import AppIntents
import Foundation

extension Notification.Name {
    static let whispToggleDictation = Notification.Name("com.slavamakeenko.whisp.toggleDictation")
    static let whispOpenSettings    = Notification.Name("com.slavamakeenko.whisp.openSettings")
    static let whispOpenHistory     = Notification.Name("com.slavamakeenko.whisp.openHistory")
    static let whispOpenPowerMode   = Notification.Name("com.slavamakeenko.whisp.openPowerMode")
    /// Posted with a `FileTranscription.id` (UUID) as `object` to open the Files tab on that record.
    static let whispOpenFiles       = Notification.Name("com.slavamakeenko.whisp.openFiles")
    static let whispOpenConference  = Notification.Name("com.slavamakeenko.whisp.openConference")
}

/// Siri / Shortcuts action that toggles dictation in the running app via a notification.
struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .whispToggleDictation, object: nil)
        return .result()
    }
}

struct WhispShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: ["Toggle dictation in \(.applicationName)"],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic.fill")
    }
}
