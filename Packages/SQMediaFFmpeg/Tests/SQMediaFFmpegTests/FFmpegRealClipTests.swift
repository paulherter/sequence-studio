import Foundation
import SQMedia
import Testing
@testable import SQMediaFFmpeg

/// Decodes a real clip around a frame (SQ_REAL_CLIP=<path>, SQ_REAL_FRAME=<index>): sequential playback ranges and cold
/// single-frame seeks, software and hardware. Skipped without the variable.
@Suite struct FFmpegRealClipTests {
    @Test(arguments: [false, true]) func decodeAroundFrame(hardware: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SQ_REAL_CLIP"], FileManager.default.fileExists(atPath: path) else { return }
        let center = Int(env["SQ_REAL_FRAME"] ?? "") ?? 1638
        let d = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        let dec = try FFmpegVideoDecoder(demuxer: d, hardware: hardware)
        print("real clip: \(d.index.count) frames, decoder \(dec.decoderName), sync frames near: "
              + "\(d.index.entries.indices.filter { d.index.entries[$0].isSync && abs($0 - center) < 80 })")
        var failures = 0
        for f in (center - 20)...(center + 20) {          // cold single-frame seeks
            dec.invalidate()
            do { _ = try await dec.decode(f...f) } catch { failures += 1; print("cold \(f): \(error)") }
        }
        dec.invalidate()
        for start in stride(from: center - 40, to: center + 40, by: 4) {   // forward playback in small ranges
            do { _ = try await dec.decode(start...(start + 3)) } catch { failures += 1; print("seq \(start): \(error)") }
        }
        print("real clip: \(failures) failures")
        #expect(failures == 0)
    }
}
