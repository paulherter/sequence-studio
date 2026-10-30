import Foundation
import SQCore
import SQExport
import SQFrame
import SQMedia
import SQMediaFFmpeg
import SQPlayback
import Testing

/// Windows media seam end to end on generated clips (nothing committed): export a pattern clip whose frame index is
/// painted as 10 bit stripes, reopen it, decode with frame-accurate seeks (hardware and software), decode a tone.
@Suite(.serialized) struct FFmpegMediaTests {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sqffmpeg-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// NV12 frames 640x360 (or any size): the luma is split into 10 vertical stripes, stripe b white when bit b of the
    /// frame index is set. Chroma neutral.
    struct PatternSource: FrameSource {
        let width: Int, height: Int, frameCount: Int
        let frameDuration = Time(1, 30)
        func frame(at index: Int) async throws -> ExportFrame {
            var bytes = [UInt8](repeating: 128, count: width * height * 3 / 2)
            let stripe = width / 10
            for y in 0..<height {
                for x in 0..<width {
                    let bit = min(9, x / stripe)
                    bytes[y * width + x] = (index >> bit) & 1 == 1 ? 235 : 16
                }
            }
            return SQFrame(width: width, height: height, pixelFormat: .nv12, colorSpace: .rec709,
                           presentationTime: Time(Int64(index), 30), storage: MemoryFrame(bytes: bytes, bytesPerRow: width))
        }
    }

    static func index(of frame: SQFrame) throws -> Int {
        guard let s = frame.storage as? FFmpegFrame else { throw FFmpegError.message("not an FFmpeg frame") }
        let px = try s.download()
        let w = frame.width, deep = frame.pixelFormat == .p010 || frame.pixelFormat == .p010FullRange
        let row = frame.height / 2
        var v = 0
        for bit in 0..<10 {
            let x = (w / 10) * bit + w / 20
            let luma = deep ? Int(px[(row * w + x) * 2 + 1]) : Int(px[row * w + x])
            if luma > 128 { v |= 1 << bit }
        }
        return v
    }

