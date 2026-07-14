import StoreKit
import SwiftUI
import WallshaderStoreCore

/// Wallshader Pro (C7): the same non-consumable product as the Mac — one
/// purchase, both platforms (universal purchase, same app record). iOS-
/// native layout, the Mac paywall's content and tone.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreService.shared
    @State private var purchasing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)
                Text("Wallshader Pro")
                    .font(.largeTitle.weight(.bold))
                Text("Unlimited wallpapers. One purchase, yours forever — on Mac, iPhone, and iPad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(alignment: .leading, spacing: 12) {
                    feature("infinity", "Unlimited wallpapers — the free library holds \(StoreService.freeDocumentLimit)")
                    feature("pencil", "Every editing feature stays free, always")
                    feature("laptopcomputer.and.iphone", "One purchase unlocks every platform")
                }
                .padding(.horizontal, 32)

                Spacer()

                if store.isPro {
                    Label("Pro is unlocked. Thanks!", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        purchase()
                    } label: {
                        Group {
                            if purchasing {
                                ProgressView()
                            } else {
                                Text("Unlock Pro — \(store.product?.displayPrice ?? "$8.99")")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .disabled(purchasing)

                    Button("Restore Purchases") {
                        Task {
                            await store.restore()
                            message = store.isPro ? nil : "No purchase found for this Apple ID."
                        }
                    }
                    .font(.callout)
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(.tint)
            Text(text).font(.callout)
        }
    }

    private func purchase() {
        purchasing = true
        Task {
            do {
                try await store.purchase()
                if store.isPro {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            } catch {
                message = error.localizedDescription
            }
            purchasing = false
        }
    }
}
