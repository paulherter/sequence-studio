import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorSession

/// "Save to Library…" on a title selection and inserting it again: one undo step, first text clip selected.
@MainActor @Suite struct TitleBlockSessionTests {
    private func session() -> EditorSession {
        var tracks = Timeline.defaultTracks(video: 2, audio: 1)
        try! tracks[0].overwrite(Clip(name: "head", media: UUID(), kind: .video,
                                      source: TimeRange(start: .zero, duration: Time(30, 1)), start: .zero))
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: tracks)
        return EditorSession(project: Project(name: "P", timelines: [tl]))
    }

    @Test func saveThenInsertElsewhereRoundTrips() throws {
        let s = session()
        s.seek(to: Time(2, 1))
        let made = TitleBuilder.parts(format: s.activeTimeline!.format).compactMap {
            s.addTextClip(template: $0.template, at: s.playhead, duration: TitleBuilder.defaultDuration, neverOverwrite: true)
        }
        #expect(made.count == 3)
        for id in made {
            let tr = try #require(s.activeTimeline?.tracks.first { $0.clips.contains { $0.id == id } })
            try s.perform("Test Transition") { p in
                try p.edit(s.activeTimelineID!) { _ = try $0.addElementTransitions(kind: .pop, track: tr.id, clip: id, edges: [.head], duration: Time(6, 30)) }
            }
        }
        s.select(clips: Set(made))
        #expect(s.canSaveSelectionAsTitleBlock)
        let block = try #require(s.titleBlockFromSelection())
        let item = try block.presetItem(name: "Mine")
        let loaded = try TitleBlock(preset: item)

        let before = s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0
        let depth = s.undoDepth
        let ids = s.insertTitleBlock(loaded, at: Time(10, 1))
        #expect(ids.count == 3)
        #expect(s.undoDepth == depth + 1)
        let t = try #require(s.activeTimeline)
        #expect(t.tracks.flatMap(\.clips).count == before + 3)
        let placed = t.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        #expect(placed.allSatisfy { $0.start == Time(10, 1) })
        #expect(Set(ids).isDisjoint(with: made))
        // Each line keeps its In animation (head element transition).
        #expect(ids.allSatisfy { id in t.tracks.contains { tr in tr.transitions.contains { $0.incoming == id && $0.outgoing == nil } } })
        #expect(s.selection == [ids[0]])                                  // line 1, ready to type
        s.undo()
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).count == before)
    }

    @Test func mediaClipsInTheSelectionRefuseToSave() throws {
        let s = session()
        let head = try #require(s.activeTimeline?.tracks[0].clips.first)
        s.select(clips: [head.id])
        #expect(!s.canSaveSelectionAsTitleBlock)
        #expect(s.titleBlockFromSelection() == nil)
        #expect(s.lastError != nil)
    }
}
