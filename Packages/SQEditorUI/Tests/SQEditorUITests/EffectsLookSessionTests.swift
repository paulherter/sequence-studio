import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

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
        #expect(ses.undoName == "Add Blur")
    }

    @Test func dropShadowAppliesWithDefaultsAndShowsItsRows() {
        let a = clip(0, 5)
        let ses = makeSession([track([a])])
        #expect(ses.addEffect(kind: ClipEffect.dropShadowKind, to: [a.id]))
        let e = ses.activeTimeline!.tracks[0].clips[0].effects[0]
        #expect(e.kind == ClipEffect.dropShadowKind && e.parameters.count == 6 && e.colors.count == 1)
        #expect(ses.undoName == "Add Drop Shadow")
        #expect(EffectCatalog.spec(for: ClipEffect.dropShadowKind)!.params.map(\.title) == ["Shadow Color", "Opacity", "Direction", "Distance", "Spread", "Softness", "Shadow Only"])
    }

    @Test func copiedEffectPastesOntoSelectedClipsWithoutEffectControls() {
        let a = clip(0, 5), b = clip(5, 5), c = clip(10, 5)
        let ses = makeSession([track([a, b, c])])
        #expect(ses.addEffect(kind: ClipEffect.gaussianBlurKind, to: [a.id]))
        #expect(!ses.canPasteEffectClipboard && !ses.pasteEffectClipboard())
        ses.effectClipboard = ses.activeTimeline!.tracks[0].clips[0].effects[0]
        ses.select(clips: [b.id, c.id], captions: [])
        #expect(ses.canPasteEffectClipboard && ses.pasteEffectClipboard())
        let clips = ses.activeTimeline!.tracks[0].clips
        #expect(clips[1].effects.count == 1 && clips[2].effects.count == 1 && clips[1].effects[0].id != clips[0].effects[0].id)
        #expect(ses.undoName == "Paste Effect")
        #expect(ses.undo() && ses.activeTimeline!.tracks[0].clips[1].effects.isEmpty && ses.activeTimeline!.tracks[0].clips[2].effects.isEmpty)
        // Copying clips afterwards makes the clip clipboard the current one again.
        ses.select(clips: [b.id], captions: [])
        #expect(ses.copySelection() && ses.effectClipboard == nil)
    }

    @Test func applyingAPresetAddsItsWholeStackAsOneUndoStep() {
        let a = clip(0, 5), b = clip(5, 5)
        let ses = makeSession([track([a, b])])
        #expect(ses.addEffect(kind: "preset.vhs", to: [a.id]))
        let vhs = FilmPresets.preset(id: "preset.vhs")!
        #expect(ses.activeTimeline!.tracks[0].clips[0].effects.map(\.kind) == vhs.effects.map(\.kind))
        #expect(ses.activeTimeline!.tracks[0].clips[1].effects.isEmpty)
        #expect(ses.undoName == "Apply Preset “VHS”")   // one label with every preset (consolidation step 8)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].effects.isEmpty)
        #expect(ses.addEffect(kind: ClipEffect.grainKind, to: [a.id]))      // single effects still work
        #expect(ses.activeTimeline!.tracks[0].clips[0].effects.count == 1)
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
        let rows = EffectsPanelView.rows(matching: "", in: EffectsPanelView.videoEntries)
        #expect(rows.filter(\.isHeader).map(\.title) == ["Blur", "Adjust", "Distort", "Cutout", "Grain", "Stylize", "Transform", "Motion", "Repair", "Time"])
        #expect(rows.filter { !$0.isHeader }.map(\.id) == [ClipEffect.gaussianBlurKind, ClipEffect.directionalBlurKind, ClipEffect.radialBlurKind, ClipEffect.motionBlurKind,
                                                             ClipEffect.sharpenKind, ClipEffect.unsharpMaskKind, ClipEffect.invertKind,
                                                             ClipEffect.colorKind, ClipEffect.brightnessContrastKind, ClipEffect.tintKind, ClipEffect.blackAndWhiteKind,
                                                             ClipEffect.lensDistortionKind, ClipEffect.mirrorKind, ClipEffect.spherizeKind, ClipEffect.twirlKind, ClipEffect.waveWarpKind, ClipEffect.tileKind, ClipEffect.kaleidoscopeKind, ClipEffect.cornerPinKind, ClipEffect.glitchKind,
                                                             ClipEffect.alphaAdjustKind, ClipEffect.ultraKeyKind, ClipEffect.lumaKeyKind, ClipEffect.trackMaskKind,
                                                             ClipEffect.grainKind, ClipEffect.noiseKind,
                                                             ClipEffect.dropShadowKind, ClipEffect.longShadowKind, ClipEffect.outlineKind, ClipEffect.glowKind, ClipEffect.gradientKind, ClipEffect.lightLeakKind, ClipEffect.mosaicKind, ClipEffect.halftoneKind, ClipEffect.edgeFeatherKind, ClipEffect.posterizeKind,
                                                             ClipEffect.rgbSplitKind, ClipEffect.strobeKind, ClipEffect.vignetteKind, ClipEffect.dateStampKind,
                                                             ClipEffect.cropKind, ClipEffect.horizontalFlipKind, ClipEffect.roundedCornersKind, ClipEffect.stabilizeKind,
                                                             ClipEffect.transformKind, ClipEffect.verticalFlipKind,
                                                             ClipEffect.shakeKind, ClipEffect.bounceKind, ClipEffect.pulseKind, ClipEffect.wiggleKind,
                                                             ClipEffect.videoDenoiseKind, ClipEffect.deflickerKind, ClipEffect.posterizeTimeKind, ClipEffect.trailsKind])
        #expect(EffectsPanelView.rows(matching: "blur").filter { !$0.isHeader }.map(\.title) == ["Blur", "Directional Blur", "Radial Blur", "Motion Blur", "Blur Dissolve"])   // the bin name matches
        #expect(EffectsPanelView.catalog.filter { EffectsPanelView.transitionKind(forID: $0.id) == nil }.allSatisfy { EffectCatalog.spec(for: $0.id) != nil || FilmPresets.preset(id: $0.id) != nil || AudioPresets.preset(id: $0.id) != nil })
        let looks = EffectsPanelView.rows(matching: "", in: EffectsPanelView.lookEntries)
        #expect(looks.filter(\.isHeader).map(\.title) == ["Looks", "Film", "Tape & TV"])
        #expect(looks.filter { !$0.isHeader }.prefix(3).map(\.title) == ["Film Look", "VHS", "Bad TV"])
        #expect(EffectsPanelView.rows(matching: "weave").filter { !$0.isHeader }.map(\.id) == [ClipEffect.gateWeaveKind])
        #expect(EffectsPanelView.rows(matching: "tape").filter { !$0.isHeader }.count == 3)
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
        #expect(FXBadge.frame(clipRect: CGRect(x: 0, y: 0, width: 10, height: 40), visible: CGRect(x: 0, y: 0, width: 500, height: 40)) == nil)
        let f = FXBadge.frame(clipRect: CGRect(x: 100, y: 10, width: 200, height: 40), visible: CGRect(x: 0, y: 0, width: 500, height: 80))!
        #expect(f.maxX == 296 && f.minY == 14)
        // Right end scrolled out of view: the badge stays inside the visible part.
        let g = FXBadge.frame(clipRect: CGRect(x: 100, y: 10, width: 2000, height: 40), visible: CGRect(x: 0, y: 0, width: 500, height: 80))!
        #expect(g.maxX == 496)
    }
}

