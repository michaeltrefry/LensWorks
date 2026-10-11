import Foundation
import CoreGraphics
import CoreImage

/// Captured-document-frame, floating-point retouch evaluation. Each current destination sample
/// maps through the current source frame and then the immutable captured document frame. A
/// nonuniform geometry or optics change is never approximated by an ellipse, a scalar map, or an
/// identity transform.
nonisolated enum LWSourceRetouch {
    typealias Pixel = SIMD4<Float>

    private enum Role: UInt8 { case outside, ring, hole }

    static func evaluate(_ node: LWLiveSourceNode,
                         developed: LWSourceOwnedLinearSurface,
                         map: LWSourceSpatialMap,
                         workspace: LWFloatWorkspace) throws -> LWSourceOwnedLinearSurface {
        // Compatibility callers retain a linear-surface signature, but must carry the exact
        // caller-admitted owner and maximumBytes. A fresh working set would bypass source-graph
        // aggregate ownership and an unowned return would outlive its allocation charge.
        try node.validate()
        guard developed.workingSet === workspace.workingSet else { throw ProjectError.invalid }
        try developed.validate(maximumBytes: developed.maximumBytes)
        // A cancelled caller must not create the bridge's temporary registered plane before the
        // operation is admitted. The tiled evaluator checks again at every bounded traversal.
        try checkpoint(workspace)
        let input = try compatibilityPlane(developed, workspace: workspace)
        let output = try evaluate(node, developed: input, map: map, workspace: workspace)
        try checkpoint(workspace)
        return try compatibilitySurface(output, maximumBytes: developed.maximumBytes,
                                        workspace: workspace)
    }

    private static func compatibilityPlane(_ surface: LWSourceOwnedLinearSurface,
                                           workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        // The owned surface copies rows through its own charged, immutable collection. No
        // Array can escape this bridge or outlive the corresponding source lease.
        try surface.plane(workspace: workspace)
    }

    private static func compatibilitySurface(_ plane: LWFloatPlane, maximumBytes: Int,
                                             workspace: LWFloatWorkspace) throws -> LWSourceOwnedLinearSurface {
        // `admitted` reserves before its per-pixel callback and hides the resulting storage
        // behind an immutable collection whose aliases retain the shared working-set lease.
        let sampler = plane.sampler(edge: .transparent)
        return try LWLinearSurface.admitted(width: plane.width, height: plane.height,
                                            maximumBytes: maximumBytes, workingSet: workspace.workingSet) { index in
            try checkpoint(workspace)
            let x = index % plane.width, y = index / plane.width
            return try sampler.sample(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), edge: .transparent)
        }
    }

    /// Source-control reference evaluator. Product callers use one of the two node-bound
    /// evaluators above, which route through the same tiled Core Image/typed-state machinery.
    /// This isolated retained-algorithm reference remains for discriminating unit controls only.
    static func evaluateReference(strokes: [LWSourceRetouchStroke], sourceID: UUID,
                         developed: LWLinearSurface, map: LWSourceSpatialMap,
                         admission: LWSourceRetouchAdmission,
                         sampleAll: (LWSourceRetouchStroke, LWLinearSurface) throws -> LWLinearSurface) throws -> LWLinearSurface {
        try developed.validate(maximumBytes: developed.maximumBytes)
        for stroke in strokes { try stroke.validate(source: sourceID) }
        _ = try operationScratchBytes(surface: developed, strokes: strokes)
        var working = developed
        for stroke in strokes {
            try Task.checkCancellation()
            let before = working
            let selection = try stroke.selectionMask(admission: admission)
            switch stroke.kind {
            case .clone:
                // Clone samples the immutable immediately-pre-stroke active layer. It must include
                // completed earlier strokes, but never sample its own mutable output.
                let source = stroke.sampleAllLayers ? try sampleAll(stroke, before) : before
                working = try clone(stroke, target: before, source: source, map: map, selection: selection)
            case .heal:
                working = try heal(stroke, target: before, map: map, selection: selection)
            case .paint:
                working = try paint(stroke, target: before, map: map, selection: selection)
            case .erase:
                working = try erase(stroke, target: before, map: map, selection: selection)
            case .smear:
                working = try smudge(stroke, target: before, map: map, selection: selection)
            case .blur:
                working = try blur(stroke, target: before, map: map, selection: selection)
            case .liquify:
                // Companion-owned FloatLiquify must preserve WarpStroke.push's document-frame,
                // prior/next-dab semantics; it is an explicit unsealed joint interface gate.
                working = try liquify(stroke, target: before, map: map, selection: selection, admission: admission)
            }
            try working.validate(maximumBytes: developed.maximumBytes)
        }
        return working
    }

    /// The companion-owned plan validates every encoded dependency and per-dab carry capacity
    /// before decoding or allocating. R5 deliberately has no fixed "eight surfaces" estimate.
    /// Candidate equality with that unsealed API remains null.

    /// Exact bounded pre-decode allocation plan. It charges every operation-local array before
    /// node validation can decode selection/composite backing. Full surfaces and encoded backing
    /// are charged by node.retouchAdmission; this method contributes only evaluator-local storage.
    private static func operationScratchBytes(surface: LWLinearSurface,
                                              strokes: [LWSourceRetouchStroke]) throws -> Int {
        let count = surface.pixels.count
        func add(_ a: Int, _ b: Int) throws -> Int {
            let (v, overflow) = a.addingReportingOverflow(b)
            guard !overflow, v >= 0, v <= surface.maximumBytes else { throw ProjectError.tooLarge }
            return v
        }
        func mul(_ a: Int, _ b: Int) throws -> Int {
            let (v, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow, v >= 0, v <= surface.maximumBytes else { throw ProjectError.tooLarge }
            return v
        }
        var required = 0
        for stroke in strokes {
            // Every mode publishes a complete successor surface before the predecessor retires.
            required = try add(required, try mul(count, MemoryLayout<Pixel>.stride))
            switch stroke.kind {
            case .heal:
                // role + membrane + worst-case index/window/detail storage, all before allocation.
                required = try add(required, try mul(count, MemoryLayout<Role>.stride + MemoryLayout<Pixel>.stride + MemoryLayout<Int>.stride * 3))
            case .smear:
                guard stroke.radius.isFinite, stroke.radius > 0,
                      stroke.radius <= Double(DocumentLimits.maxSide) else { throw ProjectError.invalid }
                let rounded = ceil(stroke.radius)
                guard rounded <= Double(Int.max / 4) else { throw ProjectError.tooLarge }
                let r = Int(rounded)
                let side = try add(try mul(r, 2), 1)
                let entries = try mul(side, side)
                // Frozen and next fixed grids: no unbounded Dictionary allocation.
                required = try add(required, try mul(entries, MemoryLayout<Pixel?>.stride * 2))
            case .liquify:
                // prior/next dab surfaces are separately held full surfaces; this charges dab vectors.
                required = try add(required, try mul(stroke.points.count, MemoryLayout<CGPoint>.stride * 2))
            case .clone, .paint, .erase, .blur:
                break
            }
        }
        return required
    }

    // MARK: Captured document-coordinate coverage

    private static func dabs(for stroke: LWSourceRetouchStroke) throws -> [CGPoint] {
        // Live-source capture retains BrushStroke's final Catmull-Rom dab centers, after its
        // provisional tail is replaced. Re-interpolating raw pointer samples would change a stroke.
        guard stroke.pointsAreDabs, !stroke.points.isEmpty else { throw ProjectError.invalid }
        return stroke.points
    }

    /// The exact retained soft-tip curve in the document frame captured with the stroke.
    /// Overlapping dabs use max coverage so the stroke opacity caps the whole stroke.
    private static func tipCoverage(_ document: CGPoint, stroke: LWSourceRetouchStroke,
                                    dabs: [CGPoint]) -> Float {
        let radius = stroke.radius
        var best = 0.0
        for dab in dabs {
            let u = hypot(Double(document.x - dab.x), Double(document.y - dab.y)) / radius
            guard u < 1 else { continue }
            let value: Double
            if u <= stroke.hardness { value = 1 }
            else {
                let edge = (u - stroke.hardness) / max(.leastNonzeroMagnitude, 1 - stroke.hardness)
                let k = 2.5
                value = max(0, (exp(-k * edge * edge) - exp(-k)) / (1 - exp(-k)))
            }
            best = max(best, value)
        }
        return Float(best)
    }

    private static func coverage(_ stroke: LWSourceRetouchStroke, surface: LWLinearSurface,
                                 map: LWSourceSpatialMap, selection: LWLinearSurface?) throws -> [Float] {
        let dabs = try dabs(for: stroke)
        var values = [Float](repeating: 0, count: surface.pixels.count)
        for y in 0..<surface.height {
            try Task.checkCancellation()
            for x in 0..<surface.width {
                guard let source = try map.sourcePointIfInBounds(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                      let document = try stroke.captureFrame.documentPointIfInBounds(source) else { continue }
                values[y * surface.width + x] = tipCoverage(document, stroke: stroke, dabs: dabs)
                    * selectionAlpha(selection, at: source)
            }
        }
        return values
    }

    /// WarpStroke computes softness from its retained integer cell offset around a rounded dab
    /// center. Sampling uses the corresponding +0.5 raster center, but the weight must never
    /// inherit that half-cell translation.
    private static func smudgeCellWeight(dx: Int, dy: Int, stroke: LWSourceRetouchStroke) -> Float {
        let u = hypot(Double(dx), Double(dy)) / stroke.radius
        guard u < 1 else { return 0 }
        let hardness = min(0.98, max(0, stroke.hardness))
        guard u > hardness else { return 1 }
        let t = (1 - u) / (1 - hardness)
        return Float(t * t * (3 - 2 * t))
    }

    private static func pixel(_ surface: LWLinearSurface, _ x: Int, _ y: Int) -> Pixel {
        surface.pixels[y * surface.width + x]
    }

    private static func linearMix(_ base: Pixel, _ overlay: Pixel, _ amount: Float) -> Pixel {
        base + (overlay - base) * min(1, max(0, amount))
    }

    private static func premultiplied(_ value: Pixel) -> Pixel {
        let alpha = min(1, max(0, value.w))
        return Pixel(value.x * alpha, value.y * alpha, value.z * alpha, alpha)
    }

    private static func straight(_ value: Pixel) -> Pixel {
        let alpha = min(1, max(0, value.w))
        guard alpha > 0 else { return .zero }
        return Pixel(value.x / alpha, value.y / alpha, value.z / alpha, alpha)
    }

    /// BrushRaster.fill uses normal source-over compositing. Keep f32 HDR RGB while converting
    /// only at the premultiplied compositing boundary.
    private static func sourceOver(_ base: Pixel, _ overlay: Pixel, _ amount: Float) -> Pixel {
        let sourceAlpha = min(1, max(0, overlay.w * min(1, max(0, amount))))
        let source = Pixel(overlay.x * sourceAlpha, overlay.y * sourceAlpha, overlay.z * sourceAlpha, sourceAlpha)
        let destination = premultiplied(base)
        return straight(source + destination * (1 - sourceAlpha))
    }

    /// Replacement/transport operations blend in premultiplied f32, then restore straight storage.
    /// This retains HDR RGB and prevents transparent hidden RGB from altering kernel results.
    private static func premultipliedMix(_ base: Pixel, _ overlay: Pixel, _ amount: Float) -> Pixel {
        straight(linearMix(premultiplied(base), premultiplied(overlay), amount))
    }

    /// HealPixels reconstructs a premultiplied membrane and applies coverage before its sole
    /// storage invariant. Converting the reconstructed value to straight pixels first would clamp
    /// alpha early and change partial-coverage overshoot at the ring boundary.
    private static func reconstructedPremultipliedMix(_ base: Pixel, _ reconstructed: Pixel, _ amount: Float) -> Pixel {
        straight(linearMix(premultiplied(base), reconstructed, amount))
    }

    /// Bilinear sampling retains f32 and unbounded linear RGB; only alpha is bounded by the
    /// surface invariant.  A source coordinate outside the transformed surface is absent.
    private static func sample(_ surface: LWLinearSurface, at point: CGPoint) -> Pixel? {
        let x = Double(point.x) - 0.5, y = Double(point.y) - 0.5
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
              x <= Double(surface.width - 1), y <= Double(surface.height - 1) else { return nil }
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let x1 = min(surface.width - 1, x0 + 1), y1 = min(surface.height - 1, y0 + 1)
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        let upper = linearMix(premultiplied(pixel(surface, x0, y0)), premultiplied(pixel(surface, x1, y0)), tx)
        let lower = linearMix(premultiplied(pixel(surface, x0, y1)), premultiplied(pixel(surface, x1, y1)), tx)
        return straight(linearMix(upper, lower, ty))
    }

    /// A normal transformed edge outside the surface is absent. The companion map distinguishes
    /// that from an invalid or folded transform, which remains an error rather than a hidden sample.
    private static func mappedSample(_ surface: LWLinearSurface, source: CGPoint,
                                     map: LWSourceSpatialMap) throws -> Pixel? {
        guard source.x.isFinite, source.y.isFinite,
              source.x >= 0, source.y >= 0,
              source.x <= CGFloat(map.width), source.y <= CGFloat(map.height) else { return nil }
        guard let developed = try map.developedPointIfInBounds(source) else { return nil }
        return sample(surface, at: developed)
    }

    private static func mappedSampleClamped(_ surface: LWLinearSurface, source: CGPoint,
                                             map: LWSourceSpatialMap) throws -> Pixel {
        guard source.x.isFinite, source.y.isFinite else { throw ProjectError.invalid }
        let clamped = CGPoint(x: min(CGFloat(map.width) - 0.5, max(0.5, source.x)),
                              y: min(CGFloat(map.height) - 0.5, max(0.5, source.y)))
        guard let developed = try map.developedPointIfInBounds(clamped) else { return .zero }
        let bounded = CGPoint(x: min(CGFloat(surface.width) - 0.5, max(0.5, developed.x)),
                              y: min(CGFloat(surface.height) - 0.5, max(0.5, developed.y)))
        return sample(surface, at: bounded) ?? .zero
    }

    private static func selectionAlpha(_ selection: LWLinearSurface?, at source: CGPoint) -> Float {
        guard let selection else { return 1 }
        return sample(selection, at: source)?.w ?? 0
    }

    // MARK: Clone, paint, and erase

    private static func clone(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                              source: LWLinearSurface, map: LWSourceSpatialMap,
                              selection: LWLinearSurface?) throws -> LWLinearSurface {
        guard target.width == source.width, target.height == source.height else { throw ProjectError.invalid }
        let c = try coverage(stroke, surface: target, map: map, selection: selection)
        var output = target
        for y in 0..<target.height { try Task.checkCancellation(); for x in 0..<target.width {
            let index = y * target.width + x, amount = c[index] * Float(stroke.opacity)
            guard amount > 0 else { continue }
            guard let destinationSource = try map.sourcePointIfInBounds(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                  let destinationDocument = try stroke.captureFrame.documentPointIfInBounds(destinationSource) else { continue }
            let sourceDocument = CGPoint(x: destinationDocument.x + stroke.sourceOffset.width,
                                         y: destinationDocument.y + stroke.sourceOffset.height)
            guard let sourceFrame = try stroke.captureFrame.sourcePointIfInBounds(sourceDocument),
                  let copied = try mappedSample(source, source: sourceFrame, map: map) else { continue }
            output.pixels[index] = sourceOver(target.pixels[index], copied, amount)
        }}
        return output
    }

    private static func paint(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                              map: LWSourceSpatialMap, selection: LWLinearSurface?) throws -> LWLinearSurface {
        let c = try coverage(stroke, surface: target, map: map, selection: selection)
        var output = target
        let color = Pixel(stroke.color[0], stroke.color[1], stroke.color[2], stroke.color[3])
        for index in output.pixels.indices where c[index] > 0 {
            output.pixels[index] = sourceOver(target.pixels[index], color, c[index] * Float(stroke.opacity))
        }
        return output
    }

    private static func erase(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                              map: LWSourceSpatialMap, selection: LWLinearSurface?) throws -> LWLinearSurface {
        let c = try coverage(stroke, surface: target, map: map, selection: selection)
        var output = target
        for index in output.pixels.indices where c[index] > 0 {
            var value = target.pixels[index]
            value.w *= 1 - c[index] * Float(stroke.opacity)
            output.pixels[index] = value
        }
        return output
    }

    // MARK: Float port of HealPixels.c

    private static func hash(_ value: UInt32) -> UInt32 {
        var x = value; x ^= x >> 16; x &*= 0x7feb352d
        x ^= x >> 15; x &*= 0x846ca68b; x ^= x >> 16; return x
    }
    private static func unit(_ value: UInt32) -> Double { Double(hash(value) >> 8) / 16_777_216 }

    private static func heal(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                             map: LWSourceSpatialMap, selection: LWLinearSurface?) throws -> LWLinearSurface {
        let c = try coverage(stroke, surface: target, map: map, selection: selection)
        let nonzero = c.indices.filter { c[$0] > 0 }
        guard !nonzero.isEmpty else { return target }
        let xs = nonzero.map { $0 % target.width }, ys = nonzero.map { $0 / target.width }
        let bounds = (xs.min()!, ys.min()!, xs.max()! + 1, ys.max()! + 1)
        let size = max(bounds.2 - bounds.0, bounds.3 - bounds.1)
        let ring = min(16, max(2, size / 8))
        let wx0 = max(0, bounds.0 - ring), wy0 = max(0, bounds.1 - ring)
        let wx1 = min(target.width, bounds.2 + ring), wy1 = min(target.height, bounds.3 + ring)
        let width = wx1 - wx0, height = wy1 - wy0
        var role = [Role](repeating: .outside, count: width * height)
        for y in 0..<height { for x in 0..<width where c[(wy0 + y) * target.width + wx0 + x] > 0 {
            role[y * width + x] = .hole
        }}
        for y in 0..<height { for x in 0..<width where role[y * width + x] == .outside {
            let x0 = max(0, x - ring), x1 = min(width, x + ring + 1)
            let y0 = max(0, y - ring), y1 = min(height, y + ring + 1)
            var near = false
            for yy in y0..<y1 where !near { for xx in x0..<x1 where role[yy * width + xx] == .hole { near = true; break } }
            if near { role[y * width + x] = .ring }
        }}
        guard role.contains(.ring) else { return target }

        let offset: SIMD2<Int>? = stroke.healMode == .createTexture ? nil : bestPatch(target, role, wx0, wy0, width, height, mode: stroke.healMode)
        var membrane = [Pixel](repeating: .zero, count: role.count)
        var mean = Pixel.zero, detail = SIMD3<Double>.zero, ringCount = 0
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            guard role[i] == .ring else { continue }
            let original = premultiplied(pixel(target, wx0 + x, wy0 + y))
            let source = offset.map { premultiplied(pixel(target, wx0 + x + $0.x, wy0 + y + $0.y)) }
            let delta = original - (source ?? .zero)
            membrane[i] = delta; mean += delta; ringCount += 1
            if source == nil {
                for channel in 0..<3 {
                    var sum = 0.0, count = 0
                    for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let px = wx0 + x + dx, py = wy0 + y + dy
                        guard px >= 0, py >= 0, px < target.width, py < target.height else { continue }
                        sum += Double(premultiplied(pixel(target, px, py))[channel]); count += 1
                    }
                    if count > 0 { let d = Double(original[channel]) - sum / Double(count); detail[channel] += d * d }
                }
            }
        }}
        mean /= Float(ringCount)
        for i in membrane.indices where role[i] == .hole { membrane[i] = mean }
        solveMembrane(&membrane, role: role, width: width, height: height, depth: 0)
        detail = SIMD3<Double>(repeating: 0.9) * SIMD3<Double>(sqrt(detail.x / Double(ringCount)), sqrt(detail.y / Double(ringCount)), sqrt(detail.z / Double(ringCount)))

        var output = target
        for y in 0..<height { for x in 0..<width {
            let local = y * width + x; guard role[local] == .hole else { continue }
            let index = (wy0 + y) * target.width + wx0 + x, original = target.pixels[index]
            let source = offset.map { premultiplied(pixel(target, wx0 + x + $0.x, wy0 + y + $0.y)) } ?? .zero
            var grain = SIMD3<Double>.zero
            if offset == nil {
                let key = hash(stroke.seed ^ hash(UInt32((wy0 + y) * target.width + wx0 + x)))
                let u1 = unit(key), u2 = unit(key ^ 0x68e31da4)
                let g = sqrt(-2 * log(1 - u1)) * cos(2 * .pi * u2)
                grain = detail * SIMD3<Double>(repeating: g)
            }
            var healed = source + membrane[local]
            healed.x += Float(grain.x); healed.y += Float(grain.y); healed.z += Float(grain.z)
            // Preserve the reconstructed premultiplied alpha through the coverage blend; storage
            // validates/clamps alpha exactly once at the surface boundary, as HealPixels does.
            output.pixels[index] = premultipliedMix(original, straight(healed), c[index] * Float(stroke.opacity))
        }}
        return output
    }

    private static func bestPatch(_ surface: LWLinearSurface, _ role: [Role], _ wx0: Int, _ wy0: Int,
                                  _ width: Int, _ height: Int, mode: LWSourceRetouchStroke.HealMode) -> SIMD2<Int>? {
        let factors: [Double] = [1.05, 1.35, 1.75, 2.25, 2.8]
        let count = mode == .proximityMatch ? 2 : factors.count
        var best = Double.infinity, answer: SIMD2<Int>?
        for f in 0..<count { for angle in 0..<24 {
            let theta = Double(angle) * .pi / 12
            let dx = Int((cos(theta) * factors[f] * Double(width)).rounded())
            let dy = Int((sin(theta) * factors[f] * Double(height)).rounded())
            let raw = patchScore(surface, role, wx0, wy0, width, height, dx, dy)
            let scored = raw * (mode == .proximityMatch ? 1 + 0.6 * Double(f) : 1 + 0.1 * Double(f))
            if scored < best { best = scored; answer = SIMD2(dx, dy) }
        }}
        guard let coarse = answer else { return nil }
        answer = coarse
        var refined = patchScore(surface, role, wx0, wy0, width, height, coarse.x, coarse.y)
        // Match HealPixels.c: each fine trial is measured from the fixed coarse offset,
        // not from a preceding trial that happened to improve the score.
        for dy in -3...3 { for dx in -3...3 {
            let candidate = SIMD2(coarse.x + dx, coarse.y + dy)
            let value = patchScore(surface, role, wx0, wy0, width, height, candidate.x, candidate.y)
            if value < refined { refined = value; answer = candidate }
        }}
        return answer
    }

    private static func patchScore(_ surface: LWLinearSurface, _ role: [Role], _ wx0: Int, _ wy0: Int,
                                   _ width: Int, _ height: Int, _ dx: Int, _ dy: Int) -> Double {
        guard abs(dx) >= width || abs(dy) >= height,
              wx0 + dx >= 0, wy0 + dy >= 0,
              wx0 + width + dx <= surface.width, wy0 + height + dy <= surface.height else { return .infinity }
        var sum = 0.0, samples = 0
        for y in 0..<height { for x in 0..<width where role[y * width + x] == .ring {
            let a = premultiplied(pixel(surface, wx0 + x, wy0 + y)), b = premultiplied(pixel(surface, wx0 + x + dx, wy0 + y + dy))
            for c in 0..<4 { let d = Double(a[c] - b[c]); sum += d * d }; samples += 1
        }}
        return samples == 0 ? .infinity : sum / Double(samples)
    }

    private static func solveMembrane(_ values: inout [Pixel], role: [Role], width: Int, height: Int, depth: Int) {
        var iterations = 300
        if width > 32 && height > 32 && depth < 16 {
            let cw = (width + 1) / 2, ch = (height + 1) / 2
            var coarse = [Pixel](repeating: .zero, count: cw * ch)
            var coarseRole = [Role](repeating: .outside, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw {
                var known = 0, holes = 0, knownSum = Pixel.zero, holeSum = Pixel.zero
                for j in 0..<2 { for i in 0..<2 {
                    let fx = x * 2 + i, fy = y * 2 + j; guard fx < width, fy < height else { continue }
                    switch role[fy * width + fx] { case .ring: known += 1; knownSum += values[fy * width + fx]
                    case .hole: holes += 1; holeSum += values[fy * width + fx]; case .outside: break }
                }}
                let p = y * cw + x
                if known > 0 { coarseRole[p] = .ring; coarse[p] = knownSum / Float(known) }
                else if holes > 0 { coarseRole[p] = .hole; coarse[p] = holeSum / Float(holes) }
            }}
            solveMembrane(&coarse, role: coarseRole, width: cw, height: ch, depth: depth + 1)
            for y in 0..<height { for x in 0..<width where role[y * width + x] == .hole {
                let q = (y / 2) * cw + x / 2; if coarseRole[q] == .hole { values[y * width + x] = coarse[q] }
            }}
            iterations = 40
        }
        let omega: Float = 1.8
        for _ in 0..<iterations { for y in 0..<height { for x in 0..<width where role[y * width + x] == .hole {
            var sum = Pixel.zero, n = 0
            for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let q = ny * width + nx; if role[q] != .outside { sum += values[q]; n += 1 }
            }
            if n > 0 { let p = y * width + x; values[p] += omega * (sum / Float(n) - values[p]) }
        }}}
    }

    // MARK: Smudge and blur

    private static func smudge(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                               map: LWSourceSpatialMap, selection: LWLinearSurface?) throws -> LWLinearSurface {
        // WarpStroke's first event is pickup only. Every later recorded final dab uses a frozen
        // bounded local carry square and commits its next carry after the complete dab.
        let dabs = try stroke.smudgeDabs
        guard let initial = dabs.first else { throw ProjectError.invalid }
        guard stroke.radius.isFinite, stroke.radius > 0,
              stroke.radius <= Double(DocumentLimits.maxSide) else { throw ProjectError.invalid }
        let rounded = ceil(stroke.radius)
        guard rounded <= Double(Int.max / 4) else { throw ProjectError.tooLarge }
        let carryRadius = Int(rounded)
        let carrySide = try checkedAdd(try checkedMultiply(carryRadius, 2), 1)
        var carried = [Pixel?](repeating: nil, count: try checkedMultiply(carrySide, carrySide))
        // Populate the complete pickup square before any output exists.
        for ly in -carryRadius...carryRadius { for lx in -carryRadius...carryRadius {
            let carryIndex = (ly + carryRadius) * carrySide + lx + carryRadius
            let pickupDocument = rasterCellCenter(center: CGPoint(x: initial.x.rounded(), y: initial.y.rounded()), dx: lx, dy: ly)
            guard let pickupSource = try stroke.captureFrame.sourcePointIfInBounds(pickupDocument),
                  let under = try mappedSample(target, source: pickupSource, map: map) else { continue }
            carried[carryIndex] = premultiplied(under)
        }}
        var output = target
        for dab in dabs.dropFirst() {
            try Task.checkCancellation()
            let beforeDab = output
            let frozenCarry = carried
            var nextCarry = frozenCarry
            // Build the next local carry before output replay, matching WarpStroke's `carried`
            // update for every covered brush cell rather than output-grid visitation order.
            for ly in -carryRadius...carryRadius { for lx in -carryRadius...carryRadius {
                let carryIndex = (ly + carryRadius) * carrySide + lx + carryRadius
                let pickupDocument = rasterCellCenter(center: CGPoint(x: dab.x.rounded(), y: dab.y.rounded()), dx: lx, dy: ly)
                let carriedCoverage = smudgeCellWeight(dx: lx, dy: ly, stroke: stroke)
                guard carriedCoverage > 0,
                      let pickupSource = try stroke.captureFrame.sourcePointIfInBounds(pickupDocument),
                      let under = try mappedSample(beforeDab, source: pickupSource, map: map) else { continue }
                let paint = frozenCarry[carryIndex] ?? premultiplied(under)
                nextCarry[carryIndex] = linearMix(premultiplied(under), paint, carriedCoverage * Float(stroke.opacity))
            }}
            for y in 0..<target.height { try Task.checkCancellation(); for x in 0..<target.width {
                guard let source = try map.sourcePointIfInBounds(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                      let document = try stroke.captureFrame.documentPointIfInBounds(source) else { continue }
                let local = SIMD2(Int(floor(document.x)) - Int(dab.x.rounded()),
                                  Int(floor(document.y)) - Int(dab.y.rounded()))
                let weight = smudgeCellWeight(dx: local.x, dy: local.y, stroke: stroke)
                let selectionWeight = selectionAlpha(selection, at: source)
                guard weight > 0, selectionWeight > 0 else { continue }
                guard abs(local.x) <= carryRadius, abs(local.y) <= carryRadius else { continue }
                let carryIndex = (local.y + carryRadius) * carrySide + local.x + carryRadius
                guard let paint = nextCarry[carryIndex] else { continue }
                // Publish the just-computed retained next carry: this is the same under+held
                // blend transported into the next dab, with selection applied once below.
                // Carry transport is selection-independent.  Its publication applies the
                // captured selection once in premultiplied HDR space, matching the tiled route.
                output.pixels[y * target.width + x] = premultipliedMix(beforeDab.pixels[y * target.width + x],
                                                                         straight(paint), selectionWeight)
            }}
            carried = nextCarry
        }
        return output
    }

    private static func blur(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                             map: LWSourceSpatialMap, selection: LWLinearSurface?) throws -> LWLinearSurface {
        let c = try coverage(stroke, surface: target, map: map, selection: selection)
        // This helper is the retained BlurTool formula in captured source-pixel units.
        let sigma = try stroke.captureFrame.retainedBlurSigma(blurRadius: stroke.blurRadius)
        guard sigma.isFinite, sigma > 0 else { throw ProjectError.invalid }
        let exactRadius = ceil(3 * sigma)
        guard exactRadius.isFinite, exactRadius >= 0, exactRadius <= Double(Int.max / 4) else { throw ProjectError.tooLarge }
        let radius = Int(exactRadius)
        var output = target
        for y in 0..<target.height { try Task.checkCancellation(); for x in 0..<target.width {
            let index = y * target.width + x, amount = c[index] * Float(stroke.opacity)
            guard amount > 0,
                  let source = try map.sourcePointIfInBounds(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                  let capturedDocument = try stroke.captureFrame.documentPointIfInBounds(source) else { continue }
            let capturedGrid = try stroke.captureFrame.documentToDevelopedPixel(capturedDocument)
            var sum = Pixel.zero, completeWeight: Float = 0
            for dy in -radius...radius { for dx in -radius...radius {
                let d2 = Double(dx) * Double(dx) + Double(dy) * Double(dy)
                let w = Float(exp(-d2 / (2 * sigma * sigma)))
                completeWeight += w
                // BlurTool offsets its captured developed layer grid, then maps back to source.
                let offsetDocument = try stroke.captureFrame.developedPixelToDocument(CGPoint(x: capturedGrid.x + CGFloat(dx), y: capturedGrid.y + CGFloat(dy)))
                guard let capturedSource = try stroke.captureFrame.sourcePointIfInBounds(offsetDocument),
                      let value = try mappedSample(target, source: capturedSource, map: map) else { continue }
                sum += premultiplied(value) * w
            }}
            guard completeWeight > 0 else { throw ProjectError.invalid }
            output.pixels[index] = premultipliedMix(target.pixels[index], straight(sum / completeWeight), amount)
        }}
        return output
    }

    // MARK: Float port of WarpStroke.push

    /// Liquify remains source-backed: every destination is mapped through the captured document
    /// frame, and each dab reads an immutable prior-dab surface before publishing its next dab.
    /// It never rasterizes the RAW source or substitutes an identity map.
    private static func liquify(_ stroke: LWSourceRetouchStroke, target: LWLinearSurface,
                                map: LWSourceSpatialMap, selection: LWLinearSurface?,
                                admission: LWSourceRetouchAdmission) throws -> LWLinearSurface {
        let dabs = try stroke.warpDabs
        guard dabs.count > 1 else { return target }
        var output = target
        for (from, to) in zip(dabs, dabs.dropFirst()) {
            let beforeDab = output
            var next = beforeDab
            let move = CGSize(width: (to.x - from.x) * stroke.liquifyStrength,
                              height: (to.y - from.y) * stroke.liquifyStrength)
            for y in 0..<target.height { try Task.checkCancellation(); for x in 0..<target.width {
                guard let source = try map.sourcePointIfInBounds(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                      let document = try stroke.captureFrame.documentPointIfInBounds(source) else { continue }
                let centre = CGPoint(x: to.x.rounded(), y: to.y.rounded())
                let dx = Int(floor(document.x)) - Int(centre.x)
                let dy = Int(floor(document.y)) - Int(centre.y)
                let weight = smudgeCellWeight(dx: dx, dy: dy, stroke: stroke)
                let selectionWeight = selectionAlpha(selection, at: source)
                guard weight > 0, selectionWeight > 0 else { continue }
                // The retained push raster is indexed by integer document cells. Its bilinear
                // input is the corresponding half-centred sample, never the soft-weight point.
                let rasterDocument = rasterCellCenter(center: centre, dx: dx, dy: dy)
                let pickupScale: CGFloat = CGFloat(weight) * CGFloat(selectionWeight)
                let pickupX: CGFloat = rasterDocument.x - move.width * pickupScale
                let pickupY: CGFloat = rasterDocument.y - move.height * pickupScale
                let pickupDocument = CGPoint(x: pickupX, y: pickupY)
                let pickupSource = try stroke.captureFrame.sourcePointClamped(pickupDocument)
                let pickup = try mappedSampleClamped(beforeDab, source: pickupSource, map: map)
                // WarpStroke.push publishes the displaced prior-dab sample; its retained weight
                // changes the displacement only, so no second blend is applied here.
                next.pixels[y * target.width + x] = pickup
            }}
            output = next
        }
        return output
    }
}

// R8 tiled entry point. This path remains separate from the observed R7 whole-plane
// evaluator. It is intentionally source-only until the companion persistence graph freezes.
extension LWSourceRetouch {
    /// Production tiled entry point. The admission is operation-wide and happens before selection,
    /// composite, tile, or typed-state decoding. Virtual image extent never becomes a hidden
    /// resident allocation: all readers, builders, and state stores lease the same workspace.
    static func evaluate(_ node: LWLiveSourceNode,
                         developed: LWFloatPlane,
                         map: LWSourceSpatialMap,
                         workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard developed.workingSet === workspace.workingSet else { throw ProjectError.invalid }
        var working = developed
        for stroke in node.retouch {
            try checkpoint(workspace)
            var superseded: LWFloatPlane?
            do {
                // The companion binds an admission to the exact immutable plane that precedes
                // this stroke. A later stroke cannot reuse the initial plane's approval or
                // dependency identity after an earlier stroke publishes a distinct plane.
                let before = working
                let scratch = try tiledScratchBytes(node: node, plane: before)
                let admission = try node.retouchAdmission(plane: before, workspace: workspace,
                                                           operationScratchBytes: scratch)
                let selectionPlane = try node.selectionPlane(for: stroke, admission: admission, workspace: workspace)
                let selection = try node.selectionSampler(for: stroke, plane: selectionPlane)
                // `before` remains retained for the complete stroke. Clone and sample-all receive
                // this immediately-prior plane, never a partially published output plane.
                let source = stroke.sampleAllLayers
                    ? try node.sampleAllCompositePlane(for: stroke, before: before, admission: admission, workspace: workspace)
                    : before
                switch stroke.kind {
                case .paint:
                    working = try tiledPaint(stroke, before: before, selection: selection, map: map, workspace: workspace)
                case .erase:
                    working = try tiledErase(stroke, before: before, selection: selection, map: map, workspace: workspace)
                case .clone:
                    working = try tiledClone(stroke, before: before, source: source, selection: selection, map: map, workspace: workspace)
                case .blur:
                    working = try tiledBlur(stroke, before: before, selection: selection, map: map, workspace: workspace)
                case .heal:
                    working = try tiledHeal(stroke, before: before, selection: selection, map: map, workspace: workspace)
                case .smear:
                    working = try tiledSmudge(stroke, before: before, selection: selection, map: map, workspace: workspace)
                case .liquify:
                    working = try tiledLiquify(stroke, before: before, selection: selection, map: map, workspace: workspace)
                }
                // Preserve the caller's initial plane and every still-shared backing. Only an
                // evaluator-owned intermediate is offered for checked retirement after the
                // successor has finished and all local readers/providers leave scope.
                if before.manifest.id != developed.manifest.id { superseded = before }
                withExtendedLifetime(admission.lease) {}
            }
            if superseded != nil { _ = try workspace.retireOwnedPlane(&superseded) }
            try workspace.retireReleasedGenerations()
            try checkpoint(workspace)
        }
        return working
    }

    // MARK: Admission and globally-addressed tile helpers

    /// This charges resident tile/carry/halo work only. Plane and dependency ownership are
    /// independently charged by `retouchAdmission(plane:workspace:operationScratchBytes:)`.
    /// Validate all metadata before any floating conversion or allocation.
    static func tiledScratchBytes(node: LWLiveSourceNode, plane: LWFloatPlane) throws -> Int {
        let tilePixels = try checkedMultiply(min(plane.width, LWFloatPlane.tileSide), min(plane.height, LWFloatPlane.tileSide))
        let rgbaTileBytes = try checkedMultiply(tilePixels, MemoryLayout<Pixel>.stride)
        let roleTileBytes = try checkedMultiply(tilePixels, MemoryLayout<UInt32>.stride)
        var peak = 0
        for stroke in node.retouch {
            guard stroke.radius.isFinite, stroke.radius > 0,
                  stroke.radius <= Double(DocumentLimits.maxSide),
                  stroke.opacity.isFinite, (0...1).contains(stroke.opacity),
                  stroke.hardness.isFinite, (0...1).contains(stroke.hardness),
                  stroke.pointsAreDabs, !stroke.points.isEmpty,
                  stroke.points.count <= 100_000,
                  stroke.color.count == 4, stroke.color.allSatisfy({ $0.isFinite }) else { throw ProjectError.invalid }
            let required: Int
            switch stroke.kind {
            case .heal:
                // `tiledHeal` holds immutable input/output tiles, three RGBA typed generations
                // (ring delta, membrane and coarse seed), and uint32 hole/role generations.
                // Each typed reader has a four-tile cache.  Charge the simultaneous bounded
                // cache set before `retouchAdmission`, rather than letting a late cache miss
                // turn an otherwise admitted operation into a partial allocation.
                let rgbaCaches = try checkedMultiply(rgbaTileBytes, 18)
                let roleCaches = try checkedMultiply(roleTileBytes, 18)
                required = try checkedAdd(rgbaCaches, roleCaches)
            case .smear:
                // `smudgeDabs` will add this captured first pickup after admission.  Check the
                // stored precondition here without constructing a second 100k-point array.
                guard stroke.sourceStart != nil else { throw ProjectError.invalid }
                // WarpStroke retains a bounded (2r+1)^2 brush-local pickup/next-carry grid.
                // It is not a full-frame dictionary keyed by a transformed destination.
                let grid = try smudgeCarryPlan(stroke)
                let carryPixels = try checkedMultiply(grid.side, grid.side)
                let carryBytes = try checkedMultiply(carryPixels, MemoryLayout<Pixel>.stride)
                // Frozen + copy-on-write next typed carry generations, plus immutable
                // input/output tile readers. The workspace owns both generations and may only
                // retire a released, exclusively held generation after publication.
                required = try checkedAdd(try checkedMultiply(carryBytes, 2), try checkedMultiply(rgbaTileBytes, 6))
            case .blur:
                // This is metadata-only and catches a bad/degenerate BlurTool radius before
                // sampler, halo, or output builder allocation.
                _ = try stroke.captureFrame.retainedBlurSigma(blurRadius: stroke.blurRadius)
                // input sampler, halo reads, output tile and the complete-kernel accumulator.
                required = try checkedMultiply(rgbaTileBytes, 6)
            case .liquify:
                guard stroke.sourceStart != nil else { throw ProjectError.invalid }
                // WarpStroke replays the captured pickup plus every persisted final step dab.
                // Charge both vectors before the evaluator builds its ordered prior/next sequence.
                let dabCount = try checkedAdd(stroke.points.count, 1)
                let dabBytes = try checkedMultiply(dabCount, MemoryLayout<CGPoint>.stride * 2)
                required = try checkedAdd(try checkedMultiply(rgbaTileBytes, 5), dabBytes)
            case .clone, .paint, .erase:
                required = try checkedMultiply(rgbaTileBytes, 3)
            }
            peak = max(peak, required)
        }
        guard peak <= plane.workingSet.limit else { throw ProjectError.tooLarge }
        return peak
    }

    private static func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
        let value = left.addingReportingOverflow(right)
        guard !value.overflow, value.partialValue >= 0 else { throw ProjectError.tooLarge }
        return value.partialValue
    }

    private static func checkedMultiply(_ left: Int, _ right: Int) throws -> Int {
        let value = left.multipliedReportingOverflow(by: right)
        guard !value.overflow, value.partialValue >= 0 else { throw ProjectError.tooLarge }
        return value.partialValue
    }

    private struct SmudgeCarryPlan {
        let radius: Int
        let side: Int
    }

    /// The retained CPU path stores one square of carried pixels around the brush centre.
    /// Validate before any integer conversion/allocation; a frame-sized map would both diverge
    /// from WarpStroke and make transformed replay depend on output traversal.
    private static func smudgeCarryPlan(_ stroke: LWSourceRetouchStroke) throws -> SmudgeCarryPlan {
        guard stroke.radius.isFinite, stroke.radius > 0,
              stroke.radius <= Double(DocumentLimits.maxSide) else { throw ProjectError.invalid }
        let rounded = ceil(stroke.radius)
        guard rounded.isFinite, rounded <= Double(Int.max / 4) else { throw ProjectError.tooLarge }
        let radius = Int(rounded)
        let side = try checkedAdd(try checkedMultiply(radius, 2), 1)
        return SmudgeCarryPlan(radius: radius, side: side)
    }

    /// WarpStroke carries document raster cells.  Its rounded brush center identifies an integer
    /// cell index, while plane sampling receives that cell's center.  Keeping this conversion in
    /// one helper prevents pickup, next-carry construction, and publication lookup from mixing
    /// integer cell indices with half-centered bilinear coordinates.
    private static func rasterCellCenter(center: CGPoint, dx: Int, dy: Int) -> CGPoint {
        CGPoint(x: center.x + CGFloat(dx) + 0.5, y: center.y + CGFloat(dy) + 0.5)
    }

    private static func checkpoint(_ workspace: LWFloatWorkspace) throws {
        try workspace.cancellation.check()
        try Task.checkCancellation()
    }

    private static func context(_ stroke: LWSourceRetouchStroke,
                                _ selection: LWSourceSelectionSampler?,
                                _ map: LWSourceSpatialMap,
                                x: Int, y: Int) throws -> (source: CGPoint, document: CGPoint, selection: Float)? {
        guard let source = try map.sourcePointIfInBounds(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
              let document = try stroke.captureFrame.documentPointIfInBounds(source) else { return nil }
        let alpha = try selection.map { try $0.sample(source).w } ?? 1
        return (source, document, min(1, max(0, alpha)))
    }

    /// Builder traversal is strictly manifest row-major. The input plane and every sampler stay
    /// immutable through the whole pass; closure code only returns a destination pixel.
    private static func tilePass(_ before: LWFloatPlane,
                                 workspace: LWFloatWorkspace,
                                 body: (LWFloatRange, Int, Int, Pixel) throws -> Pixel) throws -> LWFloatPlane {
        let builder = try workspace.makeBuilder(width: before.width, height: before.height)
        try before.forEachTile { range in
            try checkpoint(workspace)
            let tile = try before.read(range)
            // `tile.surface` is immutable owned storage. The successor reserves before its
            // callback and retains a distinct lease; no mutable tile array or uncharged COW
            // allocation can escape the source plane's reader lifetime.
            let output = try tile.surface.replacingPixels { index, original in
                try checkpoint(workspace)
                let localX = index % range.width, localY = index / range.width
                return try body(range, range.x + localX, range.y + localY, original)
            }
            try builder.append(output, at: range)
        }
        return try builder.finish()
    }

    private static func coverage(_ stroke: LWSourceRetouchStroke, document: CGPoint,
                                 selection: Float) throws -> Float {
        let dabs = try dabs(for: stroke)
        return tipCoverage(document, stroke: stroke, dabs: dabs) * selection
    }

    private static func mapped(_ sampler: LWFloatPlane.Sampler, source: CGPoint,
                               map: LWSourceSpatialMap, edge: LWFloatPlane.Edge = .transparent) throws -> Pixel {
        guard let developed = try map.developedPointIfInBounds(source) else { return .zero }
        return try sampler.sample(developed, edge: edge)
    }

    // MARK: Tile-local modes over immutable global input

    private static func tiledPaint(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                   selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                   workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let dabs = try dabs(for: stroke)
        let color = Pixel(stroke.color[0], stroke.color[1], stroke.color[2], stroke.color[3])
        return try tilePass(before, workspace: workspace) { _, x, y, value in
            guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
            let amount = tipCoverage(c.document, stroke: stroke, dabs: dabs) * c.selection * Float(stroke.opacity)
            return amount > 0 ? sourceOver(value, color, amount) : value
        }
    }

    private static func tiledErase(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                   selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                   workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let dabs = try dabs(for: stroke)
        return try tilePass(before, workspace: workspace) { _, x, y, value in
            guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
            let amount = tipCoverage(c.document, stroke: stroke, dabs: dabs) * c.selection * Float(stroke.opacity)
            guard amount > 0 else { return value }
            // Erase retains extended linear RGB and applies the single straight-alpha invariant.
            return Pixel(value.x, value.y, value.z, min(1, max(0, value.w * (1 - amount))))
        }
    }

    private static func tiledClone(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                   source: LWFloatPlane, selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                   workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let sourceSampler = source.sampler(edge: .transparent)
        let dabs = try dabs(for: stroke)
        return try tilePass(before, workspace: workspace) { _, x, y, value in
            guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
            let amount = tipCoverage(c.document, stroke: stroke, dabs: dabs) * c.selection * Float(stroke.opacity)
            guard amount > 0 else { return value }
            let shifted = CGPoint(x: c.document.x + stroke.sourceOffset.width, y: c.document.y + stroke.sourceOffset.height)
            // Ordinary extent misses are transparent; malformed/folded capture maps still throw.
            guard let captured = try stroke.captureFrame.sourcePointIfInBounds(shifted) else { return value }
            return sourceOver(value, try mapped(sourceSampler, source: captured, map: map), amount)
        }
    }

    private static func tiledBlur(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                  selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                  workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let dabs = try dabs(for: stroke)
        let sigma = try stroke.captureFrame.retainedBlurSigma(blurRadius: stroke.blurRadius)
        guard sigma.isFinite, sigma > 0 else { throw ProjectError.invalid }
        // BlurTool owns a Core Image Gaussian, not a hand-derived finite exp kernel.  Build a
        // bounded, range-backed captured-developed plane, invoke that retained operator through
        // its provider, then map the result back to current destinations.  The full logical
        // extent is tiled; neither source capture nor CI output becomes a hidden Swift array.
        let blurred = try retainedGaussianPlane(stroke, before: before, map: map, sigma: sigma, workspace: workspace)
        let sampler = blurred.sampler(edge: .transparent)
        return try tilePass(before, workspace: workspace) { _, x, y, value in
            guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
            let amount = tipCoverage(c.document, stroke: stroke, dabs: dabs) * c.selection * Float(stroke.opacity)
            guard amount > 0 else { return value }
            // Current destination → current source → captured document → captured developed grid.
            // The retained Core Image result is sampled in that captured developed grid; it never
            // treats a RAW coordinate as a grid offset or substitutes a numeric Gaussian.
            guard let capturedDocument = try stroke.captureFrame.documentPointIfInBounds(c.source) else { return value }
            let capturedGrid = try stroke.captureFrame.documentToDevelopedPixel(capturedDocument)
            return premultipliedMix(value, try sampler.sample(capturedGrid, edge: .transparent), amount)
        }
    }

    /// Materialize the captured developed-layer grid through only range-backed source reads,
    /// then delegate its Gaussian operator to the retained Core Image implementation.  This is
    /// deliberately separate from the current plane because a later geometry/optics map may be
    /// nonuniform: sampling the current plane with a scalar sigma would change BlurTool's source.
    private static func retainedGaussianPlane(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                              map: LWSourceSpatialMap, sigma: Double,
                                              workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let width = stroke.captureFrame.developedWidth, height = stroke.captureFrame.developedHeight
        guard width > 0, height > 0 else { throw ProjectError.invalid }
        let source = before.sampler(edge: .transparent)
        let capturedBuilder = try workspace.makeBuilder(width: width, height: height)
        while let range = capturedBuilder.nextRange {
            try checkpoint(workspace)
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            // Reserve the capture tile before its f32 array exists.  The source sampler has its
            // own shared cache lease and Core Image separately charges provider/output work.
            let captureLease = try workspace.workingSet.reserve(bytes)
            var pixels = [Pixel](repeating: .zero, count: range.width * range.height)
            for localY in 0..<range.height { for localX in 0..<range.width {
                try checkpoint(workspace)
                let capturedGrid = CGPoint(x: CGFloat(range.x + localX) + 0.5,
                                           y: CGFloat(range.y + localY) + 0.5)
                let document = try stroke.captureFrame.developedPixelToDocument(capturedGrid)
                if let capturedSource = try stroke.captureFrame.sourcePointIfInBounds(document),
                   let developed = try map.developedPointIfInBounds(capturedSource) {
                    pixels[localY * range.width + localX] = try source.sample(developed, edge: .transparent)
                }
            }}
            try capturedBuilder.append(try LWLinearSurface(width: range.width, height: range.height,
                pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(captureLease) {}
        }
        var captured: LWFloatPlane? = try capturedBuilder.finish()
        let result: LWFloatPlane
        do {
            guard let captured else { throw ProjectError.invalid }
            result = try LWFloatCoreImage.render(captured, makeBuilder: { width, height in
                try workspace.makeBuilder(width: width, height: height)
            }, cancellation: workspace.cancellation) { image in
                image.applyingGaussianBlur(sigma: sigma)
            }
        }
        // The provider has completed and released its captured-plane alias. Retire only this
        // evaluator-created range plane; history, source, and operator output are never offered.
        if captured != nil { _ = try workspace.retireOwnedPlane(&captured) }
        try workspace.retireReleasedGenerations()
        return result
    }

    // MARK: Global typed-state modes

    private struct TiledHealBox {
        let x0: Int; let y0: Int; let x1: Int; let y1: Int
        var width: Int { x1 - x0 }; var height: Int { y1 - y0 }
    }

    private static func tiledHeal(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                  selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                  workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let dabs = try dabs(for: stroke)
        // First pass is exact coverage in current developed coordinates. It establishes the work
        // box before the role/membrane state is decoded or allocated.
        let holes = try workspace.makeStateStore(format: .uint32, width: before.width, height: before.height)
        var bounds: (x0: Int, y0: Int, x1: Int, y1: Int)?
        try before.forEachTile { range in
            for y in range.y..<(range.y + range.height) { for x in range.x..<(range.x + range.width) {
                try checkpoint(workspace)
                guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { continue }
                if tipCoverage(c.document, stroke: stroke, dabs: dabs) * c.selection > 0 {
                    try holes.write(.uint32(2), x: x, y: y)
                    if var box = bounds { box.x0 = min(box.x0, x); box.y0 = min(box.y0, y); box.x1 = max(box.x1, x + 1); box.y1 = max(box.y1, y + 1); bounds = box }
                    else { bounds = (x, y, x + 1, y + 1) }
                }
            }}
        }
        guard let raw = bounds else { _ = try holes.commit(); return before }
        let spotSize = max(raw.x1 - raw.x0, raw.y1 - raw.y0)
        let ring = min(16, max(2, spotSize / 8))
        let box = TiledHealBox(x0: max(0, raw.x0 - ring), y0: max(0, raw.y0 - ring),
                               x1: min(before.width, raw.x1 + ring), y1: min(before.height, raw.y1 + ring))
        let holeSnapshot = try holes.commit(), holeReader = holeSnapshot.reader()
        let roles = try workspace.makeStateStore(format: .uint32, width: before.width, height: before.height)
        // C performs horizontal then vertical square dilation. The bounded direct neighborhood
        // below is the same Chebyshev-radius test, independent of tile traversal order.
        for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
            try checkpoint(workspace)
            if case .uint32(let hole) = try holeReader.read(x: x, y: y), hole == 2 {
                try roles.write(.uint32(2), x: x, y: y); continue
            }
            let left = max(box.x0, x - ring), right = min(box.x1 - 1, x + ring)
            let top = max(box.y0, y - ring), bottom = min(box.y1 - 1, y + ring)
            var near = false
            scan: for yy in top...bottom { for xx in left...right {
                if case .uint32(let hole) = try holeReader.read(x: xx, y: yy), hole == 2 { near = true; break scan }
            }}
            try roles.write(.uint32(near ? 1 : 0), x: x, y: y)
        }}
        let roleSnapshot = try roles.commit(), roleReader = roleSnapshot.reader()
        let sampler = before.sampler(edge: .transparent)
        let offset = try tiledHealBestPatch(sampler: sampler, roles: roleReader, box: box,
                                            frameWidth: before.width, frameHeight: before.height,
                                            mode: stroke.healMode, workspace: workspace)
        var ringCount = 0
        var mean = Pixel.zero
        var detail = SIMD3<Double>.zero
        let membrane = try workspace.makeStateStore(format: .rgba32, width: before.width, height: before.height)
        for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
            try checkpoint(workspace)
            guard case .uint32(let role) = try roleReader.read(x: x, y: y), role == 1 else { continue }
            let original = premultiplied(try sampler.pixel(x: x, y: y, edge: .transparent))
            let patch: Pixel
            if let offset { patch = premultiplied(try sampler.pixel(x: x + offset.x, y: y + offset.y, edge: .transparent)) }
            else { patch = .zero }
            let delta = original - patch
            try membrane.write(.rgba32(delta), x: x, y: y)
            mean += delta; ringCount += 1
            if offset == nil {
                var neighbor = Pixel.zero; var count: Double = 0
                for (nx, ny) in [(x-1,y), (x+1,y), (x,y-1), (x,y+1)] where nx >= 0 && ny >= 0 && nx < before.width && ny < before.height {
                    neighbor += premultiplied(try sampler.pixel(x: nx, y: ny, edge: .transparent)); count += 1
                }
                if count > 0 {
                    let d = original - neighbor / Float(count)
                    detail += SIMD3(Double(d.x * d.x), Double(d.y * d.y), Double(d.z * d.z))
                }
            }
        }}
        guard ringCount > 0 else { _ = try membrane.commit(); return before }
        mean /= Float(ringCount)
        for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
            if case .uint32(let role) = try roleReader.read(x: x, y: y), role == 2 { try membrane.write(.rgba32(mean), x: x, y: y) }
        }}
        // This is HealPixels' multigrid schedule: downsample ring/hole state, solve the
        // coarse membrane first, seed fine holes, then perform 40 SOR passes; small boxes run
        // the original 300-pass schedule. Every generation is typed, bounded, and globally
        // addressed, so no tile obtains a private local membrane.
        let membraneSnapshot = try solveTiledHealMembrane(values: membrane, roles: roleReader,
                                                           box: box, depth: 0, workspace: workspace)
        let membraneReader = membraneSnapshot.reader()
        detail = SIMD3<Double>(repeating: 0.9) * SIMD3(sqrt(detail.x / Double(ringCount)), sqrt(detail.y / Double(ringCount)), sqrt(detail.z / Double(ringCount)))
        return try tilePass(before, workspace: workspace) { _, x, y, value in
            guard x >= box.x0, y >= box.y0, x < box.x1, y < box.y1,
                  case .uint32(let role) = try roleReader.read(x: x, y: y), role == 2,
                  case .rgba32(let solved) = try membraneReader.read(x: x, y: y),
                  let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
            let amount = tipCoverage(c.document, stroke: stroke, dabs: dabs) * c.selection * Float(stroke.opacity)
            guard amount > 0 else { return value }
            let patch: Pixel
            if let offset { patch = premultiplied(try sampler.pixel(x: x + offset.x, y: y + offset.y, edge: .transparent)) }
            else { patch = .zero }
            var healed = patch + solved
            if offset == nil {
                let key = hash(stroke.seed ^ hash(UInt32(truncatingIfNeeded: y * before.width + x)))
                let grain = sqrt(-2 * log(1 - unit(key))) * cos(2 * .pi * unit(key ^ 0x68e31da4))
                healed.x += Float(grain * detail.x); healed.y += Float(grain * detail.y); healed.z += Float(grain * detail.z)
            }
            // HealPixels blends the reconstructed premultiplied membrane first; straight
            // storage applies the alpha invariant exactly once after partial coverage.
            return reconstructedPremultipliedMix(value, healed, amount)
        }
    }

    private static func solveTiledHealMembrane(values: LWTypedStateStore,
                                               roles: LWTypedStateStore.Reader,
                                               box: TiledHealBox, depth: Int,
                                               workspace: LWFloatWorkspace) throws -> LWTypedStateStore.Snapshot {
        let iterations: Int
        if box.width > 32 && box.height > 32 && depth < 16 {
            let coarseWidth = (box.width + 1) / 2, coarseHeight = (box.height + 1) / 2
            let coarseRoles = try workspace.makeStateStore(format: .uint32, width: coarseWidth, height: coarseHeight)
            let coarseValues = try workspace.makeStateStore(format: .rgba32, width: coarseWidth, height: coarseHeight)
            for cy in 0..<coarseHeight { for cx in 0..<coarseWidth {
                try checkpoint(workspace)
                var ringCount = 0, holeCount = 0, ringSum = Pixel.zero, holeSum = Pixel.zero
                for dy in 0..<2 { for dx in 0..<2 {
                    let x = box.x0 + cx * 2 + dx, y = box.y0 + cy * 2 + dy
                    guard x < box.x1, y < box.y1, case .uint32(let role) = try roles.read(x: x, y: y) else { continue }
                    if role == 1, case .rgba32(let value) = try values.read(x: x, y: y) { ringCount += 1; ringSum += value }
                    else if role == 2, case .rgba32(let value) = try values.read(x: x, y: y) { holeCount += 1; holeSum += value }
                }}
                if ringCount > 0 { try coarseRoles.write(.uint32(1), x: cx, y: cy); try coarseValues.write(.rgba32(ringSum / Float(ringCount)), x: cx, y: cy) }
                else if holeCount > 0 { try coarseRoles.write(.uint32(2), x: cx, y: cy); try coarseValues.write(.rgba32(holeSum / Float(holeCount)), x: cx, y: cy) }
            }}
            let coarseRoleSnapshot = try coarseRoles.commit()
            let coarseSolved = try solveTiledHealMembrane(values: coarseValues, roles: coarseRoleSnapshot.reader(),
                box: TiledHealBox(x0: 0, y0: 0, x1: coarseWidth, y1: coarseHeight), depth: depth + 1, workspace: workspace)
            let coarseReader = coarseSolved.reader(), coarseRolesReader = coarseRoleSnapshot.reader()
            for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
                guard case .uint32(let role) = try roles.read(x: x, y: y), role == 2,
                      case .uint32(let coarseRole) = try coarseRolesReader.read(x: (x - box.x0) / 2, y: (y - box.y0) / 2), coarseRole == 2,
                      case .rgba32(let value) = try coarseReader.read(x: (x - box.x0) / 2, y: (y - box.y0) / 2) else { continue }
                try values.write(.rgba32(value), x: x, y: y)
            }}
            iterations = 40
        } else { iterations = 300 }
        let omega: Float = 1.8
        for _ in 0..<iterations {
            for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
                try checkpoint(workspace)
                guard case .uint32(let role) = try roles.read(x: x, y: y), role == 2 else { continue }
                var sum = Pixel.zero; var count: Float = 0
                for (nx, ny) in [(x-1,y), (x+1,y), (x,y-1), (x,y+1)] where nx >= box.x0 && ny >= box.y0 && nx < box.x1 && ny < box.y1 {
                    guard case .uint32(let neighborRole) = try roles.read(x: nx, y: ny), neighborRole != 0,
                          case .rgba32(let neighbor) = try values.read(x: nx, y: ny) else { continue }
                    sum += neighbor; count += 1
                }
                guard count > 0, case .rgba32(let current) = try values.read(x: x, y: y) else { continue }
                try values.write(.rgba32(current + omega * (sum / count - current)), x: x, y: y)
            }}
        }
        return try values.commit()
    }

    private static func tiledHealBestPatch(sampler: LWFloatPlane.Sampler, roles: LWTypedStateStore.Reader,
                                           box: TiledHealBox, frameWidth: Int, frameHeight: Int,
                                           mode: LWSourceRetouchStroke.HealMode,
                                           workspace: LWFloatWorkspace) throws -> SIMD2<Int>? {
        guard mode != .createTexture else { return nil }
        func score(_ dx: Int, _ dy: Int) throws -> Double {
            guard !(abs(dx) < box.width && abs(dy) < box.height),
                  box.x0 + dx >= 0, box.y0 + dy >= 0,
                  box.x1 + dx <= frameWidth, box.y1 + dy <= frameHeight else { return .infinity }
            var sum = 0.0, count = 0
            for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
                try checkpoint(workspace)
                guard case .uint32(let role) = try roles.read(x: x, y: y), role == 1 else { continue }
                let a = premultiplied(try sampler.pixel(x: x, y: y, edge: .transparent))
                let b = premultiplied(try sampler.pixel(x: x + dx, y: y + dy, edge: .transparent))
                for channel in 0..<4 { let delta = Double(a[channel] - b[channel]); sum += delta * delta }
                count += 1
            }}
            return count > 0 ? sum / Double(count) : .infinity
        }
        let factors: [Double] = [1.05, 1.35, 1.75, 2.25, 2.8]
        let count = mode == .proximityMatch ? 2 : factors.count
        var best = Double.infinity, answer: SIMD2<Int>?
        for factorIndex in 0..<count { for angleIndex in 0..<24 {
            try checkpoint(workspace)
            let angle = Double(angleIndex) * .pi / 12
            let dx = Int((cos(angle) * factors[factorIndex] * Double(box.width)).rounded())
            let dy = Int((sin(angle) * factors[factorIndex] * Double(box.height)).rounded())
            let candidate = try score(dx, dy) * (mode == .proximityMatch ? 1 + 0.6 * Double(factorIndex) : 1 + 0.1 * Double(factorIndex))
            if candidate < best { best = candidate; answer = SIMD2(dx, dy) }
        }}
        guard let coarse = answer, best.isFinite else { return nil }
        var refined = try score(coarse.x, coarse.y), output = coarse
        for dy in -3...3 { for dx in -3...3 {
            try checkpoint(workspace)
            let candidate = try score(coarse.x + dx, coarse.y + dy)
            if candidate < refined { refined = candidate; output = SIMD2(coarse.x + dx, coarse.y + dy) }
        }}
        return output
    }

    private static func tiledSmudge(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                    selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                    workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let dabs = try stroke.smudgeDabs
        guard let initial = dabs.first else { throw ProjectError.invalid }
        let plan = try smudgeCarryPlan(stroke)

        // WarpStroke's first event is a pickup, never a publication.  Each carry cell is a
        // captured-developed-grid offset around that initial centre, so nonuniform replay cannot
        // turn a source-space brush into a current-output-grid map.
        let pickupSampler = before.sampler(edge: .transparent)
        // A brush-local typed grid is the retained `carried` representation.  The snapshot is
        // the frozen prior generation and the next store is its copy-on-write successor.  This
        // keeps exactly two charged carry generations live for a dab; it never grows a
        // destination-sized dictionary or stores one generation per recorded input point.
        // WarpStroke's context and brush radius are document-pixel values.  The captured
        // developed grid is used only to map a document cell to the source/current plane; it
        // never changes the carried grid's document-space radius under a scaled layer.
        let initialCentre = CGPoint(x: initial.x.rounded(), y: initial.y.rounded())
        // Keep exactly one strong carry snapshot after pickup commit.  Naming the committed
        // value separately from `carrySnapshot` would retain two aliases before the first COW
        // successor exists and make the two-generation contract an optimizer assumption.
        var carrySnapshot: LWTypedStateStore.Snapshot = try {
            let pickup = try workspace.makeStateStore(format: .rgba32, width: plan.side, height: plan.side)
            for localY in 0..<plan.side { for localX in 0..<plan.side {
                try checkpoint(workspace)
                let dx = localX - plan.radius, dy = localY - plan.radius
                let document = rasterCellCenter(center: initialCentre, dx: dx, dy: dy)
                let held: Pixel
                if let source = try stroke.captureFrame.sourcePointIfInBounds(document),
                   let developed = try map.developedPointIfInBounds(source) {
                    held = premultiplied(try pickupSampler.sample(developed, edge: .transparent))
                } else {
                    held = .zero
                }
                try pickup.write(.rgba32(held), x: localX, y: localY)
            }}
            return try pickup.commit()
        }()
        var working = before

        for dab in dabs.dropFirst() {
            try checkpoint(workspace)
            var nextSnapshot: LWTypedStateStore.Snapshot?
            var supersededPlane: LWFloatPlane?
            do {
                let prior = carrySnapshot.reader()
                let input = working.sampler(edge: .transparent)
                let next = try workspace.makeStateStore(format: .rgba32, width: plan.side, height: plan.side,
                                                          base: carrySnapshot)
                let centre = CGPoint(x: dab.x.rounded(), y: dab.y.rounded())

                // Freeze every prior-carry cell for this dab and publish its next state only after
                // the whole local grid is complete. This is the CPU WarpStroke `carried` transport,
                // not a current-plane traversal cache.
                for localY in 0..<plan.side { for localX in 0..<plan.side {
                    try checkpoint(workspace)
                    let dx = localX - plan.radius, dy = localY - plan.radius
                    let document = rasterCellCenter(center: centre, dx: dx, dy: dy)
                    let coverage = smudgeCellWeight(dx: dx, dy: dy, stroke: stroke)
                    let under: Pixel
                    if let source = try stroke.captureFrame.sourcePointIfInBounds(document),
                       let developed = try map.developedPointIfInBounds(source) {
                        under = premultiplied(try input.sample(developed, edge: .transparent))
                    } else {
                        under = .zero
                    }
                    guard case .rgba32(let held) = try prior.read(x: localX, y: localY) else {
                        throw ProjectError.invalid
                    }
                    // WarpStroke leaves a carry cell untouched outside the current hard/soft tip.
                    // Replacing it with `under` here would make a later dab depend on the current
                    // output traversal rather than its exact prior-dab pickup.
                    let painted = coverage > 0
                        ? linearMix(under, held, coverage * Float(stroke.opacity))
                        : held
                    try next.write(.rgba32(painted), x: localX, y: localY)
                }}
                let beforeDab = working
                working = try tilePass(beforeDab, workspace: workspace) { _, x, y, value in
                    guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
                    // Current output samples are pixel centers; carry ownership is indexed by
                    // retained document raster cells.  Convert both through floor(cell-center)
                    // rather than rounding one side and feeding the other into a bilinear sampler.
                    let localX = Int(floor(c.document.x)) - Int(centre.x) + plan.radius
                    let localY = Int(floor(c.document.y)) - Int(centre.y) + plan.radius
                    guard localX >= 0, localY >= 0, localX < plan.side, localY < plan.side else { return value }
                    let weight = smudgeCellWeight(dx: localX - plan.radius, dy: localY - plan.radius, stroke: stroke)
                    guard weight > 0, c.selection > 0 else { return value }
                    guard case .rgba32(let carried) = try next.read(x: localX, y: localY) else {
                        throw ProjectError.invalid
                    }
                    // `carried` already contains WarpStroke's strength/coverage blend. Publishing it
                    // directly avoids a second opacity crossfade.
                    // Carry transport is independent of selection. The publication mask is
                    // applied once in premultiplied space so a fractional captured selection
                    // cannot turn into a binary full-strength smudge.
                    return premultipliedMix(value, straight(carried), c.selection)
                }
                nextSnapshot = try next.commit()
                if beforeDab.manifest.id != before.manifest.id { supersededPlane = beforeDab }
            }
            guard let publishedCarry = nextSnapshot else { throw ProjectError.invalid }
            // Both the old carry reader and the old plane sampler have left their lexical scope.
            // The workspace may now retire an exclusively-held evaluator intermediate, but it
            // must preserve the caller's `before` plane and any history/provider-backed plane.
            carrySnapshot = publishedCarry
            if supersededPlane != nil { _ = try workspace.retireOwnedPlane(&supersededPlane) }
            try workspace.retireReleasedGenerations()
        }
        return working
    }

    private static func tiledLiquify(_ stroke: LWSourceRetouchStroke, before: LWFloatPlane,
                                     selection: LWSourceSelectionSampler?, map: LWSourceSpatialMap,
                                     workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let selectionSampler = selection
        let dabs = try stroke.warpDabs
        guard dabs.count > 1 else { return before }
        var working = before
        for (from, to) in zip(dabs, dabs.dropFirst()) {
            var superseded: LWFloatPlane?
            do {
                let priorDab = working
                let sampler = priorDab.sampler(edge: .clamp)
                working = try tilePass(priorDab, workspace: workspace) { _, x, y, value in
                    guard let c = try context(stroke, selectionSampler, map, x: x, y: y) else { return value }
                    let centre = CGPoint(x: to.x.rounded(), y: to.y.rounded())
                    let dx = Int(floor(c.document.x)) - Int(centre.x)
                    let dy = Int(floor(c.document.y)) - Int(centre.y)
                    let weight = smudgeCellWeight(dx: dx, dy: dy, stroke: stroke)
                    guard weight > 0, c.selection > 0 else { return value }
                    let rasterDocument = rasterCellCenter(center: centre, dx: dx, dy: dy)
                    let displacement = CGSize(width: (to.x - from.x) * CGFloat(stroke.liquifyStrength) * CGFloat(weight * c.selection),
                                              height: (to.y - from.y) * CGFloat(stroke.liquifyStrength) * CGFloat(weight * c.selection))
                    // WarpStroke pushes from the clamped prior-dab pickup. There is no second
                    // coverage/opacity crossfade after sampling.
                    let pickupDocument = CGPoint(x: rasterDocument.x - displacement.width, y: rasterDocument.y - displacement.height)
                    let captured = try stroke.captureFrame.sourcePointClamped(pickupDocument)
                    guard let developed = try map.developedPointIfInBounds(captured) else { throw ProjectError.invalid }
                    return try sampler.sample(developed, edge: .clamp)
                }
                if priorDab.manifest.id != before.manifest.id { superseded = priorDab }
            }
            // The sampler/alias is now out of scope. A caller, history, provider, or retained
            // reader still makes retirement fail closed; only an evaluator-owned predecessor is
            // eligible after this completed successor has published.
            if superseded != nil { _ = try workspace.retireOwnedPlane(&superseded) }
            try workspace.retireReleasedGenerations()
        }
        return working
    }
}
