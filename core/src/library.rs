//! The dictionary library: discovery, cached indexing, search, lookup, pages.

use crate::fold::{self, split_key};
use crate::formats::{self, BuildCtx, DictInfo, Kind, Reader};
use crate::index::{glob_match, Group, Index};
use crate::morph;
use crate::util::{html_escape, html_escape_into, mime_for};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::UNIX_EPOCH;

/// Bump whenever the on-disk index layout or any format's build output changes.
pub const INDEX_VERSION: u32 = 4;

#[derive(Serialize, Deserialize)]
struct Meta {
    version: u32,
    fingerprint: Vec<(String, u64, i64)>,
    info: DictInfo,
}

pub struct Loaded {
    pub info: DictInfo,
    pub index: Index,
    pub reader: Box<dyn Reader>,
    pub dir: PathBuf,
}

#[derive(Clone)]
pub enum State {
    Pending,
    Indexing,
    Ready(Arc<Loaded>),
    Failed(String),
}

pub struct Dict {
    pub id: String,
    pub kind: Kind,
    pub path: PathBuf,
    pub icon_src: Option<PathBuf>,
    size: u64,
    fingerprint: Vec<(String, u64, i64)>,
    state: RwLock<State>,
    progress: AtomicU32,
}

impl Dict {
    pub fn state(&self) -> State {
        self.state.read().unwrap().clone()
    }
    pub fn loaded(&self) -> Option<Arc<Loaded>> {
        match &*self.state.read().unwrap() {
            State::Ready(l) => Some(l.clone()),
            _ => None,
        }
    }
}

fn fnv64(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

pub fn dict_id(path: &Path) -> String {
    format!("d{:016x}", fnv64(&path.to_string_lossy()))
}

fn stat(p: &Path) -> Option<(String, u64, i64)> {
    let m = std::fs::metadata(p).ok()?;
    let mtime = m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0);
    Some((p.to_string_lossy().into_owned(), m.len(), mtime))
}

#[derive(Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub roots: Vec<String>,
    #[serde(default)]
    pub order: Vec<String>,
    #[serde(default)]
    pub disabled: Vec<String>,
}

#[derive(Serialize)]
pub struct DictSummary {
    pub id: String,
    pub name: String,
    pub format: String,
    pub path: String,
    pub state: &'static str,
    pub progress: f32,
    pub entries: u64,
    pub enabled: bool,
    pub icon: Option<String>,
    pub about: String,
    pub languages: String,
    pub error: Option<String>,
    pub size: u64,
}

#[derive(Serialize, Clone, Debug)]
pub struct Suggestion {
    pub word: String,
    /// "exact" | "lemma" | "prefix" | "fuzzy" | "glob"
    pub kind: &'static str,
    /// Number of dictionaries that contain this word.
    pub sources: u32,
}

#[derive(Serialize, Debug)]
pub struct Hit {
    pub dict: String,
    pub name: String,
    pub entries: Vec<usize>,
    pub words: Vec<String>,
    pub foreign: bool,
}

#[derive(Serialize, Debug)]
pub struct LookupResult {
    pub word: String,
    /// Set when results come from a base form (e.g. "ran" → "run").
    pub via: Option<String>,
    pub hits: Vec<Hit>,
}

pub struct Library {
    cache_root: PathBuf,
    dicts: RwLock<Vec<Arc<Dict>>>,
    disabled: RwLock<HashSet<String>>,
    generation: AtomicU64,
    workers: AtomicUsize,
    claim: Mutex<()>,
    seed: AtomicU64,
}

const MAX_WORKERS: usize = 3;

