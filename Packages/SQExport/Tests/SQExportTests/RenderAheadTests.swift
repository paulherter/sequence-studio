import Testing
import Foundation
import CoreVideo
import Synchronization
import SQCore
@testable import SQExport

/// Solid frames per media with a short decode delay; records every request.
private final class LoggingProvider: FrameProvider, Sendable {
    let solids: SolidProvider
    let delay: Duration
    /// Decode delay from this source time on (nil = `delay` everywhere).
    let slowFrom = Mutex<(time: Time, delay: Duration)?>(nil)
    let calls = Mutex<[(media: UUID, time: Time)]>([])
    init(_ colors: [UUID: (b: UInt8, g: UInt8, r: UInt8)], delay: Duration = .milliseconds(2)) {
        solids = SolidProvider(colors: colors, width: 64, height: 32); self.delay = delay
    }
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        calls.withLock { $0.append((media, sourceTime)) }
        let slow = slowFrom.withLock { $0 }
        try await Task.sleep(for: slow.map { sourceTime >= $0.time ? $0.delay : delay } ?? delay)
        return try await solids.frame(media: media, at: sourceTime)
    }
}

private let fd = Time(1, 30)
private let ids = (0..<4).map { _ in UUID() }
private let colors: [UUID: (b: UInt8, g: UInt8, r: UInt8)] =
    Dictionary(uniqueKeysWithValues: zip(ids, [(0, 0, 255), (0, 255, 0), (255, 0, 0), (0, 255, 255)]).map { ($0, $1) })

/// Four stacked tracks, moving and fading so every output frame differs.
private func moving() -> Timeline {
    let tracks = (0..<4).map { i -> Track in
        var c = Clip(name: "layer \(i)", media: ids[i], kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        c.animation.scale = AnimatedProperty(Vec2(1 - Double(i) * 0.15, 1 - Double(i) * 0.15))
        c.animation.opacity = AnimatedProperty(0.5, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: i == 0 ? 1 : 0.2),
                                                                                Keyframe(time: Time(1, 1), value: 0.9)]))
        c.animation.position = AnimatedProperty(Vec2(0, 0), track: KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-10, 0)),
                                                                                         Keyframe(time: Time(1, 1), value: Vec2(Double(i) * 6, 4))]))
        return Track(kind: .video, clips: [c])
    }
    return Timeline(name: "moving", format: SequenceFormat(width: 64, height: 32, frameDuration: fd), tracks: tracks)
}

private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    var out: [UInt8] = []
    let planes = max(1, CVPixelBufferGetPlaneCount(pb))
    for p in 0..<planes {
        let planar = CVPixelBufferIsPlanar(pb)
        let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb))!
        let n = (planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb))
            * (planar ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb))
        out += Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: n))
    }
    return out
}

@Suite struct RenderAheadTests {
    private func source(ahead: Bool, format: ExportPixelFormat = .bgra8, provider: LoggingProvider? = nil,
                        frames: Int = 8) throws -> TimelineFrameSource {
        try TimelineFrameSource(timeline: moving(), provider: provider ?? LoggingProvider(colors), width: 64, height: 32,
                                frameDuration: fd, frameCount: frames, pixelFormat: format, renderAhead: ahead)
    }

    @Test func renderAheadGivesByteIdenticalFrames() async throws {
        for format in [ExportPixelFormat.bgra8, .yuv420v, .yuv420v10] {
            var outputs: [[[UInt8]]] = []
            for ahead in [false, true] {
                let src = try source(ahead: ahead, format: format)
                var all: [[UInt8]] = []
                for i in 0..<8 { all.append(bytes(try await src.frame(at: i))) }
                outputs.append(all)
            }
            #expect(outputs[0] == outputs[1], "\(format)")
            #expect(Set(outputs[0]).count > 1)     // the frames really differ
        }
    }

    @Test func nextFrameStartsBeforeItIsAsked() async throws {
        let p = LoggingProvider(colors)
        let src = try source(ahead: true, provider: p)
        _ = try await src.frame(at: 0)
        // Frame 1 decodes without a request (4 layers per frame).
        let t0 = ContinuousClock.now
        while p.calls.withLock({ $0.count }) < 8, ContinuousClock.now - t0 < SQTiming.budget(.seconds(5)) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(p.calls.withLock { $0.count } == 8)
        // No frame 2 until frame 1 is asked.
        try await Task.sleep(for: .milliseconds(50))
        #expect(p.calls.withLock { $0.count } == 8)
    }

    @Test func lastFrameRendersNothingAhead() async throws {
        let p = LoggingProvider(colors)
        let src = try source(ahead: true, provider: p, frames: 2)
        _ = try await src.frame(at: 0)
        _ = try await src.frame(at: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(p.calls.withLock { $0.count } == 8)
    }

    @Test func jumpDropsTheFrameAheadAndRendersTheAskedOne() async throws {
        let plain = try source(ahead: false)
        let want = bytes(try await plain.frame(at: 5))
        let src = try source(ahead: true)
        _ = try await src.frame(at: 0)
        #expect(bytes(try await src.frame(at: 5)) == want)
        // And back to a frame before.
        let want2 = bytes(try await plain.frame(at: 2))
        #expect(bytes(try await src.frame(at: 2)) == want2)
    }

    @Test func cancellingARequestCancelsTheFrameAhead() async throws {
        let p = LoggingProvider(colors)
        let src = try source(ahead: true, provider: p)
        p.slowFrom.withLock { $0 = (fd, .seconds(30)) }     // frame 1 on
        _ = try await src.frame(at: 0)
        // Frame 1 is now decoding ahead; asking for it and canceling stops it.
        let task = Task { _ = try await src.frame(at: 1) }
        try await Task.sleep(for: .milliseconds(20))
        let t0 = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - t0 < SQTiming.budget(.seconds(10)))     // not the 30 s decode
        try await Task.sleep(for: .milliseconds(400))
        #expect(p.calls.withLock { $0.count } <= 8)     // frame 2 never started
    }
}
