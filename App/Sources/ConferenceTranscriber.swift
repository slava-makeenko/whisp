import Foundation
import SwiftUI
import AVFoundation
import WhispAudio
import WhispASR

/// How a Conference recording is split into speakers. Persisted under `@AppStorage("conferenceMode")`.
enum ConferenceMode: String, CaseIterable, Identifiable {
    case mono, duo, speakers
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .mono:     "Mono"
        case .duo:      "Duo (Я / Собеседник)"
        case .speakers: "Speakers (multiple participants)"
        }
    }
    /// Shown under each option — what it does + the meeting length it's suited to.
    var hint: LocalizedStringKey {
        switch self {
        case .mono:     "One combined transcript, no speaker split. Works for meetings of any length."
        case .duo:      "Splits you vs the remote side by audio channel. Best for 1-on-1, up to ~1 hour."
        case .speakers: "Detects individual participants (Собеседник 1, 2…) on the remote side. Best for meetings up to ~20–30 min — diarization needs time and memory."
        }
    }
}

/// Transcribes a Conference Mode recording (stereo: L = mic = "Я", R = system = remote side) into a
/// chronological, speaker-labelled transcript. The split depends on the chosen `ConferenceMode`.
/// Each emitted value is the cumulative transcript so the UI updates incrementally.
enum ConferenceTranscriber {
    private struct Turn { let start: Double; let label: String; let text: String }

    static func stream(_ url: URL) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let mode = ConferenceMode(rawValue: UserDefaults.standard.string(forKey: "conferenceMode") ?? "duo") ?? .duo
                let router = TranscriptionBackends.makeRouter()
                let options = TranscriptionOptions()
                var backend: (any TranscriptionService)?
                for candidate in await router.orderedReadyBackends(for: options) {
                    do { try await candidate.prepare(options); backend = candidate; break }
                    catch { continue }
                }
                guard let backend else { continuation.finish(); return }

                switch mode {
                case .speakers:
                    await transcribeSpeakers(url, backend: backend, options: options, emit: { continuation.yield($0) })
                case .mono:
                    await transcribeWindowed(url, backend: backend, options: options,
                                             labels: .mono, emit: { continuation.yield($0) })
                case .duo:
                    await transcribeWindowed(url, backend: backend, options: options,
                                             labels: .duo, emit: { continuation.yield($0) })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Labelling { case mono, duo }

    // MARK: - Mono / Duo (incremental, bounded memory — any meeting length)

    private static func transcribeWindowed(_ url: URL, backend: any TranscriptionService,
                                           options: TranscriptionOptions, labels: Labelling,
                                           emit: (String) -> Void) async {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return }
        let format = file.processingFormat
        let stereo = format.channelCount > 1
        let windowFrames = AVAudioFrameCount(max(1, format.sampleRate * 15))
        var lines: [String] = []
        while file.framePosition < file.length, !Task.isCancelled {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else { break }
            do { try file.read(into: buffer, frameCount: windowFrames) } catch { break }
            if buffer.frameLength == 0 { break }

            switch labels {
            case .mono:
                // Downmix every channel to one stream — a single, label-free transcript.
                if let samples = mono16k(buffer, channel: nil), rms(samples) > 0.0015 {
                    let text = await transcribe(samples, backend: backend, options: options)
                    if !text.isEmpty { lines.append(text); emit(lines.joined(separator: "\n")) }
                }
            case .duo:
                let me = await transcribeChannel(buffer, channel: 0, backend: backend, options: options)
                let other = stereo ? await transcribeChannel(buffer, channel: 1, backend: backend, options: options) : ""
                if !me.isEmpty { lines.append("Я: \(me)") }
                if !other.isEmpty { lines.append("Собеседник: \(other)") }
                if !me.isEmpty || !other.isEmpty { emit(lines.joined(separator: "\n")) }
            }
        }
    }

    // MARK: - Speakers (full-array diarization)

