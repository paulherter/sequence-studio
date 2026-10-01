import Foundation
import Testing
import SSCore
import SSText
@testable import SSEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}

private let template = TextTemplate(name: "Text", text: "Text", style: TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white))

@MainActor @Suite struct TypeToolSessionTests {
    @Test func clickPlacesTextAtPositionOnTopFreeTrackAtPlayheadForFiveSeconds() throws {
        let session = makeSession()
        session.seek(to: s(3))
        let id = try #require(session.addTextClip(template: template, position: Vec2(120, -80)))
        let clip = try #require(session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        #expect(clip.start == s(3) && clip.source.duration == s(5))
        #expect(clip.animation.position.value == Vec2(120, -80))
        #expect(session.activeTimeline?.tracks.last { $0.kind == .video }?.clips.contains { $0.id == id } == true)
        session.undo()    // one undo step covers clip and position
        #expect(session.activeTimeline?.tracks.allSatisfy { $0.clips.isEmpty } == true)
    }

    @Test func secondTextAtTheSameTimeGoesToTheNextFreeTrack() throws {
        let session = makeSession()
        let a = try #require(session.addTextClip(template: template, position: .zero))
        let b = try #require(session.addTextClip(template: template, position: .zero))
        let tracks = try #require(session.activeTimeline?.tracks.filter { $0.kind == .video })
        #expect(tracks.count == 2)
        #expect(tracks[1].clips.map(\.id) == [a] && tracks[0].clips.map(\.id) == [b])
    }

    @Test func discardingEmptyTextRemovesTheClip() throws {
        let session = makeSession()
        let id = try #require(session.addTextClip(template: template, position: .zero))
        #expect(session.discardTextClip(id))
        #expect(session.activeTimeline?.tracks.allSatisfy { $0.clips.isEmpty } == true)
        #expect(session.selection.isEmpty)
    }
}
