import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// S17: the storage limit, what pruning may and may not take, the warning when protected history alone is over the
/// limit, and what is left on disk when a history write is interrupted or its files are damaged.
@MainActor
struct PersistentHistoryStorageTests {
    typealias H = HistoryFixture
    typealias F = LayerGraphFixture

    /// The settings a controller reads, changeable between saves.
    final class Settings: @unchecked Sendable { var value = LWHistorySettings(storageLimitBytes: 0) }
    final class Counter: @unchecked Sendable { var count = 0 }

    /// A layer repainted `strokes` times, each stroke different everywhere, so each state before one costs a layer.
    private func strokes(_ count: Int, checkpointAfter: Int? = nil) throws -> (session: EditorSession, layer: UUID, moments: [H.Moment], kept: H.Moment?) {
        let session = EditorSession()
        var moments = [try H.moment(session)]
        let layer = try H.add(session, "Photo", H.image(200, 160, seed: 0))
        var kept: H.Moment?
        for stroke in 1...count {
            moments.append(try H.moment(session))
            try H.paint(session, layer, H.image(200, 160, seed: stroke * 7), name: "Stroke \(stroke)")
            if stroke == checkpointAfter { #expect(session.createCheckpoint(named: "Keep") != nil); kept = try H.moment(session) }
        }
        moments.append(try H.moment(session))
        return (session, layer, moments, kept)
    }

    /// Over the limit, a save drops the oldest steps first and nothing else: the checkpoint and every remaining
    /// step read back exactly. When the checkpoint and the current state alone are over the limit, the person is
    /// warned and still nothing protected goes.
    @Test func savedHistoryIsPrunedOldestFirstAndNeverLosesACheckpointOrItsPixels() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, moments, kept) = try strokes(10, checkpointAfter: 2)
        let settings = Settings()
        let controller = H.controller(session)
        controller.historySettings = { settings.value }
        let url = root.appendingPathComponent("Pruned.comp")
        #expect(await controller.save(to: url))
        let whole = try #require(session.historyUsage)
        let names = session.history.entries.map(\.name)
        #expect(session.history.undoCount == 11 && whole.bytes > 0 && whole.protectedBytes < whole.bytes && session.historyStorageWarning == nil)
        #expect(whole.bytes == H.historyBytes(url) - Int64((try Data(contentsOf: url.appendingPathComponent("History/index.json"))).count), "the reported size is what the History folder holds")

