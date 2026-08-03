import Foundation
import Combine

@MainActor
final class InlineCompletionDebugStore: ObservableObject {
    struct PaneState: Equatable {
        let source: InlineCompletionSource
        let confidenceScore: Double
        let latencyMs: Double
        let suggestionPreview: String
        let isMultiline: Bool
    }

    static let shared = InlineCompletionDebugStore()

    @Published private(set) var paneStates: [FileEditorStateManager.PaneID: PaneState] = [:]

    func update(
        paneID: FileEditorStateManager.PaneID,
        presentation: InlineSuggestionPresentation?
    ) {
        guard let presentation else {
            paneStates.removeValue(forKey: paneID)
            return
        }

        let preview = presentation.suggestionText
            .replacingOccurrences(of: "\n", with: "\\n")
            .prefix(80)

        paneStates[paneID] = PaneState(
            source: presentation.source,
            confidenceScore: presentation.confidenceScore,
            latencyMs: presentation.latencyMs,
            suggestionPreview: String(preview),
            isMultiline: presentation.suggestionText.contains("\n")
        )
    }

    func state(for paneID: FileEditorStateManager.PaneID) -> PaneState? {
        paneStates[paneID]
    }
}
