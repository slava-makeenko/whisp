import Foundation
import SwiftData

/// A single vocabulary substitution.
public struct Replacement: Sendable, Equatable {
    public let term: String
    public let replacement: String
    public init(term: String, replacement: String) {
        self.term = term
        self.replacement = replacement
    }
}

/// Pure post-transcription substitution. Case-insensitive literal replacement, applied in order.
public enum DictionaryProcessor {
    public static func apply(_ replacements: [Replacement], to text: String) -> String {
        var result = text
        for replacement in replacements where !replacement.term.isEmpty {
            result = result.replacingOccurrences(
                of: replacement.term, with: replacement.replacement, options: [.caseInsensitive])
        }
        return result
    }
}

public struct DictionaryEntryDTO: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let term: String
    public let replacement: String
    public let isEnabled: Bool
}

/// Background-isolated CRUD over the dictionary store (CloudKit-synced in production).
@ModelActor
public actor DictionaryStore {
    public func add(term: String, replacement: String) throws {
        modelContext.insert(DictionaryEntry(term: term, replacement: replacement))
        try modelContext.save()
    }

    public func all() throws -> [DictionaryEntryDTO] {
        try modelContext.fetch(FetchDescriptor<DictionaryEntry>(sortBy: [SortDescriptor(\.term)]))
            .map { DictionaryEntryDTO(id: $0.id, term: $0.term, replacement: $0.replacement, isEnabled: $0.isEnabled) }
    }

    public func delete(id: UUID) throws {
        try modelContext.delete(model: DictionaryEntry.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    /// Enabled entries that actually substitute (non-empty replacement), for post-processing.
    public func enabledReplacements() throws -> [Replacement] {
        let predicate = #Predicate<DictionaryEntry> { $0.isEnabled }
        return try modelContext.fetch(FetchDescriptor<DictionaryEntry>(predicate: predicate))
            .filter { !$0.replacement.isEmpty }
            .map { Replacement(term: $0.term, replacement: $0.replacement) }
    }
}
