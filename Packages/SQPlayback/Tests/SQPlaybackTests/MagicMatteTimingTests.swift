import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
import SQAnalysis
import SQCore
import SQMedia
import SQMediaTestSupport

// Feedback 2026-10-19: a Magic mask on a person walking left to right ran AHEAD of him, and when he turned it moved on
// the wrong way. End to end: a stamped clip whose subject (a blob) walks right and turns back, tracked by the app's
// tracker (stamp -> blob position, so every matte says which picture it was made on), then looked up at the pts of
// every frame the playback decoder shows. Each lookup must show the blob of that very picture.

/// The blob's left edge (px of a 320 px frame) on the picture stamped `n`: right 4 px per frame, back from `turn` on.
private func blobX(_ n: Int, turn: Int) -> Int { n <= turn ? 40 + 4 * n : 40 + 4 * (2 * turn - n) }
private let blobWidth = 40

/// Reads the stamp, draws the blob of that picture as object 1.
private struct StampBlobSegmenter: InstanceSegmenting {
    let turn: Int
    func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
        guard let n = readStamp(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let s = Double(w) / 320
        var l = [UInt8](repeating: 0, count: w * h)
        let x0 = Int(Double(blobX(n, turn: turn)) * s), x1 = Int(Double(blobX(n, turn: turn) + blobWidth) * s)
        for y in Int(70 * s) ..< Int(110 * s) { for x in max(x0, 0) ..< min(x1, w) { l[y * w + x] = 1 } }
        return InstanceFrame(labels: InstanceLabels(width: w, height: h, labels: l))
    }
}

private func readStamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

private func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }

/// A small gray picture of a frame (for matching pictures of two decoders).
private func thumb(_ src: CVPixelBuffer, _ o: CGImagePropertyOrientation = .up) -> [Float] {
    let n = 32
    let img = CIImage(cvPixelBuffer: src).oriented(o)
    let e = img.extent
    let small = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .transformed(by: CGAffineTransform(scaleX: CGFloat(n) / e.width, y: CGFloat(n) / e.height))
    var bytes = [UInt8](repeating: 0, count: n * n * 4)
    CIContext().render(small, toBitmap: &bytes, rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                       format: .BGRA8, colorSpace: nil)
    return stride(from: 0, to: bytes.count, by: 4).map { Float(bytes[$0]) + Float(bytes[$0 + 1]) + Float(bytes[$0 + 2]) }
}

/// Records a thumbnail of every picture it is given; the subject is a fixed blob (always found).
private final class RecordingSegmenter: InstanceSegmenting, @unchecked Sendable {
    let thumbs = NSLock()
    var pictures: [[Float]] = []
    var info = ""
    func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
        let t = thumb(pb)
        info = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) \(CVPixelBufferGetPixelFormatType(pb))"
        thumbs.withLock { pictures.append(t) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var l = [UInt8](repeating: 0, count: w * h)
        for y in h / 3 ..< 2 * h / 3 { for x in w / 3 ..< 2 * w / 3 { l[y * w + x] = 1 } }
        return InstanceFrame(labels: InstanceLabels(width: w, height: h, labels: l))
    }
}

