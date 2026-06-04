import Foundation
import WhispASR

/// JSON-serializable snapshot of user settings for export/import.
/// API keys and the license key are **intentionally excluded** (no such fields exist here).
public struct SettingsBackup: Codable, Sendable, Equatable {
    public var profiles: [PowerProfile]
    public var hotkeyKeyCode: UInt16?
    public var hotkeyModifiers: Int
    public var enhancementEnabled: Bool
    public var defaultPrompt: String

    public init(profiles: [PowerProfile] = [], hotkeyKeyCode: UInt16? = nil, hotkeyModifiers: Int = 0,
                enhancementEnabled: Bool = false, defaultPrompt: String = "") {
        self.profiles = profiles
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.enhancementEnabled = enhancementEnabled
        self.defaultPrompt = defaultPrompt
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func from(_ data: Data) throws -> SettingsBackup {
        try JSONDecoder().decode(SettingsBackup.self, from: data)
    }
}
