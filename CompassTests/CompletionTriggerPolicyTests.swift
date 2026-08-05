import XCTest
@testable import Compass

@MainActor
final class CompletionTriggerPolicyTests: XCTestCase {
    private func makeSnapshot(
        buffer: String = "foo",
        cursor: Int = 3,
        selectionLength: Int = 0,
        language: String = "swift",
        isComposingText: Bool = false,
        triggerReason: CompletionTriggerReason = .automatic
    ) -> InlineCompletionEditorSnapshot {
        InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: nil, language: language,
            buffer: buffer, cursorPosition: cursor, selectionLength: selectionLength,
            isComposingText: isComposingText, triggerReason: triggerReason
        )
    }

    private func makeSettings(isEnabled: Bool = true) -> InlineCompletionSettings {
        InlineCompletionSettings.default.with(isEnabled: isEnabled)
    }

    func testAutomaticRequestSuppressedOnSelection() {
        let gate = LineCompletionGate()
        let noSelection = makeSnapshot()
        let selectedText = makeSnapshot(cursor: 1, selectionLength: 2)

        XCTAssertFalse(gate.shouldRequest(for: noSelection, settings: makeSettings(isEnabled: false), gapMs: 200, typedChar: nil, recentRejectionCount: 0))
        XCTAssertFalse(gate.shouldRequest(for: selectedText, settings: makeSettings(), gapMs: 200, typedChar: nil, recentRejectionCount: 0))
        XCTAssertTrue(gate.shouldRequest(for: noSelection, settings: makeSettings(), gapMs: 200, typedChar: nil, recentRejectionCount: 0))
    }

    func testManualTriggerBypassesUnsupportedLanguageGuard() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot(language: "unknown-language", triggerReason: .manual)

        XCTAssertTrue(gate.shouldRequest(for: snapshot, settings: .default, gapMs: 200, typedChar: nil, recentRejectionCount: 0))
    }

    func testAutomaticRequestIsSuppressedDuringTextComposition() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot(isComposingText: true)

        XCTAssertFalse(gate.shouldRequest(for: snapshot, settings: .default, gapMs: 200, typedChar: nil, recentRejectionCount: 0))
    }

    func testFastTypingSuppressesRequest() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertFalse(gate.shouldRequest(for: snapshot, settings: .default, gapMs: 50, typedChar: "a", recentRejectionCount: 0))
    }

    func testTriggerCharacterOverridesFastTyping() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertTrue(gate.shouldRequest(for: snapshot, settings: .default, gapMs: 50, typedChar: ".", recentRejectionCount: 0))
    }

    func testRejectCharacterSuppressesRequest() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertFalse(gate.shouldRequest(for: snapshot, settings: .default, gapMs: 200, typedChar: ")", recentRejectionCount: 0))
    }

    func testRepeatedRejectionsSuppressRequest() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertFalse(gate.shouldRequest(for: snapshot, settings: .default, gapMs: 200, typedChar: "a", recentRejectionCount: 3))
    }
}

private extension InlineCompletionSettings {
    func with(isEnabled: Bool) -> InlineCompletionSettings {
        InlineCompletionSettings(
            isEnabled: isEnabled,
            debounceMilliseconds: debounceMilliseconds,
            aggressiveness: aggressiveness,
            maxSuggestionLength: maxSuggestionLength,
            debugOverlayEnabled: debugOverlayEnabled
        )
    }
}
