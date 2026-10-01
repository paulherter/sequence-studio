import Foundation
import Testing
@testable import SSCore

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
}
