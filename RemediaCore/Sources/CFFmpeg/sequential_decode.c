#include "internal.h"
#include <libswscale/swscale.h>
#include <stdlib.h>

struct CFFmpegSequentialDecoder {
    AVFormatContext *inputCtx;
    AVCodecContext *decoderCtx;
    int videoStreamIndex;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *swsCtx;
    int displayWidth;
};

void cffmpeg_close_sequential_decoder(CFFmpegSequentialDecoder *decoder) {
    if (!decoder) return;
    if (decoder->swsCtx) sws_freeContext(decoder->swsCtx);
    if (decoder->frame) av_frame_free(&decoder->frame);
    if (decoder->packet) av_packet_free(&decoder->packet);
    if (decoder->decoderCtx) avcodec_free_context(&decoder->decoderCtx);
    if (decoder->inputCtx) avformat_close_input(&decoder->inputCtx);
    free(decoder);
}

CFFmpegSequentialDecoder *cffmpeg_open_sequential_decoder(
    const char *inputPath,
    char *errorBuffer,
    int errorBufferSize
) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';

    CFFmpegSequentialDecoder *decoder = calloc(1, sizeof(CFFmpegSequentialDecoder));
    if (!decoder) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate decoder");
        return NULL;
    }

    int ret = avformat_open_input(&decoder->inputCtx, inputPath, NULL, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening input failed", ret);
        free(decoder);
        return NULL;
    }

    ret = avformat_find_stream_info(decoder->inputCtx, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Reading stream info failed", ret);
        cffmpeg_close_sequential_decoder(decoder);
        return NULL;
    }

    decoder->videoStreamIndex = av_find_best_stream(decoder->inputCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (decoder->videoStreamIndex < 0) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "No video stream found in input");
        cffmpeg_close_sequential_decoder(decoder);
        return NULL;
    }

    ret = cffmpeg_open_decoder(decoder->inputCtx, decoder->videoStreamIndex, &decoder->decoderCtx, errorBuffer, errorBufferSize);
    if (ret < 0) {
        cffmpeg_close_sequential_decoder(decoder);
        return NULL;
    }

    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    if (!decoder->packet || !decoder->frame) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate packet/frame buffers");
        cffmpeg_close_sequential_decoder(decoder);
        return NULL;
    }

    // Same SAR display-width correction as cffmpeg_probe/cffmpeg_decode_frame_at,
    // computed once since it's fixed for the decoder's lifetime.
    AVStream *videoStream = decoder->inputCtx->streams[decoder->videoStreamIndex];
    AVRational sar = videoStream->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) sar = decoder->decoderCtx->sample_aspect_ratio;
    decoder->displayWidth = cffmpeg_sanitized_display_width(decoder->decoderCtx->width, sar);

    decoder->swsCtx = sws_getContext(
        decoder->decoderCtx->width, decoder->decoderCtx->height, decoder->decoderCtx->pix_fmt,
        decoder->displayWidth, decoder->decoderCtx->height, AV_PIX_FMT_BGRA,
        SWS_BILINEAR, NULL, NULL, NULL
    );
    if (!decoder->swsCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not create color conversion context");
        cffmpeg_close_sequential_decoder(decoder);
        return NULL;
    }

    return decoder;
}

int cffmpeg_seek_sequential_decoder(CFFmpegSequentialDecoder *decoder, double timeSeconds) {
    if (!decoder) return AVERROR(EINVAL);
    AVStream *videoStream = decoder->inputCtx->streams[decoder->videoStreamIndex];
    int64_t targetTs = (int64_t)llround(timeSeconds / av_q2d(videoStream->time_base));
    int ret = av_seek_frame(decoder->inputCtx, decoder->videoStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(decoder->decoderCtx);
    return ret;
}

// Returns 0 with a frame, 1 at end of stream, negative on error. Pulls from
// the decoder first (in case a previous send already queued one) and only
// reads+sends another packet when the decoder actually needs one — unlike
// cffmpeg_decode_frame_at, nothing here reopens the file or seeks.
int cffmpeg_decode_next_frame(
    CFFmpegSequentialDecoder *decoder,
    uint8_t **outData,
    int *outWidth,
    int *outHeight,
    int *outBytesPerRow,
    double *outPts,
    char *errorBuffer,
    int errorBufferSize
) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';
    if (!decoder) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Decoder is NULL");
        return AVERROR(EINVAL);
    }

    AVStream *videoStream = decoder->inputCtx->streams[decoder->videoStreamIndex];
    int flushed = 0;
    int haveFrame = 0;
    int failure = 0;

    while (!haveFrame && !failure) {
        int receiveResult = avcodec_receive_frame(decoder->decoderCtx, decoder->frame);
        if (receiveResult == 0) {
            haveFrame = 1;
            break;
        }
        if (receiveResult == AVERROR_EOF) {
            break;
        }
        if (receiveResult != AVERROR(EAGAIN)) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Decoding failed", receiveResult);
            failure = 1;
            break;
        }

        int readResult = av_read_frame(decoder->inputCtx, decoder->packet);
        if (readResult < 0) {
            if (flushed) break; // fully drained after flush — clean EOF
            avcodec_send_packet(decoder->decoderCtx, NULL);
            flushed = 1;
            continue;
        }
        if (decoder->packet->stream_index != decoder->videoStreamIndex) {
            av_packet_unref(decoder->packet);
            continue;
        }
        avcodec_send_packet(decoder->decoderCtx, decoder->packet);
        av_packet_unref(decoder->packet);
    }

    if (failure) return AVERROR_UNKNOWN;
    if (!haveFrame) return 1; // EOF

    int64_t timestamp = decoder->frame->best_effort_timestamp;
    *outPts = timestamp == AV_NOPTS_VALUE ? 0.0 : timestamp * av_q2d(videoStream->time_base);

    int bytesPerRow = decoder->displayWidth * 4;
    uint8_t *outputBuffer = malloc((size_t)bytesPerRow * decoder->decoderCtx->height);
    if (!outputBuffer) {
        av_frame_unref(decoder->frame);
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate pixel buffer");
        return AVERROR(ENOMEM);
    }

    uint8_t *dstData[1] = { outputBuffer };
    int dstLinesize[1] = { bytesPerRow };
    sws_scale(decoder->swsCtx, (const uint8_t *const *)decoder->frame->data, decoder->frame->linesize,
              0, decoder->decoderCtx->height, dstData, dstLinesize);

    av_frame_unref(decoder->frame);

    *outData = outputBuffer;
    *outWidth = decoder->displayWidth;
    *outHeight = decoder->decoderCtx->height;
    *outBytesPerRow = bytesPerRow;
    return 0;
}
