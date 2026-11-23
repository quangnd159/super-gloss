//! Persistent, memory-mapped headword index.
//!
//! Layout of an index named `N` inside a directory:
//! * `N.fst`     — FST map: key → (first entry << 24 | entry count)
//! * `N.entries` — fixed 24-byte records sorted by key: word_off u32, word_len u32, a u64, b u64
//! * `N.words`   — UTF-8 display headwords, concatenated. A form that only leads to an
//!   entry (an inflection, a reading, a spelling without diacritics) is followed by a NUL
//!   and the entry's own headword.
//!
//! `a`/`b` form a format-specific [`Locator`].

use crate::fold::{self, KEY_SEP};
use anyhow::{bail, Context, Result};
use fst::automaton::Levenshtein;
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

    /// Adds `form`, another way to reach the entry whose headword is `head`: it is found
    /// and suggested as `form`, and the entry opens under `head`.
    pub fn add_form(&mut self, form: &str, head: &str, loc: Locator) {
        let (form, head) = (form.trim(), head.trim());
        if form == head || head.is_empty() {
            return self.add(form, loc);
        }
        if let Some(key) = fold::index_key(form) {
            self.items.push(Item { key, word: format!("{form}\0{head}"), loc });
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
        // A damaged map can send searches anywhere; caught here, the index is rebuilt.
        fst.as_fst().verify().context("corrupt index")?;
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
        let w = std::str::from_utf8(self.words.as_ref().get(off..off + len).unwrap_or(&[])).unwrap_or("");
        Some((w.split_once('\0').map_or(w, |(form, _)| form), Locator { a, b }))
    }

    /// The headword of the entry `i` leads to: its own word, unless it is another form of one.
    pub fn headword(&self, i: usize) -> Option<&str> {
        let r = self.entries.as_ref().get(i * REC..(i + 1) * REC)?;
        let off = u32::from_le_bytes(r[0..4].try_into().unwrap()) as usize;
        let len = u32::from_le_bytes(r[4..8].try_into().unwrap()) as usize;
        let w = std::str::from_utf8(self.words.as_ref().get(off..off + len)?).ok()?;
        Some(w.split_once('\0').map_or(w, |(_, head)| head))
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

    /// Every key with its value, in order.
    pub fn keys(&self) -> &fst::Map<Bytes> {
        &self.fst
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

/// Up to [`AnyLev::MAX`] Levenshtein automata walked together, so the map is read once for
/// all of them rather than once each.
pub struct AnyLev<'a>(pub &'a [Levenshtein]);

impl AnyLev<'_> {
    pub const MAX: usize = 16;
    const DEAD: u32 = u32::MAX;
}

impl Automaton for AnyLev<'_> {
    type State = [u32; AnyLev::MAX];

    fn start(&self) -> Self::State {
        let mut s = [Self::DEAD; Self::MAX];
        s[..self.0.len()].fill(0);
        s
    }
    fn is_match(&self, s: &Self::State) -> bool {
        self.0.iter().zip(s).any(|(a, &st)| st != Self::DEAD && a.is_match(&Some(st as usize)))
    }
    fn can_match(&self, s: &Self::State) -> bool {
        s.iter().any(|&st| st != Self::DEAD)
    }
    fn accept(&self, s: &Self::State, byte: u8) -> Self::State {
        let mut next = [Self::DEAD; Self::MAX];
        for ((a, &st), n) in self.0.iter().zip(s).zip(&mut next) {
            if st != Self::DEAD {
                *n = a.accept(&Some(st as usize), byte).map_or(Self::DEAD, |t| t as u32);
            }
        }
        next
    }
}

/// A glob (`*` any run, `?` one character) as an automaton over UTF-8 bytes, so a search
/// skips every branch of the map that can't match instead of visiting each key.
///
/// The pattern is a row of slots and the state the set of slots reached (bit `len` means
/// a match). `?` takes four: the lead byte, then one slot per continuation byte to come.
pub struct Glob {
    slots: Vec<Slot>,
}

#[derive(Clone, Copy)]
enum Slot {
    Byte(u8),
    Star,
    Any,
    /// Inside a `?`: this many continuation bytes still to come.
    Cont(u8),
}

impl Glob {
    /// None for a pattern too long for the state's 128 bits.
    pub fn new(pattern: &str) -> Option<Glob> {
        let mut slots = Vec::new();
        for c in pattern.chars() {
            match c {
                '*' if matches!(slots.last(), Some(Slot::Star)) => {}
                '*' => slots.push(Slot::Star),
                '?' => slots.extend([Slot::Any, Slot::Cont(1), Slot::Cont(2), Slot::Cont(3)]),
                _ => slots.extend(c.encode_utf8(&mut [0; 4]).bytes().map(Slot::Byte)),
            }
        }
        (slots.len() < 128).then_some(Glob { slots })
    }

