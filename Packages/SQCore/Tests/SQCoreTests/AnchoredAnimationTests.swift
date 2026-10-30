import Testing
import Foundation
@testable import SQCore

/// W7.3: the anchored in/out animation model lives in SQCore and has one evaluator (`AnimationSet.sample`) that the
/// monitor (TextGenerator) and the export (CaptionBurnIn) both use.
@Suite struct AnchoredAnimationTests {
    let popIn = KeyframeTemplate(tracks: [
        AnimationTrack(property: "scale", keys: [(.zero, 0.8, .overshoot), (Time(1, 4), 1.0, .linear)]),
        AnimationTrack(property: "opacity", keys: [(.zero, 0, .easeOut), (Time(1, 8), 1, .linear)]),
    ], duration: Time(1, 4))
    let slideOut = KeyframeTemplate(tracks: [
        AnimationTrack(property: "positionX", keys: [(.zero, 0, .linear), (Time(1, 2), 300, .linear)]),
        AnimationTrack(property: "positionY", keys: [(.zero, 0, .linear), (Time(1, 2), -50, .linear)]),
        AnimationTrack(property: "rotation", keys: [(.zero, 0, .linear), (Time(1, 2), 30, .linear)]),
        AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 2), -1, .linear)]),
    ], duration: Time(1, 2), anchor: .end)

    @Test func singleTemplatePicksTheSideByAnchor() {
        #expect(AnimationSet(single: popIn) == AnimationSet(in: popIn, out: nil))
        #expect(AnimationSet(single: slideOut) == AnimationSet(in: nil, out: slideOut))
        #expect(AnimationSet(single: KeyframeTemplate.none) == nil)
        #expect(AnimationSet(single: nil) == nil)
        // An animator-only template is not "none".
        let animator = KeyframeTemplate(textAnimator: TextAnimator(effect: .fade, unit: .word, duration: Time(1, 5),
                                                                   stagger: Time(1, 10)))
        #expect(AnimationSet(single: animator) == AnimationSet(in: animator, out: nil))
    }

    @Test func sampleEqualsThePerPropertyValues() {
        let set = AnimationSet(in: popIn, out: slideOut)
        let d = Time(2, 1)
        for n in 0...60 {
            let t = Time(Int64(n), 30)
            let s = set.sample(clipTime: t, clipDuration: d)
            func v(_ p: String, _ def: Double) -> Double { set.value(of: p, clipTime: t, clipDuration: d) ?? def }
            #expect(s.opacity == min(1, max(0, v("opacity", 1))))
            #expect(s.scale == v("scale", 1))
            #expect(s.offset == Vec2(v("positionX", 0), v("positionY", 0)))
            #expect(s.rotation == v("rotation", 0))
        }
    }

    @Test func emptySetSamplesToRest() {
        let s = AnimationSet(in: nil, out: nil).sample(clipTime: Time(1, 1), clipDuration: Time(2, 1))
        #expect(s == .rest)
        #expect(AnimationSample.rest == AnimationSample(opacity: 1, scale: 1, offset: .zero, rotation: 0))
        #expect(AnimationSample.rest.isRest)
    }

    @Test func outSideEndsHiddenAndClampsOpacity() {
        let set = AnimationSet(in: nil, out: slideOut)
        let end = set.sample(clipTime: Time(2, 1), clipDuration: Time(2, 1))
        #expect(end.opacity == 0)                 // -1 clamps to 0
        #expect(end.offset == Vec2(300, -50) && end.rotation == 30)
        #expect(set.sample(clipTime: Time(1, 1), clipDuration: Time(2, 1)) == .rest)
    }
}
