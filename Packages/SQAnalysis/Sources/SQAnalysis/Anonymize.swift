import CoreVideo
import Foundation
import SQCore
import Synchronization
import Vision

// F7.11 Anonymize: finds the people on a frame (Vision face and body boxes matched to the Magic segmentation's objects)
// and follows each with the Magic mask tracker, narrowing the matte to the face or the skin where asked. No second
// tracker: the mattes land in the Magic matte store under the mask's own key.

/// Face and body boxes of one upright frame.
public protocol PersonDetecting: Sendable {
    /// `bodies` false: faces only (what the per-frame refinement needs).
    func detect(_ frame: CVPixelBuffer, bodies: Bool) throws -> (bodies: [AnonymizeBox], faces: [AnonymizeFace])
}

public struct VisionPersonDetector: PersonDetecting {
    public init() {}

    public func detect(_ frame: CVPixelBuffer, bodies wantBodies: Bool) throws -> (bodies: [AnonymizeBox], faces: [AnonymizeFace]) {
        let (faces, humans) = try VisionInstanceSegmenter.compute.run { cpu in
            let faces = VNDetectFaceRectanglesRequest()
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            let requests: [VNRequest] = wantBodies ? [faces, humans] : [faces]
            if cpu { requests.forEach { VisionInstanceSegmenter.useCPU($0) } }
            try VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:]).perform(requests)
            return (faces, humans)
        }
        // Vision's boxes are normalized with the origin bottom left; flipped here.
        func box(_ r: CGRect) -> AnonymizeBox {
            AnonymizeBox(x: Double(r.minX), y: 1 - Double(r.maxY), width: Double(r.width), height: Double(r.height))
        }
        return ((humans.results ?? []).map { box($0.boundingBox) },
                (faces.results ?? []).map { AnonymizeFace(box: box($0.boundingBox), confidence: Double($0.confidence)) })
    }
}

/// The per-frame refinement of one tracking pass (`MagicMaskTracker.track(refine:)`): detects the faces of the frame,
/// narrows the person's matte and remembers the frames where that was a guess.
public final class AnonymizeFrameRefiner: Sendable {
    private struct State: Sendable {
        var refiner: AnonymizeRefiner
        var flags: [(pts: Double, reason: AnonymizeCheck.Reason)] = []
    }
    private let state: Mutex<State>
    private let part: AnonymizeTarget
    private let detector: any PersonDetecting

    /// `seed`: the stored whole-person and narrowed matte of the frame the pass starts on (Track on an existing mask), so
    /// the pass continues with the face place known there (`AnonymizeRefiner.seed`).
    public init(part: AnonymizeTarget, detector: any PersonDetecting = VisionPersonDetector(),
                seed: (person: SubjectMatte, narrowed: SubjectMatte)? = nil) {
        self.part = part; self.detector = detector
        var refiner = AnonymizeRefiner(part: part)
        if let seed { refiner.seed(person: seed.person, narrowed: seed.narrowed) }
        state = Mutex(State(refiner: refiner))
    }

    public func apply(_ frame: CVPixelBuffer, _ pts: Double, _ person: SubjectMatte) throws -> SubjectMatte {
        guard part != .person else { return person }
        // A detector that fails on a frame is a frame without a face: covered by estimate and listed, never skipped.
        let faces = (try? detector.detect(frame, bodies: false).faces) ?? []
        let guide = part == .skin ? VisionInstanceSegmenter.guide(frame) : nil
        return state.withLock { s in
            let r = s.refiner.refine(person: person, faces: faces, guide: guide)
            if let f = r.flag { s.flags.append((pts, f)) }
            return r.matte
        }
    }

    /// The frames flagged so far (source seconds).
    public var flags: [(pts: Double, reason: AnonymizeCheck.Reason)] { state.withLock { $0.flags } }
}

public struct Anonymizer: Sendable {
    public let url: URL
    private let tracker: MagicMaskTracker
    private let detector: any PersonDetecting

    /// `pixelAspect`, `deinterlace`: the media item's `displayPixelAspect` and `deinterlaceFieldOrder`; people are
    /// found and followed on the frames as the monitor shows them.
    public init(url: URL, limits: WorkLimits = .current, segmenter: any InstanceSegmenting = VisionInstanceSegmenter(),
                detector: any PersonDetecting = VisionPersonDetector(), pixelAspect: PixelAspect = .square,
                deinterlace: FieldOrder? = nil) {
        self.url = url; self.detector = detector
        tracker = MagicMaskTracker(url: url, limits: limits, segmenter: segmenter, pixelAspect: pixelAspect, deinterlace: deinterlace)
    }

    public struct Found: Sendable {
        /// Left to right.
        public var people: [AnonymizePerson]
        /// Source time (s) of the frame they were found on.
        public var pts: Double
    }

    /// The people on the source frame shown at `seconds`. nil = no frame there; no people = nothing detected.
    public func findPeople(at seconds: Double) async throws -> Found? {
        // The frame the tracker follows the people on: deinterlaced and shaped like its frames.
        let reader = FrameReader(url: url, maxDimension: tracker.maxDimension, deinterlace: tracker.deinterlace,
                                 pixelAspect: tracker.pixelAspect)
        guard let (pb, pts) = try await reader.shownFrame(at: seconds) else { return nil }
        let segmenter = tracker.segmenter, detector = detector
        // Segmentation and detection block (Vision): on the frame lane like the read, not on the cooperative pool.
        return try await reader.work(urgent: true) {
            guard let f = try segmenter.segment(pb) else { return Found(people: [], pts: pts) }
            let d = try detector.detect(pb, bodies: true)
            return Found(people: AnonymizePeople.find(labels: f.labels, bodies: d.bodies, faces: d.faces), pts: pts)
        }
    }

