import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

private func clip(_ name: String, start: Int64, from: Int64 = 30, frames: Int64 = 60) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         mediaDuration: f(300))
}

private func dissolve(_ a: Clip, _ b: Clip, frames: Int64 = 20) throws -> Timeline {
    var t = Track(kind: .video)
    try t.overwrite(a); try t.overwrite(b)
    var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
    try tl.addTransition(kind: .crossDissolve, track: tl.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(frames))
    return tl
}

@Suite struct EffectsInTransitionTests {
    @Test func bothClipsOfAPairKeepTheirOwnEffectsAndBlendModes() throws {
        var a = clip("A", start: 0), b = clip("B", start: 60)
        let crop = a.addEffect(kind: ClipEffect.cropKind)!
        a.setParameter(crop, ClipEffect.cropLeftKey, to: 10)
        let blur = b.addEffect(kind: ClipEffect.gaussianBlurKind)!
        b.setParameter(blur, ClipEffect.blurrinessKey, to: 5)
        a.blendMode = .screen
        b.blendMode = .multiply
        let tl = try dissolve(a, b)
        let l = tl.videoLayers(at: f(60))
        #expect(l.count == 2 && l[0].pair?.role == .first && l[1].pair?.role == .second)
        #expect(abs(l[0].effects.pre.crop.left - 0.1) < 1e-12 && l[0].effects.blur == 0)
        #expect(l[1].effects.blur == 5 && l[1].effects.pre.crop.isIdentity)
        #expect(l[0].blendMode == .screen && l[1].blendMode == .multiply)
    }

    @Test func fxToggleOffAppliesInsideAPair() throws {
        var a = clip("A", start: 0), b = clip("B", start: 60)
        a.animation.position = AnimatedProperty(Vec2(40, 0))
        a.motionEnabled = false
        b.opacityEnabled = false
        b.blendMode = .screen
        let l = try dissolve(a, b).videoLayers(at: f(60))
        #expect(l[0].transform.position == .zero)
        #expect(l[1].blendMode == .normal)
    }

    @Test func aTotalCropDropsOnlyThatClipFromThePair() throws {
        var a = clip("A", start: 0)
        let crop = a.addEffect(kind: ClipEffect.cropKind)!
        a.setParameter(crop, ClipEffect.cropLeftKey, to: 100)
        let l = try dissolve(a, clip("B", start: 60)).videoLayers(at: f(60))
        #expect(l.count == 1 && l[0].pair?.role == .second)
    }

    @Test func aPairOfNestedClipsCarriesGroupEffects() throws {
        let innerClip = Clip(name: "i", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(600)), start: .zero)
        var it = Track(kind: .video)
        try it.overwrite(innerClip)
        let inner = Timeline(name: "inner", frameDuration: fd, tracks: [it])
        func nested(_ name: String, start: Int64) -> Clip {
            Clip(name: name, media: inner.id, kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
                 mediaDuration: f(600), sequence: inner.id)
        }
        var a = nested("A", start: 0), b = nested("B", start: 60)
        let crop = a.addEffect(kind: ClipEffect.cropKind)!
        a.setParameter(crop, ClipEffect.cropRightKey, to: 25)
        b.blendMode = .overlay
        let tl = try dissolve(a, b)
        let l = tl.videoLayers(at: f(60), sequences: { $0 == inner.id ? inner : nil })
        #expect(l.count == 2)
        #expect(l.allSatisfy { $0.pair != nil && $0.groups.count == 1 })
        #expect(abs(l[0].groups[0].effects.pre.crop.right - 0.25) < 1e-12 && l[1].groups[0].blendMode == .overlay)
    }

    @Test func aHeldClipHasUnlimitedHandlesLikeAStill() throws {
        let a = clip("A", start: 0)
        var b = clip("B", start: 60, from: 0)               // no head handle at all
        b.holdFrame = f(0)
        var t = Track(kind: .video)
        try t.overwrite(a); try t.overwrite(b)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        // 20 frames centred on the cut need 10 frames of B's head: a clip with no media before its first frame cannot give them,
        // a held clip can (its picture is one frame).
        _ = try tl.addTransition(kind: .crossDissolve, track: tl.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(tl.resolvedTransitions(on: tl.tracks[0].id).first)
        #expect(!r.isClamped && r.before == f(10))
        // And without the hold the same transition is clamped.
        var plain = clip("B", start: 60, from: 0)
        plain.holdFrame = nil
        var t2 = Track(kind: .video)
        try t2.overwrite(a); try t2.overwrite(plain)
        var tl2 = Timeline(name: "t", frameDuration: fd, tracks: [t2])
        _ = try tl2.addTransition(kind: .crossDissolve, track: tl2.tracks[0].id, outgoing: a.id, incoming: plain.id, duration: f(20))
        #expect((tl2.resolvedTransitions(on: tl2.tracks[0].id).first?.before ?? f(99)) < f(10))
    }
}
