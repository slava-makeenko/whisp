import Foundation
import WhispAudio

public enum TranscriptionBackendID: String, Sendable, CaseIterable, Codable {
    case nativeSpeech
    case fluidAudioParakeet
    case whisper
    case whisperCpp
}

public struct TranscriptionOptions: Sendable {
    /// Selected dictation languages. One → pin that language; zero or several → auto-detect (so
    /// e.g. Russian + English are both recognized).
    public var languages: [Locale]
    public var modelID: String?
    public var partials: Bool
    public var useVAD: Bool
    /// Domain terms (names, jargon) to bias recognition toward — primes the model rather than
    /// fixing the text after the fact.
    public var vocabulary: [String]
    /// User-pinned engine; when set and ready, the router uses it instead of best-available.
    public var preferredBackend: TranscriptionBackendID?

    public init(languages: [Locale] = [], modelID: String? = nil,
                partials: Bool = true, useVAD: Bool = true, vocabulary: [String] = [],
                preferredBackend: TranscriptionBackendID? = nil) {
        self.languages = languages
        self.modelID = modelID
        self.partials = partials
        self.useVAD = useVAD
        self.vocabulary = vocabulary
        self.preferredBackend = preferredBackend
    }

    /// Primary language (first selected), or the current locale — for backends that take one locale.
    public var locale: Locale { languages.first ?? .current }

    /// The single language code to pin to, or nil to auto-detect (0 or >1 languages selected).
    public var pinnedLanguageCode: String? {
        languages.count == 1 ? languages[0].language.languageCode?.identifier : nil
    }
}

public struct TranscriptionSegment: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let segments: [TranscriptionSegment]
    public let backend: TranscriptionBackendID
    public init(text: String, segments: [TranscriptionSegment], backend: TranscriptionBackendID) {
        self.text = text; self.segments = segments; self.backend = backend
    }
}

public enum TranscriptionEvent: Sendable {
    case partial(String)
    case segment(TranscriptionSegment)
    case final(TranscriptionResult)
}

public enum BackendAvailability: Sendable, Equatable {
    case ready
    case needsDownload
    case unsupportedOS
    case missingModel
}

public enum TranscriptionError: Error, Sendable {
    case noBackendAvailable
    case modelMissing
    case cancelled
}

/// Uniform contract over every ASR backend (native SpeechAnalyzer, FluidAudio/Parakeet,
/// whisper). Concrete conformers and their `// VERIFY-ASR-*` bindings land in Phase 3.
public protocol TranscriptionService: Sendable {
    var id: TranscriptionBackendID { get }
    func availability(for options: TranscriptionOptions) async -> BackendAvailability
    func prepare(_ options: TranscriptionOptions) async throws
    /// Live dictation: a stream of partial/segment/final events.
    func stream(_ audio: AudioStream, options: TranscriptionOptions)
        -> AsyncThrowingStream<TranscriptionEvent, Error>
    /// Batch path for the file-transcription queue.
    func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult
}
