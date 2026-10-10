import Foundation
import CoreGraphics

nonisolated struct ImageSizeOptions: Sendable {
    var width: Int
    var height: Int
    var resolution: Double
    var sampling: LayerSampling = .high
}

actor ImageResizer {
    static let shared = ImageResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: ImageSizeOptions) async throws -> ProjectSnapshot {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        return try await withTaskCancellationHandler {
            let result=try resizeOwned(snapshot,to:options,workspace:workspace)
            try workspace.cancellation.check();try Task.checkCancellation()
            return result
        } onCancel: { workspace.cancellation.cancel() }
    }
    private func resizeOwned(_ snapshot: ProjectSnapshot, to options: ImageSizeOptions,
        workspace:LWFloatWorkspace) throws -> ProjectSnapshot {
        guard (1...DocumentLimits.maxSide).contains(options.width), (1...DocumentLimits.maxSide).contains(options.height),
              options.resolution.isFinite, (1...9600).contains(options.resolution) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        var manifest = try old.metadataCopy()
        manifest.width = options.width; manifest.height = options.height; manifest.resolution = options.resolution; manifest.layers = []
        if old.width == options.width && old.height == options.height {
            manifest.layers = old.layers
            return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks, workingVersion:snapshot.workingVersion)
        }
        guard options.width * options.height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        let sx = CGFloat(options.width) / CGFloat(old.width)
        let sy = CGFloat(options.height) / CGFloat(old.height)
        manifest.guides = old.guides?.map { $0.scaled(x: sx, y: sy) }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var usedPixels = 0, usedMaskPixels = 0
        for layer in old.layers {
            try Task.checkCancellation()
            // Rasterize each transformed layer independently. Nonuniform scaling of a
            // rotated rectangle can introduce shear, which width/height/angle cannot represent.
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                .map { layer.transform.point($0) }.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            let left = floor(corners.map(\.x).min()!), top = floor(corners.map(\.y).min()!)
            let width = Int(ceil(corners.map(\.x).max()!) - left)
            let height = Int(ceil(corners.map(\.y).max()!) - top)
            let transform = LayerTransform(origin: CGPoint(x: left, y: top),
                size: CGSize(width: width, height: height), sampling: options.sampling)
            guard transform.isValid else { throw ProjectError.tooLarge }
            if let source = snapshot.images[layer.id], let plane = source.linearPlane {
                guard width * height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
                usedPixels += width * height
                let placement = BrushRaster.pixelToDocument(layer.transform,width:plane.width,height:plane.height)
                    .concatenating(CGAffineTransform(scaleX:sx,y:sy)).concatenating(CGAffineTransform(translationX:-left,y:-top))
                let h = try LWSourceCoordinateMap([Double(placement.a),Double(placement.c),Double(placement.tx),
                    Double(placement.b),Double(placement.d),Double(placement.ty),0,0,1])
                let stage = LWSourcePixelStage(inputWidth:plane.width,inputHeight:plane.height,outputWidth:width,outputHeight:height,
                    offsetX:0,offsetY:0,distortion:0,homography:h)
                let operation = LWSourceResample(id:UUID(),sourceID:layer.liveSource?.id ?? layer.id,
                    upstreamRevision:layer.liveSource?.revision ?? UUID(),stage:stage,sampling:options.sampling)
                let resampled = try LWSourceResample.apply(operation,plane:plane,workspace:workspace)
                let asset = try ImportedImage(plane:resampled,name:source.name)
                try source.validatePlaneRead(); try workspace.cancellation.check()
                images[layer.id] = asset
                var changed = layer; changed.transform = transform
                changed.planeArchiveReference = asset.planeArchiveReference; changed.imageFile = "\(layer.id.uuidString).plane"
                if var node = layer.liveSource {
                    let map=try node.currentSpatialMap
                    guard map.developedWidth == plane.width,map.developedHeight == plane.height else { throw ProjectError.invalid }
                    try node.appendResample(operation);node.revision=UUID();node.sourceLineage.append(node.revision);try node.validate()
                    changed.liveSource = node
                }
                if let mask = snapshot.masks[layer.id] {
                    try mask.validatePlaneRead()
                    if (mask.image.width == 1 && mask.image.height == 1) || layer.maskPlacement != nil {
                        masks[layer.id] = mask
                        changed.maskPlacement = layer.maskPlacement.map { $0.placing($0.unitToDocument.concatenating(CGAffineTransform(scaleX:sx,y:sy))) }
                    } else {
                        guard width * height <= DocumentLimits.documentPixelBudget - usedMaskPixels else { throw ProjectError.tooLarge }
                        usedMaskPixels += width * height
                        let maskMapping = BrushRaster.pixelToDocument(layer.transform,width:mask.image.width,height:mask.image.height)
                            .concatenating(CGAffineTransform(scaleX:sx,y:sy)).concatenating(CGAffineTransform(translationX:-left,y:-top))
                        let maskPlane=try LWSourceMaskReconcile.plane(mask,workspace:workspace)
                        let resizedMask = try LWSourceMaskReconcile.projectCoverage(maskPlane,mapping:maskMapping,width:width,height:height,
                            sampling:options.sampling,workspace:workspace)
                        let owned = try ImportedImage(maskPlane:resizedMask,name:mask.name)
                        try mask.validatePlaneRead()
                        masks[layer.id] = owned;changed.maskPlaneArchiveReference = owned.planeArchiveReference
                        changed.maskFile = "\(layer.id.uuidString).mask.plane"
                    }
                }
                manifest.layers.append(changed); continue
            }
            guard layer.liveSource == nil else { throw ProjectError.missingImage }
            if layer.imageFile != nil {
                guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                      width * height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
                usedPixels += width * height
                guard let source = snapshot.images[layer.id] else { throw ProjectError.missingImage }
                let asset = try autoreleasepool {
                    guard let context = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -left, y: -top)
                    context.scaleBy(x: sx, y: sy)
                    var sourceTransform = layer.transform
                    sourceTransform.sampling = options.sampling
                    LayerRenderer.draw(source.image, transform: sourceTransform, center: sourceTransform.center, in: context)
                    guard let image = context.makeImage() else { throw ExportError.render }
                    let factor = min(1, 96 / CGFloat(max(width, height)))
                    let tw = max(1, Int(CGFloat(width) * factor)), th = max(1, Int(CGFloat(height) * factor))
                    guard let thumb = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                        bytesPerRow: tw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                    thumb.interpolationQuality = .high
                    thumb.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
                    guard let thumbnail = thumb.makeImage() else { throw ExportError.render }
                    return ImportedImage(image: image, thumbnail: thumbnail, name: source.name)
                }
                images[layer.id] = asset
            }
            var resizedMaskFile=layer.maskFile,resizedMaskReference=layer.maskPlaneArchiveReference
            if layer.maskFile != nil {
                guard let source = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
                // Uniform masks are resolution independent; avoid allocating a full canvas for reveal/hide-all.
                // A mask on its own placement keeps its pixels; the placement scales with the canvas.
                if (source.image.width == 1 && source.image.height == 1) || layer.maskPlacement != nil {
                    try source.validatePlaneRead();masks[layer.id] = source
                } else if let plane=source.linearPlane {
                    guard width * height <= DocumentLimits.documentPixelBudget-usedMaskPixels else { throw ProjectError.tooLarge }
                    usedMaskPixels += width * height
                    let mapping=BrushRaster.pixelToDocument(layer.transform,width:plane.width,height:plane.height)
                        .concatenating(CGAffineTransform(scaleX:sx,y:sy)).concatenating(CGAffineTransform(translationX:-left,y:-top))
                    let made=try LWFloatCompositor.project(plane,mapping:mapping,width:width,height:height,
                        workspace:workspace,sampling:options.sampling)
                    let asset=try ImportedImage(maskPlane:made,name:source.name)
                    try source.validatePlaneRead();try workspace.cancellation.check()
                    masks[layer.id]=asset;resizedMaskFile="\(layer.id.uuidString).mask.plane";resizedMaskReference=asset.planeArchiveReference
                } else {
                    guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                          width * height <= DocumentLimits.documentPixelBudget - usedMaskPixels else { throw ProjectError.tooLarge }
                    usedMaskPixels += width * height
                    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -left, y: -top)
                    context.scaleBy(x: sx, y: sy)
                    var sourceTransform = layer.transform
                    sourceTransform.sampling = options.sampling
                    LayerRenderer.drawCoverage(source.image, transform: sourceTransform, in: context)
                    guard let image = context.makeImage() else { throw ExportError.render }
                    masks[layer.id] = try LayerMask.asset(from: image)
                }
            }
            var resized = layer; resized.transform = transform
            resized.maskFile=resizedMaskFile;resized.maskPlaneArchiveReference=resizedMaskReference
            resized.maskPlacement = layer.maskPlacement.map { $0.placing($0.unitToDocument.concatenating(CGAffineTransform(scaleX:sx,y:sy))) }
            manifest.layers.append(resized)
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks, workingVersion:snapshot.workingVersion)
    }
}

