import ShaderCore
import SwiftUI
import WallshaderModel

/// The cinematic first-run (C8), a true port of the Mac welcome: ONE hero
/// view runs the app icon's dithering sphere full-bleed (icon gray on
/// black, the Mac's exact params), then shrinks into the glass icon tile
/// while the dither cells coarsen mid-flight; the title, pitch and CTA
/// stagger in below. Re-openable from About.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview: PreviewModel
    @State private var collapsed = false
    @State private var shrink: Double = OnboardingView.shrinkDuration

    private static let tileSize: CGFloat = 132
    private static let shrinkDuration: Double = 1.25
    /// Full-bleed look → icon look (the Mac HeroModel's numbers): the
    /// cells coarsen and the sphere fills out in lockstep with the shrink
    /// so the tile lands reading as the actual app icon.
    private static let introSize = 2.0, iconSize = 4.5
    private static let introScale = 0.6, iconScale = 0.75

    init() {
        let schema = ShaderRegistry.shared.schema(for: "dithering")
            ?? ShaderRegistry.shared.schema(for: ShaderRegistry.shared.orderedIds[0])!
        let model = PreviewModel(renderer: AppModel.shared.renderer,
                                 shaderId: schema.id,
                                 params: ShaderParams(schema: schema),
                                 device: AppModel.currentDevice)
        // The Mac hero's look, verbatim: detailed dithering sphere,
        // icon gray (#b2b2b2, sampled from the app icon) on black.
        model.params["shape"] = .choice("sphere")
        model.params["type"] = .choice("4x4")
        model.params["size"] = .number(Self.introSize)
        model.params["scale"] = .number(Self.introScale)
        model.params["colorBack"] = .color("#000000")
        model.params["colorFront"] = .color("#b2b2b2")
        model.rendersAtViewPixels = true
        model.isPlaying = true
        _preview = StateObject(wrappedValue: model)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The Mac stage backdrop: tile-contrast gray up top,
                // falling to black under the CTAs.
                LinearGradient(colors: [Color(white: 0.11), .black],
                               startPoint: .top, endPoint: .bottom)

                content
            }
            // ONE hero, Mac-style, flying onto the ensemble's tile slot:
            // no cross-fade between two copies, and the slot anchor keeps
            // the assembled composition dead-center on any screen.
            .overlayPreferenceValue(HeroSlotKey.self) { anchor in
                if let anchor {
                    hero(in: geo, slot: geo[anchor])
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: .seconds(2.7))
            guard !Task.isCancelled else { return }
            collapse(over: Self.shrinkDuration)
        }
        .onTapGesture { collapse(over: 0.6) }
    }

    /// Liquid-glass sheen over the landed tile, exactly as macOS renders
    /// app icons: an angled specular wash plus a hairline rim. Its opacity
    /// rides the same transaction as the shrink.
    private var glassSheen: some View {
        RoundedRectangle(cornerRadius: 30)
            .fill(LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0.05), .clear],
                startPoint: .topLeading, endPoint: .center))
            .overlay {
                RoundedRectangle(cornerRadius: 30)
                    .strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.12), .white.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
    }

    /// The hero itself: the container frame animates rect→square, but the
    /// shader inside KEEPS the screen's aspect and fills (cropping the
    /// sides) — a proportional shrink, never a squeeze.
    private func hero(in geo: GeometryProxy, slot: CGRect) -> some View {
        let portrait = geo.size.height >= geo.size.width
        let fast = Animation.timingCurve(0.16, 1, 0.3, 1, duration: shrink * 0.55)
        let full = Animation.timingCurve(0.16, 1, 0.3, 1, duration: shrink)
        return Color.clear
            // The LONG axis lands early: the frame passes through square
            // almost immediately instead of shrinking as a tall (or
            // wide) card the whole flight.
            .frame(height: collapsed ? slot.height : geo.size.height)
            .animation(portrait ? fast : full, value: collapsed)
            .frame(width: collapsed ? slot.width : geo.size.width)
            .animation(portrait ? full : fast, value: collapsed)
            .overlay {
                PreviewMetalView(model: preview)
                    .aspectRatio(max(geo.size.width, 1) / max(geo.size.height, 1),
                                 contentMode: .fill)
            }
            .clipShape(RoundedRectangle(cornerRadius: collapsed ? 30 : 0))
            .overlay {
                glassSheen.opacity(collapsed ? 1 : 0)
            }
            .shadow(color: .black.opacity(collapsed ? 0.55 : 0),
                    radius: 22, y: 12)
            .position(x: collapsed ? slot.midX : geo.size.width / 2,
                      y: collapsed ? slot.midY : geo.size.height / 2)
            .allowsHitTesting(false) // purely visual — taps go below
    }

    private var content: some View {
        VStack(spacing: 18) {
            // Twin spacers center the WHOLE ensemble; the hero lands on
            // this clear slot.
            Spacer()

            Color.clear
                .frame(width: Self.tileSize, height: Self.tileSize)
                .anchorPreference(key: HeroSlotKey.self, value: .bounds) { $0 }
                .padding(.bottom, 12)

            Text("Welcome to Wallshader")
                // .title on the phone: .largeTitle ran edge-to-edge there.
                .font(UIDevice.current.userInterfaceIdiom == .phone
                      ? .title.weight(.bold) : .largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .staggeredIn(shown: collapsed, delay: shrink)

            // The Mac welcome's pitch, inline SF Symbols and all; only
            // the tail adapts (no Studio window or one-click set here).
            (
                Text("Wallshader makes wallpapers out of pure GPU shaders: flowing gradients, liquid patterns and dithered light, in motion ")
                + Text(Image(systemName: "play.circle"))
                + Text(" or perfectly still. Or take your own photo ")
                + Text(Image(systemName: "photo"))
                + Text(" and pour it through the same effects. Shape it in the editor ")
                + Text(Image(systemName: "slider.horizontal.3"))
                + Text(", save it and set it as your wallpaper.")
            )
            .font(.callout)
            .lineSpacing(5)
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .frame(maxWidth: 520)
            .staggeredIn(shown: collapsed, delay: shrink + 0.35)

            Button {
                dismiss()
            } label: {
                Text("Start Creating")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .padding(.top, 6)
            .staggeredIn(shown: collapsed, delay: shrink + 0.7)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private struct HeroSlotKey: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil
        static func reduce(value: inout Anchor<CGRect>?,
                           nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }

    /// The Mac's easeOutExpo shrink + the dither-cell coarsen, driven
    /// together; a tap skips ahead with the same gesture, just quicker.
    private func collapse(over duration: Double) {
        guard !collapsed else { return }
        shrink = duration
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: duration)) {
            collapsed = true
        }
        Task { await coarsen(over: duration) }
    }

    private func coarsen(over duration: Double) async {
        let steps = 22
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(duration / Double(steps)))
            guard !Task.isCancelled else { return }
            let t = Double(step) / Double(steps)
            // Ease-out, matching the shrink: cells coarsen early so the
            // whole flight reads as one gesture.
            let eased = 1 - pow(1 - t, 3)
            preview.params["size"] = .number(
                Self.introSize + (Self.iconSize - Self.introSize) * eased)
            preview.params["scale"] = .number(
                Self.introScale + (Self.iconScale - Self.introScale) * eased)
        }
    }
}

private extension View {
    /// Staggered entrance (the Mac welcome's): fades in with a slight
    /// upward drift, `delay` seconds after `shown` flips.
    func staggeredIn(shown: Bool, delay: Double) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(.easeOut(duration: 0.55).delay(delay), value: shown)
    }
}
