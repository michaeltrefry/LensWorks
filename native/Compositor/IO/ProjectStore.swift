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
    /// The newest format version. A save writes the lowest version that can express the document: `baseline`
    /// unless it uses version-13 content (live RAW sources or float working samples), `floatContent` unless it
    /// uses version-15 content (a baked coverage on a live source layer). So a project without those features
    /// stays readable by a build that only understands the version it needs.
    static let current = 15
    /// Version 14 is the retained filter-plugin step and Invert on live RAW sources (sc-25324). This build never
    /// writes it: a baked coverage is written as 15, other float or live RAW content as 13. A version-14 package
    /// opens when what it holds is content this build knows.
    static let retainedPluginSteps = 14
    static let floatContent = 13
    static let baseline = 12
    /// Every version `load` accepts. The package-header check, the manifest check and the error
    /// message all read this, so they cannot drift apart when `current` is bumped.
    static let supported = 1...ProjectManifest.current

    var format = "com.compositor.project"
    var version = ProjectManifest.current
    var colorSpace = "sRGB"
    /// Version 13 working samples; colorSpace remains the chosen integer output profile.
    var workingSpace:String? = nil
    var workingSample:String? = nil
    var resolution: Double? = nil // Older version-1 projects default to 72 pixels/inch.
    let documentID: UUID
    var width: Int
    var height: Int
    let activeLayerID: UUID?
    var layers: [ProjectLayerRecord]
    /// Version 12: requires the matching LensWorks.json identity in the atomic package.
    var workingVersionID: UUID? = nil
    /// Alignment guides. Missing on versions 1–7.
    var guides: [CanvasGuide]? = nil
    var metadataStorage:LWSourceMetadataStorage? = nil
    enum CodingKeys:String,CodingKey {
        case format,version,colorSpace,workingSpace,workingSample,resolution,documentID,width,height,activeLayerID,layers,
            workingVersionID,guides
    }
}

nonisolated struct ProjectLayerRecord: Codable, Sendable {
    let id: UUID
    let name: String
    var isVisible: Bool
    var transform: LayerTransform
    var imageFile: String?
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
    /// Version 13: live original authority and complete document development.
    var liveSource: LWLiveSourceNode? = nil
    /// Content-addressed source archive; hydrated away before entering the editor.
    var liveSourceFile: String? = nil
    var planeArchiveReference: LWFloatPlaneArchive.Reference? = nil
    var maskPlaneArchiveReference: LWFloatPlaneArchive.Reference? = nil
    /// Version 15: coverage baked into a live source layer ("<id>.coverage.plane"), over the layer's own pixel
    /// grid. It multiplies the layer's alpha wherever the layer is composited, beside the layer's own mask (which
    /// may be switched off), and survives every development of the layer from its original.
    var coverageFile: String? = nil
    var coveragePlaneArchiveReference: LWFloatPlaneArchive.Reference? = nil
}

/// The pixel files a layer record can name, and the image each is in a snapshot.
nonisolated enum ProjectLayerSlot: CaseIterable, Sendable {
    case image, mask, coverage
    /// A mask and a baked coverage are both one-channel coverage images.
    var isCoverage: Bool { self != .image }
}
nonisolated extension ProjectLayerRecord {
    func file(_ slot: ProjectLayerSlot) -> String? {
        switch slot { case .image: imageFile; case .mask: maskFile; case .coverage: coverageFile }
    }
    func planeReference(_ slot: ProjectLayerSlot) -> LWFloatPlaneArchive.Reference? {
        switch slot { case .image: planeArchiveReference; case .mask: maskPlaneArchiveReference; case .coverage: coveragePlaneArchiveReference }
    }
    /// The name a float plane has in the package's `images` folder.
    func planeFile(_ slot: ProjectLayerSlot) -> String {
        switch slot { case .image: "\(id.uuidString).plane"; case .mask: "\(id.uuidString).mask.plane"; case .coverage: "\(id.uuidString).coverage.plane" }
    }
}
nonisolated extension ProjectSnapshot {
    func asset(_ slot: ProjectLayerSlot, for layer: UUID) -> ImportedImage? {
        switch slot { case .image: images[layer]; case .mask: masks[layer]; case .coverage: coverages[layer] }
    }
    /// The coverage baked into a layer, when its record names one.
    func bakedCoverage(for layer: ProjectLayerRecord) -> ImportedImage? { layer.coverageFile == nil ? nil : coverages[layer.id] }
}

