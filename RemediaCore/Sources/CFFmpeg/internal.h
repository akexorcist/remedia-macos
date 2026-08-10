#ifndef CFFMPEG_INTERNAL_H
#define CFFMPEG_INTERNAL_H

#include "CFFmpeg.h"
#include <math.h>

// Shared between transcode.c, preview_decode.c, sequential_decode.c, and
// probe.c — not part of the public CFFmpeg.h API surface, just
// internal-linkage-avoidance.

void cffmpeg_set_error(char *errorBuffer, int errorBufferSize, const char *message);
void cffmpeg_set_averror(char *errorBuffer, int errorBufferSize, const char *context, int averror);

int cffmpeg_open_decoder(
    AVFormatContext *inputCtx,
    int streamIndex,
    AVCodecContext **outDecoderCtx,
    char *errorBuffer,
    int errorBufferSize
);

// sample_aspect_ratio comes straight from container metadata (e.g. a
// Matroska/WebM DisplayWidth tag) and can be adversarial or simply corrupt.
// A raw `codedWidth * sar.num/sar.den` can overflow int and wrap, desyncing
// a malloc'd buffer's size from what sws_scale is told to write — fall back
// to the coded width instead of trusting an out-of-range result.
static inline int cffmpeg_sanitized_display_width(int codedWidth, AVRational sar) {
    if (sar.num <= 0 || sar.den <= 0 || sar.num == sar.den) return codedWidth;
    double scaled = (double)codedWidth * ((double)sar.num / sar.den);
    if (!(scaled >= 1.0) || scaled > 16384.0) return codedWidth;
    return (int)llround(scaled);
}

#endif
