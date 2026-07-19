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
                    if saving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                }
                .disabled(saving || !(model.document?.isAppliable ?? false))
                .accessibilityLabel("Save Wallpaper")
            } else {
                Menu {
                    ForEach(StudioExportPreset.presets(for: model.selectedDevice)) { preset in
                        Button("\(preset.name) — \(preset.width)×\(preset.height)") {
                            if let url = Self.renderTemporaryPNG(
                                model: model,
                                pixels: CGSize(width: preset.width, height: preset.height)) {
                                shareURL = url
                            }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20, weight: .semibold))
                }
                .disabled(!(model.document?.isAppliable ?? false))
                .accessibilityLabel("Export")
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
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
    }

    // MARK: - Rendering

    static func renderImage(model: EditorModel, pixels: CGSize) -> CGImage? {
        guard let renderer = model.app.renderer,
              let doc = model.document, let shaderId = doc.shaderId else { return nil }
        model.flushPendingWriteback()
        let params = model.preview.params
        let texture = model.preview.texture
        if doc.needsSourceImage && texture == nil { return nil }
        let time = model.preview.isPlaying
            ? model.preview.lastRenderedTimeSeconds
            : Float(params.frame * 0.001)
        let offscreen = OffscreenRenderer(renderer: renderer)
        return try? offscreen.renderImage(
            shaderId: shaderId, params: params,
            pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
            pixelRatio: Float(UIScreen.main.scale), timeSeconds: time,
            texture: texture, ambient: model.preview.ambient)
    }

    static func renderTemporaryPNG(model: EditorModel, pixels: CGSize? = nil) -> URL? {
        guard let renderer = model.app.renderer else { return nil }
        let target = pixels ?? UIScreen.main.nativeBounds.size
        guard let image = renderImage(model: model, pixels: target) else { return nil }
        let name = (model.document?.name ?? "Wallpaper")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name).appendingPathExtension("png")
        try? FileManager.default.removeItem(at: url)
        try? OffscreenRenderer(renderer: renderer).writePNG(image, to: url)
        return url
    }

    // MARK: - Saving

    private func saveStill() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            guard let image = Self.renderImage(model: model,
                                               pixels: UIScreen.main.nativeBounds.size) else {
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
