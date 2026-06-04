import Foundation

/// Dependency-free energy-threshold VAD with hangover-based endpointing.
/// The floor detector for the whisper path; native macOS 26 uses `SpeechDetector` instead.
public struct EnergyVAD: VoiceActivityDetector {
    public var threshold: Float
    public var hangoverChunks: Int

    private var silenceRun = 0
    private var speaking = false

    public init(threshold: Float = 0.012, hangoverChunks: Int = 8) {
        self.threshold = threshold
        self.hangoverChunks = hangoverChunks
    }

    public mutating func process(_ chunk: AudioChunk) -> VADDecision {
        if chunk.rms() >= threshold {
            speaking = true
            silenceRun = 0
            return .speech
        }
        silenceRun += 1
        if speaking && silenceRun >= hangoverChunks {
            speaking = false
            return .endpoint
        }
        return speaking ? .speech : .silence
    }
}
