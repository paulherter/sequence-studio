import Foundation
import Testing
@testable import SQMedia

@Suite struct MonoAudioDecoderTests {
    @Test func stereoIsAveragedAndLengthIsKept() throws {
        let n = 100_000
        let l = [Float](repeating: 0.5, count: n), r = [Float](repeating: -0.1, count: n)
        let m = try MonoAudioDecoder.mono(from: MemoryAudioSource(left: l, right: r))
        #expect(m.count == n)
        #expect(abs(m[0] - 0.2) < 1e-6 && abs(m[n - 1] - 0.2) < 1e-6)
    }

    @Test func monoSourceIsPassedThrough() throws {
        let s = (0..<70_000).map { Float($0 % 7) / 7 }
        #expect(try MonoAudioDecoder.mono(from: MemoryAudioSource(mono: s)) == s)
    }

    @Test func maxFramesCapsTheRead() throws {
        let s = [Float](repeating: 1, count: 10_000)
        #expect(try MonoAudioDecoder.mono(from: MemoryAudioSource(mono: s), maxFrames: 4_000).count == 4_000)
    }

    /// A real file: 1 s stereo 16 bit WAV at 48 kHz (left 0.5, right -0.1) decodes to about 1 s of mono at the analysis rate.
    @Test func fileIsDecodedToMonoAtTheAnalysisRate() async throws {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let frames = 48_000
        var pcm: [UInt8] = []
        let l = le(Int16(16_384)), r = le(Int16(-3_277))
        for _ in 0..<frames { pcm += l + r }
        var d: [UInt8] = Array("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Array("WAVEfmt ".utf8) + le(UInt32(16))
        d += le(UInt16(1)) + le(UInt16(2)) + le(UInt32(48_000)) + le(UInt32(48_000 * 4))
        d += le(UInt16(4)) + le(UInt16(16)) + Array("data".utf8) + le(UInt32(pcm.count)) + pcm
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mono-\(UUID().uuidString).wav")
        try Data(d).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let m = try await MonoAudioDecoder.decode(url: url)
        #expect(abs(m.count - MonoAudioDecoder.analysisSampleRate) < 1_000)
        let mid = m[m.count / 2]
        #expect(abs(mid - 0.2) < 0.01)
    }
}
