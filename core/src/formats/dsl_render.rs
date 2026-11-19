//! DSL (ABBYY Lingvo) body markup → HTML.

use super::markup::{entry_link, media_html, sanitize_color};
use crate::util::{html_escape, html_escape_into};
use std::borrow::Cow;
use std::collections::HashMap;

/// Removes `{{ … }}` comments, carrying open-comment state across lines.
pub fn strip_comments<'a>(line: &'a str, in_comment: &mut bool) -> Cow<'a, str> {
    if !*in_comment && !line.contains("{{") {
        return Cow::Borrowed(line);
    }
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    loop {
        if *in_comment {
            match rest.find("}}") {
                Some(p) => {
                    rest = &rest[p + 2..];
                    *in_comment = false;
                }
                None => return Cow::Owned(out),
            }
        } else {
            match rest.find("{{") {
                Some(p) => {
                    out.push_str(&rest[..p]);
                    rest = &rest[p + 2..];
                    *in_comment = true;
                }
                None => {
                    out.push_str(rest);
                    return Cow::Owned(out);
                }
            }
        }
    }
}

/// Removes DSL escapes (`\x` → `x`).
pub fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some(n) => out.push(n),
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Strips `[tags]` and escapes, giving plain text (for link targets, abbreviations).
pub fn plain_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            }
            '[' => {
                // skip to ']'
                let mut closed = false;
                for n in chars.by_ref() {
                    if n == ']' {
                        closed = true;
                        break;
                    }
                }
                if !closed {
                    break;
                }
            }
            _ => out.push(c),
        }
    }
    out
}

/// Expands a raw DSL headword line into its index variants.
///
/// `{…}` (unsorted parts) are removed, `(…)` optional parts produce variants with
/// and without the part, `\x` escapes are resolved.
pub fn headword_variants(raw: &str) -> Vec<String> {
    enum Seg {
        Lit(String),
        Opt(String),
    }
    let mut segs: Vec<Seg> = Vec::new();
    let mut cur = String::new();
    let mut opt: Option<String> = None;
    let mut brace = 0usize;
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(n) = chars.next() {
                    if brace > 0 {
                        continue;
                    }
                    match &mut opt {
                        Some(o) => o.push(n),
                        None => cur.push(n),
                    }
                }
            }
            '{' => brace += 1,
            '}' if brace > 0 => brace -= 1,
            _ if brace > 0 => {}
            '(' if opt.is_none() => {
                segs.push(Seg::Lit(std::mem::take(&mut cur)));
                opt = Some(String::new());
            }
            ')' if opt.is_some() => {
                segs.push(Seg::Opt(opt.take().unwrap()));
            }
            _ => match &mut opt {
                Some(o) => o.push(c),
                None => cur.push(c),
            },
        }
    }
    if let Some(o) = opt {
        // Unbalanced "(": treat literally.
        cur.push('(');
        cur.push_str(&o);
    }
    segs.push(Seg::Lit(cur));
    let nopt = segs.iter().filter(|s| matches!(s, Seg::Opt(_))).count().min(6);
    let mut out: Vec<String> = Vec::new();
    for mask in (0..(1u32 << nopt)).rev() {
        let mut s = String::new();
        let mut k = 0;
        for seg in &segs {
            match seg {
                Seg::Lit(l) => s.push_str(l),
                Seg::Opt(o) => {
                    if k >= nopt || mask & (1 << k) != 0 {
                        s.push_str(o);
                    }
                    k += 1;
                }
            }
        }
        let norm = s.split_whitespace().collect::<Vec<_>>().join(" ");
        if !norm.is_empty() && !out.contains(&norm) {
            out.push(norm);
        }
    }
    out
}

struct Open {
    name: String,
    html: String,
    close: &'static str,
}

pub struct Renderer<'a> {
    pub headword: &'a str,
    pub abbr: &'a HashMap<String, String>,
}

fn margin_prefix(t: &str) -> Option<(u8, usize)> {
    let b = t.as_bytes();
    if b.len() >= 3 && b[0] == b'[' && b[1] == b'm' {
        if b[2] == b']' {
            return Some((1, 3));
        }
        if b.len() >= 4 && b[2].is_ascii_digit() && b[3] == b']' {
            return Some((b[2] - b'0', 4));
        }
    }
    None
}

