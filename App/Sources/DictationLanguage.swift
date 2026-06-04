import Foundation

/// A dictation language offered in the menu / settings (BCP-47 id + native display name).
struct DictationLanguage: Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [DictationLanguage] = [
        .init(id: "en-US", name: "English (US)"),
        .init(id: "ru-RU", name: "Русский"),
        .init(id: "de-DE", name: "Deutsch"),
        .init(id: "fr-FR", name: "Français"),
        .init(id: "es-ES", name: "Español"),
        .init(id: "it-IT", name: "Italiano"),
        .init(id: "pt-BR", name: "Português (BR)"),
        .init(id: "nl-NL", name: "Nederlands"),
        .init(id: "uk-UA", name: "Українська"),
        .init(id: "ja-JP", name: "日本語"),
        .init(id: "zh-CN", name: "中文"),
    ]

    // Multi-select is stored as a comma-separated list of ids in AppStorage.
    static func selectedIDs(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    static func toggle(_ id: String, in raw: String) -> String {
        var ids = selectedIDs(raw)
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        return ids.joined(separator: ",")
    }

    static func summary(_ raw: String) -> String {
        let names = selectedIDs(raw).compactMap { id in all.first { $0.id == id }?.name }
        return names.isEmpty ? "Auto-detect" : names.joined(separator: ", ")
    }
}
