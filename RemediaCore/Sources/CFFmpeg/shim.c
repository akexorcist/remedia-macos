#include "CFFmpeg.h"

int cffmpeg_shim_is_stub(void) {
    return 1;
}

const char *cffmpeg_version_info(void) {
    return av_version_info();
}

unsigned cffmpeg_avformat_version(void) {
    return avformat_version();
}

unsigned cffmpeg_avcodec_version(void) {
    return avcodec_version();
}

unsigned cffmpeg_avfilter_version(void) {
    return avfilter_version();
}

int cffmpeg_has_libvpx_vp9_encoder(void) {
    return avcodec_find_encoder_by_name("libvpx-vp9") != NULL;
}

int cffmpeg_has_libopus_encoder(void) {
    return avcodec_find_encoder_by_name("libopus") != NULL;
}
