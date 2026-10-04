# S03 acceptance coverage snapshot

Snapshot: 2026-10-04T15:33:56.259154+00:00. Confidence: high for exact source/log/hash observations; final S03 closeout remains with the coordinator after its final reviews. Branch `codex/sc-24658-managed-catalog`, base HEAD `cc809575c196ba4a31de4eedc6455c648017cf2e`; implementation is in the working tree. Frozen PhotoCatalog `f4f8d3f12acc77fe5632720702c52a7cfefb5b58` and Compositor `11d8d7a50992b24fd9a760a1c13b1c01b70aaf30` remain unchanged.

This is evidence reconciliation, not a completion decision. All 17 profiles in `CATALOG_SERVICE_COVERAGE.json` retain `planned_unrun`: the original complete recipes have not each been executed verbatim. The independent execution mapping below records only assertions actually observed in passing tests. Source/wire coverage establishes every route's transport representation; it does not turn 1109 specimens into successful operational invocations.

## Current executed checkpoints

- Rust adapter: **30 passed /0 failed /0 ignored** (16 library, 3 retained CLI, 10 managed integration, 1 standalone source-wire test);357 complete Request and752 standalone assertions passed. Exact log SHA256 `0d66a8c1cc0635c64e8671cd5eb7755d953f1424e94162c421950e8858212b6a`.
- Frozen semantic backend: **34 passed /0 failed /0 ignored** (12 exact selected fixtures,all 6 preview_settings,all 16 application_bridge). Successful per-command records in `.build/rust-catalog-retained-final-profile.json`; raw log SHA256 `c12614e06ad52306d556e95179cd87a40bd256b5943eca60fd621b2043cf2faa`.
- Final combined native checkpoint: **41 top-level tests in 5 suites passed** (13 managed,2 parameterized wire,26 persistence), including357 complete Request +752 standalone cases. Exact log `.build/native-s03-final-all-tests.log` SHA256 `ccfd90177f1d60e0ca4c4c43c0ec24267358680e1eda8ee2c98abd3cb5afada7`; xcresult `.build/xcode/Logs/Test/Test-Compositor-2026.10.04_11-28-56--0400.xcresult`;15.438s total. Positive conflicting-sidecar Candidates/Resolve/stale CAS, Search/History/Undo/Redo, actual Float32 Recover/Run/published Plan/Restore, full ownership/callback/cancel/stopped-worker teardown and persistence assertions all passed together. Historical15/2-suite checkpoint SHA `3b0bc2a1a7c8640c9c3383d56edb62d70c6eb66e3c44896c884db7d6e46ad845` and14/2 checkpoint SHA `d06f18d430f1875cf0380d174dcaaed85114b68bfbba78c3473b40b31aad588f` remain earlier evidence.
- Persistence checkpoint: **26 tests in 3 suites passed**; SHA256 `9bdc6960ba4b7913481b27b87e2d9b8fcd0cc51c9bdf162d84558475b2ac7393`; xcresult `.build/xcode/Logs/Test/Test-Compositor-2026.10.04_10-23-07--0400.xcresult`. Includes first/repeated-save initial UUID, real catalog layers/source across reopen, SaveAs isolation, corruption/unsafe destination refusal and independent workspace undo identities.
- Installed streaming/DTO predecessor: `.build/acceptance-s03-streaming-dto-final/result.json` is `PASS_INSTALLED_RASTER_TWO_PROCESS_RESTART`, SHA256 `16e1b9685e5980ae7d3e6f15ebe49720c0b92c103e02d9e116a0b91972fed86b`. Original hash before/after `51496f200d92eb6e85601d5536ad3ec6cffaa94b344988e49162938bfb1db707`; document/photo/version/layer IDs, name Persisted Layer,opacity0.6,assetCount1 survive separate installed processes. This result predates the final Float32 wrapper adjustment.
- Final separate production build `.build/native-s03-production-build.log` passed using `.build/xcode-app`, distinct from the test derived-data directory. Final `.build/installed-s03-production-final/LensWorks.app` contains no XCTest/Testing injection payloads. Its closure has21 unique Mach-O entries; all binary hashes and19 installed notice hashes independently equal disk. Both retained helper payloads and the tested Rust archive remain unchanged.
- Historical production result `.build/acceptance-s03-production-final/result.json` succeeded after74.988s first launch/1.498s reopen, but a UI query near74s may have admitted/reopened its window. It is retained and **not credited as an isolated initial-launch pass**. Prior direct120s timeout and failed explicit `.presented` control are also preserved. Diagnostic trace later observed didFinish with0 windows and a manual reopen~112s later immediately admitting the editor. The explicit `.presented` experiment was reverted; the final fix defers a visible-editor check after didFinish and reuses existing Self.reopen only when no visible editor exists.
- Final independent no-UI installed journeys now both pass: normal LaunchServices `.build/acceptance-s03-launch-reopen-final/result.json` (first2.769s/reopen1.498s), and direct launch confirmation `.build/acceptance-s03-launch-reopen-confirmation/result.json` (first2.612s/reopen1.501s). Each is `PASS_INSTALLED_RASTER_TWO_PROCESS_RESTART`, with original SHA before/after `51496f200d92eb6e85601d5536ad3ec6cffaa94b344988e49162938bfb1db707`, initially created document/photo/version/layer/project identity retained, one asset, Persisted Layer/opacity0.6 retained, launcher exit0/error null and independently verified recorded application/launcher/helper owners absent afterward. Each fresh installed closure has21 exact matching Mach-O hashes,19 exact notice hashes and no test-injection framework payload.
- Root manually verified the exact confirmation application singleton window, real catalog/filmstrip/canvas/Persisted Layer60%, saved `native-window.jpeg` plus accessibility evidence under the confirmation acceptance directory, and normal Command-Q. This UI evidence is parent-supplied; this reviewer independently verified files/logs/process retirement. Startup-window behavior is qualified by the controlled final journeys; these timings are fixture observations, not a product performance guarantee.

Rust command (cwd `/Users/michael/Repos/LensWorks`):

```sh
MACOSX_DEPLOYMENT_TARGET=26.2 CARGO_BUILD_JOBS=4 CARGO_TARGET_DIR=/Users/michael/Repos/LensWorks/.build/rust-catalog PHOTOCATALOG_DNG_SDK=/Users/michael/Repos/LensWorks/.build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1 cargo test --manifest-path adapters/catalog/Cargo.toml --locked --release -- --test-threads=1
```

