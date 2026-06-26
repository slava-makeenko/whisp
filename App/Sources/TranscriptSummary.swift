import SwiftUI
import WhispLLM
import WhispPlatform

enum SummarizerError: Error { case noKey, emptyTranscript }

/// Generates an AI summary of a transcript using the configured cloud provider (e.g. Groq). Requires
/// an API key (same key as text enhancement).
///
/// Long transcripts are summarized map-reduce: split into chunks, summarize each, then merge the
/// partial notes — so an hour-long meeting doesn't overflow the model's context.
enum TranscriptSummarizer {
    /// Rough per-request character budget (provider-agnostic; ~2–3k tokens of input + prompt).
    private static let chunkBudget = 9000

    private static let finalPrompt = """
    You are a meeting assistant. Summarize the meeting content below. Reply in its own language. Use \
    this structure, omitting any section that has nothing:

    **TL;DR** — 1–2 sentences.
    **Key points** — short bullets.
    **Decisions** — what was decided.
    **Action items** — "- [owner] task" bullets.

    Be concise and factual; do not invent details.
    """

    private static let chunkPrompt = """
    This is ONE segment of a longer meeting transcript. Extract its key points, decisions, and action \
    items as concise bullets. No preamble. Reply in the transcript's language.
    """

    static func summarize(_ transcript: String) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummarizerError.emptyTranscript }

        let defaults = UserDefaults.standard
        let provider = EnhancementProvider(rawValue: defaults.string(forKey: "enhancementProvider") ?? "openai") ?? .openAI
        guard let key = (try? KeychainSecretStore().get(provider.secretKey)) ?? nil, !key.isEmpty else {
            throw SummarizerError.noKey
        }
        let enhancer = URLSessionLLMEnhancer(apiKey: key)
        let llmProvider = provider.llmProvider(model: defaults.string(forKey: "enhancementModel") ?? "")
        func call(_ input: String, _ system: String) async throws -> String {
            try await enhancer.enhance(input, prompt: system, provider: llmProvider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Short transcript → one shot.
        if text.count <= chunkBudget { return try await call(text, finalPrompt) }

        // Map: summarize each chunk into partial notes.
        var notes: [String] = []
        for chunk in chunks(of: text) { notes.append(try await call(chunk, chunkPrompt)) }

        // Reduce: if the merged notes are still too big, collapse them a level first.
        var merged = notes.joined(separator: "\n\n")
        if merged.count > chunkBudget {
            var second: [String] = []
            for chunk in chunks(of: merged) { second.append(try await call(chunk, chunkPrompt)) }
            merged = second.joined(separator: "\n\n")
        }
        return try await call(merged, finalPrompt)
    }

    /// Splits `text` into <=`chunkBudget` pieces on line boundaries (transcripts are one turn/line).
    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > chunkBudget, !current.isEmpty {
                result.append(current); current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Reusable summary block for a transcript detail (conferences + files): a Summarize button, progress,
/// the rendered summary, and regenerate/error states.
struct TranscriptSummaryView: View {
    let transcript: String
    @Binding var summary: String
    let onSave: () -> Void

    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.geist(size: 13)).foregroundStyle(Theme.accent)
                Text("Summary").font(.geist(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Button(summary.isEmpty ? "Summarize" : "Regenerate") { Task { await run() } }
                        .font(.geist(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                        .buttonStyle(.plain).pointingCursor()
                        .disabled(transcript.isEmpty)
                }
            }

            if let error {
                Text(error).font(.geist(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !summary.isEmpty {
                Text(LocalizedStringKey(summary))   // renders the model's **markdown** emphasis
                    .font(.geist(size: 13)).foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !running {
                Text("Generate a TL;DR, key points, decisions and action items from the transcript.")
                    .font(.geist(size: 12)).foregroundStyle(Theme.mutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).stroke(Theme.hairline))
    }

    private func run() async {
        running = true; error = nil
        defer { running = false }
        do {
            summary = try await TranscriptSummarizer.summarize(transcript)
            onSave()
        } catch SummarizerError.noKey {
            error = "Connect a cloud key in Settings → AI to generate summaries."
        } catch let failure {
            error = "Couldn't generate a summary — \(failure.localizedDescription)"
        }
    }
}
