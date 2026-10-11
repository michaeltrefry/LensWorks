import XCTest
@testable import Compositor

final class FloatRetouchTests: XCTestCase {
    func testCapturedDocumentCoverageSurvivesLaterNonuniformMap() throws {
        let f = FloatRetouchFixture()
        let input = try f.surface(width: 8, height: 8)
        let later = try f.map(width: 8, height: 8, geometry: [1.2,0,0, 0,0.8,0, 0,0,1])
        let stroke = try f.stroke(kind: .paint, width: 8, height: 8, points: [CGPoint(x: 2, y: 2)], color: [3,0,0,1])
        let output = try f.evaluate([stroke], surface: input, map: later)
        let hit = try later.developedPoint(CGPoint(x: 2, y: 2))
        XCTAssertGreaterThan(output.pixels[Int(hit.y) * 8 + Int(hit.x)].x, 1)
        XCTAssertEqual(input.pixels, [SIMD4<Float>](repeating: .zero, count: 64))
    }

    func testPaintAndBilinearCloneUsePremultipliedSourceOver() throws {
        let f = FloatRetouchFixture()
        let clear = try f.surface(width: 4, height: 4)
        let map = try f.map(width: 4, height: 4)
        let paint = try f.stroke(kind: .paint, width: 4, height: 4, points: [CGPoint(x: 1.5, y: 1.5)], color: [1,0,0,1], opacity: 0.5)
        let painted = try f.evaluate([paint], surface: clear, map: map)
        XCTAssertEqual(painted.pixels[1 * 4 + 1], SIMD4<Float>(1,0,0,0.5))
        var source = clear; source.pixels[0] = SIMD4<Float>(8,0,0,0); source.pixels[1] = SIMD4<Float>(0,0,0,1)
        let clone = try f.stroke(kind: .clone, width: 4, height: 4, points: [CGPoint(x: 2, y: 1)], sourceOffset: CGSize(width: -1.5, height: 0))
        let cloned = try f.evaluate([clone], surface: source, map: map)
        XCTAssertLessThanOrEqual(cloned.pixels[1 * 4 + 2].x, 1, "transparent hidden RGB must not contaminate a bilinear sample")
    }

    func testSampleAllReadsImmutableUpstreamAndSelectionOncePerOperation() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let upstream = try f.surface(width: 4, height: 4, pixels: [SIMD4<Float>](repeating: SIMD4<Float>(0,1,0,1), count: 16))
        let selection = try f.surface(width: 4, height: 4, pixels: [SIMD4<Float>](repeating: SIMD4<Float>(0,0,0,1), count: 16))
        let captured = try f.sampleAllNode(width: 4, height: 4, overlay: upstream, workspace: workspace)
        let template = try f.stroke(kind: .clone, width: 4, height: 4, points: [CGPoint(x: 2,y:2)], sourceOffset: .zero, sampleAll: true, selection: selection)
        let stroke = try f.rebound(template, to: captured.node, compositeRevision: captured.revision)
        let clear = try f.surface(width: 4, height: 4)
        let output = try f.evaluate([stroke], surface: clear, map: try f.map(width: 4, height: 4), node: captured.node, workspace: workspace)
        // The composite uses the document's encoded-sRGB blend; an opaque layer round-trips within float rounding.
        assertFloatClose(output.pixels[2 * 4 + 2], SIMD4<Float>(0,1,0,1),
                         "sample-all clones the captured upstream composite through the fully selected encoded coverage")
        XCTAssertEqual(output.pixels[0], .zero, "pixels outside the dab keep the immutable pre-stroke plane")
        XCTAssertEqual(clear.pixels, [SIMD4<Float>](repeating: .zero, count: 16))
    }

    func testSmudgeUsesPriorDabCarryAndEdgeCloneBlurAreAbsentNotFatal() throws {
        let f = FloatRetouchFixture()
        var input = try f.surface(width: 8, height: 4); input.pixels[1 * 8 + 1] = SIMD4<Float>(2,0,0,1)
        let map = try f.map(width: 8, height: 4)
        let smudge = try f.smudgeStroke(width: 8, height: 4, dabs: [CGPoint(x:1,y:1),CGPoint(x:5,y:1)])
        let edgeClone = try f.stroke(kind: .clone, width: 8, height: 4, points: [CGPoint(x:0,y:0)], sourceOffset: CGSize(width: -50,height:0))
        let edgeBlur = try f.stroke(kind: .blur, width: 8, height: 4, points: [CGPoint(x:0,y:0)], blurRadius: 50)
        let output = try f.evaluate([smudge, edgeClone, edgeBlur], surface: input, map: map)
        XCTAssertEqual(output.pixels[1 * 8 + 5], SIMD4<Float>(2, 0, 0, 1),
                       "the second hard dab must receive the immutable first pickup")
        XCTAssertEqual(output.pixels[1 * 8 + 1], SIMD4<Float>(2, 0, 0, 1))
    }

    func testScratchAdmissionRejectsBeforeWorkingArrays() throws {
        let f = FloatRetouchFixture()
        let input = try f.surface(width: 2, height: 2)
        var node = try f.node(width: 2, height: 2)
        let stroke = try f.rebound(try f.stroke(kind: .paint, width: 2, height: 2, points: [CGPoint(x:1,y:1)]), to: node)
        node = try f.admitted(node) { $0.retouch = [stroke] }
        let probe = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 1024 * 1024))
        let probePlane = try f.plane(input, workspace: probe)
        // Paint holds an input tile, an output tile and the selection/coverage tile: 3 RGBA tiles.
        let scratch = try LWSourceRetouch.tiledScratchBytes(node: node, plane: probePlane)
        XCTAssertEqual(scratch, 3 * 2 * 2 * MemoryLayout<SIMD4<Float>>.stride, "paint charges its tile scratch before allocation")
        let metadata = try XCTUnwrap(node.retouchAdmission(plane: probePlane, workspace: probe, operationScratchBytes: 0).lease).bytes
        let charged = try XCTUnwrap(node.retouchAdmission(plane: probePlane, workspace: probe, operationScratchBytes: scratch).lease).bytes
        XCTAssertEqual(charged, metadata + scratch, "the operation admission reserves the scratch with its metadata")
        withExtendedLifetime(probePlane) {}
        /// A budget holding the input plane plus `spare` bytes beyond the scratch-free admission charge.
        func evaluate(spare: Int) throws -> Result<LWFloatPlane, Error> {
            let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
            let plane = try f.plane(input, workspace: workspace)
            let filler = try workspace.workingSet.reserve(workspace.workingSet.limit - workspace.workingSet.retainedBytes - metadata - spare)
            defer { withExtendedLifetime(filler) {} }
            let generations = workspace.registeredGenerationCount
            let result = Result { try LWSourceRetouch.evaluate(node, developed: plane, map: try f.map(width: 2, height: 2), workspace: workspace) }
            if case .failure = result { XCTAssertEqual(workspace.registeredGenerationCount, generations, "a refused admission publishes no output plane") }
            return result
        }
        guard case .failure(let error) = try evaluate(spare: scratch - 1), case .tooLarge? = error as? ProjectError else {
            return XCTFail("one byte short of the paint scratch must refuse with tooLarge")
        }
        guard case .success = try evaluate(spare: scratch + 16 * 1024 * 1024) else { return XCTFail("a budget with the scratch admits the stroke") }
    }
}

extension FloatRetouchTests {
    func testR5OffCanvasCaptureFrameIsAbsentButFoldedMapRefuses() throws {
        let f = FloatRetouchFixture()
        let input = try f.surface(width: 8, height: 8)
        let nonuniform = try f.map(width: 8, height: 8, geometry: [1,0,0, 0,0.8,0, 0,0,1])
        let stroke = try f.stroke(kind: .paint, width: 8, height: 8, points: [CGPoint(x: 7.5, y: 7.5)])
        let edge = try f.evaluate([stroke], surface: input, map: nonuniform)
        // The map takes captured source y to developed 0.8y. Developed row 5 (centre 5.5) reads source
        // y 6.875, inside the frame and within the 1.5 px hard dab at columns 6 and 7. Rows 6 and 7 read
        // source y 8.125 and 9.375: outside the captured frame, so they are absent rather than clamped
        // onto the dab (a clamp would paint them).
        var expected = input.pixels
        expected[5 * 8 + 6] = SIMD4<Float>(0, 0, 0, 1); expected[5 * 8 + 7] = SIMD4<Float>(0, 0, 0, 1)
        XCTAssertEqual(edge.pixels, expected,
                       "a lawful captured-frame edge miss contributes no coverage or source sample")
        XCTAssertThrowsError(try f.evaluate([stroke], surface: input, map: try f.foldedMap(width: 8, height: 8)))
    }

