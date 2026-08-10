#!/usr/bin/env bash
#
# Builds libvpx, libopus, and FFmpeg (libavformat/libavcodec/libavutil/
# libswscale/libavfilter) as arm64-macOS static libraries, then packages each
# as an .xcframework under Vendor/FFmpeg/ (ARCHITECTURE §7 open item).
#
# STATUS: skeleton — documents the real steps/flags this needs; not yet run
# end-to-end. Fill in TODOs below before relying on it. Requires network
# access to fetch sources, which this scaffold pass didn't attempt.
#
# Apple Silicon only (REQUIREMENTS §2/ARCHITECTURE §1) — no x86_64 slice.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.ffmpeg-build"
VENDOR_DIR="${ROOT_DIR}/Vendor/FFmpeg"
MACOS_DEPLOYMENT_TARGET="26.0"
ARCH="arm64"

# TODO: pin exact versions/tags before running for real.
LIBVPX_REF="v1.14.1"
LIBOPUS_REF="v1.5.2"
FFMPEG_REF="n7.1"

mkdir -p "${BUILD_DIR}" "${VENDOR_DIR}"

fetch_source() {
    local name="$1" repo_url="$2" ref="$3"
    local dest="${BUILD_DIR}/${name}"
    if [[ -d "${dest}" ]]; then
        echo "==> ${name} already fetched, skipping clone"
        return
    fi
    echo "==> Fetching ${name} (${ref})"
    git clone --depth 1 --branch "${ref}" "${repo_url}" "${dest}"
}

build_libvpx() {
    echo "==> Building libvpx"
    local src="${BUILD_DIR}/libvpx"
    local out="${BUILD_DIR}/out/libvpx"
    (
        cd "${src}"
        ./configure \
            --target=arm64-darwin20-gcc \
            --disable-examples \
            --disable-unit-tests \
            --disable-docs \
            --enable-vp8 \
            --enable-vp9 \
            --enable-static \
            --disable-shared \
            --prefix="${out}"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
}

build_libopus() {
    echo "==> Building libopus"
    local src="${BUILD_DIR}/libopus"
    local out="${BUILD_DIR}/out/libopus"
    (
        cd "${src}"
        ./autogen.sh
        ./configure \
            --host=arm64-apple-darwin \
            --enable-static \
            --disable-shared \
            --prefix="${out}"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
}

build_ffmpeg() {
    echo "==> Building FFmpeg (libavformat/libavcodec/libavutil/libswscale/libavfilter)"
    local src="${BUILD_DIR}/ffmpeg"
    local out="${BUILD_DIR}/out/ffmpeg"
    local vpx_out="${BUILD_DIR}/out/libvpx"
    local opus_out="${BUILD_DIR}/out/libopus"
    (
        cd "${src}"
        ./configure \
            --arch=arm64 \
            --target-os=darwin \
            --extra-cflags="-arch ${ARCH} -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET} -I${vpx_out}/include -I${opus_out}/include" \
            --extra-ldflags="-arch ${ARCH} -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET} -L${vpx_out}/lib -L${opus_out}/lib" \
            --pkg-config-flags="--static" \
            --enable-static \
            --disable-shared \
            --disable-programs \
            --disable-doc \
            --disable-avdevice \
            --disable-postproc \
            --enable-libvpx \
            --enable-libopus \
            --enable-gpl \
            --prefix="${out}"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
}

# Wraps a static .a (+ headers) into an .xcframework for a single library.
package_xcframework() {
    local lib_name="$1" static_lib_path="$2" headers_path="$3"
    echo "==> Packaging ${lib_name}.xcframework"
    xcodebuild -create-xcframework \
        -library "${static_lib_path}" -headers "${headers_path}" \
        -output "${VENDOR_DIR}/${lib_name}.xcframework"
}

main() {
    fetch_source "libvpx" "https://chromium.googlesource.com/webm/libvpx" "${LIBVPX_REF}"
    fetch_source "libopus" "https://github.com/xiph/opus.git" "${LIBOPUS_REF}"
    fetch_source "ffmpeg" "https://github.com/FFmpeg/FFmpeg.git" "${FFMPEG_REF}"

    build_libvpx
    build_libopus
    build_ffmpeg

    package_xcframework "libvpx" "${BUILD_DIR}/out/libvpx/lib/libvpx.a" "${BUILD_DIR}/out/libvpx/include"
    package_xcframework "libopus" "${BUILD_DIR}/out/libopus/lib/libopus.a" "${BUILD_DIR}/out/libopus/include"
    for lib in avformat avcodec avutil swscale avfilter; do
        package_xcframework "lib${lib}" "${BUILD_DIR}/out/ffmpeg/lib/lib${lib}.a" "${BUILD_DIR}/out/ffmpeg/include"
    done

    echo "==> Done. See Vendor/FFmpeg/README.md for the remaining wiring steps."
}

main "$@"
