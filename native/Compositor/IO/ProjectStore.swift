import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let compositorProject = UTType(exportedAs: "com.compositor.project", conformingTo: .package)
    nonisolated static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
    nonisolated static let photoshopLargeImage = UTType(importedAs: "com.adobe.photoshop-large-image")
    static let importableImages: [UTType] = [.jpeg, .png, .heic, .tiff, .photoshopImage, .photoshopLargeImage, .rawImage, .svg]
}

nonisolated struct ProjectManifest: Codable, Sendable {
    /// The format version new saves write.
    static let current = 13
    /// Every version `load` accepts. The package-header check, the manifest check and the error
    /// message all read this, so they cannot drift apart when `current` is bumped.
    static let supported = 1...ProjectManifest.current

    var format = "com.compositor.project"
    var version = ProjectManifest.current
    var colorSpace = "sRGB"
    var resolution: Double? = nil // Older version-1 projects default to 72 pixels/inch.
    let documentID: UUID
    let width: Int
    let height: Int
    let activeLayerID: UUID?
    var layers: [ProjectLayerRecord]
    /// Version 12: requires the matching LensWorks.json identity in the atomic package.
    var workingVersionID: UUID? = nil
    /// Alignment guides. Missing on versions 1–7.
    var guides: [CanvasGuide]? = nil
    /// Version 13: history is validated and published in this same atomic package.
    var hasHistory: Bool? = nil
    /// Same-package untitled recovery identity. Ordinary First Save clears this marker.
    var recoveryDocumentID: UUID? = nil
}

nonisolated struct ProjectLayerRecord: Codable, Sendable {
    let id: UUID
    let name: String
    var isVisible: Bool
    let transform: LayerTransform
    let imageFile: String?
    var parentID: UUID? = nil
    var isGroup: Bool? = nil
    var opacity: Double? = nil
    var blendMode: LayerBlendMode? = nil
    var maskFile: String? = nil
    var maskEnabled: Bool? = nil
    var maskSourceID: UUID? = nil
    var adjustment: LayerAdjustment? = nil
    /// A mask moved apart from its layer: where it sits on the document.
    var maskPlacement: LayerTransform? = nil
    /// Nil (older projects) is linked.
    var maskLinked: Bool? = nil
    /// A shape layer's shape, drawn again when the layer is scaled. Older versions ignore it and keep the pixels.
    var shape: LayerShapeStyle? = nil
    /// The stroke and drop shadow drawn around the layer.
    var effects: LayerEffects? = nil
    var text: LayerTextStyle? = nil
}

nonisolated struct ProjectSnapshot: @unchecked Sendable {
    let manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
    var workingVersion: LensWorksWorkingVersion? = nil
    var history: ProjectHistoryArchive? = nil
}

nonisolated struct ProjectHistoryState: @unchecked Sendable { let project: ProjectSnapshot?; let revision: UUID }
nonisolated struct ProjectHistoryEntry: @unchecked Sendable { let name: String; let before: ProjectHistoryState; let after: ProjectHistoryState }
nonisolated struct ProjectHistoryArchive: @unchecked Sendable { let past: [ProjectHistoryEntry]; let future: [ProjectHistoryEntry]; let revision: UUID }

nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions \(ProjectManifest.supported.lowerBound)–\(ProjectManifest.supported.upperBound)."
        case .missingImage: "An image inside the project is missing or damaged. The current document has not been replaced."
        case .tooLarge: "This project exceeds the supported canvas, layer, file-size, or \(DocumentLimits.documentBudgetMegapixels)-megapixel document limit."
        case .encode: "An image could not be saved. The previous project has not been replaced."
        }
    }
}

