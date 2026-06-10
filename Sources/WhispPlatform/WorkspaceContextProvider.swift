import AppKit
import Foundation

/// Tracks the frontmost app via NSWorkspace and, for known browsers, the front-tab URL.
/// `@unchecked Sendable`: the observer and stream are configured/torn down on the main thread.
public final class WorkspaceContextProvider: ContextProvider, @unchecked Sendable {
    public nonisolated let changes: AsyncStream<AppContext>
    private let continuation: AsyncStream<AppContext>.Continuation
    private var observer: NSObjectProtocol?

    public init() {
        (changes, continuation) = AsyncStream.makeStream(of: AppContext.self)
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    public func current() async -> AppContext {
        await MainActor.run { Self.snapshot() }
    }

    @MainActor
    public func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.continuation.yield(Self.snapshot())
            }
        }
        continuation.yield(Self.snapshot())
    }

    @MainActor
    public func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    @MainActor
    private static func snapshot() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        return AppContext(bundleID: bundleID,
                          appName: app?.localizedName,
                          url: BrowserURL.frontTab(bundleID: bundleID))
    }
}

/// Reads the active tab URL of known browsers via AppleScript.
// VERIFY-PM-1: per-browser scripts + Automation (Apple Events) TCC consent; runs synchronously
// on the main thread only for recognized browsers (skipped otherwise to avoid UI stalls).
enum BrowserURL {
    static func frontTab(bundleID: String?) -> URL? {
        guard let bundleID, let source = scripts[bundleID] else { return nil }
        // This runs synchronously on the main thread; a hung/modal browser would otherwise
        // block the UI indefinitely. Bound the Apple Event to 2 seconds.
        let guarded = "with timeout of 2 seconds\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: guarded) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        guard error == nil, let string = output.stringValue, let url = URL(string: string) else { return nil }
        return url
    }

    private static let scripts: [String: String] = [
        "com.apple.Safari": #"tell application "Safari" to return URL of front document"#,
        "com.google.Chrome": #"tell application "Google Chrome" to return URL of active tab of front window"#,
        "com.microsoft.edgemac": #"tell application "Microsoft Edge" to return URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application "Arc" to return URL of active tab of front window"#,
        "com.brave.Browser": #"tell application "Brave Browser" to return URL of active tab of front window"#,
    ]
}
