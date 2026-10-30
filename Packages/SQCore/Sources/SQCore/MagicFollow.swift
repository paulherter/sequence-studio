import Foundation

// Magic mask tracking (pure part): one segmented frame (`InstanceFrame`) and the per-frame rule of Track
// (`MagicFollower`). The segmentation itself (Vision) runs in SQAnalysis; tests drive this with synthetic frames.

/// The picture of a segmented frame at the labels' size: RGB 0...1, interleaved, row 0 at the top. Corrections (add /
/// remove points) grow and cut along its color edges.
public struct MagicGuide: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var rgb: [Float]
    public init(width: Int, height: Int, rgb: [Float]) {
        precondition(width > 0 && height > 0 && rgb.count == width * height * 3, "MagicGuide size mismatch")
        self.width = width; self.height = height; self.rgb = rgb
    }
}

/// One segmented frame: object labels plus the soft matte of any set of objects, and (when the segmenter gives it) the
/// picture for corrections.
public struct InstanceFrame: Sendable {
    public var labels: InstanceLabels
    public var guide: MagicGuide?
    /// Soft matte of the given labels at the labels' size; default: the hard labels.
    public var soft: @Sendable (Set<UInt8>) -> SubjectMatte
    public init(labels: InstanceLabels, guide: MagicGuide? = nil, soft: (@Sendable (Set<UInt8>) -> SubjectMatte)? = nil) {
        self.labels = labels
        self.guide = guide
        self.soft = soft ?? { labels.matte(of: $0) }
    }
}

/// The per-frame rule of Track: the first frame picks by the clicks made on it (or continues a stored matte), every later
/// frame keeps the objects that continue the last matte (`MagicPick.follow`); add / remove points made on a frame correct
/// it there (`MagicCorrection`) and the correction is carried on. A frame's matte comes from that frame alone: nothing
/// of the frame before is blended in (a blend in tracking order trails every motion, and the other way when tracked
/// backward). Pure apart from the segmenter's output, so tests drive it with synthetic frames.
public struct MagicFollower: Sendable {
    public private(set) var previous: SubjectMatte?
    public private(set) var lastConfidence: Double = 1
    private var correction = MagicCorrection.State()
    private var index = 0

    /// `start`: a matte to continue from (stored for the start frame), else nil to pick by `points`.
    /// A start matte stored empty (the subject was not found on that frame) is no matte to continue: only points made
    /// on that frame pick there.
    public init(start: SubjectMatte? = nil) {
        let lost = start?.isBlank == true
        previous = lost ? nil : start
        startsOnLostFrame = lost
    }
    private var startsOnLostFrame = false

    /// A point belongs to the frame at `pts` (seconds) when its source time is within this of it.
    public static let pointTolerance = 1e-3

    /// Whether a point stored at `point` (source seconds) was made on the frame at `pts` that is shown for `span` seconds:
    /// at the frame's own time (older projects stored the decoded frame's time) or anywhere before the next frame (a click
    /// stores the clip's source time at the playhead, which lies inside the frame). `span` 0 = unknown: the frame's own
    /// time only.
    public static func belongs(point: Double, pts: Double, span: Double = 0) -> Bool {
        let d = point - pts
        return d >= -pointTolerance && d < max(span, 2 * pointTolerance) - pointTolerance
    }

    /// The matte of the next frame in tracking order, nil when the subject is not found on it. The follower then stays
    /// as it was: the next frame is compared with the last matte that was found, so a subject hidden for some frames is
    /// picked up again where it was last seen. `points`: all points
    /// of the pick; the first frame without a start matte uses the pick's own frame's points, every frame applies the
    /// points made on it (`pts`: the frame's source time in seconds, nil = none; `span`: seconds to the next frame).
    public mutating func step(_ f: InstanceFrame, points: [MagicPoint], pts: Double? = nil, span: Double = 0) -> SubjectMatte? {
        var selected: Set<UInt8>
        var here: [MagicPoint] = []
        if let pts {
            here = points.filter {
                Self.belongs(point: Double($0.sourceTime.value) / Double(max($0.sourceTime.timescale, 1)), pts: pts, span: span)
            }
        }
        var cuts: [Vec2] = []
        if let prev = previous {
            guard let r = MagicPick.follow(previous: prev, labels: f.labels) else { return nil }
            selected = r.selected
            for p in here {
                let x = f.labels.label(at: p.position)
                guard x != 0 else { continue }
                if !p.subtract { selected.insert(x) }
                else if MagicPick.share(of: x, previous: prev, labels: f.labels) >= MagicPick.protectedShare { cuts.append(p.position) }
                else { selected.remove(x) }
            }
            if index == 0 {
                // Continuing a stored (maybe corrected) matte: its correction is carried on.
                correction = MagicCorrection.state(raw: f.soft(r.selected), corrected: prev, guide: f.guide)
            }
        } else {
            // The pick's points were made on another frame: they say nothing about where the subject is here.
            if startsOnLostFrame, here.isEmpty { return nil }
            let anchor = points.first?.sourceTime
            let first = here.isEmpty ? points.filter { $0.sourceTime == anchor } : here
            let s = MagicPick.selection(first, in: f.labels)
            selected = s.selected
            cuts = s.cuts
            here = first
        }
        guard !selected.isEmpty else { return nil }
        let raw = f.soft(selected)
        guard !raw.isBlank else { return nil }          // an empty matte is a lost subject, never a black frame
        let add = here.filter { !$0.subtract }.map(\.position)
        // A frame that turns out lost leaves the carried correction as it was.
        var carried = correction
        let corrected = MagicCorrection.apply(base: raw, guide: f.guide, add: add, remove: cuts, state: &carried)
        guard !corrected.isBlank else { return nil }
        if let prev = previous, index > 0 {
            let c = Self.overlap(corrected, prev)
            guard c >= MagicPick.minConfidence else { return nil }
            lastConfidence = c
        } else {
            lastConfidence = 1
        }
        correction = carried
        index += 1
        previous = corrected
        return corrected
    }

    /// Soft IoU of two mattes (`b` resampled to `a`'s size).
    static func overlap(_ a: SubjectMatte, _ b: SubjectMatte) -> Double {
        let bb = a.width == b.width && a.height == b.height ? b : b.resampled(width: a.width, height: a.height)
        var mn = 0.0, mx = 0.0
        for i in 0..<a.values.count {
            let x = Double(a.values[i]), y = Double(bb.values[i])
            mn += min(x, y); mx += max(x, y)
        }
        return mx > 0 ? mn / mx : 0
    }
}
