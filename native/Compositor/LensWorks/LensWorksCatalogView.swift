import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct LensWorksCatalogWorkspace: View {
    let applicationDelegate: CompositorApplicationDelegate
    private var catalog: LensWorksCatalog { applicationDelegate.catalog }
    private var workspace: ProjectWorkspace { applicationDelegate.workspace }

    var body: some View {
        HStack(spacing: 0) {
            navigation.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                ContentView(session: workspace.current.session, applicationDelegate: applicationDelegate)
                    .id(workspace.current.id)
                    .disabled(workspace.isManaging)
                    .psdConversionSheet(workspace.current.session)
                    .rawDevelopSheet(workspace.current.session)
                    .background { ProjectWindowBridge(controller: workspace.current.controller).frame(width: 0, height: 0) }
                Divider()
                filmstrip
            }
        }
        .task { await catalog.restore(workspace: workspace) }
        .onChange(of: workspace.selectedID) { _, _ in
            if let version = workspace.current.controller.workingVersion, version.catalogPath == catalog.catalogPath {
                catalog.selectedPhotoID = version.photoID
            }
        }
        .onChange(of: workspace.current.session.projectURL) { _, _ in
            Task { await catalog.refreshVersions() }
        }
        .alert("LensWorks", isPresented: Binding(get: { catalog.error != nil }, set: { if !$0 { catalog.error = nil } })) {
            Button("OK") { catalog.error = nil }
        } message: { Text(catalog.error ?? "") }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LensWorks").font(.title2.weight(.semibold))
            HStack {
                Button("Open…") { Task { await catalog.openCatalog(create: false, window: workspace.window) } }
                Button("New…") { Task { await catalog.openCatalog(create: true, window: workspace.window) } }
            }.disabled(catalog.isBusy)
            if let path = catalog.catalogPath {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "photo.stack")
                    .font(.headline).help(path)
                Button("Add Photos…") { Task { await catalog.importFolder(window: workspace.window) } }
                    .disabled(catalog.isBusy)
                Text("Photos · \(catalog.assets.count) shown").font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(catalog.assets) { asset in
                            Button {
                                catalog.selectedPhotoID = asset.id
                            } label: {
                                HStack {
                                    Image(systemName: asset.state == "ready" ? "photo" : "photo.badge.exclamationmark")
                                    Text(asset.filename).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 5).padding(.horizontal, 6)
                                    .background(catalog.selectedPhotoID == asset.id ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).help(asset.originalPath)
                        }
                    }
                }
                HStack {
                    Button("Previous") { Task { await catalog.previousPage() } }
                        .disabled(!catalog.hasPrevious || catalog.isBusy)
                    Button("Next") { Task { await catalog.nextPage() } }
                        .disabled(!catalog.hasMore || catalog.isBusy)
                }
                if let asset = catalog.selectedAsset {
                    Divider()
                    Text(asset.filename).font(.headline).lineLimit(2)
                    Text(URL(fileURLWithPath: asset.originalPath).deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    Button("Create Working Version") { Task { await catalog.createWorkingVersion(workspace: workspace) } }
                        .disabled(catalog.isBusy || !workspace.canSwitch)
                    ForEach(catalog.selectedVersions) { version in
                        Button { Task { await catalog.openVersion(version, workspace: workspace) } } label: {
                            Label(version.name, systemImage: "square.stack.3d.up").lineLimit(1)
                        }.buttonStyle(.plain).help(version.projectPath)
                            .disabled(catalog.isBusy || !workspace.canSwitch)
                    }
                }
            } else {
                Text("Catalogs keep track of your photos in their existing filesystem folders.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            Button("Working Version Folder…") { Task { await catalog.chooseOutput(window: workspace.window) } }
                .disabled(catalog.isBusy)
            if let output = catalog.outputDirectory { Text(output).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(output) }
            if catalog.isBusy { ProgressView().controlSize(.small) }
            Text(catalog.status).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }.padding(14).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityIdentifier("LensWorks.catalogNavigation")
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(catalog.assets) { asset in
                    Button {
                        catalog.selectedPhotoID = asset.id
                        if let version = catalog.selectedVersions.first {
                            Task { await catalog.openVersion(version, workspace: workspace) }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            LensWorksThumbnail(path: asset.previewPath ?? asset.originalPath)
                                .frame(width: 96, height: 58)
                            Text(asset.filename).font(.caption2).lineLimit(1).frame(width: 100)
                        }.padding(4)
                            .background(catalog.selectedPhotoID == asset.id ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .disabled(catalog.isBusy || !workspace.canSwitch)
                        .help(asset.originalPath)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.frame(height: 94)
            .accessibilityLabel("Catalog filmstrip")
            .accessibilityIdentifier("LensWorks.filmstrip")
    }
}

private struct LensWorksThumbnail: View {
    let path: String
    @State private var data: Data?
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: path) {
            data = await Task.detached(priority: .utility) { Self.thumbnail(path) }.value
        }
    }
    nonisolated static func thumbnail(_ path: String) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 192, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
