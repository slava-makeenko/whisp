import Testing
import Foundation
import SwiftData
@testable import WhispCore

@Suite(.serialized) struct DictionaryTests {
    private func makeContainer() throws -> ModelContainer {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-dict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PersistenceController.makeContainer(localBuild: true, directory: dir)
    }

    @Test func processorAppliesReplacements() {
        let replacements = [
            Replacement(term: "github", replacement: "GitHub"),
            Replacement(term: "kubernetes", replacement: "Kubernetes"),
        ]
        #expect(DictionaryProcessor.apply(replacements, to: "pushed to github, deployed kubernetes")
                == "pushed to GitHub, deployed Kubernetes")
    }

    @Test func processorIsCaseInsensitive() {
        #expect(DictionaryProcessor.apply([Replacement(term: "ios", replacement: "iOS")], to: "IOS and ios")
                == "iOS and iOS")
    }

    @Test func storeCRUDAndReplacements() async throws {
        let store = DictionaryStore(modelContainer: try makeContainer())
        try await store.add(term: "github", replacement: "GitHub")
        try await store.add(term: "noop", replacement: "")    // empty replacement → excluded from substitutions
        #expect(try await store.all().count == 2)

        let replacements = try await store.enabledReplacements()
        #expect(replacements.count == 1)
        #expect(replacements.first?.replacement == "GitHub")

        let id = try #require(try await store.all().first { $0.term == "github" }?.id)
        try await store.delete(id: id)
        #expect(try await store.all().count == 1)
    }
}
