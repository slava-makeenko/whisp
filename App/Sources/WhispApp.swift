import SwiftUI
import SwiftData
import AppKit
import WhispCore
import WhispAudio
import WhispASR
import WhispInput
import WhispPlatform
import WhispLLM

@main
struct WhispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller: DictationController
    @State private var fileQueueModel: FileQueueModel
    @State private var onboarding = OnboardingModel(permissions: SystemPermissions())
    @StateObject private var updaterController = UpdaterController()
    @AppStorage("didOnboard") private var didOnboard = false
    @AppStorage("dictationLanguages") private var dictationLanguages = "en-US"
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("hotkeyMode") private var hotkeyMode = HotkeyMode.toggle
    @AppStorage("trimSilence") private var trimSilence = true
    @AppStorage("transcriptionEngine") private var transcriptionEngine = "auto"
    @AppStorage("commandModeEnabled") private var commandModeEnabled = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("accentColor") private var accentColor = "violet"
    @AppStorage("fontStyle") private var fontStyle = "system"
    private let container: ModelContainer
    private let hotkeys = CarbonHotkeyMonitor()
    private let modifierMonitor = ModifierTapMonitor()
    private let notchRecorder = NotchRecorderController()
    private let contextProvider = WorkspaceContextProvider()
    private let powerMode: PowerModeManager
    private let historyStore: HistoryStore
    private let metricsStore: MetricsStore
    private let dictionaryStore: DictionaryStore

    init() {
        do {
            container = try PersistenceController.makeContainer()
        } catch {
            fatalError("Failed to build the whisp data store: \(error)")
        }
        if UserDefaults.standard.object(forKey: "firstLaunch") == nil {
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "firstLaunch")
        }
        let historyStore = HistoryStore(modelContainer: container)
        let metricsStore = MetricsStore(modelContainer: container)
        let dictionaryStore = DictionaryStore(modelContainer: container)
        self.historyStore = historyStore
        self.metricsStore = metricsStore
        self.dictionaryStore = dictionaryStore

        // Composition root: wire concrete implementations into the orchestrator.
        let controller = DictationController(
            capturer: AVAudioEngineCapturer(),
            router: TranscriptionBackends.makeRouter(),
            injector: AccessibilityTextInjector(),
            media: NoOpMediaController(),
            vad: EnergyVAD(),
            onSessionComplete: { record in
                let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                try? await historyStore.add(text: record.text, durationMs: record.durationMs,
                                            backend: record.backend, appBundleID: bundleID)
                try? await metricsStore.record(text: record.text, durationMs: record.durationMs)
            },
            textPostProcessor: { text in
                let replacements = (try? await dictionaryStore.enabledReplacements()) ?? []
                var result = DictionaryProcessor.apply(replacements, to: text)
                let defaults = UserDefaults.standard
                let targetID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                // Resolve the active mode: a specific mode wins outright; "Auto" adapts to the focused
                // app — an explicit Power Mode rule first, otherwise a per-app-category heuristic.
                var style = EnhancementStyle(rawValue: defaults.string(forKey: "enhancementStyle") ?? "auto") ?? .auto
                if style == .auto {
                    let rules = AppEnhancementRule.decode(defaults.string(forKey: "enhancementAppRules") ?? "[]")
                    if let ruleRaw = rules.first(where: { $0.bundleID == targetID })?.style,
                       let ruled = EnhancementStyle(rawValue: ruleRaw), ruled != .auto {
                        style = ruled
                    } else {
                        style = EnhancementStyle.autoStyle(forBundleID: targetID)
                    }
                }
                guard style != .raw else { return result }

                let provider = EnhancementProvider(rawValue: defaults.string(forKey: "enhancementProvider") ?? "openai") ?? .openAI
                let key = (try? KeychainSecretStore().get(provider.secretKey)) ?? nil
                let prompt = style == .custom ? (defaults.string(forKey: "enhancementPrompt") ?? "") : (style.prompt ?? "")

                if let key, !key.isEmpty, !prompt.isEmpty {
                    let model = defaults.string(forKey: "enhancementModel") ?? ""
                    result = (try? await URLSessionLLMEnhancer(apiKey: key)
                        .enhance(result, prompt: prompt, provider: provider.llmProvider(model: model))) ?? result
                } else if style == .cleanUp {
                    result = LocalTextCleaner.clean(result)   // no LLM → light on-device cleanup
                }
                return result
            },
            vocabularyProvider: {
                let replacements = (try? await dictionaryStore.enabledReplacements()) ?? []
                return Array(Set(replacements.map(\.replacement))).filter { !$0.isEmpty }
            },
            commandProcessor: { command, selection in
                // Command Mode: ask the LLM to apply the spoken instruction to the selected text.
                let defaults = UserDefaults.standard
                let provider = EnhancementProvider(rawValue: defaults.string(forKey: "enhancementProvider") ?? "openai") ?? .openAI
                guard let key = (try? KeychainSecretStore().get(provider.secretKey)) ?? nil, !key.isEmpty else { return nil }
                let model = defaults.string(forKey: "enhancementModel") ?? ""
                let prompt = "You are a precise text editor. Apply the user's instruction to the text below and output ONLY the resulting text — no quotes, no commentary. Instruction: \(command)"
                return try? await URLSessionLLMEnhancer(apiKey: key)
                    .enhance(selection, prompt: prompt, provider: provider.llmProvider(model: model))
            },
            onCue: { cue in
                guard UserDefaults.standard.object(forKey: "playSoundCues") as? Bool ?? true else { return }
                let sound = NSSound(named: cue == .start ? "Pop" : "Bottle")
                sound?.volume = 0.5
                sound?.play()
            })
        _controller = State(initialValue: controller)
        _fileQueueModel = State(initialValue: FileQueueModel(
            queue: TranscriptionQueue(router: TranscriptionBackends.makeRouter())))

        // Power Mode applies the active profile's locale to the next dictation session.
        // Profiles start empty; the management UI is a later refinement.
        powerMode = PowerModeManager(profiles: []) { [weak controller] profile in
            controller?.preferredOptions = profile.flatMap { active in
                active.locale.map { TranscriptionOptions(languages: [Locale(identifier: $0)]) }
            }
        }

        // Drive the notch indicator off the controller directly (not a window's .onChange), so it
        // works even when whisp runs in the background with its window closed.
        notchRecorder.observe(controller)
        controller.commandModeEnabled = UserDefaults.standard.bool(forKey: "commandModeEnabled")
    }

    /// Interface language for the SwiftUI scenes. "system" follows macOS; otherwise force en/ru so the
    /// String Catalog resolves that language live (no restart needed).
    private var appLocale: Locale {
        switch appLanguage {
        case "ru": Locale(identifier: "ru")
        case "en": Locale(identifier: "en")
        default:   Locale.autoupdatingCurrent
        }
    }

    private var appAccent: Color { (AccentPalette(rawValue: accentColor) ?? .violet).color }
    private var appFontDesign: Font.Design { (AppFontStyle(rawValue: fontStyle) ?? .system).design }

    var body: some Scene {
        Window("whisp", id: "main") {
            RootView()
                .environment(controller)
                .environment(fileQueueModel)
                .environment(\.locale, appLocale)
                .modelContainer(container)
                .task { await startHotkeys() }
                .task { await startContext() }
                .task { await fileQueueModel.start() }
                .sheet(isPresented: .init(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) {
                    OnboardingView { didOnboard = true }
                        .environment(onboarding)
                }
                .onReceive(NotificationCenter.default.publisher(for: .whispToggleDictation)) { _ in
                    controller.toggle()
                }
                .onChange(of: dictationLanguages, initial: true) { _, _ in applyTranscriptionOptions() }
                .onChange(of: trimSilence) { applyTranscriptionOptions() }
                .onChange(of: transcriptionEngine) { applyTranscriptionOptions() }
                .onChange(of: commandModeEnabled) { controller.commandModeEnabled = commandModeEnabled }
                .onChange(of: hotkeyKeyCode) { applyHotkey() }
                .onChange(of: hotkeyModifiers) { applyHotkey() }
                .onChange(of: hotkeyMode) { applyHotkey() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updaterController.checkForUpdates() }
                    .disabled(!updaterController.canCheckForUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }
        }

        MenuBarExtra("whisp", image: "MenuBarIcon") {
            MenuBarContent().environment(controller).environment(\.locale, appLocale)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsView()
                .modelContainer(container)
                .environment(\.locale, appLocale)
                .tint(appAccent)
                .fontDesign(appFontDesign)
                .preferredColorScheme(.light)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 940, height: 640)
    }

    /// ⌥Space toggles dictation. Requires Accessibility permission (requested in onboarding, Phase 10);
    /// without it the tap fails to create and we simply run without a global hotkey.
    private func startHotkeys() async {
        applyHotkey()
        for await event in hotkeys.events {
            await controller.handleHotkey(event)
        }
    }

    private func applyHotkey() {
        let mods = HotkeyModifiers(rawValue: hotkeyModifiers)
        if hotkeyKeyCode < 0 {
            // Modifier-only: behavior follows the mode (hold to talk / double-tap). Carbon can't
            // bind a bare modifier, so a flagsChanged monitor drives it instead.
            hotkeys.stop()
            modifierMonitor.onEvent = { event in Task { await controller.handleHotkey(event) } }
            modifierMonitor.start(modifier: mods, mode: hotkeyMode)
        } else {
            modifierMonitor.stop()
            let binding = HotkeyBinding(keyCode: UInt16(hotkeyKeyCode), modifiers: mods)
            try? hotkeys.start(binding, mode: hotkeyMode)
        }
    }

    private func applyTranscriptionOptions() {
        let langs = DictationLanguage.selectedIDs(dictationLanguages).map { Locale(identifier: $0) }
        controller.options = TranscriptionOptions(
            languages: langs,
            useVAD: trimSilence,
            preferredBackend: TranscriptionBackendID(rawValue: transcriptionEngine))   // "auto" → nil → best-available
    }

    private func startContext() async {
        contextProvider.start()
        for await context in contextProvider.changes {
            powerMode.update(context)
        }
    }
}

