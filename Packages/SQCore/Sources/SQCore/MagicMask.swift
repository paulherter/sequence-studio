import Foundation

// Magic masks (pure part): which segmented objects a click picks, and which objects of the next frame continue the
// picked subject while tracking. The segmentation itself (Vision instance masks) runs in SQAnalysis.

/// One click of the Magic mode: a frame-fraction position (0...1, origin top left) on the source frame at `sourceTime`.
/// `subtract` (Option-click) removes the object under it.
public struct MagicPoint: Sendable, Hashable, Codable {
    public var position: Vec2
    public var subtract: Bool
    /// Source media time of the frame the click was made on (survives trims and moves of the clip).
    public var sourceTime: Time
    public init(position: Vec2, subtract: Bool, sourceTime: Time) {
        self.position = position; self.subtract = subtract; self.sourceTime = sourceTime
    }
}

/// What a Magic mask picked. The per-frame mattes Track makes are not stored in the project: they live in the matte
/// cache under `cacheKey(media:)`, so picking again (other points) never reads mattes of the old pick.
public struct MagicSelection: Sendable, Hashable, Codable {
    public var points: [MagicPoint]
    /// F7.11 Anonymize: set on the masks Anonymize makes (they must cover: a frame without a matte is covered by estimate,
    /// never left open). `.face` / `.skin` narrow the followed person's matte per frame (stored under `partKey`); nil = an
    /// ordinary pick. An optional key: an older build ignores it and draws the whole person (`cacheKey` holds that matte).
    public var part: AnonymizeTarget?
    public init(points: [MagicPoint] = [], part: AnonymizeTarget? = nil) { self.points = points; self.part = part }

    /// The frame the pick was made on (the first point's), nil before the first click.
    public var anchorTime: Time? { points.first?.sourceTime }

    /// Stable across launches (FNV-1a over the media id and the points), hex. Never depends on `part`: this key holds the
    /// followed objects as they are (the whole person), in every build.
    public func cacheKey(media: UUID) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ bytes: some Sequence<UInt8>) { for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        mix(withUnsafeBytes(of: media.uuid) { Array($0) })
        for p in points {
            mix(withUnsafeBytes(of: p.position.x.bitPattern) { Array($0) })
            mix(withUnsafeBytes(of: p.position.y.bitPattern) { Array($0) })
            mix([p.subtract ? 1 : 0])
            mix(withUnsafeBytes(of: p.sourceTime.value) { Array($0) })
            mix(withUnsafeBytes(of: p.sourceTime.timescale) { Array($0) })
        }
        return String(h, radix: 16)
    }
}

/// Object labels of one frame: 0 = background, 1...n = one segmented object each (numbers are per frame, not stable).
/// Row 0 at the top; covers the whole upright frame.
public struct InstanceLabels: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var labels: [UInt8]
    public init(width: Int, height: Int, labels: [UInt8]) {
        precondition(width > 0 && height > 0 && labels.count == width * height, "InstanceLabels size mismatch")
        self.width = width; self.height = height; self.labels = labels
    }

    /// The label at frame fractions `p` (nearest texel; outside the frame: background).
    public func label(at p: Vec2) -> UInt8 {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return 0 }
        let x = min(Int(p.x * Double(width)), width - 1), y = min(Int(p.y * Double(height)), height - 1)
        return labels[y * width + x]
    }

    /// A hard matte of the objects in `selected`.
    public func matte(of selected: Set<UInt8>) -> SubjectMatte {
        var lut = [Float](repeating: 0, count: 256)
        for l in selected where l != 0 { lut[Int(l)] = 1 }
        return SubjectMatte(width: width, height: height, values: labels.map { lut[Int($0)] })
    }
}

public enum MagicPick {
    /// Objects picked by `points` on one frame: every object under an add point, minus every object under a subtract point.
    /// Points on the background pick nothing.
    public static func select(_ points: [MagicPoint], in l: InstanceLabels) -> Set<UInt8> { selection(points, in: l).selected }

