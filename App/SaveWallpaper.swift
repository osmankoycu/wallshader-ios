import Photos
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// The guided set flow + export presets (C5). The Save button itself
/// lives in SaveWallpaperButton (detail screen).
/// The post-save tutorial: numbered steps interleaved with hand-built
/// mock cards of the real Photos flow (share bar → Use as Wallpaper →
/// Set). Opens tall enough to show everything on both idioms;
/// "Don't show this again" respected.
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guideSheetSuppressed") private var suppressed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The header scrolls with the content ON PURPOSE: a
                // pinned bar needs its own background, and Osman wants
                // one flat sheet color throughout.
                header

                step(1, "Select your saved wallpaper in **Photos**.")
                step(2, "Tap **Share**.")
                shareBarCard
                step(3, "Tap **Use as Wallpaper**.")
                menuCard
                step(4, "Tap **Add** and choose where you want to display it.")
                setBarCard

                Toggle("Don't show this again", isOn: $suppressed)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .formFittedSizing()
    }

    private var header: some View {
        ZStack {
            Text("How to Set Wallpaper").font(.headline)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .chromeGlass(in: Circle())
                }
                Spacer()
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.blue))
            Text(.init(text))
        }
    }

    // MARK: - Mock cards (no real screenshots — tiny SwiftUI replicas)

    private var shareBarCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                Spacer()
                Image(systemName: "heart")
                    .opacity(0.45)
                Spacer()
                Image(systemName: "trash")
                    .opacity(0.45)
            }
            .font(.system(size: 20))
            .foregroundStyle(.blue)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            homeIndicator
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            menuRow("Hide", "eye.slash")
            menuDivider
            menuRow("Slideshow", "play.rectangle")
            menuDivider
            menuRow("AirPlay", "tv")
            menuDivider
            menuRow("Use as Wallpaper", "iphone", highlighted: true)
            menuDivider
            menuRow("Adjust Date & Time", "video")
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .padding(.horizontal, 10)
    }

    private func menuRow(_ title: String, _ symbol: String,
                         highlighted: Bool = false) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Image(systemName: symbol).font(.system(size: 15))
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .opacity(highlighted ? 1 : 0.4)
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.blue, lineWidth: 2.5)
            }
        }
    }

    private var menuDivider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            .padding(.leading, 14)
    }

    private var setBarCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Cancel")
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .opacity(0.45)
                Spacer()
                Text("Set")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(.blue, lineWidth: 2.5))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            homeIndicator
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
    }

    private var homeIndicator: some View {
        Capsule().fill(.white.opacity(0.3))
            .frame(width: 110, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
    }
}

private extension View {
    /// iPad: form width (page felt too wide) with the height fitted to
    /// the content so the whole tutorial still shows — the plain form
    /// sheet cuts it in half. No-op on iPhone (the large detent rules
    /// there) and on iOS 17.
    @ViewBuilder
    func formFittedSizing() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.form.fitted(horizontal: false, vertical: true))
        } else {
            self
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
