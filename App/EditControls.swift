import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel
import WallshaderPalettes

/// One sub-control in the Photos-style edit rows: a circle icon plus its
/// interaction (ruler slider, option pills, direct toggle, or one-shot
/// action). Closures read/write through the EditorModel so the rows stay
/// declarative.
struct EditControl: Identifiable {
    enum Kind {
        case slider(range: ClosedRange<Double>, step: Double?, defaultValue: Double?,
                    get: () -> Double, set: (Double) -> Void, commit: () -> Void)
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case options(all: [String], get: () -> String, set: (String) -> Void)
        case action(run: () -> Void)
    }

    let id: String
    let title: String
    let systemImage: String
    let kind: Kind
    var isModified: () -> Bool = { false }
}

/// A titled slice of the Adjust circle row (the Mac inspector's grouped
/// sections, flattened to one horizontal band with labeled dividers).
struct EditSection {
    let title: String?
    let controls: [EditControl]
}

@MainActor
enum EditControls {
    /// Every schema param gets a glyph that MEANS something (feedback:
    /// the cycled abstract dials read as random). Exact names first, then
    /// keyword families, then the abstract pool as a last resort.
    private static let paramIconMap: [String: String] = [
        "size": "smallcircle.filled.circle", "grainSize": "circle.grid.3x3",
        "sizeRange": "circle.hexagongrid", "minDot": "circle.circle",
        "midSize": "circle.circle", "spotSize": "smallcircle.filled.circle",
        "smokeSize": "cloud", "shapeScale": "plus.magnifyingglass",
        "noiseScale": "plus.magnifyingglass",
        "softness": "drop", "blur": "drop", "colorSteps": "square.stack.3d.up",
        "stepsPerColor": "square.stack.3d.up",
        "shape": "square.on.circle", "innerShape": "circle.inset.filled",
        "distortionShape": "skew",
        "distortion": "water.waves", "swirl": "hurricane", "twist": "tornado",
        "grainMixer": "camera.filters", "grainOverlay": "circle.dotted",
        "type": "slider.horizontal.3", "contrast": "circle.lefthalf.filled",
        "proportion": "aspectratio", "aspectRatio": "aspectratio",
        "density": "aqi.high", "edges": "square.dashed",
        "intensity": "dial.high", "midIntensity": "dial.low",
        "noise": "aqi.medium", "gridNoise": "grid",
        "noiseFrequency": "waveform.path", "distortionFreq": "waveform.path",
        "frequency": "waveform.path", "amplitude": "waveform.path.ecg",
        "radius": "circle.dashed", "strokeWidth": "lineweight",
        "thickness": "lineweight", "strokeTaper": "pencil.tip",
        "strokeCap": "capsule.portrait",
        "highlights": "sun.max", "shadows": "moon", "brightness": "sun.max",
        "bloom": "sun.haze", "glow": "rays", "fade": "sun.dust",
        "fadeIn": "sunrise", "fadeOut": "sunset",
        "marginLeft": "arrow.left.to.line", "marginRight": "arrow.right.to.line",
        "marginTop": "arrow.up.to.line", "marginBottom": "arrow.down.to.line",
        "inverted": "circle.righthalf.filled", "mixing": "arrow.triangle.merge",
        "angle": "angle", "angle1": "angle", "angle2": "angle",
        "focalAngle": "angle", "length": "ruler",
        "gradient": "circle.bottomhalf.filled",
        "gap": "arrow.left.and.right", "gapX": "arrow.left.and.right",
        "gapY": "arrow.up.and.down", "spacing": "arrow.left.and.right",
        "stretch": "arrow.left.and.right",
        "shift": "arrow.left.arrow.right", "waveXShift": "arrow.left.arrow.right",
        "waveYShift": "arrow.up.arrow.down", "distortionShift": "arrow.left.arrow.right",
        "opacityRange": "circle.tophalf.filled", "spreading": "wind",
        "spots": "circle.grid.2x2", "spotty": "circle.grid.2x2",
        "floodC": "c.circle", "floodM": "m.circle", "floodY": "y.circle",
        "floodK": "k.circle", "gainC": "c.square", "gainM": "m.square",
        "gainY": "y.square", "gainK": "k.square",
        "grid": "grid", "count": "number", "foldCount": "number",
        "octaveCount": "number", "bandCount": "number",
        "noiseIterations": "repeat", "swirlIterations": "repeat",
        "roughness": "scribble.variable", "fiber": "line.diagonal",
        "fiberSize": "ruler", "crumples": "scribble", "crumpleSize": "ruler",
        "folds": "rectangle.compress.vertical", "drops": "drop.circle",
        "seed": "die.face.5", "persistence": "waveform.path.ecg",
        "lacunarity": "waveform", "roundness": "capsule",
        "pulse": "wave.3.right", "smoke": "cloud.fog",
        "positions": "rectangle.3.group",
        "waveX": "water.waves", "waveY": "wave.3.up", "waves": "water.waves",
        "caustic": "sparkles", "focalDistance": "camera.metering.center.weighted",
        "falloff": "chart.line.downtrend.xyaxis", "center": "scope",
        "layering": "square.stack.3d.forward.dottedline",
        "colors": "paintpalette",
    ]

