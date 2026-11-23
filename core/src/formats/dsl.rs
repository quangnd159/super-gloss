//! DSL (ABBYY Lingvo) reader: `.dsl` / `.dsl.dz` with `_abrv.dsl`, `.ann`,
//! and resources in `.files.zip` or a `.files` directory.

use super::dsl_render::{headword_variants, plain_text, strip_comments, Renderer};
use super::{BuildCtx, DictInfo, Reader};
use crate::index::{Index, IndexBuilder, Locator};
use crate::store::{plausible_size, read_maybe_gzip, Source};
use crate::util::{decode_text_auto, file_below};
use anyhow::{bail, Context, Result};
use encoding_rs::Encoding;
use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum DslEnc {
    Utf16Le,
    Utf16Be,
    Utf8,
    Single(&'static Encoding),
}

impl DslEnc {
    fn name(self) -> String {
        match self {
            DslEnc::Utf16Le => "utf-16le".into(),
            DslEnc::Utf16Be => "utf-16be".into(),
            DslEnc::Utf8 => "utf-8".into(),
            DslEnc::Single(e) => e.name().to_string(),
        }
    }
    fn from_name(s: &str) -> DslEnc {
        match s {
            "utf-16le" => DslEnc::Utf16Le,
            "utf-16be" => DslEnc::Utf16Be,
            "utf-8" => DslEnc::Utf8,
            o => Encoding::for_label(o.as_bytes()).map(DslEnc::Single).unwrap_or(DslEnc::Utf8),
        }
    }
    fn unit(self) -> usize {
        match self {
            DslEnc::Utf16Le | DslEnc::Utf16Be => 2,
            _ => 1,
        }
    }
    pub fn decode(self, b: &[u8]) -> String {
        match self {
            DslEnc::Utf16Le => encoding_rs::UTF_16LE.decode_without_bom_handling(b).0.into_owned(),
            DslEnc::Utf16Be => encoding_rs::UTF_16BE.decode_without_bom_handling(b).0.into_owned(),
            DslEnc::Utf8 => String::from_utf8_lossy(b).into_owned(),
            DslEnc::Single(e) => e.decode_without_bom_handling(b).0.into_owned(),
        }
    }
}

fn code_page(name: &str) -> Option<&'static Encoding> {
    let n = name.trim().trim_matches('"').to_ascii_lowercase();
    let label = match n.as_str() {
        "latin" | "western" => "windows-1252",
        "cyrillic" => "windows-1251",
        "easterneuropean" => "windows-1250",
        "greek" => "windows-1253",
        "turkish" => "windows-1254",
        "hebrew" => "windows-1255",
        "arabic" => "windows-1256",
        "baltic" => "windows-1257",
        "vietnamese" => "windows-1258",
        other => other,
    };
    Encoding::for_label(label.as_bytes())
}

/// Returns (encoding, offset of the first text byte after any BOM).
pub fn detect_encoding(data: &[u8]) -> (DslEnc, usize) {
    if data.starts_with(&[0xFF, 0xFE]) {
        return (DslEnc::Utf16Le, 2);
    }
    if data.starts_with(&[0xFE, 0xFF]) {
        return (DslEnc::Utf16Be, 2);
    }
    if data.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return (DslEnc::Utf8, 3);
    }
    if data.len() >= 2 && data[0] != 0 && data[1] == 0 {
        return (DslEnc::Utf16Le, 0);
    }
    if data.len() >= 2 && data[0] == 0 && data[1] != 0 {
        return (DslEnc::Utf16Be, 0);
    }
    // 8-bit: honour #SOURCE_CODE_PAGE, else UTF-8 when valid, else Windows-1251.
    let head = &data[..data.len().min(4096)];
    let head_s = String::from_utf8_lossy(head);
    for l in head_s.lines() {
        let l = l.trim();
        if let Some(v) = l.strip_prefix("#SOURCE_CODE_PAGE") {
            if let Some(e) = code_page(v) {
                return (if e == encoding_rs::UTF_8 { DslEnc::Utf8 } else { DslEnc::Single(e) }, 0);
            }
        }
    }
    let probe = &data[..data.len().min(1 << 20)];
    match std::str::from_utf8(probe) {
        Ok(_) => (DslEnc::Utf8, 0),
        Err(e) if e.error_len().is_none() => (DslEnc::Utf8, 0), // truncated at probe end
        Err(_) => (DslEnc::Single(encoding_rs::WINDOWS_1251), 0),
    }
}

