import AppKit

/// The Blur tool's modes. Smudge and Liquify push the active layer's pixels around under the brush.
/// The Brush tool's modes.
nonisolated enum BrushToolMode: String, CaseIterable, Sendable {
    case paint = "Paint"
    case erase = "Erase"
}

nonisolated enum BlurToolMode: String, CaseIterable, Sendable {
    case liquify = "Liquify"
    case blur = "Blur"
    case smudge = "Smudge"
}

/// A Smudge or Liquify stroke in progress. It works on the active layer as the canvas shows it, at document size,
/// changing it dab by dab; the canvas shows that working copy in place of the layer. When the stroke ends, the result
/// is painted into the layer's own pixels along the stroke's path (see `EditorSession.finishWarp`).
final class WarpStroke {
    let layer: ImageLayer
    let mode: BlurToolMode
    let diameter: CGFloat
    let hardness: CGFloat
    let strength: CGFloat
    let width: Int
    let height: Int
    let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    /// Every dab's center, for painting the result into the layer.
    private(set) var points: [CGPoint] = []
    /// The working copy on the GPU, where the dabs run when there is one (see MetalWarp).
    let gpu: MetalWarp?
    private var cpuImage: CGImage?
    /// The working copy as an image, fetched from the GPU the first time it's asked for after a dab.
    var image: CGImage? {
        if layer.liveSource != nil { return sourcePreviewAsset?.image ?? layer.asset?.image }
        guard let gpu else { return cpuImage }
        if cpuImage == nil {
            gpu.read(into: context)
            cpuImage = context.makeImage()
        }
        return cpuImage
    }
    private var last: CGPoint?
    private(set) var sourceStart:CGPoint?
    private(set) var sourcePreview:LWFloatPlane?
    private var sourcePreviewAsset:ImportedImage?
    private var sourcePreviewTask:Task<Void,Never>?
    private var sourcePreviewPending=false
    var sourcePreviewDidChange:(() -> Void)?
    weak var sourceSession: EditorSession?
    private var sourceSelectionID:UUID?
    private(set) var sourcePlaneAssets:[UUID:LWSourcePlaneAsset]=[:]
    private(set) var sourceError:Error?
    private(set) var sourceSelection:Data?
    private var sourceCaptureMetadata:LWSourceMetadataStorage?
    private var sourceDabMetadata:LWSourceMetadataStorage?
    /// Smudge: the color the brush carries, a (2r+1)² RGBA square.
    private var carried: [Float] = []
    private var scratch: [Float] = []

