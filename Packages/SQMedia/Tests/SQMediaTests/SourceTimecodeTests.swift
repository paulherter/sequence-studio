import Foundation
import Testing
import SQCore
@testable import SQMedia

@Suite struct SourceTimecodeTests {
    // MARK: Synthetic fixtures

    private func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] { u32(v).reversed() }
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] { u32(UInt32(body.count + 8)) + Array(type.utf8) + body }
    private func full(_ type: String, _ body: [UInt8]) -> [UInt8] { box(type, [0, 0, 0, 0] + body) }

    private func tmcdEntry(flags: UInt32, timescale: UInt32, duration: UInt32, frames: UInt8) -> [UInt8] {
        let body = [UInt8](repeating: 0, count: 6) + [0, 1] + u32(0) + u32(flags) + u32(timescale) + u32(duration) + [frames, 0]
        return box("tmcd", body)
    }

    private func video(timescale: UInt32, delta: UInt32) -> [UInt8] {
        let mdhd = full("mdhd", u32(0) + u32(0) + u32(timescale) + u32(0) + [0, 0, 0, 0])
        let hdlr = full("hdlr", u32(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 13))
        let stts = full("stts", u32(1) + u32(10) + u32(delta))
        return box("trak", box("mdia", mdhd + hdlr + box("minf", box("stbl", stts))))
    }

    private func dataTrack(format: [UInt8], offset: UInt32, size: UInt32) -> [UInt8] {
        let stsd = full("stsd", u32(1) + format)
        let stco = full("stco", u32(1) + u32(offset))
        let stsz = full("stsz", u32(0) + u32(1) + u32(size))
        return box("trak", box("mdia", box("minf", box("stbl", stsd + stco + stsz))))
    }

    /// mdat first (so offsets are known), then moov with the tracks.
    private func mp4(samples: [[UInt8]], tracks: (_ offsets: [UInt32]) -> [UInt8]) throws -> URL {
        var mdat: [UInt8] = []
        var offsets: [UInt32] = []
        for s in samples { offsets.append(UInt32(8 + mdat.count)); mdat += s }
        let file = box("mdat", mdat) + box("moov", tracks(offsets))
        return try write(Data(file), ext: "mov")
    }

    private func write(_ d: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sqtc-\(UUID().uuidString).\(ext)")
        try d.write(to: url)
        return url
    }

    // MARK: tmcd

    @Test func tmcdReadsAtItsOwnRateAndDropFlag() throws {
        // Video 30 fps timescale 3000/100; the timecode track counts 30000/1001 with drop frame.
        let url = try mp4(samples: [u32(1800)]) { o in
            video(timescale: 3000, delta: 100)
                + dataTrack(format: tmcdEntry(flags: 1, timescale: 30000, duration: 1001, frames: 30), offset: o[0], size: 4)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let tc = try #require(try SourceTimecode.read(from: url))
        #expect(tc.source == .tmcd && tc.dropFrame)
        #expect(tc.frameDuration == Time(1001, 30000))
        #expect(tc.origin == Time(1800 * 1001, 30000))          // exact, not 1800/30
        #expect(tc.label() == "00:01:00;02")                      // drop frame skips :00 and :01 at the minute
    }

    @Test func tmcdNonDropAndTwentyFour() throws {
        let url = try mp4(samples: [u32(24 * 3600 * 2 + 12)]) { o in
            dataTrack(format: tmcdEntry(flags: 0, timescale: 24, duration: 1, frames: 24), offset: o[0], size: 4)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let tc = try #require(try SourceTimecode.read(from: url))
        #expect(tc.label() == "02:00:00:12" && !tc.dropFrame)
        #expect(tc.origin == Time(7200 * 24 + 12, 24))
    }

    @Test func dropFrameBoundaries() {
        func label(_ frames: Int64) -> String? {
            SourceTimecode(origin: Time(frames * 1001, 30000), frameDuration: Time(1001, 30000), dropFrame: true, source: .tmcd).label()
        }
        #expect(label(0) == "00:00:00;00")
        #expect(label(1799) == "00:00:59;29")
        #expect(label(1800) == "00:01:00;02")
        #expect(label(17981) == "00:09:59;29")      // 10 minutes hold 17982 frames
        #expect(label(17982) == "00:10:00;00")      // every tenth minute keeps :00
        #expect(label(17982 + 1800) == "00:11:00;02")
        #expect(label(17982 * 6) == "01:00:00;00")  // an hour is 107892 frames
    }

    @Test func negativeCounterFlagIsNotTaken() throws {
        let url = try mp4(samples: [u32(UInt32.max)]) { o in
            dataTrack(format: tmcdEntry(flags: 4, timescale: 25, duration: 1, frames: 25), offset: o[0], size: 4)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SourceTimecode.read(from: url) == nil)
    }

    // MARK: rtmd fallback

    private func rtmdSample(h: UInt8, m: UInt8, s: UInt8, f: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0x20)
        b[0] = 0; b[1] = 0x1c
        b[0x0d] = h; b[0x0e] = m; b[0x0f] = s; b[0x11] = f
        return b
    }

    @Test func rtmdUsedWhenNoTmcd() throws {
        let sample = rtmdSample(h: 0x10, m: 0x25, s: 0x30, f: 0x07)
        let url = try mp4(samples: [sample]) { o in
            video(timescale: 25000, delta: 1000)
                + dataTrack(format: box("rtmd", [UInt8](repeating: 0, count: 16)), offset: o[0], size: UInt32(sample.count))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let tc = try #require(try SourceTimecode.read(from: url))
        #expect(tc.source == .rtmd && tc.label() == "10:25:30:07")
        #expect(tc.origin == Time(((10 * 3600 + 25 * 60 + 30) * 25 + 7) * 1000, 25000))
    }

    @Test func rtmdWithImplausibleDigitsGivesNothing() {
        #expect(SourceTimecode.parseRTMD(sample: Data(rtmdSample(h: 0x2A, m: 0x00, s: 0x00, f: 0x00)), clock: Time(1, 25)) == nil)
        #expect(SourceTimecode.parseRTMD(sample: Data(rtmdSample(h: 0x23, m: 0x61, s: 0x00, f: 0x00)), clock: Time(1, 25)) == nil)
        #expect(SourceTimecode.parseRTMD(sample: Data(rtmdSample(h: 0x01, m: 0x00, s: 0x00, f: 0x30)), clock: Time(1, 25)) == nil)
    }

    @Test func tmcdWinsOverRtmd() throws {
        let sample = rtmdSample(h: 0x10, m: 0x00, s: 0x00, f: 0x00)
        let url = try mp4(samples: [sample, u32(25 * 60)]) { o in
            video(timescale: 25000, delta: 1000)
                + dataTrack(format: box("rtmd", [UInt8](repeating: 0, count: 16)), offset: o[0], size: UInt32(sample.count))
                + dataTrack(format: tmcdEntry(flags: 0, timescale: 25, duration: 1, frames: 25), offset: o[1], size: 4)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let tc = try #require(try SourceTimecode.read(from: url))
        #expect(tc.source == .tmcd && tc.label() == "00:01:00:00")
    }

    @Test func fileWithoutTimecodeIsNil() throws {
        let url = try mp4(samples: []) { _ in video(timescale: 25000, delta: 1000) }
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SourceTimecode.read(from: url) == nil)
    }

    // MARK: bext

    @Test func bextTimeReferenceIsSamplesSinceMidnight() throws {
        var bext = [UInt8](repeating: 0, count: 602)
        let ref: UInt64 = 48_000 * 3600 * 14 + 48_000 * 90          // 14:01:30
        bext.replaceSubrange(338..<342, with: le32(UInt32(ref & 0xFFFF_FFFF)))
        bext.replaceSubrange(342..<346, with: le32(UInt32(ref >> 32)))
        let fmt = le32(0x0001_0001) + le32(48_000) + le32(96_000) + [2, 0, 16, 0]      // PCM mono 16 bit
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            Array(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
        }
        let payload = Array("WAVE".utf8) + chunk("fmt ", fmt) + chunk("bext", bext) + chunk("data", [0, 0, 0, 0])
        let url = try write(Data(Array("RIFF".utf8) + le32(UInt32(payload.count)) + payload), ext: "wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let tc = try #require(try SourceTimecode.read(from: url))
        #expect(tc.source == .bext && tc.origin == Time(Int64(ref), 48_000))
        #expect(tc.label(frameDuration: Time(1, 25)) == "14:01:30:00")
        #expect(tc.label() == nil)                                   // audio alone has no frame clock
    }

    @Test func wavWithoutBextIsNil() throws {
        let fmt = le32(0x0001_0001) + le32(44_100) + le32(88_200) + [2, 0, 16, 0]
        let payload = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(UInt32(fmt.count)) + fmt
        let url = try write(Data(Array("RIFF".utf8) + le32(UInt32(payload.count)) + payload), ext: "wav")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SourceTimecode.read(from: url) == nil)
    }
}
