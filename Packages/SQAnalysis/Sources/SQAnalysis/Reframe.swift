import Foundation
import SQCore

// Auto-Reframe planning: subject detections per sampled frame -> smoothed Position keys (and a cover Scale) that keep the
// subject inside the target frame. Pure value logic; the Vision part sits behind `SubjectDetecting`.

/// Rectangle in normalized coordinates of the upright picture: 0...1, origin top-left, y down.
public struct NormalizedRect: Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: Vec2 { Vec2(x + width / 2, y + height / 2) }
    public var area: Double { max(width, 0) * max(height, 0) }
}

public enum SubjectKind: String, Sendable, Hashable {
    /// Strongest signal: the camera keeps faces in frame first.
    case face
    /// Human body (person detector).
    case body
    /// Attention-based saliency (whatever the eye goes to), used when no person is found.
    case saliency
}

public struct SubjectBox: Sendable, Hashable {
    public var kind: SubjectKind
    public var rect: NormalizedRect
    /// 0...1.
    public var confidence: Double
    public init(kind: SubjectKind, rect: NormalizedRect, confidence: Double) {
        self.kind = kind; self.rect = rect; self.confidence = confidence
    }
}

/// Detections of one sampled frame. `time` is clip-local (0 = the clip's first timeline frame), like keyframe times.
public struct FrameDetections: Sendable, Hashable {
    public var time: Time
    public var boxes: [SubjectBox]
    public init(time: Time, boxes: [SubjectBox]) { self.time = time; self.boxes = boxes }
}

public struct ReframeOptions: Sendable, Hashable {
    /// Seconds between analyzed frames (rounded to whole sequence frames, at least one).
    public var sampleInterval: Double = 0.2
    /// Length of the moving average over the camera path, in seconds.
    public var smoothingWindow: Double = 1.0
    /// The camera does not move while the subject stays within this fraction of the frame size of the current framing.
    public var deadZone: Double = 0.05
    /// Keys are dropped while the linear path between the kept ones stays within this many sequence pixels.
    public var tolerance: Double = 2
    /// Detections below this confidence are ignored.
    public var minConfidence: Double = 0.3
    /// Extra zoom on top of the cover scale (1 = just fill the frame; values below 1 are clamped to 1).
    public var zoom: Double = 1
    public init() {}
}

// MARK: - Crop window

/// Where the picture sits in the frame. Compositor semantics (SQRender): position = offset of the anchor from the canvas
/// center in sequence px (y down), scale = sequence px per source px, anchor = offset from the picture center in source px.
/// Rotation is not considered (reframing a rotated clip keeps its rotation but frames as if it were 0).
public struct ReframeGeometry: Sendable, Hashable {
    /// Upright picture size (rotation applied), source px.
    public var pictureWidth: Int, pictureHeight: Int
    /// Target frame (sequence) size.
    public var frameWidth: Int, frameHeight: Int
    public var anchor: Vec2
    public var zoom: Double

    public init(pictureWidth: Int, pictureHeight: Int, frameWidth: Int, frameHeight: Int, anchor: Vec2 = .zero, zoom: Double = 1) {
        self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.anchor = anchor; self.zoom = zoom
    }

    /// Smallest scale at which the picture covers the frame on both axes, times `zoom` (>= 1).
    public var scale: Double {
        guard pictureWidth > 0, pictureHeight > 0 else { return 1 }
        let cover = max(Double(frameWidth) / Double(pictureWidth), Double(frameHeight) / Double(pictureHeight))
        return cover * max(zoom.isFinite ? zoom : 1, 1)
    }

    /// The picture already fills the frame with nothing to spare (same shape, no extra zoom): the crop window cannot move.
    public var isAlreadyFramed: Bool { maxOffset.x < 0.5 && maxOffset.y < 0.5 }

    /// Largest |position| per axis at which the picture still covers the frame, for an anchor at the picture center.
    public var maxOffset: Vec2 {
        let s = scale
        return Vec2(max((Double(pictureWidth) * s - Double(frameWidth)) / 2, 0),
                    max((Double(pictureHeight) * s - Double(frameHeight)) / 2, 0))
    }

    /// Position range on one axis: the picture edges at `position + s * (±half - anchor)` must stay outside the frame.
    private func range(_ axis: KeyPath<Vec2, Double>) -> ClosedRange<Double> {
        let m = maxOffset[keyPath: axis], a = anchor[keyPath: axis] * scale
        return (a - m)...(a + m)
    }

