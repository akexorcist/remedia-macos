import SwiftUI
import AVFoundation
import RemediaCore

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
                if isPlaying, let mediaFile = viewModel.mediaFile, Self.isNativeFormat(mediaFile.format) {
                    TrimmedAudioPreviewView(
                        url: mediaFile.url,
                        trim: viewModel.trim,
                        startTime: seekTime ?? viewModel.trim.start,
                        seekTime: $seekTime,
                        isPlaying: $isPlaying
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let previewImage = viewModel.previewImage {
                    Image(decorative: previewImage, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                CropOverlayView(viewModel: viewModel)
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
                if let mediaFile = viewModel.mediaFile, Self.isNativeFormat(mediaFile.format) {
                    let pausedTime = seekTime ?? viewModel.trim.start
                    Task { await viewModel.updatePreview(at: pausedTime) }
                }
            }
        }
    }

    private static func isNativeFormat(_ format: OutputFormat) -> Bool {
        format == .mov || format == .mp4
    }

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            return
        }
        guard let mediaFile = viewModel.mediaFile else { return }
        let trimEnd = viewModel.trim.end
        var time = seekTime ?? viewModel.trim.start
        if time >= trimEnd {
            time = viewModel.trim.start
        }
        seekTime = time

        if Self.isNativeFormat(mediaFile.format) {
            isPlaying = true
            return
        }

        let safeFrameRate = mediaFile.frameRate.isFinite && mediaFile.frameRate > 0 ? mediaFile.frameRate : 10
        let frameInterval = 1.0 / safeFrameRate
        isPlaying = true
        let playbackStartWallClock = Date()
        let playbackStartVideoTime = time
        playbackTask = Task {
            var reachedEnd = false
            while !Task.isCancelled {
                await viewModel.updatePreview(at: time)
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
            if reachedEnd {
                seekTime = trimEnd
            }
            isPlaying = false
        }
    }
}

private final class TrimPlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Real `AVPlayer` playback (audio included) for mp4/mov, bounded to the
/// current trim range — swapped in for `PreviewPlayerView`'s still-frame
/// `Image` only while `isPlaying` is true. Scrubbing still goes through
/// `AVPlayerPreviewSource`'s `AVAssetImageGenerator`, since that's the
/// frame-accurate path arbitrary-time seeks need; this view only ever
/// plays forward from wherever that left off.
private struct TrimmedAudioPreviewView: NSViewRepresentable {
    let url: URL
    let trim: TrimRange
    let startTime: TimeInterval
    @Binding var seekTime: TimeInterval?
    @Binding var isPlaying: Bool

    func makeNSView(context: Context) -> TrimPlayerLayerView {
        let view = TrimPlayerLayerView()
        let player = AVPlayer(url: url)
        view.playerLayer.player = player
        context.coordinator.start(player: player, parent: self)
        return view
    }

    func updateNSView(_ nsView: TrimPlayerLayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: TrimPlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var player: AVPlayer?
        private var timeObserver: Any?

        func start(player: AVPlayer, parent: TrimmedAudioPreviewView) {
            self.player = player
            let startCMTime = CMTime(seconds: parent.startTime, preferredTimescale: 600)
            player.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self, !self.hasReachedEnd else { return }
                if time.seconds >= parent.trim.end {
                    self.reachedEnd(parent: parent)
                } else {
                    parent.seekTime = time.seconds
                }
            }

            player.play()
        }

        // Checked in the periodic observer above rather than via
        // `addBoundaryTimeObserver` — that API silently never fired here
        // for trim ranges tight enough that playback crosses the boundary
        // within the same tick it starts on.
        private var hasReachedEnd = false

        private func reachedEnd(parent: TrimmedAudioPreviewView) {
            hasReachedEnd = true
            player?.pause()
            player?.seek(to: CMTime(seconds: parent.trim.start, preferredTimescale: 600))
            parent.seekTime = parent.trim.end
            parent.isPlaying = false
        }

        func stop() {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player?.pause()
            player = nil
        }
    }
}
