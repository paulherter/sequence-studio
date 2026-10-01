import Testing
import Foundation
import CoreVideo
import SQCore
import SQMedia
import SQPlayback
@testable import SQExport

private let fd = Time(1, 30)
private let redID = UUID(), greenID = UUID()

private func bgra(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let p = base + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

/// BT.709 OETF (what the export applies to the working-linear result), 0...255.
private func oetf255(_ l: Double) -> Double { (l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099) * 255 }

private func dissolveTimeline(kind: TransitionKind = .crossDissolve, alignment: TransitionAlignment = .center,
                              frames: Int64 = 20) throws -> Timeline {
    // A: red, 60 frames from source 1 s; B: green, 60 frames from source 1 s; both media 4 s: 30 frames of handle each side.
    let a = Clip(name: "A", media: redID, kind: .video, source: TimeRange(start: Time(1, 1), duration: fd * 60), start: .zero, mediaDuration: Time(4, 1))
    let b = Clip(name: "B", media: greenID, kind: .video, source: TimeRange(start: Time(1, 1), duration: fd * 60), start: fd * 60, mediaDuration: Time(4, 1))
    var t = Track(kind: .video); try t.overwrite(a); try t.overwrite(b)
    var tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd), tracks: [t])
    try tl.addTransition(kind: kind, track: t.id, outgoing: a.id, incoming: b.id, duration: fd * frames, alignment: alignment)
    return tl
}

@Suite struct TransitionExportTests {
    private func provider() -> SolidProvider {
        SolidProvider(colors: [redID: (0, 0, 255), greenID: (0, 255, 0)], width: 64, height: 32)
    }

    @Test func crossDissolveBlendsInLinearLight() async throws {
        let src = try TimelineFrameSource(timeline: try dissolveTimeline(), provider: provider(), width: 64, height: 32,
                                          frameDuration: fd, frameCount: 120)
        // Span is frames 50..<70 (20 frames); the incoming weight of frame i is (i + 1) / 21: 25 %, 50 %, 75 % of the way.
        for (frame, w) in [(50 + 4, 5.0 / 21), (50 + 9, 10.0 / 21), (50 + 14, 15.0 / 21)] {
            let c = bgra(try await src.frame(at: frame), 32, 16)
            let expR = oetf255(1 - w), expG = oetf255(w)
            #expect(abs(Double(c.r) - expR) <= 3 && abs(Double(c.g) - expG) <= 3 && c.b <= 3, "frame \(frame): \(c) vs R \(expR) G \(expG)")
        }
        // Outside the span the clips are untouched.
        let before = bgra(try await src.frame(at: 49), 32, 16), after = bgra(try await src.frame(at: 70), 32, 16)
        #expect(before.r > 250 && before.g < 3 && after.g > 250 && after.r < 3)
    }

    @Test func dipToBlackPassesThroughBlack() async throws {
        let src = try TimelineFrameSource(timeline: try dissolveTimeline(kind: .dipToBlack, frames: 21), provider: provider(),
                                          width: 64, height: 32, frameDuration: fd, frameCount: 120)
        // 21 frames centred: span 49.5 -> starts at frame 50 (10 before, 11 after); frame 10 of 21 has weight 0.5.
        let mid = bgra(try await src.frame(at: 50 + 10), 32, 16)
        #expect(mid.r <= 3 && mid.g <= 3 && mid.b <= 3)
        let early = bgra(try await src.frame(at: 50 + 3), 32, 16)       // weight 4/22: A at 1 - 2w = 0.636 of red
        #expect(early.r > 150 && early.g <= 3)
    }

    @Test func dipToWhiteMidpointIsWhite() async throws {
        let src = try TimelineFrameSource(timeline: try dissolveTimeline(kind: .dipToWhite, frames: 21), provider: provider(),
                                          width: 64, height: 32, frameDuration: fd, frameCount: 120)
        let mid = bgra(try await src.frame(at: 60), 32, 16)
        #expect(mid.r >= 252 && mid.g >= 252 && mid.b >= 252)
    }

    // MARK: Audio

