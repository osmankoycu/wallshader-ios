import Photos
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// The Save action (C5 + hardware feedback #1/#2): a single prominent
/// button. Animated on → tapping ASKS still-or-live in a confirmation
/// dialog; otherwise saves the still directly. Non-current-device
/// variants export via the Appendix-A preset menu instead.
struct SaveWallpaperButton: View {
    @ObservedObject var model: EditorModel
    @Binding var showingGuide: Bool
    @Binding var saveError: String?
    @State private var choosing = false
    @State private var saving = false
    @State private var shareURL: URL?
    @State private var pendingPreset: StudioExportPreset?

    private var isCurrentDevice: Bool {
        model.selectedDevice == AppModel.currentDevice
    }

    private var canExportLive: Bool {
        LivePhotoExporter.canExportLive(model: model)
    }

    var body: some View {
        Group {
            if isCurrentDevice {
                Button {
                    if canExportLive {
                        choosing = true // still or live — the user decides
                    } else {
                        saveStill()
                    }
                } label: {
                    Group {
                        if saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(saving || !(model.document?.isAppliable ?? false))
                .accessibilityLabel("Save Wallpaper")
            } else {
                Menu {
                    ForEach(StudioExportPreset.presets(for: model.selectedDevice)) { preset in
                        Button("\(preset.name) — \(preset.width)×\(preset.height)") {
                            pendingPreset = preset
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!(model.document?.isAppliable ?? false))
                .accessibilityLabel("Export")
                .task(id: pendingPreset?.id) {
                    guard let preset = pendingPreset else { return }
                    shareURL = await Self.renderTemporaryPNG(
                        model: model,
                        pixels: CGSize(width: preset.width, height: preset.height))
                    pendingPreset = nil
                }
            }
        }
        .confirmationDialog("Save Wallpaper", isPresented: $choosing,
                            titleVisibility: .visible) {
            Button("Save Live Photo") { saveLive() }
            Button("Save Still Photo") { saveStill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Live Photos animate on the Lock Screen when you wake your \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").")
        }
        .sharePopover(item: $shareURL)
    }

    // MARK: - Rendering

    /// The device's wallpaper pixels. `nativeBounds` is ALWAYS
    /// portrait-oriented; iPad runs (and papers) landscape-only, so the
    /// long edge goes horizontal there.
    static var screenWallpaperPixels: CGSize {
        let native = UIScreen.main.nativeBounds.size
        guard UIDevice.current.userInterfaceIdiom == .pad else { return native }
        return CGSize(width: max(native.width, native.height),
                      height: min(native.width, native.height))
    }

    /// Sendable box for the detached render: the full-resolution render
    /// plus PNG encode froze the whole UI on main for seconds on older
    /// hardware — including the very spinner meant to indicate it.
    private struct RenderBox: @unchecked Sendable {
        let offscreen: OffscreenRenderer
        let texture: MTLTexture?
        init(renderer: ShaderRenderer, texture: MTLTexture?) {
            offscreen = OffscreenRenderer(renderer: renderer)
            self.texture = texture
        }
    }

    /// Gathers everything on the main actor, renders detached.
    static func renderImage(model: EditorModel, pixels: CGSize) async -> CGImage? {
        guard let renderer = model.app.renderer,
              let doc = model.document, let shaderId = doc.shaderId else { return nil }
        model.flushPendingWriteback()
        let params = model.preview.params
        if doc.needsSourceImage && model.preview.texture == nil { return nil }
        let time = model.preview.isPlaying
            ? model.preview.lastRenderedTimeSeconds
            : Float(params.frame * 0.001)
        let box = RenderBox(renderer: renderer, texture: model.preview.texture)
        let ambient = model.preview.ambient
        let scale = Float(UIScreen.main.scale)
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            try? box.offscreen.renderImage(
                shaderId: shaderId, params: params,
                pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
                pixelRatio: scale, timeSeconds: time,
                texture: box.texture, ambient: ambient)
        }.value
    }

    static func renderTemporaryPNG(model: EditorModel, pixels: CGSize? = nil) async -> URL? {
        guard let renderer = model.app.renderer else { return nil }
        let target = pixels ?? Self.screenWallpaperPixels
        guard let image = await renderImage(model: model, pixels: target) else { return nil }
        let name = (model.document?.name ?? "Wallpaper")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let box = RenderBox(renderer: renderer, texture: nil)
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(name).appendingPathExtension("png")
            try? FileManager.default.removeItem(at: url)
            do {
                try box.offscreen.writePNG(image, to: url)
                return url
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - Saving

    private func saveStill() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            guard let image = await Self.renderImage(model: model,
                                                     pixels: Self.screenWallpaperPixels) else {
                saveError = "Couldn't render this wallpaper."
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveError = "Allow Wallshader to add to your photo library in Settings > Privacy."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if !UserDefaults.standard.bool(forKey: "guideSheetSuppressed") {
                    showingGuide = true
                }
            } catch {
                saveError = "Couldn't save to Photos: \(error.localizedDescription)"
            }
        }
    }

    private func saveLive() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await LivePhotoExporter.saveLiveWallpaper(model: model)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if !UserDefaults.standard.bool(forKey: "guideSheetSuppressed") {
                    showingGuide = true
                }
            } catch {
                saveError = "Couldn't save the Live Photo: \(error.localizedDescription)"
            }
        }
    }
}
