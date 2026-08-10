import Foundation
import AVFoundation
import CoreImage
import CoreMedia

public enum ConversionError: Error, Sendable {
    case unsupportedSettings
    case noVideoTrack
    case readerSetupFailed
    case writerSetupFailed
}

/// Logs only the first frame in `makeVideoComposition`'s per-frame handler,
/// which may run concurrently — locked so two frames can't both see `false`.
private final class LogOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let alreadyFired = hasFired
        hasFired = true
        return alreadyFired
    }
}

/// Native mov/mp4 path (ARCHITECTURE §3/§6) — `AVAssetReader`/`AVAssetWriter`
/// rather than `AVAssetExportSession` (§7 decision), since the quality
/// slider needs `AVAssetWriterInput.outputSettings`, which export presets
/// can't express. `EngineRouter` never routes gif/webm here.
public struct AVFoundationEngine: ConversionEngine {
    public init() {}

    public func convert(
        _ source: MediaFile,
        to target: OutputFormat,
        settings: ConversionSettings,
        outputURL: URL
    ) -> ConversionJob {
        let job = ConversionJob()
        Task {
            await job.trackPartialOutput(outputURL)
            do {
                guard case .video(let videoSettings) = settings else {
                    throw ConversionError.unsupportedSettings
                }
                try await Self.run(
                    source: source,
                    target: target,
                    settings: videoSettings,
                    outputURL: outputURL,
                    job: job
                )
                if await job.isCancelledSync {
                    // cancel() can race AVAssetWriter's own file creation,
                    // so the file may exist despite cancel() already
                    // "finishing" — clean up unconditionally.
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    await job.complete(with: outputURL)
                }
            } catch {
                if await job.isCancelledSync {
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    await job.fail(with: error)
                }
            }
        }
        return job
    }

