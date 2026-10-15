import AppKit
import CryptoKit
import Testing
@testable import Compositor

/// Shared fixtures for the S17 suites (independent versions, persistent undo, checkpoints). Everything is written
/// under a private temporary folder; controllers are set up so nothing reaches Open Recent, the shared version
/// index, the person's defaults or the Trash, and every question an alert would ask is answered in code.
@MainActor
enum HistoryFixture {
    typealias F = LayerGraphFixture

    static func folder(_ name: String = "History") throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("LWS17-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
        return try #require(made.physicalFileURL)
    }

    /// A controller that asks nobody and records nothing outside the test's own folder.
    static func configure(_ controller: ProjectController, settings: LWHistorySettings = LWHistorySettings(), index: LensWorksCatalogIndex? = nil) {
        controller.recordsRecentProjects = false
        controller.sharesWorkingVersions = false
        controller.collectsNotices = true
        controller.historySettings = { settings }
        controller.answerLoss = { _ in false }
        controller.answerName = { _ in nil }
        controller.removeVersionPackage = { _ in throw CocoaError(.featureUnsupported) }
        if let index { controller.versionIndex = index }
    }
    static func controller(_ session: EditorSession = EditorSession(), settings: LWHistorySettings = LWHistorySettings(), index: LensWorksCatalogIndex? = nil) -> ProjectController {
        let controller = ProjectController(session: session)
        configure(controller, settings: settings, index: index)
        return controller
    }
    /// Opens a package into a fresh session, as launching the app and opening it would.
    static func open(_ url: URL, settings: LWHistorySettings = LWHistorySettings(), index: LensWorksCatalogIndex? = nil) async throws -> ProjectController {
        let opened = controller(settings: settings, index: index)
        #expect(await opened.open(url), "\(opened.notices)")
        return opened
    }

    // MARK: Edits

