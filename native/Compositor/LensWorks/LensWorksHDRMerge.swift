import Foundation
import SwiftUI
import ImageIO
import CryptoKit

nonisolated struct LensWorksHDRMergeOutcome: Sendable {
    let dng: URL
    let provenance: LWHDRMergeProvenance
    let asset: LensWorksCatalogAsset
    let result: LWHDRMergeResult
}

extension LensWorksCatalog {
    var isMergingHDR: Bool { hdrMerge != nil }
    /// Why Merge to HDR… is unavailable now, or nil when the selection can be merged.
    /// Pixel dimensions are not part of a catalog row, so the memory budget is checked by
    /// `mergeSelectionToHDR` once the first photo is developed.
    func hdrMergeAvailability() -> String? {
        guard catalogPath != nil, !closingRequested else { return "Open a catalog first." }
        guard !isMergingHDR else { return "A merge to HDR is already running." }
        guard !isBusy, !isImporting else { return "Finish the current catalog action first." }
        guard selectionCount >= 2 else { return "Select two or more bracketed photos." }
        guard selectionCount <= Int64(LWHDRMerger.maximumFrames) else { return "Select at most \(LWHDRMerger.maximumFrames) bracketed photos." }
        return nil
    }
    /// Why the running merge cannot be cancelled now, or nil when it can.
    var hdrMergeCancelReason: String? {
        guard isMergingHDR else { return "No merge to HDR is running." }
        return hdrMergeAdmitting ? "The merged photo is already being added to the catalog." : nil
    }
    /// Cancels the running merge: nothing is written beside the photos or added to the catalog.
    func cancelHDRMerge() { if hdrMergeCancelReason == nil { hdrMerge?.cancel() } }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs blocking work off the main actor. Cancelling the caller cancels the work, so its
    /// `Task.checkCancellation()` calls fire.
    nonisolated static func detached<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Develops one original through the editor's source development and loads it for the merge
    /// in bounded row strips. `frames` is the size of the bracket it belongs to: the merge's
    /// memory budget is checked as soon as the dimensions are known, before the frame is loaded.
    nonisolated static func developHDRFrame(original: LWCatalogNativePath, url: URL, frames: Int = 1, budget: Int = LWHDRMerger.budgetBytes) async throws -> LWHDRFrame {
        let (node, plane) = try await LWSourceDeveloper.shared.createPlane(original: original, rawHint: RawImporter.matches(url))
        try LWHDRMerger.admit(frames: frames, width: plane.width, height: plane.height, budget: budget)
        let whiteLevel = try node.neutralClip()
        return try await detached { try LWHDRFrame(plane: plane, whiteLevel: whiteLevel) }
    }

