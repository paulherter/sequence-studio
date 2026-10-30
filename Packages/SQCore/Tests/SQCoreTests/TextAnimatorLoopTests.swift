import Testing
import Foundation
@testable import SQCore

/// Loop effects (wave, pulse): the unit moves through `loops` full cycles and rests exactly at both ends.
@Suite struct TextAnimatorLoopTests {
    func wave(loops: Int = 1) -> TextAnimator {
        TextAnimator(effect: .wave, unit: .character, duration: Time(1, 1), stagger: Time(1, 10), distance: 20, loops: loops)
    }

    @Test func loopsDefaultToOneAndStayOutOfOldFiles() throws {
        let a = TextAnimator(effect: .fade, unit: .word, duration: Time(1, 2), stagger: Time(1, 10))
        #expect(a.loops == 1)
        #expect(!String(decoding: try JSONEncoder().encode(a), as: UTF8.self).contains("loops"))
        var l = a; l.loops = 3
        #expect(try JSONDecoder().decode(TextAnimator.self, from: JSONEncoder().encode(l)).loops == 3)
    }

    @Test func loopsStretchTheUnitWindow() {
        #expect(wave(loops: 3).totalDuration(count: 1) == Time(3, 1))
        #expect(wave(loops: 1).totalDuration(count: 1) == Time(1, 1))
        // Loops only apply to loop effects.
        let fade = TextAnimator(effect: .fade, unit: .word, duration: Time(1, 2), stagger: .zero, loops: 4)
        #expect(fade.totalDuration(count: 1) == Time(1, 2))
    }

    @Test func waveRestsAtCycleEndsAndPeaksInTheMiddle() {
        let a = wave(loops: 2)
        #expect(a.inState(ofUnit: 0, count: 1, at: .zero).isRest)
        #expect(a.inState(ofUnit: 0, count: 1, at: Time(1, 1)).isRest)
        #expect(a.inState(ofUnit: 0, count: 1, at: Time(2, 1)).isRest)
        #expect(abs(a.inState(ofUnit: 0, count: 1, at: Time(1, 2)).offsetY + 20) < 1e-9)
        #expect(abs(a.inState(ofUnit: 0, count: 1, at: Time(3, 2)).offsetY + 20) < 1e-9)
    }

    @Test func pulseScalesAndStaggerDelaysUnits() {
        let a = TextAnimator(effect: .pulse, unit: .character, duration: Time(1, 1), stagger: Time(1, 4))
        #expect(a.inState(ofUnit: 0, count: 2, at: Time(1, 2)).scale > 1.1)
        #expect(a.inState(ofUnit: 1, count: 2, at: Time(1, 8)).isRest)
    }
}
