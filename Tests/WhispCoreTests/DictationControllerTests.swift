import Testing
import Foundation
import WhispAudio
import WhispASR
import WhispInput
import WhispPlatform
@testable import WhispCore

@Suite struct DictationControllerTests {

    /// Emits preloaded chunks immediately; finishes the stream on `stop()`.
    actor StubCapturer: AudioCapturer {
        private let chunks: [AudioChunk]
        private var continuation: AudioStream.Continuation?
        nonisolated let levels: AsyncStream<Float> = AsyncStream { $0.finish() }

        init(chunks: [AudioChunk]) { self.chunks = chunks }

        func start(_ config: CaptureConfig) async throws -> AudioStream {
            let (stream, cont) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
            continuation = cont
            for chunk in chunks { cont.yield(chunk) }
            return stream
        }
        func stop() async { continuation?.finish(); continuation = nil }
    }

    /// Drains the audio, then emits one `.final` with fixed text.
    struct StubTranscriber: TranscriptionService {
        let id = TranscriptionBackendID.whisper
        let text: String
        func availability(for options: TranscriptionOptions) async -> BackendAvailability { .ready }
        func prepare(_ options: TranscriptionOptions) async throws {}
        func stream(_ audio: AudioStream, options: TranscriptionOptions)
            -> AsyncThrowingStream<TranscriptionEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await _ in audio {}
                        continuation.yield(.final(TranscriptionResult(text: text, segments: [], backend: id)))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, segments: [], backend: id)
        }
    }

    /// Drains the audio, then finishes the stream with an error — the mid-session failure path
    /// that routes through `fail()` and lands the controller in `.error`.
    struct ThrowingTranscriber: TranscriptionService {
        let id = TranscriptionBackendID.whisper
        func availability(for options: TranscriptionOptions) async -> BackendAvailability { .ready }
        func prepare(_ options: TranscriptionOptions) async throws {}
        func stream(_ audio: AudioStream, options: TranscriptionOptions)
            -> AsyncThrowingStream<TranscriptionEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    do { for try await _ in audio {} } catch {}
                    continuation.finish(throwing: TranscriptionError.modelMissing)
                }
            }
        }
        func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
            throw TranscriptionError.modelMissing
        }
    }

    actor SpyInjector: TextInjector {
        private(set) var injected: [String] = []
        func inject(_ text: String, strategy: InjectionStrategy?) async throws -> InjectionOutcome {
            injected.append(text)
            return .inserted(app: nil)
        }
    }

    actor SpyMedia: MediaController {
        private(set) var pauses = 0
        private(set) var resumes = 0
        func nowPlaying() async -> NowPlaying? { nil }
        func pause() async { pauses += 1 }
        func resume() async { resumes += 1 }
    }

    private func chunk(_ amplitude: Float) -> AudioChunk {
        AudioChunk(samples: Array(repeating: amplitude, count: 1600), sampleRate: 16_000)
    }

    @Test @MainActor func recordTranscribeInjectFlow() async throws {
        let injector = SpyInjector()
        let media = SpyMedia()
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5), chunk(0.0)]),
            router: TranscriptionRouter(backends: [StubTranscriber(text: "hello world")]),
            injector: injector,
            media: media,
            vad: EnergyVAD())

        #expect(controller.state == .idle)
        try await controller.startDictation()
        #expect(controller.state == .recording)

        await controller.stopDictation()
        #expect(controller.state == .idle)
        #expect(await injector.injected == ["hello world"])
        #expect(await media.pauses == 1)
        #expect(await media.resumes == 1)
    }

    @Test @MainActor func failsWhenNoBackendAvailable() async {
        let media = SpyMedia()
        let controller = DictationController(
            capturer: StubCapturer(chunks: []),
            router: TranscriptionRouter(backends: []),  // nothing ready
            injector: SpyInjector(),
            media: media,
            vad: EnergyVAD())

        await #expect(throws: TranscriptionError.self) {
            try await controller.startDictation()
        }
        #expect(controller.state == .idle)        // never left idle
        #expect(await media.resumes == 1)         // media resumed after the failed start
    }

    /// Regression: a mid-session backend failure lands in `.error`, and `.error` must NOT brick the
    /// hotkey — the next activate recovers and starts a new session instead of being a silent no-op.
    @Test @MainActor func recoversFromErrorStateOnNextHotkey() async throws {
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5)]),
            router: TranscriptionRouter(backends: [ThrowingTranscriber()]),
            injector: SpyInjector(),
            media: SpyMedia(),
            vad: EnergyVAD())

        try await controller.startDictation()
        #expect(controller.state == .recording)
        await controller.stopDictation()          // drains → consumeTask throws → fail() → .error
        guard case .error = controller.state else {
            Issue.record("expected .error after a mid-session failure, got \(controller.state)")
            return
        }

        await controller.handleHotkey(.activate)  // must recover, not no-op
        #expect(controller.state == .recording)   // recovered from the dead-end
        await controller.stopDictation()
    }

    @Test @MainActor func hotkeyActivateRecordsThenDeactivateInjects() async throws {
        let injector = SpyInjector()
        let media = SpyMedia()
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5)]),
            router: TranscriptionRouter(backends: [StubTranscriber(text: "hi")]),
            injector: injector,
            media: media,
            vad: EnergyVAD())

        await controller.handleHotkey(.activate)
        #expect(controller.state == .recording)

        await controller.handleHotkey(.deactivate)
        #expect(controller.state == .idle)
        #expect(await injector.injected == ["hi"])
    }

    @Test @MainActor func firesSessionCompleteWithResult() async throws {
        final class Box { var record: SessionRecord? }
        let box = Box()
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5)]),
            router: TranscriptionRouter(backends: [StubTranscriber(text: "hello world")]),
            injector: SpyInjector(),
            media: SpyMedia(),
            vad: EnergyVAD(),
            onSessionComplete: { record in box.record = record })

        try await controller.startDictation()
        await controller.stopDictation()
        #expect(box.record?.text == "hello world")
        #expect(box.record?.backend == "whisper")
    }

    @Test @MainActor func appliesPostProcessingBeforeInject() async throws {
        let injector = SpyInjector()
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5)]),
            router: TranscriptionRouter(backends: [StubTranscriber(text: "hello github")]),
            injector: injector,
            media: SpyMedia(),
            vad: EnergyVAD(),
            textPostProcessor: { text in
                DictionaryProcessor.apply([Replacement(term: "github", replacement: "GitHub")], to: text)
            })

        try await controller.startDictation()
        await controller.stopDictation()
        #expect(await injector.injected == ["hello GitHub"])
    }

    /// Counts how many times capture was started.
    actor CountingCapturer: AudioCapturer {
        private(set) var startCount = 0
        private let chunks: [AudioChunk]
        private var continuation: AudioStream.Continuation?
        nonisolated let levels: AsyncStream<Float> = AsyncStream { $0.finish() }

        init(chunks: [AudioChunk]) { self.chunks = chunks }

        func start(_ config: CaptureConfig) async throws -> AudioStream {
            startCount += 1
            let (stream, cont) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
            continuation = cont
            for chunk in chunks { cont.yield(chunk) }
            return stream
        }
        func stop() async { continuation?.finish(); continuation = nil }
    }

    /// Regression: two racing starts must claim the session once (the `nullptr == Tap()` fix).
    @Test @MainActor func concurrentStartsStartCaptureOnce() async throws {
        let capturer = CountingCapturer(chunks: [chunk(0.5)])
        let controller = DictationController(
            capturer: capturer,
            router: TranscriptionRouter(backends: [StubTranscriber(text: "x")]),
            injector: SpyInjector(),
            media: SpyMedia(),
            vad: EnergyVAD())

        async let first = try? await controller.startDictation()
        async let second = try? await controller.startDictation()
        _ = await (first, second)

        #expect(controller.state == .recording)
        #expect(await capturer.startCount == 1)

        await controller.stopDictation()
        #expect(controller.state == .idle)
    }

    /// Records how many audio chunks reached the backend.
    actor CountingTranscriber: TranscriptionService {
        nonisolated let id = TranscriptionBackendID.whisper
        nonisolated let text: String
        private(set) var receivedChunks = 0
        init(text: String) { self.text = text }
        func availability(for options: TranscriptionOptions) async -> BackendAvailability { .ready }
        func prepare(_ options: TranscriptionOptions) async throws {}
        private func bump() { receivedChunks += 1 }
        nonisolated func stream(_ audio: AudioStream, options: TranscriptionOptions)
            -> AsyncThrowingStream<TranscriptionEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await _ in audio { await self.bump() }
                        continuation.yield(.final(TranscriptionResult(text: self.text, segments: [], backend: self.id)))
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
        }
        func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, segments: [], backend: id)
        }
    }

    /// VAD gating drops leading silence: 12 silent chunks + 1 speech chunk → far fewer than 13
    /// reach the backend (pre-roll caps at 8), yet the speech still gets through and is injected.
    @Test @MainActor func vadGatingDropsLeadingSilence() async throws {
        let backend = CountingTranscriber(text: "ok")
        let injector = SpyInjector()
        let chunks = Array(repeating: chunk(0.0), count: 12) + [chunk(0.5)]
        let controller = DictationController(
            capturer: StubCapturer(chunks: chunks),
            router: TranscriptionRouter(backends: [backend]),
            injector: injector,
            media: SpyMedia(),
            vad: EnergyVAD(),
            options: TranscriptionOptions(useVAD: true))

        try await controller.startDictation()
        await controller.stopDictation()

        let received = await backend.receivedChunks
        #expect(received >= 1)        // the speech chunk got through
        #expect(received < 13)        // most leading silence was dropped
        #expect(await injector.injected == ["ok"])
    }

    /// Injector that reports a fixed selection (for Command Mode tests).
    actor SelectionInjector: TextInjector {
        let selection: String?
        private(set) var injected: [String] = []
        init(selection: String?) { self.selection = selection }
        func inject(_ text: String, strategy: InjectionStrategy?) async throws -> InjectionOutcome {
            injected.append(text); return .inserted(app: nil)
        }
        func readSelection() async -> String? { selection }
    }

    /// Command Mode: with text selected, the dictation is an instruction applied to the selection.
    @Test @MainActor func commandModeEditsSelection() async throws {
        let injector = SelectionInjector(selection: "hello world")
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5)]),
            router: TranscriptionRouter(backends: [StubTranscriber(text: "uppercase it")]),
            injector: injector,
            media: SpyMedia(),
            vad: EnergyVAD(),
            commandProcessor: { command, selection in
                command.contains("uppercase") ? selection.uppercased() : selection
            })
        controller.commandModeEnabled = true

        try await controller.startDictation()
        await controller.stopDictation()

        #expect(await injector.injected == ["HELLO WORLD"])   // selection edited, command not inserted
    }

    /// With no selection, Command Mode falls back to normal dictation.
    @Test @MainActor func noSelectionFallsBackToDictation() async throws {
        let injector = SelectionInjector(selection: nil)
        let controller = DictationController(
            capturer: StubCapturer(chunks: [chunk(0.5)]),
            router: TranscriptionRouter(backends: [StubTranscriber(text: "just text")]),
            injector: injector,
            media: SpyMedia(),
            vad: EnergyVAD(),
            commandProcessor: { _, _ in "SHOULD NOT RUN" })
        controller.commandModeEnabled = true

        try await controller.startDictation()
        await controller.stopDictation()

        #expect(await injector.injected == ["just text"])     // normal dictation
    }
}
