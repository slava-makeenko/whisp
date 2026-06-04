import Foundation

/// Central plumbing for the three environment flags from the spec.
/// Compile-time flags are surfaced as static properties; runtime values are read lazily.
public enum BuildConfig: Sendable {

    /// `LOCAL_BUILD` — disables CloudKit sync and Sparkle auto-updates for ad-hoc builds.
    /// Honoured both as a compile flag (`-D LOCAL_BUILD`) and a runtime env var.
    public static var isLocalBuild: Bool {
        #if LOCAL_BUILD
        return true
        #else
        return ProcessInfo.processInfo.environment["LOCAL_BUILD"] != nil
        #endif
    }

    /// `ENABLE_NATIVE_SPEECH_ANALYZER` — compile-time flag that includes the native
    /// macOS 26 `SpeechAnalyzer` backend. Selection is still gated at runtime by an
    /// `@available(macOS 26, *)` check (see WhispASR).
    public static var nativeSpeechAnalyzerCompiledIn: Bool {
        #if ENABLE_NATIVE_SPEECH_ANALYZER
        return true
        #else
        return false
        #endif
    }

    /// `LLM_PROVIDER_API_KEY` — runtime cloud-enhancement key. Read once from the
    /// environment on first run and migrated into the Keychain; never logged, never
    /// written to settings backups.
    public static var llmProviderAPIKeyFromEnvironment: String? {
        ProcessInfo.processInfo.environment["LLM_PROVIDER_API_KEY"]
    }
}
