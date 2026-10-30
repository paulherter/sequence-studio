import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct TextAnimatorTimingTests {
    func anim(_ effect: TextAnimatorEffect = .fade, unit: TextAnimatorUnit = .word, order: TextAnimatorOrder = .forward,
              duration: Time = Time(1, 5), stagger: Time = Time(1, 10), easing: SegmentShape = .linear) -> TextAnimator {
        TextAnimator(effect: effect, unit: unit, order: order, easing: easing, duration: duration, stagger: stagger)
    }

    @Test func forwardStaggerStartsAreExactMultiples() {
        let a = anim()
        #expect(a.start(ofUnit: 0, count: 3) == .zero)
        #expect(a.start(ofUnit: 1, count: 3) == Time(1, 10))
        #expect(a.start(ofUnit: 2, count: 3) == Time(1, 5))
        #expect(a.totalDuration(count: 3) == Time(2, 5))
        #expect(a.totalDuration(count: 1) == Time(1, 5))
        #expect(a.totalDuration(count: 0) == .zero)
    }

    @Test func ntscStaggerDoesNotDrift() {
        let a = anim(stagger: Time(1001, 30000))
        // 1000 units: the last one starts exactly 1000 - 1 NTSC frames in.
        #expect(a.start(ofUnit: 999, count: 1000) == Time(999 * 1001, 30000))
        #expect(a.totalDuration(count: 1000) == Time(999 * 1001, 30000) + Time(1, 5))
    }

    @Test func reverseAndCenterOrders() {
        let r = anim(order: .reverse)
        #expect(r.start(ofUnit: 0, count: 3) == Time(1, 5))
        #expect(r.start(ofUnit: 2, count: 3) == .zero)
        let c = anim(order: .center)
        // 5 units: middle first, then its neighbors, edges last.
        #expect((0..<5).map { c.rank(ofUnit: $0, count: 5) } == [2, 1, 0, 1, 2])
        // 4 units: the two middle ones together.
        #expect((0..<4).map { c.rank(ofUnit: $0, count: 4) } == [1, 0, 0, 1])
        #expect(c.totalDuration(count: 5) == Time(2, 10) + Time(1, 5))
    }

    @Test func progressBoundariesAreExact() {
        let a = anim()
        // Unit 1: starts at 1/10, ends at 3/10.
        #expect(a.progress(ofUnit: 1, count: 3, at: Time(1, 10)) == 0)
        #expect(a.progress(ofUnit: 1, count: 3, at: Time(1, 20)) == 0)
        #expect(a.progress(ofUnit: 1, count: 3, at: Time(2, 10)) == 0.5)
        #expect(a.progress(ofUnit: 1, count: 3, at: Time(3, 10)) == 1)
        #expect(a.progress(ofUnit: 1, count: 3, at: Time(5, 1)) == 1)
    }

    @Test func typewriterIsAStepAtTheUnitStart() {
        let a = anim(.typewriter, unit: .character, duration: Time(1, 5), stagger: Time(1, 30))
        // Unit 2 appears exactly at frame 2 (1/30 s per frame).
        #expect(a.progress(ofUnit: 2, count: 5, at: Time(2, 30)) == 1)
        #expect(a.progress(ofUnit: 2, count: 5, at: Time(59, 900)) == 0)
        #expect(a.inState(ofUnit: 3, count: 5, at: Time(2, 30)).opacity == 0)
        #expect(a.inState(ofUnit: 2, count: 5, at: Time(2, 30)) == .rest)
    }

    @Test func zeroDurationIsAStep() {
        let a = anim(duration: .zero, stagger: Time(1, 10))
        #expect(a.progress(ofUnit: 1, count: 2, at: Time(1, 10)) == 1)
        #expect(a.progress(ofUnit: 1, count: 2, at: Time(1, 11)) == 0)
    }

    @Test func typewriterOutEndsExactlyAtClipEnd() {
        // Duration is ignored by typewriter, so it must not push the out side earlier.
        let a = anim(.typewriter, unit: .character, duration: Time(1, 2), stagger: Time(1, 10))
        #expect(a.totalDuration(count: 3) == Time(1, 5))
        let clip = Time(3, 1)
        #expect(a.outState(ofUnit: 2, count: 3, clipTime: Time(299, 100), clipDuration: clip) == .rest)
        #expect(a.outState(ofUnit: 2, count: 3, clipTime: clip, clipDuration: clip).opacity == 0)
        #expect(a.outStart(ofUnit: 0, count: 3, clipDuration: clip) == Time(14, 5))
    }

    @Test func hugeTimesAreClampedAndNeverTrap() {
        let a = TextAnimator(effect: .fade, unit: .word, duration: Time(Int64.max / 2, 1), stagger: Time(Int64.max / 3, Int64.max / 2))
        #expect(a.duration == TextAnimator.maxTime && a.stagger <= TextAnimator.maxTime)
        #expect(a.start(ofUnit: 999_999, count: 1_000_000) > .zero)
        _ = a.totalDuration(count: 1_000_000)
        _ = a.outState(ofUnit: 3, count: 1_000_000, clipTime: Time(1, 1), clipDuration: Time(10, 1))
        // Unreduced fractions with huge timescales are moved onto a microsecond grid, so rank * stagger cannot overflow.
        let b = TextAnimator(effect: .fade, unit: .word, duration: .zero, stagger: Time(Int64.max / 4 - 1, Int64.max / 2))
        #expect(b.stagger.timescale <= 1_000_000)
        _ = b.start(ofUnit: 1_000_000_000, count: 1_000_000_001)
        // Decoding clamps too.
        let json = #"{"effect":"fade","unit":"word","duration":{"value":-5,"timescale":1},"stagger":{"value":9000,"timescale":1}}"#
        let d = try! JSONDecoder().decode(TextAnimator.self, from: Data(json.utf8))
        #expect(d.duration == .zero && d.stagger == TextAnimator.maxTime)
    }

    @Test func outAnimatorEndsAtClipEnd() {
        let a = anim()
        let clip = Time(3, 1)
        // Total 2/5: unit 0 leaves from 3 - 2/5, unit 2 is gone exactly at the clip end.
        #expect(a.outStart(ofUnit: 0, count: 3, clipDuration: clip) == Time(13, 5))
        #expect(a.outState(ofUnit: 2, count: 3, clipTime: Time(3, 1), clipDuration: clip).opacity == 0)
        #expect(a.outState(ofUnit: 2, count: 3, clipTime: Time(14, 5), clipDuration: clip) == .rest)
        #expect(a.outState(ofUnit: 0, count: 3, clipTime: Time(28, 10), clipDuration: clip).opacity == 0)
        #expect(a.outState(ofUnit: 1, count: 3, clipTime: Time(28, 10), clipDuration: clip).opacity == 0.5)
    }

    @Test func effectStates() {
        let half = Time(1, 10)   // half of the 1/5 unit duration
        let fade = anim(.fade).inState(ofUnit: 0, count: 1, at: half)
        #expect(fade.opacity == 0.5 && fade.scale == 1 && fade.offsetY == 0 && fade.blur == 0)
        var slide = anim(.slide); slide.distance = 40; slide.direction = .up
        #expect(slide.inState(ofUnit: 0, count: 1, at: .zero).offsetY == 40)
        #expect(slide.inState(ofUnit: 0, count: 1, at: half).offsetY == 20)
        slide.direction = .left
        #expect(slide.inState(ofUnit: 0, count: 1, at: .zero).offsetX == 40)
        let pop = anim(.pop).inState(ofUnit: 0, count: 1, at: .zero)
        #expect(pop.scale == 0 && pop.opacity == 0)
        var blur = anim(.blur); blur.blurRadius = 12
        #expect(blur.inState(ofUnit: 0, count: 1, at: .zero).blur == 12)
        #expect(blur.inState(ofUnit: 0, count: 1, at: half).blur == 6)
        #expect(blur.inState(ofUnit: 0, count: 1, at: Time(1, 5)) == .rest)
    }

    @Test func overshootEasingPassesTheEnd() {
        let pop = anim(.pop, easing: .overshoot)
        let peak = (1..<20).map { pop.inState(ofUnit: 0, count: 1, at: Time(Int64($0), 100)).scale }.max()!
        #expect(peak > 1.05)
        #expect(pop.inState(ofUnit: 0, count: 1, at: Time(1, 5)) == .rest)
    }

    @Test func easingShapes() {
        #expect(TextAnimator.ease(0.5, .linear) == 0.5)
        #expect(TextAnimator.ease(0.5, .easeIn) < 0.5)
        #expect(TextAnimator.ease(0.5, .easeOut) > 0.5)
        #expect(abs(TextAnimator.ease(0.5, .easeInOut) - 0.5) < 1e-9)
        #expect(TextAnimator.ease(0, .easeInOut) == 0 && TextAnimator.ease(1, .easeInOut) == 1)
    }
}

