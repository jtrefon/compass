import Foundation

/// Bridges editor mutations to the completion engine with debounce and
/// keystroke identity.
///
/// The coordinator can emit more than one mutation event per keystroke
/// (shouldChangeTextIn + textDidChange, auto-pairing, etc.). Without dedup,
/// the second event sees the same buffer (typed-char detection fails → nil),
/// recomputes the gap against the just-updated timestamp (→ 0), and its
/// request replaces the first — the gate then rejects on `gapMs < 100` and
/// the suggestion is cleared on every second keystroke (measured in
/// fim-trace.ndjson). This class treats events as one keystroke by
/// (buffer, cursor) identity and by short-window coalescing.
@MainActor
final class EditorSignalBridge {
    private let paneID: FileEditorStateManager.PaneID
    private let lineEngine: LineCompletionEngine
    private var debounceTask: Task<Void, Never>?
    private var lastTypedAt: Date?
    private var lastBuffer: String?
    private var lastSignature: (buffer: String, cursor: Int)?
    /// Pending-request state: the pair's second event refreshes these while
    /// keeping the first event's gap (the real cadence).
    private var isTaskPending = false
    private var pendingSnapshot: InlineCompletionEditorSnapshot?
    private var pendingGapMs: Double?
    private var pendingTypedChar: Character?

    init(
        paneID: FileEditorStateManager.PaneID,
        lineEngine: LineCompletionEngine
    ) {
        self.paneID = paneID
        self.lineEngine = lineEngine
    }

    func scheduleAutomaticRequest(snapshot: InlineCompletionEditorSnapshot) {
        // Same-keystroke identity: duplicate events for one keystroke are
        // dropped entirely (no timestamp update, no new task).
        let signature = (snapshot.buffer, snapshot.cursorPosition)
        if let last = lastSignature, last == signature {
            FIMTraceLogger.shared.log("bridge.event", ["decision": "dedup-skip"])
            return
        }
        lastSignature = signature

        let now = Date()
        let gapMs: Double = lastTypedAt.map { now.timeIntervalSince($0) * 1_000 } ?? 0

        if isTaskPending {
            // Same keystroke pair (e.g. shouldChangeTextIn + textDidChange):
            // refresh the snapshot and typed char, keep the pair's ORIGINAL
            // gap so the gate sees the real cadence — the pending task fires
            // exactly once with the latest state.
            pendingSnapshot = snapshot
            pendingTypedChar = detectTypedCharacter(
                previous: lastBuffer, current: snapshot.buffer, cursor: snapshot.cursorPosition
            )
            lastBuffer = snapshot.buffer
            FIMTraceLogger.shared.log("bridge.event", [
                "decision": "coalesce",
                "gapMs": String(format: "%.0f", gapMs)
            ])
            return
        }

        pendingSnapshot = snapshot
        pendingGapMs = gapMs
        pendingTypedChar = detectTypedCharacter(
            previous: lastBuffer, current: snapshot.buffer, cursor: snapshot.cursorPosition
        )
        lastBuffer = snapshot.buffer
        lastTypedAt = now
        isTaskPending = true

        FIMTraceLogger.shared.log("bridge.event", [
            "decision": "request",
            "gapMs": String(format: "%.0f", gapMs),
            "char": pendingTypedChar.map { String($0) } ?? "nil"
        ])

        debounceTask = Task { [weak self] in
            guard let self else { return }
            let snap = self.pendingSnapshot
            let gap = self.pendingGapMs ?? 0
            let char = self.pendingTypedChar
            self.isTaskPending = false
            guard let snap else { return }
            self.lineEngine.requestCompletion(for: snap, gapMs: gap, typedChar: char)
        }
    }

    func invalidate() {
        debounceTask?.cancel()
        lastBuffer = nil
        lastTypedAt = nil
        lastSignature = nil
        isTaskPending = false
        pendingSnapshot = nil
        pendingGapMs = nil
        pendingTypedChar = nil
        lineEngine.invalidate(paneID)
    }

    private func detectTypedCharacter(previous: String?, current: String, cursor: Int) -> Character? {
        guard let previous else { return nil }
        guard current.count == previous.count + 1, cursor > 0, cursor <= current.count else { return nil }
        let nsCurrent = current as NSString
        let char = nsCurrent.substring(with: NSRange(location: cursor - 1, length: 1))
        return char.first
    }
}
