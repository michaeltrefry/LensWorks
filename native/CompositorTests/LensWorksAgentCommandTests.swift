import AppKit
import Foundation
import Testing
@testable import Compositor

/// S40: every registered command is runnable by an agent or says specifically why not; file paths stay inside the
/// folders the person granted; and nothing irreversible runs without the person's confirmation in the app.
/// Fixtures only: a throwaway defaults suite, an in-memory secret, temp directories, a private pasteboard, and
/// confirmations that stay invisible and are answered by the test itself.
@Suite(.serialized)
@MainActor
struct LensWorksAgentCommandTests {
    typealias Harness = LensWorksAutomationTests.Harness

    /// A harness with a document, its project controller, a private clipboard and one granted temp folder.
    @MainActor final class Fixture {
        let harness: Harness
        let session = EditorSession()
        let controller: ProjectController
        let granted: URL, outside: URL
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lensworks-test-\(UUID().uuidString)"))
        var tools: LensWorksAgentTools { harness.automation.tools }
        init(grant: Bool = true) throws {
            harness = try Harness()
            controller = ProjectController(session: session)
            controller.recordsRecentProjects = false
            session.pasteboard = pasteboard
            // The temp directory's real path, so a path compares equal after symbolic links are resolved.
            let root = URL(fileURLWithPath: try LensWorksGrantedFolders.realPath(harness.root.path))
            granted = root.appendingPathComponent("granted"); outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            harness.session = session
            let controller = controller
            harness.automation.tools.projects = { controller }
            if grant { try harness.automation.folders.grant(granted) }
        }
        func cleanUp() { pasteboard.releaseGlobally(); harness.cleanUp() }

