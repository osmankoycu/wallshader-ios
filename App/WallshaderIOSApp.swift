import SwiftUI
import UnsplashKit
import WallshaderModel

@main
struct WallshaderIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var app = AppModel.shared

    init() {
        // Only Release carries the iCloud entitlement (project.yml). A
        // Debug build on a signed-in device must never reach CKContainer —
        // that raises an uncatchable NSException (the Task EXC_BREAKPOINT
        // crash on first device install).
        #if !DEBUG
        CloudKitTransport.hostDeclaresEntitlement = true
        #endif
        UnsplashClient.shared.accessKey = UnsplashClient.bundledAccessKey(in: .main)
        ScreensDriver.prepareIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // .wallshader arrives via AirDrop / Files / share
                    // sheet. With in-place opening declared, a Files tap
                    // hands us a security-scoped URL — access must be
                    // wrapped or the read silently fails.
                    guard url.pathExtension.lowercased() == "wallshader" else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    app.importWallshader(from: url)
                }
                .task { ScreensDriver.runIfRequested(app: app) }
        }
        .onChange(of: scenePhase) { _, phase in
            // No Lifecycle module on iOS — just stop preview rendering when
            // not active, resume when back (spec C1). Activation also kicks
            // a sync pass (the snapshot transport has no push channel).
            app.previewsPaused = phase != .active
            if phase == .active { app.startSyncIfEnabled() }
        }
    }
}

/// iPhone: the library grid is the root, the editor pushes full-screen.
/// iPad: a split view deliberately echoing the Mac Studio layout.
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    /// Photos-style zoom between a grid tile and the detail screen.
    @Namespace private var zoomNamespace

    var body: some View {
        // ONE structure on every device: the iPhone-proven grid → zoom →
        // fullscreen detail stack (the iPad's split view retired).
        NavigationStack(path: $app.path) {
            LibraryView(zoomNamespace: zoomNamespace)
                .navigationDestination(for: UUID.self) { id in
                    DetailView(documentID: id, zoomNamespace: zoomNamespace)
                }
        }
        .fullScreenCover(isPresented: $app.showingOnboarding) { OnboardingView() }
        .sheet(isPresented: $app.showingGuideProbe) { GuideSheet() }
        .alert("Import Failed", isPresented: Binding(
            get: { app.importError != nil },
            set: { if !$0 { app.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.importError ?? "")
        }
    }
}
