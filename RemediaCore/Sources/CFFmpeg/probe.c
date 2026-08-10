#include "internal.h"

int cffmpeg_probe(const char *inputPath, CFFmpegProbeResult *outResult, char *errorBuffer, int errorBufferSize) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';

    AVFormatContext *inputCtx = NULL;
    int result = 0;

    int ret = avformat_open_input(&inputCtx, inputPath, NULL, NULL);
    if (ret < 0) {
        if (errorBuffer) {
            char avmsg[AV_ERROR_MAX_STRING_SIZE];
            av_strerror(ret, avmsg, sizeof(avmsg));
            snprintf(errorBuffer, (size_t)errorBufferSize, "Opening input failed: %s", avmsg);
        }
        return ret;
    }

    ret = avformat_find_stream_info(inputCtx, NULL);
    if (ret < 0) {
        if (errorBuffer) {
            char avmsg[AV_ERROR_MAX_STRING_SIZE];
            av_strerror(ret, avmsg, sizeof(avmsg));
            snprintf(errorBuffer, (size_t)errorBufferSize, "Reading stream info failed: %s", avmsg);
        }
        result = ret;
        goto cleanup;
    }

    int videoStreamIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoStreamIndex < 0) {
        if (errorBuffer) snprintf(errorBuffer, (size_t)errorBufferSize, "No video stream found in input");
        result = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }

    int audioStreamIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);

    AVStream *videoStream = inputCtx->streams[videoStreamIndex];
    double duration = inputCtx->duration > 0
        ? (double)inputCtx->duration / AV_TIME_BASE
        : (videoStream->duration > 0 ? videoStream->duration * av_q2d(videoStream->time_base) : 0.0);

    // A gif-sourced webm commonly has avg_frame_rate = 0/0, and av_q2d of
    // that is NaN — `frameRate <= 0` wouldn't catch it (NaN comparisons are
    // always false); `!(frameRate > 0)` does. Falls back to 10fps if
    // r_frame_rate is equally undefined; downstream callers divide by this.
    double frameRate = av_q2d(videoStream->avg_frame_rate);
    if (!(frameRate > 0)) frameRate = av_q2d(videoStream->r_frame_rate);
    if (!(frameRate > 0)) frameRate = 10.0;

    // codecpar->width/height is the raw storage size; a non-square-pixel
    // (SAR) source needs its width corrected to the display size everything
    // downstream treats as ground truth. Matroska/WebM's DisplayWidth tags
    // land on AVStream's own sample_aspect_ratio, not codecpar's copy
    // (often left at 0/1) — hence the fallback order below.
    AVRational sar = videoStream->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) sar = videoStream->codecpar->sample_aspect_ratio;
    int displayWidth = cffmpeg_sanitized_display_width(videoStream->codecpar->width, sar);

    outResult->duration = duration;
    outResult->width = displayWidth;
    outResult->height = videoStream->codecpar->height;
    outResult->frameRate = frameRate;
    outResult->hasAudio = audioStreamIndex >= 0 ? 1 : 0;

cleanup:
    if (inputCtx) avformat_close_input(&inputCtx);
    return result;
}
