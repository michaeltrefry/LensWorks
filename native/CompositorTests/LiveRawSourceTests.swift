import Testing
import Foundation
import CoreGraphics
import CoreImage
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import Compositor

/// Deterministic mathematical fixtures. These do not qualify any camera decoder,
/// photographic color error budget, installed helper, or actual RAW file support.
@MainActor struct LiveRawSourceTests {
    private func surface(_ pixels:[SIMD4<Float>],width:Int=2) throws -> LWLinearSurface {
        try LWLinearSurface(width:width,height:pixels.count/width,pixels:pixels,maximumBytes:512*1024*1024)
    }
    private func node(original:URL,width:Int,height:Int,identity:LWCatalogPair<LWCatalogU64,LWCatalogU64>? = nil) throws -> LWLiveSourceNode {
        let revision=LWApplicationExportsDtoFileRevision(bytes:LWCatalogU64(4),digest:String(repeating:"0",count:64),
            modified_ns:try LWCatalogU128(decimal:"0"),identity:identity ?? .init(first:LWCatalogU64(1),second:LWCatalogU64(2)))
        let request=LWDocumentSourceDevelopment(original:try LWCatalogNativePath(fileURL:original),originalRevision:revision,whiteBalance:.AsShot,requestID:UUID())
        let metadata=LWMediaMetadata(format:"MATHEMATICAL_REFERENCE",width:UInt32(width),height:UInt32(height),orientation:1,
            camera_make:nil,camera_model:nil,captured_at:nil,lens:nil,preview_source:"not-used")
        let provenance=LWMediaFullRenderProvenance(pipeline_version:"mathematical-reference",decoder:"fixture-only",source_bits_per_channel:32,
            source_color:"extended_linear_srgb",working_color:"linear_srgb",alpha:"straight",calibration:nil,spatial_calibration:nil,notes:["No camera qualification"])
        func object<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:LWCatalogCodec.encode(value)) }
        let document:[String:Any]=["source_revision":LWManagedAuthority.sourceRevision,"protocol":2,"kind":"source_float",
            "mime":"application/x-lensworks-rgba-f32le","width":width,"height":height,"row_stride":String(width*16),
            "byte_length":String(width*height*16),"channels":4,"sample":"float32_le","color_space":"linear_srgb",
            "alpha":"straight","orientation":"applied","metadata":try object(metadata),"provenance":try object(provenance),
            "source_authority":try object(request),"memory_enforcement":"fixture" ]
        let descriptor=try LWCatalogCodec.decode(LWManagedSourceFloatDescriptor.self,from:JSONSerialization.data(withJSONObject:document))
        let value=try LWLiveSourceNode(original:try LWCatalogNativePath(fileURL:original),originalRevision:revision,descriptor:descriptor)
        // Fixture graph edits below admit their known small metadata growth before
        // construction. Production append APIs independently reserve each mutation.
        return try value.metadataCopy(additionalBytes:64*1024)
    }
    private func manifest(_ node:LWLiveSourceNode) -> ProjectManifest {
        let id=UUID()
        return ProjectManifest(documentID:UUID(),width:node.originalWidth,height:node.originalHeight,activeLayerID:id,layers:[
            ProjectLayerRecord(id:id,name:"Live reference",isVisible:true,transform:LayerTransform(origin:.zero,size:CGSize(width:node.originalWidth,height:node.originalHeight)),imageFile:id.uuidString+".f32",liveSource:node)])
    }
    @Test(arguments: ["source", "phase", "missing", "unknown"])
    func refusedSourceSessionAdmissionRetainsItsExactReturnedOwner(_ fault: String) throws {
        var fields: [String: Any] = ["session": "18446744073709551614", "phase": "ready",
            "source_revision": LWManagedAuthority.sourceRevision]
        switch fault {
        case "source": fields["source_revision"] = String(repeating: "0", count: 64)
        case "phase": fields["phase"] = "not-a-phase"
        case "missing": fields.removeValue(forKey: "source_revision")
        default: fields["unapproved"] = true
        }
        do {
            _ = try LWCatalogCodec.decode(LWManagedSourceSessionAdmission.self, from: JSONSerialization.data(withJSONObject: fields))
            Issue.record("Refused source session header was accepted.")
        } catch let refused as LWManagedSourceAdmissionFailure {
            #expect(refused.owner.handle.value == 18446744073709551614)
            #expect(refused.owner.sourceRevision.isEmpty)
            #expect(!(refused.reason is LWManagedSourceAdmissionFailure))
        }
        // This is descriptor/strong-owner custody only. The deliberately invalid
        // handle owns no actual child and grants no runtime cleanup acceptance.
    }

    @Test func floatPackagePreservesEveryBitIncludingLatitudeAndHiddenColor() throws {
        let input=try surface([SIMD4(-0.25,4,0.0000001,1),SIMD4(10,-2,3,0)])
        let packed=try input.packageData(maximumFileBytes:1024)
        let reopened=try LWLinearSurface.package(packed,maximumFileBytes:1024)
        for i in input.pixels.indices { for c in 0..<4 { #expect(reopened.pixels[i][c].bitPattern == input.pixels[i][c].bitPattern) } }
    }
    @Test(arguments:[Float.nan,Float.infinity,-Float.infinity])
    func nonfiniteWorkingRGBIsRefused(_ value:Float) throws {
        #expect(throws:Error.self) { try surface([SIMD4(value,0,0,1),SIMD4.zero]) }
    }
    @Test(arguments:[Float(-0.01),Float(1.01)])
    func invalidAlphaIsRefused(_ alpha:Float) throws {
        #expect(throws:Error.self) { try surface([SIMD4(0,0,0,alpha),SIMD4.zero]) }
    }
    @Test func extentAdmissionPrecedesSurfaceAllocation() {
        #expect(throws:Error.self) { try LWLinearSurface.extent(width:Int.max,height:2,maximumBytes:1024) }
        #expect(throws:Error.self) { try LWLinearSurface.extent(width:2,height:2,maximumBytes:63) }
    }
    @Test func packageShortReadAndForgedExtentAreRefused() throws {
        var data=try surface([SIMD4(0,1,2,1),SIMD4(3,4,5,1)]).packageData(maximumFileBytes:1024)
        #expect(throws:Error.self) { try LWLinearSurface.package(Data(data.dropLast()),maximumFileBytes:1024) }
        data[16]=0
        #expect(throws:Error.self) { try LWLinearSurface.package(data,maximumFileBytes:1024) }
    }
    @Test func sourceArchiveExternalizesOwnedBackingAndHydratesExactSemantics() throws {
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        let coverage=try surface([SIMD4(0,0,0,0.25),SIMD4(0,0,0,0.75)]).packageData(maximumFileBytes:1024)
        source.selectedDevelopments=[.init(settings:CameraRawSettings(),whiteBalance:.asShot,seed:17,sourceCoverage:coverage)]
        let original=manifest(source),packed=try LWSourcePackageArchive.externalize(original,maximumBytes:65536)
        #expect(packed.manifest.layers[0].liveSource == nil)
        #expect(packed.assets.values.contains(coverage))
        let hydrated=try LWSourcePackageArchive.hydrate(packed.manifest) { name,maximum in
            let data=try #require(packed.assets[name]);#expect(data.count <= maximum);return data
        }
        #expect(hydrated.layers[0].liveSource == source)
        #expect(hydrated.layers[0].liveSourceFile == nil)
    }
    @Test func sourceArchiveBindsWholeBackingsAndMetadataToContent() throws {
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        source.selectedDevelopments=[.init(settings:CameraRawSettings(),whiteBalance:.asShot,seed:0,
            sourceCoverage:try surface([SIMD4(0,0,0,1),SIMD4.zero]).packageData(maximumFileBytes:1024))]
        let packed=try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:65536)
        for target in packed.assets.keys {
            #expect(throws:Error.self) { try LWSourcePackageArchive.hydrate(packed.manifest) { name,_ in
                var bytes=try #require(packed.assets[name]);if name == target { bytes[bytes.count-1] ^= 1 };return bytes
            } }
        }
    }
    @Test func historySourceReferenceChangesWhenSemanticBackingChanges() throws {
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        let before=try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:65536)
        source.grainSeed=1 // Keep node UUID/revision deliberately unchanged: semantic corruption must still differ.
        let after=try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:65536)
        #expect(before.manifest.layers[0].liveSourceFile != after.manifest.layers[0].liveSourceFile)
    }
    @Test func regularMappingAbsenceIsNotAnInvalidTransform() throws {
        let map=LWSourceSpatialMap(geometry:.identity,optics:CameraRawOpticsSettings(),width:2,height:2)
        #expect(try map.developedPointIfInBounds(CGPoint(x:3,y:1)) == nil)
        #expect(try map.developedPointIfInBounds(CGPoint(x:1,y:1)) == CGPoint(x:1,y:1))
        #expect(throws:Error.self) { try map.developedPointIfInBounds(CGPoint(x:Double.nan,y:1)) }
    }
    @Test func captureFrameKeepsDocumentTipUnderNonuniformLayerPlacement() throws {
        let frame=LWSourceRetouchFrame(geometry:.identity,optics:CameraRawOpticsSettings(),width:2,height:2,
            layerTransform:LayerTransform(origin:CGPoint(x:10,y:20),size:CGSize(width:8,height:2)))
        let source=CGPoint(x:0.5,y:1.5),document=try frame.documentPoint(source)
        #expect(try frame.sourcePoint(document) == source)
        #expect(document == CGPoint(x:12,y:21.5))
    }

    @Test func blurSigmaUsesCapturedLayerGridAndRetainsTinyExtentFraction() throws {
        let frame=LWSourceRetouchFrame(geometry:.identity,optics:CameraRawOpticsSettings(),width:1,height:1,
            layerTransform:LayerTransform(origin:.zero,size:CGSize(width:1,height:1)))
        #expect(try frame.retainedBlurSigma(blurRadius:10) == 0.5)
        let scaled=LWSourceRetouchFrame(geometry:.identity,optics:CameraRawOpticsSettings(),width:4,height:4,
            layerTransform:LayerTransform(origin:CGPoint(x:7,y:9),size:CGSize(width:8,height:8)))
        #expect(try scaled.retainedBlurSigma(blurRadius:2) == 1)
        #expect(try scaled.documentToDevelopedPixel(scaled.developedPixelToDocument(CGPoint(x:1,y:2))) == CGPoint(x:1,y:2))
    }
    @Test func transientDiagnosticsKeepWorkingPixelsAndAlphaUnchanged() throws {
        let original=try surface([SIMD4(-0.1,2,0.25,0.5),SIMD4(9,8,7,0)])
        let exact=try original.packageData(maximumFileBytes:1024)
        let shown=try LWCameraRawDiagnostics.preview(original,settings:CameraRawSettings(),clipping:.highlights,
            shadows:false,highlights:false,point:-1,sharpenMask:false)
        #expect(shown.pixels[0].x == 0 && shown.pixels[0].y == 1 && shown.pixels[0].z == 0)
        #expect(shown.pixels[0].w == original.pixels[0].w)
        #expect(shown.pixels[1] == original.pixels[1])
        #expect(try original.packageData(maximumFileBytes:1024) == exact)
    }
    @Test func sourceArchiveRejectsNonfiniteBackingBeforePackagePublication() throws {
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        var coverage=try surface([SIMD4(0,0,0,1),SIMD4.zero]).packageData(maximumFileBytes:1024)
        // First RGB word: quiet NaN; header and byte extent remain otherwise valid.
        coverage.replaceSubrange(24..<28,with:[0,0,192,127])
        source.selectedDevelopments=[.init(settings:CameraRawSettings(),whiteBalance:.asShot,seed:0,sourceCoverage:coverage)]
        #expect(throws:Error.self) { try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:65536) }
    }
    private func temporaryProjectFolder() throws -> URL {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("LWLiveSourceTests-\(UUID())")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        return folder.resolvingSymlinksInPath()
    }
    @Test func projectSaveReopenPreservesLiveGraphFloatBitsAndProtectedOriginal() async throws {
        let root=try temporaryProjectFolder();defer { try? FileManager.default.removeItem(at:root) }
        let original=root.appendingPathComponent("protected.mathematical-reference")
        let sourceBytes=Data([17,23,51,99]);try sourceBytes.write(to:original,options:.withoutOverwriting)
        let source=try node(original:original,width:2,height:1)
        let pixels=try surface([SIMD4(-0.5,4,2,1),SIMD4(0.1,0.2,0.3,0.5)])
        var document=manifest(source);document.workingSpace="extended-linear-sRGB";document.workingSample="float32-straight-RGBA"
        let id=try #require(document.activeLayerID)
        let snapshot=ProjectSnapshot(manifest:document,images:[id:try ImportedImage(linear:pixels,name:"Reference")])
        let file=root.appendingPathComponent("Live.comp")
        try await ProjectStore.shared.save(snapshot,to:file)
        let reopened=try await ProjectStore.shared.load(from:file)
        #expect(reopened.manifest.version == ProjectManifest.float)
        #expect(reopened.manifest.workingSpace == "extended-linear-sRGB")
        #expect(reopened.manifest.workingSample == "float32-straight-RGBA")
        #expect(reopened.manifest.layers[0].liveSource == source)
        let loaded=try #require(reopened.images[id]?.linearPlane).read(LWFloatRange(x:0,y:0,width:2,height:1)).surface
        #expect(Array(loaded.pixels) == pixels.pixels)
        #expect(reopened.manifest.layers[0].imageFile == id.uuidString+".plane")
        #expect(try Data(contentsOf:original) == sourceBytes)
    }
    @Test func floatImageProviderReadsUnalignedGlobalRangesAndRetainsCompleteExtent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let plane = try referencePlane(root, workingSet: LWFloatWorkingSet())
        let provider = LWFloatPlaneImage(plane: plane)
        let image = try provider.image()
        #expect(image.width == 513 && image.height == 259 && image.bitsPerComponent == 32)
        let start = (plane.width * 256 + 255) * 16 + 3
        var bytes = Data(count: 77)
        let copied = try bytes.withUnsafeMutableBytes { raw in
            try provider.copy(into: raw.baseAddress!, position: off_t(start), count: raw.count)
        }
        let reference = try plane.read(range: .init(x: 255, y: 256, width: 5, height: 1))
        var expected = Data()
        for pixel in reference.surface.pixels {
            var premultiplied = SIMD4(pixel.x * pixel.w, pixel.y * pixel.w, pixel.z * pixel.w, pixel.w)
            withUnsafeBytes(of: &premultiplied) { expected.append(contentsOf: $0) }
        }
        #expect(copied == 77 && bytes == expected.subdata(in: 3..<80))
        #expect(throws: Error.self) {
            try bytes.withUnsafeMutableBytes { raw in try provider.copy(into: raw.baseAddress!, position: -1, count: 1) }
        }
        try provider.check()
    }
    @Test func workspaceRetainsBackingThroughImmutableReaderLifetime() throws {
        var workspace: LWFloatWorkspace? = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        let directory = try #require(workspace).directory
        func makeSnapshot(_ workspace: LWFloatWorkspace) throws -> LWTypedStateStore.Snapshot {
            let store = try workspace.makeStateStore(format: .uint32, width: 2, height: 1)
            try store.write(.uint32(17), x: 1, y: 0)
            return try store.commit()
        }
        var snapshot: LWTypedStateStore.Snapshot? = try makeSnapshot(#require(workspace))
        var reader: LWTypedStateStore.Reader? = try #require(snapshot).reader()
        workspace = nil; snapshot = nil
        #expect(FileManager.default.fileExists(atPath: directory.path))
        let value = try #require(reader).read(x: 1, y: 0)
        if case .uint32(let word) = value { #expect(word == 17) } else { Issue.record("Typed role grid changed its representation") }
        reader = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func planeArchiveReopensExactPrivateBitsAndRejectsChangedManifest() throws {
        let root = try temporaryProjectFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let budget = try LWFloatWorkingSet(limit: 32 * 1024 * 1024)
        let plane = try referencePlane(root, workingSet: budget)
        let archive = try privateTileFolder(root, "Layer.plane")
        let reference = try LWFloatPlaneArchive.write(plane, to: archive)
        let workspace = try LWFloatWorkspace(workingSet: budget)
        let reopened = try LWFloatPlaneArchive.read(from: archive, reference: reference, workspace: workspace)
        #expect(reopened.manifest == plane.manifest)
        let range = LWFloatRange(x: 254, y: 254, width: 7, height: 5)
        let before = try plane.read(range), after = try reopened.read(range)
        for index in before.surface.pixels.indices { for channel in 0..<4 {
            #expect(before.surface.pixels[index][channel].bitPattern == after.surface.pixels[index][channel].bitPattern)
        } }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plane.manifest))
        var document = try #require(object as? [String: Any])
        document["unadmitted"] = true
        #expect(throws: Error.self) { try JSONDecoder().decode(LWFloatPlane.Manifest.self, from: JSONSerialization.data(withJSONObject: document)) }
        let manifest = archive.appendingPathComponent("manifest.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        var changed = try Data(contentsOf: manifest); changed[changed.count - 1] ^= 1
        try changed.write(to: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: manifest.path)
        #expect(throws: Error.self) { try LWFloatPlaneArchive.read(from: archive, reference: reference, workspace: workspace) }
        // The admitted graph-owned generation survives later package mutation.
        let retained = try reopened.read(range)
        #expect(retained.surface.pixels == after.surface.pixels)
    }
    @Test(arguments: LayerBlendMode.allCases)
    func tiledBlendUsesTheSameWholeReferenceOperatorAcrossTheSeam(_ mode: LayerBlendMode) throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        let width = 257, height = 2
        let topValues: [SIMD4<Float>] = (0..<width * height).map { (index: Int) -> SIMD4<Float> in
            let red: Float = Float(index % 7) / 4 - 0.25
            let alpha: Float = index % 3 == 0 ? 0 : 0.5
            return SIMD4<Float>(red, 1.5, 0.125, alpha)
        }
        let bottomValues: [SIMD4<Float>] = (0..<width * height).map { (index: Int) -> SIMD4<Float> in
            SIMD4<Float>(0.25, Float(index % 5) / 8, 0.75, 1)
        }
        func plane(_ values: [SIMD4<Float>]) throws -> LWFloatPlane {
            let builder = try workspace.makeBuilder(width: width, height: height)
            while let range = builder.nextRange {
                var pixels = [SIMD4<Float>]()
                for y in range.y..<range.y + range.height { for x in range.x..<range.x + range.width {
                    pixels.append(values[y * width + x])
                } }
                try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels,
                    maximumBytes: range.width * range.height * 16), at: range)
            }
            return try builder.finish()
        }
        let reference = try LWFloatCompositor.blend(surface(topValues, width: width),
            over: surface(bottomValues, width: width), mode: mode)
        let actual = try LWFloatCompositor.blend(plane(topValues), over: plane(bottomValues), mode: mode, workspace: workspace)
        let readback = try actual.read(range: actual.globalExtent)
        for index in reference.pixels.indices { for channel in 0..<4 {
            #expect(readback.surface.pixels[index][channel].bitPattern == reference.pixels[index][channel].bitPattern)
        } }
    }
    private func privateTileFolder(_ parent: URL, _ name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func referencePlane(_ parent: URL, workingSet: LWFloatWorkingSet) throws -> LWFloatPlane {
        let builder = try LWFloatPlane.Builder(directory: privateTileFolder(parent, "ReferenceTiles"),
            width: 513, height: 259, workingSet: workingSet)
        while let range = builder.nextRange {
            var values = [SIMD4<Float>](); values.reserveCapacity(range.width * range.height)
            for y in range.y..<range.y + range.height { for x in range.x..<range.x + range.width {
                values.append(SIMD4(Float(x) / 32 - 2, Float(y) / 16, 4, (x + y) % 3 == 0 ? 0 : 0.5))
            } }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: values,
                maximumBytes: range.width * range.height * 16), at: range)
        }
        return try builder.finish()
    }
    @Test func tiledPlaneReadsAcrossNondivisibleBoundariesWithoutHDRQuantization() throws {
        let root = try temporaryProjectFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let budget = try LWFloatWorkingSet(limit: 32 * 1024 * 1024)
        let plane = try referencePlane(root, workingSet: budget)
        let range = LWFloatRange(x: 254, y: 254, width: 7, height: 5)
        let tile = try plane.read(range)
        #expect(tile.range == range && tile.frameWidth == 513 && tile.frameHeight == 259)
        for y in 0..<range.height { for x in 0..<range.width {
            let gx = range.x + x, gy = range.y + y
            #expect(tile.surface.pixels[y * range.width + x] == SIMD4(Float(gx) / 32 - 2, Float(gy) / 16, 4, (gx + gy) % 3 == 0 ? 0 : 0.5))
        } }
        #expect(try range.expanded(halo: 8, frameWidth: 513, frameHeight: 259) == LWFloatRange(x: 246, y: 246, width: 23, height: 13))
        #expect(throws: Error.self) { try range.expanded(halo: Int.max, frameWidth: 513, frameHeight: 259) }
        try LWFloatPlane.validateExtent(width: 8000, height: 6250) // Full 50 MP extent, no allocation.
        #expect(throws: Error.self) { try LWLinearSurface.extent(width: 8000, height: 6250, maximumBytes: LWFloatWorkingSet.maximumBytes) }
    }
    @Test func tiledPlaneRejectsChangedOrLinkedBackingAndKeepsPremultipliedSampling() throws {
        let root = try temporaryProjectFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let budget = try LWFloatWorkingSet(limit: 32 * 1024 * 1024)
        let plane = try referencePlane(root, workingSet: budget)
        let sampler = plane.sampler()
        let value = try sampler.sample(CGPoint(x: 0.5, y: 0.5))
        #expect(value == .zero) // Hidden HDR RGB of a transparent input is not leaked by interpolation.
        let file = root.appendingPathComponent("ReferenceTiles/00000000.f32")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var changed = try Data(contentsOf: file); changed[0] ^= 1; try changed.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(throws: Error.self) { try plane.read(LWFloatRange(x: 0, y: 0, width: 1, height: 1)) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("outside.f32"))
        #expect(throws: Error.self) { try plane.read(LWFloatRange(x: 0, y: 0, width: 1, height: 1)) }
    }
    @Test func typedScratchCommitsImmutableGlobalGenerationsAndRetainsDoublePrecision() throws {
        let root = try temporaryProjectFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let budget = try LWFloatWorkingSet(limit: 32 * 1024 * 1024)
        let first = try LWTypedStateStore(format: .float64, width: 513, height: 259,
            directory: privateTileFolder(root, "FirstState"), workingSet: budget)
        let exact = 1.0 + Double.ulpOfOne
        try first.write(.float64(exact), x: 256, y: 258)
        let before = try first.commit()
        #expect(before.capacityBytes == 513 * 259 * 8 && before.recordStride == 8 && before.schema == 1)
        let next = try LWTypedStateStore(format: .float64, width: 513, height: 259,
            directory: privateTileFolder(root, "NextState"), workingSet: budget, base: before)
        try next.write(.float64(7), x: 256, y: 258)
        let after = try next.commit()
        guard case .float64(let oldValue) = try before.reader().read(x: 256, y: 258),
            case .float64(let newValue) = try after.reader().read(x: 256, y: 258) else { Issue.record("Typed scratch format changed"); return }
        #expect(oldValue == exact && newValue == 7 && before.sha256 != after.sha256)
        #expect(throws: Error.self) { try first.write(.float64(8), x: 0, y: 0) }
        let roles = try LWTypedStateStore(format: .uint32, width: 2, height: 1,
            directory: privateTileFolder(root, "Roles"), workingSet: budget)
        try roles.write(.uint32(UInt32.max), x: 1, y: 0)
        guard case .uint32(let role) = try roles.commit().reader().read(x: 1, y: 0) else { Issue.record("Role precision changed"); return }
        #expect(role == UInt32.max)
    }

}

