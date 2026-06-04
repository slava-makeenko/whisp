import Foundation

/// How the router chooses among ready backends (decision D2: best-available at runtime).
public struct SelectionPolicy: Sendable {
    /// Prefer native `SpeechAnalyzer` when it is ready (macOS 26+); otherwise it sorts last.
    public var preferNativeOnMacOS26: Bool
    /// A user-pinned backend; honoured only when that backend reports `.ready`.
    public var userOverride: TranscriptionBackendID?

    public init(preferNativeOnMacOS26: Bool = true, userOverride: TranscriptionBackendID? = nil) {
        self.preferNativeOnMacOS26 = preferNativeOnMacOS26
        self.userOverride = userOverride
    }
}

/// Picks the best available transcription backend. Pure selection logic — no external deps —
/// so it is fully unit-testable (see WhispASRTests).
public actor TranscriptionRouter {
    private let backends: [any TranscriptionService]
    private let policy: SelectionPolicy

    /// Default quality order; `preferNativeOnMacOS26 == false` demotes native to last.
    private static let priority: [TranscriptionBackendID] = [.nativeSpeech, .fluidAudioParakeet, .whisper, .whisperCpp]

    public init(backends: [any TranscriptionService], policy: SelectionPolicy = .init()) {
        self.backends = backends
        self.policy = policy
    }

    public func select(for options: TranscriptionOptions) async throws -> any TranscriptionService {
        // 0. A ready per-request preferred engine (from the Settings picker) wins.
        if let preferred = options.preferredBackend,
           let svc = backends.first(where: { $0.id == preferred }),
           await svc.availability(for: options) == .ready { return svc }

        // 1. A ready user override always wins.
        if let override = policy.userOverride,
           let svc = backends.first(where: { $0.id == override }) {
            if await svc.availability(for: options) == .ready { return svc }
        }

        // 2. Otherwise, first ready backend in (possibly native-demoted) priority order.
        let order: [TranscriptionBackendID] = policy.preferNativeOnMacOS26
            ? Self.priority
            : Self.priority.filter { $0 != .nativeSpeech } + [.nativeSpeech]

        for id in order {
            if let svc = backends.first(where: { $0.id == id }) {
                if await svc.availability(for: options) == .ready { return svc }
            }
        }

        throw TranscriptionError.noBackendAvailable
    }
}
