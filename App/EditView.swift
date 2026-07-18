import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// The EDIT screen — modeled on the iOS Photos editor: Cancel/Done pills,
/// undo/redo, the selected category as a big caps title, full-bleed
/// preview (with direct pinch/rotate/pan composition on photo documents),
/// then bottom-up: ruler/controls for the selected sub-control, the
/// sub-control row, and the main-category tab pill.
struct EditView: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    enum Tab: String, CaseIterable {
        case shader = "Shader"
        case adjust = "Adjust"
        case frame = "Frame"
        case colors = "Colors"

        var systemImage: String {
            switch self {
            case .shader: return "circle.grid.3x3.fill"
            case .adjust: return "dial.low"
            case .frame: return "crop.rotate"
            case .colors: return "paintpalette"
            }
        }
    }

    @State private var tab: Tab = .shader
    @State private var entrySnapshot: WallpaperDocument?
    @State private var canUndo = false
    @State private var canRedo = false

    private var tabs: [Tab] {
        model.document?.kind == .imageBased
            ? [.shader, .adjust, .frame, .colors]
            : [.shader, .adjust, .colors]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                GeometryReader { geo in
                    ZStack {
                        PreviewMetalView(model: model.preview,
                                         mode: app.previewsPaused ? .frozen : .live)
                            .aspectRatio(model.selectedDevice.canonicalAspect,
                                         contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                        // Like Photos' Crop: framing gestures live in the
                        // Frame tab only — no accidental re-framing while
                        // scrubbing an unrelated slider.
                        if tab == .frame {
                            CompositionGestureLayer(model: model)
                        }
                    }
                }
                .padding(.vertical, 10)

                controlsArea
                    .frame(minHeight: 132)
                tabBar
                    .padding(.bottom, 8)
                    .padding(.top, 6)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            entrySnapshot = model.document
            model.undoManager = undoManager
            refreshUndoState()
            // Screenshot automation: land on a specific tab.
            if let index = CommandLine.arguments.firstIndex(of: "--edit-tab"),
               index + 1 < CommandLine.arguments.count,
               let requested = Tab(rawValue: CommandLine.arguments[index + 1].capitalized),
               tabs.contains(requested) {
                tab = requested
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in refreshUndoState() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refreshUndoState() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refreshUndoState() }
    }

    // MARK: - Header (Cancel / undo-redo / title / Done)

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel") { cancel() }
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(.white.opacity(0.12)))
                Spacer()
                Button("Done") { done() }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .foregroundStyle(.white)

            HStack {
                HStack(spacing: 0) {
                    Button {
                        undoManager?.undo()
                        model.reloadEditor()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 36)
                    }
                    .disabled(!canUndo)
                    Button {
                        undoManager?.redo()
                        model.reloadEditor()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 44, height: 36)
                    }
                    .disabled(!canRedo)
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .background(Capsule().fill(.white.opacity(0.12)))

                Spacer()

                Text(tab.rawValue.uppercased())
                    .font(.subheadline.weight(.medium))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                // Balance the undo cluster so the title stays centered.
                Color.clear.frame(width: 88, height: 36)
            }
        }
    }

    private func refreshUndoState() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    private func cancel() {
        // Restore the state the session opened with (Photos semantics) —
        // one library write, no modifiedAt churn beyond the restore itself.
        if let snapshot = entrySnapshot {
            model.flushPendingWriteback()
            model.library.save(snapshot, touchModified: false)
            model.reloadEditor()
        }
        dismiss()
    }

    private func done() {
        model.flushPendingWriteback()
        dismiss()
    }

    // MARK: - Per-tab control area

    @ViewBuilder
    private var controlsArea: some View {
        switch tab {
        case .shader:
            ShaderStyleRow(model: model)
        case .adjust:
            AdjustControlsRow(model: model, controls: EditControls.adjustControls(model: model))
        case .frame:
            FrameControlsRow(model: model)
        case .colors:
            ColorControlsRow(model: model)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(tabs, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = item }
                } label: {
                    VStack(spacing: 4) {
                        Triangle()
                            .fill(tab == item ? Color.yellow : .clear)
                            .frame(width: 8, height: 5)
                        Image(systemName: item.systemImage)
                            .font(.system(size: 19))
                        Text(item.rawValue)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(tab == item ? .white : .white.opacity(0.55))
                    .frame(width: 74)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.rawValue))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(.white.opacity(0.1)))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
