import XCTest
@testable import Compass

/// EditorSignalBridge: keystroke identity (dedup + coalescing) and gap
/// preservation. The coordinator can emit multiple mutation events per
/// keystroke; without identity handling the second event collapses the gap
/// to 0 and nil char → the gate rejects → suggestions alternate on/off
/// (measured in fim-trace.ndjson).
@MainActor
final class EditorSignalBridgeTests: XCTestCase {
    private func makeEngine(_ inference: TestLineInferenceService) -> LineCompletionEngine {
        LineCompletionEngine(
            inferenceService: inference,
            settingsStore: LineTestSettingsStore()
        )
    }

    private func snapshot(buffer: String, cursor: Int) -> InlineCompletionEditorSnapshot {
        InlineCompletionEditorSnapshot(
            paneID: .primary, filePath: "/tmp/test.php", language: "php",
            buffer: buffer, cursorPosition: cursor, selectionLength: 0,
            isComposingText: false, triggerReason: .automatic
        )
    }

    func testDuplicateEventForSameKeystrokeIsDropped() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("x"), .immediate("y")]
        let engine = makeEngine(inference)
        let bridge = EditorSignalBridge(paneID: .primary, lineEngine: engine)

        // First call has gap 0 → gate rejects; the second (real gap) passes.
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "a", cursor: 1))
        try await Task.sleep(nanoseconds: 200_000_000)
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "ab", cursor: 2))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inference.capturedRequests.count, 1, "first real-gap keystroke must infer")

        // The exact same (buffer, cursor) again — a duplicate event for the
        // same keystroke must be dropped entirely.
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "ab", cursor: 2))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inference.capturedRequests.count, 1, "duplicate event must not trigger a second request")

        // A genuinely new keystroke infers again.
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "abc", cursor: 3))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inference.capturedRequests.count, 2)
    }

    func testCoalescedPairFiresOnceWithLatestSnapshotAndOriginalGap() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("x")]
        let engine = makeEngine(inference)
        let bridge = EditorSignalBridge(paneID: .primary, lineEngine: engine)

        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "a", cursor: 1))
        try await Task.sleep(nanoseconds: 200_000_000)

        // Same keystroke, two events (pre/post change) scheduled back-to-back
        // in the same runloop turn: the pair must produce ONE request, with
        // the post snapshot, keeping the original ~200ms gap (gate passes).
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "ab", cursor: 2))
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "abc", cursor: 3))
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(inference.capturedRequests.count, 1, "one keystroke pair must produce one request")
        XCTAssertEqual(inference.capturedRequests.first?.prefix, "abc",
                       "the latest (post-change) snapshot must reach the engine")
    }

    func testBackspacePreservesRealGap() async throws {
        let inference = TestLineInferenceService()
        inference.responses = [.immediate("x")]
        let engine = makeEngine(inference)
        let bridge = EditorSignalBridge(paneID: .primary, lineEngine: engine)

        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "ab", cursor: 2))
        try await Task.sleep(nanoseconds: 200_000_000)

        // Backspace: char detection fails (length decreases), but the real
        // ~200ms gap must reach the gate so the request is not rejected.
        bridge.scheduleAutomaticRequest(snapshot: snapshot(buffer: "a", cursor: 1))
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(inference.capturedRequests.count, 1, "backspace at a real gap must infer")
    }
}
