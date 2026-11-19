//! Lenient tag tokenizer plus converters from XDXF and Pango markup to HTML.

use crate::util::{html_escape, html_escape_into, is_audio, is_image, unescape_entities, url_encode_component, url_encode_path};

#[derive(Debug, PartialEq)]
pub enum Tok<'a> {
    Text(&'a str),
    Open { name: String, attrs: Vec<(String, String)>, selfclose: bool, raw: &'a str },
    Close { name: String, raw: &'a str },
    Other(&'a str), // comments, doctype, processing instructions
}

pub fn tokenize(s: &str) -> Vec<Tok<'_>> {
    let mut out = Vec::new();
    let b = s.as_bytes();
    let mut i = 0;
    let mut text_start = 0;
    while i < b.len() {
        if b[i] != b'<' {
            i += 1;
            continue;
        }
        let rest = &s[i..];
        if rest.starts_with("<!--") {
            let end = rest.find("-->").map(|e| i + e + 3).unwrap_or(b.len());
            if text_start < i {
                out.push(Tok::Text(&s[text_start..i]));
            }
            out.push(Tok::Other(&s[i..end]));
            i = end;
            text_start = i;
            continue;
        }
        let next = b.get(i + 1).copied().unwrap_or(0);
        let is_close = next == b'/';
        let name_start = if is_close { i + 2 } else { i + 1 };
        let valid = match b.get(name_start) {
            Some(c) => c.is_ascii_alphabetic() || (!is_close && (*c == b'!' || *c == b'?')),
            None => false,
        };
        if !valid {
            i += 1;
            continue;
        }
        // find tag end, respecting quotes
        let mut j = name_start;
        let mut quote = 0u8;
        while j < b.len() {
            let c = b[j];
            if quote != 0 {
                if c == quote {
                    quote = 0;
                }
            } else if c == b'"' || c == b'\'' {
                quote = c;
            } else if c == b'>' {
                break;
            } else if c == b'<' {
                break; // malformed; stop here
            }
            j += 1;
        }
        if j >= b.len() || b[j] != b'>' {
            i += 1;
            continue;
        }
        if text_start < i {
            out.push(Tok::Text(&s[text_start..i]));
        }
        let raw = &s[i..=j];
        let inner = &s[name_start..j];
        if b[name_start] == b'!' || b[name_start] == b'?' {
            out.push(Tok::Other(raw));
        } else {
            let name_end = inner.find(|c: char| c.is_whitespace() || c == '/').unwrap_or(inner.len());
            let name = inner[..name_end].to_ascii_lowercase();
            if is_close {
                out.push(Tok::Close { name, raw });
            } else {
                let attr_src = &inner[name_end..];
                let selfclose = attr_src.trim_end().ends_with('/');
                out.push(Tok::Open { name, attrs: parse_attrs(attr_src.trim_end_matches('/')), selfclose, raw });
            }
        }
        i = j + 1;
        text_start = i;
    }
    if text_start < b.len() {
        out.push(Tok::Text(&s[text_start..]));
    }
    out
}

pub fn parse_attrs(s: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b'/') {
            i += 1;
        }
        let ns = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' && b[i] != b'/' {
            i += 1;
        }
        if ns == i {
            i += 1;
            continue;
        }
        let name = s[ns..i].to_ascii_lowercase();
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i].is_ascii_whitespace() {
                i += 1;
            }
            let val = if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
                let q = b[i];
                let vs = i + 1;
                i = vs;
                while i < b.len() && b[i] != q {
                    i += 1;
                }
                let v = &s[vs..i.min(b.len())];
                i += 1;
                v
            } else {
                let vs = i;
                while i < b.len() && !b[i].is_ascii_whitespace() {
                    i += 1;
                }
                &s[vs..i]
            };
            out.push((name, unescape_entities(val)));
        } else {
            out.push((name, String::new()));
        }
    }
    out
}

pub fn attr<'a>(attrs: &'a [(String, String)], name: &str) -> Option<&'a str> {
    attrs.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
}

/// Plain text of a token range (tags stripped, entities decoded).
fn plain(toks: &[Tok]) -> String {
    let mut s = String::new();
    for t in toks {
        if let Tok::Text(x) = t {
            s.push_str(x);
        }
    }
    unescape_entities(&s)
}

