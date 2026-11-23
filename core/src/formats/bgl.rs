//! Babylon (.bgl) reader.
//!
//! A BGL file is a short header followed by a gzip stream of typed blocks. The
//! whole stream is converted once at index time into a chunk store of ready HTML
//! articles plus a resource store; reads afterwards are random access.

use super::{BuildCtx, DictInfo, Reader};
use crate::index::{Index, IndexBuilder, Locator};
use crate::store::{ChunkStore, ChunkStoreWriter};
use crate::util::{be16, be32, html_escape};
use anyhow::{bail, Context, Result};
use encoding_rs::Encoding;
use std::io::{BufReader, Read};
use std::path::Path;

const CHARSETS: [&str; 14] = [
    "windows-1252", // default
    "windows-1252", // latin
    "windows-1250", // eastern european
    "windows-1251", // cyrillic
    "shift_jis",    // japanese
    "big5",         // traditional chinese
    "gb18030",      // simplified chinese
    "windows-1257", // baltic
    "windows-1253", // greek
    "euc-kr",       // korean
    "windows-1254", // turkish
    "windows-1255", // hebrew
    "windows-1256", // arabic
    "windows-874",  // thai
];

const LANGUAGES: [&str; 61] = [
    "English", "French", "Italian", "Spanish", "Dutch", "Portuguese", "German", "Russian", "Japanese",
    "Chinese (Traditional)", "Chinese (Simplified)", "Greek", "Korean", "Turkish", "Hebrew", "Arabic", "Thai",
    "Other", "Other Simplified Chinese dialects", "Other Traditional Chinese dialects", "Other Eastern-European languages",
    "Other Western-European languages", "Other Russian languages", "Other Japanese languages", "Other Baltic languages",
    "Other Greek languages", "Other Korean dialects", "Other Turkish dialects", "Other Thai dialects", "Polish",
    "Hungarian", "Czech", "Lithuanian", "Latvian", "Catalan", "Croatian", "Serbian", "Slovak", "Albanian", "Urdu",
    "Slovenian", "Estonian", "Bulgarian", "Danish", "Finnish", "Icelandic", "Norwegian", "Romanian", "Swedish",
    "Ukrainian", "Belarusian", "Persian", "Basque", "Macedonian", "Afrikaans", "Faroese", "Latin", "Esperanto",
    "Tamazight", "Armenian", "Vietnamese",
];

const PARTS_OF_SPEECH: [&str; 11] = [
    "n.", "adj.", "v.", "adv.", "interj.", "pron.", "prep.", "conj.", "suff.", "pref.", "art.",
];

fn charset(code: u8) -> &'static Encoding {
    let mut t = code as usize;
    if t > 64 {
        t -= 65;
    }
    Encoding::for_label(CHARSETS.get(t).unwrap_or(&CHARSETS[0]).as_bytes()).unwrap_or(encoding_rs::WINDOWS_1252)
}

struct Charsets {
    default: &'static Encoding,
    source: Option<&'static Encoding>,
    target: Option<&'static Encoding>,
    utf8: bool,
}

impl Charsets {
    fn src(&self) -> &'static Encoding {
        if self.utf8 {
            encoding_rs::UTF_8
        } else {
            self.source.unwrap_or(self.default)
        }
    }
    fn tgt(&self) -> &'static Encoding {
        if self.utf8 {
            encoding_rs::UTF_8
        } else {
            self.target.unwrap_or(self.default)
        }
    }
}

fn decode(enc: &'static Encoding, b: &[u8]) -> String {
    if enc == encoding_rs::UTF_8 {
        // Some "UTF-8" BGLs contain stray Latin-1 bytes; fall back per string.
        match std::str::from_utf8(b) {
            Ok(s) => s.to_string(),
            Err(_) => encoding_rs::WINDOWS_1252.decode_without_bom_handling(b).0.into_owned(),
        }
    } else {
        enc.decode_without_bom_handling(b).0.into_owned()
    }
}

struct BlockReader<R: Read> {
    r: R,
}

