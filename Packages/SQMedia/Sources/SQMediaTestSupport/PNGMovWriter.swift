import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a QuickTime movie whose samples are PNG pictures (`png ` codec, the "transparent animation" export of After Effects,
/// Blender ...) by passthrough, every frame the `AlphaTestPattern` (opaque / half / transparent columns, straight color).
/// VideoToolbox and AVAssetReader cannot decode this codec.
public enum PNGMovWriter {
    public static func write(width: Int, height: Int, frames: Int, fps: Int32 = 25) async throws -> URL {
        guard let pb = AlphaTestPattern.makePixelBuffer(width: width, height: height, premultiplied: true) else {
            throw TestClipError.writerFailed("pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // CGContext only takes premultiplied BGRA; the PNG encoder writes the straight color.
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let image = ctx.makeImage()!
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let bytes = png as Data

        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMVideoCodecType(0x706E_6720), width: Int32(width), height: Int32(height),
                                       extensions: [kCMFormatDescriptionExtension_Depth: 32] as CFDictionary, formatDescriptionOut: &fd)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SQPNGMov-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
        writer.add(input)
        guard writer.startWriting() else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
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
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let sb, input.append(sb) else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "append") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        return url
    }
}
