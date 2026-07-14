import SwiftUI
import WallshaderModel

/// The type-choice creation flow (C2): a new wallpaper starts from a
/// Shader or a Photo — the same two cards as the Mac Studio's empty state.
struct TypeChoiceView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 20) {
            Text("What kind of wallpaper?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            HStack(spacing: 16) {
                card(title: "Shader",
                     subtitle: "A generated look — gradients, noise, metaballs…",
                     systemImage: "circle.bottomrighthalf.pattern.checkered") {
                    choose(.procedural)
                }
                card(title: "Photo",
                     subtitle: "Your own photo, styled by an effect.",
                     systemImage: "photo") {
                    choose(.imageBased)
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose(_ kind: WallpaperDocument.Kind) {
        _ = model.library.assignKind(kind, to: model.documentID)
        model.reloadEditor()
    }

    private func card(title: String, subtitle: String, systemImage: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Photo documents with no photo yet: the editor area IS the picker.
struct PhotoDropZoneView: View {
    @ObservedObject var model: EditorModel
    @State private var showingSources = true

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.55))
            Text("Add a photo to get started")
                .font(.headline)
                .foregroundStyle(.white)
            Button("Choose Photo…") { showingSources = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingSources) {
            PhotoSourcesSheet(model: model)
        }
    }
}
