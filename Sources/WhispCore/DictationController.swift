import Foundation
import Observation
import WhispAudio
import WhispASR
import WhispInput
import WhispPlatform

/// A completed dictation session, emitted for persistence (history + metrics).
public struct SessionRecord: Sendable {
    public let text: String
    public let durationMs: Int
    public let backend: String
    public init(text: String, durationMs: Int, backend: String) {
        self.text = text
        self.durationMs = durationMs
        self.backend = backend
    }
}

/// A short audible cue played at the boundaries of a recording (start / stop).
public enum SoundCue: Sendable { case start, stop }

/// Central orchestrator: record → (VAD) → transcribe → inject, with media ducking around
/// the session. `@MainActor` so it binds directly to the UI; heavy work is delegated to the
/// injected services (an actor-backed capturer, the transcription router, etc.).
@MainActor
@Observable
public final class DictationController {
    public enum State: Sendable, Equatable {
        case idle
        case preparing
        case recording
        case transcribing
        case injecting
        case error(String)
    }

    private enum SessionMode { case dictation, command }

    public private(set) var state: State = .idle
    public private(set) var isSpeaking = false
    public private(set) var liveText = ""
    public private(set) var level: Float = 0   // live RMS audio level for the waveform UI
    public private(set) var recordingStartedAt: Date?   // for the elapsed-time indicator
    public private(set) var lastInjection: InjectionOutcome?   // result of the last text insertion

    @ObservationIgnored private let capturer: any AudioCapturer
    @ObservationIgnored private let router: TranscriptionRouter
    @ObservationIgnored private let injector: any TextInjector
    @ObservationIgnored private let media: any MediaController
    @ObservationIgnored private var vad: any VoiceActivityDetector
    @ObservationIgnored private let captureConfig: CaptureConfig
    @ObservationIgnored public var options: TranscriptionOptions   // base dictation options (e.g. locale)

    /// Power Mode override: when set, takes precedence over `options` for the next session.
    @ObservationIgnored public var preferredOptions: TranscriptionOptions?

    @ObservationIgnored private var forwardTask: Task<Void, Never>?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var finalText = ""
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var transcribeStartedAt: Date?   // decode-latency telemetry start (audio fully captured)
    /// Held during a session so App Nap / background throttling don't freeze capture and the notch
    /// animation while another app is focused (which is the normal dictation case).
    @ObservationIgnored private var recordingActivity: (any NSObjectProtocol)?
    @ObservationIgnored private var selectedBackend: TranscriptionBackendID?
    @ObservationIgnored private let onSessionComplete: (@MainActor (SessionRecord) async -> Void)?
    @ObservationIgnored private let textPostProcessor: (@MainActor (String) async -> String)?
    @ObservationIgnored private let vocabularyProvider: (@MainActor () async -> [String])?
    /// Applies a spoken instruction to selected text (Command Mode); returns the edited text.
    @ObservationIgnored private let commandProcessor: (@MainActor (String, String) async -> String?)?
    /// Optional audible cues for record start / stop (wired to NSSound in the app layer).
    @ObservationIgnored private let onCue: (@MainActor (SoundCue) -> Void)?
    /// When true, dictating with text selected runs it as a voice command instead of inserting.
    @ObservationIgnored public var commandModeEnabled = false
    /// Hands-free: end the session automatically on the first natural pause (wired for Toggle mode).
    @ObservationIgnored public var autoStopOnSilence = false
    @ObservationIgnored private var sessionMode = SessionMode.dictation
    @ObservationIgnored private var commandSelection = ""

