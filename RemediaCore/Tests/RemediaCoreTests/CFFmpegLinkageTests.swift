import Testing
import CFFmpeg

// Proves the vendored FFmpeg xcframeworks actually link, not just compile
// against headers — a clean `swift build` alone doesn't force the linker to
// resolve any of these symbols unless something actually calls them.
@Test func vendoredFFmpegLibrariesLinkAndReportVersions() {
    let version = String(cString: cffmpeg_version_info())
    #expect(!version.isEmpty)
    #expect(cffmpeg_avformat_version() > 0)
    #expect(cffmpeg_avcodec_version() > 0)
    #expect(cffmpeg_avfilter_version() > 0)
}

@Test func libvpxAndLibopusWrapperEncodersAreCompiledIn() {
    #expect(cffmpeg_has_libvpx_vp9_encoder() == 1)
    #expect(cffmpeg_has_libopus_encoder() == 1)
}
