import SwiftUI
import AppKit

/// Bridges to the hosting `NSWindow` so `WindowSizeManager` can drive its
/// size/resizability directly — SwiftUI's own window-sizing APIs don't
/// support "fixed size in one app state, remembered size in another".
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                WindowSizeManager.shared.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
