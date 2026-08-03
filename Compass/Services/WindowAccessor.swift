import SwiftUI
import AppKit

private struct WindowAccessorKey: EnvironmentKey {
    static let defaultValue: NSWindow? = nil
}

extension EnvironmentValues {
    var nsWindow: NSWindow? {
        get { self[WindowAccessorKey.self] }
        set { self[WindowAccessorKey.self] = newValue }
    }
}

struct WindowCaptureView: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            onWindow(window)
        }
    }
}
