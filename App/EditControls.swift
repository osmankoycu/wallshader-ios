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

@MainActor
enum EditControls {
    /// Abstract dial icons cycled over schema params that have no obvious
    /// glyph of their own.
    private static let paramIcons = [
        "dial.low", "circle.grid.2x2", "waveform.path", "aqi.medium",
        "camera.filters", "square.stack.3d.forward.dottedline", "sparkles",
        "circle.hexagongrid", "rays", "seal",
    ]

    static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                  options: .regularExpression).capitalized
    }

    /// The Adjust row: Randomize first (Photos' auto-wand slot), motion,
    /// then every effect param, then — for photo documents — the photo
    /// adjustments and the ambient trio, one long scrollable row.
    static func adjustControls(model: EditorModel) -> [EditControl] {
        var controls: [EditControl] = []
        guard let schema = model.schema else { return controls }

        controls.append(EditControl(
            id: "randomize", title: "Random", systemImage: "wand.and.stars",
            kind: .action(run: {
                model.randomize()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            })))

        let animated = model.editingVariant?.animated ?? false
        if schema.animated, animated,
           let speed = schema.params.first(where: { $0.name == "speed" }) {
            controls.append(paramControl(speed, model: model, icon: "speedometer"))
        }
        if schema.animated, !animated {
            // The Mac's Moment scrubber: pick the frame a still shows.
            controls.append(EditControl(
                id: "moment", title: "Moment", systemImage: "clock",
                kind: .slider(range: 0...60, step: 0.1, defaultValue: 0,
                              get: { (model.preview.params.frame) / 1000 },
                              set: { model.preview.params["frame"] = .number($0 * 1000) },
                              commit: {}),
                isModified: { model.preview.params.frame != 0 }))
        }

        var iconIndex = 0
        for param in schema.params {
            guard param.group != "sizing", param.name != "speed", param.name != "frame",
                  param.type != .image, param.type != .color, param.type != .colorArray
            else { continue }
            let icon = paramIcons[iconIndex % paramIcons.count]
            iconIndex += 1
            controls.append(paramControl(param, model: model, icon: icon))
        }

        if model.document?.kind == .imageBased {
            controls.append(contentsOf: photoAdjustmentControls(model: model))
            controls.append(contentsOf: ambientControls(model: model))
        }
        return controls
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
            slider("adj.saturation", "Saturation", "drop.halffull", \.saturation, 0...2, 1),
            slider("adj.warmth", "Warmth", "thermometer.medium", \.warmth, -1...1, 0),
            slider("adj.blur", "Soften", "drop", \.blur, 0...1, 0),
            EditControl(
                id: "adj.bw", title: "B&W", systemImage: "circle.dotted",
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
            id: "amb.enabled", title: "Ambient", systemImage: "circle.lefthalf.striped.horizontal",
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
            id: "amb.shape", title: "Shape", systemImage: "squareshape.dashed.squareshape",
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
            slider("amb.softness", "Edge Soft", "square.on.square.squareshape.controlhandles",
                   \.edgeSoftness),
            slider("amb.blur", "Backdrop", "aqi.medium", \.backdropBlur),
            slider("amb.brightness", "Ambience", "sun.min", \.backdropBrightness),
            shapePicker,
        ]
    }
}

/// The Photos Adjust layout: ruler on top of the tab bar, circle row above
/// it, the selected circle drives what the ruler edits.
struct AdjustControlsRow: View {
    @ObservedObject var model: EditorModel
    let controls: [EditControl]
    @State private var selectedID: String?

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
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(controls) { control in
                        ControlCircle(
                            title: control.title,
                            systemImage: circleIcon(control),
                            isSelected: control.id == selected?.id && isSelectable(control),
                            isModified: control.isModified(),
                            action: { activate(control) })
                    }
                }
                .padding(.horizontal, 16)
            }

            detail
                .frame(height: 62)
                .padding(.horizontal, 24)
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
            withAnimation(.easeInOut(duration: 0.12)) { selectedID = control.id }
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
                    onCommit: commit)
            case .options(let all, let get, let set):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(all, id: \.self) { option in
                            Button {
                                set(option)
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                Text(option.capitalized)
                                    .font(.callout)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(
                                        get() == option ? .white : .white.opacity(0.12)))
                                    .foregroundStyle(get() == option ? .black : .white)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// The Frame tab (Photos' Crop analog): gestures on the canvas do the
/// framing; the ruler is the straighten dial (Rotate); Fit and Recenter
/// ride as circles.
struct FrameControlsRow: View {
    @ObservedObject var model: EditorModel

    private var rotationDisplay: Double {
        var r = 0.0
        if case .number(let v)? = model.preview.params["rotation"] { r = v }
        r = r.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r > 180 ? r - 360 : r
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                ControlCircle(title: "Recenter", systemImage: "arrow.counterclockwise",
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

            VStack(spacing: 2) {
                RulerSlider(
                    value: Binding(
                        get: { rotationDisplay },
                        set: { newValue in
                            var p = newValue.truncatingRemainder(dividingBy: 360)
                            if p < 0 { p += 360 }
                            model.preview.params["rotation"] = .number(p)
                        }),
                    range: -180...180, step: 1, defaultValue: 0)
                Text("Drag to pan · pinch to zoom · twist to rotate")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 24)
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

/// The Colors tab: curated palette capsules (the Mac rows, C2) above the
/// document's color wells.
struct ColorControlsRow: View {
    @ObservedObject var model: EditorModel

    private var colorArrayParam: ShaderSchema.Param? {
        model.schema?.params.first { $0.type == .colorArray }
    }

    private var singleColorParams: [ShaderSchema.Param] {
        model.schema?.params.filter { $0.type == .color } ?? []
    }

    var body: some View {
        VStack(spacing: 12) {
            if let param = colorArrayParam {
                paletteRow(param)
                wellsRow(param)
            }
            if !singleColorParams.isEmpty {
                HStack(spacing: 14) {
                    ForEach(singleColorParams, id: \.name) { param in
                        singleWell(param)
                    }
                }
            }
            if colorArrayParam == nil && singleColorParams.isEmpty {
                Text("This shader has no color controls.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.vertical, 4)
    }

    private func colors(_ param: ShaderSchema.Param) -> [String] {
        if case .colorArray(let all)? = model.preview.params[param.name] { return all }
        return []
    }

    private func paletteRow(_ param: ShaderSchema.Param) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PaletteStore.matching(count: colors(param).count)) { palette in
                    Button {
                        model.preview.params[param.name] = .colorArray(palette.colors)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 0) {
                            ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, hex in
                                Rectangle().fill(Color(hex: hex))
                            }
                        }
                        .frame(width: 88, height: 26)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(palette.name))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func wellsRow(_ param: ShaderSchema.Param) -> some View {
        let all = colors(param)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
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
                            .background(Circle().fill(.white.opacity(0.12)))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Add Color")
                }
            }
            .padding(.horizontal, 16)
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

/// The Shader tab — Photos' Styles row: the selected shader's name in caps
/// above a scrollable strip of live tiles (image tiles from the USER'S
/// photo), plus its preset pills.
struct ShaderStyleRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var tiles = StripTileStore.shared

    var body: some View {
        VStack(spacing: 8) {
            if let presets = model.schema?.presets, !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.name) { preset in
                            Button(preset.name) { model.apply(preset: preset) }
                                .font(.footnote)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(.white.opacity(0.12)))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16)
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
        func clamp(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }
}