    func testR5PremultipliedHiddenRGBBlurHealAndSmudgeControls() throws {
        let f = FloatRetouchFixture()
        var input = try f.surface(width: 4, height: 4)
        // Hidden RGB is adjacent to the actual destination sample, rather than an unobserved row.
        input.pixels[1 * 4 + 1] = SIMD4<Float>(8, 0, 0, 0)
        input.pixels[1 * 4 + 2] = SIMD4<Float>(0, 0, 1, 1)
        let blur = try f.stroke(kind: .blur, width: 4, height: 4, points: [CGPoint(x: 2, y: 1)], blurRadius: 50)
        let map = try f.map(width: 4, height: 4)
        let output = try f.evaluate([blur], surface: input, map: map)
        XCTAssertEqual(output.pixels[1 * 4 + 2].x, 0, accuracy: 0.0001)
        for mode in [LWSourceRetouchStroke.HealMode.contentAware, .createTexture, .proximityMatch] {
            let heal = try f.stroke(kind: .heal, width: 4, height: 4, points: [CGPoint(x: 2, y: 1)], healMode: mode)
            let first = try f.evaluate([heal], surface: input, map: map)
            let second = try f.evaluate([heal], surface: input, map: map)
            XCTAssertEqual(first.pixels, second.pixels, "mode-specific seeded Heal must be reproducible")
            XCTAssertTrue(first.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && (0...1).contains($0.w) },
                          "mode-specific Heal preserves f32 RGB and the one alpha storage invariant")
        }
        let smudge = try f.smudgeStroke(width: 4, height: 4, dabs: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 1)])
        let smudged = try f.evaluate([smudge], surface: input, map: map)
        XCTAssertEqual(smudged.pixels[1 * 4 + 2], SIMD4<Float>.zero,
                       "premultiplied carry must not propagate hidden RGB from a transparent pickup")
    }

    func testR5SampleAllUsesPreStrokeUpstreamAfterMutationAndSelectionZeroConserves() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let clear = try f.surface(width: 4, height: 4)
        let map = try f.map(width: 4, height: 4)
        let captured = try f.sampleAllNode(width: 4, height: 4, overlay: nil, workspace: workspace)
        let paint = try f.stroke(kind: .paint, width: 4, height: 4, points: [CGPoint(x: 1, y: 1)], color: [4,0,0,1])
        func clone(_ selection: LWLinearSurface) throws -> LWSourceRetouchStroke {
            try f.rebound(try f.stroke(kind: .clone, width: 4, height: 4, points: [CGPoint(x: 2, y: 1)], sourceOffset: CGSize(width: -1, height: 0),
                                       sampleAll: true, selection: selection), to: captured.node, compositeRevision: captured.revision)
        }
        let zero = try f.surface(width: 4, height: 4)
        let conserved = try f.evaluate([paint, try clone(zero)], surface: clear, map: map, node: captured.node, workspace: workspace)
        XCTAssertGreaterThan(conserved.pixels[1 * 4 + 1].x, 0)
        XCTAssertEqual(conserved.pixels[1 * 4 + 2], SIMD4<Float>.zero, "zero captured selection conserves the destination")
        let full = try f.surface(width: 4, height: 4, pixels: [SIMD4<Float>](repeating: SIMD4<Float>(0,0,0,1), count: 16))
        let sampled = try f.evaluate([paint, try clone(full)], surface: clear, map: map, node: captured.node, workspace: workspace)
        XCTAssertGreaterThan(sampled.pixels[1 * 4 + 2].x, 0,
                             "sample-all substitutes the immediately-prior plane, so the clone receives the completed paint stroke")
    }

    func testR5LiquifyRetainsOrderedPriorDabPushAndDoesNotRasterizeSource() throws {
        let f = FloatRetouchFixture()
        var input = try f.surface(width: 8, height: 8)
        input.pixels[3 * 8 + 2] = SIMD4<Float>(3, 0, 0, 1)
        let liquify = try f.liquifyStroke(width: 8, height: 8, dabs: [CGPoint(x: 2,y:3), CGPoint(x: 4,y:3)], strength: 1)
        let output = try f.evaluate([liquify], surface: input, map: try f.map(width: 8, height: 8))
        XCTAssertEqual(output.pixels[3 * 8 + 4], SIMD4<Float>(3, 0, 0, 1),
                       "the retained Push dab samples its immutable prior-dab surface behind motion")
        XCTAssertEqual(input.pixels[3 * 8 + 2], SIMD4<Float>(3, 0, 0, 1))
    }
}

extension FloatRetouchTests {
    func testR6RetainedHealModesPreservePremultipliedHDRAndSeedReference() throws {
        let f = FloatRetouchFixture()
        var input = try f.surface(width: 8, height: 8)
        input.pixels[3 * 8 + 3] = SIMD4<Float>(12, 4, 0, 0)
        input.pixels[3 * 8 + 4] = SIMD4<Float>(0, 2, 1, 1)
        let map = try f.map(width: 8, height: 8)
        for mode in [LWSourceRetouchStroke.HealMode.contentAware, .createTexture, .proximityMatch] {
            let stroke = try f.stroke(kind: .heal, width: 8, height: 8, points: [CGPoint(x: 3.5,y:3.5)], healMode: mode)
            let result = try f.evaluate([stroke], surface: input, map: map)
            XCTAssertLessThanOrEqual(result.pixels[3 * 8 + 4].x, 1, "premultiplied HealPixels reference must exclude transparent hidden RGB")
            XCTAssertEqual(try f.evaluate([stroke], surface: input, map: map).pixels, result.pixels, "seeded grain must be deterministic")
        }
    }

    func testR6BlurUsesRetainedScaleClampAndTransparentCompleteKernel() throws {
        let f = FloatRetouchFixture()
        var input = try f.surface(width: 1, height: 1)
        input.pixels[0] = SIMD4<Float>(4, 1, 0, 1)
        let blur = try f.stroke(kind: .blur, width: 1, height: 1, points: [CGPoint(x:0.5,y:0.5)], blurRadius: 50)
        let output = try f.evaluate([blur], surface: input, map: try f.map(width: 1, height: 1))
        XCTAssertTrue(output.pixels[0].x.isFinite && output.pixels[0].w.isFinite)
        XCTAssertGreaterThan(output.pixels[0].w, 0)
        XCTAssertLessThan(output.pixels[0].w, input.pixels[0].w,
                          "transparent out-of-bounds samples retain the complete Gaussian denominator")
    }

    func testR6SmudgeCarryAndLiquifyMatchPriorDabReferences() throws {
        let f = FloatRetouchFixture()
        var input = try f.surface(width: 8, height: 8)
        input.pixels[3 * 8 + 2] = SIMD4<Float>(2, 0, 0, 1)
        let map = try f.map(width: 8, height: 8, geometry: [1.25,0,0, 0,0.8,0, 0,0,1])
        let smudge = try f.smudgeStroke(width: 8, height: 8, dabs: [CGPoint(x:2,y:3), CGPoint(x:4,y:3)])
        let liquify = try f.liquifyStroke(width: 8, height: 8, dabs: [CGPoint(x:2,y:3), CGPoint(x:4,y:3)], strength: 1)
        // Developed (4,3) reads source (3.6, 4.375): retained cell (-1, +1) of the dab centred on (4,3).
        // Smudge lays down that cell's captured pickup, the developed sample at the current position of
        // source cell centre (1.5, 4.5) = (1.875, 3.6). That premultiplied bilinear sample takes
        // 0.375 x 0.9 of the red pixel at (2,3): straight HDR red with alpha 0.3375.
        let pickup = SIMD4<Float>(2, 0, 0, 0.375 * 0.9)
        let smudged = try f.evaluate([smudge], surface: input, map: map)
        assertFloatClose(smudged.pixels[3 * 8 + 4], pickup, "prior-dab pickup reference")
        // Liquify then pushes the same cell by the 2 px dab move, back to source (1.5, 4.5): the same
        // developed position, which Smudge left untouched (its cell (-2, +1) is outside the dab).
        let result = try f.evaluate([smudge, liquify], surface: input, map: map)
        assertFloatClose(result.pixels[3 * 8 + 4], pickup, "prior-dab Push reference")
    }

