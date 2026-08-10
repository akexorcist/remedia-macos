import SwiftUI
import AppKit

private let dividerHitHeight: CGFloat = 9
private let resizableVSplitContainerSpace = "ResizableVSplit.container"

/// A minimal vertical split with a draggable divider, used instead of
/// `VSplitView` since `NSSplitView`'s divider doesn't match this app's own
/// `Divider()` styling and its resize-cursor tracking can get stuck after a
/// drag once wrapped in SwiftUI.
///
/// Reads `value.location.y` in a coordinate space named on the outer
/// `GeometryReader`, not `value.translation` in `.local` — the divider moves
/// as `topHeight` changes, so `.local`'s origin shifts mid-drag and
/// corrupts the translation math (the old jittery-resize bug).
struct ResizableVSplit<Top: View, Bottom: View>: View {
    @Binding var topHeight: CGFloat
    let topMinHeight: CGFloat
    let bottomMinHeight: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    @State private var isHoveringDivider = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let maxTopHeight = max(topMinHeight, geometry.size.height - bottomMinHeight - dividerHitHeight)
            let clampedTopHeight = min(max(topHeight, topMinHeight), maxTopHeight)

            VStack(spacing: 0) {
                top()
                    .frame(height: clampedTopHeight)

                dividerHandle(maxTopHeight: maxTopHeight)

                bottom()
                    .frame(height: max(0, geometry.size.height - clampedTopHeight - dividerHitHeight))
            }
            .coordinateSpace(name: resizableVSplitContainerSpace)
        }
    }

    private func dividerHandle(maxTopHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Divider()
            Spacer(minLength: 0)
        }
        .frame(height: dividerHitHeight)
        .contentShape(Rectangle())
        .accessibilityIdentifier("resizableVSplit.divider")
        .onHover { hovering in
            isHoveringDivider = hovering
            updateCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(resizableVSplitContainerSpace))
                .onChanged { value in
                    isDragging = true
                    updateCursor()
                    let proposed = value.location.y - dividerHitHeight / 2
                    topHeight = min(max(proposed, topMinHeight), maxTopHeight)
                }
                .onEnded { _ in
                    isDragging = false
                    updateCursor()
                }
        )
    }

    private func updateCursor() {
        if isHoveringDivider || isDragging {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