extension LiveRawSourceTests {
    @Test func workspaceRefusesUnexpectedSentinelBeforeDeletingRegisteredPixels() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        defer { try? FileManager.default.removeItem(at: workspace.directory) }
        var plane: LWFloatPlane? = try tiledFixture([SIMD4(2,-0.5,0.25,1)], width: 1, workspace: workspace)
        let child = try #require(FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil).first)
        let sentinel = child.appendingPathComponent("unexpected.txt"), bytes = Data("must survive".utf8)
        try bytes.write(to: sentinel, options: .withoutOverwriting)
        expectInvalid { _ = try workspace.retireOwnedPlane(&plane) }
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try #require(plane).read(range: .init(x:0,y:0,width:1,height:1)).surface.pixels == [SIMD4(2,-0.5,0.25,1)])
        try FileManager.default.removeItem(at: sentinel)
        #expect(try workspace.retireOwnedPlane(&plane))
        try workspace.retireOwnedChildren()
    }
    @Test func workspaceRefusesSameBytesReplacementInode() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        defer { try? FileManager.default.removeItem(at: workspace.directory) }
        var plane: LWFloatPlane? = try tiledFixture([SIMD4(1,2,3,1)], width:1, workspace:workspace)
        let child = try #require(FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil).first)
        let file = child.appendingPathComponent("00000000.f32"), bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try bytes.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        expectInvalid { _ = try workspace.retireOwnedPlane(&plane) }
        #expect(plane != nil && FileManager.default.fileExists(atPath: file.path))
    }
    @Test func registeredPartialFailureWaitsForItsWriterThenRetiresExactMember() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet()), child = try workspace.makeScratchDirectory()
        var lifetime: LWFloatWorkspace.ChildLifetime? = try workspace.retainChild(child)
        let chain = try LWFloatDirectoryChain(child)
        var descriptor = openat(chain.fd, "partial.f32", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProjectError.invalid }; defer { if descriptor >= 0 { close(descriptor) } }
        try workspace.registerCreatedFile(directory: child, name: "partial.f32", descriptor: descriptor)
        let bytes = Data([1,2,3]); #expect(bytes.withUnsafeBytes { Darwin.write(descriptor,$0.baseAddress!,$0.count) } == 3)
        try workspace.captureWrittenFile(directory: child, name: "partial.f32", descriptor: descriptor)
        expectInvalid { try workspace.retireOwnedChildren() }
        let old = descriptor; #expect(close(descriptor) == 0); descriptor = -1; lifetime = nil
        try workspace.retireOwnedChildren()
        var after = stat(); #expect(fstat(old,&after) != 0 && errno == EBADF)
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
        withExtendedLifetime(lifetime) {}
    }
    @Test func uncapturedPartialWritePreservesNamedUncertaintyAfterWriterRelease() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet()), child = try workspace.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace.directory) }
        var lifetime: LWFloatWorkspace.ChildLifetime? = try workspace.retainChild(child)
        let chain = try LWFloatDirectoryChain(child)
        let descriptor = openat(chain.fd,"partial.f32",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw ProjectError.invalid }
        try workspace.registerCreatedFile(directory:child,name:"partial.f32",descriptor:descriptor)
        let bytes=Data([1,2,3]);#expect(bytes.withUnsafeBytes { Darwin.write(descriptor,$0.baseAddress!,$0.count) } == 3)
        // Simulate final capture failing: the registered empty hash must not be
        // relabeled as these bytes, even after every actual reader/writer is gone.
        #expect(close(descriptor)==0);lifetime=nil
        expectInvalid { try workspace.retireOwnedChildren() }
        #expect(try Data(contentsOf:child.appendingPathComponent("partial.f32"))==bytes)
        withExtendedLifetime(lifetime) {}
    }
    @Test func providerCallbackFailureStaysStickyAndExplicitCancellationNeedsNoTaskInheritance() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        defer { try? FileManager.default.removeItem(at:workspace.directory) }
        let builder = try workspace.makeBuilder(width: 1, height: 1)
        try builder.append(surface([SIMD4(2, -1, 0.5, 1)], width: 1), at: .init(x: 0, y: 0, width: 1, height: 1))
        let plane = try builder.finish(), provider = LWFloatPlaneImage(plane: plane), image = try provider.image()
        let children = try FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil)
        let child = try #require(children.first), file = child.appendingPathComponent("00000000.f32")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var changed = bytes; changed[0] ^= 1; try changed.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        // CopyData invokes the actual framework callback and its sticky error path.
        _ = image.dataProvider?.data
        #expect(throws: Error.self) { try provider.check() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let restored = try plane.read(range: plane.globalExtent)
        #expect(restored.surface.pixels == [SIMD4(2, -1, 0.5, 1)])
        #expect(throws: Error.self) { try provider.check() }
        let independent = LWFloatPlaneImage(plane: plane)
        workspace.cancellation.cancel()
        #expect(throws: CancellationError.self) { try independent.check() }
        #expect(throws: CancellationError.self) { try independent.image() }
    }
}

extension LiveRawSourceTests {
    @Test func streamedPNGPublishesComplete16BitFileAndPreservesPriorOutputOnSourceFailure() async throws {
        let root=try temporaryProjectFolder();defer { try? FileManager.default.removeItem(at:root) }
        let budget=LWFloatWorkingSet.sourceGraphs,plane=try referencePlane(root,workingSet:budget)
        let id=UUID(),asset=try ImportedImage(plane:plane,name:"Reference")
        let manifest=ProjectManifest(documentID:UUID(),width:plane.width,height:plane.height,activeLayerID:id,layers:[
            ProjectLayerRecord(id:id,name:"Reference",isVisible:true,transform:LayerTransform(origin:.zero,size:CGSize(width:plane.width,height:plane.height)),
                imageFile:id.uuidString+".plane",planeArchiveReference:asset.planeArchiveReference)])
        let snapshot=ProjectSnapshot(manifest:manifest,images:[id:asset]),destination=root.appendingPathComponent("export.png")
        try await ImageExporter.shared.exportPNG(snapshot,to:destination)
        let original=try Data(contentsOf:destination)
        let source=try #require(CGImageSourceCreateWithURL(destination as CFURL,nil))
        let decoded=try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
        #expect(decoded.width==513 && decoded.height==259 && decoded.bitsPerComponent==16)
        // Fail the actual range provider after a valid published file exists.
        let tile=root.appendingPathComponent("ReferenceTiles/00000000.f32")
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:tile.path)
        var bytes=try Data(contentsOf:tile);bytes[0] ^= 1;try bytes.write(to:tile)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:tile.path)
        await #expect(throws:Error.self) { try await ImageExporter.shared.exportPNG(snapshot,to:destination) }
        #expect(try Data(contentsOf:destination)==original)
    }
    @Test func streamedCodecIdentityRejectsReplacementAndRetainsDataLease() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:4*1024*1024))
        defer { try? FileManager.default.removeItem(at:workspace.directory) }
        let file=try LWEncodedImageFile(workspace:workspace),consumer=try file.consumer()
        let image=try surface([SIMD4(0.25,0.5,0.75,1),SIMD4(1,0,0,0.5)]).integerOutput(bits:16,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        let destination=try #require(CGImageDestinationCreateWithDataConsumer(consumer,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);#expect(CGImageDestinationFinalize(destination))
        try file.finish(validate:{})
        let bytes=try file.data();#expect(bytes.count==file.byteCount && bytes.count>0 && file.sha256.count==64)
        try FileManager.default.moveItem(at:file.url,to:file.directory.appendingPathComponent("displaced"))
        try bytes.write(to:file.url,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:file.url.path)
        #expect(throws:Error.self) { try file.check() }
        #expect(throws:Error.self) { try file.data() }
        #expect(throws:Error.self) { try workspace.retireOwnedChildren() }
        #expect(try Data(contentsOf:file.url)==bytes)
    }
    @Test func tiledMaskPlacementAndLinkedIdentityReconcileKeepIntrinsicCoverage() throws {
        let root=try temporaryProjectFolder();defer { try? FileManager.default.removeItem(at:root) }
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs),builder=try workspace.makeBuilder(width:257,height:3)
        while let range=builder.nextRange {
            let pixels=(0..<range.width*range.height).map { i -> SIMD4<Float> in
                let x=range.x+i%range.width;return SIMD4(repeating:Float(x%256)/255)
            }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:pixels,maximumBytes:range.width*range.height*16),at:range)
        }
        let plane=try builder.finish(),asset=try ImportedImage(maskPlane:plane,name:"Mask"),mask=LayerMask(asset:asset)
        let source=try node(original:root.appendingPathComponent("fixture.dng"),width:257,height:3)
        let transform=LayerTransform(origin:CGPoint(x:13,y:19),size:CGSize(width:514,height:6))
        let made=try #require(try LWSourceMaskReconcile.reconcilePlane(mask,previous:source,
            next:LWSourceSpatialMap(geometry:.identity,optics:CameraRawOpticsSettings(),width:257,height:3),transform:transform,workspace:workspace))
        let output=try #require(made.asset.linearPlane),actual=try output.read(range:.init(x:254,y:1,width:3,height:1))
        #expect(actual.surface.pixels.map(\.x)==[Float(254)/255,1,0])
        #expect(made.isEnabled && made.isLinked && made.placement==nil && made.asset.planeArchiveReference != nil)
        var unlinked=mask;unlinked.isLinked=false
        let retained=try #require(try LWSourceMaskReconcile.reconcilePlane(unlinked,previous:source,
            next:LWSourceSpatialMap(geometry:.identity,optics:CameraRawOpticsSettings(),width:257,height:3),transform:transform,workspace:workspace))
        #expect(retained.asset.image === asset.image)
    }
}

extension LiveRawSourceTests {
    private func ownedOnePixel(_ workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let builder = try workspace.makeBuilder(width: 1, height: 1)
        try builder.append(surface([SIMD4(3, -1, 0.5, 1)], width: 1), at: .init(x: 0, y: 0, width: 1, height: 1))
        return try builder.finish()
    }
    @Test func checkedPlaneRetirementWaitsForSamplerAndHistoricalValue() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var plane: LWFloatPlane? = try ownedOnePixel(workspace)
        var history = plane, reader = plane?.sampler()
        #expect(try workspace.retireOwnedPlane(&plane) == false && plane != nil)
        #expect(try reader?.pixel(x: 0, y: 0) == SIMD4(3, -1, 0.5, 1))
        history = nil
        #expect(try workspace.retireOwnedPlane(&plane) == false)
        reader = nil
        #expect(try workspace.retireOwnedPlane(&plane) && plane == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).isEmpty)
        withExtendedLifetime(history) {}
    }
    @Test func checkedPlaneRetirementPreservesUnexpectedMemberAndOtherGeneration() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        defer { try? FileManager.default.removeItem(at: workspace.directory) }
        var first: LWFloatPlane? = try ownedOnePixel(workspace)
        let other = try ownedOnePixel(workspace)
        let children = try FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil)
        // Insert into both children so no ordering assumption can make the test vacuous.
        for child in children { try Data([7]).write(to: child.appendingPathComponent("unowned-sentinel"), options: .withoutOverwriting) }
        #expect(throws: Error.self) { _ = try workspace.retireOwnedPlane(&first) }
        let otherRed = try other.read(other.globalExtent).surface.pixels[0].x
        #expect(first != nil && otherRed == 3)
        for child in children { #expect(try Data(contentsOf: child.appendingPathComponent("unowned-sentinel")) == Data([7])) }
    }
}


extension LiveRawSourceTests {
    @Test func independentPlaneOpenRetainsTheSameOwnedGeneration() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var plane: LWFloatPlane? = try ownedOnePixel(workspace)
        let child = try #require(FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil).first)
        var reopened: LWFloatPlane? = try LWFloatPlane.open(directory: child,
            manifest: try #require(plane).manifest, workingSet: workspace.workingSet)
        #expect(try workspace.retireOwnedPlane(&plane) == false)
        #expect(try reopened?.sampler().pixel(x: 0, y: 0) == SIMD4(3, -1, 0.5, 1))
        reopened = nil
        #expect(try workspace.retireOwnedPlane(&plane) && plane == nil)
        #expect(!FileManager.default.fileExists(atPath: child.path))
    }
    @Test func longPlaneReplacementRetainsOnlyThePublishedSuccessor() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var current: LWFloatPlane? = try ownedOnePixel(workspace)
        for _ in 0..<96 {
            // The successor is complete before predecessor deletion is attempted.
            let next = try ownedOnePixel(workspace)
            #expect(try workspace.retireOwnedPlane(&current))
            current = next
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).count == 1)
            #expect(try current?.sampler().pixel(x: 0, y: 0) == SIMD4(3, -1, 0.5, 1))
        }
        #expect(try workspace.retireOwnedPlane(&current))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).isEmpty)
    }
}


extension LiveRawSourceTests {
    @Test func explicitWorkspaceRetirementRefusesLivePlaneAndProvider() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var plane: LWFloatPlane? = try ownedOnePixel(workspace)
        var provider: LWFloatPlaneImage? = LWFloatPlaneImage(plane: try #require(plane), cancellation: workspace.cancellation)
        var image: CGImage? = try provider?.image()
        plane = nil
        #expect(throws: Error.self) { try workspace.retireOwnedChildren() }
        provider = nil
        // The CGDataProvider context retains its plane even after the adapter is gone.
        #expect(throws: Error.self) { try workspace.retireOwnedChildren() }
        image = nil
        try workspace.retireOwnedChildren()
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
        withExtendedLifetime(image) {}
    }
}


extension LiveRawSourceTests {
    @Test func workspaceCleanupWaitsForTypedSnapshotReaderAndCodecOwner() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var store: LWTypedStateStore? = try workspace.makeStateStore(format: .uint32, width: 1, height: 1)
        try store?.write(.uint32(7), x: 0, y: 0)
        var snapshot: LWTypedStateStore.Snapshot? = try store?.commit()
        var reader: LWTypedStateStore.Reader? = snapshot?.reader()
        var codec: LWEncodedImageFile? = try LWEncodedImageFile(workspace: workspace)
        store = nil; snapshot = nil
        #expect(throws: Error.self) { try workspace.retireOwnedChildren() }
        let read = try #require(try reader?.read(x: 0, y: 0))
        if case .uint32(let value) = read { #expect(value == 7) } else { Issue.record("Wrong typed reader format") }
        reader = nil
        #expect(throws: Error.self) { try workspace.retireOwnedChildren() }
        codec = nil
        try workspace.retireOwnedChildren()
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
        withExtendedLifetime(codec) {}
    }
    @Test func workspaceCleanupWaitsForF64GlobalReader() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var field: LWFloatDoubleRows? = try LWFloatDoubleRows.create(width: 2, height: 1,
            workingSet: workspace.workingSet, directory: workspace.makeScratchDirectory(), fileOwner: workspace) { _ in [0.1, 3.141592653589793] }
        var reader: LWFloatDoubleRows.Reader? = LWFloatDoubleRows.Reader(try #require(field))
        field = nil
        #expect(throws: Error.self) { try workspace.retireOwnedChildren() }
        #expect(try reader?.row(0).values[1].bitPattern == Double.pi.bitPattern)
        reader = nil
        try workspace.retireOwnedChildren()
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    }
}


