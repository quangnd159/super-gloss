use anyhow::{bail, Context, Result};
use std::fs::File;
use std::os::unix::fs::FileExt;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};

#[inline]
pub fn be16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}
#[inline]
pub fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}
#[inline]
pub fn be64(b: &[u8]) -> u64 {
    u64::from_be_bytes(b[..8].try_into().unwrap())
}
#[inline]
pub fn le16(b: &[u8]) -> u16 {
    u16::from_le_bytes([b[0], b[1]])
}

/// Bounds-checked byte cursor for binary formats.
pub struct Cursor<'a> {
    pub data: &'a [u8],
    pub pos: usize,
}

impl<'a> Cursor<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Cursor { data, pos: 0 }
    }
    pub fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }
    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if n > self.remaining() {
            bail!("unexpected end of data (need {n}, have {})", self.remaining());
        }
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    pub fn be16(&mut self) -> Result<u16> {
        Ok(be16(self.take(2)?))
    }
    pub fn be32(&mut self) -> Result<u32> {
        Ok(be32(self.take(4)?))
    }
    pub fn be64(&mut self) -> Result<u64> {
        Ok(be64(self.take(8)?))
    }
    /// Big-endian number of `width` bytes (4 or 8).
    pub fn num(&mut self, width: usize) -> Result<u64> {
        if width == 8 {
            self.be64()
        } else {
            Ok(self.be32()? as u64)
        }
    }
}

/// Reads `len` bytes at `offset`. A range past the end of the file is refused before
/// anything is allocated, so a length field in a malformed file can't size the buffer.
pub fn read_at(file: &File, offset: u64, len: usize) -> Result<Vec<u8>> {
    let flen = file.metadata()?.len();
    if offset.checked_add(len as u64).is_none_or(|e| e > flen) {
        bail!("read {len} bytes at {offset} beyond the end of the file ({flen})");
    }
    let mut buf = vec![0u8; len];
    file.read_exact_at(&mut buf, offset)
        .with_context(|| format!("read {len} bytes at {offset}"))?;
    Ok(buf)
}

/// Joins a user-supplied relative path below `base`, rejecting traversal.
pub fn safe_join(base: &Path, rel: &str) -> Option<PathBuf> {
    let rel = rel.trim_start_matches(['/', '\\']).replace('\\', "/");
    if rel.is_empty() {
        return None;
    }
    let p = Path::new(&rel);
    let mut out = base.to_path_buf();
    for c in p.components() {
        match c {
            Component::Normal(s) => out.push(s),
            Component::CurDir => {}
            _ => return None,
        }
    }
    Some(out)
}

/// The file `rel` names below `base`, matched case-insensitively when the exact name is
/// missing. A path that `..` or a symlink would lead outside `base` is refused.
pub fn file_below(base: &Path, rel: &str) -> Option<PathBuf> {
    let p = safe_join(base, rel)?;
    let found = find_case_insensitive(p.parent()?, &p.file_name()?.to_string_lossy())?;
    let real = found.canonicalize().ok()?;
    real.starts_with(base.canonicalize().ok()?).then_some(real)
}

/// Whether a link in an article may lead to `url`: a relative one, or one of the schemes
/// articles use. Browsers drop tabs and newlines anywhere in a URL and trim what
/// surrounds it, so "java\tscript:" is checked as "javascript:".
pub fn link_allowed(url: &str) -> bool {
    let u: String = url.trim_matches(|c: char| c <= ' ').chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect();
    match u.find([':', '/', '?', '#']) {
        Some(i) if u.as_bytes()[i] == b':' => {
            matches!(u[..i].to_ascii_lowercase().as_str(), "http" | "https" | "mailto" | "entry" | "sound" | "bword")
        }
        _ => true,
    }
}

/// Finds a file in `dir` matching `name` case-insensitively.
pub fn find_case_insensitive(dir: &Path, name: &str) -> Option<PathBuf> {
    let direct = dir.join(name);
    if direct.is_file() {
        return Some(direct);
    }
    let lname = name.to_lowercase();
    std::fs::read_dir(dir).ok()?.flatten().find_map(|e| {
        let n = e.file_name();
        (n.to_string_lossy().to_lowercase() == lname && e.path().is_file()).then(|| e.path())
    })
}

pub fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    html_escape_into(&mut out, s);
    out
}

pub fn html_escape_into(out: &mut String, s: &str) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
}

