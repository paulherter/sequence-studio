import Foundation
import Testing
@testable import SQCore

/// Round 4 transition set: Blur Dissolve, Through Color, Flash, Spin, Cross Zoom, Static, Light Noise, Strobe Cut.
@Suite struct MoreTransitionsTests {
    static let newKinds: [TransitionKind] = [.blurDissolve, .dipToColour, .flash, .spin, .crossZoom, .staticNoise, .lightNoise, .strobeCut]
    private let fd = Time(1, 30)

    private func eval(_ k: TransitionKind, _ i: Int, _ n: Int = 11, blur: Double = 1, dir: TransitionDirection = .left) -> TransitionRender {
        TransitionRender.evaluate(kind: k, direction: dir, softness: 0.1, motionBlur: blur, easing: .linear, frameIndex: i, frames: n)
    }

    @Test func newKindsAreVideoLayerKindsWithDistinctNames() {
        var names = Set(TransitionKind.allCases.filter { !Self.newKinds.contains($0) }.map(\.name))
        for k in Self.newKinds {
            #expect(k.trackKind == .video && k.isLayerKind && !k.isElement && !k.isStinger)
            #expect(TransitionKind.layerKinds.contains(k) && TransitionKind(rawValue: k.rawValue) == k)
            #expect(names.insert(k.name).inserted, "duplicate name \(k.name)")
        }
        // Not repeated: the existing Whip, Zoom In/Out and Through White cover those ideas.
        #expect(TransitionKind.allCases.filter { $0.name.contains("Whip") }.count == 1)
    }

    @Test func dipsShareOnePath() {
        #expect(TransitionKind.dipToBlack.isDip && TransitionKind.dipToWhite.isDip && TransitionKind.dipToColour.isDip && TransitionKind.flash.isDip)
        #expect(!TransitionKind.crossDissolve.isDip && !TransitionKind.blurDissolve.isDip)
        #expect(TransitionKind.dipToColour.usesColor && !TransitionKind.dipToBlack.usesColor)
        #expect(TransitionMix.dipColor(.dipToColour, custom: [1, 2, 3]) == [1, 2, 3])
        #expect(TransitionMix.dipColor(.dipToColour, custom: [1, 2]) == TransitionMix.defaultDipColour)
        #expect(TransitionMix.dipColor(.dipToColour) == TransitionMix.defaultDipColour)
        #expect(TransitionMix.dipColor(.flash, custom: [1, 2, 3]) == [255, 255, 255])
        let m = TransitionMix.video(.dipToColour, weight: 0.5)
        #expect(m.outgoing == 0 && m.incoming == 0 && m.dip == 1)
    }

    @Test func flashIsASharperPeakThanADipAndCutsAtTheMiddle() {
        let dip = TransitionMix.video(.dipToWhite, weight: 0.25), fl = TransitionMix.video(.flash, weight: 0.25)
        #expect(fl.dip < dip.dip && fl.outgoing > dip.outgoing && fl.incoming == 0)
        let peak = TransitionMix.video(.flash, weight: 0.5)
        #expect(peak.dip == 1 && peak.outgoing == 0 && peak.incoming == 0)
        let late = TransitionMix.video(.flash, weight: 0.75)
        #expect(late.outgoing == 0 && late.incoming > 0 && abs(late.outgoing + late.incoming + late.dip - 1) < 1e-12)
        #expect(TransitionKind.flash.presetDuration(frameDuration: fd) == fd * 15)
    }

