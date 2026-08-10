# Conversion Matrix Test Plan

**Implemented 2026-08-04** — see `Tests/RemediaCoreTests/ConversionMatrixTests.swift`
(+ `SyntheticGIF.swift`, and the `fileType` param added to `SyntheticMovie.swift`).
All 16 pairs passed on the first run with no further engine changes needed —
the fixes from `FFmpegEngineTests`/`FFmpegDecodePreviewSourceTests` (timebase
rescale, trim timestamp shift, dts fallback) were already general rather than
pair-specific, which this suite corroborates. Kept below as the design record.

Goal: a test that proves **every** source → target pair among the 4 formats
actually converts correctly, not just the 3 pairs currently covered.

## Current coverage vs. the full matrix

4 formats × 4 formats = 16 pairs. Today:

| source \ target | mov | mp4 | gif | webm |
|---|---|---|---|---|
| **mov** | — | ✅ detailed (`AVFoundationEngineTests`) | ✅ detailed (`FFmpegEngineTests`) | ✅ detailed (`FFmpegEngineTests`) |
| **mp4** | — | — | — | — |
| **gif** | — | — | — | — |
| **webm** | — | — | — | — |

"Detailed" = trim/crop/scale asserted, not just success. 13 of 16 pairs have
**zero** coverage: `mov→mov`, `mp4→mov`, `mp4→mp4`, `mp4→gif`, `mp4→webm`, and
everything with gif/webm as the *source* (8 pairs). The gif/webm-as-source
gap matters most — it's a completely untested code path (`transcode.c`'s
decode/demux side, as opposed to the encode/mux side the current tests
exercise).

## What this test is for (and isn't)

**Breadth, not depth.** This suite should confirm every pair produces a
valid, probeable output — not re-verify crop/trim/scale math, which the
existing detailed tests already own. Keep per-pair settings minimal (full
trim, no crop, original resolution/fps, auto audio) so failures point at
"this pair is broken" rather than "which setting broke it."

## Missing test infrastructure

1. **`SyntheticMovie` needs an `AVFileType` parameter.** Currently hardcodes
   `.mov` in `AVAssetWriter(url:fileType:)` (`SyntheticMovie.swift:14`). Needs
   a `fileType: AVFileType = .mov` parameter so it can also produce `.mp4`
   fixtures for the `mp4→*` pairs.

2. **New `SyntheticGIF` helper**, generating a real animated GIF via
   `ImageIO`/`CGImageDestination` (a few solid-color frames + per-frame
   `kCGImagePropertyGIFDelayTime`). Must be independent of our own
   `FFmpegEngine` — using our own encoder to build the fixture that then
   tests our own decoder would weaken the test (a bug could cancel itself
   out). ImageIO is a good independent reference since it's what
   `MediaFileProber`'s real gif-probing path already uses.

3. **webm fixture has no independent source.** Unlike gif, there's no
   ImageIO-equivalent for producing webm without FFmpeg — nothing else on
   macOS can mux VP8/VP9+Opus. Pragmatic approach: bootstrap it by running
   `FFmpegEngine` mov→webm once per test (or once for a shared fixture) to
   produce the source file, then use *that* as input for the `webm→*`
   pairs. This isn't fully circular: encode (mux) and decode (demux) are
   different code paths within `transcode.c`, so this still meaningfully
   tests the decode direction independently. Downloading a real sample
   `.webm` from the network was considered and rejected — it'd make the
   test suite non-hermetic (network-dependent, subject to source
   availability/licensing) for a personal project that should run offline
   reliably.

## Test shape

A single parameterized test using Swift Testing's `@Test(arguments:)` over
all 16 `(source: OutputFormat, target: OutputFormat)` pairs, rather than 16
near-duplicate functions:

```swift
@Test(arguments: [
    (OutputFormat.mov, OutputFormat.mov), (OutputFormat.mov, OutputFormat.mp4),
    (OutputFormat.mov, OutputFormat.gif), (OutputFormat.mov, OutputFormat.webm),
    (OutputFormat.mp4, OutputFormat.mov), (OutputFormat.mp4, OutputFormat.mp4),
    (OutputFormat.mp4, OutputFormat.gif), (OutputFormat.mp4, OutputFormat.webm),
    (OutputFormat.gif, OutputFormat.mov), (OutputFormat.gif, OutputFormat.mp4),
    (OutputFormat.gif, OutputFormat.gif), (OutputFormat.gif, OutputFormat.webm),
    (OutputFormat.webm, OutputFormat.mov), (OutputFormat.webm, OutputFormat.mp4),
    (OutputFormat.webm, OutputFormat.gif), (OutputFormat.webm, OutputFormat.webm),
])
func conversionMatrix(sourceFormat: OutputFormat, targetFormat: OutputFormat) async throws {
    // 1. makeSourceFixture(format: sourceFormat) -> MediaFile
    //    (mov/mp4 via SyntheticMovie, gif via SyntheticGIF, webm via the
    //    FFmpegEngine bootstrap above)
    // 2. settings = targetFormat == .gif ? .gif(...) : .video(...), full trim,
    //    no crop, original resolution/fps, auto audio
    // 3. engine = EngineRouter.engine(source: sourceFormat, target: targetFormat)
    // 4. run job to completion, assert:
    //    - job.state == .completed (record the failure state on Issue.record
    //      if not, so a failing pair says *why*, not just *that*)
    //    - output file exists and is non-empty
    //    - MediaFileProber.probe(output) succeeds and reports duration > 0
    //    - resolution matches source (within even-dimension rounding)
}
```

## Open questions to settle when implementing

- Should the `.mov`/`.mp4` and `.gif` fixtures be generated once per test run
  (shared, faster) or fresh per parameterized case (slower, more isolated)?
  Given each conversion is fast (~1s in existing tests), fresh-per-case is
  probably fine and simpler.
- Same-format pairs (`mov→mov`, `mp4→mp4`, `gif→gif`, `webm→webm`) exercise
  REQUIREMENTS §4's "edit-only" re-encode path — worth a comment noting
  that's specifically what they're for, not an oversight.
