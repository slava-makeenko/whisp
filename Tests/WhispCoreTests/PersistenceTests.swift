import Testing
import Foundation
import SwiftData
@testable import WhispCore

@Suite(.serialized) struct PersistenceTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The container builds with three separate stores and persists each model independently.
    @Test func persistsAcrossThreeStores() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = try PersistenceController.makeContainer(localBuild: true, directory: dir)
        let ctx = ModelContext(container)

        ctx.insert(Transcription(text: "hello world", backend: "whisper"))
        ctx.insert(DictionaryEntry(term: "Whisp", replacement: "Whisp"))
        ctx.insert(SessionMetric(wordsDictated: 2))
        try ctx.save()

        #expect(try ctx.fetchCount(FetchDescriptor<Transcription>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<DictionaryEntry>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<SessionMetric>()) == 1)

        // Distinct store files were created on disk.
        for name in ["transcriptions.store", "metrics.store", "dictionary.store"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
    }

    /// `wordCount` is derived on the convenience initializer.
    @Test func transcriptionDerivesWordCount() {
        #expect(Transcription(text: "one two three").wordCount == 3)
        #expect(Transcription(text: "   ").wordCount == 0)
    }
}
