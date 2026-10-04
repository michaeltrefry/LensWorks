# Native working-version format

LensWorks adapts the frozen Compositor package reader/writer. Readable baseline
formats 1–11 remain supported. New LensWorks saves use format version 12; the
read-only Compositor snapshot and its format documentation remain unchanged.

A version-12 catalog working version includes `workingVersionID` in the project
manifest and a matching `LensWorks.json` within the same `.comp` package. The
record preserves its schema version, stable working-version UUID, catalog photo
UUID, canonical catalog path, original source path, document path and version
name. The manifest marker makes missing or mismatched identity a load error,
rather than silently treating an incomplete catalog version as standalone.
Standalone projects may omit the catalog identity record. Saving a catalog working
version under a different project path creates a new working-version UUID while
retaining photo/source links; normal Save preserves the UUID. Catalog-managed
paths and destinations that would replace originals or the catalog are rejected.

The writer validates source protection, serializes document assets and the
identity record into the same staged package, and publishes them together through
the retained atomic project writer. No independent external sidecar is required
for new saves. A failed publication must leave the previous project readable and
must not report the captured revision as saved. Source media and the retained
PhotoCatalog recipe schema remain unchanged.

This first format extension establishes the raster working-version relationship.
The complete live RAW document contract, independent named versions, persistent
undo/checkpoints, compositions, recovery and portable export retain their explicit
owning stories in epic 24655. Version 12 does not establish those acceptances.
