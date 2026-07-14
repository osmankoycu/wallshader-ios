import SwiftUI
import WallshaderModel

/// The editor: preview letterboxed to the selected variant's aspect,
/// variant selector (current device preselected — C2), motion toggle,
/// shader strip, inspector in a bottom sheet with medium/large detents.
struct EditorView: View {
    let documentID: UUID

    @EnvironmentObject private var app: AppModel
    @StateObject private var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @State private var showingInspector = false
    @State private var showingTypeChoice = false
    @State private var showingSources = false
    @State private var showingGuide = false
    @State private var saveError: String?

    init(documentID: UUID) {
        self.documentID = documentID
        _model = StateObject(wrappedValue: EditorModel(app: AppModel.shared,
                                                       documentID: documentID))
    }

    var body: some View {
        Group {
            if let doc = model.document {
                if doc.kind == nil {
                    TypeChoiceView(model: model)
                } else if doc.needsSourceImage && doc.sourceImage == nil {
                    PhotoDropZoneView(model: model)
                } else {
                    editor(doc)
                }
            } else {
                ContentUnavailableView("Wallpaper Deleted", systemImage: "trash")
            }
        }
        .navigationTitle(model.document?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.undoManager = undoManager
            model.preview.paused = app.previewsPaused
        }
        .onChange(of: app.previewsPaused) { _, paused in
            model.preview.paused = paused
        }
        .onDisappear { model.flushPendingWriteback() }
    }

    private func editor(_ doc: WallpaperDocument) -> some View {
        VStack(spacing: 0) {
            variantBar

            GeometryReader { geo in
                ZStack {
                    Color(white: 0.08).ignoresSafeArea(edges: [])
                    PreviewMetalView(model: model.preview)
                        .aspectRatio(model.selectedDevice.canonicalAspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .shadow(radius: 10)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            controlBar(doc)
            Divider()
            ShaderStripView(model: model)
                .frame(height: 108)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SaveWallpaperMenu(model: model, showingGuide: $showingGuide,
                                  saveError: $saveError)
                Button {
                    showingInspector = true
                } label: {
                    Label("Adjust", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("Adjust parameters")
            }
        }
        .sheet(isPresented: $showingInspector) {
            InspectorSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $showingGuide) { GuideSheet() }
        .alert("Couldn't Save", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Desktop | iPad | iPhone with Auto/Customized badge (A4 on iOS).
    private var variantBar: some View {
        HStack(spacing: 10) {
            Picker("Device", selection: Binding(
                get: { model.selectedDevice },
                set: { model.selectDevice($0) }
            )) {
                ForEach(DeviceClass.allCases) { device in
                    Text(device.displayName).tag(device)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            if model.selectedDevice != .desktop {
                Text(model.selectedVariantIsCustomized ? "Customized" : "Auto")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    .foregroundStyle(.secondary)
                if model.selectedVariantIsCustomized {
                    Button("Revert") { model.revertVariantToAutomatic() }
                        .font(.caption)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func controlBar(_ doc: WallpaperDocument) -> some View {
        HStack {
            if doc.shaderIsAnimatable {
                Toggle(isOn: Binding(
                    get: { model.editingVariant?.animated ?? false },
                    set: { model.setAnimated($0) }
                )) {
                    Text("Animated")
                }
                .toggleStyle(.switch)
                .fixedSize()
            }
            Spacer()
            if doc.needsSourceImage {
                Button {
                    showingSources = true
                } label: {
                    Label("Replace Photo", systemImage: "photo")
                }
                .sheet(isPresented: $showingSources) {
                    PhotoSourcesSheet(model: model)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The shader strip (C2): only shaders matching the wallpaper's kind;
/// image-shader tiles render from the USER'S OWN photo.
struct ShaderStripView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var tiles = StripTileStore.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(matchingShaderIds(), id: \.self) { id in
                    tile(id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func matchingShaderIds() -> [String] {
        let kind = model.document?.kind ?? .procedural
        return StripTileStore.orderedIds(for: kind)
    }

    private func tile(_ id: String) -> some View {
        let selected = model.document?.shaderId == id
        return Button {
            model.switchShader(to: id)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let cg = tiles.tile(for: id, model: model) {
                        Image(uiImage: UIImage(cgImage: cg))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary.opacity(0.5))
                    }
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))

                Text(StripTileStore.displayName(id))
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 100)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(StripTileStore.displayName(id)))
    }
}
