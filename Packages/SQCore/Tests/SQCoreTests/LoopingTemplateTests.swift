import Testing
import Foundation
@testable import SQCore

@Suite struct LoopingTemplateTests {
    private func wave(loops: Bool) -> KeyframeTemplate {
        KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 0, .easeInOut), (Time(1, 4), -14, .easeInOut),
                                                         (Time(3, 4), 14, .easeInOut), (Time(1, 1), 0, .linear)]),
        ], duration: Time(1, 1), loops: loops)
    }

    @Test func wrapIsExactRational() {
        let p = Time(2, 3)
        #expect(KeyframeTemplate.wrap(Time(1, 3), period: p) == Time(1, 3))
        #expect(KeyframeTemplate.wrap(Time(2, 3), period: p) == .zero)
        #expect(KeyframeTemplate.wrap(Time(5, 3), period: p) == Time(1, 3))
        #expect(KeyframeTemplate.wrap(Time(1001, 30000) * 90, period: Time(1, 1)) == Time(90 * 1001 - 3 * 30000, 30000))
    }

    @Test func wrapLeavesNegativeAndDegenerateAlone() {
        #expect(KeyframeTemplate.wrap(Time(-1, 5), period: Time(1, 1)) == Time(-1, 5))
        #expect(KeyframeTemplate.wrap(Time(7, 5), period: .zero) == Time(7, 5))
    }

    @Test func loopingTemplateRepeatsAndPlainOneClamps() {
        let t = wave(loops: true), plain = wave(loops: false)
        let probe = Time(1, 7)
        let a = t.value(of: "positionY", at: probe)!
        for n in [1, 2, 5] as [Int64] { #expect(abs(t.value(of: "positionY", at: probe + t.duration * n)! - a) < 1e-9) }
        #expect(plain.value(of: "positionY", at: plain.duration * 10) == 0)
    }

    @Test func loopsAreOptionalOnDiskAndWrittenOnlyWhenTrue() throws {
        let old = #"{"anchor":"start","duration":{"value":1,"timescale":2},"tracks":[]}"#
        #expect(try JSONDecoder().decode(KeyframeTemplate.self, from: Data(old.utf8)).loops == false)
        #expect(!String(decoding: try JSONEncoder().encode(wave(loops: false)), as: UTF8.self).contains("loops"))
        let on = wave(loops: true)
        #expect(try JSONDecoder().decode(KeyframeTemplate.self, from: JSONEncoder().encode(on)) == on)
    }

    @Test func animationSetPlaysLoopsPastTheCycle() {
        let set = AnimationSet(in: wave(loops: true), out: nil)
        let early = set.value(of: "positionY", clipTime: Time(1, 8), clipDuration: Time(10, 1))!
        let late = set.value(of: "positionY", clipTime: Time(1, 8) + Time(3, 1), clipDuration: Time(10, 1))!
        #expect(abs(early - late) < 1e-9)
    }
}
