import XCTest
import AVFoundation
import SQCore
@testable import SQMedia

/// Opus pre-skip: the decoder emits `preSkip` samples of encoder delay first; `WebMAudioSource` must drop exactly
/// those, so a click placed at input frame N comes out at output frame N.
final class WebMOpusAlignmentTests: XCTestCase {
    static func encode(_ pcm: AVAudioPCMBuffer) throws -> [Data] {
        let inF = pcm.format
        var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let outF = try XCTUnwrap(AVAudioFormat(streamDescription: &d))
        let enc = try XCTUnwrap(AVAudioConverter(from: inF, to: outF))
        let comp = AVAudioCompressedBuffer(format: outF, packetCapacity: 400, maximumPacketSize: 1500)
        var fed = false
        var packets: [Data] = []
        while true {
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
        return packets
    }

    func testClickLandsAtItsInputFrame() throws {
        let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let frames = 960 * 110
        let pcm = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let click = 24_000, click2 = 72_000
        for c in 0..<2 {
            for i in 0..<frames { pcm.floatChannelData![c][i] = 0 }
            for (pos, k) in [click, click2].flatMap({ p in (-48...48).map { (p, $0) } } ) {   // Hann-windowed 2 kHz burst centered on the click frame
                let w = 0.5 * (1 + cos(Double(k) * .pi / 49))
                pcm.floatChannelData![c][pos + k] = Float(0.8 * w * sin(Double(k) * 2 * .pi * 2000 / 48000 + .pi / 2))
            }
        }
        let packets = try Self.encode(pcm)
        try XCTSkipIf(packets.count < 20, "system Opus encoder unavailable")
        let preSkip = 312
        var head = Data("OpusHead".utf8); head.append(contentsOf: [1, 2, UInt8(preSkip & 255), UInt8(preSkip >> 8)])
        head.append(contentsOf: [0x80, 0xBB, 0, 0, 0, 0, 0])
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: false, codecID: "A_OPUS", codecPrivate: head, channels: 2, rate: 48000)]
        for (i, p) in packets.enumerated() { w.frames.append(.init(track: 1, ms: i * 20, key: true, data: p)) }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).webm")
        try w.data().write(to: u)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        let src = try WebMAudioSource(file: try WebMFile(url: u), sampleRate: 48000)
        XCTAssertEqual(src.totalFrames, Int64(packets.count * 960 - preSkip))

        // Energy centroid of the decoded burst. The later click is read first: a fresh decoder after a seek.
        func centroid(_ at: Int) throws -> (Double, [Float]) {
            var buf = [Float](repeating: 0, count: 2000)
            let from = Int64(at - 1000)
            let got = try buf.withUnsafeMutableBufferPointer { try src.read(from: from, count: 2000, into: $0.baseAddress!, channel: 0) }
            XCTAssertEqual(got, 2000)
            var num = 0.0, den = 0.0
            for (i, v) in buf.enumerated() { num += Double(i) * Double(v * v); den += Double(v * v) }
            XCTAssertGreaterThan(den, 0.1)
            return (Double(from) + num / den, buf)
        }
        let (c2, _) = try centroid(click2)
        XCTAssertEqual(c2, Double(click2), accuracy: 2, "click after seek")
        let (c1, buf) = try centroid(click)
        XCTAssertEqual(c1, Double(click), accuracy: 2, "click from the start")
        let from = Int64(click - 1000)

        // Same burst through a read that starts inside it (seek path): identical samples.
        var again = [Float](repeating: 0, count: 500)
        _ = try again.withUnsafeMutableBufferPointer { try src.read(from: from + 700, count: 500, into: $0.baseAddress!, channel: 0) }
        XCTAssertEqual(Array(buf[700..<1200]), again)
    }

    func testWriteAudioFileMatchesSource() async throws {
        let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let frames = 960 * 30
        let pcm = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 { for i in 0..<frames { pcm.floatChannelData![c][i] = 0.4 * Float(sin(Double(i) * 2 * .pi * 300 / 48000)) } }
        let packets = try Self.encode(pcm)
        try XCTSkipIf(packets.count < 20, "system Opus encoder unavailable")
        var head = Data("OpusHead".utf8); head.append(contentsOf: [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0])
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: false, codecID: "A_OPUS", codecPrivate: head, channels: 2, rate: 48000)]
        for (i, p) in packets.enumerated() { w.frames.append(.init(track: 1, ms: i * 20, key: true, data: p)) }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).webm")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).caf")
        try w.data().write(to: u)
        addTeardownBlock { try? FileManager.default.removeItem(at: u); try? FileManager.default.removeItem(at: out) }
        try await WebMReadback.writeAudioFile(from: u, to: out)
        let file = try AVAudioFile(forReading: out)
        let src = try WebMAudioSource(file: try WebMFile(url: u), sampleRate: 48000)
        XCTAssertEqual(file.length, src.totalFrames)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }

    func testFrameIndicesFollowRange() {
        let es = (0..<10).map { SampleIndex.Entry(pts: Time(Int64($0), 10), dts: Time(Int64($0), 10), duration: Time(1, 10), isSync: $0 == 0, decodeOrdinal: $0) }
        let idx = SampleIndex(entries: es)
        XCTAssertEqual(WebMReadback.frameIndices(in: idx, range: nil), 0...9)
        XCTAssertEqual(WebMReadback.frameIndices(in: idx, range: TimeRange(start: Time(3, 10), duration: Time(3, 10))), 3...5)
        XCTAssertNil(WebMReadback.frameIndices(in: idx, range: TimeRange(start: Time(20, 10), duration: Time(1, 10))))
    }
}
