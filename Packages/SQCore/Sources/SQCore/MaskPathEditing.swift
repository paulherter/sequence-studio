import Foundation

// Mask pen handles and mask tracking (follow-up to W6.7). Pure path maths; the Program monitor overlay and the Vision
// tracker (SQAnalysis) call into it. Points are frame fractions (0...1, y down) like everything in `MaskPath`.

/// An axis-aligned box in frame fractions (y down): what the object tracker follows.
public struct MaskTrackBox: Sendable, Hashable, Codable {
    public var center: Vec2
    public var size: Vec2
    public init(center: Vec2, size: Vec2) { self.center = center; self.size = size }
}

extension MaskPath {
    /// Bounding box of the flattened outline (an empty path: a zero box at the frame center).
    public var bounds: MaskTrackBox {
        MaskTrackBox(bounding: polygon())
    }

    /// The path moved (and with `scale`, sized per axis) the way box `a` became box `b`. Tangents scale along.
    public func tracked(from a: MaskTrackBox, to b: MaskTrackBox, scale: Bool) -> MaskPath {
        let sx = scale && a.size.x > 1e-9 ? b.size.x / a.size.x : 1
        let sy = scale && a.size.y > 1e-9 ? b.size.y / a.size.y : 1
        func s(_ v: Vec2) -> Vec2 { Vec2(v.x * sx, v.y * sy) }
        return MaskPath(vertices: vertices.map { v in
            MaskVertex(b.center + s(v.point - a.center), inTangent: s(v.inTangent), outTangent: s(v.outTangent))
        })
    }

    /// Bezier control points of segment `i` (vertex i to vertex i+1, the last one closes the path).
    func controlPoints(_ i: Int) -> (Vec2, Vec2, Vec2, Vec2) {
        let a = vertices[i], b = vertices[(i + 1) % vertices.count]
        return (a.point, a.point + a.outTangent, b.point + b.inTangent, b.point)
    }

    static func bezier(_ c: (Vec2, Vec2, Vec2, Vec2), _ t: Double) -> Vec2 {
        let u = 1 - t
        return c.0 * (u * u * u) + c.1 * (3 * u * u * t) + c.2 * (3 * u * t * t) + c.3 * (t * t * t)
    }

    /// A vertex added on segment `i` at curve parameter `t` (de Casteljau): the shape does not change. A straight segment
    /// gets a corner. The new vertex sits at index `i + 1` (the end for the closing segment).
    public func splitting(segment i: Int, at t: Double) -> MaskPath {
        guard vertices.indices.contains(i) else { return self }
        let t = min(max(t, 0), 1)
        let a = vertices[i], b = vertices[(i + 1) % vertices.count]
        var out = self
        if a.outTangent == .zero && b.inTangent == .zero {
            out.vertices.insert(MaskVertex(Vec2.lerp(a.point, b.point, t)), at: i + 1)
            return out
        }
        let (p0, p1, p2, p3) = controlPoints(i)
        let p01 = Vec2.lerp(p0, p1, t), p12 = Vec2.lerp(p1, p2, t), p23 = Vec2.lerp(p2, p3, t)
        let q0 = Vec2.lerp(p01, p12, t), q1 = Vec2.lerp(p12, p23, t)
        let m = Vec2.lerp(q0, q1, t)
        out.vertices[i].outTangent = p01 - p0
        out.vertices[(i + 1) % vertices.count].inTangent = p23 - p3
        out.vertices.insert(MaskVertex(m, inTangent: q0 - m, outTangent: q1 - m), at: i + 1)
        return out
    }

