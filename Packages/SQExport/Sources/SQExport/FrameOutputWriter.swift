import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQCore
import UniformTypeIdentifiers
import VideoToolbox

/// Writes an animated GIF or a numbered image sequence from a frame source. The source already follows the export range
/// (`ExportSettings.range`), so every frame of it is written.
public enum FrameOutputWriter {
    /// `url` is the GIF file, or the folder of the sequence (created here; its name is the file name stem).
    public static func write(video: any FrameSource, output: FrameOutput, settings: ExportSettings, to url: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        switch output {
        case .gif:
            try await writeGIF(video: video, frameDuration: settings.video.frameDuration, to: url, progress: progress)
        case .sequence(let format):
            try await writeSequence(video: video, format: format, into: url, progress: progress)
        }
    }

    /// Returns the files written, in order.
    @discardableResult
    static func writeSequence(video: any FrameSource, format: FrameStillFormat, into folder: URL, startNumber: Int = 0,
                              progress: @Sendable (Double) -> Void) async throws -> [URL] {
        guard format.isSupported else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = video.frameCount
        let names = ImageSequenceNaming.fileNames(stem: folder.lastPathComponent, startNumber: startNumber, count: total,
                                                  ext: format.fileExtension)
        var urls: [URL] = []
        for i in 0..<total {
            try Task.checkCancellation()
            let pb = try await video.frame(at: i)
            let file = folder.appendingPathComponent(names[i])
            try write(pixelBuffer: pb, format: format, to: file)
            urls.append(file)
            progress(Double(i + 1) / Double(total))
        }
        return urls
    }

    /// One `.rgbaHalf` frame (premultiplied linear) through `FrameStillWriter`.
    static func write(pixelBuffer pb: CVPixelBuffer, format: FrameStillFormat, to url: URL) throws {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf else { throw CocoaError(.fileWriteUnknown) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw CocoaError(.fileWriteUnknown) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { throw CocoaError(.fileWriteUnknown) }
        var pixels = [Float16](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { dst in
            guard let out = dst.baseAddress else { return }
            for y in 0..<h { memcpy(out + y * w * 8, base + y * stride, w * 8) }
        }
        try pixels.withUnsafeBufferPointer { try FrameStillWriter.write(pixels: $0, width: w, height: h, format: format, to: url) }
    }

    /// Looping GIF. Every frame is quantized on its own by ImageIO (a local color table per frame, no global one), so a
    /// scene change does not inherit the palette of the shot before it.
    static func writeGIF(video: any FrameSource, frameDuration: Time, to url: URL,
                         progress: @Sendable (Double) -> Void) async throws {
        let total = video.frameCount
        let delays = GIFTiming.delaysCentiseconds(frameDuration: frameDuration, frameCount: total)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, total, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false,
        ]] as CFDictionary)
        for i in 0..<total {
            try Task.checkCancellation()
            let pb = try await video.frame(at: i)
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &image)
            guard let image else { throw CocoaError(.fileWriteUnknown) }
            let seconds = Double(delays[i]) / 100
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: seconds, kCGImagePropertyGIFUnclampedDelayTime: seconds,
            ]] as CFDictionary)
            progress(Double(i + 1) / Double(total) * 0.95)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Audio-only FLAC through AVAudioFile (AVAssetWriter has no FLAC file type). Written at the mix's own sample rate.
enum FLACWriter {
    static func write(_ source: any AudioSource, duration: Time, bitDepth: Int, to url: URL,
                      progress: @Sendable (Double) -> Void) async throws {
        let channels = AVAudioChannelCount(min(max(source.channels, 1), 8))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: Double(source.sampleRate), AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: bitDepth >= 24 ? 24 : 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = max(1, Int(Int128(duration.value) * Int128(source.sampleRate) / Int128(max(duration.timescale, 1))))
        var written = 0
        while let chunk = try await source.nextChunk(maxFrames: 4096) {
            try Task.checkCancellation()
            let n = chunk.frameCount
            guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                  let planes = buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(n)
            let c = chunk.channels
            for ch in 0..<Int(channels) {
                let src = min(ch, c - 1)
                for i in 0..<n { planes[ch][i] = chunk.samples[i * c + src] }
            }
            try file.write(from: buffer)
            written += n
            progress(min(1, Double(written) / Double(totalFrames)))
        }
    }
}
