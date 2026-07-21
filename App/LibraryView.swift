import CryptoKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WallshaderModel

/// The library — the Photos-style grid, root screen on EVERY device (the
/// iPad's old sidebar split view retired: one structure, iPhone-proven).
/// Thumbnails show the CURRENT DEVICE's variant (auto-derived if untouched):
/// "everything you made on the Mac is already here, iPhone-shaped" (C4).
struct LibraryView: View {
    /// Photos-style zoom into the detail screen.
    var zoomNamespace: Namespace.ID? = nil

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var library: WallpaperLibrary = AppModel.shared.library
    @ObservedObject private var thumbnails = DeviceThumbnailStore.shared
    @Environment(\.undoManager) private var undoManager
    @State private var renaming: WallpaperDocument?
    @State private var renameText = ""
    /// The home's two shelves (Photos' Library/Collections pill).
    enum LibraryTab: Hashable { case all, favorites }
    @State private var tab: LibraryTab = .all
    // Photos-style select mode (grid only): bulk share + bulk delete.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var preparingShare = false
    // The + flow: a compact Shader/Photo sheet. The document is created in
    // the BACKGROUND and the edit screen opens directly; Done returns to
    // the grid, Cancel discards the document again. Actions run on the
    // sheet's onDismiss (presenting a cover mid-dismissal misfires).
    private enum PendingNewAction { case shader, photo(URL), wallshader(URL) }
    private struct EditSession: Identifiable {
        let id: UUID
        let model: EditorModel
    }
    @State private var showingNewSheet = false
    @State private var pendingNewAction: PendingNewAction?
    @State private var editSession: EditSession?
    /// The freshly created document stays OUT of the grid while its edit
    /// session runs — it appears when you come back with Done (no tile
    /// flashing in behind the opening cover).
    @State private var hiddenNewDocID: UUID?

