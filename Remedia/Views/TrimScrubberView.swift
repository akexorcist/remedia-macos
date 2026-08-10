import SwiftUI
import RemediaCore

/// Single timeline with draggable start/end trim handles over a track
/// (REQUIREMENTS §5), plus a separate seek indicator for previewing any
/// point within the trimmed range without moving the trim itself.
struct TrimScrubberView: View {
    var viewModel: ConversionViewModel
    let duration: TimeInterval

    private let handleWidth: CGFloat = 14
    private let trackHeight: CGFloat = 28
    private let seekHitWidth: CGFloat = 16
    private static let trackCoordinateSpace = "TrimScrubberView.track"

    /// Shared with `PreviewPlayerView` — its playback loop drives this the
    /// same way scrubbing does. `nil` until moved; displayed position
    /// always re-clamps to the current trim range regardless, so staleness
    /// here can't put the indicator out of bounds.
    @Binding var seekTime: TimeInterval?
    @Binding var isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let safeDuration = max(duration, 0.01)
                let startX = xPosition(for: viewModel.trim.start, duration: safeDuration, width: width)
                let endX = xPosition(for: viewModel.trim.end, duration: safeDuration, width: width)
                let currentSeek = min(max(seekTime ?? viewModel.trim.start, viewModel.trim.start), viewModel.trim.end)
                let seekX = xPosition(for: currentSeek, duration: safeDuration, width: width)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: trackHeight)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(endX - startX, 0), height: trackHeight)
                        .position(x: (startX + endX) / 2, y: trackHeight / 2)
                        .contentShape(Rectangle())
                        .gesture(seekDragGesture(width: width, duration: safeDuration))
                        .accessibilityIdentifier("trimScrubber.selectedRange")

                    handle
                        .position(x: startX, y: trackHeight / 2)
                        .gesture(dragGesture(width: width, duration: safeDuration, isStart: true))
                        .accessibilityIdentifier("trimScrubber.startHandle")

                    handle
                        .position(x: endX, y: trackHeight / 2)
                        .gesture(dragGesture(width: width, duration: safeDuration, isStart: false))
                        .accessibilityIdentifier("trimScrubber.endHandle")

                    seekIndicator
                        .frame(width: seekHitWidth, height: trackHeight)
                        .position(x: seekX, y: trackHeight / 2)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("trimScrubber.seekIndicator")
                }
                .coordinateSpace(name: Self.trackCoordinateSpace)
            }
            .frame(height: trackHeight)

            HStack {
                Text(format(viewModel.trim.start))
                Spacer()
                Text(format(viewModel.trim.end))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: handleWidth / 2)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: trackHeight)
            .shadow(radius: 1)
    }

    private var seekIndicator: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: trackHeight)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .offset(y: -5)
            }
            .shadow(radius: 1)
    }

    /// Dragging either trim handle immediately updates the preview to that
    /// handle's frame, so scrubbing the in/out points doubles as previewing
    /// them (REQUIREMENTS §5) — the seek indicator follows along so it
    /// stays consistent with whatever's currently shown.
    private func dragGesture(width: CGFloat, duration: TimeInterval, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackCoordinateSpace))
            .onChanged { value in
                isPlaying = false
                let clampedX = min(max(value.location.x, 0), width)
                let time = time(forX: clampedX, duration: duration, width: width)
                if isStart {
                    let newStart = min(time, viewModel.trim.end)
                    viewModel.trim = TrimRange(start: newStart, end: viewModel.trim.end)
                    seekTime = newStart
                    Task { await viewModel.updatePreview(at: newStart) }
                } else {
                    let newEnd = max(time, viewModel.trim.start)
                    viewModel.trim = TrimRange(start: viewModel.trim.start, end: newEnd)
                    seekTime = newEnd
                    Task { await viewModel.updatePreview(at: newEnd) }
                }
            }
    }

    /// The seek indicator previews any point in time but is confined to the
    /// selected trim range — it can't scrub outside what will actually be
    /// in the output.
    private func seekDragGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackCoordinateSpace))
            .onChanged { value in
                isPlaying = false
                let clampedX = min(max(value.location.x, 0), width)
                let time = time(forX: clampedX, duration: duration, width: width)
                let clampedTime = min(max(time, viewModel.trim.start), viewModel.trim.end)
                seekTime = clampedTime
                Task { await viewModel.updatePreview(at: clampedTime) }
            }
    }

    private func xPosition(for time: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func time(forX x: CGFloat, duration: TimeInterval, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(x / width) * duration
    }

    private func format(_ time: TimeInterval) -> String {
        String(format: "%.1fs", time)
    }
}
