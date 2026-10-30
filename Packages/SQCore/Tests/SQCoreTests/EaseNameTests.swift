import Foundation
import Testing
@testable import SQCore

/// One easing vocabulary for the whole app (DECISIONS 2026-10-06): display names only, stored names untouched.
@Test func transitionEasingsUseTheKeyframeNamesInTheSameOrder() {
    #expect(EaseName.keyframeMenu == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold"])
    #expect(EasingCurve.transitionPresets.map(\.displayName) == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Fast Start", "Fast End",
                                                                 "Smooth In 100%", "Smooth Out 100%", "Overshoot"])
    // Same words, same order: the transition list is the keyframe list without Hold, then the extra presets.
    #expect(Array(EasingCurve.transitionPresets.map(\.displayName).prefix(4)) == Array(EaseName.keyframeMenu.prefix(4)))
}

@Test func displayNamesNeverChangeWhatIsStored() throws {
    #expect(EasingCurve.easeInOut.name == "Ease-in-out 33%")
    #expect(EasingCurve.easeIn.name == "Ease-in 33%")
    let data = try JSONEncoder().encode(EasingCurve.easeOut)
    #expect(String(decoding: data, as: UTF8.self).contains("Ease-out 33%"))
    // A curve read from an old file under its stored name still shows the own name (matched by built-in id).
    #expect(try JSONDecoder().decode(EasingCurve.self, from: data).displayName == "Smooth Out")
}

@Test func everyBuiltInAndChoiceHasAnOwnName() {
    let names = EasingCurve.builtIns.map(\.displayName)
    #expect(names == ["Steady", "Hold", "Smooth", "Smooth In", "Smooth Out", "Fast Start", "Fast End",
                      "Gentle", "Smooth In 100%", "Smooth Out 100%", "Soft Landing"])
    #expect(Set(names).count == names.count)
    for n in names + MotionCurve.titles + PunchInCutsOptions.Ease.allCases.map(\.title) {
        #expect(!n.lowercased().contains("ease"), "\(n)")
        #expect(!n.contains("33"), "\(n)")
    }
    // A user's saved curve keeps the name it was given.
    #expect(EasingCurve(name: "My ease-y curve", interpolation: .bezier, outHandle: .linear, inHandle: .linear).displayName == "My ease-y curve")
    #expect(KeyInterpolationChoice.linear.title == "Steady")
    #expect(KeyInterpolationChoice.easeIn.title == "Smooth In" && KeyInterpolationChoice.easeOut.title == "Smooth Out")
    #expect(MotionCurve.easeIn.title == "Smooth In" && MotionCurve.easeOut100.title == "Smooth In 100%")
    #expect(PunchInCutsOptions.Ease.allCases.map(\.title) == ["Hold", "Steady", "Smooth", "Fast Start"])
}

/// The motion effect Curve list speaks the same vocabulary: "In" is the slow arrival, "Out" the slow start, the bare
/// word both; no maths names (Sine, Quad ...), no "curve" suffix. Raw values (stored) keep their order.
@Test func motionCurveFamiliesUseTheSameVocabulary() {
    #expect(Array(MotionCurve.titles.prefix(3)) == ["Gentle", "Smooth", "Auto"])
    #expect(MotionCurve.sineIn.rawValue == 11 && MotionCurve.custom.rawValue == 41)
    // CSS "In" accelerates = leaves slowly = our "Out".
    #expect(MotionCurve.sineIn.title == "Soft Out" && MotionCurve.sineOut.title == "Soft In" && MotionCurve.sineInOut.title == "Soft")
    #expect(MotionCurve.sineIn.ease(0.5) < 0.5 && MotionCurve.sineOut.ease(0.5) > 0.5)
    #expect([MotionCurve.quadInOut, .cubicInOut, .quartInOut, .quintInOut, .expoInOut, .circInOut].map(\.title)
            == ["Light", "Firm", "Strong", "Heavy", "Sharp", "Round"])
    #expect(MotionCurve.backIn.title == "Wind-Up" && MotionCurve.backOut.title == "Overshoot" && MotionCurve.backInOut.title == "Wind-Up Overshoot")
    #expect(MotionCurve.elasticOut.title == "Spring In" && MotionCurve.elasticIn.title == "Spring Out" && MotionCurve.elasticInOut.title == "Spring In Out")
    #expect(MotionCurve.bounceOut.title == "Bounce In" && MotionCurve.bounceIn.title == "Bounce Out" && MotionCurve.bounceInOut.title == "Bounce")
    for n in MotionCurve.titles {
        for word in ["Sine", "Quad", "Cubic", "Quart", "Quint", "Expo", "Circ", "Back", "Elastic", "Bezier", "curve", "-Out", "("] {
            #expect(!n.contains(word), "\(n)")
        }
    }
    #expect(Set(MotionCurve.titles).count == MotionCurve.titles.count)
}

/// Premiere's influence range is 0.1...100 %: a handle can be that short and reach the other key.
@Test func reachCoversPremieresInfluenceRange() {
    #expect(SpeedHill.minReach == 0.001)
    let s = EasingCurve.easeInOut.shape
    #expect(s.settingReach(0, side: .out).reachOut == 0.001)
    #expect(s.settingReach(2, side: .both).reachOut == 1 && s.settingReach(2, side: .both).reachIn == 1)
    // Both handles at the middle (50 % each): a hill peaking at twice the steady speed, in the middle.
    let mid = SpeedHill.samples(s.settingReach(0.5, side: .both), count: 97)
    let top = mid.max { $0.speed < $1.speed }!
    #expect(abs(top.speed - 2) < 1e-9 && abs(top.x - 0.5) < 1e-9)
    #expect(abs(SpeedHill.area(mid) - 1) < 0.01)
}
