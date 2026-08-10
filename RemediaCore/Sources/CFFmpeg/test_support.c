#include "internal.h"

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
