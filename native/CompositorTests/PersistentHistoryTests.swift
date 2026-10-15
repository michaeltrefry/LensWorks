import AppKit
import Testing
@testable import Compositor

/// S17: undo history and named checkpoints are saved inside the document and come back when it is reopened,
/// within the configured storage limit, without ever losing a checkpoint or pixels a kept state needs.
@MainActor
struct PersistentHistoryTests {
    typealias H = HistoryFixture
    typealias F = LayerGraphFixture

    /// A document edited through every kind of step history has to carry: new layers, a rename, repainted pixels,
    /// a multiple selection, a mask (enabled, then switched off), guides, a canvas selection, a folder, a deletion.
    /// Returns the session and what the document was after each step, oldest first.
    private func edited() throws -> (session: EditorSession, moments: [H.Moment], base: UUID, top: UUID) {
        let session = EditorSession()
        var moments: [H.Moment] = []
        // Each moment is the document, and the selection, a step started from; the last is where it all ended.
        func step(_ body: () throws -> Void) throws { moments.append(try H.moment(session)); try body() }
        var base = UUID(), top = UUID()
        try step { base = try H.add(session, "Base", H.image(96, 64, seed: 1)) }
        try step { top = try H.add(session, "Top", H.image(40, 30, seed: 2)) }
        try step { session.renameLayer(top, to: "Retouch") }
        try step { try H.paint(session, top, H.image(40, 30, seed: 3)) }
        // Both layers selected, the top one active: the next step is made with that selection.
        session.selectLayers([base, top], primary: top)
        try step { session.beginEdit("Opacity"); session.document?.layers[1].opacity = 0.5; session.endEdit() }
        session.selectLayers([top], primary: top)
        try step { session.beginEdit("Add Layer Mask"); session.document?.layers[1].mask = LayerMask(asset: try F.ramp(40, 30, seed: 4)); session.endEdit() }
        try step { session.beginEdit("Disable Layer Mask"); session.document?.layers[1].mask?.isEnabled = false; session.endEdit() }
        try step { session.beginEdit("Add Guide"); session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 12.5)]; session.endEdit() }
        try step {
            session.beginEdit("Select")
            session.document?.selection = DocumentSelection(path: CGPath(ellipseIn: CGRect(x: 4, y: 6, width: 30, height: 20), transform: nil), antialiased: true, feather: 2)
            session.endEdit()
        }
        session.selectLayers([base, top], primary: base)
        try step { session.groupSelectedLayers() }
        session.selectLayer(top)
        try step { session.deleteActiveLayer() }
        moments.append(try H.moment(session))
        #expect(session.history.undoCount == moments.count - 1, "every step is one entry")
        return (session, moments, base, top)
    }

    /// Undo and redo walk the same states after close and reopen as before, pixel for pixel, with the selection
    /// each step was made with, and each entry's name and who made it.
    @Test func undoAndRedoWalkTheSameStatesAfterCloseAndReopen() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, moments, _, _) = try edited()
        let names = session.history.entries.map(\.name)
        #expect(session.history.undoCount == moments.count - 1)
        // Undo three steps before saving: the redo steps are history too.
        for _ in 0..<3 { await session.undoNow() }
        let url = root.appendingPathComponent("Edited.comp")
        let saving = H.controller(session)
        #expect(await saving.save(to: url), "\(saving.notices)")
        #expect(!session.isModified && session.history.undoCount == moments.count - 4 && session.history.redoCount == 3)

        let reopened = try await H.open(url)
        let other = reopened.session
        #expect(!other.isModified, "a reopened document with history is not modified")
        #expect(other.history.entries.map(\.name) == names && other.history.entries.allSatisfy { $0.origin == .user })
        #expect(other.history.undoCount == moments.count - 4 && other.history.redoCount == 3)
        #expect(try H.describe(other.document) == moments[moments.count - 4].document)
        // Nothing but the document itself is in memory until a step is asked for.
        var resident = 0
        other.history.forEachState { if $0.isResident { resident += 1 } }
        #expect(resident == 1, "states stay on disk until Undo or Redo needs them, \(resident) are in memory")
        for expected in moments.dropLast(4).reversed() {
            #expect(other.canUndo)
            await other.undoNow()
            #expect(other.commandRefusal == nil, "\(other.commandRefusal ?? "")")
            #expect(try H.describe(other.document) == expected.document)
            #expect(other.activeLayerID == expected.active)
            #expect(other.selectedLayerIDs == expected.selected, "undo restores the layers that were selected with the active one")
        }
        #expect(!other.canUndo && other.document == nil)
        for expected in moments.dropFirst() {
            #expect(other.canRedo)
            await other.redoNow()
            #expect(try H.describe(other.document) == expected.document)
        }
        #expect(other.activeLayerID == moments.last?.active)
        #expect(!other.canRedo)
        // The same in the session that never closed: undo restores the whole selection there too.
        for expected in moments.dropLast(4).reversed() {
            await session.undoNow()
            #expect(try H.moment(session) == expected)
        }
    }

    /// History is saved again with every save: a reopened document keeps its old steps, takes new ones, and a
    /// second reopen has them all. An unchanged layer shares its image between the states read back from disk.
    @Test func historyGrowsAcrossSessionsAndSharesUnchangedPixels() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, moments, base, _) = try edited()
        let url = root.appendingPathComponent("Grows.comp")
        #expect(await H.controller(session).save(to: url))
        let second = try await H.open(url)
        #expect(second.session.history.undoCount == moments.count - 1)
        try H.paint(second.session, base, H.image(96, 64, seed: 9), name: "Second Session Stroke")
        let after = try H.moment(second.session)
        #expect(second.session.isModified)
        #expect(await second.save(), "\(second.notices)")
        let third = try await H.open(url)
        #expect(third.session.history.undoCount == moments.count && third.session.history.undoName == "Second Session Stroke")
        #expect(try H.moment(third.session).document == after.document)
        await third.session.undoNow()
        #expect(try H.describe(third.session.document) == moments.last?.document)
        await third.session.undoNow(); await third.session.undoNow()
        // Two steps back the folder is gone but Base's pixels are the same image in both states: read once, shared.
        let earlier = try #require(third.session.document?.layers.first { $0.id == base }?.asset?.image)
        await third.session.undoNow()
        #expect(third.session.document?.layers.first { $0.id == base }?.asset?.image === earlier, "an unchanged layer is one image across restored states")
        #expect(try H.staged(in: root).isEmpty)
    }

    /// Checkpoints are made, renamed, restored (as an undoable step) and deleted (only after a confirmation), and
    /// survive close and reopen with their exact pixels, however far the document has moved on.
    @Test func checkpointsAreNamedRestoredRenamedDeletedAndSurviveReopen() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(), controller = H.controller(session)
        let base = try H.add(session, "Base", H.image(96, 64, seed: 1))
        let top = try H.add(session, "Top", H.image(40, 30, seed: 2))
        #expect(session.createCheckpoint(named: "   ") == nil && session.history.checkpoints.isEmpty, "a checkpoint needs a name")
        session.history.markSaved()
        controller.answerName = { question in #expect(question.title == "New Checkpoint"); return "  Before Retouch " }
        #expect(await controller.newCheckpoint())
        let first = try #require(session.history.checkpoints.first)
        #expect(first.name == "Before Retouch" && first.origin == .user && session.isModified, "a new checkpoint has to be saved")
        let kept = try H.moment(session)
        try H.paint(session, top, H.image(40, 30, seed: 5))
        session.selectLayer(base); session.deleteActiveLayer()
        #expect(session.createCheckpoint(named: "Agent Pass", origin: .agent)?.origin == .agent)
        let later = try H.moment(session)
        let url = root.appendingPathComponent("Checkpoints.comp")
        #expect(await controller.save(to: url) && !session.isModified)

        let reopened = try await H.open(url)
        let other = reopened.session
        #expect(other.history.checkpoints.map(\.name) == ["Before Retouch", "Agent Pass"])
        #expect(other.history.checkpoints.map(\.origin) == [.user, .agent])
        #expect(other.history.checkpoints.map(\.id) == session.history.checkpoints.map(\.id))
        let steps = other.history.undoCount
        #expect(await other.restoreCheckpointNow(first.id))
        #expect(try H.describe(other.document) == kept.document && other.activeLayerID == kept.active)
        #expect(other.history.undoCount == steps + 1 && other.history.undoName == "Restore “Before Retouch”", "restoring is one undoable step")
        await other.undoNow()
        #expect(try H.describe(other.document) == later.document, "undo returns to where the document was")
        await other.redoNow()
        // Rename.
        reopened.answerName = { _ in "Clean Plate" }
        #expect(await reopened.renameCheckpoint(first.id) && other.history.checkpoints.first?.name == "Clean Plate")
        // Delete asks first: "no" keeps it, and without an answer nothing can delete it.
        var asked: [LWLossQuestion] = []
        reopened.answerLoss = { asked.append($0); return false }
        #expect(!(await reopened.deleteCheckpoint(first.id)) && other.history.checkpoints.count == 2)
        #expect(asked.count == 1 && asked[0].title.contains("Clean Plate") && asked[0].message.contains("cannot be undone"))
        reopened.answerLoss = { asked.append($0); return true }
        let second = other.history.checkpoints[1].id
        #expect(await reopened.deleteCheckpoint(second) && other.history.checkpoints.map(\.name) == ["Clean Plate"])
        #expect(asked.count == 2 && other.isModified)
        #expect(await reopened.save(), "\(reopened.notices)")
        let last = try await H.open(url)
        #expect(last.session.history.checkpoints.map(\.name) == ["Clean Plate"])
        #expect(try H.describe(last.session.document) == kept.document)
        // A checkpoint cannot be made while a dialog owns the document, and the reason is stated.
        last.session.showsNewDocument = true
        #expect(last.session.checkpointUnavailableReason == "Finish the current edit or dialog first.")
        #expect(!(await last.newCheckpoint()) && last.session.commandRefusal == "Finish the current edit or dialog first.")
    }

    /// The storage model, measured on a large document: a saved step costs the tiles it changed, not the frame.
    /// Printed so the figures in the pull request are the ones this test produced.
    @Test func aSavedStepCostsTheTilesItChangedNotTheWholeFrame() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let width = 4096, height = 3072, steps = 8
        // Photographic noise: incompressible, so a tile's size on disk is close to its raw size.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in 0..<words.count { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; words[i] = seed | 0xFF000000_FF000000 }
        }
        let photo = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: F.sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let session = EditorSession()
        let layer = try H.add(session, "Photo", photo)
        let controller = H.controller(session, settings: LWHistorySettings(storageLimitBytes: 0))
        let url = root.appendingPathComponent("Large.comp")
        #expect(await controller.save(to: url))
        let frame = Int64(width * height * 4)
        // One import step: its "before" is no document at all, so history costs nothing but its records.
        #expect(H.historyBytes(url) < 64 * 1024, "one step whose pixels are the document's own takes \(H.historyBytes(url)) bytes")
        var sizes: [Int64] = [], times: [Double] = []
        var current = photo
        for step in 0..<steps {
            // A 300-pixel dab somewhere new each time: it touches at most nine 256-pixel tiles.
            current = try H.dab(current, x: 200 + step * 450, y: 300 + step * 300, side: 300, seed: step)
            try H.paint(session, layer, current)
            let started = Date()
            #expect(await controller.save(), "\(controller.notices)")
            times.append(Date().timeIntervalSince(started))
            sizes.append(H.historyBytes(url))
        }
        // The first stroke moves the layer's old pixels into history once (the document now holds the new ones).
        let first = sizes[0], later = zip(sizes.dropFirst(), sizes).map { $0 - $1 }
        let worst = try #require(later.max()), average = later.reduce(0, +) / Int64(later.count)
        print("S17 history cost, \(width)x\(height) 8-bit layer (\(frame / 1_048_576) MiB raw): first stroke \(first / 1024) KiB (the layer's previous pixels, once); each later stroke average \(average / 1024) KiB, worst \(worst / 1024) KiB; save time average \(String(format: "%.2f", times.reduce(0, +) / Double(times.count))) s")
        #expect(first <= frame + frame / 20, "the layer's previous pixels enter history once: \(first) bytes for a \(frame)-byte frame")
        #expect(worst <= 9 * 256 * 256 * 4 + 64 * 1024, "a later stroke stored \(worst) bytes, more than the nine tiles a 300-pixel dab can touch")
        #expect(worst * 20 < frame, "a step costs \(worst) bytes against a \(frame)-byte frame")
        // Memory stayed bounded without losing a step: saved states leave memory instead of being dropped.
        #expect(session.history.undoCount == steps + 1 && session.history.retainedBytes(current: session.document) <= session.history.retainedByteLimit)
        // And every one of those steps reads back exactly.
        let reopened = try await H.open(url)
        #expect(reopened.session.history.undoCount == steps + 1)
        let top = try H.describe(reopened.session.document)
        for _ in 0..<steps { await reopened.session.undoNow() }
        #expect(try H.pixels(try #require(reopened.session.activeLayer?.asset)) == (try H.pixels(F.asset(photo))), "the first state's pixels are exact")
        for _ in 0..<steps { await reopened.session.redoNow() }
        #expect(try H.describe(reopened.session.document) == top)
    }

    /// Float layers are saved by the tiles their planes already are: a step that replaces part of a float layer
    /// stores only the tiles that differ, and the samples read back bit for bit.
    @Test func floatLayersKeepTheirExactSamplesAndShareUnchangedTiles() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let width = 600, height = 520
        // No repeat at the tile size, so every tile of the plane is its own.
        let first = F.image(width, height) { x, y in ((x / 2 + y / 3) % 256, (x / 3 + y / 2) % 256, (x / 5 + y / 7) % 256, 255) }
        let session = EditorSession()
        let layer = try H.add(session, "Float", first)
        session.history.reset()
        session.document?.layers[0].asset = try F.floatAsset(first, gain: 2.5, workspace: workspace)
        var moments = [try H.moment(session)]
        // Each step changes one corner: one tile of the six differs from the state before.
        var current = first
        for step in 0..<3 {
            current = try H.dab(current, x: step * 20, y: step * 10, side: 60, seed: step)
            let index = try #require(session.document?.layers.firstIndex { $0.id == layer })
            session.beginEdit("Float Stroke"); session.document?.layers[index].asset = try F.floatAsset(current, gain: 2.5, workspace: workspace); session.endEdit()
            moments.append(try H.moment(session))
        }
        let url = root.appendingPathComponent("Float.comp")
        let controller = H.controller(session, settings: LWHistorySettings(storageLimitBytes: 0))
        #expect(await controller.save(to: url), "\(controller.notices)")
        let blobs = try H.files(url).keys.filter { $0.contains("/History/blobs/") }.count
        // Three earlier states of a 3-by-3-tile plane: the first whole (9 tiles), then one changed tile each.
        #expect(blobs == 11, "\(blobs) tiles stored for three earlier states of a nine-tile plane")
        let reopened = try await H.open(url)
        #expect(try H.describe(reopened.session.document) == moments[3].document)
        for expected in moments.dropLast().reversed() {
            await reopened.session.undoNow()
            #expect(reopened.session.commandRefusal == nil, "\(reopened.session.commandRefusal ?? "")")
            #expect(try H.describe(reopened.session.document) == expected.document)
            #expect(reopened.session.activeLayer?.asset?.linearPlane != nil, "a float layer stays float")
        }
        try await reopened.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    }

    /// Pixels that are not plain 8-bit tiles are kept whole and exactly: a float surface that is not a tiled plane
    /// (as a small development is before it is saved), and an 8-bit image in a colour space given by a profile.
    @Test func unusualPixelFormatsAreKeptWholeAndExactly() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let layer = try H.add(session, "Layer", H.image(40, 30, seed: 1))
        session.history.reset()
        var moments: [H.Moment] = []
        func replace(_ asset: ImportedImage, _ name: String) throws {
            moments.append(try H.moment(session))
            session.beginEdit(name); session.document?.layers[0].asset = asset; session.endEdit()
        }
        // A float surface held in memory, not yet a tiled plane.
        let surface = try LWLinearSurface.read(H.image(40, 30, seed: 2), maximumBytes: 40 * 30 * 16)
        let bright = try LWLinearSurface(width: 40, height: 30, pixels: surface.pixels.map { SIMD4($0.x * 3, $0.y * 3, $0.z * 3, $0.w) }, maximumBytes: 40 * 30 * 16)
        try replace(try ImportedImage(linear: bright, name: "Layer"), "Float Surface")
        // The same 8-bit bytes read through a colour profile instead of a named space.
        let plain = H.image(40, 30, seed: 3)
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData())
        let space = try #require(CGColorSpace(iccData: profile))
        let profiled = try #require(plain.copy(colorSpace: space))
        try replace(F.asset(profiled, "Layer"), "Profiled Image")
        try replace(F.asset(H.image(40, 30, seed: 4), "Layer"), "Plain Image")
        moments.append(try H.moment(session))
        let url = root.appendingPathComponent("Formats.comp")
        let controller = H.controller(session)
        #expect(await controller.save(to: url), "\(controller.notices)")
        let reopened = try await H.open(url)
        #expect(reopened.session.history.entries.map(\.name) == ["Float Surface", "Profiled Image", "Plain Image"])
        for expected in moments.dropLast().reversed() {
            await reopened.session.undoNow()
            #expect(reopened.session.commandRefusal == nil, "\(reopened.session.commandRefusal ?? "")")
            #expect(try H.describe(reopened.session.document) == expected.document)
        }
        _ = layer
        try await reopened.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    }

    /// Not every change goes through history (binding a catalog source to a fresh import does not). A step made
    /// after one starts from exactly what was there: Undo returns to it, in the session and after a reopen.
    @Test func aStepStartsFromExactlyWhatWasThereWhenTheDocumentChangedOutsideHistory() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let layer = try H.add(session, "Base", H.image(40, 30, seed: 1))
        let imported = try H.moment(session)
        // Changed directly, with no undo step of its own.
        session.document?.layers[0].opacity = 0.4
        session.document?.layers[0].mask = LayerMask(asset: try F.ramp(40, 30, seed: 2))
        let changed = try H.moment(session)
        #expect(changed.document != imported.document && session.history.undoCount == 1)
        #expect(session.createCheckpoint(named: "As Changed") != nil)
        try H.paint(session, layer, H.image(40, 30, seed: 3))
        let painted = try H.moment(session)
        await session.undoNow()
        #expect(try H.moment(session).document == changed.document, "undo returns to what the stroke started from, not to the import")
        await session.redoNow()
        let url = root.appendingPathComponent("Outside.comp")
        #expect(await H.controller(session).save(to: url))
        let reopened = try await H.open(url)
        #expect(reopened.session.history.undoCount == 2)
        #expect(try H.describe(reopened.session.document) == painted.document)
        await reopened.session.undoNow()
        #expect(try H.describe(reopened.session.document) == changed.document)
        #expect(await reopened.session.restoreCheckpointNow(try #require(reopened.session.history.checkpoints.first?.id)) == true)
        #expect(try H.describe(reopened.session.document) == changed.document, "the checkpoint kept the document as it was when it was made")
    }

    /// Save As carries the whole history into the new package and leaves the old one exactly as it was.
    @Test func saveAsCarriesHistoryAndLeavesTheOldPackageUntouched() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, moments, base, _) = try edited()
        session.createCheckpoint(named: "Marked")
        let first = root.appendingPathComponent("First.comp"), second = root.appendingPathComponent("Second.comp")
        let controller = H.controller(session)
        #expect(await controller.save(to: first))
        let before = try H.files(first)
        // One more step, then Save As: the states the first package holds are brought over from it.
        try H.paint(session, base, H.image(96, 64, seed: 8))
        #expect(await controller.save(to: second), "\(controller.notices)")
        #expect(try H.files(first) == before, "Save As only reads the package it came from")
        let reopened = try await H.open(second)
        #expect(reopened.session.history.undoCount == moments.count && reopened.session.history.checkpoints.map(\.name) == ["Marked"])
        await reopened.session.undoNow()
        for expected in moments.dropLast().reversed() {
            await reopened.session.undoNow()
            #expect(try H.describe(reopened.session.document) == expected.document)
        }
        // The old package still opens with the history it had.
        let old = try await H.open(first)
        #expect(old.session.history.undoCount == moments.count - 1)
        // (A canvas selection is not part of the saved document itself, only of its undo states.)
        #expect(try H.describe(old.session.document) == moments.last?.document.filter { !$0.hasPrefix("selection") })
    }

    /// Who made an entry is written with it. A record written before origins existed reads as the person's.
    @Test func entriesKeepTheirOriginAndOlderRecordsReadAsThePersons() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let layer = try H.add(session, "Base", H.image(32, 32, seed: 1))
        try H.paint(session, layer, H.image(32, 32, seed: 2), name: "Agent Stroke", origin: .agent)
        try H.paint(session, layer, H.image(32, 32, seed: 3), name: "My Stroke")
        #expect(session.history.undoOrigin == .user)
        let url = root.appendingPathComponent("Origins.comp")
        #expect(await H.controller(session).save(to: url))
        let reopened = try await H.open(url)
        #expect(reopened.session.history.entries.map(\.origin) == [.user, .agent, .user])
        await reopened.session.undoNow()
        #expect(reopened.session.history.undoOrigin == .agent && reopened.session.history.redoOrigin == .user)
        // The same index with every origin taken out, as a build without origins would have written it.
        let index = url.appendingPathComponent("History/index.json")
        var json = try #require(String(data: try Data(contentsOf: index), encoding: .utf8))
        // The person is spelled "person" on disk, as the first history schema wrote it.
        #expect(json.contains("\"origin\":\"agent\"") && json.contains("\"origin\":\"person\"") && !json.contains("\"origin\":\"user\""))
        json = json.replacingOccurrences(of: ",\"origin\":\"agent\"", with: "").replacingOccurrences(of: ",\"origin\":\"person\"", with: "")
        #expect(!json.contains("origin"))
        try Data(json.utf8).write(to: index)
        let older = try await H.open(url)
        #expect(older.session.history.undoCount == 3 && older.session.history.entries.allSatisfy { $0.origin == .user })
    }

    /// The document changed outside history after a checkpoint named the state it was in: the next save writes what
    /// the document is now as a state of its own, so the checkpoint still restores what it named, after a reopen too.
    @Test func aCheckpointKeepsItsStateWhenTheDocumentChangesOutsideHistoryBeforeASave() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let layer = try H.add(session, "Base", H.image(48, 32, seed: 1))
        try H.paint(session, layer, H.image(48, 32, seed: 2))
        let checkpoint = try #require(session.createCheckpoint(named: "Named"))
        let named = try H.describe(session.document)
        // Something changes the document without a history step (as a reload or a development landing does).
        let index = try #require(session.document?.layers.firstIndex { $0.id == layer })
        session.document?.layers[index].name = "Changed Outside"
        session.document?.layers[index].asset = F.asset(H.image(48, 32, seed: 3), "Changed Outside")
        let changed = try H.describe(session.document)
        #expect(changed != named)
        let url = root.appendingPathComponent("Outside.comp")
        let controller = H.controller(session)
        #expect(await controller.save(to: url), "\(controller.notices)")
        // In the session that saved: the checkpoint is still what it named.
        #expect(await session.restoreCheckpointNow(checkpoint.id))
        #expect(try H.describe(session.document) == named)
        await session.undoNow()
        #expect(try H.describe(session.document) == changed)
        // After a reopen: the document is what was saved, the checkpoint what it named.
        let reopened = try await H.open(url)
        #expect(try H.describe(reopened.session.document) == changed)
        #expect(await reopened.session.restoreCheckpointNow(checkpoint.id) && reopened.session.commandRefusal == nil)
        #expect(try H.describe(reopened.session.document) == named, "the checkpoint restores the state it named, not the document as it was saved")
    }
}
