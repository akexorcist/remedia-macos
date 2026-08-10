# Requirements Coverage Review

## Verdict: COVERAGE ADEQUATE (all findings resolved)

This review was run manually against the `requirements-reviewer` agent's checklist
(saved at `~/.claude/agents/requirements-reviewer.md` for automated use in future
sessions). All findings below have since been resolved directly in `REQUIREMENTS.md`
and `ARCHITECTURE.md`.

## Docs Reviewed
- `docs/REQUIREMENTS.md`
- `docs/ARCHITECTURE.md`

## Findings & Resolutions

### [BLOCKER → RESOLVED] Unsupported/invalid dropped file had no defined behavior
- Resolution: REQUIREMENTS §4 now states the file is rejected immediately on drop
  with an inline drop-zone error if it isn't one of the 4 formats or can't be read.

### [BLOCKER → RESOLVED] No error-handling/messaging requirement for conversion failures
- Resolution: REQUIREMENTS §8 now specifies an inline error state in the same window
  (message + Dismiss), partial output deleted same as Cancel.

### [MAJOR → RESOLVED] GIF encoder choice was inconsistent between the two docs
- Resolution: REQUIREMENTS §3 updated to state the committed approach (FFmpeg
  `palettegen`/`paletteuse`), matching ARCHITECTURE. `gifski`/`ImageIO` alternatives
  removed from the requirements table.

### [MAJOR → RESOLVED] Resolution/scale override UX was underspecified
- Resolution: REQUIREMENTS §6/§7 now specify scale-factor presets (1x/0.75x/0.5x/
  0.25x) relative to source resolution, plus custom resolution entry, with aspect
  ratio always preserved (no independent width/height distortion mode).

### [MAJOR → RESOLVED] Order of operations / coordinate space for crop + resolution override was unstated
- Resolution: ARCHITECTURE §6 now states the fixed pipeline order (trim → crop →
  scale → fps) and that the crop rect is always defined in the source's original,
  uncropped resolution — consistent across both engines.

### [MAJOR → RESOLVED] App-quit-mid-conversion behavior was undefined
- Resolution: REQUIREMENTS §4 now specifies a confirmation prompt on ⌘Q during an
  active conversion; confirming cancels the job and deletes the partial file first.

### [MINOR → RESOLVED] Audio codec option list was not enumerated
- Resolution: REQUIREMENTS §6 now lists AAC/ALAC/PCM for mp4/mov and Opus/Vorbis for
  webm.

### [MINOR → RESOLVED] Frame-rate override direction was not specified
- Resolution: REQUIREMENTS §6 now states both directions are supported — downsampling
  drops frames, upsampling duplicates frames (no motion interpolation).

### [MINOR → RESOLVED] Quality slider scale/labels were unspecified
- Resolution: REQUIREMENTS §6 now specifies a continuous 0–100 slider with Low/
  Balanced/High anchor labels.

## Notes (no action needed)

- WebM's total lack of native macOS support, and the consequence that both GIF and
  WebM sources need the same custom FFmpeg-based preview path (not just WebM), are
  both correctly and consistently reflected across both docs.
- The engine-routing rule (`mov ↔ mp4` native, anything touching `gif`/`webm` via
  FFmpeg) is applied consistently to both conversion and preview source selection —
  a single source of truth that avoids the two paths silently diverging later.
- Same-format "edit-only" re-encode behavior is consistently specified in both docs.
- Filename-collision handling (auto-rename, Finder convention) is clear and
  unambiguous in both docs.
