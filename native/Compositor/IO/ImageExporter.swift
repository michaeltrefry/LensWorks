import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportError: LocalizedError {
    case tooLarge, render, encode
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Image export supports canvases up to \(DocumentLimits.maxSurfaceMegapixels) megapixels and \(DocumentLimits.maxSide.formatted()) pixels per side."
        case .render: "The canvas could not be rendered. Try a smaller canvas."
        case .encode: "The image could not be encoded."
        }
    }
}

actor ImageExporter {
    static let shared = ImageExporter()

    /// Full original plane development precedes document composition. Persisted
    /// backings are caches, never a replacement for changed original authority.
    func renderPlane(_ snapshot: ProjectSnapshot) async throws -> LWFloatPlane {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        return try await withTaskCancellationHandler {
            let topology = try LWSourceMetadataStorage.collectionBytes(count: snapshot.images.count + snapshot.masks.count,
                stride: MemoryLayout<UUID>.stride + MemoryLayout<ImportedImage>.stride)
            let copyLease = try workspace.workingSet.reserve(topology)
            defer { withExtendedLifetime(copyLease) {} }
            var images = snapshot.images
            for layer in snapshot.manifest.layers {
                try workspace.cancellation.check(); try Task.checkCancellation()
                guard let source = layer.liveSource else { continue }
                let made = try await LWSourceDeveloper.shared.evaluatePlane(source)
                guard made.surface.width == made.map.developedWidth,made.surface.height == made.map.developedHeight else { throw ProjectError.invalid }
                images[layer.id] = try ImportedImage(plane: made.surface,name: layer.name)
            }
            let output = try LWFloatCompositor.renderPlane(ProjectSnapshot(manifest: snapshot.manifest,images: images,masks: snapshot.masks,coverages: snapshot.coverages),workspace: workspace)
            try workspace.cancellation.check(); try Task.checkCancellation(); return output
        } onCancel: { workspace.cancellation.cancel() }
    }
    func render(_ snapshot: ProjectSnapshot) async throws -> ExportRaster {
        if snapshot.manifest.layers.contains(where:{$0.liveSource != nil}) || snapshot.images.values.contains(where:{$0.linear != nil || $0.linearPlane != nil}) {
            let plane=try await renderPlane(snapshot), provider=LWFloatPlaneImage(plane:plane)
            let image=try provider.image(); try provider.check()
            return ExportRaster(image:image,resolution:snapshot.manifest.resolution ?? 72,linearPlane:plane,planeImage:provider,sourceProtection:try LWSourceDestinationAuthority(snapshot))
        }
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        return try autoreleasepool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ExportError.render
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
            for layer in snapshot.manifest.layers {
                guard layer.imageFile == nil || snapshot.images[layer.id] != nil,
                      layer.maskFile == nil || snapshot.masks[layer.id] != nil else { throw ProjectError.missingImage }
            }
            try LiveMaskGraph.validate(snapshot.manifest.layers)
            let live = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height), source: { records[$0]?.maskSourceID }) { id, target in
                guard let layer = records[id], let image = snapshot.images[id]?.image else { return }
                let opacity = layer.effectiveOpacity(in: records)
                let mask = snapshot.mask(for: layer).flatMap { $0.clipImage(placement: $0.placement, over: layer.transform, width: image.width, height: image.height) }
                let effects = LayerEffectsRenderer.cached(image, mask: mask, effects: layer.effects)
                func drawLayer(_ mode: LayerBlendMode, _ into: CGContext) {
                    if let effects {
                        let grown = LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                        LayerRenderer.draw(effects.image, transform: grown, center: grown.center,
                            opacity: opacity, blendMode: mode, mask: nil, in: into)
                        return
                    }
                    LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center,
                        opacity: opacity, blendMode: mode, mask: mask, in: into)
                }
                let mode = layer.blendMode ?? .normal
                // Core Graphics blends these two wrong; see SeparableBlend.
                if SeparableBlend.needsSurface(mode), SeparableBlend.draw(mode, in: target, body: { drawLayer(.normal, $0) }) { return }
                drawLayer(mode, target)
            }
            live.adjustment = { records[$0]?.adjustment }
            live.adjustmentOpacity = { records[$0]?.effectiveOpacity(in: records) ?? 1 }
            live.adjustmentClip = { id, ctx in
                if let layer = records[id], let image = snapshot.mask(for: layer)?.enabledImage {
                    FolderMaskClip(image: image, transform: layer.transform).apply(center: layer.transform.center, in: ctx)
                }
            }
            live.prepareStacks(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, blend: { records[$0]?.blendMode ?? .normal })
            FolderMaskClip.draw(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, clip: { id in
                guard let folder = records[id], let image = snapshot.mask(for: folder)?.enabledImage else { return nil }
                let clip = FolderMaskClip(image: image, transform: folder.transform)
                return { clip.apply(center: folder.transform.center, in: $0) }
            }, in: context) { live.drawComposite($0, in: context) }
            guard let image = context.makeImage() else { throw ExportError.render }
            return ExportRaster(image: image, resolution: snapshot.manifest.resolution ?? 72, sourceProtection:try LWSourceDestinationAuthority(snapshot))
        }
    }

    /// The Space-bar preview, saved in the project's QuickLook folder: the flattened image on white, a JPEG up to
    /// 1,024 px on the long side, about 100–200 KB. Nil for canvases too large to flatten on every save.
    func quickLookImages(_ snapshot: ProjectSnapshot) async throws -> QuickLookImages? {
        guard snapshot.manifest.width * snapshot.manifest.height <= 50_000_000 else { return nil }
        let hasFloatSource = snapshot.manifest.layers.contains { $0.liveSource != nil } ||
            snapshot.images.values.contains { $0.linear != nil || $0.linearPlane != nil }
        if hasFloatSource {
            // A failed source/provider is not an optional missing preview. Stop
            // the atomic package save before its manifest/history is published.
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let raster = try await render(snapshot)
                let provider = raster.linearPlane.map { LWFloatPlaneImage(plane: $0, cancellation: workspace.cancellation) }
                let image = try provider?.image() ?? raster.image
                let preview = try scaledSourceJPEG(image, workspace: workspace, validate: {
                    try provider?.check(); try raster.check()
                })
                try raster.check(); try Task.checkCancellation()
                return QuickLookImages(preview: preview)
            } onCancel: { workspace.cancellation.cancel() }
        }
        // Retain the established optional QuickLook behavior for legacy rasters.
        guard let raster = try? await render(snapshot),
              let preview = try? scaledJPEG(raster.image, longSide: 1024),
              (try? raster.check()) != nil else { return nil }
        return QuickLookImages(preview: preview)
    }

    /// Small preview context plus streamed encoded output. The final Data charge
    /// travels with its allocation through save/publication and every retained copy.
    private func scaledSourceJPEG(_ image: CGImage, workspace: LWFloatWorkspace,
        validate: () throws -> Void) throws -> Data {
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let scratch = try workspace.workingSet.reserve(width * height * 8)
        defer { withExtendedLifetime(scratch) {} }
        try workspace.cancellation.check(); try validate()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.render }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1); context.fill(bounds)
        context.interpolationQuality = .high; context.draw(image, in: bounds)
        try validate(); try workspace.cancellation.check()
        guard let flattened = context.makeImage() else { throw ExportError.render }
        let encoded = try encodeFile(flattened, type: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary,
            workspace: workspace, validate: validate)
        return try encoded.data()
    }

    private func scaledJPEG(_ image: CGImage, longSide: CGFloat) throws -> Data {
        let scale = min(1, longSide / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return try autoreleasepool {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw ExportError.render }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            return try encode(flattened, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        }
    }

    func pngData(_ snapshot: ProjectSnapshot) async throws -> Data {
        // This convenience API holds an admitted encoded buffer; the public export
        // below streams to disk and does not require a full-resolution Data value.
        let raster=try await render(snapshot),workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        return try await withTaskCancellationHandler {
            let provider=raster.linearPlane.map { LWFloatPlaneImage(plane:$0,format:.rgba16SRGB,cancellation:workspace.cancellation) }
            let image=try provider?.image() ?? raster.linear?.integerOutput(bits:16,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) ?? raster.image
            let encoded=try encodeFile(image,type:.png,properties:[kCGImagePropertyDPIWidth:raster.resolution,kCGImagePropertyDPIHeight:raster.resolution] as CFDictionary,
                workspace:workspace,sourceProtection:raster.sourceProtection,validate:{ try provider?.check();try raster.check() })
            return try encoded.data()
        } onCancel: { workspace.cancellation.cancel() }
    }
    private func encodeFile(_ image:CGImage,type:UTType,properties:CFDictionary?,workspace:LWFloatWorkspace,
        sourceProtection:LWSourceDestinationAuthority? = nil, validate:() throws -> Void) throws -> LWEncodedImageFile {
        let output=try LWEncodedImageFile(workspace:workspace,sourceProtection:sourceProtection)
        let consumer=try output.consumer()
        guard let destination=CGImageDestinationCreateWithDataConsumer(consumer,type.identifier as CFString,1,nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(destination,image,properties)
        let finalized=CGImageDestinationFinalize(destination)
        try validate();try workspace.cancellation.check()
        guard finalized else { throw ExportError.encode }
        return try output.finish(validate:validate)
    }
    func jpegFile(_ raster:ExportRaster,options:JPEGOptions) async throws -> JPEGFileResult {
        guard [options.quality,Double(options.red),Double(options.green),Double(options.blue)].allSatisfy(\.isFinite),
            (0...1).contains(options.red),(0...1).contains(options.green),(0...1).contains(options.blue) else { throw ProjectError.invalid }
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        return try await withTaskCancellationHandler {
            try raster.check()
            let plane=try raster.linearPlane ?? LWFloatCompositor.from(raster.image,workspace:workspace)
            // Matte is explicitly an output conversion, not a persisted RAW edit.
            let matte=try LWLinearSurface.readColor(red:Double(options.red),green:Double(options.green),blue:Double(options.blue))
            let flattened=try LWFloatCompositor.map(plane,workspace:workspace) { p,_,_ in
                let rgb=SIMD3(p.x,p.y,p.z)*p.w+matte*(1-p.w)
                return SIMD4(rgb.x,rgb.y,rgb.z,1)
            }
            let provider=LWFloatPlaneImage(plane:flattened,format:.rgba8SRGB,cancellation:workspace.cancellation)
            let image=try provider.image()
            let encoded=try encodeFile(image,type:.jpeg,properties:[kCGImageDestinationLossyCompressionQuality:min(1,max(0,options.quality)),
                kCGImagePropertyDPIWidth:raster.resolution,kCGImagePropertyDPIHeight:raster.resolution] as CFDictionary,
                workspace:workspace,sourceProtection:raster.sourceProtection,validate:{ try provider.check();try raster.check() })
            try encoded.check()
            let side=min(max(image.width,image.height),8192),scale=min(1,Double(side)/Double(max(image.width,image.height)))
            let width=max(1,Int(ceil(Double(image.width)*scale))),height=max(1,Int(ceil(Double(image.height)*scale)))
            let lease=try workspace.workingSet.reserve((width*4+64)*height)
            guard let source=CGImageSourceCreateWithURL(encoded.url as CFURL,nil),
                let preview=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceThumbnailMaxPixelSize:side,kCGImageSourceShouldCacheImmediately:true,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { throw ExportError.encode }
            guard preview.width<=width,preview.height<=height else { throw ExportError.encode }
            let owned=try LWJPEGPreviewImage.materialize(preview,workspace:workspace,validate:{ try encoded.check();try provider.check();try raster.check() })
            let display=try owned.image();try owned.check()
            // Only this scope owns the temporary ImageIO thumbnail. The returned
            // provider keeps its private generation/lease through the final alias.
            withExtendedLifetime((preview,lease)) {}
            try encoded.check();try provider.check();try raster.check()
            return JPEGFileResult(file:encoded,preview:display,previewOwner:owned)
        } onCancel: { workspace.cancellation.cancel() }
    }

    private func encode(_ image: CGImage, type: UTType, properties: CFDictionary? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    func jpeg(_ raster: ExportRaster, options: JPEGOptions) async throws -> JPEGResult {
        if raster.linearPlane != nil {
            let result=try await jpegFile(raster,options:options)
            try result.check()
            return JPEGResult(data:try result.file.data(),preview:result.preview,previewOwner:result.previewOwner)
        }
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = raster.image
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.render }
            context.setFillColor(CGColor(colorSpace: context.colorSpace!,
                components: [options.red, options.green, options.blue, 1])!)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            try Task.checkCancellation()
            let data = try encode(flattened, type: .jpeg,
                properties: [kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.quality)),
                             kCGImagePropertyDPIWidth: raster.resolution,
                             kCGImagePropertyDPIHeight: raster.resolution] as CFDictionary)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    // Full size, so the dialog's 100% view shows the real artifacts; capped to keep memory in bounds.
                    kCGImageSourceThumbnailMaxPixelSize: min(max(image.width, image.height), 8192),
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ExportError.encode }
            return JPEGResult(data: data, preview: preview)
        }
    }

    func exportPNG(_ snapshot: ProjectSnapshot, to url: URL, workingVersion: LensWorksWorkingVersion? = nil) async throws {
        try LWSourceDestinationAuthority(snapshot).validate(url)
        try workingVersion?.validateDestination(url)
        let raster=try await render(snapshot),workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        try await withTaskCancellationHandler {
            let provider=raster.linearPlane.map { LWFloatPlaneImage(plane:$0,format:.rgba16SRGB,cancellation:workspace.cancellation) }
            let image=try provider?.image() ?? raster.linear?.integerOutput(bits:16,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) ?? raster.image
            let encoded=try encodeFile(image,type:.png,properties:[kCGImagePropertyDPIWidth:raster.resolution,kCGImagePropertyDPIHeight:raster.resolution] as CFDictionary,
                workspace:workspace,sourceProtection:raster.sourceProtection,validate:{ try provider?.check();try raster.check() })
            try encoded.publish(to:url,workingVersion:workingVersion)
        } onCancel: { workspace.cancellation.cancel() }
    }

    func write(_ file:LWEncodedImageFile,to url:URL,workingVersion:LensWorksWorkingVersion? = nil) throws {
        try file.publish(to:url,workingVersion:workingVersion)
    }

    func write(_ data: Data, to url: URL, workingVersion: LensWorksWorkingVersion? = nil) throws {
        try workingVersion?.validateDestination(url)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) }
            catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}

nonisolated struct QuickLookImages: Sendable {
    let preview: Data
}
nonisolated struct ExportRaster: @unchecked Sendable {
    let image: CGImage
    var resolution: Double = 72
    /// Exact full-resolution samples before the explicitly bounded integer codec.
    var linear:LWLinearSurface? = nil
    var linearPlane:LWFloatPlane? = nil
    var planeImage:LWFloatPlaneImage? = nil
    var sourceProtection:LWSourceDestinationAuthority? = nil
    func check() throws { try planeImage?.check() }
}
nonisolated struct JPEGOptions: Equatable, Sendable {
    var quality: Double = 0.85
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
}
nonisolated struct JPEGResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
    var previewOwner:LWJPEGPreviewImage? = nil
    func check() throws { try previewOwner?.check() }
}
nonisolated struct JPEGFileResult: @unchecked Sendable {
    let file: LWEncodedImageFile
    let preview: CGImage
    let previewOwner:LWJPEGPreviewImage
    func check() throws { try file.check();try previewOwner.check() }
}
