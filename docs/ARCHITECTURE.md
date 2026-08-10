# Remedia — Architecture

Companion to `REQUIREMENTS.md`. Captures tech stack, module boundaries, and the key
abstractions needed to satisfy the requirements — most notably the WebM live-preview
requirement, which drives the FFmpeg integration approach.

## 1. Tech Stack

| Decision | Choice |
|---|---|
| Language | Swift (latest), Swift Concurrency (async/await, actors) for jobs & progress |
| UI | SwiftUI |
| Deployment target | Apple Silicon only, latest macOS — no Intel, no compatibility shims |
| Native video path | `AVFoundation` + `VideoToolbox` |
| WebM/GIF path | FFmpeg, **built and vendored as static XCFrameworks, linked in-process** |

**Why linked libraries, not a CLI subprocess:** the requirement that WebM (and GIF)
sources get the same live scrubber + crop-overlay preview as native sources means the
app needs direct access to decoded frames, not just a finished output file. Shelling out
to an `ffmpeg` binary and piping raw frames back would work but adds a second
process-management/pipe-protocol layer for no benefit once you're already vendoring
FFmpeg. Linking `libavformat`/`libavcodec`/`libavutil`/`libswscale`/`libavfilter` (+
`libvpx`, `libopus`) directly gives one in-process decode path shared by both the
conversion engine and the preview.

## 2. Module Layout

Single Xcode project, split into a local Swift package for everything below the UI so
domain/engine logic stays testable without SwiftUI:

```
Remedia.xcodeproj
├── Remedia (app target)
│   ├── App/                     — entry point, window
│   ├── Views/                   — SwiftUI views (see §5)
│   └── ViewModels/
├── RemediaCore (local SPM package)
│   ├── Domain/                  — MediaFile, ConversionSettings, format types
│   ├── Engines/                 — AVFoundationEngine, FFmpegEngine, EngineRouter
│   ├── Preview/                 — AVPlayerPreviewSource, FFmpegDecodePreviewSource
│   └── Infrastructure/          — OutputPathResolver, ProgressReporter
├── CFFmpeg (C interop target)
│   └── module.modulemap + shim headers exposing libav* C API to Swift
├── Vendor/FFmpeg/               — prebuilt XCFrameworks (libavcodec, libavformat, libavutil,
│                                   libswscale, libavfilter, libvpx, libopus)
└── Scripts/
    └── build-ffmpeg.sh          — reproducible arm64-macOS build of the above
```

## 3. Core Abstractions

### `MediaFile`
Probed metadata for the dropped source: url, container format, duration, resolution,
frame rate, has-audio flag. Probed via `AVAsset` for mov/mp4, via
`avformat_open_input`/`avformat_find_stream_info` for gif/webm.

### `ConversionSettings`
Value types matching REQUIREMENTS §6/§7 exactly:
- `VideoSettings`: quality (0–1, mapped to codec-specific CRF at the engine boundary),
  resolution (`.original` or explicit), frameRate (`.original` or explicit), trim range,
  crop rect, audio (`.auto` / explicit codec+bitrate / `.stripped`).
- `GifSettings`: fps (`.original` or explicit), scale (`.original` or explicit), trim
  range, crop rect, palette size (`.auto` or explicit), dither (`.auto` / none / Bayer /
  Floyd–Steinberg), loop (`forever` / `times(n)` / `once`).

### `ConversionEngine` protocol
```swift
protocol ConversionEngine {
    func convert(_ source: MediaFile, to target: OutputFormat,
                 settings: ConversionSettings) -> ConversionJob
}
```
Two implementations:
- **`AVFoundationEngine`** — `AVAssetReader`/`AVAssetWriter` + `VideoToolbox` compression
  session. Crop applied via `AVMutableVideoComposition` transform; trim via asset time
  range; progress from `AVAssetExportSession.progress` (or manual byte/time tracking if
  using the reader/writer pair directly for finer control).
- **`FFmpegEngine`** — builds an `avfilter` graph per job: `crop` → `scale` → `fps` →
  (for GIF) `palettegen`/`paletteuse` for the two-pass palette approach that gives the
  "Auto" palette/dither defaults reasonable quality. Progress computed from decoded
  packet PTS ÷ total duration, since there's no built-in progress object like
  `AVAssetExportSession`.

### `EngineRouter`
Single routing rule, shared by conversion **and** preview source selection:

