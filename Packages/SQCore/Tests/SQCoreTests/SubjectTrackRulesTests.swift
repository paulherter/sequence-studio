import Foundation
import Testing
@testable import SQCore

@Suite struct SubjectTrackRulesTests {
    /// A square of logits: +8 inside the box (fractions), -8 outside.
    static func logits(_ box: SubjectTrackBox, size: Int = 64) -> [Float] {
        var out = [Float](repeating: -8, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Double(x) + 0.5) / Double(size), v = (Double(y) + 0.5) / Double(size)
                if u >= box.x0, u <= box.x1, v >= box.y0, v <= box.y1 { out[y * size + x] = 8 }
            }
        }
        return out
    }

    @Test func proAndMaxChipsUseTheGPUOthersTheNeuralEngineIntelNothing() {
        #expect(SubjectTrackRules.compute(cpuBrand: "Apple M1 Pro", isIntel: false, lowMemory: false) == .gpu)
        #expect(SubjectTrackRules.compute(cpuBrand: "Apple M3 Max", isIntel: false, lowMemory: false) == .gpu)
        #expect(SubjectTrackRules.compute(cpuBrand: "Apple M2 Ultra", isIntel: false, lowMemory: false) == .gpu)
        #expect(SubjectTrackRules.compute(cpuBrand: "Apple M2", isIntel: false, lowMemory: false) == .neuralEngine)
        #expect(SubjectTrackRules.compute(cpuBrand: "", isIntel: false, lowMemory: false) == .neuralEngine)
        // 8 GB: the GPU plan takes 400 MB, the Neural Engine one 114 MB.
        #expect(SubjectTrackRules.compute(cpuBrand: "Apple M1 Pro", isIntel: false, lowMemory: true) == .neuralEngine)
        #expect(SubjectTrackRules.compute(cpuBrand: "Intel(R) Core(TM) i9", isIntel: true, lowMemory: false) == nil)
    }

    @Test func theFrameIsStretchedOntoTheModelSquare() {
        let p = SubjectTrackRules.modelPoint(Vec2(0.25, 0.5))
        #expect(p.x == 256 && p.y == 512)
        let b = SubjectTrackRules.modelBox(SubjectTrackBox(x0: 0.1, y0: 0.2, x1: 0.5, y1: 1))
        #expect(abs(b.x0 - 102.4) < 1e-9 && abs(b.y0 - 204.8) < 1e-9 && b.x1 == 512 && b.y1 == 1024)
    }

    @Test func logitsBecomeAMatteOfTheFrameSizeAndBack() throws {
        let box = SubjectTrackBox(x0: 0.25, y0: 0.5, x1: 0.75, y1: 1)
        let m = SubjectTrackRules.matte(logits: Self.logits(box), size: 64, width: 160, height: 90)
        #expect(m.width == 160 && m.height == 90)
        #expect(m.values[60 * 160 + 80] > 0.99)   // inside
        #expect(m.values[10 * 160 + 80] < 0.01)   // above the box
        #expect(m.values[60 * 160 + 10] < 0.01)   // left of it
        let found = try #require(SubjectTrackRules.box(of: m))
        #expect(abs(found.x0 - 0.25) < 0.02 && abs(found.x1 - 0.75) < 0.02 && abs(found.y0 - 0.5) < 0.02 && found.y1 > 0.98)
        let back = SubjectTrackRules.logits(from: m, size: 64)
        #expect(SubjectTrackRules.iou(back, Self.logits(box)) > 0.95)
        #expect(back.max()! <= 10 && back.min()! >= -10)
    }

    /// A weak answer of the model (logits of +-0.6, as the first frame of a pick gives on hair and beard) is solid inside
    /// the mask and soft only in a thin band at its edge, which stays where the logits cross 0 (sigmoid gave 0.65 inside).
    @Test func aWeakMaskIsSolidInsideAndSoftOnlyAtItsEdge() {
        let size = 64, px = 256   // 4 px per logit cell
        var l = [Float](repeating: -0.6, count: size * size)
        for y in 16..<48 { for x in 16..<48 { l[y * size + x] = 0.6 } }
        // A strand one cell (4 px) wide: +1 on a -1 field.
        for y in 52..<60 { for x in 0..<size { l[y * size + x] = -1 } }
        for y in 52..<60 { l[y * size + 40] = 1 }
        let m = SubjectTrackRules.matte(logits: l, size: size, width: px, height: px)
        let row = 128 * px
        // The logits cross 0 at x = 63.5 px: 0.5 lies there.
        #expect(m.values[row + 63] < 0.5 && m.values[row + 64] > 0.5)
        // Solid 2 px in from the edge, empty 2 px out, everywhere along the row.
        for x in 0..<px {
            let d = x < 128 ? Double(x) - 63.5 : 191.5 - Double(x)
            if d >= 2 { #expect(m.values[row + x] >= 0.99, "x \(x): \(m.values[row + x])") }
            if d <= -2 { #expect(m.values[row + x] <= 0.01, "x \(x): \(m.values[row + x])") }
        }
        // The thin strand's middle is solid too.
        #expect(m.values[56 * 4 * px + 40 * 4 + 1] >= 0.99 && m.values[56 * 4 * px + 40 * 4 + 2] >= 0.99)
        // A matte the model is sure of keeps its shape.
        let sure = SubjectTrackRules.matte(logits: Self.logits(SubjectTrackBox(x0: 0.25, y0: 0.25, x1: 0.75, y1: 0.75)), size: 64, width: px, height: px)
        #expect(sure.values[row + 128] == 1 && sure.values[row + 10] == 0)
    }

    @Test func statsOfLogitsGiveAreaAndBox() throws {
        let s = SubjectTrackRules.stats(logits: Self.logits(SubjectTrackBox(x0: 0, y0: 0, x1: 0.5, y1: 0.5)), size: 64)
        #expect(abs(s.area - 0.25) < 1e-9)
        let b = try #require(s.box)
        #expect(b.x0 == 0 && b.y0 == 0 && b.x1 == 0.5 && b.y1 == 0.5)
        let none = SubjectTrackRules.stats(logits: [Float](repeating: -3, count: 64 * 64), size: 64)
        #expect(none.area == 0 && none.box == nil)
        #expect(SubjectTrackRules.box(of: SubjectMatte(width: 1, height: 1, values: [0])) == nil)
    }

    @Test func theInteriorPointLiesOnTheSubjectEvenWhenTheCentroidDoesNot() throws {
        // A ring: the centroid is in the hole.
        var v = [Float](repeating: 0, count: 40 * 40)
        for y in 0..<40 { for x in 0..<40 where (8..<32).contains(x) && (8..<32).contains(y) && !((14..<26).contains(x) && (14..<26).contains(y)) { v[y * 40 + x] = 1 } }
        let m = SubjectMatte(width: 40, height: 40, values: v)
        let p = try #require(SubjectTrackRules.interiorPoint(of: m))
        #expect(m.values[min(Int(p.y * 40), 39) * 40 + min(Int(p.x * 40), 39)] == 1)
        #expect(SubjectTrackRules.interiorPoint(of: SubjectMatte(width: 2, height: 2, values: [0, 0, 0, 0])) == nil)
    }

    @Test func theLargestTrustedCandidateWinsElseTheBestRated() {
        #expect(SubjectTrackRules.largestCandidate(areas: [0.9, 0.1, 0.3, 0.2], ious: [0.9, 0.9, 0.7, 0.8]) == 2)
        #expect(SubjectTrackRules.largestCandidate(areas: [0.9, 0.1, 0.3, 0.2], ious: [0.9, 0.9, 0.5, 0.8]) == 3)
        #expect(SubjectTrackRules.largestCandidate(areas: [0, 0.1, 0.3, 0.2], ious: [0, 0.4, 0.5, 0.3]) == 2)
        // An empty candidate is never the largest.
        #expect(SubjectTrackRules.largestCandidate(areas: [0, 0, 0, 0.2], ious: [0, 0.9, 0.9, 0.2]) == 3)
    }

    @Test func boxesOverlapAndContain() {
        let a = SubjectTrackBox(x0: 0, y0: 0, x1: 0.5, y1: 0.5), b = SubjectTrackBox(x0: 0.25, y0: 0, x1: 0.75, y1: 0.5)
        #expect(abs(a.iou(b) - 1.0 / 3) < 1e-9)
        #expect(a.contains(Vec2(0.1, 0.4)) && !a.contains(Vec2(0.6, 0.4)))
        #expect(a.iou(SubjectTrackBox(x0: 0.6, y0: 0.6, x1: 0.7, y1: 0.7)) == 0)
    }

    // MARK: Lost rule

    static func box(_ cx: Double, _ cy: Double, _ side: Double) -> SubjectTrackBox {
        SubjectTrackBox(x0: cx - side / 2, y0: cy - side / 2, x1: cx + side / 2, y1: cy + side / 2)
    }

    @Test func aSteadySubjectIsNeverLost() {
        var rule = SubjectLostRule()
        for i in 0..<40 {
            let side = 0.2 + Double(i) * 0.005   // grows slowly, moves slowly
            do { let l = rule.isLost(area: side * side, box: Self.box(0.3 + Double(i) * 0.01, 0.5, side)); #expect(!l) }
        }
    }

    @Test func anEmptyMaskIsLostAndTheSubjectComesBackAnywhere() {
        var rule = SubjectLostRule()
        do { let l = rule.isLost(area: 0.04, box: Self.box(0.2, 0.5, 0.2)); #expect(!l) }
        do { let l = rule.isLost(area: 0, box: nil); #expect(l) }
        do { let l = rule.isLost(area: 0, box: nil); #expect(l) }
        // Reappears on the other side after the gap: found again at once.
        do { let l = rule.isLost(area: 0.04, box: Self.box(0.8, 0.5, 0.2)); #expect(!l) }
    }

    @Test func aMaskThatCollapsesIsLostUntilItIsBack() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.04, box: Self.box(0.5, 0.5, 0.2)); #expect(!l) }
        do { let l = rule.isLost(area: 0.004, box: Self.box(0.5, 0.5, 0.06)); #expect(l) }   // a tenth of the subject
        do { let l = rule.isLost(area: 0.001, box: Self.box(0.55, 0.5, 0.03)); #expect(l) }
        do { let l = rule.isLost(area: 0.035, box: Self.box(0.52, 0.5, 0.19)); #expect(!l) }
    }

    @Test func aMaskThatFloodsTheFrameIsLost() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.04, box: Self.box(0.5, 0.5, 0.2)); #expect(!l) }
        do { let l = rule.isLost(area: 0.9, box: SubjectTrackBox(x0: 0, y0: 0, x1: 1, y1: 1)); #expect(l) }
        do { let l = rule.isLost(area: 0.045, box: Self.box(0.5, 0.5, 0.21)); #expect(!l) }
    }

    @Test func aJumpToAnotherPlaceOnTheNextFrameIsLost() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.01, box: Self.box(0.2, 0.2, 0.1)); #expect(!l) }
        do { let l = rule.isLost(area: 0.01, box: Self.box(0.8, 0.8, 0.1)); #expect(l) }
        // Back at its place: found.
        do { let l = rule.isLost(area: 0.01, box: Self.box(0.22, 0.2, 0.1)); #expect(!l) }
    }

    /// The rule must not lock a run out for good: a new state that holds for a few frames is taken as the subject.
    @Test func aNewStateThatHoldsIsAcceptedAfterAFewFrames() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.04, box: Self.box(0.5, 0.5, 0.2)); #expect(!l) }
        var lost = 0
        for _ in 0..<(rule.settle - 1) where rule.isLost(area: 0.005, box: Self.box(0.5, 0.5, 0.07)) { lost += 1 }
        #expect(lost == rule.settle - 1)
        do { let l = rule.isLost(area: 0.005, box: Self.box(0.5, 0.5, 0.07)); #expect(!l) }
    }

    /// Odd frames that do not agree with each other (flicker) never settle.
    @Test func flickerDoesNotSettle() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.04, box: Self.box(0.5, 0.5, 0.2)); #expect(!l) }
        for i in 0..<12 {
            let odd = i % 2 == 0 ? Self.box(0.1, 0.1, 0.03) : Self.box(0.9, 0.9, 0.05)
            do { let l = rule.isLost(area: odd.area, box: odd); #expect(l) }
        }
    }

    @Test func aRuleStartedFromAReferenceJudgesTheFirstFrame() {
        var rule = SubjectLostRule(area: 0.04, box: Self.box(0.5, 0.5, 0.2))
        do { let l = rule.isLost(area: 0.0005, box: Self.box(0.5, 0.5, 0.02)); #expect(l) }
        do { let l = rule.isLost(area: 0.04, box: Self.box(0.5, 0.5, 0.2)); #expect(!l) }
    }

    // MARK: prompt box sanity

    static func matte(_ boxes: [SubjectTrackBox], size: Int = 100) -> SubjectMatte {
        var v = [Float](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size {
            let u = (Double(x) + 0.5) / Double(size), w = (Double(y) + 0.5) / Double(size)
            if boxes.contains(where: { u >= $0.x0 && u <= $0.x1 && w >= $0.y0 && w <= $0.y1 }) { v[y * size + x] = 1 }
        } }
        return SubjectMatte(width: size, height: size, values: v)
    }

    @Test func instanceBoxIsTheComponentUnderTheClickNotTheUnionOfNeighbors() throws {
        let a = SubjectTrackBox(x0: 0.1, y0: 0.2, x1: 0.3, y1: 0.8), b = SubjectTrackBox(x0: 0.6, y0: 0.3, x1: 0.9, y1: 0.7)
        let m = Self.matte([a, b])
        let box = try #require(SubjectTrackRules.instanceBox(in: m, at: Vec2(0.2, 0.5)))
        #expect(abs(box.x0 - 0.1) < 0.02 && abs(box.x1 - 0.3) < 0.02 && abs(box.y0 - 0.2) < 0.02 && abs(box.y1 - 0.8) < 0.02)
        let other = try #require(SubjectTrackRules.instanceBox(in: m, at: Vec2(0.75, 0.5)))
        #expect(abs(other.x0 - 0.6) < 0.02 && abs(other.x1 - 0.9) < 0.02)
        #expect(SubjectTrackRules.box(of: m)!.area > a.area + b.area)
    }

    @Test func instanceBoxTakesTheNearestComponentWhenTheClickMissesAndNilWhenEmpty() throws {
        let a = SubjectTrackBox(x0: 0.1, y0: 0.1, x1: 0.2, y1: 0.2)
        let m = Self.matte([a])
        let box = try #require(SubjectTrackRules.instanceBox(in: m, at: Vec2(0.23, 0.15)))
        #expect(abs(box.x1 - 0.2) < 0.02)
        #expect(SubjectTrackRules.instanceBox(in: Self.matte([]), at: Vec2(0.5, 0.5)) == nil)
    }

    @Test func aPromptBoxMuchLargerThanItsInstanceIsShrunkToTheInstance() {
        let instance = SubjectTrackBox(x0: 0.4, y0: 0.2, x1: 0.6, y1: 0.8)
        let big = SubjectTrackBox(x0: 0.2, y0: 0.1, x1: 0.8, y1: 0.9)
        #expect(SubjectTrackRules.promptBox(big, instance: instance) == instance)
        let close = SubjectTrackBox(x0: 0.38, y0: 0.18, x1: 0.62, y1: 0.82)
        #expect(SubjectTrackRules.promptBox(close, instance: instance) == close)
        #expect(SubjectTrackRules.promptBox(big, instance: nil) == big)
    }

    /// Logit grids (256) of a person and of what the system's segmentation saw: the person plus `extra` boxes.
    static func held(_ extra: [SubjectTrackBox], person: SubjectTrackBox = SubjectTrackBox(x0: 0.4, y0: 0.2, x1: 0.6, y1: 0.8)) -> (answer: [Float], seen: [Float]) {
        let answer = logits(person, size: 256)
        var seen = answer
        for box in extra { for (i, v) in logits(box, size: 256).enumerated() where v > 0 { seen[i] = v } }
        return (answer, seen)
    }

    @Test func aHeldObjectTheSegmentationSawNextToTheAnswerIsItsHeldPiece() throws {
        // A phone held out at the side, touching the hand.
        let phone = SubjectTrackBox(x0: 0.6, y0: 0.45, x1: 0.64, y1: 0.53)
        let (answer, seen) = Self.held([phone])
        let piece = try #require(SubjectTrackRules.heldPiece(seen: seen, answer: answer, size: 256))
        let box = try #require(SubjectTrackRules.stats(logits: piece, size: 256).box)
        #expect(abs(box.x0 - 0.6) < 0.01 && abs(box.x1 - 0.64) < 0.01 && abs(box.y0 - 0.45) < 0.01 && abs(box.y1 - 0.53) < 0.01, "\(box)")
        // Two held objects: the larger one first, and no more than asked.
        let cup = SubjectTrackBox(x0: 0.36, y0: 0.5, x1: 0.4, y1: 0.55)
        let both = Self.held([phone, cup])
        let pieces = SubjectTrackRules.heldPieces(seen: both.seen, answer: both.answer, size: 256)
        #expect(pieces.count == 2)
        #expect((SubjectTrackRules.stats(logits: pieces[0], size: 256).box?.x0 ?? 0) > 0.55)
        #expect((SubjectTrackRules.stats(logits: pieces[1], size: 256).box?.x1 ?? 1) < 0.45)
        #expect(SubjectTrackRules.heldPieces(seen: both.seen, answer: both.answer, size: 256, limit: 1).count == 1)
    }

    @Test func outlineSliversNeighborsAndObjectsApartAreNoHeldPiece() {
        // The segmentation's outline a pixel wider all around than the model's.
        let wider = Self.held([SubjectTrackBox(x0: 0.396, y0: 0.196, x1: 0.604, y1: 0.804)])
        #expect(SubjectTrackRules.heldPiece(seen: wider.seen, answer: wider.answer, size: 256) == nil)
        // A touching neighbor as large as the person.
        let pair = Self.held([SubjectTrackBox(x0: 0.6, y0: 0.2, x1: 0.8, y1: 0.8)])
        #expect(SubjectTrackRules.heldPiece(seen: pair.seen, answer: pair.answer, size: 256) == nil)
        // An object that does not touch the person.
        let apart = Self.held([SubjectTrackBox(x0: 0.66, y0: 0.45, x1: 0.7, y1: 0.53)])
        #expect(SubjectTrackRules.heldPiece(seen: apart.seen, answer: apart.answer, size: 256) == nil)
        // Nothing beyond the answer, or a speck.
        let same = Self.held([])
        #expect(SubjectTrackRules.heldPiece(seen: same.seen, answer: same.answer, size: 256) == nil)
        let speck = Self.held([SubjectTrackBox(x0: 0.6, y0: 0.5, x1: 0.606, y1: 0.506)])
        #expect(SubjectTrackRules.heldPiece(seen: speck.seen, answer: speck.answer, size: 256) == nil)
        // A fleck of 3 x 3 grid pixels; 5 x 5 is a phone held by a person far away.
        let fleck = Self.held([SubjectTrackBox(x0: 0.6, y0: 0.5, x1: 0.6 + 3.0 / 256, y1: 0.5 + 3.0 / 256)])
        #expect(SubjectTrackRules.heldPiece(seen: fleck.seen, answer: fleck.answer, size: 256) == nil)
        let far = Self.held([SubjectTrackBox(x0: 0.56, y0: 0.5, x1: 0.56 + 5.0 / 256, y1: 0.5 + 5.0 / 256)],
                            person: SubjectTrackBox(x0: 0.5, y0: 0.4, x1: 0.56, y1: 0.6))
        #expect(SubjectTrackRules.heldPiece(seen: far.seen, answer: far.answer, size: 256) != nil)
    }

    @Test func aPieceOfAnotherPersonIsNoHeldPiece() throws {
        // The arm of a second person reaching in next to the phone: Vision's person mask has it, not the phone.
        let phone = SubjectTrackBox(x0: 0.6, y0: 0.45, x1: 0.64, y1: 0.53)
        let arm = SubjectTrackBox(x0: 0.6, y0: 0.6, x1: 0.68, y1: 0.66)
        let (answer, seen) = Self.held([phone, arm])
        #expect(SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256).count == 2)
        let others = Self.logits(SubjectTrackBox(x0: 0.6, y0: 0.58, x1: 0.9, y1: 0.9), size: 256)
        let pieces = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256, others: others)
        #expect(pieces.count == 1)
        let box = try #require(pieces.first.flatMap { SubjectTrackRules.stats(logits: $0, size: 256).box })
        #expect(abs(box.y0 - 0.45) < 0.01, "\(box)")
        // A piece that only touches the other person is theirs too.
        let beside = Self.logits(SubjectTrackBox(x0: 0.685, y0: 0.58, x1: 0.9, y1: 0.9), size: 256)
        #expect(SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256, others: beside).count == 1)
    }

    @Test func aGapTheAnswerSurroundsIsNoHeldPiece() throws {
        // The background between an arm and the body, filled in by the segmentation: the answer is all around it.
        let phone = SubjectTrackBox(x0: 0.6, y0: 0.45, x1: 0.64, y1: 0.53)
        var (answer, seen) = Self.held([phone])
        for (i, v) in Self.logits(SubjectTrackBox(x0: 0.48, y0: 0.4, x1: 0.52, y1: 0.46), size: 256).enumerated() where v > 0 {
            answer[i] = -SubjectTrackRules.matteLogit
        }
        // Open to one side (a notch in the outline) it is still mostly surrounded.
        for (i, v) in Self.logits(SubjectTrackBox(x0: 0.4, y0: 0.6, x1: 0.44, y1: 0.64), size: 256).enumerated() where v > 0 {
            answer[i] = -SubjectTrackRules.matteLogit
        }
        let pieces = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256)
        #expect(pieces.count == 1)
        let box = try #require(pieces.first.flatMap { SubjectTrackRules.stats(logits: $0, size: 256).box })
        #expect(abs(box.y0 - 0.45) < 0.01, "\(box)")
    }

    @Test func aLimbOfThePickedPersonTheAnswerLeftOutIsAHeldPieceThoughTheAnswerSurroundsIt() throws {
        // The maintainer's clip (2026-10-19): the forearm, hand and phone held up in front of the body; the model's answer to
        // the person's box leaves them out and lies along most of their outline (0.83), like a gap.
        var (answer, seen) = Self.held([])
        for (i, v) in Self.logits(SubjectTrackBox(x0: 0.4, y0: 0.4, x1: 0.56, y1: 0.5), size: 256).enumerated() where v > 0 {
            answer[i] = -SubjectTrackRules.matteLogit
        }
        #expect(SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256).isEmpty)
        // Vision's person mask of the picked person holds it: the person's own limb, not a gap.
        let own = Self.logits(SubjectTrackBox(x0: 0.39, y0: 0.19, x1: 0.61, y1: 0.81), size: 256)
        let pieces = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256, own: own)
        #expect(pieces.count == 1)
        let box = try #require(pieces.first.flatMap { SubjectTrackRules.stats(logits: $0, size: 256).box })
        #expect(abs(box.x0 - 0.4) < 0.01 && abs(box.y0 - 0.4) < 0.01 && abs(box.x1 - 0.56) < 0.01, "\(box)")
        // A gap the person mask leaves out stays out.
        var gapless = own
        for (i, v) in Self.logits(SubjectTrackBox(x0: 0.4, y0: 0.4, x1: 0.56, y1: 0.5), size: 256).enumerated() where v > 0 {
            gapless[i] = -SubjectTrackRules.matteLogit
        }
        #expect(SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256, own: gapless).isEmpty)
        // Holes inside the person that the coarse person mask covers are no limb: one the answer surrounds all around
        // (it does not reach the outline), and a small one open to the side (walking on the mask bench: 31-55 pixels).
        var holes = Self.held([])
        for box in [SubjectTrackBox(x0: 0.45, y0: 0.3, x1: 0.55, y1: 0.36), SubjectTrackBox(x0: 0.4, y0: 0.6, x1: 0.42, y1: 0.63)] {
            for (i, v) in Self.logits(box, size: 256).enumerated() where v > 0 { holes.answer[i] = -SubjectTrackRules.matteLogit }
        }
        #expect(SubjectTrackRules.heldPieces(seen: holes.seen, answer: holes.answer, size: 256, own: own).isEmpty)
    }

    @Test func heldPiecesAreCheapEnoughForThePick() {
        // It runs on the frame lane, whose watchdog gives up after 0.5 s in the tests: a person a third of the grid
        // with a phone and specks all along their outline, in this (unoptimized Debug) build.
        let phone = SubjectTrackBox(x0: 0.6, y0: 0.45, x1: 0.64, y1: 0.53)
        let specks = (0..<40).map { k in SubjectTrackBox(x0: 0.36, y0: 0.2 + Double(k) * 0.015, x1: 0.4, y1: 0.21 + Double(k) * 0.015) }
        let (answer, seen) = Self.held([phone] + specks)
        let others = Self.logits(SubjectTrackBox(x0: 0.7, y0: 0.2, x1: 0.95, y1: 0.9), size: 256)
        let began = Date()
        for _ in 0..<5 { _ = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256, others: others) }
        let ms = Date().timeIntervalSince(began) * 1000 / 5
        print("PERF heldPieces 256x256: \(ms) ms")
        #expect(ms < 60, "\(ms) ms")
    }

    @Test func aLongStripIsNoHeldPiece() throws {
        // A leg of someone behind the person, seen as a long strip along them; the phone stays.
        let phone = SubjectTrackBox(x0: 0.6, y0: 0.45, x1: 0.64, y1: 0.53)
        let strip = SubjectTrackBox(x0: 0.6, y0: 0.2, x1: 0.616, y1: 0.4)
        let (answer, seen) = Self.held([phone, strip])
        let pieces = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: 256)
        #expect(pieces.count == 1)
        let box = try #require(pieces.first.flatMap { SubjectTrackRules.stats(logits: $0, size: 256).box })
        #expect(abs(box.y0 - 0.45) < 0.01, "\(box)")
    }

    @Test func theModelsAnswerForAHeldPieceIsKeptNearThePieceAndJoinsTheAnswer() throws {
        let phone = SubjectTrackBox(x0: 0.6, y0: 0.45, x1: 0.64, y1: 0.53)
        let (answer, seen) = Self.held([phone])
        let piece = try #require(SubjectTrackRules.heldPiece(seen: seen, answer: answer, size: 256))
        // The model's answer for the piece: the phone and a stray blob far off.
        var object = Self.logits(SubjectTrackBox(x0: 0.6, y0: 0.44, x1: 0.645, y1: 0.54), size: 256)
        for (i, v) in Self.logits(SubjectTrackBox(x0: 0.05, y0: 0.05, x1: 0.15, y1: 0.15), size: 256).enumerated() where v > 0 { object[i] = v }
        let joined = try #require(SubjectTrackRules.withHeld(answer: answer, object: object, piece: piece, size: 256))
        let box = try #require(SubjectTrackRules.stats(logits: joined, size: 256).box)
        #expect(abs(box.x0 - 0.4) < 0.01 && abs(box.x1 - 0.645) < 0.01 && box.y0 > 0.19, "\(box)")
        // An answer that is not the piece (the whole person again, or nothing there) is not taken.
        #expect(SubjectTrackRules.withHeld(answer: answer, object: answer, piece: piece, size: 256) == nil)
        let empty = [Float](repeating: -8, count: 256 * 256)
        #expect(SubjectTrackRules.withHeld(answer: answer, object: empty, piece: piece, size: 256) == nil)
    }

    @Test func clickBoxIsPersonSizedCenteredOnTheClickAndInsideThePersonBox() {
        let person = SubjectTrackBox(x0: 0.3, y0: 0.1, x1: 0.7, y1: 0.9)
        let box = SubjectTrackRules.clickBox(click: Vec2(0.4, 0.5), person: person)
        #expect(abs(box.height - 0.8 * SubjectTrackRules.clickBoxHeight) < 1e-9)
        #expect(abs(box.width - box.height * SubjectTrackRules.clickBoxAspect) < 1e-9)
        #expect(abs((box.x0 + box.x1) / 2 - 0.4) < 1e-9)
        // A click near the edge keeps the box inside the person box.
        let edge = SubjectTrackRules.clickBox(click: Vec2(0.31, 0.12), person: person)
        #expect(edge.x0 >= person.x0 && edge.y0 >= person.y0 && edge.x1 <= person.x1 && edge.y1 <= person.y1)
    }

    @Test func twoTouchingPeopleAreToldFromOneWidePerson() {
        let one = SubjectTrackBox(x0: 0.47, y0: 0.12, x1: 0.6, y1: 0.83)
        let other = SubjectTrackBox(x0: 0.34, y0: 0.12, x1: 0.47, y1: 0.8)
        let size = 64
        let seen = Self.logits(SubjectTrackBox(x0: 0.34, y0: 0.12, x1: 0.6, y1: 0.83))
        // Another person, apart from the first, as large, and the two fill the blob: the blob held two.
        #expect(SubjectTrackRules.holdsSeveralPeople(first: Self.logits(one), second: Self.logits(other), seen: seen, size: size))
        // The same person again: one subject.
        #expect(!SubjectTrackRules.holdsSeveralPeople(first: Self.logits(one), second: Self.logits(one), seen: seen, size: size))
        // Two separate masks that leave most of the blob out (limbs of one subject): no verdict.
        let wide = Self.logits(SubjectTrackBox(x0: 0.1, y0: 0.12, x1: 0.6, y1: 0.83))
        #expect(!SubjectTrackRules.holdsSeveralPeople(first: Self.logits(one), second: Self.logits(other), seen: wide, size: size))
        // A scrap elsewhere is no second person.
        let scrap = SubjectTrackBox(x0: 0.34, y0: 0.12, x1: 0.37, y1: 0.2)
        #expect(!SubjectTrackRules.holdsSeveralPeople(first: Self.logits(one), second: Self.logits(scrap), seen: seen, size: size))
        // Empty answers decide nothing.
        #expect(!SubjectTrackRules.holdsSeveralPeople(first: Self.logits(one), second: [Float](repeating: -8, count: size * size), seen: seen, size: size))
    }

    @Test func piecesBoxKeepsAHeadAndATorsoSplitByAnOccluderButNotSpecks() throws {
        let head = SubjectTrackBox(x0: 0.4, y0: 0.1, x1: 0.5, y1: 0.25)
        let torso = SubjectTrackBox(x0: 0.38, y0: 0.45, x1: 0.52, y1: 0.9)
        let speck = SubjectTrackBox(x0: 0.9, y0: 0.05, x1: 0.91, y1: 0.06)
        let m = Self.matte([head, torso, speck])
        let box = try #require(SubjectTrackRules.piecesBox(in: m, at: Vec2(0.45, 0.17)))
        #expect(abs(box.y0 - 0.1) < 0.02 && abs(box.y1 - 0.9) < 0.02 && abs(box.x1 - 0.52) < 0.02)
        #expect(box.x1 < 0.6)
        #expect(SubjectTrackRules.piecesBox(in: Self.matte([]), at: Vec2(0.5, 0.5)) == nil)
    }

    @Test func leftoverIsWhatTheFirstMaskMissedInsideTheBox() {
        let size = 64
        let seen = Self.logits(SubjectTrackBox(x0: 0.1, y0: 0.1, x1: 0.9, y1: 0.9), size: size)
        let first = Self.logits(SubjectTrackBox(x0: 0.1, y0: 0.1, x1: 0.4, y1: 0.9), size: size)
        let box = SubjectTrackBox(x0: 0.0, y0: 0.0, x1: 0.6, y1: 1.0)
        let rest = SubjectTrackRules.leftover(seen: seen, first: first, within: box, size: size)
        for y in 0..<size { for x in 0..<size where rest[y * size + x] > 0 {
            let u = (Double(x) + 0.5) / Double(size)
            #expect(u > 0.4 && u <= 0.6)
        } }
        #expect(rest.contains { $0 > 0 })
    }
}
