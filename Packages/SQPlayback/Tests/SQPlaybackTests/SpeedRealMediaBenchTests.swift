import Testing
import Foundation
import CoreMedia
import Metal
import AppKit
import QuartzCore
import SQCore
import SQMedia
@testable import SQPlayback

/// Opt-in bench (`SQ_REAL_MEDIA=1`): plays a real 1080p H.264 clip at 200 %, at 33.33 % and reversed through the display-link
/// driven engine for 5 s and prints presented / dropped frames. Control: the same clip at 100 %.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_REAL_MEDIA"] == "1"))
@MainActor struct SpeedRealMediaBenchTests {
    static let clipURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos/iOS 26 Hier/ios26hier.mp4")

    static func run(label: String, speed: ClipSpeed, reversed: Bool, sourceSeconds: Int64, from: Int64 = 0, withAudio: Bool = true, keys: SpeedKeys? = nil) async throws {
        guard FileManager.default.fileExists(atPath: clipURL.path) else { print("[speed \(label)] media missing"); return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: clipURL)
        let index = demuxer.index
        let fd = index.entries[0].duration
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: demuxer],
                                           audio: withAudio ? [media: try await AssetAudioSource.open(url: clipURL, sampleRate: 48_000)] : [:])
        let audio: AudioEngine? = withAudio ? AudioEngine(media: resolver) : nil
        let engine = try PlaybackEngine(device: device, media: resolver, audio: audio)
        let dur = index.duration
        func clip(_ kind: TrackKind) -> Clip {
            var c = Clip(name: "A", media: media, kind: kind, source: TimeRange(start: Time(from, 1), duration: Time(sourceSeconds, 1)),
                         start: .zero, mediaDuration: dur, speed: speed, reversed: reversed)
            if let keys { c.setSpeedKeys(SpeedKeys(segments: keys.segments, origin: Time(from, 1))) }
            return c
        }
        var tracks = [Track(kind: .video, clips: [clip(.video)])]
        if withAudio { tracks.append(Track(kind: .audio, clips: [clip(.audio)])) }
        engine.setTimeline(Timeline(name: "Seq", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: tracks))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 450, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = NSView(frame: window.contentView!.bounds)
        let layer = CAMetalLayer()
        view.layer = layer; view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        layer.drawableSize = CGSize(width: 900, height: 1600)
        engine.attach(layer)
        engine.seek(to: Time(1, 1))
        await engine.waitForDecodes()
        try await Task.sleep(for: .milliseconds(300))
        let seekPos = engine.position
        let before = engine.stats, decodes0 = engine.decodeCalls
        engine.play()
        try await Task.sleep(for: .seconds(5))
        let pos1 = engine.position
        engine.pause()
        audio?.shutdown()
        engine.attach(nil)
        window.orderOut(nil)
        let st = engine.stats
        let adv = pos1 - seekPos
        let line = String(format: "[speed %@] %d%% reversed=%d presented=%d dropped=%d advance=%.3fs decodeCalls=%d",
                          label, Int(speed.percent), reversed ? 1 : 0, st.presentedFrames - before.presentedFrames,
                          st.droppedFrames - before.droppedFrames, Double(adv.value) / Double(adv.timescale), engine.decodeCalls - decodes0)
        print(line)
        NSLog("%@", line)
    }

    @Test func normal() async throws { try await Self.run(label: "control", speed: .normal, reversed: false, sourceSeconds: 20) }
    @Test func double() async throws { try await Self.run(label: "2x", speed: ClipSpeed(percent: 200), reversed: false, sourceSeconds: 40) }
    @Test func third() async throws { try await Self.run(label: "33.33%", speed: ClipSpeed(percent: 33.33), reversed: false, sourceSeconds: 10) }
    @Test func reversed() async throws { try await Self.run(label: "reverse", speed: .normal, reversed: true, sourceSeconds: 20) }
    @Test func reversedDouble() async throws { try await Self.run(label: "reverse 2x", speed: ClipSpeed(percent: 200), reversed: true, sourceSeconds: 40) }

    /// Speed ramps (Time Remapping): 100 % -> 400 % over 2 s (14 s of source in 5 s), and 100 % -> 25 % (slow motion).
    static func ramp(_ a: Double, _ b: Double, hold: Int64) -> SpeedKeys {
        SpeedKeys(segments: [SpeedSegment(duration: Time(1, 1), from: .normal),
                             SpeedSegment(duration: Time(2, 1), from: ClipSpeed(percent: a), to: ClipSpeed(percent: b)),
                             SpeedSegment(duration: Time(hold, 1), from: ClipSpeed(percent: b))], origin: .zero)
    }
    @Test func rampUp() async throws {
        try await Self.run(label: "ramp 100->400", speed: .normal, reversed: false, sourceSeconds: 14,
                           keys: Self.ramp(100, 400, hold: 2))
    }
    @Test func rampDown() async throws {
        try await Self.run(label: "ramp 100->25", speed: .normal, reversed: false, sourceSeconds: 4,
                           keys: Self.ramp(100, 25, hold: 2))
    }
}
