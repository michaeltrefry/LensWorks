# Native working-version format

LensWorks adapts the frozen Compositor package reader/writer. Readable baseline
formats 1–11 remain supported. New LensWorks saves use format version 12, or
version 13 when they contain live RAW sources or float working samples. The
read-only Compositor snapshot and its format documentation remain unchanged.

A catalog working version includes `workingVersionID` in the project manifest
and a matching `LensWorks.json` within the same `.comp` package. The record
preserves its schema version, stable working-version UUID, catalog photo UUID,
canonical catalog path, original source path, document path and version name.
The manifest marker makes missing or mismatched identity a load error, rather
than silently treating an incomplete catalog version as standalone. Standalone
projects may omit the catalog identity record.

## LensWorks version document

A package may contain `LensWorksDocument/document.json` and
`LensWorksDocument/assets/<asset-id>`. They are written and published by the
same atomic `ProjectStore` transaction as `manifest.json`, images, sources and
`LensWorks.json`; they are never a sidecar. A load preserves the document and
its assets in the project snapshot, and a catalog document's `photoID` must
match the package working version's `photoID`.

`document.json` is currently schema 3. The reader upgrades schemas 1 and 2;
schema 1 did not contain `maxUndoSteps`, and older content may use scalar RAW
settings, simple layer entries and string source references. Schema 3 adds
complete composition state, exact float/source archives and persisted version
selection; older readers reject this schema rather than misreading tiled assets.
Version content can retain the complete native `ProjectLayerRecord` graph, including
parent/group topology, transforms, opacity/blend modes, masks, adjustment,
shape, effect and text state, plus its `LWLiveSourceNode` live-RAW graph. It
also records structured catalog source references. The retained legacy fields
remain readable so an upgrade does not discard historic commands.

Each catalog photo has independently-valued named versions. Duplicating one
copies its current content and checkpoints but starts separate undo/redo
history, so edits cannot mutate a sibling version. Every history step and
checkpoint stores the complete version content, and document commands are
Codable. Ordinary editor steps additionally retain an optional `oppositeContent`
endpoint and before/after revision UUIDs; the version retains its current canvas
revision UUID. These backward-compatible schema-3 fields preserve exact Redo and
saved/modified identity when pruning leaves gaps—even when distinct revisions
have identical pixels. Older steps without these fields retain their legacy
semantics. Asset retention and source-destination protection visit both endpoints.
Schema migration fixtures include commands in undo and redo history and verify
their re-encoded roundtrip.

The configurable `maxUndoSteps` (default 100; minimum 1) bounds retained undo
steps per version. The oldest unprotected undo steps are pruned first after an
edit, checkpoint restore, history-limit change, or redo. A checkpoint pins the
undo step that existed when it was named. If checkpoint protection prevents the
limit from being met, LensWorks preserves the data and returns a warning rather
than deleting recoverability.

Asset reachability includes current version content, undo/redo snapshots and
checkpoints. Layer, mask and live-source asset references remain retained until
no current version, composition/history step, or named checkpoint can reach
them. Every real package save writes only the reachable inventory, so the atomic
replacement prunes unreachable assets without ever deleting data from the old
package before publication. Float samples use exact `.f32` or tiled `.plane`
archives; live-source metadata, payloads and source planes are retained
transitively, not reduced to an integer preview. A missing reachable asset is
an error, not a partially restorable save.

Loading visits only reachable asset IDs, not every member of the asset directory.
It admits the complete inventory before full asset reads or plane copies: at most
10,000 reachable IDs and 512 MiB of aggregate encoded non-plane assets. PNG/F32
headers account for decoded backings before allocation; source JSON uses the
existing token-aware metadata allowance. Encoded assets, the selected version's
unique hydrated backings, plane tile metadata, sequential staging and the
coexisting current canvas must fit `DocumentLimits.documentPixelBudget * 4`
bytes. Disk-backed plane samples have a separate cumulative logical-copy bound
of `documentPixelBudget * 16` bytes; they are not charged as resident raster RAM.
These are admission allowances, not measured RSS; the source/tile working-set
owners still enforce their own allocation bounds. Save applies corresponding
admission before publication. Previously unbounded oversized histories are
refused atomically rather than allocating until exhaustion or replacing an
existing readable package.

Newly captured graphs also keep canvas dimensions, resolution, guides, active
layer and working color/sample state. Older schema-2 graphs lacking this
optional composition record keep the legacy canvas fallback. Selecting another
version refuses unsaved canvas edits with an actionable Save message, leaving
both edits and Undo intact. Save serializes the central editor transaction log
into the selected version: each completed ordinary edit retains its own stable
step identity, label, user/agent origin and before/after composition. The pending
Redo stack is retained too; repeated saves neither coalesce edits nor add steps.
Opening a package or selecting a version reconstructs its ordinary Edit-menu
Undo/Redo timeline, independently of sibling versions. Legacy scalar-only
commands remain available through the version history controls. Naming a
checkpoint first captures the visible selected canvas and its completed edits;
an unfinished gesture is refused without changing the canvas, version or assets.
The selected version is saved with the document so reopening the canvas and its
history controls agree.

Saving a catalog working version under a different project path creates a new
working-version UUID while retaining photo/source links; normal Save preserves
the UUID. Catalog-managed paths and destinations that would replace originals
or the catalog are rejected. The writer validates source protection,
serializes document assets and identity records into the same staged package,
and publishes them together through the retained atomic project writer. A
failed publication leaves the previous project readable and must not report
the captured revision as saved. Source media and the retained PhotoCatalog
recipe schema remain unchanged.
