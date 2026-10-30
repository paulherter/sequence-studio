import Foundation
import Testing
@testable import SQCore

@Suite struct AudioTagTests {
    @Test func roleRoundTripsThroughCodable() throws {
        var t = Track(kind: .audio)
        t.audioRole = .dialogue
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t))
        #expect(back.audioRole == .dialogue)
    }

    @Test func olderFilesWithoutARoleDecodeAsNone() throws {
        let t = Track(kind: .audio)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        json["audioRole"] = nil
        let back = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.audioRole == nil)
    }

    @Test func namesAreShortAndUnique() {
        #expect(AudioTag.allCases.map(\.title) == ["Dialogue", "Music", "SFX"])
    }
}
