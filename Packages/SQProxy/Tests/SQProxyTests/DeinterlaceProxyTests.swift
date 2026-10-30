@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQProxy

// A proxy of an interlaced file is deinterlaced once, while it is written: at the stored size, before the writer scales
// the picture. The proxy file itself is progressive (no field tags), so nothing deinterlaces its frames again.
//
// The source is uncompressed 4:2:2 whose sample description says two fields, top field first (the ProRes encoder takes
// no field count, and a ProRes file reports the field count of its frame headers): a bright box on a dark ground
// that sits at x 40..<80 in the top field and at x 64..<104 in the bottom field. The strip x 84..<100 is bright only in
// the later field: woven it shows every other row bright, scaled down it turns gray, deinterlaced it is dark.
@Suite(.serialized) struct DeinterlaceProxyTests {
    static let width = 320, height = 192

    static func picture() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_422YpCbCr8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            let box = y & 1 == 0 ? 40 : 64
            for x in 0..<width {
                row[2 * x] = 128   // Cb / Cr
                row[2 * x + 1] = (40..<152).contains(y) && (box..<box + 40).contains(x) ? 220 : 40
            }
        }
        return buffer
    }

    /// Six frames of `picture` as uncompressed 4:2:2 ('2vuy'), with or without the field tags of the sample description.
    static func write(interlaced: Bool) async throws -> URL {
        var ext: [String: Any] = [:]
        if interlaced {
            ext[kCMFormatDescriptionExtension_FieldCount as String] = 2
            ext[kCMFormatDescriptionExtension_FieldDetail as String] = kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
        }
        var made: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_422YpCbCr8, width: Int32(width), height: Int32(height),
                                       extensions: ext as CFDictionary, formatDescriptionOut: &made)
        let format = try #require(made)
        let frame = picture()
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        var bytes = Data(capacity: width * 2 * height)
        for y in 0..<height {
            bytes.append(Data(bytes: CVPixelBufferGetBaseAddress(frame)! + y * CVPixelBufferGetBytesPerRow(frame), count: width * 2))
        }
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        var all: [CMSampleBuffer] = []
        for i in 0..<6 {
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
            let data = try #require(block)
            try #require(bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count) } == noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 25), decodeTimeStamp: .invalid)
            var size = bytes.count
            var sb: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: data, formatDescription: format, sampleCount: 1,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                      sampleSizeArray: &size, sampleBufferOut: &sb)
            all.append(try #require(sb))
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-fields-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(all[0]))
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for sb in all {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            try #require(input.append(sb))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    struct Read { var fieldCount: Int?; var strip: (low: Int, high: Int); var box: Int }

    /// The file's field tag, and from its first frame: the luma range of the strip only the later field lights, and the
    /// luma in the middle of the earlier field's box.
    static func read(_ url: URL) async throws -> Read {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(out)
        try #require(reader.startReading())
        let sb = try #require(out.copyNextSampleBuffer())
        let pb = try #require(CMSampleBufferGetImageBuffer(sb))
        reader.cancelReading()
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        func luma(_ x: Int, _ y: Int) -> Int { Int((base + y * stride).assumingMemoryBound(to: UInt8.self)[x]) }
        var low = 255, high = 0
        for y in (h * 60 / height)..<(h * 132 / height) {
            for x in (w * 86 / width)..<(w * 98 / width) { low = min(low, luma(x, y)); high = max(high, luma(x, y)) }
        }
        return Read(fieldCount: (ext[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber)?.intValue,
                    strip: (low, high), box: luma(w * 52 / width, h * 96 / height))
    }

    @Test(arguments: [ProxyKind.optimized, .proxyHalf])
    func interlacedSourceGetsAProgressiveProxy(kind: ProxyKind) async throws {
        let src = try await Self.write(interlaced: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.mov")
        _ = try await ProxyTranscoder().transcode(source: src, kind: kind, destination: out, timeRange: nil) { _ in }
        let o = try await Self.read(src), p = try await Self.read(out)
        #expect(o.fieldCount == 2, "the test file is tagged interlaced")
        #expect(o.strip.high > 180 && o.strip.low < 80, "and woven: \(o.strip)")
        #expect(p.strip.high < 80, "\(kind): the later field is gone from the proxy: \(p.strip)")
        #expect(p.box > 180, "the earlier field is kept: \(p.box)")
        #expect(p.fieldCount != 2, "the proxy is progressive: nothing deinterlaces it again")
    }

    static func sample(_ format: OSType) throws -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, format, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &pb)
        let picture = try #require(pb)
        var made: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: picture, formatDescriptionOut: &made)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25), presentationTimeStamp: CMTime(value: 3, timescale: 25),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: picture, formatDescription: try #require(made),
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return try #require(sb)
    }

    /// A proxy of an interlaced source is tagged progressive, so a picture the pass cannot read is never written into
    /// it (it used to go in woven): the pump gets nothing to write and fails the job.
    @Test func aPictureThatCannotBeDeinterlacedIsNotWritten() throws {
        let unknown = try Self.sample(kCVPixelFormatType_32BGRA)
        #expect(ProxyFields.writable(unknown, fieldOrder: .topFirst) == nil)
        #expect(ProxyFields.writable(unknown, fieldOrder: nil) === unknown, "a progressive source is copied as it is")
        for format in [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_4444AYpCbCr16] {
            let known = try Self.sample(format)
            let out = try #require(ProxyFields.writable(known, fieldOrder: .bottomFirst), "format \(format)")
            #expect(CMSampleBufferGetImageBuffer(out) !== CMSampleBufferGetImageBuffer(known))
            #expect(CMSampleBufferGetPresentationTimeStamp(out) == CMTime(value: 3, timescale: 25))
        }
    }

    /// The same picture without field tags is progressive as far as anyone can tell: copied as it is, no pass.
    @Test func untaggedSourceIsLeftAlone() async throws {
        let src = try await Self.write(interlaced: false)
        defer { try? FileManager.default.removeItem(at: src) }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.mov")
        _ = try await ProxyTranscoder().transcode(source: src, kind: .optimized, destination: out, timeRange: nil) { _ in }
        let o = try await Self.read(src), p = try await Self.read(out)
        #expect(o.fieldCount != 2)
        #expect(p.strip.high > 180 && p.strip.low < 80, "the rows are untouched: \(p.strip)")
    }
}
