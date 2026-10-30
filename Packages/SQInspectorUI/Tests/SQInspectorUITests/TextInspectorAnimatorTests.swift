import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

@MainActor @Suite struct TextInspectorAnimatorTests {
    final class Log { var events: [String] = []; var sets: [AnimationSet] = [] }

    func make() -> (TextInspectorModel, Log) {
        let m = TextInspectorModel(style: TextStyle(), animations: AnimationSet(in: nil, out: nil),
                                   library: .builtIn, fontFamilies: { ["Helvetica"] })
        let log = Log()
        m.onBeginEditing = { log.events.append("begin") }
        m.onEndEditing = { log.events.append("end") }
        m.onChange = { _, a in log.events.append("change"); log.sets.append(a) }
        return (m, log)
    }

    @Test func choosingAnEffectCreatesAnAnimatorWithDefaults() {
        let (m, log) = make()
        m.setAnimatorEffect(.fade, side: .in)
        let a = m.animator(.in)
        #expect(a?.effect == .fade && a?.unit == .word)
        #expect(a?.duration == Time(3, 10) && a?.stagger == Time(2, 25))
        #expect(m.animations.animationIn?.anchor == .start)
        #expect(log.events == ["begin", "change", "end"])
        m.setAnimatorEffect(.typewriter, side: .out)
        #expect(m.animations.animationOut?.anchor == .end && m.animator(.out)?.effect == .typewriter)
    }

    @Test func distanceAndBlurAreEditableAndClamped() {
        let (m, _) = make()
        m.setAnimatorEffect(.slide, side: .in)
        m.setAnimatorDistance(120, side: .in)
        m.setAnimatorBlurRadius(-5, side: .in)
        #expect(m.animator(.in)?.distance == 120 && m.animator(.in)?.blurRadius == 0)
        m.setAnimatorDistance(.nan, side: .in)
        #expect(m.animator(.in)?.distance == 40)
        m.setAnimatorDistance(99_999, side: .in)
        #expect(m.animator(.in)?.distance == 2000)
    }

    @Test func popDefaultsToOvershoot() {
        let (m, _) = make()
        m.setAnimatorEffect(.pop, side: .in)
        #expect(m.animator(.in)?.easing == .overshoot)
    }

    @Test func millisecondFieldsAreRational() {
        let (m, _) = make()
        m.setAnimatorEffect(.slide, side: .in)
        m.setAnimatorDuration(milliseconds: 450, side: .in)
        m.setAnimatorStagger(milliseconds: 33, side: .in)
        #expect(m.animator(.in)?.duration == Time(450, 1000))
        #expect(m.animator(.in)?.stagger == Time(33, 1000))
        #expect(m.animatorMilliseconds(Time(1001, 30000)) == 33)
        m.setAnimatorStagger(milliseconds: -5, side: .in)
        #expect(m.animator(.in)?.stagger == .zero)
    }

    @Test func millisecondInputIsSanitized() {
        #expect(TextInspectorModel.milliseconds(from: .infinity) == 0)
        #expect(TextInspectorModel.milliseconds(from: -.infinity) == 0)
        #expect(TextInspectorModel.milliseconds(from: .nan) == 0)
        #expect(TextInspectorModel.milliseconds(from: 1e30) == 60_000)
        #expect(TextInspectorModel.milliseconds(from: 12.6) == 13)
        let (m, _) = make()
        m.setAnimatorEffect(.fade, side: .in)
        m.setAnimatorDuration(milliseconds: Int.max, side: .in)
        m.setAnimatorStagger(milliseconds: Int.max, side: .in)
        #expect(m.animator(.in)?.duration == Time(60, 1) && m.animator(.in)?.stagger == Time(60, 1))
    }

    @Test func unitOrderEasingEdits() {
        let (m, _) = make()
        m.setAnimatorEffect(.blur, side: .in)
        m.setAnimatorUnit(.character, side: .in)
        m.setAnimatorOrder(.center, side: .in)
        m.setAnimatorEasing(.easeInOut, side: .in)
        let a = m.animator(.in)
        #expect(a?.unit == .character && a?.order == .center && a?.easing == .easeInOut && a?.effect == .blur)
        // Edits without an animator do nothing.
        m.setAnimatorUnit(.line, side: .out)
        #expect(m.animator(.out) == nil)
    }

    @Test func removingTheEffectDropsAnAnimatorOnlyTemplate() {
        let (m, _) = make()
        m.setAnimatorEffect(.fade, side: .in)
        m.setAnimatorEffect(nil, side: .in)
        #expect(m.animations.animationIn == nil)
    }

    @Test func presetAndAnimatorLiveSideBySide() {
        let (m, _) = make()
        m.setInAnimation("pop-in")
        m.setAnimatorEffect(.fade, side: .in)
        #expect(m.selectedInID == "pop-in")
        #expect(m.animations.animationIn?.tracks.isEmpty == false && m.animator(.in)?.effect == .fade)
        m.setInAnimation("fade")                       // switching the preset keeps the animator
        #expect(m.selectedInID == "fade" && m.animator(.in)?.effect == .fade)
        m.setAnimatorEffect(nil, side: .in)            // the preset stays
        #expect(m.selectedInID == "fade" && m.animator(.in) == nil)
        m.setAnimatorEffect(.slide, side: .in)
        m.setInAnimation("none")                       // no preset: the animator alone remains
        #expect(m.animator(.in)?.effect == .slide && m.animations.animationIn?.tracks.isEmpty == true)
        #expect(m.selectedInID == "none")
    }
}
