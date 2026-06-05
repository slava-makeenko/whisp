import Foundation

/// On-device text post-processing for dictated speech. Applied when no LLM is configured.
/// Conservative by design: never rephrases, never removes real content — only fixes the
/// mechanical artifacts that ASR engines consistently produce.
public enum LocalTextCleaner {

    // MARK: - Filler words

    /// Unambiguous hesitation sounds only. Real discourse markers ("ну", "like", "actually")
    /// are excluded — they're too often meaningful to remove blindly.
    private static let fillerPatterns: [(pattern: String, replacement: String)] = [
        // English hesitations
        (#"(?i)\b(umm?m?|uhh?|uhm|err?m?|hmm+)\b,?"#,     ""),
        // Russian hesitations — only the pure phonetic ones, never real words
        (#"(?i)\b(эм+|ээ+|мм+|ага ага|угу угу)\b,?"#,     ""),
        // Standalone "ну вот" at sentence boundary (almost always filler)
        (#"(?i)(^|\.\s+)ну вот[,]?\s+"#,                   "$1"),
        (#"(?i)\s+ну вот[,]?(\.|$)"#,                      "$1"),
    ]

    // MARK: - Public API

    public static func clean(_ text: String) -> String {
        var result = text
        result = removeFillersAndHesitations(result)
        result = removeConsecutiveDuplicates(result)
        result = fixWhitespaceAroundPunctuation(result)
        result = collapseWhitespace(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove dangling conjunctions BEFORE adding trailing punctuation so we
        // don't add a period and then need to match through it.
        result = removeTrailingConjunction(result)
        result = addTrailingPunctuationIfMissing(result)
        result = capitalizeAfterSentenceEnd(result)
        return capitalizeFirst(result)
    }

    // MARK: - Steps

    private static func removeFillersAndHesitations(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in fillerPatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement,
                                                  options: .regularExpression)
        }
        return result
    }

    /// Removes consecutive duplicate words produced by ASR glitches.
    /// "the the fox" → "the fox", "и и и так" → "и так"
    private static func removeConsecutiveDuplicates(_ text: String) -> String {
        // Match a word (incl. Cyrillic) followed by optional punctuation, space(s), then itself again.
        let pattern = #"(?i)\b(\p{L}+)\b([,]?\s+)\1\b"#
        var result = text
        // Run twice to catch triple repeats ("the the the").
        for _ in 0..<2 {
            result = result.replacingOccurrences(of: pattern, with: "$1",
                                                  options: .regularExpression)
        }
        return result
    }

    private static func fixWhitespaceAroundPunctuation(_ text: String) -> String {
        // Remove space before punctuation: "hello , world" → "hello, world"
        text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1",
                                   options: .regularExpression)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// Capitalizes the first letter after each sentence-ending punctuation (. ! ?).
    /// Only applies when the next non-space character is a lowercase letter — avoids
    /// touching acronyms or already-correct text.
    private static func capitalizeAfterSentenceEnd(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"([.!?]\s+)([a-zа-яёa-z])"#, options: []) else { return text }
        let ns = text as NSString
        var result = text
        var offset = 0
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let letterRange = Range(match.range(at: 2), in: result) else { continue }
            let shifted = result.index(letterRange.lowerBound,
                                       offsetBy: offset, limitedBy: result.endIndex) ?? letterRange.lowerBound
            let shiftedRange = shifted..<result.index(shifted, offsetBy: 1)
            let upper = result[shiftedRange].uppercased()
            result.replaceSubrange(shiftedRange, with: upper)
        }
        _ = ns  // suppress "unused" warning
        return result
    }

    /// Adds a period at the very end if the text has no terminal punctuation.
    /// Skips if text looks like a code snippet (contains backticks, braces, semicolons).
    private static func addTrailingPunctuationIfMissing(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let terminators = CharacterSet(charactersIn: ".!?…")
        let codeIndicators = CharacterSet(charactersIn: "`{}();")
        // Don't add punctuation to code-like content.
        guard text.unicodeScalars.allSatisfy({ !codeIndicators.contains($0) }) else { return text }
        guard !terminators.contains(text.unicodeScalars.last!) else { return text }
        return text + "."
    }

    /// Removes a dangling coordinating conjunction at the very end of text —
    /// e.g. "это хорошо и" (ASR cut-off). Uses \b to avoid matching word
    /// endings like the "а" in "дела".
    private static func removeTrailingConjunction(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s*,?\s*\b(and|or|but|и|или|но|а|потому что|потому)\b\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
