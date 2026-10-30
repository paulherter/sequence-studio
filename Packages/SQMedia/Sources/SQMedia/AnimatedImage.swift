import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import SQCore

/// CREATOR 7: animated GIF / APNG / WebP and numbered image sequences become a clip without any project-file field.
/// The frames are rendered once into a cached ProRes 4444 strip (alpha kept, straight) which the normal video path plays,
/// so decode, scrubbing, export and relink need nothing new. The strip lives in Application Support (the project points at it).
public enum AnimatedImage {
    public struct Info: Sendable, Equatable {
        public var count: Int
        public var delays: [Time]
        public var duration: Time { delays.reduce(.zero, +) }
    }

    /// Longest side of a strip frame; larger pictures are scaled down.
    public static let maxDimension = 2048

    /// Where strips are cached: `<Application Support>/Sequence Studio/Animated Imports`.
    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sequence Studio", isDirectory: true).appendingPathComponent("Animated Imports", isDirectory: true)
    }

    /// Browser rule: a missing, zero or <= 10 ms delay plays at 100 ms.
    public static func frameDuration(seconds: Double?) -> Time {
        guard let s = seconds, s > 0.01 else { return Time(100, 1000) }
        return Time(Int64((s * 1000).rounded()), 1000)
    }

    /// Frame count and per-frame delays of a GIF, APNG or animated WebP; nil for single-frame or unreadable files.
    public static func info(of url: URL) -> Info? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }
        let delays = (0..<n).map { i -> Time in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            return frameDuration(seconds: delay(in: props))
        }
        return Info(count: n, delays: delays)
    }

    private static func delay(in props: [CFString: Any]?) -> Double? {
        guard let props else { return nil }
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dict, unclamped, clamped) in pairs {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            if let v = (d[unclamped] as? NSNumber)?.doubleValue ?? (d[clamped] as? NSNumber)?.doubleValue { return v }
        }
        return nil
    }

    /// In-place conversion of premultiplied BGRA to straight alpha (what ProRes 4444 alpha is tagged as).
    public static func unpremultiply(_ base: UnsafeMutableRawPointer, pixels: Int) {
        let p = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<pixels {
            let a = Int(p[i * 4 + 3])
            if a == 255 { continue }
            if a == 0 { p[i * 4] = 0; p[i * 4 + 1] = 0; p[i * 4 + 2] = 0; continue }
            for c in 0..<3 { p[i * 4 + c] = UInt8(min(255, (Int(p[i * 4 + c]) * 255 + a / 2) / a)) }
        }
    }

    // MARK: Strip

    public enum StripError: Error, Sendable, LocalizedError {
        case noFrames, writerFailed(String)

        /// English text (the display sink translates it with `SQL10n.localized`).
        public var errorDescription: String? {
            switch self {
            case .noFrames: "The image has no frames."
            case .writerFailed(let why): "The frames could not be written: \(why)"
            }
        }
    }

    /// Cache file for a source description (paths with size and date, so an edited file gets a new strip).
    static func stripURL(key parts: [String], in cache: URL) -> URL {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("\(digest).mov")
    }

    static func fileStamp(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
        let t = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path):\(size):\(Int64(t))"
    }

    /// Writes one frame per entry of `delays` (`frame(i)`, nil = repeat the previous one) into a ProRes 4444 .mov at `url`.
    static func writeStrip(to url: URL, width: Int, height: Int, delays: [Time], frame: @Sendable (Int) -> CGImage?) async throws {
        guard !delays.isEmpty, width > 0, height > 0 else { throw StripError.noFrames }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp.mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw StripError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        var t = Time.zero
        var last: CVPixelBuffer?
        for i in 0..<delays.count {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw StripError.writerFailed(writer.error?.localizedDescription ?? "failed") }
                try await Task.sleep(for: .milliseconds(1))
            }
            if let img = frame(i), let pb = try? straightBuffer(img, width: width, height: height) { last = pb }
            guard let pb = last else { throw StripError.noFrames }
            let pts = CMTime(value: t.value, timescale: Int32(clamping: t.timescale))
            guard adaptor.append(pb, withPresentationTime: pts) else {
                throw StripError.writerFailed(writer.error?.localizedDescription ?? "append")
            }
            t = t + delays[i]
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: t.value, timescale: Int32(clamping: t.timescale)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StripError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// `image` fitted into a `width` x `height` BGRA buffer with straight alpha, centered on transparent.
    static func straightBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { throw StillImage.StillError.bufferFailed }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw StillImage.StillError.bufferFailed }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let s = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * s, h = Double(image.height) * s
        ctx.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        let base = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<height { unpremultiply(base + y * stride, pixels: width) }
        return pb
    }

    /// Frame `i` of an image source, upright and no larger than `maxDimension`.
    static func frame(_ src: CGImageSource, _ i: Int, maxPixel: Int = maxDimension) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary)
    }
}

