import AppKit
import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorUI
@testable import SQInspectorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}

@MainActor private func makeSession() throws -> (EditorSession, Track.ID, [Clip], [Transition.ID]) {
    var v = Track(kind: .video, name: "V1")
    let a = clip(0), b = clip(60), c = clip(120)
    for x in [a, b, c] { try v.overwrite(x) }
    var t = Timeline(name: "Main", frameDuration: fd, tracks: [v])
    let first = try t.addTransition(kind: .push, track: v.id, outgoing: a.id, incoming: b.id, duration: f(12))
    try t.setTransition(first, easing: .fastStart, direction: .up, motionBlur: 1.5)
    let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
    return (ses, v.id, [a, b, c], [first])
}

@MainActor @Suite struct TransitionPresetUITests {
    @Test func savesTheSelectedTransitionAndAppliesItToAnotherCutInOneUndoStep() throws {
        let (ses, track, clips, ids) = try makeSession()
        #expect(ses.presetFromSelectedTransition() == nil)          // nothing selected
        ses.selectTransition(ids[0])
        let preset = try #require(ses.presetFromSelectedTransition())
        let item = try EditorSession.transitionPresetItem(name: "Push up", preset: preset)
        #expect(item.kind == .transition && item.payloadVersion == TransitionPreset.payloadVersion)

        // Apply at the second cut (selected edge), no transition selected.
        ses.selectTransition(nil)
        let edges = EdgeSelection(edges: [EdgeRef(clip: clips[1].id, edge: .tail)])
        #expect(ses.applyTransitionPreset(item, edges: edges))
        let trs = ses.activeTimeline!.tracks[0].transitions
        #expect(trs.count == 2)
        let made = try #require(trs.first { $0.id != ids[0] })
        #expect(made.kind == .push && made.duration == f(12) && made.effectiveEasing == .fastStart)
        #expect(made.effectiveDirection == .up && made.effectiveMotionBlur == 1.5)
        #expect(made.outgoing == clips[1].id && made.incoming == clips[2].id)
        #expect(ses.undoName == "Apply Transition Preset “Push up”")
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].transitions.count == 1)
        _ = track
    }

    @Test func appliesToTheSelectedTransitionInPlace() throws {
        let (ses, _, _, ids) = try makeSession()
        let preset = TransitionPreset(kind: .crossDissolve, duration: f(6), easing: .linear)
        let item = try EditorSession.transitionPresetItem(name: "Short dissolve", preset: preset)
        ses.selectTransition(ids[0])
        #expect(ses.applyPreset(item))                              // generic entry point dispatches on kind
        let tr = ses.activeTimeline!.tracks[0].transitions[0]
        #expect(tr.id == ids[0] && tr.kind == .crossDissolve && tr.duration == f(6))
    }

    @Test func reapplyingIdenticalPresetInPlaceSucceedsWithoutMessage() throws {
        let (ses, _, _, ids) = try makeSession()
        ses.selectTransition(ids[0])
        let item = try EditorSession.transitionPresetItem(name: "Same", preset: try #require(ses.presetFromSelectedTransition()))
        ses.clearError()
        #expect(ses.applyTransitionPreset(item, edges: nil))
        #expect(ses.lastError == nil || ses.lastError?.isEmpty == true)
    }

    @Test func audioPresetOnVideoTransitionIsRefusedWithMessage() throws {
        let (ses, _, _, ids) = try makeSession()
        let item = try EditorSession.transitionPresetItem(name: "Fade", preset: TransitionPreset(kind: .constantPower, duration: f(10)))
        ses.selectTransition(ids[0])
        #expect(!ses.applyTransitionPreset(item, edges: nil))
        #expect(ses.lastError?.isEmpty == false)
        #expect(ses.activeTimeline!.tracks[0].transitions[0].kind == .push)
    }

    @Test func damagedOrWrongKindItemsAreRefused() throws {
        let (ses, _, _, _) = try makeSession()
        let bad = PresetItem(kind: .transition, name: "Bad", payload: Data("{}".utf8), payloadVersion: 1)
        #expect(!ses.applyTransitionPreset(bad, edges: nil))
        let newer = PresetItem(kind: .transition, name: "New", payload: Data("{}".utf8), payloadVersion: 99)
        #expect(!ses.applyTransitionPreset(newer, edges: nil))
        let easing = PresetItem(kind: .easing, name: "E", payload: Data(), payloadVersion: 1)
        #expect(!ses.applyTransitionPreset(easing, edges: nil))
    }

    @Test func controlsSaveButtonReportsClick() throws {
        let (ses, _, _, ids) = try makeSession()
        let info = try #require(ses.transitionInfo(ids[0]))
        let c = TransitionControlsView()
        c.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        c.update(transition: info.transition, resolved: info.resolved, frameDuration: fd)
        var clicked = 0
        c.onSavePreset = { clicked += 1 }
        let views = c.subviews.flatMap { v -> [NSView] in [v] + v.subviews.flatMap { [$0] + $0.subviews } }
        let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Save as Preset…" })
        button.performClick(nil)
        #expect(clicked == 1)
    }

    @Test func quickApplyListsTransitionPresetsAndResolvesThem() {
        let item = PresetItem(kind: .transition, name: "Push up", payload: Data(), payloadVersion: 1)
        let items = QuickApplyCatalog.items(presets: [item])
        let row = items.first { $0.title == "Push up" }
        #expect(row?.category == "Transition Preset")
        #expect(QuickApplyTarget.resolve(row!, selectedVideoClips: []) == .preset(item.id, .transition))
    }
}
