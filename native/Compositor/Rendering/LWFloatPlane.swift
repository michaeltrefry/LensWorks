import Foundation
import Darwin
import CryptoKit

/// Extent is admitted separately from resident bytes. A complete RAW may exceed one
/// managed result; every immutable range and temporary array remains within that result ceiling.
nonisolated struct LWFloatRange: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    func validate(frameWidth: Int, frameHeight: Int) throws -> Int {
        let (right, ox) = x.addingReportingOverflow(width), (bottom, oy) = y.addingReportingOverflow(height)
        let (count, oc) = width.multipliedReportingOverflow(by: height)
        let (bytes, ob) = count.multipliedReportingOverflow(by: 16)
        guard x >= 0, y >= 0, width > 0, height > 0, !ox, !oy, !oc, !ob,
            right <= frameWidth, bottom <= frameHeight else { throw ProjectError.invalid }
        return bytes
    }
    func expanded(halo: Int, frameWidth: Int, frameHeight: Int) throws -> Self {
        _ = try validate(frameWidth: frameWidth, frameHeight: frameHeight)
        guard halo >= 0 else { throw ProjectError.invalid }
        let (right, rightOverflow) = (x + width).addingReportingOverflow(halo)
        let (bottom, bottomOverflow) = (y + height).addingReportingOverflow(halo)
        guard !rightOverflow, !bottomOverflow else { throw ProjectError.tooLarge }
        let left = max(0, x - min(x, halo)), top = max(0, y - min(y, halo))
        return Self(x: left, y: top, width: min(frameWidth, right) - left, height: min(frameHeight, bottom) - top)
    }
    var native: LWSourceTileRect {
        get throws {
            guard let x = UInt32(exactly: x), let y = UInt32(exactly: y),
                let width = UInt32(exactly: width), let height = UInt32(exactly: height) else { throw ProjectError.invalid }
            return LWSourceTileRect(x: x, y: y, width: width, height: height)
        }
    }
}

nonisolated extension LWFloatRange {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        guard Set(c.allKeys.map(\.stringValue)) == ["x", "y", "width", "height"] else { throw ProjectError.invalid }
        x = try c.decode(Int.self, forKey: .init("x")); y = try c.decode(Int.self, forKey: .init("y"))
        width = try c.decode(Int.self, forKey: .init("width")); height = try c.decode(Int.self, forKey: .init("height"))
    }
}

nonisolated extension LWFloatPlane.Entry {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        guard Set(c.allKeys.map(\.stringValue)) == ["range", "file", "bytes", "sha256"] else { throw ProjectError.invalid }
        range = try c.decode(LWFloatRange.self, forKey: .init("range")); file = try c.decode(String.self, forKey: .init("file"))
        bytes = try c.decode(Int.self, forKey: .init("bytes")); sha256 = try c.decode(String.self, forKey: .init("sha256"))
    }
}

nonisolated extension LWFloatPlane.Manifest {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        guard Set(c.allKeys.map(\.stringValue)) == ["schema", "id", "width", "height", "tileSide", "sample", "colorSpace", "alpha", "entries"] else { throw ProjectError.invalid }
        schema = try c.decode(Int.self, forKey: .init("schema")); id = try c.decode(UUID.self, forKey: .init("id"))
        width = try c.decode(Int.self, forKey: .init("width")); height = try c.decode(Int.self, forKey: .init("height"))
        tileSide = try c.decode(Int.self, forKey: .init("tileSide")); sample = try c.decode(String.self, forKey: .init("sample"))
        colorSpace = try c.decode(String.self, forKey: .init("colorSpace")); alpha = try c.decode(String.self, forKey: .init("alpha"))
        entries = try c.decode([LWFloatPlane.Entry].self, forKey: .init("entries"))
        try validate()
    }
}