impl Library {
    pub fn new(cache_root: impl Into<PathBuf>) -> Arc<Library> {
        let cache_root = cache_root.into();
        let _ = std::fs::create_dir_all(&cache_root);
        let seed = std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1) | 1;
        Arc::new(Library {
            cache_root,
            dicts: RwLock::new(Vec::new()),
            disabled: RwLock::new(HashSet::new()),
            generation: AtomicU64::new(1),
            workers: AtomicUsize::new(0),
            claim: Mutex::new(()),
            seed: AtomicU64::new(seed),
        })
    }

    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    fn bump(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    /// Discovers dictionaries below `roots` (files or folders).
    pub fn discover(roots: &[PathBuf]) -> Vec<(Kind, PathBuf)> {
        let mut found = Vec::new();
        let mut seen = HashSet::new();
        let mut budget = 200_000usize;
        for r in roots {
            walk(r, 0, &mut found, &mut seen, &mut budget);
        }
        found
    }

    pub fn configure(self: &Arc<Self>, cfg: &Config) {
        let roots: Vec<PathBuf> = cfg.roots.iter().map(|r| PathBuf::from(expand_tilde(r))).collect();
        let found = Self::discover(&roots);
        let existing: HashMap<String, Arc<Dict>> =
            self.dicts.read().unwrap().iter().map(|d| (d.id.clone(), d.clone())).collect();
        // Folders with more than one dictionary should not borrow a lone folder image.
        let mut per_dir: HashMap<PathBuf, usize> = HashMap::new();
        for (_, p) in &found {
            *per_dir.entry(p.parent().unwrap_or(Path::new("/")).to_path_buf()).or_default() += 1;
        }
        let mut list: Vec<Arc<Dict>> = Vec::new();
        for (kind, path) in found {
            let id = dict_id(&path);
            let mut fp: Vec<_> = std::iter::once(path.clone())
                .chain(formats::companion_files(kind, &path))
                .filter_map(|p| stat(&p))
                .collect();
            fp.sort();
            if let Some(d) = existing.get(&id) {
                if d.fingerprint == fp && !matches!(d.state(), State::Failed(_)) {
                    list.push(d.clone());
                    continue;
                }
            }
            let multi = per_dir.get(path.parent().unwrap_or(Path::new("/"))).copied().unwrap_or(0) > 1;
            list.push(Arc::new(Dict {
                id,
                kind,
                icon_src: formats::find_icon(kind, &path, multi),
                size: fp.iter().map(|f| f.1).sum(),
                path,
                fingerprint: fp,
                state: RwLock::new(State::Pending),
                progress: AtomicU32::new(0),
            }));
        }
        // Order: configured order first, then the rest in discovery order.
        let pos: HashMap<&str, usize> = cfg.order.iter().enumerate().map(|(i, id)| (id.as_str(), i)).collect();
        let mut keyed: Vec<(usize, usize, Arc<Dict>)> =
            list.into_iter().enumerate().map(|(i, d)| (pos.get(d.id.as_str()).copied().unwrap_or(usize::MAX), i, d)).collect();
        keyed.sort_by_key(|(p, i, _)| (*p, *i));
        *self.dicts.write().unwrap() = keyed.into_iter().map(|(_, _, d)| d).collect();
        *self.disabled.write().unwrap() = cfg.disabled.iter().cloned().collect();
        self.bump();
        self.spawn_workers();
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) {
        let mut d = self.disabled.write().unwrap();
        if enabled {
            d.remove(id);
        } else {
            d.insert(id.to_string());
        }
        drop(d);
        self.bump();
    }

    pub fn reindex(self: &Arc<Self>, id: &str) {
        if let Some(d) = self.dict(id) {
            if matches!(d.state(), State::Indexing) {
                return;
            }
            let _ = std::fs::remove_dir_all(self.cache_root.join(&d.id));
            *d.state.write().unwrap() = State::Pending;
            self.bump();
            self.spawn_workers();
        }
    }

    pub fn dict(&self, id: &str) -> Option<Arc<Dict>> {
        self.dicts.read().unwrap().iter().find(|d| d.id == id).cloned()
    }

    fn enabled_ready(&self) -> Vec<(Arc<Dict>, Arc<Loaded>)> {
        let disabled = self.disabled.read().unwrap();
        self.dicts
            .read()
            .unwrap()
            .iter()
            .filter(|d| !disabled.contains(&d.id))
            .filter_map(|d| d.loaded().map(|l| (d.clone(), l)))
            .collect()
    }

    fn spawn_workers(self: &Arc<Self>) {
        let pending = self.dicts.read().unwrap().iter().filter(|d| matches!(d.state(), State::Pending)).count();
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
        let want = pending.min(MAX_WORKERS).min(cores.max(1));
        loop {
            let cur = self.workers.load(Ordering::SeqCst);
            if cur >= want {
                break;
            }
            if self.workers.compare_exchange(cur, cur + 1, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                let me = self.clone();
                std::thread::Builder::new()
                    .name("sg-index".into())
                    .spawn(move || {
                        me.worker();
                        me.workers.fetch_sub(1, Ordering::SeqCst);
                    })
                    .ok();
            }
        }
    }

    fn cache_valid(&self, d: &Dict) -> bool {
        self.read_meta(d).is_some()
    }

    fn read_meta(&self, d: &Dict) -> Option<Meta> {
        let raw = std::fs::read(self.cache_root.join(&d.id).join("meta.json")).ok()?;
        let m: Meta = serde_json::from_slice(&raw).ok()?;
        (m.version == INDEX_VERSION && m.fingerprint == d.fingerprint).then_some(m)
    }

    /// Claims the next pending dictionary: cached ones first, then smallest first.
    fn claim_next(&self) -> Option<Arc<Dict>> {
        let _g = self.claim.lock().unwrap();
        let dicts = self.dicts.read().unwrap();
        let mut pending: Vec<&Arc<Dict>> = dicts.iter().filter(|d| matches!(d.state(), State::Pending)).collect();
        pending.sort_by_key(|d| (!self.cache_valid(d), d.size));
        let d = pending.first().cloned()?.clone();
        *d.state.write().unwrap() = State::Indexing;
        Some(d)
    }

    fn worker(self: &Arc<Self>) {
        while let Some(d) = self.claim_next() {
            self.bump();
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.load_or_build(&d)));
            let st = match r {
                Ok(Ok(l)) => State::Ready(Arc::new(l)),
                Ok(Err(e)) => State::Failed(format!("{e:#}")),
                Err(_) => State::Failed("internal error while indexing".into()),
            };
            *d.state.write().unwrap() = st;
            self.bump();
        }
    }

    fn load_or_build(&self, d: &Dict) -> Result<Loaded> {
        let dir = self.cache_root.join(&d.id);
        if let Some(meta) = self.read_meta(d) {
            if let Ok(l) = self.open_loaded(d, &dir, meta.info) {
                return Ok(l);
            }
        }
        let tmp = self.cache_root.join(format!(
            "{}.tmp-{}-{}",
            d.id,
            std::process::id(),
            std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|x| x.as_nanos()).unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp)?;
        let progress = |p: f32| {
            d.progress.store(p.to_bits(), Ordering::Relaxed);
            self.bump();
        };
        let built = formats::build(d.kind, &d.path, &BuildCtx { dir: &tmp, progress: &progress });
        let info = match built {
            Ok(i) => i,
            Err(e) => {
                let _ = std::fs::remove_dir_all(&tmp);
                return Err(e);
            }
        };
        let meta = Meta { version: INDEX_VERSION, fingerprint: d.fingerprint.clone(), info };
        std::fs::write(tmp.join("meta.json"), serde_json::to_vec(&meta)?)?;
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::rename(&tmp, &dir).context("install index")?;
        self.open_loaded(d, &dir, meta.info)
    }

    fn open_loaded(&self, d: &Dict, dir: &Path, info: DictInfo) -> Result<Loaded> {
        let index = Index::open(dir, "keys")?;
        let reader = formats::open(d.kind, &d.path, dir, &info)?;
        Ok(Loaded { info, index, reader, dir: dir.to_path_buf() })
    }

    /// Blocks until no dictionary is pending or indexing (CLI / tests).
    pub fn wait_idle(&self) {
        loop {
            let busy = self
                .dicts
                .read()
                .unwrap()
                .iter()
                .any(|d| matches!(d.state(), State::Pending | State::Indexing));
            if !busy {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    pub fn summaries(&self) -> Vec<DictSummary> {
        let disabled = self.disabled.read().unwrap();
        self.dicts
            .read()
            .unwrap()
            .iter()
            .map(|d| {
                let st = d.state();
                let (state, error, info) = match &st {
                    State::Pending => ("pending", None, None),
                    State::Indexing => ("indexing", None, None),
                    State::Ready(l) => ("ready", None, Some(&l.info)),
                    State::Failed(e) => ("failed", Some(e.clone()), None),
                };
                let fallback_name = d
                    .path
                    .file_name()
                    .map(|n| {
                        let n = n.to_string_lossy();
                        n.split('.').next().unwrap_or(&n).to_string()
                    })
                    .unwrap_or_default();
                let icon = d.icon_src.as_ref().map(|p| p.to_string_lossy().into_owned()).or_else(|| {
                    let l = d.loaded()?;
                    let rel = l.info.icon.as_ref()?;
                    Some(l.dir.join(rel).to_string_lossy().into_owned())
                });
                let languages = info
                    .map(|i| match (i.source_lang.is_empty(), i.target_lang.is_empty()) {
                        (false, false) if i.source_lang != i.target_lang => format!("{} → {}", i.source_lang, i.target_lang),
                        (false, _) => i.source_lang.clone(),
                        _ => String::new(),
                    })
                    .unwrap_or_default();
                DictSummary {
                    id: d.id.clone(),
                    name: info.map(|i| i.name.clone()).filter(|n| !n.is_empty()).unwrap_or(fallback_name),
                    format: d.kind.label().to_string(),
                    path: d.path.to_string_lossy().into_owned(),
                    state,
                    progress: f32::from_bits(d.progress.load(Ordering::Relaxed)),
                    entries: d.loaded().map(|l| l.index.key_count() as u64).unwrap_or(0),
                    enabled: !disabled.contains(&d.id),
                    icon,
                    about: info.map(|i| about_text(&i.description)).unwrap_or_default(),
                    languages,
                    error,
                    size: d.size,
                }
            })
            .collect()
    }

    // ---------------------------------------------------------------- search

    pub fn suggest(&self, query: &str, limit: usize) -> Vec<Suggestion> {
        let q = query.trim();
        if q.is_empty() || limit == 0 {
            return Vec::new();
        }
        let dicts = self.enabled_ready();
        if q.contains('*') || q.contains('?') {
            return self.glob(&dicts, q, limit);
        }
        let fq = fold::fold(q);
        let lq = fold::lower(q);
        if fq.is_empty() {
            return Vec::new();
        }
        let diacritics = fq != lq;
        // Gather a generous alphabetical window per dictionary, then rank globally.
        let window = (limit * 6).max(240);
        let mut merged: HashMap<Vec<u8>, (String, usize, u32)> = HashMap::new();
        for (prio, (_, l)) in dicts.iter().enumerate() {
            for g in l.index.prefix(fq.as_bytes(), window) {
                merge(&mut merged, &l.index, &g, prio, q);
            }
        }
        // rank: 0 exact, 1 base form, 2 spelled-as-typed prefix, 3 other prefix
        let mut out: Vec<(u8, Vec<u8>, Suggestion)> = merged
            .into_iter()
            .map(|(k, (w, _, c))| {
                let (_, ident) = split_key(&k);
                let r = if ident == lq.as_bytes() {
                    0
                } else if diacritics && !ident.starts_with(lq.as_bytes()) {
                    3
                } else {
                    2
                };
                (r, k, Suggestion { word: w, kind: if r == 0 { "exact" } else { "prefix" }, sources: c })
            })
            .collect();

        // Base forms of inflected input ("running" → "run").
        let has_exact = out.iter().any(|(r, _, _)| *r == 0);
        for lemma in morph::english_lemmas(&lq) {
            if let Some(e) = out.iter_mut().find(|(_, _, s)| fold::lower(&s.word) == lemma) {
                e.0 = 1;
                e.2.kind = "lemma";
                if has_exact {
                    break;
                }
                continue;
            }
            if let Some((w, c)) = self.exact_word(&dicts, &lemma) {
                let k = fold::index_key(&w).unwrap_or_default();
                out.push((1, k, Suggestion { word: w, kind: "lemma", sources: c }));
                if has_exact {
                    break;
                }
            }
        }
        // Within a rank: words found in more dictionaries (≈ more common) first,
        // then shorter, then alphabetical.
        out.sort_by(|a, b| {
            a.0.cmp(&b.0)
                .then(b.2.sources.cmp(&a.2.sources))
                .then(a.2.word.chars().count().cmp(&b.2.word.chars().count()))
                .then(a.1.cmp(&b.1))
        });
        let mut out: Vec<Suggestion> = out.into_iter().map(|(_, _, s)| s).take(limit).collect();

        // Typo tolerance when nothing matches as typed.
        if !has_exact && out.len() < 4 && fq.chars().count() >= 3 {
            let n = fq.chars().count();
            let dist = if n <= 5 { 1 } else { 2 };
            if let Ok(lev) = fst::automaton::Levenshtein::new(&fq, dist) {
                let mut fz: HashMap<Vec<u8>, (String, usize, u32)> = HashMap::new();
                for (prio, (_, l)) in dicts.iter().enumerate() {
                    for g in l.index.search_folded(crate::index::UntilSep(&lev), 64) {
                        merge(&mut fz, &l.index, &g, prio, q);
                    }
                }
                let mut fzv: Vec<(usize, Vec<u8>, String, u32)> = fz
                    .into_iter()
                    .map(|(k, (w, _, c))| {
                        let (f, _) = split_key(&k);
                        (osa_distance(&fq, std::str::from_utf8(f).unwrap_or("")), k, w, c)
                    })
                    .collect();
                fzv.sort_by(|a, b| a.0.cmp(&b.0).then(b.3.cmp(&a.3)).then(a.1.cmp(&b.1)));
                for (_, _, w, c) in fzv {
                    if out.len() >= limit {
                        break;
                    }
                    if !out.iter().any(|s| fold::lower(&s.word) == fold::lower(&w)) {
                        out.push(Suggestion { word: w, kind: "fuzzy", sources: c });
                    }
                }
            }
        }
        out
    }

    fn exact_word(&self, dicts: &[(Arc<Dict>, Arc<Loaded>)], word: &str) -> Option<(String, u32)> {
        let key = fold::index_key(word)?;
        let mut found: Option<String> = None;
        let mut count = 0;
        for (_, l) in dicts {
            if let Some(g) = l.index.get(&key) {
                count += 1;
                if found.is_none() {
                    found = l.index.entry(g.start).map(|(w, _)| w.to_string());
                }
            }
        }
        found.map(|w| (w, count))
    }

    fn glob(&self, dicts: &[(Arc<Dict>, Arc<Loaded>)], q: &str, limit: usize) -> Vec<Suggestion> {
        let fq = fold::fold(q);
        let pat: Vec<char> = fq.chars().collect();
        let lit: String = fq.chars().take_while(|c| *c != '*' && *c != '?').collect();
        let mut merged: HashMap<Vec<u8>, (String, usize, u32)> = HashMap::new();
        let mut buf: Vec<char> = Vec::new();
        for (prio, (_, l)) in dicts.iter().enumerate() {
            let mut n = 0;
            let mut scanned = 0usize;
            l.index.scan_prefix(lit.as_bytes(), |k, g| {
                scanned += 1;
                let (f, _) = split_key(k);
                buf.clear();
                buf.extend(std::str::from_utf8(f).unwrap_or("").chars());
                if glob_match(&pat, &buf) {
                    merge(&mut merged, &l.index, &g, prio, q);
                    n += 1;
                }
                n < limit && scanned < 2_000_000
            });
        }
        let mut v: Vec<(Vec<u8>, String, u32)> = merged.into_iter().map(|(k, (w, _, c))| (k, w, c)).collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v.into_iter().take(limit).map(|(_, w, c)| Suggestion { word: w, kind: "glob", sources: c }).collect()
    }

    // ---------------------------------------------------------------- lookup

    pub fn lookup(&self, word: &str) -> LookupResult {
        let word = word.trim();
        let dicts = self.enabled_ready();
        let hits = Self::hits_for(&dicts, word);
        if !hits.is_empty() {
            return LookupResult { word: word.to_string(), via: None, hits };
        }
        for lemma in morph::english_lemmas(&fold::lower(word)) {
            let hits = Self::hits_for(&dicts, &lemma);
            if !hits.is_empty() {
                return LookupResult { word: word.to_string(), via: Some(lemma), hits };
            }
        }
        LookupResult { word: word.to_string(), via: None, hits: Vec::new() }
    }

    fn hits_for(dicts: &[(Arc<Dict>, Arc<Loaded>)], word: &str) -> Vec<Hit> {
        let Some(key) = fold::index_key(word) else { return Vec::new() };
        let folded = split_key(&key).0.to_vec();
        let mut hits = Vec::new();
        for (d, l) in dicts {
            let groups: Vec<Group> = match l.index.get(&key) {
                Some(g) => vec![g],
                None => l.index.folded(&folded),
            };
            let mut entries = Vec::new();
            let mut words = Vec::new();
            let mut seen = HashSet::new();
            for g in groups {
                for i in g.range() {
                    if let Some((w, loc)) = l.index.entry(i) {
                        if seen.insert(loc) {
                            entries.push(i);
                            if !words.iter().any(|x: &String| x == w) {
                                words.push(w.to_string());
                            }
                        }
                    }
                }
            }
            if !entries.is_empty() {
                hits.push(Hit { dict: d.id.clone(), name: l.info.name.clone(), entries, words, foreign: l.reader.foreign() });
            }
        }
        hits
    }

    pub fn random_word(&self) -> Option<String> {
        let dicts = self.enabled_ready();
        let total: u64 = dicts.iter().map(|(_, l)| l.index.len() as u64).sum();
        if total == 0 {
            return None;
        }
        for _ in 0..64 {
            let r = self.next_rand() % total;
            let mut acc = 0u64;
            for (_, l) in &dicts {
                let n = l.index.len() as u64;
                if r < acc + n {
                    let (w, _) = l.index.entry((r - acc) as usize)?;
                    let ok = w.chars().count() >= 3
                        && w.chars().count() <= 24
                        && w.chars().all(|c| c.is_alphabetic() || c == ' ' || c == '-')
                        && w.chars().next().is_some_and(|c| c.is_lowercase());
                    if ok {
                        return Some(w.to_string());
                    }
                    break;
                }
                acc += n;
            }
        }
        None
    }

    fn next_rand(&self) -> u64 {
        // xorshift64*
        let mut x = self.seed.load(Ordering::Relaxed);
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.seed.store(x, Ordering::Relaxed);
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }

    // ---------------------------------------------------------------- pages

    /// Full HTML document for a set of entries of one dictionary.
    pub fn article_page(&self, id: &str, entries: &[usize]) -> Result<String> {
        let d = self.dict(id).context("unknown dictionary")?;
        let l = d.loaded().context("dictionary not ready")?;
        let foreign = l.reader.foreign();
        let mut body = String::new();
        for (n, &i) in entries.iter().enumerate() {
            let Some((w, loc)) = l.index.entry(i) else { continue };
            let html = match l.reader.article(&l.index, w, loc) {
                Ok(h) => h,
                Err(e) => format!("<p class=\"sg-error\">Could not read this entry: {}</p>", html_escape(&format!("{e:#}"))),
            };
            if n > 0 {
                body.push_str("<hr class=\"sg-sep\">");
            }
            body.push_str("<article class=\"sg-entry\">");
            if !foreign && !starts_with_headword(&html, w) {
                body.push_str("<h1 class=\"sg-hw\">");
                html_escape_into(&mut body, w);
                body.push_str("</h1>");
            }
            body.push_str(&html);
            body.push_str("</article>");
        }
        let class = if foreign { "sg-foreign" } else { "sg-native" };
        Ok(format!(
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">\
             <link rel=\"stylesheet\" href=\"sgloss://app/article.css\"></head>\
             <body class=\"{class} fmt-{fmt}\">{body}</body></html>",
            fmt = d.kind.label().to_ascii_lowercase()
        ))
    }

    pub fn resource(&self, id: &str, path: &str) -> Result<Option<Vec<u8>>> {
        let d = self.dict(id).context("unknown dictionary")?;
        let l = d.loaded().context("dictionary not ready")?;
        l.reader.resource(path)
    }

    /// Audio for `sound://` links, transcoded when AVFoundation can't play it.
    pub fn audio(&self, id: &str, path: &str) -> Result<Option<Vec<u8>>> {
        let path = percent_encoding::percent_decode_str(path).decode_utf8_lossy().into_owned();
        let path = path.trim_start_matches('/');
        match self.resource(id, path)? {
            Some(b) => Ok(Some(crate::audio::playable(b)?)),
            None => Ok(None),
        }
    }

    /// Serves `sgloss://<dict-id>/...` URLs: `/?e=1,2` articles, other paths resources.
    pub fn serve(&self, url: &str) -> Result<(Vec<u8>, String)> {
        let rest = url.strip_prefix("sgloss://").context("bad scheme")?;
        let (host, path_q) = rest.split_once('/').unwrap_or((rest, ""));
        let (path, query) = path_q.split_once('?').unwrap_or((path_q, ""));
        let path = path.split('#').next().unwrap_or("");
        let host = host.to_ascii_lowercase();
        if path.is_empty() {
            let entries: Vec<usize> = query
                .split('&')
                .find_map(|kv| kv.strip_prefix("e="))
                .unwrap_or("")
                .split(',')
                .filter_map(|s| s.parse().ok())
                .collect();
            if entries.is_empty() {
                bail!("no entries");
            }
            let html = self.article_page(&host, &entries)?;
            return Ok((html.into_bytes(), "text/html; charset=utf-8".into()));
        }
        let decoded = percent_encoding::percent_decode_str(path).decode_utf8_lossy().into_owned();
        match self.resource(&host, &decoded)? {
            Some(b) => {
                let mime = mime_for(&decoded);
                let mime = if mime.starts_with("text/") { format!("{mime}; charset=utf-8") } else { mime.to_string() };
                Ok((b, mime))
            }
            None => bail!("not found: {decoded}"),
        }
    }
}

fn merge(map: &mut HashMap<Vec<u8>, (String, usize, u32)>, index: &Index, g: &Group, prio: usize, q: &str) {
    let Some((w, _)) = index.entry(g.start) else { return };
    // Prefer the spelling that matches the query exactly.
    let exact = (g.start..g.start + g.count).filter_map(|i| index.entry(i)).find(|(x, _)| *x == q).map(|(x, _)| x);
    match map.get_mut(&g.key) {
        Some(e) => {
            e.2 += 1;
            if let Some(x) = exact {
                if e.0 != q {
                    e.0 = x.to_string();
                }
            } else if prio < e.1 && e.0 != q {
                e.0 = w.to_string();
                e.1 = prio;
            }
        }
        None => {
            map.insert(g.key.clone(), (exact.unwrap_or(w).to_string(), prio, 1));
        }
    }
}

/// Optimal-string-alignment distance (Levenshtein plus adjacent transpositions).
fn osa_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let w = b.len() + 1;
    let mut d = vec![0usize; (a.len() + 1) * w];
    for i in 0..=a.len() {
        d[i * w] = i;
    }
    for j in 0..=b.len() {
        d[j] = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let mut v = (d[(i - 1) * w + j] + 1).min(d[i * w + j - 1] + 1).min(d[(i - 1) * w + j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                v = v.min(d[(i - 2) * w + j - 2] + 1);
            }
            d[i * w + j] = v;
        }
    }
    d[a.len() * w + b.len()]
}

/// True when an article's visible text already opens with its headword
/// (ignoring syllable dots, stress marks and case), so no heading is added.
fn starts_with_headword(html: &str, word: &str) -> bool {
    let mut text = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => {
                text.push(c);
                if text.len() > 300 {
                    break;
                }
            }
            _ => {}
        }
    }
    let clean = |s: &str| -> Vec<char> {
        fold::fold(&crate::util::unescape_entities(s))
            .chars()
            .filter(|c| !matches!(c, '·' | '‧' | '•' | 'ˈ' | 'ˌ' | '\'' | '*' | '|' | '-'))
            .collect::<String>()
            // leading markers such as "↑", "—", "▸" aren't part of the headword
            .trim_start_matches(|c: char| !c.is_alphanumeric())
            .trim_end()
            .chars()
            .collect()
    };
    let t = clean(&text);
    let w = clean(word);
    if w.is_empty() || t.len() < w.len() || t[..w.len()] != w[..] {
        return false;
    }
    // The headword must end at a word boundary in the text.
    t.get(w.len()).is_none_or(|c| !c.is_alphanumeric()) || {
        // allow superscript homograph numbers like "bank1"
        t[w.len()..].iter().take_while(|c| c.is_ascii_digit()).count() > 0
    }
}

