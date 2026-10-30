import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Synchronization
import Testing
import VideoToolbox
@testable import SQMedia

// .mkv with H.264 / HEVC: the Matroska demuxer hands the length-prefixed samples to VideoToolbox as they are.

private func tmpURL(_ ext: String = "mkv") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).\(ext)")
}

/// Fake avcC: profile High, level 4.0, 4-byte NAL lengths, one SPS and one PPS (content not validated by the demuxer).
private func fakeAVCC() -> Data { Data([1, 100, 0, 40, 0xFF, 0xE1, 0, 4, 0x67, 1, 2, 3, 1, 0, 3, 0x68, 4, 5]) }
private func fakeHVCC() -> Data { Data([1]) + Data(repeating: 0, count: 20) + Data([0x03, 0]) }

private func nal(_ n: Int) -> Data { Data([0, 0, 0, 5, 0x41, UInt8(n), 0, 0, 0]) }

/// Decode order I0 P3 B1 B2 P6 B4 B5 | I7 P8 (pts in units of 100 ms), two GOPs.
private func bFrameWriter() -> (WebMTestWriter, [Int]) {
    let order = [0, 3, 1, 2, 6, 4, 5, 7, 8]
    var w = WebMTestWriter()
    w.keepOrder = true
    w.tracks = [.init(number: 1, isVideo: true, codecID: "V_MPEG4/ISO/AVC", codecPrivate: fakeAVCC(), width: 64, height: 48)]
    for p in order { w.frames.append(.init(track: 1, ms: p * 100, key: p == 0 || p == 7, data: nal(p))) }
    return (w, order)
}

private func write(_ w: WebMTestWriter) throws -> URL {
    let u = tmpURL()
    try w.data().write(to: u)
    return u
}

@Suite struct MatroskaH264Tests {
    @Test func detectsContainerAndParsesTrack() throws {
        let u = try write(bFrameWriter().0); defer { try? FileManager.default.removeItem(at: u) }
        #expect(WebMFile.isWebM(u))
        let f = try WebMFile.open(u)
        let t = try #require(f.track(.video))
        #expect(t.codecID == "V_MPEG4/ISO/AVC" && t.width == 64 && t.height == 48)
        #expect(t.codecPrivate == fakeAVCC())
        #expect(f.blocks(of: 1).count == 9)
    }

    @Test func formatDescriptionCarriesAvcC() throws {
        let u = try write(bFrameWriter().0); defer { try? FileManager.default.removeItem(at: u) }
        let d = try WebMDemuxer(file: try WebMFile.open(u))
        #expect(d.formatDescription.mediaSubType.rawValue == kCMVideoCodecType_H264)
        let dims = CMVideoFormatDescriptionGetDimensions(d.formatDescription)
        #expect(dims.width == 64 && dims.height == 48)
        let ext = CMFormatDescriptionGetExtensions(d.formatDescription) as? [String: Any]
        let atoms = ext?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        #expect((atoms?["avcC"] as? Data) == fakeAVCC())
    }