impl<R: Read> BlockReader<R> {
    fn next(&mut self, buf: &mut Vec<u8>) -> Result<Option<u8>> {
        let mut b = [0u8; 1];
        if self.r.read(&mut b)? == 0 {
            return Ok(None);
        }
        let typ = b[0] & 0x0f;
        let lc = (b[0] >> 4) as usize;
        let len = if lc < 4 {
            let mut n = [0u8; 4];
            self.r.read_exact(&mut n[..lc + 1]).context("truncated block length")?;
            n[..lc + 1].iter().fold(0usize, |a, &x| (a << 8) | x as usize)
        } else {
            lc - 4
        };
        // The buffer grows with the data that arrives, not with the length field (up to 4 GiB).
        buf.clear();
        (&mut self.r).take(len as u64).read_to_end(buf)?;
        if buf.len() != len {
            bail!("truncated block");
        }
        Ok(Some(typ))
    }
}

pub struct Entry {
    pub headword: String,
    pub display: Option<String>,
    pub definition: String,
    pub alternates: Vec<String>,
    pub transcription: Option<String>,
}

/// Strips Babylon's `$123$` disambiguation suffix.
fn strip_dollar(s: &str) -> &str {
    let t = s.trim_end();
    if let Some(body) = t.strip_suffix('$') {
        if let Some(p) = body.rfind('$') {
            if p + 1 < body.len() && body[p + 1..].bytes().all(|c| c.is_ascii_digit()) {
                return body[..p].trim_end();
            }
        }
    }
    s
}

