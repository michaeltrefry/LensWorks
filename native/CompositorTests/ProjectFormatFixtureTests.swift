import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

/// S17: a document saved by an earlier schema opens, upgrades and round-trips without loss.
///
/// `native/Fixtures/ProjectFormats` holds one frozen package per project format version (1–13, 15) and one with a
/// History folder per history schema. They are files, written once and never regenerated, so a change to the reader
/// or writer is tested against bytes an earlier build produced. Versions 12, 13 and 15 were written by this
/// product's own save at the time. Versions 1–11 were written by the Compositor app LensWorks grew from
/// (`vendor/Compositor`, whose `ProjectStore` is the version-11 writer); no package it saved survives in its tree or
/// its history (its tests build their manifests in code), so each of 1–11 is assembled by hand holding exactly the
/// fields that version allowed, in the layout that writer used (a manifest and PNG files), as
/// `ProjectTests.aVersion12PackageFromTheIntegerBuildStillLoads` assembles one.
///
/// Adding a format: bump `ProjectManifest.current` (or `LWHistoryArchive.schema`), extend `Self.snapshot` (or
/// `writeMissing`), and run this suite once with `TEST_RUNNER_LW_S17_WRITE_FIXTURES=1` to write the new package and its
/// expectations. Existing fixtures are never overwritten; `theFrozenFixturesCoverEveryFormatThisBuildReads` fails
/// until the new one is committed.
@MainActor
struct ProjectFormatFixtureTests {
    typealias H = HistoryFixture
    typealias F = LayerGraphFixture

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ProjectFormats", isDirectory: true)
    /// Version 14 (retained plugin steps, sc-25324) has its frozen fixture with that change; it is the one version
    /// this build reads but has no content of its own for (see `aVersion14PackageOpensAndIsWrittenInTheFormatItNeeds`).
    static let versions = Array(ProjectManifest.supported).filter { $0 != ProjectManifest.retainedPluginSteps }
    static func name(_ version: Int) -> String { String(format: "v%02d", version) }
    static let historyName = "v13-history\(LWHistoryArchive.schema)"
    static let names = versions.map(name) + [historyName]

    struct Expected: Codable, Equatable {
        struct History: Codable, Equatable {
            var past: [String]
            var future: [String]
            var origins: [String]
            var checkpoints: [String]
            /// The document after each Undo from where it was saved, down to the first state.
            var undo: [[String]]
            var checkpoint: [String]
        }
        var version: Int
        var document: [String]
        var history: History?
    }

    // MARK: Building (only when writing a new fixture)

