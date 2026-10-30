import Foundation
import SQDrawKit
import SQGPUKernels
@testable import SQDrawMonitor
import SQUIKit
import Testing

/// Waveform settings of the scopes (both platforms): the trace intensity of the Waveform and RGB Parade, its menu and the
/// drawn Scopes card's settings button.
@MainActor
@Suite struct ScopeTraceSettingsTests {
    func fresh() -> ScopeTraceSettings {
        let d = UserDefaults(suiteName: "sq.test.scopes.\(UUID().uuidString)")!
        return ScopeTraceSettings(defaults: d)
    }

    @Test func intensityDefaultsToOneIsClampedAndPersists() throws {
        let d = try #require(UserDefaults(suiteName: "sq.test.scopes.\(UUID().uuidString)"))
        let s = ScopeTraceSettings(defaults: d)
        #expect(s.intensity == 1)
        s.intensity = 9
        #expect(s.intensity == ScopeTraceSettings.range.upperBound)
        s.intensity = 0
        #expect(s.intensity == ScopeTraceSettings.range.lowerBound)
        s.intensity = 1.5
        #expect(ScopeTraceSettings(defaults: d).intensity == 1.5, "kept in the defaults")
    }

    @Test func onlyTheWaveformTracesTakeTheIntensity() {
        let s = fresh()
        s.intensity = 2
        #expect(s.intensity(for: .waveform) == 2 && s.intensity(for: .parade) == 2)
        #expect(s.intensity(for: .vectorscope) == 1 && s.intensity(for: .histogram) == 1)
        #expect(ScopeTraceSettings.hasSettings(.waveform) && ScopeTraceSettings.hasSettings(.parade))
        #expect(!ScopeTraceSettings.hasSettings(.vectorscope) && !ScopeTraceSettings.hasSettings(.histogram))
    }

    @Test func theMenuListsTheStepsWithTheCurrentOneCheckedAndPostsAChange() {
        let s = fresh()
        let items = s.menuItems()
        let choices = items.filter { $0.kind == .action }
        #expect(choices.map(\.title) == ["50%", "75%", "100%", "150%", "200%"])
        #expect(choices.filter(\.isChecked).map(\.title) == ["100%"])
        final class Count: @unchecked Sendable { var n = 0 }     // the observer block is @Sendable off the Mac
        let posted = Count()
        let token = NotificationCenter.default.addObserver(forName: ScopeTraceSettings.didChange, object: s, queue: nil) { _ in posted.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        choices[3].action?()
        #expect(s.intensity == 1.5 && posted.n == 1)
        #expect(s.menuItems().filter(\.isChecked).map(\.title) == ["150%"])
        s.intensity = 1.5
        #expect(posted.n == 1, "no change, no post")
    }

    @Test func aBrighterIntensityLiftsTheWaveformTrace() {
        var c = ScopeCounts(layout: ScopeLayout())
        // A faint trace over the whole luma waveform (a tenth of the max).
        c.waveformLuma = [UInt32](repeating: 20, count: c.waveformLuma.count)
        c.maxWaveformLuma = 200
        let a = ScopeImage.render(.waveform, c, width: 64, height: 32, intensity: 1)
        let b = ScopeImage.render(.waveform, c, width: 64, height: 32, intensity: 2)
        #expect(b.pixels.reduce(0) { $0 + Int($1) } > a.pixels.reduce(0) { $0 + Int($1) })
    }

    @Test func theCardsWaveformSlotHasASettingsButtonThatOpensTheMenu() throws {
        let p = ScopesPanel()
        p.settings = fresh()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        #expect(p.slots.count == 2 && p.kinds == [.waveform, .vectorscope])
        let b = try #require(p.settingsButton(0))
        #expect(p.settingsButton(1) == nil, "the vectorscope has no waveform settings")
        #expect(b.maxX == p.slots[0].popup.maxX && b.midY == p.slots[0].popup.midY)
        var shown: [SQMenuItem] = []
        p.onMenu = { items, _ in shown = items }
        #expect(p.handle(.mouseDown(x: Float(b.midX), y: Float(b.midY), modifiers: [])))
        #expect(shown.filter { $0.kind == .action }.count == ScopeTraceSettings.steps.count)
        // A right-click on the waveform box opens the same menu; on the vectorscope nothing opens.
        shown = []
        let box = p.slots[0].box
        #expect(p.handle(.mouseDown(x: Float(box.midX), y: Float(box.midY), modifiers: [.secondary])))
        #expect(!shown.isEmpty)
        shown = []
        let vec = p.slots[1].box
        _ = p.handle(.mouseDown(x: Float(vec.midX), y: Float(vec.midY), modifiers: [.secondary]))
        #expect(shown.isEmpty)
        // The tip names the button; switching the first scope to the vectorscope drops it.
        #expect(p.help(at: CGPoint(x: b.midX, y: b.midY)) == ScopeTraceSettings.buttonTip)
        p.select(.vectorscope, at: 0)
        #expect(p.settingsButton(0) == nil)
    }
}
