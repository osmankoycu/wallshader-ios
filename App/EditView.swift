import PhotosUI
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// The EDIT screen — modeled on the iOS Photos editor. Header v2: tiny
/// Cancel/Done capsules flank the Dynamic Island (Done lights up yellow
/// once the session is dirty; Cancel morphs into a Discard Changes panel),
/// with undo/redo, the small caps title and the fit + play/pause (or
/// photo-replace) circles on the second row. The preview is a slot the
/// wallpaper layer sits in — pinch or the fit button toggles it between
/// the slot and FULL SCREEN (binary, no free zoom), with all editor UI
/// hovering above. Bottom-up: controls for the selected tab, then the
/// compact category bar.
struct EditView: View {
    @ObservedObject var model: EditorModel
    /// Creation flow (+ sheet): Cancel discards the freshly created
    /// wallpaper instead of restoring an entry snapshot.
    var onCancel: (() -> Void)? = nil
    /// Detail-morph mode: the preview area is an EMPTY measured slot (the
    /// detail screen flies its single hero layer into it) and closing goes
    /// through the owner instead of a dismissal.
    var heroMode: Bool = false
    /// Drives the morph choreography in hero mode: the header arrives
    /// from the top, controls and tab bar from the bottom.
    var revealed: Bool = true
    /// Hero mode: the owner's hero layer follows this (slot ↔ fullscreen).
    var zoomedBinding: Binding<Bool>? = nil
    var onClose: (() -> Void)? = nil
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
    /// Creation flow owns its own zoom state (no external hero layer).
    @State private var localZoomed = false
    @State private var localSlotAnchor: Anchor<CGRect>?
    @State private var showingPhotoReplace = false
    /// Slider-drag auto-fullscreen (experimental): tracks that WE zoomed,
    /// so release can restore — a user-chosen fullscreen is never touched.
    @State private var autoZoomed = false

