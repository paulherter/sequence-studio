// swift-tools-version: 6.0
// Phase 0 spike (the Windows port plan): D3D12 window + one FFmpeg frame. Windows only, not part of the Mac build.
import Foundation
import PackageDescription

let ff = ProcessInfo.processInfo.environment["SQ_FFMPEG"]
    ?? (ProcessInfo.processInfo.environment["USERPROFILE"] ?? "C:").appending("/ffmpeg/ffmpeg-master-latest-win64-lgpl-shared")

let package = Package(
    name: "SQWinSpike",
    targets: [
        .target(
            name: "CSQWin",
            cxxSettings: [.unsafeFlags(["-I\(ff)/include"])]
        ),
        .target(name: "SQDrawKit"),  // shared draw list, pure Swift
        .executableTarget(name: "SQDrawMac", dependencies: ["SQDrawKit"]),  // Mac renderer (stub on Windows)
        .executableTarget(name: "SQGradeMac"),  // Mac Metal side of the shader check (stub on Windows)
        .executableTarget(
            name: "SQWinSpike",
            dependencies: ["CSQWin", "SQDrawKit"],
            linkerSettings: [
                .unsafeFlags(["-L\(ff)/lib"]),
                .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
