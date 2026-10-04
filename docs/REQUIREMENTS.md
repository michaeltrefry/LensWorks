# LensWorks requirements interview

Status: confirmed scope and the complete tracked slice plan were recorded in
[Shortcut epic sc-24655](https://app.shortcut.com/trefry/epic/24655) under
`@lensworks` on October 3, 2026, following Michael's instruction to create the epic.
The live epic and stories are the operational source of truth. The product interview
is complete and [sc-24657](https://app.shortcut.com/trefry/story/24657) requirements
planning is Done. Numerical limits will be approved after real native prototype
measurements in [sc-24694](https://app.shortcut.com/trefry/story/24694), as selected
by Michael. Native implementation and installed acceptance remain unstarted.

## Confirmed decisions

- LensWorks lives in a new GitHub repository, `michaeltrefry/LensWorks`.
  The PhotoCatalog repository remains unchanged.
- The new application uses Swift for its native application and editor.
  Compositor provides the editor and visual-design foundation; catalog-management
  screens should extend its existing visual language.
- PhotoCatalog's Rust catalog, metadata, migration, and recovery services are
  retained as a pinned dependency behind a Swift interface. The PhotoCatalog
  repository remains unchanged; the Swift-facing adapter belongs to LensWorks.
- Launch support is Apple-silicon Macs running macOS 26.2 or later.
- Opening a catalog photo switches the same window into the editor, retaining
  a filmstrip and catalog navigation.
- A single RAW photograph appears as one catalog photo with named versions
  beneath it. Each version retains independent RAW development settings and
  layers.
- Editing autosaves the working version with recovery. Users can explicitly
  create named checkpoints.
- Undo/Redo history persists across closing and reopening an edited version,
  with a configurable storage limit. Automatically prune the oldest unprotected
  undo steps; preserve checkpoints and assets required by current versions,
  compositions and source references. Warn if protected data exceeds the limit.
- Standalone layered documents can be opened and edited without adding them to
  a catalog. Add to Catalog asks for a virtual folder and registers the existing
  document in place, preserving identity, history and source links without creating
  an independent duplicate.
- Offer an explicit self-contained portable native document export containing
  required source images, layers and masks, with a choice to include persistent
  history. Ordinary catalog and media storage remain unchanged.
- Support native LensWorks documents plus layered PSD/PSB import and export.
  Report Photoshop-specific features that cannot be preserved before lossy
  conversion; do not silently flatten or discard them.
- Multi-source compositions appear as separate catalog composition items linked
  to their source photographs.
- Compositions retain stable source-photo revisions when those photo versions
  subsequently change. An explicit Update from Source action refreshes a placed
  source; source-version edits do not automatically alter the composition.
- Existing PhotoCatalog catalogs are imported into a new LensWorks catalog.
  Migration preserves the existing catalog and original image files.
- Preserve the existing storage model: catalog data and previews are separate
  from the filesystem folders containing image files. Originals, edited image
  files, and generated images use the same existing media storage workflow.
  Edited images are linked to their source catalog image. Do not introduce a
  separate managed-media storage scheme for edited or generated images.
- When original drives are offline, permit editing where a document's required
  full-resolution inputs are available. Clearly disable operations and exports
  needing missing sources. Preview browsing and metadata organization remain
  available; retained previews do not substitute for required full-resolution data.
- RAW development and layered editing form one continuous editing experience.
  Source RAW files remain untouched.
- Editable clone/heal strokes recompute against the updated photograph when its
  RAW development settings change. Generated AI layers contain their own pixels
  and are distinct from these sampled retouch operations.
- Integrated AI features reuse the existing SceneWorks Rust inference library.
  A Swift-facing integration boundary must be designed and validated.
- The AI capability requirements include subject selection/masking, background
  removal, object removal/replacement, generative fill/expand, prompt-based image
  editing, denoising/restoration/upscaling, captions/keywords, semantic catalog
  search, and standalone image generation. Model/runtime support must be verified
  for every requested capability; gaps cannot silently reduce the agreed scope.
- Most AI features use a dedicated AI panel. Subject masks and background removal
  also feel integrated as contextual editing tools.
- The AI panel starts with a task, shows compatible models, and makes advanced
  controls available. It is dockable and can remain visible alongside layers and
  RAW controls.
- AI-generated captions and keywords are suggestions for user review before
  application. Semantic search indexes build automatically and are rebuildable.
- Suitable AI operations also support selected-photo catalog batches, with
  progress, cancellation, and resumable work, alongside single-photo editing.
- Batch AI image enhancements create a new named version for each photo,
  preserving its current working version. Result pixels become layers in that new
  version; single-document AI edits continue adding layers immediately. Metadata
  batches retain reviewable suggestions rather than creating image versions.
- Reuse compatible model files already downloaded for SceneWorks. LensWorks can
  manage additional downloads explicitly; model reuse must verify compatibility
  rather than silently duplicating or replacing an existing model library.
- Successful AI editing results are immediately inserted into the existing
  document as new layers, which users can hide or delete. A separate candidate
  acceptance step or automatic creation of a new version is not required.
- New generated images without a source photograph are saved into the catalog,
  with a save dialog asking which virtual catalog folder to save them to.
  Virtual folders provide catalog organization; physical files follow the same
  existing filesystem storage workflow as other catalog images.
- Standalone generation produces a recoverable draft. The first Save asks for
  its catalog folder and adds it to the catalog after durable publication; autosave
  continues afterward. Canceling Save retains the draft. Unsaved recovery drafts
  have no automatic expiry, remain until explicit Save or Discard and appear in a
  visible Recoverable Drafts list.
- Use color-managed RGB photography with preserved profile provenance, wide-gamut
  display, selectable RGB export profiles and printer-profile soft-proofing.
  Native CMYK/spot-color prepress editing is outside the selected scope.
- Validate a 16 GB minimum Apple-silicon target for catalog/photo/layer editing;
  admit AI models by measured fit in available unified memory, with larger models
  on capable machines. This is a target to prove, not measured support.
- Pen input is first-class: pressure, tilt where supported, configurable brush
  response and tablet shortcuts, alongside mouse/keyboard and native accessibility.
- Distribute a signed and notarized Mac app by direct download, with user-controlled
  in-app updates. Planning does not publish a release or purchase signing services.
- Automatically pause background AI at safe execution boundaries during active
  painting/adjustment, show its paused state and resume when interaction settles.

## Performance goals and measured approval

Initial goals at the 95th percentile on the 16 GB minimum and declared reference
Macs are warm photo switches within 1 second, RAW-slider preview feedback within
150 ms and brush input-to-display latency within 50 ms. Use ordinary 24–50 MP
photos and a representative 20-layer fixture; larger documents get separate stress
tests. These goals are not final pass/fail limits or validated product claims.

[sc-24694](https://app.shortcut.com/trefry/story/24694) measures the real native
prototype and retains the host/source/model, memory and timing evidence. Michael
then approves final limits and the supported-fixture protocol before resource
validation and terminal acceptance. The full capability scope stays tracked if
goals are missed. No product-policy interview question remains unanswered.

## Engineering validation

The implementation stories own the Swift/Rust interfaces, release pins, live RAW
development/rendering contract, document schemas, source-coordinate mappings,
recovery guarantees, model compatibility and resource scheduling. These require
source/fixture validation and concrete recommendations, rather than asking the
user to choose routine implementation details. Complete retained catalog/editor
coverage, unchanged source files and the confirmed storage model remain requirements.

## Planning sequence

1. Resolve requirements through short interview rounds.
2. Explore catalog/editor layouts using Compositor's design language.
3. Reconcile implementation seams and tradeoffs with the confirmed requirements.
4. Present the complete epic and story proposal for explicit approval.
5. Record the approved requirements and slices in Shortcut, verify their readback,
   and execute through tracked stories.

## Review artifacts

- [Integration proposal](INTEGRATION.md): source-backed ownership, live RAW and
  rendering gaps, document/recovery design, AI capability routes, complete baseline
  and acceptance needs. Recommendations are explicitly separated from decisions.
- [Interaction study](design/README.md): catalog, same-window editor, generated
  draft/Save, standalone registration and batch recovery. The HTML prototype is
  illustrative; production remains native Swift.
- All confirmed product policies are recorded in the live epic and affected
  stories; the measured-performance approval sequence is tracked in sc-24694.
- [Verified story index](SHORTCUT_STORIES.md): 37 stories, three local acceptance
  criteria each, and 88 real directed dependencies. Requirements planning alone
  is Done; S01 is To Do and the other 35 stories are Backlog. One terminal
  readiness story, sc-24691, owns
  integrated installed-product proof across the entire requirement set.
