import Testing
import Foundation
@testable import SQCore

@Suite struct TextSearchTests {
    @Test func caseAndDiacriticInsensitive() {
        let m = TextSearch.matches(in: "Der O-Ton, dann o-ton und Café", find: "O-TON")
        #expect(m == [NSRange(location: 4, length: 5), NSRange(location: 16, length: 5)])
        #expect(TextSearch.matches(in: "Un café noir", find: "CAFE").count == 1)
        #expect(TextSearch.matches(in: "Un cafe noir", find: "café").count == 1)
        #expect(TextSearch.matches(in: "Café", find: "cafe", diacriticSensitive: true).isEmpty)
        #expect(TextSearch.matches(in: "abc", find: "").isEmpty)
    }

    @Test func matchesAcrossWordBoundaries() {
        #expect(TextSearch.matches(in: "so the big story is the big story", find: "big story").count == 2)
    }

    @Test func markAllAddsOncePerNameAndFrame() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30))
        #expect(t.addSearchHitMarkers(at: [Time(2, 1), Time(5, 1), Time(2, 1)], name: "O-Ton") == 2)
        #expect(t.markers.map(\.name) == ["O-Ton", "O-Ton"])
        #expect(t.addSearchHitMarkers(at: [Time(2, 1), Time(5, 1)], name: "O-Ton") == 0)
        #expect(t.markers.count == 2)
        #expect(t.addSearchHitMarkers(at: [Time(2, 1)], name: "Other") == 1)
        #expect(t.markers.count == 3)
    }
}
