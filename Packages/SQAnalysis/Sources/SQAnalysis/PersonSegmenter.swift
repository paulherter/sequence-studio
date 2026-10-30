import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQCore
import Synchronization
import Vision

/// W9.8 SubjectMask: Vision person segmentation into `SubjectMatte`s (0 background ... 1 person, row 0 at the top, covering
/// the whole picture). The matte is laid over the clip's own upright frame, so pass the orientation of a decoded buffer
/// that is stored turned (`orientation(quarterTurns:)`): Vision then returns the mask upright.
public enum PersonSegmenter {
    public enum Quality: Sendable {
        /// Real-time playback/scrub.
        case fast
        /// Paused frames.
        case balanced
        /// Export.
        case accurate

        var vision: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .fast: .fast
            case .balanced: .balanced
            case .accurate: .accurate
            }
        }
    }

    /// The orientation of a buffer whose picture is shown turned clockwise by `quarterTurns` quarter turns (the compositor's
    /// `quarter`, from the track's preferred transform).
    public static func orientation(quarterTurns: Int) -> CGImagePropertyOrientation {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }

    // shortcut: the synchronous entry points below (and `SubjectMatteTracker.matte(for:)`) take no lane: Vision blocks the
    // calling thread. Every caller runs on a thread of its own (`SubjectMatteScheduler`'s queue, the precompute's frame lane
    // via `FrameReader.work`, one-off tools); none may call them from the cooperative pool. Upgrade to an async variant on
    // `BlockingLane` when a caller on the pool appears.
    /// The person matte of one picture (already upright); nil when Vision returns no mask.
    public static func matte(in image: CGImage, quality: Quality = .balanced) throws -> SubjectMatte? {
        let r = makeRequest(quality)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([r])
        return r.results?.first.flatMap { matte(from: $0.pixelBuffer) }
    }

    /// The person matte of one decoded frame (any format Vision reads), upright for `orientation`. One-off; a clip being
    /// played goes through `SubjectMatteTracker`, which reuses its request and sequence handler.
    public static func matte(in frame: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                             quality: Quality = .balanced) throws -> SubjectMatte? {
        let r = makeRequest(quality)
        try VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation, options: [:]).perform([r])
        return r.results?.first.flatMap { matte(from: $0.pixelBuffer) }
    }

    static func makeRequest(_ q: Quality) -> VNGeneratePersonSegmentationRequest {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = q.vision
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }

    /// A one-channel mask buffer (8-bit, 16-bit half or 32-bit float) as a matte, clamped to 0...1; nil for other formats.
    public static func matte(from buffer: CVPixelBuffer) -> SubjectMatte? {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 || format == kCVPixelFormatType_OneComponent16Half
                || format == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var v = [Float](repeating: 0, count: w * h)
        v.withUnsafeMutableBytes { dst in
            var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
            var out = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                    rowBytes: w * MemoryLayout<Float>.stride)
            switch format {
            case kCVPixelFormatType_OneComponent8:
                _ = vImageConvert_Planar8toPlanarF(&src, &out, 1, 0, vImage_Flags(kvImageNoFlags))
            case kCVPixelFormatType_OneComponent16Half:
                _ = vImageConvert_Planar16FtoPlanarF(&src, &out, vImage_Flags(kvImageNoFlags))
            default:
                _ = vImageCopyBuffer(&src, &out, MemoryLayout<Float>.stride, vImage_Flags(kvImageNoFlags))
            }
        }
        if format != kCVPixelFormatType_OneComponent8 { vDSP.clip(v, to: 0...1, result: &v) }
        return SubjectMatte(width: w, height: h, values: v)
    }
}

