import Foundation
import Testing
@testable import SQCore

// F7.11 Anonymize: the cover stays in front of every effect that moves pixels, and a list with the wrong order, a mask
// switched off or an empty pick is rendered with the cover on the whole frame. Larger, never missing.

@Suite struct AnonymizeOrderTests {
    private let at = Time(1, 1)

    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    private func pick(_ x: Double) -> MagicSelection {
        MagicSelection(points: [MagicPoint(position: Vec2(x, 0.5), subtract: false, sourceTime: Time(1, 2))], part: .face)
    }

    @discardableResult
    private func cover(_ c: inout Clip, _ xs: [Double] = [0.3]) -> [ClipMask.ID] {
        c.addAnonymize(xs.map(pick), target: .face, cover: .mosaic, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
    }

    private func kinds(_ c: Clip) -> [String] { c.effects.map(\.kind) }

    private func id(_ c: Clip, _ kind: String) throws -> ClipEffect.ID { try #require(c.effects.first { $0.kind == kind }?.id) }

    /// The masks the Mosaic is limited to at 1 s (empty = it runs on the whole frame); nil = the Mosaic does not render.
    private func coverScope(_ c: Clip) throws -> [MaskShape]? {
        let e = try #require(c.effects.first { $0.kind == ClipEffect.mosaicKind })
        let f = try #require(e.imageFilter(atLocal: at))
        return c.effects(at: at).segments.first { $0.filter == f }?.scope
    }

    // MARK: Pinned

    @Test func nothingIsDraggedAboveTheCoverAndTheCoverDoesNotMoveDown() throws {
        var c = clip()
        cover(&c)
        for k in [ClipEffect.horizontalFlipKind, ClipEffect.mirrorKind, ClipEffect.lensDistortionKind, ClipEffect.twirlKind,
                  ClipEffect.waveWarpKind] { #expect(c.addEffect(kind: k) != nil) }
        let before = kinds(c)
        #expect(before.first == ClipEffect.mosaicKind)
        for k in before.dropFirst() {
            #expect(!c.moveEffect(try id(c, k), to: 0) || kinds(c).first == ClipEffect.mosaicKind)
            #expect(kinds(c).first == ClipEffect.mosaicKind)
        }
        #expect(!c.moveEffect(try id(c, ClipEffect.mosaicKind), to: 3))
        #expect(kinds(c).first == ClipEffect.mosaicKind)
        // The others still reorder among themselves.
        #expect(c.moveEffect(try id(c, ClipEffect.horizontalFlipKind), to: 1))
        #expect(kinds(c).prefix(2) == [ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind])
    }

    @Test func moveEffectOnAnUnpinnedListReportsThatItReordered() throws {
        var c = clip()
        cover(&c)
        let flip = try #require(ClipEffect.make(kind: ClipEffect.horizontalFlipKind))
        c.effects.insert(flip, at: 0)                           // an older list: the cover sits behind the flip
        #expect(kinds(c).first == ClipEffect.horizontalFlipKind)
        let first = c.moveEffect(UUID(), to: 0)
        #expect(first)                                          // nothing to move, but the list was pinned
        #expect(kinds(c) == [ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind])
        let second = c.moveEffect(UUID(), to: 0)
        #expect(!second)                                        // pinned now: nothing changes
    }

    @Test func theCoverGoesBehindTheColorEffectsWhichStayFirst() throws {
        var c = clip()
        #expect(c.addEffect(kind: ClipEffect.colorKind) != nil)
        #expect(c.addEffect(kind: ClipEffect.horizontalFlipKind) != nil)
        cover(&c)
        #expect(kinds(c) == [ClipEffect.colorKind, ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind])
        #expect(!c.moveEffect(try id(c, ClipEffect.horizontalFlipKind), to: 0))
        #expect(kinds(c) == [ClipEffect.colorKind, ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind])
        // A second run's cover joins the first in front.
        c.addAnonymize([pick(0.7)], target: .face, cover: .blur, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
        #expect(kinds(c) == [ClipEffect.colorKind, ClipEffect.gaussianBlurKind, ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind])
        #expect(c.moveEffect(try id(c, ClipEffect.mosaicKind), to: 0))
        #expect(kinds(c) == [ClipEffect.colorKind, ClipEffect.mosaicKind, ClipEffect.gaussianBlurKind, ClipEffect.horizontalFlipKind])
    }

    @Test func pastedOntoAClipWithEffectsTheCoverIsFirst() throws {
        var source = clip()
        cover(&source)
        var target = clip()
        #expect(target.addEffect(kind: ClipEffect.horizontalFlipKind) != nil)
        #expect(target.addEffect(kind: ClipEffect.twirlKind) != nil)
        let out = target.pastingAttributes(from: source)
        #expect(kinds(out) == [ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind, ClipEffect.twirlKind])
        #expect(out.effects[0].maskInput == out.masks.map(\.id) && out.masks.count == 1)
        #expect(try coverScope(out)?.count == 1)
    }

    @Test func anEffectGivenTheMaskAsInputJoinsTheCovers() throws {
        var c = clip()
        let mask = try #require(cover(&c).first)
        #expect(c.addEffect(kind: ClipEffect.horizontalFlipKind) != nil)
        #expect(c.addEffect(kind: ClipEffect.invertKind) != nil)
        c.setMask(mask, input: true, ofEffect: try id(c, ClipEffect.invertKind))
        #expect(kinds(c) == [ClipEffect.mosaicKind, ClipEffect.invertKind, ClipEffect.horizontalFlipKind])
    }

    // MARK: The wrong order is rendered safely

    @Test func aPixelMovingEffectInFrontOfTheCoverMakesItCoverTheWholeFrame() throws {
        var c = clip()
        cover(&c)
        #expect(try coverScope(c)?.count == 1)
        for k in [ClipEffect.horizontalFlipKind, ClipEffect.glitchKind, ClipEffect.mirrorKind, ClipEffect.lensDistortionKind,
                  ClipEffect.twirlKind, ClipEffect.waveWarpKind, ClipEffect.spherizeKind, ClipEffect.tileKind,
                  ClipEffect.kaleidoscopeKind] {
            var wrong = c
            var e = try #require(ClipEffect.make(kind: k))
            // Kinds that are an identity at their defaults move nothing: give them an amount.
            if k == ClipEffect.lensDistortionKind || k == ClipEffect.twirlKind || k == ClipEffect.spherizeKind {
                for key in e.parameters.keys { e.parameters[key] = AnimatedProperty(40) }
            }
            wrong.effects.insert(e, at: 0)                      // a hand-edited or old list
            guard e.imageFilter(atLocal: at) != nil else { continue }
            let scope = try coverScope(wrong)
            #expect(scope != nil && scope?.isEmpty == true, "\(k)")
        }
        // An effect that leaves the picture in place keeps the cover on the person.
        for k in [ClipEffect.invertKind, ClipEffect.blackAndWhiteKind, ClipEffect.vignetteKind, ClipEffect.cropKind] {
            var fine = c
            fine.effects.insert(try #require(ClipEffect.make(kind: k)), at: 0)
            #expect(try coverScope(fine)?.count == 1, "\(k)")
        }
        // A Transform moves the clip after every pixel effect; with a mask input it warps the picture.
        var stage = c
        stage.effects.insert(try #require(ClipEffect.make(kind: ClipEffect.transformKind)), at: 0)
        #expect(try coverScope(stage)?.count == 1)
        // A disabled effect moves nothing.
        var off = c
        var flip = try #require(ClipEffect.make(kind: ClipEffect.horizontalFlipKind))
        flip.enabled = false
        off.effects.insert(flip, at: 0)
        #expect(try coverScope(off)?.count == 1)
    }

    // MARK: Mask off, gone or without a pick

    @Test func aCoverWhoseMaskIsOffOrDeletedRunsOnTheWholeFrame() throws {
        var c = clip()
        let ids = cover(&c, [0.3, 0.7])
        #expect(try coverScope(c)?.count == 2)
        var one = c
        one.updateMask(ids[0]) { $0.enabled = false }
        #expect(try coverScope(one)?.isEmpty == true)
        var both = one
        both.updateMask(ids[1]) { $0.enabled = false }
        #expect(try coverScope(both)?.isEmpty == true)
        // Deleting one person's mask is a decision about that person; the other stays covered. No mask left: everything.
        var gone = c
        gone.removeMask(ids[0])
        #expect(try coverScope(gone)?.count == 1)
        gone.removeMask(ids[1])
        #expect(try coverScope(gone)?.isEmpty == true)
    }

    @Test func aMaskThatLostItsPickStillMustCover() throws {
        var c = clip()
        let ids = cover(&c)
        c.updateMask(ids[0]) { $0.magic?.points = [] }
        let use = try #require(c.effects(at: at).magicMattes.first)
        #expect(use.mustCover)
        #expect(try coverScope(c)?.first?.matteMustCover == true)
    }

    @Test func theTimelineListsTheKeysOfItsCovers() throws {
        var c = clip()
        cover(&c)
        var plain = clip()
        plain.masks = [ClipMask.makeMagic(name: "m", points: pick(0.5).points)]
        plain.start = Time(10, 1)
        var track = Track(kind: .video)
        try track.overwrite(c)
        try track.overwrite(plain)
        let sel = try #require(c.masks.first?.magic)
        #expect(Timeline(name: "t", frameDuration: Time(1, 25), tracks: [track]).coverMatteKeys == Set(sel.matteKeys(media: c.media)))
    }
}
