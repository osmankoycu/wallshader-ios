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
struct CompositionGestureLayer: View {
    @ObservedObject var model: EditorModel

    @State private var dragBase: (x: Double, y: Double)?
    @State private var scaleBase: Double?
    @State private var rotationBase: Double?
    @State private var didSnap = false

    private var gestureActive: Bool {
        dragBase != nil || scaleBase != nil || rotationBase != nil
    }

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
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Rectangle())
            .gesture(dragGesture(frameSize: frame))
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(rotateGesture)
            .onTapGesture(count: 2) {
                model.preview.params["offsetX"] = .number(0)
                model.preview.params["offsetY"] = .number(0)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
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

    /// The shader's fitted image box for the frame — one offset unit pans
    /// exactly one box (same rule as the shaders and the Mac pad).
    private func fittedBox(frameSize: CGSize) -> CGSize {
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

    private func number(_ name: String, _ fallback: Double) -> Double {
        if case .number(let v)? = model.preview.params[name] { return v }
        return fallback
    }

    // MARK: - Gestures

    private func dragGesture(frameSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragBase == nil {
                    dragBase = (number("offsetX", 0), number("offsetY", 0))
                }
                guard let base = dragBase else { return }
                let box = fittedBox(frameSize: frameSize)
                guard box.width > 0, box.height > 0 else { return }
                let x = base.x + Double(g.translation.width / box.width)
                let y = base.y + Double(g.translation.height / box.height)
                model.preview.params["offsetX"] = .number(min(1, max(-1, x)))
                model.preview.params["offsetY"] = .number(min(1, max(-1, y)))
            }
            .onEnded { _ in dragBase = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if scaleBase == nil { scaleBase = number("scale", 1) }
                guard let base = scaleBase else { return }
                let next = min(4, max(0.25, base * Double(value)))
                model.preview.params["scale"] = .number(next)
            }
            .onEnded { _ in scaleBase = nil }
    }

    private var rotateGesture: some Gesture {
        RotationGesture()
            .onChanged { angle in
                if rotationBase == nil {
                    rotationBase = number("rotation", 0)
                    didSnap = false
                }
                guard let base = rotationBase else { return }
                var next = (base + angle.degrees).truncatingRemainder(dividingBy: 360)
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
            }
            .onEnded { _ in rotationBase = nil }
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
