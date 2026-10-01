import CoreVideo
import Foundation
import Metal
import Testing
import SSCore
import SSText
@testable import SSPlayback

@Suite(.serialized) @MainActor struct TextPlaybackTests {
    @Test func textClipRendersInThePlayer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        let style = TextStyle(fontName: "Helvetica-Bold", size: 60, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "HHHH", style: style), animations: nil)
        let id = UUID()
        let clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)),
                        start: .zero, generator: ref)
        let tl = Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: Time(1, 30)),
                          tracks: [Track(kind: .video, clips: [clip])])
        engine.setTimeline(tl)
        engine.seek(to: Time(1, 1))
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        let w = tex.width, h = tex.height
        let px = try #require(readback(tex, device: device))
        // Some pixel in the middle band is lit.
        var lit = 0
        for y in (h / 2 - 30)..<(h / 2 + 30) { for x in 40..<(w - 40) where Float(px[(y * w + x) * 4 + 3]) > 0.5 { lit += 1 } }
        #expect(lit > 50, "lit \(lit)")
    }
}

private func readback(_ texture: MTLTexture, device: MTLDevice) -> [Float16]? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let p = buf.contents().assumingMemoryBound(to: Float16.self)
    return Array(UnsafeBufferPointer(start: p, count: w * h * 4))
}
