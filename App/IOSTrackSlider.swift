import SwiftUI

/// Port of the Mac Studio's TrackSlider (C2 requirement: the slider design
/// carries over — pill track, strong fill, title left, value right,
/// relative drag scrubbing, double-tap resets to default). The Mac's
/// click-to-type value editing is dropped on touch (logged decision);
/// everything else keeps the same visual language and drag feel.
struct TrackSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    /// Fired when a drag gesture ends — commit points for expensive
    /// downstream work (photo adjustments re-render on release).
    var onCommit: (() -> Void)?

    @State private var dragStart: Double?
    @State private var isDragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private var valueText: String {
        if let step, step >= 1, step == step.rounded() {
            return String(Int(value.rounded()))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Rectangle().fill(Color.primary)
                    .opacity(isDragging ? 0.8 : 0.5)
                    .frame(width: max(0, geo.size.width * fraction))
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.18), value: isDragging)

                HStack(spacing: 8) {
                    Text(title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(valueText)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .allowsHitTesting(false)
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        guard geo.size.width > 0 else { return }
                        if dragStart == nil { dragStart = value }
                        isDragging = true
                        let span = range.upperBound - range.lowerBound
                        let delta = Double(g.translation.width) / Double(geo.size.width) * span
                        set((dragStart ?? value) + delta)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        isDragging = false
                        onCommit?()
                    }
            )
            .onTapGesture(count: 2) { resetToDefault() }
        }
        .frame(height: 34) // ≥44pt row with section spacing; touch-friendly
        .accessibilityElement()
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in
            let increment = step ?? (range.upperBound - range.lowerBound) / 20
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
        if next != value { value = next }
    }

    private func resetToDefault() {
        guard let defaultValue else { return }
        value = min(range.upperBound, max(range.lowerBound, defaultValue))
        onCommit?()
    }
}