    /// Last-resort pool for params no rule knows (new shaders).
    private static let fallbackIcons = [
        "dial.low", "circle.grid.2x2", "waveform.path", "aqi.medium",
        "camera.filters", "square.stack.3d.forward.dottedline", "sparkles",
        "circle.hexagongrid", "rays", "seal",
    ]

    static func icon(for name: String, fallbackIndex: Int) -> String {
        if let exact = paramIconMap[name] { return exact }
        let lower = name.lowercased()
        if lower.contains("size") { return "smallcircle.filled.circle" }
        if lower.contains("count") { return "number" }
        if lower.contains("angle") { return "angle" }
        if lower.contains("width") || lower.contains("thick") { return "lineweight" }
        if lower.contains("shift") { return "arrow.left.arrow.right" }
        if lower.contains("noise") { return "aqi.medium" }
        if lower.contains("shape") { return "square.on.circle" }
        if lower.contains("soft") || lower.contains("blur") { return "drop" }
        if lower.contains("bright") { return "sun.max" }
        if lower.contains("scale") { return "plus.magnifyingglass" }
        return fallbackIcons[fallbackIndex % fallbackIcons.count]
    }

    static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                  options: .regularExpression).capitalized
    }

    /// The Adjust row as SECTIONS (mirrors the Mac inspector's grouping):
    /// Randomize alone, then Motion, the shader's effect params, and — for
    /// photo documents — Photo adjustments and the Ambient trio.
    static func adjustSections(model: EditorModel) -> [EditSection] {
        guard let schema = model.schema else { return [] }
        var sections: [EditSection] = []

        sections.append(EditSection(title: nil, controls: [EditControl(
            id: "randomize", title: "Random", systemImage: "wand.and.stars",
            kind: .action(run: {
                model.randomize()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }))]))

        var motion: [EditControl] = []
        let animated = model.editingVariant?.animated ?? false
        if schema.animated, animated,
           let speed = schema.params.first(where: { $0.name == "speed" }) {
            motion.append(paramControl(speed, model: model, icon: "speedometer"))
        }
        if schema.animated, !animated {
            // The Mac's Moment scrubber: pick the frame a still shows.
            motion.append(EditControl(
                id: "moment", title: "Moment", systemImage: "clock",
                kind: .slider(range: 0...60, step: 0.1, defaultValue: 0,
                              get: { (model.preview.params.frame) / 1000 },
                              set: { model.preview.params["frame"] = .number($0 * 1000) },
                              commit: {}),
                isModified: { model.preview.params.frame != 0 }))
        }
        if !motion.isEmpty { sections.append(EditSection(title: "Motion", controls: motion)) }

        var effect: [EditControl] = []
        var fallbackIndex = 0
        for param in schema.params {
            guard param.group != "sizing", param.name != "speed", param.name != "frame",
                  param.type != .image, param.type != .color, param.type != .colorArray
            else { continue }
            // The photo color mode (Original / B&W / Custom) owns this
            // bool from the Colors tab — Mac parity, not an Adjust knob.
            guard param.name != "originalColors" else { continue }
            let icon = icon(for: param.name, fallbackIndex: fallbackIndex)
            fallbackIndex += 1
            effect.append(paramControl(param, model: model, icon: icon))
        }
        if !effect.isEmpty { sections.append(EditSection(title: "Effect", controls: effect)) }

        if model.document?.kind == .imageBased {
            sections.append(EditSection(title: "Photo",
                                        controls: photoAdjustmentControls(model: model)))
            sections.append(EditSection(title: "Ambient",
                                        controls: ambientControls(model: model)))
        }
        return sections
    }

    private static func paramControl(_ param: ShaderSchema.Param, model: EditorModel,
                                     icon: String) -> EditControl {
        let name = param.name
        let defaultNumber = param.default?.doubleValue
        switch param.type {
        case .bool:
            return EditControl(
                id: name, title: displayName(name), systemImage: icon,
                kind: .toggle(
                    get: {
                        if case .bool(let b)? = model.preview.params[name] { return b }
                        return false
                    },
                    set: { model.preview.params[name] = .bool($0) }),
                isModified: {
                    if case .bool(let b)? = model.preview.params[name] {
                        return b != (param.default?.boolValue ?? false)
                    }
                    return false
                })
        case .enumeration:
            return EditControl(
                id: name, title: displayName(name), systemImage: icon,
                kind: .options(
                    all: param.options ?? [],
                    get: {
                        if case .choice(let c)? = model.preview.params[name] { return c }
                        return param.options?.first ?? ""
                    },
                    set: { model.preview.params[name] = .choice($0) }),
                isModified: {
                    if case .choice(let c)? = model.preview.params[name] {
                        return c != param.default?.stringValue
                    }
                    return false
                })
        default:
            return EditControl(
                id: name, title: displayName(name), systemImage: icon,
                kind: .slider(
                    range: (param.min ?? 0)...(param.max ?? 1),
                    step: param.step, defaultValue: defaultNumber,
                    get: {
                        if case .number(let v)? = model.preview.params[name] { return v }
                        return defaultNumber ?? 0
                    },
                    set: { model.preview.params[name] = .number($0) },
                    commit: {}),
                isModified: {
                    if case .number(let v)? = model.preview.params[name],
                       let defaultNumber {
                        return abs(v - defaultNumber) > 0.0001
                    }
                    return false
                })
        }
    }

    /// Photo adjustments write to a DRAFT while scrubbing; the full-res
    /// Core Image pass runs once on commit (ruler release).
    private static func photoAdjustmentControls(model: EditorModel) -> [EditControl] {
        func slider(_ id: String, _ title: String, _ icon: String,
                    _ keyPath: WritableKeyPath<WallpaperDocument.ImageAdjustments, Double>,
                    _ range: ClosedRange<Double>, _ defaultValue: Double) -> EditControl {
            EditControl(
                id: id, title: title, systemImage: icon,
                kind: .slider(range: range, step: 0.01, defaultValue: defaultValue,
                              get: { (model.draftAdjustments ?? model.currentAdjustments)[keyPath: keyPath] },
                              set: { value in
                                  var next = model.draftAdjustments ?? model.currentAdjustments
                                  next[keyPath: keyPath] = value
                                  model.draftAdjustments = next
                              },
                              commit: { model.commitDraftAdjustments() }),
                isModified: { abs(model.currentAdjustments[keyPath: keyPath] - defaultValue) > 0.0001 })
        }
        return [
            slider("adj.brightness", "Brightness", "sun.max", \.brightness, -0.5...0.5, 0),
            slider("adj.contrast", "Contrast", "circle.lefthalf.filled", \.contrast, 0.5...1.5, 1),
            slider("adj.saturation", "Saturation", "rainbow", \.saturation, 0...2, 1),
            slider("adj.warmth", "Warmth", "thermometer.medium", \.warmth, -1...1, 0),
            slider("adj.blur", "Soften", "drop", \.blur, 0...1, 0),
            EditControl(
                id: "adj.bw", title: "B&W", systemImage: "circle.bottomhalf.filled",
                kind: .toggle(
                    get: { model.currentAdjustments.blackAndWhite },
                    set: { value in
                        var next = model.currentAdjustments
                        next.blackAndWhite = value
                        model.setAdjustments(next)
                    }),
                isModified: { model.currentAdjustments.blackAndWhite }),
        ]
    }

    /// Ambient sliders scrub a DRAFT (preview-only, halo recompute
    /// coalesced downstream); the save + undo land once, on release —
    /// the same shape as the photo-adjustment sliders.
    private static func ambientControls(model: EditorModel) -> [EditControl] {
        func slider(_ id: String, _ title: String, _ icon: String,
                    _ keyPath: WritableKeyPath<AmbientSettings, Double>) -> EditControl {
            EditControl(
                id: id, title: title, systemImage: icon,
                kind: .slider(range: 0...1, step: 0.01,
                              defaultValue: AmbientSettings.automatic[keyPath: keyPath],
                              get: { (model.draftAmbient ?? model.currentAmbient)[keyPath: keyPath] },
                              set: { value in
                                  var next = model.draftAmbient ?? model.currentAmbient
                                  next[keyPath: keyPath] = value
                                  model.draftAmbient = next
                              },
                              commit: { model.commitDraftAmbient() }),
                isModified: {
                    abs(model.currentAmbient[keyPath: keyPath]
                        - AmbientSettings.automatic[keyPath: keyPath]) > 0.0001
                })
        }
        // Toggle + shape commit straight through setAmbient (single undo
        // step each, like B&W); any live scrub draft is committed first so
        // it can't be lost or resurrect stale knobs.
        let enabledToggle = EditControl(
            id: "amb.enabled", title: "Ambient", systemImage: "light.max",
            kind: .toggle(
                get: { model.currentAmbient.enabled },
                set: { value in
                    model.commitDraftAmbient()
                    var next = model.currentAmbient
                    next.enabled = value
                    model.setAmbient(next)
                }),
            isModified: { !model.currentAmbient.enabled })
        let shapeNames: [(AmbientSettings.MaskShape, String)] = [
            (.rectangle, "Rectangle"), (.roundedRectangle, "Rounded"),
            (.ellipse, "Ellipse"), (.circle, "Circle"),
        ]
        let shapePicker = EditControl(
            id: "amb.shape", title: "Shape", systemImage: "square.on.circle",
            kind: .options(
                all: shapeNames.map(\.1),
                get: {
                    shapeNames.first { $0.0 == model.currentAmbient.maskShape }?.1 ?? "Rectangle"
                },
                set: { name in
                    guard let shape = shapeNames.first(where: { $0.1 == name })?.0 else { return }
                    model.commitDraftAmbient()
                    var next = model.currentAmbient
                    next.maskShape = shape
                    model.setAmbient(next)
                }),
            isModified: { model.currentAmbient.maskShape != .rectangle })
        return [
            enabledToggle,
            slider("amb.softness", "Edge Soft", "square.inset.filled",
                   \.edgeSoftness),
            slider("amb.blur", "Backdrop", "aqi.medium", \.backdropBlur),
            slider("amb.brightness", "Ambience", "sun.min", \.backdropBrightness),
            shapePicker,
        ]
    }
}