    func testR12LawfulTinyOwnedLinearSurfaceReachesPositiveEvaluatorPath() throws {
        let f = FloatRetouchFixture()
        var node = try f.node(width: 2, height: 2)
        let smallStroke = try f.stroke(for: node, kind: .smear, width: 2, height: 2,
                                       points: [CGPoint(x: 1,y:1)], sourceStart: CGPoint(x: 0.5, y: 1))
        node = try f.admitted(node) { $0.retouch = [smallStroke] }
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 4 * 1024 * 1024))
        let tiny = try f.ownedSurface(try LWLinearSurface(width: 2, height: 2,
            pixels: [SIMD4<Float>](repeating: .zero, count: 4), maximumBytes: 64), workspace: workspace)
        let output = try LWSourceRetouch.evaluate(node, developed: tiny,
            map: try f.map(width: 2, height: 2), workspace: workspace)
        XCTAssertTrue(output.workingSet === workspace.workingSet)
        XCTAssertEqual(output.maximumBytes, 64)
    }

    func testR13OwnedLinearAliasRetainsLeaseAndSuccessorPrechargesBeforeCallback() throws {
        // Ownership-only storage intentionally uses the working-set owner directly: a workspace
        // root lease is unrelated to the immutable surface alias/release boundary under test.
        let owner = try LWFloatWorkingSet(limit: 2 * 1024 * 1024)
        var escaped: Slice<LWSourceOwnedLinearSurface.Pixels>?
        var successor: LWSourceOwnedLinearSurface?
        do {
            let original = try LWLinearSurface.admitted(width: 256, height: 256,
                maximumBytes: 1024 * 1024, workingSet: owner) { index in
                    index == 0 ? SIMD4<Float>(2, 0, 0, 1) : .zero
                }
            escaped = original.pixels[0...]
            successor = try original.replacingPixels { index, pixel in
                index == 0 ? SIMD4<Float>(3, 0, 1, 1) : pixel
            }
            XCTAssertEqual(escaped?.first, SIMD4<Float>(2, 0, 0, 1))
            XCTAssertEqual(successor?.pixels[0], SIMD4<Float>(3, 0, 1, 1))
            XCTAssertEqual(original.pixels[0], SIMD4<Float>(2, 0, 0, 1),
                           "replacement is a separate owned allocation, never COW under the original lease")
        }
        var callbackRan = false
        XCTAssertThrowsError(try LWLinearSurface.admitted(width: 256, height: 256,
            maximumBytes: 1024 * 1024, workingSet: owner) { _ in
                callbackRan = true; return .zero
            }) { error in
                guard case ProjectError.tooLarge = error else { return XCTFail("expected pre-callback owner refusal, got \(error)") }
            }
        XCTAssertFalse(callbackRan, "the owner must refuse before a third buffer callback can allocate")
        XCTAssertEqual(escaped?.first, SIMD4<Float>(2, 0, 0, 1),
                       "the escaped slice remains a live owner after its surface leaves scope")
        escaped = nil
        let reclaimed = try successor!.replacingPixels { _, pixel in pixel }
        XCTAssertEqual(reclaimed.pixels[0], SIMD4<Float>(3, 0, 1, 1),
                       "once the only original alias releases, the exact shared charge is reusable")
        withExtendedLifetime(successor) {}
    }

    func testR12NodeLinearCompatibilityRetainsCallerBudgetInputAndOutputOwnership() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 16 * 1024 * 1024))
        let input = try f.ownedSurface(try f.surface(width: 8, height: 8,
            pixels: [SIMD4<Float>](repeating: SIMD4<Float>(2, 1, 0, 1), count: 64)), workspace: workspace)
        let (node, _) = try f.nodeAndStroke(kind: .paint, width: 8, height: 8,
                                            points: [CGPoint(x: 3.5, y: 3.5)], color: [4, 0, 1, 1])
        let output = try LWSourceRetouch.evaluate(node, developed: input,
            map: try f.map(width: 8, height: 8), workspace: workspace)
        XCTAssertTrue(input.workingSet === workspace.workingSet)
        XCTAssertTrue(output.workingSet === workspace.workingSet,
                      "the returned linear result retains its caller shared working-set lease")
        XCTAssertEqual(output.maximumBytes, input.maximumBytes,
                       "compatibility output preserves the caller result bound rather than substituting a new envelope")
        XCTAssertNotEqual(Array(output.pixels), Array(input.pixels))
    }

    func testR12NodeLinearCompatibilityRefusesSharedBudgetAndCancellationWithoutOutputPublication() throws {
        let f = FloatRetouchFixture()
        let constrained = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 8 * 1024 * 1024))
        let source = try f.surface(width: 256, height: 256)
        let input = try f.ownedSurface(source, workspace: constrained)
        let (node, _) = try f.nodeAndStroke(kind: .smear, width: 256, height: 256,
            points: [CGPoint(x: 128, y: 128)], sourceStart: CGPoint(x: 127, y: 128), radius: 128)
        XCTAssertThrowsError(try LWSourceRetouch.evaluate(node, developed: input,
            map: try f.map(width: 256, height: 256), workspace: constrained)) { error in
                guard case ProjectError.tooLarge = error else { return XCTFail("expected caller shared-budget refusal, got \(error)") }
            }

        let cancellable = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 16 * 1024 * 1024))
        let cancelledInput = try f.ownedSurface(try f.surface(width: 8, height: 8), workspace: cancellable)
        let (cancelNode, _) = try f.nodeAndStroke(kind: .paint, width: 8, height: 8,
                                                   points: [CGPoint(x: 3.5, y: 3.5)], color: [1, 0, 0, 1])
        let before = cancellable.registeredGenerationCount
        cancellable.cancellation.cancel()
        XCTAssertThrowsError(try LWSourceRetouch.evaluate(cancelNode, developed: cancelledInput,
            map: try f.map(width: 8, height: 8), workspace: cancellable)) { error in
                XCTAssertTrue(error is CancellationError)
            }
        XCTAssertEqual(cancellable.registeredGenerationCount, before,
                       "a cancelled node-linear bridge cannot publish a converted input or linear result")
    }
}

extension FloatRetouchTests {
    func testR7ErasePreservesHDRRGBAndReducesOnlyAlpha() throws {
        let f = FloatRetouchFixture(); let map = try f.map(width: 4, height: 4)
        let input = try f.surface(width: 4, height: 4, pixels: [SIMD4<Float>](repeating: SIMD4<Float>(4,2,1,1), count: 16))
        let erase = try f.stroke(kind: .erase, width: 4, height: 4, points: [CGPoint(x: 1.5,y:1.5)], opacity: 0.5)
        let output = try f.evaluate([erase], surface: input, map: map)
        XCTAssertEqual(output.pixels[1 * 4 + 1].x, 4, accuracy: 0.0001)
        XCTAssertEqual(output.pixels[1 * 4 + 1].w, 0.5, accuracy: 0.0001)
    }

    func testR7CapturedDevelopedBlurAndSmudgeReferencesUnderNonuniformGeometry() throws {
        let f = FloatRetouchFixture(); let map = try f.map(width: 8, height: 8, geometry: [1.2,0,0, 0,0.8,0, 0,0,1])
        var input = try f.surface(width: 8, height: 8); input.pixels[3 * 8 + 2] = SIMD4<Float>(2,0,0,1)
        let blur = try f.stroke(kind: .blur, width: 8, height: 8, points: [CGPoint(x: 3,y:3)], blurRadius: 2)
        let smudge = try f.smudgeStroke(width: 8, height: 8, dabs: [CGPoint(x:2,y:3),CGPoint(x:4,y:3)])
        let result = try f.evaluate([blur, smudge], surface: input, map: map)
        XCTAssertGreaterThan(result.pixels[3 * 8 + 3].w, 0, "captured-developed reference must survive nonuniform replay")
    }
}