/// Replaces `<charset c=T>XXXX;YYYY;</charset>` with the hex code points.
fn expand_charset_tags(s: &str) -> String {
    let lower = s.to_ascii_lowercase();
    if !lower.contains("<charset") {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while let Some(p) = lower[i..].find("<charset") {
        let p = i + p;
        out.push_str(&s[i..p]);
        let Some(gt) = lower[p..].find('>') else { break };
        let open = &lower[p..p + gt];
        let body_start = p + gt + 1;
        let Some(end) = lower[body_start..].find("</charset>") else {
            i = p;
            break;
        };
        let body = &s[body_start..body_start + end];
        if open.contains("c=t") || open.contains("c=\"t\"") {
            for code in body.split(';') {
                let c = code.trim();
                if c.is_empty() {
                    continue;
                }
                match u32::from_str_radix(c, 16).ok().and_then(char::from_u32) {
                    Some(ch) => out.push(ch),
                    None => out.push_str(c),
                }
            }
        } else {
            out.push_str(body);
        }
        i = body_start + end + "</charset>".len();
    }
    out.push_str(&s[i..]);
    out
}

/// Start of the trailing field section: the first 0x14 not followed by a space
/// (a 0x14 + space can occur inside article text).
fn fields_start(d: &[u8]) -> Option<usize> {
    let mut from = 0;
    while let Some(i) = d[from..].iter().position(|&c| c == 0x14).map(|i| i + from) {
        if d.get(i + 1) != Some(&b' ') {
            return Some(i);
        }
        from = i + 1;
    }
    None
}

/// Parses the definition field: an article body, optionally followed by Babylon's
/// binary field section (part of speech, display headword, transcription).
fn parse_definition(d: &[u8], cs: &Charsets, e: &mut Entry) {
    let (body, fields) = match fields_start(d) {
        Some(i) => (&d[..i], &d[i + 1..]),
        None => (d, &d[d.len()..]),
    };
    let mut out: Vec<u8> = Vec::with_capacity(body.len() + 16);
    for &c in body {
        match c {
            0x0a => out.extend_from_slice(b"<br>"),
            0x09 => out.push(b' '),
            // resource-reference markers and other stray control bytes
            c if c < 0x20 => {}
            c => out.push(c),
        }
    }

    let mut pos_prefix: Option<&'static str> = None;
    let d = fields;
    let len = d.len();
    let mut a = 0usize;
    // Length-prefixed field at `a`: `head` bytes of header, then `l` bytes of value.
    let take = |a: usize, head: usize, l: usize| -> Option<&[u8]> { d.get(a + head..a + head + l) };
    while a < len {
        let c = d[a];
        let next = d.get(a + 1).copied();
        match (c, next) {
            (0x02, Some(n)) => {
                if let Some(p) = PARTS_OF_SPEECH.get(n.wrapping_sub(0x30) as usize) {
                    pos_prefix = Some(p);
                }
                a += 2;
            }
            (0x06, Some(_)) => a += 2,
            (0x13 | 0x1a, Some(l)) => match take(a, 2, l as usize) {
                Some(_) => a += 2 + l as usize,
                None => break,
            },
            (0x18, Some(l)) => match take(a, 2, l as usize) {
                Some(v) => {
                    e.display = Some(decode(cs.src(), v));
                    a += 2 + l as usize;
                }
                None => break,
            },
            (0x28, Some(_)) if a + 3 <= len => {
                let l = be16(&d[a + 1..]) as usize;
                match take(a, 3, l) {
                    Some(v) => {
                        e.display = Some(decode(cs.src(), v));
                        a += 3 + l;
                    }
                    None => break,
                }
            }
            (0x50, Some(0x1b)) if a + 3 <= len => {
                let l = d[a + 2] as usize;
                match take(a, 3, l) {
                    Some(v) => {
                        e.transcription = Some(decode(cs.tgt(), v));
                        a += 3 + l;
                    }
                    None => break,
                }
            }
            (0x60, Some(0x1b)) if a + 4 <= len => {
                let l = be16(&d[a + 2..]) as usize;
                match take(a, 4, l) {
                    Some(v) => {
                        e.transcription = Some(decode(cs.tgt(), v));
                        a += 4 + l;
                    }
                    None => break,
                }
            }
            // hidden display headword / transcription with the length in the code byte
            (0x40..=0x4f, Some(0x18 | 0x1b)) => {
                let l = (c - 0x3f) as usize;
                if take(a, 2, l).is_none() {
                    break;
                }
                a += 2 + l;
            }
            _ => break,
        }
    }
    let mut html = expand_charset_tags(&decode(cs.tgt(), &out));
    if let Some(p) = pos_prefix {
        html = format!("<span class=\"bgl-pos\">{p}</span> {html}");
    }
    e.definition = html;
}

fn parse_entry(typ: u8, data: &[u8], cs: &Charsets) -> Option<Entry> {
    let mut e = Entry { headword: String::new(), display: None, definition: String::new(), alternates: Vec::new(), transcription: None };
    let mut p = 0usize;
    let get = |p: usize, n: usize| data.get(p..p + n);
    if typ == 11 {
        p = 1;
        let hl = be32(get(p, 4)?) as usize;
        p += 4;
        e.headword = decode(cs.src(), get(p, hl)?);
        p += hl;
        let n_alt = be32(get(p, 4)?) as usize;
        p += 4;
        for _ in 0..n_alt.min(1024) {
            let al = be32(get(p, 4)?) as usize;
            p += 4;
            e.alternates.push(decode(cs.src(), get(p, al)?));
            p += al;
        }
        let dl = be32(get(p, 4)?) as usize;
        p += 4;
        let def = get(p, dl).unwrap_or(&data[p.min(data.len())..]);
        parse_definition(def, cs, &mut e);
    } else {
        let hl = *data.first()? as usize;
        p += 1;
        e.headword = decode(cs.src(), get(p, hl)?);
        p += hl;
        let dl = be16(get(p, 2)?) as usize;
        p += 2;
        let def = get(p, dl).unwrap_or(&data[p.min(data.len())..]);
        parse_definition(def, cs, &mut e);
        p += def.len();
        while p < data.len() {
            let al = data[p] as usize;
            p += 1;
            let Some(a) = get(p, al) else { break };
            e.alternates.push(decode(cs.src(), a));
            p += al;
        }
    }
    e.headword = strip_dollar(&e.headword).to_string();
    for a in &mut e.alternates {
        *a = strip_dollar(a).to_string();
    }
    Some(e)
}

#[derive(Default)]
struct Meta {
    title: String,
    author: String,
    email: String,
    copyright: String,
    description: String,
    source_lang: String,
    target_lang: String,
    icon: Option<Vec<u8>>,
}

fn open_stream(path: &Path) -> Result<impl Read> {
    let mut f = std::fs::File::open(path)?;
    let mut head = [0u8; 6];
    f.read_exact(&mut head).context("short file")?;
    if !(head[0] == 0x12 && head[1] == 0x34 && head[2] == 0x00 && (head[3] == 0x01 || head[3] == 0x02)) {
        bail!("not a Babylon .bgl file");
    }
    let off = be16(&head[4..]) as u64;
    if off < 6 {
        bail!("bad Babylon header");
    }
    use std::io::{Seek, SeekFrom};
    f.seek(SeekFrom::Start(off))?;
    Ok(flate2::read::MultiGzDecoder::new(BufReader::with_capacity(1 << 20, f)))
}

fn header_block(data: &[u8], meta: &mut Meta, cs: &mut Charsets) -> bool {
    // returns true if the block changed charsets
    if data.len() < 2 {
        return false;
    }
    let code = be16(data);
    let v = &data[2..];
    let text = |b: &[u8]| decode(encoding_rs::UTF_8, b).trim_matches('\0').trim().to_string();
    match code {
        0x01 => meta.title = text(v),
        0x02 => meta.author = text(v),
        0x03 => meta.email = text(v),
        0x04 => meta.copyright = text(v),
        0x07 => meta.source_lang = v.get(3).and_then(|&i| LANGUAGES.get(i as usize)).unwrap_or(&"").to_string(),
        0x08 => meta.target_lang = v.get(3).and_then(|&i| LANGUAGES.get(i as usize)).unwrap_or(&"").to_string(),
        0x09 => meta.description = text(v),
        0x0b => {
            if v.len() > 4 {
                meta.icon = Some(v.to_vec());
            }
        }
        0x11 => {
            if data.len() >= 5 && data[4] & 0x80 != 0 {
                cs.utf8 = true;
                return true;
            }
        }
        0x1a => {
            if let Some(&c) = v.first() {
                cs.source = Some(charset(c));
                return true;
            }
        }
        0x1b => {
            if let Some(&c) = v.first() {
                cs.target = Some(charset(c));
                return true;
            }
        }
        _ => {}
    }
    false
}

pub fn build(path: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    let first = Charsets { default: encoding_rs::WINDOWS_1252, source: None, target: None, utf8: false };
    // Decoding depends on charset headers. They precede entries in every known file, but
    // when one arrives late, the file is read again with the charsets it ended with.
    let (info, late) = build_pass(path, ctx, first)?;
    match late {
        Some(cs) => Ok(build_pass(path, ctx, cs)?.0),
        None => Ok(info),
    }
}

/// Converts the file once, decoding with `cs`. Also returns the final charsets when a
/// charset header came after entries had been decoded with the earlier ones.
fn build_pass(path: &Path, ctx: &BuildCtx, mut cs: Charsets) -> Result<(DictInfo, Option<Charsets>)> {
    let total = std::fs::metadata(path)?.len().max(1) as f32;
    let mut meta = Meta::default();
    let mut br = BlockReader { r: open_stream(path)? };
    let mut buf = Vec::new();
    let mut arts = ChunkStoreWriter::create(ctx.dir, "articles")?;
    let mut res = ChunkStoreWriter::create(ctx.dir, "res")?;
    let mut idx = IndexBuilder::new();
    let mut ridx = IndexBuilder::new();
    let mut seen_entry = false;
    let mut late_charset = false;
    let mut n = 0usize;
    let mut html = String::new();
    while let Some(typ) = br.next(&mut buf)? {
        match typ {
            0 => {
                if buf.len() >= 3 && buf[0] == 8 {
                    cs.default = charset(buf[2]);
                    late_charset |= seen_entry;
                }
            }
            3 => {
                if header_block(&buf, &mut meta, &mut cs) {
                    late_charset |= seen_entry;
                }
            }
            2 => {
                let nl = *buf.first().unwrap_or(&0) as usize;
                if buf.len() > nl {
                    let name = String::from_utf8_lossy(&buf[1..1 + nl]).into_owned();
                    let (o, l) = res.append(&buf[1 + nl..])?;
                    ridx.add_raw(name.to_lowercase().into_bytes(), &name, Locator { a: o, b: l });
                }
            }
            1 | 7 | 10 | 11 => {
                seen_entry = true;
                let Some(e) = parse_entry(typ, &buf, &cs) else { continue };
                if e.headword.trim().is_empty() {
                    continue;
                }
                html.clear();
                if let Some(t) = &e.transcription {
                    html.push_str("<div class=\"bgl-tr\">[");
                    html.push_str(&html_escape(t));
                    html.push_str("]</div>");
                }
                html.push_str(&super::markup::normalize_links(&e.definition));
                let (o, l) = arts.append(html.as_bytes())?;
                // Locator: article (offset, length); display headword stored in index.
                let shown = e.display.as_deref().map(strip_html).filter(|s| !s.trim().is_empty());
                let head = shown.clone().unwrap_or_else(|| e.headword.clone());
                let loc = Locator { a: o, b: l };
                // Every key opens the entry under the headword it shows.
                idx.add_form(&e.headword, &head, loc);
                if crate::fold::fold(&head) != crate::fold::fold(&e.headword) {
                    idx.add(&head, loc);
                }
                for a in &e.alternates {
                    idx.add_form(a, &head, loc);
                }
                n += 1;
                if n % 4096 == 0 {
                    ctx.progress(0.95f32.min(n as f32 * 300.0 / total));
                }
            }
            4 => break,
            _ => {}
        }
    }
    arts.finish()?;
    res.finish()?;
    let count = idx.len();
    idx.write(ctx.dir, "keys")?;
    ridx.write(ctx.dir, "reskeys")?;
    let name = if meta.title.is_empty() {
        path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
    } else {
        meta.title.clone()
    };
    let mut info = DictInfo::new(name, "Babylon");
    info.entries = count as u64;
    info.author = meta.author.clone();
    info.description = meta.description.clone();
    if !meta.copyright.is_empty() {
        if !info.description.is_empty() {
            info.description.push_str("<br>");
        }
        info.description.push_str(&meta.copyright);
    }
    info.source_lang = meta.source_lang.clone();
    info.target_lang = meta.target_lang.clone();
    if let Some(ico) = &meta.icon {
        let p = ctx.dir.join("icon.ico");
        std::fs::write(&p, ico)?;
        info.icon = Some("icon.ico".into());
    }
    Ok((info, late_charset.then_some(cs)))
}

fn strip_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    crate::util::unescape_entities(&out)
}