    /// `select` plus the remove points that cut inside a kept object: a remove point on the object of the first click
    /// (the subject) never drops it, it cuts that part away along color edges (`MagicCorrection`).
    public static func selection(_ points: [MagicPoint], in l: InstanceLabels) -> (selected: Set<UInt8>, cuts: [Vec2]) {
        var add = Set<UInt8>(), sub = Set<UInt8>(), cuts: [Vec2] = []
        let subject = points.first { !$0.subtract }.map { l.label(at: $0.position) } ?? 0
        for p in points {
            let x = l.label(at: p.position)
            guard x != 0 else { continue }
            if !p.subtract { add.insert(x) } else if x == subject { cuts.append(p.position) } else { sub.insert(x) }
        }
        return (add.subtracting(sub), cuts)
    }

    /// Share of `previous` (any size) lying on object `x` (0...1).
    public static func share(of x: UInt8, previous: SubjectMatte, labels l: InstanceLabels) -> Double {
        let prev = previous.width == l.width && previous.height == l.height ? previous : previous.resampled(width: l.width, height: l.height)
        var on = 0.0, all = 0.0
        for i in 0..<l.labels.count {
            let v = Double(prev.values[i])
            all += v
            if l.labels[i] == x { on += v }
        }
        return all > 0 ? on / all : 0
    }
    /// A remove point on an object holding at least this share of the last matte cuts it instead of dropping it.
    public static let protectedShare = 0.3

    /// The soft matte of `selected` when it is usable (not blank, at the labels' size or at the analyzed frame's size
    /// `frameWidth` x `frameHeight`), else the hard matte of the labels: a soft mask Vision returns empty or at another
    /// size must never turn a pick into nothing.
    public static func usableSoft(_ soft: SubjectMatte?, labels l: InstanceLabels, selected: Set<UInt8>,
                                  frameWidth: Int = 0, frameHeight: Int = 0) -> SubjectMatte {
        if let soft, !soft.isBlank,
           (soft.width == l.width && soft.height == l.height) || (soft.width == frameWidth && soft.height == frameHeight) { return soft }
        return l.matte(of: selected)
    }

    /// Below this share of an object lying inside the last matte it is not part of the subject.
    public static let keepShare = 0.5
    /// A part of the subject the segmenter split off (an arm, a leg, a hand with a cup) moves faster than the body and
    /// lies less inside the last matte than the body does: an object at most `limbSize` of the last matte's area stays
    /// from this share on. A whole second object (another person stepping in) is larger and still needs `keepShare`.
    public static let limbShare = 0.25
    public static let limbSize = 0.35
    /// Tracking stops (the subject counts as lost) when the new pick and the last matte agree less than this (IoU).
    public static let minConfidence = 0.3

    /// The objects of the next frame that continue the subject of `previous` (the last frame's matte, any size): every
    /// object lying at least `keepShare` inside it (a small one: `limbShare`), or else the one overlapping it most. `confidence` = IoU of the new
    /// pick with the previous matte (0...1). nil when nothing overlaps (subject gone or hidden).
    public static func follow(previous: SubjectMatte, labels l: InstanceLabels) -> (selected: Set<UInt8>, confidence: Double)? {
        let prev = previous.width == l.width && previous.height == l.height ? previous : previous.resampled(width: l.width, height: l.height)
        var inside = [Double](repeating: 0, count: 256), area = [Double](repeating: 0, count: 256)
        var prevArea = 0.0
        for i in 0..<l.labels.count {
            let v = Double(prev.values[i])
            prevArea += v
            let x = Int(l.labels[i])
            guard x != 0 else { continue }
            area[x] += 1; inside[x] += v
        }
        var selected = Set<UInt8>()
        var best: (UInt8, Double)?
        for x in 1..<256 where area[x] > 0 {
            if inside[x] / area[x] >= keepShare { selected.insert(UInt8(x)) }
            if inside[x] > (best?.1 ?? 0) { best = (UInt8(x), inside[x]) }
        }
        // Split limbs: only next to a body that was followed (never the only thing kept, never on an empty last matte).
        if !selected.isEmpty, prevArea > 0 {
            for x in 1..<256 where area[x] > 0 && area[x] <= limbSize * prevArea && inside[x] / area[x] >= limbShare {
                selected.insert(UInt8(x))
            }
        }
        if selected.isEmpty, let b = best, b.1 > 0 { selected = [b.0] }
        guard !selected.isEmpty, prevArea > 0 else { return nil }
        var inter = 0.0, newArea = 0.0
        for x in selected { inter += inside[Int(x)]; newArea += area[Int(x)] }
        let union = newArea + prevArea - inter
        return (selected, union > 0 ? min(max(inter / union, 0), 1) : 0)
    }
}
