import Foundation

/// The frontmost app + (for browsers) the active tab URL — the input to Power Mode.
public struct AppContext: Sendable, Equatable {
    public let bundleID: String?
    public let appName: String?
    public let url: URL?
    public init(bundleID: String?, appName: String?, url: URL?) {
        self.bundleID = bundleID; self.appName = appName; self.url = url
    }
}

/// Tracks the active app/URL. Implemented in Phase 6 (NSWorkspace + per-browser URL detection).
// VERIFY-PM-1: per-browser front-tab URL via AppleScript + Automation TCC consent; AX fallback.
public protocol ContextProvider: Sendable {
    func current() async -> AppContext
    var changes: AsyncStream<AppContext> { get }
}
