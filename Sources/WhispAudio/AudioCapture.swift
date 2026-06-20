import Foundation

/// A Sendable copy of PCM samples taken at the audio-tap boundary. `AVAudioPCMBuffer`
/// is not Sendable, so the capturer copies samples into this value before crossing actors.
public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let hostTime: UInt64

    public init(samples: [Float], sampleRate: Double, hostTime: UInt64 = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.hostTime = hostTime
    }

    /// Duration of this chunk in seconds (0 when the sample rate is unknown).
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    /// Root-mean-square amplitude (0...~1), used for VAD and UI levels.
    public func rms() -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// The pipeline's audio transport. 16 kHz mono Float is the canonical format for the
/// whisper/Parakeet backends; the native backend re-formats as needed.
public typealias AudioStream = AsyncThrowingStream<AudioChunk, Error>

public struct CaptureConfig: Sendable {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double = 16_000, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Microphone capture (implemented in Phase 2 with an `AVAudioEngine`-backed actor).
public protocol AudioCapturer: Sendable {
    func start(_ config: CaptureConfig) async throws -> AudioStream
    func stop() async
    /// RMS levels for the waveform UI.
    var levels: AsyncStream<Float> { get }
}
