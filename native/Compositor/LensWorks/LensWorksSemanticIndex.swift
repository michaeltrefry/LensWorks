import Accelerate
import CryptoKit
import Darwin
import Foundation
import SQLite3

/// One photo's embedding and the preview version its pixels came from.
nonisolated struct LensWorksSemanticEntry: Sendable, Equatable {
    let imageID: String
    let assetID: String
    let variantID: String
    let revision: Int64
    let recipeDigest: String
    let vector: [Float]
}

/// A photo the indexer still owes an embedding: never embedded, edited since, or failed (with why).
nonisolated struct LensWorksSemanticPending: Sendable, Equatable {
    let imageID: String
    let assetID: String
    let variantID: String
    var reason: String? = nil
}

/// One embedded photo's place in a ranking of the whole index: 16 bytes a photo.
nonisolated struct LensWorksSemanticRank: Sendable {
    let score: Float
    /// The photo's position in image order, which orders equal scores.
    let ordinal: UInt32
    let rowid: Int64
}

nonisolated struct LensWorksSemanticMatch: Sendable, Equatable {
    let imageID: String
    let assetID: String
    let variantID: String
    let score: Float
}

/// What opening the index found, so the caller can say why it is indexing again.
nonisolated enum LensWorksSemanticPreparation: Sendable, Equatable {
    /// The stored vectors belong to this model and are kept.
    case kept
    /// No index existed (first use, or its file was deleted).
    case created
    /// The stored vectors came from another model or layout and were discarded.
    case modelChanged
    /// The stored vectors belonged to another catalog at the same path (recreated, or restored from a backup) and were discarded.
    case catalogChanged
    /// The file was not a readable index and was replaced.
    case replacedUnreadable
}

nonisolated enum LensWorksSemanticIndexError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unavailable(String)
    case dimension(expected: Int, found: Int)
    /// The index file was unreadable mid-operation and has been replaced by an empty one.
    case recovered
    var description: String {
        switch self {
        case .unavailable(let message): "The semantic index is unavailable: \(message)"
        case .dimension(let expected, let found): "The semantic index holds \(expected)-dimension vectors; the model produced \(found)."
        case .recovered: "The semantic index was unreadable and has been replaced; indexing starts again."
        }
    }
    var errorDescription: String? { description }
}