impl Renderer<'_> {
    pub fn render(&self, body: &str) -> String {
        let mut out = String::with_capacity(body.len() * 2);
        let mut stack: Vec<Open> = Vec::new();
        let mut in_comment = false;
        for raw in body.split('\n') {
            let line = raw.trim_end_matches('\r');
            let line = strip_comments(line, &mut in_comment);
            let t = line.trim_start_matches([' ', '\t', '\u{a0}', '\u{feff}']);
            if t.trim().is_empty() {
                continue;
            }
            if let Some(sub) = t.strip_prefix('@') {
                let sub = sub.trim();
                if !sub.is_empty() {
                    out.push_str("<div class=\"dsl-sub\">");
                    html_escape_into(&mut out, &plain_text(sub));
                    out.push_str("</div>");
                }
                continue;
            }
            let (m, content) = match margin_prefix(t) {
                Some((m, n)) => (Some(m), &t[n..]),
                None => (None, t),
            };
            match m {
                Some(m) => {
                    out.push_str("<div class=\"m m");
                    out.push((b'0' + m) as char);
                    out.push_str("\">");
                }
                None => out.push_str("<div class=\"m\">"),
            }
            for o in &stack {
                out.push_str(&o.html);
            }
            self.line(content, &mut stack, &mut out);
            for o in stack.iter().rev() {
                out.push_str(o.close);
            }
            out.push_str("</div>");
        }
        out
    }

    fn line(&self, s: &str, stack: &mut Vec<Open>, out: &mut String) {
        let mut i = 0;
        let b = s.as_bytes();
        while i < b.len() {
            let c = b[i];
            match c {
                b'\\' => {
                    let ch = s[i + 1..].chars().next();
                    match ch {
                        Some(ch) => {
                            html_escape_into(out, ch.encode_utf8(&mut [0; 4]));
                            i += 1 + ch.len_utf8();
                        }
                        None => {
                            out.push('\\');
                            i += 1;
                        }
                    }
                }
                b'~' => {
                    html_escape_into(out, self.headword);
                    i += 1;
                }
                b'<' if s[i..].starts_with("<<") => {
                    if let Some(e) = s[i + 2..].find(">>") {
                        let inner = &s[i + 2..i + 2 + e];
                        let target = plain_text(inner);
                        entry_link(out, &target, &html_escape(&target), "dsl-ref");
                        i += 2 + e + 2;
                    } else {
                        out.push_str("&lt;&lt;");
                        i += 2;
                    }
                }
                b'[' => match s[i + 1..].find(']') {
                    Some(e) => {
                        let tag = &s[i + 1..i + 1 + e];
                        i = self.tag(tag, s, i + 1 + e + 1, stack, out);
                    }
                    None => {
                        out.push('[');
                        i += 1;
                    }
                },
                _ => {
                    // copy a run of ordinary characters
                    let start = i;
                    while i < b.len() && !matches!(b[i], b'\\' | b'~' | b'<' | b'[') {
                        i += 1;
                    }
                    if start == i {
                        // a lone '<' not starting "<<"
                        out.push_str("&lt;");
                        i += 1;
                    } else {
                        html_escape_into(out, &s[start..i]);
                    }
                }
            }
        }
    }

    /// Handles a tag; returns the new position in `s`.
    fn tag(&self, tag: &str, s: &str, after: usize, stack: &mut Vec<Open>, out: &mut String) -> usize {
        if let Some(name) = tag.strip_prefix('/') {
            let name = name.trim();
            if let Some(k) = stack.iter().rposition(|o| o.name == name) {
                let above: Vec<Open> = stack.drain(k + 1..).collect();
                for o in above.iter().rev() {
                    out.push_str(o.close);
                }
                let o = stack.pop().unwrap();
                out.push_str(o.close);
                for o in &above {
                    out.push_str(&o.html);
                }
                stack.extend(above);
            }
            return after;
        }
        let (name, args) = match tag.find(' ') {
            Some(p) => (&tag[..p], tag[p + 1..].trim()),
            None => (tag, ""),
        };
        // Tags whose content is captured verbatim.
        if matches!(name, "s" | "url" | "ref" | "video") {
            let close = format!("[/{name}]");
            let (content, next) = match s[after..].find(&close) {
                Some(e) => (&s[after..after + e], after + e + close.len()),
                None => (&s[after..], s.len()),
            };
            match name {
                "s" | "video" => media_html(out, &unescape(content)),
                "url" => {
                    let u = plain_text(content);
                    out.push_str("<a class=\"dsl-url\" href=\"");
                    html_escape_into(out, u.trim());
                    out.push_str("\">");
                    html_escape_into(out, &u);
                    out.push_str("</a>");
                }
                _ => {
                    let t = plain_text(content);
                    let mut inner = String::new();
                    let mut st = Vec::new();
                    self.line(content, &mut st, &mut inner);
                    for o in st.iter().rev() {
                        inner.push_str(o.close);
                    }
                    entry_link(out, &t, &inner, "dsl-ref");
                }
            }
            return next;
        }
        let (html, close): (Cow<str>, &'static str) = match name {
            "b" => ("<b>".into(), "</b>"),
            "i" => ("<i>".into(), "</i>"),
            "u" => ("<u>".into(), "</u>"),
            "sup" => ("<sup>".into(), "</sup>"),
            "sub" => ("<sub>".into(), "</sub>"),
            "c" => match sanitize_color(args) {
                Some(c) => (format!("<span class=\"c\" style=\"--c:{c}\">").into(), "</span>"),
                None => ("<span class=\"c\">".into(), "</span>"),
            },
            "ex" => ("<span class=\"dsl-ex\">".into(), "</span>"),
            "com" => ("<span class=\"dsl-com\">".into(), "</span>"),
            "trn" | "trn1" | "!trn" | "!trs" | "trs" => ("<span class=\"dsl-trn\">".into(), "</span>"),
            "*" => ("<span class=\"dsl-sec\">".into(), "</span>"),
            "t" => ("<span class=\"dsl-t\">".into(), "</span>"),
            "'" => ("<span class=\"dsl-stress\">".into(), "\u{301}</span>"),
            "lang" => ("<span class=\"dsl-lang\">".into(), "</span>"),
            // [p] is a label like "n" or "VERB"; its body goes through the stack like any
            // other tag, because sources freely misnest it ("[i][c]V [p]n[/c][/i][/p]").
            "p" => {
                let body = match s[after..].find("[/p]") {
                    Some(e) => &s[after..after + e],
                    None => &s[after..],
                };
                let t = plain_text(body);
                let mut h = String::from("<abbr class=\"dsl-p\"");
                if let Some(full) = self.abbr.get(&t.trim().to_lowercase()) {
                    h.push_str(" title=\"");
                    html_escape_into(&mut h, full);
                    h.push('"');
                }
                h.push('>');
                (h.into(), "</abbr>")
            }
            "br" => {
                out.push_str("<br>");
                return after;
            }
            _ => return after, // [m], [mN] mid-line and unknown tags are dropped
        };
        out.push_str(&html);
        stack.push(Open { name: name.to_string(), html: html.into_owned(), close });
        after
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(body: &str) -> String {
        let abbr = HashMap::from([("n".to_string(), "noun".to_string())]);
        Renderer { headword: "cause", abbr: &abbr }.render(body)
    }

    #[test]
    fn variants() {
        assert_eq!(headword_variants("run(s)"), vec!["runs", "run"]);
        assert_eq!(headword_variants("{(}to{)} run"), vec!["to run"]);
        assert_eq!(headword_variants("{to }run"), vec!["run"]);
        assert_eq!(headword_variants("a\\(b\\)"), vec!["a(b)"]);
        assert_eq!(headword_variants("(a) likely story"), vec!["a likely story", "likely story"]);
        assert_eq!(headword_variants("x {[i]}y{[/i]}"), vec!["x y"]);
    }

    #[test]
    fn comments() {
        let mut c = false;
        assert_eq!(strip_comments("a{{x}}b", &mut c), "ab");
        assert_eq!(strip_comments("a{{x", &mut c), "a");
        assert!(c);
        assert_eq!(strip_comments("y}}z", &mut c), "z");
        assert!(!c);
    }

    #[test]
    fn markup() {
        let h = r("\t[m1][b]~[/b] [p]n[/p] [c red]x[/c] <<run>> \\[1\\][/m]");
        assert_eq!(
            h,
            "<div class=\"m m1\"><b>cause</b> <abbr class=\"dsl-p\" title=\"noun\">n</abbr> <span class=\"c\" style=\"--c:red\">x</span> <a class=\"dsl-ref\" href=\"entry://run\">run</a> [1]</div>"
        );
    }

    #[test]
    fn misnested_across_lines() {
        let h = r("\t[m1][i][c]also[/i] [b]cause[/b][/m]\n\t[m1][i]CONJ[/c][/i][/m]");
        assert_eq!(
            h,
            "<div class=\"m m1\"><i><span class=\"c\">also</span></i><span class=\"c\"> <b>cause</b></span></div>\
             <div class=\"m m1\"><span class=\"c\"><i>CONJ</i></span><i></i></div>"
        );
    }

    #[test]
    fn label_misnested_does_not_leak() {
        // Collins COBUILD: [c][i] are closed *inside* [p]; nothing may stay open after the line.
        let h = r("\t[m2]\\[[i][c]V [p]n[/c][/i][/p]\\] Phyllis ran.[/m]\n\t[m1]next[/m]");
        assert!(h.ends_with("<div class=\"m m1\">next</div>"), "{h}");
        assert!(h.contains("<abbr class=\"dsl-p\" title=\"noun\">"), "{h}");
        assert!(h.contains("] Phyllis ran.</div>"), "{h}");
        let h = r("\t[m1][p][i][trn]VERB[/i][/p] When you run.[/trn][/m]\n\tafter");
        assert!(h.ends_with("<div class=\"m\">after</div>"), "{h}");
    }

    #[test]
    fn media_and_refs() {
        let h = r("\t[s]a b.wav[/s][s]pic.jpg[/s][ref dict=\"X\"]go [i]on[/i][/ref]");
        assert!(h.contains("href=\"sound://a%20b.wav\""));
        assert!(h.contains("src=\"pic.jpg\""));
        assert!(h.contains("href=\"entry://go%20on\">go <i>on</i></a>"));
    }
}