/// Index of the matching close tag for the open tag at `i`.
fn matching_close(toks: &[Tok], i: usize, name: &str) -> Option<usize> {
    let mut depth = 0;
    for (j, t) in toks.iter().enumerate().skip(i + 1) {
        match t {
            Tok::Open { name: n, selfclose: false, .. } if n == name => depth += 1,
            Tok::Close { name: n, .. } if n == name => {
                if depth == 0 {
                    return Some(j);
                }
                depth -= 1;
            }
            _ => {}
        }
    }
    None
}

pub fn sanitize_color(c: &str) -> Option<String> {
    let c = c.trim();
    if c.is_empty() || c.len() > 32 {
        return None;
    }
    c.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '#').then(|| c.to_ascii_lowercase())
}

pub fn media_html(out: &mut String, file: &str) {
    let file = file.trim();
    if file.is_empty() {
        return;
    }
    if is_audio(file) {
        out.push_str("<a class=\"sg-snd\" href=\"sound://");
        out.push_str(&html_escape(&url_encode_path(file)));
        out.push_str("\" title=\"Play\" aria-label=\"Play pronunciation\"></a>");
    } else if is_image(file) {
        out.push_str("<img class=\"sg-img\" loading=\"lazy\" src=\"");
        out.push_str(&html_escape(&url_encode_path(file)));
        out.push_str("\" alt=\"\">");
    } else {
        out.push_str("<a class=\"sg-file\" href=\"");
        out.push_str(&html_escape(&url_encode_path(file)));
        out.push_str("\">");
        html_escape_into(out, file);
        out.push_str("</a>");
    }
}

pub fn entry_link(out: &mut String, target: &str, inner_html: &str, class: &str) {
    out.push_str("<a class=\"");
    out.push_str(class);
    out.push_str("\" href=\"entry://");
    out.push_str(&html_escape(&url_encode_component(target.trim())));
    out.push_str("\">");
    out.push_str(inner_html);
    out.push_str("</a>");
}

const BLOCK: &[&str] = &["blockquote", "div", "def", "p", "ul", "ol", "li", "table", "tr", "hr", "h1", "h2", "h3", "h4"];

fn is_block(t: &Tok, xdxf: bool) -> bool {
    match t {
        Tok::Open { name, .. } | Tok::Close { name, .. } => {
            if xdxf && name == "tr" {
                return false; // transcription in XDXF
            }
            BLOCK.contains(&name.as_str())
        }
        _ => false,
    }
}

/// Converts XDXF (visual or logical) article markup to HTML.
pub fn xdxf_to_html(src: &str) -> String {
    let toks = tokenize(src);
    let mut out = String::with_capacity(src.len() + src.len() / 4);
    render_xdxf(&toks, &mut out, true);
    out
}

