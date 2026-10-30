import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SQCore
import SQMedia
import Synchronization
import Testing
@testable import SQAnalysis

extension VisionSuites {
/// Feedback 2026-10-18: the subject mask "hangs behind" a moving face. End to end on a written movie whose subject has a known
/// place on every frame: the tracker stores mattes, then each timeline frame looks its matte up the way the monitor does
/// (clip time mapping -> `SampleIndex.frame(at:)` -> that frame's pts -> the store). A matte from a neighbor frame shows
/// as an error of a whole number of steps (the patch moves `step` px per frame), a spatial bias as a constant error.
@Suite struct SubjectMatteTimingTests {
    struct Movie {
        var fps: Int32 = 30
        var frames = 60
        var codec: AVVideoCodecType = .h264
        /// B-frames: decode order differs from presentation order (camera files, most exports).
        var reorder = false
        /// Presentation time of frame 0 (> 0: an empty edit before it).
        var firstPTS: CMTime = .zero
        var transform: CGAffineTransform = .identity
        static let width = 640, height = 360, patch = 40, step = 4
        /// The patch center of frame `i` in stored pixels, y down.
        static func center(_ i: Int) -> CGPoint { CGPoint(x: Double(40 + patch / 2 + step * i), y: Double(height / 2)) }
    }