extension LiveRawSourceTests {
    /// Straight source-over in extended (sign-mirrored) encoded sRGB, returned as straight linear.
    static func encodedSourceOver(_ top:SIMD4<Float>,over bottom:SIMD4<Float>)->SIMD4<Float> {
        func encode(_ v:Double)->Double { let a=abs(v);let e=a <= 0.0031308 ? 12.92*a:1.055*pow(a,1/2.4)-0.055;return v<0 ? -e:e }
        func decode(_ v:Double)->Double { let a=abs(v);let d=a <= 0.04045 ? a/12.92:pow((a+0.055)/1.055,2.4);return v<0 ? -d:d }
        let ta=Double(top.w),ba=Double(bottom.w),alpha=ta+ba*(1-ta)
        guard alpha>0 else { return .zero }
        var out=SIMD4<Float>(0,0,0,Float(alpha))
        for c in 0..<3 { out[c]=Float(decode((encode(Double(top[c]))*ta+encode(Double(bottom[c]))*ba*(1-ta))/alpha)) }
        return out
    }
    private func expectInvalid(_ operation: () throws -> Void) {
        do { try operation(); Issue.record("Invalid owned-custody operation was accepted") }
        catch {
            guard let problem = error as? ProjectError, case .invalid = problem else {
                Issue.record("Unexpected refusal instead of owned-custody invalid: \(error)"); return
            }
        }
    }
    private func tiledFixture(_ values: [SIMD4<Float>], width: Int, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let height = values.count / width, builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            let pixels = (range.y..<range.y + range.height).flatMap { y in
                (range.x..<range.x + range.width).map { values[y * width + $0] }
            }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels,
                maximumBytes: range.width * range.height * 16), at: range)
        }
        return try builder.finish()
    }
    @Test(arguments: FilterKind.allCases.filter { $0 != .cameraRaw && $0 != .removeBackground })
    func retainedMenuFilterDispatchKeepsImmutableHDRSourceAndTypedPlane(_ kind: FilterKind) throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        let values: [SIMD4<Float>] = (0..<64).map { (i: Int) -> SIMD4<Float> in
            let red: Float = Float(i % 8) / 2 - 0.5, green: Float = Float(i / 8) / 3
            return SIMD4<Float>(red, green, 2, i == 0 ? 0 : 1)
        }
        let before = try tiledFixture(values, width: 8, workspace: workspace)
        var source = try node(original: URL(fileURLWithPath: "/mathematical-reference.dng"), width: 8, height: 8)
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8))
        var settings = FilterSettings()
        if kind == .lensCorrection { settings.distortion = 20 }
        if kind == .exposure { settings.exposure.exposure = 1 }
        if kind == .vignette { settings.vignetteAmount = 35 }
        settings = settings.normalized
        let stage = LWSourcePixelStage(inputWidth: 8, inputHeight: 8, outputWidth: 8, outputHeight: 8,
            offsetX: 0, offsetY: 0, distortion: kind == .lensCorrection ? settings.distortion : 0)
        var retained: UUID?
        if kind == .contentAwareFill {
            // An explicit actual-pixel input is bound, not regenerated by replay.
            let key = UUID(), supplied = try tiledFixture([SIMD4<Float>](repeating: SIMD4(4,-1,2,1), count: 64), width: 8, workspace: workspace)
            source.planeAssets[key] = try LWSourcePlaneAsset(supplied); retained = key
        }
        let filter = LWSourceRetainedFilter(id: UUID(), sourceID: source.id, upstreamRevision: source.revision,
            kind: kind, settings: settings, seed: 17, captureFrame: try source.capturedFrame(transform: transform),
            selectionPlaneID: nil, retainedResultPlaneID: retained, pixelStage: stage)
        let made = try LWFloatFilter.apply(filter, node: source, plane: before, map: try source.currentSpatialMap, workspace: workspace)
        #expect(made.width == 8 && made.height == 8 && made.manifest.sample == "float32-le")
        let actual = try made.read(made.globalExtent).surface
        #expect(actual.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && (0...1).contains($0.w) })
        let conserved = try before.read(before.globalExtent).surface
        for i in values.indices { for channel in 0..<4 { #expect(conserved.pixels[i][channel].bitPattern == values[i][channel].bitPattern) } }
        if kind == .contentAwareFill { #expect(actual.pixels.allSatisfy { $0 == SIMD4(4,-1,2,1) }) }
    }
    @Test func retainedSubjectMaskCombinesExistingMaskAndSelectionWithoutErasingRAW() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        let subject = try tiledFixture([SIMD4(repeating: 0.25), SIMD4(repeating: 0.75)], width: 2, workspace: workspace)
        let under = try tiledFixture([SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)], width: 2, workspace: workspace)
        let selected = try tiledFixture([SIMD4(repeating: 1), SIMD4.zero], width: 2, workspace: workspace)
        let made = try LWSourceFilterPreparation.combineSubject(subject, under: under, selection: selected, workspace: workspace)
        #expect(try made.read(made.globalExtent).surface.pixels == [SIMD4(repeating: 0.125), SIMD4(repeating: 0.5)])
        #expect(try under.read(under.globalExtent).surface.pixels == [SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)])
        let wrong = try tiledFixture([SIMD4(repeating: 1)], width: 1, workspace: workspace)
        #expect(throws: Error.self) { try LWSourceFilterPreparation.combineSubject(subject, under: wrong, selection: nil, workspace: workspace) }
    }
    @Test func orderedFilterGraphAndRetainedBackingSurviveSourceArchiveHydration() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var source = try node(original: URL(fileURLWithPath: "/mathematical-reference.dng"), width: 2, height: 1)
        let result = try tiledFixture([SIMD4(5,-2,1,1),SIMD4(2,0,3,0.5)], width: 2, workspace: workspace), key = UUID()
        source.planeAssets[key] = try LWSourcePlaneAsset(result)
        let stage = LWSourcePixelStage(inputWidth: 2, inputHeight: 1, outputWidth: 2, outputHeight: 1, offsetX: 0, offsetY: 0, distortion: 0)
        let filter = LWSourceRetainedFilter(id: UUID(), sourceID: source.id, upstreamRevision: source.revision,
            kind: .contentAwareFill, settings: FilterSettings(), seed: 7,
            captureFrame: try source.capturedFrame(transform: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 1))),
            selectionPlaneID: nil, retainedResultPlaneID: key, pixelStage: stage)
        try source.appendFilter(filter)
        let packed = try LWSourcePackageArchive.externalize(manifest(source), maximumBytes: 65536)
        let restored = try LWSourcePackageArchive.hydrate(packed.manifest, read: { name, _ in try #require(packed.assets[name]) },
            readPlane: { name, _ in try #require(packed.planes[name]?.plane) })
        let reopened = try #require(restored.layers.first?.liveSource)
        #expect(reopened == source && reopened.orderedOperations == [.filter(filter.id)])
        let input = try tiledFixture([SIMD4.zero,SIMD4.zero], width: 2, workspace: workspace)
        let made = try LWSourceOperationReplay.evaluate(reopened, developed: input, map: LWSourceSpatialMap(geometry: reopened.coordinateMap, optics: reopened.settings.optics, width: reopened.originalWidth, height: reopened.originalHeight), workspace: workspace)
        #expect(try made.surface.read(made.surface.globalExtent).surface.pixels == [SIMD4(5,-2,1,1),SIMD4(2,0,3,0.5)])
        var invalid = source; invalid.operations.append(.filter(filter.id))
        #expect(throws: Error.self) { try invalid.validate() }
    }
}


extension LiveRawSourceTests {
    @Test func pendingWriterCannotBeRetiredBeforeItClaimsItsChild() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        let child = try workspace.makeScratchDirectory()
        expectInvalid { try workspace.retireReleasedGenerations() }
        expectInvalid { try workspace.retireOwnedChildren() }
        #expect(FileManager.default.fileExists(atPath: child.path))
        var token: LWFloatWorkspace.ChildLifetime? = try workspace.retainChild(child)
        try workspace.retireReleasedGenerations()
        #expect(FileManager.default.fileExists(atPath: child.path))
        token = nil
        try workspace.retireReleasedGenerations()
        #expect(!FileManager.default.fileExists(atPath: child.path))
        withExtendedLifetime(token) {}
    }
    @Test func detachedTypedGenerationCompactionPreservesAReaderAndBoundsLongRuns() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        func generation(_ value: UInt32, base: LWTypedStateStore.Snapshot?) throws -> LWTypedStateStore.Snapshot {
            let next = try workspace.makeStateStore(format: .uint32, width: 257, height: 1, base: base)
            try next.write(.uint32(value), x: 0, y: 0)
            if base == nil { try next.write(.uint32(29), x: 256, y: 0) }
            return try next.commit()
        }
        var current: LWTypedStateStore.Snapshot? = try generation(0, base: nil)
        var historical: LWTypedStateStore.Reader? = current?.reader()
        for index in 1...96 {
            // Complete, detach, then release old storage. No inherited state
            // reference survives except the deliberately retained old reader.
            current = try generation(UInt32(index), base: current).compacted(in: workspace)
            try workspace.retireReleasedGenerations()
            let reader = try #require(current).reader()
            if case .uint32(let value) = try reader.read(x: 0, y: 0) { #expect(value == UInt32(index)) }
            else { Issue.record("Wrong typed state format") }
            if case .uint32(let value) = try reader.read(x: 256, y: 0) { #expect(value == 29) }
            else { Issue.record("Compaction lost an unchanged tile") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).count == 2)
        }
        if case .uint32(let value) = try #require(historical).read(x: 0, y: 0) { #expect(value == 0) }
        else { Issue.record("Historical typed reader was invalidated") }
        historical = nil
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).count == 1)
        current = nil
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).isEmpty)
    }
    @Test func releasedF64RowsRetireWithoutTouchingTheActiveSuccessor() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var prior: LWFloatDoubleRows? = nil
        for index in 0..<64 {
            prior = try LWFloatDoubleRows.create(width: 2, height: 1, workingSet: workspace.workingSet,
                directory: workspace.makeScratchDirectory(), fileOwner: workspace) { _ in [Double(index), Double.pi] }
            try workspace.retireReleasedGenerations()
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).count == 1)
            let reader = LWFloatDoubleRows.Reader(try #require(prior))
            #expect(try reader.row(0).values == [Double(index), Double.pi])
        }
        prior = nil
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).isEmpty)
    }
    @Test func releasedGenerationCleanupPreservesUnregisteredMembers() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        defer { try? FileManager.default.removeItem(at: workspace.directory) }
        var prior: LWFloatPlane? = try ownedOnePixel(workspace)
        let child = try #require(FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil).first)
        let sentinel = child.appendingPathComponent("unregistered")
        try Data([1,2,3]).write(to: sentinel, options: .withoutOverwriting)
        prior = nil
        expectInvalid { try workspace.retireReleasedGenerations() }
        #expect(try Data(contentsOf: sentinel) == Data([1,2,3]))
        #expect(FileManager.default.fileExists(atPath: child.path))
        withExtendedLifetime(prior) {}
    }
}


extension LiveRawSourceTests {
    private func capturedStroke(_ source: LWLiveSourceNode, frame: LWSourceRetouchFrame) -> LWSourceRetouchStroke {
        LWSourceRetouchStroke(sourceID:source.id,upstreamRevision:source.revision,captureFrame:frame,kind:.paint,seed:7,
            healMode:.contentAware,sampleAllLayers:false,aligned:false,sampleAllLayersCompositeRevision:nil,
            blurRadius:1,radius:1,hardness:1,opacity:1,points:[CGPoint(x:0.5,y:0.5)],sourceOffset:.zero,color:[2,-1,0.5,1],pointsAreDabs:true)
    }
    @Test func paddedRetouchSelectionUsesItsCapturedDevelopedGridAndWholeIdentity() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet())
        var source = try node(original: URL(fileURLWithPath:"/mathematical-reference.dng"), width:2, height:1)
        let stage = LWSourcePixelStage(inputWidth:2,inputHeight:1,outputWidth:4,outputHeight:1,offsetX:1,offsetY:0,distortion:0)
        let frame = LWSourceRetouchFrame(geometry:.identity,optics:CameraRawOpticsSettings(),width:2,height:1,
            layerTransform:LayerTransform(origin:CGPoint(x:10,y:20),size:CGSize(width:4,height:1)),stages:[stage])
        let selected = try tiledFixture([SIMD4(repeating:1),SIMD4.zero,SIMD4(repeating:0.5),SIMD4.zero],width:4,workspace:workspace)
        let key = UUID(); source.planeAssets[key] = try LWSourcePlaneAsset(selected)
        var stroke = capturedStroke(source,frame:frame);stroke.selectionPlaneID=key;stroke.selectionFrame=frame
        let sampler = try #require(try source.selectionSampler(for:stroke,plane:selected))
        // Virtual source -0.5 is the owned left pad; physical source 0.5 is the
        // second captured selection pixel. No unpadded width reinterpretation.
        #expect(try sampler.sample(CGPoint(x:-0.5,y:0.5)).w == 1)
        #expect(try sampler.sample(CGPoint(x:0.5,y:0.5)).w == 0)
        #expect(try sampler.sample(CGPoint(x:1.5,y:0.5)).w == 0.5)
        #expect(try sampler.sample(CGPoint(x:4.5,y:0.5)).w == 0)
        expectInvalid { _ = try source.selectionSampler(for:stroke,plane:nil) }
        let impostor = try tiledFixture([SIMD4(repeating:1),SIMD4.zero,SIMD4(repeating:0.5),SIMD4.zero],width:4,workspace:workspace)
        expectInvalid { _ = try source.selectionSampler(for:stroke,plane:impostor) }
        try source.appendRetouch(stroke)
        let packed = try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:65536)
        let restored = try LWSourcePackageArchive.hydrate(packed.manifest,read:{name,_ in try #require(packed.assets[name])},
            readPlane:{name,_ in try #require(packed.planes[name]?.plane)})
        let reopened = try #require(restored.layers.first?.liveSource)
        #expect(reopened.retouch[0].selectionFrame == frame && reopened == source)
    }
    @Test func croppedFilterMappingPreservesCapturedDocumentPosition() throws {
        let transform = LayerTransform(origin:CGPoint(x:30,y:40),size:CGSize(width:12,height:8))
        let pad = LWSourcePixelStage(inputWidth:2,inputHeight:2,outputWidth:6,outputHeight:4,offsetX:2,offsetY:1,distortion:0)
        let crop = LWSourcePixelStage(inputWidth:6,inputHeight:4,outputWidth:3,outputHeight:2,offsetX:-1,offsetY:-1,distortion:0)
        let frame = LWSourceRetouchFrame(geometry:.identity,optics:CameraRawOpticsSettings(),width:2,height:2,
            layerTransform:transform,stages:[pad,crop])
        let pixel = CGPoint(x:1.5,y:0.5),document = try frame.developedPixelToDocument(pixel)
        #expect(try frame.documentToDevelopedPixel(document) == pixel)
        let source = try frame.sourcePoint(document)
        #expect(try frame.documentPoint(source) == document)
        #expect(try frame.spatialMap.sourcePointIfInBounds(CGPoint(x:-0.5,y:0.5)) == nil)
        #expect(try frame.sourcePointIfInBounds(document) == source)
        #expect(throws:Error.self) { _ = try frame.sourcePointIfInBounds(CGPoint(x:CGFloat.nan,y:0)) }
    }
}


extension LiveRawSourceTests {
    private func floatProject(_ source: LWLiveSourceNode, plane: LWFloatPlane, transform: LayerTransform) throws -> ProjectSnapshot {
        let asset=try ImportedImage(plane:plane,name:"Protected float reference"),layerID=UUID()
        let record=ProjectLayerRecord(id:layerID,name:"Protected float reference",isVisible:true,transform:transform,
            imageFile:"\(layerID.uuidString).plane",liveSource:source,planeArchiveReference:asset.planeArchiveReference)
        let document=ProjectManifest(workingSpace:"extended-linear-sRGB",workingSample:"float32-straight-RGBA",
            documentID:UUID(),width:16,height:16,activeLayerID:layerID,layers:[record])
        return ProjectSnapshot(manifest:document,images:[layerID:asset])
    }
    @Test func canvasSizeAndEditorHistoryPreserveTheProtectedNodeAndFloatBacking() async throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        let plane=try tiledFixture([SIMD4(3,-1,0.5,1),SIMD4(2,0,4,0.5)],width:2,workspace:workspace)
        let snapshot=try floatProject(source,plane:plane,transform:LayerTransform(origin:CGPoint(x:2,y:3),size:CGSize(width:4,height:2)))
        let resized=try await CanvasResizer.shared.resize(snapshot,to:CanvasSizeOptions(width:20,height:18,contentOffset:CGPoint(x:1,y:2)))
        let record=try #require(resized.manifest.layers.first),before=try #require(snapshot.manifest.layers.first)
        #expect(record.liveSource == source && record.planeArchiveReference == before.planeArchiveReference)
        #expect(record.transform.origin == CGPoint(x:3,y:5))
        #expect(resized.images[record.id]?.image === snapshot.images[record.id]?.image)
        let session=EditorSession();session.installProject(snapshot,from:URL(fileURLWithPath:"/reference.comp"))
        let old=try #require(session.document)
        session.applyDocumentSize(resized,actionName:"Canvas Size")
        #expect(session.document?.layers.first?.liveSource == source && session.history.canUndo)
        session.undo();#expect(session.document == old)
        session.redo();#expect(session.document?.layers.first?.liveSource == source)
    }
    @Test func nonuniformImageSizeRetainsAnOrderedFullAffineRAWOperation() async throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:2)
        let values=[SIMD4<Float>(4,-1,2,1),SIMD4(0,2,3,1),SIMD4(2,3,4,0.5),SIMD4.zero]
        let plane=try tiledFixture(values,width:2,workspace:workspace)
        let snapshot=try floatProject(source,plane:plane,transform:LayerTransform(origin:CGPoint(x:3,y:4),size:CGSize(width:4,height:4),rotation:30))
        let resized=try await ImageResizer.shared.resize(snapshot,to:ImageSizeOptions(width:32,height:24,resolution:300,sampling:.nearest))
        let layer=try #require(resized.manifest.layers.first),next=try #require(layer.liveSource),op=try #require(next.resamples.first)
        #expect(next.original == source.original && next.originalRevision == source.originalRevision && next.provenance == source.provenance)
        #expect(next.orderedOperations == [.resample(op.id)] && next.revision != source.revision)
        let output=try #require(resized.images[layer.id]?.linearPlane)
        #expect(output.width == op.stage.outputWidth && output.height == op.stage.outputHeight)
        let mapped=try op.stage.developedPoint(CGPoint(x:0.5,y:0.5)),h=try #require(op.stage.homography)
        #expect(try h.inverse().map(mapped).x.isFinite)
        let replay=try LWSourceOperationReplay.evaluate(next,developed:plane,
            map:LWSourceSpatialMap(geometry:source.coordinateMap,optics:source.settings.optics,width:2,height:2),workspace:workspace)
        for entry in output.manifest.entries {
            #expect(try output.read(entry.range).surface.pixels == replay.surface.read(entry.range).surface.pixels)
        }
        let original=try plane.read(plane.globalExtent).surface
        for index in values.indices { for channel in 0..<4 { #expect(original.pixels[index][channel].bitPattern == values[index][channel].bitPattern) } }
        let packed=try LWSourcePackageArchive.externalize(resized.manifest,maximumBytes:65536)
        let hydrated=try LWSourcePackageArchive.hydrate(packed.manifest,read:{name,_ in try #require(packed.assets[name])},
            readPlane:{name,_ in try #require(packed.planes[name]?.plane)})
        #expect(hydrated.layers.first?.liveSource == next)
    }
    @Test(arguments:TrimBasedOn.allCases)
    func boundedTrimMatchesTheRetainedColorCriterionWithoutEditingSource(_ mode: TrimBasedOn) throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let plane=try tiledFixture([SIMD4.zero,SIMD4.zero,SIMD4.zero,SIMD4.zero,SIMD4(3,-1,2,1),SIMD4.zero],width:3,workspace:workspace)
        let provider=LWFloatPlaneImage(plane:plane,format:.rgba8SRGB),image=try provider.image()
        let options=TrimOptions(basedOn:mode)
        let reference=ImageTrim.calculateTrimRect(in:image,options:options)
        try provider.check()
        let actual=try ImageTrim.calculateTrimRect(in:plane,options:options)
        #expect(actual == reference)
        #expect(try plane.read(plane.globalExtent).surface.pixels[4] == SIMD4(3,-1,2,1))
    }
}


extension LiveRawSourceTests {
    @Test(arguments:[-20.0,20.0])
    func ownedPaddingKeepsTheSameMonotoneOpticalCoordinates(_ distortion:Double) throws {
        var optics=CameraRawOpticsSettings();optics.distortion=distortion
        let stage=LWSourcePixelStage(inputWidth:8,inputHeight:6,outputWidth:10,outputHeight:8,offsetX:1,offsetY:1,distortion:0)
        let map=LWSourceSpatialMap(geometry:.identity,optics:optics,width:8,height:6,stages:[stage])
        for point in [CGPoint(x:0.5,y:0.5),CGPoint(x:4.5,y:3.5),CGPoint(x:9.5,y:7.5)] {
            let source=try #require(try map.sourcePointIfInBounds(point))
            let returned=try #require(try map.developedPointIfInBounds(source))
            #expect(abs(returned.x-point.x) < 1e-10 && abs(returned.y-point.y) < 1e-10)
        }
        #expect(try map.sourcePointIfInBounds(CGPoint(x:-0.5,y:0.5)) == nil)
        // A virtual extent that crosses a positive radial fold must refuse;
        // source-coordinate ambiguity is never replaced by identity mapping.
        let foldedPad=LWSourcePixelStage(inputWidth:8,inputHeight:6,outputWidth:100,outputHeight:100,offsetX:40,offsetY:40,distortion:0)
        var positive=CameraRawOpticsSettings();positive.distortion=20
        let invalid=LWSourceSpatialMap(geometry:.identity,optics:positive,width:8,height:6,stages:[foldedPad])
        expectInvalid { _ = try invalid.sourcePointIfInBounds(CGPoint(x:0.5,y:0.5)) }
    }
    @Test func brushPreviewKeepsTheChronologicalFilterAndResampleMaps() throws {
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:2)
        let transform=LayerTransform(origin:.zero,size:CGSize(width:2,height:2))
        let first=LWSourceRetainedFilter(id:UUID(),sourceID:source.id,upstreamRevision:source.revision,kind:.exposure,
            settings:FilterSettings(),seed:1,captureFrame:try source.capturedFrame(transform:transform),selectionPlaneID:nil,
            retainedResultPlaneID:nil,pixelStage:.init(inputWidth:2,inputHeight:2,outputWidth:2,outputHeight:2,offsetX:0,offsetY:0,distortion:0))
        try source.appendFilter(first)
        let affine=try LWSourceCoordinateMap([2,0.25,0,0,1.5,0,0,0,1])
        let resize=LWSourceResample(id:UUID(),sourceID:source.id,upstreamRevision:source.revision,
            stage:.init(inputWidth:2,inputHeight:2,outputWidth:5,outputHeight:3,offsetX:0,offsetY:0,distortion:0,homography:affine),sampling:.high)
        try source.appendResample(resize)
        let stroke=capturedStroke(source,frame:try source.capturedFrame(transform:transform))
        try source.appendRetouch(stroke)
        let last=LWSourceRetainedFilter(id:UUID(),sourceID:source.id,upstreamRevision:source.revision,kind:.exposure,
            settings:FilterSettings(),seed:2,captureFrame:try source.capturedFrame(transform:transform),selectionPlaneID:nil,
            retainedResultPlaneID:nil,pixelStage:.init(inputWidth:5,inputHeight:3,outputWidth:5,outputHeight:3,offsetX:0,offsetY:0,distortion:0))
        try source.appendFilter(last)
        let preview=try source.previewingRetouch(stroke)
        #expect(preview.orderedOperations == [.filter(first.id),.resample(resize.id),.filter(last.id),.retouch(0)])
        #expect((try preview.currentSpatialMap).stages == (try source.currentSpatialMap).stages)
        #expect(preview.resamples == source.resamples && preview.filters == source.filters && preview.retouch == [stroke])
    }
    @Test func resizeSaveReopenRetainsSourceAndSharedComposition() async throws {
        let root=try temporaryProjectFolder();defer { try? FileManager.default.removeItem(at:root) }
        let original=root.appendingPathComponent("protected.reference"),originalBytes=Data([17,23,51,99])
        try originalBytes.write(to:original,options:.withoutOverwriting)
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try node(original:original,width:2,height:2)
        let pixels=[SIMD4<Float>(3,-1,2,1),SIMD4(0,2,3,1),SIMD4(2,1,0,0.5),SIMD4.zero]
        let plane=try tiledFixture(pixels,width:2,workspace:workspace)
        let initial=try floatProject(source,plane:plane,transform:LayerTransform(origin:CGPoint(x:3,y:4),size:CGSize(width:4,height:4),rotation:30))
        let session=EditorSession();session.installProject(initial,from:root.appendingPathComponent("Original.comp"))
        let enlarged=try await ImageResizer.shared.resize(initial,to:ImageSizeOptions(width:24,height:20,resolution:300,sampling:.nearest))
        session.applyImageSize(enlarged)
        let padded=try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
            to:CanvasSizeOptions(width:28,height:22,contentOffset:CGPoint(x:2,y:1)))
        session.applyDocumentSize(padded,actionName:"Canvas Size")
        let current=try #require(session.projectSnapshot())
        #expect(session.history.undoCount == 2)
        let file=root.appendingPathComponent("Resized.comp")
        try await ProjectStore.shared.save(current,to:file)
        let reopened=try await ProjectStore.shared.load(from:file),restored=EditorSession()
        restored.installProject(reopened,from:file)
        let beforeUndo=try #require(restored.projectSnapshot())
        #expect(beforeUndo.manifest.layers.first?.liveSource == current.manifest.layers.first?.liveSource)
        #expect(beforeUndo.manifest.layers.first?.planeArchiveReference == current.manifest.layers.first?.planeArchiveReference)
        // The canvas preview's exact graph composer and export composition use
        // the same retained placement and full float backings after restart.
        let a=try LWFloatCompositor.renderPlane(current,workspace:workspace)
        let b=try LWFloatCompositor.renderPlane(beforeUndo,workspace:workspace)
        for tile in a.manifest.entries { #expect(try a.read(tile.range).surface.pixels == b.read(tile.range).surface.pixels) }
        // Undo history is session-only: the original session still undoes both resizes.
        session.undo();#expect(session.document?.width == 24 && session.document?.height == 20)
        session.undo();#expect(session.document?.layers.first?.liveSource == source)
        let restoredPlane = try #require(session.document?.layers.first?.asset?.linearPlane)
        #expect(try restoredPlane.read(plane.globalExtent).surface.pixels == pixels)
        #expect(!restored.canUndo)
        #expect(try Data(contentsOf:original) == originalBytes)
    }
    @Test func capturedSchemasRejectUnknownKeysAndChargeRetainedStageArrays() throws {
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:2)
        let frame=try source.capturedFrame(transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:2)))
        let stroke=capturedStroke(source,frame:frame)
        var encoded=try #require(JSONSerialization.jsonObject(with:LWCatalogCodec.encode(stroke)) as? [String:Any])
        encoded["unregisteredSelectionCoordinateSpace"]="document"
        expectInvalid { _ = try LWCatalogCodec.decode(LWSourceRetouchStroke.self,from:JSONSerialization.data(withJSONObject:encoded)) }
        var frameJSON=try #require(JSONSerialization.jsonObject(with:LWCatalogCodec.encode(frame)) as? [String:Any])
        frameJSON["unregisteredTransform"]=[1,0,0]
        expectInvalid { _ = try LWCatalogCodec.decode(LWSourceRetouchFrame.self,from:JSONSerialization.data(withJSONObject:frameJSON)) }
        var retained=source;try retained.appendRetouch(stroke)
        let baseCharge=retained.retainedPayloadBytes
        let stage=LWSourcePixelStage(inputWidth:2,inputHeight:2,outputWidth:2,outputHeight:2,offsetX:0,offsetY:0,distortion:0,
            homography:try LWSourceCoordinateMap([1,0,0,0,1,0,0,0,1]))
        let extraFrame=LWSourceRetouchFrame(geometry:.identity,optics:CameraRawOpticsSettings(),width:2,height:2,
            layerTransform:frame.layerTransform,stages:[stage])
        retained.retouch=[capturedStroke(source,frame:extraFrame)]
        #expect(retained.retainedPayloadBytes >= baseCharge+MemoryLayout<LWSourcePixelStage>.stride+9*MemoryLayout<Double>.stride)
    }
}


