import Foundation

/// A user-configurable cloud LLM provider (OpenAI-compatible by default).
public struct LLMProvider: Codable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var baseURL: URL
    public var model: String

    public init(id: String, displayName: String, baseURL: URL, model: String) {
        self.id = id; self.displayName = displayName; self.baseURL = baseURL; self.model = model
    }
}

/// Optional post-transcription enhancement. The concrete implementation reads the API key
/// from the Keychain — it is never passed through settings or logs.
///
/// P1: swap in the LLMkit fork once its URL is known; a thin `URLSession` enhancer ships first.
public protocol LLMEnhancer: Sendable {
    func enhance(_ text: String, prompt: String, provider: LLMProvider) async throws -> String
}
