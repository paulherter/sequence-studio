import Foundation
import Testing
import SQCore
@testable import SQMedia

// VP8 has no decoder in the system (probed here); WebM files with VP8 video throw unsupportedCodec so the import dialog
// offers the MP4 conversion.

@Suite struct WebMVP8Tests {
    // Probed on macOS 27: VTRegisterSupplementalVideoDecoderIfAvailable('vp08') registers nothing and a decompression
    // session for VP8 fails with kVTCouldNotFindVideoDecoderErr (-12906).
    @Test func vp8IsReportedAsUnsupportedCodec() throws {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: true, codecID: "V_VP8", width: 640, height: 360)]
        w.frames = [.init(track: 1, ms: 0, key: true, data: Data([0x10, 0x02, 0x00]))]
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).webm")
        try w.data().write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        let file = try WebMFile.open(u)
        do { _ = try WebMDemuxer(file: file); Issue.record("expected unsupportedCodec") }
        catch MediaError.unsupportedCodec(let name) { #expect(name == "VP8") }
    }
}
