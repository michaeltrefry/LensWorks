import Foundation
import Testing
@testable import Compositor

@MainActor
struct FloatCameraRawTests {
    private func surface(_ pixels: [SIMD4<Float>], width: Int = 1, maximumBytes: Int? = nil) throws -> LWLinearSurface {
        try LWLinearSurface(width: width, height: pixels.count / width, pixels: pixels, maximumBytes: maximumBytes ?? pixels.count * 128)
    }
    private func fixture() throws -> LWLinearSurface {
        try surface((0..<49).map { i in
            let x = Float(i % 7)/6, y = Float(i / 7)/6
            return SIMD4(0.05 + x*0.8, 0.1 + y*0.7, 0.1 + (x + y)*0.3, 1)
        }, width: 7)
    }
    private func bits(_ s: LWLinearSurface) -> [[UInt32]] {
        s.pixels.map { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern] }
    }
    private func close(_ a: Double, _ b: Double) -> Bool {
        // Floating arithmetic comparison scaled to Float precision, not a product color budget.
        abs(a - b) <= Double(Float.ulpOfOne)*16*max(1, max(abs(a), abs(b)))
    }
    private func throwsInvalid(_ body: () throws -> Void) {
        do { try body(); Issue.record("Expected invalid float recipe or extent refusal") }
        catch { #expect(error is ProjectError) }
    }
    @Test func identityRetainsEveryFloatBitIncludingHDRNegativeAndHiddenColor() throws {
        let input = try surface([SIMD4(-0.125, 2.25, Float(bitPattern: 0x3f000001), 0.5), SIMD4(-0.0, 7, -3, 0)])
        let output = try CameraRawSettings().develop(input)
        #expect(bits(output.surface) == bits(input)); #expect(output.map == .identity)
    }
    @Test(arguments: [-5.0, -1, 0, 1, 5])
    func exposureIsExactLinearStopsWithStraightAlpha(_ stops: Double) throws {
        let input = try surface([SIMD4(-0.125, 0.25, 2, 0.25)])
        var s = CameraRawSettings(); s.exposure = stops
        let p = try s.apply(input).pixels[0]
        #expect(p.x == Float(-0.125*exp2(stops))); #expect(p.y == Float(0.25*exp2(stops)))
        #expect(p.z == Float(2*exp2(stops))); #expect(p.w.bitPattern == input.pixels[0].w.bitPattern)
    }
    @Test func whiteBalanceUsesRetainedGainConstantsWithoutQuantization() throws {
        var s = CameraRawSettings(); s.temperature = 40; s.tint = -20
        let p = try s.apply(surface([SIMD4(0.5, 0.5, 0.5, 1)])).pixels[0]
        #expect(close(Double(p.x), 0.5*(1 + 0.35*0.4 - 0.15*0.2)))
        #expect(close(Double(p.y), 0.5*(1 + 0.30*0.2))); #expect(close(Double(p.z), 0.5*(1 - 0.35*0.4 - 0.15*0.2)))
        // Auto stores the already-solved gains; it is not an unpersisted per-render guess.
        let custom = try s.apply(surface([SIMD4(0.5, 0.5, 0.5, 1)]))
        s.whiteBalance = .auto; #expect(try bits(s.apply(surface([SIMD4(0.5, 0.5, 0.5, 1)]))) == bits(custom))
    }
    @Test(arguments: [-2.0, -0.04, 0, 0.0031308, 0.18, 1, 4])
    func extendedTransferRoundTripPreservesSignedRange(_ value: Double) {
        #expect(abs(FloatImageAdjustmentPixels.decode(FloatImageAdjustmentPixels.encode(value)) - value) <= 32*Double.ulpOfOne*max(1, abs(value)))
    }
    @Test func continuousCurveMatchesIndependentLinearReferenceAndExtendsEndpoints() {
        let points = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]
        for x in [-0.25, 0, 0.1234567, 1, 2] {
            #expect(abs(FloatImageAdjustmentPixels.curve(x, points: points) - (0.1 + x*0.8)) < 32*Double.ulpOfOne)
        }
        let x = 0.25, nearby = x + 1.0/65536
        #expect(FloatImageAdjustmentPixels.curve(x, points: points) != FloatImageAdjustmentPixels.curve(nearby, points: points))
    }
    @Test func curvedUnitReferenceUsesExistingHermiteAndParametricDefinitions() throws {
        let points = CameraRawCurveSettings.mediumContrast
        var reference = CurvesSettings(); reference.channels[0] = points.map { CurvePoint(x: $0.x*255, y: $0.y*255) }
        for x in [0.0, 0.1, 0.25, 0.43, 0.75, 1] {
            #expect(abs(FloatImageAdjustmentPixels.curve(x, points: points) - reference.value(x*255, channel: 0)/255) < 64*Double.ulpOfOne)
        }
        var s = CameraRawCurveSettings(); s.shadows = 20; s.darks = -30; s.lights = 35; s.highlights = -15
        let anchors = FloatImageAdjustmentPixels.parametricAnchors(s)
        for x in [0.0, 0.13, 0.31, 0.71, 1] { #expect(abs(FloatImageAdjustmentPixels.curve(x, points: anchors) - s.parametric(x)) < 64*Double.ulpOfOne) }
    }
    @Test func saturationZeroProducesIndependentRec709NeutralInEncodedDomain() throws {
        var s = CameraRawSettings(); s.saturation = -100
        let p = try s.apply(surface([SIMD4(0.2, 0.4, 0.8, 0.5)])).pixels[0]
        let y = 0.2126*FloatImageAdjustmentPixels.encode(0.2) + 0.7152*FloatImageAdjustmentPixels.encode(0.4) + 0.0722*FloatImageAdjustmentPixels.encode(0.8)
        let expected = FloatImageAdjustmentPixels.decode(y)
        #expect(close(Double(p.x), expected)); #expect(p.x == p.y && p.y == p.z); #expect(p.w == 0.5)
    }
    @Test func hslEnvelopeRoundTripsHDRAndNegativeWithoutClipping() {
        for c in [SIMD3<Double>(-0.2, 2.1, 0.5), SIMD3<Double>(3, 4, 5), SIMD3<Double>(-2, -1, -0.5), SIMD3<Double>(0.2, 0.4, 0.7)] {
            let out = FloatImageAdjustmentPixels.ColorEnvelope(c).rgb()
            #expect(close(out.x, c.x)); #expect(close(out.y, c.y)); #expect(close(out.z, c.z))
        }
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func everyMixerFamilySelectsItsOwnHue(_ family: Int) throws {
        let color = FloatImageAdjustmentPixels.hsl(CameraRawMixerSettings.centers[family]/360, 0.6, 0.45)
        let input = try surface([SIMD4(Float(FloatImageAdjustmentPixels.decode(color.x)), Float(FloatImageAdjustmentPixels.decode(color.y)), Float(FloatImageAdjustmentPixels.decode(color.z)), 1)])
        var s = CameraRawSettings(); s.mixer.hue[family] = 70
        #expect(try bits(s.apply(input)) != bits(input))
        s.mixer.hue[family] = 0; s.mixer.saturation[family] = -70; #expect(try bits(s.apply(input)) != bits(input))
        s.mixer.saturation[family] = 0; s.mixer.luminance[family] = 50; #expect(try bits(s.apply(input)) != bits(input))
    }
    @Test func pointColorRangeSelectivityAndIdleVisualizationAreRetained() throws {
        var point = CameraRawPointColor(); point.hue = 0; point.saturation = 1; point.luminance = 0.5; point.hueShift = 100
        var s = CameraRawSettings(); s.mixer.points = [point]
        let input = try surface([SIMD4(1, 0, 0, 1), SIMD4(0, 0, 1, 1)], width: 2)
        let output = try s.apply(input)
        #expect(output.pixels[0] != input.pixels[0]); #expect(output.pixels[1] == input.pixels[1])
        s.mixer.points[0].visualize = true; #expect(try bits(s.apply(input)) == bits(output))
    }
    @Test(arguments: [0, 1, 2, 3])
    func allGradingWheelsHaveRealPixelEffect(_ wheel: Int) throws {
        let input = try surface([SIMD4(0.1, 0.1, 0.1, 1), SIMD4(0.4, 0.4, 0.4, 1), SIMD4(0.8, 0.8, 0.8, 1)], width: 3)
        var s = CameraRawSettings()
        let keys: [WritableKeyPath<CameraRawGradingSettings, CameraRawGradeWheel>] = [\.shadows, \.midtones, \.highlights, \.global]
        s.grading[keyPath: keys[wheel]].hue = 210; s.grading[keyPath: keys[wheel]].saturation = 70
        #expect(try bits(s.apply(input)) != bits(input))
    }
    @Test func effectAndDetailPreserveFullExtentAlphaAndIdleCompanions() throws {
        let input = try fixture()
        var settings: [CameraRawSettings] = []
        var s = CameraRawSettings(); s.texture = 50; settings.append(s)
        s = CameraRawSettings(); s.clarity = 50; settings.append(s)
        s = CameraRawSettings(); s.dehaze = 60; settings.append(s)
        s = CameraRawSettings(); s.glow = 70; settings.append(s)
        s = CameraRawSettings(); s.vignetteAmount = -70; settings.append(s)
        s = CameraRawSettings(); s.grainAmount = 60; settings.append(s)
        s = CameraRawSettings(); s.detail.noiseLuminance = 75; settings.append(s)
        s = CameraRawSettings(); s.detail.noiseColor = 75; settings.append(s)
        s = CameraRawSettings(); s.detail.sharpenAmount = 90; settings.append(s)
        for s in settings {
            let output = try s.apply(input, seed: 19)
            #expect(output.width == input.width && output.height == input.height)
            #expect(output.pixels.map(\.w) == input.pixels.map(\.w)); #expect(bits(output) != bits(input))
        }
        var idle = CameraRawSettings(); idle.glowWarmth = 100; idle.glowRange = 100; idle.glowSpread = 100
        idle.grainSize = 100; idle.grainRoughness = 100; idle.detail.sharpenRadius = 100; idle.optics.profileDistortion = 25
        #expect(try bits(idle.apply(input)) == bits(input))
    }
    @Test func grainHasKnownHashReferenceAndSeedConservation() throws {
        #expect(FloatImageAdjustmentPixels.mix32(0) == 0)
        #expect(FloatImageAdjustmentPixels.mix32(1) == 0x688990c0)
        #expect(FloatImageAdjustmentPixels.lattice(0, 0, seed: 0) == -1)
        #expect(try FloatImageAdjustmentPixels.grain(0, 0, size: 5, seed: 0) == -1.6)
        var s = CameraRawSettings(); s.grainAmount = 60
        let input = try fixture(), a = try s.apply(input, seed: 41), b = try s.apply(input, seed: 41), c = try s.apply(input, seed: 42)
        #expect(bits(a) == bits(b)); #expect(bits(a) != bits(c))
    }
    @Test func alphaInterpolationIsPremultipliedLinearWithoutHiddenColorFringe() throws {
        let input = try surface([SIMD4(2, 0, 0, 0.5), SIMD4(0, 100, 0, 0)], width: 2)
        let sample = FloatImageAdjustmentPixels.sample(input, x: 0.5, y: 0)
        #expect(sample == SIMD4(2, 0, 0, 0.25))
        let blur = FloatImageAdjustmentPixels.blur([0, 1, 0], width: 3, height: 1, radius: 1)
        #expect(blur.allSatisfy { abs($0 - 1.0/3) < Double.ulpOfOne })
    }
    @Test func geometryUsesTopFirstHomographyAndInverseWithNoPreviewDownsampling() throws {
        var s = CameraRawGeometrySettings(); s.offsetX = 100
        let map = try s.coordinateMap(width: 20, height: 10)
        let p = try map.map(CGPoint(x: 4, y: 3))
        #expect(abs(p.x - 7) < 1e-12); #expect(abs(p.y - 3) < 1e-12)
        let back = try map.inverse().map(p); #expect(abs(back.x - 4) < 1e-12 && abs(back.y - 3) < 1e-12)
        var settings = CameraRawSettings(); settings.geometry = s
        let developed = try settings.develop(fixture())
        #expect(developed.surface.width == 7 && developed.surface.height == 7)
        #expect(developed.map == (try s.coordinateMap(for: fixture())))
    }
    @Test func constrainCropReturnsActualAlphaAwareMapUsedByPixels() throws {
        var geometry = CameraRawGeometrySettings(); geometry.scale = -50; geometry.constrainCrop = true
        let input = try surface([SIMD4<Float>](repeating: SIMD4(2, 0.2, -0.1, 1), count: 16), width: 4)
        let raw = try geometry.coordinateMap(width: 4, height: 4), effective = try geometry.coordinateMap(for: input)
        #expect(raw != effective)
        var settings = CameraRawSettings(); settings.geometry = geometry
        let output = try settings.develop(input)
        #expect(output.map == effective)
        #expect(bits(output.surface) == bits(try geometry.resample(input, map: effective)))
        #expect(output.surface.pixels.contains { $0.x > 1 && $0.z < 0 })
    }
    @Test func opticsCoordinateAndPixelSamplerShareExactRadialMap() throws {
        var optics = CameraRawOpticsSettings(); optics.distortion = 50
        let point = CGPoint(x: 2.5, y: 1.5)
        let source = try optics.sourcePoint(for: point, width: 7, height: 7)
        let back = try optics.developedPoint(for: source, width: 7, height: 7)
        #expect(abs(back.x - point.x) < 1e-12 && abs(back.y - point.y) < 1e-12)
        var s = CameraRawSettings(); s.optics = optics
        let input = try fixture(), output = try s.apply(input)
        #expect(output.pixels[1*7 + 2] == FloatImageAdjustmentPixels.sample(input, x: source.x - 0.5, y: source.y - 0.5))
        optics.enableLensProfile = true; optics.distortion = 100
        throwsInvalid { _ = try optics.developedPoint(for: point, width: 7, height: 7) }
    }
    @Test func calibrationProcessesRetainDifferentResponsesAndAllPrimaries() throws {
        let input = try surface([SIMD4(0.4, 0.1, 0.1, 1), SIMD4(0.1, 0.4, 0.1, 1), SIMD4(0.1, 0.1, 0.4, 1)], width: 3)
        var s = CameraRawSettings(); s.calibration.redHue = 100; s.calibration.greenHue = 100; s.calibration.blueHue = 100
        var outputs = Set<[[UInt32]]>()
        for version in CameraRawProcessVersion.allCases { s.calibration.process = version; outputs.insert(bits(try s.apply(input))) }
        #expect(outputs.count == 6)
        s = CameraRawSettings(); s.calibration.process = .version1; #expect(try bits(s.apply(input)) == bits(input))
    }
    @Test func invalidControlsAndPeakFloatScratchFailClosed() throws {
        let input = try fixture()
        var s = CameraRawSettings(); s.mixer.hue.removeLast(); throwsInvalid { _ = try s.apply(input) }
        s = CameraRawSettings(); s.temperature = .nan; throwsInvalid { _ = try s.apply(input) }
        s = CameraRawSettings(); s.curve.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0, y: 1)]; throwsInvalid { _ = try s.apply(input) }
        s = CameraRawSettings(); s.geometry.scale = -100; throwsInvalid { _ = try s.apply(input) }
        s = CameraRawSettings(); s.geometry.guides = [CameraRawGeometryGuide(startX: .infinity, startY: 0, endX: 1, endY: 1)]; throwsInvalid { _ = try s.apply(input) }
        let tight = try surface(input.pixels, width: input.width, maximumBytes: input.byteLength)
        s = CameraRawSettings(); #expect(try bits(s.apply(tight)) == bits(tight))
        s.exposure = 1; throwsInvalid { _ = try s.apply(tight) }
        let insufficientScratch = try surface(input.pixels, width: 7, maximumBytes: input.pixels.count*64)
        s = CameraRawSettings(); s.detail.noiseColor = 50; throwsInvalid { _ = try s.apply(insufficientScratch) }
    }
    @Test(arguments: ["temperature", "tint", "exposure", "contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation", "texture", "clarity", "dehaze", "glow", "glowRange", "glowSpread", "glowWarmth", "vignetteAmount", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights", "grainAmount", "grainSize", "grainRoughness", "curve.shadows", "curve.darks", "curve.lights", "curve.highlights", "curve.shadowSplit", "curve.darkSplit", "curve.lightSplit", "curve.refineSaturation", "grading.global.hue", "grading.global.saturation", "grading.global.luminance", "grading.blending", "grading.balance", "detail.sharpenAmount", "detail.sharpenRadius", "detail.sharpenDetail", "detail.sharpenMasking", "detail.noiseLuminance", "detail.noiseLuminanceDetail", "detail.noiseLuminanceContrast", "detail.noiseColor", "detail.noiseColorDetail", "detail.noiseColorSmoothness", "optics.profileDistortion", "optics.profileVignetting", "optics.distortion", "optics.purpleAmount", "optics.purpleHueLow", "optics.purpleHueHigh", "optics.greenAmount", "optics.greenHueLow", "optics.greenHueHigh", "optics.vignetteAmount", "optics.vignetteMidpoint", "geometry.vertical", "geometry.horizontal", "geometry.rotate", "geometry.aspect", "geometry.scale", "geometry.offsetX", "geometry.offsetY", "calibration.shadowTint", "calibration.redHue", "calibration.redSaturation", "calibration.greenHue", "calibration.greenSaturation", "calibration.blueHue", "calibration.blueSaturation"])
    func everyRetainedScalarRejectsNonfiniteImportedValue(_ field: String) throws {
        var settings = CameraRawSettings()
        let keys: [String: WritableKeyPath<CameraRawSettings, Double>] = [
            "temperature": \.temperature,
            "tint": \.tint,
            "exposure": \.exposure,
            "contrast": \.contrast,
            "highlights": \.highlights,
            "shadows": \.shadows,
            "whites": \.whites,
            "blacks": \.blacks,
            "vibrance": \.vibrance,
            "saturation": \.saturation,
            "texture": \.texture,
            "clarity": \.clarity,
            "dehaze": \.dehaze,
            "glow": \.glow,
            "glowRange": \.glowRange,
            "glowSpread": \.glowSpread,
            "glowWarmth": \.glowWarmth,
            "vignetteAmount": \.vignetteAmount,
            "vignetteMidpoint": \.vignetteMidpoint,
            "vignetteRoundness": \.vignetteRoundness,
            "vignetteFeather": \.vignetteFeather,
            "vignetteHighlights": \.vignetteHighlights,
            "grainAmount": \.grainAmount,
            "grainSize": \.grainSize,
            "grainRoughness": \.grainRoughness,
            "curve.shadows": \.curve.shadows,
            "curve.darks": \.curve.darks,
            "curve.lights": \.curve.lights,
            "curve.highlights": \.curve.highlights,
            "curve.shadowSplit": \.curve.shadowSplit,
            "curve.darkSplit": \.curve.darkSplit,
            "curve.lightSplit": \.curve.lightSplit,
            "curve.refineSaturation": \.curve.refineSaturation,
            "grading.global.hue": \.grading.global.hue,
            "grading.global.saturation": \.grading.global.saturation,
            "grading.global.luminance": \.grading.global.luminance,
            "grading.blending": \.grading.blending,
            "grading.balance": \.grading.balance,
            "detail.sharpenAmount": \.detail.sharpenAmount,
            "detail.sharpenRadius": \.detail.sharpenRadius,
            "detail.sharpenDetail": \.detail.sharpenDetail,
            "detail.sharpenMasking": \.detail.sharpenMasking,
            "detail.noiseLuminance": \.detail.noiseLuminance,
            "detail.noiseLuminanceDetail": \.detail.noiseLuminanceDetail,
            "detail.noiseLuminanceContrast": \.detail.noiseLuminanceContrast,
            "detail.noiseColor": \.detail.noiseColor,
            "detail.noiseColorDetail": \.detail.noiseColorDetail,
            "detail.noiseColorSmoothness": \.detail.noiseColorSmoothness,
            "optics.profileDistortion": \.optics.profileDistortion,
            "optics.profileVignetting": \.optics.profileVignetting,
            "optics.distortion": \.optics.distortion,
            "optics.purpleAmount": \.optics.purpleAmount,
            "optics.purpleHueLow": \.optics.purpleHueLow,
            "optics.purpleHueHigh": \.optics.purpleHueHigh,
            "optics.greenAmount": \.optics.greenAmount,
            "optics.greenHueLow": \.optics.greenHueLow,
            "optics.greenHueHigh": \.optics.greenHueHigh,
            "optics.vignetteAmount": \.optics.vignetteAmount,
            "optics.vignetteMidpoint": \.optics.vignetteMidpoint,
            "geometry.vertical": \.geometry.vertical,
            "geometry.horizontal": \.geometry.horizontal,
            "geometry.rotate": \.geometry.rotate,
            "geometry.aspect": \.geometry.aspect,
            "geometry.scale": \.geometry.scale,
            "geometry.offsetX": \.geometry.offsetX,
            "geometry.offsetY": \.geometry.offsetY,
            "calibration.shadowTint": \.calibration.shadowTint,
            "calibration.redHue": \.calibration.redHue,
            "calibration.redSaturation": \.calibration.redSaturation,
            "calibration.greenHue": \.calibration.greenHue,
            "calibration.greenSaturation": \.calibration.greenSaturation,
            "calibration.blueHue": \.calibration.blueHue,
            "calibration.blueSaturation": \.calibration.blueSaturation
        ]
        let key = try #require(keys[field]); settings[keyPath: key] = .nan
        throwsInvalid { _ = try settings.apply(fixture()) }
    }
    @Test func everyArrayChannelPointAndGuideRejectsNonfiniteOrMissingBacking() throws {
        let input = try fixture()
        for channel in 0..<8 {
            var s = CameraRawSettings(); s.mixer.hue[channel] = .nan; throwsInvalid { _ = try s.apply(input) }
            s = CameraRawSettings(); s.mixer.saturation[channel] = .infinity; throwsInvalid { _ = try s.apply(input) }
            s = CameraRawSettings(); s.mixer.luminance[channel] = -.infinity; throwsInvalid { _ = try s.apply(input) }
        }
        var s = CameraRawSettings(); var point = CameraRawPointColor(); point.hueRange = .nan; s.mixer.points = [point]
        throwsInvalid { _ = try s.apply(input) }
        s = CameraRawSettings(); s.curve.blue[1].y = .infinity; throwsInvalid { _ = try s.apply(input) }
        s = CameraRawSettings(); s.geometry.guides = [CameraRawGeometryGuide(startX: -1, startY: 0, endX: 1, endY: 1)]
        throwsInvalid { _ = try s.apply(input) }
    }
    @Test func autoBalanceSolvesActualLinearSourceAndSkipsHiddenPixels() throws {
        let input = try surface([SIMD4(0.4, 0.2, 0.1, 1), SIMD4(100, 1, -100, 0)], width: 2)
        let solved = try #require(CameraRawSettings.autoBalance(of: input))
        let reference = try #require(CameraRawSettings.neutralize(linearRed: Double(input.pixels[0].x), green: Double(input.pixels[0].y), blue: Double(input.pixels[0].z)))
        #expect(solved.temperature == reference.temperature && solved.tint == reference.tint)
        #expect(try CameraRawSettings.autoBalance(of: surface([SIMD4(0, 0, 0, 0)])) == nil)
    }
    @Test(arguments: AdjustmentKind.allCases)
    func everyAdjustmentKindUsesFullFloatExtentAndStraightAlpha(_ kind: AdjustmentKind) throws {
        let input = try fixture()
        var a = LayerAdjustment(kind: kind)
        switch kind {
        case .hsv: a.hue = 35; a.saturation = 20
        case .levels: a.levels.ranges[0].gamma = 1.8
        case .curves: a.curves.channels[0][0].y = 25
        case .exposure: a.exposure.exposure = 1
        case .gradientMap: a.gradientMap.reversed = true
        case .grain: a.grain.seed = 31; a.grain.amount = 80
        case .addNoise: a.resolvedNoiseSeed = 31; a.resolvedNoiseAmount = 40
        case .gaussianBlur: a.gaussianRadius = 1.2
        case .motionBlur: a.resolvedMotionDistance = 6; a.resolvedMotionAngle = 35
        case .blackWhite: a.blackWhite.tint = true
        case .colorBalance: a.colorBalance.midCyanRed = 50
        case .invert: break
        }
        let output = try a.apply(input)
        #expect(output.width == input.width && output.height == input.height)
        #expect(bits(output) != bits(input)); try output.validate(maximumBytes: input.maximumBytes)
        // Interpolating blur can change edge coverage; point operations must retain every alpha bit.
        if kind != .gaussianBlur && kind != .motionBlur { #expect(output.pixels.map(\.w) == input.pixels.map(\.w)) }
    }
    @Test func adjustmentExposureAndInvertHaveAnalyticalHDRReferences() throws {
        let input = try surface([SIMD4(-0.25, 0.5, 2, 0.5)])
        var a = LayerAdjustment(kind: .exposure); a.exposure = ExposureSettings(exposure: 1, offset: 0.125, gamma: 1)
        let p = try a.apply(input).pixels[0]
        #expect(p == SIMD4(-0.375, 1.125, 4.125, 0.5))
        let inverted = try LayerAdjustment(kind: .invert).apply(input).pixels[0]
        #expect(close(Double(inverted.z), FloatImageAdjustmentPixels.decode(1 - FloatImageAdjustmentPixels.encode(2))))
        #expect(inverted.z < 0); #expect(inverted.w == 0.5)
    }
    @Test func adjustmentGrainAndNoiseStayAnchoredAcrossPartialRegions() throws {
        let full = try surface([SIMD4<Float>](repeating: SIMD4(0.3, 0.3, 0.3, 0.5), count: 16), width: 4)
        let part = try surface([SIMD4<Float>](repeating: SIMD4(0.3, 0.3, 0.3, 0.5), count: 4), width: 2)
        for kind in [AdjustmentKind.grain, .addNoise] {
            var a = LayerAdjustment(kind: kind); a.grain.seed = 53; a.resolvedNoiseSeed = 53
            let output = try a.apply(full), tile = try a.apply(part, region: CGRect(x: 2, y: 2, width: 2, height: 2))
            #expect(tile.pixels == [output.pixels[10], output.pixels[11], output.pixels[14], output.pixels[15]])
        }
    }
    @Test func negativeCurveRefinementRetainsOriginalHueRatherThanDesaturating() throws {
        var settings = CameraRawSettings(); settings.curve.rgb = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]; settings.curve.refineSaturation = -100
        let input = try surface([SIMD4(0.1, 0.3, 0.6, 1)])
        let p = try settings.apply(input).pixels[0]
        let source = SIMD3<Double>(FloatImageAdjustmentPixels.encode(Double(input.pixels[0].x)), FloatImageAdjustmentPixels.encode(Double(input.pixels[0].y)), FloatImageAdjustmentPixels.encode(Double(input.pixels[0].z)))
        let result = SIMD3<Double>(FloatImageAdjustmentPixels.encode(Double(p.x)), FloatImageAdjustmentPixels.encode(Double(p.y)), FloatImageAdjustmentPixels.encode(Double(p.z)))
        #expect(close(result.x/result.y, source.x/source.y)); #expect(close(result.z/result.y, source.z/source.y))
        #expect(result.x != result.y)
    }
    @Test(arguments: ["vertical", "horizontal", "rotate", "aspect", "scale", "offsetX", "offsetY"])
    func eachGeometryControlProducesItsOwnInvertibleSourceMap(_ field: String) throws {
        let keys: [String: WritableKeyPath<CameraRawGeometrySettings, Double>] = ["vertical": \.vertical, "horizontal": \.horizontal, "rotate": \.rotate, "aspect": \.aspect, "scale": \.scale, "offsetX": \.offsetX, "offsetY": \.offsetY]
        var geometry = CameraRawGeometrySettings(); geometry[keyPath: try #require(keys[field])] = 20
        let map = try geometry.coordinateMap(width: 7, height: 7), point = CGPoint(x: 2, y: 3)
        #expect(map != .identity)
        let roundTrip = try map.inverse().map(map.map(point))
        #expect(abs(roundTrip.x - point.x) < 1e-12 && abs(roundTrip.y - point.y) < 1e-12)
        geometry.projection = .rectilinear
        #expect(try geometry.coordinateMap(width: 7, height: 7) != .identity)
    }
    @Test func guidedUprightUsesRetainedGuideAnglesAndConstrainCropMetadata() throws {
        var geometry = CameraRawGeometrySettings(); geometry.upright = .guided
        geometry.guides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.2, endX: 0.8, endY: 0.4)]
        let guided = try geometry.coordinateMap(width: 7, height: 7)
        var manual = CameraRawGeometrySettings(); manual.rotate = -atan2(0.2, 0.7)*180 / .pi
        let reference = try manual.coordinateMap(width: 7, height: 7)
        for i in 0..<9 { #expect(abs(guided.values[i] - reference.values[i]) < 1e-12) }
    }
    @Test func allGlowVignetteLooksAndOpticsOperationsReachActualFloatPixels() throws {
        let input = try fixture()
        var glowResults = Set<[[UInt32]]>()
        for style in CameraRawGlowStyle.allCases {
            var settings = CameraRawSettings(); settings.glow = 80; settings.glowStyle = style; settings.glowRange = -50; settings.glowSpread = 60; settings.glowWarmth = 75
            glowResults.insert(bits(try settings.apply(input)))
        }
        #expect(glowResults.count == 3)
        var vignetteResults = Set<[[UInt32]]>()
        for style in CameraRawVignetteStyle.allCases {
            var settings = CameraRawSettings(); settings.vignetteAmount = -80; settings.vignetteStyle = style; settings.vignetteHighlights = 100
            vignetteResults.insert(bits(try settings.apply(input)))
        }
        #expect(vignetteResults.count == 3)
        let colors = try surface([SIMD4(0.8, 0.1, 0.8, 1), SIMD4(0.1, 0.8, 0.1, 1)], width: 2)
        var settings = CameraRawSettings(); settings.optics.purpleAmount = 100; settings.optics.greenAmount = 100
        let defringed = try settings.apply(colors)
        #expect(bits(defringed) != bits(colors))
        settings = CameraRawSettings(); settings.optics.removeChromaticAberration = true; #expect(try bits(settings.apply(input)) != bits(input))
        settings = CameraRawSettings(); settings.optics.enableLensProfile = true; #expect(try bits(settings.apply(input)) != bits(input))
    }
}

nonisolated private final class TiledFloatTestWorkspace: Sendable {
    let root: URL
    let workingSet: LWFloatWorkingSet
    init(limit: Int = 64 * 1024 * 1024) throws {
        workingSet = try LWFloatWorkingSet(limit: limit)
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LWFloatTile-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func directory() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }
    func builder(_ width: Int, _ height: Int) throws -> LWFloatPlane.Builder {
        try LWFloatPlane.Builder(directory: directory(), width: width, height: height, workingSet: workingSet)
    }
    var workspace: LWFloatKernelWorkspace {
        LWFloatKernelWorkspace(makeBuilder: builder, makeScratchDirectory: directory)
    }
    func plane(_ surface: LWLinearSurface) throws -> LWFloatPlane {
        let builder = try builder(surface.width, surface.height)
        while let range = builder.nextRange {
            let bytes = try range.validate(frameWidth: surface.width, frameHeight: surface.height)
            let lease = try workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](); pixels.reserveCapacity(bytes / 16)
            for y in range.y..<(range.y + range.height) {
                pixels.append(contentsOf: surface.pixels[(y*surface.width + range.x)..<(y*surface.width + range.x + range.width)])
            }
            try builder.append(LWLinearSurface(width: range.width, height: range.height,
                pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }
    func compare(_ plane: LWFloatPlane, _ reference: LWLinearSurface) throws {
        #expect(plane.width == reference.width && plane.height == reference.height)
        for y in 0..<reference.height {
            let row = try plane.read(LWFloatRange(x: 0, y: y, width: reference.width, height: 1))
            for x in 0..<reference.width { for channel in 0..<4 {
                #expect(row.surface.pixels[x][channel].bitPattern == reference.pixels[y*reference.width + x][channel].bitPattern)
            } }
        }
    }
}

@MainActor
struct TiledFloatCameraRawTests {
    private func fixture(width: Int = 259, height: Int = 257) throws -> LWLinearSurface {
        let pixels = (0..<(width * height)).map { i -> SIMD4<Float> in
            let x = i % width, y = i / width
            let r = Float((x*17 + y*11) % 101) / 37 - 0.2
            let g = Float((x*7 + y*19) % 97) / 71
            let b = Float((x*13 + y*3) % 103) / 41
            // Nonzero hidden RGB and a translucent edge discriminate premultiplication.
            let alpha: Float = (x + y) % 19 == 0 ? 0 : ((x + y) % 7 == 0 ? 0.25 : 1)
            return SIMD4(r, g, b, alpha)
        }
        return try LWLinearSurface(width: width, height: height, pixels: pixels, maximumBytes: pixels.count * 128)
    }
    @Test func identityKeepsPlaneBackingAndEveryHDRAlphaBit() throws {
        let fixture = try fixture(), store = try TiledFloatTestWorkspace(), plane = try store.plane(fixture)
        let result = try CameraRawSettings().develop(plane, makeBuilder: store.builder, makeScratchDirectory: store.directory)
        #expect(result.surface.manifest == plane.manifest); #expect(result.map == .identity)
        try store.compare(result.surface, fixture)
    }
    @Test(arguments: ["light", "calibration", "curve", "mixer", "grading", "texture", "clarity", "glow", "vignette", "grain", "geometry", "optics", "luminanceDetail", "colorNoise", "sharpen"])
    func allRetainedGroupsMatchReferenceAcrossBothTileSeams(_ group: String) throws {
        let input = try fixture(), store = try TiledFloatTestWorkspace(), plane = try store.plane(input)
        var s = CameraRawSettings()
        switch group {
        case "light": s.temperature = 23; s.tint = -17; s.exposure = 0.7; s.contrast = 13; s.highlights = -22; s.shadows = 19; s.whites = 8; s.blacks = -9; s.vibrance = 21; s.saturation = -12
        case "calibration": s.calibration.process = .version2; s.calibration.redHue = 28; s.calibration.blueSaturation = -17; s.calibration.shadowTint = 9
        case "curve": s.curve.rgb = CameraRawCurveSettings.mediumContrast; s.curve.shadows = 7; s.curve.refineSaturation = -13
        case "mixer": s.mixer.hue[1] = 31; s.mixer.saturation[5] = -27; s.mixer.luminance[6] = 18
        case "grading": s.grading.shadows.hue = 35; s.grading.shadows.saturation = 12; s.grading.global.luminance = 9
        case "texture": s.texture = 47
        case "clarity": s.clarity = -35; s.dehaze = 16
        case "glow": s.glow = 65; s.glowSpread = 63; s.glowRange = 24; s.glowWarmth = -31
        case "vignette": s.vignetteAmount = -43; s.vignetteMidpoint = 36; s.vignetteRoundness = 21
        case "grain": s.grainAmount = 67; s.grainSize = 39; s.grainRoughness = 82
        case "geometry": s.geometry.horizontal = 21; s.geometry.vertical = -16; s.geometry.rotate = 4; s.geometry.aspect = 24; s.geometry.scale = -9; s.geometry.constrainCrop = true
        case "optics": s.optics.distortion = 28; s.optics.removeChromaticAberration = true; s.optics.purpleAmount = 23; s.optics.vignetteAmount = -11
        case "luminanceDetail": s.detail.noiseLuminance = 77; s.detail.noiseLuminanceDetail = 81; s.detail.noiseLuminanceContrast = 41
        case "colorNoise": s.detail.noiseColor = 72; s.detail.noiseColorDetail = 31; s.detail.noiseColorSmoothness = 85
        case "sharpen": s.detail.sharpenAmount = 71; s.detail.sharpenRadius = 74; s.detail.sharpenDetail = 49; s.detail.sharpenMasking = 38
        default: throw ProjectError.invalid
        }
        let reference = try s.develop(input, seed: 913)
        let result = try s.develop(plane, seed: 913, makeBuilder: store.builder, makeScratchDirectory: store.directory)
        #expect(result.map == reference.map)
        try store.compare(result.surface, reference.surface)
        #expect(reference.surface.pixels != input.pixels)
    }
    @Test func fullFrameGrayWorldReductionMatchesCoveredReferenceInRowOrder() throws {
        let input = try fixture(), store = try TiledFloatTestWorkspace(), plane = try store.plane(input)
        let a = try CameraRawSettings.autoBalance(of: plane), b = CameraRawSettings.autoBalance(of: input)
        #expect(a?.temperature == b?.temperature); #expect(a?.tint == b?.tint)
        #expect(a != nil)
    }
    @Test func scalarRunningSumsAreBitExactAgainstFullFrameAndNotTileClamped() throws {
        let store = try TiledFloatTestWorkspace(), width = 259, height = 257
        let expected = (0..<(width * height)).map { Double((($0 % width)*3 + ($0 / width)*7) % 113) / 13 }
        let field = try LWFloatDoubleRows.create(width: width, height: height,
            workingSet: store.workingSet, directory: store.directory()) { y in Array(expected[(y*width)..<((y + 1)*width)]) }
        for radius in [1, 4, 64] {
            let result = try store.workspace.blur(field, radius: radius)
            let reference = FloatImageAdjustmentPixels.blur(expected, width: width, height: height, radius: radius)
            for y in 0..<height {
                let row = try result.read(y)
                for x in 0..<width { #expect(row.values[x].bitPattern == reference[y*width + x].bitPattern) }
            }
            #expect(try result.value(x: 255, y: 255) != expected[255*width + 255])
        }
    }
    @Test(arguments: [AdjustmentKind.hsv, .levels, .curves, .invert, .gradientMap, .blackWhite, .colorBalance, .grain, .addNoise, .exposure])
    func allPointAdjustmentsUseFullRegionGlobalCoordinates(_ kind: AdjustmentKind) throws {
        var a = LayerAdjustment(kind: kind)
        switch kind {
        case .hsv: a.hue = 13
        case .levels: a.levels.ranges[0].black = 11
        case .curves: a.curves.channels[0] = [CurvePoint(x: 0, y: 8), CurvePoint(x: 255, y: 241)]
        case .colorBalance: a.colorBalance.midCyanRed = 17
        case .grain: a.grain.amount = 43; a.grain.seed = 51
        case .addNoise: a.noiseAmount = 31; a.noiseSeed = 61
        case .exposure: a.exposure.exposure = 0.7
        default: break
        }
        let input = try fixture(), store = try TiledFloatTestWorkspace(), plane = try store.plane(input)
        let region = CGRect(x: -43, y: 81, width: 517, height: 513)
        let reference = try a.apply(input, region: region, scale: 0.75)
        let result = try a.apply(plane, region: region, scale: 0.75,
            makeBuilder: store.builder, makeScratchDirectory: store.directory)
        try store.compare(result, reference)
        #expect(reference.pixels != input.pixels)
    }
    @Test(arguments: [AdjustmentKind.gaussianBlur, .motionBlur])
    func coreImageDependencyHaloMatchesWholeOperatorAtSeams(_ kind: AdjustmentKind) throws {
        var a = LayerAdjustment(kind: kind)
        a.gaussianRadius = 7; a.motionDistance = 17; a.motionAngle = 31
        let input = try fixture(), store = try TiledFloatTestWorkspace(), plane = try store.plane(input)
        let result = try a.apply(plane, makeBuilder: store.builder, makeScratchDirectory: store.directory)
        let reference = try a.apply(input)
        // Exact operator comparison. No camera/color tolerance or clipped seam exemption.
        try store.compare(result, reference)
        #expect(reference.pixels != input.pixels)
    }
    @Test func scratchRefusesChangedNamedDirectoryAndTamperedRow() throws {
        let store = try TiledFloatTestWorkspace(), directory = try store.directory()
        let field = try LWFloatDoubleRows.create(width: 3, height: 2, workingSet: store.workingSet,
            directory: directory) { y in [Double(y), 2, 3] }
        let row = directory.appendingPathComponent("00000000.f64")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: row.path)
        try Data(repeating: 0, count: 24).write(to: row)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: row.path)
        #expect(throws: ProjectError.self) { _ = try field.read(0) }
        let original = directory.appendingPathExtension("held")
        try FileManager.default.moveItem(at: directory, to: original)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: ProjectError.self) { _ = try field.read(1) }
    }
    @Test func sharedAdmissionRefusesBeforeFieldOutputAndReleasesFailedLease() throws {
        let store = try TiledFloatTestWorkspace(limit: 64)
        #expect(throws: ProjectError.self) {
            _ = try LWFloatDoubleRows.create(width: 65, height: 2, workingSet: store.workingSet,
                directory: store.directory()) { _ in Issue.record("Output allocation must not occur before admission"); return [] }
        }
        do {
            let held = try store.workingSet.reserve(64)
            #expect(throws: ProjectError.self) { _ = try store.workingSet.reserve(1) }
            withExtendedLifetime(held) {}
        }
        let again = try store.workingSet.reserve(64)
        #expect(again.bytes == 64)
    }
    @Test func coreImageDependencyRejectsNonfiniteBeforeIntegerConversion() {
        let extent = CGRect(x: 0, y: 0, width: 259, height: 257)
        #expect(throws: ProjectError.self) { _ = try LWFloatKernelWorkspace.coreImageRange(.infinite, extent: extent) }
        #expect(throws: ProjectError.self) { _ = try LWFloatKernelWorkspace.coreImageRange(.null, extent: extent) }
        let range = try? LWFloatKernelWorkspace.coreImageRange(CGRect(x: -2, y: 250, width: 264, height: 11), extent: extent)
        #expect(range == LWFloatRange(x: 0, y: 0, width: 259, height: 7))
    }
}

