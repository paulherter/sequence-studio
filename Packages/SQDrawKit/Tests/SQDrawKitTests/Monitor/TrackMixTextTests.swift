import Testing
import SQCore
@testable import SQDrawKit

@Suite("TrackMixText") struct TrackMixTextTests {
    @Test func panRoundTrips() {
        #expect(TrackMixText.text(pan: -50) == "L 50" && TrackMixText.text(pan: 0) == "Center" && TrackMixText.text(pan: 20) == "R 20")
        #expect(TrackMixText.parse(pan: "L 30") == -30 && TrackMixText.parse(pan: "r20") == 20 && TrackMixText.parse(pan: "center") == 0)
    }

    @Test func volumeTextAndFloor() {
        #expect(TrackMixText.parse(volumeDB: "-6 dB") == -6)
        #expect(TrackMixText.parse(volumeDB: "-inf") == TrackPan.minVolumeDB)
        #expect(TrackMixText.text(volumeDB: TrackPan.minVolumeDB) == "-inf dB" && TrackMixText.capsuleText(volumeDB: 3) == "+3.0")
    }
}