    /// An opaque 8-bit pattern (opaque so a PNG round trip returns the very same bytes).
    static func image(_ width: Int, _ height: Int, seed: Int) -> CGImage { F.pattern(width, height, seed: seed, alpha: 255) }
    @discardableResult
    static func add(_ session: EditorSession, _ name: String, _ image: CGImage) throws -> UUID {
        session.insert(F.asset(image, name))
        return try #require(session.activeLayerID)
    }
    /// Replaces a layer's pixels as one undo step, the way a finished brush stroke does.
    static func paint(_ session: EditorSession, _ id: UUID, _ image: CGImage, name: String = "Brush Stroke", origin: LensWorksCommandOrigin = .user) throws {
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.history.begin(name, document: session.document, selection: session.activeLayerID, selected: session.selectedLayerIDs, origin: origin)
        let layerName = try #require(session.document?.layers[index].name)
        session.document?.layers[index].asset = F.asset(image, layerName)
        session.endEdit()
    }
    /// `image` with a `side`-pixel square at (`x`, `y`) replaced: a local edit, as a dab of paint is.
    static func dab(_ image: CGImage, x: Int, y: Int, side: Int, seed: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self), row = context.bytesPerRow
        for py in y..<min(image.height, y + side) { for px in x..<min(image.width, x + side) {
            let o = py * row + px * 4
            data[o] = UInt8((px * 7 + seed * 31) % 256); data[o + 1] = UInt8((py * 5 + seed * 17) % 256); data[o + 2] = UInt8((px + py + seed) % 256); data[o + 3] = 255
        } }
        return try #require(context.makeImage())
    }

    // MARK: Comparison

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// An image's pixels drawn pixel for pixel, so two images with the same content compare equal whatever backs them.
    static func pixels(_ asset: ImportedImage, mask: Bool = false) throws -> String {
        if let plane = asset.linearPlane {
            let samples = try F.pixels(plane)
            return "float " + sha(samples.withUnsafeBytes { Data($0) })
        }
        if let linear = asset.linear { return "float " + sha(linear.pixels.withUnsafeBytes { Data($0) }) }
        let image = asset.image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: mask)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: mask, context: context)
        return sha(Data(bytes: try #require(context.data), count: context.bytesPerRow * image.height))
    }
    /// Everything about a document a save keeps, one line per layer, with the pixels by their digest.
    static func describe(_ document: CanvasDocument?) throws -> [String] {
        guard let document else { return ["no document"] }
        var lines = ["\(document.id) \(document.width)x\(document.height) @\(document.resolution) guides \(document.guides.map { "\($0.id) \($0.position)" })"]
        if let selection = document.selection { lines.append("selection \(selection.path.boundingBoxOfPath) \(selection.antialiased) \(selection.feather)") }
        for layer in document.layers {
            var line = "\(layer.id) \(layer.name) visible \(layer.isVisible) at \(layer.transform.origin) \(layer.transform.size) r\(layer.transform.rotation)"
            line += " parent \(layer.parentID?.uuidString ?? "-") group \(layer.isGroup) opacity \(layer.opacity) blend \(layer.blendMode) clip \(layer.maskSourceID?.uuidString ?? "-")"
            line += " adjustment \(layer.adjustment.map { String(describing: $0.kind) } ?? "-") source \(layer.liveSource?.revision.uuidString ?? "-")"
            if let shape = layer.liveShape { line += " shape \(shape.style)" }
            if let text = layer.liveText { line += " text \(text.style)" }
            if let effects = layer.effects { line += " effects \(effects)" }
            if let adjustment = layer.adjustment { line += " hue \(adjustment.hue) blur \(String(describing: adjustment.blurRadius))" }
            if let asset = layer.asset { line += " pixels " + (try pixels(asset)) }
            if let mask = layer.mask { line += " mask \(mask.isEnabled) \(mask.isLinked) \(String(describing: mask.placement)) " + (try pixels(mask.asset, mask: true)) }
            if let coverage = layer.bakedCoverage { line += " coverage " + (try pixels(coverage, mask: true)) }
            lines.append(line)
        }
        return lines
    }
    struct Moment: Equatable {
        let document: [String]
        let active: UUID?
        let selected: Set<UUID>
    }
    static func moment(_ session: EditorSession) throws -> Moment {
        Moment(document: try describe(session.document), active: session.activeLayerID, selected: session.selectedLayerIDs)
    }

    /// Every file in a package by its path, with its content's digest: equal maps are byte-identical packages.
    static func files(_ package: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let walker = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        let base = package.resolvingSymlinksInPath().path
        for case let url as URL in walker where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            result[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = sha(try Data(contentsOf: url))
        }
        return result
    }
    static func historyBytes(_ package: URL) -> Int64 { LWHistoryArchive.bytes(in: package) }
    /// The hidden staging packages a save assembles beside its destination; none may be left behind.
    static func staged(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".LensWorks-") }
    }

    // MARK: Working versions

    /// A catalog working version of an "original" that exists only in the test's folder, saved and registered in
    /// the test's own index.
    static func version(named name: String, in root: URL, index: LensWorksCatalogIndex, settings: LWHistorySettings = LWHistorySettings(),
                        controller existing: ProjectController? = nil) async throws -> ProjectController {
        let session = existing?.session ?? EditorSession()
        let original = root.appendingPathComponent("Original.png"), catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let versions = root.appendingPathComponent("Versions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
            try Data("original pixels".utf8).write(to: original)
        }
        let made = existing ?? controller(session, settings: settings, index: index)
        if session.document == nil {
            try add(session, "Photo", image(64, 48, seed: 1))
            try add(session, "Retouch", image(32, 24, seed: 2))
        }
        let id = UUID(), project = LensWorksVersionStore.packageURL(named: name, id: id, in: versions)
        made.workingVersion = LensWorksWorkingVersion(id: id, photoID: "photo-1", catalogPath: catalog.path, originalPath: original.path, projectPath: project.path, name: name)
        #expect(await made.save(to: project), "\(made.notices)")
        _ = try await index.register(project)
        await made.refreshSiblingVersions()
        return made
    }
}

extension EditorSession {
    /// Undo, Redo and Restore Checkpoint read a state that has left memory back from the package off the main
    /// thread; these wait for that, as the person waits for the window to come back.
    func undoNow() async { undo(); await finishHistoryRead() }
    func redoNow() async { redo(); await finishHistoryRead() }
    func restoreCheckpointNow(_ id: UUID) async -> Bool { let started = restoreCheckpoint(id); await finishHistoryRead(); return started }
}
