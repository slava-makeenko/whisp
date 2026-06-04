import Foundation
import WhispLLM
import WhispPlatform

/// A selectable OpenAI-compatible enhancement provider. Each keeps its own API key in the Keychain.
/// (Anthropic is reached via its OpenAI-compatibility layer at `/v1/chat/completions`.)
enum EnhancementProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case groq = "groq"
    case openRouter = "openrouter"
    case anthropic = "anthropic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:     "OpenAI"
        case .groq:       "Groq"
        case .openRouter: "OpenRouter"
        case .anthropic:  "Anthropic"
        }
    }

    var baseURL: URL {
        switch self {
        case .openAI:     URL(string: "https://api.openai.com/v1")!
        case .groq:       URL(string: "https://api.groq.com/openai/v1")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .anthropic:  URL(string: "https://api.anthropic.com/v1")!   // OpenAI-compatibility layer
        }
    }

    var models: [String] {
        switch self {
        case .openAI:     ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]
        case .groq:       ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b", "qwen3-32b"]
        case .openRouter: ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "meta-llama/llama-3.3-70b-instruct", "google/gemini-2.0-flash-001"]
        case .anthropic:  ["claude-3-5-haiku-latest", "claude-3-5-sonnet-latest"]
        }
    }

    var defaultModel: String { models.first ?? "" }

    var secretKey: SecretKey {
        switch self {
        case .openAI:     .llmProviderAPIKey
        case .groq:       .groqAPIKey
        case .openRouter: .openRouterAPIKey
        case .anthropic:  .anthropicAPIKey
        }
    }

    func llmProvider(model: String) -> LLMProvider {
        LLMProvider(id: rawValue, displayName: displayName, baseURL: baseURL,
                    model: model.isEmpty ? defaultModel : model)
    }
}

/// A formatting "mode": how transcriptions are formatted after recognition. `raw` keeps them verbatim;
/// the named ones rewrite the *text* (never the audio) via the configured LLM (`cleanUp` also has an
/// on-device fallback). `auto` adapts to the focused app — an explicit Power Mode rule, else a
/// per-app-category heuristic.
enum EnhancementStyle: String, CaseIterable, Identifiable {
    case auto, cleanUp, email, chat, code, raw, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto:    "Auto"
        case .cleanUp: "Clean-up"
        case .email:   "Email"
        case .chat:    "Message"
        case .code:    "Code"
        case .raw:     "Raw"
        case .custom:  "Custom"
        }
    }

    /// LLM system prompt; `nil` for `raw`/`auto` (resolved elsewhere) and `custom` (user's own prompt).
    var prompt: String? {
        switch self {
        case .raw, .auto, .custom: nil
        case .cleanUp:
            "You clean up dictated text. Remove hesitation/filler words (um, uh, like, you know, эм, ну, как бы), fix punctuation and capitalization, and break it into sentences. Keep the original meaning, wording and language. Output ONLY the cleaned text."
        case .email:
            "Rewrite this dictated text as a clear, professional email body: fix grammar, remove filler words, structure into paragraphs. Keep the original meaning and language. Output ONLY the email text (no subject/greeting unless dictated)."
        case .chat:
            "Rewrite this dictated text as a casual, concise chat message: remove filler words, fix punctuation, keep it natural and brief. Keep the original meaning and language. Output ONLY the message."
        case .code:
            "Format this dictated text as a precise technical note or code comment: fix terminology and punctuation, remove filler words. Keep the original meaning and language. Output ONLY the formatted text."
        }
    }

    /// Resolves `auto` to a concrete style from the focused app's bundle id: Mail → email, chat apps →
    /// message, code editors / terminals → code, otherwise a light clean-up.
    static func autoStyle(forBundleID bundleID: String?) -> EnhancementStyle {
        guard let id = bundleID?.lowercased() else { return .cleanUp }
        if id.contains("mail") || id.contains("outlook") || id.contains("spark") || id.contains("airmail") {
            return .email
        }
        if id.contains("slack") || id.contains("mobilesms") || id.contains("telegram")
            || id.contains("discord") || id.contains("whatsapp") || id.contains("signal")
            || id.contains("messenger") || id.contains("textual") {
            return .chat
        }
        if id.contains("xcode") || id.contains("vscode") || id.contains("terminal") || id.contains("iterm")
            || id.contains("warp") || id.contains("jetbrains") || id.contains("intellij")
            || id.contains("sublime") || id.contains("nova") || id.contains("zed") || id.contains("cursor") {
            return .code
        }
        return .cleanUp
    }
}
