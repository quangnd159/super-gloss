//! C ABI for the Swift app. Strings are UTF-8, returned strings/buffers must be
//! released with `sg_free_string` / `sg_free_bytes`. Every entry point catches
//! panics so a malformed dictionary can never take the app down.

use crate::library::{Config, Library};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

pub struct SGLibrary(Arc<Library>);

fn cstr<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        return "";
    }
    // SAFETY: callers pass valid NUL-terminated strings.
    unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("")
}

fn out_string(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn json<T: serde::Serialize>(v: &T) -> *mut c_char {
    out_string(serde_json::to_string(v).unwrap_or_else(|_| "null".into()))
}

fn guard<T>(default: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(default)
}

fn lib<'a>(p: *const SGLibrary) -> Option<&'a Arc<Library>> {
    // SAFETY: the pointer comes from sg_library_new and stays valid until sg_library_free.
    unsafe { p.as_ref() }.map(|l| &l.0)
}

#[no_mangle]
pub extern "C" fn sg_library_new(cache_dir: *const c_char) -> *mut SGLibrary {
    guard(std::ptr::null_mut(), || Box::into_raw(Box::new(SGLibrary(Library::new(cstr(cache_dir))))))
}

/// # Safety
/// `p` must come from `sg_library_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn sg_library_free(p: *mut SGLibrary) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

/// Applies `{"roots":[..],"order":[..],"disabled":[..]}` and starts indexing. Malformed
/// JSON keeps the current configuration: read as empty, it would remove every dictionary.
#[no_mangle]
pub extern "C" fn sg_configure(p: *const SGLibrary, config_json: *const c_char) {
    guard((), || {
        if let Some(l) = lib(p) {
            match serde_json::from_str::<Config>(cstr(config_json)) {
                Ok(cfg) => l.configure(&cfg),
                Err(e) => eprintln!("sg_configure: ignoring malformed config: {e}"),
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn sg_set_enabled(p: *const SGLibrary, id: *const c_char, enabled: bool) {
    guard((), || {
        if let Some(l) = lib(p) {
            l.set_enabled(cstr(id), enabled)
        }
    })
}

#[no_mangle]
pub extern "C" fn sg_reindex(p: *const SGLibrary, id: *const c_char) {
    guard((), || {
        if let Some(l) = lib(p) {
            l.reindex(cstr(id))
        }
    })
}

/// Monotonic counter that changes whenever dictionary state changes.
#[no_mangle]
pub extern "C" fn sg_generation(p: *const SGLibrary) -> u64 {
    guard(0, || lib(p).map(|l| l.generation()).unwrap_or(0))
}

#[no_mangle]
pub extern "C" fn sg_dictionaries(p: *const SGLibrary) -> *mut c_char {
    guard(std::ptr::null_mut(), || lib(p).map(|l| json(&l.summaries())).unwrap_or(std::ptr::null_mut()))
}

#[no_mangle]
pub extern "C" fn sg_suggest(p: *const SGLibrary, query: *const c_char, limit: u32) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        lib(p).map(|l| json(&l.suggest(cstr(query), limit as usize))).unwrap_or(std::ptr::null_mut())
    })
}

#[no_mangle]
pub extern "C" fn sg_lookup(p: *const SGLibrary, word: *const c_char) -> *mut c_char {
    guard(std::ptr::null_mut(), || lib(p).map(|l| json(&l.lookup(cstr(word)))).unwrap_or(std::ptr::null_mut()))
}

/// Resolves an `entry://` target clicked inside dictionary `dict` to `{word,label,anchor}`.
#[no_mangle]
pub extern "C" fn sg_resolve_link(p: *const SGLibrary, dict: *const c_char, target: *const c_char) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        lib(p).map(|l| json(&l.resolve_link(cstr(dict), cstr(target)))).unwrap_or(std::ptr::null_mut())
    })
}

/// Readable form of a word or link key for the search line ("above_1" → "above").
#[no_mangle]
pub extern "C" fn sg_link_label(key: *const c_char) -> *mut c_char {
    guard(std::ptr::null_mut(), || out_string(crate::library::link_label(cstr(key))))
}

#[no_mangle]
pub extern "C" fn sg_random_word(p: *const SGLibrary) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        lib(p).and_then(|l| l.random_word()).map(out_string).unwrap_or(std::ptr::null_mut())
    })
}

/// Serves an `sgloss://<dict>/…` URL. Returns the body (or NULL when not found)
/// and writes its length and a newly allocated MIME type string.
///
/// # Safety
/// `out_len` and `out_mime` must be valid pointers.
#[no_mangle]
pub unsafe extern "C" fn sg_serve(
    p: *const SGLibrary,
    url: *const c_char,
    out_len: *mut usize,
    out_mime: *mut *mut c_char,
) -> *mut u8 {
    *out_len = 0;
    *out_mime = std::ptr::null_mut();
    let r = guard(None, || lib(p).and_then(|l| l.serve(cstr(url)).ok()));
    match r {
        Some((bytes, mime)) => {
            *out_mime = out_string(mime);
            out_bytes(bytes, out_len)
        }
        None => std::ptr::null_mut(),
    }
}

fn out_bytes(bytes: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    let mut b = bytes.into_boxed_slice();
    // SAFETY: caller passes a valid pointer.
    unsafe { *out_len = b.len() };
    let ptr = b.as_mut_ptr();
    std::mem::forget(b);
    ptr
}

/// Playable audio bytes for a `sound://` path of a dictionary (NULL if missing).
///
/// # Safety
/// `out_len` must be a valid pointer.
#[no_mangle]
pub unsafe extern "C" fn sg_audio(p: *const SGLibrary, id: *const c_char, path: *const c_char, out_len: *mut usize) -> *mut u8 {
    *out_len = 0;
    let r = guard(None, || lib(p).and_then(|l| l.audio(cstr(id), cstr(path)).ok().flatten()));
    match r {
        Some(b) => out_bytes(b, out_len),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `s` must come from this library.
#[no_mangle]
pub unsafe extern "C" fn sg_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// # Safety
/// `ptr`/`len` must come from `sg_serve`.
#[no_mangle]
pub unsafe extern "C" fn sg_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}
