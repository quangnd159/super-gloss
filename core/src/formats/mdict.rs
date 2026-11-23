//! MDict (.mdx / .mdd) reader. Supports engine versions 1.x and 2.x, key-info
//! encryption (Encrypted="2"), per-block fast-decrypt, zlib and LZO blocks, and
//! split resource volumes (`name.mdd`, `name.1.mdd`, ...).

use super::{BuildCtx, DictInfo, Reader};
use crate::index::{Index, IndexBuilder, Locator};
use crate::store::{inflate_zlib, plausible_size};
use crate::util::{file_below, read_at, unescape_entities, BlockCache, Cursor};
use anyhow::{bail, Context, Result};
use ripemd::{Digest, Ripemd128};
use std::collections::HashMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Enc {
    Utf8,
    Utf16,
    Other(&'static encoding_rs::Encoding),
}

struct RecordBlock {
    file_off: u64,
    comp: u64,
    decomp_off: u64,
    decomp: u64,
}

pub struct MdictFile {
    file: File,
    len: u64,
    pub attrs: HashMap<String, String>,
    width: usize,
    v2: bool,
    enc: Enc,
    encrypted: u32,
    key_section: u64,
    blocks: Vec<RecordBlock>,
    records_total: u64,
    cache: BlockCache,
}

/// The key section's header, its sizes checked against the file.
struct KeyHeader {
    blocks: u64,
    info_decomp: u64,
    info_size: u64,
    blocks_size: u64,
    /// Where the key-block info starts; the key blocks follow it, then the records.
    start: u64,
}

fn parse_attrs(header: &str) -> HashMap<String, String> {
    let mut m = HashMap::new();
    let mut rest = header;
    // <Dictionary a="b" c="d"/>
    while let Some(eq) = rest.find("=\"") {
        let name_start = rest[..eq].rfind(|c: char| c.is_whitespace() || c == '<').map(|i| i + 1).unwrap_or(0);
        let name = rest[name_start..eq].trim().to_string();
        let after = &rest[eq + 2..];
        let Some(end) = after.find('"') else { break };
        m.insert(name, unescape_entities(&after[..end]));
        rest = &after[end + 1..];
    }
    m
}

fn ripemd128(data: &[u8]) -> [u8; 16] {
    let mut h = Ripemd128::new();
    h.update(data);
    h.finalize().into()
}

fn fast_decrypt(data: &mut [u8], key: &[u8]) {
    let mut prev: u8 = 0x36;
    for (i, b) in data.iter_mut().enumerate() {
        let cur = *b;
        let t = cur.rotate_left(4) ^ prev ^ (i as u8) ^ key[i % key.len()];
        prev = cur;
        *b = t;
    }
}

/// Real blocks hold kilobytes to a few megabytes.
const MAX_BLOCK: u64 = 64 << 20;

/// Decodes an MDict compressed block (4-byte info (LE), 4-byte adler32, payload) that
/// must hold exactly `size` bytes.
fn decode_block(block: &[u8], size: u64) -> Result<Vec<u8>> {
    if block.len() < 8 {
        bail!("short block");
    }
    if size > MAX_BLOCK || !plausible_size(block.len() as u64, size) {
        bail!("a block of {} bytes can't hold {size}", block.len());
    }
    let size = size as usize;
    let info = u32::from_le_bytes(block[0..4].try_into().unwrap());
    let comp = info & 0xf;
    let enc_method = (info >> 4) & 0xf;
    let enc_size = ((info >> 8) & 0xff) as usize;
    let mut data = block[8..].to_vec();
    match enc_method {
        0 => {}
        1 => {
            let key = ripemd128(&block[4..8]);
            let n = enc_size.min(data.len());
            fast_decrypt(&mut data[..n], &key);
        }
        m => bail!("unsupported MDict block encryption {m}"),
    }
    let out = match comp {
        0 => data,
        1 => lzokay_native::decompress_all_bounded(&data, size).map_err(|e| anyhow::anyhow!("LZO: {e:?}"))?,
        2 => inflate_zlib(&data, size)?,
        c => bail!("unsupported MDict compression {c}"),
    };
    if out.len() != size {
        bail!("block holds {} bytes, not {size}", out.len());
    }
    Ok(out)
}

impl MdictFile {
    pub fn open(path: &Path, is_mdd: bool) -> Result<MdictFile> {
        let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
        let flen = file.metadata()?.len();
        let hlen = u32::from_be_bytes(read_at(&file, 0, 4)?.try_into().unwrap()) as u64;
        if hlen == 0 || hlen > flen || hlen > 16 << 20 {
            bail!("not an MDict file");
        }
        let hbytes = read_at(&file, 4, hlen as usize)?;
        let header = encoding_rs::UTF_16LE.decode_without_bom_handling(&hbytes).0;
        if !header.contains("<Dictionary") && !header.contains("<Library_Data") {
            bail!("not an MDict file (bad header)");
        }
        let attrs = parse_attrs(&header);
        let version: f32 = attrs
            .get("GeneratedByEngineVersion")
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(2.0);
        if version >= 3.0 {
            bail!("MDict 3.0 files are not supported yet");
        }
        let v2 = version >= 2.0;
        let width = if v2 { 8 } else { 4 };
        let encrypted = match attrs.get("Encrypted").map(|s| s.trim()) {
            None | Some("") | Some("No") | Some("no") => 0,
            Some("Yes") | Some("yes") => 1,
            Some(v) => v.parse().unwrap_or(0),
        };
        if encrypted & 1 != 0 {
            bail!("this MDict file is encrypted and requires a registration key");
        }
        let enc = if is_mdd {
            Enc::Utf16
        } else {
            let e = attrs.get("Encoding").map(|s| s.trim().to_ascii_uppercase()).unwrap_or_default();
            match e.as_str() {
                "" | "UTF-8" | "UTF8" => Enc::Utf8,
                "UTF-16" | "UTF16" | "UTF-16LE" => Enc::Utf16,
                "GBK" | "GB2312" | "GB18030" => Enc::Other(encoding_rs::GB18030),
                other => encoding_rs::Encoding::for_label(other.as_bytes()).map(Enc::Other).unwrap_or(Enc::Utf8),
            }
        };
        let key_section = 4 + hlen + 4;
        let mut m = MdictFile {
            file,
            len: flen,
            attrs,
            width,
            v2,
            enc,
            encrypted,
            key_section,
            blocks: Vec::new(),
            records_total: 0,
            cache: BlockCache::new(12),
        };
        m.read_record_table()?;
        Ok(m)
    }

    fn key_header(&self) -> Result<KeyHeader> {
        let w = self.width;
        let n = if self.v2 { 5 } else { 4 };
        let raw = read_at(&self.file, self.key_section, n * w)?;
        let mut c = Cursor::new(&raw);
        let blocks = c.num(w)?;
        let _entries = c.num(w)?;
        let info_decomp = if self.v2 { c.num(w)? } else { 0 };
        let info_size = c.num(w)?;
        let blocks_size = c.num(w)?;
        // v2 follows the sizes with a checksum.
        let start = self.key_section + (n * w) as u64 + if self.v2 { 4 } else { 0 };
        if start.checked_add(info_size).and_then(|e| e.checked_add(blocks_size)).is_none_or(|e| e > self.len) {
            bail!("key section exceeds the file");
        }
        Ok(KeyHeader { blocks, info_decomp, info_size, blocks_size, start })
    }

    fn read_record_table(&mut self) -> Result<()> {
        let kh = self.key_header()?;
        let rec_section = kh.start + kh.info_size + kh.blocks_size;
        let w = self.width;
        let raw = read_at(&self.file, rec_section, 4 * w)?;
        let mut c = Cursor::new(&raw);
        let num = c.num(w)?;
        let _entries = c.num(w)?;
        let info_size = c.num(w)?;
        let _data_size = c.num(w)?;
        let mut file_off = rec_section + 4 * w as u64;
        if info_size > self.len - file_off || num > info_size / (2 * w as u64) {
            bail!("corrupt record header");
        }
        let info = read_at(&self.file, file_off, info_size as usize)?;
        let mut c = Cursor::new(&info);
        file_off += info_size;
        let mut decomp_off = 0u64;
        self.blocks.reserve(num as usize);
        for _ in 0..num {
            let comp = c.num(w)?;
            let decomp = c.num(w)?;
            if comp > self.len - file_off || !plausible_size(comp, decomp) {
                bail!("corrupt record block table");
            }
            self.blocks.push(RecordBlock { file_off, comp, decomp_off, decomp });
            file_off += comp;
            decomp_off += decomp;
        }
        self.records_total = decomp_off;
        Ok(())
    }

    fn decode_key(&self, b: &[u8]) -> String {
        match self.enc {
            Enc::Utf8 => String::from_utf8_lossy(b).into_owned(),
            Enc::Utf16 => encoding_rs::UTF_16LE.decode_without_bom_handling(b).0.into_owned(),
            Enc::Other(e) => e.decode_without_bom_handling(b).0.into_owned(),
        }
    }

    /// Reads every key with its record offset, in file order.
    pub fn read_keys(&self) -> Result<Vec<(String, u64)>> {
        let kh = self.key_header()?;
        let w = self.width;
        let mut kbi = read_at(&self.file, kh.start, kh.info_size as usize)?;
        if self.v2 {
            if kbi.len() < 8 {
                bail!("short key-block info");
            }
            if self.encrypted & 2 != 0 {
                let mut k = kbi[4..8].to_vec();
                k.extend_from_slice(&0x3695u32.to_le_bytes());
                let key = ripemd128(&k);
                fast_decrypt(&mut kbi[8..], &key);
            }
            // Framed like any block: zlib as a rule, but stored or LZO where the packer chose so.
            kbi = decode_block(&kbi, kh.info_decomp)?;
        }
        let utf16 = self.enc == Enc::Utf16;
        let mut c = Cursor::new(&kbi);
        let mut sizes = Vec::with_capacity(kh.blocks.min(kbi.len() as u64) as usize);
        for _ in 0..kh.blocks {
            let _n = c.num(w)?;
            for _ in 0..2 {
                let len = if self.v2 { c.be16()? as usize } else { c.u8()? as usize };
                let term = if self.v2 { 1 } else { 0 };
                let bytes = if utf16 { (len + term) * 2 } else { len + term };
                c.take(bytes)?;
            }
            let comp = c.num(w)?;
            let decomp = c.num(w)?;
            sizes.push((comp, decomp));
        }
        let mut keys = Vec::new();
        let mut off = kh.start + kh.info_size;
        let end = off + kh.blocks_size;
        for (comp, decomp) in sizes {
            if comp > end - off {
                bail!("key block exceeds key section");
            }
            let raw = read_at(&self.file, off, comp as usize)?;
            off += comp;
            let block = decode_block(&raw, decomp)?;
            let mut p = 0usize;
            while p + w <= block.len() {
                let id = if w == 8 {
                    u64::from_be_bytes(block[p..p + 8].try_into().unwrap())
                } else {
                    u32::from_be_bytes(block[p..p + 4].try_into().unwrap()) as u64
                };
                p += w;
                let s = p;
                if utf16 {
                    while p + 1 < block.len() && !(block[p] == 0 && block[p + 1] == 0) {
                        p += 2;
                    }
                    keys.push((self.decode_key(&block[s..p.min(block.len())]), id));
                    p += 2;
                } else {
                    while p < block.len() && block[p] != 0 {
                        p += 1;
                    }
                    keys.push((self.decode_key(&block[s..p]), id));
                    p += 1;
                }
            }
        }
        Ok(keys)
    }

    /// Computes (key, offset, size) using the next distinct offset as the end.
    pub fn read_entries(&self) -> Result<Vec<(String, u64, u64)>> {
        let keys = self.read_keys()?;
        let mut offs: Vec<u64> = keys.iter().map(|k| k.1).collect();
        offs.sort_unstable();
        offs.dedup();
        let total = self.records_total;
        Ok(keys
            .into_iter()
            .filter(|(_, o)| *o < total)
            .map(|(k, o)| {
                let i = offs.partition_point(|&x| x <= o);
                let end = offs.get(i).copied().unwrap_or(total);
                (k, o, end - o)
            })
            .collect())
    }

    fn block(&self, i: usize) -> Result<Arc<Vec<u8>>> {
        self.cache.get_or_load(i as u64, || {
            let b = &self.blocks[i];
            let raw = read_at(&self.file, b.file_off, b.comp as usize)?;
            decode_block(&raw, b.decomp).with_context(|| format!("record block {i}"))
        })
    }

    pub fn record(&self, off: u64, len: u64) -> Result<Vec<u8>> {
        let end = off.checked_add(len).context("overflow")?.min(self.records_total);
        let mut i = self.blocks.partition_point(|b| b.decomp_off + b.decomp <= off);
        let mut out = Vec::with_capacity(end.saturating_sub(off).min(1 << 20) as usize);
        let mut pos = off;
        while pos < end && i < self.blocks.len() {
            let b = &self.blocks[i];
            let data = self.block(i)?;
            let s = (pos - b.decomp_off) as usize;
            let e = ((end - b.decomp_off) as usize).min(data.len());
            out.extend_from_slice(&data[s..e]);
            pos = b.decomp_off + e as u64;
            i += 1;
        }
        Ok(out)
    }

    pub fn decode_text(&self, mut b: &[u8]) -> String {
        match self.enc {
            Enc::Utf16 => {
                while b.len() >= 2 && b[b.len() - 2..] == [0, 0] {
                    b = &b[..b.len() - 2];
                }
            }
            _ => {
                while b.last() == Some(&0) {
                    b = &b[..b.len() - 1];
                }
            }
        }
        self.decode_key(b)
    }
}

/// Normalizes a resource path to the MDD key convention: `\dir\file.ext`, lowercase.
pub fn mdd_key(path: &str) -> Vec<u8> {
    let p = path.trim().replace('/', "\\");
    let p = p.trim_start_matches('\\');
    format!("\\{}", p.to_lowercase()).into_bytes()
}

fn mdd_volumes(mdx: &Path) -> Vec<PathBuf> {
    let stem = mdx.with_extension("");
    let mut v = Vec::new();
    let first = stem.with_extension("mdd");
    if first.is_file() {
        v.push(first);
        for i in 1..100 {
            let p = PathBuf::from(format!("{}.{i}.mdd", stem.display()));
            if !p.is_file() {
                break;
            }
            v.push(p);
        }
    }
    v
}

pub fn companion_files(mdx: &Path) -> Vec<PathBuf> {
    mdd_volumes(mdx)
}

fn stylesheet_table(attrs: &HashMap<String, String>) -> HashMap<String, (String, String)> {
    let mut m = HashMap::new();
    let Some(ss) = attrs.get("StyleSheet") else { return m };
    let lines: Vec<&str> = ss.lines().collect();
    let mut i = 0;
    while i + 2 < lines.len() {
        let n = lines[i].trim();
        if !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) {
            m.insert(n.to_string(), (lines[i + 1].to_string(), lines[i + 2].to_string()));
            i += 3;
        } else {
            i += 1;
        }
    }
    m
}