    private static func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))! }
    /// A document using everything format `version` could hold, and nothing later.
    static func snapshot(_ version: Int, workspace: LWFloatWorkspace? = nil) throws -> ProjectSnapshot {
        var layers: [ProjectLayerRecord] = [], images: [UUID: ImportedImage] = [:], masks: [UUID: ImportedImage] = [:]
        func raster(_ number: Int, _ name: String, _ width: Int, _ height: Int, at origin: CGPoint) -> ProjectLayerRecord {
            images[id(number)] = F.asset(H.image(width, height, seed: number), name)
            return F.raster(id: id(number), name, images[id(number)]!.image, at: origin)
        }
        layers.append(raster(1, "Base", 48, 32, at: .zero))
        var top = raster(2, "Top", 20, 12, at: CGPoint(x: 5, y: 4)); top.isVisible = false
        var folder: ProjectLayerRecord?, inside: ProjectLayerRecord?
        if version >= 2 {
            folder = F.folder(id: id(3), "Folder", width: 48, height: 32)
            inside = raster(4, "Inside", 16, 10, at: CGPoint(x: 30, y: 20)); inside?.parentID = id(3)
        }
        if version >= 3 { top.opacity = 0.75; top.blendMode = .multiply }
        if version >= 4 {
            masks[id(2)] = try F.ramp(20, 12, seed: 2)
            top.maskFile = id(2).uuidString + ".mask.png"; top.maskEnabled = false; top.maskLinked = false
            var placement = LayerTransform(origin: CGPoint(x: 6, y: 5), size: CGSize(width: 20, height: 12)); placement.sampling = .nearest
            top.maskPlacement = placement
        }
        if version >= 5 { inside?.maskSourceID = id(1) }
        if version >= 6 { masks[id(3)] = try F.ramp(48, 32, seed: 3); folder?.maskFile = id(3).uuidString + ".mask.png" }
        layers.append(top)
        if let folder { layers.append(folder) }
        if let inside { layers.append(inside) }
        if version >= 7 { layers.append(F.adjustment(id: id(5), "Hue", LayerAdjustment(kind: .hsv, hue: 20), width: 48, height: 32)) }
        var guides: [CanvasGuide]?
        if version >= 8 {
            guides = [CanvasGuide(id: id(20), axis: .vertical, position: 10.5), CanvasGuide(id: id(21), axis: .horizontal, position: 7)]
            layers[layers.firstIndex { $0.id == id(3) }!].opacity = 0.6
            var shape = raster(6, "Shape", 12, 8, at: CGPoint(x: 2, y: 22))
            shape.shape = LayerShapeStyle(kind: .rectangle, red: 0.2, green: 0.4, blue: 0.6, cornerRadius: 2)
            shape.effects = LayerEffects(stroke: StrokeEffect(size: 3, red: 1, green: 0.5, blue: 0, opacity: 0.8))
            layers.append(shape)
        }
        if version >= 9 { var blur = LayerAdjustment(kind: .gaussianBlur); blur.blurRadius = 1.5; layers.append(F.adjustment(id: id(7), "Blur", blur, width: 48, height: 32)) }
        if version >= 10 {
            var text = raster(8, "Text", 24, 10, at: CGPoint(x: 20, y: 2))
            var style = LayerTextStyle(content: "S17 text", fontSize: 9)
            style.colorRuns = [LayerTextColorRun(location: 0, length: 3, red: 1, green: 0, blue: 0)]
            if version >= 11 { style.fontRuns = [LayerTextFontRun(location: 4, length: 4, fontName: "Courier")] }
            text.text = style
            layers.append(text)
        }
        if version >= 13, let workspace {
            let image = H.image(24, 16, seed: 9)
            images[id(9)] = try F.floatAsset(image, gain: 4, workspace: workspace, name: "Float")
            var float = F.raster(id: id(9), "Float", image, at: CGPoint(x: 12, y: 8))
            float.imageFile = id(9).uuidString + ".plane"; float.planeArchiveReference = images[id(9)]?.planeArchiveReference
            layers.append(float)
        }
        let manifest = ProjectManifest(version: version, resolution: version >= 2 ? 300 : nil, documentID: id(100), width: 48, height: 32,
            activeLayerID: id(2), layers: layers, guides: guides)
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }
    /// Version 15's content: a live source layer (developed from a procedural RAW in a temporary folder) whose own
    /// mask is switched off, with the coverage of a deleted clipping source baked into its coverage slot.
    static func bakedCoverageSnapshot() async throws -> ProjectSnapshot {
        let root = try H.folder("v15-original")
        let original = root.appendingPathComponent("v15.dng")
        try ProceduralDNG.write(to: original, width: 48, height: 32)
        let session = EditorSession()
        await session.importImages([original])
        let live = try #require(session.activeLayer)
        var soft = ImageLayer(id: id(30), asset: F.asset(F.pattern(24, 16, seed: 5), "Soft"), name: "Soft", isVisible: false,
            transform: LayerTransform(origin: CGPoint(x: 6, y: 4), size: CGSize(width: 24, height: 16)), opacity: 0.8)
        soft.transform.sampling = .nearest
        session.document?.layers.append(soft)
        let index = try #require(session.document?.layers.firstIndex { $0.id == live.id })
        session.document?.layers[index].maskSourceID = soft.id
        let grid = try #require(live.asset?.image)
        session.document?.layers[index].mask = LayerMask(asset: try F.mask(grid.width, grid.height) { x, _ in 90 + x * 2 }, isEnabled: false)
        #expect(session.deleteWithLiveMaskChoice([soft.id]) { _ in .bake })
        try await LayerGraphOperationTests.idle(session)
        #expect(session.document?.layers.first?.bakedCoverage != nil)
        return try #require(session.projectSnapshot())
    }
    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    /// Writes the fixtures this build can read that are not in the folder yet. Existing ones are left alone.
    private static func writeMissing() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func expectations(_ name: String, _ expected: Expected) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(expected).write(to: folder.appendingPathComponent(name + ".expected.json"))
        }
        for version in versions {
            let package = folder.appendingPathComponent(name(version) + ".comp")
            guard !FileManager.default.fileExists(atPath: package.path) else { continue }
            if version == 15 {
                try await ProjectStore.shared.save(try await bakedCoverageSnapshot(), to: package)
            } else if version >= ProjectManifest.baseline {
                let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
                try await ProjectStore.shared.save(try snapshot(version, workspace: workspace), to: package)
            } else {
                // As a build of that version wrote it: a plain manifest and PNG files.
                let made = try snapshot(version)
                let images = package.appendingPathComponent("images", isDirectory: true)
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(made.manifest).write(to: package.appendingPathComponent("manifest.json"))
                for layer in made.manifest.layers {
                    if let file = layer.imageFile { try png(try #require(made.images[layer.id]).image).write(to: images.appendingPathComponent(file)) }
                    if let file = layer.maskFile { try png(try #require(made.masks[layer.id]).image).write(to: images.appendingPathComponent(file)) }
                }
            }
            let opened = try await H.open(try staged(name(version)))
            try expectations(name(version), Expected(version: version, document: try H.describe(opened.session.document), history: nil))
        }
        let package = folder.appendingPathComponent(historyName + ".comp")
        guard !FileManager.default.fileExists(atPath: package.path) else { return }
        // The newest format, edited: a rename, two strokes (one an agent's), a checkpoint, a canvas selection, and
        // one step undone so the package holds a redo step too.
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let session = EditorSession()
        session.document = CanvasDocument(try snapshot(ProjectManifest.current, workspace: workspace))
        session.selectLayer(id(1))
        session.renameLayer(id(1), to: "Background")
        try H.paint(session, id(1), H.image(48, 32, seed: 31))
        #expect(session.createCheckpoint(named: "Frozen") != nil)
        let checkpoint = try H.describe(session.document)
        try H.paint(session, id(4), H.image(16, 10, seed: 32), name: "Agent Stroke", origin: .agent)
        session.beginEdit("Select")
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 4, y: 4, width: 20, height: 10), transform: nil), antialiased: false, feather: 0)
        session.endEdit()
        session.selectLayers([id(1), id(2)], primary: id(2))
        session.beginEdit("Hide Layers"); session.document?.layers[0].isVisible = false; session.endEdit()
        await session.undoNow()
        let controller = H.controller(session, settings: LWHistorySettings(storageLimitBytes: 0))
        #expect(await controller.save(to: package), "\(controller.notices)")
        let opened = try await H.open(try staged(historyName))
        var expected = Expected(version: ProjectManifest.current, document: try H.describe(opened.session.document), history: nil)
        var history = Expected.History(past: opened.session.history.entries.prefix(opened.session.history.undoCount).map(\.name),
            future: opened.session.history.entries.dropFirst(opened.session.history.undoCount).map(\.name),
            origins: opened.session.history.entries.map { LWHistoryOriginCoding.encode($0.origin) }, checkpoints: opened.session.history.checkpoints.map(\.name), undo: [], checkpoint: checkpoint)
        while opened.session.canUndo { await opened.session.undoNow(); history.undo.append(try H.describe(opened.session.document)) }
        expected.history = history
        try expectations(historyName, expected)
    }

    // MARK: Reading

    /// A private copy of a fixture. Git keeps no permission bits beyond "executable", and a float plane's archive
    /// must be private and read-only to be admitted, so the copy gets the permissions a save gives it.
    static func staged(_ name: String, in root: URL? = nil) throws -> URL {
        let root = try root ?? H.folder(name)
        let copy = root.appendingPathComponent(name + ".comp")
        try FileManager.default.copyItem(at: folder.appendingPathComponent(name + ".comp"), to: copy)
        let walker = try #require(FileManager.default.enumerator(at: copy, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let url as URL in walker where url.path.contains(".plane") {
            let directory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o444], ofItemAtPath: url.path)
        }
        return copy
    }
    static func expected(_ name: String) throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: folder.appendingPathComponent(name + ".expected.json")))
    }
    private func formatVersion(_ package: URL) throws -> Int {
        let header = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any]
        return try #require(header?["version"] as? Int)
    }

    /// One frozen package for every format version this build reads, and one for its history schema. With
    /// `LW_S17_WRITE_FIXTURES` set, the missing ones are written first (and then have to be committed).
    @Test func theFrozenFixturesCoverEveryFormatThisBuildReads() async throws {
        if ProcessInfo.processInfo.environment["LW_S17_WRITE_FIXTURES"] != nil { try await Self.writeMissing() }
        #expect(Self.versions == Array(1...13) + [15] && ProjectManifest.current == 15 && ProjectManifest.retainedPluginSteps == 14)
        for name in Self.names {
            #expect(FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(name + ".comp/manifest.json").path),
                "native/Fixtures/ProjectFormats/\(name).comp is missing: a new format needs its frozen fixture (see this file's header)")
            #expect(FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(name + ".expected.json").path))
        }
        for version in Self.versions {
            #expect(try formatVersion(Self.folder.appendingPathComponent(Self.name(version) + ".comp")) == version, "\(Self.name(version)) is written in format \(version)")
        }
        #expect(FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(Self.historyName + ".comp/History/index.json").path))
    }

    /// Every frozen package opens as what it was frozen as, saves in today's format, and reopens the same: layers,
    /// pixels, masks, folders, clipping, adjustments, shapes, text, effects and guides, and — where the package has
    /// history — every undo step, the redo step, who made each, and the checkpoint.
    @Test(arguments: ProjectFormatFixtureTests.names)
    func everyFrozenFormatOpensUpgradesAndRoundTripsWithoutLoss(_ name: String) async throws {
        let root = try H.folder(name); defer { try? FileManager.default.removeItem(at: root) }
        let expected = try Self.expected(name)
        let package = try Self.staged(name, in: root)
        #expect(try formatVersion(package) == expected.version)
        let frozen = try H.files(package)
        func check(_ controller: ProjectController, _ stage: String) async throws {
            let session = controller.session
            #expect(controller.notices.isEmpty && !session.isModified, "\(stage): \(controller.notices)")
            #expect(try H.describe(session.document) == expected.document, "\(stage): the document differs from what was frozen")
            guard let history = expected.history else { #expect(!session.canUndo && session.history.checkpoints.isEmpty); return }
            #expect(session.history.entries.prefix(session.history.undoCount).map(\.name) == history.past, "\(stage)")
            #expect(session.history.entries.dropFirst(session.history.undoCount).map(\.name) == history.future, "\(stage)")
            #expect(session.history.entries.map { LWHistoryOriginCoding.encode($0.origin) } == history.origins && session.history.checkpoints.map(\.name) == history.checkpoints, "\(stage)")
            for (step, state) in history.undo.enumerated() {
                await session.undoNow()
                #expect(session.commandRefusal == nil, "\(stage): \(session.commandRefusal ?? "")")
                #expect(try H.describe(session.document) == state, "\(stage): undo step \(step + 1) differs from what was frozen")
            }
            #expect(!session.canUndo)
            #expect(await session.restoreCheckpointNow(try #require(session.history.checkpoints.first?.id)))
            #expect(try H.describe(session.document) == history.checkpoint, "\(stage): the checkpoint differs from what was frozen")
        }
        try await check(try await H.open(package), "opened")
        #expect(try H.files(package) == frozen, "opening and undoing change nothing on disk")
        // Upgrade: saved by this build, in this build's format, to a new place.
        let opened = try await H.open(package)
        let upgraded = root.appendingPathComponent("Upgraded.comp")
        #expect(await opened.save(to: upgraded), "\(opened.notices)")
        let written = try formatVersion(upgraded)
        // The lowest format that can hold what it holds: float and live RAW content needs 13, a baked coverage 15.
        #expect(written == max(ProjectManifest.baseline, expected.version), "an upgraded document is written in the format its content needs, not \(written)")
        try await check(try await H.open(upgraded), "upgraded and reopened")
        // And once more from the upgraded copy: a second round trip changes nothing either.
        let again = try await H.open(upgraded)
        let second = root.appendingPathComponent("Again.comp")
        #expect(await again.save(to: second), "\(again.notices)")
        try await check(try await H.open(second), "round-tripped twice")
        for controller in [opened, again] { try await controller.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by: .seconds(30))) }
    }

    /// Version 14 is sc-25324's (retained plugin steps). A version-14 package holding only what this build knows
    /// opens as it is and is written back in the lowest format its content needs; a baked coverage, which arrived
    /// in 15, is refused in a package that says 14.
    @Test func aVersion14PackageOpensAndIsWrittenInTheFormatItNeeds() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        func relabelled(_ name: String) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let package = try Self.staged(name, in: folder)
            let file = package.appendingPathComponent("manifest.json")
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["version"] = ProjectManifest.retainedPluginSteps
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            return package
        }
        #expect(ProjectManifest.supported.contains(14))
        let package = try relabelled(Self.name(13))
        #expect(try formatVersion(package) == 14)
        let opened = try await H.open(package)
        #expect(opened.notices.isEmpty && !opened.session.isModified, "\(opened.notices)")
        #expect(try H.describe(opened.session.document) == Self.expected(Self.name(13)).document)
        let upgraded = root.appendingPathComponent("Upgraded.comp")
        #expect(await opened.save(to: upgraded), "\(opened.notices)")
        #expect(try formatVersion(upgraded) == ProjectManifest.floatContent)
        try await opened.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        do { _ = try await ProjectStore.shared.load(from: try relabelled(Self.name(15))); Issue.record("a baked coverage needs version 15") }
        catch { if case .invalid? = error as? ProjectError {} else { Issue.record("\(error)") } }
    }

    /// Every field a package keeps, read back by name from every frozen package and compared with the document
    /// that version was frozen from, so a reader that drops or changes one fails here whatever the round trip above
    /// happens to compare.
    @Test func everyFrozenPackageKeepsEveryManifestAndLayerField() async throws {
        let root = try H.folder(); defer { try? FileManager.default.removeItem(at: root) }
        func same(_ read: LWFloatPlaneArchive.Reference?, _ made: LWFloatPlaneArchive.Reference?) -> Bool {
            // A plane is named by the digest of its tiles, which a frozen package and a document built again share
            // only in their dimensions.
            (read == nil) == (made == nil) && read?.width == made?.width && read?.height == made?.height
        }
        for version in Self.versions {
            let folder = root.appendingPathComponent("\(version)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let package = try Self.staged(Self.name(version), in: folder)
            let loaded = try await ProjectStore.shared.load(from: package)
            let manifest = loaded.manifest
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let made = version == 15 ? try await Self.bakedCoverageSnapshot().manifest : try Self.snapshot(version, workspace: workspace).manifest
            let at = "v\(version)"
            #expect(manifest.format == "com.compositor.project" && manifest.version == version && manifest.colorSpace == "sRGB", "\(at)")
            #expect(manifest.resolution == made.resolution && manifest.width == made.width && manifest.height == made.height, "\(at)")
            #expect(manifest.guides == made.guides && manifest.workingVersionID == made.workingVersionID && manifest.layers.count == made.layers.count, "\(at)")
            let floating = made.layers.contains { $0.imageFile?.hasSuffix(".plane") == true || $0.liveSource != nil }
            #expect((manifest.workingSpace == "extended-linear-sRGB") == floating && (manifest.workingSample == "float32-straight-RGBA") == floating, "\(at)")
            if version != 15 { #expect(manifest.documentID == made.documentID && manifest.activeLayerID == made.activeLayerID, "\(at)") }
            #expect(loaded.workingVersion == nil && loaded.history == nil && loaded.newerHistorySchema == nil, "\(at)")
            for (read, wrote) in zip(manifest.layers, made.layers) {
                let field = "\(at) \(wrote.name)"
                #expect(read.name == wrote.name && read.isVisible == wrote.isVisible && read.transform == wrote.transform, "\(field)")
                #expect((read.imageFile == nil) == (wrote.imageFile == nil) && read.imageFile?.split(separator: ".").last == wrote.imageFile?.split(separator: ".").last, "\(field)")
                #expect(read.parentID == wrote.parentID && (read.isGroup ?? false) == (wrote.isGroup ?? false), "\(field)")
                #expect((read.opacity ?? 1) == (wrote.opacity ?? 1) && (read.blendMode ?? .normal) == (wrote.blendMode ?? .normal), "\(field)")
                #expect((read.maskFile == nil) == (wrote.maskFile == nil) && read.maskEnabled == wrote.maskEnabled, "\(field)")
                #expect(read.maskPlacement == wrote.maskPlacement && read.maskLinked == wrote.maskLinked && read.adjustment == wrote.adjustment, "\(field)")
                #expect(read.shape == wrote.shape && read.effects == wrote.effects && read.text == wrote.text, "\(field)")
                #expect((read.liveSource == nil) == (wrote.liveSource == nil) && read.liveSourceFile == nil, "\(field): a live source is hydrated before the editor sees it")
                #expect(same(read.planeArchiveReference, wrote.planeArchiveReference) && same(read.maskPlaneArchiveReference, wrote.maskPlaneArchiveReference), "\(field)")
                #expect((read.coverageFile == nil) == (wrote.coverageFile == nil) && same(read.coveragePlaneArchiveReference, wrote.coveragePlaneArchiveReference), "\(field)")
                if version != 15 {
                    #expect(read.id == wrote.id && read.imageFile == wrote.imageFile && read.maskFile == wrote.maskFile && read.maskSourceID == wrote.maskSourceID, "\(field)")
                } else {
                    #expect(read.coverageFile == read.id.uuidString + ".coverage.plane" && read.maskEnabled == false && read.maskSourceID == nil, "\(field)")
                    #expect(loaded.coverages[read.id] != nil && loaded.masks[read.id] != nil, "\(field)")
                }
            }
            // What each version added, by name.
            let top = manifest.layers.first { $0.name == "Top" }
            if version >= 3, version < 15 { #expect(top?.opacity == 0.75 && top?.blendMode == .multiply, "\(at)") }
            if version >= 4, version < 15 { #expect(top?.maskEnabled == false && top?.maskLinked == false && top?.maskPlacement?.origin == CGPoint(x: 6, y: 5) && top?.isVisible == false, "\(at)") }
            if version >= 5, version < 15 { #expect(manifest.layers.first { $0.name == "Inside" }?.maskSourceID == Self.id(1), "\(at)") }
            if version >= 7, version < 15 { #expect(manifest.layers.first { $0.name == "Hue" }?.adjustment?.hue == 20, "\(at)") }
            if version >= 11, version < 15 { #expect(manifest.layers.first { $0.name == "Text" }?.text?.fontRuns?.first?.fontName == "Courier", "\(at)") }
            if version == 13 { #expect(manifest.layers.first { $0.name == "Float" }?.planeArchiveReference != nil && loaded.images[Self.id(9)]?.linearPlane != nil) }
            if version == 2 { #expect(manifest.layers.first { $0.name == "Folder" }?.isGroup == true && manifest.resolution == 300) }
        }
        let package = try Self.staged(Self.name(12), in: root)

        // What a package that cannot be opened says, by error.
        func broken(_ change: (inout [String: Any]) -> Void) async throws -> ProjectError? {
            let copy = root.appendingPathComponent("Broken-\(UUID().uuidString).comp")
            try FileManager.default.copyItem(at: package, to: copy)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: copy.appendingPathComponent("manifest.json"))) as? [String: Any])
            change(&json)
            try JSONSerialization.data(withJSONObject: json).write(to: copy.appendingPathComponent("manifest.json"))
            do { _ = try await ProjectStore.shared.load(from: copy); return nil } catch { return error as? ProjectError }
        }
        if case .version(let version)? = try await broken({ $0["version"] = 99 }) { #expect(version == 99) } else { Issue.record("a newer format is refused by version") }
        if case .invalid? = try await broken({ $0["colorSpace"] = "Display P3" }) {} else { Issue.record("an unknown colour space is invalid") }
        if case .tooLarge? = try await broken({ $0["width"] = DocumentLimits.maxSide + 1 }) {} else { Issue.record("an oversized canvas is too large") }
        let missing = root.appendingPathComponent("Missing.comp")
        try FileManager.default.copyItem(at: package, to: missing)
        try Data("not a png".utf8).write(to: missing.appendingPathComponent("images/\(Self.id(1).uuidString).png"))
        do { _ = try await ProjectStore.shared.load(from: missing); Issue.record("a damaged image is refused") }
        catch { if case .missingImage? = error as? ProjectError {} else { Issue.record("\(error)") } }
        #expect(ProjectError.version(99).errorDescription == "This project uses format version 99. This app supports versions 1–\(ProjectManifest.current).")
        #expect(ProjectError.invalid.errorDescription?.contains("not a valid Compositor project") == true)
        #expect(ProjectError.missingImage.errorDescription?.contains("The current document has not been replaced") == true)
        #expect(ProjectError.tooLarge.errorDescription?.contains("megapixel document limit") == true)
        #expect(ProjectError.encode.errorDescription == "An image could not be saved. The previous project has not been replaced.")

        // The document types, and the fingerprint that tells a changed package from a touched one.
        #expect(UTType.compositorProject.identifier == "com.compositor.project" && UTType.compositorProject.conforms(to: .package))
        #expect(UTType.photoshopImage.identifier == "com.adobe.photoshop-image" && UTType.photoshopLargeImage.identifier == "com.adobe.photoshop-large-image")
        #expect(UTType.importableImages.contains(.photoshopImage) && UTType.importableImages.contains(.photoshopLargeImage) && UTType.importableImages.contains(.png))
        #expect(ProjectStore.shared === ProjectStore.shared && ProjectManifest.supported.contains(ProjectManifest.current) && ProjectManifest.supported.lowerBound == 1)
        let digest = try ProjectDigest.compute(for: package)
        #expect(digest.value.count == 32)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: package.appendingPathComponent("manifest.json").path)
        #expect(try ProjectDigest.compute(for: package) == digest, "a touched package is not a changed one")
        var text = try String(contentsOf: package.appendingPathComponent("manifest.json"), encoding: .utf8)
        text = text.replacingOccurrences(of: "\"Base\"", with: "\"Renamed\"")
        try Data(text.utf8).write(to: package.appendingPathComponent("manifest.json"))
        #expect(try ProjectDigest.compute(for: package) != digest)
    }
}
