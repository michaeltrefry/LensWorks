import Foundation
import CoreGraphics
import CoreImage

/// Float branch of the retained document graph. Intrinsic painted masks remain their
/// stored coverage; source alpha and intermediate clipping never pass through L8.
nonisolated enum LWFloatCompositor {
    static let maximumBytes = LWSourceDeveloper.maximumResultBytes
    static func clear(_ width:Int,_ height:Int) throws -> LWLinearSurface {
        let n = try LWLinearSurface.extent(width:width,height:height,maximumBytes:maximumBytes)
        return try LWLinearSurface(width:width,height:height,pixels:[SIMD4<Float>](repeating:.zero,count:n),maximumBytes:maximumBytes)
    }
    static func place(_ image:CGImage, transform:LayerTransform, width:Int,height:Int) throws -> LWLinearSurface {
        let context = try LWLinearSurface.context(width:width,height:height,maximumBytes:maximumBytes)
        context.translateBy(x:0,y:CGFloat(height)); context.scaleBy(x:1,y:-1)
        context.translateBy(x:transform.center.x,y:transform.center.y)
        context.rotate(by:transform.radians)
        context.scaleBy(x:transform.flipX ? -1 : 1,y:transform.flipY ? 1 : -1)
        context.interpolationQuality = transform.sampling.quality
        context.draw(image,in:CGRect(x:-transform.size.width/2,y:-transform.size.height/2,width:transform.size.width,height:transform.size.height))
        guard let made = context.makeImage() else { throw ExportError.render }
        return try LWLinearSurface.read(made,maximumBytes:maximumBytes)
    }
    static func intrinsicMask(_ image:CGImage, transform:LayerTransform,width:Int,height:Int) throws -> [Float] {
        // Promotes the declared coverage to float. This is not a source alpha conversion.
        let context = try LWLinearSurface.context(width:width,height:height,maximumBytes:maximumBytes)
        context.translateBy(x:0,y:CGFloat(height)); context.scaleBy(x:1,y:-1)
        LayerRenderer.drawCoverage(image,transform:transform,in:context)
        guard let made = context.makeImage() else { throw ExportError.render }
        return try LWLinearSurface.read(made,maximumBytes:maximumBytes).pixels.map(\.w)
    }
    /// Straight extended-linear float in and out. Core Image's blend kernels clamp operands and
    /// results to [0, 1]; LWFloatBlend keeps the same in-range definition without that clamp.
    static func blend(_ top:LWLinearSurface, over bottom:LWLinearSurface,mode:LayerBlendMode) throws -> LWLinearSurface {
        guard top.width == bottom.width, top.height == bottom.height else { throw ProjectError.invalid }
        var result = try clear(top.width,top.height)
        top.pixels.withUnsafeBufferPointer { t in bottom.pixels.withUnsafeBufferPointer { b in
            result.pixels.withUnsafeMutableBufferPointer { o in LWFloatBlend.blend(t,over:b,mode:mode,into:o) }
        } }
        try result.validate(maximumBytes:maximumBytes); return result
    }
    static func render(_ snapshot:ProjectSnapshot) throws -> LWLinearSurface {
        try LayerHierarchy.validate(snapshot.manifest.layers); try LiveMaskGraph.validate(snapshot.manifest.layers)
        let w = snapshot.manifest.width,h = snapshot.manifest.height
        let extent = try LWLinearSurface.extent(width:w,height:h,maximumBytes:maximumBytes)
        // Current output, one foreground, and one blend result are jointly admitted.
        guard extent <= maximumBytes / (MemoryLayout<SIMD4<Float>>.stride * 3) else { throw ProjectError.tooLarge }
        let records = Dictionary(uniqueKeysWithValues:snapshot.manifest.layers.map { ($0.id,$0) })
        var visiting = Set<UUID>()
        func own(_ record:ProjectLayerRecord) throws -> LWLinearSurface {
            guard let asset = snapshot.images[record.id] else {
                if record.imageFile != nil { throw ProjectError.missingImage }
                return try clear(w,h)
            }
            var local = try asset.linear ?? LWLinearSurface.read(asset.image,maximumBytes:maximumBytes)
            if let mask = snapshot.mask(for:record), mask.isEnabled {
                guard let coverageImage = mask.clipImage(placement:mask.placement,over:record.transform,width:local.width,height:local.height) else { throw ExportError.render }
                let coverage = try intrinsicMask(coverageImage,transform:LayerTransform(origin:.zero,size:CGSize(width:local.width,height:local.height)),width:local.width,height:local.height)
                for i in local.pixels.indices { local.pixels[i].w *= coverage[i] }
            }
            if let effects = record.effects?.visible, !effects.isEmpty {
                let made = try LWFloatEffects.local(local,effects:effects)
                return try place(try made.surface.cgImage(),transform:LayerEffectsRenderer.placed(record.transform,image:try made.surface.cgImage(),inset:made.inset),width:w,height:h)
            }
            return try place(try local.cgImage(),transform:record.transform,width:w,height:h)
        }
        func alpha(_ id:UUID) throws -> [Float] {
            guard visiting.count < 256, visiting.insert(id).inserted, let record = records[id] else { throw ProjectError.invalid }
            defer { visiting.remove(id) }
            var surface = try own(record)
            if let source = record.maskSourceID {
                let coverage = try alpha(source)
                for i in surface.pixels.indices { surface.pixels[i].w *= coverage[i] }
            }
            return surface.pixels.map(\.w)
        }
        func folderCoverage(_ record:ProjectLayerRecord) throws -> [Float]? {
            var id = record.parentID, result: [Float]?
            while let parent = id, let folder = records[parent] {
                if let mask = snapshot.mask(for:folder), mask.isEnabled {
                    let coverage = try intrinsicMask(mask.asset.image,transform:mask.placement ?? folder.transform,width:w,height:h)
                    if result == nil { result = coverage }
                    else { for i in coverage.indices { result![i] *= coverage[i] } }
                }
                id = folder.parentID
            }
            return result
        }
        let visible = LayerHierarchy.visibleLayers(snapshot.manifest.layers)
        var output = try clear(w,h), index = 0
        while index < visible.count {
            let layer = visible[index]
            if let adjustment = layer.adjustment {
                var adjusted = try adjustment.apply(output,region:CGRect(x:0,y:0,width:w,height:h),scale:1)
                if (layer.blendMode ?? .normal) != .normal { adjusted = try blend(adjusted,over:output,mode:layer.blendMode ?? .normal) }
                let clip = try layer.maskSourceID.map(alpha)
                let mask = try snapshot.mask(for:layer).flatMap { owned -> [Float]? in
                    guard owned.isEnabled else { return nil }
                    return try intrinsicMask(owned.asset.image,transform:owned.placement ?? layer.transform,width:w,height:h)
                }
                let folder = try folderCoverage(layer)
                for i in output.pixels.indices {
                    let amount = Float(layer.effectiveOpacity(in:records)) * (clip?[i] ?? 1) * (mask?[i] ?? 1) * (folder?[i] ?? 1)
                    // An adjustment changes color, not the existing alpha.
                    let oldAlpha = output.pixels[i].w
                    output.pixels[i] += (adjusted.pixels[i] - output.pixels[i]) * amount
                    output.pixels[i].w = oldAlpha
                }
                index += 1; continue
            }
            var foreground = try own(layer)
            if let source = layer.maskSourceID {
                let coverage = try alpha(source)
                for i in foreground.pixels.indices { foreground.pixels[i].w *= coverage[i] }
            }
            if let folder = try folderCoverage(layer) {
                for i in foreground.pixels.indices { foreground.pixels[i].w *= folder[i] }
            }
            for i in foreground.pixels.indices { foreground.pixels[i].w *= Float(layer.effectiveOpacity(in:records)) }
            var next = index + 1
            // A contiguous clipping stack shares its base's alpha exactly, rather
            // than repeatedly painting that coverage over itself.
            let baseAlpha = foreground.pixels.map(\.w)
            while next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                let child = visible[next]
                if let adjustment = child.adjustment {
                    var adjusted=try adjustment.apply(foreground,region:CGRect(x:0,y:0,width:w,height:h),scale:1)
                    if (child.blendMode ?? .normal) != .normal { adjusted=try blend(adjusted,over:foreground,mode:child.blendMode ?? .normal) }
                    let mask=try snapshot.mask(for:child).flatMap { owned -> [Float]? in
                        guard owned.isEnabled else { return nil }
                        return try intrinsicMask(owned.asset.image,transform:owned.placement ?? child.transform,width:w,height:h)
                    }
                    let folder=try folderCoverage(child)
                    for i in foreground.pixels.indices {
                        let amount=Float(child.effectiveOpacity(in:records))*(mask?[i] ?? 1)*(folder?[i] ?? 1)
                        foreground.pixels[i] += (adjusted.pixels[i]-foreground.pixels[i])*amount
                    }
                } else {
                    var childSurface = try own(child)
                    for i in childSurface.pixels.indices { childSurface.pixels[i].w *= Float(child.effectiveOpacity(in:records)) }
                    foreground = try blend(childSurface,over:foreground,mode:child.blendMode ?? .normal)
                }
                for i in foreground.pixels.indices { foreground.pixels[i].w = baseAlpha[i] }
                next += 1
            }
            output = try blend(foreground,over:output,mode:layer.blendMode ?? .normal)
            index = next
        }
        try output.validate(maximumBytes:maximumBytes); return output
    }
}

