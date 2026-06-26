import SwiftUI
import SwiftData
import AppKit
import WhispCore
import WhispAudio
import WhispASR
import WhispInput
import WhispPlatform
import WhispLLM
import UniformTypeIdentifiers

@main
struct WhispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller: DictationController
    @State private var fileQueueModel: FileQueueModel
    @State private var conferenceController: ConferenceController
    @State private var modelStore = LocalModelStore()
    @State private var onboarding = OnboardingModel(permissions: SystemPermissions())
    @StateObject private var updaterController = UpdaterController()
    @AppStorage("didOnboard") private var didOnboard = false
    @AppStorage("dictationLanguages") private var dictationLanguages = "en-US"
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("hotkeyMode") private var hotkeyMode = HotkeyMode.toggle
    @AppStorage("conferenceHotkeyKeyCode") private var conferenceHotkeyKeyCode = 49
    @AppStorage("conferenceHotkeyModifiers") private var conferenceHotkeyModifiers = HotkeyModifiers([.control, .option]).rawValue
    @AppStorage("trimSilence") private var trimSilence = true
    @AppStorage("autoStopOnSilence") private var autoStopOnSilence = false
    @AppStorage("transcriptionEngine") private var transcriptionEngine = "auto"
    @AppStorage("commandModeEnabled") private var commandModeEnabled = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("accentColor") private var accentColor = "clay"
    @AppStorage("fontStyle") private var fontStyle = "system"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    private var preferredScheme: ColorScheme? {
        switch colorSchemeRaw { case "light": .light; case "dark": .dark; default: nil }
    }
    private let container: ModelContainer
    private let hotkeys = CarbonHotkeyMonitor()
    private let modifierMonitor = ModifierTapMonitor()
    private let conferenceHotkeys = CarbonHotkeyMonitor(id: 2)
    private let conferenceModifierMonitor = ModifierTapMonitor()
    private let notchRecorder = NotchRecorderController()
    private let contextProvider = WorkspaceContextProvider()
    // Held as properties so they stay alive during async playback.
    // NSSound(named:) returns a shared cached instance — calling stop() before play()
    // resets it so the sound fires reliably every time (not just every other time).
    private let soundStart: NSSound? = NSSound(named: "Pop")
    private let soundStop: NSSound? = NSSound(named: "Bottle")
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

                if !defaults.bool(forKey: "forceLocalEnhancement"), let key, !key.isEmpty, !prompt.isEmpty {
                    // Cloud LLM — used only when a key is set AND the user hasn't picked Local on the dashboard
                    let model = defaults.string(forKey: "enhancementModel") ?? ""
                    do {
                        result = try await URLSessionLLMEnhancer(apiKey: key)
                            .enhance(result, prompt: prompt, provider: provider.llmProvider(model: model))
                        Log.asr.info("Cloud enhancement via \(provider.displayName, privacy: .public) (\(style.rawValue, privacy: .public))")
                    } catch {
                        // Keep the raw (dictionary-applied) text, but make the failure diagnosable.
                        Log.asr.error("Live cloud enhancement failed; using raw text: \(error.localizedDescription, privacy: .public)")
                    }
                } else if UserDefaults.standard.string(forKey: "localModelID") != nil {
                    // On-device model downloaded — LocalTextCleaner now; MLX inference plugged in here
                    result = LocalTextCleaner.clean(result)
                } else if style == .cleanUp {
                    result = LocalTextCleaner.clean(result)
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
                guard !defaults.bool(forKey: "forceLocalEnhancement"),
                      let key = (try? KeychainSecretStore().get(provider.secretKey)) ?? nil, !key.isEmpty else { return nil }
                let model = defaults.string(forKey: "enhancementModel") ?? ""
                let prompt = "You are a precise text editor. Apply the user's instruction to the text below and output ONLY the resulting text — no quotes, no commentary. Instruction: \(command)"
                do {
                    return try await URLSessionLLMEnhancer(apiKey: key)
                        .enhance(selection, prompt: prompt, provider: provider.llmProvider(model: model))
                } catch {
                    Log.asr.error("Command-mode enhancement failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            },
            onCue: { [soundStart, soundStop] cue in
                guard UserDefaults.standard.object(forKey: "playSoundCues") as? Bool ?? true else { return }
                let sound = cue == .start ? soundStart : soundStop
                let outputUID = UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
                sound?.playbackDeviceIdentifier = outputUID.isEmpty ? nil : outputUID
                sound?.volume = 0.5
                sound?.stop()   // reset so play() always fires, even if previous instance hasn't finished
                sound?.play()
            })
        _controller = State(initialValue: controller)
        _fileQueueModel = State(initialValue: FileQueueModel(
            queue: TranscriptionQueue(
                router: TranscriptionBackends.makeRouter(),
                textPostProcessor: { text in
                    // Apply the same formatting pipeline as live dictation.
                    let replacements = (try? await dictionaryStore.enabledReplacements()) ?? []
                    var result = DictionaryProcessor.apply(replacements, to: text)
                    let defaults = UserDefaults.standard
                    let styleRaw = defaults.string(forKey: "enhancementStyle") ?? "auto"
                    var style = EnhancementStyle(rawValue: styleRaw) ?? .auto
                    if style == .auto {
                        let rules = AppEnhancementRule.decode(defaults.string(forKey: "enhancementAppRules") ?? "[]")
                        style = rules.first.flatMap { EnhancementStyle(rawValue: $0.style) } ?? .cleanUp
                    }
                    guard style != .raw else { return result }
                    let provider = EnhancementProvider(rawValue: defaults.string(forKey: "enhancementProvider") ?? "openai") ?? .openAI
                    let key = (try? KeychainSecretStore().get(provider.secretKey)) ?? nil
                    let prompt = style == .custom ? (defaults.string(forKey: "enhancementPrompt") ?? "") : (style.prompt ?? "")
                    if !defaults.bool(forKey: "forceLocalEnhancement"), let key, !key.isEmpty, !prompt.isEmpty {
                        let model = defaults.string(forKey: "enhancementModel") ?? ""
                        do {
                            result = try await URLSessionLLMEnhancer(apiKey: key)
                                .enhance(result, prompt: prompt, provider: provider.llmProvider(model: model))
                            Log.asr.info("File-queue cloud enhancement via \(provider.displayName, privacy: .public)")
                        } catch {
                            Log.asr.error("File-queue cloud enhancement failed; using raw text: \(error.localizedDescription, privacy: .public)")
                        }
                    } else if style == .cleanUp || defaults.string(forKey: "localModelID") != nil {
                        result = LocalTextCleaner.clean(result)
                    }
                    return result
                }
            )))

        // Power Mode applies the active profile's locale to the next dictation session.
        // Profiles start empty; the management UI is a later refinement.
        powerMode = PowerModeManager(profiles: []) { [weak controller] profile in
            controller?.preferredOptions = profile.flatMap { active in
                active.locale.map { TranscriptionOptions(languages: [Locale(identifier: $0)]) }
            }
        }

        // Conference Mode: its own controller, sharing the data store and the notch indicator.
        let conferenceController = ConferenceController()
        conferenceController.modelContainer = container
        _conferenceController = State(initialValue: conferenceController)

        // Drive the notch indicator off the controllers directly (not a window's .onChange), so it
        // works even when whisp runs in the background with its window closed.
        notchRecorder.observe(controller)
        notchRecorder.observe(conference: conferenceController)
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

    private var appAccent: Color { (AccentPalette(rawValue: accentColor) ?? .clay).color }
    private var appFontDesign: Font.Design { (AppFontStyle(rawValue: fontStyle) ?? .system).design }

    var body: some Scene {
        Window("whisp", id: "main") {
            RootView()
                .environmentObject(updaterController)
                .environment(controller)
                .environment(conferenceController)
                .environment(fileQueueModel)
                .environment(modelStore)
                .environment(\.locale, appLocale)
                .modelContainer(container)
                .task { await startHotkeys() }
                .task { await startContext() }
                .task { await fileQueueModel.start() }
                .task { await startConferenceHotkeys() }
                .sheet(isPresented: .init(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) {
                    OnboardingView { didOnboard = true }
                        .environment(onboarding)
                }
                .onReceive(NotificationCenter.default.publisher(for: .whispToggleDictation)) { _ in
                    controller.toggle()
                }
                .onChange(of: dictationLanguages, initial: true) { _, _ in applyTranscriptionOptions() }
                .onChange(of: trimSilence) { applyTranscriptionOptions() }
                .onChange(of: autoStopOnSilence) { applyTranscriptionOptions() }
                .onChange(of: transcriptionEngine) { applyTranscriptionOptions() }
                .onChange(of: commandModeEnabled) { controller.commandModeEnabled = commandModeEnabled }
                .onChange(of: hotkeyKeyCode) { applyHotkey() }
                .onChange(of: hotkeyModifiers) { applyHotkey() }
                .onChange(of: hotkeyMode) { applyHotkey(); applyTranscriptionOptions() }   // re-evaluate auto-stop gating
                .onChange(of: conferenceHotkeyKeyCode) { applyConferenceHotkey() }
                .onChange(of: conferenceHotkeyModifiers) { applyConferenceHotkey() }
        }
        .windowStyle(.hiddenTitleBar)
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
            MenuBarContent()
                .environment(controller)
                .environment(conferenceController)
                .environment(\.locale, appLocale)
        }
        .menuBarExtraStyle(.menu)
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

    private func startConferenceHotkeys() async {
        applyConferenceHotkey()
        for await event in conferenceHotkeys.events where event == .toggle {
            conferenceController.toggle()
        }
    }

    /// Conference Mode is always a toggle (press to start, press to stop). Mirrors `applyHotkey`:
    /// a modifier-only chord goes through the flagsChanged monitor; a key combo through Carbon.
    private func applyConferenceHotkey() {
        let mods = HotkeyModifiers(rawValue: conferenceHotkeyModifiers)
        if conferenceHotkeyKeyCode < 0 {
            conferenceHotkeys.stop()
            conferenceModifierMonitor.onEvent = { [conferenceController] event in
                if event == .toggle { conferenceController.toggle() }
            }
            conferenceModifierMonitor.start(modifier: mods, mode: .toggle)
        } else {
            conferenceModifierMonitor.stop()
            let binding = HotkeyBinding(keyCode: UInt16(conferenceHotkeyKeyCode), modifiers: mods)
            try? conferenceHotkeys.start(binding, mode: .toggle)
        }
    }

    private func applyTranscriptionOptions() {
        let langs = DictationLanguage.selectedIDs(dictationLanguages).map { Locale(identifier: $0) }
        controller.options = TranscriptionOptions(
            languages: langs,
            useVAD: trimSilence,
            preferredBackend: TranscriptionBackendID(rawValue: transcriptionEngine))   // "auto" → nil → best-available
        // Hands-free auto-stop only makes sense for Toggle mode (push-to-talk ends on key release).
        controller.autoStopOnSilence = autoStopOnSilence && hotkeyMode == .toggle
        // Warm the resolved backend so the first dictation is instant. Runs on launch (this is
        // called with initial: true) and re-warms whenever the engine/language changes.
        controller.prewarm()
    }

    private func startContext() async {
        contextProvider.start()
        for await context in contextProvider.changes {
            powerMode.update(context)
        }
    }
}

/// The app-menu "Settings…" item (⌘,) — brings the main window forward.
private struct OpenSettingsButton: View {
    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .whispOpenSettings, object: nil)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private struct MenuBarContent: View {
    @Environment(DictationController.self) private var controller
    @Environment(ConferenceController.self) private var conference
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
        Button(LocalizedStringKey(conference.state == .recording
                                  ? "Stop Conference Recording"
                                  : "Start Conference Recording")) {
            conference.toggle()
        }
        .disabled(conference.state == .transcribing)
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
