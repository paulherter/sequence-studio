import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite("Marker CSV")
struct MarkerCSVTests {
    let fd = Time(1, 30)

    private func timeline(_ markers: [Marker]) -> Timeline {
        var t = Timeline(name: "S", frameDuration: fd, tracks: [])
        t.markers = markers
        return t
    }

    @Test func headerAndRowsAreInTimeOrder() {
        let t = timeline([
            Marker(time: Time(60, 30), name: "B", color: .red, comment: "later"),
            Marker(time: Time(30, 30), name: "A", color: .green, duration: Time(15, 30)),
        ])
        let text = MarkerCSV.export(t).text
        #expect(text == "Scope,Name,Color,In,Out,Duration,Comment\r\n"
                + "Sequence,A,green,00:00:01:00,00:00:01:15,00:00:00:15,\r\n"
                + "Sequence,B,red,00:00:02:00,00:00:02:00,00:00:00:00,later\r\n")
    }

    @Test func formulaCellsAreEscapedAndQuotedWhenNeeded() {
        #expect(MarkerCSV.cell("=SUM(A1)") == "'=SUM(A1)")
        #expect(MarkerCSV.cell("+1") == "'+1")
        #expect(MarkerCSV.cell("@x") == "'@x")
        #expect(MarkerCSV.cell("-2") == "'-2")
        #expect(MarkerCSV.cell("a,b") == "\"a,b\"")
        #expect(MarkerCSV.cell("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(MarkerCSV.cell("two\nlines") == "\"two\nlines\"")
        #expect(MarkerCSV.cell("plain") == "plain")
    }

    @Test func timecodeStartShiftsPositionsNotDurations() {
        var t = timeline([Marker(time: Time(30, 30), name: "A", duration: Time(30, 30))])
        t.timecodeStart = Time(3600, 1)
        let line = MarkerCSV.export(t).text.components(separatedBy: "\r\n")[1]
        #expect(line == "Sequence,A,green,01:00:01:00,01:00:02:00,00:00:01:00,")
    }

    @Test func dropFrameTimecodeFor2997() {
        let row = MarkerCSV.Row(scope: "Sequence", name: "M", color: "red", time: Time(1001 * 1800, 30000),
                                duration: .zero, comment: "")
        let text = MarkerCSV.render([row], frameDuration: Time(1001, 30000))
        #expect(text.contains("00:01:00;02"))
    }

    @Test func writeIsComplete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markers-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkerCSV.export(timeline([Marker(time: .zero, name: "x")])).write(to: url)
        let back = try String(contentsOf: url, encoding: .utf8)
        #expect(back.hasPrefix("Scope,Name"))
    }
}
