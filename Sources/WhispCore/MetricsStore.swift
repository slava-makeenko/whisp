import Foundation
import SwiftData

/// Aggregated productivity metrics for the dashboard.
public struct MetricsSummary: Sendable, Equatable {
    public let timeSavedMinutes: Double
    public let avgWPM: Double
    public let totalKeystrokes: Int

    /// `timeSaved` = words at an assumed typing speed minus the actual speaking time.
    public static func from(_ metrics: [SessionMetric], typingWPM: Double = 40) -> MetricsSummary {
        let words = metrics.reduce(0) { $0 + $1.wordsDictated }
        let keystrokes = metrics.reduce(0) { $0 + $1.keystrokesSaved }
        let seconds = metrics.reduce(0) { $0 + $1.activeSeconds }
        let avgWPM = metrics.isEmpty ? 0 : metrics.map(\.wpm).reduce(0, +) / Double(metrics.count)
        let saved = max(Double(words) / typingWPM - Double(seconds) / 60.0, 0)
        return MetricsSummary(timeSavedMinutes: saved, avgWPM: avgWPM, totalKeystrokes: keystrokes)
    }
}

/// Background-isolated writer for the local session-metrics store.
@ModelActor
public actor MetricsStore {
    public func record(text: String, durationMs: Int) throws {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let minutes = max(Double(durationMs) / 60_000.0, 0.0001)
        modelContext.insert(SessionMetric(
            date: .now,
            wordsDictated: words,
            keystrokesSaved: text.count,
            activeSeconds: durationMs / 1000,
            wpm: Double(words) / minutes))
        try modelContext.save()
    }

    public func summary() throws -> MetricsSummary {
        MetricsSummary.from(try modelContext.fetch(FetchDescriptor<SessionMetric>()))
    }
}
