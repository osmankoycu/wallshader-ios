import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UnsplashKit
import WallshaderModel

/// Photo sources (C3): Photos picker (no permission prompt), Files
/// importer, and Unsplash search — each copies into the document, never
/// references. The macOS system-wallpapers gallery is Mac-only and omitted.
struct PhotoSourcesSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var showingUnsplash = false

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    showingFiles = true
                } label: {
                    Label("Files…", systemImage: "folder")
                }
                if UnsplashClient.sourceVisible && UnsplashClient.shared.isConfigured {
                    Button {
                        showingUnsplash = true
                    } label: {
                        Label("Unsplash", systemImage: "magnifyingglass")
                    }
                }
            }
            .navigationTitle("Add Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                defer { photoItem = nil; dismiss() }
                // Copy-into-document: the picked bytes land in a temp file
                // and flow through the same import layer as everything
                // else. Every failure SAYS so — an iCloud photo that
                // isn't local while offline used to just… not arrive.
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    AppModel.shared.importError =
                        "Couldn't load that photo from your library. Check your connection and try again."
                    return
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("picked-\(UUID().uuidString)")
                do {
                    try data.write(to: tmp)
                } catch {
                    AppModel.shared.importError =
                        "Couldn't save the picked photo: \(error.localizedDescription)"
                    return
                }
                model.importImage(url: tmp, onFailure: { error in
                    AppModel.shared.importError =
                        "Couldn't import this photo: \(error.localizedDescription)"
                })
            }
        }
        .fileImporter(isPresented: $showingFiles,
                      allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                model.importImage(url: url, onFailure: { error in
                    AppModel.shared.importError =
                        "Couldn't import this photo: \(error.localizedDescription)"
                })
            }
            dismiss()
        }
        .sheet(isPresented: $showingUnsplash) {
            UnsplashSearchSheet(model: model) { dismiss() }
        }
    }
}

/// Unsplash search with the same attribution and offline/rate-limit
/// handling as the Mac (C3): photographer credit on selection, the
/// download endpoint pinged when a photo is used.
struct UnsplashSearchSheet: View {
    @ObservedObject var model: EditorModel
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = NetworkMonitor.shared

    @State private var query = ""
    @State private var results: [UnsplashClient.Photo] = []
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if !network.isOnline {
                    ContentUnavailableView("You're Offline", systemImage: "wifi.slash",
                                           description: Text("Unsplash needs an internet connection."))
                } else if let message {
                    ContentUnavailableView(message, systemImage: "exclamationmark.magnifyingglass")
                } else {
                    resultsGrid
                }
            }
            .navigationTitle("Unsplash")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search photos")
            .onSubmit(of: .search) { search() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(results) { photo in
                    Button {
                        pick(photo)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            AsyncImage(url: URL(string: photo.urls.small)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            // Unsplash compliance: photographer + service.
                            Text("\(photo.user.name) · Unsplash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            if loading { ProgressView().padding() }
        }
    }

    private func search() {
        guard !query.isEmpty else { return }
        loading = true
        message = nil
        Task {
            do {
                results = try await UnsplashClient.shared.search(query: query)
                if results.isEmpty { message = "No results for “\(query)”." }
            } catch {
                message = error.localizedDescription
            }
            loading = false
        }
    }

    private func pick(_ photo: UnsplashClient.Photo) {
        loading = true
        Task {
            do {
                UnsplashClient.shared.triggerDownload(photo)
                let px = Int(UIScreen.main.nativeBounds.height)
                let url = try await UnsplashClient.shared.downloadForImport(
                    photo, targetPixelWidth: max(2556, px))
                model.importImage(url: url, attribution: photo.attribution,
                                  onFailure: { error in
                    AppModel.shared.importError =
                        "Couldn't import this photo: \(error.localizedDescription)"
                })
                dismiss()
                onDone()
            } catch {
                message = error.localizedDescription
            }
            loading = false
        }
    }
}

/// Same bridge as the Mac app: the package stays model-free.
extension UnsplashClient.Photo {
    var attribution: WallpaperDocument.Attribution {
        WallpaperDocument.Attribution(
            photographerName: user.name,
            photographerURL: user.links.html + UnsplashClient.utmSuffix,
            sourceName: "Unsplash",
            sourceURL: UnsplashClient.unsplashHomeURL)
    }
}
