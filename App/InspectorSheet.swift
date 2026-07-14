import ShaderCore
import SwiftUI
import WallshaderModel
import WallshaderPalettes

/// The parameter inspector as a bottom sheet (C1/C2). Section order and
/// semantics mirror the Mac inspector exactly: Motion (speed) → Presets →
/// Composition → Photo Adjustments → Ambient Backdrop → Colors → parameter
/// groups → Randomize/Reset footer.
struct InspectorSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let schema = model.schema {
                        if schema.animated, model.editingVariant?.animated == true {
                            motionSection(schema)
                        }
                        presetsSection(schema)
                        if model.document?.kind == .imageBased {
                            compositionSection
                            adjustmentsSection
                            ambientSection
                        }
                        colorSection(schema)
                        parameterSections(schema)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    // MARK: - Sections

    private func motionSection(_ schema: ShaderSchema) -> some View {
        section("Motion") {
            if let speed = schema.params.first(where: { $0.name == "speed" }) {
                paramSlider(speed)
            }
        }
    }

    private func presetsSection(_ schema: ShaderSchema) -> some View {
        section("Presets") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(schema.presets ?? [], id: \.name) { preset in
                        Button(preset.name) {
                            var params = model.preview.params
                            // Presets never re-frame the photo (Mac rule).
                            let keepSizing = model.document?.kind == .imageBased
                            for (name, value) in preset.params {
                                if keepSizing,
                                   schema.params.first(where: { $0.name == name })?.group == "sizing" {
                                    continue
                                }
                                if let paramValue = ShaderParams.value(from: value,
                                                                       for: name, in: schema) {
                                    params[name] = paramValue
                                }
                            }
                            model.preview.params = params
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var compositionSection: some View {
        section("Composition") {
            if let schema = model.schema {
                ForEach(schema.params.filter { $0.group == "sizing" && $0.type == .float },
                        id: \.name) { param in
                    if param.name == "rotation" {
                        centeredRotationSlider
                    } else {
                        paramSlider(param)
                    }
                }
            }
        }
    }

    /// The Mac's centered rotation control: 0–360 presented as −180…180.
    private var centeredRotationSlider: some View {
        TrackSlider(title: "Rotate", value: Binding(
            get: {
                var r = model.preview.params["rotation"].flatMap {
                    if case .number(let v) = $0 { return v } else { return nil }
                } ?? 0
                r = r.truncatingRemainder(dividingBy: 360)
                if r < 0 { r += 360 }
                return r > 180 ? r - 360 : r
            },
            set: { newValue in
                var p = newValue.truncatingRemainder(dividingBy: 360)
                if p < 0 { p += 360 }
                model.preview.params["rotation"] = .number(p)
            }
        ), range: -180...180, step: 1, defaultValue: 0)
    }

    private var adjustmentsSection: some View {
        section("Photo Adjustments") {
            adjustmentSlider("Brightness", \.brightness, -0.5...0.5, 0)
            adjustmentSlider("Contrast", \.contrast, 0.5...1.5, 1)
            adjustmentSlider("Saturation", \.saturation, 0...2, 1)
            adjustmentSlider("Warmth", \.warmth, -1...1, 0)
            adjustmentSlider("Blur", \.blur, 0...1, 0)
        }
    }

    @State private var draftAdjustments: WallpaperDocument.ImageAdjustments?

    private func adjustmentSlider(_ title: String,
                                  _ keyPath: WritableKeyPath<WallpaperDocument.ImageAdjustments, Double>,
                                  _ range: ClosedRange<Double>,
                                  _ defaultValue: Double) -> some View {
        TrackSlider(title: title, value: Binding(
            get: { (draftAdjustments ?? model.currentAdjustments)[keyPath: keyPath] },
            set: { newValue in
                var next = draftAdjustments ?? model.currentAdjustments
                next[keyPath: keyPath] = newValue
                draftAdjustments = next
            }
        ), range: range, step: 0.01, defaultValue: defaultValue, onCommit: {
            // Full-res Core Image pass on release, not per tick (C-series
            // decision: no proxy pipeline on iOS v1).
            if let draft = draftAdjustments {
                model.setAdjustments(draft)
                draftAdjustments = nil
            }
        })
    }

    private var ambientSection: some View {
        section("Ambient Backdrop") {
            ambientSlider("Edge Softness", \.edgeSoftness)
            ambientSlider("Backdrop Blur", \.backdropBlur)
            ambientSlider("Backdrop Brightness", \.backdropBrightness)
        }
    }

    private func ambientSlider(_ title: String,
                               _ keyPath: WritableKeyPath<AmbientSettings, Double>) -> some View {
        TrackSlider(title: title, value: Binding(
            get: { model.currentAmbient[keyPath: keyPath] },
            set: { newValue in
                var next = model.currentAmbient
                next[keyPath: keyPath] = newValue
                model.setAmbient(next)
            }
        ), range: 0...1, step: 0.01,
        defaultValue: AmbientSettings.automatic[keyPath: keyPath])
    }

    private func colorSection(_ schema: ShaderSchema) -> some View {
        let colorParams = schema.params.filter { $0.type == .color || $0.type == .colorArray }
        return Group {
            if !colorParams.isEmpty {
                section("Colors") {
                    // Curated palette rows — same swatch presentation and
                    // selection behavior as the Mac (C2).
                    if let arrayParam = colorParams.first(where: { $0.type == .colorArray }) {
                        paletteRows(arrayParam)
                        colorArrayEditor(arrayParam)
                    }
                    ForEach(colorParams.filter { $0.type == .color }, id: \.name) { param in
                        singleColorRow(param)
                    }
                }
            }
        }
    }

    private func currentColors(_ param: ShaderSchema.Param) -> [String] {
        if case .colorArray(let colors)? = model.preview.params[param.name] { return colors }
        return []
    }

    private func paletteRows(_ param: ShaderSchema.Param) -> some View {
        let count = currentColors(param).count
        let palettes = PaletteStore.matching(count: count)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(palettes) { palette in
                    Button {
                        model.preview.params[param.name] = .colorArray(palette.colors)
                    } label: {
                        HStack(spacing: 0) {
                            ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, hex in
                                Rectangle().fill(Color(hex: hex))
                            }
                        }
                        .frame(width: 84, height: 24)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(palette.name))
                }
            }
        }
    }

