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

    /// Photos-library grid: edge-to-edge, hairline gutters, floating
    /// chrome over a scrim — no cards, the wallpapers ARE the surface.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 118, maximum: 190), spacing: 2)]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(library.documents) { doc in
                    Button {
                        app.open(doc.id)
                    } label: {
                        thumbnailImage(doc)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(AppModel.currentDevice.canonicalAspect,
                                         contentMode: .fit)
                            .clipped()
                            .contentShape(Rectangle())
                            .accessibilityLabel(Text(doc.name))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(doc) }
                }
                .onMove(perform: move)
            }
            .padding(.top, 2)
        }
        .ignoresSafeArea(edges: .bottom)
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
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

    /// One entry per document — the stamp keyed the whole cache once, so
    /// every save (new modifiedAt) grew it by another ~1 MB CGImage that
    /// was never evicted.
    private var cache: [UUID: (stamp: String, image: CGImage)] = [:]
    private var inFlight: Set<UUID> = []

    private func stamp(_ doc: WallpaperDocument) -> String {
        // Stable stamp: JSONEncoder's dictionary order is nondeterministic,
        // so hashing an encode would miss the cache on every call.
        let device = AppModel.currentDevice
        return "\(device.rawValue)-\(doc.shaderId ?? "")-\(doc.modifiedAt.timeIntervalSince1970)-\(doc.isCustomized(device))-\(doc.sourceImageCacheKey ?? "")"
    }

    /// Returns the cached render — or, while a fresh one is in flight, the
    /// previous (stale) image so edits don't flash a gray placeholder. The
    /// photo decode + adjustment pass + texture upload all run DETACHED;
    /// doing them synchronously here stalled the main thread on every
    /// cache miss (once per save, mid-drag included).
    func thumbnail(for doc: WallpaperDocument, app: AppModel) -> CGImage? {
        let stamp = stamp(doc)
        let hit = cache[doc.id]
        if let hit, hit.stamp == stamp { return hit.image }
        guard !inFlight.contains(doc.id), let renderer = app.renderer,
              doc.shaderId != nil, doc.isAppliable else { return hit?.image }
        inFlight.insert(doc.id)
        let library = app.library
        let device = AppModel.currentDevice
        let sourceURL = doc.needsSourceImage ? library.sourceImageURL(for: doc) : nil
        // The image aspect only shapes auto-variant sizing params, not the
        // ambient settings — safe to resolve those before the decode.
        let ambient = library.ambientSpec(
            for: doc, settings: doc.resolvedVariant(for: device, imageAspect: nil).ambient)
        let px = device.canonicalPixels
        let width = 360
        let height = max(64, Int((Double(width) * px.height / px.width).rounded()))
        let box = RendererBox(renderer: renderer)
        Task.detached(priority: .utility) { [weak self] in
            var texture: MTLTexture?
            if let sourceURL {
                if let adjustments = doc.adjustments, !adjustments.isNeutral,
                   let adjusted = WallpaperLibrary.adjustedImage(at: sourceURL,
                                                                adjustments: adjustments) {
                    texture = try? box.renderer.loadTexture(cgImage: adjusted)
                } else {
                    texture = try? box.renderer.loadTexture(url: sourceURL)
                }
            }
            let aspect = texture.map { Double($0.width) / Double(max(1, $0.height)) }
            var image: CGImage?
            if let params = doc.shaderParams(for: device, imageAspect: aspect) {
                image = try? box.offscreen.renderImage(
                    shaderId: doc.shaderId!, params: params,
                    pixelWidth: width, pixelHeight: height,
                    pixelRatio: device == .ipad ? 2 : 3,
                    timeSeconds: Float(params.frame * 0.001),
                    texture: texture, ambient: ambient,
                    emulatedTarget: (SIMD2(Float(px.width), Float(px.height)),
                                     device == .ipad ? 2 : 3))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(doc.id)
                if let image {
                    self.cache[doc.id] = (stamp, image)
                    self.objectWillChange.send()
                }
            }
        }
        return hit?.image
    }
}

import ShaderCore
/// Sendable box so the detached render task can decode the photo, upload
/// the texture, and run the offscreen render off the main thread.
private struct RendererBox: @unchecked Sendable {
    let renderer: ShaderRenderer
    let offscreen: OffscreenRenderer
    init(renderer: ShaderRenderer) {
        self.renderer = renderer
        offscreen = OffscreenRenderer(renderer: renderer)
    }
}
