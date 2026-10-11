import AppKit
import Observation

nonisolated enum LevelsChannel: String, CaseIterable, Sendable, Codable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var index: Int { Self.allCases.firstIndex(of: self)! }
}
nonisolated struct LevelRange: Equatable, Sendable, Codable {
    var black: Double = 0
    var gamma: Double = 1
    var white: Double = 255
    var outputBlack: Double = 0
    var outputWhite: Double = 255
    var normalized: Self {
        func clamp(_ n: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        var result = self
        result.black = clamp(black, 0...254, 0)
        result.white = clamp(white, (result.black + 1)...255, 255)
        result.gamma = clamp(gamma, 0.1...9.99, 1)
        result.outputBlack = clamp(outputBlack, 0...255, 0)
        result.outputWhite = clamp(outputWhite, 0...255, 255)
        return result
    }
    func apply(_ value: Double) -> Double {
        let s = normalized
        let input = min(1, max(0, (value * 255 - s.black) / (s.white - s.black)))
        return (s.outputBlack + pow(input, 1 / s.gamma) * (s.outputWhite - s.outputBlack)) / 255
    }
}
nonisolated struct LevelsSettings: Equatable, Sendable, Codable {
    var channel: LevelsChannel = .rgb
    var ranges = Array(repeating: LevelRange(), count: 4)
    var current: LevelRange {
        get { ranges[channel.index] }
        set { ranges[channel.index] = newValue.normalized }
    }
    var isIdentity: Bool { ranges.allSatisfy { $0.normalized == LevelRange() } }
    /// Individual channels, followed by the composite RGB adjustment.
    func apply(_ value: Double, channel: LevelsChannel) -> Double {
        ranges[0].apply(ranges[channel.index].apply(value))
    }
}
/// Display-only vertical scaling. Keep linear bin ratios, but cap isolated spikes
/// so large solid backgrounds cannot flatten the useful tonal distribution.
nonisolated enum LevelsHistogramDisplay {
    static func scale(for bins: [Double]) -> Double {
        let peak = bins.filter { $0.isFinite && $0 > 0 }.max() ?? 0
        guard peak > 0 else { return 0 }
        let interior = bins.dropFirst().dropLast().filter { $0.isFinite && $0 > 0 }.sorted()
        guard !interior.isEmpty else { return peak }
        let typicalPeak = interior[Int(Double(interior.count - 1) * 0.95)]
        return min(peak, typicalPeak * 4)
    }
}

nonisolated struct LevelsJob: @unchecked Sendable {
    let image: CGImage
    let settings: LevelsSettings
    let selection: SelectionClip?
    let mapping: CGAffineTransform
}
nonisolated enum LevelsFilter {
    static func run(_ job: LevelsJob) throws -> CGImage {
        if job.settings.isIdentity { return job.image }
        let context = try BrushRaster.copy(job.image)
        let tables = [LevelsChannel.red, .green, .blue].flatMap { channel in
            (0...255).map { Float(job.settings.apply(Double($0) / 255, channel: channel)) }
        }
        guard let data = context.data else { throw ExportError.render }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let count = job.image.width * job.image.height
        // The tables are for colors, not colors already multiplied by their alpha, and `levels_apply` already
        // divides each channel by its alpha before the lookup and multiplies it back after. Doing it here as
        // well ran a soft edge through the conversion twice: 50% grey at half alpha came out at a quarter.
        // A Levels layer runs on the whole canvas view every frame: split across the cores.
        BrushRaster.inBands(count: count) { start, length in levels_apply(pixels + start * 4, length, tables) }
        guard let image = context.makeImage() else { throw ExportError.render }
        if let selection = job.selection {
            return try PixelAdjust.blend(image, over: job.image, through: selection, pixelToDocument: job.mapping, isMask: false)
        }
        return image
    }
    /// RGB is the mean of the three channel histograms, not a luminance histogram.
    static func histogram(_ job: LevelsJob) throws -> [[Double]] {
        let w = job.image.width, h = job.image.height
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        BrushRaster.draw(job.image, in: CGRect(x: 0, y: 0, width: w, height: h), mask: false, context: context)
        var coverageContext: CGContext?
        if let selection = job.selection {
            let image = try PixelAdjust.coverage(selection, width: w, height: h, pixelToDocument: job.mapping)
            let mask = try BrushRaster.context(width: w, height: h, mask: true)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h), mask: true, context: mask)
            coverageContext = mask
        }
        var bins = Array(repeating: 0.0, count: 1024)
        levels_histogram(context.data!.assumingMemoryBound(to: UInt8.self),
            coverageContext?.data?.assumingMemoryBound(to: UInt8.self), w * h, &bins)
        return (0..<4).map { Array(bins[($0 * 256)..<(($0 + 1) * 256)]) }
    }
}

