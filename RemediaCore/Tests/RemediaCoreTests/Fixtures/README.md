# Test Fixtures

Real sample media for tests that want more realism than the synthetic
fixtures (`SyntheticMovie`/`SyntheticGIF`) provide — rotation metadata, real
audio tracks, B-frames, larger/odd resolutions, variable frame rate, etc.

This directory is wired into `RemediaCoreTests` only, via
`Package.swift`'s `resources: [.copy("Fixtures")]`. It is copied into the
**test bundle** at build time and read back via `Bundle.module` — the app
target has no reference to this path, so nothing placed here ever ships in
the built `.app`.

Access from a test:

```swift
guard let url = Bundle.module.url(forResource: "sample", withExtension: "mov", subdirectory: "Fixtures") else {
    // handle missing fixture
}
```