extension LiveRawSourceTests {
    @Test func floatMaskImageSizeKeepsItsWholeBackingAndAffinePlacement() async throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:2)
        let plane=try tiledFixture([SIMD4<Float>](repeating:SIMD4(3,-1,2,1),count:4),width:2,workspace:workspace)
        let coverage=try tiledFixture([SIMD4(repeating:1),SIMD4.zero,SIMD4(repeating:0.25),SIMD4(repeating:0.75)],width:2,workspace:workspace)
        let mask=try ImportedImage(maskPlane:coverage,name:"Exact mask")
        var snapshot=try floatProject(source,plane:plane,transform:LayerTransform(origin:CGPoint(x:3,y:4),size:CGSize(width:4,height:4),rotation:30))
        var m=snapshot.manifest;let id=try #require(m.layers.first?.id)
        m.layers[0].maskFile="\(id.uuidString).mask.plane";m.layers[0].maskPlaneArchiveReference=mask.planeArchiveReference
        snapshot=ProjectSnapshot(manifest:m,images:snapshot.images,masks:[id:mask])
        let changed=try await ImageResizer.shared.resize(snapshot,to:ImageSizeOptions(width:24,height:20,resolution:72,sampling:.nearest))
        let record=try #require(changed.manifest.layers.first),made=try #require(changed.masks[id]?.linearPlane)
        let stage=try #require(record.liveSource?.resamples.last?.stage),v=try #require(stage.homography).values
        let opaque=try tiledFixture([SIMD4(1,1,1,1),SIMD4(0,0,0,1),SIMD4(0.25,0.25,0.25,1),SIMD4(0.75,0.75,0.75,1)],width:2,workspace:workspace)
        let projected=try LWFloatCompositor.project(opaque,mapping:CGAffineTransform(a:v[0],b:v[3],c:v[1],d:v[4],tx:v[2],ty:v[5]),
            width:stage.outputWidth,height:stage.outputHeight,workspace:workspace,sampling:.nearest)
        let expected=try LWFloatCompositor.map(projected,workspace:workspace) { p,_,_ in SIMD4(repeating:min(1,max(0,p.x*p.w))) }
        let madeReference = try LWFloatPlaneArchive.reference(made)
        #expect(record.maskFile == "\(id.uuidString).mask.plane" && record.maskPlaneArchiveReference == madeReference)
        for tile in made.manifest.entries { #expect(try made.read(tile.range).surface.pixels == expected.read(tile.range).surface.pixels) }
        #expect(try coverage.read(coverage.globalExtent).surface.pixels.map(\.w) == [1,0,0.25,0.75])
    }
}


extension LiveRawSourceTests {
    @Test(arguments:["source","selectionABA","historyABA"])
    func asynchronousResizeAdmissionRefusesNewerDocumentState(_ change:String) async throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:2)
        let plane=try tiledFixture([SIMD4<Float>](repeating:SIMD4(3,-1,2,1),count:4),width:2,workspace:workspace)
        let initial=try floatProject(source,plane:plane,transform:LayerTransform(origin:CGPoint(x:3,y:4),size:CGSize(width:4,height:4)))
        let session=EditorSession();session.installProject(initial,from:URL(fileURLWithPath:"/Reference.comp"))
        let admitted=try session.captureDocumentEditAdmission()
        let result=try await ImageResizer.shared.resize(initial,to:ImageSizeOptions(width:24,height:20,resolution:72))
        switch change {
        case "source":
            var changed=source;changed.settings.exposure=1;changed.revision=UUID();changed.sourceLineage.append(changed.revision)
            session.document?.layers[0].liveSource=changed
        case "selectionABA":
            let id=session.activeLayerID;session.activeLayerID=nil;session.activeLayerID=id
        case "historyABA":
            session.beginEdit("Reference name");session.document?.layers[0].name="New name";session.endEdit();session.undo()
        default: Issue.record("Unknown actual-code resize discriminator");return
        }
        let retained=session.document,revision=session.history.currentRevision
        expectInvalid { try session.applyDocumentSize(result,actionName:"Image Size",admission:admitted) }
        #expect(session.document == retained && session.history.currentRevision == revision)
        #expect(session.document?.width == initial.manifest.width)
        #expect(try plane.read(plane.globalExtent).surface.pixels == [SIMD4<Float>](repeating:SIMD4(3,-1,2,1),count:4))
    }
}


extension LiveRawSourceTests {
    @Test func workspaceRosterAdmissionPrecedesChildCreationAndReleasesAfterCheckedRetirement() throws {
        let small=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:4095))
        defer { try? FileManager.default.removeItem(at:small.directory) }
        #expect(throws:ProjectError.self) { _ = try small.makeScratchDirectory() }
        #expect(try FileManager.default.contentsOfDirectory(atPath:small.directory.path).isEmpty)
        let budget=try LWFloatWorkingSet(limit:4*1024*1024),workspace=try LWFloatWorkspace(workingSet:budget)
        var plane:LWFloatPlane?=try ownedOnePixel(workspace)
        #expect(throws:ProjectError.self) { _ = try budget.reserve(budget.limit) }
        plane=nil
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath:workspace.directory.path).isEmpty)
        // The live root/cleanup record still owns its metadata admission.
        let complete=try budget.reserve(budget.limit-2048)
        #expect(throws:ProjectError.self) { _=try budget.reserve(1) }
        withExtendedLifetime(complete) {};withExtendedLifetime(plane) {}
    }
}


extension LiveRawSourceTests {
    @Test func sampleAllProducerUsesTheAdmittedImmediatelyPriorPlaneAndRetainedOtherLayer() throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        let before=try tiledFixture([SIMD4<Float>(2,-1,0.5,1),SIMD4(0,2,3,1)],width:2,workspace:workspace)
        let other=try tiledFixture([SIMD4<Float>(0.25,0.5,0.75,0.5),SIMD4(1,0,0,0.25)],width:2,workspace:workspace)
        let a=try ImportedImage(plane:before,name:"Source"),b=try ImportedImage(plane:other,name:"Other layer")
        let sourceLayer=UUID(),otherLayer=UUID(),transform=LayerTransform(origin:.zero,size:CGSize(width:2,height:1))
        let manifest=ProjectManifest(workingSpace:"extended-linear-sRGB",workingSample:"float32-straight-RGBA",documentID:UUID(),
            width:2,height:1,activeLayerID:sourceLayer,layers:[
                ProjectLayerRecord(id:sourceLayer,name:a.name,isVisible:true,transform:transform,imageFile:"\(sourceLayer.uuidString).plane",
                    liveSource:source,planeArchiveReference:a.planeArchiveReference),
                ProjectLayerRecord(id:otherLayer,name:b.name,isVisible:true,transform:transform,imageFile:"\(otherLayer.uuidString).plane",
                    planeArchiveReference:b.planeArchiveReference)])
        let captured=try LWSourceSampleComposite.capturePlane(ProjectSnapshot(manifest:manifest,images:[sourceLayer:a,otherLayer:b]),
            sourceLayer:sourceLayer,node:source,workspace:workspace)
        source.sampleComposites=[captured.composite];source.planeAssets=captured.assets
        let stroke=LWSourceRetouchStroke(sourceID:source.id,upstreamRevision:source.revision,captureFrame:try source.capturedFrame(transform:transform),
            kind:.clone,seed:7,healMode:.contentAware,sampleAllLayers:true,aligned:true,sampleAllLayersCompositeRevision:captured.composite.revision,
            blurRadius:0,radius:1,hardness:1,opacity:1,points:[CGPoint(x:0.5,y:0.5)],sourceOffset:.zero,color:[0,0,0,1],pointsAreDabs:true)
        try source.appendRetouch(stroke)
        let admission=try source.retouchAdmission(plane:before,workspace:workspace,operationScratchBytes:0)
        let made=try source.sampleAllCompositePlane(for:stroke,before:before,admission:admission,workspace:workspace)
        // The capture composites with the document's blend definition: source-over in extended
        // encoded sRGB (LWFloatCompositor.blend), not in linear light. Core Image evaluates that
        // transfer in float; 2e-4 covers its rounding at these HDR magnitudes.
        let otherValues=[SIMD4<Float>(0.25,0.5,0.75,0.5),SIMD4(1,0,0,0.25)]
        func expectComposite(_ made:LWFloatPlane,over bottom:[SIMD4<Float>]) throws {
            let values=try made.read(made.globalExtent).surface.pixels
            for (index,actual) in values.enumerated() {
                let expected=Self.encodedSourceOver(otherValues[index],over:bottom[index])
                for channel in 0..<4 { #expect(abs(actual[channel]-expected[channel]) < 2e-4,"\(index) \(actual) \(expected)") }
            }
        }
        try expectComposite(made,over:[SIMD4<Float>(2,-1,0.5,1),SIMD4(0,2,3,1)])
        let changed=try tiledFixture([SIMD4<Float>(4,-2,1,1),SIMD4(0,4,6,1)],width:2,workspace:workspace)
        expectInvalid { _ = try source.sampleAllCompositePlane(for:stroke,before:changed,admission:admission,workspace:workspace) }
        let nextAdmission=try source.retouchAdmission(plane:changed,workspace:workspace,operationScratchBytes:0)
        let next=try source.sampleAllCompositePlane(for:stroke,before:changed,admission:nextAdmission,workspace:workspace)
        try expectComposite(next,over:[SIMD4<Float>(4,-2,1,1),SIMD4(0,4,6,1)])
        var stale=source;stale.revision=UUID();stale.sourceLineage.append(stale.revision)
        expectInvalid { _ = try stale.sampleAllCompositePlane(for:stroke,before:before,admission:admission,workspace:workspace) }
        let stranger=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        expectInvalid { _ = try source.sampleAllCompositePlane(for:stroke,before:before,admission:admission,workspace:stranger) }
        let backing=try LWCatalogCodec.decode(LWSourceSampleComposite.Backing.self,from:captured.composite.payload)
        #expect(backing.images[sourceLayer] == nil && backing.imagePlanes[sourceLayer] == nil)
        #expect(captured.assets.count == 1 && backing.imagePlanes[otherLayer] != nil)
        #expect(try before.read(before.globalExtent).surface.pixels == [SIMD4<Float>(2,-1,0.5,1),SIMD4(0,2,3,1)])
    }
}


extension LiveRawSourceTests {
    @Test(arguments:["unchanged","source","selectionABA","historyABA","mask"])
    func deferredLiveFilterUsesTheCapturedProductionDocumentAdmission(_ change:String) throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:2)
        let plane=try tiledFixture([SIMD4<Float>](repeating:SIMD4(3,-1,2,1),count:4),width:2,workspace:workspace)
        let snapshot=try floatProject(source,plane:plane,transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:2)))
        let session=EditorSession();session.installProject(snapshot,from:URL(fileURLWithPath:"/Reference.comp"))
        let layer=try #require(session.activeLayer)
        let edit=try FilterEdit(kind:.exposure,layer:layer,selection:nil,settings:FilterSettings())
        edit.liveAdmission=try session.captureDocumentEditAdmission();session.filterEdit=edit
        try session.validateLiveSourceFilterAdmission(edit)
        switch change {
        case "unchanged": break
        case "source":
            var changed=source;changed.revision=UUID();changed.sourceLineage.append(changed.revision)
            session.document?.layers[0].liveSource=changed
        case "selectionABA":
            let id=session.activeLayerID;session.activeLayerID=nil;session.activeLayerID=id
        case "historyABA":
            session.beginEdit("Reference name");session.document?.layers[0].name="New";session.endEdit();session.undo()
        case "mask":
            session.document?.layers[0].mask=LayerMask(asset:try ImportedImage(maskPlane:plane,name:"Reference mask"))
        default:Issue.record("Unknown production filter admission discriminator");return
        }
        let retained=session.document,revision=session.history.currentRevision
        if change == "unchanged" { try session.validateLiveSourceFilterAdmission(edit) }
        else { expectInvalid { try session.validateLiveSourceFilterAdmission(edit) } }
        #expect(session.document == retained && session.history.currentRevision == revision)
        #expect(try plane.read(plane.globalExtent).surface.pixels == [SIMD4<Float>](repeating:SIMD4(3,-1,2,1),count:4))
        session.filterEdit=nil
        expectInvalid { try session.validateLiveSourceFilterAdmission(edit) }
    }
}


extension LiveRawSourceTests {
    @Test func subjectCoverageUsesGlobalPixelCentersAndLinearAlpha() throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let source=try tiledFixture([SIMD4.zero,SIMD4(repeating:1)],width:2,workspace:workspace)
        let same=try LWFloatSubjectMask.resampleCoverage(source,width:2,height:1,workspace:workspace)
        #expect(try same.read(same.globalExtent).surface.pixels == [SIMD4.zero,SIMD4(repeating:1)])
        let doubled=try LWFloatSubjectMask.resampleCoverage(source,width:4,height:1,workspace:workspace)
        #expect(try doubled.read(doubled.globalExtent).surface.pixels.map(\.w) == [0,0.25,0.75,1])
        let soft=try tiledFixture([SIMD4(repeating:0.2),SIMD4(repeating:0.8)],width:2,workspace:workspace)
        let mixed=try LWFloatSubjectMask.resampleCoverage(soft,width:1,height:1,workspace:workspace)
        #expect(abs(try mixed.read(mixed.globalExtent).surface.pixels[0].w-0.5) < 1e-6)
        #expect(try source.read(source.globalExtent).surface.pixels == [SIMD4.zero,SIMD4(repeating:1)])
    }
    @Test func floatMaskCompositionPreservesSubByteCoverageAndRetainedPlacement() throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let value:Float=0.1234567
        let plane=try tiledFixture([SIMD4(repeating:value),SIMD4(repeating:0.8123456)],width:2,workspace:workspace)
        let asset=try ImportedImage(maskPlane:plane,name:"Float coverage"),transform=LayerTransform(origin:.zero,size:CGSize(width:2,height:1))
        let made=try LWSourceMaskReconcile.coveragePlane(LayerMask(asset:asset),over:transform,width:2,height:1,workspace:workspace)
        let pixels=try made.read(made.globalExtent).surface.pixels
        #expect(abs(pixels[0].w-value) < 1e-6 && abs(pixels[1].w-0.8123456) < 1e-6)
        #expect(abs(pixels[0].w-(value*255).rounded()/255) > 1e-5)
        let resized=try LWSourceMaskReconcile.projectCoverage(plane,mapping:CGAffineTransform(scaleX:2,y:1),width:4,height:1,
            sampling:.nearest,workspace:workspace)
        let values=try resized.read(resized.globalExtent).surface.pixels.map(\.w)
        #expect(abs(values[0]-value) < 1e-6 && abs(values[1]-value) < 1e-6)
        #expect(abs(values[2]-0.8123456) < 1e-6 && abs(values[3]-0.8123456) < 1e-6)
        #expect(try plane.read(plane.globalExtent).surface.pixels.map(\.w) == [value,0.8123456])
    }
}


