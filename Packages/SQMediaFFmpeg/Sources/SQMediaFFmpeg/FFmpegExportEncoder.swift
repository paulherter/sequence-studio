import CSQFFmpeg
import Foundation
import SQCore
import SQExport
import SQFrame

/// `ExportEncoding` on Windows: H.264 / HEVC through FFmpeg (hardware first: AMD AMF, NVIDIA NVENC, Intel Quick Sync,
/// Media Foundation; H.264 falls back to OpenH264 in software) or every ProRes the Mac offers (FFmpeg `prores_ks`, 10-bit
/// 4:2:2, 4444 as 4:4:4:4), plus AAC or 16 / 24 / 32-bit PCM audio, into MP4 or MOV by the file extension.
/// Audio-only files (M4A, WAV, FLAC; stems through `exportAudioFile`), animated GIF (a palette per frame, `GIFPalette`,
/// the Mac `GIFTiming` delays) and image sequences (`FrameStillPixels`, the Mac code values; PNG, JPEG, TIFF, EXR), as
/// the Mac writers. Loudness normalization through the portable `NormalizedAudioSource`.
/// Frames come as `SQFrame` with `MemoryFrame` (BGRA, RGBA, NV12, P010, RGBA half) or `FFmpegFrame` storage; image
/// sequences want RGBA half (premultiplied linear, the Mac `.rgbaHalf`).
/// shortcut: no HDR tags, metadata, or loudness read back from the written file (the Mac `OutputAudioVerifier`); upgrade
/// when the Windows export panel shows them.
public struct FFmpegExportEncoder: ExportEncoding {
    public init() {}

    /// Name of the video encoder the last export used (tests, diagnostics).
    nonisolated(unsafe) public static var lastVideoEncoder = ""