/// Segments and temporally smooths the frames of several clips, so edges do not flicker during playback. Each key (e.g. a
/// clip id) has its own Vision request, sequence handler and `SubjectMatteSmoother` behind its own lock: different clips
/// segment in parallel, the shared table is only locked to find a clip's state. Frame indices are the clip's source frames;
/// a frame already done (paused redraw) comes from the cache without running Vision. Use one tracker per quality (e.g. a
/// separate one for export), since cached frames are reused whatever quality is asked for.
public final class SubjectMatteTracker: Sendable {
    /// One clip's segmentation state. Vision's request and handler are not thread-safe: only touched under `lock`.
    private final class ClipState: @unchecked Sendable {
        let lock = NSLock()
        var smoother: SubjectMatteSmoother
        init(capacity: Int) { smoother = SubjectMatteSmoother(capacity: capacity) }
        var request: VNGeneratePersonSegmentationRequest?
        var quality: PersonSegmenter.Quality?
        let handler = VNSequenceRequestHandler()
    }

    private let clips = Mutex<[UUID: ClipState]>([:])
    /// Smoothed results kept per clip (the smoother needs the neighbor frame; more = cheaper paused redraws and reverse).
    public let capacity: Int

    public init(capacity: Int = 8) { self.capacity = max(2, capacity) }

    /// Clips with segmentation state (tests: released state).
    public var keys: Set<UUID> { clips.withLock { Set($0.keys) } }

    private func state(_ key: UUID) -> ClipState {
        clips.withLock { all in
            if let s = all[key] { return s }
            let s = ClipState(capacity: capacity)
            all[key] = s
            return s
        }
    }

    /// The smoothed matte of `frameIndex` if it was already made.
    public func cached(key: UUID, frameIndex: Int) -> SubjectMatte? {
        guard let s = clips.withLock({ $0[key] }) else { return nil }
        s.lock.lock(); defer { s.lock.unlock() }
        return s.smoother.cached(frameIndex: frameIndex)
    }

    /// Smooths an already segmented matte.
    public func smoothed(_ raw: SubjectMatte, key: UUID, frameIndex: Int) -> SubjectMatte {
        let s = state(key)
        s.lock.lock(); defer { s.lock.unlock() }
        return s.smoother.push(raw, frameIndex: frameIndex)
    }

    /// Segments `frame` (shown upright through `orientation`) and smooths it; nil when Vision returns no mask.
    public func matte(for frame: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, key: UUID, frameIndex: Int,
                      quality: PersonSegmenter.Quality = .fast) throws -> SubjectMatte? {
        let s = state(key)
        s.lock.lock(); defer { s.lock.unlock() }
        if let done = s.smoother.cached(frameIndex: frameIndex) { return done }
        if s.request == nil || s.quality != quality {
            s.request = PersonSegmenter.makeRequest(quality)
            s.quality = quality
        }
        let r = s.request!
        try s.handler.perform([r], on: frame, orientation: orientation)
        guard let raw = r.results?.first.flatMap({ PersonSegmenter.matte(from: $0.pixelBuffer) }) else { return nil }
        return s.smoother.push(raw, frameIndex: frameIndex)
    }

    /// Forgets one clip's history (clip removed, source changed).
    public func reset(key: UUID) { _ = clips.withLock { $0.removeValue(forKey: key) } }

    /// Forgets everything (project closed).
    public func resetAll() { clips.withLock { $0.removeAll() } }

    /// The smoothed matte of a decoded frame for `RenderLayer.subjectMatte`: `rotationDegrees` is the frame's color-hint
    /// rotation (the compositor turns the picture by it), so the matte comes back upright like the drawn layer. Vision
    /// errors and frames without a mask give nil (a subject mask then shows no person).
    public func layerMatte(for frame: CVPixelBuffer, rotationDegrees: Int, key: UUID, frameIndex: Int,
                           quality: PersonSegmenter.Quality) -> SubjectMatte? {
        let o = PersonSegmenter.orientation(quarterTurns: rotationDegrees / 90)
        return try? matte(for: frame, orientation: o, key: key, frameIndex: frameIndex, quality: quality)
    }
}
