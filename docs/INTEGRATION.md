# LensWorks integration proposal

Status: engineering design supporting the confirmed requirements and recorded
Shortcut plan, October 3, 2026. The native implementation and combined-product
acceptance remain unproven; source-derived routes are candidates to validate.

## Ownership

| Component | Owner and integration |
| --- | --- |
| Window, catalog views, panels, tools, document interaction | Swift/SwiftUI/AppKit in LensWorks, extending Compositor's design and editing foundation |
| Interactive image rendering | LensWorks' adaptation of Compositor's Core Image/Metal pipeline; retain Apple's accelerated frameworks |
| Catalog, metadata, file identity, migration, recovery services | Pinned PhotoCatalog Rust library, wrapped by a LensWorks-owned Rust adapter |
| Model execution | Pinned inference macOS runtime, wrapped by a LensWorks-owned Rust adapter |
| Layered documents, live RAW references, persistent commands, AI provenance | LensWorks-owned document schema and assets, coordinated with the catalog |
| Model discovery, reuse, verified acquisition, job scheduling | LensWorks integration; reuse compatible SceneWorks files and contracts |

Rust and Swift interoperate through a small versioned C-compatible boundary.
Opaque handles own Rust objects; explicit buffers, typed statuses, and job IDs
cross the boundary. Callbacks and cancellation have documented lifetimes. Rust
panics must not unwind into Swift. Blocking model execution and catalog work run
away from the UI thread. This interface is new work, not an existing Swift SDK.

LensWorks owns both adapters. PhotoCatalog remains unchanged. Changes genuinely
needed inside inference must be separately tracked there, followed by one tested
LensWorks dependency pin. Do not invent support in a Swift wrapper that the
selected provider cannot perform.

## One document, one editing experience

A photo version references its untouched original and retains its own RAW recipe,
editable layers, sampled retouch commands, history, and checkpoints. The RAW source
acts as a live input to the document render graph. Changing RAW exposure updates
the developed image and invalidates dependent clone/heal operations and composites.
It does not rewrite original bytes or silently regenerate AI pixels.

Source coordinates, document coordinates, masks, crop, and transforms require an
explicit mapping. Retouch replay must use a deterministic upstream input and must
not sample its own output. Placed sources in compositions retain a stable revision;
Update from Source is an undoable replacement of that revision. Old revisions and
required assets remain available while referenced by compositions or checkpoints.

Catalog photos, named versions, compositions, and standalone documents are related
entities, not interchangeable records. A generated draft has no catalog membership
until its first Save succeeds. Confirmed: Add to Catalog asks for a virtual folder
and registers the existing document in place, preserving identity, history and
source relationships without creating an independent duplicate.

The existing physical storage model applies: catalog and rebuildable previews are
separate from filesystem media folders. Edited/generated image files follow that
same workflow. A virtual folder selected in the Save dialog provides organization;
it does not create a second app-private media library.

An explicit portable native export bundles required source images, layers and
masks, with a choice to include persistent history. Its copied inputs must support
editing on another Mac without the source drive, and export must report any
unavailable required source rather than claim an incomplete copy is portable.

## Rendering and RAW development

Compositor currently develops RAW into RGBA8 sRGB and renders layer textures as
RGBA8. PhotoCatalog already has an f32 linear-sRGB full-resolution decode path.
Neither is a finished live RAW/layer editor with the requested persistence.

Proposed direction: use one authoritative RAW-development contract, starting with
PhotoCatalog's existing full-resolution decode and recipe semantics where suitable.
Swift owns interactive rendering of those inputs through Metal/Core Image. Evaluate
Core Image RAW development only against the same precision, camera support, recipe,
and preview/export parity requirements; do not let UI preview and export use
unrelated development engines.

Retain floating-point working data and explicit color/alpha contracts. Choose
texture and tile precision after numerical and GPU-memory validation, rather than
assuming a texture-format change upgrades all tools. Painting, effects, masks,
adjustments, blend modes, pixel kernels, persistence, and export must all be adapted.
The confirmed workflow is color-managed RGB photography: preserve embedded-profile
provenance, wide-gamut display, selectable RGB export profiles and printer-profile
soft-proofing. Native CMYK/spot-color prepress editing is outside the selected scope.
Display conversion occurs at the display boundary. AI input/output conversion is
explicit because model pixels are not inherently scene-linear RAW data.

Full-resolution exports evaluate the complete document from original/source assets;
browse previews cannot substitute for the export source. Reuse PhotoCatalog's
guarded file-publication behavior where its public APIs allow it, while supplying
the layered render result rather than exporting only the underlying RAW recipe.

## AI capability mapping

