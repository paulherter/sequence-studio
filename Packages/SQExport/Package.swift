// swift-tools-version: 6.2
import PackageDescription

#if os(Windows)
// Windows (the Windows port plan, seam 3): the portable part of SQExport only: settings, presets, the `FrameSource` /
// `AudioSource` / `ExportEncoding` protocols, the export queue, loudness, interchange and caption writers. The AVFoundation
// writer, the Metal timeline frame source and burn-in are left out; the Windows encoder lives in Packages/SQMediaFFmpeg.
// A new source file that imports an Apple framework or SQRender/SQAnalysis/SQLottie/SQTranscribe goes on this list.
let appleOnly = [
    "CaptionBurnIn.swift", "CoverImageWriter.swift", "DecoderFrameProvider.swift", "EncoderSpeedSession.swift",
    "ExportShaderSource.swift", "ExportSourceBuilder.swift", "ExportWriter.swift", "FrameOutputWriter.swift",
    "FrameStillWriter.swift", "RenderCacheSegmentWriter.swift", "SmartRenderWriter.swift",
    "TestPatternSource.swift", "TimelineFrameSource.swift",
]
// Tests that need neither an Apple framework nor the Mac-only modules (the queue tests write real files through
// `ExportWriter`; on Windows the FFmpeg encoder is tested in SQMediaFFmpeg).
let portableTests = [
    "AudioChainParityTests.swift", "BakeLiveDuckParityTests.swift", "BlockingReadQueue.swift", "DeliveryAdviceTests.swift",
    "DeliveryCheckTests.swift", "DeliveryTargetPresetTests.swift", "FrameStillPixelsTests.swift", "GIFPaletteTests.swift", "ExportProgressMathTests.swift", "ITTWriterTests.swift",
    "InstagramPresetTests.swift", "LiveDuckingSilenceParityTests.swift", "LoudnessDefaultsTests.swift",
    "LoudnessLimitingTests.swift", "MarkerCSVTests.swift", "PixelShapeVariantTests.swift", "PlatformSpecSoftLimitTests.swift",
    "PresetTests.swift", "QualityStepTests.swift", "SequenceVolumeParityTests.swift", "SettingsTests.swift",
    "SmartRenderEligibilityTests.swift", "SpeedRampAudioParityTests.swift", "StemExporterTests.swift", "TimingSupport.swift", "VariantExportTests.swift",
]
let package = Package(
    name: "SQExport",
    products: [.library(name: "SQExport", targets: ["SQExport"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQPlayback"), .package(path: "../SQText"),
                   .package(path: "../SQAudioFX"), .package(path: "../SQMedia"), .package(path: "../SQFrame"),
                   .package(path: "../SQTranscribe")],   // SRTWriter.cues(from:) sees SQTranscribe through canImport: declare it
    targets: [
        .target(name: "SQExport", dependencies: ["SQCore", "SQPlayback", "SQText", "SQAudioFX", "SQMedia", "SQTranscribe",
                                                .product(name: "SQFrame", package: "SQFrame")],
                exclude: appleOnly),
        .testTarget(name: "SQExportTests", dependencies: ["SQCore", "SQPlayback", "SQText", "SQExport", "SQMedia", "SQAudioFX"],
                    sources: portableTests),
    ]
)
#else
let package = Package(
    name: "SQExport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQExport", targets: ["SQExport"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQRender"), .package(path: "../SQPlayback"),
                   .package(path: "../SQTranscribe"), .package(path: "../SQText"), .package(path: "../SQAudioFX"),
                   .package(path: "../SQMedia"), .package(path: "../SQAnalysis"), .package(path: "../SQLottie"), .package(path: "../SQPremiereImport"),
                   .package(path: "../SQFrame")],
    targets: [
        .target(name: "SQExport", dependencies: ["SQCore", "SQRender", "SQPlayback", "SQTranscribe", "SQText", "SQAudioFX", "SQMedia", "SQAnalysis", "SQLottie",
                                                .product(name: "SQFrame", package: "SQFrame")]),
        .testTarget(name: "SQExportTests", dependencies: ["SQCore", "SQPremiereImport", "SQPlayback", "SQRender", "SQText", "SQTranscribe", "SQExport", "SQMedia", "SQAudioFX", "SQAnalysis",.product(name: "SQMediaTestSupport", package: "SQMedia")]),
    ]
)
#endif
