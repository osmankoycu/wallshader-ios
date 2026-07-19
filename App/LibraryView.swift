import SwiftUI
import WallshaderModel

/// The library — grid on iPhone (root screen), sidebar list on iPad.
/// Thumbnails show the CURRENT DEVICE's variant (auto-derived if untouched):
/// "everything you made on the Mac is already here, iPhone-shaped" (C4).
struct LibraryView: View {
    enum Style { case grid, sidebar }
    let style: Style
    /// Photos-style zoom into the detail screen (grid only).
    var zoomNamespace: Namespace.ID? = nil

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var library: WallpaperLibrary = AppModel.shared.library
    @ObservedObject private var thumbnails = DeviceThumbnailStore.shared
    @Environment(\.undoManager) private var undoManager
    @State private var renaming: WallpaperDocument?
    @State private var renameText = ""
    // Photos-style select mode (grid only): bulk share + bulk delete.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmingBulkDelete = false
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var preparingShare = false
    // The + flow: a Shader/Photo choice sheet; Photo runs the sources
    // sheet against a just-created document (deleted again if abandoned).
    @State private var showingNewSheet = false
    @State private var newPhotoModel: EditorModel?
    @State private var showingPhotoSources = false
    @State private var photoPicked = false

    /// The select bar's staged entrance: in after the + finished popping
    /// down, out fast. ONE transition on the container — per-child delayed
    /// transitions accumulated layout state when toggled rapidly (the bar
    /// drifted sideways), so the children carry none.
    private static let stagedBar = AnyTransition.asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.94))
            .animation(.spring(response: 0.32, dampingFraction: 0.72).delay(0.18)),
        removal: AnyTransition.opacity.animation(.easeIn(duration: 0.12)))

    /// Value-driven staged swap for the chrome that trades places with the
    /// select bar (+, Settings): the views never leave the hierarchy, so
    /// interrupted toggles can't corrupt layout — out fast, back in with a
    /// delayed spring.
    private struct ChromeSwap: ViewModifier {
        let hidden: Bool
        func body(content: Content) -> some View {
            content
                .scaleEffect(hidden ? 0.5 : 1)
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .animation(hidden ? .easeIn(duration: 0.14)
                                  : .spring(response: 0.32, dampingFraction: 0.72).delay(0.18),
                           value: hidden)
        }
    }

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
            if style == .sidebar {
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
        }
        .confirmationDialog("Delete \(selected.count) wallpapers?",
                            isPresented: $confirmingBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { bulkDelete() }
        }
        .sheet(isPresented: $showingShare) { ShareSheet(items: shareURLs) }
        .sheet(isPresented: $showingNewSheet) {
            NewWallpaperSheet(onShader: chooseShader, onPhoto: choosePhoto)
        }
        .sheet(isPresented: $showingPhotoSources, onDismiss: photoSourcesDismissed) {
            if let model = newPhotoModel {
                PhotoSourcesSheet(model: model,
                                  onPicked: { photoPicked = true },
                                  onImported: { openNewPhotoDocument() })
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

    /// Rounded tiles with one gutter width everywhere: between columns,
    /// between rows, AND at the screen edges.
    private static let gridGap: CGFloat = 6
    private static let tileCorner: CGFloat = 10

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 118, maximum: 190), spacing: Self.gridGap)]
    }

    private var grid: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gridGap) {
                ForEach(library.documents) { doc in
                    gridTile(doc)
                        .id(doc.id)
                }
                .onMove(perform: move)
            }
            .padding(.horizontal, Self.gridGap * 1.5)
            .padding(.top, 2)
            // The grid draws under the home indicator (ignored safe area),
            // so give the content a bottom runway: the last row can scroll
            // fully clear of the screen edge.
            .padding(.bottom, 48)
        }
        .softTopEdge()
        .softBottomEdge()
        .ignoresSafeArea(edges: .bottom)
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .libraryHeaderBar(header)
        .overlay(alignment: .bottomTrailing) {
            // Photos' big corner button (its search): our New Wallpaper,
            // hugging the tab-bar zone. Value-driven pop (down fast on
            // entering select mode, back with a delayed spring after the
            // bar left).
            Button {
                showingNewSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .chromeGlass(in: Circle(), tint: .accentColor)
            }
            .accessibilityLabel("New Wallpaper")
            .modifier(ChromeSwap(hidden: selecting))
            .padding(.trailing, 20)
            .padding(.bottom, 2)
        }
        .libraryBottomBar(visible: selecting, selectBar.transition(Self.stagedBar))
        // While the detail pager swipes between wallpapers, keep the grid
        // scrolled to the current one so the dismiss zoom has its tile on
        // screen to land on (Photos behavior).
        .onChange(of: app.selectedID) { _, id in
            guard let id, !app.path.isEmpty else { return }
            proxy.scrollTo(id, anchor: .center)
        }
        }
    }

    /// Photos' Library header, hand-built and PINNED: the big title +
    /// count at left, the two circle buttons on the same line at right,
    /// the grid scrolling underneath a top scrim. (The system nav bar
    /// can't align its items with a large title, hence custom.)
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallshader")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(library.documents.count == 1 ? "1 Wallpaper"
                     : "\(library.documents.count) Wallpapers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .chromeGlass(in: Circle())
            }
            .accessibilityLabel("Settings")
            .modifier(ChromeSwap(hidden: selecting))
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    selecting.toggle()
                    selected.removeAll()
                }
            } label: {
                Image(systemName: selecting ? "xmark" : "circle.grid.2x2.topleft.checkmark.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .chromeGlass(in: Circle())
            }
            .accessibilityLabel(selecting ? "Done Selecting" : "Select")
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .background {
            // OS 26 gets the real progressive blur from softTopEdge();
            // older systems fall back to a gradient scrim.
            if #available(iOS 26.0, *) {
                Color.clear
            } else {
                LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0),
                                       .init(color: .black.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -36)
                    .ignoresSafeArea(edges: .top)
            }
        }
    }

    @ViewBuilder
    private func gridTile(_ doc: WallpaperDocument) -> some View {
        let isSelected = selected.contains(doc.id)
        let tile = Button {
            if selecting {
                if isSelected { selected.remove(doc.id) } else { selected.insert(doc.id) }
            } else {
                app.open(doc.id)
            }
        } label: {
            thumbnailImage(doc)
                .frame(maxWidth: .infinity)
                .aspectRatio(AppModel.currentDevice.canonicalAspect,
                             contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Self.tileCorner))
                // The glass family's rim light, as a hairline: a real
                // glassEffect would blur/tint the artwork (and cost GPU per
                // tile) — a lit gradient stroke in plusLighter reads the
                // same and is free.
                .overlay {
                    RoundedRectangle(cornerRadius: Self.tileCorner)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        .blendMode(.plusLighter)
                }
                .overlay(alignment: .bottomLeading) {
                    if selecting && isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .font(.system(size: 22))
                            .padding(6)
                    }
                }
                .overlay {
                    if selecting && isSelected {
                        RoundedRectangle(cornerRadius: Self.tileCorner)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Self.tileCorner))
                .accessibilityLabel(Text(doc.name))
        }
        .buttonStyle(.plain)
        .zoomTransitionSource(id: doc.id, in: zoomNamespace)
        // ONE stable identity: branching tile vs tile.contextMenu swapped
        // the view identity on select-mode toggles, so every thumbnail got
        // removed+reinserted — the "all images flick" report. An empty
        // menu builder is a no-op, so the modifier can stay attached.
        tile.contextMenu {
            if !selecting { contextMenu(doc) }
        }
    }

    /// Photos' select-mode bar: Share left, count center, Delete right.
    private var selectBar: some View {
        HStack {
            Button {
                prepareShare()
            } label: {
                Group {
                    if preparingShare {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .chromeGlass(in: Circle())
            }
            .disabled(selected.isEmpty || preparingShare)
            .opacity(selected.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Share Selected")

            Spacer()

            Text(selected.isEmpty ? "Select Items" : "\(selected.count) Selected")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                confirmingBulkDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .chromeGlass(in: Circle())
            }
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Delete Selected")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// One undo step restores every deleted wallpaper (photos included).
    private func bulkDelete() {
        let docs = library.documents.filter { selected.contains($0.id) }
        let snapshots = docs.map { ($0, library.sourceImageData(for: $0)) }
        for doc in docs { library.delete(doc.id) }
        undoManager?.registerUndo(withTarget: library) { lib in
            for (doc, image) in snapshots { lib.restore(doc, imagePNG: image) }
        }
        undoManager?.setActionName(docs.count == 1 ? "Delete Wallpaper" : "Delete Wallpapers")
        selected.removeAll()
    }

    /// Bulk share renders each selection at device resolution (the same
    /// output the detail screen's Share produces), then hands the PNGs to
    /// the system sheet.
    private func prepareShare() {
        guard let renderer = app.renderer, !selected.isEmpty else { return }
        let docs = library.documents.filter { selected.contains($0.id) }
        let device = AppModel.currentDevice
        let box = RendererBox(renderer: renderer)
        let jobs: [(doc: WallpaperDocument, source: URL?, ambient: AmbientRenderSpec?)] = docs.map {
            ($0,
             $0.needsSourceImage ? library.sourceImageURL(for: $0) : nil,
             library.ambientSpec(for: $0, settings: $0.resolvedVariant(for: device, imageAspect: nil).ambient))
        }
        preparingShare = true
        Task {
            var urls: [URL] = []
            for job in jobs {
                if let url = await Self.renderShareURL(job: job, device: device, box: box) {
                    urls.append(url)
                }
            }
            await MainActor.run {
                preparingShare = false
                guard !urls.isEmpty else { return }
                shareURLs = urls
                showingShare = true
            }
        }
    }

    private static func renderShareURL(job: (doc: WallpaperDocument, source: URL?, ambient: AmbientRenderSpec?),
                                       device: DeviceClass,
                                       box: RendererBox) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let doc = job.doc
            guard let shaderId = doc.shaderId else { return nil }
            var texture: MTLTexture?
            if let source = job.source {
                if let adjustments = doc.adjustments, !adjustments.isNeutral,
                   let adjusted = WallpaperLibrary.adjustedImage(at: source,
                                                                adjustments: adjustments) {
                    texture = try? box.renderer.loadTexture(cgImage: adjusted)
                } else {
                    texture = try? box.renderer.loadTexture(url: source)
                }
            }
            let aspect = texture.map { Double($0.width) / Double(max(1, $0.height)) }
            guard let params = doc.shaderParams(for: device, imageAspect: aspect) else { return nil }
            let px = device.canonicalPixels
            guard let image = try? box.offscreen.renderImage(
                shaderId: shaderId, params: params,
                pixelWidth: Int(px.width), pixelHeight: Int(px.height),
                pixelRatio: device == .ipad ? 2 : 3,
                timeSeconds: Float(params.frame * 0.001),
                texture: texture, ambient: job.ambient) else { return nil }
            let name = doc.name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
                .joined(separator: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(name).appendingPathExtension("png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard (try? box.offscreen.writePNG(image, to: url)) != nil else { return nil }
            return url
        }.value
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

    // MARK: - The + flow (Shader / Photo choice)

    private func chooseShader() {
        showingNewSheet = false
        guard app.gateAddingDocument() else { return }
        let doc = library.createBlank()
        _ = library.assignKind(.procedural, to: doc.id)
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.delete(doc.id)
        }
        undoManager?.setActionName("New Wallpaper")
        app.open(doc.id)
    }

    private func choosePhoto() {
        showingNewSheet = false
        guard app.gateAddingDocument() else { return }
        let doc = library.createBlank()
        _ = library.assignKind(.imageBased, to: doc.id)
        newPhotoModel = EditorModel(app: app, documentID: doc.id)
        photoPicked = false
        showingPhotoSources = true
    }

    /// The wallpaper only really exists once a photo landed: abandoning
    /// the sources sheet deletes the placeholder again, silently.
    private func photoSourcesDismissed() {
        guard let model = newPhotoModel, !photoPicked else { return }
        library.delete(model.documentID)
        newPhotoModel = nil
    }

    private func openNewPhotoDocument() {
        guard let model = newPhotoModel else { return }
        let id = model.documentID
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.delete(id)
        }
        undoManager?.setActionName("New Wallpaper")
        newPhotoModel = nil
        app.open(id)
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

/// The + choice: the type-choice cards, sheet-sized.
private struct NewWallpaperSheet: View {
    let onShader: () -> Void
    let onPhoto: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Wallpaper")
                .font(.headline)
                .padding(.top, 18)
            HStack(spacing: 12) {
                card(title: "Shader",
                     subtitle: "A generated look \u{2014} gradients, noise, metaballs\u{2026}",
                     systemImage: "circle.bottomrighthalf.pattern.checkered",
                     action: onShader)
                card(title: "Photo",
                     subtitle: "Your own photo, styled by an effect.",
                     systemImage: "photo",
                     action: onPhoto)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func card(title: String, subtitle: String, systemImage: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// A custom top bar that PARTICIPATES in scroll edge effects: on OS 26
    /// safeAreaBar is what makes the system draw its progressive blur
    /// behind the header (safeAreaInset content doesn't get it) — older
    /// systems fall back to the inset + the header's own gradient scrim.
    @ViewBuilder
    func libraryHeaderBar<Header: View>(_ header: Header) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) { header }
        } else {
            safeAreaInset(edge: .top, spacing: 0) { header }
        }
    }

    /// Bottom counterpart for the select bar: safeAreaBar so OS 26 draws
    /// its progressive blur behind the bar (same treatment as the header).
    @ViewBuilder
    func libraryBottomBar<Bar: View>(visible: Bool, _ bar: Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0) { if visible { bar } }
        } else {
            overlay(alignment: .bottom) { if visible { bar } }
        }
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
