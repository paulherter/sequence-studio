import Foundation
import SQAudioFX
import SQCore
import Testing
@testable import SQMedia

/// A 5.1 file played with no channel map goes through the fold-down (ITU-R BS.775), preview and export share the source.
private func writeSixChannelWAV(frames: Int = 24_000) throws -> URL {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    let channels = 6
    var pcm: [UInt8] = []
    let values = (0..<channels).map { le(Int16((Double($0 + 1) / 10 * 32768).rounded())) }
    for _ in 0..<frames { for c in 0..<channels { pcm += values[c] } }
    var d: [UInt8] = Array("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Array("WAVEfmt ".utf8) + le(UInt32(16))
    d += le(UInt16(1)) + le(UInt16(channels)) + le(UInt32(48_000)) + le(UInt32(48_000 * channels * 2))
    d += le(UInt16(channels * 2)) + le(UInt16(16)) + Array("data".utf8) + le(UInt32(pcm.count)) + pcm
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-fold-\(UUID().uuidString).wav")
    try Data(d).write(to: url)
    return url
}

@Suite struct SurroundFoldDownSourceTests {
    @Test func fiveOneFileWithoutMapFoldsToStereo() async throws {
        let url = try writeSixChannelWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: nil)
        let inter: [Float] = (0..<6).map { Float($0 + 1) / 10 }
        let expected = SurroundFoldDown.fold(interleaved: inter)!
        #expect(!src.isMono)
        for ch in 0..<2 {
            var buf = [Float](repeating: 0, count: 512)
            #expect(try src.read(from: 2_000, count: 512, into: &buf, channel: ch) == 512)
            #expect(buf.allSatisfy { abs($0 - expected[ch]) < 3e-4 }, "channel \(ch): \(buf[0]) vs \(expected[ch])")
        }
    }

    @Test func mapStillPicksSingleChannelsOfFiveOne() async throws {
        let url = try writeSixChannelWAV(frames: 4_800)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(0))
        var buf = [Float](repeating: 0, count: 128)
        #expect(try src.read(from: 100, count: 128, into: &buf, channel: 0) == 128)
        #expect(buf.allSatisfy { abs($0 - 0.1) < 3e-4 })
    }
}
