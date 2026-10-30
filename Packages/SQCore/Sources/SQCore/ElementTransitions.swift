import Foundation

// FB-G element transitions (v40). Move, Zoom and Pop act once at a clip edge, so they are transitions (the maintainer: no duplicate
// effects): a one-sided transition on the head (In) or the tail (Out) of a clip. They animate the clip itself, exactly like
// the Move / Zoom / Pop motion effects did: while a clip shows, every element transition on it becomes a synthesized motion
// effect (mode In or Out, duration = the resolved span) at the end of its effect list (`Track.videoEntries`). Outside the
// span the clip is at rest. Nothing is written into the clip, so trims, duration changes and undo just work.
// Parameters use the motion-effect keys; Zoom has one "Scale at Edge" value (rest is always 100 %), Pop settles at 100 %.
// Motion Blur (shutter in frames) becomes the effect's Shutter Angle (frames x 360 degrees, at most 360).

extension ClipEffect {
    /// Set only on the motion effect an element transition synthesizes: its span in seconds, used as the In / Out length
    /// without the 60 s limit of the effect's Duration. Never stored.
    static let elementSpanKey = "elementSpan"
}

extension TransitionKind {
    public static let elementKinds: [TransitionKind] = [.move, .zoom, .pop]

    /// Animates one clip at one edge (head / tail only, never across a cut).
    public var isElement: Bool { self == .move || self == .zoom || self == .pop }

    /// The motion effect an element transition evaluates as.
    public var elementEffectKind: String? {
        switch self {
        case .move: ClipEffect.moveKind
        case .zoom: ClipEffect.zoomKind
        case .pop: ClipEffect.popKind
        default: nil
        }
    }

    /// Zoom's single value: the scale at the clip edge (the clip rests at 100 %).
    public static let zoomEdgeSpec = EffectParamSpec(key: ClipEffect.zoomFromKey, title: "Scale at Edge", unit: "%",
                                                     defaultValue: 110, range: 0...10_000, step: 0.5, decimals: 1)

    /// The parameters a transition shows (Effect Controls) and stores (`Transition.params`): an element transition's
    /// (mode and durations come from the transition itself, Pop's Settle is 100 %) and Zoom In / Out's Amount.
    public var elementParams: [EffectParamSpec] {
        if isZoomThrough { return [Self.zoomAmountSpec] }
        guard let kind = elementEffectKind, let spec = EffectCatalog.spec(for: kind) else { return [] }
        let skip: Set<String> = [ClipEffect.motionModeKey, ClipEffect.motionDurationKey, ClipEffect.motionOutDurationKey,
                                 ClipEffect.popSettleKey]
        var out = spec.params.filter { !skip.contains($0.key) }
        if self == .zoom {
            out = out.filter { $0.key != ClipEffect.zoomFromKey && $0.key != ClipEffect.zoomToKey } + [Self.zoomEdgeSpec]
        }
        return out
    }

    func elementParam(_ key: String) -> EffectParamSpec? { elementParams.first { $0.key == key } }
}

extension Transition {
    /// Value of element parameter `key` (the default when unset), clamped to its range; 0 for an unknown key.
    public func param(_ key: String) -> Double {
        guard let spec = kind.elementParam(key) else { return params?[key] ?? 0 }
        let v = params?[key] ?? spec.defaultValue
        return min(max(v, spec.range.lowerBound), spec.range.upperBound)
    }

    /// The motion effect this element transition plays on its clip for a resolved span of `seconds`: In at the head, Out
    /// at the tail. nil for any other kind.
    func elementEffect(seconds: Double, motionBlur: Double) -> ClipEffect? {
        guard let kind = kind.elementEffectKind, var e = ClipEffect.make(kind: kind) else { return nil }
        let atHead = outgoing == nil
        func set(_ k: String, _ v: Double) { e.parameters[k] = AnimatedProperty(v) }
        e.id = id
        set(ClipEffect.motionModeKey, Double(atHead ? MotionMode.in.rawValue : MotionMode.out.rawValue))
        let span = max(seconds, 1e-6)
        set(ClipEffect.motionDurationKey, min(max(span, 0.01), 60))
        set(ClipEffect.motionOutDurationKey, 0)
        set(ClipEffect.elementSpanKey, span)
        for p in self.kind.elementParams where p.key != ClipEffect.zoomFromKey || self.kind != .zoom {
            // FB-T3: unset Direction / Rotation pop-ups keep the angle and the signed strength (Left / None look the same).
            if p.key == ClipEffect.moveSideKey || p.key == ClipEffect.moveSpinKey, params?[p.key] == nil { continue }
            set(p.key, param(p.key))
        }
        for k in ClipEffect.customCurveKeys { if let v = params?[k] { set(k, v) } }
        // Move's fade stays inside the span: the effect switches off at its end, a longer fade would jump to full there.
        if self.kind == .move { set(ClipEffect.moveFadeLengthKey, min(param(ClipEffect.moveFadeLengthKey), span)) }
        if self.kind == .zoom {
            let edge = param(ClipEffect.zoomFromKey)
            set(ClipEffect.zoomFromKey, atHead ? edge : 100)
            set(ClipEffect.zoomToKey, atHead ? 100 : edge)
        }
        if self.kind == .pop { set(ClipEffect.popSettleKey, 100) }
        let shutter = min(max(motionBlur, 0) * 360, 360)
        if shutter > 0 { set(ClipEffect.stageShutterAngleKey, shutter) }
        return e
    }
}

