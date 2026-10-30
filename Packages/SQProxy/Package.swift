// swift-tools-version: 6.2
import PackageDescription

#if os(Windows)
// Windows (the Windows port plan, seam 5): the portable part only: model, cache, queue, policy, provider and the
// `ProxyTranscoding` / `SourceSeekProbing` seams. The AVFoundation transcoders and prober are Mac-only (a Windows
// FFmpeg transcoder plugs into the seams later). A new source file that imports an Apple framework goes on this list.
let appleOnly = ["AVSourceSeekProber.swift", "ProxyTranscoder.swift", "WebMProxyTranscoder.swift"]
let appleOnlyTests = [
    "AlphaProxyTests.swift", "DeinterlaceProxyTests.swift", "IntegrationTests.swift", "PixelAspectProxyTests.swift",
    "WebMProxyTests.swift",
]
let package = Package(
    name: "SQProxy",
    products: [.library(name: "SQProxy", targets: ["SQProxy"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQProxy", dependencies: ["SQCore", "SQMedia"], exclude: appleOnly),
        .testTarget(name: "SQProxyTests", dependencies: ["SQCore", "SQProxy"], exclude: appleOnlyTests),
    ]
)
#else
let package = Package(
    name: "SQProxy",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQProxy", targets: ["SQProxy"]),
    ],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQProxy", dependencies: ["SQCore", "SQMedia"]),
        .testTarget(name: "SQProxyTests", dependencies: ["SQCore", "SQProxy", .product(name: "SQMediaTestSupport", package: "SQMedia")]),
    ]
)
#endif
