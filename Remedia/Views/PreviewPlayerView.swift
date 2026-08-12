import SwiftUI
import RemediaCore

/// Renders whichever `PreviewSource` `EngineRouter` picked for the dropped
/// file (mov/mp4 via `AVPlayer`-backed frame extraction, gif/webm via the
/// FFmpeg decode bridge — ARCHITECTURE §3/§5), plus the trim scrubber and
/// crop overlay. The view itself is source-agnostic — it just shows
/// whatever `CGImage` the view model most recently produced.
///
/// Tapping the preview plays it back within the trim range, stepping the
/// same `updatePreview(at:)` used for scrubbing — the seek indicator
/// (shared with `TrimScrubberView` via binding) follows along either way.
struct PreviewPlayerView: View {
    var viewModel: ConversionViewModel

    @State private var seekTime: TimeInterval?
    @State private var isPlaying = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                if let previewImage = viewModel.previewImage {
                    Image(decorative: previewImage, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                CropOverlayView(viewModel: viewModel)

                // Fades via the color's own alpha, not view-level .opacity()
                // — a fully view-opacity-0 element drops out of the
                // accessibility tree entirely, which broke every UI test
                // waiting on this icon to exist before it's ever been
                // hovered.
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(isHovering ? 0.85 : 0))
                    .shadow(radius: isHovering ? 4 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isHovering)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("previewPlayer.playPauseIcon")
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityValue(isHovering ? "visible" : "hidden")
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture { togglePlayback() }
            .onHover { hovering in isHovering = hovering }

            if let mediaFile = viewModel.mediaFile {
                TrimScrubberView(
                    viewModel: viewModel, duration: mediaFile.duration,
                    seekTime: $seekTime, isPlaying: $isPlaying
                )
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                playbackTask?.cancel()
                playbackTask = nil
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            return
        }
        guard let mediaFile = viewModel.mediaFile else { return }

        // A malformed frameRate would propagate NaN into the time/trimEnd
        // comparisons below (always false), spinning the loop forever.
        let safeFrameRate = mediaFile.frameRate.isFinite && mediaFile.frameRate > 0 ? mediaFile.frameRate : 10
        let frameInterval = 1.0 / safeFrameRate
        let trimEnd = viewModel.trim.end
        var time = seekTime ?? viewModel.trim.start
        if time >= trimEnd {
            time = viewModel.trim.start
        }

        isPlaying = true
        let playbackStartWallClock = Date()
        let playbackStartVideoTime = time

        playbackTask = Task {
            var reachedEnd = false
            while !Task.isCancelled {
                await viewModel.updatePreview(at: time)
                // A pause can land while the above await is in flight —
                // cancellation doesn't interrupt it, so without this check
                // the seek indicator would still visibly advance by one
                // more frame after the user already paused.
                guard !Task.isCancelled else { break }
                seekTime = time
                time += frameInterval
                if time >= trimEnd {
                    reachedEnd = true
                    break
                }

                let targetElapsed = time - playbackStartVideoTime
                let actualElapsed = Date().timeIntervalSince(playbackStartWallClock)
                let sleepDuration = targetElapsed - actualElapsed
                if sleepDuration > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
                }
            }
            // Snapping to trimEnd here is what makes the next play tap detect "at the end" and restart from trim.start.
            if reachedEnd {
                seekTime = trimEnd
            }
            isPlaying = false
        }
    }
}
