import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Compositor

/// The sample plugin packages built from source in adapters/plugins/samples (scripts/build-sample-plugins.sh).
enum LensWorksPluginSamples {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("adapters/plugins/samples")
    static func package(_ name: String) -> URL { root.appendingPathComponent(name + ".lwplugin", isDirectory: true) }
    static func module(_ name: String) throws -> Data { try Data(contentsOf: package(name).appendingPathComponent("filter.wasm")) }
    static func id(_ name: String) -> String { "com.lensworks.sample." + name }
}

/// S46: sandboxed WebAssembly filter plugins as commands. Each plugin the person installs is a registered command
/// (in Filter › Plugins and for agents), runs in the sandbox off the main actor, and every way it can fail leaves the
/// document and its history untouched. Fixtures only: temp folders, a store per test, invisible self-answering UI.
@Suite(.serialized)
@MainActor
struct LensWorksPluginTests {
    typealias Fixture = LensWorksAgentCommandTests.Fixture
    typealias Samples = LensWorksPluginSamples

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")
    }
    private func ok(_ result: [String: Any]) -> Bool { result["isError"] as? Bool == false }
    private func content(_ result: [String: Any]) -> [String: Any] { result["structuredContent"] as? [String: Any] ?? [:] }

    /// A fixture with the two-layer 200×100 document and its own empty plugin store.
    private func fixture() throws -> (Fixture, LensWorksPluginStore) {
        let fixture = try Fixture()
        try fixture.paint()
        return (fixture, fixture.session.plugins)
    }
    /// The layer's pixels as premultiplied sRGB bytes, rows top-down.
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try PixelAdjust.bitmap(width: image.width, height: image.height, mask: false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for y in 0..<image.height { for x in 0..<image.width * 4 { result[y * image.width * 4 + x] = data.load(fromByteOffset: y * context.bytesPerRow + x, as: UInt8.self) } }
        return result
    }
    private func pixel(_ fixture: Fixture, _ name: String = "Blue", x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(try fixture.layer(name).asset?.image)
        let all = try bytes(image), at = (y * image.width + x) * 4
        return Array(all[at..<at + 4])
    }
    /// What a plugin does to an 8-bit pixel, by the interface's own arithmetic: each color byte to linear light,
    /// through `change` (given the channel and its linear value), and back. The fixture's colors are whatever its
    /// color space made of them, so expectations are computed from the pixel as it was.
    private func through(_ pixel: [UInt8], _ change: (Int, Double) -> Double) -> [UInt8] {
        (0..<3).map { channel in
            let value = FloatImageAdjustmentPixels.unit(change(channel, FloatImageAdjustmentPixels.decode(Double(pixel[channel]) / 255)))
            return UInt8((FloatImageAdjustmentPixels.encode(value) * 255).rounded())
        } + [pixel[3]]
    }
    private func inverted(_ pixel: [UInt8]) -> [UInt8] { through(pixel) { 1 - $1 } }
    /// Equal to within one 8-bit level: the plugin computes in float32, the expectation in double.
    private func near(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 } }

    /// A package folder made for one test: `manifest` (or a sample's) beside `module`.
    private func package(in fixture: Fixture, manifest: Data? = nil, from sample: String = "invert", module: Data? = nil) throws -> URL {
        let folder = fixture.harness.root.appendingPathComponent("package-\(UUID().uuidString.prefix(8)).lwplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (manifest ?? Data(contentsOf: Samples.package(sample).appendingPathComponent("plugin.json"))).write(to: folder.appendingPathComponent("plugin.json"))
        try (module ?? Samples.module(sample)).write(to: folder.appendingPathComponent("filter.wasm"))
        return folder
    }
    private func manifest(_ changes: [String: Any?] = [:], parameters: [[String: Any]]? = nil) throws -> Data {
        var object: [String: Any] = ["interface": 1, "id": "com.example.test", "name": "Test Filter", "version": "1.0.0", "parameters": parameters ?? []]
        for (key, value) in changes { if let value { object[key] = value } else { object.removeValue(forKey: key) } }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Criterion 1 — an installed plugin is a menu command; it changes pixels; one Undo restores them

    @Test func anInstalledInvertPluginIsAMenuCommandThatChangesThePixelsAndOneUndoRestoresThem() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, id = Samples.id("invert")
        // Nothing is installed: no plugin command exists anywhere.
        #expect(LensWorksCommandRegistry.dynamicDescriptors(store).isEmpty && LensWorksCommandAudit.currentTitles("Filter/Plugins", plugins: store) == [])

        let outcome = try await store.install(from: Samples.package("invert"))
        guard case .installed(let installed) = outcome else { Issue.record("expected a first install, got \(outcome)"); return }
        #expect(installed.id == id && installed.manifest.name == "Sample Invert" && installed.manifest.version == "1.0.0")
        #expect(installed.moduleHash == LensWorksPluginManifest.sha256(try Samples.module("invert")) && installed.moduleHash.count == 64)
        #expect(outcome.message == "Installed Sample Invert (\(id)) 1.0.0, SHA-256 \(installed.moduleHash).")

        // It is a registered command: one descriptor of the pluginFilter family, named by the plugin's id.
        let descriptors = LensWorksCommandRegistry.dynamicDescriptors(store)
        #expect(descriptors.map(\.name) == ["plugin.run." + id] && descriptors[0].id == .pluginFilter && descriptors[0].agent == LensWorksCommandID.pluginFilter.agentAccess)
        #expect(descriptors[0].undoable && descriptors[0].historyOwner == .document && descriptors[0].reversal == .history)
        // Its menu item is in Filter › Plugins under the plugin's name with its id alongside, and the audit accepts
        // exactly that item there: a rogue title in the same submenu is still a bypass.
        let title = "Sample Invert (\(id))"
        #expect(installed.manifest.menuTitle == title && LensWorksCommandAudit.currentTitles("Filter/Plugins", plugins: store) == [title])
        let menu = NSMenu(title: "Plugins")
        let item = NSMenuItem(); item.title = title; item.action = #selector(NSObject.copy); menu.addItem(item)
        let install = NSMenuItem(); install.title = "Install Plugin…"; install.action = #selector(NSObject.copy); menu.addItem(install)
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Filter/Plugins", plugins: store).isEmpty)
        #expect(LensWorksCommandAudit.command(for: item, path: "Filter/Plugins", plugins: store) == .init(.pluginFilter))
        #expect(LensWorksCommandAudit.command(for: install, path: "Filter/Plugins", plugins: store) == .init(.pluginInstall))
        let rogue = NSMenuItem(); rogue.title = "Sample Invert"; rogue.action = #selector(NSObject.copy); menu.addItem(rogue)
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Filter/Plugins", plugins: store).map(\.title) == ["Sample Invert"])
        // In the built-in Filter menu a plugin's title maps to nothing.
        #expect(LensWorksCommandAudit.command(for: item, path: "Filter", plugins: store) == nil)

        // Its availability is the menu's: runnable on the selected pixel layer, refused with a reason otherwise.
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true) == nil)
        let blue = try fixture.layer("Blue").id
        session.selectLayers([], primary: nil)
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true) == "Select an editable pixel layer first.")
        session.selectLayers([blue], primary: blue)

        // Choosing the item runs it through the dispatcher: the pixels change, in one history entry.
        let starting = session.document
        let blue0 = try pixel(fixture, x: 10, y: 10), red0 = try pixel(fixture, "Red", x: 10, y: 10)
        #expect(blue0[2] > 200 && blue0[3] == 255 && inverted(blue0) != blue0)
        #expect(LensWorksCommandDispatcher.perform(.init(.pluginFilter, id), reason: session.menuReason(.pluginFilter, argument: id, canStart: true)) { session.beginPlugin(id) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.history.undoCount == 0 || session.pluginRun != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(LensWorksCommandDispatcher.lastInvocation == .init(.pluginFilter, id))
        #expect(try near(pixel(fixture, x: 10, y: 10), inverted(blue0)) && near(pixel(fixture, x: 199, y: 99), inverted(blue0)) && pixel(fixture, x: 10, y: 10) != blue0)
        #expect(try pixel(fixture, "Red", x: 10, y: 10) == red0, "only the layer it was run on changed")
        #expect(session.history.undoCount == 1 && session.history.undoName == "Plugin: Sample Invert" && session.history.undoOrigin == .user)
        #expect(session.document != starting && session.pluginError == nil && session.pluginRun == nil && !session.isProjectBusy)
        // One Undo restores the pixels; Redo applies them again.
        session.undo()
        #expect(session.document == starting && session.history.undoCount == 0)
        #expect(try pixel(fixture, x: 10, y: 10) == blue0)
        session.redo()
        #expect(try near(pixel(fixture, x: 10, y: 10), inverted(blue0)) && session.history.undoCount == 1)
    }

    /// A plugin's own command is listed for agents with the parameters its manifest declares, runs under the same
    /// admission as every command, and leaves one history entry labeled “(Agent)”.
    @Test func anAgentListsAndRunsAnInstalledPluginWithItsDeclaredTypedParameters() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, id = Samples.id("brightness"), command = "plugin.run." + id
        let builtIn = fixture.tools.listCommands().count
        try await store.install(from: Samples.package("brightness")); try await store.install(from: Samples.package("invert"))
        let rows = fixture.tools.listCommands()
        #expect(rows.count == builtIn + 2 && rows.suffix(2).compactMap { $0["id"] as? String } == [command, "plugin.run." + Samples.id("invert")])
        #expect(fixture.tools.listCommands(prefix: "plugin.run.").count == 2 && fixture.tools.listCommands(prefix: "plugin.").count == 10)
        let row = try #require(rows.first { $0["id"] as? String == command })
        #expect(row["agentInvocable"] as? Bool == true && row["kind"] as? String == "document" && row["batchable"] as? Bool == true && row["available"] as? Bool == true)
        #expect(row["title"] as? String == "Sample Brightness (\(id))" && row["menu"] as? String == "Filter/Plugins" && row["undoable"] as? Bool == true
                && row["history"] as? String == "document" && row["requiresConfirmation"] as? Bool == false)
        let schema = try #require(row["inputSchema"] as? [String: Any]), properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(schema["additionalProperties"] as? Bool == false && (schema["required"] as? [String]) == [] && Set(properties.keys) == ["amount", "channel", "clamp", "repeat", "layer"])
        #expect(properties["amount"]?["type"] as? String == "number" && properties["amount"]?["minimum"] as? Double == -1 && properties["amount"]?["maximum"] as? Double == 1)
        #expect(properties["repeat"]?["type"] as? String == "integer" && properties["repeat"]?["minimum"] as? Double == 1 && properties["repeat"]?["maximum"] as? Double == 4)
        #expect(properties["clamp"]?["type"] as? String == "boolean" && properties["channel"]?["enum"] as? [String] == ["all", "red", "green", "blue"])
        #expect(properties.values.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
        // The tool schema admits a plugin command by shape, since plugins come and go while a client is connected.
        let invoke = try #require(LensWorksAgentTools.definitions.first { $0["name"] as? String == "invoke_command" })
        let named = try #require(((invoke["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["command"] as? [String: Any])
        let pattern = try #require(((named["anyOf"] as? [[String: Any]])?.last)?["pattern"] as? String)
        #expect(command.range(of: pattern, options: .regularExpression) != nil && "plugin.install".range(of: pattern, options: .regularExpression) == nil)

        // It runs as the agent through the dispatcher: red gains 0.5 of linear light, in one labeled entry.
        let starting = session.document
        let blue0 = try pixel(fixture, x: 5, y: 5), red0 = try pixel(fixture, "Red", x: 5, y: 5)
        let ran = await fixture.invoke(command, ["amount": 0.5, "channel": "red"])
        #expect(ok(ran), "\(text(ran))")
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .pluginFilter && LensWorksCommandDispatcher.lastOrigin == .agent)
        let changed = try pixel(fixture, x: 5, y: 5)
        #expect(near(changed, through(blue0) { $0 == 0 ? $1 + 0.5 : $1 }) && changed[0] > blue0[0] + 100 && changed[1] == blue0[1] && changed[2] == blue0[2], "\(blue0) became \(changed)")
        #expect(session.history.undoCount == 1 && session.history.undoOrigin == .agent && session.history.undoName == "Plugin: Sample Brightness (Agent)")
        #expect(content(ran)["command"] as? String == command && content(ran)["history"] as? String == session.history.undoName && content(ran)["changed"] as? Bool == true)
        let undone = await fixture.invoke("edit.undo")
        #expect(ok(undone) && session.document == starting && session.history.undoCount == 0)

        // The family command names a plugin and runs it with its defaults (amount 0.25 on every channel).
        let defaults = await fixture.invoke("plugin.run", ["plugin": id, "layer": try fixture.layer("Red").id.uuidString])
        #expect(ok(defaults) && session.activeLayer?.name == "Red" && session.history.undoName == "Plugin: Sample Brightness (Agent)", "\(text(defaults))")
        let lifted = try pixel(fixture, "Red", x: 5, y: 5)
        #expect(near(lifted, through(red0) { $1 + 0.25 }) && lifted != red0, "\(red0) became \(lifted)")
        #expect(ok(await fixture.invoke("edit.undo")) && session.document != nil && session.history.undoCount == 0)

        // A batch of plugin commands is one entry that one Undo reverts.
        let before = session.document
        let batch = await fixture.tools.call("batch", arguments: ["commands": [["command": command, "arguments": ["amount": 0.1]], ["command": "plugin.run." + Samples.id("invert")]]])
        #expect(ok(batch) && session.history.undoCount == 1 && session.history.undoName.hasSuffix("(Agent)"), "\(text(batch))")
        #expect(ok(await fixture.invoke("edit.undo")) && session.document == before)

        // Installing, removing and reloading are the person's alone, each refused with its own reason.
        for refused in ["plugin.install", "plugin.remove", "plugin.reload"] {
            let result = await fixture.invoke(refused, ["plugin": id])
            #expect(text(result) == "Agents cannot run \(refused). " + LensWorksAgentExclusion.pluginTrust.rawValue)
        }
        #expect(text(await fixture.invoke("plugin.cancel")) == "Agents cannot run plugin.cancel. " + LensWorksAgentExclusion.pluginProgress.rawValue)
        #expect(store.plugins.count == 2 && session.history.undoCount == 0)
    }

    /// The same admission as every command: an undeclared key, a value of the wrong type, a number that is not
    /// finite or outside the declared range, and a choice the manifest does not list are each refused before the
    /// plugin runs; nothing crashes or changes.
    @Test func everyPluginArgumentOutsideItsDeclarationIsRefusedWithoutACrashOrAChange() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        try await store.install(from: Samples.package("brightness"))
        let session = fixture.session, before = session.document, command = "plugin.run." + Samples.id("brightness")
        let descriptor = try #require(LensWorksCommandRegistry.dynamicDescriptors(store).first)
        var sent = 0
        @MainActor func refused(_ arguments: [String: Any], _ expected: String? = nil, name: String = command) async {
            let result = await fixture.invoke(name, arguments)
            sent += 1
            #expect(result["isError"] as? Bool == true && expected.map { text(result) == $0 } != false, "\(arguments): \(text(result))")
            #expect(session.document == before && session.history.undoCount == 0 && session.agentModalReason == nil && session.pluginRun == nil && !session.isProjectBusy, "\(arguments)")
        }
        // Registry-driven, as for the built-in commands: every numeric parameter the manifest declared is ranged.
        for parameter in descriptor.parameters where parameter.type == .number || parameter.type == .integer {
            let low = try #require(parameter.minimum), high = try #require(parameter.maximum)
            for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300, high + 1, low - 1, high + 0.5, low - 1e-9] { await refused([parameter.name: value]) }
            await refused([parameter.name: high + 1], "\(parameter.name) must be at most \(LensWorksAgentArguments.plain(high)).")
            await refused([parameter.name: low - 1], "\(parameter.name) must be at least \(LensWorksAgentArguments.plain(low)).")
            for wrong in ["1", true, [1], ["value": 1], NSNull()] as [Any] where !(wrong is NSNull) { await refused([parameter.name: wrong]) }
        }
        await refused(["repeat": 1.5], "repeat must be a whole number.")
        await refused(["clamp": 1], "clamp must be true or false.")
        await refused(["clamp": "true"]); await refused(["clamp": [true]])
        await refused(["channel": "alpha"], "channel must be one of: all, red, green, blue.")
        await refused(["channel": 2]); await refused(["channel": ["red"]]); await refused(["channel": ""])
        await refused(["bogus": 1], "Unknown argument “bogus” for \(command). Its arguments are: amount, channel, clamp, layer, repeat.")
        await refused(["amount": 0.1, "Amount": 0.2]); await refused(["plugin": Samples.id("invert")])
        await refused(["layer": "not-a-layer"]); await refused(["layer": UUID().uuidString], "The requested layer is no longer in this document.")
        await refused(["amount": ["nested": ["deep": Double.nan]]])
        // The family command, and names that are not an installed plugin's.
        await refused(["plugin": "com.example.absent"], "The plugin com.example.absent is not installed.", name: "plugin.run")
        await refused([:], nil, name: "plugin.run"); await refused(["plugin": 7], nil, name: "plugin.run"); await refused(["plugin": String(repeating: "x", count: 100_000)], nil, name: "plugin.run")
        await refused(["plugin": Samples.id("brightness"), "amount": 0.5], "Unknown argument “amount” for plugin.run. Its arguments are: layer, plugin.", name: "plugin.run")
        for name in ["plugin.run.com.example.absent", "plugin.run.", "plugin.run.." + Samples.id("brightness"), "plugin.run." + String(repeating: "a.", count: 5_000)] {
            await refused([:], "No plugin with that id is installed: list_commands lists each installed plugin’s command.", name: name)
        }
        await refused([:], "Name a command id from list_commands.", name: "plugin.running")
        #expect(sent > 45, "sent \(sent)")
        // With nothing refused it still runs: the checks did not wedge the session.
        let blue0 = try pixel(fixture, x: 0, y: 0)
        #expect(ok(await fixture.invoke(command, ["amount": 1, "channel": "green", "clamp": true, "repeat": 4])))
        #expect(try pixel(fixture, x: 0, y: 0) == [blue0[0], 255, blue0[2], 255] && session.history.undoCount == 1)
    }

    // MARK: Criterion 2 — hostile plugins are stopped and reported; forbidden imports are refused at install

    @Test func aPluginThatLoopsRecursesBombsTrapsOrWritesOutsideItsMemoryIsStoppedAndReportedWithTheDocumentUnchanged() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, before = session.document, blue0 = try pixel(fixture, x: 100, y: 50)
        let hostile: [(sample: String, name: String, reason: String)] = [
            ("loop", "Sample Endless Loop", "It ran past its execution budget of 90000000 fuel for this call (an endless loop?) and was stopped."),
            ("recursion", "Sample Unbounded Recursion", "It exceeded the stack limit of 1024 calls deep or 1048576 bytes (unbounded recursion?) and was stopped."),
            ("memory-bomb", "Sample Memory Bomb", "It asked for more than its limit of 16777216 bytes of memory or 4096 table elements and was stopped."),
            ("trap", "Sample Trap", "It trapped (reached unreachable code) and was stopped."),
            ("oob-write", "Sample Out-of-Bounds Write", "It read or wrote outside its own memory and was stopped."),
            ("not-a-number", "Sample Not-a-Number", "It returned a value that is not a finite number.")
        ]
        for plugin in hostile {
            // Each conforms to the interface, so it installs: what it does when run is the sandbox's to contain.
            try await store.install(from: Samples.package(plugin.sample))
            let id = Samples.id(plugin.sample)
            let expected = "The plugin \(plugin.name) (\(id)) failed, and the document was not changed. " + plugin.reason
            // As the person runs it, from the menu: reported to them, nothing changed, the app usable again.
            let started = ContinuousClock.now
            await session.runPluginReporting(id, values: [])
            #expect(ContinuousClock.now - started < .seconds(20), "\(plugin.sample) was stopped promptly")
            #expect(session.pluginError == expected, "\(plugin.sample): \(session.pluginError ?? "no error")")
            session.pluginError = nil
            #expect(session.document == before && session.history.undoCount == 0 && session.pluginRun == nil && !session.isProjectBusy && session.agentModalReason == nil
                    && session.brushError == nil, "\(plugin.sample)")
            // As an agent runs it: refused with the same words, no entry, no half-open transaction.
            let refused = await fixture.invoke("plugin.run." + id)
            #expect(refused["isError"] as? Bool == true && text(refused) == expected, "\(plugin.sample): \(text(refused))")
            #expect(session.document == before && session.history.undoCount == 0 && session.history.redoName.isEmpty && session.agentModalReason == nil && !session.isProjectBusy, "\(plugin.sample)")
            #expect(try pixel(fixture, x: 100, y: 50) == blue0)
        }
        // One failing member rolls a whole agent batch back.
        try await store.install(from: Samples.package("invert"))
        let batch = await fixture.tools.call("batch", arguments: ["commands": [["command": "plugin.run." + Samples.id("invert")], ["command": "plugin.run." + Samples.id("trap")]]])
        #expect(batch["isError"] as? Bool == true && text(batch).contains("It trapped (reached unreachable code)") && session.document == before && session.history.undoCount == 0, "\(text(batch))")
        // After all of that the app and the document are unharmed: a good plugin still runs.
        #expect(ok(await fixture.invoke("plugin.run." + Samples.id("invert"))) && session.history.undoCount == 1)
        #expect(try near(pixel(fixture, x: 100, y: 50), inverted(blue0)))
    }

    @Test func aPluginThatImportsAnythingBeyondTheFilterInterfaceIsRefusedAtInstallAndAgainAtLoad() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, before = session.document
        let named = "The plugin’s module was refused. The module imports “wasi_snapshot_preview1.fd_write”, which the filter interface does not provide. A plugin may import only lensworks_filter_v1.param."
        await #expect(throws: LensWorksPluginFailure(named)) { try await store.install(from: Samples.package("forbidden-import")) }
        #expect(store.plugins.isEmpty && store.damaged.isEmpty && LensWorksCommandRegistry.dynamicDescriptors(store).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).isEmpty, "nothing of a refused package is kept")
        #expect(text(await fixture.invoke("plugin.run." + Samples.id("forbidden-import"))) == "No plugin with that id is installed: list_commands lists each installed plugin’s command.")
        // The settings pane reports the refusal, with the import named.
        await store.perform { try await store.install(from: Samples.package("forbidden-import")).message }
        #expect(store.lastError == named && store.lastMessage == nil)

        // The sandbox itself refuses it at load, whatever the store thought: validate, and instantiate.
        let forbidden = try Samples.module("forbidden-import")
        #expect(throws: LensWorksPluginFailure.self) { try LensWorksPluginSandbox.validate(forbidden) }
        #expect(throws: LensWorksPluginFailure.self) { _ = try LensWorksPluginSandbox(wasm: forbidden, parameters: []) }

        // Installed files swapped behind LensWorks's back never run: the bytes must hash to what was installed.
        try await store.install(from: Samples.package("invert"))
        let id = Samples.id("invert"), installedModule = store.directory.appendingPathComponent(id).appendingPathComponent("filter.wasm")
        try forbidden.write(to: installedModule)
        let changed = "The plugin \(id) cannot run. " + LensWorksPluginStore.changedProblem
        await #expect(throws: LensWorksPluginFailure(changed)) { try await session.runPlugin(id, values: []) }
        #expect(session.document == before && session.history.undoCount == 0 && !session.isProjectBusy)
        // Once noticed it is listed as damaged: no command, and only Remove is left.
        #expect(store.plugins.isEmpty && store.damaged.map(\.id) == [id] && LensWorksCommandRegistry.dynamicDescriptors(store).isEmpty)
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true)?.hasPrefix("The plugin \(id) cannot run.") == true)
        // Even with the install record rewritten to match, the swapped module is validated again and refused.
        let record = store.directory.appendingPathComponent(id).appendingPathComponent(LensWorksPluginStore.recordName)
        var fields = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        fields["moduleSHA256"] = LensWorksPluginManifest.sha256(forbidden)
        try JSONSerialization.data(withJSONObject: fields).write(to: record)
        await store.refresh()
        #expect(store.plugins.map(\.id) == [id] && store.damaged.isEmpty, "the listing checks hashes; the sandbox checks the code")
        let again = "The plugin Sample Invert (\(id)) failed, and the document was not changed. The module imports “wasi_snapshot_preview1.fd_write”, which the filter interface does not provide. A plugin may import only lensworks_filter_v1.param."
        await #expect(throws: LensWorksPluginFailure(again)) { try await session.runPlugin(id, values: []) }
        #expect(text(await fixture.invoke("plugin.run." + id)) == again)
        #expect(session.document == before && session.history.undoCount == 0 && !session.isProjectBusy && session.pluginRun == nil)
        try await store.remove(id)
        #expect(store.plugins.isEmpty && !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id).path))
    }

    @Test func aMalformedOversizedOrIncompletePackageIsRefusedAtInstall() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let good = try Samples.module("invert")
        @MainActor func refusal(_ package: URL) async -> String {
            do { try await store.install(from: package); return "installed" } catch { return error.localizedDescription }
        }
        #expect(await refusal(try package(in: fixture, module: Data("not a module".utf8))) == "The plugin’s module was refused. The file is not a WebAssembly module.")
        #expect(await refusal(try package(in: fixture, module: good.prefix(good.count / 2))).hasPrefix("The plugin’s module was refused. The module is not valid WebAssembly for this host:"))
        #expect(await refusal(try package(in: fixture, module: Data())).hasPrefix("The plugin’s module was refused."))
        let limit = Int(LensWorksPluginSandbox.limits.module_bytes)
        #expect(await refusal(try package(in: fixture, module: good + Data(count: limit))) == "The package’s filter.wasm is over the \(limit)-byte limit.")
        let empty = fixture.harness.root.appendingPathComponent("empty.lwplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(await refusal(empty) == "The package has no plugin.json file.")
        let noModule = try package(in: fixture)
        try FileManager.default.removeItem(at: noModule.appendingPathComponent("filter.wasm"))
        #expect(await refusal(noModule) == "The package has no filter.wasm file.")
        #expect(await refusal(Samples.package("invert").appendingPathComponent("plugin.json")).hasPrefix("Choose a plugin package:"))
        // A link in place of the module or of the package is not followed.
        let linked = try package(in: fixture)
        try FileManager.default.removeItem(at: linked.appendingPathComponent("filter.wasm"))
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("filter.wasm"), withDestinationURL: Samples.package("invert").appendingPathComponent("filter.wasm"))
        #expect(await refusal(linked) == "The package has no filter.wasm file.")
        let link = fixture.harness.root.appendingPathComponent("link.lwplugin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Samples.package("invert"))
        #expect(await refusal(link).hasPrefix("Choose a plugin package:"))
        #expect(store.plugins.isEmpty && store.damaged.isEmpty)
    }

    /// A plugin's strings are untrusted: bounded, plain, never a built-in command's name, and always shown with its id.
    @Test func aManifestIsCheckedAndItsStringsCannotImpersonateLensWorks() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        @MainActor func refusal(_ data: Data) -> String {
            do { _ = try LensWorksPluginManifest(data: data); return "accepted" } catch { return error.localizedDescription }
        }
        let prefix = "The plugin’s manifest was refused: "
        #expect(refusal(try manifest()) == "accepted")
        // Names: a built-in command's, a disabled reason, an agent label, look-alike letters, controls, length.
        for name in ["Invert", "invert", "Gaussian Blur", "Undo", "Save", "Install Plugin", "Curves"] {
            #expect(refusal(try manifest(["name": name])) == prefix + "“name” is the name of a built-in LensWorks command.", "\(name)")
        }
        for name in ["Blur — Select a layer first.", "Fix (Agent)", "Іnvert", "Blur…", "A\nB", "A\u{202e}B", " Lead", "Trail ", "Two  Spaces", "", String(repeating: "a", count: 41), "Tab\tbed", "Slash/Path", "Emoji 🙂"] {
            #expect(refusal(try manifest(["name": name])).hasPrefix(prefix + "“name” must be 1 to 40 ASCII letters"), "\(name.debugDescription)")
        }
        #expect(refusal(try manifest(["name": 7])).hasPrefix(prefix + "“name”"))
        // Ids.
        for id in ["Invert", "invert", "com..x", ".com.x", "com.x.", "com.Example.x", "com/example", "com.example.x y", String(repeating: "a.", count: 40) + "b", "плагин.x", "a-b"] {
            #expect(refusal(try manifest(["id": id])).hasPrefix(prefix + "“id” must be lowercase letters and digits"), "\(id)")
        }
        // Interface, version, unknown and missing keys, shape, size.
        #expect(refusal(try manifest(["interface": 2])) == prefix + "it was built for filter interface 2; this LensWorks provides interface 1.")
        #expect(refusal(try manifest(["interface": "1"])) == prefix + "“interface” must be a whole number.")
        #expect(refusal(try manifest(["version": "1.0 beta!"])).hasPrefix(prefix + "“version” must be"))
        #expect(refusal(try manifest(["script": "rm -rf"])).hasPrefix(prefix + "it has a key the manifest format does not define."))
        #expect(refusal(try manifest(["version": nil])) == prefix + "it has no “version”.")
        #expect(refusal(Data("[1]".utf8)) == prefix + "it is not a JSON object." && refusal(Data("{".utf8)) == prefix + "it is not a JSON object.")
        #expect(refusal(Data(repeating: 0x20, count: LensWorksPluginManifest.maximumBytes + 1)) == prefix + "it is over 65536 bytes.")
        // Parameters.
        let amount: [String: Any] = ["name": "amount", "label": "Amount", "type": "number", "minimum": 0, "maximum": 1, "default": 0.5]
        @MainActor func parameter(_ changes: [String: Any?]) throws -> String {
            var entry = amount
            for (key, value) in changes { if let value { entry[key] = value } else { entry.removeValue(forKey: key) } }
            return refusal(try manifest(parameters: [entry]))
        }
        #expect(refusal(try manifest(parameters: [amount])) == "accepted")
        #expect(try parameter(["minimum": 2]).contains("finite “minimum” < “maximum”") && parameter(["default": 5]).contains("“default” between them"))
        #expect(try parameter(["maximum": 1e12]).contains("within ±1e9") && parameter(["default": "0.5"]).contains("“default”") && parameter(["minimum": nil]) == prefix + "parameter 1 has no “minimum”.")
        #expect(try parameter(["type": "string"]) == prefix + "parameter 1 needs “type”: number, integer, boolean or choice.")
        #expect(try parameter(["type": "integer", "default": 0.5]) == prefix + "parameter 1 is an integer: its range and default must be whole numbers.")
        #expect(try parameter(["type": "boolean"]).hasPrefix(prefix + "parameter 1 has a key") && parameter(["label": "Amount — off"]).contains("needs a “label”"))
        for name in ["layer", "plugin", "Amount", "a b", "9lives", "", String(repeating: "a", count: 33)] { #expect(try parameter(["name": name]).contains("needs a “name”"), "\(name)") }
        #expect(refusal(try manifest(parameters: [amount, amount])) == prefix + "two parameters are named “amount”.")
        #expect(refusal(try manifest(parameters: (0..<17).map { var entry = amount; entry["name"] = "p\($0)"; return entry })) == prefix + "“parameters” must be a list of at most 16 parameters.")
        let choice: [String: Any] = ["name": "mode", "label": "Mode", "type": "choice", "choices": ["soft", "hard"], "default": "soft"]
        #expect(refusal(try manifest(parameters: [choice])) == "accepted")
        for bad in [["choices": ["only"]], ["choices": ["a", "a"]], ["choices": ["ok", "bad — reason"]], ["choices": (0..<33).map { "c\($0)" }], ["choices": [1, 2]]] as [[String: Any]] {
            var entry = choice; entry.merge(bad) { $1 }
            #expect(refusal(try manifest(parameters: [entry])).contains("different “choices”"), "\(bad)")
        }
        var stray = choice; stray["default"] = "medium"
        #expect(refusal(try manifest(parameters: [stray])) == prefix + "parameter 1’s “default” must be one of its choices.")

        // What a checked manifest shows is bounded and carries the id: menu title, agent title, history name.
        let longest = try LensWorksPluginManifest(data: try manifest(["name": String(repeating: "W", count: 40), "id": String(repeating: "a", count: 31) + "." + String(repeating: "b", count: 32)], parameters: [amount]))
        #expect(longest.menuTitle.count == 40 + 64 + 4 && longest.menuTitle.hasSuffix("…") && longest.menuTitle.contains("(" + longest.id + ")"))
        #expect(LensWorksCommandRegistry.pluginDescriptor(longest).label == longest.name + " (" + longest.id + ")" && longest.historyName == "Plugin: " + longest.name)
        // A refused manifest installs nothing, and two installed plugins cannot share a name.
        await #expect(throws: LensWorksPluginFailure.self) { try await store.install(from: try package(in: fixture, manifest: try manifest(["name": "Invert"]))) }
        try await store.install(from: Samples.package("invert"))
        let twin = try package(in: fixture, manifest: try manifest(["name": "sample invert"]))
        await #expect(throws: LensWorksPluginFailure(prefix + "“name” is already the name of the installed plugin \(Samples.id("invert")).")) { try await store.install(from: twin) }
        #expect(store.plugins.map(\.id) == [Samples.id("invert")])
    }

    // MARK: Criterion 3 — removing a plugin removes its command; reloading uses the new code

    @Test func removingAPluginRemovesItsCommandAndReloadingUsesTheNewCode() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        // The person's own package folder, which they go on editing after installing it.
        let source = try package(in: fixture, manifest: try manifest(), from: "invert")
        let id = "com.example.test", command = "plugin.run." + id
        let first = try await store.install(from: source).plugin, blue0 = try pixel(fixture, x: 10, y: 10)
        #expect(ok(await fixture.invoke(command)))
        #expect(try near(pixel(fixture, x: 10, y: 10), inverted(blue0)))
        #expect(ok(await fixture.invoke("edit.undo")))

        // Unchanged on disk: Reload says so and keeps the hash.
        #expect(try await store.reload(id) == .unchanged(first))
        // New code under the same id: Reload detects it by hash and the next run uses it.
        try Samples.module("gradient").write(to: source.appendingPathComponent("filter.wasm"))
        let reloaded = try await store.reload(id)
        let gradientHash = LensWorksPluginManifest.sha256(try Samples.module("gradient"))
        #expect(reloaded == .replaced(reloaded.plugin, previousHash: first.moduleHash) && reloaded.plugin.moduleHash == gradientHash
                && reloaded.plugin.moduleHash != first.moduleHash)
        #expect(reloaded.message == "Replaced Test Filter (\(id)): it is now version 1.0.0, SHA-256 \(reloaded.plugin.moduleHash) (was \(first.moduleHash)).")
        #expect(store.plugins == [reloaded.plugin] && fixture.tools.listCommands(prefix: command).count == 1)
        #expect(ok(await fixture.invoke(command)))
        // The gradient plugin writes each pixel's place in the layer into red and green; blue is left alone.
        #expect(try pixel(fixture, x: 0, y: 0) == [0, 0, blue0[2], 255])
        let far = try pixel(fixture, x: 199, y: 99)
        #expect(far[0] > 250 && far[1] > 250 && far[2] == blue0[2], "\(far)")
        #expect(ok(await fixture.invoke("edit.undo")))
        // A manifest change (a new version, a new parameter) is a reload too, and the command's arguments follow it.
        try manifest(["version": "2.0.0"], parameters: [["name": "amount", "label": "Amount", "type": "number", "minimum": 0, "maximum": 1, "default": 0.5]]).write(to: source.appendingPathComponent("plugin.json"))
        let second = try await store.reload(id).plugin
        #expect(second.manifest.version == "2.0.0" && second.manifestHash != reloaded.plugin.manifestHash && second.moduleHash == reloaded.plugin.moduleHash)
        #expect(((fixture.tools.listCommands(prefix: command).first?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.sorted() == ["amount", "layer"])
        // Installing the same package again is detected the same way.
        #expect(try await store.install(from: source) == .unchanged(second))
        // A reload that would be refused leaves the installed plugin as it was.
        try Samples.module("forbidden-import").write(to: source.appendingPathComponent("filter.wasm"))
        await #expect(throws: LensWorksPluginFailure.self) { try await store.reload(id) }
        try Samples.module("gradient").write(to: source.appendingPathComponent("filter.wasm"))
        try manifest(["id": "com.example.other"]).write(to: source.appendingPathComponent("plugin.json"))
        await #expect(throws: LensWorksPluginFailure("The package at \(source.standardizedFileURL.path) is now the plugin com.example.other, not \(id). Install it as a new plugin instead.")) { try await store.reload(id) }
        #expect(try await store.load(id).plugin == second && store.plugins == [second])

        // Removing it removes the command everywhere: the menu's titles, the registry's list, and for agents.
        let before = session.document
        try await store.remove(id)
        #expect(store.plugins.isEmpty && LensWorksCommandRegistry.dynamicDescriptors(store).isEmpty && LensWorksCommandAudit.currentTitles("Filter/Plugins", plugins: store) == [])
        #expect(fixture.tools.listCommands(prefix: "plugin.run.").isEmpty && fixture.tools.listCommands().count == LensWorksCommandRegistry.descriptors.count)
        #expect(text(await fixture.invoke(command)) == "No plugin with that id is installed: list_commands lists each installed plugin’s command.")
        #expect(text(await fixture.invoke("plugin.run", ["plugin": id])) == "The plugin \(id) is not installed.")
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true) == "The plugin \(id) is not installed.")
        session.beginPlugin(id)
        await #expect(throws: LensWorksCommandRefusal(reason: "The plugin \(id) is not installed.")) { try await session.runPlugin(id, values: []) }
        #expect(session.document == before && session.history.undoCount == 0 && session.pluginRun == nil && session.pluginParameters == nil)
        await #expect(throws: LensWorksPluginFailure("That plugin is not installed.")) { try await store.remove(id) }
        await #expect(throws: LensWorksPluginFailure("That plugin is not installed.")) { try await store.reload(id) }
        // A new store over the same folder (the next launch) finds what is installed, and nothing else.
        try await store.install(from: Samples.package("invert"))
        let relaunched = LensWorksPluginStore(directory: store.directory)
        // The folder is read off the main actor: nothing is listed until that is done, and `loaded` waits for it.
        #expect(relaunched.plugins.isEmpty)
        await relaunched.loaded()
        #expect(relaunched.plugins == store.plugins && relaunched.plugins.map(\.id) == [Samples.id("invert")] && relaunched.damaged.isEmpty)
    }

    // MARK: The interface: tiles, float data, the selection, cancelling

    /// Cutting a layer into tiles of any size gives exactly the pixels one whole-frame pass gives, for a pointwise
    /// filter and for one that depends on each pixel's place in the layer.
    @Test func tiledAndWholeFrameResultsAreIdentical() throws {
        let width = 250, height = 200
        let context = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        for step in 0..<25 {
            context.setFillColor(CGColor(srgbRed: CGFloat(step) / 25, green: CGFloat((step * 7) % 25) / 25, blue: CGFloat((step * 13) % 25) / 25, alpha: step % 5 == 0 ? 0.4 : 1))
            context.fill(CGRect(x: step * 10, y: 0, width: 10, height: height - step * 4))
        }
        let image = try #require(context.makeImage()), original = try bytes(image)
        let asset = ImportedImage(image: image, thumbnail: image, name: "Stripes")
        for (sample, parameters) in [("invert", [Double]()), ("brightness", [0.2, 0, 0, 2]), ("gradient", [])] {
            @MainActor func run(_ side: Int) throws -> [UInt8] {
                let job = LensWorksPluginRunner.Job(wasm: try Samples.module(sample), parameters: parameters, asset: asset, selection: nil, pixelToDocument: .identity,
                                                    name: "Stripes", cancellation: LWFloatCancellation(), tileSide: side)
                return try bytes(try LensWorksPluginRunner.run(job).image)
            }
            // 250×200 is 50,000 pixels, under the tile limit, so one 256-pixel tile is the whole frame.
            let whole = try run(256)
            for side in [16, 37, 100, 128] { #expect(try run(side) == whole, "\(sample) in \(side)-pixel tiles") }
            #expect(whole != original, "\(sample) changed the picture")
        }
        // A tile larger than the sandbox carries is refused before anything runs.
        let job = LensWorksPluginRunner.Job(wasm: try Samples.module("invert"), parameters: [], asset: asset, selection: nil, pixelToDocument: .identity,
                                            name: "Stripes", cancellation: LWFloatCancellation(), tileSide: 257)
        #expect(throws: ProjectError.self) { try LensWorksPluginRunner.run(job) }
    }

    /// A float layer is read and written a stored tile at a time and stays float; a plugin sees its own layer's
    /// frame, never the document's or another layer's.
    @Test func aFloatLayerStaysFloatAndAPluginSeesOnlyTheLayerItWasGiven() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        try await store.install(from: Samples.package("invert")); try await store.install(from: Samples.package("gradient")); try await store.install(from: Samples.package("brightness"))
        // A 300×280 float plane (four stored tiles) holding values past display white, as a third layer.
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let width = 300, height = 280
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            let pixels = (0..<range.width * range.height).map { index -> SIMD4<Float> in
                let x = range.x + index % range.width, y = range.y + index / range.width
                return SIMD4(Float(x) / 100, Float(y) / 200, 0.25, x < 150 ? 1 : 0.5)
            }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: range.width * range.height * 16), at: range)
        }
        let blue0 = try pixel(fixture, "Blue", x: 10, y: 10), red0 = try pixel(fixture, "Red", x: 10, y: 10)
        session.insert(try ImportedImage(plane: builder.finish(), name: "Float"))
        session.history.reset()
        let before = session.document
        @MainActor func sample(_ x: Int, _ y: Int) throws -> SIMD4<Float> {
            let plane = try #require(try fixture.layer("Float").asset?.linearPlane)
            return try plane.read(range: LWFloatRange(x: x, y: y, width: 1, height: 1)).surface.pixels[0]
        }
        #expect(try sample(299, 279) == SIMD4(2.99, 1.395, 0.25, 0.5))
        try await session.runPlugin(Samples.id("invert"), values: [])
        // Float in, float out: values outside 0–1 survive exactly, alpha is untouched, in every stored tile.
        for (x, y) in [(0, 0), (255, 255), (256, 0), (0, 256), (299, 279), (149, 10), (150, 10)] {
            #expect(try sample(x, y) == SIMD4(1 - Float(x) / 100, 1 - Float(y) / 200, 0.75, x < 150 ? 1 : 0.5), "(\(x), \(y))")
        }
        #expect(try fixture.layer("Float").asset?.linearPlane != nil && session.history.undoCount == 1 && session.history.undoName == "Plugin: Sample Invert")
        session.undo()
        #expect(try sample(299, 279) == SIMD4(2.99, 1.395, 0.25, 0.5) && session.document == before)
        // The frame a plugin is told about is its layer's own 300×280, not the 200×100 document or another layer.
        try await session.runPlugin(Samples.id("gradient"), values: [])
        #expect(try sample(299, 279) == SIMD4(Float(299) / Float(300), Float(279) / Float(280), 0.25, 0.5) && sample(0, 0) == SIMD4(0, 0, 0.25, 1))
        #expect(try pixel(fixture, "Blue", x: 10, y: 10) == blue0 && pixel(fixture, "Red", x: 10, y: 10) == red0)
        session.undo()

        // Inside a selection only the selected pixels change; the rest keep their values exactly.
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil), mode: .replace, name: "Marquee")
        session.history.reset()
        try await session.runPlugin(Samples.id("brightness"), values: [1, 3, 0, 1])
        // Where the middle of the selection falls on the layer's own pixel grid, wherever the layer was placed.
        let placed = try fixture.layer("Float").transform
        let inside = CGPoint(x: 50, y: 50).applying(BrushRaster.pixelToDocument(placed, width: width, height: height).inverted())
        let ix = Int(inside.x), iy = Int(inside.y)
        try #require((0..<width).contains(ix) && (0..<height).contains(iy), "the selection lies on the layer")
        #expect(try sample(ix, iy) == SIMD4(Float(ix) / 100, Float(iy) / 200, 1.25, ix < 150 ? 1 : 0.5), "the selected pixel (\(ix), \(iy)) gained blue")
        #expect(try sample(299, 279) == SIMD4(2.99, 1.395, 0.25, 0.5) && sample(0, 0) == SIMD4(0, 0, 0.25, 1), "pixels outside the selection are exactly as they were")
        // And on an 8-bit layer: selected pixels change, the others keep their bytes.
        let blue = try fixture.layer("Blue").id
        session.selectLayers([blue], primary: blue)
        try await session.runPlugin(Samples.id("invert"), values: [])
        #expect(try near(pixel(fixture, x: 50, y: 50), inverted(blue0)) && pixel(fixture, x: 150, y: 50) == blue0)
        // Values that are not the plugin's declared parameters never reach it.
        for values in [[2.0, 0, 0, 1], [0, 9, 0, 1], [0, 0, 2, 1], [0, 0, 0, 1.5], [0, 0, 0], [Double.nan, 0, 0, 1]] {
            await #expect(throws: LensWorksCommandRefusal.self, "\(values)") { try await session.runPlugin(Samples.id("brightness"), values: values) }
        }
        #expect(session.history.undoCount == 2 && !session.isProjectBusy)
    }

    /// The plugin runs off the main actor, so the app stays live, and Cancel — a registered command — stops it with
    /// the document and history as they were.
    @Test func aRunningPluginLeavesTheAppLiveAndCancelStopsItWithNothingChanged() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        try await store.install(from: Samples.package("brightness"))
        // A layer big enough to take a while in a debug build: 2048×2048 is 64 tiles.
        session.insert(ImportedImage(image: try Fixture.image(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), width: 2048, height: 2048),
                                     thumbnail: try Fixture.image(CGColor(red: 0, green: 0, blue: 0, alpha: 1), width: 8, height: 8), name: "Big"))
        session.history.reset()
        let before = session.document
        #expect(LensWorksCommandRegistry.descriptor(.pluginCancel).label == "Cancel" && LensWorksCommandID.pluginCancel.agentAccess == .notRunnable(.pluginProgress))
        final class Outcome { var error: Error?; var finished = false }
        let outcome = Outcome()
        let running = Task { @MainActor in
            do { try await session.runPlugin(Samples.id("brightness"), values: [0.1, 0, 0, 1]) } catch { outcome.error = error }
            outcome.finished = true
        }
        // The main actor keeps turning while the plugin runs: this loop is on it, and sees the run's progress.
        var turns = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !outcome.finished, (session.pluginRun?.progress ?? 0) == 0, ContinuousClock.now < deadline { turns += 1; try await Task.sleep(for: .milliseconds(2)) }
        let run = try #require(session.pluginRun, "the plugin is still running after its first tiles")
        #expect(turns > 0 && run.progress > 0 && run.progress < 1 && session.isProjectBusy && run.plugin.id == Samples.id("brightness"))
        // The person's run has every run's whole-run budget.
        #expect(run.runFuel == LensWorksPluginSandbox.limits.fuel_run)
        // While it runs nothing else may start on the document.
        #expect(session.menuReason(.pluginFilter, argument: Samples.id("brightness"), canStart: true) == "Finish the current project operation first.")
        #expect(session.menuReason(.invert, canStart: true) == "Finish the current project operation first.")
        #expect(LensWorksCommandDispatcher.perform(.init(.pluginCancel)) { session.cancelPlugin() } && LensWorksCommandDispatcher.lastInvocation == .init(.pluginCancel))
        await running.value
        #expect(outcome.error is CancellationError, "\(String(describing: outcome.error))")
        #expect(session.document == before && session.history.undoCount == 0 && session.pluginRun == nil && !session.isProjectBusy && session.pluginError == nil)
        // The person's Cancel during an agent's run is that request's refusal, and rolls its transaction back.
        let asked = Task { @MainActor in await fixture.invoke("plugin.run." + Samples.id("brightness"), ["amount": 0.1]) }
        while session.pluginRun == nil || session.pluginRun?.progress == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        // An agent's run has the tighter one.
        #expect(session.pluginRun?.runFuel == LensWorksPluginSandbox.limits.fuel_run_agent && LensWorksPluginSandbox.limits.fuel_run_agent < LensWorksPluginSandbox.limits.fuel_run)
        session.cancelPlugin()
        let refused = await asked.value
        #expect(text(refused) == "The plugin Sample Brightness (\(Samples.id("brightness"))) was cancelled in LensWorks, and the document was not changed.")
        #expect(session.document == before && session.history.undoCount == 0 && session.agentModalReason == nil && !session.isProjectBusy)
        // Left alone it finishes, as one entry.
        try await session.runPlugin(Samples.id("brightness"), values: [0.1, 0, 0, 1])
        #expect(session.history.undoCount == 1 && session.document != before)
        session.cancelPlugin()
    }

    /// A plugin that spends nearly all of its fuel on every tile, and never traps, is slow rather than stuck: the
    /// whole run's budget stops it, with the document and its history untouched.
    @Test func aRunThatSpendsNearlyItsWholeFuelOnEveryTileIsStoppedByTheRunBudgetWithTheDocumentUnchanged() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, id = Samples.id("slow")
        try await store.install(from: Samples.package("slow"))
        // The 200×100 layer in 50-pixel tiles is eight tiles of 2,500 pixels: each may spend 20,000,000 fuel, and
        // 1,900,000 spins (ten fuel each) spend about nineteen of those twenty million.
        let spins = 1_900_000.0, tile: UInt64 = 10_000_000 + 4_000 * 2_500
        let before = session.document, blue0 = try pixel(fixture, x: 10, y: 10)
        // Three and a half tiles' worth for the whole run: the fourth tile is stopped, by the run's budget.
        let budget = tile * 7 / 2
        let stopped = "The plugin Sample Slow Invert (\(id)) failed, and the document was not changed. It used up its execution budget of \(budget) fuel for the whole run and was stopped."
        await #expect(throws: LensWorksPluginFailure(stopped)) { try await session.runPlugin(id, values: [spins], tileSide: 50, runFuel: budget) }
        #expect(session.document == before && session.history.undoCount == 0 && session.pluginRun == nil && !session.isProjectBusy)
        #expect(try pixel(fixture, x: 10, y: 10) == blue0)
        // The same budget stops an agent's run, as that request's refusal, and a person's Filter › Plugins run, as its alert.
        await #expect(throws: LensWorksPluginFailure(stopped)) { try await session.runPlugin(id, values: [spins], origin: .agent, tileSide: 50, runFuel: budget) }
        #expect(session.document == before && session.history.undoCount == 0 && !session.isProjectBusy)
        // One tile over its own fuel is still stopped by the tile's budget, not the run's.
        let perTile = "The plugin Sample Slow Invert (\(id)) failed, and the document was not changed. It ran past its execution budget of \(tile) fuel for this call (an endless loop?) and was stopped."
        await #expect(throws: LensWorksPluginFailure(perTile)) { try await session.runPlugin(id, values: [spins * 2], tileSide: 50) }
        #expect(session.document == before && session.history.undoCount == 0)
        // Under the budget every run has, the same slow run completes: it is slow, not stuck.
        try await session.runPlugin(id, values: [spins], tileSide: 50)
        #expect(try near(pixel(fixture, x: 10, y: 10), inverted(blue0)) && near(pixel(fixture, x: 199, y: 99), inverted(blue0)))
        #expect(session.history.undoCount == 1 && session.history.undoName == "Plugin: Sample Slow Invert")
    }

    /// An agent never edits the document — or runs a plugin — under a sheet the person has open on it.
    @Test func anAgentWaitsWhileThePersonHasAPluginsParameterSheetOpen() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, id = Samples.id("brightness")
        try await store.install(from: Samples.package("brightness")); try await store.install(from: Samples.package("invert"))
        let before = session.document
        #expect(session.agentModalReason == nil)
        session.beginPlugin(id)
        try #require(session.pluginParameters != nil, "Filter › Plugins on a plugin with parameters opened its sheet")
        let waiting = "Finish the current edit in LensWorks first."
        #expect(session.agentModalReason == waiting && fixture.tools.agentAvailability(.invert) == waiting)
        for (command, arguments) in [("image.invert", [String: Any]()), ("plugin.run." + Samples.id("invert"), [:]), ("plugin.run." + id, ["amount": 0.5]), ("layer.newBlank", [:]), ("select.all", [:])] {
            let refused = await fixture.invoke(command, arguments)
            #expect(refused["isError"] as? Bool == true && text(refused) == waiting, "\(command)")
        }
        #expect(session.document == before && session.history.undoCount == 0 && session.pluginParameters != nil)
        // The sheet closed, the same request runs.
        session.cancelPluginParameters()
        #expect(session.agentModalReason == nil)
        #expect(ok(await fixture.invoke("image.invert")) && session.history.undoCount == 1 && session.history.undoName == "Invert (Agent)")
    }

    /// Reading a package, compiling its module to check it, and hashing every installed module happen off the main
    /// actor, at install and at launch.
    @Test func installingAndReadingTheInstalledPluginsNeverHoldsTheMainActor() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        final class Seen: @unchecked Sendable {
            private let lock = NSLock(); private var work: [String] = [], onMain = false
            func note(_ name: String) { lock.lock(); work.append(name); onMain = onMain || Thread.isMainThread; lock.unlock() }
            var taken: (work: [String], onMain: Bool) { lock.lock(); defer { lock.unlock(); work = []; onMain = false }; return (work, onMain) }
        }
        let seen = Seen()
        await store.loaded()
        store.observer = { seen.note($0) }
        let placing = Seen()
        store.place = { placing.note("place"); try LensWorksPluginFiles.place(staged: $0, destination: $1) }
        try await store.install(from: Samples.package("invert"))
        // The package is checked (its module compiled), written, put in place and the folder read again: none on the main thread.
        var taken = seen.taken
        #expect(taken.work == ["check", "write", "scan"] && !taken.onMain)
        #expect(placing.taken == (["place"], false))
        _ = try await store.load(Samples.id("invert"))
        taken = seen.taken
        #expect(taken.work == ["read"] && !taken.onMain)
        try await store.reload(Samples.id("invert"))
        taken = seen.taken
        #expect(taken.work == ["check", "read"] && !taken.onMain, "an unchanged package is checked and compared, and nothing is written")
        await store.refresh()
        taken = seen.taken
        #expect(taken.work == ["scan"] && !taken.onMain)
        // At launch the store is made without reading anything: the folder is read behind it.
        let relaunched = LensWorksPluginStore(directory: store.directory)
        #expect(relaunched.plugins.isEmpty && relaunched.damaged.isEmpty)
        await relaunched.loaded()
        #expect(relaunched.plugins == store.plugins && relaunched.plugins.count == 1)
        // Changes queued together run one at a time, in order, each seeing the one before.
        async let first = store.install(from: Samples.package("brightness"))
        async let second = store.install(from: Samples.package("gradient"))
        async let third: Void = store.remove(Samples.id("invert"))
        _ = try await (first, second, third)
        #expect(store.plugins.map(\.id) == [Samples.id("brightness"), Samples.id("gradient")] && store.damaged.isEmpty)
    }

    /// Replacing an installed plugin never leaves it uninstalled: the old folder stays until the new one has taken
    /// its place, so a failure part-way keeps the plugin that was there.
    @Test func aFailureWhileReplacingAnInstalledPluginLeavesTheOldOneInstalled() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, id = Samples.id("invert")
        let source = fixture.harness.root.appendingPathComponent("invert.lwplugin", isDirectory: true)
        try FileManager.default.copyItem(at: Samples.package("invert"), to: source)
        let first = try await store.install(from: source).plugin
        let installed = store.directory.appendingPathComponent(id), original = try Samples.module("invert")
        func leftovers() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0 != id } }

        // The step itself, failing for real: the staged folder is not there to move in. The installed one is untouched.
        let missing = store.directory.appendingPathComponent(".installing-missing", isDirectory: true)
        #expect(throws: (any Error).self) { try LensWorksPluginFiles.place(staged: missing, destination: installed) }
        #expect(try Data(contentsOf: installed.appendingPathComponent("filter.wasm")) == original)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(LensWorksPluginStore.recordName).path))
        // And succeeding: the staged folder takes the place whole, and nothing of it is left beside it.
        let staged = store.directory.appendingPathComponent(".installing-test", isDirectory: true)
        try FileManager.default.copyItem(at: installed, to: staged)
        try Data("marker".utf8).write(to: staged.appendingPathComponent("marker"))
        try LensWorksPluginFiles.place(staged: staged, destination: installed)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("marker").path) && !FileManager.default.fileExists(atPath: staged.path))
        #expect(try leftovers().isEmpty)
        try FileManager.default.removeItem(at: installed.appendingPathComponent("marker"))

        // The package changes (the gradient sample's module), and putting the new copy in place fails.
        try Samples.module("gradient").write(to: source.appendingPathComponent("filter.wasm"))
        struct Injected: LocalizedError { var errorDescription: String? { "The disk is full." } }
        final class Calls: @unchecked Sendable { var destinations: [URL] = [] }
        let calls = Calls()
        store.place = { _, destination in calls.destinations.append(destination); throw Injected() }
        await #expect(throws: LensWorksPluginFailure("The plugin could not be installed: The disk is full.")) { try await store.reload(id) }
        #expect(calls.destinations.map(\.lastPathComponent) == [id])
        // The old plugin is still installed, still the bytes that were installed, and still runs — as the old code.
        #expect(store.plugins == [first] && store.damaged.isEmpty)
        #expect(try await store.load(id).module == original)
        #expect(try leftovers().isEmpty, "no staging folder is left behind")
        let blue0 = try pixel(fixture, x: 10, y: 10)
        try await session.runPlugin(id, values: [])
        #expect(try near(pixel(fixture, x: 10, y: 10), inverted(blue0)))
        session.undo()
        // A first install that fails the same way installs nothing and leaves nothing.
        await #expect(throws: LensWorksPluginFailure("The plugin could not be installed: The disk is full.")) { try await store.install(from: Samples.package("brightness")) }
        #expect(try store.plugins == [first] && leftovers().isEmpty)
        // With the failure gone the replacement goes through, and the new code runs.
        store.place = { try LensWorksPluginFiles.place(staged: $0, destination: $1) }
        let second = try await store.reload(id)
        #expect(try second == .replaced(second.plugin, previousHash: first.moduleHash) && store.plugins == [second.plugin] && leftovers().isEmpty)
        #expect(try await store.load(id).module == Samples.module("gradient"))
    }

    /// A pending transform or gradient would be applied on the way in, so a plugin waits for the person to finish it.
    @Test func aPluginWaitsForAPendingTransformOrOpenEdit() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session, id = Samples.id("invert")
        try await store.install(from: Samples.package("invert"))
        let before = session.document
        session.transformCommand()
        try #require(session.transformEdit != nil)
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true) == "Apply or cancel the current transform or gradient first.")
        await #expect(throws: LensWorksCommandRefusal(reason: "Apply or cancel the current transform or gradient first.")) { try await session.runPlugin(id, values: []) }
        #expect(session.document == before && session.history.undoCount == 0 && session.transformEdit != nil)
        session.cancelTransform()
        // A mask target, a folder and an empty layer have no pixels for a plugin.
        session.addLayerMask(); session.history.reset()
        session.isMaskSelected = true
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true) == "Select an editable pixel layer first.")
        session.isMaskSelected = false
        #expect(session.menuReason(.pluginFilter, argument: id, canStart: true) == nil)
        // The layer's mask and effects stay with it when its pixels are replaced.
        try await session.runPlugin(id, values: [])
        #expect(try fixture.layer("Blue").mask != nil && session.history.undoCount == 1)
    }

    /// The management pane, the parameter sheet and the progress panel lay out with real plugins in them, on an
    /// invisible window; their buttons are the registered commands, and the pane's actions report what happened.
    @Test func thePluginPaneSheetAndPanelShowInstalledPluginsThroughRegisteredCommands() async throws {
        let (fixture, store) = try fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        try await store.install(from: Samples.package("brightness")); try await store.install(from: Samples.package("invert"))
        // One damaged entry: its module replaced behind LensWorks's back.
        try Data("changed".utf8).write(to: store.directory.appendingPathComponent(Samples.id("invert")).appendingPathComponent("filter.wasm"))
        await store.refresh()
        #expect(store.plugins.map(\.id) == [Samples.id("brightness")] && store.damaged.map(\.id) == [Samples.id("invert")])
        let window = fixture.harness.window
        fixture.harness.showWindow()
        @MainActor func laidOut<V: View>(_ view: V) -> NSSize {
            let host = NSHostingView(rootView: view)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        #expect(laidOut(LensWorksPluginSettingsView(store: store)).height > 100)
        // The pane's actions: Reload reports the unchanged hash, Remove removes, and a failure is kept for the person.
        let brightness = try #require(store.plugin(Samples.id("brightness")))
        var started: Task<Void, Never>?
        #expect(LensWorksCommandDispatcher.perform(.init(.pluginReload, brightness.id)) { started = store.start { try await store.reload(brightness.id).message } })
        await started?.value
        #expect(store.lastMessage == "Sample Brightness (\(brightness.id)) is unchanged: SHA-256 \(brightness.moduleHash)." && store.lastError == nil)
        #expect(LensWorksCommandDispatcher.perform(.init(.pluginRemove, Samples.id("invert"))) { started = store.start { try await store.remove(Samples.id("invert")); return "Removed." } })
        await started?.value
        #expect(store.damaged.isEmpty && store.lastMessage == "Removed.")
        await store.perform { try await store.reload("com.example.absent").message }
        #expect(store.lastError == "That plugin is not installed." && store.lastMessage == nil)
        #expect(laidOut(LensWorksPluginSettingsView(store: store)).height > 100)

        // Filter › Plugins on a plugin with parameters opens its sheet at the declared defaults; Run applies them.
        session.beginPlugin(brightness.id)
        let edit = try #require(session.pluginParameters)
        #expect(edit.values == [0.25, 0, 0, 1] && session.history.undoCount == 0 && session.pluginRun == nil)
        #expect(laidOut(LensWorksPluginParameterSheet(session: session, edit: edit)).height > 100)
        session.cancelPluginParameters()
        #expect(session.pluginParameters == nil && session.history.undoCount == 0)
        session.beginPlugin(brightness.id)
        try #require(session.pluginParameters).values = [0.5, 1, 1, 2]
        let blue0 = try pixel(fixture, x: 3, y: 3)
        session.commitPluginParameters()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.history.undoCount == 0 || session.pluginRun != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.pluginParameters == nil && session.history.undoName == "Plugin: Sample Brightness")
        #expect(try pixel(fixture, x: 3, y: 3) == [255, blue0[1], blue0[2], 255], "red gained 0.5 × 2 and was clamped")
        // The progress panel lays out for a run in flight, and with none.
        session.pluginRun = LensWorksPluginRun(plugin: brightness, runFuel: LensWorksPluginSandbox.limits.fuel_run)
        #expect(laidOut(LensWorksPluginProgressPanel(session: session)).height > 60)
        session.pluginRun = nil
        #expect(laidOut(LensWorksPluginProgressPanel(session: session)).height > 30)
        window.contentView = nil
    }

    /// In the running app: installing a plugin puts its item in the real Filter › Plugins menu, every item of the
    /// menu bar still maps to a registered command, and removing the plugin takes the item away. The store is this
    /// test process's own stand-in for the person's Application Support folder.
    @Test func anInstalledPluginAppearsInTheLiveFilterMenuAndLeavesItWhenRemoved() async throws {
        let store = LensWorksPluginStore.shared, id = Samples.id("invert"), title = "Sample Invert (\(id))"
        try #require(store.directory.path.hasPrefix(LensWorksUserState.applicationSupport.path) && LensWorksUserState.isTesting)
        @MainActor func plugins() async throws -> NSMenu {
            for _ in 0..<100 {
                if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Filter" })?.submenu?.items.first(where: { $0.title == "Plugins" })?.submenu { return menu }
                try await Task.sleep(for: .milliseconds(100))
            }
            return try #require(NSApp.mainMenu?.items.first { $0.title == "Filter" }?.submenu?.items.first { $0.title == "Plugins" }?.submenu, "Filter › Plugins is in the menu bar")
        }
        @MainActor func titles() async throws -> [String] { try await plugins().items.filter { !$0.isSeparatorItem }.map(\.title) }
        @MainActor func waiting(for expected: [String]) async throws -> [String] {
            for _ in 0..<100 {
                // What AppKit does when the person opens the menu: ask its owner to bring it up to date.
                for menu in [NSApp.mainMenu, NSApp.mainMenu?.items.first { $0.title == "Filter" }?.submenu, try await plugins()] {
                    if let menu { menu.delegate?.menuNeedsUpdate?(menu); menu.update() }
                }
                if try await titles() == expected { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            return try await titles()
        }
        // The submenu's own two commands are always there: the retained steps of the selected RAW layer, and Install.
        let fixed = ["Retained Plugin Steps…", "Install Plugin…"]
        #expect(try await waiting(for: fixed) == fixed)
        try await store.install(from: Samples.package("invert"))
        do {
            #expect(try await waiting(for: [title] + fixed) == [title] + fixed)
            let item = try #require(try await plugins().items.first { $0.title == title })
            #expect(LensWorksCommandAudit.command(for: item, path: "Filter/Plugins") == .init(.pluginFilter) && item.keyEquivalent.isEmpty)
            let steps = try #require(try await plugins().items.first { $0.title == "Retained Plugin Steps…" })
            #expect(LensWorksCommandAudit.command(for: steps, path: "Filter/Plugins") == .init(.pluginSteps))
            let violations = LensWorksCommandAudit.audit(mainMenu: try #require(NSApp.mainMenu))
            #expect(violations.isEmpty, "Registry bypasses: \(violations.map(\.description).joined(separator: "; "))")
        } catch { try? await store.remove(id); throw error }
        try await store.remove(id)
        #expect(try await waiting(for: fixed) == fixed)
        #expect(LensWorksCommandAudit.audit(mainMenu: try #require(NSApp.mainMenu)).isEmpty)
    }

    /// The bounds are the runtime's own, and the person's plugins live under the one accessor for their state.
    @Test func theLimitsAreTheDocumentedOnesAndTheStoreIsUnderTheUserStateAccessor() throws {
        let limits = LensWorksPluginSandbox.limits
        #expect(limits.module_bytes == 4_194_304 && limits.memory_bytes == 16_777_216 && limits.table_elements == 4_096 && limits.stack_bytes == 1_048_576
                && limits.recursion_depth == 1_024 && limits.tile_pixels == 65_536 && limits.fuel_buffer_call == 1_000_000 && limits.fuel_filter_base == 10_000_000
                && limits.fuel_per_pixel == 4_000 && limits.parameters == 16 && limits.interface_version == 1)
        // The whole-run budgets — 1,024 full tiles' worth of fuel, 256 when an agent starts the run — and the color range.
        #expect(limits.fuel_run == 272_144_000 * 1_024 && limits.fuel_run_agent == 272_144_000 * 256 && limits.color_magnitude == 65_504)
        #expect(LensWorksPluginSandbox.runFuel(for: .user) == limits.fuel_run && LensWorksPluginSandbox.runFuel(for: .agent) == limits.fuel_run_agent)
        #expect(Int(limits.tile_pixels) == LWFloatPlane.tileSide * LWFloatPlane.tileSide, "one stored float tile is one plugin tile")
        #expect(LensWorksPluginStore.shared.directory.path == LensWorksUserState.applicationSupport.path + "/Plugins")
        #expect(EditorSession().plugins === LensWorksPluginStore.shared)
        // The family and management commands are classified in the registry's no-default switch.
        #expect(LensWorksCommandID.pluginFilter.agentAccess == .runnable(.document) && LensWorksCommandID.pluginFilter.reversal == .history)
        for id in [LensWorksCommandID.pluginInstall, .pluginRemove, .pluginReload] { #expect(id.agentAccess == .notRunnable(.pluginTrust) && LensWorksCommandRegistry.descriptor(id).historyOwner == .none) }
        #expect(LensWorksCommandAudit.registryProblems().isEmpty)
    }
}
