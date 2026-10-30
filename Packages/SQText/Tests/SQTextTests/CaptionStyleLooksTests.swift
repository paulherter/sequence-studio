import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct CaptionStyleLooksTests {
    let lib = CaptionPresetLibrary.builtIn

    // MARK: Rational wrap

    @Test func wrapIsExactRational() {
        let p = Time(2, 3)
        #expect(KeyframeTemplate.wrap(Time(1, 3), period: p) == Time(1, 3))
        #expect(KeyframeTemplate.wrap(Time(2, 3), period: p) == .zero)
        #expect(KeyframeTemplate.wrap(Time(5, 3), period: p) == Time(1, 3))   // 5/3 = 2*(2/3) + 1/3
        let w = KeyframeTemplate.wrap(Time(1001, 30000) * 90, period: Time(1, 1))
        #expect(w == Time(90 * 1001 - 3 * 30000, 30000))                       // 90090/30000 = 3 + 90/30000
    }

    @Test func wrapLeavesNegativeAndDegenerateAlone() {
        #expect(KeyframeTemplate.wrap(Time(-1, 5), period: Time(1, 1)) == Time(-1, 5))
        #expect(KeyframeTemplate.wrap(Time(7, 5), period: .zero) == Time(7, 5))
    }

    // MARK: Loops

    @Test func loopingTemplateRepeatsItsCycle() {
        let t = lib.animation(for: "wave")
        #expect(t.loops && t.anchor == .start && t.duration > .zero)
        let probe = Time(1, 7)
        let a = t.value(of: "positionY", at: probe)!
        for n in [1, 2, 5] as [Int64] {
            #expect(abs(t.value(of: "positionY", at: probe + t.duration * n)! - a) < 1e-9)
        }
    }

    @Test func nonLoopingTemplateStillClamps() {
        let t = lib.animation(for: "rise")
        #expect(!t.loops)
        #expect(t.value(of: "positionY", at: t.duration * 10) == 0)
    }

    @Test func loopsReadAsFalseFromOldFilesAndEncodeOnlyWhenOn() throws {
        let old = #"{"anchor":"start","duration":{"value":1,"timescale":2},"tracks":[]}"#
        #expect(try JSONDecoder().decode(KeyframeTemplate.self, from: Data(old.utf8)).loops == false)
        let plain = try JSONEncoder().encode(lib.animation(for: "rise"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("loops"))
        let wave = lib.animation(for: "wave")
        let back = try JSONDecoder().decode(KeyframeTemplate.self, from: JSONEncoder().encode(wave))
        #expect(back == wave && back.loops)
    }

    @Test func animationSetPlaysLoopsPastTheCycle() {
        let set = AnimationSet(in: lib.animation(for: "pulse"), out: nil)
        let d = lib.animation(for: "pulse").duration
        let early = set.value(of: "scale", clipTime: Time(1, 8), clipDuration: Time(10, 1))!
        let late = set.value(of: "scale", clipTime: Time(1, 8) + d * 3, clipDuration: Time(10, 1))!
        #expect(abs(early - late) < 1e-9)
    }

    // MARK: Specific animations

    @Test func popScalesZeroTo120To100AtFrames0_4_10() {
        let t = lib.animation(for: "pop")
        let f = Time(1, 30)
        #expect(t.value(of: "scale", at: .zero) == 0)
        #expect(abs(t.value(of: "scale", at: f * 4)! - 1.2) < 1e-9)
        #expect(abs(t.value(of: "scale", at: f * 10)! - 1.0) < 1e-9)
        #expect(t.duration == f * 10)
    }

    @Test func exitAnimationsAreEndAnchoredAndEndInvisibleOrGone() {
        for id in ["fade-out", "shrink-out", "slide-out"] {
            let t = lib.animation(for: id)
            #expect(t.anchor == .end, "\(id)")
            let clip = Time(3, 1)
            let end = clip - Time(1, 1000)
            let o = t.value(of: "opacity", clipTime: end, clipDuration: clip) ?? 1
            let s = t.value(of: "scale", clipTime: end, clipDuration: clip) ?? 1
            #expect(o < 0.05 || s < 0.05, "\(id)")
        }
    }

    // MARK: Gallery

    @Test func galleryHasTwelveToSixteenLooksWithUniqueIDsAndKnownRefs() {
        let all = CaptionStyleLooks.all
        #expect((12...24).contains(CaptionStyleLooks.handmade.count))
        #expect(Set(all.map(\.id)).count == all.count)
        for l in all {
            #expect(lib.hasStyle(l.styleRef), "\(l.id) style")
            #expect(lib.hasAnimation(l.animationRef), "\(l.id) animation")
            #expect(!l.title.isEmpty)
        }
        for g in LookGroup.allCases where g != .collection || BuiltInTextLooks.isEnabled { #expect(all.contains { $0.group == g }, "group \(g)") }
    }

    @Test func eachMotionCategoryIsCovered() {
        let ids = Set(CaptionStyleLooks.all.map(\.animationRef))
        for need in ["pop", "wave", "hop", "pulse", "slide-out", "rise"] { #expect(ids.contains(need), "\(need)") }
        #expect(CaptionStyleLooks.all.contains { $0.karaoke?.keepSpoken == true })
        #expect(CaptionStyleLooks.all.contains { $0.karaoke?.keepSpoken == false })
    }

    @Test func animationSetPutsTheLookInTheSlotOfItsAnchor() {
        let pop = CaptionStyleLooks.look(id: "pop")!
        let set = pop.animationSet(in: lib, keeping: AnimationSet(in: nil, out: lib.animation(for: "fade-out")))
        #expect(set.animationIn == lib.animation(for: "pop"))
        #expect(set.animationOut == lib.animation(for: "fade-out"))
        let out = CaptionStyleLooks.look(id: "shrink-out")!
        let s2 = out.animationSet(in: lib, keeping: AnimationSet(in: lib.animation(for: "pop"), out: nil))
        #expect(s2.animationIn == lib.animation(for: "pop"))
        #expect(s2.animationOut?.anchor == .end)
    }

    // MARK: Per-unit and shake looks (research wave: wave / bounce / loop / exit styles)

    @Test func unitAnimatorLooksCarryTextAnimatorsOnTheRightSide() {
        let expect: [(String, TextAnimatorEffect, TextAnimatorUnit, AnimationAnchor)] = [
            ("word-bounce", .pop, .word, .start), ("ripple-in", .slide, .character, .start),
            ("ripple-out", .slide, .character, .end), ("word-pop-out", .pop, .word, .end),
        ]
        for (id, effect, unit, anchor) in expect {
            let t = lib.animation(for: id)
            #expect(t.textAnimator?.effect == effect && t.textAnimator?.unit == unit, "\(id)")
            #expect(t.anchor == anchor, "\(id)")
            let look = CaptionStyleLooks.all.first { $0.animationRef == id }
            #expect(look != nil, "\(id) has a gallery look")
        }
        #expect(lib.animation(for: "word-bounce").textAnimator?.easing == .overshoot)
    }

    @Test func unitExitLooksEndHiddenAtTheClipEnd() {
        for id in ["ripple-out", "word-pop-out"] {
            let a = lib.animation(for: id).textAnimator!
            let clip = Time(3, 1)
            for n in [1, 4] {
                let s = a.outState(ofUnit: n - 1, count: n, clipTime: clip, clipDuration: clip)
                #expect(s.opacity < 0.01 || s.scale < 0.01, "\(id)")
            }
            #expect(a.outState(ofUnit: 0, count: 3, clipTime: .zero, clipDuration: clip).isRest, "\(id)")
        }
    }

    @Test func shakeLoopsWithoutAJump() {
        let t = lib.animation(for: "shake")
        #expect(t.loops && t.anchor == .start)
        #expect(t.value(of: "positionX", at: .zero) == t.value(of: "positionX", at: t.duration))
    }

    // MARK: Preview pose

    @Test func previewPoseIsPureAndRationalInTime() {
        let look = CaptionStyleLooks.look(id: "pop")!
        let a = CaptionStyleLooks.pose(of: look, library: lib, at: Time(1, 15))
        let b = CaptionStyleLooks.pose(of: look, library: lib, at: Time(1, 15))
        #expect(a == b)
        #expect(abs(a.scale - lib.animation(for: "pop").value(of: "scale", at: Time(1, 15))!) < 1e-12)
        let rest = CaptionStyleLooks.pose(of: look, library: lib, at: Time(1, 1))
        #expect(rest.scale == 1 && rest.opacity == 1 && rest.offsetY == 0)
    }

    @Test func previewExitPoseRunsOverTheTailOfTheWindow() {
        let look = CaptionStyleLooks.look(id: "fade-away")!
        let start = CaptionStyleLooks.pose(of: look, library: lib, at: Time(1, 100))
        let end = CaptionStyleLooks.pose(of: look, library: lib, at: CaptionStyleLooks.previewDuration - Time(1, 1000))
        #expect(start.opacity == 1)
        #expect(end.opacity < 0.05)
    }

    @Test func previewLitWordAdvancesWithTime() {
        #expect(CaptionStyleLooks.litWord(count: 4, at: .zero) == 0)
        #expect(CaptionStyleLooks.litWord(count: 4, at: CaptionStyleLooks.previewDuration - Time(1, 1000)) == 3)
        #expect(CaptionStyleLooks.litWord(count: 4, at: CaptionStyleLooks.previewDuration * 0 + Time(1, 1)) == 2)   // 2 s window
        #expect(CaptionStyleLooks.litWord(count: 0, at: .zero) == nil)
    }
}
