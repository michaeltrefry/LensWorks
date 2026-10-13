import Foundation
import SwiftUI
import ImageIO
import CryptoKit

/// The words each merge uses for itself in commands, progress and reasons.
extension LensWorksDerivedKind {
    nonisolated var commandName: String { self == .hdr ? "Merge to HDR" : "Merge to Panorama" }
    nonisolated var running: String { self == .hdr ? "A merge to HDR is already running." : "A merge to panorama is already running." }
    nonisolated var notRunning: String { self == .hdr ? "No merge to HDR is running." : "No merge to panorama is running." }
    nonisolated var admitting: String { self == .hdr ? "The merged photo is already being added to the catalog." : "The panorama is already being added to the catalog." }
    nonisolated var starting: String { self == .hdr ? "Merging bracketed photos to HDR…" : "Merging photos to a panorama…" }
    nonisolated var developingFor: String { self == .hdr ? "for the HDR merge" : "for the panorama" }
    nonisolated var writing: String { self == .hdr ? "Writing the merged HDR photo…" : "Writing the panorama…" }
    nonisolated var adding: String { self == .hdr ? "Adding the merged HDR photo to the catalog…" : "Adding the panorama to the catalog…" }
    nonisolated var result: String { self == .hdr ? "to HDR" : "to a panorama" }
    /// Added to the reference photo's name: `IMG_0002-HDR.dng`, `IMG_0001-Pano.dng`.
    nonisolated var suffix: String { self == .hdr ? "-HDR" : "-Pano" }
    nonisolated var partialExtension: String { self == .hdr ? "lwhdr-partial" : "lwpano-partial" }
    nonisolated var sourcesNoun: String { self == .hdr ? "HDR merge sources" : "panorama sources" }
    nonisolated var sourcesTitle: String { self == .hdr ? "HDR merge" : "Panorama" }
    var mergeCommand: LensWorksCommandID { self == .hdr ? .mergeHDR : .mergePanorama }
    var cancelCommand: LensWorksCommandID { self == .hdr ? .cancelMergeHDR : .cancelMergePanorama }
    var selectSourcesCommand: LensWorksCommandID { self == .hdr ? .selectHDRSources : .selectPanoramaSources }
}

/// One selected original a merge reads: its catalog row, its location and its bytes' hash.
nonisolated struct LensWorksMergeOriginal: Sendable {
    let row: LensWorksSelectedRow
    let native: LWCatalogNativePath
    let url: URL
    let sha256: String
    var source: LensWorksDerivedSource { LensWorksDerivedSource(imageID: row.imageID, assetID: row.key.asset_id, variantID: row.key.variant_id, filename: url.lastPathComponent) }
    var record: LWDerivedSourceRecord { LWDerivedSourceRecord(catalogImageID: row.imageID, assetID: row.key.asset_id, variantID: row.key.variant_id, fileName: url.lastPathComponent, sha256: sha256) }
}

/// What a merge has computed and how to write it: the catalog side does the rest.
nonisolated struct LensWorksMergePlan<Product: Sendable>: Sendable {
    let product: Product
    /// The output file's name without extension; `-2`, `-3`… is added if it is taken.
    let stem: String
    /// Streams the DNG to the given (new, temporary) file. Runs off the main actor.
    let write: @Sendable (URL) throws -> Void
}

nonisolated struct LensWorksMergeOutput<Product: Sendable>: Sendable {
    let dng: URL
    let asset: LensWorksCatalogAsset
    let product: Product
}

/// What Merge to HDR… and Merge to Panorama… share: admission, the selected originals and their
/// hashes, source development into bounded frames, the temporary file moved into place without
/// replacing, the single-file import, the source link, cancellation and clean-up.
extension LensWorksCatalog {
    var isMerging: Bool { merge != nil }
    /// Why a merge of `kind` is unavailable now, or nil when the selection can be merged.
    /// Pixel dimensions are not part of a catalog row, so the memory budget is checked once the
    /// first photo is developed.
    func mergeAvailability(_ kind: LensWorksDerivedKind, frames: ClosedRange<Int>, tooFew: String, tooMany: String) -> String? {
        guard catalogPath != nil, !closingRequested else { return "Open a catalog first." }
        if let merge { return merge.kind.running }
        guard !isBusy, !isImporting else { return "Finish the current catalog action first." }
        guard selectionCount >= Int64(frames.lowerBound) else { return tooFew }
        guard selectionCount <= Int64(frames.upperBound) else { return tooMany }
        return nil
    }
    /// Why the running merge of `kind` cannot be cancelled now, or nil when it can.
    func mergeCancelReason(_ kind: LensWorksDerivedKind) -> String? {
        guard merge?.kind == kind else { return kind.notRunning }
        return mergeAdmitting ? kind.admitting : nil
    }
    /// Cancels the running merge of `kind`: nothing is written beside the photos or added to the catalog.
    func cancelMerge(_ kind: LensWorksDerivedKind) { if mergeCancelReason(kind) == nil { merge?.cancel() } }

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

