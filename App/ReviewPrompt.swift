import StoreKit
import SwiftUI
import WallshaderModel

/// The iPhone's rating flow.
///
/// Launching is the milestone here, unlike the Mac — this app is opened
/// deliberately, so a launch really is someone choosing to come back,
/// where the Mac app runs from login and counts Studio opens instead. The
/// two platforms keep separate tallies (`ReviewPromptPolicy`'s key
/// prefix) because Apple's three-a-year ceiling is per device.
@MainActor
final class ReviewPrompt: ObservableObject {
    static let shared = ReviewPrompt()

    /// Raised when the policy says an ask is due; the root view lowers it
    /// again once it has asked.
    @Published var isDue = false

    private let policy = ReviewPromptPolicy(keyPrefix: "reviewPrompt.launch")
    /// A launch is one process, however many times the root view appears
    /// — returning from the background must not count as coming back.
    private var countedThisLaunch = false

    private init() {}

    func noteLaunch() {
        guard !countedThisLaunch else { return }
        countedThisLaunch = true
        if policy.noteEvent() { isDue = true }
    }
}

extension View {
    /// Asks for a rating when one is due, once this view is up.
    /// `suppressed` holds it back while something else owns the screen.
    func reviewPromptWhenDue(suppressed: Bool = false) -> some View {
        modifier(ReviewPromptModifier(suppressed: suppressed))
    }
}

private struct ReviewPromptModifier: ViewModifier {
    let suppressed: Bool

    @Environment(\.requestReview) private var requestReview
    @ObservedObject private var prompt = ReviewPrompt.shared

    func body(content: Content) -> some View {
        // Keyed on both, so lifting the suppression re-evaluates rather
        // than dropping an ask that was merely badly timed.
        content.task(id: [prompt.isDue, suppressed]) {
            guard prompt.isDue, !suppressed else { return }
            // Let the library finish appearing: the point is to catch
            // someone glad to be back, not to greet them with a dialog.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            // Lowered before asking, not after: requestReview reports
            // nothing back, so this is the only moment we know about.
            prompt.isDue = false
            requestReview()
        }
    }
}