/// Numbered stills in one folder (`fx_0001.png`, `fx_0002.png` ...) that import as one clip.
public enum ImageSequence {
    /// Render formats only: camera photos (IMG_0001.jpg ...) are numbered too but are not frames.
    static let extensions: Set<String> = ["png", "tif", "tiff", "exr", "dpx", "tga"]

    private struct Part { var url: URL; var prefix: String; var digits: String; var number: Int; var ext: String }

    private static func part(_ url: URL) -> Part? {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let digits = String(stem.reversed().prefix { $0.isNumber }.reversed())
        guard !digits.isEmpty, digits.count <= 9, let n = Int(digits) else { return nil }
        return Part(url: url, prefix: String(stem.dropLast(digits.count)), digits: digits, number: n, ext: ext)
    }

    /// Runs of at least `minCount` (two) consecutively numbered files with the same folder, name and type, in frame order.
    public static func groups(in urls: [URL], minCount: Int = 2) -> [[URL]] {
        var buckets: [String: [Part]] = [:]
        for u in urls {
            if let p = part(u) { buckets[u.deletingLastPathComponent().path + "\u{0}" + p.prefix + "\u{0}" + p.ext, default: []].append(p) }
        }
        var out: [(String, [URL])] = []
        for (key, parts) in buckets {
            let sorted = parts.sorted { $0.number < $1.number }
            var run: [Part] = []
            func flush() {
                if run.count >= max(2, minCount) { out.append((key + String(format: "%012d", run[0].number), run.map(\.url))) }
                run = []
            }
            for p in sorted {
                if let l = run.last, p.number != l.number + 1 { flush() }
                run.append(p)
            }
            flush()
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// "fx_[001-004].png"
    public static func displayName(_ frames: [URL]) -> String {
        guard let f = frames.first.flatMap(part), let l = frames.last.flatMap(part) else { return frames.first?.lastPathComponent ?? "Sequence" }
        return "\(f.prefix)[\(f.digits)-\(l.digits)].\(frames[0].pathExtension)"
    }
}

extension MediaImporter {
    /// Default frame rate of an image sequence.
    public static let defaultSequenceFPS = 30

    /// Animated GIF / APNG / WebP: renders the frames into a cached strip and describes that strip.
    public static func probeAnimated(_ url: URL, cache: URL = AnimatedImage.defaultCacheDirectory) async throws -> (MediaRef, MediaInfo) {
        guard let anim = AnimatedImage.info(of: url), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let first = AnimatedImage.frame(src, 0) else { throw MediaError.unreadable }
        let strip = AnimatedImage.stripURL(key: ["anim", AnimatedImage.fileStamp(url)], in: cache)
        if !FileManager.default.fileExists(atPath: strip.path) {
            let source = UncheckedBox(src)
            do {
                try await AnimatedImage.writeStrip(to: strip, width: first.width, height: first.height, delays: anim.delays) { i in
                    AnimatedImage.frame(source.value, i)
                }
            } catch { throw MediaError.unreadable }
        }
        return try await describeStrip(strip, name: url.lastPathComponent)
    }

    /// Numbered stills (already in frame order) as one clip at `fps`.
    public static func probeSequence(_ frames: [URL], fps: Int = defaultSequenceFPS,
                                     cache: URL = AnimatedImage.defaultCacheDirectory) async throws -> (MediaRef, MediaInfo) {
        guard frames.count >= 2, fps > 0, let src0 = CGImageSourceCreateWithURL(frames[0] as CFURL, nil),
              let first = AnimatedImage.frame(src0, 0) else { throw MediaError.unreadable }
        let strip = AnimatedImage.stripURL(key: ["seq", String(fps)] + frames.map(AnimatedImage.fileStamp), in: cache)
        if !FileManager.default.fileExists(atPath: strip.path) {
            let urls = frames
            do {
                try await AnimatedImage.writeStrip(to: strip, width: first.width, height: first.height,
                                                   delays: Array(repeating: Time(1, Int64(fps)), count: frames.count)) { i in
                    CGImageSourceCreateWithURL(urls[i] as CFURL, nil).flatMap { AnimatedImage.frame($0, 0) }
                }
            } catch { throw MediaError.unreadable }
        }
        return try await describeStrip(strip, name: ImageSequence.displayName(frames))
    }

    private static func describeStrip(_ strip: URL, name: String) async throws -> (MediaRef, MediaInfo) {
        var (ref, info) = try await probe(strip)
        ref.name = name
        return (ref, info)
    }
}

/// Carries a non-Sendable ImageIO source into the writer closure; it is only read, one frame at a time, from that task.
private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
