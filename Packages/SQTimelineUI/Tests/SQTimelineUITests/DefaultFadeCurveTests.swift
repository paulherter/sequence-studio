import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

@Suite struct DefaultFadeCurveTests {
    private let fd = Time(1, 30)
    private let rect = CGRect(x: 100, y: 0, width: 400, height: 60)
    private var clip: Clip {
        Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
    }

    @Test func settingIsReadAndFallsBackToLinear() {
        let d = UserDefaults(suiteName: "sq.test.fadecurve.\(UUID().uuidString)")!
        #expect(DefaultFadeCurve.current(d) == .linear)
        d.set("plus3dB", forKey: DefaultFadeCurve.defaultsKey)
        #expect(DefaultFadeCurve.current(d) == .plus3dB)
        d.set("nonsense", forKey: DefaultFadeCurve.defaultsKey)
        #expect(DefaultFadeCurve.current(d) == .linear)
    }

    @Test func newFadeGetsTheDefaultCurve() {
        let c = VolumeLine.clip(clip, dragging: .head, from: .zero, dx: 40, clipRect: rect, frameDuration: fd, defaultCurve: .sCurve)
        #expect(c.audioFadeInCurve == .sCurve)
        let t = VolumeLine.clip(clip, dragging: .tail, from: .zero, dx: -40, clipRect: rect, frameDuration: fd, defaultCurve: .minus3dB)
        #expect(t.audioFadeOutCurve == .minus3dB)
    }

    @Test func existingFadeKeepsItsOwnCurve() {
        var c = clip
        c.setAudioFadeIn(Time(1, 1), frameDuration: fd)
        c.setAudioFadeCurve(.plus3dB, head: true)
        let longer = VolumeLine.clip(c, dragging: .head, from: Time(1, 1), dx: 40, clipRect: rect, frameDuration: fd, defaultCurve: .sCurve)
        #expect(longer.audioFadeInCurve == .plus3dB)
        #expect(longer.audioFadeIn == Time(2, 1))
    }

    @Test func linearDefaultAndSubFrameDragStayPlain() {
        let c = VolumeLine.clip(clip, dragging: .head, from: .zero, dx: 40, clipRect: rect, frameDuration: fd)
        #expect(c.audioFadeInCurve == .linear)
        let tiny = VolumeLine.clip(clip, dragging: .head, from: .zero, dx: 0.5, clipRect: rect, frameDuration: fd, defaultCurve: .sCurve)
        #expect(tiny.animation == clip.animation)
    }
}
