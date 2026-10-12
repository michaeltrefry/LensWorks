//! Which `mlx.metallib` MLX loads.
//!
//! The pinned MLX fork searches: `PMETAL_METALLIB_PATH`, then the absolute build-directory
//! path compiled into the library, then `~/.cache/pmetal`, and only then the file next to
//! the library. On a build machine the compiled-in path would therefore shadow the bundled
//! copy. The packaged app ships the metallib in `Contents/Resources` (sealed by the bundle
//! signature) with this library in `Contents/Helpers`; the adapter pins that file through
//! upstream MLX's strict override before any Metal work, so MLX loads exactly that file or
//! fails device creation, never falling back to another one.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

unsafe extern "C" {
    fn lw_mlx_set_metallib_path(path: *const std::ffi::c_char);
    fn lw_mlx_get_metallib_path(out: *mut std::ffi::c_char, capacity: usize) -> usize;
}

pub const METALLIB: &str = "mlx.metallib";

/// The directory of the binary that contains this adapter code.
pub fn library_dir() -> Option<PathBuf> {
    let mut info: libc::Dl_info = unsafe { std::mem::zeroed() };
    let found = unsafe { libc::dladdr(library_dir as *const std::ffi::c_void, &mut info) };
    if found == 0 || info.dli_fname.is_null() {
        return None;
    }
    let path = unsafe { CStr::from_ptr(info.dli_fname) }.to_str().ok()?;
    Path::new(path).parent().map(Path::to_path_buf)
}

/// The metallib to pin for a library living in `lib_dir`: `Contents/Resources/mlx.metallib`
/// when the library sits in an app bundle's `Contents/Helpers`, else a `mlx.metallib` next to
/// the library (flat deployments). `None` when neither file exists.
pub fn locate(lib_dir: &Path) -> Option<PathBuf> {
    let in_bundle = lib_dir.file_name().is_some_and(|n| n == "Helpers")
        && lib_dir
            .parent()
            .and_then(Path::file_name)
            .is_some_and(|n| n == "Contents");
    let bundled = in_bundle.then(|| lib_dir.parent().unwrap().join("Resources").join(METALLIB));
    bundled
        .into_iter()
        .chain(std::iter::once(lib_dir.join(METALLIB)))
        .find(|p| p.is_file())
}

/// Pin MLX to `path` (strict: no fallback). Must run before the first Metal operation.
pub fn pin(path: &Path) {
    let c = CString::new(path.as_os_str().as_encoded_bytes()).expect("path without NUL");
    unsafe { lw_mlx_set_metallib_path(c.as_ptr()) };
}

/// MLX's own record of the strictly pinned metallib (`None` when MLX uses its search order).
/// Once a Metal operation has succeeded, this is the file MLX loaded.
pub fn mlx_pinned_path() -> Option<PathBuf> {
    let len = unsafe { lw_mlx_get_metallib_path(std::ptr::null_mut(), 0) };
    if len == 0 {
        return None;
    }
    let mut buf = vec![0u8; len + 1];
    unsafe { lw_mlx_get_metallib_path(buf.as_mut_ptr().cast(), buf.len()) };
    buf.truncate(len);
    Some(PathBuf::from(String::from_utf8_lossy(&buf).into_owned()))
}

/// How the metallib was chosen, decided once per process before any MLX work.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// The bundled file, pinned strictly.
    Bundled(PathBuf),
    /// No bundled file (development/test builds): MLX's own search order applies.
    MlxSearch,
}

impl Resolution {
    pub fn describe(&self) -> String {
        match self {
            Resolution::Bundled(p) => p.display().to_string(),
            Resolution::MlxSearch => "mlx_search_order".into(),
        }
    }
}

pub fn resolve_once() -> &'static Resolution {
    static RESOLUTION: OnceLock<Resolution> = OnceLock::new();
    RESOLUTION.get_or_init(|| match library_dir().as_deref().and_then(locate) {
        Some(path) => {
            pin(&path);
            Resolution::Bundled(path)
        }
        None => Resolution::MlxSearch,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bundle_pins_the_sealed_resources_copy_and_flat_layouts_the_colocated_one() {
        let root = tempfile::tempdir().unwrap();
        let contents = root.path().join("LensWorks.app/Contents");
        let helpers = contents.join("Helpers");
        std::fs::create_dir_all(&helpers).unwrap();
        std::fs::create_dir_all(contents.join("Resources")).unwrap();
        assert_eq!(locate(&helpers), None);
        std::fs::write(helpers.join(METALLIB), b"x").unwrap();
        assert_eq!(locate(&helpers), Some(helpers.join(METALLIB)));
        std::fs::write(contents.join("Resources").join(METALLIB), b"x").unwrap();
        assert_eq!(
            locate(&helpers),
            Some(contents.join("Resources").join(METALLIB))
        );
        // A Resources directory is only consulted from an app bundle's Helpers.
        let flat = root.path().join("lib");
        std::fs::create_dir_all(flat.join("Resources")).unwrap();
        std::fs::write(flat.join("Resources").join(METALLIB), b"x").unwrap();
        assert_eq!(locate(&flat), None);
    }
}