> mov ↔ mp4 → native (`AVFoundationEngine` / `AVPlayerPreviewSource`)
> anything touching gif or webm (either direction) → FFmpeg (`FFmpegEngine` /
> `FFmpegDecodePreviewSource`)

Keeping conversion and preview on the same routing rule means there's exactly one place
that decides "is this file's format native or not," instead of the two paths silently
diverging over time.

### `PreviewSource` protocol
```swift
protocol PreviewSource {
    var duration: TimeInterval { get }
    func frame(at time: TimeInterval) async -> CVPixelBuffer
}
```
- **`AVPlayerPreviewSource`** — thin wrapper over `AVPlayer`, used for mov/mp4 sources.
- **`FFmpegDecodePreviewSource`** — decodes via the same `CFFmpeg` bridge used by
  `FFmpegEngine`, rendering into a `CVPixelBuffer` displayed through
  `AVSampleBufferDisplayLayer`. Used for gif and webm sources.

Both feed the same SwiftUI preview view, so the timeline scrubber and crop overlay are
written once against the protocol, not once per source format.

### `ConversionJob`
An `actor` wrapping one running conversion: exposes an `AsyncStream<Double>` of
progress (0–1) and a `cancel()` that (a) sets a flag checked inside the FFmpeg
read/decode loop or calls `AVAssetExportSession.cancelExport()`, and (b) deletes the
partial output file via `OutputPathResolver`.

### `OutputPathResolver`
Given source URL + target format, computes the same-folder output path and resolves
collisions by appending `" (n)"` before the extension, following Finder's own
duplicate-naming convention (REQUIREMENTS §4).

## 4. Data Flow

1. Drop file → `MediaFile` probed (AVAsset or avformat, depending on extension).
2. `EngineRouter` picks the `PreviewSource` for that source format; `PreviewPlayerView`
   initializes with full-duration trim range, no crop.
3. Pick target format → settings panel (`VideoSettingsView` or `GifSettingsView`) shown
   with defaults per REQUIREMENTS §6/§7 (Original resolution/fps, Auto quality/audio/
   palette/dither/loop). Same-format target is allowed (edit-only re-encode pass).
4. Adjust trim (scrubber) / crop (overlay) / settings → all held in one
   `ConversionSettings` value on the view model.
5. Hit Convert → `EngineRouter` resolves the `ConversionEngine` for (source format,
   target format) → `ConversionJob` started as a `Task` → progress stream drives the
   determinate progress bar; Cancel button calls `job.cancel()`.
6. On success: `OutputPathResolver`'s resolved path is the final file, written
   next to the source. On cancel: partial file deleted, UI returns to the settings
   state (source file/settings retained, nothing persisted per REQUIREMENTS' no-presets
   rule).

## 5. View Layer (SwiftUI)

- `DropZoneView` — drag-and-drop target, hands the URL to the view model.
- `FormatPickerView` — target format picker, includes the source's own format.
- `PreviewPlayerView` — hosts either an `AVPlayer`-backed player layer or the
  `AVSampleBufferDisplayLayer` fed by `FFmpegDecodePreviewSource`, plus:
  - `TrimScrubberView` — draggable in/out handles over a timeline.
  - `CropOverlayView` — freeform-draggable rect + aspect-preset buttons
    (Free/1:1/16:9/9:16/4:3), drawn with `Canvas`/`GeometryReader` on top of the frame.
- `VideoSettingsView` / `GifSettingsView` — per REQUIREMENTS §6/§7 controls.
- `ConversionProgressView` — determinate progress bar + Cancel button.

`ConversionViewModel` (`@Observable`) owns `MediaFile`, `ConversionSettings`, the active
`PreviewSource`, and the current `ConversionJob?`; it's the only thing views talk to.

## 6. Non-Obvious Implementation Notes

- **Crop is implemented twice, deliberately.** `AVFoundationEngine` expresses it as a
  Core Image crop + translate + scale chain inside an `AVMutableVideoComposition`'s
  `applyingCIFiltersWithHandler` handler (operating on `request.sourceImage`, which
  AVFoundation already hands over rotation-corrected — this avoids hand-rolling
  `CGAffineTransform` composition against the track's `preferredTransform`, which is
  easy to get subtly wrong for portrait/rotated source video); `FFmpegEngine` expresses
  it as an `avfilter` `crop` string. Both consume the same `CGRect` from
  `ConversionSettings` — the divergence is contained entirely inside each engine, never
  leaks into the UI or domain layer. Note CIImage's coordinate space is Y-up
  (origin bottom-left), so the crop rect's Y is flipped against the source extent
  height before use.