nonisolated struct ProjectSnapshot: @unchecked Sendable {
    var manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
    /// Baked coverage, by layer (see `ProjectLayerRecord.coverageFile`).
    var coverages: [UUID: ImportedImage] = [:]
    var workingVersion: LensWorksWorkingVersion? = nil
    /// The undo history and checkpoints the package holds (see LWHistoryArchive); nil when it holds none.
    var history: LWHistoryArchive.Index? = nil
    /// Set when the package holds a History folder written by a newer build: this build cannot read it and must
    /// not throw it away without asking (the next save would otherwise replace the package without it).
    var newerHistorySchema: Int? = nil
}

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
    /// Any field that only version 15 can express.
    static func usesVersion15(_ manifest: ProjectManifest) -> Bool {
        manifest.layers.contains { $0.coverageFile != nil || $0.coveragePlaneArchiveReference != nil }
    }
    /// How old a staged package beside a project has to be before a save may take it for one a killed save left
    /// behind. A save that is still writing touches its staged package far more recently than this.
    static let abandonedStageAge: TimeInterval = 60 * 60
    /// Removes the staged packages (".LensWorks-<uuid>.comp") that saves which never finished left in `folder`.
    /// Each can hold a full copy of a document and its history, and nothing else would ever collect them.
    nonisolated static func removeAbandonedStages(in folder: URL, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".LensWorks-"), name.hasSuffix(".comp"), UUID(uuidString: String(name.dropFirst(11).dropLast(5))) != nil,
                  let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]), values.isDirectory == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > abandonedStageAge else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
    /// Any field or file kind that only version 13 can express.
    static func usesVersion13(_ manifest: ProjectManifest) -> Bool {
        manifest.workingSpace != nil || manifest.workingSample != nil || manifest.layers.contains { layer in
            layer.liveSource != nil || layer.liveSourceFile != nil || layer.planeArchiveReference != nil
                || layer.maskPlaneArchiveReference != nil
                || [".f32", ".plane"].contains { layer.imageFile?.hasSuffix($0) == true }
                || layer.maskFile?.hasSuffix(".mask.plane") == true
        }
    }
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    /// The manifest as a save writes it: float working samples declared, and the lowest format version that can
    /// express what the document uses.
    nonisolated func normalized(_ value: ProjectManifest, snapshot: ProjectSnapshot, version: LensWorksWorkingVersion?) throws -> ProjectManifest {
        var manifest = value
        manifest.workingVersionID = version?.id
        if version != nil { manifest.version = ProjectManifest.current }
        let floatContent=manifest.layers.contains(where:{$0.liveSource != nil})
            || snapshot.images.values.contains(where:{$0.linear != nil || $0.linearPlane != nil})
        if floatContent {
            manifest.workingSpace="extended-linear-sRGB";manifest.workingSample="float32-straight-RGBA"
        }
        manifest.version = Self.usesVersion15(manifest) ? ProjectManifest.current
            : Self.usesVersion13(manifest) ? ProjectManifest.floatContent : min(manifest.version, ProjectManifest.baseline)
        try validate(manifest)
        return manifest
    }

    /// With `history`, the package also takes the document's undo history and checkpoints, in the same atomic
    /// publication; the result says what was kept, and what had to go to stay within the storage limit.
    @discardableResult
    func save(_ snapshot: ProjectSnapshot, to url: URL, quickLook: QuickLookImages? = nil, workingVersion: LensWorksWorkingVersion? = nil,
              history: LWHistoryArchive.Capture? = nil) throws -> LWHistoryArchive.Commit? {
        try validate(snapshot.manifest)
        let sourceProtection = try LWSourceDestinationAuthority(snapshot)
        try sourceProtection.validate(url)
        let version = workingVersion ?? snapshot.workingVersion
        guard snapshot.manifest.workingVersionID == nil || snapshot.manifest.workingVersionID == version?.id else { throw ProjectError.invalid }
        try version?.validateDestination(url)
        var manifest = try normalized(snapshot.manifest, snapshot: snapshot, version: version)
        var images: [String: FileWrapper] = [:]
        var planeAssets: [String: LWFloatPlane] = [:]
        var planeReferences: [String: LWFloatPlaneArchive.Reference] = [:]
        var pixels = 0, maskPixels = 0, coveragePixels = 0
        for layer in snapshot.manifest.layers {
          for slot in ProjectLayerSlot.allCases {
            let isMask = slot.isCoverage
            guard let filename = layer.file(slot) else { continue }
            guard let asset = snapshot.asset(slot, for: layer.id) else { throw ProjectError.missingImage }
            if isMask {
                guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
                if slot == .mask { try checkSize(width: asset.image.width, height: asset.image.height, used: &maskPixels) }
                else { try checkSize(width: asset.image.width, height: asset.image.height, used: &coveragePixels) }
            } else { try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels) }
            if let plane = asset.linearPlane {
                let reference = layer.planeReference(slot)
                guard filename == layer.planeFile(slot),
                    reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }
                try asset.validatePlaneRead()
                let placeholder = FileWrapper(directoryWithFileWrappers: [:])
                placeholder.fileAttributes = [FileAttributeKey.type.rawValue: FileAttributeType.typeDirectory.rawValue, FileAttributeKey.posixPermissions.rawValue: 0o700]
                images[filename] = placeholder; planeAssets["images/" + filename] = plane
                planeReferences["images/" + filename] = reference
                continue
            }
            // A baked coverage is always a float plane.
            guard slot != .coverage else { throw ProjectError.invalid }
            let data = try autoreleasepool {
                if let linear = asset.linear, !isMask {
                    guard filename.hasSuffix(".f32") else { throw ProjectError.invalid }
                    return try linear.packageData(maximumFileBytes:512 * 1024 * 1024)
                }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw ProjectError.encode
                }
                CGImageDestinationAddImage(destination, asset.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
                try asset.validatePlaneRead();try Task.checkCancellation()
                return data as Data
            }
            images[filename] = FileWrapper(regularFileWithContents: data)
          }
        }
        let sourceProjection=try LWSourcePackageArchive.externalize(manifest,maximumBytes:LWSourceDeveloper.maximumResultBytes)
        var publicationOwners=sourceProjection.ownership
        defer { withExtendedLifetime(publicationOwners) {} }
        manifest=sourceProjection.manifest
        try validate(manifest)
        let encodedManifest=try LWSourceMetadataStorage.encode(manifest,maximumBytes:4*1024*1024,formatting:[.prettyPrinted,.sortedKeys])
        publicationOwners.append(encodedManifest.owner)
        let metadata=try encodedManifest.copyData(ownedBy:encodedManifest.owner)
        var contents = [
            "manifest.json": FileWrapper(regularFileWithContents: metadata),
            "images": FileWrapper(directoryWithFileWrappers: images)
        ]
        if var version {
            version.projectPath = url.path
            contents["LensWorks.json"] = FileWrapper(regularFileWithContents: try version.encoded())
        }
        if !sourceProjection.assets.isEmpty || !sourceProjection.planes.isEmpty {
            var sources = sourceProjection.assets.mapValues { FileWrapper(regularFileWithContents: $0) }
            for (name, asset) in sourceProjection.planes {
                guard let plane = asset.plane else { throw ProjectError.missingImage }
                let placeholder = FileWrapper(directoryWithFileWrappers: [:]); placeholder.fileAttributes = [FileAttributeKey.type.rawValue: FileAttributeType.typeDirectory.rawValue, FileAttributeKey.posixPermissions.rawValue: 0o700]
                sources[name] = placeholder; planeAssets["Sources/" + name] = plane; planeReferences["Sources/" + name] = asset.reference
            }
            contents["Sources"] = FileWrapper(directoryWithFileWrappers: sources)
        }
        // Quick Look's Space-bar preview reads this by name; loading ignores it.
        if let quickLook {
            contents["QuickLook"] = FileWrapper(directoryWithFileWrappers: [
                "Preview.jpg": FileWrapper(regularFileWithContents: quickLook.preview),
            ])
        }
        let package = FileWrapper(directoryWithFileWrappers: contents)
        var coordinationError: NSError?
        var writeError: Error?
        var commit: LWHistoryArchive.Commit?
        // What history need not copy, because this package holds it as the document itself.
        let current = history.map { LWHistoryArchive.currentDocument(snapshot, manifest: manifest, sources: Set(sourceProjection.assets.keys),
            planes: Set(sourceProjection.planes.values.map(\.reference.manifestSHA256)), assets: $0.assets) }
        let manifestDigest = LWHistoryArchive.digest(metadata)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do {
                try sourceProtection.validate(destination)
                // Foundation stages a sibling package and atomically replaces the
                // destination only once the complete package has been written.
                if planeAssets.isEmpty, history?.record.isEmpty != false {
                    try package.write(to: destination, options: .atomic, originalContentsURL: nil)
                    commit = history.map { LWHistoryArchive.Commit(limitBytes: $0.limitBytes, rasters: current?.rasters ?? [:]) }
                } else {
                    let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                    let staged = parent.appendingPathComponent(".LensWorks-" + UUID().uuidString + ".comp", isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: staged.path) else { throw ProjectError.invalid }
                    defer { if FileManager.default.fileExists(atPath: staged.path) { try? FileManager.default.removeItem(at: staged) } }
                    package.fileAttributes = [FileAttributeKey.type.rawValue: FileAttributeType.typeDirectory.rawValue, FileAttributeKey.posixPermissions.rawValue: 0o700]
                    try package.write(to: staged, options: .atomic, originalContentsURL: nil)
                    for filename in planeAssets.keys.sorted() {
                        let plane = planeAssets[filename]!
                        let reference = try LWFloatPlaneArchive.write(plane,
                            to: staged.appendingPathComponent(filename, isDirectory: true))
                        guard planeReferences[filename] == reference else { throw ProjectError.invalid }
                    }
                    if let history, let current {
                        commit = try LWHistoryArchive.write(history, current: current, manifestSHA256: manifestDigest, into: staged)
                        try history.fault?(.publish)
                    }
                    // Same-directory safe-save publishes only after every complete
                    // tile and its whole content hash have been staged successfully.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                    } else { try FileManager.default.moveItem(at: staged, to: destination) }
                }
                // This save is published. Staged packages that saves which never finished left beside it go now.
                Self.removeAbandonedStages(in: destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
        return commit
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
        var manifest: ProjectManifest
        let metadataFile=try LWSourceOwnedData.read(metadataURL,maximumBytes:4*1024*1024)
        let decodedHeader:(value:Header,owner:LWSourceMetadataStorage)
        let header: Header
        do { decodedHeader = try metadataFile.decode(Header.self);header = decodedHeader.value }
        catch { throw ProjectError.invalid }
        defer { withExtendedLifetime(decodedHeader.owner) {} }
        guard header.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(header.version) else { throw ProjectError.version(header.version) }
        do {
            let decoded=try metadataFile.decode(ProjectManifest.self)
            manifest=decoded.value;manifest.metadataStorage=decoded.owner
        }
        catch { throw ProjectError.invalid }
        try validate(manifest)
        let sourceCache=LWSourcePackageArchive.HydrationCache()
        var currentSources:[String:LWSourceOwnedData]=[:],currentSourcePlanes:[String:LWFloatPlane]=[:],sourceBytes=0
        manifest=try LWSourcePackageArchive.hydrate(manifest,readOwned: { name,maximum in
            if let entry=currentSources[name] { guard entry.count <= maximum else { throw ProjectError.tooLarge };return entry }
            let file=url.appendingPathComponent("Sources").appendingPathComponent(name)
            try checkFile(file,inside:url,maximumBytes:min(maximum,LWSourceDeveloper.maximumResultBytes-sourceBytes))
            let entry=try LWSourceOwnedData.read(file,maximumBytes:min(maximum,LWSourceDeveloper.maximumResultBytes-sourceBytes))
            sourceBytes += entry.count;currentSources[name]=entry;return entry
        }, readPlane: { name, reference in
            if let plane = currentSourcePlanes[name] {
                guard reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }; return plane
            }
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let plane = try LWFloatPlaneArchive.read(from: url.appendingPathComponent("Sources").appendingPathComponent(name, isDirectory: true),
                reference: reference, workspace: workspace)
            currentSourcePlanes[name] = plane; return plane
        },cache:sourceCache)
        try validate(manifest)
        let workingVersion = try LensWorksWorkingVersion.read(from: url)
        guard manifest.workingVersionID == workingVersion?.id || manifest.workingVersionID == nil else { throw ProjectError.invalid }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var coverages: [UUID: ImportedImage] = [:]
        var pixels = 0, maskPixels = 0, coveragePixels = 0
        for layer in manifest.layers {
          for slot in ProjectLayerSlot.allCases {
            let isMask = slot == .mask
            guard let filename = layer.file(slot) else { continue }
            let file = url.appendingPathComponent("images").appendingPathComponent(filename)
            if filename.hasSuffix(".plane") {
                guard manifest.version >= 13, let reference = layer.planeReference(slot) else { throw ProjectError.invalid }
                let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
                let plane = try LWFloatPlaneArchive.read(from: file, reference: reference, workspace: workspace)
                switch slot {
                case .mask: try checkSize(width:plane.width,height:plane.height,used:&maskPixels);masks[layer.id]=try ImportedImage(maskPlane:plane,name:"Layer Mask")
                case .coverage: try checkSize(width:plane.width,height:plane.height,used:&coveragePixels);coverages[layer.id]=try ImportedImage(maskPlane:plane,name:"Baked Coverage")
                case .image: try checkSize(width:plane.width,height:plane.height,used:&pixels);images[layer.id]=try ImportedImage(plane:plane,name:layer.name)
                }
                continue
            }
            guard slot != .coverage else { throw ProjectError.invalid }
            try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024)
            if filename.hasSuffix(".f32"), !isMask {
                guard manifest.version >= 13 else { throw ProjectError.invalid }
                let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
                let plane=try LWFloatLegacyArchive.read(from:file,maximumFileBytes:512*1024*1024,workspace:workspace)
                try checkSize(width:plane.width,height:plane.height,used:&pixels)
                images[layer.id]=try ImportedImage(plane:plane,name:layer.name);continue
            }
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
        var snapshot = ProjectSnapshot(manifest: manifest, images: images, masks: masks, coverages: coverages, workingVersion: workingVersion)
        switch LWHistoryArchive.stored(in: url, manifestSHA256: metadataFile.sha256) {
        case .usable(let index): snapshot.history = index
        case .newer(let schema): snapshot.newerHistorySchema = schema
        case .none: break
        }
        return try migrateCompactFloatBackings(snapshot)
    }
    private func migrateCompactFloatBackings(_ snapshot:ProjectSnapshot)throws->ProjectSnapshot {
        guard snapshot.manifest.layers.contains(where:{$0.imageFile?.hasSuffix(".f32")==true}) else {return snapshot}
        let topology=try LWSourceMetadataStorage.product(snapshot.manifest.layers.count,1024)
        var manifest=try snapshot.manifest.metadataCopy(additionalBytes:topology)
        for i in manifest.layers.indices {
            let layer=manifest.layers[i]
            guard layer.imageFile?.hasSuffix(".f32")==true,let asset=snapshot.images[layer.id],
                let plane=asset.linearPlane else {continue}
            manifest.layers[i].imageFile="\(layer.id.uuidString).plane"
            manifest.layers[i].planeArchiveReference=try LWFloatPlaneArchive.reference(plane)
        }
        try validate(manifest)
        var migrated=snapshot;migrated.manifest=manifest;return migrated
    }

    nonisolated func validate(_ manifest: ProjectManifest) throws {
        guard manifest.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(manifest.version) else { throw ProjectError.version(manifest.version) }
        guard manifest.colorSpace == "sRGB",manifest.workingVersionID == nil || manifest.version >= 12 else { throw ProjectError.invalid }
        guard (manifest.workingSpace == nil && manifest.workingSample == nil)
            || (manifest.version >= 13 && manifest.workingSpace == "extended-linear-sRGB" && manifest.workingSample == "float32-straight-RGBA") else { throw ProjectError.invalid }
        if let resolution = manifest.resolution {
            guard resolution.isFinite, (1...9600).contains(resolution) else { throw ProjectError.invalid }
        }
        guard (1...DocumentLimits.maxSide).contains(manifest.width), (1...DocumentLimits.maxSide).contains(manifest.height),
              manifest.layers.count <= 10_000 else { throw ProjectError.tooLarge }
        for layer in manifest.layers {
            if let file=layer.liveSourceFile {
                guard manifest.version >= 13,layer.liveSource == nil,LWSourcePackageArchive.validMetadataName(file),
                      layer.isGroup != true,layer.adjustment == nil,
                      layer.imageFile == "\(layer.id.uuidString).f32" || layer.imageFile == "\(layer.id.uuidString).plane" else { throw ProjectError.invalid }
            }
            if let source = layer.liveSource {
                guard manifest.version >= 13, layer.isGroup != true, layer.adjustment == nil,
                    layer.imageFile == "\(layer.id.uuidString).f32" || layer.imageFile == "\(layer.id.uuidString).plane" else { throw ProjectError.invalid }
                try source.validate()
            }
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
                && (layer.maskFile == "\(layer.id.uuidString).mask.png" || (manifest.version >= 13 && layer.maskFile == "\(layer.id.uuidString).mask.plane"))),
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
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png" || (manifest.version >= 13 && (layer.imageFile == "\(layer.id.uuidString).f32" || layer.imageFile == "\(layer.id.uuidString).plane")) else { throw ProjectError.invalid }
            if layer.maskFile?.hasSuffix(".plane") == true {
                guard manifest.version >= 13,let reference=layer.maskPlaneArchiveReference else { throw ProjectError.invalid }
                try reference.validate()
            } else { guard layer.maskPlaneArchiveReference == nil else { throw ProjectError.invalid } }
            if layer.imageFile == "\(layer.id.uuidString).plane" {
                guard manifest.version >= 13, let reference = layer.planeArchiveReference else { throw ProjectError.invalid }
                try reference.validate()
            } else { guard layer.planeArchiveReference == nil else { throw ProjectError.invalid } }
            // A baked coverage belongs to a live source layer: its pixels are developed afresh from the original,
            // so coverage cannot be kept in them. Any other layer takes a bake into its own pixels.
            if let file = layer.coverageFile {
                guard manifest.version >= 15, file == layer.planeFile(.coverage), layer.liveSource != nil || layer.liveSourceFile != nil,
                      let reference = layer.coveragePlaneArchiveReference else { throw ProjectError.invalid }
                try reference.validate()
            } else { guard layer.coveragePlaneArchiveReference == nil else { throw ProjectError.invalid } }
        }
        if let id = manifest.activeLayerID, !ids.contains(id) { throw ProjectError.invalid }
        try validateGuides(manifest)
    }

    nonisolated private func validateGuides(_ manifest: ProjectManifest) throws {
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
