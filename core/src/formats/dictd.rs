//! dictd (.index + .dict / .dict.dz) reader.

use super::{BuildCtx, DictInfo, Reader};
use crate::index::{Index, IndexBuilder, Locator};
use crate::store::Source;
use crate::util::{html_escape, html_escape_into, url_encode_component};
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

fn b64num(s: &str) -> Option<u64> {
    let mut n: u64 = 0;
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u64;
        n = n.checked_mul(64)?.checked_add(v)?;
    }
    Some(n)
}

pub fn data_path(index: &Path) -> Option<PathBuf> {
    let base = index.with_extension("");
    ["dict.dz", "dict"]
        .iter()
        .map(|e| PathBuf::from(format!("{}.{e}", base.display())))
        .find(|p| p.is_file())
}

pub fn companion_files(index: &Path) -> Vec<PathBuf> {
    data_path(index).into_iter().collect()
}

pub fn build(path: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    let data_p = data_path(path).context("missing .dict file")?;
    let text = std::fs::read(path)?;
    let text = String::from_utf8_lossy(&text);
    let src = Source::open(&data_p, ctx.dir, "dict", true)?;
    let mut b = IndexBuilder::new();
    let mut short_name = None;
    let mut info_loc = None;
    for line in text.lines() {
        let mut parts = line.split('\t');
        let (Some(w), Some(o), Some(l)) = (parts.next(), parts.next(), parts.next()) else { continue };
        let (Some(o), Some(l)) = (b64num(o.trim()), b64num(l.trim())) else { continue };
        let loc = Locator { a: o, b: l };
        let wl = w.to_ascii_lowercase();
        if wl.starts_with("00-database-") || wl.starts_with("00database") {
            if wl.contains("short") {
                short_name = Some(loc);
            } else if wl.contains("info") {
                info_loc = Some(loc);
            }
            continue;
        }
        b.add(w, loc);
    }
    if b.is_empty() {
        bail!("empty dictd index");
    }
    let read_text = |l: Locator| -> String {
        src.read(l.a, l.b).map(|v| String::from_utf8_lossy(&v).into_owned()).unwrap_or_default()
    };
    let mut name = short_name.map(read_text).unwrap_or_default();
    // The short-name entry usually repeats the key on its first line.
    if let Some(first) = name.lines().next() {
        if first.to_ascii_lowercase().contains("00-database-short") || first.to_ascii_lowercase().contains("00databaseshort") {
            name = name.lines().skip(1).collect::<Vec<_>>().join(" ");
        }
    }
    let name = name.trim().to_string();
    let mut info = DictInfo::new(
        if name.is_empty() { path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default() } else { name },
        "dictd",
    );
    info.description = info_loc.map(read_text).unwrap_or_default();
    info.entries = b.len() as u64;
    b.write(ctx.dir, "keys")?;
    Ok(info)
}

pub struct DictdReader {
    data: Source,
}

pub fn open(path: &Path, cache: &Path, _info: &DictInfo) -> Result<Box<dyn Reader>> {
    let data_p = data_path(path).context("missing .dict file")?;
    Ok(Box::new(DictdReader { data: Source::open(&data_p, cache, "dict", false)? }))
}

/// The entry's text without a leading line that repeats the headword.
fn body<'a>(text: &'a str, word: &str) -> &'a str {
    let text = text.trim_start_matches(['\n', '\r']);
    let (first, rest) = text.split_once('\n').unwrap_or((text, ""));
    let rest = if crate::fold::fold(first.trim()) == crate::fold::fold(word) { rest } else { text };
    let blank = rest.lines().take_while(|l| l.trim().is_empty()).map(|l| l.len() + 1).sum::<usize>();
    rest.get(blank..).unwrap_or("").trim_end()
}

