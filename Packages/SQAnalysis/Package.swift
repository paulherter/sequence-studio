// swift-tools-version: 6.2
import PackageDescription

// Picture analysis (Vision). Pure planning logic (smoothing, crop-window math, keyframe conversion) is testable without
// Vision: detections come in through `SubjectDetecting`.
#if os(Windows)
// Windows (the Windows port plan, seam 5): the portable part only: analysis cache, turn gate, reframe, scene-cut and
// beat logic, music fit, subject-mask timing/quality/look-ahead, matte store, benchmark metrics. Vision, CoreML,
// Accelerate, CoreVideo and Metal work (Magic Mask, stabilizer, Gyroflow warp, trackers, Anonymize detection) is
// Mac-only; callers see it as unavailable. A new source file that imports an Apple framework goes on this list.
let appleOnly = [
    "AnalysisFields.swift", "Anonymize.swift", "BeatDetector.swift", "EdgeTAM.swift", "ExportSubjectMattes.swift",
    "FeatureTracker.swift", "GrayFrame+CoreVideo.swift", "GyroStabilization.swift", "GyroWarpMap.swift",
    "GyroflowEngine.swift", "LucasKanade.swift", "MagicMask.swift", "MaskPointTracker.swift", "MaskTracker.swift",
    "PersonSegmenter.swift", "SceneCutAnalyzer.swift", "Stabilization.swift", "SubjectMaskEngine.swift",
    "SubjectMatteCore.swift", "SubjectMattePrecompute.swift", "SubjectMatteRefiner.swift", "SubjectMatteScheduler.swift",
    "SubjectMatteUpsample.swift", "SubjectTrackLeg.swift", "VisionSubjectDetector.swift",
]
let portableTests = [
    "AnalysisTurnTests.swift", "AnonymizeSearchTests.swift", "Benchmark/MaskMetricsTests.swift", "MusicFitTests.swift",
    "ReframeTests.swift", "RollingShutterMeasureTests.swift", "SceneCutDetectorTests.swift", "SubjectLogitMathTests.swift",
    "SubjectLookAheadTests.swift", "TimingSupport.swift", "EdgeTAMOnnxTests.swift", "FrameMatteStoreTests.swift", "LZFSETests.swift",
]
let package = Package(
    name: "SQAnalysis",
    products: [.library(name: "SQAnalysis", targets: ["SQAnalysis"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia"), .package(path: "../SQOnnx")],
    targets: [
        .target(name: "CLZFSE", exclude: ["LICENSE"], cSettings: [.headerSearchPath(".")]),
        .target(name: "SQAnalysis", dependencies: ["SQCore", "SQMedia", "SQOnnx", "CLZFSE"], exclude: appleOnly, swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "SQAnalysisTests", dependencies: ["SQCore", "SQAnalysis", "SQOnnx"], sources: portableTests),
    ]
)
#else
let package = Package(
    name: "SQAnalysis",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQAnalysis", targets: ["SQAnalysis"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia"), .package(path: "../SQOnnx")],
    targets: [
        // The per-frame loops (feature tracker, photometric check, Vision registration) run 100x slower unoptimized: a 24-frame
        // 720p clip took 211 s in a Debug build (2026-10-17: the Stabilizer sat at "Starting... 0 %"). Optimized in every configuration.
        .target(name: "CLZFSE", exclude: ["LICENSE"], cSettings: [.headerSearchPath(".")]),
        .target(name: "SQAnalysis", dependencies: ["SQCore", "SQMedia", "SQOnnx", "CLZFSE"], swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "SQAnalysisTests", dependencies: ["SQCore", "SQAnalysis", "SQOnnx", .product(name: "SQMediaTestSupport", package: "SQMedia")]),
    ]
)
#endif
