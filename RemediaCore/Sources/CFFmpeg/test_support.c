#include "internal.h"
#include <string.h>

// Test-fixture helper only. FFmpegEngine's own pipeline corrects SAR away
// before muxing, and AVFoundation can't write webm — so an anamorphic webm
// fixture can only be made by remuxing an existing one (stream copy, no
// re-encode) while forcing the video stream's sample_aspect_ratio.
int cffmpeg_force_sample_aspect_ratio(
    const char *inputPath,
    const char *outputPath,
    int sarNum,
    int sarDen,
    char *errorBuffer,
    int errorBufferSize
) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';

    AVFormatContext *inputCtx = NULL;
    AVFormatContext *outputCtx = NULL;
    int *streamMapping = NULL;
    AVPacket *packet = NULL;
    int result = 0;
    int outputOpened = 0;

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

    avformat_alloc_output_context2(&outputCtx, NULL, NULL, outputPath);
    if (!outputCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not infer output format from path");
        result = AVERROR_UNKNOWN;
        goto cleanup;
    }

    streamMapping = av_calloc(inputCtx->nb_streams, sizeof(int));
    if (!streamMapping) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }

    int outputStreamIndex = 0;
    for (unsigned i = 0; i < inputCtx->nb_streams; i++) {
        AVStream *inStream = inputCtx->streams[i];
        enum AVMediaType type = inStream->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) {
            streamMapping[i] = -1;
            continue;
        }

        AVStream *outStream = avformat_new_stream(outputCtx, NULL);
        if (!outStream) {
            result = AVERROR_UNKNOWN;
            goto cleanup;
        }
        ret = avcodec_parameters_copy(outStream->codecpar, inStream->codecpar);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Copying stream parameters failed", ret);
            result = ret;
            goto cleanup;
        }
        outStream->codecpar->codec_tag = 0;
        if (type == AVMEDIA_TYPE_VIDEO) {
            outStream->codecpar->sample_aspect_ratio.num = sarNum;
            outStream->codecpar->sample_aspect_ratio.den = sarDen;
            // The muxer (at least matroska/webm) computes DisplayWidth from
            // this legacy AVStream field, not codecpar's copy — setting
            // only codecpar silently no-ops for webm output.
            outStream->sample_aspect_ratio.num = sarNum;
            outStream->sample_aspect_ratio.den = sarDen;
        }
        streamMapping[i] = outputStreamIndex++;
    }

    ret = avio_open(&outputCtx->pb, outputPath, AVIO_FLAG_WRITE);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening output failed", ret);
        result = ret;
        goto cleanup;
    }
    outputOpened = 1;

    ret = avformat_write_header(outputCtx, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing output header failed", ret);
        result = ret;
        goto cleanup;
    }

    packet = av_packet_alloc();
    if (!packet) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }

    while (av_read_frame(inputCtx, packet) >= 0) {
        if (packet->stream_index < 0 || (unsigned)packet->stream_index >= inputCtx->nb_streams ||
            streamMapping[packet->stream_index] < 0) {
            av_packet_unref(packet);
            continue;
        }
        AVStream *inStream = inputCtx->streams[packet->stream_index];
        AVStream *outStream = outputCtx->streams[streamMapping[packet->stream_index]];
        packet->stream_index = streamMapping[packet->stream_index];
        av_packet_rescale_ts(packet, inStream->time_base, outStream->time_base);
        packet->pos = -1;
        ret = av_interleaved_write_frame(outputCtx, packet);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing packet failed", ret);
            result = ret;
            goto cleanup;
        }
    }

    ret = av_write_trailer(outputCtx);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing output trailer failed", ret);
        result = ret;
        goto cleanup;
    }

cleanup:
    if (packet) av_packet_free(&packet);
    if (streamMapping) av_free(streamMapping);
    if (outputCtx) {
        if (outputOpened) avio_closep(&outputCtx->pb);
        avformat_free_context(outputCtx);
    }
    if (inputCtx) avformat_close_input(&inputCtx);
    return result;
}