Frozen semantic runner: `python3 adapters/catalog/tests/run_retained_services.py`. It compiles the exact pinned library test binary, sets `PHOTOCATALOG_TEST_EXECUTABLE` to the freshly built retained CLI, invokes selected cases with `--exact --include-ignored --test-threads=1 --nocapture`, and runs all application_bridge tests. Strict nonzero passed/zero ignored assertions reject empty filters and ignored tests. Per-command environment/results are retained in the final profile JSON.

Swift managed/wire command:

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project native/Compositor.xcodeproj -scheme Compositor -destination platform=macOS,arch=arm64 -derivedDataPath .build/xcode -parallel-testing-enabled NO -jobs 4 -only-testing:CompositorTests/LensWorksManagedCatalogTests -only-testing:CompositorTests/LensWorksCatalogWireTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 90 CODE_SIGN_IDENTITY=- test-without-building
```

Persistence command uses the same flags with `-only-testing:CompositorTests/LensWorksCatalogTests -only-testing:CompositorTests/ProjectTests -only-testing:CompositorTests/ProjectWorkspaceTests`. Both completed logs end `TEST EXECUTE SUCCEEDED`; XCTest's preliminary zero-count line does not replace the actual Swift Testing totals.

## Historical failed attempts retained

The24-pass Rust checkpoint at SHA `9dc9a310490ebd2d68ea480920247907ba61b1b34848ef3cd19db3c01805b27e` predates ownership/shutdown repairs. The first positive Float32 export attempt failed Plan.item.state (`failed`, expected `published`) before pixel/Restore assertions; its cleanup timed out with Draining and unknown outcomes. A complete Run operation can contain failed items. Corrected26/28 checkpoints and the current30-pass suite supersede that failed qualification, without counting it as successful publication.

Initial ignored migration and wrong-namespace zero-match retained test attempts were rejected by strict runner assertions and excluded from34. Preserved ignored log: `.build/rust-catalog-retained-tests-initial-ignored.log`; final-profile JSON explicitly excludes the empty-filter attempt.

Native historical failures included Collection result handling, `/var` canonical-path identity, overlapping SQLite capture directories, integral typed float/null/tuple specimen expectations and the wrong metadata Field binding. The historical978/621 corpus used empty containers and cannot qualify corrected populated results. New public-reexport Rust fixture compilation and f32 canonicalization failures are preserved at `.build/rust-catalog-populated-wire-public-alias-compile.log` and `.build/rust-catalog-populated-wire-f32-canonicalization.log`. The initial expanded Swift corpus failed11 exact f32 crop comparisons and a migration destination/catalog-token guard; `.build/native-s03-populated-f32-migration-failures.log` preserves that attempt. No tolerance was introduced: `LWCatalogFloat32.encode` emits `Double(value)` to match exact widened IEEEbinary32; prospective migration closes the old catalog before admitting its nil-token destination. Historical 14-test checkpoint passes both repairs.

The known retained organization-then-XMP empty-candidate conflict is controlled rejection, independently reproduced by M-conflict and tracked by parent under S05/sc-24660. This record does not turn it into successful combined publication or modify frozen source.

## Source-derived surface and exact codec qualification

Corrected counts: **248 reachable types,609 enum variants,171 public application commands,357 Request/input specimens,752 standalone specimens (609 enum +143 nongeneric serialized structs),1109 total wire cases,1119 mapped inventory rows**. `lightroom::plan::Cell` is an explicit public Workbench Rows result projection root, not a new command.

Actual nonempty Metadata.Fields exposed function-local migration_source::Field imports contaminating module imports and overriding local application::metadata::Field. The resolver now reads depth0 imports, prioritizes locals, guards qualified reexport cycles and rejects ambiguous wildcard candidates. Comparing all old/new reachable bindings found only Response.Fields changed; removed migration_source Field/Collection/ByteRef were accidental graph reachability, not omitted capabilities. Populated options/vectors/generic Page rows/cursors cover container-hidden DTOs. f32 specimens round to actual IEEEbinary32 before JSON widening; exact float token kinds remain intact.

Fresh read-only `python3 scripts/audit-catalog-service-coverage.py --check-swift` and `--self-test-source-resolution` pass. Negatives verify function/impl/child imports, local shadowing, module aliases, wildcard ambiguity, reexport cycles, wrong graph and wrong Swift generic payload bindings; populated metadata Page<Field>/organization Page<T,C> and f32 precision are asserted. Actual Rust and Swift 752-case runs now pass. The source audit still truthfully leaves 17 planned profiles unrun; it does not execute lifecycle fixtures.

## Observed machine execution mapping

This JSON is an evidence index, not a replacement acceptance ledger. Each original profile remains planned. `observed_swift_*` lists unconditional passing assertions or real terminal observables from the final 41-test checkpoint; conditional loop bodies are not silently credited. Independent backend tests are separate proof, never relabeled as Swift invocations. The suffixes M/R/B are resolved in the exact-name index below.

```json
{
  "schema_version": 1,
  "baseline": "f4f8d3f12acc77fe5632720702c52a7cfefb5b58",
  "swift_checkpoint_sha256": "ccfd90177f1d60e0ca4c4c43c0ec24267358680e1eda8ee2c98abd3cb5afada7",
  "profiles": [
    {
      "profile_id": "metadata-resolution",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Metadata.Identity",
        "Metadata.Fields(nonempty)",
        "Metadata.Fields(stale identity rejected)",
        "Metadata.Candidates(real rating conflict)",
        "Metadata.Resolve",
        "MetadataWrite.Resolve"
      ],
      "observed_swift_observables": [
        "metadata revision advances after real XMP commit",
        "local metadata Field struct decodes with nonempty rows",
        "two real discovered sidecar ratings2/4 produce conflict and at least 2 distinct candidate models",
        "chosen model selected/conflicted=false",
        "resolved revision advances"
      ],
      "observed_swift_faults": [
        "stale metadata identity fails",
        "stale direct Resolve rejected"
      ],
      "independent_backend_evidence": [
        "R-metadata1",
        "R-metadata2",
        "M-family"
      ],
      "unqualified_facets": [
        "Every paged source/model/decision/packet/chunk option is not individually exercised through Swift; selected retained metadata semantics pass independently."
      ]
    },
    {
      "profile_id": "metadata-write-recovery",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "InputBegin",
        "InputAppend",
        "InputFinish",
        "Prepare",
        "Review",
        "Commit",
        "SidecarPlan",
        "SidecarApply"
      ],
      "observed_swift_observables": [
        "exact sealed rating3 bytes and BLAKE3 digest",
        "review changed_fields=1/edits=1 and exact token/digest",
        "Published sidecar receipt version2 and actual Rating token",
        "source bytes unchanged"
      ],
      "observed_swift_faults": [
        "stale Fields identity rejected"
      ],
      "independent_backend_evidence": [
        "M-family",
        "M-conflict",
        "R-files"
      ],
      "unqualified_facets": [
        "Interrupted-publication restart and every recovery-page/chunk facet are not claimed by the Swift happy lifecycle."
      ]
    },
    {
      "profile_id": "organization-revisions",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "CreateCollection",
        "Collection",
        "collection membership readback"
      ],
      "observed_swift_observables": [
        "created exact collection ID/name and one membership",
        "original bytes unchanged"
      ],
      "observed_swift_faults": [],
      "independent_backend_evidence": [
        "M-family",
        "R-org1",
        "R-org2",
        "B-organization"
      ],
      "unqualified_facets": [
        "Two-target planned batch and all edit facets are not individually qualified through Swift."
      ]
    },
    {
      "profile_id": "relink-review-identity",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Begin",
        "Prepare",
        "Plan",
        "Items",
        "Apply",
        "Original",
        "Undo",
        "Original"
      ],
      "observed_swift_observables": [
        "ready matching-byte candidate",
        "physical NativePath changes to candidate and restores original",
        "both original copies retain exact bytes"
      ],
      "observed_swift_faults": [],
      "independent_backend_evidence": [
        "R-relink",
        "B-relink"
      ],
      "unqualified_facets": [
        "Backend Confirm/cancellation/close semantics pass separately; not every review fault is a Swift invocation."
      ]
    },
    {
      "profile_id": "adjustment-transfer",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "CreateVariant",
        "SaveRecipe",
        "Begin(Exposure)",
        "Append",
        "Seal",
        "Run",
        "Status",
        "Variant"
      ],
      "observed_swift_observables": [
        "target exposure1.0 and new revision",
        "contrast/saturation preserved"
      ],
      "observed_swift_faults": [
        "stale SaveRecipe rejected"
      ],
      "independent_backend_evidence": [
        "M-family",
        "R-copy1",
        "R-copy2"
      ],
      "unqualified_facets": [
        "All selected-group/CAS/cancel/resume semantics are retained backend evidence, not every group executed in Swift."
      ]
    },
    {
      "profile_id": "preview-policy-relocation",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "SetBudgets",
        "BeginOriginalRootReview",
        "BeginRelocation(Thumbnail)",
        "Status"
      ],
      "observed_swift_observables": [
        "64MiB/256MiB exact budgets",
        "ready reviewed original roots",
        "terminal relocation/new thumbnail root"
      ],
      "observed_swift_faults": [
        "destination within original root rejected without creating directory"
      ],
      "independent_backend_evidence": [
        "R-preview1",
        "R-preview2",
        "R-preview3",
        "R-preview4",
        "R-preview5",
        "R-preview6",
        "B-cache"
      ],
      "unqualified_facets": [
        "Bounded step loops may have zero iterations; record terminal observables rather than an invented move count. Backend restart/stale/batch facets are separate."
      ]
    },
    {
      "profile_id": "guarded-migration",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Close(old catalog)",
        "Begin(PrepareSupplements)",
        "Upload(nonempty exact UTF8)",
        "Finish",
        "Act",
        "Status",
        "ResultPage",
        "Discard"
      ],
      "observed_swift_observables": [
        "guard operation and Uploading phase",
        "exact sealed byte count/digest",
        "terminal operation and result-page bytes/digest",
        "Prepared.Pin matches source/capture authority"
      ],
      "observed_swift_faults": [
        "stale generation Guard rejected"
      ],
      "independent_backend_evidence": [
        "R-migration1",
        "R-migration2"
      ],
      "unqualified_facets": [
        "One successful PrepareSupplements does not establish every Run/Repair action through Swift; actual retained Run and remaining routes passed independently."
      ]
    },
    {
      "profile_id": "workbench-input-review",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Lightroom.Open",
        "Options",
        "Capture",
        "CaptureManifest",
        "AddCapture",
        "Resume",
        "Rows",
        "Close"
      ],
      "observed_swift_observables": [
        "real closed SQLite capture/manifest authority",
        "registered capture reconciles rows",
        "Integer1 and exact nonUTF8 Text/Blob00ff80",
        "SQLite/image originals unchanged"
      ],
      "observed_swift_faults": [],
      "independent_backend_evidence": [
        "R-workbench"
      ],
      "unqualified_facets": [
        "All Query/Action/upload possibilities remain source/wire surface, not successful operations inferred from this fixture."
      ]
    },
    {
      "profile_id": "export-staging-recovery",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Export.Begin",
        "Append(Float32 TIFF LinearSrgb PreserveAlpha)",
        "Seal",
        "sourceIdentity",
        "SaveRecipe(exposure1)",
        "Export.Recover",
        "Export.Run",
        "Export.Plan",
        "Export.Restore"
      ],
      "observed_swift_observables": [
        "sealed source plan retains exact NativePath/fingerprint",
        "no output published by raw decode",
        "explicit Append budgets1MiB agree with Run execution1MiB staging limits",
        "Run complete processed1 and Plan.item.state=published",
        "Plan edit identity/revision/recipe digest and authority unchanged",
        "actual derivative bytes nonempty/distinct from original",
        "typed publication and Restore receipts state=published/exact destination/authority",
        "original image bytes/mtime unchanged before explicit stale-source mutation"
      ],
      "observed_swift_faults": [
        "stale source refuses decode"
      ],
      "independent_backend_evidence": [
        "M-core",
        "B-export"
      ],
      "unqualified_facets": [
        "Swift proves recipe-bound publication/receipts and raw original HDR samples; published RGBx2/alpha-unchanged pixel assertions are independent Rust M-core evidence. No live RAW editor acceptance is inferred."
      ]
    },
    {
      "profile_id": "catalog-open-close",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Session.create",
        "Create",
        "Status",
        "Close",
        "Session.close",
        "subscription.drain",
        "Job.wait",
        "owned buffer decode after session close"
      ],
      "observed_swift_observables": [
        "controlled finite Draining while actual worker is stopped",
        "retry Closed and checked child retirement",
        "owned result survives session closure"
      ],
      "observed_swift_faults": [
        "invalid/stale handles",
        "invalid buffer/double take",
        "callback drain timeout/reentrant Busy",
        "Rust worker failure",
        "cancellation independent of blocked receive"
      ],
      "independent_backend_evidence": [
        "M-lifecycle",
        "M-ownership",
        "M-startup",
        "M-unwind",
        "M-stopped-worker",
        "M-bounded-shutdown"
      ],
      "unqualified_facets": [
        "Final combined native ownership/lifecycle and two independent no-UI installed initial-launch/restart/owner-retirement assertions passed. Original broader planned recipe remains unrun verbatim; no product performance guarantee is inferred."
      ],
      "observed_installed_actions": [
        "independent no-UI normal LaunchServices create/import/create-version/edit/save/quit and separate reopen/quit",
        "independent no-UI direct launch confirmation of the same journey"
      ],
      "observed_installed_observables": [
        "one catalog asset",
        "original SHA256 unchanged",
        "initial document/photo/version/layer/project identity retained",
        "Persisted Layer opacity0.6 retained",
        "recorded application/launcher/helper owners absent after checked completion"
      ]
    },
    {
      "profile_id": "import-resume",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Create",
        "ImportStart",
        "ImportStatus",
        "Images"
      ],
      "observed_swift_observables": [
        "actual imported catalog row/VariantKey",
        "source bytes unchanged"
      ],
      "observed_swift_faults": [],
      "independent_backend_evidence": [
        "M-core",
        "B-import",
        "B-import-bad",
        "B-source-change"
      ],
      "unqualified_facets": [
        "ImportCancel/ImportResume/held jobs and restart fault coverage is retained semantic evidence; not all are direct Swift calls."
      ],
      "observed_installed_actions": [
        "independent no-UI normal LaunchServices create/import/create-version/edit/save/quit and separate reopen/quit",
        "independent no-UI direct launch confirmation of the same journey"
      ],
      "observed_installed_observables": [
        "one catalog asset",
        "original SHA256 unchanged",
        "initial document/photo/version/layer/project identity retained",
        "Persisted Layer opacity0.6 retained",
        "recorded application/launcher/helper owners absent after checked completion"
      ]
    },
    {
      "profile_id": "backup-restore-held-jobs",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "BackupCreate",
        "BackupStatus",
        "BackupInspect",
        "BackupRestore",
        "OpenExisting(restored)",
        "RestoreStatus",
        "ResumeRestoredJobs",
        "Images"
      ],
      "observed_swift_observables": [
        "matching operation receipts",
        "restored jobsHeld before explicit resume",
        "one preserved asset/key and original unchanged"
      ],
      "observed_swift_faults": [],
      "independent_backend_evidence": [
        "M-family",
        "R-backup",
        "B-backup",
        "B-import-bad",
        "B-held-preview"
      ],
      "unqualified_facets": [
        "No claim that external source image bytes are included in catalog backup."
      ]
    },
    {
      "profile_id": "browse-edit-history",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Images",
        "Variant",
        "SaveRecipe",
        "collection membership",
        "Search(actual filename)",
        "History",
        "Undo",
        "Redo"
      ],
      "observed_swift_observables": [
        "bounded actual row/key",
        "edit revision advances and stale SaveRecipe rejected",
        "working-version initial UUID/repeated saves/reopen persistence",
        "Search complete/no-more contains actual imported asset",
        "Undo0EV/Redo1EV and each revision advances",
        "History contains at least3 entries including current revision"
      ],
      "observed_swift_faults": [
        "stale SaveRecipe rejected",
        "stale Undo revision rejected"
      ],
      "independent_backend_evidence": [
        "B-pages",
        "B-cursors",
        "B-search",
        "B-organization"
      ],
      "unqualified_facets": [
        "No complete operational filter/cursor/Cull matrix is claimed; preserved public routes have source/wire coverage and selected backend semantics."
      ],
      "observed_installed_actions": [
        "independent no-UI normal LaunchServices create/import/create-version/edit/save/quit and separate reopen/quit",
        "independent no-UI direct launch confirmation of the same journey"
      ],
      "observed_installed_observables": [
        "one catalog asset",
        "original SHA256 unchanged",
        "initial document/photo/version/layer/project identity retained",
        "Persisted Layer opacity0.6 retained",
        "recorded application/launcher/helper owners absent after checked completion"
      ]
    },
    {
      "profile_id": "preview-generation-bytes",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "Preview(Thumbnail)",
        "PreviewStatus",
        "managed preview bytes",
        "ReleaseViewport"
      ],
      "observed_swift_observables": [
        "Ready ticket",
        "owned encoded bytes nonempty with JPEG/WebP/AVIF MIME",
        "buffer released/job closed"
      ],
      "observed_swift_faults": [],
      "independent_backend_evidence": [
        "M-family",
        "B-pages",
        "B-close",
        "B-hydration",
        "B-held-preview",
        "B-translated-hydration"
      ],
      "unqualified_facets": [
        "Pending source hydration/stale viewport/offline semantics have independent retained coverage; preview bytes are not editor float authority."
      ]
    },
    {
      "profile_id": "source-identity",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "sourceIdentity",
        "decodeFull"
      ],
      "observed_swift_observables": [
        "exact original path and pinned source_revision/protocol2",
        "source fingerprint authority bound to sealed plan"
      ],
      "observed_swift_faults": [
        "changed source refused"
      ],
      "independent_backend_evidence": [
        "M-core",
        "B-pages",
        "B-hydration",
        "B-relink"
      ],
      "unqualified_facets": [
        "Core with_edit_identity stale callback nonexecution is not separately asserted."
      ]
    },
    {
      "profile_id": "full-float-original",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "decodeFull",
        "floatSamples",
        "owned result release",
        "SaveRecipe(exposure1)",
        "Export.Recover",
        "Export.Run",
        "Export.Plan",
        "Export.Restore"
      ],
      "observed_swift_observables": [
        "2x2 width/height,row_stride32,straight alpha,applied orientation",
        "negative/high RGB and alpha0.5",
        "no derivative before explicit export and source unchanged",
        "explicit Append budgets1MiB agree with Run execution1MiB staging limits",
        "Run complete processed1 and Plan.item.state=published",
        "Plan edit identity/revision/recipe digest and authority unchanged",
        "actual derivative bytes nonempty/distinct from original",
        "typed publication and Restore receipts state=published/exact destination/authority",
        "original image bytes/mtime unchanged before explicit stale-source mutation"
      ],
      "observed_swift_faults": [
        "stale source decode rejected with no rewrite"
      ],
      "independent_backend_evidence": [
        "M-core"
      ],
      "unqualified_facets": [
        "Swift proves recipe-bound publication/receipts and raw original HDR samples; published RGBx2/alpha-unchanged pixel assertions are independent Rust M-core evidence. No live RAW editor acceptance is inferred."
      ]
    },
    {
      "profile_id": "wire-conformance",
      "planned_profile_status": "planned_unrun",
      "execution_status": "observed_partial_profile_coverage",
      "swift_checkpoint": ".build/native-s03-final-all-tests.log",
      "observed_swift_actions": [
        "357 typed Request decode/reencode",
        "752 standalone typed enum/struct decode/reencode",
        "authority integer/native-path checks",
        "fixedF32 exact widened JSON test"
      ],
      "observed_swift_observables": [
        "1109 exact JSON specimens pass",
        "609 enum plus143 populated struct specimens",
        "correct local nonempty metadata Field binding",
        "float token kind/IEEE binary32 widened value preserved"
      ],
      "observed_swift_faults": [
        "source resolver rejects wrong graph/Swift binding,ambiguous wildcard/reexport cycle",
        "authority invalid/trailing token/overflow/path validation"
      ],
      "independent_backend_evidence": [
        "M-wire",
        "R-wire"
      ],
      "unqualified_facets": [
        "Wire placeholders establish parsing/representation, never a successful service invocation."
      ]
    }
  ],
  "swift_checkpoint_top_level_tests": 41,
  "swift_checkpoint_wire_cases": 1109,
  "installed_checkpoint": {
    "result": ".build/acceptance-s03-launch-reopen-final/result.json",
    "sha256": "eef5d6a21b46b1b2b27bfc285188625e28b7f9d737a7304934e386e92248d070",
    "mode": "launch-services",
    "no_ui_tools_during_journey": true,
    "first_elapsed_seconds": 2.7693961249897256,
    "reopened_elapsed_seconds": 1.497650459059514,
    "original_sha256": "51496f200d92eb6e85601d5536ad3ec6cffaa94b344988e49162938bfb1db707",
    "owned_processes_independent_current_readback": "none remain",
    "isolated_first_launch_status": "passed",
    "confirmation": {
      "result": ".build/acceptance-s03-launch-reopen-confirmation/result.json",
      "sha256": "10d8329d5c625558aaa385519778a3e108816ad7bea0ff430f24cc076058abd3",
      "mode": "direct",
      "no_ui_tools_during_journey": true,
      "first_elapsed_seconds": 2.6118613750441,
      "reopened_elapsed_seconds": 1.5011759999906644
    },
    "limit": "timings are fixture observations, not a product performance guarantee; prior intervened pass is not credited"
  },
  "swift_checkpoint_suites": 5,
  "swift_checkpoint_managed_tests": 13,
  "swift_checkpoint_persistence_tests": 26
}
```

## Local acceptance disposition

Live AC requires typed Swift service families, controlled ownership/errors/cancellation/teardown, and the pinned source/version/transaction/original-fingerprint contract. The combined 41-test runtime passes all required direct Swift gates: real Metadata.Candidates/Resolve/stale CAS; Search/History/Undo/Redo/current-revision readback; Float32 recipe-bound Recover/Run/published Plan/exact Restore receipts; callback/cancel/error/buffer/session teardown; and26 persistence tests. Explicit1MiB Append budgets agree with Run staging; the prior default2GiB/Run1MiB mismatch failure is preserved at `.build/native-s03-export-staging-budget-failure.log` and is not credited as positive export proof.

The isolated installed first-launch gate is now qualified by two independent fresh no-UI journeys, one normal LaunchServices and one direct confirmation, each with separate reopen, source hash/initial UUID/layer preservation and actual recorded worker retirement. Controlled trace shows the former missing initial window and the final deferred no-visible-editor fallback; failed `.presented`, prior120s controls and the intervened74.988s pass remain preserved. The exact final confirmation app singleton UI and normal Quit passed parent inspection. No startup performance guarantee or broader live-RAW/product acceptance is inferred.

No remaining required S03 service-family or integrated local acceptance blocker is established by this review. The final native author's eight CPU-only trace-file probes passed; root read back `.build/startup-trace-probe/results.json` and its exact source SHA `d8695013f06c7dfb7f79fbbfde45e1f821c3f2501becfd6d19110878d81aadae`. Fresh 128-event/UTF-8 caps and mode0600 passed; repeated process and existing regular/symlink/hardlink/redirected-parent paths preserved original bytes, timestamps and membership; FIFO refusal stayed finite and disabled tracing created no files. Final source review is clear. Commit, exact-head publication/merge and tracker readback remain coordinator-owned. Full 171-command/1119-row source transport coverage is preserved; it is not recast as 1119 successful operations. Each public top-level service family has real typed Swift input/result exercises with legal completion or controlled fault and corresponding unchanged backend semantic proof. The original 17 full recipes remain planned_unrun because broader individual filters/cursors/chunks/alternate cancellation/restart/operation assertions have not all been run verbatim. Their unqualified facets remain visible rather than silently waived or turned into downstream editor/live-RAW/device/notarization requirements. Parent owns final reviews, commit and tracker acceptance.

## LensWorks-owned ABI seams and ownership proof

Scalar `lw_catalog_blake3` is a LensWorks C seam, not a frozen PhotoCatalog Request. It accepts synchronous readable bytes up to 4MiB (NULL only with length 0) and writable 32-byte output, retains no caller pointer and creates no handle. Invalid/oversize/panic statuses leave output untouched. Its actual known-vector/argument-limit Rust fixture passes, and real Swift metadata/migration proofs seal the exact encoded bytes with it off the UI thread.

Streaming digest create/update/finalize/release is separately owned: at most 16 live owners, update up to 4MiB, finalize once, retained allowance during concurrent release, stale/wrong-kind handle refusal and explicit canceled lease cleanup. Passing Rust `managed_streaming_blake3_large_input_final_once_and_handle_faults` / `managed_streaming_blake3_owner_allowance_survives_release_during_call` and Swift `retainedBlake3SealsExactBytesAndBoundsAdmission` establish these specific boundaries. No new171-command entry or invented request count is derived from these utilities.

Actual paused SessionCreate unpublished-authority rejection, response/payload/receiver saturation, concurrent job/callback publication fencing and finite checked shutdown hold ownership until workers/callbacks really drain. Real SIGSTOP fixture demonstrates finite Draining responses, independent cancellation/status, surviving owned payload, retry and checked reap. Callback drain timeout retains context; reentrant drain is Busy. Errors do not unwind into Swift or falsely advertise Closed while a child is retained.

## Exact test-name index


Managed C ABI tests (M prefix), recorded in adapter suite:

- M-lifecycle: `managed_actual_worker_lifecycle_and_service_errors`.
- M-ownership: `managed_handles_buffers_callbacks_and_cancellation`.
- M-startup: `managed_retained_worker_failure_and_shutdown`.
- M-unwind: `managed_fixture_assertion_unwind_checks_shutdown_and_reaps_owned_worker`.
- M-stopped-worker: `managed_stopped_real_worker_shutdown_is_finite_and_retryable`.
- M-bounded-shutdown: `managed::tests::managed_blocked_checked_shutdown_retains_owner_and_keeps_polling_finite`.
- M-core: `managed_source_plan_float_and_original_preservation` (final positive float publication/Restore/pixel/source-preservation assertions pass; historical failed attempt remains above).
- M-family: `managed_organization_metadata_write_copy_preview_backup_restore_lifecycles`.
- M-conflict: `managed_retained_organization_xmp_conflict_rejects_sidecar_without_source_effects`.
- M-wire: `managed_all_source_wire_variants_preserve_exact_typed_authority`.
- R-wire: `all_source_standalone_wire_variants_decode_and_reencode`.

Selected frozen backend tests (R prefix), recorded in retained suite:

- R-org1: `application::organization::tests::hierarchy_collection_cas_membership_and_synonyms_preserve_evidence`.
- R-org2: `application::organization::tests::variant_batch_is_durable_single_unit_cancelable_and_never_becomes_master`.
- R-relink: `application::relink::tests::atomic_relink_status_write_hold_cancel_commit_wins_and_close_undo`.
- R-copy1: `application::copy::tests::all_groups_are_frozen_and_preserve_other_target_settings`.
- R-copy2: `application::copy::tests::run_foreground_holds_cas_cancel_and_explicit_resume`.
- R-backup: `application::backup::tests::backup_inspect_restore_keep_receipts_and_hold`.
- R-migration1: `application::desktop::migration::tests::actual::lm_facade_actual_managed_run_status_preserve_raw_rows_and_reap_all_roles`.
- R-migration2: `application::desktop::migration::tests::actual::lm_facade_actual_remaining_five_routes_preserve_repairs_and_status`.
- R-workbench: `application::desktop::workbench_capability_tests::managed_dispatcher_preserves_sealed_artifact_and_approval_capabilities`.
- R-files: `filesystem_worker::metadata_files::tests::filesystem_owner_plans_applies_and_restores_without_losing_original`.

- R-metadata1: `application::metadata::tests::selected_copy_resolution_cas_and_opaque_provenance_preserve_originals`.
- R-metadata2: `application::metadata::tests::exact_utf16_packet_chunks_ownership_checksum_and_cancel`.
- R-preview1: `application::preview_settings::tests::budgets_survive_reopen_without_rounding_and_invalid_update_is_atomic`.
- R-preview2: `application::preview_settings::tests::completed_root_review_survives_catalog_and_manifest_reopen`.
- R-preview3: `application::preview_settings::tests::move_reopens_paused_and_rejects_occupied_destination`.
- R-preview4: `application::preview_settings::tests::oversized_move_batch_is_rejected_without_creating_a_move`.
- R-preview5: `application::preview_settings::tests::relocation_requires_reviewed_roots_and_rejects_a_sibling_inside_them`.
- R-preview6: `application::preview_settings::tests::root_review_is_bounded_and_storage_changes_make_it_stale`.

All 16 `vendor/PhotoCatalog/tests/application_bridge.rs` tests were executed (B prefix references below):

- `app_cache_parent_is_namespaced_by_catalog_and_reused_on_reopen`.
- `changed_edited_original_import_fails_actionably_without_reset_or_duplicate`.
- `close_reaps_an_observed_active_native_preview_before_cache_reopen`.
- `desktop_backup_restore_uses_selected_catalog_and_explicit_job_admission`.
- `desktop_export_explicit_recovery_native_run_and_saved_authority`.
- `desktop_organization_scopes_changes_to_selected_variant_and_catalog`.
- `desktop_relink_unverified_imported_variants_confirm_hydrate_and_undo`.
- `desktop_search_filters_keep_variant_identity_and_reject_changed_query_cursor`.
- `existing_open_never_creates_and_new_catalog_is_explicit`.
- `imports_report_bad_files_and_respect_restored_job_hold`.
- `incremental_import_interleaves_edits_cancels_rewalks_and_preserves_originals`.
- `opaque_image_cursors_support_back_forward_and_reject_stale_epoch`.
- `pending_imported_variants_hydrate_on_demand_without_rewriting_recipes_or_xmp`.
- `real_actor_pages_edits_independent_variants_delivers_binary_and_reopens`.
- `restored_pending_preview_keeps_external_job_hold_and_missing_source_is_truthful`.
- `translated_import_recipes_hydrate_without_losing_import_history`.

B shorthand: pages=`real_actor_pages_edits_independent_variants_delivers_binary_and_reopens`; cursors=`opaque_image_cursors_support_back_forward_and_reject_stale_epoch`; search=`desktop_search_filters_keep_variant_identity_and_reject_changed_query_cursor`; organization=`desktop_organization_scopes_changes_to_selected_variant_and_catalog`; open=`existing_open_never_creates_and_new_catalog_is_explicit`; close=`close_reaps_an_observed_active_native_preview_before_cache_reopen`; cache=`app_cache_parent_is_namespaced_by_catalog_and_reused_on_reopen`; import=`incremental_import_interleaves_edits_cancels_rewalks_and_preserves_originals`; import-bad=`imports_report_bad_files_and_respect_restored_job_hold`; source-change=`changed_edited_original_import_fails_actionably_without_reset_or_duplicate`; backup=`desktop_backup_restore_uses_selected_catalog_and_explicit_job_admission`; export=`desktop_export_explicit_recovery_native_run_and_saved_authority`; relink=`desktop_relink_unverified_imported_variants_confirm_hydrate_and_undo`; hydration=`pending_imported_variants_hydrate_on_demand_without_rewriting_recipes_or_xmp`; held-preview=`restored_pending_preview_keeps_external_job_hold_and_missing_source_is_truthful`; translated-hydration=`translated_import_recipes_hydrate_without_losing_import_history`.


Swift final managed checkpoint exact names: `authorityIntegersAndNativePathsAreLossless`, `fixedF32SerializesItsExactWidenedValue`, `managedSourceAndProtocolMatchApprovedDependencyLedger`, `retainedBlake3SealsExactBytesAndBoundsAdmission`, `actualABIErrorsAndBufferOwnership`, `actualWorkerFamiliesCallbacksAndBufferSurvivesSession`, `actualConflictingSidecarsRequireCandidatesAndResolutionCAS`, `actualBackupRestoreTypedReceiptsAndImportedRows`, `actualWorkbenchCaptureManifestRegistrationAndRetainedRows`, `blockedCallbackDrainTimeoutKeepsContextAndReentrantDrainIsBusy`, `actualBlockedWorkerShutdownTimesOutRetainsOwnerAndRetries`, `cancellationDoesNotQueueBehindPendingWorkerReceive`, `actualFullFloatDecodeKeepsSourceAuthorityAndWideSamples`; parameterized `retainedRequestWireRoundTrips` and `retainedEnumAndResultWireRoundTrips` account for2 top-level wire tests.

## Current packaging and fingerprint snapshot

The notice payload is133 actual normal/build Rust dependency records, 17 components,19 notice files,missing[]. Both Cargo.lock and both Cargo.toml input maps match the current files exactly. No license is invented for excluded dev/other-target packages. Current installed21 unique Mach-O entries and 19 installed notice filenames/hashes independently equal disk; declared and owned native floor26.2/arm64 is retained. Dependency dylibs may declare an older floor; this is not a claim each dependency itself declares26.2. Distribution is local ad hoc development, without paid/public release or notarization acceptance.

Current Rust archive `6039053144a654053b2e63b98e110c2e3c125e46717c653002dc015cfb11f869`; owned decode helper `bd94caf1369513f4bd4164f809ec80b9fd81660ea8133a30e8c1866c4403845f`; retained CLI `be324a7dfa502ea4565f8043909a02e03d2d44ffd878db1048a516cf8620fa58`. Artifact evidence pin_clean=true; Rust own archive floor26.2 with dependency objects11.0, both helpers min 26.2.

Hashes below identify current files read. Mutable source/test changes after the checkpoint are not claimed compiled merely because their present hash is listed. Refresh final stationary source/fixtures and runtime artifacts together before closeout.

| Path | SHA256 |
| --- | --- |
| `.build/rust-catalog-managed-tests.log` | `0d66a8c1cc0635c64e8671cd5eb7755d953f1424e94162c421950e8858212b6a` |
| `.build/rust-catalog-artifact-evidence.txt` | `e08ae94307e911471ba98b5893c49fe976f48e3a34c37caf97e49161f2ff2947` |
| `.build/rust-catalog-retained-tests.log` | `c12614e06ad52306d556e95179cd87a40bd256b5943eca60fd621b2043cf2faa` |
| `.build/rust-catalog-retained-final-profile.json` | `c3d7c6fa23cd1bf151e4c652fff162c943057965b6263f875bdc8b5b8a21dd45` |
| `.build/native-s03-managed-tests.log` | `3b0bc2a1a7c8640c9c3383d56edb62d70c6eb66e3c44896c884db7d6e46ad845` |
| `.build/native-s03-persistence-tests.log` | `9bdc6960ba4b7913481b27b87e2d9b8fcd0cc51c9bdf162d84558475b2ac7393` |
| `.build/acceptance-s03-streaming-dto-final/result.json` | `16e1b9685e5980ae7d3e6f15ebe49720c0b92c103e02d9e116a0b91972fed86b` |
| `.build/installed-s03-f32-final/closure.json` | `e47ae97ea81d343b1b322d411c23d9065f571487ef66692219076a9c3fcd7fc9` |
| `.build/native-notices-s03-final/inventory.json` | `c5d86a113e3865564e17c96d2d542c400158710d737141403a33e5ffef8a4c3c` |
| `.build/native-notices-s03-final/manifest.json` | `a680cf9376aca07f793b6edbeb58519954bb1e110aa3a8a90920ddd227da980d` |
| `DEPENDENCIES.json` | `2c87a144ed1d84d0f9646ea5b953808fec98320be147ee04dc0db56531a8d532` |
| `scripts/audit-catalog-service-coverage.py` | `6ea97644ec8973cde93309ae345590b592b46362934fa7baa23139521896f1bc` |
| `docs/CATALOG_SERVICE_COVERAGE.json` | `189f2227a2bc924a792efea812737d30e1afb50940e04e05f6b5755214bb943d` |
| `adapters/catalog/include/LensWorksCatalog.h` | `aff5b4532e0d54ae82f3b63234fc44ee1ecf8b2545ff912196d23eb09a6fa4e1` |
| `adapters/catalog/src/lib.rs` | `e4521bfd64987a1a10857b76a42d4993622e10094f6f3dbf36db0eb777c32880` |
| `adapters/catalog/src/managed.rs` | `19d69c94bbb07fd37ee25883acd4f7436f466cf610d03a74bd0b98dc99b9ac17` |
| `adapters/catalog/src/full_decode.rs` | `f81caf9b510faefd0f21407fa1ea4ccfde6a2aa2b214a5214d0c624d7d81e2d8` |
| `adapters/catalog/tests/managed.rs` | `70550f8ffa662a8385182216a14d36db4d93c6cef524faeeec60509e1f9b4f3e` |
| `adapters/catalog/tests/source_wire.rs` | `fd129ab2e8f385f17b717270e2989c7248d767184dbb736f7ffa27f404b73ce2` |
| `adapters/catalog/tests/run_retained_services.py` | `7005a96850c053078ff20f40f2431e48d8d3d7009332e1f3538f33a5073dcae8` |
| `native/Compositor/LensWorks/LensWorksManagedCatalog.swift` | `9b484af6234a2b854de6b62678c751e251ff6d44c489d6d88ec56548f886142c` |
| `native/Compositor/LensWorks/LensWorksCatalogDTO.swift` | `cc1c1a925a3ca8ddd228d941f2f6ca02c0778019a152ef88b341a299aeb0af7b` |
| `native/Compositor/LensWorks/LensWorksManagedPrimitives.swift` | `85f93ae70928a757ebbb4721033b0e079905ddbec6f09c155aa9bf1335312357` |
| `native/Compositor/LensWorks/LensWorksCatalogCodec.swift` | `772a87d1c5d68a21f6acb717fb619c81d407460b34c213c3b2dfb7a4d6ece84a` |
| `native/CompositorTests/LensWorksManagedCatalogTests.swift` | `f1e2ed00414587bd06e2e6927259078f03672883a7f760b56854e852fcc76e1e` |
| `native/CompositorTests/LensWorksCatalogWireTests.swift` | `388fac27fead7126d09c53a822bf4c2f5d5d87ef970f59408baa885d21d36a1c` |
| `scripts/build-native.sh` | `b07b3eed5d003035b02b92b40a1f14c7ec421c4f564104d92a1452bc3cac516a` |
| `scripts/install-development-app.py` | `f408172862fd46e1b5e8ba59d368cb5e888f6d82414e611c73820de6ef178ed9` |
| `scripts/collect-native-notices.py` | `b38fca8668631878066b15511ccc6e2352d293b38b2cad7e61f5a23eac07d53e` |
| `scripts/verify-installed-raster.py` | `d4cd30736a6e630e465eb8a12b9d7b206588f134a0dc99e86408377b811277c7` |

| `.build/native-s03-production-build.log` | `feb74d4bae1a309c8bec3728098b5f3335f6c915729ff67170003f7516e6bf89` |
| `.build/native-s03-installed-production-final.log` | `1c9bd85f7b08058950a8bdf22a4944a2f2f1946e34d6ce34b28fd443de76b854` |
| `.build/acceptance-s03-production-final/result.json` | `0552960b61cc598d9e8fb490f3ca12544463113fcab23753f17ffe6458ad8cdc` |
| `.build/acceptance-s03-production-final/first-launch.json` | `a544c52f38adfdb2bb9987e7b7a261c8dde50693ebc54196a0d902d01be2111d` |
| `.build/acceptance-s03-production-final/reopened-launch.json` | `ee75270059934df887823df4cda4b9bbc4a939339aed76cff66db80c2f7b0e7f` |
| `.build/installed-s03-production-final/closure.json` | `6781c83135dc494ed9643df3c1f2b0504bc9c2f5c71e01ca16d635f7a2a3d130` |
| `.build/installed-s03-production-final/LensWorks.app/Contents/Resources/THIRD_PARTY_NOTICES/source-manifest.json` | `f6813fa98695e21a8e54250fc3128368dc4c07e26cfb5e9b09dfe73456a0fc6a` |
| `README.md` | `65e7667ad4126f69ec61aa5f064cf5e06eb725ab542a87fe71e38fcf71248982` |
| `.build/native-s03-final-all-tests.log` | `ccfd90177f1d60e0ca4c4c43c0ec24267358680e1eda8ee2c98abd3cb5afada7` |
| `.build/native-s03-launch-reopen-build.log` | `38bbe3e3a5e97306afd23ff16311beb92b7764c31ffa7bcff599b6fa005cdcff` |
| `.build/native-s03-final-launch-build-tests.log` | `a9d086144e251d03ab4aa11744808c2e46b315e399f97a990d7697c0f42e9765` |
| `.build/acceptance-s03-traced-startup/first.json.startup.jsonl` | `14d6ea55f7b4e441fa64c9e5cd065929418883a9378e2346d82d5e67cb209c98` |
| `.build/acceptance-s03-explicit-window-final/first-launch.json` | `30574e1ff10c9ff9a09d396a64759048852fff008387cf9df1272de51b6b5ef4` |
| `native/Compositor/IO/CompositorApplicationDelegate.swift` | `9c4b42eccc0876b0484ad555f459187ab1fa01966fc147c2ab4817ee4aef8bb3` |
| `native/Compositor/CompositorApp.swift` | `c3fb1abde70f07007309bf052870808f18d8273ab78114124b6de06182417c6c` |
| `native/Compositor/LensWorks/LensWorksLaunchTrace.swift` | `d8695013f06c7dfb7f79fbbfde45e1f821c3f2501becfd6d19110878d81aadae` |
| `.build/acceptance-s03-launch-reopen-final/result.json` | `eef5d6a21b46b1b2b27bfc285188625e28b7f9d737a7304934e386e92248d070` |
| `.build/acceptance-s03-launch-reopen-final/first-launch.json` | `d20ba1d61d2d65c0e3a573cfabfb2caf04a06b536d41ed74b494e0762e2e766e` |
| `.build/acceptance-s03-launch-reopen-final/reopened-launch.json` | `f7457c302deed9b86b899e69fa3382b92ca5a0d645aa0f91e33fa708f81d3123` |
| `.build/installed-s03-launch-reopen-final/closure.json` | `b85775d1926ae191176d67980c85cbf5a06bd0adb40b7f9d0a4ab70611525e43` |
| `.build/acceptance-s03-launch-reopen-confirmation/result.json` | `10d8329d5c625558aaa385519778a3e108816ad7bea0ff430f24cc076058abd3` |
| `.build/acceptance-s03-launch-reopen-confirmation/first-launch.json` | `f0c916b39ae757e6a22a986b6e611ca0d692b9391c994b4e560b8ce6543b9ec2` |
| `.build/acceptance-s03-launch-reopen-confirmation/reopened-launch.json` | `708353df65be266fa5f7182d47b61b2cdfe758013cf67d6e29ec9d525076f853` |
| `.build/installed-s03-launch-reopen-confirmation/closure.json` | `0ca534170992f6e5f07dca2c019491799ee5b07392f2d66a38b923cda92a0e20` |

New direct Swift fixture source was independently reviewed before the final 41-test runtime. That runtime now verifies those unconditional positive routes; it is no longer source-only evidence.
