//! Super Gloss core: dictionary formats, indexing, search and rendering.

pub mod audio;
pub mod ffi;
pub mod fold;
pub mod formats;
pub mod index;
pub mod library;
pub mod morph;
pub mod store;
pub mod util;

pub use library::{Config, Library, LookupResult, Suggestion};
