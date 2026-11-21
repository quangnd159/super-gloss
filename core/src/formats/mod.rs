pub mod bgl;
pub mod dictd;
pub mod dsl;
pub mod dsl_render;
pub mod markup;
pub mod mdict;
pub mod stardict;
pub mod xdxf;

use crate::index::{Index, Locator};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct DictInfo {
    pub name: String,
    pub format: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub source_lang: String,
    #[serde(default)]
    pub target_lang: String,
    #[serde(default)]
    pub entries: u64,
    /// Icon path relative to the cache directory (e.g. extracted from the file).
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub extra: serde_json::Value,
}

impl DictInfo {
    pub fn new(name: impl Into<String>, format: &str) -> Self {
        DictInfo { name: name.into().trim().to_string(), format: format.into(), ..Default::default() }
    }
}

pub struct BuildCtx<'a> {
    pub dir: &'a Path,
    pub progress: &'a (dyn Fn(f32) + Sync),
}

impl BuildCtx<'_> {
    pub fn progress(&self, p: f32) {
        (self.progress)(p.clamp(0.0, 1.0));
    }
}

pub trait Reader: Send + Sync {
    /// HTML fragment for one entry.
    fn article(&self, index: &Index, word: &str, loc: Locator) -> Result<String>;
    /// Resource bytes for a path relative to the dictionary.
    fn resource(&self, path: &str) -> Result<Option<Vec<u8>>>;
    /// True when the HTML carries the dictionary's own design (MDict, Babylon, HTML
    /// StarDict). Such articles include their own headword and are not restyled.
    fn foreign(&self) -> bool;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    Mdict,
    StarDict,
    Dsl,
    Babylon,
    Dictd,
    Xdxf,
}

impl Kind {
    /// Bumped when what this format's index or cached articles hold changes; its
    /// dictionaries are then rebuilt, the others kept. (Babylon, StarDict 1: other
    /// forms open under their entry's headword.)
    pub fn revision(self) -> u32 {
        match self {
            Kind::Babylon | Kind::StarDict => 1,
            _ => 0,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Kind::Mdict => "MDict",
            Kind::StarDict => "StarDict",
            Kind::Dsl => "DSL",
            Kind::Babylon => "Babylon",
            Kind::Dictd => "dictd",
            Kind::Xdxf => "XDXF",
        }
    }
}

/// Recognizes the main file of a dictionary.
pub fn detect(path: &Path) -> Option<Kind> {
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    if name.starts_with("._") {
        return None; // AppleDouble metadata on non-HFS volumes
    }
    if name.ends_with(".mdx") {
        Some(Kind::Mdict)
    } else if name.ends_with(".ifo") {
        Some(Kind::StarDict)
    } else if (name.ends_with(".dsl") || name.ends_with(".dsl.dz")) && !dsl::is_abbrev_file(path) {
        Some(Kind::Dsl)
    } else if name.ends_with(".bgl") {
        Some(Kind::Babylon)
    } else if name.ends_with(".index") && dictd::data_path(path).is_some() {
        Some(Kind::Dictd)
    } else if name.ends_with(".xdxf") || name.ends_with(".xdxf.dz") {
        Some(Kind::Xdxf)
    } else {
        None
    }
}

/// Files whose changes should invalidate the index (besides the main file).
pub fn companion_files(kind: Kind, path: &Path) -> Vec<PathBuf> {
    match kind {
        Kind::Mdict => mdict::companion_files(path),
        Kind::StarDict => stardict::companion_files(path),
        Kind::Dsl => dsl::companion_files(path),
        Kind::Dictd => dictd::companion_files(path),
        Kind::Babylon | Kind::Xdxf => Vec::new(),
    }
}

pub fn build(kind: Kind, path: &Path, ctx: &BuildCtx) -> Result<DictInfo> {
    match kind {
        Kind::Mdict => mdict::build(path, ctx),
        Kind::StarDict => stardict::build(path, ctx),
        Kind::Dsl => dsl::build(path, ctx),
        Kind::Babylon => bgl::build(path, ctx),
        Kind::Dictd => dictd::build(path, ctx),
        Kind::Xdxf => xdxf::build(path, ctx),
    }
}

pub fn open(kind: Kind, path: &Path, cache: &Path, info: &DictInfo) -> Result<Box<dyn Reader>> {
    match kind {
        Kind::Mdict => mdict::open(path, cache, info),
        Kind::StarDict => stardict::open(path, cache, info),
        Kind::Dsl => dsl::open(path, cache, info),
        Kind::Babylon => bgl::open(path, cache, info),
        Kind::Dictd => dictd::open(path, cache, info),
        Kind::Xdxf => xdxf::open(path, cache, info),
    }
}

/// Finds an icon image shipped next to the dictionary.
pub fn find_icon(kind: Kind, path: &Path, siblings_have_dicts: bool) -> Option<PathBuf> {
    let dir = path.parent()?;
    let mut stem = path.file_name()?.to_string_lossy().to_string();
    for suf in [".dz", ".dsl", ".mdx", ".ifo", ".bgl", ".index", ".xdxf"] {
        if let Some(s) = stem.strip_suffix(suf) {
            stem = s.to_string();
        }
    }
    let exts = ["png", "jpg", "jpeg", "bmp", "ico", "gif", "tif", "tiff"];
    for e in exts {
        let p = dir.join(format!("{stem}.{e}"));
        if p.is_file() {
            return Some(p);
        }
        if let Some(p) = crate::util::find_case_insensitive(dir, &format!("{stem}.{e}")) {
            return Some(p);
        }
    }
    if kind == Kind::Dsl {
        return None;
    }
    // A folder holding a single dictionary: use the folder's lone image.
    if !siblings_have_dicts {
        let imgs: Vec<PathBuf> = std::fs::read_dir(dir)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                let n = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
                !n.starts_with("._") && exts.iter().any(|e| n.ends_with(&format!(".{e}")))
            })
            .collect();
        if imgs.len() == 1 {
            return imgs.into_iter().next();
        }
        // Prefer a non-cover image when there are a couple.
        if let Some(p) = imgs.iter().find(|p| !p.to_string_lossy().to_lowercase().contains("cover")) {
            if imgs.len() <= 3 {
                return Some(p.clone());
            }
        }
    }
    None
}