/// Decodes the handful of XML/HTML entities that appear in metadata.
pub fn unescape_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let end = rest.as_bytes()[..rest.len().min(12)].iter().position(|&b| b == b';');
        let decoded = end.and_then(|e| {
            let ent = &rest[1..e];
            let c = match ent {
                "lt" => Some('<'),
                "gt" => Some('>'),
                "amp" => Some('&'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ if ent.starts_with("#x") || ent.starts_with("#X") => {
                    u32::from_str_radix(&ent[2..], 16).ok().and_then(char::from_u32)
                }
                _ if ent.starts_with('#') => ent[1..].parse().ok().and_then(char::from_u32),
                _ => None,
            };
            c.map(|c| (c, e))
        });
        match decoded {
            Some((c, e)) => {
                out.push(c);
                rest = &rest[e + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Percent-encodes a path segment for use in an attribute URL.
pub fn url_encode_path(s: &str) -> String {
    const SET: &percent_encoding::AsciiSet = &percent_encoding::CONTROLS
        .add(b' ')
        .add(b'"')
        .add(b'#')
        .add(b'%')
        .add(b'<')
        .add(b'>')
        .add(b'?')
        .add(b'`')
        .add(b'{')
        .add(b'}')
        .add(b'\'');
    percent_encoding::utf8_percent_encode(s, SET).to_string()
}

pub fn url_encode_component(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

pub fn mime_for(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "css" => "text/css",
        "js" => "text/javascript",
        "html" | "htm" => "text/html",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "tif" | "tiff" => "image/tiff",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" | "oga" => "audio/ogg",
        "spx" => "audio/ogg",
        "m4a" | "aac" => "audio/mp4",
        "mp4" => "video/mp4",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "json" => "application/json",
        "txt" => "text/plain",
        _ => "application/octet-stream",
    }
}

pub fn is_audio(path: &str) -> bool {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    matches!(
        ext.as_str(),
        "wav" | "mp3" | "ogg" | "oga" | "spx" | "opus" | "m4a" | "aac" | "flac" | "aif" | "aiff" | "caf" | "wma"
    )
}

pub fn is_image(path: &str) -> bool {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    matches!(
        ext.as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "bmp" | "svg" | "webp" | "tif" | "tiff" | "ico"
    )
}

/// A tiny thread-safe LRU of decoded blocks.
pub struct BlockCache {
    cap: usize,
    items: Mutex<Vec<(u64, Arc<Vec<u8>>)>>,
}

impl BlockCache {
    pub fn new(cap: usize) -> Self {
        BlockCache { cap, items: Mutex::new(Vec::with_capacity(cap)) }
    }

    pub fn get_or_load(&self, id: u64, load: impl FnOnce() -> Result<Vec<u8>>) -> Result<Arc<Vec<u8>>> {
        {
            let mut items = self.items.lock().unwrap();
            if let Some(i) = items.iter().position(|(k, _)| *k == id) {
                let it = items.remove(i);
                let v = it.1.clone();
                items.insert(0, it);
                return Ok(v);
            }
        }
        let v = Arc::new(load()?);
        let mut items = self.items.lock().unwrap();
        if !items.iter().any(|(k, _)| *k == id) {
            items.insert(0, (id, v.clone()));
            items.truncate(self.cap);
        }
        Ok(v)
    }
}

/// Decodes text with an optional BOM, falling back to UTF-8 → Windows-1252.
pub fn decode_text_auto(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return encoding_rs::UTF_16LE.decode_without_bom_handling(&bytes[2..]).0.into_owned();
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return encoding_rs::UTF_16BE.decode_without_bom_handling(&bytes[2..]).0.into_owned();
    }
    let b = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    match std::str::from_utf8(b) {
        Ok(s) => s.to_string(),
        Err(_) => encoding_rs::WINDOWS_1252.decode_without_bom_handling(b).0.into_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn join() {
        let b = Path::new("/x");
        assert_eq!(safe_join(b, "a/b.png").unwrap(), PathBuf::from("/x/a/b.png"));
        assert_eq!(safe_join(b, "\\a\\b.png").unwrap(), PathBuf::from("/x/a/b.png"));
        assert!(safe_join(b, "../etc/passwd").is_none());
        assert!(safe_join(b, "").is_none());
    }
    #[test]
    fn files_stay_below_their_folder() {
        let d = std::env::temp_dir().join(format!("sg-below-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("dict")).unwrap();
        std::fs::write(d.join("dict/A.css"), "a").unwrap();
        std::fs::write(d.join("secret"), "s").unwrap();
        std::os::unix::fs::symlink(d.join("secret"), d.join("dict/leak")).unwrap();
        std::os::unix::fs::symlink(&d, d.join("dict/up")).unwrap();
        let base = d.join("dict");
        assert!(file_below(&base, "a.css").is_some());
        assert!(file_below(&base, "leak").is_none());
        assert!(file_below(&base, "up/secret").is_none());
        assert!(file_below(&base, "../secret").is_none());
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn links() {
        for u in ["entry://run", "sound://a.wav", "HTTPS://x.org", "mailto:a@b", "pics/a.png", "a.html#x", "#top", "x/y:z"] {
            assert!(link_allowed(u), "{u}");
        }
        for u in ["javascript:alert(1)", " JavaScript:x", "java\tscript:x", "\u{1}javascript:x", "data:text/html,x", "vbscript:x", "file:///etc/passwd"] {
            assert!(!link_allowed(u), "{u}");
        }
    }
    #[test]
    fn entities() {
        assert_eq!(unescape_entities("a &lt;b&gt; &amp; &#x41;&#66; &bogus"), "a <b> & AB &bogus");
        assert_eq!(unescape_entities("&a•b; ợ&—"), "&a•b; ợ&—");
    }
}
