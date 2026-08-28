import AppKit

@MainActor
protocol WindowProviding: AnyObject {
    var window: NSWindow? { get }
}

@MainActor
final class WindowProvider: WindowProviding {
    private weak var _window: NSWindow?

    var window: NSWindow? {
        _window
    }

    func setWindow(_ window: NSWindow?) {
        _window = window
    }
}