    /// Develops one original through the editor's source development and loads it for a merge in
    /// bounded row strips. `admit` is the merge's memory budget check: it runs as soon as the
    /// dimensions are known, before the frame is loaded.
    nonisolated static func developMergeFrame(original: LWCatalogNativePath, url: URL, admit: @Sendable (_ width: Int, _ height: Int) throws -> Void) async throws -> LWMergeFrame {
        let (node, plane) = try await LWSourceDeveloper.shared.createPlane(original: original, rawHint: RawImporter.matches(url))
        try admit(plane.width, plane.height)
        let whiteLevel = try node.neutralClip()
        return try await detached { try LWMergeFrame(plane: plane, whiteLevel: whiteLevel) }
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

    /// Runs one merge as the catalog's running merge. Cancelling (its Cancel command, the calling
    /// task, or the catalog scope ending) stops the work and leaves no file.
    func runMerge<Outcome: Sendable>(_ kind: LensWorksDerivedKind, availability: String?, _ work: @escaping @MainActor (LensWorksCatalogScope) async throws -> Outcome) async throws -> Outcome {
        try admitCatalogWork()
        if let availability { throw LensWorksCatalogError.message(availability) }
        let scope = captureScope()
        let task = Task { try await work(scope) }
        merge = (kind, { task.cancel() }); mergeAdmitting = false
        defer { merge = nil; mergeAdmitting = false }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            // Work interrupted by the cancel may surface its own error; it is still a cancel.
            guard error is CancellationError || task.isCancelled else { throw error }
            if scopeIsCurrent(scope) { status = "\(kind.commandName) canceled. Nothing was added to the catalog." }
            throw CancellationError()
        }
    }

    /// Develops every original of a merge in turn, reporting each in the status line.
    func developMergeFrames(_ originals: [LensWorksMergeOriginal], kind: LensWorksDerivedKind, scope: LensWorksCatalogScope, admit: @escaping @Sendable (_ width: Int, _ height: Int) throws -> Void) async throws -> [LWMergeFrame] {
        var frames: [LWMergeFrame] = []
        for (number, original) in originals.enumerated() {
            status = "Developing photo \(number + 1) of \(originals.count) \(kind.developingFor)…"
            frames.append(try await Self.developMergeFrame(original: original.native, url: original.url, admit: admit))
            try checkScope(scope); try Task.checkCancellation()
        }
        return frames
    }

