import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsAudioPartnerTests {
    func pair() -> (Clip, Clip) {
        let link = UUID()
        let r = TimeRange(start: .zero, duration: Time(10, 1))
        let v = Clip(name: "v", media: UUID(), kind: .video, source: r, start: Time(5, 1), link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: r, start: Time(5, 1), link: link)
        return (v, a)
    }

    @Test func videoWithPartnerShowsAudioGroupAfterVideoEffects() {
        let (v, a) = pair()
        let m = EffectControlsModel()
        m.setClip(v, audioPartner: a)
        #expect(m.visibleSections == [.motion, .volume])
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], groupHeaders: true)
        #expect(rows.map(\.kind).contains(.group(.audio)))
        m.setClip(v)
        #expect(m.visibleSections == [.motion])
    }

    @Test func volumeEditGoesToThePartnerOnly() {
        let (v, a) = pair()
        let m = EffectControlsModel()
        var video: [Clip] = [], audio: [Clip] = []
        m.onEdit = { c, _, _ in video.append(c) }
        m.onAudioEdit = { c, _, _ in audio.append(c) }
        m.setClip(v, audioPartner: a); m.playhead = Time(6, 1)
        #expect(m.setValue(.volume, to: -6))
        #expect(video.isEmpty)
        #expect(audio.count == 1 && audio[0].id == a.id)
        #expect(audio[0].animation.volume != a.animation.volume)
    }

    @Test func motionEditStaysOnTheVideoClip() {
        let (v, a) = pair()
        let m = EffectControlsModel()
        var video: [Clip] = [], audio: [Clip] = []
        m.onEdit = { c, _, _ in video.append(c) }
        m.onAudioEdit = { c, _, _ in audio.append(c) }
        m.setClip(v, audioPartner: a); m.playhead = Time(6, 1)
        #expect(m.setValue(.rotation, to: 20))
        #expect(audio.isEmpty)
        #expect(video.count == 1 && video[0].id == v.id && video[0].animation.volume == v.animation.volume)
    }
}
