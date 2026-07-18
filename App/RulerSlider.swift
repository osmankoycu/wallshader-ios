import SwiftUI
import UIKit

/// The Photos-app ruler scrubber: tick marks sliding under a fixed center
/// indicator. Drag scrubs the value (full ruler width ≈ the whole range),
/// major ticks give haptic detents, double-tap snaps back to the default.
/// The value reads out above the center line, dimmed when at default.
struct RulerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    /// Fired when a drag ends — commit point for expensive work.
    var onCommit: (() -> Void)?

    @State private var dragStartValue: Double?
    @State private var lastDetent: Int?

    /// One shared generator — allocating a fresh one per detent crossing
    /// costs a Taptic Engine prepare on the main thread at scrub rate.
    private static let detentHaptic = UISelectionFeedbackGenerator()

    private var span: Double { range.upperBound - range.lowerBound }

    /// ~64 minor ticks across the range, majors every 8th.
    private var minorStep: Double { span / 64 }

    private var fraction: Double {
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    private var isAtDefault: Bool {
        guard let defaultValue else { return false }
        return abs(value - defaultValue) < minorStep / 4
    }

    private var valueText: String {
        if let step, step >= 1, step == step.rounded() {
            return String(Int(value.rounded()))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(valueText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isAtDefault ? .secondary : .primary)

            GeometryReader { geo in
                let width = geo.size.width
                let tickSpacing: CGFloat = 7
                let visibleTicks = Int(width / tickSpacing) + 2
                // The ruler surface travels so the tick for `value` sits
                // under the center indicator.
                let totalTicks = Int((span / minorStep).rounded())
                let offset = CGFloat(fraction * Double(totalTicks)) * tickSpacing

                ZStack {
                    Canvas { context, size in
                        let centerX = size.width / 2
                        for i in 0...visibleTicks {
                            // Ticks are laid out in ruler space and shifted
                            // by the travel offset, wrapped to the window.
                            let rulerIndex = Int((offset / tickSpacing).rounded(.down)) - visibleTicks / 2 + i
                            guard rulerIndex >= 0, rulerIndex <= totalTicks else { continue }
                            let x = centerX + CGFloat(rulerIndex) * tickSpacing - offset
                            guard x >= -2, x <= size.width + 2 else { continue }
                            let isMajor = rulerIndex % 8 == 0
                            let height: CGFloat = isMajor ? 16 : 9
                            let y = (size.height - height) / 2
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x, y: y + height))
                            context.stroke(path, with: .color(.white.opacity(isMajor ? 0.55 : 0.3)),
                                           lineWidth: 1)
                        }
                        // Fixed center indicator, Photos-style: taller, white.
                        var center = Path()
                        center.move(to: CGPoint(x: centerX, y: (size.height - 24) / 2))
                        center.addLine(to: CGPoint(x: centerX, y: (size.height + 24) / 2))
                        context.stroke(center, with: .color(.white), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            if dragStartValue == nil { dragStartValue = value }
                            guard width > 0, let base = dragStartValue else { return }
                            // Dragging the ruler LEFT increases the value
                            // (the surface moves under the fixed needle).
                            let delta = -Double(g.translation.width / width) * span * 0.9
                            set(base + delta)
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                            lastDetent = nil
                            onCommit?()
                        }
                )
                .onTapGesture(count: 2) {
                    guard let defaultValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        value = min(range.upperBound, max(range.lowerBound, defaultValue))
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCommit?()
                }
            }
            .frame(height: 36)
        }
        .accessibilityElement()
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in
            let increment = step ?? span / 20
            switch direction {
            case .increment: set(value + increment)
            case .decrement: set(value - increment)
            @unknown default: break
            }
            onCommit?()
        }
    }

    private func set(_ raw: Double) {
        var next = min(range.upperBound, max(range.lowerBound, raw))
        if let step, step > 0 {
            next = (next / step).rounded() * step
            next = min(range.upperBound, max(range.lowerBound, next))
        }
        if next != value {
            value = next
            // Haptic detent on every major tick crossed, Photos-feel.
            let detent = Int(((next - range.lowerBound) / (minorStep * 8)).rounded())
            if detent != lastDetent {
                lastDetent = detent
                Self.detentHaptic.selectionChanged()
            }
        }
    }
}

/// A Photos-style circular sub-control: SF Symbol in a circle, selected =
/// white-filled with black glyph, a small dot marks a non-default value.
struct ControlCircle: View {
    let title: String
    let systemImage: String
    var isSelected: Bool
    var isModified: Bool = false
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.12))
                        .frame(width: 46, height: 46)
                    if let tint {
                        Circle().fill(tint).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isSelected ? .black : .white)
                    }
                }
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                    .lineLimit(1)
                Circle()
                    .fill(isModified ? Color.white.opacity(0.8) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}
