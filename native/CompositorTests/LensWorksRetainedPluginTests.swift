import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Compositor

/// S46 on live RAW layers: a plugin run, like a built-in filter, is retained on the layer's source rather than
/// turning the layer into plain pixels. Developing the RAW again applies the plugin again, with the code that made
/// the step and nothing else; a step whose plugin is gone or has changed stops the development with the reason,
/// and the person re-runs or removes it. Image › Invert is retained the same way. Fixtures only: procedural DNGs in
/// temp folders, a plugin store per test, invisible windows.
@Suite(.serialized)
@MainActor
struct LensWorksRetainedPluginTests {
    typealias Fixture = LensWorksAgentCommandTests.Fixture
    typealias Samples = LensWorksPluginSamples

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")
    }
    private func pixels(_ plane: LWFloatPlane) throws -> [SIMD4<Float>] { Array(try plane.read(plane.globalExtent).surface.pixels) }
    private func plane(_ session: EditorSession) throws -> LWFloatPlane { try #require(session.activeLayer?.asset?.linearPlane) }
    private func source(_ session: EditorSession) throws -> LWLiveSourceNode { try #require(session.activeLayer?.liveSource) }

    /// A fixture whose session holds one live RAW layer developed from a 96×64 procedural DNG, with its own plugin
    /// store. `body` runs with that store as the one a development resolves retained steps against.
    private func live(_ body: (Fixture, EditorSession, LensWorksPluginStore) async throws -> Void) async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let original = fixture.granted.appendingPathComponent("procedural.dng")
        try ProceduralDNG.write(to: original, width: 96, height: 64)
        let session = fixture.session, store = session.plugins
        try await LensWorksRetainedPlugins.$directory.withValue(store.directory) {
            await session.importImages([original])
            #expect(session.importError == nil, "\(session.importError ?? "")")
            let layer = try #require(session.activeLayer)
            try #require(layer.liveSource != nil && layer.asset?.linearPlane != nil, "the RAW is a live source layer developed in float")
            session.history.reset()
            try await body(fixture, session, store)
            try await LWSourceDeveloper.shared.drainRetainedSessions()
        }
    }
    /// Camera Raw on the live layer, committed: the RAW is developed again with the changed recipe.
    private func develop(_ session: EditorSession, _ change: (inout CameraRawSettings) -> Void) async throws {
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        change(&settings.cameraRaw)
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.filterEdit == nil)
    }
    /// What the plugin makes of `pixels` (one 96×64 tile), run fresh in its own sandbox.
    private func fresh(_ pixels: [SIMD4<Float>], module: Data, parameters: [Double] = [], width: Int = 96, height: Int = 64) throws -> [SIMD4<Float>] {
        var flat = pixels.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        try LensWorksPluginSandbox(wasm: module, parameters: parameters).filter(&flat, width: width, height: height, x: 0, y: 0, frameWidth: width, frameHeight: height)
        return stride(from: 0, to: flat.count, by: 4).map { SIMD4(flat[$0], flat[$0 + 1], flat[$0 + 2], flat[$0 + 3]) }
    }
    /// The layer's source developed without its retained plugin steps.
    private func developedWithoutPlugins(_ session: EditorSession) async throws -> [SIMD4<Float>] {
        var node = try source(session)
        for step in node.plugins { node = try node.removingPlugin(step.id) }
        return try pixels(try await LWSourceDeveloper.shared.evaluatePlane(node).surface)
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    // MARK: A plugin run on a live RAW layer is retained, and developing the RAW again applies it again

    @Test func aPluginRunOnALiveRawLayerKeepsItsSourceAndDevelopingAgainRunsThePluginAgain() async throws {
        try await live { fixture, session, store in
            let installed = try await store.install(from: Samples.package("invert")).plugin, module = try Samples.module("invert")
            let before = session.document, node0 = try source(session), developed0 = try pixels(try plane(session))
            #expect(node0.plugins.isEmpty && session.menuReason(.pluginSteps, canStart: true) == "The selected layer has no retained plugin steps.")

            try await session.runPlugin(installed.id, values: [])
            // Still a live RAW layer, in float, with the same original and recipe: the run is one retained step
            // naming the plugin, the hash of the module that ran, the interface and the values.
            let node1 = try source(session), step = try #require(node1.plugins.first)
            #expect(node1.plugins.count == 1 && node1.operations == [.plugin(step.id)] && node1.id == node0.id && node1.revision != node0.revision)
            #expect(node1.original == node0.original && node1.originalRevision == node0.originalRevision && node1.settings == node0.settings)
            #expect(step.plugin == installed.id && step.name == "Sample Invert" && step.moduleHash == installed.moduleHash && step.moduleHash == LensWorksPluginManifest.sha256(module)
                    && step.interface == 1 && step.parameters == [] && step.selectionPlaneID == nil && step.sourceID == node0.id && step.upstreamRevision == node0.revision)
            let made = try pixels(try plane(session))
            #expect(made == developed0.map { SIMD4(1 - $0.x, 1 - $0.y, 1 - $0.z, $0.w) } && made != developed0, "the pixels are the plugin’s, in float")
            #expect(try made == fresh(developed0, module: module))
            #expect(session.history.undoCount == 1 && session.history.undoName == "Plugin: Sample Invert" && session.pluginRun == nil && !session.isProjectBusy)
            // One Undo restores the layer whole, its source included; Redo brings the step back.
            session.undo()
            #expect(session.document == before && session.activeLayer?.liveSource == node0 && session.history.undoCount == 0)
            #expect(try pixels(try plane(session)) == developed0)
            session.redo()
            #expect(try session.activeLayer?.liveSource == node1 && (try pixels(try plane(session))) == made)

            // The recipe changes: the RAW is developed again and the plugin runs again on the new development.
            try await develop(session) { $0.exposure = 0.8 }
            #expect(session.brushError == nil, "\(session.brushError ?? "")")
            let node2 = try source(session)
            #expect(node2.settings.exposure == 0.8 && node2.plugins == [step] && node2.operations == [.plugin(step.id)])
            let redeveloped = try await developedWithoutPlugins(session), now = try pixels(try plane(session))
            #expect(redeveloped != developed0, "the recipe change changed the development")
            #expect(try now == fresh(redeveloped, module: module), "the result is the plugin run fresh on the new development")
            #expect(now != redeveloped && now != made && session.history.undoCount == 2)
            // The step is listed for the layer, and can be applied again as recorded.
            #expect(session.menuReason(.pluginSteps, canStart: true) == nil && session.retainedPluginSteps == [step])
            #expect(await session.pluginStepStates() == [LensWorksPluginStepState(step: step, problem: nil, installed: true)])

            // An agent's run on the live layer is retained the same way, as its own labeled entry.
            let agent = await fixture.invoke("plugin.run." + installed.id)
            #expect(agent["isError"] as? Bool == false, "\(text(agent))")
            let node3 = try source(session)
            #expect(node3.plugins.count == 2 && session.history.undoName == "Plugin: Sample Invert (Agent)" && session.history.undoOrigin == .agent)
            #expect(try pixels(try plane(session)) == fresh(now, module: module))
        }
    }

    /// Inside a selection only the selected pixels change, and the selection is retained with the step so a later
    /// development changes the same place.
    @Test func aPluginRunInsideASelectionOnALiveRawLayerRetainsTheSelection() async throws {
        try await live { _, session, store in
            let installed = try await store.install(from: Samples.package("invert")).plugin
            let layer = try #require(session.activeLayer), developed = try pixels(try plane(session))
            // The left half of the layer, wherever the layer sits on the canvas.
            let frame = CGRect(origin: layer.transform.origin, size: layer.transform.size)
            session.applySelection(CGPath(rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height), transform: nil), mode: .replace, name: "Marquee")
            session.history.reset()
            try await session.runPlugin(installed.id, values: [])
            let step = try #require(try source(session).plugins.first), key = try #require(step.selectionPlaneID)
            #expect(try source(session).planeAssets[key] != nil)
            let made = try pixels(try plane(session))
            func at(_ values: [SIMD4<Float>], _ x: Int, _ y: Int) -> SIMD4<Float> { values[y * 96 + x] }
            #expect(at(made, 10, 30) == SIMD4(1 - at(developed, 10, 30).x, 1 - at(developed, 10, 30).y, 1 - at(developed, 10, 30).z, at(developed, 10, 30).w))
            #expect(at(made, 80, 30) == at(developed, 80, 30), "a pixel outside the selection is exactly as it was")
            // Developed again, the same half is the plugin's and the other half is the new development's.
            try await develop(session) { $0.exposure = -0.6 }
            #expect(session.brushError == nil, "\(session.brushError ?? "")")
            let redeveloped = try await developedWithoutPlugins(session), now = try pixels(try plane(session))
            #expect(at(now, 80, 30) == at(redeveloped, 80, 30) && at(now, 10, 30) == SIMD4(1 - at(redeveloped, 10, 30).x, 1 - at(redeveloped, 10, 30).y, 1 - at(redeveloped, 10, 30).z, at(redeveloped, 10, 30).w))

            // A development cancelled while it is under way either never lands or lands whole: when it does not
            // land, the layer has the pixels and the source it had, and the person is told.
            session.history.reset()
            let kept = session.document, keptImage = try #require(session.activeLayer?.asset?.image)
            session.beginFilter(.cameraRaw)
            var settings = try #require(session.filterEdit).settings
            settings.cameraRaw.exposure = 0.9
            session.updateFilter(settings, preview: false)
            let committing = Task { @MainActor in await session.commitFilter() }
            while !session.isProjectBusy, session.filterEdit != nil { await Task.yield() }
            committing.cancel()
            await committing.value
            #expect(session.filterEdit == nil && !session.isProjectBusy)
            if session.history.undoCount == 0 {
                #expect(session.document == kept && session.activeLayer?.asset?.image === keptImage && session.brushError != nil)
            } else {
                #expect(try session.history.undoCount == 1 && session.brushError == nil && source(session).settings.exposure == 0.9 && source(session).plugins == [step])
            }
            session.brushError = nil
        }
    }

    // MARK: The plugin was removed

    @Test func developingALayerWhoseRetainedPluginWasRemovedReportsWhyAndThePersonRemovesTheStep() async throws {
        try await live { fixture, session, store in
            let id = Samples.id("invert")
            try await store.install(from: Samples.package("invert"))
            try await session.runPlugin(id, values: [])
            session.history.reset()
            let step = try #require(try source(session).plugins.first)
            try await store.remove(id)
            let kept = session.document, keptImage = try #require(session.activeLayer?.asset?.image), keptPixels = try pixels(try plane(session))

            // Developing the RAW again cannot apply the step: it is not skipped, the layer keeps its pixels and its
            // source, history gains nothing, and the person is told which step, why, and what to do.
            let reason = "The retained plugin step Sample Invert (\(id)) on this layer could not be applied again, so the layer was not changed. The plugin is not installed. Choose Filter › Plugins › Retained Plugin Steps… to re-run the step with the plugin installed now, or to remove it (an agent: plugin.step.rerun or plugin.step.remove with step \(step.id.uuidString))."
            try await develop(session) { $0.exposure = 0.5 }
            #expect(session.brushError == reason)
            session.brushError = nil
            #expect(session.document == kept && session.history.undoCount == 0 && !session.isProjectBusy)
            #expect(try session.activeLayer?.asset?.image === keptImage && (try pixels(try plane(session))) == keptPixels && (try source(session)).plugins == [step])
            // The project still saves and reopens as it stands, the step with it: only developing needs the plugin.
            let file = fixture.granted.appendingPathComponent("Missing.comp")
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
            let reopened = try await ProjectStore.shared.load(from: file)
            #expect(reopened.manifest.version == 14 && reopened.manifest.layers.first?.liveSource?.plugins == [step])
            let layerID = try #require(session.activeLayerID), reopenedPlane = try #require(reopened.images[layerID]?.linearPlane)
            #expect(try pixels(reopenedPlane) == keptPixels)
            // An agent asking for the same development is refused with the same words.
            let refused = await fixture.invoke("filter.apply", ["kind": "Camera Raw Filter", "settings": ["exposure": 0.5]])
            #expect(refused["isError"] as? Bool == true && text(refused) == reason)
            #expect(session.document == kept && session.history.undoCount == 0 && session.brushError == nil)
            // The sheet is the person's; an agent re-runs or removes the step by the id its refusal named. With the
            // plugin gone, re-running is refused and nothing changes; a step id that is not on the layer is refused too.
            #expect(text(await fixture.invoke("plugin.steps")) == "Agents cannot run plugin.steps. " + LensWorksAgentExclusion.pluginSteps.rawValue)
            let rerunRefused = await fixture.invoke("plugin.step.rerun", ["step": step.id.uuidString])
            #expect(rerunRefused["isError"] as? Bool == true && text(rerunRefused) == "The plugin \(id) is not installed. Install it, or remove the step.")
            #expect(text(await fixture.invoke("plugin.step.remove", ["step": UUID().uuidString])) == "That plugin step is not on the selected layer.")
            #expect(session.document == kept && session.history.undoCount == 0)

            // Filter › Plugins › Retained Plugin Steps… lists the step with what stands in its way.
            #expect(session.menuReason(.pluginSteps, canStart: true) == nil)
            #expect(LensWorksCommandDispatcher.perform(.init(.pluginSteps), reason: session.menuReason(.pluginSteps, canStart: true)) { session.beginPluginSteps() })
            let sheet = try #require(session.pluginSteps)
            #expect(try await eventually { !sheet.steps.isEmpty })
            let problem = LWSourceRetainedPluginProblem(step, .notInstalled)
            #expect(sheet.steps == [LensWorksPluginStepState(step: step, problem: problem, installed: false)] && problem.reason == "The plugin is not installed.")
            // While the sheet is open an agent does not edit the document under it.
            #expect(session.agentModalReason == "Finish the current edit in LensWorks first.")
            #expect(text(await fixture.invoke("image.invert")) == "Finish the current edit in LensWorks first." && session.document == kept)
            // The sheet lays out on the invisible test window, its buttons registered commands.
            fixture.harness.showWindow()
            let host = NSHostingView(rootView: LensWorksPluginStepsSheet(session: session, edit: sheet))
            fixture.harness.window.contentView = host; host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 100 && fixture.harness.window.alphaValue == 0)
            #expect(LensWorksCommandRegistry.descriptor(.pluginStepRerun).label == "Re-run with Installed Plugin" && LensWorksCommandRegistry.descriptor(.pluginStepRemove).label == "Remove Step")
            #expect(LensWorksCommandID.pluginSteps.agentAccess == .notRunnable(.pluginSteps))
            #expect(LensWorksCommandID.pluginStepRerun.agentAccess == .runnable(.document) && LensWorksCommandID.pluginStepRemove.agentAccess == .runnable(.document))

            // Re-running needs the plugin: with none installed it is refused and nothing changes.
            await #expect(throws: LensWorksCommandRefusal(reason: "The plugin \(id) is not installed. Install it, or remove the step.")) { try await session.rerunPluginStep(step.id) }
            await session.performPluginStep { try await session.rerunPluginStep(step.id) }.value
            #expect(sheet.error == "The plugin \(id) is not installed. Install it, or remove the step." && session.pluginSteps === sheet && session.document == kept)

            // Remove Step: the layer is developed without it, as one entry; the sheet has nothing left to list.
            var done: Task<Void, Never>?
            #expect(try LensWorksCommandDispatcher.perform(.init(.pluginStepRemove, step.id.uuidString)) { done = session.performPluginStep { try await session.removePluginStep(step.id) } })
            await done?.value
            #expect(session.pluginSteps == nil && session.history.undoCount == 1 && session.history.undoName == "Remove Plugin Step: Sample Invert")
            let cleared = try source(session)
            #expect(cleared.plugins.isEmpty && cleared.operations.isEmpty && cleared.id == step.sourceID)
            #expect(try pixels(try plane(session)) == pixels(try await LWSourceDeveloper.shared.evaluatePlane(cleared).surface) && (try pixels(try plane(session))) != keptPixels)
            // And the layer develops again.
            try await develop(session) { $0.exposure = 0.5 }
            #expect(try session.brushError == nil && (try source(session)).settings.exposure == 0.5 && session.history.undoCount == 2)
            // One Undo each: the development, then the removal — the step and its pixels are back.
            session.undo(); session.undo()
            #expect(try session.document == kept && (try source(session)).plugins == [step])
            // An agent removes the step by its id: one labeled entry that one Undo reverts.
            let removed = await fixture.invoke("plugin.step.remove", ["step": step.id.uuidString])
            #expect(removed["isError"] as? Bool == false, "\(text(removed))")
            #expect(try (try source(session)).plugins.isEmpty && session.history.undoName == "Remove Plugin Step: Sample Invert (Agent)" && session.history.undoOrigin == .agent)
            session.undo()
            #expect(try session.document == kept && (try source(session)).plugins == [step])
        }
    }

    // MARK: The installed plugin is not the code that made the step

    @Test func aRetainedStepNeverRunsWithDifferentCodeUntilThePersonReRunsIt() async throws {
        try await live { fixture, session, store in
            let id = Samples.id("invert")
            // The plugin's own package folder, so it can be rebuilt and reloaded.
            let package = fixture.harness.root.appendingPathComponent("invert.lwplugin", isDirectory: true)
            try FileManager.default.copyItem(at: Samples.package("invert"), to: package)
            let first = try await store.install(from: package).plugin
            try await session.runPlugin(id, values: [])
            session.history.reset()
            let step = try #require(try source(session).plugins.first)
            // The plugin is rebuilt (the gradient sample's module under the same id) and reloaded.
            let rebuilt = try Samples.module("gradient")
            try rebuilt.write(to: package.appendingPathComponent("filter.wasm"))
            let second = try await store.reload(id).plugin
            #expect(second.moduleHash == LensWorksPluginManifest.sha256(rebuilt) && second.moduleHash != first.moduleHash)
            let kept = session.document, keptPixels = try pixels(try plane(session))

            // The installed code is not the code that made the step: the development stops and says so, naming
            // both hashes. It does not run the new code in the old step's place.
            let problem = LWSourceRetainedPluginProblem(step, .changed(installed: second.moduleHash))
            #expect(problem.reason == "The installed plugin is not the code that made this step: its module’s SHA-256 is \(second.moduleHash), and the step recorded \(first.moduleHash).")
            try await develop(session) { $0.exposure = 0.4 }
            #expect(session.brushError == problem.errorDescription && session.brushError?.contains(first.moduleHash) == true)
            session.brushError = nil
            #expect(try session.document == kept && session.history.undoCount == 0 && (try pixels(try plane(session))) == keptPixels)
            #expect(await session.pluginStepStates() == [LensWorksPluginStepState(step: step, problem: problem, installed: true)])
            #expect(text(await fixture.invoke("filter.apply", ["kind": "Camera Raw Filter", "settings": ["exposure": 0.4]])) == problem.errorDescription)
            // An agent re-runs it by the id the refusal named: the step is bound to the installed code, one labeled entry.
            let agentRerun = await fixture.invoke("plugin.step.rerun", ["step": step.id.uuidString])
            #expect(agentRerun["isError"] as? Bool == false, "\(text(agentRerun))")
            #expect(try (try source(session)).plugins.first?.moduleHash == second.moduleHash && session.history.undoName == "Re-run Plugin Step: Sample Invert (Agent)")
            session.undo()
            #expect(try session.document == kept && (try source(session)).plugins == [step])

            // Re-run with Installed Plugin: the step is bound to the installed module and the layer developed with it.
            session.beginPluginSteps()
            let sheet = try #require(session.pluginSteps)
            var done: Task<Void, Never>?
            #expect(try LensWorksCommandDispatcher.perform(.init(.pluginStepRerun, step.id.uuidString)) { done = session.performPluginStep { try await session.rerunPluginStep(step.id) } })
            await done?.value
            #expect(sheet.error == nil && session.history.undoCount == 1 && session.history.undoName == "Re-run Plugin Step: Sample Invert")
            let rerun = try #require(try source(session).plugins.first)
            #expect(try rerun.id == step.id && rerun.moduleHash == second.moduleHash && rerun.parameters == step.parameters && (try source(session)).plugins.count == 1)
            let developed = try await developedWithoutPlugins(session)
            #expect(try pixels(try plane(session)) == fresh(developed, module: rebuilt) && (try pixels(try plane(session))) != keptPixels)
            // The sheet stays open on the step, which now applies as recorded.
            #expect(session.pluginSteps === sheet && sheet.steps == [LensWorksPluginStepState(step: rerun, problem: nil, installed: true)])
            session.closePluginSteps()
            // It develops again with the new code; one Undo each restores the old step and its pixels.
            try await develop(session) { $0.exposure = 0.4 }
            #expect(session.brushError == nil && session.history.undoCount == 2)
            #expect(try pixels(try plane(session)) == fresh(try await developedWithoutPlugins(session), module: rebuilt))
            session.undo(); session.undo()
            #expect(try session.document == kept && (try source(session)).plugins == [step])

            // Installed files changed behind LensWorks's back are not the plugin either.
            try Data("changed".utf8).write(to: store.directory.appendingPathComponent(id).appendingPathComponent("filter.wasm"))
            #expect(await session.pluginStepStates().first?.problem == LWSourceRetainedPluginProblem(step, .damaged(LensWorksPluginStore.changedProblem)))
            try await develop(session) { $0.exposure = 0.4 }
            #expect(session.brushError?.contains("The plugin cannot run. " + LensWorksPluginStore.changedProblem) == true && session.document == kept)
            session.brushError = nil
        }
    }

    // MARK: Save and reopen

    @Test func aRetainedPluginStepSurvivesSaveAndReopenInFormatVersion14() async throws {
        try await live { fixture, session, store in
            let id = Samples.id("brightness"), module = try Samples.module("brightness")
            try await store.install(from: Samples.package("brightness"))
            func header(_ file: URL) throws -> Int? {
                (try JSONSerialization.jsonObject(with: Data(contentsOf: file.appendingPathComponent("manifest.json"))) as? [String: Any])?["version"] as? Int
            }
            // A live RAW project with no plugin step is still written as version 13.
            let plain = fixture.granted.appendingPathComponent("Plain.comp")
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: plain)
            #expect(try header(plain) == 13 && ProjectManifest.float == 13 && ProjectManifest.current == 14)

            let values = [0.25, 2, 0, 3.0]
            try await session.runPlugin(id, values: values)
            let saved = try source(session), step = try #require(saved.plugins.first), savedPixels = try pixels(try plane(session))
            #expect(step.parameters == values && saved.usesFormat14)
            let file = fixture.granted.appendingPathComponent("Retained.comp")
            let snapshot = try #require(session.projectSnapshot())
            #expect(ProjectStore.usesVersion14(snapshot.manifest) && ProjectStore.writtenVersion(snapshot.manifest) == 14)
            try await ProjectStore.shared.save(snapshot, to: file)
            #expect(try header(file) == 14, "a retained plugin step is version-14 content")

            let reopened = try await ProjectStore.shared.load(from: file)
            #expect(reopened.manifest.version == 14)
            let restored = EditorSession()
            restored.plugins = store
            restored.installProject(reopened, from: file)
            let source = try #require(restored.activeLayer?.liveSource)
            #expect(source == saved && source.plugins == [step] && source.operations == [.plugin(step.id)])
            #expect(try pixels(try plane(restored)) == savedPixels)
            // Still live after reopening: a recipe change runs the retained step with its recorded values.
            try await develop(restored) { $0.exposure = 0.3 }
            #expect(restored.brushError == nil, "\(restored.brushError ?? "")")
            let redeveloped = try await developedWithoutPlugins(restored)
            #expect(try pixels(try plane(restored)) == fresh(redeveloped, module: module, parameters: values))
            #expect(try pixels(try plane(restored)) != redeveloped)

            // A package whose header claims version 13 cannot carry a retained plugin step.
            let manifest = file.appendingPathComponent("manifest.json")
            var fields = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            fields["version"] = 13
            try JSONSerialization.data(withJSONObject: fields).write(to: manifest)
            await #expect(throws: ProjectError.self) { _ = try await ProjectStore.shared.load(from: file) }
        }
    }

    // MARK: A plugin that fails, or is cancelled, while the RAW is developed

    @Test func aPluginThatFailsWhileTheRawIsDevelopedLeavesThePreviousPixelsAndReports() async throws {
        try await live { fixture, session, store in
            let trap = try await store.install(from: Samples.package("trap")).plugin
            // A step retained for a plugin that traps when run.
            let layer = try #require(session.activeLayer), index = try #require(session.document?.layers.firstIndex { $0.id == layer.id })
            var node = try source(session)
            let step = LWSourceRetainedPlugin(id: UUID(), sourceID: node.id, upstreamRevision: node.revision, plugin: trap.id, name: trap.manifest.name,
                                              moduleHash: trap.moduleHash, interface: 1, parameters: [], captureFrame: try node.capturedFrame(transform: layer.transform), selectionPlaneID: nil)
            node.revision = UUID(); node.sourceLineage.append(node.revision); try node.appendPlugin(step)
            session.document?.layers[index].liveSource = node
            session.history.reset()
            let kept = session.document, keptImage = try #require(session.activeLayer?.asset?.image)
            #expect(await session.pluginStepStates() == [LensWorksPluginStepState(step: step, problem: nil, installed: true)], "installed and unchanged: only running it fails")

            try await develop(session) { $0.exposure = 0.5 }
            let reason = "The retained plugin step \(trap.manifest.name) (\(trap.id)) on this layer could not be applied again, so the layer was not changed. The plugin failed. It trapped (reached unreachable code) and was stopped. " + LWSourceRetainedPluginProblem(step, .notInstalled).remedy
            #expect(session.brushError == reason)
            session.brushError = nil
            #expect(session.document == kept && session.activeLayer?.asset?.image === keptImage && session.history.undoCount == 0 && !session.isProjectBusy)
            #expect(text(await fixture.invoke("filter.apply", ["kind": "Camera Raw Filter", "settings": ["exposure": 0.5]])) == reason && session.document == kept)

            // Running a failing plugin on the live layer changes nothing either, and retains nothing.
            let failure = "The plugin \(trap.manifest.name) (\(trap.id)) failed, and the document was not changed. It trapped (reached unreachable code) and was stopped."
            await #expect(throws: LensWorksPluginFailure(failure)) { try await session.runPlugin(trap.id, values: []) }
            #expect(session.document == kept && session.history.undoCount == 0 && session.pluginRun == nil && !session.isProjectBusy)
        }
    }

    /// The step itself, with no RAW decoder: cancelling between tiles stops it with the plane it was given
    /// untouched, a whole-run budget stops a slow plugin, and the order of operations stays valid.
    @Test func aRetainedStepStopsWhenCancelledOrOverBudgetAndLeavesItsInputUntouched() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = fixture.session.plugins
        let slow = try await store.install(from: Samples.package("slow")).plugin, module = try Samples.module("slow")
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let width = 300, height = 280
        // A 300×280 float plane: four stored tiles.
        func gradient(_ workspace: LWFloatWorkspace) throws -> LWFloatPlane {
            let builder = try workspace.makeBuilder(width: width, height: height)
            while let range = builder.nextRange {
                let values = (0..<range.width * range.height).map { index -> SIMD4<Float> in
                    SIMD4(Float(range.x + index % range.width) / 300, Float(range.y + index / range.width) / 280, 0.25, 1)
                }
                try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: values, maximumBytes: range.width * range.height * 16), at: range)
            }
            return try builder.finish()
        }
        let input = try gradient(workspace), before = try pixels(input)
        let node0 = try FloatRetouchFixture().node(width: width, height: height), transform = LayerTransform(origin: .zero, size: CGSize(width: width, height: height))
        let map = try node0.currentSpatialMap

        // Run whole it is retained in order and gives the plugin's pixels in every stored tile.
        let made = try LWSourcePluginPreparation.prepare(node0, before: input, map: map, plugin: slow, module: module, parameters: [10], selection: nil, transform: transform, workspace: workspace)
        let step = try #require(made.node.plugins.first)
        #expect(made.node.operations == [.plugin(step.id)] && step.parameters == [10] && node0.plugins.isEmpty)
        #expect(try pixels(made.plane) == before.map { SIMD4(1 - $0.x, 1 - $0.y, 1 - $0.z, $0.w) } && (try pixels(input)) == before)
        // Applied again by a development — resolved from the installed copy — it gives the same pixels.
        let replayed = try LensWorksRetainedPlugins.$directory.withValue(store.directory) {
            try LWSourceOperationReplay.evaluate(made.node, developed: input, map: map, workspace: workspace)
        }
        #expect(try pixels(replayed.surface) == pixels(made.plane))
        // Under the person's own (shared) store the plugin is not installed, and the development says so.
        #expect(throws: LWSourceRetainedPluginProblem(step, .notInstalled)) {
            _ = try LensWorksRetainedPlugins.$directory.withValue(fixture.harness.root.appendingPathComponent("no-plugins")) {
                try LWSourceOperationReplay.evaluate(made.node, developed: input, map: map, workspace: workspace)
            }
        }

        // Cancelled after its first tile it stops before the next, and the plane it was given is as it was.
        final class Count: @unchecked Sendable { var tiles = 0 }
        let count = Count()
        let stopping = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let again = try gradient(stopping)
        #expect(throws: (any Error).self) {
            _ = try step.run(module: module, node: made.node, plane: again, map: map, workspace: stopping) { _ in count.tiles += 1; stopping.cancellation.cancel() }
        }
        #expect(count.tiles == 1, "it stopped before its second tile")
        #expect(throws: (any Error).self) { try stopping.cancellation.check() }

        // A whole-run budget smaller than the run needs stops it, reported as the step's failure.
        let spins = 1_900_000.0
        let costly = LWSourceRetainedPlugin(id: step.id, sourceID: step.sourceID, upstreamRevision: step.upstreamRevision, plugin: step.plugin, name: step.name, moduleHash: step.moduleHash,
                                            interface: 1, parameters: [spins], captureFrame: step.captureFrame, selectionPlaneID: nil)
        #expect(throws: LensWorksPluginFailure("It used up its execution budget of 30000000 fuel for the whole run and was stopped.")) {
            _ = try costly.run(module: module, node: made.node, plane: input, map: map, workspace: workspace, runFuel: 30_000_000)
        }
        #expect(try pixels(input) == before)

        // The order of operations admits each retained plugin step exactly once.
        var doubled = try made.node.metadataCopy(additionalBytes: 4096)
        doubled.operations.append(.plugin(step.id))
        #expect(throws: ProjectError.self) { try doubled.validateOperationOrder() }
        var orphaned = try made.node.metadataCopy(additionalBytes: 4096)
        orphaned.operations.removeAll()
        #expect(throws: ProjectError.self) { try orphaned.validateOperationOrder() }
        #expect(try made.node.removingPlugin(step.id).operations.isEmpty && made.node.removingPlugin(step.id).plugins.isEmpty)
    }

    // MARK: The persisted record

    /// The retained step as a project stores it, held to a checked-in fixture so the format cannot drift unnoticed.
    @Test func theRetainedPluginStepRecordMatchesItsCheckedInFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/retained-plugin-step.v14.json")
        let data = try Data(contentsOf: url)
        let step = try JSONDecoder().decode(LWSourceRetainedPlugin.self, from: data)
        #expect(step.id == UUID(uuidString: "0F5C4E1A-7B1D-4C0E-9A63-2D1B5E8F7A10") && step.sourceID == UUID(uuidString: "6A1E0C55-3B7F-4D2A-8E91-5C4D3B2A1F00")
                && step.upstreamRevision == UUID(uuidString: "C2D3E4F5-0617-4829-A3B4-C5D6E7F80912"))
        #expect(step.plugin == "com.lensworks.sample.brightness" && step.name == "Sample Brightness" && step.interface == 1 && step.parameters == [0.25, 2, 0, 3]
                && step.moduleHash == "d923b62a1ac8592118d7bd4ef271fe37fa3638a9007ee543bbb6411c5255e1d5" && step.selectionPlaneID == UUID(uuidString: "9B8A7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D"))
        #expect(step.captureFrame.width == 96 && step.captureFrame.height == 64 && step.captureFrame.layerTransform == LayerTransform(origin: CGPoint(x: 4, y: 8), size: CGSize(width: 96, height: 64)))
        #expect(try step.moduleHash == LensWorksPluginManifest.sha256(try Samples.module("brightness")), "the fixture names the committed sample’s module")
        // Written again it is the fixture, key for key.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let written = try #require(try JSONSerialization.jsonObject(with: encoder.encode(step)) as? NSDictionary)
        #expect(try written == (try JSONSerialization.jsonObject(with: data) as? NSDictionary))
        // A key the record does not define, a missing one, and values outside it are refused, not ignored.
        func refused(_ change: (inout [String: Any]) -> Void) throws -> Bool {
            var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            change(&fields)
            return (try? JSONDecoder().decode(LWSourceRetainedPlugin.self, from: JSONSerialization.data(withJSONObject: fields))) == nil
        }
        #expect(try refused { $0["script"] = "x" } && refused { $0["moduleHash"] = nil } && refused { $0["moduleHash"] = "D923" } && refused { $0["plugin"] = "Not An Id" }
                && refused { $0["name"] = "Sample — Agent" } && refused { $0["interface"] = 0 } && refused { $0["parameters"] = Array(repeating: 1.0, count: 17) })
        #expect(try !refused { $0["selectionPlaneID"] = nil } && !refused { _ in })
    }

    // MARK: Pixel edits that are not retained on a live RAW source

    /// Fill, Clear and Transform Selection are not kept with a RAW development: on a live RAW layer each is refused
    /// with its reason, and the layer keeps its pixels, its source and its effects.
    @Test func fillClearAndTransformSelectionAreRefusedOnALiveRawLayerWhichStaysLive() async throws {
        try await live { _, session, _ in
            let layer = try #require(session.activeLayer)
            let frame = CGRect(origin: layer.transform.origin, size: layer.transform.size)
            session.applySelection(CGPath(rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height), transform: nil), mode: .replace, name: "Marquee")
            session.history.reset()
            let kept = session.document, image = try #require(layer.asset?.image)
            for (name, edit) in [("Fill", { await session.fillSelection(with: .foreground) }), ("Clear", { await session.clearSelectedPixels() }),
                                 ("Transform Selection", { await session.beginSelectionTransform() })] as [(String, @MainActor () async -> Void)] {
                await edit()
                #expect(session.brushError == "“\(layer.name)” is a live RAW layer, and \(name) is not kept with its RAW development, so it was not applied and the layer stays live. Use a new layer above it, or the Brush, which the layer keeps.", "\(name)")
                session.brushError = nil
                #expect(session.document == kept && session.activeLayer?.asset?.image === image && session.history.undoCount == 0 && session.transformEdit == nil, "\(name)")
            }
        }
    }

    // MARK: Invert on a live RAW layer

    @Test func invertOnALiveRawLayerIsRetainedAndTheLayerStaysLive() async throws {
        try await live { fixture, session, _ in
            // The layer has effects of its own, which Invert keeps along with its source.
            let effects = LayerEffects(stroke: StrokeEffect(size: 3, red: 1, green: 1, blue: 1), shadow: ShadowEffect())
            session.document?.layers[0].effects = effects
            session.history.reset()
            let before = session.document, node0 = try source(session), developed = try pixels(try plane(session))
            await session.invertPixels()
            #expect(session.activeLayer?.effects == effects, "Invert kept the layer’s stroke and drop shadow")
            #expect(session.brushError == nil, "\(session.brushError ?? "")")
            let node1 = try source(session), retained = try #require(node1.adjustments.first)
            #expect(node1.adjustments.count == 1 && retained.settings.kind == .invert && node1.operations == [.adjustment(retained.id)] && node1.id == node0.id && node1.usesFormat14)
            #expect(session.activeLayer?.asset?.linearPlane != nil && session.history.undoCount == 1 && session.history.undoName == "Invert")
            // In float: each color is one minus its display-encoded value; alpha is kept.
            typealias K = FloatImageAdjustmentPixels
            let made = try pixels(try plane(session))
            func inverted(_ value: Float) -> Float { Float(K.decode(1 - K.encode(Double(value)))) }
            let at = 30 * 96 + 50
            #expect(made[at].w == developed[at].w && made != developed)
            for channel in 0..<3 { #expect(abs(made[at][channel] - inverted(developed[at][channel])) < 1e-5, "channel \(channel)") }
            // Developed again, the new development is inverted.
            try await develop(session) { $0.exposure = 0.5 }
            #expect(try session.brushError == nil && (try source(session)).adjustments == [retained])
            var plain = try source(session); plain.adjustments = []; plain.operations = []
            let redeveloped = try pixels(try await LWSourceDeveloper.shared.evaluatePlane(plain).surface), now = try pixels(try plane(session))
            for channel in 0..<3 { #expect(abs(now[at][channel] - inverted(redeveloped[at][channel])) < 1e-5, "channel \(channel) after developing again") }
            // A project holding a retained Invert is version-14 content, and reopens with it.
            let file = fixture.granted.appendingPathComponent("Inverted.comp")
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
            let reopened = try await ProjectStore.shared.load(from: file)
            #expect(try reopened.manifest.version == 14 && reopened.manifest.layers.first?.liveSource == (try source(session)))
            // One Undo each restores the layer, its source included.
            session.undo(); session.undo()
            #expect(session.document == before && session.activeLayer?.liveSource == node0)
        }
    }
}
