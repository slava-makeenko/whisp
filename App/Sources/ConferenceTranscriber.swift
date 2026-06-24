import Foundation
import AVFoundation
import WhispAudio
import WhispASR

/// Transcribes a Conference Mode recording window-by-window AND attributes each turn to a speaker:
/// the recording is stereo (L = mic = "Я", R = system = "Собеседник"), so each channel is transcribed
/// separately and labelled by its source — no ML diarization needed. Each emitted value is the
/// cumulative, speaker-labelled transcript so the UI can update incrementally.
///
/// Window-level timing (each window is one "turn" per speaker) is the granularity here; a near-silent
/// channel in a window is skipped so an idle side doesn't produce hallucinated text.
enum ConferenceTranscriber {
    static func stream(_ url: URL, windowSeconds: Double = 15) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let router = TranscriptionBackends.makeRouter()
                let options = TranscriptionOptions()
                var backend: (any TranscriptionService)?
                for candidate in await router.orderedReadyBackends(for: options) {
                    do { try await candidate.prepare(options); backend = candidate; break }
                    catch { continue }
                }
                guard let backend, let file = try? AVAudioFile(forReading: url) else {
                    continuation.finish(); return
                }

                let srcFormat = file.processingFormat
                let channelCount = Int(srcFormat.channelCount)
                let windowFrames = AVAudioFrameCount(max(1, srcFormat.sampleRate * windowSeconds))
                var lines: [String] = []
                while file.framePosition < file.length, !Task.isCancelled {
                    guard let window = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: windowFrames) else { break }
                    do { try file.read(into: window, frameCount: windowFrames) } catch { break }
                    if window.frameLength == 0 { break }

                    // Channel 0 = mic (Я); channel 1 = system (Собеседник). A mono file → only Я.
                    let me = await Self.transcribe(window, channel: 0, backend: backend, options: options)
                    let other = channelCount > 1
                        ? await Self.transcribe(window, channel: 1, backend: backend, options: options)
                        : ""

                    var emitted = false
                    if !me.isEmpty { lines.append("Я: \(me)"); emitted = true }
                    if !other.isEmpty { lines.append("Собеседник: \(other)"); emitted = true }
                    if emitted { continuation.yield(lines.joined(separator: "\n")) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Transcribes one channel of a window. Returns "" for a near-silent channel (so an idle side
    /// doesn't hallucinate a turn).
    private static func transcribe(_ window: AVAudioPCMBuffer, channel: Int,
                                   backend: any TranscriptionService, options: TranscriptionOptions) async -> String {
        guard let samples = mono16k(window, channel: channel), rms(samples) > 0.0015 else { return "" }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        continuation.yield(AudioChunk(samples: samples, sampleRate: 16_000))
        continuation.finish()
        var text = ""
        do {
            for try await event in backend.stream(stream, options: options) {
                if case .final(let result) = event { text = result.text }
            }
        } catch { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts one channel of a window and resamples it to the backends' canonical 16 kHz mono float.
    private static func mono16k(_ input: AVAudioPCMBuffer, channel: Int) -> [Float]? {
        let frames = Int(input.frameLength)
        guard frames > 0, channel < Int(input.format.channelCount),
              let src = input.floatChannelData else { return nil }

        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: input.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let monoDst = mono.floatChannelData else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        monoDst[0].update(from: src[channel], count: frames)

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: target) else { return nil }
        let ratio = target.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return mono
        }
        guard status != .error, let channelData = output.floatChannelData, output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }
}
