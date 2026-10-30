import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

// AUDIO-FX: the Audio group of Effect Controls shows Volume, then the audio clip's effects in list order. Under a linked
// video clip, the partner's audio effects are shown and their edits go to the partner.

@MainActor @Suite struct EffectControlsAudioFXTests {
    func pair() -> (Clip, Clip) {
        let link = UUID()
        let r = TimeRange(start: .zero, duration: Time(10, 1))
        var v = Clip(name: "v", media: UUID(), kind: .video, source: r, start: Time(5, 1), link: link)
        _ = v.addEffect(kind: ClipEffect.gaussianBlurKind)
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: r, start: Time(5, 1), link: link)
        _ = a.addEffect(kind: ClipEffect.audioEQKind)
        _ = a.addEffect(kind: ClipEffect.audioGainKind)
        return (v, a)
    }

    @Test func audioClipShowsVolumeThenItsEffects() {
        let (_, a) = pair()
        let m = EffectControlsModel()
        m.setClip(a)
        let fx = a.effects.map { EffectSection.effect($0.id, kind: $0.kind) }
        #expect(m.visibleSections == [.volume] + fx)
        #expect(m.visibleSections.allSatisfy { EffectControlsLayout.group(of: $0) == .audio })
    }

    @Test func linkedVideoShowsThePartnersAudioEffectsInTheAudioGroup() {
        let (v, a) = pair()
        let m = EffectControlsModel()
        m.setClip(v, audioPartner: a)
        let blur = EffectSection.effect(v.effects[0].id, kind: v.effects[0].kind)
        let fx = a.effects.map { EffectSection.effect($0.id, kind: $0.kind) }
        #expect(m.visibleSections == [.motion, blur, .volume] + fx)
        #expect(EffectControlsLayout.group(of: blur) == .video)
        #expect(fx.allSatisfy { EffectControlsLayout.group(of: $0) == .audio })
    }

    @Test func audioEffectEditsGoToThePartnerOnly() {
        let (v, a) = pair()
        let m = EffectControlsModel()
        var video: [Clip] = [], audio: [Clip] = []
        m.onEdit = { c, _, _ in video.append(c) }
        m.onAudioEdit = { c, _, _ in audio.append(c) }
        m.setClip(v, audioPartner: a); m.playhead = Time(6, 1)
        let gain = EffectSection.effect(a.effects[1].id, kind: ClipEffect.audioGainKind)
        m.setEffectEnabled(gain, false)
        #expect(video.isEmpty)
        #expect(audio.count == 1 && audio[0].id == a.id && audio[0].effects[1].enabled == false)
        #expect(audio[0].effects.count == 2)
        #expect(m.removeEffect(EffectSection.effect(a.effects[0].id, kind: ClipEffect.audioEQKind)))
        #expect(video.isEmpty)
        #expect(audio.last?.effects.map(\.kind) == [ClipEffect.audioGainKind])
    }

    @Test func videoEffectEditsDoNotCarryTheAudioEffects() {
        let (v, a) = pair()
        let m = EffectControlsModel()
        var video: [Clip] = [], audio: [Clip] = []
        m.onEdit = { c, _, _ in video.append(c) }
        m.onAudioEdit = { c, _, _ in audio.append(c) }
        m.setClip(v, audioPartner: a)
        m.setEffectEnabled(EffectSection.effect(v.effects[0].id, kind: v.effects[0].kind), false)
        #expect(audio.isEmpty)
        #expect(video.count == 1 && video[0].effects.count == 1 && !video[0].effects[0].isAudio)
    }

    /// L-cut: the audio starts 2 s after the video. Keys are clip-local, so the partner's keys are shown 2 s later in the
    /// video clip's time base and go back to the audio clip's time base on an edit.
    @Test func partnerKeysFollowTheStartOffset() throws {
        var (v, a) = pair()
        a.start = v.start + Time(2, 1)
        var gain = AnimatedProperty(0.0)
        gain.track.insert(Keyframe(time: Time(1, 1), value: -6))
        a.effects[1].parameters[ClipEffect.audioGainKey] = gain
        var vol = AnimatedProperty(1.0)
        vol.track.insert(Keyframe(time: Time(3, 1), value: 0.5))
        a.animation.volume = vol
        let m = EffectControlsModel()
        var audio: [Clip] = []
        m.onAudioEdit = { c, _, _ in audio.append(c) }
        m.setClip(v, audioPartner: a)
        let shown = try #require(m.clip)
        let fx = try #require(shown.effects.first { $0.id == a.effects[1].id })
        #expect(fx.parameters[ClipEffect.audioGainKey]?.track.keys.map(\.time) == [Time(3, 1)])
        #expect(shown.animation.volume.track.keys.map(\.time) == [Time(5, 1)])
        m.setEffectEnabled(EffectSection.effect(a.effects[0].id, kind: ClipEffect.audioEQKind), false)
        let back = try #require(audio.last)
        #expect(back.effects[1].parameters[ClipEffect.audioGainKey]?.track.keys.map(\.time) == [Time(1, 1)])
        #expect(back.animation.volume == a.animation.volume)
        #expect(back.effects[0].enabled == false)
    }
}

