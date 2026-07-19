import SwiftUI

/// The Library toolbar's SYSTEM button look, for hand-built chrome: real
/// Liquid Glass on OS 26, the material approximation before that. Every
/// floating pill/circle in Detail and Edit funnels through this so the
/// whole app reads as one family (UX feedback: the toolbar buttons "come
/// from a default place" — the custom chrome didn't).
extension View {
    /// The system's progressive-blur scroll edge (what Photos runs under
    /// its pinned Library header) — no-op before OS 26, where the header
    /// keeps a gradient scrim instead.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func chromeGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            // .regular for now. .clear was tried for the Photos-like
            // transparency and felt WORSE on hardware (2026-07-18) — the
            // regular scrim question stays open for a later pass.
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(shape.fill(.ultraThinMaterial))
        }
    }
}
