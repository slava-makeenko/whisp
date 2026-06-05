import SwiftUI
import AppKit

/// A per-app formatting rule: dictating into `bundleID` uses `style` instead of the global default.
/// Stored as JSON in AppStorage so both this view and the post-processor can read it.
struct AppEnhancementRule: Codable, Identifiable {
    var bundleID: String
    var appName: String
    var style: String   // EnhancementStyle.rawValue
    var id: String { bundleID }

    static func decode(_ json: String) -> [AppEnhancementRule] {
        (try? JSONDecoder().decode([AppEnhancementRule].self, from: Data(json.utf8))) ?? []
    }

    static func encode(_ rules: [AppEnhancementRule]) -> String {
        guard let data = try? JSONEncoder().encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// "Power Mode" — give specific apps their own formatting style (casual for chat, formal for mail…).
struct PowerModeView: View {
    @AppStorage("enhancementAppRules") private var rulesJSON = "[]"

    private var rules: [AppEnhancementRule] { AppEnhancementRule.decode(rulesJSON) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader("Power Mode")

                CardSection("Per-app formatting") {
                    if rules.isEmpty {
                        Text("No rules yet. Add an app below to give it its own formatting style.")
                            .font(.callout).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(rules) { rule in
                        HStack(spacing: 12) {
                            Text(rule.appName)
                            Spacer()
                            Picker("", selection: styleBinding(for: rule.bundleID)) {
                                ForEach(EnhancementStyle.allCases) { Text(LocalizedStringKey($0.name)).tag($0.rawValue) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Button { deleteRule(rule.bundleID) } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                        }
                        if rule.id != rules.last?.id { Divider().overlay(Theme.hairline) }
                    }
                    Menu("Add app…") {
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button(app.name) { addRule(bundleID: app.bundleID, name: app.name) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                CardCaption("In Auto mode, dictating into one of these apps uses its style instead of the per-app heuristic. A specific mode (chosen on Home or in the menu bar) overrides Auto entirely. Only text is sent to an LLM — never audio.")
            }
            .padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
    }

    private var runningApps: [(bundleID: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        let existing = Set(rules.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> (bundleID: String, name: String)? in
                guard app.activationPolicy == .regular,
                      let id = app.bundleIdentifier, id != own, !existing.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func styleBinding(for bundleID: String) -> Binding<String> {
        Binding(
            get: { rules.first { $0.bundleID == bundleID }?.style ?? "cleanUp" },
            set: { newStyle in
                var updated = rules
                if let index = updated.firstIndex(where: { $0.bundleID == bundleID }) {
                    updated[index].style = newStyle
                    rulesJSON = AppEnhancementRule.encode(updated)
                }
            })
    }

    private func addRule(bundleID: String, name: String) {
        var updated = rules
        guard !updated.contains(where: { $0.bundleID == bundleID }) else { return }
        updated.append(AppEnhancementRule(bundleID: bundleID, appName: name, style: "cleanUp"))
        rulesJSON = AppEnhancementRule.encode(updated)
    }

    private func deleteRule(_ bundleID: String) {
        rulesJSON = AppEnhancementRule.encode(rules.filter { $0.bundleID != bundleID })
    }
}