    static func write(_ m: Movie) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mattetiming-\(UUID().uuidString).mov")
        let w = Movie.width, h = Movie.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var compression: [String: Any] = [AVVideoAllowFrameReorderingKey: m.reorder, AVVideoMaxKeyFrameIntervalKey: 30]
        if m.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: m.codec, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoCompressionPropertiesKey: compression,
        ])
        input.transform = m.transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<m.frames {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                waited += 1
                if waited > 4000 || writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let b = try #require(pb)
            CVPixelBufferLockBaseAddress(b, [])
            let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.setFillColor(gray: 0.4, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let c = Movie.center(i), half = Double(Movie.patch / 2)
            let x = Int(c.x - half), y = h - Int(c.y + half)       // the context's y runs up
            let cell = Movie.patch / 4
            for cy in 0..<4 { for cx in 0..<4 {
                ctx.setFillColor(gray: (cx + cy) % 2 == 0 ? 1 : 0, alpha: 1)
                ctx.fill(CGRect(x: x + cx * cell, y: y + cy * cell, width: cell, height: cell))
            } }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTimeAdd(m.firstPTS, CMTime(value: CMTimeValue(i), timescale: m.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }

    /// Where a stored point shows upright (the track's preferred transform), as a fraction of the upright frame.
    static func upright(_ p: CGPoint, _ t: CGAffineTransform) -> (Vec2, width: Double, height: Double) {
        let box = CGRect(x: 0, y: 0, width: Movie.width, height: Movie.height).applying(t)
        let q = p.applying(t)
        return (Vec2((q.x - box.minX) / box.width, (q.y - box.minY) / box.height), box.width, box.height)
    }

    /// Tracks the whole movie, then checks every timeline frame of a clip (in-point `inFrame`, `speed`) on a sequence
    /// of `sequenceFPS`. Returns the largest error in upright source pixels and the mean signed error along the motion
    /// in frames (+ = the matte is ahead of the subject).
    static func measure(_ movie: Movie, url: URL, store: MagicMatteStore, key: String, inFrame: Int, speed: ClipSpeed,
                        sequenceFPS: Int64, playing: Bool = false, reversed: Bool = false) async throws -> (worst: Double, lead: Double, checked: Int) {
        let index = try await AVDemuxer(url: url).index
        let fd = Time(1, sequenceFPS)
        let inPoint = try #require(index.entries.indices.contains(inFrame) ? index.entries[inFrame].pts : nil)
        let sourceDuration = index.duration - inPoint
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: inPoint, duration: sourceDuration),
                        start: Time(3, 1), mediaDuration: index.duration, speed: speed)
        clip.reversed = reversed
        let along = upright(CGPoint(x: Movie.center(1).x, y: Movie.center(1).y), movie.transform).0
            - upright(Movie.center(0), movie.transform).0
        var worst = 0.0, lead = 0.0, checked = 0
        var t = clip.start
        while t < clip.timeline.end {
            defer { t = t + fd }
            let s = clip.sourceTime(at: t, frameDuration: fd)
            guard let i = index.frame(at: s) else { continue }
            let pts = seconds(index.entries[i].pts)
            // Paused / scrub: `matte(fills:)`; playing: what the look-ahead prepared (`preparedMatte`).
            let found = playing ? store.preparedMatte(key: key, pts: pts, feather: 0, expansion: 0, frameWidth: 640)
                                : store.matte(key: key, pts: pts, feather: 0, expansion: 0, frameWidth: 640, fills: true)
            let m = try #require(found, "no matte for frame \(i) at \(pts)")
            let c = try #require(m.centroid)
            let got = Vec2(c.x / Double(m.width), c.y / Double(m.height))
            let (want, uw, uh) = upright(Movie.center(i), movie.transform)
            let d = got - want
            let px = Vec2(d.x * uw, d.y * uh)
            worst = max(worst, px.length)
            let alongPx = Vec2(along.x * uw, along.y * uh)
            lead += (px.x * alongPx.x + px.y * alongPx.y) / max(alongPx.length * alongPx.length, 1e-9)
            checked += 1
        }
        return (worst, checked > 0 ? lead / Double(checked) : 0, checked)
    }


    static func click(_ movie: Movie) -> [MagicPoint] {
        [MagicPoint(position: upright(Movie.center(0), movie.transform).0, subtract: false, sourceTime: .zero)]
    }

    /// The system's segmentation (no model): what is measured is the time and space path alone.
    @Test(arguments: [24, 25, 30, 60] as [Int32])
    func matteSitsOnTheSubjectAtEveryTimelineFrame(fps: Int32) async throws {
        let all: [Movie] = [
            Movie(fps: fps, frames: Int(fps) * 2),
            Movie(fps: fps, frames: Int(fps) * 2, reorder: true),
            Movie(fps: fps, frames: Int(fps) * 2, codec: .hevc, reorder: true, firstPTS: CMTime(value: 1, timescale: 2)),
            Movie(fps: fps, frames: Int(fps) * 2, codec: .hevc, reorder: true,
                  transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(Movie.height), ty: 0)),
        ]
        // One file kind per rate (each kind passed at every rate once; all 16 took 11 minutes).
        let n = [24: 0, 25: 1, 30: 2, 60: 3][Int(fps)] ?? 0
        for movie in [all[n]] {
            let url = try await Self.write(movie)
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MagicMatteStore(directory: nil)
            let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
            let end = Double(movie.frames - 1) / Double(fps)
            let r = try await tracker.track(key: "k", points: Self.click(movie), from: 0, to: end, store: store)
            #expect(r.frames == movie.frames && !r.lost, "variant \(n): \(r.frames) frames")
            for (inFrame, speed, seq) in [(0, ClipSpeed.normal, Int64(fps)), (7, .normal, 30), (5, ClipSpeed(num: 3, den: 2), 25),
                                          (3, ClipSpeed(num: 1, den: 2), 60)] {
                for playing in [false, true] {
                    let m = try await Self.measure(movie, url: url, store: store, key: "k", inFrame: inFrame, speed: speed,
                                             sequenceFPS: seq, playing: playing)
                    let what = "\(playing ? "play" : "pause") fps \(fps) variant \(n) in \(inFrame) speed \(speed.num)/\(speed.den) seq \(seq)"
                    print("[MatteTiming] \(what): worst \(String(format: "%.2f", m.worst)) px, "
                          + "lead \(String(format: "%+.3f", m.lead)) frames over \(m.checked)")
                    #expect(m.checked > 10)
                    #expect(m.worst < 2, "\(what): \(m.worst) px")
                    #expect(abs(m.lead) < 0.25, "\(what): lead \(m.lead) frames")
                }
            }
        }
    }

    /// The paths the rate test leaves out: a track run backward (from the last frame to the first, the chunked reverse
    /// reader) and a reversed clip (the monitor's frame for a reversed timeline frame), at normal and changed speed.
    @Test func backwardTrackAndReversedClipsSitOnTheSubject() async throws {
        let movie = Movie(fps: 30, frames: 60, reorder: true)
        let url = try await Self.write(movie)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let end = Double(movie.frames - 1) / 30
        let last = Movie.center(movie.frames - 1)
        let click = [MagicPoint(position: Self.upright(last, movie.transform).0, subtract: false, sourceTime: .zero)]
        let r = try await tracker.track(key: "k", points: click, from: end, to: 0, store: store)
        #expect(r.frames == movie.frames && !r.lost, "backward: \(r.frames) frames")
        for (inFrame, speed, seq, reversed) in [(0, ClipSpeed.normal, Int64(30), false), (0, .normal, 30, true),
                                                (4, ClipSpeed(num: 3, den: 2), 25, true), (2, ClipSpeed(num: 1, den: 2), 60, true)] {
            for playing in [false, true] {
                let m = try await Self.measure(movie, url: url, store: store, key: "k", inFrame: inFrame, speed: speed,
                                               sequenceFPS: seq, playing: playing, reversed: reversed)
                let what = "\(playing ? "play" : "pause") backward track, in \(inFrame) speed \(speed.num)/\(speed.den) seq \(seq)\(reversed ? " reversed" : "")"
                print("[MatteTiming] \(what): worst \(String(format: "%.2f", m.worst)) px, lead \(String(format: "%+.3f", m.lead)) frames over \(m.checked)")
                #expect(m.checked > 10)
                #expect(m.worst < 2, "\(what): \(m.worst) px")
                #expect(abs(m.lead) < 0.25, "\(what): lead \(m.lead) frames")
            }
        }
    }

    /// The cause of the maintainer's report: overlays (the mask tint, the pick) look the matte up at the playhead's source time, not
    /// at a frame's pts. A 29.97 fps file on a 30 fps sequence puts that time in the later half of a frame now and then;
    /// the store took the nearest frame there, the matte of the NEXT frame, ahead of the picture by one frame. The store
    /// gives the frame shown at a time (pts <= t < next pts, `SampleIndex.frame(at:)`), as the monitor does.
    @Test func storeGivesTheFrameShownAtATimeNotTheNearest() throws {
        let store = MagicMatteStore(directory: nil)
        let frames = (0..<60).map { Time(Int64($0) * 1001, 30_000) }      // 29.97 fps
        for (i, t) in frames.enumerated() {
            var v = [Float](repeating: 0, count: 64 * 4)
            v[i] = 1                                                       // the matte names its frame
            store.put(SubjectMatte(width: 64, height: 4, values: v), key: "k", pts: Self.seconds(t))
        }
        let index = SampleIndex(entries: frames.enumerated().map {
            .init(pts: $0.element, dts: $0.element, duration: Time(1001, 30_000), isSync: true, decodeOrdinal: $0.offset)
        })
        var differ = 0
        for j in 0..<59 {
            let t = Time(Int64(j), 30)                                     // the playhead on a 30 fps sequence
            let shown = try #require(index.frame(at: t))
            for fills in [false, true] {
                let m = try #require(store.matte(key: "k", pts: Self.seconds(t), feather: 0, expansion: 0, frameWidth: 64, fills: fills))
                #expect(m.values.firstIndex { $0 > 0.5 } == shown, "playhead \(j)/30: matte of frame \(m.values.firstIndex { $0 > 0.5 } ?? -1), shown \(shown)")
            }
            let raw = try #require(store.matte(key: "k", pts: Self.seconds(t)))
            #expect(raw.values.firstIndex { $0 > 0.5 } == shown)
            let playing = try #require(store.preparedMatte(key: "k", pts: Self.seconds(t), feather: 0, expansion: 0, frameWidth: 64))
            #expect(playing.values.firstIndex { $0 > 0.5 } == shown)
            if abs(Self.seconds(t) - Self.seconds(frames[shown])) > Self.seconds(Time(1001, 60_000)) { differ += 1 }
        }
        #expect(differ > 0)                                                // the case is really in the run
        // A frame's own pts a hair below the stored one (Double rounding) is still that frame; before the first: none.
        #expect(store.matte(key: "k", pts: Self.seconds(frames[7]) - 1e-9)?.values.firstIndex { $0 > 0.5 } == 7)
        #expect(store.matte(key: "k", pts: -0.01) == nil)
        #expect(store.matte(key: "k", pts: Self.seconds(frames[59]) + 0.02)?.values.firstIndex { $0 > 0.5 } == 59)
        #expect(store.matte(key: "k", pts: Self.seconds(frames[59]) + 0.04) == nil)
    }

    /// The tracker's finishing queue (the edge step and store write of a frame while the model has the next one): jobs
    /// run in order, never more than `depth` wait, and `drain` returns only after all of them ran.
    @Test func finisherRunsFramesInOrderBoundedAndDrains() {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var state: (order: [Int], waiting: Int, most: Int) = ([], 0, 0)
            func with<R>(_ body: (inout (order: [Int], waiting: Int, most: Int)) -> R) -> R { lock.withLock { body(&state) } }
        }
        let finisher = MatteFinisher(depth: 2)
        let log = Log()
        for i in 0..<12 {
            log.with { $0.waiting += 1; $0.most = max($0.most, $0.waiting) }
            finisher.submit {
                Thread.sleep(forTimeInterval: 0.002)
                log.with { $0.order.append(i); $0.waiting -= 1 }
            }
        }
        finisher.drain()
        let seen = log.with { $0 }
        #expect(seen.order == Array(0..<12))
        // The job being submitted counts while it waits for room: at most depth waiting plus that one.
        #expect(seen.most <= 3 && seen.waiting == 0)
    }

    /// Real camera files (SQ_MATTE_TIMING_FILES, paths split by "|"): the times the tracker stores its mattes at are
    /// the monitor's frame times (`SampleIndex`), frame for frame, over the first seconds.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_MATTE_TIMING_FILES"] != nil))
    func trackerTimesAreTheMonitorsOnRealFiles() async throws {
        let list = try String(contentsOfFile: ProcessInfo.processInfo.environment["SQ_MATTE_TIMING_FILES"] ?? "", encoding: .utf8)
        let paths = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let index = try await AVDemuxer(url: url).index
            let shown = index.entries.filter { $0.duration > .zero }.map { Self.seconds($0.pts) }
            let times = Mutex<[Double]>([])
            try await FrameReader(url: url, maxDimension: 256).forEach(from: 0, to: 2) { _, pts in
                times.withLock { $0.append(pts) }; return true
            }
            let read = times.withLock { $0 }
            let n = min(read.count, shown.count)
            let offsets = (0..<n).map { read[$0] - shown[$0] }
            print("[MatteTiming] \(url.lastPathComponent): read \(read.count), index \(shown.count) (first \(shown.prefix(3))), "
                  + "reader first \(read.prefix(3)), offset min \(offsets.min() ?? 0) max \(offsets.max() ?? 0)")
            #expect(n > 10)
            #expect(offsets.allSatisfy { abs($0) < 1e-3 }, "\(url.lastPathComponent)")
        }
    }

    /// The tracking model (when its parts are there, SQ_SUBJECT_MASK_MODELS): the same check on its mattes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_MODELS"] != nil))
    func modelMatteSitsOnTheSubject() async throws {
        let models = try #require(ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_MODELS"])
        let engine = MaskBenchmarkTests.engine(models)
        for fps in [24, 30, 60] as [Int32] {
            let movie = Movie(fps: fps, frames: Int(fps) * 2, codec: .hevc, reorder: true)
            let url = try await Self.write(movie)
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MagicMatteStore(directory: nil)
            let tracker = SubjectMaskEngineTests.tracker(url, engine)
            let started = Date()
            let r = try await tracker.track(key: "k", points: Self.click(movie), from: 0, to: Double(movie.frames - 1) / Double(fps),
                                            store: store)
            let ms = Date().timeIntervalSince(started) * 1000 / Double(max(r.frames, 1))
            let m = try await Self.measure(movie, url: url, store: store, key: "k", inFrame: 0, speed: .normal, sequenceFPS: Int64(fps))
            print("[MatteTiming] model fps \(fps): \(r.frames) frames, \(String(format: "%.1f", ms)) ms/frame, "
                  + "worst \(String(format: "%.2f", m.worst)) px, lead \(String(format: "%+.3f", m.lead)) frames; "
                  + "\(SubjectMaskTiming.takeTimings())")
            #expect(m.worst < 3, "fps \(fps): \(m.worst) px")
            #expect(abs(m.lead) < 0.25, "fps \(fps): lead \(m.lead) frames")
        }
    }

    /// Where a track's time goes on real files (SQ_MATTE_PROFILE_FILES: a text file, one path per line; needs the
    /// model parts): 2 s from the start with a click in the middle, both edge qualities, ms per frame and per part.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_MATTE_PROFILE_FILES"] != nil
                   && ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_MODELS"] != nil))
    func profileTracksOnRealFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        let engine = MaskBenchmarkTests.engine(try #require(env["SQ_SUBJECT_MASK_MODELS"]))
        let list = try String(contentsOfFile: env["SQ_MATTE_PROFILE_FILES"] ?? "", encoding: .utf8)
        for path in list.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let url = URL(fileURLWithPath: path)
            for quality in [SubjectMaskQuality.quality, .speed] {
                var tracker = MagicMaskTracker(url: url, limits: .current, segmenter: VisionInstanceSegmenter(), engine: engine)
                tracker.decide(quality)
                let store = MagicMatteStore(directory: nil)
                _ = SubjectMaskTiming.takeTimings()
                let started = Date()
                let r = try await tracker.track(key: "k", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)],
                                                from: 0, to: 2, store: store)
                let ms = Date().timeIntervalSince(started) * 1000 / Double(max(r.frames + r.lostTimes.count, 1))
                print("[MatteProfile] \(url.lastPathComponent) \(quality.title) (\(tracker.quality.title)): "
                      + "\(r.frames) frames, \(String(format: "%.1f", ms)) ms/frame; \(SubjectMaskTiming.takeTimings())")
            }
        }
    }
}
}