fn render_xdxf(toks: &[Tok], out: &mut String, top: bool) {
    let mut i = 0;
    let mut skip_nl = top; // swallow leading newlines
    while i < toks.len() {
        match &toks[i] {
            Tok::Text(t) => {
                let mut first = true;
                for line in t.split('\n') {
                    if !first {
                        let prev_block = out.ends_with('>') && last_tag_is_block(out);
                        let next_block = line.trim().is_empty() && toks.get(i + 1).is_some_and(|n| is_block(n, true));
                        if !(skip_nl || prev_block || next_block) {
                            out.push_str("<br>");
                        }
                    }
                    first = false;
                    let l = if skip_nl { line.trim_start() } else { line };
                    if !l.is_empty() {
                        skip_nl = false;
                    }
                    let l = l.replace('\r', "");
                    // XDXF text is XML: entities are fine as-is; escape stray angle brackets.
                    out.push_str(&l.replace('<', "&lt;"));
                }
            }
            Tok::Other(_) => {}
            Tok::Close { name, .. } => {
                if let Some(c) = close_for(name) {
                    out.push_str(c);
                }
            }
            Tok::Open { name, attrs, selfclose, .. } => {
                let name = name.as_str();
                let end = if *selfclose { None } else { matching_close(toks, i, name) };
                match name {
                    "k" => {
                        // Headwords are rendered by the article header.
                        if let Some(e) = end {
                            i = e + 1;
                            skip_nl = true;
                            continue;
                        }
                    }
                    "nu" => {
                        if let Some(e) = end {
                            i = e + 1;
                            continue;
                        }
                    }
                    "kref" => {
                        if let Some(e) = end {
                            let inner = &toks[i + 1..e];
                            let target = attr(attrs, "k").map(str::to_string).unwrap_or_else(|| plain(inner));
                            let mut ih = String::new();
                            render_xdxf(inner, &mut ih, false);
                            entry_link(out, &target, &ih, "x-kref");
                            i = e + 1;
                            skip_nl = false;
                            continue;
                        }
                    }
                    "rref" => {
                        let file = match end {
                            Some(e) => {
                                let f = attr(attrs, "lctn").map(str::to_string).unwrap_or_else(|| plain(&toks[i + 1..e]));
                                i = e + 1;
                                f
                            }
                            None => {
                                i += 1;
                                attr(attrs, "lctn").unwrap_or("").to_string()
                            }
                        };
                        media_html(out, &file);
                        continue;
                    }
                    "iref" => {
                        let href = attr(attrs, "href").unwrap_or("");
                        if let Some(e) = end {
                            let inner = &toks[i + 1..e];
                            let href = if href.is_empty() { plain(inner) } else { href.to_string() };
                            out.push_str("<a class=\"x-iref\" href=\"");
                            html_escape_into(out, &href);
                            out.push_str("\">");
                            render_xdxf(inner, out, false);
                            out.push_str("</a>");
                            i = e + 1;
                            continue;
                        }
                    }
                    "c" => {
                        match attr(attrs, "c").and_then(sanitize_color) {
                            Some(c) => {
                                out.push_str("<span class=\"c\" style=\"--c:");
                                out.push_str(&c);
                                out.push_str("\">");
                            }
                            None => out.push_str("<span class=\"c\">"),
                        }
                        if *selfclose {
                            out.push_str("</span>");
                        }
                    }
                    "img" => {
                        if let Some(src) = attr(attrs, "src") {
                            out.push_str("<img class=\"sg-img\" loading=\"lazy\" src=\"");
                            html_escape_into(out, src);
                            out.push_str("\" alt=\"\">");
                        }
                    }
                    "br" => out.push_str("<br>"),
                    "hr" => out.push_str("<hr>"),
                    _ => {
                        if let Some(o) = open_for(name) {
                            out.push_str(o);
                            if *selfclose {
                                if let Some(c) = close_for(name) {
                                    out.push_str(c);
                                }
                            }
                        }
                    }
                }
                skip_nl = false;
            }
        }
        i += 1;
    }
}

fn last_tag_is_block(out: &str) -> bool {
    let Some(lt) = out.rfind('<') else { return false };
    let tag = &out[lt + 1..out.len() - 1];
    let tag = tag.trim_start_matches('/');
    let name = tag.split(|c: char| c.is_whitespace() || c == '>').next().unwrap_or("");
    matches!(name, "div" | "hr" | "br" | "p" | "ul" | "ol" | "li" | "table")
}

fn open_for(name: &str) -> Option<&'static str> {
    Some(match name {
        "b" | "strong" => "<b>",
        "i" | "em" => "<i>",
        "u" => "<u>",
        "s" | "strike" => "<s>",
        "sub" => "<sub>",
        "sup" => "<sup>",
        "tt" | "code" => "<code>",
        "big" => "<span class=\"x-big\">",
        "small" => "<small>",
        "blockquote" => "<div class=\"x-bq\">",
        "div" => "<div>",
        "p" => "<p>",
        "def" => "<div class=\"x-def\">",
        "abr" => "<abbr class=\"x-abr\">",
        "ex" => "<span class=\"x-ex\">",
        "co" => "<span class=\"x-co\">",
        "dtrn" => "<span class=\"x-dtrn\">",
        "tr" => "<span class=\"x-tr\">",
        "opt" => "<span class=\"x-opt\">",
        "pos" => "<span class=\"x-pos\">",
        "gr" => "<span class=\"x-gr\">",
        "tense" => "<span class=\"x-tense\">",
        "etm" => "<span class=\"x-etm\">",
        "categ" => "<span class=\"x-categ\">",
        "sr" | "syn" | "ant" | "hpr" | "hpn" | "mer" | "par" | "rel" => "<span class=\"x-rel\">",
        "deftext" | "ex_orig" | "ex_tran" | "mrkd" | "di" | "span" => "<span>",
        "ul" => "<ul>",
        "ol" => "<ol>",
        "li" => "<li>",
        _ => return None,
    })
}

