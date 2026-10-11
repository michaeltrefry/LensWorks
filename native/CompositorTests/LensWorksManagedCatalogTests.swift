import Foundation
import Darwin
import Testing
import CryptoKit
@testable import Compositor

@Suite(.serialized)
nonisolated struct LensWorksManagedCatalogTests {
    @Test func authorityIntegersAndNativePathsAreLossless() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for value in [Int64.min, -1, 0, Int64.max] {
            let encoded = try encoder.encode(LWCatalogI64(value))
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(value)\"")
            #expect(try decoder.decode(LWCatalogI64.self, from: encoded).value == value)
        }
        let unsigned = LWCatalogU64(UInt64.max)
        #expect(try decoder.decode(LWCatalogU64.self, from: encoder.encode(unsigned)).value == UInt64.max)
        for invalid in ["01", "+1", "-0", " 1", "18446744073709551616"] {
            #expect(throws: (any Error).self) { try LWCatalogU64(decimal: invalid) }
        }
        #expect(throws: (any Error).self) { try decoder.decode(LWCatalogU64.self, from: Data("9007199254740993".utf8)) }
        let value = try LWCatalogCodec.decode(LWCatalogJSON.self, from: Data(#"{"integer":1,"float":1.0,"exponent":1e0,"array":[1.0,18446744073709551615]}"#.utf8))
        guard case .object(let numbers) = value else { Issue.record("Expected arbitrary JSON object"); return }
        #expect(numbers["integer"] == .signed(1) && numbers["float"] == .number(1) && numbers["exponent"] == .number(1))
        #expect(try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(value)) == value)
        let special = try LWCatalogCodec.decode(LWCatalogJSON.self, from: Data(#"{"0":1.0,"escaped\/key":[-0.0,1e0,0.25,-9223372036854775808]}"#.utf8))
        #expect(try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(special)) == special)
        for malformed in ["1 trailing", "1e", "[1,]", "{\"a\":1} false"] {
            #expect(throws: (any Error).self) { try LWCatalogCodec.decode(LWCatalogJSON.self, from: Data(malformed.utf8)) }
        }
        let max128 = try LWCatalogU128(decimal: "340282366920938463463374607431768211455")
        #expect(try decoder.decode(LWCatalogU128.self, from: encoder.encode(max128)) == max128)
        #expect(throws: (any Error).self) { try LWCatalogU128(decimal: "340282366920938463463374607431768211456") }
        for path in [LWCatalogNativePath.unixBytes([47, 255, 254, 97]), .windowsWide([67, 58, 92, 0xD800, 0xFFFF])] {
            #expect(try decoder.decode(LWCatalogNativePath.self, from: encoder.encode(path)) == path)
        }
        #expect(throws: (any Error).self) { try LWCatalogNativePath.windowsWide([67, 58]).localFileURL() }
        let cell = try decoder.decode(LWLightroomPlanCell.self, from: Data(#"{"type":"Text","value":"00fF80"}"#.utf8))
        #expect(try decoder.decode(LWCatalogJSON.self, from: encoder.encode(cell)) == .object(["type": .string("Text"), "value": .string("00ff80")]))
        let options = try decoder.decode(LWApplicationBrowseOptions.self, from: Data("{}".utf8))
        #expect(options.keyword_direct == false && options.sort == .Sequence && options.direction == .Ascending)
        #expect(throws: (any Error).self) { try decoder.decode(LWApplicationRequest.self, from: Data(#"{"command":"status","unknown":true}"#.utf8)) }
    }

    @Test func fixedF32SerializesItsExactWidenedValue() throws {
        for (value, expected) in [(Float(0.1), "0.10000000149011612"), (Float(0.9), "0.8999999761581421")] {
            let bytes = try LWCatalogCodec.encode(LWCatalogFloat32(value))
            let retained = try LWCatalogCodec.decode(LWCatalogJSON.self, from: bytes)
            #expect(retained == .number(Double(value)))
            #expect(try retained == LWCatalogCodec.decode(LWCatalogJSON.self, from: Data(expected.utf8)))
            #expect(try LWCatalogCodec.decode(LWCatalogFloat32.self, from: bytes).value.bitPattern == value.bitPattern)
        }
        for value: Float in [0, -0.0, 1, Float.leastNonzeroMagnitude, Float.greatestFiniteMagnitude] {
            let bytes = try LWCatalogCodec.encode(LWCatalogFloat32(value))
            #expect(try LWCatalogCodec.decode(LWCatalogFloat32.self, from: bytes).value.bitPattern == value.bitPattern)
            guard case .number(let widened) = try LWCatalogCodec.decode(LWCatalogJSON.self, from: bytes) else { throw LensWorksManagedError.protocolViolation("Fixed f32 lost floating token kind.") }
            #expect(widened.bitPattern == Double(value).bitPattern)
        }
    }

    private func ownedCatalogAuthority(_ repository: URL) throws -> (digest: String, upstreamRevision: String) {
        struct Dependencies: Decodable {
            struct Catalog: Decodable { let revision: String, source: String, source_manifest: String, source_digest: String, upstream_snapshot_sha256: String }
            let PhotoCatalog: Catalog
        }
        struct Manifest: Decodable { let schema: Int, algorithm: String, source_digest: String, upstream_snapshot_sha256: String }
        struct Snapshot: Decodable { let schema: Int, revision: String }
        let dependencies = try JSONDecoder().decode(Dependencies.self, from: Data(contentsOf: repository.appendingPathComponent("DEPENDENCIES.json"))).PhotoCatalog
        guard dependencies.source == "engines/catalog", dependencies.source_manifest == "engines/catalog/SOURCE_PROVENANCE.json" else {
            throw LensWorksManagedError.protocolViolation("The catalog source ledger does not identify LensWorks-owned engine files.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: repository.appendingPathComponent(dependencies.source_manifest)))
        let snapshotBytes = try Data(contentsOf: repository.appendingPathComponent("engines/catalog/UPSTREAM_SNAPSHOT.json"))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: snapshotBytes)
        guard manifest.schema == 1, snapshot.schema == 1, manifest.algorithm == "sha256-canonical-file-ledger-v1",
              manifest.source_digest == dependencies.source_digest, manifest.source_digest == LWManagedAuthority.sourceRevision,
              manifest.source_digest.count == 64, manifest.source_digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              Self.mathSHA(snapshotBytes) == manifest.upstream_snapshot_sha256,
              manifest.upstream_snapshot_sha256 == dependencies.upstream_snapshot_sha256,
              snapshot.revision == dependencies.revision, snapshot.revision != manifest.source_digest else {
            throw LensWorksManagedError.protocolViolation("Owned runtime authority or distinct upstream snapshot provenance does not match the source ledger.")
        }
        return (manifest.source_digest, snapshot.revision)
    }
    @Test func managedSourceAndProtocolMatchApprovedDependencyLedger() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let authority = try ownedCatalogAuthority(root)
        #expect(LWManagedAuthority.sourceRevision == authority.digest)
        #expect(LWManagedAuthority.sourceRevision != authority.upstreamRevision)
        #expect(LWManagedAuthority.protocolVersion == 2)
        for revision in ["", "wrong-source", String(repeating: "0", count: 64), authority.upstreamRevision] {
            let data = try JSONEncoder().encode(["session": "1", "phase": "ready", "source_revision": revision])
            #expect(throws: LensWorksManagedError.self) { try LWCatalogCodec.decode(LWManagedSessionAdmission.self, from: data) }
        }
        // The old upstream commit is provenance only. It must never admit a runtime
        // owner/surface even when the protocol and geometry appear plausible.
        for (revision, version) in [(authority.digest, 1), (authority.digest, 3), (authority.upstreamRevision, 2), ("wrong-source", 2)] {
            let data = try JSONSerialization.data(withJSONObject: ["source_revision": revision, "protocol": version, "kind": "float", "mime": "application/x-lensworks-rgba-f32le", "width": 2, "height": 2])
            #expect(throws: LensWorksManagedError.self) { try LWCatalogCodec.decode(LWManagedFloatDescriptor.self, from: data) }
        }
    }

    @Test func retainedBlake3SealsExactBytesAndBoundsAdmission() async throws {
        #expect(try await LWManagedTransport.blake3(Data()) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
        #expect(try await LWManagedTransport.blake3(Data("[]".utf8)) == "d53d18c23212ea7b6300594bb89bce60218f6eff2b9d628b8cc42d3e79bbd5ab")
        let crossBound = Data(repeating: 0, count: 4 * 1024 * 1024 + 1)
        let expected = "fd62eab2af9cd2c561814fa8c53d0b26b5a898dbbe571ec57e6ec6684276e06a"
        #expect(try await LWManagedTransport.blake3(crossBound) == expected)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LWHash-\(UUID()).bin")
        try crossBound.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await LWManagedTransport.blake3(fileURL: file) == expected)
        await #expect(throws: (any Error).self) { try await LWManagedTransport.blake3(fileURL: file.appendingPathExtension("missing")) }
        try await LWManagedTransport.background {
            var output = [UInt8](repeating: 127, count: 32)
            let status = output.withUnsafeMutableBufferPointer { lw_catalog_blake3(nil, 1, $0.baseAddress) }
            #expect(status == 1 && output == [UInt8](repeating: 127, count: 32))
            var handle: UInt64 = 0
            #expect(lw_catalog_blake3_init(&handle) == 0 && handle != 0)
            defer { _ = lw_catalog_blake3_release(handle) }
            let bytes = Data("[]".utf8)
            #expect(bytes.withUnsafeBytes { lw_catalog_blake3_update(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == 0)
            #expect(output.withUnsafeMutableBufferPointer { lw_catalog_blake3_finalize(handle, $0.baseAddress) } == 0)
            #expect(output.map { String(format: "%02x", $0) }.joined() == "d53d18c23212ea7b6300594bb89bce60218f6eff2b9d628b8cc42d3e79bbd5ab")
            let digest = output
            #expect(output.withUnsafeMutableBufferPointer { lw_catalog_blake3_finalize(handle, $0.baseAddress) } == 6 && output == digest)
            #expect(lw_catalog_blake3_update(handle, nil, 0) == 6)
            #expect(lw_catalog_buffer_release(handle) == 4)
        }
        try await LWManagedTransport.background {
            var handle: UInt64 = 0
            #expect(lw_catalog_blake3_init(&handle) == 0)
            let bytes = Data(repeating: 0, count: 4 * 1024 * 1024 + 1)
            #expect(bytes.withUnsafeBytes { lw_catalog_blake3_update(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == 5)
            #expect(lw_catalog_blake3_update(handle, nil, 1) == 1)
            #expect(lw_catalog_blake3_release(handle) == 0)
            #expect(lw_catalog_blake3_release(handle) == 4 && lw_catalog_blake3_update(handle, nil, 0) == 4)
        }
        let canceled = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LWManagedTransport.blake3(Data("[]".utf8))
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        // Pre-canceled preparation must leave all sixteen context leases available.
        try await LWManagedTransport.background {
            var handles: [UInt64] = []
            defer { for handle in handles { _ = lw_catalog_blake3_release(handle) } }
            for _ in 0..<16 {
                var handle: UInt64 = 0
                let status = lw_catalog_blake3_init(&handle)
                #expect(status == 0 && handle != 0)
                if status == 0 { handles.append(handle) }
            }
            var overflow: UInt64 = 1
            #expect(lw_catalog_blake3_init(&overflow) == 2 && overflow == 0)
        }
        #expect(try await LWManagedTransport.blake3(Data("[]".utf8)) == "d53d18c23212ea7b6300594bb89bce60218f6eff2b9d628b8cc42d3e79bbd5ab")
    }

    @Test func actualABIErrorsAndBufferOwnership() async throws {
        try await LWManagedTransport.background {
            for text in ["", "{", #"{"version":1,"op":"session_status","session":"1"}"#, #"{"version":2,"op":"session_status","session":"01"}"#] {
                var handle: UInt64 = 0
                let bytes = Data(text.utf8)
                let status = bytes.withUnsafeBytes { lw_catalog_managed_request($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &handle) }
                #expect(status == 0)
                let buffer = try LWManagedBuffer(handle: LWCatalogBufferHandle(handle))
                let json = try JSONDecoder().decode(LWCatalogJSON.self, from: buffer.copySync(maximumBytes: 4096))
                guard case .object(let object) = json else { Issue.record("Expected typed failure envelope"); return }
                #expect(object["ok"] == .bool(false))
                var count = 100
                #expect(lw_catalog_buffer_copy(handle, 999999, nil, 0, &count) == 5)
                buffer.release(); buffer.release()
                #expect(lw_catalog_buffer_release(handle) == 4)
                #expect(throws: (any Error).self) { try buffer.copySync(maximumBytes: 4096) }
            }
            var untouched: UInt64 = 12345
            #expect(lw_catalog_managed_request(nil, 1, &untouched) == 1)
            #expect(untouched == 0)
        }
    }

    @Test func actualWorkerFamiliesCallbacksAndBufferSurvivesSession() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.removeIfClosed() }
        let session = fixture.session
        do {
        let notice = Notice()
        let subscription = try await session.subscribe { owner, job in notice.record(owner, job) }
        let identityReply = try await session.perform(.Metadata(catalog: fixture.catalog, request: .Identity(key: fixture.key)))
        guard case .Metadata(.Identity(let identity)) = identityReply else { throw unexpected("Metadata.Identity", identityReply) }
        let fieldsReply = try await session.perform(.Metadata(catalog: fixture.catalog, request: .Fields(identity: identity, after: nil, limit: 10)))
        guard case .Metadata(.Fields(let fields)) = fieldsReply else { throw unexpected("Metadata.Fields", fieldsReply) }
        #expect(fields.rows.count <= 10)
        let created = try await session.perform(.Organization(catalog: fixture.catalog, request: .CreateCollection(name: "Swift managed fixture")))
        guard case .Organization(.CollectionCreated(let collectionID)) = created else { throw unexpected("CollectionCreated", created) }
        let collectionReply = try await session.perform(.Organization(catalog: fixture.catalog, request: .Collection(id: collectionID)))
        guard case .Organization(.Collection(let collection)) = collectionReply, let collection else { throw unexpected("durable Collection", collectionReply) }
        #expect(collection.id == collectionID && collection.name == "Swift managed fixture")
        _ = try await session.perform(.Organization(catalog: fixture.catalog, request: .SetMember(identity: identity, collection: collection.id, position: LWCatalogI64(0))))
        let membersReply = try await session.perform(.Organization(catalog: fixture.catalog, request: .Members(collection: collection.id, after: nil, limit: 10)))
        guard case .Organization(.Members(let members)) = membersReply else { throw unexpected("Organization.Members", membersReply) }
        #expect(members.rows.count == 1)
        try await exerciseMetadataWrite(fixture)
        try await exerciseCopy(fixture)
        let exports = try await session.perform(.Export(catalog: fixture.catalog, request: .Options))
        guard case .Export(.Options) = exports else { throw unexpected("Export.Options", exports) }
        try await exerciseRelink(fixture)
        try await exercisePreview(fixture)
        try await exercisePreviewSettings(fixture)
        try await exerciseMigrationAdmission(fixture)
        let job = try await session.submit(.Status)
        let result = try await job.wait()
        #expect(try await job.status().phase == .taken)
        await #expect(throws: (any Error).self) { try await job.takeResult() }
        try await job.close()
        try await fixture.close()
        // Subscription remains valid after session release; owned payload remains readable.
        try await subscription.drain()
        #expect(notice.count > 0)
        let reply = try await result.decode(LWApplicationReply.self)
        guard case .Ok(.Status) = reply else { Issue.record("Expected status result after session release"); return }
        result.buffer.release()
        try fixture.expectOriginalUnchanged()
        } catch { throw await fixture.failure(error) }
    }

    @Test func actualConflictingSidecarsRequireCandidatesAndResolutionCAS() async throws {
        let fixture = try await Fixture.create(metadataConflict: true)
        defer { fixture.removeIfClosed() }
        do {
            let identity = try await metadataIdentity(fixture)
            let fieldsReply = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Fields(identity: identity, after: nil, limit: 100)))
            guard case .Metadata(.Fields(let fields)) = fieldsReply else { throw unexpected("conflicting Metadata.Fields", fieldsReply) }
            let field = try #require(fields.rows.first(where: { $0.name == "rating" && $0.conflicted }), "Two discovered XMP ratings must produce a real conflict.")
            let candidatesReply = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Candidates(identity: identity, field: field.name, after: nil, limit: 100)))
            guard case .Metadata(.Candidates(let candidates)) = candidatesReply else { throw unexpected("conflicting Metadata.Candidates", candidatesReply) }
            #expect(candidates.next == nil && Set(candidates.rows.map(\.model)).count >= 2)
            let chosen = try #require(candidates.rows.last)
            let resolved = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Resolve(key: fixture.key, expected_revision: identity.metadata_revision, field: field.name, model: chosen.model)))
            guard case .Metadata(.Changed(let revision)) = resolved else { throw unexpected("Metadata.Changed resolution", resolved) }
            #expect(revision.value > identity.metadata_revision.value)
            await #expect(throws: LensWorksManagedError.self) { try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Resolve(key: fixture.key, expected_revision: identity.metadata_revision, field: field.name, model: chosen.model))) }
            let fresh = try await metadataIdentity(fixture)
            let read = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Fields(identity: fresh, after: nil, limit: 100)))
            guard case .Metadata(.Fields(let stored)) = read else { throw unexpected("resolved Metadata.Fields", read) }
            let selected = try #require(stored.rows.first(where: { $0.name == field.name }))
            #expect(selected.selected_model == chosen.model && !selected.conflicted)
            // Exercise the checked MetadataWrite receipt route against the real
            // retained candidate too; its result is explicitly tagged resolved.
            _ = try await writeAction(fixture, .Resolve(identity: fresh, field: field.name, model: chosen.model), kind: "resolved")
            try fixture.expectOriginalUnchanged()
            try await fixture.close()
        } catch { throw await fixture.failure(error) }
    }

    @Test func actualBackupRestoreTypedReceiptsAndImportedRows() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.removeIfClosed() }
        let session = fixture.session
        do {
            let bundle = try LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("Backup"))
            let started = try await session.perform(.BackupCreate(catalog: fixture.catalog, bundle: bundle))
            guard case .Backup(let pending) = started, let pending else { throw unexpected("Backup operation", started) }
            let complete = try await backupComplete(session, operation: pending.operation)
            guard case .Backup(let receipt) = complete.receipt else { throw LensWorksManagedError.protocolViolation("Missing typed backup receipt: \(complete)") }
            #expect(receipt.database_bytes.value > 0 && receipt.database_blake3.count == 64)
            let inspected = try await session.perform(.BackupInspect(bundle: bundle))
            guard case .Backup(let inspect) = inspected, let inspect else { throw unexpected("BackupInspect operation", inspected) }
            let verified = try await backupComplete(session, operation: inspect.operation)
            guard case .Backup(let verifiedReceipt) = verified.receipt else { throw LensWorksManagedError.protocolViolation("Missing inspected receipt: \(verified)") }
            #expect(verifiedReceipt.backup_id == receipt.backup_id)
            let destination = try LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("Restored"))
            let restoring = try await session.perform(.BackupRestore(bundle: bundle, destination: destination))
            guard case .Backup(let restore) = restoring, let restore else { throw unexpected("BackupRestore operation", restoring) }
            let restored = try await backupComplete(session, operation: restore.operation)
            guard case .Restore(let restoredReceipt) = restored.receipt else { throw LensWorksManagedError.protocolViolation("Missing restore receipt: \(restored)") }
            #expect(restoredReceipt.backup.backup_id == receipt.backup_id)
            _ = try await session.perform(.Close(catalog: fixture.catalog))
            let opened = try await session.perform(.OpenExisting(path: destination))
            guard case .Status(let opening) = opened, let token = opening.catalog else { throw unexpected("restored catalog admission", opened) }
            try await waitUntil {
                let reply = try await session.perform(.Status)
                guard case .Status(let status) = reply else { throw unexpected("restored Status", reply) }
                if status.phase == .Failed { throw unexpected("Ready restored catalog", reply) }
                return status.phase == .Ready
            }
            let statusReply = try await session.perform(.RestoreStatus(catalog: token))
            guard case .Restore(let state) = statusReply, let state else { throw unexpected("RestoreStatus receipt", statusReply) }
            #expect(state.receipt.restore_id == restoredReceipt.restore_id && state.jobs_held)
            let resumed = try await session.perform(.ResumeRestoredJobs(catalog: token, restore_id: state.receipt.restore_id, acknowledge_pending_jobs: true))
            guard case .Restore(let released) = resumed, let released else { throw unexpected("ResumeRestoredJobs", resumed) }
            #expect(!released.jobs_held)
            let rowsReply = try await session.perform(.Images(catalog: token, folder: nil, recursive: true, text: nil, cursor: nil, limit: 10))
            guard case .Images(let rows, _, _, _, _) = rowsReply else { throw unexpected("restored Images", rowsReply) }
            #expect(rows.count == 1 && rows[0].key.asset_id == fixture.key.asset_id)
            try await fixture.close()
            #expect(try Data(contentsOf: fixture.original) == fixture.before)
        } catch { throw await fixture.failure(error) }
    }

    @Test func actualWorkbenchCaptureManifestRegistrationAndRetainedRows() async throws {
        struct Manifest: Decodable, Sendable {
            struct Request: Decodable, Sendable { let source: LWCatalogNativePath }
            let protocolVersion: UInt32, request: Request, revision_id: String?
            enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", request, revision_id }
        }
        struct Revision: Decodable, Sendable { let revision: String }
        struct Progress: Decodable, Sendable { let revision_id: String, retained_this_call: Int, stage: String }
        struct Rows: Decodable, Sendable {
            struct Row: Decodable, Sendable { let revision_id: String, table: String, cells: [LWLightroomPlanCell] }
            let rows: [Row], next: LWCatalogI64?, exhausted: Bool
        }
        let fixture = try await Fixture.create()
        defer { fixture.removeIfClosed() }
        let session = fixture.session
        do {
            let sqliteDirectory = fixture.root.appendingPathComponent("SQLiteSource", isDirectory: true)
            try FileManager.default.createDirectory(at: sqliteDirectory, withIntermediateDirectories: true)
            let sqlite = sqliteDirectory.appendingPathComponent("Fixture.lrcat")
            try await LWManagedTransport.background {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                child.arguments = [sqlite.path, "PRAGMA journal_mode=DELETE; CREATE TABLE LensWorksFixture(id INTEGER PRIMARY KEY, raw TEXT, binary BLOB); INSERT INTO LensWorksFixture VALUES(1,CAST(X'00FF80' AS TEXT),X'00FF80');"]
                let diagnostic = Pipe(); child.standardError = diagnostic
                try child.run(); child.waitUntilExit()
                guard child.terminationStatus == 0 else { throw LensWorksManagedError.protocolViolation("SQLite fixture creation failed: \(String(decoding: diagnostic.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))") }
            }
            let originalSQLite = try Data(contentsOf: sqlite)
            let optionsReply = try await session.perform(.Lightroom(request: .Options))
            guard case .Lightroom(.Options(let options)) = optionsReply else { throw unexpected("Lightroom.Options", optionsReply) }
            let opened = try await session.perform(.Lightroom(request: .Open(attempt: UUID().uuidString.lowercased(), root: LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("Inspection")), mode: .Create, capture_staging: LWCatalogNativePath(fileURL: fixture.root), limits: options.workbench)))
            guard case .Lightroom(.Status(let initial)) = opened, let initial else { throw unexpected("Workbench admission", opened) }
            let ready = try await workbenchComplete(session)
            #expect(ready.initialized && ready.workbench == initial.workbench)
            let capture = fixture.root.appendingPathComponent("Captured")
            _ = try await session.perform(.Lightroom(request: .Action(guard: workbenchGuard(ready), action: .Capture(source: LWCatalogNativePath(fileURL: sqlite), output: LWCatalogNativePath(fileURL: capture), include_auxiliary: false, closed_application_evidence: "The fixture SQLite writer exited before capture.", limits: options.inspection))))
            let manifest: Manifest = try await workbenchResult(session)
            let revision = try #require(manifest.revision_id, "Successful source capture must retain its revision.")
            let capturedSource = try LWCatalogNativePath(fileURL: sqlite)
            #expect(manifest.protocolVersion == 1 && manifest.request.source == capturedSource)
            var current = try await workbenchComplete(session)
            _ = try await session.perform(.Lightroom(request: .Read(guard: workbenchGuard(current), query: .CaptureManifest(directory: LWCatalogNativePath(fileURL: capture)))))
            let readManifest: Manifest = try await workbenchResult(session)
            #expect(readManifest.revision_id == revision && readManifest.request.source == manifest.request.source)
            current = try await workbenchComplete(session)
            _ = try await session.perform(.Lightroom(request: .Action(guard: workbenchGuard(current), action: .AddCapture(directory: LWCatalogNativePath(fileURL: capture)))))
            let hydrated: Revision = try await workbenchResult(session)
            #expect(hydrated.revision == revision)
            var progress: Progress?
            for _ in 0..<20 {
                current = try await workbenchComplete(session)
                _ = try await session.perform(.Lightroom(request: .Action(guard: workbenchGuard(current), action: .Resume(revision: revision, max_rows: LWCatalogU64(10)))))
                let next: Progress = try await workbenchResult(session)
                #expect(next.revision_id == revision)
                progress = next
                if next.stage == "rows_reconciled_paths_pending" { break }
            }
            #expect(progress?.stage == "rows_reconciled_paths_pending")
            current = try await workbenchComplete(session)
            _ = try await session.perform(.Lightroom(request: .Read(guard: workbenchGuard(current), query: .Rows(revision: revision, table: "LensWorksFixture", after: LWCatalogI64(0), limit: LWCatalogU64(10)))))
            let rows: Rows = try await workbenchResult(session)
            #expect(rows.rows.count == 1 && rows.rows[0].revision_id == revision)
            let cellJSON = try rows.rows.first.map { try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode($0.cells)) }
            #expect(cellJSON == .array([.object(["type": .string("Integer"), "value": .signed(1)]), .object(["type": .string("Text"), "value": .string("00ff80")]), .object(["type": .string("Blob"), "value": .string("00ff80")])]))
            let closed = try await session.perform(.Lightroom(request: .Close(workbench: ready.workbench)))
            guard case .Lightroom(.Status(let terminal)) = closed, let terminal else { throw unexpected("Workbench close", closed) }
            #expect(terminal.workbench == ready.workbench)
            try await waitUntil {
                let reply = try await session.perform(.Lightroom(request: .Status(workbench: ready.workbench, attempt: nil)))
                guard case .Lightroom(.Status(let status)) = reply, let status else { throw unexpected("closing Workbench.Status", reply) }
                if status.phase == .Failed { throw unexpected("closed Workbench", reply) }
                return status.closed && status.phase == .Closed
            }
            try await fixture.close()
            #expect(try Data(contentsOf: sqlite) == originalSQLite)
            #expect(try Data(contentsOf: fixture.original) == fixture.before)
        } catch { throw await fixture.failure(error) }
    }

    private func workbenchGuard(_ status: LWApplicationLightroomBridgeWireStatus) -> LWApplicationLightroomBridgeWireGuard {
        .init(workbench: status.workbench, generation: status.generation, operation: status.operation)
    }
    private func workbenchComplete(_ session: LWManagedSession) async throws -> LWApplicationLightroomBridgeWireStatus {
        var complete: LWApplicationLightroomBridgeWireStatus?
        try await waitUntil {
            let reply = try await session.perform(.Lightroom(request: .Status(workbench: nil, attempt: nil)))
            guard case .Lightroom(.Status(let status)) = reply, let status else { throw unexpected("Workbench.Status", reply) }
            if status.phase == .Failed || status.phase == .Canceled || status.phase == .Closed { throw unexpected("completed Workbench operation", reply) }
            if status.phase == .Complete { complete = status; return true }
            return false
        }
        return try #require(complete)
    }
    private func workbenchResult<T: Decodable & Sendable>(_ session: LWManagedSession) async throws -> T {
        let status = try await workbenchComplete(session)
        let token = try #require(status.result_token, "Completed Workbench operation must publish a result token.")
        var offset = LWCatalogU64(0), bytes = Data()
        for _ in 0..<100 {
            let reply = try await session.perform(.Lightroom(request: .Result(guard: workbenchGuard(status), token: token, offset: offset, limit: LWCatalogU64(65536))))
            guard case .Lightroom(.Result(let page)) = reply else { throw unexpected("Workbench.Result", reply) }
            guard page.page.offset == offset && page.page.token == token else { throw unexpected("matching result-page authority", reply) }
            bytes.append(contentsOf: page.page.json_fragment.utf8)
            guard bytes.count <= 4 * 1024 * 1024 else { throw LensWorksManagedError.resourceLimit("Workbench fixture result exceeded 4 MiB.") }
            guard let next = page.page.next else { return try LWCatalogCodec.decode(T.self, from: bytes) }
            guard next.value > offset.value else { throw unexpected("advancing result-page cursor", reply) }
            offset = next
        }
        throw LensWorksManagedError.resourceLimit("Workbench fixture exceeded 100 result pages.")
    }

    private func backupComplete(_ session: LWManagedSession, operation: String) async throws -> LWApplicationBackupSnapshot {
        var completed: LWApplicationBackupSnapshot?
        try await waitUntil {
            let reply = try await session.perform(.BackupStatus)
            guard case .Backup(let snapshot) = reply, let snapshot else { throw unexpected("BackupStatus", reply) }
            guard snapshot.operation == operation else { throw unexpected("matching backup operation", reply) }
            if snapshot.state == .Failed { throw unexpected("complete backup operation", reply) }
            if snapshot.state == .Complete { completed = snapshot; return true }
            return false
        }
        return try #require(completed)
    }

    private func metadataIdentity(_ fixture: Fixture) async throws -> LWApplicationOrganizationImageIdentity {
        let reply = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Identity(key: fixture.key)))
        guard case .Metadata(.Identity(let identity)) = reply else { throw unexpected("Metadata.Identity", reply) }
        return identity
    }

    private func writeAction(_ fixture: Fixture, _ action: LWApplicationMetadataWriteAction, kind: String) async throws -> LWCatalogJSON {
        let reply = try await fixture.session.perform(.MetadataWrite(catalog: fixture.catalog, request: .Start(attempt: UUID().uuidString.lowercased(), action: action)))
        guard case .MetadataWrite(.Admitted(let admitted)) = reply else { throw unexpected("MetadataWrite.Admitted", reply) }
        var result: LWCatalogJSON?
        try await waitUntil {
            let reply = try await fixture.session.perform(.MetadataWrite(catalog: fixture.catalog, request: .Status(operation: admitted.operation)))
            guard case .MetadataWrite(.Status(let status)) = reply, let operation = status.operation, operation.id == admitted.operation else { throw unexpected("matching MetadataWrite operation", reply) }
            if operation.phase == "failed" || operation.phase == "canceled" { throw unexpected("complete MetadataWrite operation", reply) }
            guard operation.phase == "complete" else { return false }
            guard case .object(let payload) = operation.result, payload["kind"] == .string(kind), let value = payload["value"] else { throw unexpected("MetadataWrite result kind \(kind)", reply) }
            result = value; return true
        }
        return try #require(result)
    }

    private func exerciseMetadataWrite(_ fixture: Fixture) async throws {
        struct SidecarPlan: Decodable, Sendable { let operation: String; let authority_blake3: String; let destination: LWCatalogNativePath; let payload_bytes: LWCatalogU64 }
        struct SidecarReceipt: Decodable, Sendable { let version: UInt32; let state: String; let destination: LWCatalogNativePath; let detail: String }
        let limits = LWApplicationMetadataWriteWriteLimits(input_bytes: LWCatalogU64(1048576), existing_file_bytes: LWCatalogU64(16777216), evidence_bytes: LWCatalogU64(268435456), evidence_packets: LWCatalogU64(1024), alias_directories: LWCatalogU64(4096), alias_candidates: LWCatalogU64(256))
        let identity = try await metadataIdentity(fixture)
        let bytes = Data(#"[{"operation":"set","namespace":"http://ns.adobe.com/xap/1.0/","path":"Rating","value":"3"}]"#.utf8)
        let digest = try await LWManagedTransport.blake3(bytes)
        let inputValue = try await writeAction(fixture, .InputBegin(bytes: LWCatalogU64(UInt64(bytes.count)), expected_blake3: digest, limits: limits), kind: "input")
        let input = try LWCatalogCodec.decode(LWApplicationMetadataWriteInput.self, from: LWCatalogCodec.encode(inputValue))
        _ = try await writeAction(fixture, .InputAppend(token: input.token, generation: input.generation, offset: LWCatalogU64(0), bytes: Array(bytes)), kind: "input")
        _ = try await writeAction(fixture, .InputFinish(token: input.token, generation: input.generation, bytes: LWCatalogU64(UInt64(bytes.count)), blake3: digest), kind: "input")
        let reviewValue = try await writeAction(fixture, .Prepare(identity: identity, base_model: nil, input: input.token, input_blake3: digest), kind: "review")
        let review = try LWCatalogCodec.decode(LWApplicationMetadataWriteReview.self, from: LWCatalogCodec.encode(reviewValue))
        #expect(review.changed_fields.value == 1 && review.edits.value == 1)
        let reviewed = try await fixture.session.perform(.MetadataWrite(catalog: fixture.catalog, request: .Review(token: review.token, digest: review.digest)))
        guard case .MetadataWrite(.Review(let storedReview)) = reviewed else { throw unexpected("MetadataWrite.Review", reviewed) }
        #expect(storedReview.digest == review.digest && storedReview.token == review.token)
        _ = try await writeAction(fixture, .Commit(review: review.token, review_digest: review.digest), kind: "changed")
        var current = try await metadataIdentity(fixture)
        #expect(current.metadata_revision.value > identity.metadata_revision.value)
        await #expect(throws: LensWorksManagedError.self) { try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Fields(identity: identity, after: nil, limit: 10))) }
        let fieldsReply = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Fields(identity: current, after: nil, limit: 100)))
        guard case .Metadata(.Fields(let fields)) = fieldsReply else { throw unexpected("nonempty Metadata.Fields", fieldsReply) }
        #expect(!fields.rows.isEmpty && fields.next == nil)
        for field in fields.rows where field.conflicted {
            let candidatesReply = try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Candidates(identity: current, field: field.name, after: nil, limit: 100)))
            guard case .Metadata(.Candidates(let candidates)) = candidatesReply, let candidate = candidates.rows.first else { throw unexpected("retained Metadata.Candidates", candidatesReply) }
            let stale = current
            _ = try await writeAction(fixture, .Resolve(identity: current, field: field.name, model: candidate.model), kind: "resolved")
            current = try await metadataIdentity(fixture)
            await #expect(throws: LensWorksManagedError.self) { try await fixture.session.perform(.Metadata(catalog: fixture.catalog, request: .Resolve(key: fixture.key, expected_revision: stale.metadata_revision, field: field.name, model: candidate.model))) }
        }
        let model = try #require(fields.rows.compactMap(\.selected_model).first, "Committed edit must retain an XMP model.")
        let destination = fixture.root.appendingPathComponent("edited.xmp")
        let nativeDestination = try LWCatalogNativePath(fileURL: destination)
        let planValue = try await writeAction(fixture, .SidecarPlan(identity: current, base_model: model, destination: nativeDestination, limits: limits), kind: "sidecar_plan")
        let plan = try LWCatalogCodec.decode(SidecarPlan.self, from: LWCatalogCodec.encode(planValue))
        #expect(plan.destination == nativeDestination && plan.payload_bytes.value > 0)
        let receiptValue = try await writeAction(fixture, .SidecarApply(operation: plan.operation, authority_blake3: plan.authority_blake3, overwrite_ack: false, limits: limits), kind: "sidecar_receipt")
        let receipt = try LWCatalogCodec.decode(SidecarReceipt.self, from: LWCatalogCodec.encode(receiptValue))
        #expect(receipt.version == 2 && receipt.state == "Published" && receipt.destination == nativeDestination)
        #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("Rating"))
        #expect(try Data(contentsOf: fixture.original) == fixture.before)
    }

    private func exerciseCopy(_ fixture: Fixture) async throws {
        let session = fixture.session
        let originalReply = try await session.perform(.Variant(catalog: fixture.catalog, key: fixture.key))
        guard case .Variant(let original) = originalReply, case .V1(var recipe) = original.recipe else { throw unexpected("original Variant recipe", originalReply) }
        let created = try await session.perform(.CreateVariant(catalog: fixture.catalog, key: fixture.key, expected_revision: original.revision, label: "Copy target"))
        guard case .Variant(let target) = created else { throw unexpected("created target Variant", created) }
        recipe.exposure_ev = LWCatalogFloat32(1)
        let saved = try await session.perform(.SaveRecipe(catalog: fixture.catalog, key: fixture.key, expected_revision: original.revision, recipe: .V1(recipe)))
        guard case .Variant(let savedSource) = saved else { throw unexpected("saved source Variant", saved) }
        let undone = try await session.perform(.Undo(catalog: fixture.catalog, key: fixture.key, expected_revision: savedSource.revision))
        guard case .Variant(let undo) = undone, case .V1(let undoRecipe) = undo.recipe else { throw unexpected("Undo Variant", undone) }
        #expect(undoRecipe.exposure_ev.value == 0 && undo.revision.value > savedSource.revision.value && undo.can_redo)
        let redone = try await session.perform(.Redo(catalog: fixture.catalog, key: fixture.key, expected_revision: undo.revision))
        guard case .Variant(let source) = redone, case .V1(let redoRecipe) = source.recipe else { throw unexpected("Redo Variant", redone) }
        #expect(redoRecipe.exposure_ev.value == 1 && source.revision.value > undo.revision.value)
        await #expect(throws: LensWorksManagedError.self) { try await session.perform(.Undo(catalog: fixture.catalog, key: fixture.key, expected_revision: savedSource.revision)) }
        let history = try await session.perform(.History(catalog: fixture.catalog, key: fixture.key, after: LWCatalogI64(0), limit: 100))
        guard case .History(let entries, let next) = history else { throw unexpected("typed edit History", history) }
        #expect(next == nil && entries.count >= 3)
        #expect(Set(entries.map(\.revision)).contains(source.revision))
        var search = try LWCatalogCodec.decode(LWApplicationBrowseOptions.self, from: Data("{}".utf8))
        search.text = fixture.original.lastPathComponent
        let searched = try await session.perform(.Search(catalog: fixture.catalog, options: search, cursor: nil, limit: 100))
        guard case .Images(let results, _, let hasMore, let complete, _) = searched else { throw unexpected("typed Search images", searched) }
        #expect(complete && !hasMore && results.contains(where: { $0.key.asset_id == fixture.key.asset_id }))
        let begun = try await session.perform(.EditCopy(catalog: fixture.catalog, request: .Begin(source: fixture.key, expected_revision: source.revision, groups: [.Exposure])))
        guard case .EditCopy(.Job(let job)) = begun else { throw unexpected("EditCopy.Job", begun) }
        let appended = try await session.perform(.EditCopy(catalog: fixture.catalog, request: .Append(job: job.id, expected_total: LWCatalogI64(0), targets: [LWApplicationCopyTarget(key: target.key, expected_revision: target.revision)])))
        guard case .EditCopy(.Job) = appended else { throw unexpected("EditCopy.Append", appended) }
        _ = try await session.perform(.EditCopy(catalog: fixture.catalog, request: .Seal(job: job.id, expected_total: LWCatalogI64(1))))
        let run = try await session.perform(.EditCopy(catalog: fixture.catalog, request: .Run(job: job.id)))
        guard case .EditCopy(.Operation(let operation)) = run, let operation else { throw unexpected("EditCopy.Run", run) }
        try await waitUntil {
            let reply = try await session.perform(.EditCopy(catalog: fixture.catalog, request: .Status(operation: operation.id)))
            guard case .EditCopy(.Operation(let state)) = reply, let state else { throw unexpected("EditCopy.Status", reply) }
            if state.phase == .Failed || state.phase == .Canceled { throw unexpected("completed EditCopy", reply) }
            return state.phase == .Complete
        }
        let copied = try await session.perform(.Variant(catalog: fixture.catalog, key: target.key))
        guard case .Variant(let variant) = copied, case .V1(let copiedRecipe) = variant.recipe, case .V1(let before) = target.recipe else { throw unexpected("copied Variant recipe", copied) }
        #expect(copiedRecipe.exposure_ev.value == 1 && variant.revision.value > target.revision.value)
        #expect(copiedRecipe.saturation == before.saturation && copiedRecipe.contrast == before.contrast)
        await #expect(throws: LensWorksManagedError.self) { try await session.perform(.SaveRecipe(catalog: fixture.catalog, key: target.key, expected_revision: target.revision, recipe: target.recipe)) }
    }

    private func exercisePreviewSettings(_ fixture: Fixture) async throws {
        let session = fixture.session
        func settings(_ request: LWApplicationPreviewSettingsRequest) async throws -> LWApplicationPreviewSettingsStatus {
            let reply = try await session.perform(.PreviewSettings(catalog: fixture.catalog, request: request))
            guard case .PreviewSettings(let state) = reply else { throw unexpected("PreviewSettings", reply) }
            return state
        }
        let budget = try await settings(.SetBudgets(thumbnail_bytes: LWCatalogU64(67108864), large_bytes: LWCatalogU64(268435456)))
        #expect(budget.thumbnail_bytes.value == 67108864 && budget.large_bytes.value == 268435456)
        let originalRoot = try LWCatalogNativePath(fileURL: fixture.original.deletingLastPathComponent())
        var state = try await settings(.BeginOriginalRootReview(roots: [originalRoot]))
        for _ in 0..<20 where state.original_roots.state != "ready" {
            let review = try #require(state.original_roots.review)
            state = try await settings(.StepOriginalRootReview(review: review, directories: 2))
        }
        #expect(state.original_roots.state == "ready" && state.original_roots.roots == [originalRoot])
        let destination = try LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("RelocatedThumbnails"))
        state = try await settings(.BeginRelocation(tier: .Thumbnail, destination: destination))
        for _ in 0..<100 where state.relocation_pending { state = try await settings(.StepRelocation(tier: .Thumbnail, objects: 2, bytes: LWCatalogU64(134217728))) }
        #expect(!state.relocation_pending && state.thumbnail_root == destination)
        await #expect(throws: LensWorksManagedError.self) { try await settings(.BeginRelocation(tier: .Thumbnail, destination: LWCatalogNativePath(fileURL: fixture.original.deletingLastPathComponent().appendingPathComponent("ForbiddenCache")))) }
        #expect(!FileManager.default.fileExists(atPath: fixture.original.deletingLastPathComponent().appendingPathComponent("ForbiddenCache").path))
        #expect(try Data(contentsOf: fixture.original) == fixture.before)
    }

    private func relinkComplete(_ fixture: Fixture, _ reply: LWApplicationResponse) async throws -> LWApplicationRelinkOperation {
        guard case .Relink(.Operation(let operation)) = reply, let operation else { throw unexpected("Relink operation admission", reply) }
        var completed: LWApplicationRelinkOperation?
        try await waitUntil {
            let current = try await fixture.session.perform(.Relink(catalog: fixture.catalog, request: .Status(operation: operation.id)))
            guard case .Relink(.Operation(let status)) = current, let status, status.id == operation.id else { throw unexpected("matching Relink.Status", current) }
            if status.phase == .Failed || status.phase == .Canceled { throw unexpected("completed Relink", current) }
            if status.phase == .Complete { completed = status; return true }
            return false
        }
        return try #require(completed)
    }
    private func exerciseRelink(_ fixture: Fixture) async throws {
        let session = fixture.session
        let moved = fixture.root.appendingPathComponent("moved.png")
        try fixture.before.write(to: moved)
        let nativeMoved = try LWCatalogNativePath(fileURL: moved)
        let begun = try await session.perform(.Relink(catalog: fixture.catalog, request: .Begin(scope: .Asset(asset_id: fixture.key.asset_id, destinations: [nativeMoved]))))
        guard case .Relink(.Plan(let plan)) = begun else { throw unexpected("Relink.Plan", begun) }
        _ = try await relinkComplete(fixture, session.perform(.Relink(catalog: fixture.catalog, request: .Prepare(plan: plan.id, revision: plan.revision, batch_rows: LWCatalogU64(10)))))
        let stored = try await session.perform(.Relink(catalog: fixture.catalog, request: .Plan(plan: plan.id)))
        guard case .Relink(.Plan(let read)) = stored else { throw unexpected("persisted Relink.Plan", stored) }
        #expect(read.id == plan.id && read.total.value == 1 && read.state == "ready")
        let items = try await session.perform(.Relink(catalog: fixture.catalog, request: .Items(plan: read.id, revision: read.revision, after: LWCatalogI64(0), limit: LWCatalogU64(10))))
        guard case .Relink(.Items(let rows, _)) = items else { throw unexpected("Relink.Items", items) }
        #expect(rows.count == 1 && rows[0].asset_id == fixture.key.asset_id)
        let applied = try await relinkComplete(fixture, session.perform(.Relink(catalog: fixture.catalog, request: .Apply(plan: read.id, revision: read.revision))))
        guard case .Plan(let appliedPlan) = applied.result else { throw LensWorksManagedError.protocolViolation("Missing applied relink plan: \(applied)") }
        let original = try await relinkComplete(fixture, session.perform(.Relink(catalog: fixture.catalog, request: .Original(key: fixture.key))))
        guard case .Original(let relocated) = original.result, case .Native(let relocatedPath) = relocated.status.current else { throw LensWorksManagedError.protocolViolation("Missing relocated original: \(original)") }
        #expect(relocatedPath == nativeMoved)
        let latest = try await session.perform(.Relink(catalog: fixture.catalog, request: .Plan(plan: appliedPlan.id)))
        guard case .Relink(.Plan(let undoPlan)) = latest else { throw unexpected("fresh plan before Undo", latest) }
        _ = try await relinkComplete(fixture, session.perform(.Relink(catalog: fixture.catalog, request: .Undo(plan: undoPlan.id, revision: undoPlan.revision))))
        let restored = try await relinkComplete(fixture, session.perform(.Relink(catalog: fixture.catalog, request: .Original(key: fixture.key))))
        guard case .Original(let restoredOriginal) = restored.result, case .Native(let restoredPath) = restoredOriginal.status.current else { throw LensWorksManagedError.protocolViolation("Missing restored original: \(restored)") }
        let expectedRestoredPath = try LWCatalogNativePath(fileURL: fixture.original)
        #expect(restoredPath == expectedRestoredPath)
        let restoredBytes = try Data(contentsOf: fixture.original)
        let movedBytes = try Data(contentsOf: moved)
        #expect(restoredBytes == fixture.before && movedBytes == fixture.before)
    }

    private func exercisePreview(_ fixture: Fixture) async throws {
        let session = fixture.session
        let viewport = UUID().uuidString
        let admitted = try await session.perform(.Preview(catalog: fixture.catalog, key: fixture.key, tier: .Thumbnail, interactive: false, viewport: viewport, generation: LWCatalogU64(1), foreground: false, diagnostics: true))
        guard case .Preview(let preview) = admitted else { throw unexpected("Preview admission", admitted) }
        try await waitUntil {
            let reply = try await session.perform(.PreviewStatus(catalog: fixture.catalog, ticket: preview.ticket))
            guard case .Preview(let state) = reply else { throw unexpected("PreviewStatus", reply) }
            if state.state == .Failed || state.state == .Unavailable || state.state == .NeedsResources || state.state == .Canceled { throw unexpected("ready Preview", reply) }
            return state.state == .Ready
        }
        let job = try await session.preview(catalog: fixture.catalog, ticket: preview.ticket, foreground: false)
        do {
            let result = try await job.wait()
            defer { result.buffer.release() }
            guard case .preview(let mime) = result.descriptor else { throw LensWorksManagedError.protocolViolation("Expected encoded preview descriptor: \(result.descriptor)") }
            #expect(mime == "image/jpeg" || mime == "image/webp" || mime == "image/avif")
            let bytes = try await result.buffer.copy(maximumBytes: 4 * 1024 * 1024)
            #expect(!bytes.isEmpty)
            try await job.close()
        } catch { try? await job.close(); throw error }
        let released = try await session.perform(.ReleaseViewport(catalog: fixture.catalog, viewport: viewport, generation: LWCatalogU64(1)))
        guard case .Status = released else { throw unexpected("released Preview viewport", released) }
    }

    private func exerciseMigrationAdmission(_ fixture: Fixture) async throws {
        // Exact public supplement route from the frozen source fixture. Uploaded
        // documents are proof evidence; their recorded source path is provenance.
        struct Revision: Codable, Sendable { let length: UInt64; let blake3: String; let modified_unix_ns: UInt64 }
        struct Request: Encodable, Sendable {
            let proof_root: LWCatalogNativePath, inspection_relative: LWCatalogNativePath
            let inspection_blake3: String, capture_revision: String, source_id: String
            let source_revision: Revision; let historical_status: String
        }
        struct Pin: Decodable, Sendable {
            let revision: String, source_id: String, origin: String, proof_blake3: String
            let source_revision: Revision; let historical_status: String
        }
        struct Prepared: Decodable, Sendable { let pin: Pin; let evidence: String }
        let session = fixture.session
        let proofRoot = fixture.root.appendingPathComponent("SupplementProof")
        let proof = proofRoot.appendingPathComponent("00")
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        let packet = Data("<x:xmpmeta>retained exact PSD packet</x:xmpmeta>".utf8)
        let packetHash = try await LWManagedTransport.blake3(packet)
        for name in ["packet-0.bin", "parse-input-0.bin"] { try packet.write(to: proof.appendingPathComponent(name)) }
        let revision = Revision(length: 1000, blake3: String(repeating: "b", count: 64), modified_unix_ns: 17)
        let rawRevision: [String: Any] = ["length": 1000, "blake3": revision.blake3, "modified_unix_ns": 17]
        let document: [String: Any] = [
            "baseline_equal": true, "qualified": true, "revision": String(repeating: "a", count: 64), "source_id": "original-lineage:source-key",
            "recorded_source": rawRevision, "source_revision": rawRevision, "status": "Complete", "issues": [],
            "source_path": ["encoding": "UnixBytes", "units": Array("/not-opened".utf8)], "work": ["whole_file_hash_passes": 1],
            "packets": [["attributes": [:], "container": "PsdResource1060", "decoded_bytes": NSNull(), "digest": packetHash,
                "file": ["blake3": packetHash, "bytes": packet.count, "path": "/old/probe/00/packet-0.bin"], "group": "psd:12", "origin": "embedded:packet:0",
                "ranges": [["offset": 24, "length": packet.count]], "raw_bytes": packet.count]],
            "parse_inputs": [["decoded_bytes": packet.count, "digest": packetHash,
                "file": ["blake3": packetHash, "bytes": packet.count, "path": "/old/probe/00/parse-input-0.bin"], "group": "psd:12", "origin": "embedded:parse_input:0",
                "packet_indices": [0], "raw_bytes": 0, "transformation": "Identity"]]
        ]
        let inspection = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try inspection.write(to: proof.appendingPathComponent("inspection.json"))
        let input = Request(proof_root: try LWCatalogNativePath(fileURL: proofRoot), inspection_relative: .unixBytes(Array("00/inspection.json".utf8)), inspection_blake3: try await LWManagedTransport.blake3(inspection), capture_revision: String(repeating: "a", count: 64), source_id: "original-lineage:source-key", source_revision: revision, historical_status: "Malformed")
        let upload = try LWCatalogCodec.encode([input])
        let uploadDigest = try await LWManagedTransport.blake3(upload)
        let operation = UUID().uuidString
        let header = LWApplicationLightroomMigrationHeader(catalog: nil, destination: try LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("SupplementTarget")), operation: .PrepareSupplements, parts: [LWLightroomMigrationWorkerInputPartDescriptor(role: .SupplementRequests, bytes: LWCatalogU64(UInt64(upload.count)), blake3: uploadDigest)], timeout_ms: LWCatalogU64(180000))
        func status(_ request: LWApplicationLightroomMigrationRequest) async throws -> LWApplicationLightroomMigrationSnapshot {
            let reply = try await session.perform(.LightroomMigration(request: request))
            guard case .LightroomMigration(.Status(let snapshot)) = reply else { throw unexpected("LightroomMigration.Status", reply) }
            return snapshot
        }
        // A prospective destination requires no open managed catalog. Retire the
        // original token before admitting this separate proof destination.
        let closed = try await session.perform(.Close(catalog: fixture.catalog))
        guard case .Status = closed else { throw unexpected("catalog Close before prospective migration", closed) }
        try await waitUntil {
            let reply = try await session.perform(.Status)
            guard case .Status(let state) = reply else { throw unexpected("closed catalog status", reply) }
            return state.phase == .Closed && state.catalog == nil
        }
        let admission = try await status(.Begin(operation: operation, header: header))
        #expect(admission.guard.operation == operation && admission.phase == .Uploading)
        var stale = admission.guard; stale.generation = "stale-generation"
        await #expect(throws: LensWorksManagedError.self) { try await status(.Status(guard: stale)) }
        _ = try await status(.Upload(guard: admission.guard, role: .SupplementRequests, offset: LWCatalogU64(0), text: String(decoding: upload, as: UTF8.self)))
        let sealed = try await status(.Finish(guard: admission.guard, role: .SupplementRequests, blake3: uploadDigest))
        #expect(sealed.phase == .Ready && sealed.uploaded.value == UInt64(upload.count))
        _ = try await status(.Act(guard: admission.guard))
        var completed: LWApplicationLightroomMigrationSnapshot?
        try await waitUntil {
            let state = try await status(.Status(guard: admission.guard))
            if state.phase == .Failed { throw LensWorksManagedError.protocolViolation("Supplement operation failed: \(state.failure.map(String.init(describing:)) ?? "unknown failure")") }
            if state.phase == .DrainPending { _ = try await status(.RetryDrain(guard: admission.guard)); return false }
            if state.phase == .Complete { completed = state; return true }
            return false
        }
        let complete = try #require(completed), identity = try #require(complete.result)
        var bytes = Data()
        for pageIndex in 0..<identity.pages.value {
            guard pageIndex < 100 else { throw LensWorksManagedError.resourceLimit("Supplement fixture exceeded 100 pages.") }
            var offset = LWCatalogU64(0)
            for _ in 0..<100 {
                let reply = try await session.perform(.LightroomMigration(request: .ResultPage(guard: complete.guard, page: LWCatalogU64(pageIndex), offset: offset, maximum_bytes: LWCatalogU64(16384))))
                guard case .LightroomMigration(.Page(let pageGuard, let page, let actualOffset, let text, let next)) = reply, pageGuard.operation == operation, page.value == pageIndex, actualOffset == offset else { throw unexpected("matching supplement result page", reply) }
                bytes.append(contentsOf: text.utf8)
                guard bytes.count <= 4 * 1024 * 1024 else { throw LensWorksManagedError.resourceLimit("Supplement result exceeded four MiB.") }
                guard let next else { break }
                guard next.value > offset.value else { throw unexpected("advancing supplement result cursor", reply) }; offset = next
            }
        }
        #expect(UInt64(bytes.count) == identity.bytes.value)
        #expect(try await LWManagedTransport.blake3(bytes) == identity.blake3)
        let prepared = try LWCatalogCodec.decode([Prepared].self, from: bytes)
        #expect(prepared.count == 1 && !prepared[0].evidence.isEmpty)
        #expect(prepared[0].pin.revision == input.capture_revision && prepared[0].pin.source_id == input.source_id)
        #expect(prepared[0].pin.historical_status == "Malformed" && prepared[0].pin.proof_blake3.count == 64)
        let discarded = try await session.perform(.LightroomMigration(request: .Discard(guard: complete.guard)))
        guard case .LightroomMigration(.Discarded(let retired)) = discarded else { throw unexpected("migration Discarded", discarded) }
        #expect(retired.operation == operation)
        let token = try #require(complete.catalog, "Supplement completion must retain the opened destination token.")
        _ = try await session.perform(.Close(catalog: token))
        #expect(try Data(contentsOf: fixture.original) == fixture.before)
    }

    @Test func blockedCallbackDrainTimeoutKeepsContextAndReentrantDrainIsBusy() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.removeIfClosed() }
        let gate = CallbackGate()
        defer { gate.open() }
        do {
        let subscription = try await fixture.session.subscribe { _, _ in gate.callback() }
        gate.subscription = subscription.handle.value
        let job = try await fixture.session.submit(.Status)
        let result = try await job.wait()
        result.buffer.release(); try await job.close()
        try await waitUntil { gate.entered }
        #expect(gate.reentrantStatus == 6)
        await #expect(throws: (any Error).self) { try await subscription.drain(timeoutMilliseconds: 1) }
        #expect(gate.entered)
        gate.open()
        try await subscription.drain(timeoutMilliseconds: 1000)
        try await subscription.drain(timeoutMilliseconds: 0)
        try await fixture.close()
        } catch { gate.open(); throw await fixture.failure(error) }
    }

    @Test func actualBlockedWorkerShutdownTimesOutRetainsOwnerAndRetries() async throws {
        struct Owner: Encodable, Sendable { let session: LWCatalogSessionHandle }
        struct Released: Decodable, Sendable { let released: Bool }
        let fixture = try await Fixture.create()
        defer { fixture.removeIfClosed() }
        let session = fixture.session
        let subscription = try await session.subscribe { _, _ in }
        let completedJob = try await session.submit(.Status)
        let result = try await completedJob.wait()
        defer { result.buffer.release() }
        let status = try await session.status()
        let pid = try #require(status.pid > 0 ? pid_t(status.pid) : nil, "Fixture must expose its actual retained desktop worker PID.")
        // Stop only this session's owned child. Independent Rust shutdown remains
        // addressable while its retained process wait is blocked.
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            _ = kill(pid, SIGCONT)
        }
        var paused = false
        defer { if paused { _ = kill(pid, SIGCONT) }; watchdog.cancel() }
        guard kill(pid, SIGSTOP) == 0 else { throw LensWorksManagedError.protocolViolation("Could not stop the owned fixture worker: \(errno)") }
        paused = true
        do {
            let started = ContinuousClock.now
            do {
                try await session.close(timeoutMilliseconds: 50)
                Issue.record("A stopped owned worker must not certify checked close.")
            } catch LensWorksManagedError.native(let code, let message) {
                #expect(code == "draining" && message.contains("retained for retry"))
            }
            #expect(started.duration(to: .now) < .seconds(2))
            fixture.cleanup.preserve("Expected bounded checked-shutdown timeout; session and fixture remain owned for retry.")
            #expect(!fixture.cleanup.certifiedClosed && FileManager.default.fileExists(atPath: fixture.root.path))
            let retainedArtifact = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("RetainedFixtureFailure.json"))) as? [String: Any]
            #expect(retainedArtifact?["session"] as? String == String(session.handle.value))
            #expect(retainedArtifact?["source_revision"] as? String == session.sourceRevision)
            #expect(try Data(contentsOf: fixture.original) == fixture.before)
            let retained = try await session.status()
            #expect(retained.phase == .draining && retained.pid == status.pid)
            do {
                let _: Released = try await LWManagedTransport.request("session_release", Owner(session: session.handle), as: Released.self)
                Issue.record("Pending checked close must retain its owner handle.")
            } catch LensWorksManagedError.native(let code, _) { #expect(code == "busy") }
            await #expect(throws: LensWorksManagedError.self) { try await session.submit(.Status) }
            await #expect(throws: LensWorksManagedError.self) { try await session.subscribe { _, _ in } }
            let cancelStarted = ContinuousClock.now
            try await completedJob.cancel()
            #expect(cancelStarted.duration(to: .now) < .seconds(2))
            #expect(try await completedJob.status().cancel_requested)
            guard kill(pid, SIGCONT) == 0 else { throw LensWorksManagedError.protocolViolation("Could not resume the owned fixture worker: \(errno)") }
            paused = false; watchdog.cancel()
            try await fixture.close()
            #expect(fixture.cleanup.certifiedClosed)
            // Successful close includes the checked receiver and callback drain;
            // owned payload and completed job outlive the released session.
            try await subscription.drain()
            let reply = try await result.decode(LWApplicationReply.self)
            guard case .Ok(.Status) = reply else { throw LensWorksManagedError.protocolViolation("Retained result changed after checked shutdown: \(reply)") }
            try await completedJob.close()
            await #expect(throws: LensWorksManagedError.self) { try await session.status() }
            #expect(try Data(contentsOf: fixture.original) == fixture.before)
        } catch {
            if paused { _ = kill(pid, SIGCONT); paused = false }
            watchdog.cancel()
            try? await completedJob.close()
            throw await fixture.failure(error)
        }
    }

    @Test func cancellationDoesNotQueueBehindPendingWorkerReceive() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.removeIfClosed() }
        do {
        let job = try await fixture.session.submit(.Images(catalog: fixture.catalog, folder: nil, recursive: true, text: nil, cursor: nil, limit: 100))
        let start = ContinuousClock.now
        try await job.cancel()
        #expect(start.duration(to: .now) < .seconds(2))
        let state = try await job.status()
        #expect(state.cancel_requested)
        try await job.close()
        try await fixture.close()
        } catch { throw await fixture.failure(error) }
    }

    @Test func actualFullFloatDecodeKeepsSourceAuthorityAndWideSamples() async throws {
        let fixture = try await Fixture.create(floatTIFF: true)
        defer { fixture.removeIfClosed() }
        let session = fixture.session
        do {
        let beforeRecipe = try await session.perform(.Variant(catalog: fixture.catalog, key: fixture.key))
        guard case .Variant(let originalVariant) = beforeRecipe, case .V1(var recipe) = originalVariant.recipe else { throw unexpected("original HDR Variant", beforeRecipe) }
        recipe.exposure_ev = LWCatalogFloat32(1)
        let edited = try await session.perform(.SaveRecipe(catalog: fixture.catalog, key: fixture.key, expected_revision: originalVariant.revision, recipe: .V1(recipe)))
        guard case .Variant(let editedVariant) = edited else { throw unexpected("HDR exposure edit", edited) }
        let beginReply = try await session.perform(.Export(catalog: fixture.catalog, request: .Begin))
        guard case .Export(.Job(let begun)) = beginReply else { throw unexpected("durable export plan owner", beginReply) }
        let destination = fixture.root.appendingPathComponent("unpublished.tif")
        let target = LWApplicationExportsDtoTarget(key: fixture.key, expected_revision: editedVariant.revision, destination: try LWCatalogNativePath(fileURL: destination), overwrite: false, metadata: .Omit)
        let output = LWApplicationExportsDtoOutput(size: .Original, format: .Tiff(depth: .Float32), profile: .LinearSrgb, alpha: .Preserve)
        let appendReply = try await session.perform(.Export(catalog: fixture.catalog, request: .Append(job: begun.id, expected_total: LWCatalogI64(0), target: target, output: output, budgets: LWApplicationExportsDtoBudgets(max_original_bytes: LWCatalogU64(1048576), max_payload_bytes: LWCatalogU64(1048576), alias_limits: LWApplicationExportsDtoAliasLimits(directories: LWCatalogU64(32), candidates: LWCatalogU64(256))))))
        guard case .Export(.Operation(let appended)) = appendReply, let appended else { throw unexpected("export append operation", appendReply) }
        try await waitUntil {
            let reply = try await session.perform(.Export(catalog: fixture.catalog, request: .Status(operation: appended.id)))
            guard case .Export(.Operation(let state)) = reply, let state else { throw unexpected("export append Status", reply) }
            if state.phase == "failed" { throw unexpected("complete export append", reply) }
            return state.phase == "complete"
        }
        _ = try await session.perform(.Export(catalog: fixture.catalog, request: .Seal(job: begun.id, expected_total: LWCatalogI64(1))))
        let sourceJob = try await session.sourceIdentity(catalog: fixture.catalog, exportJob: begun.id, sequence: LWCatalogI64(1))
        let sourceResult = try await sourceJob.wait()
        let plan = try await sourceResult.decode(LWApplicationExportsDtoPlan.self)
        #expect(plan.original == (try LWCatalogNativePath(fileURL: fixture.original)))
        sourceResult.buffer.release(); try await sourceJob.close()
        let decode = try await session.decodeFull(catalog: fixture.catalog, exportJob: begun.id, sequence: LWCatalogI64(1), limits: .init(max_encoded_bytes: LWCatalogU64(1048576), max_intermediate_pixels: LWCatalogU64(10000), max_allocation_bytes: LWCatalogU64(1048576)), workerBytes: LWCatalogU64(536870912), maximumOutputBytes: LWCatalogU64(64))
        let result = try await decode.wait()
        guard case .float(let descriptor) = result.descriptor else { result.buffer.release(); throw LensWorksManagedError.protocolViolation("Expected float descriptor; actual: \(result.descriptor)") }
        #expect(session.sourceRevision == LWManagedAuthority.sourceRevision)
        #expect(descriptor.source_revision == session.sourceRevision && descriptor.protocol == 2)
        #expect(descriptor.width == 2 && descriptor.height == 2 && descriptor.row_stride.value == 32)
        #expect(descriptor.alpha == "straight" && descriptor.orientation == "applied")
        let samples = try await result.floatSamples(maximumBytes: 64)
        #expect(samples.count == 16 && samples[0] < 0 && samples[1] > 1 && samples[7] == 0.5)
        result.buffer.release(); try await decode.close()
        #expect(try Data(contentsOf: fixture.original) == fixture.before)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(plan.identity.recipe_digest == editedVariant.recipe_digest && plan.identity.revision == editedVariant.revision)
        let render = LWApplicationExportsDtoRenderLimits(max_pixels: LWCatalogU64(10000), max_allocation_bytes: LWCatalogU64(1048576), max_live_bytes: LWCatalogU64(16777216))
        let decodeLimits = LWApplicationExportsDtoDecodeLimits(max_encoded_bytes: LWCatalogU64(1048576), max_intermediate_pixels: LWCatalogU64(10000), max_allocation_bytes: LWCatalogU64(1048576))
        let execution = LWApplicationExportsDtoExecutionLimits(worker_bytes: LWCatalogU64(134217728), working_bytes: LWCatalogU64(134217728), render: LWApplicationExportsDtoPhotoLimits(decode: decodeLimits, render: render, encode: LWApplicationExportsDtoEncodeLimits(render: render, max_metadata_bytes: LWCatalogU64(1048576), row_buffer_bytes: LWCatalogU64(1048576)), max_encoded_extent: LWCatalogU64(1048576)))
        _ = try await exportComplete(fixture, session.perform(.Export(catalog: fixture.catalog, request: .Recover(directories: LWCatalogU64(32), limits: execution))))
        let recoveredReply = try await session.perform(.Export(catalog: fixture.catalog, request: .Plan(job: begun.id, sequence: LWCatalogI64(1))))
        guard case .Export(.Plan(let recovered)) = recoveredReply else { throw unexpected("recovered Export.Plan", recoveredReply) }
        #expect(recovered.authority == plan.authority)
        #expect(try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(recovered.identity)) == LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(plan.identity)))
        let ran = try await exportComplete(fixture, session.perform(.Export(catalog: fixture.catalog, request: .Run(job: begun.id, limits: execution, max_items: LWCatalogU64(1), max_seconds: LWCatalogU64(30)))))
        #expect(ran.job?.state == "complete" && ran.processed.value == 1)
        let publishedReply = try await session.perform(.Export(catalog: fixture.catalog, request: .Plan(job: begun.id, sequence: LWCatalogI64(1))))
        guard case .Export(.Plan(let published)) = publishedReply else { throw unexpected("published Export.Plan", publishedReply) }
        #expect(published.authority == plan.authority && published.item.state == "published")
        #expect(try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(published.identity)) == LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(plan.identity)))
        let publicationReceipt = try #require(published.item.receipt, "Published export must persist its receipt.")
        #expect(publicationReceipt.state == "published" && publicationReceipt.destination == target.destination)
        let derivative = try Data(contentsOf: destination)
        #expect(!derivative.isEmpty && derivative != fixture.before)
        let restored = try await exportComplete(fixture, session.perform(.Export(catalog: fixture.catalog, request: .Restore(job: begun.id, sequence: LWCatalogI64(1), authority: published.authority))))
        guard case .Receipt(let restoredJob, let sequence, let authority, let receipt) = restored.result else { throw LensWorksManagedError.protocolViolation("Missing typed export Restore receipt: \(restored)") }
        #expect(restoredJob.id == begun.id && sequence.value == 1 && authority == published.authority)
        #expect(receipt.state == "published" && receipt.destination == target.destination)
        #expect(try Data(contentsOf: destination) == derivative)
        try fixture.expectOriginalUnchanged()
        try Data("changed original".utf8).write(to: fixture.original)
        let stale = try await session.decodeFull(catalog: fixture.catalog, exportJob: begun.id, sequence: LWCatalogI64(1), limits: .init(max_encoded_bytes: LWCatalogU64(1048576), max_intermediate_pixels: LWCatalogU64(10000), max_allocation_bytes: LWCatalogU64(1048576)), workerBytes: LWCatalogU64(536870912), maximumOutputBytes: LWCatalogU64(64))
        await #expect(throws: (any Error).self) { try await stale.wait() }
        try await stale.close(); try await fixture.close()
        #expect(try Data(contentsOf: fixture.original) == Data("changed original".utf8))
        } catch { throw await fixture.failure(error) }
    }


    @Test func actualLinearDNGFullFloatMatchesEveryReferencePixel() async throws {
        try await mathematicalDNG("generated-linear-mask.dng")
    }
    @Test func actualCalibrationDNGFullFloatMatchesEveryReferencePixel() async throws {
        try await mathematicalDNG("generated-calibration-mask.dng")
    }
    @Test func actualSpatialOneDNGFullFloatMatchesEveryReferencePixel() async throws {
        try await mathematicalDNG("generated-spatial1-mask.dng")
    }
    @Test func actualSpatialTwoDNGFullFloatMatchesEveryReferencePixel() async throws {
        try await mathematicalDNG("generated-spatial2-mask.dng")
    }
    private struct MathReference: Decodable {
        let width: Int, height: Int
        let linear_srgb: [[Double]], spatial_linear_srgb: [[[Double]]]
        let alpha: [Double], calibration_applied: [Bool]
    }
    private static func mathSHA(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Checked-in, generator-produced fixtures (engines/catalog/tests/fixtures,
    /// see its README). The independent per-pixel reference sits next to each DNG.
    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engines/catalog/tests/fixtures")
    }
    private func mathematicalDNG(_ filename: String) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let authority = try ownedCatalogAuthority(repository)
        let inputURL = Self.fixtureDirectory.appendingPathComponent(filename)
        let referenceURL = Self.fixtureDirectory.appendingPathComponent((filename as NSString).deletingPathExtension + ".expected.json")
        let sourceBytes = try Data(contentsOf: inputURL), referenceBytes = try Data(contentsOf: referenceURL)
        let sourceSHA = Self.mathSHA(sourceBytes)
        guard sourceBytes.count <= 1048576, referenceBytes.count <= 1048576 else { throw LensWorksManagedError.protocolViolation("DNG/reference fixture exceeds its 1MiB bound.") }
        let expected = try JSONDecoder().decode(MathReference.self, from: referenceBytes)
        let spatial = filename.contains("spatial"), rgbTolerance = spatial ? 0.002 : 0.001
        guard expected.width == 36, expected.height == 16, expected.alpha.count == 6,
              expected.linear_srgb.count == 6, expected.linear_srgb.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              expected.alpha.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              spatial ? (expected.spatial_linear_srgb.count == 16 && expected.spatial_linear_srgb.allSatisfy { $0.count == 36 && $0.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) } }) : expected.spatial_linear_srgb.isEmpty else {
            throw LensWorksManagedError.protocolViolation("Independent reference shape, finite values, or exact approved tolerances are invalid.")
        }
        let jobs = MathJobs()
        let fixture = try await Fixture.create(copiedSource: inputURL, referenceJobs: jobs)
        var passed = false
        defer { if passed { fixture.removeIfClosed() } }
        let session = fixture.session
        var evidence: [String: Any] = ["status": "UNQUALIFIED_PENDING_ACTUAL_DECODE", "source": filename,
            "inputSHA256": sourceSHA, "referenceSHA256": Self.mathSHA(referenceBytes),
            "sourceRevision": session.sourceRevision, "protocol": LWManagedAuthority.protocolVersion,
            "RGBToleranceStrict": rgbTolerance, "alphaToleranceStrict": 1e-6]
        func writeEvidence() throws {
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            guard data.count <= 131072 else { throw LensWorksManagedError.protocolViolation("Math fixture evidence exceeds its 128KiB bound.") }
            try data.write(to: fixture.root.appendingPathComponent("FullFloatReference.json"), options: .atomic)
        }
        func sourceUnchanged() throws {
            guard Self.mathSHA(try Data(contentsOf: fixture.original)) == sourceSHA,
                  Self.mathSHA(try Data(contentsOf: inputURL)) == sourceSHA else { throw LensWorksManagedError.protocolViolation("A protected mathematical fixture original changed.") }
            guard try fixture.original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == fixture.originalModified,
                  Set(try FileManager.default.contentsOfDirectory(atPath: fixture.original.deletingLastPathComponent().path)) == Set([fixture.original.lastPathComponent]) else {
                throw LensWorksManagedError.protocolViolation("A protected DNG source timestamp or directory membership changed.")
            }
        }
        func identityJSON<Value: Encodable>(_ value: Value) throws -> LWCatalogJSON {
            try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(value))
        }
        func readPlan(_ exportJob: String) async throws -> LWApplicationExportsDtoPlan {
            let job = try await session.sourceIdentity(catalog: fixture.catalog, exportJob: exportJob, sequence: LWCatalogI64(1))
            try jobs.retain(job)
            let result = try await jobs.result(job)
            var ownsBuffer = true
            defer { if ownsBuffer { result.buffer.release() } }
            let plan = try await result.decode(LWApplicationExportsDtoPlan.self, maximumBytes: 1048576)
            result.buffer.release(); ownsBuffer = false
            try await jobs.close(job)
            return plan
        }
        do {
            try sourceUnchanged()
            let variantReply = try await jobs.perform(session, .Variant(catalog: fixture.catalog, key: fixture.key))
            guard case .Variant(let variant) = variantReply else { throw unexpected("actual DNG Variant", variantReply) }
            let begin = try await jobs.perform(session, .Export(catalog: fixture.catalog, request: .Begin))
            guard case .Export(.Job(let exportJob)) = begin else { throw unexpected("actual DNG export plan owner", begin) }
            let destination = fixture.root.appendingPathComponent("NeverPublished.tif")
            let target = LWApplicationExportsDtoTarget(key: fixture.key, expected_revision: variant.revision,
                destination: try LWCatalogNativePath(fileURL: destination), overwrite: false, metadata: .Omit)
            let output = LWApplicationExportsDtoOutput(size: .Original, format: .Tiff(depth: .Float32), profile: .LinearSrgb, alpha: .Preserve)
            let append = try await jobs.perform(session, .Export(catalog: fixture.catalog, request: .Append(job: exportJob.id, expected_total: LWCatalogI64(0), target: target, output: output,
                budgets: LWApplicationExportsDtoBudgets(max_original_bytes: LWCatalogU64(1048576), max_payload_bytes: LWCatalogU64(1048576), alias_limits: LWApplicationExportsDtoAliasLimits(directories: LWCatalogU64(32), candidates: LWCatalogU64(256))))))
            guard case .Export(.Operation(let appended)) = append, let appended else { throw unexpected("actual DNG Append operation", append) }
            try await waitUntil {
                let current = try await jobs.perform(session, .Export(catalog: fixture.catalog, request: .Status(operation: appended.id)))
                guard case .Export(.Operation(let operation)) = current, let operation, operation.id == appended.id else { throw unexpected("matching DNG Append Status", current) }
                guard !["failed", "canceled"].contains(operation.phase) else { throw unexpected("completed DNG Append", current) }
                return operation.phase == "complete"
            }
            _ = try await jobs.perform(session, .Export(catalog: fixture.catalog, request: .Seal(job: exportJob.id, expected_total: LWCatalogI64(1))))
            let plan = try await readPlan(exportJob.id)
            guard plan.job == exportJob.id, plan.sequence.value == 1, !plan.authority.isEmpty,
                  plan.original == (try LWCatalogNativePath(fileURL: fixture.original)),
                  plan.identity.key.asset_id == fixture.key.asset_id, plan.identity.key.variant_id == fixture.key.variant_id,
                  plan.identity.revision == variant.revision, plan.identity.recipe_digest == variant.recipe_digest else { throw LensWorksManagedError.protocolViolation("Real sealed Plan lost exact DNG source/edit authority.") }
            evidence["planBefore"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(plan))
            evidence["variantBefore"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(variant))
            let decode = try await session.decodeFull(catalog: fixture.catalog, exportJob: exportJob.id, sequence: LWCatalogI64(1),
                limits: .init(max_encoded_bytes: LWCatalogU64(1048576), max_intermediate_pixels: LWCatalogU64(10000), max_allocation_bytes: LWCatalogU64(1048576)),
                workerBytes: LWCatalogU64(536870912), maximumOutputBytes: LWCatalogU64(9216))
            try jobs.retain(decode)
            let result = try await jobs.result(decode)
            var ownsFloatBuffer = true
            defer { if ownsFloatBuffer { result.buffer.release() } }
            guard case .float(let descriptor) = result.descriptor else { throw LensWorksManagedError.protocolViolation("Expected actual DNG float payload; received \(result.descriptor).") }
            let payload = try await result.buffer.copy(maximumBytes: 9216, expectedLength: result.length)
            try payload.write(to: fixture.root.appendingPathComponent("Decoded.rgba-f32le"), options: .atomic)
            evidence["payloadSHA256"] = Self.mathSHA(payload)
            evidence["descriptor"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(descriptor))
            try writeEvidence()
            guard descriptor.width == 36, descriptor.height == 16, descriptor.row_stride.value == 576,
                  descriptor.byte_length.value == 9216, result.length == 9216, payload.count == 9216,
                  descriptor.channels == 4, descriptor.sample == "float32_le", descriptor.color_space == "linear_srgb",
                  descriptor.alpha == "straight", descriptor.orientation == "applied",
                  descriptor.source_revision == session.sourceRevision, descriptor.source_revision == authority.digest, descriptor.protocol == 2,
                  descriptor.original == plan.original, descriptor.plan_authority == plan.authority,
                  try identityJSON(descriptor.source_identity) == identityJSON(plan.identity),
                  try identityJSON(descriptor.original_revision) == identityJSON(plan.original_revision) else { throw LensWorksManagedError.protocolViolation("Actual full-float descriptor changed geometry/protocol/source/physical revision/plan authority.") }
            let samples = try await result.floatSamples(maximumBytes: 9216)
            result.buffer.release(); ownsFloatBuffer = false
            try await jobs.close(decode)
            guard samples.count == 2304 else { throw LensWorksManagedError.protocolViolation("Actual DNG full-float frame is not exactly 2304 samples.") }
            var maximumRGBError = 0.0, maximumAlphaError = 0.0, negative = false, hdr = false, partialAlpha = false
            for y in 0..<16 { for x in 0..<36 {
                for channel in 0..<4 {
                    let index = (y * 36 + x) * 4 + channel, actual = Double(samples[index])
                    let reference = channel == 3 ? expected.alpha[x % 6] : (spatial ? expected.spatial_linear_srgb[y][x][channel] : expected.linear_srgb[x % 6][channel])
                    let tolerance = channel == 3 ? 1e-6 : rgbTolerance, delta = abs(actual - reference)
                    guard actual.isFinite, channel != 3 || (0...1).contains(actual), delta < tolerance else {
                        throw LensWorksManagedError.protocolViolation("\(filename) pixel(\(x),\(y)) channel\(channel), sample\(index): actual\(actual), expected\(reference), absolute error\(delta), strict tolerance\(tolerance). Full payload/descriptor retained at \(fixture.root.path).")
                    }
                    if channel == 3 { maximumAlphaError = max(maximumAlphaError, delta); partialAlpha = partialAlpha || (actual > 0 && actual < 1) }
                    else { maximumRGBError = max(maximumRGBError, delta); negative = negative || actual < 0; hdr = hdr || actual > 1 }
                }
            } }
            guard negative, hdr, partialAlpha else { throw LensWorksManagedError.protocolViolation("Actual DNG output omitted signed/HDR RGB or partial straight alpha.") }
            if filename.contains("calibration") {
                guard expected.calibration_applied.count == 6, let calibration = descriptor.provenance.calibration else { throw LensWorksManagedError.protocolViolation("Actual DNG calibration provenance is missing.") }
                let applied = UInt64(expected.calibration_applied.filter { $0 }.count * 16 * 6)
                guard applied == 288, calibration.applied_pixels == applied, calibration.bypassed_pixels == 576 - applied else { throw LensWorksManagedError.protocolViolation("Actual DNG calibration application/bypass counts differ from the independent mask.") }
            } else if spatial {
                guard let calibration = descriptor.provenance.spatial_calibration, calibration.applied_pixels == 576, calibration.bypassed_pixels == 0 else { throw LensWorksManagedError.protocolViolation("Actual spatial gain-map calibration did not cover all 576 pixels.") }
            } else {
                guard descriptor.provenance.calibration == nil, descriptor.provenance.spatial_calibration == nil else { throw LensWorksManagedError.protocolViolation("Matrix-only DNG unexpectedly applied LUT/spatial calibration.") }
            }
            let after = try await readPlan(exportJob.id)
            let afterVariantReply = try await jobs.perform(session, .Variant(catalog: fixture.catalog, key: fixture.key))
            guard case .Variant(let afterVariant) = afterVariantReply else { throw unexpected("DNG Variant after decode", afterVariantReply) }
            guard try identityJSON(after) == identityJSON(plan), try identityJSON(afterVariant) == identityJSON(variant),
                  !FileManager.default.fileExists(atPath: destination.path) else { throw LensWorksManagedError.protocolViolation("Source-only decode changed sealed Plan/edit authority or published an export.") }
            evidence["planAfter"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(after))
            evidence["variantAfter"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(afterVariant))
            evidence["comparedPixels"] = 576; evidence["comparedScalars"] = 2304
            evidence["maximumRGBError"] = maximumRGBError; evidence["maximumAlphaError"] = maximumAlphaError
            evidence["negativeRGB"] = negative; evidence["HDRRGB"] = hdr; evidence["partialStraightAlpha"] = partialAlpha
            try sourceUnchanged()
            // Public catalog retirement runs while the retained relay is Ready.
            let close = try await jobs.perform(session, .Close(catalog: fixture.catalog))
            guard case .Status(let closed) = close, closed.phase == .Closed, closed.catalog == nil else { throw unexpected("checked DNG catalog Closed", close) }
            try await fixture.close()
            try sourceUnchanged()
            evidence["status"] = "ACTUAL_FULL_FLOAT_REFERENCE_PASS_CHECKED_CLOSED"
            evidence["sourceSHA256VerifiedBeforeAfter"] = true; evidence["checkedClosed"] = true
            try writeEvidence()
            passed = true
        } catch {
            let primary = error
            evidence["status"] = "FAILED_UNQUALIFIED"; evidence["failure"] = String(describing: primary)
            evidence["retainedJobHandles"] = jobs.handles
            do { try sourceUnchanged(); evidence["sourceSHA256VerifiedOnFailure"] = true }
            catch { evidence["sourceVerificationFailure"] = String(describing: error) }
            do { try writeEvidence() } catch { Issue.record("Math fixture diagnostics could not be written at \(fixture.root.path): \(error)") }
            fixture.cleanup.preserve("Full-float reference failure: \(primary); source/descriptor/float artifacts retained at \(fixture.root.path).")
            do {
                try await jobs.retire()
                let close = try await jobs.perform(session, .Close(catalog: fixture.catalog))
                guard case .Status(let closed) = close, closed.phase == .Closed, closed.catalog == nil else { throw unexpected("DNG failure catalog retirement", close) }
                try await fixture.close()
            } catch {
                fixture.cleanup.preserve("Full-float reference failure: \(primary). Checked cleanup failed: \(error); retained handles \(jobs.handles).")
                throw LensWorksManagedError.protocolViolation("\(primary); checked cleanup: \(error). Retained math fixture: \(fixture.root.path).")
            }
            throw LensWorksManagedError.protocolViolation("\(primary). Checked-closed failed math fixture retained at \(fixture.root.path).")
        }
    }
    /// Test-only single-caller custody. At most eight outstanding real jobs;
    /// each completion observation is finite and pending jobs remain owned on error.
    private final class MathJobs {
        private var jobs: [LWManagedJob] = []
        var handles: [String] { jobs.map { String($0.handle.value) } }
        func retain(_ job: LWManagedJob) throws {
            guard jobs.count < 8 else { throw LensWorksManagedError.resourceLimit("Math fixture owns eight unfinished jobs; no further admission.") }
            jobs.append(job)
        }
        func result(_ job: LWManagedJob) async throws -> LWManagedResult {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while true {
                try Task.checkCancellation()
                let status = try await job.status()
                if status.phase == .complete { return try await job.takeResult() }
                guard status.phase == .pending, ContinuousClock.now < deadline else { throw LensWorksManagedError.protocolViolation("Math job \(job.handle.value) did not yield one terminal result within 30 seconds; owner retained.") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func close(_ job: LWManagedJob) async throws {
            guard try await job.status().phase != .pending else { throw LensWorksManagedError.protocolViolation("Math job release requires actual terminal authority.") }
            try await job.close()
            jobs.removeAll { $0.handle == job.handle }
        }
        func perform(_ session: LWManagedSession, _ request: LWApplicationRequest) async throws -> LWApplicationResponse {
            guard jobs.count < 8 else { throw LensWorksManagedError.resourceLimit("Math fixture has no free admitted job slot.") }
            let job = try await session.submit(request)
            try retain(job)
            let value = try await result(job)
            var ownsBuffer = true
            defer { if ownsBuffer { value.buffer.release() } }
            let reply = try await value.decode(LWApplicationReply.self, maximumBytes: 1048576)
            value.buffer.release(); ownsBuffer = false
            try await close(job)
            switch reply { case .Ok(let response): return response
            case .Error(let error): throw LensWorksManagedError.native(code: error.code.rawValue, message: error.message) }
        }
        func retire() async throws {
            for job in jobs { try await job.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !jobs.isEmpty {
                for job in jobs {
                    if try await job.status().phase != .pending { try await close(job) }
                }
                if !jobs.isEmpty {
                    guard ContinuousClock.now < deadline else { throw LensWorksManagedError.protocolViolation("Math fixture jobs still retire after 30 seconds; handles \(handles) retained.") }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }


    @Test func actualPNGFullFloatMatchesEverySourcePixel() async throws {
        let proof = try nonDNGProof("generated-swatches.png")
        var frame = try await decodeNonDNG(proof)
        do {
            guard let reference = proof.sourceLinearRGBA, reference.count == 6, reference.allSatisfy({ $0.count == 4 }) else {
                throw LensWorksManagedError.protocolViolation("Qualified PNG source reference must contain exactly six straight linear RGBA pixels.")
            }
            var maximumRGBError = 0.0, maximumAlphaError = 0.0
            for pixel in 0..<6 { for channel in 0..<4 {
                let actual = Double(frame.samples[pixel * 4 + channel]), expected = reference[pixel][channel]
                let tolerance = channel == 3 ? 1e-6 : 0.001, delta = abs(actual - expected)
                guard expected.isFinite, actual.isFinite, delta < tolerance else {
                    throw LensWorksManagedError.protocolViolation("PNG pixel\(pixel) channel\(channel): actual\(actual), expected\(expected), error\(delta), strict tolerance\(tolerance). Full raw frame retained at \(frame.fixture.root.path).")
                }
                if channel == 3 { maximumAlphaError = max(maximumAlphaError, delta) }
                else { maximumRGBError = max(maximumRGBError, delta) }
            } }
            guard frame.samples[11] == 0, frame.samples[10] > 0.999, frame.samples[7] > 0 && frame.samples[7] < 1 else {
                throw LensWorksManagedError.protocolViolation("PNG lost transparent blue RGB or partial straight alpha.")
            }
            frame.evidence["comparedPixels"] = 6; frame.evidence["comparedScalars"] = 24
            frame.evidence["maximumRGBError"] = maximumRGBError; frame.evidence["maximumAlphaError"] = maximumAlphaError
            frame.evidence["RGBToleranceStrict"] = 0.001; frame.evidence["alphaToleranceStrict"] = 1e-6
            frame.evidence["qualifiedContractRGBTolerance"] = 0.001
            frame.evidence["toleranceAuthority"] = "coordinator explicitly approved 0.001 RGB and 1e-6 alpha before runtime; no failure-based adjustment"
            frame.evidence["comparison"] = "qualified raw PNG CRC/zlib source RGBA with standard inverse sRGB; every pixel including alpha-zero RGB"
            try finishNonDNG(&frame)
        } catch {
            preserveNonDNG(&frame, failure: error)
            throw error
        }
    }

    @Test func actualAVIFIrotExifPrecedenceMatchesFullFramePair() async throws {
        var frames: [NonDNGFrame] = []
        do {
            frames.append(try await decodeNonDNG(nonDNGProof("generated-irot.avif")))
            frames.append(try await decodeNonDNG(nonDNGProof("generated-irot-exif.avif")))
            guard frames.count == 2, frames[0].descriptor.original != frames[1].descriptor.original,
                  frames[0].descriptor.source_identity.key.asset_id != frames[1].descriptor.source_identity.key.asset_id,
                  frames[0].samples.count == 24, frames[1].samples.count == 24 else {
                throw LensWorksManagedError.protocolViolation("AVIF pair requires two distinct real source and catalog-photo identities with exactly 24 full-frame samples.")
            }
            for index in 0..<24 {
                let a = frames[0].samples[index], b = frames[1].samples[index]
                guard a.isFinite, b.isFinite, a.bitPattern == b.bitPattern else {
                    throw LensWorksManagedError.protocolViolation("AVIF irot/EXIF pair differs at pixel\(index / 4) channel\(index % 4): \(a) bits\(a.bitPattern), \(b) bits\(b.bitPattern). Both checked-closed raw frames retained.")
                }
            }
            guard frames[0].raw == frames[1].raw else { throw LensWorksManagedError.protocolViolation("AVIF pair float-byte equality contradicts scalar comparison.") }
            for index in frames.indices {
                frames[index].evidence["comparedPixels"] = 6; frames[index].evidence["comparedScalars"] = 24
                frames[index].evidence["pairPayloadSHA256"] = Self.mathSHA(frames[1 - index].raw)
                frames[index].evidence["pairSource"] = frames[1 - index].proof.filename
                frames[index].evidence["comparison"] = "exact full-frame float bits and oriented2x3 geometry/metadataorientation8; EXIF identity does not override irot; relational only"
                frames[index].evidence["absoluteColorQualified"] = false
                frames[index].evidence["rotationDirectionOracleQualified"] = false
                try finishNonDNG(&frames[index])
            }
        } catch {
            for index in frames.indices { preserveNonDNG(&frames[index], failure: error) }
            throw error
        }
    }

    @Test func actualTenBitAVIFFullFloatMatchesEveryIndependentSwatch() async throws {
        let proof = try tenBitProof()
        var frame = try await decodeNonDNG(proof.frame)
        do {
            var maximumSourceRGBError = 0.0, maximumQuantizedAlphaError = 0.0
            var maximumPrecisionRGBError = 0.0, maximumPrecisionAlphaError = 0.0
            for pixel in 0..<6 { for channel in 0..<4 {
                let actual = Double(frame.samples[pixel * 4 + channel])
                let source = channel == 3 ? proof.quantizedAlpha[pixel] : proof.sourceReference[pixel][channel]
                let sourceTolerance = channel == 3 ? 1.0 / 1023 : 0.003
                let precision = proof.precisionReference[pixel][channel]
                let precisionTolerance = channel == 3 ? proof.precisionAlphaTolerance : proof.precisionRGBTolerance
                let sourceError = abs(actual - source), precisionError = abs(actual - precision)
                guard actual.isFinite, source.isFinite, precision.isFinite,
                      sourceError < sourceTolerance, precisionError < precisionTolerance else {
                    throw LensWorksManagedError.protocolViolation("10-bit AVIF pixel\(pixel) channel\(channel): actual\(actual), source\(source), strict source tolerance\(sourceTolerance), precision reference\(precision), strict precision tolerance\(precisionTolerance), source error\(sourceError), precision error\(precisionError). Full raw frame retained at \(frame.fixture.root.path).")
                }
                if channel == 3 {
                    maximumQuantizedAlphaError = max(maximumQuantizedAlphaError, sourceError)
                    maximumPrecisionAlphaError = max(maximumPrecisionAlphaError, precisionError)
                } else {
                    maximumSourceRGBError = max(maximumSourceRGBError, sourceError)
                    maximumPrecisionRGBError = max(maximumPrecisionRGBError, precisionError)
                }
            } }
            guard frame.descriptor.provenance.source_bits_per_channel == 10,
                  frame.samples[11] == 0, frame.samples[10] > 0.999,
                  frame.samples[7] > 0 && frame.samples[7] < 1 else {
                throw LensWorksManagedError.protocolViolation("10-bit AVIF lost actual10-bit provenance, transparent blue RGB, or partial straight alpha.")
            }
            frame.evidence["comparedPixels"] = 6; frame.evidence["comparedScalars"] = 24
            frame.evidence["maximumSourceRGBError"] = maximumSourceRGBError
            frame.evidence["maximumQuantizedAlphaError"] = maximumQuantizedAlphaError
            frame.evidence["maximumPrecisionRGBError"] = maximumPrecisionRGBError
            frame.evidence["maximumPrecisionAlphaError"] = maximumPrecisionAlphaError
            frame.evidence["RGBToleranceStrict"] = 0.003; frame.evidence["alphaToleranceStrict"] = 1.0 / 1023
            frame.evidence["precisionRGBToleranceStrict"] = proof.precisionRGBTolerance
            frame.evidence["precisionAlphaToleranceStrict"] = proof.precisionAlphaTolerance
            frame.evidence["precisionReference"] = proof.precisionReference
            frame.evidence["comparison"] = "all24 finite straight RGBA samples; sourcePNG color baseline plus independent16-bit ImageIO precision, actual retainedsourcebits10; alpha-zero RGB preserved"
            try finishNonDNG(&frame)
        } catch {
            preserveNonDNG(&frame, failure: error)
            throw error
        }
    }
    private struct TenBitProof {
        let frame: NonDNGProof
        let sourceReference: [[Double]], precisionReference: [[Double]], quantizedAlpha: [Double]
        let precisionRGBTolerance: Double, precisionAlphaTolerance: Double
    }
    private static func inverseSRGB(_ sample: Double) -> Double {
        sample <= 0.04045 ? sample / 12.92 : pow((sample + 0.055) / 1.055, 2.4)
    }
    /// The six straight RGBA8 swatches generate_dng_fixture.py writes into
    /// generated-swatches.png and, at 10 bits, generated-swatches-10bit.avif.
    private static let swatchRGBA8: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 128], [0, 0, 255, 0], [128, 128, 128, 255], [255, 255, 255, 255], [0, 0, 0, 255]]
    private static var swatchLinearRGBA: [[Double]] {
        swatchRGBA8.map { pixel in pixel.enumerated().map { channel, code in
            let sample = Double(code) / 255
            return channel == 3 ? sample : inverseSRGB(sample)
        } }
    }
    private func tenBitProof() throws -> TenBitProof {
        // Independent 16-bit ImageIO decode of the 10-bit AVIF, and the 10-bit
        // alpha codes it stores, recorded once from the checked-in fixture.
        let imageIORGBA16: [[UInt16]] = [[65535, 0, 0, 65535], [0, 65535, 0, 32927], [0, 0, 65535, 0], [32928, 32928, 32928, 65535], [65535, 65535, 65535, 65535], [0, 0, 0, 65535]]
        let alphaCodes10: [Double] = [1023, 514, 0, 1023, 1023, 1023]
        let precision = imageIORGBA16.map { pixel in pixel.enumerated().map { channel, code in
            let sample = Double(code) / 65535
            return channel == 3 ? sample : Self.inverseSRGB(sample)
        } }
        let frame = try nonDNGFrameProof("generated-swatches-10bit.avif", width: 3, height: 2, metadataOrientation: 1, sourceBitsPerChannel: 10, sourceLinearRGBA: nil)
        return TenBitProof(frame: frame, sourceReference: Self.swatchLinearRGBA, precisionReference: precision,
            quantizedAlpha: alphaCodes10.map { $0 / 1023 },
            precisionRGBTolerance: (2.4 / 1.055) / 65535 + 1e-6, precisionAlphaTolerance: 1.0 / 65535 + 1e-6)
    }
    private struct NonDNGProof {
        let filename: String
        let source: URL, sha256: String
        let width: UInt32, height: UInt32, metadataOrientation: UInt32, sourceBitsPerChannel: UInt32
        let sourceLinearRGBA: [[Double]]?
    }
    private struct NonDNGFrame {
        let proof: NonDNGProof
        let fixture: Fixture
        let raw: Data, samples: [Float], descriptor: LWManagedFloatDescriptor
        var evidence: [String: Any]
    }
    private func nonDNGFrameProof(_ filename: String, width: UInt32, height: UInt32, metadataOrientation: UInt32, sourceBitsPerChannel: UInt32, sourceLinearRGBA: [[Double]]?) throws -> NonDNGProof {
        let source = Self.fixtureDirectory.appendingPathComponent(filename)
        let bytes = try Data(contentsOf: source)
        guard !bytes.isEmpty, bytes.count <= 1048576 else { throw LensWorksManagedError.protocolViolation("\(filename) fixture is empty or exceeds 1MiB.") }
        return NonDNGProof(filename: filename, source: source, sha256: Self.mathSHA(bytes), width: width, height: height,
            metadataOrientation: metadataOrientation, sourceBitsPerChannel: sourceBitsPerChannel, sourceLinearRGBA: sourceLinearRGBA)
    }
    private func nonDNGProof(_ filename: String) throws -> NonDNGProof {
        switch filename {
        case "generated-swatches.png":
            return try nonDNGFrameProof(filename, width: 3, height: 2, metadataOrientation: 1, sourceBitsPerChannel: 8, sourceLinearRGBA: Self.swatchLinearRGBA)
        case "generated-irot.avif", "generated-irot-exif.avif":
            // Relational pair only: oriented 2x3 with metadata orientation 8, no absolute color oracle.
            return try nonDNGFrameProof(filename, width: 2, height: 3, metadataOrientation: 8, sourceBitsPerChannel: 8, sourceLinearRGBA: nil)
        default:
            throw LensWorksManagedError.protocolViolation("No non-DNG proof for \(filename).")
        }
    }
    private func decodeNonDNG(_ proof: NonDNGProof) async throws -> NonDNGFrame {
        let inputURL = proof.source
        guard Self.mathSHA(try Data(contentsOf: inputURL)) == proof.sha256 else { throw LensWorksManagedError.protocolViolation("Non-DNG source changed before copying.") }
        let jobs = MathJobs()
        let fixture = try await Fixture.create(copiedSource: inputURL, referenceJobs: jobs)
        var evidence: [String: Any] = ["status": "UNQUALIFIED_DECODE_PENDING", "source": proof.filename,
            "sourceSHA256": proof.sha256, "sourceRevision": fixture.session.sourceRevision,
            "protocol": LWManagedAuthority.protocolVersion, "absoluteAVIFColorQualified": false]
        func unchanged() throws {
            guard Self.mathSHA(try Data(contentsOf: fixture.original)) == proof.sha256,
                  Self.mathSHA(try Data(contentsOf: inputURL)) == proof.sha256,
                  try fixture.original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == fixture.originalModified,
                  Set(try FileManager.default.contentsOfDirectory(atPath: fixture.original.deletingLastPathComponent().path)) == Set([fixture.original.lastPathComponent]) else {
                throw LensWorksManagedError.protocolViolation("A protected non-DNG source SHA, timestamp, or directory membership changed.")
            }
        }
        func encoded<Value: Encodable>(_ value: Value) throws -> LWCatalogJSON { try LWCatalogCodec.decode(LWCatalogJSON.self, from: LWCatalogCodec.encode(value)) }
        func plan(_ id: String) async throws -> LWApplicationExportsDtoPlan {
            let job = try await fixture.session.sourceIdentity(catalog: fixture.catalog, exportJob: id, sequence: LWCatalogI64(1))
            try jobs.retain(job)
            let result = try await jobs.result(job)
            var ownsBuffer = true; defer { if ownsBuffer { result.buffer.release() } }
            let value = try await result.decode(LWApplicationExportsDtoPlan.self, maximumBytes: 1048576)
            result.buffer.release(); ownsBuffer = false; try await jobs.close(job)
            return value
        }
        do {
            try unchanged()
            let beforeReply = try await jobs.perform(fixture.session, .Variant(catalog: fixture.catalog, key: fixture.key))
            guard case .Variant(let before) = beforeReply else { throw unexpected("actual non-DNG Variant", beforeReply) }
            let begunReply = try await jobs.perform(fixture.session, .Export(catalog: fixture.catalog, request: .Begin))
            guard case .Export(.Job(let begun)) = begunReply else { throw unexpected("actual non-DNG export plan owner", begunReply) }
            let destination = fixture.root.appendingPathComponent("NeverPublished.tif")
            let target = LWApplicationExportsDtoTarget(key: fixture.key, expected_revision: before.revision, destination: try LWCatalogNativePath(fileURL: destination), overwrite: false, metadata: .Omit)
            let output = LWApplicationExportsDtoOutput(size: .Original, format: .Tiff(depth: .Float32), profile: .LinearSrgb, alpha: .Preserve)
            let appendedReply = try await jobs.perform(fixture.session, .Export(catalog: fixture.catalog, request: .Append(job: begun.id, expected_total: LWCatalogI64(0), target: target, output: output,
                budgets: LWApplicationExportsDtoBudgets(max_original_bytes: LWCatalogU64(1048576), max_payload_bytes: LWCatalogU64(1048576), alias_limits: LWApplicationExportsDtoAliasLimits(directories: LWCatalogU64(32), candidates: LWCatalogU64(256))))))
            guard case .Export(.Operation(let appended)) = appendedReply, let appended else { throw unexpected("actual non-DNG Append", appendedReply) }
            try await waitUntil {
                let reply = try await jobs.perform(fixture.session, .Export(catalog: fixture.catalog, request: .Status(operation: appended.id)))
                guard case .Export(.Operation(let state)) = reply, let state, state.id == appended.id else { throw unexpected("matching non-DNG Append Status", reply) }
                guard !["failed", "canceled"].contains(state.phase) else { throw unexpected("complete non-DNG Append", reply) }
                return state.phase == "complete"
            }
            _ = try await jobs.perform(fixture.session, .Export(catalog: fixture.catalog, request: .Seal(job: begun.id, expected_total: LWCatalogI64(1))))
            let beforePlan = try await plan(begun.id)
            guard beforePlan.job == begun.id, beforePlan.sequence.value == 1, !beforePlan.authority.isEmpty,
                  beforePlan.original == (try LWCatalogNativePath(fileURL: fixture.original)),
                  beforePlan.identity.key.asset_id == fixture.key.asset_id, beforePlan.identity.key.variant_id == fixture.key.variant_id,
                  beforePlan.identity.revision == before.revision, beforePlan.identity.recipe_digest == before.recipe_digest else { throw LensWorksManagedError.protocolViolation("Real non-DNG Plan lost source/edit authority.") }
            evidence["planBefore"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(beforePlan))
            evidence["variantBefore"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(before))
            let decode = try await fixture.session.decodeFull(catalog: fixture.catalog, exportJob: begun.id, sequence: LWCatalogI64(1),
                limits: .init(max_encoded_bytes: LWCatalogU64(1048576), max_intermediate_pixels: LWCatalogU64(10000), max_allocation_bytes: LWCatalogU64(1048576)),
                workerBytes: LWCatalogU64(536870912), maximumOutputBytes: LWCatalogU64(96))
            try jobs.retain(decode)
            let result = try await jobs.result(decode)
            var ownsBuffer = true; defer { if ownsBuffer { result.buffer.release() } }
            guard case .float(let descriptor) = result.descriptor else { throw LensWorksManagedError.protocolViolation("Expected actual non-DNG full-float descriptor.") }
            let raw = try await result.buffer.copy(maximumBytes: 96, expectedLength: result.length)
            try raw.write(to: fixture.root.appendingPathComponent("Decoded.rgba-f32le"), options: .atomic)
            evidence["payloadSHA256"] = Self.mathSHA(raw); evidence["payloadBytes"] = raw.count
            evidence["descriptor"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(descriptor))
            try writeNonDNG(fixture, evidence)
            guard descriptor.width == proof.width, descriptor.height == proof.height,
                  descriptor.row_stride.value == UInt64(proof.width) * 16, descriptor.byte_length.value == 96, result.length == 96, raw.count == 96,
                  descriptor.channels == 4, descriptor.sample == "float32_le", descriptor.color_space == "linear_srgb",
                  descriptor.alpha == "straight", descriptor.orientation == "applied", descriptor.metadata.orientation == proof.metadataOrientation,
                  descriptor.provenance.source_bits_per_channel == proof.sourceBitsPerChannel, descriptor.protocol == 2, descriptor.source_revision == LWManagedAuthority.sourceRevision, descriptor.source_revision == fixture.session.sourceRevision,
                  descriptor.original == beforePlan.original, descriptor.plan_authority == beforePlan.authority,
                  try encoded(descriptor.source_identity) == encoded(beforePlan.identity),
                  try encoded(descriptor.original_revision) == encoded(beforePlan.original_revision) else { throw LensWorksManagedError.protocolViolation("Non-DNG descriptor lost exact geometry/orientation/bitdepth/protocol/source/Plan authority.") }
            let samples = try await result.floatSamples(maximumBytes: 96)
            result.buffer.release(); ownsBuffer = false; try await jobs.close(decode)
            guard samples.count == 24 else { throw LensWorksManagedError.protocolViolation("Non-DNG frame is not exactly 24 RGBA samples.") }
            for index in samples.indices {
                guard samples[index].isFinite, index % 4 != 3 || (0...1).contains(samples[index]) else { throw LensWorksManagedError.protocolViolation("Non-DNG pixel\(index / 4) channel\(index % 4) is nonfinite or has invalid straight alpha.") }
            }
            let afterPlan = try await plan(begun.id)
            let afterReply = try await jobs.perform(fixture.session, .Variant(catalog: fixture.catalog, key: fixture.key))
            guard case .Variant(let after) = afterReply else { throw unexpected("actual non-DNG Variant after decode", afterReply) }
            guard try encoded(afterPlan) == encoded(beforePlan), try encoded(after) == encoded(before),
                  !FileManager.default.fileExists(atPath: destination.path) else { throw LensWorksManagedError.protocolViolation("Non-DNG source decode changed Plan/recipe authority or published output.") }
            evidence["planAfter"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(afterPlan))
            evidence["variantAfter"] = try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(after))
            try unchanged()
            let close = try await jobs.perform(fixture.session, .Close(catalog: fixture.catalog))
            guard case .Status(let closed) = close, closed.phase == .Closed, closed.catalog == nil else { throw unexpected("checked non-DNG public Close", close) }
            try await fixture.close(); try unchanged()
            evidence["checkedClosed"] = true; evidence["sourceSHA256VerifiedBeforeAfter"] = true
            evidence["status"] = "ACTUAL_DECODE_ONLY_CHECKED_CLOSED_COMPARISON_PENDING"
            try writeNonDNG(fixture, evidence)
            return NonDNGFrame(proof: proof, fixture: fixture, raw: raw, samples: samples, descriptor: descriptor, evidence: evidence)
        } catch {
            let primary = error
            evidence["status"] = "FAILED_UNQUALIFIED"; evidence["failure"] = String(describing: primary); evidence["retainedJobHandles"] = jobs.handles
            do { try unchanged(); evidence["sourceSHA256VerifiedOnFailure"] = true } catch { evidence["sourceVerificationFailure"] = String(describing: error) }
            do { try writeNonDNG(fixture, evidence) } catch { Issue.record("Non-DNG diagnostics could not be written at \(fixture.root.path): \(error)") }
            fixture.cleanup.preserve("Non-DNG decode failed: \(primary). Raw/source authority retained at \(fixture.root.path).")
            do {
                try await jobs.retire()
                let reply = try await jobs.perform(fixture.session, .Close(catalog: fixture.catalog))
                guard case .Status(let closed) = reply, closed.phase == .Closed, closed.catalog == nil else { throw unexpected("non-DNG failure public Close", reply) }
                try await fixture.close()
            } catch {
                fixture.cleanup.preserve("Non-DNG failure: \(primary). Checked cleanup: \(error); retained handles \(jobs.handles).")
                throw LensWorksManagedError.protocolViolation("\(primary); checked cleanup: \(error). Retained fixture: \(fixture.root.path).")
            }
            throw LensWorksManagedError.protocolViolation("\(primary). Checked-closed failed fixture retained at \(fixture.root.path).")
        }
    }
    private func writeNonDNG(_ fixture: Fixture, _ evidence: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        guard bytes.count <= 131072 else { throw LensWorksManagedError.protocolViolation("Non-DNG report exceeded 128KiB.") }
        try bytes.write(to: fixture.root.appendingPathComponent("FullFloatReference.json"), options: .atomic)
    }
    private func preserveNonDNG(_ frame: inout NonDNGFrame, failure: any Error) {
        frame.evidence["status"] = "FAILED_UNQUALIFIED"; frame.evidence["failure"] = String(describing: failure)
        do { try writeNonDNG(frame.fixture, frame.evidence) } catch { Issue.record("Non-DNG comparison failure evidence could not be written: \(error)") }
        frame.fixture.cleanup.preserve("Checked-closed non-DNG comparison failed: \(failure); raw/authority retained at \(frame.fixture.root.path).")
    }
    private func finishNonDNG(_ frame: inout NonDNGFrame) throws {
        frame.evidence["status"] = "ACTUAL_NON_DNG_REFERENCE_PASS_CHECKED_CLOSED"
        try writeNonDNG(frame.fixture, frame.evidence)
        frame.fixture.removeIfClosed()
    }

    private func exportComplete(_ fixture: Fixture, _ reply: LWApplicationResponse) async throws -> LWApplicationExportsDtoOperation {
        guard case .Export(.Operation(let operation)) = reply, let operation else { throw unexpected("Export operation admission", reply) }
        var complete: LWApplicationExportsDtoOperation?
        try await waitUntil {
            let current = try await fixture.session.perform(.Export(catalog: fixture.catalog, request: .Status(operation: operation.id)))
            guard case .Export(.Operation(let state)) = current, let state, state.id == operation.id else { throw unexpected("matching Export.Status", current) }
            if state.phase == "failed" || state.phase == "canceled" { throw unexpected("complete Export operation", current) }
            if state.phase == "complete" { complete = state; return true }
            return false
        }
        return try #require(complete)
    }

    private func unexpected(_ expected: String, _ response: LWApplicationResponse) -> LensWorksManagedError {
        let detail = (try? LWCatalogCodec.encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? String(describing: response)
        return .protocolViolation("Expected \(expected); actual typed reply: \(detail)")
    }

    private static func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw LensWorksManagedError.protocolViolation("Managed fixture timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func waitUntil(_ condition: () async throws -> Bool) async throws { try await Self.waitUntil(condition) }

    private final class Notice: @unchecked Sendable {
        private let lock = NSLock(); private var notices = 0
        var count: Int { lock.withLock { notices } }
        func record(_ session: LWCatalogSessionHandle, _ job: LWCatalogJobHandle) { lock.withLock { notices += 1 } }
    }
    private final class CallbackGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var ready = false, released = false
        private var handle: UInt64 = 0, status: Int32 = -1
        var subscription: UInt64 { get { condition.withLock { handle } } set { condition.withLock { handle = newValue } } }
        var entered: Bool { condition.withLock { ready } }
        var reentrantStatus: Int32 { condition.withLock { status } }
        func callback() {
            condition.lock()
            status = lw_catalog_unsubscribe_and_drain(handle, 0)
            ready = true
            while !released { condition.wait() }
            condition.unlock()
        }
        func open() { condition.withLock { released = true; condition.broadcast() } }
    }
    private final class FixtureCleanup: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false, diagnostic: String?
        private let root: URL, handle: LWCatalogSessionHandle
        init(root: URL, handle: LWCatalogSessionHandle) { self.root = root; self.handle = handle }
        var certifiedClosed: Bool { lock.withLock { closed } }
        func certifyClosed() { lock.withLock { closed = true } }
        func preserve(_ message: String) {
            lock.withLock { diagnostic = message }
            do {
                let bytes = try JSONSerialization.data(withJSONObject: ["session": String(handle.value), "source_revision": LWManagedAuthority.sourceRevision, "protocol": LWManagedAuthority.protocolVersion, "root": root.path, "error": message], options: [.prettyPrinted, .sortedKeys])
                try bytes.write(to: root.appendingPathComponent("RetainedFixtureFailure.json"), options: .atomic)
            } catch { Issue.record("Could not write retained fixture diagnostics at \(root.path): \(error)") }
        }
        func removeIfClosed() {
            let state = lock.withLock { (closed, diagnostic) }
            if state.0 {
                do { try FileManager.default.removeItem(at: root) }
                catch { Issue.record("Closed fixture cleanup failed at \(root.path): \(error)") }
            } else {
                let message = state.1 ?? "Fixture ended without certified checked close; retained owner and files require cleanup."
                preserve(message)
                Issue.record("\(message) Retained fixture artifacts: \(root.path)")
            }
        }
    }
    private struct Fixture: Sendable {
        let root: URL, original: URL, before: Data, originalModified: Date, session: LWManagedSession, catalog: String, key: LWCatalogEditsVariantKey
        let cleanup: FixtureCleanup
        let companions: [URL: Data], companionModified: [URL: Date]
        func expectOriginalUnchanged() throws {
            #expect(try Data(contentsOf: original) == before)
            #expect(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalModified)
            for (url, bytes) in companions {
                #expect(try Data(contentsOf: url) == bytes)
                #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == companionModified[url])
            }
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path)) == Set([original.lastPathComponent] + companions.keys.map(\.lastPathComponent)))
        }
        func close() async throws { try await session.close(); cleanup.certifyClosed() }
        func removeIfClosed() { cleanup.removeIfClosed() }
        func failure(_ primary: any Error) async -> any Error {
            do { try await close(); return primary }
            catch {
                cleanup.preserve("Fixture failed: \(primary). Checked cleanup failed: \(error)")
                return LensWorksManagedError.protocolViolation("Fixture failed: \(primary). Checked cleanup failed: \(error). Retained artifacts: \(root.path)")
            }
        }
        static func create(floatTIFF: Bool = false, metadataConflict: Bool = false, copiedSource: URL? = nil, referenceJobs: MathJobs? = nil) async throws -> Self {
            let worker = try #require(ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"], "Set the explicit owned helper fixture path.")
            let temporaryPath = try #require(realpath(FileManager.default.temporaryDirectory.path, nil), "Resolve the physical temporary directory before admitting source authority.")
            defer { free(temporaryPath) }
            let root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true).appendingPathComponent("LWManaged-\(UUID())")
            let originals = root.appendingPathComponent("Originals")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let source = originals.appendingPathComponent(copiedSource?.lastPathComponent ?? (floatTIFF ? "wide.tif" : "source.png"))
            let data = try copiedSource.map { try Data(contentsOf: $0) } ?? (floatTIFF ? tiff() : Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!)
            try data.write(to: source)
            let originalModified = try #require(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            var companions: [URL: Data] = [:], companionModified: [URL: Date] = [:]
            if metadataConflict {
                for (name, rating) in [("source.xmp", 2), ("source.png.xmp", 4)] {
                    let url = originals.appendingPathComponent(name)
                    let bytes = Data("<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"\(rating)\"/></rdf:RDF>".utf8)
                    try bytes.write(to: url)
                    companions[url] = bytes
                    companionModified[url] = try #require(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                }
            }
            let nativeWorker = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: worker))
            let decodeWorker = ProcessInfo.processInfo.environment["LW_CATALOG_TEST_DECODE_WORKER"] ?? worker
            let nativeDecodeWorker = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: decodeWorker))
            let config = LWManagedSessionConfig(worker_executable: nativeWorker, decode_worker_executable: nativeDecodeWorker, cache_root: nil, original_roots: [try LWCatalogNativePath(fileURL: originals)], limits: nil, preview_policy: nil, preview_limits: nil)
            let session = try await LWManagedSession.create(config: config)
            func perform(_ request: LWApplicationRequest) async throws -> LWApplicationResponse {
                if let referenceJobs { return try await referenceJobs.perform(session, request) }
                return try await session.perform(request)
            }
            do {
                guard case .Status(let opened) = try await perform(.Create(path: LWCatalogNativePath(fileURL: root.appendingPathComponent("Catalog")))), let catalog = opened.catalog else { throw LensWorksManagedError.protocolViolation("Expected admitted catalog token") }
                try await LensWorksManagedCatalogTests.waitUntil {
                    guard case .Status(let status) = try await perform(.Status) else { return false }
                    return status.phase == .Ready
                }
                _ = try await perform(.ImportStart(catalog: catalog, source: LWCatalogNativePath(fileURL: originals)))
                try await LensWorksManagedCatalogTests.waitUntil {
                    guard case .Import(let status) = try await perform(.ImportStatus(catalog: catalog)), let status else { return false }
                    if status.phase == .Failed { throw LensWorksManagedError.protocolViolation(status.error ?? "Import failed") }
                    return status.phase == .Complete
                }
                guard case .Images(let rows, _, _, _, _) = try await perform(.Images(catalog: catalog, folder: nil, recursive: true, text: nil, cursor: nil, limit: 10)), let image = rows.first else { throw LensWorksManagedError.protocolViolation("Expected real imported image") }
                return Self(root: root, original: source, before: data, originalModified: originalModified, session: session, catalog: catalog, key: image.key, cleanup: FixtureCleanup(root: root, handle: session.handle), companions: companions, companionModified: companionModified)
            } catch {
                let primary = error
                do {
                    if let referenceJobs {
                        try await referenceJobs.retire()
                        let stateReply = try await referenceJobs.perform(session, .Status)
                        guard case .Status(let state) = stateReply else { throw LensWorksManagedError.protocolViolation("Math fixture creation cleanup needs actual public Status.") }
                        if let token = state.catalog {
                            let reply = try await referenceJobs.perform(session, .Close(catalog: token))
                            guard case .Status(let closed) = reply, closed.phase == .Closed, closed.catalog == nil else { throw LensWorksManagedError.protocolViolation("Math fixture creation retains public catalog authority.") }
                        } else {
                            guard [.Closed, .Failed].contains(state.phase) else { throw LensWorksManagedError.protocolViolation("Math fixture creation has no certified no-catalog status.") }
                        }
                    }
                    try await session.close()
                    if referenceJobs == nil { try FileManager.default.removeItem(at: root) }
                    else { FixtureCleanup(root: root, handle: session.handle).preserve("Checked-closed math fixture creation failed: \(primary).") }
                } catch {
                    let cleanup = FixtureCleanup(root: root, handle: session.handle)
                    cleanup.preserve("Fixture creation failed: \(primary). Checked cleanup failed: \(error)")
                    throw LensWorksManagedError.protocolViolation("Fixture creation failed: \(primary). Checked cleanup failed: \(error). Retained artifacts: \(root.path)")
                }
                throw primary
            }
        }
        private static func tiff() -> Data {
            var data = Data()
            func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
            func u32(_ value: UInt32) { u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16)) }
            data.append(contentsOf: [73, 73]); u16(42); u32(8); u16(11)
            for (tag, type, count, value): (UInt16, UInt16, UInt32, UInt32) in [(256,4,1,2),(257,4,1,2),(258,3,4,146),(259,3,1,1),(262,3,1,2),(273,4,1,162),(277,3,1,4),(278,4,1,2),(279,4,1,64),(338,3,1,2),(339,3,4,154)] {
                u16(tag); u16(type); u32(count); u32(value)
            }
            u32(0); for _ in 0..<4 { u16(32) }; for _ in 0..<4 { u16(3) }
            for sample: Float in [-0.2,4,0.3,1,0.1,0.5,0.8,0.5,2,-0.1,0.3,0,0.3,0.4,0.5,1] { u32(sample.bitPattern) }
            return data
        }
    }
}
