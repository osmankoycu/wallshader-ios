import Combine
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel
import WallshaderStoreCore

/// App-wide services: one renderer, one library, navigation state.
/// The iOS analogue of the Mac's AppServices + a slice of StudioModel.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let renderer: ShaderRenderer?
    let library: WallpaperLibrary
    let store = StoreService.shared

    /// The device class this hardware edits by default (spec C2).
    static var currentDevice: DeviceClass {
        UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
    }

    @Published var selectedID: UUID?
    @Published var path: [UUID] = []
    @Published var previewsPaused = false
    @Published var showingPaywall = false
    @Published var showingOnboarding = false

    private init() {
        let renderer = try? ShaderRenderer()
        self.renderer = renderer
        self.library = WallpaperLibrary(renderer: renderer, host: LibraryHost(
            screenAspect: {
                let size = UIScreen.main.nativeBounds.size
                return size.height > 0 ? size.width / size.height : nil
            },
            screenScale: { UIScreen.main.scale },
            screenPixels: {
                let size = UIScreen.main.nativeBounds.size
                return SIMD2(Float(size.width), Float(size.height))
            },
            seedPhotoURL: { Bundle.main.url(forResource: "test-image", withExtension: "jpg") }))

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            showingOnboarding = true
        }
    }

    func open(_ id: UUID) {
        selectedID = id
        if UIDevice.current.userInterfaceIdiom != .pad, path.last != id {
            path.append(id)
        }
    }

    /// Free-tier gate, identical policy to the Mac (7 documents library-wide).
    func gateAddingDocument() -> Bool {
        guard store.canAddDocument(currentCount: library.documents.count) else {
            showingPaywall = true
            return false
        }
        return true
    }

    func importWallshader(from url: URL) {
        guard gateAddingDocument() else { return }
        do {
            let doc = try library.importWallshader(from: url)
            open(doc.id)
        } catch {
            // Import errors surface in the library as-is; nothing crashes.
        }
    }
}