extension LiveRawSourceTests {
    @Test func historicalFloatDependencyTilingPreservesHiddenRGBAndScalarMaskMeaning() throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let values=[SIMD4<Float>(7,-3,2,0),SIMD4(4,-1,3,0.5)]
        let original=try surface(values)
        let made=try LWFloatCompositor.from(original,workspace:workspace)
        let read=try made.read(made.globalExtent).surface.pixels
        for index in values.indices { for channel in 0..<4 { #expect(read[index][channel].bitPattern == values[index][channel].bitPattern) } }
        let gray=try GuidedMatte.image([0.25,0.75],width:2,height:1),asset=try LayerMask.asset(from:gray)
        let coverage=try LWSourceMaskReconcile.plane(asset,workspace:workspace)
        let expected=try GuidedMatte.levels(of:gray,width:2,height:1)
        let mask=try coverage.read(coverage.globalExtent).surface.pixels
        for index in expected.indices { #expect(mask[index] == SIMD4(repeating:expected[index])) }
    }
}


extension LiveRawSourceTests {
    @Test(arguments:["valid","request","rawAdmission","frame","metadata","provenance","short","long","unknown","planeCharge","pixelCharge","logicalDisk"])
    func sourcePlaneTransportUsesStrictProductionDescriptorAndRangeJoins(_ change:String) throws {
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:3,height:2)
        let request=try source.request(id:UUID())
        func object<T:Encodable>(_ value:T)throws->Any { try JSONSerialization.jsonObject(with:LWCatalogCodec.encode(value)) }
        var document:[String:Any]=["source_revision":LWManagedAuthority.sourceRevision,"protocol":2,"kind":"source_float_plane",
            "mime":"application/x-lensworks-rgba-f32le","width":3,"height":2,"row_stride":"48","byte_length":"96",
            "channels":4,"sample":"float32_le","color_space":"linear_srgb","alpha":"straight","orientation":"applied",
            "metadata":try JSONSerialization.jsonObject(with:source.metadata),"provenance":try JSONSerialization.jsonObject(with:source.provenance),
            "source_authority":try object(request),"memory_enforcement":"mathematical descriptor fixture","payload_digest":String(repeating:"1",count:64)]
        let plane=try LWCatalogCodec.decode(LWManagedSourcePlaneDescriptor.self,from:JSONSerialization.data(withJSONObject:document))
        let limits=LWApplicationExportsDtoDecodeLimits(max_encoded_bytes:LWCatalogU64(1024),max_intermediate_pixels:LWCatalogU64(6),max_allocation_bytes:LWCatalogU64(96))
        try LWSourceTileTransport.validatePlane(plane,request:request,limits:limits,workerBytes:LWCatalogU64(96))
        if change == "logicalDisk" {
            // A retained file can exceed the decoder's resident row allowance.
            // Validation checks its complete logical geometry/header; no Vec or
            // ABI result allocation is authorized by this descriptor.
            let rows=LWApplicationExportsDtoDecodeLimits(max_encoded_bytes:LWCatalogU64(1024),max_intermediate_pixels:LWCatalogU64(6),max_allocation_bytes:LWCatalogU64(48))
            #expect(plane.byte_length.value>48)
            try LWSourceTileTransport.validatePlane(plane,request:request,limits:rows,workerBytes:LWCatalogU64(48));return
        }
        if change == "planeCharge" {
            expectInvalid { try LWSourceTileTransport.validatePlane(plane,request:request,limits:limits,workerBytes:LWCatalogU64(95)) };return
        }
        if change == "pixelCharge" {
            let reduced=LWApplicationExportsDtoDecodeLimits(max_encoded_bytes:LWCatalogU64(1024),max_intermediate_pixels:LWCatalogU64(5),max_allocation_bytes:LWCatalogU64(96))
            expectInvalid { try LWSourceTileTransport.validatePlane(plane,request:request,limits:reduced,workerBytes:LWCatalogU64(96)) };return
        }
        let range=LWFloatRange(x:1,y:0,width:2,height:2)
        document.removeValue(forKey:"payload_digest");document["kind"]="source_float_tile"
        document["width"]=2;document["height"]=2;document["row_stride"]="32";document["byte_length"]="64"
        document["frame_width"]=3;document["frame_height"]=2;document["tile_rect"]=try object(range.native)
        switch change {
        case "valid":break
        case "request":document["source_authority"]=try object(source.request(id:UUID()))
        case "rawAdmission":var value=try #require(document["source_authority"] as? [String:Any]);value["raw_hint"] = !request.raw_hint;document["source_authority"]=value
        case "frame":document["frame_width"]=4
        case "metadata":var value=try #require(document["metadata"] as? [String:Any]);value["format"]="DIFFERENT_REFERENCE";document["metadata"]=value
        case "provenance":var value=try #require(document["provenance"] as? [String:Any]);value["decoder"]="different-fixture";document["provenance"]=value
        case "short":document["byte_length"]="63"
        case "long":document["byte_length"]="65"
        case "unknown":document["browse_fallback"]=true
        default:Issue.record("Unknown production source-plane descriptor discriminator");return
        }
        let bytes=try JSONSerialization.data(withJSONObject:document)
        if ["short","long","unknown"].contains(change) {
            #expect(throws:LensWorksManagedError.self) { _ = try LWCatalogCodec.decode(LWManagedSourceTileDescriptor.self,from:bytes) };return
        }
        let tile=try LWCatalogCodec.decode(LWManagedSourceTileDescriptor.self,from:bytes)
        if change == "valid" { try LWSourceTileTransport.validateTile(tile,plane:plane,request:request,range:range) }
        else { expectInvalid { try LWSourceTileTransport.validateTile(tile,plane:plane,request:request,range:range) } }
    }
    @Test func sourceMetadataPredecodeAndCopyRefusalDoNotPublishPartialCollections() throws {
        let source=try node(original:URL(fileURLWithPath:"/metadata-refusal.dng"),width:2,height:1)
        let bytes=try JSONEncoder().encode(source)
        let required=try LWSourceMetadataStorage.decodingBytes(bytes)
        let insufficient=try LWFloatWorkingSet(limit:required-1)
        #expect(throws:ProjectError.self) { try LWSourceMetadataStorage.decode(LWLiveSourceNode.self,from:bytes,workingSet:insufficient) }
        // A refused decoder leaves its entire reservation available.
        let full=try insufficient.reserve(required-1);withExtendedLifetime(full) {}
        let decoded=try LWSourceMetadataStorage.decode(LWLiveSourceNode.self,from:bytes)
        #expect(decoded.value == source);try decoded.value.validateMetadataStorage()
        var keys=try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        #expect(keys["metadataStorage"] == nil)
        keys["metadataStorage"]=["capacity":512*1024*1024]
        let malformed=try JSONSerialization.data(withJSONObject:keys)
        #expect(throws:ProjectError.self) { try LWSourceMetadataStorage.decode(LWLiveSourceNode.self,from:malformed) }
        let bounded=try LWFloatWorkingSet(limit:source.retainedPayloadBytes)
        var before=source;before.metadataStorage=try LWSourceMetadataStorage(bytes:before.retainedPayloadBytes,workingSet:bounded)
        #expect(throws:ProjectError.self) { try before.metadataCopy(additionalBytes:1) }
        #expect(before == source);try before.validateMetadataStorage()
    }
    @Test func chargedSourcesReadRejectsSymlinkAndCancellationWithoutLeakingReservation() async throws {
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("LWSourceMetadata-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false)
        let physical=try temporary.resolvingSymlinksInPath().resourceValues(forKeys:[.isDirectoryKey]);#expect(physical.isDirectory == true);defer { try? FileManager.default.removeItem(at:temporary) }
        let file=temporary.resolvingSymlinksInPath().appendingPathComponent("owned.data"),alias=temporary.resolvingSymlinksInPath().appendingPathComponent("alias.data")
        try Data([1,2,3,4]).write(to:file,options:.withoutOverwriting)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:file)
        let working=try LWFloatWorkingSet(limit:8192)
        #expect(throws:ProjectError.self) { try LWSourceOwnedData.read(alias,maximumBytes:4,workingSet:working) }
        var entry:LWSourceOwnedData?=try LWSourceOwnedData.read(file,maximumBytes:4,workingSet:working)
        weak var lifetime=entry?.owner
        #expect(try #require(entry).bytes.elementsEqual(Data([1,2,3,4])))
        #expect(throws:ProjectError.self) { try working.reserve(4097) }
        entry=nil;#expect(lifetime == nil)
        let task=Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return try LWSourceOwnedData.read(file,maximumBytes:4,workingSet:working)
        }
        task.cancel()
        do { _=try await task.value;Issue.record("Cancelled source metadata read was accepted") }
        catch is CancellationError {} catch { Issue.record("Unexpected source metadata cancellation error: \(error)") }
        let all=try working.reserve(8192);withExtendedLifetime(all) {}
    }
    @Test func sourceHydrationNeverSubstitutesAnUnknownBackingAndRetainsChargedMetadata() throws {
        var source=try node(original:URL(fileURLWithPath:"/metadata-history.dng"),width:2,height:1)
        let coverage=try surface([SIMD4(repeating:1),SIMD4.zero]).packageData(maximumFileBytes:1024)
        source=try source.metadataCopy(additionalBytes:64*1024)
        source.selectedDevelopments=[.init(settings:CameraRawSettings(),whiteBalance:.asShot,seed:1,sourceCoverage:coverage)]
        let packed=try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:16*1024)
        let missing=try #require(packed.assets.first(where:{$0.key.hasSuffix(".data")})).key
        #expect(throws:ProjectError.self) { try LWSourcePackageArchive.hydrate(packed.manifest,read:{ name,_ in
            guard name != missing,let bytes=packed.assets[name] else { throw ProjectError.missingImage };return bytes
        }) }
        let hydrated=try LWSourcePackageArchive.hydrate(packed.manifest,read:{ name,_ in try #require(packed.assets[name]) })
        let reopened=try #require(hydrated.layers[0].liveSource)
        #expect(reopened == source);try reopened.validateMetadataStorage()
        #expect(reopened.selectedDevelopments[0].sourceCoverage == coverage)
        // Externalization does not serialize a runtime lease or its input cache.
        #expect(hydrated.layers[0].liveSourceFile == nil)
    }

    @Test func longMetadataGenerationsStayCharged() throws {
        var base=try node(original:URL(fileURLWithPath:"/metadata-generations.dng"),width:2,height:1)
        let bytes=base.retainedPayloadBytes
        let working=try LWFloatWorkingSet(limit:bytes*129+4096)
        base.metadataStorage=try LWSourceMetadataStorage(bytes:bytes,workingSet:working)
        let listCharge=try LWSourceMetadataStorage.collectionBytes(count:128,stride:MemoryLayout<LWLiveSourceNode>.stride)
        let listOwner=try LWSourceMetadataStorage(bytes:listCharge)
        var retained:[LWLiveSourceNode]=[]
        for i in 0..<128 {
            var copy=try base.metadataCopy();copy.grainSeed=UInt32(i);try copy.validateMetadataStorage();retained.append(copy)
        }
        #expect(retained.count == 128)
        #expect(throws:ProjectError.self) { try base.metadataCopy() }
        retained.removeAll(keepingCapacity:false)
        let headroom=try working.reserve(bytes*128+4096);withExtendedLifetime(headroom) {};withExtendedLifetime(listOwner) {}
    }

    @Test func registeredSourceHistoryRefusesBeforeEffectWhenTopologyCannotBeReserved() throws {
        let source=try node(original:URL(fileURLWithPath:"/history-refusal.dng"),width:2,height:1),id=UUID()
        let layer=ImageLayer(id:id,asset:nil,name:"Protected",isVisible:true,transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)),liveSource:source)
        var initial=try CanvasDocument(width:2,height:1,layers:[layer]).admittingMetadataMutation()
        let charge=try #require(initial.metadataStorage).capacity
        let working=try LWFloatWorkingSet(limit:charge)
        initial.metadataStorage=try LWSourceMetadataStorage(bytes:charge,workingSet:working)
        let session=EditorSession();session.document=initial;session.activeLayerID=id;session.history.reset()
        let before=try #require(session.document),revision=session.history.currentRevision
        #expect(!session.runCommand(.visibility([id],false)))
        #expect(session.document == before && session.activeLayer?.isVisible == true)
        #expect(session.history.currentRevision == revision && session.history.undoCount == 0)
        #expect(session.commandRefusal != nil)
        #expect(throws:ProjectError.self) { try session.beginCommandInteraction(.opacity([id],0.5)) }
        #expect(session.commandInteraction == nil && session.document == before)
    }
    @Test func longRegisteredSourceHistoryTrimsTopologyWithoutAnAncestorLeaseChain() throws {
        let source=try node(original:URL(fileURLWithPath:"/history-generations.dng"),width:2,height:1),id=UUID()
        let layer=ImageLayer(id:id,asset:nil,name:"Protected",isVisible:true,transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)),liveSource:source)
        var initial=try CanvasDocument(width:2,height:1,layers:[layer]).admittingMetadataMutation()
        let working=try LWFloatWorkingSet(limit:8*1024*1024)
        let first=try #require(initial.metadataStorage).capacity
        initial.metadataStorage=try LWSourceMetadataStorage(bytes:first,workingSet:working)
        weak var earliest=initial.metadataStorage
        let session=EditorSession();session.document=initial;session.activeLayerID=id;session.history.reset()
        // Drop this independent original topology alias before the history trim.
        initial.metadataStorage=nil
        for _ in 0..<128 {
            #expect(session.runCommand(.visibility([id],nil)))
            #expect(session.activeLayer?.liveSource == source)
        }
        #expect(session.history.undoCount == 100);#expect(earliest == nil)
        let spare=try working.reserve(4*1024*1024);withExtendedLifetime(spare) {}
        let current=try #require(session.document).metadataStorage
        session.history.reset();#expect(session.history.undoCount == 0)
        #expect(session.document?.metadataStorage === current)
    }

}


extension LiveRawSourceTests {
    @Test(arguments:[LWSourceRetouchStroke.Kind.smear,.liquify])
    func retouchAdmissionChargesTheRetainedInitialPickup(_ kind:LWSourceRetouchStroke.Kind) throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        var source=try node(original:URL(fileURLWithPath:"/mathematical-reference.dng"),width:2,height:1)
        let before=try tiledFixture([SIMD4<Float>(2,-1,0.5,1),SIMD4(0,2,3,1)],width:2,workspace:workspace)
        let frame=try source.capturedFrame(transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)))
        let stroke=LWSourceRetouchStroke(sourceID:source.id,upstreamRevision:source.revision,captureFrame:frame,
            kind:kind,seed:1,healMode:.contentAware,sampleAllLayers:false,aligned:true,sampleAllLayersCompositeRevision:nil,
            blurRadius:0,radius:1,hardness:0.5,opacity:0.5,points:[CGPoint(x:1.5,y:0.5)],sourceOffset:.zero,
            color:[0,0,0,1],pointsAreDabs:true,sourceStart:CGPoint(x:0.5,y:0.5))
        try source.appendRetouch(stroke)
        let admission=try source.retouchAdmission(plane:before,workspace:workspace,operationScratchBytes:0)
        #expect(admission.maximumDabs == 2)
        #expect(try stroke.warpDabs == [CGPoint(x:0.5,y:0.5),CGPoint(x:1.5,y:0.5)])
        var missing=stroke;missing.sourceStart=nil
        expectInvalid { _ = try missing.admittedReplayPointCount() }
        var nonfinite=stroke;nonfinite.sourceStart=CGPoint(x:CGFloat.infinity,y:0.5)
        expectInvalid { _ = try nonfinite.admittedReplayPointCount() }
        #expect(try before.read(before.globalExtent).surface.pixels == [SIMD4<Float>(2,-1,0.5,1),SIMD4(0,2,3,1)])
    }
}


extension LiveRawSourceTests {
    @Test func capturedCancellationRefusesCachedPlaneTypedAndF64ReadsWithoutTaskCancellation() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        let plane=try ownedOnePixel(workspace), pixels=plane.sampler()
        #expect(try pixels.pixel(x:0,y:0) == SIMD4(3,-1,0.5,1))
        let store=try workspace.makeStateStore(format:.uint32,width:1,height:1)
        try store.write(.uint32(7),x:0,y:0);let reader=try store.commit().reader()
        if case .uint32(let value)=try reader.read(x:0,y:0) { #expect(value==7) }
        else { Issue.record("Typed cached state changed format") }
        let field=try LWFloatDoubleRows.create(width:1,height:1,workingSet:workspace.workingSet,
            directory:workspace.makeScratchDirectory(),fileOwner:workspace){ _ in [Double.pi] }
        let rows=LWFloatDoubleRows.Reader(field);#expect(try rows.row(0).values == [Double.pi])
        let provider=LWFloatPlaneImage(plane:plane)
        var bytes=[UInt8](repeating:0,count:16)
        try bytes.withUnsafeMutableBytes { _=try provider.copy(into:$0.baseAddress!,position:0,count:16) }
        workspace.cancellation.cancel()
        // All three caches are already populated. Refusal is the captured graph
        // signal, not the current thread's Task or a later filesystem read.
        #expect(throws:CancellationError.self){ _=try pixels.pixel(x:0,y:0) }
        #expect(throws:CancellationError.self){ _=try pixels.pixel(x:-1,y:0) }
        #expect(throws:CancellationError.self){ _=try reader.read(x:0,y:0) }
        #expect(throws:CancellationError.self){ _=try rows.row(0) }
        #expect(throws:CancellationError.self){ try bytes.withUnsafeMutableBytes { _=try provider.copy(into:$0.baseAddress!,position:0,count:16) } }
        #expect(throws:CancellationError.self){ try plane.forEachTile { (_:LWFloatRange) in Issue.record("Cancelled tile traversal advanced") } }
    }
}


extension LiveRawSourceTests {
    @Test func compactFloatBackingUsesBoundedTilesAndPreservesHiddenHDRAcrossSeams() throws {
        let root=try temporaryProjectFolder();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("reference.f32"),width=513,height=513
        func pixel(_ x:Int,_ y:Int)->SIMD4<Float>{SIMD4(Float(x)-200,Float(y)/3,Float(bitPattern:0x3f000001),(x+y)%7==0 ? 0 : 0.5)}
        do{
            let values=(0..<width*height).map{pixel($0%width,$0/width)}
            let encoded=try LWLinearSurface(width:width,height:height,pixels:values,maximumBytes:8*1024*1024).packageData(maximumFileBytes:8*1024*1024)
            try encoded.write(to:file,options:.withoutOverwriting)
        }
        let original=try Data(contentsOf:file),workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:8*1024*1024))
        let plane=try LWFloatLegacyArchive.read(from:file,maximumFileBytes:8*1024*1024,workspace:workspace)
        #expect(plane.width==width&&plane.height==height)
        let samples=try plane.read(LWFloatRange(x:254,y:254,width:5,height:5)).surface.pixels
        for i in samples.indices{for channel in 0..<4{#expect(samples[i][channel].bitPattern==pixel(254+i%5,254+i/5)[channel].bitPattern)}}
        #expect(try Data(contentsOf:file)==original)
    }
    @Test(arguments:["short","long","nonfinite","symlink","mutation"])
    func compactFloatBackingRejectsExactPayloadAndNamedCustodyFailure(_ fault:String)throws {
        let root=try temporaryProjectFolder();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("reference.f32")
        var bytes=try surface([SIMD4(2,-1,3,0),SIMD4(0.5,4,-3,1)]).packageData(maximumFileBytes:1024)
        if fault=="short"{bytes.removeLast()};if fault=="long"{bytes.append(0)}
        if fault=="nonfinite"{bytes.replaceSubrange(24..<28,with:[0,0,192,127])}
        try bytes.write(to:file,options:.withoutOverwriting)
        var selected=file
        if fault=="symlink"{selected=root.appendingPathComponent("alias.f32");try FileManager.default.createSymbolicLink(at:selected,withDestinationURL:file)}
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:8*1024*1024))
        do{
            _=try LWFloatLegacyArchive.read(from:selected,maximumFileBytes:1024,workspace:workspace,makeBuilder:{width,height in
                if fault=="mutation"{
                    var changed=bytes;changed[24]^=1;try changed.write(to:file)
                }
                return try workspace.makeBuilder(width:width,height:height)
            })
            Issue.record("Invalid compact float backing was published: \(fault)")
        }catch ProjectError.invalid {} // Exact production custody/payload branch.
        #expect(FileManager.default.fileExists(atPath:file.path))
    }
}


