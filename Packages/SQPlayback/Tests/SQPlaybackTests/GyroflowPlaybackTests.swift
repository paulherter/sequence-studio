import CoreVideo
import Foundation
import Metal
import Synchronization
import SQAnalysis
import SQCore
import SQMedia
import SQMediaTestSupport
import Testing
@testable import SQPlayback

// Gyroflow Stabilizer in playback (docs/GYROFLOW.md step 5): the decoded frame goes through the same engine warp as
// export (without waiting), with the frame's time in the file; the engine's observer redraws.

private final class WhiteGyroEngine: GyroStabilizationEngine, @unchecked Sendable {
    struct Call: Equatable { let path: String; let ts: Int64; let wait: Bool }
    let calls = Mutex<[Call]>([])
    let observers = Mutex(0)
    var availability: GyroEngineAvailability { .available }
    func addObserver(_ f: @escaping @Sendable () -> Void) { observers.withLock { $0 += 1 } }
    /// A white frame in the input's format (bi-planar 8-bit: Y 235, CbCr 128).
    func warp(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64, wait: Bool) -> CVPixelBuffer? {
        calls.withLock { $0.append(Call(path: path, ts: timestampUS, wait: wait)) }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), CVPixelBufferGetPixelFormatType(frame),
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                             kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pb)
        guard let pb, CVPixelBufferGetPlaneCount(pb) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        for (plane, v) in [(0, UInt8(235)), (1, UInt8(128))] {
            memset(CVPixelBufferGetBaseAddressOfPlane(pb, plane), Int32(v),
                   CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}

private struct GyroResolver: MediaResolver {
    let base: StaticMediaResolver
    let gyroWarper: GyroFrameWarper?
    func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
    func audio(for media: UUID) throws -> any SQMedia.AudioSource { try base.audio(for: media) }
}

private func readback(_ texture: MTLTexture, device: MTLDevice) -> [Float16] {
    let w = texture.width, h = texture.height, bpr = w * 8
    let queue = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

@Suite(.serialized) @MainActor struct GyroflowPlaybackTests {
    private func render(stabilizer: Bool) async throws -> (centre: Double, engine: WhiteGyroEngine) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec(); spec.width = 320; spec.height = 180; spec.frameCount = 10
        let url = try await TestClipWriter.write(spec)
        let media = UUID()
        let gyro = WhiteGyroEngine()
        let resolver = GyroResolver(base: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]),
                                    gyroWarper: GyroFrameWarper(engine: gyro, path: { $0 == media ? "/clips/a.mp4" : nil }))
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        let fd = Time(1, 30)
        var effects: [ClipEffect] = []
        if stabilizer {
            var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
            e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(Double(StabilizerMethod.gyroflow.rawValue))
            effects = [e]
        }
        let clip = Clip(name: "a", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 10),
                        start: .zero, mediaDuration: fd * 10, effects: effects)
        engine.setTimeline(Timeline(name: "a", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: fd * 3)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        let px = readback(tex, device: device)
        let i = ((tex.height / 2) * tex.width + tex.width / 2) * 4
        return (Double(px[i + 1]), gyro)
    }

    @Test func playbackShowsTheWarpedFrameWithoutWaiting() async throws {
        let (c, gyro) = try await render(stabilizer: true)
        #expect(c > 0.8, "center \(c): the warped (white) frame is drawn")
        #expect(gyro.calls.withLock { $0 }.contains(.init(path: "/clips/a.mp4", ts: 100_000, wait: false)))
        #expect(gyro.observers.withLock { $0 } == 1)
    }

    @Test func aClipWithoutGyroflowIsNotWarped() async throws {
        let (c, gyro) = try await render(stabilizer: false)
        #expect(c < 0.8, "center \(c)")
        #expect(gyro.calls.withLock { $0 }.isEmpty)
    }
}