/// Opt-in measurement on real footage: `SQ_MASK_TIMING_FILE=<movie> SQ_MASK_TIMING_FROM=<s> SQ_MASK_TIMING_TO=<s>`.
/// Prints, per playback frame, which tracked picture (by its stored pts) looks like it: offset 0 = the matte of that
/// frame was made on that very picture.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SQ_MASK_TIMING_FILE"] != nil)) struct MagicMatteTimingFileTests {
    @Test func trackedPicturesMatchPlaybackPictures() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["SQ_MASK_TIMING_FILE"]))
        let from = Double(env["SQ_MASK_TIMING_FROM"] ?? "") ?? 0, to = Double(env["SQ_MASK_TIMING_TO"] ?? "") ?? 1
        let d = try await AVDemuxer(url: url)
        let dec = try VTVideoDecoder(demuxer: d, media: UUID(), scale: .full)
        let idx = d.index.entries.indices.filter { seconds(d.index.entries[$0].pts) >= from - 1e-6 && seconds(d.index.entries[$0].pts) <= to }
        let lo = try #require(idx.first), hi = try #require(idx.last)
        let decoded = try await dec.decode(lo...hi)
        if let f = decoded.first { print("[MatteTiming] playback buffer \(CVPixelBufferGetWidth(f.pixelBuffer))x\(CVPixelBufferGetHeight(f.pixelBuffer)) \(CVPixelBufferGetPixelFormatType(f.pixelBuffer))") }
        let rec = RecordingSegmenter()
        let store = MagicMatteStore(directory: nil)
        let points = [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: Time(Int64((from * 600).rounded()), 600))]
        _ = try await MagicMaskTracker(url: url, segmenter: rec).track(key: "k", points: points, from: from, to: to, store: store)
        let times = store.times(key: "k")
        func diff(_ a: [Float], _ b: [Float]) -> Float {
            let ma = a.reduce(0, +) / Float(max(a.count, 1)), mb = b.reduce(0, +) / Float(max(b.count, 1))
            return zip(a, b).reduce(0) { $0 + abs(($1.0 - ma) - ($1.1 - mb)) } / Float(max(a.count, 1))
        }
        // Which turn of the decoded picture the tracker saw (its pictures are upright).
        let k0 = try #require(times.lastIndex { $0 <= seconds(decoded[0].pts) + 1e-6 })
        let turns: [(CGImagePropertyOrientation, String)] = [(.up, "up"), (.right, "right"), (.down, "down"), (.left, "left"),
                                                            (.upMirrored, "upMirrored"), (.rightMirrored, "rightMirrored"),
                                                            (.downMirrored, "downMirrored"), (.leftMirrored, "leftMirrored")]
        let scored = turns.map { (o: $0.0, name: $0.1, d: diff(thumb(decoded[0].pixelBuffer, $0.0), rec.pictures[k0])) }
        print("[MatteTiming] orientation diffs: \(scored.map { "\($0.name) \($0.d)" })")
        let o = scored.min { $0.d < $1.d }!.o
        let shown = decoded.map { (pts: seconds($0.pts), thumb: thumb($0.pixelBuffer, o)) }
        print("[MatteTiming] tracker buffer \(rec.info)")
        print("[MatteTiming] playback \(shown.count) frames \(shown.first?.pts ?? -1)...\(shown.last?.pts ?? -1), tracked \(times.count) (\(rec.pictures.count) pictures) \(times.first ?? -1)...\(times.last ?? -1)")
        #expect(times.count == rec.pictures.count)
        var offsets: [Int: Int] = [:]
        for s in shown {
            // The tracked picture whose pts the store's floor rule draws at this playback pts.
            guard let k = times.lastIndex(where: { $0 <= s.pts + 1e-6 }) else { continue }
            let near = (max(k - 3, 0)...min(k + 3, times.count - 1)).map { (j: $0 - k, d: diff(s.thumb, rec.pictures[$0])) }
            let best = near.min { $0.d < $1.d }!
            offsets[best.j, default: 0] += 1
            print(String(format: "[MatteTiming] shown %.4f -> stored %.4f, best picture offset %+d (diff own %.2f best %.2f)",
                         s.pts, times[k], best.j, near.first { $0.j == 0 }?.d ?? -1, best.d))
        }
        print("[MatteTiming] offsets (stored picture index - drawn index): \(offsets.sorted { $0.key < $1.key })")
    }
}

@Suite(.serialized) struct MagicMatteTimingTests {
    struct Case: CustomStringConvertible, Sendable {
        var name: String
        var spec: TestClipSpec
        /// Wrap the clip in a movie whose edit list shows its media from the start offset at time 0 (cameras and
        /// ffmpeg write this for B-frame streams: elst media time = the reorder delay).
        var edit: CMTime?
        var description: String { name }
    }

    static let cases: [Case] = {
        var c30 = TestClipSpec(); c30.frameCount = 60
        var c60 = TestClipSpec(); c60.frameCount = 60; c60.frameDuration = TestClipSpec.fps(60)
        var off = TestClipSpec(); off.frameCount = 60; off.startOffset = CMTime(value: 1, timescale: 10)
        var off60 = c60; off60.startOffset = CMTime(value: 1, timescale: 10)
        var ntsc = TestClipSpec(); ntsc.frameCount = 60; ntsc.frameDuration = TestClipSpec.fps(30000, 1001)
        var hevc = c60; hevc.codec = .hevcMain10
        let oneFrame = TestClipSpec.fps(30000, 1001)
        var vfr = TestClipSpec(); vfr.frameCount = 60
        var t = 0, times: [CMTime] = []
        for i in 0..<60 { times.append(CMTime(value: CMTimeValue(t), timescale: 600)); t += i % 3 == 0 ? 30 : 15 }
        vfr.presentationTimes = times
        return [Case(name: "30 fps", spec: c30), Case(name: "60 fps", spec: c60), Case(name: "30 fps start 0.1 s", spec: off),
                Case(name: "60 fps start 0.1 s", spec: off60), Case(name: "29.97 fps", spec: ntsc),
                Case(name: "60 fps HEVC", spec: hevc), Case(name: "VFR", spec: vfr),
                Case(name: "30 fps edit list from 0.1 s", spec: c30, edit: CMTime(value: 1, timescale: 10)),
                Case(name: "29.97 fps edit list from one frame", spec: ntsc, edit: oneFrame)]
    }()