@MainActor
struct TiledFloatAdmissionTests {
    @Test func cancelledDevelopmentRefusesBeforeAnyOutputFactory() async throws {
        let store = try TiledFloatTestWorkspace()
        let input = try LWLinearSurface(width: 2, height: 1,
            pixels: [SIMD4(Float(bitPattern: 0x3f000001), 2, -0.125, 0.25), SIMD4(7, -3, 9, 0)], maximumBytes: 256)
        let plane = try store.plane(input)
        var settings = CameraRawSettings(); settings.exposure = 1
        let before = try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
        let task = Task { @MainActor in
            try settings.apply(plane, makeBuilder: store.builder, makeScratchDirectory: store.directory)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted() == before)
    }
    @Test func sharedTileAndOutputAdmissionCannotFallBackToWholePlane() throws {
        let store = try TiledFloatTestWorkspace(limit: 4 * 1024 * 1024)
        let pixels = [SIMD4<Float>](repeating: SIMD4(2, -0.2, 0.25, 0.5), count: 259 * 257)
        let input = try LWLinearSurface(width: 259, height: 257, pixels: pixels, maximumBytes: pixels.count * 128)
        let plane = try store.plane(input)
        var settings = CameraRawSettings(); settings.exposure = 1
        #expect(throws: ProjectError.self) {
            _ = try settings.apply(plane, makeBuilder: store.builder, makeScratchDirectory: store.directory)
        }
        // The failed allocation cannot mutate the immutable input or its full extent.
        #expect(plane.width == 259 && plane.height == 257)
        let row = try plane.read(LWFloatRange(x: 258, y: 256, width: 1, height: 1))
        #expect(row.surface.pixels == [SIMD4(2, -0.2, 0.25, 0.5)])
    }
    @Test func globalExposureReferenceKeepsSubByteHDRAndHiddenColorAtTileBoundary() throws {
        let store = try TiledFloatTestWorkspace()
        let pixels = (0..<259).map { x -> SIMD4<Float> in
            SIMD4(Float(bitPattern: 0x3f000001 + UInt32(x)), 2.25, -0.125, x == 256 ? 0 : 0.25)
        }
        let input = try LWLinearSurface(width: 259, height: 1, pixels: pixels, maximumBytes: pixels.count * 128)
        let plane = try store.plane(input)
        var s = CameraRawSettings(); s.exposure = 1
        let output = try s.apply(plane, makeBuilder: store.builder, makeScratchDirectory: store.directory)
        let row = try output.read(LWFloatRange(x: 0, y: 0, width: 259, height: 1))
        for x in 0..<259 {
            let expected = x == 256 ? pixels[x] : SIMD4(pixels[x].x * 2, 4.5, -0.25, 0.25)
            for channel in 0..<4 { #expect(row.surface.pixels[x][channel].bitPattern == expected[channel].bitPattern) }
        }
    }
}