/// Captured before asynchronous document work. A matching document ID alone
/// cannot authorize replacing a newer source recipe, history or selection epoch.
@MainActor struct LWDocumentEditAdmission {
    let document:CanvasDocument
    let selection:UUID?
    let selected:Set<UUID>
    let interactionToken:UUID?
    let epoch:UInt64
    let historyRevision:UUID
}

extension EditorSession {
    func captureDocumentEditAdmission() throws -> LWDocumentEditAdmission {
        guard let document else { throw ProjectError.invalid }
        return .init(document:document,selection:activeLayerID,selected:selectedLayerIDs,interactionToken:commandInteraction?.token,
            epoch:commandContextEpoch,historyRevision:history.currentRevision)
    }
    func validateDocumentEditAdmission(_ admission:LWDocumentEditAdmission) throws {
        try Task.checkCancellation()
        guard document == admission.document,activeLayerID == admission.selection,selectedLayerIDs == admission.selected,
            commandInteraction?.token == admission.interactionToken,commandContextEpoch == admission.epoch,
            history.currentRevision == admission.historyRevision else { throw ProjectError.invalid }
    }
    func applyDocumentSize(_ snapshot:ProjectSnapshot,actionName:String,admission:LWDocumentEditAdmission) throws {
        try validateDocumentEditAdmission(admission)
        guard snapshot.manifest.documentID == admission.document.id else { throw ProjectError.invalid }
        applyDocumentSize(snapshot,actionName:actionName)
    }
    func applyImageSize(_ snapshot: ProjectSnapshot) {
        applyDocumentSize(snapshot, actionName: "Image Size")
    }

    func applyDocumentSize(_ snapshot: ProjectSnapshot, actionName: String) {
        guard document?.id == snapshot.manifest.documentID else { return }
        beginEdit(actionName)
        let m = snapshot.manifest
        document = CanvasDocument(id: m.documentID, width: m.width, height: m.height,
            layers: m.layers.map { ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                shape: LayerShape.loaded($0.shape,image:snapshot.images[$0.id]?.image),effects:$0.effects,
                text: LayerText.loaded($0.text,image:snapshot.images[$0.id]?.image),liveSource:$0.liveSource) }, resolution: m.resolution ?? 72, guides: m.guides ?? [])
        endEdit()
        viewport.fit(documentSize: document!.size)
    }
}
