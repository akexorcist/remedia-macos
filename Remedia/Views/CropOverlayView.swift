import SwiftUI
import AppKit
import RemediaCore

/// Freeform-draggable crop rectangle + resize handles (REQUIREMENTS §5),
/// converting between the crop's source-resolution coordinate space
/// (ARCHITECTURE §6) and wherever the letterboxed preview sits on screen.
///
/// Handle-drag modifiers, checked live via `NSEvent.modifierFlags`
/// (`DragGesture` doesn't expose them): **Shift** locks the drag-start
/// aspect ratio; **Cmd** pivots around the rect's center instead of the
/// opposite corner; both together combine.
///
/// Drags read from a named coordinate space, not `.local`/`.translation` —
/// the dragged view repositions mid-gesture, corrupting delta math against
/// a space that moves with it (same bug class as the trim scrubber and the
/// resizable split divider).
struct CropOverlayView: View {
    var viewModel: ConversionViewModel

    @State private var createDragStart: CGPoint?
    @State private var moveDragStartRect: CGRect?
    @State private var moveDragStartLocation: CGPoint?
    @State private var resizeDragStartViewRect: CGRect?

    private static let coordinateSpaceName = "cropOverlay"
    private static let handleSize: CGFloat = 10
    private static let handleHitSize: CGFloat = 20

    enum Corner: CaseIterable, Equatable {
        case topLeft, topRight, bottomLeft, bottomRight

        var opposite: Corner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }

        var identifierSuffix: String {
            switch self {
            case .topLeft: return "topLeft"
            case .topRight: return "topRight"
            case .bottomLeft: return "bottomLeft"
            case .bottomRight: return "bottomRight"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let sourceSize = viewModel.mediaFile?.resolution ?? geometry.size
            let contentRect = Self.letterboxedContentRect(containerSize: geometry.size, sourceSize: sourceSize)

            Group {
                if let cropRect = viewModel.crop {
                    let viewRect = Self.viewRect(forSourceRect: cropRect, sourceSize: sourceSize, contentRect: contentRect)
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.yellow, lineWidth: 2)
                            .background(Color.yellow.opacity(0.001)) // hit-testable for the move gesture
                            .frame(width: max(viewRect.width, 1), height: max(viewRect.height, 1))
                            .position(x: viewRect.midX, y: viewRect.midY)
                            .gesture(moveGesture(cropRect: cropRect, sourceSize: sourceSize, contentRect: contentRect))
                            .accessibilityIdentifier("cropOverlay.rect")

                        ForEach(Corner.allCases, id: \.self) { corner in
                            Circle()
                                .fill(Color.yellow)
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                                .frame(width: Self.handleSize, height: Self.handleSize)
                                .frame(width: Self.handleHitSize, height: Self.handleHitSize)
                                .contentShape(Circle())
                                .position(Self.point(for: corner, in: viewRect))
                                // highPriorityGesture: a handle sits at the
                                // edge of the rect's own move-gesture area,
                                // and plain sibling .gesture() ordering
                                // doesn't reliably let it win a contested touch.
                                .highPriorityGesture(resizeGesture(corner: corner, sourceSize: sourceSize, contentRect: contentRect))
                                .accessibilityIdentifier("cropOverlay.handle.\(corner.identifierSuffix)")
                        }
                    }
                    // Without an explicit frame, the ZStack (only unconstrained
                    // child is Color.clear) collapses toward zero size —
                    // .position()-ed children still paint but stop receiving
                    // mouse events outside the collapsed hit-test bounds.
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                } else if !viewModel.isCropDisabled {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .gesture(createGesture(sourceSize: sourceSize, contentRect: contentRect))
                        .accessibilityIdentifier("cropOverlay.drawArea")
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("cropOverlay.drawArea")
                }
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
        }
    }

    private func createGesture(sourceSize: CGSize, contentRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if createDragStart == nil { createDragStart = value.startLocation }
                guard let start = createDragStart else { return }
                let rectInView = CGRect(
                    x: min(start.x, value.location.x),
                    y: min(start.y, value.location.y),
                    width: abs(value.location.x - start.x),
                    height: abs(value.location.y - start.y)
                )
                viewModel.crop = Self.sourceRect(forViewRect: rectInView, sourceSize: sourceSize, contentRect: contentRect)
            }
            .onEnded { _ in createDragStart = nil }
    }

    private func moveGesture(cropRect: CGRect, sourceSize: CGSize, contentRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if moveDragStartRect == nil {
                    moveDragStartRect = cropRect
                    moveDragStartLocation = value.location
                }
                guard let start = moveDragStartRect, let startLocation = moveDragStartLocation,
                      contentRect.width > 0, contentRect.height > 0 else { return }
                let scaleX = sourceSize.width / contentRect.width
                let scaleY = sourceSize.height / contentRect.height
                var moved = start
                moved.origin.x = start.origin.x + (value.location.x - startLocation.x) * scaleX
                moved.origin.y = start.origin.y + (value.location.y - startLocation.y) * scaleY
                viewModel.crop = Self.clamped(moved, within: sourceSize)
            }
            .onEnded { _ in
                moveDragStartRect = nil
                moveDragStartLocation = nil
            }
    }

    private func resizeGesture(corner: Corner, sourceSize: CGSize, contentRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if resizeDragStartViewRect == nil {
                    guard let cropRect = viewModel.crop else { return }
                    resizeDragStartViewRect = Self.viewRect(forSourceRect: cropRect, sourceSize: sourceSize, contentRect: contentRect)
                }
                guard let startViewRect = resizeDragStartViewRect else { return }
                let modifiers = NSEvent.modifierFlags
                let draggedPoint = value.location
                let aspect: CGFloat? = (modifiers.contains(.shift) && startViewRect.width > 0 && startViewRect.height > 0)
                    ? startViewRect.width / startViewRect.height
                    : nil

                let newViewRect: CGRect
                if modifiers.contains(.command) {
                    // Cmd: resize symmetrically around the rect's own
                    // center, captured at drag start, rather than anchoring
                    // the opposite corner.
                    let center = CGPoint(x: startViewRect.midX, y: startViewRect.midY)
                    newViewRect = Self.centerPivotRect(center: center, draggedPoint: draggedPoint, aspect: aspect)
                } else {
                    // Opposite corner stays anchored at its drag-start
                    // position; the dragged corner tracks the pointer.
                    let fixedPoint = Self.point(for: corner.opposite, in: startViewRect)
                    if let aspect {
                        newViewRect = Self.aspectLockedRect(fixedPoint: fixedPoint, draggedPoint: draggedPoint, aspect: aspect)
                    } else {
                        // Using min/max (rather than assuming drag
                        // direction) lets a corner be dragged past its
                        // opposite without the rect inverting.
                        newViewRect = CGRect(
                            x: min(fixedPoint.x, draggedPoint.x),
                            y: min(fixedPoint.y, draggedPoint.y),
                            width: abs(draggedPoint.x - fixedPoint.x),
                            height: abs(draggedPoint.y - fixedPoint.y)
                        )
                    }
                }
                viewModel.crop = Self.sourceRect(forViewRect: newViewRect, sourceSize: sourceSize, contentRect: contentRect)
            }
            .onEnded { _ in resizeDragStartViewRect = nil }
    }

    /// The largest size that (a) matches `aspect`, if given, and (b) stays
    /// within `rawWidth`/`rawHeight` — the standard "contain" fit, shared by
    /// both the corner-anchored and center-pivot resize paths.
    static func constrainedSize(rawWidth: CGFloat, rawHeight: CGFloat, aspect: CGFloat?) -> CGSize {
        guard let aspect else { return CGSize(width: rawWidth, height: rawHeight) }
        if rawHeight > 0, rawWidth / aspect <= rawHeight {
            return CGSize(width: rawWidth, height: rawWidth / aspect)
        } else {
            return CGSize(width: rawHeight * aspect, height: rawHeight)
        }
    }

    /// Resizes from `fixedPoint` (the corner opposite the one being
    /// dragged), which stays put while the dragged corner tracks the
    /// pointer.
    static func aspectLockedRect(fixedPoint: CGPoint, draggedPoint: CGPoint, aspect: CGFloat) -> CGRect {
        let rawWidth = abs(draggedPoint.x - fixedPoint.x)
        let rawHeight = abs(draggedPoint.y - fixedPoint.y)
        let size = constrainedSize(rawWidth: rawWidth, rawHeight: rawHeight, aspect: aspect)
        let x = draggedPoint.x >= fixedPoint.x ? fixedPoint.x : fixedPoint.x - size.width
        let y = draggedPoint.y >= fixedPoint.y ? fixedPoint.y : fixedPoint.y - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Resizes symmetrically around `center`, which stays fixed while the
    /// dragged corner tracks the pointer — each axis grows/shrinks on both
    /// sides at once, so the rect expands at roughly twice the rate of the
    /// corner-anchored resize for the same pointer movement.
    static func centerPivotRect(center: CGPoint, draggedPoint: CGPoint, aspect: CGFloat?) -> CGRect {
        let rawHalfWidth = abs(draggedPoint.x - center.x)
        let rawHalfHeight = abs(draggedPoint.y - center.y)
        let halfSize = constrainedSize(rawWidth: rawHalfWidth, rawHeight: rawHalfHeight, aspect: aspect)
        return CGRect(
            x: center.x - halfSize.width, y: center.y - halfSize.height,
            width: halfSize.width * 2, height: halfSize.height * 2
        )
    }

    static func point(for corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Where the (possibly non-16:9) source frame actually lands within the
    /// container, matching `.aspectRatio(contentMode: .fit)`'s own letterboxing.
    static func letterboxedContentRect(containerSize: CGSize, sourceSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let containerAspect = containerSize.width / containerSize.height
        let sourceAspect = sourceSize.width / sourceSize.height
        if sourceAspect > containerAspect {
            let width = containerSize.width
            let height = width / sourceAspect
            return CGRect(x: 0, y: (containerSize.height - height) / 2, width: width, height: height)
        } else {
            let height = containerSize.height
            let width = height * sourceAspect
            return CGRect(x: (containerSize.width - width) / 2, y: 0, width: width, height: height)
        }
    }

    static func viewRect(forSourceRect sourceRect: CGRect, sourceSize: CGSize, contentRect: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return contentRect }
        let scaleX = contentRect.width / sourceSize.width
        let scaleY = contentRect.height / sourceSize.height
        return CGRect(
            x: contentRect.minX + sourceRect.minX * scaleX,
            y: contentRect.minY + sourceRect.minY * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        )
    }

    static func sourceRect(forViewRect viewRect: CGRect, sourceSize: CGSize, contentRect: CGRect) -> CGRect {
        guard contentRect.width > 0, contentRect.height > 0 else { return CGRect(origin: .zero, size: sourceSize) }
        let scaleX = sourceSize.width / contentRect.width
        let scaleY = sourceSize.height / contentRect.height
        let rect = CGRect(
            x: (viewRect.minX - contentRect.minX) * scaleX,
            y: (viewRect.minY - contentRect.minY) * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY
        )
        return clamped(rect, within: sourceSize)
    }

    /// Internal rather than `private` — `CropPresetsView`'s orientation
    /// toggle reuses this to keep a swapped rect on-source after rotating.
    static func clamped(_ rect: CGRect, within sourceSize: CGSize) -> CGRect {
        var result = rect
        result.size.width = min(result.width, sourceSize.width)
        result.size.height = min(result.height, sourceSize.height)
        result.origin.x = min(max(result.origin.x, 0), max(sourceSize.width - result.width, 0))
        result.origin.y = min(max(result.origin.y, 0), max(sourceSize.height - result.height, 0))
        return result
    }
}
