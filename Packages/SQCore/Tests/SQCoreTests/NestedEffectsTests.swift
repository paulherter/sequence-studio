import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@Suite struct NestedEffectsTests {
    /// Outer sequence with one nested clip (inner source 4...9 s, placed at 2 s) over an inner sequence with one media clip.
    private func rig(_ configure: (inout Clip) -> Void) throws -> (Timeline, Timeline, Clip) {
        let inner = Clip(name: "i", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero)
        var it = Track(kind: .video)
        try it.overwrite(inner)
        let innerTL = Timeline(name: "inner", frameDuration: fd, tracks: [it])
        var nested = Clip(name: "n", media: innerTL.id, kind: .video, source: TimeRange(start: s(4), duration: s(5)), start: s(2),
                          mediaDuration: s(20), sequence: innerTL.id)
        configure(&nested)
        var ot = Track(kind: .video)
        try ot.overwrite(nested)
        return (Timeline(name: "outer", frameDuration: fd, tracks: [ot]), innerTL, nested)
    }

    @Test func groupCarriesTheNestedClipsEffectsAndBlendMode() throws {
        let (outer, inner, _) = try rig { c in
            let crop = c.addEffect(kind: ClipEffect.cropKind)!
            c.setParameter(crop, ClipEffect.cropLeftKey, to: 20)
            let blur = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
            c.setParameter(blur, ClipEffect.blurrinessKey, to: 4)
            c.blendMode = .multiply
        }
        let layers = outer.videoLayers(at: s(3), sequences: { $0 == inner.id ? inner : nil })
        #expect(layers.count == 1)
        let g = try #require(layers[0].groups.first)
        #expect(g.blendMode == .multiply)
        #expect(abs(g.effects.pre.crop.left - 0.2) < 1e-12 && g.effects.blur == 4)
        // The inner layer itself is untouched.
        #expect(layers[0].effects == ClipEffects.none && layers[0].blendMode == .normal)
    }

    @Test func opacityToggleOffMakesTheGroupNormalBlend() throws {
        let (outer, inner, _) = try rig { c in c.blendMode = .screen; c.opacityEnabled = false }
        let g = try #require(outer.videoLayers(at: s(3), sequences: { $0 == inner.id ? inner : nil })[0].groups.first)
        #expect(g.blendMode == .normal)
    }

    @Test func aTotalCropOnANestedClipDrawsNothing() throws {
        let (outer, inner, _) = try rig { c in
            let crop = c.addEffect(kind: ClipEffect.cropKind)!
            c.setParameter(crop, ClipEffect.cropTopKey, to: 100)
        }
        #expect(outer.videoLayers(at: s(3), sequences: { $0 == inner.id ? inner : nil }).isEmpty)
    }

    @Test func aHeldNestedClipShowsOneInstantOfTheInnerSequence() throws {
        let (outer, inner, nested) = try rig { _ in }
        var tl = outer
        // Hold at 3 s on the outer timeline = inner time 4 + 1 = 5 s.
        let id = try tl.addFrameHold(of: nested.id, at: s(3))
        let held = tl.tracks[0].clips.first { $0.id == id }!
        #expect(held.holdFrame == s(5))
        for t in [Int64(3), 5, 6] {
            let layers = tl.videoLayers(at: s(t), sequences: { $0 == inner.id ? inner : nil })
            #expect(layers.count == 1 && layers[0].sourceTime == s(5), "outer \(t) s")
        }
        // Before the hold the inner time still moves.
        #expect(tl.videoLayers(at: s(2), sequences: { $0 == inner.id ? inner : nil })[0].sourceTime == s(4))
    }
}