extension LiveRawSourceTests {
    @Test(arguments: ["backing", "cancel"])
    func floatQuickLookRefusesSourceFailureRatherThanPublishingAnAbsentPreview(_ fault: String) async throws {
        let root = try temporaryProjectFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let plane = try referencePlane(root, workingSet: .sourceGraphs)
        let id = UUID(), asset = try ImportedImage(plane: plane, name: "Reference")
        let manifest = ProjectManifest(documentID: UUID(), width: plane.width, height: plane.height, activeLayerID: id, layers: [
            ProjectLayerRecord(id: id, name: "Reference", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: plane.width, height: plane.height)),
                imageFile: id.uuidString + ".plane", planeArchiveReference: asset.planeArchiveReference)])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [id: asset])
        let prior = try await ImageExporter.shared.quickLookImages(snapshot)
        #expect(try #require(prior).preview.count > 0)
        if fault == "backing" {
            let tile = root.appendingPathComponent("ReferenceTiles/00000000.f32")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tile.path)
            var bytes = try Data(contentsOf: tile); bytes[0] ^= 1
            try bytes.write(to: tile); try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tile.path)
            await #expect(throws: ProjectError.self) { _ = try await ImageExporter.shared.quickLookImages(snapshot) }
        } else {
            let task = Task { @MainActor in
                while !Task.isCancelled { await Task.yield() }
                return try await ImageExporter.shared.quickLookImages(snapshot)
            }
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled float preview was treated as absent") }
            catch is CancellationError {} catch { Issue.record("Unexpected float preview cancellation error: \(error)") }
        }
    }
}


extension LiveRawSourceTests {
    @Test func chargedThumbnailKeepsItsLeaseThroughIndependentCGImageRetention() throws {
        let original = try PixelAdjust.thumbnail(of: surface([SIMD4(0.2, 0.3, 0.4, 1), SIMD4(0.8, 0.7, 0.6, 0.5)]).cgImage())
        let working = try LWFloatWorkingSet(limit: 256 * 1024)
        var retained: CGImage? = try LWFloatThumbnail.owned(original, workingSet: working)
        let charge = original.bytesPerRow * original.height + 1024
        var available: LWFloatWorkingSet.Lease? = try working.reserve(working.limit - charge)
        #expect(throws: ProjectError.self) { _ = try working.reserve(1) }
        let copy = try #require(retained?.dataProvider?.data)
        #expect(CFEqual(copy, try #require(original.dataProvider?.data)))
        available = nil
        var imageAlias = retained; retained = nil
        #expect(throws: ProjectError.self) { _ = try working.reserve(working.limit) }
        #expect(imageAlias?.width == original.width)
        imageAlias = nil
        _ = try working.reserve(working.limit)
    }
}


extension LiveRawSourceTests {
    @Test(arguments: ["hardLink", "parentAlias"])
    func sourcesDataRejectsUnownedLinkAndRedirectedParentBeforeReservation(_ fault: String) throws {
        let root = try temporaryProjectFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.data")
        try Data([1, 2, 3, 4]).write(to: file, options: .withoutOverwriting)
        let working = try LWFloatWorkingSet(limit: 8192)
        let target: URL
        if fault == "hardLink" {
            let alias = root.appendingPathComponent("linked.data")
            try FileManager.default.linkItem(at: file, to: alias); target = file
        } else {
            let alias = root.appendingPathComponent("parent-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            target = alias.appendingPathComponent("source.data")
        }
        #expect(throws: ProjectError.self) { _ = try LWSourceOwnedData.read(target, maximumBytes: 4, workingSet: working) }
        let all = try working.reserve(8192); withExtendedLifetime(all) {}
        #expect(try Data(contentsOf: file) == Data([1, 2, 3, 4]))
    }
}


extension LiveRawSourceTests {
    @Test(arguments: ["unknown", "replacement"])
    func finalWorkspaceFailureRetainsTheExactRosterAndBlocksReadmissionUntilRetry(_ fault: String) throws {
        let working = try LWFloatWorkingSet(limit: 8 * 1024 * 1024)
        var workspace: LWFloatWorkspace? = try LWFloatWorkspace(workingSet: working)
        let directory = try #require(workspace).directory
        do { _ = try ownedOnePixel(try #require(workspace)) }
        let child = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let file = child.appendingPathComponent("00000000.f32")
        let unexpected = child.appendingPathComponent("unexpected.txt")
        let displaced = child.appendingPathComponent("held-original.f32")
        if fault == "unknown" { try Data("must survive".utf8).write(to: unexpected, options: .withoutOverwriting) }
        else {
            try FileManager.default.moveItem(at: file, to: displaced)
            try Data([0]).write(to: file, options: .withoutOverwriting)
        }
        workspace = nil
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: ProjectError.self) { _ = try LWFloatWorkspace(workingSet: working) }
        #expect(throws: ProjectError.self) { _ = try working.reserve(working.limit) }
        if fault == "unknown" {
            #expect(try Data(contentsOf: unexpected) == Data("must survive".utf8))
            try FileManager.default.removeItem(at: unexpected)
        } else {
            #expect(try Data(contentsOf: file) == Data([0]))
            #expect(FileManager.default.fileExists(atPath: displaced.path))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: displaced, to: file)
        }
        // Exact original bytes/inode are restored by this test's own action.
        // Replacement changed ctime, so it cannot be silently adopted by retry.
        if fault == "replacement" {
            #expect(throws: ProjectError.self) { try LWFloatWorkspace.retryRetainedCleanup(admitting: working) }
            try FileManager.default.removeItem(at: directory)
        }
        try LWFloatWorkspace.retryRetainedCleanup(admitting: working)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        _ = try working.reserve(working.limit)
    }
    @Test(arguments: ["missing", "string", "unknown"])
    func documentRawAdmissionIsARequiredStrictAuthorityField(_ fault:String) throws {
        let original=URL(fileURLWithPath:"/source.nrw")
        let value=try node(original:original,width:2,height:2)
        let request=try value.request(id:UUID())
        var object=try #require(JSONSerialization.jsonObject(with:LWCatalogCodec.encode(request)) as? [String:Any])
        switch fault { case "missing":object.removeValue(forKey:"raw_hint")
        case "string":object["raw_hint"]="true"
        default:object["unexpected"]=true }
        #expect(throws:Error.self) { try LWCatalogCodec.decode(LWDocumentSourceDevelopment.self,from:JSONSerialization.data(withJSONObject:object)) }
    }
    @Test
    func rawTypeAdmissionSurvivesSourceHistorySerializationWithoutRequeryingFilename() throws {
        let value=try node(original:URL(fileURLWithPath:"/source.nrw"),width:2,height:2)
        var object=try #require(JSONSerialization.jsonObject(with:LWCatalogCodec.encode(value)) as? [String:Any])
        object["rawHint"]=true
        let stored=try LWSourceMetadataStorage.decode(LWLiveSourceNode.self,from:JSONSerialization.data(withJSONObject:object))
        let restored=try LWSourceMetadataStorage.decode(LWLiveSourceNode.self,from:LWCatalogCodec.encode(stored.value))
        #expect(restored.value==stored.value);#expect(restored.value.rawHint)
        #expect(try restored.value.request(id:UUID()).raw_hint)
        object.removeValue(forKey:"rawHint")
        #expect(throws:Error.self) { try LWSourceMetadataStorage.decode(LWLiveSourceNode.self,from:JSONSerialization.data(withJSONObject:object)) }
    }

}


extension LiveRawSourceTests {
    @Test
    func failedWorkspaceInitializationRetainsBirthAndNeverDeletesAnUnexpectedMember() throws {
        enum Injected: Error { case afterCreate }
        let working = try LWFloatWorkingSet(limit: 8192)
        var original: URL?
        #expect(throws: Injected.self) {
            _ = try LWFloatWorkspace(workingSet: working, afterCreated: { directory in
                original = directory
                try Data("must survive".utf8).write(to: directory.appendingPathComponent("unexpected.txt"), options: .withoutOverwriting)
                throw Injected.afterCreate
            })
        }
        let root = try #require(original), member = root.appendingPathComponent("unexpected.txt")
        #expect(throws: ProjectError.self) { _ = try LWFloatWorkspace(workingSet: working) }
        #expect(throws: ProjectError.self) { _ = try working.reserve(working.limit) }
        #expect(try Data(contentsOf: member) == Data("must survive".utf8))
        try FileManager.default.removeItem(at: member)
        try LWFloatWorkspace.retryRetainedCleanup(admitting: working)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        _ = try working.reserve(working.limit)
    }
}


extension LiveRawSourceTests {
    @Test
    func canceledFinalWorkspaceOwnerRetainsItsRosterUntilANoncanceledCheckedRetry() async throws {
        let working = try LWFloatWorkingSet(limit: 8 * 1024 * 1024)
        let operation = Task { @MainActor () throws -> URL in
            var owner: LWFloatWorkspace? = try LWFloatWorkspace(workingSet: working)
            let directory = try #require(owner).directory
            do { _ = try ownedOnePixel(try #require(owner)) }
            withUnsafeCurrentTask { $0?.cancel() }
            owner = nil
            return directory
        }
        let directory = try await operation.value
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: ProjectError.self) { _ = try working.reserve(working.limit) }
        try LWFloatWorkspace.retryRetainedCleanup(admitting: working)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        _ = try working.reserve(working.limit)
    }
}


extension LiveRawSourceTests {
    @Test(arguments:["original","ancestor","hardLink"])
    func directRawSaveAndPNGRefuseToReplaceCurrentOrHistoricalOriginals(_ fault:String) async throws {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        let original=directory.appendingPathComponent("source.nrw"), bytes=Data([1,2,3,4])
        try bytes.write(to:original,options:.withoutOverwriting)
        let source=try node(original:original,width:2,height:2)
        let project=ProjectSnapshot(manifest:manifest(source),images:[:],masks:[:])
        let current=project;var destination=original
        if fault == "ancestor" { destination=directory }
        if fault == "hardLink" { destination=directory.appendingPathComponent("alias.png");try FileManager.default.linkItem(at:original,to:destination) }
        #expect(throws:ProjectError.self) { try LWSourceDestinationAuthority(current).validate(destination) }
        // Both real public writers refuse before allocating/staging publication.
        await #expect(throws:ProjectError.self) { try await ProjectStore.shared.save(current,to:destination) }
        await #expect(throws:ProjectError.self) { try await ImageExporter.shared.exportPNG(current,to:destination) }
        #expect(try Data(contentsOf:original)==bytes)
        #expect(FileManager.default.fileExists(atPath:directory.path))
    }
}


extension LiveRawSourceTests {
    @Test
    func encodedJPEGKeepsSourceProtectionThroughItsFinalPublicationOwner() async throws {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        let original=directory.appendingPathComponent("source.raw"),bytes=Data([1,2,3,4])
        try bytes.write(to:original,options:.withoutOverwriting)
        let source=try node(original:original,width:2,height:2)
        let authority=try LWSourceDestinationAuthority(ProjectSnapshot(manifest:manifest(source),images:[:],masks:[:]))
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs),plane=try ownedOnePixel(workspace)
        let provider=LWFloatPlaneImage(plane:plane),image=try provider.image()
        let raster=ExportRaster(image:image,resolution:72,linearPlane:plane,planeImage:provider,sourceProtection:authority)
        let encoded=try await ImageExporter.shared.jpegFile(raster,options:JPEGOptions())
        #expect(encoded.file.byteCount>0)
        await #expect(throws:ProjectError.self) { try await ImageExporter.shared.write(encoded.file,to:original) }
        #expect(try Data(contentsOf:original)==bytes)
        let legitimate=directory.appendingPathComponent("output.jpg")
        try await ImageExporter.shared.write(encoded.file,to:legitimate)
        #expect(try Data(contentsOf:legitimate)==encoded.file.data())
        #expect(try Data(contentsOf:original)==bytes)
    }
}


extension LiveRawSourceTests {
    @Test func sourceCacheProjectionRefusesItsOwnCollectionChargeWithoutPublishing() throws {
        var source=try node(original:URL(fileURLWithPath:"/cache-admission.dng"),width:2,height:1)
        let coverage=try surface([SIMD4(repeating:1),SIMD4.zero]).packageData(maximumFileBytes:1024)
        source=try source.metadataCopy(additionalBytes:64*1024)
        source.selectedDevelopments=[.init(settings:CameraRawSettings(),whiteBalance:.asShot,seed:1,sourceCoverage:coverage)]
        let packed=try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:16*1024)
        let set=try LWFloatWorkingSet(limit:1),cache=LWSourcePackageArchive.HydrationCache(workingSet:set)
        let name=try #require(packed.manifest.layers[0].liveSourceFile)
        #expect(throws:ProjectError.self) { try LWSourcePackageArchive.hydrate(packed.manifest,
            read:{ path,_ in try #require(packed.assets[path]) },cache:cache) }
        #expect(cache.entry(name)==nil)
        let all=try set.reserve(1);withExtendedLifetime(all) {}
    }
    @Test func sourceCacheHitRechecksDeclaredBackingBeforePublishingSharedNode() throws {
        var source=try node(original:URL(fileURLWithPath:"/cache-custody.dng"),width:2,height:1)
        let coverage=try surface([SIMD4(repeating:1),SIMD4.zero]).packageData(maximumFileBytes:1024)
        source=try source.metadataCopy(additionalBytes:64*1024)
        source.selectedDevelopments=[.init(settings:CameraRawSettings(),whiteBalance:.asShot,seed:1,sourceCoverage:coverage)]
        let packed=try LWSourcePackageArchive.externalize(manifest(source),maximumBytes:16*1024)
        let missing=try #require(packed.assets.first(where:{$0.key.hasSuffix(".data")})).key
        let set=try LWFloatWorkingSet(limit:32*1024)
        var cache:LWSourcePackageArchive.HydrationCache?=LWSourcePackageArchive.HydrationCache(workingSet:set)
        let opened=try LWSourcePackageArchive.hydrate(packed.manifest,
            read:{ path,_ in try #require(packed.assets[path]) },cache:try #require(cache))
        #expect(opened.layers[0].liveSource==source)
        #expect(throws:ProjectError.self) { try LWSourcePackageArchive.hydrate(packed.manifest,
            read:{ path,_ in guard path != missing,let data=packed.assets[path] else { throw ProjectError.missingImage };return data },
            cache:try #require(cache)) }
        #expect(throws:ProjectError.self) { try set.reserve(32*1024) }
        cache=nil
        let all=try set.reserve(32*1024);withExtendedLifetime(all) {}
    }
}


extension LiveRawSourceTests {
    @Test func derivedSourceMapRefusesBeforeStageProjectionWithoutAvailableAdmission() throws {
        var source=try node(original:URL(fileURLWithPath:"/derived-admission.dng"),width:2,height:1)
        let set=try LWFloatWorkingSet(limit:source.retainedPayloadBytes)
        source.metadataStorage=try LWSourceMetadataStorage(bytes:source.retainedPayloadBytes,workingSet:set)
        #expect(throws:ProjectError.self) { _=try source.currentSpatialMap }
        #expect(throws:ProjectError.self) { _=try source.capturedFrame(transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1))) }
    }
    @Test func capturedSourceFrameRetainsDerivedMetadataThroughAnIndependentMapAlias() throws {
        let source=try node(original:URL(fileURLWithPath:"/derived-owner.dng"),width:2,height:1)
        var frame:LWSourceRetouchFrame?=try source.capturedFrame(transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)))
        weak var owner=frame?.metadataStorage
        var map:LWSourceSpatialMap?=frame?.spatialMap
        frame=nil;#expect(owner != nil)
        #expect(try #require(map).sourcePoint(CGPoint(x:0.5,y:0.5))==CGPoint(x:0.5,y:0.5))
        map=nil;#expect(owner == nil)
    }
}


extension LiveRawSourceTests {
    @Test func completedGraphScopeCollectsOnlyReleasedIntermediatesAndKeepsOutputReader() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        func graph() throws -> LWFloatPlane {
            let input=try tiledFixture([SIMD4(4,-1,2,1),SIMD4(2,3,4,1)],width:2,workspace:workspace)
            let first=try LWFloatCompositor.map(input,workspace:workspace) { p,_,_ in p*SIMD4(2,2,2,1) }
            return try LWFloatCompositor.map(first,workspace:workspace) { p,_,_ in p+SIMD4(1,0,0,0) }
        }
        var output:LWFloatPlane?=try graph()
        let sampler=try #require(output).sampler()
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath:workspace.directory.path).count==1)
        #expect(try sampler.pixel(x:0,y:0)==SIMD4(9,-2,4,1))
        #expect(try workspace.retireOwnedPlane(&output)==false)
        #expect(try sampler.pixel(x:1,y:0)==SIMD4(5,6,8,1))
    }
}


extension LiveRawSourceTests {
    private func jpegPreviewFixture(height:Int) throws -> CGImage {
        guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:8,height:height,
            bitsPerComponent:8,bytesPerRow:32,space:color,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw ProjectError.invalid }
        for y in 0..<height { for x in 0..<8 {
            context.setFillColor(CGColor(colorSpace:color,components:[CGFloat(x)/7,CGFloat(y)/CGFloat(max(1,height-1)),CGFloat((x+y)%3)/2,1])!)
            context.fill(CGRect(x:x,y:y,width:1,height:1))
        } }
        return try #require(context.makeImage())
    }
    private func normalizedJPEGPreview(_ image:CGImage) throws -> Data {
        guard let color=CGColorSpace(name:CGColorSpace.sRGB) else { throw ProjectError.invalid }
        var data=Data(count:image.width*image.height*4)
        try data.withUnsafeMutableBytes { raw in
            guard let context=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,
                bytesPerRow:image.width*4,space:color,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw ProjectError.invalid }
            context.setBlendMode(.copy);context.interpolationQuality = .none
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return data
    }
    @Test(arguments:[64,129])
    func jpegPreviewRowsMatchWholeEncodedDomainReferenceAcrossChunkBoundaries(_ height:Int) throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        let input=try jpegPreviewFixture(height:height)
        let owned=try LWJPEGPreviewImage.materialize(input,workspace:workspace,validate:{})
        #expect(try owned.file.data()==normalizedJPEGPreview(input))
        let shown=try owned.image();try owned.check()
        #expect(try normalizedJPEGPreview(shown)==normalizedJPEGPreview(input))
        #expect(owned.file.byteCount==8*height*4)
    }
    @Test func jpegPreviewProviderKeepsOwnedByteGenerationThroughIndependentImageAlias() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        var owner:LWJPEGPreviewImage?=try LWJPEGPreviewImage.materialize(jpegPreviewFixture(height:3),workspace:workspace,validate:{})
        weak var retained=owner
        var image:CGImage?=try owner?.image()
        owner=nil;#expect(retained != nil)
        #expect(try normalizedJPEGPreview(try #require(image)).count==8*3*4)
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath:workspace.directory.path).count==1)
        image=nil;#expect(retained == nil)
        try workspace.retireReleasedGenerations()
        #expect(try FileManager.default.contentsOfDirectory(atPath:workspace.directory.path).isEmpty)
    }
    @Test(arguments:["cancel","mutate"])
    func jpegPreviewCallbackFailureRemainsStickyAtItsPublicationConsumer(_ fault:String) throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        defer { try? FileManager.default.removeItem(at:workspace.directory) }
        let owner=try LWJPEGPreviewImage.materialize(jpegPreviewFixture(height:3),workspace:workspace,validate:{})
        let image=try owner.image()
        if fault == "cancel" { workspace.cancellation.cancel() }
        else {
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:owner.file.url.path)
            let output=try FileHandle(forWritingTo:owner.file.url);try output.write(contentsOf:Data([0]));try output.close()
        }
        // Actual provider read triggers its bounded failure path, not a mirrored
        // predicate; the same consumer check used by the sheet/export must reject.
        _=image.dataProvider?.data
        #expect(throws:Error.self) { try owner.check() }
        #expect(throws:Error.self) { try owner.check() }
    }
    @Test func publicJPEGPreviewMatchesTheActualEncodedFileAndOwnsItsDisplayGeneration() async throws {
        let input=try jpegPreviewFixture(height:129),raster=ExportRaster(image:input,resolution:72)
        let result=try await ImageExporter.shared.jpegFile(raster,options:JPEGOptions(quality:0.73))
        try result.check()
        let source=try #require(CGImageSourceCreateWithURL(result.file.url as CFURL,nil))
        let expected=try #require(CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceThumbnailMaxPixelSize:129,kCGImageSourceShouldCacheImmediately:true,
            kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary))
        #expect(try normalizedJPEGPreview(result.preview)==normalizedJPEGPreview(expected))
        #expect(result.previewOwner.file.byteCount==result.preview.width*result.preview.height*4)
        try result.check()
    }
}


