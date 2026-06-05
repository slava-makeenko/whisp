import AppIntents
import Foundation

extension Notification.Name {
    static let whispToggleDictation = Notification.Name("com.example.whisp.toggleDictation")
    static let whispOpenSettings    = Notification.Name("com.example.whisp.openSettings")
    static let whispOpenHistory     = Notification.Name("com.example.whisp.openHistory")
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
