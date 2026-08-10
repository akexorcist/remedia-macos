import SwiftUI
import AVFoundation
import AppKit
import CoreImage
import RemediaCore

/// Paused by default (REQUIREMENTS: the user should be able to verify the
/// converted result deliberately, not have it auto-playing at them) — tap
/// anywhere to play/pause, matching the editor's `PreviewPlayerView`.
struct ResultPlayerView: View {
    let url: URL
    let mediaFile: MediaFile?

    @State private var isPlaying = false
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Group {
                switch mediaFile?.format {
                case .mov, .mp4:
                    AVPlayerContainerView(url: url, isPlaying: $isPlaying)
                case .gif:
                    GifPlayerView(url: url, isPlaying: $isPlaying)
                case .webm:
                    if let mediaFile {
                        WebmLoopPlayerView(mediaFile: mediaFile, isPlaying: $isPlaying)
                    } else {
                        Color.black
                    }
                case nil:
                    Color.black
                }
            }

            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 4)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isHovering)
                .allowsHitTesting(false)
                .accessibilityIdentifier("resultPlayer.playPauseIcon")
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityValue(isHovering ? "visible" : "hidden")
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { isPlaying.toggle() }
        .onHover { hovering in isHovering = hovering }
    }
}

private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .none
        view.playerLayer.player = player

        context.coordinator.loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            if isPlaying { player.play() }
        }
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if isPlaying {
            nsView.playerLayer.player?.play()
        } else {
            nsView.playerLayer.player?.pause()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Coordinator) {
        if let token = coordinator.loopObserver {
            NotificationCenter.default.removeObserver(token)
        }
        nsView.playerLayer.player?.pause()
    }

    final class Coordinator {
        var loopObserver: NSObjectProtocol?
    }
}

private struct GifPlayerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOf: url)
        imageView.animates = isPlaying
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = isPlaying
    }
}

/// No native webm playback and no audio decode path, so this drives a
/// silent visual loop over `FFmpegSequentialPlayer` instead.
private let webmLoopCIContext = CIContext()

private struct WebmLoopPlayerView: View {
    let mediaFile: MediaFile
    @Binding var isPlaying: Bool

    @State private var currentImage: CGImage?
    @State private var player: FFmpegSequentialPlayer?
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            if let currentImage {
                Image(decorative: currentImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: mediaFile.url) {
            await showFirstFrame()
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startPlaybackLoop()
            } else {
                playbackTask?.cancel()
            }
        }
        .onDisappear {
            playbackTask?.cancel()
        }
    }

    /// Decodes just the first frame so a paused player shows a thumbnail
    /// rather than a blank black rect — mirrors the editor preview always
    /// showing the current frame regardless of play state.
    private func showFirstFrame() async {
        guard let newPlayer = FFmpegSequentialPlayer(url: mediaFile.url) else { return }
        let decoded: CGImage? = await Task.detached {
            guard let (frame, _) = newPlayer.nextFrame() else { return nil }
            let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
            return webmLoopCIContext.createCGImage(ciImage, from: ciImage.extent)
        }.value
        currentImage = decoded
        player = newPlayer
        if isPlaying {
            startPlaybackLoop()
        }
    }

    private func startPlaybackLoop() {
        guard let player else { return }
        guard playbackTask == nil || playbackTask?.isCancelled == true else { return }
        // Guards the UInt64(Double) conversion below against a malformed
        // frameRate from the file's own metadata (also fixed at the source
        // in cffmpeg_probe).
        let safeFrameRate = mediaFile.frameRate.isFinite && mediaFile.frameRate > 0 ? mediaFile.frameRate : 10
        let frameInterval = 1.0 / safeFrameRate

        let previousTask = playbackTask
        playbackTask = Task {
            // `player` allows only one call in flight at a time; cancelling
            // the previous task doesn't stop a detached decode already
            // running, so wait for it to actually finish before reusing it.
            await previousTask?.value

            while !Task.isCancelled {
                let decoded: CGImage? = await Task.detached {
                    var result = player.nextFrame()
                    if result == nil {
                        player.seek(to: 0)
                        result = player.nextFrame()
                    }
                    guard let (frame, _) = result else { return nil }
                    let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
                    return webmLoopCIContext.createCGImage(ciImage, from: ciImage.extent)
                }.value
                guard let decoded, !Task.isCancelled else { break }
                currentImage = decoded

                try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            }
        }
    }
}
