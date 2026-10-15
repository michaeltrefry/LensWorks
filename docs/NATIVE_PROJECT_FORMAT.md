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

## Version 14: retained plugin steps and Invert on live RAW sources

Version 13 carries live RAW sources and float working samples. Version 14 adds two things a live RAW source's
ordered operations may hold, and nothing else:

- a **filter-plugin step** — the source record's optional `plugins` array and the `plugin` operation: each step's
  id, the plugin's id and name, the SHA-256 of the module that ran, the filter interface version, the parameter
  values, the capture frame, and an optional selection plane (`docs/PLUGINS.md`, "On a live RAW layer");
- a retained adjustment of kind **Invert** (Image › Invert on a live RAW layer), beside the Hue/Saturation and
  Levels adjustments version 13 retains.

The writer follows the existing rule — the oldest version that can express the package: 14 only when some source
holds one of these (`ProjectStore.usesVersion14`), 13 for other live RAW or float content, 12 otherwise. The
`plugins` key is written only when there is a step, so a version-13 package holds exactly the keys it did. The
reader accepts versions 1–14 and refuses a package below 14 that carries either. A build that knows only version
13 refuses a version-14 package by its version, rather than opening it and losing the step.

`native/CompositorTests/Fixtures/retained-plugin-step.v14.json` is the step record as stored; a test holds the
reader and writer to it.

Fill, Clear and Transform Selection have no retained form on a live RAW source. On a live RAW layer each is refused
with its reason (the layer's mask can still be filled or cleared) rather than turning the layer into plain pixels
and losing its development.
