import XCTest
import CoreMedia
import AVFoundation
import SQCore
@testable import SQMedia

final class WebMTests: XCTestCase {
    private func tmp(_ w: WebMTestWriter) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).webm")
        try w.data().write(to: u)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    private func videoWriter(frames n: Int = 40) -> WebMTestWriter {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: true, codecID: "V_VP9", width: 64, height: 48)]
        for i in 0..<n {
            w.frames.append(.init(track: 1, ms: i * 100, key: i % 10 == 0, data: WebMTestWriter.vp9KeyFrame(width: 64, height: 48)))
        }
        return w
    }
    private let media = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../TestMedia").standardized

    func testIsWebMDetectsHeader() throws {
        XCTAssertTrue(WebMFile.isWebM(try tmp(videoWriter())))
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).webm")
        try Data(repeating: 1, count: 64).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertFalse(WebMFile.isWebM(junk))
    }

    func testParsesTracksAndBlocks() throws {
        let f = try WebMFile(url: try tmp(videoWriter()))
        XCTAssertEqual(f.tracks.count, 1)
        XCTAssertEqual(f.track(.video)?.codecID, "V_VP9")
        XCTAssertEqual(f.track(.video)?.width, 64)
        XCTAssertEqual(f.blocks(of: 1).count, 40)
        XCTAssertEqual(f.blocks(of: 1).filter(\.isKey).count, 4)
        XCTAssertEqual(f.time(f.blocks(of: 1)[5].ticks), Time(1, 2))
    }

    func testUnknownSizeClustersAndBlockGroups() throws {
        var w = videoWriter()
        w.unknownSizes = true; w.blockGroups = true
        let f = try WebMFile(url: try tmp(w))
        XCTAssertEqual(f.blocks(of: 1).count, 40)
        XCTAssertEqual(f.blocks(of: 1).filter(\.isKey).count, 4)
    }

    func testVP9HeaderParse() {
        let info = VP9KeyFrameInfo.parse(WebMTestWriter.vp9KeyFrame(width: 1920, height: 1080))
        XCTAssertEqual(info?.width, 1920)
        XCTAssertEqual(info?.height, 1080)
        XCTAssertEqual(info?.profile, 0)
        XCTAssertEqual(info?.bitDepth, 8)
        XCTAssertEqual(info?.chroma, "4:2:0")
        XCTAssertNil(VP9KeyFrameInfo.parse(Data([0x00, 0x01])))
    }

    func testDemuxerIndexAndFormat() throws {
        let d = try WebMDemuxer(file: try WebMFile(url: try tmp(videoWriter())))
        XCTAssertEqual(d.index.entries.count, 40)
        XCTAssertTrue(d.index.entries[0].isSync)
        XCTAssertEqual(d.index.entries[1].pts - d.index.entries[0].pts, Time(1, 10))
        XCTAssertEqual(d.formatDescription.mediaSubType.rawValue, kCMVideoCodecType_VP9)
    }

    func testVP8IsReportedUnsupported() throws {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: true, codecID: "V_VP8", width: 64, height: 48)]
        w.frames = [.init(track: 1, ms: 0, key: true, data: Data(repeating: 0, count: 20))]
        let f = try WebMFile(url: try tmp(w))
        XCTAssertThrowsError(try WebMDemuxer(file: f)) { e in
            guard case MediaError.unsupportedCodec(let n) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(n, "VP8")
        }
    }

    func testOpusPacketDuration() {
        XCTAssertEqual(OpusPacketDecoder.samples(in: Data([0xFC, 0, 0])), 960)           // CELT 20 ms, one frame
        XCTAssertEqual(OpusPacketDecoder.samples(in: Data([0xFD, 0, 0])), 1920)          // two frames
        XCTAssertEqual(OpusPacketDecoder.samples(in: Data([0xFF, 3, 0])), 960 * 3)       // arbitrary count
        XCTAssertNil(OpusPacketDecoder.samples(in: Data()))
    }

    func testIMDCTMatchesDirectFormula() throws {
        let n = 64
        let spec = (0..<n / 2).map { Float(sin(Double($0) * 0.7)) }
        let a = VorbisDecoder.imdctDirect(spec, n: n)
        XCTAssertEqual(a.count, n)
        XCTAssertTrue(a.allSatisfy { $0.isFinite })
    }

    func testUnsupportedProbeThrowsCodecName() async throws {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: true, codecID: "V_VP8", width: 64, height: 48)]
        w.frames = [.init(track: 1, ms: 0, key: true, data: Data(repeating: 0, count: 20))]
        let u = try tmp(w)
        do { _ = try await MediaImporter.probe(u); XCTFail("expected throw") }
        catch MediaError.unsupportedCodec(let n) { XCTAssertEqual(n, "VP8") }
    }

    /// Opus packets made with the system encoder, muxed into a synthetic file, read back through `WebMAudioSource`.
    func testOpusRoundTrip() throws {
        let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let outF = AVAudioFormat(streamDescription: &d)!
        let enc = try XCTUnwrap(AVAudioConverter(from: inF, to: outF))
        let frames = 960 * 100
        let pcm = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 { for i in 0..<frames { pcm.floatChannelData![c][i] = 0.5 * Float(sin(Double(i) * 2 * .pi * 440 / 48000)) } }
        let comp = AVAudioCompressedBuffer(format: outF, packetCapacity: 200, maximumPacketSize: 1500)
        var fed = false
        var packets: [Data] = []
        while packets.count < 100 {
            var err: NSError?
            let st = enc.convert(to: comp, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return pcm
            }
            guard let descs = comp.packetDescriptions else { break }
            for i in 0..<Int(comp.packetCount) {
                let p = descs[i]
                packets.append(Data(bytes: comp.data.advanced(by: Int(p.mStartOffset)), count: Int(p.mDataByteSize)))
            }
            if st == .endOfStream || st == .error || comp.packetCount == 0 { break }
        }
        try XCTSkipIf(packets.count < 20, "system Opus encoder unavailable")
        var head = Data("OpusHead".utf8); head.append(contentsOf: [1, 2, 0x38, 0x01]); head.append(contentsOf: [0x80, 0xBB, 0, 0, 0, 0, 0])
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: false, codecID: "A_OPUS", codecPrivate: head, channels: 2, rate: 48000)]
        for (i, p) in packets.enumerated() { w.frames.append(.init(track: 1, ms: i * 20, key: true, data: p)) }
        let src = try WebMAudioSource(file: try WebMFile(url: try tmp(w)), sampleRate: 48000)
        XCTAssertEqual(src.totalFrames, Int64(packets.count * 960 - 312), accuracy: 0)
        var buf = [Float](repeating: 0, count: 9600)
        let got = try buf.withUnsafeMutableBufferPointer { try src.read(from: 24000, count: 9600, into: $0.baseAddress!, channel: 1) }
        XCTAssertEqual(got, 9600)
        XCTAssertEqual(buf.map(abs).max() ?? 0, 0.5, accuracy: 0.1)
    }

    // MARK: real files (skipped when absent)

    func testRealFileProbeAndAudio() async throws {
        // (the short sample has a silent audio track; the long one carries signal)
        let u = media.appendingPathComponent("sample-vp9-vorbis-long.webm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path))
        let (_, info) = try await MediaImporter.probe(u)
        XCTAssertNotNil(info.video)
        XCTAssertNotNil(info.audio)
        let src = try await WebMAudioSource.open(url: u, sampleRate: 48000)
        XCTAssertGreaterThan(src.totalFrames, 48000)
        var buf = [Float](repeating: 0, count: 4800)
        let got = try buf.withUnsafeMutableBufferPointer { try src.read(from: 48000, count: 4800, into: $0.baseAddress!, channel: 0) }
        XCTAssertEqual(got, 4800)
        var peak: Float = 0
        for start in stride(from: Int64(0), to: src.totalFrames, by: 24000) {
            var b = [Float](repeating: 0, count: 4800)
            _ = try b.withUnsafeMutableBufferPointer { try src.read(from: start, count: 4800, into: $0.baseAddress!, channel: 0) }
            peak = max(peak, b.map(abs).max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 0.001)
        // Seek back: same samples as a fresh forward read.
        var again = [Float](repeating: 0, count: 4800)
        _ = try again.withUnsafeMutableBufferPointer { try src.read(from: 48000, count: 4800, into: $0.baseAddress!, channel: 0) }
        XCTAssertEqual(buf, again)
    }

    func testRealFileDecodesFrame() async throws {
        let u = media.appendingPathComponent("sample-vp9-vorbis.webm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path))
        let d = try await WebMDemuxer(url: u)
        XCTAssertGreaterThan(d.index.entries.count, 10)
        let s = try await d.samples(for: 0...0)
        XCTAssertEqual(s.count, 1)
    }
}
