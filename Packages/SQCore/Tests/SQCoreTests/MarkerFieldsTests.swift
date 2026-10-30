import Foundation
import Testing
@testable import SQCore

@Suite struct MarkerFieldsTests {
    @Test func oldFilesDecodeWithDefaults() throws {
        let m = Marker(time: Time(5, 1), name: "A")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        json.removeValue(forKey: "color"); json.removeValue(forKey: "comment"); json.removeValue(forKey: "duration")
        let old = try JSONDecoder().decode(Marker.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == m)
    }

    @Test func fieldsRoundTrip() throws {
        let m = Marker(time: Time(5, 1), name: "A", color: .red, comment: "fix audio", duration: Time(2, 1))
        #expect(try JSONDecoder().decode(Marker.self, from: JSONEncoder().encode(m)) == m)
    }

    @Test func updateMarkerSetsColourAndComment() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30))
        let id = t.addMarker(at: Time(1, 1))
        t.updateMarker(id) { $0.color = .blue; $0.comment = "c"; $0.name = "n" }
        #expect(t.markers[0].color == .blue && t.markers[0].comment == "c" && t.markers[0].name == "n")
    }

    @Test func v12FileLoadsWithMarkerDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-v12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = UUID(), tid = UUID(), mid = UUID()
        let json = #"""
        {"formatVersion":12,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[],"markers":[{"id":"\#(mid)","time":{"value":3,"timescale":1},"name":"M"}]}]}}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let p = try ProjectFile.read(from: dir)
        #expect(p.timelines[0].markers[0].name == "M" && p.timelines[0].markers[0].color == .green)
    }
}
