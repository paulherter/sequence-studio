import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// Consolidation step 8: motion, keying, film-look and Voice presets share one type, one apply path, one undo label and
/// one listing path.
@MainActor @Suite struct EffectStackPresetSessionTests {
    private func session(_ tracks: [Track]) -> EditorSession {
        EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: tracks)]),
                      engine: StubProgramEngine())
    }

    /// A video clip with a linked audio clip below it.
    private func linkedPair() -> (EditorSession, Clip, Clip) {
        let link = UUID()
        var v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(6, 1)), start: .zero)
        var a = Clip(name: "a", media: v.media, kind: .audio, source: v.source, start: .zero)
        v.link = link; a.link = link
        var tv = Track(kind: .video), ta = Track(kind: .audio)
        try! tv.overwrite(v); try! ta.overwrite(a)
        return (session([tv, ta]), v, a)
    }

    private func effects(_ s: EditorSession, _ id: Clip.ID) -> [ClipEffect] {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!.effects
    }

    @Test func everyBinAppliesThroughTheOnePathAsOneUndoStep() {
        for p in [EffectStackPresets.preset(id: "greenScreen")!, EffectStackPresets.preset(id: "whipIn")!,
                  FilmPresets.preset(id: "preset.vhs")!, AudioPresets.voice] {
            let (s, v, a) = linkedPair()
            let depth = s.undoDepth
            #expect(s.applyStackPreset(p.id, to: [v.id]), "\(p.id)")
            #expect(s.undoDepth == depth + 1)
            #expect(s.undoName == "Apply Preset “\(p.name)”")
            let target = p.trackKind == .audio ? a.id : v.id, other = p.trackKind == .audio ? v.id : a.id
            #expect(effects(s, target).map(\.kind) == p.effects.map(\.kind), "\(p.id)")
            #expect(effects(s, other).isEmpty, "\(p.id)")
            #expect(s.undo() && effects(s, target).isEmpty)
        }
    }

    @Test func rowIDsFromThePanelAndDropsGoThroughTheSamePath() {
        for p in [EffectStackPresets.preset(id: "greenScreen")!, FilmPresets.preset(id: "preset.badTV")!, AudioPresets.voice] {
            let (s, v, a) = linkedPair()
            #expect(s.addEffect(kind: p.rowID, to: [v.id]), "\(p.rowID)")
            #expect(s.undoName == "Apply Preset “\(p.name)”")
            #expect(effects(s, p.trackKind == .audio ? a.id : v.id).map(\.kind) == p.effects.map(\.kind))
        }
    }

    @Test func withoutIDsThePresetGoesOntoTheSelection() {
        let (s, v, a) = linkedPair()
        s.select(clips: [v.id], captions: [])
        #expect(s.applyStackPreset(AudioPresets.voiceID))
        #expect(effects(s, a.id).count == AudioPresets.voice.effects.count && effects(s, v.id).isEmpty)
    }

    @Test func unknownIDFailsWithAMessage() {
        let (s, v, _) = linkedPair()
        #expect(!s.applyStackPreset("nope", to: [v.id]))
        #expect(s.lastError != nil)
    }

    @Test func everyOfferedPresetIsListedOnceUnderItsBinFolder() {
        let rows = EffectsPanelView.catalog + EffectsPanelView.builtInPresetEntries
        for p in EffectStackPresets.offered {
            let hits = rows.filter { $0.id == p.rowID }
            #expect(hits.count == 1, "\(p.rowID)")
            #expect(hits.first?.title == p.name && hits.first?.category == p.bin.panelCategory, "\(p.rowID)")
        }
        // Today's places: motion and keying in Presets, film looks in Looks, Voice in the audio Presets folder.
        #expect(EffectStackPreset.Bin.looks.panelCategory == "Looks")
        #expect([EffectStackPreset.Bin.motion, .keying, .voice].allSatisfy { $0.panelCategory == "Presets" })
    }

    @Test func hiddenPresetsStillApply() {
        let (s, v, _) = linkedPair()
        #expect(s.applyStackPreset("rgbGlitch", to: [v.id]))
        #expect(effects(s, v.id).count == 2)
    }
}
