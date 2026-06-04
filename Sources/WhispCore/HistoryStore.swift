import Foundation
import SwiftData

/// Sendable snapshot of a history record for UI / cross-actor use (the `@Model` is not Sendable).
public struct TranscriptionDTO: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let backend: String
    public let appBundleID: String?
    public let wordCount: Int
}

/// Background-isolated writer/reader for the local history store.
@ModelActor
public actor HistoryStore {
    public func add(text: String, durationMs: Int, backend: String, appBundleID: String?) throws {
        modelContext.insert(Transcription(text: text, durationMs: durationMs,
                                          backend: backend, appBundleID: appBundleID))
        try modelContext.save()
    }

    public func recent(limit: Int) throws -> [TranscriptionDTO] {
        var descriptor = FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(Self.dto)
    }

    public func search(_ query: String) throws -> [TranscriptionDTO] {
        guard !query.isEmpty else { return try recent(limit: 100) }
        let predicate = #Predicate<Transcription> { $0.text.localizedStandardContains(query) }
        let descriptor = FetchDescriptor<Transcription>(
            predicate: predicate, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map(Self.dto)
    }

    public func delete(id: UUID) throws {
        try modelContext.delete(model: Transcription.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    public func exportCSV() throws -> String {
        let items = try modelContext.fetch(
            FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let formatter = ISO8601DateFormatter()
        var rows = ["date,backend,app,words,text"]
        for item in items {
            rows.append([
                formatter.string(from: item.createdAt),
                item.backend,
                item.appBundleID ?? "",
                String(item.wordCount),
                Self.csvEscape(item.text),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func dto(_ t: Transcription) -> TranscriptionDTO {
        TranscriptionDTO(id: t.id, text: t.text, createdAt: t.createdAt,
                         backend: t.backend, appBundleID: t.appBundleID, wordCount: t.wordCount)
    }

    private static func csvEscape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