    private static func run(
        source: MediaFile,
        target: OutputFormat,
        settings: VideoSettings,
        outputURL: URL,
        job: ConversionJob
    ) async throws {
        let asset = AVURLAsset(url: source.url)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let sourceNominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // Reuses source.resolution rather than re-deriving it — a second,
        // independent derivation is what let the crop rect drift out of
        // sync with the size used to interpret it.
        let sourceSize = source.resolution

        // Crop rect is always defined in the source's original, uncropped
        // resolution (ARCHITECTURE §6); resolution override scales the
        // already-cropped frame.
        let cropRect = settings.crop ?? CGRect(origin: .zero, size: sourceSize)
        let outputSize = OutputSizeResolver.resolvedOutputSize(cropSize: cropRect.size, resolution: settings.resolution)
        CropDebugLog.log(
            "ENGINE.run url=\(source.url.lastPathComponent) sourceSize(=source.resolution)=\(sourceSize) " +
            "requestedCrop=\(String(describing: settings.crop)) effectiveCropRect=\(cropRect) outputSize=\(outputSize)"
        )

        let frameRateValue: Float = {
            switch settings.frameRate {
            case .original: return max(sourceNominalFrameRate, 1)
            case .fps(let value): return Float(max(value, 1))
            }
        }()
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRateValue.rounded()))

        let videoComposition = try await makeVideoComposition(
            asset: asset,
            sourceSize: sourceSize,
            cropRect: cropRect,
            outputSize: outputSize,
            frameDuration: frameDuration
        )

        let trimStart = CMTime(seconds: max(settings.trim.start, 0), preferredTimescale: 600)
        let trimEnd = CMTime(seconds: settings.trim.end, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: trimStart, end: trimEnd)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let videoReaderOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        videoReaderOutput.videoComposition = videoComposition
        guard reader.canAdd(videoReaderOutput) else { throw ConversionError.readerSetupFailed }
        reader.add(videoReaderOutput)

        let includeAudio = settings.audio != .stripped && audioTrack != nil
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if includeAudio, let audioTrack {
            // Decode to linear PCM so the writer can re-encode to whatever
            // target codec/bitrate AudioMode specifies.
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            guard reader.canAdd(output) else { throw ConversionError.readerSetupFailed }
            reader.add(output)
            audioReaderOutput = output
        }

        guard reader.startReading() else {
            throw reader.error ?? ConversionError.readerSetupFailed
        }

        let fileType: AVFileType = target == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(url: outputURL, fileType: fileType)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoEncoderSettings(outputSize: outputSize, quality: settings.quality, frameRate: frameRateValue)
        )
        videoInput.expectsMediaDataInRealTime = false
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        guard writer.canAdd(videoInput) else { throw ConversionError.writerSetupFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioEncoderSettings(mode: settings.audio))
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ConversionError.writerSetupFailed }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? ConversionError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = max(CMTimeGetSeconds(timeRange.duration), 0.001)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let videoQueue = DispatchQueue(label: "RemediaCore.AVFoundationEngine.video")
            let audioQueue = DispatchQueue(label: "RemediaCore.AVFoundationEngine.audio")
            let group = DispatchGroup()
            let errorLock = NSLock()
            var recordedError: Error?

            func recordError(_ error: Error) {
                errorLock.lock()
                if recordedError == nil { recordedError = error }
                errorLock.unlock()
            }

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if job.isCancelledSync {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let adjustedTime = CMTimeSubtract(presentationTime, timeRange.start)

                    if !pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: adjustedTime) {
                        recordError(writer.error ?? ConversionError.writerSetupFailed)
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }

                    job.reportSync(progress: min(max(CMTimeGetSeconds(adjustedTime) / totalDuration, 0), 1))
                }
            }

            if let audioInput, let audioReaderOutput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if job.isCancelledSync {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        guard let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        // Must shift by the same trim.start offset as video,
                        // or a non-zero trim leaves audio starting late
                        // relative to the rebased video track.
                        let shiftedBuffer = Self.sampleBuffer(sampleBuffer, shiftedBy: timeRange.start) ?? sampleBuffer
                        if !audioInput.append(shiftedBuffer) {
                            recordError(writer.error ?? ConversionError.writerSetupFailed)
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                if job.isCancelledSync {
                    writer.cancelWriting()
                    reader.cancelReading()
                    continuation.resume()
                    return
                }
                if let recordedError {
                    writer.cancelWriting()
                    continuation.resume(throwing: recordedError)
                    return
                }
                writer.finishWriting {
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Shifts presentation/decode timestamps by `-offset`, matching video's
    /// own rebasing so both tracks agree on where t=0 is.
    private static func sampleBuffer(_ sampleBuffer: CMSampleBuffer, shiftedBy offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else {
            return nil
        }

        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: nil) == noErr else {
            return nil
        }

        for index in timingInfo.indices {
            timingInfo[index].presentationTimeStamp = CMTimeSubtract(timingInfo[index].presentationTimeStamp, offset)
            if timingInfo[index].decodeTimeStamp.isValid {
                timingInfo[index].decodeTimeStamp = CMTimeSubtract(timingInfo[index].decodeTimeStamp, offset)
            }
        }

        var adjustedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingInfo.count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )
        return status == noErr ? adjustedBuffer : nil
    }

    /// CI-filter-based crop/translate/scale rather than a layer-instruction
    /// transform — `request.sourceImage` is already rotation-corrected,
    /// avoiding a hand-composed transform against `preferredTransform` (§6).
    private static func makeVideoComposition(
        asset: AVURLAsset,
        sourceSize: CGSize,
        cropRect: CGRect,
        outputSize: CGSize,
        frameDuration: CMTime
    ) async throws -> AVMutableVideoComposition {
        let hasLoggedExtent = LogOnceFlag()

        let base = try await AVVideoComposition.videoComposition(with: asset) { request in
            var image = request.sourceImage
            var sourceExtent = image.extent

            // `request.sourceImage` is rotation-corrected but not SAR-
            // corrected (unlike `AVAssetImageGenerator`, which
            // `source.resolution`'s probe uses) — a non-square-pixel
            // source decodes here at its raw storage size, shifting/
            // stretching a crop rect authored against the SAR-corrected
            // sourceSize. Confirmed against a real anamorphic source:
            // sourceExtent 320x240 vs. sourceSize 426.667x240.
            let needsSARCorrection = abs(sourceExtent.width - sourceSize.width) > 0.5
                || abs(sourceExtent.height - sourceSize.height) > 0.5
            if needsSARCorrection, sourceExtent.width > 0, sourceExtent.height > 0 {
                let parScaleX = sourceSize.width / sourceExtent.width
                let parScaleY = sourceSize.height / sourceExtent.height
                image = image.transformed(by: CGAffineTransform(scaleX: parScaleX, y: parScaleY))
                sourceExtent = image.extent
            }

            // CIImage is Y-up (origin bottom-left); the crop rect is Y-down
            // like the UI. sourceExtent's origin isn't guaranteed (0,0)
            // either — assuming so can mis-locate/over-clip the crop.
            let ciCropRect = CGRect(
                x: sourceExtent.origin.x + cropRect.origin.x,
                y: sourceExtent.origin.y + sourceExtent.height - cropRect.origin.y - cropRect.height,
                width: cropRect.width,
                height: cropRect.height
            ).intersection(sourceExtent)

            if !hasLoggedExtent.consume() {
                CropDebugLog.log(
                    "ENGINE.composition rawSourceExtent=\(request.sourceImage.extent) sarCorrected=\(needsSARCorrection) " +
                    "correctedSourceExtent=\(sourceExtent) requestedCropRect=\(cropRect) " +
                    "computedCiCropRect=\(ciCropRect) outputSize=\(outputSize)"
                )
            }

            if !ciCropRect.isEmpty && ciCropRect != sourceExtent {
                image = image.cropped(to: ciCropRect)
                image = image.transformed(by: CGAffineTransform(translationX: -ciCropRect.origin.x, y: -ciCropRect.origin.y))
            }

            // Scaled from the requested crop size, not the (possibly
            // `.intersection`-clipped) cropped extent — scaling against the
            // clipped size instead would stretch the output despite it
            // reporting the "correct" dimensions.
            if cropRect.width > 0, cropRect.height > 0 {
                let scaleX = outputSize.width / cropRect.width
                let scaleY = outputSize.height / cropRect.height
                image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            }

            request.finish(with: image, context: nil)
        }
        guard let composition = base.mutableCopy() as? AVMutableVideoComposition else {
            throw ConversionError.readerSetupFailed
        }
        composition.renderSize = outputSize
        composition.frameDuration = frameDuration
        return composition
    }

    /// Quality (0...100) maps to bitrate via a bits-per-pixel heuristic
    /// (~0.05 bpp at Low, ~0.35 bpp at High) since AVAssetWriterInput has no
    /// direct CRF-style knob for H.264 the way FFmpeg does.
    private static func videoEncoderSettings(outputSize: CGSize, quality: Double, frameRate: Float) -> [String: Any] {
        let normalizedQuality = max(min(quality, 100), 0) / 100.0
        let bitsPerPixel = 0.05 + (0.35 - 0.05) * normalizedQuality
        let bitRate = Double(outputSize.width) * Double(outputSize.height) * Double(frameRate) * bitsPerPixel

        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]
    }

    private static func audioEncoderSettings(mode: AudioMode) -> [String: Any] {
        let codec: AudioCodec
        let bitrateKbps: Int
        switch mode {
        case .auto:
            codec = .aac
            bitrateKbps = 128
        case .custom(let customCodec, let customBitrate):
            codec = customCodec
            bitrateKbps = customBitrate
        case .stripped:
            codec = .aac
            bitrateKbps = 128
        }

        switch codec {
        case .aac, .opus, .vorbis:
            // opus/vorbis aren't valid in mov/mp4 (this engine only handles
            // that pair) — falls back to AAC; unreachable in practice.
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: bitrateKbps * 1000,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100
            ]
        case .pcm:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100
            ]
        }
    }
}