// Test-fixture helper only. Synthesizes a small libvpx-vp9/yuva420p webm
// directly (no decode source) — FFmpegEngine's own pipeline never writes
// alpha except when re-encoding a source that already has it, so there's no
// production path that could produce this starting point. Left half of
// every frame is fully opaque solid red; right half is fully transparent
// (alpha=0, color left unset) — a known, testable split for assertions.
int cffmpeg_encode_synthetic_alpha_webm(
    const char *outputPath,
    int width,
    int height,
    int frameCount,
    char *errorBuffer,
    int errorBufferSize
) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';

    AVFormatContext *outputCtx = NULL;
    AVCodecContext *encoderCtx = NULL;
    AVStream *stream = NULL;
    AVFrame *frame = NULL;
    AVPacket *packet = NULL;
    int result = 0;
    int outputOpened = 0;

    const AVCodec *encoder = avcodec_find_encoder_by_name("libvpx-vp9");
    if (!encoder) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "libvpx-vp9 encoder not found");
        return AVERROR_ENCODER_NOT_FOUND;
    }

    int ret = avformat_alloc_output_context2(&outputCtx, NULL, "webm", outputPath);
    if (ret < 0 || !outputCtx) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Allocating output context failed", ret < 0 ? ret : AVERROR_UNKNOWN);
        result = ret < 0 ? ret : AVERROR_UNKNOWN;
        goto cleanup;
    }

    stream = avformat_new_stream(outputCtx, NULL);
    if (!stream) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not create output stream");
        result = AVERROR(ENOMEM);
        goto cleanup;
    }

    encoderCtx = avcodec_alloc_context3(encoder);
    if (!encoderCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate encoder context");
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    encoderCtx->width = width;
    encoderCtx->height = height;
    encoderCtx->pix_fmt = AV_PIX_FMT_YUVA420P;
    encoderCtx->time_base = (AVRational){1, 10};
    encoderCtx->framerate = (AVRational){10, 1};
    if (outputCtx->oformat->flags & AVFMT_GLOBALHEADER) {
        encoderCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    stream->time_base = encoderCtx->time_base;

    ret = avcodec_open2(encoderCtx, encoder, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening encoder failed", ret);
        result = ret;
        goto cleanup;
    }

    ret = avcodec_parameters_from_context(stream->codecpar, encoderCtx);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Copying encoder parameters failed", ret);
        result = ret;
        goto cleanup;
    }

    ret = avio_open(&outputCtx->pb, outputPath, AVIO_FLAG_WRITE);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening output failed", ret);
        result = ret;
        goto cleanup;
    }
    outputOpened = 1;

    ret = avformat_write_header(outputCtx, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing output header failed", ret);
        result = ret;
        goto cleanup;
    }

    frame = av_frame_alloc();
    packet = av_packet_alloc();
    if (!frame || !packet) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    frame->format = AV_PIX_FMT_YUVA420P;
    frame->width = width;
    frame->height = height;
    ret = av_frame_get_buffer(frame, 0);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Allocating frame buffer failed", ret);
        result = ret;
        goto cleanup;
    }

    // BT.601 limited-range "red" on the Y/U/V planes; alpha plane carries
    // the actual left-opaque/right-transparent split the tests assert on.
    for (int y = 0; y < height; y++) {
        memset(frame->data[0] + y * frame->linesize[0], 76, (size_t)width);
        memset(frame->data[3] + y * frame->linesize[3], 255, (size_t)(width / 2));
        memset(frame->data[3] + y * frame->linesize[3] + width / 2, 0, (size_t)(width - width / 2));
    }
    for (int y = 0; y < (height + 1) / 2; y++) {
        memset(frame->data[1] + y * frame->linesize[1], 84, (size_t)((width + 1) / 2));
        memset(frame->data[2] + y * frame->linesize[2], 255, (size_t)((width + 1) / 2));
    }

    for (int i = 0; i < frameCount; i++) {
        ret = av_frame_make_writable(frame);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Making frame writable failed", ret);
            result = ret;
            goto cleanup;
        }
        frame->pts = i;

        ret = avcodec_send_frame(encoderCtx, frame);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Sending frame to encoder failed", ret);
            result = ret;
            goto cleanup;
        }
        while (ret >= 0) {
            ret = avcodec_receive_packet(encoderCtx, packet);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) {
                cffmpeg_set_averror(errorBuffer, errorBufferSize, "Receiving packet from encoder failed", ret);
                result = ret;
                goto cleanup;
            }
            av_packet_rescale_ts(packet, encoderCtx->time_base, stream->time_base);
            packet->stream_index = stream->index;
            ret = av_interleaved_write_frame(outputCtx, packet);
            av_packet_unref(packet);
            if (ret < 0) {
                cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing packet failed", ret);
                result = ret;
                goto cleanup;
            }
        }
    }

    ret = avcodec_send_frame(encoderCtx, NULL); // flush
    while (ret >= 0) {
        ret = avcodec_receive_packet(encoderCtx, packet);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Receiving packet from encoder failed", ret);
            result = ret;
            goto cleanup;
        }
        av_packet_rescale_ts(packet, encoderCtx->time_base, stream->time_base);
        packet->stream_index = stream->index;
        ret = av_interleaved_write_frame(outputCtx, packet);
        av_packet_unref(packet);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing packet failed", ret);
            result = ret;
            goto cleanup;
        }
    }

    ret = av_write_trailer(outputCtx);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing output trailer failed", ret);
        result = ret;
        goto cleanup;
    }

cleanup:
    if (packet) av_packet_free(&packet);
    if (frame) av_frame_free(&frame);
    if (encoderCtx) avcodec_free_context(&encoderCtx);
    if (outputCtx) {
        if (outputOpened) avio_closep(&outputCtx->pb);
        avformat_free_context(outputCtx);
    }
    return result;
}