pub struct BglReader {
    arts: ChunkStore,
    res: ChunkStore,
    ridx: Index,
}

pub fn open(_path: &Path, cache: &Path, _info: &DictInfo) -> Result<Box<dyn Reader>> {
    Ok(Box::new(BglReader {
        arts: ChunkStore::open(cache, "articles")?,
        res: ChunkStore::open(cache, "res")?,
        ridx: Index::open(cache, "reskeys")?,
    }))
}

impl Reader for BglReader {
    fn article(&self, _index: &Index, _word: &str, loc: Locator) -> Result<String> {
        Ok(String::from_utf8_lossy(&self.arts.read(loc.a, loc.b)?).into_owned())
    }

    fn resource(&self, path: &str) -> Result<Option<Vec<u8>>> {
        let name = path.trim_start_matches('/').rsplit(['/', '\\']).next().unwrap_or("").to_lowercase();
        if let Some(g) = self.ridx.get(name.as_bytes()) {
            if let Some((_, loc)) = self.ridx.entry(g.start) {
                return Ok(Some(self.res.read(loc.a, loc.b)?));
            }
        }
        Ok(None)
    }

    fn foreign(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn definition_body_keeps_parentheses() {
        let cs = Charsets { default: encoding_rs::WINDOWS_1252, source: None, target: None, utf8: true };
        let mut e = Entry { headword: String::new(), display: None, definition: String::new(), alternates: vec![], transcription: None };
        // '(' is 0x28 — a field code only in the trailing section after 0x14.
        let mut d = b"f(\x00\x05abcdef) x\x14 y".to_vec();
        d.extend_from_slice(b"\x14\x02\x31\x18\x03run");
        parse_definition(&d, &cs, &mut e);
        assert_eq!(e.display.as_deref(), Some("run"));
        assert!(e.definition.ends_with("f(abcdef) x y"), "{}", e.definition);
        assert!(e.definition.starts_with("<span class=\"bgl-pos\">"));
    }

    #[test]
    fn block_longer_than_its_data_fails() {
        // A type-1 block whose 4-byte length claims 4 GiB, followed by three bytes.
        let data = [0x31u8, 0xff, 0xff, 0xff, 0xff, 1, 2, 3];
        assert!(BlockReader { r: &data[..] }.next(&mut Vec::new()).is_err());
    }

    #[test]
    fn helpers() {
        assert_eq!(strip_dollar("run$12$"), "run");
        assert_eq!(strip_dollar("a$b"), "a$b");
        assert_eq!(expand_charset_tags("x<charset c=T>0041;0042;</charset>y"), "xABy");
        let cs = Charsets { default: encoding_rs::WINDOWS_1252, source: None, target: None, utf8: true };
        let mut e = Entry { headword: String::new(), display: None, definition: String::new(), alternates: vec![], transcription: None };
        parse_definition(b"a\nb<img src=\x1ex.png\x1f>\x14\x02\x30", &cs, &mut e);
        assert_eq!(e.definition, "<span class=\"bgl-pos\">n.</span> a<br>b<img src=x.png>");
        let data = b"\x02go\x00\x03def\x04goes";
        let e = parse_entry(1, data, &cs).unwrap();
        assert_eq!(e.headword, "go");
        assert_eq!(e.definition, "def");
        assert_eq!(e.alternates, vec!["goes"]);
    }
}