    /// The catalog side of a merge: reads the selection, hashes the originals, lets `plan`
    /// compute the result, writes it under a hidden temporary name beside the first source,
    /// re-verifies the sources' bytes, moves the file into place without replacing, imports that
    /// one file and records its sources against the new catalog photo. Sources are only read.
    /// `checked` is what an agent's request was checked against (each source original's path, in
    /// selection order): with it, nothing is read or written unless the selection still reaches exactly those.
    func performMerge<Product: Sendable>(_ kind: LensWorksDerivedKind, scope: LensWorksCatalogScope, frames: ClosedRange<Int>, tooFew: String, tooMany: String,
                                         checked: [String]? = nil, plan: ([LensWorksMergeOriginal]) async throws -> LensWorksMergePlan<Product>) async throws -> LensWorksMergeOutput<Product> {
        let owner = selectionOwnerForCommands
        let written: (url: URL, product: Product, sources: [LensWorksDerivedSource])
        // The file this merge has created and the catalog has not admitted: removed on any failure.
        var pending: URL?
        do {
            do {
                let busy = beginBusy(); defer { finishBusy(busy) }
                status = kind.starting
                let rows = try await index.selection(owner: owner)
                try checkScope(scope); try Task.checkCancellation()
                guard Int64(rows.count) == selectionCount else {
                    throw LensWorksCatalogError.message("The selection changed while \(kind.commandName) was starting. Try again.")
                }
                guard rows.count >= frames.lowerBound else { throw LensWorksCatalogError.message(tooFew) }
                guard rows.count <= frames.upperBound else { throw LensWorksCatalogError.message(tooMany) }
                var originals: [LensWorksMergeOriginal] = []
                for row in rows {
                    let native = try await service.originalLocation(row.key)
                    try checkScope(scope)
                    let url = try native.localFileURL()
                    // Checked before the file is read.
                    if let checked, checked.count != rows.count || checked[originals.count] != url.path {
                        throw LensWorksCatalogError.message("The selection or its originals changed after the request was checked: nothing was merged.")
                    }
                    guard (try? url.checkResourceIsReachable()) == true else {
                        throw LensWorksCatalogError.message("“\(url.lastPathComponent)” is offline. Reconnect its location before merging.")
                    }
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        throw LensWorksCatalogError.message("“\(url.lastPathComponent)” is not a photo file.")
                    }
                    originals.append(LensWorksMergeOriginal(row: row, native: native, url: url, sha256: try await Self.detached { try Self.sha256(url) }))
                    try checkScope(scope)
                }
                let planned = try await plan(originals)
                try checkScope(scope)
                let folder = originals[0].url.deletingLastPathComponent(), stem = planned.stem
                // Written under a hidden temporary name (not an importable extension) and moved into place whole.
                let temporary = folder.appendingPathComponent(".\(stem)-\(UUID().uuidString).\(kind.partialExtension)")
                let hashes = originals.map { (url: $0.url, hash: $0.sha256) }, write = planned.write
                status = kind.writing
                pending = temporary
                let destination = try await Self.detached {
                    try write(temporary)
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
                written = (destination, planned.product, originals.map(\.source))
            }
            try checkScope(scope); try Task.checkCancellation()
            #if DEBUG
            try await mergeWrittenFixture?(written.url)
            try checkScope(scope); try Task.checkCancellation()
            #endif
            guard let catalogPath else { throw CancellationError() }
            // From here the engine may admit the file at any moment: no cancel, and the file stays
            // unless the import ends without it.
            mergeAdmitting = true
            status = kind.adding
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
            try await index.recordSources(catalog: catalogPath, image: asset.id, kind: kind, sources: written.sources)
            try checkScope(scope)
            status = "Merged \(written.sources.count) photos \(kind.result): \(written.url.lastPathComponent)"
            return LensWorksMergeOutput(dng: written.url, asset: asset, product: written.product)
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

/// A derived photo's link to its source photos, in the catalog's photo details. The details pane
/// loads `link` (`LensWorksCatalog.derivedLink`) and shows this only when there is one.
struct LensWorksDerivedSourcesView: View {
    let catalog: LensWorksCatalog
    let asset: LensWorksCatalogAsset
    let link: LensWorksDerivedLink
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(link.kind.sourcesTitle) of \(link.sources.count) photos").font(.caption).bold()
            ForEach(link.sources, id: \.imageID) { source in
                Text(source.missing ? source.filename + " (no longer in this catalog)" : source.filename)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LensWorksCommandButton(link.kind.selectSourcesCommand, reason: catalog.isBusy ? "Finish the current catalog action first."
                : link.sources.allSatisfy(\.missing) ? "These source photos are no longer in this catalog." : nil) {
                let kind = link.kind
                Task {
                    let scope = catalog.captureScope()
                    do { try await catalog.selectDerivedSources(of: asset, kind: kind) }
                    catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
                }
            }.accessibilityIdentifier(link.kind.selectSourcesCommand.rawValue)
        }.accessibilityElement(children: .contain).accessibilityIdentifier(link.kind == .hdr ? "LensWorks.hdrSources" : "LensWorks.panoramaSources")
    }
}

/// A merge's place in the catalog toolbar: its registered command with its availability reason;
/// while that merge runs, its progress and its registered Cancel command. `sheet` is the merge's
/// own options; its Cancel and default buttons go through `LensWorksMergeSheetButtons`.
struct LensWorksMergeButton<Sheet: View>: View {
    let kind: LensWorksDerivedKind
    let catalog: LensWorksCatalog
    let availability: String?
    @Binding var confirming: Bool
    @ViewBuilder let sheet: () -> Sheet
    var body: some View {
        HStack(spacing: 6) {
            if catalog.merge?.kind == kind {
                ProgressView().controlSize(.small)
                LensWorksCommandButton(kind.cancelCommand, reason: catalog.mergeCancelReason(kind)) { catalog.cancelMerge(kind) }
                    .accessibilityIdentifier(kind.cancelCommand.rawValue)
            } else {
                LensWorksCommandButton(kind.mergeCommand, reason: availability) { confirming = true }
                    .accessibilityIdentifier(kind.mergeCommand.rawValue)
            }
        }
            .sheet(isPresented: $confirming) { sheet().padding(20).frame(width: 380) }
    }
}

/// The Cancel and Merge buttons of a merge's options sheet, bound through the command registry.
struct LensWorksMergeSheetButtons: View {
    @Binding var confirming: Bool
    let confirmIdentifier: String
    let merge: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { confirming = false }.registeredCommandShortcut(.cancel, role: .cancelAction)
            Button("Merge") { confirming = false; merge() }
                .registeredCommandShortcut(.apply, role: .defaultAction).accessibilityIdentifier(confirmIdentifier)
        }
    }
}