@MainActor @Suite struct AudioFXPanelAndPaletteTests {
    @Test func effectsPanelHasAnAudioEffectsFolder() {
        let rows = EffectFolderOutline.rows(entries: EffectsPanelView.catalog, store: EffectFolderStore(), expanded: [], query: "")
        let tops = rows.filter { $0.isFolder && $0.depth == 0 }.map(\.title)
        #expect(tops == ["Presets", "Video", "Transitions", "Audio", "Crossfades"])
        let search = EffectFolderOutline.rows(entries: EffectsPanelView.catalog, store: EffectFolderStore(), expanded: [], query: "de-ess")
        #expect(search.map(\.title) == ["Audio", "Level", "De-Esser"])
        for e in EffectCatalog.audio { #expect(EffectsPanelView.catalog.contains { $0.id == e.kind }) }
    }

    @Test func paletteListsAudioEffectsAndTargetsAudioClips() throws {
        let items = QuickApplyCatalog.items(presets: [])
        let eq = try #require(items.first { $0.action == .effect(ClipEffect.audioParametricEQKind) })
        #expect(eq.category == "Audio Effect")
        let a = UUID(), v = UUID()
        #expect(QuickApplyTarget.resolve(eq, selectedVideoClips: [v], audioTargets: [a]) == .effect(kind: ClipEffect.audioParametricEQKind, clips: [a]))
        guard case .refused = QuickApplyTarget.resolve(eq, selectedVideoClips: [v], audioTargets: []) else { Issue.record("not refused"); return }
    }
}

@MainActor @Suite struct AudioFXSessionTests {
    private func session() -> (EditorSession, Clip, Clip, Clip) {
        let link = UUID(), fd = Time(1, 30)
        let r = TimeRange(start: .zero, duration: Time(10, 1))
        let v = Clip(name: "v", media: UUID(), kind: .video, source: r, start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: r, start: .zero, link: link)
        let lone = Clip(name: "lone", media: UUID(), kind: .video, source: r, start: Time(20, 1))
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try! vt.overwrite(v); try! vt.overwrite(lone); try! at.overwrite(a)
        let t = Timeline(name: "Main", frameDuration: fd, tracks: [vt, at])
        return (EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine()), v, a, lone)
    }
    private func clip(_ s: EditorSession, _ id: Clip.ID) -> Clip? { s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id } }

    @Test func audioEffectOnAnAudioClipIsOneUndoStep() {
        let (s, _, a, _) = session()
        #expect(s.addEffect(kind: ClipEffect.audioCompressorKind, to: [a.id]))
        #expect(clip(s, a.id)?.effects.map(\.kind) == [ClipEffect.audioCompressorKind])
        #expect(s.undoName == "Add Compressor")
        #expect(s.undo())
        #expect(clip(s, a.id)?.effects.isEmpty == true)
    }

    @Test func audioEffectDroppedOnALinkedVideoClipGoesToItsAudio() {
        let (s, v, a, _) = session()
        #expect(s.addEffect(kind: ClipEffect.audioDeEsserKind, to: [v.id]))
        #expect(clip(s, v.id)?.effects.isEmpty == true)
        #expect(clip(s, a.id)?.effects.map(\.kind) == [ClipEffect.audioDeEsserKind])
    }

    @Test func audioEffectNeedsAnAudioClip() {
        let (s, _, _, lone) = session()
        #expect(!s.addEffect(kind: ClipEffect.audioGainKind, to: [lone.id]))
    }

    /// Cmd-V of a copied audio effect with the linked video clip selected: the copy lands on its audio.
    @Test func pastedAudioEffectOnALinkedVideoClipGoesToItsAudio() throws {
        let (s, v, a, lone) = session()
        #expect(s.addEffect(kind: ClipEffect.audioGainKind, to: [a.id]))
        s.effectClipboard = try #require(clip(s, a.id)?.effects.first)
        s.select(clips: [v.id])
        #expect(s.canPasteEffectClipboard)
        #expect(s.pasteEffectClipboard())
        #expect(clip(s, v.id)?.effects.isEmpty == true)
        #expect(clip(s, a.id)?.effects.map(\.kind) == [ClipEffect.audioGainKind, ClipEffect.audioGainKind])
        s.select(clips: [lone.id])
        #expect(!s.canPasteEffectClipboard)
        #expect(!s.pasteEffectClipboard())
    }

    @Test func videoEffectNeverLandsOnAudio() {
        let (s, _, a, _) = session()
        #expect(!s.addEffect(kind: ClipEffect.gaussianBlurKind, to: [a.id]))
    }
}
