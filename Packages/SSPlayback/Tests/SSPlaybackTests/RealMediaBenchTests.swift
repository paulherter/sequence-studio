import Testing
import Foundation
import CoreMedia
import Metal
import AppKit
import QuartzCore
import SSCore
import SSMedia
import SSMediaTestSupport
@testable import SSPlayback

/// Opt-in real-media playback bench (`SS_REAL_MEDIA=1`): HostClock, headless compositor, ticks at ~60 Hz wall time.
/// Prints presented/dropped frames, position advance, decode calls and tick timings. Control: a generated E-01 clip.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SS_REAL_MEDIA"] == "1"))
@MainActor struct RealMediaBenchTests {
    static let iPhoneClip = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos/iPhone 18 Pro/Ohne Titel.mov")

    struct Result { var presented = 0, dropped = 0; var advance = 0.0; var decodes = 0; var ticks = 0
        var tickMean = 0.0, tickMax = 0.0, presentMean = 0.0; var seekPosition = Time.zero; var fps = 0.0 }

    /// Same run, but driven by the real `DisplayLinkDriver` on a layer in an on-screen window (no manual ticks).
    static func runDisplayLink(url: URL, label: String, width: Int, height: Int, withAudio: Bool = false) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: url)
        let index = demuxer.index
        let fd = index.entries[0].duration
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: demuxer],
                                           audio: withAudio ? [media: try await AssetAudioSource.open(url: url, sampleRate: 48_000)] : [:])
        let audio: AudioEngine? = withAudio ? AudioEngine(media: resolver) : nil
        let engine = try PlaybackEngine(device: device, media: resolver, audio: audio)
        let dur = index.duration
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: dur),
                        start: .zero, mediaDuration: dur)
        var tracks = [Track(kind: .video, clips: [clip])]
        if withAudio {
            tracks.append(Track(kind: .audio, clips: [Clip(name: "A", media: media, kind: .audio,
                source: TimeRange(start: .zero, duration: dur), start: .zero, mediaDuration: dur)]))
        }
        let tl = Timeline(name: "Seq", format: SequenceFormat(width: width, height: height, frameDuration: fd), tracks: tracks)
        engine.setTimeline(tl)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 450), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = NSView(frame: window.contentView!.bounds)
        let layer = CAMetalLayer()
        view.layer = layer; view.wantsLayer = true
        window.contentView = view
        // SS_HIDDEN=1: window never on screen; CAMetalDisplayLink then stops ticking (measured 0 ticks in 3 s).
        if ProcessInfo.processInfo.environment["SS_HIDDEN"] == nil { window.orderFrontRegardless() }
        layer.drawableSize = CGSize(width: 1600, height: 900)
        engine.attach(layer)
        engine.seek(to: Time(1, 1))
        await engine.waitForDecodes()
        try await Task.sleep(for: .milliseconds(300))
        let seekPos = engine.position
        let before = engine.stats, decodes0 = engine.decodeCalls
        let tim0 = engine.loop.timing.withLock { $0 }
        engine.play()
        try await Task.sleep(for: .seconds(3))
        let pos1 = engine.position
        let usedAudio = engine.usesAudioClock, audioFailed = engine.audioUnavailable
        engine.pause()
        audio?.shutdown()
        let tim1 = engine.loop.timing.withLock { $0 }
        engine.attach(nil)
        window.orderOut(nil)
        let st = engine.stats
        let adv = pos1 - seekPos
        let ticks = tim1.ticks - tim0.ticks, presents = tim1.presents - tim0.presents
        let ms = { (d: Duration) in d / .milliseconds(1) }
        print(String(format: "[displaylink %@] fd=%@ frames=%d seek(1s)->%@ presented=%d dropped=%d advance=%.3fs decodeCalls=%d driverTicks=%d tick mean=%.2fms presentTick mean=%.2fms audioClock=%d audioUnavailable=%d",
                     label, "\(fd)", index.count, "\(seekPos)", st.presentedFrames - before.presentedFrames,
                     st.droppedFrames - before.droppedFrames, Double(adv.value) / Double(adv.timescale),
                     engine.decodeCalls - decodes0, ticks, ms(tim1.total - tim0.total) / Double(max(1, ticks)),
                     ms(tim1.presentTotal - tim0.presentTotal) / Double(max(1, presents)), usedAudio ? 1 : 0, audioFailed ? 1 : 0))
    }

    @Test func iPhoneHEVCDisplayLink() async throws {
        guard FileManager.default.fileExists(atPath: Self.iPhoneClip.path) else { return }
        try await Self.runDisplayLink(url: Self.iPhoneClip, label: "iPhone", width: 1280, height: 720)
    }

    @Test func iPhoneHEVCDisplayLinkWithAudio() async throws {
        guard FileManager.default.fileExists(atPath: Self.iPhoneClip.path) else { return }
        try await Self.runDisplayLink(url: Self.iPhoneClip, label: "iPhone+audio", width: 1280, height: 720, withAudio: true)
    }

    static func run(url: URL, label: String, width: Int, height: Int) async throws -> Result {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: url)
        let index = demuxer.index
        let fd = index.entries[0].duration
        let media = UUID()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: demuxer]))
        let dur = index.duration
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: dur),
                        start: .zero, mediaDuration: dur)
        let tl = Timeline(name: "Seq", format: SequenceFormat(width: width, height: height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])
        engine.setTimeline(tl)
        engine.seek(to: Time(1, 1))
        await engine.waitForDecodes()
        engine.tick()
        var r = Result()
        r.fps = Double(fd.timescale) / Double(fd.value)
        r.seekPosition = engine.position
        let before = engine.stats, decodes0 = engine.decodeCalls, pos0 = engine.position
        engine.play()
        let clock = ContinuousClock()
        let start = clock.now
        var tickTimes: [Double] = [], presentTimes: [Double] = []
        while clock.now - start < .seconds(3) {
            let t0 = clock.now
            let p = engine.tick()
            let dt = (clock.now - t0) / .milliseconds(1)
            tickTimes.append(dt); if p { presentTimes.append(dt) }
            try await Task.sleep(for: .milliseconds(8))   // ~100 Hz, above the content rate
        }
        engine.pause()
        let st = engine.stats
        r.presented = st.presentedFrames - before.presentedFrames
        r.dropped = st.droppedFrames - before.droppedFrames
        let adv = engine.position - pos0
        r.advance = Double(adv.value) / Double(adv.timescale)
        r.decodes = engine.decodeCalls - decodes0
        r.ticks = tickTimes.count
        r.tickMean = tickTimes.reduce(0, +) / Double(max(1, tickTimes.count))
        r.tickMax = tickTimes.max() ?? 0
        r.presentMean = presentTimes.reduce(0, +) / Double(max(1, presentTimes.count))
        print(String(format: "[bench %@] fd=%@ seek(1s)->%@ presented=%d dropped=%d advance=%.3fs decodeCalls=%d ticks=%d tick mean=%.2fms max=%.2fms presentTick mean=%.2fms",
                     label, "\(fd)", "\(r.seekPosition)", r.presented, r.dropped, r.advance, r.decodes, r.ticks,
                     r.tickMean, r.tickMax, r.presentMean))
        return r
    }

    @Test func iPhoneHEVC() async throws {
        guard FileManager.default.fileExists(atPath: Self.iPhoneClip.path) else { return }
        let r = try await Self.run(url: Self.iPhoneClip, label: "iPhone HEVC", width: 1280, height: 720)
        #expect(r.advance > 2.5)
        #expect(Double(r.presented) > 2.7 * r.fps)        // ~every grid frame of 3 s
    }

    @Test func generatedControl() async throws {
        var spec = TestClipSpec()
        spec.width = 1280; spec.height = 720
        spec.frameDuration = TestClipSpec.fps(60)
        spec.frameCount = 250
        let url = try await TestClipWriter.write(spec)
        let r = try await Self.run(url: url, label: "E-01 control 720p60", width: 1280, height: 720)
        #expect(r.advance > 2.5)
        #expect(Double(r.presented) > 2.7 * r.fps)        // ~every grid frame of 3 s
    }
}
