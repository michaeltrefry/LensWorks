import Foundation
import Darwin
import Testing
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

    @Test func managedSourceAndProtocolMatchApprovedDependencyLedger() throws {
        struct Ledger: Decodable { struct Pin: Decodable { let revision: String }; let PhotoCatalog: Pin }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: root.appendingPathComponent("DEPENDENCIES.json")))
        #expect(LWManagedAuthority.sourceRevision == ledger.PhotoCatalog.revision)
        #expect(LWManagedAuthority.protocolVersion == 2)
        for revision in ["", "wrong-source", String(repeating: "0", count: 40)] {
            let data = try JSONEncoder().encode(["session": "1", "phase": "ready", "source_revision": revision])
            #expect(throws: LensWorksManagedError.self) { try LWCatalogCodec.decode(LWManagedSessionAdmission.self, from: data) }
        }
        // Authority is checked before the remaining descriptor fields, so unsupported
        // protocol/source fixtures cannot be admitted even if geometry looks plausible.
        for (revision, version) in [(ledger.PhotoCatalog.revision, 1), (ledger.PhotoCatalog.revision, 3), ("wrong-source", 2)] {
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
        static func create(floatTIFF: Bool = false, metadataConflict: Bool = false) async throws -> Self {
            let worker = try #require(ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"], "Set the explicit owned helper fixture path.")
            let temporaryPath = try #require(realpath(FileManager.default.temporaryDirectory.path, nil), "Resolve the physical temporary directory before admitting source authority.")
            defer { free(temporaryPath) }
            let root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true).appendingPathComponent("LWManaged-\(UUID())")
            let originals = root.appendingPathComponent("Originals")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let source = originals.appendingPathComponent(floatTIFF ? "wide.tif" : "source.png")
            let data = floatTIFF ? tiff() : Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
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
            do {
                guard case .Status(let opened) = try await session.perform(.Create(path: LWCatalogNativePath(fileURL: root.appendingPathComponent("Catalog")))), let catalog = opened.catalog else { throw LensWorksManagedError.protocolViolation("Expected admitted catalog token") }
                try await LensWorksManagedCatalogTests.waitUntil {
                    guard case .Status(let status) = try await session.perform(.Status) else { return false }
                    return status.phase == .Ready
                }
                _ = try await session.perform(.ImportStart(catalog: catalog, source: LWCatalogNativePath(fileURL: originals)))
                try await LensWorksManagedCatalogTests.waitUntil {
                    guard case .Import(let status) = try await session.perform(.ImportStatus(catalog: catalog)), let status else { return false }
                    if status.phase == .Failed { throw LensWorksManagedError.protocolViolation(status.error ?? "Import failed") }
                    return status.phase == .Complete
                }
                guard case .Images(let rows, _, _, _, _) = try await session.perform(.Images(catalog: catalog, folder: nil, recursive: true, text: nil, cursor: nil, limit: 10)), let image = rows.first else { throw LensWorksManagedError.protocolViolation("Expected real imported image") }
                return Self(root: root, original: source, before: data, originalModified: originalModified, session: session, catalog: catalog, key: image.key, cleanup: FixtureCleanup(root: root, handle: session.handle), companions: companions, companionModified: companionModified)
            } catch {
                let primary = error
                do {
                    try await session.close()
                    try FileManager.default.removeItem(at: root)
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