/// One shared admission for tile samples, decoded backing, output and operation scratch.
/// Owners release their charge only when the corresponding buffers cease to be retained.
nonisolated final class LWFloatWorkingSet: @unchecked Sendable {
    static let maximumBytes = 512 * 1024 * 1024
    /// Production source graphs share one owner. A new document/import cannot
    /// multiply the admitted native float working set by opening another workspace.
    static let sourceGraphs = try! LWFloatWorkingSet(limit: maximumBytes)
    let limit: Int
    private let lock = NSLock()
    private var retained = 0
    private var peak = 0
    /// Exact admitted-byte accounting only; no process RSS or retirement grant.
    var retainedBytes:Int { lock.withLock { retained } }
    /// Highest admitted residency since creation or the last `resetPeak`.
    var peakRetainedBytes:Int { lock.withLock { peak } }
    func resetPeak() { lock.withLock { peak = retained } }
    init(limit: Int = maximumBytes) throws {
        guard limit > 0, limit <= Self.maximumBytes else { throw ProjectError.tooLarge }
        self.limit = limit
    }
    func reserve(_ bytes: Int) throws -> Lease {
        try lock.withLock {
            guard bytes >= 0, bytes <= limit - retained else { throw ProjectError.tooLarge }
            retained += bytes; peak = max(peak, retained)
            return Lease(owner: self, bytes: bytes)
        }
    }
    func withScratch<Value>(bytes: Int, _ body: () throws -> Value) throws -> Value {
        let lease = try reserve(bytes)
        defer { withExtendedLifetime(lease) {} }
        return try body()
    }
    private func release(_ bytes: Int) { lock.withLock { retained -= bytes } }
    final class Lease: @unchecked Sendable {
        private let owner: LWFloatWorkingSet
        let bytes: Int
        fileprivate init(owner: LWFloatWorkingSet, bytes: Int) { self.owner = owner; self.bytes = bytes }
        deinit { owner.release(bytes) }
    }
}

/// Immutable range plus global coordinates. Kernels must never infer global origin from local dimensions.
nonisolated final class LWFloatTile: Sendable {
    let range: LWFloatRange
    let frameWidth: Int
    let frameHeight: Int
    let surface: LWSourceOwnedLinearSurface
    fileprivate init(range: LWFloatRange, frameWidth: Int, frameHeight: Int,
        surface: LWSourceOwnedLinearSurface) {
        self.range = range; self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.surface = surface
    }
}

