#ifndef CFFMPEG_INTERNAL_H
#define CFFMPEG_INTERNAL_H

#include "CFFmpeg.h"

// Shared between transcode.c and preview_decode.c — not part of the public
// CFFmpeg.h API surface, just internal-linkage-avoidance.

void cffmpeg_set_error(char *errorBuffer, int errorBufferSize, const char *message);
void cffmpeg_set_averror(char *errorBuffer, int errorBufferSize, const char *context, int averror);

int cffmpeg_open_decoder(
    AVFormatContext *inputCtx,
    int streamIndex,
    AVCodecContext **outDecoderCtx,
    char *errorBuffer,
    int errorBufferSize
);

#endif
