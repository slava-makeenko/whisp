import Testing
import Foundation
@testable import WhispLLM

@Suite struct LLMTests {
    private let provider = LLMProvider(
        id: "openai", displayName: "OpenAI",
        baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-4o-mini")

    @Test func buildsOpenAICompatibleRequest() throws {
        let request = URLSessionLLMEnhancer.makeRequest(
            text: "hello", prompt: "Fix grammar.", provider: provider, apiKey: "secret-key")

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "gpt-4o-mini")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.last?["content"] == "hello")
    }

    @Test func parsesChatCompletion() throws {
        let json = #"{"choices":[{"message":{"content":"Hello."}}]}"#.data(using: .utf8)!
        #expect(try URLSessionLLMEnhancer.parse(json) == "Hello.")
    }

    @Test func localCleanerStripsFillersAndTidies() {
        let cleaned = LocalTextCleaner.clean("um, this is uh a test эм да")
        #expect(cleaned.first == "T")           // capitalized
        #expect(!cleaned.contains(" uh "))      // English filler gone
        #expect(!cleaned.contains("эм"))        // Russian filler gone
        #expect(cleaned.contains("test"))       // real words kept
        #expect(!cleaned.contains("  "))        // no double spaces
    }
}
