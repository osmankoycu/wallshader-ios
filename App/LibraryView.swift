import SwiftUI
import WallshaderModel

/// The library — grid on iPhone (root screen), sidebar list on iPad.
/// Thumbnails show the CURRENT DEVICE's variant (auto-derived if untouched):
/// "everything you made on the Mac is already here, iPhone-shaped" (C4).
struct LibraryView: View {
    enum Style { case grid, sidebar }
    let style: Style

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var library: WallpaperLibrary = AppModel.shared.library
    @ObservedObject private var thumbnails = DeviceThumbnailStore.shared
    @Environment(\.undoManager) private var undoManager
    @State private var renaming: WallpaperDocument?
    @State private var renameText = ""

    var body: some View {
        Group {
            if style == .sidebar {
                sidebarList
            } else {
                grid
            }
        }
        .navigationTitle("Wallshader")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newWallpaper()
                } label: {
                    Label("New Wallpaper", systemImage: "plus")
                }
                .accessibilityLabel("New Wallpaper")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $app.showingPaywall) { PaywallView() }
        .alert("Rename Wallpaper", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let doc = renaming {
                    let previous = doc.name
                    library.rename(doc.id, to: renameText)
                    let id = doc.id
                    undoManager?.registerUndo(withTarget: library) { lib in
                        lib.rename(id, to: previous)
                    }
                    undoManager?.setActionName("Rename")
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(library.documents) { doc in
                    Button {
                        app.open(doc.id)
                    } label: {
                        card(doc)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(doc) }
                }
                .onMove(perform: move)
            }
            .padding(16)
        }
    }

    private var sidebarList: some View {
        List(selection: Binding(get: { app.selectedID },
                                set: { if let id = $0 { app.open(id) } })) {
            ForEach(library.documents) { doc in
                HStack(spacing: 10) {
                    thumbnailImage(doc)
                        .frame(width: 64, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(doc.name).lineLimit(1)
                }
                .tag(doc.id)
                .contextMenu { contextMenu(doc) }
            }
            .onMove(perform: move)
        }
        .navigationTitle("Library")
    }

    private func card(_ doc: WallpaperDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnailImage(doc)
                .frame(maxWidth: .infinity)
                .aspectRatio(AppModel.currentDevice.canonicalAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 0.5))
            Text(doc.name)
                .font(.callout)
                .lineLimit(1)
        }
        .accessibilityLabel(Text(doc.name))
    }

    @ViewBuilder
    private func thumbnailImage(_ doc: WallpaperDocument) -> some View {
        if let cg = thumbnails.thumbnail(for: doc, app: app) {
            Image(uiImage: UIImage(cgImage: cg))
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.5))
                Image(systemName: "circle.bottomrighthalf.pattern.checkered")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ doc: WallpaperDocument) -> some View {
        Button {
            renameText = doc.name
            renaming = doc
        } label: { Label("Rename", systemImage: "pencil") }

        Button {
            guard app.gateAddingDocument() else { return }
            if let copy = library.duplicate(doc.id) {
                let id = copy.id
                undoManager?.registerUndo(withTarget: library) { lib in
                    lib.delete(id)
                }
                undoManager?.setActionName("Duplicate")
            }
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

        Button(role: .destructive) {
            deleteWithUndo(doc)
        } label: { Label("Delete", systemImage: "trash") }
    }

    /// Full undo including the deleted photo (C2): snapshot the document
    /// AND its image bytes before deleting; undo restores both.
    private func deleteWithUndo(_ doc: WallpaperDocument) {
        let imageData = library.sourceImageData(for: doc)
        library.delete(doc.id)
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.restore(doc, imagePNG: imageData)
        }
        undoManager?.setActionName("Delete Wallpaper")
    }

    private func move(from source: IndexSet, to destination: Int) {
        library.moveDocuments(from: source, to: destination)
    }

    private func newWallpaper() {
        guard app.gateAddingDocument() else { return }
        let doc = library.createBlank()
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.delete(doc.id)
        }
        undoManager?.setActionName("New Wallpaper")
        app.open(doc.id)
    }
}

/// Current-device variant thumbnails, rendered lazily on-device and cached
/// (C4). Separate from the library's own (desktop-based) thumbnail files.
@MainActor
final class DeviceThumbnailStore: ObservableObject {
    static let shared = DeviceThumbnailStore()

    private var cache: [String: CGImage] = [:]
    private var inFlight: Set<String> = []

    private func key(_ doc: WallpaperDocument) -> String {
        // Stable stamp: JSONEncoder's dictionary order is nondeterministic,
        // so hashing an encode would miss the cache on every call.
        let device = AppModel.currentDevice
        return "\(doc.id)-\(device.rawValue)-\(doc.shaderId ?? "")-\(doc.modifiedAt.timeIntervalSince1970)-\(doc.isCustomized(device))-\(doc.sourceImageCacheKey ?? "")"
    }

    func thumbnail(for doc: WallpaperDocument, app: AppModel) -> CGImage? {
        let key = key(doc)
        if let hit = cache[key] { return hit }
        guard !inFlight.contains(key), let renderer = app.renderer,
              doc.shaderId != nil, doc.isAppliable else { return nil }
        inFlight.insert(key)
        let library = app.library
        let device = AppModel.currentDevice
        let texture = doc.needsSourceImage ? library.loadSourceTexture(for: doc) : nil
        let aspect: Double? = texture.map { Double($0.width) / Double(max(1, $0.height)) }
        guard let params = doc.shaderParams(for: device, imageAspect: aspect) else { return nil }
        let variant = doc.resolvedVariant(for: device, imageAspect: aspect)
        let ambient = library.ambientSpec(for: doc, settings: variant.ambient)
        let px = device.canonicalPixels
        let width = 360
        let height = max(64, Int((Double(width) * px.height / px.width).rounded()))
        let offscreen = OffscreenRendererBox(renderer: renderer)
        Task.detached(priority: .utility) { [weak self] in
            let image = try? offscreen.value.renderImage(
                shaderId: doc.shaderId!, params: params,
                pixelWidth: width, pixelHeight: height,
                pixelRatio: device == .ipad ? 2 : 3,
                timeSeconds: Float(params.frame * 0.001),
                texture: texture, ambient: ambient,
                emulatedTarget: (SIMD2(Float(px.width), Float(px.height)),
                                 device == .ipad ? 2 : 3))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                if let image {
                    self.cache[key] = image
                    self.objectWillChange.send()
                }
            }
        }
        return nil
    }
}

import ShaderCore
/// Sendable box so the detached render task can carry the offscreen renderer.
private struct OffscreenRendererBox: @unchecked Sendable {
    let value: OffscreenRenderer
    init(renderer: ShaderRenderer) { value = OffscreenRenderer(renderer: renderer) }
}
