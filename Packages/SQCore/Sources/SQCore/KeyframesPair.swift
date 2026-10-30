import Foundation

/// Two scalar tracks shown as one X/Y row (`EffectParamPair`: Transform / Auto Reframe Position and Anchor). Storage stays
/// two scalar tracks; the Stabilizer writes them with different key times. A pair is *aligned* when both members have keys
/// at the same times with the same interpolation and ease handles: then it reads as one Vec2 track (`zipped`) and the graph
/// draws one speed curve (|delta| x ease'), otherwise two. Every edit through a pair row writes both members aligned.
public enum KeyframesPair {
    /// Same key times, interpolation and ease handles, key by key. Two unanimated members are aligned.
    public static func isAligned(_ x: AnimatedProperty<Double>, _ y: AnimatedProperty<Double>) -> Bool {
        let a = x.track.keys, b = y.track.keys
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { sameShape($0, $1) }
    }

    /// Both members with keys at the union of their key times. A key is inserted into a member so that the member's own
    /// curve stays exactly as it was (see `insertingKeepingCurve`, which may rewrite the handles around the new key).
    /// Then, on the split tracks and in time order, each side of every key is settled on its own: the out side (kind
    /// and out-handle) over the stretch to the next key, the in side (in-handle) over the stretch from the previous key.
    /// A member that does not change over that stretch takes the side of the one that does (both flat: Y takes X's).
    /// An in side behind a Hold is not part of the curve, but its handle is what un-holding brings back, so it is never
    /// overwritten. Where both change, both stay: aligning never changes a curve, and aligning its result again changes
    /// nothing. Existing keys keep ids and values. The result is aligned when the curves allow it (linear and constant
    /// stretches always do); otherwise the graph draws two curves, and a pair row edit (`edit`) gives Y X's shape there.
    public static func aligning(_ x: AnimatedProperty<Double>, _ y: AnimatedProperty<Double>)
        -> (x: AnimatedProperty<Double>, y: AnimatedProperty<Double>) {
        if isAligned(x, y) { return (x, y) }
        var ax = x, ay = y
        let xTimes = Set(x.track.keys.map(\.time)), yTimes = Set(y.track.keys.map(\.time))
        for k in x.track.keys where !yTimes.contains(k.time) { ay.insertingKeepingCurve(at: k.time, partner: k) }
        for k in y.track.keys where !xTimes.contains(k.time) { ax.insertingKeepingCurve(at: k.time, partner: k) }
        for i in ax.track.keys.indices {
            var kx = ax.track.keys[i], ky = ay.track.keys[i]
            if kx.inHandle != ky.inHandle {
                if inSideIsFlat(i, ay.track) { ay.track.update(ky.id) { $0.inHandle = kx.inHandle } }
                else if inSideIsFlat(i, ax.track) { ax.track.update(kx.id) { $0.inHandle = ky.inHandle } }
            }
            kx = ax.track.keys[i]; ky = ay.track.keys[i]
            if kx.interpolation != ky.interpolation || kx.outHandle != ky.outHandle {
                if outSideIsFlat(i, ay.track) {
                    ay.track.update(ky.id) { $0.interpolation = kx.interpolation; $0.outHandle = kx.outHandle }
                } else if outSideIsFlat(i, ax.track) {
                    ax.track.update(kx.id) { $0.interpolation = ky.interpolation; $0.outHandle = ky.outHandle }
                }
            }
        }
        return (ax, ay)
    }

    /// The pair as one Vec2 property (keys take X's ids, interpolation and handles; straight spatial path), or nil when
    /// not aligned. Evaluates to (x(t), y(t)) exactly: both members share the eased progress of every segment.
    public static func zipped(_ x: AnimatedProperty<Double>, _ y: AnimatedProperty<Double>) -> AnimatedProperty<Vec2>? {
        guard isAligned(x, y) else { return nil }
        return AnimatedProperty(Vec2(x.value, y.value), track: zippedTrack(x.track, y.track))
    }

