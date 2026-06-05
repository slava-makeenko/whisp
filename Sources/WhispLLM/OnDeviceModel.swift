import Foundation

/// Metadata for a downloadable on-device LLM. Models are GGUF format (single file),
/// ready for llama.cpp / MLX inference. Stored locally in Application Support.
public struct OnDeviceModel: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String
    public let badge: String          // e.g. "1B", "3B", "3.8B"
    public let sizeBytes: Int64       // approximate download size
    public let languages: [String]    // language codes this model handles well
    public let downloadURL: URL
    public let filename: String       // local filename in Application Support

    public var sizeFormatted: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb / 1_048_576 * 1024)
    }

    public static let catalog: [OnDeviceModel] = [
        OnDeviceModel(
            id: "llama-3.2-1b",
            displayName: "Llama 3.2 1B",
            description: "Fast and lightweight. Best for quick clean-up and chat. Works well for English.",
            badge: "1B",
            sizeBytes: 770_000_000,
            languages: ["en"],
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            filename: "llama-3.2-1b-instruct-q4.gguf"
        ),
        OnDeviceModel(
            id: "qwen-2.5-3b",
            displayName: "Qwen 2.5 3B",
            description: "Balanced quality and size. Strong multilingual support including Russian and English.",
            badge: "3B",
            sizeBytes: 1_900_000_000,
            languages: ["en", "ru", "zh"],
            downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!,
            filename: "qwen2.5-3b-instruct-q4.gguf"
        ),
        OnDeviceModel(
            id: "phi-3.5-mini",
            displayName: "Phi 3.5 Mini",
            description: "High quality reasoning. Great for email and structured text. Requires more RAM.",
            badge: "3.8B",
            sizeBytes: 2_200_000_000,
            languages: ["en", "ru"],
            downloadURL: URL(string: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf")!,
            filename: "phi-3.5-mini-instruct-q4.gguf"
        ),
    ]
}
