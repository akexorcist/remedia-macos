import AppKit

/// REQUIREMENTS §4: quitting while a conversion is running shows a
/// confirmation; confirming cancels the job (which deletes the partial
/// output file) before the app actually terminates.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: ConversionViewModel?

    /// Single-window utility app (REQUIREMENTS §4) — closing the window
    /// should quit the app rather than leaving it running with no window
    /// and a stale Dock icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, case .converting = viewModel.phase else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "A conversion is in progress"
        alert.informativeText = "Quitting now will cancel the conversion and delete the partial output file."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // .terminateLater rather than cancelling and quitting immediately —
        // cancellation's partial-file cleanup is asynchronous, and quitting
        // before it actually finishes would defeat the point of asking.
        Task { @MainActor in
            await viewModel.cancelConversionAwaitingCompletion()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