    private static let zoomSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Every shader carries the full sizing group (scale/rotation/offset/
    /// fit), so Frame applies to procedural wallpapers too.
    private var tabs: [Tab] { [.shader, .adjust, .frame, .colors] }

    private var zoomed: Bool { zoomedBinding?.wrappedValue ?? localZoomed }

    private func setZoomed(_ value: Bool) {
        withAnimation(Self.zoomSpring) {
            if let zoomedBinding {
                zoomedBinding.wrappedValue = value
            } else {
                localZoomed = value
            }
        }
    }

    /// Anything to walk back this session? (Undo burst registers on the
    /// FIRST change, so this beats the debounced document compare.)
    private var isDirty: Bool {
        if canUndo { return true }
        if let entrySnapshot, let doc = model.document, doc != entrySnapshot { return true }
        return false
    }

    var body: some View {
        GeometryReader { outer in
            let topInset = outer.safeAreaInsets.top
            let bottomInset = outer.safeAreaInsets.bottom
            ZStack {
            // Hero mode: the owner hosts the black backdrop UNDER its hero
            // layer, so the fullscreen-fit wallpaper can show through with
            // this chrome hovering on top.
            (heroMode ? Color.clear : Color.black).ignoresSafeArea()

            if !heroMode {
                // Creation flow's own wallpaper layer, same architecture
                // as the detail hero: one live view flying slot ↔ full.
                GeometryReader { proxy in
                    let full = CGRect(origin: .zero, size: proxy.size)
                    let slotState = !zoomed && localSlotAnchor != nil
                    let rect = slotState ? proxy[localSlotAnchor!] : full
                    PreviewMetalView(model: model.preview,
                                     mode: app.previewsPaused ? .frozen : .live)
                        .aspectRatio(model.selectedDevice.canonicalAspect,
                                     contentMode: .fit)
                        .editSlotDressing(active: slotState)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }

            // Every pinch in the editor lands HERE (except the Frame
            // canvas, which sits above and owns its own touches): outside
            // Frame it toggles slot <-> fullscreen; in Frame it does
            // nothing — but by recognizing it still STARVES the detail
            // zoom's pinch-to-grid, so no gesture can ever close the
            // editor. Cancel/Done are the only exits (Photos parity).
            EditPinchShield(isFitToggle: tab != .frame) { scale in
                if scale > 1.08, !zoomed {
                    setZoomed(true)
                } else if scale < 0.92, zoomed {
                    setZoomed(false)
                }
            }
            .ignoresSafeArea()

            // Framing gestures + thirds grid follow the PREVIEW's rect —
            // the whole screen in fullscreen, the slot otherwise. Sits
            // UNDER the chrome so buttons stay tappable in Frame mode.
            if tab == .frame {
                GeometryReader { proxy in
                    let full = CGRect(origin: .zero, size: proxy.size)
                    let rect = (!zoomed && localSlotAnchor != nil)
                        ? proxy[localSlotAnchor!] : full
                    CompositionGestureLayer(model: model)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    // Into the top safe area: the capsules ride the Dynamic
                    // Island's line (the status bar is hidden here).
                    .padding(.top, topInset > 0 ? 14 : 10)
                    .offset(y: revealed ? 0 : -56)

                GeometryReader { geo in
                    Color.clear
                        .aspectRatio(model.selectedDevice.canonicalAspect,
                                     contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .anchorPreference(key: EditSlotAnchorKey.self,
                                          value: .bounds) { $0 }
                }
                .padding(.vertical, 10)

                Group {
                    controlsArea
                        .frame(height: 138)
                    tabBar
                        .padding(.top, 6)
                        // Down into the bottom safe area, stopping just
                        // above the home indicator.
                        .padding(.bottom, bottomInset > 0 ? 16 : 10)
                }
                .offset(y: revealed ? 0 : 56)
            }
            .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onPreferenceChange(EditSlotAnchorKey.self) { anchor in
            localSlotAnchor = anchor
        }
        .sheet(isPresented: $showingPhotoReplace) {
            PhotoReplaceSheet { url in
                model.importImage(url: url)
            }
        }
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

    // MARK: - Header v2 (tiny Cancel/Done row + tool row)

    private var header: some View {
        VStack(spacing: 10) {
            // Row 1: small capsules flanking the Dynamic Island.
            HStack {
                // Column-aligned with row 2: Cancel's right edge meets the
                // undo/redo group's right edge, Done's left edge meets the
                // circles' left edge.
                cancelControl
                    .frame(width: 88, alignment: .trailing)
                Spacer()
                doneButton
                    .frame(width: 88, alignment: .leading)
            }

            // Row 2: undo/redo left, title centered, fit + mode right.
            HStack {
                HStack(spacing: 0) {
                    Button {
                        undoManager?.undo()
                        model.reloadEditor()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 40)
                    }
                    .disabled(!canUndo)
                    Button {
                        undoManager?.redo()
                        model.reloadEditor()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 44, height: 40)
                    }
                    .disabled(!canRedo)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .chromeGlass(in: Capsule())
                .frame(width: 88, alignment: .leading)

                Spacer()

                Text(tab.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(1.4)
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                HStack(spacing: 8) {
                    headerCircle(zoomed ? "arrow.down.right.and.arrow.up.left"
                                        : "arrow.up.left.and.arrow.down.right",
                                 label: zoomed ? "Shrink Preview" : "Fit to Screen") {
                        setZoomed(!zoomed)
                    }
                    modeCircle
                }
                .frame(width: 88, alignment: .trailing)
            }
        }
    }

    private var cancelControl: some View {
        Group {
            if isDirty {
                // The button MORPHS into the unsaved-changes panel, the
                // same pattern as the detail screen's delete button.
                Menu {
                    Section {
                        Button(role: .destructive) {
                            cancel()
                        } label: { Label("Discard Changes", systemImage: "trash") }
                    } header: {
                        Text("Your changes haven't been saved.")
                    }
                } label: {
                    smallCapsuleLabel("Cancel")
                }
            } else {
                Button { cancel() } label: {
                    smallCapsuleLabel("Cancel")
                }
            }
        }
        .accessibilityLabel("Cancel")
    }

    private var doneButton: some View {
        // Photos: Done sleeps until the session is dirty, then lights up
        // in the system yellow. Creation flow keeps it live throughout —
        // there the new wallpaper itself is the change.
        Button { done() } label: {
            Group {
                if isDirty {
                    Text("Done")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(Capsule().fill(Color.yellow))
                } else {
                    smallCapsuleLabel("Done")
                        .opacity(onCancel != nil ? 1 : 0.5)
                }
            }
        }
        .disabled(!isDirty && onCancel == nil)
        .accessibilityLabel("Done")
    }

    private func smallCapsuleLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .chromeGlass(in: Capsule())
    }

    private func headerCircle(_ systemImage: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .chromeGlass(in: Circle())
        }
        .accessibilityLabel(Text(label))
    }

    /// The right slot next to fit: play/pause for animatable shaders (the
    /// live/still decision lives HERE now, not on the detail bar), the
    /// photo-replace picker for photo documents, empty otherwise.
    @ViewBuilder
    private var modeCircle: some View {
        if model.document?.kind == .imageBased {
            headerCircle("photo", label: "Replace Photo") {
                showingPhotoReplace = true
            }
        } else if model.document?.shaderIsAnimatable == true {
            let animated = model.editingVariant?.animated ?? false
            headerCircle(animated ? "pause.fill" : "play.fill",
                         label: animated ? "Make Still" : "Make Animated") {
                model.setAnimated(!animated)
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } else {
            Color.clear.frame(width: 40, height: 40)
        }
    }

    /// Experimental: a slider drag in the SMALL state zooms the preview
    /// fullscreen for the duration of the scrub. A fullscreen the user
    /// chose (fit button / pinch) is never auto-exited.
    private func setScrubbing(_ active: Bool) {
        if active {
            guard !zoomed else { return }
            autoZoomed = true
            setZoomed(true)
        } else if autoZoomed {
            autoZoomed = false
            if zoomed { setZoomed(false) }
        }
    }

    private func refreshUndoState() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    private func cancel() {
        if let onCancel {
            onCancel()
            close()
            return
        }
        // Restore the state the session opened with (Photos semantics) —
        // one library write, no modifiedAt churn beyond the restore itself.
        if let snapshot = entrySnapshot {
            model.flushPendingWriteback()
            model.library.save(snapshot, touchModified: false)
            model.reloadEditor()
        }
        close()
    }

    private func done() {
        model.flushPendingWriteback()
        close()
    }

    private func close() {
        if zoomed { setZoomed(false) }
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    // MARK: - Per-tab control area

    @ViewBuilder
    private var controlsArea: some View {
        switch tab {
        case .shader:
            ShaderStyleRow(model: model, preview: model.preview)
        case .adjust:
            AdjustControlsRow(model: model, preview: model.preview,
                              sections: EditControls.adjustSections(model: model),
                              onScrubbing: { setScrubbing($0) })
        case .frame:
            FrameControlsRow(model: model, preview: model.preview)
        case .colors:
            ColorControlsRow(model: model, preview: model.preview)
        }
    }

    // Compact v2: no indicator triangle — the active item simply reads in
    // the app yellow, tighter cell/bar metrics.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 18))
                        Text(item.rawValue)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(tab == item ? Color.yellow : .white.opacity(0.55))
                    .frame(width: 56)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.rawValue))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .chromeGlass(in: Capsule())
    }
}

/// The editor's pinch owner. A UIKit recognizer whose delegate forces
/// every recognizer outside this view (the detail zoom's interactive
/// pinch-to-grid, the nav edge swipe) to wait for it — and it never
/// fails, so no gesture can dismiss the editor. Outside the Frame tab
/// the recognized pinch drives the binary fit toggle.
private struct EditPinchShield: UIViewRepresentable {
    var isFitToggle: Bool
    var onPinchEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ShieldView()
        view.backgroundColor = .clear
        // Edge swipes never reach OUR recognizers — the system gates
        // edge-originating touches and claims them first — so while the
        // editor lives, the nav stack's edge-pop recognizers are switched
        // OFF outright (re-enabled in dismantle when the editor closes).
        view.onAttach = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.disableSystemDismiss(from: view)
        }
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.pinch(_:)))
        // A greedy do-nothing pan: the nav stack's EDGE SWIPE is a
        // one-finger gesture the pinch can't starve (it fails on single
        // touches, releasing the edge pan). This pan claims every
        // one-finger drag on the canvas instead, so no swipe can pop the
        // editor either — Cancel/Done stay the only exits.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        for recognizer in [pinch, pan] as [UIGestureRecognizer] {
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.isFitToggle = isFitToggle
        context.coordinator.onPinchEnded = onPinchEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFitToggle: isFitToggle, onPinchEnded: onPinchEnded)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.restoreSystemDismiss()
    }

    /// Reports when it lands in a window, so the coordinator can find the
    /// navigation controller in the responder chain.
    final class ShieldView: UIView {
        var onAttach: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onAttach?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isFitToggle: Bool
        var onPinchEnded: (CGFloat) -> Void

        init(isFitToggle: Bool, onPinchEnded: @escaping (CGFloat) -> Void) {
            self.isFitToggle = isFitToggle
            self.onPinchEnded = onPinchEnded
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended, isFitToggle,
                  recognizer.scale.isFinite else { return }
            onPinchEnded(recognizer.scale)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            // Intentionally empty: recognizing is the whole job.
        }

        // MARK: Edge-pop suppression

        private var disabledRecognizers: [(UIGestureRecognizer, Bool)] = []

        func disableSystemDismiss(from view: UIView) {
            guard disabledRecognizers.isEmpty, let window = view.window else { return }
            // The pop/dismiss machinery is SCATTERED: the edge pop sits on
            // the nav container, but a SECOND parallax pan (the horizontal
            // scroll-edge handoff) plus the content-swipe dismiss live on
            // the pushed page's own hosting view (found via a full window
            // census on hardware). Sweep the whole window by class name.
            var targets: [UIGestureRecognizer] = []
            func sweep(_ v: UIView) {
                for recognizer in v.gestureRecognizers ?? [] {
                    let name = String(describing: Swift.type(of: recognizer))
                    if recognizer is UIScreenEdgePanGestureRecognizer
                        || name.contains("ParallaxTransition")
                        || name.contains("ContentSwipeDismiss") {
                        targets.append(recognizer)
                    }
                }
                for sub in v.subviews { sweep(sub) }
            }
            sweep(window)
            for recognizer in targets where recognizer.view !== view && recognizer.isEnabled {
                disabledRecognizers.append((recognizer, true))
                recognizer.isEnabled = false
            }
        }

        func restoreSystemDismiss() {
            for (recognizer, wasEnabled) in disabledRecognizers {
                recognizer.isEnabled = wasEnabled
            }
            disabledRecognizers = []
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view !== gestureRecognizer.view
        }
    }
}

/// Rounded corners + the grid tiles' rim light at HALF opacity, applied
/// to the wallpaper layer only while it sits in the edit slot. Fullscreen
/// drops both; shrinking brings them back (animates with the zoom spring).
extension View {
    func editSlotDressing(active: Bool) -> some View {
        clipShape(RoundedRectangle(cornerRadius: active ? 18 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    .blendMode(.plusLighter)
                    .opacity(active ? 1 : 0)
            }
    }
}

/// The editor's preview slot, reported to the detail screen so its hero
/// layer knows where to fly.
struct EditSlotAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The photo-replace picker: the creation sheet's source rows, reused for
/// swapping the photo under the current edit session.
private struct PhotoReplaceSheet: View {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFiles = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Replace Photo")
                .font(.headline)
                .padding(.top, 18)
            VStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    sourceRow("Photo Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    showingFiles = true
                } label: {
                    sourceRow("Files", systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("picked-\(UUID().uuidString)")
                    try? data.write(to: tmp)
                    onPick(tmp)
                }
                photoItem = nil
                dismiss()
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                onPick(url)
                dismiss()
            }
        }
    }

    private func sourceRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
            Text(title)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
    }
}
