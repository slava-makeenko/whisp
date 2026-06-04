import Foundation
import Observation
import WhispCore

/// Observable bridge over the actor-based `TranscriptionQueue` for SwiftUI.
@MainActor
@Observable
final class FileQueueModel {
    private(set) var jobs: [TranscriptionJob] = []
    private let queue: TranscriptionQueue

    init(queue: TranscriptionQueue) { self.queue = queue }

    func start() async {
        for await jobs in queue.updates { self.jobs = jobs }
    }

    func enqueue(_ urls: [URL]) {
        Task { await queue.enqueue(urls) }
    }
}