fn expand_tilde(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(h) = std::env::var("HOME") {
            return format!("{h}/{rest}");
        }
    }
    p.to_string()
}

fn walk(p: &Path, depth: usize, out: &mut Vec<(Kind, PathBuf)>, seen: &mut HashSet<PathBuf>, budget: &mut usize) {
    if *budget == 0 || depth > 6 {
        return;
    }
    *budget -= 1;
    let Ok(meta) = std::fs::metadata(p) else { return };
    if meta.is_file() {
        if let Some(k) = formats::detect(p) {
            let canon = std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
            if seen.insert(canon.clone()) {
                // Prefer `.dsl` over a sibling `.dsl.dz` duplicate.
                if k == Kind::Dsl && canon.to_string_lossy().ends_with(".dz") {
                    let plain = PathBuf::from(canon.to_string_lossy().trim_end_matches(".dz").to_string());
                    if plain.is_file() {
                        return;
                    }
                }
                out.push((k, canon));
            }
        }
        return;
    }
    if !meta.is_dir() {
        return;
    }
    let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    if depth > 0 && (name.starts_with('.') || name.ends_with(".files") || name == "res" || name.ends_with(".app")) {
        return;
    }
    let Ok(rd) = std::fs::read_dir(p) else { return };
    let mut entries: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    entries.sort();
    for e in entries {
        walk(&e, depth + 1, out, seen, budget);
    }
}

