import XCTest
import Foundation
import AppKit
import CryptoKit

final class CompositorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreateCanvasAndNavigation() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["newCanvasWelcome"].click()
        let width = app.textFields["widthInput"]
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("0")
        XCTAssertFalse(app.buttons["createCanvas"].isEnabled)
        width.typeKey("a", modifierFlags: .command)
        width.typeText("1200")
        let height = app.textFields["heightInput"]
        height.click()
        height.typeKey("a", modifierFlags: .command)
        height.typeText("800")
        app.buttons["createCanvas"].click()
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
        app.buttons["actualPixels"].click()
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "100%")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "125%")
        app.buttons["fitCanvas"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor foundation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("n", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Explicit macOS baseline: includes XCTest launch/idle/accessibility overhead.
        let app = XCUIApplication()
        var samples: [Double] = []
        for _ in 0..<5 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            XCTAssertTrue(app.buttons["newCanvasWelcome"].waitForExistence(timeout: 5))
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        print("LAUNCH_TO_READY_SECONDS: \(samples)")
        print("LAUNCH_TO_READY_MEDIAN: \(samples.sorted()[2])")
    }
}

private enum S47ScreenshotComparator {
    struct Tolerance {
        let maxChannelDelta: UInt8
        let maxChangedFraction: Double
    }

    struct RGBA8 {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    struct Measurement: Codable {
        let width: Int
        let height: Int
        let maximumChannelDelta: UInt8
        let changedPixelFraction: Double
    }

    static func requiredRunnerValue(_ environment: [String: String], _ name: String) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw NSError(domain: "LensWorks.S47", code: 1, userInfo: [NSLocalizedDescriptionKey: "CI must transport TEST_RUNNER_" + name + " so Xcode delivers " + name + " to the UI test runner."])
        }
        return value
    }

    static func requiredTolerance(_ environment: [String: String]) throws -> Tolerance {
        let delta = try requiredRunnerValue(environment, "LW_S47_MAX_CHANNEL_DELTA")
        let fraction = try requiredRunnerValue(environment, "LW_S47_MAX_CHANGED_PIXEL_FRACTION")
        guard let parsedDelta = UInt8(delta), let parsedFraction = Double(fraction),
              parsedFraction.isFinite, (0...1).contains(parsedFraction) else {
            throw NSError(domain: "LensWorks.S47", code: 2, userInfo: [NSLocalizedDescriptionKey: "CI must declare bounded TEST_RUNNER_LW_S47_MAX_CHANNEL_DELTA and TEST_RUNNER_LW_S47_MAX_CHANGED_PIXEL_FRACTION; this tour has no implicit screenshot tolerance."])
        }
        return Tolerance(maxChannelDelta: parsedDelta, maxChangedFraction: parsedFraction)
    }

    static func requireWindowGeometry(pixelWidth: Int, pixelHeight: Int, frame: CGRect) throws {
        guard pixelWidth > 0, pixelHeight > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else {
            throw NSError(domain: "LensWorks.S47", code: 11, userInfo: [NSLocalizedDescriptionKey: "S47 capture requires finite nonempty window and image geometry."])
        }
        // AX frames use points; PNG dimensions use backing pixels. Allow only pixel rounding.
        let scale = Double(pixelWidth) / Double(frame.width)
        guard scale.isFinite, scale > 0,
              abs(Double(pixelHeight) - Double(frame.height) * scale) <= 1 else {
            throw NSError(domain: "LensWorks.S47", code: 12, userInfo: [NSLocalizedDescriptionKey: "S47 capture image geometry must correspond to its loaded editor window."])
        }
    }

    static func normalizedRGBA8(_ screenshot: XCUIScreenshot) throws -> RGBA8 {
        guard let image = NSImage(data: screenshot.pngRepresentation),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0,
              source.bitsPerComponent == 8,
              source.bitsPerPixel >= 24 else {
            throw NSError(domain: "LensWorks.S47", code: 2, userInfo: [NSLocalizedDescriptionKey: "S47 screenshot must decode as a nonempty 8-bit RGB-family image."])
        }
        let bytesPerRow = source.width * 4
        var bytes = [UInt8](repeating: 0, count: source.height * bytesPerRow)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                  let context = CGContext(data: base, width: source.width, height: source.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return true
        }
        guard rendered else { throw NSError(domain: "LensWorks.S47", code: 3, userInfo: [NSLocalizedDescriptionKey: "S47 could not normalize screenshot bytes to dense RGBA8."]) }
        return RGBA8(width: source.width, height: source.height, bytes: bytes)
    }

    static func measurement(_ first: RGBA8, _ second: RGBA8) throws -> Measurement {
        guard first.width > 0, first.height > 0, first.width == second.width, first.height == second.height,
              first.bytes.count == first.width * first.height * 4,
              second.bytes.count == second.width * second.height * 4 else {
            throw NSError(domain: "LensWorks.S47", code: 4, userInfo: [NSLocalizedDescriptionKey: "S47 screenshots must normalize to equal dense RGBA8 layouts."])
        }
        var changedPixels = 0
        var maximum: UInt8 = 0
        for pixel in 0..<(first.width * first.height) {
            var changed = false
            for channel in 0..<4 {
                let offset = pixel * 4 + channel
                let delta = UInt8(abs(Int(first.bytes[offset]) - Int(second.bytes[offset])))
                maximum = max(maximum, delta)
                changed = changed || delta != 0
            }
            changedPixels += changed ? 1 : 0
        }
        return Measurement(width: first.width, height: first.height, maximumChannelDelta: maximum, changedPixelFraction: Double(changedPixels) / Double(first.width * first.height))
    }

    static func requireWithin(_ measurement: Measurement, tolerance: Tolerance) throws {
        guard measurement.maximumChannelDelta <= tolerance.maxChannelDelta else {
            throw NSError(domain: "LensWorks.S47", code: 5, userInfo: [NSLocalizedDescriptionKey: "maximum screenshot channel delta \(measurement.maximumChannelDelta) exceeds \(tolerance.maxChannelDelta)"])
        }
        guard measurement.changedPixelFraction <= tolerance.maxChangedFraction else {
            throw NSError(domain: "LensWorks.S47", code: 6, userInfo: [NSLocalizedDescriptionKey: "changed screenshot fraction \(measurement.changedPixelFraction) exceeds \(tolerance.maxChangedFraction)"])
        }
    }
}