/// Iterates lines as (start, end_without_newline, next_line_start) byte offsets.
pub fn for_each_line(data: &[u8], start: usize, enc: DslEnc, mut f: impl FnMut(usize, usize, usize)) {
    let unit = enc.unit();
    let mut s = start;
    let n = data.len();
    match enc {
        DslEnc::Utf16Le | DslEnc::Utf16Be => {
            let nl: [u8; 2] = if enc == DslEnc::Utf16Le { [0x0A, 0] } else { [0, 0x0A] };
            let mut p = s;
            while p + 1 < n {
                if data[p] == nl[0] && data[p + 1] == nl[1] {
                    f(s, p, p + 2);
                    s = p + 2;
                }
                p += 2;
            }
            if s + 1 < n {
                f(s, n - (n - s) % unit, n);
            }
        }
        _ => {
            let mut p = s;
            while p < n {
                match memchr(b'\n', &data[p..]) {
                    Some(i) => {
                        f(s, p + i, p + i + 1);
                        p += i + 1;
                        s = p;
                    }
                    None => {
                        f(s, n, n);
                        break;
                    }
                }
            }
        }
    }
}

#[inline]
fn memchr(b: u8, s: &[u8]) -> Option<usize> {
    s.iter().position(|&c| c == b)
}

#[inline]
fn is_ws(c: char) -> bool {
    c == ' ' || c == '\t' || c == '\u{a0}'
}

fn strip_dz(p: &Path) -> PathBuf {
    let s = p.to_string_lossy();
    match s.strip_suffix(".dz") {
        Some(x) => PathBuf::from(x),
        None => p.to_path_buf(),
    }
}

/// `foo.dsl` / `foo.dsl.dz` → `foo`
fn stem_path(p: &Path) -> PathBuf {
    let s = strip_dz(p);
    s.with_extension("")
}

fn abbrev_path(p: &Path) -> Option<PathBuf> {
    let stem = stem_path(p);
    ["_abrv.dsl", "_abrv.dsl.dz", "_ABRV.dsl", "_abrv.DSL"]
        .iter()
        .map(|suf| PathBuf::from(format!("{}{suf}", stem.display())))
        .find(|p| p.is_file())
}

fn resource_paths(p: &Path) -> Vec<PathBuf> {
    let plain = strip_dz(p);
    let mut v = vec![
        PathBuf::from(format!("{}.files.zip", p.display())),
        PathBuf::from(format!("{}.files.zip", plain.display())),
        PathBuf::from(format!("{}.files", p.display())),
        PathBuf::from(format!("{}.files", plain.display())),
    ];
    v.dedup();
    v
}

pub fn companion_files(p: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = abbrev_path(p).into_iter().collect();
    v.extend(resource_paths(p).into_iter().filter(|r| r.is_file()));
    let ann = PathBuf::from(format!("{}.ann", stem_path(p).display()));
    if ann.is_file() {
        v.push(ann);
    }
    v
}

pub fn is_abbrev_file(p: &Path) -> bool {
    let n = p.file_name().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
    n.ends_with("_abrv.dsl") || n.ends_with("_abrv.dsl.dz")
}

struct Header {
    name: String,
    index_lang: String,
    contents_lang: String,
}