fn close_for(name: &str) -> Option<&'static str> {
    Some(match name {
        "b" | "strong" => "</b>",
        "i" | "em" => "</i>",
        "u" => "</u>",
        "s" | "strike" => "</s>",
        "sub" => "</sub>",
        "sup" => "</sup>",
        "tt" | "code" => "</code>",
        "small" => "</small>",
        "blockquote" | "div" | "def" => "</div>",
        "p" => "</p>",
        "abr" => "</abbr>",
        "c" | "big" | "ex" | "co" | "dtrn" | "tr" | "opt" | "pos" | "gr" | "tense" | "etm" | "categ" | "sr" | "syn"
        | "ant" | "hpr" | "hpn" | "mer" | "par" | "rel" | "deftext" | "ex_orig" | "ex_tran" | "mrkd" | "di"
        | "span" => "</span>",
        "ul" => "</ul>",
        "ol" => "</ol>",
        "li" => "</li>",
        _ => return None,
    })
}

/// Converts Pango markup to HTML.
pub fn pango_to_html(src: &str) -> String {
    let mut out = String::with_capacity(src.len() + 32);
    for t in tokenize(src) {
        match t {
            Tok::Text(x) => out.push_str(&x.replace('<', "&lt;").replace('\n', "<br>")),
            Tok::Other(_) => {}
            Tok::Open { name, attrs, selfclose, .. } => {
                let tag = match name.as_str() {
                    "span" | "font" => {
                        let mut style = String::new();
                        for (k, v) in &attrs {
                            match k.as_str() {
                                "foreground" | "fgcolor" | "color" => {
                                    if let Some(c) = sanitize_color(v) {
                                        style.push_str(&format!("color:{c};"));
                                    }
                                }
                                "background" | "bgcolor" => {
                                    if let Some(c) = sanitize_color(v) {
                                        style.push_str(&format!("background:{c};"));
                                    }
                                }
                                "weight" if v == "bold" || v == "heavy" => style.push_str("font-weight:bold;"),
                                "style" if v == "italic" => style.push_str("font-style:italic;"),
                                "underline" if v != "none" => style.push_str("text-decoration:underline;"),
                                _ => {}
                            }
                        }
                        format!("<span style=\"{style}\">")
                    }
                    "b" | "i" | "u" | "s" | "sub" | "sup" | "small" | "tt" => format!("<{name}>"),
                    "big" => "<span class=\"x-big\">".into(),
                    _ => String::new(),
                };
                out.push_str(&tag);
                if selfclose && !tag.is_empty() {
                    out.push_str("</span>");
                }
            }
            Tok::Close { name, .. } => match name.as_str() {
                "span" | "font" | "big" => out.push_str("</span>"),
                "b" | "i" | "u" | "s" | "sub" | "sup" | "small" | "tt" => out.push_str(&format!("</{name}>")),
                _ => {}
            },
        }
    }
    out
}

pub fn plain_to_html(src: &str) -> String {
    let mut out = String::with_capacity(src.len() + 16);
    for (i, line) in src.split('\n').enumerate() {
        if i > 0 {
            out.push_str("<br>");
        }
        html_escape_into(&mut out, line.trim_end_matches('\r'));
    }
    out
}

/// Replaces `bword://` links (StarDict/Babylon convention) with `entry://`.
pub fn normalize_links(html: &str) -> String {
    if html.contains("bword://") {
        html.replace("bword://", "entry://")
    } else {
        html.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens() {
        let t = tokenize("a<b>c</b><c c=\"red\">x</c> 1 < 2 <br/>");
        assert_eq!(t.len(), 9);
        assert!(matches!(&t[1], Tok::Open { name, .. } if name == "b"));
        assert!(matches!(&t[7], Tok::Text(" 1 < 2 ")));
        assert!(matches!(&t[8], Tok::Open { selfclose: true, .. }));
    }

    #[test]
    fn xdxf() {
        let h = xdxf_to_html("<k>apple</k>\n<b>ap·ple</b>\n<abr>n.</abr> See <kref>pear</kref>\n<blockquote>x</blockquote>\n<c c=\"darkred\">y</c><rref>a.jpg</rref>");
        assert!(!h.contains("apple</"));
        assert!(h.contains("<a class=\"x-kref\" href=\"entry://pear\">pear</a>"));
        assert!(h.contains("<div class=\"x-bq\">x</div>"));
        assert!(h.contains("--c:darkred"));
        assert!(h.contains("src=\"a.jpg\""));
        assert!(h.starts_with("<b>"));
    }

    #[test]
    fn pango() {
        assert_eq!(pango_to_html("<span foreground=\"blue\">x</span>\ny"), "<span style=\"color:blue;\">x</span><br>y");
    }
}
