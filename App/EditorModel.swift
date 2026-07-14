import Combine
import CoreGraphics
import Photos
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// Editing state for one open document — the iOS counterpart of the Mac's
/// StudioModel, carrying over its deliberate semantics: debounced param
/// writeback with burst undo, per-variant routing (A4), auto→customized on
/// first edit, adjustments/ambient as document/variant state.
@MainActor
final class EditorModel: ObservableObject {
    let app: AppModel
    let documentID: UUID
    @Published private(set) var document: WallpaperDocument?
    @Published private(set) var selectedDevice: DeviceClass
    @Published var preview: PreviewModel
    @Published var applyError: String?
    @Published var justSaved = false

    weak var undoManager: UndoManager?
    private var cancellables: Set<AnyCancellable> = []
    private var suppressWriteback = false
    private var writebackDebounce: Task<Void, Never>?
    private var pendingWriteback: (device: DeviceClass, params: ShaderParams)?
    private var undoBurstActive = false
    private var undoBaseline: [String: JSONValue]?

    var library: WallpaperLibrary { app.library }

    init(app: AppModel, documentID: UUID) {
        self.app = app
        self.documentID = documentID
        let device = AppModel.currentDevice
        self.selectedDevice = device
        let doc = app.library.document(id: documentID)
        self.document = doc
        let schema = doc?.shaderId.flatMap { ShaderRegistry.shared.schema(for: $0) }
            ?? ShaderRegistry.shared.schema(for: ShaderRegistry.shared.orderedIds[0])!
        self.preview = PreviewModel(renderer: app.renderer,
                                    shaderId: doc?.shaderId ?? schema.id,
                                    params: ShaderParams(schema: schema),
                                    device: device)
        reloadEditor()

        preview.$params
            .dropFirst()
            .sink { [weak self] params in self?.scheduleWriteback(params: params) }
            .store(in: &cancellables)
        library.$documents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] docs in
                guard let self else { return }
                let fresh = docs.first { $0.id == self.documentID }
                if fresh != self.document { self.document = fresh }
            }
            .store(in: &cancellables)
    }

    var currentImageAspect: Double? {
        guard let texture = preview.texture, texture.height > 0 else { return nil }
        return Double(texture.width) / Double(texture.height)
    }

    var editingVariant: WallpaperVariant? {
        document?.resolvedVariant(for: selectedDevice, imageAspect: currentImageAspect)
    }

    var selectedVariantIsCustomized: Bool {
        document?.isCustomized(selectedDevice) ?? false
    }

    var schema: ShaderSchema? {
        document?.shaderId.flatMap { ShaderRegistry.shared.schema(for: $0) }
    }

    // MARK: - Loading

    func reloadEditor() {
        suppressWriteback = true
        defer { suppressWriteback = false }
        undoBurstActive = false
        document = library.document(id: documentID)
        guard let doc = document, let shaderId = doc.shaderId else {
            undoBaseline = nil
            return
        }
        if preview.shaderId != shaderId { preview.shaderId = shaderId }
        preview.texture = doc.needsSourceImage ? library.loadSourceTexture(for: doc) : nil
        let variant = doc.resolvedVariant(for: selectedDevice, imageAspect: currentImageAspect)
        if let params = doc.shaderParams(for: selectedDevice, imageAspect: currentImageAspect) {
            preview.params = params
        }
        preview.ambient = library.ambientSpec(for: doc, settings: variant.ambient)
        preview.emulatedPixels = PreviewModel.target(for: selectedDevice)
        preview.isPlaying = doc.shaderIsAnimatable && variant.animated
        preview.resetClock(frameMs: variant.params["frame"]?.doubleValue ?? 0)
        undoBaseline = variant.params
    }

    func selectDevice(_ device: DeviceClass) {
        guard device != selectedDevice else { return }
        flushPendingWriteback()
        selectedDevice = device
        reloadEditor()
    }

    // MARK: - Param writeback (burst undo, debounced persist — Mac semantics)

    private func scheduleWriteback(params: ShaderParams) {
        guard !suppressWriteback, document?.shaderId != nil else { return }
        if !undoBurstActive {
            undoBurstActive = true
            registerParamUndo(baseline: undoBaseline, device: selectedDevice)
        }
        pendingWriteback = (selectedDevice, params)
        writebackDebounce?.cancel()
        writebackDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushPendingWriteback()
        }
    }

    func flushPendingWriteback() {
        writebackDebounce?.cancel()
        writebackDebounce = nil
        undoBurstActive = false
        guard let pending = pendingWriteback else { return }
        pendingWriteback = nil
        guard var fresh = library.document(id: documentID), fresh.shaderId != nil else { return }
        var json: [String: JSONValue] = [:]
        for param in pending.params.schema.params {
            if let value = pending.params.values[param.name] { json[param.name] = JSONValue(value) }
        }
        if pending.device == .desktop {
            guard json != fresh.params else { return }
            fresh.params = json
        } else {
            var variant = fresh.resolvedVariant(for: pending.device, imageAspect: currentImageAspect)
            guard json != variant.params else { return }
            variant.params = json
            fresh.setVariant(variant, for: pending.device)
        }
        library.save(fresh)
        undoBaseline = json
        document = library.document(id: documentID)
    }

    private func registerParamUndo(baseline: [String: JSONValue]?, device: DeviceClass) {
        guard let baseline, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.applyParamState(baseline, device: device)
        }
        undoManager.setActionName("Edit Parameters")
    }

    private func applyParamState(_ params: [String: JSONValue], device: DeviceClass) {
        flushPendingWriteback()
        guard var fresh = library.document(id: documentID) else { return }
        let current = device == .desktop
            ? fresh.params
            : fresh.resolvedVariant(for: device, imageAspect: currentImageAspect).params
        undoManager?.registerUndo(withTarget: self) { model in
            model.applyParamState(current, device: device)
        }
        if device == .desktop {
            fresh.params = params
        } else {
            var variant = fresh.resolvedVariant(for: device, imageAspect: currentImageAspect)
            variant.params = params
            fresh.setVariant(variant, for: device)
        }
        library.save(fresh)
        if selectedDevice != device { selectedDevice = device }
        reloadEditor()
    }

    // MARK: - Shader switch / motion / variants (Mac semantics)

    func switchShader(to shaderId: String) {
        flushPendingWriteback()
        guard let doc = library.document(id: documentID), let old = doc.shaderId else {
            _ = library.switchShader(of: documentID, to: shaderId)
            reloadEditor()
            return
        }
        let previousParams = doc.params
        let previousVariants = doc.variants
        let previousAnimated = doc.animated
        _ = library.switchShader(of: documentID, to: shaderId)
        undoManager?.registerUndo(withTarget: self) { model in
            guard var fresh = model.library.document(id: model.documentID) else { return }
            let redoShader = fresh.shaderId
            let redoParams = fresh.params
            model.undoManager?.registerUndo(withTarget: model) { m in
                if let redoShader { _ = m.library.switchShader(of: m.documentID, to: redoShader) }
                if var f = m.library.document(id: m.documentID) { f.params = redoParams; m.library.save(f) }
                m.reloadEditor()
            }
            fresh.shaderId = old
            fresh.params = previousParams
            fresh.variants = previousVariants
            fresh.animated = previousAnimated
            model.library.save(fresh)
            model.reloadEditor()
        }
        undoManager?.setActionName("Switch Shader")
        reloadEditor()
    }

    func setAnimated(_ animated: Bool) {
        guard var fresh = library.document(id: documentID), fresh.shaderIsAnimatable else {
            preview.isPlaying = false
            return
        }
        if selectedDevice == .desktop {
            fresh.animated = animated
        } else {
            var variant = fresh.resolvedVariant(for: selectedDevice, imageAspect: currentImageAspect)
            variant.animated = animated
            fresh.setVariant(variant, for: selectedDevice)
        }
        library.save(fresh, regenerateThumbnail: false)
        document = library.document(id: documentID)
        if !animated {
            // Freeze at the frame the user is looking at (Mac semantics).
            let frameMs = Double(preview.lastRenderedTimeSeconds) * 1000
            if preview.params.frame != frameMs {
                preview.params["frame"] = .number(frameMs)
            }
        } else {
            preview.resetClock(frameMs: preview.params.frame)
        }
        preview.isPlaying = animated
    }

    func revertVariantToAutomatic() {
        guard selectedDevice != .desktop,
              var fresh = library.document(id: documentID),
              let stored = fresh.variants?[selectedDevice.rawValue] else { return }
        flushPendingWriteback()
        let device = selectedDevice
        undoManager?.registerUndo(withTarget: self) { model in
            guard var f = model.library.document(id: model.documentID) else { return }
            model.undoManager?.registerUndo(withTarget: model) { m in
                m.revertVariantToAutomatic()
            }
            f.setVariant(stored, for: device)
            model.library.save(f)
            model.reloadEditor()
        }
        undoManager?.setActionName("Revert to Automatic")
        fresh.revertVariantToAutomatic(device)
        library.save(fresh)
        reloadEditor()
    }

    // MARK: - Adjustments & ambient (variant-aware, commit-per-change)

    var currentAdjustments: WallpaperDocument.ImageAdjustments {
        document?.adjustments ?? .neutral
    }

    /// Scrub-time adjustments draft (Photos-style ruler): the full-res
    /// Core Image pass runs once, on commit — never per tick.
    @Published var draftAdjustments: WallpaperDocument.ImageAdjustments?

    func commitDraftAdjustments() {
        guard let draft = draftAdjustments else { return }
        draftAdjustments = nil
        setAdjustments(draft)
    }

    /// Applies an upstream preset (Mac rule: presets never re-frame the
    /// photo — sizing params are skipped for image documents).
    func apply(preset: ShaderSchema.Preset) {
        guard let schema else { return }
        var params = preview.params
        let keepSizing = document?.kind == .imageBased
        for (name, value) in preset.params {
            guard let param = schema.params.first(where: { $0.name == name }) else { continue }
            if keepSizing, param.group == "sizing" { continue }
            switch param.type {
            case .float, .motion:
                if let v = value.doubleValue { params[name] = .number(v) }
            case .bool:
                if let v = value.boolValue { params[name] = .bool(v) }
            case .color:
                if let v = value.stringValue { params[name] = .color(v) }
            case .enumeration:
                if let v = value.stringValue { params[name] = .choice(v) }
            case .colorArray:
                if let v = value.stringArrayValue { params[name] = .colorArray(v) }
            case .image:
                break
            }
        }
        preview.params = params
    }

    /// iOS applies adjustments per commit (slider release), full-res on a
    /// background task — no proxy pipeline (logged decision).
    func setAdjustments(_ new: WallpaperDocument.ImageAdjustments) {
        guard var fresh = library.document(id: documentID), fresh.sourceImage != nil else { return }
        let previous = fresh.adjustments ?? .neutral
        undoManager?.registerUndo(withTarget: self) { model in
            model.setAdjustments(previous)
        }
        undoManager?.setActionName("Adjust Photo")
        fresh.adjustments = new.isNeutral ? nil : new
        library.save(fresh)
        document = library.document(id: documentID)
        refreshAdjustedTexture()
    }

    private var textureGen = 0
    private func refreshAdjustedTexture() {
        guard let doc = document, let url = library.sourceImageURL(for: doc) else { return }
        textureGen += 1
        let gen = textureGen
        let adjustments = doc.adjustments
        Task { @MainActor [weak self] in
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let a = adjustments, !a.isNeutral else { return nil }
                return WallpaperLibrary.adjustedImage(at: url, adjustments: a)
            }.value
            guard let self, gen == self.textureGen else { return }
            if let cg, let texture = self.library.makeTexture(from: cg) {
                self.preview.texture = texture
            } else if cg == nil, let doc = self.document {
                self.preview.texture = self.library.loadSourceTexture(for: doc)
            }
            if let doc = self.document {
                self.preview.ambient = self.library.ambientSpec(
                    for: doc, settings: self.editingVariant?.ambient)
            }
        }
    }

    var currentAmbient: AmbientSettings {
        editingVariant?.ambient ?? .automatic
    }

    func setAmbient(_ new: AmbientSettings) {
        guard var fresh = library.document(id: documentID), fresh.sourceImage != nil else { return }
        let device = selectedDevice
        let previous = fresh.resolvedVariant(for: device, imageAspect: currentImageAspect).ambient ?? .automatic
        undoManager?.registerUndo(withTarget: self) { model in
            model.setAmbient(previous)
        }
        undoManager?.setActionName("Adjust Ambient Backdrop")
        if device == .desktop {
            fresh.ambient = new.isAutomatic ? nil : new
        } else {
            var variant = fresh.resolvedVariant(for: device, imageAspect: currentImageAspect)
            variant.ambient = new.isAutomatic ? nil : new
            fresh.setVariant(variant, for: device)
        }
        library.save(fresh)
        document = library.document(id: documentID)
        preview.ambient = library.ambientSpec(for: fresh, settings: new)
    }

    // MARK: - Randomize / reset (Mac semantics: effect params only)

    func randomize() {
        var params = preview.params
        for p in params.schema.params {
            guard p.group != "sizing", p.name != "speed", p.name != "frame",
                  p.type != .image else { continue }
            switch p.type {
            case .float, .motion:
                if let min = p.min, let max = p.max {
                    params[p.name] = .number(Double.random(in: min...max))
                }
            case .bool:
                params[p.name] = .bool(Bool.random())
            case .enumeration:
                if let options = p.options, let pick = options.randomElement() {
                    params[p.name] = .choice(pick)
                }
            case .color:
                params[p.name] = .color(WallshaderPalettesRandomColor())
            case .colorArray:
                if case .colorArray(let current)? = params[p.name] {
                    params[p.name] = .colorArray(WallshaderPalettesRandom(maxCount: max(1, current.count)))
                }
            case .image:
                break
            }
        }
        preview.params = params
    }

    func resetToDefaults() {
        guard let schema else { return }
        var params = ShaderParams(schema: schema)
        if document?.kind == .imageBased {
            // Keep the user's framing (composition is per document — §4.3).
            for p in schema.params where p.group == "sizing" {
                if let kept = preview.params[p.name] { params[p.name] = kept }
            }
        }
        params["frame"] = preview.params["frame"] ?? params["frame"]
        preview.params = params
    }

    // MARK: - Photo import

    func importImage(url: URL, attribution: WallpaperDocument.Attribution? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let prepared = try? await Task.detached(priority: .userInitiated) {
                try WallpaperLibrary.prepareSourceImport(from: url)
            }.value
            guard let prepared else { return }
            _ = try? self.library.adoptPreparedSourceImage(prepared, into: self.documentID,
                                                           attribution: attribution)
            self.reloadEditor()
        }
    }
}

// Small indirections so EditorModel stays import-light in this file.
import WallshaderPalettes
private func WallshaderPalettesRandomColor() -> String { PaletteStore.randomColor() }
private func WallshaderPalettesRandom(maxCount: Int) -> [String] { PaletteStore.random(maxCount: maxCount) }