    /// Moves `source` to `<stem>.dng` in `folder`, or `<stem>-2.dng`, `-3`… when that name is
    /// taken. An existing file is never replaced.
    nonisolated static func moveWithoutReplacing(_ source: URL, into folder: URL, stem: String) throws -> URL {
        for suffix in 1...10_000 {
            let destination = folder.appendingPathComponent(suffix == 1 ? stem + ".dng" : "\(stem)-\(suffix).dng")
            if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            if errno == ENOTSUP, !FileManager.default.fileExists(atPath: destination.path) {
                // The volume has no exclusive rename; moveItem still refuses an existing destination.
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }
            guard errno == EEXIST || errno == ENOTSUP else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Merges the selected bracket into a new linear floating-point DNG beside the first source,
    /// imports that one file into this catalog, records its sources against it and selects it.
    /// Sources are only read; their bytes are re-verified before the DNG is put in place.
    /// Cancelling (the Cancel command, the calling task, or the catalog scope ending) stops the
    /// merge and leaves no file.
    func mergeSelectionToHDR(deghost: Bool = true) async throws -> LensWorksHDRMergeOutcome {
        try admitCatalogWork()
        if let reason = hdrMergeAvailability() { throw LensWorksCatalogError.message(reason) }
        let scope = captureScope()
        let task = Task { try await self.performHDRMerge(deghost: deghost, scope: scope) }
        hdrMerge = task; hdrMergeAdmitting = false
        defer { hdrMerge = nil; hdrMergeAdmitting = false }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            // Work interrupted by the cancel may surface its own error; it is still a cancel.
            guard error is CancellationError || task.isCancelled else { throw error }
            if scopeIsCurrent(scope) { status = "Merge to HDR canceled. Nothing was added to the catalog." }
            throw CancellationError()
        }
    }

    private func performHDRMerge(deghost: Bool, scope: LensWorksCatalogScope) async throws -> LensWorksHDRMergeOutcome {
        let owner = selectionOwnerForCommands
        let written: (url: URL, provenance: LWHDRMergeProvenance, result: LWHDRMergeResult, sources: [LensWorksDerivedSource])
        // The file this merge has created and the catalog has not admitted: removed on any failure.
        var pending: URL?
        do {
            do {
                let busy = beginBusy(); defer { finishBusy(busy) }
                status = "Merging bracketed photos to HDR…"
                let rows = try await index.selection(owner: owner)
                try checkScope(scope); try Task.checkCancellation()
                guard Int64(rows.count) == selectionCount else {
                    throw LensWorksCatalogError.message("The selection changed while Merge to HDR was starting. Try again.")
                }
                guard rows.count >= 2 else { throw LWHDRMergeError.tooFewFrames }
                guard rows.count <= LWHDRMerger.maximumFrames else { throw LWHDRMergeError.tooManyFrames }
                var originals: [(row: LensWorksSelectedRow, native: LWCatalogNativePath, url: URL, hash: String)] = []
                for row in rows {
                    let native = try await service.originalLocation(row.key)
                    try checkScope(scope)
                    let url = try native.localFileURL()
                    guard (try? url.checkResourceIsReachable()) == true else {
                        throw LensWorksCatalogError.message("“\(url.lastPathComponent)” is offline. Reconnect its location before merging.")
                    }
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        throw LensWorksCatalogError.message("“\(url.lastPathComponent)” is not a photo file.")
                    }
                    originals.append((row, native, url, try await Self.detached { try Self.sha256(url) }))
                    try checkScope(scope)
                }
                var frames: [LWHDRFrame] = []
                for (number, original) in originals.enumerated() {
                    status = "Developing photo \(number + 1) of \(originals.count) for the HDR merge…"
                    frames.append(try await Self.developHDRFrame(original: original.native, url: original.url, frames: originals.count))
                    try checkScope(scope); try Task.checkCancellation()
                }
                status = "Merging \(frames.count) photos to HDR…"
                let result = try await Self.detached { [frames] in try LWHDRMerger.merge(frames, options: LWHDRMergeOptions(deghost: deghost)) }
                frames = []  // Not needed for the write.
                try checkScope(scope)
                let reference = originals[result.referenceIndex].url
                let provenance = LWHDRMergeProvenance(documentID: UUID().uuidString, deghost: deghost, referenceIndex: result.referenceIndex,
                    baselineExposure: Double(-log2(LWHDRDNGWriter.normalization(result))), sources: originals.indices.map { index in
                        LWHDRMergeProvenance.Source(catalogImageID: originals[index].row.imageID, assetID: originals[index].row.key.asset_id,
                            variantID: originals[index].row.key.variant_id, fileName: originals[index].url.lastPathComponent, sha256: originals[index].hash,
                            relativeExposureEV: log2(result.exposures[index]), offset: result.offsets[index], profile: Self.profileName(originals[index].url))
                    })
                let folder = originals[0].url.deletingLastPathComponent()
                let stem = reference.deletingPathExtension().lastPathComponent + "-HDR"
                // Written under a hidden temporary name (not an importable extension) and moved into place whole.
                let temporary = folder.appendingPathComponent(".\(stem)-\(UUID().uuidString).lwhdr-partial")
                let hashes = originals.map { (url: $0.url, hash: $0.hash) }
                status = "Writing the merged HDR photo…"
                pending = temporary
                let destination = try await Self.detached {
                    try LWHDRDNGWriter.write(result, provenance: provenance, reference: Self.referenceMetadata(reference), to: temporary)
                    for original in hashes {
                        try Task.checkCancellation()
                        guard try Self.sha256(original.url) == original.hash else {
                            throw LensWorksCatalogError.message("“\(original.url.lastPathComponent)” changed while merging; nothing was added to the catalog.")
                        }
                    }
                    try Task.checkCancellation()
                    return try Self.moveWithoutReplacing(temporary, into: folder, stem: stem)
                }
                pending = destination
                written = (destination, provenance, result, originals.map {
                    LensWorksDerivedSource(imageID: $0.row.imageID, assetID: $0.row.key.asset_id, variantID: $0.row.key.variant_id, filename: $0.url.lastPathComponent)
                })
            }
            try checkScope(scope); try Task.checkCancellation()
            #if DEBUG
            try await hdrMergeWrittenFixture?(written.url)
            try checkScope(scope); try Task.checkCancellation()
            #endif
            guard let catalogPath else { throw CancellationError() }
            // From here the engine may admit the file at any moment: no cancel, and the file stays
            // unless the import ends without it.
            hdrMergeAdmitting = true
            status = "Adding the merged HDR photo to the catalog…"
            let asset: LensWorksCatalogAsset
            do { asset = try await importOriginal(written.url) }
            catch {
                // The file is removed only when the import has ended without admitting it. While it is
                // still importing, or once the catalog scope is gone, the engine owns the outcome.
                var admitted = true
                if scopeIsCurrent(scope), !isImporting { do { admitted = try await recentCatalogRow(original: written.url) != nil } catch {} }
                if admitted { pending = nil }
                throw error
            }
            pending = nil
            try await index.recordSources(catalog: catalogPath, image: asset.id, sources: written.sources)
            try checkScope(scope)
            status = "Merged \(written.sources.count) photos to HDR: \(written.url.lastPathComponent)"
            return LensWorksHDRMergeOutcome(dng: written.url, provenance: written.provenance, asset: asset, result: written.result)
        } catch {
            if let pending { try? FileManager.default.removeItem(at: pending) }
            throw error
        }
    }