    /// The segment nearest to `p` (frame fractions), its curve parameter and the distance in px of a `frame`-sized picture.
    public func nearestSegment(to p: Vec2, frame: Vec2) -> (segment: Int, t: Double, distance: Double)? {
        guard vertices.count >= 2 else { return nil }
        func px(_ v: Vec2) -> Vec2 { Vec2(v.x * frame.x, v.y * frame.y) }
        let target = px(p)
        var best: (Int, Double, Double)?
        let steps = Self.curveSubdivisions * 4
        for i in vertices.indices {
            let c = controlPoints(i)
            let straight = c.0 == c.1 && c.2 == c.3   // `splitting` places points linearly on straight segments
            var prev = px(c.0)
            for s in 1...steps {
                let t1 = Double(s) / Double(steps)
                let cur = px(straight ? Vec2.lerp(c.0, c.3, t1) : Self.bezier(c, t1))
                let e = cur - prev, w = target - prev
                let ee = e.x * e.x + e.y * e.y
                let k = ee > 0 ? min(max((w.x * e.x + w.y * e.y) / ee, 0), 1) : 0
                let d = (w - e * k).length
                if d < (best?.2 ?? .infinity) {
                    best = (i, (Double(s - 1) + k) / Double(steps), d)
                }
                prev = cur
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// Pen tool: a vertex placed on segment `i` at `t` (see `splitting`) whose handles are pulled to `handle` (its out
    /// tangent, offset from the new point; the in tangent mirrors unless `independent`). A zero handle is a plain split.
    public func placingVertex(segment i: Int, at t: Double, handle: Vec2, independent: Bool) -> MaskPath {
        guard vertices.indices.contains(i) else { return self }
        var out = splitting(segment: i, at: t)
        if handle != .zero { out.setTangent(i + 1, out: true, to: handle, independent: independent) }
        return out
    }

    /// The path without vertex `i`; nil when that would leave fewer than three vertices or `i` is out of range.
    public func removingVertex(_ i: Int) -> MaskPath? {
        guard vertices.indices.contains(i), vertices.count > 3 else { return nil }
        var out = self
        out.vertices.remove(at: i)
        return out
    }

    /// Corner <-> smooth (Option-click a vertex): a corner gets tangents along the chord of its neighbors, a third of
    /// the way to each; a smooth or broken vertex becomes a corner.
    public func togglingSmooth(_ i: Int) -> MaskPath {
        guard vertices.indices.contains(i), vertices.count >= 3 else { return self }
        var out = self
        let v = vertices[i]
        if !v.isCorner {
            out.vertices[i].inTangent = .zero; out.vertices[i].outTangent = .zero
            return out
        }
        let prev = vertices[(i + vertices.count - 1) % vertices.count].point, next = vertices[(i + 1) % vertices.count].point
        let chord = next - prev
        let len = chord.length
        guard len > 1e-12 else { return self }
        let dir = chord * (1 / len)
        out.vertices[i].outTangent = dir * ((next - v.point).length / 3)
        out.vertices[i].inTangent = dir * (-(prev - v.point).length / 3)
        return out
    }

    /// Drags one tangent handle (offset from the vertex). The other side mirrors it unless `independent` (Option).
    public mutating func setTangent(_ i: Int, out isOut: Bool, to offset: Vec2, independent: Bool) {
        guard vertices.indices.contains(i) else { return }
        if isOut { vertices[i].outTangent = offset } else { vertices[i].inTangent = offset }
        guard !independent else { return }
        if isOut { vertices[i].inTangent = offset * -1 } else { vertices[i].outTangent = offset * -1 }
    }
}

/// Follows a mask region through source frames (Vision in SQAnalysis; tests use a fake).
public protocol MaskTracking: Sendable {
    /// `region` is the mask outline (frame fractions) at `sourceTimes[0]`; times run in tracking order (forward or
    /// backward). Returns one motion per time (frame fractions, from the first frame; the first is the identity), nil
    /// from the frame where the object was lost on. `mode` says which motion to follow.
    func track(region: [Vec2], mode: MaskTrackMode, sourceTimes: [Time],
               progress: (@Sendable (Double) -> Void)?) async throws -> [MaskMotion?]
}

extension Clip {
    /// Adds a vertex on segment `segment` at curve parameter `t` to the path value and every path key (same place in each),
    /// so the keys keep the same vertex count and still blend.
    public mutating func insertMaskVertex(_ id: ClipMask.ID, segment: Int, at t: Double) {
        updateMask(id) { m in
            m.path.value = m.path.value.splitting(segment: segment, at: t)
            for k in m.path.track.keys where k.value.vertices.count > segment {
                m.path.track.set(k.id, value: k.value.splitting(segment: segment, at: t))
            }
        }
    }

    /// Pen tool: `insertMaskVertex` plus pulled handles on the new vertex of the shape shown at `t` (a key there when the
    /// path is animated). Other keys only get the point.
    public mutating func placeMaskVertex(_ id: ClipMask.ID, segment: Int, at t: Double, handle: Vec2, independent: Bool,
                                         atLocal local: Time) {
        insertMaskVertex(id, segment: segment, at: t)
        guard handle != .zero, let m = mask(id), m.path.value(atLocal: local).vertices.indices.contains(segment + 1) else { return }
        var shown = m.path.value(atLocal: local)
        shown.setTangent(segment + 1, out: true, to: handle, independent: independent)
        setMaskPath(id, shown, atLocal: local)
    }

    /// Deletes vertex `index` from the path value and every key. False when the path would get fewer than three vertices.
    @discardableResult
    public mutating func removeMaskVertex(_ id: ClipMask.ID, _ index: Int) -> Bool {
        guard let m = mask(id) else { return false }
        let shapes = m.path.isAnimated ? m.path.track.keys.map(\.value) : [m.path.value]
        guard shapes.allSatisfy({ $0.removingVertex(index) != nil }) else { return false }
        updateMask(id) { m in
            if let v = m.path.value.removingVertex(index) { m.path.value = v }
            for k in m.path.track.keys { if let r = k.value.removingVertex(index) { m.path.track.set(k.id, value: r) } }
        }
        return true
    }

    /// Clip-local frame times a track visits, starting at `l0` and stepping one frame to the clip's first or last frame.
    /// Empty when `l0` is outside the clip.
    public func maskTrackTimes(fromLocal l0: Time, forward: Bool, frameDuration fd: Time) -> [Time] {
        guard fd > .zero, l0 >= .zero, l0 < duration else { return [] }
        var out: [Time] = []
        var t = l0
        while t >= .zero && t < duration {
            out.append(t)
            t = forward ? t + fd : t - fd
        }
        return out
    }

    /// Writes a tracked mask: a path key at every `times[i]` whose box is known (up to the first lost frame), the shape shown
    /// at `times[0]` moved (and with `scale`, sized) like `boxes[0]` became `boxes[i]`. Path keys inside the tracked span are
    /// replaced. Returns the number of keys written (0: nothing changed).
    @discardableResult
    public mutating func applyMaskTrack(_ id: ClipMask.ID, times: [Time], boxes: [MaskTrackBox?], scale: Bool) -> Int {
        guard let b0 = boxes.first ?? nil else { return 0 }
        return applyMaskTrack(id, times: times, motions: boxes.map { $0.map { MaskMotion(from: b0, to: $0, scale: scale) } })
    }

    /// Writes a tracked mask from motions (frame fractions, from the shape shown at `times[0]`): a path key at every time
    /// up to the first nil; path keys inside the tracked span are replaced. Returns the number of keys written.
    @discardableResult
    public mutating func applyMaskTrack(_ id: ClipMask.ID, times: [Time], motions: [MaskMotion?]) -> Int {
        guard let m = mask(id), let first = times.first, motions.first ?? nil != nil else { return 0 }
        let base = m.path.value(atLocal: first)
        var written: [(Time, MaskPath)] = []
        for (t, h) in zip(times, motions) {
            guard let h else { break }
            written.append((t, base.transformed(by: h)))
        }
        guard let lo = written.map(\.0).min(), let hi = written.map(\.0).max() else { return 0 }
        updateMask(id) { m in
            for k in m.path.track.keys where k.time >= lo && k.time <= hi { m.path.track.remove(k.id) }
            for (t, p) in written { m.path.track.insert(Keyframe(time: t, value: p)) }
        }
        return written.count
    }
}

// Long-track drift: a track between path keys the user already set re-anchors on them.
extension MaskPath {
    /// This path with `anchor - end` added, scaled by `weight`, to every vertex (point and tangents); same vertex count assumed.
    func corrected(from end: MaskPath, to anchor: MaskPath, weight: Double) -> MaskPath {
        guard end.vertices.count == vertices.count, anchor.vertices.count == vertices.count else { return self }
        return MaskPath(vertices: (0..<vertices.count).map { i in
            let v = vertices[i], e = end.vertices[i], a = anchor.vertices[i]
            return MaskVertex(v.point + (a.point - e.point) * weight,
                              inTangent: v.inTangent + (a.inTangent - e.inTangent) * weight,
                              outTangent: v.outTangent + (a.outTangent - e.outTangent) * weight)
        })
    }
}

extension Clip {
    /// Indices of `times` (not the first) holding a key the user set: a key in a run of 3 or more consecutive visited frames
    /// is an earlier tracking result, not an anchor (re-tracking replaces it).
    func maskTrackAnchors(_ id: ClipMask.ID, times: [Time]) -> [Int] {
        guard let m = mask(id), !times.isEmpty else { return [] }
        let keyed = Set(m.path.track.keys.map(\.time))
        let has = times.map { keyed.contains($0) }
        var anchors: [Int] = []
        var i = 0
        while i < times.count {
            guard has[i] else { i += 1; continue }
            var j = i
            while j + 1 < times.count, has[j + 1] { j += 1 }
            if j - i + 1 <= 2, i > 0 { anchors.append(i) }
            i = j + 1
        }
        return anchors
    }

    /// Index ranges of `times` a track runs in, split at the anchors: an anchor ends one range and starts the next (they share
    /// that index). Without anchors: one range.
    public func maskTrackSegments(_ id: ClipMask.ID, times: [Time]) -> [Range<Int>] {
        guard !times.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var lo = 0
        for a in maskTrackAnchors(id, times: times) { out.append(lo..<(a + 1)); lo = a }
        if lo < times.count - 1 || out.isEmpty { out.append(lo..<times.count) }
        return out
    }

    /// Writes a track made per `maskTrackSegments` range. `motions[s]` belongs to `segments[s]` (one per frame, from the shape
    /// shown at the range's first frame; nil = lost). A range that ends on an anchor key is pulled onto it: the error between
    /// where the tracker ended and the key is spread linearly over the range. A lost frame ends the run (later ranges are not
    /// written). Keys inside the written span are replaced. Returns the number of keys written.
    @discardableResult
    public mutating func applyMaskTrack(_ id: ClipMask.ID, times: [Time], segments: [Range<Int>], motions: [[MaskMotion?]]) -> Int {
        guard let m = mask(id), segments.count == motions.count else { return 0 }
        let anchors = Set(maskTrackAnchors(id, times: times))
        var written: [(Time, MaskPath)] = []
        for (si, (seg, ms)) in zip(segments, motions).enumerated() {
            guard ms.count == seg.count, ms.first ?? nil != nil else { break }
            let base = m.path.value(atLocal: times[seg.lowerBound])
            var path = ms.compactMap { $0.map { base.transformed(by: $0) } }
            let lost = path.count < ms.count
            if !lost, anchors.contains(seg.upperBound - 1), path.count > 1 {
                let end = path[path.count - 1]
                let target = m.path.value(atLocal: times[seg.upperBound - 1])
                let n = Double(path.count - 1)
                for k in path.indices { path[k] = path[k].corrected(from: end, to: target, weight: Double(k) / n) }
            }
            // A range after the first starts on the anchor the one before ended on (already written).
            for (k, p) in path.enumerated() where si == 0 || k > 0 { written.append((times[seg.lowerBound + k], p)) }
            if lost { break }
        }
        guard let lo = written.map(\.0).min(), let hi = written.map(\.0).max() else { return 0 }
        updateMask(id) { m in
            for k in m.path.track.keys where k.time >= lo && k.time <= hi { m.path.track.remove(k.id) }
            for (t, p) in written { m.path.track.insert(Keyframe(time: t, value: p)) }
        }
        return written.count
    }
}
