import Foundation
import Testing
@testable import SQCore

// Magic mask sanity: an empty (all-zero) or missing matte never blacks out the picture.

struct MagicMatteSanityTests {
    func matte(_ w: Int, _ h: Int, _ f: (Int, Int) -> Float) -> SubjectMatte {
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { v[y * w + x] = f(x, y) } }
        return SubjectMatte(width: w, height: h, values: v)
    }

    @Test func blankMattes() {
        #expect(matte(8, 4) { _, _ in 0 }.isBlank)
        #expect(matte(8, 4) { _, _ in 0.001 }.isBlank)          // below one 8-bit step: stores as zero
        #expect(!matte(8, 4) { x, y in x == 3 && y == 2 ? 1 : 0 }.isBlank)
        #expect(!matte(8, 4) { _, _ in 1 }.isBlank)
    }

    @Test func softMatteFallsBackToTheHardLabels() {
        var l = [UInt8](repeating: 0, count: 10 * 10)
        for y in 2..<6 { for x in 2..<6 { l[y * 10 + x] = 3 } }
        let labels = InstanceLabels(width: 10, height: 10, labels: l)
        let hard = labels.matte(of: [3])
        let good = matte(10, 10) { x, y in (2..<6).contains(x) && (2..<6).contains(y) ? 0.9 : 0 }
        #expect(MagicPick.usableSoft(good, labels: labels, selected: [3]) == good)
        // Empty soft matte, wrong size, none at all: the hard labels.
        #expect(MagicPick.usableSoft(matte(10, 10) { _, _ in 0 }, labels: labels, selected: [3]) == hard)
        #expect(MagicPick.usableSoft(matte(5, 5) { _, _ in 1 }, labels: labels, selected: [3]) == hard)
        #expect(MagicPick.usableSoft(nil, labels: labels, selected: [3]) == hard)
        // A soft matte at the analyzed frame's size (finer than the labels) is taken as it is.
        let fine = matte(32, 18) { x, y in (6..<20).contains(x) && (4..<11).contains(y) ? 1 : 0 }
        #expect(MagicPick.usableSoft(fine, labels: labels, selected: [3], frameWidth: 32, frameHeight: 18) == fine)
        #expect(MagicPick.usableSoft(fine, labels: labels, selected: [3], frameWidth: 40, frameHeight: 18) == hard)
        #expect(MagicPick.usableSoft(matte(32, 18) { _, _ in 0 }, labels: labels, selected: [3], frameWidth: 32, frameHeight: 18) == hard)
    }

    @Test func untrackedOrBlankMagicMasksDoNotCutThePicture() {
        let a = UUID(), b = UUID(), c = UUID()
        let magicA = MaskShape(polygon: [], source: .magic, matteKey: a)
        let magicB = MaskShape(polygon: [], source: .magic, matteKey: b)
        let magicC = MaskShape(polygon: [], source: .magic, matteKey: c)
        let rect = MaskShape(polygon: [Vec2(0, 0), Vec2(0.5, 0), Vec2(0.5, 1), Vec2(0, 1)])
        let subject = MaskShape(polygon: [], source: .subject)
        let person = matte(4, 4) { x, _ in x < 2 ? 1 : 0 }
        let mattes: [UUID: SubjectMatte] = [a: person, b: matte(4, 4) { _, _ in 0 }]
        let kept = MaskCoverage.opacityMasks([magicA, magicB, magicC, rect, subject], mattes: mattes)
        #expect(kept == [magicA, rect, subject])
        // A lone Magic mask with no matte (picked on another frame, nothing found, not tracked here): picture stays.
        let frame = Vec2(100, 100)
        let alone = MaskCoverage.opacityMasks([magicC], mattes: mattes)
        #expect(MaskCoverage.coverage(at: Vec2(75, 50), masks: alone, frame: frame, pixel: 1, mattes: mattes) == 1)
        let blank = MaskCoverage.opacityMasks([magicB], mattes: mattes)
        #expect(MaskCoverage.coverage(at: Vec2(75, 50), masks: blank, frame: frame, pixel: 1, mattes: mattes) == 1)
        // A tracked matte still cuts.
        let tracked = MaskCoverage.opacityMasks([magicA], mattes: mattes)
        #expect(MaskCoverage.coverage(at: Vec2(75, 50), masks: tracked, frame: frame, pixel: 1, mattes: mattes) == 0)
        #expect(MaskCoverage.coverage(at: Vec2(25, 50), masks: tracked, frame: frame, pixel: 1, mattes: mattes) == 1)
    }
}
