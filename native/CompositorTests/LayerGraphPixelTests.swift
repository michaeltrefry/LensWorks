import Testing
import Foundation
import CoreGraphics
@testable import Compositor

/// S10 (sc-24665) bullet 1: the float document graph reproduces the retained Compositor's layer, folder, blend,
/// mask and clipping semantics. The oracle is the frozen Core Graphics compositor itself (`ImageExporter.render`
/// of an all-8-bit document), which the float branch must match within 8-bit rounding on in-range pixels; the
/// tile cache must then match the whole float frame.
@MainActor struct LayerGraphPixelTests {
    typealias F = LayerGraphFixture
    /// Premultiplied 8-bit levels. The retained compositor rounds to 8 bits after every layer, and a soft-edged
    /// clipping stack or folder mask adds one more rounding per stage.
    static let levelTolerance = 3.0
    static let contract = try! RendererContract.load()

    struct Graph {
        var width: Int, height: Int
        var layers: [ProjectLayerRecord] = []
        var images: [UUID: CGImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        @discardableResult mutating func add(_ record: ProjectLayerRecord, _ image: CGImage? = nil, mask: ImportedImage? = nil,
                                             placement: LayerTransform? = nil, enabled: Bool = true) -> UUID {
            var record = record
            if let mask { record.maskFile = record.id.uuidString + ".mask.png"; record.maskEnabled = enabled; record.maskPlacement = placement; masks[record.id] = mask }
            layers.append(record)
            if let image { images[record.id] = image }
            return record.id
        }
        @MainActor func reference() throws -> Reference? { try LayerGraphPixelTests.reference(self) }
        func snapshot(document: UUID = UUID()) -> ProjectSnapshot {
            ProjectSnapshot(manifest: ProjectManifest(documentID: document, width: width, height: height, activeLayerID: layers.last?.id, layers: layers),
                images: images.mapValues { F.asset($0) }, masks: masks)
        }
    }

    /// The graph's `Reference`, read from its 8-bit images and masks. Nil when the graph has something `Reference`
    /// does not evaluate (an adjustment, a flipped or resampled layer, a mask placed apart from its layer).
    private static func reference(_ graph: Graph) throws -> Reference? {
        var pixels: [UUID: [SIMD4<Float>]] = [:], masks: [UUID: [Float]] = [:]
        let w = graph.width, h = graph.height
        func placed<T>(_ values: [T], _ iw: Int, _ ih: Int, at origin: CGPoint, outside: T) -> [T] {
            let ox = Int(origin.x), oy = Int(origin.y)
            return (0..<w * h).map { i in
                let x = i % w - ox, y = i / w - oy
                return x >= 0 && y >= 0 && x < iw && y < ih ? values[y * iw + x] : outside
            }
        }
        for layer in graph.layers {
            let t = layer.transform
            guard layer.adjustment == nil, layer.maskPlacement == nil, t.rotation == 0, !t.flipX, !t.flipY,
                  t.origin.x == t.origin.x.rounded(), t.origin.y == t.origin.y.rounded() else { return nil }
            if let image = graph.images[layer.id] {
                guard t.size == CGSize(width: image.width, height: image.height) else { return nil }
                pixels[layer.id] = placed(try F.levels(image).map(F.straight), image.width, image.height, at: t.origin, outside: .zero)
            }
            if let mask = graph.masks[layer.id]?.image {
                guard t.size == CGSize(width: mask.width, height: mask.height) else { return nil }
                masks[layer.id] = placed(try GuidedMatte.levels(of: mask, width: mask.width, height: mask.height), mask.width, mask.height, at: t.origin, outside: 1)
            }
        }
        return Reference(layers: graph.layers, pixels: pixels, masks: masks, count: w * h)
    }

