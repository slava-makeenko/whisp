import SwiftUI
import Sparkle
import Combine

/// Thin wrapper over Sparkle's standard updater. No-op in LOCAL_BUILD (dev) — there is no
/// feed or signing in development. Resolves VERIFY-UPD-1 (compile-verified against Sparkle 2.9.2).
/// P4: set `SUFeedURL` + `SUPublicEDKey` in Info.plist to enable real updates in Release.
/// `@MainActor`: Sparkle 2.9.2's `SPUStandardUpdaterController`/`SPUUpdater` are main-actor isolated.
@MainActor
final class UpdaterController: ObservableObject {
    @Published var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController?

    init() {
        #if LOCAL_BUILD
        controller = nil
        #else
        let standard = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = standard
        standard.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        #endif
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
