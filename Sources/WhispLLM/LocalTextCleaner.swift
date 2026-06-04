import Foundation

/// Lightweight, on-device tidy-up used when no LLM is configured. Conservatively strips hesitation
/// sounds and normalizes spacing/capitalization — it never rephrases or changes wording.
public enum LocalTextCleaner {
    /// Only unambiguous hesitation sounds — never real words like "ну", "like" or "actually".
    private static let fillers = ["um", "umm", "ummm", "uh", "uhh", "uhm", "er", "erm", "ah",
                                  "эм", "эмм", "ээ", "эээ", "ммм", "мм"]

    public static func clean(_ text: String) -> String {
        var result = text
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            result = result.replacingOccurrences(of: "(?i)\\b\(escaped)\\b,?",
                                                 with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = result.first else { return result }
        return first.uppercased() + result.dropFirst()
    }
}