    /// `url`'s frames remuxed so their media starts `offset` late (pts = dts + offset), shown from time 0 by the edit
    /// list: what cameras and ffmpeg write for B-frame streams (elst media time = the reorder delay).
    static func editListed(_ url: URL, offset: CMTime) async throws -> URL {
        let source = AVURLAsset(url: url)
        let track = try #require(try await source.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let out = url.deletingLastPathComponent().appendingPathComponent("edit.mov")
        let reader = try AVAssetReader(asset: source)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        // Passthrough with the session starting at `offset`: the writer maps media `offset` to time 0 (elst).
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: offset)
        while let s = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
            var timing = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(s, at: 0, timingInfoOut: &timing)
            if !timing.decodeTimeStamp.isNumeric { timing.decodeTimeStamp = timing.presentationTimeStamp }
            // Decode times stay: the composition offset (ctts) carries the delay, as in a B-frame stream.
            timing.presentationTimeStamp = timing.presentationTimeStamp + offset
            var copy: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: s, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &copy)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            #expect(input.append(try #require(copy)), "append \(String(describing: writer.error))")
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        let check = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let segs = try await check.load(.segments).filter { !$0.isEmpty }
        #expect(segs.count == 1 && segs[0].timeMapping.target.start == .zero && abs(segs[0].timeMapping.source.start.seconds - offset.seconds) < 1e-4,
                "edit list \(segs.map { ($0.timeMapping.source.start.value, $0.timeMapping.source.start.timescale) }) \(segs.map { ($0.timeMapping.source.start.seconds, $0.timeMapping.target.start.seconds) })")
        return out
    }

    /// Every frame the decoder shows: its pts and its stamp.
    static func shown(_ url: URL) async throws -> [(pts: Time, stamp: Int)] {
        let d = try await AVDemuxer(url: url)
        let dec = try VTVideoDecoder(demuxer: d, media: UUID())
        let frames = try await dec.decode(0...(d.index.count - 1))
        return frames.compactMap { f in readStamp(f.pixelBuffer).map { (f.pts, $0) } }
    }

    /// The tracked matte at each shown frame against that frame's own blob: (frame pts, stamp, error in px).
    static func errors(_ store: MagicMatteStore, key: String, _ shown: [(pts: Time, stamp: Int)], turn: Int,
                       fills: Bool) -> [(Double, Int, Double)] {
        shown.compactMap { f in
            let p = seconds(f.pts)
            let m = fills ? store.matte(key: key, pts: p, feather: 0, expansion: 0, frameWidth: 320, fills: true)
                          : store.matte(key: key, pts: p)
            guard let m, let c = m.centroid else { return (p, f.stamp, .infinity) }
            let x = c.x / Double(m.width) * 320
            return (p, f.stamp, x - Double(blobX(f.stamp, turn: turn) + blobWidth / 2))
        }
    }

    @Test(arguments: cases) func trackedMatteShowsTheShownPicturesBlob(_ c: Case) async throws {
        let written = try await TestClipWriter.write(c.spec)
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }
        let url = if let e = c.edit { try await Self.editListed(written, offset: e) } else { written }
        let turn = 30
        let shown = try await Self.shown(url)
        #expect(shown.count >= 59, "\(c): decoded \(shown.count)")
        let tracker = MagicMaskTracker(url: url, segmenter: StampBlobSegmenter(turn: turn))
        let first = try #require(shown.first), mid = shown[shown.count / 2], last = try #require(shown.last)
        func click(_ f: (pts: Time, stamp: Int)) -> [MagicPoint] {
            [MagicPoint(position: Vec2((Double(blobX(f.stamp, turn: turn)) + 20) / 320, 90.0 / 180), subtract: false, sourceTime: f.pts)]
        }
        // Forward from the first frame, and a pick in the middle tracked both ways (the app's pick).
        let store = MagicMatteStore(directory: nil)
        _ = try await tracker.track(key: "f", points: click(first), from: seconds(first.pts), to: seconds(last.pts), store: store)
        _ = try await tracker.track(key: "m", points: click(mid), from: seconds(mid.pts), to: seconds(last.pts), store: store)
        _ = try await tracker.track(key: "m", points: click(mid), from: seconds(mid.pts), to: 0, store: store)
        for key in ["f", "m"] {
            for fills in [false, true] {
                let bad = Self.errors(store, key: key, shown, turn: turn, fills: fills).filter { abs($0.2) > 1.5 }
                #expect(bad.isEmpty, "\(c) key \(key) fills \(fills): \(bad.prefix(8).map { String(format: "%.4f s #%d %+.1f px", $0.0, $0.1, $0.2) })")
            }
        }
    }
}
