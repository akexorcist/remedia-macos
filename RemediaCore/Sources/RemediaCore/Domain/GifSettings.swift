import Foundation
import CoreGraphics

/// Advanced settings for GIF output (REQUIREMENTS §7).
public struct GifSettings: Sendable, Equatable {
    public var fps: FrameRateOverride
    public var scale: ResolutionOverride
    public var trim: TrimRange
    /// Defined in the source's original, uncropped resolution (ARCHITECTURE §6).
    /// `nil` means no crop.
    public var crop: CGRect?
    /// 50...100 in the UI (5% steps, matching video's quality control).
    /// Drives `paletteSize`/`dither` when those are left at `.auto`;
    /// explicit overrides always take precedence. Not clamped here, so
    /// engine/test code can exercise values outside the UI's range.
    public var quality: Double
    public var paletteSize: PaletteSize
    public var dither: DitherMethod
    public var loop: LoopBehavior

    public init(
        fps: FrameRateOverride = .original,
        scale: ResolutionOverride = .original,
        trim: TrimRange,
        crop: CGRect? = nil,
        quality: Double = 85,
        paletteSize: PaletteSize = .auto,
        dither: DitherMethod = .auto,
        loop: LoopBehavior = .forever
    ) {
        self.fps = fps
        self.scale = scale
        self.trim = trim
        self.crop = crop
        self.quality = quality
        self.paletteSize = paletteSize
        self.dither = dither
        self.loop = loop
    }
}
