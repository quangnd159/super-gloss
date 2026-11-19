//! StarDict (.ifo/.idx[.gz]/.dict[.dz]/.syn) reader.

use super::markup::{media_html, normalize_links, pango_to_html, plain_to_html, xdxf_to_html};
use super::{BuildCtx, DictInfo, Reader};
use crate::index::{Index, IndexBuilder, Locator};
use crate::store::{read_maybe_gzip, Source};
use crate::util::{be32, be64, html_escape, safe_join};
use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn parse_ifo(path: &Path) -> Result<HashMap<String, String>> {
    let raw = std::fs::read(path)?;
    let text = String::from_utf8_lossy(&raw);
    let mut lines = text.lines();
    let magic = lines.next().unwrap_or("").trim_start_matches('\u{feff}').trim();
    if magic != "StarDict's dict ifo file" && magic != "StarDict's storage ifo file" {
        bail!("not a StarDict .ifo file");
    }
    let mut m = HashMap::new();
    for l in lines {
        if let Some((k, v)) = l.split_once('=') {
            m.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    Ok(m)
}

fn find_with_ext(base: &Path, exts: &[&str]) -> Option<PathBuf> {
    exts.iter().map(|e| PathBuf::from(format!("{}.{e}", base.display()))).find(|p| p.is_file())
}

fn base_of(ifo: &Path) -> PathBuf {
    ifo.with_extension("")
}

pub fn companion_files(ifo: &Path) -> Vec<PathBuf> {
    let b = base_of(ifo);
    [&["idx", "idx.gz", "idx.dz"][..], &["dict", "dict.dz"], &["syn", "syn.dz"]]
        .iter()
        .filter_map(|e| find_with_ext(&b, e))
        .collect()
}

pub fn build(ifo: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    let meta = parse_ifo(ifo)?;
    let base = base_of(ifo);
    let idx_path = find_with_ext(&base, &["idx", "idx.gz", "idx.dz"]).context("missing .idx file")?;
    let dict_path = find_with_ext(&base, &["dict", "dict.dz"]).context("missing .dict file")?;
    let off64 = meta.get("idxoffsetbits").map(|v| v == "64").unwrap_or(false);
    let idx = read_maybe_gzip(&idx_path)?;
    let w = if off64 { 8 } else { 4 };
    let mut b = IndexBuilder::new();
    let mut locs = Vec::new();
    let mut p = 0;
    while p < idx.len() {
        let e = idx[p..].iter().position(|&c| c == 0).context("truncated .idx")? + p;
        let word = String::from_utf8_lossy(&idx[p..e]).into_owned();
        let q = e + 1;
        if q + w + 4 > idx.len() {
            bail!("truncated .idx entry");
        }
        let off = if off64 { be64(&idx[q..]) } else { be32(&idx[q..]) as u64 };
        let size = be32(&idx[q + w..]) as u64;
        p = q + w + 4;
        let loc = Locator { a: off, b: size };
        b.add(&word, loc);
        locs.push(loc);
    }
    ctx.progress(0.6);
    if let Some(syn) = find_with_ext(&base, &["syn", "syn.dz"]) {
        let data = read_maybe_gzip(&syn)?;
        let mut p = 0;
        while p < data.len() {
            let Some(e) = data[p..].iter().position(|&c| c == 0).map(|e| e + p) else { break };
            if e + 5 > data.len() {
                break;
            }
            let word = String::from_utf8_lossy(&data[p..e]).into_owned();
            let i = be32(&data[e + 1..]) as usize;
            if let Some(loc) = locs.get(i) {
                b.add(&word, *loc);
            }
            p = e + 5;
        }
    }
    let count = b.len();
    b.write(ctx.dir, "keys")?;
    // Prepare random access (decompresses non-dictzip .gz once into the cache).
    let _ = Source::open(&dict_path, ctx.dir, "dict", true)?;
    let mut info = DictInfo::new(
        meta.get("bookname").cloned().filter(|s| !s.is_empty()).unwrap_or_else(|| {
            ifo.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
        }),
        "StarDict",
    );
    info.description = meta.get("description").cloned().unwrap_or_default().replace("<br>", "\n");
    info.author = meta.get("author").cloned().unwrap_or_default();
    info.entries = count as u64;
    info.extra = serde_json::json!({
        "sametypesequence": meta.get("sametypesequence").cloned().unwrap_or_default(),
    });
    Ok(info)
}

pub struct StarDictReader {
    data: Source,
    types: Vec<u8>,
    res_dir: PathBuf,
}

pub fn open(ifo: &Path, cache: &Path, info: &DictInfo) -> Result<Box<dyn Reader>> {
    let base = base_of(ifo);
    let dict_path = find_with_ext(&base, &["dict", "dict.dz"]).context("missing .dict file")?;
    let data = Source::open(&dict_path, cache, "dict", false)?;
    let types = info.extra.get("sametypesequence").and_then(|v| v.as_str()).unwrap_or("").as_bytes().to_vec();
    Ok(Box::new(StarDictReader { data, types, res_dir: ifo.parent().unwrap_or(Path::new("/")).join("res") }))
}

/// Splits an article into (type, payload) fields.
pub fn split_fields<'a>(data: &'a [u8], types: &[u8]) -> Vec<(u8, &'a [u8])> {
    let mut out = Vec::new();
    let mut p = 0;
    let take = |t: u8, last: bool, p: &mut usize| -> Option<&'a [u8]> {
        let rest = &data[(*p).min(data.len())..];
        if last {
            *p = data.len();
            return Some(rest);
        }
        if t.is_ascii_uppercase() {
            if rest.len() < 4 {
                return None;
            }
            let n = be32(rest) as usize;
            let v = rest.get(4..4 + n)?;
            *p += 4 + n;
            Some(v)
        } else {
            let e = rest.iter().position(|&c| c == 0).unwrap_or(rest.len());
            *p += e + 1;
            Some(&rest[..e])
        }
    };
    if !types.is_empty() {
        for (i, &t) in types.iter().enumerate() {
            match take(t, i + 1 == types.len(), &mut p) {
                Some(v) => out.push((t, v)),
                None => break,
            }
        }
    } else {
        while p < data.len() {
            let t = data[p];
            p += 1;
            match take(t, false, &mut p) {
                Some(v) => out.push((t, v)),
                None => break,
            }
        }
    }
    out
}

