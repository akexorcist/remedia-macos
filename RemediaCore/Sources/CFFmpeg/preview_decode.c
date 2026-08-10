#include "internal.h"
#include <libswscale/swscale.h>
#include <stdlib.h>

void cffmpeg_free_frame_data(uint8_t *data) {
    free(data);
}

int cffmpeg_decode_frame_at(
    const char *inputPath,
    double timeSeconds,
    uint8_t **outData,
    int *outWidth,
    int *outHeight,
    int *outBytesPerRow,
    char *errorBuffer,
    int errorBufferSize
) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';

    AVFormatContext *inputCtx = NULL;
    AVCodecContext *decoderCtx = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    AVFrame *lastGoodFrame = NULL;
    AVFrame *bgraFrame = NULL;
    struct SwsContext *swsCtx = NULL;
    uint8_t *outputBuffer = NULL;
    int result = 0;

    int ret = avformat_open_input(&inputCtx, inputPath, NULL, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening input failed", ret);
        return ret;
    }

    ret = avformat_find_stream_info(inputCtx, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Reading stream info failed", ret);
        result = ret;
        goto cleanup;
    }

    int videoStreamIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoStreamIndex < 0) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "No video stream found in input");
        result = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }

    ret = cffmpeg_open_decoder(inputCtx, videoStreamIndex, &decoderCtx, errorBuffer, errorBufferSize);
    if (ret < 0) { result = ret; goto cleanup; }

    AVStream *videoStream = inputCtx->streams[videoStreamIndex];
    int64_t targetTs = (int64_t)llround(timeSeconds / av_q2d(videoStream->time_base));
    // AVSEEK_FLAG_BACKWARD lands on the keyframe at or before targetTs;
    // decoding continues forward from there to the exact requested frame.
    av_seek_frame(inputCtx, videoStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(decoderCtx);

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    lastGoodFrame = av_frame_alloc();
    if (!packet || !frame || !lastGoodFrame) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate packet/frame buffers");
        result = AVERROR(ENOMEM);
        goto cleanup;
    }

    int haveFrame = 0;
    while (av_read_frame(inputCtx, packet) >= 0) {
        if (packet->stream_index != videoStreamIndex) {
            av_packet_unref(packet);
            continue;
        }
        ret = avcodec_send_packet(decoderCtx, packet);
        av_packet_unref(packet);
        if (ret < 0 && ret != AVERROR(EAGAIN)) continue;

        while (avcodec_receive_frame(decoderCtx, frame) == 0) {
            int64_t timestamp = frame->best_effort_timestamp;
            double framePts = timestamp == AV_NOPTS_VALUE ? 0.0 : timestamp * av_q2d(videoStream->time_base);
            haveFrame = 1;
            if (framePts >= timeSeconds) {
                goto decoded;
            }
            // avcodec_receive_frame unrefs `frame` internally the moment it
            // next returns EAGAIN/EOF, so the last successfully decoded
            // frame must be saved into a separate holder now — relying on
            // `frame` still holding it after this inner loop exits is wrong
            // and silently hands sws_scale a cleared (all-NULL) frame.
            av_frame_unref(lastGoodFrame);
            av_frame_ref(lastGoodFrame, frame);
        }
    }

    // True EOF without ever reaching timeSeconds — fall back to the last
    // successfully decoded frame instead of whatever `frame` was left
    // holding (already unreferenced by the failing receive call above).
    if (haveFrame) {
        av_frame_unref(frame);
        av_frame_ref(frame, lastGoodFrame);
    }

decoded:
    if (!haveFrame) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not decode any frame at the requested time");
        result = AVERROR_UNKNOWN;
        goto cleanup;
    }

    // Same SAR display-width correction as cffmpeg_probe, and for the same
    // reason: read from AVStream, not decoderCtx (only ever a copy of
    // codecpar's, often left at 0/1 for Matroska/WebM).
    AVRational sar = videoStream->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) sar = decoderCtx->sample_aspect_ratio;
    int displayWidth = decoderCtx->width;
    if (sar.num > 0 && sar.den > 0 && sar.num != sar.den) {
        displayWidth = (int)llround(decoderCtx->width * ((double)sar.num / sar.den));
    }

    swsCtx = sws_getContext(
        decoderCtx->width, decoderCtx->height, decoderCtx->pix_fmt,
        displayWidth, decoderCtx->height, AV_PIX_FMT_BGRA,
        SWS_BILINEAR, NULL, NULL, NULL
    );
    if (!swsCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not create color conversion context");
        result = AVERROR_UNKNOWN;
        goto cleanup;
    }

    bgraFrame = av_frame_alloc();
    if (!bgraFrame) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate output frame");
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    bgraFrame->format = AV_PIX_FMT_BGRA;
    bgraFrame->width = displayWidth;
    bgraFrame->height = decoderCtx->height;

    int bytesPerRow = displayWidth * 4;
    outputBuffer = malloc((size_t)bytesPerRow * decoderCtx->height);
    if (!outputBuffer) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate pixel buffer");
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    bgraFrame->data[0] = outputBuffer;
    bgraFrame->linesize[0] = bytesPerRow;

    sws_scale(swsCtx, (const uint8_t *const *)frame->data, frame->linesize, 0, decoderCtx->height,
              bgraFrame->data, bgraFrame->linesize);

    *outData = outputBuffer;
    *outWidth = displayWidth;
    *outHeight = decoderCtx->height;
    *outBytesPerRow = bytesPerRow;
    outputBuffer = NULL; // ownership transferred to the caller

cleanup:
    if (outputBuffer) free(outputBuffer);
    if (bgraFrame) av_frame_free(&bgraFrame);
    if (swsCtx) sws_freeContext(swsCtx);
    if (frame) av_frame_free(&frame);
    if (lastGoodFrame) av_frame_free(&lastGoodFrame);
    if (packet) av_packet_free(&packet);
    if (decoderCtx) avcodec_free_context(&decoderCtx);
    if (inputCtx) avformat_close_input(&inputCtx);
    return result;
}
