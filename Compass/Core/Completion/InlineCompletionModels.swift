import Foundation

enum InlineCompletionSource: String, Codable, CaseIterable, Sendable {
    case local
}

enum CompletionTriggerReason: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual
}

struct InlineCompletionRequest: Sendable {
    let requestId: UUID
    let language: String
    let prefix: String
    let suffix: String
    let triggerReason: CompletionTriggerReason
    let maxSuggestionLength: Int
    let maxTokens: Int
    /// Variant decoding (FIM_VariantPools_Arch.md §4): hard-excluded first
    /// tokens of earlier variants + the variant's sampling temperature.
    /// Empty on the standard path.
    let bannedTokenIDs: [Int]
    let variantTemperature: Float?
}

struct InlineCompletionResult: Sendable {
    let requestId: UUID
    let suggestionText: String
    let confidenceScore: Double
    let source: InlineCompletionSource
    let latencyMs: Double
}

struct InlineSuggestionPresentation: Equatable, Sendable {
    let requestId: UUID
    let suggestionText: String
    let source: InlineCompletionSource
    let confidenceScore: Double
    let latencyMs: Double
}

struct InlineCompletionSettings: Equatable, Sendable {
    let isEnabled: Bool
    let debounceMilliseconds: Int
    let aggressiveness: Double
    let maxSuggestionLength: Int
    let debugOverlayEnabled: Bool

    static let `default` = InlineCompletionSettings(
        isEnabled: {
#if DEBUG
            true
#else
            AppRuntimeEnvironment.launchContext.isTesting
#endif
        }(),
        debounceMilliseconds: 0,
        aggressiveness: 0.6,
        maxSuggestionLength: 120,
        debugOverlayEnabled: {
#if DEBUG
            true
#else
            false
#endif
        }()
    )
}

struct InlineCompletionEditorSnapshot: Sendable {
    let paneID: FileEditorStateManager.PaneID
    let filePath: String?
    let language: String
    let buffer: String
    let cursorPosition: Int
    let selectionLength: Int
    let isComposingText: Bool
    let triggerReason: CompletionTriggerReason

    var hasSelection: Bool {
        selectionLength > 0
    }
}

struct CompletionContextPayload: Sendable {
    let prefix: String
    let suffix: String
}