pub fn build(path: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    let mdx = MdictFile::open(path, false)?;
    let entries = mdx.read_entries()?;
    ctx.progress(0.5);
    let mut b = IndexBuilder::new();
    for (k, o, s) in &entries {
        b.add(k, Locator { a: *o, b: *s });
    }
    let count = b.len();
    b.write(ctx.dir, "keys")?;
    let vols = mdd_volumes(path);
    for (vi, v) in vols.iter().enumerate() {
        let mdd = MdictFile::open(v, true).with_context(|| format!("resource file {}", v.display()))?;
        let mut rb = IndexBuilder::new();
        for (k, o, s) in mdd.read_entries()? {
            rb.add_raw(mdd_key(&k), &k, Locator { a: o, b: s });
        }
        rb.write(ctx.dir, &format!("res{vi}"))?;
        ctx.progress(0.5 + 0.5 * (vi + 1) as f32 / vols.len() as f32);
    }
    let title = mdx.attrs.get("Title").map(|s| s.trim().to_string()).unwrap_or_default();
    let name = if title.is_empty() || title == "Title (No HTML code allowed)" {
        path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
    } else {
        title
    };
    let mut info = DictInfo::new(name, "MDict");
    info.description = mdx.attrs.get("Description").cloned().unwrap_or_default();
    info.entries = count as u64;
    info.extra = serde_json::json!({ "volumes": vols.len() });
    Ok(info)
}

