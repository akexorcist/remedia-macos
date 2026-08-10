#include "internal.h"
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
#include <stdio.h>
#include <string.h>

// One decode -> filter -> encode pipeline stage (video or audio).
typedef struct {
    int inputStreamIndex;
    AVCodecContext *decoderCtx;

    AVFilterGraph *filterGraph;
    AVFilterContext *bufferSrcCtx;
    AVFilterContext *bufferSinkCtx;

    AVCodecContext *encoderCtx;
    AVStream *outputStream;

    // Audio only: encoders with a fixed frame_size (AAC, Opus) reject
    // arbitrarily-sized frames, so filtered samples are buffered here and
    // drained in exact frame_size chunks (cffmpeg_push_audio_frame).
    AVAudioFifo *audioFifo;
    int64_t audioSamplesWritten;
} CFFmpegStreamPipeline;

void cffmpeg_set_error(char *errorBuffer, int errorBufferSize, const char *message) {
    if (errorBuffer && errorBufferSize > 0) {
        snprintf(errorBuffer, (size_t)errorBufferSize, "%s", message);
    }
}

void cffmpeg_set_averror(char *errorBuffer, int errorBufferSize, const char *context, int averror) {
    if (!errorBuffer || errorBufferSize <= 0) return;
    char avmsg[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(averror, avmsg, sizeof(avmsg));
    snprintf(errorBuffer, (size_t)errorBufferSize, "%s: %s", context, avmsg);
}

static void cffmpeg_free_pipeline(CFFmpegStreamPipeline *pipeline) {
    if (!pipeline) return;
    if (pipeline->decoderCtx) avcodec_free_context(&pipeline->decoderCtx);
    if (pipeline->encoderCtx) avcodec_free_context(&pipeline->encoderCtx);
    if (pipeline->filterGraph) avfilter_graph_free(&pipeline->filterGraph);
    if (pipeline->audioFifo) av_audio_fifo_free(pipeline->audioFifo);
}

int cffmpeg_open_decoder(AVFormatContext *inputCtx, int streamIndex, AVCodecContext **outDecoderCtx,
                                 char *errorBuffer, int errorBufferSize) {
    AVStream *stream = inputCtx->streams[streamIndex];
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "No decoder available for input stream");
        return AVERROR_DECODER_NOT_FOUND;
    }

    AVCodecContext *decoderCtx = avcodec_alloc_context3(decoder);
    if (!decoderCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate decoder context");
        return AVERROR(ENOMEM);
    }

    int ret = avcodec_parameters_to_context(decoderCtx, stream->codecpar);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Copying decoder parameters failed", ret);
        avcodec_free_context(&decoderCtx);
        return ret;
    }
    decoderCtx->pkt_timebase = stream->time_base;

    ret = avcodec_open2(decoderCtx, decoder, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening decoder failed", ret);
        avcodec_free_context(&decoderCtx);
        return ret;
    }

    *outDecoderCtx = decoderCtx;
    return 0;
}

// Order matches ARCHITECTURE §6: trim (outside the filter graph) -> crop ->
// scale -> fps. `decodedWidth/Height` is the decoder's raw storage size,
// which for a non-square-pixel (SAR) source differs from
// `options->sourceWidth/Height` (the display size crop coordinates are
// authored against) — a corrective scale is inserted first to close that gap.
static void cffmpeg_build_video_filter_description(
    const CFFmpegTranscodeOptions *options, int decodedWidth, int decodedHeight,
    char *buffer, size_t bufferSize
) {
    char clause[256];
    buffer[0] = '\0';

    if (options->sourceWidth > 0 && options->sourceHeight > 0 &&
        (options->sourceWidth != decodedWidth || options->sourceHeight != decodedHeight)) {
        snprintf(clause, sizeof(clause), "scale=%d:%d,", options->sourceWidth, options->sourceHeight);
        strlcat(buffer, clause, bufferSize);
    }

    if (options->hasCrop) {
        snprintf(clause, sizeof(clause), "crop=%d:%d:%d:%d,",
                 options->cropWidth, options->cropHeight, options->cropX, options->cropY);
        strlcat(buffer, clause, bufferSize);
    }

    snprintf(clause, sizeof(clause), "scale=%d:%d,", options->outputWidth, options->outputHeight);
    strlcat(buffer, clause, bufferSize);

    if (options->fps > 0) {
        snprintf(clause, sizeof(clause), "fps=%f,", options->fps);
        strlcat(buffer, clause, bufferSize);
    }

    if (options->isGifTarget) {
        int colors = options->paletteColors > 0 ? options->paletteColors : 256;
        const char *dither = (options->ditherMode && options->ditherMode[0]) ? options->ditherMode : "sierra2_4a";
        snprintf(clause, sizeof(clause),
                 "split[s0][s1];[s0]palettegen=max_colors=%d:reserve_transparent=0[p];[s1][p]paletteuse=dither=%s",
                 colors, dither);
        strlcat(buffer, clause, bufferSize);
    } else {
        strlcat(buffer, "format=yuv420p", bufferSize);
    }
}