    /// `scale` 1 is the small document compared with the retained compositor; larger scales spread the same
    /// graph over several tiles and evaluation blocks.
    static func graph(_ name: String, mode: LayerBlendMode = .normal, scale s: Int = 1) throws -> Graph {
        let w = 64 * s, h = 48 * s
        var g = Graph(width: w, height: h)
        func at(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        let backdrop = F.pattern(w, h, seed: 1, alpha: 255)
        g.add(F.raster("Backdrop", backdrop), backdrop)
        func put(_ name: String, seed: Int, _ iw: Int, _ ih: Int, at origin: CGPoint, parent: UUID? = nil, mode: LayerBlendMode = .normal,
                 opacity: Double = 1, visible: Bool = true, clip: UUID? = nil, alpha: Int? = nil, mask: ImportedImage? = nil,
                 placement: LayerTransform? = nil, enabled: Bool = true) -> UUID {
            let image = F.pattern(iw * s, ih * s, seed: seed, alpha: alpha)
            return g.add(F.raster(name, image, at: origin, parent: parent, mode: mode, opacity: opacity, visible: visible, clip: clip),
                         image, mask: mask, placement: placement, enabled: enabled)
        }
        switch name {
        case "nested-groups":
            // Opacity multiplies down three folders; a hidden folder hides what is inside, however visible.
            let outer = g.add(F.folder("Outer", width: w, height: h, opacity: 0.8))
            _ = put("In outer", seed: 2, 40, 30, at: at(4, 6), parent: outer, opacity: 0.9)
            let middle = g.add(F.folder("Middle", width: w, height: h, parent: outer, opacity: 0.5))
            _ = put("In middle", seed: 3, 36, 30, at: at(20, 10), parent: middle, mode: .multiply)
            let inner = g.add(F.folder("Inner", width: w, height: h, parent: middle, opacity: 0.7))
            _ = put("In inner", seed: 4, 30, 24, at: at(30, 20), parent: inner, opacity: 0.6)
            let hidden = g.add(F.folder("Hidden", width: w, height: h, parent: outer, visible: false))
            _ = put("In hidden", seed: 5, 64, 48, at: at(0, 0), parent: hidden, alpha: 255)
            _ = put("Hidden layer", seed: 6, 64, 48, at: at(0, 0), parent: outer, visible: false, alpha: 255)
            _ = put("Above", seed: 7, 24, 20, at: at(2, 26), mode: .screen, opacity: 0.75)
            g.add(F.folder("Empty", width: w, height: h, opacity: 0.3))
        case "group-masks":
            // A folder mask clips everything inside, multiplied by enclosing folders' masks and each layer's own;
            // a disabled mask does nothing; a mask moved apart from its layer keeps its own placement.
            let outer = g.add(F.folder("Outer", width: w, height: h, opacity: 0.9), mask: try F.ramp(w, h, seed: 1))
            _ = put("Masked", seed: 2, 40, 30, at: at(4, 6), parent: outer, mask: try F.ramp(40 * s, 30 * s, seed: 2))
            let inner = g.add(F.folder("Inner", width: w, height: h, parent: outer), mask: try F.ramp(w, h, seed: 3))
            _ = put("In inner", seed: 3, 36, 30, at: at(20, 10), parent: inner, mode: .overlay, alpha: 255)
            _ = put("Disabled mask", seed: 4, 20, 20, at: at(40, 2), parent: inner, mask: try F.ramp(20 * s, 20 * s, seed: 4), enabled: false)
            var moved = LayerTransform(origin: at(10, 24), size: CGSize(width: 30 * s, height: 20 * s)); moved.sampling = .nearest
            _ = put("Moved mask", seed: 5, 30, 20, at: at(6, 22), mask: try F.ramp(30 * s, 20 * s, seed: 5), placement: moved)
            let off = g.add(F.folder("Disabled folder mask", width: w, height: h), mask: try F.ramp(w, h, seed: 6), enabled: false)
            _ = put("In off", seed: 6, 16, 16, at: at(46, 30), parent: off)
        case "clipping":
            // A soft-edged base at reduced opacity with a clipped stack (blend modes, opacity, a masked child), then
            // an unclipped layer, then layers that take another layer's alpha from elsewhere in the document.
            let folder = g.add(F.folder("Folder", width: w, height: h, opacity: 0.9), mask: try F.ramp(w, h, seed: 7))
            let base = put("Base", seed: 2, 44, 34, at: at(4, 4), parent: folder, mode: .hardLight, opacity: 0.8)
            _ = put("Clipped multiply", seed: 3, 50, 40, at: at(0, 0), parent: folder, mode: .multiply, clip: base, alpha: 255)
            _ = put("Clipped half", seed: 4, 30, 30, at: at(12, 8), parent: folder, opacity: 0.5, clip: base)
            _ = put("Clipped masked", seed: 5, 40, 20, at: at(8, 14), parent: folder, mode: .screen, clip: base, alpha: 255,
                    mask: try F.ramp(40 * s, 20 * s, seed: 5))
            _ = put("Unclipped", seed: 6, 14, 14, at: at(48, 2), parent: folder)
            // A hidden source still supplies its alpha, at its own opacity and through its own mask.
            let source = put("Hidden source", seed: 7, 40, 30, at: at(20, 16), opacity: 0.6, visible: false, mask: try F.ramp(40 * s, 30 * s, seed: 8))
            let linked = put("Takes hidden alpha", seed: 8, 64, 48, at: at(0, 0), mode: .difference, clip: source, alpha: 255)
            // A chain: this layer's coverage is its own alpha times its source's.
            _ = put("Chained", seed: 9, 50, 40, at: at(10, 6), opacity: 0.7, clip: linked)
        case "blend-through-group":
            // The mode belongs to the layer, however deep: it blends with everything below, outside its folders.
            let outer = g.add(F.folder("Outer", width: w, height: h, opacity: 0.9), mask: try F.ramp(w, h, seed: 9))
            let inner = g.add(F.folder("Inner", width: w, height: h, parent: outer, opacity: 0.85))
            _ = put("Blended", seed: 2, 48, 36, at: at(6, 4), parent: inner, mode: mode, opacity: 0.9)
            let base = put("Stack base", seed: 3, 40, 30, at: at(20, 14), parent: inner, mode: mode)
            _ = put("Stack child", seed: 4, 44, 34, at: at(16, 12), parent: inner, mode: mode, opacity: 0.8, clip: base, alpha: 255)
            _ = put("Over the group", seed: 5, 30, 20, at: at(2, 26), mode: mode, opacity: 0.6)
        case "flips":
            // Flip Layer mirrors the layer in place and carries a linked mask with it; a mask placed apart mirrors
            // on its own. A flipped base keeps its clipped layers where they were.
            func flip(_ id: UUID, x: Bool, y: Bool) {
                let i = g.layers.firstIndex { $0.id == id }!
                g.layers[i].transform.flipX = x; g.layers[i].transform.flipY = y
            }
            let folder = g.add(F.folder("Folder", width: w, height: h, opacity: 0.9), mask: try F.ramp(w, h, seed: 3))
            flip(put("Flipped across", seed: 2, 40, 30, at: at(4, 6), parent: folder, mask: try F.ramp(40 * s, 30 * s, seed: 2)), x: true, y: false)
            var apart = LayerTransform(origin: at(26, 12), size: CGSize(width: 30 * s, height: 20 * s)); apart.sampling = .nearest; apart.flipY = true
            flip(put("Flipped down, mask apart", seed: 3, 30, 24, at: at(22, 10), parent: folder, mode: .overlay, mask: try F.ramp(30 * s, 20 * s, seed: 4), placement: apart), x: false, y: true)
            let base = put("Flipped base", seed: 4, 36, 28, at: at(10, 16), mode: .multiply)
            flip(base, x: true, y: true)
            _ = put("Clipped to flipped", seed: 5, 44, 34, at: at(8, 12), opacity: 0.8, clip: base, alpha: 255)
        case "clipped-adjustment", "clipped-adjustment-blended", "clipped-adjustment-hidden-base":
            // A clipping stack holding an adjustment: it changes the base's colour through its own mask, at its own
            // opacity and in its own mode, inside the base's alpha, and the raster clipped above it paints over the
            // result. With the base hidden there is no stack left for the adjustment to act in and it draws nothing,
            // while the raster still takes the hidden base's alpha.
            let folder = g.add(F.folder("Folder", width: w, height: h, opacity: 0.85), mask: try F.ramp(w, h, seed: 4))
            let base = put("Soft base", seed: 2, 46, 36, at: at(6, 4), parent: folder, visible: !name.hasSuffix("hidden-base"))
            g.add(F.adjustment("Clipped adjustment", LayerAdjustment(kind: .invert), width: w, height: h, parent: folder,
                               mode: name.hasSuffix("blended") ? .multiply : .normal, opacity: 0.7, clip: base), mask: try F.ramp(w, h, seed: 5))
            _ = put("Clipped raster", seed: 3, 30, 24, at: at(20, 14), parent: folder, mode: .screen, opacity: 0.8, clip: base)
            _ = put("Above", seed: 6, 20, 16, at: at(40, 28), opacity: 0.9)
        case "one-stage":
            // One opaque layer in `mode` over the opaque backdrop: a single blend of exact 8-bit operands, with no
            // intermediate for the retained compositor to round. Every channel meets 0 and 255, their neighbours,
            // the complementary pairs that sum to exactly 255 (Hard Mix's threshold) and both sides of one half;
            // the right-hand quarter is grey on grey, where the hue and saturation transfers have nothing to take.
            let steps = [0, 255, 1, 254, 127, 128, 64, 191, 2, 253, 126, 129, 32, 223, 96, 159]
            func level(_ index: Int, _ channel: Int, grey: Bool) -> Int { steps[(index + (grey ? 0 : channel * 5)) % steps.count] }
            g = Graph(width: w, height: h)
            let below = F.image(w, h) { x, _ in let grey = x >= w * 3 / 4; return (level(x / s, 0, grey: grey), level(x / s, 1, grey: grey), level(x / s, 2, grey: grey), 255) }
            let above = F.image(w, h) { x, y in let grey = x >= w * 3 / 4; return (level(y / s, 0, grey: grey), level(y / s + x / s / 16, 1, grey: grey), level(y / s, 2, grey: grey), 255) }
            g.add(F.raster("Backdrop", below), below)
            g.add(F.raster("Blended", above, mode: mode), above)
        default: throw ProjectError.invalid
        }
        return g
    }

    /// Modes with a threshold or a steep slope (and the hue and saturation transfers near grey), where one unit of
    /// rounding in an operand can move the result a long way.
    static let steepModes: Set<LayerBlendMode> = [.colorBurn, .colorDodge, .vividLight, .linearLight, .hardLight, .hardMix, .divide, .hue, .saturation, .color, .luminosity]
    /// Modes whose result is a continuous function of both operands with slope at most 2: 8-bit rounding of an
    /// operand cannot move their result by more than `levelTolerance`.
    static let gentleModes = Set(LayerBlendMode.allCases).subtracting([.colorBurn, .colorDodge, .vividLight, .hardMix, .divide, .hue, .saturation, .color, .luminosity])

    /// Where the float graph and the retained compositor differ by more than `levelTolerance`, the difference has to
    /// be one that 8-bit rounding explains. The retained compositor rounds what is below to 8 bits after every
    /// layer and reads each layer as premultiplied 8 bits; a steep or thresholded mode turns that one level into a
    /// large difference at an isolated pixel. So a pixel beyond tolerance is admitted only if the graph, evaluated
    /// again at that pixel by `Reference` with every blend's operands moved by up to one 8-bit level, spans the
    /// retained value. A difference in how the graph is composited, or in what a mode does at the ends of its
    /// range, is not spanned and fails. `excused` names pixels a caller has checked against the declared rule itself.
    private func compareWithRetained(_ graph: Graph, _ label: String, admitting: Bool = true, excused: Set<Int> = []) async throws {
        let found = try await Self.unexplained(graph, admitting: admitting, excused: excused)
        #expect(found.refused == 0, "\(label): \(found.refused) of \(found.outliers) pixels beyond \(Self.levelTolerance) levels are not explained by 8-bit rounding; \(found.first)")
    }
    /// The pixels of an all-8-bit document where the float graph and the retained compositor differ by more than
    /// `levelTolerance` (`outliers`), and how many of those the one-level span does not explain (`refused`).
    static func unexplained(_ graph: Graph, admitting: Bool = true, excused: Set<Int> = []) async throws -> (refused: Int, outliers: Int, first: String) {
        let snapshot = graph.snapshot()
        let retained = try F.levels(try await ImageExporter.shared.render(snapshot).image)
        let set = try LWFloatWorkingSet(limit: 256 * 1024 * 1024)
        let float = F.levels(try F.float(snapshot, workingSet: set))
        let outliers = float.indices.filter { i in
            let d = float[i] - retained[i]
            return !excused.contains(i) && max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) > Self.levelTolerance
        }
        guard !outliers.isEmpty else { return (0, 0, "") }
        let reference = admitting ? try graph.reference() : nil
        let refused = outliers.filter { i in
            guard let reference else { return true }
            let span = reference.span(i), tolerance = SIMD4(repeating: Self.levelTolerance)
            // Alpha never depends on the mode or on rounding below: it has to agree outright.
            return abs(float[i].w - retained[i].w) > Self.levelTolerance
                || any(retained[i] .< span.lo - tolerance) || any(retained[i] .> span.hi + tolerance)
        }
        let first = refused.prefix(6).map { "float \(float[$0]) vs retained \(retained[$0]) at (\($0 % graph.width), \($0 / graph.width))" }.joined(separator: "; ")
        return (refused.count, outliers.count, first)
    }

