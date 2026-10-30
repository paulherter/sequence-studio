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

// Hidden layers in playback (PLAYBACK-PERF "Playback: hidden layers"): the monitor leaves out the same layers as the
// export and shows the same picture, with real decoders.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

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

@Suite(.serialized) @MainActor struct PlaybackHiddenLayerTests {
    private struct Shown { var pixels: [Float16]; var hidden: Int; var layers: Int }

    /// A for 60 frames; B (as large as the canvas, Opacity 1) over frames 20..<45, from its source frame 5.
    private func timeline(_ a: UUID, _ b: UUID, _ spec: TestClipSpec) -> Timeline {
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero)
        let upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: f(5), duration: f(25)), start: f(20))
        return Timeline(name: "cover", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                        tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
    }

    /// Paused on each of `frames` in turn, with every exact frame decoded.
    private func shown(_ tl: Timeline, media: [UUID: URL], frames: [Int64], cull: Bool, device: MTLDevice) async throws -> [Int64: Shown] {
        var demuxers: [UUID: any Demuxing] = [:]
        for (id, url) in media { demuxers[id] = try await AVDemuxer(url: url) }
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: demuxers, audio: [:]), clock: ManualClock())
        engine.quality = .full
        engine.cullsHiddenLayers = cull
        engine.setTimeline(tl)
        var out: [Int64: Shown] = [:]
        for n in frames {
            engine.seek(to: f(n))
            var done: TickProfile?
            for _ in 0..<200 {
                _ = engine.tick()
                if let p = engine.lastTickProfile, p.time == f(n), p.presented, p.missing == 0, p.noFrame == 0 { done = p; break }
                await engine.waitForDecodes()
            }
            let p = try #require(done, "frame \(n) never completed")
            out[n] = Shown(pixels: pixels(try #require(engine.lastRenderedTexture), device: device), hidden: p.hidden, layers: p.layers)
        }
        return out
    }

    @Test func playbackLeavesOutTheCoveredLayerAndShowsWhatTheExportWrites() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        let a = UUID(), b = UUID()
        let urls = [a: try await TestClipWriter.write(spec), b: try await TestClipWriter.write(spec)]
        defer { for u in urls.values { try? FileManager.default.removeItem(at: u) } }
        let tl = timeline(a, b, spec)
        let frames: [Int64] = [10, 20, 21, 30, 44, 45, 50, 30, 19]

        // The export with every layer drawn is the reference picture.
        let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: urls[a]!), b: try await AVDemuxer(url: urls[b]!)], audio: [:])
        let src = try TimelineFrameSource(timeline: tl, provider: DecoderFrameProvider(resolver: resolver), width: spec.width,
                                          height: spec.height, frameDuration: fd, frameCount: 60, cullHidden: false)
        var exported: [Int64: (bytes: [UInt8], rowBytes: Int)] = [:]
        for i in 0..<60 {
            let pb = try await src.frame(at: i)
            if frames.contains(Int64(i)) { exported[Int64(i)] = bgra(pb) }
        }

        let all = try await shown(tl, media: urls, frames: frames, cull: false, device: device)
        let culled = try await shown(tl, media: urls, frames: frames, cull: true, device: device)
        for n in Set(frames).sorted() {
            let covered = (20..<45).contains(n)
            let c = try #require(culled[n]), r = try #require(all[n]), e = try #require(exported[n])
            #expect(r.hidden == 0 && r.layers == (covered ? 2 : 1), "frame \(n)")
            #expect(c.hidden == (covered ? 1 : 0) && c.layers == 1, "frame \(n): hidden \(c.hidden), layers \(c.layers)")
            // Same picture with and without the hidden layer, to the bit.
            #expect(c.pixels == r.pixels, "frame \(n): leaving the hidden layer out changed the picture")
            // And the picture the export writes (8-bit Rec.709 against the monitor's linear float picture).
            var worst = 0
            for y in stride(from: 2, to: spec.height, by: 6) {
                for x in stride(from: 2, to: spec.width, by: 6) {
                    let i = (y * spec.width + x) * 4, j = y * e.rowBytes + x * 4
                    for k in 0..<3 { worst = max(worst, abs(rec709(Double(c.pixels[i + k])) - Int(e.bytes[j + 2 - k]))) }
                }
            }
            #expect(worst <= 3, "frame \(n): playback and export differ by \(worst)")
        }
        // The pictures really change where the cover starts and ends.
        #expect(all[19]?.pixels != all[20]?.pixels)
        #expect(all[44]?.pixels != all[45]?.pixels)
    }

    /// A source with an alpha channel never hides what lies below it.
    @Test func aTransparentSourceHidesNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        var alpha = TestClipSpec(); alpha.codec = .prores4444Alpha
        let a = UUID(), b = UUID()
        let urls = [a: try await TestClipWriter.write(spec), b: try await TestClipWriter.write(alpha)]
        defer { for u in urls.values { try? FileManager.default.removeItem(at: u) } }
        let out = try await shown(timeline(a, b, spec), media: urls, frames: [30, 31], cull: true, device: device)
        #expect(out[30]?.hidden == 0 && out[30]?.layers == 2)
        #expect(out[31]?.hidden == 0 && out[31]?.layers == 2)
    }
}
