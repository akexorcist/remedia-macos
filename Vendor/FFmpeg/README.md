# Vendor/FFmpeg

Real, built FFmpeg (+ libvpx + libopus) static libraries, packaged as local
xcframeworks and linked into `CFFmpeg` (ARCHITECTURE §1/§7). Built via
`Scripts/build-ffmpeg.sh`'s process on 2026-08-04:

```
Vendor/FFmpeg/
├── libavformat.xcframework
├── libavcodec.xcframework
├── libavutil.xcframework
├── libswscale.xcframework
├── libavfilter.xcframework
├── libswresample.xcframework
├── libvpx.xcframework
└── libopus.xcframework
```

Configured with `--enable-libvpx --enable-libopus`, no `--enable-gpl` needed
(vpx/opus are both permissively licensed) — `ffmpeg`'s own configure reports
`License: LGPL version 2.1 or later` for this build.

## Headers are vendored separately, inside the package

The actual public headers used by `CFFmpeg` live at
`MediaConverterCore/Sources/CFFmpeg/include/{libavformat,libavcodec,libavutil,
libswscale,libavfilter,libswresample,vpx,opus}/`, copied in from the same
build — **not** read from these xcframeworks' own embedded `Headers/`
directories. This split exists because Xcode's package-graph integration
(unlike plain `swift build`) doesn't reliably expose a local static-library
binaryTarget's headers to a sibling regular target's clang dependency
scanner — headers had to be placed directly inside `CFFmpeg`'s own default
public-headers directory (`Sources/CFFmpeg/include/`) for Xcode's build to
find them at all. The xcframeworks here are relied on purely for linking the
compiled `.a` binaries via `Package.swift`'s `binaryTarget` declarations.

If FFmpeg is ever rebuilt (different version, different enabled
codecs/filters), **both** places need updating: the `.xcframework`s here, and
the header copies under `MediaConverterCore/Sources/CFFmpeg/include/`.

## Verifying the vendoring is real, not just headers-that-compile

`MediaConverterCore/Tests/MediaConverterCoreTests/CFFmpegLinkageTests.swift`
calls real `libavformat`/`libavcodec`/`libavfilter` functions and checks that
`avcodec_find_encoder_by_name("libvpx-vp9")` /
`avcodec_find_encoder_by_name("libopus")` return non-null — i.e. that the
wrapper encoders were actually compiled in and linked, not just that the
headers parse.

## Rebuilding from scratch

`Scripts/build-ffmpeg.sh` documents the full process (clone libvpx/libopus/
FFmpeg, configure, build, install, package as xcframeworks). Prerequisites
installed via Homebrew for this build: `autoconf`, `automake`, `libtool`
(GNU, not Apple's `/usr/bin/libtool` — needed for `opus`'s `autogen.sh`,
which fails with `undefined or overquoted macro: AM_PROG_LIBTOOL` without
it). System libraries FFmpeg links against on macOS: `libz`, `libiconv`,
`VideoToolbox.framework` — declared in `MediaConverterCore/Package.swift`'s
`CFFmpeg` target `linkerSettings`.
