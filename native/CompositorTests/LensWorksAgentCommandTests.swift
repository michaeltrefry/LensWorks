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
        /// `whileAsked` runs with the sheet open, before the answer: what the person or the disk does meanwhile.
        func answering(_ allow: Bool, whileAsked: @MainActor () throws -> Void = {}, _ call: @escaping @MainActor () async -> [String: Any]) async throws -> (result: [String: Any], asked: LensWorksAgentConfirmation?) {
            harness.showWindow()
            final class Box { var value: [String: Any]? }
            let box = Box()
            let running = Task { @MainActor in box.value = await call() }
            var asked: LensWorksAgentConfirmation?
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while box.value == nil, ContinuousClock.now < deadline {
                if let pending = harness.automation.pendingConfirmation { asked = pending; try whileAsked(); harness.automation.resolveConfirmation(allow); break }
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
            .openProject, .openRecent, .importImages, .save, .saveAs, .exportPNG, .exportJPEG, .openCatalog, .newCatalog, .addPhotos, .newCanvas, .undo, .redo,
            .locateFolder, .openInEditor
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

    /// The two document commands that run an analysis rather than a setting, on a picture with something in it: the
    /// fill replaces the object with its surroundings, and the subject found becomes the selection.
    @Test func theAnalysisCommandsChangeAPictureWithSomethingInIt() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.createDocument(width: 64, height: 48)
        // A flat blue field with a red block on it, as SmartEditTests uses for the fill.
        let context = try BrushRaster.context(width: 64, height: 48, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 20, y: 16, width: 12, height: 10))
        let picture = try #require(context.makeImage())
        session.insert(ImportedImage(image: picture, thumbnail: picture, name: "Object"))
        session.applySelection(CGPath(rect: CGRect(x: 20, y: 16, width: 12, height: 10), transform: nil), mode: .replace, name: "Marquee")
        session.history.reset()
        @MainActor func red(at x: Int, _ y: Int) throws -> (red: Int, blue: Int) {
            let image = try #require(session.activeLayer?.asset?.image)
            let reading = try BrushRaster.context(width: 64, height: 48, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48), mask: false, context: reading)
            let pixels = try #require(reading.data).assumingMemoryBound(to: UInt8.self)
            return (Int(pixels[y * reading.bytesPerRow + x * 4]), Int(pixels[y * reading.bytesPerRow + x * 4 + 2]))
        }
        #expect(try red(at: 26, 21).red == 255)
        let filled = await fixture.invoke("edit.contentAwareFill")
        #expect(ok(filled) && LensWorksCommandDispatcher.lastInvocation?.id == .contentAwareFill && LensWorksCommandDispatcher.lastOrigin == .agent, "\(text(filled))")
        // The block is gone: where it was is the field's blue, as one agent entry that Undo puts back.
        let after = try red(at: 26, 21)
        #expect(abs(after.red - 51) <= 2 && abs(after.blue - 204) <= 2, "the fill replaced the block, got red \(after.red) blue \(after.blue)")
        #expect(session.filterEdit == nil && session.agentModalReason == nil && session.history.undoCount == 1 && session.history.undoOrigin == .agent
                && session.history.undoName.hasSuffix("(Agent)"))
        let undone = await fixture.invoke("edit.undo")
        #expect(try ok(undone) && red(at: 26, 21).red == 255)
    }

    /// Select Subject on a picture with a subject: the selection it leaves is the subject's outline, not the canvas.
    @Test func selectSubjectSelectsTheSubjectOfAPicture() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        let picture = try Self.subjectPicture()
        session.createDocument(width: picture.width, height: picture.height)
        session.insert(ImportedImage(image: picture, thumbnail: picture, name: "Subject"))
        session.history.reset()
        let before = session.document
        let result = await fixture.invoke("select.subject")
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .selectSubject && LensWorksCommandDispatcher.lastOrigin == .agent)
        #expect(ok(result) && content(result)["changed"] as? Bool == true, "\(text(result))")
        let box = try #require(session.selection?.path.boundingBoxOfPath, "a selection was made")
        let subject = Self.subjectBounds
        // Around the subject, and not the whole picture.
        #expect(box.intersects(subject) && box.width < CGFloat(picture.width) * 0.9 && box.intersection(subject).width > subject.width * 0.5, "selected \(box)")
        #expect(session.document != before && session.history.undoCount == 1 && session.history.undoOrigin == .agent && session.history.undoName == "Select Subject (Agent)"
                && session.agentModalReason == nil)
        #expect(ok(await fixture.invoke("edit.undo")) && session.selection == nil)
    }
    static let subjectBounds = CGRect(x: 180, y: 110, width: 280, height: 280)
    /// A shaded ball on a plain floor and wall: a picture the subject finder has something to find in.
    static func subjectPicture() throws -> CGImage {
        let width = 640, height = 480, space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let wall = try #require(CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.80, green: 0.84, blue: 0.88, alpha: 1), CGColor(srgbRed: 0.62, green: 0.68, blue: 0.74, alpha: 1)] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(wall, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 120), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.38, blue: 0.30, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: 130))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)); context.fillEllipse(in: CGRect(x: 200, y: 95, width: 260, height: 40))
        let ball = try #require(CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.75, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.85, green: 0.15, blue: 0.10, alpha: 1),
                                                                         CGColor(srgbRed: 0.35, green: 0.03, blue: 0.03, alpha: 1)] as CFArray, locations: [0, 0.55, 1]))
        context.saveGState()
        context.addEllipse(in: subjectBounds); context.clip()
        context.drawRadialGradient(ball, startCenter: CGPoint(x: 270, y: 300), startRadius: 4, endCenter: CGPoint(x: 320, y: 250), endRadius: 150, options: [.drawsAfterEndLocation])
        context.restoreGState()
        return try #require(context.makeImage())
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
            // One complete, valid, non-identity range: it decodes, but the renderer indexes all four channels.
            ("image.levels", ["settings": ["ranges": [["black": 40, "gamma": 1, "white": 200, "outputBlack": 0, "outputWhite": 255]]]], "settings.ranges must list exactly 4 values."),
            ("layer.newAdjustment", ["kind": "Levels", "settings": ["ranges": [["black": 40, "gamma": 1, "white": 200, "outputBlack": 0, "outputWhite": 255]]]], "settings.ranges must list exactly 4 values."),
            ("image.curves", ["settings": ["channels": [[["x": 0, "y": 0], ["x": 255, "y": 255]]]]], "settings.channels must list exactly 4 values."),
            ("filter.apply", ["kind": "Camera Raw Filter", "settings": ["mixer": ["hue": [10]]]], "settings.mixer.hue must list exactly 8 values."),
            ("filter.apply", ["kind": "Gaussian Blur", "settings": ["radius": 100_000]], LensWorksAgentSettings.outside),
            ("select.colorRange", ["x": 1e300, "y": 10], "x must be at most \(DocumentLimits.maxSide)."),
            ("layer.transform", ["rotation": 1e300], "rotation must be at most 360."),
            (LensWorksCommandID.exposure.rawValue, ["exposureEV": 1, "expected": ["revision": "7"]], "expected.revision must be a whole number."),
            (LensWorksCommandID.exposure.rawValue, ["exposureEV": 1, "expected": ["variantId": 7]], "expected.variantId must be a string."),
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
        // Behind the argument check, the settings themselves are refused in the shapes that reach the renderer's
        // fixed-size tables, however they were built.
        let range = LevelRange(black: 40, gamma: 1, white: 200)
        #expect(throws: LensWorksCommandRefusal.self) { try LensWorksAgentSettings.check(LevelsSettings(ranges: [range])) }
        #expect(throws: LensWorksCommandRefusal.self) { try LensWorksAgentSettings.check(LevelsSettings(ranges: [LevelRange(black: 300), LevelRange(), LevelRange(), LevelRange()])) }
        #expect(throws: Never.self) { try LensWorksAgentSettings.check(LevelsSettings(ranges: [range, LevelRange(), LevelRange(), LevelRange()])) }
        var raw = FilterSettings()
        raw.cameraRaw.mixer.hue = [10]
        #expect(throws: LensWorksCommandRefusal.self) { try LensWorksAgentSettings.check(.cameraRaw, raw) }
        var curves = FilterSettings()
        curves.curves.channels = [curves.curves.channels[0]]
        #expect(throws: LensWorksCommandRefusal.self) { try LensWorksAgentSettings.check(.curves, curves) }
        #expect(throws: Never.self) { try LensWorksAgentSettings.check(.cameraRaw, FilterSettings()); try LensWorksAgentSettings.check(.curves, FilterSettings()) }
    }

    /// What a hostile caller can put where `value` goes: each list cut short, emptied and over-long, each number not
    /// a number, infinite, and far outside any slider. `expected` is in the refusal when the check that must catch
    /// it is known.
    static func hostile(_ value: Any, key: String, nested: Bool = false) -> [(value: Any, expected: String?)] {
        switch value {
        case let object as [String: Any]:
            return object.keys.sorted().flatMap { name in
                hostile(object[name]!, key: name, nested: nested).map { bad in (object.merging([name: bad.value]) { $1 } as Any, bad.expected) }
            }
        case let list as [Any]:
            let growing = LensWorksAgentSettings.growingLists.contains(key)
            let exact: String? = nested || growing ? nil : "must list exactly \(list.count) values."
            var out: [(Any, String?)] = []
            if !list.isEmpty { out.append(([Any](), exact)) }
            if list.count > 1 { out.append((Array(list.prefix(1)), exact)) }
            if let first = list.first, !growing { out.append((list + [first], exact)) }
            if growing && !nested { out.append((Array(repeating: list.first ?? 0, count: LensWorksAgentSettings.listLimit + 1), "must list at most \(LensWorksAgentSettings.listLimit) values.")) }
            if let first = list.first { out += hostile(first, key: "", nested: true).map { ([$0.value] + list.dropFirst(), $0.expected) } }
            return out
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let finite = "Every number in the arguments must be finite"
            return [(Double.nan, finite), (Double.infinity, finite), (-Double.infinity, finite), (1e12, nil), (-1e12, nil)]
        default: return []
        }
    }

    /// Registry-driven: every value of every settings object an admitted dialog command takes, pushed outside what
    /// its dialog can produce. Each is refused; nothing crashes, opens, or changes the document.
    @Test func everySettingsValueOutsideItsDialogIsRefusedWithoutACrashOrAChange() async throws {
        let commands = LensWorksCommandRegistry.descriptors.filter { $0.agent.isRunnable && $0.parameters.contains { $0.type == .settings } }
        #expect(Set(commands.map(\.id)) == [.curves, .levels, .hueSaturation, .imageAdjustment, .filter, .newAdjustment, .editAdjustment, .addEffect])
        var sent = 0, lists = 0
        for descriptor in commands {
            let id = descriptor.id, kinds = LensWorksAgentSettings.defaults(for: id)
            // The defaults are the schema: one object per kind the command's own `kind` choices name.
            if let choices = descriptor.parameters.first(where: { $0.name == "kind" })?.choices { #expect(Set(kinds.keys) == Set(choices), "\(id.rawValue)") }
            else if id != .editAdjustment { #expect(Array(kinds.keys) == [""], "\(id.rawValue)") }
            for (kind, defaults) in kinds.sorted(by: { $0.key < $1.key }) {
                let fixture = try Fixture(); defer { fixture.cleanUp() }
                try fixture.paint()
                let session = fixture.session
                if id == .editAdjustment { session.addAdjustment(try #require(AdjustmentKind(rawValue: kind))); session.adjustmentEditingID = nil; session.history.reset() }
                let before = session.document, selected = session.selectedLayerIDs
                #expect(fixture.tools.agentAvailability(id) == nil, "\(id.rawValue) \(kind) can run on the fixture")
                for name in defaults.keys.sorted() {
                    for bad in Self.hostile(defaults[name]!, key: name) {
                        var arguments: [String: Any] = ["settings": [name: bad.value]]
                        if !kind.isEmpty, id != .editAdjustment { arguments["kind"] = kind }
                        let result = await fixture.invoke(id.rawValue, arguments)
                        sent += 1
                        if bad.value is [Any] { lists += 1 }
                        let what = "\(id.rawValue) \(kind) \(name) = \(String(describing: bad.value).prefix(160)): \(text(result).prefix(200))"
                        #expect(result["isError"] as? Bool == true && bad.expected.map { text(result).contains($0) } != false, "\(what)")
                        #expect(session.document == before && session.history.undoCount == 0 && session.selectedLayerIDs == selected && session.agentModalReason == nil
                                && session.filterEdit == nil && session.levels == nil && session.hueSaturation == nil && session.effectsEditing == nil, "\(what)")
                    }
                }
            }
        }
        // The walk reached the settings it is for: hundreds of values, and the fixed-size lists among them.
        #expect(sent > 500 && lists > 30, "sent \(sent), lists \(lists)")
    }

    /// Registry-driven: every numeric argument of every admitted command, not a number, infinite, and far outside
    /// any size or radius. Each is refused before the command runs; nothing crashes or changes.
    @Test func everyNumericArgumentOutsideItsRangeIsRefusedWithoutACrashOrAChange() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paint()
        let session = fixture.session, before = session.document
        let numeric: Set<LensWorksCommandParameterType> = [.unitInterval, .exposure, .number, .cursor, .rating, .integer]
        var sent = 0
        for descriptor in LensWorksCommandRegistry.descriptors where descriptor.agent.isRunnable {
            for parameter in descriptor.parameters where numeric.contains(parameter.type) {
                // Every size, radius, coordinate and angle a document or file command takes is bounded by the registry.
                if descriptor.agent.kind != .catalog, parameter.type != .unitInterval {
                    #expect(parameter.minimum != nil && parameter.maximum != nil, "\(descriptor.id.rawValue).\(parameter.name) has no range")
                }
                var values: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, 0.5 + (parameter.maximum ?? 9e15)]
                if let maximum = parameter.maximum { values.append(maximum + 1) }
                if let minimum = parameter.minimum { values.append(minimum - 1) }
                for value in values {
                    var arguments: [String: Any] = [parameter.name: value]
                    for other in descriptor.parameters where other.required && other.name != parameter.name {
                        arguments[other.name] = numeric.contains(other.type) ? (other.minimum ?? 1) as Any : (other.choices?.first ?? "x") as Any
                    }
                    let result = await fixture.invoke(descriptor.id.rawValue, arguments)
                    sent += 1
                    #expect(result["isError"] as? Bool == true, "\(descriptor.id.rawValue).\(parameter.name) = \(value): \(text(result).prefix(200))")
                    #expect(session.document == before && session.history.undoCount == 0 && session.agentModalReason == nil && session.colorRange == nil
                            && session.transformEdit == nil, "\(descriptor.id.rawValue).\(parameter.name) = \(value)")
                }
            }
        }
        #expect(sent > 150, "sent \(sent)")
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
        #expect(failing["isError"] as? Bool == true && text(failing) == "Command 3 (layer.ungroup): Select a folder first. The whole batch was rolled back: the document, its history, the selection and the palette colors are as they were (anything a cut or copy put on the clipboard stays there).", "\(text(failing))")
        #expect(session.document == starting && session.history.undoCount == 0 && !session.isModified && session.selectedLayerIDs == selected)
        // Project-file commands and commands that ask the person never ride in a batch.
        let mixed = await fixture.tools.call("batch", arguments: ["commands": [["command": "layer.newBlank"], ["command": "file.exportPNG", "arguments": ["path": fixture.granted.appendingPathComponent("a.png").path]]]])
        #expect(mixed["isError"] as? Bool == true && text(mixed).contains("file.exportPNG cannot be part of a batch") && session.document == starting
                && !FileManager.default.fileExists(atPath: fixture.granted.appendingPathComponent("a.png").path))
        // What a member set on its way to the failure goes back too: a fill's palette color, and the effect the
        // person had targeted before a member named its layer.
        let blue = try fixture.layer("Blue").id
        session.setEffects(LayerEffects(stroke: StrokeEffect()), on: blue); session.history.reset()
        session.effectSelection = LayerEffectSelection(layerID: blue, kind: .stroke)
        session.foregroundColor = .black; session.backgroundColor = .white
        let effects = session.document
        let colored = await fixture.tools.call("batch", arguments: ["commands": [
            ["command": "select.all"], ["command": "edit.fillForeground", "arguments": ["color": "#00FF00", "layer": blue.uuidString]],
            ["command": "edit.fillBackground", "arguments": ["color": "#FF00FF"]], ["command": "layer.ungroup"]]])
        #expect(colored["isError"] as? Bool == true && session.document == effects && session.history.undoCount == 0, "\(text(colored))")
        #expect(session.foregroundColor == .black && session.backgroundColor == .white, "the palette is as the person left it")
        #expect(session.effectSelection == LayerEffectSelection(layerID: blue, kind: .stroke), "the person's targeted effect is still targeted")
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
        // Nor a folder that takes in the home folder, the Library inside it, LensWorks's own data, or the data volume
        // (the same disk under another name): each is refused, and nothing is granted.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var broad = [home, URL(fileURLWithPath: home).deletingLastPathComponent().path, home + "/Library", home + "/Library/Application Support",
                     "/System/Volumes/Data", "/System/Volumes", "/System", "/System/Volumes/Data" + home, "/System/Volumes/Data" + home + "/Library"]
        if FileManager.default.fileExists(atPath: home + "/Library/Application Support/LensWorks") { broad.append(home + "/Library/Application Support/LensWorks") }
        for path in broad {
            #expect(FileManager.default.fileExists(atPath: path), "\(path) is there to be refused")
            do { try folders.grant(URL(fileURLWithPath: path)); Issue.record("\(path) was granted") }
            catch { #expect(error.localizedDescription.contains("cannot be granted to automation"), "\(path): \(error.localizedDescription)") }
        }
        #expect(folders.grants.isEmpty && LensWorksGrantedFolders(defaults: fixture.harness.defaults).grants.isEmpty)
        // The rule is about what a folder holds, not where it is: a folder inside the home folder is fine.
        #expect(LensWorksGrantedFolders.isTooBroad(home) && LensWorksGrantedFolders.isTooBroad(home + "/Library") && LensWorksGrantedFolders.isTooBroad("/Users")
                && LensWorksGrantedFolders.isTooBroad(home + "/Library/Application Support/LensWorks")
                && !LensWorksGrantedFolders.isTooBroad(home + "/Pictures/Shoot") && !LensWorksGrantedFolders.isTooBroad(home + "/Library/Application Support/Other")
                && !LensWorksGrantedFolders.isTooBroad(granted.path))
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
        #expect(Set(pathed.map(\.id)) == [.openCatalog, .newCatalog, .addPhotos, .openProject, .openRecent, .importImages, .saveAs, .exportPNG, .exportJPEG, .locateFolder])
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

        // A file no argument names: an image file copied in Finder is on the clipboard as its path beside its picture,
        // and Paste reads the file.
        try fixture.writePNG(fixture.outside.appendingPathComponent("copied.png")); try fixture.writePNG(fixture.granted.appendingPathComponent("copied.png"))
        @MainActor func copyFile(_ url: URL) throws -> Bool {
            fixture.pasteboard.clearContents()
            guard fixture.pasteboard.writeObjects([url as NSURL]) else { return false }
            fixture.pasteboard.addTypes([.png], owner: nil)
            return fixture.pasteboard.setData(try Data(contentsOf: url), forType: .png)
        }
        #expect(try copyFile(fixture.outside.appendingPathComponent("copied.png")) && session.canPaste)
        let pastedOutside = await fixture.invoke("edit.paste")
        #expect(pastedOutside["isError"] as? Bool == true && text(pastedOutside).hasPrefix("The clipboard holds a file. ") && text(pastedOutside).contains("outside every folder granted to automation"), "\(text(pastedOutside))")
        #expect(session.document == before && session.history.undoCount == 0)
        #expect(try copyFile(fixture.granted.appendingPathComponent("copied.png")))
        let pastedInside = await fixture.invoke("edit.paste")
        #expect(ok(pastedInside) && session.document?.layers.count == 3 && session.history.undoOrigin == .agent, "\(text(pastedInside))")
        #expect(ok(await fixture.invoke("edit.undo")) && session.document == before)
        try FileManager.default.removeItem(at: fixture.outside.appendingPathComponent("copied.png"))

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

    /// Enumerates the admitted commands: each is classified by name (none by falling through), and whatever cannot
    /// be put back carries the confirmation rule that covers it.
    @Test func everyIrreversibleAdmittedCommandCarriesAConfirmation() throws {
        let admitted = LensWorksCommandRegistry.descriptors.filter { $0.agent.isRunnable }
        // Classified explicitly, and only admitted commands are: a command missing here would be irreversible.
        #expect(Set(LensWorksCommandID.agentReversals.keys) == Set(admitted.map(\.id)),
                "unclassified \(Set(admitted.map(\.id)).subtracting(LensWorksCommandID.agentReversals.keys).map(\.rawValue).sorted()), not admitted \(Set(LensWorksCommandID.agentReversals.keys).subtracting(admitted.map(\.id)).map(\.rawValue).sorted())")
        #expect(LensWorksCommandID.hideApp.reversal == .transient)
        var always: Set<LensWorksCommandID> = [], replacing: Set<LensWorksCommandID> = [], discarding: Set<LensWorksCommandID> = []
        for descriptor in admitted {
            let id = descriptor.id
            #expect(descriptor.reversal == LensWorksCommandID.agentReversals[id], "\(id.rawValue)")
            #expect(descriptor.reversal.isCovered(by: descriptor.agentConfirmation), "\(id.rawValue) is \(descriptor.reversal) but its rule is \(descriptor.agentConfirmation)")
            #expect(descriptor.requiresAgentConfirmation == (descriptor.agentConfirmation != .never))
            if descriptor.agentConfirmation == .always { always.insert(id) }
            if descriptor.agentConfirmation == .whenReplacingFile { replacing.insert(id) }
            if descriptor.agentConfirmation == .whenDiscardingCatalogHistory { discarding.insert(id) }
            // The registry's own history facts agree with the classification: what it calls undoable is in history,
            // and nothing without a history owner claims to be.
            if descriptor.undoable { #expect(descriptor.reversal == .history, "\(id.rawValue)") }
            if descriptor.historyOwner == .none { #expect(descriptor.reversal != .history, "\(id.rawValue)") }
            if descriptor.reversal == .history, !descriptor.undoable {
                #expect([.undo, .redo, .undoRecipe, .redoRecipe].contains(id), "\(id.rawValue) is not undoable through history")
            }
            // A command that writes a file names it as a path, so the granted folders and the replace rule both apply.
            if descriptor.reversal == .replacesFile || descriptor.reversal == .replacesCatalog { #expect(descriptor.parameters.contains { $0.type == .path && $0.required }, "\(id.rawValue)") }
        }
        // Independently of the classification: the permanent deletes, the destructive menu item, the relink, every
        // file writer, and the two that let the open catalog go.
        #expect(always == [.deleteVirtualFolder, .deleteKeyword, .save, .locateFolder] && replacing == [.saveAs, .exportPNG, .exportJPEG] && discarding == [.openCatalog, .newCatalog])
        #expect(admitted.filter { $0.reversal == .irreversible }.map(\.id) == [.save, .deleteVirtualFolder])
        #expect(admitted.filter { $0.reversal == .replacesCatalog }.map(\.id) == [.openCatalog, .newCatalog])
        // The rules cover what they are for and no less: none lets a permanent change through unasked.
        #expect(!LensWorksCommandReversal.irreversible.isCovered(by: .whenReplacingFile) && !LensWorksCommandReversal.irreversible.isCovered(by: .never)
                && !LensWorksCommandReversal.replacesCatalog.isCovered(by: .never) && !LensWorksCommandReversal.replacesCatalog.isCovered(by: .whenReplacingFile)
                && !LensWorksCommandReversal.replacesFile.isCovered(by: .never) && !LensWorksCommandReversal.replacesFile.isCovered(by: .whenDiscardingCatalogHistory))
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
        // A long path: the row keeps the folder it starts in and the file name being replaced at its end.
        let deep = (0..<3).reduce(fixture.granted) { folder, level in folder.appendingPathComponent(String(repeating: "abcdefghij"[String.Index(utf16Offset: level, in: "abcdefghij")], count: 90)) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let long = deep.appendingPathComponent("The file being replaced.png")
        try original.write(to: long)
        #expect(long.path.count > LensWorksAgentConfirmation.Item.nameLimit + 60)
        let longAsked = try await fixture.answering(false) { await fixture.invoke("file.exportPNG", ["path": long.path]) }
        let row = try #require(longAsked.asked?.items.first?.name)
        #expect(row.count == LensWorksAgentConfirmation.Item.nameLimit && row.hasSuffix("/The file being replaced.png") && row.hasPrefix(String(long.path.prefix(100))) && row.contains("…"), "\(row)")
        #expect(try LensWorksAgentConfirmation.Item(action: "x", name: "short.png").name == "short.png" && Data(contentsOf: long) == original)

        // While the sheet is open the grant is taken back: the person's Allow no longer writes anything.
        let taken = try #require(automation.folders.grants.first)
        let revoked = try await fixture.answering(true, whileAsked: { automation.folders.revoke(taken.id) }) { await fixture.invoke("file.exportPNG", ["path": target.path]) }
        #expect(revoked.asked != nil && revoked.result["isError"] as? Bool == true && text(revoked.result).hasPrefix("No folders are granted to automation"), "\(text(revoked.result))")
        try automation.folders.grant(fixture.granted)
        // While the sheet is open a folder on the way becomes a link out of the granted folder: nothing is written
        // through it, for a replaced file or for the project's own.
        let inside = fixture.granted.appendingPathComponent("sub"), moved = fixture.granted.appendingPathComponent("sub-moved")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        for (command, name) in [("file.exportPNG", "swap.png"), ("file.exportJPEG", "swap.jpg"), ("file.saveAs", "swap.comp")] {
            try original.write(to: inside.appendingPathComponent(name)); try original.write(to: fixture.outside.appendingPathComponent(name))
            let swapped = try await fixture.answering(true, whileAsked: {
                try FileManager.default.moveItem(at: inside, to: moved)
                try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: fixture.outside)
            }) { await fixture.invoke(command, ["path": inside.appendingPathComponent(name).path]) }
            #expect(swapped.asked != nil && swapped.result["isError"] as? Bool == true && text(swapped.result).contains("outside every folder granted to automation"), "\(command): \(text(swapped.result))")
            #expect(try Data(contentsOf: fixture.outside.appendingPathComponent(name)) == original && Data(contentsOf: moved.appendingPathComponent(name)) == original, "\(command) wrote nothing")
            try FileManager.default.removeItem(at: inside); try FileManager.default.moveItem(at: moved, to: inside)
        }
        // A folder on the way that becomes a link to another place inside the granted folder is refused as well: the
        // person was shown one file, and this is another.
        let sibling = fixture.granted.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let redirected = try await fixture.answering(true, whileAsked: {
            try FileManager.default.moveItem(at: inside, to: moved)
            try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: sibling)
        }) { await fixture.invoke("file.exportPNG", ["path": inside.appendingPathComponent("swap.png").path]) }
        #expect(redirected.asked != nil && redirected.result["isError"] as? Bool == true && text(redirected.result) == "path no longer reaches the file it did when the request was checked: nothing was read or written.", "\(text(redirected.result))")
        #expect(!FileManager.default.fileExists(atPath: sibling.appendingPathComponent("swap.png").path))
        try FileManager.default.removeItem(at: inside); try FileManager.default.moveItem(at: moved, to: inside)
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
            // The organize steps above are still in Undo, so the person is asked before the catalog is let go.
            let created = try await fixture.answering(true) { await fixture.invoke("file.catalog.new", ["path": second.path]) }.result
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

    /// Open in Editor names a photo, not a file: the original it reads and the working version it opens or writes are
    /// found and held to the granted folders, and the folder chooser never opens for an agent.
    @Test func openingACatalogPhotoInTheEditorIsHeldToTheGrantedFolders() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try LensWorksCatalogBrowserTests.Fixture(images: 2)
        try await catalog.run { model in
            try await catalog.importPhotos(model)
            let folders = fixture.harness.automation.folders
            @MainActor func surface() -> (workspace: ProjectWorkspace, invoke: (String) async -> [String: Any]) {
                let workspace = ProjectWorkspace()
                workspace.configureController = { $0.recordsRecentProjects = false; $0.sharesWorkingVersions = false }
                let tools = LensWorksAgentTools(session: { workspace.current.session }, catalog: { model }, folders: folders)
                tools.projects = { workspace.current.controller }; tools.workspace = { workspace }
                return (workspace, { photo in await tools.call("invoke_command", arguments: ["command": "catalog.asset.openInEditor", "arguments": ["photo": photo]]) })
            }
            let first = surface(), workspace = first.workspace
            let photo = try #require(model.assets.last), selectedBefore = model.selectedPhotoID, outside = catalog.root.appendingPathComponent("Versions"), inside = fixture.granted.appendingPathComponent("Versions")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            @MainActor func untouched(_ why: Comment) throws {
                #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil && model.error == nil, why)
                #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty && FileManager.default.contentsOfDirectory(atPath: inside.path).isEmpty, why)
            }
            // The original is outside every granted folder: refused before the photo is even selected.
            #expect(model.outputDirectory == nil)
            let original = await first.invoke(photo.id)
            #expect(original["isError"] as? Bool == true && text(original).hasPrefix("The photo’s original: ") && text(original).contains("outside every folder granted to automation"), "\(text(original))")
            #expect(model.selectedPhotoID == selectedBefore && selectedBefore != photo.id)
            try untouched("original outside")
            // The original is granted, but no working-versions folder is chosen. The menu item would open the folder
            // chooser here; an agent is refused instead, and nothing opens.
            try folders.grant(catalog.photos)
            let unchosen = await first.invoke(photo.id)
            #expect(unchosen["isError"] as? Bool == true && text(unchosen) == "No working-versions folder is chosen: the person chooses it in the catalog before an agent can create a working version.", "\(text(unchosen))")
            try untouched("no output chosen")
            // A folder is chosen, but outside the granted folders: nothing is written there.
            await model.setOutput(outside.path)
            #expect(model.outputDirectory != nil && model.error == nil)
            let output = await first.invoke(photo.id)
            #expect(output["isError"] as? Bool == true && text(output).hasPrefix("The working-versions folder: ") && text(output).contains("outside every folder granted to automation"), "\(text(output))")
            try untouched("output outside")
            // Both inside: the photo opens as a new working version, saved in the granted folder.
            await model.setOutput(inside.path)
            let opened = await first.invoke(photo.id)
            #expect(ok(opened) && workspace.current.session.document != nil && workspace.current.controller.workingVersion?.photoID == photo.photoID, "\(text(opened))")
            let written = try FileManager.default.contentsOfDirectory(atPath: inside.path)
            #expect(try written.count == 1 && written[0].hasSuffix(".comp") && FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            #expect(workspace.current.controller.agentRequest == nil && workspace.agentRequest == nil)
            let version = try #require(workspace.current.controller.workingVersion)
            // The catalog holds what it runs to what was admitted: another original or folder than the one checked
            // opens nothing.
            let stray = ProjectWorkspace()
            stray.configureController = { $0.recordsRecentProjects = false; $0.sharesWorkingVersions = false }
            let unopened = try #require(model.assets.first), chosen = try #require(model.outputDirectory)
            let itsOriginal = try await model.service.resolve(unopened).originalURL.path
            await model.select(unopened)
            for admitted in [(original: "/somewhere/else.png", output: chosen), (original: itsOriginal, output: outside.path)] {
                await model.createWorkingVersion(workspace: stray, admitted: admitted)
                #expect(try model.error == "The photo’s original or the working-versions folder changed after the request was checked: nothing was opened."
                        && stray.current.session.document == nil && FileManager.default.contentsOfDirectory(atPath: inside.path).count == 1, "\(admitted)")
                model.error = nil
            }

            // The photo now has a working version (this fixture's own index finds it in the folder): opening it reads
            // that project, which must be granted too.
            await model.reconcileWorkingVersions()
            let second = surface()
            let grant = try #require(folders.grants.first { $0.path == fixture.granted.path })
            folders.revoke(grant.id)
            let existing = await second.invoke(photo.id)
            #expect(existing["isError"] as? Bool == true && text(existing).hasPrefix("The photo’s working version: ") && text(existing).contains("outside every folder granted to automation"), "\(text(existing)) versions \(model.selectedVersions.count)/\(model.versions.count)")
            #expect(second.workspace.tabs.count == 1 && second.workspace.current.session.document == nil && model.error == nil)
            try folders.grant(fixture.granted)
            let reopened = await second.invoke(photo.id)
            #expect(ok(reopened) && second.workspace.current.controller.workingVersion?.id == version.id && second.workspace.current.session.document != nil, "\(text(reopened))")
            #expect(try FileManager.default.contentsOfDirectory(atPath: inside.path).count == 1)

        }
    }

    /// The catalog's organize history: an agent's steps are named as its own, it steps only over its own, and it
    /// cannot discard the person's by opening another catalog or by riding a change in beside an approved delete.
    @Test func organizeHistoryKeepsWhoMadeEachStepAndIsNeverDiscardedUnasked() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try LensWorksCatalogBrowserTests.Fixture(images: 2)
        try await catalog.run { model in
            fixture.harness.catalog = model
            try await catalog.importPhotos(model)
            try fixture.harness.automation.folders.grant(catalog.root)
            try await model.createKeyword("Doomed"); try await model.createKeyword("Mover")
            let original = try #require(model.catalogPath), photo = try #require(model.assets.first)
            await model.select(photo)
            let created = model.organizationUndo.count

            // The person rates; the agent flags and adds a synonym. Each step says who made it.
            try await model.organize(.rating(3))
            #expect(model.organizationUndo.count == created + 1 && model.organizationUndo.last?.origin == .user && model.organizationUndo.last?.title.hasSuffix("(Agent)") == false)
            #expect(ok(await fixture.invoke("catalog.organize.flag", ["flag": "pick"])))
            #expect(model.organizationUndo.count == created + 2 && model.organizationUndo.last?.origin == .agent && model.organizationUndo.last?.title.hasSuffix(" (Agent)") == true,
                    "\(model.organizationUndo.last?.title ?? "")")
            // The catalog's own rating command is an organize step too, and is the agent's when the agent runs it.
            try await model.loadCatalogVariants()
            let rated = await fixture.invoke(LensWorksCommandID.rating.rawValue, ["rating": 4])
            #expect(ok(rated) && model.organizationUndo.count == created + 3 && model.organizationUndo.last?.origin == .agent && model.organizationUndo.last?.title == "Rating 4 (Agent)", "\(text(rated)) \(model.organizationUndo.last?.title ?? "")")
            try await model.undoOrganization(origin: .agent)
            #expect(model.organizationUndo.count == created + 2 && model.assets.first { $0.id == photo.id }?.rating == 3)
            #expect(ok(await fixture.invoke("catalog.keyword.addSynonym", ["keyword": "Mover", "synonym": "Shifter"])))
            #expect(model.organizationUndo.last?.origin == .agent && model.organizationUndo.last?.title == "Add Synonym Shifter (Agent)")
            // An agent undoes its own two steps and stops at the person's; it redoes its own and never the person's.
            try await model.undoOrganization(origin: .agent); try await model.undoOrganization(origin: .agent)
            #expect(model.organizationUndo.count == created + 1 && model.organizationRedo.count == 2 && model.assets.first { $0.id == photo.id }?.flag == "unflagged")
            do { try await model.undoOrganization(origin: .agent); Issue.record("an agent undid the person's step") }
            catch { #expect(error.localizedDescription == "The last organization change is the person’s own: an agent undoes only its own.") }
            #expect(model.organizationUndo.count == created + 1 && model.assets.first { $0.id == photo.id }?.rating == 3)
            try await model.redoOrganization(origin: .agent)
            #expect(model.assets.first { $0.id == photo.id }?.flag == "pick")
            try await model.undoOrganization(origin: .agent); try await model.undoOrganization()
            do { try await model.redoOrganization(origin: .agent); Issue.record("an agent redid the person's step") }
            catch { #expect(error.localizedDescription == "The next organization change to redo is the person’s own: an agent redoes only its own.") }
            try await model.redoOrganization()
            let steps = model.organizationUndo.count + model.organizationRedo.count, undo = model.organizationUndo.count
            #expect(undo == created + 1 && steps == created + 3)

            // A delete the person approves is a name: no other member of the batch may change what that name holds.
            // (Nobody is asked, so nothing waits; were someone asked, this test would not answer.)
            fixture.harness.automation.confirmationTimeout = .seconds(2)
            let paired = await fixture.tools.call("batch", arguments: ["commands": [
                ["command": "catalog.keyword.move", "arguments": ["keyword": "Mover", "parent": "Doomed"]],
                ["command": "catalog.keyword.delete", "arguments": ["keyword": "Doomed"]]]])
            #expect(paired["isError"] as? Bool == true && text(paired) == "Command 2 (catalog.keyword.delete): It needs the person’s confirmation, so it cannot share a batch with another command that changes keywords or virtual folders; run it with invoke_command. Nothing was run.", "\(text(paired))")
            try await model.loadKeywords()
            #expect(fixture.harness.automation.pendingConfirmation == nil && Set(model.keywords.map(\.name)) == ["Doomed", "Mover"] && model.organizationUndo.count == undo)
            fixture.harness.automation.confirmationTimeout = LensWorksAutomation.confirmationTimeout
            // What the person approved is checked again at the moment it runs: an earlier member that moved the
            // keyword page off the approved keyword stops the delete.
            let wandered = try await fixture.answering(true) { await fixture.tools.call("batch", arguments: ["commands": [
                ["command": "catalog.keyword.showNested", "arguments": ["keyword": "Doomed"]],
                ["command": "catalog.keyword.delete", "arguments": ["keyword": "Doomed"]]]]) }
            let rows = content(wandered.result)["results"] as? [[String: Any]] ?? []
            #expect(wandered.asked != nil && wandered.result["isError"] as? Bool == true && rows.last?["status"] as? String == "failed"
                    && (rows.last?["message"] as? String)?.contains("A keyword changed while waiting for confirmation: nothing was run or deleted.") == true, "\(text(wandered.result))")
            try await model.loadKeywords()
            #expect(Set(model.keywords.map(\.name)) == ["Doomed", "Mover"] && model.organizationUndo.count == undo)

            // A folder that is not a catalog is refused before anyone is asked and before the open catalog is let go.
            fixture.harness.automation.confirmationTimeout = .seconds(2)
            let notCatalog = await fixture.invoke("file.catalog.open", ["path": catalog.photos.path])
            fixture.harness.automation.confirmationTimeout = LensWorksAutomation.confirmationTimeout
            #expect(notCatalog["isError"] as? Bool == true && text(notCatalog) == "That folder is not a catalog: it has no catalog database.")
            #expect(model.catalogPath == original && model.organizationUndo.count == undo && fixture.harness.automation.pendingConfirmation == nil)
            // Opening another catalog would discard the organize history: the person is asked, and declining keeps it.
            let second = catalog.root.appendingPathComponent("Second")
            for (command, path) in [("file.catalog.new", second.path), ("file.catalog.open", original)] {
                let declined = try await fixture.answering(false) { await fixture.invoke(command, ["path": path]) }
                let item = try #require(declined.asked?.items.first, "\(command) asked the person")
                #expect(declined.result["isError"] as? Bool == true && item.name == original && item.action.hasPrefix("Discard \(steps) organize changes from Undo to "), "\(command): \(item.action)")
                #expect(model.catalogPath == original && model.organizationUndo.count == undo && model.organizationRedo.count == steps - undo, "\(command) left the catalog and its history")
            }
            #expect(!FileManager.default.fileExists(atPath: second.path))
            // The command itself refuses without that answer, whoever calls it.
            let direct = try fixture.tools.parse(["command": "file.catalog.new", "arguments": ["path": second.path]])
            do { _ = try await LensWorksCommandDispatcher.dispatchStandalone(direct.admission, context: fixture.tools.context); Issue.record("ran unconfirmed") }
            catch { #expect(error.localizedDescription.contains("the person has not confirmed discarding them")) }
            #expect(model.catalogPath == original && model.organizationUndo.count == undo && !FileManager.default.fileExists(atPath: second.path))
            // A catalog that cannot be opened leaves the person with the one they had.
            let broken = catalog.root.appendingPathComponent("Broken")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("not a database".utf8).write(to: broken.appendingPathComponent("catalog.sqlite3"))
            let failed = try await fixture.answering(true) { await fixture.invoke("file.catalog.open", ["path": broken.path]) }
            #expect(failed.asked != nil && failed.result["isError"] as? Bool == true && model.catalogPath == original && model.error == nil, "\(text(failed.result))")
            // Allowed: the new catalog opens, with no history; and with none to lose, nobody is asked.
            await model.select(try #require(model.assets.first))
            try await model.organize(.rating(2))
            let allowed = try await fixture.answering(true) { await fixture.invoke("file.catalog.new", ["path": second.path]) }
            #expect(ok(allowed.result) && allowed.asked != nil && (try? LensWorksGrantedFolders.realPath(model.catalogPath ?? "/")) == second.path && model.organizationUndo.isEmpty, "\(text(allowed.result))")
            let unasked = await fixture.invoke("file.catalog.open", ["path": original])
            #expect(ok(unasked) && model.catalogPath == original, "\(text(unasked))")
        }
    }

    /// Locate Moved Folder: the folder's originals are relinked to a granted folder, all or none, once the person allows.
    @Test func locatingAMovedFolderRelinksItsOriginalsAfterThePersonAllows() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try LensWorksCatalogBrowserTests.Fixture(images: 2)
        try await catalog.run { model in
            fixture.harness.catalog = model
            try await catalog.importPhotos(model)
            let moved = catalog.root.appendingPathComponent("Moved"), empty = catalog.root.appendingPathComponent("Empty"), review = model.relink
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            // get_state lists the catalog's folders with the ids the command takes.
            try await model.loadFolders()
            let listed = (content(await fixture.tools.call("get_state", arguments: [:]))["catalog"] as? [String: Any])?["folders"] as? [[String: Any]] ?? []
            // The catalog lists its folders from the disk's root down, each with the id the command takes; a folder
            // deeper than the page is named by the path it had when its photos were added.
            let root = try #require(listed.first?["id"] as? String)
            #expect(listed.count == model.folders.count && listed.first?["path"] as? String == LensWorksRelinkPaths.label(model.folders[0].locator))
            let folder = catalog.photos.path
            try FileManager.default.moveItem(at: catalog.photos, to: moved)
            await model.relinkChanged()
            @MainActor func located() async throws -> String { try await model.service.resolve(try #require(model.assets.first)).originalURL.path }
            #expect(try await located().hasPrefix(catalog.photos.path))

            // Outside the granted folders: refused with the rule, and nobody is asked.
            let ungranted = await fixture.invoke("catalog.folder.locate", ["folder": folder, "path": moved.path])
            #expect(ungranted["isError"] as? Bool == true && text(ungranted).contains("outside every folder granted to automation") && review.plan == nil)
            try fixture.harness.automation.folders.grant(catalog.root)
            let unknown = await fixture.invoke("catalog.folder.locate", ["folder": "987654321", "path": moved.path])
            #expect(unknown["isError"] as? Bool == true && text(unknown) == "folder must be a catalog folder id from get_state, or the absolute path the folder had before it moved." && review.plan == nil)
            // Named by id, the row shows the folder as the catalog knows it.
            let byID = try await fixture.answering(false) { await fixture.invoke("catalog.folder.locate", ["folder": root, "path": moved.path]) }
            #expect(byID.result["isError"] as? Bool == true && byID.asked?.items.first?.name == LensWorksRelinkPaths.label(model.folders[0].locator) + " → " + moved.path && review.plan == nil)
            // Declined: nothing is reviewed or relinked. The row names the folder and where it would point.
            let declined = try await fixture.answering(false) { await fixture.invoke("catalog.folder.locate", ["folder": folder, "path": moved.path]) }
            #expect(declined.result["isError"] as? Bool == true && declined.asked?.items.first?.action == "Locate Moved Folder"
                    && declined.asked?.items.first?.name == catalog.photos.path.suffix(96) + " → " + moved.path && review.plan == nil)
            // Allowed, but the folder does not hold the originals: all or none means none.
            let wrong = try await fixture.answering(true) { await fixture.invoke("catalog.folder.locate", ["folder": folder, "path": empty.path]) }
            #expect(wrong.result["isError"] as? Bool == true && text(wrong.result).contains("Nothing was relinked") && review.lastApplied == nil, "\(text(wrong.result))")
            #expect(try await located().hasPrefix(catalog.photos.path))
            // Allowed with the right folder: every original under it now points there.
            let allowed = try await fixture.answering(true) { await fixture.invoke("catalog.folder.locate", ["folder": folder, "path": moved.path]) }
            #expect(ok(allowed.result) && allowed.asked != nil && review.plan?.state == "applied" && review.lastApplied != nil && text(allowed.result).contains("2 originals"), "\(text(allowed.result))")
            #expect(try await located().hasPrefix(moved.path) && LensWorksCommandDispatcher.lastInvocation?.id == .locateFolder && LensWorksCommandDispatcher.lastOrigin == .agent)
            // The review's own Undo puts every location back; the fixture's originals go home.
            try await review.undo()
            #expect(try await located().hasPrefix(catalog.photos.path))
            try FileManager.default.moveItem(at: moved, to: catalog.photos)
            await model.relinkChanged()
        }
    }

    /// A failure in an agent's file command goes back to the agent from the project it is driving and from no other;
    /// and the RAW originals a project reaches are files held to the granted folders like any it names.
    @Test func anAgentsFileFailureStaysWithItsOwnProjectAndAProjectsOriginalsAreHeldToTheGrants() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let workspace = ProjectWorkspace(), folders = fixture.harness.automation.folders
        workspace.configureController = { $0.recordsRecentProjects = false }
        let tools = LensWorksAgentTools(session: { workspace.current.session }, catalog: { nil }, folders: folders)
        tools.projects = { workspace.current.controller }; tools.workspace = { workspace }
        tools.automation = fixture.harness.automation
        @MainActor func invoke(_ command: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
            await tools.call("invoke_command", arguments: ["command": command, "arguments": arguments])
        }
        let canvases = [await invoke("file.newCanvas", ["width": 64, "height": 48]), await invoke("file.newCanvas", ["width": 32, "height": 32])]
        #expect(canvases.allSatisfy(ok))
        let other = workspace.tabs[0].controller, driven = workspace.current.controller
        #expect(other !== driven && workspace.tabs.allSatisfy { $0.controller.agentRequest == nil && !$0.controller.recordsRecentProjects })
        // While the agent's command runs, only the project it drives reports to it.
        @MainActor final class Seen { var driven = false, others = false, done = false }
        let seen = Seen()
        let watcher = Task { @MainActor in
            while !seen.done {
                if driven.agentRequest != nil { seen.driven = true }
                if other.agentRequest != nil { seen.others = true }
                await Task.yield()
            }
        }
        // The destination's folder is a file: the save fails, and the failure comes back instead of an alert.
        try Data("x".utf8).write(to: fixture.granted.appendingPathComponent("blocked"))
        let failed = await invoke("file.saveAs", ["path": fixture.granted.appendingPathComponent("blocked/work.comp").path])
        seen.done = true; await watcher.value
        #expect(failed["isError"] as? Bool == true && text(failed).hasPrefix("Couldn’t save the project: "), "\(text(failed))")
        #expect(seen.driven && !seen.others && driven.agentRequest == nil && other.agentRequest == nil && workspace.agentRequest == nil)

        // A project is read before it is installed, and what the agent's request refuses never opens.
        let project = fixture.granted.appendingPathComponent("work.comp")
        #expect(ok(await invoke("file.saveAs", ["path": project.path])))
        let session = EditorSession(), controller = ProjectController(session: session), request = ProjectAgentRequest()
        controller.recordsRecentProjects = false
        request.admit = { _ in throw LensWorksCommandRefusal(reason: "A RAW layer’s original: not granted.") }
        controller.agentRequest = request
        #expect(await controller.open(project) == false && session.document == nil && request.failure == "Couldn’t open the project: A RAW layer’s original: not granted.")
        // The check the agent's request makes: every live RAW layer's original inside a granted folder.
        let snapshot = try #require(driven.session.projectSnapshot())
        #expect(throws: Never.self) { try LensWorksAgentProjectCommands.admitSources(snapshot, folders: folders) }
        var manifest = snapshot.manifest
        manifest.layers[0].liveSource = try FloatRetouchFixture().node(width: 4, height: 4)
        let raw = ProjectSnapshot(manifest: manifest, images: snapshot.images)
        do { try LensWorksAgentProjectCommands.admitSources(raw, folders: folders); Issue.record("an original outside the granted folders was admitted") }
        catch { #expect(error.localizedDescription.hasPrefix("A RAW layer’s original: ") && error.localizedDescription.contains("outside every folder granted to automation")) }
        manifest.layers[0].liveSource = nil; manifest.layers[0].liveSourceFile = "unread"
        #expect(throws: LensWorksCommandRefusal.self) { try LensWorksAgentProjectCommands.admitSources(ProjectSnapshot(manifest: manifest, images: snapshot.images), folders: folders) }
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
