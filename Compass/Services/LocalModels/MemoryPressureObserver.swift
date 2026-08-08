import Foundation

enum MemoryPressureLevel: Sendable {
    case warning
    case critical
}

protocol MemoryPressureObserving: Sendable {}

final class MemoryPressureObserver: MemoryPressureObserving, @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private let onMemoryPressure: @Sendable (MemoryPressureLevel) -> Void

    init(onMemoryPressure: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        self.onMemoryPressure = onMemoryPressure
        setupObserver()
    }

    /// macOS-correct pressure source. The previous implementation listened for
    /// `NSMemoryWarningNotification` — an iOS-only notification that no macOS
    /// component ever posts, so the unload path NEVER ran.
    private func setupObserver() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let level: MemoryPressureLevel = source.data == .critical ? .critical : .warning
            self?.onMemoryPressure(level)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