/// A horizontal control row that CENTERS its content while it fits the
/// screen and turns into a leading-anchored scroller once it overflows —
/// the batch-wide row rule (presets, palettes, color wells, option pills).
struct CenteredScrollRow<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) { content() }
                .padding(.horizontal, 16)
                .frame(minWidth: UIScreen.main.bounds.width)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The Photos Adjust layout: ruler on top of the tab bar, circle row above
/// it, the selected circle drives what the ruler edits. Sections read as
/// one band with small labeled dividers between them (Mac's grouping).
struct AdjustControlsRow: View {
    @ObservedObject var model: EditorModel
    let sections: [EditSection]
    /// Bubbles the ruler's drag state up (the auto-fullscreen hook).
    var onScrubbing: ((Bool) -> Void)? = nil
    @State private var selectedID: String?
    /// The carousel's centered item (drives selection; markers and
    /// non-selectable circles can pass through the center unselected).
    @State private var centeredID: String?
    /// Index (in rowEntries) of the last CONTROL that held the center —
    /// gives the marker hop its direction.
    @State private var lastControlIndex: Int?

    /// The circle row flattened: controls interleaved with the section
    /// markers, every entry identified so the snap can rest on (and be
    /// nudged off) any of them.
    private enum RowEntry: Identifiable {
        case control(EditControl)
        case marker(Int, String?)
        var id: String {
            switch self {
            case .control(let control): return control.id
            case .marker(let index, _): return "marker-\(index)"
            }
        }
    }

