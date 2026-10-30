import Foundation
import Testing
@testable import SQCore

// F7.11 Anonymize (pure part): which segmented objects are people, the Face / Skin matte made from a person's matte, the
// frames listed for a manual check, and what the command writes into the clip.

@Suite struct AnonymizeTests {
    /// Labels of a w x h frame; each object fills columns x0..<x1 of rows y0..<y1.
    private func labels(_ w: Int, _ h: Int, _ objects: [(UInt8, Int, Int, Int, Int)]) -> InstanceLabels {
        var l = [UInt8](repeating: 0, count: w * h)
        for (id, x0, x1, y0, y1) in objects { for y in y0..<y1 { for x in x0..<x1 { l[y * w + x] = id } } }
        return InstanceLabels(width: w, height: h, labels: l)
    }

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AnonymizeBox { AnonymizeBox(x: x, y: y, width: w, height: h) }

    /// A person matte: columns x0..<x1, rows y0..<y1 of a w x h matte.
    private func matte(_ w: Int, _ h: Int, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> SubjectMatte {
        var v = [Float](repeating: 0, count: w * h)
        for y in y0..<y1 { for x in x0..<x1 { v[y * w + x] = 1 } }
        return SubjectMatte(width: w, height: h, values: v)
    }

    // MARK: People

    @Test func peopleAreTheObjectsUnderAFaceOrBodyLeftToRight() {
        // Object 1: a person on the right (body box only), object 2: a person on the left (face), object 3: a lamp.
        let l = labels(40, 20, [(1, 26, 34, 4, 20), (2, 4, 12, 2, 20), (3, 18, 22, 0, 6)])
        let face = AnonymizeFace(box: box(0.125, 0.1, 0.15, 0.2), confidence: 0.9)
        let people = AnonymizePeople.find(labels: l, bodies: [box(0.65, 0.2, 0.2, 0.8)], faces: [face])
        #expect(people.map(\.label) == [2, 1])
        #expect(people[0].face == face && people[1].face == nil)
        // The pick point lies on the person (a Magic pick there selects that object).
        for p in people { #expect(l.label(at: p.point) == p.label) }
        #expect(abs(people[0].box.x - 0.1) < 1e-9 && abs(people[0].box.width - 0.2) < 1e-9)
    }

    @Test func aBoxOverBackgroundOrTheSamePersonTwiceGivesNoExtraPerson() {
        let l = labels(40, 20, [(1, 10, 20, 2, 20)])
        let face = AnonymizeFace(box: box(0.3, 0.1, 0.15, 0.25), confidence: 0.8)
        let people = AnonymizePeople.find(labels: l, bodies: [box(0.25, 0.1, 0.25, 0.9), box(0.7, 0.1, 0.2, 0.8)], faces: [face])
        #expect(people.count == 1)
        #expect(people[0].face == face)
    }

    // MARK: Face

    @Test func faceTargetCoversTheFaceAndLeavesTheBody() {
        let person = matte(80, 60, 30, 50, 5, 60)
        var r = AnonymizeRefiner(part: .face)
        let out = r.refine(person: person, faces: [AnonymizeFace(box: box(0.4, 0.1, 0.2, 0.25), confidence: 0.9)], guide: nil)
        #expect(out.flag == nil)
        // The whole detected box is covered, with room around it (hair, chin, ears): never tighter than the detection.
        for (x, y) in [(32, 6), (47, 6), (32, 20), (47, 20), (40, 13)] { #expect(out.matte[x, y] == 1, "\(x),\(y)") }
        #expect(out.matte[40, 45] == 0)                    // the body stays
        #expect(out.matte[5, 13] == 0)
    }

    @Test func aFaceOfSomebodyElseIsNotUsed() {
        let person = matte(80, 60, 30, 50, 5, 60)
        var r = AnonymizeRefiner(part: .face)
        let other = AnonymizeFace(box: box(0.05, 0.1, 0.15, 0.25), confidence: 0.95)
        let out = r.refine(person: person, faces: [other], guide: nil)
        #expect(out.flag == .noFace)
        #expect(out.matte[40, 10] == 1)                    // the head end of the person, estimated
        #expect(out.matte[8, 12] == 0)                     // not the other face
    }

    @Test func aFrameWithoutAFaceKeepsTheLastFacePlaceOnThePersonAndIsFlagged() {
        var r = AnonymizeRefiner(part: .face)
        _ = r.refine(person: matte(80, 60, 30, 50, 5, 60), faces: [AnonymizeFace(box: box(0.4, 0.1, 0.2, 0.25), confidence: 0.9)], guide: nil)
        // The person moved 20 px right and turned away: no face. The cover moves with the person.
        let out = r.refine(person: matte(80, 60, 50, 70, 5, 60), faces: [], guide: nil)
        #expect(out.flag == .noFace)
        #expect(out.matte[60, 13] == 1)
        #expect(out.matte[40, 13] < 1)
        #expect(out.matte[60, 50] == 0)
    }

    @Test func anUnsureFaceIsUsedAndFlagged() {
        var r = AnonymizeRefiner(part: .face)
        let out = r.refine(person: matte(80, 60, 30, 50, 5, 60), faces: [AnonymizeFace(box: box(0.4, 0.1, 0.2, 0.25), confidence: 0.3)], guide: nil)
        #expect(out.flag == .lowConfidence)
        #expect(out.matte[40, 13] == 1)
    }

    @Test func wholePersonIsThePersonMatteUnchanged() {
        let person = matte(80, 60, 30, 50, 5, 60)
        var r = AnonymizeRefiner(part: .person)
        let out = r.refine(person: person, faces: [], guide: nil)
        #expect(out.matte == person && out.flag == nil)
    }

    // MARK: Skin

    /// A picture at the matte's size: skin tone on the face rows (5..<20) and an arm (rows 30..<40), blue shirt elsewhere on
    /// the person, gray background; `tattoo`: a dark patch in the middle of the arm.
    private func picture(_ w: Int, _ h: Int, tattoo: Bool) -> MagicGuide {
        var rgb = [Float](repeating: 0.5, count: w * h * 3)
        for y in 0..<h {
            for x in 30..<50 {
                let skin = (5..<20).contains(y) || (30..<40).contains(y)
                var c: (Float, Float, Float) = skin ? (0.85, 0.62, 0.5) : (0.1, 0.2, 0.7)
                if tattoo, (33..<37).contains(y), (37..<43).contains(x) { c = (0.1, 0.12, 0.12) }
                let i = (y * w + x) * 3
                rgb[i] = c.0; rgb[i + 1] = c.1; rgb[i + 2] = c.2
            }
        }
        return MagicGuide(width: w, height: h, rgb: rgb)
    }

    @Test func skinTargetCoversSkinAndLeavesClothes() {
        let person = matte(80, 60, 30, 50, 5, 60)
        var r = AnonymizeRefiner(part: .skin)
        let face = AnonymizeFace(box: box(0.4, 0.1, 0.2, 0.2), confidence: 0.9)
        let out = r.refine(person: person, faces: [face], guide: picture(80, 60, tattoo: false))
        #expect(out.flag == nil)
        #expect(out.matte[40, 12] == 1)                    // face
        #expect(out.matte[40, 35] == 1)                    // arm
        #expect(out.matte[40, 25] == 0)                    // shirt between them
        #expect(out.matte[40, 52] == 0)                    // shirt below
        #expect(out.matte[10, 12] == 0)                    // background
    }

    @Test func aTattooInsideSkinIsCoveredToo() {
        let person = matte(80, 60, 30, 50, 5, 60)
        var r = AnonymizeRefiner(part: .skin)
        let face = AnonymizeFace(box: box(0.4, 0.1, 0.2, 0.2), confidence: 0.9)
        let out = r.refine(person: person, faces: [face], guide: picture(80, 60, tattoo: true))
        for x in 37..<43 { #expect(out.matte[x, 35] == 1, "x \(x)") }
        #expect(out.matte[40, 52] == 0)
    }

    @Test func skinWithoutAFaceUsesTheToneLearnedBeforeAndIsFlagged() {
        let person = matte(80, 60, 30, 50, 5, 60)
        var r = AnonymizeRefiner(part: .skin)
        let pic = picture(80, 60, tattoo: false)
        _ = r.refine(person: person, faces: [AnonymizeFace(box: box(0.4, 0.1, 0.2, 0.2), confidence: 0.9)], guide: pic)
        let out = r.refine(person: person, faces: [], guide: pic)
        #expect(out.flag == .noFace)
        #expect(out.matte[40, 35] == 1 && out.matte[40, 52] == 0)
    }

    @Test func skinThatCannotBeFoundCoversTheWholePerson() {
        // No picture to read, or nothing skin colored: cover more, never less, and say so.
        let person = matte(80, 60, 30, 50, 5, 60)
        var a = AnonymizeRefiner(part: .skin)
        let none = a.refine(person: person, faces: [], guide: nil)
        #expect(none.matte == person && none.flag == .wholePerson)
        var b = AnonymizeRefiner(part: .skin)
        let blue = MagicGuide(width: 80, height: 60, rgb: (0..<(80 * 60 * 3)).map { $0 % 3 == 2 ? 0.8 : 0.1 })
        let out = b.refine(person: person, faces: [], guide: blue)
        #expect(out.matte == person && out.flag == .wholePerson)
    }

    // MARK: Check list

    @Test func flaggedFramesCollapseIntoRangesPerReason() {
        let fd = 1.0 / 25
        var flags: [(pts: Double, reason: AnonymizeCheck.Reason)] = []
        for i in 10..<20 { flags.append((Double(i) * fd, .noFace)) }
        for i in 40..<43 { flags.append((Double(i) * fd, .noFace)) }
        flags.append((30 * fd, .lowConfidence))
        let r = AnonymizeReport.ranges(person: 2, flags: flags, gap: fd)
        #expect(r.count == 3)
        #expect(r.map(\.reason) == [.noFace, .lowConfidence, .noFace])
        #expect(abs(r[0].from - 10 * fd) < 1e-9 && abs(r[0].to - 19 * fd) < 1e-9)
        #expect(abs(r[1].from - 30 * fd) < 1e-9 && r[1].from == r[1].to)
        #expect(r.allSatisfy { $0.person == 2 })
        #expect(AnonymizeReport.ranges(person: 0, flags: [], gap: fd).isEmpty)
    }

    @Test func noCheckTextClaimsCertainty() {
        for r in AnonymizeCheck.Reason.allCases {
            let t = r.text.lowercased()
            #expect(!t.isEmpty)
            for word in ["guarantee", "certain", "always", "fully", "safe"] { #expect(!t.contains(word), "\(r): \(t)") }
        }
    }

    // MARK: Clip

    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    private func pick(_ x: Double, part: AnonymizeTarget?) -> MagicSelection {
        MagicSelection(points: [MagicPoint(position: Vec2(x, 0.5), subtract: false, sourceTime: Time(1, 2))], part: part)
    }

    @Test func anonymizeAddsOneCoverLimitedToOneMaskPerPerson() throws {
        var c = clip()
        let ids = c.addAnonymize([pick(0.3, part: .face), pick(0.7, part: .face)], target: .face, cover: .mosaic,
                                 subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
        #expect(ids.count == 2 && c.masks.map(\.id) == ids)
        #expect(c.masks.map(\.name) == ["Face 1", "Face 2"])
        for m in c.masks {
            #expect(m.source == .magic && !m.usedByOpacity)          // the picture is never cut, only the cover is limited
            #expect(m.magic?.part == .face)
        }
        #expect(c.effects.count == 1)
        let e = try #require(c.effects.first)
        #expect(e.kind == ClipEffect.mosaicKind && e.maskInput == ids)
        #expect(e.imageFilter(atLocal: .zero) == .mosaic(columns: 38, rows: 22, sharp: false))     // 50 px blocks
        #expect(c.hasLiveMaskInput(e))
        // A second run adds its own masks and cover and numbers on.
        let more = c.addAnonymize([pick(0.5, part: nil)], target: .person, cover: .blur, subjectWidth: 300, frameWidth: 1920, frameHeight: 1080)
        #expect(c.masks.count == 3 && c.masks.last?.name == "Person 1")
        // A whole person made by Anonymize is marked too: its mask must cover.
        #expect(c.masks.last?.magic?.part == .person && c.masks.last?.magic?.mustCover == true)
        #expect(c.effects.count == 2 && c.effects[0].kind == ClipEffect.gaussianBlurKind && c.effects[0].maskInput == more)
        #expect(c.effects[0].parameters[ClipEffect.blurrinessKey]?.value(atLocal: .zero) ?? 0 >= 54)
        #expect(c.addAnonymize([], target: .face, cover: .mosaic, subjectWidth: 1, frameWidth: 10, frameHeight: 10).isEmpty)
        #expect(c.effects.count == 2)
    }

    // MARK: Stored pick

    @Test func thePartOfAPickIsAnOptionalKeyAndNeverChangesThePersonKey() throws {
        let plain = pick(0.3, part: nil), face = pick(0.3, part: .face), skin = pick(0.3, part: .skin), person = pick(0.3, part: .person)
        let media = UUID()
        // One key for the followed person whatever the part: a build that does not know `part` (or a file whose `part` an
        // old build dropped) reads it and covers the whole person.
        let base = plain.cacheKey(media: media)
        #expect([face, skin, person].allSatisfy { $0.cacheKey(media: media) == base })
        // The narrowed matte lives under a derived key (a Face and a Skin run on one person never overwrite each other).
        let fk = try #require(face.partKey(media: media)), sk = try #require(skin.partKey(media: media))
        #expect(fk != sk && fk.hasPrefix(base) && sk.hasPrefix(base) && fk != base)
        #expect(plain.partKey(media: media) == nil && person.partKey(media: media) == nil)
        #expect(face.matteKey(media: media) == fk && person.matteKey(media: media) == base && plain.matteKey(media: media) == base)
        #expect(face.matteKeys(media: media) == [base, fk] && plain.matteKeys(media: media) == [base])
        #expect(face.mustCover && skin.mustCover && person.mustCover && !plain.mustCover)
        // A pick without a part is stored exactly as before.
        let json = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!json.contains("part"))
        let old = try JSONDecoder().decode(MagicSelection.self, from: JSONEncoder().encode(plain))
        #expect(old == plain && old.part == nil)
        let back = try JSONDecoder().decode(MagicSelection.self, from: JSONEncoder().encode(skin))
        #expect(back == skin)
    }

    // MARK: Keys a project keeps and a render reads

    @Test func aFaceMaskKeepsThePersonMatteAndTheNarrowedOne() throws {
        var c = clip()
        c.addAnonymize([pick(0.3, part: .face)], target: .face, cover: .mosaic, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
        let sel = try #require(c.masks.first?.magic)
        let base = sel.cacheKey(media: c.media), part = try #require(sel.partKey(media: c.media))
        var track = Track(kind: .video)
        try track.overwrite(c)
        let p = Project(name: "P", timelines: [Timeline(name: "t", frameDuration: Time(1, 25), tracks: [track])])
        // Both stay on close; with the mask deleted neither is listed, so the sweep removes them.
        #expect(p.magicMatteCacheKeys == [base, part])
        var gone = c
        gone.masks = []
        var t2 = Track(kind: .video)
        try t2.overwrite(gone)
        #expect(Project(name: "P", timelines: [Timeline(name: "t", frameDuration: Time(1, 25), tracks: [t2])]).magicMatteCacheKeys.isEmpty)
        // The render draws the narrowed matte, knows where the whole person is and that the mask must cover.
        #expect(c.renderedMagicKeys == [part])
        let use = try #require(c.effects(at: Time(1, 1)).magicMattes.first)
        #expect(use.cacheKey == part && use.baseKey == base && use.mustCover)
        // An ordinary Magic mask: as before.
        var o = clip()
        var m = ClipMask.makeMagic(name: "Mask (1)", points: pick(0.3, part: nil).points)
        m.usedByOpacity = true
        o.masks = [m]
        let plain = try #require(o.effects(at: Time(1, 1)).magicMattes.first)
        #expect(plain.cacheKey == m.magic?.cacheKey(media: o.media) && plain.baseKey == nil && !plain.mustCover)
    }

    // MARK: Cover and other effects

    /// The mattes are tracked on the source frame. The cover is therefore the first pixel effect, so a Horizontal Flip
    /// added before the run flips the covered picture and the cover stays on the face.
    @Test func theCoverActsBeforeAHorizontalFlipAddedEarlier() throws {
        var c = clip()
        c.effects = [try #require(ClipEffect.make(kind: ClipEffect.horizontalFlipKind))]
        let ids = c.addAnonymize([pick(0.3, part: .face)], target: .face, cover: .mosaic, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
        #expect(c.effects.map(\.kind) == [ClipEffect.mosaicKind, ClipEffect.horizontalFlipKind])
        let segs = c.effects(at: Time(1, 1)).segments
        let cover = try #require(segs.firstIndex { !$0.scope.isEmpty })
        let flip = try #require(segs.firstIndex { $0.filter == .flip(horizontal: true, vertical: false) })
        #expect(cover < flip)
        #expect(segs[cover].scope.map(\.matteKey) == ids.map { Optional($0) })
        if case .mosaic = segs[cover].filter {} else { Issue.record("the masked segment is not the Mosaic") }
    }

    /// Transform and the Standard Stabilizer are stages: they move the finished picture of all pixel effects, so the cover
    /// (made on the clip's own frame, where the matte was tracked) moves with the face.
    @Test func transformAndStabilizerStagesMoveTheCoveredPicture() throws {
        var plain = clip()
        plain.addAnonymize([pick(0.3, part: .face)], target: .face, cover: .mosaic, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
        for kind in [ClipEffect.transformKind, ClipEffect.stabilizeKind] {
            var c = clip()
            var stage = try #require(ClipEffect.make(kind: kind))
            stage.parameters[ClipEffect.stagePositionXKey] = AnimatedProperty(300)
            stage.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(150)
            c.effects = [stage]
            c.addAnonymize([pick(0.3, part: .face)], target: .face, cover: .mosaic, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080)
            #expect(c.effects.map(\.kind) == [ClipEffect.mosaicKind, kind])
            // The same clip as `plain` plus the stage (a new clip has other media and mask ids).
            c = plain
            c.effects.append(stage)
            #expect(stage.isTransformStage)
            // Same pixel passes as without the stage: the cover is not made on a moved picture.
            #expect(c.effects(at: Time(1, 1)).segments == plain.effects(at: Time(1, 1)).segments, "\(kind)")
        }
    }

    // MARK: Fallback and Track again

    @Test func theFallbackGrowsWithTheDistanceToTheNearestTrackedFrame() {
        #expect(AnonymizeFallback.growth(gap: 0.04) >= 0.05)
        #expect(AnonymizeFallback.growth(gap: 1) > AnonymizeFallback.growth(gap: 0.04))
        #expect(AnonymizeFallback.growth(gap: 10) > AnonymizeFallback.growth(gap: 1))
        #expect(AnonymizeFallback.wholeFrame.values.allSatisfy { $0 == 1 })
        #expect(AnonymizeCheck.Reason.lost.isCritical && !AnonymizeCheck.Reason.noFace.isCritical)
    }

    /// Track on a Face mask from the middle of a clip: the refiner starts with the face place of the stored mattes, so a
    /// first frame without a detected face is covered there, not at the head end of the person.
    @Test func aSeededRefinerPlacesTheFaceWhereTheStoredMatteHadIt() throws {
        let person = matte(100, 100, 30, 70, 10, 100)
        // A profile shot: the face sits low and to the right on the person.
        let stored = AnonymizeFace(box: box(0.55, 0.40, 0.10, 0.10), confidence: 0.9)
        var first = AnonymizeRefiner(part: .face)
        let narrowed = first.refine(person: person, faces: [stored], guide: nil).matte
        var seeded = AnonymizeRefiner(part: .face)
        seeded.seed(person: person, narrowed: narrowed)
        let got = seeded.refine(person: person, faces: [], guide: nil)
        #expect(got.flag == .noFace)
        let e = try #require(AnonymizeRefiner.extent(got.matte)), want = try #require(AnonymizeRefiner.extent(narrowed))
        #expect(abs(e.center.x - want.center.x) < 0.03 && abs(e.center.y - want.center.y) < 0.03)
        #expect(abs(e.width - want.width) < 0.04 && abs(e.height - want.height) < 0.04)
        // Unseeded it would sit at the head end.
        var blind = AnonymizeRefiner(part: .face)
        let head = try #require(AnonymizeRefiner.extent(blind.refine(person: person, faces: [], guide: nil).matte))
        #expect(abs(head.center.y - want.center.y) > 0.1)
    }
}
