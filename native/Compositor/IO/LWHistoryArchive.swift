import Foundation
import Compression
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// The pixels a session knows by the name the History store gives them, so a state read back from disk shares the
/// images the document (and every other state) already holds, and a save never hashes an image twice.
///
/// A layer's 8-bit image gets an identifier the first time a save meets it; a float plane is known by the digest
/// of its tile list, which it already carries. What the package's own `images` and `Sources` folders hold (the
/// durable set) is kept alive here until the next save, because a stored state may still need it after the
/// document has moved on.
nonisolated final class LWHistoryAssets: @unchecked Sendable {
    private let lock = NSLock()
    private var rasterIDs: [ObjectIdentifier: UUID] = [:]
    private var rasters: [UUID: ImportedImage] = [:]
    private var planeImages: [String: ImportedImage] = [:]
    private var sourcePlanes: [String: LWFloatPlane] = [:]
    private var durableRasters: Set<UUID> = []
    private var durablePlanes: Set<String> = []

    /// The identifier a save writes this image under, assigned on first sight.
    func rasterID(for asset: ImportedImage) -> UUID {
        lock.withLock {
            let identity = ObjectIdentifier(asset.image)
            if let id = rasterIDs[identity] { return id }
            let id = UUID(); rasterIDs[identity] = id; rasters[id] = asset; return id
        }
    }
    func register(raster id: UUID, _ asset: ImportedImage) {
        lock.withLock { rasterIDs[ObjectIdentifier(asset.image)] = id; rasters[id] = asset }
    }
    func raster(_ id: UUID) -> ImportedImage? { lock.withLock { rasters[id] } }
    private static func planeKey(_ sha: String, mask: Bool) -> String { mask ? sha + "#mask" : sha }
    func register(planeImage asset: ImportedImage, mask: Bool) {
        guard let sha = asset.planeArchiveReference?.manifestSHA256 else { return }
        lock.withLock { planeImages[Self.planeKey(sha, mask: mask)] = asset }
    }
    /// A plane image under the digest a state names it by. A layer developed again from its source can come out
    /// with a different tile list than the one recorded; the state still asks for it by the recorded digest.
    func register(planeImage asset: ImportedImage, sha: String, mask: Bool) {
        lock.withLock { planeImages[Self.planeKey(sha, mask: mask)] = asset }
    }
    func planeImage(_ sha: String, mask: Bool) -> ImportedImage? { lock.withLock { planeImages[Self.planeKey(sha, mask: mask)] } }
    func register(sourcePlane plane: LWFloatPlane, sha: String) { lock.withLock { sourcePlanes[sha] = plane } }
    /// Any plane known under this tile-list digest, whichever kind of layer holds it.
    func plane(_ sha: String) -> LWFloatPlane? {
        lock.withLock { sourcePlanes[sha] ?? planeImages[sha]?.linearPlane ?? planeImages[Self.planeKey(sha, mask: true)]?.linearPlane }
    }

    /// The package on disk now holds exactly this document: its images under `rasters` (identifier to file), and
    /// its planes. They stay alive here until the next save says otherwise.
    func setDurable(_ snapshot: ProjectSnapshot, rasters named: [UUID: String]) {
        let files = Dictionary(named.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        lock.withLock {
            durableRasters = []; durablePlanes = []
            for layer in snapshot.manifest.layers {
                for slot in ProjectLayerSlot.allCases {
                    let isMask = slot.isCoverage
                    guard let file = layer.file(slot), let asset = snapshot.asset(slot, for: layer.id) else { continue }
                    if let sha = asset.planeArchiveReference?.manifestSHA256, asset.linearPlane != nil {
                        planeImages[Self.planeKey(sha, mask: isMask)] = asset; durablePlanes.insert(sha)
                    } else if let id = files["images/" + file] {
                        rasterIDs[ObjectIdentifier(asset.image)] = id; rasters[id] = asset; durableRasters.insert(id)
                    }
                }
                for backing in layer.liveSource.map({ Array($0.planeAssets.values) }) ?? [] {
                    guard let plane = backing.plane else { continue }
                    sourcePlanes[backing.reference.manifestSHA256] = plane; durablePlanes.insert(backing.reference.manifestSHA256)
                }
            }
        }
    }
    /// Lets go of everything no document in memory uses and the package does not hold.
    func prune(keeping images: Set<ObjectIdentifier>, planes: Set<String>) {
        lock.withLock {
            for (id, asset) in rasters where !durableRasters.contains(id) && !images.contains(ObjectIdentifier(asset.image)) {
                rasters[id] = nil; rasterIDs[ObjectIdentifier(asset.image)] = nil
            }
            for (key, asset) in planeImages {
                let sha = String(key.prefix(64))
                if !durablePlanes.contains(sha), !images.contains(ObjectIdentifier(asset.image)) { planeImages[key] = nil }
            }
            for sha in Array(sourcePlanes.keys) where !durablePlanes.contains(sha) && !planes.contains(sha) { sourcePlanes[sha] = nil }
        }
    }
    func reset() {
        lock.withLock { rasterIDs = [:]; rasters = [:]; planeImages = [:]; sourcePlanes = [:]; durableRasters = []; durablePlanes = [] }
    }
    var retainedCount: Int { lock.withLock { rasters.count + planeImages.count + sourcePlanes.count } }
}

/// Undo history and checkpoints inside a project package, published with the document by the same atomic save.
///
///     History/index.json                  entries, checkpoints, the cursor, and which images are the document's own
///     History/states/<revision>/          one state: state.json, and manifest.json (a project manifest)
///     History/rasters/<id>.json           an 8-bit image as a list of 256-pixel tiles (or one encoded blob)
///     History/planes/<digest>.json        a float plane's tile list
///     History/blobs/<aa>/<sha256>         tile and source bytes, named by content, LZFSE-compressed
///
/// A state names its pixels; the bytes live once in `blobs` however many states share them, so a step costs the
/// tiles it changed. Pixels the document itself holds (its `images` and `Sources` folders) are not copied here at
/// all: a state that still shows a layer as the document does costs only its manifest.
nonisolated enum LWHistoryArchive {
    static let schema = 1
    static let folder = "History"
    static let tileSide = 256
    static let maximumIndexBytes = 16 * 1024 * 1024
    static let maximumBlobBytes = 512 * 1024 * 1024

    /// Where a write can be interrupted; tests fail it at each to prove the package stays openable. `ingest` is
    /// reached before an image in memory is cut into tiles, `blob` before a tile is compressed and written: an
    /// image or a tile the old package already holds reaches neither.
    enum Stage: String, Sendable, CaseIterable { case ingest, blob, state, prune, index, publish }
    /// What a package's History folder is to this build.
    enum Stored: Sendable {
        /// No History folder, or one that is damaged or was written for another manifest: nothing to keep.
        case none
        case usable(Index)
        /// Written by a newer build. This build cannot read it, and must not discard it without asking.
        case newer(schema: Int)
    }

    struct Index: Codable, Sendable {
        var schema = LWHistoryArchive.schema
        /// The SHA-256 of the package's manifest.json: history written for another document is not this one's.
        var manifestSHA256: String
        var record: DocumentHistory.Record
        /// The images the package's own `images` folder holds, by the identifier states know them under.
        var document: [String: String]
        /// What the History folder's pixels and states take on disk, and how much of that only checkpoints and the
        /// current state need.
        var bytes: Int64
        var protectedBytes: Int64
    }
    struct Needs: Codable, Sendable {
        var rasters: [UUID] = []
        var planes: [String] = []
        var sources: [String] = []
    }
    struct StateRecord: Codable, Sendable {
        var schema = LWHistoryArchive.schema
        let revision: UUID
        /// False for the state before the first canvas existed.
        let hasDocument: Bool
        var selection: SelectionRecord? = nil
        /// Image file name (as the manifest names it) to the raster it is.
        var rasters: [String: UUID] = [:]
        var needs = Needs()
    }
    struct SelectionRecord: Codable, Sendable {
        struct Element: Codable, Sendable { let kind: Int32; let points: [Double] }
        let antialiased: Bool
        let feather: Double
        let elements: [Element]
        init(_ selection: DocumentSelection) {
            antialiased = selection.antialiased; feather = Double(selection.feather)
            var elements: [Element] = []
            selection.path.applyWithBlock { pointer in
                let element = pointer.pointee
                let count: Int
                switch element.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint: count = 2
                case .addCurveToPoint: count = 3
                default: count = 0
                }
                var points: [Double] = []
                for index in 0..<count { points.append(Double(element.points[index].x)); points.append(Double(element.points[index].y)) }
                elements.append(Element(kind: element.type.rawValue, points: points))
            }
            self.elements = elements
        }
        func selection() throws -> DocumentSelection {
            let path = CGMutablePath()
            for element in elements {
                func point(_ index: Int) throws -> CGPoint {
                    guard element.points.count >= index * 2 + 2, element.points[index * 2].isFinite, element.points[index * 2 + 1].isFinite else { throw ProjectError.invalid }
                    return CGPoint(x: element.points[index * 2], y: element.points[index * 2 + 1])
                }
                switch CGPathElementType(rawValue: element.kind) {
                case .moveToPoint: path.move(to: try point(0))
                case .addLineToPoint: path.addLine(to: try point(0))
                case .addQuadCurveToPoint: path.addQuadCurve(to: try point(1), control: try point(0))
                case .addCurveToPoint: path.addCurve(to: try point(2), control1: try point(0), control2: try point(1))
                case .closeSubpath: path.closeSubpath()
                default: throw ProjectError.invalid
                }
            }
            guard feather.isFinite, feather >= 0 else { throw ProjectError.invalid }
            return DocumentSelection(path: path.copy() ?? path, antialiased: antialiased, feather: CGFloat(feather))
        }
    }
    struct RasterRecord: Codable, Sendable {
        var schema = LWHistoryArchive.schema
        let width: Int
        let height: Int
        /// "tiles": raw rows cut into `tileSide` squares, row-major. "png" and "f32": the whole image as one blob.
        let encoding: String
        var bitsPerComponent = 8
        var bitsPerPixel = 32
        var bitmapInfo: UInt32 = 0
        var colorSpace: String? = nil
        var tileSide = LWHistoryArchive.tileSide
        var blobs: [String]
    }

    /// One state as it is in memory.
    struct LiveState: @unchecked Sendable {
        let snapshot: ProjectSnapshot?
        /// The canvas selection: part of the state for undo, though the document's own manifest does not keep it.
        let selection: DocumentSelection?
    }
    /// Everything a save needs to write history, taken on the main thread at the moment the document was captured.
    struct Capture: @unchecked Sendable {
        var record: DocumentHistory.Record
        /// The states in memory.
        var live: [UUID: LiveState]
        /// The states `source`'s History folder holds.
        var stored: Set<UUID>
        var source: URL?
        let assets: LWHistoryAssets
        /// The most the History folder may take; the oldest unprotected steps go first. Zero is no limit.
        var limitBytes: Int64
        /// Throws to stand in for the process dying at that point.
        var fault: (@Sendable (Stage) throws -> Void)? = nil
    }
    /// What a finished save tells the session.
    struct Commit: Sendable {
        var stored: Set<UUID> = []
        /// Entries dropped to stay within the limit.
        var pruned: Set<UUID> = []
        var prunedNames: [String] = []
        /// Entries and checkpoints whose saved state could no longer be found anywhere.
        var lost: [String] = []
        var bytes: Int64 = 0
        var protectedBytes: Int64 = 0
        var limitBytes: Int64 = 0
        var rasters: [UUID: String] = [:]
        /// Checkpoints and the current state alone take more than the limit. Nothing protected was removed.
        var protectedExceedsLimit: Bool { limitBytes > 0 && protectedBytes > limitBytes }
    }
    enum Failure: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self { case .missing(let what): "The saved history is missing \(what)." }
        }
    }

    // MARK: Names

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func blobPath(_ sha: String) -> String { "blobs/" + sha.prefix(2) + "/" + sha }
    private static func rasterPath(_ id: UUID) -> String { "rasters/" + id.uuidString + ".json" }
    private static func planePath(_ sha: String) -> String { "planes/" + sha + ".json" }
    private static func statePath(_ revision: UUID) -> String { "states/" + revision.uuidString }
    static func root(of package: URL) -> URL { package.appendingPathComponent(folder, isDirectory: true) }
    /// The digest a source file is named by ("<sha256>.json", "<sha256>.data").
    private static func sourceDigest(_ name: String) throws -> String {
        let sha = String(name.prefix(64))
        guard isDigest(sha), name == sha + ".json" || name == sha + ".data" else { throw ProjectError.invalid }
        return sha
    }

    // MARK: Blobs

    private static func size(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { return nil }
        return Int64(size)
    }
    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    /// One byte says how the rest is stored: 1 is LZFSE, 0 is as it is (when compressing would not shrink it).
    private static func pack(_ data: Data) -> Data {
        if let packed = try? (data as NSData).compressed(using: .lzfse) as Data, packed.count < data.count { return Data([1]) + packed }
        return Data([0]) + data
    }
    private static func readBlob(_ sha: String, root: URL, maximumBytes: Int) throws -> Data {
        guard isDigest(sha) else { throw ProjectError.invalid }
        let url = root.appendingPathComponent(blobPath(sha))
        guard let stored = size(url) else { throw Failure.missing("some of its pixels") }
        guard stored >= 1, stored <= Int64(maximumBytes) + 1 else { throw ProjectError.tooLarge }
        let file = try Data(contentsOf: url)
        guard let kind = file.first else { throw ProjectError.invalid }
        let body = Data(file.dropFirst())
        let data: Data
        switch kind {
        case 0: data = body
        case 1: data = try inflate(body, maximumBytes: maximumBytes)
        default: throw ProjectError.invalid
        }
        guard data.count <= maximumBytes, digest(data) == sha else { throw ProjectError.invalid }
        return data
    }
    /// Decompresses an LZFSE blob through a stream that stops at `maximumBytes`: a crafted blob that expands
    /// without end is refused as too large when it passes the size its record allows, before it can take memory.
    static func inflate(_ packed: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw ProjectError.invalid }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else { throw ProjectError.invalid }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return try packed.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { throw ProjectError.invalid }
            stream.pointee.src_ptr = base; stream.pointee.src_size = packed.count
            while true {
                stream.pointee.dst_ptr = buffer; stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else { throw ProjectError.invalid }
                let produced = chunk - stream.pointee.dst_size
                // One byte past the limit is enough to know: nothing beyond it is ever held.
                guard produced <= maximumBytes - output.count else { throw ProjectError.tooLarge }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END { return output }
                // The input ran out before the stream ended: a blob cut short.
                guard produced > 0 || stream.pointee.src_size > 0 else { throw ProjectError.invalid }
            }
        }
    }

    // MARK: Reading

    /// The history a package holds, as this build can use it. A missing or damaged History folder, or one written
    /// for a different manifest, never stops the document opening and is nothing to keep. One written by a newer
    /// build does not stop it either, but it is somebody's undo history and checkpoints: it is reported apart,
    /// so the first save that would replace the package without it asks first.
    static func stored(in package: URL, manifestSHA256: String) -> Stored {
        struct Header: Decodable { let schema: Int }
        let url = root(of: package).appendingPathComponent("index.json")
        guard let bytes = size(url), bytes <= Int64(maximumIndexBytes), let data = try? Data(contentsOf: url),
              let header = try? decoder.decode(Header.self, from: data) else { return .none }
        if header.schema > schema { return .newer(schema: header.schema) }
        guard header.schema == schema, let index = try? decoder.decode(Index.self, from: data),
              index.manifestSHA256 == manifestSHA256, validate(index.record) else { return .none }
        return .usable(index)
    }
    /// The package's History folder, when its index says this build's schema wrote it.
    private static func readableRoot(of package: URL) -> URL? {
        struct Header: Decodable { let schema: Int }
        let folder = root(of: package), url = folder.appendingPathComponent("index.json")
        guard let bytes = size(url), bytes <= Int64(maximumIndexBytes), let data = try? Data(contentsOf: url),
              (try? decoder.decode(Header.self, from: data))?.schema == schema else { return nil }
        return folder
    }
    static func index(in package: URL, manifestSHA256: String) -> Index? {
        if case .usable(let index) = stored(in: package, manifestSHA256: manifestSHA256) { return index }
        return nil
    }
    /// Every identity is used once, each entry changes something, and nothing is absurdly large. Entries need not
    /// chain: a step can start from a state no other step ended at (the document was changed outside history).
    static func validate(_ record: DocumentHistory.Record) -> Bool {
        let entries = record.past + record.future
        guard entries.count <= 100_000, record.checkpoints.count <= 10_000,
              Set(entries.map(\.id)).count == entries.count, Set(record.checkpoints.map(\.id)).count == record.checkpoints.count,
              entries.allSatisfy({ $0.name.utf8.count <= 16_384 && $0.before != $0.after }),
              record.checkpoints.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 16_384 }) else { return false }
        return true
    }
    private static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    private static func readJSON<T: Decodable>(_ type: T.Type, _ url: URL, maximumBytes: Int = 4 * 1024 * 1024) throws -> T {
        guard let bytes = size(url) else { throw Failure.missing(url.lastPathComponent) }
        guard bytes <= Int64(maximumBytes) else { throw ProjectError.tooLarge }
        do { return try decoder.decode(type, from: Data(contentsOf: url)) } catch { throw ProjectError.invalid }
    }

    /// A stored state as its files give it: everything but the developed pixels of the live source layers a save
    /// did not store (see `stage`), which are developed from their sources next.
    struct Pending: @unchecked Sendable {
        struct Development: @unchecked Sendable {
            let layer: UUID
            let name: String
            let node: LWLiveSourceNode
            let reference: LWFloatPlaneArchive.Reference
        }
        var manifest: ProjectManifest
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var coverages: [UUID: ImportedImage] = [:]
        var selection: DocumentSelection?
        var develop: [Development] = []
    }
    /// A document handed from the thread that read it to the main actor.
    struct Restored: @unchecked Sendable { let document: CanvasDocument? }

    /// Reads one stored state back into memory, sharing every image the session already has. It reads files and,
    /// for a live source layer whose developed pixels were not stored, develops them from the layer's source as an
    /// export does, so it never runs on the main thread: the session calls it from a background task.
    static func restore(_ revision: UUID, package: URL, assets: LWHistoryAssets) async throws -> Restored {
        var coordination: NSError?, result: Result<Pending?, Error>?
        // A save of the same package finishes first: a state is never read from a package caught half replaced.
        NSFileCoordinator().coordinate(readingItemAt: package, options: .withoutChanges, error: &coordination) { url in
            result = Result { try read(revision, package: url, assets: assets) }
        }
        if let coordination { throw coordination }
        guard let result else { throw ProjectError.invalid }
        guard var pending = try result.get() else { return Restored(document: nil) }
        for item in pending.develop {
            try Task.checkCancellation()
            if let known = assets.planeImage(item.reference.manifestSHA256, mask: false) { pending.images[item.layer] = known; continue }
            let made = try await LWSourceDeveloper.shared.evaluatePlane(item.node)
            guard made.surface.width == item.reference.width, made.surface.height == item.reference.height else { throw ProjectError.invalid }
            let asset = try ImportedImage(plane: made.surface, name: item.name)
            assets.register(planeImage: asset, sha: item.reference.manifestSHA256, mask: false)
            pending.images[item.layer] = asset
        }
        var document = CanvasDocument(ProjectSnapshot(manifest: pending.manifest, images: pending.images, masks: pending.masks, coverages: pending.coverages))
        document.selection = pending.selection
        return Restored(document: document)
    }

    /// The files of one stored state. Nil for the state before the first canvas existed.
    static func read(_ revision: UUID, package: URL, assets: LWHistoryAssets) throws -> Pending? {
        let root = root(of: package), folder = root.appendingPathComponent(statePath(revision), isDirectory: true)
        let state = try readJSON(StateRecord.self, folder.appendingPathComponent("state.json"))
        guard state.schema == schema, state.revision == revision else { throw ProjectError.invalid }
        guard state.hasDocument else { return nil }
        let file = try LWSourceOwnedData.read(folder.appendingPathComponent("manifest.json"), maximumBytes: 4 * 1024 * 1024)
        var manifest: ProjectManifest
        do { let decoded = try file.decode(ProjectManifest.self); manifest = decoded.value; manifest.metadataStorage = decoded.owner }
        catch { throw ProjectError.invalid }
        try ProjectStore.shared.validate(manifest)
        manifest = try LWSourcePackageArchive.hydrate(manifest, readOwned: { name, maximum in
            let sha = try sourceDigest(name)
            let data: Data
            if size(root.appendingPathComponent(blobPath(sha))) != nil { data = try readBlob(sha, root: root, maximumBytes: maximum) }
            else {
                // Still one of the document's own source files.
                let own = package.appendingPathComponent("Sources").appendingPathComponent(name)
                guard let bytes = size(own), bytes <= Int64(maximum) else { throw Failure.missing("a source record") }
                data = try Data(contentsOf: own)
                guard digest(data) == sha else { throw ProjectError.invalid }
            }
            return try LWSourceOwnedData.retaining(data)
        }, readPlane: { name, reference in
            let sha = reference.manifestSHA256
            guard name == sha + ".plane" else { throw ProjectError.invalid }
            if let known = assets.plane(sha) { return known }
            let plane = try restorePlane(reference, root: root)
            assets.register(sourcePlane: plane, sha: sha)
            return plane
        })
        try ProjectStore.shared.validate(manifest)
        var pending = Pending(manifest: manifest)
        for layer in manifest.layers {
            for slot in ProjectLayerSlot.allCases {
                guard let name = layer.file(slot) else { continue }
                let isMask = slot.isCoverage
                let asset: ImportedImage
                if name.hasSuffix(".plane") {
                    guard let reference = layer.planeReference(slot) else { throw ProjectError.invalid }
                    let sha = reference.manifestSHA256
                    if let known = assets.planeImage(sha, mask: isMask) { asset = known }
                    else if let plane = try assets.plane(sha) ?? (size(root.appendingPathComponent(planePath(sha))) != nil ? restorePlane(reference, root: root) : nil) {
                        asset = isMask ? try ImportedImage(maskPlane: plane, name: slot == .mask ? "Layer Mask" : "Baked Coverage") : try ImportedImage(plane: plane, name: layer.name)
                        assets.register(planeImage: asset, mask: isMask)
                    } else if slot == .image, let node = layer.liveSource {
                        // A live source layer's developed pixels are not kept: its source develops them again.
                        pending.develop.append(.init(layer: layer.id, name: layer.name, node: node, reference: reference)); continue
                    } else { throw Failure.missing("a layer’s pixels") }
                } else {
                    guard slot != .coverage, let id = state.rasters[name] else { throw ProjectError.invalid }
                    if let known = assets.raster(id) { asset = known }
                    else {
                        asset = try restoreRaster(id, isMask: isMask, name: isMask ? "Layer Mask" : layer.name, root: root)
                        assets.register(raster: id, asset)
                    }
                }
                switch slot {
                case .image: pending.images[layer.id] = asset
                case .mask: guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }; pending.masks[layer.id] = asset
                case .coverage: guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }; pending.coverages[layer.id] = asset
                }
            }
        }
        pending.selection = try state.selection?.selection()
        return pending
    }

    private static func restorePlane(_ reference: LWFloatPlaneArchive.Reference, root: URL) throws -> LWFloatPlane {
        try reference.validate()
        let url = root.appendingPathComponent(planePath(reference.manifestSHA256))
        guard let bytes = size(url) else { throw Failure.missing("a layer’s pixels") }
        guard bytes <= Int64(LWFloatPlaneArchive.maximumManifestBytes) else { throw ProjectError.tooLarge }
        let data = try Data(contentsOf: url)
        guard digest(data) == reference.manifestSHA256 else { throw ProjectError.invalid }
        let manifest = try JSONDecoder().decode(LWFloatPlane.Manifest.self, from: data)
        guard manifest.id == reference.planeID, manifest.width == reference.width, manifest.height == reference.height else { throw ProjectError.invalid }
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        return try LWFloatPlane.restored(manifest, workspace: workspace) { entry in
            try readBlob(entry.sha256, root: root, maximumBytes: entry.bytes)
        }
    }

    private static func restoreRaster(_ id: UUID, isMask: Bool, name: String, root: URL) throws -> ImportedImage {
        let url = root.appendingPathComponent(rasterPath(id))
        guard size(url) != nil else { throw Failure.missing("a layer’s pixels") }
        let record = try readJSON(RasterRecord.self, url, maximumBytes: 16 * 1024 * 1024)
        guard record.schema == schema, (1...DocumentLimits.maxSide).contains(record.width), (1...DocumentLimits.maxSide).contains(record.height),
              record.width * record.height <= DocumentLimits.documentPixelBudget else { throw ProjectError.tooLarge }
        switch record.encoding {
        case "tiles":
            let bytesPerPixel = record.bitsPerPixel / 8, side = record.tileSide
            guard record.bitsPerComponent == 8, record.bitsPerPixel % 8 == 0, (1...4).contains(bytesPerPixel), side == tileSide else { throw ProjectError.invalid }
            let columns = (record.width + side - 1) / side, rows = (record.height + side - 1) / side
            guard record.blobs.count == columns * rows else { throw ProjectError.invalid }
            let rowBytes = record.width * bytesPerPixel
            var pixels = Data(count: rowBytes * record.height)
            try pixels.withUnsafeMutableBytes { target in
                for (index, sha) in record.blobs.enumerated() {
                    let x = index % columns * side, y = index / columns * side
                    let width = min(side, record.width - x), height = min(side, record.height - y)
                    let tile = try readBlob(sha, root: root, maximumBytes: width * height * bytesPerPixel)
                    guard tile.count == width * height * bytesPerPixel else { throw ProjectError.invalid }
                    tile.withUnsafeBytes { source in
                        for row in 0..<height {
                            target.baseAddress!.advanced(by: (y + row) * rowBytes + x * bytesPerPixel)
                                .copyMemory(from: source.baseAddress!.advanced(by: row * width * bytesPerPixel), byteCount: width * bytesPerPixel)
                        }
                    }
                }
            }
            let space: CGColorSpace?
            if record.colorSpace == "kCGColorSpaceDeviceGray" { space = CGColorSpaceCreateDeviceGray() }
            else if record.colorSpace == "kCGColorSpaceDeviceRGB" { space = CGColorSpaceCreateDeviceRGB() }
            else { space = record.colorSpace.flatMap { CGColorSpace(name: $0 as CFString) } }
            guard let space, let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: record.width, height: record.height, bitsPerComponent: 8, bitsPerPixel: record.bitsPerPixel,
                    bytesPerRow: rowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: record.bitmapInfo), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ProjectError.missingImage }
            if isMask { return try LayerMask.asset(from: image) }
            return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
        case "png":
            guard record.blobs.count == 1 else { throw ProjectError.invalid }
            let bytes = try readBlob(record.blobs[0], root: root, maximumBytes: maximumBlobBytes)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier, CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == record.width, image.height == record.height else { throw ProjectError.missingImage }
            if isMask { return try LayerMask.asset(from: image) }
            return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
        case "f32":
            guard record.blobs.count == 1, !isMask else { throw ProjectError.invalid }
            let bytes = try readBlob(record.blobs[0], root: root, maximumBytes: maximumBlobBytes)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorks-history-" + UUID().uuidString + ".f32")
            try bytes.write(to: scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let plane = try LWFloatLegacyArchive.read(from: scratch, maximumFileBytes: maximumBlobBytes, workspace: workspace)
            guard plane.width == record.width, plane.height == record.height else { throw ProjectError.invalid }
            return try ImportedImage(plane: plane, name: name)
        default: throw ProjectError.invalid
        }
    }

    // MARK: Writing

    /// What is in the History folder being staged: every file by its path under it, and which blobs each raster and
    /// plane is made of.
    private struct Pool {
        let root: URL
        /// The History folder of the package being replaced, when there is one: what it already holds is cloned.
        let source: URL?
        let fault: (@Sendable (Stage) throws -> Void)?
        var files: [String: Int64] = [:]
        var rasters: [UUID: [String]] = [:]
        var planes: [String: [String]] = [:]

        mutating func add(_ path: String, _ data: Data) throws {
            if files[path] != nil { return }
            try LWHistoryArchive.write(data, to: root.appendingPathComponent(path))
            files[path] = Int64(data.count)
        }
        mutating func blob(_ data: Data, sha: String? = nil) throws -> String {
            let sha = sha ?? LWHistoryArchive.digest(data), path = LWHistoryArchive.blobPath(sha)
            if files[path] != nil { return sha }
            // The old package already has these bytes under this name: clone the file, do not compress them again.
            // (Read back first: a damaged blob is written afresh from memory, not carried forward.)
            if let source, (try? LWHistoryArchive.readBlob(sha, root: source, maximumBytes: data.count)) == data, try carry(path, from: source) { return sha }
            try fault?(.blob); try add(path, LWHistoryArchive.pack(data))
            return sha
        }
        /// Brings a file over from another package's History folder: a copy-on-write clone where the volume has them.
        mutating func carry(_ path: String, from source: URL) throws -> Bool {
            if files[path] != nil { return true }
            let from = source.appendingPathComponent(path)
            guard let bytes = LWHistoryArchive.size(from) else { return false }
            let to = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
            files[path] = bytes
            return true
        }
    }

    /// The document being saved, as history sees it: which pixels need no copy because the package holds them.
    struct CurrentDocument {
        var rasters: [UUID: String] = [:]
        var planes: Set<String> = []
        var sources: Set<String> = []
    }
    static func currentDocument(_ snapshot: ProjectSnapshot, manifest: ProjectManifest, sources: Set<String>, planes: Set<String>, assets: LWHistoryAssets) -> CurrentDocument {
        var current = CurrentDocument(planes: planes, sources: sources)
        for layer in manifest.layers {
            for slot in ProjectLayerSlot.allCases {
                guard let file = layer.file(slot), let asset = snapshot.asset(slot, for: layer.id) else { continue }
                if let sha = asset.planeArchiveReference?.manifestSHA256, asset.linearPlane != nil { current.planes.insert(sha) }
                else { current.rasters[assets.rasterID(for: asset)] = "images/" + file }
            }
        }
        return current
    }

    private static func ingest(raster asset: ImportedImage, id: UUID, isMask: Bool, pool: inout Pool) throws {
        guard pool.rasters[id] == nil else { return }
        try pool.fault?(.ingest)
        let image = asset.image
        var record: RasterRecord
        if let linear = asset.linear, !isMask {
            let sha = try pool.blob(try linear.packageData(maximumFileBytes: maximumBlobBytes))
            record = RasterRecord(width: image.width, height: image.height, encoding: "f32", blobs: [sha])
        } else if image.bitsPerComponent == 8, image.bitsPerPixel % 8 == 0, (1...4).contains(image.bitsPerPixel / 8), !image.isMask, image.decode == nil,
                  let name = image.colorSpace?.name as String?, let data = image.dataProvider?.data,
                  CFDataGetLength(data) >= (image.height - 1) * image.bytesPerRow + image.width * (image.bitsPerPixel / 8) {
            let bytesPerPixel = image.bitsPerPixel / 8, side = tileSide, stride = image.bytesPerRow
            let columns = (image.width + side - 1) / side, rows = (image.height + side - 1) / side
            var blobs: [String] = []
            blobs.reserveCapacity(columns * rows)
            let base = CFDataGetBytePtr(data)!
            for index in 0..<(columns * rows) {
                try Task.checkCancellation()
                let x = index % columns * side, y = index / columns * side
                let width = min(side, image.width - x), height = min(side, image.height - y)
                var tile = Data(count: width * height * bytesPerPixel)
                tile.withUnsafeMutableBytes { target in
                    for row in 0..<height {
                        target.baseAddress!.advanced(by: row * width * bytesPerPixel)
                            .copyMemory(from: base.advanced(by: (y + row) * stride + x * bytesPerPixel), byteCount: width * bytesPerPixel)
                    }
                }
                blobs.append(try pool.blob(tile))
            }
            record = RasterRecord(width: image.width, height: image.height, encoding: "tiles", bitsPerPixel: image.bitsPerPixel,
                bitmapInfo: image.bitmapInfo.rawValue, colorSpace: name, blobs: blobs)
        } else {
            // A format tiles cannot hold exactly (an unnamed profile, deep or indexed samples): the whole image, as a save writes it.
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ProjectError.encode }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
            let sha = try pool.blob(data as Data)
            record = RasterRecord(width: image.width, height: image.height, encoding: "png", blobs: [sha])
        }
        try pool.add(rasterPath(id), try encoder.encode(record))
        pool.rasters[id] = record.blobs
    }
    private static func ingest(plane: LWFloatPlane, sha: String, pool: inout Pool) throws {
        guard pool.planes[sha] == nil else { return }
        try pool.fault?(.ingest)
        let manifestEncoder = JSONEncoder(); manifestEncoder.outputFormatting = [.sortedKeys]
        let data = try manifestEncoder.encode(plane.manifest)
        guard digest(data) == sha else { throw ProjectError.invalid }
        for entry in plane.manifest.entries {
            try Task.checkCancellation()
            if pool.files[blobPath(entry.sha256)] == nil { _ = try pool.blob(try plane.tileBytes(entry), sha: entry.sha256) }
        }
        try pool.add(planePath(sha), data)
        pool.planes[sha] = plane.manifest.entries.map(\.sha256)
    }
    private static func carry(raster id: UUID, from source: URL, pool: inout Pool) throws -> Bool {
        if pool.rasters[id] != nil { return true }
        let url = source.appendingPathComponent(rasterPath(id))
        guard size(url) != nil, let record = try? readJSON(RasterRecord.self, url, maximumBytes: 16 * 1024 * 1024) else { return false }
        for sha in record.blobs { guard isDigest(sha), try pool.carry(blobPath(sha), from: source) else { return false } }
        guard try pool.carry(rasterPath(id), from: source) else { return false }
        pool.rasters[id] = record.blobs
        return true
    }
    private static func carry(plane sha: String, from source: URL, pool: inout Pool) throws -> Bool {
        if pool.planes[sha] != nil { return true }
        let url = source.appendingPathComponent(planePath(sha))
        guard let bytes = size(url), bytes <= Int64(LWFloatPlaneArchive.maximumManifestBytes), let data = try? Data(contentsOf: url), digest(data) == sha,
              let manifest = try? JSONDecoder().decode(LWFloatPlane.Manifest.self, from: data) else { return false }
        for entry in manifest.entries { guard isDigest(entry.sha256), try pool.carry(blobPath(entry.sha256), from: source) else { return false } }
        guard try pool.carry(planePath(sha), from: source) else { return false }
        pool.planes[sha] = manifest.entries.map(\.sha256)
        return true
    }

    /// The History files one state needs beyond its own folder.
    private static func files(_ needs: Needs, current: CurrentDocument, pool: Pool) -> Set<String> {
        var result = Set<String>()
        for id in needs.rasters where current.rasters[id] == nil {
            result.insert(rasterPath(id)); for sha in pool.rasters[id] ?? [] { result.insert(blobPath(sha)) }
        }
        for sha in needs.planes where !current.planes.contains(sha) {
            result.insert(planePath(sha)); for tile in pool.planes[sha] ?? [] { result.insert(blobPath(tile)) }
        }
        for name in needs.sources where !current.sources.contains(name) { result.insert(blobPath(String(name.prefix(64)))) }
        return result
    }

    /// Writes a state that is in memory: its manifest, and whatever of its pixels the document does not hold.
    private static func stage(_ live: LiveState, revision: UUID, current: CurrentDocument, assets: LWHistoryAssets, pool: inout Pool) throws -> Needs {
        let folder = statePath(revision)
        guard let snapshot = live.snapshot else {
            try pool.add(folder + "/state.json", try encoder.encode(StateRecord(revision: revision, hasDocument: false)))
            return Needs()
        }
        var manifest = try ProjectStore.shared.normalized(snapshot.manifest, snapshot: snapshot, version: nil)
        let projection = try LWSourcePackageArchive.externalize(manifest, maximumBytes: LWSourceDeveloper.maximumResultBytes)
        let owners = projection.ownership
        defer { withExtendedLifetime(owners) {} }
        manifest = projection.manifest
        try ProjectStore.shared.validate(manifest)
        var state = StateRecord(revision: revision, hasDocument: true, selection: live.selection.map { SelectionRecord($0) })
        var rasters = Set<UUID>(), planes = Set<String>()
        for layer in manifest.layers {
            for slot in ProjectLayerSlot.allCases {
                let isMask = slot.isCoverage
                guard let file = layer.file(slot) else { continue }
                guard let asset = snapshot.asset(slot, for: layer.id) else { throw ProjectError.missingImage }
                if let plane = asset.linearPlane {
                    guard let reference = layer.planeReference(slot),
                          reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }
                    // A live source layer's developed pixels are a cache of its source: the state keeps the source
                    // node (its recipe, with whatever planes that needs) and the pixels are developed again when
                    // the state is read back. A recipe change then costs its recipe, not a whole developed frame.
                    if slot == .image, layer.liveSource != nil || layer.liveSourceFile != nil { continue }
                    planes.insert(reference.manifestSHA256)
                    if !current.planes.contains(reference.manifestSHA256) { try ingest(plane: plane, sha: reference.manifestSHA256, pool: &pool) }
                } else {
                    guard slot != .coverage else { throw ProjectError.invalid }
                    let id = assets.rasterID(for: asset)
                    state.rasters[file] = id; rasters.insert(id)
                    if current.rasters[id] == nil { try ingest(raster: asset, id: id, isMask: isMask, pool: &pool) }
                }
            }
        }
        for (name, backing) in projection.planes {
            let sha = backing.reference.manifestSHA256
            guard name == sha + ".plane", let plane = backing.plane else { throw ProjectError.missingImage }
            planes.insert(sha)
            if !current.planes.contains(sha) { try ingest(plane: plane, sha: sha, pool: &pool) }
        }
        for (name, data) in projection.assets where !current.sources.contains(name) { _ = try pool.blob(data, sha: try sourceDigest(name)) }
        state.needs = Needs(rasters: rasters.sorted { $0.uuidString < $1.uuidString }, planes: planes.sorted(), sources: projection.assets.keys.sorted())
        let encoded = try LWSourceMetadataStorage.encode(manifest, maximumBytes: 4 * 1024 * 1024, formatting: [.sortedKeys])
        try pool.add(folder + "/manifest.json", try encoded.copyData(ownedBy: encoded.owner))
        try pool.add(folder + "/state.json", try encoder.encode(state))
        return state.needs
    }

    /// Brings a state over from the package it was last saved in. Pixels that package held as its own document and
    /// this one no longer does are written from memory, where the session kept them for exactly this.
    private static func carry(_ revision: UUID, from source: URL, package: URL, current: CurrentDocument, assets: LWHistoryAssets, pool: inout Pool) throws -> Needs? {
        let folder = statePath(revision)
        guard let state = try? readJSON(StateRecord.self, source.appendingPathComponent(folder + "/state.json")),
              state.schema == schema, state.revision == revision else { return nil }
        if state.hasDocument {
            for id in state.needs.rasters where current.rasters[id] == nil {
                if try carry(raster: id, from: source, pool: &pool) { continue }
                guard let asset = assets.raster(id) else { return nil }
                try ingest(raster: asset, id: id, isMask: LayerMask.isValid(asset.image), pool: &pool)
            }
            for sha in state.needs.planes where !current.planes.contains(sha) {
                guard isDigest(sha) else { return nil }
                if try carry(plane: sha, from: source, pool: &pool) { continue }
                guard let plane = assets.plane(sha) else { return nil }
                try ingest(plane: plane, sha: sha, pool: &pool)
            }
            for name in state.needs.sources where !current.sources.contains(name) {
                guard let sha = try? sourceDigest(name) else { return nil }
                if try pool.carry(blobPath(sha), from: source) { continue }
                let own = package.appendingPathComponent("Sources").appendingPathComponent(name)
                guard let bytes = size(own), bytes <= Int64(LWSourceDeveloper.maximumResultBytes), let data = try? Data(contentsOf: own), digest(data) == sha else { return nil }
                _ = try pool.blob(data, sha: sha)
            }
            guard try pool.carry(folder + "/manifest.json", from: source) else { return nil }
        }
        guard try pool.carry(folder + "/state.json", from: source) else { return nil }
        return state.needs
    }

    /// Which entries have to go for the History folder to fit `limit`: the oldest steps first, then the furthest
    /// redo steps. Checkpoints and the current state are never candidates; when they alone are over the limit the
    /// record keeps them and `protected` says how much they take.
    static func prune(_ record: inout DocumentHistory.Record, files: [UUID: Set<String>], sizes: [String: Int64], stateBytes: [UUID: Int64],
                      limit: Int64) -> (pruned: [DocumentHistory.Record.Entry], bytes: Int64, protected: Int64) {
        func total(_ record: DocumentHistory.Record) -> Int64 {
            var paths = Set<String>(), bytes: Int64 = 0
            for state in record.states { paths.formUnion(files[state] ?? []); bytes += stateBytes[state] ?? 0 }
            for path in paths { bytes += sizes[path] ?? 0 }
            return bytes
        }
        var pruned: [DocumentHistory.Record.Entry] = []
        var bytes = total(record)
        while limit > 0, bytes > limit {
            if !record.past.isEmpty { pruned.append(record.past.removeFirst()) }
            else if !record.future.isEmpty { pruned.append(record.future.removeFirst()) }
            else { break }
            bytes = total(record)
        }
        var bare = record; bare.past = []; bare.future = []
        return (pruned, bytes, total(bare))
    }

    /// Writes the History folder into a staged package, before that package replaces the one on disk. Nothing
    /// outside `staged` is touched, so a failure (or the process dying) at any point leaves the old package whole.
    static func write(_ capture: Capture, current: CurrentDocument, manifestSHA256: String, into staged: URL) throws -> Commit {
        var record = capture.record
        var commit = Commit(limitBytes: capture.limitBytes, rasters: current.rasters)
        guard !record.isEmpty else { return commit }
        let root = root(of: staged)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Only a History folder this build wrote (or can read) is a source: its blobs are named and packed as ours are.
        let source = capture.source.flatMap { readableRoot(of: $0) }
        var pool = Pool(root: root, source: source, fault: capture.fault)
        var needs: [UUID: Needs] = [:], unavailable = Set<UUID>()
        let revisions = record.states.sorted(by: { $0.uuidString < $1.uuidString })
        // First everything the old package holds, cloned as it is; then the states in memory, which by then find
        // the images and tiles they share with a stored state already staged and neither cut nor compress them again.
        var staging: [UUID] = []
        for revision in revisions {
            try Task.checkCancellation()
            guard capture.stored.contains(revision), let source, let package = capture.source else { staging.append(revision); continue }
            try capture.fault?(.state)
            if let carried = try carry(revision, from: source, package: package, current: current, assets: capture.assets, pool: &pool) { needs[revision] = carried }
            else { staging.append(revision) }
        }
        for revision in staging {
            try Task.checkCancellation()
            try capture.fault?(.state)
            if let live = capture.live[revision] { needs[revision] = try stage(live, revision: revision, current: current, assets: capture.assets, pool: &pool) }
            else { unavailable.insert(revision) }
        }
        // A state that is neither in memory nor readable from the old package cannot be kept: the steps through it
        // go, and the person is told. Steps on the far side of a lost one are unreachable and go with it.
        if !unavailable.isEmpty {
            guard !unavailable.contains(record.cursor) else { throw ProjectError.invalid }
            func lost(_ entry: DocumentHistory.Record.Entry) -> Bool { unavailable.contains(entry.before) || unavailable.contains(entry.after) }
            if let index = record.past.lastIndex(where: lost) {
                commit.lost += record.past[...index].map(\.name); commit.pruned.formUnion(record.past[...index].map(\.id)); record.past.removeFirst(index + 1)
            }
            if let index = record.future.lastIndex(where: lost) {
                commit.lost += record.future[...index].map(\.name); commit.pruned.formUnion(record.future[...index].map(\.id)); record.future.removeFirst(index + 1)
            }
            commit.lost += record.checkpoints.filter { unavailable.contains($0.state) }.map(\.name)
            record.checkpoints.removeAll { unavailable.contains($0.state) }
        }
        try capture.fault?(.prune)
        var files: [UUID: Set<String>] = [:], stateBytes: [UUID: Int64] = [:]
        for (revision, need) in needs {
            files[revision] = self.files(need, current: current, pool: pool)
            stateBytes[revision] = (pool.files[statePath(revision) + "/state.json"] ?? 0) + (pool.files[statePath(revision) + "/manifest.json"] ?? 0)
        }
        let plan = prune(&record, files: files, sizes: pool.files, stateBytes: stateBytes, limit: capture.limitBytes)
        commit.pruned.formUnion(plan.pruned.map(\.id)); commit.prunedNames = plan.pruned.map(\.name)
        commit.bytes = plan.bytes; commit.protectedBytes = plan.protected
        // Sweep: only what a kept state needs stays in the staged folder.
        let kept = record.states
        var wanted = Set<String>()
        for revision in kept {
            wanted.formUnion(files[revision] ?? [])
            wanted.insert(statePath(revision) + "/state.json"); wanted.insert(statePath(revision) + "/manifest.json")
        }
        for path in pool.files.keys where !wanted.contains(path) { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
        for revision in needs.keys where !kept.contains(revision) { try? FileManager.default.removeItem(at: root.appendingPathComponent(statePath(revision))) }
        if record.isEmpty {
            try FileManager.default.removeItem(at: root)
            return commit
        }
        try capture.fault?(.index)
        let index = Index(manifestSHA256: manifestSHA256, record: record,
            document: Dictionary(uniqueKeysWithValues: current.rasters.map { ($0.key.uuidString, $0.value) }), bytes: plan.bytes, protectedBytes: plan.protected)
        let data = try encoder.encode(index)
        guard data.count <= maximumIndexBytes else { throw ProjectError.tooLarge }
        try data.write(to: root.appendingPathComponent("index.json"))
        commit.stored = kept
        return commit
    }

    /// Rebinds a copied package's history to its rewritten manifest (a duplicated version has a new identity).
    static func rebind(_ package: URL, manifestSHA256: String) throws {
        let url = root(of: package).appendingPathComponent("index.json")
        guard let bytes = size(url) else { return }
        // Only the one value changes; an index a newer build wrote keeps every field this build does not know.
        guard bytes <= Int64(maximumIndexBytes), var index = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              index["manifestSHA256"] is String else { throw ProjectError.invalid }
        index["manifestSHA256"] = manifestSHA256
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
    }
    /// What the History folder of a package takes on disk.
    static func bytes(in package: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: root(of: package), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker { total += size(url) ?? 0 }
        return total
    }
}
