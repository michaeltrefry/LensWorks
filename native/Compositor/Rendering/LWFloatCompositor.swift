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
    /// A pixel copy is drawn by Core Graphics from the crop of the image under each tile. Any other transform
    /// (rotation, scaling, flips, fractional origins) is resampled by `resampled`, whose samples depend only on
    /// document coordinates: Core Graphics' resampling depends on the extent of the image it draws, so neither
    /// cropping nor tiling could otherwise reproduce a whole-frame evaluation. Either way a tile reads only
    /// the part of the layer that reaches it, charged to the working set.
    static func place(_ image: CGImage, transform: LayerTransform, width: Int, height: Int,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let builder = try workspace.makeBuilder(width: width, height: height)
        let copy = placesAsPixelCopy(image, transform: transform)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: width, frameHeight: height)
                let lease = try workspace.workingSet.reserve(bytes * 8)
                if !copy {
                    try builder.append(resampled(image, transform: transform, range: range, workingSet: workspace.workingSet), at: range)
                    withExtendedLifetime(lease) {}
                    return
                }
                let context = try LWLinearSurface.context(width: range.width, height: range.height, maximumBytes: bytes)
                context.translateBy(x: -CGFloat(range.x), y: CGFloat(range.y + range.height))
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: transform.center.x, y: transform.center.y)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = transform.sampling.quality
                if let crop = sourceCrop(of: image, transform: transform, range: range, margin: 1) {
                    // The decoded source the draw reads: the crop's samples at the image's own depth.
                    let decoded = try workspace.workingSet.reserve(Int(crop.width * crop.height) * max(1, image.bitsPerPixel / 8))
                    let part = crop.size == CGSize(width: image.width, height: image.height) ? image : image.cropping(to: crop) ?? image
                    let w = transform.size.width, h = transform.size.height
                    // Local space runs up from the layer's centre: the image's top row is at the rectangle's maxY.
                    let rect = part === image ? CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                        : CGRect(x: -w / 2 + crop.minX, y: h / 2 - crop.maxY, width: crop.width, height: crop.height)
                    context.draw(part, in: rect)
                    withExtendedLifetime(decoded) {}
                }
                guard let made = context.makeImage() else { throw ExportError.render }
                try builder.append(LWLinearSurface.read(made, maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
        }
        return try builder.finish()
    }

    /// Document pixels (y down) → continuous image pixel coordinates (origin at the image's top-left corner,
    /// sample centres at +0.5): the inverse of placement.
    static func documentToImage(_ image: CGImage, transform: LayerTransform) -> CGAffineTransform {
        let w = transform.size.width, h = transform.size.height
        let place = CGAffineTransform(translationX: transform.center.x, y: transform.center.y)
            .rotated(by: transform.radians).scaledBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        let sx = CGFloat(image.width) / w, sy = CGFloat(image.height) / h
        return place.inverted().concatenating(CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: w * sx / 2, ty: h * sy / 2))
    }

    /// The rectangle of image pixels whose samples can reach `range` under `transform`: the range inverse-mapped
    /// into the image, widened by `margin` pixels and clipped to it. Nil when the layer does not reach the range.
    static func sourceCrop(of image: CGImage, transform: LayerTransform, range: LWFloatRange, margin: CGFloat) -> CGRect? {
        guard transform.size.width > 0, transform.size.height > 0, image.width > 0, image.height > 0 else { return nil }
        let toImage = documentToImage(image, transform: transform)
        let corners = [CGPoint(x: range.x, y: range.y), CGPoint(x: range.x + range.width, y: range.y),
                       CGPoint(x: range.x, y: range.y + range.height), CGPoint(x: range.x + range.width, y: range.y + range.height)]
            .map { $0.applying(toImage) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let reach = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -margin, dy: -margin)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard [reach.minX, reach.minY, reach.maxX, reach.maxY].allSatisfy(\.isFinite) else { return bounds }
        let crop = reach.integral.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        return crop
    }

    /// The part of `image` one tile's resampling reads (see `sourceCrop`).
    static func visiblePart(of image: CGImage, transform: LayerTransform, range: LWFloatRange) -> CGImage? {
        guard let crop = sourceCrop(of: image, transform: transform, range: range, margin: 2) else { return nil }
        return crop.size == CGSize(width: image.width, height: image.height) ? image : image.cropping(to: crop)
    }

    /// `range` of the layer `image` placed by `transform`, resampled from premultiplied float samples. Each output
    /// pixel is computed from its document coordinates alone (Nearest: the sample under its centre; Smooth: bilinear
    /// at its centre; High quality: the mean of n×n bilinear taps spread over its footprint in the image, n the
    /// reduction factor rounded up, so reductions are filtered rather than aliased). Samples outside the image are
    /// transparent. Only the crop under the range is decoded, so any tiling gives the same samples as a whole frame.
    @_optimize(speed) static func resampled(_ image: CGImage, transform: LayerTransform, range: LWFloatRange, workingSet: LWFloatWorkingSet) throws -> LWLinearSurface {
        let bytes = try range.validate(frameWidth: range.x + range.width, frameHeight: range.y + range.height)
        var output = [SIMD4<Float>](repeating: .zero, count: range.width * range.height)
        guard let crop = sourceCrop(of: image, transform: transform, range: range, margin: 2) else {
            return try LWLinearSurface(width: range.width, height: range.height, pixels: output, maximumBytes: bytes)
        }
        let cw = Int(crop.width), ch = Int(crop.height), cx = Int(crop.minX), cy = Int(crop.minY)
        // The crop decoded at its own depth, and its premultiplied float samples.
        let decoded = try workingSet.reserve(cw * ch * (16 + max(1, image.bitsPerPixel / 8)))
        let part = crop.size == CGSize(width: image.width, height: image.height) ? image : image.cropping(to: crop) ?? image
        let context = try LWLinearSurface.context(width: cw, height: ch, maximumBytes: cw * ch * 16)
        context.interpolationQuality = .none
        context.draw(part, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        guard let data = context.data else { throw ExportError.render }
        let samples = UnsafeBufferPointer(start: data.bindMemory(to: SIMD4<Float>.self, capacity: cw * ch), count: cw * ch)
        let m = documentToImage(image, transform: transform)
        let a = Double(m.a), b = Double(m.b), c = Double(m.c), d = Double(m.d), tx = Double(m.tx), ty = Double(m.ty)
        let iw = image.width, ih = image.height
        @inline(__always) func at(_ i: Int, _ j: Int) -> SIMD4<Float> {
            guard i >= 0, j >= 0, i < iw, j < ih else { return .zero }
            let li = i - cx, lj = j - cy
            guard li >= 0, lj >= 0, li < cw, lj < ch else { return .zero } // Never reached: the crop covers every tap.
            return samples[lj * cw + li]
        }
        @inline(__always) func bilinear(_ u: Double, _ v: Double) -> SIMD4<Float> {
            let fu = u - 0.5, fv = v - 0.5, i = Int(fu.rounded(.down)), j = Int(fv.rounded(.down))
            let wx = Float(fu - Double(i)), wy = Float(fv - Double(j))
            let top = at(i, j) * (1 - wx) + at(i + 1, j) * wx, bottom = at(i, j + 1) * (1 - wx) + at(i + 1, j + 1) * wx
            return top * (1 - wy) + bottom * wy
        }
        let n: Int
        switch transform.sampling {
        case .high: n = max(1, min(16, Int((max((a * a + b * b).squareRoot(), (c * c + d * d).squareRoot()) - 1e-9).rounded(.up))))
        default: n = 1
        }
        try Task.checkCancellation()
        for y in 0..<range.height {
            for x in 0..<range.width {
                var sum = SIMD4<Float>.zero
                for sj in 0..<n { for si in 0..<n {
                    // Absolute document coordinates: the same position whatever range or crop is evaluated.
                    let px = Double(range.x + x) + (Double(si) + 0.5) / Double(n), py = Double(range.y + y) + (Double(sj) + 0.5) / Double(n)
                    let u = a * px + c * py + tx, v = b * px + d * py + ty
                    if transform.sampling == .nearest {
                        sum += at(Int(u.rounded(.down)), Int(v.rounded(.down)))
                    } else {
                        sum += bilinear(u, v)
                    }
                } }
                let p = n == 1 ? sum : sum / Float(n * n), alpha = min(1, max(0, p.w))
                output[y * range.width + x] = alpha > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, alpha) : .zero
            }
        }
        withExtendedLifetime(decoded) {}
        withExtendedLifetime(context) {}
        return try LWLinearSurface(width: range.width, height: range.height, pixels: output, maximumBytes: bytes)
    }

    /// Native size on whole-pixel coordinates without rotation or flip: placement copies samples.
    static func placesAsPixelCopy(_ image: CGImage, transform: LayerTransform) -> Bool {
        transform.radians == 0 && !transform.flipX && !transform.flipY
            && transform.size.width == CGFloat(image.width) && transform.size.height == CGFloat(image.height)
            && transform.origin.x == transform.origin.x.rounded() && transform.origin.y == transform.origin.y.rounded()
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
        let documentHeight = snapshot.manifest.height
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
            snapshot = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks, coverages: snapshot.coverages, workingVersion: snapshot.workingVersion)
            documentOrigin = CGPoint(x: dx, y: dy)
        }
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
        var visiting = Set<UUID>()
        func checkedMask(_ layer: ProjectLayerRecord, local: LWFloatPlane? = nil) throws -> LWFloatPlane? {
            guard var mask = snapshot.mask(for: layer), mask.isEnabled else { return nil }
            // A folder's or an adjustment's mask without a placement of its own sits where the layer's own frame puts it
            // (the whole document, until the canvas is flipped or the folder transformed), as in the retained compositor.
            if local == nil, mask.placement == nil { mask.placement = layer.transform }
            let w = local?.width ?? width, h = local?.height ?? height
            let target = local != nil ? layer.transform : LayerTransform(origin:.zero,size:CGSize(width:w,height:h))
            return try LWSourceMaskReconcile.coveragePlane(mask,over:target,width:w,height:h,workspace:workspace)
        }
        /// The coverage baked into a layer, stretched over the layer's own grid. A record that names one the
        /// snapshot does not carry is refused: a path that dropped it must not quietly show the layer without it.
        func bakedCoverage(_ layer: ProjectLayerRecord, local: LWFloatPlane) throws -> LWFloatPlane? {
            guard layer.coverageFile != nil else { return nil }
            guard let asset = snapshot.coverages[layer.id] else { throw ProjectError.missingImage }
            if let plane = asset.linearPlane, plane.width == local.width, plane.height == local.height { return plane }
            return try LWSourceMaskReconcile.coveragePlane(LayerMask(asset: asset), over: layer.transform, width: local.width, height: local.height, workspace: workspace)
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
            // Placement converts the samples it reads to premultiplied extended-linear float before any resampling,
            // exactly as converting the image to a plane first would, so the result is the same.
            if asset.linearPlane == nil, snapshot.mask(for: record)?.isEnabled != true, record.coverageFile == nil, record.effects?.visible.isEmpty ?? true {
                return try place(asset.image, transform: record.transform, width: width, height: height, workspace: workspace)
            }
            var local = try asset.linearPlane ?? from(asset.image, workspace: workspace)
            local = try applyAlpha(local, coverage: checkedMask(record, local: local))
            // Coverage baked into the layer multiplies its alpha too, whatever its own mask does.
            local = try applyAlpha(local, coverage: bakedCoverage(record, local: local))
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
        /// The coverage a layer lends to the layers that take its alpha: its own alpha through its own mask, at the
        /// opacity it is drawn at (its folders' included), times whatever coverage it takes in turn. Its visibility,
        /// colour and blend mode do not enter, and neither do its folders' masks.
        func alpha(_ id: UUID) throws -> LWFloatPlane {
            guard visiting.count < 256, visiting.insert(id).inserted, let record = records[id] else { throw ProjectError.invalid }
            defer { visiting.remove(id) }
            var surface = try applyAlpha(own(record), coverage: nil, opacity: Float(record.effectiveOpacity(in: records)))
            if let source = record.maskSourceID { surface = try applyAlpha(surface, coverage: alpha(source)) }
            return surface
        }
        func settingAlpha(_ surface: LWFloatPlane, to coverage: LWFloatPlane?) throws -> LWFloatPlane {
            let sampler = coverage?.sampler()
            return try map(surface, workspace: workspace) { pixel, x, y in
                var result = pixel; result.w = try sampler?.pixel(x: x, y: y).w ?? 1; return result
            }
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
        /// An adjustment changes colour only: what is below keeps its alpha. `inStack`: the adjustment is clipped inside
        /// a clipping stack, whose base already carries the folders' masks.
        func adjusted(_ old: LWFloatPlane, layer: ProjectLayerRecord, inStack: Bool = false) throws -> LWFloatPlane {
            guard let adjustment = layer.adjustment else { throw ProjectError.invalid }
            var made = try adjustment.apply(old, region: CGRect(x: documentOrigin.x, y: documentOrigin.y, width: CGFloat(width), height: CGFloat(height)), scale: 1,
                makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) }, makeScratchDirectory: { try workspace.makeScratchDirectory() }, fileOwner: workspace,
                documentHeight: documentHeight)
            if (layer.blendMode ?? .normal) != .normal { made = try blend(made, over: old, mode: layer.blendMode ?? .normal, workspace: workspace) }
            let newPixels = made.sampler()
            let mask = try checkedMask(layer)?.sampler(), folder = inStack ? nil : try folderCoverage(layer)?.sampler()
            let opacity = Float(layer.effectiveOpacity(in: records))
            typealias K = FloatImageAdjustmentPixels
            return try map(old, workspace: workspace) { before, x, y in
                let amount = try opacity * (mask?.pixel(x: x, y: y).w ?? 1) * (folder?.pixel(x: x, y: y).w ?? 1)
                guard amount > 0 else { return before }
                var result = try newPixels.pixel(x: x, y: y)
                if amount < 1 {
                    // The adjusted colour lies over the original as a Normal layer at `amount`: mixed in encoded sRGB,
                    // the rule every layer blends by (LWFloatBlend) and what the retained compositor does.
                    for c in 0..<3 {
                        let below = K.encode(Double(before[c])), above = K.encode(Double(result[c]))
                        result[c] = Float(K.decode(below + (above - below) * Double(amount)))
                    }
                }
                result.w = before.w; return result
            }
        }
        let visible = LayerHierarchy.visibleLayers(snapshot.manifest.layers)
        var output = try clearPlane(width: width, height: height, workspace: workspace), index = 0
        while index < visible.count {
            try Task.checkCancellation()
            let layer = visible[index]
            if layer.adjustment != nil {
                // An adjustment clipped to a layer acts only inside that layer's clipping stack. Outside one (its base
                // hidden, or linked to a layer that is not directly below it) it does nothing, as in the retained compositor.
                if layer.maskSourceID == nil { output = try adjusted(output, layer: layer) }
                index += 1; continue
            }
            var foreground = try own(layer)
            if let source = layer.maskSourceID { foreground = try applyAlpha(foreground, coverage: alpha(source)) }
            foreground = try applyAlpha(foreground, coverage: folderCoverage(layer), opacity: Float(layer.effectiveOpacity(in: records)))
            var next = index + 1
            // A clipping stack: the layers directly above a base (itself unclipped) in the same folder that take
            // its alpha. They are composited onto the base's colour as if it were opaque, each in its own blend
            // mode, and the result takes the base's alpha back: a soft edge of the base is neither thickened by
            // painting its coverage over itself nor tinted by the clipped layers' unblended colour. The stack
            // then blends with what is below in the base's mode.
            if layer.maskSourceID == nil, next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                let baseAlpha = foreground
                foreground = try settingAlpha(foreground, to: nil)
                while next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                    let child = visible[next]
                    if child.adjustment != nil { foreground = try adjusted(foreground, layer: child, inStack: true) }
                    else {
                        let childPixels = try applyAlpha(own(child), coverage: nil, opacity: Float(child.effectiveOpacity(in: records)))
                        foreground = try blend(childPixels, over: foreground, mode: child.blendMode ?? .normal, workspace: workspace)
                    }
                    next += 1
                }
                foreground = try settingAlpha(foreground, to: baseAlpha)
            }
            output = try blend(foreground, over: output, mode: layer.blendMode ?? .normal, workspace: workspace)
            index = next
        }
        try Task.checkCancellation(); return output
    }
}