pub fn render_field(t: u8, v: &[u8], out: &mut String) {
    let text = || String::from_utf8_lossy(v).trim_end_matches('\0').to_string();
    match t {
        b'h' => out.push_str(&normalize_links(&text())),
        b'x' => out.push_str(&xdxf_to_html(&text())),
        b'g' => out.push_str(&pango_to_html(&text())),
        b't' => {
            out.push_str("<div class=\"sd-t\">[");
            out.push_str(&html_escape(&text()));
            out.push_str("]</div>");
        }
        b'y' => {
            out.push_str("<div class=\"sd-t\">");
            out.push_str(&html_escape(&text()));
            out.push_str("</div>");
        }
        b'r' => {
            for line in text().lines() {
                let item = line.split_once(':').map(|(_, f)| f).unwrap_or(line);
                media_html(out, item);
            }
        }
        b'P' => {
            use std::fmt::Write;
            let _ = write!(out, "<img class=\"sg-img\" src=\"data:image/png;base64,{}\" alt=\"\">", base64(v));
        }
        b'W' | b'X' => {}
        b'k' => {
            // KingSoft XML: show its text content.
            let s = text();
            let plain: String = super::markup::tokenize(&s)
                .into_iter()
                .filter_map(|t| if let super::markup::Tok::Text(x) = t { Some(x) } else { None })
                .collect();
            out.push_str(&plain_to_html(&crate::util::unescape_entities(&plain)));
        }
        _ => {
            out.push_str("<div class=\"sd-m\">");
            out.push_str(&plain_to_html(&text()));
            out.push_str("</div>");
        }
    }
}

fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        s.push(T[(n >> 18) as usize & 63] as char);
        s.push(T[(n >> 12) as usize & 63] as char);
        s.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        s.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    s
}

impl Reader for StarDictReader {
    fn article(&self, _index: &Index, _word: &str, loc: Locator) -> Result<String> {
        let raw = self.data.read(loc.a, loc.b)?;
        let mut out = String::with_capacity(raw.len() + raw.len() / 3);
        for (t, v) in split_fields(&raw, &self.types) {
            render_field(t, v, &mut out);
        }
        Ok(out)
    }

    fn resource(&self, path: &str) -> Result<Option<Vec<u8>>> {
        let Some(p) = safe_join(&self.res_dir, path) else { return Ok(None) };
        if p.is_file() {
            return Ok(Some(std::fs::read(p)?));
        }
        // Case-insensitive fallback for files on case-sensitive volumes.
        if let (Some(parent), Some(name)) = (p.parent(), p.file_name()) {
            if let Some(f) = crate::util::find_case_insensitive(parent, &name.to_string_lossy()) {
                return Ok(Some(std::fs::read(f)?));
            }
        }
        Ok(None)
    }

    fn foreign(&self) -> bool {
        self.types.first() == Some(&b'h')
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fields() {
        let f = split_fields(b"abc", b"m");
        assert_eq!(f, vec![(b'm', &b"abc"[..])]);
        let f = split_fields(b"t1\0body", b"tm");
        assert_eq!(f, vec![(b't', &b"t1"[..]), (b'm', &b"body"[..])]);
        let f = split_fields(b"mhello\0W\0\0\0\x02xy", b"");
        assert_eq!(f, vec![(b'm', &b"hello"[..]), (b'W', &b"xy"[..])]);
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(b"Ma"), "TWE=");
    }
}
