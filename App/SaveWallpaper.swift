import Photos
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// Export & the guided set flow (C5). There is NO API to set a wallpaper
/// on iOS — the honest flow: render at the device's exact native pixels,
/// save to Photos (add-only), then a 3-step illustrated guide. Never a
/// fake "Set" button. Non-current variants are Export/Share only.
struct SaveWallpaperMenu: View {
    @ObservedObject var model: EditorModel
    @Binding var showingGuide: Bool
    @Binding var saveError: String?
    @State private var shareURL: URL?
    @State private var saving = false

    private var isCurrentDevice: Bool {
        model.selectedDevice == AppModel.currentDevice
    }

    var body: some View {
        Group {
            if isCurrentDevice {
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView()
                    } else {
                        Label("Save Wallpaper", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(saving || !(model.document?.isAppliable ?? false))
                .accessibilityLabel("Save Wallpaper to Photos")
                .contextMenu {
                    if LivePhotoExporter.canExportLive(model: model) {
                        Button {
                            saveLive()
                        } label: {
                            Label("Save as Live Wallpaper", systemImage: "livephoto")
                        }
                    }
                    shareButton
                }
            } else {
                Menu {
                    ForEach(StudioExportPreset.presets(for: model.selectedDevice)) { preset in
                        Button("\(preset.name) — \(preset.width)×\(preset.height)") {
                            export(preset: preset)
                        }
                    }
                    shareButton
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!(model.document?.isAppliable ?? false))
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
    }

    private var shareButton: some View {
        Button {
            if let url = renderToTemporaryPNG(pixels: targetPixels()) {
                shareURL = url
            }
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
    }

    private func targetPixels() -> CGSize {
        isCurrentDevice ? UIScreen.main.nativeBounds.size
                        : model.selectedDevice.canonicalPixels
    }

    // MARK: - Render

    private func renderImage(pixels: CGSize) -> CGImage? {
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

    private func renderToTemporaryPNG(pixels: CGSize) -> URL? {
        guard let renderer = model.app.renderer,
              let image = renderImage(pixels: pixels) else { return nil }
        let name = (model.document?.name ?? "Wallpaper")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name).appendingPathExtension("png")
        try? FileManager.default.removeItem(at: url)
        try? OffscreenRenderer(renderer: renderer).writePNG(image, to: url)
        return url
    }

    // MARK: - Save to Photos (add-only authorization)

    private func save() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            guard let image = renderImage(pixels: UIScreen.main.nativeBounds.size) else {
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

    private func export(preset: StudioExportPreset) {
        if let url = renderToTemporaryPNG(pixels: CGSize(width: preset.width,
                                                         height: preset.height)) {
            shareURL = url
        }
    }
}

/// The 3-step illustrated guide (C5) — honest about how wallpapers work on
/// iOS; "Don't show this again" respected.
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guideSheetSuppressed") private var suppressed = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .padding(.top, 28)
            Text("Saved to Photos")
                .font(.title2.weight(.semibold))
            Text("iOS sets wallpapers from Settings — here's the quickest way:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 18) {
                step(1, "Open **Settings → Wallpaper**", "gearshape")
                step(2, "Tap **Add New Wallpaper**, then **Photos**", "plus.rectangle.on.rectangle")
                step(3, "Pick your wallpaper and set it", "photo.on.rectangle.angled")
            }
            .padding(.horizontal, 28)

            Spacer()

            Toggle("Don't show this again", isOn: $suppressed)
                .padding(.horizontal, 28)
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .presentationDetents([.large, .medium])
    }

    private func step(_ number: Int, _ text: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.quaternary.opacity(0.6)).frame(width: 40, height: 40)
                Image(systemName: symbol)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(number)").font(.caption).foregroundStyle(.secondary)
                Text(.init(text)).font(.callout)
            }
        }
    }
}

/// Appendix A export presets, iOS side (non-current variants).
struct StudioExportPreset: Identifiable {
    let name: String
    let width: Int
    let height: Int
    var id: String { name }

    static func presets(for device: DeviceClass) -> [StudioExportPreset] {
        switch device {
        case .desktop:
            return [StudioExportPreset(name: "Desktop 16:10", width: 2560, height: 1600),
                    StudioExportPreset(name: "Desktop 5K", width: 5120, height: 2880)]
        case .iphone:
            return [StudioExportPreset(name: "iPhone 6.3″ (Pro)", width: 1206, height: 2622),
                    StudioExportPreset(name: "iPhone 6.1″", width: 1179, height: 2556),
                    StudioExportPreset(name: "iPhone 6.9″ (Pro Max)", width: 1320, height: 2868),
                    StudioExportPreset(name: "iPhone 6.7″", width: 1290, height: 2796)]
        case .ipad:
            return [StudioExportPreset(name: "iPad 11″ Portrait", width: 1668, height: 2420),
                    StudioExportPreset(name: "iPad 11″ Landscape", width: 2420, height: 1668),
                    StudioExportPreset(name: "iPad 13″ Portrait", width: 2064, height: 2752),
                    StudioExportPreset(name: "iPad 13″ Landscape", width: 2752, height: 2064)]
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
