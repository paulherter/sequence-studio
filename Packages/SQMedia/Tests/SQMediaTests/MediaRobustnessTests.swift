import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

// W6.3 MediaRobustnessSuite: the maintainer's real formats (when present under SQ_MEDIA_DIR, default ~/Documents/Videos, or
// TestMedia/) plus synthetic stand-ins written with AVAssetWriter, so the suite always checks something.
// Per file: import, rotation, first frame, last frame, duration ±1 frame, audio channels. Plus the 29.97 -> 30 conform.

private func write(_ spec: TestClipSpec) async throws -> URL? {
    do { return try await TestClipWriter.write(spec) }
    catch TestClipError.encoderUnavailable(let why) { Issue.record("encoder unavailable on this host: \(why)"); return nil }
}

private func stamp(_ f: DecodedFrame?) -> Int? { f.flatMap { FrameStamp.read($0.pixelBuffer) } }

/// Assertions every file must satisfy, whatever its format.
private func expectSound(_ r: MediaRobustness.Report, _ name: String) {
    #expect(r.problems.isEmpty, "\(name): \(r.problems)")
    #expect(r.firstFrame != nil && r.lastFrame != nil, "\(name): first/last frame not decoded")
    #expect(r.durationErrorFrames <= 1, "\(name): duration off by \(r.durationErrorFrames) frames")
}

@Suite(.serialized) struct MediaRobustnessSyntheticTests {
    /// Sony 4K H.264 Log stand-in: H.264, rotated 90, 29.97, stereo.
    @Test func sonyLikeRotatedH264() async throws {
        var s = TestClipSpec(); s.width = 640; s.height = 360; s.rotation = 90; s.frameCount = 45
        s.frameDuration = CMTime(value: 1001, timescale: 30000); s.audioClicks = [CMTime(value: 1, timescale: 2)]
        guard let url = try await write(s) else { return }
        let r = try await MediaRobustness.check(url)
        expectSound(r, "sony-like")
        let v = try #require(r.info.video)
        #expect(v.codec == "avc1" && v.rotation == 90 && v.displayWidth == 360 && v.displayHeight == 640)
        #expect(v.nominalFrameDuration == Time(1001, 30000) && !v.isVariableFrameRate)
        #expect(r.frameCount == 45)
        #expect(stamp(r.firstFrame) == 0 && stamp(r.lastFrame) == 44)
        #expect(r.firstFrame.map { CVPixelBufferGetWidth($0.pixelBuffer) } == 640)
        #expect(r.info.audio?.channels == 2 && r.audio?.isMono == false && r.audio?.readable == true)
    }

    /// Panasonic stand-in: HEVC Main10, 3:2, rotated 90, 29.97, stereo.
    @Test func panasonicLikeHEVC10Bit3x2() async throws {
        var s = TestClipSpec(); s.codec = .hevcMain10; s.width = 480; s.height = 320; s.rotation = 90; s.frameCount = 40
        s.frameDuration = CMTime(value: 1001, timescale: 30000); s.audioClicks = []
        guard let url = try await write(s) else { return }
        let r = try await MediaRobustness.check(url)
        expectSound(r, "panasonic-like")
        let v = try #require(r.info.video)
        #expect(v.codec == "hvc1" && v.bitDepth == 10 && v.width * 2 == v.height * 3 && v.rotation == 90)
        #expect(stamp(r.firstFrame) == 0 && stamp(r.lastFrame) == 39)
        #expect(r.info.audio?.channels == 2)
    }

    /// iPhone stand-in: HEVC 59.94, mono audio. Mono must reach both output channels identically.
    @Test func iPhoneLike5994Mono() async throws {
        var s = TestClipSpec(); s.codec = .hevcMain10; s.width = 320; s.height = 180; s.rotation = 90; s.frameCount = 60
        s.frameDuration = CMTime(value: 1001, timescale: 60000)
        s.audioChannels = 1; s.audioClicks = [CMTime(value: 1, timescale: 4), CMTime(value: 3, timescale: 4)]
        guard let url = try await write(s) else { return }
        let r = try await MediaRobustness.check(url)
        expectSound(r, "iphone-like")
        #expect(r.info.video?.nominalFrameDuration == Time(1001, 60000))
        #expect(r.info.audio?.channels == 1)
        let a = try #require(r.audio)
        #expect(a.isMono && a.readable && a.channelsIdentical)
        #expect(stamp(r.lastFrame) == 59)
    }

