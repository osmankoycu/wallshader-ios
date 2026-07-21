import SwiftUI
import UIKit

/// The Photos-app scrubber, v2. Two faces behind one API:
///
/// - CONTINUOUS params get the ruler: rounded hairline ticks melting away
///   at both edges, a fixed center needle, 1:1 finger tracking with no
///   quantization — the surface glides, it never steps.
/// - DISCRETE params (integer steps, a handful of values) get a dot
///   scale instead: one dot per value, the active one grown, drag or tap
///   snaps dot to dot. Counts like "4 steps" should LOOK countable, not
///   like a continuous dial that secretly notches.
///
/// The value reads out above either face, dimmed when at default;
/// double-tap snaps back to the default.
struct RulerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    /// .horizontal (iPhone rows) or .vertical (the iPad Adjust column).
    var axis: Axis = .horizontal
    /// Fired when a drag ends — commit point for expensive work.
    var onCommit: (() -> Void)?
    /// Fired with true on the first drag movement, false on release —
    /// the edit screen's auto-fullscreen hook.
    var onScrubbing: ((Bool) -> Void)?

    @State private var dragStartValue: Double?
    @State private var lastDetent: Int?
    /// The live drag value, echoed locally. The binding's read side can
    /// lag behind (the model coalesces publishes while scrubbing for
    /// preview performance), which made the ruler step 0.44 -> 0.57 while
    /// the preview glided — the surface must track the finger 1:1, so
    /// during a drag the view renders from THIS, not the binding.
    @State private var dragValue: Double?

    /// One shared generator — allocating a fresh one per detent crossing
    /// costs a Taptic Engine prepare on the main thread at scrub rate.
    private static let detentHaptic = UISelectionFeedbackGenerator()

    private var span: Double { range.upperBound - range.lowerBound }

    /// A param-derived value can arrive NaN/Inf (bad gesture math upstream,
    /// corrupt document): every consumer below reads through this clamp so
    /// no Int(Double) conversion can ever trap.
    private var safeValue: Double {
        let current = dragValue ?? value
        guard current.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, current))
    }

    /// Integer-ish params with few enough values to show one dot each.
    private var discreteCount: Int? {
        guard let step, step >= 1, step == step.rounded(), span > 0 else { return nil }
        let count = Int((span / step).rounded()) + 1
        return count <= 24 ? count : nil
    }

    /// The tick grid: ~80 lines across the range, majors every 8th. A
    /// schema step COARSER than that becomes the grid itself, so the
    /// drawn lines, the snap targets and the haptic detents are always
    /// the same set.
    private var minorStep: Double {
        guard span > 0 else { return 1 }
        let dense = span / 80
        if let step, step > dense { return step }
        return dense
    }

    private var fraction: Double {
        guard span > 0 else { return 0 }
        return (safeValue - range.lowerBound) / span
    }

    private var isAtDefault: Bool {
        guard let defaultValue else { return false }
        return abs(safeValue - defaultValue) < minorStep / 4
    }

    private var valueText: String {
        if let step, step >= 1, step == step.rounded() {
            return String(Int(safeValue.rounded()))
        }
        return safeValue.formatted(.number.precision(.fractionLength(0...2)))
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(valueText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isAtDefault ? .secondary : .primary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: valueText)

            if let count = discreteCount {
                dotScale(count: count)
            } else if axis == .vertical {
                verticalRuler
            } else {
                ruler
            }
        }
        .accessibilityElement()
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in
            let increment = step ?? span / 20
            switch direction {
            case .increment: set(safeValue + increment)
            case .decrement: set(safeValue - increment)
            @unknown default: break
            }
            onCommit?()
        }
    }

    // MARK: - Continuous face (the ruler)

    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let tickSpacing: CGFloat = 7
            let visibleTicks = Int(width / tickSpacing) + 2
            // The ruler surface travels so the tick for `value` sits
            // under the center indicator.
            let totalTicks = max(1, Int((span / minorStep).rounded()))
            let offset = CGFloat(fraction * Double(totalTicks)) * tickSpacing

            Canvas { context, size in
                let centerX = size.width / 2
                for i in 0...visibleTicks {
                    // Ticks are laid out in ruler space and shifted by
                    // the travel offset, wrapped to the window.
                    let rulerIndex = Int((offset / tickSpacing).rounded(.down)) - visibleTicks / 2 + i
                    guard rulerIndex >= 0, rulerIndex <= totalTicks else { continue }
                    let x = centerX + CGFloat(rulerIndex) * tickSpacing - offset
                    guard x >= -2, x <= size.width + 2 else { continue }
                    let isMajor = rulerIndex % 8 == 0
                    let height: CGFloat = isMajor ? 14 : 8
                    let y = (size.height - height) / 2
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + height))
                    context.stroke(path, with: .color(.white.opacity(isMajor ? 0.6 : 0.28)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                // Fixed center needle: a rounded bar, taller than the majors.
                let needle = Path(roundedRect: CGRect(x: centerX - 1.25,
                                                      y: (size.height - 26) / 2,
                                                      width: 2.5, height: 26),
                                  cornerRadius: 1.25)
                context.fill(needle, with: .color(.white))
            }
            // The tick field melts away at both ends instead of clipping.
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStartValue == nil {
                            dragStartValue = safeValue
                            onScrubbing?(true)
                        }
                        guard width > 0, let base = dragStartValue else { return }
                        // Dragging the ruler LEFT increases the value
                        // (the surface moves under the fixed needle).
                        let delta = -Double(g.translation.width / width) * span * 0.9
                        set(base + delta)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        dragValue = nil
                        lastDetent = nil
                        onScrubbing?(false)
                        onCommit?()
                    }
            )
            .onTapGesture(count: 2) { snapToDefault() }
        }
        .frame(height: 36)
    }

    // MARK: - Continuous face, standing up (iPad Adjust column)

    private var verticalRuler: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let tickSpacing: CGFloat = 7
            let visibleTicks = Int(height / tickSpacing) + 2
            let totalTicks = max(1, Int((span / minorStep).rounded()))
            let offset = CGFloat(fraction * Double(totalTicks)) * tickSpacing

            Canvas { context, size in
                let centerY = size.height / 2
                for i in 0...visibleTicks {
                    let rulerIndex = Int((offset / tickSpacing).rounded(.down)) - visibleTicks / 2 + i
                    guard rulerIndex >= 0, rulerIndex <= totalTicks else { continue }
                    // Value grows UPWARD: higher index sits higher.
                    let y = centerY - CGFloat(rulerIndex) * tickSpacing + offset
                    guard y >= -2, y <= size.height + 2 else { continue }
                    let isMajor = rulerIndex % 8 == 0
                    let width: CGFloat = isMajor ? 14 : 8
                    let x = (size.width - width) / 2
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + width, y: y))
                    context.stroke(path, with: .color(.white.opacity(isMajor ? 0.6 : 0.28)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                let needle = Path(roundedRect: CGRect(x: (size.width - 26) / 2,
                                                      y: centerY - 1.25,
                                                      width: 26, height: 2.5),
                                  cornerRadius: 1.25)
                context.fill(needle, with: .color(.white))
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStartValue == nil {
                            dragStartValue = safeValue
                            onScrubbing?(true)
                        }
                        guard height > 0, let base = dragStartValue else { return }
                        // Dragging DOWN moves the surface down = value up?
                        // Photos: drag UP increases — translation is
                        // negative upward, so subtracting flips it right.
                        let delta = Double(g.translation.height / height) * span * 0.9
                        set(base + delta)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        dragValue = nil
                        lastDetent = nil
                        onScrubbing?(false)
                        onCommit?()
                    }
            )
            .onTapGesture(count: 2) { snapToDefault() }
        }
        .frame(width: 36)
    }

    // MARK: - Discrete face (the dot scale)

    private func dotScale(count: Int) -> some View {
        GeometryReader { geo in
            let stride = min(26, max(16, geo.size.width / CGFloat(count)))
            let rowWidth = stride * CGFloat(count)
            let selected = selectedIndex(count: count)

            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == selected ? 1 : 0.3))
                        .frame(width: index == selected ? 9 : 5,
                               height: index == selected ? 9 : 5)
                        .frame(width: stride)
                        .animation(.snappy(duration: 0.18), value: selected)
                }
            }
            .frame(width: rowWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStartValue == nil {
                            dragStartValue = safeValue
                            onScrubbing?(true)
                        }
                        // Map touch x straight to the nearest dot slot.
                        let origin = (geo.size.width - rowWidth) / 2
                        let raw = (g.location.x - origin) / max(stride, 1) - 0.5
                        guard raw.isFinite else { return }
                        let index = min(count - 1, max(0, Int(raw.rounded())))
                        setIndex(index, count: count)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        dragValue = nil
                        lastDetent = nil
                        onScrubbing?(false)
                        onCommit?()
                    }
            )
            .onTapGesture(count: 2) { snapToDefault() }
        }
        .frame(height: 36)
    }

    private func selectedIndex(count: Int) -> Int {
        guard let step, step > 0 else { return 0 }
        let index = Int(((safeValue - range.lowerBound) / step).rounded())
        return min(count - 1, max(0, index))
    }

    private func setIndex(_ index: Int, count: Int) {
        guard let step else { return }
        let next = min(range.upperBound,
                       max(range.lowerBound, range.lowerBound + Double(index) * step))
        if next != safeValue {
            if dragStartValue != nil { dragValue = next }
            value = next
            if index != lastDetent {
                lastDetent = index
                Self.detentHaptic.selectionChanged()
            }
        }
    }

    // MARK: - Shared

    private func snapToDefault() {
        guard let defaultValue else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            value = min(range.upperBound, max(range.lowerBound, defaultValue))
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCommit?()
    }

    private func set(_ raw: Double) {
        // NaN/Inf must never reach params: min/max PROPAGATE NaN, so the
        // finite check is load-bearing, not paranoia.
        guard raw.isFinite else { return }
        var next = min(range.upperBound, max(range.lowerBound, raw))
        // Snap to the tick grid — the surface clicks line to line instead
        // of drifting between them (schema steps coarser than the grid
        // ARE the grid, see minorStep).
        if minorStep > 0 {
            next = range.lowerBound
                + ((next - range.lowerBound) / minorStep).rounded() * minorStep
            next = min(range.upperBound, max(range.lowerBound, next))
        }
        if next != safeValue {
            if dragStartValue != nil { dragValue = next }
            value = next
            // One haptic per tick line crossed.
            let detent = Int(((next - range.lowerBound) / minorStep).rounded())
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
            VStack(spacing: 4) {
                ZStack {
                    // Glass, not a flat 12% white: the circles must stay
                    // readable over a fullscreen wallpaper. One identity —
                    // the glass base persists and the white selected face
                    // fades over it (an if/else swap crossfaded two
                    // circles, a visible double image).
                    Color.clear
                        .frame(width: 46, height: 46)
                        .chromeGlass(in: Circle())
                    Circle().fill(Color.white)
                        .frame(width: 46, height: 46)
                        .opacity(isSelected ? 1 : 0)
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
                // Photos marks touched controls with the app's yellow —
                // with a breath of space, not glued to the label.
                Circle()
                    .fill(isModified ? Color.yellow : .clear)
                    .frame(width: 4, height: 4)
                    .padding(.top, 2)
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}
