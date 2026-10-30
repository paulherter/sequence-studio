import Foundation
import Testing
@testable import SQCore

@Suite struct SubjectCropPassTests {
    static func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SubjectTrackBox { SubjectTrackBox(x0: x0, y0: y0, x1: x1, y1: y1) }

    // MARK: Crop rectangle

    @Test func aSmallSubjectGetsACropAroundItWithMargin() throws {
        let crop = try #require(SubjectCropPass.crop(around: Self.box(0.4, 0.3, 0.5, 0.6), aspect: 16.0 / 9))
        #expect(crop.x0 < 0.4 && crop.x1 > 0.5 && crop.y0 < 0.3 && crop.y1 > 0.6)
        #expect(crop.x0 >= 0 && crop.y0 >= 0 && crop.x1 <= 1 && crop.y1 <= 1)
    }

    @Test func aTallNarrowSubjectIsWidenedToACropThatIsNotAStrip() throws {
        let crop = try #require(SubjectCropPass.crop(around: Self.box(0.45, 0.1, 0.55, 0.8), aspect: 16.0 / 9))
        let pixelAspect = crop.width * 16.0 / 9 / crop.height   // width / height in px of a 16:9 frame
        #expect(pixelAspect >= SubjectCropPass.minAspect - 1e-9)
        #expect(crop.x0 < 0.45 && crop.x1 > 0.55)
    }

    @Test func aSubjectThatFillsTheFrameNeedsNoCrop() {
        #expect(SubjectCropPass.crop(around: Self.box(0.1, 0.05, 0.9, 0.95), aspect: 16.0 / 9) == nil)
    }

    @Test func aCropNearTheEdgeShiftsInsideTheFrame() throws {
        let crop = try #require(SubjectCropPass.crop(around: Self.box(0.0, 0.2, 0.08, 0.5), aspect: 16.0 / 9))
        #expect(crop.x0 >= 0 && crop.x1 <= 1 && crop.x0 == 0)
        #expect(crop.x1 > 0.08)
    }

    // MARK: Composing the crop's answer into the frame

    @Test func theCropsLogitsReplaceTheFrameInsideTheCropOnly() {
        let size = 8
        let crop = Self.box(0.25, 0.25, 0.75, 0.75)
        let base = SubjectMatte(width: 16, height: 16, values: [Float](repeating: 0.2, count: 256))
        let inside = [Float](repeating: 10, count: size * size)
        let out = SubjectCropPass.compose(base: base, cropLogits: inside, size: size, crop: crop)
        let onGrid = SubjectCropPass.merged(frame: [Float](repeating: -8, count: 16 * 16), side: 16, cropLogits: inside, size: size, crop: crop)
        #expect(onGrid[8 * 16 + 8] == 10 && onGrid[0] == -8)
        #expect(out[8, 8] > 0.99)        // in the crop
        #expect(out[0, 0] == 0.2)        // outside: as the base
        #expect(out[15, 15] == 0.2)
    }

    @Test func aCropAnswerAgreesWithTheFrameAnswerOrIsNotUsed() {
        let a = SubjectTrackRulesTests.logits(Self.box(0.3, 0.3, 0.6, 0.9))
        let b = SubjectTrackRulesTests.logits(Self.box(0.31, 0.3, 0.6, 0.9))
        let c = SubjectTrackRulesTests.logits(Self.box(0.0, 0.0, 0.2, 0.2))
        #expect(SubjectCropPass.accepts(crop: b, frame: a))
        #expect(!SubjectCropPass.accepts(crop: c, frame: a))
        #expect(!SubjectCropPass.accepts(crop: [Float](repeating: -8, count: a.count), frame: a))
    }

    // MARK: Search band

    @Test func logitsFarFromThePreviousBoxAreCutOffNearOnesStay() {
        let size = 64
        var logits = [Float](repeating: -8, count: size * size)
        func set(_ x: Int, _ y: Int) { logits[y * size + x] = 8 }
        set(32, 32)   // inside the previous box
        set(60, 4)    // far corner
        let cut = SubjectCropPass.constrain(logits, size: size, to: Self.box(0.4, 0.4, 0.6, 0.6))
        #expect(cut[32 * size + 32] == 8)
        #expect(cut[4 * size + 60] < 0)
        #expect(cut[4 * size + 60] == -SubjectTrackRules.matteLogit)
    }

