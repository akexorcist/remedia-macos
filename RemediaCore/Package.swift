// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemediaCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "RemediaCore",
            targets: ["RemediaCore"]
        )
    ],
    targets: [
        // Vendored via Scripts/build-ffmpeg.sh (ARCHITECTURE §7) — static
        // libraries packaged as local xcframeworks under Vendor/FFmpeg.
        .binaryTarget(name: "libavformat", path: "../Vendor/FFmpeg/libavformat.xcframework"),
        .binaryTarget(name: "libavcodec", path: "../Vendor/FFmpeg/libavcodec.xcframework"),
        .binaryTarget(name: "libavutil", path: "../Vendor/FFmpeg/libavutil.xcframework"),
        .binaryTarget(name: "libswscale", path: "../Vendor/FFmpeg/libswscale.xcframework"),
        .binaryTarget(name: "libavfilter", path: "../Vendor/FFmpeg/libavfilter.xcframework"),
        .binaryTarget(name: "libswresample", path: "../Vendor/FFmpeg/libswresample.xcframework"),
        .binaryTarget(name: "libvpx", path: "../Vendor/FFmpeg/libvpx.xcframework"),
        .binaryTarget(name: "libopus", path: "../Vendor/FFmpeg/libopus.xcframework"),
        .target(
            name: "CFFmpeg",
            dependencies: [
                "libavformat", "libavcodec", "libavutil", "libswscale",
                "libavfilter", "libswresample", "libvpx", "libopus"
            ],
            path: "Sources/CFFmpeg",
            linkerSettings: [
                // System libs FFmpeg's configure auto-detected and links
                // against: zlib (PNG/TIFF/flashsv/etc. decode), iconv
                // (subtitle charset conversion), bz2 (optional Matroska/WebM
                // header compression support in matroskadec.o — only hit for
                // some files, but the symbols must still resolve), OpenGL
                // (the "coreimage" avfilter wrapper — NSOpenGLPixelFormat is
                // an AppKit class despite the OpenGL name), VideoToolbox
                // (hardware H.264/HEVC encode/decode).
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedLibrary("bz2"),
                .linkedFramework("OpenGL"),
                .linkedFramework("AppKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(
            name: "RemediaCore",
            dependencies: ["CFFmpeg"],
            path: "Sources/RemediaCore"
        ),
        .testTarget(
            name: "RemediaCoreTests",
            dependencies: ["RemediaCore", "CFFmpeg"],
            path: "Tests/RemediaCoreTests",
            // Real sample media for tests that want more than the synthetic
            // fixtures (rotation metadata, real audio, B-frames, etc.) —
            // copied into the *test bundle* only via Bundle.module. The app
            // target has no reference to this path at all, so nothing here
            // ships in the built .app.
            resources: [.copy("Fixtures")]
        )
    ]
)