    @Test(arguments: ["nested-groups", "group-masks", "clipping", "flips", "clipped-adjustment", "clipped-adjustment-blended", "clipped-adjustment-hidden-base"])
    func floatGraphMatchesTheRetainedCompositor(_ name: String) async throws {
        try await compareWithRetained(try Self.graph(name), name, admitting: false)
    }

    /// What a thresholded mode gives where an 8-bit operand sits exactly on an end of its range: the declared rule
    /// (`LWFloatBlend.extendedRules`) and the retained compositor's Core Image kernel. They agree everywhere but on
    /// Hard Mix's threshold itself, which the declared rule includes (b + s >= 1) and Core Image's kernel does not.
    static func boundary(_ mode: LayerBlendMode, backdrop b: Int, source s: Int) -> (declared: Int, retained: Int)? {
        switch mode {
        case .colorBurn: return b == 255 ? (255, 255) : s == 0 ? (0, 0) : nil
        case .colorDodge: return b == 0 ? (0, 0) : s == 255 ? (255, 255) : nil
        case .divide: return b == 0 ? (0, 0) : s == 0 ? (255, 255) : nil
        case .vividLight: return b == 255 ? (255, 255) : b == 0 ? (0, 0) : nil
        case .hardMix: return (b == 255 && s == 0) || (b == 0 && s == 255) ? (255, 0) : nil
        default: return nil
        }
    }
    /// W3C Color, B(Cb, Cs) = SetLum(Cs, Lum(Cb)), on encoded operands in 0...1: written out here, apart from the kernel.
    static func colorBlend(backdrop b: SIMD3<Double>, source s: SIMD3<Double>) -> SIMD3<Double> {
        func lum(_ c: SIMD3<Double>) -> Double { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }
        var c = s + SIMD3(repeating: lum(b) - lum(s))
        let l = lum(c), n = c.min(), x = c.max()
        if n < 0 { c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * (l / (l - n)) }
        if x > 1 { c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * ((1 - l) / (x - l)) }
        return c
    }