    /// Screen recording stand-in: VFR (frames only when the screen changed), no audio.
    @Test func screenRecordingVFR() async throws {
        var s = TestClipSpec(); s.width = 320; s.height = 288
        var t: Int64 = 0
        let gaps: [Int64] = [100, 100, 300, 100, 1200, 100, 100, 500, 100, 100, 2000, 100, 100, 100, 700, 100]
        s.presentationTimes = gaps.map { g in defer { t += g }; return CMTime(value: t, timescale: 6000) }
        s.frameDuration = CMTime(value: 100, timescale: 6000)
        guard let url = try await write(s) else { return }
        let r = try await MediaRobustness.check(url)
        expectSound(r, "screenrec-like")
        #expect(r.info.video?.isVariableFrameRate == true)
        #expect(r.info.audio == nil && r.audio == nil)
        #expect(stamp(r.firstFrame) == 0 && stamp(r.lastFrame) == gaps.count - 1)
    }

    /// ProRes 4444 (alpha-capable, 4:4:4): imports and decodes; alpha itself is W9.2.
    @Test func proRes4444() async throws {
        var s = TestClipSpec(); s.codec = .prores4444; s.width = 320; s.height = 180; s.frameCount = 20
        s.frameDuration = CMTime(value: 1, timescale: 30); s.audioClicks = []
        guard let url = try await write(s) else { return }
        let r = try await MediaRobustness.check(url)
        expectSound(r, "prores4444")
        let v = try #require(r.info.video)
        #expect(v.codec == "ap4h" && v.chroma == "4:4:4")
        #expect(r.frameCount == 20)
    }

    /// A real 29.97 file looped on a 30.00 sequence through the report.
    @Test func reportCarriesConformOnto30() async throws {
        var s = TestClipSpec(); s.frameCount = 90; s.frameDuration = CMTime(value: 1001, timescale: 30000)
        guard let url = try await write(s) else { return }
        let r = try await MediaRobustness.check(url, conformOnto: Time(1, 30), conformLength: Time(600, 1))
        let c = try #require(r.conform)
        #expect(c.maxLagFrames < 1)
        #expect(c.sequenceFrames == 18000)
    }
}

@Suite struct ConformTests {
    private func index(frameDuration fd: Time, count: Int) -> SampleIndex {
        SampleIndex(entries: (0..<count).map {
            .init(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % 15 == 0, decodeOrdinal: $0)
        })
    }

    /// 29.97 media on a 30.00 sequence for 10 minutes: the shown frame never lags real time by a whole frame, and the
    /// sequence repeats exactly the 18 frames the 0.1 % rate difference needs (no drift accumulates).
    @Test func ntscOn30DriftsLessThanOneFrameOver10Minutes() {
        let idx = index(frameDuration: Time(1001, 30000), count: 18_100)
        let c = MediaRobustness.conform(index: idx, sequenceFrameDuration: Time(1, 30), length: Time(600, 1))
        #expect(c.sequenceFrames == 18_000)
        #expect(c.maxLagFrames < 1 && c.maxLagFrames >= 0)
        #expect(c.repeatedFrames == 18 && c.skippedFrames == 0)
        #expect(c.endDriftFrames < 1)
    }

    /// The other direction: 30.00 media on a 29.97 sequence skips 18 frames, still no drift.
    @Test func thirtyOnNTSCSkipsWithoutDrift() {
        let idx = index(frameDuration: Time(1, 30), count: 18_100)
        let c = MediaRobustness.conform(index: idx, sequenceFrameDuration: Time(1001, 30000), length: Time(600, 1))
        #expect(c.maxLagFrames < 1)
        #expect(c.skippedFrames == 17 && c.repeatedFrames == 0)   // 17983 sequence frames cover 18000 media frames
    }

    /// Short media loops back to back (like a long timeline of copies): no drift across the seams either.
    @Test func loopedShortClipStaysInSync() {
        let idx = index(frameDuration: Time(1001, 30000), count: 1575)   // C2160.MP4 length, 52.5525 s
        let c = MediaRobustness.conform(index: idx, sequenceFrameDuration: Time(1, 30), length: Time(600, 1))
        #expect(c.maxLagFrames < 1)
        #expect(c.endDriftFrames < 1)
    }
}

