import Foundation

/// Deterministic classification of user input into one of three execution paths.
/// No LLM call — runs in <1ms. Placed at ConversationSendCoordinator before any
/// graph node is invoked. Each path gets a different graph topology.
enum RequestComplexity: String, Sendable {
    /// Greeting, factual question, single-turn — no task to perform.
    case fast
    /// Read-only analysis, audit, critique, explain.
    case review
    /// Create, modify, refactor, implement — requires full build pipeline.
    case build
}

enum RequestClassifier {

    // MARK: - Public

    static func classify(_ userInput: String) -> RequestComplexity {
        let normalized = userInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .fast }

        let firstSentence = extractFirstSentence(normalized)

        let hasReview = matchesAny(firstSentence, patterns: reviewPathSignals)
        let hasMutation = matchesAny(firstSentence, patterns: mutationSignals)

        // Mutation signals take precedence over fast signals: "how do I fix
        // the build error in main.swift" is work, not a greeting.
        if hasMutation {
            return .build
        }
        if hasReview && !hasMutation {
            return .review
        }
        if matchesAny(firstSentence, patterns: fastPathSignals) {
            return .fast
        }
        // Unmatched statement-form input defaults to build — the read-only
        // review default left the agent without bash for "npm test fails".
        return .build
    }

    // MARK: - Private

    private static func extractFirstSentence(_ text: String) -> String {
        if let range = text.range(of: ".") {
            return String(text[..<range.lowerBound])
        }
        if let range = text.range(of: "?") {
            return String(text[..<range.lowerBound]) + "?"
        }
        if let range = text.range(of: "!") {
            return String(text[..<range.lowerBound]) + "!"
        }
        return String(text.prefix(200))
    }

    private static func matchesAny(_ input: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            // Use word-boundary regex for single-word patterns,
            // substring match for multi-word phrases.
            if trimmed.contains(" ") {
                return input.localizedCaseInsensitiveContains(trimmed)
            }
            return input.range(of: "\\b\(escaped)\\b", options: [.caseInsensitive, .regularExpression]) != nil
        }
    }

    // MARK: - Signal lists

    private static let fastPathSignals: [String] = [
        "hi", "hello", "hey", "thanks", "thank you", "ok", "okay",
        "what is", "how do i", "how does", "does this", "do we have",
        "do you have", "is there", "are there", "can you tell",
        "which port", "where is", "what port", "show me the",
        "what version", "how many", "who is",
    ]

    private static let reviewPathSignals: [String] = [
        "review", "audit", "critique", "assess", "evaluate",
        "explain", "describe", "summarize", "summarise", "analyze",
        "analyse", "check if", "check whether", "look at",
        "look over", "walk through", "walkthrough", "inspect",
    ]

    private static let mutationSignals: [String] = [
        "create", "write", "build", "add", "implement", "refactor",
        "migrate", "fix", "change", "modify", "delete", "remove",
        "rename", "generate", "install", "set up", "configure",
        "deploy", "make a", "write a", "add a",
    ]
}