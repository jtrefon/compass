import Foundation

enum OverlaySearchDebouncer {
    static func reschedule(
        searchTask: inout Task<Void, Never>?,
        debounceNanoseconds: UInt64,
        action: @MainActor @escaping () async -> Void
    ) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            await action()
        }
    }
}
