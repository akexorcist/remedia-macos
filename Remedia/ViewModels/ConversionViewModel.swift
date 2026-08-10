import Foundation
import CoreGraphics
import CoreImage
import Observation
import AppKit
import UniformTypeIdentifiers
import RemediaCore

@Observable
@MainActor
final class ConversionViewModel {
    enum Phase: Equatable {
        case idle
        case invalidFile(message: String)
        case ready
        case converting(progress: Double)
        case failed(message: String)
        case completed(outputURL: URL)
    }

    private(set) var phase: Phase = .idle
    private(set) var mediaFile: MediaFile?
    var targetFormat: OutputFormat?
    var videoSettings: VideoSettings?
    var gifSettings: GifSettings?

    /// Rendered by whichever `PreviewSource` `EngineRouter` picks for the
    /// dropped file's format (ARCHITECTURE §3/§5) — mov/mp4 via `AVPlayer`,
    /// gif/webm via the FFmpeg decode bridge. The view layer only ever sees
    /// a `CGImage`, never which source produced it.
    private(set) var previewImage: CGImage?
    /// Probed metadata for the just-converted output, letting the completed
    /// screen play it back before the user chooses to save it.
    private(set) var resultMediaFile: MediaFile?

    private var previewSource: PreviewSource?
    private var activeJob: ConversionJob?
    private static let previewContext = CIContext()

    /// Mirrors every write into both settings structs, so trim/crop stay
    /// shared across format switches rather than reset (REQUIREMENTS §5).
    var trim: TrimRange {
        get {
            videoSettings?.trim ?? gifSettings?.trim ?? .full(duration: 0)
        }
        set {
            videoSettings?.trim = newValue
            gifSettings?.trim = newValue
        }
    }

    var crop: CGRect? {
        get {
            videoSettings?.crop ?? gifSettings?.crop
        }
        set {
            videoSettings?.crop = newValue
            gifSettings?.crop = newValue
        }
    }

    /// Distinguishes "Original" from "Free" in `CropPresetsView` — both
    /// leave `crop == nil`, so that alone can't tell them apart. Not
    /// mirrored per-format like `crop`/`trim` since it isn't a conversion
    /// parameter; persists on the view model itself.
    var isCropDisabled: Bool = true

    /// Which `CropPresetsView` segment is selected — see that view for why
    /// this is tracked explicitly rather than derived from `crop`'s ratio.
    var selectedCropShape: String = "Free"

    /// REQUIREMENTS §4: unsupported/invalid dropped file is rejected immediately,
    /// before ever reaching format selection. Also covers files that probing
    /// can't read (corrupt/unreadable data).
    func handleDrop(url: URL) async {
        guard let format = OutputFormat(fileExtension: url.pathExtension) else {
            phase = .invalidFile(
                message: "\"\(url.lastPathComponent)\" isn't a supported format (.mov, .mp4, .gif, .webm)."
            )
            return
        }

        do {
            let probed = try await MediaFileProber.probe(url: url)
            mediaFile = probed
            targetFormat = format
            videoSettings = VideoSettings(trim: .full(duration: probed.duration))
            gifSettings = GifSettings(trim: .full(duration: probed.duration))
            isCropDisabled = true
            selectedCropShape = "Free"
            previewSource = EngineRouter.previewSource(for: probed)
            phase = .ready
            await updatePreview(at: 0)
        } catch {
            phase = .invalidFile(
                message: "Couldn't read \"\(url.lastPathComponent)\": \(Self.message(for: error))"
            )
        }
    }

    /// Called as the trim handles move (REQUIREMENTS §5) so the preview
    /// reflects whichever edge the user is currently dragging. Failures are
    /// swallowed deliberately — a preview hiccup shouldn't block editing or
    /// surface as a conversion-style error; the last successfully rendered
    /// frame just stays on screen.
    func updatePreview(at time: TimeInterval) async {
        guard let previewSource else { return }
        guard let frame = try? await previewSource.frame(at: time) else { return }
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        previewImage = Self.previewContext.createCGImage(ciImage, from: ciImage.extent)
    }