pub struct MdictReader {
    mdx: MdictFile,
    dir: PathBuf,
    volumes: Vec<(MdictFile, Index)>,
    styles: HashMap<String, (String, String)>,
}

pub fn open(path: &Path, cache: &Path, info: &DictInfo) -> Result<Box<dyn Reader>> {
    let mdx = MdictFile::open(path, false)?;
    let nvol = info.extra.get("volumes").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    let vols = mdd_volumes(path);
    let mut volumes = Vec::new();
    for (i, v) in vols.iter().enumerate().take(nvol) {
        volumes.push((MdictFile::open(v, true)?, Index::open(cache, &format!("res{i}"))?));
    }
    let styles = stylesheet_table(&mdx.attrs);
    Ok(Box::new(MdictReader { dir: path.parent().unwrap_or(Path::new("/")).to_path_buf(), mdx, volumes, styles }))
}

impl MdictReader {
    fn apply_stylesheet(&self, txt: &str) -> String {
        if self.styles.is_empty() || !txt.contains('`') {
            return txt.to_string();
        }
        let mut out = String::with_capacity(txt.len() * 2);
        let mut rest = txt;
        let mut pending: Option<&(String, String)> = None;
        loop {
            // find next `digits`
            let next = rest.char_indices().find_map(|(i, c)| {
                if c != '`' {
                    return None;
                }
                let tail = &rest[i + 1..];
                let n = tail.find(|c: char| !c.is_ascii_digit())?;
                (n > 0 && tail[n..].starts_with('`')).then(|| (i, &tail[..n], i + 1 + n + 1))
            });
            let (seg, adv) = match next {
                Some((i, _, _)) => (&rest[..i], next),
                None => (rest, None),
            };
            match pending {
                Some((begin, end)) => {
                    out.push_str(begin);
                    if seg.ends_with('\n') {
                        out.push_str(seg.trim_end());
                        out.push_str(end);
                        out.push_str("\r\n");
                    } else {
                        out.push_str(seg);
                        out.push_str(end);
                    }
                }
                None => out.push_str(seg),
            }
            match adv {
                Some((_, num, after)) => {
                    pending = self.styles.get(num);
                    if pending.is_none() {
                        pending = Some(&EMPTY_STYLE);
                    }
                    rest = &rest[after..];
                }
                None => break,
            }
        }
        out
    }
}

