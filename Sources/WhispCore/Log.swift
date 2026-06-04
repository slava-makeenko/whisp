import os

/// Shared loggers. Secrets must always be interpolated with `privacy: .private`
/// (e.g. `Log.llm.debug("key=\(key, privacy: .private)")`) — never `.public`.
public enum Log {
    public static let general = Logger(subsystem: AppConstants.bundleIdentifier, category: "general")
    public static let audio   = Logger(subsystem: AppConstants.bundleIdentifier, category: "audio")
    public static let asr     = Logger(subsystem: AppConstants.bundleIdentifier, category: "asr")
    public static let input   = Logger(subsystem: AppConstants.bundleIdentifier, category: "input")
    public static let data    = Logger(subsystem: AppConstants.bundleIdentifier, category: "data")
}
