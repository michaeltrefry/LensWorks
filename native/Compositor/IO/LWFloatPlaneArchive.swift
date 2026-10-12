import Foundation
import Darwin
import CryptoKit

/// Exact .comp float backing. Package publication is still owned by ProjectStore;
/// this helper writes only a new private staging child, one complete tile at a time.
nonisolated enum LWFloatPlaneArchive {
    static let maximumManifestBytes = 4 * 1024 * 1024
    struct Reference: Codable, Hashable, Sendable {
        let schema: Int
        let planeID: UUID
        let width: Int
        let height: Int
        let manifestSHA256: String
        func validate() throws {
            try LWFloatPlane.validateExtent(width: width, height: height)
            guard schema == 1, manifestSHA256.count == 64,
                manifestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProjectError.invalid }
        }
    }
    static func reference(_ plane: LWFloatPlane) throws -> Reference {
        let lease = try plane.workingSet.reserve(maximumManifestBytes * 2)
        defer { withExtendedLifetime(lease) {} }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plane.manifest)
        guard data.count <= maximumManifestBytes else { throw ProjectError.tooLarge }
        return Reference(schema: 1, planeID: plane.manifest.id, width: plane.width, height: plane.height,
            manifestSHA256: digest(data))
    }
    static func write(_ plane: LWFloatPlane, to directory: URL) throws -> Reference {
        let chain = try privateDirectory(directory)
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            mkdirat(chain.fd, "tiles", 0o700) == 0 else { throw ProjectError.invalid }
        let copied = try plane.copy(directory: directory.appendingPathComponent("tiles", isDirectory: true))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let scratch = try plane.workingSet.reserve(maximumManifestBytes * 2)
        defer { withExtendedLifetime(scratch) {} }
        let data = try encoder.encode(copied.manifest)
        guard data.count <= maximumManifestBytes else { throw ProjectError.tooLarge }
        try chain.check()
        let fd = openat(chain.fd, "manifest.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProjectError.invalid }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ProjectError.invalid }
                offset += count
            }
        }
        guard fsync(fd) == 0, fchmod(fd, 0o444) == 0, fsync(chain.fd) == 0 else { throw ProjectError.invalid }
        try chain.check()
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["manifest.json", "tiles"] else { throw ProjectError.invalid }
        return Reference(schema: 1, planeID: plane.manifest.id, width: plane.width, height: plane.height,
            manifestSHA256: digest(data))
    }
    static func read(from directory: URL, reference: Reference, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try reference.validate()
        let chain = try privateDirectory(directory)
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["manifest.json", "tiles"] else { throw ProjectError.invalid }
        let fd = openat(chain.fd, "manifest.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectError.invalid }
        defer { close(fd) }
        let before = try checkedManifest(fd, chain: chain)
        let lease = try workspace.workingSet.reserve(Int(before.st_size) * 3)
        defer { withExtendedLifetime(lease) {} }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ProjectError.invalid }
                offset += count
            }
            var extra: UInt8 = 0
            guard Darwin.read(fd, &extra, 1) == 0 else { throw ProjectError.invalid }
        }
        let after = try checkedManifest(fd, chain: chain)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            digest(data) == reference.manifestSHA256 else { throw ProjectError.invalid }
        let manifest = try JSONDecoder().decode(LWFloatPlane.Manifest.self, from: data)
        guard manifest.id == reference.planeID, manifest.width == reference.width, manifest.height == reference.height else { throw ProjectError.invalid }
        let source = try LWFloatPlane.open(directory: directory.appendingPathComponent("tiles", isDirectory: true),
            manifest: manifest, workingSet: workspace.workingSet)
        // Never keep an editable package path as an immutable rendering dependency.
        // Atomic Save may replace that path; history keeps its private exact copy.
        let copied = try source.copy(directory: workspace.makeScratchDirectory(), workspace: workspace)
        try chain.check()
        let final = try checkedManifest(fd, chain: chain)
        guard final.st_size == before.st_size,
            final.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw ProjectError.invalid }
        return copied
    }
    private static func privateDirectory(_ url: URL) throws -> LWFloatDirectoryChain {
        let chain = try LWFloatDirectoryChain(url)
        var info = stat()
        guard fstat(chain.fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw ProjectError.invalid }
        return chain
    }
    private static func checkedManifest(_ fd: Int32, chain: LWFloatDirectoryChain) throws -> stat {
        try chain.check()
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, fstatat(chain.fd, "manifest.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
            (held.st_mode & S_IFMT) == S_IFREG, held.st_uid == getuid(), held.st_nlink == 1,
            (held.st_mode & 0o777) == 0o444, held.st_size > 0, held.st_size <= maximumManifestBytes,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_size == named.st_size else { throw ProjectError.invalid }
        return held
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
