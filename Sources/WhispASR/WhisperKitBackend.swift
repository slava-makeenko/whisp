import Foundation
import WhispAudio
import WhisperKit

/// Whisper via WhisperKit (Swift-native CoreML on the ANE). Default fallback / override
/// backend. `stream` buffers to a final result; WhisperKit's `AudioStreamTranscriber`
/// real-time path is a later refinement.
// VERIFY-ASR-1: WhisperKit transcribe signatures confirmed against the source checkout.
public actor WhisperKitBackend: TranscriptionService {
    public nonisolated let id = TranscriptionBackendID.whisper

    private var pipe: WhisperKit?
    private let model: String?

    public init(model: String? = nil) { self.model = model }

    public func availability(for options: TranscriptionOptions) async -> BackendAvailability {
        .ready   // WhisperKit downloads the recommended model on first use during prepare().
    }

    public func prepare(_ options: TranscriptionOptions) async throws {
        guard pipe == nil else { return }
        pipe = try await WhisperKit(WhisperKitConfig(model: model))
    }

    public nonisolated func stream(_ audio: WhispAudio.AudioStream, options: TranscriptionOptions)
        -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var samples: [Float] = []
                    for try await chunk in audio { samples.append(contentsOf: chunk.samples) }
                    let text = try await self.transcribe(samples: samples, options: options)
                    continuation.yield(.final(TranscriptionResult(text: text, segments: [], backend: self.id)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
        guard let pipe else { throw TranscriptionError.modelMissing }
        // `results` is inferred as WhisperKit's [TranscriptionResult]; our own same-named type
        // (built below) shadows the imported one, so it is never named explicitly here.
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: decodeOptions(options))
        return TranscriptionResult(text: results.map(\.text).joined(separator: " "), segments: [], backend: id)
    }

    private func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String {
        guard let pipe else { throw TranscriptionError.modelMissing }
        guard !samples.isEmpty else { return "" }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: decodeOptions(options))
        return results.map(\.text).joined(separator: " ")
    }

    /// Tuned decoding: pin the language from the user's locale (skips error-prone auto-detect),
    /// chunk by voice activity, and prime the decoder with the user's vocabulary so jargon/names
    /// are recognized. Hallucination thresholds (compressionRatio / logProb / noSpeech) already
    /// default to Whisper's recommended values inside `DecodingOptions`.
    private func decodeOptions(_ options: TranscriptionOptions) -> DecodingOptions {
        var promptTokens: [Int]?
        if !options.vocabulary.isEmpty, let tokenizer = pipe?.tokenizer {
            promptTokens = tokenizer.encode(text: " " + options.vocabulary.joined(separator: ", "))
        }
        let language = options.pinnedLanguageCode   // nil → auto-detect (multilingual)
        return DecodingOptions(language: language,
                               usePrefillPrompt: true,
                               detectLanguage: language == nil,
                               promptTokens: promptTokens,
                               chunkingStrategy: .vad)
    }
}