static EMPTY_STYLE: (String, String) = (String::new(), String::new());

const LINK: &str = "@@@LINK=";

impl Reader for MdictReader {
    fn article(&self, index: &Index, _word: &str, loc: Locator) -> Result<String> {
        let mut loc = loc;
        let mut seen = Vec::new();
        for _ in 0..8 {
            let raw = self.mdx.record(loc.a, loc.b)?;
            let text = self.mdx.decode_text(&raw);
            let trimmed = text.trim_start_matches('\u{feff}').trim();
            if let Some(target) = trimmed.strip_prefix(LINK) {
                let target = target.lines().next().unwrap_or("").trim();
                seen.push(loc);
                let next = crate::fold::index_key(target).and_then(|k| index.get(&k)).or_else(|| {
                    let f = crate::fold::fold(target);
                    index.folded(f.as_bytes()).into_iter().next()
                });
                let next = next.and_then(|g| {
                    g.range().filter_map(|i| index.entry(i)).map(|(_, l)| l).find(|l| !seen.contains(l))
                });
                match next {
                    Some(l) => {
                        loc = l;
                        continue;
                    }
                    None => {
                        return Ok(format!(
                            "<p class=\"sg-redirect\">See <a href=\"entry://{0}\">{1}</a></p>",
                            crate::util::url_encode_component(target),
                            crate::util::html_escape(target)
                        ))
                    }
                }
            }
            return Ok(rewrite_links(&self.apply_stylesheet(&text)));
        }
        bail!("redirect loop")
    }

