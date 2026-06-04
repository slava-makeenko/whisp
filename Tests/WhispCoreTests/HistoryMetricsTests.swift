import Testing
import Foundation
import SwiftData
@testable import WhispCore

@Suite(.serialized) struct HistoryMetricsTests {

    private func makeContainer() throws -> ModelContainer {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-hm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PersistenceController.makeContainer(localBuild: true, directory: dir)
    }

    @Test func historyAddSearchExport() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        try await store.add(text: "hello world", durationMs: 1000, backend: "whisper", appBundleID: "com.app")
        try await store.add(text: "draft email", durationMs: 2000, backend: "native", appBundleID: nil)

        #expect(try await store.recent(limit: 10).count == 2)

        let found = try await store.search("draft")
        #expect(found.count == 1)
        #expect(found.first?.text == "draft email")

        let csv = try await store.exportCSV()
        #expect(csv.hasPrefix("date,backend,app,words,text"))
        #expect(csv.contains("\"hello world\""))
    }

    @Test func historyDelete() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        try await store.add(text: "one", durationMs: 1, backend: "x", appBundleID: nil)
        let dto = try #require(try await store.recent(limit: 1).first)
        try await store.delete(id: dto.id)
        #expect(try await store.recent(limit: 10).isEmpty)
    }

    @Test func metricsSummaryAggregates() {
        let metrics = [
            SessionMetric(wordsDictated: 100, keystrokesSaved: 500, activeSeconds: 60, wpm: 100),
            SessionMetric(wordsDictated: 50, keystrokesSaved: 250, activeSeconds: 60, wpm: 50),
        ]
        let summary = MetricsSummary.from(metrics, typingWPM: 40)
        #expect(summary.totalKeystrokes == 750)
        #expect(abs(summary.avgWPM - 75) < 0.001)
        // words=150 → typed 3.75 min; speaking 120 s = 2 min; saved = 1.75 min
        #expect(abs(summary.timeSavedMinutes - 1.75) < 0.001)
    }

    @Test func metricsStoreRecordAndSummary() async throws {
        let store = MetricsStore(modelContainer: try makeContainer())
        try await store.record(text: "one two three", durationMs: 60_000)
        let summary = try await store.summary()
        #expect(summary.totalKeystrokes == 13)   // "one two three"
    }
}
