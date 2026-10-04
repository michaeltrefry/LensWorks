//! LensWorks-owned, blocking C/JSON boundary over the pinned PhotoCatalog core.
pub mod full_decode;
mod managed;
pub use managed::{
    lw_catalog_buffer_copy, lw_catalog_buffer_release, lw_catalog_managed_request,
    lw_catalog_subscribe, lw_catalog_unsubscribe_and_drain,
};
use photocatalog::Catalog;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::{Component, Path, PathBuf},
    sync::Mutex,
};

pub const SOURCE_REVISION: &str = "f4f8d3f12acc77fe5632720702c52a7cfefb5b58";
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_ITEMS: usize = 1000;
// Stateless calls close their catalog before returning. This mutex prevents
// competing native callers from mutating the same catalog during admission.
static REQUEST_LOCK: Mutex<()> = Mutex::new(());

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    op: Operation,
    catalog_path: String,
    source_path: Option<String>,
    after: Option<i64>,
    limit: Option<usize>,
    max_files: Option<usize>,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation {
    Create,
    Open,
    List,
    Import,
}

struct Failure {
    code: &'static str,
    message: String,
}
type Result<T> = std::result::Result<T, Failure>;
fn failure(code: &'static str, message: impl Into<String>) -> Failure {
    Failure {
        code,
        message: message.into(),
    }
}
fn catalog_failure(error: impl std::fmt::Display) -> Failure {
    failure("catalog_failure", format!("{error:#}"))
}
fn absolute_path(value: &str) -> Result<PathBuf> {
    if value.is_empty()
        || value.len() > 32768
        || value.contains('\0')
        || !Path::new(value).is_absolute()
        || Path::new(value)
            .components()
            .any(|part| part == Component::ParentDir)
    {
        return Err(failure(
            "invalid_request",
            "paths must be absolute, nonempty UTF-8 paths of at most 32768 bytes without parent traversal",
        ));
    }
    Ok(PathBuf::from(value))
}
fn existing_catalog(path: &Path) -> Result<PathBuf> {
    if !managed_entry(path, true)? {
        return Err(failure("not_found", "catalog directory does not exist"));
    }
    let root = std::fs::canonicalize(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            failure("not_found", "catalog directory does not exist")
        } else {
            catalog_failure(error)
        }
    })?;
    validate_managed_catalog(&root)?;
    if !managed_entry(&root.join("catalog.sqlite3"), false)? {
        return Err(failure(
            "not_found",
            "catalog.sqlite3 does not exist at the selected catalog path",
        ));
    }
    Ok(root)
}

// Catalog::open initializes/migrates SQLite and creates previews before its
// retained object-identity check. Admit every mutable path used by this minimal
// compatibility route before opening. A redirected preview directory would let
// the importer publish/remove preview filenames inside originals.
fn managed_entry(path: &Path, directory: bool) -> Result<bool> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(catalog_failure(error)),
    };
    let kind = metadata.file_type();
    if kind.is_symlink() || (directory && !kind.is_dir()) || (!directory && !kind.is_file()) {
        return Err(failure(
            "unsafe_location",
            format!(
                "catalog storage must use a private {}: {}",
                if directory {
                    "directory"
                } else {
                    "regular file"
                },
                path.display()
            ),
        ));
    }
    #[cfg(unix)]
    if !directory {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() != 1 {
            return Err(failure(
                "unsafe_location",
                format!(
                    "catalog storage must not use a hard-linked file: {}",
                    path.display()
                ),
            ));
        }
    }
    Ok(true)
}