    /// The pair as one editable Vec2 property, always: `aligning` first, then Y takes X's interpolation and handles at
    /// every key (only matters for the rare eased split `aligning` cannot keep aligned). Keys carry X's ids. Used by the
    /// X/Y pair rows in Effect Controls; read the exact current value from the members, not from this.
    public static func editable(_ x: AnimatedProperty<Double>, _ y: AnimatedProperty<Double>) -> AnimatedProperty<Vec2> {
        let (ax, ay) = alignedForEdit(x, y)
        return AnimatedProperty(Vec2(ax.value, ay.value), track: zippedTrack(ax.track, ay.track))
    }

    /// The two members `editable` zips: aligned, Y with X's shapes.
    private static func alignedForEdit(_ x: AnimatedProperty<Double>, _ y: AnimatedProperty<Double>)
        -> (x: AnimatedProperty<Double>, y: AnimatedProperty<Double>) {
        var (ax, ay) = aligning(x, y)
        for (kx, ky) in zip(ax.track.keys, ay.track.keys) where !sameShape(kx, ky) {
            ay.track.update(ky.id) { copyShape(kx, into: &$0) }
        }
        return (ax, ay)
    }

    /// The keys of both members zipped (X's ids and shapes).
    private static func zippedTrack(_ x: KeyframeTrack<Double>, _ y: KeyframeTrack<Double>) -> KeyframeTrack<Vec2> {
        KeyframeTrack(keys: zip(x.keys, y.keys).map { a, b in
            Keyframe(id: a.id, time: a.time, value: Vec2(a.value, b.value), interpolation: a.interpolation,
                     inHandle: a.inHandle, outHandle: a.outHandle)
        })
    }

    /// Splits a Vec2 pair property back into its two scalar members. X keys keep the Vec2 key ids; Y keys reuse the id
    /// of `yIDsFrom`'s key at the same time, else get a fresh id (members never share key ids).
    public static func split(_ v: AnimatedProperty<Vec2>, yIDsFrom y: AnimatedProperty<Double>)
        -> (x: AnimatedProperty<Double>, y: AnimatedProperty<Double>) {
        let yIDs = Dictionary(y.track.keys.map { ($0.time, $0.id) }, uniquingKeysWith: { a, _ in a })
        let xs = v.track.keys.map { k in
            Keyframe(id: k.id, time: k.time, value: k.value.x, interpolation: k.interpolation,
                     inHandle: k.inHandle, outHandle: k.outHandle)
        }
        let ys = v.track.keys.map { k in
            Keyframe(id: yIDs[k.time] ?? UUID(), time: k.time, value: k.value.y, interpolation: k.interpolation,
                     inHandle: k.inHandle, outHandle: k.outHandle)
        }
        return (AnimatedProperty(v.value.x, track: KeyframeTrack(keys: xs)), AnimatedProperty(v.value.y, track: KeyframeTrack(keys: ys)))
    }

    /// One edit through a pair row: both members as one Vec2 property (`editable`), written back aligned (`split`).
    public static func edit(_ x: inout AnimatedProperty<Double>, _ y: inout AnimatedProperty<Double>,
                            _ body: (inout AnimatedProperty<Vec2>) -> Void) {
        let (ax, ay) = alignedForEdit(x, y)
        var v = AnimatedProperty(Vec2(ax.value, ay.value), track: zippedTrack(ax.track, ay.track))
        body(&v)
        (x, y) = split(v, yIDsFrom: y)
    }

    /// A paste through a pair row: both members take their part of every key, aligned. X keys carry the ids of `keys`,
    /// Y keys fresh ones (or the one of the key they replace).
    static func paste(_ keys: [Keyframe<Vec2>], x: inout AnimatedProperty<Double>, y: inout AnimatedProperty<Double>) {
        guard !keys.isEmpty else { return }
        edit(&x, &y) { v in for k in keys { v.track.insert(k) } }
    }

    /// The track does not change from key `i` to its next key (or `i` is the last one): any kind and out-handle on it
    /// give the same curve.
    private static func outSideIsFlat(_ i: Int, _ track: KeyframeTrack<Double>) -> Bool {
        let keys = track.keys
        return i + 1 >= keys.count || keys[i + 1].value == keys[i].value
    }