@MainActor @Suite struct PasteAttributesSelectionTests {
    @Test func onlyMotionKeepsTargetOpacityAndEffects() {
        var a = clip(0, 5)
        a.animation.rotation = AnimatedProperty(30.0)
        a.animation.opacity = AnimatedProperty(0.25)
        _ = a.addEffect(kind: ClipEffect.cropKind)
        var b = clip(5, 5)
        b.animation.opacity = AnimatedProperty(0.8)
        let out = b.pastingAttributes(from: a, groups: [.motion])
        #expect(out.animation.rotation.value == 30)
        #expect(out.animation.opacity.value == 0.8)
        #expect(out.effects.isEmpty)
    }

    @Test func emptySelectionChangesNothingAndAudioGroupsIgnoreVideo() {
        var a = clip(0, 5); a.animation.rotation = AnimatedProperty(30.0)
        let b = clip(5, 5)
        #expect(b.pastingAttributes(from: a, groups: []) == b)
        #expect(b.pastingAttributes(from: a, groups: [.volume]) == b)
        #expect(PasteAttributeGroup.groups(for: .audio) == [.volume])
    }

    @Test func sessionPastesOnlyChosenGroupsInOneUndoStep() {
        var a = clip(0, 5)
        a.animation.rotation = AnimatedProperty(30.0)
        a.animation.opacity = AnimatedProperty(0.25)
        let b = clip(5, 5)
        let ses = makeSession([track([a, b])])
        ses.select(clips: [a.id]); #expect(ses.copySelection())
        ses.select(clips: [b.id])
        #expect(ses.pasteAttributeChoices == [.motion, .opacity, .effects, .color])
        #expect(ses.pasteAttributes(groups: [.motion]))
        let out = ses.activeTimeline!.tracks[0].clips[1]
        #expect(out.animation.rotation.value == 30 && out.animation.opacity.value == 1)
        #expect(!ses.pasteAttributes(groups: []))
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[1].animation.rotation.value == 0)
    }
}

