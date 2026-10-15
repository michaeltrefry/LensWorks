import Foundation
import SQLite3
import Darwin

nonisolated struct LensWorksVersionPage: Sendable {
    var versions: [LensWorksWorkingVersion]
    var next: String?
    var errors: [String]
}
nonisolated struct LensWorksVersionDiscovery: Sendable {
    var scanned: Int
    var hasMore: Bool
    var errors: [String]
}
nonisolated struct LensWorksSelectedRow: Sendable {
    let imageID: String
    let key: LWCatalogEditsVariantKey
}
/// One photo's recorded organization change: the encoded forward edit and its exact
/// inverse. Recorded before the write is sent, so a committed change is never unrecorded.
nonisolated struct LensWorksOrganizationRecord: Sendable {
    let row: LensWorksSelectedRow
    let forward: Data
    let inverse: Data
}
/// One recorded keyword-dictionary edit of a step, replayed before (phase 0) or
/// after (phase 1) the step's photo records.
nonisolated struct LensWorksDictionaryRecord: Sendable {
    let ordinal: Int64
    let phase: Int32
    let forward: Data
    let inverse: Data
}

/// Rebuildable LensWorks metadata only. Native package records remain the version authority.
/// Selection is disk-backed TEMP storage; neither browse nor save materializes the global registry.
actor LensWorksCatalogIndex {
    static let shared = LensWorksCatalogIndex()
    /// Where the shared index lives: in LensWorks's Application Support folder (a throwaway one under XCTest).
    nonisolated static var sharedLocation: URL { LensWorksUserState.applicationSupport.appendingPathComponent("CatalogIndex.sqlite3") }
    private let suppliedURL: URL?
    private var database: OpaquePointer?
    private var enumerator: FileManager.DirectoryEnumerator?
    private var enumeratedDirectory: String?
    private var attemptedMigration = false
    private var rangeLeases: [String: UUID] = [:]
    private var rangeQueries: [String: String] = [:]
    private var activeQueries: Set<String> = []
    static let maximumLogicalRows: Int64 = 10_000_000
    static let maximumIdentityBytes = 4096
    private func validate(_ rows: [LensWorksSelectedRow]) throws {
        guard rows.allSatisfy({ !$0.imageID.isEmpty && !$0.key.asset_id.isEmpty && !$0.key.variant_id.isEmpty && $0.imageID.utf8.count + $0.key.asset_id.utf8.count + $0.key.variant_id.utf8.count <= Self.maximumIdentityBytes }) else { throw LensWorksManagedError.resourceLimit("Selection identity byte allowance.") }
        try Task.checkCancellation()
    }
    private func ownedCount(_ table: String, owner: String) throws -> Int64 {
        try statement("SELECT COALESCE((SELECT count FROM owner_counts WHERE kind='" + table + "' AND owner=?),0)", strings: [owner]) { prepared in
            guard sqlite3_step(prepared) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(prepared, 0)
        }
    }
    private func admitOwner(_ kind: String, owner: String) throws {
        let available = try statement("SELECT (EXISTS(SELECT 1 FROM owner_counts WHERE kind=? AND owner=?)) OR (SELECT COUNT(*) FROM owner_counts WHERE kind=?)<4", strings: [kind, owner, kind]) { prepared in
            guard sqlite3_step(prepared) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int(prepared, 0) != 0
        }
        guard available else { throw LensWorksManagedError.resourceLimit("Disk selection owner allowance. Retire the previous browse scope before admitting another.") }
    }
    private let applicationID: Int32 = 0x4c575652
    init(url: URL? = nil) { suppliedURL = url }
    deinit { if let database { sqlite3_close_v2(database) } }
    private func failure() -> LensWorksCatalogError {
        .message(database.map { String(cString: sqlite3_errmsg($0)) } ?? "The LensWorks metadata index could not be opened.")
    }
    /// Inspect the original spelling before Foundation can collapse a redirected ancestor.
    private func admitParent(_ parent: URL) throws {
        var prefix = ""
        for component in parent.path.split(separator: "/") {
            try Task.checkCancellation()
            prefix += "/" + component
            var info = stat()
            let result = prefix.withCString { Darwin.lstat($0, &info) }
            if result != 0 {
                guard errno == ENOENT else { throw LensWorksCatalogError.message("The metadata index parent could not be inspected.") }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw LensWorksCatalogError.message("The LensWorks metadata index parent is redirected or is not a directory.") }
        }
    }
    private func open() throws {
        guard database == nil else { return }
        let url: URL
        if let suppliedURL { url = suppliedURL }
        else {
            url = Self.sharedLocation
        }
        let parent = url.deletingLastPathComponent()
        try admitParent(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try admitParent(parent)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            var stat = stat()
            if path.withCString({ Darwin.lstat($0, &stat) }) == 0 {
                guard stat.st_mode & S_IFMT == S_IFREG, stat.st_nlink == 1 else { throw LensWorksCatalogError.message("The LensWorks metadata index path is redirected or linked.") }
                if suffix.isEmpty {
                    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
                    let bytes = try file.read(upToCount: 100) ?? Data()
                    let id = bytes.count >= 72 ? bytes[68..<72].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } : 0
                    guard bytes.prefix(16) == Data("SQLite format 3\0".utf8), id == UInt32(applicationID) else { throw LensWorksCatalogError.message("The existing file is not a LensWorks version index. It was left unchanged.") }
                }
            } else { guard errno == ENOENT else { throw LensWorksCatalogError.message("The LensWorks metadata index path could not be inspected.") } }
        }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let pointer { sqlite3_close_v2(pointer) }; throw failure()
        }
        database = pointer
        do {
            sqlite3_busy_timeout(pointer, 3000)
            sqlite3_progress_handler(pointer, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            try execute("PRAGMA application_id=\(applicationID); PRAGMA journal_mode=WAL; PRAGMA temp_store=FILE; CREATE TABLE IF NOT EXISTS versions(path TEXT PRIMARY KEY,catalog TEXT NOT NULL,photo TEXT NOT NULL,variant TEXT NOT NULL,uuid TEXT NOT NULL,payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS source_versions ON versions(catalog,photo,variant,path); CREATE TABLE IF NOT EXISTS recipe_origins(catalog TEXT NOT NULL,asset TEXT NOT NULL,variant TEXT NOT NULL,revision INTEGER NOT NULL,digest TEXT NOT NULL,undo TEXT NOT NULL,redo TEXT NOT NULL,PRIMARY KEY(catalog,asset,variant)); CREATE TEMP TABLE selection(owner TEXT NOT NULL,image TEXT NOT NULL,asset TEXT NOT NULL,variant TEXT NOT NULL,PRIMARY KEY(owner,image)); CREATE TEMP TABLE visits(owner TEXT NOT NULL,image TEXT NOT NULL,asset TEXT NOT NULL,variant TEXT NOT NULL,ordinal INTEGER NOT NULL,PRIMARY KEY(owner,image)); CREATE INDEX visits_order ON visits(owner,ordinal); CREATE TEMP TABLE organization_history(step INTEGER NOT NULL,image TEXT NOT NULL,asset TEXT NOT NULL,variant TEXT NOT NULL,forward BLOB NOT NULL,inverse BLOB NOT NULL,PRIMARY KEY(step,image)); CREATE TEMP TABLE organization_dictionary(step INTEGER NOT NULL,phase INTEGER NOT NULL,ordinal INTEGER NOT NULL,forward BLOB NOT NULL,inverse BLOB NOT NULL,PRIMARY KEY(step,phase,ordinal)); CREATE TEMP TABLE owner_counts(kind TEXT NOT NULL,owner TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(kind,owner)); CREATE TEMP TRIGGER selection_add AFTER INSERT ON selection BEGIN INSERT INTO owner_counts VALUES('selection',NEW.owner,1) ON CONFLICT(kind,owner) DO UPDATE SET count=count+1; END; CREATE TEMP TRIGGER selection_remove AFTER DELETE ON selection BEGIN UPDATE owner_counts SET count=count-1 WHERE kind='selection' AND owner=OLD.owner; DELETE FROM owner_counts WHERE kind='selection' AND owner=OLD.owner AND count=0; END; CREATE TEMP TRIGGER visits_add AFTER INSERT ON visits BEGIN INSERT INTO owner_counts VALUES('visits',NEW.owner,1) ON CONFLICT(kind,owner) DO UPDATE SET count=count+1; END; CREATE TEMP TRIGGER visits_remove AFTER DELETE ON visits BEGIN UPDATE owner_counts SET count=count-1 WHERE kind='visits' AND owner=OLD.owner; DELETE FROM owner_counts WHERE kind='visits' AND owner=OLD.owner AND count=0; END;")
        } catch { sqlite3_close_v2(pointer); database = nil; throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement<Result>(_ sql: String, strings: [String] = [], body: (OpaquePointer) throws -> Result) throws -> Result {
        try open()
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in strings.enumerated() {
            guard !value.utf8.contains(0) else { throw LensWorksManagedError.protocolViolation("Catalog identity contains a NUL byte.") }
            guard value.withCString({ sqlite3_bind_text(pointer, Int32(index + 1), $0, -1, transient) }) == SQLITE_OK else { throw failure() }
        }
        return try body(pointer)
    }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
    @discardableResult func register(_ project: URL) throws -> Bool {
        try Task.checkCancellation()
        guard let record = try LensWorksWorkingVersion.read(from: project) else { return false }
        let canonical = project.resolvingSymlinksInPath().standardizedFileURL.path
        let bytes = try record.encoded()
        try statement("INSERT INTO versions(path,catalog,photo,variant,uuid,payload) VALUES(?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET catalog=excluded.catalog,photo=excluded.photo,variant=excluded.variant,uuid=excluded.uuid,payload=excluded.payload", strings: [canonical, URL(fileURLWithPath: record.catalogPath).resolvingSymlinksInPath().standardizedFileURL.path, record.photoID, record.sourceVariantID, record.id.uuidString]) { prepared in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bound = bytes.withUnsafeBytes { sqlite3_bind_blob(prepared, 6, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK, sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
        }
        return true
    }
    /// Forgets a working version whose package is gone (deleted or moved to the Trash). The package is the
    /// authority: this only stops the index listing it.
    func remove(_ project: URL) throws {
        let canonical = project.resolvingSymlinksInPath().standardizedFileURL.path
        try statement("DELETE FROM versions WHERE path=? OR path=?", strings: [canonical, project.path]) { prepared in
            guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
        }
    }
    /// The deprecated defaults array is admitted once, on this background actor. Failed records remain
    /// in defaults for explicit reconciliation; no path is truncated or silently discarded.
    func migrateLegacyDefaults(defaults: UserDefaults, retry: Bool = false) -> [String] {
        guard retry || !attemptedMigration else { return [] }
        attemptedMigration = true
        let paths = defaults.stringArray(forKey: "LensWorks.workingVersions") ?? []
        var errors: [String] = []
        var failures = 0
        for path in paths {
            if Task.isCancelled { errors.append("Legacy reconciliation was canceled. The complete original ledger remains retained."); return errors }
            do { guard try register(URL(fileURLWithPath: path)) else { throw LensWorksCatalogError.message("This project has no LensWorks source record; its legacy registration remains unresolved.") } }
            catch { failures += 1; if errors.count < 10 { errors.append(path + ": " + error.localizedDescription) } }
        }
        if failures == 0 { defaults.removeObject(forKey: "LensWorks.workingVersions") }
        else { errors.append("\(failures) legacy registrations still need reconciliation; the original ledger has been retained.") }
        return errors
    }
    func versions(catalog: String, photo: String, variant: String, after: String? = nil) throws -> LensWorksVersionPage {
        var rows: [LensWorksWorkingVersion] = [], errors: [String] = [], next: String?
        try statement("SELECT path FROM versions WHERE catalog=? AND photo=? AND variant=? AND path>? ORDER BY path LIMIT 101", strings: [catalog, photo, variant, after ?? ""]) { prepared in
            var observed = 0
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(prepared)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw failure() }
                let path = text(prepared, 0)
                observed += 1
                if observed == 101 { next = next ?? path; break }
                next = path
                do {
                    guard let version = try LensWorksWorkingVersion.read(from: URL(fileURLWithPath: path)), URL(fileURLWithPath: version.catalogPath).resolvingSymlinksInPath().standardizedFileURL.path == catalog, version.photoID == photo, version.sourceVariantID == variant else {
                        throw LensWorksCatalogError.message("Indexed source identity no longer matches this working version.")
                    }
                    rows.append(version)
                } catch { if errors.count < 10 { errors.append(path + ": " + error.localizedDescription) } }
            }
            if observed <= 100 { next = nil }
        }
        return LensWorksVersionPage(versions: rows, next: next, errors: errors)
    }
    func discover(_ directory: String, restart: Bool = false) throws -> LensWorksVersionDiscovery {
        if restart || enumeratedDirectory != directory {
            enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            guard enumerator != nil else { throw LensWorksCatalogError.message("The working-version folder could not be enumerated. Reconnect its location and reconcile again.") }
            enumeratedDirectory = directory
        }
        guard let enumerator else { return LensWorksVersionDiscovery(scanned: 0, hasMore: false, errors: []) }
        var scanned = 0, errors: [String] = []
        while scanned < 500 {
            try Task.checkCancellation()
            guard let entry = enumerator.nextObject() as? URL else {
                self.enumerator = nil
                return LensWorksVersionDiscovery(scanned: scanned, hasMore: false, errors: errors)
            }
            scanned += 1
            if entry.pathExtension == "comp" {
                do { try register(entry) } catch { if errors.count < 10 { errors.append(entry.path + ": " + error.localizedDescription) } }
            }
        }
        return LensWorksVersionDiscovery(scanned: scanned, hasMore: true, errors: errors)
    }
    func beginVisits(owner: String) throws {
        try Task.checkCancellation()
        guard activeQueries.contains(owner) || activeQueries.count < 4 else { throw LensWorksManagedError.resourceLimit("Browse-query owner allowance.") }
        activeQueries.insert(owner)
    }
    func rememberPage(owner: String, page: Int64, rows: [LensWorksSelectedRow]) throws {
        guard activeQueries.contains(owner) else { throw CancellationError() }
        guard rows.count <= 100, page >= 0, page <= Int64.max / 100 else { throw LensWorksManagedError.resourceLimit("Visited selection page allowance.") }
        try validate(rows)
        try admitOwner("visits", owner: owner)
        try open(); try execute("BEGIN IMMEDIATE")
        do {
            for (index, row) in rows.enumerated() {
                try statement("INSERT INTO visits(owner,image,asset,variant,ordinal) VALUES(?,?,?,?,?) ON CONFLICT(owner,image) DO UPDATE SET ordinal=excluded.ordinal", strings: [owner, row.imageID, row.key.asset_id, row.key.variant_id]) { prepared in
                    sqlite3_bind_int64(prepared, 5, page * 100 + Int64(index))
                    guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
                }
            }
            guard try ownedCount("visits", owner: owner) <= Self.maximumLogicalRows else { throw LensWorksManagedError.resourceLimit("Logical-row authority exceeds ten million.") }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func clearVisits(owner: String) throws {
        for selection in rangeQueries.filter({ $0.value == owner }).map(\.key) { rangeLeases[selection] = nil; rangeQueries[selection] = nil }
        let admitted = activeQueries.remove(owner) != nil
        do { try statement("DELETE FROM visits WHERE owner=?", strings: [owner]) { guard sqlite3_step($0) == SQLITE_DONE else { throw failure() } } }
        catch { if admitted { activeQueries.insert(owner) }; throw error }
    }
    /// Every batch admits at most 500 identities; a retired selection owner cannot be
    /// repopulated by a suspended range operation. Partial selection survives cancellation.
    func selectRange(owner: String, query: String, anchor: String, end: String, replacing: Bool) async throws {
        let first = try statement("SELECT ordinal FROM visits WHERE owner=? AND image=?", strings: [query, anchor]) { prepared -> Int64? in
            let step = sqlite3_step(prepared)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(prepared, 0)
        }
        let last = try statement("SELECT ordinal FROM visits WHERE owner=? AND image=?", strings: [query, end]) { prepared -> Int64? in
            let step = sqlite3_step(prepared)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(prepared, 0)
        }
        guard let first, let last else { throw LensWorksCatalogError.message("The range anchor belongs to a different browse scope. Select a new anchor.") }
        guard rangeLeases.count < 4 || rangeLeases[owner] != nil else { throw LensWorksManagedError.resourceLimit("Selection operation owner allowance.") }
        if replacing { try clearSelection(owner: owner) }
        try admitOwner("selection", owner: owner)
        let lease = UUID(); rangeLeases[owner] = lease; rangeQueries[owner] = query
        defer { if rangeLeases[owner] == lease { rangeLeases[owner] = nil; rangeQueries[owner] = nil } }
        var after = min(first, last) - 1
        let until = max(first, last)
        while true {
            try Task.checkCancellation()
            guard rangeLeases[owner] == lease else { throw CancellationError() }
            let page = try statement("SELECT image,asset,variant,ordinal FROM visits WHERE owner=? AND ordinal>? AND ordinal<=? ORDER BY ordinal LIMIT 500", strings: [query]) { prepared -> [(LensWorksSelectedRow, Int64)] in
                sqlite3_bind_int64(prepared, 2, after); sqlite3_bind_int64(prepared, 3, until)
                var rows: [(LensWorksSelectedRow, Int64)] = []
                while true {
                    let step = sqlite3_step(prepared)
                    if step == SQLITE_DONE { return rows }
                    guard step == SQLITE_ROW else { throw failure() }
                    rows.append((LensWorksSelectedRow(imageID: text(prepared, 0), key: .init(asset_id: text(prepared, 1), variant_id: text(prepared, 2))), sqlite3_column_int64(prepared, 3)))
                }
            }
            guard !page.isEmpty else { return }
            let rows = page.map { $0.0 }; try validate(rows)
            try execute("BEGIN IMMEDIATE")
            do {
                for row in rows {
                    try statement("INSERT OR IGNORE INTO selection(owner,image,asset,variant) VALUES(?,?,?,?)", strings: [owner, row.imageID, row.key.asset_id, row.key.variant_id]) { guard sqlite3_step($0) == SQLITE_DONE else { throw failure() } }
                }
                guard try ownedCount("selection", owner: owner) <= Self.maximumLogicalRows else { throw LensWorksManagedError.resourceLimit("Logical-row authority exceeds ten million.") }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            after = page.last!.1
            await Task.yield()
        }
    }
    func setSelection(owner: String, rows: [LensWorksSelectedRow], replace: Bool, remove: Bool = false) throws {
        guard rows.count <= 100 else { throw LensWorksManagedError.resourceLimit("Selection admission exceeds the current page.") }
        try validate(rows); rangeLeases[owner] = nil; rangeQueries[owner] = nil
        try admitOwner("selection", owner: owner)
        try open(); try execute("BEGIN IMMEDIATE")
        do {
            if replace { try clearSelection(owner: owner) }
            for row in rows {
                if remove {
                    try statement("DELETE FROM selection WHERE owner=? AND image=?", strings: [owner, row.imageID]) { guard sqlite3_step($0) == SQLITE_DONE else { throw failure() } }
                } else {
                    try statement("INSERT OR IGNORE INTO selection(owner,image,asset,variant) VALUES(?,?,?,?)", strings: [owner, row.imageID, row.key.asset_id, row.key.variant_id]) { guard sqlite3_step($0) == SQLITE_DONE else { throw failure() } }
                }
            }
            guard try ownedCount("selection", owner: owner) <= Self.maximumLogicalRows else { throw LensWorksManagedError.resourceLimit("Logical-row authority exceeds ten million.") }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func clearSelection(owner: String) throws {
        rangeLeases[owner] = nil; rangeQueries[owner] = nil
        try statement("DELETE FROM selection WHERE owner=?", strings: [owner]) { guard sqlite3_step($0) == SQLITE_DONE else { throw failure() } }
    }
    func selection(owner: String, after: String = "") throws -> [LensWorksSelectedRow] {
        try statement("SELECT image,asset,variant FROM selection WHERE owner=? AND image>? ORDER BY image LIMIT 100", strings: [owner, after]) { prepared in
            var rows: [LensWorksSelectedRow] = []
            while true {
                let step = sqlite3_step(prepared)
                if step == SQLITE_DONE { return rows }
                guard step == SQLITE_ROW else { throw failure() }
                rows.append(LensWorksSelectedRow(imageID: text(prepared, 0), key: LWCatalogEditsVariantKey(asset_id: text(prepared, 1), variant_id: text(prepared, 2))))
            }
        }
    }
    /// Undo history is disk-backed TEMP storage written and read one bounded page at a time.
    func recordOrganization(step: Int64, records: [LensWorksOrganizationRecord]) throws {
        guard records.count <= 100 else { throw LensWorksManagedError.resourceLimit("Organization history admission exceeds one page.") }
        try validate(records.map(\.row))
        try open(); try execute("BEGIN IMMEDIATE")
        do {
            for record in records {
                try statement("INSERT OR REPLACE INTO organization_history(step,image,asset,variant,forward,inverse) VALUES(?,?,?,?,?,?)", strings: ["", record.row.imageID, record.row.key.asset_id, record.row.key.variant_id]) { prepared in
                    sqlite3_bind_int64(prepared, 1, step)
                    try bind(prepared, 5, record.forward); try bind(prepared, 6, record.inverse)
                    guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func bind(_ prepared: OpaquePointer, _ column: Int32, _ data: Data) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard data.withUnsafeBytes({ sqlite3_bind_blob(prepared, column, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32($0.count), transient) }) == SQLITE_OK else { throw failure() }
    }
    private func blob(_ prepared: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(prepared, column))
        guard count > 0, let bytes = sqlite3_column_blob(prepared, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    func organizationRecords(step: Int64, after: String = "") throws -> [LensWorksOrganizationRecord] {
        try statement("SELECT image,asset,variant,forward,inverse FROM organization_history WHERE step=? AND image>? ORDER BY image LIMIT 100", strings: ["", after]) { prepared in
            sqlite3_bind_int64(prepared, 1, step)
            var rows: [LensWorksOrganizationRecord] = []
            while true {
                let step = sqlite3_step(prepared)
                if step == SQLITE_DONE { return rows }
                guard step == SQLITE_ROW else { throw failure() }
                rows.append(LensWorksOrganizationRecord(row: LensWorksSelectedRow(imageID: text(prepared, 0), key: LWCatalogEditsVariantKey(asset_id: text(prepared, 1), variant_id: text(prepared, 2))), forward: blob(prepared, 3), inverse: blob(prepared, 4)))
            }
        }
    }
    /// Forget photos whose recorded change was not applied (for example a batch item
    /// that failed its compare-and-set), so undo never reports them.
    func forgetOrganization(step: Int64, images: [String]) throws {
        guard images.count <= 100 else { throw LensWorksManagedError.resourceLimit("Organization history admission exceeds one page.") }
        for image in images {
            try statement("DELETE FROM organization_history WHERE step=? AND image=?", strings: ["", image]) { prepared in
                sqlite3_bind_int64(prepared, 1, step)
                guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
            }
        }
    }
    func recordDictionary(step: Int64, records: [LensWorksDictionaryRecord]) throws {
        guard records.count <= 100 else { throw LensWorksManagedError.resourceLimit("Organization history admission exceeds one page.") }
        try open(); try execute("BEGIN IMMEDIATE")
        do {
            for record in records {
                try statement("INSERT OR REPLACE INTO organization_dictionary(step,phase,ordinal,forward,inverse) VALUES(?,?,?,?,?)", strings: []) { prepared in
                    sqlite3_bind_int64(prepared, 1, step); sqlite3_bind_int(prepared, 2, record.phase); sqlite3_bind_int64(prepared, 3, record.ordinal)
                    try bind(prepared, 4, record.forward); try bind(prepared, 5, record.inverse)
                    guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    /// One page of a step's dictionary records in one phase, ascending or descending by ordinal.
    func dictionaryRecords(step: Int64, phase: Int32, after: Int64?, descending: Bool) throws -> [LensWorksDictionaryRecord] {
        let sql = descending
            ? "SELECT ordinal,phase,forward,inverse FROM organization_dictionary WHERE step=? AND phase=? AND ordinal<? ORDER BY ordinal DESC LIMIT 100"
            : "SELECT ordinal,phase,forward,inverse FROM organization_dictionary WHERE step=? AND phase=? AND ordinal>? ORDER BY ordinal LIMIT 100"
        return try statement(sql, strings: []) { prepared in
            sqlite3_bind_int64(prepared, 1, step); sqlite3_bind_int(prepared, 2, phase)
            sqlite3_bind_int64(prepared, 3, after ?? (descending ? Int64.max : Int64.min))
            var rows: [LensWorksDictionaryRecord] = []
            while true {
                let step = sqlite3_step(prepared)
                if step == SQLITE_DONE { return rows }
                guard step == SQLITE_ROW else { throw failure() }
                rows.append(LensWorksDictionaryRecord(ordinal: sqlite3_column_int64(prepared, 0), phase: sqlite3_column_int(prepared, 1), forward: blob(prepared, 2), inverse: blob(prepared, 3)))
            }
        }
    }
    /// Who made the recipe changes Undo and Redo would step over for one catalog copy, as recorded when the copy
    /// stood at exactly `revision` with recipe `digest`. Nil when nothing is recorded for that state: the copy was
    /// changed by something that did not record it, so nothing is known about who made its history.
    func recipeOrigins(catalog: String, key: LWCatalogEditsVariantKey, revision: Int64, digest: String) throws -> LensWorksRecipeOrigins? {
        try statement("SELECT revision,digest,undo,redo FROM recipe_origins WHERE catalog=? AND asset=? AND variant=?", strings: [catalog, key.asset_id, key.variant_id]) { prepared in
            let step = sqlite3_step(prepared)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw failure() }
            guard sqlite3_column_int64(prepared, 0) == revision, text(prepared, 1) == digest else { return nil }
            return LensWorksRecipeOrigins(undo: text(prepared, 2), redo: text(prepared, 3))
        }
    }
    /// Records `origins` as the history of the copy at `revision` and `digest`, replacing what was recorded before.
    func setRecipeOrigins(_ origins: LensWorksRecipeOrigins, catalog: String, key: LWCatalogEditsVariantKey, revision: Int64, digest: String) throws {
        try statement("INSERT OR REPLACE INTO recipe_origins(catalog,asset,variant,digest,undo,redo,revision) VALUES(?,?,?,?,?,?,?)",
                      strings: [catalog, key.asset_id, key.variant_id, digest, origins.encodedUndo, origins.encodedRedo]) { prepared in
            sqlite3_bind_int64(prepared, 7, revision)
            guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
        }
    }
    func discardOrganization(steps: [Int64]) throws {
        for step in steps {
            for table in ["organization_history", "organization_dictionary"] {
                try statement("DELETE FROM \(table) WHERE step=?", strings: [""]) { prepared in
                    sqlite3_bind_int64(prepared, 1, step)
                    guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
                }
            }
        }
    }
    func selectionProjection(owner: String, images: [String]) throws -> (Set<String>, Int64) {
        guard images.count <= 100 else { throw LensWorksManagedError.resourceLimit("Selection projection exceeds the current page.") }
        let count = try ownedCount("selection", owner: owner)
        var selected: Set<String> = []
        for image in images {
            let exists = try statement("SELECT 1 FROM selection WHERE owner=? AND image=?", strings: [owner, image]) { prepared in
                let step = sqlite3_step(prepared)
                guard step == SQLITE_ROW || step == SQLITE_DONE else { throw failure() }
                return step == SQLITE_ROW
            }
            if exists { selected.insert(image) }
        }
        return (selected, count)
    }
}