nonisolated extension LWFloatCompositor {
    static func map(_ source: LWFloatPlane, workspace: LWFloatWorkspace,
        _ operation: (SIMD4<Float>, Int, Int) throws -> SIMD4<Float>) throws -> LWFloatPlane {
        try LWFloatKernelWorkspace(makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) },
            makeScratchDirectory: { try workspace.makeScratchDirectory() }, fileOwner: workspace).map(source) { pixel, x, y, _ in
                try operation(pixel, x, y)
            }
    }
    /// Compatibility input already owns straight f32 samples. Copy admitted
    /// ranges directly; a CGImage round-trip would erase hidden RGB at alpha zero.
    static func from(_ surface:LWLinearSurface,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        let builder=try workspace.makeBuilder(width:surface.width,height:surface.height)
        while let range=builder.nextRange {
            try workspace.cancellation.check();try Task.checkCancellation()
            let bytes=try range.validate(frameWidth:surface.width,frameHeight:surface.height)
            let lease=try workspace.workingSet.reserve(bytes)
            var pixels=[SIMD4<Float>]();pixels.reserveCapacity(bytes/16)
            for y in range.y..<range.y+range.height {
                pixels.append(contentsOf:surface.pixels[(y*surface.width+range.x)..<(y*surface.width+range.x+range.width)])
            }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:pixels,maximumBytes:bytes),at:range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }
    /// Read an already retained legacy package directly into admitted tiles.
    /// Header validation precedes allocation; no decoded whole-image Array is
    /// formed alongside the encoded source/selection/composite backing.
    static func fromEncodedSurface(_ data:Data,maximumFileBytes:Int,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        let extent=try LWLinearSurface.packageExtent(data,maximumFileBytes:maximumFileBytes)
        try workspace.cancellation.check()
        let builder=try workspace.makeBuilder(width:extent.width,height:extent.height)
        while let range=builder.nextRange {
            try workspace.cancellation.check()
            let bytes=try range.validate(frameWidth:extent.width,frameHeight:extent.height)
            let lease=try workspace.workingSet.reserve(bytes)
            var pixels=[SIMD4<Float>]();pixels.reserveCapacity(bytes/16)
            for y in range.y..<(range.y+range.height) { for x in range.x..<(range.x+range.width) {
                try workspace.cancellation.check()
                let offset=24+(y*extent.width+x)*16
                func word(_ channel:Int)->Float {
                    let start=offset+channel*4
                    let bits=(0..<4).reduce(UInt32(0)) { $0 | UInt32(data[start+$1]) << ($1*8) }
                    return Float(bitPattern:bits)
                }
                let pixel=SIMD4(word(0),word(1),word(2),word(3))
                guard pixel.x.isFinite,pixel.y.isFinite,pixel.z.isFinite,pixel.w.isFinite,(0...1).contains(pixel.w) else { throw ProjectError.invalid }
                pixels.append(pixel)
            } }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:pixels,maximumBytes:bytes),at:range)
            withExtendedLifetime(lease) {}
        }
        try workspace.cancellation.check()
        return try builder.finish()
    }
    static func from(_ image: CGImage, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try place(image, transform: LayerTransform(origin: .zero, size: CGSize(width: image.width, height: image.height)),
            width: image.width, height: image.height, workspace: workspace)
    }
    static func project(_ source: LWFloatPlane, mapping: CGAffineTransform, width: Int, height: Int,
        workspace: LWFloatWorkspace, sampling: LayerSampling = .high) throws -> LWFloatPlane {
        guard [mapping.a, mapping.b, mapping.c, mapping.d, mapping.tx, mapping.ty].allSatisfy(\.isFinite),
            mapping.a * mapping.d - mapping.b * mapping.c != 0 else { throw ProjectError.invalid }
        if sampling == .nearest { return try projectNearest(source, mapping: mapping, width: width, height: height, workspace: workspace) }
        let provider = LWFloatPlaneImage(plane: source,cancellation: workspace.cancellation), image = try provider.image()
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: width, frameHeight: height)
                let lease = try workspace.workingSet.reserve(bytes * 8)
                let context = try LWLinearSurface.context(width: range.width, height: range.height, maximumBytes: bytes)
                context.translateBy(x: -CGFloat(range.x), y: CGFloat(range.y + range.height)); context.scaleBy(x: 1, y: -1)
                context.concatenate(mapping); context.interpolationQuality = sampling.quality
                context.translateBy(x: 0, y: CGFloat(source.height)); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
                guard let made = context.makeImage() else { throw ExportError.render }
                try provider.check(); try builder.append(LWLinearSurface.read(made, maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
        }
        try provider.check(); return try builder.finish()
    }
    /// Nearest-neighbour projection evaluated directly on straight f32 samples. Each destination
    /// pixel centre maps through the inverse affine to one source pixel; centres outside the source
    /// are transparent. CoreGraphics is not used: its float draw path drops the last source column
    /// when it upscales an image that is exactly one row tall, and it would premultiply hidden RGB.
    static func projectNearest(_ source: LWFloatPlane, mapping: CGAffineTransform, width: Int, height: Int,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard source.workingSet === workspace.workingSet else { throw ProjectError.invalid }
        let inverse = mapping.inverted(), sampler = source.sampler(edge: .transparent)
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try workspace.cancellation.check(); try Task.checkCancellation()
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            let lease = try workspace.workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](); pixels.reserveCapacity(bytes / 16)
            for y in range.y..<(range.y + range.height) { for x in range.x..<(range.x + range.width) {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
                guard point.x.isFinite, point.y.isFinite else { throw ProjectError.invalid }
                let sx = floor(point.x), sy = floor(point.y)
                guard sx >= 0, sy >= 0, sx < CGFloat(source.width), sy < CGFloat(source.height) else { pixels.append(.zero); continue }
                pixels.append(try sampler.pixel(x: Int(sx), y: Int(sy), edge: .transparent))
            } }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }
    /// Exact area-average reduction in premultiplied float: every output pixel is the coverage-
    /// weighted mean of the source pixels under its footprint. Used to give the Camera Raw preview
    /// a reduced grid of the decoded source before development.
    static func downscale(_ source: LWFloatPlane, width: Int, height: Int, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard source.workingSet === workspace.workingSet, width > 0, height > 0,
            width <= source.width, height <= source.height else { throw ProjectError.invalid }
        let sx = Double(source.width) / Double(width), sy = Double(source.height) / Double(height)
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try workspace.cancellation.check(); try Task.checkCancellation()
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            let left = Int(floor(Double(range.x) * sx)), right = min(source.width, Int(ceil(Double(range.x + range.width) * sx)))
            let top = Int(floor(Double(range.y) * sy)), bottom = min(source.height, Int(ceil(Double(range.y + range.height) * sy)))
            let input = try source.read(LWFloatRange(x: left, y: top, width: right - left, height: bottom - top))
            let lease = try workspace.workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](); pixels.reserveCapacity(bytes / 16)
            for y in range.y..<(range.y + range.height) {
                let y0 = Double(y) * sy, y1 = y0 + sy
                for x in range.x..<(range.x + range.width) {
                    let x0 = Double(x) * sx, x1 = x0 + sx
                    var sum = SIMD4<Double>.zero
                    for iy in Int(floor(y0))..<min(source.height, Int(ceil(y1))) {
                        let wy = min(y1, Double(iy + 1)) - max(y0, Double(iy))
                        for ix in Int(floor(x0))..<min(source.width, Int(ceil(x1))) {
                            let w = (min(x1, Double(ix + 1)) - max(x0, Double(ix))) * wy
                            let p = input.surface.pixels[(iy - top) * input.range.width + ix - left]
                            let a = Double(p.w) * w
                            sum += SIMD4(Double(p.x) * a, Double(p.y) * a, Double(p.z) * a, a)
                        }
                    }
                    let alpha = sum.w / (sx * sy)
                    pixels.append(sum.w > 0 ? SIMD4(Float(sum.x / sum.w), Float(sum.y / sum.w), Float(sum.z / sum.w), Float(min(1, alpha))) : .zero)
                }
            }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }
    static func intrinsicMask(_ image: CGImage, transform: LayerTransform, width: Int, height: Int,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: width, frameHeight: height)
                let lease = try workspace.workingSet.reserve(bytes * 8)
                let context = try LWLinearSurface.context(width: range.width, height: range.height, maximumBytes: bytes)
                context.translateBy(x: -CGFloat(range.x), y: CGFloat(range.y + range.height)); context.scaleBy(x: 1, y: -1)
                LayerRenderer.drawCoverage(image, transform: transform, in: context)
                guard let made = context.makeImage() else { throw ExportError.render }
                try builder.append(LWLinearSurface.read(made, maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
        }
        return try builder.finish()
    }
    static func clearPlane(width: Int, height: Int, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            let lease = try workspace.workingSet.reserve(bytes)
            let surface = try LWLinearSurface(width: range.width, height: range.height,
                pixels: [SIMD4<Float>](repeating: .zero, count: bytes / 16), maximumBytes: bytes)
            try builder.append(surface, at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }

    /// All retained blend modes are pointwise. The same float/profile/operator
    /// boundary is evaluated on complete globally aligned pairs of ranges.
    static func blend(_ top: LWFloatPlane, over bottom: LWFloatPlane,
        mode: LayerBlendMode, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard top.width == bottom.width, top.height == bottom.height,
            top.workingSet === workspace.workingSet, bottom.workingSet === workspace.workingSet else { throw ProjectError.invalid }
        let builder = try workspace.makeBuilder(width: bottom.width, height: bottom.height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: bottom.width, frameHeight: bottom.height)
                // Source tiles retain their own leases. Admit copied providers,
                // output/context/readback and conversion buffers separately.
                let lease = try workspace.workingSet.reserve(bytes * 8)
                let foreground = try top.read(range: range), background = try bottom.read(range: range)
                func resident(_ tile: LWFloatTile) throws -> LWLinearSurface {
                    try LWLinearSurface(width: tile.surface.width, height: tile.surface.height,
                        pixels: Array(tile.surface.pixels), maximumBytes: bytes)
                }
                let made = try blend(resident(foreground), over: resident(background), mode: mode)
                try builder.append(made, at: range)
                withExtendedLifetime(lease) {}
            }
        }
        return try builder.finish()
    }

    static func place(_ source: LWFloatPlane, transform: LayerTransform, width: Int, height: Int,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard source.workingSet === workspace.workingSet else { throw ProjectError.invalid }
        let provider = LWFloatPlaneImage(plane: source,cancellation: workspace.cancellation), image = try provider.image()
        let result = try place(image, transform: transform, width: width, height: height, workspace: workspace)
        try provider.check()
        return result
    }
    static func place(_ image: CGImage, transform: LayerTransform, width: Int, height: Int,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: width, frameHeight: height)
                let lease = try workspace.workingSet.reserve(bytes * 8)
                let context = try LWLinearSurface.context(width: range.width, height: range.height, maximumBytes: bytes)
                context.translateBy(x: -CGFloat(range.x), y: CGFloat(range.y + range.height))
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: transform.center.x, y: transform.center.y)
                context.rotate(by: transform.radians)
                context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
                context.interpolationQuality = transform.sampling.quality
                if let part = visiblePart(of: image, transform: transform, range: range) {
                    context.draw(part.image, in: part.rect)
                }
                guard let made = context.makeImage() else { throw ExportError.render }
                try builder.append(LWLinearSurface.read(made, maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
        }
        return try builder.finish()
    }

    /// The part of `image` that can reach `range` when `transform` places it at its own pixel size on whole-pixel
    /// coordinates, and where that part is drawn in the layer's local space. Core Graphics reads every row of an
    /// image it draws; cropping keeps such a tile's placement proportional to the tile rather than to the layer.
    /// Placement is then a pixel copy, so the cropped draw is identical to the uncropped one. Any other transform
    /// (rotation, scaling, flips, fractional origins) resamples, and Core Graphics' resampling depends on the
    /// drawn image's extent, so those draw the whole image as before. Nil when the layer does not reach the range.
    static func visiblePart(of image: CGImage, transform: LayerTransform, range: LWFloatRange) -> (image: CGImage, rect: CGRect)? {
        let w = transform.size.width, h = transform.size.height
        let full = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        guard transform.radians == 0, !transform.flipX, !transform.flipY, w == CGFloat(image.width), h == CGFloat(image.height),
              transform.origin.x == transform.origin.x.rounded(), transform.origin.y == transform.origin.y.rounded() else { return (image, full) }
        // Image pixels, top row first, in document pixels relative to the layer's origin; one pixel of margin.
        let crop = CGRect(x: CGFloat(range.x) - transform.origin.x, y: CGFloat(range.y) - transform.origin.y,
                          width: CGFloat(range.width), height: CGFloat(range.height))
            .insetBy(dx: -1, dy: -1).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        if crop.width >= CGFloat(image.width) && crop.height >= CGFloat(image.height) { return (image, full) }
        guard let part = image.cropping(to: crop) else { return (image, full) }
        // Local space runs up from the layer's centre: the image's top row is at the rectangle's maxY.
        return (part, CGRect(x: full.minX + crop.minX, y: full.maxY - crop.maxY, width: crop.width, height: crop.height))
    }

    /// Full document graph, with immutable range-backed intermediates. Preview and
    /// export share this path; output size changes are downstream of development.
    ///
    /// `region` evaluates the same full-resolution graph for one rectangle of the document: every
    /// layer and mask placement is expressed relative to the region and document-anchored
    /// adjustments (noise, grain) keep their document coordinates. Pointwise stages are therefore
    /// identical to the whole-frame samples; a caller evaluating a spatial adjustment (blur) widens
    /// the region by `LWDocumentTileRenderer.halo` and discards the apron.
    static func renderPlane(_ snapshot: ProjectSnapshot, region: LWFloatRange? = nil, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try LayerHierarchy.validate(snapshot.manifest.layers); try LiveMaskGraph.validate(snapshot.manifest.layers)
        try LWFloatPlane.validateExtent(width: snapshot.manifest.width, height: snapshot.manifest.height)
        var snapshot = snapshot, documentOrigin = CGPoint.zero
        // A folder or adjustment mask without its own placement covers the whole document.
        var documentMaskFrame = LayerTransform(origin: .zero, size: CGSize(width: snapshot.manifest.width, height: snapshot.manifest.height))
        if let region {
            _ = try region.validate(frameWidth: snapshot.manifest.width, frameHeight: snapshot.manifest.height)
            var manifest = snapshot.manifest
            let dx = CGFloat(region.x), dy = CGFloat(region.y)
            func shifted(_ t: LayerTransform) -> LayerTransform { var t = t; t.origin.x -= dx; t.origin.y -= dy; return t }
            for i in manifest.layers.indices {
                manifest.layers[i].transform = shifted(manifest.layers[i].transform)
                manifest.layers[i].maskPlacement = manifest.layers[i].maskPlacement.map(shifted)
            }
            manifest.width = region.width; manifest.height = region.height
            snapshot = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks, workingVersion: snapshot.workingVersion)
            documentOrigin = CGPoint(x: dx, y: dy)
            documentMaskFrame.origin = CGPoint(x: -dx, y: -dy)
        }
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
        var visiting = Set<UUID>()
        func checkedMask(_ layer: ProjectLayerRecord, local: LWFloatPlane? = nil) throws -> LWFloatPlane? {
            guard var mask = snapshot.mask(for: layer), mask.isEnabled else { return nil }
            if local == nil, mask.placement == nil { mask.placement = documentMaskFrame }
            let w = local?.width ?? width, h = local?.height ?? height
            let target = local != nil ? layer.transform : LayerTransform(origin:.zero,size:CGSize(width:w,height:h))
            return try LWSourceMaskReconcile.coveragePlane(mask,over:target,width:w,height:h,workspace:workspace)
        }
        func applyAlpha(_ surface: LWFloatPlane, coverage: LWFloatPlane?, opacity: Float = 1) throws -> LWFloatPlane {
            guard coverage.map({ $0.width == surface.width && $0.height == surface.height }) ?? true,
                opacity.isFinite, (0...1).contains(opacity) else { throw ProjectError.invalid }
            // No coverage at full opacity is the identity: keep the immutable plane, do not copy it.
            if coverage == nil, opacity == 1 { return surface }
            let sampler = coverage?.sampler()
            return try map(surface, workspace: workspace) { pixel, x, y in
                var result = pixel; result.w *= try (sampler?.pixel(x: x, y: y).w ?? 1) * opacity; return result
            }
        }
        func own(_ record: ProjectLayerRecord) throws -> LWFloatPlane {
            guard let asset = snapshot.images[record.id] else {
                guard record.imageFile == nil else { throw ProjectError.missingImage }
                return try clearPlane(width: width, height: height, workspace: workspace)
            }
            // A plain raster places its image once; converting it to a whole local plane first
            // would materialize the full layer even when only one region of it is evaluated.
            if asset.linearPlane == nil, snapshot.mask(for: record)?.isEnabled != true, record.effects?.visible.isEmpty ?? true {
                return try place(asset.image, transform: record.transform, width: width, height: height, workspace: workspace)
            }
            var local = try asset.linearPlane ?? from(asset.image, workspace: workspace)
            local = try applyAlpha(local, coverage: checkedMask(record, local: local))
            if let effects = record.effects?.visible, !effects.isEmpty {
                let made = try LWFloatEffects.local(local, effects: effects, workspace: workspace)
                // Only dimensions enter placement; retain the range provider until
                // the complete transformed output has checked every read.
                let provider = LWFloatPlaneImage(plane: made.surface,cancellation: workspace.cancellation), image = try provider.image()
                let output = try place(made.surface,
                    transform: LayerEffectsRenderer.placed(record.transform, image: image, inset: made.inset),
                    width: width, height: height, workspace: workspace)
                try provider.check(); try asset.validatePlaneRead(); return output
            }
            let output = try place(local, transform: record.transform, width: width, height: height, workspace: workspace)
            try asset.validatePlaneRead(); return output
        }
        func alpha(_ id: UUID) throws -> LWFloatPlane {
            guard visiting.count < 256, visiting.insert(id).inserted, let record = records[id] else { throw ProjectError.invalid }
            defer { visiting.remove(id) }
            var surface = try own(record)
            if let source = record.maskSourceID { surface = try applyAlpha(surface, coverage: alpha(source)) }
            return surface
        }
        func folderCoverage(_ record: ProjectLayerRecord) throws -> LWFloatPlane? {
            var id = record.parentID, result: LWFloatPlane?, depth = 0
            while let parent = id {
                guard depth < 256, let folder = records[parent] else { throw ProjectError.invalid }; depth += 1
                if let coverage = try checkedMask(folder) {
                    if let prior = result { result = try applyAlpha(prior, coverage: coverage) }
                    else { result = coverage }
                }
                id = folder.parentID
            }
            return result
        }
        func adjusted(_ old: LWFloatPlane, layer: ProjectLayerRecord, clipping: LWFloatPlane?, keepAlpha: Bool) throws -> LWFloatPlane {
            guard let adjustment = layer.adjustment else { throw ProjectError.invalid }
            var made = try adjustment.apply(old, region: CGRect(x: documentOrigin.x, y: documentOrigin.y, width: CGFloat(width), height: CGFloat(height)), scale: 1,
                makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) }, makeScratchDirectory: { try workspace.makeScratchDirectory() }, fileOwner: workspace)
            if (layer.blendMode ?? .normal) != .normal { made = try blend(made, over: old, mode: layer.blendMode ?? .normal, workspace: workspace) }
            let newPixels = made.sampler(), clip = clipping?.sampler()
            let mask = try checkedMask(layer)?.sampler(), folder = try folderCoverage(layer)?.sampler()
            let opacity = Float(layer.effectiveOpacity(in: records))
            return try map(old, workspace: workspace) { before, x, y in
                let amount = try opacity * (clip?.pixel(x: x, y: y).w ?? 1) * (mask?.pixel(x: x, y: y).w ?? 1) * (folder?.pixel(x: x, y: y).w ?? 1)
                var result = before + (try newPixels.pixel(x: x, y: y) - before) * amount
                if keepAlpha { result.w = before.w }; return result
            }
        }
        let visible = LayerHierarchy.visibleLayers(snapshot.manifest.layers)
        var output = try clearPlane(width: width, height: height, workspace: workspace), index = 0
        while index < visible.count {
            try Task.checkCancellation()
            let layer = visible[index]
            if layer.adjustment != nil {
                output = try adjusted(output, layer: layer, clipping: layer.maskSourceID.map(alpha), keepAlpha: true)
                index += 1; continue
            }
            var foreground = try own(layer)
            if let source = layer.maskSourceID { foreground = try applyAlpha(foreground, coverage: alpha(source)) }
            foreground = try applyAlpha(foreground, coverage: folderCoverage(layer), opacity: Float(layer.effectiveOpacity(in: records)))
            let baseAlpha = foreground, base = baseAlpha.sampler()
            var next = index + 1
            while next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                let child = visible[next]
                if child.adjustment != nil { foreground = try adjusted(foreground, layer: child, clipping: nil, keepAlpha: false) }
                else {
                    let childPixels = try applyAlpha(own(child), coverage: nil, opacity: Float(child.effectiveOpacity(in: records)))
                    foreground = try blend(childPixels, over: foreground, mode: child.blendMode ?? .normal, workspace: workspace)
                }
                foreground = try map(foreground, workspace: workspace) { pixel, x, y in
                    var result = pixel; result.w = try base.pixel(x: x, y: y).w; return result
                }
                next += 1
            }
            output = try blend(foreground, over: output, mode: layer.blendMode ?? .normal, workspace: workspace)
            index = next
        }
        try Task.checkCancellation(); return output
    }
}
