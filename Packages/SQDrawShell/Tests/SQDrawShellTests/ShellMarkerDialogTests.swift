import Foundation
import Testing
import SQCore
import SQEditorSession
import SQDrawKit
@testable import SQDrawShell

/// The Mac marker sheet in the shared shell: rows, OK writes the fields, Delete Marker removes the marker.
@MainActor
struct ShellMarkerDialogTests {
    func session() -> EditorSession {
        EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30))]))
    }

    @Test func okWritesNameColorCommentAndDuration() throws {
        let s = session()
        let id = try #require(s.markAtPlayhead()).id
        let d = try #require(ShellHost.markerDialog(id, clip: nil, session: s))
        let f = try #require(d.form)
        #expect(d.messageText == "Marker")
        #expect(f.rows.compactMap(ShellForm.id(of:)) == ["name", "color", "duration", "comment"])
        f.set("name", .text("Hook"))
        f.set("color", .index(try #require(MarkerColor.allCases.firstIndex(of: .red))))
        f.set("comment", .text("tighten"))
        f.set("duration", .text("00:00:01:00"))
        ShellHost.applyMarkerDialog(d, response: .first, id: id, clip: nil, session: s)
        let m = try #require(s.activeTimeline?.markers.first { $0.id == id })
        #expect(m.name == "Hook" && m.color == .red && m.comment == "tighten")
        #expect(m.duration == Time(1, 1))
    }

    @Test func deleteMarkerRemovesIt() throws {
        let s = session()
        let id = try #require(s.markAtPlayhead()).id
        let d = try #require(ShellHost.markerDialog(id, clip: nil, session: s))
        ShellHost.applyMarkerDialog(d, response: .third, id: id, clip: nil, session: s)
        #expect(s.activeTimeline?.markers.contains { $0.id == id } == false)
        #expect(ShellHost.markerDialog(id, clip: nil, session: s) == nil)
    }

    /// The Mac Color popup puts the marker's color dot before each name (`Theme.Palette.marker`).
    @Test func theColorPopupCarriesTheMarkerColorDots() throws {
        let s = session()
        let id = try #require(s.markAtPlayhead()).id
        let f = try #require(ShellHost.markerDialog(id, clip: nil, session: s)?.form)
        let dots = try #require(f.popupStyles["color"]?.dots)
        #expect(dots.count == MarkerColor.allCases.count)
        #expect(dots.first == 0x30D158)
        #expect(dots[try #require(MarkerColor.allCases.firstIndex(of: .red))] == DrawTheme.marker(.red).rgbHex)
    }
}
