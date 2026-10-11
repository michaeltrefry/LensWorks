import XCTest
@testable import Compositor

/// Concrete f32 fixtures for FloatRetouchTests. They use the evaluator's test entry point rather
/// than a live decoder: source RAW, UI, export, and product execution remain outside this candidate.
struct FloatRetouchFixture {
    let sourceID = UUID()
    let revision = UUID()

    func surface(width: Int, height: Int, pixels: [SIMD4<Float>] = []) throws -> LWLinearSurface {
        let values = pixels.isEmpty ? [SIMD4<Float>](repeating: .zero, count: width * height) : pixels
        return try LWLinearSurface(width: width, height: height, pixels: values,
                                   maximumBytes: LWSourceDeveloper.maximumResultBytes)
    }

    func map(width: Int, height: Int, geometry: [Double] = [1,0,0, 0,1,0, 0,0,1]) throws -> LWSourceSpatialMap {
        LWSourceSpatialMap(geometry: try LWSourceCoordinateMap(geometry), optics: CameraRawOpticsSettings(),
                           width: width, height: height)
    }

    func capturedFrame(width: Int, height: Int) throws -> LWSourceRetouchFrame {
        LWSourceRetouchFrame(geometry: .identity, optics: CameraRawOpticsSettings(), width: width, height: height,
                             layerTransform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)))
    }

    func node(width: Int, height: Int) throws -> LWLiveSourceNode {
        let revision = LWApplicationExportsDtoFileRevision(bytes: LWCatalogU64(4), digest: String(repeating: "0", count: 64),
            modified_ns: try LWCatalogU128(decimal: "0"), identity: .init(first: LWCatalogU64(1), second: LWCatalogU64(2)))
        let original = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: "/float-retouch-reference.dng"))
        let request = LWDocumentSourceDevelopment(original: original, originalRevision: revision, whiteBalance: .AsShot, requestID: UUID())
        let metadata = LWMediaMetadata(format: "FLOAT_REFERENCE", width: UInt32(width), height: UInt32(height), orientation: 1,
            camera_make: nil, camera_model: nil, captured_at: nil, lens: nil, preview_source: "fixture")
        let provenance = LWMediaFullRenderProvenance(pipeline_version: "fixture", decoder: "fixture-only", source_bits_per_channel: 32,
            source_color: "extended_linear_srgb", working_color: "linear_srgb", alpha: "straight", calibration: nil, spatial_calibration: nil, notes: ["No camera qualification"])
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: LWCatalogCodec.encode(value)) }
        let object: [String: Any] = ["source_revision": LWManagedAuthority.sourceRevision, "protocol": 2, "kind": "source_float",
            "mime": "application/x-lensworks-rgba-f32le", "width": width, "height": height, "row_stride": String(width * 16),
            "byte_length": String(width * height * 16), "channels": 4, "sample": "float32_le", "color_space": "linear_srgb",
            "alpha": "straight", "orientation": "applied", "metadata": try object(metadata), "provenance": try object(provenance),
            "source_authority": try object(request), "memory_enforcement": "fixture"]
        let descriptor = try LWCatalogCodec.decode(LWManagedSourceFloatDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
        return try LWLiveSourceNode(original: original, originalRevision: revision, descriptor: descriptor)
    }

    func foldedMap(width: Int, height: Int) throws -> LWSourceSpatialMap {
        try map(width: width, height: height, geometry: [0,0,0, 0,0,0, 0,0,1])
    }

    func liquifyStroke(width: Int, height: Int, dabs: [CGPoint], strength: Double) throws -> LWSourceRetouchStroke {
        guard let initial = dabs.first else { throw ProjectError.invalid }
        var value = try stroke(kind: .liquify, width: width, height: height, points: Array(dabs.dropFirst()), opacity: strength)
        value.sourceStart = initial
        return value
    }

    /// `WarpStroke.append` uses its first point only to pick up Smudge pixels.  The persisted
    /// dab sequence starts after it, so preserve that source distinction in every reference test.
    func smudgeStroke(width: Int, height: Int, dabs: [CGPoint], strength: Double = 1,
                      radius: Double = 1.5, hardness: Double = 1) throws -> LWSourceRetouchStroke {
        guard let initial = dabs.first else { throw ProjectError.invalid }
        var value = try stroke(kind: .smear, width: width, height: height,
                               points: Array(dabs.dropFirst()), opacity: strength,
                               radius: radius, hardness: hardness)
        value.sourceStart = initial
        return value
    }

    func stroke(kind: LWSourceRetouchStroke.Kind, width: Int, height: Int, points: [CGPoint],
                color: [Float] = [0,0,0,1], sourceOffset: CGSize = .zero, opacity: Double = 1,
                radius: Double = 1.5, hardness: Double = 1, blurRadius: Double = 1,
                healMode: LWSourceRetouchStroke.HealMode = .contentAware,
                sampleAll: Bool = false, selection: LWLinearSurface? = nil) throws -> LWSourceRetouchStroke {
        let selectionData = try selection.map { try $0.packageData(maximumFileBytes: LWSourceDeveloper.maximumResultBytes) }
        return LWSourceRetouchStroke(sourceID: sourceID, upstreamRevision: revision,
                                     captureFrame: try capturedFrame(width: width, height: height), kind: kind,
                                     seed: 0x1234, healMode: healMode, sampleAllLayers: sampleAll, aligned: true,
                                     sampleAllLayersCompositeRevision: sampleAll ? UUID() : nil, blurRadius: blurRadius,
                                     radius: radius, hardness: hardness, opacity: opacity, points: points,
                                     sourceOffset: sourceOffset, color: color, pointsAreDabs: true,
                                     selectionSourceCoverage: selectionData)
    }

    /// Direct reference controls still describe the encoded selection payload and retained replay
    /// count they pass to the evaluator. They do not substitute for the real plane/node admission
    /// used by tiled controls, but also cannot make a zero-backing admission claim while exercising
    /// an encoded selection or a sample-all stroke.
    func admittedFixture(_ surface: LWLinearSurface, strokes: [LWSourceRetouchStroke]) throws -> LWSourceRetouchAdmission {
        let selectionBytes = try strokes.reduce(into: 0) { total, stroke in
            let value = stroke.selectionSourceCoverage?.count ?? 0
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw ProjectError.tooLarge }
            total = next
        }
        let maximumDabs = try strokes.reduce(into: 0) { total, stroke in
            let value = try stroke.admittedReplayPointCount()
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw ProjectError.tooLarge }
            total = next
        }
        return .init(encodedBackingBytes: selectionBytes, selectionBytes: selectionBytes, compositeBytes: 0,
                     maximumDabs: maximumDabs, surfaceBytes: surface.byteLength, operationScratchBytes: 0)
    }

    func evaluate(_ strokes: [LWSourceRetouchStroke], surface: LWLinearSurface, map: LWSourceSpatialMap,
                  sampleAll: @escaping (LWSourceRetouchStroke, LWLinearSurface) throws -> LWLinearSurface = { _, upstream in upstream }) throws -> LWLinearSurface {
        try LWSourceRetouch.evaluateReference(strokes: strokes, sourceID: sourceID, developed: surface, map: map,
                                     admission: try admittedFixture(surface, strokes: strokes), sampleAll: sampleAll)
    }
}

