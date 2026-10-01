import Testing
import Foundation
import CoreMedia
import Metal
import SSCore
import SSMedia
import SSMediaTestSupport
@testable import SSPlayback

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

/// One generated 60-frame H.264 clip (320x180, 30 fps, stamps 0...59), shared by all tests.
private actor SpeedSharedClip {
    static let shared = SpeedSharedClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 60
        spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

/// Reads the FrameStamp (16 black/white 16x16 blocks, bit 0 leftmost) from an rgba16Float texture at row `y0`.
private func speedReadStamp(_ texture: MTLTexture, device: MTLDevice, y0: Int = 0) -> Int? {
    let w = texture.width, h = texture.height
    let bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    var value = 0
    for bit in 0..<FrameStamp.bitCount {
        var sum: Float = 0, n: Float = 0
        for y in (y0 + 4)..<(y0 + 12) {
            for x in (bit * 16 + 4)..<(bit * 16 + 12) {
                let i = y * w * 4 + x * 4
                sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
            }
        }
        let v = sum / n
        if v > 0.3 && v < 0.7 { return nil }
        if v >= 0.7 { value |= 1 << bit }
    }
    return value
}


/// Plays a clip of the 60-frame stamped test media at constant speed / reversed through the real engine
/// (decoder, planner, cache, compositor) and reads back which source frame each timeline frame shows.
@MainActor
private func stamps(speed: ClipSpeed, reversed: Bool = false, sourceFrames: Int64 = 60, playing: Bool = false) async throws
    -> (stamps: [Int], dropped: Int) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let demuxer = try await AVDemuxer(url: try await SpeedSharedClip.shared.get())
    let media = UUID()
    let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: demuxer]), clock: ManualClock())
    let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * sourceFrames),
                    start: .zero, mediaDuration: fd * 60, speed: speed, reversed: reversed)
    engine.setTimeline(Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])]))
    let count = Int(clip.duration.frameIndex(frameDuration: fd))
    var out: [Int] = []
    for i in 0..<count {
        engine.seek(to: fd * Int64(i))
        await engine.waitForDecodes()
        _ = engine.tick()
        if let tex = engine.lastRenderedTexture, let s = speedReadStamp(tex, device: device) { out.append(s) }
    }
    return (out, engine.stats.droppedFrames)
}

@Suite(.serialized) @MainActor struct SpeedPlaybackTests {
    @Test func doubleSpeedShowsEverySecondSourceFrame() async throws {
        let r = try await stamps(speed: ClipSpeed(percent: 200))
        #expect(r.stamps == Array(stride(from: 0, to: 60, by: 2)))
    }

    @Test func halfSpeedRepeatsEachSourceFrameTwice() async throws {
        let r = try await stamps(speed: ClipSpeed(percent: 50), sourceFrames: 20)
        #expect(r.stamps == (0..<20).flatMap { [$0, $0] })
    }

    @Test func nonIntegerRatioPicksTheFrameShownAtThatTime() async throws {
        let r = try await stamps(speed: ClipSpeed(percent: 250), sourceFrames: 50)      // 20 timeline frames
        #expect(r.stamps == (0..<20).map { Int(Double($0) * 2.5) })
    }

    @Test func reversedClipPlaysTheSourceBackwards() async throws {
        let r = try await stamps(speed: .normal, reversed: true)
        #expect(r.stamps == Array((0..<60).reversed()))
    }

    @Test func reversedDoubleSpeed() async throws {
        let r = try await stamps(speed: ClipSpeed(percent: 200), reversed: true)
        #expect(r.stamps == Array(stride(from: 58, through: 0, by: -2)))
    }
}
