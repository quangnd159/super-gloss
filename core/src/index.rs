//! Persistent, memory-mapped headword index.
//!
//! Layout of an index named `N` inside a directory:
//! * `N.fst`     — FST map: key → (first entry << 24 | entry count)
//! * `N.entries` — fixed 24-byte records sorted by key: word_off u32, word_len u32, a u64, b u64
//! * `N.words`   — UTF-8 display headwords, concatenated
//!
//! `a`/`b` form a format-specific [`Locator`].

use crate::fold::{self, KEY_SEP};
use anyhow::{bail, Context, Result};
use fst::{Automaton, IntoStreamer, Streamer};
use memmap2::Mmap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct Locator {
    pub a: u64,
    pub b: u64,
}

const REC: usize = 24;
const COUNT_BITS: u64 = 24;
const COUNT_MASK: u64 = (1 << COUNT_BITS) - 1;

pub enum Bytes {
    Map(Mmap),
    Owned(Vec<u8>),
}

impl AsRef<[u8]> for Bytes {
    fn as_ref(&self) -> &[u8] {
        match self {
            Bytes::Map(m) => m,
            Bytes::Owned(v) => v,
        }
    }
}

pub fn map_file(path: &Path) -> Result<Bytes> {
    let f = File::open(path).with_context(|| format!("open {}", path.display()))?;
    let len = f.metadata()?.len();
    if len == 0 {
        return Ok(Bytes::Owned(Vec::new()));
    }
    // SAFETY: index files are private to the cache and never modified once written
    // (rebuilds write a new directory and rename it into place).
    let m = unsafe { Mmap::map(&f)? };
    Ok(Bytes::Map(m))
}

struct Item {
    key: Vec<u8>,
    word: String,
    loc: Locator,
}

#[derive(Default)]
pub struct IndexBuilder {
    items: Vec<Item>,
}

impl IndexBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Adds a headword using the standard folded key.
    pub fn add(&mut self, word: &str, loc: Locator) {
        let word = word.trim();
        if let Some(key) = fold::index_key(word) {
            self.items.push(Item { key, word: word.to_string(), loc });
        }
    }

    /// Adds an entry with a caller-defined key (used for resource paths).
    pub fn add_raw(&mut self, key: Vec<u8>, word: &str, loc: Locator) {
        if !key.is_empty() {
            self.items.push(Item { key, word: word.to_string(), loc });
        }
    }

    pub fn write(mut self, dir: &Path, name: &str) -> Result<()> {
        // Stable sort keeps source order among identical keys.
        self.items.sort_by(|x, y| x.key.cmp(&y.key));
        // Drop exact duplicates (same key, word and locator), e.g. StarDict synonyms
        // that repeat the main headword.
        self.items.dedup_by(|x, y| x.key == y.key && x.loc == y.loc && x.word == y.word);

        let mut entries = BufWriter::new(File::create(dir.join(format!("{name}.entries")))?);
        let mut words = BufWriter::new(File::create(dir.join(format!("{name}.words")))?);
        let fst_file = BufWriter::new(File::create(dir.join(format!("{name}.fst")))?);
        let mut map = fst::MapBuilder::new(fst_file)?;

        let mut word_off: u64 = 0;
        let mut i = 0usize;
        while i < self.items.len() {
            let start = i;
            let key = &self.items[i].key;
            let mut j = i;
            while j < self.items.len() && &self.items[j].key == key {
                j += 1;
            }
            let count = ((j - start) as u64).min(COUNT_MASK);
            map.insert(key, ((start as u64) << COUNT_BITS) | count)?;
            for it in &self.items[start..j] {
                let wb = it.word.as_bytes();
                let wl = wb.len().min(u32::MAX as usize);
                if word_off + wl as u64 > u32::MAX as u64 {
                    bail!("headword table exceeds 4 GiB");
                }
                entries.write_all(&(word_off as u32).to_le_bytes())?;
                entries.write_all(&(wl as u32).to_le_bytes())?;
                entries.write_all(&it.loc.a.to_le_bytes())?;
                entries.write_all(&it.loc.b.to_le_bytes())?;
                words.write_all(&wb[..wl])?;
                word_off += wl as u64;
            }
            i = j;
        }
        map.finish()?;
        entries.flush()?;
        words.flush()?;
        Ok(())
    }
}

