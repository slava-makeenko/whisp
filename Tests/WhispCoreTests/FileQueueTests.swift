import Testing
import Foundation
import WhispAudio
import WhispASR
@testable import WhispCore

@Suite struct FileQueueTests {

    private struct StubFileTranscriber: TranscriptionService {
        let id = TranscriptionBackendID.whisper
        let text: String
        func availability(for options: TranscriptionOptions) async -> BackendAvailability { .ready }
        func prepare(_ options: TranscriptionOptions) async throws {}
        func stream(_ audio: AudioStream, options: TranscriptionOptions)
            -> AsyncThrowingStream<TranscriptionEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func transcribeFile(_ url: URL, options: TranscriptionOptions) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, segments: [], backend: id)
        }
    }

    @Test func processesAllQueuedFiles() async throws {
        let queue = TranscriptionQueue(
            router: TranscriptionRouter(backends: [StubFileTranscriber(text: "transcript")]))
        await queue.enqueue([URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.m4a")])
        let jobs = await queue.currentJobs()
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.state == .done("transcript") })
    }

    @Test func failsWhenNoBackendAvailable() async throws {
        let queue = TranscriptionQueue(router: TranscriptionRouter(backends: []))
        await queue.enqueue([URL(fileURLWithPath: "/tmp/a.wav")])
        let jobs = await queue.currentJobs()
        #expect(jobs.count == 1)
        guard case .failed = jobs.first?.state else {
            Issue.record("expected the job to fail")
            return
        }
    }
}