/// The rebuildable semantic index of one catalog: unit-length image embeddings (stored as
/// half floats) keyed by catalog image, tagged with the embedding model's identity. It holds
/// nothing the catalog or the originals need: deleting it, changing the model, or interrupting
/// a rebuild only costs the time to embed previews again.
///
/// Every write is one transaction; `completeThrough` is the highest catalog sequence a finished
/// pass has covered, so an interrupted pass or rebuild simply continues.
///
/// The file is named by the catalog's path, so it is also bound to the catalog's creation stamp
/// (when one can be read): a catalog recreated or restored at the same path starts an empty index.
actor LensWorksSemanticIndex {
    static let applicationID: Int32 = 0x4c57_5349 // "LWSI"
    static let schemaVersion = 1
    /// Storage layout version: part of the identity the stored vectors are valid for.
    static let layout = "unit-f16-v1"

    nonisolated let url: URL
    /// The creation stamp of the catalog these vectors belong to; nil when it cannot be read.
    nonisolated let catalog: String?
    /// Counts every time the stored vectors were discarded (deleted file, other model, other catalog,
    /// rebuild): a pass that started before such a change must not record itself as complete.
    private(set) var generation = 0
    /// Counts every change to the stored vectors, so a ranking computed from them knows when it is out of date.
    private(set) var revision = 0
    private var database: OpaquePointer?
    private var openedInode: UInt64 = 0
    private var model: String?
    private var dimension: Int?
    private var scratch: [Float] = []

    private struct SQLiteFailure: Error { let code: Int32; let message: String }

    init(url: URL, catalog: String? = nil) { self.url = url; self.catalog = catalog }
    deinit { if let database { sqlite3_close_v2(database) } }

    /// The index file for a catalog, under `directory` (LensWorks' own Application Support
    /// folder by default), named by the catalog's canonical path.
    static func location(catalogPath: String, directory: URL? = nil) throws -> URL {
        let root = directory ?? LensWorksUserState.applicationSupport.appendingPathComponent("SemanticIndex", isDirectory: true)
        let canonical = URL(fileURLWithPath: catalogPath).resolvingSymlinksInPath().standardizedFileURL.path
        let name = SHA256.hash(data: Data(canonical.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".sqlite3")
    }

    /// When the catalog at `catalogPath` was created, as a stable stamp: the creation time of its
    /// database file (a restore replaces that file inside the same folder), or of the path itself.
    /// Nil when the volume is not local (creation times there may be synthesized from other
    /// timestamps) or it cannot be read.
    static func catalogStamp(catalogPath: String) -> String? {
        let root = URL(fileURLWithPath: catalogPath).resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true else { return nil }
        var info = stat()
        let database = root.appendingPathComponent("catalog.sqlite3").path
        guard database.withCString({ Darwin.lstat($0, &info) }) == 0 || root.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_birthtimespec.tv_sec > 0 else { return nil }
        return "born-\(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec)"
    }

    // MARK: Opening and recovery

    /// Opens the index for `model`, creating it when missing, replacing it when unreadable and
    /// discarding vectors another model or layout produced.
    @discardableResult func prepare(model: String) throws -> LensWorksSemanticPreparation {
        self.model = model
        if database != nil, inode() != openedInode { close() } // deleted or replaced underneath us
        do {
            if database != nil {
                do { return try adopt(model) }
                catch let failure as SQLiteFailure where Self.isUnreadable(failure.code) { close() }
            }
            let existed = inode() != nil
            do {
                try open()
                let adopted = try adopt(model)
                return existed ? adopted : .created
            } catch let failure as SQLiteFailure where Self.isUnreadable(failure.code) {
                try replaceUnreadable()
                _ = try adopt(model)
                return .replacedUnreadable
            }
        } catch let failure as SQLiteFailure { throw LensWorksSemanticIndexError.unavailable(failure.message) }
    }

    private static func isUnreadable(_ code: Int32) -> Bool { [SQLITE_CORRUPT, SQLITE_NOTADB].contains(code & 0xff) }

    private func inode() -> UInt64? {
        var info = stat()
        return url.path.withCString { Darwin.lstat($0, &info) } == 0 && info.st_mode & S_IFMT == S_IFREG ? UInt64(info.st_ino) : nil
    }

    private func close() {
        if let database { sqlite3_close_v2(database) }
        database = nil; dimension = nil; openedInode = 0
    }

    private func open() throws {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw LensWorksSemanticIndexError.unavailable(error.localizedDescription) }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = SQLiteFailure(code: pointer.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN,
                                        message: pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "The index file could not be opened.")
            if let pointer { sqlite3_close_v2(pointer) }
            throw failure
        }
        database = pointer
        sqlite3_busy_timeout(pointer, 3000)
        sqlite3_progress_handler(pointer, 4000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        do {
            // Reading the header fails here for a file that is not a database.
            let id = try scalar("PRAGMA application_id")
            let tables = try scalar("SELECT COUNT(*) FROM sqlite_master")
            guard id == Int64(Self.applicationID) || (id == 0 && tables == 0) else {
                throw SQLiteFailure(code: SQLITE_NOTADB, message: "The file is not a LensWorks semantic index.")
            }
            try execute("""
                PRAGMA application_id=\(Self.applicationID); PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS embeddings(image TEXT PRIMARY KEY, asset TEXT NOT NULL, variant TEXT NOT NULL,
                    revision INTEGER NOT NULL, digest TEXT NOT NULL, vector BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS pending(image TEXT PRIMARY KEY, asset TEXT NOT NULL, variant TEXT NOT NULL, reason TEXT) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS seen(image TEXT PRIMARY KEY) WITHOUT ROWID;
                """)
        } catch { close(); throw error }
        openedInode = inode() ?? 0
    }

    /// The file is LensWorks' own derived data in LensWorks' own folder: an unreadable one is removed and rebuilt.
    private func replaceUnreadable() throws {
        close()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var info = stat()
            let path = url.path + suffix
            guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { continue }
            guard info.st_mode & S_IFMT == S_IFREG else { throw LensWorksSemanticIndexError.unavailable("\(path) is not a regular file; it was left untouched.") }
            do { try FileManager.default.removeItem(atPath: path) }
            catch { throw LensWorksSemanticIndexError.unavailable(error.localizedDescription) }
        }
        do { try open() } catch let failure as SQLiteFailure { throw LensWorksSemanticIndexError.unavailable(failure.message) }
    }

    /// Makes the open database belong to `model` and this catalog. Returns what happened to its
    /// stored vectors: kept (or there were none), or discarded for another model or another catalog.
    private func adopt(_ model: String) throws -> LensWorksSemanticPreparation {
        let identity = model + "|" + Self.layout + "|schema-\(Self.schemaVersion)"
        if try meta("model") == identity {
            let bound = try meta("catalog")
            if let catalog, let bound, bound != catalog {
                try transaction {
                    try execute("DELETE FROM embeddings; DELETE FROM pending; DELETE FROM seen; DELETE FROM meta WHERE key IN ('complete_through','dimension','verified_through')")
                    try setMeta("catalog", catalog)
                }
                dimension = nil; generation += 1; revision += 1
                return .catalogChanged
            }
            // An index written before the stamp could be read is adopted; the pass still notices a foreign catalog by its sequences.
            if let catalog, bound == nil { try setMeta("catalog", catalog) }
            dimension = try meta("dimension").flatMap { Int($0) }
            return .kept
        }
        let hadContents = try scalar("SELECT EXISTS(SELECT 1 FROM embeddings) OR EXISTS(SELECT 1 FROM meta)") != 0
        try transaction {
            try execute("DELETE FROM embeddings; DELETE FROM pending; DELETE FROM seen; DELETE FROM meta")
            try setMeta("model", identity)
            if let catalog { try setMeta("catalog", catalog) }
        }
        dimension = nil; generation += 1; revision += 1
        return hadContents ? .modelChanged : .kept
    }

    /// Runs `body` against the prepared index, reopening it when its file was deleted and
    /// replacing it when SQLite reports it unreadable. `needsModel: false` is for writes that only
    /// need the open database (queueing an edited photo while the model is unavailable).
    private func run<T>(needsModel: Bool = true, _ body: () throws -> T) throws -> T {
        if let model {
            if database == nil || inode() != openedInode { try prepare(model: model) }
        } else {
            guard !needsModel else { throw LensWorksSemanticIndexError.unavailable("The index has not been prepared for a model.") }
            if database != nil, inode() != openedInode { close() }
            if database == nil {
                do { try open() }
                catch let failure as SQLiteFailure {
                    guard Self.isUnreadable(failure.code) else { throw LensWorksSemanticIndexError.unavailable(failure.message) }
                    try replaceUnreadable()
                }
            }
        }
        do { return try body() }
        catch let failure as SQLiteFailure {
            if failure.code & 0xff == SQLITE_INTERRUPT { throw CancellationError() }
            guard Self.isUnreadable(failure.code) else { throw LensWorksSemanticIndexError.unavailable(failure.message) }
            try replaceUnreadable()
            generation += 1; revision += 1
            if let model { do { _ = try adopt(model) } catch let failure as SQLiteFailure { throw LensWorksSemanticIndexError.unavailable(failure.message) } }
            throw LensWorksSemanticIndexError.recovered
        }
    }

    // MARK: SQLite plumbing

    private func failure() -> SQLiteFailure {
        SQLiteFailure(code: database.map { sqlite3_extended_errcode($0) } ?? SQLITE_CANTOPEN,
                      message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "The index is not open.")
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    private func statement<T>(_ sql: String, _ strings: [String] = [], body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        for (index, value) in strings.enumerated() {
            guard value.withCString({ sqlite3_bind_text(pointer, Int32(index + 1), $0, -1, Self.transient) }) == SQLITE_OK else { throw failure() }
        }
        return try body(pointer)
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Resets a prepared statement and binds new text values, so a loop prepares its statement once.
    private func rebind(_ prepared: OpaquePointer, _ strings: [String]) throws {
        sqlite3_reset(prepared)
        for (index, value) in strings.enumerated() {
            guard value.withCString({ sqlite3_bind_text(prepared, Int32(index + 1), $0, -1, Self.transient) }) == SQLITE_OK else { throw failure() }
        }
    }
    private func step(_ prepared: OpaquePointer) throws -> Bool {
        switch sqlite3_step(prepared) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure()
        }
    }
    private func done(_ prepared: OpaquePointer) throws { guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() } }
    private func scalar(_ sql: String, _ strings: [String] = []) throws -> Int64 {
        try statement(sql, strings) { try step($0) ? sqlite3_column_int64($0, 0) : 0 }
    }
    private func text(_ prepared: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(prepared, column).map { String(cString: $0) } ?? ""
    }
    private func meta(_ key: String) throws -> String? {
        try statement("SELECT value FROM meta WHERE key=?", [key]) { try step($0) ? text($0, 0) : nil }
    }
    private func setMeta(_ key: String, _ value: String?) throws {
        if let value { try statement("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) { try done($0) } }
        else { try statement("DELETE FROM meta WHERE key=?", [key]) { try done($0) } }
    }

    // MARK: Vectors

    private static func normalized(_ vector: [Float]) -> [Float]? {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard !vector.isEmpty, norm.isFinite, norm > 0 else { return nil }
        var unit = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &norm, &unit, 1, vDSP_Length(vector.count))
        return unit
    }

    /// Unit-length half floats; nil for a vector that is empty, not finite or zero.
    static func encode(_ vector: [Float]) -> Data? {
        guard var unit = normalized(vector) else { return nil }
        var data = Data(count: vector.count * 2)
        let converted = unit.withUnsafeMutableBytes { source in
            data.withUnsafeMutableBytes { destination -> vImage_Error in
                var input = vImage_Buffer(data: source.baseAddress, height: 1, width: vImagePixelCount(vector.count), rowBytes: source.count)
                var output = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(vector.count), rowBytes: destination.count)
                return vImageConvert_PlanarFtoPlanar16F(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        return converted == kvImageNoError ? data : nil
    }

    /// Dot product of a stored half-float vector with a unit query, through `scratch`.
    private func score(_ blob: UnsafeRawPointer, query: [Float]) -> Float {
        let count = query.count
        var result: Float = 0
        scratch.withUnsafeMutableBytes { destination in
            var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: blob), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            var output = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags))
        }
        vDSP_dotpr(scratch, 1, query, 1, &result, vDSP_Length(count))
        return result
    }

    /// The unit query, or empty when the index holds no vectors yet.
    private func unit(_ query: [Float]) throws -> [Float] {
        guard let dimension else { return [] }
        guard query.count == dimension else { throw LensWorksSemanticIndexError.dimension(expected: dimension, found: query.count) }
        guard let out = Self.normalized(query) else { throw LensWorksSemanticIndexError.unavailable("The query embedding is not a usable vector.") }
        if scratch.count != dimension { scratch = [Float](repeating: 0, count: dimension) }
        return out
    }

    // MARK: Contents

    func count() throws -> Int { try run { Int(try scalar("SELECT COUNT(*) FROM embeddings")) } }
    func pendingCount() throws -> Int { try run { Int(try scalar("SELECT COUNT(*) FROM pending")) } }
    /// Photos that could not be embedded on their last attempt, and why (first few distinct reasons).
    func failures(limit: Int = 3) throws -> (count: Int, reasons: [String]) {
        try run {
            let count = Int(try scalar("SELECT COUNT(*) FROM pending WHERE reason IS NOT NULL"))
            let reasons = try statement("SELECT DISTINCT reason FROM pending WHERE reason IS NOT NULL LIMIT ?") { prepared -> [String] in
                sqlite3_bind_int(prepared, 1, Int32(limit))
                var rows: [String] = []
                while try step(prepared) { rows.append(text(prepared, 0)) }
                return rows
            }
            return (count, reasons)
        }
    }

    /// The highest catalog sequence a finished pass covered; nil until one finishes.
    func completeThrough() throws -> Int64? { try run { try meta("complete_through").flatMap { Int64($0) } } }
    func setCompleteThrough(_ sequence: Int64?) throws { try run { try setMeta("complete_through", sequence.map { String($0) }) } }

    /// Of `images`, those with a stored embedding that is not waiting to be replaced.
    func embedded(_ images: [String]) throws -> Set<String> {
        try matching(images, "SELECT EXISTS(SELECT 1 FROM embeddings WHERE image=?1) AND NOT EXISTS(SELECT 1 FROM pending WHERE image=?1)")
    }
    /// Of `images`, those queued for (re)embedding or recorded as failed.
    func owed(_ images: [String]) throws -> Set<String> { try matching(images, "SELECT EXISTS(SELECT 1 FROM pending WHERE image=?1)") }
    /// Of `images`, those the index has heard of at all (embedded, queued or failed).
    func known(_ images: [String]) throws -> Set<String> {
        try matching(images, "SELECT EXISTS(SELECT 1 FROM embeddings WHERE image=?1) OR EXISTS(SELECT 1 FROM pending WHERE image=?1)")
    }
    /// One prepared statement, bound once per image.
    private func matching(_ images: [String], _ sql: String) throws -> Set<String> {
        guard !images.isEmpty else { return [] }
        return try run {
            try statement(sql) { prepared in
                var found = Set<String>()
                for image in images {
                    try rebind(prepared, [image])
                    if try step(prepared), sqlite3_column_int64(prepared, 0) != 0 { found.insert(image) }
                }
                return found
            }
        }
    }

    // MARK: Full scans

    /// A scan of the whole catalog starts: nothing has been seen yet.
    func beginFullScan() throws { try run { try execute("DELETE FROM seen") } }
    /// Photos a full scan found in the catalog.
    func markSeen(_ images: [String]) throws {
        guard !images.isEmpty else { return }
        try run {
            try transaction {
                try statement("INSERT OR IGNORE INTO seen(image) VALUES(?)") { prepared in
                    for image in images { try rebind(prepared, [image]); try done(prepared) }
                }
            }
        }
    }
    /// Records a finished scan that started when the index was at `generation`. A full scan also
    /// forgets every photo it did not see (the catalog no longer has them). Returns how many were
    /// forgotten. Throws `recovered` when the stored vectors were discarded while the scan ran.
    @discardableResult func finishScan(full: Bool, through sequence: Int64?, generation started: Int) throws -> Int {
        try run {
            guard generation == started else { throw LensWorksSemanticIndexError.recovered }
            var forgotten = 0
            try transaction {
                if full {
                    forgotten = Int(try scalar("SELECT COUNT(*) FROM embeddings WHERE image NOT IN (SELECT image FROM seen)"))
                    try execute("DELETE FROM embeddings WHERE image NOT IN (SELECT image FROM seen); DELETE FROM pending WHERE image NOT IN (SELECT image FROM seen); DELETE FROM seen")
                }
                try setMeta("complete_through", sequence.map { String($0) })
            }
            if forgotten > 0 { revision += 1 }
            return forgotten
        }
    }

    // MARK: Verification

    /// Up to `limit` embedded photos (not already owed) after the last one a pass verified, in image order.
    func verificationSlice(limit: Int) throws -> [LensWorksSemanticEntry] {
        try run {
            let after = try meta("verified_through") ?? ""
            return try statement("SELECT image,asset,variant,revision,digest FROM embeddings WHERE image>?1 AND image NOT IN (SELECT image FROM pending) ORDER BY image LIMIT ?2", [after]) { prepared in
                sqlite3_bind_int(prepared, 2, Int32(limit))
                var rows: [LensWorksSemanticEntry] = []
                while try step(prepared) {
                    rows.append(.init(imageID: text(prepared, 0), assetID: text(prepared, 1), variantID: text(prepared, 2),
                                      revision: sqlite3_column_int64(prepared, 3), recipeDigest: text(prepared, 4), vector: []))
                }
                return rows
            }
        }
    }
    /// Records how far verification got; nil starts again from the first photo.
    func setVerifiedThrough(_ image: String?) throws { try run { try setMeta("verified_through", image) } }

    /// Stores one batch of embeddings and settles their pending rows, atomically.
    func store(_ entries: [LensWorksSemanticEntry]) throws {
        guard let first = entries.first else { return }
        try run {
            let expected = dimension ?? first.vector.count
            var blobs: [Data] = []
            for entry in entries {
                guard entry.vector.count == expected else { throw LensWorksSemanticIndexError.dimension(expected: expected, found: entry.vector.count) }
                guard let blob = Self.encode(entry.vector) else { throw LensWorksSemanticIndexError.unavailable("The model returned an unusable embedding for \(entry.imageID).") }
                blobs.append(blob)
            }
            try transaction {
                if dimension == nil { try setMeta("dimension", String(expected)) }
                try statement("INSERT INTO embeddings(image,asset,variant,digest,revision,vector) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(image) DO UPDATE SET asset=excluded.asset,variant=excluded.variant,revision=excluded.revision,digest=excluded.digest,vector=excluded.vector") { insert in
                    try statement("DELETE FROM pending WHERE image=?") { settle in
                        for (entry, blob) in zip(entries, blobs) {
                            try rebind(insert, [entry.imageID, entry.assetID, entry.variantID, entry.recipeDigest])
                            sqlite3_bind_int64(insert, 5, entry.revision)
                            guard blob.withUnsafeBytes({ sqlite3_bind_blob(insert, 6, $0.baseAddress, Int32($0.count), Self.transient) }) == SQLITE_OK else { throw failure() }
                            try done(insert)
                            try rebind(settle, [entry.imageID]); try done(settle)
                        }
                    }
                }
            }
            dimension = expected; revision += 1
        }
    }

    /// Queues photos for (re)embedding, or records why an attempt failed. A photo whose pixels
    /// changed keeps its old vector until the new one replaces it, but is no longer reported as embedded.
    /// Needs only the index file, not a model: an edit made while the model is unavailable is still owed.
    func markPending(_ rows: [LensWorksSemanticPending]) throws {
        guard !rows.isEmpty else { return }
        try run(needsModel: false) {
            try transaction {
                try statement("INSERT INTO pending(image,asset,variant,reason) VALUES(?,?,?,?) ON CONFLICT(image) DO UPDATE SET asset=excluded.asset,variant=excluded.variant,reason=excluded.reason") { prepared in
                    for row in rows {
                        try rebind(prepared, [row.imageID, row.assetID, row.variantID])
                        if let reason = row.reason {
                            guard reason.withCString({ sqlite3_bind_text(prepared, 4, $0, -1, Self.transient) }) == SQLITE_OK else { throw failure() }
                        } else { sqlite3_bind_null(prepared, 4) }
                        try done(prepared)
                    }
                }
            }
        }
    }

    func pending(after image: String = "", limit: Int) throws -> [LensWorksSemanticPending] {
        try run {
            try statement("SELECT image,asset,variant,reason FROM pending WHERE image>? ORDER BY image LIMIT ?", [image]) { prepared in
                sqlite3_bind_int(prepared, 2, Int32(limit))
                var rows: [LensWorksSemanticPending] = []
                while try step(prepared) {
                    rows.append(.init(imageID: text(prepared, 0), assetID: text(prepared, 1), variantID: text(prepared, 2),
                                      reason: sqlite3_column_type(prepared, 3) == SQLITE_NULL ? nil : text(prepared, 3)))
                }
                return rows
            }
        }
    }

    /// Forgets photos the catalog no longer has.
    func remove(_ images: [String]) throws {
        guard !images.isEmpty else { return }
        try run {
            try transaction {
                for table in ["embeddings", "pending"] {
                    try statement("DELETE FROM \(table) WHERE image=?") { prepared in
                        for image in images { try rebind(prepared, [image]); try done(prepared) }
                    }
                }
            }
            revision += 1
        }
    }

    /// Starts a rebuild: every vector and the pass watermark go in one transaction, so a rebuild
    /// interrupted at any later point is just an unfinished pass.
    func clear() throws {
        try run {
            try transaction {
                try execute("DELETE FROM embeddings; DELETE FROM pending; DELETE FROM seen; DELETE FROM meta WHERE key IN ('complete_through','dimension','verified_through')")
            }
            dimension = nil; generation += 1; revision += 1
        }
    }

    // MARK: Queries

    /// The `limit` most similar photos, by a streaming scan that keeps only `limit` candidates.
    /// Equal scores are ordered by image id, so the same index always answers in the same order.
    func nearest(_ query: [Float], limit: Int) throws -> [LensWorksSemanticMatch] {
        try run {
            let query = try unit(query)
            guard !query.isEmpty, limit > 0 else { return [] }
            var best: [(score: Float, image: String, rowid: Int64)] = [] // worst first: ascending score, then descending image id
            try statement("SELECT rowid,vector,image FROM embeddings") { prepared in
                var scanned = 0
                while try step(prepared) {
                    scanned += 1
                    if scanned & 0x3ff == 0 { try Task.checkCancellation() }
                    guard Int(sqlite3_column_bytes(prepared, 1)) == query.count * 2, let blob = sqlite3_column_blob(prepared, 1) else { continue }
                    let value = score(blob, query: query)
                    if best.count == limit, value < best[0].score { continue }
                    let image = text(prepared, 2)
                    if best.count == limit {
                        guard value > best[0].score || image < best[0].image else { continue }
                        best.removeFirst()
                    }
                    let index = best.firstIndex { $0.score > value || ($0.score == value && $0.image < image) } ?? best.count
                    best.insert((value, image, sqlite3_column_int64(prepared, 0)), at: index)
                }
            }
            return try statement("SELECT asset,variant FROM embeddings WHERE rowid=?") { prepared in
                try best.reversed().compactMap { candidate in
                    sqlite3_reset(prepared)
                    sqlite3_bind_int64(prepared, 1, candidate.rowid)
                    return try step(prepared) ? LensWorksSemanticMatch(imageID: candidate.image, assetID: text(prepared, 0), variantID: text(prepared, 1), score: candidate.score) : nil
                }
            }
        }
    }

    /// Every embedded photo's similarity to `query`, best first, equal scores in image order. Unlike
    /// `nearest` it keeps the whole ranking (16 bytes a photo), for a caller that must walk down it
    /// until enough photos pass a test the index cannot make (the catalog's filters).
    func ranked(_ query: [Float]) throws -> [LensWorksSemanticRank] {
        try run {
            let query = try unit(query)
            guard !query.isEmpty else { return [] }
            var ranking: [LensWorksSemanticRank] = []
            ranking.reserveCapacity(Int(try scalar("SELECT COUNT(*) FROM embeddings")))
            try statement("SELECT rowid,vector FROM embeddings ORDER BY image") { prepared in
                while try step(prepared) {
                    if ranking.count & 0x3ff == 0 { try Task.checkCancellation() }
                    guard Int(sqlite3_column_bytes(prepared, 1)) == query.count * 2, let blob = sqlite3_column_blob(prepared, 1) else { continue }
                    ranking.append(.init(score: score(blob, query: query), ordinal: UInt32(truncatingIfNeeded: ranking.count), rowid: sqlite3_column_int64(prepared, 0)))
                }
            }
            ranking.sort { $0.score != $1.score ? $0.score > $1.score : $0.ordinal < $1.ordinal }
            return ranking
        }
    }

    /// The photos stored at `rowids`, in that order; nil for a row that is gone.
    func photos(rowids: [Int64]) throws -> [LensWorksSemanticPending?] {
        guard !rowids.isEmpty else { return [] }
        return try run {
            try statement("SELECT image,asset,variant FROM embeddings WHERE rowid=?") { prepared in
                try rowids.map { rowid in
                    sqlite3_reset(prepared)
                    sqlite3_bind_int64(prepared, 1, rowid)
                    return try step(prepared) ? LensWorksSemanticPending(imageID: text(prepared, 0), assetID: text(prepared, 1), variantID: text(prepared, 2)) : nil
                }
            }
        }
    }

    /// Similarity of each of `images` that has an embedding (the others are absent from the result).
    func scores(_ query: [Float], images: [String]) throws -> [String: Float] {
        guard !images.isEmpty else { return [:] }
        return try run {
            let query = try unit(query)
            guard !query.isEmpty else { return [:] }
            return try statement("SELECT vector FROM embeddings WHERE image=?") { prepared in
                var result: [String: Float] = [:]
                result.reserveCapacity(images.count)
                for image in images {
                    try rebind(prepared, [image])
                    guard try step(prepared), Int(sqlite3_column_bytes(prepared, 0)) == query.count * 2, let blob = sqlite3_column_blob(prepared, 0) else { continue }
                    result[image] = score(blob, query: query)
                }
                return result
            }
        }
    }

    /// The preview version a photo's stored embedding came from.
    func version(_ image: String) throws -> (revision: Int64, recipeDigest: String)? {
        try run {
            try statement("SELECT revision,digest FROM embeddings WHERE image=?", [image]) { try step($0) ? (sqlite3_column_int64($0, 0), text($0, 1)) : nil }
        }
    }
}
