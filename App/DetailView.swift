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
    @StateObject private var models = ModelCache()
    @State private var editing = false
    @State private var chromeHidden = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
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

    init(documentID: UUID, zoomNamespace: Namespace.ID? = nil) {
        _currentID = State(initialValue: documentID)
        self.zoomNamespace = zoomNamespace
    }

    private func model(for id: UUID) -> EditorModel {
        models.model(for: id, undoManager: undoManager)
    }

    private var currentModel: EditorModel { model(for: currentID) }
    private var currentDocument: WallpaperDocument? { library.document(id: currentID) }

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
                LazyHStack(spacing: 0) {
                    ForEach(library.documents) { doc in
                        Group {
                            if isNeighbor(doc.id) {
                                pagePreview(doc)
                            } else {
                                Color.black
                            }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(doc.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $pagerID)
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
            }

            if !chromeHidden {
                chrome
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(chromeHidden)
        .preferredColorScheme(.dark)
        // The dismiss zoom targets whatever wallpaper is CURRENT — swiping
        // in the pager retargets it, and the grid scrolls along behind
        // (selectedID sync below) so the tile is on screen to land on.
        .zoomTransition(sourceID: currentID, in: zoomNamespace)
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
        .fullScreenCover(isPresented: $editing) {
            EditView(model: currentModel)
        }
        .sheet(isPresented: $showingGuide) { GuideSheet() }
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
        .confirmationDialog("Delete this wallpaper?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Wallpaper", role: .destructive) { deleteCurrent() }
        }
        .task {
            // Screenshot automation (make screens): jump straight into edit.
            if CommandLine.arguments.contains("--auto-edit") {
                try? await Task.sleep(for: .seconds(1))
                editing = true
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

    private func prewarmNeighbors() {
        let docs = library.documents
        guard let index = docs.firstIndex(where: { $0.id == currentID }) else { return }
        for offset in [-1, 1] {
            let j = index + offset
            guard docs.indices.contains(j) else { continue }
            _ = model(for: docs[j].id)
        }
    }

    private func isNeighbor(_ id: UUID) -> Bool {
        let docs = library.documents
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
            PreviewMetalView(model: model.preview, mode: pageMode(doc))
                .aspectRatio(model.selectedDevice.canonicalAspect, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
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
            topBar
            variantPill
                .padding(.top, 6)
            Spacer()
            filmstrip
                .padding(.bottom, 10)
            bottomBar
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            if UIDevice.current.userInterfaceIdiom != .pad {
                pillButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            }

            Spacer()

            VStack(spacing: 1) {
                Text(currentDocument?.name ?? "")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .chromeGlass(in: Capsule())

            Spacer()

            Menu {
                Button {
                    renameText = currentDocument?.name ?? ""
                    renaming = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button {
                    duplicateCurrent()
                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                if currentModel.selectedVariantIsCustomized,
                   currentModel.selectedDevice != .desktop {
                    Button {
                        currentModel.revertVariantToAutomatic()
                    } label: { Label("Revert to Automatic", systemImage: "wand.and.sparkles") }
                }
                Divider()
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .chromeGlass(in: Circle())
            }
            .accessibilityLabel("More")
        }
    }

    private var subtitle: String {
        guard let doc = currentDocument else { return "" }
        let device = currentModel.selectedDevice.displayName
        let state = currentModel.selectedDevice == .desktop
            ? "" : (doc.isCustomized(currentModel.selectedDevice) ? " · Customized" : " · Auto")
        return device + state
    }

    private var variantPill: some View {
        Picker("Device", selection: Binding(
            get: { currentModel.selectedDevice },
            set: { currentModel.selectDevice($0) }
        )) {
            ForEach(DeviceClass.allCases) { device in
                Text(device.displayName).tag(device)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
        // Segmented alone disappears over bright wallpapers — back it with
        // the same glass as every other chrome pill.
        .padding(4)
        .chromeGlass(in: Capsule())
    }

    // MARK: - Filmstrip (Photos-style neighbor strip)

    /// Thumb geometry: constant width so the scrubber math is exact.
    private static let stripThumbWidth: CGFloat = 28
    private static let stripSpacing: CGFloat = 3
    private static var stripStride: CGFloat { stripThumbWidth + stripSpacing }
    private static let stripHaptic = UISelectionFeedbackGenerator()

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.stripSpacing) {
                    ForEach(library.documents) { doc in
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
        let docs = library.documents
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

            Spacer()

            HStack(spacing: 26) {
                if currentDocument?.shaderIsAnimatable == true {
                    Button {
                        currentModel.setAnimated(!(currentModel.editingVariant?.animated ?? false))
                    } label: {
                        Image(systemName: (currentModel.editingVariant?.animated ?? false)
                              ? "pause.circle" : "play.circle")
                            .font(.system(size: 21))
                    }
                    .accessibilityLabel("Animated")
                }

                SaveWallpaperButton(model: currentModel, showingGuide: $showingGuide,
                                    saveError: $saveError)

                Button {
                    currentModel.undoManager = undoManager
                    editing = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20))
                }
                .disabled(!(currentDocument?.isAppliable ?? false)
                          && currentDocument?.kind == nil)
                .accessibilityLabel("Edit")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .chromeGlass(in: Capsule())

            Spacer()

            pillButton(systemImage: "trash", label: "Delete") { confirmingDelete = true }
        }
    }

    private func pillButton(systemImage: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .chromeGlass(in: Circle())
        }
        .accessibilityLabel(Text(label))
    }

    // MARK: - Actions

    private func share() {
        guard let url = SaveWallpaperButton.renderTemporaryPNG(model: currentModel) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?
            .presentedOrSelf
            .present(controller, animated: true)
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
        let neighbors = library.documents
        let index = neighbors.firstIndex { $0.id == doc.id } ?? 0
        library.delete(doc.id)
        undoManager?.registerUndo(withTarget: library) { lib in
            lib.restore(doc, imagePNG: imageData)
        }
        models.remove(doc.id)
        let remaining = library.documents
        if remaining.isEmpty {
            dismiss()
        } else {
            currentID = remaining[min(index, remaining.count - 1)].id
        }
    }
}

private extension UIViewController {
    var presentedOrSelf: UIViewController {
        presentedViewController?.presentedOrSelf ?? self
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