    fn resource(&self, path: &str) -> Result<Option<Vec<u8>>> {
        // Files next to the .mdx take precedence (stylesheets, scripts shipped separately).
        if let Some(p) = file_below(&self.dir, path) {
            return Ok(Some(std::fs::read(p)?));
        }
        let key = mdd_key(path);
        for (file, idx) in &self.volumes {
            if let Some(g) = idx.get(&key) {
                if let Some((_, loc)) = idx.entry(g.start) {
                    return Ok(Some(file.record(loc.a, loc.b)?));
                }
            }
        }
        Ok(None)
    }

    fn foreign(&self) -> bool {
        true
    }
}

/// Rewrites MDict-specific URL forms into ones the article view understands.
fn rewrite_links(html: &str) -> String {
    let mut out = html.replace("entry://#", "#");
    if out.contains("file://") {
        out = out.replace("\"file://", "\"").replace("'file://", "'");
    }
    out
}

/// A v2 .mdx: header, the key section's five numbers, then `rest` as it is.
#[cfg(test)]
pub(crate) fn crafted_mdx(key_section: [u64; 5], rest: &[u8]) -> Vec<u8> {
    let header: Vec<u8> = r#"<Dictionary GeneratedByEngineVersion="2.0" Title="crafted"/>"#
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    let mut f = (header.len() as u32).to_be_bytes().to_vec();
    f.extend_from_slice(&header);
    f.extend_from_slice(&[0; 4]);
    for n in key_section {
        f.extend_from_slice(&n.to_be_bytes());
    }
    f.extend_from_slice(&[0; 4]);
    f.extend_from_slice(rest);
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_crafted(name: &str, bytes: &[u8]) -> Result<MdictFile> {
        let p = std::env::temp_dir().join(format!("sg-crafted-{name}-{}.mdx", std::process::id()));
        std::fs::write(&p, bytes).unwrap();
        let r = MdictFile::open(&p, false).and_then(|m| m.read_entries().map(|_| m));
        let _ = std::fs::remove_file(&p);
        r
    }

    /// Key-block info as one stored block of 8 bytes, then `records`.
    fn sections(records: &[u64]) -> Vec<u8> {
        let mut b = vec![0; 8];
        b.extend_from_slice(&[0; 8]);
        for n in records {
            b.extend_from_slice(&n.to_be_bytes());
        }
        b
    }

    #[test]
    fn malformed_sizes_fail_instead_of_allocating() {
        let empty_records = [0, 0, 0, 0];
        // The well-formed baseline: no keys, no records.
        let ok = crafted_mdx([0, 0, 8, 16, 0], &sections(&empty_records));
        assert!(open_crafted("ok", &ok).unwrap().read_keys().unwrap().is_empty());
        // Key-section sizes that wrap around u64 to land back inside the file.
        let wrap = crafted_mdx([0, 0, 0, 0x4000_0000_0000_0000, 0xC000_0000_0000_0000], &sections(&empty_records));
        assert!(open_crafted("wrap", &wrap).is_err());
        // Key-block info past the end of the file.
        assert!(open_crafted("past", &crafted_mdx([0, 0, 8, 1 << 40, 0], &sections(&empty_records))).is_err());
        // Key-block info claiming to inflate to a terabyte.
        assert!(open_crafted("bomb", &crafted_mdx([0, 0, 1 << 40, 16, 0], &sections(&empty_records))).is_err());
        // A record block of 16 bytes claiming a terabyte.
        let records = sections(&[1, 1, 16, 16, 16, 1 << 40, 0, 0]);
        assert!(open_crafted("records", &crafted_mdx([0, 0, 8, 16, 0], &records)).is_err());
    }

    #[test]
    fn attrs() {
        let a = parse_attrs(r#"<Dictionary GeneratedByEngineVersion="2.0" Title="A &amp; B" Encrypted="2"/>"#);
        assert_eq!(a["Title"], "A & B");
        assert_eq!(a["Encrypted"], "2");
    }
    #[test]
    fn mddkey() {
        assert_eq!(mdd_key("/Images/A.PNG"), b"\\images\\a.png".to_vec());
        assert_eq!(mdd_key("x.css"), b"\\x.css".to_vec());
    }
}