    @Test func throughColourKeepsItsColourOnTheEdge() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: fd * 30, duration: fd * 30), start: .zero, mediaDuration: fd * 200)
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: fd * 30, duration: fd * 30), start: fd * 30, mediaDuration: fd * 200)
        try t.tracks[0].overwrite(a); try t.tracks[0].overwrite(b)
        let id = try t.addTransition(kind: .dipToColour, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: fd * 10)
        #expect(t.tracks[0].transitions[0].color == nil)
        try t.setTransition(id, color: [10, 20, 30])
        #expect(t.tracks[0].transitions[0].color == [10, 20, 30])
        let r = try #require(t.tracks[0].resolvedTransitions(frameDuration: fd).first)
        #expect(r.color == [10, 20, 30])
        // The solid behind the faded pictures carries the color while the transition runs.
        let solids = t.videoLayers(at: r.span.start + fd * 5).compactMap(\.generator)
        #expect(solids.contains(GeneratorRef.solid(rgb: [10, 20, 30])))
        try t.setTransition(id, color: [1])   // malformed: ignored
        #expect(t.tracks[0].transitions[0].color == [10, 20, 30])
    }

    @Test func throughColourAsALayerUsesItsPayloadColour() throws {
        let tracks = [Track(kind: .video), Track(kind: .video)]
        let tl = Timeline(name: "T", frameDuration: fd, tracks: tracks)
        var p = Project(name: "P", timelines: [tl])
        let id = try p.addTransitionLayer(kind: .dipToColour, in: tl.id, at: .zero, track: tracks[1].id, duration: fd * 12)
        try p.edit(tl.id) { try $0.setTransitionLayer(id) { $0.color = [9, 8, 7] } }
        let t = try #require(p.timeline(tl.id))
        let r = try #require(t.resolvedTransitionLayer(id))
        #expect(r.kind == .dipToColour && r.color == [9, 8, 7] && r.frames == 12)
        let solids = t.videoLayers(at: fd * 6).compactMap(\.generator)
        #expect(solids.contains(GeneratorRef.solid(rgb: [9, 8, 7])))
    }

    @Test func blurDissolveBlurPeaksInTheMiddleAndMixesMonotonically() {
        let n = 11
        let radii = (0..<n).map { eval(.blurDissolve, $0, n).wipe.softness }
        #expect(radii.max() == radii[n / 2] && radii.min()! > 0 && radii[0] < radii[n / 2] && radii[n - 1] < radii[n / 2])
        #expect(radii[n / 2] <= TransitionRender.BlurDissolve.maxRadius)
        for i in 0..<n { #expect(eval(.blurDissolve, i, n).compose == .blurDissolve) }
        let w = (0..<n).map { eval(.blurDissolve, $0, n).wipe.front }
        #expect(zip(w, w.dropFirst()).allSatisfy { $0 < $1 } && w[0] > 0 && w[n - 1] < 1)
        #expect(!TransitionKind.blurDissolve.usesMotionBlur && !TransitionKind.blurDissolve.usesDirection && TransitionKind.blurDissolve.usesEasing)
    }

    @Test func spinRotatesBothPicturesAndAlwaysCoversTheFrame() {
        for dir in [TransitionDirection.left, .right] {
            for i in 0..<11 {
                let r = eval(.spin, i, 11, dir: dir)
                #expect(abs(r.outgoing.opacity + r.incoming.opacity - 1) < 1e-12 && r.compose == .sum)
                for s in [r.outgoing, r.incoming] {
                    #expect(abs(s.rotation) <= TransitionRender.spinAngle + 1e-12)
                    #expect(s.scale >= TransitionRender.coverScale(rotation: s.rotation) - 1e-12 && s.scale >= 1)
                }
            }
        }
        let l = eval(.spin, 5, 11, dir: .left), r = eval(.spin, 5, 11, dir: .right)
        #expect(l.outgoing.rotation == -r.outgoing.rotation && l.outgoing.rotation != 0)
        #expect(abs(eval(.spin, 0, 100).outgoing.rotation) < 0.05 && abs(eval(.spin, 99, 100).incoming.rotation) < 0.05)
        #expect(TransitionRender.coverScale(rotation: 0) == 1)
        #expect(TransitionKind.spin.usesDirection && TransitionKind.spin.usesMotionBlur)
    }

    @Test func crossZoomSmearsInTheMiddleAndFollowsTheShutter() {
        let n = 11
        let mid = eval(.crossZoom, n / 2, n), edge = eval(.crossZoom, 0, n)
        #expect(mid.outgoing.zoomBlur > edge.outgoing.zoomBlur && mid.incoming.zoomBlur == mid.outgoing.zoomBlur)
        #expect(eval(.crossZoom, n / 2, n, blur: 0).outgoing.zoomBlur == 0)
        for i in 0..<n {
            let r = eval(.crossZoom, i, n)
            #expect(abs(r.outgoing.opacity + r.incoming.opacity - 1) < 1e-12 && r.outgoing.scale >= 1 && r.incoming.scale >= 1)
        }
        #expect(eval(.crossZoom, 0, 100).incoming.scale > eval(.crossZoom, 99, 100).incoming.scale)
    }

    @Test func strobeAlternatesHardAndEndsOnTheIncomingPicture() {
        let n = 24
        let seq = (0..<n).map { eval(.strobeCut, $0, n).incoming.opacity }
        #expect(seq.allSatisfy { $0 == 0 || $0 == 1 })
        #expect(seq.first == 0 && seq.last == 1)
        var flips = 0
        for (a, b) in zip(seq, seq.dropFirst()) where a != b { flips += 1 }
        #expect(flips == TransitionRender.strobeParts - 1)
        for i in 0..<n { let r = eval(.strobeCut, i, n); #expect(r.outgoing.opacity + r.incoming.opacity == 1) }
    }

    @Test func staticCutsAtTheMiddleWithNoiseThatPeaksThere() {
        let n = 20
        let rs = (0..<n).map { eval(.staticNoise, $0, n).glitch }
        #expect(rs.allSatisfy { $0.intensity > 0 && $0.intensity <= 1 })
        #expect(rs[n / 2].intensity > rs[0].intensity && rs[n / 2].intensity > rs[n - 1].intensity)
        #expect(Set(rs.map(\.seed)).count == n, "every frame has its own noise")
        #expect(rs[0].mix < 0.5 && rs[n - 1].mix > 0.5)
        #expect(eval(.staticNoise, 3, n).glitch == eval(.staticNoise, 3, n).glitch, "deterministic for export")
        #expect(eval(.staticNoise, 3, n).compose == .staticNoise)
    }

    /// Single-sided (a clip head or tail): the missing side is transparent, so A leaves / B arrives through the same maths.
    @Test func singleSidedUsesTheSameMixSoAFadesOutAndBFadesIn() {
        let n = 20
        func tail(_ k: TransitionKind, _ i: Int) -> TransitionRender {
            TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: k.defaultMotionBlur, easing: .linear,
                                      frameIndex: i, frames: n, hasIncoming: false)
        }
        for k in [TransitionKind.spin, .crossZoom, .strobeCut] {
            #expect(tail(k, n - 1).outgoing.opacity < 0.4 && tail(k, 0).outgoing.opacity > 0.6 || k == .strobeCut, "\(k)")
        }
        #expect(tail(.blurDissolve, n - 1).wipe.front > 0.9 && tail(.lightNoise, n - 1).wipe.front > 0.9)
        #expect(tail(.staticNoise, n - 1).glitch.mix > 0.9)
    }

    @Test func lightNoiseProgressesMonotonically() {
        let f = (0..<11).map { eval(.lightNoise, $0).wipe.front }
        #expect(zip(f, f.dropFirst()).allSatisfy { $0 < $1 } && eval(.lightNoise, 4).compose == .lightNoise)
    }

    @Test func everyNewKindCanBeATransitionLayer() throws {
        let tracks = [Track(kind: .video), Track(kind: .video)]
        let tl = Timeline(name: "T", frameDuration: fd, tracks: tracks)
        var p = Project(name: "P", timelines: [tl])
        for (n, k) in Self.newKinds.enumerated() {
            let id = try p.addTransitionLayer(kind: k, in: tl.id, at: fd * Int64(n * 12), track: tracks[1].id, duration: fd * 12)
            let r = try #require(p.timeline(tl.id)?.resolvedTransitionLayer(id))
            #expect(r.kind == k && r.frames == 12)
            // Every frame of the layer evaluates (motion kinds through the shared engine, dips through the solid).
            for i in 0..<12 { _ = Clip.stackRender(r, frameIndex: i) }
        }
    }

    @Test func transitionsWithTheNewKindsRoundTrip() throws {
        for k in Self.newKinds {
            var tr = Transition(kind: k, duration: fd * 6, outgoing: UUID(), incoming: UUID())
            tr.color = [4, 5, 6]
            let back = try JSONDecoder().decode(Transition.self, from: JSONEncoder().encode(tr))
            #expect(back == tr)
        }
        let plain = Transition(kind: .flash, duration: fd, outgoing: nil, incoming: UUID())
        #expect(try JSONDecoder().decode(Transition.self, from: JSONEncoder().encode(plain)).color == nil)
    }

    /// Measurement (printed): CPU cost of evaluating one frame of each new kind (the GPU cost is in SQRender's tests).
    @Test func evaluationIsCheap() {
        let clock = ContinuousClock()
        var sink = 0.0
        let d = clock.measure {
            for k in Self.newKinds { for i in 0..<10_000 { sink += eval(k, i % 30, 30).outgoing.opacity } }
        }
        NSLog("new transitions: %.2f us/frame evaluate (8 kinds)", Double(d.components.attoseconds) / 1e12 / 80_000)
        #expect(sink > 0)
    }
}
