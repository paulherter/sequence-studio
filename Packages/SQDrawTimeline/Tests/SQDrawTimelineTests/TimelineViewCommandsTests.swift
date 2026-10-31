import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

private func clip(_ start: Int64, _ frames: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * frames), start: fd * start)
}

/// V1 with two clips, V2, A1 in a session; a 1000 x 400 pt panel synced to it.
@MainActor private func setup() -> (TimelinePanel, EditorSession, UserDefaults) {
    let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(0, 50), clip(100, 50)]),
                                                         Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    sync(&p, s)
    let d = UserDefaults(suiteName: "sq.test.viewcommands.\(UUID().uuidString)")!
    return (p, s, d)
}

@MainActor private func sync(_ p: inout TimelinePanel, _ s: EditorSession) {
    p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
}

@MainActor @Suite struct TimelineViewCommandsTests {
    @Test func theToolsMenuPicksTheToolAndTheSlipVariant() {
        var (p, s, d) = setup()
        #expect(p.runViewCommand(.tool(.razor), session: s, defaults: d) == "Blade Tool")
        #expect(p.toolState.tool == .razor)
        #expect(p.runViewCommand(.slipKeyframesStayTool, session: s, defaults: d) != nil)
        #expect(p.toolState.tool == .slip && p.toolState.slipKeyframesStay)
        _ = p.runViewCommand(.tool(.slip), session: s, defaults: d)
        #expect(!p.toolState.slipKeyframesStay)
    }

    @Test func addMarkerTwiceOpensTheMarkerEditor() {
        var (p, s, d) = setup()
        var opened: [TimelineEditorRequest] = []
        let host = TimelineHost()
        host.open = { opened.append($0); return true }
        #expect(p.runViewCommand(.addMarker, session: s, host: host, defaults: d) == "")
        #expect(s.activeTimeline!.markers.count == 1 && opened.isEmpty)
        _ = p.runViewCommand(.addMarker, session: s, host: host, defaults: d)
        #expect(s.activeTimeline!.markers.count == 1 && opened.count == 1)
    }

    @Test func snappingToggleIsSavedWithTheSequenceAndUndoBringsItBack() {
        var (p, s, d) = setup()
        #expect(p.toolState.snapping)
        #expect(p.runViewCommand(.toggleSnapping, session: s, defaults: d) == "Snapping off")
        #expect(!p.toolState.snapping && s.activeTimeline!.snappingOn == false)
        #expect(d.object(forKey: ToolState.snappingDefaultsKey) as? Bool == false)
        s.undo()
        sync(&p, s)
        p.syncToggles(session: s)
        #expect(p.toolState.snapping)
    }

    @Test func linkedSelectionToggleReachesTheSession() {
        var (p, s, d) = setup()
        #expect(p.runViewCommand(.toggleLinkedSelection, session: s, defaults: d) == "Linked Selection off")
        #expect(!s.linkedSelection && s.activeTimeline!.linkedSelectionOn == false && !p.toolState.linkedSelection)
    }

    @Test func fastCutToggleSaysTheMode() {
        var (p, s, d) = setup()
        #expect(p.runViewCommand(.toggleMagnetic, session: s, defaults: d)?.hasPrefix("Fast Cut:") == true)
        #expect(s.activeTimeline!.editMode == .magnetic)
        #expect(p.runViewCommand(.toggleMagnetic, session: s, defaults: d) == "Normal: classic tracks")
    }

    @Test func edgeCommandsSelectTrimAndCycle() {
        var (p, s, d) = setup()
        #expect(p.runViewCommand(.trimBackward, session: s, defaults: d) == TimelinePanel.needEditLine)
        #expect(p.runViewCommand(.selectRightEdge, session: s, defaults: d) == "Select a clip first.")
        let first = s.activeTimeline!.tracks[0].clips[0].id
        s.select(clips: [first], captions: [])
        sync(&p, s)
        #expect(p.runViewCommand(.selectRightEdge, session: s, defaults: d) == "")
        #expect(p.interaction.edgeSelection?.edges.first == EdgeRef(clip: first, edge: .tail))
        #expect(p.runViewCommand(.trimBackward, session: s, defaults: d) == StepStatus.line("Trim", frames: -1))
        #expect(s.activeTimeline!.tracks[0].clips[0].duration == fd * 49)
        let before = p.interaction.edgeSelection
        #expect(p.runViewCommand(.toggleTrimType, session: s, defaults: d) == "")
        #expect(p.interaction.edgeSelection != before)
    }

