import Observation
import Sparkle
import SwiftUI

/// Direct (non-App-Store) auto-update through Sparkle 2.
///
/// The Mac app ships as a notarized DMG from our own hosting, so nothing
/// updates it unless the app does. Sparkle checks a signed appcast, verifies
/// the new build's EdDSA signature against the public key in Info.plist, and
/// only then offers it — which is why the private key must never be in this
/// repo.
///
/// Honest about being off: with no `SUFeedURL` configured the controller is
/// not started at all, `canCheckForUpdates` stays false, and the menu item
/// disables itself rather than failing silently when clicked.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    /// False when no feed is configured, so the UI can say so.
    var isConfigured: Bool { controller != nil }
    /// Mirrors Sparkle's own gate, so the menu item greys out while a check
    /// is already running.
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    private init() {
        // `startingUpdater: true` would begin scheduled checks immediately;
        // only do that when there is actually a feed to check.
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        guard let feed, !feed.isEmpty else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Explicit "Check for Updates…". Sparkle shows its own UI from here.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

/// The Help-menu item. Disabled rather than hidden when unconfigured: hiding
/// it would make a shipped build look like it has no updater at all.
struct CheckForUpdatesCommand: View {
    @State private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
