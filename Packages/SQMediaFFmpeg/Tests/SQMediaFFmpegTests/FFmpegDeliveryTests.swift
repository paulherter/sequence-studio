import Foundation
import SQCore
import SQExport
import SQFrame
import SQMediaFFmpeg
import Testing

/// The Mac export presets that are not one video file, written by FFmpeg on Windows: audio-only M4A / WAV / FLAC, stems,
/// animated GIF with the Mac delays, image sequences with the Mac code values (`FrameStillPixels`).
@Suite(.serialized) struct FFmpegDeliveryTests {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sqffmpeg-delivery", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func tool(_ name: String) -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";").map(String.init)
        if let bin = paths.first(where: { FileManager.default.fileExists(atPath: $0 + "\\\(name).exe") }) {
            return URL(fileURLWithPath: bin + "\\\(name).exe")
        }
        return URL(fileURLWithPath: "\(name).exe")
    }

    static func run(_ name: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = tool(name)
        p.arguments = ["-v", "error"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    static func probe(_ url: URL, _ args: [String]) throws -> String {
        String(decoding: try run("ffprobe", args + [url.path]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tone(_ seconds: Int = 1) -> SineAudioSource {
        SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(Int64(seconds), 1), frequency: 1000, amplitude: 0.5)
    }

    /// Float to binary16 bits for values exact in half.
    static func half(_ f: Float) -> UInt16 {
        if f == 0 { return 0 }
        let b = f.bitPattern
        return UInt16((b >> 16) & 0x8000) | UInt16(Int((b >> 23) & 0xFF) - 112) << 10 | UInt16((b >> 13) & 0x3FF)
    }

    /// RGBA half frames (premultiplied linear): left half (0.5, 0.25, 0, 0.5), right half opaque white; frame i shifts
    /// nothing, so every still is the same.
    struct HalfSource: FrameSource {
        let frameCount: Int
        let width = 64, height = 32
        let frameDuration = Time(1, 30)
        func frame(at index: Int) async throws -> ExportFrame {
            var px = [UInt16](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let c: [Float] = x < width / 2 ? [0.5, 0.25, 0, 0.5] : [1, 1, 1, 1]
                    for k in 0..<4 { px[(y * width + x) * 4 + k] = FFmpegDeliveryTests.half(c[k]) }
                }
            }
            return SQFrame(width: width, height: height, pixelFormat: .rgba16f, colorSpace: .rec709,
                           presentationTime: Time(Int64(index), 30),
                           storage: MemoryFrame(bytes: px.withUnsafeBytes { Array($0) }, bytesPerRow: width * 8))
        }
    }

    /// RGBA8 frames for GIF: a gradient that moves by the frame index.
    struct GradientSource: FrameSource {
        let frameCount: Int
        let width = 96, height = 48
        let frameDuration: Time
        func frame(at index: Int) async throws -> ExportFrame {
            var px = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    px[o] = UInt8((x * 2 + index * 8) & 255); px[o + 1] = UInt8(y * 5); px[o + 2] = UInt8(255 - x * 2)
                }
            }
            return SQFrame(width: width, height: height, pixelFormat: .rgba8, colorSpace: .rec709,
                           presentationTime: Time(Int64(index), 24), storage: MemoryFrame(bytes: px, bytesPerRow: width * 4))
        }
    }

    @Test(arguments: [(AudioFileFormat.m4a, 16, "aac,48000,2"), (.wav, 24, "pcm_s24le,48000,2"), (.wav, 16, "pcm_s16le,48000,2"),
                      (.wav, 32, "pcm_s32le,48000,2"), (.flac, 16, "flac,48000,2"), (.flac, 24, "flac,48000,2")])
    func audioOnlyFilesAreTheMacFormats(format: AudioFileFormat, bits: Int, expected: String) async throws {
        var s = ExportSettings()
        s.audioOnly = format
        s.audio.pcmBitDepth = bits
        s.video.frameDuration = Time(1, 25)
        let url = Self.dir.appendingPathComponent("tone-\(bits).\(format.fileExtension)")
        // The audio length is the video frame count times the frame duration (the Mac writer's rule): 25 frames = 1 s.
        try await FFmpegExportEncoder().export(video: HalfSource(frameCount: 25), audio: Self.tone(2), settings: s, to: url,
                                               progress: { _ in })
        #expect(try Self.probe(url, ["-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate,channels",
                                     "-of", "csv=p=0"]) == expected)
        if format == .flac {
            #expect(try Self.probe(url, ["-select_streams", "a:0", "-show_entries", "stream=bits_per_raw_sample", "-of", "csv=p=0"])
                    == String(bits))
        }
        let d = Double(try Self.probe(url, ["-show_entries", "format=duration", "-of", "csv=p=0"])) ?? 0
        #expect(abs(d - 1) < (format == .m4a ? 0.05 : 0.001))
        let src = try FFmpegAudioSource(url: url)
        var l = [Float](repeating: 0, count: 24_000)
        _ = try l.withUnsafeMutableBufferPointer { try src.read(from: 12_000, count: 24_000, into: $0.baseAddress!, channel: 0) }
        let rms = (l.reduce(0) { $0 + $1 * $1 } / Float(l.count)).squareRoot()
        #expect(abs(rms - Float(0.5) / Float(2).squareRoot()) < (format == .m4a ? 0.01 : 0.001))
    }

    @Test func stemsWriteThroughFFmpeg() async throws {
        var tl = Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30)))
        let c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, end: Time(1, 1)), start: .zero)
        var d = Track(kind: .audio, clips: [c]); d.audioRole = .dialogue
        var m = Track(kind: .audio, clips: [c]); m.audioRole = .music
        tl.tracks = [d, m]
        var a = AudioSettings(); a.codec = .pcm; a.pcmBitDepth = 24
        let out = try await StemExporter.export(stems: StemPlan.stems(for: tl), base: "Show", directory: Self.dir, format: .wav,
                                                duration: Time(1, 1), settings: a, encoder: FFmpegExportEncoder(),
                                                audioFor: { _ in Self.tone() }, progress: { _ in })
        #expect(out.map(\.url.lastPathComponent) == ["Show_dialogue.wav", "Show_music.wav", "Show_me.wav"])
        for w in out {
            #expect(try Self.probe(w.url, ["-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0"]) == "pcm_s24le")
        }
    }

    @Test func gifLoopsWithTheMacDelays() async throws {
        var s = ExportSettings()
        s.frameOutput = .gif
        s.video.width = 96; s.video.height = 48
        s.video.frameDuration = Time(1, 24)
        let url = Self.dir.appendingPathComponent("moving.gif")
        try await FFmpegExportEncoder().export(video: GradientSource(frameCount: 6, frameDuration: Time(1, 24)), audio: nil,
                                               settings: s, to: url, progress: { _ in })
        #expect(try Self.probe(url, ["-select_streams", "v:0", "-count_frames", "-show_entries",
                                     "stream=codec_name,width,height,nb_read_frames", "-of", "csv=p=0"]) == "gif,96,48,6")
        let delays = try Self.probe(url, ["-select_streams", "v:0", "-show_entries", "packet=duration", "-of", "csv=p=0"])
            .split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        #expect(delays == GIFTiming.delaysCentiseconds(frameDuration: Time(1, 24), frameCount: 6))
        // Loops forever: the NETSCAPE2.0 block with count 0.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("NETSCAPE2.0".utf8)) != nil)
    }

    @Test(arguments: FrameStillFormat.allCases)
    func imageSequenceWritesTheMacCodeValues(format: FrameStillFormat) async throws {
        var s = ExportSettings()
        s.frameOutput = .sequence(format)
        s.video.width = 64; s.video.height = 32
        let folder = Self.dir.appendingPathComponent("Shot-\(format.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try await FFmpegExportEncoder().export(video: HalfSource(frameCount: 3), audio: nil, settings: s, to: folder, progress: { _ in })
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let ext = format.fileExtension
        #expect(names == ["Shot-\(format.rawValue)_0000.\(ext)", "Shot-\(format.rawValue)_0001.\(ext)", "Shot-\(format.rawValue)_0002.\(ext)"])
        let file = folder.appendingPathComponent(names[0])
        let codec = try Self.probe(file, ["-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0"])
        let expected = ["png": "png", "jpg": "mjpeg", "tiff": "tiff", "exr": "exr"][ext]!
        #expect(codec == "\(expected),64,32")
        // The pixels read back: 8 / 16-bit formats exactly the shared code values (JPEG within its loss).
        let frame = try await HalfSource(frameCount: 1).frame(at: 0)
        let ref = try #require((frame.storage as! MemoryFrame).bytes.withUnsafeBytes {
            FrameStillPixels.image(halfRGBA: $0, width: 64, height: 32, bytesPerRow: 512, format: format)
        })
        switch format {
        case .png, .pngAlpha, .jpeg:
            let raw = try Self.run("ffmpeg", ["-i", file.path, "-f", "rawvideo", "-pix_fmt", "rgba", "-"])
            #expect(raw.count == ref.bytes.count)
            let worst = zip(raw, ref.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 255
            #expect(worst <= (format == .jpeg ? 6 : 0))
        case .tiff16, .tiff16Alpha:
            let raw = try Self.run("ffmpeg", ["-i", file.path, "-f", "rawvideo", "-pix_fmt", "rgba64le", "-"])
            #expect(raw == Data(ref.bytes))
        case .exr:
            let raw = try Self.run("ffmpeg", ["-i", file.path, "-f", "rawvideo", "-pix_fmt", "gbrapf32le", "-"])
            #expect(raw.count == 64 * 32 * 16)
            let r = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 64 * 32 * 8, as: Float.self) }   // R plane, first pixel
            let a = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 64 * 32 * 12, as: Float.self) }
            let g = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float.self) }
            let b = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 64 * 32 * 4, as: Float.self) }
            // Premultiplied linear, as the Mac EXR; within half a half-float step (ffmpeg.exe reads back through swscale).
            #expect(zip([r, g, b, a], [Float(0.5), 0.25, 0, 0.5]).allSatisfy { abs($0 - $1) < 0.00025 })
        }
    }
}
