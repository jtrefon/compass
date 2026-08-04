import Foundation

protocol MemoryPressureObserving: Sendable {}

final class MemoryPressureObserver: MemoryPressureObserving, @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private let onMemoryPressure: @Sendable () -> Void

    init(onMemoryPressure: @escaping @Sendable () -> Void) {
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
            self?.onMemoryPressure()
        }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
