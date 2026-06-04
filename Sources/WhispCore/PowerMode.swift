import Foundation
import Observation
import WhispPlatform
import WhispASR

/// A single match condition for a Power Mode profile.
public struct ContextRule: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case bundleID, urlHost }
    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public func matches(_ context: AppContext) -> Bool {
        switch kind {
        case .bundleID:
            return context.bundleID == value
        case .urlHost:
            guard let host = context.url?.host() else { return false }
            return host.localizedCaseInsensitiveContains(value)
        }
    }
}

/// A context-activated profile: when any rule matches the active app/URL, its settings apply.
public struct PowerProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var rules: [ContextRule]
    public var locale: String?                          // BCP-47; overrides the dictation locale
    public var backendOverride: TranscriptionBackendID?
    public var enhancementPrompt: String?               // applied in Phase 10 (AI enhancement)
    public var enableEnhancement: Bool

    public init(id: UUID = UUID(), name: String, rules: [ContextRule],
                locale: String? = nil, backendOverride: TranscriptionBackendID? = nil,
                enhancementPrompt: String? = nil, enableEnhancement: Bool = false) {
        self.id = id
        self.name = name
        self.rules = rules
        self.locale = locale
        self.backendOverride = backendOverride
        self.enhancementPrompt = enhancementPrompt
        self.enableEnhancement = enableEnhancement
    }

    public func matches(_ context: AppContext) -> Bool {
        rules.contains { $0.matches(context) }
    }
}

/// Pure resolver: the first profile whose any rule matches the context wins.
public struct PowerModeResolver: Sendable {
    public init() {}
    public func resolve(_ context: AppContext, profiles: [PowerProfile]) -> PowerProfile? {
        profiles.first { $0.matches(context) }
    }
}

/// Tracks the active context and resolved profile, firing `onChange` when the profile changes.
@MainActor
@Observable
public final class PowerModeManager {
    public private(set) var activeContext = AppContext(bundleID: nil, appName: nil, url: nil)
    public private(set) var activeProfile: PowerProfile?
    public var profiles: [PowerProfile]

    @ObservationIgnored private let resolver = PowerModeResolver()
    @ObservationIgnored private let onChange: (@MainActor (PowerProfile?) -> Void)?

    public init(profiles: [PowerProfile] = [], onChange: (@MainActor (PowerProfile?) -> Void)? = nil) {
        self.profiles = profiles
        self.onChange = onChange
    }

    public func update(_ context: AppContext) {
        activeContext = context
        let resolved = resolver.resolve(context, profiles: profiles)
        if resolved?.id != activeProfile?.id {
            activeProfile = resolved
            onChange?(resolved)
        }
    }
}