    /// Adds the slots a `*` reaches by matching nothing.
    fn close(&self, mut s: u128) -> u128 {
        for (i, slot) in self.slots.iter().enumerate() {
            if matches!(slot, Slot::Star) && s & (1 << i) != 0 {
                s |= 1 << (i + 1);
            }
        }
        s
    }
}

impl Automaton for Glob {
    type State = u128;

    fn start(&self) -> u128 {
        self.close(1)
    }
    fn is_match(&self, s: &u128) -> bool {
        s & (1 << self.slots.len()) != 0
    }
    fn can_match(&self, s: &u128) -> bool {
        *s != 0
    }
    fn accept(&self, s: &u128, b: u8) -> u128 {
        let mut live = s & !(1 << self.slots.len());
        let mut next = 0u128;
        while live != 0 {
            let i = live.trailing_zeros() as usize;
            live &= live - 1;
            let to = match self.slots[i] {
                Slot::Byte(x) if x == b => i + 1,
                Slot::Star => i,
                Slot::Any => match b {
                    0..=0x7f => i + 4,
                    0xc0..=0xdf => i + 1,
                    0xe0..=0xef => i + 2,
                    0xf0..=0xf7 => i + 3,
                    _ => continue,
                },
                // Cont(n) sits n slots after its `?`, whose end is 4 slots after it.
                Slot::Cont(n) if b & 0xc0 == 0x80 => if n > 1 { i - 1 } else { i + 3 },
                _ => continue,
            };
            next |= 1 << to;
        }
        self.close(next)
    }
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
        let lev = |q, d| fst::automaton::Levenshtein::new(q, d).unwrap();
        assert_eq!(idx.search_folded(UntilSep(&lev("aple", 1)), 10).len(), 1);
        assert_eq!(idx.search_folded(UntilSep(&lev("an", 0)), 10).len(), 3);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn damaged_map_is_refused() {
        let d = tmpdir("damaged");
        let mut b = IndexBuilder::new();
        for (i, w) in ["apple", "banana", "cherry", "date", "elderberry"].iter().enumerate() {
            b.add(w, Locator { a: i as u64, b: 0 });
        }
        b.write(&d, "k").unwrap();
        let p = d.join("k.fst");
        let mut bytes = std::fs::read(&p).unwrap();
        let mid = bytes.len() / 2;
        bytes[mid] ^= 0x5a;
        std::fs::write(&p, bytes).unwrap();
        assert!(Index::open(&d, "k").is_err());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn glob() {
        let d = tmpdir("glob");
        let mut b = IndexBuilder::new();
        for (i, w) in ["apple", "ample", "ape", "ăn", "ấn", "đi", "x", "日本", "本"].iter().enumerate() {
            b.add(w, Locator { a: i as u64, b: 0 });
        }
        b.write(&d, "k").unwrap();
        let idx = Index::open(&d, "k").unwrap();
        let find = |p: &str| -> Vec<String> {
            let g = Glob::new(&fold::fold(p)).unwrap();
            idx.search_folded(UntilSep(&g), 100).iter().map(|g| idx.entry(g.start).unwrap().0.to_string()).collect()
        };
        assert_eq!(find("a*e"), ["ample", "ape", "apple"]);
        assert_eq!(find("a?e"), ["ape"]);
        assert_eq!(find("a??le"), ["ample", "apple"]);
        assert_eq!(find("?n"), ["ăn", "ấn"]);
        assert_eq!(find("?"), ["x", "本"]);
        assert_eq!(find("??"), ["ăn", "ấn", "đi", "日本"]);
        assert_eq!(find("*本"), ["日本", "本"]);
        assert_eq!(find("**p*"), ["ample", "ape", "apple"]);
        assert!(find("z*").is_empty());
        assert!(Glob::new(&"?".repeat(40)).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn other_forms_open_under_their_headword() {
        let d = tmpdir("forms");
        let mut b = IndexBuilder::new();
        b.add("rồ", Locator { a: 1, b: 0 });
        b.add_form("roof", "rồ", Locator { a: 1, b: 0 });
        b.add("roof", Locator { a: 2, b: 0 });
        b.write(&d, "k").unwrap();
        let idx = Index::open(&d, "k").unwrap();
        let g = idx.get(&crate::fold::index_key("roof").unwrap()).unwrap();
        let found: Vec<_> = g.range().map(|i| (idx.entry(i).unwrap().0, idx.headword(i).unwrap())).collect();
        assert_eq!(found, vec![("roof", "rồ"), ("roof", "roof")]);
        let _ = std::fs::remove_dir_all(&d);
    }
}
