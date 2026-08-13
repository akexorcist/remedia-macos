import AppKit

/// Drives window sizing across the two app states: a fixed-size drop zone
/// (REQUIREMENTS §4) and a resizable editor once a file is loaded. The
/// editor's size is remembered across conversions and app launches so a
/// user's preferred size sticks.
@MainActor
final class WindowSizeManager: NSObject, NSWindowDelegate {
    static let shared = WindowSizeManager()

    /// Also used by `ContentView` to give the editor-phase content a
    /// matching `.frame(minWidth:minHeight:)` — otherwise SwiftUI's default
    /// `.windowResizability(.automatic)` derives its own (smaller) minimum
    /// from the content and fights with this `NSWindow.minSize`.
    static let editorMinSize = NSSize(width: 460, height: 420)

    private static let dropZoneSize = NSSize(width: 360, height: 270)
    private static let defaultEditorSize = NSSize(width: 820, height: 780)
    private static let editorWidthKey = "editorWindowWidth"
    private static let editorHeightKey = "editorWindowHeight"

    private weak var window: NSWindow?
    private var isEditorPhase = false

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.delegate = self
        applyDropZoneSize()
    }

    func enterEditor() {
        guard let window, !isEditorPhase else { return }
        isEditorPhase = true
        window.styleMask.insert(.resizable)
        window.minSize = Self.editorMinSize
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setSize(rememberedEditorSize(), animate: true)
    }

    func enterDropZone() {
        guard window != nil else { return }
        isEditorPhase = false
        applyDropZoneSize()
    }

    private func applyDropZoneSize() {
        guard let window else { return }
        window.styleMask.remove(.resizable)
        window.minSize = Self.dropZoneSize
        window.maxSize = Self.dropZoneSize
        setSize(Self.dropZoneSize, animate: true)
    }

    private func setSize(_ size: NSSize, animate: Bool) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x -= (size.width - frame.width) / 2
        frame.origin.y -= (size.height - frame.height) / 2
        frame.size = size
        window.setFrame(frame, display: true, animate: animate)
    }

    private func rememberedEditorSize() -> NSSize {
        // UI tests should start from the same known window size every run —
        // otherwise a previous interactive session's resize persists via
        // UserDefaults and can leave a test with far more room than a real
        // first launch would have, silently hiding a layout overflow that
        // only shows up at the actual default size. Mirrors
        // `ContentView.rememberedPreviewPaneHeight()`'s same guard.
        if ProcessInfo.processInfo.environment["UI_TEST_AUTOLOAD_MEDIA_PATH"] != nil {
            return Self.defaultEditorSize
        }
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: Self.editorWidthKey)
        let height = defaults.double(forKey: Self.editorHeightKey)
        guard width >= Self.editorMinSize.width, height >= Self.editorMinSize.height else {
            return Self.defaultEditorSize
        }
        return NSSize(width: width, height: height)
    }

    func windowDidResize(_ notification: Notification) {
        guard isEditorPhase, let window else { return }
        let defaults = UserDefaults.standard
        defaults.set(window.frame.width, forKey: Self.editorWidthKey)
        defaults.set(window.frame.height, forKey: Self.editorHeightKey)
    }

    /// Vetoes any resize attempt on the drop zone screen — SwiftUI's
    /// `WindowGroup` can re-assert its own resizability on this NSWindow
    /// after `applyDropZoneSize()` already removed `.resizable`, so this is
    /// the authoritative backstop regardless of how that happens.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        isEditorPhase ? frameSize : Self.dropZoneSize
    }
}
