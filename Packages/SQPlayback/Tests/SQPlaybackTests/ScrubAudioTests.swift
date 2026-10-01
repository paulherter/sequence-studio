import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

// E-12 scrub audio: pure parts (planner, grain rendering, voice handoff), headless.

private let sr = 48_000
private let fd30 = Time(1, 30)
private let fadeN = 240

/// 440 Hz sine, amplitude 0.5, `seconds` long, both channels.
private func sineSource(seconds: Int = 6) -> MemoryAudioSource {
    let n = seconds * sr
    return MemoryAudioSource(mono: (0..<n).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / Double(sr))) })
}
/// Largest per-sample step of the source itself (the threshold's baseline).
private let naturalStep: Float = Float(0.5 * 2 * Double.pi * 440 / Double(sr))
/// Crossfades may add |a - b| x max ramp slope (pi / (2 x 240) ~ 0.0065) on top of the natural step.
private let threshold: Float = naturalStep + 0.012

private func timeline(clipStart: Time = .zero, duration: Time = Time(6, 1), muted: Bool = false,
                      frameDuration: Time = fd30, media: UUID) -> Timeline {
    let c = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: .zero, duration: duration), start: clipStart)
    return Timeline(name: "S", frameDuration: frameDuration, tracks: [Track(kind: .audio, clips: [c], isMuted: muted)])
}

private func makeScrub(settings: ScrubSettings = ScrubSettings(), muted: Bool = false, clipStart: Time = .zero,
                       duration: Time = Time(6, 1)) -> ScrubAudio {
    let media = UUID(), src = sineSource()
    let s = ScrubAudio(resolver: { _ in src }, settings: settings, inline: true)
    s.setTimeline(timeline(clipStart: clipStart, duration: duration, muted: muted, media: media), sequences: [:])
    return s
}

