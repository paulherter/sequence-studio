import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SQCore
import SQMedia
import Synchronization
import Vision

/// Faces, bodies and attention saliency of a media file's frames via Vision. Frames are read upright (preferred track
/// transform applied) and small (analysis needs no full resolution), so box coordinates match `pictureSize(of:)`.
public struct VisionSubjectDetector: SubjectDetecting {
    private let asset: AVURLAsset
    private let url: URL
    private let maxDimension: Int
    private let deinterlace: FieldOrder?
    private let pixelAspect: PixelAspect?
    private let session = Session()

    /// What every deinterlaced frame of this detector needs of the file, loaded with the first: a Reframe analysis
    /// asks one detector for hundreds of frames.
    private final class Session: Sendable {
        let opened = Mutex<(plan: FrameReader.Plan, shape: PixelAspect)?>(nil)
    }

    /// How far from the asked time a frame may lie, in seconds (the tolerance the image generator gets).
    static let window = 0.05

    /// `maxDimension`: longest side of the analyzed frame in pixels. `deinterlace`: the media item's
    /// `VideoTrackInfo.deinterlaceFieldOrder`; such a frame is read at the stored size and deinterlaced before it is
    /// shrunk (nil = the image generator's frame, as stored). `pixelAspect`: the item's `displayPixelAspect`, the
    /// shape a deinterlaced frame is analyzed in (nil = the file's own tag, which the image generator applies too).
    public init(url: URL, maxDimension: Int = 640, deinterlace: FieldOrder? = nil, pixelAspect: PixelAspect? = nil) {
        asset = AVURLAsset(url: url)
        self.url = url
        self.maxDimension = maxDimension
        self.deinterlace = deinterlace
        self.pixelAspect = pixelAspect
    }

    /// Tests: runs on the thread that is about to make the Vision requests of `subjects`.
    @TaskLocal static var onDetect: (@Sendable () -> Void)?

    /// The Vision requests of one frame block: they run on the frame lane (`FrameReader.lane`, where the deinterlaced
    /// frame is read too), never on the cooperative pool, and ahead of waiting long reads. Not on the analysis lane: a
    /// whole Stabilizer analysis holds a slot of it for minutes. A request canceled before its turn is not made.
    private func onLane(_ body: @escaping () throws -> [SubjectBox]) async throws -> [SubjectBox] {
        let hook = Self.onDetect
        return try await FrameReader(url: url, maxDimension: maxDimension).work(urgent: true) { hook?(); return try body() }
    }

    /// A reader of deinterlaced frames as they are shown, and the file's plan. The plan (asset, track, sizes) is loaded
    /// once per detector; the reader is new per call (its stop belongs to one request).
    private func reader() async throws -> (FrameReader, FrameReader.Plan) {
        var reader = FrameReader(url: url, maxDimension: maxDimension, deinterlace: deinterlace)
        if let o = session.opened.withLock({ $0 }) {
            reader.pixelAspect = o.shape
            return (reader, o.plan)
        }
        let plan = try await reader.plan()
        var shape = pixelAspect
        if shape == nil { shape = try await plan.track.load(.formatDescriptions).first.map { PixelAspectTag.pixelAspect(of: $0) } }
        let opened = (plan: plan, shape: shape ?? .square)
        session.opened.withLock { $0 = opened }
        reader.pixelAspect = opened.shape
        return (reader, plan)
    }

    /// What `body` makes of the deinterlaced, upright, shrunk frame nearest to `seconds` (at most `window` away), with
    /// that frame's pts; nil when the reader finds none there. Read and `body` (Vision) are one job on the frame lane.
    private func onProgressiveFrame<T: Sendable>(near seconds: Double,
                                                 _ body: @escaping (CVPixelBuffer, Double) throws -> T) async throws -> T? {
        let (reader, plan) = try await reader()
        let hooks = FrameReader.Hooks.current
        return try await reader.work(urgent: true) {
            guard let (pb, pts) = try reader.nearest(plan, to: seconds, within: Self.window, hooks: hooks) else { return nil }
            try reader.stop.check()
            return try body(pb, pts)
        }
    }

    /// Tests: size and pts of the frame `subjects` looks at, and what `probe` reads from it.
    func progressiveFrame<T: Sendable>(near seconds: Double,
                                       _ probe: @escaping (CVPixelBuffer) -> T) async throws -> (width: Int, height: Int, pts: Double, probe: T)? {
        try await onProgressiveFrame(near: seconds) { pb, pts in
            (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), pts, probe(pb))
        }
    }

    public func subjects(atSourceTime t: Time) async throws -> [SubjectBox] {
        if WebMFile.isWebM(url) {   // AVFoundation cannot open WebM: the frame comes from the WebM decoder
            let image = try await WebMStill.cgImage(url: url, time: CMTime(value: t.value, timescale: CMTimeScale(clamping: t.timescale)),
                                                    height: maxDimension, exact: false)
            return try await onLane { try Self.detect(in: image) }
        }
        if deinterlace != nil {
            let hook = Self.onDetect
            let found = try await onProgressiveFrame(near: Double(t.value) / Double(max(t.timescale, 1))) { pb, _ in
                hook?()
                return try Self.detect(with: VNImageRequestHandler(cvPixelBuffer: pb, options: [:]))
            }
            if let found { return found }
        }
        // One generator per call: it is not Sendable, the asset is.
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // A few frames off is invisible after smoothing and much faster than exact seeking.
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
        let time = CMTime(value: t.value, timescale: CMTimeScale(clamping: t.timescale))
        let image = try await g.image(at: time).image
        return try await onLane { try Self.detect(in: image) }
    }

    /// Runs the three requests on one picture. Vision's boxes are normalized with the origin bottom-left; flipped here.
    static func detect(in image: CGImage) throws -> [SubjectBox] {
        try detect(with: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    static func detect(with handler: VNImageRequestHandler) throws -> [SubjectBox] {
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try handler.perform([faces, bodies, saliency])
        func rect(_ r: CGRect) -> NormalizedRect {
            NormalizedRect(x: Double(r.minX), y: 1 - Double(r.maxY), width: Double(r.width), height: Double(r.height))
        }
        var out: [SubjectBox] = []
        for f in faces.results ?? [] { out.append(SubjectBox(kind: .face, rect: rect(f.boundingBox), confidence: Double(f.confidence))) }
        for b in bodies.results ?? [] { out.append(SubjectBox(kind: .body, rect: rect(b.boundingBox), confidence: Double(b.confidence))) }
        for o in saliency.results?.first?.salientObjects ?? [] {
            out.append(SubjectBox(kind: .saliency, rect: rect(o.boundingBox), confidence: Double(o.confidence)))
        }
        return out
    }
}