    func startConversion() {
        guard let mediaFile, let targetFormat else { return }

        let settings: ConversionSettings = targetFormat == .gif
            ? .gif(gifSettings ?? GifSettings(trim: .full(duration: mediaFile.duration)))
            : .video(videoSettings ?? VideoSettings(trim: .full(duration: mediaFile.duration)))

        // Converts to a scratch location first — the completed screen shows
        // a preview of it, and downloading (a separate, explicit step) is
        // what actually asks where to save.
        let workingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(targetFormat.fileExtension)

        let engine = EngineRouter.engine(source: mediaFile.format, target: targetFormat)
        let job = engine.convert(mediaFile, to: targetFormat, settings: settings, outputURL: workingURL)

        activeJob = job
        phase = .converting(progress: 0)

        Task {
            for await value in await job.progress {
                phase = .converting(progress: value)
            }
            switch await job.state {
            case .completed(let tempURL):
                await showCompletedResult(tempURL: tempURL)
            case .failed(let error):
                phase = .failed(message: Self.message(for: error))
            case .cancelled:
                phase = .ready
            case .running:
                break
            }
        }
    }

    private func showCompletedResult(tempURL: URL) async {
        phase = .completed(outputURL: tempURL)
        resultMediaFile = try? await MediaFileProber.probe(url: tempURL)
    }

    /// Presents a save panel defaulting to the same folder/name convention
    /// the app used to auto-save to, but now editable. Copies (rather than
    /// moves) the scratch file so the result stays playable/saveable again
    /// afterward.
    func saveResult() async {
        guard case .completed(let tempURL) = phase, let mediaFile, let targetFormat else { return }
        let suggestedURL = OutputPathResolver.resolvedOutputURL(forSource: mediaFile.url, target: targetFormat)

        guard let destinationURL = await Self.presentSavePanel(
            directoryURL: suggestedURL.deletingLastPathComponent(),
            suggestedName: suggestedURL.lastPathComponent,
            contentType: UTType(filenameExtension: tempURL.pathExtension)
        ) else { return }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destinationURL)
        } catch {
            phase = .failed(message: Self.message(for: error))
        }
    }

    private static func presentSavePanel(directoryURL: URL, suggestedName: String, contentType: UTType?) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.directoryURL = directoryURL
            panel.nameFieldStringValue = suggestedName
            if let contentType {
                panel.allowedContentTypes = [contentType]
            }
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Discards the scratch output and returns to the editor with the same
    /// source file and settings still loaded.
    func backToEditor() {
        if case .completed(let tempURL) = phase {
            try? FileManager.default.removeItem(at: tempURL)
        }
        resultMediaFile = nil
        phase = .ready
    }

    func cancelConversion() {
        guard let activeJob else { return }
        Task { await activeJob.cancel() }
    }

    /// Used by the quit-confirmation flow (AppDelegate), which needs to
    /// know cancellation's partial-file cleanup has actually finished
    /// before really terminating — unlike `cancelConversion()`, which is
    /// fire-and-forget for the in-window Cancel button.
    func cancelConversionAwaitingCompletion() async {
        guard let activeJob else { return }
        await activeJob.cancel()
    }

    /// REQUIREMENTS §8: conversion failure surfaces as an inline error state
    /// in the same window, dismissible back to the settings/ready state.
    func dismissError() {
        phase = mediaFile == nil ? .idle : .ready
    }

    func reset() {
        if case .completed(let tempURL) = phase {
            try? FileManager.default.removeItem(at: tempURL)
        }
        mediaFile = nil
        targetFormat = nil
        videoSettings = nil
        gifSettings = nil
        previewSource = nil
        previewImage = nil
        resultMediaFile = nil
        activeJob = nil
        phase = .idle
    }

    private static func message(for error: Error) -> String {
        if let notImplemented = error as? NotImplementedError {
            return "Not implemented yet: \(notImplemented.feature)"
        }
        return "\(error)"
    }
}
