import Foundation

public enum VADDecision: Sendable, Equatable {
    case speech
    case silence
    /// End of an utterance — the orchestrator may finalize the current segment.
    case endpoint
}

/// Voice-activity detection. Phase 2 ships `EnergyVAD` (dependency-free floor);
/// `SpeechDetectorVAD` (macOS 26) and FluidAudio's VAD arrive with their backends.
/// Streaming + stateful → `mutating`; owned and driven within a single isolation domain.
public protocol VoiceActivityDetector {
    mutating func process(_ chunk: AudioChunk) -> VADDecision
    /// Clear any accumulated speech/silence state before a new session.
    mutating func reset()
}

public extension VoiceActivityDetector {
    mutating func reset() {}   // stateless detectors need no reset
}
