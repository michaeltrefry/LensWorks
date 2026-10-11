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

    /// Captures the window only once two consecutive frames are identical, so a press, hover
    /// or scroller transition still in flight is never frozen into the comparison.
    @MainActor
    private func s47QuiescentScreenshot(_ window: XCUIElement) throws -> XCUIScreenshot {
        var previous = window.screenshot()
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let next = window.screenshot()
            if try S47ScreenshotComparator.normalizedRGBA8(next).bytes == S47ScreenshotComparator.normalizedRGBA8(previous).bytes { return next }
            previous = next
        }
        throw NSError(domain: "LensWorks.S47", code: 16, userInfo: [NSLocalizedDescriptionKey: "The editor window never settled on a stable frame to capture."])
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
            // Freeze the time-dependent chrome both tours would otherwise capture at different
            // phases: overlay scrollers that fade out, a blinking insertion point and window animations.
            + ["-AppleShowScrollBars", "Always", "-NSTextInsertionPointBlinkPeriodOn", "1000000000", "-NSTextInsertionPointBlinkPeriodOff", "0",
               "-NSAutomaticWindowAnimationsEnabled", "NO"]
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
        let screenshot = try s47QuiescentScreenshot(editorWindow)
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

    // Actual S38 UI routes use new fixture-owner prepared directories and read native packages.
    // They never invoke the registry directly or change the application's defaults.
    private struct S38Package {
        let manifest: NSDictionary
        let source: NSDictionary
        let imageHashes: [String: String]
        var layerID: String { manifest["activeLayerID"] as! String }
        var layer: [String: Any] { (manifest["layers"] as! [[String: Any]]).first { $0["id"] as? String == layerID }! }
        var opacity: Double { (layer["opacity"] as? NSNumber)?.doubleValue ?? 1 }
        var visible: Bool { (layer["isVisible"] as! NSNumber).boolValue }
    }
    private struct S38UIContext {
        let app: XCUIApplication
        let editor: XCUIElement
        let fixture: URL
        let project: URL
        let originals: [String: String]
    }
    private func s38Object(_ url: URL) throws -> NSDictionary {
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary else {
            throw NSError(domain: "LensWorks.S38", code: 1)
        }
        return object
    }
    private func s38ReadPackage(_ url: URL) throws -> S38Package {
        let manifest = try s38Object(url.appendingPathComponent("manifest.json"))
        let source = try s38Object(url.appendingPathComponent("LensWorks.json"))
        guard (manifest["version"] as? NSNumber)?.intValue == 12,
              let document = manifest["documentID"] as? String, UUID(uuidString: document) != nil,
              let active = manifest["activeLayerID"] as? String, UUID(uuidString: active) != nil,
              let layers = manifest["layers"] as? [[String: Any]], layers.count == 1,
              layers[0]["id"] as? String == active, layers[0]["isVisible"] is NSNumber,
              let working = manifest["workingVersionID"] as? String, working == source["id"] as? String else { throw NSError(domain: "LensWorks.S38", code: 2) }
        var images: [String: String] = [:]
        let imagesRoot = url.appendingPathComponent("images")
        for file in try FileManager.default.contentsOfDirectory(at: imagesRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw NSError(domain: "LensWorks.S38", code: 4) }
            images["images/" + file.lastPathComponent] = try s47SHA256(file)
        }
        return S38Package(manifest: manifest, source: source, imageHashes: images)
    }
    /// The enabled Undo/Redo item titles of the public Edit menu: the observable session history.
    @MainActor
    private func s38History(_ context: S38UIContext) -> [String] {
        let edit = context.app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(edit.exists); edit.click()
        let items = edit.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo' OR title BEGINSWITH 'Redo'"))
        let titles = (0..<items.count).map { items.element(boundBy: $0) }.filter(\.isEnabled).map(\.title)
        context.app.typeKey(.escape, modifierFlags: [])
        return titles
    }
    @MainActor
    private func s38Open(run: Int) throws -> S38UIContext {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_S38_FIXTURE_ROOT"))
        let worker = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_CATALOG_TEST_WORKER")
        let decode = try S47ScreenshotComparator.requiredRunnerValue(environment, "LW_CATALOG_TEST_DECODE_WORKER")
        let configuration = try XCTUnwrap(environment["XCTestConfigurationFilePath"])
        let before = try s47FixtureHashes(fixture)
        let output = fixture.appendingPathComponent("WorkingVersions-\(run)")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              output.resolvingSymlinksInPath().path == output.path,
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
            throw NSError(domain: "LensWorks.S38", code: 5, userInfo: [NSLocalizedDescriptionKey: "The fixture owner must prepare three new real empty private working folders."])
        }
        let catalog = output.appendingPathComponent("Demo.catalog")
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            guard app.state == .runningForeground || app.state == .runningBackground else { return }
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "S38 failure teardown uses public Quit on the same owned application")
        }
        app.launchEnvironment["XCTestConfigurationFilePath"] = configuration
        app.launchEnvironment["LW_CATALOG_TEST_WORKER"] = worker
        app.launchEnvironment["LW_CATALOG_TEST_DECODE_WORKER"] = decode
        app.launchArguments = ["--lensworks-catalog", catalog.path, "--lensworks-create-catalog", "--lensworks-import", fixture.appendingPathComponent("photos").path, "--lensworks-output", output.path]
        app.launch(); app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        let grid = app.scrollViews["LensWorks.catalogGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        let photo = grid.staticTexts["LensWorks.catalogAsset.single-harbor.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 30)); photo.doubleClick()
        let loaded = app.staticTexts["LensWorks.loadedEditorDocument"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 20))
        XCTAssertEqual(loaded.value as? String, "single-harbor.png|master|160x120")
        let editors = app.windows.containing(.staticText, identifier: "LensWorks.loadedEditorDocument")
        XCTAssertEqual(editors.count, 1)
        guard editors.count == 1 else { throw NSError(domain: "LensWorks.S38", code: 6) }
        let projects = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).filter { $0.pathExtension == "comp" }
        XCTAssertEqual(projects.count, 1)
        let project = try XCTUnwrap(projects.first)
        let package = try s38ReadPackage(project)
        XCTAssertEqual(package.source["schema"] as? NSNumber, 1)
        XCTAssertEqual(package.source["catalogPath"] as? String, catalog.path)
        XCTAssertEqual(package.source["originalPath"] as? String, fixture.appendingPathComponent("photos/single-harbor.png").path)
        let key = try XCTUnwrap(package.source["originalVariantKey"] as? NSDictionary)
        XCTAssertEqual(key["variant_id"] as? String, "master")
        XCTAssertEqual(key["asset_id"] as? String, package.source["photoID"] as? String)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(package.source["photoID"] as? String)))
        let nativePath = try XCTUnwrap(package.source["originalNativePath"] as? NSDictionary)
        XCTAssertEqual(nativePath["encoding"] as? String, "UnixBytes")
        XCTAssertEqual(nativePath["units"] as? [UInt8], Array(fixture.appendingPathComponent("photos/single-harbor.png").path.utf8))
        return S38UIContext(app: app, editor: editors.element(boundBy: 0), fixture: fixture, project: project, originals: before)
    }
    @MainActor
    private func s38Choose(_ label: String, menu: String, in context: S38UIContext) {
        let parent = context.app.menuBars.menuBarItems[menu]
        XCTAssertTrue(parent.exists && parent.isEnabled); parent.click()
        let item = context.app.menuBars.menuItems[label]
        XCTAssertTrue(item.waitForExistence(timeout: 10) && item.isEnabled); item.click()
    }
    @MainActor
    private func s38Saved(_ context: S38UIContext, matching: @escaping (S38Package) -> Bool) throws -> S38Package {
        s38Choose("Save", menu: "File", in: context)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let snapshot = try? self.s38ReadPackage(context.project) else { return false }
            return matching(snapshot)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, "Public Save must publish the exact native package state")
        let result = try s38ReadPackage(context.project)
        XCTAssertTrue(matching(result)); return result
    }
    private func s38Conserved(_ before: S38Package, _ after: S38Package, field: String? = nil, value: Any? = nil) {
        let expected = before.manifest.mutableCopy() as! NSMutableDictionary
        if let field, let value {
            var layers = expected["layers"] as! [[String: Any]]
            let index = layers.firstIndex { $0["id"] as? String == before.layerID }!
            layers[index][field] = value; expected["layers"] = layers
        }
        XCTAssertEqual(after.manifest, expected, "Only the admitted field of the same native layer may change")
        XCTAssertEqual(after.source, before.source, "Full working-version source, native path, VariantKey and identity must remain unchanged")
        XCTAssertEqual(after.imageHashes, before.imageHashes, "Every native image backing must retain whole bytes")
    }
    @MainActor
    private func s38Finish(_ context: S38UIContext, expected: S38Package) throws {
        XCTAssertEqual(context.editor.staticTexts["LensWorks.loadedEditorDocument"].value as? String, "single-harbor.png|master|160x120")
        XCTAssertEqual(try s47FixtureHashes(context.fixture), context.originals)
        context.app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(context.app.wait(for: .notRunning, timeout: 15))
        let terminal = try s38ReadPackage(context.project)
        XCTAssertEqual(terminal.manifest, expected.manifest); XCTAssertEqual(terminal.source, expected.source)
        XCTAssertEqual(terminal.imageHashes, expected.imageHashes)
        XCTAssertEqual(try s47FixtureHashes(context.fixture), context.originals)
        let evidence: [String: Any] = ["schema": "lensworks.s38.native-ui-package.v2", "project": context.project.path, "manifest": terminal.manifest, "workingSource": terminal.source, "wholeImageHashes": terminal.imageHashes, "originalHashes": context.originals]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "S38 native terminal package " + context.project.lastPathComponent
        attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    private func s38VisibilityShortcut(_ context: S38UIContext) throws -> String {
        s38Choose("Keyboard Shortcuts…", menu: "Edit", in: context)
        let panel = context.app.dialogs["keyboardShortcuts"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let search = panel.textFields["Search shortcuts"]
        XCTAssertTrue(search.exists); search.click(); search.typeText("Hide/Show Layer")
        let recorder = panel.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[⌃⌥⇧⌘]*(?:.|Delete|Return|Esc|Tab|Space)$"))
        XCTAssertEqual(recorder.count, 1, "The exact registered visibility row must have one effective chord")
        guard recorder.count == 1 else { throw NSError(domain: "LensWorks.S38", code: 7) }
        let chord = recorder.element(boundBy: 0).label
        panel.buttons["Cancel"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10)); return chord
    }
    @MainActor
    private func s38TypeShortcut(_ label: String, on app: XCUIApplication) throws {
        var key = label; var modifiers: XCUIElement.KeyModifierFlags = []
        for (symbol, flag) in [("⌃", XCUIElement.KeyModifierFlags.control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)] {
            if key.hasPrefix(symbol) { modifiers.insert(flag); key.removeFirst() }
        }
        switch key {
        case "Delete": app.typeKey(.delete, modifierFlags: modifiers)
        case "Return": app.typeKey(.return, modifierFlags: modifiers)
        case "Esc": app.typeKey(.escape, modifierFlags: modifiers)
        case "Tab": app.typeKey(.tab, modifierFlags: modifiers)
        case "Space": app.typeKey(.space, modifierFlags: modifiers)
        case "←": app.typeKey(.leftArrow, modifierFlags: modifiers)
        case "→": app.typeKey(.rightArrow, modifierFlags: modifiers)
        case "↓": app.typeKey(.downArrow, modifierFlags: modifiers)
        case "↑": app.typeKey(.upArrow, modifierFlags: modifiers)
        default:
            guard key.count == 1 else { throw NSError(domain: "LensWorks.S38", code: 8) }
            app.typeKey(key.lowercased(), modifierFlags: modifiers)
        }
    }
    @MainActor
    func testS38LayerMenuAndEffectiveShortcutShareVisibilityAndSingleUndo() throws {
        let context = try s38Open(run: 1)
        let baseline = try s38Saved(context) { $0.visible && $0.opacity == 1 }
        let chord = try s38VisibilityShortcut(context)
        let layerMenu = context.app.menuBars.menuBarItems["Layer"]
        layerMenu.click()
        let hide = layerMenu.menuItems["Hide Layer"]
        XCTAssertTrue(hide.exists && hide.isEnabled); XCTAssertEqual(hide.title, "Hide Layer"); hide.click()
        let hidden = try s38Saved(context) { !$0.visible }
        s38Conserved(baseline, hidden, field: "isVisible", value: false)
        XCTAssertTrue(s38History(context).contains("Undo Hide Layer"))
        s38Choose("Undo Hide Layer", menu: "Edit", in: context)
        let undone = try s38Saved(context) { $0.visible }
        s38Conserved(baseline, undone); XCTAssertTrue(s38History(context).contains("Redo Hide Layer"))
        context.editor.buttons["fitCanvas"].click()
        try s38TypeShortcut(chord, on: context.app)
        let shortcutHidden = try s38Saved(context) { !$0.visible }
        s38Conserved(baseline, shortcutHidden, field: "isVisible", value: false)
        let afterShortcut = s38History(context)
        XCTAssertTrue(afterShortcut.contains("Undo Hide Layer"))
        XCTAssertFalse(afterShortcut.contains { $0.hasPrefix("Redo") }, "The shortcut records a new step, replacing the redo")
        s38Choose("Undo Hide Layer", menu: "Edit", in: context)
        let final = try s38Saved(context) { $0.visible }
        s38Conserved(baseline, final); try s38Finish(context, expected: final)
    }
    @MainActor
    func testS38OpacityLiveBurstCoalescesAndEscapePreservesStartingHistory() throws {
        let context = try s38Open(run: 2)
        let baseline = try s38Saved(context) { $0.visible && $0.opacity == 1 }
        let percent = context.editor.textFields["Opacity percent"]
        XCTAssertTrue(percent.exists && percent.isEnabled); percent.click()
        for value in ["99", "98", "97"] { percent.typeKey(.downArrow, modifierFlags: []); XCTAssertEqual(percent.value as? String, value) }
        percent.typeKey(.return, modifierFlags: [])
        let burst = try s38Saved(context) { $0.opacity == 0.97 }
        s38Conserved(baseline, burst, field: "opacity", value: 0.97)
        XCTAssertTrue(s38History(context).contains("Undo Layer Opacity"))
        // One Undo reverts the whole burst to its starting value.
        s38Choose("Undo Layer Opacity", menu: "Edit", in: context)
        let starting = try s38Saved(context) { $0.opacity == 1 }
        s38Conserved(baseline, starting)
        let startingHistory = s38History(context)
        XCTAssertTrue(startingHistory.contains("Redo Layer Opacity"))
        percent.click()
        for value in ["99", "98", "97"] { percent.typeKey(.downArrow, modifierFlags: []); XCTAssertEqual(percent.value as? String, value) }
        percent.typeKey(.escape, modifierFlags: []); XCTAssertEqual(percent.value as? String, "100")
        // Cancel restores the starting value and records nothing: the redo step survives.
        let cancelled = try s38Saved(context) { $0.opacity == 1 }
        s38Conserved(starting, cancelled); XCTAssertEqual(s38History(context), startingHistory)
        s38Choose("Redo Layer Opacity", menu: "Edit", in: context)
        let redone = try s38Saved(context) { $0.opacity == 0.97 }
        s38Conserved(baseline, redone, field: "opacity", value: 0.97)
        s38Choose("Undo Layer Opacity", menu: "Edit", in: context)
        let final = try s38Saved(context) { $0.opacity == 1 }
        s38Conserved(baseline, final); try s38Finish(context, expected: final)
    }
    @MainActor
    func testS38DisabledRegisteredLayerMenuDisplaysTransformReason() throws {
        let context = try s38Open(run: 3)
        let baseline = try s38Saved(context) { $0.visible && $0.opacity == 1 }
        let baselineHistory = s38History(context)
        s38Choose("Transform Layer", menu: "Layer", in: context)
        XCTAssertTrue(context.editor.buttons["Apply"].waitForExistence(timeout: 10))
        let layerMenu = context.app.menuBars.menuBarItems["Layer"]
        layerMenu.click()
        let hide = layerMenu.menuItems["Hide Layer — Finish the current tool, dialog or layer edit first."]
        XCTAssertTrue(hide.waitForExistence(timeout: 10))
        XCTAssertFalse(hide.isEnabled)
        XCTAssertEqual(hide.title, "Hide Layer — Finish the current tool, dialog or layer edit first.")
        context.app.typeKey(.escape, modifierFlags: [])
        let cancel = context.editor.buttons["Cancel"]
        XCTAssertTrue(cancel.exists && cancel.isEnabled); cancel.click()
        layerMenu.click()
        let restored = layerMenu.menuItems["Hide Layer"]
        XCTAssertTrue(restored.exists && restored.isEnabled); XCTAssertEqual(restored.title, "Hide Layer")
        context.app.typeKey(.escape, modifierFlags: [])
        let final = try s38Saved(context) { $0.visible && $0.opacity == 1 }
        s38Conserved(baseline, final); XCTAssertEqual(s38History(context), baselineHistory)
        try s38Finish(context, expected: final)
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
