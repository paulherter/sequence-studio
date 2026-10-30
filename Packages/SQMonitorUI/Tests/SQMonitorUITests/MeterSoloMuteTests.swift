import AppKit
import Testing
import SQAudioFX
import SQCore
import SQUIKit
@testable import SQMonitorUI

@MainActor
@Suite struct MeterSoloMuteTests {
    @Test func soloAndMuteToggleAndReport() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 48, height: 200))
        var seen: [ChannelMonitor] = []
        v.onChannelMonitorChange = { seen.append($0) }
        v.toggleSolo(bar: 1)
        #expect(v.channelMonitor.gains == [0, 1])
        v.toggleMute(bar: 1)
        #expect(v.channelMonitor.gains == [0, 0])
        v.clearChannelMonitor()
        #expect(v.channelMonitor.isNeutral)
        #expect(seen.count == 3)
        v.clearChannelMonitor()
        #expect(seen.count == 3)                 // already neutral: nothing to report
    }

    @Test func monoBarStandsForBothChannels() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 48, height: 200))
        v.isMono = true
        v.toggleMute(bar: 0)
        #expect(v.channelMonitor.gains == [0, 0])
    }

    @Test func clickOnBarsInsideWaveformViewDoesNotScrub() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        m.duration = Time(10, 1)
        var began = 0
        m.onScrubBegan = { began += 1 }
        let v = SourceWaveformView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        v.meterReading = { nil }
        v.layoutSubtreeIfNeeded()
        let meter = v.meter
        let local = NSPoint(x: 12, y: 100)                       // on a bar body
        let win = meter.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: win, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: meter.mouseDown(with: e)
            case .leftMouseDragged: meter.mouseDragged(with: e)
            default: meter.mouseUp(with: e)
            }
        }
        #expect(began == 0)
    }

    @Test func clickUnderABarMapsToThatBar() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 48, height: 200))
        #expect(v.bar(atX: 10) == 0)
        #expect(v.bar(atX: 18) == 1)
        #expect(v.bar(atX: 45) == nil)
    }

    @Test func panelForwardsAndMenuListsChannels() {
        let panel = AudioMeterPanelView(frame: NSRect(x: 0, y: 0, width: 120, height: 300), monitorDefaults: UserDefaults(suiteName: "sq.test.solo")!)
        var last: ChannelMonitor?
        panel.onChannelMonitorChange = { last = $0 }
        panel.meter.toggleSolo(bar: 0)
        #expect(last?.gains == [1, 0])
        let titles = panel.monitorItems().map(\.title)
        #expect(titles.contains("Solo L") && titles.contains("Mute R") && titles.contains("Clear Solo and Mute"))
    }

    @Test func sourceWaveformMeterFollowsTheSourceEngine() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        let v = SourceWaveformView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        var now = 0.0
        v.clock = { now }
        let id = ObjectIdentifier(v)
        var seq = 0
        v.meterReading = { seq += 1; return (id, seq, [0.5, 0.25]) }
        v.pollMeter()
        #expect(v.meter.channels.count == 2)
        #expect(v.meter.channels[0].levelDB > MeterBallistics.floorDB)
        v.meterReading = { (id, 1, [0.5, 0.25]) }          // same buffer again: nothing new, then stale
        now = 1
        v.pollMeter()
        let settled = v.meter.channels.allSatisfy { $0.isSettled }
        #expect(settled)
    }
}