    public init(capturer: any AudioCapturer,
                router: TranscriptionRouter,
                injector: any TextInjector,
                media: any MediaController,
                vad: any VoiceActivityDetector,
                captureConfig: CaptureConfig = .init(),
                options: TranscriptionOptions = .init(),
                onSessionComplete: (@MainActor (SessionRecord) async -> Void)? = nil,
                textPostProcessor: (@MainActor (String) async -> String)? = nil,
                vocabularyProvider: (@MainActor () async -> [String])? = nil,
                commandProcessor: (@MainActor (String, String) async -> String?)? = nil,
                onCue: (@MainActor (SoundCue) -> Void)? = nil) {
        self.capturer = capturer
        self.router = router
        self.injector = injector
        self.media = media
        self.vad = vad
        self.captureConfig = captureConfig
        self.options = options
        self.onSessionComplete = onSessionComplete
        self.textPostProcessor = textPostProcessor
        self.vocabularyProvider = vocabularyProvider
        self.commandProcessor = commandProcessor
        self.onCue = onCue
    }

    /// UI entry point: start when idle, stop when recording.
    public func toggle() {
        Task { await handleHotkey(.toggle) }
    }

    /// Routes a global hotkey event (the four modes from `HotkeyMonitor`) to the pipeline.
    public func handleHotkey(_ event: HotkeyEvent) async {
        switch event {
        case .toggle:
            switch state {
            case .preparing, .recording:  await stopDictation()
            default:                      await recoverAndStart()   // idle/error → (re)start; transcribing/injecting ignored
            }
        case .activate:
            await recoverAndStart()
        case .deactivate:
            if state == .recording || state == .preparing { await stopDictation() }
        }
    }

    /// Start dictation from `.idle`, first recovering from a prior `.error` so a failed session never
    /// bricks the hotkey (nothing else transitions out of `.error`). No-op while transcribing/injecting.
    private func recoverAndStart() async {
        if case .error = state { state = .idle }
        guard state == .idle else { return }
        try? await startDictation()
    }

