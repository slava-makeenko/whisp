import Foundation

/// User-facing update state distilled from Sparkle callbacks.
/// Kept in WhispCore so the labels used by the sidebar/settings can be tested
/// without loading Sparkle or the macOS app target.
public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case available(version: String)
    case downloading(progress: Double)
    case extracting(progress: Double)
    case readyToInstall(version: String?)
    case installing
    case failed(String)

    public var isSidebarVisible: Bool {
        switch self {
        case .idle, .checking, .available, .failed:
            false
        case .downloading, .extracting, .readyToInstall, .installing:
            true
        }
    }

    public var sidebarMessage: String? {
        switch self {
        case .idle, .checking, .available, .failed:
            nil
        case .downloading(let progress):
            "Downloading update… \(Self.percent(progress))"
        case .extracting(let progress):
            "Preparing update… \(Self.percent(progress))"
        case .readyToInstall(let version):
            if let version, !version.isEmpty {
                "Update \(version) is ready"
            } else {
                "Update is ready"
            }
        case .installing:
            "Installing update…"
        }
    }

    public var settingsMessage: String? {
        switch self {
        case .idle:
            nil
        case .checking:
            "Checking for updates…"
        case .available(let version):
            "Update \(version) is available. Follow the Sparkle prompt to download it."
        case .downloading(let progress):
            "Downloading update… \(Self.percent(progress))"
        case .extracting(let progress):
            "Preparing update… \(Self.percent(progress))"
        case .readyToInstall(let version):
            if let version, !version.isEmpty {
                "Update \(version) is ready to install."
            } else {
                "Update is ready to install."
            }
        case .installing:
            "Installing update…"
        case .failed(let message):
            message
        }
    }

    public var actionTitle: String? {
        if case .readyToInstall = self { "Restart to Update" } else { nil }
    }

    private static func percent(_ progress: Double) -> String {
        let clamped = min(max(progress, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}
