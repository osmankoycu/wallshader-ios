import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// Direct-manipulation framing on the edit canvas (Frame tab only, like
/// Photos' Crop): drag pans, pinch zooms, two-finger twist rotates,
/// double-tap recenters. The math REPLICATES the Mac composition pad —
/// one offset unit pans exactly one fitted box — so touch, Mac pad, and
/// shaders stay pixel-consistent. A rule-of-thirds grid shows while a
/// gesture is live (Photos-crop feel), and rotation snaps to 0° with a
/// haptic tick.
///
/// The gestures are UIKit recognizers, not SwiftUI gestures, for one
/// hard reason: the detail screen's zoom transition installs an
/// interactive pinch-to-grid on an ANCESTOR view, and on hardware it kept
/// stealing Frame's two-finger touches (closing the editor mid-framing).
/// Our recognizers' delegate makes every recognizer outside this layer
/// wait for ours to fail — a touch that starts on the canvas can only
/// ever mean framing.
struct CompositionGestureLayer: View {
    @ObservedObject var model: EditorModel

    @State private var gestureActive = false

    var body: some View {
        GeometryReader { geo in
            let aspect = model.selectedDevice.canonicalAspect
            let frame = Self.fitted(size: geo.size, aspect: aspect)

            ZStack {
                if gestureActive {
                    thirdsGrid
                        .frame(width: frame.width, height: frame.height)
                        .transition(.opacity)
                }
                FrameTouchView(model: model, frameSize: frame,
                               active: $gestureActive)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    // MARK: - Geometry (mirror of the Mac's CompositionMath)

    static func fitted(size: CGSize, aspect: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, aspect > 0 else { return size }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }

    // MARK: - Grid overlay

    private var thirdsGrid: some View {
        Canvas { context, size in
            var lines = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(i) / 3
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            context.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: gestureActive)
    }
}

/// The UIKit touch surface. All four recognizers live on THIS view and
/// recognize simultaneously with each other; anything attached elsewhere
/// (the navigation zoom's dismiss pinch, scroll views, the editor's own
/// fit toggle) is forced to wait for ours to fail first.
private struct FrameTouchView: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    var frameSize: CGSize
    @Binding var active: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.rotate(_:)))
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        for recognizer in [pan, pinch, rotate, doubleTap] {
            recognizer.delegate = c
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.model = model
        context.coordinator.frameSize = frameSize
        context.coordinator.setActive = { active in
            if self.active != active { self.active = active }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, frameSize: frameSize)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var model: EditorModel
        var frameSize: CGSize
        var setActive: ((Bool) -> Void)?

        private var dragBase: (x: Double, y: Double)?
        private var scaleBase: Double?
        private var rotationBase: Double?
        private var didSnap = false
        private var liveRecognizers = Set<ObjectIdentifier>()

        init(model: EditorModel, frameSize: CGSize) {
            self.model = model
            self.frameSize = frameSize
        }

        // MARK: Delegate — the exclusivity rules

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Pan + pinch + rotate together on OUR view only.
            other.view === gestureRecognizer.view
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Every recognizer NOT on this view (the zoom-dismiss pinch
            // above all) must wait for ours — which never fail for
            // touches that start on the canvas.
            other.view !== gestureRecognizer.view
        }

        // MARK: Shared param plumbing

        private func number(_ name: String, _ fallback: Double) -> Double {
            if case .number(let v)? = model.preview.params[name] { return v }
            return fallback
        }

        private func track(_ recognizer: UIGestureRecognizer) {
            let id = ObjectIdentifier(recognizer)
            switch recognizer.state {
            case .began:
                liveRecognizers.insert(id)
            case .ended, .cancelled, .failed:
                liveRecognizers.remove(id)
            default:
                break
            }
            let active = !liveRecognizers.isEmpty
            withAnimation(.easeInOut(duration: 0.15)) { setActive?(active) }
        }

        /// The shader's fitted image box for the frame — one offset unit
        /// pans exactly one box (same rule as the shaders and Mac pad).
        private func fittedBox() -> CGSize {
            let a = max(CGFloat(model.currentImageAspect ?? 1), 0.0001)
            let contain: Bool = {
                if case .choice(let f)? = model.preview.params["fit"] { return f == "contain" }
                return false
            }()
            let w = contain
                ? min(frameSize.width / a, frameSize.height) * a
                : max(frameSize.width / a, frameSize.height) * a
            return CGSize(width: w, height: w / a)
        }

        // MARK: Handlers (same math as the retired SwiftUI gestures)

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            track(recognizer)
            switch recognizer.state {
            case .began:
                dragBase = (number("offsetX", 0), number("offsetY", 0))
            case .changed:
                guard let base = dragBase else { return }
                let box = fittedBox()
                guard box.width > 0, box.height > 0 else { return }
                let t = recognizer.translation(in: recognizer.view)
                let x = base.x + Double(t.x / box.width)
                let y = base.y + Double(t.y / box.height)
                guard x.isFinite, y.isFinite else { return }
                model.preview.params["offsetX"] = .number(min(1, max(-1, x)))
                model.preview.params["offsetY"] = .number(min(1, max(-1, y)))
            default:
                dragBase = nil
            }
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            track(recognizer)
            switch recognizer.state {
            case .began:
                scaleBase = number("scale", 1)
            case .changed:
                guard let base = scaleBase, recognizer.scale.isFinite else { return }
                // Clamp to the SCHEMA's scale range (all shaders carry
                // one; procedural documents frame through here too).
                let param = model.schema?.params.first { $0.name == "scale" }
                let lo = param?.min ?? 0.25
                let hi = param?.max ?? 4
                let next = min(hi, max(lo, base * Double(recognizer.scale)))
                guard next.isFinite else { return }
                model.preview.params["scale"] = .number(next)
            default:
                scaleBase = nil
            }
        }

        @objc func rotate(_ recognizer: UIRotationGestureRecognizer) {
            track(recognizer)
            switch recognizer.state {
            case .began:
                rotationBase = number("rotation", 0)
                didSnap = false
            case .changed:
                // The rotation can arrive NaN when the two touches meet at
                // extreme pinches — a NaN written into params crashed
                // every Int(Double) consumer downstream (the Frame ruler).
                let degrees = Double(recognizer.rotation) * 180 / .pi
                guard let base = rotationBase, degrees.isFinite else { return }
                var next = (base + degrees).truncatingRemainder(dividingBy: 360)
                if next < 0 { next += 360 }
                // Snap to level (0°) with one haptic tick, Photos-style.
                let distanceToZero = min(next, 360 - next)
                if distanceToZero < 2 {
                    next = 0
                    if !didSnap {
                        didSnap = true
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    }
                } else {
                    didSnap = false
                }
                model.preview.params["rotation"] = .number(next)
            default:
                rotationBase = nil
            }
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            model.preview.params["offsetX"] = .number(0)
            model.preview.params["offsetY"] = .number(0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