extension FloatRetouchTests {
    func testR13RetainedIntegerCellSoftWeightAndPartialOpacityReferences() throws {
        func retainedWeight(dx: Int, dy: Int, radius: Double, hardness: Double) -> Float {
            let u = hypot(Double(dx), Double(dy)) / radius
            guard u < 1 else { return 0 }
            let h = min(0.98, max(0, hardness))
            guard u > h else { return 1 }
            let t = (1 - u) / (1 - h)
            return Float(t * t * (3 - 2 * t))
        }
        XCTAssertEqual(retainedWeight(dx: 0, dy: 0, radius: 3, hardness: 0.2), 1,
                       "the retained center weight is integer-cell exact, independent of +0.5 sampling")
        let edge = retainedWeight(dx: 2, dy: 0, radius: 3, hardness: 0.2)
        XCTAssertGreaterThan(edge, 0); XCTAssertLessThan(edge, 1)
        XCTAssertEqual(retainedWeight(dx: 3, dy: 0, radius: 3, hardness: 0.2), 0)

        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        // Center and soft-edge cells each receive a real captured pickup. The expected output
        // below is straight storage after the carry's premultiplied opacity blend.
        input.pixels[128 * 257 + 126] = SIMD4<Float>(4, 1, 0, 1)
        input.pixels[128 * 257 + 128] = SIMD4<Float>(4, 1, 0, 1)
        var node = try f.node(width: 257, height: 257)
        let stroke = try f.stroke(for: node, kind: .smear, width: 257, height: 257,
                                  points: [CGPoint(x: 129, y: 128)], sourceStart: CGPoint(x: 126, y: 128),
                                  opacity: 0.5, radius: 3, hardness: 0.2)
        node = try f.admitted(node) { $0.retouch = [stroke] }
        let smudged = try f.pixels(try f.tiledEvaluate(node, surface: input,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertEqual(smudged[128 * 257 + 129], SIMD4<Float>(4, 1, 0, 0.5),
                       "the center stores straight HDR RGB with the retained partial alpha")
        XCTAssertEqual(smudged[128 * 257 + 131], SIMD4<Float>(4, 1, 0, edge * 0.5),
                       "the production soft-edge cell uses the independently derived retained integer weight")
        XCTAssertEqual(smudged[128 * 257 + 132], SIMD4<Float>.zero,
                       "the retained integer rim has zero coverage and cannot publish carry")

        let (liquifyNode, _) = try f.nodeAndStroke(kind: .liquify, width: 257, height: 257,
            points: [CGPoint(x: 129, y: 128)], sourceStart: CGPoint(x: 126, y: 128),
            opacity: 1, radius: 3, hardness: 0.2)
        let liquified = try f.pixels(try f.tiledEvaluate(liquifyNode, surface: input,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertEqual(liquified[128 * 257 + 129], SIMD4<Float>(4, 1, 0, 1),
                       "the integer-cell center uses the +0.5 pickup sample while the retained center weight stays one")
        XCTAssertEqual(liquified[128 * 257 + 132], SIMD4<Float>.zero,
                       "the Liquify rim derives its zero displacement from the same retained integer-cell formula")

        let gradientPixels = (0..<(257 * 257)).map { index in SIMD4<Float>(Float(index % 257), 0, 0, 1) }
        let gradient = try f.surface(width: 257, height: 257, pixels: gradientPixels)
        let fractional = try f.pixels(try f.tiledEvaluate(liquifyNode, surface: gradient,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        let displacement = 3.0 * Double(edge)
        let expectedFractional = Float((131.5 - displacement) - 0.5)
        let softEdge = fractional[128 * 257 + 131]
        XCTAssertEqual(softEdge.x, expectedFractional, accuracy: 0.0001,
                       "Liquify's soft edge uses the retained fractional integer-cell weight in its prior-dab bilinear displacement")
        XCTAssertEqual(softEdge.y, 0, accuracy: 0.0001)
        XCTAssertEqual(softEdge.z, 0, accuracy: 0.0001)
        XCTAssertEqual(softEdge.w, 1, accuracy: 0.0001)
    }

    func testR8TiledModesUseImmutablePriorPlaneAndGlobalCoordinates() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 127] = SIMD4<Float>(2, 0, 0, 1)
        let map = try f.map(width: 257, height: 257, geometry: [1.25,0,0, 0,0.8,0, 0,0,1])
        let cases: [(LWSourceRetouchStroke.Kind, [CGPoint], CGPoint?, [Float])] = [
            (.paint, [CGPoint(x: 128, y: 128)], nil, [3,0,0,1]),
            (.erase, [CGPoint(x: 128, y: 128)], nil, [0,0,0,1]),
            (.clone, [CGPoint(x: 128, y: 128)], nil, [0,0,0,1]),
            (.heal, [CGPoint(x: 128, y: 128)], nil, [0,0,0,1]),
            (.blur, [CGPoint(x: 128, y: 128)], nil, [0,0,0,1]),
            (.smear, [CGPoint(x: 127, y: 128)], CGPoint(x: 126, y: 128), [0,0,0,1]),
            (.liquify, [CGPoint(x: 129, y: 128)], CGPoint(x: 127, y: 128), [0,0,0,1])
        ]
        for (kind, points, start, color) in cases {
            let (node, _) = try f.nodeAndStroke(kind: kind, width: 257, height: 257, points: points,
                sourceStart: start, color: color, radius: 4, blurRadius: 2,
                sourceOffset: kind == .clone ? CGSize(width: -1, height: 0) : .zero)
            let result = try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace)
            XCTAssertEqual(result.width, 257); XCTAssertEqual(result.height, 257)
            XCTAssertEqual(input.pixels[128 * 257 + 127], SIMD4<Float>(2,0,0,1), "input plane remains immutable")
        }
    }

    func testR9TiledAdmissionRefusesAfterLawfulInputAndCancellationPublishesNothing() throws {
        let f = FloatRetouchFixture()
        // A legal 256² tile plus its builder/root metadata is built before the operation is
        // admitted. Eight MiB stays inside the unchanged result cap, but is below the aggregate
        // typed carry/cache plan for a radius-128 Smudge operation.
        let constrained = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 8 * 1024 * 1024))
        let input = try f.surface(width: 256, height: 256)
        let (node, _) = try f.nodeAndStroke(kind: .smear, width: 256, height: 256,
            points: [CGPoint(x: 128, y: 128)], sourceStart: CGPoint(x: 127, y: 128), radius: 128)
        let admittedInput = try f.plane(input, workspace: constrained)
        let registeredBeforeRefusal = constrained.registeredGenerationCount
        XCTAssertThrowsError(try LWSourceRetouch.evaluate(node, developed: admittedInput,
            map: try f.map(width: 256, height: 256), workspace: constrained)) { error in
                guard case ProjectError.tooLarge = error else {
                    return XCTFail("the lawful input must reach the exact aggregate scratch refusal, got \(error)")
                }
            }
        XCTAssertEqual(constrained.registeredGenerationCount, registeredBeforeRefusal,
                       "a rejected admission cannot publish a new plane or registered generation")

        let cancelled = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let cancellableInput = try f.plane(input, workspace: cancelled)
        let registeredBeforeCancel = cancelled.registeredGenerationCount
        cancelled.cancellation.cancel()
        XCTAssertThrowsError(try LWSourceRetouch.evaluate(node, developed: cancellableInput,
            map: try f.map(width: 256, height: 256), workspace: cancelled)) { error in
                XCTAssertTrue(error is CancellationError,
                              "the lawful input must reach the cancellation check, not an unrelated construction failure")
            }
        XCTAssertEqual(cancelled.registeredGenerationCount, registeredBeforeCancel,
                       "cancellation before evaluator traversal cannot publish a builder or plane")
    }

    func testR8TiledReferenceControlsRetainPremultipliedEdgesAndPriorDabState() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 127] = SIMD4<Float>(6, 0, 0, 0) // hidden RGB must remain invisible.
        input.pixels[128 * 257 + 128] = SIMD4<Float>(0, 0, 2, 1)
        let map = try f.map(width: 257, height: 257)
        let (blurNode, _) = try f.nodeAndStroke(kind: .blur, width: 257, height: 257,
            points: [CGPoint(x: 128, y: 128)], radius: 3, blurRadius: 2)
        let blurred = try f.tiledEvaluate(blurNode, surface: input, map: map, workspace: workspace)
        let tile = try blurred.read(LWFloatRange(x: 0, y: 0, width: 256, height: 256))
        XCTAssertEqual(tile.surface.pixels[128 * 256 + 128].x, 0, accuracy: 0.0001,
                       "premultiplied tile halo sampling excludes transparent hidden RGB")

        var smudgeInput = try f.surface(width: 257, height: 257)
        smudgeInput.pixels[128 * 257 + 126] = SIMD4<Float>(2,0,0,1)
        let (smudgeNode, _) = try f.nodeAndStroke(kind: .smear, width: 257, height: 257,
            points: [CGPoint(x: 129, y: 128)], sourceStart: CGPoint(x: 126, y: 128), radius: 3)
        let smudged = try f.tiledEvaluate(smudgeNode, surface: smudgeInput, map: map, workspace: workspace)
        let result = try smudged.read(LWFloatRange(x: 0, y: 0, width: 256, height: 256))
        XCTAssertGreaterThan(result.surface.pixels[128 * 256 + 129].x, 0,
                             "the second dab reads the immutable global first pickup across a tile seam")
    }

    func testR8TiledSmudgeCarriesOneBoundedGenerationAcrossRecordedDabs() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 120] = SIMD4<Float>(4, 0, 0, 1)
        var node = try f.node(width: 257, height: 257)
        let dabs = (120...136).map { CGPoint(x: CGFloat($0), y: 128) }
        let stroke = try f.stroke(for: node, kind: .smear, width: 257, height: 257,
                                  points: Array(dabs.dropFirst()), sourceStart: dabs.first,
                                  radius: 2, hardness: 1)
        node = try f.admitted(node) { $0.retouch = [stroke] }
        let output = try f.pixels(try f.tiledEvaluate(node, surface: input,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertGreaterThan(output[128 * 257 + 136].x, 0,
                             "ordered pickup/next carry must reach the final retained dab without a per-dab global state allocation")
        XCTAssertEqual(input.pixels[128 * 257 + 120], SIMD4<Float>(4, 0, 0, 1),
                       "the immutable source plane remains unchanged through every carry generation")
    }
}

extension FloatRetouchTests {
    func testR8TiledPaintEraseAndCloneHaveReferencePixels() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let map = try f.map(width: 8, height: 8)
        let clear = try f.surface(width: 8, height: 8)
        let (paintNode, _) = try f.nodeAndStroke(kind: .paint, width: 8, height: 8,
            points: [CGPoint(x: 3.5, y: 3.5)], color: [3,1,0,1], opacity: 0.5)
        let painted = try f.pixels(try f.tiledEvaluate(paintNode, surface: clear, map: map, workspace: workspace))
        XCTAssertEqual(painted[3 * 8 + 3], SIMD4<Float>(3,1,0,0.5), "source-over retains HDR RGB and straight alpha")

        var source = clear; source.pixels[3 * 8 + 2] = SIMD4<Float>(2,0,1,1)
        let (cloneNode, _) = try f.nodeAndStroke(kind: .clone, width: 8, height: 8,
            points: [CGPoint(x: 3.5, y: 3.5)], sourceOffset: CGSize(width: -1, height: 0))
        let cloned = try f.pixels(try f.tiledEvaluate(cloneNode, surface: source, map: map, workspace: workspace))
        XCTAssertEqual(cloned[3 * 8 + 3], SIMD4<Float>(2,0,1,1), "clone samples the immutable immediately-prior plane")