/// Renders `frames` from the voice in 512-frame calls; returns the left channel (right is identical for the mono source).
private func render(_ v: ScrubVoice, _ frames: Int, call: Int = 512) -> [Float] {
    var out: [Float] = []
    let l = UnsafeMutablePointer<Float>.allocate(capacity: call), r = UnsafeMutablePointer<Float>.allocate(capacity: call)
    defer { l.deallocate(); r.deallocate() }
    var left = frames
    while left > 0 {
        let n = min(call, left)
        _ = v.render(left: l, right: r, count: n)
        for i in 0..<n { #expect(l[i] == r[i]) }
        out.append(contentsOf: UnsafeBufferPointer(start: l, count: n))
        left -= n
    }
    return out
}

private func maxStep(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }
private func peak(_ x: [Float]) -> Float { x.map(abs).max() ?? 0 }
private func ms(_ n: Int64) -> Int64 { n * 1_000_000 }
private func t(_ frame: Int64) -> Time { Time(frame, Int64(sr)) }

@Suite struct ScrubPlannerTests {
    @Test func grainLengthIsOneFrameButAtLeast40ms() {
        let p = ScrubGrainPlanner()
        #expect(p.grainLength(speed: 1, frameDuration: fd30) == 1920)                   // 33 ms frame -> 40 ms
        #expect(p.grainLength(speed: 1, frameDuration: Time(1, 24)) == 2000)            // 41.7 ms
        #expect(p.grainLength(speed: 1, frameDuration: Time(1001, 24_000)) == 2002)     // 23.976: ceil(2002.0)
        #expect(p.grainLength(speed: 0.2, frameDuration: Time(1, 24)) == 2000)
        #expect(p.grainLength(speed: 3, frameDuration: Time(1, 24)) == 1920)            // fast: shortest grains
        #expect(p.grainLength(speed: 1, frameDuration: Time(1, 10)) == 4800)
    }

    @Test func scrubGrainFollowsTheDirectionOfMotion() throws {
        var p = ScrubGrainPlanner()
        p.begin(at: Time(1, 1), hostNanos: 0)
        let f0 = p.scrub(to: Time(1, 1) + Time(1, 60), hostNanos: ms(16), frameDuration: fd30)
        let f = try #require(f0)
        #expect(!f.reverse && f.start == 48_800 && f.hop == 1920 && f.fade == fadeN && f.speed == 1)
        #expect(p.velocity > 1 && p.velocity < 1.1)                                       // 16.7 ms moved in 16 ms
        let b0 = p.scrub(to: Time(1, 1), hostNanos: ms(32), frameDuration: fd30)
        let b = try #require(b0)
        #expect(b.reverse && b.start == 48_000)                                           // reads backwards from here
        #expect(p.scrub(to: Time(1, 1), hostNanos: ms(48), frameDuration: fd30) == nil)  // no movement: no grain
    }

    @Test func velocityResetsAfterAHoldAndFastScrubShortensGrains() throws {
        var p = ScrubGrainPlanner()
        p.begin(at: .zero, hostNanos: 0)
        let g0 = p.scrub(to: Time(1, 10), hostNanos: ms(20), frameDuration: Time(1, 24))      // 5x
        let g = try #require(g0)
        #expect(g.hop == 1920 && p.velocity > 2)
        let h0 = p.scrub(to: Time(1, 10) + Time(1, 1000), hostNanos: ms(1000), frameDuration: Time(1, 24))
        let h = try #require(h0)
        #expect(h.hop == 2000 && abs(p.velocity) < 0.1)                                  // after a hold: slow again
    }

    @Test func varispeedOnlyWhenEnabled() throws {
        var p = ScrubGrainPlanner()
        p.begin(at: .zero, hostNanos: 0)
        let g1 = p.scrub(to: Time(1, 10), hostNanos: ms(33), frameDuration: fd30)
        #expect(g1?.speed == 1)                                      // pitch preserved
        var s = ScrubSettings(); s.maxVarispeed = 2
        var q = ScrubGrainPlanner(settings: s)
        q.begin(at: .zero, hostNanos: 0)
        let g0 = q.scrub(to: Time(1, 10), hostNanos: ms(33), frameDuration: fd30)            // ~3x
        let g = try #require(g0)
        #expect(g.speed == 2 && g.sourceSpan >= 2 * (g.frames - 1))
    }

    @Test func stepGrainIsOneFrameInStepDirection() throws {
        let p = ScrubGrainPlanner()
        let f = try #require(p.step(from: Time(1, 1), to: Time(1, 1) + fd30, frameDuration: fd30))
        #expect(!f.reverse && f.start == 49_600 && f.hop == 1920)
        let b = try #require(p.step(from: Time(1, 1), to: Time(1, 1) - fd30, frameDuration: fd30))
        #expect(b.reverse && b.start == 48_000)                          // end of the new frame, read backwards
        #expect(p.step(from: .zero, to: .zero, frameDuration: fd30) == nil)
    }
}

@Suite struct ScrubVoiceTests {
    /// Forward, backward and jittering drags at mouse-event rate: every grain join is a crossfade, no step above the threshold.
    @Test(arguments: ["forward", "backward", "jitter"])
    func grainJoinsAreContinuous(_ mode: String) {
        let s = makeScrub()
        var pos: Int64 = 2 * 48_000, host: Int64 = 0
        s.begin(at: t(pos), hostNanos: host)
        var out: [Float] = []
        for k in 0..<120 {                                    // 120 events, one per 8 ms render slice (~1 s)
            switch mode {
            case "forward": pos += 400                        // ~1x
            case "backward": pos -= 400
            default: pos += (k % 3 == 0 ? -700 : 450)         // back and forth
            }
            host += ms(8)
            s.scrub(to: t(pos), hostNanos: host)
            out += render(s.voice, 384)
        }
        out += render(s.voice, 4800)                          // tail fades out
        #expect(peak(out) > 0.4, "grains played")
        #expect(maxStep(out) < threshold, "\(mode): max step \(maxStep(out)) >= \(threshold)")
        print("[E-12] \(mode): max step \(maxStep(out)) (source alone \(naturalStep), threshold \(threshold)), \(s.voice.grainsStarted) grains")
        #expect(s.voice.grainsStarted > 10)
        #expect(out.suffix(100).allSatisfy { $0 == 0 }, "silent after the last grain")
    }

    /// The crossfade matters: without it the same drag has steps far above the threshold (sanity check of the measure).
    @Test func hardCutsWouldFailTheThreshold() {
        var set = ScrubSettings(); set.fadeFrames = 1
        let s = makeScrub(settings: set)
        var pos: Int64 = 48_000
        s.begin(at: t(pos), hostNanos: 0)
        var out: [Float] = []
        for k in 0..<60 { pos += 737; s.scrub(to: t(pos), hostNanos: ms(Int64(k + 1) * 8)); out += render(s.voice, 384) }
        #expect(maxStep(out) > 0.1)
        print("[E-12] same drag without crossfades: max step \(maxStep(out))")
    }

    @Test func reverseGrainPlaysTheSourceBackwards() {
        let s = makeScrub()
        s.begin(at: t(96_000), hostNanos: 0)
        s.scrub(to: t(90_000), hostNanos: ms(100))
        let out = render(s.voice, 1920 + fadeN)
        let src = sineSource().left
        for j in stride(from: 300, to: 1900, by: 97) { #expect(abs(out[j] - src[90_000 - 1 - j]) < 1e-5) }
    }

    /// Scrubbing much faster than grains can play: requests replace each other (one pending), nothing queues up,
    /// and the grain that plays next is the latest one.
    @Test func fastScrubReplacesPendingGrains() {
        let s = makeScrub()
        var pos: Int64 = 48_000
        s.begin(at: t(pos), hostNanos: 0)
        for k in 0..<500 { pos += 200; s.scrub(to: t(pos), hostNanos: Int64(k + 1) * 100_000) }
        #expect(s.droppedRequests == 0)
        #expect(s.voice.freeSlots == ScrubVoice.slotCount - 1)          // exactly one pending, nothing else held
        _ = render(s.voice, 512)
        #expect(s.voice.grainsStarted == 1 && s.voice.lastStartedTag == s.lastTag)
        for _ in 0..<500 { pos += 200; s.scrub(to: t(pos), hostNanos: Int64(1_000) * 100_000) }
        let played = render(s.voice, 48_000)                               // 1 s
        #expect(s.voice.grainsStarted == 2 && s.voice.lastStartedTag == s.lastTag)
        #expect(peak(played) > 0.4 && maxStep(played) < threshold)
        #expect(s.voice.freeSlots == ScrubVoice.slotCount)
    }

    @Test func gapAndMutedTrackAreSilent() {
        let gap = makeScrub(clipStart: Time(3, 1), duration: Time(1, 1))   // audio only in [3 s, 4 s)
        gap.begin(at: t(48_000), hostNanos: 0)
        var out: [Float] = []
        for k in 0..<40 { gap.scrub(to: t(48_000 + Int64(k + 1) * 400), hostNanos: ms(Int64(k + 1) * 8)); out += render(gap.voice, 384) }
        #expect(out.allSatisfy { $0 == 0 })
        let muted = makeScrub(muted: true)
        muted.begin(at: t(48_000), hostNanos: 0)
        out = []
        for k in 0..<40 { muted.scrub(to: t(48_000 + Int64(k + 1) * 400), hostNanos: ms(Int64(k + 1) * 8)); out += render(muted.voice, 384) }
        #expect(out.allSatisfy { $0 == 0 })
    }

    /// Scrubbing across a clip edge: the grain's gap part is silent, the join into it stays continuous.
    @Test func clipEdgeInsideAGrainStaysContinuous() {
        let s = makeScrub(clipStart: Time(1, 1), duration: Time(1, 1))
        s.begin(at: t(47_000), hostNanos: 0)
        var out: [Float] = []
        for k in 0..<20 { s.scrub(to: t(47_000 + Int64(k + 1) * 400), hostNanos: ms(Int64(k + 1) * 8)); out += render(s.voice, 384) }
        #expect(peak(out) > 0.4)
        // The sine starts at phase 0 at the clip start, so the edit itself adds no step either.
        #expect(maxStep(out) < threshold)
        print("[E-12] across a clip edge: max step \(maxStep(out))")
    }

    @Test func stopFadesOutAndDropsStaleGrains() {
        let s = makeScrub()
        s.begin(at: t(48_000), hostNanos: 0)
        s.scrub(to: t(48_400), hostNanos: ms(8))
        var out = render(s.voice, 1000)                  // mid-grain
        s.scrub(to: t(48_800), hostNanos: ms(16))        // pending
        s.stop()
        out += render(s.voice, 2000)
        #expect(maxStep(out) < threshold)
        #expect(out.suffix(2000 - fadeN).allSatisfy { $0 == 0 }, "silent after the 5 ms fade")
        #expect(s.voice.grainsStarted == 1 && s.voice.freeSlots == ScrubVoice.slotCount)
        // A grain produced for a request made before the stop is dropped by the voice.
        let slot = s.voice.claim()!
        s.voice.publish(slot: slot, frames: 600, hop: 300, generation: s.voice.generation - 1, tag: 99)
        #expect(render(s.voice, 512).allSatisfy { $0 == 0 })
        #expect(s.voice.freeSlots == ScrubVoice.slotCount)
    }

    @Test func stepPlaysOneGrainThenSilence() {
        let s = makeScrub()
        s.step(from: Time(1, 1), to: Time(1, 1) + fd30)
        let out = render(s.voice, 4800)
        #expect(peak(out) > 0.4 && maxStep(out) < threshold)
        #expect(out[(1920 + fadeN)...].allSatisfy { $0 == 0 })
        #expect(s.voice.grainsStarted == 1)
    }

    /// Worker-queue mode (the app's): same results once the queue is idle.
    @Test func asyncWorkerProducesGrains() {
        let media = UUID(), src = sineSource()
        let s = ScrubAudio(resolver: { _ in src })
        s.setTimeline(timeline(media: media), sequences: [:])
        s.begin(at: t(48_000), hostNanos: 0)
        for k in 0..<50 { s.scrub(to: t(48_000 + Int64(k + 1) * 400), hostNanos: ms(Int64(k + 1) * 8)) }
        s.waitUntilIdle()
        #expect(s.droppedRequests == 0 && s.voice.freeSlots == ScrubVoice.slotCount - 1)
        let out = render(s.voice, 4800)
        #expect(peak(out) > 0.4 && s.voice.lastStartedTag == s.lastTag)
    }
}
