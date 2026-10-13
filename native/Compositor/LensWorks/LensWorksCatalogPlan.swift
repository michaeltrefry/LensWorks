import Foundation
import Darwin
import CryptoKit

nonisolated struct LensWorksCatalogPlan: Decodable, Sendable {
    let version: Int
    let actions: [Action]
    struct Action: Decodable, Sendable {
        let kind: String
        var path: String?
        var parentPath: String?
        var folderPath: String?
        var groupName: String?
        var name: String?
        var newName: String?
        var recursive: Bool?
        var text: String?
        var filename: String?
        var variantID: String?
        var phase: String?
        var minimumImported: LWCatalogU64?
        var timeoutMilliseconds: UInt32?
        var exposureEV: Double?
        var count: Int?
        var direction: String?
        var sort: LWOrganizationSearchSort?
        var range: Bool?
        var extending: Bool?
        var thumbnailBytes: LWCatalogU64?
        var largeBytes: LWCatalogU64?
        var paths: [String]?
        var tier: LWPreviewStoreTier?
        var objects: UInt16?
        var bytes: LWCatalogU64?
        var directories: UInt16?
    }
    static func read(_ path: String) async throws -> Self {
        try await Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard data.count <= 1024 * 1024 else { throw LensWorksCatalogError.message("Catalog action plan exceeds 1 MiB.") }
            let plan = try JSONDecoder().decode(Self.self, from: data)
            guard plan.version == 1, (1...64).contains(plan.actions.count) else { throw LensWorksCatalogError.message("Catalog action plan requires version 1 and 1–64 actions.") }
            return plan
        }.value
    }
}