    nonisolated static func profileName(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyProfileName] as? String
    }

    /// Capture metadata of the reference frame, carried into the merged photo's XMP.
    nonisolated static func referenceMetadata(_ url: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var values: [String: String] = [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let make = tiff[kCGImagePropertyTIFFMake] as? String { values["tiff:Make"] = make }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { values["tiff:Model"] = model }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { values["aux:Lens"] = lens }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            // EXIF "YYYY:MM:DD HH:MM:SS" → XMP ISO 8601.
            let parts = date.split(separator: " ")
            if parts.count == 2 { values["exif:DateTimeOriginal"] = parts[0].replacingOccurrences(of: ":", with: "-") + "T" + parts[1] }
        }
        return values
    }
}

/// The catalog toolbar's registered Merge to HDR… command with its availability reason; while a
/// merge runs, its progress and the registered Cancel Merge to HDR command.
struct LensWorksHDRMergeButton: View {
    let catalog: LensWorksCatalog
    let workspace: ProjectWorkspace
    @State private var confirming = false
    @State private var deghost = true
    var body: some View {
        HStack(spacing: 6) {
            if catalog.isMergingHDR {
                ProgressView().controlSize(.small)
                LensWorksCommandButton(.cancelMergeHDR, reason: catalog.hdrMergeCancelReason) { catalog.cancelHDRMerge() }
                    .accessibilityIdentifier(LensWorksCommandID.cancelMergeHDR.rawValue)
            } else {
                LensWorksCommandButton(.mergeHDR, reason: catalog.hdrMergeAvailability()) { confirming = true }
                    .accessibilityIdentifier(LensWorksCommandID.mergeHDR.rawValue)
            }
        }
            .sheet(isPresented: $confirming) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Merge \(catalog.selectionCount) Photos to HDR").font(.headline)
                    Text("Creates a new linear floating-point DNG beside the first photo and adds it to the catalog. The originals are not changed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Deghost moving subjects", isOn: $deghost).accessibilityIdentifier("LensWorks.hdrDeghost")
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { confirming = false }.registeredCommandShortcut(.cancel, role: .cancelAction)
                        Button("Merge") {
                            confirming = false
                            let deghost = deghost
                            Task {
                                let scope = catalog.captureScope()
                                do {
                                    _ = try await catalog.mergeSelectionToHDR(deghost: deghost)
                                    try catalog.checkScope(scope)
                                    await catalog.createWorkingVersion(workspace: workspace)
                                } catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
                            }
                        }.registeredCommandShortcut(.apply, role: .defaultAction).accessibilityIdentifier("LensWorks.hdrMergeConfirm")
                    }
                }.padding(20).frame(width: 380)
            }
    }
}

/// A merged HDR photo's link to its source photos, in the catalog's photo details. The details
/// pane loads `sources` (`LensWorksCatalog.hdrMergeSources`) and shows this only when there are any.
struct LensWorksHDRSourcesView: View {
    let catalog: LensWorksCatalog
    let asset: LensWorksCatalogAsset
    let sources: [LensWorksDerivedSource]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HDR merge of \(sources.count) photos").font(.caption).bold()
            ForEach(sources, id: \.imageID) { source in
                Text(source.missing ? source.filename + " (no longer in this catalog)" : source.filename)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LensWorksCommandButton(.selectHDRSources, reason: catalog.isBusy ? "Finish the current catalog action first."
                : sources.allSatisfy(\.missing) ? "These source photos are no longer in this catalog." : nil) {
                Task {
                    let scope = catalog.captureScope()
                    do { try await catalog.selectHDRMergeSources(of: asset) }
                    catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
                }
            }.accessibilityIdentifier(LensWorksCommandID.selectHDRSources.rawValue)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("LensWorks.hdrSources")
    }
}
