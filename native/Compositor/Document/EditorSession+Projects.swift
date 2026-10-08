import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var snapshot = projectSnapshot(document, selection: activeLayerID)
        let archive = history.archive
        func state(_ value: DocumentHistory.Snapshot) -> ProjectHistoryState {
            .init(project: value.document.map { projectSnapshot($0, selection: value.activeLayerID) }, revision: value.revision)
        }
        snapshot.history = .init(past: archive.past.map { .init(name: $0.name, before: state($0.before), after: state($0.after)) },
            future: archive.future.map { .init(name: $0.name, before: state($0.before), after: state($0.after)) }, revision: archive.revision)
        return snapshot
    }
    private func projectSnapshot(_ document: CanvasDocument, selection: UUID?) -> ProjectSnapshot {
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style)
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: selection, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides), images: images, masks: masks)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        commandContextEpoch &+= 1
        commandInteraction = nil; opacityEditLayerID = nil
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map {
                ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                           isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                           shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                           effects: $0.effects,
                           text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image))
            }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        activeLayerID = manifest.activeLayerID
        projectURL = manifest.recoveryDocumentID == nil ? url : nil
        renamingLayerID = nil
        history.reset()
        commandInteraction = nil; opacityEditLayerID = nil
        if let archive = snapshot.history {
            func state(_ value: ProjectHistoryState) -> DocumentHistory.Snapshot {
                .init(document: value.project.map { project in
                    let temporary = EditorSession(); temporary.installProject(project, from: url); return temporary.document!
                }, activeLayerID: value.project?.manifest.activeLayerID, revision: value.revision)
            }
            history.restoreArchive(.init(past: archive.past.map { .init(name: $0.name, before: state($0.before), after: state($0.after)) },
                future: archive.future.map { .init(name: $0.name, before: state($0.before), after: state($0.after)) }, revision: archive.revision), saved: manifest.recoveryDocumentID == nil)
        }
        if manifest.recoveryDocumentID != nil { history.markUnsaved() }
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is loaded from the same validated atomic package as the current document.
    func reloadProject(_ snapshot: ProjectSnapshot) {
        guard let url = projectURL else { return }
        let viewport = self.viewport
        let collapsed = collapsedGroupIDs
        let active = activeLayerID
        let selected = selectedLayerIDs
        installProject(snapshot, from: url)
        self.viewport = viewport
        let ids = Set(snapshot.manifest.layers.map(\.id))
        collapsedGroupIDs = collapsed.intersection(ids)
        if let active, ids.contains(active) {
            activeLayerID = active
            selectedLayerIDs = selected.intersection(ids).union([active])
        }
    }

    func clearProject() {
        commandContextEpoch &+= 1
        commandInteraction = nil; opacityEditLayerID = nil
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        history.reset()
        commandInteraction = nil; opacityEditLayerID = nil
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }
}
