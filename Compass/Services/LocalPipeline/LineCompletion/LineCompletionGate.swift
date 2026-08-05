import Foundation

/// Single keystroke gate for inline completion (merged from
/// CompletionTriggerPolicy + LineCompletionContextualFilter — one job, one
/// place). Decides whether the current typing event warrants a model request.
@MainActor
struct LineCompletionGate {
    private let supportedLanguages: Set<String> = [
        "swift", "objective-c", "objective-cpp", "c", "cpp", "c#", "csharp",
        "typescript", "tsx", "javascript", "jsx",
        "python", "rust", "go", "golang",
        "java", "kotlin", "ruby", "scala",
        "php", "perl", "dart", "lua", "r",
        "haskell", "julia", "zig",
        "json", "html", "css", "markdown", "yaml", "shell", "bash",
        "sql", "graphql", "protobuf", "toml"
    ]

    /// Characters that strongly signal a worthwhile completion trigger.
    private let triggerSet: Set<Character> = [".", "(", "{", "[", "<", " ", "\n", "\t"]
    /// Characters that indicate the user is finishing a token — no completion wanted.
    private let rejectSet: Set<Character> = [")", "]", "\"", "'", "`", "/"]
    /// Below this inter-keystroke gap we assume the user is still actively typing.
    private let fastTypingGapMs: Double = 100
    /// Once this many recent completions were rejected, stop offering them.
    private let maxRecentRejections: Int = 3

    func shouldRequest(
        for snapshot: InlineCompletionEditorSnapshot,
        settings: InlineCompletionSettings,
        gapMs: Double,
        typedChar: Character?,
        recentRejectionCount: Int
    ) -> Bool {
        guard settings.isEnabled else { return false }
        guard snapshot.triggerReason == .manual || !snapshot.hasSelection else { return false }
        guard snapshot.triggerReason == .manual || !snapshot.isComposingText else { return false }
        guard !snapshot.buffer.isEmpty else { return false }
        let normalizedLanguage = snapshot.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard snapshot.triggerReason == .manual || supportedLanguages.contains(normalizedLanguage) else { return false }
        if let char = typedChar {
            if triggerSet.contains(char) { return true }
            if rejectSet.contains(char) { return false }
        }
        if recentRejectionCount >= maxRecentRejections { return false }
        if gapMs < fastTypingGapMs { return false }
        return true
    }
}
