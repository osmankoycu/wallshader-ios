import SwiftUI
import UnsplashKit
import WallshaderModel

@main
struct WallshaderIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var app = AppModel.shared

    init() {
        UnsplashClient.shared.accessKey = UnsplashClient.bundledAccessKey(in: .main)
        ScreensDriver.prepareIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .onOpenURL { url in
                    // .wallshader arrives via AirDrop / Files / share sheet.
                    guard url.pathExtension.lowercased() == "wallshader" else { return }
                    app.importWallshader(from: url)
                }
                .task { ScreensDriver.runIfRequested(app: app) }
        }
        .onChange(of: scenePhase) { _, phase in
            // No Lifecycle module on iOS — just stop preview rendering when
            // not active, resume when back (spec C1).
            app.previewsPaused = phase != .active
        }
    }
}

/// iPhone: the library grid is the root, the editor pushes full-screen.
/// iPad: a split view deliberately echoing the Mac Studio layout.
struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                LibraryView(style: .sidebar)
            } detail: {
                if let id = app.selectedID, app.library.document(id: id) != nil {
                    EditorView(documentID: id)
                } else {
                    ContentUnavailableView("No Wallpaper Selected",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text("Pick one from the library, or create a new wallpaper."))
                }
            }
            .sheet(isPresented: $app.showingOnboarding) { OnboardingView() }
        } else {
            NavigationStack(path: $app.path) {
                LibraryView(style: .grid)
                    .navigationDestination(for: UUID.self) { id in
                        EditorView(documentID: id)
                    }
            }
            .fullScreenCover(isPresented: $app.showingOnboarding) { OnboardingView() }
        }
    }
}
