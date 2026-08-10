import Testing
import Foundation

/// Embeds a file into the test report (Xcode's Report Navigator) so a
/// converted output can be opened/exported directly instead of only being
/// checked via numeric assertions. Best-effort — failing to read the file
/// for attachment purposes shouldn't fail the test itself; the real
/// correctness assertions already ran before this is called.
func attachOutputToTestReport(at url: URL, named name: String) {
    guard let data = try? Data(contentsOf: url) else { return }
    Attachment.record(Array(data), named: name)
}
