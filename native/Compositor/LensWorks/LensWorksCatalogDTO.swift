// Source-derived from LensWorks-owned engines/catalog; upstream snapshot f4f8d3f12acc77fe5632720702c52a7cfefb5b58 is provenance only.
// Coverage and source hashes: docs/CATALOG_SERVICE_COVERAGE.json.
// All retained serialized request/result fields remain typed; arbitrary JSON is limited to serde_json::Value.
import Foundation

/// application::Limits (engines/catalog/src/application.rs:101).
nonisolated struct LWApplicationLimits: Codable, Sendable {
    var queued: UInt
    var request_bytes: UInt
    var reply_bytes: UInt
    var page_rows: UInt16
    var scan_rows: UInt
    var page_bytes: UInt
    var tickets: UInt
    var ttl_seconds: UInt64
    var binary_bytes: UInt
    init(queued: UInt, request_bytes: UInt, reply_bytes: UInt, page_rows: UInt16, scan_rows: UInt, page_bytes: UInt, tickets: UInt, ttl_seconds: UInt64, binary_bytes: UInt) {
        self.queued = queued
        self.request_bytes = request_bytes
        self.reply_bytes = reply_bytes
        self.page_rows = page_rows
        self.scan_rows = scan_rows
        self.page_bytes = page_bytes
        self.tickets = tickets
        self.ttl_seconds = ttl_seconds
        self.binary_bytes = binary_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["queued", "request_bytes", "reply_bytes", "page_rows", "scan_rows", "page_bytes", "tickets", "ttl_seconds", "binary_bytes"])
        self.queued = try container.decode(UInt.self, forKey: LWCatalogCodingKey("queued"))
        self.request_bytes = try container.decode(UInt.self, forKey: LWCatalogCodingKey("request_bytes"))
        self.reply_bytes = try container.decode(UInt.self, forKey: LWCatalogCodingKey("reply_bytes"))
        self.page_rows = try container.decode(UInt16.self, forKey: LWCatalogCodingKey("page_rows"))
        self.scan_rows = try container.decode(UInt.self, forKey: LWCatalogCodingKey("scan_rows"))
        self.page_bytes = try container.decode(UInt.self, forKey: LWCatalogCodingKey("page_bytes"))
        self.tickets = try container.decode(UInt.self, forKey: LWCatalogCodingKey("tickets"))
        self.ttl_seconds = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("ttl_seconds"))
        self.binary_bytes = try container.decode(UInt.self, forKey: LWCatalogCodingKey("binary_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(queued, forKey: LWCatalogCodingKey("queued"))
        try container.encode(request_bytes, forKey: LWCatalogCodingKey("request_bytes"))
        try container.encode(reply_bytes, forKey: LWCatalogCodingKey("reply_bytes"))
        try container.encode(page_rows, forKey: LWCatalogCodingKey("page_rows"))
        try container.encode(scan_rows, forKey: LWCatalogCodingKey("scan_rows"))
        try container.encode(page_bytes, forKey: LWCatalogCodingKey("page_bytes"))
        try container.encode(tickets, forKey: LWCatalogCodingKey("tickets"))
        try container.encode(ttl_seconds, forKey: LWCatalogCodingKey("ttl_seconds"))
        try container.encode(binary_bytes, forKey: LWCatalogCodingKey("binary_bytes"))
    }
}

/// application::backup::BackupReceipt (engines/catalog/src/application/backup.rs:76).
nonisolated struct LWApplicationBackupBackupReceipt: Codable, Sendable {
    var `protocol`: LWCatalogU64
    var backup_id: String
    var application_id: LWCatalogI64
    var schema_version: LWCatalogI64
    var database_bytes: LWCatalogU64
    var database_blake3: String
    init(`protocol`: LWCatalogU64, backup_id: String, application_id: LWCatalogI64, schema_version: LWCatalogI64, database_bytes: LWCatalogU64, database_blake3: String) {
        self.`protocol` = `protocol`
        self.backup_id = backup_id
        self.application_id = application_id
        self.schema_version = schema_version
        self.database_bytes = database_bytes
        self.database_blake3 = database_blake3
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.`protocol` = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("protocol"))
        self.backup_id = try container.decode(String.self, forKey: LWCatalogCodingKey("backup_id"))
        self.application_id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("application_id"))
        self.schema_version = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("schema_version"))
        self.database_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("database_bytes"))
        self.database_blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("database_blake3"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(`protocol`, forKey: LWCatalogCodingKey("protocol"))
        try container.encode(backup_id, forKey: LWCatalogCodingKey("backup_id"))
        try container.encode(application_id, forKey: LWCatalogCodingKey("application_id"))
        try container.encode(schema_version, forKey: LWCatalogCodingKey("schema_version"))
        try container.encode(database_bytes, forKey: LWCatalogCodingKey("database_bytes"))
        try container.encode(database_blake3, forKey: LWCatalogCodingKey("database_blake3"))
    }
}

/// application::backup::Failure (engines/catalog/src/application/backup.rs:120).
nonisolated struct LWApplicationBackupFailure: Codable, Sendable {
    var message: String
    var truncated: Bool
    init(message: String, truncated: Bool) {
        self.message = message
        self.truncated = truncated
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.message = try container.decode(String.self, forKey: LWCatalogCodingKey("message"))
        self.truncated = try container.decode(Bool.self, forKey: LWCatalogCodingKey("truncated"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(message, forKey: LWCatalogCodingKey("message"))
        try container.encode(truncated, forKey: LWCatalogCodingKey("truncated"))
    }
}

/// application::backup::Kind (engines/catalog/src/application/backup.rs:44).
nonisolated enum LWApplicationBackupKind: String, Codable, Sendable {
    case Create = "create"
    case Inspect = "inspect"
    case Restore = "restore"
}

/// application::backup::Progress (engines/catalog/src/application/backup.rs:59).
nonisolated struct LWApplicationBackupProgress: Codable, Sendable {
    var phase: LWCatalogBackupPhase
    var pages_copied: LWCatalogU64
    var total_pages: LWCatalogU64
    var bytes_processed: LWCatalogU64
    init(phase: LWCatalogBackupPhase, pages_copied: LWCatalogU64, total_pages: LWCatalogU64, bytes_processed: LWCatalogU64) {
        self.phase = phase
        self.pages_copied = pages_copied
        self.total_pages = total_pages
        self.bytes_processed = bytes_processed
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.phase = try container.decode(LWCatalogBackupPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.pages_copied = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("pages_copied"))
        self.total_pages = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_pages"))
        self.bytes_processed = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes_processed"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(pages_copied, forKey: LWCatalogCodingKey("pages_copied"))
        try container.encode(total_pages, forKey: LWCatalogCodingKey("total_pages"))
        try container.encode(bytes_processed, forKey: LWCatalogCodingKey("bytes_processed"))
    }
}

/// application::backup::Receipt (engines/catalog/src/application/backup.rs:115).
nonisolated indirect enum LWApplicationBackupReceipt: Codable, Sendable {
    case Backup(LWApplicationBackupBackupReceipt)
    case Restore(LWApplicationBackupRestoreReceipt)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "backup":
            self = .Backup(try container.decode(LWApplicationBackupBackupReceipt.self, forKey: LWCatalogCodingKey("data")))
        case "restore":
            self = .Restore(try container.decode(LWApplicationBackupRestoreReceipt.self, forKey: LWCatalogCodingKey("data")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationBackupReceipt variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Backup(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Restore(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        }
    }
}

/// application::backup::RestoreReceipt (engines/catalog/src/application/backup.rs:97).
nonisolated struct LWApplicationBackupRestoreReceipt: Codable, Sendable {
    var `protocol`: LWCatalogU64
    var restore_id: String
    var backup: LWApplicationBackupBackupReceipt
    var schema_version: LWCatalogI64
    init(`protocol`: LWCatalogU64, restore_id: String, backup: LWApplicationBackupBackupReceipt, schema_version: LWCatalogI64) {
        self.`protocol` = `protocol`
        self.restore_id = restore_id
        self.backup = backup
        self.schema_version = schema_version
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.`protocol` = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("protocol"))
        self.restore_id = try container.decode(String.self, forKey: LWCatalogCodingKey("restore_id"))
        self.backup = try container.decode(LWApplicationBackupBackupReceipt.self, forKey: LWCatalogCodingKey("backup"))
        self.schema_version = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("schema_version"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(`protocol`, forKey: LWCatalogCodingKey("protocol"))
        try container.encode(restore_id, forKey: LWCatalogCodingKey("restore_id"))
        try container.encode(backup, forKey: LWCatalogCodingKey("backup"))
        try container.encode(schema_version, forKey: LWCatalogCodingKey("schema_version"))
    }
}

/// application::backup::Snapshot (engines/catalog/src/application/backup.rs:125).
nonisolated struct LWApplicationBackupSnapshot: Codable, Sendable {
    var operation: String
    var kind: LWApplicationBackupKind
    var state: LWApplicationBackupState
    var cancellation_requested: Bool
    var progress: LWApplicationBackupProgress?
    var receipt: LWApplicationBackupReceipt?
    var error: LWApplicationBackupFailure?
    init(operation: String, kind: LWApplicationBackupKind, state: LWApplicationBackupState, cancellation_requested: Bool, progress: LWApplicationBackupProgress?, receipt: LWApplicationBackupReceipt?, error: LWApplicationBackupFailure?) {
        self.operation = operation
        self.kind = kind
        self.state = state
        self.cancellation_requested = cancellation_requested
        self.progress = progress
        self.receipt = receipt
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        self.kind = try container.decode(LWApplicationBackupKind.self, forKey: LWCatalogCodingKey("kind"))
        self.state = try container.decode(LWApplicationBackupState.self, forKey: LWCatalogCodingKey("state"))
        self.cancellation_requested = try container.decode(Bool.self, forKey: LWCatalogCodingKey("cancellation_requested"))
        self.progress = try container.decodeIfPresent(LWApplicationBackupProgress.self, forKey: LWCatalogCodingKey("progress"))
        self.receipt = try container.decodeIfPresent(LWApplicationBackupReceipt.self, forKey: LWCatalogCodingKey("receipt"))
        self.error = try container.decodeIfPresent(LWApplicationBackupFailure.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(cancellation_requested, forKey: LWCatalogCodingKey("cancellation_requested"))
        try container.encode(progress, forKey: LWCatalogCodingKey("progress"))
        try container.encode(receipt, forKey: LWCatalogCodingKey("receipt"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::backup::State (engines/catalog/src/application/backup.rs:51).
nonisolated enum LWApplicationBackupState: String, Codable, Sendable {
    case Running = "running"
    case CancelRequested = "cancel_requested"
    case Complete = "complete"
    case Failed = "failed"
}

/// application::browse::Options (engines/catalog/src/application/browse.rs:8).
nonisolated struct LWApplicationBrowseOptions: Codable, Sendable {
    var text: String?
    var keyword: LWCatalogI64?
    var keyword_direct: Bool
    var folder: LWCatalogI64?
    var folder_recursive: Bool
    var collection: String?
    var date_from: String?
    var date_until: String?
    var camera_make: String?
    var camera: String?
    var lens: String?
    var format: String?
    var rating: UInt8?
    var flag: LWOrganizationFlag?
    var label: String?
    var only_conflicted: Bool
    var sort: LWOrganizationSearchSort
    var direction: LWOrganizationSearchDirection
    init(text: String?, keyword: LWCatalogI64?, keyword_direct: Bool, folder: LWCatalogI64?, folder_recursive: Bool, collection: String?, date_from: String?, date_until: String?, camera_make: String?, camera: String?, lens: String?, format: String?, rating: UInt8?, flag: LWOrganizationFlag?, label: String?, only_conflicted: Bool, sort: LWOrganizationSearchSort, direction: LWOrganizationSearchDirection) {
        self.text = text
        self.keyword = keyword
        self.keyword_direct = keyword_direct
        self.folder = folder
        self.folder_recursive = folder_recursive
        self.collection = collection
        self.date_from = date_from
        self.date_until = date_until
        self.camera_make = camera_make
        self.camera = camera
        self.lens = lens
        self.format = format
        self.rating = rating
        self.flag = flag
        self.label = label
        self.only_conflicted = only_conflicted
        self.sort = sort
        self.direction = direction
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["text", "keyword", "keyword_direct", "folder", "folder_recursive", "collection", "date_from", "date_until", "camera_make", "camera", "lens", "format", "rating", "flag", "label", "only_conflicted", "sort", "direction"])
        self.text = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("text"))
        self.keyword = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("keyword"))
        self.keyword_direct = try container.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("keyword_direct")) ?? false
        self.folder = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("folder"))
        self.folder_recursive = try container.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("folder_recursive")) ?? false
        self.collection = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("collection"))
        self.date_from = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("date_from"))
        self.date_until = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("date_until"))
        self.camera_make = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("camera_make"))
        self.camera = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("camera"))
        self.lens = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("lens"))
        self.format = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("format"))
        self.rating = try container.decodeIfPresent(UInt8.self, forKey: LWCatalogCodingKey("rating"))
        self.flag = try container.decodeIfPresent(LWOrganizationFlag.self, forKey: LWCatalogCodingKey("flag"))
        self.label = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("label"))
        self.only_conflicted = try container.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("only_conflicted")) ?? false
        self.sort = try container.decodeIfPresent(LWOrganizationSearchSort.self, forKey: LWCatalogCodingKey("sort")) ?? .Sequence
        self.direction = try container.decodeIfPresent(LWOrganizationSearchDirection.self, forKey: LWCatalogCodingKey("direction")) ?? .Ascending
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(text, forKey: LWCatalogCodingKey("text"))
        try container.encode(keyword, forKey: LWCatalogCodingKey("keyword"))
        try container.encode(keyword_direct, forKey: LWCatalogCodingKey("keyword_direct"))
        try container.encode(folder, forKey: LWCatalogCodingKey("folder"))
        try container.encode(folder_recursive, forKey: LWCatalogCodingKey("folder_recursive"))
        try container.encode(collection, forKey: LWCatalogCodingKey("collection"))
        try container.encode(date_from, forKey: LWCatalogCodingKey("date_from"))
        try container.encode(date_until, forKey: LWCatalogCodingKey("date_until"))
        try container.encode(camera_make, forKey: LWCatalogCodingKey("camera_make"))
        try container.encode(camera, forKey: LWCatalogCodingKey("camera"))
        try container.encode(lens, forKey: LWCatalogCodingKey("lens"))
        try container.encode(format, forKey: LWCatalogCodingKey("format"))
        try container.encode(rating, forKey: LWCatalogCodingKey("rating"))
        try container.encode(flag, forKey: LWCatalogCodingKey("flag"))
        try container.encode(label, forKey: LWCatalogCodingKey("label"))
        try container.encode(only_conflicted, forKey: LWCatalogCodingKey("only_conflicted"))
        try container.encode(sort, forKey: LWCatalogCodingKey("sort"))
        try container.encode(direction, forKey: LWCatalogCodingKey("direction"))
    }
}

/// application::copy::Inspection (engines/catalog/src/application/copy.rs:117).
nonisolated struct LWApplicationCopyInspection: Codable, Sendable {
    var job: LWApplicationCopyJob
    var source: LWApplicationCopyTarget
    var name: LWApplicationCopyName
    var digest: String
    var recipe: LWEditRecipeRecipe
    var groups: [LWEditRecipeAdjustmentGroup]
    init(job: LWApplicationCopyJob, source: LWApplicationCopyTarget, name: LWApplicationCopyName, digest: String, recipe: LWEditRecipeRecipe, groups: [LWEditRecipeAdjustmentGroup]) {
        self.job = job
        self.source = source
        self.name = name
        self.digest = digest
        self.recipe = recipe
        self.groups = groups
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.job = try container.decode(LWApplicationCopyJob.self, forKey: LWCatalogCodingKey("job"))
        self.source = try container.decode(LWApplicationCopyTarget.self, forKey: LWCatalogCodingKey("source"))
        self.name = try container.decode(LWApplicationCopyName.self, forKey: LWCatalogCodingKey("name"))
        self.digest = try container.decode(String.self, forKey: LWCatalogCodingKey("digest"))
        self.recipe = try container.decode(LWEditRecipeRecipe.self, forKey: LWCatalogCodingKey("recipe"))
        self.groups = try container.decode([LWEditRecipeAdjustmentGroup].self, forKey: LWCatalogCodingKey("groups"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(job, forKey: LWCatalogCodingKey("job"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(digest, forKey: LWCatalogCodingKey("digest"))
        try container.encode(recipe, forKey: LWCatalogCodingKey("recipe"))
        try container.encode(groups, forKey: LWCatalogCodingKey("groups"))
    }
}

/// application::copy::Item (engines/catalog/src/application/copy.rs:107).
nonisolated struct LWApplicationCopyItem: Codable, Sendable {
    var sequence: LWCatalogI64
    var target: LWApplicationCopyTarget
    var name: LWApplicationCopyName
    var state: String
    var applied_revision: LWCatalogI64?
    var current_revision: LWCatalogI64?
    var error: String?
    init(sequence: LWCatalogI64, target: LWApplicationCopyTarget, name: LWApplicationCopyName, state: String, applied_revision: LWCatalogI64?, current_revision: LWCatalogI64?, error: String?) {
        self.sequence = sequence
        self.target = target
        self.name = name
        self.state = state
        self.applied_revision = applied_revision
        self.current_revision = current_revision
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.target = try container.decode(LWApplicationCopyTarget.self, forKey: LWCatalogCodingKey("target"))
        self.name = try container.decode(LWApplicationCopyName.self, forKey: LWCatalogCodingKey("name"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.applied_revision = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("applied_revision"))
        self.current_revision = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("current_revision"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(target, forKey: LWCatalogCodingKey("target"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(applied_revision, forKey: LWCatalogCodingKey("applied_revision"))
        try container.encode(current_revision, forKey: LWCatalogCodingKey("current_revision"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::copy::Job (engines/catalog/src/application/copy.rs:82).
nonisolated struct LWApplicationCopyJob: Codable, Sendable {
    var sequence: LWCatalogI64
    var id: String
    var state: String
    var total: LWCatalogI64
    var completed: LWCatalogI64
    init(sequence: LWCatalogI64, id: String, state: String, total: LWCatalogI64, completed: LWCatalogI64) {
        self.sequence = sequence
        self.id = id
        self.state = state
        self.total = total
        self.completed = completed
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.total = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("total"))
        self.completed = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("completed"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(total, forKey: LWCatalogCodingKey("total"))
        try container.encode(completed, forKey: LWCatalogCodingKey("completed"))
    }
}

/// application::copy::Name (engines/catalog/src/application/copy.rs:101).
nonisolated struct LWApplicationCopyName: Codable, Sendable {
    var filename: String
    var variant_label: String
    var available: Bool
    init(filename: String, variant_label: String, available: Bool) {
        self.filename = filename
        self.variant_label = variant_label
        self.available = available
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.filename = try container.decode(String.self, forKey: LWCatalogCodingKey("filename"))
        self.variant_label = try container.decode(String.self, forKey: LWCatalogCodingKey("variant_label"))
        self.available = try container.decode(Bool.self, forKey: LWCatalogCodingKey("available"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(filename, forKey: LWCatalogCodingKey("filename"))
        try container.encode(variant_label, forKey: LWCatalogCodingKey("variant_label"))
        try container.encode(available, forKey: LWCatalogCodingKey("available"))
    }
}

/// application::copy::Operation (engines/catalog/src/application/copy.rs:136).
nonisolated struct LWApplicationCopyOperation: Codable, Sendable {
    var id: String
    var job: LWApplicationCopyJob
    var phase: LWApplicationCopyPhase
    var error: String?
    init(id: String, job: LWApplicationCopyJob, phase: LWApplicationCopyPhase, error: String?) {
        self.id = id
        self.job = job
        self.phase = phase
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.job = try container.decode(LWApplicationCopyJob.self, forKey: LWCatalogCodingKey("job"))
        self.phase = try container.decode(LWApplicationCopyPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(job, forKey: LWCatalogCodingKey("job"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::copy::Phase (engines/catalog/src/application/copy.rs:127).
nonisolated enum LWApplicationCopyPhase: String, Codable, Sendable {
    case Running = "running"
    case Paused = "paused"
    case CancelRequested = "cancel_requested"
    case Complete = "complete"
    case Canceled = "canceled"
    case Failed = "failed"
}

/// application::copy::Request (engines/catalog/src/application/copy.rs:22).
nonisolated indirect enum LWApplicationCopyRequest: Codable, Sendable {
    case Begin(source: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, groups: [LWEditRecipeAdjustmentGroup])
    case Append(job: String, expected_total: LWCatalogI64, targets: [LWApplicationCopyTarget])
    case Seal(job: String, expected_total: LWCatalogI64)
    case Run(job: String)
    case Status(operation: String?)
    case Cancel(job: String, operation: String?)
    case Job(job: String)
    case Jobs(after: LWCatalogI64, limit: LWCatalogU64)
    case Items(job: String, after: LWCatalogI64, limit: LWCatalogU64)
    case Inspect(job: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "begin":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["source", "expected_revision", "groups"])
            self = .Begin(source: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("source")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), groups: try payload.decode([LWEditRecipeAdjustmentGroup].self, forKey: LWCatalogCodingKey("groups")))
        case "append":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "expected_total", "targets"])
            self = .Append(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), expected_total: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_total")), targets: try payload.decode([LWApplicationCopyTarget].self, forKey: LWCatalogCodingKey("targets")))
        case "seal":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "expected_total"])
            self = .Seal(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), expected_total: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_total")))
        case "run":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Run(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Status(operation: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation")))
        case "cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "operation"])
            self = .Cancel(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), operation: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation")))
        case "job":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Job(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "jobs":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["after", "limit"])
            self = .Jobs(after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "items":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "after", "limit"])
            self = .Items(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "inspect":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Inspect(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationCopyRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Begin(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("source"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("groups"))
        case .Append(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("append", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_total"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("targets"))
        case .Seal(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("seal", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_total"))
        case .Run(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("run", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .Cancel(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("operation"))
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Jobs(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jobs", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limit"))
        case .Items(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Inspect(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("inspect", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        }
    }
}

/// application::copy::Response (engines/catalog/src/application/copy.rs:144).
nonisolated indirect enum LWApplicationCopyResponse: Codable, Sendable {
    case Job(LWApplicationCopyJob)
    case Jobs(rows: [LWApplicationCopyJob], next: LWCatalogI64?)
    case Items(rows: [LWApplicationCopyItem], next: LWCatalogI64?)
    case Inspection(LWApplicationCopyInspection)
    case Operation(LWApplicationCopyOperation?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "job":
            self = .Job(try container.decode(LWApplicationCopyJob.self, forKey: LWCatalogCodingKey("value")))
        case "jobs":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Jobs(rows: try payload.decode([LWApplicationCopyJob].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "items":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Items(rows: try payload.decode([LWApplicationCopyItem].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "inspection":
            self = .Inspection(try container.decode(LWApplicationCopyInspection.self, forKey: LWCatalogCodingKey("value")))
        case "operation":
            self = .Operation(try container.decode(LWApplicationCopyOperation?.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationCopyResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Jobs(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jobs", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Items(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Inspection(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("inspection", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Operation(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("operation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::copy::Target (engines/catalog/src/application/copy.rs:77).
nonisolated struct LWApplicationCopyTarget: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var expected_revision: LWCatalogI64
    init(key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64) {
        self.key = key
        self.expected_revision = expected_revision
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["key", "expected_revision"])
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.expected_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(expected_revision, forKey: LWCatalogCodingKey("expected_revision"))
    }
}

/// application::dto::BridgeError (engines/catalog/src/application/dto.rs:437).
nonisolated struct LWApplicationDtoBridgeError: Codable, Sendable {
    var code: LWApplicationDtoErrorCode
    var message: String
    init(code: LWApplicationDtoErrorCode, message: String) {
        self.code = code
        self.message = message
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.code = try container.decode(LWApplicationDtoErrorCode.self, forKey: LWCatalogCodingKey("code"))
        self.message = try container.decode(String.self, forKey: LWCatalogCodingKey("message"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(code, forKey: LWCatalogCodingKey("code"))
        try container.encode(message, forKey: LWCatalogCodingKey("message"))
    }
}

/// application::dto::CullOperation (engines/catalog/src/application/dto.rs:220).
nonisolated indirect enum LWApplicationDtoCullOperation: Codable, Sendable {
    case Rating(UInt8)
    case Flag(LWOrganizationFlag)
    case Label(String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        switch discriminator {
        case "rating":
            try container.lwRequireKeys(["operation", "value"])
            self = .Rating(try container.decode(UInt8.self, forKey: LWCatalogCodingKey("value")))
        case "flag":
            try container.lwRequireKeys(["operation", "value"])
            self = .Flag(try container.decode(LWOrganizationFlag.self, forKey: LWCatalogCodingKey("value")))
        case "label":
            try container.lwRequireKeys(["operation", "value"])
            self = .Label(try container.decode(String.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationDtoCullOperation variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Rating(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("rating", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Flag(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("flag", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Label(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("label", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::dto::ErrorCode (engines/catalog/src/application/dto.rs:426).
nonisolated enum LWApplicationDtoErrorCode: String, Codable, Sendable {
    case InvalidRequest = "invalid_request"
    case Busy = "busy"
    case Canceled = "canceled"
    case Superseded = "superseded"
    case StaleSession = "stale_session"
    case Native = "native"
    case ResourceLimit = "resource_limit"
    case Closed = "closed"
}

/// application::dto::Folder (engines/catalog/src/application/dto.rs:278).
nonisolated struct LWApplicationDtoFolder: Codable, Sendable {
    var id: LWCatalogI64
    var parent: LWCatalogI64?
    var locator: LWCatalogNativePath
    var name: String
    init(id: LWCatalogI64, parent: LWCatalogI64?, locator: LWCatalogNativePath, name: String) {
        self.id = id
        self.parent = parent
        self.locator = locator
        self.name = name
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.parent = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("parent"))
        self.locator = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("locator"))
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(parent, forKey: LWCatalogCodingKey("parent"))
        try container.encode(locator, forKey: LWCatalogCodingKey("locator"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
    }
}

/// application::dto::GridImage (engines/catalog/src/application/dto.rs:285).
nonisolated struct LWApplicationDtoGridImage: Codable, Sendable {
    var image_id: String
    var origin: String
    var translation_state: String
    var key: LWCatalogEditsVariantKey
    var sequence: LWCatalogI64
    var metadata_revision: LWCatalogI64
    var metadata_pending: Bool
    var state: String
    var filename: String
    var rating: LWCatalogI64?
    var flag: String
    var label: String
    var conflicts: [String]
    init(image_id: String, origin: String, translation_state: String, key: LWCatalogEditsVariantKey, sequence: LWCatalogI64, metadata_revision: LWCatalogI64, metadata_pending: Bool, state: String, filename: String, rating: LWCatalogI64?, flag: String, label: String, conflicts: [String]) {
        self.image_id = image_id
        self.origin = origin
        self.translation_state = translation_state
        self.key = key
        self.sequence = sequence
        self.metadata_revision = metadata_revision
        self.metadata_pending = metadata_pending
        self.state = state
        self.filename = filename
        self.rating = rating
        self.flag = flag
        self.label = label
        self.conflicts = conflicts
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.image_id = try container.decode(String.self, forKey: LWCatalogCodingKey("image_id"))
        self.origin = try container.decode(String.self, forKey: LWCatalogCodingKey("origin"))
        self.translation_state = try container.decode(String.self, forKey: LWCatalogCodingKey("translation_state"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.metadata_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("metadata_revision"))
        self.metadata_pending = try container.decode(Bool.self, forKey: LWCatalogCodingKey("metadata_pending"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.filename = try container.decode(String.self, forKey: LWCatalogCodingKey("filename"))
        self.rating = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("rating"))
        self.flag = try container.decode(String.self, forKey: LWCatalogCodingKey("flag"))
        self.label = try container.decode(String.self, forKey: LWCatalogCodingKey("label"))
        self.conflicts = try container.decode([String].self, forKey: LWCatalogCodingKey("conflicts"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(image_id, forKey: LWCatalogCodingKey("image_id"))
        try container.encode(origin, forKey: LWCatalogCodingKey("origin"))
        try container.encode(translation_state, forKey: LWCatalogCodingKey("translation_state"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(metadata_revision, forKey: LWCatalogCodingKey("metadata_revision"))
        try container.encode(metadata_pending, forKey: LWCatalogCodingKey("metadata_pending"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(filename, forKey: LWCatalogCodingKey("filename"))
        try container.encode(rating, forKey: LWCatalogCodingKey("rating"))
        try container.encode(flag, forKey: LWCatalogCodingKey("flag"))
        try container.encode(label, forKey: LWCatalogCodingKey("label"))
        try container.encode(conflicts, forKey: LWCatalogCodingKey("conflicts"))
    }
}

/// application::dto::HistoryEntry (engines/catalog/src/application/dto.rs:311).
nonisolated struct LWApplicationDtoHistoryEntry: Codable, Sendable {
    var revision: LWCatalogI64
    var kind: String
    var recipe: LWEditRecipeRecipe
    var recipe_digest: String
    init(revision: LWCatalogI64, kind: String, recipe: LWEditRecipeRecipe, recipe_digest: String) {
        self.revision = revision
        self.kind = kind
        self.recipe = recipe
        self.recipe_digest = recipe_digest
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.kind = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        self.recipe = try container.decode(LWEditRecipeRecipe.self, forKey: LWCatalogCodingKey("recipe"))
        self.recipe_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("recipe_digest"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(recipe, forKey: LWCatalogCodingKey("recipe"))
        try container.encode(recipe_digest, forKey: LWCatalogCodingKey("recipe_digest"))
    }
}

/// application::dto::ImportPhase (engines/catalog/src/application/dto.rs:253).
nonisolated enum LWApplicationDtoImportPhase: String, Codable, Sendable {
    case Discovering = "discovering"
    case Draining = "draining"
    case Complete = "complete"
    case CancelRequested = "cancel_requested"
    case Canceled = "canceled"
    case Failed = "failed"
}

/// application::dto::ImportStatus (engines/catalog/src/application/dto.rs:262).
nonisolated struct LWApplicationDtoImportStatus: Codable, Sendable {
    var id: String
    var source: LWCatalogNativePath
    var phase: LWApplicationDtoImportPhase
    var imported: LWCatalogU64
    var unchanged: LWCatalogU64
    var failed: LWCatalogU64
    var skipped: LWCatalogU64
    var metadata_updated: LWCatalogU64
    var metadata_warnings: LWCatalogU64
    var awaiting_resources: LWCatalogU64
    var pending_previews: UInt32
    var error: String?
    var error_source: LWCatalogNativePath?
    init(id: String, source: LWCatalogNativePath, phase: LWApplicationDtoImportPhase, imported: LWCatalogU64, unchanged: LWCatalogU64, failed: LWCatalogU64, skipped: LWCatalogU64, metadata_updated: LWCatalogU64, metadata_warnings: LWCatalogU64, awaiting_resources: LWCatalogU64, pending_previews: UInt32, error: String?, error_source: LWCatalogNativePath?) {
        self.id = id
        self.source = source
        self.phase = phase
        self.imported = imported
        self.unchanged = unchanged
        self.failed = failed
        self.skipped = skipped
        self.metadata_updated = metadata_updated
        self.metadata_warnings = metadata_warnings
        self.awaiting_resources = awaiting_resources
        self.pending_previews = pending_previews
        self.error = error
        self.error_source = error_source
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.source = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("source"))
        self.phase = try container.decode(LWApplicationDtoImportPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.imported = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("imported"))
        self.unchanged = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("unchanged"))
        self.failed = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("failed"))
        self.skipped = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("skipped"))
        self.metadata_updated = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("metadata_updated"))
        self.metadata_warnings = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("metadata_warnings"))
        self.awaiting_resources = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("awaiting_resources"))
        self.pending_previews = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("pending_previews"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
        self.error_source = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("error_source"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(imported, forKey: LWCatalogCodingKey("imported"))
        try container.encode(unchanged, forKey: LWCatalogCodingKey("unchanged"))
        try container.encode(failed, forKey: LWCatalogCodingKey("failed"))
        try container.encode(skipped, forKey: LWCatalogCodingKey("skipped"))
        try container.encode(metadata_updated, forKey: LWCatalogCodingKey("metadata_updated"))
        try container.encode(metadata_warnings, forKey: LWCatalogCodingKey("metadata_warnings"))
        try container.encode(awaiting_resources, forKey: LWCatalogCodingKey("awaiting_resources"))
        try container.encode(pending_previews, forKey: LWCatalogCodingKey("pending_previews"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
        try container.encode(error_source, forKey: LWCatalogCodingKey("error_source"))
    }
}

/// application::dto::Phase (engines/catalog/src/application/dto.rs:233).
nonisolated enum LWApplicationDtoPhase: String, Codable, Sendable {
    case Closed = "closed"
    case Opening = "opening"
    case Indexing = "indexing"
    case Ready = "ready"
    case Closing = "closing"
    case Failed = "failed"
}

/// application::dto::PreviewDeliveryDiagnostic (engines/catalog/src/application/dto.rs:350).
nonisolated struct LWApplicationDtoPreviewDeliveryDiagnostic: Codable, Sendable {
    var ready_for_transfer_ms: LWCatalogFloat64
    var retained_read: LWApplicationDtoPreviewReadDiagnostic
    var transfer_ms: LWCatalogFloat64
    var total_ms: LWCatalogFloat64
    init(ready_for_transfer_ms: LWCatalogFloat64, retained_read: LWApplicationDtoPreviewReadDiagnostic, transfer_ms: LWCatalogFloat64, total_ms: LWCatalogFloat64) {
        self.ready_for_transfer_ms = ready_for_transfer_ms
        self.retained_read = retained_read
        self.transfer_ms = transfer_ms
        self.total_ms = total_ms
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.ready_for_transfer_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("ready_for_transfer_ms"))
        self.retained_read = try container.decode(LWApplicationDtoPreviewReadDiagnostic.self, forKey: LWCatalogCodingKey("retained_read"))
        self.transfer_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("transfer_ms"))
        self.total_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("total_ms"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(ready_for_transfer_ms, forKey: LWCatalogCodingKey("ready_for_transfer_ms"))
        try container.encode(retained_read, forKey: LWCatalogCodingKey("retained_read"))
        try container.encode(transfer_ms, forKey: LWCatalogCodingKey("transfer_ms"))
        try container.encode(total_ms, forKey: LWCatalogCodingKey("total_ms"))
    }
}

/// application::dto::PreviewDiagnostic (engines/catalog/src/application/dto.rs:359).
nonisolated struct LWApplicationDtoPreviewDiagnostic: Codable, Sendable {
    var route: LWApplicationDtoPreviewRoute
    var expected_key_digest: String?
    var selected_key_digest: String?
    var current_key_matches_selected: Bool?
    var retained_read: LWApplicationDtoPreviewReadDiagnostic?
    var original_render_ms: LWCatalogFloat64?
    var ready_ms: LWCatalogFloat64?
    var delivery: LWApplicationDtoPreviewDeliveryDiagnostic?
    init(route: LWApplicationDtoPreviewRoute, expected_key_digest: String?, selected_key_digest: String?, current_key_matches_selected: Bool?, retained_read: LWApplicationDtoPreviewReadDiagnostic?, original_render_ms: LWCatalogFloat64?, ready_ms: LWCatalogFloat64?, delivery: LWApplicationDtoPreviewDeliveryDiagnostic?) {
        self.route = route
        self.expected_key_digest = expected_key_digest
        self.selected_key_digest = selected_key_digest
        self.current_key_matches_selected = current_key_matches_selected
        self.retained_read = retained_read
        self.original_render_ms = original_render_ms
        self.ready_ms = ready_ms
        self.delivery = delivery
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.route = try container.decode(LWApplicationDtoPreviewRoute.self, forKey: LWCatalogCodingKey("route"))
        self.expected_key_digest = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("expected_key_digest"))
        self.selected_key_digest = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("selected_key_digest"))
        self.current_key_matches_selected = try container.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("current_key_matches_selected"))
        self.retained_read = try container.decodeIfPresent(LWApplicationDtoPreviewReadDiagnostic.self, forKey: LWCatalogCodingKey("retained_read"))
        self.original_render_ms = try container.decodeIfPresent(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("original_render_ms"))
        self.ready_ms = try container.decodeIfPresent(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("ready_ms"))
        self.delivery = try container.decodeIfPresent(LWApplicationDtoPreviewDeliveryDiagnostic.self, forKey: LWCatalogCodingKey("delivery"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(route, forKey: LWCatalogCodingKey("route"))
        try container.encode(expected_key_digest, forKey: LWCatalogCodingKey("expected_key_digest"))
        try container.encode(selected_key_digest, forKey: LWCatalogCodingKey("selected_key_digest"))
        try container.encode(current_key_matches_selected, forKey: LWCatalogCodingKey("current_key_matches_selected"))
        try container.encode(retained_read, forKey: LWCatalogCodingKey("retained_read"))
        try container.encode(original_render_ms, forKey: LWCatalogCodingKey("original_render_ms"))
        try container.encode(ready_ms, forKey: LWCatalogCodingKey("ready_ms"))
        try container.encode(delivery, forKey: LWCatalogCodingKey("delivery"))
    }
}

/// application::dto::PreviewReadDiagnostic (engines/catalog/src/application/dto.rs:338).
nonisolated struct LWApplicationDtoPreviewReadDiagnostic: Codable, Sendable {
    var outcome: String
    var queue_ms: LWCatalogFloat64
    var owner_read_ms: LWCatalogFloat64
    var catalog_identity_ms: LWCatalogFloat64
    var store_read_checksum_ms: LWCatalogFloat64
    var header_decode_ms: LWCatalogFloat64
    var total_ms: LWCatalogFloat64
    var decoded_hits: UInt64
    var decoded_misses: UInt64
    init(outcome: String, queue_ms: LWCatalogFloat64, owner_read_ms: LWCatalogFloat64, catalog_identity_ms: LWCatalogFloat64, store_read_checksum_ms: LWCatalogFloat64, header_decode_ms: LWCatalogFloat64, total_ms: LWCatalogFloat64, decoded_hits: UInt64, decoded_misses: UInt64) {
        self.outcome = outcome
        self.queue_ms = queue_ms
        self.owner_read_ms = owner_read_ms
        self.catalog_identity_ms = catalog_identity_ms
        self.store_read_checksum_ms = store_read_checksum_ms
        self.header_decode_ms = header_decode_ms
        self.total_ms = total_ms
        self.decoded_hits = decoded_hits
        self.decoded_misses = decoded_misses
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.outcome = try container.decode(String.self, forKey: LWCatalogCodingKey("outcome"))
        self.queue_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("queue_ms"))
        self.owner_read_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("owner_read_ms"))
        self.catalog_identity_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("catalog_identity_ms"))
        self.store_read_checksum_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("store_read_checksum_ms"))
        self.header_decode_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("header_decode_ms"))
        self.total_ms = try container.decode(LWCatalogFloat64.self, forKey: LWCatalogCodingKey("total_ms"))
        self.decoded_hits = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("decoded_hits"))
        self.decoded_misses = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("decoded_misses"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(outcome, forKey: LWCatalogCodingKey("outcome"))
        try container.encode(queue_ms, forKey: LWCatalogCodingKey("queue_ms"))
        try container.encode(owner_read_ms, forKey: LWCatalogCodingKey("owner_read_ms"))
        try container.encode(catalog_identity_ms, forKey: LWCatalogCodingKey("catalog_identity_ms"))
        try container.encode(store_read_checksum_ms, forKey: LWCatalogCodingKey("store_read_checksum_ms"))
        try container.encode(header_decode_ms, forKey: LWCatalogCodingKey("header_decode_ms"))
        try container.encode(total_ms, forKey: LWCatalogCodingKey("total_ms"))
        try container.encode(decoded_hits, forKey: LWCatalogCodingKey("decoded_hits"))
        try container.encode(decoded_misses, forKey: LWCatalogCodingKey("decoded_misses"))
    }
}

/// application::dto::PreviewRoute (engines/catalog/src/application/dto.rs:331).
nonisolated enum LWApplicationDtoPreviewRoute: String, Codable, Sendable {
    case Pending = "pending"
    case Retained = "retained"
    case OriginalRender = "original_render"
    case MemoryCache = "memory_cache"
}

/// application::dto::PreviewState (engines/catalog/src/application/dto.rs:319).
nonisolated enum LWApplicationDtoPreviewState: String, Codable, Sendable {
    case Queued = "queued"
    case Ready = "ready"
    case Stale = "stale"
    case NeedsResources = "needs_resources"
    case Unavailable = "unavailable"
    case Failed = "failed"
    case CancelRequested = "cancel_requested"
    case Canceled = "canceled"
}

/// application::dto::PreviewStatus (engines/catalog/src/application/dto.rs:370).
nonisolated struct LWApplicationDtoPreviewStatus: Codable, Sendable {
    var ticket: String
    var key: LWCatalogEditsVariantKey
    var revision: LWCatalogI64
    var recipe_digest: String
    var viewport: String
    var generation: LWCatalogU64
    var state: LWApplicationDtoPreviewState
    var message: String?
    var diagnostic: LWApplicationDtoPreviewDiagnostic?
    init(ticket: String, key: LWCatalogEditsVariantKey, revision: LWCatalogI64, recipe_digest: String, viewport: String, generation: LWCatalogU64, state: LWApplicationDtoPreviewState, message: String?, diagnostic: LWApplicationDtoPreviewDiagnostic?) {
        self.ticket = ticket
        self.key = key
        self.revision = revision
        self.recipe_digest = recipe_digest
        self.viewport = viewport
        self.generation = generation
        self.state = state
        self.message = message
        self.diagnostic = diagnostic
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.ticket = try container.decode(String.self, forKey: LWCatalogCodingKey("ticket"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.recipe_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("recipe_digest"))
        self.viewport = try container.decode(String.self, forKey: LWCatalogCodingKey("viewport"))
        self.generation = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation"))
        self.state = try container.decode(LWApplicationDtoPreviewState.self, forKey: LWCatalogCodingKey("state"))
        self.message = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("message"))
        self.diagnostic = try container.decodeIfPresent(LWApplicationDtoPreviewDiagnostic.self, forKey: LWCatalogCodingKey("diagnostic"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(ticket, forKey: LWCatalogCodingKey("ticket"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(recipe_digest, forKey: LWCatalogCodingKey("recipe_digest"))
        try container.encode(viewport, forKey: LWCatalogCodingKey("viewport"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(message, forKey: LWCatalogCodingKey("message"))
        try container.encodeIfPresent(diagnostic, forKey: LWCatalogCodingKey("diagnostic"))
    }
}

/// application::dto::PreviewTier (engines/catalog/src/application/dto.rs:227).
nonisolated enum LWApplicationDtoPreviewTier: String, Codable, Sendable {
    case Thumbnail = "thumbnail"
    case Large = "large"
}

/// application::dto::Reply (engines/catalog/src/application/dto.rs:443).
nonisolated indirect enum LWApplicationDtoReply: Codable, Sendable {
    case Ok(value: LWApplicationDtoResponse)
    case Error(error: LWApplicationDtoBridgeError)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("status"))
        switch discriminator {
        case "ok":
            self = .Ok(value: try container.decode(LWApplicationDtoResponse.self, forKey: LWCatalogCodingKey("value")))
        case "error":
            self = .Error(error: try container.decode(LWApplicationDtoBridgeError.self, forKey: LWCatalogCodingKey("error")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationDtoReply variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Ok(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("ok", forKey: LWCatalogCodingKey("status"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Error(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("error", forKey: LWCatalogCodingKey("status"))
            try container.encode(value0, forKey: LWCatalogCodingKey("error"))
        }
    }
}

/// application::dto::Request (engines/catalog/src/application/dto.rs:37).
nonisolated indirect enum LWApplicationDtoRequest: Codable, Sendable {
    case PreviewSettings(catalog: String, request: LWApplicationPreviewSettingsRequest)
    case LightroomMigration(request: LWApplicationLightroomMigrationRequest)
    case Lightroom(request: LWApplicationLightroomBridgeWireRequest)
    case Export(catalog: String, request: LWApplicationExportsDtoRequest)
    case EditCopy(catalog: String, request: LWApplicationCopyRequest)
    case Relink(catalog: String, request: LWApplicationRelinkRequest)
    case OpenExisting(path: LWCatalogNativePath)
    case Create(path: LWCatalogNativePath)
    case Status
    case Close(catalog: String)
    case ImportStart(catalog: String, source: LWCatalogNativePath)
    case ImportResume(catalog: String, source: LWCatalogNativePath)
    case ImportStatus(catalog: String)
    case ImportCancel(catalog: String, `import`: String)
    case BackupCreate(catalog: String, bundle: LWCatalogNativePath)
    case BackupInspect(bundle: LWCatalogNativePath)
    case BackupRestore(bundle: LWCatalogNativePath, destination: LWCatalogNativePath)
    case BackupStatus
    case BackupCancel(operation: String)
    case RestoreStatus(catalog: String)
    case ResumeRestoredJobs(catalog: String, restore_id: String, acknowledge_pending_jobs: Bool)
    case Metadata(catalog: String, request: LWApplicationMetadataRequest)
    case MetadataWrite(catalog: String, request: LWApplicationMetadataWriteRequest)
    case Organization(catalog: String, request: LWApplicationOrganizationRequest)
    case Folders(catalog: String, parent: LWCatalogI64?, after: LWCatalogI64, limit: UInt16)
    case Images(catalog: String, folder: LWCatalogI64?, recursive: Bool, text: String?, cursor: String?, limit: UInt16)
    case Search(catalog: String, options: LWApplicationBrowseOptions, cursor: String?, limit: UInt16)
    case Image(catalog: String, key: LWCatalogEditsVariantKey)
    case Variant(catalog: String, key: LWCatalogEditsVariantKey)
    case Variants(catalog: String, asset_id: String, after: LWCatalogI64, limit: UInt16)
    case CreateVariant(catalog: String, key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, label: String)
    case SaveRecipe(catalog: String, key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, recipe: LWEditRecipeRecipe)
    case Undo(catalog: String, key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64)
    case Redo(catalog: String, key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64)
    case History(catalog: String, key: LWCatalogEditsVariantKey, after: LWCatalogI64, limit: UInt16)
    case Cull(catalog: String, key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, operation: LWApplicationDtoCullOperation)
    case Preview(catalog: String, key: LWCatalogEditsVariantKey, tier: LWApplicationDtoPreviewTier, interactive: Bool, viewport: String, generation: LWCatalogU64, foreground: Bool, diagnostics: Bool)
    case PreviewStatus(catalog: String, ticket: String)
    case ReleaseViewport(catalog: String, viewport: String, generation: LWCatalogU64)
    case CancelPreview(catalog: String, ticket: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "preview_settings":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .PreviewSettings(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationPreviewSettingsRequest.self, forKey: LWCatalogCodingKey("request")))
        case "lightroom_migration":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["request"])
            self = .LightroomMigration(request: try payload.decode(LWApplicationLightroomMigrationRequest.self, forKey: LWCatalogCodingKey("request")))
        case "lightroom":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["request"])
            self = .Lightroom(request: try payload.decode(LWApplicationLightroomBridgeWireRequest.self, forKey: LWCatalogCodingKey("request")))
        case "export":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .Export(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationExportsDtoRequest.self, forKey: LWCatalogCodingKey("request")))
        case "edit_copy":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .EditCopy(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationCopyRequest.self, forKey: LWCatalogCodingKey("request")))
        case "relink":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .Relink(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationRelinkRequest.self, forKey: LWCatalogCodingKey("request")))
        case "open_existing":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["path"])
            self = .OpenExisting(path: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path")))
        case "create":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["path"])
            self = .Create(path: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path")))
        case "status":
            try container.lwRequireKeys(["command", "args"])
            self = .Status
        case "close":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog"])
            self = .Close(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")))
        case "import_start":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "source"])
            self = .ImportStart(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), source: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("source")))
        case "import_resume":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "source"])
            self = .ImportResume(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), source: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("source")))
        case "import_status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog"])
            self = .ImportStatus(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")))
        case "import_cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "import"])
            self = .ImportCancel(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), import: try payload.decode(String.self, forKey: LWCatalogCodingKey("import")))
        case "backup_create":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "bundle"])
            self = .BackupCreate(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), bundle: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("bundle")))
        case "backup_inspect":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["bundle"])
            self = .BackupInspect(bundle: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("bundle")))
        case "backup_restore":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["bundle", "destination"])
            self = .BackupRestore(bundle: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("bundle")), destination: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination")))
        case "backup_status":
            try container.lwRequireKeys(["command", "args"])
            self = .BackupStatus
        case "backup_cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .BackupCancel(operation: try payload.decode(String.self, forKey: LWCatalogCodingKey("operation")))
        case "restore_status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog"])
            self = .RestoreStatus(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")))
        case "resume_restored_jobs":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "restore_id", "acknowledge_pending_jobs"])
            self = .ResumeRestoredJobs(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), restore_id: try payload.decode(String.self, forKey: LWCatalogCodingKey("restore_id")), acknowledge_pending_jobs: try payload.decode(Bool.self, forKey: LWCatalogCodingKey("acknowledge_pending_jobs")))
        case "metadata":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .Metadata(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationMetadataRequest.self, forKey: LWCatalogCodingKey("request")))
        case "metadata_write":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .MetadataWrite(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationMetadataWriteRequest.self, forKey: LWCatalogCodingKey("request")))
        case "organization":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "request"])
            self = .Organization(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), request: try payload.decode(LWApplicationOrganizationRequest.self, forKey: LWCatalogCodingKey("request")))
        case "folders":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "parent", "after", "limit"])
            self = .Folders(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), parent: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("parent")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "images":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "folder", "recursive", "text", "cursor", "limit"])
            self = .Images(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), folder: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("folder")), recursive: try payload.decode(Bool.self, forKey: LWCatalogCodingKey("recursive")), text: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("text")), cursor: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("cursor")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "search":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "options", "cursor", "limit"])
            self = .Search(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), options: try payload.decode(LWApplicationBrowseOptions.self, forKey: LWCatalogCodingKey("options")), cursor: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("cursor")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "image":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key"])
            self = .Image(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")))
        case "variant":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key"])
            self = .Variant(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")))
        case "variants":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "asset_id", "after", "limit"])
            self = .Variants(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), asset_id: try payload.decode(String.self, forKey: LWCatalogCodingKey("asset_id")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "create_variant":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "expected_revision", "label"])
            self = .CreateVariant(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), label: try payload.decode(String.self, forKey: LWCatalogCodingKey("label")))
        case "save_recipe":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "expected_revision", "recipe"])
            self = .SaveRecipe(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), recipe: try payload.decode(LWEditRecipeRecipe.self, forKey: LWCatalogCodingKey("recipe")))
        case "undo":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "expected_revision"])
            self = .Undo(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")))
        case "redo":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "expected_revision"])
            self = .Redo(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")))
        case "history":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "after", "limit"])
            self = .History(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "cull":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "expected_revision", "operation"])
            self = .Cull(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), operation: try payload.decode(LWApplicationDtoCullOperation.self, forKey: LWCatalogCodingKey("operation")))
        case "preview":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "key", "tier", "interactive", "viewport", "generation", "foreground", "diagnostics"])
            self = .Preview(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), tier: try payload.decode(LWApplicationDtoPreviewTier.self, forKey: LWCatalogCodingKey("tier")), interactive: try payload.decode(Bool.self, forKey: LWCatalogCodingKey("interactive")), viewport: try payload.decode(String.self, forKey: LWCatalogCodingKey("viewport")), generation: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation")), foreground: try payload.decode(Bool.self, forKey: LWCatalogCodingKey("foreground")), diagnostics: try payload.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("diagnostics")) ?? false)
        case "preview_status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "ticket"])
            self = .PreviewStatus(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), ticket: try payload.decode(String.self, forKey: LWCatalogCodingKey("ticket")))
        case "release_viewport":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "viewport", "generation"])
            self = .ReleaseViewport(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), viewport: try payload.decode(String.self, forKey: LWCatalogCodingKey("viewport")), generation: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation")))
        case "cancel_preview":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["catalog", "ticket"])
            self = .CancelPreview(catalog: try payload.decode(String.self, forKey: LWCatalogCodingKey("catalog")), ticket: try payload.decode(String.self, forKey: LWCatalogCodingKey("ticket")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationDtoRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .PreviewSettings(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("preview_settings", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .LightroomMigration(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("lightroom_migration", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("request"))
        case .Lightroom(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("lightroom", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("request"))
        case .Export(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("export", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .EditCopy(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("edit_copy", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .Relink(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("relink", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .OpenExisting(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("open_existing", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("path"))
        case .Create(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("create", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("path"))
        case .Status:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("command"))
        case .Close(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("close", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
        case .ImportStart(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_start", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("source"))
        case .ImportResume(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_resume", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("source"))
        case .ImportStatus(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
        case .ImportCancel(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("import"))
        case .BackupCreate(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup_create", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("bundle"))
        case .BackupInspect(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup_inspect", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("bundle"))
        case .BackupRestore(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup_restore", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("bundle"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destination"))
        case .BackupStatus:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup_status", forKey: LWCatalogCodingKey("command"))
        case .BackupCancel(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup_cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .RestoreStatus(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore_status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
        case .ResumeRestoredJobs(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("resume_restored_jobs", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("restore_id"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("acknowledge_pending_jobs"))
        case .Metadata(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("metadata", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .MetadataWrite(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("metadata_write", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .Organization(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("organization", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("request"))
        case .Folders(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("folders", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("parent"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Images(let value0, let value1, let value2, let value3, let value4, let value5):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("images", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("folder"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("recursive"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("text"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("cursor"))
            try payload.encode(value5, forKey: LWCatalogCodingKey("limit"))
        case .Search(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("search", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("options"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("cursor"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Image(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("image", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
        case .Variant(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("variant", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
        case .Variants(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("variants", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("asset_id"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .CreateVariant(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("create_variant", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("label"))
        case .SaveRecipe(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("save_recipe", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("recipe"))
        case .Undo(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("undo", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("expected_revision"))
        case .Redo(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("redo", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("expected_revision"))
        case .History(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("history", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Cull(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cull", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("operation"))
        case .Preview(let value0, let value1, let value2, let value3, let value4, let value5, let value6, let value7):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("preview", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("tier"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("interactive"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("viewport"))
            try payload.encode(value5, forKey: LWCatalogCodingKey("generation"))
            try payload.encode(value6, forKey: LWCatalogCodingKey("foreground"))
            try payload.encode(value7, forKey: LWCatalogCodingKey("diagnostics"))
        case .PreviewStatus(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("preview_status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("ticket"))
        case .ReleaseViewport(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("release_viewport", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("viewport"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("generation"))
        case .CancelPreview(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel_preview", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("catalog"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("ticket"))
        }
    }
}

/// application::dto::Response (engines/catalog/src/application/dto.rs:384).
nonisolated indirect enum LWApplicationDtoResponse: Codable, Sendable {
    case PreviewSettings(LWApplicationPreviewSettingsStatus)
    case LightroomMigration(LWApplicationLightroomMigrationResponse)
    case Lightroom(LWApplicationLightroomBridgeWireResponse)
    case Export(LWApplicationExportsDtoResponse)
    case Metadata(LWApplicationMetadataResponse)
    case MetadataWrite(LWApplicationMetadataWriteResponse)
    case Relink(LWApplicationRelinkResponse)
    case EditCopy(LWApplicationCopyResponse)
    case Organization(LWApplicationOrganizationResponse)
    case Backup(LWApplicationBackupSnapshot?)
    case Restore(LWApplicationDtoRestored?)
    case Status(LWApplicationDtoStatus)
    case Import(LWApplicationDtoImportStatus?)
    case Folders(rows: [LWApplicationDtoFolder], next: LWCatalogI64?)
    case Images(rows: [LWApplicationDtoGridImage], next: String?, has_more: Bool, page_complete: Bool, scanned: UInt32)
    case Image(LWApplicationDtoGridImage)
    case Variant(LWApplicationDtoVariant)
    case Variants(rows: [LWCatalogPair<LWCatalogI64, LWApplicationDtoVariant>], next: LWCatalogI64?)
    case History(rows: [LWApplicationDtoHistoryEntry], next: LWCatalogI64?)
    case Culled(metadata_revision: LWCatalogI64)
    case Preview(LWApplicationDtoPreviewStatus)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "preview_settings":
            self = .PreviewSettings(try container.decode(LWApplicationPreviewSettingsStatus.self, forKey: LWCatalogCodingKey("data")))
        case "lightroom_migration":
            self = .LightroomMigration(try container.decode(LWApplicationLightroomMigrationResponse.self, forKey: LWCatalogCodingKey("data")))
        case "lightroom":
            self = .Lightroom(try container.decode(LWApplicationLightroomBridgeWireResponse.self, forKey: LWCatalogCodingKey("data")))
        case "export":
            self = .Export(try container.decode(LWApplicationExportsDtoResponse.self, forKey: LWCatalogCodingKey("data")))
        case "metadata":
            self = .Metadata(try container.decode(LWApplicationMetadataResponse.self, forKey: LWCatalogCodingKey("data")))
        case "metadata_write":
            self = .MetadataWrite(try container.decode(LWApplicationMetadataWriteResponse.self, forKey: LWCatalogCodingKey("data")))
        case "relink":
            self = .Relink(try container.decode(LWApplicationRelinkResponse.self, forKey: LWCatalogCodingKey("data")))
        case "edit_copy":
            self = .EditCopy(try container.decode(LWApplicationCopyResponse.self, forKey: LWCatalogCodingKey("data")))
        case "organization":
            self = .Organization(try container.decode(LWApplicationOrganizationResponse.self, forKey: LWCatalogCodingKey("data")))
        case "backup":
            self = .Backup(try container.decode(LWApplicationBackupSnapshot?.self, forKey: LWCatalogCodingKey("data")))
        case "restore":
            self = .Restore(try container.decode(LWApplicationDtoRestored?.self, forKey: LWCatalogCodingKey("data")))
        case "status":
            self = .Status(try container.decode(LWApplicationDtoStatus.self, forKey: LWCatalogCodingKey("data")))
        case "import":
            self = .Import(try container.decode(LWApplicationDtoImportStatus?.self, forKey: LWCatalogCodingKey("data")))
        case "folders":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Folders(rows: try payload.decode([LWApplicationDtoFolder].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "images":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Images(rows: try payload.decode([LWApplicationDtoGridImage].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("next")), has_more: try payload.decode(Bool.self, forKey: LWCatalogCodingKey("has_more")), page_complete: try payload.decode(Bool.self, forKey: LWCatalogCodingKey("page_complete")), scanned: try payload.decode(UInt32.self, forKey: LWCatalogCodingKey("scanned")))
        case "image":
            self = .Image(try container.decode(LWApplicationDtoGridImage.self, forKey: LWCatalogCodingKey("data")))
        case "variant":
            self = .Variant(try container.decode(LWApplicationDtoVariant.self, forKey: LWCatalogCodingKey("data")))
        case "variants":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Variants(rows: try payload.decode([LWCatalogPair<LWCatalogI64, LWApplicationDtoVariant>].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "history":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .History(rows: try payload.decode([LWApplicationDtoHistoryEntry].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "culled":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Culled(metadata_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("metadata_revision")))
        case "preview":
            self = .Preview(try container.decode(LWApplicationDtoPreviewStatus.self, forKey: LWCatalogCodingKey("data")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationDtoResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .PreviewSettings(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("preview_settings", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .LightroomMigration(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("lightroom_migration", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Lightroom(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("lightroom", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Export(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("export", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Metadata(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("metadata", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .MetadataWrite(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("metadata_write", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Relink(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("relink", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .EditCopy(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("edit_copy", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Organization(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("organization", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Backup(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("backup", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Restore(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Import(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Folders(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("folders", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Images(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("images", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("has_more"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("page_complete"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("scanned"))
        case .Image(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("image", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Variant(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("variant", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Variants(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("variants", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .History(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("history", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Culled(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("culled", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("metadata_revision"))
        case .Preview(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("preview", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        }
    }
}

/// application::dto::Restored (engines/catalog/src/application/dto.rs:455).
nonisolated struct LWApplicationDtoRestored: Codable, Sendable {
    var receipt: LWApplicationBackupRestoreReceipt
    var jobs_held: Bool
    init(receipt: LWApplicationBackupRestoreReceipt, jobs_held: Bool) {
        self.receipt = receipt
        self.jobs_held = jobs_held
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.receipt = try container.decode(LWApplicationBackupRestoreReceipt.self, forKey: LWCatalogCodingKey("receipt"))
        self.jobs_held = try container.decode(Bool.self, forKey: LWCatalogCodingKey("jobs_held"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(receipt, forKey: LWCatalogCodingKey("receipt"))
        try container.encode(jobs_held, forKey: LWCatalogCodingKey("jobs_held"))
    }
}

/// application::dto::Status (engines/catalog/src/application/dto.rs:242).
nonisolated struct LWApplicationDtoStatus: Codable, Sendable {
    var phase: LWApplicationDtoPhase
    var catalog: String?
    var jobs_held: Bool
    var pending_commands: UInt32
    var active_previews: UInt32
    var cancel_requested: Bool
    var message: String?
    init(phase: LWApplicationDtoPhase, catalog: String?, jobs_held: Bool, pending_commands: UInt32, active_previews: UInt32, cancel_requested: Bool, message: String?) {
        self.phase = phase
        self.catalog = catalog
        self.jobs_held = jobs_held
        self.pending_commands = pending_commands
        self.active_previews = active_previews
        self.cancel_requested = cancel_requested
        self.message = message
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.phase = try container.decode(LWApplicationDtoPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.catalog = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("catalog"))
        self.jobs_held = try container.decode(Bool.self, forKey: LWCatalogCodingKey("jobs_held"))
        self.pending_commands = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("pending_commands"))
        self.active_previews = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("active_previews"))
        self.cancel_requested = try container.decode(Bool.self, forKey: LWCatalogCodingKey("cancel_requested"))
        self.message = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("message"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(catalog, forKey: LWCatalogCodingKey("catalog"))
        try container.encode(jobs_held, forKey: LWCatalogCodingKey("jobs_held"))
        try container.encode(pending_commands, forKey: LWCatalogCodingKey("pending_commands"))
        try container.encode(active_previews, forKey: LWCatalogCodingKey("active_previews"))
        try container.encode(cancel_requested, forKey: LWCatalogCodingKey("cancel_requested"))
        try container.encode(message, forKey: LWCatalogCodingKey("message"))
    }
}

/// application::dto::Variant (engines/catalog/src/application/dto.rs:301).
nonisolated struct LWApplicationDtoVariant: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var label: String
    var revision: LWCatalogI64
    var recipe: LWEditRecipeRecipe
    var recipe_digest: String
    var can_undo: Bool
    var can_redo: Bool
    init(key: LWCatalogEditsVariantKey, label: String, revision: LWCatalogI64, recipe: LWEditRecipeRecipe, recipe_digest: String, can_undo: Bool, can_redo: Bool) {
        self.key = key
        self.label = label
        self.revision = revision
        self.recipe = recipe
        self.recipe_digest = recipe_digest
        self.can_undo = can_undo
        self.can_redo = can_redo
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.label = try container.decode(String.self, forKey: LWCatalogCodingKey("label"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.recipe = try container.decode(LWEditRecipeRecipe.self, forKey: LWCatalogCodingKey("recipe"))
        self.recipe_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("recipe_digest"))
        self.can_undo = try container.decode(Bool.self, forKey: LWCatalogCodingKey("can_undo"))
        self.can_redo = try container.decode(Bool.self, forKey: LWCatalogCodingKey("can_redo"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(label, forKey: LWCatalogCodingKey("label"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(recipe, forKey: LWCatalogCodingKey("recipe"))
        try container.encode(recipe_digest, forKey: LWCatalogCodingKey("recipe_digest"))
        try container.encode(can_undo, forKey: LWCatalogCodingKey("can_undo"))
        try container.encode(can_redo, forKey: LWCatalogCodingKey("can_redo"))
    }
}

/// application::exports::dto::AliasLimits (engines/catalog/src/application/exports/dto.rs:38).
nonisolated struct LWApplicationExportsDtoAliasLimits: Codable, Sendable {
    var directories: LWCatalogU64
    var candidates: LWCatalogU64
    init(directories: LWCatalogU64, candidates: LWCatalogU64) {
        self.directories = directories
        self.candidates = candidates
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["directories", "candidates"])
        self.directories = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("directories"))
        self.candidates = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("candidates"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(directories, forKey: LWCatalogCodingKey("directories"))
        try container.encode(candidates, forKey: LWCatalogCodingKey("candidates"))
    }
}

/// application::exports::dto::Blob (engines/catalog/src/application/exports/dto.rs:386).
nonisolated struct LWApplicationExportsDtoBlob: Codable, Sendable {
    var digest: String
    var bytes: LWCatalogU64
    init(digest: String, bytes: LWCatalogU64) {
        self.digest = digest
        self.bytes = bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.digest = try container.decode(String.self, forKey: LWCatalogCodingKey("digest"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(digest, forKey: LWCatalogCodingKey("digest"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
    }
}

/// application::exports::dto::Budgets (engines/catalog/src/application/exports/dto.rs:44).
nonisolated struct LWApplicationExportsDtoBudgets: Codable, Sendable {
    var max_original_bytes: LWCatalogU64
    var max_payload_bytes: LWCatalogU64
    var alias_limits: LWApplicationExportsDtoAliasLimits
    init(max_original_bytes: LWCatalogU64, max_payload_bytes: LWCatalogU64, alias_limits: LWApplicationExportsDtoAliasLimits) {
        self.max_original_bytes = max_original_bytes
        self.max_payload_bytes = max_payload_bytes
        self.alias_limits = alias_limits
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["max_original_bytes", "max_payload_bytes", "alias_limits"])
        self.max_original_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_original_bytes"))
        self.max_payload_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_payload_bytes"))
        self.alias_limits = try container.decode(LWApplicationExportsDtoAliasLimits.self, forKey: LWCatalogCodingKey("alias_limits"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(max_original_bytes, forKey: LWCatalogCodingKey("max_original_bytes"))
        try container.encode(max_payload_bytes, forKey: LWCatalogCodingKey("max_payload_bytes"))
        try container.encode(alias_limits, forKey: LWCatalogCodingKey("alias_limits"))
    }
}

/// application::exports::dto::DecodeLimits (engines/catalog/src/application/exports/dto.rs:58).
nonisolated struct LWApplicationExportsDtoDecodeLimits: Codable, Sendable {
    var max_encoded_bytes: LWCatalogU64
    var max_intermediate_pixels: LWCatalogU64
    var max_allocation_bytes: LWCatalogU64
    init(max_encoded_bytes: LWCatalogU64, max_intermediate_pixels: LWCatalogU64, max_allocation_bytes: LWCatalogU64) {
        self.max_encoded_bytes = max_encoded_bytes
        self.max_intermediate_pixels = max_intermediate_pixels
        self.max_allocation_bytes = max_allocation_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["max_encoded_bytes", "max_intermediate_pixels", "max_allocation_bytes"])
        self.max_encoded_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_encoded_bytes"))
        self.max_intermediate_pixels = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_intermediate_pixels"))
        self.max_allocation_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_allocation_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(max_encoded_bytes, forKey: LWCatalogCodingKey("max_encoded_bytes"))
        try container.encode(max_intermediate_pixels, forKey: LWCatalogCodingKey("max_intermediate_pixels"))
        try container.encode(max_allocation_bytes, forKey: LWCatalogCodingKey("max_allocation_bytes"))
    }
}

/// application::exports::dto::Destination (engines/catalog/src/application/exports/dto.rs:442).
nonisolated struct LWApplicationExportsDtoDestination: Codable, Sendable {
    var target: LWApplicationExportsDtoTargetKey
    var name: LWApplicationExportsDtoName
    var destination: LWCatalogNativePath?
    var error: String?
    init(target: LWApplicationExportsDtoTargetKey, name: LWApplicationExportsDtoName, destination: LWCatalogNativePath?, error: String?) {
        self.target = target
        self.name = name
        self.destination = destination
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.target = try container.decode(LWApplicationExportsDtoTargetKey.self, forKey: LWCatalogCodingKey("target"))
        self.name = try container.decode(LWApplicationExportsDtoName.self, forKey: LWCatalogCodingKey("name"))
        self.destination = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(target, forKey: LWCatalogCodingKey("target"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::exports::dto::DestinationSnapshot (engines/catalog/src/application/exports/dto.rs:391).
nonisolated struct LWApplicationExportsDtoDestinationSnapshot: Codable, Sendable {
    var version: UInt32
    var operation: String
    var destination: LWCatalogNativePath
    var expected: LWApplicationExportsDtoFileRevision?
    var max_existing_bytes: LWCatalogU64
    init(version: UInt32, operation: String, destination: LWCatalogNativePath, expected: LWApplicationExportsDtoFileRevision?, max_existing_bytes: LWCatalogU64) {
        self.version = version
        self.operation = operation
        self.destination = destination
        self.expected = expected
        self.max_existing_bytes = max_existing_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.version = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("version"))
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        self.destination = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.expected = try container.decodeIfPresent(LWApplicationExportsDtoFileRevision.self, forKey: LWCatalogCodingKey("expected"))
        self.max_existing_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_existing_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(version, forKey: LWCatalogCodingKey("version"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(expected, forKey: LWCatalogCodingKey("expected"))
        try container.encode(max_existing_bytes, forKey: LWCatalogCodingKey("max_existing_bytes"))
    }
}

/// application::exports::dto::EncodeLimits (engines/catalog/src/application/exports/dto.rs:65).
nonisolated struct LWApplicationExportsDtoEncodeLimits: Codable, Sendable {
    var render: LWApplicationExportsDtoRenderLimits
    var max_metadata_bytes: LWCatalogU64
    var row_buffer_bytes: LWCatalogU64
    init(render: LWApplicationExportsDtoRenderLimits, max_metadata_bytes: LWCatalogU64, row_buffer_bytes: LWCatalogU64) {
        self.render = render
        self.max_metadata_bytes = max_metadata_bytes
        self.row_buffer_bytes = row_buffer_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["render", "max_metadata_bytes", "row_buffer_bytes"])
        self.render = try container.decode(LWApplicationExportsDtoRenderLimits.self, forKey: LWCatalogCodingKey("render"))
        self.max_metadata_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_metadata_bytes"))
        self.row_buffer_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("row_buffer_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(render, forKey: LWCatalogCodingKey("render"))
        try container.encode(max_metadata_bytes, forKey: LWCatalogCodingKey("max_metadata_bytes"))
        try container.encode(row_buffer_bytes, forKey: LWCatalogCodingKey("row_buffer_bytes"))
    }
}

/// application::exports::dto::ExecutionLimits (engines/catalog/src/application/exports/dto.rs:80).
nonisolated struct LWApplicationExportsDtoExecutionLimits: Codable, Sendable {
    var worker_bytes: LWCatalogU64
    var working_bytes: LWCatalogU64
    var render: LWApplicationExportsDtoPhotoLimits
    init(worker_bytes: LWCatalogU64, working_bytes: LWCatalogU64, render: LWApplicationExportsDtoPhotoLimits) {
        self.worker_bytes = worker_bytes
        self.working_bytes = working_bytes
        self.render = render
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["worker_bytes", "working_bytes", "render"])
        self.worker_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("worker_bytes"))
        self.working_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("working_bytes"))
        self.render = try container.decode(LWApplicationExportsDtoPhotoLimits.self, forKey: LWCatalogCodingKey("render"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(worker_bytes, forKey: LWCatalogCodingKey("worker_bytes"))
        try container.encode(working_bytes, forKey: LWCatalogCodingKey("working_bytes"))
        try container.encode(render, forKey: LWCatalogCodingKey("render"))
    }
}

/// application::exports::dto::FileRevision (engines/catalog/src/application/exports/dto.rs:295).
nonisolated struct LWApplicationExportsDtoFileRevision: Codable, Sendable {
    var bytes: LWCatalogU64
    var digest: String
    var modified_ns: LWCatalogU128
    var identity: LWCatalogPair<LWCatalogU64, LWCatalogU64>
    init(bytes: LWCatalogU64, digest: String, modified_ns: LWCatalogU128, identity: LWCatalogPair<LWCatalogU64, LWCatalogU64>) {
        self.bytes = bytes
        self.digest = digest
        self.modified_ns = modified_ns
        self.identity = identity
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.digest = try container.decode(String.self, forKey: LWCatalogCodingKey("digest"))
        self.modified_ns = try container.decode(LWCatalogU128.self, forKey: LWCatalogCodingKey("modified_ns"))
        self.identity = try container.decode(LWCatalogPair<LWCatalogU64, LWCatalogU64>.self, forKey: LWCatalogCodingKey("identity"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(digest, forKey: LWCatalogCodingKey("digest"))
        try container.encode(modified_ns, forKey: LWCatalogCodingKey("modified_ns"))
        try container.encode(identity, forKey: LWCatalogCodingKey("identity"))
    }
}

/// application::exports::dto::ImageIdentity (engines/catalog/src/application/exports/dto.rs:343).
nonisolated struct LWApplicationExportsDtoImageIdentity: Codable, Sendable {
    var image_id: String
    var key: LWCatalogEditsVariantKey
    var metadata_revision: LWCatalogI64
    var pixel_generation: LWCatalogI64
    var shared_source_epoch: LWCatalogI64
    var physical_generation: LWCatalogI64
    init(image_id: String, key: LWCatalogEditsVariantKey, metadata_revision: LWCatalogI64, pixel_generation: LWCatalogI64, shared_source_epoch: LWCatalogI64, physical_generation: LWCatalogI64) {
        self.image_id = image_id
        self.key = key
        self.metadata_revision = metadata_revision
        self.pixel_generation = pixel_generation
        self.shared_source_epoch = shared_source_epoch
        self.physical_generation = physical_generation
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.image_id = try container.decode(String.self, forKey: LWCatalogCodingKey("image_id"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.metadata_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("metadata_revision"))
        self.pixel_generation = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("pixel_generation"))
        self.shared_source_epoch = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("shared_source_epoch"))
        self.physical_generation = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("physical_generation"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(image_id, forKey: LWCatalogCodingKey("image_id"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(metadata_revision, forKey: LWCatalogCodingKey("metadata_revision"))
        try container.encode(pixel_generation, forKey: LWCatalogCodingKey("pixel_generation"))
        try container.encode(shared_source_epoch, forKey: LWCatalogCodingKey("shared_source_epoch"))
        try container.encode(physical_generation, forKey: LWCatalogCodingKey("physical_generation"))
    }
}

/// application::exports::dto::Item (engines/catalog/src/application/exports/dto.rs:331).
nonisolated struct LWApplicationExportsDtoItem: Codable, Sendable {
    var sequence: LWCatalogI64
    var key: LWCatalogEditsVariantKey
    var name: LWApplicationExportsDtoName
    var destination: LWCatalogNativePath
    var state: String
    var attempt: String?
    var authority: String
    var error: String?
    var receipt: LWApplicationExportsDtoReceipt?
    init(sequence: LWCatalogI64, key: LWCatalogEditsVariantKey, name: LWApplicationExportsDtoName, destination: LWCatalogNativePath, state: String, attempt: String?, authority: String, error: String?, receipt: LWApplicationExportsDtoReceipt?) {
        self.sequence = sequence
        self.key = key
        self.name = name
        self.destination = destination
        self.state = state
        self.attempt = attempt
        self.authority = authority
        self.error = error
        self.receipt = receipt
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.name = try container.decode(LWApplicationExportsDtoName.self, forKey: LWCatalogCodingKey("name"))
        self.destination = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.attempt = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.authority = try container.decode(String.self, forKey: LWCatalogCodingKey("authority"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
        self.receipt = try container.decodeIfPresent(LWApplicationExportsDtoReceipt.self, forKey: LWCatalogCodingKey("receipt"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try container.encode(authority, forKey: LWCatalogCodingKey("authority"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
        try container.encode(receipt, forKey: LWCatalogCodingKey("receipt"))
    }
}

/// application::exports::dto::Job (engines/catalog/src/application/exports/dto.rs:270).
nonisolated struct LWApplicationExportsDtoJob: Codable, Sendable {
    var sequence: LWCatalogI64
    var id: String
    var state: String
    var total: LWCatalogI64
    var completed: LWCatalogI64
    init(sequence: LWCatalogI64, id: String, state: String, total: LWCatalogI64, completed: LWCatalogI64) {
        self.sequence = sequence
        self.id = id
        self.state = state
        self.total = total
        self.completed = completed
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.total = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("total"))
        self.completed = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("completed"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(total, forKey: LWCatalogCodingKey("total"))
        try container.encode(completed, forKey: LWCatalogCodingKey("completed"))
    }
}

/// application::exports::dto::Metadata (engines/catalog/src/application/exports/dto.rs:99).
nonisolated indirect enum LWApplicationExportsDtoMetadata: Codable, Sendable {
    case Omit
    case Resolved(expected_revision: LWCatalogI64, base_model: LWCatalogI64?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("mode"))
        switch discriminator {
        case "omit":
            try container.lwRequireKeys(["mode"])
            self = .Omit
        case "resolved":
            try container.lwRequireKeys(["mode", "expected_revision", "base_model"])
            self = .Resolved(expected_revision: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), base_model: try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("base_model")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationExportsDtoMetadata variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Omit:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("omit", forKey: LWCatalogCodingKey("mode"))
        case .Resolved(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("resolved", forKey: LWCatalogCodingKey("mode"))
            try container.encode(value0, forKey: LWCatalogCodingKey("expected_revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("base_model"))
        }
    }
}

/// application::exports::dto::Name (engines/catalog/src/application/exports/dto.rs:289).
nonisolated struct LWApplicationExportsDtoName: Codable, Sendable {
    var filename: String
    var variant_label: String
    var available: Bool
    init(filename: String, variant_label: String, available: Bool) {
        self.filename = filename
        self.variant_label = variant_label
        self.available = available
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.filename = try container.decode(String.self, forKey: LWCatalogCodingKey("filename"))
        self.variant_label = try container.decode(String.self, forKey: LWCatalogCodingKey("variant_label"))
        self.available = try container.decode(Bool.self, forKey: LWCatalogCodingKey("available"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(filename, forKey: LWCatalogCodingKey("filename"))
        try container.encode(variant_label, forKey: LWCatalogCodingKey("variant_label"))
        try container.encode(available, forKey: LWCatalogCodingKey("available"))
    }
}

/// application::exports::dto::Naming (engines/catalog/src/application/exports/dto.rs:123).
nonisolated struct LWApplicationExportsDtoNaming: Codable, Sendable {
    var prefix: String
    var suffix: String
    var variant_suffix: Bool
    var sequence_start: LWCatalogU64?
    init(prefix: String, suffix: String, variant_suffix: Bool, sequence_start: LWCatalogU64?) {
        self.prefix = prefix
        self.suffix = suffix
        self.variant_suffix = variant_suffix
        self.sequence_start = sequence_start
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["prefix", "suffix", "variant_suffix", "sequence_start"])
        self.prefix = try container.decode(String.self, forKey: LWCatalogCodingKey("prefix"))
        self.suffix = try container.decode(String.self, forKey: LWCatalogCodingKey("suffix"))
        self.variant_suffix = try container.decode(Bool.self, forKey: LWCatalogCodingKey("variant_suffix"))
        self.sequence_start = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("sequence_start"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(prefix, forKey: LWCatalogCodingKey("prefix"))
        try container.encode(suffix, forKey: LWCatalogCodingKey("suffix"))
        try container.encode(variant_suffix, forKey: LWCatalogCodingKey("variant_suffix"))
        try container.encode(sequence_start, forKey: LWCatalogCodingKey("sequence_start"))
    }
}

/// application::exports::dto::Operation (engines/catalog/src/application/exports/dto.rs:476).
nonisolated struct LWApplicationExportsDtoOperation: Codable, Sendable {
    var id: String
    var kind: String
    var phase: String
    var job: LWApplicationExportsDtoJob?
    var sequence: LWCatalogI64?
    var stage: String
    var stream_bytes: LWCatalogU64?
    var processed: LWCatalogU64
    var write_hold: Bool
    var result: LWApplicationExportsDtoResultValue?
    var error: String?
    init(id: String, kind: String, phase: String, job: LWApplicationExportsDtoJob?, sequence: LWCatalogI64?, stage: String, stream_bytes: LWCatalogU64?, processed: LWCatalogU64, write_hold: Bool, result: LWApplicationExportsDtoResultValue?, error: String?) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.job = job
        self.sequence = sequence
        self.stage = stage
        self.stream_bytes = stream_bytes
        self.processed = processed
        self.write_hold = write_hold
        self.result = result
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.kind = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        self.phase = try container.decode(String.self, forKey: LWCatalogCodingKey("phase"))
        self.job = try container.decodeIfPresent(LWApplicationExportsDtoJob.self, forKey: LWCatalogCodingKey("job"))
        self.sequence = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.stage = try container.decode(String.self, forKey: LWCatalogCodingKey("stage"))
        self.stream_bytes = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("stream_bytes"))
        self.processed = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("processed"))
        self.write_hold = try container.decode(Bool.self, forKey: LWCatalogCodingKey("write_hold"))
        self.result = try container.decodeIfPresent(LWApplicationExportsDtoResultValue.self, forKey: LWCatalogCodingKey("result"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(job, forKey: LWCatalogCodingKey("job"))
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(stage, forKey: LWCatalogCodingKey("stage"))
        try container.encode(stream_bytes, forKey: LWCatalogCodingKey("stream_bytes"))
        try container.encode(processed, forKey: LWCatalogCodingKey("processed"))
        try container.encode(write_hold, forKey: LWCatalogCodingKey("write_hold"))
        try container.encode(result, forKey: LWCatalogCodingKey("result"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::exports::dto::Options (engines/catalog/src/application/exports/dto.rs:86).
nonisolated struct LWApplicationExportsDtoOptions: Codable, Sendable {
    var budgets: LWApplicationExportsDtoBudgets
    var execution: LWApplicationExportsDtoExecutionLimits
    var page_rows: LWCatalogU64
    var page_bytes: LWCatalogU64
    var path_bytes: LWCatalogU64
    var profile_bytes: LWCatalogU64
    var profile_tokens: LWCatalogU64
    var profile_total_bytes: LWCatalogU64
    var result_rows: LWCatalogU64
    init(budgets: LWApplicationExportsDtoBudgets, execution: LWApplicationExportsDtoExecutionLimits, page_rows: LWCatalogU64, page_bytes: LWCatalogU64, path_bytes: LWCatalogU64, profile_bytes: LWCatalogU64, profile_tokens: LWCatalogU64, profile_total_bytes: LWCatalogU64, result_rows: LWCatalogU64) {
        self.budgets = budgets
        self.execution = execution
        self.page_rows = page_rows
        self.page_bytes = page_bytes
        self.path_bytes = path_bytes
        self.profile_bytes = profile_bytes
        self.profile_tokens = profile_tokens
        self.profile_total_bytes = profile_total_bytes
        self.result_rows = result_rows
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.budgets = try container.decode(LWApplicationExportsDtoBudgets.self, forKey: LWCatalogCodingKey("budgets"))
        self.execution = try container.decode(LWApplicationExportsDtoExecutionLimits.self, forKey: LWCatalogCodingKey("execution"))
        self.page_rows = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("page_rows"))
        self.page_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("page_bytes"))
        self.path_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("path_bytes"))
        self.profile_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("profile_bytes"))
        self.profile_tokens = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("profile_tokens"))
        self.profile_total_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("profile_total_bytes"))
        self.result_rows = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("result_rows"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(budgets, forKey: LWCatalogCodingKey("budgets"))
        try container.encode(execution, forKey: LWCatalogCodingKey("execution"))
        try container.encode(page_rows, forKey: LWCatalogCodingKey("page_rows"))
        try container.encode(page_bytes, forKey: LWCatalogCodingKey("page_bytes"))
        try container.encode(path_bytes, forKey: LWCatalogCodingKey("path_bytes"))
        try container.encode(profile_bytes, forKey: LWCatalogCodingKey("profile_bytes"))
        try container.encode(profile_tokens, forKey: LWCatalogCodingKey("profile_tokens"))
        try container.encode(profile_total_bytes, forKey: LWCatalogCodingKey("profile_total_bytes"))
        try container.encode(result_rows, forKey: LWCatalogCodingKey("result_rows"))
    }
}

/// application::exports::dto::Output (engines/catalog/src/application/exports/dto.rs:30).
nonisolated struct LWApplicationExportsDtoOutput: Codable, Sendable {
    var size: LWImageExportSpecificationOutputSize
    var format: LWImageExportSpecificationOutputFormat
    var profile: LWApplicationExportsDtoProfile
    var alpha: LWImageExportSpecificationAlphaPolicy
    init(size: LWImageExportSpecificationOutputSize, format: LWImageExportSpecificationOutputFormat, profile: LWApplicationExportsDtoProfile, alpha: LWImageExportSpecificationAlphaPolicy) {
        self.size = size
        self.format = format
        self.profile = profile
        self.alpha = alpha
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["size", "format", "profile", "alpha"])
        self.size = try container.decode(LWImageExportSpecificationOutputSize.self, forKey: LWCatalogCodingKey("size"))
        self.format = try container.decode(LWImageExportSpecificationOutputFormat.self, forKey: LWCatalogCodingKey("format"))
        self.profile = try container.decode(LWApplicationExportsDtoProfile.self, forKey: LWCatalogCodingKey("profile"))
        self.alpha = try container.decode(LWImageExportSpecificationAlphaPolicy.self, forKey: LWCatalogCodingKey("alpha"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(size, forKey: LWCatalogCodingKey("size"))
        try container.encode(format, forKey: LWCatalogCodingKey("format"))
        try container.encode(profile, forKey: LWCatalogCodingKey("profile"))
        try container.encode(alpha, forKey: LWCatalogCodingKey("alpha"))
    }
}

/// application::exports::dto::Paths (engines/catalog/src/application/exports/dto.rs:436).
nonisolated struct LWApplicationExportsDtoPaths: Codable, Sendable {
    var projected: LWCatalogU64
    var pending: Bool
    var unbound: LWCatalogU64
    init(projected: LWCatalogU64, pending: Bool, unbound: LWCatalogU64) {
        self.projected = projected
        self.pending = pending
        self.unbound = unbound
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.projected = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("projected"))
        self.pending = try container.decode(Bool.self, forKey: LWCatalogCodingKey("pending"))
        self.unbound = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("unbound"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(projected, forKey: LWCatalogCodingKey("projected"))
        try container.encode(pending, forKey: LWCatalogCodingKey("pending"))
        try container.encode(unbound, forKey: LWCatalogCodingKey("unbound"))
    }
}

/// application::exports::dto::PhotoLimits (engines/catalog/src/application/exports/dto.rs:72).
nonisolated struct LWApplicationExportsDtoPhotoLimits: Codable, Sendable {
    var decode: LWApplicationExportsDtoDecodeLimits
    var render: LWApplicationExportsDtoRenderLimits
    var encode: LWApplicationExportsDtoEncodeLimits
    var max_encoded_extent: LWCatalogU64
    init(decode: LWApplicationExportsDtoDecodeLimits, render: LWApplicationExportsDtoRenderLimits, encode: LWApplicationExportsDtoEncodeLimits, max_encoded_extent: LWCatalogU64) {
        self.decode = decode
        self.render = render
        self.encode = encode
        self.max_encoded_extent = max_encoded_extent
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["decode", "render", "encode", "max_encoded_extent"])
        self.decode = try container.decode(LWApplicationExportsDtoDecodeLimits.self, forKey: LWCatalogCodingKey("decode"))
        self.render = try container.decode(LWApplicationExportsDtoRenderLimits.self, forKey: LWCatalogCodingKey("render"))
        self.encode = try container.decode(LWApplicationExportsDtoEncodeLimits.self, forKey: LWCatalogCodingKey("encode"))
        self.max_encoded_extent = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_encoded_extent"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(decode, forKey: LWCatalogCodingKey("decode"))
        try container.encode(render, forKey: LWCatalogCodingKey("render"))
        try container.encode(encode, forKey: LWCatalogCodingKey("encode"))
        try container.encode(max_encoded_extent, forKey: LWCatalogCodingKey("max_encoded_extent"))
    }
}

/// application::exports::dto::Plan (engines/catalog/src/application/exports/dto.rs:399).
nonisolated struct LWApplicationExportsDtoPlan: Codable, Sendable {
    var job: String
    var sequence: LWCatalogI64
    var authority: String
    var plan_bytes: LWCatalogU64
    var version: UInt32
    var renderer_identity: String
    var name: LWApplicationExportsDtoName
    var identity: LWApplicationExportsDtoRenderIdentity
    var original: LWCatalogNativePath
    var original_revision: LWApplicationExportsDtoFileRevision
    var output: LWApplicationExportsDtoStoredOutput
    var metadata: LWApplicationExportsDtoMetadata
    var xmp_blob: LWApplicationExportsDtoBlob?
    var destination: LWApplicationExportsDtoDestinationSnapshot
    var budgets: LWApplicationExportsDtoBudgets
    var item: LWApplicationExportsDtoItem
    init(job: String, sequence: LWCatalogI64, authority: String, plan_bytes: LWCatalogU64, version: UInt32, renderer_identity: String, name: LWApplicationExportsDtoName, identity: LWApplicationExportsDtoRenderIdentity, original: LWCatalogNativePath, original_revision: LWApplicationExportsDtoFileRevision, output: LWApplicationExportsDtoStoredOutput, metadata: LWApplicationExportsDtoMetadata, xmp_blob: LWApplicationExportsDtoBlob?, destination: LWApplicationExportsDtoDestinationSnapshot, budgets: LWApplicationExportsDtoBudgets, item: LWApplicationExportsDtoItem) {
        self.job = job
        self.sequence = sequence
        self.authority = authority
        self.plan_bytes = plan_bytes
        self.version = version
        self.renderer_identity = renderer_identity
        self.name = name
        self.identity = identity
        self.original = original
        self.original_revision = original_revision
        self.output = output
        self.metadata = metadata
        self.xmp_blob = xmp_blob
        self.destination = destination
        self.budgets = budgets
        self.item = item
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.job = try container.decode(String.self, forKey: LWCatalogCodingKey("job"))
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.authority = try container.decode(String.self, forKey: LWCatalogCodingKey("authority"))
        self.plan_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("plan_bytes"))
        self.version = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("version"))
        self.renderer_identity = try container.decode(String.self, forKey: LWCatalogCodingKey("renderer_identity"))
        self.name = try container.decode(LWApplicationExportsDtoName.self, forKey: LWCatalogCodingKey("name"))
        self.identity = try container.decode(LWApplicationExportsDtoRenderIdentity.self, forKey: LWCatalogCodingKey("identity"))
        self.original = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("original"))
        self.original_revision = try container.decode(LWApplicationExportsDtoFileRevision.self, forKey: LWCatalogCodingKey("original_revision"))
        self.output = try container.decode(LWApplicationExportsDtoStoredOutput.self, forKey: LWCatalogCodingKey("output"))
        self.metadata = try container.decode(LWApplicationExportsDtoMetadata.self, forKey: LWCatalogCodingKey("metadata"))
        self.xmp_blob = try container.decodeIfPresent(LWApplicationExportsDtoBlob.self, forKey: LWCatalogCodingKey("xmp_blob"))
        self.destination = try container.decode(LWApplicationExportsDtoDestinationSnapshot.self, forKey: LWCatalogCodingKey("destination"))
        self.budgets = try container.decode(LWApplicationExportsDtoBudgets.self, forKey: LWCatalogCodingKey("budgets"))
        self.item = try container.decode(LWApplicationExportsDtoItem.self, forKey: LWCatalogCodingKey("item"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(job, forKey: LWCatalogCodingKey("job"))
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(authority, forKey: LWCatalogCodingKey("authority"))
        try container.encode(plan_bytes, forKey: LWCatalogCodingKey("plan_bytes"))
        try container.encode(version, forKey: LWCatalogCodingKey("version"))
        try container.encode(renderer_identity, forKey: LWCatalogCodingKey("renderer_identity"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(identity, forKey: LWCatalogCodingKey("identity"))
        try container.encode(original, forKey: LWCatalogCodingKey("original"))
        try container.encode(original_revision, forKey: LWCatalogCodingKey("original_revision"))
        try container.encode(output, forKey: LWCatalogCodingKey("output"))
        try container.encode(metadata, forKey: LWCatalogCodingKey("metadata"))
        try container.encode(xmp_blob, forKey: LWCatalogCodingKey("xmp_blob"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(budgets, forKey: LWCatalogCodingKey("budgets"))
        try container.encode(item, forKey: LWCatalogCodingKey("item"))
    }
}

/// application::exports::dto::PlanChunk (engines/catalog/src/application/exports/dto.rs:418).
nonisolated struct LWApplicationExportsDtoPlanChunk: Codable, Sendable {
    var job: String
    var sequence: LWCatalogI64
    var authority: String
    var offset: LWCatalogU64
    var next: LWCatalogU64?
    var total_bytes: LWCatalogU64
    var text: String
    init(job: String, sequence: LWCatalogI64, authority: String, offset: LWCatalogU64, next: LWCatalogU64?, total_bytes: LWCatalogU64, text: String) {
        self.job = job
        self.sequence = sequence
        self.authority = authority
        self.offset = offset
        self.next = next
        self.total_bytes = total_bytes
        self.text = text
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.job = try container.decode(String.self, forKey: LWCatalogCodingKey("job"))
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.authority = try container.decode(String.self, forKey: LWCatalogCodingKey("authority"))
        self.offset = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset"))
        self.next = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next"))
        self.total_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_bytes"))
        self.text = try container.decode(String.self, forKey: LWCatalogCodingKey("text"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(job, forKey: LWCatalogCodingKey("job"))
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(authority, forKey: LWCatalogCodingKey("authority"))
        try container.encode(offset, forKey: LWCatalogCodingKey("offset"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(total_bytes, forKey: LWCatalogCodingKey("total_bytes"))
        try container.encode(text, forKey: LWCatalogCodingKey("text"))
    }
}

/// application::exports::dto::Profile (engines/catalog/src/application/exports/dto.rs:23).
nonisolated indirect enum LWApplicationExportsDtoProfile: Codable, Sendable {
    case Srgb
    case LinearSrgb
    case Icc(token: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "srgb":
            try container.lwRequireKeys(["kind"])
            self = .Srgb
        case "linear_srgb":
            try container.lwRequireKeys(["kind"])
            self = .LinearSrgb
        case "icc":
            try container.lwRequireKeys(["kind", "token"])
            self = .Icc(token: try container.decode(String.self, forKey: LWCatalogCodingKey("token")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationExportsDtoProfile variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Srgb:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("srgb", forKey: LWCatalogCodingKey("kind"))
        case .LinearSrgb:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("linear_srgb", forKey: LWCatalogCodingKey("kind"))
        case .Icc(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("icc", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("token"))
        }
    }
}

/// application::exports::dto::ProfileAdmission (engines/catalog/src/application/exports/dto.rs:428).
nonisolated struct LWApplicationExportsDtoProfileAdmission: Codable, Sendable {
    var token: String
    var name: String
    var bytes: LWCatalogU64
    var blake3: String
    var linear: Bool
    init(token: String, name: String, bytes: LWCatalogU64, blake3: String, linear: Bool) {
        self.token = token
        self.name = name
        self.bytes = bytes
        self.blake3 = blake3
        self.linear = linear
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.token = try container.decode(String.self, forKey: LWCatalogCodingKey("token"))
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.linear = try container.decode(Bool.self, forKey: LWCatalogCodingKey("linear"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(token, forKey: LWCatalogCodingKey("token"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(linear, forKey: LWCatalogCodingKey("linear"))
    }
}

/// application::exports::dto::Receipt (engines/catalog/src/application/exports/dto.rs:312).
nonisolated struct LWApplicationExportsDtoReceipt: Codable, Sendable {
    var state: String
    var destination: LWCatalogNativePath
    var recovery_directory: LWCatalogNativePath
    var captured_original: LWCatalogNativePath?
    var detail: String
    init(state: String, destination: LWCatalogNativePath, recovery_directory: LWCatalogNativePath, captured_original: LWCatalogNativePath?, detail: String) {
        self.state = state
        self.destination = destination
        self.recovery_directory = recovery_directory
        self.captured_original = captured_original
        self.detail = detail
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.destination = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.recovery_directory = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("recovery_directory"))
        self.captured_original = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("captured_original"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(recovery_directory, forKey: LWCatalogCodingKey("recovery_directory"))
        try container.encode(captured_original, forKey: LWCatalogCodingKey("captured_original"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
    }
}

/// application::exports::dto::Recovery (engines/catalog/src/application/exports/dto.rs:449).
nonisolated struct LWApplicationExportsDtoRecovery: Codable, Sendable {
    var fenced: LWCatalogU64
    var complete: Bool
    init(fenced: LWCatalogU64, complete: Bool) {
        self.fenced = fenced
        self.complete = complete
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.fenced = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("fenced"))
        self.complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("complete"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(fenced, forKey: LWCatalogCodingKey("fenced"))
        try container.encode(complete, forKey: LWCatalogCodingKey("complete"))
    }
}

/// application::exports::dto::RenderIdentity (engines/catalog/src/application/exports/dto.rs:360).
nonisolated struct LWApplicationExportsDtoRenderIdentity: Codable, Sendable {
    var image_identity: LWApplicationExportsDtoImageIdentity?
    var source: LWApplicationExportsDtoSourceIdentity
    var key: LWCatalogEditsVariantKey
    var revision: LWCatalogI64
    var recipe_digest: String
    init(image_identity: LWApplicationExportsDtoImageIdentity?, source: LWApplicationExportsDtoSourceIdentity, key: LWCatalogEditsVariantKey, revision: LWCatalogI64, recipe_digest: String) {
        self.image_identity = image_identity
        self.source = source
        self.key = key
        self.revision = revision
        self.recipe_digest = recipe_digest
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.image_identity = try container.decodeIfPresent(LWApplicationExportsDtoImageIdentity.self, forKey: LWCatalogCodingKey("image_identity"))
        self.source = try container.decode(LWApplicationExportsDtoSourceIdentity.self, forKey: LWCatalogCodingKey("source"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.recipe_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("recipe_digest"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(image_identity, forKey: LWCatalogCodingKey("image_identity"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(recipe_digest, forKey: LWCatalogCodingKey("recipe_digest"))
    }
}

/// application::exports::dto::RenderLimits (engines/catalog/src/application/exports/dto.rs:51).
nonisolated struct LWApplicationExportsDtoRenderLimits: Codable, Sendable {
    var max_pixels: LWCatalogU64
    var max_allocation_bytes: LWCatalogU64
    var max_live_bytes: LWCatalogU64
    init(max_pixels: LWCatalogU64, max_allocation_bytes: LWCatalogU64, max_live_bytes: LWCatalogU64) {
        self.max_pixels = max_pixels
        self.max_allocation_bytes = max_allocation_bytes
        self.max_live_bytes = max_live_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["max_pixels", "max_allocation_bytes", "max_live_bytes"])
        self.max_pixels = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_pixels"))
        self.max_allocation_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_allocation_bytes"))
        self.max_live_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_live_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(max_pixels, forKey: LWCatalogCodingKey("max_pixels"))
        try container.encode(max_allocation_bytes, forKey: LWCatalogCodingKey("max_allocation_bytes"))
        try container.encode(max_live_bytes, forKey: LWCatalogCodingKey("max_live_bytes"))
    }
}

/// application::exports::dto::Request (engines/catalog/src/application/exports/dto.rs:136).
nonisolated indirect enum LWApplicationExportsDtoRequest: Codable, Sendable {
    case Options
    case Profile(path: LWCatalogNativePath)
    case ProfileRelease(token: String)
    case Begin
    case Paths(limit: LWCatalogU64)
    case Destinations(directory: LWCatalogNativePath, targets: [LWApplicationExportsDtoTargetKey], format: LWImageExportSpecificationOutputFormat, naming: LWApplicationExportsDtoNaming)
    case DestinationRows(token: String, after: LWCatalogU64, limit: LWCatalogU64)
    case ResultRelease(token: String)
    case Append(job: String, expected_total: LWCatalogI64, target: LWApplicationExportsDtoTarget, output: LWApplicationExportsDtoOutput, budgets: LWApplicationExportsDtoBudgets?)
    case Seal(job: String, expected_total: LWCatalogI64)
    case Job(job: String)
    case Jobs(after: LWCatalogI64, limit: LWCatalogU64)
    case Items(job: String, after: LWCatalogI64, limit: LWCatalogU64)
    case Plan(job: String, sequence: LWCatalogI64)
    case PlanChunk(job: String, sequence: LWCatalogI64, authority: String, offset: LWCatalogU64, bytes: LWCatalogU64)
    case Run(job: String, limits: LWApplicationExportsDtoExecutionLimits?, max_items: LWCatalogU64, max_seconds: LWCatalogU64)
    case Status(operation: String?)
    case Cancel(job: String?, operation: String?)
    case Yield(job: String, operation: String)
    case Recover(directories: LWCatalogU64, limits: LWApplicationExportsDtoExecutionLimits?)
    case RetrySeal(job: String, sequence: LWCatalogI64, authority: String)
    case Restore(job: String, sequence: LWCatalogI64, authority: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "options":
            try container.lwRequireKeys(["command", "args"])
            self = .Options
        case "profile":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["path"])
            self = .Profile(path: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path")))
        case "profile_release":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token"])
            self = .ProfileRelease(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")))
        case "begin":
            try container.lwRequireKeys(["command", "args"])
            self = .Begin
        case "paths":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["limit"])
            self = .Paths(limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "destinations":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["directory", "targets", "format", "naming"])
            self = .Destinations(directory: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")), targets: try payload.decode([LWApplicationExportsDtoTargetKey].self, forKey: LWCatalogCodingKey("targets")), format: try payload.decode(LWImageExportSpecificationOutputFormat.self, forKey: LWCatalogCodingKey("format")), naming: try payload.decode(LWApplicationExportsDtoNaming.self, forKey: LWCatalogCodingKey("naming")))
        case "destination_rows":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token", "after", "limit"])
            self = .DestinationRows(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), after: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "result_release":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token"])
            self = .ResultRelease(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")))
        case "append":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "expected_total", "target", "output", "budgets"])
            self = .Append(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), expected_total: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_total")), target: try payload.decode(LWApplicationExportsDtoTarget.self, forKey: LWCatalogCodingKey("target")), output: try payload.decode(LWApplicationExportsDtoOutput.self, forKey: LWCatalogCodingKey("output")), budgets: try payload.decodeIfPresent(LWApplicationExportsDtoBudgets.self, forKey: LWCatalogCodingKey("budgets")))
        case "seal":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "expected_total"])
            self = .Seal(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), expected_total: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_total")))
        case "job":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Job(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "jobs":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["after", "limit"])
            self = .Jobs(after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "items":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "after", "limit"])
            self = .Items(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "plan":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "sequence"])
            self = .Plan(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), sequence: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")))
        case "plan_chunk":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "sequence", "authority", "offset", "bytes"])
            self = .PlanChunk(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), sequence: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")), authority: try payload.decode(String.self, forKey: LWCatalogCodingKey("authority")), offset: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), bytes: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes")))
        case "run":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "limits", "max_items", "max_seconds"])
            self = .Run(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), limits: try payload.decodeIfPresent(LWApplicationExportsDtoExecutionLimits.self, forKey: LWCatalogCodingKey("limits")), max_items: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_items")), max_seconds: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_seconds")))
        case "status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Status(operation: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation")))
        case "cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "operation"])
            self = .Cancel(job: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("job")), operation: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation")))
        case "yield":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "operation"])
            self = .Yield(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), operation: try payload.decode(String.self, forKey: LWCatalogCodingKey("operation")))
        case "recover":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["directories", "limits"])
            self = .Recover(directories: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("directories")), limits: try payload.decodeIfPresent(LWApplicationExportsDtoExecutionLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "retry_seal":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "sequence", "authority"])
            self = .RetrySeal(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), sequence: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")), authority: try payload.decode(String.self, forKey: LWCatalogCodingKey("authority")))
        case "restore":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "sequence", "authority"])
            self = .Restore(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), sequence: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")), authority: try payload.decode(String.self, forKey: LWCatalogCodingKey("authority")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationExportsDtoRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Options:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("options", forKey: LWCatalogCodingKey("command"))
        case .Profile(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("profile", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("path"))
        case .ProfileRelease(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("profile_release", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
        case .Begin:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("command"))
        case .Paths(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("paths", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("limit"))
        case .Destinations(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("destinations", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("directory"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("targets"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("format"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("naming"))
        case .DestinationRows(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("destination_rows", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .ResultRelease(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("result_release", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
        case .Append(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("append", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_total"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("target"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("output"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("budgets"))
        case .Seal(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("seal", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_total"))
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Jobs(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jobs", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limit"))
        case .Items(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Plan(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("sequence"))
        case .PlanChunk(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan_chunk", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("sequence"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("authority"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("offset"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("bytes"))
        case .Run(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("run", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limits"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("max_items"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("max_seconds"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .Cancel(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("operation"))
        case .Yield(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("yield", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("operation"))
        case .Recover(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("recover", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("directories"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limits"))
        case .RetrySeal(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("retry_seal", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("sequence"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("authority"))
        case .Restore(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("sequence"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("authority"))
        }
    }
}

/// application::exports::dto::Response (engines/catalog/src/application/exports/dto.rs:491).
nonisolated indirect enum LWApplicationExportsDtoResponse: Codable, Sendable {
    case Options(LWApplicationExportsDtoOptions)
    case Released(token: String)
    case Job(LWApplicationExportsDtoJob)
    case Jobs(rows: [LWApplicationExportsDtoJob], next: LWCatalogI64?)
    case Items(rows: [LWApplicationExportsDtoItem], next: LWCatalogI64?)
    case Plan(LWApplicationExportsDtoPlan)
    case PlanChunk(LWApplicationExportsDtoPlanChunk)
    case Destinations(rows: [LWApplicationExportsDtoDestination], next: LWCatalogU64?, total: LWCatalogU64)
    case Operation(LWApplicationExportsDtoOperation?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "options":
            self = .Options(try container.decode(LWApplicationExportsDtoOptions.self, forKey: LWCatalogCodingKey("value")))
        case "released":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Released(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")))
        case "job":
            self = .Job(try container.decode(LWApplicationExportsDtoJob.self, forKey: LWCatalogCodingKey("value")))
        case "jobs":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Jobs(rows: try payload.decode([LWApplicationExportsDtoJob].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "items":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Items(rows: try payload.decode([LWApplicationExportsDtoItem].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "plan":
            self = .Plan(try container.decode(LWApplicationExportsDtoPlan.self, forKey: LWCatalogCodingKey("value")))
        case "plan_chunk":
            self = .PlanChunk(try container.decode(LWApplicationExportsDtoPlanChunk.self, forKey: LWCatalogCodingKey("value")))
        case "destinations":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Destinations(rows: try payload.decode([LWApplicationExportsDtoDestination].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next")), total: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total")))
        case "operation":
            self = .Operation(try container.decode(LWApplicationExportsDtoOperation?.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationExportsDtoResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Options(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("options", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Released(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("released", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Jobs(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jobs", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Items(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Plan(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .PlanChunk(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan_chunk", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Destinations(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("destinations", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("total"))
        case .Operation(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("operation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::exports::dto::ResultValue (engines/catalog/src/application/exports/dto.rs:455).
nonisolated indirect enum LWApplicationExportsDtoResultValue: Codable, Sendable {
    case Profile(LWApplicationExportsDtoProfileAdmission)
    case Paths(LWApplicationExportsDtoPaths)
    case Destinations(token: String, total: LWCatalogU64)
    case Appended(job: LWApplicationExportsDtoJob, item: LWApplicationExportsDtoItem)
    case Job(LWApplicationExportsDtoJob)
    case Recovery(LWApplicationExportsDtoRecovery)
    case Receipt(job: LWApplicationExportsDtoJob, sequence: LWCatalogI64, authority: String, receipt: LWApplicationExportsDtoReceipt)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "profile":
            self = .Profile(try container.decode(LWApplicationExportsDtoProfileAdmission.self, forKey: LWCatalogCodingKey("value")))
        case "paths":
            self = .Paths(try container.decode(LWApplicationExportsDtoPaths.self, forKey: LWCatalogCodingKey("value")))
        case "destinations":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Destinations(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), total: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total")))
        case "appended":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Appended(job: try payload.decode(LWApplicationExportsDtoJob.self, forKey: LWCatalogCodingKey("job")), item: try payload.decode(LWApplicationExportsDtoItem.self, forKey: LWCatalogCodingKey("item")))
        case "job":
            self = .Job(try container.decode(LWApplicationExportsDtoJob.self, forKey: LWCatalogCodingKey("value")))
        case "recovery":
            self = .Recovery(try container.decode(LWApplicationExportsDtoRecovery.self, forKey: LWCatalogCodingKey("value")))
        case "receipt":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Receipt(job: try payload.decode(LWApplicationExportsDtoJob.self, forKey: LWCatalogCodingKey("job")), sequence: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")), authority: try payload.decode(String.self, forKey: LWCatalogCodingKey("authority")), receipt: try payload.decode(LWApplicationExportsDtoReceipt.self, forKey: LWCatalogCodingKey("receipt")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationExportsDtoResultValue variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Profile(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("profile", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Paths(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("paths", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Destinations(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("destinations", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("total"))
        case .Appended(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("appended", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("item"))
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Recovery(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("recovery", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Receipt(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("receipt", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("sequence"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("authority"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("receipt"))
        }
    }
}

/// application::exports::dto::SourceIdentity (engines/catalog/src/application/exports/dto.rs:352).
nonisolated struct LWApplicationExportsDtoSourceIdentity: Codable, Sendable {
    var asset_id: String
    var generation: LWCatalogI64
    var fingerprint: String?
    var state: String
    var metadata_revision: LWCatalogI64
    init(asset_id: String, generation: LWCatalogI64, fingerprint: String?, state: String, metadata_revision: LWCatalogI64) {
        self.asset_id = asset_id
        self.generation = generation
        self.fingerprint = fingerprint
        self.state = state
        self.metadata_revision = metadata_revision
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.asset_id = try container.decode(String.self, forKey: LWCatalogCodingKey("asset_id"))
        self.generation = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("generation"))
        self.fingerprint = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("fingerprint"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.metadata_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("metadata_revision"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(asset_id, forKey: LWCatalogCodingKey("asset_id"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(fingerprint, forKey: LWCatalogCodingKey("fingerprint"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(metadata_revision, forKey: LWCatalogCodingKey("metadata_revision"))
    }
}

/// application::exports::dto::StoredOutput (engines/catalog/src/application/exports/dto.rs:379).
nonisolated struct LWApplicationExportsDtoStoredOutput: Codable, Sendable {
    var size: LWImageExportSpecificationOutputSize
    var format: LWImageExportSpecificationOutputFormat
    var profile: LWApplicationExportsDtoStoredProfile
    var alpha: LWImageExportSpecificationAlphaPolicy
    init(size: LWImageExportSpecificationOutputSize, format: LWImageExportSpecificationOutputFormat, profile: LWApplicationExportsDtoStoredProfile, alpha: LWImageExportSpecificationAlphaPolicy) {
        self.size = size
        self.format = format
        self.profile = profile
        self.alpha = alpha
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.size = try container.decode(LWImageExportSpecificationOutputSize.self, forKey: LWCatalogCodingKey("size"))
        self.format = try container.decode(LWImageExportSpecificationOutputFormat.self, forKey: LWCatalogCodingKey("format"))
        self.profile = try container.decode(LWApplicationExportsDtoStoredProfile.self, forKey: LWCatalogCodingKey("profile"))
        self.alpha = try container.decode(LWImageExportSpecificationAlphaPolicy.self, forKey: LWCatalogCodingKey("alpha"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(size, forKey: LWCatalogCodingKey("size"))
        try container.encode(format, forKey: LWCatalogCodingKey("format"))
        try container.encode(profile, forKey: LWCatalogCodingKey("profile"))
        try container.encode(alpha, forKey: LWCatalogCodingKey("alpha"))
    }
}

/// application::exports::dto::StoredProfile (engines/catalog/src/application/exports/dto.rs:369).
nonisolated indirect enum LWApplicationExportsDtoStoredProfile: Codable, Sendable {
    case Srgb
    case LinearSrgb
    case Icc(blob: String, bytes: LWCatalogU64, linear: Bool?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "srgb":
            self = .Srgb
        case "linear_srgb":
            self = .LinearSrgb
        case "icc":
            self = .Icc(blob: try container.decode(String.self, forKey: LWCatalogCodingKey("blob")), bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes")), linear: try container.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("linear")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationExportsDtoStoredProfile variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Srgb:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("srgb", forKey: LWCatalogCodingKey("kind"))
        case .LinearSrgb:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("linear_srgb", forKey: LWCatalogCodingKey("kind"))
        case .Icc(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("icc", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("blob"))
            try container.encode(value1, forKey: LWCatalogCodingKey("bytes"))
            try container.encode(value2, forKey: LWCatalogCodingKey("linear"))
        }
    }
}

/// application::exports::dto::Target (engines/catalog/src/application/exports/dto.rs:114).
nonisolated struct LWApplicationExportsDtoTarget: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var expected_revision: LWCatalogI64
    var destination: LWCatalogNativePath
    var overwrite: Bool
    var metadata: LWApplicationExportsDtoMetadata
    init(key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, destination: LWCatalogNativePath, overwrite: Bool, metadata: LWApplicationExportsDtoMetadata) {
        self.key = key
        self.expected_revision = expected_revision
        self.destination = destination
        self.overwrite = overwrite
        self.metadata = metadata
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["key", "expected_revision", "destination", "overwrite", "metadata"])
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.expected_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision"))
        self.destination = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.overwrite = try container.decode(Bool.self, forKey: LWCatalogCodingKey("overwrite"))
        self.metadata = try container.decode(LWApplicationExportsDtoMetadata.self, forKey: LWCatalogCodingKey("metadata"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(expected_revision, forKey: LWCatalogCodingKey("expected_revision"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(overwrite, forKey: LWCatalogCodingKey("overwrite"))
        try container.encode(metadata, forKey: LWCatalogCodingKey("metadata"))
    }
}

/// application::exports::dto::TargetKey (engines/catalog/src/application/exports/dto.rs:108).
nonisolated struct LWApplicationExportsDtoTargetKey: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var expected_revision: LWCatalogI64
    init(key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64) {
        self.key = key
        self.expected_revision = expected_revision
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["key", "expected_revision"])
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.expected_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(expected_revision, forKey: LWCatalogCodingKey("expected_revision"))
    }
}

/// application::lightroom::OpenMode (engines/catalog/src/application/lightroom.rs:148).
nonisolated enum LWApplicationLightroomOpenMode: String, Codable, Sendable {
    case Create = "Create"
    case OpenExisting = "OpenExisting"
}

/// application::lightroom::OriginalInspection (engines/catalog/src/application/lightroom.rs:162).
nonisolated enum LWApplicationLightroomOriginalInspection: String, Codable, Sendable {
    case MetadataOnly = "MetadataOnly"
    case Packets = "Packets"
}

/// application::lightroom::Phase (engines/catalog/src/application/lightroom.rs:346).
nonisolated enum LWApplicationLightroomPhase: String, Codable, Sendable {
    case Opening = "Opening"
    case Running = "Running"
    case Complete = "Complete"
    case Failed = "Failed"
    case CancelRequested = "CancelRequested"
    case Canceled = "Canceled"
    case Closing = "Closing"
    case Closed = "Closed"
}

/// application::lightroom::ResultPage (engines/catalog/src/application/lightroom.rs:375).
nonisolated struct LWApplicationLightroomResultPage: Codable, Sendable {
    var workbench: String
    var generation: String
    var operation: String
    var token: String
    var offset: LWCatalogU64
    var next: LWCatalogU64?
    var total_bytes: LWCatalogU64
    var json_fragment: String
    init(workbench: String, generation: String, operation: String, token: String, offset: LWCatalogU64, next: LWCatalogU64?, total_bytes: LWCatalogU64, json_fragment: String) {
        self.workbench = workbench
        self.generation = generation
        self.operation = operation
        self.token = token
        self.offset = offset
        self.next = next
        self.total_bytes = total_bytes
        self.json_fragment = json_fragment
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.workbench = try container.decode(String.self, forKey: LWCatalogCodingKey("workbench"))
        self.generation = try container.decode(String.self, forKey: LWCatalogCodingKey("generation"))
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        self.token = try container.decode(String.self, forKey: LWCatalogCodingKey("token"))
        self.offset = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset"))
        self.next = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next"))
        self.total_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_bytes"))
        self.json_fragment = try container.decode(String.self, forKey: LWCatalogCodingKey("json_fragment"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(workbench, forKey: LWCatalogCodingKey("workbench"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(token, forKey: LWCatalogCodingKey("token"))
        try container.encode(offset, forKey: LWCatalogCodingKey("offset"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(total_bytes, forKey: LWCatalogCodingKey("total_bytes"))
        try container.encode(json_fragment, forKey: LWCatalogCodingKey("json_fragment"))
    }
}

/// application::lightroom::ReviewCollection (engines/catalog/src/application/lightroom.rs:239).
nonisolated enum LWApplicationLightroomReviewCollection: String, Codable, Sendable {
    case Families = "Families"
    case Captures = "Captures"
    case UninspectedCandidates = "UninspectedCandidates"
    case ConflictSample = "ConflictSample"
    case PathCollisionSample = "PathCollisionSample"
}

/// application::lightroom_bridge::wire::Action (engines/catalog/src/application/lightroom_bridge/wire.rs:65).
nonisolated indirect enum LWApplicationLightroomBridgeWireAction: Codable, Sendable {
    case Discover(root: LWCatalogNativePath, limits: LWApplicationLightroomBridgeWireInspectionLimits)
    case Capture(source: LWCatalogNativePath, output: LWCatalogNativePath, include_auxiliary: Bool, closed_application_evidence: String?, limits: LWApplicationLightroomBridgeWireInspectionLimits)
    case RegisterInventory(input: String)
    case AddCapture(directory: LWCatalogNativePath)
    case Resume(revision: String, max_rows: LWCatalogU64)
    case InspectOriginals(revision: String, limit: LWCatalogU64, inspection: LWApplicationLightroomOriginalInspection)
    case AssignFamily(revision: String, family: String, reason: String)
    case Choose(family: String, revision: String, expected_evidence: String, reason: String)
    case PrepareSelection(input: String, limits: LWApplicationLightroomBridgeWireSelectionLimits)
    case Seal(review_token: String, approval_blake3: String, input: String, output: LWCatalogNativePath)
    case ApprovalDocuments(input: String, review_token: String)
    case ReleaseReview
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "Discover":
            try container.lwRequireKeys(["kind", "root", "limits"])
            self = .Discover(root: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("root")), limits: try container.decode(LWApplicationLightroomBridgeWireInspectionLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "Capture":
            try container.lwRequireKeys(["kind", "source", "output", "include_auxiliary", "closed_application_evidence", "limits"])
            self = .Capture(source: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("source")), output: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("output")), include_auxiliary: try container.decode(Bool.self, forKey: LWCatalogCodingKey("include_auxiliary")), closed_application_evidence: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("closed_application_evidence")), limits: try container.decode(LWApplicationLightroomBridgeWireInspectionLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "RegisterInventory":
            try container.lwRequireKeys(["kind", "input"])
            self = .RegisterInventory(input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")))
        case "AddCapture":
            try container.lwRequireKeys(["kind", "directory"])
            self = .AddCapture(directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")))
        case "Resume":
            try container.lwRequireKeys(["kind", "revision", "max_rows"])
            self = .Resume(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), max_rows: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_rows")))
        case "InspectOriginals":
            try container.lwRequireKeys(["kind", "revision", "limit", "inspection"])
            self = .InspectOriginals(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")), inspection: try container.decode(LWApplicationLightroomOriginalInspection.self, forKey: LWCatalogCodingKey("inspection")))
        case "AssignFamily":
            try container.lwRequireKeys(["kind", "revision", "family", "reason"])
            self = .AssignFamily(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), family: try container.decode(String.self, forKey: LWCatalogCodingKey("family")), reason: try container.decode(String.self, forKey: LWCatalogCodingKey("reason")))
        case "Choose":
            try container.lwRequireKeys(["kind", "family", "revision", "expected_evidence", "reason"])
            self = .Choose(family: try container.decode(String.self, forKey: LWCatalogCodingKey("family")), revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), expected_evidence: try container.decode(String.self, forKey: LWCatalogCodingKey("expected_evidence")), reason: try container.decode(String.self, forKey: LWCatalogCodingKey("reason")))
        case "PrepareSelection":
            try container.lwRequireKeys(["kind", "input", "limits"])
            self = .PrepareSelection(input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")), limits: try container.decode(LWApplicationLightroomBridgeWireSelectionLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "Seal":
            try container.lwRequireKeys(["kind", "review_token", "approval_blake3", "input", "output"])
            self = .Seal(review_token: try container.decode(String.self, forKey: LWCatalogCodingKey("review_token")), approval_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("approval_blake3")), input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")), output: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("output")))
        case "ApprovalDocuments":
            try container.lwRequireKeys(["kind", "input", "review_token"])
            self = .ApprovalDocuments(input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")), review_token: try container.decode(String.self, forKey: LWCatalogCodingKey("review_token")))
        case "ReleaseReview":
            try container.lwRequireKeys(["kind"])
            self = .ReleaseReview
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationLightroomBridgeWireAction variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Discover(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Discover", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("root"))
            try container.encode(value1, forKey: LWCatalogCodingKey("limits"))
        case .Capture(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Capture", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("source"))
            try container.encode(value1, forKey: LWCatalogCodingKey("output"))
            try container.encode(value2, forKey: LWCatalogCodingKey("include_auxiliary"))
            try container.encode(value3, forKey: LWCatalogCodingKey("closed_application_evidence"))
            try container.encode(value4, forKey: LWCatalogCodingKey("limits"))
        case .RegisterInventory(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("RegisterInventory", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("input"))
        case .AddCapture(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("AddCapture", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("directory"))
        case .Resume(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Resume", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("max_rows"))
        case .InspectOriginals(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("InspectOriginals", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("limit"))
            try container.encode(value2, forKey: LWCatalogCodingKey("inspection"))
        case .AssignFamily(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("AssignFamily", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("family"))
            try container.encode(value2, forKey: LWCatalogCodingKey("reason"))
        case .Choose(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Choose", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("family"))
            try container.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value2, forKey: LWCatalogCodingKey("expected_evidence"))
            try container.encode(value3, forKey: LWCatalogCodingKey("reason"))
        case .PrepareSelection(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("PrepareSelection", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("input"))
            try container.encode(value1, forKey: LWCatalogCodingKey("limits"))
        case .Seal(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Seal", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("review_token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("approval_blake3"))
            try container.encode(value2, forKey: LWCatalogCodingKey("input"))
            try container.encode(value3, forKey: LWCatalogCodingKey("output"))
        case .ApprovalDocuments(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("ApprovalDocuments", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("input"))
            try container.encode(value1, forKey: LWCatalogCodingKey("review_token"))
        case .ReleaseReview:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("ReleaseReview", forKey: LWCatalogCodingKey("kind"))
        }
    }
}

/// application::lightroom_bridge::wire::Guard (engines/catalog/src/application/lightroom_bridge/wire.rs:51).
nonisolated struct LWApplicationLightroomBridgeWireGuard: Codable, Sendable {
    var workbench: String
    var generation: String
    var operation: String
    init(workbench: String, generation: String, operation: String) {
        self.workbench = workbench
        self.generation = generation
        self.operation = operation
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["workbench", "generation", "operation"])
        self.workbench = try container.decode(String.self, forKey: LWCatalogCodingKey("workbench"))
        self.generation = try container.decode(String.self, forKey: LWCatalogCodingKey("generation"))
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(workbench, forKey: LWCatalogCodingKey("workbench"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
    }
}

/// application::lightroom_bridge::wire::InputPurpose (engines/catalog/src/application/lightroom_bridge/wire.rs:57).
nonisolated enum LWApplicationLightroomBridgeWireInputPurpose: String, Codable, Sendable {
    case Inventory = "Inventory"
    case SelectionRequest = "SelectionRequest"
    case Approval = "Approval"
    case ApprovalDraft = "ApprovalDraft"
}

/// application::lightroom_bridge::wire::InputStatus (engines/catalog/src/application/lightroom_bridge/wire.rs:598).
nonisolated struct LWApplicationLightroomBridgeWireInputStatus: Codable, Sendable {
    var attempt: String
    var `guard`: LWApplicationLightroomBridgeWireGuard
    var input: String
    var purpose: LWApplicationLightroomBridgeWireInputPurpose
    var total_bytes: LWCatalogU64
    var received_bytes: LWCatalogU64
    var blake3: String?
    var expected_blake3: String?
    var complete: Bool
    init(attempt: String, `guard`: LWApplicationLightroomBridgeWireGuard, input: String, purpose: LWApplicationLightroomBridgeWireInputPurpose, total_bytes: LWCatalogU64, received_bytes: LWCatalogU64, blake3: String?, expected_blake3: String?, complete: Bool) {
        self.attempt = attempt
        self.`guard` = `guard`
        self.input = input
        self.purpose = purpose
        self.total_bytes = total_bytes
        self.received_bytes = received_bytes
        self.blake3 = blake3
        self.expected_blake3 = expected_blake3
        self.complete = complete
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.attempt = try container.decode(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.`guard` = try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard"))
        self.input = try container.decode(String.self, forKey: LWCatalogCodingKey("input"))
        self.purpose = try container.decode(LWApplicationLightroomBridgeWireInputPurpose.self, forKey: LWCatalogCodingKey("purpose"))
        self.total_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_bytes"))
        self.received_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("received_bytes"))
        self.blake3 = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.expected_blake3 = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("expected_blake3"))
        self.complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("complete"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try container.encode(`guard`, forKey: LWCatalogCodingKey("guard"))
        try container.encode(input, forKey: LWCatalogCodingKey("input"))
        try container.encode(purpose, forKey: LWCatalogCodingKey("purpose"))
        try container.encode(total_bytes, forKey: LWCatalogCodingKey("total_bytes"))
        try container.encode(received_bytes, forKey: LWCatalogCodingKey("received_bytes"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(expected_blake3, forKey: LWCatalogCodingKey("expected_blake3"))
        try container.encode(complete, forKey: LWCatalogCodingKey("complete"))
    }
}

/// application::lightroom_bridge::wire::InspectionLimits (engines/catalog/src/application/lightroom_bridge/wire.rs:25).
nonisolated struct LWApplicationLightroomBridgeWireInspectionLimits: Codable, Sendable {
    var max_files: LWCatalogU64
    var max_depth: LWCatalogU64
    var max_file_bytes: LWCatalogU64
    var max_total_bytes: LWCatalogU64
    var max_cell_bytes: LWCatalogU64
    init(max_files: LWCatalogU64, max_depth: LWCatalogU64, max_file_bytes: LWCatalogU64, max_total_bytes: LWCatalogU64, max_cell_bytes: LWCatalogU64) {
        self.max_files = max_files
        self.max_depth = max_depth
        self.max_file_bytes = max_file_bytes
        self.max_total_bytes = max_total_bytes
        self.max_cell_bytes = max_cell_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["max_files", "max_depth", "max_file_bytes", "max_total_bytes", "max_cell_bytes"])
        self.max_files = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_files"))
        self.max_depth = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_depth"))
        self.max_file_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_file_bytes"))
        self.max_total_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_total_bytes"))
        self.max_cell_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_cell_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(max_files, forKey: LWCatalogCodingKey("max_files"))
        try container.encode(max_depth, forKey: LWCatalogCodingKey("max_depth"))
        try container.encode(max_file_bytes, forKey: LWCatalogCodingKey("max_file_bytes"))
        try container.encode(max_total_bytes, forKey: LWCatalogCodingKey("max_total_bytes"))
        try container.encode(max_cell_bytes, forKey: LWCatalogCodingKey("max_cell_bytes"))
    }
}

/// application::lightroom_bridge::wire::Options (engines/catalog/src/application/lightroom_bridge/wire.rs:538).
nonisolated struct LWApplicationLightroomBridgeWireOptions: Codable, Sendable {
    var envelope_bytes: LWCatalogU64
    var chunk_bytes: LWCatalogU64
    var input_slots: LWCatalogU64
    var input_owned_factor: LWCatalogU64
    var minimum_nonfinal_chunk_bytes: LWCatalogU64
    var selection_preparation_chunk_bytes: LWCatalogU64
    var selection_preparation_page_rows: LWCatalogU64
    var workbench: LWApplicationLightroomBridgeWireWorkbenchLimits
    var inspection: LWApplicationLightroomBridgeWireInspectionLimits
    var selection: LWApplicationLightroomBridgeWireSelectionLimits
    init(envelope_bytes: LWCatalogU64, chunk_bytes: LWCatalogU64, input_slots: LWCatalogU64, input_owned_factor: LWCatalogU64, minimum_nonfinal_chunk_bytes: LWCatalogU64, selection_preparation_chunk_bytes: LWCatalogU64, selection_preparation_page_rows: LWCatalogU64, workbench: LWApplicationLightroomBridgeWireWorkbenchLimits, inspection: LWApplicationLightroomBridgeWireInspectionLimits, selection: LWApplicationLightroomBridgeWireSelectionLimits) {
        self.envelope_bytes = envelope_bytes
        self.chunk_bytes = chunk_bytes
        self.input_slots = input_slots
        self.input_owned_factor = input_owned_factor
        self.minimum_nonfinal_chunk_bytes = minimum_nonfinal_chunk_bytes
        self.selection_preparation_chunk_bytes = selection_preparation_chunk_bytes
        self.selection_preparation_page_rows = selection_preparation_page_rows
        self.workbench = workbench
        self.inspection = inspection
        self.selection = selection
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.envelope_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("envelope_bytes"))
        self.chunk_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("chunk_bytes"))
        self.input_slots = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("input_slots"))
        self.input_owned_factor = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("input_owned_factor"))
        self.minimum_nonfinal_chunk_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("minimum_nonfinal_chunk_bytes"))
        self.selection_preparation_chunk_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("selection_preparation_chunk_bytes"))
        self.selection_preparation_page_rows = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("selection_preparation_page_rows"))
        self.workbench = try container.decode(LWApplicationLightroomBridgeWireWorkbenchLimits.self, forKey: LWCatalogCodingKey("workbench"))
        self.inspection = try container.decode(LWApplicationLightroomBridgeWireInspectionLimits.self, forKey: LWCatalogCodingKey("inspection"))
        self.selection = try container.decode(LWApplicationLightroomBridgeWireSelectionLimits.self, forKey: LWCatalogCodingKey("selection"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(envelope_bytes, forKey: LWCatalogCodingKey("envelope_bytes"))
        try container.encode(chunk_bytes, forKey: LWCatalogCodingKey("chunk_bytes"))
        try container.encode(input_slots, forKey: LWCatalogCodingKey("input_slots"))
        try container.encode(input_owned_factor, forKey: LWCatalogCodingKey("input_owned_factor"))
        try container.encode(minimum_nonfinal_chunk_bytes, forKey: LWCatalogCodingKey("minimum_nonfinal_chunk_bytes"))
        try container.encode(selection_preparation_chunk_bytes, forKey: LWCatalogCodingKey("selection_preparation_chunk_bytes"))
        try container.encode(selection_preparation_page_rows, forKey: LWCatalogCodingKey("selection_preparation_page_rows"))
        try container.encode(workbench, forKey: LWCatalogCodingKey("workbench"))
        try container.encode(inspection, forKey: LWCatalogCodingKey("inspection"))
        try container.encode(selection, forKey: LWCatalogCodingKey("selection"))
    }
}

/// application::lightroom_bridge::wire::Query (engines/catalog/src/application/lightroom_bridge/wire.rs:122).
nonisolated indirect enum LWApplicationLightroomBridgeWireQuery: Codable, Sendable {
    case CaptureManifest(directory: LWCatalogNativePath)
    case Rows(revision: String, table: String?, after: LWCatalogI64, limit: LWCatalogU64)
    case Report(revision: String)
    case Paths(revision: String, after: LWCatalogI64, limit: LWCatalogU64)
    case Issues(revision: String, after: LWCatalogI64, limit: LWCatalogU64)
    case Packets(revision: String, after: LWCatalogI64, limit: LWCatalogU64)
    case PacketBytes(revision: String, sequence: LWCatalogI64, decoded: Bool, offset: LWCatalogI64, limit: LWCatalogU64)
    case MetadataConflicts(revision: String, after: LWCatalogI64, limit: LWCatalogU64)
    case GlobalIdConflicts(left: String, right: String, after_left: String, after_right: String, limit: LWCatalogU64)
    case PathCollisions(left: String, right: String, after_left: LWCatalogI64, after_right: LWCatalogI64, limit: LWCatalogU64)
    case Families
    case SelectionSummary
    case SelectionSources(review_token: String, revision: String, after: LWCatalogI64, limit: LWCatalogU64)
    case SelectionPreparation(review_token: String, document: LWLightroomPlanSelectionPreparationPreparationDocument, offset: LWCatalogU64, limit: LWCatalogU64)
    case SelectionPage(review_token: String, collection: LWApplicationLightroomReviewCollection, after: LWCatalogU64, limit: LWCatalogU64)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "CaptureManifest":
            try container.lwRequireKeys(["kind", "directory"])
            self = .CaptureManifest(directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")))
        case "Rows":
            try container.lwRequireKeys(["kind", "revision", "table", "after", "limit"])
            self = .Rows(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), table: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("table")), after: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "Report":
            try container.lwRequireKeys(["kind", "revision"])
            self = .Report(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")))
        case "Paths":
            try container.lwRequireKeys(["kind", "revision", "after", "limit"])
            self = .Paths(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), after: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "Issues":
            try container.lwRequireKeys(["kind", "revision", "after", "limit"])
            self = .Issues(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), after: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "Packets":
            try container.lwRequireKeys(["kind", "revision", "after", "limit"])
            self = .Packets(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), after: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "PacketBytes":
            try container.lwRequireKeys(["kind", "revision", "sequence", "decoded", "offset", "limit"])
            self = .PacketBytes(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), sequence: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")), decoded: try container.decode(Bool.self, forKey: LWCatalogCodingKey("decoded")), offset: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("offset")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "MetadataConflicts":
            try container.lwRequireKeys(["kind", "revision", "after", "limit"])
            self = .MetadataConflicts(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), after: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "GlobalIdConflicts":
            try container.lwRequireKeys(["kind", "left", "right", "after_left", "after_right", "limit"])
            self = .GlobalIdConflicts(left: try container.decode(String.self, forKey: LWCatalogCodingKey("left")), right: try container.decode(String.self, forKey: LWCatalogCodingKey("right")), after_left: try container.decode(String.self, forKey: LWCatalogCodingKey("after_left")), after_right: try container.decode(String.self, forKey: LWCatalogCodingKey("after_right")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "PathCollisions":
            try container.lwRequireKeys(["kind", "left", "right", "after_left", "after_right", "limit"])
            self = .PathCollisions(left: try container.decode(String.self, forKey: LWCatalogCodingKey("left")), right: try container.decode(String.self, forKey: LWCatalogCodingKey("right")), after_left: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after_left")), after_right: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after_right")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "Families":
            try container.lwRequireKeys(["kind"])
            self = .Families
        case "SelectionSummary":
            try container.lwRequireKeys(["kind"])
            self = .SelectionSummary
        case "SelectionSources":
            try container.lwRequireKeys(["kind", "review_token", "revision", "after", "limit"])
            self = .SelectionSources(review_token: try container.decode(String.self, forKey: LWCatalogCodingKey("review_token")), revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), after: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "SelectionPreparation":
            try container.lwRequireKeys(["kind", "review_token", "document", "offset", "limit"])
            self = .SelectionPreparation(review_token: try container.decode(String.self, forKey: LWCatalogCodingKey("review_token")), document: try container.decode(LWLightroomPlanSelectionPreparationPreparationDocument.self, forKey: LWCatalogCodingKey("document")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "SelectionPage":
            try container.lwRequireKeys(["kind", "review_token", "collection", "after", "limit"])
            self = .SelectionPage(review_token: try container.decode(String.self, forKey: LWCatalogCodingKey("review_token")), collection: try container.decode(LWApplicationLightroomReviewCollection.self, forKey: LWCatalogCodingKey("collection")), after: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("after")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationLightroomBridgeWireQuery variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .CaptureManifest(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("CaptureManifest", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("directory"))
        case .Rows(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Rows", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("table"))
            try container.encode(value2, forKey: LWCatalogCodingKey("after"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Report(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Report", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
        case .Paths(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Paths", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("after"))
            try container.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Issues(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Issues", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("after"))
            try container.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Packets(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Packets", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("after"))
            try container.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .PacketBytes(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("PacketBytes", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("sequence"))
            try container.encode(value2, forKey: LWCatalogCodingKey("decoded"))
            try container.encode(value3, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value4, forKey: LWCatalogCodingKey("limit"))
        case .MetadataConflicts(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("MetadataConflicts", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("after"))
            try container.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .GlobalIdConflicts(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("GlobalIdConflicts", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("left"))
            try container.encode(value1, forKey: LWCatalogCodingKey("right"))
            try container.encode(value2, forKey: LWCatalogCodingKey("after_left"))
            try container.encode(value3, forKey: LWCatalogCodingKey("after_right"))
            try container.encode(value4, forKey: LWCatalogCodingKey("limit"))
        case .PathCollisions(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("PathCollisions", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("left"))
            try container.encode(value1, forKey: LWCatalogCodingKey("right"))
            try container.encode(value2, forKey: LWCatalogCodingKey("after_left"))
            try container.encode(value3, forKey: LWCatalogCodingKey("after_right"))
            try container.encode(value4, forKey: LWCatalogCodingKey("limit"))
        case .Families:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Families", forKey: LWCatalogCodingKey("kind"))
        case .SelectionSummary:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("SelectionSummary", forKey: LWCatalogCodingKey("kind"))
        case .SelectionSources(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("SelectionSources", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("review_token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value2, forKey: LWCatalogCodingKey("after"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .SelectionPreparation(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("SelectionPreparation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("review_token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("document"))
            try container.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .SelectionPage(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("SelectionPage", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("review_token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("collection"))
            try container.encode(value2, forKey: LWCatalogCodingKey("after"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limit"))
        }
    }
}

/// application::lightroom_bridge::wire::Request (engines/catalog/src/application/lightroom_bridge/wire.rs:458).
nonisolated indirect enum LWApplicationLightroomBridgeWireRequest: Codable, Sendable {
    case SealedDocument(request: LWFilesystemWorkerWireLightroomSealedRead)
    case ArtifactPreparation(request: LWFilesystemWorkerWireLightroomArtifactPreparation)
    case Options
    case Open(attempt: String, root: LWCatalogNativePath, mode: LWApplicationLightroomOpenMode, capture_staging: LWCatalogNativePath, limits: LWApplicationLightroomBridgeWireWorkbenchLimits)
    case Status(workbench: String?, attempt: String?)
    case Action(`guard`: LWApplicationLightroomBridgeWireGuard, action: LWApplicationLightroomBridgeWireAction)
    case Read(`guard`: LWApplicationLightroomBridgeWireGuard, query: LWApplicationLightroomBridgeWireQuery)
    case Cancel(`guard`: LWApplicationLightroomBridgeWireGuard)
    case Close(workbench: String)
    case Result(`guard`: LWApplicationLightroomBridgeWireGuard, token: String, offset: LWCatalogU64, limit: LWCatalogU64)
    case InputBegin(`guard`: LWApplicationLightroomBridgeWireGuard, purpose: LWApplicationLightroomBridgeWireInputPurpose, total_bytes: LWCatalogU64, expected_blake3: String?)
    case InputAppend(`guard`: LWApplicationLightroomBridgeWireGuard, input: String, offset: LWCatalogU64, fragment: String)
    case InputFinish(`guard`: LWApplicationLightroomBridgeWireGuard, input: String)
    case InputDiscard(`guard`: LWApplicationLightroomBridgeWireGuard, input: String)
    case InputStatus(`guard`: LWApplicationLightroomBridgeWireGuard, input: String?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "SealedDocument":
            try container.lwRequireKeys(["kind", "request"])
            self = .SealedDocument(request: try container.decode(LWFilesystemWorkerWireLightroomSealedRead.self, forKey: LWCatalogCodingKey("request")))
        case "ArtifactPreparation":
            try container.lwRequireKeys(["kind", "request"])
            self = .ArtifactPreparation(request: try container.decode(LWFilesystemWorkerWireLightroomArtifactPreparation.self, forKey: LWCatalogCodingKey("request")))
        case "Options":
            try container.lwRequireKeys(["kind"])
            self = .Options
        case "Open":
            try container.lwRequireKeys(["kind", "attempt", "root", "mode", "capture_staging", "limits"])
            self = .Open(attempt: try container.decode(String.self, forKey: LWCatalogCodingKey("attempt")), root: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("root")), mode: try container.decode(LWApplicationLightroomOpenMode.self, forKey: LWCatalogCodingKey("mode")), capture_staging: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("capture_staging")), limits: try container.decode(LWApplicationLightroomBridgeWireWorkbenchLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "Status":
            try container.lwRequireKeys(["kind", "workbench", "attempt"])
            self = .Status(workbench: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("workbench")), attempt: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("attempt")))
        case "Action":
            try container.lwRequireKeys(["kind", "guard", "action"])
            self = .Action(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), action: try container.decode(LWApplicationLightroomBridgeWireAction.self, forKey: LWCatalogCodingKey("action")))
        case "Read":
            try container.lwRequireKeys(["kind", "guard", "query"])
            self = .Read(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), query: try container.decode(LWApplicationLightroomBridgeWireQuery.self, forKey: LWCatalogCodingKey("query")))
        case "Cancel":
            try container.lwRequireKeys(["kind", "guard"])
            self = .Cancel(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")))
        case "Close":
            try container.lwRequireKeys(["kind", "workbench"])
            self = .Close(workbench: try container.decode(String.self, forKey: LWCatalogCodingKey("workbench")))
        case "Result":
            try container.lwRequireKeys(["kind", "guard", "token", "offset", "limit"])
            self = .Result(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), token: try container.decode(String.self, forKey: LWCatalogCodingKey("token")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "InputBegin":
            try container.lwRequireKeys(["kind", "guard", "purpose", "total_bytes", "expected_blake3"])
            self = .InputBegin(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), purpose: try container.decode(LWApplicationLightroomBridgeWireInputPurpose.self, forKey: LWCatalogCodingKey("purpose")), total_bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_bytes")), expected_blake3: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("expected_blake3")))
        case "InputAppend":
            try container.lwRequireKeys(["kind", "guard", "input", "offset", "fragment"])
            self = .InputAppend(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), fragment: try container.decode(String.self, forKey: LWCatalogCodingKey("fragment")))
        case "InputFinish":
            try container.lwRequireKeys(["kind", "guard", "input"])
            self = .InputFinish(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")))
        case "InputDiscard":
            try container.lwRequireKeys(["kind", "guard", "input"])
            self = .InputDiscard(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")))
        case "InputStatus":
            try container.lwRequireKeys(["kind", "guard", "input"])
            self = .InputStatus(guard: try container.decode(LWApplicationLightroomBridgeWireGuard.self, forKey: LWCatalogCodingKey("guard")), input: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("input")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationLightroomBridgeWireRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .SealedDocument(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("SealedDocument", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("request"))
        case .ArtifactPreparation(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("ArtifactPreparation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("request"))
        case .Options:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Options", forKey: LWCatalogCodingKey("kind"))
        case .Open(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Open", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("attempt"))
            try container.encode(value1, forKey: LWCatalogCodingKey("root"))
            try container.encode(value2, forKey: LWCatalogCodingKey("mode"))
            try container.encode(value3, forKey: LWCatalogCodingKey("capture_staging"))
            try container.encode(value4, forKey: LWCatalogCodingKey("limits"))
        case .Status(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Status", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("workbench"))
            try container.encode(value1, forKey: LWCatalogCodingKey("attempt"))
        case .Action(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Action", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("action"))
        case .Read(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Read", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("query"))
        case .Cancel(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Cancel", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
        case .Close(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Close", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("workbench"))
        case .Result(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Result", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("token"))
            try container.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .InputBegin(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("InputBegin", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("purpose"))
            try container.encode(value2, forKey: LWCatalogCodingKey("total_bytes"))
            try container.encode(value3, forKey: LWCatalogCodingKey("expected_blake3"))
        case .InputAppend(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("InputAppend", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("input"))
            try container.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value3, forKey: LWCatalogCodingKey("fragment"))
        case .InputFinish(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("InputFinish", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("input"))
        case .InputDiscard(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("InputDiscard", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("input"))
        case .InputStatus(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("InputStatus", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("input"))
        }
    }
}

/// application::lightroom_bridge::wire::Response (engines/catalog/src/application/lightroom_bridge/wire.rs:611).
nonisolated indirect enum LWApplicationLightroomBridgeWireResponse: Codable, Sendable {
    case Options(LWApplicationLightroomBridgeWireOptions)
    case Status(LWApplicationLightroomBridgeWireStatus?)
    case Result(LWApplicationLightroomBridgeWireResultPage)
    case Input(LWApplicationLightroomBridgeWireInputStatus?)
    case SealedDocument(LWFilesystemWorkerWireLightroomSealedDocumentPage?)
    case ArtifactPreparation(LWFilesystemWorkerWireLightroomArtifactPreparationReply?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "Options":
            self = .Options(try container.decode(LWApplicationLightroomBridgeWireOptions.self, forKey: LWCatalogCodingKey("value")))
        case "Status":
            self = .Status(try container.decode(LWApplicationLightroomBridgeWireStatus?.self, forKey: LWCatalogCodingKey("value")))
        case "Result":
            self = .Result(try container.decode(LWApplicationLightroomBridgeWireResultPage.self, forKey: LWCatalogCodingKey("value")))
        case "Input":
            self = .Input(try container.decode(LWApplicationLightroomBridgeWireInputStatus?.self, forKey: LWCatalogCodingKey("value")))
        case "SealedDocument":
            self = .SealedDocument(try container.decode(LWFilesystemWorkerWireLightroomSealedDocumentPage?.self, forKey: LWCatalogCodingKey("value")))
        case "ArtifactPreparation":
            self = .ArtifactPreparation(try container.decode(LWFilesystemWorkerWireLightroomArtifactPreparationReply?.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationLightroomBridgeWireResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Options(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Options", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Status", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Result(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Result", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Input(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Input", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .SealedDocument(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("SealedDocument", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .ArtifactPreparation(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("ArtifactPreparation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::lightroom_bridge::wire::ResultPage (engines/catalog/src/application/lightroom_bridge/wire.rs:592).
nonisolated struct LWApplicationLightroomBridgeWireResultPage: Codable, Sendable {
    var attempt: String
    var page: LWApplicationLightroomResultPage
    init(attempt: String, page: LWApplicationLightroomResultPage) {
        self.attempt = attempt
        self.page = page
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.attempt = try container.decode(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.page = try LWApplicationLightroomResultPage(from: decoder)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try page.encode(to: encoder)
    }
}

/// application::lightroom_bridge::wire::SelectionLimits (engines/catalog/src/application/lightroom_bridge/wire.rs:36).
nonisolated struct LWApplicationLightroomBridgeWireSelectionLimits: Codable, Sendable {
    var review_bytes: LWCatalogU64
    var row_bytes: LWCatalogU64
    var page_bytes: LWCatalogU64
    var native_path_units: LWCatalogU64
    var snapshot_bytes: LWCatalogU64
    var vm_steps: LWCatalogU64
    var deadline_ms: LWCatalogU64
    init(review_bytes: LWCatalogU64, row_bytes: LWCatalogU64, page_bytes: LWCatalogU64, native_path_units: LWCatalogU64, snapshot_bytes: LWCatalogU64, vm_steps: LWCatalogU64, deadline_ms: LWCatalogU64) {
        self.review_bytes = review_bytes
        self.row_bytes = row_bytes
        self.page_bytes = page_bytes
        self.native_path_units = native_path_units
        self.snapshot_bytes = snapshot_bytes
        self.vm_steps = vm_steps
        self.deadline_ms = deadline_ms
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["review_bytes", "row_bytes", "page_bytes", "native_path_units", "snapshot_bytes", "vm_steps", "deadline_ms"])
        self.review_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("review_bytes"))
        self.row_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("row_bytes"))
        self.page_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("page_bytes"))
        self.native_path_units = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("native_path_units"))
        self.snapshot_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("snapshot_bytes"))
        self.vm_steps = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("vm_steps"))
        self.deadline_ms = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("deadline_ms"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(review_bytes, forKey: LWCatalogCodingKey("review_bytes"))
        try container.encode(row_bytes, forKey: LWCatalogCodingKey("row_bytes"))
        try container.encode(page_bytes, forKey: LWCatalogCodingKey("page_bytes"))
        try container.encode(native_path_units, forKey: LWCatalogCodingKey("native_path_units"))
        try container.encode(snapshot_bytes, forKey: LWCatalogCodingKey("snapshot_bytes"))
        try container.encode(vm_steps, forKey: LWCatalogCodingKey("vm_steps"))
        try container.encode(deadline_ms, forKey: LWCatalogCodingKey("deadline_ms"))
    }
}

/// application::lightroom_bridge::wire::Status (engines/catalog/src/application/lightroom_bridge/wire.rs:551).
nonisolated struct LWApplicationLightroomBridgeWireStatus: Codable, Sendable {
    var attempt: String
    var workbench: String
    var generation: String
    var operation: String
    var phase: LWApplicationLightroomPhase
    var initialized: Bool
    var closed: Bool
    var root: LWCatalogNativePath
    var limits: LWApplicationLightroomBridgeWireWorkbenchLimits
    var processed: LWCatalogU64
    var result_token: String?
    var result_bytes: LWCatalogU64
    var review_token: String?
    var capture_pid: LWCatalogU64?
    var capture_staging: LWCatalogNativePath?
    var error: String?
    init(attempt: String, workbench: String, generation: String, operation: String, phase: LWApplicationLightroomPhase, initialized: Bool, closed: Bool, root: LWCatalogNativePath, limits: LWApplicationLightroomBridgeWireWorkbenchLimits, processed: LWCatalogU64, result_token: String?, result_bytes: LWCatalogU64, review_token: String?, capture_pid: LWCatalogU64?, capture_staging: LWCatalogNativePath?, error: String?) {
        self.attempt = attempt
        self.workbench = workbench
        self.generation = generation
        self.operation = operation
        self.phase = phase
        self.initialized = initialized
        self.closed = closed
        self.root = root
        self.limits = limits
        self.processed = processed
        self.result_token = result_token
        self.result_bytes = result_bytes
        self.review_token = review_token
        self.capture_pid = capture_pid
        self.capture_staging = capture_staging
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.attempt = try container.decode(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.workbench = try container.decode(String.self, forKey: LWCatalogCodingKey("workbench"))
        self.generation = try container.decode(String.self, forKey: LWCatalogCodingKey("generation"))
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        self.phase = try container.decode(LWApplicationLightroomPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.initialized = try container.decode(Bool.self, forKey: LWCatalogCodingKey("initialized"))
        self.closed = try container.decode(Bool.self, forKey: LWCatalogCodingKey("closed"))
        self.root = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("root"))
        self.limits = try container.decode(LWApplicationLightroomBridgeWireWorkbenchLimits.self, forKey: LWCatalogCodingKey("limits"))
        self.processed = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("processed"))
        self.result_token = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("result_token"))
        self.result_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("result_bytes"))
        self.review_token = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("review_token"))
        self.capture_pid = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("capture_pid"))
        self.capture_staging = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("capture_staging"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try container.encode(workbench, forKey: LWCatalogCodingKey("workbench"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(initialized, forKey: LWCatalogCodingKey("initialized"))
        try container.encode(closed, forKey: LWCatalogCodingKey("closed"))
        try container.encode(root, forKey: LWCatalogCodingKey("root"))
        try container.encode(limits, forKey: LWCatalogCodingKey("limits"))
        try container.encode(processed, forKey: LWCatalogCodingKey("processed"))
        try container.encode(result_token, forKey: LWCatalogCodingKey("result_token"))
        try container.encode(result_bytes, forKey: LWCatalogCodingKey("result_bytes"))
        try container.encode(review_token, forKey: LWCatalogCodingKey("review_token"))
        try container.encode(capture_pid, forKey: LWCatalogCodingKey("capture_pid"))
        try container.encode(capture_staging, forKey: LWCatalogCodingKey("capture_staging"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::lightroom_bridge::wire::WorkbenchLimits (engines/catalog/src/application/lightroom_bridge/wire.rs:12).
nonisolated struct LWApplicationLightroomBridgeWireWorkbenchLimits: Codable, Sendable {
    var request_bytes: LWCatalogU64
    var result_bytes: LWCatalogU64
    var page_bytes: LWCatalogU64
    var row_bytes: LWCatalogU64
    var native_path_units: LWCatalogU64
    var vm_steps: LWCatalogU64
    var deadline_ms: LWCatalogU64
    init(request_bytes: LWCatalogU64, result_bytes: LWCatalogU64, page_bytes: LWCatalogU64, row_bytes: LWCatalogU64, native_path_units: LWCatalogU64, vm_steps: LWCatalogU64, deadline_ms: LWCatalogU64) {
        self.request_bytes = request_bytes
        self.result_bytes = result_bytes
        self.page_bytes = page_bytes
        self.row_bytes = row_bytes
        self.native_path_units = native_path_units
        self.vm_steps = vm_steps
        self.deadline_ms = deadline_ms
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["request_bytes", "result_bytes", "page_bytes", "row_bytes", "native_path_units", "vm_steps", "deadline_ms"])
        self.request_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("request_bytes"))
        self.result_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("result_bytes"))
        self.page_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("page_bytes"))
        self.row_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("row_bytes"))
        self.native_path_units = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("native_path_units"))
        self.vm_steps = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("vm_steps"))
        self.deadline_ms = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("deadline_ms"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(request_bytes, forKey: LWCatalogCodingKey("request_bytes"))
        try container.encode(result_bytes, forKey: LWCatalogCodingKey("result_bytes"))
        try container.encode(page_bytes, forKey: LWCatalogCodingKey("page_bytes"))
        try container.encode(row_bytes, forKey: LWCatalogCodingKey("row_bytes"))
        try container.encode(native_path_units, forKey: LWCatalogCodingKey("native_path_units"))
        try container.encode(vm_steps, forKey: LWCatalogCodingKey("vm_steps"))
        try container.encode(deadline_ms, forKey: LWCatalogCodingKey("deadline_ms"))
    }
}

/// application::lightroom_migration::Failure (engines/catalog/src/application/lightroom_migration.rs:73).
nonisolated struct LWApplicationLightroomMigrationFailure: Codable, Sendable {
    var code: LWApplicationDtoErrorCode
    var detail: String
    var required: LWCatalogU64?
    var available: LWCatalogU64?
    var poisoned: Bool
    var outcome_unknown: Bool
    init(code: LWApplicationDtoErrorCode, detail: String, required: LWCatalogU64?, available: LWCatalogU64?, poisoned: Bool, outcome_unknown: Bool) {
        self.code = code
        self.detail = detail
        self.required = required
        self.available = available
        self.poisoned = poisoned
        self.outcome_unknown = outcome_unknown
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["code", "detail", "required", "available", "poisoned", "outcome_unknown"])
        self.code = try container.decode(LWApplicationDtoErrorCode.self, forKey: LWCatalogCodingKey("code"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
        self.required = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("required"))
        self.available = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("available"))
        self.poisoned = try container.decode(Bool.self, forKey: LWCatalogCodingKey("poisoned"))
        self.outcome_unknown = try container.decode(Bool.self, forKey: LWCatalogCodingKey("outcome_unknown"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(code, forKey: LWCatalogCodingKey("code"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
        try container.encode(required, forKey: LWCatalogCodingKey("required"))
        try container.encode(available, forKey: LWCatalogCodingKey("available"))
        try container.encode(poisoned, forKey: LWCatalogCodingKey("poisoned"))
        try container.encode(outcome_unknown, forKey: LWCatalogCodingKey("outcome_unknown"))
    }
}

/// application::lightroom_migration::Header (engines/catalog/src/application/lightroom_migration.rs:13).
nonisolated struct LWApplicationLightroomMigrationHeader: Codable, Sendable {
    var catalog: String?
    var destination: LWCatalogNativePath
    var operation: LWLightroomMigrationWorkerWorkerOperation
    var parts: [LWLightroomMigrationWorkerInputPartDescriptor]
    var timeout_ms: LWCatalogU64
    init(catalog: String?, destination: LWCatalogNativePath, operation: LWLightroomMigrationWorkerWorkerOperation, parts: [LWLightroomMigrationWorkerInputPartDescriptor], timeout_ms: LWCatalogU64) {
        self.catalog = catalog
        self.destination = destination
        self.operation = operation
        self.parts = parts
        self.timeout_ms = timeout_ms
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["catalog", "destination", "operation", "parts", "timeout_ms"])
        self.catalog = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("catalog"))
        self.destination = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.operation = try container.decode(LWLightroomMigrationWorkerWorkerOperation.self, forKey: LWCatalogCodingKey("operation"))
        self.parts = try container.decode([LWLightroomMigrationWorkerInputPartDescriptor].self, forKey: LWCatalogCodingKey("parts"))
        self.timeout_ms = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("timeout_ms"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(catalog, forKey: LWCatalogCodingKey("catalog"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(parts, forKey: LWCatalogCodingKey("parts"))
        try container.encode(timeout_ms, forKey: LWCatalogCodingKey("timeout_ms"))
    }
}

/// application::lightroom_migration::Phase (engines/catalog/src/application/lightroom_migration.rs:62).
nonisolated enum LWApplicationLightroomMigrationPhase: String, Codable, Sendable {
    case Uploading = "uploading"
    case Ready = "ready"
    case Running = "running"
    case CancelRequested = "cancel_requested"
    case DrainPending = "drain_pending"
    case Complete = "complete"
    case Failed = "failed"
}

/// application::lightroom_migration::Request (engines/catalog/src/application/lightroom_migration.rs:22).
nonisolated indirect enum LWApplicationLightroomMigrationRequest: Codable, Sendable {
    case Begin(operation: String, header: LWApplicationLightroomMigrationHeader)
    case Upload(`guard`: LWLightroomMigrationWorkerProtocolGuard, role: LWLightroomMigrationWorkerProtocolInputRole, offset: LWCatalogU64, text: String)
    case Finish(`guard`: LWLightroomMigrationWorkerProtocolGuard, role: LWLightroomMigrationWorkerProtocolInputRole, blake3: String)
    case Act(`guard`: LWLightroomMigrationWorkerProtocolGuard)
    case Status(`guard`: LWLightroomMigrationWorkerProtocolGuard)
    case Cancel(`guard`: LWLightroomMigrationWorkerProtocolGuard)
    case RetryDrain(`guard`: LWLightroomMigrationWorkerProtocolGuard)
    case ResultPage(`guard`: LWLightroomMigrationWorkerProtocolGuard, page: LWCatalogU64, offset: LWCatalogU64, maximum_bytes: LWCatalogU64)
    case Discard(`guard`: LWLightroomMigrationWorkerProtocolGuard)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("action"))
        switch discriminator {
        case "begin":
            try container.lwRequireKeys(["action", "operation", "header"])
            self = .Begin(operation: try container.decode(String.self, forKey: LWCatalogCodingKey("operation")), header: try container.decode(LWApplicationLightroomMigrationHeader.self, forKey: LWCatalogCodingKey("header")))
        case "upload":
            try container.lwRequireKeys(["action", "guard", "role", "offset", "text"])
            self = .Upload(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")), role: try container.decode(LWLightroomMigrationWorkerProtocolInputRole.self, forKey: LWCatalogCodingKey("role")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), text: try container.decode(String.self, forKey: LWCatalogCodingKey("text")))
        case "finish":
            try container.lwRequireKeys(["action", "guard", "role", "blake3"])
            self = .Finish(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")), role: try container.decode(LWLightroomMigrationWorkerProtocolInputRole.self, forKey: LWCatalogCodingKey("role")), blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("blake3")))
        case "act":
            try container.lwRequireKeys(["action", "guard"])
            self = .Act(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")))
        case "status":
            try container.lwRequireKeys(["action", "guard"])
            self = .Status(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")))
        case "cancel":
            try container.lwRequireKeys(["action", "guard"])
            self = .Cancel(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")))
        case "retry_drain":
            try container.lwRequireKeys(["action", "guard"])
            self = .RetryDrain(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")))
        case "result_page":
            try container.lwRequireKeys(["action", "guard", "page", "offset", "maximum_bytes"])
            self = .ResultPage(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")), page: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("page")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), maximum_bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("maximum_bytes")))
        case "discard":
            try container.lwRequireKeys(["action", "guard"])
            self = .Discard(guard: try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationLightroomMigrationRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Begin(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("operation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("header"))
        case .Upload(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("upload", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("role"))
            try container.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value3, forKey: LWCatalogCodingKey("text"))
        case .Finish(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("finish", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("role"))
            try container.encode(value2, forKey: LWCatalogCodingKey("blake3"))
        case .Act(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("act", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
        case .Cancel(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
        case .RetryDrain(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("retry_drain", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
        case .ResultPage(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("result_page", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try container.encode(value1, forKey: LWCatalogCodingKey("page"))
            try container.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value3, forKey: LWCatalogCodingKey("maximum_bytes"))
        case .Discard(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("discard", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("guard"))
        }
    }
}

/// application::lightroom_migration::Response (engines/catalog/src/application/lightroom_migration.rs:107).
nonisolated indirect enum LWApplicationLightroomMigrationResponse: Codable, Sendable {
    case Status(LWApplicationLightroomMigrationSnapshot)
    case Page(`guard`: LWLightroomMigrationWorkerProtocolGuard, page: LWCatalogU64, offset: LWCatalogU64, text: String, next_offset: LWCatalogU64?)
    case Discarded(`guard`: LWLightroomMigrationWorkerProtocolGuard)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "status":
            try container.lwRequireKeys(["kind", "data"])
            self = .Status(try container.decode(LWApplicationLightroomMigrationSnapshot.self, forKey: LWCatalogCodingKey("data")))
        case "page":
            try container.lwRequireKeys(["kind", "data"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["guard", "page", "offset", "text", "next_offset"])
            self = .Page(guard: try payload.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")), page: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("page")), offset: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), text: try payload.decode(String.self, forKey: LWCatalogCodingKey("text")), next_offset: try payload.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next_offset")))
        case "discarded":
            try container.lwRequireKeys(["kind", "data"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("data"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["guard"])
            self = .Discarded(guard: try payload.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationLightroomMigrationResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("data"))
        case .Page(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("page", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("guard"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("page"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("text"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("next_offset"))
        case .Discarded(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("discarded", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("data"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("guard"))
        }
    }
}

/// application::lightroom_migration::ResultIdentity (engines/catalog/src/application/lightroom_migration.rs:95).
nonisolated struct LWApplicationLightroomMigrationResultIdentity: Codable, Sendable {
    var bytes: LWCatalogU64
    var blake3: String
    var pages: LWCatalogU64
    init(bytes: LWCatalogU64, blake3: String, pages: LWCatalogU64) {
        self.bytes = bytes
        self.blake3 = blake3
        self.pages = pages
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["bytes", "blake3", "pages"])
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.pages = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("pages"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(pages, forKey: LWCatalogCodingKey("pages"))
    }
}

/// application::lightroom_migration::Snapshot (engines/catalog/src/application/lightroom_migration.rs:83).
nonisolated struct LWApplicationLightroomMigrationSnapshot: Codable, Sendable {
    var `guard`: LWLightroomMigrationWorkerProtocolGuard
    var phase: LWApplicationLightroomMigrationPhase
    var catalog: String?
    var uploaded: LWCatalogU64
    var next_role: LWLightroomMigrationWorkerProtocolInputRole?
    var progress: LWCatalogTriple<String, LWCatalogU64, LWCatalogU64?>?
    var failure: LWApplicationLightroomMigrationFailure?
    var result: LWApplicationLightroomMigrationResultIdentity?
    init(`guard`: LWLightroomMigrationWorkerProtocolGuard, phase: LWApplicationLightroomMigrationPhase, catalog: String?, uploaded: LWCatalogU64, next_role: LWLightroomMigrationWorkerProtocolInputRole?, progress: LWCatalogTriple<String, LWCatalogU64, LWCatalogU64?>?, failure: LWApplicationLightroomMigrationFailure?, result: LWApplicationLightroomMigrationResultIdentity?) {
        self.`guard` = `guard`
        self.phase = phase
        self.catalog = catalog
        self.uploaded = uploaded
        self.next_role = next_role
        self.progress = progress
        self.failure = failure
        self.result = result
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["guard", "phase", "catalog", "uploaded", "next_role", "progress", "failure", "result"])
        self.`guard` = try container.decode(LWLightroomMigrationWorkerProtocolGuard.self, forKey: LWCatalogCodingKey("guard"))
        self.phase = try container.decode(LWApplicationLightroomMigrationPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.catalog = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("catalog"))
        self.uploaded = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("uploaded"))
        self.next_role = try container.decodeIfPresent(LWLightroomMigrationWorkerProtocolInputRole.self, forKey: LWCatalogCodingKey("next_role"))
        self.progress = try container.decodeIfPresent(LWCatalogTriple<String, LWCatalogU64, LWCatalogU64?>.self, forKey: LWCatalogCodingKey("progress"))
        self.failure = try container.decodeIfPresent(LWApplicationLightroomMigrationFailure.self, forKey: LWCatalogCodingKey("failure"))
        self.result = try container.decodeIfPresent(LWApplicationLightroomMigrationResultIdentity.self, forKey: LWCatalogCodingKey("result"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(`guard`, forKey: LWCatalogCodingKey("guard"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(catalog, forKey: LWCatalogCodingKey("catalog"))
        try container.encode(uploaded, forKey: LWCatalogCodingKey("uploaded"))
        try container.encode(next_role, forKey: LWCatalogCodingKey("next_role"))
        try container.encode(progress, forKey: LWCatalogCodingKey("progress"))
        try container.encode(failure, forKey: LWCatalogCodingKey("failure"))
        try container.encode(result, forKey: LWCatalogCodingKey("result"))
    }
}

/// application::metadata::AdobePage (engines/catalog/src/application/metadata.rs:372).
nonisolated struct LWApplicationMetadataAdobePage: Codable, Sendable {
    var row: LWApplicationMetadataImportedRow
    var compatibility: LWCatalogMigrationHistoryCompatibility
    var reason: String
    var input_json: String?
    var coordinate_space: String?
    var properties: LWApplicationMetadataPage<LWApplicationMetadataAdobeProperty>
    var missing: [String]
    var failure: LWLightroomAdobeFailure?
    var contribution_json: String?
    var adobe_rendering_equivalent: Bool
    init(row: LWApplicationMetadataImportedRow, compatibility: LWCatalogMigrationHistoryCompatibility, reason: String, input_json: String?, coordinate_space: String?, properties: LWApplicationMetadataPage<LWApplicationMetadataAdobeProperty>, missing: [String], failure: LWLightroomAdobeFailure?, contribution_json: String?, adobe_rendering_equivalent: Bool) {
        self.row = row
        self.compatibility = compatibility
        self.reason = reason
        self.input_json = input_json
        self.coordinate_space = coordinate_space
        self.properties = properties
        self.missing = missing
        self.failure = failure
        self.contribution_json = contribution_json
        self.adobe_rendering_equivalent = adobe_rendering_equivalent
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.row = try container.decode(LWApplicationMetadataImportedRow.self, forKey: LWCatalogCodingKey("row"))
        self.compatibility = try container.decode(LWCatalogMigrationHistoryCompatibility.self, forKey: LWCatalogCodingKey("compatibility"))
        self.reason = try container.decode(String.self, forKey: LWCatalogCodingKey("reason"))
        self.input_json = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("input_json"))
        self.coordinate_space = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("coordinate_space"))
        self.properties = try container.decode(LWApplicationMetadataPage<LWApplicationMetadataAdobeProperty>.self, forKey: LWCatalogCodingKey("properties"))
        self.missing = try container.decode([String].self, forKey: LWCatalogCodingKey("missing"))
        self.failure = try container.decodeIfPresent(LWLightroomAdobeFailure.self, forKey: LWCatalogCodingKey("failure"))
        self.contribution_json = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("contribution_json"))
        self.adobe_rendering_equivalent = try container.decode(Bool.self, forKey: LWCatalogCodingKey("adobe_rendering_equivalent"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(row, forKey: LWCatalogCodingKey("row"))
        try container.encode(compatibility, forKey: LWCatalogCodingKey("compatibility"))
        try container.encode(reason, forKey: LWCatalogCodingKey("reason"))
        try container.encode(input_json, forKey: LWCatalogCodingKey("input_json"))
        try container.encode(coordinate_space, forKey: LWCatalogCodingKey("coordinate_space"))
        try container.encode(properties, forKey: LWCatalogCodingKey("properties"))
        try container.encode(missing, forKey: LWCatalogCodingKey("missing"))
        try container.encode(failure, forKey: LWCatalogCodingKey("failure"))
        try container.encode(contribution_json, forKey: LWCatalogCodingKey("contribution_json"))
        try container.encode(adobe_rendering_equivalent, forKey: LWCatalogCodingKey("adobe_rendering_equivalent"))
    }
}

/// application::metadata::AdobeProperty (engines/catalog/src/application/metadata.rs:360).
nonisolated struct LWApplicationMetadataAdobeProperty: Codable, Sendable {
    var path_json: String
    var namespace: String?
    var name: String
    var lexical: String
    var start: LWCatalogU64
    var end: LWCatalogU64
    var value_json: String
    var disposition: LWLightroomAdobeDisposition
    var reason: String
    init(path_json: String, namespace: String?, name: String, lexical: String, start: LWCatalogU64, end: LWCatalogU64, value_json: String, disposition: LWLightroomAdobeDisposition, reason: String) {
        self.path_json = path_json
        self.namespace = namespace
        self.name = name
        self.lexical = lexical
        self.start = start
        self.end = end
        self.value_json = value_json
        self.disposition = disposition
        self.reason = reason
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.path_json = try container.decode(String.self, forKey: LWCatalogCodingKey("path_json"))
        self.namespace = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("namespace"))
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.lexical = try container.decode(String.self, forKey: LWCatalogCodingKey("lexical"))
        self.start = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("start"))
        self.end = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("end"))
        self.value_json = try container.decode(String.self, forKey: LWCatalogCodingKey("value_json"))
        self.disposition = try container.decode(LWLightroomAdobeDisposition.self, forKey: LWCatalogCodingKey("disposition"))
        self.reason = try container.decode(String.self, forKey: LWCatalogCodingKey("reason"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(path_json, forKey: LWCatalogCodingKey("path_json"))
        try container.encode(namespace, forKey: LWCatalogCodingKey("namespace"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(lexical, forKey: LWCatalogCodingKey("lexical"))
        try container.encode(start, forKey: LWCatalogCodingKey("start"))
        try container.encode(end, forKey: LWCatalogCodingKey("end"))
        try container.encode(value_json, forKey: LWCatalogCodingKey("value_json"))
        try container.encode(disposition, forKey: LWCatalogCodingKey("disposition"))
        try container.encode(reason, forKey: LWCatalogCodingKey("reason"))
    }
}

/// application::metadata::BlobSource (engines/catalog/src/application/metadata.rs:125).
nonisolated indirect enum LWApplicationMetadataBlobSource: Codable, Sendable {
    case Packet(observation: LWCatalogI64, ordinal: LWCatalogI64)
    case Model(id: LWCatalogI64)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "packet":
            try container.lwRequireKeys(["kind", "observation", "ordinal"])
            self = .Packet(observation: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation")), ordinal: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("ordinal")))
        case "model":
            try container.lwRequireKeys(["kind", "id"])
            self = .Model(id: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataBlobSource variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Packet(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("packet", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("observation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("ordinal"))
        case .Model(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("model", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("id"))
        }
    }
}

/// application::metadata::Candidate (engines/catalog/src/application/metadata.rs:229).
nonisolated struct LWApplicationMetadataCandidate: Codable, Sendable {
    var model: LWCatalogI64
    var source: LWCatalogI64
    var observation: LWCatalogI64
    var ordinal: LWCatalogI64
    var ambiguous: Bool
    var semantic_hash: String
    var value: LWApplicationMetadataRetainedText
    init(model: LWCatalogI64, source: LWCatalogI64, observation: LWCatalogI64, ordinal: LWCatalogI64, ambiguous: Bool, semantic_hash: String, value: LWApplicationMetadataRetainedText) {
        self.model = model
        self.source = source
        self.observation = observation
        self.ordinal = ordinal
        self.ambiguous = ambiguous
        self.semantic_hash = semantic_hash
        self.value = value
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.model = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("model"))
        self.source = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source"))
        self.observation = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation"))
        self.ordinal = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("ordinal"))
        self.ambiguous = try container.decode(Bool.self, forKey: LWCatalogCodingKey("ambiguous"))
        self.semantic_hash = try container.decode(String.self, forKey: LWCatalogCodingKey("semantic_hash"))
        self.value = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("value"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(model, forKey: LWCatalogCodingKey("model"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(observation, forKey: LWCatalogCodingKey("observation"))
        try container.encode(ordinal, forKey: LWCatalogCodingKey("ordinal"))
        try container.encode(ambiguous, forKey: LWCatalogCodingKey("ambiguous"))
        try container.encode(semantic_hash, forKey: LWCatalogCodingKey("semantic_hash"))
        try container.encode(value, forKey: LWCatalogCodingKey("value"))
    }
}

/// application::metadata::Chunk (engines/catalog/src/application/metadata.rs:294).
nonisolated struct LWApplicationMetadataChunk: Codable, Sendable {
    var bytes: [UInt8]
    var offset: LWCatalogU64
    var total: LWCatalogU64
    var next: LWCatalogU64?
    var blake3: String?
    var verified: Bool
    var inspected_bytes: LWCatalogU64
    init(bytes: [UInt8], offset: LWCatalogU64, total: LWCatalogU64, next: LWCatalogU64?, blake3: String?, verified: Bool, inspected_bytes: LWCatalogU64) {
        self.bytes = bytes
        self.offset = offset
        self.total = total
        self.next = next
        self.blake3 = blake3
        self.verified = verified
        self.inspected_bytes = inspected_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.bytes = try container.decode([UInt8].self, forKey: LWCatalogCodingKey("bytes"))
        self.offset = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset"))
        self.total = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total"))
        self.next = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next"))
        self.blake3 = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.verified = try container.decode(Bool.self, forKey: LWCatalogCodingKey("verified"))
        self.inspected_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("inspected_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(offset, forKey: LWCatalogCodingKey("offset"))
        try container.encode(total, forKey: LWCatalogCodingKey("total"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(verified, forKey: LWCatalogCodingKey("verified"))
        try container.encode(inspected_bytes, forKey: LWCatalogCodingKey("inspected_bytes"))
    }
}

/// application::metadata::ColumnPage (engines/catalog/src/application/metadata.rs:353).
nonisolated struct LWApplicationMetadataColumnPage: Codable, Sendable {
    var row: LWApplicationMetadataImportedRow
    var columns: LWApplicationMetadataPage<LWApplicationMetadataImportedColumn>
    var types_complete: Bool
    var reason: String
    init(row: LWApplicationMetadataImportedRow, columns: LWApplicationMetadataPage<LWApplicationMetadataImportedColumn>, types_complete: Bool, reason: String) {
        self.row = row
        self.columns = columns
        self.types_complete = types_complete
        self.reason = reason
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.row = try container.decode(LWApplicationMetadataImportedRow.self, forKey: LWCatalogCodingKey("row"))
        self.columns = try container.decode(LWApplicationMetadataPage<LWApplicationMetadataImportedColumn>.self, forKey: LWCatalogCodingKey("columns"))
        self.types_complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("types_complete"))
        self.reason = try container.decode(String.self, forKey: LWCatalogCodingKey("reason"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(row, forKey: LWCatalogCodingKey("row"))
        try container.encode(columns, forKey: LWCatalogCodingKey("columns"))
        try container.encode(types_complete, forKey: LWCatalogCodingKey("types_complete"))
        try container.encode(reason, forKey: LWCatalogCodingKey("reason"))
    }
}

/// application::metadata::Decision (engines/catalog/src/application/metadata.rs:279).
nonisolated struct LWApplicationMetadataDecision: Codable, Sendable {
    var id: LWCatalogI64
    var revision: LWCatalogI64
    var action: LWApplicationMetadataRetainedText
    var detail: LWApplicationMetadataRetainedText
    var created_at: LWApplicationMetadataRetainedText
    init(id: LWCatalogI64, revision: LWCatalogI64, action: LWApplicationMetadataRetainedText, detail: LWApplicationMetadataRetainedText, created_at: LWApplicationMetadataRetainedText) {
        self.id = id
        self.revision = revision
        self.action = action
        self.detail = detail
        self.created_at = created_at
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.action = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("action"))
        self.detail = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("detail"))
        self.created_at = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("created_at"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(action, forKey: LWCatalogCodingKey("action"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
        try container.encode(created_at, forKey: LWCatalogCodingKey("created_at"))
    }
}

/// application::metadata::DecisionText (engines/catalog/src/application/metadata.rs:156).
nonisolated enum LWApplicationMetadataDecisionText: String, Codable, Sendable {
    case Action = "action"
    case Detail = "detail"
    case CreatedAt = "created_at"
}

/// application::metadata::Field (engines/catalog/src/application/metadata.rs:222).
nonisolated struct LWApplicationMetadataField: Codable, Sendable {
    var name: String
    var value: LWApplicationMetadataRetainedText?
    var conflicted: Bool
    var selected_model: LWCatalogI64?
    init(name: String, value: LWApplicationMetadataRetainedText?, conflicted: Bool, selected_model: LWCatalogI64?) {
        self.name = name
        self.value = value
        self.conflicted = conflicted
        self.selected_model = selected_model
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.value = try container.decodeIfPresent(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("value"))
        self.conflicted = try container.decode(Bool.self, forKey: LWCatalogCodingKey("conflicted"))
        self.selected_model = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("selected_model"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(value, forKey: LWCatalogCodingKey("value"))
        try container.encode(conflicted, forKey: LWCatalogCodingKey("conflicted"))
        try container.encode(selected_model, forKey: LWCatalogCodingKey("selected_model"))
    }
}

/// application::metadata::FileInstance (engines/catalog/src/application/metadata.rs:287).
nonisolated struct LWApplicationMetadataFileInstance: Codable, Sendable {
    var id: LWCatalogI64
    var source: LWCatalogI64
    var provenance: LWApplicationMetadataRetainedText
    var observed_at: LWApplicationMetadataRetainedText
    init(id: LWCatalogI64, source: LWCatalogI64, provenance: LWApplicationMetadataRetainedText, observed_at: LWApplicationMetadataRetainedText) {
        self.id = id
        self.source = source
        self.provenance = provenance
        self.observed_at = observed_at
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.source = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source"))
        self.provenance = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("provenance"))
        self.observed_at = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("observed_at"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(provenance, forKey: LWCatalogCodingKey("provenance"))
        try container.encode(observed_at, forKey: LWCatalogCodingKey("observed_at"))
    }
}

/// application::metadata::FileInstanceText (engines/catalog/src/application/metadata.rs:163).
nonisolated enum LWApplicationMetadataFileInstanceText: String, Codable, Sendable {
    case Provenance = "provenance"
    case ObservedAt = "observed_at"
}

/// application::metadata::ImportedColumn (engines/catalog/src/application/metadata.rs:346).
nonisolated struct LWApplicationMetadataImportedColumn: Codable, Sendable {
    var ordinal: LWCatalogU64
    var name: String
    var cell_type: String?
    var bytes: LWCatalogU64?
    init(ordinal: LWCatalogU64, name: String, cell_type: String?, bytes: LWCatalogU64?) {
        self.ordinal = ordinal
        self.name = name
        self.cell_type = cell_type
        self.bytes = bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.ordinal = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("ordinal"))
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.cell_type = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("cell_type"))
        self.bytes = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(ordinal, forKey: LWCatalogCodingKey("ordinal"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(cell_type, forKey: LWCatalogCodingKey("cell_type"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
    }
}

/// application::metadata::ImportedField (engines/catalog/src/application/metadata.rs:339).
nonisolated struct LWApplicationMetadataImportedField: Codable, Sendable {
    var name: String
    var representation: String
    var bytes: LWCatalogU64
    var scalar_json: String?
    init(name: String, representation: String, bytes: LWCatalogU64, scalar_json: String?) {
        self.name = name
        self.representation = representation
        self.bytes = bytes
        self.scalar_json = scalar_json
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.representation = try container.decode(String.self, forKey: LWCatalogCodingKey("representation"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.scalar_json = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("scalar_json"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(representation, forKey: LWCatalogCodingKey("representation"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(scalar_json, forKey: LWCatalogCodingKey("scalar_json"))
    }
}

/// application::metadata::ImportedPage (engines/catalog/src/application/metadata.rs:327).
nonisolated struct LWApplicationMetadataImportedPage: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var input: String
    var anchor_json: String
    var row: LWApplicationMetadataImportedRow
    var relations: [LWApplicationMetadataRelation]
    var next: String?
    var coverage_complete: Bool
    var keys_complete: Bool
    var adobe_rendering_equivalent: Bool
    init(key: LWCatalogEditsVariantKey, input: String, anchor_json: String, row: LWApplicationMetadataImportedRow, relations: [LWApplicationMetadataRelation], next: String?, coverage_complete: Bool, keys_complete: Bool, adobe_rendering_equivalent: Bool) {
        self.key = key
        self.input = input
        self.anchor_json = anchor_json
        self.row = row
        self.relations = relations
        self.next = next
        self.coverage_complete = coverage_complete
        self.keys_complete = keys_complete
        self.adobe_rendering_equivalent = adobe_rendering_equivalent
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.input = try container.decode(String.self, forKey: LWCatalogCodingKey("input"))
        self.anchor_json = try container.decode(String.self, forKey: LWCatalogCodingKey("anchor_json"))
        self.row = try container.decode(LWApplicationMetadataImportedRow.self, forKey: LWCatalogCodingKey("row"))
        self.relations = try container.decode([LWApplicationMetadataRelation].self, forKey: LWCatalogCodingKey("relations"))
        self.next = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("next"))
        self.coverage_complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("coverage_complete"))
        self.keys_complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("keys_complete"))
        self.adobe_rendering_equivalent = try container.decode(Bool.self, forKey: LWCatalogCodingKey("adobe_rendering_equivalent"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(input, forKey: LWCatalogCodingKey("input"))
        try container.encode(anchor_json, forKey: LWCatalogCodingKey("anchor_json"))
        try container.encode(row, forKey: LWCatalogCodingKey("row"))
        try container.encode(relations, forKey: LWCatalogCodingKey("relations"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(coverage_complete, forKey: LWCatalogCodingKey("coverage_complete"))
        try container.encode(keys_complete, forKey: LWCatalogCodingKey("keys_complete"))
        try container.encode(adobe_rendering_equivalent, forKey: LWCatalogCodingKey("adobe_rendering_equivalent"))
    }
}

/// application::metadata::ImportedRow (engines/catalog/src/application/metadata.rs:304).
nonisolated struct LWApplicationMetadataImportedRow: Codable, Sendable {
    var record: LWCatalogI64
    var source_key_json: String
    var source_id: String
    var entity_record: LWCatalogI64
    var table_record: LWCatalogI64
    var cells_field: String
    var cells_json_bytes: LWCatalogU64
    var classification: LWCatalogMigrationHistoryClassification
    init(record: LWCatalogI64, source_key_json: String, source_id: String, entity_record: LWCatalogI64, table_record: LWCatalogI64, cells_field: String, cells_json_bytes: LWCatalogU64, classification: LWCatalogMigrationHistoryClassification) {
        self.record = record
        self.source_key_json = source_key_json
        self.source_id = source_id
        self.entity_record = entity_record
        self.table_record = table_record
        self.cells_field = cells_field
        self.cells_json_bytes = cells_json_bytes
        self.classification = classification
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.record = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("record"))
        self.source_key_json = try container.decode(String.self, forKey: LWCatalogCodingKey("source_key_json"))
        self.source_id = try container.decode(String.self, forKey: LWCatalogCodingKey("source_id"))
        self.entity_record = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("entity_record"))
        self.table_record = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("table_record"))
        self.cells_field = try container.decode(String.self, forKey: LWCatalogCodingKey("cells_field"))
        self.cells_json_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("cells_json_bytes"))
        self.classification = try container.decode(LWCatalogMigrationHistoryClassification.self, forKey: LWCatalogCodingKey("classification"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(record, forKey: LWCatalogCodingKey("record"))
        try container.encode(source_key_json, forKey: LWCatalogCodingKey("source_key_json"))
        try container.encode(source_id, forKey: LWCatalogCodingKey("source_id"))
        try container.encode(entity_record, forKey: LWCatalogCodingKey("entity_record"))
        try container.encode(table_record, forKey: LWCatalogCodingKey("table_record"))
        try container.encode(cells_field, forKey: LWCatalogCodingKey("cells_field"))
        try container.encode(cells_json_bytes, forKey: LWCatalogCodingKey("cells_json_bytes"))
        try container.encode(classification, forKey: LWCatalogCodingKey("classification"))
    }
}

/// application::metadata::Model (engines/catalog/src/application/metadata.rs:262).
nonisolated struct LWApplicationMetadataModel: Codable, Sendable {
    var id: LWCatalogI64
    var ordinal: LWCatalogI64
    var blob_hash: String
    var bytes: LWCatalogU64
    var descriptor: LWApplicationMetadataRetainedText
    var projection: LWApplicationMetadataRetainedText
    var error: LWApplicationMetadataRetainedText?
    init(id: LWCatalogI64, ordinal: LWCatalogI64, blob_hash: String, bytes: LWCatalogU64, descriptor: LWApplicationMetadataRetainedText, projection: LWApplicationMetadataRetainedText, error: LWApplicationMetadataRetainedText?) {
        self.id = id
        self.ordinal = ordinal
        self.blob_hash = blob_hash
        self.bytes = bytes
        self.descriptor = descriptor
        self.projection = projection
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.ordinal = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("ordinal"))
        self.blob_hash = try container.decode(String.self, forKey: LWCatalogCodingKey("blob_hash"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.descriptor = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("descriptor"))
        self.projection = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("projection"))
        self.error = try container.decodeIfPresent(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(ordinal, forKey: LWCatalogCodingKey("ordinal"))
        try container.encode(blob_hash, forKey: LWCatalogCodingKey("blob_hash"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(descriptor, forKey: LWCatalogCodingKey("descriptor"))
        try container.encode(projection, forKey: LWCatalogCodingKey("projection"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::metadata::ModelText (engines/catalog/src/application/metadata.rs:149).
nonisolated enum LWApplicationMetadataModelText: String, Codable, Sendable {
    case Descriptor = "descriptor"
    case Projection = "projection"
    case Error = "error"
}

/// application::metadata::Observation (engines/catalog/src/application/metadata.rs:251).
nonisolated struct LWApplicationMetadataObservation: Codable, Sendable {
    var id: LWCatalogI64
    var source: LWCatalogI64
    var revision: LWApplicationMetadataRetainedText
    var status: LWApplicationMetadataRetainedText
    var issues: LWApplicationMetadataRetainedText
    var provenance: LWApplicationMetadataRetainedText
    var created_at: LWApplicationMetadataRetainedText
    var current: Bool
    init(id: LWCatalogI64, source: LWCatalogI64, revision: LWApplicationMetadataRetainedText, status: LWApplicationMetadataRetainedText, issues: LWApplicationMetadataRetainedText, provenance: LWApplicationMetadataRetainedText, created_at: LWApplicationMetadataRetainedText, current: Bool) {
        self.id = id
        self.source = source
        self.revision = revision
        self.status = status
        self.issues = issues
        self.provenance = provenance
        self.created_at = created_at
        self.current = current
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.source = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source"))
        self.revision = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("revision"))
        self.status = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("status"))
        self.issues = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("issues"))
        self.provenance = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("provenance"))
        self.created_at = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("created_at"))
        self.current = try container.decode(Bool.self, forKey: LWCatalogCodingKey("current"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
        try container.encode(issues, forKey: LWCatalogCodingKey("issues"))
        try container.encode(provenance, forKey: LWCatalogCodingKey("provenance"))
        try container.encode(created_at, forKey: LWCatalogCodingKey("created_at"))
        try container.encode(current, forKey: LWCatalogCodingKey("current"))
    }
}

/// application::metadata::ObservationText (engines/catalog/src/application/metadata.rs:140).
nonisolated enum LWApplicationMetadataObservationText: String, Codable, Sendable {
    case Revision = "revision"
    case Status = "status"
    case Issues = "issues"
    case Provenance = "provenance"
    case CreatedAt = "created_at"
}

/// application::metadata::Packet (engines/catalog/src/application/metadata.rs:272).
nonisolated struct LWApplicationMetadataPacket: Codable, Sendable {
    var ordinal: LWCatalogI64
    var blob_hash: String
    var bytes: LWCatalogU64
    var descriptor: LWApplicationMetadataRetainedText
    init(ordinal: LWCatalogI64, blob_hash: String, bytes: LWCatalogU64, descriptor: LWApplicationMetadataRetainedText) {
        self.ordinal = ordinal
        self.blob_hash = blob_hash
        self.bytes = bytes
        self.descriptor = descriptor
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.ordinal = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("ordinal"))
        self.blob_hash = try container.decode(String.self, forKey: LWCatalogCodingKey("blob_hash"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.descriptor = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("descriptor"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(ordinal, forKey: LWCatalogCodingKey("ordinal"))
        try container.encode(blob_hash, forKey: LWCatalogCodingKey("blob_hash"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(descriptor, forKey: LWCatalogCodingKey("descriptor"))
    }
}

/// application::metadata::Page (engines/catalog/src/application/metadata.rs:216).
nonisolated struct LWApplicationMetadataPage<T: Codable & Sendable>: Codable, Sendable {
    var rows: [T]
    var next: String?
    var scanned: LWCatalogU64
    init(rows: [T], next: String?, scanned: LWCatalogU64) {
        self.rows = rows
        self.next = next
        self.scanned = scanned
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.rows = try container.decode([T].self, forKey: LWCatalogCodingKey("rows"))
        self.next = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("next"))
        self.scanned = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("scanned"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(rows, forKey: LWCatalogCodingKey("rows"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(scanned, forKey: LWCatalogCodingKey("scanned"))
    }
}

/// application::metadata::RecordRole (engines/catalog/src/application/metadata.rs:204).
nonisolated enum LWApplicationMetadataRecordRole: String, Codable, Sendable {
    case Row = "row"
    case Table = "table"
    case Entity = "entity"
}

/// application::metadata::Relation (engines/catalog/src/application/metadata.rs:315).
nonisolated struct LWApplicationMetadataRelation: Codable, Sendable {
    var reference_record: LWCatalogI64
    var source_id: String
    var field: String
    var target_table: String
    var target_key: String
    var source: LWApplicationMetadataImportedRow?
    var target: LWApplicationMetadataImportedRow?
    var compatibility: LWCatalogMigrationHistoryCompatibility
    var anchor_json: String?
    init(reference_record: LWCatalogI64, source_id: String, field: String, target_table: String, target_key: String, source: LWApplicationMetadataImportedRow?, target: LWApplicationMetadataImportedRow?, compatibility: LWCatalogMigrationHistoryCompatibility, anchor_json: String?) {
        self.reference_record = reference_record
        self.source_id = source_id
        self.field = field
        self.target_table = target_table
        self.target_key = target_key
        self.source = source
        self.target = target
        self.compatibility = compatibility
        self.anchor_json = anchor_json
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.reference_record = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("reference_record"))
        self.source_id = try container.decode(String.self, forKey: LWCatalogCodingKey("source_id"))
        self.field = try container.decode(String.self, forKey: LWCatalogCodingKey("field"))
        self.target_table = try container.decode(String.self, forKey: LWCatalogCodingKey("target_table"))
        self.target_key = try container.decode(String.self, forKey: LWCatalogCodingKey("target_key"))
        self.source = try container.decodeIfPresent(LWApplicationMetadataImportedRow.self, forKey: LWCatalogCodingKey("source"))
        self.target = try container.decodeIfPresent(LWApplicationMetadataImportedRow.self, forKey: LWCatalogCodingKey("target"))
        self.compatibility = try container.decode(LWCatalogMigrationHistoryCompatibility.self, forKey: LWCatalogCodingKey("compatibility"))
        self.anchor_json = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("anchor_json"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(reference_record, forKey: LWCatalogCodingKey("reference_record"))
        try container.encode(source_id, forKey: LWCatalogCodingKey("source_id"))
        try container.encode(field, forKey: LWCatalogCodingKey("field"))
        try container.encode(target_table, forKey: LWCatalogCodingKey("target_table"))
        try container.encode(target_key, forKey: LWCatalogCodingKey("target_key"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(target, forKey: LWCatalogCodingKey("target"))
        try container.encode(compatibility, forKey: LWCatalogCodingKey("compatibility"))
        try container.encode(anchor_json, forKey: LWCatalogCodingKey("anchor_json"))
    }
}

/// application::metadata::Request (engines/catalog/src/application/metadata.rs:21).
nonisolated indirect enum LWApplicationMetadataRequest: Codable, Sendable {
    case Identity(key: LWCatalogEditsVariantKey)
    case Fields(identity: LWApplicationOrganizationImageIdentity, after: String?, limit: UInt16)
    case Candidates(identity: LWApplicationOrganizationImageIdentity, field: String, after: String?, limit: UInt16)
    case Sources(identity: LWApplicationOrganizationImageIdentity, after: String?, limit: UInt16)
    case Observations(identity: LWApplicationOrganizationImageIdentity, after: String?, limit: UInt16)
    case Models(identity: LWApplicationOrganizationImageIdentity, observation: LWCatalogI64, after: String?, limit: UInt16)
    case Packets(identity: LWApplicationOrganizationImageIdentity, observation: LWCatalogI64, after: String?, limit: UInt16)
    case Decisions(identity: LWApplicationOrganizationImageIdentity, after: String?, limit: UInt16)
    case FileInstances(identity: LWApplicationOrganizationImageIdentity, after: String?, limit: UInt16)
    case Resolve(key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, field: String, model: LWCatalogI64)
    case TextChunk(identity: LWApplicationOrganizationImageIdentity, reference: LWApplicationMetadataTextReference, offset: LWCatalogU64, length: UInt32)
    case BlobChunk(key: LWCatalogEditsVariantKey, source: LWApplicationMetadataBlobSource, offset: LWCatalogU64, length: UInt32)
    case ImportHistory(key: LWCatalogEditsVariantKey, anchor_json: String?, direction: LWCatalogMigrationHistoryDirection, after_json: String?, limit: UInt16)
    case ImportColumns(key: LWCatalogEditsVariantKey, anchor_json: String, after: LWCatalogU64, limit: UInt16)
    case ImportFields(key: LWCatalogEditsVariantKey, anchor_json: String, role: LWApplicationMetadataRecordRole, after: String, limit: UInt16)
    case ImportChunk(key: LWCatalogEditsVariantKey, anchor_json: String, role: LWApplicationMetadataRecordRole, field: String, offset: LWCatalogU64, length: UInt32)
    case AdobeProperties(key: LWCatalogEditsVariantKey, anchor_json: String, column: String, settings_path_json: String, after: LWCatalogU64, limit: UInt16)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "identity":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key"])
            self = .Identity(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")))
        case "fields":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "after", "limit"])
            self = .Fields(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "candidates":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "field", "after", "limit"])
            self = .Candidates(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), field: try payload.decode(String.self, forKey: LWCatalogCodingKey("field")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "sources":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "after", "limit"])
            self = .Sources(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "observations":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "after", "limit"])
            self = .Observations(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "models":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "observation", "after", "limit"])
            self = .Models(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), observation: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "packets":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "observation", "after", "limit"])
            self = .Packets(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), observation: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "decisions":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "after", "limit"])
            self = .Decisions(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "file_instances":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "after", "limit"])
            self = .FileInstances(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "resolve":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "expected_revision", "field", "model"])
            self = .Resolve(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), field: try payload.decode(String.self, forKey: LWCatalogCodingKey("field")), model: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("model")))
        case "text_chunk":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "reference", "offset", "length"])
            self = .TextChunk(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), reference: try payload.decode(LWApplicationMetadataTextReference.self, forKey: LWCatalogCodingKey("reference")), offset: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), length: try payload.decode(UInt32.self, forKey: LWCatalogCodingKey("length")))
        case "blob_chunk":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "source", "offset", "length"])
            self = .BlobChunk(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), source: try payload.decode(LWApplicationMetadataBlobSource.self, forKey: LWCatalogCodingKey("source")), offset: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), length: try payload.decode(UInt32.self, forKey: LWCatalogCodingKey("length")))
        case "import_history":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "anchor_json", "direction", "after_json", "limit"])
            self = .ImportHistory(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), anchor_json: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("anchor_json")), direction: try payload.decode(LWCatalogMigrationHistoryDirection.self, forKey: LWCatalogCodingKey("direction")), after_json: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after_json")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "import_columns":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "anchor_json", "after", "limit"])
            self = .ImportColumns(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), anchor_json: try payload.decode(String.self, forKey: LWCatalogCodingKey("anchor_json")), after: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "import_fields":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "anchor_json", "role", "after", "limit"])
            self = .ImportFields(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), anchor_json: try payload.decode(String.self, forKey: LWCatalogCodingKey("anchor_json")), role: try payload.decode(LWApplicationMetadataRecordRole.self, forKey: LWCatalogCodingKey("role")), after: try payload.decode(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "import_chunk":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "anchor_json", "role", "field", "offset", "length"])
            self = .ImportChunk(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), anchor_json: try payload.decode(String.self, forKey: LWCatalogCodingKey("anchor_json")), role: try payload.decode(LWApplicationMetadataRecordRole.self, forKey: LWCatalogCodingKey("role")), field: try payload.decode(String.self, forKey: LWCatalogCodingKey("field")), offset: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), length: try payload.decode(UInt32.self, forKey: LWCatalogCodingKey("length")))
        case "adobe_properties":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "anchor_json", "column", "settings_path_json", "after", "limit"])
            self = .AdobeProperties(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), anchor_json: try payload.decode(String.self, forKey: LWCatalogCodingKey("anchor_json")), column: try payload.decode(String.self, forKey: LWCatalogCodingKey("column")), settings_path_json: try payload.decode(String.self, forKey: LWCatalogCodingKey("settings_path_json")), after: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Identity(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("identity", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
        case .Fields(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("fields", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Candidates(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("candidates", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("field"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Sources(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sources", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Observations(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("observations", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Models(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("models", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("observation"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Packets(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("packets", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("observation"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Decisions(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("decisions", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .FileInstances(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("file_instances", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Resolve(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("resolve", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("field"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("model"))
        case .TextChunk(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("text_chunk", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("reference"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("length"))
        case .BlobChunk(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("blob_chunk", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("source"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("length"))
        case .ImportHistory(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_history", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("anchor_json"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("direction"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("after_json"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("limit"))
        case .ImportColumns(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_columns", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("anchor_json"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .ImportFields(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_fields", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("anchor_json"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("role"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("limit"))
        case .ImportChunk(let value0, let value1, let value2, let value3, let value4, let value5):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_chunk", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("anchor_json"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("role"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("field"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("offset"))
            try payload.encode(value5, forKey: LWCatalogCodingKey("length"))
        case .AdobeProperties(let value0, let value1, let value2, let value3, let value4, let value5):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("adobe_properties", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("anchor_json"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("column"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("settings_path_json"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value5, forKey: LWCatalogCodingKey("limit"))
        }
    }
}

/// application::metadata::Response (engines/catalog/src/application/metadata.rs:386).
nonisolated indirect enum LWApplicationMetadataResponse: Codable, Sendable {
    case Identity(LWApplicationOrganizationImageIdentity)
    case Fields(LWApplicationMetadataPage<LWApplicationMetadataField>)
    case Candidates(LWApplicationMetadataPage<LWApplicationMetadataCandidate>)
    case Sources(LWApplicationMetadataPage<LWApplicationMetadataSource>)
    case Observations(LWApplicationMetadataPage<LWApplicationMetadataObservation>)
    case Models(LWApplicationMetadataPage<LWApplicationMetadataModel>)
    case Packets(LWApplicationMetadataPage<LWApplicationMetadataPacket>)
    case Decisions(LWApplicationMetadataPage<LWApplicationMetadataDecision>)
    case FileInstances(LWApplicationMetadataPage<LWApplicationMetadataFileInstance>)
    case Changed(revision: LWCatalogI64)
    case Chunk(LWApplicationMetadataChunk)
    case ImportHistory(LWApplicationMetadataImportedPage)
    case ImportFields(LWApplicationMetadataPage<LWApplicationMetadataImportedField>)
    case ImportColumns(LWApplicationMetadataColumnPage)
    case AdobeProperties(LWApplicationMetadataAdobePage)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "identity":
            self = .Identity(try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("value")))
        case "fields":
            self = .Fields(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataField>.self, forKey: LWCatalogCodingKey("value")))
        case "candidates":
            self = .Candidates(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataCandidate>.self, forKey: LWCatalogCodingKey("value")))
        case "sources":
            self = .Sources(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataSource>.self, forKey: LWCatalogCodingKey("value")))
        case "observations":
            self = .Observations(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataObservation>.self, forKey: LWCatalogCodingKey("value")))
        case "models":
            self = .Models(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataModel>.self, forKey: LWCatalogCodingKey("value")))
        case "packets":
            self = .Packets(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataPacket>.self, forKey: LWCatalogCodingKey("value")))
        case "decisions":
            self = .Decisions(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataDecision>.self, forKey: LWCatalogCodingKey("value")))
        case "file_instances":
            self = .FileInstances(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataFileInstance>.self, forKey: LWCatalogCodingKey("value")))
        case "changed":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Changed(revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")))
        case "chunk":
            self = .Chunk(try container.decode(LWApplicationMetadataChunk.self, forKey: LWCatalogCodingKey("value")))
        case "import_history":
            self = .ImportHistory(try container.decode(LWApplicationMetadataImportedPage.self, forKey: LWCatalogCodingKey("value")))
        case "import_fields":
            self = .ImportFields(try container.decode(LWApplicationMetadataPage<LWApplicationMetadataImportedField>.self, forKey: LWCatalogCodingKey("value")))
        case "import_columns":
            self = .ImportColumns(try container.decode(LWApplicationMetadataColumnPage.self, forKey: LWCatalogCodingKey("value")))
        case "adobe_properties":
            self = .AdobeProperties(try container.decode(LWApplicationMetadataAdobePage.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Identity(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("identity", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Fields(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("fields", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Candidates(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("candidates", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Sources(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sources", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Observations(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("observations", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Models(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("models", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Packets(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("packets", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Decisions(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("decisions", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .FileInstances(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("file_instances", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Changed(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("changed", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("revision"))
        case .Chunk(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("chunk", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .ImportHistory(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_history", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .ImportFields(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_fields", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .ImportColumns(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("import_columns", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .AdobeProperties(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("adobe_properties", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::metadata::RetainedText (engines/catalog/src/application/metadata.rs:210).
nonisolated struct LWApplicationMetadataRetainedText: Codable, Sendable {
    var bytes: LWCatalogU64
    var inline: String?
    var reference: LWApplicationMetadataTextReference
    init(bytes: LWCatalogU64, inline: String?, reference: LWApplicationMetadataTextReference) {
        self.bytes = bytes
        self.inline = inline
        self.reference = reference
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.inline = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("inline"))
        self.reference = try container.decode(LWApplicationMetadataTextReference.self, forKey: LWCatalogCodingKey("reference"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(inline, forKey: LWCatalogCodingKey("inline"))
        try container.encode(reference, forKey: LWCatalogCodingKey("reference"))
    }
}

/// application::metadata::Source (engines/catalog/src/application/metadata.rs:239).
nonisolated struct LWApplicationMetadataSource: Codable, Sendable {
    var id: LWCatalogI64
    var kind: LWApplicationMetadataRetainedText
    var display: LWApplicationMetadataRetainedText
    var association: LWApplicationMetadataRetainedText
    var availability: LWApplicationMetadataRetainedText
    var locator: LWApplicationMetadataRetainedText
    var observation: LWCatalogI64?
    var status: LWApplicationMetadataRetainedText?
    var issues: LWApplicationMetadataRetainedText?
    init(id: LWCatalogI64, kind: LWApplicationMetadataRetainedText, display: LWApplicationMetadataRetainedText, association: LWApplicationMetadataRetainedText, availability: LWApplicationMetadataRetainedText, locator: LWApplicationMetadataRetainedText, observation: LWCatalogI64?, status: LWApplicationMetadataRetainedText?, issues: LWApplicationMetadataRetainedText?) {
        self.id = id
        self.kind = kind
        self.display = display
        self.association = association
        self.availability = availability
        self.locator = locator
        self.observation = observation
        self.status = status
        self.issues = issues
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.kind = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("kind"))
        self.display = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("display"))
        self.association = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("association"))
        self.availability = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("availability"))
        self.locator = try container.decode(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("locator"))
        self.observation = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation"))
        self.status = try container.decodeIfPresent(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("status"))
        self.issues = try container.decodeIfPresent(LWApplicationMetadataRetainedText.self, forKey: LWCatalogCodingKey("issues"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(display, forKey: LWCatalogCodingKey("display"))
        try container.encode(association, forKey: LWCatalogCodingKey("association"))
        try container.encode(availability, forKey: LWCatalogCodingKey("availability"))
        try container.encode(locator, forKey: LWCatalogCodingKey("locator"))
        try container.encode(observation, forKey: LWCatalogCodingKey("observation"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
        try container.encode(issues, forKey: LWCatalogCodingKey("issues"))
    }
}

/// application::metadata::SourceText (engines/catalog/src/application/metadata.rs:131).
nonisolated enum LWApplicationMetadataSourceText: String, Codable, Sendable {
    case Kind = "kind"
    case Display = "display"
    case Association = "association"
    case Availability = "availability"
    case Locator = "locator"
}

/// application::metadata::TextReference (engines/catalog/src/application/metadata.rs:169).
nonisolated indirect enum LWApplicationMetadataTextReference: Codable, Sendable {
    case Effective(field: String)
    case Candidate(model: LWCatalogI64, field: String)
    case Source(source: LWCatalogI64, field: LWApplicationMetadataSourceText)
    case Observation(observation: LWCatalogI64, field: LWApplicationMetadataObservationText)
    case Model(model: LWCatalogI64, field: LWApplicationMetadataModelText)
    case Packet(observation: LWCatalogI64, ordinal: LWCatalogI64)
    case Decision(decision: LWCatalogI64, field: LWApplicationMetadataDecisionText)
    case FileInstance(instance: LWCatalogI64, field: LWApplicationMetadataFileInstanceText)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "effective":
            try container.lwRequireKeys(["kind", "field"])
            self = .Effective(field: try container.decode(String.self, forKey: LWCatalogCodingKey("field")))
        case "candidate":
            try container.lwRequireKeys(["kind", "model", "field"])
            self = .Candidate(model: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("model")), field: try container.decode(String.self, forKey: LWCatalogCodingKey("field")))
        case "source":
            try container.lwRequireKeys(["kind", "source", "field"])
            self = .Source(source: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source")), field: try container.decode(LWApplicationMetadataSourceText.self, forKey: LWCatalogCodingKey("field")))
        case "observation":
            try container.lwRequireKeys(["kind", "observation", "field"])
            self = .Observation(observation: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation")), field: try container.decode(LWApplicationMetadataObservationText.self, forKey: LWCatalogCodingKey("field")))
        case "model":
            try container.lwRequireKeys(["kind", "model", "field"])
            self = .Model(model: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("model")), field: try container.decode(LWApplicationMetadataModelText.self, forKey: LWCatalogCodingKey("field")))
        case "packet":
            try container.lwRequireKeys(["kind", "observation", "ordinal"])
            self = .Packet(observation: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation")), ordinal: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("ordinal")))
        case "decision":
            try container.lwRequireKeys(["kind", "decision", "field"])
            self = .Decision(decision: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("decision")), field: try container.decode(LWApplicationMetadataDecisionText.self, forKey: LWCatalogCodingKey("field")))
        case "file_instance":
            try container.lwRequireKeys(["kind", "instance", "field"])
            self = .FileInstance(instance: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("instance")), field: try container.decode(LWApplicationMetadataFileInstanceText.self, forKey: LWCatalogCodingKey("field")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataTextReference variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Effective(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("effective", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("field"))
        case .Candidate(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("candidate", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("model"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
        case .Source(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("source", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("source"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
        case .Observation(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("observation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("observation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
        case .Model(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("model", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("model"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
        case .Packet(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("packet", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("observation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("ordinal"))
        case .Decision(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("decision", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("decision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
        case .FileInstance(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("file_instance", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("instance"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
        }
    }
}

/// application::metadata_write::Action (engines/catalog/src/application/metadata_write.rs:66).
nonisolated indirect enum LWApplicationMetadataWriteAction: Codable, Sendable {
    case InputBegin(bytes: LWCatalogU64, expected_blake3: String?, limits: LWApplicationMetadataWriteWriteLimits)
    case InputAppend(token: String, generation: LWCatalogU64, offset: LWCatalogU64, bytes: [UInt8])
    case InputFinish(token: String, generation: LWCatalogU64, bytes: LWCatalogU64, blake3: String)
    case InputDiscard(token: String, generation: LWCatalogU64)
    case Prepare(identity: LWApplicationOrganizationImageIdentity, base_model: LWCatalogI64?, input: String, input_blake3: String)
    case Release(token: String)
    case Commit(review: String, review_digest: String)
    case Resolve(identity: LWApplicationOrganizationImageIdentity, field: String, model: LWCatalogI64)
    case SidecarPlan(identity: LWApplicationOrganizationImageIdentity, base_model: LWCatalogI64, destination: LWCatalogNativePath, limits: LWApplicationMetadataWriteWriteLimits)
    case SidecarApply(operation: String, authority_blake3: String, overwrite_ack: Bool, limits: LWApplicationMetadataWriteWriteLimits)
    case SidecarRecover(operation: String, authority_blake3: String, recovery_directory: LWCatalogNativePath, may_publish_ack: Bool, limits: LWApplicationMetadataWriteWriteLimits)
    case SidecarRestore(operation: String, authority_blake3: String, recovery_directory: LWCatalogNativePath, limits: LWApplicationMetadataWriteWriteLimits)
    case Discover(directory: LWCatalogNativePath)
    case ReconcilePaths(rows: UInt16)
    case EvidenceExport(identity: LWApplicationOrganizationImageIdentity, observation: LWCatalogI64, destination: LWCatalogNativePath, limits: LWApplicationMetadataWriteWriteLimits)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "input_begin":
            try container.lwRequireKeys(["kind", "bytes", "expected_blake3", "limits"])
            self = .InputBegin(bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes")), expected_blake3: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("expected_blake3")), limits: try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "input_append":
            try container.lwRequireKeys(["kind", "token", "generation", "offset", "bytes"])
            self = .InputAppend(token: try container.decode(String.self, forKey: LWCatalogCodingKey("token")), generation: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), bytes: try container.decode([UInt8].self, forKey: LWCatalogCodingKey("bytes")))
        case "input_finish":
            try container.lwRequireKeys(["kind", "token", "generation", "bytes", "blake3"])
            self = .InputFinish(token: try container.decode(String.self, forKey: LWCatalogCodingKey("token")), generation: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation")), bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes")), blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("blake3")))
        case "input_discard":
            try container.lwRequireKeys(["kind", "token", "generation"])
            self = .InputDiscard(token: try container.decode(String.self, forKey: LWCatalogCodingKey("token")), generation: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation")))
        case "prepare":
            try container.lwRequireKeys(["kind", "identity", "base_model", "input", "input_blake3"])
            self = .Prepare(identity: try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), base_model: try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("base_model")), input: try container.decode(String.self, forKey: LWCatalogCodingKey("input")), input_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("input_blake3")))
        case "release":
            try container.lwRequireKeys(["kind", "token"])
            self = .Release(token: try container.decode(String.self, forKey: LWCatalogCodingKey("token")))
        case "commit":
            try container.lwRequireKeys(["kind", "review", "review_digest"])
            self = .Commit(review: try container.decode(String.self, forKey: LWCatalogCodingKey("review")), review_digest: try container.decode(String.self, forKey: LWCatalogCodingKey("review_digest")))
        case "resolve":
            try container.lwRequireKeys(["kind", "identity", "field", "model"])
            self = .Resolve(identity: try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), field: try container.decode(String.self, forKey: LWCatalogCodingKey("field")), model: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("model")))
        case "sidecar_plan":
            try container.lwRequireKeys(["kind", "identity", "base_model", "destination", "limits"])
            self = .SidecarPlan(identity: try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), base_model: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("base_model")), destination: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination")), limits: try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "sidecar_apply":
            try container.lwRequireKeys(["kind", "operation", "authority_blake3", "overwrite_ack", "limits"])
            self = .SidecarApply(operation: try container.decode(String.self, forKey: LWCatalogCodingKey("operation")), authority_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("authority_blake3")), overwrite_ack: try container.decode(Bool.self, forKey: LWCatalogCodingKey("overwrite_ack")), limits: try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "sidecar_recover":
            try container.lwRequireKeys(["kind", "operation", "authority_blake3", "recovery_directory", "may_publish_ack", "limits"])
            self = .SidecarRecover(operation: try container.decode(String.self, forKey: LWCatalogCodingKey("operation")), authority_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("authority_blake3")), recovery_directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("recovery_directory")), may_publish_ack: try container.decode(Bool.self, forKey: LWCatalogCodingKey("may_publish_ack")), limits: try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "sidecar_restore":
            try container.lwRequireKeys(["kind", "operation", "authority_blake3", "recovery_directory", "limits"])
            self = .SidecarRestore(operation: try container.decode(String.self, forKey: LWCatalogCodingKey("operation")), authority_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("authority_blake3")), recovery_directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("recovery_directory")), limits: try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("limits")))
        case "discover":
            try container.lwRequireKeys(["kind", "directory"])
            self = .Discover(directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")))
        case "reconcile_paths":
            try container.lwRequireKeys(["kind", "rows"])
            self = .ReconcilePaths(rows: try container.decode(UInt16.self, forKey: LWCatalogCodingKey("rows")))
        case "evidence_export":
            try container.lwRequireKeys(["kind", "identity", "observation", "destination", "limits"])
            self = .EvidenceExport(identity: try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), observation: try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("observation")), destination: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination")), limits: try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("limits")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataWriteAction variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .InputBegin(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("input_begin", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("bytes"))
            try container.encode(value1, forKey: LWCatalogCodingKey("expected_blake3"))
            try container.encode(value2, forKey: LWCatalogCodingKey("limits"))
        case .InputAppend(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("input_append", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("generation"))
            try container.encode(value2, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value3, forKey: LWCatalogCodingKey("bytes"))
        case .InputFinish(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("input_finish", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("generation"))
            try container.encode(value2, forKey: LWCatalogCodingKey("bytes"))
            try container.encode(value3, forKey: LWCatalogCodingKey("blake3"))
        case .InputDiscard(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("input_discard", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("token"))
            try container.encode(value1, forKey: LWCatalogCodingKey("generation"))
        case .Prepare(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prepare", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try container.encode(value1, forKey: LWCatalogCodingKey("base_model"))
            try container.encode(value2, forKey: LWCatalogCodingKey("input"))
            try container.encode(value3, forKey: LWCatalogCodingKey("input_blake3"))
        case .Release(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("release", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("token"))
        case .Commit(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("commit", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("review"))
            try container.encode(value1, forKey: LWCatalogCodingKey("review_digest"))
        case .Resolve(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("resolve", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try container.encode(value1, forKey: LWCatalogCodingKey("field"))
            try container.encode(value2, forKey: LWCatalogCodingKey("model"))
        case .SidecarPlan(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sidecar_plan", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try container.encode(value1, forKey: LWCatalogCodingKey("base_model"))
            try container.encode(value2, forKey: LWCatalogCodingKey("destination"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limits"))
        case .SidecarApply(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sidecar_apply", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("operation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("authority_blake3"))
            try container.encode(value2, forKey: LWCatalogCodingKey("overwrite_ack"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limits"))
        case .SidecarRecover(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sidecar_recover", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("operation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("authority_blake3"))
            try container.encode(value2, forKey: LWCatalogCodingKey("recovery_directory"))
            try container.encode(value3, forKey: LWCatalogCodingKey("may_publish_ack"))
            try container.encode(value4, forKey: LWCatalogCodingKey("limits"))
        case .SidecarRestore(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sidecar_restore", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("operation"))
            try container.encode(value1, forKey: LWCatalogCodingKey("authority_blake3"))
            try container.encode(value2, forKey: LWCatalogCodingKey("recovery_directory"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limits"))
        case .Discover(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("discover", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("directory"))
        case .ReconcilePaths(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("reconcile_paths", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("rows"))
        case .EvidenceExport(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("evidence_export", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try container.encode(value1, forKey: LWCatalogCodingKey("observation"))
            try container.encode(value2, forKey: LWCatalogCodingKey("destination"))
            try container.encode(value3, forKey: LWCatalogCodingKey("limits"))
        }
    }
}

/// application::metadata_write::Admitted (engines/catalog/src/application/metadata_write.rs:257).
nonisolated struct LWApplicationMetadataWriteAdmitted: Codable, Sendable {
    var operation: String
    var attempt: String
    var request_digest: String
    var epoch: LWCatalogU64
    init(operation: String, attempt: String, request_digest: String, epoch: LWCatalogU64) {
        self.operation = operation
        self.attempt = attempt
        self.request_digest = request_digest
        self.epoch = epoch
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        self.attempt = try container.decode(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.request_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("request_digest"))
        self.epoch = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("epoch"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try container.encode(request_digest, forKey: LWCatalogCodingKey("request_digest"))
        try container.encode(epoch, forKey: LWCatalogCodingKey("epoch"))
    }
}

/// application::metadata_write::Bytes (engines/catalog/src/application/metadata_write.rs:309).
nonisolated struct LWApplicationMetadataWriteBytes: Codable, Sendable {
    var bytes: [UInt8]
    var offset: LWCatalogU64
    var total: LWCatalogU64
    var next: LWCatalogU64?
    var blake3: String
    var verified: Bool
    init(bytes: [UInt8], offset: LWCatalogU64, total: LWCatalogU64, next: LWCatalogU64?, blake3: String, verified: Bool) {
        self.bytes = bytes
        self.offset = offset
        self.total = total
        self.next = next
        self.blake3 = blake3
        self.verified = verified
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.bytes = try container.decode([UInt8].self, forKey: LWCatalogCodingKey("bytes"))
        self.offset = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset"))
        self.total = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total"))
        self.next = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next"))
        self.blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.verified = try container.decode(Bool.self, forKey: LWCatalogCodingKey("verified"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(offset, forKey: LWCatalogCodingKey("offset"))
        try container.encode(total, forKey: LWCatalogCodingKey("total"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(verified, forKey: LWCatalogCodingKey("verified"))
    }
}

/// application::metadata_write::Input (engines/catalog/src/application/metadata_write.rs:264).
nonisolated struct LWApplicationMetadataWriteInput: Codable, Sendable {
    var token: String
    var generation: LWCatalogU64
    var bytes: LWCatalogU64
    var expected_bytes: LWCatalogU64
    var expected_blake3: String?
    var last_offset: LWCatalogU64?
    var last_chunk_blake3: String?
    var sealed: Bool
    var blake3: String?
    init(token: String, generation: LWCatalogU64, bytes: LWCatalogU64, expected_bytes: LWCatalogU64, expected_blake3: String?, last_offset: LWCatalogU64?, last_chunk_blake3: String?, sealed: Bool, blake3: String?) {
        self.token = token
        self.generation = generation
        self.bytes = bytes
        self.expected_bytes = expected_bytes
        self.expected_blake3 = expected_blake3
        self.last_offset = last_offset
        self.last_chunk_blake3 = last_chunk_blake3
        self.sealed = sealed
        self.blake3 = blake3
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.token = try container.decode(String.self, forKey: LWCatalogCodingKey("token"))
        self.generation = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.expected_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("expected_bytes"))
        self.expected_blake3 = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("expected_blake3"))
        self.last_offset = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("last_offset"))
        self.last_chunk_blake3 = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("last_chunk_blake3"))
        self.sealed = try container.decode(Bool.self, forKey: LWCatalogCodingKey("sealed"))
        self.blake3 = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("blake3"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(token, forKey: LWCatalogCodingKey("token"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(expected_bytes, forKey: LWCatalogCodingKey("expected_bytes"))
        try container.encode(expected_blake3, forKey: LWCatalogCodingKey("expected_blake3"))
        try container.encode(last_offset, forKey: LWCatalogCodingKey("last_offset"))
        try container.encode(last_chunk_blake3, forKey: LWCatalogCodingKey("last_chunk_blake3"))
        try container.encode(sealed, forKey: LWCatalogCodingKey("sealed"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
    }
}

/// application::metadata_write::Operation (engines/catalog/src/application/metadata_write.rs:318).
nonisolated struct LWApplicationMetadataWriteOperation: Codable, Sendable {
    var id: String
    var attempt: String
    var request_digest: String
    var epoch: LWCatalogU64
    var kind: String
    var phase: String
    var stage: String
    var cancel_requested: Bool
    var progress: LWCatalogU64
    var result: LWCatalogJSON?
    var error: String?
    init(id: String, attempt: String, request_digest: String, epoch: LWCatalogU64, kind: String, phase: String, stage: String, cancel_requested: Bool, progress: LWCatalogU64, result: LWCatalogJSON?, error: String?) {
        self.id = id
        self.attempt = attempt
        self.request_digest = request_digest
        self.epoch = epoch
        self.kind = kind
        self.phase = phase
        self.stage = stage
        self.cancel_requested = cancel_requested
        self.progress = progress
        self.result = result
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.attempt = try container.decode(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.request_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("request_digest"))
        self.epoch = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("epoch"))
        self.kind = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        self.phase = try container.decode(String.self, forKey: LWCatalogCodingKey("phase"))
        self.stage = try container.decode(String.self, forKey: LWCatalogCodingKey("stage"))
        self.cancel_requested = try container.decode(Bool.self, forKey: LWCatalogCodingKey("cancel_requested"))
        self.progress = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("progress"))
        self.result = try container.decodeIfPresent(LWCatalogJSON.self, forKey: LWCatalogCodingKey("result"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try container.encode(request_digest, forKey: LWCatalogCodingKey("request_digest"))
        try container.encode(epoch, forKey: LWCatalogCodingKey("epoch"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(stage, forKey: LWCatalogCodingKey("stage"))
        try container.encode(cancel_requested, forKey: LWCatalogCodingKey("cancel_requested"))
        try container.encode(progress, forKey: LWCatalogCodingKey("progress"))
        try container.encode(result, forKey: LWCatalogCodingKey("result"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::metadata_write::Options (engines/catalog/src/application/metadata_write.rs:244).
nonisolated struct LWApplicationMetadataWriteOptions: Codable, Sendable {
    var defaults: LWApplicationMetadataWriteWriteLimits
    var input_max: LWCatalogU64
    var packet_max: LWCatalogU64
    var edits_max: LWCatalogU64
    var page_max: UInt16
    var scan_max: LWCatalogU64
    var response_bytes: LWCatalogU64
    var chunk_max: UInt32
    var path_bytes: LWCatalogU64
    var receipt_bytes: LWCatalogU64
    init(defaults: LWApplicationMetadataWriteWriteLimits, input_max: LWCatalogU64, packet_max: LWCatalogU64, edits_max: LWCatalogU64, page_max: UInt16, scan_max: LWCatalogU64, response_bytes: LWCatalogU64, chunk_max: UInt32, path_bytes: LWCatalogU64, receipt_bytes: LWCatalogU64) {
        self.defaults = defaults
        self.input_max = input_max
        self.packet_max = packet_max
        self.edits_max = edits_max
        self.page_max = page_max
        self.scan_max = scan_max
        self.response_bytes = response_bytes
        self.chunk_max = chunk_max
        self.path_bytes = path_bytes
        self.receipt_bytes = receipt_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.defaults = try container.decode(LWApplicationMetadataWriteWriteLimits.self, forKey: LWCatalogCodingKey("defaults"))
        self.input_max = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("input_max"))
        self.packet_max = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("packet_max"))
        self.edits_max = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("edits_max"))
        self.page_max = try container.decode(UInt16.self, forKey: LWCatalogCodingKey("page_max"))
        self.scan_max = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("scan_max"))
        self.response_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("response_bytes"))
        self.chunk_max = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("chunk_max"))
        self.path_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("path_bytes"))
        self.receipt_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("receipt_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(defaults, forKey: LWCatalogCodingKey("defaults"))
        try container.encode(input_max, forKey: LWCatalogCodingKey("input_max"))
        try container.encode(packet_max, forKey: LWCatalogCodingKey("packet_max"))
        try container.encode(edits_max, forKey: LWCatalogCodingKey("edits_max"))
        try container.encode(page_max, forKey: LWCatalogCodingKey("page_max"))
        try container.encode(scan_max, forKey: LWCatalogCodingKey("scan_max"))
        try container.encode(response_bytes, forKey: LWCatalogCodingKey("response_bytes"))
        try container.encode(chunk_max, forKey: LWCatalogCodingKey("chunk_max"))
        try container.encode(path_bytes, forKey: LWCatalogCodingKey("path_bytes"))
        try container.encode(receipt_bytes, forKey: LWCatalogCodingKey("receipt_bytes"))
    }
}

/// application::metadata_write::Page (engines/catalog/src/application/metadata_write.rs:303).
nonisolated struct LWApplicationMetadataWritePage<T: Codable & Sendable>: Codable, Sendable {
    var rows: [T]
    var next: String?
    var scanned: LWCatalogU64
    init(rows: [T], next: String?, scanned: LWCatalogU64) {
        self.rows = rows
        self.next = next
        self.scanned = scanned
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.rows = try container.decode([T].self, forKey: LWCatalogCodingKey("rows"))
        self.next = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("next"))
        self.scanned = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("scanned"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(rows, forKey: LWCatalogCodingKey("rows"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(scanned, forKey: LWCatalogCodingKey("scanned"))
    }
}

/// application::metadata_write::Reference (engines/catalog/src/application/metadata_write.rs:276).
nonisolated struct LWApplicationMetadataWriteReference: Codable, Sendable {
    var token: String
    var bytes: LWCatalogU64
    var blake3: String
    var media_type: String
    init(token: String, bytes: LWCatalogU64, blake3: String, media_type: String) {
        self.token = token
        self.bytes = bytes
        self.blake3 = blake3
        self.media_type = media_type
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.token = try container.decode(String.self, forKey: LWCatalogCodingKey("token"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.media_type = try container.decode(String.self, forKey: LWCatalogCodingKey("media_type"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(token, forKey: LWCatalogCodingKey("token"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(media_type, forKey: LWCatalogCodingKey("media_type"))
    }
}

/// application::metadata_write::Request (engines/catalog/src/application/metadata_write.rs:152).
nonisolated indirect enum LWApplicationMetadataWriteRequest: Codable, Sendable {
    case Options
    case Status(operation: String?)
    case Cancel(operation: String, epoch: LWCatalogU64)
    case Start(attempt: String, action: LWApplicationMetadataWriteAction)
    case InputStatus(token: String, generation: LWCatalogU64)
    case Receipt(attempt: String)
    case Review(token: String, digest: String)
    case ReviewFields(token: String, digest: String, after: String?, limit: UInt16)
    case Chunk(reference: LWApplicationMetadataWriteReference, offset: LWCatalogU64, length: UInt32)
    case Plans(owner: LWCatalogEditsVariantKey?, after: String?, limit: UInt16)
    case Plan(operation: String)
    case RecoveryEntries(token: String, after: String?, limit: UInt16)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "options":
            try container.lwRequireKeys(["command", "args"])
            self = .Options
        case "status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Status(operation: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation")))
        case "cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation", "epoch"])
            self = .Cancel(operation: try payload.decode(String.self, forKey: LWCatalogCodingKey("operation")), epoch: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("epoch")))
        case "start":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["attempt", "action"])
            self = .Start(attempt: try payload.decode(String.self, forKey: LWCatalogCodingKey("attempt")), action: try payload.decode(LWApplicationMetadataWriteAction.self, forKey: LWCatalogCodingKey("action")))
        case "input_status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token", "generation"])
            self = .InputStatus(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), generation: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("generation")))
        case "receipt":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["attempt"])
            self = .Receipt(attempt: try payload.decode(String.self, forKey: LWCatalogCodingKey("attempt")))
        case "review":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token", "digest"])
            self = .Review(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), digest: try payload.decode(String.self, forKey: LWCatalogCodingKey("digest")))
        case "review_fields":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token", "digest", "after", "limit"])
            self = .ReviewFields(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), digest: try payload.decode(String.self, forKey: LWCatalogCodingKey("digest")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "chunk":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["reference", "offset", "length"])
            self = .Chunk(reference: try payload.decode(LWApplicationMetadataWriteReference.self, forKey: LWCatalogCodingKey("reference")), offset: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), length: try payload.decode(UInt32.self, forKey: LWCatalogCodingKey("length")))
        case "plans":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["owner", "after", "limit"])
            self = .Plans(owner: try payload.decodeIfPresent(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("owner")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "plan":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Plan(operation: try payload.decode(String.self, forKey: LWCatalogCodingKey("operation")))
        case "recovery_entries":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["token", "after", "limit"])
            self = .RecoveryEntries(token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), after: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataWriteRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Options:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("options", forKey: LWCatalogCodingKey("command"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .Cancel(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("epoch"))
        case .Start(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("start", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("attempt"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("action"))
        case .InputStatus(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("input_status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("generation"))
        case .Receipt(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("receipt", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("attempt"))
        case .Review(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("review", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("digest"))
        case .ReviewFields(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("review_fields", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("digest"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Chunk(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("chunk", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("reference"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("offset"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("length"))
        case .Plans(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plans", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("owner"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Plan(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .RecoveryEntries(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("recovery_entries", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        }
    }
}

/// application::metadata_write::Response (engines/catalog/src/application/metadata_write.rs:229).
nonisolated indirect enum LWApplicationMetadataWriteResponse: Codable, Sendable {
    case Options(LWApplicationMetadataWriteOptions)
    case Status(LWApplicationMetadataWriteStatus)
    case Admitted(LWApplicationMetadataWriteAdmitted)
    case Input(LWApplicationMetadataWriteInput)
    case Receipt(LWCatalogMetadataWriteReceipt?)
    case Review(LWApplicationMetadataWriteReview)
    case ReviewFields(LWApplicationMetadataWritePage<LWApplicationMetadataWriteReviewField>)
    case Chunk(LWApplicationMetadataWriteBytes)
    case Plans(LWApplicationMetadataWritePage<LWCatalogJSON>)
    case Plan(LWCatalogJSON?)
    case RecoveryEntries(LWApplicationMetadataWritePage<LWCatalogSessionMetadataFilesDiscoveryEntry>)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "options":
            try container.lwRequireKeys(["kind", "value"])
            self = .Options(try container.decode(LWApplicationMetadataWriteOptions.self, forKey: LWCatalogCodingKey("value")))
        case "status":
            try container.lwRequireKeys(["kind", "value"])
            self = .Status(try container.decode(LWApplicationMetadataWriteStatus.self, forKey: LWCatalogCodingKey("value")))
        case "admitted":
            try container.lwRequireKeys(["kind", "value"])
            self = .Admitted(try container.decode(LWApplicationMetadataWriteAdmitted.self, forKey: LWCatalogCodingKey("value")))
        case "input":
            try container.lwRequireKeys(["kind", "value"])
            self = .Input(try container.decode(LWApplicationMetadataWriteInput.self, forKey: LWCatalogCodingKey("value")))
        case "receipt":
            try container.lwRequireKeys(["kind", "value"])
            self = .Receipt(try container.decode(LWCatalogMetadataWriteReceipt?.self, forKey: LWCatalogCodingKey("value")))
        case "review":
            try container.lwRequireKeys(["kind", "value"])
            self = .Review(try container.decode(LWApplicationMetadataWriteReview.self, forKey: LWCatalogCodingKey("value")))
        case "review_fields":
            try container.lwRequireKeys(["kind", "value"])
            self = .ReviewFields(try container.decode(LWApplicationMetadataWritePage<LWApplicationMetadataWriteReviewField>.self, forKey: LWCatalogCodingKey("value")))
        case "chunk":
            try container.lwRequireKeys(["kind", "value"])
            self = .Chunk(try container.decode(LWApplicationMetadataWriteBytes.self, forKey: LWCatalogCodingKey("value")))
        case "plans":
            try container.lwRequireKeys(["kind", "value"])
            self = .Plans(try container.decode(LWApplicationMetadataWritePage<LWCatalogJSON>.self, forKey: LWCatalogCodingKey("value")))
        case "plan":
            try container.lwRequireKeys(["kind", "value"])
            self = .Plan(try container.decode(LWCatalogJSON?.self, forKey: LWCatalogCodingKey("value")))
        case "recovery_entries":
            try container.lwRequireKeys(["kind", "value"])
            self = .RecoveryEntries(try container.decode(LWApplicationMetadataWritePage<LWCatalogSessionMetadataFilesDiscoveryEntry>.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationMetadataWriteResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Options(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("options", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Admitted(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("admitted", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Input(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("input", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Receipt(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("receipt", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Review(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("review", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .ReviewFields(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("review_fields", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Chunk(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("chunk", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Plans(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plans", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Plan(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .RecoveryEntries(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("recovery_entries", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::metadata_write::Review (engines/catalog/src/application/metadata_write.rs:283).
nonisolated struct LWApplicationMetadataWriteReview: Codable, Sendable {
    var token: String
    var digest: String
    var identity: LWApplicationOrganizationImageIdentity
    var base_model: LWCatalogI64?
    var input_blake3: String
    var edits: LWCatalogU64
    var changed_fields: LWCatalogU64
    var packet: LWApplicationMetadataWriteReference
    var issues: String
    init(token: String, digest: String, identity: LWApplicationOrganizationImageIdentity, base_model: LWCatalogI64?, input_blake3: String, edits: LWCatalogU64, changed_fields: LWCatalogU64, packet: LWApplicationMetadataWriteReference, issues: String) {
        self.token = token
        self.digest = digest
        self.identity = identity
        self.base_model = base_model
        self.input_blake3 = input_blake3
        self.edits = edits
        self.changed_fields = changed_fields
        self.packet = packet
        self.issues = issues
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.token = try container.decode(String.self, forKey: LWCatalogCodingKey("token"))
        self.digest = try container.decode(String.self, forKey: LWCatalogCodingKey("digest"))
        self.identity = try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity"))
        self.base_model = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("base_model"))
        self.input_blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("input_blake3"))
        self.edits = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("edits"))
        self.changed_fields = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("changed_fields"))
        self.packet = try container.decode(LWApplicationMetadataWriteReference.self, forKey: LWCatalogCodingKey("packet"))
        self.issues = try container.decode(String.self, forKey: LWCatalogCodingKey("issues"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(token, forKey: LWCatalogCodingKey("token"))
        try container.encode(digest, forKey: LWCatalogCodingKey("digest"))
        try container.encode(identity, forKey: LWCatalogCodingKey("identity"))
        try container.encode(base_model, forKey: LWCatalogCodingKey("base_model"))
        try container.encode(input_blake3, forKey: LWCatalogCodingKey("input_blake3"))
        try container.encode(edits, forKey: LWCatalogCodingKey("edits"))
        try container.encode(changed_fields, forKey: LWCatalogCodingKey("changed_fields"))
        try container.encode(packet, forKey: LWCatalogCodingKey("packet"))
        try container.encode(issues, forKey: LWCatalogCodingKey("issues"))
    }
}

/// application::metadata_write::ReviewField (engines/catalog/src/application/metadata_write.rs:295).
nonisolated struct LWApplicationMetadataWriteReviewField: Codable, Sendable {
    var field: String
    var before: String?
    var after: String?
    var removed: Bool
    var semantic_changed: Bool
    init(field: String, before: String?, after: String?, removed: Bool, semantic_changed: Bool) {
        self.field = field
        self.before = before
        self.after = after
        self.removed = removed
        self.semantic_changed = semantic_changed
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.field = try container.decode(String.self, forKey: LWCatalogCodingKey("field"))
        self.before = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("before"))
        self.after = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("after"))
        self.removed = try container.decode(Bool.self, forKey: LWCatalogCodingKey("removed"))
        self.semantic_changed = try container.decode(Bool.self, forKey: LWCatalogCodingKey("semantic_changed"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(field, forKey: LWCatalogCodingKey("field"))
        try container.encode(before, forKey: LWCatalogCodingKey("before"))
        try container.encode(after, forKey: LWCatalogCodingKey("after"))
        try container.encode(removed, forKey: LWCatalogCodingKey("removed"))
        try container.encode(semantic_changed, forKey: LWCatalogCodingKey("semantic_changed"))
    }
}

/// application::metadata_write::Status (engines/catalog/src/application/metadata_write.rs:332).
nonisolated struct LWApplicationMetadataWriteStatus: Codable, Sendable {
    var catalog: String
    var epoch: LWCatalogU64
    var operation: LWApplicationMetadataWriteOperation?
    var write_hold: Bool
    var closing: Bool
    var input: LWApplicationMetadataWriteInput?
    var review: LWApplicationMetadataWriteReview?
    init(catalog: String, epoch: LWCatalogU64, operation: LWApplicationMetadataWriteOperation?, write_hold: Bool, closing: Bool, input: LWApplicationMetadataWriteInput?, review: LWApplicationMetadataWriteReview?) {
        self.catalog = catalog
        self.epoch = epoch
        self.operation = operation
        self.write_hold = write_hold
        self.closing = closing
        self.input = input
        self.review = review
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.catalog = try container.decode(String.self, forKey: LWCatalogCodingKey("catalog"))
        self.epoch = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("epoch"))
        self.operation = try container.decodeIfPresent(LWApplicationMetadataWriteOperation.self, forKey: LWCatalogCodingKey("operation"))
        self.write_hold = try container.decode(Bool.self, forKey: LWCatalogCodingKey("write_hold"))
        self.closing = try container.decode(Bool.self, forKey: LWCatalogCodingKey("closing"))
        self.input = try container.decodeIfPresent(LWApplicationMetadataWriteInput.self, forKey: LWCatalogCodingKey("input"))
        self.review = try container.decodeIfPresent(LWApplicationMetadataWriteReview.self, forKey: LWCatalogCodingKey("review"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(catalog, forKey: LWCatalogCodingKey("catalog"))
        try container.encode(epoch, forKey: LWCatalogCodingKey("epoch"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(write_hold, forKey: LWCatalogCodingKey("write_hold"))
        try container.encode(closing, forKey: LWCatalogCodingKey("closing"))
        try container.encode(input, forKey: LWCatalogCodingKey("input"))
        try container.encode(review, forKey: LWCatalogCodingKey("review"))
    }
}

/// application::metadata_write::WriteLimits (engines/catalog/src/application/metadata_write.rs:18).
nonisolated struct LWApplicationMetadataWriteWriteLimits: Codable, Sendable {
    var input_bytes: LWCatalogU64
    var existing_file_bytes: LWCatalogU64
    var evidence_bytes: LWCatalogU64
    var evidence_packets: LWCatalogU64
    var alias_directories: LWCatalogU64
    var alias_candidates: LWCatalogU64
    init(input_bytes: LWCatalogU64, existing_file_bytes: LWCatalogU64, evidence_bytes: LWCatalogU64, evidence_packets: LWCatalogU64, alias_directories: LWCatalogU64, alias_candidates: LWCatalogU64) {
        self.input_bytes = input_bytes
        self.existing_file_bytes = existing_file_bytes
        self.evidence_bytes = evidence_bytes
        self.evidence_packets = evidence_packets
        self.alias_directories = alias_directories
        self.alias_candidates = alias_candidates
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["input_bytes", "existing_file_bytes", "evidence_bytes", "evidence_packets", "alias_directories", "alias_candidates"])
        self.input_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("input_bytes"))
        self.existing_file_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("existing_file_bytes"))
        self.evidence_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("evidence_bytes"))
        self.evidence_packets = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("evidence_packets"))
        self.alias_directories = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("alias_directories"))
        self.alias_candidates = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("alias_candidates"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(input_bytes, forKey: LWCatalogCodingKey("input_bytes"))
        try container.encode(existing_file_bytes, forKey: LWCatalogCodingKey("existing_file_bytes"))
        try container.encode(evidence_bytes, forKey: LWCatalogCodingKey("evidence_bytes"))
        try container.encode(evidence_packets, forKey: LWCatalogCodingKey("evidence_packets"))
        try container.encode(alias_directories, forKey: LWCatalogCodingKey("alias_directories"))
        try container.encode(alias_candidates, forKey: LWCatalogCodingKey("alias_candidates"))
    }
}

/// application::organization::KeywordTarget (engines/catalog/src/application/organization.rs:130).
nonisolated struct LWApplicationOrganizationKeywordTarget: Codable, Sendable {
    var kind: LWOrganizationKeywordKind
    var path: [String]
    init(kind: LWOrganizationKeywordKind, path: [String]) {
        self.kind = kind
        self.path = path
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["kind", "path"])
        self.kind = try container.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind"))
        self.path = try container.decode([String].self, forKey: LWCatalogCodingKey("path"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(path, forKey: LWCatalogCodingKey("path"))
    }
}

/// application::organization::BatchItem (engines/catalog/src/application/organization.rs:124).
nonisolated struct LWApplicationOrganizationBatchItem: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var expected_revision: LWCatalogI64
    init(key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64) {
        self.key = key
        self.expected_revision = expected_revision
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["key", "expected_revision"])
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.expected_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(expected_revision, forKey: LWCatalogCodingKey("expected_revision"))
    }
}

/// application::organization::Collection (engines/catalog/src/application/organization.rs:219).
nonisolated struct LWApplicationOrganizationCollection: Codable, Sendable {
    var id: String
    var name: String
    var revision: LWCatalogI64
    var provenance_json: String
    init(id: String, name: String, revision: LWCatalogI64, provenance_json: String) {
        self.id = id
        self.name = name
        self.revision = revision
        self.provenance_json = provenance_json
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.provenance_json = try container.decode(String.self, forKey: LWCatalogCodingKey("provenance_json"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(provenance_json, forKey: LWCatalogCodingKey("provenance_json"))
    }
}

/// application::organization::ImageState (engines/catalog/src/application/organization.rs:146).
nonisolated struct LWApplicationOrganizationImageState: Codable, Sendable {
    var identity: LWApplicationOrganizationImageIdentity
    var rating: String?
    var label: String?
    var flag: LWOrganizationFlag?
    var effective_flag: LWOrganizationFlag
    var keywords: [LWApplicationOrganizationKeywordTarget]
    var member: Bool?
    var position: LWCatalogI64?
    init(identity: LWApplicationOrganizationImageIdentity, rating: String?, label: String?, flag: LWOrganizationFlag?, effective_flag: LWOrganizationFlag, keywords: [LWApplicationOrganizationKeywordTarget], member: Bool?, position: LWCatalogI64?) {
        self.identity = identity
        self.rating = rating
        self.label = label
        self.flag = flag
        self.effective_flag = effective_flag
        self.keywords = keywords
        self.member = member
        self.position = position
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.identity = try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity"))
        self.rating = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("rating"))
        self.label = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("label"))
        self.flag = try container.decodeIfPresent(LWOrganizationFlag.self, forKey: LWCatalogCodingKey("flag"))
        self.effective_flag = try container.decode(LWOrganizationFlag.self, forKey: LWCatalogCodingKey("effective_flag"))
        self.keywords = try container.decode([LWApplicationOrganizationKeywordTarget].self, forKey: LWCatalogCodingKey("keywords"))
        self.member = try container.decodeIfPresent(Bool.self, forKey: LWCatalogCodingKey("member"))
        self.position = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("position"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(identity, forKey: LWCatalogCodingKey("identity"))
        try container.encode(rating, forKey: LWCatalogCodingKey("rating"))
        try container.encode(label, forKey: LWCatalogCodingKey("label"))
        try container.encode(flag, forKey: LWCatalogCodingKey("flag"))
        try container.encode(effective_flag, forKey: LWCatalogCodingKey("effective_flag"))
        try container.encode(keywords, forKey: LWCatalogCodingKey("keywords"))
        try container.encode(member, forKey: LWCatalogCodingKey("member"))
        try container.encode(position, forKey: LWCatalogCodingKey("position"))
    }
}

/// application::organization::ImageIdentity (engines/catalog/src/application/organization.rs:130).
nonisolated struct LWApplicationOrganizationImageIdentity: Codable, Sendable {
    var image_id: String
    var key: LWCatalogEditsVariantKey
    var metadata_revision: LWCatalogI64
    var pixel_generation: LWCatalogI64
    var shared_source_epoch: LWCatalogI64
    var physical_generation: LWCatalogI64
    init(image_id: String, key: LWCatalogEditsVariantKey, metadata_revision: LWCatalogI64, pixel_generation: LWCatalogI64, shared_source_epoch: LWCatalogI64, physical_generation: LWCatalogI64) {
        self.image_id = image_id
        self.key = key
        self.metadata_revision = metadata_revision
        self.pixel_generation = pixel_generation
        self.shared_source_epoch = shared_source_epoch
        self.physical_generation = physical_generation
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["image_id", "key", "metadata_revision", "pixel_generation", "shared_source_epoch", "physical_generation"])
        self.image_id = try container.decode(String.self, forKey: LWCatalogCodingKey("image_id"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.metadata_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("metadata_revision"))
        self.pixel_generation = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("pixel_generation"))
        self.shared_source_epoch = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("shared_source_epoch"))
        self.physical_generation = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("physical_generation"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(image_id, forKey: LWCatalogCodingKey("image_id"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(metadata_revision, forKey: LWCatalogCodingKey("metadata_revision"))
        try container.encode(pixel_generation, forKey: LWCatalogCodingKey("pixel_generation"))
        try container.encode(shared_source_epoch, forKey: LWCatalogCodingKey("shared_source_epoch"))
        try container.encode(physical_generation, forKey: LWCatalogCodingKey("physical_generation"))
    }
}

/// application::organization::Job (engines/catalog/src/application/organization.rs:243).
nonisolated struct LWApplicationOrganizationJob: Codable, Sendable {
    var id: String
    var operation: LWOrganizationOperation
    var state: String
    var pending: LWCatalogI64
    var applied: LWCatalogI64
    var failed: LWCatalogI64
    var skipped: LWCatalogI64
    init(id: String, operation: LWOrganizationOperation, state: String, pending: LWCatalogI64, applied: LWCatalogI64, failed: LWCatalogI64, skipped: LWCatalogI64) {
        self.id = id
        self.operation = operation
        self.state = state
        self.pending = pending
        self.applied = applied
        self.failed = failed
        self.skipped = skipped
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.operation = try container.decode(LWOrganizationOperation.self, forKey: LWCatalogCodingKey("operation"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.pending = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("pending"))
        self.applied = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("applied"))
        self.failed = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("failed"))
        self.skipped = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("skipped"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(pending, forKey: LWCatalogCodingKey("pending"))
        try container.encode(applied, forKey: LWCatalogCodingKey("applied"))
        try container.encode(failed, forKey: LWCatalogCodingKey("failed"))
        try container.encode(skipped, forKey: LWCatalogCodingKey("skipped"))
    }
}

/// application::organization::JobItem (engines/catalog/src/application/organization.rs:266).
nonisolated struct LWApplicationOrganizationJobItem: Codable, Sendable {
    var sequence: LWCatalogI64
    var key: LWCatalogEditsVariantKey
    var image_id: String
    var expected_revision: LWCatalogI64
    var status: String
    var error: String?
    var result_revision: LWCatalogI64?
    init(sequence: LWCatalogI64, key: LWCatalogEditsVariantKey, image_id: String, expected_revision: LWCatalogI64, status: String, error: String?, result_revision: LWCatalogI64?) {
        self.sequence = sequence
        self.key = key
        self.image_id = image_id
        self.expected_revision = expected_revision
        self.status = status
        self.error = error
        self.result_revision = result_revision
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.image_id = try container.decode(String.self, forKey: LWCatalogCodingKey("image_id"))
        self.expected_revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision"))
        self.status = try container.decode(String.self, forKey: LWCatalogCodingKey("status"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
        self.result_revision = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("result_revision"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(image_id, forKey: LWCatalogCodingKey("image_id"))
        try container.encode(expected_revision, forKey: LWCatalogCodingKey("expected_revision"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
        try container.encode(result_revision, forKey: LWCatalogCodingKey("result_revision"))
    }
}

/// application::organization::Keyword (engines/catalog/src/application/organization.rs:211).
nonisolated struct LWApplicationOrganizationKeyword: Codable, Sendable {
    var id: LWCatalogI64
    var kind: LWOrganizationKeywordKind
    var parent: LWCatalogI64?
    var name: String
    var path: [String]
    init(id: LWCatalogI64, kind: LWOrganizationKeywordKind, parent: LWCatalogI64?, name: String, path: [String]) {
        self.id = id
        self.kind = kind
        self.parent = parent
        self.name = name
        self.path = path
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id"))
        self.kind = try container.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind"))
        self.parent = try container.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("parent"))
        self.name = try container.decode(String.self, forKey: LWCatalogCodingKey("name"))
        self.path = try container.decode([String].self, forKey: LWCatalogCodingKey("path"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(parent, forKey: LWCatalogCodingKey("parent"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(path, forKey: LWCatalogCodingKey("path"))
    }
}

/// application::organization::Member (engines/catalog/src/application/organization.rs:237).
nonisolated struct LWApplicationOrganizationMember: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var cursor: LWApplicationOrganizationMemberCursor
    var provenance_json: String
    init(key: LWCatalogEditsVariantKey, cursor: LWApplicationOrganizationMemberCursor, provenance_json: String) {
        self.key = key
        self.cursor = cursor
        self.provenance_json = provenance_json
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.cursor = try container.decode(LWApplicationOrganizationMemberCursor.self, forKey: LWCatalogCodingKey("cursor"))
        self.provenance_json = try container.decode(String.self, forKey: LWCatalogCodingKey("provenance_json"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(cursor, forKey: LWCatalogCodingKey("cursor"))
        try container.encode(provenance_json, forKey: LWCatalogCodingKey("provenance_json"))
    }
}

/// application::organization::MemberCursor (engines/catalog/src/application/organization.rs:164).
nonisolated struct LWApplicationOrganizationMemberCursor: Codable, Sendable {
    var position: LWCatalogI64
    var sequence: LWCatalogI64
    init(position: LWCatalogI64, sequence: LWCatalogI64) {
        self.position = position
        self.sequence = sequence
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["position", "sequence"])
        self.position = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("position"))
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(position, forKey: LWCatalogCodingKey("position"))
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
    }
}

/// application::organization::MembershipCursor (engines/catalog/src/application/organization.rs:170).
nonisolated struct LWApplicationOrganizationMembershipCursor: Codable, Sendable {
    var collection: String
    var revision: LWCatalogI64
    var ordered: Bool
    var position: LWCatalogI64
    var sequence: LWCatalogI64
    init(collection: String, revision: LWCatalogI64, ordered: Bool, position: LWCatalogI64, sequence: LWCatalogI64) {
        self.collection = collection
        self.revision = revision
        self.ordered = ordered
        self.position = position
        self.sequence = sequence
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["collection", "revision", "ordered", "position", "sequence"])
        self.collection = try container.decode(String.self, forKey: LWCatalogCodingKey("collection"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.ordered = try container.decode(Bool.self, forKey: LWCatalogCodingKey("ordered"))
        self.position = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("position"))
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(collection, forKey: LWCatalogCodingKey("collection"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(ordered, forKey: LWCatalogCodingKey("ordered"))
        try container.encode(position, forKey: LWCatalogCodingKey("position"))
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
    }
}

/// application::organization::MembershipPage (engines/catalog/src/application/organization.rs:200).
nonisolated struct LWApplicationOrganizationMembershipPage: Codable, Sendable {
    var rows: [LWApplicationOrganizationMember]
    var next: LWApplicationOrganizationMembershipCursor?
    var scanned: LWCatalogU64
    init(rows: [LWApplicationOrganizationMember], next: LWApplicationOrganizationMembershipCursor?, scanned: LWCatalogU64) {
        self.rows = rows
        self.next = next
        self.scanned = scanned
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.rows = try container.decode([LWApplicationOrganizationMember].self, forKey: LWCatalogCodingKey("rows"))
        self.next = try container.decodeIfPresent(LWApplicationOrganizationMembershipCursor.self, forKey: LWCatalogCodingKey("next"))
        self.scanned = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("scanned"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(rows, forKey: LWCatalogCodingKey("rows"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(scanned, forKey: LWCatalogCodingKey("scanned"))
    }
}

/// application::organization::Page (engines/catalog/src/application/organization.rs:206).
nonisolated struct LWApplicationOrganizationPage<T: Codable & Sendable, C: Codable & Sendable>: Codable, Sendable {
    var rows: [T]
    var next: C?
    init(rows: [T], next: C?) {
        self.rows = rows
        self.next = next
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.rows = try container.decode([T].self, forKey: LWCatalogCodingKey("rows"))
        self.next = try container.decodeIfPresent(C.self, forKey: LWCatalogCodingKey("next"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(rows, forKey: LWCatalogCodingKey("rows"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
    }
}

/// application::organization::Placement (engines/catalog/src/application/organization.rs:226).
nonisolated struct LWApplicationOrganizationPlacement: Codable, Sendable {
    var collection: String
    var parent: String?
    var position: LWCatalogI64
    init(collection: String, parent: String?, position: LWCatalogI64) {
        self.collection = collection
        self.parent = parent
        self.position = position
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.collection = try container.decode(String.self, forKey: LWCatalogCodingKey("collection"))
        self.parent = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("parent"))
        self.position = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("position"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(collection, forKey: LWCatalogCodingKey("collection"))
        try container.encode(parent, forKey: LWCatalogCodingKey("parent"))
        try container.encode(position, forKey: LWCatalogCodingKey("position"))
    }
}

/// application::organization::Request (engines/catalog/src/application/organization.rs:19).
nonisolated indirect enum LWApplicationOrganizationRequest: Codable, Sendable {
    case Keywords(kind: LWOrganizationKeywordKind, parent: LWCatalogI64?, after: LWCatalogI64, limit: UInt16)
    case CreateKeyword(kind: LWOrganizationKeywordKind, path: [String])
    case DeleteKeyword(id: LWCatalogI64)
    case FindKeyword(kind: LWOrganizationKeywordKind, path: [String])
    case Synonyms(keyword: LWCatalogI64, after: String, limit: UInt16)
    case AddSynonym(keyword: LWCatalogI64, synonym: String)
    case RemoveSynonym(keyword: LWCatalogI64, synonym: String)
    case Collections(after: String, limit: UInt16)
    case Collection(id: String)
    case CreateCollection(name: String)
    case RenameCollection(id: String, expected_revision: LWCatalogI64, name: String)
    case DeleteCollection(id: String, expected_revision: LWCatalogI64)
    case Placement(collection: String)
    case PlaceCollection(collection: String, expected_revision: LWCatalogI64, parent: String?, position: LWCatalogI64)
    case Members(collection: String, after: LWApplicationOrganizationMembershipCursor?, limit: UInt16)
    case Identity(key: LWCatalogEditsVariantKey)
    case SetMember(identity: LWApplicationOrganizationImageIdentity, collection: String, position: LWCatalogI64)
    case States(keys: [LWCatalogEditsVariantKey], keywords: [LWApplicationOrganizationKeywordTarget], collection: String?)
    case Apply(key: LWCatalogEditsVariantKey, expected_revision: LWCatalogI64, operation: LWOrganizationOperation)
    case Begin(operation: LWOrganizationOperation)
    case Append(job: String, items: [LWApplicationOrganizationBatchItem])
    case Seal(job: String)
    case Step(job: String)
    case Run(job: String, limit: UInt16)
    case Cancel(job: String)
    case Job(job: String)
    case Jobs(after: String, limit: UInt16)
    case Items(job: String, after: LWCatalogI64, limit: UInt16)
    case Review(job: String, key: LWCatalogEditsVariantKey, new_revision: LWCatalogI64?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "keywords":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["kind", "parent", "after", "limit"])
            self = .Keywords(kind: try payload.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind")), parent: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("parent")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "create_keyword":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["kind", "path"])
            self = .CreateKeyword(kind: try payload.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind")), path: try payload.decode([String].self, forKey: LWCatalogCodingKey("path")))
        case "delete_keyword":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["id"])
            self = .DeleteKeyword(id: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id")))
        case "find_keyword":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["kind", "path"])
            self = .FindKeyword(kind: try payload.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind")), path: try payload.decode([String].self, forKey: LWCatalogCodingKey("path")))
        case "synonyms":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["keyword", "after", "limit"])
            self = .Synonyms(keyword: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("keyword")), after: try payload.decode(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "add_synonym":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["keyword", "synonym"])
            self = .AddSynonym(keyword: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("keyword")), synonym: try payload.decode(String.self, forKey: LWCatalogCodingKey("synonym")))
        case "remove_synonym":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["keyword", "synonym"])
            self = .RemoveSynonym(keyword: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("keyword")), synonym: try payload.decode(String.self, forKey: LWCatalogCodingKey("synonym")))
        case "collections":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["after", "limit"])
            self = .Collections(after: try payload.decode(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "collection":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["id"])
            self = .Collection(id: try payload.decode(String.self, forKey: LWCatalogCodingKey("id")))
        case "create_collection":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["name"])
            self = .CreateCollection(name: try payload.decode(String.self, forKey: LWCatalogCodingKey("name")))
        case "rename_collection":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["id", "expected_revision", "name"])
            self = .RenameCollection(id: try payload.decode(String.self, forKey: LWCatalogCodingKey("id")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), name: try payload.decode(String.self, forKey: LWCatalogCodingKey("name")))
        case "delete_collection":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["id", "expected_revision"])
            self = .DeleteCollection(id: try payload.decode(String.self, forKey: LWCatalogCodingKey("id")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")))
        case "placement":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["collection"])
            self = .Placement(collection: try payload.decode(String.self, forKey: LWCatalogCodingKey("collection")))
        case "place_collection":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["collection", "expected_revision", "parent", "position"])
            self = .PlaceCollection(collection: try payload.decode(String.self, forKey: LWCatalogCodingKey("collection")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), parent: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("parent")), position: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("position")))
        case "members":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["collection", "after", "limit"])
            self = .Members(collection: try payload.decode(String.self, forKey: LWCatalogCodingKey("collection")), after: try payload.decodeIfPresent(LWApplicationOrganizationMembershipCursor.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "identity":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key"])
            self = .Identity(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")))
        case "set_member":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["identity", "collection", "position"])
            self = .SetMember(identity: try payload.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("identity")), collection: try payload.decode(String.self, forKey: LWCatalogCodingKey("collection")), position: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("position")))
        case "states":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["keys", "keywords", "collection"])
            self = .States(keys: try payload.decode([LWCatalogEditsVariantKey].self, forKey: LWCatalogCodingKey("keys")), keywords: try payload.decode([LWApplicationOrganizationKeywordTarget].self, forKey: LWCatalogCodingKey("keywords")), collection: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("collection")))
        case "apply":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key", "expected_revision", "operation"])
            self = .Apply(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), expected_revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("expected_revision")), operation: try payload.decode(LWOrganizationOperation.self, forKey: LWCatalogCodingKey("operation")))
        case "begin":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Begin(operation: try payload.decode(LWOrganizationOperation.self, forKey: LWCatalogCodingKey("operation")))
        case "append":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "items"])
            self = .Append(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), items: try payload.decode([LWApplicationOrganizationBatchItem].self, forKey: LWCatalogCodingKey("items")))
        case "seal":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Seal(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "step":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Step(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "run":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "limit"])
            self = .Run(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Cancel(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "job":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job"])
            self = .Job(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")))
        case "jobs":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["after", "limit"])
            self = .Jobs(after: try payload.decode(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "items":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "after", "limit"])
            self = .Items(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("limit")))
        case "review":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["job", "key", "new_revision"])
            self = .Review(job: try payload.decode(String.self, forKey: LWCatalogCodingKey("job")), key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")), new_revision: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("new_revision")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationOrganizationRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Keywords(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("keywords", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("kind"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("parent"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .CreateKeyword(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("create_keyword", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("kind"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("path"))
        case .DeleteKeyword(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("delete_keyword", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("id"))
        case .FindKeyword(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("find_keyword", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("kind"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("path"))
        case .Synonyms(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("synonyms", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("keyword"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .AddSynonym(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("add_synonym", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("keyword"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("synonym"))
        case .RemoveSynonym(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("remove_synonym", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("keyword"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("synonym"))
        case .Collections(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("collections", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limit"))
        case .Collection(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("collection", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("id"))
        case .CreateCollection(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("create_collection", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("name"))
        case .RenameCollection(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("rename_collection", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("id"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("name"))
        case .DeleteCollection(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("delete_collection", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("id"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_revision"))
        case .Placement(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("placement", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("collection"))
        case .PlaceCollection(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("place_collection", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("collection"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("parent"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("position"))
        case .Members(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("members", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("collection"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Identity(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("identity", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
        case .SetMember(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("set_member", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("identity"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("collection"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("position"))
        case .States(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("states", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("keys"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("keywords"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("collection"))
        case .Apply(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("apply", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("expected_revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("operation"))
        case .Begin(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .Append(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("append", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("items"))
        case .Seal(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("seal", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Step(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("step", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Run(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("run", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limit"))
        case .Cancel(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
        case .Jobs(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jobs", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limit"))
        case .Items(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Review(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("review", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("job"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("key"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("new_revision"))
        }
    }
}

/// application::organization::Response (engines/catalog/src/application/organization.rs:277).
nonisolated indirect enum LWApplicationOrganizationResponse: Codable, Sendable {
    case Keywords(LWApplicationOrganizationPage<LWApplicationOrganizationKeyword, LWCatalogI64>)
    case KeywordCreated(id: LWCatalogI64)
    case Keyword(LWApplicationOrganizationKeyword?)
    case Synonyms(LWApplicationOrganizationPage<LWApplicationOrganizationSynonym, String>)
    case Collections(LWApplicationOrganizationPage<LWApplicationOrganizationCollection, String>)
    case Collection(LWApplicationOrganizationCollection?)
    case CollectionCreated(id: String)
    case Placement(LWApplicationOrganizationPlacement)
    case Members(LWApplicationOrganizationMembershipPage)
    case Identity(LWApplicationOrganizationImageIdentity)
    case States([LWApplicationOrganizationImageState])
    case Changed(revision: LWCatalogI64)
    case Acknowledged
    case Job(LWApplicationOrganizationJob)
    case Jobs(LWApplicationOrganizationPage<LWApplicationOrganizationJob, String>)
    case Items(LWApplicationOrganizationPage<LWApplicationOrganizationJobItem, LWCatalogI64>)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "keywords":
            self = .Keywords(try container.decode(LWApplicationOrganizationPage<LWApplicationOrganizationKeyword, LWCatalogI64>.self, forKey: LWCatalogCodingKey("value")))
        case "keyword_created":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .KeywordCreated(id: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("id")))
        case "keyword":
            self = .Keyword(try container.decodeIfPresent(LWApplicationOrganizationKeyword.self, forKey: LWCatalogCodingKey("value")))
        case "synonyms":
            self = .Synonyms(try container.decode(LWApplicationOrganizationPage<LWApplicationOrganizationSynonym, String>.self, forKey: LWCatalogCodingKey("value")))
        case "collections":
            self = .Collections(try container.decode(LWApplicationOrganizationPage<LWApplicationOrganizationCollection, String>.self, forKey: LWCatalogCodingKey("value")))
        case "collection":
            self = .Collection(try container.decode(LWApplicationOrganizationCollection?.self, forKey: LWCatalogCodingKey("value")))
        case "collection_created":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .CollectionCreated(id: try payload.decode(String.self, forKey: LWCatalogCodingKey("id")))
        case "placement":
            self = .Placement(try container.decode(LWApplicationOrganizationPlacement.self, forKey: LWCatalogCodingKey("value")))
        case "members":
            self = .Members(try container.decode(LWApplicationOrganizationMembershipPage.self, forKey: LWCatalogCodingKey("value")))
        case "identity":
            self = .Identity(try container.decode(LWApplicationOrganizationImageIdentity.self, forKey: LWCatalogCodingKey("value")))
        case "states":
            self = .States(try container.decode([LWApplicationOrganizationImageState].self, forKey: LWCatalogCodingKey("value")))
        case "changed":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Changed(revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")))
        case "acknowledged":
            self = .Acknowledged
        case "job":
            self = .Job(try container.decode(LWApplicationOrganizationJob.self, forKey: LWCatalogCodingKey("value")))
        case "jobs":
            self = .Jobs(try container.decode(LWApplicationOrganizationPage<LWApplicationOrganizationJob, String>.self, forKey: LWCatalogCodingKey("value")))
        case "items":
            self = .Items(try container.decode(LWApplicationOrganizationPage<LWApplicationOrganizationJobItem, LWCatalogI64>.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationOrganizationResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Keywords(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("keywords", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .KeywordCreated(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("keyword_created", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("id"))
        case .Keyword(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("keyword", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Synonyms(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("synonyms", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Collections(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("collections", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Collection(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("collection", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .CollectionCreated(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("collection_created", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("id"))
        case .Placement(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("placement", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Members(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("members", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Identity(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("identity", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .States(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("states", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Changed(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("changed", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("revision"))
        case .Acknowledged:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("acknowledged", forKey: LWCatalogCodingKey("kind"))
        case .Job(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("job", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Jobs(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jobs", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Items(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::organization::Synonym (engines/catalog/src/application/organization.rs:232).
nonisolated struct LWApplicationOrganizationSynonym: Codable, Sendable {
    var synonym: String
    var provenance_json: String
    init(synonym: String, provenance_json: String) {
        self.synonym = synonym
        self.provenance_json = provenance_json
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.synonym = try container.decode(String.self, forKey: LWCatalogCodingKey("synonym"))
        self.provenance_json = try container.decode(String.self, forKey: LWCatalogCodingKey("provenance_json"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(synonym, forKey: LWCatalogCodingKey("synonym"))
        try container.encode(provenance_json, forKey: LWCatalogCodingKey("provenance_json"))
    }
}

/// application::preview_settings::OriginalRoots (engines/catalog/src/application/preview_settings.rs:72).
nonisolated struct LWApplicationPreviewSettingsOriginalRoots: Codable, Sendable {
    var state: String
    var roots: [LWCatalogNativePath]
    var review: String?
    var checked_directories: LWCatalogU64
    var uncovered: LWCatalogNativePath?
    var message: String?
    init(state: String, roots: [LWCatalogNativePath], review: String?, checked_directories: LWCatalogU64, uncovered: LWCatalogNativePath?, message: String?) {
        self.state = state
        self.roots = roots
        self.review = review
        self.checked_directories = checked_directories
        self.uncovered = uncovered
        self.message = message
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.roots = try container.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("roots"))
        self.review = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("review"))
        self.checked_directories = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("checked_directories"))
        self.uncovered = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("uncovered"))
        self.message = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("message"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(roots, forKey: LWCatalogCodingKey("roots"))
        try container.encode(review, forKey: LWCatalogCodingKey("review"))
        try container.encode(checked_directories, forKey: LWCatalogCodingKey("checked_directories"))
        try container.encode(uncovered, forKey: LWCatalogCodingKey("uncovered"))
        try container.encode(message, forKey: LWCatalogCodingKey("message"))
    }
}

/// application::preview_settings::Relocation (engines/catalog/src/application/preview_settings.rs:61).
nonisolated struct LWApplicationPreviewSettingsRelocation: Codable, Sendable {
    var source: LWCatalogNativePath
    var destination: LWCatalogNativePath
    var phase: String
    var objects: LWCatalogU64?
    var bytes: LWCatalogU64?
    var total_objects: LWCatalogU64?
    var total_bytes: LWCatalogU64?
    init(source: LWCatalogNativePath, destination: LWCatalogNativePath, phase: String, objects: LWCatalogU64?, bytes: LWCatalogU64?, total_objects: LWCatalogU64?, total_bytes: LWCatalogU64?) {
        self.source = source
        self.destination = destination
        self.phase = phase
        self.objects = objects
        self.bytes = bytes
        self.total_objects = total_objects
        self.total_bytes = total_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.source = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("source"))
        self.destination = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
        self.phase = try container.decode(String.self, forKey: LWCatalogCodingKey("phase"))
        self.objects = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("objects"))
        self.bytes = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.total_objects = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_objects"))
        self.total_bytes = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(objects, forKey: LWCatalogCodingKey("objects"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(total_objects, forKey: LWCatalogCodingKey("total_objects"))
        try container.encode(total_bytes, forKey: LWCatalogCodingKey("total_bytes"))
    }
}

/// application::preview_settings::Request (engines/catalog/src/application/preview_settings.rs:25).
nonisolated indirect enum LWApplicationPreviewSettingsRequest: Codable, Sendable {
    case Status
    case SetBudgets(thumbnail_bytes: LWCatalogU64, large_bytes: LWCatalogU64)
    case BeginOriginalRootReview(roots: [LWCatalogNativePath])
    case StepOriginalRootReview(review: String, directories: UInt16)
    case BeginRelocation(tier: LWPreviewStoreTier, destination: LWCatalogNativePath)
    case StepRelocation(tier: LWPreviewStoreTier, objects: UInt16, bytes: LWCatalogU64)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "status":
            try container.lwRequireKeys(["command", "args"])
            self = .Status
        case "set_budgets":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["thumbnail_bytes", "large_bytes"])
            self = .SetBudgets(thumbnail_bytes: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("thumbnail_bytes")), large_bytes: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("large_bytes")))
        case "begin_original_root_review":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["roots"])
            self = .BeginOriginalRootReview(roots: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("roots")))
        case "step_original_root_review":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["review", "directories"])
            self = .StepOriginalRootReview(review: try payload.decode(String.self, forKey: LWCatalogCodingKey("review")), directories: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("directories")))
        case "begin_relocation":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["tier", "destination"])
            self = .BeginRelocation(tier: try payload.decode(LWPreviewStoreTier.self, forKey: LWCatalogCodingKey("tier")), destination: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination")))
        case "step_relocation":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["tier", "objects", "bytes"])
            self = .StepRelocation(tier: try payload.decode(LWPreviewStoreTier.self, forKey: LWCatalogCodingKey("tier")), objects: try payload.decode(UInt16.self, forKey: LWCatalogCodingKey("objects")), bytes: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationPreviewSettingsRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Status:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("command"))
        case .SetBudgets(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("set_budgets", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("thumbnail_bytes"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("large_bytes"))
        case .BeginOriginalRootReview(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin_original_root_review", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("roots"))
        case .StepOriginalRootReview(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("step_original_root_review", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("review"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("directories"))
        case .BeginRelocation(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin_relocation", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("tier"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destination"))
        case .StepRelocation(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("step_relocation", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("tier"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("objects"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("bytes"))
        }
    }
}

/// application::preview_settings::Status (engines/catalog/src/application/preview_settings.rs:50).
nonisolated struct LWApplicationPreviewSettingsStatus: Codable, Sendable {
    var thumbnail_root: LWCatalogNativePath
    var large_root: LWCatalogNativePath
    var thumbnail_bytes: LWCatalogU64
    var large_bytes: LWCatalogU64
    var previews_drained: Bool
    var relocation_pending: Bool
    var relocation_tier: LWPreviewStoreTier?
    var relocation: LWApplicationPreviewSettingsRelocation?
    var original_roots: LWApplicationPreviewSettingsOriginalRoots
    init(thumbnail_root: LWCatalogNativePath, large_root: LWCatalogNativePath, thumbnail_bytes: LWCatalogU64, large_bytes: LWCatalogU64, previews_drained: Bool, relocation_pending: Bool, relocation_tier: LWPreviewStoreTier?, relocation: LWApplicationPreviewSettingsRelocation?, original_roots: LWApplicationPreviewSettingsOriginalRoots) {
        self.thumbnail_root = thumbnail_root
        self.large_root = large_root
        self.thumbnail_bytes = thumbnail_bytes
        self.large_bytes = large_bytes
        self.previews_drained = previews_drained
        self.relocation_pending = relocation_pending
        self.relocation_tier = relocation_tier
        self.relocation = relocation
        self.original_roots = original_roots
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.thumbnail_root = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("thumbnail_root"))
        self.large_root = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("large_root"))
        self.thumbnail_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("thumbnail_bytes"))
        self.large_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("large_bytes"))
        self.previews_drained = try container.decode(Bool.self, forKey: LWCatalogCodingKey("previews_drained"))
        self.relocation_pending = try container.decode(Bool.self, forKey: LWCatalogCodingKey("relocation_pending"))
        self.relocation_tier = try container.decodeIfPresent(LWPreviewStoreTier.self, forKey: LWCatalogCodingKey("relocation_tier"))
        self.relocation = try container.decodeIfPresent(LWApplicationPreviewSettingsRelocation.self, forKey: LWCatalogCodingKey("relocation"))
        self.original_roots = try container.decode(LWApplicationPreviewSettingsOriginalRoots.self, forKey: LWCatalogCodingKey("original_roots"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(thumbnail_root, forKey: LWCatalogCodingKey("thumbnail_root"))
        try container.encode(large_root, forKey: LWCatalogCodingKey("large_root"))
        try container.encode(thumbnail_bytes, forKey: LWCatalogCodingKey("thumbnail_bytes"))
        try container.encode(large_bytes, forKey: LWCatalogCodingKey("large_bytes"))
        try container.encode(previews_drained, forKey: LWCatalogCodingKey("previews_drained"))
        try container.encode(relocation_pending, forKey: LWCatalogCodingKey("relocation_pending"))
        try container.encode(relocation_tier, forKey: LWCatalogCodingKey("relocation_tier"))
        try container.encode(relocation, forKey: LWCatalogCodingKey("relocation"))
        try container.encode(original_roots, forKey: LWCatalogCodingKey("original_roots"))
    }
}

/// application::relink::Action (engines/catalog/src/application/relink.rs:317).
nonisolated enum LWApplicationRelinkAction: String, Codable, Sendable {
    case Prepare = "prepare"
    case Confirm = "confirm"
    case Revise = "revise"
    case Apply = "apply"
    case Undo = "undo"
    case Mounts = "mounts"
    case Original = "original"
}

/// application::relink::Item (engines/catalog/src/application/relink.rs:239).
nonisolated struct LWApplicationRelinkItem: Codable, Sendable {
    var sequence: LWCatalogI64
    var asset_id: String
    var status: String
    var detail: String
    var identity_basis: String
    var original: LWCatalogStoragePathReference
    var candidates: [LWCatalogStorageCandidate]
    var destination: LWCatalogNativePath?
    init(sequence: LWCatalogI64, asset_id: String, status: String, detail: String, identity_basis: String, original: LWCatalogStoragePathReference, candidates: [LWCatalogStorageCandidate], destination: LWCatalogNativePath?) {
        self.sequence = sequence
        self.asset_id = asset_id
        self.status = status
        self.detail = detail
        self.identity_basis = identity_basis
        self.original = original
        self.candidates = candidates
        self.destination = destination
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.sequence = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence"))
        self.asset_id = try container.decode(String.self, forKey: LWCatalogCodingKey("asset_id"))
        self.status = try container.decode(String.self, forKey: LWCatalogCodingKey("status"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
        self.identity_basis = try container.decode(String.self, forKey: LWCatalogCodingKey("identity_basis"))
        self.original = try container.decode(LWCatalogStoragePathReference.self, forKey: LWCatalogCodingKey("original"))
        self.candidates = try container.decode([LWCatalogStorageCandidate].self, forKey: LWCatalogCodingKey("candidates"))
        self.destination = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(sequence, forKey: LWCatalogCodingKey("sequence"))
        try container.encode(asset_id, forKey: LWCatalogCodingKey("asset_id"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
        try container.encode(identity_basis, forKey: LWCatalogCodingKey("identity_basis"))
        try container.encode(original, forKey: LWCatalogCodingKey("original"))
        try container.encode(candidates, forKey: LWCatalogCodingKey("candidates"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
    }
}

/// application::relink::Mount (engines/catalog/src/application/relink.rs:285).
nonisolated struct LWApplicationRelinkMount: Codable, Sendable {
    var token: String
    var path: LWCatalogNativePath
    var filesystem: String
    var identity_available: Bool
    init(token: String, path: LWCatalogNativePath, filesystem: String, identity_available: Bool) {
        self.token = token
        self.path = path
        self.filesystem = filesystem
        self.identity_available = identity_available
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.token = try container.decode(String.self, forKey: LWCatalogCodingKey("token"))
        self.path = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path"))
        self.filesystem = try container.decode(String.self, forKey: LWCatalogCodingKey("filesystem"))
        self.identity_available = try container.decode(Bool.self, forKey: LWCatalogCodingKey("identity_available"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(token, forKey: LWCatalogCodingKey("token"))
        try container.encode(path, forKey: LWCatalogCodingKey("path"))
        try container.encode(filesystem, forKey: LWCatalogCodingKey("filesystem"))
        try container.encode(identity_available, forKey: LWCatalogCodingKey("identity_available"))
    }
}

/// application::relink::Mounts (engines/catalog/src/application/relink.rs:292).
nonisolated struct LWApplicationRelinkMounts: Codable, Sendable {
    var rows: [LWApplicationRelinkMount]
    var complete: Bool
    var issues: [LWStorageVolumeVolumeIssue]
    init(rows: [LWApplicationRelinkMount], complete: Bool, issues: [LWStorageVolumeVolumeIssue]) {
        self.rows = rows
        self.complete = complete
        self.issues = issues
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.rows = try container.decode([LWApplicationRelinkMount].self, forKey: LWCatalogCodingKey("rows"))
        self.complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("complete"))
        self.issues = try container.decode([LWStorageVolumeVolumeIssue].self, forKey: LWCatalogCodingKey("issues"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(rows, forKey: LWCatalogCodingKey("rows"))
        try container.encode(complete, forKey: LWCatalogCodingKey("complete"))
        try container.encode(issues, forKey: LWCatalogCodingKey("issues"))
    }
}

/// application::relink::Operation (engines/catalog/src/application/relink.rs:334).
nonisolated struct LWApplicationRelinkOperation: Codable, Sendable {
    var id: String
    var action: LWApplicationRelinkAction
    var phase: LWApplicationRelinkPhase
    var plan: LWApplicationRelinkPlan?
    var progress: LWCatalogI64
    var boundary: String?
    var write_hold: Bool
    var result: LWApplicationRelinkOutcome?
    var error: String?
    init(id: String, action: LWApplicationRelinkAction, phase: LWApplicationRelinkPhase, plan: LWApplicationRelinkPlan?, progress: LWCatalogI64, boundary: String?, write_hold: Bool, result: LWApplicationRelinkOutcome?, error: String?) {
        self.id = id
        self.action = action
        self.phase = phase
        self.plan = plan
        self.progress = progress
        self.boundary = boundary
        self.write_hold = write_hold
        self.result = result
        self.error = error
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.action = try container.decode(LWApplicationRelinkAction.self, forKey: LWCatalogCodingKey("action"))
        self.phase = try container.decode(LWApplicationRelinkPhase.self, forKey: LWCatalogCodingKey("phase"))
        self.plan = try container.decodeIfPresent(LWApplicationRelinkPlan.self, forKey: LWCatalogCodingKey("plan"))
        self.progress = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("progress"))
        self.boundary = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("boundary"))
        self.write_hold = try container.decode(Bool.self, forKey: LWCatalogCodingKey("write_hold"))
        self.result = try container.decodeIfPresent(LWApplicationRelinkOutcome.self, forKey: LWCatalogCodingKey("result"))
        self.error = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("error"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(action, forKey: LWCatalogCodingKey("action"))
        try container.encode(phase, forKey: LWCatalogCodingKey("phase"))
        try container.encode(plan, forKey: LWCatalogCodingKey("plan"))
        try container.encode(progress, forKey: LWCatalogCodingKey("progress"))
        try container.encode(boundary, forKey: LWCatalogCodingKey("boundary"))
        try container.encode(write_hold, forKey: LWCatalogCodingKey("write_hold"))
        try container.encode(result, forKey: LWCatalogCodingKey("result"))
        try container.encode(error, forKey: LWCatalogCodingKey("error"))
    }
}

/// application::relink::Original (engines/catalog/src/application/relink.rs:298).
nonisolated struct LWApplicationRelinkOriginal: Codable, Sendable {
    var key: LWCatalogEditsVariantKey
    var status: LWCatalogStorageStorageStatus
    init(key: LWCatalogEditsVariantKey, status: LWCatalogStorageStorageStatus) {
        self.key = key
        self.status = status
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.status = try container.decode(LWCatalogStorageStorageStatus.self, forKey: LWCatalogCodingKey("status"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
    }
}

/// application::relink::Outcome (engines/catalog/src/application/relink.rs:328).
nonisolated indirect enum LWApplicationRelinkOutcome: Codable, Sendable {
    case Plan(LWApplicationRelinkPlan)
    case Mounts(LWApplicationRelinkMounts)
    case Original(LWApplicationRelinkOriginal)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "plan":
            self = .Plan(try container.decode(LWApplicationRelinkPlan.self, forKey: LWCatalogCodingKey("value")))
        case "mounts":
            self = .Mounts(try container.decode(LWApplicationRelinkMounts.self, forKey: LWCatalogCodingKey("value")))
        case "original":
            self = .Original(try container.decode(LWApplicationRelinkOriginal.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkOutcome variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Plan(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Mounts(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("mounts", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Original(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("original", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::relink::Override (engines/catalog/src/application/relink.rs:52).
nonisolated indirect enum LWApplicationRelinkOverride: Codable, Sendable {
    case Asset(asset_id: String, candidates: [LWCatalogNativePath])
    case Source(source_id: LWCatalogI64, candidates: [LWCatalogNativePath])
    case Prefix(from: LWCatalogStoragePathReference, destinations: [LWCatalogNativePath])
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("target"))
        switch discriminator {
        case "asset":
            try container.lwRequireKeys(["target", "value"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["asset_id", "candidates"])
            self = .Asset(asset_id: try payload.decode(String.self, forKey: LWCatalogCodingKey("asset_id")), candidates: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("candidates")))
        case "source":
            try container.lwRequireKeys(["target", "value"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["source_id", "candidates"])
            self = .Source(source_id: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source_id")), candidates: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("candidates")))
        case "prefix":
            try container.lwRequireKeys(["target", "value"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["from", "destinations"])
            self = .Prefix(from: try payload.decode(LWCatalogStoragePathReference.self, forKey: LWCatalogCodingKey("from")), destinations: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("destinations")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkOverride variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Asset(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("asset", forKey: LWCatalogCodingKey("target"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("asset_id"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("candidates"))
        case .Source(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("source", forKey: LWCatalogCodingKey("target"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("source_id"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("candidates"))
        case .Prefix(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prefix", forKey: LWCatalogCodingKey("target"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("from"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destinations"))
        }
    }
}

/// application::relink::Phase (engines/catalog/src/application/relink.rs:304).
nonisolated enum LWApplicationRelinkPhase: String, Codable, Sendable {
    case Preparing = "preparing"
    case Observing = "observing"
    case Draining = "draining"
    case Applying = "applying"
    case Undoing = "undoing"
    case CancelRequested = "cancel_requested"
    case Complete = "complete"
    case Canceled = "canceled"
    case Failed = "failed"
}

/// application::relink::Plan (engines/catalog/src/application/relink.rs:202).
nonisolated struct LWApplicationRelinkPlan: Codable, Sendable {
    var id: String
    var state: String
    var revision: LWCatalogI64
    var scanned_through: LWCatalogI64
    var high_water: LWCatalogI64
    var total: LWCatalogI64
    var matched: LWCatalogI64
    var excluded: LWCatalogI64
    var unresolved: LWCatalogI64
    var unresolved_sources: LWCatalogI64
    var unverified: LWCatalogI64
    var user_confirmed: LWCatalogI64
    var confirmation_token: String?
    var summary_complete: Bool
    init(id: String, state: String, revision: LWCatalogI64, scanned_through: LWCatalogI64, high_water: LWCatalogI64, total: LWCatalogI64, matched: LWCatalogI64, excluded: LWCatalogI64, unresolved: LWCatalogI64, unresolved_sources: LWCatalogI64, unverified: LWCatalogI64, user_confirmed: LWCatalogI64, confirmation_token: String?, summary_complete: Bool) {
        self.id = id
        self.state = state
        self.revision = revision
        self.scanned_through = scanned_through
        self.high_water = high_water
        self.total = total
        self.matched = matched
        self.excluded = excluded
        self.unresolved = unresolved
        self.unresolved_sources = unresolved_sources
        self.unverified = unverified
        self.user_confirmed = user_confirmed
        self.confirmation_token = confirmation_token
        self.summary_complete = summary_complete
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.id = try container.decode(String.self, forKey: LWCatalogCodingKey("id"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.scanned_through = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("scanned_through"))
        self.high_water = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("high_water"))
        self.total = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("total"))
        self.matched = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("matched"))
        self.excluded = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("excluded"))
        self.unresolved = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("unresolved"))
        self.unresolved_sources = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("unresolved_sources"))
        self.unverified = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("unverified"))
        self.user_confirmed = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("user_confirmed"))
        self.confirmation_token = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("confirmation_token"))
        self.summary_complete = try container.decode(Bool.self, forKey: LWCatalogCodingKey("summary_complete"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(id, forKey: LWCatalogCodingKey("id"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(scanned_through, forKey: LWCatalogCodingKey("scanned_through"))
        try container.encode(high_water, forKey: LWCatalogCodingKey("high_water"))
        try container.encode(total, forKey: LWCatalogCodingKey("total"))
        try container.encode(matched, forKey: LWCatalogCodingKey("matched"))
        try container.encode(excluded, forKey: LWCatalogCodingKey("excluded"))
        try container.encode(unresolved, forKey: LWCatalogCodingKey("unresolved"))
        try container.encode(unresolved_sources, forKey: LWCatalogCodingKey("unresolved_sources"))
        try container.encode(unverified, forKey: LWCatalogCodingKey("unverified"))
        try container.encode(user_confirmed, forKey: LWCatalogCodingKey("user_confirmed"))
        try container.encode(confirmation_token, forKey: LWCatalogCodingKey("confirmation_token"))
        try container.encode(summary_complete, forKey: LWCatalogCodingKey("summary_complete"))
    }
}

/// application::relink::Request (engines/catalog/src/application/relink.rs:73).
nonisolated indirect enum LWApplicationRelinkRequest: Codable, Sendable {
    case Rules(plan: String, revision: LWCatalogI64, after: LWApplicationRelinkRuleCursor?, limit: LWCatalogU64)
    case Begin(scope: LWApplicationRelinkScope)
    case Prepare(plan: String, revision: LWCatalogI64, batch_rows: LWCatalogU64)
    case Revise(plan: String, revision: LWCatalogI64, changes: [LWApplicationRelinkOverride])
    case Plan(plan: String)
    case Plans(after: String, limit: LWCatalogU64)
    case Items(plan: String, revision: LWCatalogI64, after: LWCatalogI64, limit: LWCatalogU64)
    case Sources(plan: String, revision: LWCatalogI64, sequence: LWCatalogI64, after: LWCatalogI64, limit: LWCatalogU64)
    case Confirm(plan: String, revision: LWCatalogI64, token: String, acknowledgement: String)
    case Apply(plan: String, revision: LWCatalogI64)
    case Undo(plan: String, revision: LWCatalogI64)
    case Mounts
    case Original(key: LWCatalogEditsVariantKey)
    case Status(operation: String?)
    case Cancel(operation: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("command"))
        switch discriminator {
        case "rules":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision", "after", "limit"])
            self = .Rules(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")), after: try payload.decodeIfPresent(LWApplicationRelinkRuleCursor.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "begin":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["scope"])
            self = .Begin(scope: try payload.decode(LWApplicationRelinkScope.self, forKey: LWCatalogCodingKey("scope")))
        case "prepare":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision", "batch_rows"])
            self = .Prepare(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")), batch_rows: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("batch_rows")))
        case "revise":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision", "changes"])
            self = .Revise(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")), changes: try payload.decode([LWApplicationRelinkOverride].self, forKey: LWCatalogCodingKey("changes")))
        case "plan":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan"])
            self = .Plan(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")))
        case "plans":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["after", "limit"])
            self = .Plans(after: try payload.decode(String.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "items":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision", "after", "limit"])
            self = .Items(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "sources":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision", "sequence", "after", "limit"])
            self = .Sources(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")), sequence: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("sequence")), after: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("after")), limit: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "confirm":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision", "token", "acknowledgement"])
            self = .Confirm(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")), token: try payload.decode(String.self, forKey: LWCatalogCodingKey("token")), acknowledgement: try payload.decode(String.self, forKey: LWCatalogCodingKey("acknowledgement")))
        case "apply":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision"])
            self = .Apply(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")))
        case "undo":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["plan", "revision"])
            self = .Undo(plan: try payload.decode(String.self, forKey: LWCatalogCodingKey("plan")), revision: try payload.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision")))
        case "mounts":
            try container.lwRequireKeys(["command", "args"])
            self = .Mounts
        case "original":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["key"])
            self = .Original(key: try payload.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key")))
        case "status":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Status(operation: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation")))
        case "cancel":
            try container.lwRequireKeys(["command", "args"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("args"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["operation"])
            self = .Cancel(operation: try payload.decode(String.self, forKey: LWCatalogCodingKey("operation")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkRequest variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Rules(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("rules", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Begin(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("scope"))
        case .Prepare(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prepare", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("batch_rows"))
        case .Revise(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("revise", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("changes"))
        case .Plan(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
        case .Plans(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plans", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("limit"))
        case .Items(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("limit"))
        case .Sources(let value0, let value1, let value2, let value3, let value4):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sources", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("sequence"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("after"))
            try payload.encode(value4, forKey: LWCatalogCodingKey("limit"))
        case .Confirm(let value0, let value1, let value2, let value3):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("confirm", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("token"))
            try payload.encode(value3, forKey: LWCatalogCodingKey("acknowledgement"))
        case .Apply(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("apply", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
        case .Undo(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("undo", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("plan"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("revision"))
        case .Mounts:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("mounts", forKey: LWCatalogCodingKey("command"))
        case .Original(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("original", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("key"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        case .Cancel(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("cancel", forKey: LWCatalogCodingKey("command"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("args"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("operation"))
        }
    }
}

/// application::relink::Response (engines/catalog/src/application/relink.rs:347).
nonisolated indirect enum LWApplicationRelinkResponse: Codable, Sendable {
    case Rules(rows: [LWApplicationRelinkRuleRow], next: LWApplicationRelinkRuleCursor?, scanned: LWCatalogU64)
    case Plan(LWApplicationRelinkPlan)
    case Plans(rows: [LWApplicationRelinkPlan], next: String?)
    case Items(rows: [LWApplicationRelinkItem], next: LWCatalogI64?)
    case Sources(rows: [LWApplicationRelinkSource], next: LWCatalogI64?)
    case Operation(LWApplicationRelinkOperation?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "rules":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Rules(rows: try payload.decode([LWApplicationRelinkRuleRow].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWApplicationRelinkRuleCursor.self, forKey: LWCatalogCodingKey("next")), scanned: try payload.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("scanned")))
        case "plan":
            self = .Plan(try container.decode(LWApplicationRelinkPlan.self, forKey: LWCatalogCodingKey("value")))
        case "plans":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Plans(rows: try payload.decode([LWApplicationRelinkPlan].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("next")))
        case "items":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Items(rows: try payload.decode([LWApplicationRelinkItem].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "sources":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Sources(rows: try payload.decode([LWApplicationRelinkSource].self, forKey: LWCatalogCodingKey("rows")), next: try payload.decodeIfPresent(LWCatalogI64.self, forKey: LWCatalogCodingKey("next")))
        case "operation":
            self = .Operation(try container.decode(LWApplicationRelinkOperation?.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkResponse variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Rules(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("rules", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("scanned"))
        case .Plan(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plan", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Plans(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("plans", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Items(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("items", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Sources(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("sources", forKey: LWCatalogCodingKey("kind"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("rows"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("next"))
        case .Operation(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("operation", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::relink::Rule (engines/catalog/src/application/relink.rs:192).
nonisolated indirect enum LWApplicationRelinkRule: Codable, Sendable {
    case Scope(LWApplicationRelinkSavedScope)
    case Override(LWApplicationRelinkOverride)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "scope":
            self = .Scope(try container.decode(LWApplicationRelinkSavedScope.self, forKey: LWCatalogCodingKey("value")))
        case "override":
            self = .Override(try container.decode(LWApplicationRelinkOverride.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkRule variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Scope(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("scope", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Override(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("override", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// application::relink::RuleCursor (engines/catalog/src/application/relink.rs:165).
nonisolated struct LWApplicationRelinkRuleCursor: Codable, Sendable {
    var plan: String
    var revision: LWCatalogI64
    var stage: LWApplicationRelinkRuleStage
    var position: LWCatalogI64
    var source: LWCatalogI64
    var entity: String
    init(plan: String, revision: LWCatalogI64, stage: LWApplicationRelinkRuleStage, position: LWCatalogI64, source: LWCatalogI64, entity: String) {
        self.plan = plan
        self.revision = revision
        self.stage = stage
        self.position = position
        self.source = source
        self.entity = entity
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["plan", "revision", "stage", "position", "source", "entity"])
        self.plan = try container.decode(String.self, forKey: LWCatalogCodingKey("plan"))
        self.revision = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("revision"))
        self.stage = try container.decode(LWApplicationRelinkRuleStage.self, forKey: LWCatalogCodingKey("stage"))
        self.position = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("position"))
        self.source = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source"))
        self.entity = try container.decode(String.self, forKey: LWCatalogCodingKey("entity"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(plan, forKey: LWCatalogCodingKey("plan"))
        try container.encode(revision, forKey: LWCatalogCodingKey("revision"))
        try container.encode(stage, forKey: LWCatalogCodingKey("stage"))
        try container.encode(position, forKey: LWCatalogCodingKey("position"))
        try container.encode(source, forKey: LWCatalogCodingKey("source"))
        try container.encode(entity, forKey: LWCatalogCodingKey("entity"))
    }
}

/// application::relink::RuleRow (engines/catalog/src/application/relink.rs:197).
nonisolated struct LWApplicationRelinkRuleRow: Codable, Sendable {
    var rule: LWApplicationRelinkRule
    var label: String?
    init(rule: LWApplicationRelinkRule, label: String?) {
        self.rule = rule
        self.label = label
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.rule = try container.decode(LWApplicationRelinkRule.self, forKey: LWCatalogCodingKey("rule"))
        self.label = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("label"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(rule, forKey: LWCatalogCodingKey("rule"))
        try container.encode(label, forKey: LWCatalogCodingKey("label"))
    }
}

/// application::relink::RuleStage (engines/catalog/src/application/relink.rs:154).
nonisolated enum LWApplicationRelinkRuleStage: String, Codable, Sendable {
    case Scope = "scope"
    case Prefix = "prefix"
    case Asset = "asset"
    case Source = "source"
    case ExcludedAsset = "excluded_asset"
    case ExcludedSource = "excluded_source"
    case End = "end"
}

/// application::relink::SavedScope (engines/catalog/src/application/relink.rs:175).
nonisolated indirect enum LWApplicationRelinkSavedScope: Codable, Sendable {
    case Prefix(from: LWCatalogStoragePathReference, destinations: [LWCatalogNativePath])
    case Asset(asset_id: String, destinations: [LWCatalogNativePath])
    case Volume(logical_volume: String, mount_path: LWCatalogNativePath, filesystem: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("scope"))
        switch discriminator {
        case "prefix":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Prefix(from: try payload.decode(LWCatalogStoragePathReference.self, forKey: LWCatalogCodingKey("from")), destinations: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("destinations")))
        case "asset":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Asset(asset_id: try payload.decode(String.self, forKey: LWCatalogCodingKey("asset_id")), destinations: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("destinations")))
        case "volume":
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            self = .Volume(logical_volume: try payload.decode(String.self, forKey: LWCatalogCodingKey("logical_volume")), mount_path: try payload.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("mount_path")), filesystem: try payload.decode(String.self, forKey: LWCatalogCodingKey("filesystem")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkSavedScope variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Prefix(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prefix", forKey: LWCatalogCodingKey("scope"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("from"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destinations"))
        case .Asset(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("asset", forKey: LWCatalogCodingKey("scope"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("asset_id"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destinations"))
        case .Volume(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("volume", forKey: LWCatalogCodingKey("scope"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("logical_volume"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("mount_path"))
            try payload.encode(value2, forKey: LWCatalogCodingKey("filesystem"))
        }
    }
}

/// application::relink::Scope (engines/catalog/src/application/relink.rs:31).
nonisolated indirect enum LWApplicationRelinkScope: Codable, Sendable {
    case Prefix(from: LWCatalogStoragePathReference, destinations: [LWCatalogNativePath])
    case Asset(asset_id: String, destinations: [LWCatalogNativePath])
    case Volume(logical_volume: String, mount_token: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("scope"))
        switch discriminator {
        case "prefix":
            try container.lwRequireKeys(["scope", "value"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["from", "destinations"])
            self = .Prefix(from: try payload.decode(LWCatalogStoragePathReference.self, forKey: LWCatalogCodingKey("from")), destinations: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("destinations")))
        case "asset":
            try container.lwRequireKeys(["scope", "value"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["asset_id", "destinations"])
            self = .Asset(asset_id: try payload.decode(String.self, forKey: LWCatalogCodingKey("asset_id")), destinations: try payload.decode([LWCatalogNativePath].self, forKey: LWCatalogCodingKey("destinations")))
        case "volume":
            try container.lwRequireKeys(["scope", "value"])
            let payloadDecoder = try container.superDecoder(forKey: LWCatalogCodingKey("value"))
            let payload = try payloadDecoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.lwRequireKeys(["logical_volume", "mount_token"])
            self = .Volume(logical_volume: try payload.decode(String.self, forKey: LWCatalogCodingKey("logical_volume")), mount_token: try payload.decode(String.self, forKey: LWCatalogCodingKey("mount_token")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWApplicationRelinkScope variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Prefix(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prefix", forKey: LWCatalogCodingKey("scope"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("from"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destinations"))
        case .Asset(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("asset", forKey: LWCatalogCodingKey("scope"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("asset_id"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("destinations"))
        case .Volume(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("volume", forKey: LWCatalogCodingKey("scope"))
            let payloadEncoder = container.superEncoder(forKey: LWCatalogCodingKey("value"))
            var payload = payloadEncoder.container(keyedBy: LWCatalogCodingKey.self)
            try payload.encode(value0, forKey: LWCatalogCodingKey("logical_volume"))
            try payload.encode(value1, forKey: LWCatalogCodingKey("mount_token"))
        }
    }
}

/// application::relink::Source (engines/catalog/src/application/relink.rs:264).
nonisolated struct LWApplicationRelinkSource: Codable, Sendable {
    var source_id: LWCatalogI64
    var status: String
    var detail: String
    var original: LWCatalogStoragePathReference
    var candidates: [LWCatalogStorageCandidate]
    var destination: LWCatalogNativePath?
    init(source_id: LWCatalogI64, status: String, detail: String, original: LWCatalogStoragePathReference, candidates: [LWCatalogStorageCandidate], destination: LWCatalogNativePath?) {
        self.source_id = source_id
        self.status = status
        self.detail = detail
        self.original = original
        self.candidates = candidates
        self.destination = destination
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.source_id = try container.decode(LWCatalogI64.self, forKey: LWCatalogCodingKey("source_id"))
        self.status = try container.decode(String.self, forKey: LWCatalogCodingKey("status"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
        self.original = try container.decode(LWCatalogStoragePathReference.self, forKey: LWCatalogCodingKey("original"))
        self.candidates = try container.decode([LWCatalogStorageCandidate].self, forKey: LWCatalogCodingKey("candidates"))
        self.destination = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("destination"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(source_id, forKey: LWCatalogCodingKey("source_id"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
        try container.encode(original, forKey: LWCatalogCodingKey("original"))
        try container.encode(candidates, forKey: LWCatalogCodingKey("candidates"))
        try container.encode(destination, forKey: LWCatalogCodingKey("destination"))
    }
}

/// catalog_backup::Phase (engines/catalog/src/catalog_backup.rs:85).
nonisolated enum LWCatalogBackupPhase: String, Codable, Sendable {
    case Snapshot = "Snapshot"
    case Copy = "Copy"
    case Verify = "Verify"
    case Hash = "Hash"
    case Upgrade = "Upgrade"
    case Publish = "Publish"
}

/// catalog_edits::VariantKey (engines/catalog/src/catalog_edits.rs:59).
nonisolated struct LWCatalogEditsVariantKey: Codable, Sendable {
    var asset_id: String
    var variant_id: String
    init(asset_id: String, variant_id: String) {
        self.asset_id = asset_id
        self.variant_id = variant_id
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["asset_id", "variant_id"])
        self.asset_id = try container.decode(String.self, forKey: LWCatalogCodingKey("asset_id"))
        self.variant_id = try container.decode(String.self, forKey: LWCatalogCodingKey("variant_id"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(asset_id, forKey: LWCatalogCodingKey("asset_id"))
        try container.encode(variant_id, forKey: LWCatalogCodingKey("variant_id"))
    }
}

/// catalog_images::ImageMetadataIdentity (engines/catalog/src/catalog_images.rs:59).
nonisolated struct LWCatalogImagesImageMetadataIdentity: Codable, Sendable {
    var image_id: String
    var key: LWCatalogEditsVariantKey
    var metadata_revision: Int64
    var pixel_generation: Int64
    var shared_source_epoch: Int64
    var physical_generation: Int64
    init(image_id: String, key: LWCatalogEditsVariantKey, metadata_revision: Int64, pixel_generation: Int64, shared_source_epoch: Int64, physical_generation: Int64) {
        self.image_id = image_id
        self.key = key
        self.metadata_revision = metadata_revision
        self.pixel_generation = pixel_generation
        self.shared_source_epoch = shared_source_epoch
        self.physical_generation = physical_generation
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["image_id", "key", "metadata_revision", "pixel_generation", "shared_source_epoch", "physical_generation"])
        self.image_id = try container.decode(String.self, forKey: LWCatalogCodingKey("image_id"))
        self.key = try container.decode(LWCatalogEditsVariantKey.self, forKey: LWCatalogCodingKey("key"))
        self.metadata_revision = try container.decode(Int64.self, forKey: LWCatalogCodingKey("metadata_revision"))
        self.pixel_generation = try container.decode(Int64.self, forKey: LWCatalogCodingKey("pixel_generation"))
        self.shared_source_epoch = try container.decode(Int64.self, forKey: LWCatalogCodingKey("shared_source_epoch"))
        self.physical_generation = try container.decode(Int64.self, forKey: LWCatalogCodingKey("physical_generation"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(image_id, forKey: LWCatalogCodingKey("image_id"))
        try container.encode(key, forKey: LWCatalogCodingKey("key"))
        try container.encode(metadata_revision, forKey: LWCatalogCodingKey("metadata_revision"))
        try container.encode(pixel_generation, forKey: LWCatalogCodingKey("pixel_generation"))
        try container.encode(shared_source_epoch, forKey: LWCatalogCodingKey("shared_source_epoch"))
        try container.encode(physical_generation, forKey: LWCatalogCodingKey("physical_generation"))
    }
}

/// catalog_metadata_write::Owner (engines/catalog/src/catalog_metadata_write.rs:21).
nonisolated indirect enum LWCatalogMetadataWriteOwner: Codable, Sendable {
    case Image(identity: LWCatalogImagesImageMetadataIdentity)
    case LegacyAsset(asset_id: String, revision: Int64)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "image":
            try container.lwRequireKeys(["kind", "identity"])
            self = .Image(identity: try container.decode(LWCatalogImagesImageMetadataIdentity.self, forKey: LWCatalogCodingKey("identity")))
        case "legacy_asset":
            try container.lwRequireKeys(["kind", "asset_id", "revision"])
            self = .LegacyAsset(asset_id: try container.decode(String.self, forKey: LWCatalogCodingKey("asset_id")), revision: try container.decode(Int64.self, forKey: LWCatalogCodingKey("revision")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWCatalogMetadataWriteOwner variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Image(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("image", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("identity"))
        case .LegacyAsset(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("legacy_asset", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("asset_id"))
            try container.encode(value1, forKey: LWCatalogCodingKey("revision"))
        }
    }
}

/// catalog_metadata_write::Receipt (engines/catalog/src/catalog_metadata_write.rs:28).
nonisolated struct LWCatalogMetadataWriteReceipt: Codable, Sendable {
    var attempt: String
    var request_digest: String
    var kind: String
    var owner: LWCatalogMetadataWriteOwner
    var result: LWCatalogJSON
    var created_at: String
    init(attempt: String, request_digest: String, kind: String, owner: LWCatalogMetadataWriteOwner, result: LWCatalogJSON, created_at: String) {
        self.attempt = attempt
        self.request_digest = request_digest
        self.kind = kind
        self.owner = owner
        self.result = result
        self.created_at = created_at
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["attempt", "request_digest", "kind", "owner", "result", "created_at"])
        self.attempt = try container.decode(String.self, forKey: LWCatalogCodingKey("attempt"))
        self.request_digest = try container.decode(String.self, forKey: LWCatalogCodingKey("request_digest"))
        self.kind = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        self.owner = try container.decode(LWCatalogMetadataWriteOwner.self, forKey: LWCatalogCodingKey("owner"))
        self.result = try container.decode(LWCatalogJSON.self, forKey: LWCatalogCodingKey("result"))
        self.created_at = try container.decode(String.self, forKey: LWCatalogCodingKey("created_at"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(attempt, forKey: LWCatalogCodingKey("attempt"))
        try container.encode(request_digest, forKey: LWCatalogCodingKey("request_digest"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(owner, forKey: LWCatalogCodingKey("owner"))
        try container.encode(result, forKey: LWCatalogCodingKey("result"))
        try container.encode(created_at, forKey: LWCatalogCodingKey("created_at"))
    }
}

/// catalog_migration::history::Classification (engines/catalog/src/catalog_migration/history.rs:34).
nonisolated enum LWCatalogMigrationHistoryClassification: String, Codable, Sendable {
    case Image = "Image"
    case CurrentSettings = "CurrentSettings"
    case Settings = "Settings"
    case BeforeSettings = "BeforeSettings"
    case History = "History"
    case Snapshot = "Snapshot"
    case Metadata = "Metadata"
    case Organization = "Organization"
    case Unsupported = "Unsupported"
}

/// catalog_migration::history::Compatibility (engines/catalog/src/catalog_migration/history.rs:46).
nonisolated enum LWCatalogMigrationHistoryCompatibility: String, Codable, Sendable {
    case RetainedOnly = "RetainedOnly"
    case Missing = "Missing"
    case Ambiguous = "Ambiguous"
    case Unavailable = "Unavailable"
    case OutsideImageHistory = "OutsideImageHistory"
    case TraversalLimit = "TraversalLimit"
}

/// catalog_migration::history::Direction (engines/catalog/src/catalog_migration/history.rs:29).
nonisolated enum LWCatalogMigrationHistoryDirection: String, Codable, Sendable {
    case Incoming = "Incoming"
    case Outgoing = "Outgoing"
}

/// catalog_session::PhysicalObjectId (engines/catalog/src/catalog_session.rs:32).
nonisolated indirect enum LWCatalogSessionPhysicalObjectId: Codable, Sendable {
    case Unix(device: LWCatalogU64, inode: LWCatalogU64)
    case Windows(volume_serial: LWCatalogU64, file_index: LWCatalogU64)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("platform"))
        switch discriminator {
        case "unix":
            try container.lwRequireKeys(["platform", "device", "inode"])
            self = .Unix(device: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("device")), inode: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("inode")))
        case "windows":
            try container.lwRequireKeys(["platform", "volume_serial", "file_index"])
            self = .Windows(volume_serial: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("volume_serial")), file_index: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("file_index")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWCatalogSessionPhysicalObjectId variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Unix(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("unix", forKey: LWCatalogCodingKey("platform"))
            try container.encode(value0, forKey: LWCatalogCodingKey("device"))
            try container.encode(value1, forKey: LWCatalogCodingKey("inode"))
        case .Windows(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("windows", forKey: LWCatalogCodingKey("platform"))
            try container.encode(value0, forKey: LWCatalogCodingKey("volume_serial"))
            try container.encode(value1, forKey: LWCatalogCodingKey("file_index"))
        }
    }
}

/// catalog_session::metadata_files::DiscoveryEntry (engines/catalog/src/catalog_session/metadata_files.rs:209).
nonisolated struct LWCatalogSessionMetadataFilesDiscoveryEntry: Codable, Sendable {
    var directory: LWCatalogNativePath
    var name: LWCatalogNativePath
    var kind: String
    var operation: String?
    var plan_digest: String?
    var detail: String
    init(directory: LWCatalogNativePath, name: LWCatalogNativePath, kind: String, operation: String?, plan_digest: String?, detail: String) {
        self.directory = directory
        self.name = name
        self.kind = kind
        self.operation = operation
        self.plan_digest = plan_digest
        self.detail = detail
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["directory", "name", "kind", "operation", "plan_digest", "detail"])
        self.directory = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory"))
        self.name = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("name"))
        self.kind = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        self.operation = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("operation"))
        self.plan_digest = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("plan_digest"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(directory, forKey: LWCatalogCodingKey("directory"))
        try container.encode(name, forKey: LWCatalogCodingKey("name"))
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
        try container.encode(plan_digest, forKey: LWCatalogCodingKey("plan_digest"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
    }
}

/// catalog_storage::Candidate (engines/catalog/src/catalog_storage.rs:117).
nonisolated struct LWCatalogStorageCandidate: Codable, Sendable {
    var path: LWCatalogNativePath
    var status: LWCatalogStorageMatchStatus
    var detail: String
    init(path: LWCatalogNativePath, status: LWCatalogStorageMatchStatus, detail: String) {
        self.path = path
        self.status = status
        self.detail = detail
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.path = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path"))
        self.status = try container.decode(LWCatalogStorageMatchStatus.self, forKey: LWCatalogCodingKey("status"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(path, forKey: LWCatalogCodingKey("path"))
        try container.encode(status, forKey: LWCatalogCodingKey("status"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
    }
}

/// catalog_storage::MatchStatus (engines/catalog/src/catalog_storage.rs:90).
nonisolated enum LWCatalogStorageMatchStatus: String, Codable, Sendable {
    case Matched = "Matched"
    case Unverified = "Unverified"
    case UserConfirmed = "UserConfirmed"
    case Historical = "Historical"
    case Missing = "Missing"
    case Mismatch = "Mismatch"
    case Ambiguous = "Ambiguous"
    case Unavailable = "Unavailable"
    case Excluded = "Excluded"
}

/// catalog_storage::PathReference (engines/catalog/src/catalog_storage.rs:62).
nonisolated indirect enum LWCatalogStoragePathReference: Codable, Sendable {
    case Unspecified([UInt8])
    case Native(LWCatalogNativePath)
    case LegacyUnix([UInt8])
    case LegacyWindows([UInt16])
    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            switch single {
            default: throw LensWorksManagedError.protocolViolation("Unknown LWCatalogStoragePathReference variant.")
            }
        }
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        guard container.allKeys.count == 1, let discriminator = container.allKeys.first?.stringValue else { throw LensWorksManagedError.protocolViolation("Expected one externally tagged variant.") }
        switch discriminator {
        case "Unspecified":
            self = .Unspecified(try container.decode([UInt8].self, forKey: LWCatalogCodingKey("Unspecified")))
        case "Native":
            self = .Native(try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("Native")))
        case "LegacyUnix":
            self = .LegacyUnix(try container.decode([UInt8].self, forKey: LWCatalogCodingKey("LegacyUnix")))
        case "LegacyWindows":
            self = .LegacyWindows(try container.decode([UInt16].self, forKey: LWCatalogCodingKey("LegacyWindows")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWCatalogStoragePathReference variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Unspecified(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode(value0, forKey: LWCatalogCodingKey("Unspecified"))
        case .Native(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode(value0, forKey: LWCatalogCodingKey("Native"))
        case .LegacyUnix(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode(value0, forKey: LWCatalogCodingKey("LegacyUnix"))
        case .LegacyWindows(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode(value0, forKey: LWCatalogCodingKey("LegacyWindows"))
        }
    }
}

/// catalog_storage::StorageStatus (engines/catalog/src/catalog_storage.rs:161).
nonisolated struct LWCatalogStorageStorageStatus: Codable, Sendable {
    var asset_id: String
    var state: String
    var current: LWCatalogStoragePathReference
    var candidate: LWCatalogNativePath?
    var logical_volume: String?
    var detail: String
    init(asset_id: String, state: String, current: LWCatalogStoragePathReference, candidate: LWCatalogNativePath?, logical_volume: String?, detail: String) {
        self.asset_id = asset_id
        self.state = state
        self.current = current
        self.candidate = candidate
        self.logical_volume = logical_volume
        self.detail = detail
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.asset_id = try container.decode(String.self, forKey: LWCatalogCodingKey("asset_id"))
        self.state = try container.decode(String.self, forKey: LWCatalogCodingKey("state"))
        self.current = try container.decode(LWCatalogStoragePathReference.self, forKey: LWCatalogCodingKey("current"))
        self.candidate = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("candidate"))
        self.logical_volume = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("logical_volume"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(asset_id, forKey: LWCatalogCodingKey("asset_id"))
        try container.encode(state, forKey: LWCatalogCodingKey("state"))
        try container.encode(current, forKey: LWCatalogCodingKey("current"))
        try container.encode(candidate, forKey: LWCatalogCodingKey("candidate"))
        try container.encode(logical_volume, forKey: LWCatalogCodingKey("logical_volume"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
    }
}

/// edit::recipe::AdjustmentGroup (engines/catalog/src/edit/recipe.rs:58).
nonisolated enum LWEditRecipeAdjustmentGroup: String, Codable, Sendable {
    case Geometry = "geometry"
    case Exposure = "exposure"
    case WhiteBalance = "white_balance"
    case Tone = "tone"
    case Color = "color"
    case Sharpening = "sharpening"
    case NoiseReduction = "noise_reduction"
}

/// edit::recipe::NoiseReduction (engines/catalog/src/edit/recipe.rs:52).
nonisolated struct LWEditRecipeNoiseReduction: Codable, Sendable {
    var luminance: LWCatalogFloat32
    var chroma: LWCatalogFloat32
    init(luminance: LWCatalogFloat32, chroma: LWCatalogFloat32) {
        self.luminance = luminance
        self.chroma = chroma
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["luminance", "chroma"])
        self.luminance = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("luminance"))
        self.chroma = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("chroma"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(luminance, forKey: LWCatalogCodingKey("luminance"))
        try container.encode(chroma, forKey: LWCatalogCodingKey("chroma"))
    }
}

/// edit::recipe::NormalizedRect (engines/catalog/src/edit/recipe.rs:32).
nonisolated struct LWEditRecipeNormalizedRect: Codable, Sendable {
    var left: LWCatalogFloat32
    var top: LWCatalogFloat32
    var right: LWCatalogFloat32
    var bottom: LWCatalogFloat32
    init(left: LWCatalogFloat32, top: LWCatalogFloat32, right: LWCatalogFloat32, bottom: LWCatalogFloat32) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["left", "top", "right", "bottom"])
        self.left = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("left"))
        self.top = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("top"))
        self.right = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("right"))
        self.bottom = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("bottom"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(left, forKey: LWCatalogCodingKey("left"))
        try container.encode(top, forKey: LWCatalogCodingKey("top"))
        try container.encode(right, forKey: LWCatalogCodingKey("right"))
        try container.encode(bottom, forKey: LWCatalogCodingKey("bottom"))
    }
}

/// edit::recipe::Recipe (engines/catalog/src/edit/recipe.rs:8).
nonisolated indirect enum LWEditRecipeRecipe: Codable, Sendable {
    case V1(LWEditRecipeRecipeV1)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("version"))
        switch discriminator {
        case "1":
            try container.lwRequireKeys(["version", "settings"])
            self = .V1(try container.decode(LWEditRecipeRecipeV1.self, forKey: LWCatalogCodingKey("settings")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWEditRecipeRecipe variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .V1(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("1", forKey: LWCatalogCodingKey("version"))
            try container.encode(value0, forKey: LWCatalogCodingKey("settings"))
        }
    }
}

/// edit::recipe::RecipeV1 (engines/catalog/src/edit/recipe.rs:14).
nonisolated struct LWEditRecipeRecipeV1: Codable, Sendable {
    var crop: LWEditRecipeNormalizedRect?
    var straighten_degrees: LWCatalogFloat32
    var exposure_ev: LWCatalogFloat32
    var white_balance: LWEditRecipeWhiteBalance
    var contrast: LWCatalogFloat32
    var highlights: LWCatalogFloat32
    var shadows: LWCatalogFloat32
    var saturation: LWCatalogFloat32
    var vibrance: LWCatalogFloat32
    var sharpening: LWEditRecipeSharpening
    var noise_reduction: LWEditRecipeNoiseReduction
    init(crop: LWEditRecipeNormalizedRect?, straighten_degrees: LWCatalogFloat32, exposure_ev: LWCatalogFloat32, white_balance: LWEditRecipeWhiteBalance, contrast: LWCatalogFloat32, highlights: LWCatalogFloat32, shadows: LWCatalogFloat32, saturation: LWCatalogFloat32, vibrance: LWCatalogFloat32, sharpening: LWEditRecipeSharpening, noise_reduction: LWEditRecipeNoiseReduction) {
        self.crop = crop
        self.straighten_degrees = straighten_degrees
        self.exposure_ev = exposure_ev
        self.white_balance = white_balance
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.saturation = saturation
        self.vibrance = vibrance
        self.sharpening = sharpening
        self.noise_reduction = noise_reduction
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["crop", "straighten_degrees", "exposure_ev", "white_balance", "contrast", "highlights", "shadows", "saturation", "vibrance", "sharpening", "noise_reduction"])
        self.crop = try container.decodeIfPresent(LWEditRecipeNormalizedRect.self, forKey: LWCatalogCodingKey("crop"))
        self.straighten_degrees = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("straighten_degrees"))
        self.exposure_ev = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("exposure_ev"))
        self.white_balance = try container.decode(LWEditRecipeWhiteBalance.self, forKey: LWCatalogCodingKey("white_balance"))
        self.contrast = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("contrast"))
        self.highlights = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("highlights"))
        self.shadows = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("shadows"))
        self.saturation = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("saturation"))
        self.vibrance = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("vibrance"))
        self.sharpening = try container.decode(LWEditRecipeSharpening.self, forKey: LWCatalogCodingKey("sharpening"))
        self.noise_reduction = try container.decode(LWEditRecipeNoiseReduction.self, forKey: LWCatalogCodingKey("noise_reduction"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(crop, forKey: LWCatalogCodingKey("crop"))
        try container.encode(straighten_degrees, forKey: LWCatalogCodingKey("straighten_degrees"))
        try container.encode(exposure_ev, forKey: LWCatalogCodingKey("exposure_ev"))
        try container.encode(white_balance, forKey: LWCatalogCodingKey("white_balance"))
        try container.encode(contrast, forKey: LWCatalogCodingKey("contrast"))
        try container.encode(highlights, forKey: LWCatalogCodingKey("highlights"))
        try container.encode(shadows, forKey: LWCatalogCodingKey("shadows"))
        try container.encode(saturation, forKey: LWCatalogCodingKey("saturation"))
        try container.encode(vibrance, forKey: LWCatalogCodingKey("vibrance"))
        try container.encode(sharpening, forKey: LWCatalogCodingKey("sharpening"))
        try container.encode(noise_reduction, forKey: LWCatalogCodingKey("noise_reduction"))
    }
}

/// edit::recipe::Sharpening (engines/catalog/src/edit/recipe.rs:46).
nonisolated struct LWEditRecipeSharpening: Codable, Sendable {
    var amount: LWCatalogFloat32
    var radius_px: LWCatalogFloat32
    init(amount: LWCatalogFloat32, radius_px: LWCatalogFloat32) {
        self.amount = amount
        self.radius_px = radius_px
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["amount", "radius_px"])
        self.amount = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("amount"))
        self.radius_px = try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("radius_px"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(amount, forKey: LWCatalogCodingKey("amount"))
        try container.encode(radius_px, forKey: LWCatalogCodingKey("radius_px"))
    }
}

/// edit::recipe::WhiteBalance (engines/catalog/src/edit/recipe.rs:40).
nonisolated indirect enum LWEditRecipeWhiteBalance: Codable, Sendable {
    case AsShot
    case TemperatureTint(kelvin: UInt32, tint: LWCatalogFloat32)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("mode"))
        switch discriminator {
        case "as_shot":
            try container.lwRequireKeys(["mode"])
            self = .AsShot
        case "temperature_tint":
            try container.lwRequireKeys(["mode", "kelvin", "tint"])
            self = .TemperatureTint(kelvin: try container.decode(UInt32.self, forKey: LWCatalogCodingKey("kelvin")), tint: try container.decode(LWCatalogFloat32.self, forKey: LWCatalogCodingKey("tint")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWEditRecipeWhiteBalance variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .AsShot:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("as_shot", forKey: LWCatalogCodingKey("mode"))
        case .TemperatureTint(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("temperature_tint", forKey: LWCatalogCodingKey("mode"))
            try container.encode(value0, forKey: LWCatalogCodingKey("kelvin"))
            try container.encode(value1, forKey: LWCatalogCodingKey("tint"))
        }
    }
}

/// filesystem_worker::wire::LightroomArtifactPreparation (engines/catalog/src/filesystem_worker/wire.rs:350).
nonisolated indirect enum LWFilesystemWorkerWireLightroomArtifactPreparation: Codable, Sendable {
    case Begin(session: String, directory: LWCatalogNativePath, capture_revision: String, manifest_blake3: String, maximum_bytes: LWCatalogU64, open_deadline_ms: LWCatalogU64)
    case Member(session: String, member_index: LWCatalogU64)
    case Resolve(receipt: String)
    case DiscardReceipt(receipt: String)
    case Discard(session: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("action"))
        switch discriminator {
        case "begin":
            try container.lwRequireKeys(["action", "session", "directory", "capture_revision", "manifest_blake3", "maximum_bytes", "open_deadline_ms"])
            self = .Begin(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")), directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")), capture_revision: try container.decode(String.self, forKey: LWCatalogCodingKey("capture_revision")), manifest_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("manifest_blake3")), maximum_bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("maximum_bytes")), open_deadline_ms: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("open_deadline_ms")))
        case "member":
            try container.lwRequireKeys(["action", "session", "member_index"])
            self = .Member(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")), member_index: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("member_index")))
        case "resolve":
            try container.lwRequireKeys(["action", "receipt"])
            self = .Resolve(receipt: try container.decode(String.self, forKey: LWCatalogCodingKey("receipt")))
        case "discard_receipt":
            try container.lwRequireKeys(["action", "receipt"])
            self = .DiscardReceipt(receipt: try container.decode(String.self, forKey: LWCatalogCodingKey("receipt")))
        case "discard":
            try container.lwRequireKeys(["action", "session"])
            self = .Discard(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWFilesystemWorkerWireLightroomArtifactPreparation variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Begin(let value0, let value1, let value2, let value3, let value4, let value5):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
            try container.encode(value1, forKey: LWCatalogCodingKey("directory"))
            try container.encode(value2, forKey: LWCatalogCodingKey("capture_revision"))
            try container.encode(value3, forKey: LWCatalogCodingKey("manifest_blake3"))
            try container.encode(value4, forKey: LWCatalogCodingKey("maximum_bytes"))
            try container.encode(value5, forKey: LWCatalogCodingKey("open_deadline_ms"))
        case .Member(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("member", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
            try container.encode(value1, forKey: LWCatalogCodingKey("member_index"))
        case .Resolve(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("resolve", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("receipt"))
        case .DiscardReceipt(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("discard_receipt", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("receipt"))
        case .Discard(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("discard", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
        }
    }
}

/// filesystem_worker::wire::LightroomArtifactPreparationReply (engines/catalog/src/filesystem_worker/wire.rs:421).
nonisolated indirect enum LWFilesystemWorkerWireLightroomArtifactPreparationReply: Codable, Sendable {
    case Begun(session: String, directory: LWCatalogNativePath, manifest_path: LWCatalogNativePath, manifest_physical: LWCatalogSessionPhysicalObjectId, capture_revision: String, manifest_blake3: String, manifest_bytes: LWCatalogU64, members: LWCatalogU64)
    case Prepared(session: String, member_index: LWCatalogU64, receipt: String)
    case Resolved(receipt: String, input_json: String, input_blake3: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "begun":
            try container.lwRequireKeys(["kind", "session", "directory", "manifest_path", "manifest_physical", "capture_revision", "manifest_blake3", "manifest_bytes", "members"])
            self = .Begun(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")), directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")), manifest_path: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("manifest_path")), manifest_physical: try container.decode(LWCatalogSessionPhysicalObjectId.self, forKey: LWCatalogCodingKey("manifest_physical")), capture_revision: try container.decode(String.self, forKey: LWCatalogCodingKey("capture_revision")), manifest_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("manifest_blake3")), manifest_bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("manifest_bytes")), members: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("members")))
        case "prepared":
            try container.lwRequireKeys(["kind", "session", "member_index", "receipt"])
            self = .Prepared(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")), member_index: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("member_index")), receipt: try container.decode(String.self, forKey: LWCatalogCodingKey("receipt")))
        case "resolved":
            try container.lwRequireKeys(["kind", "receipt", "input_json", "input_blake3"])
            self = .Resolved(receipt: try container.decode(String.self, forKey: LWCatalogCodingKey("receipt")), input_json: try container.decode(String.self, forKey: LWCatalogCodingKey("input_json")), input_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("input_blake3")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWFilesystemWorkerWireLightroomArtifactPreparationReply variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Begun(let value0, let value1, let value2, let value3, let value4, let value5, let value6, let value7):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begun", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
            try container.encode(value1, forKey: LWCatalogCodingKey("directory"))
            try container.encode(value2, forKey: LWCatalogCodingKey("manifest_path"))
            try container.encode(value3, forKey: LWCatalogCodingKey("manifest_physical"))
            try container.encode(value4, forKey: LWCatalogCodingKey("capture_revision"))
            try container.encode(value5, forKey: LWCatalogCodingKey("manifest_blake3"))
            try container.encode(value6, forKey: LWCatalogCodingKey("manifest_bytes"))
            try container.encode(value7, forKey: LWCatalogCodingKey("members"))
        case .Prepared(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prepared", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
            try container.encode(value1, forKey: LWCatalogCodingKey("member_index"))
            try container.encode(value2, forKey: LWCatalogCodingKey("receipt"))
        case .Resolved(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("resolved", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("receipt"))
            try container.encode(value1, forKey: LWCatalogCodingKey("input_json"))
            try container.encode(value2, forKey: LWCatalogCodingKey("input_blake3"))
        }
    }
}

/// filesystem_worker::wire::LightroomSealedDocument (engines/catalog/src/filesystem_worker/wire.rs:280).
nonisolated enum LWFilesystemWorkerWireLightroomSealedDocument: String, Codable, Sendable {
    case Seal = "seal"
    case Approval = "approval"
}

/// filesystem_worker::wire::LightroomSealedDocumentPage (engines/catalog/src/filesystem_worker/wire.rs:335).
nonisolated struct LWFilesystemWorkerWireLightroomSealedDocumentPage: Codable, Sendable {
    var session: String
    var directory: LWCatalogNativePath
    var path: LWCatalogNativePath
    var document: LWFilesystemWorkerWireLightroomSealedDocument
    var physical: LWCatalogSessionPhysicalObjectId
    var total_bytes: LWCatalogU64
    var blake3: String
    var offset: LWCatalogU64
    var next: LWCatalogU64?
    var bytes: [UInt8]
    init(session: String, directory: LWCatalogNativePath, path: LWCatalogNativePath, document: LWFilesystemWorkerWireLightroomSealedDocument, physical: LWCatalogSessionPhysicalObjectId, total_bytes: LWCatalogU64, blake3: String, offset: LWCatalogU64, next: LWCatalogU64?, bytes: [UInt8]) {
        self.session = session
        self.directory = directory
        self.path = path
        self.document = document
        self.physical = physical
        self.total_bytes = total_bytes
        self.blake3 = blake3
        self.offset = offset
        self.next = next
        self.bytes = bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["session", "directory", "path", "document", "physical", "total_bytes", "blake3", "offset", "next", "bytes"])
        self.session = try container.decode(String.self, forKey: LWCatalogCodingKey("session"))
        self.directory = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory"))
        self.path = try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path"))
        self.document = try container.decode(LWFilesystemWorkerWireLightroomSealedDocument.self, forKey: LWCatalogCodingKey("document"))
        self.physical = try container.decode(LWCatalogSessionPhysicalObjectId.self, forKey: LWCatalogCodingKey("physical"))
        self.total_bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("total_bytes"))
        self.blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("blake3"))
        self.offset = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset"))
        self.next = try container.decodeIfPresent(LWCatalogU64.self, forKey: LWCatalogCodingKey("next"))
        self.bytes = try container.decode([UInt8].self, forKey: LWCatalogCodingKey("bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(session, forKey: LWCatalogCodingKey("session"))
        try container.encode(directory, forKey: LWCatalogCodingKey("directory"))
        try container.encode(path, forKey: LWCatalogCodingKey("path"))
        try container.encode(document, forKey: LWCatalogCodingKey("document"))
        try container.encode(physical, forKey: LWCatalogCodingKey("physical"))
        try container.encode(total_bytes, forKey: LWCatalogCodingKey("total_bytes"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
        try container.encode(offset, forKey: LWCatalogCodingKey("offset"))
        try container.encode(next, forKey: LWCatalogCodingKey("next"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
    }
}

/// filesystem_worker::wire::LightroomSealedRead (engines/catalog/src/filesystem_worker/wire.rs:287).
nonisolated indirect enum LWFilesystemWorkerWireLightroomSealedRead: Codable, Sendable {
    case Begin(session: String, directory: LWCatalogNativePath, document: LWFilesystemWorkerWireLightroomSealedDocument)
    case Page(session: String, offset: LWCatalogU64, limit: LWCatalogU64)
    case Discard(session: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("action"))
        switch discriminator {
        case "begin":
            try container.lwRequireKeys(["action", "session", "directory", "document"])
            self = .Begin(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")), directory: try container.decode(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("directory")), document: try container.decode(LWFilesystemWorkerWireLightroomSealedDocument.self, forKey: LWCatalogCodingKey("document")))
        case "page":
            try container.lwRequireKeys(["action", "session", "offset", "limit"])
            self = .Page(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")), offset: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("offset")), limit: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("limit")))
        case "discard":
            try container.lwRequireKeys(["action", "session"])
            self = .Discard(session: try container.decode(String.self, forKey: LWCatalogCodingKey("session")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWFilesystemWorkerWireLightroomSealedRead variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Begin(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("begin", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
            try container.encode(value1, forKey: LWCatalogCodingKey("directory"))
            try container.encode(value2, forKey: LWCatalogCodingKey("document"))
        case .Page(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("page", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
            try container.encode(value1, forKey: LWCatalogCodingKey("offset"))
            try container.encode(value2, forKey: LWCatalogCodingKey("limit"))
        case .Discard(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("discard", forKey: LWCatalogCodingKey("action"))
            try container.encode(value0, forKey: LWCatalogCodingKey("session"))
        }
    }
}

/// image_export::specification::AlphaPolicy (engines/catalog/src/image_export/specification.rs:43).
nonisolated indirect enum LWImageExportSpecificationAlphaPolicy: Codable, Sendable {
    case Preserve
    case Composite(linear_rgb: LWCatalogTriple<LWCatalogFloat32, LWCatalogFloat32, LWCatalogFloat32>)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("mode"))
        switch discriminator {
        case "preserve":
            try container.lwRequireKeys(["mode"])
            self = .Preserve
        case "composite":
            try container.lwRequireKeys(["mode", "linear_rgb"])
            self = .Composite(linear_rgb: try container.decode(LWCatalogTriple<LWCatalogFloat32, LWCatalogFloat32, LWCatalogFloat32>.self, forKey: LWCatalogCodingKey("linear_rgb")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWImageExportSpecificationAlphaPolicy variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Preserve:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("preserve", forKey: LWCatalogCodingKey("mode"))
        case .Composite(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("composite", forKey: LWCatalogCodingKey("mode"))
            try container.encode(value0, forKey: LWCatalogCodingKey("linear_rgb"))
        }
    }
}

/// image_export::specification::IntegerDepth (engines/catalog/src/image_export/specification.rs:6).
nonisolated enum LWImageExportSpecificationIntegerDepth: String, Codable, Sendable {
    case Eight = "eight"
    case Sixteen = "sixteen"
}

/// image_export::specification::OutputFormat (engines/catalog/src/image_export/specification.rs:19).
nonisolated indirect enum LWImageExportSpecificationOutputFormat: Codable, Sendable {
    case Jpeg(quality: UInt8)
    case Png(depth: LWImageExportSpecificationIntegerDepth)
    case Tiff(depth: LWImageExportSpecificationTiffDepth)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("format"))
        switch discriminator {
        case "jpeg":
            try container.lwRequireKeys(["format", "quality"])
            self = .Jpeg(quality: try container.decode(UInt8.self, forKey: LWCatalogCodingKey("quality")))
        case "png":
            try container.lwRequireKeys(["format", "depth"])
            self = .Png(depth: try container.decode(LWImageExportSpecificationIntegerDepth.self, forKey: LWCatalogCodingKey("depth")))
        case "tiff":
            try container.lwRequireKeys(["format", "depth"])
            self = .Tiff(depth: try container.decode(LWImageExportSpecificationTiffDepth.self, forKey: LWCatalogCodingKey("depth")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWImageExportSpecificationOutputFormat variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Jpeg(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("jpeg", forKey: LWCatalogCodingKey("format"))
            try container.encode(value0, forKey: LWCatalogCodingKey("quality"))
        case .Png(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("png", forKey: LWCatalogCodingKey("format"))
            try container.encode(value0, forKey: LWCatalogCodingKey("depth"))
        case .Tiff(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("tiff", forKey: LWCatalogCodingKey("format"))
            try container.encode(value0, forKey: LWCatalogCodingKey("depth"))
        }
    }
}

/// image_export::specification::OutputSize (engines/catalog/src/image_export/specification.rs:26).
nonisolated indirect enum LWImageExportSpecificationOutputSize: Codable, Sendable {
    case Original
    case Fit(width: UInt32, height: UInt32, allow_upscale: Bool)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("mode"))
        switch discriminator {
        case "original":
            try container.lwRequireKeys(["mode"])
            self = .Original
        case "fit":
            try container.lwRequireKeys(["mode", "width", "height", "allow_upscale"])
            self = .Fit(width: try container.decode(UInt32.self, forKey: LWCatalogCodingKey("width")), height: try container.decode(UInt32.self, forKey: LWCatalogCodingKey("height")), allow_upscale: try container.decode(Bool.self, forKey: LWCatalogCodingKey("allow_upscale")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWImageExportSpecificationOutputSize variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Original:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("original", forKey: LWCatalogCodingKey("mode"))
        case .Fit(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("fit", forKey: LWCatalogCodingKey("mode"))
            try container.encode(value0, forKey: LWCatalogCodingKey("width"))
            try container.encode(value1, forKey: LWCatalogCodingKey("height"))
            try container.encode(value2, forKey: LWCatalogCodingKey("allow_upscale"))
        }
    }
}

/// image_export::specification::TiffDepth (engines/catalog/src/image_export/specification.rs:12).
nonisolated enum LWImageExportSpecificationTiffDepth: String, Codable, Sendable {
    case Eight = "eight"
    case Sixteen = "sixteen"
    case Float32 = "float32"
}

/// lightroom::adobe::Disposition (engines/catalog/src/lightroom/adobe.rs:159).
nonisolated enum LWLightroomAdobeDisposition: String, Codable, Sendable {
    case MappedParameter = "mapped_parameter"
    case RetainedOnly = "retained_only"
    case Invalid = "invalid"
    case Conflict = "conflict"
}

/// lightroom::adobe::Failure (engines/catalog/src/lightroom/adobe.rs:187).
nonisolated struct LWLightroomAdobeFailure: Codable, Sendable {
    var kind: LWLightroomAdobeFailureKind
    var message: String
    init(kind: LWLightroomAdobeFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.kind = try container.decode(LWLightroomAdobeFailureKind.self, forKey: LWCatalogCodingKey("kind"))
        self.message = try container.decode(String.self, forKey: LWCatalogCodingKey("message"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(message, forKey: LWCatalogCodingKey("message"))
    }
}

/// lightroom::adobe::FailureKind (engines/catalog/src/lightroom/adobe.rs:181).
nonisolated enum LWLightroomAdobeFailureKind: String, Codable, Sendable {
    case ResourceLimit = "resource_limit"
    case InvalidSyntax = "invalid_syntax"
    case Conflict = "conflict"
}

/// lightroom::plan::Cell (engines/catalog/src/lightroom/plan.rs:97).
nonisolated indirect enum LWLightroomPlanCell: Codable, Sendable {
    case Null
    case Integer(Int64)
    case RealBits(UInt64)
    case Text(LWCatalogHexBytes)
    case Blob(LWCatalogHexBytes)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("type"))
        switch discriminator {
        case "Null":
            self = .Null
        case "Integer":
            self = .Integer(try container.decode(Int64.self, forKey: LWCatalogCodingKey("value")))
        case "RealBits":
            self = .RealBits(try container.decode(UInt64.self, forKey: LWCatalogCodingKey("value")))
        case "Text":
            self = .Text(try container.decode(LWCatalogHexBytes.self, forKey: LWCatalogCodingKey("value")))
        case "Blob":
            self = .Blob(try container.decode(LWCatalogHexBytes.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWLightroomPlanCell variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Null:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Null", forKey: LWCatalogCodingKey("type"))
        case .Integer(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Integer", forKey: LWCatalogCodingKey("type"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .RealBits(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("RealBits", forKey: LWCatalogCodingKey("type"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Text(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Text", forKey: LWCatalogCodingKey("type"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Blob(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Blob", forKey: LWCatalogCodingKey("type"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// lightroom::plan::selection::preparation::PreparationDocument (engines/catalog/src/lightroom/plan/selection/preparation.rs:11).
nonisolated indirect enum LWLightroomPlanSelectionPreparationPreparationDocument: Codable, Sendable {
    case Manifest(revision: String)
    case OriginalEvidence(revision: String, source_id: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("kind"))
        switch discriminator {
        case "Manifest":
            try container.lwRequireKeys(["kind", "revision"])
            self = .Manifest(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")))
        case "OriginalEvidence":
            try container.lwRequireKeys(["kind", "revision", "source_id"])
            self = .OriginalEvidence(revision: try container.decode(String.self, forKey: LWCatalogCodingKey("revision")), source_id: try container.decode(String.self, forKey: LWCatalogCodingKey("source_id")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWLightroomPlanSelectionPreparationPreparationDocument variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Manifest(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("Manifest", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
        case .OriginalEvidence(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("OriginalEvidence", forKey: LWCatalogCodingKey("kind"))
            try container.encode(value0, forKey: LWCatalogCodingKey("revision"))
            try container.encode(value1, forKey: LWCatalogCodingKey("source_id"))
        }
    }
}

/// lightroom_migration_worker::input::PartDescriptor (engines/catalog/src/lightroom_migration_worker/input.rs:49).
nonisolated struct LWLightroomMigrationWorkerInputPartDescriptor: Codable, Sendable {
    var role: LWLightroomMigrationWorkerProtocolInputRole
    var bytes: LWCatalogU64
    var blake3: String
    init(role: LWLightroomMigrationWorkerProtocolInputRole, bytes: LWCatalogU64, blake3: String) {
        self.role = role
        self.bytes = bytes
        self.blake3 = blake3
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["role", "bytes", "blake3"])
        self.role = try container.decode(LWLightroomMigrationWorkerProtocolInputRole.self, forKey: LWCatalogCodingKey("role"))
        self.bytes = try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("bytes"))
        self.blake3 = try container.decode(String.self, forKey: LWCatalogCodingKey("blake3"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(role, forKey: LWCatalogCodingKey("role"))
        try container.encode(bytes, forKey: LWCatalogCodingKey("bytes"))
        try container.encode(blake3, forKey: LWCatalogCodingKey("blake3"))
    }
}

/// lightroom_migration_worker::protocol::Guard (engines/catalog/src/lightroom_migration_worker/protocol.rs:33).
nonisolated struct LWLightroomMigrationWorkerProtocolGuard: Codable, Sendable {
    var session: String
    var generation: String
    var operation: String
    init(session: String, generation: String, operation: String) {
        self.session = session
        self.generation = generation
        self.operation = operation
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.lwRequireKeys(["session", "generation", "operation"])
        self.session = try container.decode(String.self, forKey: LWCatalogCodingKey("session"))
        self.generation = try container.decode(String.self, forKey: LWCatalogCodingKey("generation"))
        self.operation = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(session, forKey: LWCatalogCodingKey("session"))
        try container.encode(generation, forKey: LWCatalogCodingKey("generation"))
        try container.encode(operation, forKey: LWCatalogCodingKey("operation"))
    }
}

/// lightroom_migration_worker::protocol::InputRole (engines/catalog/src/lightroom_migration_worker/protocol.rs:22).
nonisolated enum LWLightroomMigrationWorkerProtocolInputRole: String, Codable, Sendable {
    case Operation = "operation"
    case Seal = "seal"
    case Approval = "approval"
    case Policy = "policy"
    case RepairRequest = "repair_request"
    case SupplementRequests = "supplement_requests"
    case ExecutionAuthorization = "execution_authorization"
}

/// lightroom_migration_worker::worker::Operation (engines/catalog/src/lightroom_migration_worker/worker.rs:66).
nonisolated indirect enum LWLightroomMigrationWorkerWorkerOperation: Codable, Sendable {
    case Run(approval_blake3: String, max_steps: LWCatalogU64, max_seconds: LWCatalogU64, source_open_ms: LWCatalogU64, artifact_open_ms: LWCatalogU64, max_artifact_bytes: LWCatalogU64)
    case Status(run: String)
    case PrepareSupplements
    case RepairCurrent(max_steps: LWCatalogU64, max_seconds: LWCatalogU64, source_open_ms: LWCatalogU64)
    case RepairStatus(repair: String)
    case RepairKeywords(max_steps: LWCatalogU64, max_seconds: LWCatalogU64, source_open_ms: LWCatalogU64)
    case KeywordRepairStatus(repair: String)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        switch discriminator {
        case "run":
            try container.lwRequireKeys(["operation", "approval_blake3", "max_steps", "max_seconds", "source_open_ms", "artifact_open_ms", "max_artifact_bytes"])
            self = .Run(approval_blake3: try container.decode(String.self, forKey: LWCatalogCodingKey("approval_blake3")), max_steps: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_steps")), max_seconds: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_seconds")), source_open_ms: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("source_open_ms")), artifact_open_ms: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("artifact_open_ms")), max_artifact_bytes: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_artifact_bytes")))
        case "status":
            try container.lwRequireKeys(["operation", "run"])
            self = .Status(run: try container.decode(String.self, forKey: LWCatalogCodingKey("run")))
        case "prepare_supplements":
            try container.lwRequireKeys(["operation"])
            self = .PrepareSupplements
        case "repair_current":
            try container.lwRequireKeys(["operation", "max_steps", "max_seconds", "source_open_ms"])
            self = .RepairCurrent(max_steps: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_steps")), max_seconds: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_seconds")), source_open_ms: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("source_open_ms")))
        case "repair_status":
            try container.lwRequireKeys(["operation", "repair"])
            self = .RepairStatus(repair: try container.decode(String.self, forKey: LWCatalogCodingKey("repair")))
        case "repair_keywords":
            try container.lwRequireKeys(["operation", "max_steps", "max_seconds", "source_open_ms"])
            self = .RepairKeywords(max_steps: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_steps")), max_seconds: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("max_seconds")), source_open_ms: try container.decode(LWCatalogU64.self, forKey: LWCatalogCodingKey("source_open_ms")))
        case "keyword_repair_status":
            try container.lwRequireKeys(["operation", "repair"])
            self = .KeywordRepairStatus(repair: try container.decode(String.self, forKey: LWCatalogCodingKey("repair")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWLightroomMigrationWorkerWorkerOperation variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Run(let value0, let value1, let value2, let value3, let value4, let value5):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("run", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("approval_blake3"))
            try container.encode(value1, forKey: LWCatalogCodingKey("max_steps"))
            try container.encode(value2, forKey: LWCatalogCodingKey("max_seconds"))
            try container.encode(value3, forKey: LWCatalogCodingKey("source_open_ms"))
            try container.encode(value4, forKey: LWCatalogCodingKey("artifact_open_ms"))
            try container.encode(value5, forKey: LWCatalogCodingKey("max_artifact_bytes"))
        case .Status(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("status", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("run"))
        case .PrepareSupplements:
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("prepare_supplements", forKey: LWCatalogCodingKey("operation"))
        case .RepairCurrent(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("repair_current", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("max_steps"))
            try container.encode(value1, forKey: LWCatalogCodingKey("max_seconds"))
            try container.encode(value2, forKey: LWCatalogCodingKey("source_open_ms"))
        case .RepairStatus(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("repair_status", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("repair"))
        case .RepairKeywords(let value0, let value1, let value2):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("repair_keywords", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("max_steps"))
            try container.encode(value1, forKey: LWCatalogCodingKey("max_seconds"))
            try container.encode(value2, forKey: LWCatalogCodingKey("source_open_ms"))
        case .KeywordRepairStatus(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("keyword_repair_status", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("repair"))
        }
    }
}

/// media::Metadata (engines/catalog/src/media.rs:19).
nonisolated struct LWMediaMetadata: Codable, Sendable {
    var format: String
    var width: UInt32
    var height: UInt32
    var orientation: UInt32
    var camera_make: String?
    var camera_model: String?
    var captured_at: String?
    var lens: String?
    var preview_source: String
    init(format: String, width: UInt32, height: UInt32, orientation: UInt32, camera_make: String?, camera_model: String?, captured_at: String?, lens: String?, preview_source: String) {
        self.format = format
        self.width = width
        self.height = height
        self.orientation = orientation
        self.camera_make = camera_make
        self.camera_model = camera_model
        self.captured_at = captured_at
        self.lens = lens
        self.preview_source = preview_source
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.format = try container.decode(String.self, forKey: LWCatalogCodingKey("format"))
        self.width = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("width"))
        self.height = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("height"))
        self.orientation = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("orientation"))
        self.camera_make = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("camera_make"))
        self.camera_model = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("camera_model"))
        self.captured_at = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("captured_at"))
        self.lens = try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("lens"))
        self.preview_source = try container.decode(String.self, forKey: LWCatalogCodingKey("preview_source"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(format, forKey: LWCatalogCodingKey("format"))
        try container.encode(width, forKey: LWCatalogCodingKey("width"))
        try container.encode(height, forKey: LWCatalogCodingKey("height"))
        try container.encode(orientation, forKey: LWCatalogCodingKey("orientation"))
        try container.encode(camera_make, forKey: LWCatalogCodingKey("camera_make"))
        try container.encode(camera_model, forKey: LWCatalogCodingKey("camera_model"))
        try container.encode(captured_at, forKey: LWCatalogCodingKey("captured_at"))
        try container.encode(lens, forKey: LWCatalogCodingKey("lens"))
        try container.encode(preview_source, forKey: LWCatalogCodingKey("preview_source"))
    }
}

/// media::full::ColorCalibration (engines/catalog/src/media/full.rs:95).
nonisolated struct LWMediaFullColorCalibration: Codable, Sendable {
    var table: String
    var applied_pixels: UInt64
    var bypassed_pixels: UInt64
    var domain_policy: String
    init(table: String, applied_pixels: UInt64, bypassed_pixels: UInt64, domain_policy: String) {
        self.table = table
        self.applied_pixels = applied_pixels
        self.bypassed_pixels = bypassed_pixels
        self.domain_policy = domain_policy
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.table = try container.decode(String.self, forKey: LWCatalogCodingKey("table"))
        self.applied_pixels = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("applied_pixels"))
        self.bypassed_pixels = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("bypassed_pixels"))
        self.domain_policy = try container.decode(String.self, forKey: LWCatalogCodingKey("domain_policy"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(table, forKey: LWCatalogCodingKey("table"))
        try container.encode(applied_pixels, forKey: LWCatalogCodingKey("applied_pixels"))
        try container.encode(bypassed_pixels, forKey: LWCatalogCodingKey("bypassed_pixels"))
        try container.encode(domain_policy, forKey: LWCatalogCodingKey("domain_policy"))
    }
}

/// media::full::DecodeLimits (engines/catalog/src/media/full.rs:21).
nonisolated struct LWMediaFullDecodeLimits: Codable, Sendable {
    var max_encoded_bytes: UInt64
    var max_intermediate_pixels: UInt64
    var max_allocation_bytes: UInt64
    init(max_encoded_bytes: UInt64, max_intermediate_pixels: UInt64, max_allocation_bytes: UInt64) {
        self.max_encoded_bytes = max_encoded_bytes
        self.max_intermediate_pixels = max_intermediate_pixels
        self.max_allocation_bytes = max_allocation_bytes
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.max_encoded_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("max_encoded_bytes"))
        self.max_intermediate_pixels = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("max_intermediate_pixels"))
        self.max_allocation_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("max_allocation_bytes"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(max_encoded_bytes, forKey: LWCatalogCodingKey("max_encoded_bytes"))
        try container.encode(max_intermediate_pixels, forKey: LWCatalogCodingKey("max_intermediate_pixels"))
        try container.encode(max_allocation_bytes, forKey: LWCatalogCodingKey("max_allocation_bytes"))
    }
}

/// media::full::DecodeStatus (engines/catalog/src/media/full.rs:69).
nonisolated enum LWMediaFullDecodeStatus: String, Codable, Sendable {
    case Unsupported = "unsupported"
    case Corrupt = "corrupt"
    case ResourceLimit = "resource_limit"
    case Io = "io"
}

/// media::full::RenderProvenance (engines/catalog/src/media/full.rs:102).
nonisolated struct LWMediaFullRenderProvenance: Codable, Sendable {
    var pipeline_version: String
    var decoder: String
    var source_bits_per_channel: UInt32
    var source_color: String
    var working_color: String
    var alpha: String
    var calibration: LWMediaFullColorCalibration?
    var spatial_calibration: LWMediaFullColorCalibration?
    var notes: [String]
    var neutral_clip: LWCatalogTriple<LWCatalogFloat32,LWCatalogFloat32,LWCatalogFloat32>?
    init(pipeline_version: String, decoder: String, source_bits_per_channel: UInt32, source_color: String, working_color: String, alpha: String, calibration: LWMediaFullColorCalibration?, spatial_calibration: LWMediaFullColorCalibration?, notes: [String], neutral_clip: LWCatalogTriple<LWCatalogFloat32,LWCatalogFloat32,LWCatalogFloat32>? = nil) {
        self.pipeline_version = pipeline_version
        self.decoder = decoder
        self.source_bits_per_channel = source_bits_per_channel
        self.source_color = source_color
        self.working_color = working_color
        self.alpha = alpha
        self.calibration = calibration
        self.spatial_calibration = spatial_calibration
        self.notes = notes
        self.neutral_clip = neutral_clip
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.pipeline_version = try container.decode(String.self, forKey: LWCatalogCodingKey("pipeline_version"))
        self.decoder = try container.decode(String.self, forKey: LWCatalogCodingKey("decoder"))
        self.source_bits_per_channel = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("source_bits_per_channel"))
        self.source_color = try container.decode(String.self, forKey: LWCatalogCodingKey("source_color"))
        self.working_color = try container.decode(String.self, forKey: LWCatalogCodingKey("working_color"))
        self.alpha = try container.decode(String.self, forKey: LWCatalogCodingKey("alpha"))
        self.calibration = try container.decodeIfPresent(LWMediaFullColorCalibration.self, forKey: LWCatalogCodingKey("calibration"))
        self.spatial_calibration = try container.decodeIfPresent(LWMediaFullColorCalibration.self, forKey: LWCatalogCodingKey("spatial_calibration"))
        self.notes = try container.decode([String].self, forKey: LWCatalogCodingKey("notes"))
        self.neutral_clip = try container.decodeIfPresent(LWCatalogTriple<LWCatalogFloat32,LWCatalogFloat32,LWCatalogFloat32>.self, forKey: LWCatalogCodingKey("neutral_clip"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(pipeline_version, forKey: LWCatalogCodingKey("pipeline_version"))
        try container.encode(decoder, forKey: LWCatalogCodingKey("decoder"))
        try container.encode(source_bits_per_channel, forKey: LWCatalogCodingKey("source_bits_per_channel"))
        try container.encode(source_color, forKey: LWCatalogCodingKey("source_color"))
        try container.encode(working_color, forKey: LWCatalogCodingKey("working_color"))
        try container.encode(alpha, forKey: LWCatalogCodingKey("alpha"))
        try container.encode(calibration, forKey: LWCatalogCodingKey("calibration"))
        try container.encode(spatial_calibration, forKey: LWCatalogCodingKey("spatial_calibration"))
        try container.encode(notes, forKey: LWCatalogCodingKey("notes"))
        try container.encodeIfPresent(neutral_clip, forKey: LWCatalogCodingKey("neutral_clip"))
    }
}

/// organization::Flag (engines/catalog/src/organization.rs:74).
nonisolated enum LWOrganizationFlag: String, Codable, Sendable {
    case Unflagged = "unflagged"
    case Pick = "pick"
    case Reject = "reject"
}

/// organization::KeywordKind (engines/catalog/src/organization.rs:60).
nonisolated enum LWOrganizationKeywordKind: String, Codable, Sendable {
    case Flat = "flat"
    case Hierarchical = "hierarchical"
}

/// organization::Operation (engines/catalog/src/organization.rs:119).
nonisolated indirect enum LWOrganizationOperation: Codable, Sendable {
    case Rating(value: UInt8)
    case Label(value: String)
    case Flag(value: LWOrganizationFlag)
    case AddKeyword(kind: LWOrganizationKeywordKind, path: [String])
    case RemoveKeyword(kind: LWOrganizationKeywordKind, path: [String])
    case MoveKeyword(from: [String], to: [String])
    case AddCollection(collection: String)
    case RemoveCollection(collection: String)
    case RestoreRating(value: String?)
    case RestoreLabel(value: String?)
    case RestoreFlag(value: LWOrganizationFlag?)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let discriminator = try container.decode(String.self, forKey: LWCatalogCodingKey("operation"))
        switch discriminator {
        case "rating":
            self = .Rating(value: try container.decode(UInt8.self, forKey: LWCatalogCodingKey("value")))
        case "label":
            self = .Label(value: try container.decode(String.self, forKey: LWCatalogCodingKey("value")))
        case "flag":
            self = .Flag(value: try container.decode(LWOrganizationFlag.self, forKey: LWCatalogCodingKey("value")))
        case "add_keyword":
            self = .AddKeyword(kind: try container.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind")), path: try container.decode([String].self, forKey: LWCatalogCodingKey("path")))
        case "remove_keyword":
            self = .RemoveKeyword(kind: try container.decode(LWOrganizationKeywordKind.self, forKey: LWCatalogCodingKey("kind")), path: try container.decode([String].self, forKey: LWCatalogCodingKey("path")))
        case "move_keyword":
            self = .MoveKeyword(from: try container.decode([String].self, forKey: LWCatalogCodingKey("from")), to: try container.decode([String].self, forKey: LWCatalogCodingKey("to")))
        case "add_collection":
            self = .AddCollection(collection: try container.decode(String.self, forKey: LWCatalogCodingKey("collection")))
        case "remove_collection":
            self = .RemoveCollection(collection: try container.decode(String.self, forKey: LWCatalogCodingKey("collection")))
        case "restore_rating":
            self = .RestoreRating(value: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("value")))
        case "restore_label":
            self = .RestoreLabel(value: try container.decodeIfPresent(String.self, forKey: LWCatalogCodingKey("value")))
        case "restore_flag":
            self = .RestoreFlag(value: try container.decodeIfPresent(LWOrganizationFlag.self, forKey: LWCatalogCodingKey("value")))
        default: throw LensWorksManagedError.protocolViolation("Unknown LWOrganizationOperation variant.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .Rating(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("rating", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Label(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("label", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .Flag(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("flag", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .AddKeyword(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("add_keyword", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("kind"))
            try container.encode(value1, forKey: LWCatalogCodingKey("path"))
        case .RemoveKeyword(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("remove_keyword", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("kind"))
            try container.encode(value1, forKey: LWCatalogCodingKey("path"))
        case .MoveKeyword(let value0, let value1):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("move_keyword", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("from"))
            try container.encode(value1, forKey: LWCatalogCodingKey("to"))
        case .AddCollection(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("add_collection", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("collection"))
        case .RemoveCollection(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("remove_collection", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("collection"))
        case .RestoreRating(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore_rating", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .RestoreLabel(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore_label", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        case .RestoreFlag(let value0):
            var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
            try container.encode("restore_flag", forKey: LWCatalogCodingKey("operation"))
            try container.encode(value0, forKey: LWCatalogCodingKey("value"))
        }
    }
}

/// organization_search::Direction (engines/catalog/src/organization_search.rs:32).
nonisolated enum LWOrganizationSearchDirection: String, Codable, Sendable {
    case Ascending = "ascending"
    case Descending = "descending"
}

/// organization_search::Sort (engines/catalog/src/organization_search.rs:23).
nonisolated enum LWOrganizationSearchSort: String, Codable, Sendable {
    case Sequence = "sequence"
    case Capture = "capture"
    case Filename = "filename"
    case Rating = "rating"
}

/// preview::codec::Codec (engines/catalog/src/preview/codec.rs:16).
nonisolated enum LWPreviewCodecCodec: String, Codable, Sendable {
    case Jpeg = "jpeg"
    case Webp = "webp"
    case Avif = "avif"
}

/// preview::codec::CodecSettings (engines/catalog/src/preview/codec.rs:31).
nonisolated struct LWPreviewCodecCodecSettings: Codable, Sendable {
    var codec: LWPreviewCodecCodec
    var quality: UInt8
    init(codec: LWPreviewCodecCodec, quality: UInt8) {
        self.codec = codec
        self.quality = quality
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.codec = try container.decode(LWPreviewCodecCodec.self, forKey: LWCatalogCodingKey("codec"))
        self.quality = try container.decode(UInt8.self, forKey: LWCatalogCodingKey("quality"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(codec, forKey: LWCatalogCodingKey("codec"))
        try container.encode(quality, forKey: LWCatalogCodingKey("quality"))
    }
}

/// preview::service::PreviewPolicy (engines/catalog/src/preview/service.rs:33).
nonisolated struct LWPreviewServicePreviewPolicy: Codable, Sendable {
    var thumbnail: LWPreviewServiceTierPolicy
    var large: LWPreviewServiceTierPolicy
    init(thumbnail: LWPreviewServiceTierPolicy, large: LWPreviewServiceTierPolicy) {
        self.thumbnail = thumbnail
        self.large = large
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.thumbnail = try container.decode(LWPreviewServiceTierPolicy.self, forKey: LWCatalogCodingKey("thumbnail"))
        self.large = try container.decode(LWPreviewServiceTierPolicy.self, forKey: LWCatalogCodingKey("large"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(thumbnail, forKey: LWCatalogCodingKey("thumbnail"))
        try container.encode(large, forKey: LWCatalogCodingKey("large"))
    }
}

/// preview::service::ServiceLimits (engines/catalog/src/preview/service.rs:56).
nonisolated struct LWPreviewServiceServiceLimits: Codable, Sendable {
    var requests: UInt
    var workers: UInt
    var working_bytes: UInt64
    var per_worker_bytes: UInt64
    var cache_header_scratch_bytes: UInt64
    var cache_codec_scratch_bytes: UInt64
    var decode_limits: LWMediaFullDecodeLimits
    var encoded_staging_bytes: UInt64
    var per_worker_encoded_bytes: UInt64
    var decoded_cache_bytes: UInt64
    var decoded_live_bytes: UInt64
    var decoded_entries: UInt
    var prepared_cache_bytes: UInt64
    var prepared_cache_entries: UInt
    init(requests: UInt, workers: UInt, working_bytes: UInt64, per_worker_bytes: UInt64, cache_header_scratch_bytes: UInt64, cache_codec_scratch_bytes: UInt64, decode_limits: LWMediaFullDecodeLimits, encoded_staging_bytes: UInt64, per_worker_encoded_bytes: UInt64, decoded_cache_bytes: UInt64, decoded_live_bytes: UInt64, decoded_entries: UInt, prepared_cache_bytes: UInt64, prepared_cache_entries: UInt) {
        self.requests = requests
        self.workers = workers
        self.working_bytes = working_bytes
        self.per_worker_bytes = per_worker_bytes
        self.cache_header_scratch_bytes = cache_header_scratch_bytes
        self.cache_codec_scratch_bytes = cache_codec_scratch_bytes
        self.decode_limits = decode_limits
        self.encoded_staging_bytes = encoded_staging_bytes
        self.per_worker_encoded_bytes = per_worker_encoded_bytes
        self.decoded_cache_bytes = decoded_cache_bytes
        self.decoded_live_bytes = decoded_live_bytes
        self.decoded_entries = decoded_entries
        self.prepared_cache_bytes = prepared_cache_bytes
        self.prepared_cache_entries = prepared_cache_entries
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.requests = try container.decode(UInt.self, forKey: LWCatalogCodingKey("requests"))
        self.workers = try container.decode(UInt.self, forKey: LWCatalogCodingKey("workers"))
        self.working_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("working_bytes"))
        self.per_worker_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("per_worker_bytes"))
        self.cache_header_scratch_bytes = try container.decodeIfPresent(UInt64.self, forKey: LWCatalogCodingKey("cache_header_scratch_bytes")) ?? 1048576
        self.cache_codec_scratch_bytes = try container.decodeIfPresent(UInt64.self, forKey: LWCatalogCodingKey("cache_codec_scratch_bytes")) ?? 8388608
        self.decode_limits = try container.decode(LWMediaFullDecodeLimits.self, forKey: LWCatalogCodingKey("decode_limits"))
        self.encoded_staging_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("encoded_staging_bytes"))
        self.per_worker_encoded_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("per_worker_encoded_bytes"))
        self.decoded_cache_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("decoded_cache_bytes"))
        self.decoded_live_bytes = try container.decode(UInt64.self, forKey: LWCatalogCodingKey("decoded_live_bytes"))
        self.decoded_entries = try container.decode(UInt.self, forKey: LWCatalogCodingKey("decoded_entries"))
        self.prepared_cache_bytes = try container.decodeIfPresent(UInt64.self, forKey: LWCatalogCodingKey("prepared_cache_bytes")) ?? 268435456
        self.prepared_cache_entries = try container.decodeIfPresent(UInt.self, forKey: LWCatalogCodingKey("prepared_cache_entries")) ?? 16
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(requests, forKey: LWCatalogCodingKey("requests"))
        try container.encode(workers, forKey: LWCatalogCodingKey("workers"))
        try container.encode(working_bytes, forKey: LWCatalogCodingKey("working_bytes"))
        try container.encode(per_worker_bytes, forKey: LWCatalogCodingKey("per_worker_bytes"))
        try container.encode(cache_header_scratch_bytes, forKey: LWCatalogCodingKey("cache_header_scratch_bytes"))
        try container.encode(cache_codec_scratch_bytes, forKey: LWCatalogCodingKey("cache_codec_scratch_bytes"))
        try container.encode(decode_limits, forKey: LWCatalogCodingKey("decode_limits"))
        try container.encode(encoded_staging_bytes, forKey: LWCatalogCodingKey("encoded_staging_bytes"))
        try container.encode(per_worker_encoded_bytes, forKey: LWCatalogCodingKey("per_worker_encoded_bytes"))
        try container.encode(decoded_cache_bytes, forKey: LWCatalogCodingKey("decoded_cache_bytes"))
        try container.encode(decoded_live_bytes, forKey: LWCatalogCodingKey("decoded_live_bytes"))
        try container.encode(decoded_entries, forKey: LWCatalogCodingKey("decoded_entries"))
        try container.encode(prepared_cache_bytes, forKey: LWCatalogCodingKey("prepared_cache_bytes"))
        try container.encode(prepared_cache_entries, forKey: LWCatalogCodingKey("prepared_cache_entries"))
    }
}

/// preview::service::TierPolicy (engines/catalog/src/preview/service.rs:28).
nonisolated struct LWPreviewServiceTierPolicy: Codable, Sendable {
    var edge: UInt32
    var encoding: LWPreviewCodecCodecSettings
    init(edge: UInt32, encoding: LWPreviewCodecCodecSettings) {
        self.edge = edge
        self.encoding = encoding
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.edge = try container.decode(UInt32.self, forKey: LWCatalogCodingKey("edge"))
        self.encoding = try container.decode(LWPreviewCodecCodecSettings.self, forKey: LWCatalogCodingKey("encoding"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(edge, forKey: LWCatalogCodingKey("edge"))
        try container.encode(encoding, forKey: LWCatalogCodingKey("encoding"))
    }
}

/// preview::store::Tier (engines/catalog/src/preview/store.rs:26).
nonisolated enum LWPreviewStoreTier: String, Codable, Sendable {
    case Thumbnail = "thumbnail"
    case Large = "large"
}

/// storage_volume::IssueKind (engines/catalog/src/storage_volume.rs:99).
nonisolated enum LWStorageVolumeIssueKind: String, Codable, Sendable {
    case IdentityUnavailable = "IdentityUnavailable"
    case IdentityAmbiguous = "IdentityAmbiguous"
    case MappingUnavailable = "MappingUnavailable"
    case ObservationChanged = "ObservationChanged"
    case Inaccessible = "Inaccessible"
    case Malformed = "Malformed"
    case ResourceLimit = "ResourceLimit"
    case Unsupported = "Unsupported"
}

/// storage_volume::VolumeIssue (engines/catalog/src/storage_volume.rs:110).
nonisolated struct LWStorageVolumeVolumeIssue: Codable, Sendable {
    var kind: LWStorageVolumeIssueKind
    var path: LWCatalogNativePath?
    var detail: String
    init(kind: LWStorageVolumeIssueKind, path: LWCatalogNativePath?, detail: String) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        self.kind = try container.decode(LWStorageVolumeIssueKind.self, forKey: LWCatalogCodingKey("kind"))
        self.path = try container.decodeIfPresent(LWCatalogNativePath.self, forKey: LWCatalogCodingKey("path"))
        self.detail = try container.decode(String.self, forKey: LWCatalogCodingKey("detail"))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try container.encode(kind, forKey: LWCatalogCodingKey("kind"))
        try container.encode(path, forKey: LWCatalogCodingKey("path"))
        try container.encode(detail, forKey: LWCatalogCodingKey("detail"))
    }
}

typealias LWApplicationRequest = LWApplicationDtoRequest
typealias LWApplicationReply = LWApplicationDtoReply
typealias LWApplicationResponse = LWApplicationDtoResponse