    /// Pre-load the backend resolved from the current options so the first dictation doesn't stall on
    /// a cold model load (WhisperKit pipe build, FluidAudio model load, whisper.cpp download). `prepare()`
    /// is idempotent, so a later session reuses the warm handle. Call at launch and whenever the
    /// engine/model changes. No-op while a session is active; queued warms run serially.
    public func prewarm() {
        guard state == .idle else { return }
        let previous = prewarmTask
        prewarmTask = Task { @MainActor [weak self] in
            await previous?.value   // serialize: never run two prepare() calls concurrently
            guard let self, self.state == .idle else { return }
            let opts = self.preferredOptions ?? self.options
            do {
                let backend = try await self.router.select(for: opts)
                guard self.state == .idle else { return }   // a session claimed the engine — it owns prepare
                try await backend.prepare(opts)
                self.selectedBackend = backend.id
            } catch {
                Log.asr.error("backend prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func startDictation() async throws {
        guard state == .idle else { return }
        state = .preparing   // claim synchronously; blocks re-entrant starts
        await injector.captureFocus()   // pin the target field + caret at the moment dictation starts
        if commandModeEnabled, let selection = await injector.readSelection(), !selection.isEmpty {
            sessionMode = .command       // text is selected → treat this dictation as an edit command
            commandSelection = selection
        } else {
            sessionMode = .dictation
            commandSelection = ""
        }
        var effectiveOptions = preferredOptions ?? options
        finalText = ""
        liveText = ""
        vad.reset()   // clear stale speaking/silence state so leading-silence trimming works every session
        await media.pause()
        if effectiveOptions.vocabulary.isEmpty, let vocabularyProvider {
            effectiveOptions.vocabulary = await vocabularyProvider()   // prime the model with the user's terms
        }

        // Let any launch/settings prewarm finish so prepare() isn't invoked concurrently on a
        // non-actor backend (whisper.cpp); the warm handle is then reused below.
        await prewarmTask?.value

        // Select + load a backend BEFORE capturing. Try the ready backends in order so a single
        // engine's prepare failure (e.g. a model download 404) falls through to the next instead of
        // dead-ending the session; the mic only opens once one is ready.
        let backend: any TranscriptionService
        do {
            backend = try await prepareFirstAvailable(for: effectiveOptions)
            selectedBackend = backend.id
        } catch {
            await media.resume()
            state = .idle
            throw error
        }
        guard state == .preparing else { await media.resume(); return }   // stopped while preparing

        onCue?(.start)   // audible "recording started" cue, just before the mic opens

        let raw: AudioStream
        do {
            raw = try await capturer.start(captureConfig)
        } catch {
            await media.resume()
            state = .idle
            throw error
        }

        sessionStart = .now
        recordingStartedAt = sessionStart

        // Forward raw chunks into the backend's input stream. With VAD enabled, only speech is
        // forwarded — leading / trailing / long-pause silence is dropped (with a generous pre-roll
        // and the VAD's hangover) so the model isn't fed silence it can hallucinate over.
        let (forwarded, fwdContinuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        let gateVAD = effectiveOptions.useVAD
        forwardTask = Task { @MainActor [weak self] in
            var all: [AudioChunk] = []
            var firstSpeech: Int?
            var lastSpeech = 0
            do {
                for try await chunk in raw {
                    guard let self else { break }
                    let decision = self.decideVAD(chunk)
                    let index = all.count
                    all.append(chunk)
                    switch decision {
                    case .speech:   if firstSpeech == nil { firstSpeech = index }; lastSpeech = index
                    case .endpoint: lastSpeech = index
                    case .silence:  break
                    }
                    // Hands-free: end the session on the first natural pause (Toggle mode opt-in).
                    if decision == .endpoint, self.autoStopOnSilence, self.state == .recording {
                        Task { @MainActor in await self.stopDictation() }
                    }
                }
                // Trim only the silence *around* the speech (everything between first and last speech
                // is kept, with a time-based pre-roll / hangover). If no speech was detected — or VAD
                // is off — forward it all: never starve the engine, which rejects clips under ~0.3 s.
                let slice: ArraySlice<AudioChunk>
                if gateVAD, let start = firstSpeech {
                    let lo = Self.preRollIndex(before: start, seconds: 0.25, in: all)
                    let hi = Self.postRollIndex(after: lastSpeech, seconds: 0.20, in: all)
                    slice = lo <= hi ? all[lo...hi] : all[...]
                } else {
                    slice = all[...]
                }
                for chunk in slice { fwdContinuation.yield(chunk) }
                fwdContinuation.finish()
            } catch {
                fwdContinuation.finish(throwing: error)
            }
        }

        let opts = effectiveOptions
        consumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in backend.stream(forwarded, options: opts) {
                    self.handle(event)
                }
                await self.finishTranscription()
            } catch {
                await self.fail(error)
            }
        }

        // The capturer's levels stream lives for the capturer's lifetime and tolerates a single
        // consumer only — cancelling the reader would terminate the stream for good, leaving every
        // later session stuck at level 0. Start one persistent reader and keep it; it idles between
        // recordings and resumes when the tap yields again.
        if levelTask == nil {
            let levels = capturer.levels
            levelTask = Task { @MainActor [weak self] in
                for await value in levels { self?.level = value }
            }
        }

        // Keep the OS from throttling us while another app is focused (audio + notch animation).
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "whisp recording")

        state = .recording
    }

    public func stopDictation() async {
        switch state {
        case .preparing:
            state = .idle           // startDictation aborts once prepare returns
        case .recording:
            state = .transcribing   // immediate feedback; transcription runs while we drain
            let pending = consumeTask
            try? await Task.sleep(for: .milliseconds(300))   // keep capturing the tail of the last word
            await capturer.stop()   // finishes the capture stream → drains the pipeline
            transcribeStartedAt = .now   // audio fully captured → decode begins (latency telemetry)
            onCue?(.stop)           // "recording stopped" cue, after the mic is closed (no bleed)
            await pending?.value    // wait for transcription + injection to complete
        default:
            break
        }
    }

    // MARK: - Private

    /// Runs the VAD on the main actor (cheap energy check), updates `isSpeaking`, and returns the
    /// decision so the forward loop can gate silence.
    private func decideVAD(_ chunk: AudioChunk) -> VADDecision {
        let decision = vad.process(chunk)
        isSpeaking = decision == .speech
        return decision
    }

    /// Prepares the first ready backend that loads successfully, falling through to the next on
    /// failure. Throws the last error (or `.noBackendAvailable`) if none prepare.
    private func prepareFirstAvailable(for options: TranscriptionOptions) async throws -> any TranscriptionService {
        let candidates = await router.orderedReadyBackends(for: options)
        guard !candidates.isEmpty else { throw TranscriptionError.noBackendAvailable }
        var lastError: Error?
        for candidate in candidates {
            do {
                try await candidate.prepare(options)
                return candidate
            } catch {
                lastError = error
                Log.asr.error("backend \(candidate.id.rawValue, privacy: .public) prepare failed; trying next: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError ?? TranscriptionError.noBackendAvailable
    }

    /// First chunk index ≈ `seconds` of audio before `idx` — a device-independent leading pre-roll
    /// (chunk sizes vary with the hardware buffer, so a fixed chunk count would not be). Pure.
    nonisolated static func preRollIndex(before idx: Int, seconds: Double, in chunks: [AudioChunk]) -> Int {
        var acc = 0.0, i = idx
        while i > 0 && acc < seconds { i -= 1; acc += chunks[i].duration }
        return i
    }

    /// Last chunk index ≈ `seconds` of audio after `idx` — the trailing hangover. Pure.
    nonisolated static func postRollIndex(after idx: Int, seconds: Double, in chunks: [AudioChunk]) -> Int {
        var acc = 0.0, i = idx
        while i < chunks.count - 1 && acc < seconds { i += 1; acc += chunks[i].duration }
        return i
    }

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let text):     liveText = text
        case .segment(let segment):  liveText = segment.text
        case .final(let result):     finalText = result.text; liveText = result.text
        }
    }

    private func finishTranscription() async {
        if let t = transcribeStartedAt {
            Log.asr.info("decode latency \(Int(Date.now.timeIntervalSince(t) * 1000))ms (backend \(self.selectedBackend?.rawValue ?? "?", privacy: .public))")
        }
        state = .injecting
        if !finalText.isEmpty {
            switch sessionMode {
            case .dictation:
                let text = await textPostProcessor?(finalText) ?? finalText
                await injectResult(text)
                let duration = Int(Date.now.timeIntervalSince(sessionStart ?? .now) * 1000)
                await onSessionComplete?(SessionRecord(text: text, durationMs: duration,
                                                       backend: selectedBackend?.rawValue ?? ""))
            case .command:
                // finalText is the spoken instruction; apply it to the selection and replace it.
                if let edited = await commandProcessor?(finalText, commandSelection), !edited.isEmpty {
                    await injectResult(edited)
                }
            }
        }
        sessionMode = .dictation
        await media.resume()
        forwardTask?.cancel()
        forwardTask = nil
        endRecordingActivity()
        level = 0
        recordingStartedAt = nil
        isSpeaking = false
        state = .idle
    }

    private func fail(_ error: Error) async {
        Log.general.error("dictation session failed: \(String(describing: error), privacy: .public)")
        await media.resume()
        forwardTask?.cancel()
        forwardTask = nil
        endRecordingActivity()
        level = 0
        recordingStartedAt = nil
        isSpeaking = false
        state = .error(String(describing: error))
    }

    private func injectResult(_ text: String) async {
        do {
            lastInjection = try await injector.inject(text, strategy: nil)
        } catch {
            lastInjection = nil
            Log.input.error("Injection failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func endRecordingActivity() {
        if let activity = recordingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            recordingActivity = nil
        }
    }
}