/// The maintainer's real formats. Skips (passes without checks) when the footage is not on this Mac.
@Suite(.serialized) struct MediaRobustnessRealTests {
    struct Expect: Sendable, CustomTestStringConvertible {
        var label: String, path: String
        var codec: String, width: Int, height: Int, rotation: Int, bitDepth: Int?
        var frameDuration: Time?, vfr: Bool, channels: Int?
        var testDescription: String { label }
    }

    static let corpus: [Expect] = [
        Expect(label: "Sony 4K H.264 Log rot 90", path: "iOS 27 Features #2/C2160.MP4", codec: "avc1", width: 3840,
               height: 2160, rotation: 90, bitDepth: nil, frameDuration: Time(1001, 30000), vfr: false, channels: 2),
        Expect(label: "Panasonic HEVC 10-bit 3:2", path: "iPhone 18 Pro/P1000066.MP4", codec: "hvc1", width: 3840,
               height: 2560, rotation: 90, bitDepth: 10, frameDuration: Time(1001, 30000), vfr: false, channels: 2),
        Expect(label: "iPhone 59.94 mono", path: "Käsiger michael/IMG_1281.MOV", codec: "hvc1", width: 1920, height: 1080,
               rotation: 90, bitDepth: nil, frameDuration: Time(1001, 60000), vfr: false, channels: 1),
        Expect(label: "VFR screen recording", path: "16. Aug 2025/Yusuf Stitch Arbeitszeitbetrug/Bildschirmaufnahme 2025-08-16 um 13.51.17.mov",
               codec: "avc1", width: 2582, height: 2304, rotation: 0, bitDepth: 8, frameDuration: nil, vfr: true, channels: nil),
        Expect(label: "ProRes 4444", path: "prores4444.mov", codec: "ap4h", width: 0, height: 0, rotation: 0, bitDepth: nil,
               frameDuration: nil, vfr: false, channels: nil),
    ]