extension LiveRawSourceTests {
    @Test func sourcePublicationRejectsRecordedHardLinkAfterOriginalNameReplacement() throws {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        let original=directory.appendingPathComponent("original.raw"),alias=directory.appendingPathComponent("retained-alias.jpg")
        let bytes=Data([1,2,3,4]);try bytes.write(to:original,options:.withoutOverwriting)
        var stat=Darwin.stat();guard original.path.withCString({lstat($0,&stat)})==0 else { throw ProjectError.invalid }
        let source=try node(original:original,width:2,height:2,identity:.init(first:LWCatalogU64(UInt64(stat.st_dev)),second:LWCatalogU64(UInt64(stat.st_ino))))
        let authority=try LWSourceDestinationAuthority(ProjectSnapshot(manifest:manifest(source),images:[:],masks:[:]))
        try FileManager.default.linkItem(at:original,to:alias)
        try FileManager.default.removeItem(at:original);try Data([5,6,7,8]).write(to:original,options:.withoutOverwriting)
        #expect(throws:ProjectError.self) { try authority.validate(alias) }
        #expect(try Data(contentsOf:alias)==bytes)
        #expect(try Data(contentsOf:original)==Data([5,6,7,8]))
    }
}



extension LiveRawSourceTests {
    @Test func canvasProjectionRefusesBeforeCopyOnWriteAndKeepsOriginalManifest() throws {
        let source=try node(original:URL(fileURLWithPath:"/mathematical-reference.raw"),width:2,height:2)
        let original=ProjectSnapshot(manifest:manifest(source),images:[:])
        let set=try LWFloatWorkingSet(limit:1)
        #expect(throws:ProjectError.self) { _=try original.metadataProjection(workingSet:set) }
        #expect(original.manifest.metadataStorage == nil)
        #expect(original.manifest.layers[0].liveSource == source)
    }
    @Test func canvasProjectionRetainsItsContainerChargeThroughIndependentManifestCopy() throws {
        let set=try LWFloatWorkingSet(limit:128*1024)
        var projected:ProjectSnapshot?=try ProjectSnapshot(manifest:ProjectManifest(documentID:UUID(),width:2,height:2,
            activeLayerID:nil,layers:[]),images:[:]).metadataProjection(workingSet:set)
        var retained:ProjectManifest?=projected?.manifest
        projected=nil
        #expect(throws:ProjectError.self) { _=try set.reserve(set.limit) }
        #expect(retained?.width==2)
        retained=nil
        let released=try set.reserve(set.limit);withExtendedLifetime(released) {}
    }
    nonisolated private struct EncodingPayload:Codable {
        let text:String
        let data:Data
        let values:[Double]
        let identities:[String:UUID]
    }
    nonisolated private final class EncodingVisits:@unchecked Sendable { var count=0 }
    nonisolated private struct EncodingProbe:Encodable {
        let visits:EncodingVisits
        let text:String
        func encode(to encoder:any Encoder) throws {
            visits.count+=1
            var value=encoder.singleValueContainer();try value.encode(text)
        }
    }
    @Test(arguments:[false,true])
    func sourceEncodingKeepsFoundationWireAndChargedRetainedBytes(pretty:Bool) throws {
        let set=try LWFloatWorkingSet(limit:8*1024*1024)
        let payload=EncodingPayload(text:"HDR \\ \" α /\n",data:Data([0,255,17,34]),values:[-2.5,0,4.75],identities:["source":UUID()])
        let formatting:JSONEncoder.OutputFormatting=pretty ? [.prettyPrinted,.sortedKeys]:[.sortedKeys]
        let reference=JSONEncoder();reference.outputFormatting=formatting
        let expected=try reference.encode(payload)
        var owned:LWSourceOwnedData?=try LWSourceMetadataStorage.encode(payload,maximumBytes:4*1024*1024,workingSet:set,formatting:formatting)
        #expect(try #require(owned).bytes.elementsEqual(expected))
        weak var weakOwner=owned?.owner
        var publication:LWSourceOwnedData?=owned
        owned=nil
        #expect(weakOwner != nil);#expect(try #require(publication).bytes.elementsEqual(expected))
        #expect(throws:ProjectError.self) { _=try set.reserve(set.limit) }
        publication=nil
        #expect(weakOwner==nil)
        let released=try set.reserve(set.limit);withExtendedLifetime(released) {}
    }
    @Test func sourceEncodingRefusesBeforeFoundationSerializationWhenSharedAdmissionCannotFit() throws {
        let set=try LWFloatWorkingSet(limit:64*1024),visits=EncodingVisits()
        let value=EncodingProbe(visits:visits,text:String(repeating:"x",count:128*1024))
        #expect(throws:ProjectError.self) { _=try LWSourceMetadataStorage.encode(value,maximumBytes:4*1024*1024,workingSet:set) }
        // The one source visitor ran; the second JSONEncoder visit never started.
        #expect(visits.count==1)
        let released=try set.reserve(set.limit);withExtendedLifetime(released) {}
    }
    @Test func sourceEncodingPreservesWireCapAndReleasesFailedPublicationCharge() throws {
        let set=try LWFloatWorkingSet(limit:8*1024*1024)
        #expect(throws:ProjectError.self) { _=try LWSourceMetadataStorage.encode(String(repeating:"x",count:1024),maximumBytes:128,workingSet:set) }
        let released=try set.reserve(set.limit);withExtendedLifetime(released) {}
    }
    @Test func headerDecodeChargeRefusesBeforeDecoderAndRetiresOnThrow() throws {
        let input=Data("{\"format\":\"com.compositor.project\",\"version\":14}".utf8)
        let set=try LWFloatWorkingSet(limit:32*1024)
        var held:LWFloatWorkingSet.Lease?=try set.reserve(set.limit-1024)
        var invoked=false
        #expect(throws:ProjectError.self) { _=try LWSourceMetadataStorage.withDecodeCharge(from:input,workingSet:set) { invoked=true;return 0 } }
        #expect(!invoked);withExtendedLifetime(held) {};held=nil
        #expect(throws:ProjectError.self) { let _:Int=try LWSourceMetadataStorage.withDecodeCharge(from:input,workingSet:set) { throw ProjectError.invalid } }
        let released=try set.reserve(set.limit);withExtendedLifetime(released) {}
    }

}


extension LiveRawSourceTests {
    @Test func admittedLinearCompatibilityRefusesBeforeAllocationAndKeepsCallerLimit() throws {
        let set = try LWFloatWorkingSet(limit: 64)
        var allocated = false
        #expect(throws: ProjectError.self) {
            _ = try LWLinearSurface.admitted(width: 5, height: 1, maximumBytes: 64, workingSet: set) { _ in
                allocated = true; return .zero
            }
        }
        #expect(!allocated)
        let held = try set.reserve(64)
        #expect(throws: ProjectError.self) {
            _ = try LWLinearSurface.admitted(width: 1, height: 1, maximumBytes: 16, workingSet: set) { _ in
                allocated = true; return .zero
            }
        }
        #expect(!allocated); withExtendedLifetime(held) {}
    }
    @Test func admittedLinearCompatibilityRetainsChargeThroughPixelStorageAlias() throws {
        let set = try LWFloatWorkingSet(limit: 32)
        var value: LWSourceOwnedLinearSurface? = try LWLinearSurface.admitted(width: 2, height: 1, maximumBytes: 32, workingSet: set) { index in
            index == 0 ? SIMD4(4,-2,1,1):SIMD4(1,2,3,0.5)
        }
        var alias = value
        var escaped:LWSourceOwnedLinearSurface.Pixels?=value?.pixels
        var slice:Slice<LWSourceOwnedLinearSurface.Pixels>?=value?.pixels[0..<1]
        value = nil
        #expect(alias?.workingSet === set); #expect(alias?.maximumBytes == 32)
        #expect(alias?.pixels[0] == SIMD4(4,-2,1,1))
        #expect(throws: ProjectError.self) { _ = try set.reserve(1) }
        alias = nil
        #expect(escaped?[1] == SIMD4(1,2,3,0.5))
        #expect(throws:ProjectError.self) { _=try set.reserve(1) }
        escaped=nil
        #expect(slice?.first == SIMD4(4,-2,1,1))
        #expect(throws:ProjectError.self) { _=try set.reserve(1) }
        slice=nil
        let released = try set.reserve(32); withExtendedLifetime(released) {}
    }
    @Test func admittedLinearCompatibilityRetiresFailedAllocationCharge() throws {
        let set = try LWFloatWorkingSet(limit: 32)
        #expect(throws: ProjectError.self) {
            _ = try LWLinearSurface.admitted(width: 2, height: 1, maximumBytes: 32, workingSet: set) { _ in throw ProjectError.invalid }
        }
        let released = try set.reserve(32); withExtendedLifetime(released) {}
    }
    @Test func admittedLinearMutationReservesDistinctStorageBeforeCallback() throws {
        let set=try LWFloatWorkingSet(limit:64)
        var original:LWSourceOwnedLinearSurface?=try LWLinearSurface.admitted(width:2,height:1,maximumBytes:32,workingSet:set) { _ in SIMD4(4,-2,1,1) }
        var changed:LWSourceOwnedLinearSurface?=try original?.replacingPixels { _,pixel in pixel+SIMD4(1,0,0,0) }
        #expect(original?.pixels[0] == SIMD4(4,-2,1,1));#expect(changed?.pixels[0] == SIMD4(5,-2,1,1))
        var invoked=false
        #expect(throws:ProjectError.self) { _=try original?.replacingPixels { _,pixel in invoked=true;return pixel } }
        #expect(!invoked)
        changed=nil
        let freed=try set.reserve(32);withExtendedLifetime(freed) {}
        original=nil
    }
    @Test func admittedLinearFrameworkImageRetainsExactPixelAllocation() throws {
        let set=try LWFloatWorkingSet(limit:32)
        var value:LWSourceOwnedLinearSurface?=try LWLinearSurface.admitted(width:2,height:1,maximumBytes:32,workingSet:set) { index in SIMD4(Float(index)+2,-1,0.5,1) }
        var image:CGImage?=try value?.cgImage()
        value=nil
        #expect(image?.bitsPerComponent == 32 && image?.width == 2)
        #expect(throws:ProjectError.self) { _=try set.reserve(1) }
        image=nil
        let released=try set.reserve(32);withExtendedLifetime(released) {}
    }
    @Test func tileSamplesOutliveTileOnlyWithTheirExactAllocationCharge() throws {
        let working=try LWFloatWorkingSet(limit:16*1024*1024),workspace=try LWFloatWorkspace(workingSet:working)
        let plane=try tiledFixture([SIMD4(4,-2,1,1),SIMD4(1,2,3,0.5)],width:2,workspace:workspace)
        let baseline=working.retainedBytes
        var tile:LWFloatTile?=try plane.read(plane.globalExtent)
        #expect(working.retainedBytes == baseline+32)
        var surface:LWSourceOwnedLinearSurface?=tile?.surface
        var samples:LWSourceOwnedLinearSurface.Pixels?=surface?.pixels
        tile=nil;surface=nil
        #expect(samples?[0] == SIMD4(4,-2,1,1))
        #expect(working.retainedBytes == baseline+32)
        let held=try working.reserve(working.limit-baseline-32)
        #expect(throws:ProjectError.self) { _=try working.reserve(1) }
        samples=nil
        #expect(working.retainedBytes == working.limit-32)
        let released=try working.reserve(32);withExtendedLifetime((held,released)) {}
    }
    @Test func tileMutationUsesDistinctOwnedStorageAndRefusesUnadmittedCopies() throws {
        let working=try LWFloatWorkingSet(limit:16*1024*1024),workspace=try LWFloatWorkspace(workingSet:working)
        let plane=try tiledFixture([SIMD4(4,-2,1,1),SIMD4(1,2,3,0.5)],width:2,workspace:workspace)
        let tile=try plane.read(plane.globalExtent)
        let before=working.retainedBytes
        var next:LWSourceOwnedLinearSurface?=try tile.surface.replacingPixels { _,pixel in pixel+SIMD4(1,0,0,0) }
        #expect(working.retainedBytes == before+32)
        #expect(next?.pixels[0] == SIMD4(5,-2,1,1));#expect(tile.surface.pixels[0] == SIMD4(4,-2,1,1))
        let held=try working.reserve(working.limit-working.retainedBytes)
        var invoked=false
        #expect(throws:ProjectError.self) { _=try tile.surface.replacingPixels { _,pixel in invoked=true;return pixel } }
        #expect(!invoked)
        next=nil
        let released=try working.reserve(32);withExtendedLifetime((held,released)) {}
    }
    @Test func confirmedSourceCloseJoinsActualPreviewBeforeReleaseAndAllowsCheckedRetry() async throws {
        let session = EditorSession()
        session.createNewProject(width:2,height:2)
        let before = session.document, revision = session.history.currentRevision
        var continuation: CheckedContinuation<Void,Never>?
        var finished = false
        let task = try session.makeSourcePreviewTask {
            await withCheckedContinuation { continuation = $0 }
            finished = true
        }
        while continuation == nil { await Task.yield() }
        do {
            try await session.releaseConfirmedSourceProject(deadline: ContinuousClock.now)
            Issue.record("An unfinished source preview was accepted as drained")
        } catch { #expect(error is LWSourceCleanupFailure) }
        #expect(session.sourceClosePending && session.retainedSourcePreviewCount == 1 && !finished)
        #expect(session.document == before && session.history.currentRevision == revision)
        #expect(!session.canStartProjectOperation)
        #expect(throws: CancellationError.self) { _ = try session.makeSourcePreviewTask {} }
        continuation?.resume(); continuation = nil
        await task.value
        #expect(finished && session.retainedSourcePreviewCount == 0)
        try await session.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        try session.finishConfirmedSourceRetirement(protectedOwners: [])
        #expect(session.document == nil && !session.canStartProjectOperation)
    }
    @Test func confirmedSourceCloseRefusesLiveBackingAliasAndRetiresOnlyAfterActualRelease() async throws {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs), session = EditorSession()
        let source = try node(original: URL(fileURLWithPath: "/close-reference.dng"), width: 2, height: 1)
        var plane: LWFloatPlane? = try tiledFixture([SIMD4(4,-1,2,1), SIMD4(2,3,4,0.5)], width: 2, workspace: workspace)
        session.installProject(try floatProject(source,plane:try #require(plane),transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1))),
            from: URL(fileURLWithPath: "/close-reference.comp"))
        try await session.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        #expect(session.document == nil && !session.history.canUndo)
        #expect(throws: ProjectError.self) { try session.finishConfirmedSourceRetirement(protectedOwners: []) }
        #expect(FileManager.default.fileExists(atPath: workspace.directory.path))
        #expect(try plane?.read(.init(x:0,y:0,width:1,height:1)).surface.pixels.first == SIMD4(4,-1,2,1))
        plane = nil
        try session.finishConfirmedSourceRetirement(protectedOwners: [])
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    }
    @Test func confirmedSourceClosePreservesRootTransferredToAnotherDocumentUntilFinalClose() async throws {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs), first = EditorSession(), second = EditorSession()
        let source = try node(original: URL(fileURLWithPath: "/shared-close.dng"), width: 2, height: 1)
        do {
            let plane = try tiledFixture([SIMD4(4,-1,2,1),SIMD4(2,3,4,1)],width:2,workspace:workspace)
            let snapshot = try floatProject(source,plane:plane,transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)))
            first.installProject(snapshot,from:URL(fileURLWithPath:"/first.comp"))
            second.installProject(snapshot,from:URL(fileURLWithPath:"/second.comp"))
        }
        try await first.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by:.seconds(30)))
        let protected = try second.sourceWorkspaceOwners()
        try first.finishConfirmedSourceRetirement(protectedOwners: [protected])
        #expect(second.document != nil && FileManager.default.fileExists(atPath:workspace.directory.path))
        try await second.releaseConfirmedSourceProject(deadline: ContinuousClock.now.advanced(by:.seconds(30)))
        try second.finishConfirmedSourceRetirement(protectedOwners: [])
        #expect(!FileManager.default.fileExists(atPath:workspace.directory.path))
    }
}

extension LiveRawSourceTests {
    @Test(arguments:[AdjustmentKind.hsv,.levels])
    func retainedDialogAdjustmentUsesOrderedFloatSelectionAndReopensExactSource(_ kind:AdjustmentKind) throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let values:[SIMD4<Float>]=[SIMD4(4,-2,1,1),SIMD4(0.25,0.5,0.75,0.5),SIMD4(0.75,0.25,0.5,1),SIMD4(9,-3,2,0)]
        let before=try tiledFixture(values,width:4,workspace:workspace)
        let source=try node(original:URL(fileURLWithPath:"/retained-dialog-reference.dng"),width:4,height:1)
        let transform=LayerTransform(origin:.zero,size:CGSize(width:4,height:1))
        let mask=try BrushRaster.context(width:2,height:1,mask:true)
        mask.setFillColor(gray:1,alpha:1);mask.fill(CGRect(x:0,y:0,width:2,height:1))
        let selection=SelectionClip(rect:CGRect(x:1,y:0,width:2,height:1),coverage:try #require(mask.makeImage()))
        var settings=LayerAdjustment(kind:kind)
        if kind == .hsv { settings.hsvSettings=HueSaturationSettings(hue:45,saturation:20) }
        else { settings.levels.ranges[0].gamma=2 }
        let map=try source.currentSpatialMap
        let made=try LWSourceAdjustmentPreparation.prepare(source,before:before,map:map,settings:settings,selection:selection,transform:transform,workspace:workspace)
        #expect(source.adjustments.isEmpty && made.node.adjustments.count == 1)
        #expect(made.node.original == source.original && made.node.originalRevision == source.originalRevision)
        #expect(made.node.id == source.id && made.node.revision != source.revision)
        let sampled=try made.plane.read(made.plane.globalExtent).surface
        #expect(sampled.pixels[0] == values[0] && sampled.pixels[3] == values[3])
        #expect(sampled.pixels[1] != values[1] && sampled.pixels[1].w == values[1].w)
        #expect(try before.read(before.globalExtent).surface.pixels == values)
        let packed=try LWSourcePackageArchive.externalize(manifest(made.node),maximumBytes:1024*1024)
        let restored=try LWSourcePackageArchive.hydrate(packed.manifest,read:{ name,_ in try #require(packed.assets[name]) },
            readPlane:{ name,_ in try #require(packed.planes[name]?.plane) })
        let reopened=try #require(restored.layers.first?.liveSource)
        #expect(reopened == made.node)
        let replay=try LWSourceOperationReplay.evaluate(reopened,developed:before,map:map,workspace:workspace)
        #expect(try replay.surface.read(replay.surface.globalExtent).surface.pixels == sampled.pixels)
        var duplicated=try reopened.metadataCopy(additionalBytes:4096)
        duplicated.operations.append(try #require(duplicated.operations.last))
        expectInvalid { try duplicated.validateOperationOrder() }
    }
    @Test(arguments:[AdjustmentKind.hsv,.levels])
    func retainedDialogAdjustmentPublishesOneHistoryEntryAndRefusesStaleAdmission(_ kind:AdjustmentKind) throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let before=try tiledFixture([SIMD4(0.25,0.5,0.75,1),SIMD4(4,-1,2,0.5)],width:2,workspace:workspace)
        let source=try node(original:URL(fileURLWithPath:"/dialog-publication-reference.dng"),width:2,height:1)
        let transform=LayerTransform(origin:.zero,size:CGSize(width:2,height:1)),id=UUID()
        let original=try ImportedImage(plane:before,name:"Protected source")
        let layer=ImageLayer(id:id,asset:original,name:"Protected source",isVisible:true,transform:transform,liveSource:source)
        let session=EditorSession();session.document=try CanvasDocument(width:2,height:1,layers:[layer]).admittingMetadataMutation()
        session.activeLayerID=id;session.history.reset()
        let old=try #require(session.document),admission=try session.captureDocumentEditAdmission()
        var settings=LayerAdjustment(kind:kind)
        if kind == .hsv { settings.hsvSettings=HueSaturationSettings(hue:30) } else { settings.levels.ranges[0].gamma=2 }
        let made=try LWSourceAdjustmentPreparation.prepare(source,before:before,map:source.currentSpatialMap,settings:settings,selection:nil,transform:transform,workspace:workspace)
        try session.publishSourceAdjustment(made,admission:admission,layerID:id,node:source,original:original,transform:transform,mask:nil,actionName:kind.rawValue)
        #expect(session.history.undoCount == 1 && session.activeLayer?.liveSource == made.node)
        #expect(session.activeLayer?.id == id && session.activeLayer?.transform == transform)
        #expect(session.activeLayer?.liveSource?.originalRevision == source.originalRevision)
        let changed=try #require(session.document)
        expectInvalid { try session.publishSourceAdjustment(made,admission:admission,layerID:id,node:source,original:original,transform:transform,mask:nil,actionName:kind.rawValue) }
        #expect(session.document == changed && session.history.undoCount == 1)
        session.undo();#expect(session.document == old && session.history.canRedo)
        session.redo();#expect(session.document == changed)
    }
    @Test func retainedDialogAdjustmentRefusesMalformedSettingsAndForeignLineageBeforePublication() throws {
        let source=try node(original:URL(fileURLWithPath:"/dialog-invalid-reference.dng"),width:2,height:1)
        let frame=try source.capturedFrame(transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)))
        var invalid=LayerAdjustment(kind:.hsv);invalid.hsvSettings=HueSaturationSettings(hue:.nan)
        let operation=LWSourceRetainedAdjustment(id:UUID(),sourceID:source.id,upstreamRevision:source.revision,
            settings:invalid,captureFrame:frame,selectionPlaneID:nil)
        expectInvalid { try operation.validate(source:source.id) }
        var foreign=try source.metadataCopy(additionalBytes:8192)
        let valid=LWSourceRetainedAdjustment(id:UUID(),sourceID:source.id,upstreamRevision:UUID(),
            settings:LayerAdjustment(kind:.levels),captureFrame:frame,selectionPlaneID:nil)
        try foreign.appendAdjustment(valid)
        expectInvalid { try foreign.validate() }
    }
    @Test func retainedLevelsHistogramBinsActualFloatWithoutChangingReferenceSamples() throws {
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let values:[SIMD4<Float>]=[SIMD4(4,-2,1,1),SIMD4(0,0,0,0.5)]
        let plane=try tiledFixture(values,width:2,workspace:workspace)
        let result=try LWSourceLevelsHistogram.make(plane,selection:nil,
            transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)),workspace:workspace)
        #expect(result.bins.count == 4 && result.bins.allSatisfy({$0.count == 256}))
        #expect(result.bins[1][255] == 1 && result.bins[1][0] == 0.5)
        #expect(result.bins[2][0] == 1.5 && result.bins[3][255] == 1)
        #expect(try plane.read(plane.globalExtent).surface.pixels == values)
        workspace.cancellation.cancel()
        #expect(throws:CancellationError.self) { _=try LWSourceLevelsHistogram.make(plane,selection:nil,
            transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)),workspace:workspace) }
    }
}


