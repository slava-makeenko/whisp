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
            """
            You are a precise speech-to-text editor. Clean up the following dictated text by:
            1. Removing filler/hesitation words (um, uh, er, hmm, эм, ну вот, короче, типа, как бы, вот, значит — only when they are clearly fillers, not when they carry meaning).
            2. Removing consecutive duplicate words ("the the" → "the", "и и" → "и").
            3. Adding missing punctuation: periods at sentence ends, commas before conjunctions, question marks for questions.
            4. Capitalizing the start of every sentence and proper nouns.
            5. Removing dangling conjunctions at the very end (e.g. text cut off mid-phrase).
            Rules: NEVER rephrase, paraphrase, or add content. NEVER translate. Preserve the exact wording, all languages, and all code/technical terms verbatim. Output ONLY the cleaned text.
            """

        case .email:
            """
            Rewrite the following dictated text as a polished email body:
            - Fix grammar, punctuation, and remove filler words.
            - Structure into clear paragraphs with logical flow.
            - Use a professional yet natural tone.
            - Do NOT translate — preserve every language used by the speaker.
            - Do NOT add a subject line, greeting, or sign-off unless explicitly dictated.
            Output ONLY the email body text, nothing else.
            """

        case .chat:
            """
            Rewrite the following dictated text as a natural, concise chat message:
            - Remove filler words and false starts.
            - Fix punctuation and capitalization.
            - Keep it brief and conversational — do not expand or formalize.
            - Do NOT translate — preserve every language used.
            Output ONLY the message text, nothing else.
            """

        case .code:
            """
            You are a developer's dictation assistant. Process the following dictated text:
            - If it describes code: convert spoken syntax to correct code (e.g. "open paren" → "(", "dot" → ".", "equals equals" → "==", "new line" → actual newline).
            - If it is a comment or technical note: fix grammar, remove fillers, use precise technical terminology.
            - Remove duplicate words and hesitations.
            - Do NOT translate. Do NOT add explanations.
            Output ONLY the processed text or code, nothing else.
            """
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