    private var rowEntries: [RowEntry] {
        var out: [RowEntry] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { out.append(.marker(index, section.title)) }
            out.append(contentsOf: section.controls.map(RowEntry.control))
        }
        return out
    }

    private var controls: [EditControl] { sections.flatMap(\.controls) }

    private var selected: EditControl? {
        controls.first { $0.id == (selectedID ?? firstAdjustableID) }
    }

    private var firstAdjustableID: String? {
        controls.first {
            if case .slider = $0.kind { return true }
            if case .options = $0.kind { return true }
            return false
        }?.id
    }

    var body: some View {
        VStack(spacing: 6) {
            // Photos' Adjust carousel: the row snaps circle-to-center; the
            // CENTERED circle is the active one and the ruler below always
            // edits it. Scrolling ticks through them one by one; a tap
            // scrolls that circle into the center.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(rowEntries) { entry in
                        switch entry {
                        case .marker(_, let title):
                            SectionMarker(title: title)
                                .id(entry.id)
                        case .control(let control):
                            ControlCircle(
                                title: control.title,
                                systemImage: circleIcon(control),
                                isSelected: control.id == selected?.id && isSelectable(control),
                                isModified: control.isModified(),
                                action: { activate(control) })
                            .id(entry.id)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal,
                            max(0, UIScreen.main.bounds.width / 2 - 31),
                            for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredID, anchor: .center)
            .modifier(ScrollIdleObserver(onIdle: settleOffMarker))
            .onChange(of: centeredID) { _, id in
                guard let id,
                      let index = rowEntries.firstIndex(where: { $0.id == id }),
                      case .control(let control) = rowEntries[index] else { return }
                lastControlIndex = index
                // A selectable circle landing in the center becomes the
                // active control, with a picker-style tick.
                guard isSelectable(control), selectedID != id else { return }
                withAnimation(.easeInOut(duration: 0.12)) { selectedID = id }
                UISelectionFeedbackGenerator().selectionChanged()
            }
            .onAppear {
                // Open centered on the first adjustable control, selected.
                if centeredID == nil {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { centeredID = firstAdjustableID }
                }
            }

            detail
                .frame(height: 58)
                .padding(.horizontal, 24)
        }
    }

    /// A section marker is never a resting place: when the scroll settles
    /// on one, hop to the first control in the travel direction (falling
    /// back to the other side at the row's ends).
    private func settleOffMarker() {
        guard let id = centeredID,
              let index = rowEntries.firstIndex(where: { $0.id == id }),
              case .marker = rowEntries[index] else { return }
        let direction = index >= (lastControlIndex ?? 0) ? 1 : -1
        for dir in [direction, -direction] {
            var j = index + dir
            while j >= 0, j < rowEntries.count {
                if case .control(let control) = rowEntries[j] {
                    withAnimation(.easeOut(duration: 0.2)) { centeredID = control.id }
                    return
                }
                j += dir
            }
        }
    }

    private func circleIcon(_ control: EditControl) -> String {
        if case .toggle(let get, _) = control.kind {
            return get() ? "checkmark.circle.fill" : control.systemImage
        }
        return control.systemImage
    }

    private func isSelectable(_ control: EditControl) -> Bool {
        switch control.kind {
        case .slider, .options: return true
        case .toggle, .action: return false
        }
    }

    private func activate(_ control: EditControl) {
        switch control.kind {
        case .action(let run):
            run()
        case .toggle(let get, let set):
            set(!get())
            UISelectionFeedbackGenerator().selectionChanged()
        case .slider, .options:
            // Tap = scroll it into the center; selection follows via the
            // centeredID observer.
            withAnimation(.easeInOut(duration: 0.2)) {
                centeredID = control.id
                selectedID = control.id
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            switch selected.kind {
            case .slider(let range, let step, let defaultValue, let get, let set, let commit):
                RulerSlider(
                    value: Binding(get: get, set: set),
                    range: range, step: step, defaultValue: defaultValue,
                    onCommit: commit, onScrubbing: onScrubbing)
            case .options(let all, let get, let set):
                OptionPillsRow(all: all, get: get, set: set)
            default:
                EmptyView()
            }
        }
    }
}

