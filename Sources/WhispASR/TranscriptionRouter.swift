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
        guard let best = await orderedReadyBackends(for: options).first else {
            throw TranscriptionError.noBackendAvailable
        }
        return best
    }

    /// The ready backends in selection order (best first), deduplicated. `select` returns the first;
    /// callers wanting fall-through (try the next when `prepare()` fails) iterate the whole list.
    public func orderedReadyBackends(for options: TranscriptionOptions) async -> [any TranscriptionService] {
        // Build the candidate order first (no awaits): preferred → user override → priority order.
        var candidateIDs: [TranscriptionBackendID] = []
        if let preferred = options.preferredBackend { candidateIDs.append(preferred) }
        if let override = policy.userOverride { candidateIDs.append(override) }
        // Native SpeechAnalyzer pins to a single locale, so for a genuine multi-language request
        // (2+ selected) it would silently honour only the first. Demote it to last in that case so a
        // multilingual-capable backend (Parakeet/Whisper auto-detect) wins — unless the user
        // explicitly pinned an engine above (preferredBackend / userOverride), which still leads.
        let multilingual = options.languages.count > 1
        candidateIDs += (policy.preferNativeOnMacOS26 && !multilingual)
            ? Self.priority
            : Self.priority.filter { $0 != .nativeSpeech } + [.nativeSpeech]

        // Then keep the ready ones, deduplicated, preserving order.
        var ordered: [any TranscriptionService] = []
        var seen = Set<TranscriptionBackendID>()
        for id in candidateIDs {
            guard seen.insert(id).inserted, let svc = backends.first(where: { $0.id == id }) else { continue }
            if await svc.availability(for: options) == .ready { ordered.append(svc) }
        }
        return ordered
    }
}
