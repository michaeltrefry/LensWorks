import Foundation
import CoreGraphics

actor CanvasResizer {
    static let shared = CanvasResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: CanvasSizeOptions) async throws -> ProjectSnapshot {
        let needsFloatFill=options.fill != nil && (options.width > snapshot.manifest.width || options.height > snapshot.manifest.height)
            && (snapshot.manifest.layers.contains(where: { $0.liveSource != nil }) || snapshot.images.values.contains(where: { $0.linearPlane != nil }))
        let workspace:LWFloatWorkspace?=needsFloatFill ? try LWFloatWorkspace(workingSet:.sourceGraphs):nil
        return try await withTaskCancellationHandler {
            let result=try resizeOwned(snapshot,to:options,workspace:workspace)
            try workspace?.cancellation.check();try Task.checkCancellation()
            return result
        } onCancel: { workspace?.cancellation.cancel() }
    }
    private func resizeOwned(_ snapshot: ProjectSnapshot, to options: CanvasSizeOptions,
        workspace:LWFloatWorkspace?) throws -> ProjectSnapshot {
        guard (1...DocumentLimits.maxSide).contains(options.width), (1...DocumentLimits.maxSide).contains(options.height),
              (0...8).contains(options.anchor) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        let offset = options.offset(fromWidth: old.width, height: old.height)
        guard offset.x.isFinite, offset.y.isFinite, abs(offset.x) <= 1_000_000, abs(offset.y) <= 1_000_000 else {
            throw ProjectError.invalid
        }
        guard options.width != old.width || options.height != old.height || offset != .zero else { return snapshot }
        var manifest = try old.metadataCopy()
        manifest.width = options.width; manifest.height = options.height; manifest.layers = []
        manifest.guides = old.guides?.map { $0.offset(x:offset.x,y:offset.y) }
        for layer in old.layers {
            try Task.checkCancellation();try workspace?.cancellation.check()
            var transform = layer.transform
            transform.origin.x += offset.x
            transform.origin.y += offset.y
            guard transform.isValid else { throw ProjectError.tooLarge }
            var moved = layer; moved.transform = transform
            moved.maskPlacement = layer.maskPlacement.map { placement in
                var result = placement; result.origin.x += offset.x; result.origin.y += offset.y; return result
            }
            manifest.layers.append(moved)
        }
        var images = snapshot.images
        // A colored extension is separate bottom-layer content. The old canvas
        // intersection remains transparent, including holes in the existing artwork.
        if let color = options.fill, options.width > old.width || options.height > old.height {
            let used = images.values.reduce(0) { $0 + $1.image.width * $1.image.height }
            guard options.width * options.height <= DocumentLimits.documentPixelBudget - used,
                  manifest.layers.count < 10_000 else { throw ProjectError.tooLarge }
            guard [color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ProjectError.invalid
            }
            let asset: ImportedImage
            if old.layers.contains(where: { $0.liveSource != nil }) || snapshot.images.values.contains(where: { $0.linearPlane != nil }) {
                guard let workspace else { throw ProjectError.invalid }
                let linear = try LWLinearSurface.readColor(red:Double(color.red),green:Double(color.green),blue:Double(color.blue))
                let blank = try LWFloatCompositor.clearPlane(width:options.width,height:options.height,workspace:workspace)
                let made = try LWFloatCompositor.map(blank,workspace:workspace) { _,x,y in
                    let pixel=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
                    if CGRect(origin:offset,size:CGSize(width:old.width,height:old.height)).contains(pixel) { return .zero }
                    return SIMD4(linear.x,linear.y,linear.z,1)
                }
                asset = try ImportedImage(plane:made,name:"Canvas Extension")
                try workspace.cancellation.check()
            } else { asset = try autoreleasepool {
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let context = CGContext(data: nil, width: options.width, height: options.height,
                    bitsPerComponent: 8, bytesPerRow: options.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                context.translateBy(x: 0, y: CGFloat(options.height))
                context.scaleBy(x: 1, y: -1)
                context.setFillColor(CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])!)
                context.fill(CGRect(x: 0, y: 0, width: options.width, height: options.height))
                context.clear(CGRect(origin: offset, size: CGSize(width: old.width, height: old.height)))
                guard let image = context.makeImage() else { throw ExportError.render }
                let factor = min(1, 96 / CGFloat(max(options.width, options.height)))
                let tw = max(1, Int(CGFloat(options.width) * factor)), th = max(1, Int(CGFloat(options.height) * factor))
                guard let thumb = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                    bytesPerRow: tw * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ExportError.render
                }
                thumb.interpolationQuality = .high
                thumb.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
                guard let thumbnail = thumb.makeImage() else { throw ExportError.render }
                return ImportedImage(image: image, thumbnail: thumbnail, name: "Canvas Extension")
            } }
            let id = UUID()
            images[id] = asset
            manifest.layers.insert(ProjectLayerRecord(id: id, name: "Canvas Extension", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: options.width, height: options.height)),
                imageFile: "\(id.uuidString)." + (asset.linearPlane == nil ? "png":"plane"),planeArchiveReference:asset.planeArchiveReference), at: 0)
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: snapshot.masks, coverages: snapshot.coverages, workingVersion:snapshot.workingVersion)
    }
}
