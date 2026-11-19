//! Text folding used for indexing and searching.
//!
//! Two normalizations exist:
//! * [`fold`] — the *search* form: lowercase, diacritics stripped, punctuation
//!   variants unified, whitespace collapsed. Typing `cafe` finds `Café`.
//! * [`lower`] — the *identity* form: lowercase and whitespace/punctuation
//!   normalized but diacritics kept, so `ăn` and `ấn` stay distinct words.
//!
//! Index keys are `fold(w)` followed by `\0 lower(w)` when the two differ, so a
//! folded prefix scan finds every variant while distinct words stay distinct.

use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

/// Separator between folded and identity forms inside an index key.
pub const KEY_SEP: u8 = 0;

#[inline]
fn unify(c: char) -> Option<char> {
    Some(match c {
        '\u{2018}' | '\u{2019}' | '\u{201B}' | '\u{2032}' | '\u{02BC}' | '\u{0060}' | '\u{00B4}' => '\'',
        '\u{201C}' | '\u{201D}' | '\u{201F}' | '\u{2033}' | '\u{00AB}' | '\u{00BB}' => '"',
        '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2212}' => '-',
        // Soft hyphen, zero-width characters and BOM vanish.
        '\u{00AD}' | '\u{200B}' | '\u{200C}' | '\u{200D}' | '\u{2060}' | '\u{FEFF}' => return None,
        _ => c,
    })
}

#[inline]
fn push_lower(out: &mut String, c: char) {
    if c.is_ascii() {
        out.push(c.to_ascii_lowercase());
    } else {
        out.extend(c.to_lowercase());
    }
}

/// Letters that do not decompose under NFKD but should fold to ASCII.
#[inline]
fn fold_special(c: char) -> Option<&'static str> {
    Some(match c {
        'đ' | 'Đ' | 'ð' | 'Ð' => "d",
        'ł' | 'Ł' => "l",
        'ø' | 'Ø' => "o",
        'æ' | 'Æ' => "ae",
        'œ' | 'Œ' => "oe",
        'ß' | 'ẞ' => "ss",
        'ı' => "i",
        'ħ' | 'Ħ' => "h",
        'ŧ' | 'Ŧ' => "t",
        _ => return None,
    })
}

/// Search form of a string.
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    // Fast path for plain ASCII.
    if s.is_ascii() {
        for b in s.bytes() {
            if b.is_ascii_whitespace() || b < 0x20 {
                space = !out.is_empty();
                continue;
            }
            if space {
                out.push(' ');
                space = false;
            }
            let c = if b == b'`' { b'\'' } else { b.to_ascii_lowercase() };
            out.push(c as char);
        }
        return out;
    }
    for c in s.nfkd() {
        if is_combining_mark(c) {
            continue;
        }
        let Some(c) = unify(c) else { continue };
        if c.is_whitespace() || c.is_control() {
            space = !out.is_empty();
            continue;
        }
        if space {
            out.push(' ');
            space = false;
        }
        if let Some(rep) = fold_special(c) {
            out.push_str(rep);
        } else {
            push_lower(&mut out, c);
        }
    }
    out
}

/// Identity form: case-insensitive, diacritics preserved (NFC).
pub fn lower(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for c in s.nfc() {
        let Some(c) = unify(c) else { continue };
        if c.is_whitespace() || c.is_control() {
            space = !out.is_empty();
            continue;
        }
        if space {
            out.push(' ');
            space = false;
        }
        push_lower(&mut out, c);
    }
    out
}

/// Builds the index key for a headword. Returns `None` for empty words.
pub fn index_key(word: &str) -> Option<Vec<u8>> {
    let f = fold(word);
    if f.is_empty() {
        return None;
    }
    let l = lower(word);
    let mut key = f.into_bytes();
    if l.as_bytes() != key.as_slice() {
        key.push(KEY_SEP);
        key.extend_from_slice(l.as_bytes());
    }
    Some(key)
}

/// Splits an index key into (folded, identity) parts.
pub fn split_key(key: &[u8]) -> (&[u8], &[u8]) {
    match key.iter().position(|&b| b == KEY_SEP) {
        Some(p) => (&key[..p], &key[p + 1..]),
        None => (key, key),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folding() {
        assert_eq!(fold("  Café  au   Lait "), "cafe au lait");
        assert_eq!(fold("ĐƯỜNG"), "duong");
        assert_eq!(fold("ấn"), "an");
        assert_eq!(fold("don’t"), "don't");
        assert_eq!(fold("Straße"), "strasse");
        assert_eq!(fold("APPLE"), "apple");
        assert_eq!(lower("ẤN Độ"), "ấn độ");
        assert_eq!(lower("ﬁne"), "ﬁne");
        assert_eq!(fold("ﬁne"), "fine");
    }

    #[test]
    fn keys() {
        assert_eq!(index_key("Apple").unwrap(), b"apple".to_vec());
        let k = index_key("ăn").unwrap();
        let (f, l) = split_key(&k);
        assert_eq!(f, b"an");
        assert_eq!(l, "ăn".as_bytes());
        assert!(index_key("   ").is_none());
    }
}
