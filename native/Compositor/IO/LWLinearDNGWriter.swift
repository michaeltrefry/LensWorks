import Foundation
import CoreGraphics
import Darwin

/// A failed rollback never hides or deletes uncertain media. Callers surface
/// these paths through the normal operation error, including cancellation paths.
nonisolated struct LWLinearMediaRecoveryError: LocalizedError, Sendable {
    static let accessNotice = "Informational metadata only. No filesystem access is granted; owner recovery or an explicit folder grant is required."
    let reason: String
    let recoveryPaths: [URL]
    var errorDescription: String? {
        reason + " Preserved media/recovery location: " + recoveryPaths.map(\.path).joined(separator: "; ") + " " + Self.accessNotice
    }
}

#if DEBUG
/// Per-operation fault injection after the real atomic quarantine. No validation
/// is disabled; the fixture mutates only its own files to force recovery paths.
nonisolated enum LWLinearMediaCleanupTestSeam {
    @TaskLocal static var afterQuarantine: (@Sendable (URL, URL) -> Void)?
}
#endif

/// A physical, descriptor-pinned media child under the admitted output root.
/// Shared by HDR and panorama; publication never replaces an existing file.
nonisolated final class LWLinearMediaDestination: @unchecked Sendable {
    let directory: URL
    var descriptor: Int32 { directoryOwner.value }
    private var parent: Int32 { parentOwner.value }
    private let parentOwner: Descriptor
    private let directoryOwner: Descriptor
    private let root: URL
    private let subdirectory: String
    private let chain: LWFloatDirectoryChain
    private let lock = NSLock()
    private var publications: [String: Publication] = [:]
    private final class Descriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { Darwin.close(value) }
    }
    private final class Publication {
        let descriptor: Int32
        let identity: stat
        init(descriptor: Int32, identity: stat) { self.descriptor = descriptor; self.identity = identity }
        deinit { Darwin.close(descriptor) }
    }
    init(output: URL, subdirectory: String) throws {
        guard output.isFileURL, !subdirectory.isEmpty, !subdirectory.contains("/"), !subdirectory.contains("\0"), !subdirectory.contains("\\"), subdirectory != ".", subdirectory != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        self.subdirectory = subdirectory; root = output
        chain = try LWFloatDirectoryChain(output)
        try Self.validateMediaPath(output)
        let parent = fcntl(chain.fd, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        parentOwner = Descriptor(parent)
        if mkdirat(parent, subdirectory, 0o755) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        let child = openat(parent, subdirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "The media output must be a real folder, not a symbolic link."]) }
        directoryOwner = Descriptor(child); directory = output.appendingPathComponent(subdirectory, isDirectory: true)
        try validate()
    }

    /// Media is never placed within any catalog's database/preview tree. Marker
    /// inspection reads metadata only; no catalog contents are opened here.
    fileprivate static func validateMediaPath(_ output: URL) throws {
        var path = output
        while true {
            var info = stat()
            let marker = path.appendingPathComponent("catalog.sqlite3").path
            errno = 0
            if marker.withCString({ lstat($0, &info) }) == 0 {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "Choose a media folder outside catalog database and preview storage."])
            }
            guard errno == ENOENT || errno == ENOTDIR else { throw CocoaError(.fileWriteInvalidFileName) }
            if path.path == "/" { break }
            path.deleteLastPathComponent()
        }
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size && a.st_nlink == b.st_nlink &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func location(_ descriptor: Int32, fallback: URL) -> URL {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        return result == 0 ? URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) : fallback
    }
    private static func recovery(_ reason: String, owned: Int32, publicURL: URL, additional: [URL] = []) -> LWLinearMediaRecoveryError {
        var seen = Set<URL>()
        let paths = ([location(owned, fallback: publicURL)] + additional + [publicURL]).filter { seen.insert($0).inserted }
        return LWLinearMediaRecoveryError(reason: reason, recoveryPaths: paths)
    }
    /// Registration may read only the exact unchanged files this operation published.
    func validatePublication(named name: String) throws {
        guard let owned = lock.withLock({ publications[name] }) else {
            throw LWLinearMediaRecoveryError(reason: "The media file has no retained publication authority.", recoveryPaths: [directory.appendingPathComponent(name)])
        }
        do { try validate() }
        catch { throw Self.recovery("The media directory changed before registration; no substitute was accepted.", owned: owned.descriptor, publicURL: directory.appendingPathComponent(name)) }
        var held = stat(), named = stat()
        guard fstat(owned.descriptor, &held) == 0, Self.same(held, owned.identity),
              fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(held, named) else {
            throw Self.recovery("The media publication changed before registration; no substitute was accepted.",
                owned: owned.descriptor, publicURL: directory.appendingPathComponent(name))
        }
        do { try validate() }
        catch { throw Self.recovery("The media directory changed while registration authority was checked.", owned: owned.descriptor, publicURL: directory.appendingPathComponent(name)) }
    }
    fileprivate func retainPublication(named name: String, descriptor source: Int32) throws {
        var held = stat(), named = stat()
        guard fstat(source, &held) == 0, fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (held.st_mode & S_IFMT) == S_IFREG, Self.same(held, named) else { throw Self.recovery("The published file changed before its ownership could be retained.", owned: source, publicURL: directory.appendingPathComponent(name)) }
        let pinned = fcntl(source, F_DUPFD_CLOEXEC, 0)
        guard pinned >= 0 else {
            throw Self.recovery("The published file could not retain a cleanup descriptor; no rollback was attempted.", owned: source, publicURL: directory.appendingPathComponent(name))
        }
        let publication = Publication(descriptor: pinned, identity: held)
        lock.withLock { publications[name] = publication }
    }
    /// Rollback first atomically quarantines the public entry, then verifies the
    /// held publication again. A replacement raced at the public name is restored
    /// without overwrite (or preserved privately if that name was taken again).
    /// Darwin has no conditional inode unlink. The private 0700 random retirement
    /// directory closes the ordinary public-name race, not a security boundary
    /// against another same-uid process deliberately mutating that private directory.
    func removeUnimportedPublication(named name: String) throws {
        guard !name.contains("/"), !name.contains("\0"), name != ".", name != "..",
              let owned = lock.withLock({ publications[name] }) else { return }
        func failure(_ reason: String, at path: URL? = nil) -> LWLinearMediaRecoveryError {
            Self.recovery(reason, owned: owned.descriptor, publicURL: directory.appendingPathComponent(name), additional: path.map { [$0] } ?? [])
        }
        do { try validate() } catch { throw failure("The admitted media directory changed; no rollback was attempted.") }
        var before = stat(), named = stat()
        guard fstat(owned.descriptor, &before) == 0, Self.same(before, owned.identity),
              fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(before, named) else {
            throw failure("The publication was moved, replaced or edited; no rollback was attempted.")
        }
        let retirement = ".linear-retire-" + UUID().uuidString
        guard mkdirat(descriptor, retirement, 0o700) == 0 else { throw failure("A private media-retirement directory could not be made.") }
        let folder = openat(descriptor, retirement, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure("The private media-retirement directory could not be opened.") }
        defer {
            var held = stat(), path = stat()
            if fstat(folder, &held) == 0, fstatat(descriptor, retirement, &path, AT_SYMLINK_NOFOLLOW) == 0,
               held.st_dev == path.st_dev, held.st_ino == path.st_ino {
                _ = unlinkat(descriptor, retirement, AT_REMOVEDIR) // Only succeeds when empty.
            }
            Darwin.close(folder)
        }
        let moved = name.withCString { source in
            "candidate".withCString { target in renameatx_np(descriptor, source, folder, target, UInt32(RENAME_EXCL)) }
        }
        guard moved == 0 else { throw failure("The publication could not be retired atomically; no file was deleted.") }
        #if DEBUG
        LWLinearMediaCleanupTestSeam.afterQuarantine?(
            Self.location(descriptor, fallback: directory).appendingPathComponent(name),
            Self.location(folder, fallback: directory.appendingPathComponent(retirement)).appendingPathComponent("candidate"))
        #endif
        var held = stat(), candidate = stat()
        // Rename may change ctime; retain every other recorded attribute and the
        // held inode, then compare the private name with the current held file.
        let unchanged = fstat(owned.descriptor, &held) == 0 &&
            held.st_dev == before.st_dev && held.st_ino == before.st_ino && held.st_mode == before.st_mode &&
            held.st_size == before.st_size && held.st_nlink == before.st_nlink &&
            held.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && held.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
            fstatat(folder, "candidate", &candidate, AT_SYMLINK_NOFOLLOW) == 0 && Self.same(held, candidate)
        guard unchanged else {
            let restored = "candidate".withCString { source in
                name.withCString { target in renameatx_np(folder, source, descriptor, target, UInt32(RENAME_EXCL)) }
            }
            if restored != 0 {
                let retained = Self.location(folder, fallback: directory.appendingPathComponent(retirement)).appendingPathComponent("candidate")
                throw failure("A changed file was preserved privately because its public name was taken again; no sibling was overwritten.", at: retained)
            }
            throw failure("A changed file was restored without overwrite; rollback was refused.", at: directory.appendingPathComponent(name))
        }
        guard unlinkat(folder, "candidate", 0) == 0 else {
            throw failure("The owned file remains in private retirement because deletion failed.",
                at: Self.location(folder, fallback: directory.appendingPathComponent(retirement)).appendingPathComponent("candidate"))
        }
        lock.withLock { publications[name] = nil }
    }
    func validate() throws {
        try chain.check()
        var heldRoot = stat(), namedRoot = stat(), held = stat(), named = stat()
        guard fstat(parent, &heldRoot) == 0, root.path.withCString({ lstat($0, &namedRoot) }) == 0,
              fstat(descriptor, &held) == 0, fstatat(parent, subdirectory, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (namedRoot.st_mode & S_IFMT) == S_IFDIR, (named.st_mode & S_IFMT) == S_IFDIR,
              heldRoot.st_dev == namedRoot.st_dev, heldRoot.st_ino == namedRoot.st_ino,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw CocoaError(.fileWriteInvalidFileName) }
        try Self.validateMediaPath(directory)
        try chain.check()
    }
}