static int cffmpeg_init_video_filter_graph(AVCodecContext *decoderCtx, AVRational inputTimeBase,
                                            const CFFmpegTranscodeOptions *options,
                                            AVFilterGraph **outGraph, AVFilterContext **outSrc, AVFilterContext **outSink,
                                            char *errorBuffer, int errorBufferSize) {
    char args[512];
    char filterDescription[512];
    int ret;

    AVFilterGraph *graph = avfilter_graph_alloc();
    if (!graph) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate video filter graph");
        return AVERROR(ENOMEM);
    }

    const AVFilter *bufferSrc = avfilter_get_by_name("buffer");
    const AVFilter *bufferSink = avfilter_get_by_name("buffersink");

    snprintf(args, sizeof(args),
             "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
             decoderCtx->width, decoderCtx->height, decoderCtx->pix_fmt,
             inputTimeBase.num, inputTimeBase.den,
             decoderCtx->sample_aspect_ratio.num ? decoderCtx->sample_aspect_ratio.num : 1,
             decoderCtx->sample_aspect_ratio.den ? decoderCtx->sample_aspect_ratio.den : 1);

    AVFilterContext *srcCtx = NULL;
    ret = avfilter_graph_create_filter(&srcCtx, bufferSrc, "in", args, NULL, graph);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Creating video buffer source failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    AVFilterContext *sinkCtx = NULL;
    ret = avfilter_graph_create_filter(&sinkCtx, bufferSink, "out", NULL, NULL, graph);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Creating video buffer sink failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    cffmpeg_build_video_filter_description(options, decoderCtx->width, decoderCtx->height, filterDescription, sizeof(filterDescription));

    {
        FILE *debugLog = fopen("/tmp/mediaconverter-crop-debug.log", "a");
        if (debugLog) {
            fprintf(
                debugLog,
                "TRANSCODE.filterGraph decoderCtx(width:height)=(%d:%d) sar=%d/%d "
                "options.source(width:height)=(%d:%d) hasCrop=%d crop(x:y:w:h)=(%d:%d:%d:%d) "
                "output(width:height)=(%d:%d) filterDescription=\"%s\"\n",
                decoderCtx->width, decoderCtx->height,
                decoderCtx->sample_aspect_ratio.num, decoderCtx->sample_aspect_ratio.den,
                options->sourceWidth, options->sourceHeight,
                options->hasCrop, options->cropX, options->cropY, options->cropWidth, options->cropHeight,
                options->outputWidth, options->outputHeight,
                filterDescription
            );
            fclose(debugLog);
        }
    }

    AVFilterInOut *inputs = avfilter_inout_alloc();
    AVFilterInOut *outputs = avfilter_inout_alloc();
    if (!inputs || !outputs) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate filter graph endpoints");
        avfilter_inout_free(&inputs);
        avfilter_inout_free(&outputs);
        avfilter_graph_free(&graph);
        return AVERROR(ENOMEM);
    }

    // Reversed from what the names suggest: the parsed graph's "outputs"
    // connect to what WE feed in (bufferSrc), and its "inputs" connect to
    // what reads out of it (bufferSink).
    outputs->name = av_strdup("in");
    outputs->filter_ctx = srcCtx;
    outputs->pad_idx = 0;
    outputs->next = NULL;

    inputs->name = av_strdup("out");
    inputs->filter_ctx = sinkCtx;
    inputs->pad_idx = 0;
    inputs->next = NULL;

    ret = avfilter_graph_parse_ptr(graph, filterDescription, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Parsing video filter graph failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    ret = avfilter_graph_config(graph, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Configuring video filter graph failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    *outGraph = graph;
    *outSrc = srcCtx;
    *outSink = sinkCtx;
    return 0;
}

static int cffmpeg_init_audio_filter_graph(AVCodecContext *decoderCtx, AVRational inputTimeBase,
                                            enum AVSampleFormat targetSampleFormat, int targetSampleRate,
                                            AVFilterGraph **outGraph, AVFilterContext **outSrc, AVFilterContext **outSink,
                                            char *errorBuffer, int errorBufferSize) {
    char args[512];
    char layoutDescription[64];
    char filterDescription[256];
    int ret;

    AVFilterGraph *graph = avfilter_graph_alloc();
    if (!graph) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate audio filter graph");
        return AVERROR(ENOMEM);
    }

    const AVFilter *bufferSrc = avfilter_get_by_name("abuffer");
    const AVFilter *bufferSink = avfilter_get_by_name("abuffersink");

    av_channel_layout_describe(&decoderCtx->ch_layout, layoutDescription, sizeof(layoutDescription));
    snprintf(args, sizeof(args),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             inputTimeBase.num, inputTimeBase.den,
             decoderCtx->sample_rate, av_get_sample_fmt_name(decoderCtx->sample_fmt), layoutDescription);

    AVFilterContext *srcCtx = NULL;
    ret = avfilter_graph_create_filter(&srcCtx, bufferSrc, "in", args, NULL, graph);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Creating audio buffer source failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    AVFilterContext *sinkCtx = NULL;
    ret = avfilter_graph_create_filter(&sinkCtx, bufferSink, "out", NULL, NULL, graph);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Creating audio buffer sink failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    snprintf(filterDescription, sizeof(filterDescription),
             "aformat=sample_fmts=%s:sample_rates=%d:channel_layouts=stereo",
             av_get_sample_fmt_name(targetSampleFormat), targetSampleRate);

    AVFilterInOut *inputs = avfilter_inout_alloc();
    AVFilterInOut *outputs = avfilter_inout_alloc();
    if (!inputs || !outputs) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate audio filter graph endpoints");
        avfilter_inout_free(&inputs);
        avfilter_inout_free(&outputs);
        avfilter_graph_free(&graph);
        return AVERROR(ENOMEM);
    }

    outputs->name = av_strdup("in");
    outputs->filter_ctx = srcCtx;
    outputs->pad_idx = 0;
    outputs->next = NULL;

    inputs->name = av_strdup("out");
    inputs->filter_ctx = sinkCtx;
    inputs->pad_idx = 0;
    inputs->next = NULL;

    ret = avfilter_graph_parse_ptr(graph, filterDescription, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Parsing audio filter graph failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    ret = avfilter_graph_config(graph, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Configuring audio filter graph failed", ret);
        avfilter_graph_free(&graph);
        return ret;
    }

    *outGraph = graph;
    *outSrc = srcCtx;
    *outSink = sinkCtx;
    return 0;
}