extension LiveRawSourceTests {
    @Test func confirmedSourceClosePreservesUnknownSentinelAndRetainsExactRetryTarget() async throws {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs), session = EditorSession()
        let source = try node(original:URL(fileURLWithPath:"/sentinel-close.dng"),width:2,height:1)
        var plane:LWFloatPlane? = try tiledFixture([SIMD4(4,-1,2,1),SIMD4(2,3,4,1)],width:2,workspace:workspace)
        session.installProject(try floatProject(source,plane:try #require(plane),transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1))),from:URL(fileURLWithPath:"/sentinel-close.comp"))
        let sentinel = workspace.directory.appendingPathComponent("foreign-sentinel")
        let payload = Data("preserve unknown ownership".utf8)
        try payload.write(to:sentinel,options:.withoutOverwriting)
        plane = nil
        try await session.releaseConfirmedSourceProject(deadline:ContinuousClock.now.advanced(by:.seconds(30)))
        #expect(throws:ProjectError.self) { try session.finishConfirmedSourceRetirement(protectedOwners:[]) }
        #expect(try Data(contentsOf:sentinel)==payload)
        #expect(session.sourceClosePending && !session.canStartProjectOperation)
        let retained = try session.sourceWorkspaceOwners()
        #expect(retained.values.contains(where:{$0 === workspace}))
        // Only this fixture author removes the exact file it created. Production
        // Close neither adopts nor deletes an unregistered member.
        try FileManager.default.removeItem(at:sentinel)
        try session.finishConfirmedSourceRetirement(protectedOwners:[])
        #expect(!FileManager.default.fileExists(atPath:workspace.directory.path))
    }
}


extension LiveRawSourceTests {
    @Test func confirmedSourceCloseJoinsQueuedEffectsAndCannotRepublishItsCanceledProvider() async throws {
        let session = EditorSession(), workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let source = try node(original:URL(fileURLWithPath:"/effects-close.dng"),width:2,height:1)
        do {
            let plane = try tiledFixture([SIMD4(4,-1,2,1),SIMD4(2,3,4,0.5)],width:2,workspace:workspace)
            session.installProject(try floatProject(source,plane:plane,transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1))),from:URL(fileURLWithPath:"/effects-close.comp"))
        }
        let cache = session.effectsPreviews
        var completionRan = false
        do {
            var layer = try #require(session.document?.layers.first)
            layer.effects = LayerEffects(shadow:ShadowEffect())
            _ = cache.preview(for:layer,mask:nil,transform:layer.transform,maskPlacement:nil,completion:{ completionRan = true })
        }
        #expect(cache.hasPendingWorkers)
        try await session.releaseConfirmedSourceProject(deadline:ContinuousClock.now.advanced(by:.seconds(30)))
        #expect(!cache.hasPendingWorkers && !completionRan)
        try session.finishConfirmedSourceRetirement(protectedOwners:[])
        #expect(!FileManager.default.fileExists(atPath:workspace.directory.path))
    }
}


extension LiveRawSourceTests {
    @Test func generationFrontierRecordsHeldReadersAndRetainsHighWaterAfterCheckedRetirement() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:16*1024*1024))
        var first:LWFloatPlane?=try tiledFixture([SIMD4(4,-2,1,1)],width:1,workspace:workspace)
        let initial=try workspace.generationObservation()
        let original=try #require(initial.entries.first)
        #expect(initial.entries.count == 1 && initial.registeredHighWater == 1)
        #expect(original.device != nil && original.inode != nil && !original.pendingWriter)
        #expect(original.activeLifetimeCount > 0 && original.registeredMemberCount == 1)
        var reader:LWFloatPlane.Sampler?=first?.sampler()
        var next:LWFloatPlane?=try tiledFixture([SIMD4(5,-2,1,1)],width:1,workspace:workspace)
        let during=try workspace.generationObservation()
        #expect(during.workspaceID == initial.workspaceID && during.entries.count == 2)
        #expect(during.registeredHighWater == 2 && during.entries.contains(original))
        #expect(!(try workspace.retireOwnedPlane(&first)))
        #expect(try reader?.pixel(x:0,y:0) == SIMD4(4,-2,1,1))
        #expect(try workspace.generationObservation().entries.map(\.name) == during.entries.map(\.name))
        reader=nil
        #expect(try workspace.retireOwnedPlane(&first))
        let after=try workspace.generationObservation()
        #expect(after.entries.count == 1 && after.registeredHighWater == 2)
        #expect(!after.entries.contains(where:{$0.name == original.name}))
        #expect(try workspace.retireOwnedPlane(&next))
        let empty=try workspace.generationObservation()
        #expect(empty.entries.isEmpty && empty.registeredHighWater == 2)
        try workspace.retireOwnedChildren()
    }
    @Test func generationObservationDoesNotAdoptOrRetireAnUnknownMember() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:16*1024*1024))
        var plane:LWFloatPlane?=try tiledFixture([SIMD4(4,-2,1,1)],width:1,workspace:workspace)
        let before=try workspace.generationObservation(),entry=try #require(before.entries.first)
        let sentinel=workspace.directory.appendingPathComponent(entry.name).appendingPathComponent("unknown-member")
        let bytes=Data("observation is not retirement authority".utf8)
        try bytes.write(to:sentinel,options:.withoutOverwriting)
        let observed=try workspace.generationObservation()
        #expect(observed.entries == before.entries && observed.registeredHighWater == before.registeredHighWater)
        #expect(throws:ProjectError.self) { _=try workspace.retireOwnedPlane(&plane) }
        #expect(try Data(contentsOf:sentinel) == bytes)
        try FileManager.default.removeItem(at:sentinel) // Exact fixture-created member only.
        #expect(try workspace.retireOwnedPlane(&plane))
        try workspace.retireOwnedChildren()
    }
}

extension LiveRawSourceTests {
    @Test func legacyEncodedFloatBackingStreamsTilesUnderSmallerDecodedWorkingBudget() throws {
        // Encoded input is the fixture's retained package. Production reserves
        // only bounded decoded tiles; it cannot allocate this complete pixel set
        // within the deliberately smaller shared decoded working owner.
        let width=1024,height=513,maximum=16*1024*1024
        let value=SIMD4<Float>(4,-2,0.125,0.5)
        let encoded=try LWLinearSurface(width:width,height:height,
            pixels:[SIMD4<Float>](repeating:value,count:width*height),maximumBytes:maximum).packageData(maximumFileBytes:maximum)
        let set=try LWFloatWorkingSet(limit:4*1024*1024),workspace=try LWFloatWorkspace(workingSet:set)
        #expect(encoded.count > set.limit)
        let plane=try LWFloatCompositor.fromEncodedSurface(encoded,maximumFileBytes:maximum,workspace:workspace)
        #expect(plane.width == width && plane.height == height)
        for range in [LWFloatRange(x:255,y:255,width:3,height:3),LWFloatRange(x:1023,y:512,width:1,height:1)] {
            #expect(try plane.read(range).surface.pixels.allSatisfy({$0 == value}))
        }
        #expect(try LWLinearSurface.packageExtent(encoded,maximumFileBytes:maximum).height == height)
    }
    @Test func legacyEncodedFloatBackingRejectsMalformedHeaderSamplesAndCancellation() throws {
        let data=try LWLinearSurface(width:1,height:1,pixels:[SIMD4(4,-2,1,0.5)],maximumBytes:16).packageData(maximumFileBytes:40)
        func reject(_ encoded:Data) throws {
            let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
            #expect(throws:ProjectError.self) { _=try LWFloatCompositor.fromEncodedSurface(encoded,maximumFileBytes:64,workspace:workspace) }
        }
        try reject(Data(data.dropLast()));try reject(data+Data([0]))
        var nonfinite=data
        var bits=Float.nan.bitPattern.littleEndian
        withUnsafeBytes(of:&bits) { nonfinite.replaceSubrange(24..<28,with:$0) }
        try reject(nonfinite)
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet());workspace.cancellation.cancel()
        #expect(throws:CancellationError.self) { _=try LWFloatCompositor.fromEncodedSurface(data,maximumFileBytes:64,workspace:workspace) }
        #expect(try FileManager.default.contentsOfDirectory(at:workspace.directory,includingPropertiesForKeys:nil).isEmpty)
    }
}

extension LiveRawSourceTests {
    @Test func selectedRawDevelopmentKeepsCapturedSelectionInCurrentFrameAcrossGeometryChange() throws {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let before = try tiledFixture([SIMD4(10,0,0,1),SIMD4(20,0,0,1),SIMD4(30,0,0,1),SIMD4(40,0,0,1)],width:4,workspace:workspace)
        let adjusted = try tiledFixture([SIMD4(100,0,0,1),SIMD4(200,0,0,1),SIMD4(300,0,0,1),SIMD4(400,0,0,1)],width:4,workspace:workspace)
        let coverage = try tiledFixture([SIMD4(repeating:1),SIMD4.zero,SIMD4.zero,SIMD4.zero],width:4,workspace:workspace)
        let map = LWSourceSpatialMap(geometry:try LWSourceCoordinateMap([1,0,1,0,1,0,0,0,1]),optics:CameraRawOpticsSettings(),width:4,height:1)
        let result = try LWSourceSelectedDevelopmentBlend.apply(original:before,adjusted:adjusted,sourceCoverage:coverage,currentMap:map,workspace:workspace)
        let pixels = try result.read(.init(x:0,y:0,width:4,height:1)).surface.pixels
        #expect(pixels.map(\.x)==[10,200,30,40])
        #expect(try before.read(.init(x:0,y:0,width:4,height:1)).surface.pixels.map(\.x)==[10,20,30,40])
    }
    @Test func selectedRawDevelopmentInterpolatesHDRPremultipliedAlphaWithoutHiddenRGBLeakage() throws {
        let workspace = try LWFloatWorkspace(workingSet:.sourceGraphs)
        let before = try tiledFixture([SIMD4(1000,-1000,400,0),SIMD4(4,-2,1,0.5)],width:2,workspace:workspace)
        let adjusted = try tiledFixture([SIMD4(4,-2,1,1),SIMD4(2,6,-4,1)],width:2,workspace:workspace)
        let coverage = try tiledFixture([SIMD4(repeating:0.5),SIMD4(repeating:0.5)],width:2,workspace:workspace)
        let map = LWSourceSpatialMap(geometry:.identity,optics:CameraRawOpticsSettings(),width:2,height:1)
        let result = try LWSourceSelectedDevelopmentBlend.apply(original:before,adjusted:adjusted,sourceCoverage:coverage,currentMap:map,workspace:workspace)
        let pixels = try result.read(.init(x:0,y:0,width:2,height:1)).surface.pixels
        #expect(pixels[0]==SIMD4(4,-2,1,0.5))
        #expect(pixels[1]==SIMD4(Float(8)/3,Float(10)/3,-Float(7)/3,0.75))
    }
}

extension LiveRawSourceTests {
    @Test func readOnlySourceBytesRetainTheirExactInputChargeAfterCacheEntryRelease() throws {
        let working=try LWFloatWorkingSet(limit:256*1024)
        var entry:LWSourceOwnedData?=try LWSourceOwnedData.retaining(Data(repeating:17,count:64*1024),workingSet:working)
        weak var owner=entry?.owner
        var escaped:LWSourceOwnedData.Bytes?=entry?.bytes
        entry=nil
        #expect(owner != nil)
        #expect(try #require(escaped).count==64*1024 && escaped?.first==17 && escaped?.last==17)
        #expect(throws:ProjectError.self) { _=try working.reserve(working.limit) }
        escaped=nil
        #expect(owner == nil)
        let released=try working.reserve(working.limit);withExtendedLifetime(released) {}
    }
    @Test func sourceDataTransferBindsItsDistinctAllocationToTheAdmittedDestinationOwner() throws {
        let working=try LWFloatWorkingSet(limit:512*1024)
        weak var retained:LWSourceMetadataStorage?
        var output:Data?
        do {
            let input=try LWSourceOwnedData.retaining(Data(repeating:23,count:64*1024),workingSet:working)
            let destination=try LWSourceMetadataStorage(bytes:2*64*1024+4096,workingSet:working)
            retained=destination;output=try input.copyData(ownedBy:destination)
        }
        #expect(retained != nil)
        #expect(output?.count==64*1024 && output?.first==23 && output?.last==23)
        #expect(throws:ProjectError.self) { _=try working.reserve(working.limit) }
        output=nil
        #expect(retained == nil)
        let released=try working.reserve(working.limit);withExtendedLifetime(released) {}
    }
    @Test func sourceDataTransferRefusesUnadmittedOrForeignCopiesWithoutChangingInput() throws {
        let working=try LWFloatWorkingSet(limit:512*1024)
        let input=try LWSourceOwnedData.retaining(Data(repeating:31,count:64*1024),workingSet:working)
        let tooSmall=try LWSourceMetadataStorage(bytes:2*64*1024+4095,workingSet:working)
        let foreign=try LWSourceMetadataStorage(bytes:2*64*1024+4096,workingSet:LWFloatWorkingSet(limit:256*1024))
        #expect(throws:ProjectError.self) { _=try input.copyData(ownedBy:tooSmall) }
        #expect(throws:ProjectError.self) { _=try input.copyData(ownedBy:foreign) }
        #expect(input.bytes.allSatisfy({$0==31}) && input.count==64*1024)
    }
}

extension LiveRawSourceTests {
    @Test(arguments:[4096,8192])
    func sourceHistoryBookkeepingPreservesExactUndoWhenItsTransientSetCannotBeAdmitted(limit:Int) throws {
        let set=try LWFloatWorkingSet(limit:limit),owner=try LWSourceMetadataStorage(bytes:4096,workingSet:set)
        var document=CanvasDocument(width:1,height:1,layers:[]);document.metadataStorage=owner
        let successor=CanvasDocument(width:2,height:1,layers:[])
        let history=DocumentHistory()
        history.begin("Retained",document:document,selection:nil);history.end(document:successor,selection:nil)
        let before=set.retainedBytes
        #expect(history.retainedBytes(current:successor)==4096)
        #expect(history.retainedBytes(current:document)==0)
        #expect(history.canUndo && history.undoCount==1 && !history.canRedo)
        #expect(set.retainedBytes==before) // No observer lease outlives either path.
    }
}

extension LiveRawSourceTests {
    @Test func escapedGenerationFrontierRetainsOnlyItsObservationChargeAfterRealWorkspaceRetirement() throws {
        let working=try LWFloatWorkingSet(limit:16*1024*1024)
        var workspace:LWFloatWorkspace?=try LWFloatWorkspace(workingSet:working)
        var plane:LWFloatPlane?=try tiledFixture([SIMD4(4,-2,1,1)],width:1,workspace:try #require(workspace))
        var entries:LWFloatWorkspace.GenerationEntries?=try #require(workspace).generationObservation().entries
        #expect(try #require(entries).count==1)
        #expect(try #require(workspace).retireOwnedPlane(&plane))
        try #require(workspace).retireOwnedChildren();workspace=nil
        #expect(working.retainedBytes>0)
        #expect(try #require(entries).first?.registeredMemberCount==1) // One actual tile member; manifest is in memory.
        entries=nil
        let released=try working.reserve(working.limit);withExtendedLifetime(released) {}
    }
}


extension LiveRawSourceTests {
    @Test func sampleAllBackingRefusesItsCallerBudgetBeforeMalformedJSONDecode() throws {
        let working=try LWFloatWorkingSet(limit:4096)
        let source=UUID(),upstream=UUID(),payload=Data("{not valid JSON".utf8)
        let captured=LWSourceSampleComposite(revision:UUID(),sourceID:source,upstreamRevision:upstream,payload:payload)
        do {
            _=try captured.decodedBacking(workingSet:working)
            Issue.record("The caller budget was bypassed before backing decode")
        } catch ProjectError.tooLarge {} // The actual reservation branch, before the malformed JSON parser.
        #expect(captured.payload==payload && working.retainedBytes==0)
        let full=try working.reserve(working.limit);withExtendedLifetime(full) {}
    }
    @Test func sampleAllBackingRetainsItsExactCallerDecodeOwnerUntilBackingRelease() throws {
        let layer=UUID(),source=UUID(),upstream=UUID()
        let backing=LWSourceSampleComposite.Backing(documentID:UUID(),width:2,height:1,sourceLayerID:layer,
            layers:[ProjectLayerRecord(id:layer,name:"Immutable upstream",isVisible:true,
                transform:LayerTransform(origin:.zero,size:CGSize(width:2,height:1)),imageFile:layer.uuidString+".plane")],
            images:[:],masks:[:])
        let payload=try LWCatalogCodec.encode(backing)
        let required=try LWSourceMetadataStorage.decodingBytes(payload)
        let working=try LWFloatWorkingSet(limit:required)
        let captured=LWSourceSampleComposite(revision:UUID(),sourceID:source,upstreamRevision:upstream,payload:payload)
        var decoded:LWSourceSampleComposite.Backing?=try captured.decodedBacking(workingSet:working)
        weak var owner=decoded?.metadataStorage
        #expect(owner?.workingSet === working && owner?.capacity==required)
        try #require(decoded).validate()
        #expect(decoded?.layers.first?.id==layer && decoded?.sourceLayerID==layer)
        #expect(throws:ProjectError.self) { _=try working.reserve(1) }
        decoded=nil
        #expect(owner == nil && working.retainedBytes==0)
        let full=try working.reserve(working.limit);withExtendedLifetime(full) {}
    }
}


extension LiveRawSourceTests {
    @Test func escapedCloseOwnerProjectionRetainsItsExactCollectionAndWorkspaceOwners() throws {
        let working=try LWFloatWorkingSet(limit:16*1024*1024)
        var workspace:LWFloatWorkspace?=try LWFloatWorkspace(workingSet:working)
        var escaped:LWSourceWorkspaceOwners.Owners?
        do {
            let charge=try working.reserve(1024)
            let projected=LWSourceWorkspaceOwners(values:[try #require(workspace)],charge:charge)
            escaped=projected.values
        }
        #expect(escaped?.count==1 && escaped?.first === workspace)
        try #require(workspace).retireOwnedChildren();workspace=nil
        #expect(working.retainedBytes>0)
        #expect(throws:ProjectError.self) { _=try working.reserve(working.limit) }
        escaped=nil
        let full=try working.reserve(working.limit);withExtendedLifetime(full) {}
    }
}
