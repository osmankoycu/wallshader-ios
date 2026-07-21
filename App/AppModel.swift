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
    @Published private(set) var syncStatus: LibrarySyncEngine.Status = .off
    private var syncEngine: LibrarySyncEngine?
    private var syncStatusMirror: AnyCancellable?
    static let syncEnabledKey = "syncWithICloud"
    @Published var path: [UUID] = []
    /// Detail pager scope: the id list frozen when a wallpaper is opened
    /// from a filtered shelf (Favorites pages only through favorites,
    /// Photos-album style). nil = the whole library, live.
    @Published var detailScopeIDs: [UUID]?
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
        // Bulk-hydrate grid thumbnails from disk before the first frame
        // asks for them — the library appears fully populated at once.
        DeviceThumbnailStore.shared.preload(docs: library.documents)
        startSyncIfEnabled()
    }

    // MARK: - iCloud sync (Phase D)

    var syncEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.syncEnabledKey) as? Bool ?? true
    }

    func startSyncIfEnabled() {
        guard syncEnabled else {
            syncStatus = .off
            return
        }
        guard syncEngine == nil else {
            syncEngine?.scheduleSync()
            return
        }
        let engine = LibrarySyncEngine(library: library, transport: CloudKitTransport())
        syncEngine = engine
        syncStatusMirror = engine.$status.sink { [weak self] status in
            self?.syncStatus = status
        }
        engine.start()
    }

    func setSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.syncEnabledKey)
        if enabled {
            startSyncIfEnabled()
        } else {
            syncEngine?.stop()
            syncEngine = nil
            syncStatusMirror = nil
            syncStatus = .off
        }
    }

    var syncStatusLine: String {
        switch syncStatus {
        case .off: return "Off"
        case .unavailable: return "iCloud unavailable"
        case .syncing: return "Syncing…"
        case .idle(let last):
            if let last {
                return "Last synced \(last.formatted(date: .omitted, time: .shortened))"
            }
            return "Waiting for first sync"
        case .error(let message): return "Sync problem: \(message)"
        }
    }

    func open(_ id: UUID, scope: [UUID]? = nil) {
        detailScopeIDs = scope
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
