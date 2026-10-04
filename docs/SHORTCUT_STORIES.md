# LensWorks verified story index

Verified October 3, 2026. Epic: [sc-24655](https://app.shortcut.com/trefry/epic/24655), team @lensworks, Standard workflow. 37 stories, 88 directed blocking relations, three local acceptance criteria per story. S02 requirements planning is Done; S01 is To Do; the remaining 35 are Backlog. Native implementation has not started.

| Story | Type | Title | Depends on | AC count | State |
| --- | --- | --- | --- | --- | --- |
| [sc-24656](https://app.shortcut.com/trefry/story/24656) | feature | Open, edit and reopen a catalog photo in the native Swift application | none | 3 | To Do |
| [sc-24657](https://app.shortcut.com/trefry/story/24657) | chore | Finalize native LensWorks product requirements | none | 3 | Done |
| [sc-24658](https://app.shortcut.com/trefry/story/24658) | chore | Expose retained Rust catalog services through the Swift adapter | sc-24656 | 3 | Backlog |
| [sc-24659](https://app.shortcut.com/trefry/story/24659) | feature | Manage catalogs, source folders and previews in native views | sc-24658 | 3 | Backlog |
| [sc-24660](https://app.shortcut.com/trefry/story/24660) | feature | Organize photos and preserve metadata through native catalog controls | sc-24659 | 3 | Backlog |
| [sc-24661](https://app.shortcut.com/trefry/story/24661) | feature | Browse offline sources and relink files without changing photo identity | sc-24657, sc-24659 | 3 | Backlog |
| [sc-24662](https://app.shortcut.com/trefry/story/24662) | feature | Import PhotoCatalog and Lightroom libraries into a new LensWorks catalog | sc-24659, sc-24672 | 3 | Backlog |
| [sc-24663](https://app.shortcut.com/trefry/story/24663) | feature | Develop live RAW sources beneath editable document layers | sc-24657, sc-24658 | 3 | Backlog |
| [sc-24664](https://app.shortcut.com/trefry/story/24664) | chore | Adapt the Metal and Core Image renderer for precision and bounded tiles | sc-24663 | 3 | Backlog |
| [sc-24665](https://app.shortcut.com/trefry/story/24665) | feature | Preserve the complete layer graph, masks and layer operations | sc-24664 | 3 | Backlog |
| [sc-24666](https://app.shortcut.com/trefry/story/24666) | feature | Preserve all adjustment layers, layer effects and finishing filters | sc-24665, sc-24672 | 3 | Backlog |
| [sc-24667](https://app.shortcut.com/trefry/story/24667) | feature | Preserve transforms, crop and document canvas navigation | sc-24665, sc-24672 | 3 | Backlog |
| [sc-24668](https://app.shortcut.com/trefry/story/24668) | feature | Preserve selections, refinement and content-aware editing | sc-24665, sc-24672 | 3 | Backlog |
| [sc-24669](https://app.shortcut.com/trefry/story/24669) | feature | Preserve painting, erasing, blur and brush input behavior | sc-24665, sc-24672 | 3 | Backlog |
| [sc-24670](https://app.shortcut.com/trefry/story/24670) | feature | Replay editable clone and heal strokes after RAW changes | sc-24667, sc-24672 | 3 | Backlog |
| [sc-24671](https://app.shortcut.com/trefry/story/24671) | feature | Preserve editable text, vector shapes and gradients | sc-24665, sc-24672 | 3 | Backlog |
| [sc-24672](https://app.shortcut.com/trefry/story/24672) | feature | Persist independent photo versions, undo history and named checkpoints | sc-24657, sc-24665 | 3 | Backlog |
| [sc-24673](https://app.shortcut.com/trefry/story/24673) | feature | Compose multiple source photos with explicit source updates | sc-24667, sc-24672 | 3 | Backlog |
| [sc-24674](https://app.shortcut.com/trefry/story/24674) | feature | Recover autosaved documents and drafts across interrupted publication | sc-24657, sc-24672 | 3 | Backlog |
| [sc-24675](https://app.shortcut.com/trefry/story/24675) | feature | Open standalone documents and exchange layered PSD/PSB files | sc-24657, sc-24674 | 3 | Backlog |
| [sc-24676](https://app.shortcut.com/trefry/story/24676) | feature | Export complete layered documents with color and metadata fidelity | sc-24657, sc-24672 | 3 | Backlog |
| [sc-24677](https://app.shortcut.com/trefry/story/24677) | feature | Back up and restore catalog-linked documents and editor assets | sc-24673, sc-24674 | 3 | Backlog |
| [sc-24678](https://app.shortcut.com/trefry/story/24678) | chore | Bind the macOS inference runtime to native cancellable jobs | sc-24656 | 3 | Backlog |
| [sc-24679](https://app.shortcut.com/trefry/story/24679) | feature | Reuse SceneWorks model files and manage explicit additional downloads | sc-24678 | 3 | Backlog |
| [sc-24680](https://app.shortcut.com/trefry/story/24680) | feature | Dock the task-first AI panel and insert revision-aware results | sc-24672, sc-24678, sc-24679 | 3 | Backlog |
| [sc-24681](https://app.shortcut.com/trefry/story/24681) | feature | Generate recoverable new images and save them into catalog folders | sc-24659, sc-24674, sc-24680 | 3 | Backlog |
| [sc-24682](https://app.shortcut.com/trefry/story/24682) | feature | Edit prompts, replace objects and generate masked fill or expansion | sc-24667, sc-24668, sc-24680 | 3 | Backlog |
| [sc-24683](https://app.shortcut.com/trefry/story/24683) | feature | Select subjects and remove backgrounds with contextual editable masks | sc-24668, sc-24680 | 3 | Backlog |
| [sc-24684](https://app.shortcut.com/trefry/story/24684) | feature | Denoise, restore and upscale photos through validated AI routes | sc-24667, sc-24680 | 3 | Backlog |
| [sc-24685](https://app.shortcut.com/trefry/story/24685) | feature | Review AI caption and keyword suggestions before metadata application | sc-24660, sc-24680 | 3 | Backlog |
| [sc-24686](https://app.shortcut.com/trefry/story/24686) | feature | Search the catalog semantically using rebuildable image and text indexes | sc-24659, sc-24678, sc-24679 | 3 | Backlog |
| [sc-24687](https://app.shortcut.com/trefry/story/24687) | feature | Run and resume AI jobs on catalog selections | sc-24657, sc-24681, sc-24682, sc-24683, sc-24684, sc-24685 | 3 | Backlog |
| [sc-24688](https://app.shortcut.com/trefry/story/24688) | chore | Coordinate interactive rendering, exports and AI within resource budgets | sc-24657, sc-24664, sc-24678, sc-24694 | 3 | Backlog |
| [sc-24689](https://app.shortcut.com/trefry/story/24689) | feature | Complete native keyboard, accessibility and panel behavior | sc-24657, sc-24659, sc-24680 | 3 | Backlog |
| [sc-24690](https://app.shortcut.com/trefry/story/24690) | chore | Package the native application and implement approved distribution updates | sc-24656, sc-24657, sc-24678 | 3 | Backlog |
| [sc-24691](https://app.shortcut.com/trefry/story/24691) | chore | Verify the integrated native LensWorks product and reconcile epic completion | sc-24661, sc-24662, sc-24666, sc-24669, sc-24670, sc-24671, sc-24675, sc-24676, sc-24677, sc-24686, sc-24687, sc-24688, sc-24689, sc-24690 | 3 | Backlog |
| [sc-24694](https://app.shortcut.com/trefry/story/24694) | chore | Measure native responsiveness and approve final acceptance limits | sc-24659, sc-24669, sc-24678 | 3 | Backlog |

S37 / sc-24694 measures the real native prototype and obtains final-limit approval before S33 resource validation. S36 / sc-24691 is the sole terminal readiness story; its dependencies transitively cover all other stories. The graph is acyclic. Neither the performance goals nor the 16 GB target are validated support claims.

Full local acceptance criteria and validation methods live on each linked story. The [epic mirror](SHORTCUT_PLAN.md) holds the confirmed cross-cutting requirements; the [ledger](SHORTCUT_LEDGER.json) records the verified identities and dependency directions.
