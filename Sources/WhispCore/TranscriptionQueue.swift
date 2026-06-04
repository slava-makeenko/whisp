import Foundation
import WhispASR

public struct TranscriptionJob: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case queued
        case running
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

/// Serial file-transcription queue. Selects/prepares a backend once, then runs each file
/// through `transcribeFile`. Job updates are published via the `updates` stream.
// VERIFY-FILE-1: audio files go straight to the backend; video containers need an audio
// extraction step (AVAsset) — a later refinement, so video jobs may fail until then.
public actor TranscriptionQueue {
    private let router: TranscriptionRouter
    private let options: TranscriptionOptions
    private var jobs: [TranscriptionJob] = []
    private var processing = false

    public nonisolated let updates: AsyncStream<[TranscriptionJob]>
    private let continuation: AsyncStream<[TranscriptionJob]>.Continuation

    public init(router: TranscriptionRouter, options: TranscriptionOptions = .init()) {
        self.router = router
        self.options = options
        (updates, continuation) = AsyncStream.makeStream(of: [TranscriptionJob].self)
    }

    public func currentJobs() -> [TranscriptionJob] { jobs }

    public func enqueue(_ urls: [URL]) async {
        for url in urls { jobs.append(TranscriptionJob(url: url)) }
        emit()
        await processPending()
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
            jobs[index].state = .running
            emit()
            do {
                let result = try await service.transcribeFile(url, options: options)
                update(id, .done(result.text))
            } catch {
                update(id, .failed(String(describing: error)))
            }
        }
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
}
