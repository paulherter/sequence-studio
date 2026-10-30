import Foundation
import SQAnalysis
import SQCore
import SQDrawKit
import SQMediaFFmpeg
import SQOnnx
import Synchronization

/// The Magic mask's segmenter on Windows (the Windows port plan "Magic Mask"): EdgeTAM as five ONNX parts on ONNX Runtime with
/// the DirectML provider (`EdgeTAMOnnxModel`), the frames from FFmpeg, the mattes into `FrameMatteStore`. Everything here runs
/// off the main thread; the model loads on first use (seconds: DirectML compiles the five graphs).
/// Frames are turned upright by the file's rotation tag (`SubjectFrame.upright`) like the Mac analysis frames, so a click
/// (a fraction of the upright picture) and the stored mattes need no rotation anywhere else.
/// shortcut: frames keep the file's pixel shape (no pixel-aspect squeeze); upgrade when anamorphic clips matter.
final class WinMagicEngine: @unchecked Sendable {
    static let shared = WinMagicEngine()

    /// The matte's width in px (its height follows the frame): the model answers 256 x 256 logits, so more would only
    /// be the resample. shortcut: one fixed size; derive it from the longest side when 4K mattes are wanted.
    static let matteWidth = 512

    struct Failure: Error, CustomStringConvertible { var description: String }

    private let lock = NSLock()
    private var loaded: EdgeTAMOnnxModel?
    private var sources: [String: WinMediaSource] = [:]
    let store: FrameMatteStore

    init(store: FrameMatteStore = .shared) { self.store = store }

    /// Where the models are, nil when they are not installed (the Magic button then says how).
    var modelsFolder: URL? { EdgeTAMOnnxLocation.find() }

    func model() throws -> EdgeTAMOnnxModel {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard let dir = EdgeTAMOnnxLocation.find() else {
            throw Failure(description: "Magic Mask needs its model files: run scripts/get-subject-mask-models.sh --onnx or put the edgetam_*.onnx files in "
                          + "%LOCALAPPDATA%\\SequenceStudio\\SubjectMask.")
        }
        let m: EdgeTAMOnnxModel
        do { m = try EdgeTAMOnnxModel(directory: dir, directML: ProcessInfo.processInfo.environment["SQ_ONNX_CPU"] == nil) }
        catch { throw Failure(description: "Magic Mask could not start its model: \(error)") }
        loaded = m
        return m
    }

    func source(path: String, media: UUID) throws -> WinMediaSource {
        lock.lock(); defer { lock.unlock() }
        if let s = sources[path] { return s }
        let s = try WinMediaSource(path: path, media: media)
        if sources.count > 3 { sources = [:] }
        sources[path] = s
        return s
    }