@Suite struct TextUnitsTests {
    @Test func segmentsCharactersWordsLines() {
        // Two lines: "Hi you" (0..<6) and "go" (7..<9) after a newline.
        let u = TextUnits.segment(text: "Hi you\ngo", lines: [NSRange(location: 0, length: 6), NSRange(location: 7, length: 2)])
        #expect(u.characters.count == 7)          // whitespace is no unit
        #expect(u.characters.map(\.word) == [0, 0, 1, 1, 1, 2, 2])
        #expect(u.characters.map(\.line) == [0, 0, 0, 0, 0, 1, 1])
        #expect(u.characters.map(\.index) == Array(0..<7))
        #expect(u.wordCount == 3 && u.lineCount == 2)
        #expect(u.count(of: .character) == 7 && u.count(of: .word) == 3 && u.count(of: .line) == 2)
        #expect(u.characters[2].range == NSRange(location: 3, length: 1))
    }

    @Test func graphemeClustersAreOneCharacter() {
        let u = TextUnits.segment(text: "é👍🏽", lines: [NSRange(location: 0, length: ("é👍🏽" as NSString).length)])
        #expect(u.characters.count == 2)
    }
}

@Suite struct TextAnimatorSetTests {
    let units = TextUnits.segment(text: "ab cd", lines: [NSRange(location: 0, length: 5)])

