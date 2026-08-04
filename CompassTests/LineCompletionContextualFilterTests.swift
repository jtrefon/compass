import XCTest
@testable import Compass

@MainActor
final class LineCompletionContextualFilterTests: XCTestCase {
    private func snapshot(
        buffer: String = "foo",
        cursor: Int = 3,
        selectionLength: Int = 0,
        isComposingText: Bool = false
    ) -> InlineCompletionEditorSnapshot {
        InlineCompletionEditorSnapshot(
            paneID: .primary,
            filePath: nil,
            language: "swift",
            buffer: buffer,
            cursorPosition: cursor,
            selectionLength: selectionLength,
            isComposingText: isComposingText,
            triggerReason: .automatic
        )
    }

    func testFilter_allowsTriggerChar() {
        let filter = LineCompletionContextualFilter()
        let snap = snapshot()
        XCTAssertTrue(filter.shouldRequest(for: snap, gapMs: 0, typedChar: ".", recentRejectionCount: 0))
        XCTAssertTrue(filter.shouldRequest(for: snap, gapMs: 0, typedChar: "(", recentRejectionCount: 0))
        XCTAssertTrue(filter.shouldRequest(for: snap, gapMs: 0, typedChar: "{", recentRejectionCount: 0))
    }

    func testFilter_rejectsClosingChar() {
        let filter = LineCompletionContextualFilter()
        let snap = snapshot()
        XCTAssertFalse(filter.shouldRequest(for: snap, gapMs: 0, typedChar: ")", recentRejectionCount: 0))
        XCTAssertFalse(filter.shouldRequest(for: snap, gapMs: 0, typedChar: "]", recentRejectionCount: 0))
        XCTAssertFalse(filter.shouldRequest(for: snap, gapMs: 0, typedChar: "\"", recentRejectionCount: 0))
    }

    func testFilter_suppressesAfterRecentRejections() {
        let filter = LineCompletionContextualFilter()
        let snap = snapshot()
        XCTAssertFalse(filter.shouldRequest(for: snap, gapMs: 100, typedChar: nil, recentRejectionCount: 3))
    }

    func testFilter_suppressesDuringFastTyping() {
        let filter = LineCompletionContextualFilter()
        let snap = snapshot()
        XCTAssertFalse(filter.shouldRequest(for: snap, gapMs: 40, typedChar: nil, recentRejectionCount: 0))
    }

    func testFilter_suppressesDuringComposition() {
        let filter = LineCompletionContextualFilter()
        let snap = snapshot(isComposingText: true)
        XCTAssertFalse(filter.shouldRequest(for: snap, gapMs: 200, typedChar: "a", recentRejectionCount: 0))
    }
}
