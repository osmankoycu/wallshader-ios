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
    @StateObject private var models = ModelCache()
    @State private var editing = false
    @State private var chromeHidden = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var showingGuide = false
    @State private var saveError: String?

    init(documentID: UUID) {
        _currentID = State(initialValue: documentID)
    }

    private func model(for id: UUID) -> EditorModel {
        models.model(for: id, undoManager: undoManager)
    }

    private var currentModel: EditorModel { model(for: currentID) }
    private var currentDocument: WallpaperDocument? { library.document(id: currentID) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Full-bleed pager over the library (Photos-style swiping).
            // TabView(.page) is EAGER: only the current page and its
            // neighbors get a live Metal view — the rest stay black, or a
            // detail view over a big library would spin up every photo
            // texture at once.
            TabView(selection: $currentID) {
                ForEach(library.documents) { doc in
                    Group {
                        if isNeighbor(doc.id) {
                            pagePreview(doc)
                        } else {
                            Color.black
                        }
                    }
                    .tag(doc.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
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
        .onChange(of: currentID) { _, _ in
            currentModel.preview.paused = app.previewsPaused
        }
        .task {
            // Screenshot automation (make screens): jump straight into edit.
            if CommandLine.arguments.contains("--auto-edit") {
                try? await Task.sleep(for: .seconds(1))
                editing = true
            }
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
            PreviewMetalView(model: model.preview)
                .aspectRatio(model.selectedDevice.canonicalAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            .background(Capsule().fill(.ultraThinMaterial))

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
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.ultraThinMaterial))
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
        // the same material as every other chrome pill.
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    // MARK: - Filmstrip (Photos-style neighbor strip)

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(library.documents) { doc in
                        filmstripThumb(doc)
                            .id(doc.id)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: UIScreen.main.bounds.width - 32) // centers short strips
            }
            .frame(height: 44)
            .onChange(of: currentID) { _, id in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
        }
    }

    @ViewBuilder
    private func filmstripThumb(_ doc: WallpaperDocument) -> some View {
        let selected = doc.id == currentID
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { currentID = doc.id }
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
            .frame(width: selected ? 34 : 26, height: 44)
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
            .background(Capsule().fill(.ultraThinMaterial))

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
                .background(Circle().fill(.ultraThinMaterial))
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