/// A run of entries sharing one key.
#[derive(Clone, Debug)]
pub struct Group {
    pub key: Vec<u8>,
    pub start: usize,
    pub count: usize,
}

impl Group {
    fn from(key: &[u8], v: u64) -> Self {
        Group { key: key.to_vec(), start: (v >> COUNT_BITS) as usize, count: (v & COUNT_MASK) as usize }
    }
    pub fn range(&self) -> std::ops::Range<usize> {
        self.start..self.start + self.count
    }
}

pub struct Index {
    fst: fst::Map<Bytes>,
    entries: Bytes,
    words: Bytes,
    len: usize,
}

impl Index {
    pub fn open(dir: &Path, name: &str) -> Result<Index> {
        let fst = fst::Map::new(map_file(&dir.join(format!("{name}.fst")))?)?;
        let entries = map_file(&dir.join(format!("{name}.entries")))?;
        let words = map_file(&dir.join(format!("{name}.words")))?;
        if entries.as_ref().len() % REC != 0 {
            bail!("corrupt index entries");
        }
        let len = entries.as_ref().len() / REC;
        Ok(Index { fst, entries, words, len })
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn key_count(&self) -> usize {
        self.fst.len()
    }

    pub fn entry(&self, i: usize) -> Option<(&str, Locator)> {
        if i >= self.len {
            return None;
        }
        let r = &self.entries.as_ref()[i * REC..(i + 1) * REC];
        let off = u32::from_le_bytes(r[0..4].try_into().unwrap()) as usize;
        let len = u32::from_le_bytes(r[4..8].try_into().unwrap()) as usize;
        let a = u64::from_le_bytes(r[8..16].try_into().unwrap());
        let b = u64::from_le_bytes(r[16..24].try_into().unwrap());
        let w = self.words.as_ref().get(off..off + len).unwrap_or(&[]);
        Some((std::str::from_utf8(w).unwrap_or(""), Locator { a, b }))
    }

    pub fn get(&self, key: &[u8]) -> Option<Group> {
        self.fst.get(key).map(|v| Group::from(key, v))
    }

    /// All groups whose folded part equals `folded` (every identity variant).
    pub fn folded(&self, folded: &[u8]) -> Vec<Group> {
        let mut out = Vec::new();
        if let Some(g) = self.get(folded) {
            out.push(g);
        }
        let mut lo = folded.to_vec();
        lo.push(KEY_SEP);
        let mut hi = folded.to_vec();
        hi.push(KEY_SEP + 1);
        let mut s = self.fst.range().ge(&lo).lt(&hi).into_stream();
        while let Some((k, v)) = s.next() {
            out.push(Group::from(k, v));
        }
        out
    }

    /// Groups whose key starts with `prefix`, in key order.
    pub fn prefix(&self, prefix: &[u8], limit: usize) -> Vec<Group> {
        let mut out = Vec::new();
        let mut s = self.fst.range().ge(prefix).into_stream();
        while let Some((k, v)) = s.next() {
            if !k.starts_with(prefix) || out.len() >= limit {
                break;
            }
            out.push(Group::from(k, v));
        }
        out
    }

    /// Groups whose folded part is within `dist` edits of `folded`.
    pub fn fuzzy(&self, folded: &str, dist: u32, limit: usize) -> Vec<Group> {
        let Ok(lev) = fst::automaton::Levenshtein::new(folded, dist) else {
            return Vec::new();
        };
        self.search_folded(UntilSep(&lev), limit)
    }

    pub fn search_folded<A: Automaton>(&self, aut: UntilSep<A>, limit: usize) -> Vec<Group> {
        let mut out = Vec::new();
        let mut s = self.fst.search(aut).into_stream();
        while let Some((k, v)) = s.next() {
            out.push(Group::from(k, v));
            if out.len() >= limit {
                break;
            }
        }
        out
    }

    /// Streams every key starting with `prefix`, calling `f` until it returns false.
    pub fn scan_prefix(&self, prefix: &[u8], mut f: impl FnMut(&[u8], Group) -> bool) {
        let mut s = self.fst.range().ge(prefix).into_stream();
        while let Some((k, v)) = s.next() {
            if !k.starts_with(prefix) {
                break;
            }
            if !f(k, Group::from(k, v)) {
                break;
            }
        }
    }
}

/// Runs an automaton over the folded part of a key and accepts any identity suffix.
pub struct UntilSep<A>(pub A);

#[derive(Clone)]
pub enum SepState<S> {
    In(S),
    After,
    Dead,
}

impl<A: Automaton> Automaton for UntilSep<A> {
    type State = SepState<A::State>;