// Bits-per-pixel heuristic shared conceptually with AVFoundationEngine's
// videoEncoderSettings, so the same quality slider means roughly the same
// thing regardless of which engine handles the conversion.
static int64_t cffmpeg_bitrate_for_quality(int width, int height, double fps, double quality) {
    double normalized = quality < 0 ? 0 : (quality > 1 ? 1 : quality);
    double bitsPerPixel = 0.05 + (0.35 - 0.05) * normalized;
    double effectiveFps = fps > 0 ? fps : 30.0;
    return (int64_t)((double)width * (double)height * effectiveFps * bitsPerPixel);
}

static int cffmpeg_open_video_encoder(const CFFmpegTranscodeOptions *options, AVFormatContext *outputCtx,
                                       AVRational filterTimeBase, AVCodecContext **outEncoderCtx, AVStream **outStream,
                                       char *errorBuffer, int errorBufferSize) {
    const AVCodec *encoder = avcodec_find_encoder_by_name(options->videoCodecName);
    if (!encoder) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Video encoder not found (was it enabled in this FFmpeg build?)");
        return AVERROR_ENCODER_NOT_FOUND;
    }

    AVStream *stream = avformat_new_stream(outputCtx, NULL);
    if (!stream) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not create output video stream");
        return AVERROR(ENOMEM);
    }

    AVCodecContext *encoderCtx = avcodec_alloc_context3(encoder);
    if (!encoderCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate video encoder context");
        return AVERROR(ENOMEM);
    }

    encoderCtx->width = options->outputWidth;
    encoderCtx->height = options->outputHeight;
    encoderCtx->time_base = filterTimeBase;
    stream->time_base = filterTimeBase;
    encoderCtx->framerate = options->fps > 0 ? av_d2q(options->fps, 100000) : (AVRational){30, 1};

    if (options->isGifTarget) {
        encoderCtx->pix_fmt = AV_PIX_FMT_PAL8;
    } else {
        encoderCtx->pix_fmt = AV_PIX_FMT_YUV420P;
        encoderCtx->bit_rate = cffmpeg_bitrate_for_quality(options->outputWidth, options->outputHeight, options->fps, options->quality);
        encoderCtx->gop_size = 60;
    }

    if (outputCtx->oformat->flags & AVFMT_GLOBALHEADER) {
        encoderCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    int ret = avcodec_open2(encoderCtx, encoder, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening video encoder failed", ret);
        avcodec_free_context(&encoderCtx);
        return ret;
    }

    ret = avcodec_parameters_from_context(stream->codecpar, encoderCtx);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Copying video encoder parameters failed", ret);
        avcodec_free_context(&encoderCtx);
        return ret;
    }

    *outEncoderCtx = encoderCtx;
    *outStream = stream;
    return 0;
}

