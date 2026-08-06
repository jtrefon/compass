import XCTest
@testable import Compass

@MainActor
final class LineCompletionContextAssemblerTests: XCTestCase {
    private func makeSnapshot(buffer: String, cursor: Int) -> InlineCompletionEditorSnapshot {
        InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: "/tmp/test.php", language: "php",
            buffer: buffer, cursorPosition: cursor, selectionLength: 0,
            isComposingText: false, triggerReason: .automatic
        )
    }

    /// The window must be line-anchored: typing one char must GROW the prefix
    /// at the end (prefix2 == prefix1 + char), never shift it — a sliding
    /// window breaks KV-cache token alignment (measured common=1 in the trace).
    func testWindowStartIsStableAcrossKeystrokes() {
        let assembler = LineCompletionContextAssembler()
        // 1500-char filler line, then the working line — rawStart lands inside
        // the filler; the anchor pins to the filler line's start.
        let filler = String(repeating: "x", count: 1500)
        let buffer = "lineA\n" + filler + "\n    $pl"
        let cursor1 = buffer.count
        let cursor2 = cursor1 + 1
        let buffer2 = buffer + "u"

        let context1 = assembler.buildContext(from: makeSnapshot(buffer: buffer, cursor: cursor1))
        let context2 = assembler.buildContext(from: makeSnapshot(buffer: buffer2, cursor: cursor2))

        XCTAssertFalse(context1.prefix.contains("lineA\n"),
                       "window must start AFTER the line boundary, not include a partial line")
        XCTAssertEqual(context2.prefix, context1.prefix + "u",
                       "typing one char must append, not shift the window")
    }

    func testShortBufferUsesWholePrefixFromZero() {
        let assembler = LineCompletionContextAssembler()
        let context = assembler.buildContext(from: makeSnapshot(buffer: "let x = 1", cursor: 9))
        XCTAssertEqual(context.prefix, "let x = 1")
    }

    func testCursorDeepAnchorsToLineBoundary() {
        let assembler = LineCompletionContextAssembler()
        // rawStart (cursor-1500) lands after the first line's newline — the
        // anchor must start right after it, dropping the partial first line.
        let buffer = "a\n" + String(repeating: "y", count: 1500) + "\nmid"
        let context = assembler.buildContext(from: makeSnapshot(buffer: buffer, cursor: buffer.count))
        XCTAssertFalse(context.prefix.hasPrefix("a\n"), "partial first line must be dropped")
        XCTAssertEqual(context.prefix, String(buffer.dropFirst(2)), "prefix starts at the line boundary")
    }
}