These are source-backed candidate routes, not claims of end-to-end LensWorks
support. Every route needs real-input acceptance through the native application.

| Required task | Existing foundation | LensWorks work / uncertainty |
| --- | --- | --- |
| Standalone generation | Registered MLX image generators, including Flux and Qwen families | Task/model filtering, draft recovery, provenance, first Save and catalog insertion |
| Prompt editing / replacement | Image-edit providers in the inference catalog | Verify each provider's reference and spatial conditioning; composite results into new layers |
| Generative fill / expand / object removal | Editing providers plus Compositor selections, content-aware tools and masks | A generic image editor is not proof of masked generation. Validate a real mask-aware route or implement the missing engine capability; preserve pixels outside the requested region |
| Subject masks / background removal | Compositor's Apple Vision route; inference SAM2/SAM3 bespoke utilities | Contextual UI, editable masks, refinement and source-coordinate mapping; dedicated utility adapters where used |
| Upscaling | SeedVR2 registry explicitly supports still-image Reference conditioning | Resolution changes, placement and alignment, tiled/memory-bounded execution, new-layer insertion |
| Restoration / denoising | Candidate restoration providers and existing image-processing operations | Verify separate restoration and photographic denoising behavior; upscaling alone does not establish either requirement |
| Captions / keywords | Captioner contracts and JoyCaption provider | Reviewable suggestions, metadata application/undo and batch policy; keywords need a validated extraction route |
| Semantic search | Paired image/text embedding contracts and CLIP provider | Compatible embedding spaces, index construction/versioning, search UI, stale-source invalidation and rebuild |

Model menus come from validated capabilities and available assets. Advanced controls
only appear when the provider honors them. Reusing SceneWorks downloads requires
matching component layout, revision, precision/quantization, integrity and license
terms. A recorded hash of current bytes alone does not prove a match to the expected
manifest. Verify selected assets when admitted/loaded, cache valid identity evidence,
and invalidate it when files change; avoid hashing every unused model at app launch.

AI jobs snapshot document/source revision, task, model assets, settings and input
geometry. If the user edits while a job runs, insert the result with its captured
alignment/provenance and a clear indication of the input revision; never apply stale
masks to a different geometry silently. Finished editing results become undoable
new layers. Metadata remains reviewable suggestions.

Batch jobs persist per-item state, completed results, failures and cancellation.
Resuming does not repeat completed outputs or overwrite an intervening edit.
Confirmed: batch image enhancements create a new named version per photo,
preserving its current working version and inserting result pixels as layers in
the new version. Single-document AI edits still add layers immediately; metadata
batches retain reviewable suggestions.

Metal rendering and MLX inference share GPU and unified memory. Scheduling prioritizes
interactive rendering, bounds model residency and queued work, and supports cooperative
cancellation. Background AI automatically pauses at safe execution boundaries during
active painting/adjustment, shows the paused state and resumes once interaction
settles. Boundary waiting time must be measured; no instant kernel preemption is
assumed. AI model admission uses measured fit in available unified memory. Running
SceneWorks simultaneously is a separate resource-coordination
case to validate; a shared model directory does not share resident GPU allocations.
No zero-copy Swift texture-to-MLX transfer is assumed without measuring a supported
buffer path.

## Persistence, migration, recovery and backup

Compositor's package format must be extended for live RAW recipes, source revisions,
sampled operations, precision, AI provenance, and persistent undo. Preserve readable
legacy Compositor documents with a conversion report for unsupported data. Existing
PhotoCatalog recipe records reject arbitrary unknown fields; layer documents cannot
simply be inserted into that recipe JSON.

Use LensWorks-owned document records/assets with explicit schema versions and a
recovery journal coordinating catalog membership and asset publication. Define the
commit point for autosave, first Save and Add to Catalog, including crash recovery
between file publication and database update. No success notification before durable
publication. One authoritative writer prevents conflicting standalone/catalog edits.

Configurable undo limits automatically prune the oldest unprotected steps; named
checkpoints and current version/composition/source references retain required assets.
Warn when protected data prevents meeting the limit. Unsaved generated/standalone
recovery drafts have no automatic expiry, remain until explicit Save or Discard and
are accessible in Recoverable Drafts. Preview caches remain rebuildable.
Catalog backup must include LensWorks' non-rebuildable document data/history/assets
or an explicit manifest of separately backed-up media. PhotoCatalog's existing SQL
snapshot alone does not back up the new editor. Restore validation must resolve
documents and their references, not just reopen the database.

Import PhotoCatalog/Lightroom into a new catalog with dry-run/reporting and original
path/metadata preservation. Preserve offline browsing and stable identity/relinking
contracts. Confirmed: allow document editing where required full-resolution inputs
are available; visibly disable operations and exports requiring missing inputs.
Retained previews do not substitute for those inputs. Offline preview browsing
and metadata organization remain available.