static int cffmpeg_open_audio_encoder(const CFFmpegTranscodeOptions *options, AVFormatContext *outputCtx,
                                      enum AVSampleFormat sampleFormat, int sampleRate,
                                      AVCodecContext **outEncoderCtx, AVStream **outStream,
                                      char *errorBuffer, int errorBufferSize) {
    const AVCodec *encoder = avcodec_find_encoder_by_name(options->audioCodecName);
    if (!encoder) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Audio encoder not found (was it enabled in this FFmpeg build?)");
        return AVERROR_ENCODER_NOT_FOUND;
    }

    AVStream *stream = avformat_new_stream(outputCtx, NULL);
    if (!stream) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not create output audio stream");
        return AVERROR(ENOMEM);
    }

    AVCodecContext *encoderCtx = avcodec_alloc_context3(encoder);
    if (!encoderCtx) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate audio encoder context");
        return AVERROR(ENOMEM);
    }

    encoderCtx->sample_fmt = sampleFormat;
    encoderCtx->sample_rate = sampleRate;
    av_channel_layout_default(&encoderCtx->ch_layout, 2);
    encoderCtx->bit_rate = (int64_t)options->audioBitrateKbps * 1000;
    encoderCtx->time_base = (AVRational){1, sampleRate};
    stream->time_base = encoderCtx->time_base;

    if (outputCtx->oformat->flags & AVFMT_GLOBALHEADER) {
        encoderCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    int ret = avcodec_open2(encoderCtx, encoder, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening audio encoder failed", ret);
        avcodec_free_context(&encoderCtx);
        return ret;
    }

    ret = avcodec_parameters_from_context(stream->codecpar, encoderCtx);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Copying audio encoder parameters failed", ret);
        avcodec_free_context(&encoderCtx);
        return ret;
    }

    *outEncoderCtx = encoderCtx;
    *outStream = stream;
    return 0;
}

// frame=NULL flushes at end-of-stream.
static int cffmpeg_encode_and_write(AVCodecContext *encoderCtx, AVFormatContext *outputCtx, AVStream *stream,
                                     AVFrame *frame, AVRational frameTimeBase, AVPacket *packet,
                                     char *errorBuffer, int errorBufferSize) {
    // Filters (e.g. "fps=5") can renegotiate the buffersink's time_base —
    // rescale into the encoder's own before send_frame, which assumes
    // frame->pts is already in encoderCtx->time_base units.
    if (frame && frame->pts != AV_NOPTS_VALUE) {
        frame->pts = av_rescale_q(frame->pts, frameTimeBase, encoderCtx->time_base);
    }

    int ret = avcodec_send_frame(encoderCtx, frame);
    if (ret < 0 && ret != AVERROR_EOF) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Sending frame to encoder failed", ret);
        return ret;
    }

    while (ret >= 0 || ret == AVERROR_EOF) {
        ret = avcodec_receive_packet(encoderCtx, packet);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Receiving packet from encoder failed", ret);
            return ret;
        }

        av_packet_rescale_ts(packet, encoderCtx->time_base, stream->time_base);
        packet->stream_index = stream->index;
        // Encoders with no frame reordering (gif, and generally anything
        // without B-frames) may leave dts unset — the muxer's interleaving
        // queue requires a valid dts to sort by.
        if (packet->dts == AV_NOPTS_VALUE) {
            packet->dts = packet->pts;
        }

        ret = av_interleaved_write_frame(outputCtx, packet);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing packet failed", ret);
            return ret;
        }
    }
    return 0;
}

