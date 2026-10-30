// swift-tools-version: 6.2
// Windows implementation of the media seams (the Windows port plan, seam 3): FFmpeg demux and decode (D3D11VA hardware,
// software fallback), audio decode, export encode (AMF / NVENC / Quick Sync / Media Foundation H.264 and HEVC, AAC) and
// WASAPI output, behind SQMedia's `Demuxing` / `VideoDecoding` / `AudioSource`, SQPlayback's `AudioPlaying` and SQExport's
// `ExportEncoding`. FFmpeg is the LGPL shared build (`SQ_FFMPEG`, default below); its `bin` folder must be on PATH at
// run time. On the Mac only the shared core builds (the Mac uses AVFoundation / VideoToolbox / CoreAudio).
import Foundation
import PackageDescription

// SQMediaFFmpegCore holds the pure timing and decode-order logic (built and tested on both platforms).
let core: [Target] = [
    .target(name: "SQMediaFFmpegCore", dependencies: ["SQCore", "SQMedia"]),
    .testTarget(name: "SQMediaFFmpegCoreTests", dependencies: ["SQMediaFFmpegCore", "SQCore", "SQMedia"]),
]

#if os(Windows)
let ff = (ProcessInfo.processInfo.environment["SQ_FFMPEG"] ?? (ProcessInfo.processInfo.environment["USERPROFILE"] ?? "C:").appending("/ffmpeg/ffmpeg-master-latest-win64-lgpl-shared"))
    .replacingOccurrences(of: "\\", with: "/")
let package = Package(
    name: "SQMediaFFmpeg",
    products: [.library(name: "SQMediaFFmpeg", targets: ["SQMediaFFmpeg"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQFrame"), .package(path: "../SQMedia"),
                   .package(path: "../SQPlayback"), .package(path: "../SQExport"), .package(path: "../SQAudioFX")],
    targets: core + [
        .target(
            name: "CSQFFmpeg",
            cxxSettings: [.unsafeFlags(["-I\(ff)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L\(ff)/lib"]),
                .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                .linkedLibrary("swscale"), .linkedLibrary("swresample"), .linkedLibrary("ole32"),
            ]
        ),
        .target(name: "SQMediaFFmpeg", dependencies: [
            "CSQFFmpeg", "SQMediaFFmpegCore", "SQCore", .product(name: "SQFrame", package: "SQFrame"), "SQMedia",
            "SQPlayback", "SQExport", "SQAudioFX",
        ]),
        .testTarget(name: "SQMediaFFmpegTests", dependencies: [
            "SQMediaFFmpeg", "SQMediaFFmpegCore", "SQCore", .product(name: "SQFrame", package: "SQFrame"), "SQMedia",
            "SQPlayback", "SQExport",
        ]),
    ],
    cxxLanguageStandard: .cxx17
)
#else
// The Mac uses AVFoundation / VideoToolbox / CoreAudio: only the shared core is built here.
let package = Package(
    name: "SQMediaFFmpeg",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQMediaFFmpegCore", targets: ["SQMediaFFmpegCore"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: core
)
#endif
