import Photos
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// The guided set flow + export presets (C5). The Save button itself
/// lives in SaveWallpaperButton (detail screen).
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
