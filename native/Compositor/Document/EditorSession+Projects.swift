import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        do { return try Self.projectSnapshot(of: document, activeLayerID: activeLayerID) }
        catch { brushError=error.localizedDescription;return nil }
    }
    /// A document as a save writes it: the session's own, or a state undo history holds.
    static func projectSnapshot(of document: CanvasDocument, activeLayerID: UUID?) throws -> ProjectSnapshot {
        let charge=try LWSourceMetadataStorage.sum(4096,LWSourceMetadataStorage.collectionBytes(count:document.layers.count,
            stride:max(MemoryLayout<ImageLayer>.stride,MemoryLayout<ProjectLayerRecord>.stride)+256))
        let owner=try LWSourceMetadataStorage(bytes:charge,payloadOwners:document.metadataStorage?.payloadOwners ?? [])
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var coverages: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            if let coverage = layer.bakedCoverage { coverages[layer.id] = coverage }
            var record = ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString)." + (layer.asset?.linearPlane != nil ? "plane" : layer.asset?.linear == nil ? "png" : "f32"), parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask." + (layer.mask?.asset.linearPlane != nil ? "plane" : "png"), maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style, liveSource:layer.liveSource, planeArchiveReference:layer.asset?.planeArchiveReference,maskPlaneArchiveReference:layer.mask?.asset.planeArchiveReference)
            if let coverage = layer.bakedCoverage {
                record.coverageFile = record.planeFile(.coverage); record.coveragePlaneArchiveReference = coverage.planeArchiveReference
            }
            return record
        }
        let floating=images.values.contains(where:{$0.linear != nil || $0.linearPlane != nil})
        return ProjectSnapshot(manifest: ProjectManifest(workingSpace:floating ? "extended-linear-sRGB" : nil,
            workingSample:floating ? "float32-straight-RGBA" : nil,resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides:document.guides.isEmpty ? nil:document.guides,metadataStorage:owner),images:images,masks:masks,coverages:coverages)
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
        document = CanvasDocument(snapshot)
        activeLayerID = manifest.activeLayerID
        projectURL = url
        renamingLayerID = nil
        history.reset()
        adoptHistory(snapshot)
        commandInteraction = nil; opacityEditLayerID = nil
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is whatever the package on disk now holds, as
    /// after an open: steps made here and never saved do not survive someone else's rewrite of the document.
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
        historyAssets.reset(); historyUsage = nil; historyStorageWarning = nil; historyPruneNotice = nil; newerHistorySchema = nil
        siblingVersions = []; versionName = nil
        commandInteraction = nil; opacityEditLayerID = nil
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }
}

extension CanvasDocument {
    /// The document a loaded package (or a stored history state) describes.
    nonisolated init(_ snapshot: ProjectSnapshot) {
        let manifest = snapshot.manifest
        self.init(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map {
                ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                           isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                           shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                           effects: $0.effects,
                           text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image), liveSource:$0.liveSource,
                           bakedCoverage: snapshot.bakedCoverage(for: $0))
            }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        metadataStorage=manifest.metadataStorage
    }
}
