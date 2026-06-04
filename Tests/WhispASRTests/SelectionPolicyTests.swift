import Testing
import Foundation
import WhispAudio
@testable import WhispASR

@Suite struct SelectionPolicyTests {

    /// Minimal stub backend with a fixed availability.
    private struct StubBackend: TranscriptionService {
        let id: TranscriptionBackendID
        let avail: BackendAvailability
        func availability(for options: TranscriptionOptions) async -> BackendAvailability { avail }
        func prepare(_ options: TranscriptionOptions) async throws {}
        func stream(_ audio: AudioStream, options: TranscriptionOptions)
            -> AsyncThrowingStream<TranscriptionEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", segments: [], backend: id)
        }
    }

    private let opts = TranscriptionOptions(languages: [Locale(identifier: "en_US")])

    @Test func prefersNativeWhenReadyAndPreferred() async throws {
        let router = TranscriptionRouter(
            backends: [
                StubBackend(id: .whisper, avail: .ready),
                StubBackend(id: .fluidAudioParakeet, avail: .ready),
                StubBackend(id: .nativeSpeech, avail: .ready),
            ],
            policy: .init(preferNativeOnMacOS26: true))
        let chosen = try await router.select(for: opts)
        #expect(chosen.id == .nativeSpeech)
    }

    @Test func fallsBackWhenNativeUnavailable() async throws {
        let router = TranscriptionRouter(
            backends: [
                StubBackend(id: .nativeSpeech, avail: .unsupportedOS),
                StubBackend(id: .fluidAudioParakeet, avail: .ready),
                StubBackend(id: .whisper, avail: .ready),
            ],
            policy: .init(preferNativeOnMacOS26: true))
        let chosen = try await router.select(for: opts)
        #expect(chosen.id == .fluidAudioParakeet)
    }

    @Test func honorsReadyUserOverride() async throws {
        let router = TranscriptionRouter(
            backends: [
                StubBackend(id: .nativeSpeech, avail: .ready),
                StubBackend(id: .whisper, avail: .ready),
            ],
            policy: .init(preferNativeOnMacOS26: true, userOverride: .whisper))
        let chosen = try await router.select(for: opts)
        #expect(chosen.id == .whisper)
    }

    @Test func throwsWhenNothingReady() async {
        let router = TranscriptionRouter(
            backends: [StubBackend(id: .whisper, avail: .missingModel)],
            policy: .init())
        await #expect(throws: TranscriptionError.self) {
            _ = try await router.select(for: opts)
        }
    }
}
