// swift-tools-version: 6.2
import PackageDescription

#if os(Windows)
// Windows (the Windows port plan, seam 3): the portable part of SQPlayback only: `AudioPlaying`, the audio feeder and
// clock, decode scheduling, frame cache, ring buffer, the caption plan (`CaptionLayerPlan`, through SQText). The render
// loop and engine (Metal, SQRender), CoreAudio output and recording are left out; WASAPI output lives in
// Packages/SQMediaFFmpeg.
// A new source file that imports an Apple framework or SQRender/SQText/SQAnalysis/SQLottie goes on this list.
let appleOnly = [
    "AudioEngine.swift", "AudioOutputDevices.swift", "LookPreview.swift",
    "PlayProbe.swift", "PlaybackEngine.swift", "ProxyPicture.swift", "RenderLayer+TextFill.swift", "RenderLoop.swift",
    "VoiceRecorder.swift",
]
// Tests that need neither an Apple framework nor the render loop.
let portableTests = [
    "AudioClockTests.swift", "AudioDeClickFeederTests.swift", "AudioFeederClipFXTests.swift",
    "AudioFeederDuckIndexTests.swift", "AudioFeederFXTests.swift", "AudioFeederKeyedSequenceVolumeTests.swift",
    "AudioFeederMasterTests.swift", "AudioFeederNestFXTests.swift", "AudioFeederRoleBusTests.swift",
    "AudioFeederScrubMonoTests.swift", "AudioFeederSequenceVolumeTests.swift", "AudioFeederTests.swift",
    "AudioFeederTrackMixTests.swift", "AudioFeederVoiceChainTests.swift", "AudioMeterLoudnessTests.swift",
    "AudioMixerFuzzTests.swift", "AudioRetimeTests.swift", "AudioRetimerGuardTests.swift",
    "AudioRetimerRangeTests.swift", "ChannelMonitorStageTests.swift", "ClockTests.swift",
    "DisguiseVoiceFailClosedTests.swift", "DisguiseVoiceFeederTests.swift", "DisguiseVoiceLeakTests.swift",
    "DisplayLeadEmptyLoopTests.swift", "FrameCacheTests.swift", "FramePacingTests.swift", "FramePhaseLockTests.swift",
    "LiveDuckingSilenceFeederTests.swift", "MemoryBudgetTests.swift", "MonitorGainStageTests.swift", "PrefetchTests.swift",
    "PresentProbeTests.swift", "PreviewRateTests.swift", "RingBufferTests.swift", "RingFadeTests.swift",
    "SQPlaybackTests.swift", "ScrubAudioTests.swift", "ScrubToneTests.swift", "ShuttleStretchTests.swift",
    "SpeedKeysAudioTests.swift",
    "SpeedKeysTransitionAudioTests.swift", "TextStandInsTests.swift", "TimingSupport.swift",
    "WaveformSilencesCacheTests.swift",
]
let package = Package(
    name: "SQPlayback",
    products: [.library(name: "SQPlayback", targets: ["SQPlayback"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia"), .package(path: "../SQAudioFX"), .package(path: "../SQFrame"),
                   .package(path: "../SQText")],
    targets: [
        .target(name: "SQPlayback", dependencies: ["SQCore", "SQMedia", "SQAudioFX", "SQText",
                                                  .product(name: "SQFrame", package: "SQFrame"),
                                                  .product(name: "SQFrameCoreVideo", package: "SQFrame")],
                exclude: appleOnly),
        .testTarget(name: "SQPlaybackTests", dependencies: ["SQCore", "SQPlayback", "SQAudioFX", "SQMedia",
                                                        .product(name: "SQFrame", package: "SQFrame")],
                    sources: portableTests),
    ]
)
#else
let package = Package(
    name: "SQPlayback",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQPlayback", targets: ["SQPlayback"])],
    dependencies: [.package(path: "../SQCore"),.package(path: "../SQMedia"),.package(path: "../SQRender"),.package(path: "../SQAudioFX"),.package(path: "../SQText"),.package(path: "../SQAnalysis"), .package(path: "../SQLottie"), .package(path: "../SQFrame")],
    targets: [
        .target(name: "SQPlayback", dependencies: ["SQCore","SQMedia","SQRender","SQAudioFX","SQText","SQAnalysis","SQLottie",
                                                  .product(name: "SQFrame", package: "SQFrame"),
                                                  .product(name: "SQFrameCoreVideo", package: "SQFrame")]),
        .testTarget(name: "SQPlaybackTests", dependencies: ["SQCore", "SQRender", "SQPlayback","SQText","SQAudioFX","SQMedia","SQAnalysis",.product(name: "SQMediaTestSupport", package: "SQMedia"),
                                                        .product(name: "SQFrame", package: "SQFrame"),
                                                        .product(name: "SQFrameCoreVideo", package: "SQFrame")]),
    ]
)
#endif