- **Crop/resolution/fps ordering is fixed:** the crop `CGRect` in `ConversionSettings`
  is always defined in the source's original, uncropped resolution. Any resolution
  override is applied as a final scale of the already-cropped frame — the effective
  per-engine pipeline is trim → crop → scale (resolution override) → fps override, in
  that order, on both engines. This keeps the crop overlay's coordinates meaningful
  regardless of whether a resolution override is also set, and keeps the two engines'
  filter/composition graphs behaviorally identical despite being implemented
  separately.
- **`MediaFile.resolution` for mov/mp4 sources is derived from an actually-rendered
  frame** (`AVAssetImageGenerator`, `appliesPreferredTrackTransform = true` — the same
  mechanism `AVPlayerPreviewSource` uses for the live preview), not from hand-computing
  `naturalSize.applying(preferredTransform)`. That bounding-box computation only
  correctly captures a clean 90°-multiple rotation; anything else in the transform
  silently disagrees with what's actually rendered. Since this same `resolution` value
  is what `CropOverlayView` treats as "source size" for its letterbox/coordinate math
  *and* what `AVFoundationEngine` treats as "source size" when interpreting the stored
  crop `CGRect`, any disagreement between it and the real rendered frame desyncs the
  crop overlay from the pixels displayed underneath it, and separately desyncs the
  conversion's own crop from what the user actually selected — a shifted-and-stretched
  crop despite the UI, the crop math, and the output dimensions each individually
  looking correct in isolation. `AVFoundationEngine.run` reuses the passed-in
  `source.resolution` rather than re-deriving it a second time, so there's exactly one
  computation of this value, reused everywhere — it can't drift out of sync with itself.
- **GIF quality** relies on FFmpeg's two-pass `palettegen`/`paletteuse` filters rather
  than a single-pass encode — this is what the "Auto" palette/dither defaults in
  REQUIREMENTS §7 are actually implemented with.
- **Same-format conversion always re-encodes** rather than stream-copying, since trim/
  crop/quality edits can't be applied via a stream copy. (A no-edits fast-path stream
  copy is a possible later optimization, not required for v1.)
- **Progress reporting is asymmetric across engines** — both `FFmpegEngine` and
  `AVFoundationEngine` compute it manually (decoded timestamp ÷ total duration), since
  `AVFoundationEngine` is built on `AVAssetReader`/`AVAssetWriter` rather than
  `AVAssetExportSession` (see decision below) and so doesn't get progress for free.
- **`AVFoundationEngine` is built on `AVAssetReader`/`AVAssetWriter`, not
  `AVAssetExportSession`** (resolves the §7 open item from scaffold phase).
  `AVAssetExportSession` only exposes a fixed set of named presets for encode
  parameters — it can't express the continuous 0–100 quality slider mapped to a
  codec-specific bitrate/quality value that REQUIREMENTS §6 calls for, since that needs
  `AVAssetWriterInput.outputSettings`' `AVVideoCompressionPropertiesKey` dictionary
  (`AVVideoQualityKey`/`AVVideoAverageBitRateKey`) directly. The reader side uses
  `AVAssetReaderVideoCompositionOutput` (so crop/scale/rotation are already applied via
  the video composition before the writer ever sees a frame) for video, and a plain
  `AVAssetReaderTrackOutput` decoding to linear PCM for audio, which the writer then
  re-encodes to the target `AudioMode` — the standard "decompress then recompress"
  pattern needed to change audio codec/bitrate at all.
- **`RemediaTests`** is a plain `bundle.unit-test` target (`@testable import
  Remedia`, runs in-process) alongside `RemediaUITests`
  (`bundle.ui-testing`, runs the built app as a separate process via the accessibility
  tree). Pure app-layer logic that doesn't need a live view hierarchy — crop
  preset/ratio matching, resize/aspect-lock geometry, coordinate mapping — is exposed as
  `internal` (not `private`) static functions on the owning view (e.g.
  `CropPresetsView.matchedPreset(for:)`, `CropOverlayView.aspectLockedRect(...)`)
  specifically so `RemediaTests` can exercise it directly: faster and more
  exhaustive (many ratio/orientation/quadrant combinations) than driving the same cases
  through XCUITest drags.

## 7. Open Items

