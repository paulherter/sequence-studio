import Foundation
import SQCore
import SQMedia
import SQMediaFFmpeg
import Testing

/// The Windows import probe on generated files: the 3 s pattern clip, a WAV, a PNG and a text file.
@Suite(.serialized) struct FFmpegMediaProbeTests {
    static func seconds(_ t: Time?) -> Double { t.map { Double($0.value) / Double($0.timescale) } ?? 0 }

    @Test func movieGetsVideoFromTheIndexAndSoundFromTheContainer() throws {
        let ref = try FFmpegMediaProbe.probe(FFmpegMediaTests.clip)
        let info = try #require(ref.info)
        #expect(ref.name == "pattern.mp4")
        #expect(info.video?.width == 640 && info.video?.height == 360)
        #expect(info.video?.codec == "h264")
        #expect(info.video?.nominalFrameDuration == Time(1, 30))
        #expect(info.audio?.sampleRate == 48_000 && info.audio?.codec == "aac")
        #expect(abs(Self.seconds(ref.duration) - 3) < 0.05)
        #expect(!info.isStill)
        #expect(ref.fingerprint.size > 0 && ref.fingerprint.headHash?.count == 64)
    }

    @Test func wavIsSoundOnly() throws {
        let n = 24_000
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(48_000); u32(48_000 * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        data.append(Data(count: n * 2))
        let url = FFmpegMediaTests.dir.appendingPathComponent("probe.wav")
        try data.write(to: url)
        let ref = try FFmpegMediaProbe.probe(url)
        #expect(ref.info?.video == nil)
        #expect(ref.info?.audio?.channels == 1 && ref.info?.audio?.sampleRate == 48_000)
        #expect(abs(Self.seconds(ref.duration) - 0.5) < 0.01)
    }

    @Test func pngIsAStill() throws {
        // 2x1 RGB PNG (one red, one white pixel), stored deflate block, real CRCs.
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func crc(_ b: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for x in b { c ^= UInt32(x); for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 } }
            return ~c
        }
        func chunk(_ type: String, _ d: [UInt8]) -> [UInt8] { let t = Array(type.utf8) + d; return be(UInt32(d.count)) + t + be(crc(t)) }
        let raw: [UInt8] = [0, 255, 0, 0, 255, 255, 255]
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        let z: [UInt8] = [0x78, 0x01, 0x01, UInt8(raw.count), 0, ~UInt8(raw.count), 0xFF] + raw + be(b << 16 | a)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", be(2) + be(1) + [8, 2, 0, 0, 0]) + chunk("IDAT", z) + chunk("IEND", [])
        let url = FFmpegMediaTests.dir.appendingPathComponent("probe.png")
        try Data(png).write(to: url)
        let ref = try FFmpegMediaProbe.probe(url)
        #expect(ref.info?.isStill == true)
        #expect(ref.info?.video?.width == 2 && ref.info?.video?.height == 1)
        #expect(ref.duration == MediaInfo.defaultStillDuration)
    }

    @Test func textFileIsUnreadable() throws {
        let url = FFmpegMediaTests.dir.appendingPathComponent("notes.txt")
        try Data("not media at all".utf8).write(to: url)
        #expect(throws: MediaError.self) { try FFmpegMediaProbe.probe(url) }
    }
}
