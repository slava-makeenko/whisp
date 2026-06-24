import Foundation
import AVFoundation
import WhispAudio
import WhispASR

/// Transcribes a Conference Mode recording in time windows so an hour-long meeting transcribes with
/// progress (and bounded memory) instead of one giant decode. Each emitted value is the *cumulative*
/// transcript so far, so the UI can update incrementally. (The chunking strategy noted in
/// CONFERENCE_MODE.md / BACKLOG.)
enum ConferenceTranscriber {
    static func stream(_ url: URL, windowSeconds: Double = 45) -> AsyncStream<String> {
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
                let windowFrames = AVAudioFrameCount(max(1, srcFormat.sampleRate * windowSeconds))
                var full = ""
                while file.framePosition < file.length, !Task.isCancelled {
                    guard let window = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: windowFrames) else { break }
                    do { try file.read(into: window, frameCount: windowFrames) } catch { break }
                    if window.frameLength == 0 { break }
                    guard let samples = Self.mono16k(window) else { continue }
                    let text = await Self.transcribe(samples, backend: backend, options: options)
                    if !text.isEmpty {
                        full += full.isEmpty ? text : " " + text
                        continuation.yield(full)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downmixes + resamples one window buffer to the backends' canonical 16 kHz mono float.
    private static func mono16k(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.format, to: target) else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return input
        }
        guard status != .error, let channel = output.floatChannelData, output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Runs one window's samples through a backend's stream path and returns the final text.
    private static func transcribe(_ samples: [Float], backend: any TranscriptionService,
                                   options: TranscriptionOptions) async -> String {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        continuation.yield(AudioChunk(samples: samples, sampleRate: 16_000))
        continuation.finish()
        var text = ""
        do {
            for try await event in backend.stream(stream, options: options) {
                if case .final(let result) = event { text = result.text }
            }
        } catch { return text }
        return text
    }
}