- **FFmpeg is now actually vendored and linked** (as of 2026-08-04) — `libvpx`,
  `libopus`, and FFmpeg (`libavformat`/`libavcodec`/`libavutil`/`libswscale`/
  `libavfilter`/`libswresample`) were built from source per `Scripts/build-ffmpeg.sh`
  and packaged as local xcframeworks under `Vendor/FFmpeg/`. See
  `Vendor/FFmpeg/README.md` for the header-vendoring split this required (Xcode's
  package-graph integration doesn't expose a local binaryTarget's headers to a
  sibling target's clang dependency scanner, so the real headers live as plain files
  inside `RemediaCore/Sources/CFFmpeg/include/` rather than being read from the
  xcframeworks themselves) and the linkage smoke tests
  (`CFFmpegLinkageTests.swift`) that confirm the `libvpx`/`libopus` wrapper encoders
  are genuinely compiled in, not just headers that parse.
- **`FFmpegEngine.convert` is now implemented** (as of 2026-08-04) — a real decode →
  filter → encode → mux pipeline in C (`Sources/CFFmpeg/transcode.c`), covering every
  pair `EngineRouter` sends here: source or target is gif/webm, in either direction
  (including e.g. webm → mov or gif → mp4, where FFmpeg is needed only because the
  *source* isn't natively readable, even though the target container is native).
  Video: `h264_videotoolbox` for mov/mp4, `libvpx-vp9` for webm, `gif` for gif, with
  crop/scale/fps via an avfilter graph (`split`+`palettegen`+`paletteuse` for gif's
  palette per REQUIREMENTS §7). Audio: `aac`/`alac`/`pcm_s16le`/`libopus`/`vorbis`
  chosen by `AudioMode` + target container, decode-then-reencode via a second
  filter graph. `FFmpegEngine.swift` itself is a thin wrapper resolving
  `ConversionSettings` into the C options struct and bridging progress/cancellation
  to `ConversionJob` via C function-pointer callbacks (`Unmanaged` context pointers).
  Verified with real integration tests (`FFmpegEngineTests.swift`) against a
  synthetic source, not just a clean compile — mov→webm with trim/crop/scale, and
  mov→gif. Real webm probing was added to `MediaFileProber` alongside this (needed
  to verify the webm output), closing that stub too.
  - **Three real bugs found and fixed via this testing, worth knowing about if this
    code is touched again:** (1) a filter like `fps=N` renegotiates the buffersink's
    own output time_base to `1/N`, not the time_base the graph was fed — frames must
    be rescaled from `av_buffersink_get_time_base()`, not assumed to match the
    decoder's original time_base, or timestamps silently corrupt (this broke GIF
    output specifically, since its muxer enforces strictly-monotonic dts and caught
    the collision that h264/vp9 quietly tolerated). (2) Output timestamps must be
    shifted so the trimmed range starts at 0 — otherwise a trim like `[1s, 3s]`
    leaves the output's own timeline starting at 1s, confusing duration reporting.
    (3) A non-B-frame encoder (gif) can leave a packet's `dts` unset; the muxer's
    interleaving queue requires a valid one, so falling back to `dts = pts` when
    unset is necessary.
- **`FFmpegDecodePreviewSource.frame` is now implemented** (as of 2026-08-04) — a
  separate, simpler C decode-only loop (`Sources/CFFmpeg/preview_decode.c`,
  `cffmpeg_decode_frame_at`) than the full transcode pipeline: seeks to the nearest
  keyframe at or before the requested time, decodes forward to the exact frame,
  converts to BGRA via `libswscale`, and hands the raw bytes back to Swift to build a
  `CVPixelBuffer`. A real bug was caught by testing here too:
  `avcodec_receive_frame` unrefs its output frame internally the moment a
  *subsequent* call returns EAGAIN/EOF, so "keep the last decoded frame in case we
  hit EOF before the target time" requires cloning it into a separate holder frame
  (`av_frame_ref`) as each candidate is decoded — relying on the original frame still
  holding data after the loop exits silently hands `sws_scale` a cleared, all-NULL
  frame. Caught by asserting decoded pixel content isn't all-zero (dimension checks
  alone didn't catch it) and confirmed by temporarily reverting the fix to watch the
  same test fail before restoring it.
- **Preview rendering, real crop interaction, and quit-while-converting confirmation
  are now wired up** (as of 2026-08-04), closing out the remaining scaffold-era
  TODOs: `ConversionViewModel` now holds the `PreviewSource` and renders frames via
  `CIContext`; `CropOverlayView` does real freeform drag-to-create /
  drag-to-move + aspect-ratio-preset snapping, converting between the (possibly
  letterboxed) on-screen preview and the source's actual pixel resolution;
  `AppDelegate.applicationShouldTerminate` shows the confirmation alert and uses
  `.terminateLater` + `NSApplication.reply(toApplicationShouldTerminate:)` so quitting
  actually waits for cancellation's partial-file cleanup rather than racing it.