    private func colorArrayEditor(_ param: ShaderSchema.Param) -> some View {
        let colors = currentColors(param)
        return VStack(spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                HStack {
                    ColorPicker("Color \(index + 1)", selection: Binding(
                        get: { Color(hex: hex) },
                        set: { newColor in
                            var next = colors
                            next[index] = newColor.hexString
                            model.preview.params[param.name] = .colorArray(next)
                        }
                    ), supportsOpacity: false)
                    if colors.count > 1 {
                        Button {
                            var next = colors
                            next.remove(at: index)
                            model.preview.params[param.name] = .colorArray(next)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if colors.count < (param.maxCount ?? 8) {
                Button {
                    var next = colors
                    next.append(PaletteStore.randomColor())
                    model.preview.params[param.name] = .colorArray(next)
                } label: {
                    Label("Add Color", systemImage: "plus.circle")
                }
                .font(.callout)
            }
        }
    }

    private func singleColorRow(_ param: ShaderSchema.Param) -> some View {
        let hex: String = {
            if case .color(let value)? = model.preview.params[param.name] { return value }
            return "#000000"
        }()
        return ColorPicker(displayName(param), selection: Binding(
            get: { Color(hex: hex) },
            set: { model.preview.params[param.name] = .color($0.hexString) }
        ), supportsOpacity: false)
    }

    private func parameterSections(_ schema: ShaderSchema) -> some View {
        // Same grouping/order the schema declares (mirrors the Mac).
        let grouped = Dictionary(grouping: schema.params.filter { param in
            param.group != "sizing" && param.type != .image && param.type != .color
                && param.type != .colorArray && param.name != "speed" && param.name != "frame"
        }, by: { $0.group ?? "Parameters" })
        let order = schema.params.compactMap(\.group).uniqued()
        let keys = (order + ["Parameters"]).uniqued().filter { grouped[$0] != nil }
        return ForEach(keys, id: \.self) { group in
            section(group.capitalized) {
                ForEach(grouped[group] ?? [], id: \.name) { param in
                    paramControl(param)
                }
            }
        }
    }

    @ViewBuilder
    private func paramControl(_ param: ShaderSchema.Param) -> some View {
        switch param.type {
        case .float, .motion:
            paramSlider(param)
        case .bool:
            Toggle(displayName(param), isOn: Binding(
                get: {
                    if case .bool(let b)? = model.preview.params[param.name] { return b }
                    return false
                },
                set: { model.preview.params[param.name] = .bool($0) }
            ))
        case .enumeration:
            Picker(displayName(param), selection: Binding(
                get: {
                    if case .choice(let c)? = model.preview.params[param.name] { return c }
                    return param.options?.first ?? ""
                },
                set: { model.preview.params[param.name] = .choice($0) }
            )) {
                ForEach(param.options ?? [], id: \.self) { option in
                    Text(option.capitalized).tag(option)
                }
            }
            .pickerStyle(.menu)
        default:
            EmptyView()
        }
    }

    private func paramSlider(_ param: ShaderSchema.Param) -> some View {
        TrackSlider(title: displayName(param), value: Binding(
            get: {
                if case .number(let v)? = model.preview.params[param.name] { return v }
                return param.default?.doubleValue ?? 0
            },
            set: { model.preview.params[param.name] = .number($0) }
        ), range: (param.min ?? 0)...(param.max ?? 1),
           step: param.step,
           defaultValue: param.default?.doubleValue)
    }

    private func displayName(_ param: ShaderSchema.Param) -> String {
        param.name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                        options: .regularExpression)
            .capitalized
    }

    // MARK: - Footer (Randomize / Reset — Mac placement and semantics)

    private var footer: some View {
        HStack {
            Button {
                model.randomize()
            } label: {
                Label("Randomize", systemImage: "dice")
            }
            Spacer()
            Button("Reset") { model.resetToDefaults() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Helpers

extension ShaderParams {
    /// Converts a preset's JSONValue into the runtime value for a param.
    static func value(from json: JSONValue, for name: String,
                      in schema: ShaderSchema) -> ParamValue? {
        guard let param = schema.params.first(where: { $0.name == name }) else { return nil }
        switch param.type {
        case .float, .motion: return json.doubleValue.map { .number($0) }
        case .bool: return json.boolValue.map { .bool($0) }
        case .color: return json.stringValue.map { .color($0) }
        case .enumeration: return json.stringValue.map { .choice($0) }
        case .colorArray: return json.stringArrayValue.map { .colorArray($0) }
        case .image: return nil
        }
    }
}

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

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