    static func locate(_ path: String) -> URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../TestMedia").standardized
        var dirs: [String] = [NSHomeDirectory() + "/Documents/Videos", repo.path]
        if let env = ProcessInfo.processInfo.environment["SQ_MEDIA_DIR"], !env.isEmpty { dirs.insert(env, at: 0) }
        for d in dirs {
            let u = URL(fileURLWithPath: d).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: u.path) { return u }
            let flat = URL(fileURLWithPath: d).appendingPathComponent((path as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }

    @Test(arguments: corpus) func realFile(_ e: Expect) async throws {
        guard let url = Self.locate(e.path) else { return }   // footage not on this Mac
        let r = try await MediaRobustness.check(url, conformOnto: Time(1, 30), conformLength: Time(600, 1))
        expectSound(r, e.label)
        let v = try #require(r.info.video)
        #expect(v.codec == e.codec, "\(e.label)")
        if e.width > 0 { #expect(v.width == e.width && v.height == e.height, "\(e.label): \(v.width)x\(v.height)") }
        #expect(v.rotation == e.rotation, "\(e.label)")
        if let b = e.bitDepth { #expect(v.bitDepth == b, "\(e.label): \(v.bitDepth)-bit") }
        if let fd = e.frameDuration { #expect(v.nominalFrameDuration == fd, "\(e.label): \(v.nominalFrameDuration)") }
        #expect(v.isVariableFrameRate == e.vfr, "\(e.label): vfr \(v.isVariableFrameRate)")
        #expect(r.info.audio?.channels == e.channels, "\(e.label): channels \(String(describing: r.info.audio?.channels))")
        if e.channels == 1 { #expect(r.audio?.channelsIdentical == true) }
        if let c = r.conform { #expect(c.maxLagFrames < 1, "\(e.label): conform lag \(c.maxLagFrames)") }
    }
}

/// Edit lists that cut media out (macOS screen recordings: `Bildschirmaufnahme …mov` shows media 0..2/60 s, skips
/// 0.25 s, then continues). The frame table must follow the presentation timeline, like AVAssetReader-based audio does.
@Suite(.serialized) struct EditListTests {
    /// Cuts media frames [cutFrom, cutTo) out of a 30 fps stamped clip via a movie header with an edit list.
    private func cutClip(frames: Int, cutFrom: Int64, cutTo: Int64) async throws -> URL {
        var s = TestClipSpec(); s.frameCount = frames
        let src = try await TestClipWriter.write(s)
        let movie = AVMutableMovie(url: src, options: nil)
        movie.removeTimeRange(CMTimeRange(start: CMTime(value: cutFrom, timescale: 30), end: CMTime(value: cutTo, timescale: 30)))
        let out = src.deletingLastPathComponent().appendingPathComponent("cut.mov")
        try movie.writeHeader(to: out, fileType: .mov, options: .addMovieHeaderToDestination)
        return out
    }

    @Test func cutOutMediaIsNotPresented() async throws {
        let url = try await cutClip(frames: 60, cutFrom: 10, cutTo: 20)
        let segments = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first!.load(.segments)
        #expect(segments.filter { !$0.isEmpty }.count == 2)
        let d = try await AVDemuxer(url: url)
        #expect(d.index.duration == Time(50, 30))
        let dec = try VTVideoDecoder(demuxer: d, media: UUID())
        for (t, stamp) in [(Int64(9), 9), (10, 20), (49, 59)] {
            let f = try #require(d.index.frame(at: Time(t, 30)))
            let frames = try await dec.decode(f...f)
            #expect(FrameStamp.read(frames[0].pixelBuffer) == stamp, "at \(t)/30")
        }
        #expect(d.index.frame(at: Time(50, 30)) == nil)

        let r = try await MediaRobustness.check(url)
        expectSound(r, "edit-list cut")
        #expect(r.info.video?.nominalFrameDuration == Time(1, 30) && r.info.video?.isVariableFrameRate == false)
    }

    @Test func hiddenSamplesSortBeforeTheShownFrame() {
        let fd = Time(1, 30)
        // Ordinal 2 is cut out (zero duration at the cut point 1/30); ordinal 1 is shown there.
        let idx = SampleIndex(entries: [
            .init(pts: .zero, dts: .zero, duration: fd, isSync: true, decodeOrdinal: 0),
            .init(pts: fd, dts: fd, duration: .zero, isSync: false, decodeOrdinal: 2),
            .init(pts: fd, dts: fd, duration: fd, isSync: false, decodeOrdinal: 1),
        ])
        #expect(idx.frame(at: fd).map { idx.entries[$0].decodeOrdinal } == 1)
    }
}

@Suite struct FrameRateJitterTests {
    private func info(_ ticks: [Int64], timescale: Int64) throws -> VideoTrackInfo {
        var t: Int64 = 0
        var e: [SampleIndex.Entry] = []
        for (i, d) in ticks.enumerated() {
            e.append(.init(pts: Time(t, timescale), dts: Time(t, timescale), duration: Time(d, timescale), isSync: i == 0, decodeOrdinal: i))
            t += d
        }
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16, extensions: nil,
                                       formatDescriptionOut: &fd)
        return try MediaImporter.videoInfo(format: try #require(fd), index: SampleIndex(entries: e))
    }

    /// iPhone 59.94 in timescale 600: 10/600 with an 11/600 every ~100 frames (IMG_1281.MOV) is constant frame rate.
    @Test func timescaleRoundingIsNotVFR() throws {
        let v = try info((0..<1000).map { $0 % 100 == 99 ? Int64(11) : 10 }, timescale: 600)
        #expect(!v.isVariableFrameRate)
        #expect(v.nominalFrameDuration == Time(1001, 60000))
        #expect(!(try info((0..<300).map { $0 % 3 == 2 ? Int64(21) : 20 }, timescale: 600)).isVariableFrameRate)   // 29.97
        // IMG_1282.MOV: one 9/600 among 10s and 11s.
        #expect(!(try info([10, 9] + (0..<500).map { $0 % 100 == 99 ? Int64(11) : 10 }, timescale: 600)).isVariableFrameRate)
    }

    @Test func realVFRStaysVFR() throws {
        // Screen recording: 1/60 frames with pauses.
        #expect(try info((0..<200).map { $0 % 50 == 49 ? Int64(700) : 100 }, timescale: 6000).isVariableFrameRate)
        // Low-light phone clip: 60 -> 30 fps switch in timescale 600.
        #expect(try info((0..<200).map { $0 < 100 ? Int64(10) : 20 }, timescale: 600).isVariableFrameRate)
        // Pure 1-and-2 frame gaps (tick = one frame) is not timescale rounding.
        #expect(try info((0..<200).map { $0 % 10 == 9 ? Int64(200) : 100 }, timescale: 6000).isVariableFrameRate)
    }
}