        let (eraseNode, _) = try f.nodeAndStroke(kind: .erase, width: 8, height: 8,
            points: [CGPoint(x: 3.5, y: 3.5)], opacity: 0.5)
        let erased = try f.pixels(try f.tiledEvaluate(eraseNode, surface: clonedAsSurface(cloned, width: 8), map: map, workspace: workspace))
        XCTAssertEqual(erased[3 * 8 + 3], SIMD4<Float>(2,0,1,0.5), "erase changes alpha without clipping HDR RGB")
    }

    func testR8TiledHealModesAndLiquifyUseDeterministicGlobalReferences() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        // A covered outlier gives every retained mode a discriminating membrane repair target;
        // the neighboring source marker makes source-patch modes exercise real patch search.
        input.pixels[128 * 257 + 126] = SIMD4<Float>(2,1,0,1)
        input.pixels[128 * 257 + 128] = SIMD4<Float>(9,0,0,1)
        let map = try f.map(width: 257, height: 257)
        for mode in [LWSourceRetouchStroke.HealMode.contentAware, .createTexture, .proximityMatch] {
            let (node, _) = try f.nodeAndStroke(kind: .heal, width: 257, height: 257,
                points: [CGPoint(x: 128, y: 128)], radius: 3, healMode: mode)
            let first = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
            let second = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
            XCTAssertEqual(first, second, "seeded \(mode) replay is independent of tile residency")
            XCTAssertTrue(first.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && (0...1).contains($0.w) })
            XCTAssertNotEqual(first[128 * 257 + 128], input.pixels[128 * 257 + 128],
                              "\(mode) applies its retained HealPixels membrane at covered source coordinates")
        }

        let (liquifyNode, _) = try f.nodeAndStroke(kind: .liquify, width: 257, height: 257,
            points: [CGPoint(x: 130, y: 128)], sourceStart: CGPoint(x: 126, y: 128), opacity: 1, radius: 4)
        let pushed = try f.pixels(try f.tiledEvaluate(liquifyNode, surface: input, map: map, workspace: workspace))
        XCTAssertEqual(pushed[128 * 257 + 130], SIMD4<Float>(2,1,0,1),
                       "WarpStroke push uses the clamped immutable prior-dab pickup without a second blend")
    }

    private func clonedAsSurface(_ pixels: [SIMD4<Float>], width: Int) throws -> LWLinearSurface {
        try LWLinearSurface(width: width, height: pixels.count / width, pixels: pixels,
                            maximumBytes: LWSourceDeveloper.maximumResultBytes)
    }
}

extension FloatRetouchTests {
    func testR8TiledMultistrokeCloneReadsCompletedPriorStrokeOnly() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let blank = try f.surface(width: 257, height: 257)
        var seed = try f.node(width: 257, height: 257)
        let paint = try f.stroke(for: seed, kind: .paint, width: 257, height: 257,
                                 points: [CGPoint(x: 128, y: 128)], color: [5,0,1,1], radius: 2)
        let clone = try f.stroke(for: seed, kind: .clone, width: 257, height: 257,
                                 points: [CGPoint(x: 129, y: 128)], radius: 2, sourceOffset: CGSize(width: -1, height: 0))
        seed = try f.admitted(seed) { $0.retouch = [paint, clone] }
        let result = try f.pixels(try f.tiledEvaluate(seed, surface: blank, map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertEqual(result[128 * 257 + 128], SIMD4<Float>(5,0,1,1))
        XCTAssertEqual(result[128 * 257 + 129], SIMD4<Float>(5,0,1,1),
                       "clone receives the completed first stroke plane, not its own output or the original plane")
    }

    func testR8TiledCapturedEdgeRulesDistinguishAbsentAndClampedSamples() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var source = try f.surface(width: 257, height: 257)
        source.pixels[0] = SIMD4<Float>(4,0,0,1)
        let map = try f.map(width: 257, height: 257, geometry: [1.2,0,0, 0,0.8,0, 0,0,1])
        let (cloneNode, _) = try f.nodeAndStroke(kind: .clone, width: 257, height: 257,
            points: [CGPoint(x: 0.5, y: 0.5)], radius: 2, sourceOffset: CGSize(width: -10_000, height: 0))
        let clone = try f.pixels(try f.tiledEvaluate(cloneNode, surface: source, map: map, workspace: workspace))
        XCTAssertEqual(clone[0], source.pixels[0], "ordinary capture-frame extent misses are absent, not errors or clamped clones")

        // A 2.5 px push at the left edge picks up from x = -2 in the captured frame. WarpStroke clamps
        // that lawful edge pickup to the first captured pixel centre instead of refusing or reading
        // transparency. Under the identity map that centre is exactly developed pixel 0.
        let (liquifyNode, _) = try f.nodeAndStroke(kind: .liquify, width: 257, height: 257,
            points: [CGPoint(x: 3, y: 0.5)], sourceStart: CGPoint(x: 0.5, y: 0.5), radius: 4)
        let pushed = try f.pixels(try f.tiledEvaluate(liquifyNode, surface: source, map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertEqual(pushed[0], SIMD4<Float>(4,0,0,1), "WarpStroke uses captured-frame clamping only for lawful edge pickup")
        // Under the 1.2x/0.8x map the clamped captured centre (0.5, 0.5) lies at developed (0.6, 0.4):
        // a premultiplied bilinear sample that takes 10% of the transparent neighbour.
        let scaled = try f.pixels(try f.tiledEvaluate(liquifyNode, surface: source, map: map, workspace: workspace))
        for (channel, expected) in [Float(4), 0, 0, 0.9].enumerated() {
            XCTAssertEqual(scaled[0][channel], expected, accuracy: 1e-5, "the clamped pickup is resampled through the current map")
        }
        XCTAssertThrowsError(try f.tiledEvaluate(liquifyNode, surface: source,
            map: try f.foldedMap(width: 257, height: 257), workspace: workspace),
            "folded optics/geometry remain refusals rather than regular edge samples")
    }
}

extension FloatRetouchTests {
    func testR9TiledSmudgeAppliesFractionalCapturedSelectionAtPublication() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 126] = SIMD4<Float>(4, 1, 0, 1)
        let selectionSurface = try f.surface(width: 257, height: 257,
            pixels: [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0.25), count: 257 * 257))
        let selectionPlane = try f.plane(selectionSurface, workspace: workspace)
        var node = try f.node(width: 257, height: 257)
        var stroke = try f.stroke(for: node, kind: .smear, width: 257, height: 257,
                                  points: [CGPoint(x: 129, y: 128)], sourceStart: CGPoint(x: 126, y: 128), radius: 3)
        let selectionID = UUID()
        stroke.selectionPlaneID = selectionID
        let asset = try LWSourcePlaneAsset(selectionPlane)
        node = try f.admitted(node) { value in
            value.planeAssets[selectionID] = asset
            value.retouch = [stroke]
        }
        let output = try f.pixels(try f.tiledEvaluate(node, surface: input,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertEqual(output[128 * 257 + 129], SIMD4<Float>(4, 1, 0, 0.25),
                       "a fractional captured selection blends the carried HDR/alpha sample once at publication")
    }

    func testR9TiledBlurUsesRetainedCoreImageOperatorAtCapturedGridCoordinates() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 127] = SIMD4<Float>(3, 0, 1, 1)
        let map = try f.map(width: 257, height: 257)
        let original = try f.plane(input, workspace: workspace)
        // This is an independently assembled retained Core Image reference, not a copy of the
        // retouch implementation's previous truncated exp-kernel formula.
        let reference = try LWFloatCoreImage.render(original, makeBuilder: { width, height in
            try workspace.makeBuilder(width: width, height: height)
        }, cancellation: workspace.cancellation) { image in
            image.applyingGaussianBlur(sigma: 2)
        }
        let referencePixels = try f.pixels(reference)
        let (node, _) = try f.nodeAndStroke(kind: .blur, width: 257, height: 257,
                                            points: [CGPoint(x: 128, y: 128)], radius: 4, blurRadius: 2)
        let output = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
        XCTAssertEqual(output[128 * 257 + 128], referencePixels[128 * 257 + 128],
                       "full captured coverage publishes the retained CI Gaussian sample, including its transparent ROI boundary")
    }

    func testR10TiledBlurMatchesRetainedGaussianAtActualSeamBorderAndTinyDestinations() throws {
        let f = FloatRetouchFixture()
        func expected(_ input: LWLinearSurface, _ point: CGPoint, radius: Double) throws -> SIMD4<Float> {
            let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
            let plane = try f.plane(input, workspace: workspace)
            let reference = try LWFloatCoreImage.render(plane, makeBuilder: { width, height in
                try workspace.makeBuilder(width: width, height: height)
            }, cancellation: workspace.cancellation) { image in image.applyingGaussianBlur(sigma: radius) }
            return try reference.sampler(edge: .transparent).sample(point, edge: .transparent)
        }

        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var seamInput = try f.surface(width: 257, height: 257)
        seamInput.pixels[128 * 257 + 255] = SIMD4<Float>(4, 0, 1, 1)
        let seamPoint = CGPoint(x: 256.5, y: 128.5)
        let (seamNode, _) = try f.nodeAndStroke(kind: .blur, width: 257, height: 257,
                                                 points: [seamPoint], radius: 4, blurRadius: 2)
        let seam = try f.pixels(try f.tiledEvaluate(seamNode, surface: seamInput,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        assertFloatClose(seam[128 * 257 + 256], try expected(seamInput, seamPoint, radius: 2),
                       "the affected destination across the real 256 seam gathers the retained full-coordinate Gaussian")

        var borderInput = try f.surface(width: 257, height: 257)
        borderInput.pixels[0] = SIMD4<Float>(2, 1, 0, 1)
        let borderPoint = CGPoint(x: 0.5, y: 0.5)
        let (borderNode, _) = try f.nodeAndStroke(kind: .blur, width: 257, height: 257,
                                                   points: [borderPoint], radius: 4, blurRadius: 2)
        let border = try f.pixels(try f.tiledEvaluate(borderNode, surface: borderInput,
            map: try f.map(width: 257, height: 257), workspace: workspace))
        assertFloatClose(border[0], try expected(borderInput, borderPoint, radius: 2),
                       "the transparent captured boundary is compared at a genuinely affected border destination")

        var tiny = try f.surface(width: 2, height: 2)
        tiny.pixels[0] = SIMD4<Float>(6, 0, 0, 1)
        let (tinyNode, _) = try f.nodeAndStroke(kind: .blur, width: 2, height: 2,
                                                 points: [CGPoint(x: 0.5, y: 0.5)], radius: 1, blurRadius: 0.5)
        let tinyOutput = try f.pixels(try f.tiledEvaluate(tinyNode, surface: tiny,
            map: try f.map(width: 2, height: 2), workspace: workspace))
        assertFloatClose(tinyOutput[0], try expected(tiny, CGPoint(x: 0.5, y: 0.5), radius: 0.5),
                       "the retained operator, rather than a truncated kernel, defines tiny-extent output")
    }

    func testR8TiledSelectionPlaneIsDecodedOnceAndZeroCoverageConservesInput() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let input = try f.surface(width: 257, height: 257)
        var node = try f.node(width: 257, height: 257)
        var stroke = try f.stroke(for: node, kind: .paint, width: 257, height: 257,
                                  points: [CGPoint(x: 128, y: 128)], color: [7,0,0,1], radius: 4)
        let zero = try f.plane(input, workspace: workspace)
        let selectionID = UUID()
        stroke.selectionPlaneID = selectionID
        let selectionAsset = try LWSourcePlaneAsset(zero)
        node = try f.admitted(node) { value in
            value.planeAssets[selectionID] = selectionAsset
            value.retouch = [stroke]
        }
        let output = try f.pixels(try f.tiledEvaluate(node, surface: input, map: try f.map(width: 257, height: 257), workspace: workspace))
        XCTAssertEqual(output, input.pixels, "the real plane-backed zero selection prevents any paint publication")
    }
}