    @discardableResult
    public func export(video: any FrameSource, audio: (any SQExport.AudioSource)?, settings: ExportSettings, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        let v = settings.video
        let issues = settings.validate()
        guard issues.isEmpty else { throw ExportError.invalidSettings(issues) }
        if let format = settings.audioOnly {
            // The Mac writer's rule: the length is the sequence frame duration times the frame count.
            guard let audio else { throw ExportError.noAudio }
            return try await exportAudioFile(audio, format: format, duration: settings.video.frameDuration * Int64(video.frameCount),
                                             settings: settings.effectiveAudio, to: url, progress: progress)
        }
        if let output = settings.frameOutput {
            guard video.frameCount > 0 else { throw ExportError.emptySource }
            switch output {
            case .gif: try await writeGIF(video, to: url, progress: progress)
            case .sequence(let f): try await writeSequence(video, format: f, into: url, progress: progress)
            }
            progress(1)
            return nil
        }
        if v.codec.isProRes, url.pathExtension.lowercased() != "mov" {
            throw ExportError.writerFailed("ProRes needs a .mov file")
        }
        if let audio, settings.audio.enabled, audio.sampleRate != settings.audio.sampleRate {
            // shortcut: no resampling here; the timeline audio source already renders at the export rate.
            throw ExportError.writerFailed("audio at \(audio.sampleRate) Hz, the export at \(settings.audio.sampleRate) Hz")
        }
        let fd = video.frameDuration
        let (audio, report) = try await Self.normalized(settings.audio.enabled ? audio : nil, settings.audio)
        let withAudio = audio != nil && settings.audio.enabled
        let channels = max(1, min(2, settings.audio.channels))
        let rate = settings.audio.sampleRate
        try? FileManager.default.removeItem(at: url)
        var cfg = SQFFEncodeConfig()
        cfg.hevc = v.codec == .hevc ? 1 : 0
        cfg.hardware = v.hardwareEncoding ? 1 : 0
        cfg.width = Int32(v.width); cfg.height = Int32(v.height)
        cfg.fpsNum = Int32(fd.timescale); cfg.fpsDen = Int32(fd.value)
        cfg.bitrate = Int64(v.bitrate.averageBitsPerSecond)
        cfg.gop = Int32(max(1, v.keyframeInterval))
        cfg.bFrames = v.allowsFrameReordering ? 2 : 0
        cfg.tenBit = v.codec == .hevc && v.profile == .main10 ? 1 : 0
        cfg.prores = Self.proresProfile(v.codec)
        cfg.pcmBits = settings.audio.codec == .pcm ? Int32(settings.audio.pcmBitDepth) : 0
        cfg.audioRate = Int32(rate)
        cfg.audioChannels = withAudio ? Int32(channels) : 0
        cfg.audioBitrate = Int64(settings.audio.bitrate)
        var err = [CChar](repeating: 0, count: 256)
        var enc: OpaquePointer?
        let r = url.withUnsafeFileSystemRepresentation { path in
            cfg.path = path
            return sq_enc_open(&cfg, &enc, &err, Int32(err.count))
        }
        guard r == 0, let enc else { throw ExportError.writerFailed(FFmpegError.from("encoder", r, err).description) }
        Self.lastVideoEncoder = String(cString: sq_enc_video_name(enc))
        var finished = false
        defer { if !finished { sq_enc_abort(enc); try? FileManager.default.removeItem(at: url) } }

        let n = video.frameCount
        var audioWritten: Int64 = 0
        var audioEnded = false
        for i in 0..<n {
            try Task.checkCancellation()
            let frame = try await video.frame(at: i)
            try Self.encode(frame, index: Int64(i), width: v.width, height: v.height, into: enc)
            if withAudio, let audio {
                // Audio up to the end of this frame, so the muxer interleaves evenly. Past the source's end: silence.
                let end = Int64((Int128(i + 1) * Int128(fd.value) * Int128(rate) + Int128(fd.timescale) / 2) / Int128(fd.timescale))
                while audioWritten < end {
                    let want = Int(min(4096, end - audioWritten))
                    var out: [Float]
                    if !audioEnded, let chunk = try await audio.nextChunk(maxFrames: want), chunk.frameCount > 0 {
                        out = Self.remix(chunk, to: channels)
                    } else {
                        audioEnded = true
                        out = [Float](repeating: 0, count: want * channels)
                    }
                    let frames = out.count / channels
                    let e = out.withUnsafeBufferPointer { sq_enc_audio(enc, $0.baseAddress, Int32(frames)) }
                    guard e == 0 else { throw ExportError.writerFailed(FFmpegError.failed("audio encode", e).description) }
                    audioWritten += Int64(frames)
                }
            }
            progress(Double(i + 1) / Double(max(1, n)))
        }
        finished = true
        let f = sq_enc_finish(enc, &err, Int32(err.count))
        guard f == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(FFmpegError.from("finish", f, err).description)
        }
        return report
    }

    /// The mix with the loudness gain when the settings ask for it (the Mac `ExportWriter.normalizedAudio`).
    static func normalized(_ audio: (any SQExport.AudioSource)?, _ settings: AudioSettings) async throws
        -> ((any SQExport.AudioSource)?, LoudnessReport?) {
        guard let l = settings.loudness, let a = audio else { return (audio, nil) }
        guard let r = a as? any RewindableAudioSource else { throw ExportError.loudnessNeedsRewindableSource }
        let n = try await NormalizedAudioSource.make(r, settings: l)
        return (n, LoudnessReport(normalized: n, settings: l))
    }

    // MARK: Audio files

    /// M4A (AAC), WAV (16 / 24 / 32-bit PCM) or FLAC (16 / 24-bit) of `duration`, at the mix's rate; silence pads a mix
    /// that ends early, a longer one is cut at `duration` (the Mac writer's length).
    @discardableResult
    public func exportAudioFile(_ audio: any SQExport.AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                                to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        var s = settings
        s.codec = format.codec
        if format == .flac, ![16, 24].contains(s.pcmBitDepth) { s.pcmBitDepth = s.pcmBitDepth > 24 ? 24 : 16 }
        let (source, report) = try await Self.normalized(audio, s)
        guard let source else { throw ExportError.noAudio }
        let rate = source.sampleRate
        let channels = max(1, min(2, s.channels))
        try? FileManager.default.removeItem(at: url)
        var cfg = SQFFEncodeConfig()
        cfg.noVideo = 1
        cfg.flac = format == .flac ? 1 : 0
        cfg.pcmBits = format == .m4a ? 0 : Int32(s.pcmBitDepth)
        cfg.audioRate = Int32(rate)
        cfg.audioChannels = Int32(channels)
        cfg.audioBitrate = Int64(s.bitrate)
        let enc = try Self.open(&cfg, url)
        var finished = false
        defer { if !finished { sq_enc_abort(enc); try? FileManager.default.removeItem(at: url) } }
        let total = max(1, Int64((Int128(duration.value) * Int128(rate) + Int128(duration.timescale) / 2) / Int128(max(1, duration.timescale))))
        var written: Int64 = 0, ended = false
        while written < total {
            try Task.checkCancellation()
            let want = Int(min(4096, total - written))
            var out: [Float]
            if !ended, let chunk = try await source.nextChunk(maxFrames: want), chunk.frameCount > 0 {
                out = Self.remix(chunk, to: channels)
                if out.count / channels > want { out = Array(out[..<(want * channels)]) }
            } else {
                ended = true
                out = [Float](repeating: 0, count: want * channels)
            }
            let frames = out.count / channels
            let e = out.withUnsafeBufferPointer { sq_enc_audio(enc, $0.baseAddress, Int32(frames)) }
            guard e == 0 else { throw ExportError.writerFailed(FFmpegError.failed("audio encode", e).description) }
            written += Int64(frames)
            progress(Double(written) / Double(total))
        }
        try Self.finish(enc, url)
        finished = true
        progress(1)
        return report
    }

    private static func open(_ cfg: inout SQFFEncodeConfig, _ url: URL) throws -> OpaquePointer {
        var err = [CChar](repeating: 0, count: 256)
        var enc: OpaquePointer?
        let r = url.withUnsafeFileSystemRepresentation { path in
            cfg.path = path
            return sq_enc_open(&cfg, &enc, &err, Int32(err.count))
        }
        guard r == 0, let enc else { throw ExportError.writerFailed(FFmpegError.from("encoder", r, err).description) }
        return enc
    }

    /// Writes the trailer (the encoder is freed either way).
    private static func finish(_ enc: OpaquePointer, _ url: URL) throws {
        var err = [CChar](repeating: 0, count: 256)
        let f = sq_enc_finish(enc, &err, Int32(err.count))
        guard f == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(FFmpegError.from("finish", f, err).description)
        }
    }

    // MARK: GIF and image sequences

    /// Looping GIF, one palette per frame, frame i from round(i * 100 / fps) to round((i + 1) * 100 / fps) centiseconds.
    func writeGIF(_ video: any FrameSource, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let n = video.frameCount
        let delays = GIFTiming.delaysCentiseconds(frameDuration: video.frameDuration, frameCount: n)
        try? FileManager.default.removeItem(at: url)
        var enc: OpaquePointer?
        var finished = false
        defer { if !finished { if let enc { sq_enc_abort(enc) }; try? FileManager.default.removeItem(at: url) } }
        var start: Int64 = 0
        for i in 0..<n {
            try Task.checkCancellation()
            let frame = try await video.frame(at: i)
            guard let m = frame.storage as? MemoryFrame, frame.pixelFormat == .rgba8 || frame.pixelFormat == .bgra8 else {
                throw ExportError.writerFailed("GIF frame \(i) is not 8-bit RGBA")
            }
            if enc == nil {
                var cfg = SQFFEncodeConfig()
                cfg.gif = 1
                cfg.width = Int32(frame.width); cfg.height = Int32(frame.height)
                cfg.fpsNum = Int32(video.frameDuration.timescale); cfg.fpsDen = Int32(max(1, video.frameDuration.value))
                cfg.gop = 1
                cfg.gifFinalDelay = Int32(delays.last ?? 1)
                enc = try Self.open(&cfg, url)
            }
            let bgra = frame.pixelFormat == .bgra8
            let pal = m.bytes.withUnsafeBytes {
                GIFPalette.quantize($0, width: frame.width, height: frame.height, bytesPerRow: m.bytesPerRow,
                                    rOffset: bgra ? 2 : 0, gOffset: 1, bOffset: bgra ? 0 : 2)
            }
            var bytes = pal.indices
            bytes.reserveCapacity(bytes.count + 1024)
            for k in 0..<256 {
                let c = k < pal.colors.count ? pal.colors[k] : (0, 0, 0)
                bytes += [c.2, c.1, c.0, 255]   // AV_PIX_FMT_PAL8 entries: native-endian 0xAARRGGBB
            }
            let r = bytes.withUnsafeBufferPointer { sq_enc_video(enc, $0.baseAddress, "pal8", Int32(frame.width), start) }
            guard r == 0 else { throw ExportError.writerFailed(FFmpegError.failed("GIF frame \(i)", r).description) }
            start += Int64(delays[i])
            progress(Double(i + 1) / Double(n) * 0.98)
        }
        guard let e = enc else { throw ExportError.emptySource }
        finished = true
        try Self.finish(e, url)
    }

    /// `folder` (created; its name is the file name stem) gets one numbered still per frame (`ImageSequenceNaming`).
    @discardableResult
    func writeSequence(_ video: any FrameSource, format: FrameStillFormat, into folder: URL, startNumber: Int = 0,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = video.frameCount
        let names = ImageSequenceNaming.fileNames(stem: folder.lastPathComponent, startNumber: startNumber, count: total,
                                                  ext: format.fileExtension)
        var urls: [URL] = []
        for i in 0..<total {
            try Task.checkCancellation()
            let frame = try await video.frame(at: i)
            guard let m = frame.storage as? MemoryFrame, frame.pixelFormat == .rgba16f else {
                throw ExportError.writerFailed("image sequence frame \(i) is not RGBA half")
            }
            let file = folder.appendingPathComponent(names[i])
            try Self.writeStill(m.bytes, width: frame.width, height: frame.height, bytesPerRow: m.bytesPerRow, format: format, to: file)
            urls.append(file)
            progress(Double(i + 1) / Double(total))
        }
        return urls
    }

    /// One still from rgba halves (premultiplied linear) in `format`.
    static func writeStill(_ half: [UInt8], width w: Int, height h: Int, bytesPerRow: Int, format: FrameStillFormat, to url: URL) throws {
        guard let img = half.withUnsafeBytes({ FrameStillPixels.image(halfRGBA: $0, width: w, height: h, bytesPerRow: bytesPerRow, format: format) })
        else { throw ExportError.writerFailed("still \(url.lastPathComponent): the frame is too small") }
        let codec: String, pixFmt: String
        var bytes = img.bytes, stride = img.bytesPerRow
        switch format {
        case .png, .pngAlpha: codec = "png"; pixFmt = "rgba"
        case .jpeg: codec = "mjpeg"; pixFmt = "rgba"
        case .tiff16, .tiff16Alpha: codec = "tiff"; pixFmt = "rgba64le"
        case .exr:
            // The EXR encoder takes planar G, B, R, A floats.
            codec = "exr"; pixFmt = "gbrapf32le"
            var planes = [Float](repeating: 0, count: w * h * 4)
            img.bytes.withUnsafeBytes { src in
                let n = w * h
                func channel(_ p: Int, _ k: Int) -> Float {
                    FrameStillPixels.float(halfBits: src.loadUnaligned(fromByteOffset: (p * 4 + k) * 2, as: UInt16.self))
                }
                for p in 0..<n {
                    planes[p] = channel(p, 1); planes[n + p] = channel(p, 2)
                    planes[2 * n + p] = channel(p, 0); planes[3 * n + p] = channel(p, 3)
                }
            }
            bytes = planes.withUnsafeBytes { Array($0) }
            stride = w * 4
        }
        var err = [CChar](repeating: 0, count: 256)
        try? FileManager.default.removeItem(at: url)
        let r = bytes.withUnsafeBufferPointer { px in
            url.withUnsafeFileSystemRepresentation { path in
                sq_still_write(path, codec, px.baseAddress, pixFmt, Int32(stride), Int32(w), Int32(h), img.hasAlpha ? 1 : 0, 0.95,
                               &err, Int32(err.count))
            }
        }
        guard r == 0 else { throw ExportError.writerFailed(FFmpegError.from("still \(url.lastPathComponent)", r, err).description) }
    }

    /// The C config's ProRes value: 0 for H.264 / HEVC, else 1 + the `prores_ks` profile.
    static func proresProfile(_ c: VideoCodec) -> Int32 {
        switch c {
        case .h264, .hevc: 0
        case .prores422Proxy: 1
        case .prores422LT: 2
        case .prores422: 3
        case .prores422HQ: 4
        case .prores4444: 5
        }
    }

    private static func encode(_ frame: SQFrame, index: Int64, width: Int, height: Int, into enc: OpaquePointer) throws {
        guard frame.width == width, frame.height == height else {
            throw ExportError.writerFailed("frame \(index) is \(frame.width)x\(frame.height), the export \(width)x\(height)")
        }
        let bytes: [UInt8], stride: Int, format: String
        switch frame.storage {
        case let m as MemoryFrame:
            bytes = m.bytes; stride = m.bytesPerRow
            guard let f = pixelFormatName(frame.pixelFormat) else {
                throw ExportError.writerFailed("pixel format \(frame.pixelFormat) cannot be exported")
            }
            format = f
        case let f as FFmpegFrame:
            bytes = try f.download()
            let deep = frame.pixelFormat == .p010 || frame.pixelFormat == .p010FullRange
            stride = deep ? width * 2 : width
            format = deep ? "p010le" : "nv12"
        default:
            throw ExportError.writerFailed("frame \(index) has a storage this encoder cannot read")
        }
        let r = bytes.withUnsafeBufferPointer { sq_enc_video(enc, $0.baseAddress, format, Int32(stride), index) }
        guard r == 0 else { throw ExportError.writerFailed(FFmpegError.failed("video encode frame \(index)", r).description) }
    }

    /// Interleaved samples in `channels` (1 or 2): mono doubles, more channels keep the first two (or average to mono).
    static func remix(_ c: AudioChunk, to channels: Int) -> [Float] {
        let n = c.frameCount, src = max(1, c.channels)
        if src == channels { return c.samples }
        var out = [Float](repeating: 0, count: n * channels)
        for k in 0..<n {
            let l = c.samples[k * src], r = src > 1 ? c.samples[k * src + 1] : l
            if channels == 2 { out[2 * k] = l; out[2 * k + 1] = r } else { out[k] = (l + r) * 0.5 }
        }
        return out
    }

    static func pixelFormatName(_ f: SQFramePixelFormat) -> String? {
        switch f {
        case .bgra8: "bgra"
        case .rgba8: "rgba"
        case .nv12, .nv12FullRange: "nv12"
        case .p010, .p010FullRange: "p010le"
        case .rgba16f: "rgbaf16le"
        default: nil
        }
    }
}