    /// One blend of exact 8-bit operands, including 0 and 255: the float kernel and the retained compositor agree
    /// on what every mode does, at the ends of its range as well as inside it. The continuous modes, and the hue,
    /// saturation and luminosity transfers, agree at every pixel. A thresholded mode may differ only where one
    /// level in an operand crosses its threshold, and where an operand is exactly 0 or 255 both give what the
    /// declared rule says (`boundary`). Color agrees except where the backdrop's luminosity is within two levels of
    /// black or white: there Core Graphics does not keep the backdrop's luminosity (over white it gives a saturated
    /// colour), and the float kernel is held to the W3C formula instead.
    @Test(arguments: LayerBlendMode.allCases)
    func everyBlendModeOnOneStageMatchesTheRetainedCompositor(_ mode: LayerBlendMode) async throws {
        let graph = try Self.graph("one-stage", mode: mode), snapshot = graph.snapshot()
        let below = try F.levels(try #require(graph.images[graph.layers[0].id])), above = try F.levels(try #require(graph.images[graph.layers[1].id]))
        let float = F.levels(try F.float(snapshot, workingSet: try LWFloatWorkingSet(limit: 256 * 1024 * 1024)))
        let retained = try F.levels(try await ImageExporter.shared.render(snapshot).image)
        // The ends of the range, channel by channel.
        var ends = 0
        for i in float.indices { for c in 0..<3 {
            guard let expected = Self.boundary(mode, backdrop: Int(below[i][c]), source: Int(above[i][c])) else { continue }
            ends += 1
            #expect(abs(float[i][c] - Double(expected.declared)) <= 0.5 && Int(retained[i][c]) == expected.retained,
                "\(mode) of \(Int(above[i][c])) over \(Int(below[i][c])): float \(float[i][c]) (declared \(expected.declared)), retained \(retained[i][c]) (expected \(expected.retained))")
        } }
        #expect((ends > 0) == [.colorBurn, .colorDodge, .divide, .vividLight, .hardMix].contains(mode))
        var excused = Set<Int>()
        if mode == .color {
            for i in float.indices {
                let b = SIMD3(below[i].x, below[i].y, below[i].z) / 255, s = SIMD3(above[i].x, above[i].y, above[i].z) / 255
                let luminosity = (0.3 * b.x + 0.59 * b.y + 0.11 * b.z) * 255
                guard luminosity <= 2 || luminosity >= 253 else { continue }
                let formula = Self.colorBlend(backdrop: b, source: s) * 255, made = SIMD3(float[i].x, float[i].y, float[i].z)
                let difference = made - formula
                #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) <= 1, "Color of \(above[i]) over \(below[i]): float \(made), W3C \(formula)")
                excused.insert(i)
            }
            #expect(!excused.isEmpty && excused.count < float.count / 8, "the luminosity bounds are a small part of the fixture")
        }
        let exact = Self.gentleModes.contains(mode) || [.hue, .saturation, .luminosity].contains(mode)
        try await compareWithRetained(graph, "one stage \(mode)", admitting: !exact, excused: excused)
    }

