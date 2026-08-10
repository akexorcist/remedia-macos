import CoreGraphics

/// Shared by both engines so a resolution override means exactly the same
/// thing regardless of which one handles the conversion (ARCHITECTURE §6).
public enum OutputSizeResolver {
    public static func resolvedOutputSize(cropSize: CGSize, resolution: ResolutionOverride) -> CGSize {
        // Encoders (H.264, VP9) generally require even dimensions.
        func evenSize(_ size: CGSize) -> CGSize {
            CGSize(width: max(2, floor(size.width / 2) * 2), height: max(2, floor(size.height / 2) * 2))
        }
        switch resolution {
        case .original:
            return evenSize(cropSize)
        case .scale(let factor):
            return evenSize(CGSize(width: cropSize.width * factor, height: cropSize.height * factor))
        case .customWidth(let width):
            let safeWidth = max(cropSize.width, 1)
            let aspect = cropSize.height / safeWidth
            return evenSize(CGSize(width: CGFloat(width), height: CGFloat(width) * aspect))
        }
    }
}
