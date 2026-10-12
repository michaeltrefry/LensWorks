import Foundation
import Darwin
import CryptoKit

/// Typed global algorithm state. It is separate from color surfaces: integer Heal
/// roles and Double membrane/accumulator values are never quantized through f32 RGBA.
nonisolated final class LWTypedStateStore {
    enum Format: String, Codable, Equatable, Sendable {
        case uint32, float64, rgba32
        var stride: Int { switch self { case .uint32: 4; case .float64: 8; case .rgba32: 16 } }
    }
    enum Value: Sendable {
        case uint32(UInt32), float64(Double), rgba32(SIMD4<Float>)
    }
    struct Record: Codable, Equatable, Sendable {
        let index: Int
        let file: String
        let bytes: Int
        let sha256: String
    }
    /// An immutable same-dab input generation. Sparse missing tiles are exactly
    /// initialized zero records; a next generation shares this input without editing it.
    final class Snapshot: Sendable {
        let schema = 1
        let id: UUID
        let width: Int
        let height: Int
        let format: Format
        let capacityBytes: Int
        let records: [Record]
        var recordStride: Int { format.stride }
        let sha256: String
        fileprivate let storage: Storage
        fileprivate struct Location: Sendable { let storage: Storage; let record: Record }
        fileprivate let locations: [Int: Location]
        fileprivate let workingSet: LWFloatWorkingSet
        fileprivate let metadataLease: LWFloatWorkingSet.Lease
        fileprivate init(id: UUID, width: Int, height: Int, format: Format, records: [Record],
            storage: Storage, base: Snapshot?, workingSet: LWFloatWorkingSet, metadataLease: LWFloatWorkingSet.Lease) throws {
            self.id = id; self.width = width; self.height = height; self.format = format
            capacityBytes = width * height * format.stride; self.records = records
            self.storage = storage; self.workingSet = workingSet; self.metadataLease = metadataLease
            var merged = base?.locations ?? [:]
            for record in records { merged[record.index] = Location(storage: storage, record: record) }
            locations = merged
            struct Content: Encodable { let index: Int; let bytes: Int; let sha256: String }
            struct Header: Encodable { let schema: Int; let id: UUID; let width: Int; let height: Int; let stride: Int; let format: Format; let records: [Content] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            sha256 = Self.digest(try encoder.encode(Header(schema: 1, id: id, width: width, height: height,
                stride: format.stride, format: format, records: merged.values.map { Content(index: $0.record.index, bytes: $0.record.bytes, sha256: $0.record.sha256) }.sorted { $0.index < $1.index })))
        }
        fileprivate func locate(_ index: Int) -> (Storage, Record)? {
            guard let location = locations[index] else { return nil }
            return (location.storage, location.record)
        }
        /// Fully detached successor for a long sequence of dabs. Each admitted
        /// record is copied once; no full-extent array or inherited storage chain
        /// survives in the result. Readers of this snapshot remain valid.
        func compacted(in workspace: LWFloatWorkspace) throws -> Snapshot {
            guard workspace.workingSet === workingSet else { throw ProjectError.invalid }
            let next = try workspace.makeStateStore(format: format, width: width, height: height)
            for (index, location) in locations.sorted(by: { $0.key < $1.key }) {
                try workspace.cancellation.check()
                let lease = try workingSet.reserve(location.record.bytes * 2)
                let bytes = try location.storage.read(location.record)
                try next.adopt(bytes, index: index)
                withExtendedLifetime(lease) {}
            }
            return try next.commit()
        }
        func reader() -> Reader { Reader(snapshot: self) }
        fileprivate static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    final class Reader {
        private let snapshot: Snapshot
        private var cache: [Tile] = []
        fileprivate init(snapshot: Snapshot) { self.snapshot = snapshot }
        func read(x: Int, y: Int) throws -> Value {
            try snapshot.storage.checkCancellation()
            let (index, offset, bytes) = try LWTypedStateStore.address(x: x, y: y,
                width: snapshot.width, height: snapshot.height, stride: snapshot.format.stride)
            let tile: Tile
            if let position = cache.firstIndex(where: { $0.index == index }) {
                tile = cache.remove(at: position); cache.append(tile)
            } else {
                if cache.count == 4 { cache.removeFirst() }
                let lease = try snapshot.workingSet.reserve(bytes * 2)
                let data: Data
                if let (storage, record) = snapshot.locate(index) { data = try storage.read(record) }
                else { data = Data(count: bytes) }
                tile = Tile(index: index, data: data, lease: lease); cache.append(tile)
            }
            return try LWTypedStateStore.decode(tile.data, offset: offset, format: snapshot.format)
        }
    }
    private final class Tile {
        let index: Int
        var data: Data
        var dirty = false
        let lease: LWFloatWorkingSet.Lease
        init(index: Int, data: Data, lease: LWFloatWorkingSet.Lease) { self.index = index; self.data = data; self.lease = lease }
    }
    let width: Int
    let height: Int
    let format: Format
    let capacityBytes: Int
    private let storage: Storage
    private let base: Snapshot?
    private let workingSet: LWFloatWorkingSet
    private let metadataLease: LWFloatWorkingSet.Lease
    private var records: [Int: Record] = [:]
    private var cache: [Tile] = []
    private var sealed = false
    init(format: Format, width: Int, height: Int, directory: URL,
        workingSet: LWFloatWorkingSet, base: Snapshot? = nil, workspace: LWFloatWorkspace? = nil) throws {
        // Claim and hold the exact child before extent/working admission.
        let ownedStorage = try Storage(directory: directory, workspace: workspace)
        try LWFloatPlane.validateExtent(width: width, height: height)
        let (capacity, overflow) = (width * height).multipliedReportingOverflow(by: format.stride)
        guard !overflow, base.map({ $0.width == width && $0.height == height && $0.format == format }) ?? true else { throw ProjectError.invalid }
        let tiles = ((width + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide) * ((height + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide)
        // Both the keyed record table and the ordered published table are charged.
        let metadata = try workingSet.reserve(tiles * (MemoryLayout<Record>.stride * 3 + 384))
        self.width = width; self.height = height; self.format = format; capacityBytes = capacity
        self.workingSet = workingSet; self.base = base; metadataLease = metadata
        storage = ownedStorage
    }
    func read(x: Int, y: Int) throws -> Value {
        try storage.checkCancellation()
        guard !sealed else { throw ProjectError.invalid }
        let (index, offset, bytes) = try Self.address(x: x, y: y, width: width, height: height, stride: format.stride)
        return try Self.decode(try tile(index: index, bytes: bytes).data, offset: offset, format: format)
    }
    func write(_ value: Value, x: Int, y: Int) throws {
        try storage.checkCancellation()
        guard !sealed else { throw ProjectError.invalid }
        let (index, offset, bytes) = try Self.address(x: x, y: y, width: width, height: height, stride: format.stride)
        let tile = try tile(index: index, bytes: bytes)
        try Self.encode(value, into: &tile.data, offset: offset, format: format); tile.dirty = true
    }
    /// Commit only after the complete dab/pass. No published Snapshot can observe
    /// partial carried state, and the writer becomes unusable after this boundary.
    func commit() throws -> Snapshot {
        try storage.checkCancellation()
        guard !sealed else { throw ProjectError.invalid }
        for tile in cache { try flush(tile) }
        let ordered = records.values.sorted { $0.index < $1.index }
        try storage.validateMembers(ordered)
        let snapshot = try Snapshot(id: UUID(), width: width, height: height, format: format,
            records: ordered, storage: storage, base: base, workingSet: workingSet, metadataLease: metadataLease)
        sealed = true; cache.removeAll(); return snapshot
    }
    private func adopt(_ data: Data, index: Int) throws {
        guard !sealed, base == nil, records[index] == nil else { throw ProjectError.invalid }
        let columns = (width + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide
        let count = columns * ((height + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide)
        guard index >= 0, index < count else { throw ProjectError.invalid }
        let range = LWFloatPlane.range(index: index, width: width, height: height)
        guard data.count == range.width * range.height * format.stride else { throw ProjectError.invalid }
        let record = Record(index: index, file: "\(index)-\(UUID().uuidString.lowercased()).state",
            bytes: data.count, sha256: Snapshot.digest(data))
        try storage.write(data, record: record); records[index] = record
    }
    private func tile(index: Int, bytes: Int) throws -> Tile {
        try Task.checkCancellation()
        if let position = cache.firstIndex(where: { $0.index == index }) {
            let tile = cache.remove(at: position); cache.append(tile); return tile
        }
        if cache.count == 4 { let retired = cache.removeFirst(); try flush(retired) }
        let lease = try workingSet.reserve(bytes * 2)
        let data: Data
        if let local = records[index] { data = try storage.read(local) }
        else if let (storage, record) = base?.locate(index) { data = try storage.read(record) }
        else { data = Data(count: bytes) }
        let tile = Tile(index: index, data: data, lease: lease); cache.append(tile); return tile
    }
    private func flush(_ tile: Tile) throws {
        guard tile.dirty else { return }
        try Task.checkCancellation()
        let record = Record(index: tile.index, file: "\(tile.index)-\(UUID().uuidString.lowercased()).state",
            bytes: tile.data.count, sha256: Snapshot.digest(tile.data))
        try storage.write(tile.data, record: record)
        if let previous = records[tile.index] { try storage.remove(previous) }
        records[tile.index] = record; tile.dirty = false
    }
    private static func address(x: Int, y: Int, width: Int, height: Int, stride: Int) throws -> (Int, Int, Int) {
        try Task.checkCancellation()
        guard x >= 0, y >= 0, x < width, y < height else { throw ProjectError.invalid }
        let columns = (width + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide
        let index = y / LWFloatPlane.tileSide * columns + x / LWFloatPlane.tileSide
        let range = LWFloatPlane.range(index: index, width: width, height: height)
        return (index, ((y - range.y) * range.width + x - range.x) * stride, range.width * range.height * stride)
    }
    private static func decode(_ data: Data, offset: Int, format: Format) throws -> Value {
        guard offset >= 0, offset <= data.count - format.stride else { throw ProjectError.invalid }
        func word(_ start: Int, _ bytes: Int) -> UInt64 { (0..<bytes).reduce(0) { $0 | UInt64(data[start + $1]) << ($1 * 8) } }
        switch format {
        case .uint32: return .uint32(UInt32(word(offset, 4)))
        case .float64: return .float64(Double(bitPattern: word(offset, 8)))
        case .rgba32: return .rgba32(SIMD4((0..<4).map { Float(bitPattern: UInt32(word(offset + $0 * 4, 4))) }))
        }
    }
    private static func encode(_ value: Value, into data: inout Data, offset: Int, format: Format) throws {
        guard offset >= 0, offset <= data.count - format.stride else { throw ProjectError.invalid }
        func word(_ bits: UInt64, _ start: Int, _ bytes: Int) { for byte in 0..<bytes { data[start + byte] = UInt8(truncatingIfNeeded: bits >> (byte * 8)) } }
        switch (format, value) {
        case (.uint32, .uint32(let value)): word(UInt64(value), offset, 4)
        case (.float64, .float64(let value)):
            guard value.isFinite else { throw ProjectError.invalid }; word(value.bitPattern, offset, 8)
        case (.rgba32, .rgba32(let value)):
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite, (0...1).contains(value.w) else { throw ProjectError.invalid }
            for channel in 0..<4 { word(UInt64(value[channel].bitPattern), offset + channel * 4, 4) }
        default: throw ProjectError.invalid
        }
    }
    fileprivate final class Storage: @unchecked Sendable {
        private let workspace: LWFloatWorkspace?
        private let lifetime: LWFloatWorkspace.ChildLifetime?
        private let chain: LWFloatDirectoryChain
        private let directory: URL
        private var identities: [String: stat] = [:]
        init(directory: URL, workspace: LWFloatWorkspace? = nil) throws {
            self.workspace = workspace
            lifetime = try workspace?.retainChild(directory)
            self.directory = directory; chain = try LWFloatDirectoryChain(directory)
            var info = stat()
            guard fstat(chain.fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700,
                try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw ProjectError.invalid }
        }
        func checkCancellation() throws { try workspace?.cancellation.check(); try Task.checkCancellation() }
        private func checked(_ fd: Int32, record: Record, mode: mode_t) throws -> stat {
            try checkCancellation(); try chain.check(); var held = stat(), named = stat(), directoryInfo = stat()
            guard fstat(chain.fd, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
                (directoryInfo.st_mode & 0o777) == 0o700 else { throw ProjectError.invalid }
            guard fstat(fd, &held) == 0, fstatat(chain.fd, record.file, &named, AT_SYMLINK_NOFOLLOW) == 0,
                (held.st_mode & S_IFMT) == S_IFREG, held.st_nlink == 1, held.st_uid == getuid(),
                (held.st_mode & 0o777) == mode, held.st_size == record.bytes,
                held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_size == named.st_size,
                held.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec, held.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec else { throw ProjectError.invalid }
            if let original = identities[record.file] {
                guard held.st_dev == original.st_dev, held.st_ino == original.st_ino,
                    held.st_size == original.st_size else { throw ProjectError.invalid }
            }
            return held
        }
        func read(_ record: Record) throws -> Data {
            try checkCancellation(); try chain.check()
            let fd = openat(chain.fd, record.file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ProjectError.invalid }; defer { close(fd) }
            let before = try checked(fd, record: record, mode: 0o444)
            var data = Data(count: record.bytes)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try checkCancellation()
                    let count = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw ProjectError.invalid }; offset += count
                }
                var extra: UInt8 = 0; guard Darwin.read(fd, &extra, 1) == 0 else { throw ProjectError.invalid }
            }
            let after = try checked(fd, record: record, mode: 0o444)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                Snapshot.digest(data) == record.sha256 else { throw ProjectError.invalid }
            return data
        }
        func write(_ data: Data, record: Record) throws {
            try checkCancellation(); try chain.check()
            let fd = openat(chain.fd, record.file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProjectError.invalid }
            defer { try? workspace?.captureWrittenFile(directory: directory, name: record.file, descriptor: fd); close(fd) }
            try workspace?.registerCreatedFile(directory: directory, name: record.file, descriptor: fd)
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try checkCancellation()
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw ProjectError.encode }; offset += count
                }
            }
            _ = try checked(fd, record: record, mode: 0o600)
            guard fsync(fd) == 0, fchmod(fd, 0o444) == 0, fsync(chain.fd) == 0 else { throw ProjectError.encode }
            identities[record.file] = try checked(fd, record: record, mode: 0o444)
            try workspace?.captureWrittenFile(directory: directory, name: record.file, descriptor: fd)
        }
        func remove(_ record: Record) throws {
            // Verify the whole held old generation before unlinking only our admitted member.
            let descriptor = openat(chain.fd, record.file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProjectError.invalid }; defer { close(descriptor) }
            let before = try checked(descriptor, record: record, mode: 0o444)
            _ = try read(record)
            let current = try checked(descriptor, record: record, mode: 0o444)
            guard before.st_dev == current.st_dev, before.st_ino == current.st_ino,
                before.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec,
                before.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec else { throw ProjectError.invalid }
            guard unlinkat(chain.fd, record.file, 0) == 0, fsync(chain.fd) == 0 else { throw ProjectError.invalid }
            var after = stat()
            guard fstat(descriptor, &after) == 0, after.st_dev == before.st_dev,
                after.st_ino == before.st_ino, after.st_nlink == 0 else { throw ProjectError.invalid }
            try workspace?.forgetRemovedFile(directory: directory, name: record.file)
            identities.removeValue(forKey: record.file)
            try chain.check()
        }
        func validateMembers(_ records: [Record]) throws {
            try chain.check()
            guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(records.map(\.file)) else { throw ProjectError.invalid }
            try chain.check()
        }
    }
}
