import AVFoundation
import AppKit
import CoreGraphics

/// Real (tiny) media files for the render harness' "online" states: the demo project's footage as 270x480 H.264 clips
/// (sunset scene like the design boards, one hue per clip, the sun drifting) with a speech-like AAC track, plus an audio
/// bed. Written once into a temp folder; never part of the shipped UI. Without them every clip is offline (red).
enum RenderDemoMedia {
    static let size = (w: 270, h: 480)

    /// File name per demo media name; all go into `dir`.
    static func fileName(for name: String) -> String { name.hasSuffix(".mp3") ? "Late Sun.m4a" : name }

    /// Writes the five footage clips and the music bed. `frames` per clip name. Returns when all files are complete.
    static func write(into dir: URL, footage: [(name: String, frames: Int)], music: (seconds: Int, name: String)) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, f) in footage.enumerated() {
            let url = dir.appendingPathComponent(f.name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try await writeVideo(url, frames: f.frames, hue: [0.0, 0.07, 0.62, 0.9, 0.12][i % 5], seed: UInt64(i + 1))
        }
        let m = dir.appendingPathComponent(fileName(for: music.name))
        if !FileManager.default.fileExists(atPath: m.path) { try await writeAudio(m, seconds: music.seconds) }
    }

    // MARK: Picture

    private static func color(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
        NSColor(calibratedHue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor
    }

    /// Sunset: sky gradient, sun, two mountain ridges, a person's head and shoulders (the board's thumbnail scene).
    private static func draw(_ ctx: CGContext, hue: Double, phase: Double) {
        let w = CGFloat(size.w), h = CGFloat(size.h)
        let space = CGColorSpaceCreateDeviceRGB()
        let sky = CGGradient(colorsSpace: space, colors: [color(hue + 0.72, 0.55, 0.30), color(hue + 0.90, 0.50, 0.75), color(hue + 0.02, 0.45, 0.98)] as CFArray,
                             locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.25), options: [.drawsAfterEndLocation])
        ctx.setFillColor(color(hue + 0.12, 0.25, 1))
        ctx.fillEllipse(in: CGRect(x: w * (0.55 + 0.1 * phase), y: h * 0.52, width: 34, height: 34))
        ctx.setFillColor(color(hue + 0.80, 0.50, 0.40))
        ctx.move(to: CGPoint(x: 0, y: h * 0.25)); ctx.addLine(to: CGPoint(x: w * 0.30, y: h * 0.52)); ctx.addLine(to: CGPoint(x: w * 0.55, y: h * 0.33))
        ctx.addLine(to: CGPoint(x: w * 0.80, y: h * 0.50)); ctx.addLine(to: CGPoint(x: w, y: h * 0.28)); ctx.addLine(to: CGPoint(x: w, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: 0))
        ctx.fillPath()
        ctx.setFillColor(color(hue + 0.74, 0.55, 0.22))
        ctx.fillEllipse(in: CGRect(x: w * 0.5 - 52, y: h * 0.12 - 40, width: 104, height: 130))     // shoulders
        ctx.setFillColor(color(hue + 0.04, 0.35, 0.80))
        ctx.fillEllipse(in: CGRect(x: w * 0.5 - 26, y: h * 0.20, width: 52, height: 62))            // head
        ctx.setFillColor(color(hue + 0.72, 0.5, 0.12))
        ctx.fillEllipse(in: CGRect(x: w * 0.5 - 30, y: h * 0.20 + 34, width: 60, height: 36))       // hair
    }

    private static func pixelBuffer(hue: Double, phase: Double) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard CVPixelBufferCreate(nil, size.w, size.h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: size.w, height: size.h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(ctx, hue: hue, phase: phase)
        return pb
    }

    // MARK: Audio

    private static func audioBuffer(frameStart: Int, count: Int, seed: UInt64) -> CMSampleBuffer? {
        var samples = [Float](repeating: 0, count: count * 2)
        var rng = seed &+ UInt64(frameStart)
        for i in 0..<count {
            let t = Double(frameStart + i) / 48_000
            let env = Float(max(0, sin(t * 7.1) * sin(t * 2.3 + Double(seed)))) * 0.5 + 0.05      // words and pauses
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: rng >> 11) % 2000) / 1000 - 1
            let v = env * (0.6 * noise + 0.4 * Float(sin(t * 2 * .pi * 180)))
            samples[i * 2] = v; samples[i * 2 + 1] = v
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                               mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var block: CMBlockBuffer?
        let bytes = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: count,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(frameStart), timescale: 48_000),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    private static var aac: [String: Any] { [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000] }

    private static func writeAudio(_ url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var pos = 0
        let total = seconds * 48_000
        while pos < total {
            if input.isReadyForMoreMediaData, let sb = audioBuffer(frameStart: pos, count: 4800, seed: 9) { input.append(sb); pos += 4800 }
            else { try await Task.sleep(for: .milliseconds(1)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func writeVideo(_ url: URL, frames: Int, hue: Double, seed: UInt64) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.w, AVVideoHeightKey: size.h,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 15, AVVideoAverageBitRateKey: 600_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.w, kCVPixelBufferHeightKey as String: size.h])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        writer.add(vIn); writer.add(aIn)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var next = 0, audioPos = 0
        let audioTotal = frames * 48_000 / 30
        var buffer: CVPixelBuffer?
        while next < frames || audioPos < audioTotal {
            var progressed = false
            if next < frames, vIn.isReadyForMoreMediaData {
                if next % 10 == 0 || buffer == nil { buffer = pixelBuffer(hue: hue, phase: Double(next) / Double(max(frames, 1))) }
                if let b = buffer, adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: 30)) { next += 1; progressed = true }
                else if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            if audioPos < audioTotal, aIn.isReadyForMoreMediaData {
                let n = min(4800, audioTotal - audioPos)
                if let sb = audioBuffer(frameStart: audioPos, count: n, seed: seed) { aIn.append(sb) }
                audioPos += n; progressed = true
                if audioPos >= audioTotal { aIn.markAsFinished() }
            }
            if !progressed { try await Task.sleep(for: .milliseconds(1)) }
        }
        vIn.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