    // MARK: Frames

    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }

    /// The presentation index of the frame nearest to source `seconds`.
    static func index(_ src: WinMediaSource, seconds s: Double) -> Int {
        let e = src.demuxer.index.entries
        guard !e.isEmpty else { return 0 }
        var lo = 0, hi = e.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if seconds(e[mid].pts) < s - 1e-6 { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(seconds(e[lo - 1].pts) - s) < abs(seconds(e[lo].pts) - s) { lo -= 1 }
        return lo
    }

    static func time(_ src: WinMediaSource, index i: Int) -> Double { seconds(src.demuxer.index.entries[i].pts) }

    /// Frames shrunk to about 1280 px wide at most (the model sees 1024 x 1024 anyway).
    static func divisor(_ src: WinMediaSource) -> Int { src.info.width > 2600 ? 4 : (src.info.width > 1400 ? 2 : 1) }

    /// The frames `range`, in index order, as RGBA.
    static func frames(_ src: WinMediaSource, _ range: ClosedRange<Int>) async throws -> [(index: Int, frame: SubjectFrame)] {
        let pictures = try await WinMediaSource.decodePictures(src.decoder, range, divisor: divisor(src))
        return pictures.map { i, p in
            let e = p.eightBit
            let img = RGBAImage(nv12: e.bytes, width: e.width, height: e.height, fullRange: e.fullRange)
            return (i, SubjectFrame(width: img.width, height: img.height, rgba: img.pixels).upright(rotation: src.info.rotation))
        }
    }

    static func matte(_ answer: EdgeTAMAnswer, frame: SubjectFrame) -> SubjectMatte? {
        let w = min(matteWidth, frame.width), h = max(1, Int((Double(w) * Double(frame.height) / Double(frame.width)).rounded()))
        let m = SubjectTrackRules.matte(logits: answer.logits, size: SubjectTrackRules.logitSize, width: w, height: h)
        return m.isBlank ? nil : m
    }

    // MARK: Pick

    /// The matte of the clicks (all on the frame at `at` source seconds), stored under `key`; nil: nothing there.
    func pick(path: String, media: UUID, key: String, points: [MagicPoint], at seconds: Double) async throws -> SubjectMatte? {
        let src = try source(path: path, media: media)
        let i = Self.index(src, seconds: seconds)
        guard let f = try await Self.frames(src, i...i).first?.frame else { throw Failure(description: "the frame could not be read") }
        let session = try model().makeSession()
        let answer = try session.pick(f, points: points.map { ($0.position, $0.subtract) })
        guard answer.score > 0, let matte = Self.matte(answer, frame: f) else { return nil }
        store.put(key: key, pts: Self.time(src, index: i), matte: matte)
        store.saveLater(key: key)
        return matte
    }

    /// The matte of the object under `point` on the frame at `seconds`, not stored (the hover highlight); nil: nothing there.
    func hover(path: String, media: UUID, point: Vec2, at seconds: Double) async throws -> SubjectMatte? {
        let src = try source(path: path, media: media)
        let i = Self.index(src, seconds: seconds)
        guard let f = try await Self.frames(src, i...i).first?.frame else { return nil }
        let answer = try model().makeSession().click(f, point: point, box: nil)
        return answer.score > 0 ? Self.matte(answer, frame: f) : nil
    }

    /// A correction on a tracked frame (a click on another frame than the pick's): the matte stored under `oldKey` at
    /// source second `seconds` gains the object under `point` (`subtract`: loses it), stored under `key`; the tracked
    /// frames of `oldKey` before the correction (`keepBefore`: those earlier than it, else later) are copied along.
    /// nil: nothing was there to correct or nothing would be left.
    /// shortcut: the correction is the object under the click, added to or cut out of the tracked matte (no mask-prompted
    /// decoder pass); upgrade when parts of objects must be corrected.
    func correct(path: String, media: UUID, key: String, oldKey: String, point: Vec2, subtract: Bool, at seconds: Double,
                 keepBefore: Bool) async throws -> SubjectMatte? {
        let src = try source(path: path, media: media)
        let i = Self.index(src, seconds: seconds), pts = Self.time(src, index: i)
        guard let before = store.matte(key: oldKey, pts: pts) else { return nil }
        guard let f = try await Self.frames(src, i...i).first?.frame else { throw Failure(description: "the frame could not be read") }
        let answer = try model().makeSession().pick(f, points: [(point, false)])
        guard answer.score > 0, let object = Self.matte(answer, frame: f), object.width == before.width, object.height == before.height
        else { return nil }
        var values = before.values
        for n in values.indices { values[n] = subtract ? values[n] * (1 - object.values[n]) : max(values[n], object.values[n]) }
        let out = SubjectMatte(width: before.width, height: before.height, values: values)
        guard !out.isBlank else { return nil }
        store.copyFrames(from: oldKey, to: key) { keepBefore ? $0 < pts - 1e-6 : $0 > pts + 1e-6 }
        store.put(key: key, pts: pts, matte: out)
        store.saveLater(key: key)
        return out
    }

    // MARK: Track

    struct Tracked { var frames = 0; var lost = false }

    /// Follows the pick `key` from source second `from` to `to` (either order), storing a matte per frame. Starts from the
    /// matte stored at `from`. Stops at the first frame the object is not on (`lost`), on cancellation (frames done are
    /// kept) or when `keep` turns false. `progress`: 0...1.
    func track(path: String, media: UUID, key: String, from: Double, to: Double,
               keep: @Sendable () -> Bool = { true }, progress: @Sendable (Double) -> Void = { _ in }) async throws -> Tracked {
        let src = try source(path: path, media: media)
        let a = Self.index(src, seconds: from), b = Self.index(src, seconds: to)
        var out = Tracked()
        defer { if out.frames > 0 { store.saveLater(key: key) } }
        guard a != b, let seed = store.matte(key: key, pts: Self.time(src, index: a)) else { return out }
        let step = b > a ? 1 : -1
        let session = try model().makeSession()
        guard let first = try await Self.frames(src, a...a).first?.frame else { throw Failure(description: "the frame could not be read") }
        try session.condition(first, matte: seed)
        var i = a + step
        let chunk = 8
        while step > 0 ? i <= b : i >= b {
            try Task.checkCancellation()
            let end = step > 0 ? min(i + chunk - 1, b) : max(i - chunk + 1, b)
            let got = try await Self.frames(src, min(i, end)...max(i, end))
            for item in step > 0 ? got : got.reversed() {
                try Task.checkCancellation()
                guard keep() else { return out }
                let answer = try session.track(item.frame)
                guard answer.score > 0, let matte = Self.matte(answer, frame: item.frame) else { out.lost = true; return out }
                store.put(key: key, pts: Self.time(src, index: item.index), matte: matte)
                try session.commit()
                out.frames += 1
                progress(Double(abs(item.index - a)) / Double(abs(b - a)))
            }
            i = end + step
        }
        return out
    }
}