        /// A 200×100 document: an opaque red layer under an opaque blue one, the blue one selected.
        func paint() throws {
            for (name, color) in [("Red", CGColor(red: 1, green: 0, blue: 0, alpha: 1)), ("Blue", CGColor(red: 0, green: 0, blue: 1, alpha: 1))] {
                session.insert(ImportedImage(image: try Self.image(color), thumbnail: try Self.image(color), name: name))
            }
            session.history.reset()
        }
        static func image(_ color: CGColor, width: Int = 200, height: Int = 100) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        func writePNG(_ url: URL, _ color: CGColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)) throws {
            try LensWorksAgentTools.boundedPNG(try Self.image(color, width: 8, height: 8), maxDimension: 8).data.write(to: url)
        }
        func invoke(_ command: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
            await tools.call("invoke_command", arguments: ["command": command, "arguments": arguments])
        }
        func layer(_ name: String) throws -> ImageLayer { try #require(session.document?.layers.first { $0.name == name }) }
        /// Runs `call` and answers the confirmation it raises (invisible, on the hidden test window).
        func answering(_ allow: Bool, _ call: @escaping @MainActor () async -> [String: Any]) async throws -> (result: [String: Any], asked: LensWorksAgentConfirmation?) {
            harness.showWindow()
            final class Box { var value: [String: Any]? }
            let box = Box()
            let running = Task { @MainActor in box.value = await call() }
            var asked: LensWorksAgentConfirmation?
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while box.value == nil, ContinuousClock.now < deadline {
                if let pending = harness.automation.pendingConfirmation { asked = pending; harness.automation.resolveConfirmation(allow); break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await running.value
            return (box.value ?? [:], asked)
        }
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")
    }
    private func ok(_ result: [String: Any]) -> Bool { result["isError"] as? Bool == false }
    private func content(_ result: [String: Any]) -> [String: Any] { result["structuredContent"] as? [String: Any] ?? [:] }

    // MARK: Criterion 1 — the whole registry

    /// Enumerates the registry: every command is admitted (typed, schema-described arguments that reach the
    /// command's own admission) or carries a reason specific to it. Prints the table the pull request reports.
    @Test func everyRegisteredCommandIsRunnableByAnAgentOrSaysSpecificallyWhyNot() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let rows = Dictionary(uniqueKeysWithValues: fixture.tools.listCommands().compactMap { row in (row["id"] as? String).map { ($0, row) } })
        #expect(rows.count == LensWorksCommandID.allCases.count)
        let generic = ["not yet", "not exposed", "only from its menu", "unsupported", "not available to agents yet"]
        var table: [String: (admitted: Int, excluded: [LensWorksAgentExclusion: Int])] = [:]
        for descriptor in LensWorksCommandRegistry.descriptors {
            let id = descriptor.id.rawValue, row = try #require(rows[id])
            let group = String(descriptor.menu.split(separator: "/").first ?? "")
            switch descriptor.agent {
            case .runnable(let kind):
                table[group, default: (0, [:])].admitted += 1
                #expect(row["agentInvocable"] as? Bool == true && row["kind"] as? String == kind.rawValue, "\(id)")
                let schema = try #require(row["inputSchema"] as? [String: Any], "\(id)")
                let properties = try #require(schema["properties"] as? [String: Any], "\(id)")
                #expect(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false, "\(id)")
                // Every registered parameter is in the schema with a type and a description, and nothing else is.
                #expect(Set(properties.keys) == Set(descriptor.parameters.map(\.name)), "\(id)")
                for parameter in descriptor.parameters {
                    let property = try #require(properties[parameter.name] as? [String: Any], "\(id).\(parameter.name)")
                    #expect(property["type"] != nil && (property["description"] as? String)?.isEmpty == false, "\(id).\(parameter.name)")
                    if parameter.type == .choice { #expect((property["enum"] as? [String])?.isEmpty == false, "\(id).\(parameter.name)") }
                }
                #expect(Set(schema["required"] as? [String] ?? []) == Set(descriptor.parameters.filter(\.required).map(\.name)), "\(id)")
                // A reason it cannot run now is about the app's state, never "agents cannot".
                if let reason = row["reason"] as? String { #expect(LensWorksAgentExclusion(rawValue: reason) == nil && !reason.isEmpty, "\(id): \(reason)") }
                // It reaches its typed admission: an undeclared argument is refused by name, not by "cannot run".
                let stray = await fixture.invoke(id, ["__undeclared": 1])
                #expect(stray["isError"] as? Bool == true && text(stray).hasPrefix("Unknown argument “__undeclared” for \(id)."), "\(id): \(text(stray))")
            case .notRunnable(let exclusion):
                table[group, default: (0, [:])].excluded[exclusion, default: 0] += 1
                let reason = try #require(row["reason"] as? String, "\(id)")
                #expect(row["agentInvocable"] as? Bool == false && row["available"] as? Bool == false && reason == exclusion.rawValue, "\(id)")
                #expect(reason.count > 40 && !generic.contains { reason.localizedCaseInsensitiveContains($0) }, "\(id): \(reason)")
                let refused = await fixture.invoke(id)
                #expect(refused["isError"] as? Bool == true && text(refused) == "Agents cannot run \(id). " + reason, "\(id)")
            }
        }
        // Every reason is in use, and none is shared by commands of unrelated purpose by accident.
        let used = Set(LensWorksCommandID.allCases.compactMap(\.agentAccess.exclusion))
        #expect(used == Set(LensWorksAgentExclusion.allCases))
        // What changes a document, the catalog, a selection or a file is admitted.
        let mustRun: [LensWorksCommandID] = [
            .newBlankLayer, .duplicateLayer, .deleteLayer, .groupLayers, .ungroupLayers, .mergeLayers, .moveLayerUp, .moveLayerDown, .moveOutOfFolder,
            .addMask, .toggleMask, .deleteMask, .linkMask, .clippingMask, .blendMode, .opacity, .visibility, .rename, .addEffect, .newAdjustment, .editAdjustment,
            .transform, .flipLayerHorizontal, .flipLayerVertical, .selectLayers, .selectPhotos,
            .curves, .levels, .hueSaturation, .imageAdjustment, .invert, .filter, .canvasSize, .imageSize, .trim, .flipCanvasHorizontal, .flipCanvasVertical,
            .selectAll, .deselect, .inverseSelection, .selectLayerPixels, .selectSubject, .colorRange, .selectMaskBlack, .expandSelection, .contractSelection, .featherSelection,
            .cut, .copyPixels, .copyMerged, .paste, .fillForeground, .fillBackground, .clearSelectionPixels, .contentAwareFill, .clearGuides,
            .addKeyword, .removeKeyword, .renameKeyword, .moveKeyword, .addSynonym, .deleteKeyword, .ratePhotos, .flagPhotos, .labelPhotos, .rating,
            .filterRating, .filterFlag, .filterLabel, .filterAnyKeyword, .clearFilters, .sortBy, .sortDirection,
            .addToVirtualFolder, .removeFromVirtualFolder, .renameVirtualFolder, .moveVirtualFolder, .deleteVirtualFolder,
            .openProject, .openRecent, .importImages, .save, .saveAs, .exportPNG, .exportJPEG, .openCatalog, .newCatalog, .addPhotos, .newCanvas, .undo, .redo
        ]
        #expect(mustRun.filter { !$0.agentAccess.isRunnable }.isEmpty)
        // A command that enters document or catalog history is never left out.
        #expect(Set(LensWorksCommandRegistry.descriptors.filter { $0.historyOwner != .none && !$0.agent.isRunnable }.map(\.id)).isSubset(of: [.apply, .opacityDigit, .finishText, .tracking, .leading]))
        let admitted = LensWorksCommandRegistry.agentCommands.count
        print("AGENT-TABLE total=\(LensWorksCommandID.allCases.count) admitted=\(admitted) notRunnable=\(LensWorksCommandID.allCases.count - admitted)")
        for (group, counts) in table.sorted(by: { $0.key < $1.key }) {
            print("AGENT-TABLE | \(group) | \(counts.admitted) | \(counts.excluded.values.reduce(0, +)) | " + counts.excluded.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value)× \($0.key)" }.joined(separator: ", ") + " |")
        }
        for exclusion in LensWorksAgentExclusion.allCases {
            print("AGENT-REASON | \(exclusion) | \(LensWorksCommandID.allCases.filter { $0.agentAccess.exclusion == exclusion }.count) | \(exclusion.rawValue) |")
        }
    }

    /// The reason an agent is refused with is the reason the menu item shows: one function answers both.
    @Test func anAgentIsRefusedWithTheMenusOwnReasonForEveryDocumentCommand() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session
        let documents = LensWorksCommandRegistry.agentCommands.filter { $0.agentAccess.kind == .document && !LensWorksAgentTools.layerCommands.contains($0) }
        @MainActor func compare(_ state: Comment) {
            for id in documents {
                let menu = session.menuReason(id, canStart: fixture.controller.canStart)
                let listed = fixture.tools.agentAvailability(id)
                // Where the menu bar disables the item with a reason, the agent gets those words.
                if let menu, id != .newAdjustment, id != .transform, id != .groupLayers { #expect(listed == menu, "\(id.rawValue) \(state)") }
                #expect(listed == LensWorksAgentDocumentCommands(session: session, context: fixture.tools.context).reason(id), "\(id.rawValue) \(state)")
            }
        }
        compare("two layers, one selected")
        session.selectLayers([], primary: nil)
        compare("no layer selected")
        let none = await fixture.invoke("layer.merge")
        #expect(text(none) == session.menuReason(.mergeLayers, canStart: true) && text(none) == "Select layers that can be merged first.")
        let noSelection = await fixture.invoke("select.deselect")
        #expect(text(noSelection) == "There is no selection." && session.menuReason(.deselect, canStart: true) == "There is no selection.")
        // Under the person's open edit every document command is refused, and nothing changes.
        session.selectLayers([try fixture.layer("Blue").id], primary: nil)
        session.cropRect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let before = session.document
        for id in documents where id != .importImages {
            #expect(fixture.tools.agentAvailability(id) == "Finish the current edit in LensWorks first.", "\(id.rawValue)")
        }
        for command in ["layer.newBlank", "image.invert", "select.all", "layer.delete"] {
            let refused = await fixture.invoke(command)
            #expect(refused["isError"] as? Bool == true && text(refused) == "Finish the current edit in LensWorks first.", "\(command)")
        }
        #expect(session.document == before && session.history.undoCount == 0 && session.cropRect != nil)
    }

    /// One scenario per document command: it runs through the dispatcher as the agent, changes the document as its
    /// menu item would, and lands in history as one agent entry that Undo reverts.
    @Test func everyDocumentCommandRunsAsTheAgentAndIsOneLabeledUndoableEntry() async throws {
        struct Scenario {
            let id: LensWorksCommandID
            var arguments: (Fixture) throws -> [String: Any] = { _ in [:] }
            var prepare: (Fixture) async throws -> Void = { _ in }
            /// What the document must show afterwards.
            var verify: (Fixture) throws -> Bool = { _ in true }
            /// Commands that change no document content (a selection of layers, the clipboard, the palette).
            var transient = false
        }
        @MainActor func selectAll(_ fixture: Fixture) { fixture.session.selectAll(); fixture.session.history.reset() }
        @MainActor func ids(_ fixture: Fixture) throws -> [String] { [try fixture.layer("Red").id.uuidString, try fixture.layer("Blue").id.uuidString] }
        let scenarios: [Scenario] = [
            .init(id: .selectLayers, arguments: { ["layers": [try $0.layer("Red").id.uuidString]] }, verify: { $0.session.activeLayer?.name == "Red" }, transient: true),
            .init(id: .newBlankLayer, verify: { $0.session.document?.layers.count == 3 }),
            .init(id: .duplicateLayer, arguments: { ["layers": [try $0.layer("Red").id.uuidString]] }, verify: { $0.session.document?.layers.count == 3 }),
            .init(id: .layerViaCopy, verify: { $0.session.document?.layers.count == 3 }),
            .init(id: .groupLayers, arguments: { ["layers": try ids($0)] }, verify: { $0.session.document?.layers.contains(where: \.isGroup) == true }),
            .init(id: .ungroupLayers, prepare: { $0.session.selectLayers(Set($0.session.document!.layers.map(\.id)), primary: nil); $0.session.groupSelectedLayers(); $0.session.history.reset() },
                  verify: { $0.session.document?.layers.contains(where: \.isGroup) == false }),
            .init(id: .moveOutOfFolder, arguments: { ["layer": try $0.layer("Blue").id.uuidString] },
                  prepare: { $0.session.selectLayers(Set($0.session.document!.layers.map(\.id)), primary: nil); $0.session.groupSelectedLayers(); $0.session.history.reset() },
                  verify: { try $0.layer("Blue").parentID == nil }),
            .init(id: .moveLayerDown, verify: { $0.session.document?.layers.last?.name == "Red" }),
            .init(id: .moveLayerUp, arguments: { ["layer": try $0.layer("Red").id.uuidString] }, verify: { $0.session.document?.layers.last?.name == "Red" }),
            .init(id: .mergeLayers, verify: { $0.session.document?.layers.count == 1 }),
            .init(id: .deleteLayer, arguments: { ["layers": [try $0.layer("Red").id.uuidString]] }, verify: { $0.session.document?.layers.map(\.name) == ["Blue"] }),
            .init(id: .canvasDelete, verify: { $0.session.document?.layers.map(\.name) == ["Red"] }),
            .init(id: .flipLayerHorizontal, verify: { try $0.layer("Blue").transform.flipX }),
            .init(id: .flipLayerVertical, verify: { try $0.layer("Blue").transform.flipY }),
            .init(id: .clippingMask, verify: { try $0.layer("Blue").maskSourceID == $0.layer("Red").id }),
            .init(id: .addMask, arguments: { _ in ["fill": "black"] }, verify: { try $0.layer("Blue").mask != nil }),
            .init(id: .toggleMask, prepare: { $0.session.addLayerMask(); $0.session.history.reset() }, verify: { try $0.layer("Blue").mask?.isEnabled == false }),
            .init(id: .linkMask, prepare: { $0.session.addLayerMask(); $0.session.history.reset() }, verify: { try $0.layer("Blue").mask?.isLinked == false }),
            .init(id: .deleteMask, prepare: { $0.session.addLayerMask(); $0.session.history.reset() }, verify: { try $0.layer("Blue").mask == nil }),
            .init(id: .selectMaskBlack, prepare: { $0.session.addLayerMask(revealing: false); $0.session.history.reset() }, verify: { $0.session.selection != nil }),
            .init(id: .blendMode, arguments: { _ in ["mode": LayerBlendMode.multiply.rawValue] }, verify: { try $0.layer("Blue").blendMode == .multiply }),
            .init(id: .addEffect, arguments: { _ in ["kind": "Stroke", "settings": ["size": 7]] }, verify: { try $0.layer("Blue").effects?.stroke?.size == 7 && $0.session.effectsEditing == nil }),
            .init(id: .newAdjustment, arguments: { _ in ["kind": "Exposure", "settings": ["exposure": 1.5]] },
                  verify: { $0.session.document?.layers.first { $0.adjustment != nil }?.adjustment?.exposure.exposure == 1.5 && $0.session.adjustmentEditingID == nil }),
            .init(id: .editAdjustment, arguments: { _ in ["settings": ["exposure": -1]] }, prepare: { $0.session.addAdjustment(.exposure); $0.session.adjustmentEditingID = nil; $0.session.history.reset() },
                  verify: { $0.session.activeLayer?.adjustment?.exposure.exposure == -1 }),
            .init(id: .transform, arguments: { _ in ["x": 10, "y": 5, "width": 100, "height": 50] },
                  verify: { try $0.layer("Blue").transform.origin == CGPoint(x: 10, y: 5) && $0.layer("Blue").transform.size == CGSize(width: 100, height: 50) && $0.session.transformEdit == nil }),
            .init(id: .nudge, arguments: { _ in ["step": "right.10"] }, verify: { try $0.layer("Blue").transform.origin.x == 10 }),
            .init(id: .selectAll, verify: { $0.session.selection != nil }),
            .init(id: .deselect, prepare: { selectAll($0) }, verify: { $0.session.selection == nil }),
            .init(id: .inverseSelection, prepare: { $0.session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), mode: .replace, name: "Marquee"); $0.session.history.reset() },
                  verify: { $0.session.selection?.path.contains(CGPoint(x: 150, y: 80)) == true }),
            .init(id: .selectLayerPixels, verify: { $0.session.selection != nil }),
            .init(id: .expandSelection, arguments: { _ in ["amount": 5] },
                  prepare: { $0.session.applySelection(CGPath(rect: CGRect(x: 20, y: 20, width: 20, height: 20), transform: nil), mode: .replace, name: "Marquee"); $0.session.history.reset() },
                  verify: { ($0.session.selection?.path.boundingBoxOfPath.width ?? 0) > 25 }),
            .init(id: .contractSelection, arguments: { _ in ["amount": 5] },
                  prepare: { $0.session.applySelection(CGPath(rect: CGRect(x: 20, y: 20, width: 40, height: 40), transform: nil), mode: .replace, name: "Marquee"); $0.session.history.reset() },
                  verify: { ($0.session.selection?.path.boundingBoxOfPath.width ?? 99) < 35 }),
            .init(id: .featherSelection, arguments: { _ in ["amount": 4] }, prepare: { selectAll($0) }, verify: { $0.session.selection?.feather == 4 }),
            .init(id: .colorRange, arguments: { _ in ["x": 10, "y": 10, "fuzziness": 20] }, verify: { $0.session.selection != nil && $0.session.colorRange == nil }),
            .init(id: .fillForeground, arguments: { _ in ["color": "#00FF00"] }, verify: { $0.session.foregroundColor == PaletteColor(red: 0, green: 1, blue: 0) }),
            .init(id: .fillBackground, arguments: { _ in ["color": "#FFFF00"] }),
            .init(id: .clearSelectionPixels, prepare: { selectAll($0) }),
            .init(id: .cut, prepare: { selectAll($0) }, verify: { $0.pasteboard.data(forType: .png) != nil }),
            .init(id: .copyPixels, prepare: { selectAll($0) }, verify: { $0.pasteboard.data(forType: .png) != nil }, transient: true),
            .init(id: .copyMerged, prepare: { selectAll($0) }, verify: { $0.pasteboard.data(forType: .png) != nil }, transient: true),
            .init(id: .paste, prepare: { selectAll($0); $0.session.copySelection() }, verify: { $0.session.document?.layers.count == 3 }),
            .init(id: .movePixels, arguments: { _ in ["step": "down.10"] },
                  prepare: { $0.session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), mode: .replace, name: "Marquee"); $0.session.history.reset() }),
            .init(id: .invert),
            .init(id: .curves, arguments: { _ in ["settings": ["channels": [[["x": 0, "y": 0], ["x": 128, "y": 200], ["x": 255, "y": 255]], [["x": 0, "y": 0], ["x": 255, "y": 255]], [["x": 0, "y": 0], ["x": 255, "y": 255]], [["x": 0, "y": 0], ["x": 255, "y": 255]]]]] }),
            .init(id: .levels, arguments: { _ in ["settings": ["ranges": [["black": 40, "gamma": 1, "white": 200, "outputBlack": 0, "outputWhite": 255], ["black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255],
                                                                    ["black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255], ["black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255]]]] }),
            .init(id: .hueSaturation, arguments: { _ in ["settings": ["hue": 90, "range": "Master"]] }),
            .init(id: .imageAdjustment, arguments: { _ in ["kind": "Exposure", "settings": ["exposure": 1]] }),
            .init(id: .filter, arguments: { _ in ["kind": "Gaussian Blur", "settings": ["radius": 6]] }, verify: { $0.session.filterEdit == nil && $0.session.filterSettings.radius == 6 }),
            .init(id: .canvasSize, arguments: { _ in ["width": 300, "height": 150, "anchor": "topLeft"] }, verify: { $0.session.document?.width == 300 && $0.session.document?.height == 150 }),
            .init(id: .imageSize, arguments: { _ in ["width": 100, "height": 50] }, verify: { $0.session.document?.width == 100 && $0.session.document?.height == 50 }),
            .init(id: .trim, prepare: { fixture in
                      // Shrink both layers so the canvas has an empty border to trim.
                      for name in ["Red", "Blue"] { let index = fixture.session.document!.layers.firstIndex { $0.name == name }!
                          fixture.session.document!.layers[index].transform = LayerTransform(origin: CGPoint(x: 50, y: 25), size: CGSize(width: 100, height: 50)) }
                      fixture.session.history.reset() },
                  verify: { $0.session.document?.width == 100 && $0.session.document?.height == 50 }),
            .init(id: .flipCanvasHorizontal), .init(id: .flipCanvasVertical),
            .init(id: .clearGuides, prepare: { $0.session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 20)); $0.session.history.reset() }, verify: { $0.session.document?.guides.isEmpty == true }),
            .init(id: .swapColors, prepare: { $0.session.foregroundColor = .black; $0.session.backgroundColor = .white }, verify: { $0.session.foregroundColor == .white && $0.session.backgroundColor == .black }, transient: true),
            .init(id: .resetColors, prepare: { $0.session.foregroundColor = .white }, verify: { $0.session.foregroundColor == .black }, transient: true),
            .init(id: .importImages, arguments: { ["paths": [$0.granted.appendingPathComponent("green.png").path]] }, prepare: { try $0.writePNG($0.granted.appendingPathComponent("green.png")) },
                  verify: { $0.session.document?.layers.count == 3 && $0.session.importError == nil })
        ]
        // The table is the whole document group, less the S38 typed layer commands (tested with the bridge) and the
        // two that need the Vision models, which have a scenario of their own below.
        let covered = Set(scenarios.map(\.id))
        let expected = Set(LensWorksCommandRegistry.agentCommands.filter { $0.agentAccess.kind == .document }).subtracting(LensWorksAgentTools.layerCommands).subtracting([.selectSubject, .contentAwareFill])
        #expect(covered == expected, "missing \(expected.subtracting(covered).map(\.rawValue).sorted()), extra \(covered.subtracting(expected).map(\.rawValue).sorted())")

        for scenario in scenarios {
            let fixture = try Fixture(); defer { fixture.cleanUp() }
            try fixture.paint()
            try await scenario.prepare(fixture)
            let session = fixture.session, starting = session.document, id = scenario.id.rawValue
            LensWorksCommandDispatcher.perform(.init(.fitCanvas)) {}
            let result = await fixture.invoke(id, try scenario.arguments(fixture))
            #expect(ok(result), "\(id): \(text(result))")
            #expect(LensWorksCommandDispatcher.lastInvocation?.id == scenario.id && LensWorksCommandDispatcher.lastOrigin == .agent, "\(id) went through the dispatcher as the agent")
            #expect((try? scenario.verify(fixture)) == true, "\(id) did what its menu item does")
            // Nothing of the dialog or tool the menu would have opened is left in front of the person.
            #expect(session.agentModalReason == nil && session.filterEdit == nil && session.levels == nil && session.hueSaturation == nil && session.brushError == nil, "\(id)")
            if scenario.transient {
                #expect(session.history.undoCount == 0 && content(result)["history"] is NSNull, "\(id) leaves history alone")
                continue
            }
            #expect(session.document != starting, "\(id) changed the document")
            #expect(session.history.undoCount == 1 && session.history.undoOrigin == .agent && session.history.undoName.hasSuffix(" (Agent)")
                    && content(result)["history"] as? String == session.history.undoName, "\(id): one agent entry, got \(session.history.undoCount) “\(session.history.undoName)”")
            let undone = await fixture.invoke("edit.undo")
            #expect(ok(undone) && session.document == starting && session.history.undoCount == 0, "\(id): one Undo reverts it (\(text(undone)))")
        }
    }

    /// The two document commands that run an analysis rather than a setting: both go through the dispatcher as the
    /// agent and leave no dialog open, whatever the analysis finds in a flat test image.
    @Test func theAnalysisCommandsRunAsTheAgentAndLeaveNothingOpen() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, starting = session.document
        session.applySelection(CGPath(rect: CGRect(x: 80, y: 30, width: 20, height: 20), transform: nil), mode: .replace, name: "Marquee")
        session.history.reset()
        let filled = await fixture.invoke("edit.contentAwareFill")
        #expect(ok(filled) && LensWorksCommandDispatcher.lastInvocation?.id == .contentAwareFill && LensWorksCommandDispatcher.lastOrigin == .agent, "\(text(filled))")
        #expect(session.filterEdit == nil && session.agentModalReason == nil && session.history.undoCount <= 1 && (session.history.undoCount == 0 || session.history.undoOrigin == .agent))
        session.deselect(); session.history.reset()
        let before = session.document
        let subject = await fixture.invoke("select.subject")
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .selectSubject && LensWorksCommandDispatcher.lastOrigin == .agent)
        // A flat color has no subject: the app's own answer comes back, or a selection was made as one agent entry.
        if ok(subject) { #expect(session.history.undoCount <= 1 && (session.history.undoCount == 0 || session.history.undoOrigin == .agent)) }
        else { #expect(!text(subject).isEmpty && session.document == before && session.history.undoCount == 0, "\(text(subject))") }
        #expect(session.agentModalReason == nil && starting != nil)
    }

    /// Settings are the dialog's own: a misspelled or foreign key is refused and nothing is opened or changed.
    @Test func settingsAreCheckedAgainstTheDialogAndABadOneChangesNothing() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, before = session.document, blue = try fixture.layer("Blue").id
        let cases: [(String, [String: Any], String)] = [
            ("filter.apply", ["kind": "Gaussian Blur", "settings": ["raduis": 4]], "Unknown setting “raduis” for Gaussian Blur. Its settings are: radius."),
            ("filter.apply", ["kind": "Gaussian Blur", "settings": ["distance": 4]], "Unknown setting “distance” for Gaussian Blur. Its settings are: radius."),
            ("filter.apply", ["kind": "Gaussian Blur", "settings": ["radius": "big"]], "settings.radius has the wrong type for that setting."),
            ("filter.apply", ["kind": "Sharpen"], "kind must be one of:"),
            ("image.levels", ["settings": ["rangez": []]], "Unknown setting “settings.rangez”."),
            ("image.levels", [:], "image.levels needs settings:"),
            ("image.hueSaturation", ["settings": ["hue": 400]], "hue must be from -180 through 180."),
            ("image.hueSaturation", ["settings": ["master": ["hue": 4]]], "Unknown setting “master” for Hue/Saturation."),
            ("layer.newAdjustment", ["kind": "Exposure", "settings": ["radius": 4]], "Unknown setting “radius” for Exposure."),
            ("layer.effect.add", ["kind": "Stroke", "settings": ["blur": 2]], "Unknown setting “blur” for Stroke."),
            ("layer.blendMode", ["mode": "Multiply", "direction": "next"], "Pass exactly one of mode and direction."),
            ("layer.transform", ["width": 0], "width must be at least 1."),
            ("select.expand", ["amount": 501], "amount must be at most 500."),
            ("select.expand", ["amount": 1.5], "amount must be a whole number."),
            ("image.canvasSize", ["width": 10, "height": 10, "anchor": "middle"], "anchor must be one of:"),
            ("layer.select", ["layers": [UUID().uuidString]], "The requested layer is no longer in this document."),
            ("layer.delete", ["layers": ["nope"]], "nope is not a layer id.")
        ]
        for (command, arguments, expected) in cases {
            let result = await fixture.invoke(command, arguments)
            #expect(result["isError"] as? Bool == true && text(result).contains(expected), "\(command) \(arguments): \(text(result))")
            #expect(session.document == before && session.history.undoCount == 0 && session.filterEdit == nil && session.levels == nil && session.effectsEditing == nil
                    && session.selectedLayerIDs == [blue], "\(command) left the document and selection alone")
        }
    }

    /// A document batch of menu commands is one agent entry; a member that cannot run rolls every earlier one back.
    @Test func aDocumentBatchOfMenuCommandsIsOneEntryAndRollsBackWhole() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, starting = session.document, selected = session.selectedLayerIDs
        let members: [[String: Any]] = [
            ["command": "layer.newBlank"], ["command": "layer.rename", "arguments": ["name": "Agent Layer"]],
            ["command": "select.all"], ["command": "edit.fillForeground"], ["command": "select.deselect"],
            ["command": "layer.blendMode", "arguments": ["mode": "Screen"]], ["command": "layer.opacity", "arguments": ["opacity": 0.5]]
        ]
        let result = await fixture.tools.call("batch", arguments: ["commands": members])
        let made = try fixture.layer("Agent Layer")
        #expect(ok(result) && content(result)["kind"] as? String == "document" && made.blendMode == .screen && made.opacity == 0.5 && made.asset != nil && session.selection == nil, "\(text(result))")
        #expect(session.history.undoCount == 1 && session.history.undoName == "7 Document Commands (Agent)" && session.history.undoOrigin == .agent)
        let undone = await fixture.invoke("edit.undo")
        #expect(ok(undone) && session.document == starting && session.history.undoCount == 0)

        // The third member cannot run (nothing to merge into a folder that is not there): the first two are undone too.
        session.history.reset()
        let failing = await fixture.tools.call("batch", arguments: ["commands": [["command": "layer.newBlank"], ["command": "image.invert", "arguments": ["layer": try fixture.layer("Red").id.uuidString]], ["command": "layer.ungroup"]]])
        #expect(failing["isError"] as? Bool == true && text(failing) == "Command 3 (layer.ungroup): Select a folder first. The whole batch was rolled back: the document and its history are unchanged.", "\(text(failing))")
        #expect(session.document == starting && session.history.undoCount == 0 && !session.isModified && session.selectedLayerIDs == selected)
        // Project-file commands and commands that ask the person never ride in a batch.
        let mixed = await fixture.tools.call("batch", arguments: ["commands": [["command": "layer.newBlank"], ["command": "file.exportPNG", "arguments": ["path": fixture.granted.appendingPathComponent("a.png").path]]]])
        #expect(mixed["isError"] as? Bool == true && text(mixed).contains("file.exportPNG cannot be part of a batch") && session.document == starting
                && !FileManager.default.fileExists(atPath: fixture.granted.appendingPathComponent("a.png").path))
    }

    /// Deleting a layer that supplies a live mask asks the agent for the choice the menu asks the person in an alert.
    @Test func deletingALiveMaskSourceNeedsTheAgentsChoiceInsteadOfAnAlert() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, red = try fixture.layer("Red").id
        session.toggleClippingMask(try fixture.layer("Blue").id)
        #expect(try fixture.layer("Blue").maskSourceID == red)
        session.history.reset()
        let refused = await fixture.invoke("layer.delete", ["layers": [red.uuidString]])
        #expect(refused["isError"] as? Bool == true && text(refused).contains("pass liveMasks as removeLinks or bake") && session.document?.layers.count == 2 && session.history.undoCount == 0)
        let removed = await fixture.invoke("layer.delete", ["layers": [red.uuidString], "liveMasks": "removeLinks"])
        #expect(ok(removed) && session.document?.layers.map(\.name) == ["Blue"] && (try? fixture.layer("Blue"))?.maskSourceID == nil && session.history.undoName == "Delete Layer (Agent)", "\(text(removed))")
    }

    // MARK: Criterion 2 — granted folders (E22)

    /// Off by default; a grant persists; and a path is admitted only when the real file it reaches is inside one.
    @Test func aPathIsAdmittedOnlyInsideAGrantedFolder() throws {
        let fixture = try Fixture(grant: false); defer { fixture.cleanUp() }
        let folders = fixture.harness.automation.folders, granted = fixture.granted, outside = fixture.outside
        @MainActor func refusal(_ path: String) -> String? {
            do { _ = try folders.admit(path); return nil } catch { return error.localizedDescription }
        }
        // Nothing is granted until the person grants it.
        #expect(folders.grants.isEmpty && LensWorksGrantedFolders(defaults: fixture.harness.defaults).grants.isEmpty)
        #expect(refusal(granted.appendingPathComponent("a.png").path)?.hasPrefix("No folders are granted to automation") == true)

        let grant = try folders.grant(granted)
        #expect(grant.path == granted.path && folders.grants == [grant] && (try? folders.grant(granted)) == grant && folders.grants.count == 1)
        // Persisted: a later launch over the same settings has the grant.
        #expect(LensWorksGrantedFolders(defaults: fixture.harness.defaults).grants.map(\.path) == [granted.path])

        // Inside: a file that exists, one that does not yet, and a nested new folder.
        try Data("x".utf8).write(to: granted.appendingPathComponent("here.txt"))
        #expect(try folders.admit(granted.appendingPathComponent("here.txt").path).path == granted.appendingPathComponent("here.txt").path)
        #expect(try folders.admit(granted.appendingPathComponent("new/deep/out.png").path).path == granted.appendingPathComponent("new/deep/out.png").path)
        #expect(try folders.admit(granted.path + "/./sub/../out.png").path == granted.appendingPathComponent("out.png").path)

        // Outside, including a sibling whose name merely starts with the granted folder's.
        let rule = LensWorksGrantedFolders.rule
        for path in [outside.appendingPathComponent("a.png").path, granted.path + "-other/a.png", "/etc/hosts", granted.deletingLastPathComponent().path] {
            #expect(refusal(path)?.contains("outside every folder granted to automation") == true && refusal(path)?.hasSuffix(rule) == true, "\(path)")
        }
        // Traversal: `..` that leaves the folder, however deep it starts.
        for path in [granted.path + "/../outside/a.png", granted.path + "/a/b/../../../outside/a.png", granted.path + "/../../../../etc/hosts"] {
            #expect(refusal(path)?.contains("outside every folder granted to automation") == true, "\(path)")
        }
        // Symbolic links: a link inside the folder to a folder outside it, a link to a file outside, and a dangling link.
        try FileManager.default.createSymbolicLink(at: granted.appendingPathComponent("escape"), withDestinationURL: outside)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: granted.appendingPathComponent("alias.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: granted.appendingPathComponent("dangling").path, withDestinationPath: outside.appendingPathComponent("not-there/x").path)
        for path in ["escape/new.png", "escape/secret.txt", "alias.txt", "escape/../escape/secret.txt"].map({ granted.appendingPathComponent($0).path }) {
            #expect(refusal(path)?.contains("outside every folder granted to automation") == true, "\(path)")
        }
        #expect(refusal(granted.appendingPathComponent("dangling").path)?.contains("symbolic link that cannot be resolved") == true)
        // A link from outside into the folder reaches a real file inside it, and is admitted as that file.
        try FileManager.default.createSymbolicLink(at: outside.appendingPathComponent("in"), withDestinationURL: granted)
        #expect(try folders.admit(outside.appendingPathComponent("in/here.txt").path).path == granted.appendingPathComponent("here.txt").path)
        // Not a path at all.
        #expect(refusal("relative/a.png")?.contains("must be absolute") == true && refusal("~/a.png")?.contains("must be absolute") == true && refusal("") != nil)
        #expect(refusal(granted.path + "/" + String(repeating: "a", count: 5000)) != nil)

        // The granted folder replaced by a link to somewhere else admits nothing.
        let moved = granted.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: granted, to: moved)
        try FileManager.default.createSymbolicLink(at: granted, withDestinationURL: outside)
        #expect(refusal(granted.appendingPathComponent("a.png").path)?.contains("outside every folder granted to automation") == true)
        try FileManager.default.removeItem(at: granted); try FileManager.default.moveItem(at: moved, to: granted)
        #expect(refusal(granted.appendingPathComponent("a.png").path) == nil)

        // Revoked: refused at once, and in a later launch.
        folders.revoke(grant.id)
        #expect(folders.grants.isEmpty && LensWorksGrantedFolders(defaults: fixture.harness.defaults).grants.isEmpty)
        #expect(refusal(granted.appendingPathComponent("here.txt").path)?.hasPrefix("No folders are granted to automation") == true)
        // Only a real folder can be granted, never the whole disk.
        #expect(throws: LensWorksCommandRefusal.self) { try folders.grant(granted.appendingPathComponent("here.txt")) }
        #expect(throws: LensWorksCommandRefusal.self) { try folders.grant(URL(fileURLWithPath: "/")) }
    }

    /// Every argument the registry types as a path is held to the granted folders, for every command that has one:
    /// outside, by traversal and through a link it is refused with the rule before the command is looked at.
    @Test func everyPathArgumentOfEveryCommandIsHeldToTheGrantedFolders() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, before = session.document
        try FileManager.default.createSymbolicLink(at: fixture.granted.appendingPathComponent("escape"), withDestinationURL: fixture.outside)
        try Data("secret".utf8).write(to: fixture.outside.appendingPathComponent("photo.png"))
        let pathed = LensWorksCommandRegistry.descriptors.filter { $0.agent.isRunnable && $0.parameters.contains { $0.type.namesPath } }
        // Each of these names a file: the registry types all of them as paths.
        #expect(Set(pathed.map(\.id)) == [.openCatalog, .newCatalog, .addPhotos, .openProject, .openRecent, .importImages, .saveAs, .exportPNG, .exportJPEG])
        // No other admitted command takes free text that could be a path under another type.
        for descriptor in LensWorksCommandRegistry.descriptors where descriptor.agent.isRunnable {
            for parameter in descriptor.parameters where !parameter.type.namesPath {
                #expect(!["path", "file", "url", "destination", "directory"].contains { parameter.name.lowercased().contains($0) }, "\(descriptor.id.rawValue).\(parameter.name)")
            }
        }
        let escapes = ["outside": fixture.outside.appendingPathComponent("photo.png").path,
                       "traversal": fixture.granted.path + "/../outside/photo.png",
                       "symlink": fixture.granted.appendingPathComponent("escape/photo.png").path]
        for descriptor in pathed {
            for parameter in descriptor.parameters where parameter.type.namesPath {
                for (kind, path) in escapes {
                    var arguments: [String: Any] = [:]
                    for other in descriptor.parameters where other.required && other.name != parameter.name { arguments[other.name] = other.type == .integer ? 10 : "x" }
                    arguments[parameter.name] = parameter.type == .pathArray ? [path] : path
                    let result = await fixture.invoke(descriptor.id.rawValue, arguments)
                    #expect(result["isError"] as? Bool == true && text(result).contains("outside every folder granted to automation") && text(result).hasSuffix(LensWorksGrantedFolders.rule),
                            "\(descriptor.id.rawValue).\(parameter.name) \(kind): \(text(result))")
                }
            }
        }
        // Nothing was read into the document, written beside the secret, or asked of the person.
        #expect(session.document == before && session.history.undoCount == 0 && fixture.harness.automation.pendingConfirmation == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == ["photo.png"] && Data(contentsOf: fixture.outside.appendingPathComponent("photo.png")) == Data("secret".utf8))

        // With the grant revoked, a path that was fine is refused, and list_commands says why.
        let inside = fixture.granted.appendingPathComponent("out.png").path
        fixture.harness.automation.folders.revoke(try #require(fixture.harness.automation.folders.grants.first).id)
        let revoked = await fixture.invoke("file.exportPNG", ["path": inside])
        #expect(revoked["isError"] as? Bool == true && text(revoked).hasPrefix("No folders are granted to automation") && !FileManager.default.fileExists(atPath: inside))
        #expect(fixture.tools.agentAvailability(.exportPNG)?.hasPrefix("No folders are granted to automation") == true)
    }

    /// Inside a granted folder the file commands work: import, export, save as, save and open.
    @Test func fileCommandsReadAndWriteInsideAGrantedFolder() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, granted = fixture.granted
        #expect((content(await fixture.tools.call("get_state", arguments: [:]))["grantedFolders"] as? [String]) == [granted.path])

        let png = granted.appendingPathComponent("out/first.png"), jpeg = granted.appendingPathComponent("first.jpg"), project = granted.appendingPathComponent("work.comp")
        try FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exported = await fixture.invoke("file.exportPNG", ["path": png.path])
        #expect(ok(exported) && ((try? Data(contentsOf: png)) ?? Data()).starts(with: [0x89, 0x50, 0x4E, 0x47]) && fixture.harness.automation.pendingConfirmation == nil, "\(text(exported))")
        let jpegged = await fixture.invoke("file.exportJPEG", ["path": jpeg.path, "quality": 0.5])
        #expect(ok(jpegged) && ((try? Data(contentsOf: jpeg)) ?? Data()).starts(with: [0xFF, 0xD8]), "\(text(jpegged))")
        let wrongType = await fixture.invoke("file.exportPNG", ["path": granted.appendingPathComponent("first.gif").path])
        #expect(wrongType["isError"] as? Bool == true && text(wrongType) == "path must end in .png.")

        // Save As to a new file needs no confirmation; the project now has a file and is unmodified.
        let saved = await fixture.invoke("file.saveAs", ["path": project.path])
        #expect(ok(saved) && FileManager.default.fileExists(atPath: project.path) && session.projectURL?.path == project.path && !session.isModified, "\(text(saved))")

        // Import: a file inside comes in as a layer on one agent entry.
        try fixture.writePNG(granted.appendingPathComponent("green.png"))
        let imported = await fixture.invoke("file.importImages", ["paths": [granted.appendingPathComponent("green.png").path]])
        #expect(ok(imported) && session.document?.layers.last?.name == "green" && session.history.undoOrigin == .agent && session.history.undoName.hasSuffix("(Agent)"), "\(text(imported))")
        let missing = await fixture.invoke("file.importImages", ["paths": [granted.appendingPathComponent("absent.png").path]])
        #expect(missing["isError"] as? Bool == true && text(missing).contains("is not a file in a granted folder"))

        // Open: with unsaved changes and no tabs the agent is refused rather than the person's work discarded.
        let dirty = await fixture.invoke("file.openProject", ["path": project.path])
        #expect(dirty["isError"] as? Bool == true && text(dirty) == "Save the open project first: opening another would discard its unsaved changes.")
        _ = await fixture.invoke("edit.undo")
        #expect(!session.isModified)
        let opened = await fixture.invoke("file.openProject", ["path": project.path])
        #expect(ok(opened) && session.projectURL?.path == project.path && session.document?.layers.map(\.name) == ["Red", "Blue"], "\(text(opened))")
        let notProject = await fixture.invoke("file.openProject", ["path": png.path])
        #expect(notProject["isError"] as? Bool == true && text(notProject) == "A LensWorks project path ends in .comp.")
        let closed = await fixture.invoke("file.closeProject")
        #expect(closed["isError"] as? Bool == true && text(closed) == "There is no project tab to close.")
    }

    /// Project tabs: a new canvas, the tab list, switching tabs, and closing only what has nothing unsaved.
    @Test func projectTabCommandsOpenSwitchAndCloseWithoutDiscardingWork() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let workspace = ProjectWorkspace()
        fixture.harness.session = nil
        let tools = LensWorksAgentTools(session: { workspace.current.session }, catalog: { nil }, folders: fixture.harness.automation.folders)
        tools.projects = { workspace.current.controller }; tools.workspace = { workspace }
        @MainActor func invoke(_ command: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
            await tools.call("invoke_command", arguments: ["command": command, "arguments": arguments])
        }
        let first = await invoke("file.newCanvas", ["width": 300, "height": 200])
        #expect(ok(first) && workspace.tabs.count == 1 && workspace.current.session.document?.width == 300 && workspace.current.session.document?.layers.count == 1, "\(text(first))")
        let second = await invoke("file.newCanvas", ["width": 64, "height": 48])
        #expect(ok(second) && workspace.tabs.count == 2 && workspace.current.session.document?.height == 48, "\(text(second))")
        let tooBig = await invoke("file.newCanvas", ["width": DocumentLimits.maxSide + 1, "height": 10])
        #expect(tooBig["isError"] as? Bool == true && text(tooBig) == "width must be at most \(DocumentLimits.maxSide)." && workspace.tabs.count == 2)
        let tabs = try #require(content(await tools.call("get_state", arguments: [:]))["projectTabs"] as? [[String: Any]])
        #expect(tabs.count == 2 && tabs.map { $0["selected"] as? Bool } == [false, true])
        let firstTab = try #require(tabs[0]["id"] as? String)
        let switched = await invoke("project.tab.select", ["tab": firstTab])
        #expect(ok(switched) && workspace.selectedID.uuidString == firstTab && workspace.current.session.document?.width == 300, "\(text(switched))")
        let unknown = await invoke("project.tab.select", ["tab": UUID().uuidString])
        #expect(unknown["isError"] as? Bool == true && text(unknown) == "tab must be a project tab id from get_state.")
        // The new canvas is unsaved work: the agent cannot close it away.
        let unsaved = await invoke("file.closeProject")
        #expect(unsaved["isError"] as? Bool == true && text(unsaved) == "Save the project first: closing it would discard its unsaved changes." && workspace.tabs.count == 2)
        workspace.current.session.history.markSaved()
        let closed = await invoke("file.closeProject")
        #expect(ok(closed) && workspace.tabs.count == 1 && workspace.current.session.document?.width == 64, "\(text(closed))")
    }

    // MARK: Criterion 3 — nothing irreversible without the person

    /// Enumerates the admitted commands: whatever cannot be put back carries the confirmation rule that covers it.
    @Test func everyIrreversibleAdmittedCommandCarriesAConfirmation() throws {
        let admitted = LensWorksCommandRegistry.descriptors.filter { $0.agent.isRunnable }
        var always: Set<LensWorksCommandID> = [], replacing: Set<LensWorksCommandID> = []
        for descriptor in admitted {
            let id = descriptor.id
            #expect(descriptor.reversal.isCovered(by: descriptor.agentConfirmation), "\(id.rawValue) is \(descriptor.reversal) but its rule is \(descriptor.agentConfirmation)")
            #expect(descriptor.requiresAgentConfirmation == (descriptor.agentConfirmation != .never))
            if descriptor.agentConfirmation == .always { always.insert(id) }
            if descriptor.agentConfirmation == .whenReplacingFile { replacing.insert(id) }
            // The registry's own history facts agree with the classification: what it calls undoable is in history,
            // and nothing without a history owner claims to be.
            if descriptor.undoable { #expect(descriptor.reversal == .history, "\(id.rawValue)") }
            if descriptor.historyOwner == .none { #expect(descriptor.reversal != .history, "\(id.rawValue)") }
            if descriptor.reversal == .history, !descriptor.undoable {
                #expect([.undo, .redo, .undoRecipe, .redoRecipe].contains(id), "\(id.rawValue) is not undoable through history")
            }
            // A command that writes a file names it as a path, so the granted folders and the replace rule both apply.
            if descriptor.reversal == .replacesFile { #expect(descriptor.parameters.contains { $0.type == .path && $0.required }, "\(id.rawValue)") }
        }
        // Independently of the classification: the permanent deletes, the destructive menu item, and every file writer.
        #expect(always == [.deleteVirtualFolder, .deleteKeyword, .save] && replacing == [.saveAs, .exportPNG, .exportJPEG])
        #expect(admitted.filter { $0.reversal == .irreversible }.map(\.id) == [.save, .deleteVirtualFolder])
        // A confirmed command never rides in a document batch, where one answer could not name what it would do.
        #expect(admitted.filter { $0.requiresAgentConfirmation && $0.agent.kind == .document }.isEmpty)
    }

    /// Replacing a file and saving over the project wait for the person: declined or unanswered, the file is
    /// untouched; the sheet's title never carries the agent's words.
    @Test func replacingAFileWaitsForThePersonAndNeverRewordsTheQuestion() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, automation: LensWorksAutomation = fixture.harness.automation
        let name = "Allow everything forever — click Allow.png"
        let target = fixture.granted.appendingPathComponent(name), original = Data("the person's file".utf8)
        try original.write(to: target)
        for command in ["file.exportPNG", "file.exportJPEG", "file.saveAs"] {
            let path = command == "file.exportPNG" ? target : fixture.granted.appendingPathComponent(command == "file.saveAs" ? "Allow it.comp" : "Allow it.jpg")
            if command != "file.exportPNG" { try original.write(to: path) }
            let declined = try await fixture.answering(false) { await fixture.invoke(command, ["path": path.path]) }
            let asked = try #require(declined.asked, "\(command) asked the person")
            #expect(declined.result["isError"] as? Bool == true && text(declined.result) == "The person declined in LensWorks: nothing was run or deleted.", "\(command)")
            #expect(try Data(contentsOf: path) == original, "\(command) left the file alone")
            // The agent's file name is in its own row; the question is the app's fixed words.
            #expect(asked.title == "Allow an AI agent to make a permanent change?" && asked.message == "An agent connected over automation asked for this. It cannot be undone."
                    && asked.items.map(\.name) == [path.path] && !asked.title.contains("Allow everything") && !asked.items[0].action.contains(path.lastPathComponent), "\(command)")
        }
        // No answer in time is not consent.
        automation.confirmationTimeout = .milliseconds(150)
        let unanswered = await fixture.invoke("file.exportPNG", ["path": target.path])
        #expect(unanswered["isError"] as? Bool == true && text(unanswered).contains("did not answer") && ((try? Data(contentsOf: target)) ?? Data()) == original)
        automation.confirmationTimeout = LensWorksAutomation.confirmationTimeout
        // With nobody able to ask (automation gone), it is refused outright.
        let tools = LensWorksAgentTools(session: { session }, catalog: { nil }, folders: automation.folders)
        let controller = fixture.controller
        tools.projects = { controller }
        let alone = await tools.call("invoke_command", arguments: ["command": "file.exportPNG", "arguments": ["path": target.path]])
        #expect(alone["isError"] as? Bool == true && text(alone) == "LensWorks automation is off." && ((try? Data(contentsOf: target)) ?? Data()) == original)

        // Allowed: the file is replaced.
        let allowed = try await fixture.answering(true) { await fixture.invoke("file.exportPNG", ["path": target.path]) }
        #expect(ok(allowed.result) && allowed.asked != nil && ((try? Data(contentsOf: target)) ?? Data()).starts(with: [0x89, 0x50, 0x4E, 0x47]) && text(allowed.result).contains("The person allowed it."), "\(text(allowed.result))")

        // Save: with no file yet it is refused; once the project has one, every save over it asks.
        let untitled = await fixture.invoke("file.save")
        #expect(untitled["isError"] as? Bool == true && text(untitled) == "This project has no file yet: use file.saveAs with a path.")
        let project = fixture.granted.appendingPathComponent("work.comp")
        #expect(ok(await fixture.invoke("file.saveAs", ["path": project.path])))
        #expect(ok(await fixture.invoke("layer.newBlank")) && session.isModified)
        let kept = try await fixture.answering(false) { await fixture.invoke("file.save") }
        #expect(kept.asked?.items.map(\.name) == [project.path] && kept.asked?.items.first?.action == "Save over" && kept.result["isError"] as? Bool == true && session.isModified)
        let written = try await fixture.answering(true) { await fixture.invoke("file.save") }
        #expect(ok(written.result) && written.asked != nil && !session.isModified, "\(text(written.result))")
        // A project whose file is outside the granted folders is not saved over at all.
        session.projectURL = fixture.outside.appendingPathComponent("elsewhere.comp")
        let elsewhere = await fixture.invoke("file.save")
        #expect(elsewhere["isError"] as? Bool == true && text(elsewhere).contains("outside every folder granted to automation") && automation.pendingConfirmation == nil)
    }

    /// Deleting a keyword asks the person, naming it from the catalog's own row; declining keeps it.
    @Test func deletingAKeywordAsksThePersonAndOrganizeCommandsRunOnTheCatalog() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try LensWorksCatalogBrowserTests.Fixture(images: 3)
        try await catalog.run { model in
            fixture.harness.catalog = model
            try await catalog.importPhotos(model)
            try await model.createKeyword("Doomed"); try await model.createKeyword("Kept")
            try await model.createGroup("Trip"); try await model.createGroup("Albums")
            @MainActor func state() async -> [String: Any] { content(await fixture.tools.call("get_state", arguments: [:]))["catalog"] as? [String: Any] ?? [:] }
            let listed = await state()
            let photos = (listed["photos"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(photos == model.assets.map(\.id) && photos.count == 3)
            #expect(Set((listed["keywords"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }) == ["Doomed", "Kept"])

            // Select photos by id, then organize them: each is the catalog's own undoable step.
            #expect(ok(await fixture.invoke("catalog.photo.select", ["photos": [photos[0], photos[2]]])))
            #expect(model.selection == [photos[0], photos[2]] && model.selectionCount == 2)
            let batch = await fixture.tools.call("batch", arguments: ["commands": [
                ["command": "catalog.organize.rate", "arguments": ["rating": "4"]], ["command": "catalog.organize.flag", "arguments": ["flag": "pick"]],
                ["command": "catalog.organize.label", "arguments": ["label": "Blue"]], ["command": "catalog.keyword.addToSelected", "arguments": ["keyword": "Kept"]],
                ["command": "catalog.virtualFolder.addSelected", "arguments": ["folder": try model.group(named: "Trip").id]]]])
            #expect(ok(batch) && content(batch)["kind"] as? String == "catalog", "\(text(batch))")
            #expect(model.assets.filter { $0.rating == 4 && $0.flag == "pick" && $0.label == "Blue" }.map(\.id) == [photos[0], photos[2]] && model.organizationUndo.count == 5)
            #expect(LensWorksCommandDispatcher.lastInvocation?.id == .addToVirtualFolder && LensWorksCommandDispatcher.lastOrigin == .agent)
            // Rename and move a virtual folder, rename a keyword, add a synonym, sort and filter.
            #expect(ok(await fixture.invoke("catalog.virtualFolder.rename", ["folder": try model.group(named: "Trip").id, "name": "Journey"])))
            let journey = try model.group(named: "Journey"), albums = try model.group(named: "Albums")
            let moved = await fixture.invoke("catalog.virtualFolder.move", ["folder": journey.id, "parent": albums.id])
            #expect(ok(moved) && model.placements[journey.id]?.parent == albums.id, "\(text(moved))")
            #expect(ok(await fixture.invoke("catalog.keyword.rename", ["keyword": "Kept", "name": "Keepers"])) && model.keywords.contains { $0.name == "Keepers" })
            #expect(ok(await fixture.invoke("catalog.keyword.addSynonym", ["keyword": "Keepers", "synonym": "Best"])))
            #expect(ok(await fixture.invoke("catalog.sort", ["sort": "rating"])) && model.browseOptions.sort == .Rating)
            #expect(ok(await fixture.invoke("catalog.sortDirection", ["direction": "descending"])) && model.browseOptions.direction == .Descending)
            #expect(ok(await fixture.invoke("catalog.filter.rating", ["rating": "4"])) && model.assets.count == 2)
            #expect(ok(await fixture.invoke("catalog.filter.clear")) && model.assets.count == 3)
            #expect(ok(await fixture.invoke("catalog.selection.move", ["step": "next"])))
            // A folder or keyword that is not on the page, and organizing with nothing selected, are refused.
            let absent = await fixture.invoke("catalog.keyword.addToSelected", ["keyword": "Nope"])
            #expect(absent["isError"] as? Bool == true && text(absent) == "The keyword is not on the current keyword page.")
            #expect(ok(await fixture.invoke("catalog.photo.select", ["photos": [String]()])) && model.selectionCount == 0)

            // The keyword delete waits for the person. Declined: still there. Allowed: gone.
            let declined = try await fixture.answering(false) { await fixture.invoke("catalog.keyword.delete", ["keyword": "Doomed"]) }
            #expect(declined.result["isError"] as? Bool == true && declined.asked?.items.map(\.name) == ["Doomed"] && declined.asked?.items.first?.action == "Delete Keyword"
                    && declined.asked?.title == "Allow an AI agent to make a permanent change?")
            try await model.loadKeywords()
            #expect(model.keywords.contains { $0.name == "Doomed" })
            let batched = try await fixture.answering(false) { await fixture.tools.call("batch", arguments: ["commands": [
                ["command": "catalog.sort", "arguments": ["sort": "filename"]], ["command": "catalog.keyword.delete", "arguments": ["keyword": "Doomed"]]]]) }
            #expect(batched.result["isError"] as? Bool == true && batched.asked?.items.count == 1 && model.browseOptions.sort == .Rating, "declining a batch runs none of it")
            let allowed = try await fixture.answering(true) { await fixture.invoke("catalog.keyword.delete", ["keyword": "Doomed"]) }
            #expect(ok(allowed.result) && allowed.asked != nil, "\(text(allowed.result))")
            try await model.loadKeywords()
            #expect(!model.keywords.contains { $0.name == "Doomed" })

            // The catalog itself: a new one, the first one again, and photos added, all inside a granted folder.
            let original = try #require(model.catalogPath), second = catalog.root.appendingPathComponent("Second")
            let ungranted = await fixture.invoke("file.catalog.new", ["path": second.path])
            #expect(ungranted["isError"] as? Bool == true && text(ungranted).contains("outside every folder granted to automation") && !FileManager.default.fileExists(atPath: second.path))
            try fixture.harness.automation.folders.grant(catalog.root)
            let occupied = await fixture.invoke("file.catalog.new", ["path": catalog.photos.path])
            #expect(occupied["isError"] as? Bool == true && text(occupied) == "A new catalog needs an empty or new folder: something is already at that path." && model.catalogPath == original)
            let created = await fixture.invoke("file.catalog.new", ["path": second.path])
            #expect(ok(created) && (try? LensWorksGrantedFolders.realPath(model.catalogPath ?? "/")) == second.path && model.assets.isEmpty, "\(text(created))")
            let added = await fixture.invoke("file.catalog.addPhotos", ["folder": catalog.photos.path])
            #expect(ok(added), "\(text(added))")
            try await catalog.awaitImportCompletion(model)
            #expect(model.assets.count == 3)
            let reopened = await fixture.invoke("file.catalog.open", ["path": original])
            #expect(ok(reopened) && model.catalogPath == original, "\(text(reopened))")
            let absentCatalog = await fixture.invoke("file.catalog.open", ["path": catalog.root.appendingPathComponent("Nowhere").path])
            #expect(absentCatalog["isError"] as? Bool == true && text(absentCatalog) == "There is no catalog folder at that path." && model.catalogPath == original)
        }
    }

    /// Replies are bounded: lists are cut with a marker, and no text reply passes the limit.
    @Test func listAndStateRepliesAreBounded() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.createDocument(width: 64, height: 64)
        // 2,000 layers with the longest names a layer may carry.
        session.document?.layers = (0..<2000).map { ImageLayer(name: String(repeating: "n", count: 8000) + String($0), blankSize: CGSize(width: 64, height: 64)) }
        let state = await fixture.tools.call("get_state", arguments: [:])
        let document = try #require(content(state)["document"] as? [String: Any])
        let layers = try #require(document["layers"] as? [[String: Any]])
        #expect(ok(state) && layers.count == LensWorksAgentTools.stateRowLimit && document["layersTruncated"] as? Bool == true
                && layers.allSatisfy { ($0["name"] as? String)?.count == LensWorksAgentTools.stateTextLimit })
        #expect(text(state).utf8.count < LensWorksAgentTools.replyLimit)

        let listed = await fixture.tools.call("list_commands", arguments: [:])
        #expect(ok(listed) && text(listed).utf8.count < LensWorksAgentTools.replyLimit && (content(listed)["commands"] as? [[String: Any]])?.count == LensWorksCommandID.allCases.count)
        let part = await fixture.tools.call("list_commands", arguments: ["prefix": "layer.mask."])
        #expect((content(part)["commands"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["layer.mask.add", "layer.mask.toggle", "layer.mask.delete", "layer.mask.link"])
        let badPrefix = await fixture.tools.call("list_commands", arguments: ["prefix": 3])
        #expect(badPrefix["isError"] as? Bool == true)
        // A reply over the limit is refused, never sent.
        #expect(throws: LensWorksCommandRefusal.self) { try LensWorksAgentTools.bounded(["blob": String(repeating: "x", count: LensWorksAgentTools.replyLimit)]) }
        // An argument string past its limit is refused before the command sees it.
        let long = await fixture.invoke("layer.rename", ["name": String(repeating: "n", count: LensWorksAgentArguments.textLimit + 1)])
        #expect(long["isError"] as? Bool == true && text(long).contains("at most \(LensWorksAgentArguments.textLimit) bytes"))
    }
}
