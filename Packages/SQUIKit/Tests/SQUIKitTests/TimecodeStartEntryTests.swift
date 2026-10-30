import Testing
import SQCore
@testable import SQUIKit

@Suite struct TimecodeStartEntryTests {
    private let fd30 = Time(1, 30), fd24 = Time(1, 24)

    @Test func rateChangeReformatsInsteadOfFailingToParse() {
        // "00:00:10:25" is valid at 30 fps, not at 24 (frame 25 >= 24).
        var e = TimecodeStartEntry(start: fd30 * 325, frameDuration: fd30, framesOnly: false)
        #expect(e.text == "00:00:10:25")
        e.setText(e.text)
        e.reconfigure(frameDuration: fd24, framesOnly: false)
        #expect(e.isValid)
        #expect(e.start == fd30 * 325)
        #expect(e.text == "00:00:10:20")
        #expect(e.timecode.parse(e.text) != nil)
    }

    @Test func framesTypedAsFramesStayFramesWhenDisplayChanges() {
        var e = TimecodeStartEntry(start: .zero, frameDuration: fd30, framesOnly: true)
        e.setText("1800")
        #expect(e.isValid && e.start == fd30 * 1800)
        e.reconfigure(frameDuration: fd30, framesOnly: false)
        #expect(e.text == "00:01:00:00")
        #expect(e.start == Time(60, 1))
        e.reconfigure(frameDuration: fd30, framesOnly: true)
        #expect(e.text == "1800")
    }

    @Test func invalidTextKeepsTheLastValidStart() {
        var e = TimecodeStartEntry(start: Time(10, 1), frameDuration: fd30, framesOnly: false)
        e.setText("00:00:99:00")
        #expect(!e.isValid)
        #expect(e.start == Time(10, 1))
        e.setText("-00:00:01:00")                  // negative starts are not allowed
        #expect(!e.isValid)
        e.setText("00:00:02:00")
        #expect(e.isValid && e.start == Time(2, 1))
    }

    @Test func reconfigureAfterInvalidTextRestoresTheLastValidStart() {
        var e = TimecodeStartEntry(start: Time(10, 1), frameDuration: fd30, framesOnly: false)
        e.setText("abc")
        e.reconfigure(frameDuration: fd24, framesOnly: false)
        #expect(e.isValid && e.text == "00:00:10:00")
    }

    @Test func negativePositionSubtractsTheOriginLikePositiveOnes() {
        var tc = Timecode(frameDuration: fd30, dropFrame: false)
        tc.origin = Time(3600, 1)
        #expect(tc.parsePosition("-00:00:10:00") == Time(-3610, 1))
        #expect(tc.parsePosition("01:00:10:00") == Time(10, 1))
        let t = Time(-5, 1)
        #expect(tc.parsePosition(tc.position(t)) == t)
    }
}