fn validate_managed_catalog(root: &Path) -> Result<()> {
    managed_entry(root, true)?;
    managed_entry(&root.join("previews"), true)?;
    for name in [
        "catalog.sqlite3",
        "catalog.sqlite3-wal",
        "catalog.sqlite3-shm",
        "catalog.sqlite3-journal",
        "import.lock",
    ] {
        managed_entry(&root.join(name), false)?;
    }
    Ok(())
}
fn bounded(value: usize, label: &str) -> Result<usize> {
    if !(1..=MAX_ITEMS).contains(&value) {
        return Err(failure(
            "invalid_request",
            format!("{label} must be 1..={MAX_ITEMS}"),
        ));
    }
    Ok(value)
}
fn execute(bytes: &[u8]) -> Result<Value> {
    if bytes.len() > MAX_REQUEST_BYTES {
        return Err(failure("invalid_request", "request exceeds 1 MiB"));
    }
    let request: Request =
        serde_json::from_slice(bytes).map_err(|e| failure("invalid_request", e.to_string()))?;
    if request.version != 1 {
        return Err(failure(
            "invalid_request",
            "unsupported ABI version; expected 1",
        ));
    }
    let path = absolute_path(&request.catalog_path)?;
    // A poisoned admission mutex remains recoverable: no catalog handle survives
    // a fenced panic, and PhotoCatalog owns its durable transaction boundaries.
    let _guard = REQUEST_LOCK
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if managed::has_managed_owner() {
        return Err(failure(
            "busy",
            "a managed catalog owner is active; use the managed ABI",
        ));
    }
    match request.op {
        Operation::Create => {
            if managed_entry(&path, true)? {
                validate_managed_catalog(&path)?;
                let mut entries = std::fs::read_dir(&path).map_err(catalog_failure)?;
                if entries.next().is_some() {
                    return Err(failure(
                        "already_exists",
                        "create requires a missing or empty catalog directory",
                    ));
                }
            }
            let _catalog = Catalog::open(&path).map_err(catalog_failure)?;
            let root = std::fs::canonicalize(&path).map_err(catalog_failure)?;
            Ok(json!({"catalog_path": root, "source_revision": SOURCE_REVISION}))
        }
        Operation::Open => {
            let root = existing_catalog(&path)?;
            let _catalog = Catalog::open(&root).map_err(catalog_failure)?;
            Ok(json!({"catalog_path": root, "source_revision": SOURCE_REVISION}))
        }
        Operation::List => {
            let after = request.after.unwrap_or(0);
            if after < 0 {
                return Err(failure("invalid_request", "after must be nonnegative"));
            }
            let limit = bounded(request.limit.unwrap_or(100), "limit")?;
            let root = existing_catalog(&path)?;
            let catalog = Catalog::open(&root).map_err(catalog_failure)?;
            let assets = catalog.browse(after, limit).map_err(catalog_failure)?;
            let next_after = assets.last().map_or(after, |asset| asset.sequence);
            let mut output = Vec::with_capacity(assets.len());
            for asset in assets {
                let (preview_path, preview_error) = if asset.state == "ready" {
                    match catalog.preview(&asset.id) {
                        Ok(bytes) => (
                            Some(
                                root.join("previews")
                                    .join(format!("{}.jpg", blake3::hash(&bytes).to_hex())),
                            ),
                            None,
                        ),
                        Err(error) => (None, Some(format!("{error:#}"))),
                    }
                } else {
                    (None, None)
                };
                let mut value = serde_json::to_value(asset).map_err(catalog_failure)?;
                value["preview_path"] = json!(preview_path);
                value["preview_error"] = json!(preview_error);
                output.push(value);
            }
            Ok(json!({"assets": output, "next_after": next_after}))
        }
        Operation::Import => {
            let source = absolute_path(
                request
                    .source_path
                    .as_deref()
                    .ok_or_else(|| failure("invalid_request", "import requires source_path"))?,
            )?;
            let max_files = bounded(request.max_files.unwrap_or(MAX_ITEMS), "max_files")?;
            let root = existing_catalog(&path)?;
            let source =
                std::fs::canonicalize(source).map_err(|e| failure("not_found", e.to_string()))?;
            if !source.is_dir() || root.starts_with(&source) || source.starts_with(&root) {
                return Err(failure(
                    "unsafe_location",
                    "catalog and source must be separate directories; source must be a folder",
                ));
            }
            let mut catalog = Catalog::open_for_import(&root, &source).map_err(catalog_failure)?;
            let report = catalog
                .import(&source, Some(max_files), |_| Ok(()))
                .map_err(catalog_failure)?;
            serde_json::to_value(report).map_err(catalog_failure)
        }
    }
}
fn response(result: Result<Value>) -> Value {
    match result {
        Ok(result) => json!({"version":1,"ok":true,"result":result}),
        Err(error) => {
            json!({"version":1,"ok":false,"error":{"code":error.code,"message":error.message}})
        }
    }
}
fn fenced(operation: impl FnOnce() -> Result<Value>) -> Value {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| response(operation())))
        .unwrap_or_else(|_| response(Err(failure("panic", "catalog operation panicked"))))
}