- **`TrimScrubberView` upgraded to a single timeline control** (as of 2026-08-04) —
  one track with two draggable pill-shaped handles and a highlighted selected range,
  replacing the earlier two-slider placeholder. Dragging either handle previews that
  handle's exact frame, matching REQUIREMENTS §5, without a separate playhead concept.
- **Full conversion-matrix test implemented** (as of 2026-08-04) — all 16
  source/target pairs, not just the few pairs exercised by the per-engine tests. See
  `docs/CONVERSION_MATRIX_TEST_PLAN.md` for the design record; all 16 passed without
  needing further engine changes.
- **Real-world sample fixtures added, and they caught what 28 synthetic test cases
  never did** (as of 2026-08-04). `Tests/RemediaCoreTests/Fixtures/
  sample_video.{mov,mp4,gif,webm}` are genuine, independently-authored files (not
  our own encoder output), wired in via SwiftPM's test-only `resources:` — the app
  target has no reference to this path, so nothing here ships in the built `.app`.
  Every synthetic fixture up to this point was silent (no audio track at all), so
  the audio encode path had literally never run end-to-end. Testing against real
  files with real audio immediately surfaced three bugs:
  1. **Opus rejects arbitrary sample rates** — it only accepts 8/12/16/24/48 kHz;
     the code hardcoded 44100 (fine for AAC/ALAC/PCM) for every codec, so any `*→webm`
     conversion with audio failed outright at encoder setup.
  2. **AAC and Opus require exact frame sizes** per `avcodec_send_frame` call —
     sending whatever size the filter graph happened to produce (not the encoder's
     `frame_size`) failed with `EINVAL`. Fixed with the standard `AVAudioFifo`-based
     buffering pattern (`cffmpeg_push_audio_frame`/`cffmpeg_encode_audio_chunk`/
     `cffmpeg_flush_audio_fifo` in transcode.c): filtered samples accumulate in a
     FIFO and are drained in exact `encoderCtx->frame_size` chunks, with pts tracked
     as a running sample count (frame_size == 0 encoders like PCM just encode
     whatever's available).
  3. **A real crash, not just a logic bug**: the Opus sample-rate check called
     `strcmp` on `options->audioCodecName` unconditionally, but that pointer is
     legitimately `NULL` whenever there's no audio at all (gif targets, stripped
     audio) — which is most of the test matrix. This didn't just fail one test; it
     segfaulted the whole process, including previously-passing *synthetic* tests
     that happened to run after it. Found via `swift test --sanitize=address`,
     which pinpointed the exact `strcmp` call — worth remembering as the tool of
     first resort for a crash (not just a failure) in this codebase, since ordinary
     stack traces from a bare `signal 11` gave no useful location at all.
  4. **`Attachment.record`** (Swift Testing) embeds each conversion's actual output
     file into the Xcode test report — verified end-to-end by generating a real
     `.xcresult` and extracting an attachment back out with `xcresulttool`, then
     confirming `file` recognized it as a genuine, valid QuickTime movie.
- **Integer overflow in SAR-derived display width, found via security review**
  (as of 2026-08-11) — `probe.c`, `preview_decode.c`, and `sequential_decode.c` each
  computed a container's display width as `codedWidth * (sar.num/sar.den)` with no
  bounds check; a crafted or simply corrupt `sample_aspect_ratio` (e.g. a
  Matroska/WebM `DisplayWidth` tag) could overflow `int` and wrap, desyncing the
  `malloc`'d BGRA buffer's size from what `sws_scale` is told to write into it —
  reachable just by dropping the file, since the live preview decodes a frame
  automatically. Fixed with a shared `cffmpeg_sanitized_display_width` helper
  (`internal.h`) that falls back to the coded width whenever the scaled value
  doesn't round-trip into `[1, 16384]`, used at all three call sites.
- **Remaining, deliberately deferred:** none currently tracked. `FFmpegEngine`/
  `AVFoundationEngine`/`FFmpegDecodePreviewSource`/`AVPlayerPreviewSource` are all
  real and tested against both synthetic and real-world media; UI is wired
  end-to-end. Future work (batch conversion, presets, etc.) is explicitly out of
  scope per REQUIREMENTS §9, not deferred.
