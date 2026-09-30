import Foundation
import Testing
@testable import SSCore

@Suite struct TimeTests {
    private func decodeTime(_ json: String) throws -> Time {
        try JSONDecoder().decode(Time.self, from: Data(json.utf8))
    }

    @Test func decodingNormalizesLikeTheInit() throws {
        let t = try decodeTime(#"{"value":2,"timescale":60}"#)
        #expect(t == Time(1, 30))
        #expect(t.value == 1 && t.timescale == 30)
        #expect(Set([t, Time(1, 30)]).count == 1)
    }

    @Test func decodingRejectsNonPositiveTimescale() {
        for ts in ["0", "-30"] {
            #expect(throws: DecodingError.self) { try decodeTime(#"{"value":1,"timescale":\#(ts)}"#) }
        }
    }

    @Test func encodingFormatIsUnchanged() throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try e.encode(Time(1001, 30000)), as: UTF8.self) == #"{"timescale":30000,"value":1001}"#)
    }

    @Test func extremeValuesNormalizeWithoutTrapping() {
        #expect(Time(Int64.min, 2).value == Int64.min / 2)
        #expect(Time(Int64.min, 1) == Time(Int64.min, 1))
        #expect(Time(Int64.min, Int64.max).timescale == Int64.max)
        #expect(Time(-6, 4) == Time(-3, 2))
    }

    @Test func equalityIsValueBasedAcrossTimescales() {
        #expect(Time(1, 2) == Time(2, 4))
        #expect(Time(1001, 30000) != Time(1, 30))
        #expect(Time(0, 1) == Time(0, 600))
    }

    @Test func ordering() {
        #expect(Time(1, 3) < Time(1, 2))
        #expect(Time(-1, 2) < .zero)
        #expect(Time(30000, 1001) > Time(29, 1))
    }

    @Test func arithmeticIsExact() {
        #expect(Time(1, 3) + Time(1, 6) == Time(1, 2))
        #expect(Time(1, 2) - Time(1, 3) == Time(1, 6))
        #expect(Time(1001, 30000) * 30 == Time(30030, 30000))
        #expect(-Time(1, 4) == Time(-1, 4))
    }

    @Test func noDriftOver24HoursAtNTSC() {
        let frame = Time(1001, 30000)
        var t = Time.zero
        for _ in 0..<(30000 * 3600 * 24 / 1001) { t = t + frame }
        #expect(t == frame * (30000 * 3600 * 24 / 1001))
    }

    @Test func frameConversion() {
        let frame = Time(1001, 30000)
        #expect(Time.frames(90, frameDuration: frame) == Time(90090, 30000))
        #expect(Time(90090, 30000).frameIndex(frameDuration: frame) == 90)
        // floor semantics, also for negatives
        #expect((Time(90090, 30000) + Time(1, 100000)).frameIndex(frameDuration: frame) == 90)
        #expect((Time(-1, 100000)).frameIndex(frameDuration: frame) == -1)
    }

    @Test func snapToFrame() {
        let frame = Time(1, 25)
        #expect(Time(3, 100).snapped(to: frame) == Time(1, 25))   // 0.75 frame rounds up
        #expect(Time(1, 100).snapped(to: frame) == .zero)
    }

    @Test func rangeBasics() {
        let r = TimeRange(start: Time(2, 1), duration: Time(3, 1))
        #expect(r.end == Time(5, 1))
        #expect(r.contains(Time(2, 1)))
        #expect(!r.contains(Time(5, 1)))
        #expect(r.overlaps(TimeRange(start: Time(4, 1), duration: Time(3, 1))))
        #expect(!r.overlaps(TimeRange(start: Time(5, 1), duration: Time(1, 1))))
        #expect(r.intersection(TimeRange(start: Time(4, 1), duration: Time(3, 1))) == TimeRange(start: Time(4, 1), duration: Time(1, 1)))
    }
}
