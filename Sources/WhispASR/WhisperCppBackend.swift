import Foundation
@preconcurrency import AVFoundation
import WhispAudio
@preconcurrency import SwiftWhisper

/// Whisper via whisper.cpp (ggml / Metal) — the same engine family VoiceInk uses, offered as a
/// user-selectable backend. The ggml model downloads on first `prepare()`.
///
/// `Whisper` isn't `Sendable`, and its `transcribe` is a free async call, so an actor would have to
/// "send" it out on every call. Instead this is a class whose state is touched serially — the
/// orchestrator runs one session at a time (prepare → stream), so there is no concurrent access.
public final class WhisperCppBackend: TranscriptionService, @unchecked Sendable {
    public let id = TranscriptionBackendID.whisperCpp

    private var whisper: Whisper?
    private let modelName: String
    private let remoteURL: URL

    public init(modelName: String = "ggml-base.bin") {
        self.modelName = modelName
        self.remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)")!
    }

    public func availability(for options: TranscriptionOptions) async -> BackendAvailability {
        .ready   // model downloads on prepare(), same as the other backends
    }

    public func prepare(_ options: TranscriptionOptions) async throws {
        guard whisper == nil else { return }
        let modelFile = try await downloadedModel()
        let params = WhisperParams.default
        if let code = options.pinnedLanguageCode,   // nil (0 or >1 languages) → leave .auto
           let lang = WhisperLanguage(rawValue: code) {
            params.language = lang
        }
        whisper = Whisper(fromFileURL: modelFile, withParams: params)
    }

    public func stream(_ audio: WhispAudio.AudioStream, options: TranscriptionOptions)
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
        try await prepare(options)
        let text = try await transcribe(samples: Self.pcm16kMono(url))
        return TranscriptionResult(text: text, segments: [], backend: id)
    }

    private func transcribe(samples: [Float]) async throws -> String {
        guard let whisper else { throw TranscriptionError.modelMissing }
        guard !samples.isEmpty else { return "" }
        let segments = try await whisper.transcribe(audioFrames: samples)
        return segments.map(\.text).joined()
    }

    /// Downloads the ggml model into Application Support on first use; returns the local URL.
    private func downloadedModel() async throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("whisp/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(modelName)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let (tmp, _) = try await URLSession.shared.download(from: remoteURL)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Decodes an audio file to 16 kHz mono Float frames (what whisper.cpp expects).
    private static func pcm16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw TranscriptionError.modelMissing }
        try file.read(into: inBuf)

        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / inFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw TranscriptionError.modelMissing
        }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let error { throw error }
        guard let channel = outBuf.floatChannelData else { throw TranscriptionError.modelMissing }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuf.frameLength)))
    }
}
