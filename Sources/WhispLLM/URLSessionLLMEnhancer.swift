import Foundation

public enum LLMError: Error, Sendable {
    case badResponse(Int)
    case emptyResponse
}

/// Default OpenAI-compatible enhancer (the LLMkit fork swaps in later — P1).
/// The API key is injected at construction by the composition (read from the Keychain),
/// never persisted in settings backups or logged.
public struct URLSessionLLMEnhancer: LLMEnhancer {
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func enhance(_ text: String, prompt: String, provider: LLMProvider) async throws -> String {
        let (data, response) = try await session.data(
            for: Self.makeRequest(text: text, prompt: prompt, provider: provider, apiKey: apiKey))
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw LLMError.badResponse(http.statusCode) }
        return try Self.parse(data)
    }

    static func makeRequest(text: String, prompt: String, provider: LLMProvider, apiKey: String) -> URLRequest {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else {
            throw LLMError.emptyResponse
        }
        return content
    }
}
