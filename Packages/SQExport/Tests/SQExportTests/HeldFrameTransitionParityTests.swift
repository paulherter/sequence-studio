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

// Premiere parity fix 8: a transition at a cut where neither clip has media beyond it repeats the edge frames. With real
// decoders: the export shows the edge frame (same picture as a clip frozen on it) and the monitor shows what the export
// writes, frame for frame.

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

@Suite(.serialized) @MainActor struct HeldFrameTransitionParityTests {
    /// Two whole 60-frame clips end to end (no media beyond the cut on either side), a 20-frame Cross Dissolve centered on
    /// the cut at 60. `holdA` / `holdB`: that clip frozen on its edge frame instead (the reference pictures).
    private func timeline(_ a: UUID, _ b: UUID, _ spec: TestClipSpec, holdA: Bool = false, holdB: Bool = false) throws -> Timeline {
        var ca = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero, mediaDuration: f(60))
        var cb = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(60), mediaDuration: f(60))
        if holdA { ca.holdFrame = f(59) }
        if holdB { cb.holdFrame = .zero }
        var track = Track(kind: .video)
        try track.overwrite(ca); try track.overwrite(cb)
        var tl = Timeline(name: "held", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd), tracks: [track])
        if holdA || holdB {
            // The references keep the same centered span (a frozen clip has unlimited handles; Apply would move it).
            tl.tracks[0].transitions = [Transition(kind: .crossDissolve, duration: f(20), outgoing: ca.id, incoming: cb.id)]
        } else {
            try tl.addTransition(kind: .crossDissolve, track: tl.tracks[0].id, outgoing: ca.id, incoming: cb.id, duration: f(20))
        }
        return tl
    }

    private func exported(_ tl: Timeline, sequences: [Timeline.ID: Timeline] = [:], urls: [UUID: URL],
                          frames: [Int64]) async throws -> [Int64: (bytes: [UInt8], rowBytes: Int)] {
        var demuxers: [UUID: any Demuxing] = [:]
        for (id, url) in urls { demuxers[id] = try await AVDemuxer(url: url) }
        let src = try TimelineFrameSource(timeline: tl, sequences: sequences,
                                          provider: DecoderFrameProvider(resolver: StaticMediaResolver(demuxers: demuxers, audio: [:])),
                                          width: tl.format.width, height: tl.format.height, frameDuration: fd, frameCount: 120)
        var out: [Int64: (bytes: [UInt8], rowBytes: Int)] = [:]
        for i in 0..<120 {
            let pb = try await src.frame(at: i)
            if frames.contains(Int64(i)) { out[Int64(i)] = bgra(pb) }
        }
        return out
    }

    private func shown(_ tl: Timeline, sequences: [Timeline.ID: Timeline] = [:], urls: [UUID: URL], frames: [Int64],
                       device: MTLDevice) async throws -> [Int64: [Float16]] {
        var demuxers: [UUID: any Demuxing] = [:]
        for (id, url) in urls { demuxers[id] = try await AVDemuxer(url: url) }
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: demuxers, audio: [:]), clock: ManualClock())
        engine.quality = .full
        engine.setTimeline(tl, sequences: sequences)
        var out: [Int64: [Float16]] = [:]
        for n in frames {
            engine.seek(to: f(n))
            var done = false
            for _ in 0..<200 {
                _ = engine.tick()
                if let p = engine.lastTickProfile, p.time == f(n), p.presented, p.missing == 0, p.noFrame == 0 { done = true; break }
                await engine.waitForDecodes()
            }
            #expect(done, "frame \(n) never completed")
            out[n] = pixels(try #require(engine.lastRenderedTexture), device: device)
        }
        return out
    }

    /// Two nested sequences (each one whole 60-frame clip) end to end with Cmd+D: the held halves show the nested clips'
    /// edge pictures, exactly what the same edit with plain clips shows, and the monitor matches the export.
    @Test func nestedClipsHoldTheirEdgeFramesLikePlainClips() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        let a = UUID(), b = UUID()
        let urls = [a: try await TestClipWriter.write(spec), b: try await TestClipWriter.write(spec)]
        defer { for u in urls.values { try? FileManager.default.removeItem(at: u) } }
        let format = SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd)
        func inner(_ media: UUID, _ name: String) throws -> Timeline {
            var tr = Track(kind: .video)
            try tr.overwrite(Clip(name: name, media: media, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero,
                                  mediaDuration: f(60)))
            return Timeline(name: name, format: format, tracks: [tr])
        }
        let ia = try inner(a, "A"), ib = try inner(b, "B")
        let na = Clip(name: "A", media: ia.id, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero,
                      mediaDuration: f(60), sequence: ia.id)
        let nb = Clip(name: "B", media: ib.id, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(60),
                      mediaDuration: f(60), sequence: ib.id)
        var track = Track(kind: .video)
        try track.overwrite(na); try track.overwrite(nb)
        var outer = Timeline(name: "outer", format: format, tracks: [track])
        try outer.addTransition(kind: .crossDissolve, track: outer.tracks[0].id, outgoing: na.id, incoming: nb.id, duration: f(20))
        let r = try #require(outer.resolvedTransitions(on: outer.tracks[0].id).first)
        #expect(r.heldBefore == 10 && r.heldAfter == 10)
        let seqs = [ia.id: ia, ib.id: ib]
        // The evaluator asks the inner sequences for their edge frames (never an empty half).
        let early = outer.videoLayers(at: f(55), sequences: { seqs[$0] })
        let late = outer.videoLayers(at: f(65), sequences: { seqs[$0] })
        #expect(early.count == 2 && early[1].sourceTime == .zero && late.count == 2 && late[0].sourceTime == f(59))

        let frames: [Int64] = [50, 55, 59, 60, 65, 69]
        let nested = try await exported(outer, sequences: seqs, urls: urls, frames: frames)
        let plain = try await exported(try timeline(a, b, spec), urls: urls, frames: frames)
        // Same picture as plain clips (the nested group composites in its own pass: a rounding step, not a different frame).
        for n in frames {
            let x = try #require(nested[n]), y = try #require(plain[n])
            var worst = 0
            for i in stride(from: 0, to: min(x.bytes.count, y.bytes.count), by: 7) { worst = max(worst, abs(Int(x.bytes[i]) - Int(y.bytes[i]))) }
            #expect(worst <= 3, "frame \(n): nested held picture differs from plain clips by \(worst)")
        }
        let mon = try await shown(outer, sequences: seqs, urls: urls, frames: frames, device: device)
        for n in frames {
            let m = try #require(mon[n]), e = try #require(nested[n])
            var worst = 0
            for y in stride(from: 2, to: spec.height, by: 6) {
                for x in stride(from: 2, to: spec.width, by: 6) {
                    let i = (y * spec.width + x) * 4, j = y * e.rowBytes + x * 4
                    for k in 0..<3 { worst = max(worst, abs(rec709(Double(m[i + k])) - Int(e.bytes[j + 2 - k]))) }
                }
            }
            #expect(worst <= 3, "frame \(n): playback and export differ by \(worst)")
        }
    }

    @Test func heldEdgeFramesMatchFrozenClipsAndPlaybackMatchesExport() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        let a = UUID(), b = UUID()
        let urls = [a: try await TestClipWriter.write(spec), b: try await TestClipWriter.write(spec)]
        defer { for u in urls.values { try? FileManager.default.removeItem(at: u) } }

        let tl = try timeline(a, b, spec)
        let r = try #require(tl.resolvedTransitions(on: tl.tracks[0].id).first)
        #expect(r.span == TimeRange(start: f(50), duration: f(20)) && r.heldBefore == 10 && r.heldAfter == 10)

        let frames: [Int64] = [49, 50, 53, 59, 60, 64, 69, 70]
        let held = try await exported(tl, urls: urls, frames: frames)
        // Before the cut B shows its first frame, held: the same picture as B frozen on frame 0.
        let frozenB = try await exported(try timeline(a, b, spec, holdB: true), urls: urls, frames: [50, 53, 59])
        for n: Int64 in [50, 53, 59] { #expect(held[n]?.bytes == frozenB[n]?.bytes, "frame \(n): B is not held on its first frame") }
        // After the cut A shows its last frame, held: the same picture as A frozen on frame 59.
        let frozenA = try await exported(try timeline(a, b, spec, holdA: true), urls: urls, frames: [60, 64, 69])
        for n: Int64 in [60, 64, 69] { #expect(held[n]?.bytes == frozenA[n]?.bytes, "frame \(n): A is not held on its last frame") }
        // The dissolve really moves (not one frozen mix).
        #expect(held[53]?.bytes != held[59]?.bytes && held[60]?.bytes != held[69]?.bytes)

        // The monitor shows what the export writes (8-bit Rec.709 against the monitor's linear float picture).
        let mon = try await shown(tl, urls: urls, frames: frames, device: device)
        for n in frames {
            let m = try #require(mon[n]), e = try #require(held[n])
            var worst = 0
            for y in stride(from: 2, to: spec.height, by: 6) {
                for x in stride(from: 2, to: spec.width, by: 6) {
                    let i = (y * spec.width + x) * 4, j = y * e.rowBytes + x * 4
                    for k in 0..<3 { worst = max(worst, abs(rec709(Double(m[i + k])) - Int(e.bytes[j + 2 - k]))) }
                }
            }
            #expect(worst <= 3, "frame \(n): playback and export differ by \(worst)")
        }
    }
}