    @Test func theBandGrowsWithTheBoxDiagonal() {
        let a = Self.box(0.45, 0.45, 0.5, 0.5), b = Self.box(0.2, 0.2, 0.8, 0.8)
        let small = SubjectCropPass.band(around: a), big = SubjectCropPass.band(around: b)
        #expect(small.x0 < a.x0 && big.x0 < b.x0)
        #expect(b.x0 - big.x0 > a.x0 - small.x0)
    }

    // MARK: Lost rule: tiny masks and a subject leaving the frame

    @Test func aMaskUnder49LogitPixelsIsLostWhatEverItsUsualArea() {
        var rule = SubjectLostRule()
        let tiny = 40.0 / 65536
        let tinyLost = rule.isLost(area: tiny, box: Self.box(0.5, 0.5, 0.51, 0.51))
        #expect(tinyLost)
        // A small subject that is small all along stays found.
        var small = SubjectLostRule()
        for _ in 0..<6 { let l = small.isLost(area: 100.0 / 65536, box: Self.box(0.48, 0.48, 0.52, 0.52)); #expect(!l) }
    }

    @Test func aSubjectThatLeavesThroughTheEdgeKeepsItsShrinkingMask() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.1, box: Self.box(0.7, 0.2, 1.0, 1.0)); #expect(!l) }
        // Half out, a tenth out, still touching the right edge: found, not lost.
        do { let l = rule.isLost(area: 0.04, box: Self.box(0.85, 0.2, 1.0, 1.0)); #expect(!l) }
        do { let l = rule.isLost(area: 0.01, box: Self.box(0.95, 0.2, 1.0, 1.0)); #expect(!l) }
    }

    @Test func aCollapseInTheMiddleOfTheFrameIsStillLost() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.1, box: Self.box(0.35, 0.35, 0.65, 0.65)); #expect(!l) }
        do { let l = rule.isLost(area: 0.01, box: Self.box(0.45, 0.45, 0.55, 0.55)); #expect(l) }
    }

    @Test func theBandWidensWithEveryLostFrameUntilItCoversTheFrame() {
        let a = Self.box(0.1, 0.5, 0.2, 0.6)
        let w0 = SubjectCropPass.band(around: a).x1, w3 = SubjectCropPass.band(around: a, lostFrames: 3).x1
        #expect(w3 > w0)
        let far = SubjectCropPass.band(around: a, lostFrames: 10)
        #expect(far.x0 <= 0 && far.x1 >= 1 && far.y0 <= 0 && far.y1 >= 1)
    }

    @Test func aSubjectAtTheEdgeThatOnlyCollapsesInPlaceIsLost() {
        var rule = SubjectLostRule()
        for _ in 0..<5 { let l = rule.isLost(area: 0.1, box: Self.box(0.7, 0.2, 1.0, 1.0)); #expect(!l) }
        // Same box center, far smaller mask, both touching the right edge: no movement toward the edge.
        let l = rule.isLost(area: 0.01, box: Self.box(0.7, 0.2, 1.0, 0.3))
        #expect(l)
    }

    @Test func aTinyMaskIsLostEvenAtTheEdgeAndAfterNoHistory() {
        var rule = SubjectLostRule()
        let l = rule.isLost(area: 10.0 / 65536, box: Self.box(0.99, 0.5, 1.0, 0.51))
        #expect(l)
    }

    @Test func theCropKeepsItsAspectBoundWhenTheFrameClampsIt() throws {
        // A wide box nearly the frame's width and short: widening the height would pass 1.
        let c = SubjectCropPass.crop(around: Self.box(0.0, 0.45, 1.0, 0.55), aspect: 1.78)
        if let c { #expect(c.width * 1.78 / c.height >= SubjectCropPass.minAspect - 1e-9 && c.width * 1.78 / c.height <= 1 / SubjectCropPass.minAspect + 1e-9) }
    }
}
