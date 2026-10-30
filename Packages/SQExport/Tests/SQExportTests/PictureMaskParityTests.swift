import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import SQRender
@testable import SQExport

// C6 T4: a Picture mask renders the same in the export and on the monitor. V1 = an orange solid whose Picture mask reads
// V2; V2 = a hidden track with a white solid at 50 % (the matte). Only the square of V1 shows, never the white.

private let fd = Time(1, 30)

private func bgra(_ pb: CVPixelBuffer) -> (bytes: [UInt8], rowBytes: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let n = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return (Array(UnsafeBufferPointer(start: p, count: n)), CVPixelBufferGetBytesPerRow(pb))
}

private func pixels(_ t: MTLTexture, device: MTLDevice) -> [Float16] {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

private func rec709(_ l: Double) -> Int {
    let l = max(0, min(1, l))
    return Int(((l < 0.018053968510807 ? 4.5 * l : 1.09929682680944 * pow(l, 0.45) - 0.09929682680944) * 255).rounded())
}

@Suite(.serialized) @MainActor struct PictureMaskParityTests {
    let w = 128, h = 72

    func timeline() throws -> Timeline {
        var matte = Clip(name: "matte", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 30), start: .zero,
                         mediaDuration: fd * 30)
        matte.generator = .solid(rgb: [255, 255, 255])
        matte.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        var v2 = Track(kind: .video)
        try v2.overwrite(matte)
        v2.isVisible = false
        var consumer = Clip(name: "consumer", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 30),
                            start: .zero, mediaDuration: fd * 30)
        consumer.generator = .solid(rgb: [230, 120, 40])
        consumer.masks = [ClipMask.makePicture(track: v2.id)]
        var v1 = Track(kind: .video)
        try v1.overwrite(consumer)
        return Timeline(name: "picture", format: SequenceFormat(width: w, height: h, frameDuration: fd), tracks: [v1, v2])
    }

    @Test func exportAndPlaybackShowTheSameMattedPicture() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let tl = try timeline()
        let layers = tl.videoLayers(at: fd * 5)
        #expect(layers.count == 2 && layers[1].matteFor == tl.tracks[1].id)

        let src = try TimelineFrameSource(timeline: tl, sequences: [:],
                                          provider: DecoderFrameProvider(resolver: StaticMediaResolver(demuxers: [:], audio: [:])),
                                          width: w, height: h, frameDuration: fd, frameCount: 10)
        let e = bgra(try await src.frame(at: 5))
        // Export: orange inside the square (x 32..<96, y 18..<54), black outside, never white.
        let mid = 36 * e.rowBytes + 64 * 4
        #expect(abs(Int(e.bytes[mid + 2]) - 230) <= 2 && abs(Int(e.bytes[mid + 1]) - 120) <= 2 && abs(Int(e.bytes[mid]) - 40) <= 2)
        let corner = 4 * e.rowBytes + 4 * 4
        #expect(e.bytes[corner] <= 1 && e.bytes[corner + 1] <= 1 && e.bytes[corner + 2] <= 1)

        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [:], audio: [:]), clock: ManualClock())
        engine.quality = .full
        engine.setTimeline(tl, sequences: [:])
        engine.seek(to: fd * 5)
        var done = false
        for _ in 0..<200 {
            _ = engine.tick()
            if let p = engine.lastTickProfile, p.time == fd * 5, p.presented, p.missing == 0, p.noFrame == 0 { done = true; break }
            await engine.waitForDecodes()
        }
        #expect(done)
        let m = pixels(try #require(engine.lastRenderedTexture), device: device)
        var worst = 0
        for y in stride(from: 1, to: h, by: 3) {
            for x in stride(from: 1, to: w, by: 3) {
                let i = (y * w + x) * 4, j = y * e.rowBytes + x * 4
                for k in 0..<3 { worst = max(worst, abs(rec709(Double(m[i + k])) - Int(e.bytes[j + 2 - k]))) }
            }
        }
        #expect(worst <= 2, "playback and export differ by \(worst)")
    }
}