@MainActor
extension LensWorksCatalog {
    private func wire<Value: Encodable & Sendable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(value), options: [.fragmentsAllowed])
    }
    private func identityRows() -> [[String: Any]] {
        assets.map { row in
            ["image_id": row.id, "asset_id": row.photoID, "variant_id": row.key?.variant_id ?? "",
             "sequence": String(row.sequence), "metadata_revision": String(row.metadataRevision), "filename": row.filename, "state": row.state]
        }
    }
    private func pageDigest() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: identityRows(), options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func snapshot() async throws -> [String: Any] {
        var value: [String: Any] = ["catalogPath": catalogPath ?? "", "catalogToken": catalogToken ?? "",
            "rows": identityRows(), "rowCount": assets.count, "rowsHighWater": rowsHighWater,
            "selectionCount": String(selectionCount), "selectionProjectionCount": selection.count,
            "versionRows": versions.count, "versionRowsHighWater": versionsHighWater, "versionDiscoveryScanned": versionDiscoveryScanned, "versionDiscoveryPending": versionDiscoveryPending,
            "hasMore": hasMore, "pageComplete": pageComplete, "scanned": scanned,
            "cursorHistoryCount": cursorHistoryCount, "cursorHistoryLimit": 64, "currentCursor": currentCursor ?? "", "nextCursor": nextCursor ?? "",
            "navigationResidency": navigationResidency,
            "pagePublication": pagePublication, "staleCursorRestarts": staleCursorRestarts,
            "navigationHighWater": navigationHighWater,
            "selectedImageID": selectedPhotoID ?? "", "selectedPhotoID": selectedAsset?.photoID ?? "",
            "folders": try wire(folders), "groups": try wire(groups), "placements": try wire(placements),
            "previewMetrics": try wire(await service.previewMetrics())]
        if let importProgress { value["import"] = try wire(importProgress) }
        value["importSamples"] = try wire(importSamples)
        if let previewSettings { value["previewSettings"] = try wire(previewSettings) }
        return value
    }
    /// Text action plans enter through canonical UTF-8 paths; native navigation keeps opaque bytes.
    func folder(at path: String) async throws -> LWApplicationDtoFolder {
        try admitCatalogWork()
        let epoch = catalogEpoch, startingNavigation = folderNavigationGeneration
        let wanted = try await Task.detached(priority: .utility) {
            guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 32768,
                  let canonical = path.withCString({ Darwin.realpath($0, nil) }) else {
                throw LensWorksCatalogError.message("The physical folder is unavailable.")
            }
            defer { free(canonical) }
            guard let physical = String(validatingUTF8: canonical) else { throw LensWorksCatalogError.message("This folder path cannot be represented in the action plan.") }
            return LWCatalogNativePath.unixBytes(Array(physical.utf8))
        }.value
        guard catalogEpoch == epoch, folderNavigationGeneration == startingNavigation else { throw CancellationError() }
        return try await folder(at: wanted)
    }
    /// Walk the retained byte-component hierarchy with at most one admitted sibling page in memory.
    func folder(at path: LWCatalogNativePath) async throws -> LWApplicationDtoFolder {
        try admitCatalogWork()
        let wanted = try path.physicalFolderUnits()
        let epoch = catalogEpoch, startingNavigation = folderNavigationGeneration
        let depth = wanted.split(separator: 47).count + 1
        var navigation = startingNavigation &+ 1
        try await loadFolders()
        for _ in 0..<depth {
            var nearest: LWApplicationDtoFolder?
            while nearest == nil {
                try Task.checkCancellation()
                guard catalogEpoch == epoch, folderNavigationGeneration == navigation else { throw CancellationError() }
                nearest = folders.filter { folder in
                    guard let location = try? folder.locator.physicalFolderUnits() else { return false }
                    return location == wanted || wanted.starts(with: location == [47] ? [47] : location + [47])
                }.max { ((try? $0.locator.physicalFolderUnits().count) ?? 0) < ((try? $1.locator.physicalFolderUnits().count) ?? 0) }
                if nearest == nil {
                    guard let after = folderNext else { throw LensWorksCatalogError.message("The physical folder was not found in this catalog.") }
                    navigation &+= 1
                    try await loadFolders(parent: folderParent, after: after)
                }
            }
            guard let nearest, catalogEpoch == epoch, folderNavigationGeneration == navigation else { throw CancellationError() }
            if try nearest.locator.physicalFolderUnits() == wanted { return nearest }
            navigation &+= 1
            try await loadFolders(parent: nearest)
        }
        throw LensWorksCatalogError.message("The physical folder was not found in this catalog.")
    }
    func executeCatalogPlan(_ path: String) async throws {
        let plan = try await LensWorksCatalogPlan.read(path)
        catalogJourney = []
        for (index, action) in plan.actions.enumerated() {
            var additional: [String: Any] = [:]
            do {
                func required(_ value: String?) throws -> String {
                    guard let value, !value.isEmpty else { throw LensWorksCatalogError.message("Catalog action " + action.kind + " requires its path/name.") }
                    return value
                }
                switch action.kind {
                case "create", "open":
                    await connect(try required(action.path), create: action.kind == "create")
                    guard catalogPath != nil else { throw LensWorksCatalogError.message(error ?? "Catalog admission failed.") }
                case "startImport", "resumeImport": try await startImport(action.path, resume: action.kind == "resumeImport")
                case "waitImport": try await waitImport(terminal: false, minimumImported: action.minimumImported?.value, phase: action.phase, timeoutMilliseconds: action.timeoutMilliseconds ?? 60000)
                case "observeImport":
                    do {
                        try await waitImport(terminal: true, timeoutMilliseconds: action.timeoutMilliseconds ?? 60000)
                        additional["importObservationTimedOut"] = false
                    } catch LensWorksCatalogError.importObservationTimeout(let status) {
                        additional["importObservationTimedOut"] = true
                        additional["observedImport"] = try wire(status)
                    }
                case "finishImport": try await waitImport(terminal: true, timeoutMilliseconds: action.timeoutMilliseconds ?? 60000)
                case "cancelImport": try await cancelImport()
                case "folders":
                    let parent: LWApplicationDtoFolder?
                    if let path = action.parentPath { parent = try await folder(at: path) } else { parent = nil }
                    try await loadFolders(parent: parent)
                case "nextFolders": await nextFolders()
                case "nextGroups": await nextGroups()
                case "browse":
                    let physical: LWApplicationDtoFolder?
                    if let path = action.folderPath { physical = try await folder(at: path) } else { physical = nil }
                    let groupID = try action.groupName.map { try group(named: $0).id }
                    try await browse(folder: physical, collection: groupID, recursive: action.recursive ?? true, text: action.text)
                case "setBrowseOrder":
                    guard let sort = action.sort, let direction = action.direction.flatMap(LWOrganizationSearchDirection.init(rawValue:)) else { throw LensWorksCatalogError.message("Supply a retained sort and direction.") }
                    await setBrowseOrder(sort: sort, direction: direction)
                case "placeGroup":
                    let selected = try group(named: required(action.groupName))
                    let parent = try action.name.map { try group(named: $0).id }
                    try await placeGroup(selected, parent: parent)
                case "refresh": await refresh()
                case "nextPage":
                    guard await nextPage() else { throw LensWorksCatalogError.message("The requested next page did not advance its query authority.") }
                case "previousPage":
                    guard await previousPage() else { throw LensWorksCatalogError.message("The requested previous page did not advance its query authority.") }
                case "walkPages":
                    let count = action.count ?? 0
                    guard (1...256).contains(count), ["next", "previous"].contains(action.direction ?? "") else { throw LensWorksCatalogError.message("Paging walk requires next/previous and 1–256 steps.") }
                    var steps: [[String: Any]] = []
                    for step in 0..<count {
                        guard action.direction == "next" ? hasMore : hasPrevious else { break }
                        let advanced = action.direction == "next" ? await nextPage() : await previousPage()
                        guard advanced else { throw LensWorksCatalogError.message("Paging stopped without an admitted page advancement.") }
                        if let error { throw LensWorksCatalogError.message(error) }
                        steps.append(["step": step + 1, "rowCount": assets.count, "firstImageID": assets.first?.id ?? "", "lastImageID": assets.last?.id ?? "", "pageDigest": try pageDigest(), "hasMore": hasMore, "pageComplete": pageComplete, "scanned": scanned, "cursorHistoryCount": cursorHistoryCount])
                    }
                    additional["pagingSteps"] = steps
                case "selectCurrentPage": await selectCurrentPage()
                case "clearSelection": await clearSelection()
                case "select":
                    let matches = assets.filter { $0.filename == action.filename && (action.variantID == nil || $0.key?.variant_id == action.variantID) }
                    guard matches.count == 1, let row = matches.first else { throw LensWorksCatalogError.message("Photo selection requires one exact logical row on the current page.") }
                    await select(row, extending: action.extending ?? false, range: action.range ?? false)
                case "createGroup": try await createGroup(try required(action.name))
                case "renameGroup": try await renameGroup(try group(named: required(action.name)), name: required(action.newName))
                case "deleteGroup": try await deleteGroup(try group(named: required(action.name)))
                case "addSelectedToGroup": try await setSelectedMembership(try group(named: required(action.name)))
                case "removeSelectedFromGroup": try await setSelectedMembership(try group(named: required(action.name)), remove: true)
                case "preview":
                    var results: [[String: Any]] = []
                    for row in assets {
                        let previewTier: LWApplicationDtoPreviewTier = action.tier == .Large ? .Large : .Thumbnail
                        let value = try await thumbnail(row, tier: previewTier)
                        let original = try await service.resolve(row)
                        results.append(["image_id": row.id, "asset_id": row.photoID, "variant_id": row.key?.variant_id ?? "",
                            "filename": row.filename, "tier": previewTier.rawValue, "width": value.width, "height": value.height, "samples": try wire(value.samples),
                            "colorSpace": value.colorSpace, "alpha": value.alpha, "encodedBytes": value.data.count, "encodedSHA256": SHA256.hash(data: value.data).map { String(format: "%02x", $0) }.joined(),
                            "status": try wire(value.status), "original": try wire(original.nativeOriginal)])
                    }
                    additional["previews"] = results
                case "editPreview":
                    guard let key = selectedAsset?.key, let exposure = action.exposureEV, exposure.isFinite else { throw LensWorksCatalogError.message("Select a photo and supply finite exposure.") }
                    let before = try await service.variant(key)
                    let after = try await service.setExposure(key, value: Float(exposure))
                    await invalidateSemantic(key, row: selectedAsset) // the photo's pixels changed: its embedding is owed again
                    await service.cancelPreviews()
                    await refresh()
                    additional["beforeVariant"] = try wire(before); additional["afterVariant"] = try wire(after)
                case "previewSettings": try await settings()
                case "setPreviewBudgets":
                    guard let thumbnail = action.thumbnailBytes, let large = action.largeBytes else { throw LensWorksCatalogError.message("Supply canonical byte budgets.") }
                    try await settings(.SetBudgets(thumbnail_bytes: thumbnail, large_bytes: large))
                case "beginRootReview":
                    guard let paths = action.paths, !paths.isEmpty else { throw LensWorksCatalogError.message("Choose original root paths to review.") }
                    try await settings(.BeginOriginalRootReview(roots: paths.map { try LWCatalogNativePath(fileURL: URL(fileURLWithPath: $0)) }))
                case "stepRootReview":
                    try await settings()
                    guard let review = previewSettings?.original_roots.review else { throw LensWorksCatalogError.message("There is no root review to step.") }
                    try await settings(.StepOriginalRootReview(review: review, directories: action.directories ?? 32))
                case "beginRelocation":
                    guard let tier = action.tier else { throw LensWorksCatalogError.message("Choose thumbnail or large tier.") }
                    try await settings(.BeginRelocation(tier: tier, destination: LWCatalogNativePath(fileURL: URL(fileURLWithPath: required(action.path)))))
                case "stepRelocation":
                    try await settings()
                    guard let tier = action.tier ?? previewSettings?.relocation_tier else { throw LensWorksCatalogError.message("There is no pending preview move.") }
                    try await settings(.StepRelocation(tier: tier, objects: action.objects ?? 32, bytes: action.bytes ?? LWCatalogU64(16 * 1024 * 1024)))
                case "pauseSettings": await finishSettingsPause(); try await settings()
                case "resumeSettings": resumeSettingsWork()
                case "waitSettings": try await waitSettings(timeoutMilliseconds: action.timeoutMilliseconds ?? 60_000)
                case "resumePreviews": await resumePreviews()
                case "close": try await close()
                case "reopen":
                    guard let path = lastClosedCatalogPath else { throw LensWorksCatalogError.message("There is no closed catalog to reopen.") }
                    await connect(path)
                    guard catalogPath != nil else { throw LensWorksCatalogError.message(error ?? "Catalog reopen failed.") }
                default: throw LensWorksCatalogError.message("Unknown catalog plan action: " + action.kind)
                }
                if let error { throw LensWorksCatalogError.message(error) }
                var evidence = try await snapshot()
                evidence["action"] = action.kind; evidence["index"] = index; evidence["status"] = "ok"
                evidence.merge(additional) { _, new in new }
                catalogJourney.append(evidence)
            } catch {
                var evidence = (try? await snapshot()) ?? [:]
                evidence["action"] = action.kind; evidence["index"] = index; evidence["status"] = "error"; evidence["error"] = error.localizedDescription
                catalogJourney.append(evidence)
                throw error
            }
        }
    }
    func writeCatalogEvidence(_ path: String?, workspace: ProjectWorkspace) async {
        guard let path else { return }
        do {
            var evidence = try await snapshot()
            evidence["catalogJourney"] = catalogJourney; evidence["error"] = error ?? ""
            evidence["assetCount"] = assets.count
            evidence["versionID"] = workspace.current.controller.workingVersion?.id.uuidString ?? ""
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try await Task.detached(priority: .utility) { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }.value
        } catch { self.error = error.localizedDescription }
    }
}

nonisolated extension LWCatalogNativePath {
    func physicalFolderUnits() throws -> [UInt8] {
        guard case .unixBytes(let units) = self, units.first == 47, units.count <= 32768, !units.contains(0),
              units == [47] || (units.last != 47 && !units.split(separator: 47).contains(where: { Array($0) == [46] || Array($0) == [46, 46] })) else {
            throw LensWorksManagedError.protocolViolation("Physical navigation requires an absolute native Unix folder path without a platform conversion.")
        }
        return units
    }
    func parentPhysicalFolder() throws -> LWCatalogNativePath {
        let units = try physicalFolderUnits()
        guard units != [47], let separator = units.lastIndex(of: 47) else { throw LensWorksManagedError.protocolViolation("The root folder has no parent.") }
        return .unixBytes(separator == 0 ? [47] : Array(units[..<separator]))
    }
}
