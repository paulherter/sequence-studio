import XCTest
import AVFoundation
import SQCore
@testable import SQMedia

final class MXFTests: XCTestCase {
    private typealias F = MXFFixture

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 29)
        }
    }

    private func smallFrames(_ n: Int, spec: H264TestStream.Spec = .init()) -> [Data] {
        (0..<n).map { H264TestStream.frame(spec, luma: 40 + 20 * ($0 % 8), idrID: $0 & 1) }
    }

    private func write(_ data: Data, name: String = "clip") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mxf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(name).MXF")
        try data.write(to: url)
        return url
    }

    /// Center luma sample and its bit depth, nil for pixel formats this helper does not know.
    private func centerLuma(_ pb: CVPixelBuffer) -> (value: Int, bits: Int)? {
        guard CVPixelBufferIsPlanar(pb) else { return nil }
        let type = CVPixelBufferGetPixelFormatType(pb)
        let first = UInt8(type >> 24)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let row = base + (h / 2) * CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        if first == UInt8(ascii: "x") {
            return (Int(row.load(fromByteOffset: (w / 2) * 2, as: UInt16.self)) >> 6, 10)
        }
        if first == UInt8(ascii: "4") { return (Int(row.load(fromByteOffset: w / 2, as: UInt8.self)), 8) }
        return nil
    }

    private static let measureFile = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mxf-decode-measure.txt")
    private func record(_ line: String) {
        let old = (try? String(contentsOf: Self.measureFile, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: Self.measureFile, atomically: true, encoding: .utf8)
    }

    // MARK: KLV and BER

    func testBERLengths() {
        XCTAssertEqual(MXFBER.decode([0x00])?.length, 0)
        XCTAssertEqual(MXFBER.decode([0x7F])?.length, 127)
        XCTAssertEqual(MXFBER.decode([0x7F])?.size, 1)
        XCTAssertEqual(MXFBER.decode([0x81, 0x80])?.length, 128)
        XCTAssertEqual(MXFBER.decode([0x83, 0x01, 0x02, 0x03])?.length, 0x010203)
        XCTAssertEqual(MXFBER.decode([0x83, 0x01, 0x02, 0x03])?.size, 4)
        XCTAssertEqual(MXFBER.decode([0x88, 0, 0, 0, 0, 0, 0, 1, 0])?.length, 256)
        XCTAssertNil(MXFBER.decode([]))
        XCTAssertNil(MXFBER.decode([0x80]), "indefinite length")
        XCTAssertNil(MXFBER.decode([0x89, 0, 0, 0, 0, 0, 0, 0, 0, 1]), "more than 8 length bytes")
        XCTAssertNil(MXFBER.decode([0x84, 0x01, 0x02]), "cut off")
    }

    func testKLVWalk() {
        let a = F.klv(F.fillKey, [1, 2, 3], long: 0), b = F.klv(F.pictureKey, [UInt8](repeating: 9, count: 300), long: 3)
        let r = MXFBytes(Data(a + b + [0x06, 0x0E]))
        let first = r.klv(at: 0), second = r.klv(at: a.count)
        XCTAssertEqual(first?.length, 3); XCTAssertEqual(first?.valueOffset, 17); XCTAssertEqual(first?.key.isFill, true)
        XCTAssertEqual(second?.length, 300); XCTAssertEqual(second?.valueOffset, a.count + 20)
        XCTAssertEqual(second?.key.isEssenceElement, true); XCTAssertEqual(second?.key.trackNumber, 0x1501_0500)
        XCTAssertNil(r.klv(at: a.count + b.count), "key cut off")
        XCTAssertNil(r.klv(at: -4)); XCTAssertNil(r.klv(at: 1 << 40))
        // A length that reaches past the end is returned, and does not fit.
        let cut = MXFBytes(Data(b.prefix(100)))
        XCTAssertEqual(cut.klv(at: 0).map { cut.fits($0) }, false)
        XCTAssertNil(MXFBytes(Data(F.pictureKey + [0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])).klv(at: 0), "absurd length")
        XCTAssertNil(r.u32(r.count - 3)); XCTAssertNil(r.slice(4..<(r.count + 1)))
        XCTAssertEqual(MXFUL(F.pictureKey).bytes, F.pictureKey)
        XCTAssertEqual(MXFUL(F.partitionKey(0x04)).partitionKind, 4)
        XCTAssertTrue(MXFUL(F.systemKey).isSystemItem); XCTAssertFalse(MXFUL(F.systemKey).isPartitionPack)
    }

    // MARK: partitions, metadata

    func testPartitionsRunInAndRandomIndexPack() throws {
        var fx = F()
        fx.frames = smallFrames(9); fx.runIn = 512; fx.bodyPartitions = 3; fx.audioTracks = 2
        for rip in [true, false] {
            fx.hasRIP = rip
            let f = try MXFFile(data: fx.build())
            XCTAssertEqual(f.runIn, 512)
            XCTAssertEqual(f.partitionCount, 5, "header, three bodies, footer (rip: \(rip))")
            XCTAssertTrue(f.usesIndexTable)
            XCTAssertEqual(f.unitCount, 9)
            for u in 0..<9 {
                let r = try XCTUnwrap(f.pictureRange(ofUnit: u))
                XCTAssertEqual(f.bytes.slice(r), fx.frames[u], "unit \(u)")
                XCTAssertEqual(f.elements(ofUnit: u).map(\.track), [0x1501_0500, 0x1602_0300, 0x1602_0301])
            }
        }
        // Essence in the header partition, no system items.
        fx.bodyPartitions = 0; fx.hasSystemItem = false; fx.runIn = 0
        let f = try MXFFile(data: fx.build())
        XCTAssertEqual(f.partitionCount, 2); XCTAssertEqual(f.unitCount, 9); XCTAssertTrue(f.usesIndexTable)
        XCTAssertEqual(f.bytes.slice(try XCTUnwrap(f.pictureRange(ofUnit: 8))), fx.frames[8])
    }

    func testIsMXF() throws {
        var fx = F(); fx.frames = smallFrames(2)
        XCTAssertTrue(MXFFile.isMXF(try write(fx.build())))
        fx.runIn = 4096
        XCTAssertTrue(MXFFile.isMXF(try write(fx.build())), "run-in")
        XCTAssertFalse(MXFFile.isMXF(try write(Data(repeating: 7, count: 5000))))
        XCTAssertFalse(MXFFile.isMXF(try write(Data([1, 2, 3]))))
        XCTAssertThrowsError(try MXFFile(data: Data(repeating: 0, count: 4000)))
    }

    func testDescriptorMapping() throws {
        var fx = F()
        fx.frames = smallFrames(4); fx.audioTracks = 4; fx.editRate = (30_000, 1001); fx.samplesPerUnit = [1602, 1601, 1602, 1601, 1602]
        fx.transfer = F.label(0x01, 0x0B); fx.primaries = F.label(0x03, 0x04); fx.equations = F.label(0x02, 0x06)
        for linked in [true, false] {
            fx.linkedTrackIDs = linked
            let f = try MXFFile(data: fx.build())
            XCTAssertEqual(f.tracks.map(\.kind), [.picture, .sound, .sound, .sound, .sound])
            let v = try XCTUnwrap(f.videoTrack), p = try XCTUnwrap(v.picture)
            XCTAssertEqual(v.editUnit, Time(1001, 30_000)); XCTAssertEqual(v.duration, 4); XCTAssertEqual(v.number, 0x1501_0500)
            XCTAssertEqual(p.storedWidth, 1920); XCTAssertEqual(p.storedHeight, 1080); XCTAssertEqual(p.displayHeight, 1080)
            XCTAssertEqual(p.componentDepth, 10); XCTAssertEqual(p.chroma, "4:2:2"); XCTAssertFalse(p.isInterlaced)
            XCTAssertEqual(p.aspect?.num, 16); XCTAssertEqual(p.aspect?.den, 9)
            XCTAssertEqual(p.transferTag, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            XCTAssertEqual(p.primariesTag, kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
            XCTAssertEqual(p.matrixTag, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
            XCTAssertEqual(f.videoCodec, .h264)
            let s = try XCTUnwrap(f.soundTracks.last?.sound)
            XCTAssertEqual(s.sampleRate, 48_000); XCTAssertEqual(s.bits, 24); XCTAssertEqual(s.channels, 1)
            XCTAssertEqual(s.bytesPerSample, 3); XCTAssertTrue(s.isPCM); XCTAssertFalse(s.isBigEndian)
            XCTAssertEqual(f.soundTracks.map(\.number), [0x1604_0300, 0x1604_0301, 0x1604_0302, 0x1604_0303])
        }
    }

    func testCodecIdentification() {
        func id(_ tail: [UInt8]) -> MXFVideoCodec? { MXFVideoCodec.identify(coding: MXFUL(F.coding(tail)), container: nil) }
        XCTAssertEqual(id([0x01, 0x32, 0x31, 0x01]), .h264)
        XCTAssertEqual(id([0x01, 0x31, 0x60, 0x01]), .h264)
        XCTAssertEqual(id([0x03, 0x06, 0x04, 0x00]), .prores(MXFVideoCodec.code("apch")))
        XCTAssertEqual(id([0x03, 0x06, 0x05, 0x00]), .prores(MXFVideoCodec.code("ap4h")))
        XCTAssertEqual(id([0x71, 0x01, 0x00, 0x00]), .unsupported("DNxHD / DNxHR"))
        XCTAssertEqual(id([0x03, 0x02, 0x01, 0x00]), .unsupported("DNxHD / DNxHR"))
        XCTAssertEqual(id([0x01, 0x04, 0x03, 0x00]), .unsupported("MPEG-2 (XDCAM / IMX)"))
        XCTAssertEqual(id([0x03, 0x01, 0x01, 0x00]), .unsupported("JPEG 2000"))
        XCTAssertEqual(id([0x02, 0x02, 0x02, 0x00]), .unsupported("DV"))
        XCTAssertEqual(MXFVideoCodec.identify(coding: nil, container: MXFUL(F.avcContainer)), .h264)
        XCTAssertNil(MXFVideoCodec.identify(coding: nil, container: nil))
    }

    func testTimecode() throws {
        XCTAssertEqual(MXFTimecode(startFrame: 90_000, base: 25, dropFrame: false).string, "01:00:00:00")
        XCTAssertEqual(MXFTimecode(startFrame: 1_799, base: 30, dropFrame: true).string, "00:00:59;29")
        XCTAssertEqual(MXFTimecode(startFrame: 1_800, base: 30, dropFrame: true).string, "00:01:00;02")
        XCTAssertEqual(MXFTimecode(startFrame: 17_982, base: 30, dropFrame: true).string, "00:10:00;00")
        XCTAssertEqual(MXFTimecode(startFrame: 107_892, base: 30, dropFrame: true).string, "01:00:00;00")
        XCTAssertEqual(MXFTimecode(startFrame: 3_600, base: 60, dropFrame: true).string, "00:01:00;04")
        XCTAssertEqual(MXFTimecode(startFrame: 1_800, base: 30, dropFrame: false).string, "00:01:00:00")
        XCTAssertEqual(MXFTimecode(startFrame: 5, base: 0, dropFrame: false).string, "00:00:00:00")

        var fx = F(); fx.frames = smallFrames(2)
        fx.timecode = (107_892, 30, true)
        let tc = try XCTUnwrap(try MXFFile(data: fx.build()).timecode)
        XCTAssertEqual(tc, MXFTimecode(startFrame: 107_892, base: 30, dropFrame: true))
        fx.timecode = nil
        XCTAssertNil(try MXFFile(data: fx.build()).timecode)
    }

    // MARK: index table, seek mapping

    /// Two groups of pictures stored I P B B P B B, shown I B B P B B P.
    private func longGOP() -> F {
        var fx = F()
        fx.frames = smallFrames(14); fx.coding = F.avcLongCoding
        fx.temporalOffsets = [0, 1, 1, -2, 1, 1, -2, 0, 1, 1, -2, 1, 1, -2]
        fx.flags = [0xC0, 0x22, 0x33, 0x33, 0x22, 0x33, 0x33, 0xC0, 0x22, 0x33, 0x33, 0x22, 0x33, 0x33]
        return fx
    }

    func testIndexKeyFramesAndDisplayOrder() async throws {
        var fx = longGOP()
        for segment in [1000, 5] {
            fx.segmentSize = segment
            let d = try MXFDemuxer(file: try MXFFile(data: fx.build()))
            XCTAssertTrue(d.file.usesIndexTable); XCTAssertFalse(d.isIntraOnly)
            XCTAssertEqual(d.index.count, 14)
            XCTAssertEqual(d.index.entries.map(\.decodeOrdinal), [0, 2, 3, 1, 5, 6, 4, 7, 9, 10, 8, 12, 13, 11])
            XCTAssertEqual(d.index.entries.filter(\.isSync).map(\.decodeOrdinal), [0, 7])
            XCTAssertEqual(d.index.entries.map(\.pts), (0..<14).map { Time(Int64($0), 25) })
            XCTAssertTrue(d.index.entries.allSatisfy { $0.dts <= $0.pts })
            XCTAssertEqual(d.index.duration, Time(14, 25))

            // Frame 9 is stored last of the second group's first four: the group's key frame and what precedes it are needed.
            let seek = try await d.samples(for: 9...9)
            XCTAssertEqual(seek.count, 4)
            XCTAssertEqual(Time(CMSampleBufferGetPresentationTimeStamp(seek[0])), Time(7, 25))
            XCTAssertEqual(Time(CMSampleBufferGetPresentationTimeStamp(seek[3])), Time(9, 25))
            // Frame 6 (a P frame stored before its B frames) from the first key frame.
            let six = try await d.samples(for: 6...6).count
            XCTAssertEqual(six, 5)
            let all = try await d.samples(for: 0...13).count
            XCTAssertEqual(all, 14)
            do { _ = try await d.samples(for: 10...14); XCTFail("out of range") } catch {}
        }
    }

    func testIntraOnlyIndexAndPayload() async throws {
        var fx = F(); fx.frames = smallFrames(6); fx.frames[2] = H264TestStream.frame(.init(), luma: 99, accessUnitDelimiter: true, filler: 500)
        let d = try MXFDemuxer(file: try MXFFile(data: fx.build()))
        XCTAssertTrue(d.isIntraOnly)
        let one = try await d.samples(for: 4...4).count
        XCTAssertEqual(one, 1, "any frame of an intra file is a seek point")
        // Length-prefixed for VideoToolbox: delimiter and filler are gone, the sizes add up.
        let p = try d.payload(ordinal: 2)
        let nals = try XCTUnwrap(p.withUnsafeBytes { H264AnnexB.lengthPrefixedRanges($0.bindMemory(to: UInt8.self)) })
        XCTAssertEqual(nals.map { p[p.startIndex + $0.lowerBound] & 0x1F }, [7, 8, 5])
        XCTAssertLessThan(p.count, fx.frames[2].count - 500)
        let dims = CMVideoFormatDescriptionGetDimensions(d.formatDescription)
        XCTAssertEqual(dims.width, 64); XCTAssertEqual(dims.height, 48)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(d.formatDescription), kCMVideoCodecType_H264)
    }

    func testConstantBytesPerUnitIndex() throws {
        var fx = F(); fx.frames = smallFrames(8); fx.index = .cbr; fx.audioTracks = 2
        let f = try MXFFile(data: fx.build())
        XCTAssertTrue(f.usesIndexTable); XCTAssertEqual(f.unitCount, 8)
        for u in 0..<8 { XCTAssertEqual(f.bytes.slice(try XCTUnwrap(f.pictureRange(ofUnit: u))), fx.frames[u]) }
        XCTAssertTrue(try MXFDemuxer(file: f).isIntraOnly)
    }

    func testScanWithoutIndex() throws {
        var fx = F(); fx.frames = smallFrames(7); fx.audioTracks = 2
        // No index table; then a file still being written: no footer, open header partition.
        for (index, footer) in [(F.Index.none, true), (.vbr, false)] {
            fx.index = index; fx.hasFooter = footer
            for system in [true, false] {
                fx.hasSystemItem = system
                let data = fx.build()
                let f = try MXFFile(data: data)
                XCTAssertFalse(f.usesIndexTable); XCTAssertEqual(f.unitCount, 7)
                XCTAssertEqual(f.bytes.slice(try XCTUnwrap(f.pictureRange(ofUnit: 6))), fx.frames[6])
                XCTAssertEqual(try MXFDemuxer(file: f).index.count, 7)
                XCTAssertEqual(try MXFAudioSource(file: f, sampleRate: 48_000).totalFrames, 7 * 1920)
                if !footer {
                    // Cut inside the last picture: that unit is gone, the rest plays.
                    let cut = try MXFFile(data: data.prefix(data.count - 2 * 1920 * 3 - fx.frames[6].count / 2 - 150))
                    XCTAssertEqual(cut.unitCount, 6)
                    XCTAssertEqual(try MXFDemuxer(file: cut).index.count, 6)
                }
            }
        }
    }

    func testBrokenIndexFallsBackToScanAndKeepsEntries() throws {
        var fx = longGOP()
        var data = fx.build()
        // Shift every stream offset: the index no longer lands on content packages.
        let f0 = try MXFFile(data: data)
        XCTAssertTrue(f0.usesIndexTable)
        var hits = 0
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = p.count - 16
            while i > 0 {
                if (0..<16).allSatisfy({ p[i + $0] == F.indexKey[$0] }) {
                    var o = i + 16 + 5
                    while o + 4 < p.count {
                        let tag = Int(p[o]) << 8 | Int(p[o + 1]), len = Int(p[o + 2]) << 8 | Int(p[o + 3])
                        if tag == 0x3F0A { for e in 0..<14 { p[o + 4 + 8 + e * 11 + 10] &+= 3 }; hits += 1; break }
                        o += 4 + len
                    }
                    break
                }
                i -= 1
            }
        }
        XCTAssertEqual(hits, 1)
        let f = try MXFFile(data: data)
        XCTAssertFalse(f.usesIndexTable); XCTAssertEqual(f.unitCount, 14)
        XCTAssertEqual(try MXFDemuxer(file: f).index.entries.map(\.decodeOrdinal), [0, 2, 3, 1, 5, 6, 4, 7, 9, 10, 8, 12, 13, 11])
        fx.index = .none
        XCTAssertEqual(try MXFFile(data: fx.build()).unitCount, 14)
    }

    func testStreamScanGivesOrderWithoutIndex() throws {
        // Stored I P B B | I P B B with explicit picture order counts and no index: order and key frames from the slices.
        var spec = H264TestStream.Spec(); spec.pocType = 0
        var fx = F(); fx.coding = F.avcLongCoding; fx.index = .none
        let poc = [0, 6, 2, 4]
        for g in 0..<2 {
            for (i, p) in poc.enumerated() {
                fx.frames.append(H264TestStream.frame(spec, luma: 60, idr: i == 0, reference: i < 2, idrID: g, frameNum: i, pocLsb: p,
                                                      parameterSets: i == 0))
            }
        }
        let d = try MXFDemuxer(file: try MXFFile(data: fx.build()))
        XCTAssertEqual(d.index.entries.map(\.decodeOrdinal), [0, 2, 3, 1, 4, 6, 7, 5])
        XCTAssertEqual(d.index.entries.filter(\.isSync).map(\.decodeOrdinal), [0, 4])
        XCTAssertFalse(d.isIntraOnly)
        // The intra label says every frame is a key frame: no scan.
        fx.coding = F.avcIntraCoding
        XCTAssertTrue(try MXFDemuxer(file: try MXFFile(data: fx.build())).isIntraOnly)
    }

    // MARK: review fixes

    private func bytes(_ sb: CMSampleBuffer) -> Data {
        guard let b = CMSampleBufferGetDataBuffer(sb) else { return Data() }
        var d = Data(count: CMBlockBufferGetDataLength(b))
        _ = d.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        return d
    }

    /// Forward playback of long GOP: a continued read starts at the given decode ordinal, not at the key frame.
    func testContinuedReadStartsAtTheGivenDecodeOrdinal() async throws {
        let d = try MXFDemuxer(file: try MXFFile(data: longGOP().build()))
        // Display frame 12 is stored at 13, its key frame at 7.
        let full = try await d.samples(for: 12...12)
        let tail = try await d.samples(for: 12...12, fromDecodeOrdinal: 11)
        XCTAssertEqual(full.count, 7); XCTAssertEqual(tail.count, 3)
        XCTAssertEqual(tail.map { Time(CMSampleBufferGetPresentationTimeStamp($0)) }, full.suffix(3).map { Time(CMSampleBufferGetPresentationTimeStamp($0)) })
        XCTAssertEqual(tail.map(bytes), full.suffix(3).map(bytes))
        for (i, s) in full.enumerated() { XCTAssertEqual(bytes(s), try d.payload(ordinal: 7 + i), "written straight into the block buffer") }
        // Nothing left to read; an ordinal before the key frame starts at the key frame.
        let none = try await d.samples(for: 9...9, fromDecodeOrdinal: 12).count
        XCTAssertEqual(none, 0)
        let early = try await d.samples(for: 9...9, fromDecodeOrdinal: 3).count
        XCTAssertEqual(early, 4)
        do { _ = try await d.samples(for: 10...14, fromDecodeOrdinal: 11); XCTFail("out of range") } catch {}

        // The decoder's continued decode (the playback path) gets every picture once, in order.
        let decoder = try VTVideoDecoder(demuxer: d, media: UUID())
        defer { decoder.invalidate() }
        var pts: [Time] = []
        for r in [0...3, 4...8, 9...13] { pts += try await decoder.decode(r).map(\.pts) }
        XCTAssertEqual(pts, (0..<14).map { Time(Int64($0), 25) })
    }

    /// Essence that starts past the end of its partition: no index, no trap (the essence scan takes over).
    func testCorruptPartitionLayoutGivesNoIndexInsteadOfATrap() throws {
        var part = MXFPartition(); part.essenceStart = 500; part.essenceEnd = 100
        var later = MXFPartition(); later.offset = 100; later.essenceStart = 140; later.essenceEnd = 1000; later.bodyOffset = 64
        let bytes = MXFBytes(Data(count: 1000))
        for constant in [0, 64] {
            var s = MXFIndexSegment(); s.duration = 3; s.editUnitByteCount = constant
            if constant == 0 { s.streamOffsets = [0, 64, 128]; s.temporalOffsets = [0, 0, 0]; s.flags = [0x80, 0x80, 0x80] }
            XCTAssertNil(MXFFile.unitsFromIndex(bytes, parts: [part], segments: [s], tracks: []))
            XCTAssertNil(MXFFile.unitsFromIndex(bytes, parts: [part, later], segments: [s], tracks: []))
            XCTAssertNil(MXFFile.unitsFromIndex(bytes, parts: [later, part], segments: [s], tracks: []))
        }

        // In a file: the footer partition offset of the random index pack points before the body's essence.
        var fx = F(); fx.frames = smallFrames(6); fx.audioTracks = 2; fx.bodyPartitions = 2
        let data = fx.build()
        var rng = LCG(state: 11)
        for _ in 0..<300 {
            var d = data
            // Any 8-byte position field of a partition pack or the random index pack set to a small or huge value.
            let at = Int.random(in: 0..<(d.count - 8), using: &rng)
            let value = [UInt64(0), 1, 40, 0x7FFF_FFFF_FFFF_FFFF, UInt64(d.count - 1)].randomElement(using: &rng)!
            for i in 0..<8 { d[at + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * (7 - i))) }
            if let f = try? MXFFile(data: d) { _ = try? MXFDemuxer(file: f) }
        }
    }

    /// A scaling list delta outside the standard's range used to overflow.
    func testCraftedScalingListIsRejected() {
        func sps(_ delta: (inout H264TestStream.Bits) -> Void) -> [UInt8] {
            var b = H264TestStream.Bits()
            b.put(100, 8); b.put(0, 16); b.ue(0)
            b.ue(1); b.ue(0); b.ue(0); b.put(0, 1)
            b.put(1, 1)                                       // scaling matrix
            b.put(1, 1)                                       // first list
            delta(&b)
            for _ in 0..<15 { b.se(0) }
            for _ in 0..<7 { b.put(0, 1) }
            b.ue(0); b.ue(2); b.ue(1); b.put(0, 1); b.ue(3); b.ue(2); b.put(1, 1); b.put(1, 1); b.put(0, 1); b.put(0, 1)
            b.trailing()
            return [0x67] + b.bytes
        }
        XCTAssertNil(H264AnnexB.sps(sps { $0.ue(0xFFFF_FFFD) }), "delta Int32.max")
        XCTAssertNil(H264AnnexB.sps(sps { $0.ue(0xFFFF_FFFE) }), "delta -Int32.max")
        XCTAssertNil(H264AnnexB.sps(sps { $0.se(128) }))
        XCTAssertNil(H264AnnexB.sps(sps { $0.se(-129) }))
        XCTAssertEqual(H264AnnexB.sps(sps { $0.se(-128) })?.profile, 100)
        XCTAssertEqual(H264AnnexB.sps(sps { $0.se(127) })?.pocType, 2)
    }

    /// Flags for every frame but a temporal offset that points outside the clip: the order comes from the stream,
    /// not stored order.
    func testInvalidTemporalOffsetsFallBackToTheStream() throws {
        var spec = H264TestStream.Spec(); spec.pocType = 0
        var fx = F(); fx.coding = F.avcLongCoding
        let poc = [0, 6, 2, 4]
        for g in 0..<2 {
            for (i, p) in poc.enumerated() {
                fx.frames.append(H264TestStream.frame(spec, luma: 60, idr: i == 0, reference: i < 2, idrID: g, frameNum: i, pocLsb: p,
                                                      parameterSets: i == 0))
            }
        }
        fx.flags = [0xC0, 0x22, 0x33, 0x33, 0xC0, 0x22, 0x33, 0x33]
        for offsets: [Int8] in [[0, 1, 1, -2, 0, 1, 1, 90], [0, 1, 1, -2, 0, 1, 1, 0], [-1, 1, 1, -2, 0, 1, 1, -2]] {
            fx.temporalOffsets = offsets
            let d = try MXFDemuxer(file: try MXFFile(data: fx.build()))
            XCTAssertTrue(d.file.usesIndexTable)
            XCTAssertEqual(d.index.entries.map(\.decodeOrdinal), [0, 2, 3, 1, 4, 6, 7, 5], "\(offsets)")
            XCTAssertEqual(d.index.entries.filter(\.isSync).map(\.decodeOrdinal), [0, 4])
        }
        // Valid offsets are used as they are.
        fx.temporalOffsets = [0, 1, 1, -2, 0, 1, 1, -2]
        XCTAssertEqual(try MXFDemuxer(file: try MXFFile(data: fx.build())).index.entries.map(\.decodeOrdinal), [0, 2, 3, 1, 4, 6, 7, 5])
    }

    /// Files are read with positional reads: a file cut short under an open clip (card pulled, copy replaced) throws.
    func testFileBackedReadsMatchMemoryAndThrowWhenTheFileShrinks() async throws {
        var fx = F(); fx.frames = smallFrames(40); fx.audioTracks = 2
        let data = fx.build()
        let url = try write(data)
        let file = try MXFFile(url: url), memory = try MXFFile(data: data)
        XCTAssertEqual(file.unitCount, 40); XCTAssertEqual(file.usesIndexTable, memory.usesIndexTable)
        XCTAssertEqual(file.tracks, memory.tracks)
        for u in [0, 1, 17, 39] {
            XCTAssertEqual(file.pictureRange(ofUnit: u), memory.pictureRange(ofUnit: u))
            XCTAssertEqual(file.bytes.slice(try XCTUnwrap(file.pictureRange(ofUnit: u))), fx.frames[u])
        }
        // Small reads across the reader's window boundaries, and the ends of the file.
        for o in Array(4088...4100) + Array(8185...8195) + [0, data.count - 8, data.count - 7, data.count - 1, data.count, -1] {
            for n in [1, 2, 4, 8] { XCTAssertEqual(file.bytes.uint(o, n), memory.bytes.uint(o, n), "\(o) \(n)") }
        }
        XCTAssertNil(file.bytes.slice((data.count - 4)..<(data.count + 1)))
        XCTAssertEqual(file.bytes.slice(100..<100), Data())

        let d = try MXFDemuxer(file: file)
        let a = try MXFAudioSource(file: file, sampleRate: 48_000)
        let first = try await d.samples(for: 0...0)
        XCTAssertEqual(bytes(first[0]), try MXFDemuxer(file: memory).payload(ordinal: 0))

        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(data.count / 2)); try h.close()
        do { _ = try await d.samples(for: 39...39); XCTFail("the frame is gone") } catch {}
        XCTAssertThrowsError(try d.payload(ordinal: 39))
        // Sound that is gone is silence, not a crash.
        var b = [Float](repeating: 1, count: 1000)
        _ = try a.read(from: a.totalFrames - 1000, count: 1000, into: &b, channel: 0)
        XCTAssertEqual(b, [Float](repeating: 0, count: 1000))
        // Missing files and directories are errors.
        XCTAssertThrowsError(try MXFFile(url: url.deletingLastPathComponent()))
        XCTAssertThrowsError(try MXFFile(url: url.appendingPathExtension("gone")))
    }

    /// Sequential read speed of positional reads against a memory map (both from the page cache), for the engine notes.
    func testMeasureSequentialReadAgainstMemoryMap() async throws {
        let size = 1_000_000, count = 128
        var frame = F.be(UInt64(size), 4) + Array("icpf".utf8) + F.be(148, 2) + F.be(0, 2) + Array("sqsq".utf8) + F.be(1920, 2) + F.be(1080, 2) + [0x80]
        frame += [UInt8](repeating: 0x5A, count: size - frame.count)
        var fx = F(); fx.frames = Array(repeating: Data(frame), count: count); fx.coding = F.coding([0x03, 0x06, 0x03, 0x00])
        fx.pictureContainer = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0D, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x1C, 0x01, 0x00]
        let url = try write(fx.build())
        let mapped = try MXFDemuxer(file: try MXFFile(data: try Data(contentsOf: url, options: .alwaysMapped), url: url))
        let direct = try MXFDemuxer(file: try MXFFile(url: url))
        func megabytesPerSecond(_ d: MXFDemuxer) async throws -> Double {
            let start = Date()
            var total = 0
            for i in 0..<count {
                let s = try await d.samples(for: i...i)
                total += CMSampleBufferGetTotalSampleSize(s[0])
            }
            XCTAssertEqual(total, size * count)
            return Double(total) / 1e6 / Date().timeIntervalSince(start)
        }
        var best = (mapped: 0.0, direct: 0.0)
        for _ in 0..<3 {
            best.mapped = max(best.mapped, try await megabytesPerSecond(mapped))
            best.direct = max(best.direct, try await megabytesPerSecond(direct))
        }
        record("sequential read, \(count) frames of 1 MB into sample buffers: memory map \(Int(best.mapped)) MB/s, pread \(Int(best.direct)) MB/s")
        // An absolute floor, not a ratio to the map: the ratio moves around 0.4 with machine load, and what matters is
        // that reading stays far above what a card or an SSD delivers.
        XCTAssertGreaterThan(best.direct, 500, "positional reads must stay far above storage speed")
    }

    /// Thumbnails and color detection open a demuxer per call: the parse and the sample index are kept per file.
    func testSampleIndexIsBuiltOncePerFile() async throws {
        var spec = H264TestStream.Spec(); spec.pocType = 0
        var fx = F(); fx.coding = F.avcLongCoding; fx.index = .none
        for g in 0..<3 {
            for (i, p) in [0, 6, 2, 4].enumerated() {
                fx.frames.append(H264TestStream.frame(spec, luma: 60, idr: i == 0, reference: i < 2, idrID: g, frameNum: i, pocLsb: p,
                                                      parameterSets: i == 0))
            }
        }
        let url = try write(fx.build())
        let file = try MXFFile.open(url)
        XCTAssertEqual(file.shared.indexBuilds.withLock { $0 }, 0)
        let a = try await MXFDemuxer(url: url), b = try await MXFDemuxer(url: url)
        XCTAssertTrue(a.file.shared === file.shared); XCTAssertTrue(b.file.shared === file.shared)
        XCTAssertEqual(file.shared.indexBuilds.withLock { $0 }, 1, "the stream scan and the sort ran once")
        XCTAssertEqual(a.index.entries.map(\.decodeOrdinal), [0, 2, 3, 1, 4, 6, 7, 5, 8, 10, 11, 9])
        XCTAssertEqual(b.index.entries.map(\.decodeOrdinal), a.index.entries.map(\.decodeOrdinal))
        XCTAssertTrue(a.formatDescription === b.formatDescription)
        let one = try await b.samples(for: 5...5).count
        XCTAssertEqual(one, 3)

        // Another size or modification date is another file.
        fx.frames.removeLast(4)
        try fx.build().write(to: url)
        let changed = try await MXFDemuxer(url: url)
        XCTAssertFalse(changed.file.shared === file.shared)
        XCTAssertEqual(changed.index.count, 8)
    }

    /// The cache keeps the parse, never an open file (a camera card must be ejectable after import), and drops
    /// the least recently used parse first.
    func testCachedParseHoldsNoOpenFile() throws {
        var fx = F(); fx.frames = smallFrames(4)
        let data = fx.build()
        let url = try write(data)
        weak var reader: MXFFileReader?
        do {
            let a = try MXFFile.open(url), b = try MXFFile.open(url)
            XCTAssertFalse(a === b); XCTAssertTrue(a.shared === b.shared)
            XCTAssertFalse(a.bytes.reader === b.bytes.reader, "every open file has its own descriptor")
            reader = a.bytes.reader
            XCTAssertNotNil(reader)
            XCTAssertEqual(b.bytes.slice(try XCTUnwrap(b.pictureRange(ofUnit: 2))), fx.frames[2])
        }
        XCTAssertNil(reader, "released with the last user: the descriptor is closed")
        let kept = try XCTUnwrap(MXFFile.cachedParse(of: url))
        XCTAssertNil(kept.bytes.reader); XCTAssertEqual(kept.unitCount, 4)

        var others: [URL] = []
        for i in 0..<(MXFFile.cacheLimit - 1) {
            others.append(try write(data, name: "other\(i)"))
            _ = try MXFFile.open(others[i])
        }
        _ = try MXFFile.open(url)                                   // used again: now the newest
        _ = try MXFFile.open(try write(data, name: "last"))
        XCTAssertNotNil(MXFFile.cachedParse(of: url))
        XCTAssertNil(MXFFile.cachedParse(of: others[0]), "the least recently used parse went")
        XCTAssertNotNil(MXFFile.cachedParse(of: others[1]))
    }

    /// A corrupt element length cannot reach past the next edit unit (no huge allocation and read).
    func testElementPastTheNextUnitIsRejected() async throws {
        var fx = F(); fx.frames = smallFrames(12)
        var data = fx.build()
        let r = try XCTUnwrap(try MXFFile(data: data).pictureRange(ofUnit: 3))
        let length = UInt32(data.count - r.lowerBound)              // the four length bytes before the value
        for i in 0..<4 { data[r.lowerBound - 4 + i] = UInt8(truncatingIfNeeded: length >> UInt32(8 * (3 - i))) }
        let f = try MXFFile(data: data)
        XCTAssertTrue(f.usesIndexTable)
        XCTAssertNil(f.pictureRange(ofUnit: 3)); XCTAssertEqual(f.pictureRange(ofUnit: 4)?.count, fx.frames[4].count)
        let d = try MXFDemuxer(file: f)
        do { _ = try await d.samples(for: 3...3); XCTFail("a frame from a corrupt length") } catch {}
        let after = try await d.samples(for: 4...4).count
        XCTAssertEqual(after, 1)
    }

    /// Clip-wrapped sound with a constant byte count per unit: rejected at the first units, not after the table
    /// of offsets is filled.
    func testConstantByteCountInsideOneElementIsRejected() {
        var d = Data(count: 4_000_000)
        let key: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x16, 0x01, 0x02, 0x01]
        d.replaceSubrange(100..<120, with: key + F.ber(4_000_000 - 120))
        var part = MXFPartition(); part.essenceStart = 100; part.essenceEnd = 4_000_000
        var s = MXFIndexSegment(); s.editUnitByteCount = 6
        XCTAssertNil(MXFFile.unitsFromIndex(MXFBytes(d), parts: [part], segments: [s], tracks: []))
    }

    /// A corrupt edit rate or sample rate throws instead of overflowing.
    func testCorruptRatesDoNotOverflowTheLength() throws {
        var fx = F(); fx.frames = smallFrames(12); fx.audioTracks = 2; fx.samplesPerUnit = [1000, 1920, 7, 1500]
        fx.audioRate = 2_147_483_647; fx.editRate = (1, 2_147_483_647)
        let file = try MXFFile(data: fx.build())
        XCTAssertThrowsError(try MXFAudioSource(file: file, sampleRate: 48_000, left: nil, right: nil, eagerUnits: 8))
        XCTAssertThrowsError(try MXFAudioSource(file: file, sampleRate: .max))
    }

    /// An irregular sample cadence in a long file is not resolved while probing; a read walks only as far as it needs.
    func testIrregularCadenceTableIsBuiltOnFirstRead() throws {
        var fx = F(); fx.frames = smallFrames(12); fx.audioTracks = 4; fx.samplesPerUnit = [1000, 1920, 7, 1500]
        let file = try MXFFile(data: fx.build())
        let eager = try MXFAudioSource(file: file, sampleRate: 48_000)
        XCTAssertEqual(eager.totalFrames, 3 * 4427); XCTAssertEqual(eager.walkedUnits, 0)

        let lazy = try MXFAudioSource(file: file, sampleRate: 48_000, left: nil, right: nil, eagerUnits: 8)
        XCTAssertEqual(lazy.walkedUnits, 0, "opening does not walk the units")
        XCTAssertEqual(lazy.totalFrames, 12 * 1920, "length from the edit rate until the table exists")
        XCTAssertEqual(samples(lazy, channel: 0, from: 10, count: 60), (10..<70).map { expected(0, $0) })
        XCTAssertEqual(lazy.walkedUnits, 1, "a read at the start walks the first unit only")
        XCTAssertEqual(samples(lazy, channel: 3, from: 2900, count: 60), samples(eager, channel: 3, from: 2900, count: 60))
        XCTAssertEqual(lazy.walkedUnits, 4, "units 1 to 3 hold the samples")
        for from in [Int64(0), 2900, 9000, 13_200] {
            XCTAssertEqual(samples(lazy, channel: 2, from: from, count: 60), samples(eager, channel: 2, from: from, count: 60))
        }
        XCTAssertEqual(samples(lazy, channel: 1, from: 4400, count: 60), (4400..<4460).map { expected(1, $0) })
        XCTAssertEqual(lazy.walkedUnits, 12)
        // Past the real end: silence.
        XCTAssertEqual(samples(lazy, channel: 0, from: 20_000, count: 8), [Float](repeating: 0, count: 8))
    }

    // MARK: Annex B

    func testAnnexBConversion() throws {
        let stream: [UInt8] = [0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1E, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80, 0, 0, 0,
                               0, 0, 1, 0x0C, 0xFF, 0xFF, 0x80, 0, 0, 1, 0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0x42]
        try stream.withUnsafeBufferPointer { p in
            XCTAssertTrue(H264AnnexB.hasStartCode(p))
            let ranges = H264AnnexB.nalRanges(p)
            XCTAssertEqual(ranges.map { p[$0.lowerBound] & 0x1F }, [9, 7, 8, 12, 5])
            XCTAssertEqual(Array(p[ranges[2]]), [0x68, 0xEE, 0x3C, 0x80], "trailing zero bytes are not part of the unit")
            XCTAssertEqual(Array(p[ranges[4]]), [0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0x42], "emulation prevention stays")
            XCTAssertEqual(H264AnnexB.nalRanges(p, limit: 2).count, 2)
            let sets = try XCTUnwrap(H264AnnexB.parameterSets(p))
            XCTAssertEqual(sets.sps, [0x67, 0x64, 0x00, 0x1E]); XCTAssertEqual(sets.pps, [0x68, 0xEE, 0x3C, 0x80])
            let out = [UInt8](H264AnnexB.lengthPrefixed(p))
            XCTAssertEqual(out, [0, 0, 0, 4, 0x67, 0x64, 0x00, 0x1E, 0, 0, 0, 4, 0x68, 0xEE, 0x3C, 0x80,
                                 0, 0, 0, 7, 0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0x42])
            // Already length-prefixed input is taken as it is.
            out.withUnsafeBufferPointer { q in
                XCTAssertFalse(H264AnnexB.hasStartCode(q))
                XCTAssertEqual([UInt8](H264AnnexB.lengthPrefixed(q)), out)
            }
        }
        [UInt8]([1, 2, 3]).withUnsafeBufferPointer { XCTAssertTrue(H264AnnexB.nalRanges($0).isEmpty) }
        [UInt8]([0, 0, 0, 0, 0, 0, 0, 1]).withUnsafeBufferPointer { XCTAssertTrue(H264AnnexB.nalRanges($0).isEmpty) }
        [UInt8]([0, 0, 0, 9, 1, 2]).withUnsafeBufferPointer { XCTAssertNil(H264AnnexB.lengthPrefixedRanges($0)) }
        XCTAssertEqual([UInt8]([0x65, 1, 0, 0, 3, 0, 0, 3, 1]).withUnsafeBufferPointer { H264AnnexB.rbsp($0) }, [1, 0, 0, 0, 0, 1])
    }

    func testParameterSetAndSliceParsing() throws {
        var spec = H264TestStream.Spec(); spec.tenBit422 = true; spec.pocType = 0
        let frame = [UInt8](H264TestStream.frame(spec, luma: 500, idr: false, reference: false, frameNum: 3, pocLsb: 22))
        try frame.withUnsafeBufferPointer { p in
            let sets = try XCTUnwrap(H264AnnexB.parameterSets(p))
            let sps = try XCTUnwrap(H264AnnexB.sps(sets.sps))
            XCTAssertEqual(sps.profile, 122); XCTAssertEqual(sps.chromaFormat, 2); XCTAssertEqual(sps.pocType, 0)
            XCTAssertEqual(sps.log2MaxFrameNum, 4); XCTAssertEqual(sps.log2MaxPocLsb, 6); XCTAssertTrue(sps.frameMbsOnly)
            let slice = try XCTUnwrap(H264AnnexB.firstSlice(p, sps: sps))
            XCTAssertEqual(slice, H264AnnexB.Slice(isIDR: false, isReference: false, type: 2, pocLsb: 22))
        }
        XCTAssertNil(H264AnnexB.sps([0x67, 0x64]))
        XCTAssertNil(H264AnnexB.sps([0x68, 1, 2, 3, 4, 5]))
        // Counts wrap around: 60, 62, then 0 and 2 belong to the next cycle.
        typealias S = H264AnnexB.Slice
        let wrapped = [S(isIDR: true, isReference: true, type: 2, pocLsb: 56), S(isReference: true, type: 0, pocLsb: 62),
                       S(type: 1, pocLsb: 58), S(type: 1, pocLsb: 60), S(isReference: true, type: 0, pocLsb: 4), S(type: 1, pocLsb: 0),
                       S(type: 1, pocLsb: 2)]
        XCTAssertEqual(H264AnnexB.displayOrder(wrapped, log2MaxPocLsb: 6), [0, 3, 1, 2, 6, 4, 5])
        XCTAssertNil(H264AnnexB.displayOrder([S(isIDR: true, pocLsb: nil)], log2MaxPocLsb: 6))
    }

    // MARK: audio

    private func samples(_ a: MXFAudioSource, channel c: Int, from: Int64, count: Int) -> [Float] {
        var b = [Float](repeating: -9, count: count)
        let n = b.withUnsafeMutableBufferPointer { a.read(sourceChannel: c, from: from, count: count, into: $0.baseAddress!) }
        return Array(b.prefix(n))
    }
    private func expected(_ c: Int, _ n: Int, bits: Int = 24) -> Float { Float(F.sample(c, n, bits: bits)) / Float(Int64(1) << Int64(bits - 1)) }

    func testMultiMonoAudioTracksAreChannels() throws {
        for (bits, bigEndian) in [(24, false), (24, true), (16, false), (32, true)] {
            var fx = F(); fx.frames = smallFrames(12); fx.audioTracks = 4; fx.audioBits = bits; fx.audioBigEndian = bigEndian
            let a = try MXFAudioSource(file: try MXFFile(data: fx.build()), sampleRate: 48_000)
            XCTAssertEqual(a.channelCount, 4); XCTAssertEqual(a.nativeRate, 48_000); XCTAssertEqual(a.totalFrames, 12 * 1920)
            XCTAssertEqual(a.channels.map(\.bits), [bits, bits, bits, bits]); XCTAssertTrue(a.isMono)
            for c in 0..<4 {
                // Across the boundary between two edit units.
                let got = samples(a, channel: c, from: 1900, count: 100)
                XCTAssertEqual(got, (1900..<2000).map { expected(c, $0, bits: bits) }, "channel \(c), \(bits) bit, big endian \(bigEndian)")
            }
            XCTAssertEqual(samples(a, channel: 3, from: 12 * 1920 - 10, count: 50).count, 10)
            XCTAssertTrue(samples(a, channel: 4, from: 0, count: 10).isEmpty)

            // Default mix: mono channels are centered, channels 1 and 2 on both sides (one microphone on channel 1
            // is not heard left only), each at -3 dB so that dual mono does not come out 6 dB hot.
            var l = [Float](repeating: 0, count: 64), r = l
            XCTAssertEqual(try a.read(from: 5000, count: 64, into: &l, channel: 0), 64)
            XCTAssertEqual(try a.read(from: 5000, count: 64, into: &r, channel: 1), 64)
            let g = Float(0.5).squareRoot()
            for i in 0..<64 {
                XCTAssertEqual(l[i], (expected(0, 5000 + i, bits: bits) + expected(1, 5000 + i, bits: bits)) * g, accuracy: 1e-6)
            }
            XCTAssertEqual(r, l)
            XCTAssertEqual(a.left, [0, 1]); XCTAssertEqual(a.right, [0, 1])
        }
    }

    func testAudioRoutingAndCadence() throws {
        var fx = F(); fx.frames = smallFrames(12); fx.audioTracks = 4; fx.editRate = (30_000, 1001)
        fx.samplesPerUnit = [1602, 1601, 1602, 1601, 1602]
        let file = try MXFFile(data: fx.build())
        let a = try MXFAudioSource(file: file, sampleRate: 48_000, left: [2, 3], right: [1])
        XCTAssertEqual(a.totalFrames, 2 * 8008 + 1602 + 1601)
        var l = [Float](repeating: 0, count: 4000), r = l
        XCTAssertEqual(try a.read(from: 7000, count: 4000, into: &l, channel: 0), 4000)
        XCTAssertEqual(try a.read(from: 7000, count: 4000, into: &r, channel: 1), 4000)
        for i in stride(from: 0, to: 4000, by: 37) {
            XCTAssertEqual(l[i], expected(2, 7000 + i) + expected(3, 7000 + i), accuracy: 1e-6)
            XCTAssertEqual(r[i], expected(1, 7000 + i))
        }
        XCTAssertEqual(samples(a, channel: 0, from: 16_000, count: 3219), (16_000..<19_219).map { expected(0, $0) })
        // One channel on both sides is mono; out of range channels are ignored.
        XCTAssertTrue(try MXFAudioSource(file: file, sampleRate: 48_000, left: [3], right: [3, 9]).isMono)
        // Another output rate: length follows, samples are interpolated.
        let half = try MXFAudioSource(file: file, sampleRate: 24_000)
        XCTAssertEqual(half.totalFrames, (2 * 8008 + 1602 + 1601) / 2)
        XCTAssertEqual(samples(half, channel: 1, from: 100, count: 3), [200, 202, 204].map { expected(1, $0) })
        var all = 0
        try half.streamAll { _, _, n in all += n }
        XCTAssertEqual(Int64(all), half.totalFrames)

        // Irregular unit lengths (fewer than ten units): per-unit table.
        fx.frames = smallFrames(4); fx.samplesPerUnit = [1000, 1920, 7, 1500]
        let odd = try MXFAudioSource(file: try MXFFile(data: fx.build()), sampleRate: 48_000)
        XCTAssertEqual(odd.totalFrames, 4427)
        XCTAssertEqual(samples(odd, channel: 2, from: 2900, count: 60), (2900..<2960).map { expected(2, $0) })
    }

    func testAudioOnlyAndUnsupportedSound() throws {
        var fx = F(); fx.audioTracks = 2; fx.samplesPerUnit = [48_000]
        let f = try MXFFile(data: fx.build())
        XCTAssertNil(f.videoTrack)
        let a = try MXFAudioSource(file: f, sampleRate: 48_000)
        XCTAssertEqual(a.totalFrames, 48_000)
        XCTAssertEqual(samples(a, channel: 0, from: 47_990, count: 10), (47_990..<48_000).map { expected(0, $0) })

        fx.frames = smallFrames(3); fx.samplesPerUnit = [1920]
        fx.audioCompression = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x04, 0x02, 0x02, 0x02, 0x03, 0x02, 0x01, 0x00]
        XCTAssertThrowsError(try MXFAudioSource(file: try MXFFile(data: fx.build()), sampleRate: 48_000)) {
            XCTAssertEqual("\($0)", "\(MediaError.unsupportedCodec("AC-3 audio in MXF"))")
        }
        fx.audioCompression = nil; fx.soundElementType = 0x10
        XCTAssertThrowsError(try MXFAudioSource(file: try MXFFile(data: fx.build()), sampleRate: 48_000)) {
            XCTAssertEqual("\($0)", "\(MediaError.unsupportedCodec("D-10 AES3 audio in MXF"))")
        }
    }

    // MARK: other essence

    func testUnsupportedVideoNamesTheCodec() async throws {
        let cases: [([UInt8], String)] = [([0x71, 0x01, 0x00, 0x00], "DNxHD / DNxHR in MXF"), ([0x01, 0x04, 0x03, 0x00], "MPEG-2 (XDCAM / IMX) in MXF"),
                                          ([0x03, 0x01, 0x01, 0x00], "JPEG 2000 in MXF")]
        for (tail, message) in cases {
            var fx = F(); fx.frames = (0..<3).map { _ in Data(repeating: 0x42, count: 900) }; fx.coding = F.coding(tail); fx.audioTracks = 2
            let data = fx.build()
            XCTAssertThrowsError(try MXFDemuxer(file: try MXFFile(data: data))) {
                XCTAssertEqual("\($0)", "\(MediaError.unsupportedCodec(message))")
            }
            let url = try write(data)
            do { _ = try await MediaImporter.probe(url); XCTFail("probe must fail for \(message)") }
            catch { XCTAssertEqual("\(error)", "\(MediaError.unsupportedCodec(message))") }
        }
        // No label at all and nothing recognizable in the stream.
        var fx = F(); fx.frames = [Data(repeating: 0x42, count: 900)]; fx.coding = nil
        fx.pictureContainer = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x02, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x04, 0x60, 0x01]
        XCTAssertThrowsError(try MXFDemuxer(file: try MXFFile(data: fx.build())))
        // The same container with H.264 inside is found by its parameter sets.
        fx.frames = smallFrames(2)
        XCTAssertEqual(try MXFDemuxer(file: try MXFFile(data: fx.build())).index.count, 2)
    }

    func testProResFormatFromFrameHeader() throws {
        var frame = F.be(2000, 4) + Array("icpf".utf8) + F.be(148, 2) + F.be(0, 2) + Array("sqsq".utf8) + F.be(1920, 2) + F.be(1080, 2) + [0x80]
        frame += [UInt8](repeating: 0, count: 2000 - frame.count)
        var fx = F(); fx.frames = [Data(frame), Data(frame)]; fx.coding = F.coding([0x03, 0x06, 0x03, 0x00])
        fx.pictureContainer = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0D, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x1C, 0x01, 0x00]
        let d = try MXFDemuxer(file: try MXFFile(data: fx.build()))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(d.formatDescription), MXFVideoCodec.code("apcn"))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(d.formatDescription).width, 1920)
        XCTAssertTrue(d.isIntraOnly)
        XCTAssertEqual(try d.payload(ordinal: 1), Data(frame))
    }

    // MARK: malformed input

    private func exercise(_ data: Data) async {
        guard let f = try? MXFFile(data: data) else { return }
        _ = f.videoCodec; _ = f.timecode?.string; _ = f.tracks.count
        if let d = try? MXFDemuxer(file: f), d.index.count > 0 {
            let n = d.index.count
            _ = try? await d.samples(for: 0...min(n - 1, 40))
            _ = try? await d.samples(for: (n - 1)...(n - 1))
        }
        if let a = try? MXFAudioSource(file: f, sampleRate: 48_000) {
            var b = [Float](repeating: 0, count: 4096)
            _ = try? a.read(from: 0, count: 4096, into: &b, channel: 0)
            _ = try? a.read(from: max(0, a.totalFrames - 100), count: 4096, into: &b, channel: 1)
            for c in 0..<min(a.channelCount, 8) { _ = a.read(sourceChannel: c, from: a.totalFrames / 2, count: 4096, into: &b) }
        }
    }

    func testTruncatedFilesNeverCrash() async throws {
        let spec = H264TestStream.Spec(width: 32, height: 32)
        var fx = longGOP(); fx.frames = smallFrames(14, spec: spec); fx.audioTracks = 2; fx.samplesPerUnit = [480]; fx.bodyPartitions = 2
        fx.runIn = 64
        let data = fx.build()
        var n = 0
        while n < data.count { await exercise(data.prefix(n)); n += n < 6000 ? 7 : 211 }
        for cut in 1...64 { await exercise(data.prefix(data.count - cut)) }
        // A file cut after the essence still plays what is there.
        XCTAssertNotNil(try? MXFFile(data: data.prefix(data.count - 400)))
    }

    func testCorruptedAndRandomDataNeverCrash() async throws {
        let spec = H264TestStream.Spec(width: 32, height: 32)
        var rng = LCG(state: 0x5EED)
        for variant in 0..<3 {
            var fx = longGOP(); fx.frames = smallFrames(14, spec: spec); fx.audioTracks = 2; fx.samplesPerUnit = [480]
            if variant == 1 { fx.index = .cbr; fx.temporalOffsets = nil; fx.flags = nil }
            if variant == 2 { fx.hasFooter = false; fx.coding = F.avcLongCoding }
            let good = fx.build()
            let headEnd = min(good.count, 3500)
            for i in 0..<400 {
                var d = good
                d.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: UInt8.self)
                    for _ in 0..<Int.random(in: 1...6, using: &rng) {
                        // Mostly metadata, index and partition packs (head and tail), sometimes essence.
                        let where_ = Int.random(in: 0..<10, using: &rng)
                        let o = where_ < 5 ? Int.random(in: 0..<headEnd, using: &rng)
                            : where_ < 8 ? Int.random(in: max(0, p.count - 900)..<p.count, using: &rng) : Int.random(in: 0..<p.count, using: &rng)
                        p[o] = i % 3 == 0 ? 0xFF : UInt8.random(in: 0...255, using: &rng)
                    }
                }
                await exercise(d)
            }
        }
        for size in [16, 64, 65, 200, 5000, 70_000] {
            for prefix in [[], F.partitionKey(0x02), F.partitionKey(0x02) + [0x83, 0x00, 0x00, 0x68]] {
                var bytes = prefix + (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
                await exercise(Data(bytes))
                bytes += F.partitionKey(0x04) + [0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
                await exercise(Data(bytes))
            }
        }
        // Every KLV of a good file with an absurd length, one at a time.
        var fx = F(); fx.frames = smallFrames(3, spec: spec); fx.audioTracks = 1; fx.samplesPerUnit = [480]
        let good = fx.build()
        let r = MXFBytes(good)
        var p = 0
        while let k = r.klv(at: p), k.end > p, k.end <= r.count {
            for length: [UInt8] in [[0x88, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], [0x80], [0x00], [0x84, 0x7F, 0xFF, 0xFF, 0xFF]] {
                var d = good
                d.replaceSubrange((p + 16)..<min(d.count, p + 16 + length.count), with: length)
                await exercise(d)
            }
            p = k.end
        }
        XCTAssertGreaterThan(p, good.count - 200, "walked the whole file")
    }

    // MARK: field order

    func testFieldOrderFromThePictureDescriptor() throws {
        func order(layout: UInt8, dominance: UInt8? = nil, map: (Int, Int)? = nil) throws -> FieldOrder? {
            var fx = F(); fx.frames = smallFrames(2)
            fx.frameLayout = layout; fx.fieldDominance = dominance; fx.videoLineMap = map
            return try XCTUnwrap(MXFFile(data: fx.build()).videoTrack?.picture).fieldOrder
        }
        // Progressive: full frame, and a segmented frame (PsF) whatever its line map says.
        XCTAssertNil(try order(layout: 0)); XCTAssertNil(try order(layout: 0, dominance: 1, map: (21, 584)))
        XCTAssertNil(try order(layout: 4, map: (21, 584))); XCTAssertNil(try order(layout: 4, dominance: 2, map: (21, 584)))
        XCTAssertNil(try order(layout: 2, map: (21, 584)), "a single field has no second one")
        // 1080i (XAVC 50i / 59.94i): separate fields, lines 21 and 584, field 1 on top and first.
        XCTAssertEqual(try order(layout: 1, map: (21, 584)), .topFirst)
        XCTAssertEqual(try order(layout: 1, dominance: 1, map: (21, 584)), .topFirst)
        XCTAssertEqual(try order(layout: 1, dominance: 2, map: (21, 584)), .bottomFirst)
        XCTAssertEqual(try order(layout: 3, map: (23, 336)), .topFirst, "625 lines, mixed fields")
        // 525-line DV style map: both start lines odd, field 1 is the lower field.
        XCTAssertEqual(try order(layout: 1, map: (23, 285)), .bottomFirst)
        XCTAssertEqual(try order(layout: 1, dominance: 2, map: (23, 285)), .topFirst)
        // No line map: field 1 is the top field.
        XCTAssertEqual(try order(layout: 1), .topFirst); XCTAssertEqual(try order(layout: 1, dominance: 2), .bottomFirst)
    }

    func testProbeCarriesTheFieldOrder() async throws {
        let spec = H264TestStream.Spec()
        var fx = F(); fx.frames = smallFrames(4, spec: spec); fx.width = 64; fx.height = 48; fx.depth = 8; fx.vSub = 2
        for (layout, expected) in [(UInt8(1), FieldOrder?.some(.topFirst)), (4, nil), (0, nil)] {
            fx.frameLayout = layout; fx.videoLineMap = (21, 584)
            let url = try write(fx.build(), name: "field\(layout)")
            let (_, info) = try await MediaImporter.probe(url)
            XCTAssertEqual(info.video?.fieldOrder, expected, "frame layout \(layout)")
        }
    }

    func testFieldOrderOfAFormatDescription() {
        let count = kCMFormatDescriptionExtension_FieldCount as String, detail = kCMFormatDescriptionExtension_FieldDetail as String
        XCTAssertNil(MediaImporter.fieldOrder(extensions: [:]))
        XCTAssertNil(MediaImporter.fieldOrder(extensions: [count: 1]))
        XCTAssertEqual(MediaImporter.fieldOrder(extensions: [count: 2, detail: kCMFormatDescriptionFieldDetail_TemporalTopFirst as String]), .topFirst)
        XCTAssertEqual(MediaImporter.fieldOrder(extensions: [count: 2, detail: kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly as String]), .topFirst)
        XCTAssertEqual(MediaImporter.fieldOrder(extensions: [count: 2, detail: kCMFormatDescriptionFieldDetail_TemporalBottomFirst as String]), .bottomFirst)
        XCTAssertEqual(MediaImporter.fieldOrder(extensions: [count: 2, detail: kCMFormatDescriptionFieldDetail_SpatialFirstLineLate as String]), .bottomFirst)
        XCTAssertEqual(MediaImporter.fieldOrder(extensions: [count: 2]), .topFirst)
    }

    // MARK: import and decode

    func testProbeThumbnailAndWaveform() async throws {
        let spec = H264TestStream.Spec()
        var fx = F(); fx.frames = smallFrames(25, spec: spec); fx.audioTracks = 4; fx.width = 64; fx.height = 48; fx.depth = 8; fx.vSub = 2
        let url = try write(fx.build(), name: "C0001")
        let (ref, info) = try await MediaImporter.probe(url)
        XCTAssertEqual(ref.path, url.path)
        XCTAssertEqual(info.duration, Time(1, 1))
        let v = try XCTUnwrap(info.video)
        XCTAssertEqual(v.width, 64); XCTAssertEqual(v.height, 48); XCTAssertEqual(v.codec, "avc1")
        XCTAssertEqual(v.nominalFrameDuration, Time(1, 25)); XCTAssertFalse(v.isVariableFrameRate)
        XCTAssertEqual(v.bitDepth, 8); XCTAssertEqual(v.chroma, "4:2:0")
        XCTAssertEqual(info.audio?.channels, 4, "every mono track is a channel of the source")
        XCTAssertEqual(info.audio?.sampleRate, 48_000)

        let image = try await MXFStill.cgImage(url: url, time: CMTime(value: 10, timescale: 25), height: 48, exact: true)
        XCTAssertEqual(image.height, 48)
        let wave = try await WaveformBuilder.build(url: url, cache: nil)
        // The default mix is centered (mono), so the waveform has one row.
        XCTAssertEqual(wave.totalFrames, 48_000); XCTAssertEqual(wave.sampleRate, 48_000); XCTAssertEqual(wave.channelCount, 1)
    }

    func testDecodeGeneratedIntraFrames() async throws {
        var fx = F(); fx.frames = smallFrames(10); fx.width = 64; fx.height = 48; fx.depth = 8; fx.vSub = 2
        let demuxer = try MXFDemuxer(file: try MXFFile(data: fx.build()))
        let decoder = try VTVideoDecoder(demuxer: demuxer, media: UUID())
        defer { decoder.invalidate() }
        let frames = try await decoder.decode(0...9)
        XCTAssertEqual(frames.map(\.pts), (0..<10).map { Time(Int64($0), 25) })
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(CVPixelBufferGetWidth(f.pixelBuffer), 64); XCTAssertEqual(CVPixelBufferGetHeight(f.pixelBuffer), 48)
            if let luma = centerLuma(f.pixelBuffer), luma.bits == 8 { XCTAssertEqual(luma.value, 40 + 20 * (i % 8), accuracy: 2, "frame \(i)") }
        }
        // Seek straight to a frame in the middle.
        let seek = try await decoder.decode(6...6)
        XCTAssertEqual(seek.map(\.pts), [Time(6, 25)])
        if let luma = seek.first.flatMap({ centerLuma($0.pixelBuffer) }), luma.bits == 8 { XCTAssertEqual(luma.value, 160, accuracy: 2) }
    }

    /// What this Mac does with H.264 High 4:2:2 Intra, 10 bit (the profile of XAVC-I). The result is written to a file
    /// for the engine notes; the test fails only when a decoded picture is wrong.
    func testMeasureHigh422IntraTenBitDecode() async throws {
        for (width, height, level) in [(1920, 1088, UInt8(41)), (3840, 2160, UInt8(51))] {
            let spec = H264TestStream.Spec(width: width, height: height, tenBit422: true, pocType: 2, level: level)
            var fx = F(); fx.frames = (0..<3).map { H264TestStream.frame(spec, luma: 400 + 40 * $0, chroma: 500, idrID: $0 & 1) }
            fx.width = width; fx.height = height
            let label = "H.264 High 4:2:2 Intra 10 bit \(width)x\(height) (raw PCM macroblocks)"
            do {
                let demuxer = try MXFDemuxer(file: try MXFFile(data: fx.build()))
                let info = try MediaImporter.videoInfo(format: demuxer.formatDescription, index: demuxer.index, rotation: 0)
                XCTAssertEqual(info.bitDepth, 10); XCTAssertEqual(info.chroma, "4:2:2")
                let decoder = try VTVideoDecoder(demuxer: demuxer, media: UUID())
                defer { decoder.invalidate() }
                let start = Date()
                let frames = try await decoder.decode(0...2)
                let ms = Date().timeIntervalSince(start) * 1000 / 3
                XCTAssertEqual(frames.count, 3)
                var lumas: [String] = []
                for (i, f) in frames.enumerated() {
                    guard let luma = centerLuma(f.pixelBuffer) else { lumas.append("?"); continue }
                    lumas.append("\(luma.value)/\(luma.bits)bit")
                    if luma.bits == 10 { XCTAssertEqual(luma.value, 400 + 40 * i, accuracy: 4) }
                }
                let type = frames.first.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) } ?? 0
                let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: type >> UInt32($0)) }, encoding: .ascii) ?? "?"
                record("\(label): decoded, hardware=\(decoder.isHardware), output=\(fourCC), luma=\(lumas), \(String(format: "%.1f", ms)) ms/frame")
            } catch {
                record("\(label): NOT decoded (\(error))")
            }
        }
    }

    /// Local only: the first group of pictures of a Sony XAVC (long GOP, 4:2:2 10 bit) clip, rewrapped as MXF.
    func testRewrappedSonyLongGOPDecodes() async throws {
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../TestMedia").standardized
        let imports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Sequence Studio Imports/Untitled")
        let candidates = ["C2157.MP4", "C2158.MP4"].map { local.appendingPathComponent($0) }
            + ["C2164.MP4", "C2165.MP4", "C2166.MP4"].map { imports.appendingPathComponent($0) }
        let found = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        let url = try XCTUnwrap(found ?? { try XCTSkipIf(true, "no local Sony XAVC clip"); return nil }())
        let source = try await AVDemuxer(url: url)
        let entries = source.index.entries
        var byOrdinal = [Int](repeating: 0, count: entries.count)
        for (i, e) in entries.enumerated() { byOrdinal[e.decodeOrdinal] = i }
        var n = entries.count
        for o in 1..<entries.count where entries[byOrdinal[o]].isSync { n = o; break }
        let ranks = (0..<n).map { byOrdinal[$0] }
        try XCTSkipUnless(n >= 2 && n <= 120 && Set(ranks) == Set(0..<n), "first group of pictures is not self-contained")

        var count = 0, lengthSize: Int32 = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(source.formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        var sets: [UInt8] = []
        for i in 0..<count {
            var p: UnsafePointer<UInt8>?, size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(source.formatDescription, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let p { sets += [0, 0, 0, 1] + Array(UnsafeBufferPointer(start: p, count: size)) }
        }
        let buffers = try await source.samples(for: 0...(n - 1))
        try XCTSkipUnless(buffers.count >= n && lengthSize == 4, "unexpected sample layout")
        var fx = F(); fx.coding = F.avcLongCoding
        for (o, sb) in buffers.prefix(n).enumerated() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sb))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            var out = o == 0 ? sets : []
            var i = 0
            while i + 4 <= bytes.count {
                let len = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                guard len > 0, i + 4 + len <= bytes.count else { break }
                out += [0, 0, 0, 1] + bytes[(i + 4)..<(i + 4 + len)]
                i += 4 + len
            }
            fx.frames.append(Data(out))
        }
        var storedOf = [Int](repeating: 0, count: n)
        for (stored, rank) in ranks.enumerated() { storedOf[rank] = stored }
        fx.temporalOffsets = (0..<n).map { Int8(clamping: storedOf[$0] - $0) }
        fx.flags = (0..<n).map { $0 == 0 ? 0xC0 : 0x22 }
        let unit = entries[0].duration
        fx.editRate = (Int(unit.timescale), Int(unit.value))
        let dims = CMVideoFormatDescriptionGetDimensions(source.formatDescription)
        fx.width = Int(dims.width); fx.height = Int(dims.height)

        let demuxer = try MXFDemuxer(file: try MXFFile(data: fx.build()))
        XCTAssertEqual(demuxer.index.entries.map(\.decodeOrdinal), storedOf)
        XCTAssertEqual(demuxer.index.entries.filter(\.isSync).count, 1)
        let info = try MediaImporter.videoInfo(format: demuxer.formatDescription, index: demuxer.index, rotation: 0)
        let decoder = try VTVideoDecoder(demuxer: demuxer, media: UUID())
        defer { decoder.invalidate() }
        let start = Date()
        let frames = try await decoder.decode(0...(n - 1))
        let ms = Date().timeIntervalSince(start) * 1000 / Double(n)
        XCTAssertEqual(frames.count, n)
        XCTAssertEqual(frames.map(\.pts), frames.map(\.pts).sorted())
        let reference = try VTVideoDecoder(demuxer: source, media: UUID())
        defer { reference.invalidate() }
        let wanted = try await reference.decode(0...(n - 1))
        XCTAssertEqual(frames.compactMap { centerLuma($0.pixelBuffer)?.value }, wanted.compactMap { centerLuma($0.pixelBuffer)?.value })
        record("Sony XAVC long GOP \(info.width)x\(info.height) \(info.chroma) \(info.bitDepth) bit rewrapped as MXF: \(n) frames decoded, "
               + "hardware=\(decoder.isHardware), \(String(format: "%.1f", ms)) ms/frame")
        // A seek to the last frame of the group decodes from its key frame.
        let again = try VTVideoDecoder(demuxer: demuxer, media: UUID())
        defer { again.invalidate() }
        let last = try await again.decode((n - 1)...(n - 1)).map(\.pts)
        XCTAssertEqual(last, [demuxer.index.entries[n - 1].pts])
    }
}