    /// Hue and Saturation with a translucent source are where the retained compositor is not the float graph's
    /// oracle. Core Graphics applies the source's alpha twice in the two modes that set saturation: measured on the
    /// "blend-through-group" fixture at (16, 6), a Saturation layer of alpha 0.302 under a folder mask of 0.396 moves
    /// the backdrop's blue from 121 to 119, where B(Cb, Cs) composited by the source-over equation gives 113.8 and
    /// 121 + 0.396 * 0.302 * 0.302 * (B - 121) gives 118.8. On opaque operands the two agree (the one-stage test).
    /// The float kernel follows the declared rule, so for these two modes the graph is held to that rule evaluated
    /// per pixel on the same 8-bit inputs.
    static let retainedAppliesSourceAlphaTwice: Set<LayerBlendMode> = [.hue, .saturation]

    @Test(arguments: LayerBlendMode.allCases)
    func everyBlendModeThroughAGroupBoundaryMatchesTheRetainedCompositor(_ mode: LayerBlendMode) async throws {
        let graph = try Self.graph("blend-through-group", mode: mode)
        guard Self.retainedAppliesSourceAlphaTwice.contains(mode) else { return try await compareWithRetained(graph, "\(mode)") }
        let reference = try #require(try graph.reference())
        let float = F.levels(try F.float(graph.snapshot(), workingSet: try LWFloatWorkingSet(limit: 256 * 1024 * 1024))), expected = F.levels(reference.render())
        // Within tolerance of the rule on the stored 8-bit levels; or, where the float graph's own reading of an 8-bit
        // layer (a fraction of a level off) is magnified by the transfer, within the rule's span for one level.
        let tolerance = SIMD4(repeating: Self.levelTolerance)
        let refused = float.indices.filter { i in
            let d = float[i] - expected[i]
            guard max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) > Self.levelTolerance else { return false }
            let span = reference.span(i)
            return abs(d.w) > Self.levelTolerance || any(float[i] .< span.lo - tolerance) || any(float[i] .> span.hi + tolerance)
        }
        let first = refused.first.map { "float \(float[$0]) vs the declared rule \(expected[$0]) at (\($0 % graph.width), \($0 / graph.width))" } ?? ""
        #expect(refused.isEmpty, "\(mode): \(refused.count) pixels are not the declared rule's; \(first)")
        // And the retained compositor really is somewhere else here: were it not, it would be the oracle again.
        let retained = try F.levels(try await ImageExporter.shared.render(graph.snapshot()).image)
        #expect(F.worst(float, retained).error > 2 * Self.levelTolerance, "\(mode): the retained compositor now agrees; compare with it")
    }