// pts is a running sample count in encoderCtx->time_base units (== {1,
// sampleRate}) — passing the encoder's own time_base as cffmpeg_encode_and_write's
// "source" time_base makes its rescale step a no-op.
static int cffmpeg_encode_audio_chunk(CFFmpegStreamPipeline *pipeline, int sampleCount, AVFormatContext *outputCtx,
                                       AVPacket *packet, char *errorBuffer, int errorBufferSize) {
    AVFrame *chunk = av_frame_alloc();
    if (!chunk) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate audio chunk frame");
        return AVERROR(ENOMEM);
    }

    chunk->format = pipeline->encoderCtx->sample_fmt;
    chunk->sample_rate = pipeline->encoderCtx->sample_rate;
    av_channel_layout_copy(&chunk->ch_layout, &pipeline->encoderCtx->ch_layout);
    chunk->nb_samples = sampleCount;

    int ret = av_frame_get_buffer(chunk, 0);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Allocating audio chunk buffer failed", ret);
        av_frame_free(&chunk);
        return ret;
    }

    ret = av_audio_fifo_read(pipeline->audioFifo, (void **)chunk->data, sampleCount);
    if (ret < sampleCount) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Reading from audio FIFO failed");
        av_frame_free(&chunk);
        return AVERROR_UNKNOWN;
    }

    chunk->pts = pipeline->audioSamplesWritten;
    pipeline->audioSamplesWritten += sampleCount;

    ret = cffmpeg_encode_and_write(pipeline->encoderCtx, outputCtx, pipeline->outputStream,
                                   chunk, pipeline->encoderCtx->time_base, packet, errorBuffer, errorBufferSize);
    av_frame_free(&chunk);
    return ret;
}

// Buffers a filtered audio frame and drains it in exact
// encoderCtx->frame_size chunks — encoders with a fixed frame size (AAC,
// Opus) reject arbitrarily-sized frames from the filter graph outright.
// Encoders that accept any size report frame_size == 0, in which case each
// incoming frame is just encoded as-is.
static int cffmpeg_push_audio_frame(CFFmpegStreamPipeline *pipeline, AVFrame *filteredFrame,
                                     AVFormatContext *outputCtx, AVPacket *packet,
                                     char *errorBuffer, int errorBufferSize) {
    if (!pipeline->audioFifo) {
        pipeline->audioFifo = av_audio_fifo_alloc(
            pipeline->encoderCtx->sample_fmt, pipeline->encoderCtx->ch_layout.nb_channels, 1
        );
        if (!pipeline->audioFifo) {
            cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate audio FIFO");
            return AVERROR(ENOMEM);
        }
    }

    int ret = av_audio_fifo_write(pipeline->audioFifo, (void **)filteredFrame->data, filteredFrame->nb_samples);
    if (ret < filteredFrame->nb_samples) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Writing to audio FIFO failed");
        return AVERROR_UNKNOWN;
    }

    int frameSize = pipeline->encoderCtx->frame_size > 0 ? pipeline->encoderCtx->frame_size : filteredFrame->nb_samples;
    while (av_audio_fifo_size(pipeline->audioFifo) >= frameSize) {
        ret = cffmpeg_encode_audio_chunk(pipeline, frameSize, outputCtx, packet, errorBuffer, errorBufferSize);
        if (ret < 0) return ret;
    }
    return 0;
}

