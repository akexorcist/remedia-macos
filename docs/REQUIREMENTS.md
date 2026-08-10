# Remedia — Requirements

## 1. Overview

A native macOS app for personal use that converts media files between four formats:

- `.mov`
- `.mp4`
- `.gif`
- `.webm`

Single-file workflow: drop a file, pick a target format, adjust advanced settings with a live preview, convert. No batch queue.

## 2. Distribution & Platform

- **Personal use, direct distribution.** Not shipped to the Mac App Store.
- No App Sandbox constraints — free to bundle a third-party encoder and its dependencies.
- Self-signed / ad-hoc notarized build is sufficient; no App Store review compliance needed.

## 3. Conversion Engine

| Path | Engine | Notes |
|---|---|---|
| `.mov` ↔ `.mp4` | `AVFoundation` (`AVAssetReader`/`AVAssetWriter`) + `VideoToolbox` | Fully native, hardware-accelerated encode/decode (H.264/HEVC/ProRes). No third-party dependency. |
| `.gif` (read/write) | Bundled **FFmpeg** (`palettegen`/`paletteuse` two-pass filters) | `ImageIO`/`CGImageDestination` can read/write animated GIF natively, but produces mediocre quality (banding, poor palette) and gives no palette/dither control. The two-pass FFmpeg palette pipeline is used for both directions to satisfy the palette/dither requirements in §7. |
| `.webm` (read/write, any direction) | Bundled **FFmpeg** (libvpx + libopus) | Apple frameworks have **no support at all** for the WebM container — no demuxer/muxer exists in `AVFoundation`/`VideoToolbox`, regardless of codec. FFmpeg (or `libvpx`/`libwebm`/`libopus` linked directly) is the only way to support WebM on macOS. |

**Engine selection rule:** prefer hardware acceleration (VideoToolbox) whenever the conversion pair is `mov`/`mp4`. Fall back to the bundled FFmpeg pipeline for any conversion touching `webm` or `gif`.

Because personal use removes App Store/sandbox constraints, FFmpeg can be bundled as a static library or embedded binary without licensing review concerns.

## 4. Interaction Model

- **Standalone window app** (Dock icon, not a menu bar utility, not Finder-Quick-Action-only).
- Flow: **drop file → select target format → adjust advanced settings via preview → convert.**
- **One file at a time.** No multi-file batch queue.
- **Output location:** conversion finishes into a scratch file, and the completed screen shows a preview of it — sized to the actual exported file's aspect ratio (post-crop/resolution-override), not a fixed 16:9 — with a **Download** button — pressing it opens a native Save panel to pick the destination folder and filename, defaulting to the same folder as the source with the new extension (e.g. `clip.mov` → `clip.mp4`), auto-renamed on collision following Finder's convention (`clip (1).mp4`, ...) as a starting suggestion only. Downloading copies rather than moves, so the result stays previewable/downloadable again afterward. A **Back** button returns to the editor (same source file and settings still loaded) and discards the scratch file.
- **Same-format conversion allowed:** the target-format picker includes the source's own format. Converting a file to its own format (e.g. `.mp4` → `.mp4`) is a valid "edit-only" pass — applies trim/crop/quality/resolution/frame-rate changes and re-encodes without changing the container.
- **Settings persistence:** none. Every new conversion starts from default settings — nothing is remembered between runs, and there are no named presets.
- **Unsupported/invalid dropped file:** rejected immediately — on drop, the file is checked/probed, and if it isn't one of the four supported formats or can't be read, an inline error is shown in the drop zone. The app never proceeds to format selection with an invalid file.
- **Quit while converting:** ⌘Q during an active conversion shows a confirmation ("A conversion is in progress — Quit Anyway / Cancel"). Choosing Quit Anyway cancels the job and deletes the partial output file first, matching the Cancel button's behavior (§8), before the app quits.
- **Window sizing:** the drop-zone window is a small fixed size (non-resizable). Once a file is dropped and the editor (preview/settings) appears, the window becomes resizable and expands to either a sensible default size or the user's last-used editor size, whichever was remembered from a previous conversion/launch (persisted via `UserDefaults`). Resetting back to the drop zone (e.g. "Convert Another") shrinks the window back to the fixed size; the remembered editor size is unaffected.

## 5. Preview & Editing UI

A single embedded video preview player is central to the UI, used for both trim and crop:

