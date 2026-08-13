import SwiftUI
import RemediaCore

struct ContentView: View {
    var viewModel: ConversionViewModel
    @State private var previewPaneHeight: CGFloat = ContentView.rememberedPreviewPaneHeight()

    private static let previewPaneHeightKey = "previewPaneHeight"

    /// Mirrors `WindowSizeManager`'s own remembered-size pattern, just for
    /// the preview/output-config split instead of the window frame.
    private static func rememberedPreviewPaneHeight() -> CGFloat {
        // UI tests should start from the same known height every run —
        // otherwise a previous test's drag persists via UserDefaults and
        // can leave the next one with no headroom left to drag by its own
        // fixed amount, drifting a "round trip" test's math for reasons
        // that have nothing to do with what it's actually testing.
        if ProcessInfo.processInfo.environment["UI_TEST_AUTOLOAD_MEDIA_PATH"] != nil {
            return 320
        }
        let stored = UserDefaults.standard.double(forKey: previewPaneHeightKey)
        return stored > 0 ? CGFloat(stored) : 320
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle, .invalidFile:
                DropZoneView(viewModel: viewModel)
                    .padding()
                    .transition(.scale)

            case .ready:
                readyView
                    .frame(minWidth: WindowSizeManager.editorMinSize.width, minHeight: WindowSizeManager.editorMinSize.height)
                    .transition(.scale)

            case .converting, .failed:
                ConversionProgressView(viewModel: viewModel)
                    .padding()
                    .frame(minWidth: WindowSizeManager.editorMinSize.width, minHeight: WindowSizeManager.editorMinSize.height)
                    .transition(.scale)

            case .completed(let outputURL):
                completedView(outputURL: outputURL)
                    .padding()
                    .frame(minWidth: WindowSizeManager.editorMinSize.width, minHeight: WindowSizeManager.editorMinSize.height)
                    .transition(.scale)
            }
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.phase)
        .background(WindowAccessor())
        .onAppear { updateWindowSize(for: viewModel.phase) }
        .onChange(of: viewModel.phase) { _, newPhase in
            updateWindowSize(for: newPhase)
        }
        .onChange(of: previewPaneHeight) { _, newValue in
            UserDefaults.standard.set(Double(newValue), forKey: Self.previewPaneHeightKey)
        }
    }

    private func updateWindowSize(for phase: ConversionViewModel.Phase) {
        switch phase {
        case .idle, .invalidFile:
            WindowSizeManager.shared.enterDropZone()
        case .ready, .converting, .failed, .completed:
            WindowSizeManager.shared.enterEditor()
        }
    }

    /// Floor for the output-config pane when the user drags the split
    /// divider to grow the preview/timeframe pane above it — small enough to
    /// always show at least the first setting, relying on the pane's own
    /// `ScrollView` for the rest.
    private static let outputConfigMinHeight: CGFloat = 160
    /// Floor for the preview/timeframe pane so it can't be dragged down to
    /// nothing either.
    private static let previewMinHeight: CGFloat = 200
    private static let outputConfigTopID = "outputConfigTop"

    private var readyView: some View {
        VStack(spacing: 0) {
            ResizableVSplit(
                topHeight: $previewPaneHeight,
                topMinHeight: Self.previewMinHeight,
                bottomMinHeight: Self.outputConfigMinHeight
            ) {
                PreviewPlayerView(viewModel: viewModel)
                    .padding(.horizontal)
            } bottom: {
                // `.defaultScrollAnchor(.top)` alone isn't reliable since
                // this view is inserted mid `.transition(.scale)` — scrolling
                // explicitly in `.onAppear` is deterministic instead.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            CropPresetsView(viewModel: viewModel)

                            FormatPickerView(viewModel: viewModel)

                            if viewModel.targetFormat == .gif {
                                GifSettingsView(viewModel: viewModel)
                            } else {
                                VideoSettingsView(viewModel: viewModel)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .id(Self.outputConfigTopID)
                    }
                    .onAppear {
                        proxy.scrollTo(Self.outputConfigTopID, anchor: .top)
                    }
                }
            }

            // No top spacing — sits flush against the scrollable pane's own
            // bottom edge instead of stealing height from it.
            Divider()

            HStack {
                Spacer()
                Button("Back") {
                    viewModel.reset()
                }
                Button("Convert") {
                    viewModel.startConversion()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private static let resultInfoLabelSpacing: CGFloat = 8
    private static let completedVStackSpacing: CGFloat = 16
    // `.aspectRatio(contentMode: .fit)` relies on SwiftUI's flexible-sizing
    // negotiation to shrink a view within a VStack, which twice over proved
    // unreliable here — `ResultPlayerView`'s NSViewRepresentable-backed
    // players (AVPlayerLayer, etc.) don't cooperate with it and end up
    // claiming the VStack's entire height, pushing the label/button rows
    // out of view instead of yielding to them. So the image's size is
    // computed explicitly instead, via the same letterboxing math the crop
    // overlay already uses, against whatever height is left after generously
    // reserving room for those two rows — no negotiation, no ambiguity.
    private static let completedLabelRowReservedHeight: CGFloat = 28
    private static let completedButtonRowReservedHeight: CGFloat = 40

    private func completedView(outputURL: URL) -> some View {
        GeometryReader { geometry in
            let reservedHeight = Self.completedLabelRowReservedHeight + Self.completedButtonRowReservedHeight
                + Self.completedVStackSpacing + Self.resultInfoLabelSpacing
            let availableImageSize = CGSize(
                width: geometry.size.width,
                height: max(geometry.size.height - reservedHeight, 40)
            )
            let aspectRatio = Self.resultAspectRatio(for: viewModel.resultMediaFile)
            let fittedSize = CropOverlayView.letterboxedContentRect(
                containerSize: availableImageSize,
                sourceSize: CGSize(width: aspectRatio, height: 1)
            ).size

            VStack(spacing: Self.completedVStackSpacing) {
                VStack(spacing: Self.resultInfoLabelSpacing) {
                    resultInfoLabel(outputURL: outputURL)

                    // Reflects the actual exported file's dimensions
                    // (post-crop), rather than a fixed 16:9 — a non-16:9 crop
                    // (e.g. 1:1, 4:3) was correctly exported but shown
                    // letterboxed/pillarboxed to the wrong shape otherwise.
                    ResultPlayerView(url: outputURL, mediaFile: viewModel.resultMediaFile)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                }
                .frame(maxWidth: .infinity)

                HStack {
                    Spacer()
                    Button("Back") {
                        viewModel.backToEditor()
                    }
                    Button("Start Over") {
                        viewModel.reset()
                    }
                    Button("Save") {
                        Task { await viewModel.saveResult() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultInfoLabel(outputURL: URL) -> some View {
        HStack {
            if let duration = viewModel.resultMediaFile?.duration {
                (Text("Duration: ").bold() + Text(Self.formattedDuration(duration)))
                    .accessibilityIdentifier("completedScreen.duration")
            }
            Spacer()
            if let fileSize = Self.fileSize(at: outputURL) {
                (Text("File size: ").bold() + Text(fileSize))
                    .accessibilityIdentifier("completedScreen.fileSize")
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
    }

    private static func resultAspectRatio(for mediaFile: MediaFile?) -> CGFloat {
        guard let resolution = mediaFile?.resolution, resolution.width > 0, resolution.height > 0 else {
            return 16.0 / 9.0
        }
        return resolution.width / resolution.height
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func fileSize(at url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

#Preview {
    ContentView(viewModel: ConversionViewModel())
}
