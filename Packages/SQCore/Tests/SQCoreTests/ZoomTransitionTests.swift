import Foundation
import Testing
@testable import SQCore

// Zoom In / Zoom Out to the maintainer's real spec (the design notes 2026-10-04 "Zoom In / Zoom Out: the maintainer's real spec"): two layers,
// B under A; A fades out over a few frames at its very end (a short real crossfade). Zoom In: both layers scale 100 -> 110 %,
// A accelerates into its end, B starts at full speed and settles. Zoom Out: 110 -> 100 % on both.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private let amount = TransitionRender.zoomAmount

private func render(_ k: TransitionKind, _ i: Int, of n: Int, blur: Double? = nil,
                    hasOutgoing: Bool = true, hasIncoming: Bool = true) -> TransitionRender {
    TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: blur ?? k.defaultMotionBlur,
                              easing: k.defaultEasing, frameIndex: i, frames: n,
                              hasIncoming: hasIncoming, hasOutgoing: hasOutgoing)
}

/// Frames where A is partly transparent over B (the crossfade).
private func fadeFrames(_ k: TransitionKind, _ n: Int) -> [Int] {
    (0..<n).filter { let o = render(k, $0, of: n).outgoing.opacity; return o > 0 && o < 1 }
}

@Suite struct ZoomTransitionTests {
    @Test func defaults() {
        #expect(TransitionRender.zoomAmount == 1.1)
        #expect(TransitionRender.zoomFadeFrames == 3)
        for k in [TransitionKind.zoomIn, .zoomOut] {
            #expect(k.presetDuration(frameDuration: fd) == f(21), "0.7 s")
            #expect(k.defaultMotionBlur == 1, "a 360 degree shutter")
            #expect(k.isMotion && k.usesMotionBlur && !k.usesDirection && !k.usesSoftness)
            #expect(!k.usesEasing, "the speed curve is part of the look")
        }
        #expect(TransitionKind.zoomPop.defaultMotionBlur == 0.5 && TransitionKind.push.defaultMotionBlur == 0.5)
        #expect(TransitionKind.push.usesEasing && TransitionKind.zoomPop.usesEasing)
    }