/// Scans a DSL file, invoking `card` for every card with
/// (headword lines, body start, body end, subentries).
fn scan(
    data: &[u8],
    enc: DslEnc,
    start: usize,
    mut card: impl FnMut(&[String], usize, usize, &[(String, usize, usize)]),
    mut progress: impl FnMut(f32),
) -> Header {
    let mut hdr = Header { name: String::new(), index_lang: String::new(), contents_lang: String::new() };
    let mut in_header = true;
    let mut comment = false;
    let mut heads: Vec<String> = Vec::new();
    let mut body: Option<(usize, usize)> = None;
    let mut subs: Vec<(String, usize, usize)> = Vec::new();
    let mut sub: Option<(String, usize)> = None;
    let mut last_report = 0usize;
    let total = data.len().max(1);

    let mut finish = |heads: &mut Vec<String>,
                      body: &mut Option<(usize, usize)>,
                      subs: &mut Vec<(String, usize, usize)>,
                      sub: &mut Option<(String, usize)>| {
        if let Some((bs, be)) = body.take() {
            if let Some((h, s)) = sub.take() {
                subs.push((h, s, be));
            }
            card(heads, bs, be, subs);
        }
        heads.clear();
        subs.clear();
        *sub = None;
    };

    for_each_line(data, start, enc, |s, e, next| {
        if s - last_report > 8 << 20 {
            last_report = s;
            progress(s as f32 / total as f32);
        }
        let raw = enc.decode(&data[s..e]);
        let raw = raw.trim_end_matches('\r');
        let line = strip_comments(raw, &mut comment);
        if in_header {
            let t = line.trim();
            if t.starts_with('#') {
                let (k, v) = t.split_once(|c: char| c.is_whitespace()).unwrap_or((t, ""));
                let v = v.trim().trim_matches('"').to_string();
                match k {
                    "#NAME" => hdr.name = v,
                    "#INDEX_LANGUAGE" => hdr.index_lang = v,
                    "#CONTENTS_LANGUAGE" => hdr.contents_lang = v,
                    _ => {}
                }
                return;
            }
            if t.is_empty() {
                return;
            }
            in_header = false;
        }
        let Some(first) = line.chars().next() else { return };
        if line.trim().is_empty() {
            return;
        }
        if !is_ws(first) {
            if body.is_some() {
                finish(&mut heads, &mut body, &mut subs, &mut sub);
            }
            heads.push(line.trim_end().to_string());
        } else {
            if heads.is_empty() {
                return;
            }
            match &mut body {
                Some((_, be)) => *be = next,
                None => body = Some((s, next)),
            }
            let t = line.trim_start_matches(is_ws);
            if let Some(rest) = t.strip_prefix('@') {
                if let Some((h, ss)) = sub.take() {
                    subs.push((h, ss, s));
                }
                let rest = rest.trim();
                if !rest.is_empty() {
                    sub = Some((rest.to_string(), next));
                }
            }
        }
    });
    finish(&mut heads, &mut body, &mut subs, &mut sub);
    hdr
}

pub fn build(path: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    let data = Source::prepare(path, ctx.dir, "text")?;
    let (enc, start) = detect_encoding(&data);
    let mut b = IndexBuilder::new();
    let mut add = |raw: &str, loc: Locator| {
        for v in headword_variants(raw) {
            b.add(&v, loc);
        }
    };
    let hdr = scan(
        &data,
        enc,
        start,
        |heads, bs, be, subs| {
            let loc = Locator { a: bs as u64, b: (be - bs) as u64 };
            for h in heads {
                add(h, loc);
            }
            for (h, ss, se) in subs {
                if se > ss {
                    add(h, Locator { a: *ss as u64, b: (se - ss) as u64 });
                }
            }
        },
        |p| ctx.progress(p * 0.9),
    );
    drop(add);
    let count = b.len();
    b.write(ctx.dir, "keys")?;

    let stem = stem_path(path);
    let name = if hdr.name.is_empty() {
        stem.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
    } else {
        hdr.name
    };
    let mut info = DictInfo::new(name, "DSL");
    info.entries = count as u64;
    info.source_lang = hdr.index_lang;
    info.target_lang = hdr.contents_lang;
    let ann = PathBuf::from(format!("{}.ann", stem.display()));
    if let Ok(raw) = std::fs::read(&ann) {
        info.description = decode_text_auto(&raw).trim().to_string();
    }
    info.extra = serde_json::json!({ "encoding": enc.name() });
    Ok(info)
}