extension FloatRetouchTests {
    func testR8TiledBlurAndSmudgeUseCapturedLayerGridWithTranslatedFrame() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var placement = LayerTransform(origin: CGPoint(x: 19, y: 11), size: CGSize(width: 128.5, height: 96.25))
        placement.rotation = 17
        let frame = LWSourceRetouchFrame(geometry: .identity, optics: CameraRawOpticsSettings(), width: 257, height: 257,
            layerTransform: placement)
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 127] = SIMD4<Float>(2,0,0,1)
        let map = try f.map(width: 257, height: 257, geometry: [1.2,0,0, 0,0.8,0, 0,0,1])
        var node = try f.node(width: 257, height: 257)
        // Pick the actual current destination first. Its source/document/grid chain supplies both
        // the stroke center and the independently gathered retained-Gaussian comparison point.
        let destination = CGPoint(x: 128.5, y: 128.5)
        guard let sourcePoint = try map.sourcePointIfInBounds(destination) else { throw ProjectError.invalid }
        let documentPoint = try frame.documentPoint(sourcePoint)
        let blur = try f.stroke(for: node, kind: .blur, width: 257, height: 257,
                                 points: [documentPoint], radius: 4, blurRadius: 2, captureFrame: frame)
        // Select actual captured raster cells first, then derive document points through the
        // public transformed frame. These remain in-bounds under scale, rotation and placement.
        let smudgeCapturedStart = CGPoint(x: 100.5, y: 100.5)
        let smudgeCapturedDab = CGPoint(x: 104.5, y: 100.5)
        let smudgeStartDocument = try frame.developedPixelToDocument(smudgeCapturedStart)
        let smudgeDabDocument = try frame.developedPixelToDocument(smudgeCapturedDab)
        guard let selectedSource = try frame.sourcePointIfInBounds(smudgeDabDocument),
              let selectedCurrentRaw = try map.developedPointIfInBounds(selectedSource) else { throw ProjectError.invalid }
        // Select the actual output pixel centre, then derive its retained document-cell offset
        // and the initial pickup cell. Only after that chain is complete do we mark the four
        // bilinear source samples that the sampler really reads.
        let selectedCurrent = CGPoint(x: CGFloat(Int(floor(selectedCurrentRaw.x))) + 0.5,
                                      y: CGFloat(Int(floor(selectedCurrentRaw.y))) + 0.5)
        guard let selectedCurrentSource = try map.sourcePointIfInBounds(selectedCurrent),
              let selectedDocument = try frame.documentPointIfInBounds(selectedCurrentSource) else { throw ProjectError.invalid }
        let dabCentre = CGPoint(x: smudgeDabDocument.x.rounded(), y: smudgeDabDocument.y.rounded())
        let startCentre = CGPoint(x: smudgeStartDocument.x.rounded(), y: smudgeStartDocument.y.rounded())
        let dx = Int(floor(selectedDocument.x)) - Int(dabCentre.x)
        let dy = Int(floor(selectedDocument.y)) - Int(dabCentre.y)
        let pickupDocument = CGPoint(x: startCentre.x + CGFloat(dx) + 0.5,
                                     y: startCentre.y + CGFloat(dy) + 0.5)
        guard let pickupSource = try frame.sourcePointIfInBounds(pickupDocument),
              let pickupCurrent = try map.developedPointIfInBounds(pickupSource) else { throw ProjectError.invalid }
        let supportX = Int(floor(pickupCurrent.x - 0.5)), supportY = Int(floor(pickupCurrent.y - 0.5))
        for y in supportY...(supportY + 1) { for x in supportX...(supportX + 1) {
            guard x >= 0, y >= 0, x < 257, y < 257 else { throw ProjectError.invalid }
            input.pixels[y * 257 + x] = SIMD4<Float>(3,1,0,1)
        }}
        let smudge = try f.stroke(for: node, kind: .smear, width: 257, height: 257,
                                   points: [smudgeDabDocument],
                                   sourceStart: smudgeStartDocument,
                                   radius: 4, captureFrame: frame)
        node = try f.admitted(node) { $0.retouch = [blur] }
        let blurredOutput = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
        let captured = try f.capturedDevelopedPlane(input, frame: frame, map: map, workspace: workspace)
        let sigma = try frame.retainedBlurSigma(blurRadius: 2)
        let reference = try LWFloatCoreImage.render(captured, makeBuilder: { width, height in
            try workspace.makeBuilder(width: width, height: height)
        }, cancellation: workspace.cancellation) { image in image.applyingGaussianBlur(sigma: sigma) }
        let grid = try frame.documentToDevelopedPixel(documentPoint)
        let expected = try reference.sampler(edge: .transparent).sample(grid, edge: .transparent)
        XCTAssertEqual(blurredOutput[128 * 257 + 128], expected,
                       "scaled/rotated capture maps the CI Gaussian reference through its developed grid")

        node = try f.admitted(node) { $0.retouch = [blur, smudge] }
        let output = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
        XCTAssertTrue(output.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && (0...1).contains($0.w) })
        XCTAssertNotEqual(output, blurredOutput,
                          "the subsequent scaled/rotated Smudge uses document-space carried cells rather than current tile indices")
        let blurredSurface = try f.surface(width: 257, height: 257, pixels: blurredOutput)
        let smudgeReference = try LWSourceRetouch.evaluateReference(strokes: [smudge], sourceID: node.id,
            developed: blurredSurface, map: map, admission: try f.admittedFixture(blurredSurface, strokes: [smudge])) { _, upstream in upstream }
        let smudgeDocumentCell = try frame.developedPixelToDocument(smudgeCapturedDab)
        guard let smudgeSource = try frame.sourcePointIfInBounds(smudgeDocumentCell),
              let smudgeCurrent = try map.developedPointIfInBounds(smudgeSource) else { throw ProjectError.invalid }
        let smudgeX = Int(floor(smudgeCurrent.x)), smudgeY = Int(floor(smudgeCurrent.y))
        guard smudgeX >= 0, smudgeY >= 0, smudgeX < 257, smudgeY < 257 else { throw ProjectError.invalid }
        XCTAssertEqual(output[smudgeY * 257 + smudgeX], smudgeReference.pixels[smudgeY * 257 + smudgeX],
                       "scaled/rotated Smudge agrees with the independently indexed document-raster reference")
        XCTAssertGreaterThan(output[smudgeY * 257 + smudgeX].w, 0,
                             "the selected transformed current destination receives the real marked captured pickup")
    }
}

extension FloatRetouchTests {
    func testR8TiledHealModesReconstructUniformPremultipliedReference() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let reference = SIMD4<Float>(2, 1, 0.5, 1)
        var input = try f.surface(width: 257, height: 257,
                                  pixels: [SIMD4<Float>](repeating: reference, count: 257 * 257))
        input.pixels[128 * 257 + 128] = SIMD4<Float>(9, 0, 0, 1)
        let map = try f.map(width: 257, height: 257)

