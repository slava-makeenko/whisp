import Foundation
@preconcurrency import FluidAudio

/// One contiguous span of speech attributed to a speaker.
public struct DiarizedSegment: Sendable, Equatable {
    public let speakerId: String
    public let start: Double   // seconds
    public let end: Double
    public init(speakerId: String, start: Double, end: Double) {
        self.speakerId = speakerId; self.start = start; self.end = end
    }
}

/// On-device speaker diarization via FluidAudio (CoreML segmentation + embedding models). Splits a
/// 16 kHz mono recording into per-speaker time spans — used to label remote participants in
/// Conference Mode. Models download on first use (cached afterwards).
public actor SpeakerDiarizer {
    private var manager: DiarizerManager?

    public init() {}

    /// Returns the speaker segments for `samples` (16 kHz mono), sorted by start time. Throws if the
    /// models can't be loaded; an empty array means no speech was found.
    public func diarize(_ samples: [Float]) async throws -> [DiarizedSegment] {
        if manager == nil {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            self.manager = manager
        }
        guard let manager else { return [] }
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        return result.segments
            .map { DiarizedSegment(speakerId: $0.speakerId,
                                   start: Double($0.startTimeSeconds),
                                   end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }
}