extension FloatRetouchFixture {
    /// Tiled controls use the same private workspace and plane factory as the production graph.
    /// They do not turn this source-only candidate into a camera, export, or UI acceptance claim.
    func plane(_ surface: LWLinearSurface, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        // Do not round a float/HDR reference through CGImage: tiled controls require the same
        // straight f32 samples that the evaluator receives in production.
        let builder = try workspace.makeBuilder(width: surface.width, height: surface.height)
        while let range = builder.nextRange {
            var pixels = [SIMD4<Float>](repeating: .zero, count: range.width * range.height)
            for y in 0..<range.height { for x in 0..<range.width {
                pixels[y * range.width + x] = surface.pixels[(range.y + y) * surface.width + range.x + x]
            }}
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels,
                                               maximumBytes: range.width * range.height * 16), at: range)
        }
        return try builder.finish()
    }

    func nodeAndStroke(kind: LWSourceRetouchStroke.Kind, width: Int, height: Int,
                       points: [CGPoint], sourceStart: CGPoint? = nil,
                       color: [Float] = [0,0,0,1], opacity: Double = 1,
                       radius: Double = 1.5, hardness: Double = 1,
                       blurRadius: Double = 1, sourceOffset: CGSize = .zero,
                       healMode: LWSourceRetouchStroke.HealMode = .contentAware) throws -> (LWLiveSourceNode, LWSourceRetouchStroke) {
        var node = try self.node(width: width, height: height)
        let stroke = try self.stroke(for: node, kind: kind, width: width, height: height, points: points,
                                     sourceStart: sourceStart, color: color, opacity: opacity, radius: radius,
                                     hardness: hardness, blurRadius: blurRadius, sourceOffset: sourceOffset,
                                     healMode: healMode)
        node = try admitted(node) { $0.retouch = [stroke] }
        return (node, stroke)
    }

    func stroke(for node: LWLiveSourceNode, kind: LWSourceRetouchStroke.Kind, width: Int, height: Int,
                points: [CGPoint], sourceStart: CGPoint? = nil, color: [Float] = [0,0,0,1],
                opacity: Double = 1, radius: Double = 1.5, hardness: Double = 1,
                blurRadius: Double = 1, sourceOffset: CGSize = .zero,
                healMode: LWSourceRetouchStroke.HealMode = .contentAware,
                captureFrame: LWSourceRetouchFrame? = nil) throws -> LWSourceRetouchStroke {
        let captured: LWSourceRetouchFrame
        if let captureFrame { captured = captureFrame }
        else { captured = try self.capturedFrame(width: width, height: height) }
        var stroke = try LWSourceRetouchStroke(sourceID: node.id, upstreamRevision: node.revision,
            captureFrame: captured, kind: kind, seed: 0x1234,
            healMode: healMode, sampleAllLayers: false, aligned: true, sampleAllLayersCompositeRevision: nil,
            blurRadius: blurRadius, radius: radius, hardness: hardness, opacity: opacity, points: points,
            sourceOffset: sourceOffset, color: color)
        stroke.pointsAreDabs = true
        stroke.sourceStart = sourceStart
        return stroke
    }

    func node(width: Int, height: Int, retouch: [LWSourceRetouchStroke]) throws -> LWLiveSourceNode {
        try admitted(try node(width: width, height: height)) { $0.retouch = retouch }
    }

    /// Fixture graph mutations use the same retained-metadata reservation as the production
    /// command path. A positive tiled control must reach evaluator admission; it cannot bypass
    /// metadata ownership by assigning retouch/composite/plane collections directly.
    func admitted(_ node: LWLiveSourceNode,
                  mutate: (inout LWLiveSourceNode) throws -> Void) throws -> LWLiveSourceNode {
        var proposed = node
        try mutate(&proposed)
        let delta = max(0, proposed.retainedPayloadBytes - node.retainedPayloadBytes)
        var admitted = node
        try admitted.admitMetadataMutation(additionalBytes: delta)
        try mutate(&admitted)
        try admitted.validate()
        return admitted
    }

    func tiledEvaluate(_ node: LWLiveSourceNode, surface: LWLinearSurface,
                       map: LWSourceSpatialMap, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try LWSourceRetouch.evaluate(node, developed: plane(surface, workspace: workspace), map: map, workspace: workspace)
    }
}

