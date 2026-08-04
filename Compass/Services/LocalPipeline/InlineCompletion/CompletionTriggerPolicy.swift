import Foundation

struct CompletionTriggerPolicyDecision: Equatable {
    let shouldRequest: Bool
}

@MainActor
struct CompletionTriggerPolicy {
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

    func shouldRequest(
        for snapshot: InlineCompletionEditorSnapshot,
        settings: InlineCompletionSettings
    ) -> Bool {
        guard settings.isEnabled else { return false }
        guard snapshot.triggerReason == .manual || !snapshot.hasSelection else { return false }
        guard snapshot.triggerReason == .manual || !snapshot.isComposingText else { return false }
        guard !snapshot.buffer.isEmpty else { return false }
        let normalizedLanguage = snapshot.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard snapshot.triggerReason == .manual || supportedLanguages.contains(normalizedLanguage) else { return false }
        return true
    }
}