/// # Safety
/// `request` must be NULL or a valid NUL-terminated buffer alive for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_request(request: *const c_char) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
    let value = fenced(|| {
        if request.is_null() {
            return Err(failure("invalid_request", "request is NULL"));
        }
        // The native caller retains its request allocation until this call ends.
        let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
        execute(bytes)
    });
    // JSON escapes embedded NULs, so constructing the result cannot reject one.
    CString::new(value.to_string())
        .expect("serialized JSON has no literal NUL")
        .into_raw()
    })).unwrap_or_else(|_| CString::new("{\"version\":1,\"ok\":false,\"error\":{\"code\":\"panic\",\"message\":\"catalog response panic fenced\"}}").unwrap().into_raw())
}

/// # Safety
/// `response` must be NULL or a still-owned pointer returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_string_free(response: *mut c_char) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !response.is_null() {
            drop(unsafe { CString::from_raw(response) });
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    fn call(value: Value) -> Value {
        let input = CString::new(value.to_string()).unwrap();
        unsafe {
            let output = lw_catalog_request(input.as_ptr());
            let value = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
            lw_catalog_string_free(output);
            value
        }
    }
    fn request(op: &str, root: &Path) -> Value {
        json!({"version":1,"op":op,"catalog_path":root})
    }
    #[test]
    fn real_catalog_import_restart_pagination_and_original_preservation() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("catalog 日本語");
        let originals = temp.path().join("originals");
        std::fs::create_dir(&originals).unwrap();
        let original = originals.join("photo.png");
        image::RgbImage::from_pixel(32, 24, image::Rgb([52, 71, 88]))
            .save(&original)
            .unwrap();
        let bytes = std::fs::read(&original).unwrap();
        let modified = std::fs::metadata(&original).unwrap().modified().unwrap();
        assert_eq!(call(request("create", &root))["ok"], true);
        assert_eq!(
            call(request("open", &root))["result"]["source_revision"],
            SOURCE_REVISION
        );
        let mut import = request("import", &root);
        import["source_path"] = json!(originals);
        import["max_files"] = json!(1);
        assert_eq!(call(import.clone())["result"]["imported"], 1);
        let listed = call(request("list", &root));
        assert_eq!(listed["ok"], true);
        let asset = &listed["result"]["assets"][0];
        assert_eq!(
            asset["original_path"],
            json!(std::fs::canonicalize(&original).unwrap())
        );
        assert_eq!(asset["state"], "ready");
        assert!(Path::new(asset["preview_path"].as_str().unwrap()).is_file());
        assert_eq!(call(import)["result"]["unchanged"], 1);
        assert_eq!(
            call(request("list", &root))["result"]["assets"][0]["id"],
            asset["id"]
        );
        let mut next = request("list", &root);
        next["after"] = listed["result"]["next_after"].clone();
        assert_eq!(call(next)["result"]["assets"], json!([]));
        assert_eq!(std::fs::read(&original).unwrap(), bytes);
        assert_eq!(
            std::fs::metadata(original).unwrap().modified().unwrap(),
            modified
        );
        assert_eq!(std::fs::read_dir(originals).unwrap().count(), 1);
    }
    #[test]
    fn typed_errors_do_not_initialize_missing_or_unsafe_locations() {
        let temp = tempfile::tempdir().unwrap();
        let missing = temp.path().join("missing");
        assert_eq!(
            call(request("open", &missing))["error"]["code"],
            "not_found"
        );
        assert!(!missing.exists());
        let mut invalid = request("list", &missing);
        invalid["limit"] = json!(1001);
        assert_eq!(call(invalid)["error"]["code"], "invalid_request");
        let root = temp.path().join("catalog");
        assert_eq!(call(request("create", &root))["ok"], true);
        assert_eq!(
            call(request("create", &root))["error"]["code"],
            "already_exists"
        );
        let mut unsafe_import = request("import", &root);
        unsafe_import["source_path"] = json!(temp.path());
        assert_eq!(call(unsafe_import)["error"]["code"], "unsafe_location");
        assert_eq!(fenced(|| panic!("test fence"))["error"]["code"], "panic");
    }
    #[cfg(unix)]
    #[test]
    fn redirected_preview_directory_never_publishes_or_removes_original_files() {
        use std::os::unix::fs::symlink;
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("catalog");
        let originals = temp.path().join("originals");
        std::fs::create_dir(&originals).unwrap();
        let source = originals.join("source.png");
        image::RgbImage::from_pixel(32, 24, image::Rgb([52, 71, 88]))
            .save(&source)
            .unwrap();
        let (_, preview) = photocatalog::media::decode(&source).unwrap();
        // Retained publish_preview would remove this invalid existing hash leaf
        // if the preview directory could redirect into originals.
        let protected = originals.join(format!("{}.jpg", blake3::hash(&preview).to_hex()));
        std::fs::write(&protected, b"protected original bytes, not a preview").unwrap();
        let snapshots: Vec<_> = [&source, &protected]
            .into_iter()
            .map(|path| {
                (
                    path.clone(),
                    std::fs::read(path).unwrap(),
                    std::fs::metadata(path).unwrap().modified().unwrap(),
                )
            })
            .collect();
        assert_eq!(call(request("create", &root))["ok"], true);
        let database = std::fs::read(root.join("catalog.sqlite3")).unwrap();
        std::fs::remove_dir(root.join("previews")).unwrap();
        symlink(&originals, root.join("previews")).unwrap();
        for op in ["open", "list", "import"] {
            let mut input = request(op, &root);
            if op == "import" {
                input["source_path"] = json!(originals);
            }
            assert_eq!(call(input)["error"]["code"], "unsafe_location", "{op}");
        }
        assert_eq!(
            std::fs::read(root.join("catalog.sqlite3")).unwrap(),
            database
        );
        assert_eq!(std::fs::read_dir(&originals).unwrap().count(), 2);
        for (path, bytes, modified) in snapshots {
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert_eq!(
                std::fs::metadata(path).unwrap().modified().unwrap(),
                modified
            );
        }
    }
    #[cfg(unix)]
    #[test]
    fn redirected_and_hardlinked_database_sidefiles_and_locks_are_rejected_before_open() {
        use std::os::unix::fs::symlink;
        for name in [
            "catalog.sqlite3",
            "catalog.sqlite3-wal",
            "catalog.sqlite3-shm",
            "catalog.sqlite3-journal",
            "import.lock",
        ] {
            for hardlink in [false, true] {
                let temp = tempfile::tempdir().unwrap();
                let root = temp.path().join("catalog");
                assert_eq!(call(request("create", &root))["ok"], true);
                let external = temp.path().join("protected-original");
                std::fs::write(&external, b"external original bytes").unwrap();
                let entry = root.join(name);
                if entry.exists() {
                    std::fs::remove_file(&entry).unwrap();
                }
                if hardlink {
                    std::fs::hard_link(&external, &entry).unwrap();
                } else {
                    symlink(&external, &entry).unwrap();
                }
                assert_eq!(
                    call(request("open", &root))["error"]["code"],
                    "unsafe_location",
                    "{name}, hardlink={hardlink}"
                );
                assert_eq!(
                    std::fs::read(&external).unwrap(),
                    b"external original bytes"
                );
                assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 2);
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn create_rejects_redirected_roots_and_parent_traversal_without_initializing_sources() {
        use std::os::unix::fs::symlink;
        let temp = tempfile::tempdir().unwrap();
        let originals = temp.path().join("originals");
        std::fs::create_dir(&originals).unwrap();
        let alias = temp.path().join("catalog-alias");
        symlink(&originals, &alias).unwrap();
        assert_eq!(
            call(request("create", &alias))["error"]["code"],
            "unsafe_location"
        );
        for op in ["open", "list", "import"] {
            let mut value = request(op, &alias);
            if op == "import" {
                value["source_path"] = json!(originals);
            }
            assert_eq!(call(value)["error"]["code"], "unsafe_location");
        }
        let traversal = originals.join("incidental/../../catalog");
        assert_eq!(
            call(request("create", &traversal))["error"]["code"],
            "invalid_request"
        );
        assert_eq!(std::fs::read_dir(originals).unwrap().count(), 0);
        assert!(!temp.path().join("catalog").exists());
    }
    #[test]
    fn malformed_null_version_and_oversized_requests_are_typed() {
        unsafe {
            let output = lw_catalog_request(std::ptr::null());
            let value: Value = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
            lw_catalog_string_free(output);
            lw_catalog_string_free(std::ptr::null_mut());
            assert_eq!(value["error"]["code"], "invalid_request");
        }
        assert_eq!(
            response(execute(b"not json"))["error"]["code"],
            "invalid_request"
        );
        assert_eq!(
            response(execute(&vec![b' '; MAX_REQUEST_BYTES + 1]))["error"]["code"],
            "invalid_request"
        );
        let mut unsupported = request("open", Path::new("/tmp/missing"));
        unsupported["version"] = json!(2);
        assert_eq!(call(unsupported)["error"]["code"], "invalid_request");
    }
}