    init(layer: ImageLayer, image: CGImage, transform: LayerTransform, canvas: CGSize, mode: BlurToolMode, settings: BrushSettings,
         useGPU: Bool = true, sourceSelection:Data? = nil, sourceSelectionPlane:LWSourcePlaneAsset? = nil) throws {
        self.layer = layer
        self.mode = mode
        if layer.liveSource != nil {
            sourceCaptureMetadata=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(8192,LWSourceMetadataStorage.product(sourceSelection?.count ?? 0,2)))
        }
        self.sourceSelection=sourceSelection
        if let sourceSelectionPlane { let id=UUID();sourceSelectionID=id;sourcePlaneAssets[id]=sourceSelectionPlane }
        diameter = max(2, settings.diameter)
        hardness = min(0.98, max(0, settings.hardness))
        strength = min(1, max(0.01, settings.opacity))
        width = Int(canvas.width); height = Int(canvas.height)
        // The byte context belongs only to the retained raster implementation.
        // Live RAW keeps an inert one-pixel context and evaluates immutable global planes.
        context = try BrushRaster.context(width:layer.liveSource == nil ? width : 1,height:layer.liveSource == nil ? height : 1,mask:false)
        if layer.liveSource == nil { LayerRenderer.draw(image,transform:transform,center:transform.center,in:context) }
        guard let data = context.data else { throw ExportError.render }
        // Top-left rows: a document point's row is its y.
        pixels = data.bindMemory(to: UInt8.self, capacity:layer.liveSource == nil ? width*height*4 : 4)
        gpu = useGPU && layer.liveSource == nil ? MetalWarp(pixels: context) : nil
        sourcePreview=layer.asset?.linearPlane
        cpuImage = context.makeImage()
    }

    private var radius: Int { Int((diameter / 2).rounded(.up)) }
    /// How much a dab moves pixels at a distance `u` (0 center, 1 rim) from its center.
    private func weight(_ u: Float) -> Float {
        guard u < 1 else { return 0 }
        let h = Float(hardness)
        guard u > h else { return 1 }
        let t = (1 - u) / (1 - h)
        return t * t * (3 - 2 * t)
    }

    /// Continues the stroke to `point`, dabbing along the way, then refreshes `image`.
    func append(_ point: CGPoint) {
        if layer.liveSource != nil {
            do { try appendSource(point) } catch { sourceError=error }
            return
        }
        guard let from = last else {
            last = point
            if mode == .smudge {
                if let gpu { gpu.pickUp(at: point, radius: radius); gpu.commit() } else { pickUp(at: point) }
            }
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        // Smudge drags the pixels one dab's spacing at a time and mixes them with what's there: spaced widely, each step
        // left a faint copy of what it dragged, echoes along the stroke. A pixel apart (a little more for a huge brush)
        // the steps run together into one smear, as Photoshop's does.
        let spacing = max(1, diameter * (mode == .smudge ? 0.005 : 0.025))
        guard distance >= spacing else { return }
        let steps = Int((distance / spacing).rounded(.up))
        var previous = from
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            if let gpu {
                if mode == .smudge { gpu.smudge(at: next, radius: radius, diameter: diameter, hardness: hardness, strength: strength) }
                else { gpu.push(from: previous, to: next, radius: radius, diameter: diameter, hardness: hardness, strength: strength) }
            } else if mode == .smudge { smudge(at: next) } else { push(from: previous, to: next) }
            points.append(next)
            previous = next
        }
        last = point
        if let gpu {
            gpu.commit()
            cpuImage = nil
        } else {
            cpuImage = context.makeImage()
        }
    }

    /// Captures the same retained pointer/step sequence; evaluation uses exact
    /// float samples and never installs the byte WarpStroke preview as RAW pixels.
    private func appendSource(_ point:CGPoint) throws {
        guard sourceError == nil,point.x.isFinite,point.y.isFinite else { throw ProjectError.invalid }
        guard let from=last else { last=point;sourceStart=point;return }
        let distance=hypot(point.x-from.x,point.y-from.y)
        let spacing=max(1,diameter*(mode == .smudge ? 0.005 : 0.025))
        guard distance.isFinite,distance/spacing <= CGFloat(100000-points.count) else { throw ProjectError.tooLarge }
        guard distance >= spacing else { return }
        let steps=Int((distance/spacing).rounded(.up))
        let owner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.collectionBytes(count:points.count+steps,stride:MemoryLayout<CGPoint>.stride))
        for i in 1...steps {
            let t=CGFloat(i)/CGFloat(steps)
            points.append(CGPoint(x:from.x+(point.x-from.x)*t,y:from.y+(point.y-from.y)*t))
        }
        sourceDabMetadata=owner;last=point
        try scheduleSourcePreview()
    }
    func sourceRecord(selection:Data?) throws -> LWSourceRetouchStroke {
        guard let node=layer.liveSource,let sourceStart,!points.isEmpty,mode != .blur else { throw ProjectError.invalid }
        let frame=try node.capturedFrame(transform:layer.transform)
        return LWSourceRetouchStroke(sourceID:node.id,upstreamRevision:node.revision,captureFrame:frame,
            kind:mode == .smudge ? .smear : .liquify,seed:0,healMode:.contentAware,sampleAllLayers:false,aligned:false,
            sampleAllLayersCompositeRevision:nil,blurRadius:0,radius:Double(diameter/2),hardness:Double(hardness),opacity:Double(strength),
            points:points,sourceOffset:.zero,color:[0,0,0,0],pointsAreDabs:true,selectionSourceCoverage:selection,selectionPlaneID:sourceSelectionID,
            selectionFrame:sourceSelectionID == nil ? nil:frame,sourceStart:sourceStart)
    }

    deinit { sourcePreviewTask?.cancel() }
    private func scheduleSourcePreview() throws {
        guard let original=layer.asset?.linearPlane,let node=layer.liveSource else { throw ProjectError.invalid }
        sourcePreviewPending=true;guard sourcePreviewTask == nil else { return };sourcePreviewPending=false
        var preview=try node.previewingRetouch(sourceRecord(selection:sourceSelection))
        try preview.admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.collectionBytes(count:sourcePlaneAssets.count,stride:MemoryLayout<LWSourcePlaneAsset>.stride+128))
        for (id,asset) in sourcePlaneAssets { guard preview.planeAssets[id]==nil else { throw ProjectError.invalid };preview.planeAssets[id]=asset }
        let retained=preview,map=try node.currentSpatialMap
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        guard let sourceSession else { throw ProjectError.invalid }
        sourcePreviewTask=try sourceSession.makeSourcePreviewTask { [weak self] in
            let worker=Task.detached(priority:.userInitiated) { try LWSourceRetouch.evaluate(retained,developed:original,map:map,workspace:workspace) }
            let outcome=await withTaskCancellationHandler { await worker.result } onCancel: { workspace.cancellation.cancel();worker.cancel() }
            guard let self,!Task.isCancelled else { return };self.sourcePreviewTask=nil
            switch outcome {
            case .success(let plane):
                do { self.sourcePreviewAsset=try ImportedImage(plane:plane,name:self.layer.name);self.sourcePreview=plane;self.sourcePreviewDidChange?() }
                catch { self.sourceError=error;return }
            case .failure(let error):self.sourceError=error;return
            }
            if self.sourcePreviewPending { do { try self.scheduleSourcePreview() } catch { self.sourceError=error } }
        }
    }

    private func pickUp(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        carried = [Float](repeating: 0, count: side * side * 4)
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 { carried[c + k] = Float(pixels[p + k]) }
            }
        }
    }

    private func smudge(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let keep = Float(strength), invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 {
                    let under = Float(pixels[p + k])
                    // What was under the brush at the last dab, laid down here at the smudge's strength, as Photoshop
                    // does: all of it drags the pixels along; less mixes them with what's here, softening the trail.
                    let painted = under + (carried[c + k] - under) * w * keep
                    pixels[p + k] = UInt8(max(0, min(255, painted.rounded())))
                    // The brush then carries what it just left, and nothing older: holding on to what it picked up
                    // at the start stamped it again at every dab, a trail of ghost copies.
                    carried[c + k] = painted
                }
            }
        }
    }

    /// Forward warp: pixels under the brush move with it, most at its center, fading to none at its rim.
    private func push(from a: CGPoint, to b: CGPoint) {
        let r = radius
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        // A copy of the area as it was before this dab, which the dab samples from.
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        if scratch.count < cw * ch * 4 { scratch = [Float](repeating: 0, count: cw * ch * 4) }
        for y in 0..<ch {
            for x in 0..<cw {
                let p = ((y + y0) * width + x + x0) * 4, s = (y * cw + x) * 4
                for k in 0..<4 { scratch[s + k] = Float(pixels[p + k]) }
            }
        }
        let invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= y0, y <= y1 else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= x0, x <= x1 else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                // Bilinear sample of the old pixels, from behind the brush's travel.
                let sx = min(Float(cw - 1), max(0, Float(x - x0) - move.x * w))
                let sy = min(Float(ch - 1), max(0, Float(y - y0) - move.y * w))
                let ix = min(cw - 2, Int(sx)), iy = min(ch - 2, Int(sy))
                guard ix >= 0, iy >= 0 else { continue }
                let fx = sx - Float(ix), fy = sy - Float(iy)
                let p = (y * width + x) * 4
                let s00 = (iy * cw + ix) * 4, s10 = s00 + 4, s01 = s00 + cw * 4, s11 = s01 + 4
                for k in 0..<4 {
                    let top = scratch[s00 + k] + (scratch[s10 + k] - scratch[s00 + k]) * fx
                    let bottom = scratch[s01 + k] + (scratch[s11 + k] - scratch[s01 + k]) * fx
                    pixels[p + k] = UInt8(max(0, min(255, (top + (bottom - top) * fy).rounded())))
                }
            }
        }
    }
}

