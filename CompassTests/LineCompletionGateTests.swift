import XCTest
@testable import Compass

@MainActor
final class LineCompletionGateTests: XCTestCase {
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

    func testAutomaticRequestSuppressedOnSelection() {
        let gate = LineCompletionGate()
        let noSelection = makeSnapshot()
        let selectedText = makeSnapshot(cursor: 1, selectionLength: 2)

        XCTAssertFalse(gate.shouldRequest(for: selectedText, gapMs: 200, typedChar: nil, recentRejectionCount: 0))
        XCTAssertTrue(gate.shouldRequest(for: noSelection, gapMs: 200, typedChar: nil, recentRejectionCount: 0))
    }

    func testManualTriggerBypassesUnsupportedLanguageGuard() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot(language: "unknown-language", triggerReason: .manual)

        XCTAssertTrue(gate.shouldRequest(for: snapshot, gapMs: 200, typedChar: nil, recentRejectionCount: 0))
    }

    func testAutomaticRequestIsSuppressedDuringTextComposition() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot(isComposingText: true)

        XCTAssertFalse(gate.shouldRequest(for: snapshot, gapMs: 200, typedChar: nil, recentRejectionCount: 0))
    }

    func testFastTypingSuppressesRequest() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertFalse(gate.shouldRequest(for: snapshot, gapMs: 50, typedChar: "a", recentRejectionCount: 0))
    }

    func testTriggerCharacterOverridesFastTyping() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertTrue(gate.shouldRequest(for: snapshot, gapMs: 50, typedChar: ".", recentRejectionCount: 0))
    }

    func testRejectCharacterSuppressesRequest() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertFalse(gate.shouldRequest(for: snapshot, gapMs: 200, typedChar: ")", recentRejectionCount: 0))
    }

    func testRepeatedRejectionsSuppressRequest() {
        let gate = LineCompletionGate()
        let snapshot = makeSnapshot()

        XCTAssertFalse(gate.shouldRequest(for: snapshot, gapMs: 200, typedChar: "a", recentRejectionCount: 3))
    }
}