// Encodes whatever's left in the FIFO as one final (possibly shorter than
// frame_size) chunk — called once at end-of-stream, before the encoder
// itself is flushed with a NULL frame.
static int cffmpeg_flush_audio_fifo(CFFmpegStreamPipeline *pipeline, AVFormatContext *outputCtx, AVPacket *packet,
                                     char *errorBuffer, int errorBufferSize) {
    if (!pipeline->audioFifo) return 0;
    int remaining = av_audio_fifo_size(pipeline->audioFifo);
    if (remaining <= 0) return 0;
    return cffmpeg_encode_audio_chunk(pipeline, remaining, outputCtx, packet, errorBuffer, errorBufferSize);
}

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
) {
    if (errorBuffer && errorBufferSize > 0) errorBuffer[0] = '\0';

    AVFormatContext *inputCtx = NULL;
    AVFormatContext *outputCtx = NULL;
    AVPacket *packet = NULL;
    AVFrame *decodedFrame = NULL;
    AVFrame *filteredFrame = NULL;

    CFFmpegStreamPipeline video = {0};
    CFFmpegStreamPipeline audio = {0};
    video.inputStreamIndex = -1;
    audio.inputStreamIndex = -1;

    int wantsAudio = options->audioCodecName && options->audioCodecName[0] && !options->isGifTarget;
    int result = 0;

    int ret = avformat_open_input(&inputCtx, inputPath, NULL, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening input failed", ret);
        result = ret;
        goto cleanup;
    }

    ret = avformat_find_stream_info(inputCtx, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Reading input stream info failed", ret);
        result = ret;
        goto cleanup;
    }

    video.inputStreamIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (video.inputStreamIndex < 0) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "No video stream found in input");
        result = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }

    if (wantsAudio) {
        audio.inputStreamIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
        if (audio.inputStreamIndex < 0) {
            wantsAudio = 0; // source simply has no audio track — not an error.
        }
    }

    ret = cffmpeg_open_decoder(inputCtx, video.inputStreamIndex, &video.decoderCtx, errorBuffer, errorBufferSize);
    if (ret < 0) { result = ret; goto cleanup; }

    if (wantsAudio) {
        ret = cffmpeg_open_decoder(inputCtx, audio.inputStreamIndex, &audio.decoderCtx, errorBuffer, errorBufferSize);
        if (ret < 0) { result = ret; goto cleanup; }
    }

    AVRational videoInputTimeBase = inputCtx->streams[video.inputStreamIndex]->time_base;
    ret = cffmpeg_init_video_filter_graph(video.decoderCtx, videoInputTimeBase, options,
                                          &video.filterGraph, &video.bufferSrcCtx, &video.bufferSinkCtx,
                                          errorBuffer, errorBufferSize);
    if (ret < 0) { result = ret; goto cleanup; }

    ret = avformat_alloc_output_context2(&outputCtx, NULL, outputFormatName, outputPath);
    if (ret < 0 || !outputCtx) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Allocating output context failed", ret < 0 ? ret : AVERROR_UNKNOWN);
        result = ret < 0 ? ret : AVERROR_UNKNOWN;
        goto cleanup;
    }

    // buffer/buffersink preserve the decoder's original time_base.
    ret = cffmpeg_open_video_encoder(options, outputCtx, videoInputTimeBase, &video.encoderCtx, &video.outputStream,
                                      errorBuffer, errorBufferSize);
    if (ret < 0) { result = ret; goto cleanup; }

    enum AVSampleFormat audioSampleFormat = AV_SAMPLE_FMT_NONE;
    int audioSampleRate = 44100;
    if (wantsAudio) {
        // Opus only accepts 8/12/16/24/48 kHz — 44100 (fine for AAC/ALAC/PCM)
        // fails encoder setup outright for it. audioCodecName is NULL
        // whenever there's no audio at all (gif targets, stripped audio),
        // so this check must stay inside the wantsAudio guard.
        if (strcmp(options->audioCodecName, "libopus") == 0) {
            audioSampleRate = 48000;
        }
        const AVCodec *audioEncoder = avcodec_find_encoder_by_name(options->audioCodecName);
        if (!audioEncoder) {
            cffmpeg_set_error(errorBuffer, errorBufferSize, "Audio encoder not found (was it enabled in this FFmpeg build?)");
            result = AVERROR_ENCODER_NOT_FOUND;
            goto cleanup;
        }
        audioSampleFormat = (audioEncoder->sample_fmts && audioEncoder->sample_fmts[0] != AV_SAMPLE_FMT_NONE)
            ? audioEncoder->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;

        AVRational audioInputTimeBase = inputCtx->streams[audio.inputStreamIndex]->time_base;
        ret = cffmpeg_init_audio_filter_graph(audio.decoderCtx, audioInputTimeBase, audioSampleFormat, audioSampleRate,
                                              &audio.filterGraph, &audio.bufferSrcCtx, &audio.bufferSinkCtx,
                                              errorBuffer, errorBufferSize);
        if (ret < 0) { result = ret; goto cleanup; }

        ret = cffmpeg_open_audio_encoder(options, outputCtx, audioSampleFormat, audioSampleRate,
                                         &audio.encoderCtx, &audio.outputStream, errorBuffer, errorBufferSize);
        if (ret < 0) { result = ret; goto cleanup; }
    }

    if (!(outputCtx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&outputCtx->pb, outputPath, AVIO_FLAG_WRITE);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Opening output file failed", ret);
            result = ret;
            goto cleanup;
        }
    }

    if (options->isGifTarget) {
        av_opt_set_int(outputCtx->priv_data, "loop", options->gifLoopCount, 0);
    }

    ret = avformat_write_header(outputCtx, NULL);
    if (ret < 0) {
        cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing output header failed", ret);
        result = ret;
        goto cleanup;
    }

    packet = av_packet_alloc();
    decodedFrame = av_frame_alloc();
    filteredFrame = av_frame_alloc();
    if (!packet || !decodedFrame || !filteredFrame) {
        cffmpeg_set_error(errorBuffer, errorBufferSize, "Could not allocate packet/frame buffers");
        result = AVERROR(ENOMEM);
        goto cleanup;
    }

    double totalDuration = options->trimEnd - options->trimStart;
    if (totalDuration <= 0) totalDuration = 0.001;
    int cancelled = 0;

    while (av_read_frame(inputCtx, packet) >= 0) {
        if (shouldCancelCallback && shouldCancelCallback(cancelContext)) {
            cancelled = 1;
            av_packet_unref(packet);
            break;
        }

        CFFmpegStreamPipeline *pipeline = NULL;
        if (packet->stream_index == video.inputStreamIndex) {
            pipeline = &video;
        } else if (wantsAudio && packet->stream_index == audio.inputStreamIndex) {
            pipeline = &audio;
        } else {
            av_packet_unref(packet);
            continue;
        }

        ret = avcodec_send_packet(pipeline->decoderCtx, packet);
        av_packet_unref(packet);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Sending packet to decoder failed", ret);
            result = ret;
            goto cleanup;
        }

        while (avcodec_receive_frame(pipeline->decoderCtx, decodedFrame) == 0) {
            AVRational streamTimeBase = inputCtx->streams[pipeline->inputStreamIndex]->time_base;
            // best_effort_timestamp falls back through pkt_dts when a
            // decoder leaves pts itself unset — more reliable than raw pts.
            int64_t timestamp = decodedFrame->best_effort_timestamp;
            double framePts = timestamp == AV_NOPTS_VALUE
                ? 0.0 : timestamp * av_q2d(streamTimeBase);

            if (framePts < options->trimStart) {
                av_frame_unref(decodedFrame);
                continue;
            }
            if (framePts > options->trimEnd) {
                av_frame_unref(decodedFrame);
                continue;
            }

            // Rebase so the output timeline starts at 0 at trimStart,
            // rather than carrying the source's original timestamps through.
            if (timestamp != AV_NOPTS_VALUE) {
                int64_t trimStartTicks = (int64_t)llround(options->trimStart / av_q2d(streamTimeBase));
                decodedFrame->pts = timestamp - trimStartTicks;
            }

            ret = av_buffersrc_add_frame_flags(pipeline->bufferSrcCtx, decodedFrame, AV_BUFFERSRC_FLAG_KEEP_REF);
            av_frame_unref(decodedFrame);
            if (ret < 0) {
                cffmpeg_set_averror(errorBuffer, errorBufferSize, "Feeding filter graph failed", ret);
                result = ret;
                goto cleanup;
            }

            // Per decoded frame, not per filtered-output frame — gif's
            // palette filter graph buffers everything and emits nothing
            // from buffersink until EOF, which left progress pinned at 0%
            // until a final burst at the end.
            if (pipeline == &video) {
                if (progressCallback) progressCallback((framePts - options->trimStart) / totalDuration, progressContext);
            }

            AVRational sinkTimeBase = av_buffersink_get_time_base(pipeline->bufferSinkCtx);
            while (av_buffersink_get_frame(pipeline->bufferSinkCtx, filteredFrame) == 0) {
                if (pipeline == &audio) {
                    ret = cffmpeg_push_audio_frame(pipeline, filteredFrame, outputCtx, packet, errorBuffer, errorBufferSize);
                } else {
                    ret = cffmpeg_encode_and_write(pipeline->encoderCtx, outputCtx, pipeline->outputStream,
                                                   filteredFrame, sinkTimeBase, packet, errorBuffer, errorBufferSize);
                }
                av_frame_unref(filteredFrame);
                if (ret < 0) { result = ret; goto cleanup; }
            }
        }
    }

    if (!cancelled) {
        // Flush: decoder -> filter -> encoder for each pipeline, then encoder alone.
        CFFmpegStreamPipeline *pipelines[2] = {&video, wantsAudio ? &audio : NULL};
        for (int i = 0; i < 2; i++) {
            CFFmpegStreamPipeline *pipeline = pipelines[i];
            if (!pipeline || !pipeline->decoderCtx) continue;

            AVRational pipelineTimeBase = inputCtx->streams[pipeline->inputStreamIndex]->time_base;
            avcodec_send_packet(pipeline->decoderCtx, NULL);
            while (avcodec_receive_frame(pipeline->decoderCtx, decodedFrame) == 0) {
                int64_t timestamp = decodedFrame->best_effort_timestamp;
                double framePts = timestamp == AV_NOPTS_VALUE ? 0.0 : timestamp * av_q2d(pipelineTimeBase);
                if (framePts < options->trimStart || framePts > options->trimEnd) {
                    av_frame_unref(decodedFrame);
                    continue;
                }
                if (timestamp != AV_NOPTS_VALUE) {
                    int64_t trimStartTicks = (int64_t)llround(options->trimStart / av_q2d(pipelineTimeBase));
                    decodedFrame->pts = timestamp - trimStartTicks;
                }
                (void)av_buffersrc_add_frame_flags(pipeline->bufferSrcCtx, decodedFrame, AV_BUFFERSRC_FLAG_KEEP_REF);
                av_frame_unref(decodedFrame);
                AVRational sinkTimeBase = av_buffersink_get_time_base(pipeline->bufferSinkCtx);
                while (av_buffersink_get_frame(pipeline->bufferSinkCtx, filteredFrame) == 0) {
                    if (pipeline == &audio) {
                        ret = cffmpeg_push_audio_frame(pipeline, filteredFrame, outputCtx, packet, errorBuffer, errorBufferSize);
                    } else {
                        ret = cffmpeg_encode_and_write(pipeline->encoderCtx, outputCtx, pipeline->outputStream,
                                                       filteredFrame, sinkTimeBase, packet, errorBuffer, errorBufferSize);
                    }
                    av_frame_unref(filteredFrame);
                    if (ret < 0) { result = ret; goto cleanup; }
                }
            }

            AVRational sinkTimeBase = av_buffersink_get_time_base(pipeline->bufferSinkCtx);
            (void)av_buffersrc_add_frame_flags(pipeline->bufferSrcCtx, NULL, 0);
            while (av_buffersink_get_frame(pipeline->bufferSinkCtx, filteredFrame) == 0) {
                if (pipeline == &audio) {
                    ret = cffmpeg_push_audio_frame(pipeline, filteredFrame, outputCtx, packet, errorBuffer, errorBufferSize);
                } else {
                    ret = cffmpeg_encode_and_write(pipeline->encoderCtx, outputCtx, pipeline->outputStream,
                                                   filteredFrame, sinkTimeBase, packet, errorBuffer, errorBufferSize);
                }
                av_frame_unref(filteredFrame);
                if (ret < 0) { result = ret; goto cleanup; }
            }

            if (pipeline == &audio) {
                ret = cffmpeg_flush_audio_fifo(pipeline, outputCtx, packet, errorBuffer, errorBufferSize);
                if (ret < 0) { result = ret; goto cleanup; }
            }

            ret = cffmpeg_encode_and_write(pipeline->encoderCtx, outputCtx, pipeline->outputStream,
                                           NULL, sinkTimeBase, packet, errorBuffer, errorBufferSize);
            if (ret < 0) { result = ret; goto cleanup; }
        }

        ret = av_write_trailer(outputCtx);
        if (ret < 0) {
            cffmpeg_set_averror(errorBuffer, errorBufferSize, "Writing output trailer failed", ret);
            result = ret;
            goto cleanup;
        }
        if (progressCallback) progressCallback(1.0, progressContext);
    } else {
        result = 1;
    }

cleanup:
    if (packet) av_packet_free(&packet);
    if (decodedFrame) av_frame_free(&decodedFrame);
    if (filteredFrame) av_frame_free(&filteredFrame);
    cffmpeg_free_pipeline(&video);
    cffmpeg_free_pipeline(&audio);
    if (outputCtx) {
        if (!(outputCtx->oformat->flags & AVFMT_NOFILE) && outputCtx->pb) {
            avio_closep(&outputCtx->pb);
        }
        avformat_free_context(outputCtx);
    }
    if (inputCtx) avformat_close_input(&inputCtx);

    return result;
}
