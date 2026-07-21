import ShaderCore
import SwiftUI
import WallshaderModel

/// The wallpaper DETAIL screen — modeled on the iOS Photos detail view:
/// full-bleed live content on black, floating pill chrome, a filmstrip of
/// the library for swiping between wallpapers, and one bottom action bar:
/// Share · [Animated · Save · Edit] · Delete.
struct DetailView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var library: WallpaperLibrary = AppModel.shared.library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @State var currentID: UUID
    /// Photos-style zoom back to the grid tile (nil on iPad's split view).
    var zoomNamespace: Namespace.ID?
    // Detail→edit morph: ONE hero preview layer flies between full screen
    // and the editor's measured slot; the pager's own page hides while it
    // is active and the editor UI fades in around it.
    @State private var heroActive = false
    @State private var editorRevealed = false
    /// Return flight in progress: the detail chrome stays hidden and then
    /// simply APPEARS at the end — no reverse slide (feedback: the chrome
    /// only becomes visible once the wallpaper is fullscreen again).
    @State private var closingEditor = false
    /// Binary fullscreen-fit inside the editor: the hero flies slot ↔ full
    /// while all editor chrome hovers above it.
    @State private var editorZoomed = false
    @State private var editSlotAnchor: Anchor<CGRect>?
    @StateObject private var models = ModelCache()
    @State private var editing = false
    @State private var chromeHidden = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showingGuide = false
    @State private var saveError: String?
    /// The pager's scroll position. A real state, NOT a computed binding
    /// to currentID: a computed get told ScrollView it was already on the
    /// target page, so a freshly pushed detail never scrolled and showed
    /// the FIRST wallpaper regardless of what was tapped. Starts nil and
    /// is asserted after layout.
    @State private var pagerID: UUID?
    // Filmstrip scrubbing (iOS 18 scroll geometry): the strip is a
    // center-locked scrubber — dragging it retargets the current
    // wallpaper tick by tick; taps jump instantly.
    @State private var stripScrubbing = false
    @State private var stripBaseline: CGFloat?
    @State private var stripTapJump = false
    @State private var showingSizeSheet = false
    @State private var shareItem: URL?
    @State private var exportItem: URL?

    init(documentID: UUID, zoomNamespace: Namespace.ID? = nil) {
        _currentID = State(initialValue: documentID)
        self.zoomNamespace = zoomNamespace
    }

    private func model(for id: UUID) -> EditorModel {
        models.model(for: id, undoManager: undoManager)
    }

    private var currentModel: EditorModel { model(for: currentID) }
    private var currentDocument: WallpaperDocument? { library.document(id: currentID) }

    /// What the pager, filmstrip and neighbor logic walk: the shelf scope
    /// frozen at open (Favorites), or the whole library.
    private var pagedDocuments: [WallpaperDocument] {
        if let ids = app.detailScopeIDs {
            return ids.compactMap { library.document(id: $0) }
        }
        return library.documents
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Full-bleed pager over the library. A paging ScrollView, not
            // TabView(.page): pages slide side by side like Photos (the
            // tab style eased pages in place, which read as a weird
            // springy morph). Only the current page and its neighbors get
            // a live Metal view — the rest stay black, or a detail view
            // over a big library would spin up every photo texture at once.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 24) {
                    ForEach(pagedDocuments) { doc in
                        Group {
                            if isNeighbor(doc.id) {
                                pagePreview(doc)
                            } else {
                                Color.black
                            }
                        }
                        // Fixed to the SCREEN, not the container: the
                        // status bar toggling with the chrome shifts the
                        // safe area, and container-relative pages rescaled
                        // visibly with it. Screen points never move.
                        .frame(width: UIScreen.main.bounds.width,
                               height: UIScreen.main.bounds.height)
                        .id(doc.id)
                    }
                }
                .scrollTargetLayout()
            }
            // viewAligned (one page per swipe), not .paging: paging
            // strides by container width, so a gutter between pages would
            // accumulate misalignment page after page.
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollIndicators(.hidden)
            .scrollPosition(id: $pagerID)
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
            }
        }
        // The chrome lives in an OVERLAY, not as a ZStack sibling: layout
        // siblings re-lay the whole container on every show/hide, and the
        // pager's realignment drifted a couple of pixels each toggle.
        // Overlays never touch the base layout.
        .overlay {
            if !chromeHidden {
                chrome
            }
        }
        .navigationBarHidden(true)
        // ALWAYS hidden, not tied to the chrome: toggling the status bar
        // re-runs layout and nudged the pager a pixel or two sideways —
        // the wallpaper must be rock still when the chrome fades.
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        // The dismiss zoom targets whatever wallpaper is CURRENT — swiping
        // in the pager retargets it, and the grid scrolls along behind
        // (selectedID sync below) so the tile is on screen to land on.
        // While the editor is up the zoom pair DETACHES — the transition's
        // scroll-edge handoff (a drag starting on a horizontal scroller's
        // boundary hands off to the interactive pop) bypasses both the
        // pinch shield and the disabled edge recognizers, and detaching is
        // the only lever that reaches it. Outside the editor the pair
        // stays attached so flick-dismissals keep flying to their tile.
        .zoomTransition(sourceID: currentID, in: editing ? nil : zoomNamespace)
        .onChange(of: pagerID) { _, id in
            if let id, id != currentID { currentID = id }
        }
        .onChange(of: currentID) { _, id in
            app.selectedID = id
            if pagerID != id { pagerID = id }
        }
        .task {
            // Position the pager on the pushed wallpaper once layout
            // exists (and once more after the zoom transition settles).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pagerID = currentID }
            try? await Task.sleep(for: .milliseconds(250))
            if pagerID != currentID {
                withTransaction(transaction) { pagerID = currentID }
            }
        }
        // The editor is an in-place layer, not a presentation. Its preview
        // area is an EMPTY slot: the single hero layer carries the actual
        // wallpaper, so "another image arriving" is structurally
        // impossible — the one on screen simply shrinks into place while
        // the UI cross-fades (the Photos edit morph). Layer order matters:
        // black backdrop UNDER the hero, editor chrome ABOVE it — that's
        // what lets the fullscreen-fit toggle show the wallpaper edge to
        // edge with the whole editor UI hovering on top.
        .overlay {
            if editing {
                Color.black.ignoresSafeArea()
                    .opacity(editorRevealed ? 1 : 0)
            }
        }
        .overlay {
            if heroActive {
                GeometryReader { proxy in
                    let full = CGRect(origin: .zero, size: proxy.size)
                    let slotState = editorRevealed && editing && !editorZoomed
                        && editSlotAnchor != nil
                    let rect = slotState ? proxy[editSlotAnchor!] : full
                    PreviewMetalView(model: currentModel.preview, mode: .live)
                        .aspectRatio(currentModel.selectedDevice.canonicalAspect,
                                     contentMode: .fit)
                        .editSlotDressing(active: slotState)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }
        }
        .overlay {
            if editing {
                EditView(model: currentModel, heroMode: true,
                         revealed: editorRevealed,
                         zoomedBinding: $editorZoomed,
                         onClose: { closeEditor() })
                .opacity(editorRevealed ? 1 : 0)
            }
        }
        .onPreferenceChange(EditSlotAnchorKey.self) { editSlotAnchor = $0 }
        .onChange(of: editSlotAnchor != nil) { _, hasSlot in
            // Reveal only once the slot is measured: the hero then animates
            // to a known target instead of guessing a frame early.
            guard hasSlot, editing, !editorRevealed else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                editorRevealed = true
            }
        }
        .sheet(isPresented: $showingGuide) { GuideSheet() }
        .sheet(isPresented: $showingSizeSheet) {
            ExportSizeSheet(model: currentModel)
        }
        .alert("Rename Wallpaper", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let previous = currentDocument?.name ?? ""
                library.rename(currentID, to: renameText)
                let id = currentID
                undoManager?.registerUndo(withTarget: library) { lib in
                    lib.rename(id, to: previous)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Save", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .task {
            // Screenshot automation (make screens): jump straight into edit.
            if CommandLine.arguments.contains("--auto-edit") {
                try? await Task.sleep(for: .seconds(1))
                openEditor()
            }
        }
        // Neighbor pages cost a main-thread photo decode when their model
        // first exists — pay that in idle right after arriving on a page,
        // never inside the first swipe gesture (the reported hitch).
        .task(id: currentID) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            prewarmNeighbors()
        }
    }

    /// Instant page jump (strip taps, scrub ticks): both states move in
    /// one animation-free transaction.
    private func jumpPager(to id: UUID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentID = id
            pagerID = id
        }
    }

    private func openEditor() {
        // Hero takes over the wallpaper at its CURRENT frame (identical
        // pixels, no visible handoff), the editor mounts invisibly, and
        // the reveal fires once its slot reports in (onPreferenceChange).
        heroActive = true
        editing = true
    }

    private func closeEditor() {
        closingEditor = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86),
                      completionCriteria: .logicallyComplete) {
            editorRevealed = false
        } completion: {
            editing = false
            heroActive = false
            editSlotAnchor = nil
            closingEditor = false
            editorZoomed = false
        }
    }

    private func prewarmNeighbors() {
        let docs = pagedDocuments
        guard let index = docs.firstIndex(where: { $0.id == currentID }) else { return }
        for offset in [-1, 1] {
            let j = index + offset
            guard docs.indices.contains(j) else { continue }
            _ = model(for: docs[j].id)
        }
    }

    private func isNeighbor(_ id: UUID) -> Bool {
        let docs = pagedDocuments
        guard let current = docs.firstIndex(where: { $0.id == currentID }),
              let index = docs.firstIndex(where: { $0.id == id }) else { return false }
        return abs(current - index) <= 1
    }

    @ViewBuilder
    private func pagePreview(_ doc: WallpaperDocument) -> some View {
        let model = model(for: doc.id)
        if doc.kind == nil {
            TypeChoiceView(model: model)
        } else if doc.needsSourceImage && doc.sourceImage == nil {
            PhotoDropZoneView(model: model)
        } else {
            if heroActive && doc.id == currentID {
                Color.black
            } else {
                PreviewMetalView(model: model.preview, mode: pageMode(doc))
                    .aspectRatio(model.selectedDevice.canonicalAspect, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
    }

    /// Only the current page animates; neighbors render a still on demand
    /// (Photos-style). While the editor covers this screen — or the scene
    /// goes inactive — pages render nothing and keep their last frame.
    private func pageMode(_ doc: WallpaperDocument) -> PreviewMetalView.Mode {
        if editing || app.previewsPaused { return .frozen }
        return doc.id == currentID ? .live : .still
    }

    // MARK: - Floating chrome (Photos-style pills)

    private var chrome: some View {
        VStack(spacing: 0) {
            // Directional exit under the edit morph: top chrome slides up
            // and away, bottom chrome slides down — the editor's pieces
            // arrive along the same axes.
            topBar
                // The status bar is hidden, so the landscape iPad's top
                // inset is zero and the bar glued to the edge — seat it.
                .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 20 : 0)
                .offset(y: editorRevealed ? -56 : 0)
                .opacity(editorRevealed || closingEditor ? 0 : 1)
            Spacer()
            Group {
                filmstrip
                    .padding(.bottom, 10)
                bottomBar
                    .padding(.bottom, 4)
            }
            .offset(y: editorRevealed ? 56 : 0)
            .opacity(editorRevealed || closingEditor ? 0 : 1)
        }
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            pillButton(systemImage: "chevron.left", label: "Back") { dismiss() }

            Spacer()

            VStack(spacing: 1) {
                // One line, always: the pill grows to fit and then the
                // name truncates — it never wraps under itself.
                Text(currentDocument?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .chromeGlass(in: Capsule())

            Spacer()

            Menu {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                        library.setFavorite(!(currentDocument?.favorite == true),
                                            id: currentID)
                    }
                } label: {
                    currentDocument?.favorite == true
                        ? Label("Remove from Favorites", systemImage: "heart.slash")
                        : Label("Add to Favorites", systemImage: "heart")
                }
                Button {
                    renameText = currentDocument?.name ?? ""
                    renaming = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button {
                    duplicateCurrent()
                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Divider()
                Button {
                    showingSizeSheet = true
                } label: {
                    Label("Export at a Different Size", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    exportWallshader()
                } label: {
                    Label("Export as", systemImage: "doc.badge.arrow.up")
                    Text("Wallshader")
                }
                Divider()
                Button(role: .destructive) {
                    deleteCurrent()
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .chromeGlass(in: Circle())
            }
            .accessibilityLabel("More")
            .sharePopover(item: $exportItem)
        }
    }

    /// The wallpaper's shader, human-named — device/customization state
    /// stopped meaning anything once mobile lost variant switching.
    private var subtitle: String {
        guard let shaderId = currentDocument?.shaderId else { return "" }
        return StripTileStore.displayName(shaderId)
    }

    // MARK: - Filmstrip (Photos-style neighbor strip)

    /// Thumb geometry: constant width so the scrubber math is exact.
    private static let stripThumbWidth: CGFloat =
        UIDevice.current.userInterfaceIdiom == .pad ? 58 : 28
    private static let stripSpacing: CGFloat = 3
    private static var stripStride: CGFloat { stripThumbWidth + stripSpacing }
    private static let stripHaptic = UISelectionFeedbackGenerator()

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.stripSpacing) {
                    ForEach(pagedDocuments) { doc in
                        filmstripThumb(doc)
                            .id(doc.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            // Photos keeps the ACTIVE thumb dead center: half-screen side
            // margins let even the first/last item reach the middle.
            .contentMargins(.horizontal,
                            UIScreen.main.bounds.width / 2 - Self.stripThumbWidth / 2,
                            for: .scrollContent)
            .frame(height: 44)
            // ...and the strip melts away at both ends.
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .stripScrubber(midX: { handleStripGeometry($0) },
                           phase: { interacting in
                               stripScrubbing = interacting
                           })
            .onChange(of: currentID) { _, id in
                guard !stripScrubbing else { return }
                if stripTapJump {
                    stripTapJump = false
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .task {
                // Arrival centering: an immediate onAppear scroll fired
                // before margins/zoom-transition settled and missed —
                // re-center after layout, twice, unanimated.
                for delay in [80, 350] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, !stripScrubbing else { return }
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
    }

    /// Scrub tick: the thumb under the fixed center becomes current — the
    /// page jumps with no slide, Photos-style. The first idle callback
    /// calibrates the geometry baseline (inset conventions differ), then
    /// center-x maps to an index by constant stride.
    private func handleStripGeometry(_ midX: CGFloat) {
        let docs = pagedDocuments
        guard !docs.isEmpty else { return }
        if !stripScrubbing {
            if let index = docs.firstIndex(where: { $0.id == currentID }) {
                stripBaseline = midX - CGFloat(index) * Self.stripStride
            }
            return
        }
        guard let baseline = stripBaseline else { return }
        let raw = Int(((midX - baseline) / Self.stripStride).rounded())
        let index = min(max(raw, 0), docs.count - 1)
        let id = docs[index].id
        guard id != currentID else { return }
        jumpPager(to: id)
        Self.stripHaptic.selectionChanged()
    }

    @ViewBuilder
    private func filmstripThumb(_ doc: WallpaperDocument) -> some View {
        let selected = doc.id == currentID
        Button {
            // Photos: a tap lands DIRECTLY on that wallpaper — no sliding
            // through everything in between.
            stripTapJump = true
            jumpPager(to: doc.id)
        } label: {
            Group {
                if let cg = DeviceThumbnailStore.shared.thumbnail(for: doc, app: app) {
                    Image(uiImage: UIImage(cgImage: cg))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.1))
                }
            }
            .frame(width: Self.stripThumbWidth, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(doc.name))
    }

    // MARK: - Bottom action bar (Share · Animated/Save/Edit · Delete)

    private var bottomBar: some View {
        HStack {
            pillButton(systemImage: "square.and.arrow.up", label: "Share") { share() }
                .sharePopover(item: $shareItem)

            Spacer()

            // 44pt hit targets inside the capsule; the tighter paddings
            // keep its visual size where it was.
            HStack(spacing: 8) {
                SaveWallpaperButton(model: currentModel, showingGuide: $showingGuide,
                                    saveError: $saveError)

                Button {
                    currentModel.undoManager = undoManager
                    openEditor()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!(currentDocument?.isAppliable ?? false)
                          && currentDocument?.kind == nil)
                .accessibilityLabel("Edit")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .chromeGlass(in: Capsule())

            Spacer()

            // The delete button MORPHS into its confirmation, exactly like
            // the More button morphs into its menu (Photos' delete panel).
            Menu {
                Section {
                    Button(role: .destructive) {
                        deleteCurrent()
                    } label: { Label("Delete Wallpaper", systemImage: "trash") }
                } header: {
                    Text("This wallpaper will be deleted from your library.")
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .chromeGlass(in: Circle())
            }
            .accessibilityLabel("Delete")
        }
    }

    private func pillButton(systemImage: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .chromeGlass(in: Circle())
        }
        .accessibilityLabel(Text(label))
    }

    // MARK: - Actions

    private func share() {
        guard let url = SaveWallpaperButton.renderTemporaryPNG(model: currentModel) else { return }
        shareItem = url
    }

    /// The portable .wallshader file (recipe + embedded photo) through
    /// the system share sheet — same format the Mac exports and imports.
    private func exportWallshader() {
        guard let doc = currentDocument else { return }
        currentModel.flushPendingWriteback()
        guard let fresh = library.document(id: currentID),
              let data = try? library.exportWallshaderData(for: fresh) else {
            saveError = "This wallpaper isn't finished yet, so it can't be exported."
            return
        }
        let name = fresh.name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallshader-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name).appendingPathExtension("wallshader")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            saveError = error.localizedDescription
            return
        }
        exportItem = url
        _ = doc
    }

    private func duplicateCurrent() {
        guard app.gateAddingDocument() else { return }
        if let copy = library.duplicate(currentID) {
            let id = copy.id
            undoManager?.registerUndo(withTarget: library) { lib in lib.delete(id) }
            currentID = copy.id
        }
    }

    private func deleteCurrent() {
        guard let doc = currentDocument else { return }
        let imageData = library.sourceImageData(for: doc)
        let neighbors = pagedDocuments
        let index = neighbors.firstIndex { $0.id == doc.id } ?? 0
        library.delete(doc.id)
        app.detailScopeIDs?.removeAll { $0 == doc.id }
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.restore(doc, imagePNG: imageData)
        }
        models.remove(doc.id)
        let remaining = pagedDocuments
        if remaining.isEmpty {
            dismiss()
        } else {
            currentID = remaining[min(index, remaining.count - 1)].id
        }
    }
}


/// "Export at a Different Size": the Mac size catalog, used on mobile
/// purely as EXPORT targets — the preview never changes size here. Each
/// row renders that category's variant (auto-derived when untouched) at
/// the preset's resolution and hands the PNG to the share sheet.
struct ExportSizeSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            List {
                ForEach(DeviceClass.allCases) { device in
                    Section(device.categoryName) {
                        ForEach(DeviceSizeCatalog.presets(for: device)) { preset in
                            row(preset, device: device)
                        }
                    }
                }
            }
            .navigationTitle("Export Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(exporting != nil)
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
    }

    private func row(_ preset: DeviceSizePreset, device: DeviceClass) -> some View {
        Button {
            export(preset, device: device)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name)
                            .foregroundStyle(.white)
                        Text(preset.sizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: device.categorySymbol)
                }
                Spacer()
                if exporting == preset.id {
                    ProgressView()
                }
            }
        }
        .disabled(exporting != nil)
    }

    private func export(_ preset: DeviceSizePreset, device: DeviceClass) {
        guard exporting == nil, let renderer = model.app.renderer,
              let doc = model.document, doc.shaderId != nil else { return }
        model.flushPendingWriteback()
        let library = model.library
        let sourceURL = doc.needsSourceImage ? library.sourceImageURL(for: doc) : nil
        let ambient = library.ambientSpec(
            for: doc, settings: doc.resolvedVariant(for: device, imageAspect: nil).ambient)
        exporting = preset.id
        let box = ExportRendererBox(renderer: renderer)
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
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
                guard let shaderId = doc.shaderId,
                      let params = doc.shaderParams(for: device, imageAspect: aspect),
                      let image = try? box.offscreen.renderImage(
                          shaderId: shaderId, params: params,
                          pixelWidth: preset.pixelWidth, pixelHeight: preset.pixelHeight,
                          pixelRatio: preset.pixelRatio,
                          timeSeconds: Float(params.frame * 0.001),
                          texture: texture, ambient: ambient) else { return nil }
                let name = doc.name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
                    .joined(separator: "-")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
                    .appendingPathComponent("\(name) \(preset.sizeLabel)")
                    .appendingPathExtension("png")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                guard (try? box.offscreen.writePNG(image, to: url)) != nil else { return nil }
                return url
            }.value
            await MainActor.run {
                exporting = nil
                if let url { shareURL = url }
            }
        }
    }
}

private struct ExportRendererBox: @unchecked Sendable {
    let renderer: ShaderRenderer
    let offscreen: OffscreenRenderer
    init(renderer: ShaderRenderer) {
        self.renderer = renderer
        offscreen = OffscreenRenderer(renderer: renderer)
    }
}

/// One EditorModel per visited document, created exactly once — creating
/// models during view-body evaluation (and stashing them via async state
/// writes) duplicated Combine subscriptions per render pass.
@MainActor
final class ModelCache: ObservableObject {
    private var cache: [UUID: EditorModel] = [:]

    func remove(_ id: UUID) {
        cache[id] = nil
    }

    func model(for id: UUID, undoManager: UndoManager?) -> EditorModel {
        if let existing = cache[id] {
            existing.undoManager = undoManager
            return existing
        }
        let fresh = EditorModel(app: AppModel.shared, documentID: id)
        fresh.undoManager = undoManager
        cache[id] = fresh
        return fresh
    }
}
