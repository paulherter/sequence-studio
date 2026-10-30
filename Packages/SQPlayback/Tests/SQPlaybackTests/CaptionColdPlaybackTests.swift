import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQText
@testable import SQPlayback

/// The maintainer: word-by-word captions sometimes vanish for one frame on the first play after a seek; the second play is perfect.
/// One tick per frame (playback, no retries) on a cold text cache must show the caption on every frame, identical to
/// the same frames played again warm.
@Suite(.serialized) @MainActor struct CaptionColdPlaybackTests {
    @Test func coldCaptionsNeverDropAFrameDuringPlayback() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: clock)
        let fd = Time(1, 30)
        let format = SequenceFormat(width: 1080, height: 1920, frameDuration: fd)
        // A text clip far off canvas only gives the sequence its length.
        let style = TextStyle(fontName: "Helvetica-Bold", size: 20, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "i", style: style), animations: nil)
        let id = UUID()
        var clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                        start: .zero, generator: ref)
        clip.animation.position = AnimatedProperty(Vec2(5000, 5000))
        var tl = Timeline(name: "s", format: format, tracks: [Track(kind: .video, clips: [clip])])
        // Word-by-word captions: back to back, 9 frames each, two words per caption, the caption pop, karaoke on.
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        var items: [CaptionItem] = []
        for i in stride(from: 0, to: words.count, by: 2) {
            let start = fd * Int64(i / 2 * 9), mid = start + fd * 4, end = start + fd * 9
            let ws = [CaptionWord(text: words[i], range: TimeRange(start: start, end: mid)),
                      CaptionWord(text: words[i + 1], range: TimeRange(start: mid, end: end))]
            items.append(CaptionItem(lines: ["\(words[i]) \(words[i + 1])"], range: TimeRange(start: start, end: end),
                                     styleRef: "tiktok", animationRef: CaptionLook.popAnimationID, words: ws))
        }
        let track = try tl.replaceCaptions(items)
        try tl.setCaptionKaraoke(KaraokeStyle(), track: track)
        let frames = items.count * 9
        engine.setTimeline(tl)

        /// One pass in playback order: one tick per frame, then the clock moves on by one frame.
        func pass() throws -> [Double] {
            engine.pause()
            engine.seek(to: .zero)
            _ = engine.tick()
            engine.play()
            var sums: [Double] = []
            for f in 0..<frames {
                #expect(engine.tick(), "frame \(f) not presented")
                let tex = try #require(engine.lastRenderedTexture)
                sums.append(try #require(bottomHalfSum(tex, device: device)))
                clock.advance(by: fd)
            }
            return sums
        }

        TextGenerator.clearCache()
        let before = engine.stats.captionSyncRenders
        let cold = try pass()
        let syncRenders = engine.stats.captionSyncRenders - before
        let warm = try pass()
        for f in 0..<frames {
            #expect(cold[f] > 1000, "frame \(f): no caption on the cold pass (\(cold[f]))")
            #expect(abs(cold[f] - warm[f]) <= warm[f] * 0.001, "frame \(f): cold \(Int(cold[f])) vs warm \(Int(warm[f]))")
        }
        let ms = Double(engine.stats.maxCaptionSyncRender.components.attoseconds) / 1e15
            + Double(engine.stats.maxCaptionSyncRender.components.seconds) * 1000
        print("caption cold pass: \(syncRenders) synchronous raster renders, slowest \(String(format: "%.2f", ms)) ms (1080x1920)")
    }
}

/// Sum of the color channels over the lower half (every second row and column) of the composite (where the captions sit).
private func bottomHalfSum(_ texture: MTLTexture, device: MTLDevice) -> Double? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let p = buf.contents().assumingMemoryBound(to: Float16.self)
    var sum: Float = 0
    for y in stride(from: h / 2, to: h, by: 2) {
        let row = y * w * 4
        for x in stride(from: 0, to: w * 4, by: 8) { sum += Float(p[row + x]) + Float(p[row + x + 1]) + Float(p[row + x + 2]) }
    }
    return Double(sum)
}