/// Fires when a scroll gesture fully settles (iOS 18 scroll phases; a
/// no-op before that — markers then simply stay non-selectable).
private struct ScrollIdleObserver: ViewModifier {
    let onIdle: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                if newPhase == .idle { onIdle() }
            }
        } else {
            content
        }
    }
}

/// The thin vertical section divider with its tiny label riding on top,
/// left-aligned to the line.
private struct SectionMarker: View {
    let title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title?.uppercased() ?? " ")
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(title == nil ? 0 : 0.4))
                .fixedSize()
            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 44)
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 10)
        .accessibilityHidden(true)
    }
}

/// Shared option pills (enums, ambient shape, photo color mode).
struct OptionPillsRow: View {
    let all: [String]
    let get: () -> String
    let set: (String) -> Void

    var body: some View {
        CenteredScrollRow(spacing: 8) {
            ForEach(all, id: \.self) { option in
                Button {
                    set(option)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    // "2x2"/"4x4" style options read wrong capitalized.
                    let selected = get() == option
                    Group {
                        // Glass keeps the pill readable over a fullscreen
                        // wallpaper; the selected one stays solid white.
                        if selected {
                            Text(option.first?.isNumber == true ? option : option.capitalized)
                                .font(.callout)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(.white))
                        } else {
                            Text(option.first?.isNumber == true ? option : option.capitalized)
                                .font(.callout)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .chromeGlass(in: Capsule())
                        }
                    }
                    .foregroundStyle(selected ? .black : .white)
                }
            }
        }
    }
}

