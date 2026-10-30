// swift-tools-version: 6.2
import PackageDescription

#if os(Windows)
// Windows (the Windows port plan, seam 5): the portable part only: transcript model, editing, captions, subtitle readers,
// sequence mapping and the `TranscriptionService` seam. The Speech engine and the AVFoundation audio extraction are
// Mac-only. A new source file that imports an Apple framework goes on this list.
let appleOnly = ["AudioExtraction.swift", "SpeechTranscription.swift"]
let appleOnlyTests = [
    "ChannelMappedTranscriptionTests.swift", "SpeechTranscriptionTests.swift", "WebMAudioExtractionTests.swift",
    "WordConfidenceFollowUpTests.swift", "WordTokenTests.swift",
]
let package = Package(
    name: "SQTranscribe",
    products: [.library(name: "SQTranscribe", targets: ["SQTranscribe"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "CSQWhisper"),
        .target(name: "SQTranscribe", dependencies: ["SQCore", "SQMedia", "CSQWhisper"], exclude: appleOnly),
        .testTarget(name: "SQTranscribeTests", dependencies: ["SQCore", "SQTranscribe"], exclude: appleOnlyTests),
    ]
)
#else
let package = Package(
    name: "SQTranscribe",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQTranscribe", targets: ["SQTranscribe"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "CSQWhisper"),
        .target(name: "SQTranscribe", dependencies: ["SQCore", "SQMedia", "CSQWhisper"]),
        .testTarget(name: "SQTranscribeTests", dependencies: ["SQCore", "SQTranscribe"]),
    ]
)
#endif
