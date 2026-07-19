import UIKit
import WallshaderModel

/// The Mac variant bar v2's size catalog, used on mobile as EXPORT
/// targets only (the phone previews and saves at its own screen size —
/// the sizes never change what you see). "Current" is THIS device's
/// screen at the top of its own category.
struct DeviceSizePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelRatio: Float

    var sizeLabel: String { "\(pixelWidth)×\(pixelHeight)" }
}

@MainActor
enum DeviceSizeCatalog {
    nonisolated static let currentScreenID = "ios.current"

    /// THIS device's screen, resolved at read time.
    static func currentScreenPreset() -> DeviceSizePreset {
        let size = UIScreen.main.nativeBounds.size
        return DeviceSizePreset(id: currentScreenID, name: "Current",
                                pixelWidth: max(1, Int(size.width)),
                                pixelHeight: max(1, Int(size.height)),
                                pixelRatio: Float(UIScreen.main.scale))
    }

    static func presets(for device: DeviceClass) -> [DeviceSizePreset] {
        var all: [DeviceSizePreset]
        switch device {
        case .desktop:
            all = [
                DeviceSizePreset(id: "desktop.mba13", name: "MacBook Air 13″",
                                 pixelWidth: 2560, pixelHeight: 1664, pixelRatio: 2),
                DeviceSizePreset(id: "desktop.mba15", name: "MacBook Air 15″",
                                 pixelWidth: 2880, pixelHeight: 1864, pixelRatio: 2),
                DeviceSizePreset(id: "desktop.mbp14", name: "MacBook Pro 14″",
                                 pixelWidth: 3024, pixelHeight: 1964, pixelRatio: 2),
                DeviceSizePreset(id: "desktop.mbp16", name: "MacBook Pro 16″",
                                 pixelWidth: 3456, pixelHeight: 2234, pixelRatio: 2),
                DeviceSizePreset(id: "desktop.fullhd", name: "Full HD",
                                 pixelWidth: 1920, pixelHeight: 1080, pixelRatio: 1),
                DeviceSizePreset(id: "desktop.qhd", name: "QHD Display",
                                 pixelWidth: 2560, pixelHeight: 1440, pixelRatio: 1),
                DeviceSizePreset(id: "desktop.4k", name: "4K Display",
                                 pixelWidth: 3840, pixelHeight: 2160, pixelRatio: 2),
                DeviceSizePreset(id: "desktop.5k", name: "5K Display",
                                 pixelWidth: 5120, pixelHeight: 2880, pixelRatio: 2),
                DeviceSizePreset(id: "desktop.6k", name: "6K Display",
                                 pixelWidth: 6016, pixelHeight: 3384, pixelRatio: 2),
            ]
        case .ipad:
            all = [
                DeviceSizePreset(id: "tablet.pro13", name: "iPad Pro 13″",
                                 pixelWidth: 2064, pixelHeight: 2752, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.pro129", name: "iPad Pro 12.9″",
                                 pixelWidth: 2048, pixelHeight: 2732, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.pro11", name: "iPad Pro 11″",
                                 pixelWidth: 1668, pixelHeight: 2420, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.air11", name: "iPad Air 11″",
                                 pixelWidth: 1640, pixelHeight: 2360, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.mini", name: "iPad mini 8.3″",
                                 pixelWidth: 1488, pixelHeight: 2266, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.android", name: "Android Tablet",
                                 pixelWidth: 1600, pixelHeight: 2560, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.surface", name: "Surface Pro",
                                 pixelWidth: 1920, pixelHeight: 2880, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.pro13.landscape", name: "iPad Pro 13″ Landscape",
                                 pixelWidth: 2752, pixelHeight: 2064, pixelRatio: 2),
                DeviceSizePreset(id: "tablet.pro11.landscape", name: "iPad Pro 11″ Landscape",
                                 pixelWidth: 2420, pixelHeight: 1668, pixelRatio: 2),
            ]
        case .iphone:
            all = [
                DeviceSizePreset(id: "phone.61", name: "iPhone 16 · 17",
                                 pixelWidth: 1179, pixelHeight: 2556, pixelRatio: 3),
                DeviceSizePreset(id: "phone.63pro", name: "iPhone 16 · 17 Pro",
                                 pixelWidth: 1206, pixelHeight: 2622, pixelRatio: 3),
                DeviceSizePreset(id: "phone.67", name: "iPhone 16 Plus",
                                 pixelWidth: 1290, pixelHeight: 2796, pixelRatio: 3),
                DeviceSizePreset(id: "phone.69promax", name: "iPhone 16 · 17 Pro Max",
                                 pixelWidth: 1320, pixelHeight: 2868, pixelRatio: 3),
                DeviceSizePreset(id: "phone.air", name: "iPhone Air",
                                 pixelWidth: 1260, pixelHeight: 2736, pixelRatio: 3),
                DeviceSizePreset(id: "phone.1415pro", name: "iPhone 14 · 15 Pro",
                                 pixelWidth: 1179, pixelHeight: 2556, pixelRatio: 3),
                DeviceSizePreset(id: "phone.1314", name: "iPhone 13 · 14",
                                 pixelWidth: 1170, pixelHeight: 2532, pixelRatio: 3),
                DeviceSizePreset(id: "phone.14plus", name: "iPhone 14 Plus",
                                 pixelWidth: 1284, pixelHeight: 2778, pixelRatio: 3),
                DeviceSizePreset(id: "phone.se", name: "iPhone SE",
                                 pixelWidth: 750, pixelHeight: 1334, pixelRatio: 2),
                DeviceSizePreset(id: "phone.android", name: "Android Phone",
                                 pixelWidth: 1080, pixelHeight: 2400, pixelRatio: 3),
            ]
        }
        if device == AppModel.currentDevice {
            all.insert(currentScreenPreset(), at: 0)
        }
        return all
    }


}

extension DeviceClass {
    /// Generic category names (variant bar v2) — the shared displayName
    /// stays device-branded for storage/compat.
    var categoryName: String {
        switch self {
        case .desktop: return "Desktop"
        case .ipad: return "Tablet"
        case .iphone: return "Phone"
        }
    }

    var categorySymbol: String {
        switch self {
        case .desktop: return "desktopcomputer"
        case .ipad: return "ipad"
        case .iphone: return "iphone"
        }
    }
}
