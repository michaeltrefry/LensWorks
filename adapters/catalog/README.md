# Catalog adapter

LensWorks owns this C/JSON boundary and the complete retained catalog source
at `../../engines/catalog`. `UPSTREAM_SNAPSHOT.json` records the immutable copy
provenance from upstream revision `f4f8d3f12acc77fe5632720702c52a7cfefb5b58`.
The original PhotoCatalog checkout is preserved locally and is not a dependency.
The owned source retains all catalog services, its `libsqlite3-sys` private
identity fix, `xmp_toolkit` source-preservation fork, fixtures and notices.

Runtime `source_revision` is the owned source SHA256 in
`engines/catalog/SOURCE_PROVENANCE.json`, not the historical upstream revision.
`scripts/catalog_source.py` verifies a canonical sorted path/mode/length/SHA256
ledger for the complete engine tree. Only that current manifest itself and
explicit known build-output directories are excluded. The adapter build script
requires this verified identity and compiles it into the ABI and decode helper.
Engine changes require review and explicit `python3 scripts/catalog_source.py
--write`; builds never repair authority automatically. Adapter source is tracked
separately as LensWorks ABI/build authority. Historical acceptance artifacts
remain evidence for their original source identity and are not transferred.

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
`catalog_failure`, `busy`, and `panic`. Compatibility requests return `busy`
while any managed owner is live, retained after failed startup, or draining.
Catalog failures retain the underlying error
chain as text; individual decode failures appear in ImportReport and the
asset state, as defined by PhotoCatalog.

## Reproduce

Verify the owned source before building:

```sh
python3 scripts/catalog_source.py
python3 scripts/verify-dependencies.py
```

No PhotoCatalog Git checkout or repository access is needed. Prerequisites are
the copied Adobe DNG SDK checksum-pinned fetch script, native pkg-config libraries,
and Rust toolchain; no GPU workload is used by this adapter.

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

## Managed version 2

`lw_catalog_managed_request(bytes, length, &response_buffer)` takes a **valid**
length-delimited UTF-8 JSON allocation of at most 4 MiB. Its C return status is
0 when an owned JSON response buffer exists; other statuses are in the header.
Null/nonzero-length input, oversize input, invalid handles and copy ranges are
controlled failures. As with every C API, arbitrary invalid addresses are a
caller memory-contract violation; Rust cannot validate arbitrary addresses.
Every exported function fences Rust unwinding. The C caller must not unwind
through a completion callback.

All JSON envelopes include `version: 2` and `op`. Successful responses are
`{"version":2,"ok":true,"result":...}`; errors have the same `error.code` and
`error.message` shape as v1. Retained error codes keep their exact snake-case
names. Adapter codes also include `invalid_handle`, `already_taken`, `draining`,
`retained_startup`, `range`, and `panic`. Handles are canonical decimal strings
in JSON. Their nonzero C uint64 value contains slot, type and generation;
released, stale, zero and wrong-kind handles never become borrowed pointers.
Initializing session slots are private until startup installs the ready or
retained owner; guessed handles return `invalid_handle` throughout startup.

`lw_catalog_blake3(bytes, length, out_digest)` computes the retained BLAKE3
digest needed by sealed uploads and proof inputs. It accepts at most 4 MiB,
allows null input only for length zero, and writes exactly 32 raw digest bytes
to caller-owned output on success. Encode those bytes as lowercase hex when
the retained DTO requires a hex checksum. Status 1 rejects null arguments,
5 rejects oversize input, and 3 fences panic; failures leave output untouched.
Neither pointer is retained, and the function allocates no managed handle.

For larger sealed documents and file proofs, use `lw_catalog_blake3_init`,
`lw_catalog_blake3_update`, `lw_catalog_blake3_finalize`, then
`lw_catalog_blake3_release`. Updates are at most 4 MiB each, with no artificial
total document limit. The process admits 16 live, constant-state retained
`blake3::Hasher` owners, charged until the last in-flight call releases ownership.
Init returns an owned generation-stamped handle or status 2 at capacity.
Finalize writes 32 raw digest bytes once; subsequent update/finalize returns
status 6 without changing output. Release remains required after finalize,
and also releases an incomplete stream. Stale, released, and wrong-kind handles
return status 4. Per-hasher calls serialize; callers must determine update order.
Swift prepares larger data/files off main in bounded chunks and releases its
hasher on success, cancellation, or failure; no native pointer survives a call.

The exact operations are:

