import Testing
import Foundation
@testable import RemediaCore

@Test func resolvesToSameFolderWithNewExtension() {
    let source = URL(fileURLWithPath: "/tmp/clip.mov")
    let result = OutputPathResolver.resolvedOutputURL(
        forSource: source,
        target: .mp4,
        fileExists: { _ in false }
    )
    #expect(result == URL(fileURLWithPath: "/tmp/clip.mp4"))
}

@Test func autoRenamesOnCollisionFinderStyle() {
    let source = URL(fileURLWithPath: "/tmp/clip.mov")
    let existing: Set<String> = [
        "/tmp/clip.mp4",
        "/tmp/clip (1).mp4"
    ]
    let result = OutputPathResolver.resolvedOutputURL(
        forSource: source,
        target: .mp4,
        fileExists: { existing.contains($0.path) }
    )
    #expect(result == URL(fileURLWithPath: "/tmp/clip (2).mp4"))
}
