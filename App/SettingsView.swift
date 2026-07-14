import SwiftUI
import WallshaderStoreCore

/// Settings (C9): frame-rate cap (it maps directly to the shared preview
/// renderer), Restore Purchases, About. The iCloud Sync toggle lands with
/// Phase D.
struct SettingsView: View {
    @AppStorage("liveFrameRateCap") private var frameRateCap = 60
    @ObservedObject private var store = StoreService.shared
    @State private var restoreMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $frameRateCap) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Preview")
            } footer: {
                Text("A lower frame rate eases battery use while editing. Low Power Mode always caps previews at 30 fps.")
            }

            Section {
                if store.isPro {
                    Label("Wallshader Pro is unlocked", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Restore Purchases") {
                        Task {
                            await store.restore()
                            restoreMessage = store.isPro
                                ? "Pro restored."
                                : "No purchase found for this Apple ID."
                        }
                    }
                }
                if let restoreMessage {
                    Text(restoreMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Purchases")
            }

            Section {
                NavigationLink("About Wallshader") { AboutView() }
            }
        }
        .navigationTitle("Settings")
    }
}

/// About (C9): same credits as the Mac — Paper Shaders (Apache-2.0),
/// Unsplash attribution, licenses.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wallshader").font(.headline)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("GPU shader wallpapers for your devices — live on the Mac desktop, Photos-ready on iPhone and iPad.")
                        .font(.callout)
                }
                .padding(.vertical, 4)
            }
            Section("Credits") {
                Link(destination: URL(string: "https://paper.design")!) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paper Shaders")
                        Text("The open-source shader collection Wallshader's looks are ported from. Apache License 2.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Link(destination: URL(string: "https://unsplash.com/?utm_source=wallshader&utm_medium=referral")!) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unsplash")
                        Text("Photo search powered by Unsplash.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Show Welcome Again") {
                    AppModel.shared.showingOnboarding = true
                }
            }
        }
        .navigationTitle("About")
    }
}