/// Private immutable f32 tile backing. Files are held through a no-follow directory
/// descriptor; every read checks the named inode, complete bytes and content hash.
nonisolated struct LWFloatPlane: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let range: LWFloatRange
        let file: String
        let bytes: Int
        let sha256: String
    }
    struct Manifest: Codable, Equatable, Sendable {
        let schema: Int
        let id: UUID
        let width: Int
        let height: Int
        let tileSide: Int
        let sample: String
        let colorSpace: String
        let alpha: String
        let entries: [Entry]
        func validate() throws {
            try LWFloatPlane.validateExtent(width: width, height: height)
            guard schema == 1, tileSide == LWFloatPlane.tileSide, sample == "float32-le",
                colorSpace == "extended-linear-sRGB", alpha == "straight",
                entries.count == ((width + tileSide - 1) / tileSide) * ((height + tileSide - 1) / tileSide) else { throw ProjectError.invalid }
            for (index, entry) in entries.enumerated() {
                guard entry.range == LWFloatPlane.range(index: index, width: width, height: height),
                    entry.file == String(format: "%08d.f32", index),
                    entry.bytes == (try entry.range.validate(frameWidth: width, frameHeight: height)),
                    entry.sha256.count == 64, entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProjectError.invalid }
            }
        }
    }
    static func open(directory: URL, manifest: Manifest, workingSet: LWFloatWorkingSet) throws -> Self {
        try manifest.validate()
        let backing = try Backing.acquire(directory: directory, requireEmpty: false)
        try backing.validateMembers(manifest.entries)
        let metadataLease = try workingSet.reserve(manifest.entries.count * (MemoryLayout<Entry>.stride * 2 + 256))
        return Self(manifest: manifest, workingSet: workingSet, backing: backing, metadataLease: metadataLease)
    }
    /// Explicit whole-workspace cleanup cannot invalidate any live builder,
    /// independently opened plane, sampler, provider, history or composite value.
    static func withWorkspaceRetirementBarrier<T>(_ owner: LWFloatWorkspace, _ body: () throws -> T) throws -> T {
        try Backing.withAcquisitionLock {
            guard !Backing.hasLiveBacking(ownedBy: owner) else { throw ProjectError.invalid }
            return try body()
        }
    }
    static let tileSide = 256
    let manifest: Manifest
    let workingSet: LWFloatWorkingSet
    private var backing: Backing
    var workspaceOwner: LWFloatWorkspace? { backing.owner }
    private let metadataLease: LWFloatWorkingSet.Lease
    var width: Int { manifest.width }
    var height: Int { manifest.height }
    var retainedMetadataBytes: Int { metadataLease.bytes }
    /// Every plane value, sampler and provider retains the same backing. Only an
    /// exclusive evaluator value can retire its generation; retained history or
    /// readers make this return false without any filesystem change.
    mutating func retireOwnedBacking(using workspace: LWFloatWorkspace) throws -> Bool {
        // Opening the same named directory must retain this backing too. Hold
        // the acquisition lock through the uniqueness check and deletion so a
        // concurrent open cannot slip between them.
        try Backing.withAcquisitionLock {
            guard isKnownUniquelyReferenced(&backing), backing.owned(by: workspace) else { return false }
            try backing.validateMembers(manifest.entries)
            guard let lifetime = backing.lifetime else { throw ProjectError.invalid }
            try workspace.retireOwnedDirectory(backing.directoryURL, lifetime: lifetime)
            backing.markRetired()
            return true
        }
    }

    var globalExtent: LWFloatRange { LWFloatRange(x: 0, y: 0, width: width, height: height) }
    static func validateExtent(width: Int, height: Int) throws {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
            !overflow, count <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
    }
    static func range(index: Int, width: Int, height: Int) -> LWFloatRange {
        let columns = (width + tileSide - 1) / tileSide
        let x = index % columns * tileSide, y = index / columns * tileSide
        return LWFloatRange(x: x, y: y, width: min(tileSide, width - x), height: min(tileSide, height - y))
    }
    /// Read any admitted global rectangle. The output and one decoded backing tile
    /// are charged together before allocation; no full-plane Data is constructed.
    func checkCancellation() throws { try backing.checkCancellation(); try Task.checkCancellation() }
    func read(_ range: LWFloatRange) throws -> LWFloatTile {
        try checkCancellation()
        let bytes = try range.validate(frameWidth: width, frameHeight: height)
        let (charge, overflow) = bytes.addingReportingOverflow(Self.tileSide * Self.tileSide * 16 * 2)
        guard !overflow else { throw ProjectError.tooLarge }
        let lease = try workingSet.reserve(charge)
        var pixels = [SIMD4<Float>](repeating: .zero, count: bytes / 16)
        let firstColumn = range.x / Self.tileSide, lastColumn = (range.x + range.width - 1) / Self.tileSide
        let firstRow = range.y / Self.tileSide, lastRow = (range.y + range.height - 1) / Self.tileSide
        let columns = (width + Self.tileSide - 1) / Self.tileSide
        for row in firstRow...lastRow { for column in firstColumn...lastColumn {
            try Task.checkCancellation()
            let entry = manifest.entries[row * columns + column]
            let data = try backing.read(entry)
            let left = max(range.x, entry.range.x), right = min(range.x + range.width, entry.range.x + entry.range.width)
            let top = max(range.y, entry.range.y), bottom = min(range.y + range.height, entry.range.y + entry.range.height)
            guard data.count == entry.range.width * entry.range.height * 16 else { throw ProjectError.invalid }
            try data.withUnsafeBytes { raw in
                for y in top..<bottom { for x in left..<right {
                    let source = ((y - entry.range.y) * entry.range.width + x - entry.range.x) * 16
                    func word(_ channel: Int) -> Float {
                        Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: source + channel * 4, as: UInt32.self)))
                    }
                    let pixel = SIMD4(word(0), word(1), word(2), word(3))
                    guard pixel.x.isFinite, pixel.y.isFinite, pixel.z.isFinite, pixel.w.isFinite, (0...1).contains(pixel.w) else { throw ProjectError.invalid }
                    pixels[(y - range.y) * range.width + x - range.x] = pixel
                } }
            }
        } }
        // The temporary decode/entry buffers retire here. Published immutable
        // samples own a separate exact allocation charge through every escaped
        // surface/collection/slice/provider alias, independent of this tile object.
        let surface=try LWLinearSurface.admitted(width:range.width,height:range.height,maximumBytes:bytes,
            workingSet:workingSet) { pixels[$0] }
        withExtendedLifetime(lease) {}
        return LWFloatTile(range:range,frameWidth:width,frameHeight:height,surface:surface)
    }
    func read(range: LWFloatRange) throws -> LWFloatTile { try read(range) }
    /// Copy immutable content and its identity with one backing tile resident.
    /// Used when a package is opened into graph-owned storage or staged for save.
    func copy(directory: URL, workspace: LWFloatWorkspace? = nil) throws -> Self {
        let target = try Backing.acquire(directory: directory, requireEmpty: true, workspace: workspace)
        let metadata = try workingSet.reserve(manifest.entries.count * (MemoryLayout<Entry>.stride * 2 + 256))
        for entry in manifest.entries {
            try Task.checkCancellation()
            let scratch = try workingSet.reserve(entry.bytes * 2)
            defer { withExtendedLifetime(scratch) {} }
            let data = try backing.read(entry)
            try target.write(data, entry: entry)
        }
        try target.validateMembers(manifest.entries)
        return Self(manifest: manifest, workingSet: workingSet, backing: target, metadataLease: metadata)
    }
    /// Deterministic row-major tile order; each range retains its complete global origin.
    func forEachTile(_ body: (LWFloatRange) throws -> Void) throws {
        for entry in manifest.entries { try checkCancellation(); try body(entry.range); try checkCancellation() }
    }
    /// Await one range at a time. A cancelled body cannot advance to a later tile.
    func forEachTile(_ body: (LWFloatRange) async throws -> Void) async throws {
        for entry in manifest.entries {
            try checkCancellation()
            try await body(entry.range)
            try checkCancellation()
        }
    }
    enum Edge: Equatable, Sendable { case transparent, clamp }
    /// A bounded per-operation cache for nonlocal geometry, optics and convolution.
    /// Samples use premultiplied interpolation, then return the working straight RGBA value.
    final class Sampler {
        private let plane: LWFloatPlane
        private let defaultEdge: Edge
        private var tiles: [(index: Int, tile: LWFloatTile)] = []
        fileprivate init(plane: LWFloatPlane, edge: Edge) { self.plane = plane; defaultEdge = edge }
        func pixel(x inputX: Int, y inputY: Int, edge requestedEdge: Edge? = nil) throws -> SIMD4<Float> {
            try plane.checkCancellation()
            let edge = requestedEdge ?? defaultEdge
            let x: Int, y: Int
            switch edge {
            case .transparent:
                guard inputX >= 0, inputY >= 0, inputX < plane.width, inputY < plane.height else { return .zero }
                x = inputX; y = inputY
            case .clamp: x = min(plane.width - 1, max(0, inputX)); y = min(plane.height - 1, max(0, inputY))
            }
            let columns = (plane.width + tileSide - 1) / tileSide
            let index = y / tileSide * columns + x / tileSide
            let tile: LWFloatTile
            if let retained = tiles.firstIndex(where: { $0.index == index }) {
                let item = tiles.remove(at: retained); tiles.append(item); tile = item.tile
            } else {
                if tiles.count == 4 { tiles.removeFirst() }
                tile = try plane.read(plane.manifest.entries[index].range)
                tiles.append((index, tile))
            }
            return tile.surface.pixels[(y - tile.range.y) * tile.range.width + x - tile.range.x]
        }
        func sample(_ point: CGPoint, edge requestedEdge: Edge? = nil) throws -> SIMD4<Float> {
            guard point.x.isFinite, point.y.isFinite else { throw ProjectError.invalid }
            let edge = requestedEdge ?? defaultEdge
            // Reject before any Double→Int conversion. Out-of-frame sampling is an explicit edge rule.
            var px = Double(point.x) - 0.5, py = Double(point.y) - 0.5
            switch edge {
            case .transparent:
                guard px > -1, px < Double(plane.width), py > -1, py < Double(plane.height) else { return .zero }
            case .clamp:
                px = min(Double(plane.width - 1), max(0, px)); py = min(Double(plane.height - 1), max(0, py))
            }
            let x = Int(floor(px)), y = Int(floor(py)), tx = Float(px - floor(px)), ty = Float(py - floor(py))
            let weights = [(x,y,(1-tx)*(1-ty)),(x+1,y,tx*(1-ty)),(x,y+1,(1-tx)*ty),(x+1,y+1,tx*ty)]
            var premultiplied = SIMD4<Float>.zero
            for (x,y,weight) in weights {
                let value = try pixel(x: x, y: y, edge: edge)
                premultiplied += SIMD4(value.x * value.w, value.y * value.w, value.z * value.w, value.w) * weight
            }
            return premultiplied.w > 0 ? SIMD4(premultiplied.x / premultiplied.w,
                premultiplied.y / premultiplied.w, premultiplied.z / premultiplied.w, premultiplied.w) : .zero
        }
    }
    func sampler(edge: Edge = .transparent) -> Sampler { Sampler(plane: self, edge: edge) }
    /// Caller supplies a new exclusive private directory; it cannot be a protected original or catalog.
    final class Builder {
        let width: Int
        let height: Int
        let workingSet: LWFloatWorkingSet
        private let backing: Backing
        private let metadataLease: LWFloatWorkingSet.Lease
        private var entries: [Entry] = []
        private var sealed = false
        init(directory: URL, width: Int, height: Int, workingSet: LWFloatWorkingSet, workspace: LWFloatWorkspace? = nil) throws {
            // Claim the pending writer before validation/admission can fail.
            let ownedBacking = try Backing.acquire(directory: directory, requireEmpty: true, workspace: workspace)
            try LWFloatPlane.validateExtent(width: width, height: height)
            self.width = width; self.height = height; self.workingSet = workingSet
            let tiles = ((width + tileSide - 1) / tileSide) * ((height + tileSide - 1) / tileSide)
            metadataLease = try workingSet.reserve(tiles * (MemoryLayout<Entry>.stride * 2 + 256))
            self.backing = ownedBacking
        }
        var nextRange: LWFloatRange? {
            let count = ((width + tileSide - 1) / tileSide) * ((height + tileSide - 1) / tileSide)
            return entries.count < count ? LWFloatPlane.range(index: entries.count, width: width, height: height) : nil
        }
        func append(_ surface:LWLinearSurface,at range:LWFloatRange) throws {
            try surface.validate(maximumBytes:try range.validate(frameWidth:width,frameHeight:height))
            try appendPixels(surface.pixels,surfaceWidth:surface.width,surfaceHeight:surface.height,at:range)
        }
        func append(_ surface:LWSourceOwnedLinearSurface,at range:LWFloatRange) throws {
            guard surface.workingSet === workingSet else { throw ProjectError.invalid }
            try surface.validate(maximumBytes:try range.validate(frameWidth:width,frameHeight:height))
            try appendPixels(surface.pixels,surfaceWidth:surface.width,surfaceHeight:surface.height,at:range)
        }
        private func appendPixels<C:Collection>(_ pixels:C,surfaceWidth:Int,surfaceHeight:Int,at range:LWFloatRange) throws where C.Element == SIMD4<Float> {
            try Task.checkCancellation()
            guard !sealed,range == nextRange,surfaceWidth == range.width,surfaceHeight == range.height else { throw ProjectError.invalid }
            let bytes=try range.validate(frameWidth:width,frameHeight:height)
            let (charge,overflow)=bytes.multipliedReportingOverflow(by:2)
            guard !overflow,pixels.count == bytes/16 else { throw ProjectError.tooLarge }
            let lease=try workingSet.reserve(charge)
            defer { withExtendedLifetime(lease) {} }
            var data=Data(count:bytes)
            data.withUnsafeMutableBytes { raw in
                var offset=0
                for pixel in pixels { for channel in 0..<4 {
                    raw.storeBytes(of:pixel[channel].bitPattern.littleEndian,toByteOffset:offset,as:UInt32.self);offset+=4
                } }
            }
            let file=String(format:"%08d.f32",entries.count)
            let entry=Entry(range:range,file:file,bytes:bytes,sha256:Self.digest(data))
            try backing.write(data,entry:entry);entries.append(entry)
        }
        func finish() throws -> LWFloatPlane {
            guard !sealed, nextRange == nil else { throw ProjectError.invalid }
            let manifest = Manifest(schema: 1, id: UUID(), width: width, height: height, tileSide: tileSide,
                sample: "float32-le", colorSpace: "extended-linear-sRGB", alpha: "straight", entries: entries)
            try manifest.validate(); try backing.validateMembers(entries)
            sealed = true
            return LWFloatPlane(manifest: manifest, workingSet: workingSet, backing: backing, metadataLease: metadataLease)
        }
        private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    private final class Backing: @unchecked Sendable {
        private final class WeakBacking { weak var value: Backing?; init(_ value: Backing) { self.value = value } }
        private final class Registry: @unchecked Sendable {
            let lock = NSLock()
            var values: [String: WeakBacking] = [:]
        }
        private static let registry = Registry()
        static func withAcquisitionLock<T>(_ body: () throws -> T) rethrows -> T {
            try registry.lock.withLock(body)
        }
        // Called only under the acquisition/retirement lock. The weak registry
        // does not own generations, but sees every independently acquired alias.
        static func hasLiveBacking(ownedBy owner: LWFloatWorkspace) -> Bool {
            registry.values.values.contains { $0.value?.workspace === owner }
        }
        static func acquire(directory: URL, requireEmpty: Bool, workspace: LWFloatWorkspace? = nil) throws -> Backing {
            try registry.lock.withLock {
                // A held real chain supplies the key; path spellings alone never
                // establish an alias or permission to adopt an existing child.
                let chain = try LWFloatDirectoryChain(directory)
                var identity = stat()
                guard fstat(chain.fd, &identity) == 0 else { throw ProjectError.invalid }
                let key = "\(identity.st_dev):\(identity.st_ino)"
                if let existing = registry.values[key]?.value {
                    guard !requireEmpty, existing.directory.physicalFileURL?.path == directory.physicalFileURL?.path,
                        workspace == nil || existing.workspace === workspace else { throw ProjectError.invalid }
                    try existing.checkDirectory(); try chain.check()
                    return existing
                }
                // Remove dead weak entries in-place. A filter projection would
                // allocate a second dictionary of every live generation before
                // its registered child metadata allowance could cover it.
                while let stale=registry.values.first(where: { $0.value.value == nil }) {
                    registry.values.removeValue(forKey:stale.key)
                }
                let backing = try Backing(directory: directory, requireEmpty: requireEmpty, workspace: workspace)
                registry.values[key] = WeakBacking(backing)
                try chain.check()
                return backing
            }
        }
        private let memberLock = NSRecursiveLock()
        private let workspace: LWFloatWorkspace?
        var owner: LWFloatWorkspace? { workspace }
        fileprivate let lifetime: LWFloatWorkspace.ChildLifetime?
        private let chain: LWFloatDirectoryChain
        private let fd: Int32
        private let directory: URL
        private let identity: stat
        private var identities: [String: stat] = [:]
        private var retired = false
        var directoryURL: URL { directory }
        func owned(by owner: LWFloatWorkspace) -> Bool { workspace === owner && !retired }
        func markRetired() { retired = true }
        private init(directory: URL, requireEmpty: Bool, workspace: LWFloatWorkspace? = nil) throws {
            guard directory.isFileURL, directory.hasNormalizedPath,
                directory.isUnaliasedFilePath else { throw ProjectError.invalid }
            self.directory = directory
            self.workspace = workspace
            lifetime = try workspace?.retainChild(directory)
            let chain = try LWFloatDirectoryChain(directory)
            self.chain = chain
            let descriptor = chain.fd
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw ProjectError.invalid }
            fd = descriptor; identity = info
            do {
                try checkDirectory()
                if requireEmpty { guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw ProjectError.invalid } }
            } catch { throw error }
        }
        func checkCancellation() throws { try workspace?.cancellation.check() }
        func checkDirectory() throws {
            guard !retired else { throw ProjectError.invalid }
            try workspace?.cancellation.check(); try chain.check()
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, lstat(directory.path, &named) == 0,
                held.st_dev == identity.st_dev, held.st_ino == identity.st_ino,
                named.st_dev == held.st_dev, named.st_ino == held.st_ino,
                (named.st_mode & S_IFMT) == S_IFDIR, named.st_uid == getuid(),
                (named.st_mode & 0o777) == 0o700,
                directory.isUnaliasedFilePath else { throw ProjectError.invalid }
        }
        func validateMembers(_ entries: [Entry]) throws {
            memberLock.lock(); defer { memberLock.unlock() }
            try checkDirectory()
            guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(entries.map(\.file)) else { throw ProjectError.invalid }
            for entry in entries {
                var info = stat()
                guard fstatat(fd, entry.file, &info, AT_SYMLINK_NOFOLLOW) == 0,
                    (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                    info.st_uid == getuid(), (info.st_mode & 0o777) == 0o444,
                    info.st_size == entry.bytes else { throw ProjectError.invalid }
                if let original = identities[entry.file] {
                    guard info.st_dev == original.st_dev, info.st_ino == original.st_ino else { throw ProjectError.invalid }
                } else { identities[entry.file] = info }
            }
            try checkDirectory()
        }
        private func checked(_ descriptor: Int32, entry: Entry, mode: mode_t) throws -> stat {
            var held = stat(), named = stat()
            guard fstat(descriptor, &held) == 0, fstatat(fd, entry.file, &named, AT_SYMLINK_NOFOLLOW) == 0,
                (held.st_mode & S_IFMT) == S_IFREG, held.st_nlink == 1, held.st_uid == getuid(),
                (held.st_mode & 0o777) == mode, held.st_size == entry.bytes,
                held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                held.st_size == named.st_size, held.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec,
                held.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec else { throw ProjectError.invalid }
            if let original = identities[entry.file] {
                guard held.st_dev == original.st_dev, held.st_ino == original.st_ino,
                    held.st_size == original.st_size else { throw ProjectError.invalid }
            }
            return held
        }
        func write(_ data: Data, entry: Entry) throws {
            memberLock.lock(); defer { memberLock.unlock() }
            try checkDirectory()
            let descriptor = openat(fd, entry.file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ProjectError.invalid }
            defer { try? workspace?.captureWrittenFile(directory: directory, name: entry.file, descriptor: descriptor); close(descriptor) }
            try workspace?.registerCreatedFile(directory: directory, name: entry.file, descriptor: descriptor)
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try workspace?.cancellation.check(); try Task.checkCancellation()
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ProjectError.encode }; offset += count
                }
            }
            _ = try checked(descriptor, entry: entry, mode: 0o600)
            guard fsync(descriptor) == 0, fchmod(descriptor, 0o444) == 0, fsync(fd) == 0 else { throw ProjectError.encode }
            identities[entry.file] = try checked(descriptor, entry: entry, mode: 0o444)
            try workspace?.captureWrittenFile(directory: directory, name: entry.file, descriptor: descriptor); try checkDirectory()
        }
        func read(_ entry: Entry) throws -> Data {
            memberLock.lock(); defer { memberLock.unlock() }
            try checkDirectory()
            let descriptor = openat(fd, entry.file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProjectError.invalid }
            defer { close(descriptor) }
            let before = try checked(descriptor, entry: entry, mode: 0o444)
            var data = Data(count: entry.bytes)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try workspace?.cancellation.check(); try Task.checkCancellation()
                    let count = Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ProjectError.invalid }; offset += count
                }
                var excess: UInt8 = 0
                guard Darwin.read(descriptor, &excess, 1) == 0 else { throw ProjectError.invalid }
            }
            let after = try checked(descriptor, entry: entry, mode: 0o444)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw ProjectError.invalid }
            try checkDirectory(); return data
        }
    }
}