    /// Clamped position that puts the normalized picture point `p` in the frame center (as close as covering allows).
    public func position(centering p: Vec2) -> Vec2 {
        let s = scale
        let src = Vec2((p.x - 0.5) * Double(pictureWidth), (p.y - 0.5) * Double(pictureHeight))
        return clamp(Vec2(-s * (src.x - anchor.x), -s * (src.y - anchor.y)))
    }

    public func clamp(_ v: Vec2) -> Vec2 {
        let rx = range(\.x), ry = range(\.y)
        return Vec2(min(max(v.x, rx.lowerBound), rx.upperBound), min(max(v.y, ry.lowerBound), ry.upperBound))
    }
}

// MARK: - Focus point

public enum ReframeFocus {
    /// A body box is framed on its upper part (head and shoulders), this far down from its top.
    public static let bodyHeadFraction = 0.25

    /// Normalized point the camera should center for one frame: faces first, then bodies, then saliency; within the
    /// winning kind the area x confidence weighted center. nil when nothing reaches `minConfidence`.
    public static func focus(of boxes: [SubjectBox], minConfidence: Double) -> Vec2? {
        let usable = boxes.filter { $0.confidence >= minConfidence && $0.rect.area > 0 }
        for kind in [SubjectKind.face, .body, .saliency] {
            let group = usable.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            var sum = Vec2.zero, total = 0.0
            for b in group {
                let w = b.rect.area * b.confidence
                sum = sum + point(of: b) * w
                total += w
            }
            if total > 0 { return sum * (1 / total) }
        }
        return nil
    }

    static func point(of b: SubjectBox) -> Vec2 {
        switch b.kind {
        case .body: Vec2(b.rect.x + b.rect.width / 2, b.rect.y + b.rect.height * bodyHeadFraction)
        case .face, .saliency: b.rect.center
        }
    }
}

// MARK: - Smoothing

public enum ReframeSmoothing {
    /// Missing points hold the last known one; leading gaps take the first known. nil when no point is known.
    public static func fillGaps(_ pts: [Vec2?]) -> [Vec2]? {
        guard let first = pts.first(where: { $0 != nil }) ?? nil else { return nil }
        var last = first
        return pts.map { p in
            if let p { last = p }
            return last
        }
    }

    /// Lazy camera: starts on the first point and moves only as far as needed to keep each point within `radius`.
    public static func deadZone(_ pts: [Vec2], radius: Vec2) -> [Vec2] {
        guard var c = pts.first else { return [] }
        func follow(_ cam: Double, _ p: Double, _ r: Double) -> Double {
            if p > cam + r { return p - r }
            if p < cam - r { return p + r }
            return cam
        }
        return pts.map { p in
            c = Vec2(follow(c.x, p.x, radius.x), follow(c.y, p.y, radius.y))
            return c
        }
    }

    /// Centered moving average of `2 * radius + 1` points; the window shrinks symmetrically at the ends, so the first and
    /// last points are kept as they are and a straight path stays straight.
    public static func movingAverage(_ pts: [Vec2], radius: Int) -> [Vec2] {
        guard radius > 0, pts.count > 2 else { return pts }
        return pts.indices.map { i in
            let r = min(radius, i, pts.count - 1 - i)
            guard r > 0 else { return pts[i] }
            var s = Vec2.zero
            for j in (i - r)...(i + r) { s = s + pts[j] }
            return s * (1 / Double(2 * r + 1))
        }
    }

