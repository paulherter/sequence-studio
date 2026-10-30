import Testing
import Foundation
import CoreVideo
import Synchronization
import SQCore
@testable import SQExport

/// Solid frames per media with a decode delay; records calls, overlap overall and per media, and fails on request.
private final class SlowProvider: FrameProvider, Sendable {
    struct Log { var calls: [(media: UUID, time: Time)] = []; var inFlight = 0, maxInFlight = 0
        var perMedia: [UUID: Int] = [:]; var maxPerMedia = 0; var running = 0 }
    let solids: SolidProvider
    let delay: Duration
    let failing: Set<UUID>
    let log = Mutex(Log())
    init(_ colors: [UUID: (b: UInt8, g: UInt8, r: UInt8)], delay: Duration = .milliseconds(30), failing: Set<UUID> = []) {
        solids = SolidProvider(colors: colors, width: 64, height: 32); self.delay = delay; self.failing = failing
    }
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        log.withLock { l in
            l.calls.append((media, sourceTime)); l.inFlight += 1; l.maxInFlight = max(l.maxInFlight, l.inFlight)
            l.perMedia[media, default: 0] += 1; l.maxPerMedia = max(l.maxPerMedia, l.perMedia[media]!); l.running += 1
        }
        defer { log.withLock { l in l.inFlight -= 1; l.perMedia[media]! -= 1; l.running -= 1 } }
        try await Task.sleep(for: delay)
        if failing.contains(media) { throw FrameDecodeError(media: media, sourceTime: sourceTime, reason: "broken") }
        return try await solids.frame(media: media, at: sourceTime)
    }
}

private let fd = Time(1, 30)
private let ids = (0..<6).map { _ in UUID() }
private let palette: [(b: UInt8, g: UInt8, r: UInt8)] = [(0, 0, 255), (0, 255, 0), (255, 0, 0), (0, 255, 255), (255, 0, 255), (255, 255, 0)]
private var colors: [UUID: (b: UInt8, g: UInt8, r: UInt8)] {
    Dictionary(uniqueKeysWithValues: zip(ids, palette).map { ($0, $1) })
}

/// `n` stacked video tracks, one media each, every layer smaller and half transparent so all of them show.
private func stack(_ n: Int, media: [UUID] = ids, sourceStarts: [Time]? = nil) -> Timeline {
    let tracks = (0..<n).map { i -> Track in
        let src = TimeRange(start: sourceStarts?[i] ?? .zero, duration: Time(2, 1))
        var c = Clip(name: "layer \(i)", media: media[i], kind: .video, source: src, start: .zero)
        let s = 1.0 - Double(i) * 0.12
        c.animation.scale = AnimatedProperty(Vec2(s, s))
        c.animation.opacity = AnimatedProperty(i == 0 ? 1 : 0.6)
        return Track(kind: .video, clips: [c])
    }
    return Timeline(name: "stack", format: SequenceFormat(width: 64, height: 32, frameDuration: fd), tracks: tracks)
}

private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb) * 4
    return (0..<CVPixelBufferGetHeight(pb)).flatMap { y in Array(UnsafeBufferPointer(start: base + y * stride, count: w)) }
}

@Suite struct LayerDecodeConcurrencyTests {
    @Test func concurrentLayersRenderIdenticalPixelsToSerial() async throws {
        for format in [ExportPixelFormat.bgra8, .yuv420v10] {
            var outputs: [[UInt8]] = []
            for width in [1, 4] {
                let p = SlowProvider(colors, delay: .milliseconds(1))
                let src = try TimelineFrameSource(timeline: stack(5), provider: p, width: 64, height: 32, frameDuration: fd,
                                                  frameCount: 3, pixelFormat: format, layerConcurrency: width)
                var all: [UInt8] = []
                for i in 0..<3 {
                    let pb = try await src.frame(at: i)
                    if format == .bgra8 { all += bytes(pb) } else {
                        CVPixelBufferLockBaseAddress(pb, .readOnly)
                        for plane in 0..<2 {
                            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt8.self)
                            all += Array(UnsafeBufferPointer(start: base, count: CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                                                             * CVPixelBufferGetHeightOfPlane(pb, plane)))
                        }
                        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                    }
                }
                outputs.append(all)
            }
            #expect(outputs[0] == outputs[1])
        }
    }

    @Test func independentLayersDecodeAtOnceWithinTheWidth() async throws {
        let wide = SlowProvider(colors)
        _ = try await TimelineFrameSource(timeline: stack(6), provider: wide, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 1, layerConcurrency: 3).frame(at: 0)
        let w = wide.log.withLock { $0 }
        #expect(w.maxInFlight == 3)
        #expect(w.calls.count == 6)

        let serial = SlowProvider(colors)
        _ = try await TimelineFrameSource(timeline: stack(6), provider: serial, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 1, layerConcurrency: 1).frame(at: 0)
        #expect(serial.log.withLock { $0.maxInFlight } == 1)
    }

    @Test func oneMediaIsAskedInLayerOrderAndNeverTwiceAtOnce() async throws {
        // Layers 0 and 2 are two clips of one file at different source positions; layer 1 is another file.
        let a = ids[0], b = ids[1]
        let tl = stack(3, media: [a, b, a], sourceStarts: [.zero, .zero, Time(1, 1)])
        let p = SlowProvider(colors)
        _ = try await TimelineFrameSource(timeline: tl, provider: p, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 1, layerConcurrency: 4).frame(at: 0)
        let log = p.log.withLock { $0 }
        #expect(log.maxPerMedia == 1)
        #expect(log.maxInFlight == 2)
        #expect(log.calls.filter { $0.media == a }.map(\.time) == [.zero, Time(1, 1)])
    }

    @Test func firstFailingLayerInLayerOrderIsReported() async throws {
        // Layer 1 fails slowly, layer 3 fails at once: the export names layer 1, like the serial render.
        let p = SlowProvider(colors, failing: [ids[1], ids[3]])
        let src = try TimelineFrameSource(timeline: stack(4), provider: p, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 1, layerConcurrency: 4)
        do {
            _ = try await src.frame(at: 0)
            Issue.record("expected a decode error")
        } catch let e as ExportDecodeError {
            #expect(e.clipName == "layer 1")
        }
    }

    @Test func cancellationStopsEveryLayerDecode() async throws {
        let p = SlowProvider(colors, delay: .seconds(10))
        let src = try TimelineFrameSource(timeline: stack(4), provider: p, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 1, layerConcurrency: 4)
        let task = Task { _ = try await src.frame(at: 0) }
        while p.log.withLock({ $0.running }) < 4 { try await Task.sleep(for: .milliseconds(5)) }
        let t0 = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - t0 < SQTiming.budget(.seconds(10)))
        #expect(p.log.withLock { $0.running } == 0)
    }
}