    private func sine(_ hz: Double, _ seconds: Int) -> MemoryAudioSource {
        MemoryAudioSource(mono: (0..<(48_000 * seconds)).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / 48_000)) })
    }

    private func audioTimeline(_ kind: TransitionKind) throws -> (Timeline, UUID, UUID) {
        let ma = UUID(), mb = UUID()
        // A: 440 Hz, B: 1 kHz; each plays one second from source 0.5 s of a 3 s file: 15+ frames of handle each side.
        let a = Clip(name: "A", media: ma, kind: .audio, source: TimeRange(start: Time(1, 2), duration: Time(1, 1)), start: .zero, mediaDuration: Time(3, 1))
        let b = Clip(name: "B", media: mb, kind: .audio, source: TimeRange(start: Time(1, 2), duration: Time(1, 1)), start: Time(1, 1), mediaDuration: Time(3, 1))
        var t = Track(kind: .audio); try t.overwrite(a); try t.overwrite(b)
        var tl = Timeline(name: "t", format: SequenceFormat(frameDuration: fd), tracks: [t])
        try tl.addTransition(kind: kind, track: t.id, outgoing: a.id, incoming: b.id, duration: fd * 30)   // 1 s, 0.5 s each side
        return (tl, ma, mb)
    }

    private func render(_ tl: Timeline, _ ma: UUID, _ mb: UUID, seconds: Int) async throws -> [Float] {
        let resolver = StaticMediaResolver(audio: [ma: sine(440, 3), mb: sine(1000, 3)])
        let src = TimelineAudioSource(timeline: tl, range: TimeRange(start: .zero, duration: Time(Int64(seconds), 1)), resolver: resolver)
        var left: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 4096) {
            for i in stride(from: 0, to: chunk.samples.count, by: 2) { left.append(chunk.samples[i]) }
        }
        return left
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let p = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        return 10 * log10(p)
    }

    @Test func constantPowerCrossfadeKeepsTheLevelWithinOneDB() async throws {
        let (tl, ma, mb) = try audioTimeline(.constantPower)
        let out = try await render(tl, ma, mb, seconds: 2)
        #expect(out.count >= 96_000)
        let ref = 10 * log10(0.5 * 0.5 / 2)                    // RMS of a 0.5-amplitude sine
        // 50 ms windows from 0.1 s to 1.9 s: before, through and after the crossfade (0.5 s ... 1.5 s).
        var worst = 0.0
        for start in stride(from: 4_800, to: 91_200, by: 2_400) {
            worst = max(worst, abs(rmsDB(out[start..<(start + 2_400)]) - ref))
        }
        NSLog("transition audio: constant power crossfade, worst window deviation \(worst) dB")
        #expect(worst < 1.0)
        // The tails are the pure clips: before the span only A (440 Hz at full level), after it only B.
        #expect(abs(rmsDB(out[4_800..<7_200]) - ref) < 0.05 && abs(rmsDB(out[84_000..<86_400]) - ref) < 0.05)
    }

    @Test func constantGainCrossfadeDipsInPowerAndEndsExact() async throws {
        let (tl, ma, mb) = try audioTimeline(.constantGain)
        let out = try await render(tl, ma, mb, seconds: 2)
        let ref = 10 * log10(0.5 * 0.5 / 2)
        // Uncorrelated tones with linear gains lose 3 dB in the middle (the known Constant Gain behaviour).
        let mid = rmsDB(out[47_000..<49_000])
        #expect(mid < ref - 2.5 && mid > ref - 3.5)
        #expect(abs(rmsDB(out[4_800..<7_200]) - ref) < 0.05)
    }

    @Test func incomingClipPlaysItsHeadBeforeTheCut() async throws {
        let (tl, ma, mb) = try audioTimeline(.constantGain)
        let out = try await render(tl, ma, mb, seconds: 2)
        // Just before the cut at 1.0 s B is already audible: correlate with 1 kHz in the window 0.9 ... 0.95 s.
        let w = out[43_200..<45_600]
        var corr = 0.0
        for (i, s) in w.enumerated() { corr += Double(s) * sin(2 * Double.pi * 1000 * (Double(i + 43_200) / 48_000 - 1.0 + 0.5)) }
        #expect(abs(corr) > 10)
    }
}