fn load_abbreviations(path: &Path) -> HashMap<String, String> {
    let mut m = HashMap::new();
    let Ok(data) = read_maybe_gzip(path) else { return m };
    let (enc, start) = detect_encoding(&data);
    scan(
        &data,
        enc,
        start,
        |heads, bs, be, _| {
            let body = enc.decode(&data[bs..be]);
            let mut c = false;
            let text: Vec<String> = body
                .lines()
                .map(|l| plain_text(strip_comments(l, &mut c).trim()))
                .filter(|l| !l.is_empty())
                .collect();
            let text = text.join("; ");
            for h in heads {
                for v in headword_variants(h) {
                    m.entry(v.to_lowercase()).or_insert_with(|| text.clone());
                }
            }
        },
        |_| {},
    );
    m
}

enum Res {
    /// Opened on first use or when the library warms its dictionaries, whichever comes
    /// first: reading a large archive's directory must not delay the dictionary's search.
    Zip(PathBuf, OnceLock<Option<Zip>>),
    Dir(PathBuf),
}

/// A `.files.zip`, its directory read once. Each request reads through its own clone of
/// the archive, so requests never wait on one another.
struct Zip {
    archive: zip::ZipArchive<SharedFile>,
    names: HashMap<String, usize>,
}

impl Zip {
    fn open(path: &Path) -> Result<Zip> {
        let file = File::open(path)?;
        let len = file.metadata()?.len();
        let archive = zip::ZipArchive::new(SharedFile { file: Arc::new(file), len, pos: 0 })
            .with_context(|| format!("zip {}", path.display()))?;
        let mut names = HashMap::with_capacity(archive.len());
        for i in 0..archive.len() {
            if let Some(Ok(n)) = archive.name_for_index(i) {
                let n = n.replace('\\', "/");
                names.insert(n.to_lowercase(), i);
                // Also index by bare file name for archives with a top-level folder.
                if let Some(base) = n.rsplit('/').next() {
                    names.entry(base.to_lowercase()).or_insert(i);
                }
            }
        }
        Ok(Zip { archive, names })
    }

    fn get(&self, name: &str) -> Result<Option<Vec<u8>>> {
        let key = name.replace('\\', "/").trim_start_matches('/').to_lowercase();
        let Some(&i) = self.names.get(&key) else { return Ok(None) };
        let mut archive = self.archive.clone();
        let mut f = archive.by_index(i)?;
        // The sizes come from the archive: read no more than it declares, and no more than
        // its compressed bytes can honestly hold.
        let size = f.size();
        if !plausible_size(f.compressed_size(), size) {
            bail!("{name}: {} bytes can't hold {size}", f.compressed_size());
        }
        let mut buf = Vec::with_capacity(size.min(1 << 20) as usize);
        f.by_ref().take(size + 1).read_to_end(&mut buf)?;
        if buf.len() as u64 != size {
            bail!("{name}: holds {} bytes, not {size}", buf.len());
        }
        Ok(Some(buf))
    }
}

/// A file read at a position of its own: clones share the descriptor, not the cursor.
#[derive(Clone)]
struct SharedFile {
    file: Arc<File>,
    len: u64,
    pos: u64,
}

impl Read for SharedFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.file.read_at(buf, self.pos)?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for SharedFile {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let pos = match to {
            SeekFrom::Start(p) => Some(p),
            SeekFrom::End(d) => self.len.checked_add_signed(d),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
        };
        self.pos = pos.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "seek before the start"))?;
        Ok(self.pos)
    }
}