@Observable
final class LevelsEdit {
    let layerID: UUID
    let original: ImportedImage
    let transform: LayerTransform
    let liveSource:LWLiveSourceNode?
    let originalMask:LayerMask?
    var liveAdmission:LWDocumentEditAdmission?
    @ObservationIgnored var livePreviewPlane:LWFloatPlane?
    let selection: SelectionClip?
    let mapping: CGAffineTransform
    let previewSource: CGImage
    let previewMapping: CGAffineTransform
    var sampleMode: LevelsSample?
    var settings = LevelsSettings()
    var preview = true
    var committing = false
    var histogram: [[Double]] = Array(repeating: Array(repeating: 0, count: 256), count: 4)
    var histogramReady = false
    @ObservationIgnored var histogramCharge:LWFloatWorkingSet.Lease?
    @ObservationIgnored var preparedPreview: CGImage?
    @ObservationIgnored var pending: LevelsJob?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    @ObservationIgnored var histogramTask: Task<Void, Never>?

    init(layer: ImageLayer, selection: SelectionClip?) throws {
        layerID = layer.id; original = layer.asset!; transform = layer.transform; self.selection = selection
        liveSource=layer.liveSource;originalMask=layer.mask
        mapping = BrushRaster.pixelToDocument(transform, width: original.image.width, height: original.image.height)
        // Full size up to 8000 pixels on a side: a levels preview is a lookup table per pixel, quick enough to run
        // on the whole layer, and a downscaled copy showed the canvas a coarse, pixelated version while dragging.
        let factor = min(1, 8000 / CGFloat(max(original.image.width, original.image.height)))
        if factor < 1,layer.liveSource == nil {
            let w = max(1, Int(CGFloat(original.image.width) * factor)), h = max(1, Int(CGFloat(original.image.height) * factor))
            let context = try BrushRaster.context(width: w, height: h, mask: false)
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            if let raster = original.raster { raster.draw(in: rect, context: context) }
            else { BrushRaster.draw(original.image, in: rect, mask: false, context: context) }
            guard let image = context.makeImage() else { throw ExportError.render }
            previewSource = image
            previewMapping = BrushRaster.pixelToDocument(transform, width: w, height: h)
        } else { previewSource = original.image; previewMapping = mapping }
    }
    func previewImage(for id: UUID) -> CGImage? { preview && id == layerID ? preparedPreview : nil }
    var previewJob: LevelsJob { LevelsJob(image: previewSource, settings: settings, selection: selection, mapping: previewMapping) }
}

