import Foundation
import Testing
@testable import SQCore

/// A click on a tracked frame refines the tracked mask, never swaps it for another one
/// (docs/research/mask-tracking/BENCH-MIDCLIP.md).
@Suite struct SubjectCorrectionRuleTests {
    static let size = 64
    static func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Float] {
        SubjectTrackRulesTests.logits(SubjectTrackBox(x0: x0, y0: y0, x1: x1, y1: y1), size: size)
    }
    static func add(_ x: Double, _ y: Double) -> MagicPoint { MagicPoint(position: Vec2(x, y), subtract: false, sourceTime: Time(0, 1)) }
    static func remove(_ x: Double, _ y: Double) -> MagicPoint { MagicPoint(position: Vec2(x, y), subtract: true, sourceTime: Time(0, 1)) }

    @Test func aMaskAnswersAddedPointsOnItAndRemovedPointsOffIt() {
        let tracked = Self.box(0.2, 0.2, 0.6, 0.6)
        #expect(SubjectCorrectionRule.answers([Self.add(0.4, 0.4)], logits: tracked, size: Self.size))
        #expect(!SubjectCorrectionRule.answers([Self.add(0.8, 0.8)], logits: tracked, size: Self.size))
        #expect(SubjectCorrectionRule.answers([Self.remove(0.8, 0.8)], logits: tracked, size: Self.size))
        #expect(!SubjectCorrectionRule.answers([Self.remove(0.4, 0.4), Self.add(0.3, 0.3)], logits: tracked, size: Self.size))
        #expect(!SubjectCorrectionRule.answers([], logits: tracked, size: Self.size))
    }

    @Test func aMatteAnswersTheSameWayAtItsOwnSize() {
        var values = [Float](repeating: 0, count: 10 * 10)
        for y in 2..<6 { for x in 2..<6 { values[y * 10 + x] = 1 } }
        let m = SubjectMatte(width: 10, height: 10, values: values)
        #expect(SubjectCorrectionRule.answers([Self.add(0.35, 0.35), Self.remove(0.9, 0.1)], matte: m))
        #expect(!SubjectCorrectionRule.answers([Self.add(0.75, 0.75)], matte: m))
    }

    @Test func anAddedClickTakesTheCandidateThatGrowsTheTrackedMaskLeast() {
        let tracked = Self.box(0.2, 0.2, 0.5, 0.6)
        let candidates = [
            Self.box(0.6, 0.3, 0.9, 0.9),   // another object under the click: drops the tracked mask
            Self.box(0.0, 0.0, 1.0, 1.0),   // the whole frame: grows far too much
            Self.box(0.2, 0.2, 0.75, 0.6),  // the tracked mask with the missing part
            Self.box(0.2, 0.2, 0.5, 0.6),   // the tracked mask itself: does not hold the click
        ]
        #expect(SubjectCorrectionRule.refinement(candidates, tracked: tracked, points: [Self.add(0.7, 0.4)], size: Self.size) == 2)
    }

    @Test func aRemovedClickTakesACandidateInsideTheTrackedMask() {
        let tracked = Self.box(0.1, 0.1, 0.9, 0.5)
        let candidates = [
            Self.box(0.6, 0.6, 0.9, 0.9),   // off the tracked mask
            Self.box(0.1, 0.1, 0.5, 0.5),   // the tracked mask without its right half
        ]
        #expect(SubjectCorrectionRule.refinement(candidates, tracked: tracked, points: [Self.remove(0.8, 0.3)], size: Self.size) == 1)
        // A cut that leaves almost nothing is no refinement.
        #expect(SubjectCorrectionRule.refinement([Self.box(0.1, 0.1, 0.15, 0.15)], tracked: tracked, points: [Self.remove(0.8, 0.3)], size: Self.size) == nil)
    }

    @Test func noCandidateThatRefinesIsNil() {
        let tracked = Self.box(0.2, 0.2, 0.5, 0.6)
        #expect(SubjectCorrectionRule.refinement([Self.box(0.6, 0.6, 0.9, 0.9)], tracked: tracked, points: [Self.add(0.7, 0.7)], size: Self.size) == nil)
        #expect(SubjectCorrectionRule.refinement([], tracked: tracked, points: [Self.add(0.7, 0.7)], size: Self.size) == nil)
    }

    @Test func aLostFrameTakesTheFirstCandidateThatAnswersTheClick() {
        let empty = [Float](repeating: -8, count: Self.size * Self.size)
        let candidates = [Self.box(0.0, 0.0, 0.2, 0.2), Self.box(0.6, 0.6, 0.9, 0.9), Self.box(0.5, 0.5, 1.0, 1.0)]
        #expect(SubjectCorrectionRule.refinement(candidates, tracked: empty, points: [Self.add(0.7, 0.7)], size: Self.size) == 1)
    }
}
