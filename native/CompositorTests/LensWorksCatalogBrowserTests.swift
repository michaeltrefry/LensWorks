import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CryptoKit
@testable import Compositor

@Suite(.serialized)
@MainActor
struct LensWorksCatalogBrowserTests {
    @Test func actualResolvedOriginalPublishesFullSourceForCreateAndReopenWithoutChangingPage() async throws {
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let row = try #require(model.assets.first)
            await model.select(row)
            #expect(model.selectedAsset?.originalPath == row.filename && model.selectedAsset?.nativeOriginal == nil)
            let output = fixture.root.appendingPathComponent("Versions")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            await model.setOutput(output.path)
            let page = model.pageAuthority, rows = model.assets.map(\.id)
            let workspace = ProjectWorkspace()
            await model.createWorkingVersion(workspace: workspace)
            let version = try #require(workspace.current.controller.workingVersion)
            let selected = try #require(model.selectedAsset)
            #expect(model.error == nil && !model.showingCatalog)
            #expect(selected.originalPath == version.originalPath)
            #expect(try selected.originalURL.path == version.originalPath)
            #expect(selected.key?.asset_id == version.originalVariantKey?.asset_id && selected.key?.variant_id == version.sourceVariantID)
            #expect(selected.metadataRevision == row.metadataRevision && selected.filename == row.filename)
            #expect(model.pageAuthority == page && model.assets.map(\.id) == rows)
            #expect(workspace.current.session.document?.size == CGSize(width: 1, height: 1))
            let project = URL(fileURLWithPath: version.projectPath)
            let saved = try #require(try LensWorksWorkingVersion.read(from: project))
            #expect(saved.id == version.id && saved.originalPath == selected.originalPath)
            await model.refresh()
            #expect(model.selectedAsset?.nativeOriginal == nil)
            let refreshedPage = model.pageAuthority
            await model.openVersion(saved, workspace: workspace)
            #expect(model.selectedAsset?.originalPath == saved.originalPath && model.selectedAsset?.nativeOriginal != nil)
            #expect(model.pageAuthority == refreshedPage && model.assets.map(\.id) == rows)
            #expect(workspace.current.controller.workingVersion?.id == saved.id && !model.showingCatalog)
        }
    }

    #if DEBUG
    @Test(arguments: ["selection", "selectionABA", "page", "closed", "variant"])
    func actualResolvedOriginalRejectsDeferredPublicationIntoChangedAuthority(_ change: String) async throws {
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let first = try #require(model.assets.first), other = try #require(model.assets.last)
            await model.select(first); try await model.loadCatalogVariants()
            let gate = ContinuationGate()
            model.continuationFixture = { if $0 == .originalResolved { await gate.hold() } }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { model.continuationFixture = nil; watchdog.cancel(); Task { await gate.release() } }
            let resolving = Task { try await model.resolveSelectedOriginal() }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !(await gate.entered) {
                    guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Native original resolution did not reach its publication checkpoint.") }
                    try await Task.sleep(for: .milliseconds(25))
                }
                switch change {
                case "selection": await model.select(other)
                case "selectionABA": await model.select(other); await model.select(first)
                case "page": await model.refresh()
                case "closed": try await model.close()
                case "variant": _ = try await model.changeCatalogRecipe(.copy("Deferred native source copy"))
                default: throw LensWorksCatalogError.message("Unknown source-publication control.")
                }
                let paths = model.assets.map(\.originalPath), page = model.pageAuthority, selected = model.selectedAsset?.id
                await gate.release()
                do { _ = try await resolving.value; throw LensWorksCatalogError.message("A stale native source published into changed authority.") }
                catch is CancellationError { }
                #expect(model.assets.map(\.originalPath) == paths && model.pageAuthority == page && model.selectedAsset?.id == selected)
                #expect(model.selectedAsset?.nativeOriginal == nil)
            } catch {
                let primary = error
                await gate.release(); _ = try? await resolving.value
                throw primary
            }
        }
    }
    #endif

    @Test func actualRegistryCatalogRecipePreservesFullKeyCASAndDeferredSelectionRefusal() async throws {
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let first = try #require(model.assets.first), second = try #require(model.assets.last)
            await model.select(first); try await model.loadCatalogVariants()
            let before = try #require(model.currentCatalogVariant), key = before.key
            let held = try model.admitCommand(.recipe(.exposure(1)), expected: before)
            #expect(held.id == .exposure)
            await model.select(second); try await model.loadCatalogVariants()
            do { try await model.dispatchCommand(held); Issue.record("Registry retargeted a deferred catalog command") }
            catch is CancellationError { }
            let unchanged = try await model.service.variant(key)
            #expect(unchanged.revision == before.revision && unchanged.recipe_digest == before.recipe_digest)
            await model.select(first); try await model.loadCatalogVariants()
            let fresh = try #require(model.currentCatalogVariant)
            try await model.dispatchCommand(model.admitCommand(.recipe(.exposure(1)), expected: fresh))
            let edited = try #require(model.currentCatalogVariant)
            #expect(edited.key.asset_id == key.asset_id && edited.key.variant_id == key.variant_id)
            #expect(edited.revision.value > fresh.revision.value && edited.recipe_digest != fresh.recipe_digest)
            #expect(model.catalogCommandAvailability(.recipe(.exposure(.nan)), expected: edited) == "Exposure must be finite.")
            try await model.dispatchCommand(model.admitCommand(.recipe(.undo), expected: edited))
            let undone = try #require(model.currentCatalogVariant)
            #expect(undone.recipe_digest == fresh.recipe_digest)
            try await model.dispatchCommand(model.admitCommand(.recipe(.redo), expected: undone))
            #expect(model.currentCatalogVariant?.recipe_digest == edited.recipe_digest)
            let closed = try model.admitCommand(.rating(3), expected: try #require(model.currentCatalogVariant))
            try await model.close()
            do { try await model.dispatchCommand(closed); Issue.record("Registry used retired catalog authority") }
            catch is CancellationError { }
        }
    }

    @Test func actualCatalogNamedCopyRecipeUndoAndFullKeyFocus() async throws {
        let fixture = try Fixture(images: 3)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let master = try #require(model.assets.first)
            await model.select(master); try await model.loadCatalogVariants()
            let original = try #require(model.currentCatalogVariant)
            #expect(model.catalogVariants.filter { $0.key.variant_id == original.key.variant_id }.count == 1)
            let masterPixels = try await model.thumbnail(master)
            try await model.createGroup("Single Master")
            try await model.setSelectedMembership(try model.group(named: "Single Master"))
            try await model.browse(collection: try model.group(named: "Single Master").id)
            await model.select(try #require(model.assets.first)); try await model.loadCatalogVariants()
            let copy = try await model.changeCatalogRecipe(.copy("Independent Catalog Copy"))
            #expect(copy.key.asset_id == original.key.asset_id && copy.key.variant_id != original.key.variant_id)
            #expect(copy.label == "Independent Catalog Copy" && copy.recipe_digest == original.recipe_digest)
            #expect(model.assets.count == 2)
            #expect(Set(model.assets.compactMap { $0.key?.variant_id }) == Set([original.key.variant_id, copy.key.variant_id]))
            #expect(model.selectedAsset?.key?.variant_id == copy.key.variant_id)
            #expect(model.selectedVersions.allSatisfy { $0.sourceVariantID == copy.key.variant_id })
            try await model.setSelectedMembership(try model.group(named: "Single Master"), remove: true)
            #expect(model.assets.count == 1 && model.assets.first?.key?.variant_id == original.key.variant_id)
            await model.select(try #require(model.assets.first)); try await model.loadCatalogVariants()
            try await model.selectCatalogVariant(try #require(model.catalogVariants.first { $0.key.variant_id == copy.key.variant_id }))
            try await model.loadCatalogVariants()
            #expect(model.assets.count == 1 && model.assets.first?.key?.variant_id == original.key.variant_id)
            #expect(model.selectedAsset?.key?.variant_id == copy.key.variant_id)
            #expect(model.selectedVersions.allSatisfy { $0.sourceVariantID == copy.key.variant_id })
            let copied = try #require(model.selectedAsset)
            let before = try await model.thumbnail(copied)
            let changed = try await model.changeCatalogRecipe(.exposure(1))
            #expect(changed.revision.value > copy.revision.value && changed.recipe_digest != copy.recipe_digest)
            let brighter = try await model.thumbnail(try #require(model.selectedAsset))
            let brightness: (LensWorksPreview) -> Int = { $0.samples.reduce(0) { $0 + $1.rgba.prefix(3).reduce(0) { $0 + Int($1) } } }
            #expect(brightness(brighter) > brightness(before))
            let undone = try await model.changeCatalogRecipe(.undo)
            #expect(undone.recipe_digest == copy.recipe_digest && undone.revision.value > changed.revision.value)
            let restored = try await model.thumbnail(try #require(model.selectedAsset))
            #expect(try LWCatalogCodec.encode(restored.samples) == LWCatalogCodec.encode(before.samples))
            let redone = try await model.changeCatalogRecipe(.redo)
            #expect(redone.recipe_digest == changed.recipe_digest && redone.revision.value > undone.revision.value)
            try await model.loadCatalogVariants()
            #expect(model.catalogVariants.filter { $0.key.variant_id == original.key.variant_id }.count == 1)
            try await model.selectCatalogVariant(try #require(model.catalogVariants.first { $0.key.variant_id == original.key.variant_id }))
            let preserved = try await model.thumbnail(try #require(model.selectedAsset))
            #expect(preserved.data == masterPixels.data)
            #expect(try await model.service.variant(original.key).revision == original.revision)
            try await model.close(); await model.connect(fixture.catalog.path, create: false)
            if let error = model.error { throw LensWorksCatalogError.message(error) }
            let reopened = try await model.service.variant(copy.key)
            #expect(reopened.label == copy.label && reopened.recipe_digest == changed.recipe_digest && reopened.revision == redone.revision)
        }
    }

    @Test func actualCatalogRecipeUndoABARejectsHeldOldPreviewBytes() async throws {
        #if DEBUG
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let asset = try #require(model.assets.first)
            await model.select(asset); try await model.loadCatalogVariants()
            let original = try #require(model.currentCatalogVariant)
            let gate = PreviewCapacityGate()
            try await model.service.setAdmittedPreviewBytesFixture { await gate.hold(String($0)) }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { watchdog.cancel(); Task { await gate.release() } }
            let reading = Task { try await model.thumbnail(asset) }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await gate.ticketCount != 1 {
                    guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("An actual old PreviewBytes job did not reach the held checkpoint.") }
                    try await Task.sleep(for: .milliseconds(25))
                }
                _ = try await model.changeCatalogRecipe(.exposure(1))
                let restored = try await model.changeCatalogRecipe(.undo)
                #expect(restored.recipe_digest == original.recipe_digest && restored.revision.value > original.revision.value)
                await gate.release()
                do { _ = try await reading.value; throw LensWorksCatalogError.message("Old ABA preview bytes incorrectly published.") }
                catch is CancellationError { }
                try await model.service.setAdmittedPreviewBytesFixture(nil)
                let fresh = try await model.thumbnail(try #require(model.selectedAsset))
                #expect(fresh.status.revision == restored.revision && fresh.status.recipe_digest == restored.recipe_digest)
            } catch {
                let primary = error
                await gate.release()
                reading.cancel()
                _ = await reading.result
                throw primary
            }
        }
        #endif
    }

    @Test func actualCatalogRatingDoesNotInvalidatePixelCache() async throws {
        let fixture = try Fixture(images: 3)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let selected = try #require(model.assets.first), key = try #require(selected.key)
            await model.select(selected); try await model.loadCatalogVariants()
            let recipe = try #require(model.currentCatalogVariant)
            let preview = try await model.thumbnail(selected)
            let before = await model.service.previewMetrics()
            guard case .Identity(let identity) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Expected actual metadata identity.") }
            try await model.setCatalogRating(3)
            guard case .Identity(let next) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Expected committed metadata identity.") }
            #expect(next.metadata_revision.value > identity.metadata_revision.value)
            #expect(next.pixel_generation == identity.pixel_generation && next.shared_source_epoch == identity.shared_source_epoch)
            let exact = try #require(model.assets.first { $0.key?.asset_id == key.asset_id && $0.key?.variant_id == key.variant_id })
            #expect(exact.rating == 3)
            let cached = try await model.thumbnail(exact), after = await model.service.previewMetrics()
            #expect(cached.data == preview.data && after.completed == before.completed)
            let preserved = try await model.service.variant(key)
            #expect(preserved.revision == recipe.revision && preserved.recipe_digest == recipe.recipe_digest)
        }
    }

    @Test func actualCatalogRecipeStaleRevisionIsRefusedWithoutRetry() async throws {
        #if DEBUG
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let asset = try #require(model.assets.first), key = try #require(asset.key)
            await model.select(asset); try await model.loadCatalogVariants()
            let captured = try #require(model.currentCatalogVariant)
            let gate = ContinuationGate()
            model.continuationFixture = { if $0 == .catalogRecipeAdmission { await gate.hold() } }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { model.continuationFixture = nil; watchdog.cancel(); Task { await gate.release() } }
            let saving = Task { try await model.changeCatalogRecipe(.exposure(1)) }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !(await gate.entered) {
                    guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Actual recipe CAS admission did not reach its owned checkpoint.") }
                    try await Task.sleep(for: .milliseconds(25))
                }
                let external = try await model.service.setExposure(key, value: 2)
                await gate.release()
                do { _ = try await saving.value; throw LensWorksCatalogError.message("Stale UI recipe CAS was incorrectly retried.") }
                catch LensWorksManagedError.native(_, _) { }
                let actual = try await model.service.variant(key)
                #expect(actual.revision == external.revision && actual.recipe_digest == external.recipe_digest)
                #expect(actual.revision.value > captured.revision.value)
            } catch {
                let primary = error
                await gate.release()
                saving.cancel()
                _ = await saving.result
                throw primary
            }
        }
        #endif
    }

    #if DEBUG
    @Test(arguments: [LensWorksCatalogContinuationPoint.catalogRecipeAdmission, .catalogRecipeReply])
    func actualCatalogRecipeCannotPublishIntoReplacedSelection(_ point: LensWorksCatalogContinuationPoint) async throws {
        #if DEBUG
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let first = try #require(model.assets.first), other = try #require(model.assets.last)
            await model.select(first); try await model.loadCatalogVariants()
            let before = try #require(model.currentCatalogVariant)
            let gate = ContinuationGate()
            model.continuationFixture = { if $0 == point { await gate.hold() } }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { model.continuationFixture = nil; watchdog.cancel(); Task { await gate.release() } }
            let saving = Task { try await model.changeCatalogRecipe(.exposure(1)) }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !(await gate.entered) {
                    guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Actual recipe publication did not reach its owned checkpoint.") }
                    try await Task.sleep(for: .milliseconds(25))
                }
                await model.select(other); await gate.release()
                do { _ = try await saving.value; throw LensWorksCatalogError.message("A stale recipe action published into another selection.") }
                catch is CancellationError { }
                #expect(model.selectedAsset?.id == other.id && model.currentCatalogVariant?.key.asset_id == nil)
                let source = try await model.service.variant(before.key)
                #expect(point == .catalogRecipeAdmission ? source.revision == before.revision : source.revision.value > before.revision.value)
                try await model.loadCatalogVariants()
                #expect(model.currentCatalogVariant?.key.asset_id == other.key?.asset_id)
            } catch {
                let primary = error
                await gate.release()
                saving.cancel()
                _ = await saving.result
                throw primary
            }
        }
        #endif
    }
    #endif

    @Test func actualCatalogRecipeReplyCannotPublishAfterCheckedClose() async throws {
        #if DEBUG
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            await model.select(try #require(model.assets.first)); try await model.loadCatalogVariants()
            let gate = ContinuationGate()
            model.continuationFixture = { if $0 == .catalogRecipeReply { await gate.hold() } }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { model.continuationFixture = nil; watchdog.cancel(); Task { await gate.release() } }
            let saving = Task { try await model.changeCatalogRecipe(.exposure(1)) }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !(await gate.entered) {
                    guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("An actual catalog recipe reply did not reach its owned checkpoint.") }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try await model.close(); await gate.release()
                do { _ = try await saving.value; throw LensWorksCatalogError.message("An old recipe reply published after checked Close.") }
                catch is CancellationError { }
                #expect(model.catalogPath == nil && model.catalogToken == nil && model.currentCatalogVariant?.key.asset_id == nil)
            } catch {
                let primary = error
                await gate.release()
                saving.cancel()
                _ = await saving.result
                throw primary
            }
        }
        #endif
    }

    @Test(arguments: [false, true])
    func actualCatalogClickAdmissionCannotRetargetAfterDeferredSelection(_ rating: Bool) async throws {
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let first = try #require(model.assets.first), second = try #require(model.assets.last)
            let firstKey = try #require(first.key), secondKey = try #require(second.key)
            await model.select(first); try await model.loadCatalogVariants()
            let firstRecipe = try #require(model.currentCatalogVariant), secondRecipe = try await model.service.variant(secondKey)
            guard case .Identity(let firstIdentity) = try await model.service.organization(.Identity(key: firstKey)),
                  case .Identity(let secondIdentity) = try await model.service.organization(.Identity(key: secondKey)) else { throw LensWorksManagedError.protocolViolation("Expected two actual click target identities.") }
            // Same production seam as the inspector: synchronous capture, then
            // dispatch is deliberately deferred across a real selection change.
            let admission = try model.captureCatalogControl(rating ? .rating(3) : .recipe(.exposure(1)), expected: firstRecipe)
            await model.select(second); try await model.loadCatalogVariants()
            #expect(!model.catalogControlIsCurrent(admission))
            do { try await model.performCatalogControl(admission); throw LensWorksCatalogError.message("A click intended for the first photo retargeted a later selection.") }
            catch is CancellationError { }
            let unchangedFirst = try await model.service.variant(firstKey), unchangedSecond = try await model.service.variant(secondKey)
            #expect(unchangedFirst.revision == firstRecipe.revision && unchangedFirst.recipe_digest == firstRecipe.recipe_digest)
            #expect(unchangedSecond.revision == secondRecipe.revision && unchangedSecond.recipe_digest == secondRecipe.recipe_digest)
            guard case .Identity(let afterFirst) = try await model.service.organization(.Identity(key: firstKey)),
                  case .Identity(let afterSecond) = try await model.service.organization(.Identity(key: secondKey)) else { throw LensWorksManagedError.protocolViolation("Expected actual unchanged click targets.") }
            #expect(afterFirst.metadata_revision == firstIdentity.metadata_revision && afterSecond.metadata_revision == secondIdentity.metadata_revision)
            #expect(model.selectedAsset?.id == second.id && model.currentCatalogVariant?.key.asset_id == secondKey.asset_id)
        }
    }

    @Test(arguments: [false, true])
    func actualCatalogClickAdmissionIsRefusedAfterCheckedClose(_ rating: Bool) async throws {
        let fixture = try Fixture(images: 2)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let first = try #require(model.assets.first), key = try #require(first.key)
            await model.select(first); try await model.loadCatalogVariants()
            let before = try #require(model.currentCatalogVariant)
            guard case .Identity(let metadata) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Expected actual click target metadata.") }
            let admission = try model.captureCatalogControl(rating ? .rating(3) : .recipe(.exposure(1)), expected: before)
            try await model.close()
            #expect(!model.catalogControlIsCurrent(admission))
            do { try await model.performCatalogControl(admission); throw LensWorksCatalogError.message("A deferred click used retired catalog authority.") }
            catch is CancellationError { }
            await model.connect(fixture.catalog.path, create: false)
            if let error = model.error { throw LensWorksCatalogError.message(error) }
            #expect(!model.catalogControlIsCurrent(admission))
            let unchanged = try await model.service.variant(key)
            #expect(unchanged.revision == before.revision && unchanged.recipe_digest == before.recipe_digest)
            guard case .Identity(let after) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Expected durable unchanged click target.") }
            #expect(after.metadata_revision == metadata.metadata_revision)
        }
    }

    @Test func actualColdForegroundCancellationDrainsNativeReadsBeforeRelocationRefusal() async throws {
        #if DEBUG
        let fixture = try Fixture(images: 4)
        fixture.preserveSuccessEvidence = true
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            try await model.settings(.BeginOriginalRootReview(roots: [LWCatalogNativePath(fileURL: fixture.photos)]))
            model.resumeSettingsWork(); try await model.waitSettings()
            try await model.close()
            await model.connect(fixture.catalog.path, create: false)
            if let error = model.error { throw LensWorksCatalogError.message(error) }
            let assets = Array(model.assets.prefix(4))
            guard assets.count == 4, Set(assets.map(\.photoID)).count == 4 else { throw LensWorksManagedError.protocolViolation("Expected four distinct cold photo authorities.") }
            let gate = PreviewCapacityGate()
            try await model.service.setAdmittedPreviewBytesFixture { await gate.hold(String($0)) }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { watchdog.cancel() }
            var reads: [Task<LensWorksPreview, any Error>] = []
            for asset in assets { reads.append(Task { try await model.thumbnail(asset) }) }
            do {
                // Native reads now finish within milliseconds, so public Status is
                // sampled continuously from the moment the reads are issued rather
                // than only after every bytes job has reached the gate.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var undrained: LWApplicationPreviewSettingsStatus?
                while true {
                    let held = await gate.ticketCount
                    if undrained != nil && held == 4 { break }
                    guard ContinuousClock.now < deadline else {
                        throw LensWorksCatalogError.message(undrained == nil ? "Real public Status never observed an undrained native read before cancellation."
                            : "Four cold production preview bytes jobs did not reach their actual owned gate.")
                    }
                    if undrained == nil {
                        try await model.settings()
                        if model.previewSettings?.previews_drained == false { undrained = model.previewSettings }
                    } else { try await Task.sleep(for: .milliseconds(5)) }
                }
                let nativeBefore = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(try #require(undrained)))
                try fixture.writeComparison(["stage": "before native read cancellation", "ownedBytesJobs": await gate.ticketCount,
                    "catalogToken": try #require(model.catalogToken), "previews_drained": false,
                    "status": nativeBefore])
                let maintenance = Task {
                    try await model.settings(.BeginRelocation(tier: .Thumbnail, destination: LWCatalogNativePath(fileURL: fixture.photos.appendingPathComponent("Forbidden"))))
                }
                await gate.release()
                do {
                    try await maintenance.value
                    throw LensWorksManagedError.protocolViolation("Relocation into originals must be refused after native preview retirement.")
                } catch LensWorksManagedError.native(_, let message) {
                    guard message == "relocation overlaps originals" else { throw LensWorksCatalogError.message("Unexpected relocation refusal: " + message) }
                }
                var readyPayloadSHA256: [String] = [], canceled = 0
                for read in reads {
                    do { let value = try await read.value; guard !value.data.isEmpty else { throw LensWorksManagedError.protocolViolation("Admitted preview payload is empty.") }; readyPayloadSHA256.append(Self.hash(value.data)) }
                    catch is CancellationError { canceled += 1 }
                }
                try await model.service.setAdmittedPreviewBytesFixture(nil)
                try await model.settings()
                #expect(model.previewSettings?.previews_drained == true)
                let metrics = await model.service.previewMetrics()
                #expect(metrics.active == 0 && metrics.pending == 0)
                let custody = try await model.service.previewDrainCustody()
                #expect(custody.job == nil && !custody.result && !custody.required && !custody.accepting)
                #expect(readyPayloadSHA256.count + canceled == 4)
                try fixture.writeComparison(["qualification": "NATIVE_READ_CANCELLATION_DRAIN_REGRESSION",
                    "ownedBytesJobs": 4, "beforeStatus": nativeBefore,
                    "afterStatus": try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(try #require(model.previewSettings))),
                    "expectedDomainRefusal": "relocation overlaps originals", "readyPayloadSHA256": readyPayloadSHA256, "canceled": canceled,
                    "metrics": try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(metrics))])
            } catch {
                await gate.release()
                for read in reads { read.cancel(); _ = await read.result }
                try await model.service.setAdmittedPreviewBytesFixture(nil)
                throw error
            }
        }
        #endif
    }

    @Test func actualNativeDrainTakenResultAndReleaseFaultKeepCheckedRetryAuthority() async throws {
        #if DEBUG
        for point in [LensWorksPreviewDrainFaultPoint.beforeDecode, .beforeRelease] {
            let fixture = try Fixture(images: 1)
            try await fixture.run { model in
                try await fixture.importPhotos(model)
                try await model.suspendPreviews()
                let fault = PreviewDrainFault(point: point)
                try await model.service.setPreviewDrainFixture { try await fault.hit($0) }
                do {
                    try await model.suspendPreviews()
                    throw LensWorksManagedError.protocolViolation("Owned drain fault was not observed.")
                } catch PreviewDrainTestError.injected { }
                let held = try await model.service.previewDrainCustody()
                #expect(held.job != nil && held.required && !held.accepting)
                #expect(held.result == (point == .beforeDecode))
                #expect(held.outcome == (point == .beforeRelease))
                await model.resumePreviews()
                #expect(model.previewsSuspended)
                if point == .beforeDecode {
                    try await model.suspendPreviews()
                    let retired = try await model.service.previewDrainCustody()
                    #expect(retired.job == nil && !retired.result && !retired.outcome && !retired.required)
                    try await model.service.setPreviewDrainFixture(nil)
                } else {
                    // Real native Close retires this catalog. Cleanup releases the
                    // already-taken job without issuing Status to its retired token.
                    try await model.close()
                    #expect(model.catalogPath == nil)
                }
                let submits = await fault.submits
                #expect(submits == 1, "Retry/checked Close must not submit a second Status for the retained terminal result.")
            }
        }
        #endif
    }

    @Test func actualPreviewDrainDeadlineAndCanceledStatusKeepAdmissionFenced() async throws {
        #if DEBUG
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let gate = PreviewCapacityGate()
            try await model.service.setAdmittedPreviewFixture { await gate.hold($0) }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { watchdog.cancel() }
            let read = Task { try await model.thumbnail(try #require(model.assets.first)) }
            do {
                let admission = ContinuousClock.now.advanced(by: .seconds(5))
                while await gate.ticketCount != 1 {
                    guard ContinuousClock.now < admission else { throw LensWorksCatalogError.message("Real preview ticket did not reach the deadline fixture.") }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let start = ContinuousClock.now
                do {
                    try await model.service.observePreviewDrain(timeoutMilliseconds: 250)
                    throw LensWorksManagedError.protocolViolation("Held consumer unexpectedly retired before its deadline.")
                } catch LensWorksCatalogError.message(let message) {
                    guard message == "Native preview consumers are still retiring. Their status job and catalog remain owned for checked retry." else { throw LensWorksCatalogError.message(message) }
                }
                #expect(start.duration(to: .now) < .seconds(1))
                let localHeld = try await model.service.previewDrainCustody()
                #expect(localHeld.required && !localHeld.accepting && localHeld.job == nil)
                await gate.release(); _ = await read.result
                try await model.service.setAdmittedPreviewFixture(nil)
                let statusGate = ContinuationGate()
                try await model.service.setPreviewDrainFixture { point in if point == .afterSubmit { await statusGate.hold() } }
                let observing = Task { try await model.suspendPreviews() }
                do {
                    let submitted = ContinuousClock.now.advanced(by: .seconds(5))
                    while !(await statusGate.entered) {
                        guard ContinuousClock.now < submitted else { throw LensWorksCatalogError.message("Real Status job did not reach its cancellation checkpoint.") }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    observing.cancel(); await statusGate.release()
                    do { try await observing.value; throw LensWorksManagedError.protocolViolation("Canceled observer unexpectedly completed.") }
                    catch is CancellationError { }
                    let nativeHeld = try await model.service.previewDrainCustody()
                    #expect(nativeHeld.job != nil && nativeHeld.required && !nativeHeld.accepting)
                    try await model.service.setPreviewDrainFixture(nil)
                    try await model.suspendPreviews()
                    let retired = try await model.service.previewDrainCustody()
                    #expect(retired.job == nil)
                } catch {
                    observing.cancel(); await statusGate.release(); _ = await observing.result
                    try await model.service.setPreviewDrainFixture(nil)
                    throw error
                }
            } catch {
                await gate.release(); read.cancel(); _ = await read.result
                try await model.service.setAdmittedPreviewFixture(nil)
                throw error
            }
        }
        #endif
    }
    #if DEBUG
    private enum PreviewDrainTestError: Error { case injected }
    private actor PreviewDrainFault {
        let point: LensWorksPreviewDrainFaultPoint
        private var fired = false
        private(set) var submits = 0
        init(point: LensWorksPreviewDrainFaultPoint) { self.point = point }
        func hit(_ current: LensWorksPreviewDrainFaultPoint) throws {
            if current == .afterSubmit { submits += 1 }
            if current == point && !fired { fired = true; throw PreviewDrainTestError.injected }
        }
    }
    #endif
    @Test func actualNestedFoldersVirtualGroupsAndLogicalCopies() async throws {
        let fixture = try Fixture(images: 130)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let root = try await model.folder(at: fixture.photos.path)
            try await model.browse(folder: root, recursive: false)
            #expect(model.assets.count == 2 && !model.hasMore)
            let nested = try await model.folder(at: fixture.photos.appendingPathComponent("Nested").path)
            try await model.browse(folder: nested, recursive: true)
            #expect(model.assets.count == 100 && model.hasMore)
            let first = try #require(model.assets.first)
            await model.select(first)
            await model.nextPage()
            #expect(model.assets.count == 28 && model.selectionCount == 1 && model.selection.isEmpty)
            await model.select(try #require(model.assets.last), range: true)
            #expect(model.selectionCount == 128 && model.selection.count == 28)
            try await model.createGroup("Parent")
            try await model.createGroup("Child")
            let child = try model.group(named: "Child"), parent = try model.group(named: "Parent")
            try await model.placeGroup(child, parent: parent.id)
            #expect(model.placements[child.id]?.parent == parent.id)
            try await model.setSelectedMembership(child)
            try await model.browse(collection: child.id)
            #expect(model.assets.count == 100 && model.hasMore)
            try await model.browse(collection: parent.id)
            #expect(model.assets.isEmpty, "Parent placement does not imply recursive membership.")
            try await model.browse(folder: root, recursive: false)
            let master = try #require(model.assets.first), key = try #require(master.key)
            let (owner, token) = try await model.service.context()
            let authority = try await model.service.variant(key)
            guard case .Variant(let copy) = try await owner.perform(.CreateVariant(catalog: token, key: key, expected_revision: authority.revision, label: "Independent copy")) else { throw LensWorksManagedError.protocolViolation("Expected actual copy authority.") }
            await model.refresh()
            #expect(model.assets.count == 3)
            let logicalCopy = try #require(model.assets.first { $0.key?.variant_id == copy.key.variant_id })
            #expect(logicalCopy.photoID == master.photoID && logicalCopy.id != master.id)
            let version = try fixture.package(photo: master.photoID, variant: "master", catalog: try #require(model.catalogPath), name: "master.comp")
            try await model.index.register(version)
            await model.select(logicalCopy)
            #expect(model.selectedVersions.isEmpty, "A logical copy must never select the master's project.")
            let copyVersion = try fixture.package(photo: logicalCopy.photoID, variant: copy.key.variant_id, catalog: try #require(model.catalogPath), name: "copy.comp")
            try await model.index.register(copyVersion)
            await model.refreshVersions()
            #expect(model.selectedVersions.count == 1 && model.selectedVersions.first?.sourceVariantID == copy.key.variant_id)
            await model.select(master)
            #expect(model.selectedVersions.count == 1 && model.selectedVersions.first?.sourceVariantID == "master")
            await model.setBrowseOrder(sort: .Filename, direction: .Descending)
            #expect(model.cursorHistoryCount == 0 && model.browseOptions.folder == root.id)
            try await model.browse(collection: child.id, text: "Photo")
            #expect(model.activeFolder == nil && model.browseOptions.folder == nil && model.browseOptions.collection == child.id)
        }
    }

    @Test func actualPhysicalUpRemainsReachableBeyondTheAncestorCache() async throws {
        let fixture = try Fixture(images: 1)
        let source = try #require(fixture.sources.keys.first)
        var extras: [URL: Data] = [:]
        for number in 0..<101 {
            let folder = fixture.photos.appendingPathComponent(String(format: "Sibling-%03d", number))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Sibling.png")
            try FileManager.default.copyItem(at: source, to: file); extras[file] = try Data(contentsOf: file)
        }
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let root = try await model.folder(at: fixture.photos.path)
            try await model.loadFolders(parent: root)
            #expect(model.folders.count == 100 && model.folderNext != nil)
            while model.folderNext != nil { await model.nextFolders() }
            let target = try #require(model.folders.last)
            var deepest = try target.locator.localFileURL()
            for _ in 0..<70 { deepest.appendPathComponent("é") }
            try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
            let deepSource = deepest.appendingPathComponent("Deep.png")
            try FileManager.default.copyItem(at: source, to: deepSource)
            let before = try Data(contentsOf: deepSource)
            try await fixture.importPhotos(model)
            let deepFolder = try await model.folder(at: deepest.path)
            try await model.loadFolders(parent: deepFolder)
            var current = deepest
            for _ in 0..<70 {
                await model.upFolder()
                current.deleteLastPathComponent()
                #expect(try model.folderParent?.locator.localFileURL().path == current.path)
                #expect(model.navigationHighWater <= 364)
                if let error = model.error { throw LensWorksCatalogError.message(error) }
            }
            #expect(model.folderParent?.id == target.id)
            #expect(try Data(contentsOf: deepSource) == before)
            for (file, original) in extras { #expect(try Data(contentsOf: file) == original) }
        }
    }

    @Test func actualPublicTwoRequestMixedRescanWithDrainedPreviewControl() async throws {
        try await exercisePublicTwoRequestRescan(mode: "drained")
    }
    @Test func actualPublicTwoRequestMixedRescanComposesWithFourForegroundPreviews() async throws {
        try await exercisePublicTwoRequestRescan(mode: "four_foreground")
    }
    @Test func actualPublicTwoRequestMixedRescanWithExplicitlyPausedPreviewControl() async throws {
        try await exercisePublicTwoRequestRescan(mode: "paused")
    }
    @Test func actualProductionMixedRescanKeepsFourForegroundPreviewsReady() async throws {
        try await exercisePublicTwoRequestRescan(mode: "four_foreground", productionDefaults: true)
    }
    private func exercisePublicTwoRequestRescan(mode: String, productionDefaults: Bool = false) async throws {
        // Existing comparisons change only requests=2. The separate production
        // proof sends no preview limit override and requires four real Ready payloads.
        guard !productionDefaults || mode == "four_foreground" else { throw LensWorksManagedError.protocolViolation("Production preview proof requires the real four-foreground path.") }
        let fixture = try Fixture(images: 1, previewRequests: productionDefaults ? nil : 2)
        if productionDefaults {
            guard case nil = fixture.config.preview_limits else { throw LensWorksManagedError.protocolViolation("Production proof must use retained default preview limits without an override.") }
        }
        fixture.preserveSuccessEvidence = true
        let source = try #require(fixture.sources.keys.first), sourceBytes = try Data(contentsOf: source)
        var originals = Set(fixture.sources.keys)
        for number in 0..<101 {
            let folder = fixture.photos.appendingPathComponent(String(format: "Sibling-%03d", number))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Sibling.png")
            try sourceBytes.write(to: file); originals.insert(file)
        }
        fixture.comparisonSourceHashes = try Self.hashSources(originals)
        try await fixture.run { model in
            var report: [String: Any] = ["mode": mode, "qualification": productionDefaults ? "PRODUCTION_DEFAULT_FOUR_FOREGROUND_IMPORT_PROOF" : "PUBLIC_REQUEST_BUDGET_EXPERIMENT_ONLY",
                "sourceRevision": LWManagedAuthority.sourceRevision, "productionPolicyChanged": false,
                "frontendActiveLimit": 4, "frontendPendingLimit": 200,
                "publicPreviewLimits": productionDefaults ? "retained ServiceLimits::default; no override" : try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(try #require(fixture.config.preview_limits))),
                "productionDefaults": productionDefaults,
                "knownDefaultFailure": productionDefaults ? "HISTORICAL_R3_ONLY; no current default400 failure assumed" : "R3 default400: pending import preview followed by synchronous cached read Busy; unchanged101, failed1"]
            do {
                fixture.diagnosticStage = productionDefaults ? "production default400 seed 102 physical originals" : "requests2 seed 102 physical originals"
                let firstStart = ContinuousClock.now
                try await fixture.importPhotos(model)
                try fixture.checkComparisonSources()
                report["seedSeconds"] = Self.seconds(firstStart.duration(to: .now))
                let firstAttempt = try #require(model.importProgress?.id)
                guard model.importProgress?.imported.value == 102, model.importProgress?.failed.value == 0 else { throw LensWorksManagedError.protocolViolation("The controlled initial import did not complete all 102 originals.") }
                let foregroundRows = Array(model.assets.prefix(4))
                guard foregroundRows.count == 4 else { throw LensWorksManagedError.protocolViolation("The experiment requires four distinct actual existing photo authorities.") }
                let oldIDs = try await Self.enumerate(model, count: 102)
                var deepest = fixture.photos.appendingPathComponent("Sibling-100")
                for _ in 0..<70 { deepest.appendPathComponent("é") }
                try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
                let added = deepest.appendingPathComponent("Deep.png")
                try sourceBytes.write(to: added); originals.insert(added)
                var sourceHashes = try #require(fixture.comparisonSourceHashes)
                sourceHashes[added] = Self.hash(sourceBytes)
                fixture.comparisonSourceHashes = sourceHashes
                report["originalSHA256"] = Dictionary(uniqueKeysWithValues: try #require(fixture.comparisonSourceHashes).map { ($0.key.path, $0.value) })
                try await model.suspendPreviews()
                if mode != "paused" { await model.resumePreviews() }
                fixture.diagnosticStage = (productionDefaults ? "production default400" : "requests2") + " mixed 102-existing plus one-new rescan: " + mode
                let secondStart = ContinuousClock.now
                try await model.startImport(fixture.photos.path)
                let secondAttempt = try #require(model.importProgress?.id)
                guard firstAttempt != secondAttempt, model.isImporting else { throw LensWorksManagedError.protocolViolation("The controlled rescan did not admit a new active attempt.") }
                report["firstAttempt"] = firstAttempt; report["secondAttempt"] = secondAttempt
                if mode != "drained" {
                    try await model.waitImport(terminal: false, phase: "discovering", timeoutMilliseconds: 5000)
                    guard model.isImporting, model.importProgress?.id == secondAttempt else { throw LensWorksManagedError.protocolViolation("Foreground composition must begin during the same real active attempt.") }
                    await fixture.previewCheckpoint(model, stage: (productionDefaults ? "production default400 " : "requests2 ") + mode + " four foreground calls during Discovering")
                    report["foregroundAdmissionImport"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(try #require(model.importProgress)))
                    if productionDefaults {
                        let current = try #require(try await model.service.importStatus())
                        guard current.id == secondAttempt, [.Discovering, .Draining].contains(current.phase), current.failed.value == 0,
                              try LWCatalogCodec.encode(current.source) == LWCatalogCodec.encode(try LWCatalogNativePath(fileURL: fixture.photos)) else {
                            throw LensWorksManagedError.protocolViolation("Four production calls require the same real active import source/attempt at admission.")
                        }
                        let keys = try foregroundRows.map { try #require($0.key) }
                        guard Set(try keys.map { try LWCatalogCodec.encode($0) }).count == 4 else { throw LensWorksManagedError.protocolViolation("Four production previews require distinct complete logical photo authorities.") }
                        report["foregroundAdmissionImport"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(current))
                        report["foregroundAuthorities"] = zip(foregroundRows, keys).map { ["imageID": $0.0.id, "assetID": $0.1.asset_id, "variantID": $0.1.variant_id] }
                    }
                    let previewsStart = ContinuousClock.now
                    let outcomes = try await fixture.observeFourPreviews(model, rows: foregroundRows, expectPaused: mode == "paused", expectCapacity: mode == "four_foreground" && !productionDefaults)
                    report["foregroundSeconds"] = Self.seconds(previewsStart.duration(to: .now))
                    report["foregroundOutcomes"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(outcomes))
                    let foregroundMetrics = await model.service.previewMetrics()
                    report["foregroundPreviewMetrics"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(foregroundMetrics))
                    let afterPreviews = try #require(try await model.service.importStatus())
                    report["foregroundCompletionImport"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(afterPreviews))
                    if mode == "four_foreground" {
                        guard foregroundMetrics.activeHighWater == 4,
                              afterPreviews.id == secondAttempt, [.Discovering, .Draining].contains(afterPreviews.phase) else {
                            throw LensWorksManagedError.protocolViolation("The four preview receipts were not all observed before the same active import finished; concurrent-import composition remains unqualified.")
                        }
                    }
                    if productionDefaults {
                        guard outcomes.count == 4, outcomes.allSatisfy({ $0.outcome == "ready" && $0.encodedSHA256?.count == 64 }),
                              foregroundMetrics.active == 0, foregroundMetrics.pending == 0 else {
                            throw LensWorksManagedError.protocolViolation("All four production preview calls must yield real checked Ready payloads and retire; no capacity negative is tolerated.")
                        }
                    }
                    report["independentPreviewsDuringImportQualified"] = productionDefaults
                    report["negativeTwoRequestCapacityQualified"] = !productionDefaults && mode == "four_foreground" && outcomes.contains(where: { $0.outcome == "capacity_rejected" })
                } else { report["independentPreviewsDuringImportQualified"] = false }
                try await fixture.awaitImportCompletion(model)
                let completed = try #require(model.importProgress)
                guard completed.id == secondAttempt, completed.phase == .Complete,
                      completed.imported.value == 1, completed.unchanged.value == 102, completed.failed.value == 0 else {
                    throw LensWorksManagedError.protocolViolation("The requests2 mixed rescan did not complete exactly one new plus 102 unchanged originals: \(completed).")
                }
                report["rescanSeconds"] = Self.seconds(secondStart.duration(to: .now))
                report["import"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(completed))
                let ids = try await Self.enumerate(model, count: 103)
                guard oldIDs.isSubset(of: ids), ids.subtracting(oldIDs).count == 1 else { throw LensWorksManagedError.protocolViolation("The controlled rescan changed existing image identities or did not add exactly one new image.") }
                if mode == "paused" {
                    await model.resumePreviews()
                    guard !model.previewsSuspended else { throw LensWorksManagedError.protocolViolation("The explicitly paused control did not resume its owned producer.") }
                    let resumed = try await fixture.observeFourPreviews(model, rows: foregroundRows, expectPaused: false, expectCapacity: true)
                    report["resumedOutcomes"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(resumed))
                    report["resumedCapacityRejectionObserved"] = resumed.contains(where: { $0.outcome == "capacity_rejected" })
                    let large = try await model.thumbnail(foregroundRows[0], tier: .Large)
                    guard large.cost > 0 else { throw LensWorksManagedError.protocolViolation("The resumed Large-tier preview did not publish real bytes.") }
                    report["resumedLargeSHA256"] = Self.hash(large.data)
                }
                if mode != "drained" {
                    // No retry: new real admission after all four prior calls have retired.
                    let thumbnail = try await model.thumbnail(foregroundRows[0])
                    let large = try await model.thumbnail(foregroundRows[0], tier: .Large)
                    guard thumbnail.cost > 0, large.cost > 0 else { throw LensWorksManagedError.protocolViolation("Retired slots did not admit actual Thumbnail/Large payloads again.") }
                    report["reusedThumbnailSHA256"] = Self.hash(thumbnail.data)
                    report["reusedLargeSHA256"] = Self.hash(large.data)
                    let retired = await model.service.previewMetrics()
                    guard retired.active == 0, retired.pending == 0 else { throw LensWorksManagedError.protocolViolation("Preview tasks did not retire after actual receipts.") }
                }
                report["previewMetrics"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(await model.service.previewMetrics()))
                report["allImageIDs"] = ids.sorted(); report["uniqueImageCount"] = ids.count
                try fixture.checkComparisonSources()
                report["status"] = "actual import and requested control/composition completed; checked close pending"
                try fixture.writeComparison(report)
            } catch {
                fixture.cancelComparisonPreviews()
                report["status"] = "FAILED_UNQUALIFIED"; report["failure"] = String(describing: error)
                if let progress = model.importProgress { report["import"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(progress)) }
                report["previewOutcomes"] = fixture.comparisonPreviewDescriptions
                report["previewMetrics"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(await model.service.previewMetrics()))
                try fixture.checkComparisonSources()
                try fixture.writeComparison(report)
                throw error
            }
        }
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hashSources(_ urls: Set<URL>) throws -> [URL: String] {
        try Dictionary(uniqueKeysWithValues: urls.map { ($0, hash(try Data(contentsOf: $0))) })
    }
    private static func enumerate(_ model: LensWorksCatalog, count: Int) async throws -> Set<String> {
        try await model.browse()
        let maximumPages = (count + 99) / 100
        var ids = Set<String>(), photos = Set<String>(), pages = 0
        while true {
            guard pages < maximumPages, !model.assets.isEmpty, model.assets.count <= 100 else { throw LensWorksManagedError.protocolViolation("Controlled comparison exceeded its exact bounded page count.") }
            pages += 1
            let authority = model.pageAuthority
            for row in model.assets {
                guard ids.insert(row.id).inserted, photos.insert(row.photoID).inserted else { throw LensWorksManagedError.protocolViolation("Controlled comparison repeated actual image/photo authority.") }
            }
            if !model.hasMore { break }
            guard pages < maximumPages, await model.nextPage(), model.pageAuthority.queryEpoch == authority.queryEpoch,
                  model.pageAuthority.current == authority.next, model.pageAuthority.publication > authority.publication else {
                throw LensWorksManagedError.protocolViolation("Controlled comparison did not advance its actual query/page authority.")
            }
        }
        guard ids.count == count, photos.count == count else { throw LensWorksManagedError.protocolViolation("Controlled comparison did not enumerate exactly \(count) distinct physical photos.") }
        return ids
    }

    @Test func actualHostRejectsOpaqueUnixFolderBeforeCatalogAdmission() throws {
        let fixture = try Fixture(images: 1)
        let units = Array(fixture.photos.path.utf8) + [47, 255, 254] + Array(" Camera".utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.photos.path).sorted()
        let result = (units + [0]).withUnsafeBytes { Darwin.mkdir($0.baseAddress!.assumingMemoryBound(to: CChar.self), 0o700) }
        let failure = errno
        if result == 0 {
            _ = (units + [0]).withUnsafeBytes { Darwin.rmdir($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            throw LensWorksCatalogError.message("This filesystem admitted opaque bytes; the separate APFS rejection fixture cannot qualify on this host.")
        }
        let directory = fixture.photos.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directory >= 0 else { throw LensWorksCatalogError.message("The owned host-admission directory could not be opened.") }
        defer { Darwin.close(directory) }
        var filesystem = statfs()
        guard Darwin.fstatfs(directory, &filesystem) == 0 else { throw LensWorksCatalogError.message("The opaque-path host filesystem could not be identified.") }
        let filesystemName = withUnsafePointer(to: &filesystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        let evidence: [String: Any] = ["operation": "mkdir", "errno": failure, "filesystem": filesystemName,
            "nativePathBytes": units, "catalogAdmitted": false, "physicalOpaqueImportQualified": false]
        let destination = fixture.root.appendingPathComponent("opaque-host-admission.json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: destination)
        print("Opaque-byte host rejection evidence retained at \(destination.path); errno=\(failure), filesystem=\(filesystemName). No catalog admission or opaque physical import is claimed.")
        #expect(failure == EILSEQ)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photos.path).sorted() == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.catalog.path))
        for (file, original) in fixture.sources { #expect(try Data(contentsOf: file) == original) }
    }

    @Test func opaqueNativePathCodecAndSeventyParentsPreserveEveryByte() throws {
        let parent = Array("/Photos/".utf8) + [255, 254] + Array(" Camera".utf8)
        var units = parent
        for _ in 0..<70 { units += [47, 100] }
        var path = LWCatalogNativePath.unixBytes(units)
        #expect(try LWCatalogCodec.decode(LWCatalogNativePath.self, from: LWCatalogCodec.encode(path)) == path)
        #expect(try path.physicalFolderUnits() == units)
        for _ in 0..<70 {
            units.removeLast(2)
            path = try path.parentPhysicalFolder()
            #expect(path == .unixBytes(units))
            #expect(try LWCatalogCodec.decode(LWCatalogNativePath.self, from: LWCatalogCodec.encode(path)) == .unixBytes(units))
        }
        #expect(path == .unixBytes(parent))
        #expect(throws: (any Error).self) { try LWCatalogNativePath.unixBytes([47, 255, 0]).physicalFolderUnits() }
        // This is a pure lossless native authority contract, not a filesystem/import proof.
    }

    @Test func actualSavedCandidateTransportPreservesOpaqueUnixBytesAcrossReopen() async throws {
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let key = try #require(model.assets.first?.key)
            let candidate = LWCatalogNativePath.unixBytes(Array("/Saved Candidate/".utf8) + [255, 254])
            let (session, catalog) = try await model.service.context()
            let begun = try await session.perform(.Relink(catalog: catalog, request: .Begin(scope: .Asset(asset_id: key.asset_id, destinations: [candidate]))))
            guard case .Relink(.Plan(let plan)) = begun else { throw LensWorksManagedError.protocolViolation("Saved candidate transport did not return its real synchronous plan authority.") }
            let rules = try await session.perform(.Relink(catalog: catalog, request: .Rules(plan: plan.id, revision: plan.revision, after: nil, limit: LWCatalogU64(16))))
            try Self.requireSavedCandidate(rules, asset: key.asset_id, candidate: candidate)
            try await model.close()
            await model.connect(fixture.catalog.path)
            guard model.error == nil else { throw LensWorksCatalogError.message(model.error!) }
            let (reopened, token) = try await model.service.context()
            #expect(token != catalog)
            let stored = try await reopened.perform(.Relink(catalog: token, request: .Plan(plan: plan.id)))
            guard case .Relink(.Plan(let read)) = stored, read.id == plan.id, read.revision == plan.revision else { throw LensWorksManagedError.protocolViolation("Saved candidate plan authority changed across checked reopen.") }
            let persisted = try await reopened.perform(.Relink(catalog: token, request: .Rules(plan: read.id, revision: read.revision, after: nil, limit: LWCatalogU64(16))))
            try Self.requireSavedCandidate(persisted, asset: key.asset_id, candidate: candidate)
            print("SAVED_CANDIDATE_TRANSPORT: real asset/plan/revision, Rules limit16, exact opaque bytes persisted across checked reopen. No Prepare/Apply, opaque filesystem import, or offline Original is claimed.")
        }
    }
    private static func requireSavedCandidate(_ response: LWApplicationResponse, asset: String, candidate: LWCatalogNativePath) throws {
        guard case .Relink(.Rules(let rows, let next, _)) = response, !rows.isEmpty, rows.count <= 16, next == nil else { throw LensWorksManagedError.protocolViolation("Saved candidate evidence did not fit its bounded real Rules page.") }
        let scopes = rows.compactMap { row -> [LWCatalogNativePath]? in
            if case .Scope(.Asset(let id, let destinations)) = row.rule, id == asset { return destinations }
            return nil
        }
        guard scopes.count == 1, scopes[0] == [candidate] else { throw LensWorksManagedError.protocolViolation("The actual saved candidate scope lost its exact native path bytes or asset authority.") }
    }

    @Test func actualSparsePagesAndStaleCursorRestart() async throws {
        let fixture = try Fixture(images: 5, scanRows: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            #expect(model.assets.count <= 1 && model.hasMore)
            await model.nextPage()
            #expect(model.cursorHistoryCount == 1)
            let key = try #require(model.assets.first?.key)
            guard case .Identity(let identity) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Expected actual metadata CAS authority.") }
            guard case .Changed(let changedRevision) = try await model.service.organization(.Apply(key: key, expected_revision: identity.metadata_revision, operation: .Rating(value: 3))) else { throw LensWorksManagedError.protocolViolation("Expected a completed rating mutation.") }
            #expect(changedRevision.value > identity.metadata_revision.value)
            let restarts = model.staleCursorRestarts, publication = model.pagePublication
            let advanced = await model.nextPage()
            #expect(!advanced && model.error == nil && model.cursorHistoryCount == 0)
            #expect(model.staleCursorRestarts == restarts + 1 && model.pagePublication > publication)
            #expect(model.currentCursor == nil && model.assets.count == 1)
            let folder = try await model.folder(at: fixture.photos.path)
            try await model.browse(folder: folder, recursive: true, text: "missing-no-photo")
            #expect(model.assets.isEmpty && !model.pageComplete && model.nextCursor != nil)
            var steps = 0
            while model.hasMore, steps < 10 { await model.nextPage(); steps += 1 }
            #expect(steps > 0 && steps <= 5 && model.assets.isEmpty && !model.hasMore)
            #expect(model.rowsHighWater <= 100 && model.cursorHistoryCount <= 64)
        }
    }

    @Test func actualLatePageCannotRestoreAReplacedQuery() async throws {
        let fixture = try Fixture(images: 230)
        try await fixture.run { model in
            // Seed-workload control only; every public observation remains <=60000ms.
            let seedDeadline = ContinuousClock.now.advanced(by: .seconds(120))
            try await model.startImport(fixture.photos.path)
            let seed = try #require(model.importProgress)
            var completed = false
            for window in 0..<2 {
                let before = try #require(model.importProgress)
                let remaining = (seedDeadline - ContinuousClock.now).components
                let milliseconds = remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000
                let allowance = UInt32(clamping: min(60000, milliseconds))
                guard allowance > 0 else { throw LensWorksCatalogError.message("The 230-photo seed exceeded its measured 120-second workload control.") }
                do {
                    try await model.waitImport(terminal: true, timeoutMilliseconds: allowance)
                    completed = true; break
                } catch LensWorksCatalogError.importObservationTimeout(let observed) {
                    guard observed.id == seed.id, observed.source == seed.source,
                          [.Discovering, .Draining].contains(observed.phase), observed.failed.value == 0,
                          observed.imported.value >= before.imported.value, observed.unchanged.value >= before.unchanged.value,
                          observed.imported.value + observed.unchanged.value > before.imported.value + before.unchanged.value else {
                        throw LensWorksManagedError.protocolViolation("The race seed timed out without same-attempt/source progress.")
                    }
                    if window == 1 { throw LensWorksCatalogError.importObservationTimeout(observed) }
                }
            }
            let terminal = try #require(model.importProgress)
            guard completed, ContinuousClock.now <= seedDeadline,
                  terminal.id == seed.id, terminal.source == seed.source, terminal.phase == .Complete,
                  terminal.failed.value == 0, terminal.imported.value + terminal.unchanged.value == 230 else {
                throw LensWorksManagedError.protocolViolation("The race seed did not complete exactly 230 photos within its finite workload control.")
            }
            _ = try await Self.enumerate(model, count: 230)
            try await model.browse()
            await model.nextPage()
            #expect(model.cursorHistoryCount == 1 && model.currentCursor != nil && model.hasMore)
            let (session, _) = try await model.service.context()
            let state = try await session.status()
            let pid = try #require(state.pid > 0 ? pid_t(state.pid) : nil)
            let watchdog = Task.detached { do { try await Task.sleep(for: .seconds(10)); _ = kill(pid, SIGCONT) } catch { } }
            var stopped = false
            defer { if stopped { _ = kill(pid, SIGCONT) }; watchdog.cancel() }
            guard kill(pid, SIGSTOP) == 0 else { throw LensWorksCatalogError.message("Owned worker could not be stopped.") }
            stopped = true
            let generation = model.previewGeneration, oldAuthority = model.pageAuthority, history = model.cursorHistoryCount
            let oldPage = Task { await model.nextPage() }
            try await Self.wait { model.isBusy && model.previewGeneration > generation }
            #expect(model.pageAuthority == oldAuthority && model.cursorHistoryCount == history, "Navigation authority stays paired with the old visible rows until its actual reply is admitted.")
            let replacement = Task { try await model.browse(text: "Photo-0000") }
            try await Self.wait { model.previewGeneration > generation + 1 }
            #expect(model.assets.isEmpty && model.selection.isEmpty && !model.hasMore && !model.pageComplete && model.scanned == 0)
            #expect(model.currentCursor == nil && model.nextCursor == nil && model.cursorHistoryCount == 0 && model.pageStart == 0)
            _ = kill(pid, SIGCONT); stopped = false
            #expect(await oldPage.value == false); try await replacement.value
            #expect(model.error == nil && model.assets.count == 1)
            #expect(model.assets.first?.filename == "Photo-0000.png")
            #expect(model.browseOptions.text == "Photo-0000" && model.cursorHistoryCount == 0 && model.currentCursor == nil && model.nextCursor == nil)
        }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Controlled worker admission did not reach its bounded checkpoint.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func actualPreviewCacheBoundsDuplicateChargesEditInvalidationAndBothTiers() async throws {
        let fixture = try Fixture(images: 70)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let rows = model.assets
            let first = try #require(rows.first)
            await fixture.previewCheckpoint(model, stage: "before duplicate first-key preview")
            async let a = model.thumbnail(first)
            async let b = model.thumbnail(first)
            let (one, two) = try await (a, b)
            #expect(one.data == two.data)
            let sameKey = await model.service.previewMetrics()
            #expect(sameKey.cacheEntries == 1 && sameKey.cacheBytes == one.cost)
            let before = one.data
            await fixture.previewCheckpoint(model, stage: "before 70-key bounded preview group")
            try await withThrowingTaskGroup(of: Int.self) { group in
                for row in rows { group.addTask { try await model.thumbnail(row).cost } }
                for try await cost in group { #expect(cost > 0) }
            }
            await fixture.previewCheckpoint(model, stage: "70-key preview group completed; before edit")
            let bounded = await model.service.previewMetrics()
            #expect(bounded.cacheEntries == 64 && bounded.cacheEntriesHighWater <= 64)
            #expect(bounded.cacheBytes <= 32 * 1024 * 1024 && bounded.cacheBytesHighWater <= 32 * 1024 * 1024)
            #expect(bounded.activeHighWater <= 4 && bounded.pendingHighWater <= 200)
            fixture.diagnosticStage = "save actual exposure edit"
            _ = try await model.service.setExposure(try #require(first.key), value: -1)
            await fixture.previewCheckpoint(model, stage: "before edited thumbnail")
            let edited = try await model.thumbnail(first)
            #expect(edited.data != before && edited.status.revision.value > one.status.revision.value)
            await fixture.previewCheckpoint(model, stage: "before actual Large previews")
            let large = try await model.thumbnail(first, tier: .Large)
            for row in rows.dropFirst().prefix(2) { _ = try await model.thumbnail(row, tier: .Large) }
            #expect(large.width == 1 && large.height == 1 && large.alpha == "opaque")
            try await model.settings(.BeginOriginalRootReview(roots: [LWCatalogNativePath(fileURL: fixture.photos)]))
            model.resumeSettingsWork(); try await model.waitSettings()
            for tier: LWPreviewStoreTier in [.Thumbnail, .Large] {
                let destination = fixture.root.appendingPathComponent(tier == .Thumbnail ? "MovedThumbs" : "MovedLarge")
                try await model.settings(.BeginRelocation(tier: tier, destination: LWCatalogNativePath(fileURL: destination)))
                try await model.settings(.StepRelocation(tier: tier, objects: 1, bytes: LWCatalogU64(1048576)))
                await model.finishSettingsPause()
                let partial = try #require(model.previewSettings)
                #expect((partial.relocation?.objects?.value ?? 0) > 0 && partial.relocation_pending)
                try await model.close()
                await model.connect(fixture.catalog.path)
                try await model.settings()
                #expect(model.previewSettings?.relocation_pending == true)
                #expect(model.previewSettings?.relocation_tier == tier)
                model.resumeSettingsWork(); try await model.waitSettings()
                #expect(model.previewSettings?.relocation_pending == false)
                let target = tier == .Thumbnail ? model.previewSettings?.thumbnail_root : model.previewSettings?.large_root
                #expect(try target?.localFileURL().path == destination.path)
                await model.resumePreviews()
                let value = try await model.thumbnail(first, tier: tier == .Thumbnail ? .Thumbnail : .Large)
                #expect(value.data == (tier == .Thumbnail ? edited.data : large.data))
            }
            await #expect(throws: (any Error).self) {
                try await model.settings(.BeginRelocation(tier: .Thumbnail, destination: LWCatalogNativePath(fileURL: fixture.photos.appendingPathComponent("Forbidden"))))
            }
        }
    }

    @Test func actualImportInterruptionRescansWithNewAttemptAndRejectsOldCancel() async throws {
        let fixture = try Fixture(images: 2048)
        var stage = "start original import"
        try await fixture.run { model in
            do {
            try await model.startImport(fixture.photos.path)
            stage = "await active original attempt"
            try await model.waitImport(terminal: false, minimumImported: 1, phase: "discovering")
            let interrupted = try #require(model.importProgress?.id)
            #expect(model.isImporting)
            stage = "cancel original attempt and await retirement"
            try await model.cancelImport()
            #expect(model.importProgress?.id == interrupted && model.importProgress?.phase == .Canceled)
            #expect(model.importSamples.contains { $0.phase == .CancelRequested || $0.phase == .Canceled })
            stage = "checked close after original cancellation"
            try await model.close()
            await model.connect(fixture.catalog.path)
            #expect(model.hasImportCheckpoint && model.importProgress == nil)
            stage = "start resumed attempt"
            try await model.startImport(resume: true)
            let resumed = try #require(model.importProgress?.id)
            #expect(resumed != interrupted)
            await #expect(throws: (any Error).self) { try await model.service.cancelImport(interrupted) }
            stage = "await resumed attempt completion within measured 600-second workload budget"
            let completionDeadline = ContinuousClock.now.advanced(by: .seconds(600))
            let resumedSource = try #require(model.importProgress?.source)
            var observations = 0
            while model.isImporting {
                guard observations < 10, ContinuousClock.now < completionDeadline else { throw LensWorksCatalogError.message("The 2048-source workload exceeded its measured 600-second acceptance budget.") }
                let before = try #require(model.importProgress)
                let remaining = completionDeadline - ContinuousClock.now
                let components = remaining.components
                let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
                let allowance = UInt32(clamping: min(milliseconds, 60000))
                guard allowance > 0 else { throw LensWorksCatalogError.message("Import workload observation budget expired.") }
                do { try await model.waitImport(terminal: true, timeoutMilliseconds: allowance) }
                catch LensWorksCatalogError.importObservationTimeout(let observed) {
                    #expect(observed.id == resumed && observed.source == resumedSource)
                    guard observed.id == resumed, observed.source == resumedSource,
                          [.Discovering, .Draining].contains(observed.phase),
                          observed.failed.value == 0,
                          observed.imported.value >= before.imported.value, observed.unchanged.value >= before.unchanged.value,
                          observed.imported.value + observed.unchanged.value > before.imported.value + before.unchanged.value else {
                        throw LensWorksManagedError.protocolViolation("The resumed workload stopped making progress or changed its source/attempt authority.")
                    }
                }
                observations += 1
            }
            #expect(ContinuousClock.now <= completionDeadline)
            #expect(model.importProgress?.id == resumed && model.importProgress?.phase == .Complete)
            #expect(model.importProgress?.failed.value == 0)
            let completed = try #require(model.importProgress)
            #expect(completed.imported.value + completed.unchanged.value == 2048)
            #expect(model.assets.count == 100 && model.hasMore)
            stage = "enumerate 2048 unique photos within 21 actual pages"
            var imageIDs = Set<String>(), photoIDs = Set<String>(), filenames = Set<String>()
            var pages = 0
            while true {
                guard pages < 21 else { throw LensWorksManagedError.protocolViolation("The 2048-photo enumeration exceeded its admitted 21 pages.") }
                pages += 1
                let authority = model.pageAuthority, ids = model.assets.map(\.id)
                guard !ids.isEmpty, ids.count <= 100 else { throw LensWorksManagedError.protocolViolation("The completed import did not publish a bounded, nonempty enumeration page.") }
                for row in model.assets {
                    guard imageIDs.insert(row.id).inserted, photoIDs.insert(row.photoID).inserted,
                          filenames.insert(row.filename).inserted else {
                        throw LensWorksManagedError.protocolViolation("The completed import repeated an image, photo, or filename authority on page \(pages).")
                    }
                }
                if !model.hasMore { break }
                guard pages < 21, await model.nextPage() else { throw LensWorksManagedError.protocolViolation("The completed import failed to advance within its 20 ordinary next-page transitions.") }
                if let error = model.error { throw LensWorksCatalogError.message(error) }
                let next = model.pageAuthority
                guard next.catalogEpoch == authority.catalogEpoch, next.queryEpoch == authority.queryEpoch,
                      next.publication > authority.publication, next.ordinal == authority.ordinal + 1,
                      next.current == authority.next, model.assets.map(\.id) != ids else {
                    throw LensWorksManagedError.protocolViolation("Enumeration changed query ownership or failed to advance its actual admitted page.")
                }
            }
            #expect(pages == 21)
            #expect(imageIDs.count == 2048 && photoIDs.count == 2048 && filenames.count == 2048)
            #expect(model.rowsHighWater <= 100 && model.cursorHistoryCount <= 64)
            } catch {
                let progress = model.importProgress
                throw LensWorksManagedError.protocolViolation("Import fixture stage: \(stage); attempt: \(progress?.id ?? "none"); phase: \(progress?.phase.rawValue ?? "none"); added: \(progress?.imported.value ?? 0); unchanged: \(progress?.unchanged.value ?? 0); failure: \(error)")
            }
        }
    }

    @Test func actualActiveImportClosesThroughThePublicCatalogRetirementReceipt() async throws {
        let fixture = try Fixture(images: 128)
        try await fixture.run { model in
            try await model.startImport(fixture.photos.path)
            try await model.waitImport(terminal: false, minimumImported: 1, phase: "discovering")
            #expect(model.isImporting)
            let attempt = try #require(model.importProgress?.id)
            let checkpointCatalog = try #require(model.catalogPath)
            let (_, token) = try await model.service.context()
            try await model.close()
            #expect(model.catalogPath == nil && !model.isImporting && model.importProgress == nil && model.importSamples.isEmpty)
            #expect(fixture.defaults.data(forKey: "LensWorks.importSource." + checkpointCatalog) != nil)
            await #expect(throws: (any Error).self) { _ = try await model.service.context() }
            await model.connect(fixture.catalog.path)
            #expect(model.error == nil && model.hasImportCheckpoint)
            let (_, reopened) = try await model.service.context()
            #expect(reopened != token && model.importProgress == nil)
            await #expect(throws: (any Error).self) { _ = try await model.service.cancelImport(attempt) }
        }
    }

    @Test func actualLateImportAdmissionCannotPublishAfterCatalogRetirement() async throws {
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let (session, _) = try await model.service.context()
            let key = "LensWorks.importSource." + (try #require(model.catalogPath))
            let checkpoint = fixture.defaults.data(forKey: key)
            let state = try await session.status()
            let pid = try #require(state.pid > 0 ? pid_t(state.pid) : nil)
            let watchdog = Task.detached { do { try await Task.sleep(for: .seconds(10)); _ = kill(pid, SIGCONT) } catch { } }
            var stopped = false
            defer { if stopped { _ = kill(pid, SIGCONT) }; watchdog.cancel() }
            guard kill(pid, SIGSTOP) == 0 else { throw LensWorksCatalogError.message("Owned worker could not be stopped.") }
            stopped = true
            let importing = Task { try await model.startImport(fixture.photos.path) }
            let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try await session.status().pending == 0 {
                guard ContinuousClock.now < admissionDeadline else { throw LensWorksCatalogError.message("Actual import Start did not reach its owned worker.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            let closing = Task { try await model.close() }
            try await Self.wait { model.closingRequested && model.closeInFlight }
            _ = kill(pid, SIGCONT); stopped = false
            await #expect(throws: CancellationError.self) { try await importing.value }
            try await closing.value
            #expect(model.catalogPath == nil && model.importProgress == nil && model.importSamples.isEmpty && !model.isImporting && !model.isBusy)
            #expect(fixture.defaults.data(forKey: key) == checkpoint, "An abandoned Start reply cannot overwrite the durable source checkpoint.")
            await model.connect(fixture.catalog.path)
            #expect(model.error == nil && model.hasImportCheckpoint)
        }
    }

    #if DEBUG
    @Test func actualLateTerminalImportMonitorCannotReplayAfterExplicitCompletion() async throws {
        let fixture = try Fixture(images: 130)
        try await fixture.run { model in
            let gate = ContinuationGate()
            model.continuationFixture = { point in if point == .importMonitorTerminal { await gate.hold() } }
            let watchdog = Task.detached { do { try await Task.sleep(for: .seconds(90)); await gate.release() } catch { } }
            defer { model.continuationFixture = nil; Task { await gate.release() }; watchdog.cancel() }
            try await model.startImport(fixture.photos.path)
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while !(await gate.entered) {
                guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("The real terminal import Status did not reach its finite continuation gate.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.isImporting, "The monitor has not published its actual terminal result yet.")
            try await model.waitImport(terminal: true)
            guard await model.nextPage() else { throw LensWorksCatalogError.message("The post-import second page did not advance.") }
            let page = model.pageAuthority, ids = model.assets.map(\.id), history = model.cursorHistoryCount
            let generation = model.previewGeneration, status = model.status, samples = model.importSamples.count
            let progress = try #require(model.importProgress)
            guard !(await gate.released) else { throw LensWorksCatalogError.message("The finite monitor gate expired before explicit terminal observation and navigation completed.") }
            await gate.release()
            try await model.finishImportMonitorFixture()
            #expect(model.pageAuthority == page && model.assets.map(\.id) == ids && model.cursorHistoryCount == history)
            #expect(model.previewGeneration == generation && model.status == status && model.importSamples.count == samples)
            #expect(model.importProgress?.id == progress.id && model.importProgress?.phase == .Complete && !model.isImporting)
            _ = try await model.thumbnail(try #require(model.assets.first))
        }
        // A genuine monitor-owned completion still refreshes once without an explicit waiter.
        let automatic = try Fixture(images: 3)
        try await automatic.run { model in
            let publication = model.pagePublication
            try await model.startImport(automatic.photos.path)
            try await model.finishImportMonitorFixture()
            #expect(model.importProgress?.phase == .Complete && !model.isImporting && model.error == nil)
            #expect(model.assets.count == 3 && model.pagePublication == publication + 1)
        }
    }

    @Test func actualOrganizationFollowUpsCannotMutateAfterCatalogOrQueryReplacement() async throws {
        for action in ["rename", "delete", "place", "membership"] {
            let fixture = try Fixture(images: 1)
            try await fixture.run { model in
                try await fixture.importPhotos(model)
                try await model.createGroup("Target")
                try await model.createGroup("Parent")
                let target = try model.group(named: "Target"), parent = try model.group(named: "Parent")
                let photo = try #require(model.assets.first), key = try #require(photo.key)
                await model.select(photo)
                #expect(model.selectionCount == 1)
                guard case .Identity(let before) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Actual identity authority is unavailable.") }
                let scope = model.captureScope()
                let gate = ContinuationGate()
                let point: LensWorksCatalogContinuationPoint = action == "membership" ? .membershipIdentity : .groupRead
                model.continuationFixture = { actual in if actual == point { await gate.hold() } }
                let watchdog = Task.detached { do { try await Task.sleep(for: .seconds(90)); await gate.release() } catch { } }
                defer { model.continuationFixture = nil; Task { await gate.release() }; watchdog.cancel() }
                let changing = Task {
                    switch action {
                    case "rename": try await model.renameGroup(target, name: "Must-Not-Rename")
                    case "delete": try await model.deleteGroup(target)
                    case "place": try await model.placeGroup(target, parent: parent.id)
                    default: try await model.setSelectedMembership(target)
                    }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !(await gate.entered) {
                    guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Real decoded organization response did not reach its owned continuation: " + action) }
                    try await Task.sleep(for: .milliseconds(5))
                }
                // Only the Swift continuation is held. Its Collection/Identity result,
                // native CAS revision, and released transport job all came from the worker.
                if action == "membership" {
                    try await model.browse(text: "no-matching-physical-photo")
                    #expect(model.assets.isEmpty && model.selectionCount == 1)
                } else {
                    try await model.close()
                    let cloned = fixture.root.appendingPathComponent("Distinct-Cloned-Catalog")
                    try FileManager.default.copyItem(at: fixture.catalog, to: cloned)
                    await model.connect(cloned.path)
                    #expect(model.error == nil && model.catalogPath != scope.path && model.catalogToken != scope.token)
                    #expect(try model.group(named: "Target").id == target.id, "The distinct catalog deliberately preserves real UUIDs to expose owner recapture.")
                }
                guard !(await gate.released) else { throw LensWorksCatalogError.message("The finite owned continuation fixture expired before scope replacement completed.") }
                await gate.release()
                await #expect(throws: CancellationError.self) { try await changing.value }
                let recovered = try model.group(named: "Target")
                let placement = try #require(model.placements[target.id])
                #expect(recovered.id == target.id && recovered.name == "Target" && recovered.revision == target.revision)
                #expect(placement.parent == nil)
                try await model.browse(collection: target.id)
                #expect(model.assets.isEmpty && !model.hasMore)
                guard case .Identity(let after) = try await model.service.organization(.Identity(key: key)) else { throw LensWorksManagedError.protocolViolation("Actual readback identity is unavailable.") }
                #expect(after.metadata_revision == before.metadata_revision)
                if action != "membership" {
                    try await model.close()
                    await model.connect(fixture.catalog.path)
                    #expect(model.error == nil)
                    let original = try model.group(named: "Target")
                    #expect(original.id == target.id && original.name == "Target" && original.revision == target.revision)
                    let originalPlacement = try #require(model.placements[target.id])
                    #expect(originalPlacement.parent == nil)
                    try await model.browse(collection: target.id)
                    #expect(model.assets.isEmpty && !model.hasMore, "The abandoned continuation cannot mutate either native catalog.")
                }
            }
        }
    }
    private actor PreviewCapacityGate {
        private var tickets: Set<String> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        var ticketCount: Int { tickets.count }
        func hold(_ ticket: String) async {
            guard !released else { return }
            tickets.insert(ticket)
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let owned = waiters; waiters = []
            for waiter in owned { waiter.resume() }
        }
    }
    private actor ContinuationGate {
        private(set) var entered = false
        private(set) var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            guard !released else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume(); continuation = nil
        }
    }
    #endif

    @Test func actualPendingCatalogRetirementKeepsTheSameOwnerForCheckedRetry() async throws {
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let (session, token) = try await model.service.context()
            let before = try await session.status()
            let pid = try #require(before.pid > 0 ? pid_t(before.pid) : nil)
            let watchdog = Task.detached { do { try await Task.sleep(for: .seconds(10)); _ = kill(pid, SIGCONT) } catch { } }
            var stopped = false
            defer { if stopped { _ = kill(pid, SIGCONT) }; watchdog.cancel() }
            guard kill(pid, SIGSTOP) == 0 else { throw LensWorksCatalogError.message("Owned worker could not be stopped.") }
            stopped = true
            let began = ContinuousClock.now
            do {
                try await model.close(retirementTimeoutMilliseconds: 250)
                Issue.record("Stopped actual worker unexpectedly completed public catalog retirement.")
            } catch LensWorksManagedError.native(let code, _) {
                #expect(code == "draining")
            }
            #expect(ContinuousClock.now - began < .seconds(2))
            #expect(model.catalogPath != nil && model.hasImportCheckpoint)
            await #expect(throws: (any Error).self) { _ = try await model.service.context() }
            await #expect(throws: (any Error).self) { _ = try await model.service.managedRequest(.Status) }
            let retained = try await model.service.retirementAuthority()
            #expect(retained.session == session.handle && retained.catalog == token)
            #expect(retained.state.phase == .ready, "Global shutdown must not begin before the public Closed receipt.")
            _ = kill(pid, SIGCONT); stopped = false
            try await model.close()
            #expect(model.catalogPath == nil)
        }
    }

    @Test func actualSettingsRetirementFencesNewCatalogActionsBeforeItsAwaitCompletes() async throws {
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let source = try #require(model.assets.first)
            let (session, token) = try await model.service.context()
            #if DEBUG
            let gate = ContinuationGate()
            model.continuationFixture = { point in if point == .settingsStatus { await gate.hold() } }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate.release() } catch { } }
            defer { watchdog.cancel(); model.continuationFixture = nil }
            // Hold only the owned continuation AFTER the actual settings Status reply
            // was decoded and its job/buffer retired. No worker is stopped or reply fabricated.
            model.resumeSettingsWork()
            let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            do {
                while !(await gate.entered) {
                    guard ContinuousClock.now < admissionDeadline else {
                        throw LensWorksCatalogError.message("Actual settings Status did not reach its owned continuation checkpoint.")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            } catch {
                await gate.release()
                throw error
            }
            let originalPath = model.catalogPath
            let abandonedTarget = fixture.root.appendingPathComponent("Already-Admitted-Must-Not-Open")
            // Structured children cannot escape to Fixture.run's checked cleanup.
            // Release the gate on every primary failure, cancel, then observe BOTH
            // real child completions before propagating the failure for checked retry.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await model.connect(abandonedTarget.path, create: true) }
                do {
                    try await Self.wait { model.isBusy && model.isSettingsWorking }
                    group.addTask { @MainActor in try await model.close() }
                    try await Self.wait { model.closingRequested && model.closeInFlight }
                    #expect(model.isSettingsWorking)
                    let epoch = model.catalogEpoch
                    await model.connect(fixture.root.appendingPathComponent("Must-Not-Open").path, create: true)
                    #expect(model.catalogPath == originalPath && model.catalogEpoch == epoch)
                    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Must-Not-Open").path))
                    await #expect(throws: (any Error).self) { try await model.close() }
                    await #expect(throws: (any Error).self) { try await model.browse(text: "must not replace the retiring query") }
                    await #expect(throws: (any Error).self) { try await model.startImport(fixture.photos.path) }
                    await #expect(throws: (any Error).self) { try await model.createGroup("Must-Not-Create") }
                    await #expect(throws: (any Error).self) { try await model.settings() }
                    await #expect(throws: (any Error).self) { _ = try await model.thumbnail(source) }
                    await #expect(throws: (any Error).self) { _ = try await model.service.context() }
                    await #expect(throws: (any Error).self) { _ = try await model.service.open(fixture.root.appendingPathComponent("Must-Not-Open").path, create: true) }
                    let retained = try await model.service.retirementAuthority()
                    #expect(retained.session == session.handle && retained.catalog == token && retained.state.phase == .ready)
                    #expect(retained.job == nil, "Public Close is not submitted before the captured settings task retires.")
                    await gate.release()
                    while !group.isEmpty { _ = try await group.next() }
                } catch {
                    let primary = error
                    await gate.release()
                    group.cancelAll()
                    var secondary: [String] = []
                    while !group.isEmpty {
                        do { _ = try await group.next() }
                        catch { secondary.append(String(describing: error)) }
                    }
                    if !secondary.isEmpty {
                        throw LensWorksManagedError.protocolViolation("Settings overlap failed: \(primary); observed child retirement: \(secondary.joined(separator: "; "))")
                    }
                    throw primary
                }
            }
            #expect(!FileManager.default.fileExists(atPath: abandonedTarget.path))
            #expect(!model.closingRequested && !model.closeInFlight && !model.isSettingsWorking && !model.isBusy && model.catalogPath == nil)
            await model.connect(fixture.catalog.path)
            #expect(model.error == nil && model.assets.count == 1)
            #else
            throw LensWorksManagedError.protocolViolation("The real settings continuation fixture requires DEBUG observation support.")
            #endif
        }
    }

    #if DEBUG
    /// Only the owned client boundary is faulted. Catalog Close, result bytes, jobs,
    /// and final checked shutdown all come from the actual retained worker.
    @Test func actualCatalogRetirementRetainsAuthorityAcrossOwnedClientFaults() async throws {
        for point in [LensWorksCatalogCloseFaultPoint.beforeSubmit, .beforeDecode, .beforeRelease] {
            let fixture = try Fixture(images: 1)
            let fault = OneShotCloseFault(point)
            let service = LensWorksCatalogService(configuration: fixture.config, closeFault: { try fault.intervene($0) })
            try await fixture.run(catalogService: service) { model in
                try await fixture.importPhotos(model)
                let source = try #require(model.assets.first)
                let before = try await service.retirementAuthority()
                do {
                    try await model.close()
                    Issue.record("The one-shot owned close boundary fault did not fire.")
                } catch LensWorksManagedError.native(let code, _) { #expect(code == "resource_limit") }
                let retained = try await service.retirementAuthority()
                #expect(retained.session == before.session && retained.catalog == before.catalog && model.catalogPath != nil)
                if point == .beforeSubmit { #expect(retained.job == nil && !retained.resultTaken) }
                else { #expect(retained.job != nil && retained.resultTaken) }
                #expect(retained.verifiedClosed == (point == .beforeRelease))
                #expect(retained.state.phase == .ready && model.closingRequested && !model.closeInFlight)
                await #expect(throws: (any Error).self) { _ = try await service.context() }
                await #expect(throws: (any Error).self) { _ = try await service.managedRequest(.Status) }
                await #expect(throws: (any Error).self) { _ = try await service.preview(source) }
                await service.resumePreviews()
                await #expect(throws: (any Error).self) { _ = try await service.preview(source) }
                try await model.close()
                #expect(model.catalogPath == nil && fault.fired && !model.closingRequested)
                await #expect(throws: (any Error).self) { _ = try await service.retirementAuthority() }
            }
        }
    }
    nonisolated private final class OneShotCloseFault: @unchecked Sendable {
        private let lock = NSLock()
        private let point: LensWorksCatalogCloseFaultPoint
        private var didFire = false
        init(_ point: LensWorksCatalogCloseFaultPoint) { self.point = point }
        var fired: Bool { lock.withLock { didFire } }
        func intervene(_ actual: LensWorksCatalogCloseFaultPoint) throws {
            try lock.withLock {
                if actual == point && !didFire {
                    didFire = true
                    throw LensWorksManagedError.native(code: "resource_limit", message: "One-shot owned-client boundary fault; backend result is unchanged.")
                }
            }
        }
    }
    #endif

    @Test func actualFailedCatalogAdmissionRetiresBeforeOpeningAnotherCatalog() async throws {
        let fixture = try Fixture(images: 1)
        try await fixture.run { model in
            try await fixture.importPhotos(model)
            let missing = fixture.root.appendingPathComponent("Missing-Catalog")
            await model.connect(missing.path)
            #expect(model.error != nil && model.catalogPath == nil)
            // The missing directory above is an adapter-preflight rejection. This
            // separate, private regular database reaches retained native admission.
            let malformed = fixture.root.appendingPathComponent("Malformed-Catalog")
            try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
            let database = malformed.appendingPathComponent("catalog.sqlite3")
            let malformedBytes = Data("deliberately malformed owned SQLite fixture".utf8)
            try malformedBytes.write(to: database)
            let direct = try await LWManagedSession.create(config: fixture.config)
            do {
                await #expect(throws: (any Error).self) { _ = try await direct.perform(.OpenExisting(path: LWCatalogNativePath(fileURL: malformed))) }
                let response = try await direct.perform(.Status)
                guard case .Status(let status) = response else { throw LensWorksManagedError.protocolViolation("Retained failed admission did not return its actual status.") }
                guard status.phase == .Failed && status.catalog == nil else { throw LensWorksManagedError.protocolViolation("Native bootstrap failure did not certify Failed/nil cleanup: \(status)") }
                try await direct.close()
            } catch {
                // Keep this owner and its fixture diagnosable until checked cleanup.
                do {
                    guard case .Status(let status) = try await direct.perform(.Status) else { throw LensWorksManagedError.protocolViolation("Native cleanup status is unavailable.") }
                    if let token = status.catalog {
                        guard case .Status(let closed) = try await direct.perform(.Close(catalog: token)), closed.phase == .Closed, closed.catalog == nil else { throw LensWorksManagedError.protocolViolation("Native admission still retains cleanup authority.") }
                    } else {
                        guard [.Closed, .Failed].contains(status.phase) else { throw LensWorksManagedError.protocolViolation("No-token admission retirement remains uncertified.") }
                    }
                    try await direct.close()
                } catch { throw LensWorksManagedError.protocolViolation("Malformed native admission cleanup failed; retain \(fixture.root.path): \(error)") }
                throw error
            }
            await model.connect(malformed.path)
            #expect(model.error != nil && model.catalogPath == nil)
            #expect(!model.closingRequested, "Wrapper recovery must consume actual Failed/nil cleanup and finish checked shutdown.")
            #expect(try Data(contentsOf: database) == malformedBytes)
            let replacement = fixture.root.appendingPathComponent("Replacement-Catalog")
            await model.connect(replacement.path, create: true)
            #expect(model.error == nil && model.catalogPath != nil)
            try await model.startImport(fixture.photos.path)
            try await model.waitImport(terminal: true)
            #expect(model.assets.count == 1)
            try await model.close()
            await model.connect(fixture.catalog.path)
            #expect(model.error == nil && model.assets.count == 1)
        }
    }

    /// S04 AC3: on a 100,000-photo catalog, scrolling, selection (including shift-range
    /// across pages) and the catalog -> editor/filmstrip transition only ever hold one
    /// bounded page of rows; nothing materializes the whole catalog.
    @Test func largeSyntheticCatalogNavigationSelectionAndEditorTransitionStayWindowed() async throws {
        let photos = 100_000, pageRows = 100
        let fixture = try Fixture(images: 1)
        try fixture.prepareSyntheticCatalog(count: photos)
        try await fixture.run(create: false) { model in
            @MainActor func checkWindow() {
                #expect(model.assets.count <= pageRows)
                #expect(Set(model.assets.map(\.id)).count == model.assets.count)
                #expect(model.selection.count <= pageRows)
                #expect(model.cursorHistoryCount <= LensWorksCursorWindow.capacity)
            }
            /// Runs one page transition and requires it to issue exactly one bounded catalog fetch.
            @MainActor func singleFetch(_ step: () async -> Bool) async -> Bool {
                let before = await model.service.browseCalls
                let moved = await step()
                #expect(await model.service.browseCalls - before == 1)
                #expect(await model.service.browseLimitHighWater <= UInt16(pageRows))
                return moved
            }
            #expect(model.assets.count == pageRows && model.hasMore)
            checkWindow()

            // Scroll 150 pages (15,000 photos) deep. Every page is a fresh bounded fetch
            // that continues strictly after the previous one.
            var firstIDs: [Int64: String] = [0: try #require(model.assets.first?.id)]
            var lastSequence = try #require(model.assets.last?.sequence)
            let started = ContinuousClock.now
            for page in 1...150 {
                #expect(await singleFetch { await model.nextPage() })
                checkWindow()
                #expect(model.assets.count == pageRows)
                let first = try #require(model.assets.first)
                #expect(first.sequence > lastSequence)
                lastSequence = try #require(model.assets.last?.sequence)
                firstIDs[Int64(page)] = first.id
            }
            let deepScroll = ContinuousClock.now - started
            #expect(deepScroll < .seconds(120), "150 windowed pages took \(deepScroll)")
            // Scrolling back re-fetches exactly the earlier windows.
            for page in stride(from: 149, through: 140, by: -1) {
                #expect(await singleFetch { await model.previousPage() })
                checkWindow()
                #expect(model.assets.first?.id == firstIDs[Int64(page)])
            }

            // Shift-range selection spanning four pages stays disk-backed; only the
            // visible page is projected into memory.
            let anchor = model.assets[10]
            await model.select(anchor)
            #expect(model.selectionCount == 1)
            for _ in 0..<3 { #expect(await singleFetch { await model.nextPage() }) }
            await model.select(model.assets[20], range: true)
            #expect(model.error == nil)
            #expect(model.selectionCount == Int64((pageRows - 10) + 2 * pageRows + 21))
            #expect(model.selection.count == 21)
            checkWindow()
            await model.clearSelection()
            #expect(model.selectionCount == 0)

            // Keyboard navigation across a page boundary fetches only the next window.
            await model.select(try #require(model.assets.last))
            let beforeBoundary = model.pageAuthority.ordinal
            _ = await singleFetch { await model.moveSelection(1, range: false); return true }
            #expect(model.pageAuthority.ordinal == beforeBoundary + 1)
            #expect(model.selectedPhotoID == model.assets.first?.id)
            checkWindow()

            // Catalog -> editor transition on the one real photo (newest sequence) keeps the
            // grid/filmstrip window unchanged and never re-fetches or widens it.
            try await fixture.importPhotos(model)
            await model.setBrowseOrder(sort: .Sequence, direction: .Descending)
            let real = try #require(model.assets.first)
            #expect(real.filename.hasSuffix("Photo-0000.png"))
            checkWindow()
            await model.select(real)
            let output = fixture.root.appendingPathComponent("Versions")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            await model.setOutput(output.path)
            let page = model.pageAuthority, rows = model.assets.map(\.id)
            let fetchesBeforeEditor = await model.service.browseCalls
            let workspace = ProjectWorkspace()
            await model.createWorkingVersion(workspace: workspace)
            #expect(model.error == nil && !model.showingCatalog)
            #expect(workspace.current.session.document != nil)
            #expect(model.pageAuthority == page && model.assets.map(\.id) == rows)
            // Filmstrip selection inside the editor moves within the same window.
            await model.moveSelection(1, range: false)
            #expect(model.selectedPhotoID == rows[1] && model.pageAuthority == page)
            model.showingCatalog = true
            #expect(model.pageAuthority == page && model.assets.map(\.id) == rows)
            #expect(await model.service.browseCalls == fetchesBeforeEditor, "the editor transition must not re-fetch the window")
            checkWindow()

            let previews = await model.service.previewMetrics()
            #expect(previews.cacheEntriesHighWater <= LensWorksPreviewStore.maximumEntries)
        }
    }

    @Test func indexedVersionsAndSelectionRemainPagedAndRecoverCorruptRecord() async throws {
        let fixture = try Fixture(images: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let index = LensWorksCatalogIndex(url: fixture.root.appendingPathComponent("Index.sqlite3"))
        for number in 0..<205 {
            let url = try fixture.package(photo: "photo", variant: "master", catalog: fixture.catalog.path, name: String(format: "%03d.comp", number))
            try await index.register(url)
        }
        let first = try await index.versions(catalog: fixture.catalog.path, photo: "photo", variant: "master")
        #expect(first.versions.count == 100 && first.next != nil)
        let second = try await index.versions(catalog: fixture.catalog.path, photo: "photo", variant: "master", after: first.next)
        let third = try await index.versions(catalog: fixture.catalog.path, photo: "photo", variant: "master", after: second.next)
        #expect(second.versions.count == 100 && third.versions.count == 5 && third.next == nil)
        #expect(Set((first.versions + second.versions + third.versions).map(\.id)).count == 205)
        let corrupt = try #require(first.versions.first)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: corrupt.projectPath).appendingPathComponent("LensWorks.json"))
        let recovered = try await index.versions(catalog: fixture.catalog.path, photo: "photo", variant: "master")
        #expect(recovered.versions.count == 99 && recovered.errors.count == 1 && recovered.next != nil)
        let copy = try fixture.package(photo: "photo", variant: "copy", catalog: fixture.catalog.path, name: "copy.comp")
        try await index.register(copy)
        #expect(try await index.versions(catalog: fixture.catalog.path, photo: "photo", variant: "copy").versions.count == 1)
        try await index.beginVisits(owner: "query")
        for page in 0..<70 {
            let rows = (0..<100).map { item in LensWorksSelectedRow(imageID: String(format: "%06d", page * 100 + item), key: .init(asset_id: "photo-\(page * 100 + item)", variant_id: "master")) }
            try await index.rememberPage(owner: "query", page: Int64(page), rows: rows)
        }
        try await index.selectRange(owner: "selection", query: "query", anchor: "000050", end: "006999", replacing: true)
        let (projection, count) = try await index.selectionProjection(owner: "selection", images: ["000050", "006999"])
        #expect(projection.count == 2 && count == 6950)
        #expect(try await index.selection(owner: "selection").count == 100)
        await #expect(throws: (any Error).self) {
            try await index.setSelection(owner: "selection", rows: [LensWorksSelectedRow(imageID: "bad\0image", key: .init(asset_id: "photo", variant_id: "master"))], replace: false)
        }
        try await index.clearSelection(owner: "selection"); try await index.clearVisits(owner: "query")
        #expect(try await index.selectionProjection(owner: "selection", images: []).1 == 0)
        await #expect(throws: (any Error).self) { try await index.rememberPage(owner: "query", page: 0, rows: [LensWorksSelectedRow(imageID: "late", key: .init(asset_id: "photo", variant_id: "master"))]) }
    }

    @Test func explicitLegacyReconciliationRetainsUnresolvedPathsAndReadsSchemaOneMaster() async throws {
        let fixture = try Fixture(images: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let index = LensWorksCatalogIndex(url: fixture.root.appendingPathComponent("LegacyIndex.sqlite3"))
        let legacy = try fixture.package(photo: "photo", variant: "master", catalog: fixture.catalog.path, name: "legacy.comp")
        let metadata = legacy.appendingPathComponent("LensWorks.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object.removeValue(forKey: "originalVariantKey")
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        #expect(try LensWorksWorkingVersion.read(from: legacy)?.sourceVariantID == "master")
        let generic = fixture.root.appendingPathComponent("generic.comp")
        try FileManager.default.createDirectory(at: generic, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: generic.appendingPathComponent("manifest.json"))
        let paths = [legacy.path, generic.path]
        fixture.defaults.set(paths, forKey: "LensWorks.workingVersions")
        let failures = await index.migrateLegacyDefaults(defaults: fixture.defaults)
        #expect(failures.contains { $0.contains("generic.comp") })
        #expect(fixture.defaults.stringArray(forKey: "LensWorks.workingVersions") == paths)
        #expect(try await index.versions(catalog: fixture.catalog.path, photo: "photo", variant: "master").versions.count == 1)
        fixture.defaults.set([legacy.path], forKey: "LensWorks.workingVersions")
        #expect(await index.migrateLegacyDefaults(defaults: fixture.defaults, retry: true).isEmpty)
        #expect(fixture.defaults.object(forKey: "LensWorks.workingVersions") == nil)
        let invalid = try fixture.package(photo: "photo", variant: "master", catalog: fixture.catalog.path, name: "empty-catalog.comp")
        let invalidMetadata = invalid.appendingPathComponent("LensWorks.json")
        var bad = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: invalidMetadata)) as? [String: Any])
        bad["catalogPath"] = ""
        try JSONSerialization.data(withJSONObject: bad).write(to: invalidMetadata)
        #expect(throws: (any Error).self) { try LensWorksWorkingVersion.read(from: invalid) }
        let oversized = try fixture.package(photo: "photo", variant: "master", catalog: fixture.catalog.path, name: "oversized.comp")
        try Data(repeating: 32, count: 65537).write(to: oversized.appendingPathComponent("LensWorks.json"))
        #expect(throws: (any Error).self) { try LensWorksWorkingVersion.read(from: oversized) }
        let fifo = try fixture.package(photo: "photo", variant: "master", catalog: fixture.catalog.path, name: "fifo.comp")
        let fifoMetadata = fifo.appendingPathComponent("LensWorks.json")
        try FileManager.default.removeItem(at: fifoMetadata)
        #expect(mkfifo(fifoMetadata.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try LensWorksWorkingVersion.read(from: fifo) }
    }

    @Test func metadataIndexRefusesOriginalLinksAndRedirectedParentBeforeCreatingChildren() async throws {
        let fixture = try Fixture(images: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try #require(fixture.sources.keys.first), before = try Data(contentsOf: source)
        for link in [false, true] {
            let url = fixture.root.appendingPathComponent(link ? "hard.sqlite3" : "symbolic.sqlite3")
            if link { try FileManager.default.linkItem(at: source, to: url) }
            else { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source) }
            let index = LensWorksCatalogIndex(url: url)
            await #expect(throws: (any Error).self) { try await index.clearSelection(owner: "refused") }
            #expect(try Data(contentsOf: source) == before)
        }
        let parent = fixture.root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.photos)
        let index = LensWorksCatalogIndex(url: parent.appendingPathComponent("Uncreated/index.sqlite3"))
        await #expect(throws: (any Error).self) { try await index.clearSelection(owner: "refused") }
        #expect(!FileManager.default.fileExists(atPath: fixture.photos.appendingPathComponent("Uncreated").path))
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func cursorHistoryEvictsAuthoritiesWithoutRetainingRows() {
        var window = LensWorksCursorWindow()
        for number in 1...128 { window.next = String(number); _ = window.advance() }
        #expect(window.previous.count == 64 && window.current == "128")
        for _ in 0..<32 { _ = window.retreat() }
        #expect(window.current == "96" && window.previous.count == 32)
        window.reset(); #expect(window.previous.isEmpty && window.current == nil && window.next == nil)
    }

    nonisolated private struct PreviewExperimentOutcome: Codable, Sendable {
        let imageID: String
        let outcome: String
        let encodedSHA256: String?
    }
    @MainActor private final class Fixture {
        let root: URL, photos: URL, catalog: URL
        let config: LWManagedSessionConfig
        let defaults: UserDefaults
        let sources: [URL: Data]
        var diagnosticStage = "fixture admission"
        private var previewCheckpoints: [[String: Any]] = []
        var preserveSuccessEvidence = false
        var comparisonSourceHashes: [URL: String]?
        private var comparisonPreviewTasks: [Task<Void, Never>] = []
        private var comparisonPreviewReplies: [Result<PreviewExperimentOutcome, any Error>?] = []
        private var comparisonAdmissionObservation: [String: Int] = [:]
        init(images: Int, scanRows: UInt = 512, previewRequests: UInt? = nil) throws {
            let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
            root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWBrowser-\(UUID())")
            photos = root.appendingPathComponent("Photos"); catalog = root.appendingPathComponent("Catalog")
            let nested = photos.appendingPathComponent("Nested/Photos café")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            var originals: [URL: Data] = [:]
            for number in 0..<images {
                let folder = number < 2 ? photos : (number % 2 == 0 ? photos.appendingPathComponent("Nested") : nested)
                let path = folder.appendingPathComponent(String(format: "Photo-%04d.png", number))
                let data = try Self.png(red: UInt8(32 + number % 192))
                try data.write(to: path); originals[path] = data
            }
            sources = originals
            defaults = try #require(UserDefaults(suiteName: "LWBrowser-\(UUID())"))
            let worker = try #require(ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"], "Explicit retained fixture helper is required.")
            let decode = ProcessInfo.processInfo.environment["LW_CATALOG_TEST_DECODE_WORKER"] ?? worker
            config = LWManagedSessionConfig(worker_executable: try LWCatalogNativePath(fileURL: URL(fileURLWithPath: worker)), decode_worker_executable: try LWCatalogNativePath(fileURL: URL(fileURLWithPath: decode)), cache_root: try LWCatalogNativePath(fileURL: root.appendingPathComponent("Cache")), original_roots: [try LWCatalogNativePath(fileURL: photos)], limits: LWApplicationLimits(queued: 128, request_bytes: 1048576, reply_bytes: 1048576, page_rows: UInt16(min(100, scanRows)), scan_rows: scanRows, page_bytes: 131072, tickets: 128, ttl_seconds: 60, binary_bytes: 16777216), preview_policy: nil, preview_limits: previewRequests.map { requests in
                // Exact frozen PreviewService::default (service.rs95–113), with only
                // its public requests admission budget changed for this experiment.
                let mib: UInt64 = 1024 * 1024
                return LWPreviewServiceServiceLimits(requests: requests, workers: 1, working_bytes: 3 * 1024 * mib,
                    per_worker_bytes: 2164 * mib, cache_header_scratch_bytes: mib, cache_codec_scratch_bytes: 8 * mib,
                    decode_limits: LWMediaFullDecodeLimits(max_encoded_bytes: 256 * mib, max_intermediate_pixels: 32_000_000, max_allocation_bytes: 768 * mib),
                    encoded_staging_bytes: 32 * mib, per_worker_encoded_bytes: 8 * mib,
                    decoded_cache_bytes: 256 * mib, decoded_live_bytes: 256 * mib, decoded_entries: 400,
                    prepared_cache_bytes: 256 * mib, prepared_cache_entries: 16)
            })
        }
        private static func png(red: UInt8) throws -> Data {
            let pixels = Data([red, 16, 8, 255])
            let provider = try #require(CGDataProvider(data: pixels as CFData))
            let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw LensWorksCatalogError.message("Fixture PNG encoding failed.") }
            return data as Data
        }
        /// Seeds `catalog` with the engine's official synthetic organization fixture
        /// (organization_probe prepare): normalized catalog rows, no image files.
        func prepareSyntheticCatalog(count: Int) throws {
            let environment = ProcessInfo.processInfo.environment
            let worker = try #require(environment["LW_CATALOG_TEST_WORKER"])
            let probe = environment["LW_CATALOG_TEST_ORGANIZATION_PROBE"]
                ?? URL(fileURLWithPath: worker).deletingLastPathComponent().appendingPathComponent("organization_probe").path
            guard FileManager.default.isExecutableFile(atPath: probe) else {
                throw LensWorksCatalogError.message("organization_probe is required next to LW_CATALOG_TEST_WORKER or via LW_CATALOG_TEST_ORGANIZATION_PROBE: \(probe)")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: probe)
            process.arguments = ["--catalog", catalog.path, "--output", root.appendingPathComponent("synthetic-prepare.json").path, "prepare", "--count", String(count)]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LensWorksCatalogError.message("organization_probe prepare exited \(process.terminationStatus)") }
        }
        func run(create: Bool = true, catalogService: LensWorksCatalogService? = nil, _ body: (LensWorksCatalog) async throws -> Void) async throws {
            let model = LensWorksCatalog(configuration: config, index: LensWorksCatalogIndex(url: root.appendingPathComponent("Index.sqlite3")), defaults: defaults, migrateLegacy: false, catalogService: catalogService)
            await model.connect(catalog.path, create: create)
            do {
                if let error = model.error { throw LensWorksCatalogError.message(error) }
                try await body(model)
                if let error = model.error { throw LensWorksCatalogError.message(error) }
                try await model.close()
                for (source, before) in sources { #expect(try Data(contentsOf: source) == before) }
                try checkComparisonSources()
                if preserveSuccessEvidence {
                    let destination = root.appendingPathComponent("public-request-budget-experiment.json")
                    if FileManager.default.fileExists(atPath: destination.path) {
                        var report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
                        report["checkedClosed"] = true; report["originalSHA256VerifiedAfterCheckedClose"] = true
                        try writeComparison(report)
                    }
                    print("Checked-closed public request-budget experiment evidence retained at \(root.path). Production policy unchanged.")
                } else { try FileManager.default.removeItem(at: root) }
            } catch {
                let primary = error
                cancelComparisonPreviews()
                await recordFailure(model, stage: "before checked cleanup", error: primary)
                do { try await model.close() }
                catch {
                    await recordFailure(model, stage: "checked cleanup failed", error: error)
                    throw LensWorksManagedError.protocolViolation("Fixture: \(primary); checked cleanup: \(error). Live authority and diagnostics preserved at \(root.path)")
                }
                throw LensWorksManagedError.protocolViolation("Fixture: \(primary). Failed fixture and diagnostics preserved at \(root.path)")
            }
        }
        var comparisonPreviewDescriptions: [String] {
            comparisonPreviewReplies.map { reply in
                guard let reply else { return "pending retained preview task" }
                switch reply { case .success(let value): return value.outcome + ":" + value.imageID
                case .failure(let error): return "FAILED:" + String(describing: error) }
            }
        }
        func cancelComparisonPreviews() { for task in comparisonPreviewTasks { task.cancel() } }
        func observeFourPreviews(_ model: LensWorksCatalog, rows: [LensWorksCatalogAsset], expectPaused: Bool, expectCapacity: Bool = false) async throws -> [PreviewExperimentOutcome] {
            guard rows.count == 4, Set(rows.map(\.id)).count == 4, comparisonPreviewTasks.isEmpty, !(expectPaused && expectCapacity) else { throw LensWorksManagedError.protocolViolation("The comparison requires one bounded set of four actual preview producers.") }
            #if DEBUG
            let gate = expectCapacity ? PreviewCapacityGate() : nil
            if let gate { try await model.service.setAdmittedPreviewFixture { await gate.hold($0) } }
            let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await gate?.release() } catch { } }
            defer { watchdog.cancel() }
            #else
            guard !expectCapacity else { throw LensWorksManagedError.protocolViolation("The deterministic capacity fixture requires DEBUG observation support.") }
            #endif
            comparisonPreviewReplies = Array(repeating: nil, count: 4)
            comparisonAdmissionObservation = [:]
            var heldAdmissions = 0
            do {
            for (index, row) in rows.enumerated() {
                comparisonPreviewTasks.append(Task { [self] in
                    do {
                        let value = try await model.thumbnail(row)
                        guard !expectPaused, value.cost > 0 else { throw LensWorksManagedError.protocolViolation("The expected producer admission policy did not match real preview publication.") }
                        comparisonPreviewReplies[index] = .success(PreviewExperimentOutcome(imageID: row.id, outcome: "ready", encodedSHA256: LensWorksCatalogBrowserTests.hash(value.data)))
                    } catch LensWorksCatalogError.message(let message) where expectPaused && message == "Previews are paused for storage maintenance." {
                        comparisonPreviewReplies[index] = .success(PreviewExperimentOutcome(imageID: row.id, outcome: "explicitly_paused", encodedSHA256: nil))
                    } catch LensWorksManagedError.native(let code, let message) where expectCapacity && code == "native" && message == "preview request allowance exhausted" {
                        comparisonPreviewReplies[index] = .success(PreviewExperimentOutcome(imageID: row.id, outcome: "capacity_rejected", encodedSHA256: nil))
                    } catch { comparisonPreviewReplies[index] = .failure(error) }
                })
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            #if DEBUG
            if let gate {
                let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while true {
                    if let failed = comparisonPreviewReplies.compactMap({ $0 }).first(where: { if case .failure = $0 { return true }; return false }) { _ = try failed.get() }
                    let replies = comparisonPreviewReplies.compactMap { try? $0?.get() }
                    let admitted = await gate.ticketCount
                    let rejected = replies.filter({ $0.outcome == "capacity_rejected" }).count
                    let ready = replies.filter({ $0.outcome == "ready" }).count
                    comparisonAdmissionObservation = ["admittedPreviewReplyHooks": admitted, "exactCapacityRejections": rejected, "completedReadyPayloads": ready, "completedCallReplies": replies.count]
                    // take_read can retire native capacity before PreviewBytes. This
                    // gate observes actual client replies, not still-charged native slots.
                    if (1...4).contains(admitted), admitted + replies.count == 4 { heldAdmissions = admitted; break }
                    try Task.checkCancellation()
                    guard ContinuousClock.now < admissionDeadline else { throw LensWorksManagedError.protocolViolation("Four distinct actual call admissions/outcomes were not observed within 5 seconds; retained callback counts are recorded separately from native slot ownership.") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let held = await model.service.previewMetrics()
                guard held.active == heldAdmissions, held.activeHighWater == 4, held.pending == 0 else { throw LensWorksManagedError.protocolViolation("The four distinct calls did not reach the observed client continuation or a real terminal outcome.") }
                await gate.release()
            }
            #endif
            while comparisonPreviewReplies.contains(where: { if case nil = $0 { return true }; return false }) {
                if let failed = comparisonPreviewReplies.compactMap({ $0 }).first(where: { if case .failure = $0 { return true }; return false }) {
                    cancelComparisonPreviews(); _ = try failed.get()
                }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    cancelComparisonPreviews()
                    throw LensWorksCatalogError.message("The four owned preview tasks remain retained after their finite 60-second comparison observation.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let replies = try comparisonPreviewReplies.compactMap { try $0?.get() }
            guard replies.count == 4 else { throw LensWorksManagedError.protocolViolation("The comparison lost a real preview outcome.") }
            guard Set(replies.map(\.imageID)) == Set(rows.map(\.id)) else { throw LensWorksManagedError.protocolViolation("The comparison repeated or lost an actual photo outcome.") }
            if expectCapacity {
                let ready = replies.filter({ $0.outcome == "ready" && $0.encodedSHA256?.count == 64 }).count
                let rejected = replies.filter({ $0.outcome == "capacity_rejected" && $0.encodedSHA256 == nil }).count
                guard (1...4).contains(heldAdmissions), ready > 0, ready + rejected == 4 else {
                    throw LensWorksManagedError.protocolViolation("The four actual calls must produce checked payloads or the exact capacity rejection; no other error or fabricated negative is accepted.")
                }
            }
            for task in comparisonPreviewTasks { await task.value }
            #if DEBUG
            await gate?.release()
            if expectCapacity { try await model.service.setAdmittedPreviewFixture(nil) }
            #endif
            comparisonPreviewTasks = []
            let retired = await model.service.previewMetrics()
            guard retired.active == 0, retired.pending == 0 else { throw LensWorksManagedError.protocolViolation("The four tasks/tickets did not retire after their actual receipts.") }
            return replies
            } catch {
                #if DEBUG
                await gate?.release()
                if expectCapacity {
                    do { try await model.service.setAdmittedPreviewFixture(nil) }
                    catch let cleanup { cancelComparisonPreviews(); throw LensWorksCatalogError.message("Comparison failed: \(error); fixture cleanup failed: \(cleanup)") }
                }
                #endif
                cancelComparisonPreviews()
                throw error // Existing Fixture.run retains failure roots and performs checked retirement.
            }
        }
        func checkComparisonSources() throws {
            guard let comparisonSourceHashes else { return }
            for (source, expected) in comparisonSourceHashes {
                guard LensWorksCatalogBrowserTests.hash(try Data(contentsOf: source)) == expected else { throw LensWorksManagedError.protocolViolation("An experiment original changed: " + source.path) }
            }
        }
        func writeComparison(_ report: [String: Any]) throws {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard bytes.count <= 128 * 1024 else { throw LensWorksManagedError.protocolViolation("Public request-budget diagnostics exceeded their finite artifact allowance.") }
            try bytes.write(to: root.appendingPathComponent("public-request-budget-experiment.json"), options: .atomic)
        }
        func previewCheckpoint(_ model: LensWorksCatalog, stage: String) async {
            diagnosticStage = stage
            let authority = model.pageAuthority, generation = model.previewGeneration
            let metrics = await model.service.previewMetrics()
            let row: [String: Any] = ["stage": stage, "time": Date().timeIntervalSince1970,
                "catalogEpoch": authority.catalogEpoch, "queryEpoch": authority.queryEpoch, "pagePublication": authority.publication,
                "pageOrdinal": authority.ordinal, "previewGenerationBefore": generation, "previewGenerationAfter": model.previewGeneration,
                "rowCount": model.assets.count, "firstImageID": model.assets.first?.id ?? "", "lastImageID": model.assets.last?.id ?? "",
                "metrics": (try? JSONSerialization.jsonObject(with: LWCatalogCodec.encode(metrics))) ?? "unavailable"]
            if previewCheckpoints.count >= 8 { previewCheckpoints.removeFirst() }
            previewCheckpoints.append(row)
        }
        private func recordFailure(_ model: LensWorksCatalog, stage: String, error: any Error) async {
            let authority = model.pageAuthority
            var evidence: [String: Any] = ["stage": stage, "fixtureStage": diagnosticStage, "failure": String(describing: error), "catalogPath": model.catalogPath ?? "none", "time": Date().timeIntervalSince1970,
                "catalogEpoch": authority.catalogEpoch, "queryEpoch": authority.queryEpoch, "pagePublication": authority.publication,
                "pageOrdinal": authority.ordinal, "currentCursor": authority.current ?? "none", "nextCursor": authority.next ?? "none",
                "previewGeneration": model.previewGeneration, "rowCount": model.assets.count, "hasMore": model.hasMore,
                "previewCheckpoints": previewCheckpoints, "comparisonPreviewTasks": comparisonPreviewDescriptions, "comparisonAdmissionObservation": comparisonAdmissionObservation]
            do {
                evidence["previewMetrics"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(await model.service.previewMetrics()))
                if let progress = model.importProgress { evidence["import"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(progress)) }
                evidence["importSamples"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(model.importSamples))
                do {
                    let retained = try await model.service.retirementAuthority()
                    evidence["catalogToken"] = retained.catalog ?? "none"
                    let status = retained.state
                    evidence["session"] = ["phase": status.phase.rawValue, "pending": status.pending, "outcome_unknown": status.outcome_unknown, "message": status.message ?? "", "pid": status.pid] as [String: Any]
                } catch { evidence["sessionStatusError"] = String(describing: error) }
                let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                let destination = root.appendingPathComponent(stage == "before checked cleanup" ? "failure-before-close.json" : "failure-after-close.json")
                try await Task.detached(priority: .utility) { try bytes.write(to: destination, options: .atomic) }.value
            } catch { print("Fixture diagnostic could not be retained at \(root.path): \(error)") }
        }
        func importPhotos(_ model: LensWorksCatalog) async throws {
            try await model.startImport(photos.path); try await awaitImportCompletion(model)
            #expect(model.importProgress?.failed.value == 0)
        }
        /// Observes the owned import to its end through the public (at most 60-second) observation windows. A window
        /// that closes before the import ends must show the same attempt and source still making forward progress, so
        /// a stalled import fails while a host slowed by parallel tests or CI builds only needs more windows.
        func awaitImportCompletion(_ model: LensWorksCatalog) async throws {
            let attempt = try #require(model.importProgress)
            while true {
                let before = try #require(model.importProgress)
                do { try await model.waitImport(terminal: true); return }
                catch LensWorksCatalogError.importObservationTimeout(let observed) {
                    let advanced = observed.imported.value + observed.unchanged.value > before.imported.value + before.unchanged.value
                        || (before.phase == .Discovering && observed.phase == .Draining)
                        || (observed.phase == .Draining && observed.pending_previews < before.pending_previews)
                    guard observed.id == attempt.id, observed.source == attempt.source,
                          [.Discovering, .Draining].contains(observed.phase), observed.failed.value == 0, advanced else {
                        throw LensWorksCatalogError.importObservationTimeout(observed)
                    }
                }
            }
        }
        // Index tests need only the actual native identity format; layer serialization is covered
        // separately by LensWorksCatalogTests' real ProjectStore save/reopen fixtures.
        func package(photo: String, variant: String, catalog: String, name: String) throws -> URL {
            let project = root.appendingPathComponent("Versions").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let source = try #require(sources.keys.first)
            let record = LensWorksWorkingVersion(id: UUID(), photoID: photo, catalogPath: catalog, originalPath: source.path, projectPath: project.path, name: name, originalVariantKey: .init(asset_id: photo, variant_id: variant))
            try record.encoded().write(to: project.appendingPathComponent("LensWorks.json"))
            try JSONEncoder().encode(["workingVersionID": record.id.uuidString]).write(to: project.appendingPathComponent("manifest.json"))
            return project
        }
    }
}
