import Foundation
import Testing
import SQCore
@testable import SQEditorUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(dur)), start: s(start))
}

@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: fd, tracks: tracks)
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}

@MainActor @Suite struct EffectsLookSessionTests {
    @Test func addEffectIsOneUndoStepAndAllowsASecondInstance() {
        let a = clip(0, 5)
        let ses = makeSession([track([a])])
        #expect(ses.addEffect(kind: ClipEffect.gaussianBlurKind, to: [a.id]))
        #expect(ses.addEffect(kind: ClipEffect.gaussianBlurKind, to: [a.id]))
        let effects = ses.activeTimeline!.tracks[0].clips[0].effects
        #expect(effects.count == 2 && effects[0].id != effects[1].id)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].effects.count == 1)
        #expect(ses.undoName == "Add Gaussian Blur")
    }

    @Test func addEffectRefusesAudioAndUnknownKinds() {
        let a = clip(0, 5, kind: .audio)
        let ses = makeSession([track([a], kind: .audio)])
        #expect(!ses.addEffect(kind: ClipEffect.cropKind, to: [a.id]))
        #expect(!ses.addEffect(kind: "nonsense", to: [a.id]))
        #expect(!ses.canUndo)
    }

    @Test func fadeInAndOutOnTheSelectionIsOneUndoStepEach() {
        let a = clip(0, 5)
        let ses = makeSession([track([a])])
        ses.select(clips: [a.id])
        #expect(ses.fadeVideo(.head))
        var keys = ses.activeTimeline!.tracks[0].clips[0].animation.opacity.track.keys
        #expect(keys.map(\.time) == [s(0), s(1)] && keys.map(\.value) == [0, 1])
        #expect(ses.fadeVideo(.tail))
        keys = ses.activeTimeline!.tracks[0].clips[0].animation.opacity.track.keys
        #expect(keys.map(\.time) == [s(0), s(1), s(4), s(5)])
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].animation.opacity.track.keys.count == 2)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].animation.opacity.track.isEmpty)
    }

    @Test func fadeWithoutSelectionUsesTheClipUnderThePlayhead() {
        let a = clip(0, 5), b = clip(5, 5)
        let ses = makeSession([track([a, b])])
        ses.seek(to: s(7))
        #expect(ses.fadeVideo(.head))
        #expect(ses.activeTimeline!.tracks[0].clips[0].animation.opacity.track.isEmpty)
        #expect(ses.activeTimeline!.tracks[0].clips[1].animation.opacity.track.keys.count == 2)
    }

    @Test func fadeOnAnAudioClipDoesNothing() {
        let a = clip(0, 5, kind: .audio)
        let ses = makeSession([track([a], kind: .audio)])
        ses.select(clips: [a.id])
        #expect(!ses.fadeVideo(.head))
    }

    @Test func insertFrameHoldAtThePlayhead() {
        let a = clip(0, 10), b = clip(10, 2)
        let ses = makeSession([track([a, b])])
        ses.seek(to: s(4))
        #expect(ses.insertFrameHold())
        let clips = ses.activeTimeline!.tracks[0].clips
        #expect(clips.count == 4 && clips[1].holdFrame == s(14) && clips[1].timeline == TimeRange(start: s(4), duration: s(2)))
        #expect(clips[3].start == s(12))
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.count == 2)
    }

    @Test func addFrameHoldFreezesTheRest() {
        let a = clip(0, 10)
        let ses = makeSession([track([a])])
        ses.seek(to: s(4))
        #expect(ses.addFrameHold())
        let clips = ses.activeTimeline!.tracks[0].clips
        #expect(clips.count == 2 && clips[1].holdFrame == s(14) && clips[1].timeline.duration == s(6))
        ses.seek(to: s(50))
        #expect(!ses.addFrameHold())
    }

    @Test func pasteAttributesNeedsACopyAndATarget() {
        var a = clip(0, 5)
        a.animation.rotation = AnimatedProperty(30.0)
        _ = a.addEffect(kind: ClipEffect.cropKind)
        let b = clip(5, 5)
        let ses = makeSession([track([a, b])])
        #expect(!ses.canPasteAttributes && !ses.pasteAttributes())
        ses.select(clips: [a.id])
        #expect(ses.copySelection())
        ses.select(clips: [a.id])
        #expect(!ses.canPasteAttributes)                         // the copied clip itself is no target
        ses.select(clips: [b.id])
        #expect(ses.canPasteAttributes)
        #expect(ses.pasteAttributes())
        let out = ses.activeTimeline!.tracks[0].clips[1]
        #expect(out.animation.rotation.value == 30 && out.effects.count == 1 && out.effects[0].id != a.effects[0].id)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[1].effects.isEmpty)
    }

    // MARK: Commands and menu

    @Test func newCommandsAreInTheClipMenuAndMenuOnly() {
        let clipMenu = EditorMenus.clip.commands
        for c in [EditorCommand.addFrameHold, .insertFrameHold, .videoFadeIn, .videoFadeOut] {
            #expect(clipMenu.contains(c))
            #expect(EditorMenus.menuOnly.contains(c))
        }
        #expect(EditorMenus.edit.commands.contains(.pasteAttributes))
    }

    @Test func effectsPanelListsTheNewEffectsInBins() {
        let rows = EffectsPanelView.rows(matching: "")
        #expect(rows.filter(\.isHeader).map(\.title) == ["Blur & Sharpen", "Keying", "Transform"])
        #expect(rows.filter { !$0.isHeader }.map(\.id) == [ClipEffect.gaussianBlurKind, ClipEffect.ultraKeyKind, ClipEffect.cropKind, ClipEffect.roundedCornersKind])
        #expect(EffectsPanelView.rows(matching: "blur").filter { !$0.isHeader }.map(\.title) == ["Gaussian Blur"])
        #expect(EffectsPanelView.catalog.allSatisfy { EffectCatalog.spec(for: $0.id) != nil })
    }

    @Test func fxBadgeDecision() {
        var c = clip(0, 5)
        #expect(FXBadge.state(for: c) == .none)
        c.animation.opacity = AnimatedProperty(0.5)
        #expect(FXBadge.state(for: c) == .applied)
        c.animation.opacity = AnimatedProperty(1.0)
        #expect(FXBadge.state(for: c) == .none)
        _ = c.addEffect(kind: ClipEffect.cropKind)
        #expect(FXBadge.state(for: c) == .applied)
        var audio = clip(0, 5, kind: .audio)
        _ = audio.addEffect(kind: ClipEffect.cropKind)
        #expect(FXBadge.state(for: audio) == .none)
        var blend = clip(0, 5)
        blend.blendMode = .screen
        #expect(FXBadge.state(for: blend) == .applied)
        var moved = clip(0, 5)
        moved.animation.position = AnimatedProperty(Vec2(10, 0))
        #expect(FXBadge.state(for: moved) == .applied)
        #expect(FXBadge.frame(clipRect: CGRect(x: 0, y: 0, width: 20, height: 40), visible: CGRect(x: 0, y: 0, width: 500, height: 40)) == nil)
        let f = FXBadge.frame(clipRect: CGRect(x: 100, y: 10, width: 200, height: 40), visible: CGRect(x: 0, y: 0, width: 500, height: 80))!
        #expect(f.maxX == 297 && f.minY == 12)
        // Right end scrolled out of view: the badge stays inside the visible part.
        let g = FXBadge.frame(clipRect: CGRect(x: 100, y: 10, width: 2000, height: 40), visible: CGRect(x: 0, y: 0, width: 500, height: 80))!
        #expect(g.maxX == 497)
    }
}
