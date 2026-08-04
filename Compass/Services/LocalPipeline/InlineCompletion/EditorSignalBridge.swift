import Foundation

@MainActor
final class EditorSignalBridge {
    private let paneID: FileEditorStateManager.PaneID
    private let lineEngine: LineCompletionEngine
    private let settingsStore: InlineCompletionSettingsStore
    private var debounceTask: Task<Void, Never>?
    private var lastTypedAt: Date?
    private var lastBuffer: String?

    private static let structuralCharacters: Set<Character> = [
        ".", "(", ")", "{", "}", "[", "]", ":", "=", ",", ">", "\n", ";", " "
    ]

    init(
        paneID: FileEditorStateManager.PaneID,
        lineEngine: LineCompletionEngine,
        settingsStore: InlineCompletionSettingsStore = InlineCompletionSettingsStore()
    ) {
        self.paneID = paneID
        self.lineEngine = lineEngine
        self.settingsStore = settingsStore
    }

    func scheduleAutomaticRequest(snapshot: InlineCompletionEditorSnapshot) {
        debounceTask?.cancel()

        let now = Date()
        let gapMs: Double = if let last = lastTypedAt {
            now.timeIntervalSince(last) * 1_000
        } else {
            0
        }
        lastTypedAt = now

        let typedChar = detectTypedCharacter(previous: lastBuffer, current: snapshot.buffer, cursor: snapshot.cursorPosition)
        lastBuffer = snapshot.buffer

        let settings = settingsStore.load()
        let debounceMs = computeDebounceMs(settings: settings, gapMs: gapMs, typedChar: typedChar)

        debounceTask = Task { [weak self] in
            guard let self else { return }
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            self.lineEngine.requestCompletion(for: snapshot, gapMs: gapMs, typedChar: typedChar)
        }
    }

    func invalidate(textView: CodeEditorTextView? = nil) {
        debounceTask?.cancel()
        lastBuffer = nil
        lastTypedAt = nil
        lineEngine.invalidate(paneID)
    }

    private func detectTypedCharacter(previous: String?, current: String, cursor: Int) -> Character? {
        guard let previous else { return nil }
        let prevLen = previous.count
        let currLen = current.count
        guard currLen == prevLen + 1, cursor > 0, cursor <= currLen else { return nil }
        let nsCurrent = current as NSString
        let char = nsCurrent.substring(with: NSRange(location: cursor - 1, length: 1))
        return char.first
    }

    private func computeDebounceMs(settings: InlineCompletionSettings, gapMs: Double, typedChar: Character?) -> Int {
        if let char = typedChar, Self.structuralCharacters.contains(char) {
            return 0
        }

        if gapMs < 50 {
            return min(300, Int(Double(settings.debounceMilliseconds) * 2.0))
        } else if gapMs < 120 {
            return settings.debounceMilliseconds
        } else {
            return max(40, settings.debounceMilliseconds / 2)
        }
    }
}
