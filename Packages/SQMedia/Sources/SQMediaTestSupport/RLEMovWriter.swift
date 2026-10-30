import AVFoundation
import CoreMedia
import Foundation

/// Writes a QuickTime Animation ('rle ') movie by passthrough with a minimal RLE encoder: the first frame is a key frame,
/// later frames are delta frames (partial line range, skip codes over unchanged pixels, run and literal codes), so the
/// decoder is tested against real delta handling. Frames are straight RGBA, `width * height * 4` bytes each.
public enum RLEMovWriter {
    public static func write(frames: [[UInt8]], width: Int, height: Int, depth: Int = 32, fps: Int32 = 25,
                             keyEvery: Int = Int.max) async throws -> URL {
        var chunks: [Data] = []
        var prev: [UInt8]?
        for (i, f) in frames.enumerated() {
            let key = i % keyEvery == 0
            chunks.append(encode(f, prev: key ? nil : prev, width: width, height: height, depth: depth))
            prev = f
        }
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMVideoCodecType(0x726C_6520), width: Int32(width), height: Int32(height),
                                       extensions: [kCMFormatDescriptionExtension_Depth: depth] as CFDictionary, formatDescriptionOut: &fd)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SQRLEMov-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
        writer.add(input)
        guard writer.startWriting() else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        for (i, bytes) in chunks.enumerated() {
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
            bytes.withUnsafeBytes {
                _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: fps), decodeTimeStamp: .invalid)
            var size = bytes.count
            var sb: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                 formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
            if i % keyEvery != 0, let sb, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
                arr.first?[kCMSampleAttachmentKey_NotSync] = true
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let sb, input.append(sb) else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "append") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        return url
    }

    /// One chunk. `prev == nil` writes every line (key frame).
    static func encode(_ frame: [UInt8], prev: [UInt8]?, width: Int, height: Int, depth: Int) -> Data {
        let bpp = depth == 32 ? 4 : depth == 24 ? 3 : 2
        func px(_ f: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * width + x) * 4
            let (r, g, b, a) = (f[o], f[o + 1], f[o + 2], f[o + 3])
            switch bpp {
            case 4: return [a, r, g, b]
            case 3: return [r, g, b]
            default:
                let v = (Int(r >> 3) << 10) | (Int(g >> 3) << 5) | Int(b >> 3)
                return [UInt8(v >> 8), UInt8(v & 255)]
            }
        }
        var firstRow = 0, lastRow = height - 1
        if let prev {
            let changed = (0..<height).filter { y in (0..<width).contains { px(frame, $0, y) != px(prev, $0, y) } }
            firstRow = changed.first ?? 0; lastRow = changed.last ?? 0
        }
        var body = Data()
        for y in firstRow...lastRow {
            var f = 0, l = width - 1
            if let prev {
                let diff = (0..<width).filter { px(frame, $0, y) != px(prev, $0, y) }
                guard let a = diff.first, let b = diff.last else { body += [1, 0xFF]; continue }
                f = a; l = b
            }
            var skip = f + 1
            body.append(UInt8(min(skip, 255))); skip -= min(skip, 255)
            while skip > 0 { let s = min(skip + 1, 255); body += [0, UInt8(s)]; skip -= s - 1 }
            var x = f
            while x <= l {
                var run = 1
                while x + run <= l, run < 127, px(frame, x + run, y) == px(frame, x, y) { run += 1 }
                if run >= 3 {
                    body.append(UInt8(bitPattern: Int8(-run))); body += px(frame, x, y); x += run
                } else {
                    var n = 0
                    // Literal: until a run of 3 starts or 127 pixels.
                    while x + n <= l, n < 127 {
                        if x + n + 2 <= l, px(frame, x + n, y) == px(frame, x + n + 1, y), px(frame, x + n, y) == px(frame, x + n + 2, y) { break }
                        n += 1
                    }
                    n = max(n, 1)
                    body.append(UInt8(n))
                    for k in 0..<n { body += px(frame, x + k, y) }
                    x += n
                }
            }
            body.append(0xFF)
        }
        var head = Data()
        let partial = prev != nil
        let total = 4 + 2 + (partial ? 8 : 0) + body.count
        head += [UInt8(total >> 24 & 255), UInt8(total >> 16 & 255), UInt8(total >> 8 & 255), UInt8(total & 255)]
        head += partial ? [0, 8] : [0, 0]
        if partial {
            let n = lastRow - firstRow + 1
            head += [UInt8(firstRow >> 8), UInt8(firstRow & 255), 0, 0, UInt8(n >> 8), UInt8(n & 255), 0, 0]
        }
        return head + body
    }
}