    /// Each tab instance filters for ITS OWN shelf — filtering off the
    /// shared selection made the outgoing tab's grid reflow (animated!)
    /// mid-switch, which read as the whole grid sliding away.
    private func documents(for shelf: LibraryTab) -> [WallpaperDocument] {
        var docs = library.documents
        if let hiddenNewDocID {
            docs = docs.filter { $0.id != hiddenNewDocID }
        }
        if shelf == .favorites {
            docs = docs.filter { $0.favorite == true }
        }
        return docs
    }

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
                                  : .spring(response: 0.32, dampingFraction: 0.72).delay(0.12),
                           value: hidden)
        }
    }

    var body: some View {
        grid
            .navigationTitle("Wallshader")
        .sheet(isPresented: $showingShare) { ShareSheet(items: shareURLs) }
        .sheet(isPresented: $showingNewSheet, onDismiss: runPendingNewAction) {
            NewWallpaperSheet(
                onShader: { pendingNewAction = .shader; showingNewSheet = false },
                onPhotoPicked: { url in
                    pendingNewAction = .photo(url)
                    showingNewSheet = false
                },
                onWallshaderPicked: { url in
                    pendingNewAction = .wallshader(url)
                    showingNewSheet = false
                })
        }
        .fullScreenCover(item: $editSession, onDismiss: { hiddenNewDocID = nil }) { session in
            EditView(model: session.model, onCancel: {
                library.delete(session.model.documentID)
            })
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
    /// iPad breathes: larger tiles, wider gutters (one structure, two
    /// densities).
    private static let gridGap: CGFloat =
        UIDevice.current.userInterfaceIdiom == .pad ? 16 : 6
    private static let tileCorner: CGFloat =
        UIDevice.current.userInterfaceIdiom == .pad ? 14 : 10

    private var columns: [GridItem] {
        UIDevice.current.userInterfaceIdiom == .pad
            ? [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: Self.gridGap)]
            : [GridItem(.adaptive(minimum: 118, maximum: 190), spacing: Self.gridGap)]
    }

    private var grid: some View {
        // Hand-built Photos layout: the shelf pill LEFT, the + circle
        // RIGHT. The system TabView couldn't give this without a
        // search-role tab (whose lazy first build flashed a foreign grid),
        // and its 2-tab pill centers. Both shelves stay ALIVE and swap by
        // opacity, so switching can't reflow or slide anything.
        ZStack {
            gridContent(shelf: .all)
                .opacity(tab == .all ? 1 : 0)
                .allowsHitTesting(tab == .all)
            gridContent(shelf: .favorites)
                .opacity(tab == .favorites ? 1 : 0)
                .allowsHitTesting(tab == .favorites)
        }
        .libraryBottomBar(visible: true, bottomBar)
    }

    /// ONE bottom bar, a REAL safeAreaBar like the pinned header: the
    /// system draws its progressive blur behind it and seats it at the
    /// default bar position over the home indicator. Browse chrome (pill +
    /// plus) and the select controls swap in place.
    private var bottomBar: some View {
        ZStack {
            HStack(alignment: .center) {
                tabPill
                    .modifier(ChromeSwap(hidden: selecting))
                Spacer()
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
            }
            .padding(.horizontal, 20)

            selectBar
                .modifier(ChromeSwap(hidden: !selecting))
        }
        .frame(height: 62)
    }

    private func gridContent(shelf: LibraryTab) -> some View {
        let docs = documents(for: shelf)
        return ScrollViewReader { proxy in
        ScrollView {
            if shelf == .favorites && docs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No Favorites")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Tap and hold a wallpaper to add to favorites.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .frame(maxWidth: .infinity)
                // TRUE screen-center: the fixed top padding sat high (and
                // clearly off-center on the landscape iPad) — size the
                // empty state to the scroll container and center within.
                .containerRelativeFrame(.vertical, alignment: .center)
            }
            LazyVGrid(columns: columns, spacing: Self.gridGap) {
                ForEach(docs) { doc in
                    gridTile(doc, shelf: shelf)
                        .id(doc.id)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                .onMove(perform: move)
            }
            // Photos-style reflow: inserts pop in, deletes let the
            // neighbors spring into place. Keyed to the ID LIST so only
            // membership/order changes animate (select-mode toggles and
            // thumbnail refreshes don't).
            .animation(.spring(response: 0.4, dampingFraction: 0.85),
                       value: docs.map(\.id))
            .padding(.horizontal, Self.gridGap * 1.5)
            .padding(.top, 2)
            // The grid draws under the home indicator (ignored safe area),
            // so give the content a bottom runway: the last row must scroll
            // fully clear of the floating tab bar AND the screen edge
            // (bar 62 + home inset + breathing room). This also keeps the
            // return zoom's minimal scroll from parking its target tile
            // behind the bar.
            .padding(.bottom, 128)
        }
        // An empty shelf is a STILL page: nothing to scroll, no bounce.
        .scrollDisabled(shelf == .favorites && docs.isEmpty)
        .softTopEdge()
        .softBottomEdge()
        .ignoresSafeArea(edges: .bottom)
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .libraryHeaderBar(header(for: shelf))
        // While the detail pager swipes between wallpapers, keep the grid
        // scrolled to the current one so the dismiss zoom has its tile on
        // screen to land on (Photos behavior). ONLY the active shelf
        // follows — the shelves manage their scroll independently — and
        // the nil anchor scrolls the MINIMUM needed, so a tile already on
        // screen keeps the grid exactly where the user left it.
        .onChange(of: app.selectedID) { _, id in
            guard let id, !app.path.isEmpty, shelf == tab else { return }
            proxy.scrollTo(id)
        }
        }
    }

    /// Photos' Library header, hand-built and PINNED: the big title +
    /// count at left, the two circle buttons on the same line at right,
    /// the grid scrolling underneath a top scrim. (The system nav bar
    /// can't align its items with a large title, hence custom.)
    private func header(for shelf: LibraryTab) -> some View {
        let count = documents(for: shelf).count
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf == .favorites ? "Favorites" : "Wallshader")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(count == 1 ? "1 Wallpaper" : "\(count) Wallpapers")
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
    private func gridTile(_ doc: WallpaperDocument, shelf: LibraryTab) -> some View {
        let isSelected = selected.contains(doc.id)
        let tile = Button {
            if selecting {
                if isSelected { selected.remove(doc.id) } else { selected.insert(doc.id) }
            } else {
                // From Favorites, the detail pager walks favorites ONLY —
                // frozen at open so a mid-session unfavorite can't yank
                // pages out from underfoot.
                app.open(doc.id, scope: shelf == .favorites
                    ? documents(for: .favorites).map(\.id) : nil)
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
                .overlay(alignment: .bottomTrailing) {
                    // Favorites wear a small persistent heart — pops in on
                    // add, pops away on remove. Only on All: the Favorites
                    // shelf IS the indicator.
                    if shelf == .all && doc.favorite == true {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 5)
                            .padding(7)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
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
        // Only the ACTIVE shelf registers return targets: both grids stay
        // alive (opacity swap), and a favorite registered twice in the
        // namespace resolved to the hidden All grid — the return zoom then
        // shrank to screen center instead of the Favorites tile.
        .zoomTransitionSource(id: doc.id, in: shelf == tab ? zoomNamespace : nil)
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

            Menu {
                Section {
                    Button(role: .destructive) {
                        bulkDelete()
                    } label: {
                        Label(selected.count == 1 ? "Delete Wallpaper"
                              : "Delete \(selected.count) Wallpapers",
                              systemImage: "trash")
                    }
                } header: {
                    Text(selected.count == 1
                         ? "This wallpaper will be deleted from your library."
                         : "These wallpapers will be deleted from your library.")
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .semibold))
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

    /// Photos' Library/Collections pill: All + Favorites.
    private var tabPill: some View {
        HStack(spacing: 0) {
            tabButton(.all, title: "All",
                      systemImage: "circle.bottomrighthalf.pattern.checkered")
            tabButton(.favorites, title: "Favorites", systemImage: "heart")
        }
        .padding(4)
        .chromeGlass(in: Capsule())
    }

    private func tabButton(_ target: LibraryTab, title: String,
                           systemImage: String) -> some View {
        let selected = tab == target
        return Button {
            tab = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(selected ? Color.accentColor : .white)
            // Equal, generous segments — unequal intrinsic widths made the
            // first pill feel untappable at the edges.
            .frame(width: 88, height: 56)
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.14))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private func contextMenu(_ doc: WallpaperDocument) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                library.setFavorite(!(doc.favorite == true), id: doc.id)
            }
        } label: {
            doc.favorite == true
                ? Label("Remove from Favorites", systemImage: "heart.slash")
                : Label("Add to Favorites", systemImage: "heart")
        }

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

    private func runPendingNewAction() {
        guard let action = pendingNewAction else { return }
        pendingNewAction = nil
        guard app.gateAddingDocument() else { return }
        switch action {
        case .wallshader(let url):
            // Files hands out security-scoped URLs; the import copies the
            // recipe (and embedded photo) into the library.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            app.importWallshader(from: url)
        case .shader:
            let doc = library.createBlank()
            _ = library.assignKind(.procedural, to: doc.id)
            hiddenNewDocID = doc.id
            registerCreationUndo(doc.id)
            editSession = EditSession(id: doc.id,
                                      model: EditorModel(app: app, documentID: doc.id))
        case .photo(let url):
            let doc = library.createBlank()
            _ = library.assignKind(.imageBased, to: doc.id)
            hiddenNewDocID = doc.id
            registerCreationUndo(doc.id)
            let model = EditorModel(app: app, documentID: doc.id)
            model.importImage(url: url) { [self] in
                editSession = EditSession(id: doc.id, model: model)
            }
        }
    }

    private func registerCreationUndo(_ id: UUID) {
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.delete(id)
        }
        undoManager?.setActionName("New Wallpaper")
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
        // v2: iPad went landscape — the token busts portrait-era caches.
        return "\(device.rawValue)v2-\(doc.shaderId ?? "")-\(doc.modifiedAt.timeIntervalSince1970)-\(doc.isCustomized(device))-\(doc.sourceImageCacheKey ?? "")"
    }

    /// Returns the cached render — or, while a fresh one is in flight, the
    /// previous (stale) image so edits don't flash a gray placeholder. The
    /// photo decode + adjustment pass + texture upload all run DETACHED;
    /// doing them synchronously here stalled the main thread on every
    /// cache miss (once per save, mid-drag included).
    ///
    /// Renders persist to disk (stamp-keyed PNGs): a relaunch reads them
    /// back instead of re-rendering the whole library — the launch-time
    /// full-res render storm is gone, the grid fills instantly.
    func thumbnail(for doc: WallpaperDocument, app: AppModel) -> CGImage? {
        let stamp = stamp(doc)
        let hit = cache[doc.id]
        if let hit, hit.stamp == stamp { return hit.image }
        guard !inFlight.contains(doc.id), let renderer = app.renderer,
              doc.shaderId != nil, doc.isAppliable else { return hit?.image }
        inFlight.insert(doc.id)
        if !cleanedUp {
            cleanedUp = true
            Self.cleanup(keeping: app.library.documents.map(\.id))
        }
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
        let diskURL = Self.diskURL(id: doc.id, stamp: stamp)
        Task.detached(priority: .utility) { [weak self] in
            // Disk first: a relaunch rehydrates without touching the GPU.
            if let stored = Self.readPNG(at: diskURL) {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(doc.id)
                    self.cache[doc.id] = (stamp, stored)
                    self.objectWillChange.send()
                }
                return
            }
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
                let ratio: Float = device == .ipad ? 2 : 3
                // Every thumbnail is the TRUE wallpaper: rendered at the
                // device's canonical pixels and scaled down — what you tap
                // is exactly what the detail screen resumes (and the
                // fragCoord pair can't be miniaturized at all). Offline and
                // disk-cached, so the full-res cost is paid once per edit.
                let full = try? box.offscreen.renderImage(
                    shaderId: doc.shaderId!, params: params,
                    pixelWidth: Int(px.width), pixelHeight: Int(px.height),
                    pixelRatio: ratio,
                    timeSeconds: Float(params.frame * 0.001),
                    texture: texture, ambient: ambient)
                image = full.flatMap { Self.downscaled($0, width: width, height: height) }
            }
            if let image { Self.writePNG(image, id: doc.id, stamp: stamp, to: diskURL) }
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

    // MARK: - Disk persistence (regenerable — lives in Caches)

    private var cleanedUp = false

    /// Launch-time bulk hydrate: read EVERY stored thumbnail in one detached
    /// pass and publish once — the grid's first frame is fully populated
    /// instead of tiles popping in one by one as their reads land.
    func preload(docs: [WallpaperDocument]) {
        let wanted: [(id: UUID, stamp: String, url: URL)] = docs.compactMap { doc in
            let stamp = stamp(doc)
            guard cache[doc.id]?.stamp != stamp,
                  let url = Self.diskURL(id: doc.id, stamp: stamp) else { return nil }
            return (doc.id, stamp, url)
        }
        guard !wanted.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            var loaded: [(UUID, String, CGImage)] = []
            for entry in wanted {
                if let image = Self.readPNG(at: entry.url) {
                    loaded.append((entry.id, entry.stamp, image))
                }
            }
            guard !loaded.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, stamp, image) in loaded where self.cache[id]?.stamp != stamp {
                    self.cache[id] = (stamp, image)
                }
                self.objectWillChange.send()
            }
        }
    }

    nonisolated private static var diskDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("DeviceThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stamps carry arbitrary strings (photo cache keys) — hash them into a
    /// stable filename. Hasher is launch-seeded, so SHA256 it is.
    nonisolated private static func diskURL(id: UUID, stamp: String) -> URL? {
        guard let dir = diskDirectory else { return nil }
        let digest = SHA256.hash(data: Data(stamp.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(id.uuidString)-\(digest).png")
    }

    nonisolated private static func readPNG(at url: URL?) -> CGImage? {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated private static func writePNG(_ image: CGImage, id: UUID, stamp: String, to url: URL?) {
        guard let url else { return }
        // Encode in memory, then one atomic Data.write — ImageIO's direct
        // file writer (CGImageDestinationCreateWithURL + Finalize) fails on
        // device hardware while the in-memory encoder is fine everywhere.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            print("thumb-disk: png encode FAILED \(url.lastPathComponent)")
            return
        }
        // A changed stamp means the old render is stale — drop its file.
        removeFiles(for: id, except: url.lastPathComponent)
        do {
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            print("thumb-disk: file write FAILED \(url.lastPathComponent): \(error)")
        }
    }

    nonisolated private static func removeFiles(for id: UUID, except keep: String? = nil) {
        guard let dir = diskDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasPrefix(id.uuidString) && file != keep {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// Once per launch: drop files for documents that no longer exist.
    nonisolated private static func cleanup(keeping ids: [UUID]) {
        let valid = Set(ids.map(\.uuidString))
        Task.detached(priority: .utility) {
            guard let dir = diskDirectory,
                  let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for file in files {
                let prefix = String(file.prefix(36))
                if !valid.contains(prefix) {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
                }
            }
        }
    }

    nonisolated private static func downscaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// The + choice, compact and two-step: Shader/Photo cards first; Photo
/// swaps the SAME small sheet to the source rows (Photo Library opens the
/// system picker directly) instead of a tall list sheet.
private struct NewWallpaperSheet: View {
    let onShader: () -> Void
    let onPhotoPicked: (URL) -> Void
    let onWallshaderPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosingPhotoSource = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var showingWallshaderFiles = false

    var body: some View {
        VStack(spacing: 16) {
            Text(choosingPhotoSource ? "Add Photo" : "New Wallpaper")
                .font(.headline)
                .padding(.top, 18)
            if choosingPhotoSource {
                VStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        sourceRow("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showingFiles = true
                    } label: {
                        sourceRow("Files", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        card(title: "Shader",
                             subtitle: "A generated look: gradients, noise, metaballs and more.",
                             systemImage: "circle.bottomrighthalf.pattern.checkered",
                             action: onShader)
                        card(title: "Photo",
                             subtitle: "Your own photo, styled by a shader.",
                             systemImage: "photo",
                             action: { withAnimation(.easeInOut(duration: 0.15)) { choosingPhotoSource = true } })
                    }
                    .frame(height: 150)

                    // The wide thin third row: a shared .wallshader file
                    // (AirDrop, mail, Files) imported straight into the
                    // library, Mac parity.
                    Button {
                        showingWallshaderFiles = true
                    } label: {
                        sourceRow("Import a Wallshader File",
                                  systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(choosingPhotoSource ? 250 : 312)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("picked-\(UUID().uuidString)")
                    try? data.write(to: tmp)
                    onPhotoPicked(tmp)
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                onPhotoPicked(url)
            }
        }
        .fileImporter(isPresented: $showingWallshaderFiles,
                      allowedContentTypes: [Self.wallshaderType]) { result in
            if case .success(let url) = result {
                onWallshaderPicked(url)
            }
        }
    }

    /// The app's own exported document type (matches Info.plist).
    private static let wallshaderType =
        UTType(exportedAs: "com.innovationBox.wallshader.wallpaper")

    private func sourceRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
            Text(title)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