    /// The pick that follows `person` found on the frame at `pts`.
    public static func selection(_ person: AnonymizePerson, pts: Double, target: AnonymizeTarget) -> MagicSelection {
        let t = Time(Int64((pts * 90_000).rounded()), 90_000)
        return MagicSelection(points: [MagicPoint(position: person.point, subtract: false, sourceTime: t)], part: target)
    }

    /// Mattes of a run, stored under a staged key until the result is taken over.
    public struct Staged: Sendable, Hashable {
        public var temp: String
        public var key: String
    }

    public struct Outcome: Sendable {
        /// Frames to look at by hand, in time order per person.
        public var checks: [AnonymizeCheck]
        /// Frames stored over all people.
        public var frames: Int
        /// Where the mattes are: `commit` moves them under the masks' keys, `discard` forgets them.
        public var staged: [Staged]
    }

    /// Takes a run's mattes over under the masks' own keys (after the masks were written into the clip). Mattes of an
    /// earlier run at other times stay.
    public static func commit(_ staged: [Staged], store: MagicMatteStore) {
        for s in staged { store.adopt(from: s.temp, into: s.key) }
    }

    /// Forgets a run's mattes; mattes a mask already draws are not touched.
    public static func discard(_ staged: [Staged], store: MagicMatteStore) {
        for s in staged { store.remove(key: s.temp) }
    }

    /// Follows every pick from its own frame to `last` and back to `first` (source seconds of the clip's edge frames).
    /// `frameGap`: seconds between two frames (joins flagged frames into ranges). The mattes are stored under staged keys
    /// (`Outcome.staged`), never under a mask's key: a pick on the same frame as an applied mask has that mask's key, so a
    /// run that is canceled, fails or is refused must leave it alone. Cancel through the task; a run that throws has
    /// removed its staged mattes.
    public func run(_ picks: [MagicSelection], media: UUID, first: Double, last: Double, frameGap: Double,
                    store: MagicMatteStore, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Outcome {
        var out = Outcome(checks: [], frames: 0, staged: [])
        let prefix = MagicMatteStore.stagedPrefix + UUID().uuidString.prefix(8).lowercased() + "-"
        for pick in picks {
            for k in pick.matteKeys(media: media) where !out.staged.contains(where: { $0.key == k }) {
                out.staged.append(Staged(temp: prefix + k, key: k))
            }
        }
        do {
            try await follow(picks, media: media, first: first, last: last, frameGap: frameGap, store: store, prefix: prefix,
                             out: &out, progress: progress)
        } catch {
            Self.discard(out.staged, store: store)
            throw error
        }
        progress?(1)
        return out
    }

    private func follow(_ picks: [MagicSelection], media: UUID, first: Double, last: Double, frameGap: Double, store: MagicMatteStore,
                        prefix: String, out: inout Outcome, progress: (@Sendable (Double) -> Void)?) async throws {
        let total = Double(max(picks.count, 1))
        for (i, pick) in picks.enumerated() {
            guard let anchorTime = pick.anchorTime else { continue }
            let anchor = Double(anchorTime.value) / Double(max(anchorTime.timescale, 1))
            let key = prefix + pick.cacheKey(media: media), partKey = pick.partKey(media: media).map { prefix + $0 }
            var flags: [(pts: Double, reason: AnonymizeCheck.Reason)] = []
            var lost: [AnonymizeCheck] = []
            let span = max(last - first, 1e-3)
            let forwardShare = min(max((last - anchor) / span, 0), 1)
            for forward in [true, false] {
                let to = forward ? last : first
                guard forward || anchor - first > 1e-4 else { continue }
                // One refiner per direction: both start at the pick's frame, where the person was found.
                let refiner = partKey == nil ? nil : pick.part.map { AnonymizeFrameRefiner(part: $0, detector: detector) }
                var refine: (@Sendable (CVPixelBuffer, Double, SubjectMatte) throws -> SubjectMatte)?
                if let refiner { refine = { pb, pts, m in try refiner.apply(pb, pts, m) } }
                let report: @Sendable (Double) -> Void = { p in
                    let done = forward ? p * forwardShare : forwardShare + p * (1 - forwardShare)
                    progress?((Double(i) + done) / total)
                }
                let r = try await tracker.track(key: key, points: pick.points, from: anchor, to: to, store: store,
                                                refinedKey: partKey, refine: refine, marksLost: false, progress: report)
                out.frames += r.frames
                flags += refiner?.flags ?? []
                if r.frames == 0 {
                    // Nothing to follow from the pick's frame: the whole direction is unchecked.
                    lost.append(AnonymizeCheck(person: i, reason: .lost, from: min(anchor, to), to: max(anchor, to)))
                }
                // The track goes on past frames without the person (the cover there is the enlarged last place): one
                // check per stretch of such frames.
                var run: (from: Double, to: Double)?
                for t in r.lostTimes.sorted() {
                    if let x = run, t - x.to <= frameGap * 1.5 + 1e-6 { run = (x.from, t) } else {
                        if let x = run { lost.append(AnonymizeCheck(person: i, reason: .lost, from: x.from, to: x.to)) }
                        run = (t, t)
                    }
                }
                if let x = run { lost.append(AnonymizeCheck(person: i, reason: .lost, from: x.from, to: x.to)) }
            }
            out.checks += (AnonymizeReport.ranges(person: i, flags: flags, gap: frameGap) + lost).sorted { $0.from < $1.from }
        }
    }
}
