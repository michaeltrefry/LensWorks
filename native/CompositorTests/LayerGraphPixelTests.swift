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
        func snapshot(document: UUID = UUID()) -> ProjectSnapshot {
            ProjectSnapshot(manifest: ProjectManifest(documentID: document, width: width, height: height, activeLayerID: layers.last?.id, layers: layers),
                images: images.mapValues { F.asset($0) }, masks: masks)
        }
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
        default: throw ProjectError.invalid
        }
        return g
    }

    static let steepModes: Set<LayerBlendMode> = [.colorBurn, .colorDodge, .vividLight, .linearLight, .hardLight, .hardMix, .divide, .hue, .saturation, .color, .luminosity]

    private func compareWithRetained(_ graph: Graph, _ label: String, mode: LayerBlendMode = .normal) async throws {
        let snapshot = graph.snapshot()
        let retained = try F.levels(try await ImageExporter.shared.render(snapshot).image)
        let set = try LWFloatWorkingSet(limit: 256 * 1024 * 1024)
        let float = F.levels(try F.float(snapshot, workingSet: set))
        let (error, index) = F.worst(float, retained)
        // Modes with a threshold or a steep slope (and the hue and saturation transfers near grey) turn the
        // retained compositor's 8-bit rounding of the layers below into large differences at isolated pixels. A
        // difference in how the graph is composited moves whole regions instead.
        let outliers = float.indices.filter { i in let d = float[i] - retained[i]; return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) > Self.levelTolerance }.count
        let allowed = Self.steepModes.contains(mode) ? float.count * 4 / 100 : 0
        #expect(outliers <= allowed,
            "\(label): \(outliers) of \(float.count) pixels beyond \(Self.levelTolerance) levels; worst float \(float[index]) vs retained \(retained[index]) at (\(index % graph.width), \(index / graph.width)): \(error)")
    }

    @Test(arguments: ["nested-groups", "group-masks", "clipping", "flips"])
    func floatGraphMatchesTheRetainedCompositor(_ name: String) async throws {
        try await compareWithRetained(try Self.graph(name), name)
    }

    @Test(arguments: LayerBlendMode.allCases)
    func everyBlendModeThroughAGroupBoundaryMatchesTheRetainedCompositor(_ mode: LayerBlendMode) async throws {
        try await compareWithRetained(try Self.graph("blend-through-group", mode: mode), "\(mode)", mode: mode)
    }

    /// The same graphs spread over 3×2 tiles: tile evaluation equals the whole frame.
    @Test(arguments: ["nested-groups", "group-masks", "clipping", "flips", "blend-through-group"])
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
