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
    static func blend(_ top:LWLinearSurface, over bottom:LWLinearSurface,mode:LayerBlendMode) throws -> LWLinearSurface {
        guard top.width == bottom.width, top.height == bottom.height else { throw ProjectError.invalid }
        let name: String = switch mode {
        case .normal: "CISourceOverCompositing"
        case .darken: "CIDarkenBlendMode"
        case .multiply: "CIMultiplyBlendMode"
        case .lighten: "CILightenBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        default: mode.coreImageFilter!
        }
        guard let filter = CIFilter(name:name), let encoded = CGColorSpace(name:CGColorSpace.extendedSRGB),
            let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB) else { throw ExportError.render }
        filter.setValue(CIImage(cgImage:try top.cgImage()),forKey:kCIInputImageKey)
        filter.setValue(CIImage(cgImage:try bottom.cgImage()),forKey:kCIInputBackgroundImageKey)
        guard let output = filter.outputImage else { throw ExportError.render }
        // Retain the editor's encoded-sRGB blend definition with extended floating
        // components. The transport and resulting document samples are linear float.
        let context = CIContext(options:[.workingColorSpace:encoded,.outputColorSpace:linear,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
        var result = try clear(top.width,top.height)
        result.pixels.withUnsafeMutableBytes { bytes in
            context.render(output,toBitmap:bytes.baseAddress!,rowBytes:top.width*16,
                bounds:CGRect(x:0,y:0,width:top.width,height:top.height),format:.RGBAf,colorSpace:linear)
        }
        for i in result.pixels.indices {
            let alpha = result.pixels[i].w
            if alpha > 0 { result.pixels[i].x /= alpha; result.pixels[i].y /= alpha; result.pixels[i].z /= alpha }
            else { result.pixels[i] = .zero }
        }
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
                let made = try blend(foreground.surface, over: background.surface, mode: mode)
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
                context.draw(image, in: CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2,
                    width: transform.size.width, height: transform.size.height))
                guard let made = context.makeImage() else { throw ExportError.render }
                try builder.append(LWLinearSurface.read(made, maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
        }
        return try builder.finish()
    }

    /// Full document graph, with immutable range-backed intermediates. Preview and
    /// export share this path; output size changes are downstream of development.
    static func renderPlane(_ snapshot: ProjectSnapshot, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try LayerHierarchy.validate(snapshot.manifest.layers); try LiveMaskGraph.validate(snapshot.manifest.layers)
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        try LWFloatPlane.validateExtent(width: width, height: height)
        let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
        var visiting = Set<UUID>()
        func checkedMask(_ layer: ProjectLayerRecord, local: LWFloatPlane? = nil) throws -> LWFloatPlane? {
            guard let mask = snapshot.mask(for: layer), mask.isEnabled else { return nil }
            let w = local?.width ?? width, h = local?.height ?? height
            let target = local != nil ? layer.transform : LayerTransform(origin:.zero,size:CGSize(width:w,height:h))
            return try LWSourceMaskReconcile.coveragePlane(mask,over:target,width:w,height:h,workspace:workspace)
        }
        func applyAlpha(_ surface: LWFloatPlane, coverage: LWFloatPlane?, opacity: Float = 1) throws -> LWFloatPlane {
            guard coverage.map({ $0.width == surface.width && $0.height == surface.height }) ?? true,
                opacity.isFinite, (0...1).contains(opacity) else { throw ProjectError.invalid }
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
            var made = try adjustment.apply(old, region: CGRect(x: 0, y: 0, width: width, height: height), scale: 1,
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
