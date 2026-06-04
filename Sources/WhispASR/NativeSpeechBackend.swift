#if ENABLE_NATIVE_SPEECH_ANALYZER
import Foundation
import AVFoundation
import Speech
import WhispAudio

/// macOS 26 native on-device ASR via `SpeechAnalyzer` + `SpeechTranscriber`.
/// Real streaming (the marquee path on 26): a results task reads `transcriber.results`
/// while the driver feeds `AnalyzerInput` buffers and finalizes at end-of-audio.
///
/// API confirmed against the Speech.framework `.swiftinterface` in the macOS 26.5 SDK.
/// Resolves VERIFY-ASR-3. Runtime behaviour is validated manually (needs the model + mic).
@available(macOS 26, *)
public actor NativeSpeechBackend: TranscriptionService {
    public nonisolated let id = TranscriptionBackendID.nativeSpeech

    public init() {}

    public func availability(for options: TranscriptionOptions) async -> BackendAvailability {
        // OS is gated by @available; here we only check the locale is offered.
        await Self.supports(options.locale) ? .ready : .unsupportedOS
    }

    public func prepare(_ options: TranscriptionOptions) async throws {
        let transcriber = SpeechTranscriber(locale: options.locale, preset: .progressiveTranscription)
        try await Self.ensureModel(for: transcriber, locale: options.locale)
    }

    public nonisolated func stream(_ audio: WhispAudio.AudioStream, options: TranscriptionOptions)
        -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let id = self.id
        return AsyncThrowingStream { continuation in
            let driver = Task {
                do {
                    let transcriber = SpeechTranscriber(locale: options.locale, preset: .progressiveTranscription)
                    try await Self.ensureModel(for: transcriber, locale: options.locale)

                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    let (inputStream, inputCont) = AsyncStream.makeStream(of: AnalyzerInput.self)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])

                    // Reader task: transcriber is Sendable, so it crosses safely; analyzer does not.
                    let resultsTask = Task {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            if result.isFinal {
                                continuation.yield(.final(TranscriptionResult(text: text, segments: [], backend: id)))
                            } else {
                                continuation.yield(.partial(text))
                            }
                        }
                    }

                    try await analyzer.start(inputSequence: inputStream)

                    let converter = NativeBufferConverter()
                    for try await chunk in audio {
                        if let buffer = converter.buffer(from: chunk, target: format) {
                            inputCont.yield(AnalyzerInput(buffer: buffer))
                        }
                    }
                    inputCont.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await resultsTask.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in driver.cancel() }
        }
    }

    public func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
        let transcriber = SpeechTranscriber(locale: options.locale, preset: .transcription)
        try await Self.ensureModel(for: transcriber, locale: options.locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        let resultsTask = Task {
            var text = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                text.append(result.text)
            }
            return text
        }

        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let text = try await resultsTask.value
        return TranscriptionResult(text: String(text.characters), segments: [], backend: id)
    }

    // MARK: - Assets

    private static func supports(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let wanted = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

/// Converts a 16 kHz mono Float `AudioChunk` to the analyzer's preferred format.
/// `@unchecked Sendable`: only ever used inside the single driver task's feed loop.
@available(macOS 26, *)
private final class NativeBufferConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var pendingInput: AVAudioPCMBuffer?

    func buffer(from chunk: AudioChunk, target: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: chunk.sampleRate, channels: 1, interleaved: false),
              let sourceBuffer = Self.floatBuffer(chunk.samples, format: source)
        else { return nil }

        // Common case: analyzer accepts our 16 kHz mono float directly.
        guard let target, target.sampleRate != source.sampleRate else { return sourceBuffer }

        if converter == nil { converter = AVAudioConverter(from: source, to: target) }
        guard let converter,
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(Double(chunk.samples.count) * target.sampleRate / source.sampleRate) + 1024)
        else { return sourceBuffer }

        pendingInput = sourceBuffer
        var error: NSError?
        converter.convert(to: output, error: &error) { [self] _, status in
            guard let buffer = pendingInput else { status.pointee = .noDataNow; return nil }
            pendingInput = nil
            status.pointee = .haveData
            return buffer
        }
        return output
    }

    private static func floatBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData, !samples.isEmpty {
            samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }
}
#endif