extension EditorSession {
    func beginWarp(at point: CGPoint) {
        guard canPaint, !isMaskSelected, let layer = activeLayer, let image = layer.asset?.image, let document else {
            brushError = isMaskSelected ? "Smudge and Liquify work on a layer's pixels, not its mask." : paintRefusal
            return
        }
        finishOpacityEdit()
        do {
            let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
            let capturedSelection=try layer.liveSource == nil ? nil:LWSourceSelectionPlane.capture(selection?.clip(canvas:document.size),
                mapping:BrushRaster.pixelToDocument(layer.transform,width:image.width,height:image.height),
                width:image.width,height:image.height,workspace:workspace)
            let sourceSelection=try capturedSelection.map(LWSourcePlaneAsset.init)
            let stroke = try WarpStroke(layer: layer, image: image, transform: displayedTransform(for: layer),
                                        canvas: document.size, mode: blurMode, settings:brushSettings,sourceSelectionPlane:sourceSelection)
            stroke.sourceSession = self
            stroke.append(point)
            warpStroke = stroke
            stroke.sourcePreviewDidChange={ [weak self,weak stroke] in
                guard let self,let stroke,self.warpStroke === stroke else { return };self.brushRevision+=1
            }
            lastBrushPoint = (point, layer.id, false)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    private func commitSourceWarp(_ warp:WarpStroke,current:ImageLayer) throws {
        guard let original=current.liveSource else { throw ProjectError.invalid }
        var changed=try original.metadataCopy(additionalBytes:LWSourceMetadataStorage.collectionBytes(count:warp.sourcePlaneAssets.count,stride:MemoryLayout<LWSourcePlaneAsset>.stride+128))
        for (id,asset) in warp.sourcePlaneAssets { guard changed.planeAssets[id]==nil else { throw ProjectError.invalid };changed.planeAssets[id]=asset }
        try changed.appendRetouch(try warp.sourceRecord(selection:warp.sourceSelection))
        changed.revision=UUID();changed.sourceLineage.append(changed.revision)
        let epoch=commandContextEpoch
        isProjectBusy=true
        Task { @MainActor in
            defer { isProjectBusy=false;brushRevision+=1 }
            do {
                let made=try await LWSourceDeveloper.shared.evaluatePlane(changed)
                guard commandContextEpoch == epoch,let i=document?.layers.firstIndex(where:{$0.id == current.id}),
                      let actual=document?.layers[i],actual.liveSource == original,actual.asset?.image === current.asset?.image,
                      actual.transform == current.transform else { throw CancellationError() }
                var updated=actual;updated.asset=try ImportedImage(plane:made.surface,name:actual.name);updated.liveSource=changed
                guard beginEdit(warp.mode.rawValue) else { return };document?.layers[i]=updated;endEdit()
            } catch { brushError=error.localizedDescription }
        }
    }

    /// Paints the finished Smudge or Liquify result into the layer's pixels along the stroke, as one undo step.
    func finishWarp() {
        guard let warp = warpStroke else { return }
        warpStroke = nil
        brushRevision += 1
        if let error=warp.sourceError { brushError=error.localizedDescription;return }
        guard !warp.points.isEmpty, let result = warp.image,
              let current = document?.layers.first(where: { $0.id == warp.layer.id }),
              current.asset?.image === warp.layer.asset?.image, current.transform == warp.layer.transform else { return }
        do {
            if current.liveSource != nil { try commitSourceWarp(warp,current:current);return }
            var settings = brushSettings
            // A hard tip a little wider than the brush covers everything the stroke moved.
            settings.diameter = warp.diameter + 4
            settings.hardness = 1
            settings.opacity = 1
            let stroke = try makeRasterEdit(for: current, settings: settings)
            stroke.clone = (result, CGRect(x: 0, y: 0, width: result.width, height: result.height), false)
            stroke.replacesWithClone = true
            stroke.editName = warp.mode.rawValue
            // The tip is solid and a little wider than the brush, so a point every twentieth of its width covers what
            // every dab did: a big brush on a big canvas lays thousands of dabs, and replaying each one stalled the release.
            let spacing = max(1, warp.diameter * 0.05)
            var kept: CGPoint?
            for (index, point) in warp.points.enumerated() {
                if let kept, index < warp.points.count - 1, hypot(point.x - kept.x, point.y - kept.y) < spacing { continue }
                try stroke.append(point)
                kept = point
            }
            try stroke.flush()
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
    }
}
