# LensWorks Shortcut plan

Verified mirror of [epic sc-24655](https://app.shortcut.com/trefry/epic/24655), October 3, 2026. The live tracker is authoritative. Requirements planning is Done; native implementation remains unstarted.

## Objective

Build LensWorks as one native macOS application for catalog management, live nondestructive RAW development, the complete Compositor layered editor and integrated SceneWorks inference. The catalog and editor share one window, versions/history/recovery/source relationships, and the established filesystem media workflow. Done means the complete agreed experience works in an installed, validated Apple-silicon application—not merely that a prototype or bridge compiles.

## Authorization and source of truth

Michael authorized creation under [@lensworks](shortcutapp://groups/6a9ff222-1702-437c-be8b-9e6547440079) on October 3, 2026 after reviewing the requirements/integration/layout study. This epic is the operational home of those requirements and execution slices. The product interview is complete and confirmed policies are recorded here. S02 / sc-24657 owns the requirements record; S37 / sc-24694 measures the native prototype and obtains Michael's approval of final numerical limits before resource and terminal acceptance. Creation does not authorize implementation, GPU campaigns, paid infrastructure or public release.

New repository: https://github.com/michaeltrefry/LensWorks. Related foundation: https://app.shortcut.com/trefry/epic/22835 (PhotoCatalog repository and legacy acceptance remain unchanged). The LensWorks team was verified live; it uses the Standard workflow. S01 / sc-24656 is the initial native implementation slice; S02 / sc-24657 records completed requirements planning. Implementation stories remain unstarted with real blocking relations and prose dependency direction. Revalidate each candidate before execution; final scope completion is measured against this epic and the frozen source inventory.

## Requirements

E1. Native Swift/SwiftUI/AppKit application in the new michaeltrefry/LensWorks repository, targeting Apple silicon and macOS 26.2+. Compositor is the editing and design foundation; preserve MIT notices and freeze provenance/dependency revisions. PhotoCatalog's repository and existing foundation epic remain unchanged.

E2. Copy PhotoCatalog's complete UI-independent Rust catalog, metadata, migration and recovery services into LensWorks-owned source. PhotoCatalog's repository remains unchanged and is not a build/runtime dependency; its retirement or deletion must not affect LensWorks. Preserve notices and baseline provenance; fix the copied code within LensWorks. Retain SceneWorks inference's macOS Rust runtime. LensWorks owns versioned Swift-facing adapters with explicit ownership, buffers, typed errors, cancellation and callback lifetimes; blocking work stays off the UI thread. Necessary inference changes must be tracked explicitly before repinning.

E3. Preserve the complete editing capability surface of the frozen Compositor baseline and existing PhotoCatalog catalog/migration services. Maintain an exhaustive source-derived capability-to-story/fixture inventory. No difficult tool, unsupported input or AI requirement may be silently excluded or called a follow-on.

E4. Preserve the existing storage model: catalog and rebuildable previews are separate from filesystem media folders. Originals remain untouched. Edited/generated files use that same media workflow; edited images link to source catalog photos. Virtual catalog folders organize items and do not introduce a second app-private media library.

E5. When original drives are offline, permit document editing where its required full-resolution inputs are available and clearly disable operations/exports needing missing sources; retained-preview browsing/organization remains available. Native catalog management preserves stable identities, folder hierarchy, ratings/flags/color labels, hierarchical keywords, collections, filtering, complete XMP/provenance and conflicts, bounded incremental queries/previews, offline browsing/organization and atomic undoable folder/file relinking without moving originals. Preserve the existing million-photo scale contract; qualify integrated performance separately.

E6. Opening a photo switches the same window into an editor retaining catalog navigation and filmstrip. Extend Compositor's visual language for catalog screens. RAW, layers and a dockable AI panel can remain visible together. Native document tabs, shortcuts and panel behavior remain usable across supported window sizes.

E7. Use a color-managed RGB photography workflow with preserved embedded-profile provenance, wide-gamut display, selectable RGB export profiles and printer-profile soft-proofing; native CMYK/spot-color prepress editing is outside the chosen scope. One catalog photo has independent named versions, each with live RAW settings and layers. Use one authoritative development/color contract for preview and full-resolution export, retain RAW latitude and floating-point working data, and define alpha, precision and source/document/mask coordinate mappings. Existing RGBA8 RAW import is not acceptance for live RAW editing.

E8. Editable clone/heal strokes recompute deterministically from their upstream image after RAW changes, without sampling their own output. Geometry changes preserve or explicitly reconcile source-relative strokes and masks. AI layers retain generated pixels and are not automatically regenerated when RAW settings change.

E9. Multi-source compositions are separate catalog items linked to source photos and stable source-version revisions. Later source edits do not change a composition automatically. Explicit Update from Source is undoable and preserves downstream placement, masks, effects and required prior revision assets.

E10. Persistent Undo/Redo survives reopen, with configurable storage limits and named checkpoints. Automatically prune the oldest unprotected undo steps at the configured limit; preserve named checkpoints and assets required by current versions, compositions and source references. Warn when protected data prevents meeting the limit rather than silently deleting it. Version duplication remains independent and metadata/editor changes have defined undo ownership.

E11. Native documents offer an explicit self-contained portable export containing required source images, layers and masks, with optional persistent history. Ordinary catalog/media storage remains unchanged. Working versions autosave durably with recovery. Standalone documents remain editable outside catalogs. Add to Catalog registers the existing document in place, preserving identity, history and source links, and asks for a virtual catalog folder; it does not create an independent duplicate. Standalone generation creates a recoverable draft; first Save selects a virtual catalog folder and only registers the image after durable publication, then autosave continues. Canceling Save retains the draft. Unsaved generated/standalone recovery drafts remain until explicitly saved or discarded and are accessible in a visible Recoverable Drafts list; no automatic expiry.

E12. Import existing PhotoCatalog catalogs into a new LensWorks catalog, preserving source catalogs and original files. Preserve existing Lightroom discovery/current-family selection, dry-run/snapshot/reconciliation and metadata/virtual-copy/history provenance contracts. Unsupported Adobe semantics are preserved/reported; retained instructions do not prove rendering parity.

E13. Deliver all requested AI tasks: subject selection/masks, background removal, object removal/replacement, generative fill/expand, prompt image editing, denoising, restoration, upscaling, captions/keywords, semantic search and standalone generation. Verify real provider/task compatibility; generic image editing does not prove masked generation, and upscaling does not prove denoising.

E14. AI UI is task-first with compatible models and honored advanced controls; subject masks/background removal also appear contextually. Successful document AI edits immediately become undoable new layers that can be hidden/deleted. Captions/keywords remain reviewable suggestions. Semantic indexes build automatically and are rebuildable.

E15. Reuse compatible SceneWorks model files without silent duplication/replacement. Additional downloads are explicit and cancellable/resumable. Validate selected component layout, revision, precision/quantization, expected integrity and license terms; preserve external model-library ownership and avoid evicting active assets. AI results retain model/settings/input-revision/geometry provenance and explicit color/alpha conversions.

E16. Suitable AI tasks support single-document and selected-catalog resumable batches with progress, cancellation, failures and durable per-item state. Resumption does not repeat completed outputs or silently overwrite intervening edits. Batch AI image enhancements create a new named version for each photo, preserving its selected working version; successful result pixels are layers in the new version. Single-document AI editing retains its immediate-new-layer behavior, and metadata batches retain reviewable suggestions. Capture job input revisions and safely handle edits during execution.

E17. Full-resolution layered exports use original/source assets, not browse JPEGs, and preserve approved color/bit-depth/ICC/alpha/metadata contracts. Support native LensWorks documents plus layered PSD/PSB import and export, alongside the retained image formats. Preserve supported editable constructs and report Photoshop incompatibilities before lossy conversion rather than silently flattening or discarding data.

E18. Validate catalog/photo/layer editing on a 16 GB minimum Apple-silicon Mac and a declared reference Mac. Admit AI models only when their measured memory needs fit available unified memory. Pen-tablet editing is first-class, including pressure, supported tilt, configurable brush response and tablet shortcuts. Foreground interaction takes priority over preview/export/AI batches with bounded GPU/unified-memory residency and validated cancellation. Automatically pause background AI at safe execution boundaries during active painting/adjustment, show its paused state, and resume when interaction settles. Distribute a signed/notarized Mac app by direct download, with user-controlled in-app updates. Initial 95th-percentile responsiveness goals are warm photo switches within 1 s, RAW preview feedback within 150 ms and brush input-to-display within 50 ms, using 24–50 MP photos and a representative 20-layer fixture on minimum/reference Macs; larger documents have separate stress tests. These are goals, not validated support or fixed acceptance limits. S37 / sc-24694 measures the native prototype; Michael approves final latency/memory limits and the supported-fixture protocol after reviewing those measurements and before resource/terminal acceptance. Final acceptance includes precision/color, accessibility/keyboard/pen support, crash/restart/backup/restore, migrations, all tools and AI tasks with real inputs/weights, and installed signed application/update behavior. Source/library tests or a simulated prototype alone cannot establish integrated readiness.

## Epic acceptance

- Installed native catalog → photo version → live RAW → all layered tools → export → restart/checkpoint journey passes with catalog navigation/filmstrip and unchanged original hashes.

- PhotoCatalog/Lightroom import and metadata/organization/relink/backup/restore journeys reconcile counts, identities, variants, XMP, source revision links and non-rebuildable document assets; originals and source catalogs remain unchanged.

- Every frozen Compositor capability, retained catalog service and requested AI task has a mapped completed story/fixture. Unsupported required mechanisms remain blockers and must be explicitly resolved; preserving an opaque recipe does not establish Adobe render parity.

- Real-weight generation, masked edit/expand/replacement, subject/background masks, photographic denoise/restoration/upscale, caption/keyword review, semantic search and suitable resumable batches work through native UI with model/source provenance and validated controls.

- Autosave, persistent undo/checkpoints, source updates, standalone Add to Catalog and first generated-image Save pass cancel/crash/restart/failure cases without data loss, duplicate insertion or silent source-revision/geometry mismatch.

- The confirmed RGB/soft-proofing, minimum-device, offline/input/accessibility and signed distribution/update contracts, plus final performance/memory limits approved after S37 / sc-24694 native measurements, pass the stationary-revision installed-product protocol. Exact reviewed/merged source pins, CI/package identities and retained failures/limitations are part of acceptance.

## Slice plan

One epic records the complete integrated product scope in 37 executable stories. S02 completes requirements planning; all native implementation and installed acceptance remain open. Each implementation slice has three observable local acceptance criteria. S37 establishes measured final limits before S33 resource validation; S36 remains the sole terminal readiness story.

S01 / sc-24656. **Open, edit and reopen a catalog photo in the native Swift application** (feature) — Establish a real end-to-end LensWorks path: build the Apple-silicon Swift app with frozen Compositor provenance and a LensWorks-owned minimal Rust catalog adapter, open a catalog raster photo, create a working version, change a layer and reopen it. Freeze the complete source capability inventory for the subsequent stories. Depends on: none (prerequisites block this story).

S02 / sc-24657. **Finalize native LensWorks product requirements** (chore) — Record the completed product interview and map every confirmed decision into the epic and implementation stories. Numerical performance goals are provisional; the native prototype measurements and Michael's subsequent approval of final limits belong to S37 / sc-24694. Depends on: none (prerequisites block this story).

S03 / sc-24658. **Expose retained Rust catalog services through the Swift adapter** (chore) — Complete the LensWorks-owned catalog boundary around pinned public PhotoCatalog services: sessions/storage, organization/search, metadata/XMP, migration, previews/full decode, edit/export workers and recovery/backup. Avoid upstream recipe-schema modifications; LensWorks document data has its own versioned contract. Depends on: sc-24656 (prerequisites block this story).

S04 / sc-24659. **Manage catalogs, source folders and previews in native views** (feature) — Build Compositor-styled catalog creation/opening, source-folder import, hierarchical browse grid, selection, retained previews, virtual folders and catalog/editor navigation. Adapt bounded catalog service APIs rather than loading a whole catalog into UI memory. Depends on: sc-24658 (prerequisites block this story).

S05 / sc-24660. **Organize photos and preserve metadata through native catalog controls** (feature) — Expose ratings, flags, labels, hierarchical keywords, collections, photographic filters and metadata inspection/application. Preserve full XMP packets, unknown namespaces, source provenance and explicit conflicts; provide defined undo and controlled metadata output. Depends on: sc-24659 (prerequisites block this story).

S06 / sc-24661. **Browse offline sources and relink files without changing photo identity** (feature) — Preserve offline browse/organization and proactive or missing-source folder/root/subfolder/photo relinking. Allow editing only where required full-resolution inputs are available; clearly disable operations and exports needing missing sources. Retained browsing previews do not authorize approximate RAW editing or substitute for those inputs. Depends on: sc-24659, sc-24657 (prerequisites block this story).

S07 / sc-24662. **Import PhotoCatalog and Lightroom libraries into a new LensWorks catalog** (feature) — Provide native dry-run/review/import flows for existing PhotoCatalog and current logical Lightroom catalog families. Preserve original catalogs, external media references, source metadata/versions/history evidence, and explicit unsupported rendering semantics. Depends on: sc-24659, sc-24672 (prerequisites block this story).

S08 / sc-24663. **Develop live RAW sources beneath editable document layers** (feature) — Replace spend-at-import RAW semantics with a persisted live source and authoritative development contract. Resolve PhotoCatalog full-resolution decode versus Core Image development against the approved precision/camera/recipe requirements and use the same contract for preview and export. Depends on: sc-24658, sc-24657 (prerequisites block this story).

S09 / sc-24664. **Adapt the Metal and Core Image renderer for precision and bounded tiles** (chore) — Upgrade Compositor's RGBA8 rendering/pixel-kernel assumptions to the agreed precision/linear-color/alpha contract and a bounded document render graph. Preserve accelerated Apple rendering, dirty-tile behavior and display conversion boundaries. Depends on: sc-24663 (prerequisites block this story).

S10 / sc-24665. **Preserve the complete layer graph, masks and layer operations** (feature) — Adapt all Compositor layers/groups, opacity/blend modes, masks/clipping, merge, clipboard and inter-document drag/copy operations to the live-source document graph and precision contract. Depends on: sc-24664 (prerequisites block this story).

S11 / sc-24666. **Preserve all adjustment layers, layer effects and finishing filters** (feature) — Adapt the complete frozen adjustment/effect/filter surface: Hue/Saturation, levels, curves, exposure, gradient map, grain, black-and-white, color balance, invert, Gaussian/motion blur and noise; stroke, drop/inner shadow, color overlay, inner/outer glow; all source finishing filters. Depends on: sc-24665, sc-24672 (prerequisites block this story).

S12 / sc-24667. **Preserve transforms, crop and document canvas navigation** (feature) — Preserve scale/rotate/flip/free distortion, snapping/guides, document crop/straighten, image/canvas sizing/trim, rulers/grid, zoom/downsample/pixel-grid views and project tabs. Define source/document/mask coordinates under geometry changes. Depends on: sc-24665, sc-24672 (prerequisites block this story).

S13 / sc-24668. **Preserve selections, refinement and content-aware editing** (feature) — Adapt marquee/lasso/magic-wand/object/subject selection, feather/expand/contract/refinement and Compositor's content-aware fill/extend paths. This story preserves baseline image tools; generative inference is separately covered. Depends on: sc-24665, sc-24672 (prerequisites block this story).

S14 / sc-24669. **Preserve painting, erasing, blur and brush input behavior** (feature) — Adapt the complete Compositor brush/eraser/blur and smoothing/coverage behavior to the precision, tiled rendering and persistent command paths. Provide first-class pen-tablet input alongside mouse/keyboard: pressure, tilt where supported, configurable brush response and tablet shortcuts. Depends on: sc-24665, sc-24672 (prerequisites block this story).

S15 / sc-24670. **Replay editable clone and heal strokes after RAW changes** (feature) — Represent clone/heal operations as deterministic sampled commands with upstream/source-relative inputs rather than irreversible pixels. Recompute them after RAW recipe changes and correctly reconcile crop/transform changes. Depends on: sc-24667, sc-24672 (prerequisites block this story).

S16 / sc-24671. **Preserve editable text, vector shapes and gradients** (feature) — Adapt all frozen text, shape and gradient authoring/editing controls, transforms and rasterization into the precision document graph with proper persistent parameters. Depends on: sc-24665, sc-24672 (prerequisites block this story).

S17 / sc-24672. **Persist independent photo versions, undo history and named checkpoints** (feature) — Implement versioned LensWorks document records/packages and commands for live RAW, layer graphs and source references, separate from PhotoCatalog's strict recipe schema. Persist version independence, bounded Undo/Redo and checkpoint asset retention. Depends on: sc-24665, sc-24657 (prerequisites block this story).

S18 / sc-24673. **Compose multiple source photos with explicit source updates** (feature) — Create separate catalog composition items with placed stable photo-version revisions. Make Update from Source undoable and preserve downstream placement, masks/effects and previous revision reachability. Depends on: sc-24667, sc-24672 (prerequisites block this story).

S19 / sc-24674. **Recover autosaved documents and drafts across interrupted publication** (feature) — Coordinate document assets, journal/transactions and catalog records so autosave, first Save, source updates and standalone registration recover consistently. Retain unsaved recovery drafts until explicit Save or Discard, expose a visible Recoverable Drafts list and maintain single-writer behavior. Depends on: sc-24672, sc-24657 (prerequisites block this story).

S20 / sc-24675. **Open standalone documents and exchange layered PSD/PSB files** (feature) — Support catalog-free native layered documents, explicit Add to Catalog, the full frozen Compositor import surface and layered PSD/PSB import/export. Offer an explicit self-contained portable copy bundling required sources, layers and masks, with a choice to include persistent history; ordinary catalog/media storage remains unchanged. Depends on: sc-24674, sc-24657 (prerequisites block this story).

S21 / sc-24676. **Export complete layered documents with color and metadata fidelity** (feature) — Render entire live-RAW/layer/composition documents to supported PhotoCatalog image export formats through guarded durable publication, including batch export and source/revision safeguards. Depends on: sc-24672, sc-24657 (prerequisites block this story).

S22 / sc-24677. **Back up and restore catalog-linked documents and editor assets** (feature) — Extend the catalog backup contract to include LensWorks document schemas, history/checkpoints, composition source revisions and non-rebuildable edit/AI assets, with an explicit media/reference manifest and existing separate original/preview policy. Depends on: sc-24674, sc-24673 (prerequisites block this story).

S23 / sc-24678. **Bind the macOS inference runtime to native cancellable jobs** (chore) — Build the LensWorks-owned inference adapter using validated pinned runtime bundles, registry and bespoke utility interfaces where needed. Expose typed task/capability/load/job/progress/cancel/buffer contracts with model lifetimes and panic fencing. Depends on: sc-24656 (prerequisites block this story).

S24 / sc-24679. **Reuse SceneWorks model files and manage explicit additional downloads** (feature) — Provide native model discovery/admission and additional acquisition using compatible SceneWorks artifact layouts/manifests. Preserve external-library ownership and active model assets while validating expected integrity, revision, precision and licensing. Depends on: sc-24678 (prerequisites block this story).

S25 / sc-24680. **Dock the task-first AI panel and insert revision-aware results** (feature) — Build the native dockable task-first panel beside RAW/layers, compatible model menus, advanced controls and job lifecycle/provenance. Successful editing jobs become new undoable layers immediately, with correct captured input geometry and stale-revision handling. Depends on: sc-24678, sc-24679, sc-24672 (prerequisites block this story).

S26 / sc-24681. **Generate recoverable new images and save them into catalog folders** (feature) — Expose standalone prompt generation through compatible inference providers, recoverable drafts and first Save into selected virtual catalog folders using the existing filesystem workflow. Depends on: sc-24680, sc-24674, sc-24659 (prerequisites block this story).

S27 / sc-24682. **Edit prompts, replace objects and generate masked fill or expansion** (feature) — Implement real provider routes for prompt editing, object removal/replacement, masked generative fill and canvas expansion. Implement necessary missing inference mechanisms as tracked work within this outcome; unmasked image editing is not an acceptable substitute. Depends on: sc-24680, sc-24668, sc-24667 (prerequisites block this story).

S28 / sc-24683. **Select subjects and remove backgrounds with contextual editable masks** (feature) — Integrate contextual subject/background tools using Compositor's accelerated Apple Vision foundation and compatible inference segmentation routes where required. Keep masks editable with refinement and precise coordinate/alpha handling. Depends on: sc-24668, sc-24680 (prerequisites block this story).

S29 / sc-24684. **Denoise, restore and upscale photos through validated AI routes** (feature) — Provide separate validated photographic denoising, restoration and upscaling tasks with appropriate compatible models, pixel/color contracts and resolution-aware result insertion. SeedVR2's still-image route is a source-backed upscaling candidate, not proof of every enhancement task. Depends on: sc-24680, sc-24667 (prerequisites block this story).

S30 / sc-24685. **Review AI caption and keyword suggestions before metadata application** (feature) — Integrate compatible captioning and validated keyword extraction into catalog and editor workflows. Separate generation of suggestions from explicit metadata application and preserve existing metadata/XMP. Depends on: sc-24680, sc-24660 (prerequisites block this story).

S31 / sc-24686. **Search the catalog semantically using rebuildable image and text indexes** (feature) — Build automatic incremental image embeddings and paired text-query embeddings using compatible shared spaces. Version the semantic index by provider/assets/source/recipe and expose semantic search alongside existing catalog filters. Depends on: sc-24678, sc-24679, sc-24659 (prerequisites block this story).

S32 / sc-24687. **Run and resume AI jobs on catalog selections** (feature) — Extend suitable task routes to durable selected-photo queues creating new named versions for batch image enhancements while preserving each working version, with per-item captured revisions, reviewable metadata suggestions and shared model admission. Scope includes all suitable requested tasks, not only one demonstration operation. Depends on: sc-24681, sc-24682, sc-24683, sc-24684, sc-24685, sc-24657 (prerequisites block this story).

S37 / sc-24694. **Measure native responsiveness and approve final acceptance limits** (chore) — Run the native prototype measurement stage Michael selected before freezing final performance acceptance. This story owns concrete measurements and the resulting approved protocol; it is not a status-only revalidation slice. Preserve the complete capability scope if goals are missed and present the actual evidence for a decision. Depends on: sc-24659, sc-24669, sc-24678 (prerequisites block this story).

S33 / sc-24688. **Coordinate interactive rendering, exports and AI within resource budgets** (chore) — Prioritize foreground editing while previews, exports, semantic indexing and inference/batches share Apple GPU/unified memory. Automatically pause background AI at safe execution boundaries during painting or adjustment, show its paused state, and resume when interaction settles. Bound model residency/job concurrency, measure copy paths, and validate coexistence with SceneWorks without assuming shared GPU allocations. Depends on: sc-24664, sc-24678, sc-24657, sc-24694 (prerequisites block this story).

S34 / sc-24689. **Complete native keyboard, accessibility and panel behavior** (feature) — Carry the complete source shortcut customization and native interaction contracts through catalog/editor/AI/dialogs/tabs. Provide first-class pressure/tilt/tablet controls and native keyboard/accessibility/window behavior, eliminating controls that fail keyboard or assistive-technology use. Depends on: sc-24659, sc-24680, sc-24657 (prerequisites block this story).

S35 / sc-24690. **Package the native application and implement approved distribution updates** (chore) — Create repeatable Apple-silicon macOS 26.2+ builds/CI and distributable native packages with pinned Rust/native libraries, retained licenses and direct download of a signed and notarized Mac app with user-controlled in-app updates. Keep release credentials and paid/public publication actions separately authorized. Depends on: sc-24656, sc-24678, sc-24657 (prerequisites block this story).

S36 / sc-24691. **Verify the integrated native LensWorks product and reconcile epic completion** (chore) — Own the sole terminal readiness result after all local slices pass. Prove the entire confirmed catalog/live-RAW/layer/AI experience in an installed native package, including complete capability coverage, migrations/source preservation, restart/crash/restore, exports, accessibility and controlled resource acceptance. Depends on: sc-24661, sc-24662, sc-24666, sc-24669, sc-24670, sc-24671, sc-24675, sc-24676, sc-24677, sc-24686, sc-24687, sc-24688, sc-24689, sc-24690 (prerequisites block this story).

S01 supplies the initial native catalog/raster editing path. Catalog, live RAW, layered editing, durable documents and inference work follow their explicit dependencies. S37 follows actual catalog/RAW/brush/inference prototype building blocks; S33 consumes its approved limits. S36 transitively covers every preceding implementation slice and owns whole-product acceptance.

## Product decisions and measured acceptance

The product interview is complete. Storage, versions, history/drafts, standalone association, offline behavior, layered Photoshop interchange, RGB/soft-proofing, 16 GB target, pen input, AI result placement/scheduling and distribution are confirmed. The numerical goals above become final acceptance limits only after S37 / sc-24694 native measurements and Michael's explicit approval. This measured sequence is the selected policy, not an unanswered product question. Precision/color, accessibility/window and resource protocols are concrete engineering obligations in their owning stories. Missing release credentials and unvalidated hardware/task support remain execution blockers when relevant; no support is claimed without evidence.

## Sources and validation constraints

Planning inspection: Compositor 11d8d7a50992b24fd9a760a1c13b1c01b70aaf30; PhotoCatalog f4f8d3f12acc77fe5632720702c52a7cfefb5b58; local inference 2ab9486b49f64f9599ca1b22d4ea7b6a72ae3d03. These are discovery snapshots, not permission to choose an unvalidated release pin. Compositor RAW/layer paths are RGBA8; PhotoCatalog has f32 linear full decode but strict recipe JSON, and neither has the complete requested live RAW/layer/history schema. Swift adapters and integrated performance are new work.

Confidence: high in the repository/framework ownership and identified source gaps; the precise release pins, provider/task completeness and combined performance require the stories' actual evidence.

## Out of scope / separate authority

Native CMYK/spot-color prepress editing, Windows/Linux launch builds, rewriting PhotoCatalog, migrating live originals in place, replacing the existing foundation epic, cloud/multi-computer catalogs, video/audio/training product features, unsolicited paid resources and public releases. No source original, source catalog or shared SceneWorks model library may be modified by a migration/admission convenience. Layered PSD/PSB import and export are now confirmed requirements; compatibility reports identify Photoshop constructs that cannot be preserved.

Execution uses reviewed off-main changes, meaningful local validation and exact terminal CI/installed evidence. Long jobs retain revision/job identity, owner, timeout, required evidence and completion/resume handoff. No watcher, automation, build, model download or GPU job is launched by this planning operation.

## Recorded tracker index

- S01: [sc-24656](https://app.shortcut.com/trefry/story/24656) — Open, edit and reopen a catalog photo in the native Swift application (feature); prerequisites: none; 3 local acceptance criteria.
- S02: [sc-24657](https://app.shortcut.com/trefry/story/24657) — Finalize native LensWorks product requirements (chore); prerequisites: none; 3 local acceptance criteria.
- S03: [sc-24658](https://app.shortcut.com/trefry/story/24658) — Expose retained Rust catalog services through the Swift adapter (chore); prerequisites: sc-24656; 3 local acceptance criteria.
- S04: [sc-24659](https://app.shortcut.com/trefry/story/24659) — Manage catalogs, source folders and previews in native views (feature); prerequisites: sc-24658; 3 local acceptance criteria.
- S05: [sc-24660](https://app.shortcut.com/trefry/story/24660) — Organize photos and preserve metadata through native catalog controls (feature); prerequisites: sc-24659; 3 local acceptance criteria.
- S06: [sc-24661](https://app.shortcut.com/trefry/story/24661) — Browse offline sources and relink files without changing photo identity (feature); prerequisites: sc-24657, sc-24659; 3 local acceptance criteria.
- S07: [sc-24662](https://app.shortcut.com/trefry/story/24662) — Import PhotoCatalog and Lightroom libraries into a new LensWorks catalog (feature); prerequisites: sc-24659, sc-24672; 3 local acceptance criteria.
- S08: [sc-24663](https://app.shortcut.com/trefry/story/24663) — Develop live RAW sources beneath editable document layers (feature); prerequisites: sc-24657, sc-24658; 3 local acceptance criteria.
- S09: [sc-24664](https://app.shortcut.com/trefry/story/24664) — Adapt the Metal and Core Image renderer for precision and bounded tiles (chore); prerequisites: sc-24663; 3 local acceptance criteria.
- S10: [sc-24665](https://app.shortcut.com/trefry/story/24665) — Preserve the complete layer graph, masks and layer operations (feature); prerequisites: sc-24664; 3 local acceptance criteria.
- S11: [sc-24666](https://app.shortcut.com/trefry/story/24666) — Preserve all adjustment layers, layer effects and finishing filters (feature); prerequisites: sc-24665, sc-24672; 3 local acceptance criteria.
- S12: [sc-24667](https://app.shortcut.com/trefry/story/24667) — Preserve transforms, crop and document canvas navigation (feature); prerequisites: sc-24665, sc-24672; 3 local acceptance criteria.
- S13: [sc-24668](https://app.shortcut.com/trefry/story/24668) — Preserve selections, refinement and content-aware editing (feature); prerequisites: sc-24665, sc-24672; 3 local acceptance criteria.
- S14: [sc-24669](https://app.shortcut.com/trefry/story/24669) — Preserve painting, erasing, blur and brush input behavior (feature); prerequisites: sc-24665, sc-24672; 3 local acceptance criteria.
- S15: [sc-24670](https://app.shortcut.com/trefry/story/24670) — Replay editable clone and heal strokes after RAW changes (feature); prerequisites: sc-24667, sc-24672; 3 local acceptance criteria.
- S16: [sc-24671](https://app.shortcut.com/trefry/story/24671) — Preserve editable text, vector shapes and gradients (feature); prerequisites: sc-24665, sc-24672; 3 local acceptance criteria.
- S17: [sc-24672](https://app.shortcut.com/trefry/story/24672) — Persist independent photo versions, undo history and named checkpoints (feature); prerequisites: sc-24657, sc-24665; 3 local acceptance criteria.
- S18: [sc-24673](https://app.shortcut.com/trefry/story/24673) — Compose multiple source photos with explicit source updates (feature); prerequisites: sc-24667, sc-24672; 3 local acceptance criteria.
- S19: [sc-24674](https://app.shortcut.com/trefry/story/24674) — Recover autosaved documents and drafts across interrupted publication (feature); prerequisites: sc-24657, sc-24672; 3 local acceptance criteria.
- S20: [sc-24675](https://app.shortcut.com/trefry/story/24675) — Open standalone documents and exchange layered PSD/PSB files (feature); prerequisites: sc-24657, sc-24674; 3 local acceptance criteria.
- S21: [sc-24676](https://app.shortcut.com/trefry/story/24676) — Export complete layered documents with color and metadata fidelity (feature); prerequisites: sc-24657, sc-24672; 3 local acceptance criteria.
- S22: [sc-24677](https://app.shortcut.com/trefry/story/24677) — Back up and restore catalog-linked documents and editor assets (feature); prerequisites: sc-24673, sc-24674; 3 local acceptance criteria.
- S23: [sc-24678](https://app.shortcut.com/trefry/story/24678) — Bind the macOS inference runtime to native cancellable jobs (chore); prerequisites: sc-24656; 3 local acceptance criteria.
- S24: [sc-24679](https://app.shortcut.com/trefry/story/24679) — Reuse SceneWorks model files and manage explicit additional downloads (feature); prerequisites: sc-24678; 3 local acceptance criteria.
- S25: [sc-24680](https://app.shortcut.com/trefry/story/24680) — Dock the task-first AI panel and insert revision-aware results (feature); prerequisites: sc-24672, sc-24678, sc-24679; 3 local acceptance criteria.
- S26: [sc-24681](https://app.shortcut.com/trefry/story/24681) — Generate recoverable new images and save them into catalog folders (feature); prerequisites: sc-24659, sc-24674, sc-24680; 3 local acceptance criteria.
- S27: [sc-24682](https://app.shortcut.com/trefry/story/24682) — Edit prompts, replace objects and generate masked fill or expansion (feature); prerequisites: sc-24667, sc-24668, sc-24680; 3 local acceptance criteria.
- S28: [sc-24683](https://app.shortcut.com/trefry/story/24683) — Select subjects and remove backgrounds with contextual editable masks (feature); prerequisites: sc-24668, sc-24680; 3 local acceptance criteria.
- S29: [sc-24684](https://app.shortcut.com/trefry/story/24684) — Denoise, restore and upscale photos through validated AI routes (feature); prerequisites: sc-24667, sc-24680; 3 local acceptance criteria.
- S30: [sc-24685](https://app.shortcut.com/trefry/story/24685) — Review AI caption and keyword suggestions before metadata application (feature); prerequisites: sc-24660, sc-24680; 3 local acceptance criteria.
- S31: [sc-24686](https://app.shortcut.com/trefry/story/24686) — Search the catalog semantically using rebuildable image and text indexes (feature); prerequisites: sc-24659, sc-24678, sc-24679; 3 local acceptance criteria.
- S32: [sc-24687](https://app.shortcut.com/trefry/story/24687) — Run and resume AI jobs on catalog selections (feature); prerequisites: sc-24657, sc-24681, sc-24682, sc-24683, sc-24684, sc-24685; 3 local acceptance criteria.
- S33: [sc-24688](https://app.shortcut.com/trefry/story/24688) — Coordinate interactive rendering, exports and AI within resource budgets (chore); prerequisites: sc-24657, sc-24664, sc-24678, sc-24694; 3 local acceptance criteria.
- S34: [sc-24689](https://app.shortcut.com/trefry/story/24689) — Complete native keyboard, accessibility and panel behavior (feature); prerequisites: sc-24657, sc-24659, sc-24680; 3 local acceptance criteria.
- S35: [sc-24690](https://app.shortcut.com/trefry/story/24690) — Package the native application and implement approved distribution updates (chore); prerequisites: sc-24656, sc-24657, sc-24678; 3 local acceptance criteria.
- S36: [sc-24691](https://app.shortcut.com/trefry/story/24691) — Verify the integrated native LensWorks product and reconcile epic completion (chore); prerequisites: sc-24661, sc-24662, sc-24666, sc-24669, sc-24670, sc-24671, sc-24675, sc-24676, sc-24677, sc-24686, sc-24687, sc-24688, sc-24689, sc-24690; 3 local acceptance criteria.
- S37: [sc-24694](https://app.shortcut.com/trefry/story/24694) — Measure native responsiveness and approve final acceptance limits (chore); prerequisites: sc-24659, sc-24669, sc-24678; 3 local acceptance criteria.

## Confirmed interview decisions — October 3, 2026

- Batch AI image enhancements create a new named version per photo, preserving the current working version; single-document AI edits still add layers immediately.
- Native LensWorks documents plus layered PSD/PSB import and export are required, with explicit compatibility reports for Photoshop features that cannot be preserved.
- Offline editing is allowed only where required full-resolution inputs are available; missing-source operations/exports are clearly disabled, while preview browsing and metadata organization remain available.
- An explicit portable native export bundles required source images, layers and masks, with an option to include persistent history; normal media storage is unchanged.


## Additional confirmed interview decisions — October 3, 2026

- Automatically prune the oldest unprotected undo steps; protect checkpoints and referenced version/composition assets, and warn if protected data exceeds the limit.
- Keep unsaved recovery drafts until explicit Save or Discard, with a visible Recoverable Drafts list and no automatic expiry.
- Add to Catalog registers the existing document in place with its identity/history/source links and asks for a virtual catalog folder.
- Color-managed RGB photography includes wide-gamut display, selectable export profiles and print soft-proofing; native CMYK/spot-color prepress editing is outside the selected scope.
- Validate a 16 GB minimum for catalog/photo/layer editing; AI model admission follows measured available-memory fit, with larger models on capable machines.
- First-class pen input includes pressure, tilt where supported, configurable brush response and tablet shortcuts.


## Final confirmed interview decisions — October 3, 2026

- Direct download of a signed and notarized Mac app with user-controlled in-app updates.
- Background AI automatically pauses at safe execution boundaries during painting/adjustment, visibly reports pause, then resumes when interaction settles.
- Provisional p95 goals: warm switch 1 s; RAW preview 150 ms; brush display 50 ms, for 24–50 MP and 20-layer fixtures on 16 GB minimum/reference Macs. Measure the native prototype first, then obtain Michael's approval of final limits in sc-24694 before final resource/installed acceptance.
