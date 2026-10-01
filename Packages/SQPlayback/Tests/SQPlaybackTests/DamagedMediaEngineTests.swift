import Testing
import Foundation
import CoreMedia
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

private enum Shown: Equatable { case stamp(Int), offline, damaged, other }

/// Reads the composite: a FrameStamp when the top-left reads as one, else the placeholder colour at the centre.
@MainActor private func read(_ texture: MTLTexture, device: MTLDevice, y0: Int = 0) -> Shown {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return .other }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    var value = 0, isStamp = true
    for bit in 0..<FrameStamp.bitCount {
        var sum: Float = 0, n: Float = 0
        for y in (y0 + 4)..<(y0 + 12) { for x in (bit * 16 + 4)..<(bit * 16 + 12) {
            let i = y * w * 4 + x * 4
            sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
        } }
        let v = sum / n
        if v > 0.3 && v < 0.7 { isStamp = false; break }
        if v >= 0.7 { value |= 1 << bit }
    }
    // Placeholder first: its flat colour also reads as an all-black/white "stamp" otherwise.
    let c = ((y0 + 60) * w + w / 2) * 4
    let (r, g, b) = (Float(px[c]), Float(px[c + 1]), Float(px[c + 2]))
    if r > 0.1 && g < 0.04 && b < 0.04 { return .offline }      // linear ~ (0.17, 0.01, 0.01)
    if r > 0.1 && g >= 0.04 && b < 0.02 { return .damaged }     // linear ~ (0.17, 0.09, 0.002)
    return isStamp ? .stamp(value) : .other
}

private func truncated(_ frames: Int, fraction: Int) async throws -> URL {
    var spec = TestClipSpec(); spec.frameCount = frames; spec.moovAtStart = true
    spec.frameDuration = TestClipSpec.fps(30)
    let url = try await TestClipWriter.write(spec)
    var data = try Data(contentsOf: url)
    data = data.prefix(data.count * fraction / 100)
    let out = url.deletingLastPathComponent().appendingPathComponent("cut.mov")
    try data.write(to: out)
    return out
}

@MainActor private struct Rig {
    let engine: PlaybackEngine, clock: ManualClock, device: MTLDevice

    init(_ demuxers: [UUID: any Demuxing], timeline: Timeline) throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        clock = ManualClock()
        engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: demuxers), clock: clock)
        engine.setTimeline(timeline)
    }

    func shown(y0: Int = 0) -> Shown? {
        guard let t = engine.lastRenderedTexture else { return nil }
        return read(t, device: device, y0: y0)
    }

    /// Seek to frame k, let decoding finish, present.
    func frame(_ k: Int, y0: Int = 0) async -> Shown? {
        engine.seek(to: fd * Int64(k))
        _ = engine.tick()
        await engine.waitForDecodes()
        _ = engine.tick()
        return shown(y0: y0)
    }
}

private func singleClip(_ media: UUID, frames: Int, duration: Time? = nil) -> Timeline {
    let d = duration ?? fd * Int64(frames)
    let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: d), start: .zero, mediaDuration: d)
    return Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])])
}

