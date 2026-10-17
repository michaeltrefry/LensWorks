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

`document.json` is currently schema 2. The reader upgrades schema 1, which did
not contain `maxUndoSteps`; older content may use scalar RAW settings, simple
layer entries and string source references. Schema-2 content can retain the
complete native `ProjectLayerRecord` graph, including
parent/group topology, transforms, opacity/blend modes, masks, adjustment,
shape, effect and text state, plus its `LWLiveSourceNode` live-RAW graph. It
also records structured catalog source references. The retained legacy fields
remain readable so an upgrade does not discard historic commands.

Each catalog photo has independently-valued named versions. Duplicating one
copies its current content and checkpoints but starts separate undo/redo
history, so edits cannot mutate a sibling version. Every history step and
checkpoint stores the complete version content, and document commands are
Codable. Schema migration fixtures include commands in undo and redo history
and verify their re-encoded roundtrip.

The configurable `maxUndoSteps` (default 100; minimum 1) bounds retained undo
steps per version. The oldest unprotected undo steps are pruned first after an
edit, checkpoint restore, history-limit change, or redo. A checkpoint pins the
undo step that existed when it was named. If checkpoint protection prevents the
limit from being met, LensWorks preserves the data and returns a warning rather
than deleting recoverability.

Asset reachability includes current version content, undo/redo snapshots and
checkpoints. Layer, mask and live-source asset references remain retained until
no current version, composition/history step, or named checkpoint can reach
them; `collectUnreachableAssets` removes only the remainder.

Saving a catalog working version under a different project path creates a new
working-version UUID while retaining photo/source links; normal Save preserves
the UUID. Catalog-managed paths and destinations that would replace originals
or the catalog are rejected. The writer validates source protection,
serializes document assets and identity records into the same staged package,
and publishes them together through the retained atomic project writer. A
failed publication leaves the previous project readable and must not report
the captured revision as saved. Source media and the retained PhotoCatalog
recipe schema remain unchanged.
