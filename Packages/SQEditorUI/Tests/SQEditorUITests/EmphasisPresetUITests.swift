import AppKit
import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorUI
@testable import SQInspectorUI

private let names = ["Ghost Frame", "Whip In", "Elastic Pop", "Bounce In", "Spin In", "Slide In Overshoot", "Caption Pop"]

@MainActor @Suite struct EmphasisPresetUITests {
    @Test func listedInThePanelAndFoundInThePalette() {
        let items = QuickApplyCatalog.items(presets: [])
        for n in names {
            #expect(EffectsPanelView.builtInPresetEntries.contains { $0.title == n }, "\(n) in the Effects panel")
            let hits = QuickApplyRanking.rank(items, query: n, recents: [], limit: 5)
            #expect(hits.first?.title == n && hits.first?.category == "Preset", "\(n) first palette hit")
        }
    }

    @Test func hiddenDuplicatesAreNotListedAnywhere() {
        let items = QuickApplyCatalog.items(presets: [])
        let titles = Set(EffectsPanelView.catalog.map(\.title) + EffectsPanelView.builtInPresetEntries.map(\.title))
        for n in ["Punch-In", "Camera Shake", "Move From Left", "Slide In", "Whip Blur In", "Vignette", "Brightness & Contrast",
                  "Black & White", "Noise", "Gain"] {
            #expect(!titles.contains(n), "\(n) in the Effects panel")
            #expect(!items.contains { $0.title == n }, "\(n) in the palette")
        }
        #expect(!EffectsPanelView.catalog.contains { $0.id == ClipEffect.audioEQKind }, "3-band EQ hidden; the 5-band is the one EQ")
        for k in HiddenCatalog.effectKinds { #expect(!EffectsPanelView.catalog.contains { $0.id == k }, "\(k)") }
    }

    @Test func oneClickIsOneUndoStep() throws {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(6, 1)), start: .zero)
        var t = Track(kind: .video)
        try t.overwrite(c)
        let ses = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [t])]),
                                engine: StubProgramEngine())
        let id = MotionPresets.builtIn(named: "RGB Glitch")!.id   // hidden, still applies
        #expect(ses.applyStackPreset(id, to: [c.id]))
        #expect(ses.activeTimeline!.tracks[0].clips[0].effects.count == 2)
        #expect(ses.undoName == "Apply Preset “RGB Glitch”")
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].effects.isEmpty)
    }
}