    /// Ramer-Douglas-Peucker in time: indices of the points to keep so that linear interpolation between the kept points
    /// (by time) stays within `tolerance` of every dropped point. Always keeps the first and the last.
    public static func simplify(times: [Double], points: [Vec2], tolerance: Double) -> [Int] {
        let n = min(times.count, points.count)
        guard n > 2 else { return Array(0..<n) }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true; keep[n - 1] = true
        var stack = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = -1.0, at = -1
            let span = times[b] - times[a]
            for k in (a + 1)..<b {
                let f = span > 0 ? (times[k] - times[a]) / span : 0
                let d = (points[k] - Vec2.lerp(points[a], points[b], f)).length
                if d > worst { worst = d; at = k }
            }
            if worst > tolerance {
                keep[at] = true
                stack.append((a, at)); stack.append((at, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }
}

// MARK: - Planner

/// Result for one clip: what to write into Motion.
public struct ReframePlan: Sendable, Hashable {
    /// Uniform Scale (static).
    public var scale: Double
    /// Position: static value, or keys at sample times (clip-local, linear).
    public var position: AnimatedProperty<Vec2>
    /// Frames analyzed and frames with a usable subject.
    public var samples: Int
    public var detectedSamples: Int

    public init(scale: Double, position: AnimatedProperty<Vec2>, samples: Int, detectedSamples: Int) {
        self.scale = scale; self.position = position; self.samples = samples; self.detectedSamples = detectedSamples
    }
}

public enum ReframePlanner {
    /// nil when no frame has a usable subject (the clip is then left alone).
    public static func plan(detections: [FrameDetections], geometry: ReframeGeometry,
                            options: ReframeOptions = ReframeOptions()) -> ReframePlan? {
        let sorted = detections.sorted { $0.time < $1.time }
        let focus = sorted.map { ReframeFocus.focus(of: $0.boxes, minConfidence: options.minConfidence) }
        guard let filled = ReframeSmoothing.fillGaps(focus) else { return nil }
        let targets = filled.map(geometry.position(centering:))
        let lazy = ReframeSmoothing.deadZone(targets, radius: Vec2(options.deadZone * Double(geometry.frameWidth),
                                                                   options.deadZone * Double(geometry.frameHeight)))
        let seconds = sorted.map { Double($0.time.value) / Double($0.time.timescale) }
        let step = seconds.count > 1 ? (seconds.last! - seconds.first!) / Double(seconds.count - 1) : 0
        let radius = step > 0 ? Int((options.smoothingWindow / step / 2).rounded()) : 0
        let path = ReframeSmoothing.movingAverage(lazy, radius: radius).map(geometry.clamp)
        let kept = ReframeSmoothing.simplify(times: seconds, points: path, tolerance: options.tolerance)
        let detected = focus.count { $0 != nil }
        let s = geometry.scale
        if kept.count <= 2, let a = kept.first, let b = kept.last, (path[a] - path[b]).length <= options.tolerance {
            return ReframePlan(scale: s, position: AnimatedProperty(path[a]), samples: sorted.count, detectedSamples: detected)
        }
        let keys = kept.map { Keyframe(time: sorted[$0].time, value: path[$0]) }
        return ReframePlan(scale: s, position: AnimatedProperty(path[kept[0]], track: KeyframeTrack(keys: keys)),
                           samples: sorted.count, detectedSamples: detected)
    }
}

// MARK: - Sampling

/// One analyzed frame: clip-local time (key time) and the source (media) time shown there.
public struct ReframeSample: Sendable, Hashable {
    public var local: Time
    public var source: Time
    public init(local: Time, source: Time) { self.local = local; self.source = source }
}

public enum ReframeSampling {
    /// Every `interval` seconds (whole frames, at least one) from the clip's first frame, plus its last frame; source times
    /// through the clip's speed, reverse and time remapping.
    public static func samples(for clip: Clip, frameDuration fd: Time, interval: Double) -> [ReframeSample] {
        let frames = clip.duration.frameIndex(frameDuration: fd)
        guard frames > 0 else { return [] }
        let fps = Double(fd.timescale) / Double(fd.value)
        let step = max(Int64((interval * fps).rounded()), 1)
        var locals = stride(from: Int64(0), to: frames, by: Int(step)).map { fd * $0 }
        let lastFrame = fd * (frames - 1)
        if locals.last != lastFrame { locals.append(lastFrame) }
        return locals.map { ReframeSample(local: $0, source: clip.sourceTime(at: clip.start + $0, frameDuration: fd)) }
    }
}

// MARK: - Detection

/// Finds subjects in the frame shown at a source time. `VisionSubjectDetector` is the real one; tests script their own.
public protocol SubjectDetecting: Sendable {
    func subjects(atSourceTime t: Time) async throws -> [SubjectBox]
}

public enum ReframeAnalyzer {
    /// Runs `detector` on every sample in order. `progress` gets 0...1 after each frame. Throws `CancellationError` when
    /// the task is canceled (checked before each frame).
    public static func detect(samples: [ReframeSample], using detector: any SubjectDetecting,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> [FrameDetections] {
        var out: [FrameDetections] = []
        out.reserveCapacity(samples.count)
        for (i, s) in samples.enumerated() {
            try Task.checkCancellation()
            out.append(FrameDetections(time: s.local, boxes: try await detector.subjects(atSourceTime: s.source)))
            progress?(Double(i + 1) / Double(samples.count))
        }
        return out
    }
}
