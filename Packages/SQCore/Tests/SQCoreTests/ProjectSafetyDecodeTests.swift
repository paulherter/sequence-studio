import Foundation
import Testing
@testable import SQCore

/// Bad numbers in a project file are an error, not silently turned into something else.
@Suite struct ProjectSafetyDecodeTests {
    private func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(t, from: Data(json.utf8))
    }

    @Test func speedWithNonPositiveParts() throws {
        #expect(try decode(ClipSpeed.self, #"{"num":3,"den":2}"#) == ClipSpeed(num: 3, den: 2))
        #expect(throws: DecodingError.self) { try decode(ClipSpeed.self, #"{"num":0,"den":1}"#) }
        #expect(throws: DecodingError.self) { try decode(ClipSpeed.self, #"{"num":1,"den":-4}"#) }
        #expect(ClipSpeed(num: 0, den: 1) == .normal)         // arithmetic stays forgiving
    }

    @Test func formatFieldsMustBePositive() throws {
        let good = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30), audioSampleRate: 48_000)
        let data = try JSONEncoder().encode(good)
        #expect(try JSONDecoder().decode(SequenceFormat.self, from: data) == good)
        for (key, bad) in [("width", 0), ("height", -1), ("audioSampleRate", 0)] {
            var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            obj[key] = bad
            let broken = try JSONSerialization.data(withJSONObject: obj)
            #expect(throws: DecodingError.self, "\(key) = \(bad)") { try JSONDecoder().decode(SequenceFormat.self, from: broken) }
        }
    }

    @Test func duckFadeKeepsFramePrecision() {
        for fade in [Time(1, 30), Time(1001, 30_000), Time(3, 10), Time(2, 25), Time(1, 24)] {
            let live = LiveDucking(amountDB: 12, fade: fade)
            #expect(live.fade == fade && live.recovery == fade)
        }
        let t = DuckTiming(attackMs: 1000.0 / 30, recoveryMs: 1000.0 / 30)
        #expect(t.attack == Time(1, 30))
    }

    @Test func mergeRemapsEveryId() throws {
        let m = MediaRef(name: "a", path: "/v/a.mov", fingerprint: MediaFingerprint(size: 10), duration: Time(10, 1))
        let tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let p = Project(name: "P", media: [m], timelines: [tl])
        let r = try #require(ProjectMerge.remapIDs(in: p, keeping: [:]))
        #expect(r.media[0].id != m.id && r.timelines[0].id != tl.id)
    }
}
