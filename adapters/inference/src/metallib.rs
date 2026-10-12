//! Which `mlx.metallib` MLX loads.
//!
//! The pinned MLX fork searches: `PMETAL_METALLIB_PATH`, then the absolute build-directory
//! path compiled into the library, then `~/.cache/pmetal`, and only then the file next to
//! the library. On a build machine the compiled-in path would therefore shadow the bundled
//! copy. When a `mlx.metallib` sits next to this library (the packaged app), the adapter
//! pins it through upstream MLX's strict override instead, before any Metal work: MLX then
//! loads exactly that file or fails device creation, never falling back to another one.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

unsafe extern "C" {
    fn lw_mlx_set_metallib_path(path: *const std::ffi::c_char);
}

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

/// Pin MLX to `path` (strict: no fallback). Must run before the first Metal operation.
pub fn pin(path: &Path) {
    let c = CString::new(path.as_os_str().as_encoded_bytes()).expect("path without NUL");
    unsafe { lw_mlx_set_metallib_path(c.as_ptr()) };
}

/// How the metallib was chosen, decided once per process before any MLX work.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// The bundled file next to this library, pinned strictly.
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
    RESOLUTION.get_or_init(|| {
        let candidate = library_dir().map(|d| d.join("mlx.metallib"));
        match candidate {
            Some(path) if path.is_file() => {
                pin(&path);
                Resolution::Bundled(path)
            }
            _ => Resolution::MlxSearch,
        }
    })
}