/// The Frame tab (Photos' Crop analog): the CANVAS does the framing —
/// drag pans, pinch zooms, twist rotates — while Recenter/Fill/Fit ride
/// as circles. (The rotation ruler retired; the twist gesture owns it.)
struct FrameControlsRow: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 2) {
                ControlCircle(title: "Recenter", systemImage: "scope",
                              isSelected: false, action: {
                    model.preview.params["offsetX"] = .number(0)
                    model.preview.params["offsetY"] = .number(0)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                })
                ControlCircle(title: "Fill", systemImage: "arrow.up.left.and.arrow.down.right",
                              isSelected: fit == "cover", action: { setFit("cover") })
                ControlCircle(title: "Fit", systemImage: "arrow.down.right.and.arrow.up.left",
                              isSelected: fit == "contain", action: { setFit("contain") })
            }

            Text("Drag to pan · pinch to zoom · twist to rotate")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var fit: String {
        if case .choice(let f)? = model.preview.params["fit"] { return f }
        return "cover"
    }

    private func setFit(_ value: String) {
        model.preview.params["fit"] = .choice(value)
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// The Colors tab, Mac inspector rules ported: photo shaders with an
/// "original colors" uniform get the Original / B&W / Custom mode pills
/// (palette + wells only under Custom); array shaders get the palette
/// strip over one unified row of array wells + accent wells; fixed-color
/// shaders get an exact-count palette strip over their wells.
struct ColorControlsRow: View {
    @ObservedObject var model: EditorModel

    private var colorArrayParam: ShaderSchema.Param? {
        model.schema?.params.first { $0.type == .colorArray }
    }

    private var singleColorParams: [ShaderSchema.Param] {
        model.schema?.params.filter { $0.type == .color } ?? []
    }

    private var hasColorMode: Bool {
        model.schema?.params.contains { $0.name == "originalColors" } ?? false
    }

    var body: some View {
        VStack(spacing: 12) {
            if hasColorMode {
                OptionPillsRow(
                    all: PhotoColorMode.allCases.map(\.rawValue),
                    get: { currentMode.rawValue },
                    set: { name in
                        if let mode = PhotoColorMode(rawValue: name) { setMode(mode) }
                    })
                if currentMode == .custom {
                    paletteStrip(PaletteStore.matching(count: singleColorParams.count),
                                 isSelected: singlesMatch, apply: applyToSingles)
                    CenteredScrollRow(spacing: 14) {
                        ForEach(singleColorParams, id: \.name) { param in
                            singleWell(param)
                        }
                    }
                }
            } else if let param = colorArrayParam {
                paletteStrip(PaletteStore.matching(count: colors(param).count),
                             isSelected: { arrayMatches($0, param: param) },
                             apply: { applyToArray($0, param: param) })
                CenteredScrollRow(spacing: 12) {
                    arrayWells(param)
                    if !singleColorParams.isEmpty {
                        wellsDivider
                        ForEach(singleColorParams, id: \.name) { param in
                            singleWell(param)
                        }
                    }
                }
            } else if !singleColorParams.isEmpty {
                paletteStrip(PaletteStore.matching(count: singleColorParams.count),
                             isSelected: singlesMatch, apply: applyToSingles)
                CenteredScrollRow(spacing: 14) {
                    ForEach(singleColorParams, id: \.name) { param in
                        singleWell(param)
                    }
                }
            } else {
                Text("This shader has no color controls.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Photo color mode (Mac parity)

    /// Original / B&W / Custom. B&W maps to the document-level Black &
    /// White adjustment, so the choice travels with the photo; the color
    /// params are dead uniforms outside Custom, so they only show there.
    private enum PhotoColorMode: String, CaseIterable {
        case original = "Original"
        case blackAndWhite = "B&W"
        case custom = "Custom"
    }

    private var currentMode: PhotoColorMode {
        if case .bool(true)? = model.preview.params["originalColors"] {
            return model.currentAdjustments.blackAndWhite ? .blackAndWhite : .original
        }
        return .custom
    }

    private func setMode(_ mode: PhotoColorMode) {
        model.preview.params["originalColors"] = .bool(mode != .custom)
        let wantsBW = mode == .blackAndWhite
        if model.currentAdjustments.blackAndWhite != wantsBW {
            var next = model.currentAdjustments
            next.blackAndWhite = wantsBW
            model.setAdjustments(next)
        }
    }

    // MARK: - Palettes

    @ViewBuilder
    private func paletteStrip(_ palettes: [ColorPalette],
                              isSelected: @escaping (ColorPalette) -> Bool,
                              apply: @escaping (ColorPalette) -> Void) -> some View {
        if !palettes.isEmpty {
            CenteredScrollRow(spacing: 10) {
                ForEach(palettes) { palette in
                    Button {
                        apply(palette)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 0) {
                            ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, hex in
                                Rectangle().fill(Color(hex: hex))
                            }
                        }
                        .frame(width: 88, height: 26)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(
                            isSelected(palette) ? Color.yellow : .white.opacity(0.25),
                            lineWidth: isSelected(palette) ? 1.5 : 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(palette.name))
                }
            }
        }
    }

    private func applyToSingles(_ palette: ColorPalette) {
        for (index, param) in singleColorParams.enumerated()
        where index < palette.colors.count {
            model.preview.params[param.name] = .color(palette.colors[index])
        }
    }

    private func applyToArray(_ palette: ColorPalette, param: ShaderSchema.Param) {
        model.preview.params[param.name] = .colorArray(palette.colors)
    }

    private func singlesMatch(_ palette: ColorPalette) -> Bool {
        guard palette.colors.count == singleColorParams.count else { return false }
        return zip(singleColorParams, palette.colors).allSatisfy { param, hex in
            if case .color(let current)? = model.preview.params[param.name] {
                return current.lowercased() == hex.lowercased()
            }
            return false
        }
    }

    private func arrayMatches(_ palette: ColorPalette, param: ShaderSchema.Param) -> Bool {
        let current = colors(param)
        guard current.count == palette.colors.count else { return false }
        return zip(current, palette.colors).allSatisfy { $0.lowercased() == $1.lowercased() }
    }

    // MARK: - Wells

    private func colors(_ param: ShaderSchema.Param) -> [String] {
        if case .colorArray(let all)? = model.preview.params[param.name] { return all }
        return []
    }

    private var wellsDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func arrayWells(_ param: ShaderSchema.Param) -> some View {
        let all = colors(param)
        ForEach(Array(all.enumerated()), id: \.offset) { index, hex in
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex) },
                set: { newColor in
                    var next = all
                    next[index] = newColor.hexString
                    model.preview.params[param.name] = .colorArray(next)
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .contextMenu {
                if all.count > 1 {
                    Button(role: .destructive) {
                        var next = all
                        next.remove(at: index)
                        model.preview.params[param.name] = .colorArray(next)
                    } label: { Label("Remove Color", systemImage: "minus.circle") }
                }
            }
        }
        if all.count < (param.maxCount ?? 8) {
            Button {
                var next = all
                next.append(PaletteStore.randomColor())
                model.preview.params[param.name] = .colorArray(next)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 32, height: 32)
                    .chromeGlass(in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Add Color")
        }
    }

    private func singleWell(_ param: ShaderSchema.Param) -> some View {
        let hex: String = {
            if case .color(let value)? = model.preview.params[param.name] { return value }
            return "#000000"
        }()
        return VStack(spacing: 4) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex) },
                set: { model.preview.params[param.name] = .color($0.hexString) }
            ), supportsOpacity: false)
            .labelsHidden()
            Text(EditControls.displayName(param.name))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// The Shader tab — Photos' Styles row: preset pills (selected state in
/// the app yellow, centered while they fit) above a scrollable strip of
/// live tiles (image tiles from the USER'S photo).
struct ShaderStyleRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var tiles = StripTileStore.shared

    var body: some View {
        VStack(spacing: 8) {
            if let presets = model.schema?.presets, !presets.isEmpty {
                CenteredScrollRow(spacing: 8) {
                    ForEach(presets, id: \.name) { preset in
                        presetPill(preset)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(StripTileStore.orderedIds(for: model.document?.kind ?? .procedural),
                            id: \.self) { id in
                        tile(id)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func presetPill(_ preset: ShaderSchema.Preset) -> some View {
        let selected = presetMatches(preset)
        return Button {
            model.apply(preset: preset)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(preset.name)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.yellow : .white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .chromeGlass(in: Capsule())
                .overlay(Capsule().strokeBorder(
                    selected ? Color.yellow : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.name))
    }

    /// A preset is "selected" when every param it sets matches the current
    /// values (sizing skipped for photo documents, mirroring how presets
    /// APPLY — they never re-frame the photo).
    private func presetMatches(_ preset: ShaderSchema.Preset) -> Bool {
        guard let schema = model.schema else { return false }
        let skipSizing = model.document?.kind == .imageBased
        for (name, value) in preset.params {
            guard let param = schema.params.first(where: { $0.name == name }) else { continue }
            if skipSizing, param.group == "sizing" { continue }
            switch param.type {
            case .float, .motion:
                guard let want = value.doubleValue else { continue }
                guard case .number(let have)? = model.preview.params[name],
                      abs(have - want) < 0.001 else { return false }
            case .bool:
                guard let want = value.boolValue else { continue }
                guard case .bool(let have)? = model.preview.params[name],
                      have == want else { return false }
            case .enumeration:
                guard let want = value.stringValue else { continue }
                guard case .choice(let have)? = model.preview.params[name],
                      have == want else { return false }
            case .color:
                guard let want = value.stringValue else { continue }
                guard case .color(let have)? = model.preview.params[name],
                      have.lowercased() == want.lowercased() else { return false }
            case .colorArray:
                guard let want = value.stringArrayValue else { continue }
                guard case .colorArray(let have)? = model.preview.params[name],
                      have.count == want.count,
                      zip(have, want).allSatisfy({ $0.lowercased() == $1.lowercased() })
                else { return false }
            case .image:
                continue
            }
        }
        return true
    }

    private func tile(_ id: String) -> some View {
        let selected = model.document?.shaderId == id
        return Button {
            model.switchShader(to: id)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let cg = tiles.tile(for: id, model: model) {
                        Image(uiImage: UIImage(cgImage: cg))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.white.opacity(0.1))
                    }
                }
                .frame(width: 84, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? .white : .clear, lineWidth: 2))

                Text(StripTileStore.displayName(id))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
            }
            .frame(width: 92)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(StripTileStore.displayName(id)))
    }
}

// MARK: - Shared color helpers

extension Color {
    init(hex: String) {
        let rgba = shaderColor(fromHex: hex)
        self.init(.sRGB, red: Double(rgba.x), green: Double(rgba.y),
                  blue: Double(rgba.z), opacity: 1)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Int {
            guard v.isFinite else { return 0 }
            return Int((min(1, max(0, v)) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }
}
