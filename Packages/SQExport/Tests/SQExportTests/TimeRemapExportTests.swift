import Testing
import Foundation
import CoreVideo
import SQCore
import SQMedia
import SQPlayback
@testable import SQExport

private let fd = Time(1, 30)

/// Records every source time asked for; frames carry a start / duration like the real decoder's (source frames of 1/30 s,
/// solid colour = frame number so a blend is visible).
private final class TimesProvider: FrameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Time] = []
    private let width = 32, height = 32
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        lock.withLock { times.append(sourceTime) }
        let n = Int64(max(sourceTime.value * 30 / sourceTime.timescale, 0))      // floor of source frame number
        let v = UInt8(min(n * 4, 255))
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb!)
        for y in 0..<height { for x in 0..<width { let p = base + y * stride + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let info = VideoTrackInfo(width: width, height: height, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: fd, isVariableFrameRate: false)
        return ProvidedFrame(buffer: pb!, info: info, start: Time(n, 30), duration: fd)
    }
    var requested: [Time] { lock.withLock { times } }
}

private func remappedPair() -> (Timeline, UUID, Clip) {
    let m = UUID(), link = UUID()
    let segs = [SpeedSegment(duration: Time(1, 1), from: ClipSpeed(percent: 100)),
                SpeedSegment(duration: Time(1, 2), from: ClipSpeed(percent: 100), to: ClipSpeed(percent: 300)),
                SpeedSegment(duration: Time(1, 1), from: ClipSpeed(percent: 300))]          // 1 + 1 + 3 = 5 s of source in 2.5 s
    func clip(_ kind: TrackKind) -> Clip {
        var c = Clip(name: "r", media: m, kind: kind, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero, link: link,
                     mediaDuration: Time(5, 1))
        c.setSpeedKeys(SpeedKeys(segments: segs, origin: .zero))
        return c
    }
    let v = clip(.video), a = clip(.audio)
    return (Timeline(name: "t", format: SequenceFormat(width: 32, height: 32, frameDuration: fd),
                     tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])]), m, v)
}

@Suite struct TimeRemapExportTests {
    @Test func exportAsksForTheSourceTimesOfTheMapping() async throws {
        let (tl, m, v) = remappedPair()
        _ = m
        let provider = TimesProvider()
        let n = Int(v.duration.frameIndex(frameDuration: fd))
        #expect(n == 75)                                                               // 2.5 s
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 32, height: 32, frameDuration: fd, frameCount: n)
        for i in 0..<n { _ = try await src.frame(at: i) }
        let asked = provider.requested
        #expect(asked.count == n)
        for i in 0..<n { #expect(asked[i] == v.sourceTime(at: fd * Int64(i), frameDuration: fd), "frame \(i)") }
        #expect(asked[30] == Time(1, 1))                                                // the ramp starts at 1 s of source
        #expect(asked.last! > Time(4, 1))
    }

    @Test func exportedAudioEqualsThePlaybackMix() async throws {
        let (tl, m, _) = remappedPair()
        let src = MemoryAudioSource(mono: (0..<(5 * 48_000 + 100)).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) })
        let resolver = StaticMediaResolver(audio: [m: src])
        let export = TimelineAudioSource(timeline: tl, range: TimeRange(start: .zero, duration: Time(5, 2)), resolver: resolver)
        var exported: [Float] = []
        while exported.count / 2 < 120_000, let c = try await export.nextChunk(maxFrames: 4096) {
            exported += c.samples
        }
        // Same timeline mixed by the playback feeder, in blocks of another size.
        let feeder = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 14), sampleRate: 48_000, blockFrames: 777) { try resolver.audio(for: $0) }
        var mixed: [Float] = []
        var start: Int64 = 0
        while mixed.count < 120_000 {
            var l = [Float](repeating: 0, count: 777), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                feeder.mix(timeline: tl, startFrame: start, count: 777, left: lp.baseAddress!, right: rp.baseAddress!) } }
            mixed += l
            start += 777
        }
        let n = 100_000
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(exported[i * 2] - mixed[i])) }
        #expect(worst < 1e-6, "worst difference \(worst)")
        #expect(exported[2 * 60_000..<2 * 60_000 + 2000].contains { abs($0) > 0.1 })        // audio present inside the ramp
    }

    @Test func frameBlendAsksForTheNextSourceFrame() async throws {
        let m = UUID()
        var c = Clip(name: "s", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                     mediaDuration: Time(1, 1), speed: ClipSpeed(percent: 50))
        c.timeInterpolation = .frameBlend
        let tl = Timeline(name: "t", format: SequenceFormat(width: 32, height: 32, frameDuration: fd), tracks: [Track(kind: .video, clips: [c])])
        let provider = TimesProvider()
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 32, height: 32, frameDuration: fd, frameCount: 4)
        for i in 0..<4 { _ = try await src.frame(at: i) }
        // frame 0: on source frame 0 (no blend); frame 1: half a frame in -> frame 0 and frame 1; frame 2: on source frame 1; frame 3: 1 and 2.
        let asked = provider.requested
        #expect(asked == [.zero, Time(1, 60), Time(1, 30), Time(1, 30), Time(1, 20), Time(1, 30) + Time(1, 30)])
        #expect(asked.count == 6)
    }
}
