import Testing
import SQCore

@Suite("Beat snap")
struct BeatSnapTests {
    private func timeline() -> Timeline {
        var t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])
        t.replaceBeatMarkers(in: TimeRange(start: .zero, duration: Time(20, 1)),
                                 with: (0..<8).map { Time(Int64($0), 1) })
        t.addMarker(at: Time(3, 2), name: "Note")
        return t
    }

    @Test func everyBeatKeepsAll() {
        let times = timeline().markerSnapTimes(beatLevel: .everyBeat)
        #expect(times.count == 9)
    }

    @Test func barsOnlyKeepsDownbeatsAndPlainMarkers() {
        let times = timeline().markerSnapTimes(beatLevel: .barsOnly).sorted()
        #expect(times == [Time(0, 1), Time(3, 2), Time(4, 1)])
    }

    @Test func durationClampsAtZero() {
        var t = timeline()
        let id = t.markers[0].id
        let a = t.setMarkerDuration(id, to: Time(-5, 1))
        #expect(a)
        #expect(t.markers.first { $0.id == id }?.duration == .zero)
        let b = t.setMarkerDuration(id, to: Time(2, 1))
        #expect(b)
        #expect(t.markers.first { $0.id == id }?.duration == Time(2, 1))
    }
}
