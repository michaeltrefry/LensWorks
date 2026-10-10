import Foundation
import Darwin
import CryptoKit

/// Graph-owned storage lifetime. Only newly created private children belong to
/// this workspace; originals, catalogs and package directories are never retired.
nonisolated final class LWFloatWorkspace: @unchecked Sendable {
    let workingSet: LWFloatWorkingSet
    let directory: URL
    private let chain: LWFloatDirectoryChain
    private let rootLease: LWFloatWorkingSet.Lease
    private let cleanupID: UUID
    private var restoredCleanup = false
    private struct CleanupRecord: @unchecked Sendable {
        let id: UUID
        let directory: URL
        let chain: LWFloatDirectoryChain
        let workingSet: LWFloatWorkingSet
        let rootLease: LWFloatWorkingSet.Lease
        let children: [String: stat]
        let members: [String: [String: Member]]
        let childLeases: [String: LWFloatWorkingSet.Lease]
        let pendingWriters: Set<String>
        let registeredHighWater: Int
    }
    private final class CreatedRoot: @unchecked Sendable {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { close(fd) }
    }
    private struct FailedCreation: @unchecked Sendable {
        let held: CreatedRoot?
        let parent: LWFloatDirectoryChain
        let name: String
        let birth: stat?
        let workingSet: LWFloatWorkingSet
        let rootLease: LWFloatWorkingSet.Lease
    }
    private final class CleanupRegistry: @unchecked Sendable {
        let lock = NSLock()
        var records: [UUID: CleanupRecord] = [:]
        var creations: [UUID: FailedCreation] = [:]
    }
    private static let cleanupRegistry = CleanupRegistry()
    private let lock = NSLock()
    private var children: [String: stat] = [:]
    private struct Member { let identity:stat;let digest:String;let metadataLease:LWFloatWorkingSet.Lease }
    private var childLeases:[String:LWFloatWorkingSet.Lease]=[:]
    private var members: [String: [String: Member]] = [:]
    private var lifetimes: [String: Set<UUID>] = [:]
    // A directory returned to a constructor remains reserved until the first
    // writer acquires its strong ChildLifetime. Failed/unclaimed construction
    // is uncertainty, never permission for cleanup.
    private var pendingWriters: Set<String> = []
    private var retired = false
    private var registeredHighWater = 0
    let cancellation = LWFloatCancellation()
    /// Observation only: includes registered pending/uncertain generations.
    /// Counts never authorize retirement or replace roster/reader custody.
    var registeredGenerationCount:Int { lock.withLock { children.count } }
    var activeGenerationCount:Int {
        lock.withLock {
            var count=0
            for name in children.keys {
                if pendingWriters.contains(name) || lifetimes[name]?.isEmpty == false { count+=1 }
            }
            return count
        }
    }
    struct GenerationIdentity: Equatable, Sendable {
        let name: String
        /// Captured registration identity, not a fresh filesystem observation.
        /// Nil identity records pending creation uncertainty without adoption.
        let device: UInt64?
        let inode: UInt64?
        let pendingWriter: Bool
        let activeLifetimeCount: Int
        let registeredMemberCount: Int
    }
    struct GenerationEntries:RandomAccessCollection,Equatable,Sendable {
        typealias Index=Int
        private final class Storage:@unchecked Sendable {
            let values:[GenerationIdentity]
            let charge:LWFloatWorkingSet.Lease
            init(values:[GenerationIdentity],charge:LWFloatWorkingSet.Lease) { self.values=values;self.charge=charge }
        }
        private let storage:Storage
        fileprivate init(values:[GenerationIdentity],charge:LWFloatWorkingSet.Lease) { storage=Storage(values:values,charge:charge) }
        var startIndex:Int { 0 }
        var endIndex:Int { storage.values.count }
        func index(after index:Int)->Int { index+1 }
        func index(before index:Int)->Int { index-1 }
        subscript(index:Int)->GenerationIdentity { storage.values[index] }
        static func ==(lhs:Self,rhs:Self)->Bool { lhs.elementsEqual(rhs) }
    }
    struct GenerationObservation: Sendable {
        let workspaceID: UUID
        let entries: GenerationEntries
        let registeredHighWater: Int
        fileprivate let charge: LWFloatWorkingSet.Lease
    }
    /// A charged read-only frontier for operation-boundary controls. It never
    /// performs discovery, grants deletion, charges disk pixels as resident, or
    /// substitutes for named/held roster checks. Observe while the actual dab's
    /// input/output/state readers remain held; final-only counts prove no bound.
    func generationObservation() throws -> GenerationObservation {
        try lock.withLock {
            let count=childLeases.count
            let bytes=try LWSourceMetadataStorage.sum(1024,
                LWSourceMetadataStorage.collectionBytes(count:count,stride:MemoryLayout<GenerationIdentity>.stride+128))
            let charge=try workingSet.reserve(bytes)
            let entries=childLeases.keys.sorted().map { name in
                let identity=children[name]
                return GenerationIdentity(name:name,
                    device:identity.map { UInt64(truncatingIfNeeded:$0.st_dev) },
                    inode:identity.map { UInt64(truncatingIfNeeded:$0.st_ino) },
                    pendingWriter:pendingWriters.contains(name),activeLifetimeCount:lifetimes[name]?.count ?? 0,
                    registeredMemberCount:members[name]?.count ?? 0)
            }
            return GenerationObservation(workspaceID:cleanupID,entries:GenerationEntries(values:entries,charge:charge),
                registeredHighWater:registeredHighWater,charge:charge)
        }
    }

    init(workingSet: LWFloatWorkingSet, afterCreated: ((URL) throws -> Void)? = nil) throws {
        // Failed cleanup is an admission hold, not an ARC success receipt. Retry
        // the exact original roster before creating another private graph root.
        try Self.retryRetainedCleanup()
        let admittedRoot = try workingSet.reserve(2048), creationID = UUID()
        rootLease = admittedRoot; cleanupID = creationID
        self.workingSet = workingSet
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let parentChain = try LWFloatDirectoryChain(parent)
        try parentChain.check()
        let name = "LensWorks-Float-" + UUID().uuidString.lowercased()
        guard mkdirat(parentChain.fd, name, 0o700) == 0 else { throw ProjectError.invalid }
        let createdDirectory = parent.appendingPathComponent(name, isDirectory: true)
        directory = createdDirectory
        var birth = stat()
        let observed = fstatat(parentChain.fd, name, &birth, AT_SYMLINK_NOFOLLOW) == 0 &&
            (birth.st_mode & S_IFMT) == S_IFDIR && birth.st_uid == getuid() && (birth.st_mode & 0o777) == 0o700
        let createdFD = openat(parentChain.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let createdRoot: CreatedRoot? = createdFD >= 0 ? CreatedRoot(createdFD) : nil
        do {
            var heldBirth = stat()
            guard observed, let createdRoot, fstat(createdRoot.fd, &heldBirth) == 0,
                heldBirth.st_dev == birth.st_dev, heldBirth.st_ino == birth.st_ino,
                heldBirth.st_mode == birth.st_mode, heldBirth.st_uid == birth.st_uid, heldBirth.st_nlink == birth.st_nlink,
                heldBirth.st_mtimespec.tv_sec == birth.st_mtimespec.tv_sec, heldBirth.st_mtimespec.tv_nsec == birth.st_mtimespec.tv_nsec,
                heldBirth.st_ctimespec.tv_sec == birth.st_ctimespec.tv_sec, heldBirth.st_ctimespec.tv_nsec == birth.st_ctimespec.tv_nsec else { throw ProjectError.invalid }
            // Reference boundary injects a real post-mkdir initialization failure;
            // normal callers do not replace any identity or cleanup policy.
            try afterCreated?(createdDirectory)
            let capturedChain = try LWFloatDirectoryChain(createdDirectory)
            chain = capturedChain
            try parentChain.check(); try capturedChain.check()
        } catch {
            let failure = FailedCreation(held: createdRoot, parent: parentChain, name: name, birth: observed ? birth : nil,
                workingSet: workingSet, rootLease: admittedRoot)
            Self.cleanupRegistry.lock.withLock { Self.cleanupRegistry.creations[creationID] = failure }
            throw error
        }
    }

    private init(restoring record: CleanupRecord) {
        cleanupID = record.id; directory = record.directory; chain = record.chain
        workingSet = record.workingSet; rootLease = record.rootLease
        children = record.children; members = record.members; childLeases = record.childLeases
        pendingWriters = record.pendingWriters; registeredHighWater = record.registeredHighWater; restoredCleanup = true
    }
    /// No discovery/adoption: a retained record is copied from this exact owner
    /// after its last child token releases. Failed retries preserve the record.
    static func retryRetainedCleanup() throws {
        try cleanupRegistry.lock.withLock {
            for id in cleanupRegistry.creations.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                try retireFailedCreation(cleanupRegistry.creations[id]!)
                cleanupRegistry.creations.removeValue(forKey: id)
            }
            for id in cleanupRegistry.records.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let owner = LWFloatWorkspace(restoring: cleanupRegistry.records[id]!)
                do {
                    try owner.retireOwnedChildren()
                    cleanupRegistry.records.removeValue(forKey: id)
                } catch {
                    cleanupRegistry.records[id] = owner.cleanupRecord()
                    throw error
                }
            }
        }
    }
    /// A failed initializer has no ARC owner. Retire only its captured root inode,
    /// with an empty roster and held/named checks; missing birth remains uncertainty.
    private static func retireFailedCreation(_ value: FailedCreation) throws {
        guard let birth = value.birth, let heldRoot = value.held else { throw ProjectError.invalid }
        try value.parent.check()
        let fd = heldRoot.fd
        var already = stat(), named = stat(); errno = 0
        guard fstat(fd, &already) == 0, already.st_dev == birth.st_dev, already.st_ino == birth.st_ino else { throw ProjectError.invalid }
        if already.st_nlink == 0 {
            guard fstatat(value.parent.fd, value.name, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ProjectError.invalid }
            try value.parent.check(); return
        }
        func checked() throws -> stat {
            try value.parent.check(); var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, fstatat(value.parent.fd, value.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                held.st_dev == birth.st_dev, held.st_ino == birth.st_ino, held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                (held.st_mode & S_IFMT) == S_IFDIR, held.st_uid == getuid(), held.st_nlink == 2,
                (held.st_mode & 0o777) == 0o700, held.st_mode == named.st_mode else { throw ProjectError.invalid }
            return held
        }
        let before = try checked(), lease = try value.workingSet.reserve(1024)
        let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0 else { throw ProjectError.invalid }
        guard let entries = fdopendir(duplicate) else { close(duplicate); throw ProjectError.invalid }
        defer { closedir(entries); withExtendedLifetime(lease) {} }
        errno = 0
        while let entry = readdir(entries) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name == "." || name == ".." else { throw ProjectError.invalid }
            errno = 0
        }
        guard errno == 0 else { throw ProjectError.invalid }
        let after = try checked()
        guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            unlinkat(value.parent.fd, value.name, AT_REMOVEDIR) == 0 else { throw ProjectError.invalid }
        var retired = stat(), named = stat(); errno = 0
        guard fstat(fd, &retired) == 0, retired.st_dev == birth.st_dev, retired.st_ino == birth.st_ino, retired.st_nlink == 0,
            fstatat(value.parent.fd, value.name, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ProjectError.invalid }
        try value.parent.check()
    }
    private func cleanupRecord() -> CleanupRecord {
        CleanupRecord(id: cleanupID, directory: directory, chain: chain, workingSet: workingSet,
            rootLease: rootLease, children: children, members: members, childLeases: childLeases,
            pendingWriters: pendingWriters, registeredHighWater: registeredHighWater)
    }

    func makeScratchDirectory() throws -> URL {
        // Factory boundary is an explicit checked retirement pass, never deinit
        // authority. Active readers/writers remain protected by their tokens.
        try retireReleasedGenerations()
        return try lock.withLock {
            guard !retired else { throw ProjectError.invalid }
            try chain.check()
            let name = UUID().uuidString.lowercased()
            let metadata=try workingSet.reserve(4096) // Child dictionaries, identity, name and pending reservation.
            guard mkdirat(chain.fd, name, 0o700) == 0 else { throw ProjectError.invalid }
            childLeases[name]=metadata;pendingWriters.insert(name)
            registeredHighWater=max(registeredHighWater,childLeases.count)
            var info = stat()
            guard fstatat(chain.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
                (info.st_mode & 0o777) == 0o700 else { throw ProjectError.invalid }
            children[name] = info; members[name] = [:]
            try chain.check()
            return directory.appendingPathComponent(name, isDirectory: true)
        }
    }

    func makeBuilder(width: Int, height: Int) throws -> LWFloatPlane.Builder {
        try LWFloatPlane.Builder(directory: makeScratchDirectory(), width: width, height: height,
            workingSet: workingSet, workspace: self)
    }
    func makeStateStore(format: LWTypedStateStore.Format, width: Int, height: Int,
        base: LWTypedStateStore.Snapshot? = nil) throws -> LWTypedStateStore {
        try LWTypedStateStore(format: format, width: width, height: height, directory: makeScratchDirectory(),
            workingSet: workingSet, base: base, workspace: self)
    }

    /// Strong lifetime tokens are retained by every storage writer and immutable
    /// reader generation. They carry no permission to adopt another directory.
    final class ChildLifetime: @unchecked Sendable {
        fileprivate let owner: LWFloatWorkspace
        fileprivate let key: String
        fileprivate let id: UUID
        private let metadataLease:LWFloatWorkingSet.Lease
        fileprivate init(owner:LWFloatWorkspace,key:String,id:UUID,metadataLease:LWFloatWorkingSet.Lease) {
            self.owner=owner;self.key=key;self.id=id;self.metadataLease=metadataLease
        }
        deinit { owner.lock.withLock { owner.lifetimes[key]?.remove(id) } }
    }
    func retainChild(_ child: URL) throws -> ChildLifetime {
        try lock.withLock {
            let key = try childKey(child), id = UUID()
            let metadata=try workingSet.reserve(512)
            lifetimes[key, default: []].insert(id)
            pendingWriters.remove(key)
            return ChildLifetime(owner:self,key:key,id:id,metadataLease:metadata)
        }
    }

    /// Registration is called immediately after the writer's exclusive create.
    /// Final capture is also called on partial-write failure while its FD is held.
    /// Enumeration never establishes ownership of an unregistered member.
    func registerCreatedFile(directory child: URL, name: String, descriptor: Int32) throws {
        try lock.withLock {
            let key = try childKey(child)
            guard members[key]?[name] == nil else { throw ProjectError.invalid }
            let observed = try observe(child: child, name: name, descriptor: descriptor)
            guard observed.identity.st_size == 0, (observed.identity.st_mode & 0o777) == 0o600 else { throw ProjectError.invalid }
            members[key]![name] = observed
        }
    }
    func captureWrittenFile(directory child: URL, name: String, descriptor: Int32) throws {
        try lock.withLock {
            let key = try childKey(child)
            guard let original = members[key]?[name] else { throw ProjectError.invalid }
            let observed = try observe(child: child, name: name, descriptor: descriptor)
            guard observed.identity.st_dev == original.identity.st_dev,
                observed.identity.st_ino == original.identity.st_ino else { throw ProjectError.invalid }
            members[key]![name] = observed
        }
    }
    /// Only a writer that has already verified and removed its exact old member
    /// can forget that generation. An unexpected replacement is never adopted.
    func forgetRemovedFile(directory child: URL, name: String) throws {
        try lock.withLock {
            let key = try childKey(child)
            guard members[key]?[name] != nil else { throw ProjectError.invalid }
            let childChain = try LWFloatDirectoryChain(child)
            var info = stat(); errno = 0
            guard fstatat(childChain.fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ProjectError.invalid }
            members[key]!.removeValue(forKey: name)
        }
    }
    private func childKey(_ child: URL) throws -> String {
        guard !retired, child.deletingLastPathComponent() == directory,
            child.standardizedFileURL == child, child.resolvingSymlinksInPath() == child,
            let expected = children[child.lastPathComponent] else { throw ProjectError.invalid }
        try chain.check()
        var info = stat()
        guard fstatat(chain.fd, child.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
            info.st_dev == expected.st_dev, info.st_ino == expected.st_ino,
            (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw ProjectError.invalid }
        return child.lastPathComponent
    }
    private func observe(child: URL, name: String, descriptor: Int32) throws -> Member {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw ProjectError.invalid }
        let childChain = try LWFloatDirectoryChain(child)
        let input = openat(childChain.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw ProjectError.invalid }; defer { close(input) }
        func identity() throws -> stat {
            var writer = stat(), held = stat(), named = stat()
            guard fstat(descriptor, &writer) == 0, fstat(input, &held) == 0,
                fstatat(childChain.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                writer.st_dev == held.st_dev, writer.st_ino == held.st_ino,
                held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                (held.st_mode & S_IFMT) == S_IFREG, held.st_uid == getuid(), held.st_nlink == 1,
                [mode_t(0o444), mode_t(0o600)].contains(held.st_mode & 0o777), held.st_size >= 0,
                held.st_size == named.st_size, held.st_mode == named.st_mode,
                held.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec, held.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec,
                held.st_ctimespec.tv_sec == named.st_ctimespec.tv_sec, held.st_ctimespec.tv_nsec == named.st_ctimespec.tv_nsec else { throw ProjectError.invalid }
            return held
        }
        let before = try identity()
        let metadata=try workingSet.reserve(MemoryLayout<Member>.stride+name.utf8.count+64+1024)
        let lease = try workingSet.reserve(1024 * 1024)
        var chunk = Data(count: 1024 * 1024), hash = SHA256(), remaining = before.st_size
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = min(remaining, off_t(chunk.count))
            let count = chunk.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, Int(requested)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProjectError.invalid }
            chunk.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: count)) }
            remaining -= off_t(count)
        }
        var extra: UInt8 = 0; guard Darwin.read(input, &extra, 1) == 0 else { throw ProjectError.invalid }
        let after = try identity()
        guard before.st_size == after.st_size, before.st_mode == after.st_mode,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ProjectError.invalid }
        try childChain.check(); withExtendedLifetime(lease) {}
        return Member(identity:after,digest:hash.finalize().map { String(format:"%02x",$0) }.joined(),metadataLease:metadata)
    }

    /// Checked generation replacement. The caller consumes its value only when
    /// no sampler/provider/history/composite shares that backing; never retire an
    /// original or a directory merely found beneath the workspace.
    @discardableResult
    func retireOwnedPlane(_ plane: inout LWFloatPlane?) throws -> Bool {
        guard var value = plane else { return true }
        // Move, rather than copy, out of the optional before the uniqueness test.
        plane = nil
        do {
            if try value.retireOwnedBacking(using: self) { return true }
            plane = value; return false
        } catch { plane = value; throw error }
    }
    func retireOwnedDirectory(_ child: URL, lifetime: ChildLifetime) throws {
        try lock.withLock {
            let key = try childKey(child)
            guard lifetime.owner === self, lifetime.key == key, lifetimes[key] == [lifetime.id],
                !pendingWriters.contains(key) else { throw ProjectError.invalid }
            try retireChildLocked(child, key: key)
        }
    }

    /// Explicit pass after fully publishing a successor and releasing its old
    /// readers. Empty lifetime sets are authority only for our exact registered
    /// children; no directory enumeration establishes ownership.
    func retireReleasedGenerations() throws {
        try lock.withLock {
            guard !retired, pendingWriters.isEmpty else { throw ProjectError.invalid }
            try chain.check()
            try checkRoster(chain:chain,expected:Set(children.keys))
            for key in children.keys.sorted() where lifetimes[key, default: []].isEmpty {
                let child = directory.appendingPathComponent(key, isDirectory: true)
                _ = try childKey(child)
                try retireChildLocked(child, key: key)
            }
        }
    }

    private func retireChildLocked(_ child: URL, key: String) throws {
            let roster = members[key]!
            let childChain = try LWFloatDirectoryChain(child)
            try checkRoster(chain:childChain,expected:Set(roster.keys))
            // Validate the full roster before the first delete.
            for (name, expected) in roster {
                let fd = openat(childChain.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ProjectError.invalid }; defer { close(fd) }
                guard Self.matches(try observe(child: child, name: name, descriptor: fd), expected) else { throw ProjectError.invalid }
            }
            for name in roster.keys.sorted() {
                let expected = roster[name]!
                let fd = openat(childChain.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ProjectError.invalid }; defer { close(fd) }
                guard Self.matches(try observe(child: child, name: name, descriptor: fd), expected) else { throw ProjectError.invalid }
                _ = try childKey(child); try childChain.check()
                guard unlinkat(childChain.fd, name, 0) == 0 else { throw ProjectError.invalid }
                var held = stat()
                guard fstat(fd, &held) == 0, held.st_dev == expected.identity.st_dev,
                    held.st_ino == expected.identity.st_ino, held.st_nlink == 0 else { throw ProjectError.invalid }
                // Record each proven deletion before a later syscall can fail.
                members[key]!.removeValue(forKey: name)
            }
            try checkRoster(chain:childChain,expected:[])
            _ = try childKey(child)
            guard unlinkat(chain.fd, key, AT_REMOVEDIR) == 0 else { throw ProjectError.invalid }
            members.removeValue(forKey:key);children.removeValue(forKey:key);lifetimes.removeValue(forKey:key);childLeases.removeValue(forKey:key)
            try chain.check()
    }

    /// Failure preserves unexpected members. This is conservative RAII retirement,
    /// not a checked Catalog Close/lifecycle receipt.
    deinit {
        guard !restoredCleanup else { return }
        do { try retireOwnedChildren() }
        catch {
            let record = cleanupRecord()
            Self.cleanupRegistry.lock.withLock { Self.cleanupRegistry.records[record.id] = record }
        }
    }
    func retireOwnedChildren() throws {
        try LWFloatPlane.withWorkspaceRetirementBarrier(self) {
        try lock.withLock {
            guard !retired else { return }
            guard lifetimes.values.allSatisfy(\.isEmpty) else { throw ProjectError.invalid }
            // External deletion is only an observation of this exact held root
            // being unlinked with an absent name. A replacement/rename is refused;
            // this gives no authority over any moved or unregistered object.
            if try chain.isUnlinkedLeaf() {
                members.removeAll(); children.removeAll(); lifetimes.removeAll(); childLeases.removeAll()
                pendingWriters.removeAll(); retired = true; return
            }
            guard pendingWriters.isEmpty else { throw ProjectError.invalid }
            try chain.check()
            try checkRoster(chain:chain,expected:Set(children.keys))
            // Validate every roster before deleting any member, including unknown
            // sentinels and replaced files in later children.
            for name in children.keys.sorted() {
                let child = directory.appendingPathComponent(name, isDirectory: true)
                _ = try childKey(child)
                let childChain = try LWFloatDirectoryChain(child)
                try checkRoster(chain:childChain,expected:Set(members[name]!.keys))
                for (member, expected) in members[name]! {
                    let fd = openat(childChain.fd, member, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw ProjectError.invalid }; defer { close(fd) }
                    let actual = try observe(child: child, name: member, descriptor: fd)
                    guard Self.matches(actual, expected) else { throw ProjectError.invalid }
                }
            }
            for name in children.keys.sorted() {
                try retireChildLocked(directory.appendingPathComponent(name, isDirectory: true), key: name)
            }
            try chain.check()
            try checkRoster(chain:chain,expected:[])
            guard rmdir(directory.path) == 0 else { throw ProjectError.invalid }
            members.removeAll();children.removeAll();lifetimes.removeAll();childLeases.removeAll()
            retired=true
        }
        }
    }
    /// Read one bounded dirent at a time and reject the first unknown name.
    /// Enumeration verifies an already registered roster; it never adopts files.
    private func checkRoster(chain:LWFloatDirectoryChain,expected:Set<String>) throws {
        try chain.check()
        let lease=try workingSet.reserve(expected.count*128+1024)
        defer { withExtendedLifetime(lease) {} }
        let descriptor=openat(chain.fd,".",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectError.invalid }
        guard let stream=fdopendir(descriptor) else { close(descriptor);throw ProjectError.invalid }
        defer { closedir(stream) }
        var seen=Set<String>()
        while true {
            errno=0
            guard let entry=readdir(stream) else { guard errno == 0 else { throw ProjectError.invalid };break }
            let capacity=MemoryLayout.size(ofValue:entry.pointee.d_name)
            let name=withUnsafePointer(to:&entry.pointee.d_name) { raw in
                raw.withMemoryRebound(to:CChar.self,capacity:capacity) { String(validatingUTF8:$0) }
            }
            guard let name else { throw ProjectError.invalid }
            if name == "." || name == ".." { continue }
            guard expected.contains(name),seen.insert(name).inserted else { throw ProjectError.invalid }
        }
        guard seen == expected else { throw ProjectError.invalid };try chain.check()
    }
    private static func matches(_ actual: Member, _ expected: Member) -> Bool {
        let a = actual.identity, b = expected.identity
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec && actual.digest == expected.digest
    }
}

/// Framework callbacks are not guaranteed to inherit the originating Task.
/// The graph's cancellation handler marks this shared token explicitly.
nonisolated final class LWFloatCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]
    func cancel() {
        let actions = lock.withLock { () -> [@Sendable () -> Void] in
            guard !cancelled else { return [] }; cancelled = true
            let values = Array(observers.values); observers.removeAll(); return values
        }
        // Framework cancellation may synchronously call a callback. Never invoke
        // it while holding the cancellation lock.
        for action in actions { action() }
    }
    func register(_ action: @escaping @Sendable () -> Void) -> Registration {
        let id = UUID(), invoke = lock.withLock { () -> Bool in
            if cancelled { return true }; observers[id] = action; return false
        }
        if invoke { action() }
        return Registration(owner: self, id: id)
    }
    private func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    final class Registration: @unchecked Sendable {
        private let owner: LWFloatCancellation
        private let id: UUID
        fileprivate init(owner: LWFloatCancellation, id: UUID) { self.owner = owner; self.id = id }
        func remove() { owner.remove(id) }
        deinit { remove() }
    }
}
