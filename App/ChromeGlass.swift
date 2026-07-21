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
    func softBottomEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }

    /// Photos' tile→detail zoom pair (iOS 18+; a plain push before that).
    @ViewBuilder
    func zoomTransitionSource(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }

    /// Filmstrip scrubber senses (iOS 18 scroll geometry/phase; inert
    /// before that — the strip then behaves like a plain scroller).
    @ViewBuilder
    func stripScrubber(midX: @escaping (CGFloat) -> Void,
                       phase: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.visibleRect.midX
                } action: { _, new in
                    midX(new)
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        phase(true)
                    default:
                        phase(false)
                    }
                }
        } else {
            self
        }
    }

    /// `interactive: false` for containers SHARED by several buttons —
    /// the liquid touch-bounce animates the whole capsule there, which
    /// reads as every button flickering.
    @ViewBuilder
    func chromeGlass(in shape: some Shape, tint: Color? = nil,
                     interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            // .regular for now. .clear was tried for the Photos-like
            // transparency and felt WORSE on hardware (2026-07-18) — the
            // regular scrim question stays open for a later pass.
            if let tint {
                glassEffect(interactive ? .regular.tint(tint).interactive()
                                        : .regular.tint(tint), in: shape)
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular,
                            in: shape)
            }
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
            }
        }
    }
}