    fn start(&self) -> Self::State {
        SepState::In(self.0.start())
    }
    fn is_match(&self, s: &Self::State) -> bool {
        match s {
            SepState::In(s) => self.0.is_match(s),
            SepState::After => true,
            SepState::Dead => false,
        }
    }
    fn can_match(&self, s: &Self::State) -> bool {
        match s {
            SepState::In(s) => self.0.can_match(s) || self.0.is_match(s),
            SepState::After => true,
            SepState::Dead => false,
        }
    }
    fn accept(&self, s: &Self::State, byte: u8) -> Self::State {
        match s {
            SepState::In(st) => {
                if byte == KEY_SEP {
                    if self.0.is_match(st) {
                        SepState::After
                    } else {
                        SepState::Dead
                    }
                } else {
                    SepState::In(self.0.accept(st, byte))
                }
            }
            SepState::After => SepState::After,
            SepState::Dead => SepState::Dead,
        }
    }
}

/// Case/diacritic-folded glob match supporting `*` and `?`.
pub fn glob_match(pattern: &[char], text: &[char]) -> bool {
    let (mut p, mut t) = (0usize, 0usize);
    let (mut star, mut mark) = (usize::MAX, 0usize);
    while t < text.len() {
        if p < pattern.len() && (pattern[p] == '?' || pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if p < pattern.len() && pattern[p] == '*' {
            star = p;
            p += 1;
            mark = t;
        } else if star != usize::MAX {
            p = star + 1;
            mark += 1;
            t = mark;
        } else {
            return false;
        }
    }
    while p < pattern.len() && pattern[p] == '*' {
        p += 1;
    }
    p == pattern.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("sg-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn build_and_query() {
        let d = tmpdir("index");
        let mut b = IndexBuilder::new();
        for (i, w) in ["apple", "Apple", "an", "ăn", "ấn", "an ủi", "banana", "ăn uống"].iter().enumerate() {
            b.add(w, Locator { a: i as u64, b: 0 });
        }
        b.write(&d, "k").unwrap();
        let idx = Index::open(&d, "k").unwrap();
        assert_eq!(idx.len(), 8);
        let g = idx.get(b"apple").unwrap();
        assert_eq!(g.count, 2);
        let words: Vec<_> = g.range().map(|i| idx.entry(i).unwrap().0.to_string()).collect();
        assert_eq!(words, vec!["apple", "Apple"]);
        assert_eq!(idx.folded(b"an").len(), 3);
        let p = idx.prefix(b"an", 100);
        assert_eq!(p.len(), 5);
        let fz = idx.fuzzy("aple", 1, 10);
        assert_eq!(fz.len(), 1);
        let fz = idx.fuzzy("an", 0, 10);
        assert_eq!(fz.len(), 3);
        assert!(glob_match(&"a*e".chars().collect::<Vec<_>>(), &"apple".chars().collect::<Vec<_>>()));
        assert!(!glob_match(&"a?e".chars().collect::<Vec<_>>(), &"apple".chars().collect::<Vec<_>>()));
        let _ = std::fs::remove_dir_all(&d);
    }
}
