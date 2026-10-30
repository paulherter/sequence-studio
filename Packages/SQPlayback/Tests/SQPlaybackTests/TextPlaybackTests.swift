import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQText
@testable import SQPlayback

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
        // The first raster is rendered on a background task: the layer is invisible until it is ready, then the loop redraws.
        var lit = 0, w = 0, h = 0
        for _ in 0..<100 {
            _ = engine.tick()
            if let tex = engine.lastRenderedTexture, let px = readback(tex, device: device) {
                w = tex.width; h = tex.height; lit = 0
                for y in (h / 2 - 30)..<(h / 2 + 30) { for x in 40..<(w - 40) where Float(px[(y * w + x) * 4]) > 0.5 { lit += 1 } }
                if lit > 50 { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lit > 50, "lit \(lit)")
    }
}

@Suite(.serialized) @MainActor struct CaptionPlaybackTests {
    /// A caption on the caption track shows in the Program monitor at the bottom, only while it is active.
    @Test func captionShowsAtTheBottomWhileActive() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        // A tiny text clip near the top left only gives the sequence a length; the caption is what is measured.
        let style = TextStyle(fontName: "Helvetica-Bold", size: 20, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "i", style: style), animations: nil)
        let id = UUID()
        var clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                        start: .zero, generator: ref)
        clip.animation.position = AnimatedProperty(Vec2(-140, -70))
        var tl = Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: Time(1, 30)),
                          tracks: [Track(kind: .video, clips: [clip])])
        _ = try tl.replaceCaptions([CaptionItem(lines: ["HHHH"], range: TimeRange(start: Time(1, 1), end: Time(2, 1)),
                                                styleRef: "title")])
        engine.setTimeline(tl)

        func lit(in rows: Range<Int>, at t: Time) async throws -> Int {
            engine.seek(to: t)
            var best = 0
            for _ in 0..<100 {
                _ = engine.tick()
                if let tex = engine.lastRenderedTexture, let px = readback(tex, device: device) {
                    let w = tex.width
                    best = 0
                    for y in rows { for x in 20..<(w - 20) where Float(px[(y * w + x) * 4]) > 0.5 { best += 1 } }
                    if best > 50 { break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return best
        }
        let bottom = 110..<175
        let during = try await lit(in: bottom, at: Time(3, 2))
        #expect(during > 50, "caption pixels \(during)")
        // The 72 pt "title" line is taller than the caption box (rows 104..<158) and bottom-aligned in it, so its cap
        // tops reach up to about row 88 (Inter sits a row or two higher than Helvetica). "Top" is the part of the
        // picture clearly above that: a caption placed at the top or the middle would light hundreds of pixels there.
        let top = try await lit(in: 0..<80, at: Time(3, 2))
        #expect(top < 30, "the caption stays at the bottom, \(top) lit pixels above")
        let after = try await lit(in: bottom, at: Time(5, 2))
        #expect(after < 30, "no caption after its end, \(after)")
    }
}

@Suite(.serialized) @MainActor struct ExportFrameFollowTests {
    /// Export Frame with a Follow shape whose text target is hidden and not laid out yet: the shape sits on the measured
    /// text box (as export and a warm steady frame do), not where it was authored.
    @Test func exportFrameMeasuresAHiddenColdFollowTarget() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        let fmt = SequenceFormat(width: 640, height: 360, frameDuration: Time(1, 30))
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "C\(Int.random(in: 1000...9999))", style: TextStyle(fontName: "Helvetica-Bold", size: 60, color: .white)), animations: nil)
        var text = GraphicsLayer.text(ref)
        text.isVisible = false
        var box = GraphicsLayer.shape(.rectangle, canvasWidth: 640, canvasHeight: 360)
        box.follow = GraphicsFollow(target: .layer(id: text.id), padding: 10)
        let v1 = Track(kind: .video)
        var p = Project(name: "P", timelines: [Timeline(name: "S", format: fmt, tracks: [v1])])
        let tid = p.timelines[0].id
        _ = try p.addGraphicsClip(in: tid, at: .zero, track: v1.id, duration: Time(4, 1), layers: [box, text])
        TextGenerator.installFollowMeasure()
        engine.setTimeline(p.timelines[0])
        engine.seek(to: Time(1, 1))
        var lit: (w: Int, h: Int)?
        await engine.withFullSizeFrame { r in
            guard case .frame(let tex) = r, let px = readback(tex, device: device) else { return }
            var minX = tex.width, maxX = -1, minY = tex.height, maxY = -1
            for y in 0..<tex.height { for x in 0..<tex.width where Float(px[(y * tex.width + x) * 4]) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            if maxX >= 0 { lit = (maxX - minX + 1, maxY - minY + 1) }
        }
        let want = try #require(TextGenerator.graphicsRect(ref: ref, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: fmt))
        let got = try #require(lit)
        #expect(abs(Double(got.w) - (want.width + 20)) < 3, "w \(got.w) want \(want.width + 20)")
        #expect(abs(Double(got.h) - (want.height + 20)) < 3, "h \(got.h) want \(want.height + 20)")
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