        // Half the room: the oldest steps go, the newest stay, the checkpoint stays.
        settings.value.storageLimitBytes = whole.bytes / 2
        #expect(await controller.save(), "\(controller.notices)")
        let pruned = try #require(session.historyUsage)
        let left = session.history.undoCount
        #expect(left < 11 && left > 0, "\(left) steps left of 11")
        #expect(session.history.entries.map(\.name) == Array(names.suffix(left)), "the oldest steps were the ones removed")
        #expect(pruned.bytes <= whole.bytes / 2 && pruned.limitBytes == whole.bytes / 2)
        #expect(H.historyBytes(url) < whole.bytes, "the pruned steps' pixels left the package")
        #expect(session.history.checkpoints.map(\.name) == ["Keep"] && session.historyStorageWarning == nil)
        // The steps the save removed are gone from Undo here too, and the person is told: how many, and the limit.
        let notice = try #require(session.historyPruneNotice)
        #expect(notice.removedSteps == 11 - left && notice.limitBytes == whole.bytes / 2 && notice.checkpoints == 1)
        #expect(controller.notices.count == 1 && controller.notices[0].hasPrefix("Saving removed undo steps") && controller.notices[0].contains(HistoryPruneNotice.steps(11 - left)),
                "\(controller.notices)")
        // In the open session the checkpoint still restores, though the steps around it are gone.
        #expect(await session.restoreCheckpointNow(try #require(session.history.checkpoints.first?.id)))
        #expect(try H.describe(session.document) == kept?.document)
        await session.undoNow()

        let reopened = try await H.open(url)
        #expect(reopened.session.history.undoCount == left && reopened.session.history.checkpoints.map(\.name) == ["Keep"])
        for expected in moments.dropLast().suffix(left).reversed() {
            await reopened.session.undoNow()
            #expect(reopened.session.commandRefusal == nil, "\(reopened.session.commandRefusal ?? "")")
            #expect(try H.describe(reopened.session.document) == expected.document, "every kept step still has all of its pixels")
        }
        #expect(!reopened.session.canUndo)
        #expect(await reopened.session.restoreCheckpointNow(try #require(reopened.session.history.checkpoints.first?.id)))
        #expect(try H.describe(reopened.session.document) == kept?.document, "the checkpoint's pixels outlive the steps that made them")

        // Almost no room at all: every step goes, and the checkpoint is still not touched. The person is told, once,
        // that the undo steps were removed and the checkpoint kept.
        settings.value.storageLimitBytes = 1024
        let stepsBefore = session.history.undoCount + session.history.redoCount
        #expect(await controller.save(), "\(controller.notices)")
        #expect(session.history.undoCount == 0 && session.history.redoCount == 0 && session.history.checkpoints.map(\.name) == ["Keep"])
        let warning = try #require(session.historyStorageWarning)
        #expect(warning.limitBytes == 1024 && warning.protectedBytes > 1024 && warning.checkpoints == ["Keep"] && warning.removedSteps == stepsBefore)
        #expect(!warning.message.contains("Nothing was removed") && warning.message.contains("Checkpoints are never pruned, so all 1 were kept")
                && warning.message.contains("removed \(HistoryPruneNotice.steps(stepsBefore))"), "\(warning.message)")
        #expect(controller.notices.count == 2 && controller.notices[1].contains("Checkpoints use more than the history storage limit"))
        #expect(await controller.save() && controller.notices.count == 2, "the warning is raised once, not on every save")
        let protected = try await H.open(url)
        #expect(await protected.session.restoreCheckpointNow(try #require(protected.session.history.checkpoints.first?.id)))
        #expect(try H.describe(protected.session.document) == kept?.document)
        // With room again the warning is withdrawn.
        settings.value.storageLimitBytes = 0
        #expect(await controller.save() && session.historyStorageWarning == nil)
    }

    /// The order pruning takes entries in, on its own: oldest undo steps, then the furthest redo steps, never a
    /// state a checkpoint keeps or the one the document is in, and never a file a kept state still needs.
    @Test func pruningTakesTheOldestStepsThenTheFurthestRedoAndNeverAProtectedState() {
        typealias Record = DocumentHistory.Record
        let states = (0..<7).map { _ in UUID() }
        func entry(_ from: Int, _ to: Int) -> Record.Entry {
            .init(id: UUID(), name: "\(from)>\(to)", origin: .user, date: Date(), before: states[from], after: states[to], beforeSelection: .init(), afterSelection: .init())
        }
        // 0 > 1 > 2 > 3 (cursor) and redo 3 > 4 > 5 > 6; a checkpoint keeps state 1.
        let record = Record(past: [entry(0, 1), entry(1, 2), entry(2, 3)], future: [entry(5, 6), entry(4, 5), entry(3, 4)],
            checkpoints: [.init(id: UUID(), name: "Keep", origin: .user, date: Date(), state: states[1], selection: .init())], cursor: states[3])
        #expect(LWHistoryArchive.validate(record))
        // Each state has 100 bytes of its own; states 1 and 2 share one 1000-byte file.
        var files: [UUID: Set<String>] = [:], sizes: [String: Int64] = ["shared": 1000]
        for (index, state) in states.enumerated() { files[state] = ["own\(index)"]; sizes["own\(index)"] = 100 }
        files[states[1]]?.insert("shared"); files[states[2]]?.insert("shared")
        func prune(_ limit: Int64) -> (names: [String], bytes: Int64, protected: Int64, left: Record) {
            var copy = record
            let plan = LWHistoryArchive.prune(&copy, files: files, sizes: sizes, stateBytes: [:], limit: limit)
            return (plan.pruned.map(\.name), plan.bytes, plan.protected, copy)
        }
        #expect(prune(0).names.isEmpty && prune(0).bytes == 1700, "no limit removes nothing")
        #expect(prune(1700).names.isEmpty)
        #expect(prune(1699).names == ["0>1"] && prune(1699).bytes == 1600, "the oldest step goes first")
        // Dropping 1>2 frees state 2's own bytes but not the shared file: the checkpoint's state still needs it.
        #expect(prune(1599).names == ["0>1", "1>2", "2>3"] && prune(1599).bytes == 1500)
        #expect(prune(1499).names == ["0>1", "1>2", "2>3", "5>6"], "then the furthest redo step")
        let floor = prune(1)
        #expect(floor.names == ["0>1", "1>2", "2>3", "5>6", "4>5", "3>4"])
        #expect(floor.bytes == 1200 && floor.protected == 1200, "the checkpoint (with the shared file) and the current state remain")
        #expect(floor.left.checkpoints.count == 1 && floor.left.states == [states[1], states[3]])
        #expect(prune(1700).protected == 1200)
        // A record that uses one entry twice, or has a step that changes nothing, is refused when a package is opened.
        var broken = record; broken.future.append(record.past[0])
        #expect(!LWHistoryArchive.validate(broken))
        broken = record; broken.past.append(entry(3, 3))
        #expect(!LWHistoryArchive.validate(broken))
    }

    /// A history write that fails at any point (standing in for the process dying there) leaves the package on disk
    /// byte for byte as it was, with the document and history of its last save, and no staging folder behind.
    @Test(arguments: LWHistoryArchive.Stage.allCases)
    func anInterruptedHistoryWriteLeavesTheLastSavedDocumentAndHistory(_ stage: LWHistoryArchive.Stage) async throws {
        let root = try H.folder(stage.rawValue); defer { try? FileManager.default.removeItem(at: root) }
        let (session, layer, moments, _) = try strokes(3, checkpointAfter: 1)
        let controller = H.controller(session)
        let url = root.appendingPathComponent("Durable.comp")
        #expect(await controller.save(to: url))
        let durable = try H.files(url)
        // More work, and a second checkpoint, that the interrupted save would have written.
        try H.paint(session, layer, H.image(200, 160, seed: 99), name: "Unsaved Stroke")
        session.createCheckpoint(named: "Unsaved Checkpoint")
        let reached = Counter()
        controller.historyFault = { at in if at == stage { reached.count += 1; throw CocoaError(.fileWriteUnknown) } }
        #expect(!(await controller.save()), "the save reports failure")
        #expect(reached.count == 1, "the write reached \(stage)")
        #expect(controller.notices.count == 1 && controller.notices[0].hasPrefix("Couldn’t save the project"))
        #expect(session.isModified && session.history.undoCount == 5, "the session keeps its unsaved work and says so")
        #expect(try H.files(url) == durable, "the package was not touched")
        #expect(try H.staged(in: root).isEmpty, "no staging folder is left behind")
        let reopened = try await H.open(url)
        #expect(reopened.session.history.undoCount == 4 && reopened.session.history.checkpoints.map(\.name) == ["Keep"])
        for expected in moments.dropLast().reversed() {
            await reopened.session.undoNow()
            #expect(try H.describe(reopened.session.document) == expected.document)
        }
        // The process really dying leaves its staging folder; it is hidden, and it changes nothing.
        let orphan = root.appendingPathComponent(".LensWorks-" + UUID().uuidString + ".comp")
        try FileManager.default.createDirectory(at: orphan.appendingPathComponent("History/blobs"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: orphan.appendingPathComponent("manifest.json"))
        let beside = try await H.open(url)
        #expect(beside.session.history.undoCount == 4)
        // And the next save, uninterrupted, writes everything.
        controller.historyFault = nil
        #expect(await controller.save(), "\(controller.notices)")
        let saved = try await H.open(url)
        #expect(saved.session.history.undoCount == 5 && saved.session.history.checkpoints.map(\.name) == ["Keep", "Unsaved Checkpoint"])
    }

    /// Damage to the History folder never stops the document opening. A step whose pixels are gone refuses with a
    /// reason and changes nothing; the next save keeps what can still be read and says what could not be.
    @Test func damagedHistoryNeverStopsTheDocumentOpening() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, layer, moments, _) = try strokes(4)
        let url = root.appendingPathComponent("Damaged.comp")
        #expect(await H.controller(session).save(to: url))
        let index = url.appendingPathComponent("History/index.json")
        let good = try Data(contentsOf: index)

        // An index cut short, an index for another manifest, and a newer history schema: the document opens without history.
        let other = String(data: good, encoding: .utf8)!
        let newer = Data(other.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2").utf8)
        for damaged in [Data(good.prefix(good.count / 2)), Data(other.replacingOccurrences(of: "\"manifestSHA256\":\"", with: "\"manifestSHA256\":\"0").utf8), newer] {
            try damaged.write(to: index)
            let opened = try await H.open(url)
            #expect(opened.notices.isEmpty && opened.session.history.undoCount == 0 && !opened.session.isModified)
            #expect(try H.describe(opened.session.document) == moments.last?.document)
            // Only a newer build's history is somebody's to keep; damaged history is nothing to ask about.
            #expect(opened.session.newerHistorySchema == (damaged == newer ? 2 : nil))
        }
        // A newer build's history is never thrown away unasked: the first save over the package asks, and "Cancel"
        // leaves the package byte for byte as it was.
        try newer.write(to: index)
        let frozen = try H.files(url)
        let keeping = try await H.open(url)
        var asked: [LWLossQuestion] = []
        keeping.answerLoss = { asked.append($0); return false }
        try H.paint(keeping.session, layer, H.image(200, 160, seed: 77), name: "Over Newer History")
        #expect(!(await keeping.save()), "the save is cancelled")
        #expect(asked.count == 1 && asked[0].title == "Save without this document’s saved history?" && asked[0].message.contains("history format 2"), "\(asked)")
        #expect(try H.files(url) == frozen, "a cancelled save leaves the package and its newer history byte for byte as they were")
        #expect(keeping.session.isModified && keeping.session.newerHistorySchema == 2)
        // Save As elsewhere keeps this file as it is and asks nothing.
        let elsewhere = root.appendingPathComponent("Elsewhere.comp")
        #expect(await keeping.save(to: elsewhere) && asked.count == 1)
        #expect(try H.files(url) == frozen)
        // Saving over it with the person's yes replaces the history with this build's.
        let replacing = try await H.open(url)
        replacing.answerLoss = { asked.append($0); return true }
        try H.paint(replacing.session, layer, H.image(200, 160, seed: 78), name: "Replace History")
        #expect(await replacing.save(), "\(replacing.notices)")
        #expect(asked.count == 2 && replacing.session.newerHistorySchema == nil)
        #expect(try await H.open(url).session.history.undoName == "Replace History")
        #expect(await replacing.save() && asked.count == 2, "the question is put once")
        try good.write(to: index)
        // (The package now holds this build's history from the last save; put the original back for what follows.)
        try FileManager.default.removeItem(at: url)
        #expect(await H.controller(session).save(to: url))

        // One tile of the oldest painted state is removed; another is corrupted.
        let blobs = try H.files(url).keys.filter { $0.contains("/History/blobs/") }.sorted()
        #expect(blobs.count >= 2)
        let opened = try await H.open(url)
        #expect(opened.session.history.undoCount == 5)
        for (damage, expected) in [(0, "missing"), (1, "could not be read")] {
            let victim = URL(fileURLWithPath: url.path + blobs[damage])
            let original = try Data(contentsOf: victim)
            if damage == 0 { try FileManager.default.removeItem(at: victim) }
            else { var bytes = original; bytes[bytes.count - 1] ^= 0xFF; try bytes.write(to: victim) }
            let fresh = try await H.open(url)
            var refused: String?
            for _ in 0..<5 where refused == nil { await fresh.session.undoNow(); refused = fresh.session.commandRefusal }
            let reason = try #require(refused, "a step whose pixels are damaged refuses")
            #expect(reason.contains(expected), "\(reason)")
            #expect(fresh.session.canUndo && fresh.session.document != nil, "the refused step is still there and the document stands")
            try original.write(to: victim)
        }
        // With a tile gone for good, the next save keeps what it can read and names what it could not keep.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + blobs[0]))
        let last = try await H.open(url)
        try H.paint(last.session, layer, H.image(200, 160, seed: 50), name: "After Damage")
        #expect(await last.save(), "\(last.notices)")
        #expect(last.notices.count == 1 && last.notices[0].hasPrefix("Some saved history could not be kept"))
        let healed = try await H.open(url)
        #expect(healed.session.history.undoCount > 0 && healed.session.history.undoCount < 6)
        while healed.session.canUndo { await healed.session.undoNow(); #expect(healed.session.commandRefusal == nil) }
    }

    /// When undo holds too much in memory, states the package already holds leave memory; no step is lost, and
    /// each comes back from disk exactly when it is undone to.
    @Test func savedStatesLeaveMemoryInsteadOfStepsBeingDropped() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, layer, moments, _) = try strokes(6)
        let controller = H.controller(session)
        #expect(await controller.save(to: root.appendingPathComponent("Memory.comp")))
        func resident() -> Int { var count = 0; session.history.forEachState { if $0.isResident { count += 1 } }; return count }
        #expect(resident() == 8 && session.history.retainedBytes(current: session.document) > 600_000)
        // Room for about one layer's worth of undo in memory.
        session.history.retainedByteLimit = 150_000
        session.renameLayer(layer, to: "Renamed")
        #expect(session.history.undoCount == 8, "no step was dropped")
        #expect(session.history.retainedBytes(current: session.document) <= 150_000 && resident() <= 3, "\(resident()) states still in memory")
        await session.undoNow()
        for expected in moments.dropLast().reversed() {
            await session.undoNow()
            #expect(session.commandRefusal == nil, "\(session.commandRefusal ?? "")")
            #expect(try H.describe(session.document) == expected.document)
            #expect(session.history.retainedBytes(current: session.document) <= 150_000)
        }
        #expect(session.history.redoCount == 8)
        // Without a package to hold them, the oldest steps are what goes (as before this story).
        let unsaved = try strokes(6).session
        unsaved.history.retainedByteLimit = 150_000
        unsaved.renameLayer(try #require(unsaved.activeLayerID), to: "Renamed")
        #expect(unsaved.history.undoCount < 8 && unsaved.history.undoName == "Rename Layer")
    }

    /// The limits are the person's settings: they persist in the defaults they are given and nowhere else.
    @Test func theStorageLimitIsASettingThatPersists() async throws {
        let defaults: UserDefaults = LensWorksVolatileDefaults()
        #expect(LWHistorySettings(defaults: defaults) == LWHistorySettings() && LWHistorySettings().storageLimitBytes == 1024 * 1024 * 1024 && LWHistorySettings().stepLimit == 100)
        let center = LWHistorySettingsCenter(defaults: defaults)
        center.update { $0.storageLimitBytes = 4 * 1024 * 1024 * 1024; $0.stepLimit = 5_000 }
        #expect(center.settings.storageLimitBytes == 4 * 1024 * 1024 * 1024 && center.settings.stepLimit == 1000, "the step limit is held to its range")
        #expect(LWHistorySettingsCenter(defaults: defaults).settings == center.settings, "the settings come back")
        center.update { $0.storageLimitBytes = -5 }
        #expect(center.settings.storageLimitBytes == 0 && LWHistorySettings.label(0) == "No limit")
        // The app's own center keeps them in the person's preferences, through the one accessor that hands a test
        // process preferences of its own (LensWorksUserStateTests holds the accessor to that).
        #expect(LWHistorySettingsCenter.shared.settingsDefaults === LensWorksUserState.defaults && LensWorksUserState.defaults is LensWorksVolatileDefaults)
        let transient = LWHistorySettingsCenter(defaults: LensWorksVolatileDefaults())
        transient.update { $0.stepLimit = 20 }
        #expect(transient.settings.stepLimit == 20 && LWHistorySettingsCenter(defaults: LensWorksVolatileDefaults()).settings == LWHistorySettings())
        #expect(LWHistorySettings.storageChoices.contains(LWHistorySettings().storageLimitBytes) && LWHistorySettings.storageChoices.last == 0)
        // The panel lays out for a session with no document, never on screen.
        let host = NSHostingView(rootView: HistoryStorageView(center: transient, session: EditorSession()))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= 380 && host.fittingSize.height > 100)
        // The step limit reaches the session's history at the next save or open.
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try strokes(2).session, controller = H.controller(session, settings: LWHistorySettings(stepLimit: 20))
        #expect(session.history.entryLimit == 100)
        #expect(await controller.save(to: root.appendingPathComponent("Limit.comp")) && session.history.entryLimit == 20)
        let reopened = try await H.open(root.appendingPathComponent("Limit.comp"), settings: LWHistorySettings(stepLimit: 30))
        #expect(reopened.session.history.entryLimit == 30)
    }

    /// An unsaved checkpoint whose state alone is over the memory limit is never released, and it does not count
    /// against the undo steps: an edit keeps its steps instead of dropping all of them.
    @Test func anUnsavedCheckpointOverTheMemoryLimitLeavesTheUndoStepsTheirOwnRoom() throws {
        let session = EditorSession()
        let layer = try H.add(session, "Photo", H.image(200, 160, seed: 0))
        try H.paint(session, layer, H.image(200, 160, seed: 1), name: "Stroke 1")
        #expect(session.createCheckpoint(named: "Unsaved") != nil)
        // The checkpoint's state stays in memory (there is no package to hold it). The limit has room for one step
        // (a state of this layer takes about 130 KB), not for the checkpoint and a step together.
        session.history.retainedByteLimit = 200_000
        for stroke in 2...5 { try H.paint(session, layer, H.image(200, 160, seed: stroke), name: "Stroke \(stroke)") }
        #expect(session.history.checkpoints.map(\.name) == ["Unsaved"])
        #expect(session.history.undoCount > 0 && session.history.undoName == "Stroke 5", "\(session.history.undoCount) steps left")
        // The steps' own share stays within the limit: what only the steps hold is dropped oldest first.
        #expect(session.history.undoCount == 1, "\(session.history.undoCount)")
        session.undo()
        #expect(session.history.redoName == "Stroke 5")
    }

    /// Lowering the step limit drops the oldest steps at once, so a save writes no more than the limit allows, and
    /// a package saved under a higher limit is opened within the lower one.
    @Test func aLowerStepLimitDropsTheOldestStepsAtSaveAndAtOpen() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let layer = try H.add(session, "Photo", H.image(32, 24, seed: 0))
        for stroke in 1...30 { try H.paint(session, layer, H.image(32, 24, seed: stroke), name: "Stroke \(stroke)") }
        #expect(session.history.undoCount == 31)
        let names = session.history.entries.map(\.name)
        let url = root.appendingPathComponent("Steps.comp")
        let controller = H.controller(session, settings: LWHistorySettings(storageLimitBytes: 0, stepLimit: 10))
        #expect(await controller.save(to: url), "\(controller.notices)")
        #expect(session.history.entryLimit == 10 && session.history.undoCount == 10 && session.history.entries.map(\.name) == Array(names.suffix(10)))
        let reopened = try await H.open(url, settings: LWHistorySettings(storageLimitBytes: 0, stepLimit: 10))
        #expect(reopened.session.history.entries.map(\.name) == Array(names.suffix(10)), "the newest 10 were saved")
        // Saved under 30, opened under 10.
        let wide = EditorSession()
        let wideLayer = try H.add(wide, "Photo", H.image(32, 24, seed: 0))
        for stroke in 1...30 { try H.paint(wide, wideLayer, H.image(32, 24, seed: stroke), name: "Stroke \(stroke)") }
        let wideURL = root.appendingPathComponent("Wide.comp")
        #expect(await H.controller(wide, settings: LWHistorySettings(storageLimitBytes: 0, stepLimit: 100)).save(to: wideURL))
        let narrow = try await H.open(wideURL, settings: LWHistorySettings(storageLimitBytes: 0, stepLimit: 10))
        #expect(narrow.session.history.undoCount == 10 && narrow.session.history.entries.map(\.name) == Array(names.suffix(10)))
        while narrow.session.canUndo { await narrow.session.undoNow(); #expect(narrow.session.commandRefusal == nil) }
        #expect(narrow.session.history.redoCount == 10)
    }

    /// A blob is decompressed through a stream that stops one byte past what its record allows: a crafted blob that
    /// expands without end is refused before it can take memory, a cut-short one is refused as damaged.
    @Test func decompressionStopsAtTheSizeTheRecordAllows() throws {
        let plain = Data(repeating: 7, count: 1_000_000)
        let packed = try (plain as NSData).compressed(using: .lzfse) as Data
        #expect(packed.count < 10_000)
        #expect(try LWHistoryArchive.inflate(packed, maximumBytes: plain.count) == plain)
        #expect(throws: ProjectError.self) { try LWHistoryArchive.inflate(packed, maximumBytes: plain.count - 1) }
        do { _ = try LWHistoryArchive.inflate(packed, maximumBytes: 4096); Issue.record("a blob larger than its record was read") }
        catch ProjectError.tooLarge {} catch { Issue.record("\(error)") }
        #expect(throws: ProjectError.self) { try LWHistoryArchive.inflate(packed.prefix(packed.count / 2), maximumBytes: plain.count) }
    }

    final class Stages: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [LWHistoryArchive.Stage: Int] = [:]
        func note(_ stage: LWHistoryArchive.Stage) { lock.withLock { seen[stage, default: 0] += 1 } }
        func count(_ stage: LWHistoryArchive.Stage) -> Int { lock.withLock { seen[stage] ?? 0 } }
        func reset() { lock.withLock { seen = [:] } }
    }

    /// A save neither cuts nor compresses again what the package it replaces already holds: states stored there are
    /// carried first, so a state in memory that shares an image with one finds it already staged; and a tile the
    /// old History holds is cloned even when no state still carried names it.
    @Test func aSaveReusesWhatTheOldPackageHoldsInsteadOfCompressingItAgain() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let stages = Stages()
        // Carried first: an image a stored state holds, met again in a state made since, is not cut again. (The order
        // in which states are visited otherwise follows their identities, so four documents cover either order.)
        for run in 0..<4 {
            let session = EditorSession()
            let x = try H.add(session, "X", H.image(512, 512, seed: 100 + run)), y = try H.add(session, "Y", H.image(64, 64, seed: 200 + run))
            try H.paint(session, x, H.image(512, 512, seed: 300 + run), name: "Paint X")
            let url = root.appendingPathComponent("Carry\(run).comp")
            let controller = H.controller(session, settings: LWHistorySettings(storageLimitBytes: 0))
            #expect(await controller.save(to: url))
            session.undo()                                     // X back to its first image, which only History holds
            try H.paint(session, y, H.image(64, 64, seed: 400 + run), name: "Paint Y")
            try H.paint(session, x, H.image(512, 512, seed: 500 + run), name: "Paint X Again")
            stages.reset()
            controller.historyFault = { stages.note($0) }
            #expect(await controller.save(), "\(controller.notices)")
            // Y's first image (one tile), which the old package held as its own document rather than in History, is
            // cut and compressed. X's first image, met again in the state made with Y's new one, comes with the state
            // carried first: it is not cut again. (Y's new image is the document's own now.)
            #expect(stages.count(.ingest) == 1 && stages.count(.blob) == 1, "run \(run): ingest \(stages.count(.ingest)) blob \(stages.count(.blob))")
            let reopened = try await H.open(url)
            while reopened.session.canUndo { await reopened.session.undoNow(); #expect(reopened.session.commandRefusal == nil) }
        }
        // Cloned: X painted back to pixels the old History holds (a new image with the same content), after the steps
        // that held them were dropped. Its tiles are cloned from the old package, not compressed again.
        let session = EditorSession()
        let x = try H.add(session, "X", H.image(512, 512, seed: 1))
        _ = try H.add(session, "Y", H.image(64, 64, seed: 2))
        try H.paint(session, x, H.image(512, 512, seed: 3), name: "X1")
        try H.paint(session, x, H.image(512, 512, seed: 4), name: "X2")
        let url = root.appendingPathComponent("Clone.comp")
        let controller = H.controller(session, settings: LWHistorySettings(storageLimitBytes: 0))
        #expect(await controller.save(to: url))
        session.history.entryLimit = 1; session.history.entryLimit = 2
        try H.paint(session, x, H.image(512, 512, seed: 3), name: "X1 Again")   // the pixels of X1, a new image
        try H.paint(session, x, H.image(512, 512, seed: 5), name: "X3")
        stages.reset()
        controller.historyFault = { stages.note($0) }
        #expect(await controller.save(), "\(controller.notices)")
        // X2 (the document the old package held as its own) is cut and compressed (its four tiles are one repeated
        // tile, stored once). "X1 Again" is cut, but its tile is in the old History: it is cloned, not compressed.
        #expect(stages.count(.ingest) == 2 && stages.count(.blob) == 1, "ingest \(stages.count(.ingest)) blob \(stages.count(.blob))")
        let reopened = try await H.open(url)
        await reopened.session.undoNow()
        #expect(reopened.session.commandRefusal == nil)
        let shown = try #require(reopened.session.document?.layers.first?.asset)
        #expect(try H.pixels(shown) == H.pixels(F.asset(H.image(512, 512, seed: 3), "X")))
    }

    /// A step whose state has left memory is read back off the main thread while the session is busy, as an open
    /// is: Undo returns at once, nothing else can start, and the step lands when the read finishes.
    @Test func aStoredStepIsReadBackOffTheMainThreadWhileTheSessionIsBusy() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, moments, _) = try strokes(3)
        let url = root.appendingPathComponent("Busy.comp")
        #expect(await H.controller(session).save(to: url))
        let reopened = try await H.open(url)
        let other = reopened.session
        let shown = try H.describe(other.document)
        other.undo()
        #expect(other.isProjectBusy && other.historyRead != nil, "the read is under way and the session is busy")
        #expect(try H.describe(other.document) == shown && !other.canUndo && !other.canUseHistory, "nothing changes, and nothing else starts, until it lands")
        await other.finishHistoryRead()
        #expect(!other.isProjectBusy && other.historyRead == nil && other.commandRefusal == nil)
        #expect(try H.describe(other.document) == moments[moments.count - 2].document && other.history.redoCount == 1)
        // A state already in memory needs no read: Redo lands at once.
        other.redo()
        #expect(!other.isProjectBusy && other.history.redoCount == 0)
    }

    /// Staged packages that saves which never finished (the process killed) left beside a project are collected by
    /// a later successful save, once they are old enough that no save can still be writing them; nothing else is.
    @Test func aSaveCollectsTheStagedPackagesKilledSavesLeftBehind() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, _, _) = try strokes(1)
        let url = root.appendingPathComponent("Collect.comp")
        let controller = H.controller(session)
        #expect(await controller.save(to: url))
        func staged(_ name: String, age: TimeInterval) throws -> URL {
            let made = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: made.appendingPathComponent("History"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: made.appendingPathComponent("manifest.json"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: made.path)
            return made
        }
        let abandoned = try staged(".LensWorks-\(UUID().uuidString).comp", age: 2 * 60 * 60)
        let recent = try staged(".LensWorks-\(UUID().uuidString).comp", age: 60)
        let unrelated = try staged(".LensWorks-notastage.comp", age: 2 * 60 * 60)
        let visible = try staged("LensWorks-\(UUID().uuidString).comp", age: 2 * 60 * 60)
        try H.paint(session, try #require(session.activeLayerID), H.image(200, 160, seed: 9))
        #expect(await controller.save(), "\(controller.notices)")
        #expect(!FileManager.default.fileExists(atPath: abandoned.path), "a staged package older than an hour is collected")
        for kept in [recent, unrelated, visible] { #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent) is kept") }
        #expect(ProjectStore.abandonedStageAge == 60 * 60)
    }
}
