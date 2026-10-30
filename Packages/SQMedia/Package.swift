// swift-tools-version: 6.2
import PackageDescription

#if os(Windows)
// Windows (the Windows port plan, seam 3): the portable part of SQMedia only (protocols `Demuxing`, `VideoDecoding`,
// `AudioSource`, sample index, MXF/WebM parsing, metadata). Files that need AVFoundation, VideoToolbox, CoreMedia,
// CoreVideo, ImageIO or Accelerate are left out here; the Windows implementation lives in Packages/SQMediaFFmpeg.
// A new source file that imports an Apple framework goes on this list.
let appleOnly = [
    "AnglesSync.swift", "AnimatedImage.swift", "AudioChannelRouting.swift", "AudioSource.swift", "ColorDetection.swift",
    "Deinterlacer.swift", "Demuxer.swift", "ImageSampleDecoder.swift", "MXF", "MonoAudioDecoder.swift",
    "MediaBookmark.swift", "MediaDiagnosis.swift", "MediaImporter.swift", "MediaRobustness.swift",
    "MultiTrackAudio.swift", "PNGFastDecoder.swift", "PeakAccumulator.swift", "PixelAspectTag.swift", "RLEDecoder.swift",
    "Relink.swift", "ShootMetadata.swift", "SpeechRenderer.swift", "StillImage.swift", "Thumbnailer.swift",
    "UncachedFileDemuxer.swift", "VFRConform.swift", "VideoDecoder.swift", "Waveform.swift", "WaveformDiskCache.swift",
    "WebM/VorbisDecoder.swift", "WebM/WebMAudioSource.swift", "WebM/WebMDemuxer.swift", "WebM/WebMReadback.swift", "WebM/WebMStill.swift",
]
// MXF (needs CoreMedia formats and the MXF demuxer), mono decode and the waveform cache sit on Apple-only types.
// Tests that need no Apple framework and no SQMediaTestSupport (which writes clips with AVFoundation).
let portableTests = [
    "EmbeddedLUTTests.swift", "MediaCollectTests.swift", "PeakPyramidTests.swift", "SQMediaTests.swift", "SampleIndexTests.swift", "SonyMetadataTests.swift",
    "SourceTimecodeTests.swift", "TimingSupport.swift", "ToneAudioSourceTests.swift", "WebMTestWriter.swift",
]
let package = Package(
    name: "SQMedia",
    products: [.library(name: "SQMedia", targets: ["SQMedia"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQAudioFX"), .package(path: "../SQFrame")],
    targets: [
        .target(name: "SQMedia", dependencies: ["SQCore", "SQAudioFX", .product(name: "SQFrame", package: "SQFrame"),
                                               .product(name: "SQFrameCoreVideo", package: "SQFrame")],
                exclude: appleOnly),
        .testTarget(name: "SQMediaTests", dependencies: ["SQCore", "SQAudioFX", "SQMedia"], sources: portableTests),
    ]
)
#else
let package = Package(
    name: "SQMedia",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQMedia", targets: ["SQMedia"]),
        .library(name: "SQMediaTestSupport", targets: ["SQMediaTestSupport"]),
    ],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQAudioFX"), .package(path: "../SQFrame")],
    targets: [
        .target(name: "SQMedia", dependencies: ["SQCore", "SQAudioFX",
                                               .product(name: "SQFrame", package: "SQFrame"),
                                               .product(name: "SQFrameCoreVideo", package: "SQFrame")]),
        .target(name: "SQMediaTestSupport", path: "Sources/SQMediaTestSupport"),
        .testTarget(name: "SQMediaTests", dependencies: ["SQCore", "SQAudioFX", "SQMedia", "SQMediaTestSupport"]),
    ]
)
#endif
