import Foundation
import Observation
import SwiftData
import WhispCore

/// Observable bridge over the actor-based `TranscriptionQueue` for SwiftUI. When a job finishes, its
/// file is copied into storage and saved as a `FileTranscription` (Files history), then dropped from
/// the in-progress card.
@MainActor
@Observable
final class FileQueueModel {
    private(set) var jobs: [TranscriptionJob] = []
    /// job.id → the saved `FileTranscription.id`, so a finished row links to its record in Files.
    private(set) var savedRecordIDs: [UUID: UUID] = [:]
    @ObservationIgnored var modelContainer: ModelContainer?
    @ObservationIgnored private let queue: TranscriptionQueue
    @ObservationIgnored private var persistedIDs = Set<UUID>()

    init(queue: TranscriptionQueue) { self.queue = queue }

    func start() async {
        for await jobs in queue.updates {
            for job in jobs {
                // Persist once on completion, but keep the row so it can link to the saved record.
                if case .done(let text) = job.state, persistedIDs.insert(job.id).inserted {
                    persist(job, text: text)
                }
            }
            self.jobs = jobs
        }
    }

    func recordID(for jobID: UUID) -> UUID? { savedRecordIDs[jobID] }

    func enqueue(_ urls: [URL]) {
        Task { await queue.enqueue(urls) }
    }

    func retry(_ id: UUID) {
        Task { await queue.retry(id) }
    }

    func remove(_ id: UUID) {
        Task { await queue.remove(id) }
    }

    /// Copies the source file off-main, then saves the FileTranscription on the main context and
    /// remembers its id so the finished card row can link to it.
    private func persist(_ job: TranscriptionJob, text: String) {
        guard let container = modelContainer else { return }
        let original = job.url
        let jobID = job.id
        Task.detached {
            var stored = ""
            if let dir = try? AppConstants.fileTranscriptionsDirectory() {
                let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(original.lastPathComponent)")
                if (try? FileManager.default.copyItem(at: original, to: dest)) != nil {
                    stored = dest.lastPathComponent
                }
            }
            let storedName = stored
            await MainActor.run {
                let record = FileTranscription(
                    title: original.deletingPathExtension().lastPathComponent,
                    transcript: text,
                    originalName: original.lastPathComponent,
                    storedFileName: storedName)
                container.mainContext.insert(record)
                try? container.mainContext.save()
                self.savedRecordIDs[jobID] = record.id
            }
        }
    }
}