    /// The track does not change from the key before key `i` (or `i` is the first one): any in-handle on it gives the
    /// same curve. A Hold before a changing key does not count: the handle is not drawn, but un-holding brings it back.
    private static func inSideIsFlat(_ i: Int, _ track: KeyframeTrack<Double>) -> Bool {
        let keys = track.keys
        return i == 0 || keys[i - 1].value == keys[i].value
    }

    private static func sameShape(_ a: Keyframe<Double>, _ b: Keyframe<Double>) -> Bool {
        a.time == b.time && a.interpolation == b.interpolation && a.inHandle == b.inHandle && a.outHandle == b.outHandle
    }

    static func copyShape(_ from: Keyframe<Double>, into k: inout Keyframe<Double>) {
        k.interpolation = from.interpolation; k.inHandle = from.inHandle; k.outHandle = from.outHandle
    }
}

extension AnimatedProperty where V == Double {
    /// Inserts a key at `t` (no-op if one exists) without changing the evaluated curve. `partner`'s shape is used where
    /// any shape gives the same curve (constant stretch). Inside a Hold segment the key holds; inside a linear segment it
    /// is linear; inside an eased segment the segment's timing bezier is split (de Casteljau) and both halves get
    /// renormalised handles. Only if the split point's progress is exactly 0 or 1 on a non-constant segment (overshoot
    /// handles) can a half not be renormalised: then the key is value-exact at `t` and that half becomes linear.
    mutating func insertingKeepingCurve(at t: Time, partner: Keyframe<Double>) {
        let keys = track.keys
        guard !keys.contains(where: { $0.time == t }) else { return }
        var k = Keyframe(time: t, value: value(atLocal: t))
        KeyframesPair.copyShape(partner, into: &k)
        guard let hi = keys.firstIndex(where: { $0.time > t }), hi > 0 else { track.insert(k); return }   // constant stretch
        let a = keys[hi - 1], b = keys[hi]
        if a.interpolation == .hold { k.interpolation = .hold; track.insert(k); return }
        // Constant from the new key on (equal neighbors, or a Hold Ahead: the key sits on the next key's value already):
        // any shape keeps it.
        if a.interpolation == .holdAhead || a.value == b.value { track.insert(k); return }
        k.interpolation = a.interpolation
        if a.outHandle == .linear && b.inHandle == .linear {
            k.inHandle = .linear; k.outHandle = .linear
            track.insert(k); return
        }
        // Timing bezier P0 (0,0), P1 (x1,y1), P2 (x2,y2), P3 (1,1) as `KeyframeMath.bezierProgress` reads the handles;
        // split at the parameter s whose x is the time fraction of `t`.
        let x1 = min(max(a.outHandle.dx, 0), 1), x2 = 1 - min(max(b.inHandle.dx, 0), 1)
        let y1 = a.outHandle.dy, y2 = 1 - b.inHandle.dy
        let s = KeyframeMath.solve(KeyframeMath.ratio(t - a.time, b.time - a.time), x1, x2)
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * s }
        let (l1x, l1y) = (mix(0, x1), mix(0, y1))
        let (cx, cy) = (mix(x1, x2), mix(y1, y2))
        let (r2x, r2y) = (mix(x2, 1), mix(y2, 1))
        let (l2x, l2y) = (mix(l1x, cx), mix(l1y, cy))
        let (r1x, r1y) = (mix(cx, r2x), mix(cy, r2y))
        let (mx, my) = (mix(l2x, r1x), mix(l2y, r1y))   // (time fraction, eased progress) at t
        var aOut = EaseHandle.linear, bIn = EaseHandle.linear
        k.inHandle = .linear; k.outHandle = .linear
        if mx > 0, my != 0 {
            aOut = EaseHandle(dx: l1x / mx, dy: l1y / my)
            k.inHandle = EaseHandle(dx: 1 - l2x / mx, dy: 1 - l2y / my)
        }
        if mx < 1, my != 1 {
            k.outHandle = EaseHandle(dx: (r1x - mx) / (1 - mx), dy: (r1y - my) / (1 - my))
            bIn = EaseHandle(dx: 1 - (r2x - mx) / (1 - mx), dy: 1 - (r2y - my) / (1 - my))
        }
        track.update(a.id) { $0.outHandle = aOut }
        track.update(b.id) { $0.inHandle = bIn }
        track.insert(k)
    }
}