    /// The same graphs spread over 3×2 tiles: tile evaluation equals the whole frame.
    @Test(arguments: ["nested-groups", "group-masks", "clipping", "flips", "blend-through-group", "clipped-adjustment", "clipped-adjustment-blended", "clipped-adjustment-hidden-base"])
    func tiledGraphMatchesTheWholeFrame(_ name: String) throws {
        for mode in name == "blend-through-group" ? [LayerBlendMode.softLight, .linearLight, .luminosity] : [.normal] {
            let snapshot = try Self.graph(name, mode: mode, scale: 9).snapshot()
            let set = try LWFloatWorkingSet(limit: 512 * 1024 * 1024)
            let whole = try F.float(snapshot, workingSet: set), tiled = try F.tiled(snapshot, workingSet: set)
            let error = F.worstRelative(tiled, whole)
            #expect(error <= Self.contract.document_region_parity_relative, "\(name) \(mode): worst \(error)")
        }
    }

    // MARK: HDR float layers against a per-pixel evaluation of the graph

    /// The graph evaluated one pixel at a time, written from the retained compositor's rules rather than from the
    /// float compositor's code: folders pass through (their opacity and masks multiply into each layer inside), a
    /// layer that takes another's alpha multiplies its own by that layer's coverage (own alpha, own mask, drawn
    /// opacity, and its source's coverage in turn; never its visibility), and a clipping stack composites its
    /// clipped layers on the base's colour as if opaque before taking the base's alpha back. Only the two-pixel
    /// blend itself is the kernel's (`LWFloatBlend.pixel`, checked on its own by FloatRendererPrecisionTests).
    struct Reference {
        let layers: [ProjectLayerRecord], pixels: [UUID: [SIMD4<Float>]], masks: [UUID: [Float]], count: Int
        var byID: [UUID: ProjectLayerRecord] { Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) }) }
        func ancestors(_ layer: ProjectLayerRecord) -> [ProjectLayerRecord] {
            var result: [ProjectLayerRecord] = [], parent = layer.parentID
            while let id = parent, let folder = byID[id] { result.append(folder); parent = folder.parentID }
            return result
        }
        func drawnOpacity(_ layer: ProjectLayerRecord) -> Float { Float(ancestors(layer).reduce(layer.opacity ?? 1) { $0 * ($1.opacity ?? 1) }) }
        func mask(_ layer: ProjectLayerRecord, _ i: Int) -> Float { layer.maskEnabled == false ? 1 : masks[layer.id]?[i] ?? 1 }
        func own(_ layer: ProjectLayerRecord, _ i: Int) -> SIMD4<Float> {
            var p = pixels[layer.id]?[i] ?? .zero; p.w *= mask(layer, i); return p
        }
        func coverage(_ layer: ProjectLayerRecord, _ i: Int) -> Float {
            own(layer, i).w * drawnOpacity(layer) * (layer.maskSourceID.flatMap { byID[$0] }.map { coverage($0, i) } ?? 1)
        }
        /// The range of results at pixel `i`, as premultiplied sRGB levels, when every operand of every blend is
        /// moved by up to one 8-bit level: each layer's own pixel, as it is drawn, one premultiplied level down, as
        /// it is and one up, over what is below it as evaluated and at the corners of the range those moves have
        /// reached so far. Alpha is not varied. The evaluation is `render`'s, stage for stage.
        func span(_ i: Int) -> (lo: SIMD4<Double>, hi: SIMD4<Double>) {
            func nudged(_ p: SIMD4<Float>) -> [SIMD4<Float>] {
                guard p.w > 0 else { return [p] }
                let stored = F.levels([p])[0]
                // All three channels together, and each alone: the hue and saturation transfers turn on their differences.
                let moves = [-1.0, 1].flatMap { d in [SIMD4(d, d, d, 0), SIMD4(d, 0, 0, 0), SIMD4(0, d, 0, 0), SIMD4(0, 0, d, 0)] }
                return [p] + moves.map { move in
                    var moved = (stored + move).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: stored.w)); moved.w = stored.w
                    var straight = F.straight(moved); straight.w = p.w; return straight
                }
            }
            let visible = layers.filter { $0.isGroup != true && $0.isVisible && ancestors($0).allSatisfy(\.isVisible) }
            var exact = SIMD4<Float>.zero, lo = SIMD4<Double>.zero, hi = SIMD4<Double>.zero, index = 0
            while index < visible.count {
                let layer = visible[index]
                var top = own(layer, i)
                if let source = layer.maskSourceID.flatMap({ byID[$0] }) { top.w *= coverage(source, i) }
                top.w *= ancestors(layer).reduce(1) { $0 * mask($1, i) } * drawnOpacity(layer)
                var tops = nudged(top), next = index + 1
                if layer.maskSourceID == nil {
                    var colours = tops.map { SIMD4($0.x, $0.y, $0.z, 1) }, stacked = false
                    while next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                        var child = own(visible[next], i); child.w *= drawnOpacity(visible[next])
                        let mode = visible[next].blendMode ?? .normal
                        colours = colours.flatMap { colour in nudged(child).map { LWFloatBlend.pixel(mode, top: $0, bottom: colour) } }
                        next += 1; stacked = true
                    }
                    // The retained compositor holds the stack's colour in 8 bits too, before the stack blends below.
                    if stacked { tops = [SIMD4(colours[0].x, colours[0].y, colours[0].z, top.w)] + colours.flatMap { nudged(SIMD4($0.x, $0.y, $0.z, top.w)) } }
                }
                // What is below: as evaluated, and the corners of the range reached so far.
                var backdrops = [exact]
                if exact.w > 0 {
                    let alpha = Double(exact.w) * 255
                    for corner in 0..<8 {
                        var straight = F.straight(SIMD4(corner & 1 == 0 ? lo.x : hi.x, corner & 2 == 0 ? lo.y : hi.y, corner & 4 == 0 ? lo.z : hi.z, alpha))
                        straight.w = exact.w; backdrops.append(straight)
                    }
                }
                let mode = layer.blendMode ?? .normal
                let results = F.levels(backdrops.flatMap { below in tops.map { LWFloatBlend.pixel(mode, top: $0, bottom: below) } })
                exact = LWFloatBlend.pixel(mode, top: tops[0], bottom: exact)
                lo = results.reduce(results[0]) { pointwiseMin($0, $1) }; hi = results.reduce(results[0]) { pointwiseMax($0, $1) }
                index = next
            }
            return (lo, hi)
        }
        func render() -> [SIMD4<Float>] {
            let visible = layers.filter { $0.isGroup != true && $0.isVisible && ancestors($0).allSatisfy(\.isVisible) }
            return (0..<count).map { i in
                var output = SIMD4<Float>.zero, index = 0
                while index < visible.count {
                    let layer = visible[index]
                    var top = own(layer, i)
                    if let source = layer.maskSourceID.flatMap({ byID[$0] }) { top.w *= coverage(source, i) }
                    top.w *= ancestors(layer).reduce(1) { $0 * mask($1, i) } * drawnOpacity(layer)
                    var next = index + 1
                    if layer.maskSourceID == nil {
                        var colour = SIMD4(top.x, top.y, top.z, 1), stacked = false
                        while next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                            var child = own(visible[next], i); child.w *= drawnOpacity(visible[next])
                            colour = LWFloatBlend.pixel(visible[next].blendMode ?? .normal, top: child, bottom: colour)
                            next += 1; stacked = true
                        }
                        if stacked { top = SIMD4(colour.x, colour.y, colour.z, top.w) }
                    }
                    output = LWFloatBlend.pixel(layer.blendMode ?? .normal, top: top, bottom: output)
                    index = next
                }
                return output
            }
        }
    }

    /// Every blend mode on HDR, negative and partly transparent float layers: inside two nested, masked folders,
    /// as a clipping stack's base and clipped layer, and on layers taking a hidden layer's alpha, in a chain.
    @Test(arguments: LayerBlendMode.allCases)
    func hdrGraphMatchesThePerPixelReference(_ mode: LayerBlendMode) throws {
        let w = 40, h = 32, n = w * h
        let set = try LWFloatWorkingSet(limit: 256 * 1024 * 1024), workspace = try LWFloatWorkspace(workingSet: set)
        var layers: [ProjectLayerRecord] = [], images: [UUID: ImportedImage] = [:], pixels: [UUID: [SIMD4<Float>]] = [:]
        var masks: [UUID: ImportedImage] = [:], levels: [UUID: [Float]] = [:]
        func mask(_ record: inout ProjectLayerRecord, seed: Int) throws {
            let values = (0..<n).map { min(255, max(0, (($0 % w * 13 + $0 / w * 29 + seed * 71) % 300) - 20)) }
            record.maskFile = record.id.uuidString + ".mask.png"
            masks[record.id] = try F.mask(w, h) { x, y in values[y * w + x] }
            levels[record.id] = values.map { Float($0) / 255 }
        }
        func folder(_ name: String, parent: UUID? = nil, opacity: Double, maskSeed: Int? = nil) throws -> UUID {
            var record = F.folder(name, width: w, height: h, parent: parent, opacity: opacity)
            if let maskSeed { try mask(&record, seed: maskSeed) }
            layers.append(record); return record.id
        }
        func layer(_ name: String, seed: UInt64, parent: UUID? = nil, mode: LayerBlendMode = .normal, opacity: Double = 1, visible: Bool = true,
                   clip: UUID? = nil, maskSeed: Int? = nil) throws -> UUID {
            let (plane, surface) = try PrecisionFixture.plane(w, h, seed: seed, workspace: workspace)
            let asset = try ImportedImage(plane: plane, name: name)
            var record = F.raster(name, asset.image, parent: parent, mode: mode, opacity: opacity, visible: visible, clip: clip)
            if let maskSeed { try mask(&record, seed: maskSeed) }
            layers.append(record); images[record.id] = asset; pixels[record.id] = surface.pixels
            return record.id
        }
        _ = try layer("Backdrop", seed: 1)
        let outer = try folder("Outer", opacity: 0.9, maskSeed: 1)
        let inner = try folder("Inner", parent: outer, opacity: 0.85, maskSeed: 2)
        _ = try layer("Blended", seed: 2, parent: inner, mode: mode, opacity: 0.9, maskSeed: 3)
        let base = try layer("Stack base", seed: 3, parent: inner, mode: mode, opacity: 0.8)
        _ = try layer("Stack child", seed: 4, parent: inner, mode: mode, opacity: 0.8, clip: base)
        _ = try layer("Stack child, masked", seed: 5, parent: inner, opacity: 0.7, clip: base, maskSeed: 4)
        _ = try layer("Hidden in folder", seed: 6, parent: inner, visible: false)
        _ = try layer("Over the group", seed: 7, mode: mode, opacity: 0.6)
        let source = try layer("Hidden source", seed: 8, parent: outer, opacity: 0.6, visible: false, maskSeed: 5)
        let linked = try layer("Takes hidden alpha", seed: 9, mode: mode, clip: source)
        _ = try layer("Chained", seed: 10, mode: mode, opacity: 0.7, clip: linked)
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: w, height: h, activeLayerID: nil, layers: layers), images: images, masks: masks)
        let made = try F.float(snapshot, workingSet: set)
        let expected = Reference(layers: layers, pixels: pixels, masks: levels, count: n).render()
        // Alpha never depends on the mode: exact to float rounding everywhere.
        for i in 0..<n { #expect(abs(made[i].w - expected[i].w) <= 2e-6, "\(mode): alpha at \(i)") }
        // Colour: the compositor multiplies coverage factors in a different order from the reference, so alpha
        // differs in its last bit; a mode with a threshold may turn that into a different branch at a rare pixel.
        var off: [Int] = []
        for i in 0..<n {
            for c in 0..<3 {
                let e = Double(expected[i][c]), m = Double(made[i][c])
                if abs(m - e) / max(1, abs(e)) > 1e-4 { off.append(i); break }
            }
        }
        let allowed = Self.steepModes.contains(mode) ? n / 200 : 0
        let first = off.first.map { "\($0): \(made[$0]) vs \(expected[$0])" } ?? ""
        #expect(off.count <= allowed, "\(mode): \(off.count) pixels differ, first \(first)")
        // The fixture is HDR all the way through: the graph does not clamp.
        #expect(made.contains { $0.x > 1.5 || $0.y > 1.5 || $0.z > 1.5 })
    }
}