nonisolated extension URL {
    /// The physical path, including the /private firmlink prefix Foundation's
    /// resolvingSymlinksInPath drops. The managed decoder admits only physical originals.
    var physicalFileURL: URL? {
        guard isFileURL, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    /// An absolute path without "." or ".." components (standardizedFileURL would
    /// also drop the /private firmlink prefix, so it cannot be compared directly).
    var hasNormalizedPath: Bool {
        isFileURL && path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains { $0 == "." || $0 == ".." || $0.isEmpty }
    }
    /// No symbolic link anywhere in the path, other than the system /private
    /// firmlink prefix (Foundation reports /var and /tmp without it). A missing
    /// leaf is judged by its deepest existing ancestor.
    var isUnaliasedFilePath: Bool {
        guard isFileURL, path.hasPrefix("/") else { return false }
        var existing = self, suffix: [String] = []
        var physical = existing.physicalFileURL
        while physical == nil {
            guard errno == ENOENT, existing.path != "/" else { return false }
            suffix.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent()
            physical = existing.physicalFileURL
        }
        guard let physical else { return false }
        let resolved = ([physical.path == "/" ? "" : physical.path] + suffix).joined(separator: "/")
        return resolved == path || resolved == "/private" + path
    }
}

/// Held real parent chain. Renaming a parent or substituting a link is detected,
/// rather than trusting string canonicalization alone after the directory was opened.
nonisolated final class LWFloatDirectoryChain: @unchecked Sendable {
    private let descriptors: [Int32]
    private let identities: [stat]
    private let names: [String]
    var fd: Int32 { descriptors.last! }
    init(_ url: URL) throws {
        guard url.isFileURL, url.path.utf8.count < Int(PATH_MAX), url.path.hasPrefix("/"),
            url.hasNormalizedPath, url.isUnaliasedFilePath,
            let physical = realpath(url.path, nil) else { throw ProjectError.invalid }
        let physicalPath = String(cString: physical); free(physical)
        // Foundation reports /var, /tmp and /etc without their /private firmlink
        // prefix. Only that system prefix may differ; any other link is refused.
        guard physicalPath == url.path || physicalPath == "/private" + url.path else { throw ProjectError.invalid }
        let names = physicalPath.split(separator: "/").map(String.init)
        var descriptors: [Int32] = [], identities: [stat] = []
        do {
            let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ProjectError.invalid }; descriptors.append(root)
            var rootInfo = stat(); guard fstat(root, &rootInfo) == 0 else { throw ProjectError.invalid }; identities.append(rootInfo)
            for name in names {
                let next = openat(descriptors.last!, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ProjectError.invalid }; descriptors.append(next)
                var info = stat(); guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
                identities.append(info)
            }
            self.descriptors = descriptors; self.identities = identities; self.names = names
            try check()
        } catch { for descriptor in descriptors { close(descriptor) }; throw error }
    }
    deinit { for descriptor in descriptors { close(descriptor) } }
    /// Absence can release this recorded path only if the original held leaf is
    /// actually unlinked and every named parent is unchanged. Renames/replacements
    /// remain uncertainty; no name found by enumeration becomes owned.
    func isUnlinkedLeaf() throws -> Bool {
        guard descriptors.count > 1 else { return false }
        for index in descriptors.indices.dropLast() {
            var held = stat()
            guard fstat(descriptors[index], &held) == 0, held.st_dev == identities[index].st_dev,
                held.st_ino == identities[index].st_ino, (held.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
            if index > 0 {
                var named = stat()
                guard fstatat(descriptors[index - 1], names[index - 1], &named, AT_SYMLINK_NOFOLLOW) == 0,
                    named.st_dev == held.st_dev, named.st_ino == held.st_ino, (named.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
            }
        }
        var held = stat()
        guard fstat(fd, &held) == 0, held.st_dev == identities.last!.st_dev,
            held.st_ino == identities.last!.st_ino, (held.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
        var named = stat(); errno = 0
        if fstatat(descriptors[descriptors.count - 2], names.last!, &named, AT_SYMLINK_NOFOLLOW) == 0 {
            guard held.st_nlink != 0 else { throw ProjectError.invalid }
            return false
        }
        guard errno == ENOENT else { throw ProjectError.invalid }
        return try Self.heldDirectoryIsDeleted(fd, linkCount: held.st_nlink)
    }
    /// APFS keeps a removed directory's link count on its held descriptor, so ask
    /// the held inode itself: a deleted directory refuses new entries with ENOENT,
    /// while one merely renamed elsewhere stays uncertain (false).
    static func heldDirectoryIsDeleted(_ fd: Int32, linkCount: nlink_t) throws -> Bool {
        if linkCount == 0 { return true }
        let probe = ".lw-unlink-probe-" + UUID().uuidString.lowercased()
        if mkdirat(fd, probe, 0o700) == 0 {
            guard unlinkat(fd, probe, AT_REMOVEDIR) == 0 else { throw ProjectError.invalid }
            return false
        }
        guard errno == ENOENT else { throw ProjectError.invalid }
        return true
    }

    func check() throws {
        for index in descriptors.indices {
            var held = stat()
            guard fstat(descriptors[index], &held) == 0, held.st_dev == identities[index].st_dev,
                held.st_ino == identities[index].st_ino, (held.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
            if index > 0 {
                var named = stat()
                guard fstatat(descriptors[index - 1], names[index - 1], &named, AT_SYMLINK_NOFOLLOW) == 0,
                    (named.st_mode & S_IFMT) == S_IFDIR, named.st_dev == held.st_dev, named.st_ino == held.st_ino else { throw ProjectError.invalid }
            }
        }
    }
}
