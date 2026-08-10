import SwiftUI
import UniformTypeIdentifiers
import AppKit
import RemediaCore

struct DropZoneView: View {
    var viewModel: ConversionViewModel
    @State private var isTargeted = false

    private static let allowedContentTypes: [UTType] = ["mov", "mp4", "gif", "webm"].compactMap {
        UTType(filenameExtension: $0)
    }

    /// This view reappears every time a Start Over/Reset returns to the drop
    /// zone, and its `.task` would otherwise re-autoload the same fixture on
    /// each reappearance — masking the drop-zone screen from a UI test
    /// that's specifically checking it's reached. One-shot per process is
    /// enough: every UI test that uses this hook only needs it once.
    private static var hasAutoloadedForUITests = false

    private var errorMessage: String? {
        if case .invalidFile(let message) = viewModel.phase {
            return message
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Text("Drop a .mov, .mp4, .gif, or .webm file")
                .foregroundStyle(.secondary)
            Text("or click to browse")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture { presentOpenPanel() }
        .accessibilityIdentifier("dropZone.tapArea")
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await viewModel.handleDrop(url: url)
                }
            }
            return true
        }
        // UI tests can't synthesize a real Finder drag; this lets them reach
        // the editor screen by launching with the fixture path in this
        // environment variable instead. No-op unless a UI test sets it.
        .task {
            guard !Self.hasAutoloadedForUITests else { return }
            if let uiTestFile = ProcessInfo.processInfo.environment["UI_TEST_AUTOLOAD_MEDIA_PATH"] {
                Self.hasAutoloadedForUITests = true
                await viewModel.handleDrop(url: URL(fileURLWithPath: uiTestFile))
            }
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await viewModel.handleDrop(url: url)
            }
        }
    }
}
