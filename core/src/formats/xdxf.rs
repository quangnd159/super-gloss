//! Standalone XDXF dictionary files (`.xdxf`, `.xdxf.dz`).

use super::markup::{tokenize, xdxf_to_html, Tok};
use super::{BuildCtx, DictInfo, Reader};
use crate::index::{Index, IndexBuilder, Locator};
use crate::store::Source;
use crate::util::{file_below, unescape_entities};
use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

fn tag_text(doc: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}");
    let s = doc.find(&open)?;
    let gt = doc[s..].find('>')? + s + 1;
    let close = format!("</{tag}>");
    let e = doc[gt..].find(&close)? + gt;
    Some(unescape_entities(doc[gt..e].trim()))
}

/// Extracts headwords from the `<k>` elements of an article. `<opt>` parts give
/// variants with and without the optional text.
fn keys_of(ar: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = ar;
    while let Some(s) = rest.find("<k") {
        let after = &rest[s + 2..];
        if !after.starts_with('>') && !after.starts_with(' ') {
            rest = after;
            continue;
        }
        let Some(gt) = after.find('>') else { break };
        let body_start = &after[gt + 1..];
        let Some(e) = body_start.find("</k>") else { break };
        let inner = &body_start[..e];
        let (mut with, mut without) = (String::new(), String::new());
        let mut in_opt = 0;
        for t in tokenize(inner) {
            match t {
                Tok::Text(x) => {
                    with.push_str(x);
                    if in_opt == 0 {
                        without.push_str(x);
                    }
                }
                Tok::Open { name, .. } if name == "opt" => in_opt += 1,
                Tok::Close { name, .. } if name == "opt" => in_opt -= 1,
                _ => {}
            }
        }
        for v in [with, without] {
            let v = unescape_entities(&v.split_whitespace().collect::<Vec<_>>().join(" "));
            if !v.is_empty() && !out.contains(&v) {
                out.push(v);
            }
        }
        rest = &body_start[e + 4..];
    }
    out
}

pub fn build(path: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    let data = Source::prepare(path, ctx.dir, "text")?;
    let doc = std::str::from_utf8(&data).map_err(|_| anyhow::anyhow!("XDXF file is not valid UTF-8"))?;
    let probe_end = (0..=doc.len().min(4096)).rev().find(|&i| doc.is_char_boundary(i)).unwrap_or(0);
    if !doc[..probe_end].contains("<xdxf") {
        bail!("not an XDXF file");
    }
    let mut b = IndexBuilder::new();
    let bytes = doc.as_bytes();
    let mut pos = 0;
    while let Some(s) = doc[pos..].find("<ar") {
        let s = pos + s;
        let next = bytes.get(s + 3).copied().unwrap_or(0);
        if next != b'>' && next != b' ' {
            pos = s + 3;
            continue;
        }
        let Some(e) = doc[s..].find("</ar>") else { break };
        let e = s + e + 5;
        let ar = &doc[s..e];
        let loc = Locator { a: s as u64, b: (e - s) as u64 };
        for k in keys_of(ar) {
            b.add(&k, loc);
        }
        pos = e;
    }
    let head = &doc[..doc.find("<ar").unwrap_or(doc.len()).min(doc.len())];
    let name = tag_text(head, "full_title")
        .or_else(|| tag_text(head, "full_name"))
        .or_else(|| tag_text(head, "title"))
        .unwrap_or_else(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
    let mut info = DictInfo::new(name, "XDXF");
    info.description = tag_text(head, "description").unwrap_or_default();
    info.entries = b.len() as u64;
    b.write(ctx.dir, "keys")?;
    Ok(info)
}

pub struct XdxfReader {
    text: Source,
    dir: PathBuf,
}

pub fn open(path: &Path, cache: &Path, _info: &DictInfo) -> Result<Box<dyn Reader>> {
    Ok(Box::new(XdxfReader {
        text: Source::open(path, cache, "text", false)?,
        dir: path.parent().unwrap_or(Path::new("/")).to_path_buf(),
    }))
}

impl Reader for XdxfReader {
    fn article(&self, _index: &Index, _word: &str, loc: Locator) -> Result<String> {
        let raw = self.text.read(loc.a, loc.b)?;
        let s = String::from_utf8_lossy(&raw);
        // strip the <ar ...> wrapper
        let inner = s.find('>').map(|i| &s[i + 1..]).unwrap_or(&s);
        let inner = inner.strip_suffix("</ar>").unwrap_or(inner);
        Ok(xdxf_to_html(inner))
    }
    fn resource(&self, path: &str) -> Result<Option<Vec<u8>>> {
        match file_below(&self.dir, path) {
            Some(p) => Ok(Some(std::fs::read(p)?)),
            None => Ok(None),
        }
    }
    fn foreign(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keys() {
        assert_eq!(keys_of("<ar><k>apple</k><k><opt>the</opt> pie</k> x</ar>"), vec!["apple", "the pie", "pie"]);
    }
}