extension EditorSession {
    func beginLevels() {
        guard levels == nil, hueSaturation == nil, canAdjustColors else { return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginLevels() }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        guard let layer = activeLayer, let document else { return }
        do {
            let edit = try LevelsEdit(layer: layer, selection: selection?.clip(canvas: document.size))
            if edit.liveSource != nil { edit.liveAdmission=try captureDocumentEditAdmission() }
            levels = edit
            let job = edit.previewJob
            edit.histogramTask = try makeSourcePreviewTask { [weak self, weak edit] in
                if let self,let edit,let source=edit.liveSource,let admission=edit.liveAdmission {
                    do {
                        try self.validateSourceAdjustmentAdmission(admission,layerID:edit.layerID,node:source,original:edit.original,transform:edit.transform,mask:edit.originalMask)
                        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
                        let result=try await withTaskCancellationHandler {
                            let before=try await LWSourceDeveloper.shared.evaluatePlane(source)
                            return try LWSourceLevelsHistogram.make(before.surface,selection:edit.selection,transform:edit.transform,workspace:workspace)
                        } onCancel: { workspace.cancellation.cancel() }
                        try Task.checkCancellation()
                        try self.validateSourceAdjustmentAdmission(admission,layerID:edit.layerID,node:source,original:edit.original,transform:edit.transform,mask:edit.originalMask)
                        guard self.levels === edit else { return }
                        edit.histogram=result.bins;edit.histogramCharge=result.charge;edit.histogramReady=true
                    } catch { if self.levels === edit { self.brushError=error.localizedDescription } }
                    return
                }
                let result = await Task.detached(priority: .userInitiated) { try? LevelsFilter.histogram(job) }.value
                guard let self, let edit, self.levels === edit, !Task.isCancelled else { return }
                if let result { edit.histogram = result }
                edit.histogramReady = true
            }
        } catch { brushError = error.localizedDescription }
    }
    func updateLevels(_ settings: LevelsSettings, preview: Bool) {
        guard let edit = levels, !edit.committing else { return }
        edit.settings = settings; edit.preview = preview
        if previewAdjustmentEditing(preview: preview) { return }
        if !preview || settings.isIdentity {
            edit.previewTask?.cancel(); edit.pending = nil
            edit.preparedPreview = nil;edit.livePreviewPlane=nil; brushRevision += 1
            return
        }
        edit.pending = edit.previewJob
        renderLevelsPreview(edit)
    }
    private func renderLevelsPreview(_ edit: LevelsEdit) {
        guard levels === edit, edit.previewTask == nil, let job = edit.pending else { return }
        edit.pending = nil
        do {
        edit.previewTask = try makeSourcePreviewTask { [weak self, weak edit] in
            if let self,let edit,let node=edit.liveSource,let admission=edit.liveAdmission {
                do {
                    try self.validateSourceAdjustmentAdmission(admission,layerID:edit.layerID,node:node,original:edit.original,transform:edit.transform,mask:edit.originalMask)
                    var settings=LayerAdjustment(kind:.levels);settings.levels=job.settings
                    let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
                    let made=try await LWSourceAdjustmentPreparation.prepare(node,settings:settings,selection:edit.selection,transform:edit.transform,workspace:workspace)
                    try Task.checkCancellation()
                    try self.validateSourceAdjustmentAdmission(admission,layerID:edit.layerID,node:node,original:edit.original,transform:edit.transform,mask:edit.originalMask)
                    guard self.levels === edit else { throw CancellationError() }
                    let provider=LWFloatPlaneImage(plane:made.plane,cancellation:workspace.cancellation)
                    let image=try provider.image();try provider.check()
                    edit.livePreviewPlane=made.plane;edit.preparedPreview=image;self.brushRevision+=1
                } catch { if self.levels === edit { self.brushError=error.localizedDescription } }
                edit.previewTask=nil;self.renderLevelsPreview(edit);return
            }
            let result = await Task.detached(priority: .userInitiated) { try? LevelsFilter.run(job) }.value
            guard let self,let edit else { return }
            edit.previewTask=nil
            guard self.levels === edit,!Task.isCancelled else { return }
            if edit.preview, !edit.settings.isIdentity { edit.preparedPreview = result; self.brushRevision += 1 }
            self.renderLevelsPreview(edit)
        }
        } catch { commandRefusal=error.localizedDescription }
    }
    func cancelLevels() {
        if finishAdjustmentEditing(commit: false) { return }
        guard let edit = levels, !edit.committing else { return }
        edit.previewTask?.cancel(); edit.histogramTask?.cancel()
        levels = nil; brushRevision += 1
    }
    func commitLevels() async {
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = levels, !edit.committing else { return }
        if edit.settings.isIdentity { cancelLevels(); return }
        edit.committing = true
        edit.previewTask?.cancel(); edit.histogramTask?.cancel()
        isProjectBusy = true
        defer { levels = nil; isProjectBusy = false; brushRevision += 1 }
        if let node=edit.liveSource,let admission=edit.liveAdmission {
            do {
                var value=LayerAdjustment(kind:.levels);value.levels=edit.settings
                try await commitSourceAdjustment(admission:admission,layerID:edit.layerID,node:node,original:edit.original,
                    transform:edit.transform,mask:edit.originalMask,settings:value,selection:edit.selection)
            } catch { brushError=error.localizedDescription }
            return
        }
        let job = LevelsJob(image: edit.original.image, settings: edit.settings, selection: edit.selection, mapping: edit.mapping)
        do {
            let asset = try await Task.detached(priority: .userInitiated) {
                let image = try LevelsFilter.run(job)
                return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Levels")
            }.value
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let current = document?.layers[index], current.asset?.image === edit.original.image,
                  current.transform == edit.transform else { return }
            guard beginEdit("Levels") else { return }
            document?.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name, isVisible: current.isVisible,
                transform: current.transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode, mask: current.mask, maskSourceID: current.maskSourceID)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