pub struct DslReader {
    text: Source,
    enc: DslEnc,
    abbr: HashMap<String, String>,
    res: Vec<Res>,
    dir: PathBuf,
}

pub fn open(path: &Path, cache: &Path, info: &DictInfo) -> Result<Box<dyn Reader>> {
    let text = Source::open(path, cache, "text", false)?;
    let enc = DslEnc::from_name(info.extra.get("encoding").and_then(|v| v.as_str()).unwrap_or("utf-8"));
    let abbr = abbrev_path(path).map(|p| load_abbreviations(&p)).unwrap_or_default();
    let mut res = Vec::new();
    for p in resource_paths(path) {
        if p.is_file() {
            res.push(Res::Zip(p, OnceLock::new()));
        } else if p.is_dir() {
            res.push(Res::Dir(p));
        }
    }
    Ok(Box::new(DslReader { text, enc, abbr, res, dir: path.parent().unwrap_or(Path::new("/")).to_path_buf() }))
}

/// The archive at `path`, opened once. An unreadable one costs the dictionary its pictures
/// and sounds, not its text.
fn zip_at<'a>(path: &Path, cell: &'a OnceLock<Option<Zip>>) -> Option<&'a Zip> {
    cell.get_or_init(|| Zip::open(path).ok()).as_ref()
}

impl Reader for DslReader {
    fn warm(&self) {
        for r in &self.res {
            if let Res::Zip(p, z) = r {
                zip_at(p, z);
            }
        }
    }

    fn article(&self, _index: &Index, word: &str, loc: Locator) -> Result<String> {
        let raw = self.text.read(loc.a, loc.b)?;
        let body = self.enc.decode(&raw);
        Ok(Renderer { headword: word, abbr: &self.abbr }.render(&body))
    }

    fn resource(&self, path: &str) -> Result<Option<Vec<u8>>> {
        for r in &self.res {
            let found = match r {
                Res::Zip(p, z) => match zip_at(p, z) {
                    Some(z) => z.get(path)?,
                    None => None,
                },
                Res::Dir(d) => file_below(d, path).map(std::fs::read).transpose()?,
            };
            if found.is_some() {
                return Ok(found);
            }
        }
        Ok(file_below(&self.dir, path).map(std::fs::read).transpose()?)
    }

    fn foreign(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utf16(s: &str) -> Vec<u8> {
        let mut v = vec![0xFF, 0xFE];
        for u in s.encode_utf16() {
            v.extend_from_slice(&u.to_le_bytes());
        }
        v
    }

    #[test]
    fn scan_cards() {
        let src = "#NAME \"Test\"\n#INDEX_LANGUAGE \"English\"\n\nhead1\nhead2\n\t[m1]body one[/m]\n\t@ sub one\n\tsub body\n\t@\n\tmore\n\n{{comment\nnot a head}}\nhead3\n  body three\r\n";
        for data in [src.as_bytes().to_vec(), utf16(src)] {
            let (enc, start) = detect_encoding(&data);
            let mut cards = Vec::new();
            let hdr = scan(
                &data,
                enc,
                start,
                |h, bs, be, subs| {
                    let body = enc.decode(&data[bs..be]);
                    let subs: Vec<_> = subs.iter().map(|(h, s, e)| (h.clone(), enc.decode(&data[*s..*e]))).collect();
                    cards.push((h.to_vec(), body, subs));
                },
                |_| {},
            );
            assert_eq!(hdr.name, "Test");
            assert_eq!(cards.len(), 2);
            assert_eq!(cards[0].0, vec!["head1", "head2"]);
            assert!(cards[0].1.starts_with("\t[m1]body one"));
            assert!(cards[0].1.ends_with("\tmore\n"));
            assert_eq!(cards[0].2, vec![("sub one".to_string(), "\tsub body\n".to_string())]);
            assert_eq!(cards[1].0, vec!["head3"]);
            assert_eq!(cards[1].1, "  body three\r\n");
        }
    }
}
