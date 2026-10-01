import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct MarkersPanelModelTests {
    let fd = Time(1, 30)

    func model() -> MarkersPanelModel {
        let m = MarkersPanelModel()
        m.update(markers: [Marker(time: Time(65, 1), name: "b"), Marker(time: Time(2, 1), name: "a")], frameDuration: fd)
        return m
    }

    @Test func rowsSortedWithTimecode() {
        let r = model().rows
        #expect(r.map(\.name) == ["a", "b"])
        #expect(r[0].inTimecode == "00:00:02:00")
        #expect(r[1].inTimecode == "00:01:05:00")
    }

    @Test func doubleClickSeeks() {
        let m = model()
        var sought: Time?
        m.onSeek = { sought = $0 }
        m.activate(row: 1)
        #expect(sought == Time(65, 1))
        m.activate(row: 9)
        #expect(sought == Time(65, 1))
    }

    @Test func inlineEdits() {
        let m = model()
        var edits: [MarkersPanelModel.Edit] = []
        m.onEdit = { edits.append($0) }
        #expect(m.commit(row: 0, column: .name, text: "x"))
        #expect(m.commit(row: 0, column: .inPoint, text: "00:00:03:15"))
        #expect(!m.commit(row: 0, column: .inPoint, text: "00:00:03:45"))
        #expect(!m.commit(row: 0, column: .duration, text: "abc"))
        #expect(m.commit(row: 0, column: .color, text: "Red"))
        #expect(edits.count == 3)
        #expect(edits[1] == .move(m.markers[0].id, Time(3, 1) + Time(15, 30)))
    }

    @Test func timecodeRoundTrip() {
        let t = Time(3661, 1) + Time(7, 30)
        let s = MarkersPanelModel.timecode(t, frameDuration: fd)
        #expect(s == "01:01:01:07")
        #expect(MarkersPanelModel.parseTimecode(s, frameDuration: fd) == t)
        #expect(MarkersPanelModel.parseTimecode("45", frameDuration: fd) == fd * 45)
    }
}
