import Foundation
import AVFoundation
import WhispAudio
import WhispASR

public struct TranscriptionJob: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case queued
        case running(Double)   // 0…1 progress
        case done(String)
        case failed(String)
    }
    public let id: UUID
    public let url: URL
    public var state: State

    public init(id: UUID = UUID(), url: URL, state: State = .queued) {
        self.id = id
        self.url = url
        self.state = state
    }
}

/// Serial file-transcription queue. Selects/prepares a backend once, then runs each file in time
/// windows so it reports real progress (and streams text). Video containers have their audio track
/// extracted first (`MediaPreparer`). Job updates are published via the `updates` stream.
public actor TranscriptionQueue {
    private let router: TranscriptionRouter
    private let options: TranscriptionOptions
    private var jobs: [TranscriptionJob] = []
    private var processing = false

    /// Optional post-processing applied to each file's transcript (same pipeline as dictation).
    public var textPostProcessor: (@Sendable (String) async -> String)?

    public nonisolated let updates: AsyncStream<[TranscriptionJob]>
    private let continuation: AsyncStream<[TranscriptionJob]>.Continuation

    public init(router: TranscriptionRouter,
                options: TranscriptionOptions = .init(),
                textPostProcessor: (@Sendable (String) async -> String)? = nil) {
        self.router = router
        self.options = options
        self.textPostProcessor = textPostProcessor
        (updates, continuation) = AsyncStream.makeStream(of: [TranscriptionJob].self)
    }

    public func currentJobs() -> [TranscriptionJob] { jobs }

    public func enqueue(_ urls: [URL]) async {
        for url in urls { jobs.append(TranscriptionJob(url: url)) }
        emit()
        await processPending()
    }

    /// Re-queues a failed job and resumes draining.
    public func retry(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              case .failed = jobs[index].state else { return }
        jobs[index].state = .queued
        emit()
        await processPending()
    }

    /// Drops a job from the queue (e.g. once it's been moved to the Files history).
    public func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        emit()
    }

    private func processPending() async {
        guard !processing else { return }   // a running drain will pick up newly-queued jobs
        processing = true
        defer { processing = false }

        let service: any TranscriptionService
        do {
            service = try await router.select(for: options)
            try await service.prepare(options)
        } catch {
            failQueued(error)
            return
        }

        while let index = jobs.firstIndex(where: { $0.state == .queued }) {
            let id = jobs[index].id
            let url = jobs[index].url
            jobs[index].state = .running(0)
            emit()
            // Video → extract audio to a temp .m4a first; audio files transcribe in place.
            let extracted = await MediaPreparer.extractedAudioURL(for: url)
            defer { if let extracted { try? FileManager.default.removeItem(at: extracted) } }
            do {
                let raw = try await transcribeWindowed(extracted ?? url, service: service, jobID: id)
                let text = await textPostProcessor?(raw) ?? raw
                update(id, .done(text))
            } catch {
                update(id, .failed(String(describing: error)))
            }
        }
    }

    /// Transcribes `url` in ~30 s windows, updating the job's progress after each. Falls back to a
    /// one-shot decode if the file can't be opened as audio frames.
    private func transcribeWindowed(_ url: URL, service: any TranscriptionService, jobID: UUID) async throws -> String {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            return try await service.transcribeFile(url, options: options).text
        }
        let format = file.processingFormat
        let total = file.length
        let windowFrames = AVAudioFrameCount(max(1, format.sampleRate * 30))
        var fullText = ""
        while file.framePosition < total, !Task.isCancelled {
            guard let window = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else { break }
            try file.read(into: window, frameCount: windowFrames)
            if window.frameLength == 0 { break }
            if let samples = Self.mono16k(window) {
                let text = try await Self.transcribeWindow(samples, service: service, options: options)
                if !text.isEmpty { fullText += fullText.isEmpty ? text : " " + text }
            }
            update(jobID, .running(min(1, Double(file.framePosition) / Double(total))))
        }
        return fullText
    }

    private func failQueued(_ error: Error) {
        for index in jobs.indices where jobs[index].state == .queued {
            jobs[index].state = .failed(String(describing: error))
        }
        emit()
    }

    private func update(_ id: UUID, _ state: TranscriptionJob.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        emit()
    }

    private func emit() { continuation.yield(jobs) }

    // MARK: - Windowed decode helpers (nonisolated: pure, no actor state)

    private nonisolated static func transcribeWindow(_ samples: [Float], service: any TranscriptionService,
                                                     options: TranscriptionOptions) async throws -> String {
        let (stream, cont) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        cont.yield(AudioChunk(samples: samples, sampleRate: 16_000))
        cont.finish()
        var text = ""
        for try await event in service.stream(stream, options: options) {
            if case .final(let result) = event { text = result.text }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downmixes a window to mono and resamples it to the backends' canonical 16 kHz mono float.
    private nonisolated static func mono16k(_ input: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(input.frameLength)
        guard frames > 0, let src = input.floatChannelData else { return nil }
        let channels = Int(input.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let p = src[c]
            for i in 0..<frames { mono[i] += p[i] }
        }
        if channels > 1 { let inv = 1 / Float(channels); for i in 0..<frames { mono[i] *= inv } }

        let rate = input.format.sampleRate
        if rate == 16_000 { return mono }

        guard let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                          channels: 1, interleaved: false),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(frames)),
              let dst = monoBuf.floatChannelData,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFmt, to: target) else { return mono }
        monoBuf.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { dst[0].update(from: $0.baseAddress!, count: frames) }

        let capacity = AVAudioFrameCount(Double(frames) * 16_000 / rate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return mono }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return monoBuf
        }
        guard status != .error, let channel = output.floatChannelData, output.frameLength > 0 else { return mono }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