/// Scene-linear float32 DNG publication shared by photographic merge operations.
/// Extracted from the independently decoded/color-validated panorama writer.
nonisolated enum LWLinearDNGWriter {
    /// Uncompressed float32 LinearRaw DNG in the established filesystem media workflow.
    /// RGB is extended-linear sRGB, with explicit D50 color/forward matrices and unity neutral;
    /// no tone curve, clipping, integer quantization, camera white balance or display profile is baked in.
    /// Strips keep both encoding residency and file writes bounded, independently of output extent.
    @_optimize(speed) static func writeDNG(_ plane: LWFloatPlane, to url: URL, destination: LWLinearMediaDestination? = nil) throws {
        guard plane.width > 0, plane.height > 0,
              UInt64(plane.width) * UInt64(plane.height) * 12 + 1024 * 1024 <= UInt64(UInt32.max) else { throw ProjectError.tooLarge }
        let rowsPerStrip = min(128, plane.height), strips = (plane.height + rowsPerStrip - 1) / rowsPerStrip
        let counts = (0..<strips).map { UInt32(plane.width * min(rowsPerStrip, plane.height - $0 * rowsPerStrip) * 12) }
        var entries: [(UInt16, Value)] = [
            (254, .long([0])), (256, .long([UInt32(plane.width)])), (257, .long([UInt32(plane.height)])),
            (258, .short([32, 32, 32])), (259, .short([1])), (262, .short([34892])),
            (273, .long(Array(repeating: 0, count: strips))), (274, .short([1])), (277, .short([3])),
            (278, .long([UInt32(rowsPerStrip)])), (279, .long(counts)), (284, .short([1])),
            (339, .short([3, 3, 3])), (50706, .byte([1, 4, 0, 0])), (50707, .byte([1, 4, 0, 0])),
            (50708, .ascii("LensWorks linear sRGB")), (50713, .short([1, 1])),
            (50714, .rational([0, 0, 0])), (50717, .long([1, 1, 1])),
            (50721, .srational([3.1338561, -1.6168667, -0.4906146, -0.9787684, 1.9161415, 0.0334540, 0.0719453, -0.2289914, 1.4052427])),
            (50728, .rational([1, 1, 1])), (50778, .short([23])),
            (50964, .srational([0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733]))
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        let encoded = entries.map { encode($0.1) }
        var extraCount = 0
        for entry in encoded where entry.bytes.count > 4 { extraCount += entry.bytes.count + entry.bytes.count % 2 }
        var offset = UInt32(8 + ifdSize + extraCount), offsets: [UInt32] = []
        for count in counts { offsets.append(offset); offset += count }
        entries[entries.firstIndex(where: { $0.0 == 273 })!].1 = .long(offsets)
        var header = Data([0x49, 0x49, 42, 0]); put(UInt32(8), into: &header); put(UInt16(entries.count), into: &header)
        var extra = Data()
        for entry in entries {
            let value = encode(entry.1)
            put(entry.0, into: &header); put(value.type, into: &header); put(value.count, into: &header)
            if value.bytes.count > 4 {
                put(UInt32(8 + ifdSize + extra.count), into: &header)
                extra.append(value.bytes); if extra.count % 2 != 0 { extra.append(0) }
            } else { header.append(value.bytes); header.append(Data(repeating: 0, count: 4 - value.bytes.count)) }
        }
        put(UInt32(0), into: &header); header.append(extra)
        try publish(to: url, destination: destination) { handle in
            try handle.write(contentsOf: header)
            for strip in 0..<strips {
                try Task.checkCancellation()
                let y = strip * rowsPerStrip, rows = min(rowsPerStrip, plane.height - y)
                let charge = try plane.workingSet.reserve(plane.width * rows * 12)
                defer { withExtendedLifetime(charge) {} }
                let tile = try plane.read(.init(x: 0, y: y, width: plane.width, height: rows))
                var data = Data(count: plane.width * rows * 12)
                data.withUnsafeMutableBytes { raw in
                    for (index, pixel) in tile.surface.pixels.enumerated() { for channel in 0..<3 {
                        raw.storeBytes(of: pixel[channel].bitPattern.littleEndian, toByteOffset: index * 12 + channel * 4, as: UInt32.self)
                    } }
                }
                try handle.write(contentsOf: data)
            }
        }
    }

    static func writeData(_ data: Data, to url: URL, destination: LWLinearMediaDestination? = nil) throws {
        try publish(to: url, destination: destination) { try $0.write(contentsOf: data) }
    }

    private static func publish(to url: URL, destination: LWLinearMediaDestination?, _ body: (FileHandle) throws -> Void) throws {
        guard url.isFileURL, !url.lastPathComponent.isEmpty, !url.lastPathComponent.contains("\0"), url.lastPathComponent != ".", url.lastPathComponent != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        // Stream privately, then atomically admit the whole file with an exclusive rename.
        // No importer can see a partial .dng; an existing original is never replaced, even in a race.
        let parent: Int32
        let chain: LWFloatDirectoryChain?
        if let destination {
            try destination.validate()
            guard url.deletingLastPathComponent() == destination.directory else { throw CocoaError(.fileWriteInvalidFileName) }
            chain = nil; parent = fcntl(destination.descriptor, F_DUPFD_CLOEXEC, 0)
        } else {
            let admitted = try LWFloatDirectoryChain(url.deletingLastPathComponent())
            try LWLinearMediaDestination.validateMediaPath(url.deletingLastPathComponent())
            chain = admitted; parent = fcntl(admitted.fd, F_DUPFD_CLOEXEC, 0)
        }
        guard parent >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        defer { Darwin.close(parent) }
        let temporary = ".linear-dng-" + UUID().uuidString + ".partial"
        let descriptor = temporary.withCString { Darwin.openat(parent, $0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = temporary.withCString { Darwin.unlinkat(parent, $0, 0) } }
        try body(handle)
        try handle.synchronize(); try Task.checkCancellation()
        try destination?.validate(); try chain?.check()
        let published = temporary.withCString { source in url.lastPathComponent.withCString { target in Darwin.renameatx_np(parent, source, parent, target, UInt32(RENAME_EXCL)) } }
        guard published == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        try destination?.retainPublication(named: url.lastPathComponent, descriptor: descriptor)
    }

    private enum Value { case byte([UInt8]), ascii(String), short([UInt16]), long([UInt32]), rational([Double]), srational([Double]) }
    private static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
        var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    private static func encode(_ value: Value) -> (type: UInt16, count: UInt32, bytes: Data) {
        var data = Data()
        switch value {
        case .byte(let v): data.append(contentsOf: v); return (1, UInt32(v.count), data)
        case .ascii(let v): data.append(contentsOf: v.utf8); data.append(0); return (2, UInt32(v.utf8.count + 1), data)
        case .short(let v): for x in v { put(x, into: &data) }; return (3, UInt32(v.count), data)
        case .long(let v): for x in v { put(x, into: &data) }; return (4, UInt32(v.count), data)
        case .rational(let v): for x in v { put(UInt32((x * 1_000_000).rounded()), into: &data); put(UInt32(1_000_000), into: &data) }; return (5, UInt32(v.count), data)
        case .srational(let v): for x in v { put(Int32((x * 1_000_000).rounded()), into: &data); put(Int32(1_000_000), into: &data) }; return (10, UInt32(v.count), data)
        }
    }
}