extension Track {
    /// `c` with the motion effects of the element transitions on it that can reach `t` (their span, widened by a frame for
    /// the motion-blur shutter). The stored clip is never changed.
    func clipWithElementTransitions(_ c: Clip, at t: Time, frameDuration fd: Time) -> Clip {
        var out = c
        for tr in transitions where tr.kind.isElement && (tr.incoming == c.id || tr.outgoing == c.id) {
            guard let r = resolve(tr, frameDuration: fd), t >= r.span.start - fd, t < r.span.end + fd,
                  let e = tr.elementEffect(seconds: KeyframeMath.seconds(r.span.duration), motionBlur: r.motionBlur) else { continue }
            out.effects.append(e)
        }
        return out
    }
}

extension Timeline {
    /// Sets parameters of element transition `id` (merged into what it has, each clamped to its range). Throws
    /// `.invalidFormat` for a kind without parameters or an unknown key; nothing changes then.
    /// `replacing`: `params` become the whole set (a preset's saved look), unset keys go back to their defaults.
    public mutating func setTransition(_ id: Transition.ID, params: [String: Double], replacing: Bool = false) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }),
              let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        var tr = tracks[ti].transitions[ni]
        var merged = replacing ? [:] : tr.params ?? [:]
        for (k, v) in params {
            // The Custom curve (not a row of its own): X 0...1, Y -2...3.
            if ClipEffect.customCurveKeys.contains(k), tr.kind.isElement, v.isFinite {
                merged[k] = k == ClipEffect.curveX1Key || k == ClipEffect.curveX2Key ? min(max(v, 0), 1) : min(max(v, -2), 3)
                continue
            }
            guard let spec = tr.kind.elementParam(k), v.isFinite else { throw EditError.invalidFormat }
            merged[k] = min(max(v, spec.range.lowerBound), spec.range.upperBound)
        }
        tr.params = merged.isEmpty ? nil : merged
        tracks[ti].transitions[ni] = tr
    }
}

extension Timeline {
    /// Length for an element transition on one end of a `clipDuration` clip; `bothEnds`: at most half the clip each, so
    /// In and Out both fit. Whole frames, at least one.
    public static func elementDuration(_ d: Time, clipDuration: Time, bothEnds: Bool, frameDuration fd: Time) -> Time {
        guard bothEnds else { return d }
        let half = max(1, clipDuration.frameIndex(frameDuration: fd) / 2)
        return min(d, fd * half)
    }

    /// Adds element transition `kind` to `edges` of `clip` (`duration` each; both ends share the clip half and half). An
    /// edge where no frame fits is skipped; `insufficientMedia` only when none fits. Returns the new IDs, head first.
    @discardableResult
    public mutating func addElementTransitions(kind: TransitionKind, track: Track.ID, clip: Clip.ID, edges: [ClipEdge],
                                               duration: Time) throws -> [Transition.ID] {
        guard kind.isElement else { throw EditError.notACut }
        guard let c = self.track(track)?.clip(clip) else { throw EditError.clipNotFound }
        let both = edges.contains(.head) && edges.contains(.tail)
        let d = Self.elementDuration(duration, clipDuration: c.duration, bothEnds: both, frameDuration: format.frameDuration)
        var made: [Transition.ID] = []
        for edge in [ClipEdge.head, .tail] where edges.contains(edge) {
            do { made.append(try addTransition(point: edge == .head ? .head(clip) : .tail(clip), kind: kind, track: track, duration: d)) }
            catch EditError.insufficientMedia { continue }
        }
        if made.isEmpty { throw EditError.insufficientMedia }
        return made
    }
}

extension Project {
    /// Some track holds a Move / Zoom / Pop transition (v40).
    public var containsElementTransitions: Bool {
        timelines.contains { $0.tracks.contains { $0.transitions.contains { $0.kind.isElement } } }
    }
}