    @Test func heightCommandsTurnFitOffAndKeepThePreset() {
        var (p, s, d) = setup()
        p.geometry.fitAllTracks = true
        let v1 = s.activeTimeline!.tracks[0].id
        let h = p.rows.first { $0.track == v1 }!.height
        #expect(p.runViewCommand(.videoTracksTaller, session: s, defaults: d) == "")
        #expect(!p.geometry.fitAllTracks && d.object(forKey: TimelinePanel.fitTracksDefaultsKey) as? Bool == false)
        #expect(p.rows.first { $0.track == v1 }!.height > h)
        #expect(p.runViewCommand(.trackHeightSmall, session: s, defaults: d) == "")
        #expect(p.geometry.heightMode == .small && p.geometry.heightOverrides.isEmpty)
        #expect(d.string(forKey: TimelinePanel.heightModeDefaultsKey) == "small")
        #expect(p.runViewCommand(.toggleFitTracks, session: s, defaults: d) == "")
        #expect(p.geometry.fitAllTracks)
        var q = TimelinePanel()
        q.loadHeightPrefs(d)
        #expect(q.geometry.heightMode == .small && q.geometry.fitAllTracks)
        // Opening a sequence keeps the app-wide preset (a fresh geometry used to fall back to auto stretch).
        q.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        #expect(q.geometry.heightMode == .small && q.geometry.fitAllTracks)
    }

    @Test func zoomCommandsPassOnWhenAnotherPanelZooms() {
        var (p, s, d) = setup()
        #expect(p.runViewCommand(.zoomIn, session: s, zooms: false, defaults: d) == nil)
        let pps = p.geometry.pointsPerSecond
        #expect(p.runViewCommand(.zoomIn, session: s, defaults: d) == "")
        p.settleZoomAnimation()                                   // the Mac eases the step
        #expect(p.geometry.pointsPerSecond > pps)
        #expect(p.runViewCommand(.copy, session: s, defaults: d) == nil)
    }

    @Test func playbackPagesUntilTheUserScrolls() {
        var (p, s, _) = setup()
        p.setZoom(pointsPerSecond: 200)
        p.geometry.scrollX = 0
        p.followPlayback(playing: true)                       // playhead at 0 is visible: follow on
        s.seek(to: fd * 140)                                  // 5.6 s = 1120 pt, past the right edge
        sync(&p, s)
        p.followPlayback(playing: true)
        let x = p.geometry.x(for: s.playhead)
        #expect(p.geometry.scrollX > 0 && x >= TimelineGeometry.contentOriginX && x < p.size.width)
        p.isPlaying = true
        _ = p.handle(.scroll(x: 500, y: 200, dx: 0, dy: 400, modifiers: .shift))
        let scrolled = p.geometry.scrollX
        s.seek(to: fd * 149)
        sync(&p, s)
        p.followPlayback(playing: true)
        #expect(p.geometry.scrollX == scrolled)               // the user's scroll wins until the next play
    }

    @Test func revealScrollsAnOffScreenRangeIn() {
        var (p, _, _) = setup()
        p.setZoom(pointsPerSecond: 200)
        p.geometry.scrollX = 0
        p.reveal(TimeRange(start: fd * 140, duration: fd * 5))
        let x = p.geometry.x(for: fd * 140)
        #expect(abs(x - (TimelineGeometry.contentOriginX + (p.size.width - TimelineGeometry.contentOriginX) * 0.1)) < 1)
        let before = p.geometry.scrollX
        p.reveal(TimeRange(start: fd * 141, duration: fd * 2))   // already in view: stays
        #expect(p.geometry.scrollX == before)
    }
}

@MainActor @Suite struct TimelineLiveModifierTests {
    final class Keys { var held: InputModifiers = [] }

