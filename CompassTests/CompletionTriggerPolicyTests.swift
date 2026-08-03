import XCTest
@testable import Compass

@MainActor
final class CompletionTriggerPolicyTests: XCTestCase {
    func testAutomaticRequestSuppressedOnSelection() {
        let policy = CompletionTriggerPolicy()
        let disabledSettings = InlineCompletionSettings.default.with(isEnabled: false)
        let enabledSettings = InlineCompletionSettings.default.with(isEnabled: true)

        let noSelection = InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: nil, language: "swift",
            buffer: "foo", cursorPosition: 3, selectionLength: 0,
            isComposingText: false, triggerReason: .automatic
        )
        let selectedText = InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: nil, language: "swift",
            buffer: "foo", cursorPosition: 1, selectionLength: 2,
            isComposingText: false, triggerReason: .automatic
        )

        XCTAssertFalse(policy.shouldRequest(for: noSelection, settings: disabledSettings))
        XCTAssertFalse(policy.shouldRequest(for: selectedText, settings: enabledSettings))
        XCTAssertTrue(policy.shouldRequest(for: noSelection, settings: enabledSettings))
    }

    func testManualTriggerBypassesUnsupportedLanguageGuard() {
        let policy = CompletionTriggerPolicy()
        let snapshot = InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: nil, language: "unknown-language",
            buffer: "foo", cursorPosition: 3, selectionLength: 0,
            isComposingText: false, triggerReason: .manual
        )

        XCTAssertTrue(policy.shouldRequest(for: snapshot, settings: .default))
    }

    func testAutomaticRequestIsSuppressedDuringTextComposition() {
        let policy = CompletionTriggerPolicy()
        let snapshot = InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: "/tmp/Test.swift", language: "swift",
            buffer: "let value =", cursorPosition: 11, selectionLength: 0,
            isComposingText: true, triggerReason: .automatic
        )

        XCTAssertFalse(policy.shouldRequest(for: snapshot, settings: .default))
    }
}

private extension InlineCompletionSettings {
    func with(isEnabled: Bool) -> InlineCompletionSettings {
        InlineCompletionSettings(
            isEnabled: isEnabled,
            debounceMilliseconds: debounceMilliseconds,
            aggressiveness: aggressiveness,
            maxSuggestionLength: maxSuggestionLength,
            multilineEnabled: multilineEnabled,
            retrievalEnabled: retrievalEnabled,
            routingMode: routingMode,
            debugOverlayEnabled: debugOverlayEnabled
        )
    }
}