/// Plain-text "about" from a (possibly HTML) description.
fn about_text(desc: &str) -> String {
    let mut out = String::with_capacity(desc.len());
    let mut in_tag = false;
    let mut tag = String::new();
    let lower = desc.to_ascii_lowercase();
    let mut skip_until: Option<&str> = None;
    let mut i = 0;
    let b = desc.as_bytes();
    while i < b.len() {
        if let Some(end) = skip_until {
            match lower[i..].find(end) {
                Some(p) => {
                    i += p + end.len();
                    skip_until = None;
                    continue;
                }
                None => break,
            }
        }
        let c = desc[i..].chars().next().unwrap();
        if in_tag {
            if c == '>' {
                in_tag = false;
                let t = tag.trim_start_matches('/').split_whitespace().next().unwrap_or("").to_ascii_lowercase();
                if matches!(t.as_str(), "br" | "p" | "div" | "li" | "tr" | "h1" | "h2" | "h3" | "h4" | "h5") {
                    out.push('\n');
                }
                if !tag.starts_with('/') && (t == "style" || t == "script") {
                    skip_until = Some(if t == "style" { "</style>" } else { "</script>" });
                }
                tag.clear();
            } else {
                tag.push(c);
            }
        } else if c == '<' {
            in_tag = true;
        } else {
            out.push(c);
        }
        i += c.len_utf8();
    }
    let text = crate::util::unescape_entities(&out);
    let lines: Vec<String> = text
        .lines()
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|l| !l.is_empty())
        .collect();
    let mut s = lines.join("\n");
    if s.chars().count() > 600 {
        s = s.chars().take(600).collect::<String>() + "…";
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn about() {
        assert_eq!(about_text("<style>.x{}</style><h1>Title</h1><p>Hello &amp; welcome</p>"), "Title\nHello & welcome");
        assert_eq!(osa_distance("kitten", "sitting"), 3);
        assert!(starts_with_headword("<b>ab·a·cus</b>(ăb)", "abacus"));
        assert!(starts_with_headword("<div class=\"m m0\"><b>beautiful</b> UK", "beautiful"));
        assert!(starts_with_headword("<b>Run</b> <i>verb</i>", "run"));
        assert!(!starts_with_headword("<b>running</b>", "run"));
        assert!(!starts_with_headword("[serendipiti]", "serendipity"));
        assert!(starts_with_headword("<b>a la carte</b>", "à la carte"));
        assert!(starts_with_headword("<b>Kind and thoughtful</b>", "↑Kind and thoughtful"));
        assert!(starts_with_headword("—<b>run</b> UK", "run"));
        assert_eq!(osa_distance("recieve", "receive"), 1);
    }
}
