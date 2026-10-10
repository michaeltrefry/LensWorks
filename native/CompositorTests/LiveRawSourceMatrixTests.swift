import Foundation
import Testing
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin
@testable import Compositor

/// Root supplies licensed, hash-bound source/reference fixtures after source review.
/// A successful semantic route is not numerical-color or camera support approval.
@MainActor struct LiveRawSourceMatrixTests {
    private struct Row: Decodable {
        let id: String
        let family: String
        let source: URL
        let sourceSHA256: String
        let license: String
        let raw: Bool
        let orientation: UInt32
        let cameraMake: String?
        let cameraModel: String?
        let metadataFormat: String
        let sourceColor: String
        let decoder: String
        let alpha: String
        let alphaMode: String
        let profileKind: String
        let embeddedICC: URL?
        let embeddedICCSHA256: String?
        let displayProfile: String
        let referencePlane: URL
        let reference: LWFloatPlaneArchive.Reference
        let approvedMaximumAbsoluteError: Double?
        let selectedGeometry: Bool
    }
    private struct Matrix: Decodable { let rows:[Row] }
    private struct OwnedMatrix { let value:Matrix;let owner:LWSourceMetadataStorage;var rows:[Row] { value.rows } }
    private func wholeHash(_ url:URL)throws->String {
        guard url.isFileURL,url.standardizedFileURL==url,url.resolvingSymlinksInPath()==url else { throw ProjectError.invalid }
        let parent=try LWFloatDirectoryChain(url.deletingLastPathComponent())
        let fd=openat(parent.fd,url.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else { throw ProjectError.invalid };defer { close(fd) }
        var held=stat(),named=stat()
        guard fstat(fd,&held)==0,fstatat(parent.fd,url.lastPathComponent,&named,AT_SYMLINK_NOFOLLOW)==0,(held.st_mode&S_IFMT)==S_IFREG,
              held.st_dev==named.st_dev,held.st_ino==named.st_ino,held.st_size>0 else { throw ProjectError.invalid }
        try parent.check()
        let lease=try LWFloatWorkingSet.sourceGraphs.reserve(2*65536)
        var buffer=[UInt8](repeating:0,count:65536),hash=SHA256(),total:off_t=0
        while true {
            try Task.checkCancellation()
            let n=buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!,65536) }
            guard n>=0 else { throw ProjectError.invalid };if n==0 { break }
            hash.update(data:Data(buffer[0..<n]));total+=off_t(n)
        }
        var after=stat(),renamed=stat()
        guard fstat(fd,&after)==0,fstatat(parent.fd,url.lastPathComponent,&renamed,AT_SYMLINK_NOFOLLOW)==0,total==held.st_size,
              after.st_dev==held.st_dev,after.st_ino==held.st_ino,after.st_size==held.st_size,
              after.st_mtimespec.tv_sec==held.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==held.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec==held.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==held.st_ctimespec.tv_nsec,
              renamed.st_dev==held.st_dev,renamed.st_ino==held.st_ino else { throw ProjectError.invalid }
        try parent.check()
        withExtendedLifetime(lease) {};return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private func matrix()throws->OwnedMatrix {
        let path=try #require(ProcessInfo.processInfo.environment["LW_S08_RAW_MATRIX"])
        let expected=try #require(ProcessInfo.processInfo.environment["LW_S08_RAW_MATRIX_SHA256"])
        let url=URL(fileURLWithPath:path)
        guard expected.count==64,try wholeHash(url)==expected else { throw ProjectError.invalid }
        let bytes=try LWSourceOwnedData.read(url,maximumBytes:4*1024*1024,workingSet:.sourceGraphs)
        let decoded=try bytes.decode(Matrix.self),value=decoded.value
        guard !value.rows.isEmpty,value.rows.count<=256,Set(value.rows.map(\.id)).count==value.rows.count else { throw ProjectError.invalid }
        let raw=Set(value.rows.filter(\.raw).map(\.family))
        guard raw==Set(["cr2","cr3","dng","raf","rw2","nef","arw","orf","pef"]),
              Set(value.rows.map(\.orientation))==Set(UInt32(1)...UInt32(8)),
              Set(value.rows.map(\.alphaMode)).isSuperset(of:["opaque","straight-transparent"]),
              Set(value.rows.map(\.profileKind)).isSuperset(of:["camera-matrix","embedded-ICC","untagged-sRGB"]),
              Set(value.rows.map(\.displayProfile)).isSuperset(of:["sRGB","Display-P3"]) else { throw ProjectError.invalid }
        for row in value.rows {
            guard !row.license.isEmpty,row.license.utf8.count<=4096,!row.id.isEmpty,row.id.utf8.count<=256,
                  [row.family,row.metadataFormat,row.sourceColor,row.decoder,row.alpha,row.profileKind].allSatisfy({$0.utf8.count<=4096}),(1...8).contains(row.orientation),row.sourceSHA256.count==64,
                  row.reference.manifestSHA256.count==64,["opaque","straight-transparent"].contains(row.alphaMode),
                  ["sRGB","Display-P3"].contains(row.displayProfile),
                  row.approvedMaximumAbsoluteError.map({$0.isFinite && $0>=0}) ?? true else { throw ProjectError.invalid }
            if row.profileKind=="embedded-ICC" { guard row.embeddedICC != nil,row.embeddedICCSHA256?.count==64 else { throw ProjectError.invalid } }
        }
        // Retain typed fixture metadata until the route has its own retained copy.
        return OwnedMatrix(value:value,owner:decoded.owner)
    }
    private func snapshot(_ node:LWLiveSourceNode,_ plane:LWFloatPlane)throws->ProjectSnapshot {
        let id=UUID(),transform=LayerTransform(origin:.zero,size:CGSize(width:plane.width,height:plane.height))
        let manifest=ProjectManifest(workingSpace:"extended-linear-sRGB",workingSample:"float32-straight-RGBA",
            documentID:UUID(),width:plane.width,height:plane.height,activeLayerID:id,layers:[
                .init(id:id,name:"Live RAW",isVisible:true,transform:transform,imageFile:id.uuidString+".plane",liveSource:node)])
        return ProjectSnapshot(manifest:manifest,images:[id:try ImportedImage(plane:plane,name:"Live RAW")])
    }
    private func equal(_ a:LWFloatPlane,_ b:LWFloatPlane)throws {
        #expect(a.width==b.width && a.height==b.height)
        try a.forEachTile { range in
            let x=try a.read(range).surface,y=try b.read(range).surface
            #expect(x.pixels.enumerated().allSatisfy { i,p in (0..<4).allSatisfy { p[$0].bitPattern==y.pixels[i][$0].bitPattern } })
        }
    }
    @Test func selectedGeometryRunsApplyingDevelopmentEvaluatePlaneAndDurableReopen() async throws {
        let admittedMatrix=try matrix()
        defer { withExtendedLifetime(admittedMatrix) {} }
        let fixture=try #require(admittedMatrix.rows.first(where:\.selectedGeometry))
        #expect(try wholeHash(fixture.source)==fixture.sourceSHA256)
        let (source,raw)=try await LWSourceDeveloper.shared.createPlane(original:LWCatalogNativePath(fileURL:fixture.source),rawHint:fixture.raw)
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        let width=source.originalWidth,height=source.originalHeight
        guard width>=4,height>=4 else { throw ProjectError.invalid }
        let mask=try #require(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:1,
            space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue))
        mask.setFillColor(gray:1,alpha:1);mask.fill(CGRect(x:0,y:0,width:1,height:1))
        let selection=SelectionClip(rect:CGRect(x:1,y:1,width:width/2,height:height/2),coverage:try #require(mask.makeImage()))
        var settings=CameraRawSettings();settings.exposure=1;settings.geometry.rotate=17
        settings.geometry.vertical=12;settings.optics.distortion = -5
        let changed=try source.applyingDevelopment(settings:settings,whiteBalance:.asShot,seed:19,
            selection:selection,mapping:.identity,workspace:workspace)
        let step=try #require(changed.selectedDevelopments.last);#expect(step.coverageFrame != nil)
        let developed=try await LWSourceDeveloper.shared.evaluatePlane(changed)
        let selected=try settings.develop(raw,seed:19,makeBuilder:{try workspace.makeBuilder(width:$0,height:$1)},
            makeScratchDirectory:{try workspace.makeScratchDirectory()},fileOwner:workspace)
        #expect(selected.map != .identity)
        let selectedMap=LWSourceSpatialMap(geometry:selected.map,optics:settings.optics,width:width,height:height)
        let capture=try #require(step.coverageFrame),coverage=try changed.developmentSelectionPlane(step,workspace:workspace).sampler()
        let original=raw.sampler(),adjusted=selected.surface.sampler(),actual=developed.surface.sampler()
        var compared=0
        // Independent source/captured/selected coordinate chain, not a call to blend().
        for y in 0..<height { for x in 0..<width {
            let point=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
            guard let destination=try selectedMap.developedPointIfInBounds(point),
                  let captured=try capture.spatialMap.developedPointIfInBounds(point) else { continue }
            let amount=try coverage.sample(captured).w
            if amount==1 { #expect(try actual.sample(point)==adjusted.sample(destination));compared+=1 }
            if amount==0 { #expect(try actual.sample(point)==original.sample(point)) }
        } }
        #expect(compared>0)
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let project=directory.appendingPathComponent("Selected.comp",isDirectory:true)
        try await ProjectStore.shared.save(snapshot(changed,developed.surface),to:project)
        let reopened=try await ProjectStore.shared.load(from:project),restored=try #require(reopened.manifest.layers.first?.liveSource)
        #expect(restored.selectedDevelopments==changed.selectedDevelopments)
        let after=try await LWSourceDeveloper.shared.evaluatePlane(restored);try equal(developed.surface,after.surface)
        #expect(try wholeHash(fixture.source)==fixture.sourceSHA256)

        // Reach the same selected development seam after a real retained public
        // resize. This frame deliberately differs from the immutable source size.
        let resizedSnapshot=try await ImageResizer.shared.resize(snapshot(source,raw),
            to:ImageSizeOptions(width:width-1,height:height-2,resolution:72,sampling:.nearest))
        let retained=try #require(resizedSnapshot.manifest.layers.first?.liveSource)
        let current=try retained.currentSpatialMap
        #expect(current.developedWidth==width-1 && current.developedHeight==height-2)
        #expect(!retained.resamples.isEmpty && current.stages.count>0)
        let resizedSelection=SelectionClip(rect:CGRect(x:0,y:0,width:CGFloat(current.developedWidth)/2,
            height:CGFloat(current.developedHeight)/2),coverage:try #require(mask.makeImage()))
        let selectedRetained=try retained.applyingDevelopment(settings:settings,whiteBalance:.asShot,seed:19,
            selection:resizedSelection,mapping:.identity,workspace:workspace)
        let capturedStep=try #require(selectedRetained.selectedDevelopments.last)
        let retainedFrame=try #require(capturedStep.coverageFrame)
        #expect(retainedFrame.developedWidth==current.developedWidth && retainedFrame.developedHeight==current.developedHeight)
        #expect(retainedFrame.width==width && retainedFrame.height==height)
        let storedCoverage=try selectedRetained.developmentSelectionPlane(capturedStep,workspace:workspace)
        #expect(storedCoverage.width==width-1 && storedCoverage.height==height-2)
        try selectedRetained.validateBackingAssets()
        let retainedResult=try await LWSourceDeveloper.shared.evaluatePlane(selectedRetained)
        let capturedCoverage=storedCoverage.sampler()
        var inside=0,outside=0
        // Source-grid reference composes the recorded coverage and selected
        // development first, then the retained resize with its actual sampling.
        // It does not invoke the production selected blend or evaluatePlane.
        var expected=try LWFloatCompositor.map(raw,workspace:workspace) { old,x,y in
            let point=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
            guard let adjustedPoint=try selectedMap.developedPointIfInBounds(point),
                  let coveragePoint=try retainedFrame.spatialMap.developedPointIfInBounds(point) else { return old }
            let amount=try capturedCoverage.sample(coveragePoint).w
            if amount==0 { outside+=1;return old }
            inside+=1
            let replacement=try adjusted.sample(adjustedPoint)
            if amount==1 { return replacement }
            let alpha=old.w*(1-amount)+replacement.w*amount
            guard alpha>0 else { return .zero }
            return SIMD4((old.x*old.w*(1-amount)+replacement.x*replacement.w*amount)/alpha,
                (old.y*old.w*(1-amount)+replacement.y*replacement.w*amount)/alpha,
                (old.z*old.w*(1-amount)+replacement.z*replacement.w*amount)/alpha,alpha)
        }
        #expect(inside>0 && outside>0)
        for operation in retained.resamples { expected=try LWSourceResample.apply(operation,plane:expected,workspace:workspace) }
        #expect(retainedResult.surface.width==width-1 && retainedResult.surface.height==height-2)
        try equal(retainedResult.surface,expected)
        let retainedProject=directory.appendingPathComponent("ResizedSelection.comp",isDirectory:true)
        try await ProjectStore.shared.save(snapshot(selectedRetained,retainedResult.surface),to:retainedProject)
        let retainedReopened=try await ProjectStore.shared.load(from:retainedProject)
        let hydrated=try #require(retainedReopened.manifest.layers.first?.liveSource)
        #expect(hydrated.resamples==selectedRetained.resamples && hydrated.operations==selectedRetained.operations)
        #expect(hydrated.selectedDevelopments==selectedRetained.selectedDevelopments)
        try hydrated.validateBackingAssets()
        let replay=try await LWSourceDeveloper.shared.evaluatePlane(hydrated)
        try equal(retainedResult.surface,replay.surface)
        #expect(try wholeHash(fixture.source)==fixture.sourceSHA256)
    }
    @Test func sourceBackedCameraProfileOrientationAlphaAndSameBackendMatrix() async throws {
        let manifest=try matrix()
        var sawHDR=false,sawNegative=false
        defer { withExtendedLifetime(manifest) {} }
        for row in manifest.rows {
            #expect(try wholeHash(row.source)==row.sourceSHA256)
            let (node,raw)=try await LWSourceDeveloper.shared.createPlane(original:LWCatalogNativePath(fileURL:row.source),rawHint:row.raw)
            let metadataOwner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.decodingBytes(node.metadata))
            let provenanceOwner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.decodingBytes(node.provenance))
            defer { withExtendedLifetime(metadataOwner) {};withExtendedLifetime(provenanceOwner) {} }
            let metadata=try LWCatalogCodec.decode(LWMediaMetadata.self,from:node.metadata)
            let provenance=try LWCatalogCodec.decode(LWMediaFullRenderProvenance.self,from:node.provenance)
            #expect(metadata.format==row.metadataFormat && metadata.orientation==row.orientation)
            #expect(metadata.camera_make==row.cameraMake && metadata.camera_model==row.cameraModel)
            #expect(provenance.decoder==row.decoder && provenance.source_color==row.sourceColor && provenance.alpha==row.alpha)
            #expect(provenance.working_color=="linear sRGB primaries, D65, f32, unclamped")
            if let profile=row.embeddedICC {
                #expect(try wholeHash(profile)==row.embeddedICCSHA256)
                let owned=try LWSourceOwnedData.read(profile,maximumBytes:16*1024*1024,workingSet:.sourceGraphs)
                let identity=try LWSourceMetadataStorage(bytes:32*1024*1024+4096,workingSet:.sourceGraphs)
                let bytes=try owned.copyData(ownedBy:identity)
                let source=try #require(CGImageSourceCreateWithURL(row.source as CFURL,nil))
                let pixels=try LWSourceMetadataStorage.product(node.originalWidth,node.originalHeight)
                let imageLease=try LWFloatWorkingSet.sourceGraphs.reserve(LWSourceMetadataStorage.product(pixels,64))
                defer { withExtendedLifetime(imageLease) {} }
                let image=try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
                let embedded=try #require(image.colorSpace?.copyICCData())
                #expect((embedded as Data)==bytes);#expect(CGColorSpace(iccData:bytes as CFData) != nil)
            }
            var opaque=true,transparent=false
            try raw.forEachTile { range in
                let tile=try raw.read(range).surface
                for pixel in tile.pixels { opaque=opaque && pixel.w==1;transparent=transparent || pixel.w<1
                    if pixel.w>0 { sawHDR=sawHDR || max(pixel.x,max(pixel.y,pixel.z))>1;sawNegative=sawNegative || min(pixel.x,min(pixel.y,pixel.z))<0 } }
            }
            #expect(row.alphaMode=="opaque" ? opaque:transparent)
            let developed=try await LWSourceDeveloper.shared.evaluatePlane(node)
            let snapshot=try snapshot(node,developed.surface),workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
            let preview=try LWFloatCompositor.renderPlane(snapshot,workspace:workspace)
            let exported=try await ImageExporter.shared.renderPlane(snapshot);try equal(preview,exported)
            let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:directory) }
            let project=directory.appendingPathComponent("Matrix.comp",isDirectory:true)
            try await ProjectStore.shared.save(snapshot,to:project)
            let reopened=try await ProjectStore.shared.load(from:project)
            let retained=try #require(reopened.manifest.layers.first?.liveSource)
            #expect(retained.original==node.original && retained.originalRevision==node.originalRevision)
            #expect(retained.metadata==node.metadata && retained.provenance==node.provenance)
            try equal(exported,try await ImageExporter.shared.renderPlane(reopened))
            let color=try #require(CGColorSpace(name:row.displayProfile=="sRGB" ? CGColorSpace.sRGB:CGColorSpace.displayP3))
            let tile=try exported.read(.init(x:0,y:0,width:min(8,exported.width),height:1)).surface
            let lease=try workspace.workingSet.reserve(tile.byteLength*4)
            let linear=try LWLinearSurface(width:tile.width,height:1,pixels:Array(tile.pixels),maximumBytes:tile.byteLength)
            let output=try linear.integerOutput(bits:16,colorSpace:color)
            #expect(output.bitsPerComponent==16 && output.colorSpace?.name==color.name)
            withExtendedLifetime(lease) {}
            try row.reference.validate()
            let reference=try LWFloatPlaneArchive.read(from:row.referencePlane,reference:row.reference,workspace:workspace)
            #expect(reference.width==raw.width && reference.height==raw.height)
            var maximumError:Double=0
            try raw.forEachTile { range in
                let actual=try raw.read(range).surface,expected=try reference.read(range).surface
                for i in actual.pixels.indices { for channel in 0..<4 { maximumError=max(maximumError,abs(Double(actual.pixels[i][channel])-Double(expected.pixels[i][channel]))) } }
            }
            if let approved=row.approvedMaximumAbsoluteError { #expect(maximumError<=approved) }
            let receipt:[String:Any]=["fixture":row.id,"source_sha256":row.sourceSHA256,"family":row.family,
                "orientation":row.orientation,"source_color":provenance.source_color,"decoder":provenance.decoder,
                "display_profile":row.displayProfile,"alpha_mode":row.alphaMode,"maximum_absolute_error":maximumError,
                "approved_maximum_absolute_error":row.approvedMaximumAbsoluteError.map { $0 as Any } ?? NSNull(),
                "camera_support_approval":NSNull(),"preview_export_same_backend_exact":true]
            let receiptLease=try workspace.workingSet.reserve(1024*1024)
            let receiptBytes=try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys])
            guard receiptBytes.count<=512*1024 else { throw ProjectError.tooLarge }
            print("S08_MATRIX_MEASUREMENT "+String(decoding:receiptBytes,as:UTF8.self))
            withExtendedLifetime(receiptLease) {}
            // Nil approval deliberately records a measurement, never fabricates a limit.
            #expect(maximumError.isFinite)
            #expect(try wholeHash(row.source)==row.sourceSHA256)
            #expect(node.decoderSourceRevision==LWManagedAuthority.sourceRevision)
        }
        #expect(sawHDR && sawNegative,"Licensed matrix must discriminate extended scene-linear latitude, not only display-range inputs")
    }
    @Test func productionSampleAllRefusesForeignOwnerAndCancelledAdmissionBeforeDecode() throws {
        let fixture=FloatRetouchFixture(),workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:64*1024*1024))
        var node=try fixture.node(width:8,height:8)
        let plane=try fixture.plane(fixture.surface(width:8,height:8),workspace:workspace)
        let sourceLayer=UUID(),overlay=UUID(),transform=LayerTransform(origin:.zero,size:CGSize(width:8,height:8))
        let other=try fixture.plane(fixture.surface(width:8,height:8,pixels:[SIMD4<Float>](repeating:SIMD4(0,3,0,1),count:64)),workspace:workspace)
        let manifest=ProjectManifest(workingSpace:"extended-linear-sRGB",workingSample:"float32-straight-RGBA",documentID:UUID(),
            width:8,height:8,activeLayerID:sourceLayer,layers:[
                .init(id:sourceLayer,name:"Source",isVisible:true,transform:transform,imageFile:sourceLayer.uuidString+".plane",liveSource:node),
                .init(id:overlay,name:"Overlay",isVisible:true,transform:transform,imageFile:overlay.uuidString+".plane")])
        let captured=try LWSourceSampleComposite.capturePlane(ProjectSnapshot(manifest:manifest,images:[
            sourceLayer:try ImportedImage(plane:plane,name:"Source"),overlay:try ImportedImage(plane:other,name:"Overlay")]),
            sourceLayer:sourceLayer,node:node,workspace:workspace)
        node=try fixture.admitted(node) { value in value.sampleComposites.append(captured.composite);value.planeAssets.merge(captured.assets) { _,current in current } }
        let template=try fixture.stroke(for:node,kind:.clone,width:8,height:8,points:[CGPoint(x:3.5,y:3.5)])
        let stroke=try LWSourceRetouchStroke(sourceID:node.id,upstreamRevision:node.revision,captureFrame:template.captureFrame,
            kind:.clone,seed:template.seed,healMode:template.healMode,sampleAllLayers:true,aligned:true,
            sampleAllLayersCompositeRevision:captured.composite.revision,blurRadius:template.blurRadius,radius:template.radius,
            hardness:template.hardness,opacity:template.opacity,points:template.points,sourceOffset:.zero,color:template.color,pointsAreDabs:true)
        node=try fixture.admitted(node) { $0.retouch=[stroke] }
        let admission=try node.retouchAdmission(plane:plane,workspace:workspace,operationScratchBytes:0)
        let lawful=try node.sampleAllCompositePlane(for:stroke,before:plane,admission:admission,workspace:workspace)
        #expect(try lawful.sampler().pixel(x:3,y:3)==SIMD4<Float>(0,3,0,1))
        let foreign=try LWFloatWorkspace(workingSet:LWFloatWorkingSet(limit:64*1024*1024))
        #expect(throws:ProjectError.self) { _=try node.sampleAllCompositePlane(for:stroke,before:plane,admission:admission,workspace:foreign) }
        workspace.cancellation.cancel()
        #expect(throws:CancellationError.self) { _=try node.sampleAllCompositePlane(for:stroke,before:plane,admission:admission,workspace:workspace) }
        #expect(foreign.registeredGenerationCount==0)
    }
}
