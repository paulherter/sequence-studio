import Foundation
import Testing
import SQAudioFX
import SQCore
import SQDrawKit
import SQUIKit
@testable import SQDrawMonitor

@MainActor
@Suite struct MeterStripTests {
    /// A meter card as the Windows host lays it out (104 pt wide) on its own defaults suite.
    func panel(height: Float = 400) -> (MeterPanel, UserDefaults) {
        let name = "sq.test.meter.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let p = MeterPanel(monitorDefaults: d)
        p.layout(DrawRect(x: 0, y: 0, w: 104, h: height), scale: 1)
        return (p, d)
    }

    func click(_ p: MeterPanel, _ pt: CGPoint, _ mods: InputModifiers = []) {
        _ = p.handle(.mouseDown(x: Float(pt.x), y: Float(pt.y), modifiers: mods))
        _ = p.handle(.mouseUp(x: Float(pt.x), y: Float(pt.y)))
    }

    /// The label row under the bars of bar `i`.
    func label(_ p: MeterPanel, _ i: Int) -> CGPoint {
        CGPoint(x: p.meterRect.minX + 8 + CGFloat(i) * 8 + 2, y: p.meterRect.maxY - 8)
    }

    @Test func stripShowsUnderTheMeterOnlyWhenTheCardIsTallEnough() {
        let (p, _) = panel()
        #expect(p.stripRect.height == CGFloat(DrawTheme.Metrics.monitorStrip))
        #expect(p.meterRect.maxY == p.stripRect.minY)
        #expect(p.stripRect.contains(p.sliderRect) && p.stripRect.contains(p.dimRect))
        let (small, _) = panel(height: 90)
        #expect(small.stripRect == .zero && small.meterRect.height == 90)
    }

    @Test func dimButtonTogglesTheStoredSettingAndReportsIt() {
        let (p, d) = panel()
        var reported: [MonitorGain.Setting] = []
        p.onMonitorGainChange = { reported.append($0) }
        click(p, CGPoint(x: p.dimRect.midX, y: p.dimRect.midY))
        #expect(MonitorGain.Setting.current(defaults: d).dim)
        #expect(reported.last?.dim == true)
        click(p, CGPoint(x: p.dimRect.midX, y: p.dimRect.midY))
        #expect(!MonitorGain.Setting.current(defaults: d).dim)
    }

    @Test func sliderDragSetsTheListeningLevel() {
        let (p, d) = panel()
        let r = p.sliderRect
        _ = p.handle(.mouseDown(x: Float(r.maxX - 1), y: Float(r.midY), modifiers: []))
        #expect(MonitorGain.Setting.current(defaults: d).levelDB == MonitorGain.maxDB)
        #expect(p.handle(.mouseDragged(x: Float(r.minX), y: Float(r.midY))))
        #expect(MonitorGain.Setting.current(defaults: d).levelDB == MonitorGain.minDB)
        #expect(p.handle(.mouseUp(x: Float(r.minX), y: Float(r.midY))))
        #expect(!p.handle(.mouseDragged(x: Float(r.maxX), y: Float(r.midY))))   // the drag ended
        #expect(MeterPanel.levelDB(sliderFraction: MeterPanel.sliderFraction(levelDB: -18)) == -18)
    }

    @Test func labelClickSolosAltClickMutes() {
        let (p, _) = panel()
        var changes: [ChannelMonitor] = []
        p.onChannelMonitorChange = { changes.append($0) }
        click(p, label(p, 0))
        #expect(p.channelMonitor.isSoloed(0))
        #expect(p.channelLabels == [.soloed, .silenced])
        click(p, label(p, 1), .option)
        #expect(p.channelMonitor.isMuted(1))
        #expect(p.channelLabels == [.soloed, .muted])
        p.clearChannelMonitor()
        #expect(p.channelLabels == [.normal, .normal])
        #expect(changes.count == 3 && changes.last?.isNeutral == true)
    }

    @Test func menuHasListeningChannelAndDimRows() {
        let (p, d) = panel()
        let titles = p.menuItems().map(\.title)
        #expect(titles.contains("Full (0 dB)") && titles.contains("\u{2212}12 dB"))
        #expect(titles.contains("Solo L") && titles.contains("Mute R") && titles.contains("Clear Solo and Mute"))
        #expect(titles.contains("Dim Monitor") && titles.contains("Reset Peak and Loudness"))
        p.menuItems().first { $0.title == "\u{2212}12 dB" }?.action?()
        #expect(MonitorGain.Setting.current(defaults: d).levelDB == -12)
        #expect(p.menuItems().first { $0.title == "\u{2212}12 dB" }?.isChecked == true)
    }

    @Test func drawsWithTheStrip() {
        let (p, _) = panel()
        var c = Canvas(width: 104, height: 400, atlas: nil, scale: 1)
        p.draw(&c)
        #expect(!c.list.quads.isEmpty)
    }
}
