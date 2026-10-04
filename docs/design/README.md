# LensWorks interaction study

Open `index.html` through a local server. This is a reviewable browser prototype,
not the production application or a React/Vite recommendation. The application
remains native Swift. Sample illustrations and AI execution are simulated.

## Design foundation

Compositor supplies the visual language: charcoal canvas, 42-point panel headers,
13-point semibold titles, restrained monochrome controls, 56-point tool rail,
right-side panels and a compact status bar. LensWorks extends that language with
catalog navigation, a grid, photo versions, a filmstrip, RAW and AI panels.

## Review flows

1. Catalog: select a photo, choose a version or double-click to open the same-window
   editor. Catalog navigation and filmstrip remain available.
2. Editor: show/float/dock the AI panel, select a task, run/cancel simulated AI,
   hide/delete its result layer, adjust sample RAW exposure, undo/redo and create or
   restore a checkpoint. Contextual subject/background tools expose editable masks.
3. Generation: generate a draft, reload to recover it, cancel first Save without
   discarding it, then choose a virtual catalog folder and save.
4. Batch: run the three-favorite sample batch, cancel remaining work, reload, resume.
5. Standalone: open the sample document and use Add to Catalog.

Browser-local persistence demonstrates the recovery/history interaction only. It
does not model the final document schema or independently store each photo version.
RAW sliders change an illustration's brightness; no RAW processing occurs. Task
models and advanced settings are illustrative. Ordinary brush/crop tool selection
is shown, but pixel editing is not implemented in this study. Sample catalog paths
describe the already-agreed storage model; no filesystem operation occurs.

## Confirmed follow-up decisions

- Batch image enhancements create new named versions, preserving working versions.
- Native documents and layered PSD/PSB import/export are required, with explicit
  compatibility reports. The study does not implement document conversion.
- Offline editing requires the full-resolution inputs needed by an operation;
  operations/exports needing missing sources are clearly disabled.
- Explicit portable native export bundles required sources, layers and masks,
  with optional history; ordinary media storage remains unchanged.

The product interview is complete: in-place standalone registration, protected
checkpoint/history pruning, explicitly retained recoverable drafts, RGB soft-proofing,
16 GB target, first-class pen input, direct signed/notarized download with controlled
updates and safe-boundary background-AI pause/resume are confirmed. This study does
not simulate every approved policy. Catalog import/management screen details and
small-display panel behavior still need native layout validation.

Provisional p95 goals are 1 s warm photo switch, 150 ms RAW preview and 50 ms brush
display for 24–50 MP/20-layer fixtures on minimum/reference Macs. Final limits will
be approved after the real native prototype measurements in sc-24694. Browser
timings are not evidence for those limits.

The study is intended to reveal layout and workflow problems before native work;
the implementation plan must still cover the full agreed editing and catalog scope.

## Verification

Checked in the Codex browser at 1280 × 720: catalog search and editor transition,
panel float/dock, simulated AI completion/new layer and cancellation, layer
visibility/undo, named checkpoint persistence, undo/redo across reload, generated
draft recovery, first Save cancellation and insertion, batch cancellation/reload/
resume/completion, and standalone registration in Compositions. A folder-filtering
defect was fixed and registration rechecked. Browser error logs were empty.

Screenshots are `catalog-preview.jpg`, `editor-preview.jpg`, and `save-preview.jpg`.
These checks verify the study's interactions, not native rendering, actual model
execution, document durability, catalog performance or accessibility certification.
