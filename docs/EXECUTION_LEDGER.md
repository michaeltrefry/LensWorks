# LensWorks execution ledger

October 4, 2026. Live Shortcut is authoritative. This is a continuation record, not completion evidence. Execution branch: `codex/sc-24655-native-delivery`; repository: `/Users/michael/Repos/LensWorks`. Original PhotoCatalog checkout remains unchanged.

| Story | State | Surface | Evidence | Next action |
|---|---|---|---|---|
| sc-24656 | In Progress | Open, edit and reopen a catalog photo in the native Swift application | 6 Rust tests, 25 native tests, installed two-process restart pass; source SHA unchanged; independent reviews clear | Publish and verify private PR merge before Done |
| sc-24657 | Done | Finalize native LensWorks product requirements | Requirements and live epic reconciled | Retain confirmed policy; no redo |
| sc-24658 | Backlog | Expose retained Rust catalog services through the Swift adapter | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24659 | Backlog | Manage catalogs, source folders and previews in native views | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24660 | Backlog | Organize photos and preserve metadata through native catalog controls | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24661 | Backlog | Browse offline sources and relink files without changing photo identity | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24662 | Backlog | Import PhotoCatalog and Lightroom libraries into a new LensWorks catalog | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24663 | Backlog | Develop live RAW sources beneath editable document layers | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24664 | Backlog | Adapt the Metal and Core Image renderer for precision and bounded tiles | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24665 | Backlog | Preserve the complete layer graph, masks and layer operations | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24666 | Backlog | Preserve all adjustment layers, layer effects and finishing filters | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24667 | Backlog | Preserve transforms, crop and document canvas navigation | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24668 | Backlog | Preserve selections, refinement and content-aware editing | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24669 | Backlog | Preserve painting, erasing, blur and brush input behavior | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24670 | Backlog | Replay editable clone and heal strokes after RAW changes | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24671 | Backlog | Preserve editable text, vector shapes and gradients | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24672 | Backlog | Persist independent photo versions, undo history and named checkpoints | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24673 | Backlog | Compose multiple source photos with explicit source updates | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24674 | Backlog | Recover autosaved documents and drafts across interrupted publication | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24675 | Backlog | Open standalone documents and exchange layered PSD/PSB files | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24676 | Backlog | Export complete layered documents with color and metadata fidelity | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24677 | Backlog | Back up and restore catalog-linked documents and editor assets | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24678 | Backlog | Bind the macOS inference runtime to native cancellable jobs | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24679 | Backlog | Reuse SceneWorks model files and manage explicit additional downloads | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24680 | Backlog | Dock the task-first AI panel and insert revision-aware results | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24681 | Backlog | Generate recoverable new images and save them into catalog folders | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24682 | Backlog | Edit prompts, replace objects and generate masked fill or expansion | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24683 | Backlog | Select subjects and remove backgrounds with contextual editable masks | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24684 | Backlog | Denoise, restore and upscale photos through validated AI routes | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24685 | Backlog | Review AI caption and keyword suggestions before metadata application | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24686 | Backlog | Search the catalog semantically using rebuildable image and text indexes | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24687 | Backlog | Run and resume AI jobs on catalog selections | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24688 | Backlog | Coordinate interactive rendering, exports and AI within resource budgets | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24689 | Backlog | Complete native keyboard, accessibility and panel behavior | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24690 | Backlog | Package the native application and implement approved distribution updates | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24691 | Backlog | Verify the integrated native LensWorks product and reconcile epic completion | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |
| sc-24694 | Backlog | Measure native responsiveness and approve final acceptance limits | Not implemented or accepted | Wait for directed prerequisites; revalidate before execution |

Sources: Compositor `11d8d7a50992b24fd9a760a1c13b1c01b70aaf30`, PhotoCatalog `f4f8d3f12acc77fe5632720702c52a7cfefb5b58`; adapters qualify these exact revisions. Inference remains unintegrated until sc-24678. No product support or performance claims follow from baseline source reuse.

## S01 local acceptance — October 4, 2026

The native arm64/macOS 26.2 application was built with Xcode 26.5 and the locked Rust adapter. Six Rust tests and 25 focused Swift tests (LensWorksCatalogTests, ProjectTests and ProjectWorkspaceTests) pass. Independent reviewers reproduced and verified repair of managed-preview symlink admission and reviewed native persistence, source protections, lifetime and packaging.

The installed development app at `.build/installed-s01-quit-fixed/LensWorks.app` passes architecture/deployment/dependency closure and carries the complete checked notice manifest. `scripts/verify-installed-raster.py` passes two separate processes: real catalog import, working version creation, layer rename to `Persisted Layer`, opacity 0.6, save and restart. Photo/version/document/layer identities and source/project paths match; both documents are saved. Original SHA-256 remains `51496f200d92eb6e85601d5536ad3ec6cffaa94b344988e49162938bfb1db707`. A termination deadlock reproduced in the initial installed run was repaired and independently reviewed; the successful rerun preserves normal quit confirmation.

Evidence: `.build/rust-catalog-tests.log`, `.build/native-build.log`, `.build/native-tests.log`, `.build/xcode/Logs/Test/`, `.build/installed-s01-quit-fixed/closure.json`, `.build/native-notices-final/inventory.json`, `.build/acceptance-s01-quit-fixed/result.json`. No upstream PhotoCatalog tracked changes; original execution checkout is clean. This establishes S01 local acceptance, not CI, notarization, live RAW, full catalog service coverage or AI acceptance. Those remain required by the live epic.

Capability audit covers 28,319 rows, including 11,774 declared controls/services mapped to concrete planned fixture profiles, 16,545 provenance-only support rows and 735 frozen files. All four fault injections reject invalid inventories. Planned fixture/source-test references are not evidence that later capabilities have passed.

Installed UI inspection after reopening confirms catalog navigation, selected real photo, horizontal filmstrip, canvas, editable layer and 60% opacity in the same native window. Screenshot: `.build/acceptance-s01-quit-fixed/native-window.png`; normal Command-Q closes the acceptance instance.
