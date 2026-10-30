import Foundation
import Testing
@testable import SQCore

// Unified masks: Magic masks (picked + tracked mattes), masks as inputs of effects, Opacity use, ProjectFile v54 gate.

@Suite struct MaskInputTests {
    private let fd30 = Time(1, 30)

    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    private func project(_ c: Clip) throws -> Project {
        var track = Track(kind: .video)
        try track.overwrite(c)
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                       tracks: [track])])
    }

    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    private func mosaic() -> ClipEffect {
        ClipEffect(kind: ClipEffect.mosaicKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.mosaicKind))
    }

    // MARK: Model and file

    @Test func magicMaskRoundTripsWithItsPoints() throws {
        let p = MagicPoint(position: Vec2(0.4, 0.5), subtract: false, sourceTime: Time(1, 2))
        var m = ClipMask.makeMagic(name: "Mask 1", points: [p])
        m.usedByOpacity = false
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ClipMask.self, from: data)
        #expect(back == m)
        #expect(back.source == .magic)
        #expect(back.magic?.points == [p])
        #expect(!back.usedByOpacity)
    }

    @Test func plainMaskEncodesWithoutNewKeys() throws {
        let m = ClipMask.make(.ellipse, name: "M")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        #expect(obj["magic"] == nil)
        #expect(obj["opacityOff"] == nil)
        #expect(obj["source"] == nil)
        var e = mosaic()
        let eo = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        #expect(eo["masks"] == nil)
        e.maskInput = [m.id]
        let back = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(e))
        #expect(back.maskInput == [m.id])
    }

    @Test func fileGateIsWrittenOnlyWithMaskInputsOrMagic() throws {
        var c = clip()
        c.masks = [ClipMask.make(.rectangle, name: "M")]
        #expect(try writtenVersion(project(c)) < ProjectFile.maskInputVersion)
        var e = mosaic()
        e.maskInput = [c.masks[0].id]
        c.effects = [e]
        #expect(try writtenVersion(project(c)) == ProjectFile.maskInputVersion)
        var d = clip()
        d.masks = [ClipMask.makeMagic(name: "M", points: [])]
        #expect(try writtenVersion(project(d)) == ProjectFile.maskInputVersion)
        var o = clip()
        var m = ClipMask.make(.rectangle, name: "M"); m.usedByOpacity = false
        o.masks = [m]
        #expect(try writtenVersion(project(o)) == ProjectFile.maskInputVersion)
        // Round trip through the file.
        let back = try ProjectFile.decode(ProjectFile.encode(project(c)), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].effects[0].maskInput == [c.masks[0].id])
    }

    // MARK: Evaluation

    @Test func maskOnAnEffectLeavesOpacityAndScopesTheEffect() throws {
        var c = clip()
        var m = ClipMask.make(.ellipse, name: "M")
        m.usedByOpacity = false
        c.masks = [m]
        var e = mosaic()
        e.maskInput = [m.id]
        c.effects = [e]
        let fx = c.effects(at: Time(1, 1))
        #expect(fx.masks.isEmpty)                               // Opacity does not cut the picture
        #expect(fx.segments.first?.filter != nil)
        #expect(fx.segments.first?.scope.count == 1)
        #expect(fx.segments.first?.scope.first?.polygon.isEmpty == false)
    }

    @Test func maskUsedByOpacityAndAnEffectDoesBoth() throws {
        var c = clip()
        let m = ClipMask.make(.ellipse, name: "M")
        c.masks = [m]
        var e = mosaic()
        e.maskInput = [m.id]
        c.effects = [e]
        let fx = c.effects(at: .zero)
        #expect(fx.masks.count == 1)
        #expect(fx.segments.first?.scope.count == 1)
    }

    @Test func missingOrDisabledInputMasksLeaveTheEffectWhole() throws {
        var c = clip()
        var m = ClipMask.make(.ellipse, name: "M")
        m.enabled = false
        c.masks = [m]
        var e = mosaic()
        e.maskInput = [m.id, UUID()]
        c.effects = [e]
        #expect(c.effects(at: .zero).segments.first?.scope.isEmpty == true)
    }

    @Test func blursWithDifferentScopesAreNotMerged() throws {
        var c = clip()
        let m = ClipMask.make(.ellipse, name: "M")
        c.masks = [m]
        var b1 = ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(20)])
        let b2 = ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(20)])
        b1.maskInput = [m.id]
        c.effects = [b1, b2]
        let segs = c.effects(at: .zero).segments
        #expect(segs.filter { $0.blurAfter > 0 }.count == 2)
        #expect(segs[0].scope.count == 1)
        #expect(segs[1].scope.isEmpty)
    }

    @Test func magicMaskShapeCarriesItsMatteKey() {
        var c = clip()
        let m = ClipMask.makeMagic(name: "M", points: [])
        c.masks = [m]
        let s = c.effects(at: .zero).masks
        #expect(s.count == 1)
        #expect(s[0].source == .magic)
        #expect(s[0].matteKey == m.id)
        #expect(c.effects(at: .zero).magicMatteKeys == [m.id])
        #expect(!c.effects(at: .zero).needsSubjectMatte)
    }

    @Test func coverageReadsTheMagicMatteByKey() {
        let id = UUID()
        let matte = SubjectMatte(width: 2, height: 1, values: [1, 0])
        let s = MaskShape(polygon: [], source: .magic, matteKey: id)
        let frame = Vec2(100, 50)
        #expect(MaskCoverage.coverage(at: Vec2(10, 25), masks: [s], frame: frame, pixel: 1, mattes: [id: matte]) == 1)
        #expect(MaskCoverage.coverage(at: Vec2(90, 25), masks: [s], frame: frame, pixel: 1, mattes: [id: matte]) == 0)
        // Not tracked there yet: nothing selected (like a subject mask without a matte).
        #expect(MaskCoverage.coverage(at: Vec2(10, 25), masks: [s], frame: frame, pixel: 1, mattes: [:]) == 0)
    }

    // MARK: Editing

    @Test func removingAMaskDropsItFromEffectInputs() {
        var c = clip()
        let m = ClipMask.make(.ellipse, name: "M")
        c.masks = [m]
        var e = mosaic()
        e.maskInput = [m.id]
        c.effects = [e]
        c.removeMask(m.id)
        #expect(c.masks.isEmpty)
        #expect(c.effects[0].maskInput.isEmpty)
    }

    @Test func assigningMasksToEffectsAndOpacity() {
        var c = clip()
        let m = ClipMask.make(.ellipse, name: "M")
        c.masks = [m]
        let e = mosaic()
        c.effects = [e]
        c.setMask(m.id, input: true, ofEffect: e.id)
        #expect(c.effects[0].maskInput == [m.id])
        c.setMask(m.id, input: true, ofEffect: e.id)
        #expect(c.effects[0].maskInput == [m.id])            // no duplicates
        c.setMask(m.id, usedByOpacity: false)
        #expect(c.mask(m.id)?.usedByOpacity == false)
        #expect(c.effectsUsing(mask: m.id) == [e.id])
        c.setMask(m.id, input: false, ofEffect: e.id)
        #expect(c.effects[0].maskInput.isEmpty)
    }

    @Test func pasteKeepsEffectInputsPointingAtThePastedMasks() {
        var src = clip()
        let m = ClipMask.make(.ellipse, name: "M")
        src.masks = [m]
        var e = mosaic()
        e.maskInput = [m.id]
        src.effects = [e]
        let out = clip().pastingAttributes(from: src)
        #expect(out.masks.count == 1)
        #expect(out.effects.count == 1)
        #expect(out.effects[0].maskInput == [out.masks[0].id])
    }

    @Test func pictureEffectsTakeAMaskInput() {
        #expect(mosaic().acceptsMaskInput)
        #expect(ClipEffect(kind: ClipEffect.gaussianBlurKind).acceptsMaskInput)
        #expect(!ClipEffect(kind: ClipEffect.cropKind).acceptsMaskInput)
        #expect(ClipEffect(kind: ClipEffect.ultraKeyKind).acceptsMaskInput)
    }

    // MARK: Magic picking and following

    /// 8 x 4 labels: instance 1 on the left half, instance 2 on the right half of rows 1...2.
    private func labels() -> InstanceLabels {
        var l = [UInt8](repeating: 0, count: 32)
        for y in 1...2 { for x in 0..<4 { l[y * 8 + x] = 1 }; for x in 4..<8 { l[y * 8 + x] = 2 } }
        return InstanceLabels(width: 8, height: 4, labels: l)
    }

    @Test func pickAddsAndSubtractsInstances() {
        let l = labels()
        let t = Time.zero
        #expect(l.label(at: Vec2(0.1, 0.5)) == 1)
        #expect(l.label(at: Vec2(0.1, 0.05)) == 0)
        #expect(MagicPick.select([MagicPoint(position: Vec2(0.1, 0.5), subtract: false, sourceTime: t)], in: l) == [1])
        let both = [MagicPoint(position: Vec2(0.1, 0.5), subtract: false, sourceTime: t),
                    MagicPoint(position: Vec2(0.9, 0.5), subtract: false, sourceTime: t)]
        #expect(MagicPick.select(both, in: l) == [1, 2])
        #expect(MagicPick.select(both + [MagicPoint(position: Vec2(0.8, 0.4), subtract: true, sourceTime: t)], in: l) == [1])
        #expect(MagicPick.select([MagicPoint(position: Vec2(0.1, 0.05), subtract: false, sourceTime: t)], in: l).isEmpty)
        let matte = l.matte(of: [1])
        #expect(matte.area == 8)
        #expect(matte[0, 1] == 1 && matte[5, 1] == 0)
    }

    @Test func followKeepsTheInstanceThatOverlapsTheLastMatte() throws {
        let l = labels()
        let prev = l.matte(of: [2])
        // Next frame: the labels swapped numbers (Vision numbers instances per frame).
        let swapped = InstanceLabels(width: 8, height: 4, labels: l.labels.map { $0 == 1 ? 2 : $0 == 2 ? 1 : 0 })
        let f = try #require(MagicPick.follow(previous: prev, labels: swapped))
        #expect(f.selected == [1])
        #expect(f.confidence > 0.99)
        // Subject gone: lost.
        #expect(MagicPick.follow(previous: prev, labels: InstanceLabels(width: 8, height: 4, labels: [UInt8](repeating: 0, count: 32))) == nil)
    }

    @Test func followKeepsASplitLimbButNotAnotherPerson() throws {
        // 40 x 20. Last matte: the body, columns 10..<20 over all rows (200 texels).
        let w = 40, h = 20
        var prev = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 10..<20 { prev[y * w + x] = 1 } }
        let last = SubjectMatte(width: w, height: h, values: prev)
        /// Body = 1 where the last matte is; a second object 2 in rows 0..<rows, columns from..<to.
        func frame(_ from: Int, _ to: Int, rows: Int) -> InstanceLabels {
            var l = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 10..<20 { l[y * w + x] = 1 } }
            for y in 0..<rows { for x in from..<to { l[y * w + x] = 2 } }
            return InstanceLabels(width: w, height: h, labels: l)
        }
        // An arm the segmenter split off, swung out: 4 rows, columns 17..<27 (40 texels, 30 % still inside the last
        // matte). It is small against the subject and stays.
        #expect(try #require(MagicPick.follow(previous: last, labels: frame(17, 27, rows: 4))).selected == [1, 2])
        // The same arm only 10 % inside: something that merely touches the subject is not taken.
        #expect(try #require(MagicPick.follow(previous: last, labels: frame(19, 29, rows: 4))).selected == [1])
        // A second person stepping in (as large as the subject), 30 % inside: not the subject. The limb rule is for
        // small parts only, a whole object still needs half of itself inside.
        #expect(try #require(MagicPick.follow(previous: last, labels: frame(17, 27, rows: 20))).selected == [1])
        // ... and with 60 % inside it is taken, as before.
        #expect(try #require(MagicPick.follow(previous: last, labels: frame(14, 24, rows: 20))).selected.contains(2))
    }

    @Test func followWorksAcrossMatteSizes() throws {
        let l = labels()
        let prev = l.matte(of: [1]).resampled(width: 16, height: 8)
        let f = try #require(MagicPick.follow(previous: prev, labels: l))
        #expect(f.selected == [1])
    }

    @Test func cacheKeyFollowsMediaAndPoints() {
        let media = UUID()
        let a = MagicSelection(points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])
        var b = a
        #expect(a.cacheKey(media: media) == b.cacheKey(media: media))
        b.points[0].position = Vec2(0.6, 0.5)
        #expect(a.cacheKey(media: media) != b.cacheKey(media: media))
        #expect(a.cacheKey(media: media) != a.cacheKey(media: UUID()))
    }
}