    @Test func noAnimatorGivesNil() {
        #expect(AnimationSet(in: nil, out: nil).characterStates(units: units, clipTime: .zero, clipDuration: Time(2, 1)) == nil)
        let plain = KeyframeTemplate(tracks: [], duration: Time(1, 2))
        #expect(AnimationSet(in: plain, out: nil).characterStates(units: units, clipTime: .zero, clipDuration: Time(2, 1)) == nil)
    }

    @Test func inByWordOutByCharacterCompose() {
        let inA = TextAnimator(effect: .typewriter, unit: .word, duration: .zero, stagger: Time(1, 2))
        let outA = TextAnimator(effect: .fade, unit: .character, easing: .linear, duration: Time(1, 10), stagger: .zero)
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: inA), out: KeyframeTemplate(textAnimator: outA))
        let clip = Time(2, 1)
        let s0 = set.characterStates(units: units, clipTime: Time(1, 4), clipDuration: clip)!
        #expect(s0.map(\.opacity) == [1, 1, 0, 0])
        let s1 = set.characterStates(units: units, clipTime: Time(1, 1), clipDuration: clip)!
        #expect(s1.allSatisfy { $0.isRest })
        let s2 = set.characterStates(units: units, clipTime: Time(39, 20), clipDuration: clip)!
        #expect(s2.allSatisfy { $0.opacity == 0.5 })
        #expect(s2[0].outUnit == .character && s0[0].inUnit == .word)
    }

    @Test func templateCodableKeepsOldShapeWithoutAnimator() throws {
        let plain = KeyframeTemplate(tracks: [], duration: Time(1, 2))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("textAnimator"))
        var withA = plain
        withA.textAnimator = TextAnimator(effect: .slide, unit: .line, order: .center, easing: .easeOut,
                                          duration: Time(1, 3), stagger: Time(1001, 30000), distance: 25, direction: .down,
                                          blurRadius: 4)
        let back = try JSONDecoder().decode(KeyframeTemplate.self, from: try JSONEncoder().encode(withA))
        #expect(back == withA)
        // A minimal animator (only the required keys) reads with defaults.
        let min = #"{"effect":"fade","unit":"word","duration":{"value":1,"timescale":5},"stagger":{"value":1,"timescale":10}}"#
        let a = try JSONDecoder().decode(TextAnimator.self, from: Data(min.utf8))
        #expect(a.order == .forward && a.easing == .easeOut && a.direction == .up)
    }
}