    private static func transcribeSpeakers(_ url: URL, backend: any TranscriptionService,
                                           options: TranscriptionOptions, emit: (String) -> Void) async {
        guard let channels = loadChannels16k(url) else { return }
        let mic = channels.mic, system = channels.system
        var turns: [Turn] = []
        func flush() {
            emit(turns.sorted { $0.start < $1.start }.map { "\($0.label): \($0.text)" }.joined(separator: "\n"))
        }

        // Mic ("Я") in 15 s windows so it interleaves by time with the remote side.
        let window = 16_000 * 15
        var i = 0
        while i < mic.count, !Task.isCancelled {
            let end = min(i + window, mic.count)
            let slice = Array(mic[i..<end])
            if rms(slice) > 0.0015 {
                let text = await transcribe(slice, backend: backend, options: options)
                if !text.isEmpty { turns.append(Turn(start: Double(i) / 16_000, label: "Я", text: text)); flush() }
            }
            i = end
        }

        guard !system.isEmpty else { return }
        let segments = (try? await SpeakerDiarizer().diarize(system)) ?? []
        if segments.isEmpty {
            // Diarization unavailable → single remote label, windowed.
            var j = 0
            while j < system.count, !Task.isCancelled {
                let end = min(j + window, system.count)
                let slice = Array(system[j..<end])
                if rms(slice) > 0.0015 {
                    let text = await transcribe(slice, backend: backend, options: options)
                    if !text.isEmpty { turns.append(Turn(start: Double(j) / 16_000, label: "Собеседник", text: text)); flush() }
                }
                j = end
            }
            return
        }
        var labels: [String: String] = [:]
        var order = 1
        for seg in segments where (seg.end - seg.start) >= 0.8 && !Task.isCancelled {
            let s = max(0, Int(seg.start * 16_000)), e = min(Int(seg.end * 16_000), system.count)
            guard s < e else { continue }
            let slice = Array(system[s..<e])
            guard rms(slice) > 0.0015 else { continue }
            let text = await transcribe(slice, backend: backend, options: options)
            guard !text.isEmpty else { continue }
            let label = labels[seg.speakerId] ?? {
                let new = "Собеседник \(order)"; labels[seg.speakerId] = new; order += 1; return new
            }()
            turns.append(Turn(start: seg.start, label: label, text: text)); flush()
        }
    }

    // MARK: - Helpers

    private static func transcribeChannel(_ buffer: AVAudioPCMBuffer, channel: Int,
                                          backend: any TranscriptionService, options: TranscriptionOptions) async -> String {
        guard let samples = mono16k(buffer, channel: channel), rms(samples) > 0.0015 else { return "" }
        return await transcribe(samples, backend: backend, options: options)
    }

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
        } catch { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadChannels16k(_ url: URL) -> (mic: [Float], system: [Float])? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let stereo = format.channelCount > 1
        let windowFrames = AVAudioFrameCount(max(1, format.sampleRate * 30))
        var mic: [Float] = [], system: [Float] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else { break }
            do { try file.read(into: buffer, frameCount: windowFrames) } catch { break }
            if buffer.frameLength == 0 { break }
            if let m = mono16k(buffer, channel: 0) { mic.append(contentsOf: m) }
            if stereo, let s = mono16k(buffer, channel: 1) { system.append(contentsOf: s) }
        }
        return (mic, system)
    }

    /// Resamples to 16 kHz mono. `channel == nil` downmixes all channels; otherwise extracts one.
    private static func mono16k(_ input: AVAudioPCMBuffer, channel: Int?) -> [Float]? {
        let frames = Int(input.frameLength)
        guard frames > 0, let src = input.floatChannelData else { return nil }
        let channelCount = Int(input.format.channelCount)
        if let channel, channel >= channelCount { return nil }

        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: input.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let monoDst = mono.floatChannelData else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        if let channel {
            monoDst[0].update(from: src[channel], count: frames)
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += src[c][i] }
                monoDst[0][i] = sum / Float(channelCount)
            }
        }

        if input.format.sampleRate == 16_000 {
            return Array(UnsafeBufferPointer(start: monoDst[0], count: frames))
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: target) else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * 16_000 / input.format.sampleRate) + 1024
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