| Operation | Additional fields | Success result |
| --- | --- | --- |
| `session_create` | `config` | `session`, `phase`, `source_revision` |
| `session_status` | `session` | `phase`, `pending`, `outcome_unknown`, nullable `message`, `pid` |
| `session_shutdown` | `session` | `phase: "closed"` |
| `session_release` | `session` | `released: true` |
| `submit` | `session`, exact retained `request` | `job` |
| `preview_bytes` | `session`, retained `catalog`, `ticket`, `foreground` | `job` |
| `job_status` | `job` | `phase`, `cancel_requested`, `failed` |
| `job_cancel` | `job` | `cancel_requested: true` |
| `job_result` | `job` | `buffer`, decimal `length`, `descriptor` |
| `job_release` | `job` | `released: true` |
| `source_identity` | `session`, `catalog`, `export_job`, decimal `sequence` | `job` |
| `decode_full` | same source fields, `limits`, decimal `worker_bytes`, decimal `max_output_bytes` | `job` |

Config requires `worker_executable: NativePath`, with optional
`decode_worker_executable: NativePath` (defaults to the same executable),
`cache_root: NativePath`, `original_roots: [NativePath]`, and exact retained
`limits`, `preview_policy`, `preview_limits` structures. Omitted retained
structures use their pinned defaults. The cache root is caller-declared
app-owned storage and must be separate from known original roots. Retained
admission enforces original/catalog/cache separation and filesystem authority.
The owned preflight also rejects redirected roots, database/lock paths, cache
directories and the known hash-prefix directories before catalog admission;
it repeats catalog checks for requests bound to an admitted catalog token.
Do not mutate managed trees concurrently from another process: static admission
does not claim a hostile filesystem rename-race security boundary.

`payload_bytes` optionally configures the process-wide pending/result pool:
default 512 MiB, finite range 8 MiB..8 GiB. A change requires every previous
owner and output buffer released. `worker_bytes` optionally sets the session's
maximum isolated float-worker watchdog allowance: default 4 GiB, finite
1..8 GiB. These are explicit admission defaults, **not measured product or
camera-support limits**. Larger approved budgets fit the same ABI. Four actual
live/retained/draining session owners, 128 actual jobs/receiver owners, 256
buffer handles and 1024 registry slots bound ownership. Receiver admission
lasts through callbacks even when its completed job handle has been released.
Only one isolated float worker runs at a time. Native service pools retain
PhotoCatalog's distinct `ByteBudget` allocations and configured limits;
per-session reservation totals and sampled decoder RSS do not establish a
hard total application RSS ceiling.

Response slot and byte admission happen **before** any mutation. JSON jobs
reserve 4 MiB, preview jobs reserve 32 MiB, and float jobs reserve their declared
output ceiling before submission. The same payload lease follows a completed
but unread result into an owned buffer and is released with its actual owner.
Published `PreviewBytes` keeps the retained transport owner/budget alive.
Buffer copying exposes no Rust-owned address; copy an explicit range with
`lw_catalog_buffer_copy` and release exactly once with `buffer_release`.
Output buffers survive session shutdown/release.

Session phases are `starting`, `ready`, `draining`, `failed`, `closed`, or
`retained_startup`. Failed startup still returns a session handle owning the
failure; retry checked shutdown and preserve its `outcome_unknown` status.
Never replace uncertain owners with a fresh catalog. Shutdown closes callback
admission, cancels jobs and invokes retained checked shutdown. `draining`
requires a later retry until receiver/child owners finish; release requires
`closed`. No simultaneous v1 compatibility catalog is admitted.
Checked shutdown executes on one bounded background receiver per session;
the C request returns promptly with `draining` while that receiver is pending.
It never holds the session status/admission mutex across a retained wait.
Even if a retained worker stops responding, its handle and owner allowance stay
retained. Poll to actual `closed`; a caller deadline is not proof of teardown.

Job phases are `pending`, `complete`, and `taken`. Results are taken once;
pending returns `busy`, repeated take returns `already_taken`. A failed job
returns its typed error when taken. Release of a pending job returns `busy`;
cancel and wait for completion first. Cancel is independent of receiver waits.
It requests retained cancellation and reports the real retained outcome,
which may already have committed. It never promises transaction rollback.

The JSON job payload is the exact public `application::Reply`, preserving all
`Request` and nested request/result variants through `DesktopBridge::submit`.
No family is projected away: lifecycle, import, organization/search, metadata
provenance/XMP write/recovery, relink, cache settings/previews, Lightroom
workbench/capture/migration, variants/recipes/history/culling, edit-copy,
export, and backup/restore remain reachable. `NativePath` preserves exact
`UnixBytes` or `WindowsWide` units; foreign-platform paths require explicit
mapping. Retained I64/U64/U128 authority is canonical **decimal text**, never
a floating-point JSON number. Search cursors and tokens remain session-bound.
Each public operation retains its optimistic revisions, sealed approvals,
publication, recovery, and cancellation semantics. A returned operation/job
may need polling before the next mutation; for example export `Append` must
reach its terminal durable boundary before `Seal`.

