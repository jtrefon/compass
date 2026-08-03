import Foundation

enum InlineCompletionSource: String, Codable, CaseIterable, Sendable {
    case local
    case remote
}

enum CompletionTriggerReason: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual
}

enum InlineCompletionRoutingMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case remoteOnly
    case hybridPreferLocal
    case hybridPreferRemote
}

struct InlineCompletionRequest: Sendable {
    let requestId: UUID
    let filePath: String?
    let language: String
    let prefix: String
    let suffix: String
    let cursorPosition: Int
    let scopeSummary: String?
    let symbols: [String]
    let retrievalContext: [String]
    let triggerReason: CompletionTriggerReason
    let maxSuggestionLength: Int
    let maxTokens: Int
    let allowMultiline: Bool
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
    let multilineEnabled: Bool
    let retrievalEnabled: Bool
    let routingMode: InlineCompletionRoutingMode
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
        multilineEnabled: true,
        retrievalEnabled: false,
        routingMode: .hybridPreferLocal,
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
    let scopeSummary: String?
    let symbols: [String]
}
