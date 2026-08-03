import Foundation

@MainActor
struct LineCompletionContextualFilter {
    /// Characters that strongly signal a worthwhile completion trigger.
    private let triggerSet: Set<Character> = [".", "(", "{", "[", "<", " ", "\n", "\t"]
    /// Characters that indicate the user is finishing a token — no completion wanted.
    private let rejectSet: Set<Character> = [")", "]", "\"", "'", "`", "/"]
    /// Below this inter-keystroke gap we assume the user is still actively typing.
    private let fastTypingGapMs: Double = 100
    /// Once this many recent completions were rejected, stop offering them.
    private let maxRecentRejections: Int = 3

    func shouldRequest(for snapshot: InlineCompletionEditorSnapshot, gapMs: Double, typedChar: Character?, recentRejectionCount: Int) -> Bool {
        if snapshot.isComposingText { return false }
        if snapshot.hasSelection { return false }
        if let char = typedChar {
            if triggerSet.contains(char) { return true }
            if rejectSet.contains(char) { return false }
        }
        if recentRejectionCount >= maxRecentRejections { return false }
        if gapMs < fastTypingGapMs { return false }
        return true
    }
}