actor ProjectStore {
    static let shared = ProjectStore()
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    func save(_ snapshot: ProjectSnapshot, to url: URL, quickLook: QuickLookImages? = nil, workingVersion: LensWorksWorkingVersion? = nil, recovery: Bool = false) throws {
        try validate(snapshot.manifest)
        let version = workingVersion ?? snapshot.workingVersion
        guard snapshot.manifest.workingVersionID == nil || snapshot.manifest.workingVersionID == version?.id else { throw ProjectError.invalid }
        try version?.validateDestination(url)
        var manifest = snapshot.manifest
        manifest.workingVersionID = version?.id
        manifest.version = ProjectManifest.current
        manifest.hasHistory = snapshot.history != nil
        guard !recovery || version == nil else { throw ProjectError.invalid }
        manifest.recoveryDocumentID = recovery ? manifest.documentID : nil
        if version != nil { manifest.version = ProjectManifest.current }
        try validate(manifest)
        var images: [String: FileWrapper] = [:]
        var pixels = 0, maskPixels = 0
        for layer in snapshot.manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            guard let asset = (isMask ? snapshot.masks : snapshot.images)[layer.id] else { throw ProjectError.missingImage }
            if isMask {
                guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
                try checkSize(width: asset.image.width, height: asset.image.height, used: &maskPixels)
            } else { try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels) }
            let data = try autoreleasepool {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw ProjectError.encode
                }
                CGImageDestinationAddImage(destination, asset.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
                return data as Data
            }
            images[filename] = FileWrapper(regularFileWithContents: data)
          }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(manifest)
        guard metadata.count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
        var contents = [
            "manifest.json": FileWrapper(regularFileWithContents: metadata),
            "images": FileWrapper(directoryWithFileWrappers: images)
        ]
        if var version {
            version.projectPath = url.path
            contents["LensWorks.json"] = FileWrapper(regularFileWithContents: try version.encoded())
        }
        if let history = snapshot.history { contents["History"] = try historyWrapper(history, current: snapshot) }
        // Quick Look's Space-bar preview reads this by name; loading ignores it.
        if let quickLook {
            contents["QuickLook"] = FileWrapper(directoryWithFileWrappers: [
                "Preview.jpg": FileWrapper(regularFileWithContents: quickLook.preview),
            ])
        }
        let package = FileWrapper(directoryWithFileWrappers: contents)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do {
                // Foundation stages a sibling package and atomically replaces the
                // destination only once the complete package has been written.
                try package.write(to: destination, options: .atomic, originalContentsURL: nil)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }

    func load(from url: URL) throws -> ProjectSnapshot {
        var coordinationError: NSError?
        var result: Result<ProjectSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try readPackage(source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectError.invalid }
        return try result.get()
    }

    private func readPackage(_ url: URL) throws -> ProjectSnapshot {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ProjectError.invalid }
        let metadataURL = url.appendingPathComponent("manifest.json")
        try checkFile(metadataURL, inside: url, maximumBytes: 4 * 1024 * 1024)
        let manifest: ProjectManifest
        let metadata = try Data(contentsOf: metadataURL)
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: metadata) }
        catch { throw ProjectError.invalid }
        guard header.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(header.version) else { throw ProjectError.version(header.version) }
        do { manifest = try JSONDecoder().decode(ProjectManifest.self, from: metadata) }
        catch { throw ProjectError.invalid }
        try validate(manifest)
        let workingVersion = try LensWorksWorkingVersion.read(from: url)
        guard manifest.workingVersionID == workingVersion?.id || manifest.workingVersionID == nil else { throw ProjectError.invalid }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var pixels = 0, maskPixels = 0
        for layer in manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            let file = url.appendingPathComponent("images").appendingPathComponent(filename)
            try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024)
            let asset = try autoreleasepool {
                // Decoded from the file's bytes in memory, not from the file: an image made from a file source stays tied
                // to it, and the next save replaces that file (ImageIO: "mmapped file changed"), so an image kept for undo
                // could later read someone else's pixels.
                let bytes = try Data(contentsOf: file)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw ProjectError.missingImage }
                if isMask { try checkSize(width: width, height: height, used: &maskPixels) }
                else { try checkSize(width: width, height: height, used: &pixels) }
                guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw ProjectError.missingImage }
                if isMask, !LayerMask.isValid(image) { throw ProjectError.invalid }
                return ImportedImage(image: image, thumbnail: thumbnail, name: layer.name)
            }
            if isMask { masks[layer.id] = asset } else { images[layer.id] = asset }
          }
        }
        var snapshot = ProjectSnapshot(manifest: manifest, images: images, masks: masks, workingVersion: workingVersion)
        let historyURL = url.appendingPathComponent("History")
        if manifest.hasHistory == true { snapshot.history = try readHistory(historyURL, current: snapshot) }
        else if FileManager.default.fileExists(atPath: historyURL.path) { throw ProjectError.invalid }
        return snapshot
    }

    private struct HistoryStateRecord: Codable {
        let manifest: ProjectManifest?
        let images: [UUID: String]
        let masks: [UUID: String]
        let revision: UUID
    }
    private struct HistoryEntryRecord: Codable { let name: String; let before: Int; let after: Int }
    private struct HistoryIndex: Codable {
        let version: Int
        let revision: UUID
        let states: [String]
        let past: [HistoryEntryRecord]
        let future: [HistoryEntryRecord]
        let assets: [String]
    }
    private func encodeHistoryImage(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ProjectError.encode }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw ProjectError.encode }
        return data as Data
    }
    /// Current images are referenced, not duplicated. Historical images share one backing per immutable CGImage.
    private func historyWrapper(_ archive: ProjectHistoryArchive, current: ProjectSnapshot) throws -> FileWrapper {
        guard archive.past.count + archive.future.count <= 100 else { throw ProjectError.tooLarge }
        var identities: [ObjectIdentifier: String] = [:]
        for (id, asset) in current.images { identities[ObjectIdentifier(asset.image)] = "current-image:\(id.uuidString)" }
        for (id, asset) in current.masks { identities[ObjectIdentifier(asset.image)] = "current-mask:\(id.uuidString)" }
        var files: [String: FileWrapper] = [:], states: [String] = []
        var stateFiles: [String: FileWrapper] = [:], stateRecords: [HistoryStateRecord] = []
        var retainedBytes = 0
        func reference(_ asset: ImportedImage) throws -> String {
            let identity = ObjectIdentifier(asset.image)
            if let key = identities[identity] { return key }
            let bytes = asset.image.bytesPerRow.multipliedReportingOverflow(by: asset.image.height)
            guard !bytes.overflow, bytes.partialValue <= 256 * 1024 * 1024 - retainedBytes else { throw ProjectError.tooLarge }
            let key = "\(files.count).png", data = try encodeHistoryImage(asset.image)
            guard data.count <= 512 * 1024 * 1024 else { throw ProjectError.tooLarge }
            let thumbnailBytes = asset.thumbnail.bytesPerRow.multipliedReportingOverflow(by: asset.thumbnail.height)
            guard !thumbnailBytes.overflow, thumbnailBytes.partialValue <= 256 * 1024 * 1024 - retainedBytes - bytes.partialValue else { throw ProjectError.tooLarge }
            retainedBytes += bytes.partialValue + thumbnailBytes.partialValue
            files[key] = FileWrapper(regularFileWithContents: data); identities[identity] = key
            return key
        }
        func state(_ value: ProjectHistoryState) throws -> Int {
            guard value.project?.history == nil, value.project?.workingVersion == nil else { throw ProjectError.invalid }
            var images: [UUID: String] = [:], masks: [UUID: String] = [:]
            if let project = value.project {
                try validate(project.manifest)
                guard project.manifest.hasHistory != true, project.manifest.workingVersionID == nil, project.manifest.recoveryDocumentID == nil,
                      Set(project.images.keys) == Set(project.manifest.layers.filter { $0.imageFile != nil }.map(\.id)),
                      Set(project.masks.keys) == Set(project.manifest.layers.filter { $0.maskFile != nil }.map(\.id)) else { throw ProjectError.missingImage }
                guard try JSONEncoder().encode(project.manifest).count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
                for (id, asset) in project.images { images[id] = current.images[id]?.image === asset.image ? "current-image:" + id.uuidString : try reference(asset) }
                for (id, asset) in project.masks { masks[id] = current.masks[id]?.image === asset.image ? "current-mask:" + id.uuidString : try reference(asset) }
            }
            let index = states.count
            let record = HistoryStateRecord(manifest: value.project?.manifest, images: images, masks: masks, revision: value.revision)
            let data = try JSONEncoder().encode(record)
            guard data.count <= 8 * 1024 * 1024 else { throw ProjectError.tooLarge }
            let filename = "\(index).json"
            stateRecords.append(record); states.append(filename)
            stateFiles[filename] = FileWrapper(regularFileWithContents: data)
            return index
        }
        func entries(_ values: [ProjectHistoryEntry]) throws -> [HistoryEntryRecord] {
            try values.map { entry in
                guard !entry.name.isEmpty, entry.name.utf8.count <= 1024 else { throw ProjectError.invalid }
                return .init(name: entry.name, before: try state(entry.before), after: try state(entry.after))
            }
        }
        let past = try entries(archive.past), future = try entries(archive.future)
        let index = HistoryIndex(version: 1, revision: archive.revision, states: states, past: past, future: future, assets: files.keys.sorted())
        try validateHistoryIndex(index, states: stateRecords)
        try validateCurrentHistory(index, states: stateRecords, current: current)
        let data = try JSONEncoder().encode(index)
        guard data.count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
        return FileWrapper(directoryWithFileWrappers: ["index.json": FileWrapper(regularFileWithContents: data), "assets": FileWrapper(directoryWithFileWrappers: files), "states": FileWrapper(directoryWithFileWrappers: stateFiles)])
    }
    private func historyDocumentProjection(_ value: ProjectManifest) throws -> Data {
        let normalized = ProjectManifest(resolution: value.resolution, documentID: value.documentID, width: value.width,
            height: value.height, activeLayerID: nil, layers: value.layers, guides: value.guides)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(normalized)
    }
    private func historyStatesAgree(_ lhs: HistoryStateRecord, _ rhs: HistoryStateRecord) throws -> Bool {
        guard lhs.revision == rhs.revision, lhs.images == rhs.images, lhs.masks == rhs.masks else { return false }
        switch (lhs.manifest, rhs.manifest) {
        case (nil, nil): return true
        case (.some(let a), .some(let b)): return try historyDocumentProjection(a) == historyDocumentProjection(b)
        default: return false
        }
    }
    private func validateHistoryIndex(_ index: HistoryIndex, states: [HistoryStateRecord]) throws {
        guard index.version == 1, index.past.count + index.future.count <= 100,
              index.states.count == (index.past.count + index.future.count) * 2,
              index.states.count == states.count, index.states == (0..<states.count).map { "\($0).json" },
              Set(index.assets).count == index.assets.count,
              Set(index.assets) == Set((0..<index.assets.count).map { "\($0).png" }) else { throw ProjectError.invalid }
        let entries = index.past + index.future
        guard Set(entries.flatMap { [$0.before, $0.after] }) == Set(index.states.indices) else { throw ProjectError.invalid }
        for entry in entries {
            guard !entry.name.isEmpty, entry.name.utf8.count <= 1024,
                  index.states.indices.contains(entry.before), index.states.indices.contains(entry.after),
                  states[entry.before].revision != states[entry.after].revision else { throw ProjectError.invalid }
        }
        for chain in [index.past, index.future.reversed().map { $0 }] {
            for pair in zip(chain, chain.dropFirst()) {
                guard try historyStatesAgree(states[pair.0.after], states[pair.1.before]) else { throw ProjectError.invalid }
            }
        }
        if let past = index.past.last { guard states[past.after].revision == index.revision else { throw ProjectError.invalid } }
        if let future = index.future.last { guard states[future.before].revision == index.revision else { throw ProjectError.invalid } }
        if let past = index.past.last, let future = index.future.last {
            guard try historyStatesAgree(states[past.after], states[future.before]) else { throw ProjectError.invalid }
        }
    }
    private func validateCurrentHistory(_ index: HistoryIndex, states: [HistoryStateRecord], current: ProjectSnapshot) throws {
        guard let position = index.past.last?.after ?? index.future.last?.before else { return }
        guard let manifest = states[position].manifest else { throw ProjectError.invalid }
        guard try historyDocumentProjection(manifest) == historyDocumentProjection(current.manifest),
              states[position].images.allSatisfy({ id, key in key == "current-image:" + id.uuidString }),
              states[position].masks.allSatisfy({ id, key in key == "current-mask:" + id.uuidString }) else { throw ProjectError.invalid }
    }
    private func readHistory(_ url: URL, current: ProjectSnapshot) throws -> ProjectHistoryArchive {
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw ProjectError.invalid }
        let metadata = url.appendingPathComponent("index.json")
        try checkFile(metadata, inside: url, maximumBytes: 4 * 1024 * 1024)
        let index = try JSONDecoder().decode(HistoryIndex.self, from: Data(contentsOf: metadata))
        guard index.states.count <= 200, index.states == (0..<index.states.count).map({ "\($0).json" }) else { throw ProjectError.invalid }
        let stateRecords: [HistoryStateRecord] = try index.states.map { filename in
            let file = url.appendingPathComponent("states").appendingPathComponent(filename)
            try checkFile(file, inside: url, maximumBytes: 8 * 1024 * 1024)
            let record = try JSONDecoder().decode(HistoryStateRecord.self, from: Data(contentsOf: file))
            if let manifest = record.manifest {
                guard try JSONEncoder().encode(manifest).count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
            }
            return record
        }
        try validateHistoryIndex(index, states: stateRecords)
        try validateCurrentHistory(index, states: stateRecords, current: current)
        var assets: [String: ImportedImage] = [:], used = 0
        for (id, asset) in current.images { assets["current-image:\(id.uuidString)"] = asset }
        for (id, asset) in current.masks { assets["current-mask:\(id.uuidString)"] = asset }
        for key in index.assets {
            let file = url.appendingPathComponent("assets").appendingPathComponent(key)
            try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024)
            let bytes = try Data(contentsOf: file)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier, CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                  (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                  (props[kCGImagePropertyDepth] as? Int ?? 8) <= 8,
                  width <= (256 * 1024 * 1024 - used) / 4 / height else { throw ProjectError.tooLarge }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.bytesPerRow <= (256 * 1024 * 1024 - used) / height,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary) else { throw ProjectError.missingImage }
            let thumbnailBytes = thumbnail.bytesPerRow * thumbnail.height
            guard thumbnailBytes <= 256 * 1024 * 1024 - used - image.bytesPerRow * height else { throw ProjectError.tooLarge }
            used += image.bytesPerRow * height + thumbnailBytes
            assets[key] = ImportedImage(image: image, thumbnail: thumbnail, name: "History")
        }
        var referenced = Set<String>()
        let states: [ProjectHistoryState] = try stateRecords.map { record in
            guard let manifest = record.manifest else {
                guard record.images.isEmpty, record.masks.isEmpty else { throw ProjectError.invalid }
                return .init(project: nil, revision: record.revision)
            }
            try validate(manifest)
            guard manifest.hasHistory != true, manifest.workingVersionID == nil, manifest.recoveryDocumentID == nil,
                  Set(record.images.keys) == Set(manifest.layers.filter { $0.imageFile != nil }.map(\.id)),
                  Set(record.masks.keys) == Set(manifest.layers.filter { $0.maskFile != nil }.map(\.id)) else { throw ProjectError.invalid }
            func resolved(_ refs: [UUID: String], mask: Bool) throws -> [UUID: ImportedImage] {
                var result: [UUID: ImportedImage] = [:], pixels = 0
                for (id, key) in refs {
                    guard let asset = assets[key], !mask || LayerMask.isValid(asset.image) else { throw ProjectError.missingImage }
                    try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels)
                    referenced.insert(key); result[id] = asset
                }
                return result
            }
            return .init(project: ProjectSnapshot(manifest: manifest, images: try resolved(record.images, mask: false), masks: try resolved(record.masks, mask: true)), revision: record.revision)
        }
        guard Set(index.assets).isSubset(of: referenced) else { throw ProjectError.invalid }
        func entries(_ rows: [HistoryEntryRecord]) -> [ProjectHistoryEntry] {
            rows.map { .init(name: $0.name, before: states[$0.before], after: states[$0.after]) }
        }
        return .init(past: entries(index.past), future: entries(index.future), revision: index.revision)
    }

    private func validate(_ manifest: ProjectManifest) throws {
        guard manifest.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(manifest.version) else { throw ProjectError.version(manifest.version) }
        guard manifest.hasHistory != true || manifest.version >= 13 else { throw ProjectError.invalid }
        if let recovery = manifest.recoveryDocumentID {
            guard manifest.version >= 13, recovery == manifest.documentID, manifest.workingVersionID == nil else { throw ProjectError.invalid }
        }
        guard manifest.colorSpace == "sRGB", manifest.workingVersionID == nil || manifest.version >= 12 else { throw ProjectError.invalid }
        if let resolution = manifest.resolution {
            guard resolution.isFinite, (1...9600).contains(resolution) else { throw ProjectError.invalid }
        }
        guard (1...DocumentLimits.maxSide).contains(manifest.width), (1...DocumentLimits.maxSide).contains(manifest.height),
              manifest.layers.count <= 10_000 else { throw ProjectError.tooLarge }
        for layer in manifest.layers {
            if let text = layer.text {
                // Per-letter colors arrived in version 10, per-letter faces in version 11.
                guard text.isValid,
                      text.colorRuns == nil || manifest.version >= 10,
                      text.fontRuns == nil || manifest.version >= 11,
                      layer.imageFile != nil, layer.isGroup != true, layer.adjustment == nil else { throw ProjectError.invalid }
            }
            if let adjustment = layer.adjustment {
                guard manifest.version >= 7, layer.isGroup != true, layer.imageFile == nil, adjustment.isValid else { throw ProjectError.invalid }
                if adjustment.kind == .gaussianBlur || adjustment.kind == .motionBlur || adjustment.kind == .addNoise {
                    guard manifest.version >= 9 else { throw ProjectError.invalid }
                }
            }
            // Layer masks arrived in version 4, folder masks in version 6.
            guard layer.maskFile == nil || (manifest.version >= (layer.isGroup == true ? 6 : 4)
                && layer.maskFile == "\(layer.id.uuidString).mask.png"),
                layer.maskEnabled == nil || layer.maskFile != nil,
                layer.maskPlacement.map({ $0.isValid && layer.maskFile != nil }) ?? true else { throw ProjectError.invalid }
            let opacity = layer.opacity ?? 1
            let blend = layer.blendMode ?? .normal
            // Folders took an opacity of their own in version 8, which multiplies into what is inside
            // them; their blend mode is still pass-through, so it stays Normal.
            guard opacity.isFinite, (0...1).contains(opacity),
                  (manifest.version >= 3 || (opacity == 1 && blend == .normal)),
                  (layer.isGroup != true || (blend == .normal && (manifest.version >= 8 || opacity == 1))) else { throw ProjectError.invalid }
        }
        try LayerHierarchy.validate(manifest.layers)
        try LiveMaskGraph.validate(manifest.layers)
        if manifest.version < 5, manifest.layers.contains(where: { $0.maskSourceID != nil }) { throw ProjectError.invalid }
        if manifest.version == 1, manifest.layers.contains(where: { $0.parentID != nil || $0.isGroup == true }) { throw ProjectError.invalid }
        var ids = Set<UUID>()
        for layer in manifest.layers {
            guard ids.insert(layer.id).inserted, layer.transform.isValid,
                  !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  layer.name.utf8.count <= 16_384,
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png" else { throw ProjectError.invalid }
        }
        if let id = manifest.activeLayerID, !ids.contains(id) { throw ProjectError.invalid }
        try validateGuides(manifest)
    }

    private func validateGuides(_ manifest: ProjectManifest) throws {
        let guides = manifest.guides ?? []
        if manifest.version < 8 {
            guard guides.isEmpty else { throw ProjectError.invalid }
            return
        }
        guard guides.count <= 1_000 else { throw ProjectError.tooLarge }
        var ids = Set<UUID>()
        for guide in guides {
            guard ids.insert(guide.id).inserted, guide.position.isFinite, abs(guide.position) <= 1_000_000 else {
                throw ProjectError.invalid
            }
        }
    }

    private func checkSize(width: Int, height: Int, used: inout Int) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), width * height <= DocumentLimits.documentPixelBudget - used else {
            throw ProjectError.tooLarge
        }
        used += width * height
    }

    private func checkFile(_ file: URL, inside package: URL, maximumBytes: Int) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw ProjectError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw ProjectError.tooLarge }
    }
}