/// The app-menu "Settings…" item (⌘,) — opens the dedicated Settings window.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}

private struct MenuBarContent: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @AppStorage("dictationLanguages") private var dictationLanguages = "en-US"
    @AppStorage("enhancementStyle") private var enhancementStyle = "auto"

    var body: some View {
        Button("Open whisp Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(LocalizedStringKey(controller.state == .recording ? "Stop Dictation" : "Start Dictation")) {
            controller.toggle()
        }
        Menu("Language") {
            ForEach(DictationLanguage.all) { language in
                Toggle(language.name, isOn: Binding(
                    get: { DictationLanguage.selectedIDs(dictationLanguages).contains(language.id) },
                    set: { _ in dictationLanguages = DictationLanguage.toggle(language.id, in: dictationLanguages) }))
            }
        }
        Menu("Mode") {
            ForEach(EnhancementStyle.allCases) { style in
                Toggle(LocalizedStringKey(style.name), isOn: Binding(
                    get: { enhancementStyle == style.rawValue },
                    set: { if $0 { enhancementStyle = style.rawValue } }))
            }
        }
        if !controller.liveText.isEmpty {
            Text(controller.liveText).lineLimit(1)
        }
        Divider()
        Button("Quit whisp") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Brings the app and its window forward on launch and on Dock-icon reopen — otherwise the
/// window can open behind Xcode (you'd see only the menu-bar icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var backgroundActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Dictation happens while another app is focused, so whisp is in the background. Hold a
        // user-initiated activity to keep App Nap from throttling capture, the notch animation, and
        // text injection when we're not frontmost.
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Background dictation")
    }

    /// Closing the window (red ✕) must NOT quit whisp — it keeps running in the background with the
    /// menu-bar icon and the global hotkey live. Reopen via the menu bar or the Dock icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return true   // reopens the window on Dock-icon click
    }
}
