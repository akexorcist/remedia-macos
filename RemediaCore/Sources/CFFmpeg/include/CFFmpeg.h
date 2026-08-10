#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

// Real FFmpeg C API, vendored via Scripts/build-ffmpeg.sh and packaged as
// local xcframeworks under Vendor/FFmpeg (ARCHITECTURE §7). Re-exported here
// so FFmpegEngine/FFmpegDecodePreviewSource can call libav*/libvpx/libopus
// directly from Swift through this module.

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>

int cffmpeg_shim_is_stub(void);

// Real linkage smoke test — forces the linker to resolve symbols from
// libavutil/libavformat/libavcodec/libavfilter/libvpx/libopus, proving the
// vendored xcframeworks actually link, not just compile against headers.
const char *cffmpeg_version_info(void);
unsigned cffmpeg_avformat_version(void);
unsigned cffmpeg_avcodec_version(void);
unsigned cffmpeg_avfilter_version(void);

// Non-zero if libavcodec was actually built with the libvpx/libopus
// wrapper encoders compiled in and linked (not just headers present).
int cffmpeg_has_libvpx_vp9_encoder(void);
int cffmpeg_has_libopus_encoder(void);

// Real transcode pipeline for anything EngineRouter doesn't route to
// AVFoundationEngine (ARCHITECTURE §3): source or target is gif/webm, in
// either direction. Implemented in C (transcode.c) rather than called
// piecemeal from Swift, since the raw FFmpeg C API is a far more natural fit
// here than through Swift/C interop — see FFmpeg's own transcoding.c /
// filtering_video.c examples, which this follows closely.
//
// All settings are pre-resolved by the Swift side (ResolutionOverride /
// FrameRateOverride / AudioMode already turned into concrete numbers and
// codec names) — this function has no opinions about defaults.
typedef struct {
    // The source's probed display resolution — what `cropX/Y/Width/Height`
    // below are actually authored against (matching the UI's crop overlay
    // and `MediaFile.resolution`). Ordinarily equal to the decoder's own
    // `width`/`height`, except for a source with non-square pixels (SAR),
    // where the decoder produces frames at the raw, un-stretched storage
    // size instead. When they differ, the filter graph inserts a
    // corrective scale before cropping so the crop coordinates land where
    // they were actually drawn.
    int sourceWidth;
    int sourceHeight;

    // Crop, in the source's original pixel coordinates. hasCrop=0 means the
    // full frame (ARCHITECTURE §6: crop is always defined pre-scale).
    int hasCrop;
    int cropX;
    int cropY;
    int cropWidth;
    int cropHeight;

    // Final output pixel size, after crop and any resolution override.
    int outputWidth;
    int outputHeight;

    // Output frame rate. <= 0 means keep the source's frame rate.
    double fps;

    // Trim range in seconds, both already resolved to concrete values by
    // the Swift side (REQUIREMENTS §5) — never "to end of source" here.
    double trimStart;
    double trimEnd;

    // 0...1; mapped to a bitrate for whichever video codec is selected,
    // the same bits-per-pixel heuristic AVFoundationEngine uses.
    double quality;

    // e.g. "h264_videotoolbox", "libvpx-vp9", "gif".
    const char *videoCodecName;

    // NULL/empty means no audio track in the output at all (AudioMode
    // .stripped, or target is gif). e.g. "aac", "alac", "pcm_s16le",
    // "libopus", "vorbis".
    const char *audioCodecName;
    int audioBitrateKbps;

    // GIF target only; ignored for other targets.
    int isGifTarget;
    int paletteColors;       // 0 = ffmpeg's own default (256)
    const char *ditherMode;  // "bayer" / "none" / "floyd_steinberg" / "sierra2_4a"; NULL = ffmpeg default
    // Matches the gif muxer's own `loop` option: -1 = no loop (play once),
    // 0 = infinite, N > 0 = loop N times.
    int gifLoopCount;
} CFFmpegTranscodeOptions;

typedef void (*CFFmpegProgressCallback)(double progress, void *context);
// Return non-zero to abort the transcode early (checked once per read packet).
typedef int (*CFFmpegShouldCancelCallback)(void *context);

// Returns 0 on success, 1 if cancelled mid-run, negative on failure — with a
// human-readable message written into errorBuffer either way (empty on
// success). outputFormatName is ffmpeg's muxer name: "mov", "mp4", "gif", "webm".
int cffmpeg_transcode(
    const char *inputPath,
    const char *outputPath,
    const char *outputFormatName,
    const CFFmpegTranscodeOptions *options,
    CFFmpegProgressCallback progressCallback,
    void *progressContext,
    CFFmpegShouldCancelCallback shouldCancelCallback,
    void *cancelContext,
    char *errorBuffer,
    int errorBufferSize
);

// Real probing for formats AVFoundation can't read at all (webm; gif is
// probed via ImageIO instead, since that needs no FFmpeg — see
// MediaFileProber). Returns 0 on success, negative on failure with a
// message in errorBuffer.
typedef struct {
    double duration;
    int width;
    int height;
    double frameRate;
    int hasAudio;
} CFFmpegProbeResult;

int cffmpeg_probe(
    const char *inputPath,
    CFFmpegProbeResult *outResult,
    char *errorBuffer,
    int errorBufferSize
);

// Decodes a single frame near timeSeconds (seeks to the nearest keyframe at
// or before it, then decodes forward to the exact target) and converts it
// to top-left-origin BGRA — the layout AVPlayerPreviewSource's CVPixelBuffer
// construction also uses, so both preview sources feed the UI identically
// (ARCHITECTURE §3/§5). *outData is malloc'd; the caller must free it via
// cffmpeg_free_frame_data, not free() directly (kept as a separate symbol in
// case the allocation strategy ever changes).
int cffmpeg_decode_frame_at(
    const char *inputPath,
    double timeSeconds,
    uint8_t **outData,
    int *outWidth,
    int *outHeight,
    int *outBytesPerRow,
    char *errorBuffer,
    int errorBufferSize
);

void cffmpeg_free_frame_data(uint8_t *data);

// Sequential (non-seeking) decode for continuous playback — opens the file
// once and reads forward, unlike cffmpeg_decode_frame_at which reopens and
// reseeks on every call (fine for scrubbing, far too slow to call at
// playback frame rates).
typedef struct CFFmpegSequentialDecoder CFFmpegSequentialDecoder;

CFFmpegSequentialDecoder *cffmpeg_open_sequential_decoder(
    const char *inputPath,
    char *errorBuffer,
    int errorBufferSize
);

int cffmpeg_decode_next_frame(
    CFFmpegSequentialDecoder *decoder,
    uint8_t **outData,
    int *outWidth,
    int *outHeight,
    int *outBytesPerRow,
    double *outPts,
    char *errorBuffer,
    int errorBufferSize
);

int cffmpeg_seek_sequential_decoder(CFFmpegSequentialDecoder *decoder, double timeSeconds);

void cffmpeg_close_sequential_decoder(CFFmpegSequentialDecoder *decoder);

// Test-fixture helper only (test_support.c) — remuxes inputPath into
// outputPath (stream-copy, no re-encode) while forcing the video stream's
// sample_aspect_ratio, so tests can build an anamorphic webm fixture that
// FFmpegEngine's own transcode pipeline can't produce (it corrects SAR away
// before muxing). Returns 0 on success, negative on failure with a message
// in errorBuffer.
int cffmpeg_force_sample_aspect_ratio(
    const char *inputPath,
    const char *outputPath,
    int sarNum,
    int sarDen,
    char *errorBuffer,
    int errorBufferSize
);

#endif