    static func settings(_ codec: VideoCodec, width: Int, height: Int, hardware: Bool = true) -> ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec
        s.video.width = width; s.video.height = height
        s.video.frameDuration = Time(1, 30)
        s.video.bitrate = .average(8_000_000)
        s.video.keyframeInterval = 30
        s.video.hardwareEncoding = hardware
        return s
    }

    /// The 3 s pattern clip with a 1 kHz tone, written once.
    static let clip: URL = {
        let url = dir.appendingPathComponent("pattern.mp4")
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await FFmpegExportEncoder().export(video: PatternSource(width: 640, height: 360, frameCount: 90),
                                                        audio: SineAudioSource(sampleRate: 48_000, channels: 1, duration: Time(3, 1),
                                                                               frequency: 1000, amplitude: 0.5),
                                                        settings: settings(.h264, width: 640, height: 360), to: url,
                                                        progress: { _ in })
            sem.signal()
        }
        sem.wait()
        return url
    }()

    static func ffprobe(_ url: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "ffprobe.exe")
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";").map(String.init)
        if let bin = paths.first(where: { FileManager.default.fileExists(atPath: $0 + "\\ffprobe.exe") }) {
            p.executableURL = URL(fileURLWithPath: bin + "\\ffprobe.exe")
        }
        p.arguments = ["-v", "error"] + args + [url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func exportWritesThreeSecondsOfH264AndAAC() throws {
        let url = Self.clip
        #expect(FileManager.default.fileExists(atPath: url.path))
        print("export encoder:", FFmpegExportEncoder.lastVideoEncoder)
        let video = try Self.ffprobe(url, ["-select_streams", "v:0", "-count_frames", "-show_entries",
                                           "stream=codec_name,width,height,nb_read_frames", "-of", "csv=p=0"])
        #expect(video.trimmingCharacters(in: .whitespacesAndNewlines) == "h264,640,360,90")
        let audio = try Self.ffprobe(url, ["-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate,channels",
                                           "-of", "csv=p=0"])
        #expect(audio.trimmingCharacters(in: .whitespacesAndNewlines) == "aac,48000,2")
        let duration = try Self.ffprobe(url, ["-show_entries", "format=duration", "-of", "csv=p=0"])
        let d = Double(duration.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(abs(d - 3) < 0.1)
    }

    @Test func aLonePictureFileOpensAsOneFrame() throws {
        // A 1x1 PNG: the image2 demuxer gives its packet no file position ("packet without file position" before).
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let url = Self.dir.appendingPathComponent("lone-picture.png")
        try png.write(to: url)
        let d = try FFmpegDemuxer(url: url)
        #expect(d.index.count == 1)
        #expect(d.trackInfo.width == 1 && d.trackInfo.height == 1)
    }

    @Test func demuxerIndexesEveryFrameInPresentationOrder() throws {
        let d = try FFmpegDemuxer(url: Self.clip)
        #expect(d.index.count == 90)
        #expect(d.index.entries.first?.pts == .zero)
        #expect(d.index.entries[45].pts == Time(45, 30))
        #expect(d.trackInfo.width == 640 && d.trackInfo.height == 360)
        #expect(d.trackInfo.nominalFrameDuration == Time(1, 30))
        #expect(d.formatDescription.codec == "h264")
    }

    @Test(arguments: [true, false]) func seeksAreFrameAccurate(hardware: Bool) async throws {
        let d = try FFmpegDemuxer(url: Self.clip)
        let dec = try FFmpegVideoDecoder(demuxer: d, hardware: hardware)
        print("decoder:", dec.decoderName, "hardware:", dec.isHardware)
        if !hardware { #expect(!dec.isHardware) }
        for range in [45...47, 10...10, 89...89, 0...5, 6...12, 61...61, 30...31] {
            let frames = try await dec.decode(range)
            #expect(frames.map { $0.frame.presentationTime } == range.map { Time(Int64($0), 30) })
            #expect(try frames.map { try Self.index(of: $0.frame) } == Array(range))
        }
    }

    /// Open-GOP HEVC (x265's default CRA): the frame before each sync frame is a leading picture decoded after it; sought
    /// alone it used to come back missing ("were not decoded"). The FFmpeg build on the PC has no libx265, so this reads
    /// the 10-bit sample `scripts/win-app.sh` makes on the Mac (`SQ_SAMPLE_10BIT=1 scripts/win-app.sh sample`).
    /// shortcut: skipped when that sample is missing; upgrade to a generated clip once an open-GOP encoder is on the PC.
    /// The main thread asks `isHardware` on every pause; a running decode (the state lock) must not hold it up.
    @Test func isHardwareDoesNotWaitForARunningDecode() async throws {
        let d = try FFmpegDemuxer(url: Self.clip)
        let dec = try FFmpegVideoDecoder(demuxer: d, hardware: false)
        let inDecode = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await dec.decode(0...0, deliver: { _ in inDecode.signal(); _ = release.wait(timeout: .now() + 5) })
        }
        defer { release.signal() }
        #expect(inDecode.wait(timeout: .now() + 5) == .success)       // the decode now holds the lock inside deliver
        let start = DispatchTime.now()
        #expect(dec.isHardware == false)
        #expect(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 < 200)
        release.signal()
        _ = try await task.value
    }

    @Test(arguments: [true, false]) func openGOPLeadingPicturesDecodeWhenSoughtAlone(hardware: Bool) async throws {
        let path = ProcessInfo.processInfo.environment["SQ_OPEN_GOP_SAMPLE"]
            ?? "open-gop-sample.mp4"
        guard FileManager.default.fileExists(atPath: path) else { print("open-GOP sample missing:", path); return }
        let d = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        let dec = try FFmpegVideoDecoder(demuxer: d, hardware: hardware)
        let syncs = d.index.entries.indices.filter { d.index.entries[$0].isSync && $0 > 0 }
        let leading = d.index.entries.indices.filter { d.index.freshDecodeStart(for: $0) != $0 }
        print("open GOP: \(syncs.count) sync frames, \(leading.count) leading pictures, decoder \(dec.decoderName)")
        #expect(!leading.isEmpty)
        for f in Set(syncs.map { $0 - 1 } + leading).sorted() {
            dec.invalidate()
            let frames = try await dec.decode(f...f)
            #expect(frames.map { $0.frame.presentationTime } == [d.index.entries[f].pts], "frame \(f)")
        }
    }

    /// What zero-copy (D3D11VA texture straight into D3D12) would save: the GPU-to-memory copy of each hardware frame
    /// (`FFmpegFrame.download`), measured against the decode itself on the 1080p 10-bit open-GOP sample.
    @Test func hardwareFrameDownloadCost() async throws {
        let path = ProcessInfo.processInfo.environment["SQ_OPEN_GOP_SAMPLE"]
            ?? "open-gop-sample.mp4"
        guard FileManager.default.fileExists(atPath: path) else { print("open-GOP sample missing:", path); return }
        let d = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        let dec = try FFmpegVideoDecoder(demuxer: d, hardware: true)
        guard dec.isHardware else { print("no hardware decoder"); return }
        let n = min(100, d.index.entries.count)
        // Frames are dropped per batch: the decoder's texture pool holds only a few.
        var decodeTime = Duration.zero, copyTime = Duration.zero, bytes = 0, count = 0
        for start in stride(from: 0, to: n, by: 4) {
            let t0 = ContinuousClock.now
            let frames = try await dec.decode(start...min(n - 1, start + 3))
            decodeTime += ContinuousClock.now - t0
            for f in frames {
                guard let s = f.frame.storage as? FFmpegFrame else { continue }
                let c0 = ContinuousClock.now
                bytes += try s.download().count
                copyTime += ContinuousClock.now - c0
                count += 1
            }
        }
        let ms = { (t: Duration) in Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1000 }
        let per = Double(max(1, count))
        print("hardware download \(dec.decoderName): \(count) frames, decode \(ms(decodeTime) / per) ms/frame, "
              + "download \(ms(copyTime) / per) ms/frame, \(bytes / max(1, count)) bytes/frame")
        #expect(count == n)
    }

    @Test(arguments: [true, false]) func decodeSpeed1080p(hardware: Bool) async throws {
        let url = Self.dir.appendingPathComponent("speed1080.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await FFmpegExportEncoder().export(video: PatternSource(width: 1920, height: 1080, frameCount: 120), audio: nil,
                                                   settings: Self.settings(.h264, width: 1920, height: 1080), to: url,
                                                   progress: { _ in })
        }
        let dec = try FFmpegVideoDecoder(demuxer: try FFmpegDemuxer(url: url), hardware: hardware)
        let t0 = Date()
        var count = 0
        for start in stride(from: 0, to: 120, by: 8) {
            count += try await dec.decode(start...min(119, start + 7)).count
        }
        let fps = Double(count) / Date().timeIntervalSince(t0)
        print("1080p H.264 decode \(dec.decoderName) hardware \(dec.isHardware): \(Int(fps)) fps")
        #expect(count == 120)
        #expect(fps > 30)
    }

    @Test func hevcExportUsesHardwareOrIsUnavailable() async throws {
        let url = Self.dir.appendingPathComponent("pattern-hevc.mp4")
        do {
            try await FFmpegExportEncoder().export(video: PatternSource(width: 640, height: 360, frameCount: 30), audio: nil,
                                                   settings: Self.settings(.hevc, width: 640, height: 360), to: url,
                                                   progress: { _ in })
        } catch {
            print("HEVC export unavailable:", error)
            return
        }
        print("HEVC encoder:", FFmpegExportEncoder.lastVideoEncoder)
        let dec = try FFmpegVideoDecoder(demuxer: try FFmpegDemuxer(url: url))
        let frames = try await dec.decode(20...22)
        #expect(try frames.map { try Self.index(of: $0.frame) } == [20, 21, 22])
    }

    /// Every ProRes the Mac offers, with 24-bit PCM: the profile and sampling the Mac writes (4:2:2, 4444 as 4:4:4:4),
    /// every frame back at its index, the tone at its level.
    @Test(arguments: [(VideoCodec.prores422Proxy, "Proxy"), (.prores422LT, "LT"), (.prores422, "Standard"),
                      (.prores422HQ, "HQ"), (.prores4444, "4444")])
    func proResExportsTheMacProfiles(codec: VideoCodec, profile: String) async throws {
        var s = Self.settings(codec, width: 640, height: 360)
        s.audio.codec = .pcm; s.audio.pcmBitDepth = 24
        let url = Self.dir.appendingPathComponent("pattern-\(codec.rawValue).mov")
        try await FFmpegExportEncoder().export(video: PatternSource(width: 640, height: 360, frameCount: 30),
                                               audio: SineAudioSource(sampleRate: 48_000, channels: 1, duration: Time(1, 1),
                                                                      frequency: 1000, amplitude: 0.5),
                                               settings: s, to: url, progress: { _ in })
        #expect(FFmpegExportEncoder.lastVideoEncoder == "prores_ks")
        let video = try Self.ffprobe(url, ["-select_streams", "v:0", "-show_entries", "stream=codec_name,profile,pix_fmt",
                                           "-of", "csv=p=0"])
        let pix = codec == .prores4444 ? "yuva444p12le" : "yuv422p10le"   // FFmpeg reads every 4444 stream as 12-bit
        #expect(video.trimmingCharacters(in: .whitespacesAndNewlines) == "prores,\(profile),\(pix)")
        let audio = try Self.ffprobe(url, ["-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate",
                                           "-of", "csv=p=0"])
        #expect(audio.trimmingCharacters(in: .whitespacesAndNewlines) == "pcm_s24le,48000")
        let dec = try FFmpegVideoDecoder(demuxer: try FFmpegDemuxer(url: url))
        #expect(try await dec.decode(0...29).map { try Self.index(of: $0.frame) } == Array(0...29))
        let src = try FFmpegAudioSource(url: url)
        #expect(src.frameCount == 48_000)
        var l = [Float](repeating: 0, count: 24_000)
        _ = try l.withUnsafeMutableBufferPointer { try src.read(from: 12_000, count: 24_000, into: $0.baseAddress!, channel: 0) }
        let rms = (l.reduce(0) { $0 + $1 * $1 } / Float(l.count)).squareRoot()
        #expect(abs(rms - Float(0.5) / Float(2).squareRoot()) < 0.002)
    }

    @Test func proResNeedsAMovFile() async throws {
        await #expect(throws: ExportError.self) {
            try await FFmpegExportEncoder().export(video: PatternSource(width: 64, height: 64, frameCount: 1), audio: nil,
                                                   settings: Self.settings(.prores422, width: 64, height: 64),
                                                   to: Self.dir.appendingPathComponent("x.mp4"), progress: { _ in })
        }
    }

    /// 16-bit PCM WAV of a known tone decodes to the same samples (int16 / 32768, exact up to one LSB).
    @Test func wavToneDecodesToTheSamePCM() throws {
        let n = 48_000
        let samples: [Int16] = (0..<n).map { Int16(sin(2 * Double.pi * 440 * Double($0) / 48_000) * 16_000) }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
        for (i, s) in samples.enumerated() { u16(UInt16(bitPattern: s)); u16(UInt16(bitPattern: i % 2 == 0 ? s : -s)) }
        let url = Self.dir.appendingPathComponent("tone.wav")
        try data.write(to: url)

        let src = try FFmpegAudioSource(url: url)
        #expect(src.frameCount == Int64(n))
        #expect(!src.isMono)
        var l = [Float](repeating: 0, count: n), r = l
        #expect(try l.withUnsafeMutableBufferPointer { try src.read(from: 0, count: n, into: $0.baseAddress!, channel: 0) } == n)
        #expect(try r.withUnsafeMutableBufferPointer { try src.read(from: 0, count: n, into: $0.baseAddress!, channel: 1) } == n)
        var worst: Float = 0
        for i in 0..<n {
            let e = Float(samples[i]) / 32768
            let er = Float(i % 2 == 0 ? samples[i] : -samples[i]) / 32768
            worst = max(worst, abs(l[i] - e), abs(r[i] - er))
        }
        #expect(worst <= 1 / 32768)
    }

    @Test func exportedToneComesBackAtTheRightLevel() throws {
        let src = try FFmpegAudioSource(url: Self.clip)
        #expect(abs(src.frameCount - 144_000) < 2048)       // AAC priming / padding
        var l = [Float](repeating: 0, count: 48_000)
        _ = try l.withUnsafeMutableBufferPointer { try src.read(from: 48_000, count: 48_000, into: $0.baseAddress!, channel: 0) }
        let rms = (l.reduce(0) { $0 + $1 * $1 } / Float(l.count)).squareRoot()
        #expect(abs(rms - Float(0.5) / Float(2).squareRoot()) < 0.01)
    }

    @Test func wasapiOutputPullsAudio() async throws {
        let engine = WASAPIAudioEngine(resolver: { _ in MemoryAudioSource(mono: []) })
        do { try engine.prepare() } catch {
            print("no WASAPI output device:", error)
            return
        }
        defer { engine.shutdown() }
        print("WASAPI device:", engine.deviceName ?? "?", "latency:", engine.outputLatency)
        engine.setRate(.forward)
        engine.seek(to: .zero)
        engine.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        engine.stop()
        #expect(engine.renderedFrames > 9_600)
        #expect(engine.outputLatency > .zero)
        #expect(engine.consumedFrames > 0)
    }
}