extension FloatRetouchFixture {
    /// The public linear compatibility path accepts only caller-owned f32 storage. Fixtures use
    /// the same admitted factory so shared-budget and retained-result controls reach the bridge.
    func ownedSurface(_ surface: LWLinearSurface, workspace: LWFloatWorkspace) throws -> LWSourceOwnedLinearSurface {
        try LWLinearSurface.admitted(width: surface.width, height: surface.height,
                                    maximumBytes: surface.maximumBytes, workingSet: workspace.workingSet) { index in
            surface.pixels[index]
        }
    }

    func pixels(_ plane: LWFloatPlane) throws -> [SIMD4<Float>] {
        var result = [SIMD4<Float>](repeating: .zero, count: plane.width * plane.height)
        try plane.forEachTile { range in
            let tile = try plane.read(range)
            for y in 0..<range.height { for x in 0..<range.width {
                result[(range.y + y) * plane.width + range.x + x] = tile.surface.pixels[y * range.width + x]
            }}
        }
        return result
    }

    /// Independently constructs the retained captured developed grid for a Blur reference.
    /// It deliberately uses the public frame/current-map transforms rather than the retouch
    /// evaluator's private gather helper, so a scale/rotation mismatch is observable.
    func capturedDevelopedPlane(_ surface: LWLinearSurface, frame: LWSourceRetouchFrame,
                                map: LWSourceSpatialMap, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let input = try plane(surface, workspace: workspace), sampler = input.sampler(edge: .transparent)
        let builder = try workspace.makeBuilder(width: frame.developedWidth, height: frame.developedHeight)
        while let range = builder.nextRange {
            let bytes = try range.validate(frameWidth: frame.developedWidth, frameHeight: frame.developedHeight)
            let lease = try workspace.workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](repeating: .zero, count: range.width * range.height)
            for y in 0..<range.height { for x in 0..<range.width {
                let grid = CGPoint(x: CGFloat(range.x + x) + 0.5, y: CGFloat(range.y + y) + 0.5)
                let document = try frame.developedPixelToDocument(grid)
                if let source = try frame.sourcePointIfInBounds(document),
                   let current = try map.developedPointIfInBounds(source) {
                    pixels[y * range.width + x] = try sampler.sample(current, edge: .transparent)
                }
            }}
            try builder.append(try LWLinearSurface(width: range.width, height: range.height,
                pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }
}
