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
    @Query(sort: \DictionaryEntry.term) private var entries: [DictionaryEntry]
    @State private var newTerm = ""
    @State private var newReplacement = ""
    @State private var category: SettingsCategory = .general

    @AppStorage("dictationLanguages") private var dictationLanguages = "en-US"
    @AppStorage("enhancementStyle") private var enhancementStyle = "auto"
    @AppStorage("commandModeEnabled") private var commandModeEnabled = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("accentColor") private var accentColor = "violet"
    @AppStorage("fontStyle") private var fontStyle = "system"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    @AppStorage("enhancementProvider") private var enhancementProviderID = "openai"
    @AppStorage("enhancementModel") private var enhancementModel = ""
    @AppStorage("enhancementPrompt") private var enhancementPrompt = "Clean up grammar and punctuation."
    @AppStorage("firstLaunch") private var firstLaunch = Date.now.timeIntervalSince1970
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("hotkeyMode") private var hotkeyMode = HotkeyMode.toggle
    @AppStorage("trimSilence") private var trimSilence = true
    @AppStorage("playSoundCues") private var playSoundCues = true
    @AppStorage("transcriptionEngine") private var transcriptionEngine = "auto"
    @State private var apiKey = ""
    @State private var licenseKey = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var customModelMode = false

    private let keychain = KeychainSecretStore()
    private var enhancementProvider: EnhancementProvider { EnhancementProvider(rawValue: enhancementProviderID) ?? .openAI }

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general, appearance, ai, dictionary, data
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .general:    "General"
            case .appearance: "Appearance"
            case .ai:         "AI"
            case .dictionary: "Dictionary"
            case .data:       "Data"
            }
        }
        var symbol: String {
            switch self {
            case .general:    "slider.horizontal.3"
            case .appearance: "paintbrush"
            case .ai:         "sparkles"
            case .dictionary: "character.book.closed"
            case .data:       "lock.shield"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(category.title)
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.primaryText)
                    content
                }
                .padding(34)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.cardBG)
        }
        .background(Theme.windowBG)
        .onAppear {
            apiKey = ((try? keychain.get(enhancementProvider.secretKey)) ?? nil) ?? ""
            licenseKey = ((try? keychain.get(.licenseKey)) ?? nil) ?? ""
            if enhancementModel.isEmpty { enhancementModel = enhancementProvider.defaultModel }
        }
    }

    // MARK: - Category sidebar

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("SETTINGS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            ForEach(SettingsCategory.allCases) { categoryRow($0) }
            Spacer()
            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12).padding(.bottom, 4)
        }
        .padding(14)
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBG)
    }

    private func categoryRow(_ cat: SettingsCategory) -> some View {
        Button { category = cat } label: {
            HStack(spacing: 11) {
                Image(systemName: cat.symbol).font(.system(size: 14)).frame(width: 22)
                Text(cat.title).font(.system(size: 15, weight: category == cat ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(category == cat ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(category == cat ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingCursor()
    }

    private var versionString: String {
        "whisp " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch category {
        case .general:    generalContent
        case .appearance: appearanceContent
        case .ai:         aiContent
        case .dictionary: dictionaryContent
        case .data:       dataContent
        }
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
                SettingRow("Sound on start / stop", description: "Plays a short cue when recording begins and ends.") {
                    Toggle("", isOn: $playSoundCues).labelsHidden().toggleStyle(WisprToggleStyle())
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
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
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

    private var aiContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingRow("Formatting", description: "Auto adapts to the focused app. Clean-up works on-device; the rest use the LLM below.") {
                    WispValueMenu(selection: $enhancementStyle, options: EnhancementStyle.allCases.map { ($0.rawValue, $0.name) })
                }
                if currentStyle != .raw {
                    RowDivider()
                    SettingRow("Provider") {
                        WispValueMenu(selection: $enhancementProviderID,
                                      options: EnhancementProvider.allCases.map { ($0.rawValue, $0.displayName) })
                    }
                    RowDivider()
                    SettingRow("API key", description: testMessage.map { LocalizedStringKey($0) }) {
                        HStack(spacing: 8) {
                            SecureField("\(enhancementProvider.displayName) key", text: $apiKey)
                                .onChange(of: apiKey) { _, value in
                                    try? keychain.set(value.isEmpty ? nil : value, for: enhancementProvider.secretKey)
                                }
                                .wispField().frame(width: 190)
                            Button("Test") { Task { await testKey() } }
                                .buttonStyle(WisprButtonStyle())
                                .disabled(apiKey.isEmpty || testing)
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    RowDivider()
                    SettingRow("Model") {
                        WispValueMenu(selection: modelPickerBinding,
                                      options: enhancementProvider.models.map { ($0, $0) } + [("__custom__", "Custom…")])
                    }
                    if showCustomModelField {
                        RowDivider()
                        SettingRow("Model id") { TextField("", text: $enhancementModel).wispField().frame(width: 200) }
                    }
                    if currentStyle == .custom {
                        RowDivider()
                        SettingRow("Custom prompt") {
                            TextField("", text: $enhancementPrompt, axis: .vertical).wispField().frame(width: 240)
                        }
                    }
                }
                RowDivider()
                SettingRow("Command Mode", description: "Select text in any app, dictate an instruction — whisp replaces it with the AI-edited result.") {
                    Toggle("", isOn: $commandModeEnabled).labelsHidden().toggleStyle(WisprToggleStyle())
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
                        .font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        Text(entry.term).foregroundStyle(Theme.primaryText)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(Theme.secondaryText)
                        Text(entry.replacement.isEmpty ? "—" : entry.replacement).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button { deleteEntry(entry) } label: { Image(systemName: "trash").font(.system(size: 12)) }
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
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                if let description {
                    Text(description).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
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
            .font(.system(size: 14, weight: .medium))
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
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}