Optional completion subscriptions execute on receiver threads and can run
concurrently. They carry only session/job IDs, never borrowed result bytes.
`unsubscribe_and_drain` stops admission before waiting for in-flight calls.
Timeout or reentrant self-drain returns busy and keeps the subscription/context
alive; retry successfully before freeing the Swift context. A subscription
remains independently drainable after session release. Swift must schedule
presentation onto its main actor and keep blocking calls/receiver waits on
independent background executors so cancellation cannot queue behind a wait.

## Source authority and full float decode

These operations require an **already prepared durable retained export plan**,
identified by the catalog token, export job and sequence. They do not silently
create an export job or publish an output. The caller uses the retained export
inputs/append/seal lifecycle and retains its normal recovery/restore controls.
`source_identity` returns the exact retained `application::exports::Plan` JSON,
including source fingerprint/generation, metadata and recipe revisions,
native original path and observed physical/content `original_revision`.
No second SQLite/catalog owner is opened.

`decode_full.limits` has positive finite decimal `max_encoded_bytes`,
`max_intermediate_pixels`, and `max_allocation_bytes`. Zero and u64::MAX are
rejected; allocation/output ceilings must fit the explicit worker allowance.
The isolated worker calls pinned `media::decode_full_limited`, verifies source
fingerprint and device/inode/size/mtime/content revision before and after,
and the parent revalidates the retained plan after the child is drained.
Cancellation/deadline/failure kills and reaps the child before completing the
job and publishes no float result. The worker has a 120-second deadline and
a sampled RSS watchdog (50 ms); native per-surface ceilings and watchdog
sampling do not promise a hard native scratch/RSS ceiling.

The returned float descriptor includes `kind: "float"`, `protocol: 2`, exact
compiled `source_revision`, MIME `application/x-lensworks-rgba-f32le`, numeric
`width`/`height`, decimal `row_stride`/`byte_length`, `channels: 4`,
`sample: "float32_le"`, `color_space: "linear_srgb"`, `alpha: "straight"`,
`orientation: "applied"`, retained metadata/provenance, exact `source_identity`,
`original`, `original_revision`, and `plan_authority`. The parent verifies
all authority, frame extent and format fields before allocating output,
then validates finite float samples and alpha in [0,1]. RGB can be negative
or above one. The payload is contiguous RGBA f32 little-endian with stride
width*16; it is the full original decode, not an encoded preview or an applied
editor recipe. The editor retains the recipe/layer evaluation separately.

`lensworks-decode-worker` compiles the owned `src/main.rs` directly using
`include!`, preserving every retained descendant-worker dispatch. Its owned
`--lensworks-full-decode` mode precedes that dispatch. Production may package
separate PhotoCatalog and LensWorks decode helpers; configure both absolute
paths, sign them and retain the native library closure. Never merge their
framed stdout/stderr into app logs. The float mode uses a versioned bounded
file frame with private temporary files and no media-directory staging.

Run CPU tests with `cargo test --release --locked --manifest-path
adapters/catalog/Cargo.toml --target-dir .build/rust-catalog`.
Registry/compatibility tests serialize on an in-code process-wide fixture gate
(the managed registry and counters are global by design), so the suite runs
with the default parallel harness; the dedicated blocked-callback fixture itself exercises concurrent admission,
cancellation and teardown. Planned inventory profiles and wire round trips
are reported separately from actual retained-service lifecycle acceptance.

The tests separately validate all 357 request specimens and 621 standalone
enum specimens against the pinned public Rust serde types. Actual adapter
fixtures exercise organization, metadata input/review/commit and sidecar
publication, edit copy, preview byte ownership, backup restore, source authority,
full float decode, cancellation, admission saturation, callback drain, and
checked shutdown during an injected test assertion unwind.
The float fixture freezes exposure +1, verifies that full-source decode still
returns the original HDR samples, then executes retained recovery/run/publication
with explicit finite staging/decode/render/encode caps. The published Float32
TIFF has doubled RGB and unchanged alpha, exact frozen authority and a receipt;
original bytes/mtime remain unchanged. A real stopped-worker fixture uses only
its own child PID, verifies finite `draining` polls, resumes and checks reaping.

The pin has a known combined-state fault: assigning a hierarchical keyword,
then preparing/committing a rating edit with `base_model: null`, can leave a
keyword choice pointing at an old model with no current candidate. Fields
reports a conflict; Candidates has no legal replacement; SidecarPlan returns
`resolve metadata conflicts before export`. The adapter forwards this failure
and preserves source bytes. The regression fixture
`managed_retained_organization_xmp_conflict_rejects_sidecar_without_source_effects`
records the exact request sequence. Repair requires explicit full-base authority
and candidate reconciliation or a reviewed retained-source correction; no model
or database authority is synthesized here. Successful sidecar fixtures pass a
physically canonical destination because the retained worker checks exact path
authority against its canonical plan.