- **Scrubbable timeline** with draggable trim in/out handles to set the start/end range for both video and GIF outputs.
- **Crop overlay** on the video frame: freeform drag rectangle (arbitrary x/y/width/height) — drag to draw when no crop exists yet, drag the rect to move it once one does, drag a corner handle to resize it. Modifier keys during a handle drag: **Shift** locks the resize to the rect's aspect ratio as of when the drag started; **Cmd** pivots the resize around the rect's center instead of anchoring the opposite corner; both together combine (aspect-locked, center-pivoted).
- **Crop aspect-ratio presets** (**Original, Free, 1:1, 16:9, 4:3**) live in their own section in the scrollable output config, above the format picker — not overlaid on the preview, since they're pure computation rather than a spatial drag interaction. A segmented control, matching the "Convert to" row's style. **Defaults to "Original"** on a freshly-loaded file — cropping starts off until the user opts in. "Original" turns cropping off (clears the rect, preview overlay isn't drawable). "Free" means "a crop is active with no fixed ratio" — like the ratio presets, it always leaves a visible, draggable/resizable rect on screen: the existing one if there is one (just dropping its ratio constraint), otherwise a default 5:4 rect (fitted to the source, with a bit of padding so the corner handles aren't flush against the preview's edge). Selection is one-directional: resizing a named preset's crop off its exact ratio falls back to "Free" being shown as selected, but resizing a Free crop onto an exact preset ratio does *not* auto-select that preset — matching a named ratio only ever happens via direct selection.
- **Crop orientation** — a Landscape/Portrait toggle next to the presets, enabled whenever a non-square *named-ratio* crop is active (disabled for "Free," even when its rect is non-square — there's no fixed shape to flip — though the toggle's displayed value still tracks the rect's actual current orientation), swaps the crop rect's width/height (e.g. 16:9 ↔ 9:16). Disabled when no crop is set or the crop is square (1:1).
- **Resolution/Scale labels** ("Original", 0.75x/0.5x/0.25x, in §6/§7) compute their shown dimensions from the active crop area's size when a crop is set, not the full source resolution — matching what those options actually produce, since output sizing is always crop-then-scale.

Both trim and crop apply identically regardless of target format (video or GIF).

**Non-native source preview:** `AVFoundation`/`AVPlayer` cannot decode `.webm` at all, and does not treat an animated `.gif` as a scrubbable movie asset either. So when the dropped source file is `.webm` **or** `.gif`, the preview player is fed by the same bundled FFmpeg pipeline used for conversion (decoded frames pushed into a custom preview view, e.g. via `CVPixelBuffer`/`AVSampleBufferDisplayLayer`) rather than `AVPlayer`. Only `.mov`/`.mp4` sources use native `AVPlayer` preview. This keeps the scrubber + crop overlay UX identical regardless of source format, at the cost of an extra decode path to implement and maintain alongside the native path.

## 6. Advanced Settings — Video Output (`mp4` / `mov` / `webm`)

Exposed controls:

- **Quality** — percentage stepper, **50–100% in 5% steps, default 85%** (revised from an earlier continuous 0–100 slider — below 50% looked too degraded to be worth exposing, and coarser steps read more like a deliberate choice than fiddly precision), mapped internally to a bitrate heuristic (or CRF-equivalent quality parameter per codec).
- **Resolution** — defaults to source ("Original", i.e. 1x — no separate 1x preset since that would just duplicate Original). Overridable via scale-factor presets relative to source resolution (**0.75x, 0.5x, 0.25x**) or a custom resolution entry. Aspect ratio is always preserved — height is computed automatically from width (or from the chosen scale factor); there is no independent width/height distortion mode.
- **Frame rate** — defaults to source ("Original"), overridable to a specific fps in either direction — downsampling (e.g. 60→30fps) drops frames; upsampling (e.g. 24→60fps) duplicates frames (no motion interpolation).
- **Trim** — start/end range via the preview timeline (§5).
- **Crop** — via the preview overlay (§5).
- **Audio**:
  - Explicit codec + bitrate control (not just "Auto"). Selectable codecs: **AAC, ALAC, PCM** for `mp4`/`mov`; **Opus, Vorbis** for `webm`.
  - **Strip audio** toggle to remove the audio track entirely.
  - When not manually overridden, codec defaults per container: AAC for `mp4`/`mov`, Opus for `webm`.

## 7. Advanced Settings — GIF Output

Exposed controls:

- **Quality** — percentage stepper, 50–100% in 5% steps, default 85% (same control as video's §6 quality — below 50% looked too degraded to be worth exposing), added after real-world testing showed the prior Auto behavior (always max colors + heaviest dithering) produced needlessly large files — dithering alone roughly doubled output size in testing. Drives palette size (32–256 colors, linear in quality) and dither method (none below ~33, Bayer 33–66, Floyd/Sierra above ~66) whenever those are left on Auto below; explicit palette/dither overrides always take precedence over this.
- **Frame rate (fps)** — defaults to source's original fps, overridable.
- **Scale** — defaults to source's original size ("Original", i.e. 1x — no separate 1x preset). Overridable via the same scale-factor presets (0.75x, 0.5x, 0.25x) or a custom resolution entry as video output (§6) — aspect ratio always preserved.
- **Trim** — via preview timeline (§5).
- **Crop** — via preview overlay (§5), same freeform + aspect-preset UI as video.
- **Palette size, dither method, loop count** — available as advanced controls, defaulting to **Auto** (derived from the Quality slider above) with manual override available for each:
  - Palette size (number of colors).
  - Dither method (e.g. none / Bayer / Floyd–Steinberg).
  - Loop count (forever / N times / play once).

GIF has no audio track, so audio settings (§6) do not apply.

## 8. Non-Functional Requirements

- Prefer hardware-accelerated encode/decode wherever the codec/container support it (VideoToolbox for H.264/HEVC in mp4/mov).
- App should remain responsive during conversion.
- **Progress feedback:** determinate progress bar showing percentage complete, for both the FFmpeg and AVFoundation conversion paths.
- **Cancel:** a visible Cancel button stops the in-progress conversion and deletes the partial output file.
- **Conversion failure:** on any failure (corrupt input, unsupported codec inside the container, encoder rejecting the settings, disk full, etc.), the progress view switches to an inline error state in the same window showing a message and a Dismiss action — no separate modal dialog. Partial output file is deleted, same as Cancel.
- No requirement for background/menu-bar operation — app runs in foreground with a window while converting.

## 9. Explicit Non-Goals

- No Mac App Store distribution.
- No batch/multi-file conversion queue.
- No saved/named presets or remembered last-used settings.
- No Finder Quick Action or menu-bar mode.
- No destination-folder picker — output always lands next to the source file.