@Suite(.serialized) @MainActor struct DamagedMediaEngineTests {
    @Test func truncatedClipPlaysGoodPartThenDamagedPlaceholder() async throws {
        let url = try await truncated(120, fraction: 60)
        let d = try await AVDemuxer(url: url)
        let media = UUID()
        let rig = try Rig([media: d], timeline: singleClip(media, frames: d.index.count))
        let e = rig.engine
        var shown: [Shown] = []
        for k in 0..<d.index.count { shown.append(await rig.frame(k) ?? .other) }
        let good = shown.prefix { if case .stamp = $0 { true } else { false } }
        #expect(good.count >= 40)
        for (k, s) in good.enumerated() { #expect(s == .stamp(k)) }
        #expect(shown.dropFirst(good.count).count > 0)
        #expect(shown.dropFirst(good.count).allSatisfy { $0 == .damaged })
        #expect(shown.last == .damaged)
        // No retry loop: one decode call per GOP at most (good GOPs + each failed one once).
        let gops = Set((0..<d.index.count).map { d.index.gop(containing: $0) }).count
        #expect(e.decodeCalls <= gops)
        let calls = e.decodeCalls
        for _ in 0..<5 { _ = e.tick(); await e.waitForDecodes() }
        #expect(e.decodeCalls == calls)
    }

    @Test func playingIntoDamagedRegionDoesNotHangOrRetry() async throws {
        let url = try await truncated(120, fraction: 60)
        let d = try await AVDemuxer(url: url)
        let media = UUID()
        let rig = try Rig([media: d], timeline: singleClip(media, frames: d.index.count))
        let e = rig.engine
        e.seek(to: .zero)
        await e.waitForDecodes()
        _ = e.tick()
        e.play()
        var last: Shown?
        for _ in 1..<d.index.count {
            await e.waitForDecodes()
            rig.clock.advance(by: fd)
            _ = e.tick()
            last = rig.shown()
        }
        #expect(last == .damaged)
        let gops = Set((0..<d.index.count).map { d.index.gop(containing: $0) }).count
        #expect(e.decodeCalls <= gops + 2)
    }

    @Test func garbageMediaShowsOfflinePlaceholder() async throws {
        var bytes = [UInt8](repeating: 0, count: 20_000)
        for i in bytes.indices { bytes[i] = .random(in: 0...255) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SQGarbageEngine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("noise.mov")
        try Data(bytes).write(to: url)
        let empty = dir.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        for u in [url, empty] {
            struct OpenFailing: MediaResolver {
                let url: URL
                func demuxer(for media: UUID) throws -> any Demuxing {
                    let box = Box()
                    let sem = DispatchSemaphore(value: 0)
                    let u = url
                    Task.detached { box.value = await Result { try await AVDemuxer(url: u) }; sem.signal() }
                    sem.wait()
                    return try box.value!.get()
                }
                func audio(for media: UUID) throws -> any AudioSource { throw MediaError.unreadable }
            }
            let device = try #require(MTLCreateSystemDefaultDevice())
            let e = try PlaybackEngine(device: device, media: OpenFailing(url: u), clock: ManualClock())
            let media = UUID()
            e.setTimeline(singleClip(media, frames: 30))
            e.seek(to: fd * 3)
            await e.waitForDecodes()
            _ = e.tick()
            let shown = read(try #require(e.lastRenderedTexture), device: device)
            #expect(shown == .offline)
            #expect(e.decodeCalls == 0)
        }
    }

    @Test func damagedMediaDoesNotStallOtherLayers() async throws {
        let bad = try await AVDemuxer(url: try await truncated(120, fraction: 60))
        var spec = TestClipSpec(); spec.frameCount = 120; spec.frameDuration = TestClipSpec.fps(30)
        let good = try await AVDemuxer(url: try await TestClipWriter.write(spec))
        let (mBad, mGood) = (UUID(), UUID())
        let len = fd * 120
        let a = Clip(name: "good", media: mGood, kind: .video, source: TimeRange(start: .zero, duration: len), start: .zero, mediaDuration: len)
        var anim = ClipAnimation(); anim.position = AnimatedProperty(Vec2(0, 90))
        let b = Clip(name: "bad", media: mBad, kind: .video, source: TimeRange(start: .zero, duration: len), start: .zero,
                     mediaDuration: len, animation: anim)
        let tl = Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [a]), Track(kind: .video, clips: [b])])
        let rig = try Rig([mBad: bad, mGood: good], timeline: tl)
        for k in stride(from: 0, to: 120, by: 7) {
            _ = await rig.frame(k)
            #expect(rig.shown(y0: 0) == .stamp(k))              // the healthy layer is always exact
        }
        _ = await rig.frame(119)
        #expect(rig.shown(y0: 0) == .stamp(119))
        #expect(rig.engine.decodeCalls <= 2 * 12 + 2)
    }

    @Test func vfrClipMapsToFramesAtOrBeforeTime() async throws {
        var spec = TestClipSpec()
        let steps: [Int32] = [0, 1, 3, 4, 8, 9, 10, 14, 15, 16, 20, 21]
        spec.presentationTimes = steps.map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
        let media = UUID()
        let rig = try Rig([media: d], timeline: singleClip(media, frames: 22))
        for k in 0..<22 {
            let expected = steps.lastIndex { Int($0) <= k }!
            #expect(await rig.frame(k) == .stamp(expected))
        }
        // Playing through gives the same sequence.
        rig.engine.seek(to: .zero); await rig.engine.waitForDecodes(); _ = rig.engine.tick()
        rig.engine.play()
        var got: [Int] = []
        for _ in 1..<22 {
            await rig.engine.waitForDecodes()
            rig.clock.advance(by: fd); _ = rig.engine.tick()
            if case .stamp(let s)? = rig.shown() { got.append(s) }
        }
        #expect(got == (1..<22).map { k in steps.lastIndex { Int($0) <= k }! })
    }

    @Test func startOffsetClipShowsFirstPresentedFrameAtTimelineStart() async throws {
        var spec = TestClipSpec(); spec.frameCount = 24; spec.startOffset = CMTime(value: 1, timescale: 10)
        spec.frameDuration = TestClipSpec.fps(30)
        let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
        let media = UUID()
        let rig = try Rig([media: d], timeline: singleClip(media, frames: d.index.count, duration: d.index.duration))
        let first = await rig.frame(0)
        guard case .stamp(let s0)? = first else { Issue.record("frame 0 is \(String(describing: first))"); return }
        #expect(s0 == 0)       // first presented frame, not black / placeholder
        let last = await rig.frame(d.index.count - 1)
        #expect(last == .stamp(23))
    }
}

private final class Box: @unchecked Sendable { var value: Result<any Demuxing, any Error>? }
extension Result where Failure == any Error {
    fileprivate init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
