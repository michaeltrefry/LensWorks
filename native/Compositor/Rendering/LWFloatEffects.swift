import Foundation
import CoreGraphics
import CoreImage

nonisolated enum LWFloatEffects {
    /// Global local-layer effects. Margins, morphology and filter dependencies are
    /// evaluated in one padded coordinate system, never independently per tile.
    static func local(_ source: LWFloatPlane, effects: LayerEffects,
        workspace: LWFloatWorkspace) throws -> (surface: LWFloatPlane, inset: CGFloat) {
        guard effects.isValid, source.workingSet === workspace.workingSet else { throw ProjectError.invalid }
        let visible = effects.visible, inset = LayerEffectsRenderer.margin(for: visible)
        let margin = Int(inset), width = source.width + margin * 2, height = source.height + margin * 2
        try LWFloatPlane.validateExtent(width: width, height: height)
        let sourcePixels = source.sampler()
        let empty = try LWFloatCompositor.clearPlane(width: width, height: height, workspace: workspace)
        let padded = try LWFloatCompositor.map(empty, workspace: workspace) { _, x, y in
            try sourcePixels.pixel(x: x - margin, y: y - margin)
        }
        let shape = try LWFloatCompositor.map(padded, workspace: workspace) { p, _, _ in SIMD4(p.w, p.w, p.w, 1) }
        let shapePixels = padded.sampler()
        var result = empty
        func fill(_ color: PaletteColor, opacity: Double, coverage: LWFloatPlane) throws {
            func linear(_ x: CGFloat) -> Float { let v = Double(x); return Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
            let rgb = SIMD3(linear(color.red), linear(color.green), linear(color.blue))
            let layer = try LWFloatCompositor.map(coverage, workspace: workspace) { p, _, _ in
                SIMD4(rgb.x, rgb.y, rgb.z, max(0, min(1, p.x)) * Float(opacity))
            }
            result = try LWFloatCompositor.blend(layer, over: result, mode: .normal, workspace: workspace)
        }
        func coverage(offset: CGSize = .zero, blur: CGFloat = 0) throws -> LWFloatPlane {
            try filteredCoverage(shape, offset: offset, blur: blur, workspace: workspace)
        }
        func ring(_ stroke: StrokeEffect) throws -> LWFloatPlane {
            let changed = try extreme(shape, reach: max(1, Int(stroke.size.rounded())), smallest: stroke.inside, workspace: workspace)
            return try LWFloatCompositor.map(changed, workspace: workspace) { p, x, y in
                let old = try shapePixels.pixel(x: x, y: y).w
                let value = stroke.inside ? max(0, old - p.x) : max(0, p.x - old)
                return SIMD4(value, value, value, 1)
            }
        }
        if let shadow = visible.shadow, shadow.opacity > 0 { try fill(shadow.color, opacity: shadow.opacity, coverage: coverage(offset: shadow.offset, blur: shadow.blur)) }
        if let glow = visible.outerGlow, glow.opacity > 0 {
            let soft = try coverage(blur: glow.size)
            let mask = try LWFloatCompositor.map(soft, workspace: workspace) { p, x, y in
                let value = p.x * (1 - (try shapePixels.pixel(x: x, y: y).w)); return SIMD4(value, value, value, 1)
            }
            try fill(glow.color, opacity: glow.opacity, coverage: mask)
        }
        if let stroke = visible.stroke, !stroke.inside, stroke.size > 0, stroke.opacity > 0 { try fill(stroke.color, opacity: stroke.opacity, coverage: ring(stroke)) }
        result = try LWFloatCompositor.blend(padded, over: result, mode: .normal, workspace: workspace)
        if let overlay = visible.colorOverlay, overlay.opacity > 0 { try fill(overlay.color, opacity: overlay.opacity, coverage: shape) }
        if let glow = visible.innerGlow, glow.opacity > 0 {
            let soft = try coverage(blur: glow.size)
            let mask = try LWFloatCompositor.map(soft, workspace: workspace) { p, x, y in
                let value = (try shapePixels.pixel(x: x, y: y).w) * (1 - p.x); return SIMD4(value, value, value, 1)
            }
            try fill(glow.color, opacity: glow.opacity, coverage: mask)
        }
        if let shadow = visible.innerShadow, shadow.opacity > 0 {
            let shifted = try coverage(offset: shadow.offset, blur: shadow.blur)
            let mask = try LWFloatCompositor.map(shifted, workspace: workspace) { p, x, y in
                let value = (try shapePixels.pixel(x: x, y: y).w) * (1 - p.x); return SIMD4(value, value, value, 1)
            }
            try fill(shadow.color, opacity: shadow.opacity, coverage: mask)
        }
        if let stroke = visible.stroke, stroke.inside, stroke.size > 0, stroke.opacity > 0 { try fill(stroke.color, opacity: stroke.opacity, coverage: ring(stroke)) }
        return (result, inset)
    }

    private static func filteredCoverage(_ source: LWFloatPlane, offset: CGSize, blur: CGFloat,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard offset.width.isFinite, offset.height.isFinite, blur.isFinite, blur >= 0,
            let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw ProjectError.invalid }
        let fixed = try workspace.workingSet.reserve(16)
        let topology = CIImage(bitmapData: Data(count: 16), bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: color)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(source.width), y: CGFloat(source.height)))
        func filter(_ input: CIImage) -> CIImage {
            var result = input.transformed(by: CGAffineTransform(translationX: offset.width, y: -offset.height))
            if blur > 0 { result = result.clampedToExtent().applyingGaussianBlur(sigma: blur / 2) }
            return result
        }
        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let topologyResult = filter(topology), builder = try workspace.makeBuilder(width: source.width, height: source.height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let output = CGRect(x: range.x, y: source.height - range.y - range.height, width: range.width, height: range.height)
                let dependency = topologyResult.regionOfInterest(for: topology, in: output)
                guard !dependency.isInfinite,dependency.isNull || [dependency.minX,dependency.minY,dependency.maxX,dependency.maxY].allSatisfy(\.isFinite) else { throw ProjectError.invalid }
                let clipped = dependency.isNull ? CGRect.null : dependency.integral.intersection(full), outputBytes = try range.validate(frameWidth: source.width, frameHeight: source.height)
                let result: LWLinearSurface
                if clipped.isNull || clipped.isEmpty {
                    let lease = try workspace.workingSet.reserve(outputBytes)
                    result = try LWLinearSurface(width: range.width, height: range.height, pixels: [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: outputBytes / 16), maximumBytes: outputBytes)
                    try builder.append(result, at: range); withExtendedLifetime(lease) {}; return
                }
                let inputRange = try LWFloatKernelWorkspace.coreImageRange(dependency, extent: full)
                let inputBytes = try inputRange.validate(frameWidth: source.width, frameHeight: source.height)
                let (inputCharge, iOverflow) = inputBytes.multipliedReportingOverflow(by: 4)
                let (outputCharge, oOverflow) = outputBytes.multipliedReportingOverflow(by: 3)
                let (charge, overflow) = inputCharge.addingReportingOverflow(outputCharge)
                guard !iOverflow, !oOverflow, !overflow else { throw ProjectError.tooLarge }
                let lease = try workspace.workingSet.reserve(charge)
                let tile = try source.read(range: inputRange)
                let input = CIImage(cgImage: try tile.surface.cgImage(), options: [.colorSpace: color])
                    .transformed(by: CGAffineTransform(translationX: CGFloat(inputRange.x), y: CGFloat(source.height - inputRange.y - inputRange.height)))
                result = try LWLinearSurface.render(filter(input).cropped(to: output)
                    .transformed(by: CGAffineTransform(translationX: -output.minX, y: -output.minY)), width: range.width, height: range.height, maximumBytes: outputBytes)
                // Match the retained scalar extraction and its [0,1] coverage bound.
                var scalar = result
                for i in scalar.pixels.indices { let value = max(0, min(1, scalar.pixels[i].x)); scalar.pixels[i] = SIMD4(value, value, value, 1) }
                try builder.append(scalar, at: range); withExtendedLifetime(lease) {}
            }
        }
        withExtendedLifetime(fixed) {}; return try builder.finish()
    }

    /// Same square extrema and zero-outside erosion as the retained two-deque
    /// algorithm. Only one line, its queue, and bounded typed-store tiles are resident.
    private static func extreme(_ source: LWFloatPlane, reach: Int, smallest: Bool,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let radius = max(0, reach), width = source.width, height = source.height
        let lineCharge = max(width, height) * (MemoryLayout<Float>.stride * 2 + MemoryLayout<Int>.stride)
        let lease = try workspace.workingSet.reserve(lineCharge)
        func sweep(_ values: [Float]) -> [Float] {
            var output = [Float](repeating: 0, count: values.count), queue = [Int](repeating: 0, count: values.count)
            var head = 0, tail = 0, next = 0
            for center in values.indices {
                while next <= min(values.count - 1, center + radius) {
                    let value = values[next]
                    while tail > head {
                        let previous = values[queue[tail - 1]]
                        if smallest ? previous < value : previous > value { break }; tail -= 1
                    }
                    queue[tail] = next; tail += 1; next += 1
                }
                while head < tail, queue[head] < center - radius { head += 1 }
                output[center] = smallest && (center < radius || center + radius >= values.count) ? 0 : values[queue[head]]
            }
            return output
        }
        let horizontal = try workspace.makeStateStore(format: .float64, width: width, height: height)
        for y in 0..<height {
            try Task.checkCancellation()
            let row = try source.read(range: LWFloatRange(x: 0, y: y, width: width, height: 1))
            let values = sweep(row.surface.pixels.map(\.x))
            for x in 0..<width { try horizontal.write(.float64(Double(values[x])), x: x, y: y) }
        }
        let first = try horizontal.commit(), reader = first.reader()
        let vertical = try workspace.makeStateStore(format: .float64, width: width, height: height)
        for x in 0..<width {
            try Task.checkCancellation()
            var column = [Float](repeating: 0, count: height)
            for y in 0..<height { guard case .float64(let value) = try reader.read(x: x, y: y) else { throw ProjectError.invalid }; column[y] = Float(value) }
            let values = sweep(column)
            for y in 0..<height { try vertical.write(.float64(Double(values[y])), x: x, y: y) }
        }
        let complete = try vertical.commit(), values = complete.reader()
        let result = try LWFloatCompositor.map(source, workspace: workspace) { _, x, y in
            guard case .float64(let scalar) = try values.read(x: x, y: y) else { throw ProjectError.invalid }
            let f = Float(scalar); return SIMD4(f, f, f, 1)
        }
        withExtendedLifetime(lease) {}; return result
    }
}
