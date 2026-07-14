import ShaderCore
import SwiftUI
import WallshaderModel

/// The cinematic first-run (C8): the app icon's dithering shader animates
/// full-bleed, then collapses into a glass icon tile — the Mac welcome,
/// adapted to iPhone/iPad geometry. Re-openable from About.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview: PreviewModel
    @State private var collapsed = false

    init() {
        let schema = ShaderRegistry.shared.schema(for: "dithering")
            ?? ShaderRegistry.shared.schema(for: ShaderRegistry.shared.orderedIds[0])!
        let model = PreviewModel(renderer: AppModel.shared.renderer,
                                 shaderId: schema.id,
                                 params: ShaderParams(schema: schema),
                                 device: AppModel.currentDevice)
        model.isPlaying = true
        _preview = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewMetalView(model: preview)
                .ignoresSafeArea()
                .opacity(collapsed ? 0 : 1)

            VStack(spacing: 18) {
                if collapsed {
                    PreviewMetalView(model: preview)
                        .frame(width: 132, height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .overlay(RoundedRectangle(cornerRadius: 30)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                        .transition(.scale(scale: 3).combined(with: .opacity))
                }
                if collapsed {
                    VStack(spacing: 8) {
                        Text("Welcome to Wallshader")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.white)
                        Text("GPU shader wallpapers — make one, save it to Photos, set it from Settings. Everything you create syncs across your devices.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .frame(maxWidth: 520)
                    }
                    .transition(.opacity)

                    Button {
                        dismiss()
                    } label: {
                        Text("Start Creating")
                            .font(.headline)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .transition(.opacity)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.spring(duration: 0.9)) { collapsed = true }
        }
        .onTapGesture {
            if !collapsed {
                withAnimation(.spring(duration: 0.6)) { collapsed = true }
            }
        }
    }
}
