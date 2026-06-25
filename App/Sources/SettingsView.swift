import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import WhispCore
import WhispPlatform
import WhispInput
import WhispLLM
import WhispASR

/// Wispr-Flow-style settings: a category sidebar on the left, a serif title + grouped cards on the
/// right. Each row is "title + description … control". Adapted to whisp's own features.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updater: UpdaterController
    @Query(sort: \DictionaryEntry.term) private var entries: [DictionaryEntry]
    @State private var newTerm = ""
    @State private var newReplacement = ""
    @State private var category: SettingsCategory = .general

    @AppStorage("dictationLanguages") private var dictationLanguages = "en-US"
    @AppStorage("enhancementStyle") private var enhancementStyle = "auto"
    @AppStorage("commandModeEnabled") private var commandModeEnabled = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("accentColor") private var accentColor = "clay"
    @AppStorage("fontStyle") private var fontStyle = "system"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    @AppStorage("enhancementProvider") private var enhancementProviderID = "openai"
    @AppStorage("enhancementModel") private var enhancementModel = ""
    @AppStorage("enhancementPrompt") private var enhancementPrompt = "Clean up grammar and punctuation."
    @AppStorage("firstLaunch") private var firstLaunch = Date.now.timeIntervalSince1970
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("hotkeyMode") private var hotkeyMode = HotkeyMode.toggle
    @AppStorage("conferenceHotkeyKeyCode") private var conferenceHotkeyKeyCode = 49
    @AppStorage("conferenceHotkeyModifiers") private var conferenceHotkeyModifiers = HotkeyModifiers([.control, .option]).rawValue
    @AppStorage("trimSilence") private var trimSilence = true
    @AppStorage("autoStopOnSilence") private var autoStopOnSilence = false
    @AppStorage("playSoundCues") private var playSoundCues = true
    @AppStorage("transcriptionEngine") private var transcriptionEngine = "auto"
    @AppStorage("audioInputDeviceUID") private var audioInputDeviceUID = ""
    @AppStorage("audioOutputDeviceUID") private var audioOutputDeviceUID = ""
    @AppStorage("forceLocalEnhancement") private var forceLocalEnhancement = false
    @State private var audioDevices = AudioDevicesModel()
    @State private var apiKey = ""
    @State private var licenseKey = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var customModelMode = false

    private let keychain = KeychainSecretStore()
    private var enhancementProvider: EnhancementProvider { EnhancementProvider(rawValue: enhancementProviderID) ?? .openAI }

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general, audio, appearance, ai, dictionary, data
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .general:    "General"
            case .audio:      "Audio"
            case .appearance: "Appearance"
            case .ai:         "AI"
            case .dictionary: "Dictionary"
            case .data:       "Data"
            }
        }
        var symbol: String {
            switch self {
            case .general:    "slider.horizontal.3"
            case .audio:      "waveform"
            case .appearance: "paintbrush"
            case .ai:         "sparkles"
            case .dictionary: "character.book.closed"
            case .data:       "lock.shield"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryTabBar
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    content
                }
                .padding(.horizontal, 34).padding(.bottom, 34).padding(.top, 32)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.windowBG)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.windowBG)
        .onAppear {
            apiKey = ((try? keychain.get(enhancementProvider.secretKey)) ?? nil) ?? ""
            licenseKey = ((try? keychain.get(.licenseKey)) ?? nil) ?? ""
            if enhancementModel.isEmpty { enhancementModel = enhancementProvider.defaultModel }
        }
    }

    // MARK: - Category tab bar

    private var categoryTabBar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsCategory.allCases) { cat in
                SettingsCategoryTab(
                    cat: cat,
                    selected: category == cat,
                    accent: Theme.accent
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { category = cat }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(Theme.windowBG)
    }

    private var versionString: String {
        "whisp " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch category {
        case .general:    generalContent
        case .audio:      audioContent
        case .appearance: appearanceContent
        case .ai:         aiContent
        case .dictionary: dictionaryContent
        case .data:       dataContent
        }
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingRow("Microphone", description: "Input device whisp records from (dictation & conference).") {
                    WispValueMenu(selection: $audioInputDeviceUID,
                                  options: deviceOptions(audioDevices.inputs,
                                                         defaultName: audioDevices.defaultInputName,
                                                         selected: audioInputDeviceUID))
                }
                RowDivider()
                SettingRow("Output", description: "Where whisp plays its start / stop sound cues.") {
                    WispValueMenu(selection: $audioOutputDeviceUID,
                                  options: deviceOptions(audioDevices.outputs,
                                                         defaultName: audioDevices.defaultOutputName,
                                                         selected: audioOutputDeviceUID))
                }
            }
            CardCaption("System Default follows macOS — the active device is shown in the menu. Picking a specific device affects whisp only, not the system.")
        }
        .onAppear { audioDevices.start() }
        .onDisappear { audioDevices.stop() }
    }

    /// `[(uid, name)]` for the device menu: a "System Default" row (showing the live default device),
    /// the connected devices, and — if the chosen device is unplugged — a placeholder so it still shows.
    private func deviceOptions(_ devices: [AudioDeviceInfo], defaultName: String, selected: String) -> [(String, String)] {
        var options: [(String, String)] = [("", defaultName.isEmpty ? "System Default" : "System Default — \(defaultName)")]
        options += devices.map { ($0.uid, $0.name) }
        if !selected.isEmpty, !devices.contains(where: { $0.uid == selected }) {
            options.append((selected, "Selected device (disconnected)"))
        }
        return options
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingRow("Mode", description: "How the dictation hotkey behaves.") {
                    WispValueMenu(selection: $hotkeyMode, options: HotkeyMode.allCases.map { ($0, modeName($0)) })
                }
                if hotkeyMode != .middleClick {
                    RowDivider()
                    SettingRow("Shortcut", description: "Or tap a single modifier (🌐 ⌃ ⌥ ⌘).") {
                        ShortcutField(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers)
                    }
                }
                RowDivider()
                SettingRow("Conference hotkey", description: "Start/stop recording a meeting (mic + system audio).") {
                    ShortcutField(keyCode: $conferenceHotkeyKeyCode, modifiers: $conferenceHotkeyModifiers)
                }
                RowDivider()
                SettingRow("Engine", description: "On-device speech-recognition model.") {
                    WispValueMenu(selection: $transcriptionEngine, options: [
                        ("auto", "Auto (best available)"),
                        (TranscriptionBackendID.fluidAudioParakeet.rawValue, "Parakeet"),
                        (TranscriptionBackendID.whisper.rawValue, "WhisperKit"),
                        (TranscriptionBackendID.whisperCpp.rawValue, "whisper.cpp"),
                    ])
                }
                RowDivider()
                SettingRow("Languages", description: "Recognized dictation languages.") {
                    languagesMenu
                }
            }
            SettingsGroup {
                SettingRow("Trim silence", description: "Sends only speech to the model, skipping pauses and noise.") {
                    Toggle("", isOn: $trimSilence).labelsHidden().toggleStyle(WisprToggleStyle())
                }
                RowDivider()
                SettingRow("Stop on silence", description: "In Toggle mode, ends dictation automatically after a natural pause.") {
                    Toggle("", isOn: $autoStopOnSilence).labelsHidden().toggleStyle(WisprToggleStyle())
                }
                RowDivider()
                SettingRow("Sound on start / stop", description: "Plays a short cue when recording begins and ends.") {
                    Toggle("", isOn: $playSoundCues).labelsHidden().toggleStyle(WisprToggleStyle())
                }
            }
            SettingsGroup {
                SettingRow("Updates", description: "Check for a new whisp release and follow Sparkle's install prompt.") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            updater.checkForUpdates()
                        } label: {
                            Text("Check for Updates…")
                                .font(.geist(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointingCursor()
                        .disabled(!updater.canCheckForUpdates)
                        .opacity(updater.canCheckForUpdates ? 1 : 0.5)

                        if let message = updater.status.settingsMessage {
                            Text(message)
                                .font(.geist(size: 10))
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 220, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var languagesMenu: some View {
        Menu {
            ForEach(DictationLanguage.all) { language in
                Toggle(language.name, isOn: Binding(
                    get: { DictationLanguage.selectedIDs(dictationLanguages).contains(language.id) },
                    set: { _ in dictationLanguages = DictationLanguage.toggle(language.id, in: dictationLanguages) }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(DictationLanguage.summary(dictationLanguages)).foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.up.chevron.down").font(.geist(size: 9)).foregroundStyle(Theme.secondaryText)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingRow("App Language", description: "Interface language. \"System\" follows macOS.") {
                    WispValueMenu(selection: $appLanguage, options: [
                        ("system", "System"), ("en", "English"), ("ru", "Русский"),
                    ])
                }
                RowDivider()
                SettingRow("Color scheme", description: "Light, dark, or follow the system.") {
                    Picker("", selection: $colorSchemeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                RowDivider()
                SettingRow("Accent color", description: "Used across the app.") {
                    HStack(spacing: 9) {
                        ForEach(AccentPalette.allCases) { palette in
                            Button { accentColor = palette.rawValue } label: {
                                Circle().fill(palette.color).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Theme.primaryText.opacity(0.85),
                                                                   lineWidth: accentColor == palette.rawValue ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain).pointingCursor()
                        }
                    }
                }
                RowDivider()
                SettingRow("Font", description: "App-wide typography.") {
                    WispValueMenu(selection: $fontStyle, options: AppFontStyle.allCases.map { ($0.rawValue, $0.name) })
                }
            }
        }
    }

    private var currentStyle: EnhancementStyle { EnhancementStyle(rawValue: enhancementStyle) ?? .auto }

    /// Cloud enhancement is "Active" only when the selected provider has a key AND the user hasn't
    /// switched to Local (the dashboard Local/Cloud toggle). Otherwise everything runs on-device.
    private var cloudActive: Bool { !apiKey.isEmpty && !forceLocalEnhancement }

    private var aiContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Status + local cleanup
            SettingsGroup {
                SettingRow("Text enhancement", description: cloudActive
                    ? "Active — \(enhancementProvider.displayName) rewrites your transcribed text. Audio never leaves your Mac."
                    : "Local — whisp cleans up dictation on-device. Add a cloud key below for smarter formatting.") {
                    if cloudActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.geist(size: 13, weight: .medium)).foregroundStyle(.green)
                    } else {
                        Label("Local", systemImage: "checkmark.shield.fill")
                            .font(.geist(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    }
                }
                if !cloudActive {
                    RowDivider()
                    SettingRow("Clean up dictation", description: "Remove filler words and fix punctuation on-device.") {
                        Toggle("", isOn: Binding(
                            get: { currentStyle != .raw },
                            set: { enhancementStyle = $0 ? "cleanUp" : "raw" }))
                            .labelsHidden().toggleStyle(WisprToggleStyle())
                    }
                }
            }

            // Cloud enhancement (optional) — extra rows appear only once a key is connected.
            SettingsGroup {
                SettingRow("Cloud provider", description: "Optional. Pick a provider and add its key to enable LLM formatting.") {
                    WispValueMenu(selection: $enhancementProviderID,
                                  options: EnhancementProvider.allCases.map { ($0.rawValue, $0.displayName) })
                }
                RowDivider()
                SettingRow("API key", description: testMessage.map { LocalizedStringKey($0) }) {
                    HStack(spacing: 8) {
                        SecureField("\(enhancementProvider.displayName) key", text: $apiKey)
                            .onChange(of: apiKey) { _, value in
                                try? keychain.set(value.isEmpty ? nil : value, for: enhancementProvider.secretKey)
                                testMessage = nil; testOK = false   // stale result no longer applies
                            }
                            .wispField().frame(width: 190)
                        Button("Test") { Task { await testKey() } }
                            .buttonStyle(WisprButtonStyle())
                            .disabled(apiKey.isEmpty || testing)
                        if testing {
                            ProgressView().controlSize(.small)
                        } else if testMessage != nil {
                            Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.geist(size: 16))
                                .foregroundStyle(testOK ? .green : .red)
                        }
                    }
                }
                if cloudActive {
                    RowDivider()
                    SettingRow("Model") {
                        WispValueMenu(selection: modelPickerBinding,
                                      options: enhancementProvider.models.map { ($0, $0) } + [("__custom__", "Custom…")])
                    }
                    if showCustomModelField {
                        RowDivider()
                        SettingRow("Model id") { TextField("", text: $enhancementModel).wispField().frame(width: 200) }
                    }
                    RowDivider()
                    SettingRow("Formatting", description: "How the model rewrites your dictation.") {
                        WispValueMenu(selection: $enhancementStyle,
                                      options: EnhancementStyle.allCases.map { ($0.rawValue, $0.name) })
                    }
                    if currentStyle == .custom {
                        RowDivider()
                        SettingRow("Custom prompt") {
                            TextField("", text: $enhancementPrompt, axis: .vertical).wispField().frame(width: 240)
                        }
                    }
                }
            }

            // Command Mode needs the cloud LLM — only shown when it can actually run.
            if cloudActive {
                SettingsGroup {
                    SettingRow("Command Mode", description: "Select text in any app, dictate an instruction — whisp replaces it with the AI-edited result.") {
                        Toggle("", isOn: $commandModeEnabled).labelsHidden().toggleStyle(WisprToggleStyle())
                    }
                }
            }
        }
        .onChange(of: enhancementProviderID) { _, _ in
            apiKey = ((try? keychain.get(enhancementProvider.secretKey)) ?? nil) ?? ""
            enhancementModel = enhancementProvider.defaultModel
            customModelMode = false
            testMessage = nil
        }
    }

    private var dictionaryContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                if entries.isEmpty {
                    Text("No terms yet — add one below to auto-replace it in transcriptions.")
                        .font(.geist(size: 14)).foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        Text(entry.term).foregroundStyle(Theme.primaryText)
                        Image(systemName: "arrow.right").font(.geist(size: 11)).foregroundStyle(Theme.secondaryText)
                        Text(entry.replacement.isEmpty ? "—" : entry.replacement).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button { deleteEntry(entry) } label: { Image(systemName: "trash").font(.geist(size: 12)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                    }
                    .padding(.vertical, 12)
                    RowDivider()
                }
                HStack(spacing: 8) {
                    TextField("Term", text: $newTerm).wispField()
                    TextField("Replacement", text: $newReplacement).wispField()
                    Button("Add", action: addEntry).buttonStyle(WisprButtonStyle()).disabled(newTerm.isEmpty)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var dataContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingRow("Export settings", description: "Save your preferences to a file. API keys and the license are never exported.") {
                    Button("Export…", action: exportSettings).buttonStyle(WisprButtonStyle())
                }
                RowDivider()
                SettingRow("Import settings") {
                    Button("Import…", action: importSettings).buttonStyle(WisprButtonStyle())
                }
            }
            SettingsGroup {
                SettingRow("License", description: LocalizedStringKey(licenseLabel)) {
                    Button("Activate") {
                        try? keychain.set(licenseKey.isEmpty ? nil : licenseKey, for: .licenseKey)
                    }
                    .buttonStyle(WisprButtonStyle()).disabled(licenseKey.isEmpty)
                }
                RowDivider()
                SettingRow("License key") {
                    SecureField("", text: $licenseKey).wispField().frame(width: 220)
                }
            }
        }
    }

    // MARK: - Logic

    private func modeName(_ mode: HotkeyMode) -> String {
        switch mode {
        case .toggle:      "Toggle"
        case .pushToTalk:  "Push-to-Talk"
        case .hybridHold:  "Hybrid (double-tap = toggle, hold = talk)"
        case .middleClick: "Middle Mouse Button"
        }
    }

    private var isCustomModel: Bool { !enhancementProvider.models.contains(enhancementModel) }
    private var showCustomModelField: Bool { customModelMode || isCustomModel }

    private var modelPickerBinding: Binding<String> {
        Binding(
            get: { (customModelMode || isCustomModel) ? "__custom__" : enhancementModel },
            set: { value in
                if value == "__custom__" { customModelMode = true }
                else { customModelMode = false; enhancementModel = value }
            })
    }

    @MainActor
    private func testKey() async {
        testing = true
        testMessage = nil
        defer { testing = false }
        do {
            _ = try await URLSessionLLMEnhancer(apiKey: apiKey)
                .enhance("ping", prompt: "Reply with OK.",
                         provider: enhancementProvider.llmProvider(model: enhancementModel))
            testOK = true
            testMessage = "Key works"
        } catch let error as LLMError {
            testOK = false
            switch error {
            case .badResponse(let code): testMessage = "HTTP \(code)"
            case .emptyResponse:         testMessage = "Empty response"
            }
        } catch {
            testOK = false
            testMessage = error.localizedDescription
        }
    }

    private var licenseState: LicenseState {
        LicenseEvaluator.evaluate(firstLaunch: Date(timeIntervalSince1970: firstLaunch),
                                  licenseKey: licenseKey.isEmpty ? nil : licenseKey)
    }

    private var licenseLabel: String {
        switch licenseState {
        case .trial(let days): "Trial — \(days) days left"
        case .licensed:        "Licensed"
        case .expired:         "Trial expired"
        }
    }

    private func addEntry() {
        modelContext.insert(DictionaryEntry(term: newTerm, replacement: newReplacement))
        try? modelContext.save()
        newTerm = ""
        newReplacement = ""
    }

    private func deleteEntry(_ entry: DictionaryEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func exportSettings() {
        let backup = SettingsBackup(enhancementEnabled: currentStyle != .raw, defaultPrompt: enhancementPrompt)
        guard let data = try? backup.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "whisp-settings.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let backup = try? SettingsBackup.from(data) else { return }
        enhancementStyle = backup.enhancementEnabled ? "auto" : "raw"
        enhancementPrompt = backup.defaultPrompt
    }
}

// MARK: - Wispr-style settings components

/// A single tab button in the Settings tab bar.
private struct SettingsCategoryTab: View {
    let cat: SettingsView.SettingsCategory
    let selected: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: cat.symbol)
                        .font(.geist(size: 12, weight: selected ? .semibold : .regular))
                    Text(cat.title)
                        .font(.geist(size: 13, weight: selected ? .semibold : .regular))
                }
                .foregroundStyle(
                    selected ? Theme.primaryText
                             : (hovering ? Theme.primaryText.opacity(0.7) : Theme.secondaryText))

                // Accent underline for selected tab
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(selected ? accent : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }
}

/// A rounded group that holds setting rows — adapts fill to light/dark mode.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 20)
            .background(Theme.groupBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One row: bold title + optional grey description on the left, a control on the right.
private struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey?
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, description: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.geist(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                if let description {
                    Text(description).font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowDivider: View {
    var body: some View { Divider().overlay(Theme.hairline) }
}

/// Wide pill toggle — adapts to light/dark: primaryText fill when on (dark in light, light in dark).
private struct WisprToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.primaryText : Theme.groupBG)
                    .frame(width: 46, height: 28)
                Circle().fill(Theme.cardBG).frame(width: 23, height: 23)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .padding(2.5)
            }
        }
        .buttonStyle(.plain).pointingCursor()
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
    }
}

/// Rounded grey button — background adapts to light/dark.
private struct WisprButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(size: 14, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.groupBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// A label-less menu showing the current value as dark text + chevron (for the right side of a row).
private struct WispValueMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { opt in
                Button { selection = opt.value } label: {
                    if opt.value == selection { Label(LocalizedStringKey(opt.label), systemImage: "checkmark") }
                    else { Text(LocalizedStringKey(opt.label)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(options.first { $0.value == selection }?.label ?? ""))
                    .foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.up.chevron.down").font(.geist(size: 9)).foregroundStyle(Theme.secondaryText)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}