extension CompositorUITests {
    private struct S47WindowCaptureDomain: Codable {
        let schema: String
        let run: Int
        let receiver: String
        let windowIdentifier: String
        let windowLabel: String
        let windowFramePoints: [Double]
        let loadedMarkerIdentifier: String
        let loadedMarkerValue: String
        let pngSHA256: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct S47TourCapture {
        let run: Int
        let screenshot: XCUIScreenshot
        let originalHashes: [String: String]
    }

    private func s47SHA256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func s47FixtureHashes(_ root: URL) throws -> [String: String] {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-manifest.json"))) as? [String: Any]
        let photos = try XCTUnwrap(manifest?["photos"] as? [[String: Any]])
        var hashes: [String: String] = [:]
        for photo in photos {
            let path = try XCTUnwrap(photo["path"] as? String)
            let expected = try XCTUnwrap(photo["sha256"] as? String)
            let actual = try s47SHA256(root.appendingPathComponent(path))
            XCTAssertEqual(actual, expected, "fixture original must match its manifest before and after every tour")
            hashes[path] = actual
        }
        return hashes
    }

    @MainActor
    private func runS47Tour(run: Int, fixture: URL, worker: String, decode: String, configuration: String) throws -> S47TourCapture {
        let before = try s47FixtureHashes(fixture)
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            let state = app.state
            guard state == .runningForeground || state == .runningBackground else { return }
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "tour \(run) failure teardown must observe ordinary public Quit")
        }
        let output = fixture.appendingPathComponent("WorkingVersions-\(run)")
        let catalog = output.appendingPathComponent("Demo.catalog")
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard outputAttributes[.type] as? FileAttributeType == .typeDirectory,
              (outputAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
            throw NSError(domain: "LensWorks.S47", code: 10, userInfo: [NSLocalizedDescriptionKey: "The fixture owner must prepare each S47 tour's real, empty, private working version folder."])
        }
        app.launchEnvironment["XCTestConfigurationFilePath"] = configuration
        app.launchEnvironment["LW_CATALOG_TEST_WORKER"] = worker
        app.launchEnvironment["LW_CATALOG_TEST_DECODE_WORKER"] = decode
        app.launchArguments = ["--lensworks-catalog", catalog.path, "--lensworks-create-catalog", "--lensworks-import", fixture.appendingPathComponent("photos").path, "--lensworks-output", output.path]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "tour \(run) must activate its owned UI window")
        let grid = app.scrollViews["LensWorks.catalogGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "tour \(run) must reach the native catalog grid")
        let photo = grid.staticTexts["LensWorks.catalogAsset.single-harbor.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 30), "tour \(run) must expose the generated original")
        photo.doubleClick()
        let loaded = app.staticTexts["LensWorks.loadedEditorDocument"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 20), "tour \(run) must expose the selected asset through its current working version and editor document")
        XCTAssertEqual(loaded.value as? String, "single-harbor.png|master|160x120", "tour \(run) must bind the expected original identity to the active editor document")
        let editorWindows = app.windows.containing(.staticText, identifier: "LensWorks.loadedEditorDocument")
        XCTAssertEqual(editorWindows.count, 1, "tour \(run) must bind exactly one loaded editor window")
        guard editorWindows.count == 1 else {
            throw NSError(domain: "LensWorks.S47", code: 13, userInfo: [NSLocalizedDescriptionKey: "S47 capture cannot select an ambiguous or missing loaded editor window."])
        }
        let editorWindow = editorWindows.element(boundBy: 0)
        let windowLoaded = editorWindow.staticTexts["LensWorks.loadedEditorDocument"]
        XCTAssertTrue(windowLoaded.exists)
        XCTAssertEqual(windowLoaded.value as? String, "single-harbor.png|master|160x120")
        // Keep each catalog and working version exclusive while using the same visible names.
        // The double-click above still creates the ordinary UUID-named working version first.
        let createdProjects = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).filter { $0.pathExtension == "comp" }
        XCTAssertEqual(createdProjects.count, 1, "tour \(run) must create exactly one working version through the photo route")
        guard createdProjects.count == 1 else {
            throw NSError(domain: "LensWorks.S47", code: 14, userInfo: [NSLocalizedDescriptionKey: "The fresh tour must contain exactly its newly created working version."])
        }
        let createdProject = createdProjects[0]
        let originalRecordBytes = try Data(contentsOf: createdProject.appendingPathComponent("LensWorks.json"))
        let originalRecord = try XCTUnwrap(try JSONSerialization.jsonObject(with: originalRecordBytes) as? [String: Any])
        let namedProject = output.appendingPathComponent("single-harbor.comp")
        guard !FileManager.default.fileExists(atPath: namedProject.path) else {
            throw NSError(domain: "LensWorks.S47", code: 15, userInfo: [NSLocalizedDescriptionKey: "The deterministic Save As destination must be new."])
        }
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists && fileMenu.isEnabled, "tour \(run) must admit the ordinary File menu")
        fileMenu.click()
        let saveAs = app.menuBars.menuItems["Save As…"]
        XCTAssertTrue(saveAs.exists && saveAs.isEnabled, "tour \(run) must admit the public Save As command")
        saveAs.click()
        let saveSheet = editorWindow.sheets.firstMatch
        XCTAssertTrue(saveSheet.waitForExistence(timeout: 10), "tour \(run) must use the public Save As sheet")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = saveSheet.sheets["GoToWindow"]
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 10), "tour \(run) must admit the public Go to Folder sheet")
        let pathField = goToSheet.textFields["PathTextField"]
        XCTAssertTrue(pathField.exists && pathField.isEnabled)
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(output.path)
        XCTAssertEqual(pathField.value as? String, output.path, "Go to Folder must contain this tour's exact owned destination")
        pathField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(goToSheet.waitForNonExistence(timeout: 10), "tour \(run) must complete folder navigation before accessing Save As")
        let nameField = saveSheet.textFields["saveAsNameTextField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, createdProject.lastPathComponent, "Save As must name the current working project")
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(namedProject.lastPathComponent)
        saveSheet.buttons["Save"].click()
        let savedEditor = editorWindows.matching(NSPredicate(format: "title == %@", namedProject.deletingPathExtension().lastPathComponent)).firstMatch
        XCTAssertTrue(savedEditor.waitForExistence(timeout: 20), "tour \(run) must publish the exact saved editor title before capture")
        XCTAssertEqual(editorWindow.title, namedProject.deletingPathExtension().lastPathComponent, "the same loaded editor window must own the saved document title")
        let savedRecord = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: namedProject.appendingPathComponent("LensWorks.json"))) as? [String: Any])
        for field in ["schema", "catalogPath", "photoID", "originalPath", "originalNativePath", "originalVariantKey"] {
            XCTAssertEqual(try XCTUnwrap(savedRecord[field] as? NSObject), try XCTUnwrap(originalRecord[field] as? NSObject), "Save As must retain the complete source field \(field)")
        }
        XCTAssertNotEqual(try XCTUnwrap(savedRecord["id"] as? String), try XCTUnwrap(originalRecord["id"] as? String), "Save As must create a distinct working version")
        XCTAssertEqual(savedRecord["name"] as? String, "single-harbor")
        XCTAssertEqual(try Data(contentsOf: createdProject.appendingPathComponent("LensWorks.json")), originalRecordBytes, "Save As must preserve the created working version's source record")
        XCTAssertEqual(windowLoaded.value as? String, "single-harbor.png|master|160x120", "Save As must retain the selected original and master identity")
        let fit = editorWindow.buttons["fitCanvas"]
        XCTAssertTrue(fit.waitForExistence(timeout: 10) && fit.isEnabled, "tour \(run) must reach an enabled editor state")
        fit.click()
        let frame = editorWindow.frame
        let screenshot = editorWindow.screenshot()
        let image = try S47ScreenshotComparator.normalizedRGBA8(screenshot)
        try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: image.width, pixelHeight: image.height, frame: frame)
        XCTAssertEqual(editorWindow.frame, frame, "tour \(run) must retain the capture receiver's window geometry")
        XCTAssertEqual(windowLoaded.value as? String, "single-harbor.png|master|160x120", "tour \(run) must retain loaded source identity at capture")
        let domain = S47WindowCaptureDomain(schema: "lensworks.s47.editor-window-capture-domain.v1", run: run, receiver: "XCUIElement.window", windowIdentifier: editorWindow.identifier, windowLabel: editorWindow.label, windowFramePoints: [Double(frame.origin.x), Double(frame.origin.y), Double(frame.width), Double(frame.height)], loadedMarkerIdentifier: "LensWorks.loadedEditorDocument", loadedMarkerValue: try XCTUnwrap(windowLoaded.value as? String), pngSHA256: SHA256.hash(data: screenshot.pngRepresentation).map { String(format: "%02x", $0) }.joined(), pixelWidth: image.width, pixelHeight: image.height)
        let domainAttachment = XCTAttachment(data: try JSONEncoder().encode(domain), uniformTypeIdentifier: "public.json")
        domainAttachment.name = "S47 editor capture domain run \(run)"
        domainAttachment.lifetime = .keepAlways
        add(domainAttachment)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "S47 editor run \(run)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(try s47FixtureHashes(fixture), before, "tour \(run) must not alter fixture originals before the public Quit")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "tour \(run) must end through ordinary public Quit")
        let afterQuit = try s47FixtureHashes(fixture)
        XCTAssertEqual(afterQuit, before, "tour \(run) must retain every source original after observed public Quit")
        return S47TourCapture(run: run, screenshot: screenshot, originalHashes: afterQuit)
    }

    @MainActor
    func testS47DeterministicDemoCatalogTourOpensPhotoEditorAndComparesConsecutiveScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_S47_FIXTURE_ROOT")
        let worker = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_CATALOG_TEST_WORKER")
        let decode = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_CATALOG_TEST_DECODE_WORKER")
        let configuration = try XCTUnwrap(environment["XCTestConfigurationFilePath"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: worker))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: decode))
        let tolerance = try S47ScreenshotComparator.requiredTolerance(environment)
        let fixture = URL(fileURLWithPath: root)
        let first = try runS47Tour(run: 1, fixture: fixture, worker: worker, decode: decode, configuration: configuration)
        let second = try runS47Tour(run: 2, fixture: fixture, worker: worker, decode: decode, configuration: configuration)
        XCTAssertEqual(first.originalHashes, second.originalHashes, "both complete tours must retain identical fixture originals")
        let measurement = try S47ScreenshotComparator.measurement(try S47ScreenshotComparator.normalizedRGBA8(first.screenshot), try S47ScreenshotComparator.normalizedRGBA8(second.screenshot))
        let evidence = XCTAttachment(string: "S47 two-tour measurement run1=\(first.run) run2=\(second.run) maxChannelDelta=\(measurement.maximumChannelDelta) changedPixelFraction=\(measurement.changedPixelFraction)")
        evidence.name = "S47 two-tour comparison measurement"
        evidence.lifetime = .keepAlways
        add(evidence)
        try S47ScreenshotComparator.requireWithin(measurement, tolerance: tolerance)
    }

    private struct S47CalibrationRecord: Codable {
        let schema: String
        let status: String
        let runs: [Int]
        let originalHashes: [String: String]
        let measurement: S47ScreenshotComparator.Measurement
    }

    @MainActor
    func testS47DeterministicDemoCatalogTourMeasuresTwoRunsWithoutToleranceAcceptance() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_S47_FIXTURE_ROOT")
        let worker = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_CATALOG_TEST_WORKER")
        let decode = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_CATALOG_TEST_DECODE_WORKER")
        let configuration = try XCTUnwrap(environment["XCTestConfigurationFilePath"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: worker))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: decode))
        let fixture = URL(fileURLWithPath: root)
        let first = try runS47Tour(run: 1, fixture: fixture, worker: worker, decode: decode, configuration: configuration)
        let second = try runS47Tour(run: 2, fixture: fixture, worker: worker, decode: decode, configuration: configuration)
        XCTAssertEqual(first.originalHashes, second.originalHashes, "both complete tours must retain identical fixture originals")
        let measurement = try S47ScreenshotComparator.measurement(try S47ScreenshotComparator.normalizedRGBA8(first.screenshot), try S47ScreenshotComparator.normalizedRGBA8(second.screenshot))
        let record = S47CalibrationRecord(schema: "lensworks.s47.same-host-screenshot-calibration.v1", status: "MEASURED_NOT_ACCEPTED", runs: [first.run, second.run], originalHashes: first.originalHashes, measurement: measurement)
        let encoded = try JSONEncoder().encode(record)
        let reportAttachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        reportAttachment.name = "S47-calibration-report.json"
        reportAttachment.lifetime = .keepAlways
        add(reportAttachment)
        let evidence = XCTAttachment(string: "S47 calibration measurement run1=\(first.run) run2=\(second.run) maxChannelDelta=\(measurement.maximumChannelDelta) changedPixelFraction=\(measurement.changedPixelFraction) status=MEASURED_NOT_ACCEPTED")
        evidence.name = "S47 two-tour calibration measurement"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testS47WindowCaptureGeometryHonorsBackingScaleAndRejectsWholeDisplay() throws {
        let window = CGRect(x: 40, y: 60, width: 1000, height: 700)
        XCTAssertNoThrow(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 1000, pixelHeight: 700, frame: window))
        XCTAssertNoThrow(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 2000, pixelHeight: 1400, frame: window))
        XCTAssertNoThrow(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 1500, pixelHeight: 1051, frame: window))
        XCTAssertThrowsError(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 3456, pixelHeight: 2234, frame: window))
        XCTAssertThrowsError(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 0, pixelHeight: 700, frame: window))
        XCTAssertThrowsError(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 1000, pixelHeight: 700, frame: .zero))
        XCTAssertThrowsError(try S47ScreenshotComparator.requireWindowGeometry(pixelWidth: 1000, pixelHeight: 700, frame: CGRect(x: CGFloat.infinity, y: 0, width: 1000, height: 700)))
    }

    func testS47ComparatorControlsToleranceAndIndependentFraction() throws {
        XCTAssertThrowsError(try S47ScreenshotComparator.requiredTolerance([:]))
        XCTAssertThrowsError(try S47ScreenshotComparator.requiredTolerance(["LW_S47_MAX_CHANNEL_DELTA": "not-a-byte", "LW_S47_MAX_CHANGED_PIXEL_FRACTION": "0.1"]))
        let base = S47ScreenshotComparator.RGBA8(width: 2, height: 1, bytes: [1, 2, 3, 255, 4, 5, 6, 255])
        let identical = try S47ScreenshotComparator.measurement(base, base)
        XCTAssertEqual(identical.maximumChannelDelta, 0)
        XCTAssertEqual(identical.changedPixelFraction, 0)
        let changed = S47ScreenshotComparator.RGBA8(width: 2, height: 1, bytes: [2, 2, 3, 255, 4, 5, 6, 255])
        let measurement = try S47ScreenshotComparator.measurement(base, changed)
        XCTAssertEqual(measurement.maximumChannelDelta, 1)
        XCTAssertEqual(measurement.changedPixelFraction, 0.5)
        XCTAssertThrowsError(try S47ScreenshotComparator.requireWithin(measurement, tolerance: .init(maxChannelDelta: 0, maxChangedFraction: 1)))
        XCTAssertThrowsError(try S47ScreenshotComparator.requireWithin(measurement, tolerance: .init(maxChannelDelta: 1, maxChangedFraction: 0.49)))
    }

    func testS47ComparatorControlsRejectInvalidDenseLayout() {
        let valid = S47ScreenshotComparator.RGBA8(width: 1, height: 1, bytes: [0, 0, 0, 255])
        let malformed = S47ScreenshotComparator.RGBA8(width: 1, height: 1, bytes: [0, 0, 0])
        let mismatch = S47ScreenshotComparator.RGBA8(width: 2, height: 1, bytes: [0, 0, 0, 255, 0, 0, 0, 255])
        XCTAssertThrowsError(try S47ScreenshotComparator.measurement(valid, malformed))
        XCTAssertThrowsError(try S47ScreenshotComparator.measurement(valid, mismatch))
    }
}