    @Test func shiftPressedMidScrubSnapsThePlayhead() {
        var (p, s, _) = setup()
        p.setZoom(pointsPerSecond: 100)
        p.geometry.scrollX = 0
        let keys = Keys()
        p.liveModifiers = { keys.held }
        let edge = p.geometry.x(for: fd * 100)                  // the second clip's head
        _ = p.handle(.mouseDown(x: Float(edge - 40), y: 10, modifiers: []))
        guard case .scrub(let free)? = p.handle(.mouseDragged(x: Float(edge + 3), y: 10)).last else { Issue.record("no scrub"); return }
        #expect(free != fd * 100)
        keys.held = .shift                                     // Shift goes down during the drag
        guard case .scrub(let snapped)? = p.handle(.mouseDragged(x: Float(edge + 3), y: 10)).last else { Issue.record("no scrub"); return }
        #expect(snapped == fd * 100)
        _ = p.handle(.mouseUp(x: Float(edge + 3), y: 10))
        _ = s
    }

    @Test func backtickHoldsAttachedClipsOnlyInFastCut() {
        var (p, s, _) = setup()
        _ = p.handle(.keyDown(.character("`"), modifiers: []))
        #expect(!p.toolState.keepAttached)                                 // Normal: no hold
        _ = s.setTimelineEditMode(.magnetic)
        sync(&p, s)
        _ = p.handle(.keyDown(.character("`"), modifiers: []))
        #expect(p.toolState.keepAttached)
        _ = s.setTimelineEditMode(.normal)
        sync(&p, s)
        _ = p.keyUp(.character("`"))                                       // the key-up ends it in any mode
        #expect(!p.toolState.keepAttached)
    }

    @Test func withoutLiveKeysTheKeysOfThePressCount() {
        var (p, _, _) = setup()
        _ = p.handle(.mouseDown(x: 400, y: 10, modifiers: .shift))
        #expect(p.dragModifiers == .shift)
        p.liveModifiers = { [] }
        #expect(p.dragModifiers.isEmpty)
    }

    @Test func thumbnailModeCommandSetsThePanelThePreferenceAndTheChecks() {
        var (p, s, d) = setup()
        #expect(p.runViewCommand(.thumbnailMode(.continuous), session: s, defaults: d) == "")
        #expect(p.thumbnailMode == .continuous && d.string(forKey: ThumbnailPrefs.modeKey) == "continuous")
        let checks = p.viewChecks(session: s)
        #expect(checks.contains(.thumbnailMode(.continuous)) && !checks.contains(.thumbnailMode(.head)))
        #expect(checks.contains(.toggleSnapping) && checks.contains(.toggleLinkedSelection))
        _ = p.runViewCommand(.toggleSnapping, session: s, defaults: d)
        #expect(!p.viewChecks(session: s).contains(.toggleSnapping))
        #expect(!p.viewChecks(session: s).contains(.toggleMagnetic))
        _ = p.runViewCommand(.toggleMagnetic, session: s, defaults: d)
        #expect(p.viewChecks(session: s).contains(.toggleMagnetic))
    }

    @Test func silencePreviewShadesTheRangesRedAcrossTheLanes() {
        var (p, _, _) = setup()
        var plain = DrawList(width: 1000, height: 400)
        p.draw(into: &plain, atlas: nil)
        p.silencePreview = [TimeRange(start: fd * 10, duration: fd * 20)]
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        let red = TimelineSkin(theme: p.theme).red
        let x0 = Float(p.geometry.x(for: fd * 10)), x1 = Float(p.geometry.x(for: fd * 30))
        let bands = list.quads.filter { abs($0.r - red.r) < 0.01 && abs($0.g - red.g) < 0.01 && abs($0.a - 0.28) < 0.01 }
        #expect(bands.count == 1)
        #expect(abs(bands[0].x - x0) < 0.5 && abs(bands[0].x + bands[0].w - x1) < 0.5)
        #expect(list.quads.filter { abs($0.r - red.r) < 0.01 && abs($0.a - 0.9) < 0.01 && $0.w == 1 }.count == 2)
        #expect(list.quads.count == plain.quads.count + 3)
    }
}