        for mode in [LWSourceRetouchStroke.HealMode.contentAware, .createTexture, .proximityMatch] {
            let (node, _) = try f.nodeAndStroke(kind: .heal, width: 257, height: 257,
                points: [CGPoint(x: 128.5, y: 128.5)], radius: 2, healMode: mode)
            let result = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
            XCTAssertEqual(result[128 * 257 + 128], reference,
                           "\(mode) must solve the retained ring/membrane reference, not merely produce a finite changed pixel")
            XCTAssertEqual(result[127 * 257 + 128], reference,
                           "\(mode) keeps the unmasked ring fixed while it reconstructs the hole")
        }
    }

    func testR9TiledHealLargeNonuniformHoleMatchesTheIndependentGlobalSolver() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let width = 257, height = 257
        let base = SIMD4<Float>(2, 1, 0.5, 1)
        var input = try f.surface(width: width, height: height,
                                  pixels: [SIMD4<Float>](repeating: base, count: width * height))
        // A nonuniform ring makes the >32px coarse-grid path discriminating: a coarse role may
        // seed only retained HOLE cells, never a fixed ring sample or a synthetic random fill.
        for x in 72...184 {
            input.pixels[72 * width + x] = SIMD4<Float>(3, 0.5, 0.25, 1)
            input.pixels[184 * width + x] = SIMD4<Float>(0.5, 2, 1, 1)
        }
        for y in 72...184 {
            input.pixels[y * width + 72] = SIMD4<Float>(1, 0.25, 3, 1)
            input.pixels[y * width + 184] = SIMD4<Float>(2.5, 1, 0.125, 1)
        }
        input.pixels[128 * width + 128] = SIMD4<Float>(11, 0, 0, 1)
        let map = try f.map(width: width, height: height,
                            geometry: [1.15, 0.08, -9, 0.03, 0.84, 12, 0, 0, 1])
        for mode in [LWSourceRetouchStroke.HealMode.contentAware, .createTexture, .proximityMatch] {
            let (node, stroke) = try f.nodeAndStroke(kind: .heal, width: width, height: height,
                                                       points: [CGPoint(x: 128.5, y: 128.5)],
                                                       radius: 48, healMode: mode)
            let tiled = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
            // The independent global reference must retain the exact node source identity; the
            // fixture-wide source UUID is deliberately different and production validation rejects it.
            let reference = try LWSourceRetouch.evaluateReference(strokes: [stroke], sourceID: node.id,
                developed: input, map: map, admission: try f.admittedFixture(input, strokes: [stroke])) { _, upstream in upstream }
            XCTAssertEqual(tiled, reference.pixels,
                           "\(mode) preserves the retained large-hole role/membrane solver through nonuniform tiled coordinates")
            XCTAssertNotEqual(tiled[128 * width + 128], input.pixels[128 * width + 128],
                              "the >32px coarse HOLE branch repairs the covered outlier")
        }
    }

    func testR8TiledSelectionZeroConservesEveryRetouchMode() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let input = try f.surface(width: 257, height: 257,
                                  pixels: [SIMD4<Float>](repeating: SIMD4<Float>(3, 2, 1, 1), count: 257 * 257))
        let zero = try f.plane(try f.surface(width: 257, height: 257), workspace: workspace)
        let map = try f.map(width: 257, height: 257)

        for kind in [LWSourceRetouchStroke.Kind.clone, .heal, .paint, .erase, .smear, .blur, .liquify] {
            var node = try f.node(width: 257, height: 257)
            var stroke = try f.stroke(for: node, kind: kind, width: 257, height: 257,
                                      points: [CGPoint(x: 129, y: 128)],
                                      sourceStart: kind == .smear || kind == .liquify ? CGPoint(x: 127, y: 128) : nil,
                                      color: [8, 0, 0, 1], radius: 3, blurRadius: 2,
                                      sourceOffset: kind == .clone ? CGSize(width: -1, height: 0) : .zero)
            let selectionID = UUID()
            stroke.selectionPlaneID = selectionID
            let selectionAsset = try LWSourcePlaneAsset(zero)
            node = try f.admitted(node) { value in
                value.planeAssets[selectionID] = selectionAsset
                value.retouch = [stroke]
            }
            let output = try f.pixels(try f.tiledEvaluate(node, surface: input, map: map, workspace: workspace))
            XCTAssertEqual(output, input.pixels,
                           "zero captured selection must suppress \(kind) before any output publication")
        }
    }

    func testR8TiledSampleAllUsesCapturedPlaneCompositeAndImmediatelyPriorSource() throws {
        let f = FloatRetouchFixture(), workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        let sourceSurface = try f.surface(width: 8, height: 8)
        let sourcePlane = try f.plane(sourceSurface, workspace: workspace)
        let overlaySurface = try f.surface(width: 8, height: 8,
            pixels: [SIMD4<Float>](repeating: SIMD4<Float>(0,3,0,1), count: 64))
        let overlayPlane = try f.plane(overlaySurface, workspace: workspace)
        var node = try f.node(width: 8, height: 8)
        let sourceLayer = UUID(), overlayLayer = UUID()
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8))
        let manifest = ProjectManifest(workingSpace: "extended-linear-sRGB", workingSample: "float32-straight-RGBA",
            documentID: UUID(), width: 8, height: 8, activeLayerID: sourceLayer, layers: [
                ProjectLayerRecord(id: sourceLayer, name: "Captured source", isVisible: true, transform: transform,
                    imageFile: sourceLayer.uuidString + ".plane", liveSource: node),
                ProjectLayerRecord(id: overlayLayer, name: "Retained overlay", isVisible: true, transform: transform,
                    imageFile: overlayLayer.uuidString + ".plane")])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [
            sourceLayer: try ImportedImage(plane: sourcePlane, name: "Source"),
            overlayLayer: try ImportedImage(plane: overlayPlane, name: "Overlay")])
        let captured = try LWSourceSampleComposite.capturePlane(snapshot, sourceLayer: sourceLayer, node: node, workspace: workspace)
        node = try f.admitted(node) { value in
            value.sampleComposites.append(captured.composite)
            value.planeAssets.merge(captured.assets) { _, current in current }
        }
        var stroke = try f.stroke(for: node, kind: .clone, width: 8, height: 8,
                                  points: [CGPoint(x: 3.5, y: 3.5)], sourceOffset: .zero)
        stroke = try LWSourceRetouchStroke(sourceID: node.id, upstreamRevision: node.revision,
            captureFrame: stroke.captureFrame, kind: .clone, seed: stroke.seed, healMode: stroke.healMode,
            sampleAllLayers: true, aligned: stroke.aligned,
            sampleAllLayersCompositeRevision: captured.composite.revision, blurRadius: stroke.blurRadius,
            radius: stroke.radius, hardness: stroke.hardness, opacity: stroke.opacity, points: stroke.points,
            sourceOffset: stroke.sourceOffset, color: stroke.color, pointsAreDabs: stroke.pointsAreDabs,
            selectionSourceCoverage: nil)
        node = try f.admitted(node) { $0.retouch = [stroke] }
        let output = try f.pixels(try f.tiledEvaluate(node, surface: sourceSurface, map: try f.map(width: 8, height: 8), workspace: workspace))
        assertFloatClose(output[3 * 8 + 3], SIMD4<Float>(0,3,0,1),
            "sample-all resolves the captured plane composite and substitutes the immutable pre-stroke source only at its source layer")
    }

    func testR13TiledSmudgeLongRunRetainsOnlyPriorAndNextBrushLocalGenerations() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 240] = SIMD4<Float>(3, 0.5, 0, 1)
        var node = try f.node(width: 257, height: 257)
        // This crosses the actual 256-pixel tile boundary. The source control is intentionally long
        // enough to reject a one-snapshot-per-dab design, while the production evaluator keeps
        // only its typed prior/next brush-local carry pair live for each retained dab.
        // WarpStroke's carry places the pickup under each in-canvas dab centre; a dab whose centre is
        // past the last column drags it off canvas. End the route on that last column (x = 256, in
        // the second tile) so the carried pickup must survive every seam-crossing generation.
        let route = (240...256).map { CGPoint(x: CGFloat($0), y: 128) }
        let stroke = try f.stroke(for: node, kind: .smear, width: 257, height: 257,
                                  points: Array(route.dropFirst()), sourceStart: route.first,
                                  radius: 3, hardness: 0.98)
        node = try f.admitted(node) { $0.retouch = [stroke] }
        var inputPlane: LWFloatPlane? = try f.plane(input, workspace: workspace)
        let generationsBefore = workspace.registeredGenerationCount
        var outputPlane: LWFloatPlane? = try LWSourceRetouch.evaluate(node, developed: inputPlane!,
            map: try f.map(width: 257, height: 257), workspace: workspace)
        let output = try f.pixels(outputPlane!)
        XCTAssertGreaterThan(output[128 * 257 + 256].x, 0,
                             "a long retained route carries the original pickup through typed prior/next generations")
        XCTAssertEqual(input.pixels[128 * 257 + 240], SIMD4<Float>(3, 0.5, 0, 1),
                       "long-run retirement never mutates the caller-owned initial plane")
        XCTAssertEqual(workspace.registeredGenerationCount, generationsBefore + 1,
                       "each completed Smudge dab retires its registered carry generation; only the published output plane remains")
        XCTAssertEqual(workspace.activeGenerationCount, 2,
                       "the caller input and published output are the only strong plane generations after the long route")
        let smudgeObservation = try workspace.generationObservation()
        XCTAssertEqual(smudgeObservation.entries.count, generationsBefore + 1)
        XCTAssertLessThanOrEqual(smudgeObservation.registeredHighWater, generationsBefore + 4,
                                 "Smudge may hold input, next carry and a tile successor, but cannot accumulate one generation per dab")
        XCTAssertTrue(smudgeObservation.entries.allSatisfy { !$0.pendingWriter && $0.device != nil && $0.inode != nil && $0.activeLifetimeCount > 0 },
                      "the live frontier must expose held registration identities rather than inferred cleanup")
        XCTAssertTrue(try workspace.retireOwnedPlane(&outputPlane),
                      "after the final output reader releases, only the evaluator-owned result is retired")
        XCTAssertEqual(workspace.registeredGenerationCount, generationsBefore,
                       "retiring the final output returns the registered roster to the explicitly retained input baseline")
        withExtendedLifetime(inputPlane) {}
    }

    func testR13TiledLiquifyLongRunRetiresEachSupersededPlane() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var input = try f.surface(width: 257, height: 257)
        input.pixels[128 * 257 + 240] = SIMD4<Float>(3, 0.5, 0, 1)
        var node = try f.node(width: 257, height: 257)
        // WarpStroke's carry places the pickup under each in-canvas dab centre; a dab whose centre is
        // past the last column drags it off canvas. End the route on that last column (x = 256, in
        // the second tile) so the carried pickup must survive every seam-crossing generation.
        let route = (240...256).map { CGPoint(x: CGFloat($0), y: 128) }
        let stroke = try f.stroke(for: node, kind: .liquify, width: 257, height: 257,
                                  points: Array(route.dropFirst()), sourceStart: route.first,
                                  opacity: 1, radius: 3, hardness: 0.98)
        node = try f.admitted(node) { $0.retouch = [stroke] }
        var inputPlane: LWFloatPlane? = try f.plane(input, workspace: workspace)
        let generationsBefore = workspace.registeredGenerationCount
        var outputPlane: LWFloatPlane? = try LWSourceRetouch.evaluate(node, developed: inputPlane!,
            map: try f.map(width: 257, height: 257), workspace: workspace)
        let output = try f.pixels(outputPlane!)
        XCTAssertNotEqual(output, input.pixels,
                          "the long Liquify route publishes its complete final successor before retirement")
        XCTAssertEqual(workspace.registeredGenerationCount, generationsBefore + 1,
                       "every Liquify predecessor is retired after its reader scope ends")
        XCTAssertEqual(workspace.activeGenerationCount, 2,
                       "long Liquify keeps the caller input and one final output, never one registered plane per dab")
        let liquifyObservation = try workspace.generationObservation()
        XCTAssertEqual(liquifyObservation.entries.count, generationsBefore + 1)
        XCTAssertLessThanOrEqual(liquifyObservation.registeredHighWater, generationsBefore + 2,
                                 "Liquify holds only its prior and one successor plane at an actual dab boundary")
        XCTAssertTrue(liquifyObservation.entries.allSatisfy { !$0.pendingWriter && $0.device != nil && $0.inode != nil && $0.activeLifetimeCount > 0 })
        XCTAssertTrue(try workspace.retireOwnedPlane(&outputPlane),
                      "the final Liquify plane retires only after the retained output observation ends")
        XCTAssertEqual(workspace.registeredGenerationCount, generationsBefore,
                       "long Liquify returns to the explicitly retained input generation baseline")
        withExtendedLifetime(inputPlane) {}
    }

    func testR14PerDabGenerationObservationsReturnToTheEmptyPreInputRoster() throws {
        let f = FloatRetouchFixture()
        for kind in [LWSourceRetouchStroke.Kind.smear, .liquify] {
            let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
            let emptyRoster = try workspace.generationObservation()
            XCTAssertEqual(emptyRoster.entries.count, 0,
                "the route starts before any owned input generation is created")
            var surface = try f.surface(width: 257, height: 257)
            surface.pixels[128 * 257 + 124] = SIMD4<Float>(3, 0.5, 0, 1)
            var current: LWFloatPlane? = try f.plane(surface, workspace: workspace)
            let heldInputBaseline = try workspace.generationObservation()
            XCTAssertEqual(heldInputBaseline.entries.count, emptyRoster.entries.count + 1,
                "the held input is an explicit pre-evaluation generation, not the retirement target")
            for step in 0..<12 {
                let from = CGPoint(x: step.isMultiple(of: 2) ? 124 : 132, y: 128)
                let to = CGPoint(x: step.isMultiple(of: 2) ? 132 : 124, y: 128)
                var node = try f.node(width: 257, height: 257)
                let stroke = try f.stroke(for: node, kind: kind, width: 257, height: 257,
                    points: [to], sourceStart: from, opacity: 1, radius: 3, hardness: 0.98)
                node = try f.admitted(node) { $0.retouch = [stroke] }
                var next: LWFloatPlane? = try LWSourceRetouch.evaluate(node, developed: current!,
                    map: try f.map(width: 257, height: 257), workspace: workspace)

                // This observes a real evaluator boundary while both the prior input and newly
                // published successor remain held. It is not a final-sweep count or a virtual
                // resident-byte estimate.
                let boundary = try workspace.generationObservation()
                XCTAssertEqual(boundary.entries.count, heldInputBaseline.entries.count + 1,
                    "\(kind) holds exactly the input and its newly published successor at a dab boundary")
                XCTAssertEqual(Set(boundary.entries.map(\.name)).count, boundary.entries.count)
                XCTAssertTrue(boundary.entries.allSatisfy {
                    !$0.pendingWriter && $0.device != nil && $0.inode != nil &&
                    $0.activeLifetimeCount > 0 && $0.registeredMemberCount > 0
                })
                let bound = kind == .smear ? heldInputBaseline.registeredHighWater + 4 : heldInputBaseline.registeredHighWater + 2
                XCTAssertLessThanOrEqual(boundary.registeredHighWater, bound,
                    "\(kind) cannot register one typed carry or plane generation per historical dab")
                XCTAssertNotEqual(current!.manifest.id, next!.manifest.id)
                XCTAssertTrue(try workspace.retireOwnedPlane(&current),
                    "only the locally owned predecessor is retired after the observation has released it")
                current = next
            }
            XCTAssertTrue(try workspace.retireOwnedPlane(&current))
            let restored = try workspace.generationObservation()
            XCTAssertEqual(restored.entries.count, emptyRoster.entries.count,
                "the per-dab route retires the held input and final successor back to the empty pre-input roster")
        }
    }

    func testR14LongDabRoutesRetainTheInherited16MiBFrontier() throws {
        let f = FloatRetouchFixture()
        for kind in [LWSourceRetouchStroke.Kind.smear, .liquify] {
            let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 16 * 1024 * 1024))
            var input = try f.surface(width: 257, height: 257)
            input.pixels[128 * 257 + 126] = SIMD4<Float>(3, 0.5, 0, 1)
            var node = try f.node(width: 257, height: 257)
            let dabs = (0..<96).map { index in CGPoint(x: index.isMultiple(of: 2) ? 129 : 126, y: 128) }
            let stroke = try f.stroke(for: node, kind: kind, width: 257, height: 257,
                points: dabs, sourceStart: CGPoint(x: 126, y: 128), opacity: 1, radius: 3, hardness: 0.98)
            node = try f.admitted(node) { $0.retouch = [stroke] }
            var inputPlane: LWFloatPlane? = try f.plane(input, workspace: workspace)
            let baseline = try workspace.generationObservation()
            var outputPlane: LWFloatPlane? = try LWSourceRetouch.evaluate(node, developed: inputPlane!,
                map: try f.map(width: 257, height: 257), workspace: workspace)
            let frontier = try workspace.generationObservation()
            XCTAssertEqual(frontier.entries.count, baseline.entries.count + 1)
            let bound = kind == .smear ? baseline.entries.count + 4 : baseline.entries.count + 2
            XCTAssertLessThanOrEqual(frontier.registeredHighWater, bound,
                "\(kind) must expose its actual bounded predecessor/successor frontier, not infer a resident-byte budget")
            XCTAssertTrue(frontier.entries.allSatisfy { !$0.pendingWriter && $0.device != nil && $0.inode != nil && $0.activeLifetimeCount > 0 })
            XCTAssertTrue(try workspace.retireOwnedPlane(&outputPlane))
            withExtendedLifetime(inputPlane) {}
        }
    }

    func testR9CheckedRetirementRefusesAnAliasedPlaneThenReclaimsReleasedGeneration() throws {
        let f = FloatRetouchFixture()
        let workspace = try LWFloatWorkspace(workingSet: try LWFloatWorkingSet(limit: 64 * 1024 * 1024))
        var candidate: LWFloatPlane? = try f.plane(try f.surface(width: 257, height: 257), workspace: workspace)
        do {
            let reader = candidate!.sampler(edge: .transparent)
            XCTAssertFalse(try workspace.retireOwnedPlane(&candidate),
                           "a retained reader prevents an evaluator from deleting a still-aliased intermediate")
            _ = try reader.sample(CGPoint(x: 0.5, y: 0.5), edge: .transparent)
        }
        XCTAssertTrue(try workspace.retireOwnedPlane(&candidate),
                      "only the released evaluator-owned plane is eligible for checked retirement")
        XCTAssertNil(candidate)
    }
}

/// Tiled and whole-frame float evaluation may associate sums differently; agree to a few ULPs.
func assertFloatClose(_ a: SIMD4<Float>, _ b: @autoclosure () throws -> SIMD4<Float>, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let expected = try b()
        let close = (0..<4).allSatisfy { abs(a[$0] - expected[$0]) <= 1e-6 * max(1, abs(expected[$0])) }
        XCTAssertTrue(close, "\(a) is not within tolerance of \(expected) - \(message)", file: file, line: line)
    } catch { XCTFail("\(error)", file: file, line: line) }
}