    @Test func hevcFormatDescriptionCarriesHvcC() throws {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: true, codecID: "V_MPEGH/ISO/HEVC", codecPrivate: fakeHVCC(), width: 64, height: 48)]
        w.frames = [.init(track: 1, ms: 0, key: true, data: nal(0)), .init(track: 1, ms: 40, key: false, data: nal(1))]
        let u = try write(w); defer { try? FileManager.default.removeItem(at: u) }
        let d = try WebMDemuxer(file: try WebMFile.open(u))
        #expect(d.formatDescription.mediaSubType.rawValue == kCMVideoCodecType_HEVC)
        #expect(d.index.count == 2)
    }

    @Test func bFramesGetPresentationAndMonotonicDecodeTimes() async throws {
        let (w, order) = bFrameWriter()
        let u = try write(w); defer { try? FileManager.default.removeItem(at: u) }
        let d = try WebMDemuxer(file: try WebMFile.open(u))
        let e = d.index.entries
        #expect(e.count == 9)
        // Presentation order is 0...8 at 100 ms, each frame is 100 ms long.
        for (i, x) in e.enumerated() { #expect(x.pts == Time(Int64(i), 10) && x.duration == Time(1, 10)) }
        // Decode ordinal k holds frame order[k]; dts never decreases and never passes pts.
        for (i, x) in e.enumerated() { #expect(x.decodeOrdinal == order.firstIndex(of: i)) }
        let byOrdinal = e.sorted { $0.decodeOrdinal < $1.decodeOrdinal }
        for k in 1..<byOrdinal.count { #expect(byOrdinal[k].dts > byOrdinal[k - 1].dts) }
        for x in byOrdinal { #expect(x.dts <= x.pts) }
        #expect(e.map(\.isSync) == [true, false, false, false, false, false, false, true, false])
        // Samples come out in decode order with those times.
        let s = try await d.samples(for: 0...6)
        #expect(s.count == 7)
        let pts = s.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        #expect(pts == [0, 0.3, 0.1, 0.2, 0.6, 0.4, 0.5])
        let dts = s.map { CMSampleBufferGetDecodeTimeStamp($0).seconds }
        #expect(dts == dts.sorted())
    }

    @Test func seekStartsAtTheKeyframeBeforeTheFrame() async throws {
        let u = try write(bFrameWriter().0); defer { try? FileManager.default.removeItem(at: u) }
        let d = try WebMDemuxer(file: try WebMFile.open(u))
        // Frame 8 lives in the second GOP: decoding starts at frame 7 (decode ordinal 7).
        #expect(d.index.syncDecodeOrdinal(for: 8) == 7)
        let s = try await d.samples(for: 8...8)
        #expect(s.count == 2)
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(s[0]).seconds - 0.7) < 0.001)
        // Frame 5 (a B-frame of the first GOP) is decoded from the first key frame through P6.
        #expect(d.index.syncDecodeOrdinal(for: 5) == 0)
        #expect(try await d.samples(for: 5...5).count == 7)
    }

    @Test func otherCodecsKeepTheClearError() throws {
        for (id, name) in [("V_MPEG4/ISO/AP", "MPEG4/ISO/AP"), ("V_VP8", "VP8"), ("V_MS/VFW/FOURCC", "MS/VFW/FOURCC")] {
            var w = WebMTestWriter()
            w.tracks = [.init(number: 1, isVideo: true, codecID: id, width: 64, height: 48)]
            w.frames = [.init(track: 1, ms: 0, key: true, data: Data(repeating: 0, count: 8))]
            let u = try write(w); defer { try? FileManager.default.removeItem(at: u) }
            do { _ = try WebMDemuxer(file: try WebMFile.open(u)); Issue.record("\(id) must throw") }
            catch MediaError.unsupportedCodec(let n) { #expect(n == name) }
        }
    }

    @Test func brokenConfigurationRecordIsUnreadable() throws {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: true, codecID: "V_MPEG4/ISO/AVC", codecPrivate: Data([1, 2]), width: 64, height: 48)]
        w.frames = [.init(track: 1, ms: 0, key: true, data: nal(0))]
        let u = try write(w); defer { try? FileManager.default.removeItem(at: u) }
        #expect(throws: MediaError.self) { _ = try WebMDemuxer(file: try WebMFile.open(u)) }
    }

    /// Real encoded H.264 / HEVC (written with AVAssetWriter, B-frames where the encoder uses them) copied sample by
    /// sample into a Matroska file: same frame times as the MP4, and VideoToolbox decodes every frame.
    @Test(arguments: [TestClipSpec.Codec.h264, .hevcMain10])
    func remuxedRealStreamDecodes(codec: TestClipSpec.Codec) async throws {
        var spec = TestClipSpec(); spec.codec = codec; spec.frameCount = 45; 
        let mp4: URL
        do { mp4 = try await TestClipWriter.write(spec) }
        catch TestClipError.encoderUnavailable(let why) { Issue.record("encoder unavailable: \(why)"); return }
        defer { try? FileManager.default.removeItem(at: mp4) }
        let asset = AVURLAsset(url: mp4)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        #expect(reader.startReading())
        var w = WebMTestWriter()
        w.keepOrder = true
        var atom: Data?
        var id = ""
        var count = 0
        while let sb = out.copyNextSampleBuffer() {
            if atom == nil, let fd = CMSampleBufferGetFormatDescription(sb) {
                let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
                let atoms = ext?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
                if let a = atoms?["avcC"] as? Data { atom = a; id = "V_MPEG4/ISO/AVC" }
                else if let a = atoms?["hvcC"] as? Data { atom = a; id = "V_MPEGH/ISO/HEVC" }
            }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(bb))
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first
            let notSync = (att?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            w.frames.append(.init(track: 1, ms: Int((pts.seconds * 1000).rounded()), key: !notSync, data: data))
            count += 1
        }
        w.tracks = [.init(number: 1, isVideo: true, codecID: id, codecPrivate: try #require(atom), width: Int(spec.width), height: Int(spec.height))]
        #expect(count == 45)
        let mkv = try write(w); defer { try? FileManager.default.removeItem(at: mkv) }

        let d = try WebMDemuxer(file: try WebMFile.open(mkv))
        let ref = try await AVDemuxer(url: mp4)
        #expect(d.index.count == ref.index.count)
        for (a, b) in zip(d.index.entries, ref.index.entries) {
            #expect(abs(a.pts.cmTime.seconds - b.pts.cmTime.seconds) < 0.002, "pts \(a.pts) vs \(b.pts)")
            #expect(a.isSync == b.isSync)
        }
        // Decode all frames with VideoToolbox.
        let samples = try await d.samples(for: 0...(d.index.count - 1))
        var session: VTDecompressionSession?
        #expect(VTDecompressionSessionCreate(allocator: nil, formatDescription: d.formatDescription, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr)
        let s = try #require(session)
        let decoded = Mutex(0)
        for sb in samples {
            VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { st, _, img, _, _ in
                if st == noErr, img != nil { decoded.withLock { $0 += 1 } }
            }
        }
        VTDecompressionSessionFinishDelayedFrames(s)
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        #expect(decoded.withLock { $0 } == 45)
    }
}
