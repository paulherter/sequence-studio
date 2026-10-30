import Foundation
import SQCore
import SQDrawKit
import SQDrawLibrary
import SQDrawTimeline
import SQEditorSession
import SQLibrary
import SQInspectorUI
import SQTimelineUI
import Testing
@testable import SQAppShell

private let fd = Time(1, 25)

/// V1 with one 100-frame clip, an empty A1.
@MainActor private func setup() -> (TimelinePanel, EditorSession) {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: fd, isVariableFrameRate: false)
    let m = MediaRef(name: "a", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: fd * 100, info: MediaInfo(duration: fd * 100, video: v, audio: nil))
    let c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
    let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c]), Track(kind: .audio)])
    var project = Project(name: "P", timelines: [t])
    project.media = [m]
    let s = EditorSession(project: project)
    s.setActiveTimeline(t.id)
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 2000, h: 400), scale: 1)
    p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    return (p, s)
}

@MainActor private final class Calls {
    var placed: [([URL], TimelineAction)] = []
    var status: [String] = []
    var context: LibraryDropRoute.Context {
        LibraryDropRoute.Context(presets: [], importAndPlace: { self.placed.append(($0, $1)) }, status: { self.status.append($0) })
    }
}

@MainActor @Suite struct LibraryDropRouteTests {
    @Test func filesShowTheGhostThenImportWhereItShowed() {
        var (p, s) = setup()
        let calls = Calls()
        let row = p.geometry.rows(for: p.timeline)[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 50))
        let file = URL(fileURLWithPath: "/x/b.mov")
        #expect(!LibraryDropRoute.drag(.library(.files([file])), phase: .moved, x: x, y: y, modifiers: [], panel: &p, session: s,
                                       context: calls.context))
        #expect(calls.placed.isEmpty)
        #expect(LibraryDropRoute.drag(.library(.files([file])), phase: .ended, x: x, y: y, modifiers: [], panel: &p, session: s,
                                      context: calls.context))
        guard case .dropMedia(_, let time, _, _, _, _)? = calls.placed.first?.1 else { Issue.record("no drop action"); return }
        #expect(calls.placed.first?.0 == [file])
        #expect(time >= fd * 40 && time <= fd * 60)    // where the ghost showed
    }

    @Test func releaseOutsideTheTimelinePlacesNothing() {
        var (p, s) = setup()
        let calls = Calls()
        #expect(!LibraryDropRoute.drag(.library(.files([URL(fileURLWithPath: "/x/b.mov")])), phase: .ended, x: 5000, y: 5000,
                                       modifiers: [], panel: &p, session: s, context: calls.context))
        #expect(calls.placed.isEmpty)
    }

    @Test func textTemplateLandsAtTheGhostAsOneUndoStep() throws {
        var (p, s) = setup()
        let calls = Calls()
        let id = try #require(TextTemplateCatalog.all.first { !$0.isCTA && $0.graphicPresetID == nil }?.id)
        let row = p.geometry.rows(for: p.timeline)[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 50))
        let before = s.activeTimeline!.tracks.flatMap(\.clips).count
        #expect(LibraryDropRoute.drag(.library(.textTemplate(id)), phase: .ended, x: x, y: y, modifiers: [], panel: &p, session: s,
                                      context: calls.context))
        #expect(s.activeTimeline!.tracks.flatMap(\.clips).count > before)
        s.undo()
        #expect(s.activeTimeline!.tracks.flatMap(\.clips).count == before)
    }

    @Test func effectDropAddsItToTheClipUnderThePointer() {
        var (p, s) = setup()
        let calls = Calls()
        let row = p.geometry.rows(for: p.timeline)[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 50))
        let kind = ClipEffect.gaussianBlurKind
        #expect(LibraryDropRoute.drag(.effects([kind]), phase: .ended, x: x, y: y, modifiers: [], panel: &p, session: s,
                                      context: calls.context))
        #expect(s.activeTimeline!.tracks[0].clips[0].effects.contains { $0.kind == kind })
    }

    @Test func applyNamesWhatIsMissing() {
        let (_, s) = setup()
        var status: [String] = []
        EffectsApply.apply("gaussianBlur", session: s, presets: [], edges: nil) { status.append($0) }
        #expect(status.first?.hasPrefix("Select a video clip first") == true)
        #expect(EffectsApply.targetNoun("gaussianBlur") == "a video clip")
    }
}