    @Test func twoLayersWithBUnderAAndAShortFadeOfA() {
        for k in [TransitionKind.zoomIn, .zoomOut] {
            let n = 12
            var lastA = 1.0
            for i in 0..<n {
                let r = render(k, i, of: n)
                #expect(r.compose == .outgoingOver, "A is drawn over B")
                let a = r.outgoing.opacity, b = r.incoming.opacity
                #expect(a <= lastA, "\(k) frame \(i): A only fades out")
                lastA = a
                // B is fully opaque whenever it is there at all (it sits under A, no B fade-in).
                #expect(b == 0 || b == 1, "\(k) frame \(i): B \(b)")
                // Never a blank frame: A fully there or B underneath.
                #expect(a == 1 || b == 1, "\(k) frame \(i)")
            }
            #expect(render(k, 0, of: n).outgoing.opacity == 1 && render(k, 0, of: n).incoming.opacity == 0)
            #expect(render(k, n - 1, of: n).outgoing.opacity == 0 && render(k, n - 1, of: n).incoming.opacity == 1)
            // The crossfade sits at the middle and only lasts a couple of frames.
            let fades = fadeFrames(k, n)
            #expect(fades == [5, 6], "\(k): \(fades)")
            for i in fades { #expect(render(k, i, of: n).incoming.opacity == 1, "B under A during the fade") }
        }
    }

    @Test func fadeLengthIsIndependentOfTheSpan() {
        #expect(fadeFrames(.zoomIn, 12).count == 2)
        #expect(fadeFrames(.zoomIn, 36).count == 2)
        #expect(fadeFrames(.zoomIn, 60).count == 2)
        let long = fadeFrames(.zoomIn, 36)
        #expect(long.allSatisfy { abs(Double($0) - 17.5) < 2 }, "centered on the cut: \(long)")
        // A very short span still fades (never a hard pop), within the span.
        #expect(!fadeFrames(.zoomIn, 3).isEmpty)
    }

    @Test func zoomInSpeedPeaksAtTheTransitionPoint() {
        let n = 24
        let a = (0..<n).map { render(.zoomIn, $0, of: n).outgoing }
        let b = (0..<n).map { render(.zoomIn, $0, of: n).incoming }
        let fades = fadeFrames(.zoomIn, n)
        let firstB = try! #require((0..<n).first { b[$0].opacity > 0 })
        let lastA = try! #require((0..<n).last { a[$0].opacity > 0 })
        // A: 100 % -> towards 110 %, accelerating all the way to its end.
        #expect(abs(a[0].scale - 1) < 0.001, "A starts at rest")
        #expect(a[lastA].scale > 1.07 && a[lastA].scale <= amount + 1e-12)
        for i in 1...lastA {
            #expect(a[i].scale > a[i - 1].scale, "A pushes in, frame \(i)")
            if i >= 2 { #expect(a[i].scale - a[i - 1].scale > a[i - 1].scale - a[i - 2].scale, "A accelerates, frame \(i)") }
        }
        // B: the same direction 100 % -> 110 %, fastest at its start, settling towards the end.
        #expect(b[firstB].scale < 1.03, "B starts near 100 %")
        #expect(abs(b[n - 1].scale - amount) < 0.001, "B ends at 110 %")
        for i in (firstB + 1)..<n {
            #expect(b[i].scale > b[i - 1].scale, "B pushes in, frame \(i)")
            if i >= firstB + 2 { #expect(b[i].scale - b[i - 1].scale < b[i - 1].scale - b[i - 2].scale, "B settles, frame \(i)") }
        }
        // Speed of what is on screen: A's step before the fade, B's after; the peak sits at the fade.
        func step(_ i: Int) -> Double {
            i <= lastA && a[i].opacity == 1 ? a[i].scale - a[i - 1].scale : b[i].scale - (i > firstB ? b[i - 1].scale : 1)
        }
        let speeds = (1..<n).map { step($0) }
        let peak = speeds.indices.max { speeds[$0] < speeds[$1] }! + 1
        #expect(abs(peak - fades[0]) <= 2, "peak at frame \(peak), fade \(fades)")
        #expect(speeds.first! < speeds.max()! / 4 && speeds.last! < speeds.max()! / 4, "slow at both ends")
        // Never below 100 %: no empty edges.
        #expect((a + b).allSatisfy { $0.scale >= 1 && $0.offset == .zero })
    }

    @Test func zoomOutIsOneHundredTenToOneHundredOnBothLayers() {
        let n = 24
        let a = (0..<n).map { render(.zoomOut, $0, of: n).outgoing }
        let b = (0..<n).map { render(.zoomOut, $0, of: n).incoming }
        let lastA = (0..<n).last { a[$0].opacity > 0 }!, firstB = (0..<n).first { b[$0].opacity > 0 }!
        #expect(abs(a[0].scale - amount) < 0.001, "A starts at 110 %")
        #expect(a[lastA].scale < 1.03)
        #expect(b[firstB].scale > 1.07)
        #expect(abs(b[n - 1].scale - 1) < 0.001, "B ends at 100 %")
        for i in 1...lastA { #expect(a[i].scale < a[i - 1].scale) }
        for i in (firstB + 1)..<n { #expect(b[i].scale < b[i - 1].scale) }
        #expect((a + b).allSatisfy { $0.scale >= 1 - 1e-12 })
        // Same motion as Zoom In, mirrored in scale: 2.1 - s.
        for i in 0..<n {
            let zi = render(.zoomIn, i, of: n)
            #expect(abs(zi.outgoing.scale + a[i].scale - (1 + amount)) < 1e-9)
            #expect(abs(zi.incoming.scale + b[i].scale - (1 + amount)) < 1e-9)
            #expect(zi.outgoing.opacity == a[i].opacity && zi.incoming.opacity == b[i].opacity)
        }
    }

    @Test func amountIsAdjustable() {
        let r = TransitionRender.evaluate(kind: .zoomIn, direction: .left, softness: 0, motionBlur: 0, easing: .linear,
                                          frameIndex: 11, frames: 12, zoomAmount: 1.2)
        #expect(abs(r.incoming.scale - 1.2) < 0.001)
    }

    @Test func blurFollowsTheSpeedAndPeaksAtTheFade() {
        let n = 24
        let fades = fadeFrames(.zoomIn, n)
        let shownBlur = (0..<n).map { i -> Double in
            let r = render(.zoomIn, i, of: n)
            return r.outgoing.opacity == 1 ? r.outgoing.zoomBlur : r.incoming.zoomBlur
        }
        #expect(shownBlur.allSatisfy { $0 >= 0 })
        let peak = shownBlur.indices.max { shownBlur[$0] < shownBlur[$1] }!
        #expect(abs(peak - fades[0]) <= 2, "blur peak at \(peak), fade \(fades)")
        #expect(shownBlur[0] < shownBlur[peak] / 4 && shownBlur[n - 1] < shownBlur[peak] / 4)
        #expect(render(.zoomIn, fades[0], of: n, blur: 0).outgoing.zoomBlur == 0)
        #expect(render(.zoomIn, fades[0], of: n, blur: 2).outgoing.zoomBlur > render(.zoomIn, fades[0], of: n).outgoing.zoomBlur)
    }

    @Test func headOnlyPlaysBsMoveAndFadesIn() {
        let n = 12
        var last = 0.0
        for i in 0..<n {
            let r = render(.zoomIn, i, of: n, hasOutgoing: false)
            #expect(r.outgoing.opacity == 0)
            #expect(r.incoming.scale >= 1 && r.incoming.scale > last, "B keeps pushing in")
            last = r.incoming.scale
        }
        let first = render(.zoomIn, 0, of: n, hasOutgoing: false).incoming
        #expect(first.opacity > 0 && first.opacity < 1)
        #expect(render(.zoomIn, 3, of: n, hasOutgoing: false).incoming.opacity == 1, "in after a few frames")
        #expect(abs(render(.zoomIn, n - 1, of: n, hasOutgoing: false).incoming.scale - amount) < 0.001)
        #expect(render(.zoomOut, n - 1, of: n, hasOutgoing: false).incoming.scale < 1.001)
    }

    @Test func tailOnlyPlaysAsMoveAndFadesOut() {
        let n = 12
        var last = 0.0
        for i in 0..<n {
            let r = render(.zoomIn, i, of: n, hasIncoming: false)
            #expect(r.incoming.opacity == 0)
            #expect(r.outgoing.scale >= 1 && r.outgoing.scale > last, "A keeps pushing in")
            last = r.outgoing.scale
        }
        #expect(render(.zoomIn, 0, of: n, hasIncoming: false).outgoing.opacity == 1)
        #expect(render(.zoomIn, n - 4, of: n, hasIncoming: false).outgoing.opacity == 1)
        let end = render(.zoomIn, n - 1, of: n, hasIncoming: false).outgoing
        #expect(end.opacity < 0.4 && end.scale > 1.07)
        #expect(render(.zoomOut, n - 1, of: n, hasIncoming: false).outgoing.scale < 1.03)
    }

    @Test func headOnlyOnTheTimelineShowsTheIncomingClip() throws {
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(60),
                     mediaDuration: f(300))
        var track = Track(kind: .video)
        try track.overwrite(b)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        try t.addTransition(kind: .zoomIn, track: t.tracks[0].id, outgoing: nil, incoming: b.id, duration: f(12))
        let l = t.videoLayers(at: f(62))
        let r = try #require(l.first?.pair?.render)
        #expect(l.count == 1 && l[0].pair?.role == .second)
        #expect(r.incoming.opacity > 0 && r.incoming.scale >= 1)
    }

    @Test func disabledOutgoingClipShowsTheIncomingOneThroughout() throws {
        func c(_ n: String, _ start: Int64) -> Clip {
            Clip(name: n, media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
                 mediaDuration: f(300))
        }
        var a = c("A", 0)
        let b = c("B", 60)
        a.isEnabled = false
        var track = Track(kind: .video)
        try track.overwrite(a); try track.overwrite(b)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        try t.addTransition(kind: .zoomIn, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(12))
        // First frame of the span: B must already be on screen, not a blank half.
        let l = t.videoLayers(at: f(54))
        let r = try #require(l.first?.pair?.render)
        #expect(l.count == 1 && l[0].clip == b.id)
        #expect(r.incoming.opacity > 0 && r.incoming.scale >= 1)
    }

    @Test func bothClipsAreLayeredDuringTheFade() throws {
        func c(_ n: String, _ start: Int64) -> Clip {
            Clip(name: n, media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
                 mediaDuration: f(300))
        }
        let a = c("A", 0), b = c("B", 60)
        var track = Track(kind: .video)
        try track.overwrite(a); try track.overwrite(b)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        try t.addTransition(kind: .zoomIn, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(12))
        // Span 54..66, frame 5 of 12 = 59: A partly over B.
        let l = t.videoLayers(at: f(59))
        let r = try #require(l.first?.pair?.render)
        #expect(Set(l.map(\.clip)) == [a.id, b.id])
        #expect(r.outgoing.opacity > 0 && r.outgoing.opacity < 1 && r.incoming.opacity == 1)
    }
}