@MainActor @Suite struct PasteAttributesColorIndependenceTests {
    private func source() -> Clip {
        var a = clip(0, 5)
        _ = a.addEffect(kind: ClipEffect.colorKind)
        _ = a.addEffect(kind: ClipEffect.cropKind)
        let i = a.effects.firstIndex { $0.isColor }!
        a.effects[i].enabled = false
        a.effects[i].parameters[ClipEffect.colorExposureKey]?.track.insert(Keyframe(time: s(1), value: 0.5))
        a.effects[i].parameters[ClipEffect.colorExposureKey]?.track.insert(Keyframe(time: s(2), value: 1.0))
        a.animation.rotation = AnimatedProperty(30.0)
        return a
    }
    private func target() -> Clip {
        var b = clip(5, 5)
        _ = b.addEffect(kind: ClipEffect.colorKind)
        _ = b.addEffect(kind: ClipEffect.gaussianBlurKind)
        return b
    }

    @Test func effectsOnlyKeepsTheTargetGrade() {
        let b = target()
        let out = b.pastingAttributes(from: source(), groups: [.effects])
        let grade = out.colorGradeEffects, old = b.colorGradeEffects
        #expect(grade.count == 1 && grade[0].enabled && grade[0].parameters == old[0].parameters)
        #expect(out.effects.contains { $0.kind == ClipEffect.cropKind })
    }

    @Test func colorOnlyKeepsTargetEffectsAndCarriesKeysAndSwitch() {
        let b = target()
        let out = b.pastingAttributes(from: source(), groups: [.color])
        let grade = out.colorGradeEffects
        #expect(grade.count == 1 && !grade[0].enabled)
        #expect(grade[0].parameters[ClipEffect.colorExposureKey]?.track.keys.count == 2)
        #expect(out.effects.filter { !$0.isColor }.map(\.id) == b.effects.filter { !$0.isColor }.map(\.id))
        #expect(out.animation.rotation.value == 0)
    }

    @Test func allGroupsEqualTheFullPaste() {
        let b = target(), a = source()
        let full = b.pastingAttributes(from: a)
        let out = b.pastingAttributes(from: a, groups: Set(PasteAttributeGroup.allCases))
        #expect(out.effects.map(\.kind) == full.effects.map(\.kind))
        #expect(out.colorGradeEffects.map(\.enabled) == full.colorGradeEffects.map(\.enabled))
        #expect(out.colorGradeEffects[0].parameters == full.colorGradeEffects[0].parameters)
        #expect(out.animation.rotation == full.animation.rotation && out.footageColor == full.footageColor)
    }
}

@MainActor @Suite struct EffectDropAndUndoRevealTests {
    @Test func dropOnSelectedClipTargetsWholeSelectionAsOneStep() {
        let a = clip(0, 5), b = clip(5, 5), c = clip(10, 5)
        let ses = makeSession([track([a, b, c])])
        ses.select(clips: [a.id, b.id])
        #expect(ses.effectDropTargets(hit: a.id) == [a.id, b.id])
        #expect(ses.effectDropTargets(hit: c.id) == [c.id])
        #expect(ses.addEffect(kind: ClipEffect.gaussianBlurKind, to: ses.effectDropTargets(hit: b.id)))
        let clips = ses.activeTimeline!.tracks[0].clips
        #expect(clips.map(\.effects.count) == [1, 1, 0])
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.allSatisfy { $0.effects.isEmpty })
        #expect(!ses.canUndo)
    }

    @Test func undoMovesPlayheadAndSelectionToTheChange() {
        let a = clip(0, 5), b = clip(100, 5)
        let ses = makeSession([track([a, b])])
        ses.seek(to: s(100))
        #expect(ses.addEffect(kind: ClipEffect.gaussianBlurKind, to: [a.id]))
        ses.select(clips: [b.id])
        ses.seek(to: s(103))
        #expect(ses.undo())
        #expect(ses.selection == [a.id])
        #expect(ses.playhead == s(0))
        #expect(ses.revealRange == TimeRange(start: s(0), duration: s(5)))
        #expect(ses.redo())
        #expect(ses.playhead == s(0))
    }

    @Test func undoKeepsPlayheadWhenAlreadyInsideTheChange() {
        let a = clip(0, 10)
        let ses = makeSession([track([a])])
        #expect(ses.addEffect(kind: ClipEffect.gaussianBlurKind, to: [a.id]))
        ses.seek(to: s(4))
        #expect(ses.undo())
        #expect(ses.playhead == s(4))
    }
}
