import SwiftUI
import RemediaCore

/// Advanced settings for GIF output (REQUIREMENTS §7).
struct GifSettingsView: View {
    var viewModel: ConversionViewModel

    private static let scalePresets: [ResolutionOverride] = [
        .original, .scale(0.75), .scale(0.5), .scale(0.25)
    ]
    private static let fpsPresets: [FrameRateOverride] = [
        .original, .fps(24), .fps(15), .fps(12), .fps(10)
    ]
    private static let labelWidth: CGFloat = 130
    private static let qualityValueWidth: CGFloat = 36
    private static let sectionSpacing: CGFloat = 8

    var body: some View {
        Form {
            if let settings = viewModel.gifSettings {
                Section {
                    Slider(
                        value: Binding(
                            get: { settings.quality },
                            set: { viewModel.gifSettings?.quality = $0 }
                        ),
                        in: 50...100,
                        step: 5
                    ) {
                        HStack(spacing: 4) {
                            Text("Quality:")
                            Text("\(Int(settings.quality))%")
                                .frame(width: Self.qualityValueWidth, alignment: .trailing)
                        }
                        .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
                .padding(.bottom, Self.sectionSpacing)

                Section {
                    Picker(selection: Binding(
                        get: { settings.scale },
                        set: { viewModel.gifSettings?.scale = $0 }
                    )) {
                        ForEach(Self.scalePresets, id: \.self) { preset in
                            Text(label(for: preset)).tag(preset)
                        }
                    } label: {
                        Text("Resolution")
                            .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
                .padding(.bottom, Self.sectionSpacing)

                Section {
                    Picker(selection: Binding(
                        get: { settings.fps },
                        set: { viewModel.gifSettings?.fps = $0 }
                    )) {
                        ForEach(Self.fpsPresets, id: \.self) { preset in
                            Text(label(for: preset)).tag(preset)
                        }
                    } label: {
                        Text("Frame Rate")
                            .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
                .padding(.bottom, Self.sectionSpacing)

                Section {
                    Picker(selection: Binding(
                        get: { settings.paletteSize },
                        set: { viewModel.gifSettings?.paletteSize = $0 }
                    )) {
                        Text("Auto").tag(PaletteSize.auto)
                        Text("256").tag(PaletteSize.colors(256))
                        Text("128").tag(PaletteSize.colors(128))
                        Text("64").tag(PaletteSize.colors(64))
                    } label: {
                        Text("Colors")
                            .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
                .padding(.bottom, Self.sectionSpacing)

                Section {
                    Picker(selection: Binding(
                        get: { settings.dither },
                        set: { viewModel.gifSettings?.dither = $0 }
                    )) {
                        Text("Auto").tag(DitherMethod.auto)
                        Text("None").tag(DitherMethod.none)
                        Text("Bayer").tag(DitherMethod.bayer)
                        Text("Floyd–Steinberg").tag(DitherMethod.floydSteinberg)
                    } label: {
                        Text("Dither")
                            .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
                .padding(.bottom, Self.sectionSpacing)

                Section {
                    Picker(selection: Binding(
                        get: { settings.loop },
                        set: { viewModel.gifSettings?.loop = $0 }
                    )) {
                        Text("Forever").tag(LoopBehavior.forever)
                        Text("Once").tag(LoopBehavior.once)
                        Text("3 Times").tag(LoopBehavior.times(3))
                    } label: {
                        Text("Loop")
                            .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Uses the crop area's size once active, matching `OutputSizeResolver`'s
    /// own base for "Original"/scale-factor sizing.
    private func label(for resolution: ResolutionOverride) -> String {
        guard let sourceSize = viewModel.crop?.size ?? viewModel.mediaFile?.resolution else {
            switch resolution {
            case .original: return "Original"
            case .scale(let factor): return "\(factor.formatted())x"
            case .customWidth(let width): return "\(width)px wide"
            }
        }
        switch resolution {
        case .original:
            return "Original (\(Int(sourceSize.width))x\(Int(sourceSize.height)))"
        case .scale(let factor):
            let width = Int(sourceSize.width * factor)
            let height = Int(sourceSize.height * factor)
            return "\(factor.formatted())x (\(width)x\(height))"
        case .customWidth(let width):
            let height = sourceSize.width > 0 ? Int(CGFloat(width) * sourceSize.height / sourceSize.width) : width
            return "\(width)px wide (\(width)x\(height))"
        }
    }

    private func label(for frameRate: FrameRateOverride) -> String {
        switch frameRate {
        case .original:
            guard let sourceRate = viewModel.mediaFile?.frameRate else { return "Original" }
            return "Original (\(Self.formatted(sourceRate)))"
        case .fps(let value):
            return "\(Int(value))"
        }
    }

    /// Rounds to 2 decimal places rather than truncating to `Int` — sources
    /// shot at NTSC rates (e.g. 59.94, 23.976) would otherwise silently
    /// display as 59/23, which doesn't match what's actually being played.
    private static func formatted(_ frameRate: Double) -> String {
        frameRate.formatted(.number.precision(.fractionLength(0...2)))
    }
}
