# Catalog adapter

LensWorks owns this version-1 C/JSON boundary. The catalog, import, metadata,
schema migration, UUID identity, preview validation, and original-file safety
remain in PhotoCatalog at `f4f8d3f12acc77fe5632720702c52a7cfefb5b58`.
The dependency is the pinned `../../vendor/PhotoCatalog` checkout. The root
Cargo patch preserves its `libsqlite3-sys` private database-identity fix;
PhotoCatalog also retains its `xmp_toolkit` source-preservation fork.

`lw_catalog_request` accepts a NUL-terminated UTF-8 JSON request and returns
an owned NUL-terminated JSON string. Release it exactly once using
`lw_catalog_string_free`; never use the Swift/C allocator. NULL input returns
an error; NULL free is allowed. Other pointers must satisfy the C header's
valid-buffer ownership preconditions. The request envelope is capped at
1 MiB after reading the valid terminated input.

All calls block. Swift must keep them off the main actor. A process-wide mutex
serializes adapter operations; each request opens and drops its own catalog,
and PhotoCatalog retains its own transaction/import locking. No persistent
handles or callbacks cross the ABI. Rust panics in request processing become
typed `panic` errors with the default unwind profile.

## Contract

Every request includes `version: 1`, `op`, and an absolute UTF-8 `catalog_path`.
Unknown fields and operations are rejected. Paths are capped at 32768 bytes
and must not contain parent traversal (`..`).

```json
{"version":1,"op":"create","catalog_path":"/absolute/My Catalog"}
{"version":1,"op":"open","catalog_path":"/absolute/My Catalog"}
{"version":1,"op":"list","catalog_path":"/absolute/My Catalog","after":0,"limit":100}
{"version":1,"op":"import","catalog_path":"/absolute/My Catalog","source_path":"/absolute/Originals","max_files":1000}
```

Create requires a missing or empty directory. Open, list, and import require
an existing `catalog.sqlite3` and never implicitly create a missing catalog.
Before opening or migrating a catalog, admission rejects symlinked selected
roots and preview directories, and symlinked, nonregular, or hardlinked
database, WAL, SHM, rollback journal, and import-lock files. This prevents
managed writes from following redirects into original-media locations.
Import requires an existing source directory separate from the catalog;
ancestor/descendant overlaps are rejected before opening for import. The
PhotoCatalog importer writes catalog/previews only and reads originals.
LensWorks native documents must remain in their separate document locations.

`after` defaults to 0 and must be nonnegative. `limit` defaults to 100 and must
be 1..1000. `max_files` defaults to 1000 and must be 1..1000; this bounds the
number of supported source files processed, not the number of directory
entries walked. PhotoCatalog's retained importer defines supported formats.
This milestone uses its synchronous compatibility import and provisional
JPEG previews. Managed scheduling and the wider catalog surface belong to
the subsequent retained-service contract story.

Success is `{"version":1,"ok":true,"result":...}`. Create/open return
`catalog_path` (canonical) and `source_revision`. Import returns the retained
`ImportReport` including `imported`, `unchanged`, `failed`, `skipped`,
`metadata_updated`, `metadata_warnings`, `awaiting_resources`, and `stopped`.
List returns `assets` and `next_after` (last sequence, or input `after` when
empty). Each asset has `sequence`, stable UUID `id`, `original_path`, `state`,
`metadata`, `error`, nullable `preview_path`, and nullable `preview_error`.
Preview paths identify existing JPEGs validated through `Catalog::preview`;
they are browsing assets and must not be used as editable full-resolution
inputs. Missing/corrupt previews keep the asset visible with `preview_error`.

Errors are `{"version":1,"ok":false,"error":{"code":"...","message":"..."}}`.
Codes are `invalid_request`, `not_found`, `already_exists`, `unsafe_location`,
`catalog_failure`, and `panic`. Catalog failures retain the underlying error
chain as text; individual decode failures appear in ImportReport and the
asset state, as defined by PhotoCatalog.

## Reproduce

Verify the source revision and clean tracked files before building:

```sh
git -C vendor/PhotoCatalog rev-parse HEAD
git -C vendor/PhotoCatalog diff --exit-code
git -C vendor/PhotoCatalog diff --cached --exit-code
```

The expected head is the revision above. The coordinator's dependency pin
manifest records the same revision and licenses. Build prerequisites are
PhotoCatalog's existing Adobe DNG SDK checksum-pinned fetch, native pkg-config
libraries, and Rust toolchain; no GPU workload is used by this adapter.

```sh
export PHOTOCATALOG_DNG_SDK="$PWD/.build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1"
export MACOSX_DEPLOYMENT_TARGET=26.2 CARGO_BUILD_JOBS=4
cargo test --locked --manifest-path adapters/catalog/Cargo.toml --target-dir .build/rust-catalog
cargo build --release --locked --manifest-path adapters/catalog/Cargo.toml --target-dir .build/rust-catalog
```

The native build links `.build/rust-catalog/release/liblensworks_catalog.a`
and PhotoCatalog's required system/native libraries. `Cargo.lock` records
the resolved Rust dependency graph; the repository dependency inventory
also covers the SDK and dynamically linked native libraries.

The tests exercise real catalog creation/open/import/reopen, stable UUIDs,
pagination, existing verified preview paths, NULL/malformed/oversized/version
errors, panic fencing, missing catalog admission, overlapping locations,
and unchanged original bytes, modification time, and source directory contents.
They also reproduce a redirected preview directory with an existing invalid
preview-named original file and verify rejection preserves both files and
directory contents. Database sidefile/lock symlinks and hardlinks, redirected
create roots, and parent traversal are rejected before initialization.