/// Whether a dictd entry holds HTML, as converters such as PyGlossary write it: closing
/// tags or line breaks, not grammar in angle brackets ("<neut, n, sg>").
fn is_html(text: &str) -> bool {
    let t = text.to_ascii_lowercase();
    ["</div>", "</p>", "</b>", "</i>", "</font>", "</span>", "</a>", "<br>", "<br/>", "<br />"].iter().any(|m| t.contains(m))
}

/// Renders a dictd entry: HTML as it is, plain text with `{word}` cross-references as links.
pub fn render(text: &str, word: &str) -> String {
    let body = body(text, word);
    if is_html(body) {
        return format!("<div class=\"dictd-html\">{}</div>", super::markup::normalize_links(body));
    }
    // The indent every line shares goes; the indents between them stay.
    let indent = body.lines().filter(|l| !l.trim().is_empty()).map(|l| l.len() - l.trim_start().len()).min().unwrap_or(0);
    let body: String = body.lines().map(|l| l.get(indent..).unwrap_or(l.trim_start())).collect::<Vec<_>>().join("\n");
    let mut out = String::with_capacity(body.len() + 96);
    // A first line that opens with the headword ("Kuwait /k'u:vaɪt/ <neut, n, sg>") gives it
    // to the entry's heading and keeps the rest.
    let mut rest = body.as_str();
    if let Some(after) = rest.strip_prefix(word.trim()).filter(|a| a.starts_with([' ', '\t'])) {
        out.push_str("<h1 class=\"sg-hw\">");
        html_escape_into(&mut out, word.trim());
        out.push_str("</h1>");
        rest = after.trim_start_matches([' ', '\t']);
    }
    out.push_str("<div class=\"dictd\">");
    while let Some(o) = rest.find('{') {
        let Some(c) = rest[o..].find('}') else { break };
        let inner = &rest[o + 1..o + c];
        if inner.contains('\n') && inner.len() > 80 {
            html_escape_into(&mut out, &rest[..o + 1]);
            rest = &rest[o + 1..];
            continue;
        }
        html_escape_into(&mut out, &rest[..o]);
        let target = inner.split_whitespace().collect::<Vec<_>>().join(" ");
        out.push_str("<a class=\"dictd-ref\" href=\"entry://");
        out.push_str(&html_escape(&url_encode_component(&target)));
        out.push_str("\">");
        html_escape_into(&mut out, inner);
        out.push_str("</a>");
        rest = &rest[o + c + 1..];
    }
    html_escape_into(&mut out, rest);
    out.push_str("</div>");
    out
}

impl Reader for DictdReader {
    fn article(&self, _index: &Index, word: &str, loc: Locator) -> Result<String> {
        let raw = self.data.read(loc.a, loc.b)?;
        Ok(render(&String::from_utf8_lossy(&raw), word))
    }
    fn resource(&self, _path: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    fn foreign(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numbers() {
        assert_eq!(b64num("A"), Some(0));
        assert_eq!(b64num("B"), Some(1));
        assert_eq!(b64num("BA"), Some(64));
        assert_eq!(b64num("/"), Some(63));
        assert_eq!(b64num("*"), None);
    }
    #[test]
    fn plain() {
        let h = render("apple\n  A fruit. See {pear}.\n", "apple");
        assert_eq!(h, "<div class=\"dictd\">A fruit. See <a class=\"dictd-ref\" href=\"entry://pear\">pear</a>.</div>");
        assert_eq!(render("w\n  n 1: one\n       two\n", "w"), "<div class=\"dictd\">n 1: one\n     two</div>");
        assert!(render("Haus\n  house <neut, n, sg>", "Haus").starts_with("<div class=\"dictd\">"));
        assert_eq!(render("Kuwait /k'u:vaɪt/ <n>\n[geogr.] Kuwait", "Kuwait"),
            "<h1 class=\"sg-hw\">Kuwait</h1><div class=\"dictd\">/k&#39;u:vaɪt/ &lt;n&gt;\n[geogr.] Kuwait</div>");
        assert!(render("A\n<div>first letter</div>", "A").starts_with("<div class=\"dictd-html\"><div>first"));
    }
}
