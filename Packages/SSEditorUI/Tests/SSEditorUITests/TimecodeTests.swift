import Testing
import SSCore
@testable import SSEditorUI

@Suite struct TimecodeTests {
    let ndf2997 = Timecode(frameDuration: Time(1001, 30000), dropFrame: false)
    let df2997 = Timecode(frameDuration: Time(1001, 30000), dropFrame: true)
    let f25 = Timecode(frameDuration: Time(1, 25), dropFrame: false)
    let f23976 = Timecode(frameDuration: Time(1001, 24000), dropFrame: false)

    @Test func nominalRates() {
        #expect(ndf2997.nominalFPS == 30)
        #expect(f25.nominalFPS == 25)
        #expect(f23976.nominalFPS == 24)
    }

    @Test func formatNonDrop() {
        #expect(ndf2997.format(.zero) == "00:00:00:00")
        #expect(ndf2997.format(Time(1001, 30000) * 30) == "00:00:01:00")
        #expect(ndf2997.format(Time(1001, 30000) * 1800) == "00:01:00:00")
        #expect(f25.format(Time(1, 25) * 26) == "00:00:01:01")
        #expect(f25.format(Time(1, 25) * 90_000) == "01:00:00:00")
        #expect(f23976.format(Time(1001, 24000) * 48) == "00:00:02:00")
    }

    @Test func formatDropFrame() {
        let fd = Time(1001, 30000)
        #expect(df2997.format(fd * 1799) == "00:00:59;29")
        #expect(df2997.format(fd * 1800) == "00:01:00;02")
        #expect(df2997.format(fd * 17_981) == "00:09:59;29")
        #expect(df2997.format(fd * 17_982) == "00:10:00;00")
        #expect(df2997.format(fd * 107_892) == "01:00:00;00")
        #expect(df2997.format(fd * 3598) == "00:02:00;02")
    }

    @Test func dropFrameUsesSemicolon() {
        #expect(df2997.separatorBeforeFrames == ";")
        #expect(ndf2997.separatorBeforeFrames == ":")
    }

    @Test func dropFrameIgnoredForNonDropRates() {
        #expect(Timecode(frameDuration: Time(1, 25), dropFrame: true).dropFrame == false)
        #expect(Timecode(frameDuration: Time(1, 30), dropFrame: true).dropFrame == false)
    }

    @Test func roundTripDF() {
        let fd = Time(1001, 30000)
        for n in stride(from: 0, to: 120_000, by: 7) {
            let t = fd * Int64(n)
            #expect(df2997.parse(df2997.format(t)) == t)
        }
    }

    @Test func parseForms() {
        #expect(f25.parse("00:00:01:01") == Time(26, 25))
        #expect(f25.parse("1:01") == Time(26, 25))
        #expect(f25.parse("101") == Time(26, 25))
        #expect(f25.parse("00.00.01.01") == Time(26, 25))
        #expect(f25.parse(" 00:00:01:01 ") == Time(26, 25))
        #expect(f25.parse("-00:00:01:00") == Time(-1, 1))
        #expect(df2997.parse("00;01;00;02") == Time(1001, 30000) * 1800)
        #expect(f23976.parse("00:00:02:00") == Time(1001, 24000) * 48)
    }

    @Test func parseRejects() {
        #expect(f25.parse("") == nil)
        #expect(f25.parse("abc") == nil)
        #expect(f25.parse("00:00:00:25") == nil)
        #expect(f25.parse("00:60:00:00") == nil)
        #expect(df2997.parse("00:01:00:00") == nil)
        #expect(df2997.parse("00:01:00:01") == nil)
    }

    @Test func negativeFormat() {
        #expect(f25.format(Time(-26, 25)) == "-00:00:01:01")
    }
}

@Suite struct MonitorModelTests {
    @MainActor @Test func timecodeCommitSeeks() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25))
        var sought: Time?
        m.onSeek = { sought = $0 }
        #expect(m.commitTimecodeText("00:00:01:01"))
        #expect(sought == Time(26, 25))
        sought = nil
        #expect(!m.commitTimecodeText("garbage"))
        #expect(sought == nil)
    }

    @MainActor @Test func texts() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25))
        m.currentTime = Time(26, 25)
        m.duration = Time(10, 1)
        #expect(m.timecodeText == "00:00:01:01")
        #expect(m.durationText == "00:00:10:00")
        #expect(m.inOutDurationText == nil)
        m.markIn = Time(1, 1)
        m.markOut = Time(3, 1)
        #expect(m.inOutDurationText == "00:00:02:00")
        m.markOut = nil
        #expect(m.inOutDurationText == "00:00:09:00")
    }

    @MainActor @Test func transportCallbacksAndModes() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25))
        var log: [MonitorAction] = []
        m.onAction = { log.append($0) }
        m.perform(.playPause)
        m.perform(.stepForward)
        m.perform(.insert)
        #expect(log == [.playPause, .stepForward])
        m.mode = .source
        m.perform(.insert)
        m.perform(.overwrite)
        #expect(log.suffix(2) == [.insert, .overwrite])
        #expect(m.availableActions.contains(.insert))
        m.mode = .program
        #expect(!m.availableActions.contains(.insert))
    }

    @MainActor @Test func zoomAndQuality() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25))
        var z: MonitorZoom?, q: MonitorQuality?
        m.onZoomChange = { z = $0 }
        m.onQualityChange = { q = $0 }
        m.setZoom(.percent(200))
        m.setQuality(.half)
        #expect(z == .percent(200) && m.zoom == .percent(200))
        #expect(q == .half && m.quality == .half)
        #expect(MonitorQuality.half.divisor == 2 && MonitorQuality.quarter.divisor == 4)
        #expect(MonitorZoom.presets.first == .fit)
        #expect(MonitorZoom.presets.count == 8)
        #expect(MonitorZoom.percent(25).title == "25%")
    }

    @MainActor @Test func dropFrameToggle() {
        let m = MonitorPanelModel(frameDuration: Time(1001, 30000))
        m.dropFrame = true
        m.currentTime = Time(1001, 30000) * 1800
        #expect(m.timecodeText == "00:01:00;02")
    }
}