## Capability baseline and acceptance

The proposed baseline preserves the complete Compositor editing surface and the
existing PhotoCatalog catalog/migration surface. The implementation plan must map
every capability to a slice; this inventory is not permission to defer difficult tools.

- Catalog: import, external source folders, offline browsing, atomic relinking,
  hierarchical keywords, ratings/flags/labels, collections and filters, metadata/XMP
  preservation, Lightroom migration, previews, export queues, backup and restore.
- Editing: layers/groups, masks/clipping, opacity/blending, adjustment layers and
  effects, merge/clipboard/drag operations, transforms/distortion/snapping/guides,
  selections/refinement, content-aware fill/extend, brush/eraser/smoothing,
  clone/heal/blur, gradients/shapes/text, RAW controls, finishing filters,
  document tabs, rulers/grid/crop/canvas sizing/trim, zoom/pixel display and shortcuts.
- Formats: existing Compositor imports, including its bounded PSD/PSB support;
  native layered documents, original RAW formats and PhotoCatalog's guarded image
  export formats. Confirmed additional scope: layered PSD/PSB import and export,
  preserving supported editable constructs and explicitly reporting Photoshop
  incompatibilities before lossy conversion. This is new implementation work,
  not an existing export capability established by Compositor's import support.
- New requirements: integrated editor/catalog navigation, independent photo
  versions, source-linked compositions, persistent history/checkpoints, recovery,
  standalone documents, every listed AI task, resumable batches and model reuse.
- Terminal acceptance: real RAW/photo and layered-document fixtures, color/precision
  parity, restart/crash/restore, missing-source/relink, migration preservation,
  all tools and exports, all AI routes with real weights, keyboard/accessibility,
  sustained interactive editing during background work, and signed distributable app.

Confirmed targets: 16 GB minimum Apple-silicon Mac for catalog/photo/layer editing,
first-class pressure/tilt where supported with configurable brush/tablet controls,
RGB soft-proofing, and signed/notarized direct download with user-controlled updates.
These require actual installed-product evidence, not source benchmarks.

Initial p95 goals are 1 s warm photo switch, 150 ms RAW preview feedback and 50 ms
brush input-to-display on minimum/reference Macs with 24–50 MP photos and a
representative 20-layer fixture. Larger documents have separate stress tests.
[S37 / sc-24694](https://app.shortcut.com/trefry/story/24694) measures the native
prototype and obtains Michael's approval of final latency/memory limits after
reviewing the evidence. S33 then validates resource behavior against those limits;
S36 owns the sole whole-product acceptance. Goals are not measured support claims.

## Inspected sources

- Compositor: `11d8d7a50992b24fd9a760a1c13b1c01b70aaf30`, MIT (retain notices).
  [RAW importer](https://github.com/robbietilton/Compositor/blob/11d8d7a50992b24fd9a760a1c13b1c01b70aaf30/Compositor/IO/RawImporter.swift),
  [GPU canvas](https://github.com/robbietilton/Compositor/blob/11d8d7a50992b24fd9a760a1c13b1c01b70aaf30/Compositor/Rendering/GPUCanvas.swift),
  README and package/project-format sources in the inspected clone.
- PhotoCatalog: `f4f8d3f12acc77fe5632720702c52a7cfefb5b58` in the current chat checkout:
  `src/lib.rs`, `src/media/full.rs`, `src/edit/recipe.rs`,
  `docs/EDITING_AND_EXPORT.md`, `docs/CATALOG_BACKUP.md`, root requirements.
- Inference: inspected local `2ab9486b49f64f9599ca1b22d4ea7b6a72ae3d03`:
  macOS runtime guide, `crates/contracts/gen-core`, provider catalog, SeedVR2
  registry, CLIP and SAM utilities. This snapshot is not yet the chosen release pin.
- SceneWorks currently references inference revision
  `eac60a770030aef0630ca418d85ffd169be9748a` in root Cargo.toml's patched
  candle-kernels dependency. Reconcile the full runtime pin and compatible artifact
  manifests before selecting LensWorks' dependency revisions.
- Chosen pin (sc-24678): inference `25bd55cdb6a56c78b07584a12150c9f5d46be439`, the revision
  SceneWorks main pins for its macOS worker's `runtime-macos` at qualification, consumed by
  `adapters/inference` (see its README and `DEPENDENCIES.json`).

Confidence: high in the source ownership split and identified RAW/persistence gaps;
moderate in this proposed render/document design pending a focused native integration
slice; unmeasured performance and unproven end-to-end AI task compatibility.
