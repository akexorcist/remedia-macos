import SwiftUI
import RemediaCore

/// Advanced settings for mp4/mov/webm output (REQUIREMENTS §6).
struct VideoSettingsView: View {
    var viewModel: ConversionViewModel

    private static let resolutionPresets: [ResolutionOverride] = [
        .original, .scale(0.75), .scale(0.5), .scale(0.25)
    ]
    private static let frameRatePresets: [FrameRateOverride] = [
        .original, .fps(60), .fps(30), .fps(24)
    ]
    private static let audioCodecs: [AudioCodec] = [.aac, .alac, .pcm, .opus, .vorbis]
    private static let labelWidth: CGFloat = 130
    private static let qualityValueWidth: CGFloat = 36
    private static let sectionSpacing: CGFloat = 8

    var body: some View {
        Form {
            if let settings = viewModel.videoSettings {
                Section {
                    Slider(
                        value: Binding(
                            get: { settings.quality },
                            set: { viewModel.videoSettings?.quality = $0 }
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
                        get: { settings.resolution },
                        set: { viewModel.videoSettings?.resolution = $0 }
                    )) {
                        ForEach(Self.resolutionPresets, id: \.self) { preset in
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
                        get: { settings.frameRate },
                        set: { viewModel.videoSettings?.frameRate = $0 }
                    )) {
                        ForEach(Self.frameRatePresets, id: \.self) { preset in
                            Text(label(for: preset)).tag(preset)
                        }
                    } label: {
                        Text("Frame Rate")
                            .frame(width: Self.labelWidth, alignment: .trailing)
                    }
                }
                .padding(.bottom, Self.sectionSpacing)

                if viewModel.targetFormat == .mp4 || viewModel.targetFormat == .mov {
                    Section {
                        Picker(selection: Binding(
                            get: { settings.videoCodec },
                            set: { viewModel.videoSettings?.videoCodec = $0 }
                        )) {
                            Text("Auto Codec").tag(VideoCodec.auto)
                            Text("H.264").tag(VideoCodec.h264)
                            Text("HEVC").tag(VideoCodec.hevc)
                        } label: {
                            Text("Video")
                                .frame(width: Self.labelWidth, alignment: .trailing)
                        }
                    }
                    .padding(.bottom, Self.sectionSpacing)
                }

                Section {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { settings.audio != .stripped },
                                set: { viewModel.videoSettings?.audio = $0 ? .auto : .stripped }
                            ))
                            .labelsHidden()
                            Picker("", selection: Binding<AudioCodec?>(
                                get: {
                                    if case .custom(let codec, _) = settings.audio { return codec }
                                    return nil
                                },
                                set: { newCodec in
                                    guard let newCodec else {
                                        viewModel.videoSettings?.audio = .auto
                                        return
                                    }
                                    let bitrate: Int
                                    if case .custom(_, let existing) = settings.audio {
                                        bitrate = existing
                                    } else {
                                        bitrate = 128
                                    }
                                    viewModel.videoSettings?.audio = .custom(codec: newCodec, bitrateKbps: bitrate)
                                }
                            )) {
                                Text("Auto Codec").tag(AudioCodec?.none)
                                ForEach(Self.audioCodecs, id: \.self) { codec in
                                    Text(codec.rawValue.uppercased()).tag(AudioCodec?.some(codec))
                                }
                            }
                            .labelsHidden()
                            .disabled(settings.audio == .stripped)
                            .fixedSize()
                        }
                    } label: {
                        Text("Audio")
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
            return "Original (\(Int(sourceRate)))"
        case .fps(let value):
            return "\(Int(value))"
        }
    }
}
