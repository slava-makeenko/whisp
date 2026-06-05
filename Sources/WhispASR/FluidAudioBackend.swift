import Foundation
import WhispAudio
@preconcurrency import FluidAudio

/// Parakeet (TDT v3 multilingual / v2 English) via FluidAudio CoreML on the ANE.
/// `stream` buffers to a final result; true low-latency streaming would use FluidAudio's
/// SlidingWindow / EOU managers and is a later refinement.
///
/// API confirmed against the FluidAudio source checkout (`AsrManager`, `AsrModels`,
/// `TdtDecoderState`, `ASRResult`). Resolves VERIFY-ASR-2.
public actor FluidAudioBackend: TranscriptionService {
    public nonisolated let id = TranscriptionBackendID.fluidAudioParakeet

    private var manager: AsrManager?

    public init() {}

    public func availability(for options: TranscriptionOptions) async -> BackendAvailability {
        .ready   // Parakeet weights download during prepare(); model-status UI is a later phase.
    }

    public func prepare(_ options: TranscriptionOptions) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        manager = AsrManager(models: models)
    }

    // Synchronous protocol requirement → must be `nonisolated` on an actor; the work happens
    // in a child task that hops back in via `await self.transcribe(samples:)`.
    public nonisolated func stream(_ audio: WhispAudio.AudioStream, options: TranscriptionOptions)
        -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var samples: [Float] = []
                    for try await chunk in audio { samples.append(contentsOf: chunk.samples) }
                    let text = try await self.transcribe(samples: samples)
                    continuation.yield(.final(TranscriptionResult(text: text, segments: [], backend: self.id)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
        guard let manager else { throw TranscriptionError.modelMissing }
        let layers = await manager.decoderLayerCount
        var state = try TdtDecoderState(decoderLayers: layers)
        let result = try await manager.transcribe(url, decoderState: &state)
        return TranscriptionResult(text: result.text, segments: [], backend: id)
    }

    private func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriptionError.modelMissing }
        guard !samples.isEmpty else { return "" }
        // Parakeet rejects clips shorter than ~0.3 s (ASRError.invalidAudioData); pad a short
        // utterance with trailing silence so brief words still transcribe.
        let minSamples = 8000   // 0.5 s at 16 kHz — comfortably above the engine's minimum
        let frames = samples.count >= minSamples
            ? samples
            : samples + Array(repeating: 0, count: minSamples - samples.count)
        let layers = await manager.decoderLayerCount
        var state = try TdtDecoderState(decoderLayers: layers)
        let result = try await manager.transcribe(frames, decoderState: &state)
        return result.text
    }
}
