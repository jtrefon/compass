import Foundation

enum LineCompletionRankerEvaluation {
    case accepted(InlineSuggestionPresentation)
    case rejected(String)
}

@MainActor
struct LineCompletionRanker {
    func evaluate(_ result: InlineCompletionResult, for request: InlineCompletionRequest, aggressiveness: Double) -> LineCompletionRankerEvaluation {
        guard let sanitized = sanitizedSuggestion(from: result.suggestionText) else {
            return .rejected("sanitized_nil")
        }
        guard !sanitized.isEmpty else { return .rejected("empty") }
        guard !request.suffix.hasPrefix(sanitized) else { return .rejected("suffix_prefix_duplicate") }
        guard !duplicatesLeadingSuffix(sanitized, suffix: request.suffix) else { return .rejected("leading_suffix_duplicate") }
        guard !hasSelfRepetition(sanitized) else { return .rejected("self_repetition") }
        guard !matchesLineContent(sanitized, prefix: request.prefix) else { return .rejected("already_typed") }
        guard sanitized.count <= request.maxSuggestionLength else { return .rejected("too_long") }

        let score = min(0.98, max(aggressiveness, result.confidenceScore))
        return .accepted(InlineSuggestionPresentation(
            requestId: result.requestId,
            suggestionText: sanitized,
            source: result.source,
            confidenceScore: score,
            latencyMs: result.latencyMs
        ))
    }

    func rank(_ result: InlineCompletionResult, for request: InlineCompletionRequest, aggressiveness: Double) -> InlineSuggestionPresentation? {
        switch evaluate(result, for: request, aggressiveness: aggressiveness) {
        case .accepted(let p): return p
        case .rejected: return nil
        }
    }

    private func sanitizedSuggestion(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("\n") { return nil }
        return text
    }

    private func duplicatesLeadingSuffix(_ suggestion: String, suffix: String) -> Bool {
        let candidate = suggestion.trimmingCharacters(in: .whitespaces)
        let remaining = suffix.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, !remaining.isEmpty else { return false }
        guard candidate.count >= 3 else { return false }
        guard remaining.hasPrefix(candidate) else { return false }
        let nextIndex = remaining.index(remaining.startIndex, offsetBy: candidate.count)
        if nextIndex < remaining.endIndex {
            let nextChar = remaining[nextIndex]
            return !nextChar.isLetter && nextChar != "_"
        }
        return true
    }

    private func hasSelfRepetition(_ suggestion: String) -> Bool {
        let words = suggestion.split(separator: " ").filter { !$0.isEmpty }
        guard words.count >= 4 else { return false }
        for n in 2...3 {
            if words.count >= n * 2 {
                let first = words[0..<n]
                let second = words[n..<(n*2)]
                if first == second { return true }
            }
        }
        return false
    }

    private func matchesLineContent(_ suggestion: String, prefix: String) -> Bool {
        guard let lastLine = prefix.components(separatedBy: .newlines).last else { return false }
        let trimmedLine = lastLine.trimmingCharacters(in: .whitespaces)
        return trimmedLine.hasSuffix(suggestion)
    }
}
