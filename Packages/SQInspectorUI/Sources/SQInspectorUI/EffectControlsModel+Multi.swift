import Foundation
import SQCore

/// Multi-select editing (Premiere): with several clips selected Effect Controls shows the first (by start) and its
/// `peers`. A field shows the value when every clip has it at the playhead (each clip at its own local time), an empty
/// field when they differ; an edit sets that one value on all of them in one undo step (`onEditMany`). An effect section
/// shows when the shown clip and at least one other selected clip have an effect of that kind at that occurrence; its edits
/// go to the clips that have it, the others are left alone (and not compared for the mixed state). Transform's Crop rows map
/// to each clip's first Crop and add one where it is missing. The stopwatch and the add / remove key button key every
/// clip at its own playhead (clamped into the clip) in one step; Speed, masks and the linked-audio group stay single-clip,
/// and key drags, graphs and key copy / paste work on the shown clip.
extension EffectControlsModel {
    public var isMulti: Bool { !peers.isEmpty }

    /// Follows a selection of several clips. False when the selection is one clip (or one linked pair): the single path runs.
    func syncMulti(with session: EditorSession) -> Bool {
        let clips = session.selectedEditClips
        guard clips.count > 1 else { return false }
        let sound = clips.filter { $0.kind == .audio }.count
        // Picture and sound-only clips share nothing Effect Controls could edit together.
        if sound == 0 || sound == clips.count { setClip(clips[0], peers: Array(clips.dropFirst())) } else { setClip(nil) }
        return true
    }

    /// The Custom sides every selected clip has: only these show rows in a multi-selection (a side that is Off or plays
    /// a preset in some clip has no keys to edit there). A row's value reads mixed where the clips differ (`isMixed`).
    func sharedCustomSides() -> [AnimationSide] {
        guard let c = clip else { return [] }
        return Self.customSides(of: c).filter { side in peers.allSatisfy { Self.customSides(of: $0).contains(side) } }
    }

    /// Some peer has an effect matching `id` of the shown clip: there is something to edit together.
    func sharedByAnyPeer(_ id: ClipEffect.ID) -> Bool {
        guard let c = clip else { return false }
        return peers.contains { $0.matchingEffectID(for: id, in: c) != nil }
    }

    /// `p` of the shown clip as the same property of `peer`; nil when the peer has no such property (masks, missing effect).
    func mapped(_ p: EffectProperty, to peer: Clip) -> EffectProperty? {
        switch p {
        case .fx(let id, let kind, let key):
            guard let c = clip else { return nil }
            // Transform's Crop rows: the peer's first Crop (or the one they add to it).
            if kind == ClipEffect.cropKind, id == Self.transformCropID(in: c) {
                return Self.transformCropID(in: peer).map { .fx($0, kind: kind, key: key) }
            }
            guard let m = peer.matchingEffectID(for: id, in: c) else { return nil }
            return .fx(m, kind: kind, key: key)
        case .mask: return nil
        case .anim(let side, _): return Self.customSides(of: peer).contains(side) ? p : nil      // a peer's own Custom side
        default: return p
        }
    }

    /// Section `s` of the shown clip as the same section of `peer`; nil when the peer has none (an effect it lacks, a mask).
    func mappedSection(_ s: EffectSection, to peer: Clip) -> EffectSection? {
        switch s {
        case .motion, .opacity, .volume: return s
        case .speed, .mask: return nil
        case .animation(let side): return Self.customSides(of: peer).contains(side) ? s : nil
        case .effect(let id, let kind):
            guard let c = clip, let m = peer.matchingEffectID(for: id, in: c) else { return nil }
            return .effect(m, kind: kind)
        }
    }

    /// The fx switch of `s` is on in some selected clips that have the section and off in others.
    public func isEffectEnabledMixed(_ s: EffectSection) -> Bool {
        guard isMulti, let c = clip, let mine = Self.enabled(s, in: c) else { return false }
        return peers.contains { peer in mappedSection(s, to: peer).flatMap { Self.enabled($0, in: peer) }.map { $0 != mine } ?? false }
    }

    /// The fx switch was clicked: flips it, or turns it on everywhere while it is mixed.
    public func toggleEffectEnabled(_ s: EffectSection) {
        setEffectEnabled(s, isEffectEnabledMixed(s) || !isEffectEnabled(s))
    }

    private static func enabled(_ s: EffectSection, in c: Clip) -> Bool? {
        switch s {
        case .motion: return c.motionEnabled && c.opacityEnabled
        case .opacity: return c.opacityEnabled
        case .volume, .speed, .animation: return nil
        case .effect(let id, _): return c.effects.first { $0.id == id }?.enabled
        case .mask(let id): return c.mask(id)?.enabled
        }
    }

    /// The selected clips use different blend modes: the popup shows nothing picked.
    public var isBlendModeMixed: Bool {
        guard isMulti, let c = clip else { return false }
        return peers.contains { $0.kind == .video && $0.blendMode != c.blendMode }
    }

    /// The peers (from the gesture's base inside a gesture) with `body` applied to each, given the mapped property, the
    /// peer's own local playhead and whether that lies inside it. nil when there are no peers.
    func editedPeers(_ p: EffectProperty, _ body: (inout Clip, EffectProperty, Time, Bool) -> Void) -> [Clip]? {
        guard isMulti else { return nil }
        return (peerGestureBase ?? peers).map { peer in
            var c = peer
            if let q = mapped(p, to: peer) {
                let l = playhead - peer.start
                body(&c, q, l, l >= .zero && l <= peer.duration)
            }
            return c
        }
    }

    /// True when the selected clips show different values of `p` (or of one component of it) at the playhead: the field is empty.
    public func isMixed(_ p: EffectProperty, component: EffectComponent = .all) -> Bool {
        guard isMulti, let c = clip else { return false }
        let mine = Self.reading(p, in: c, at: localPlayhead)
        for peer in peers {
            guard let q = mapped(p, to: peer) else { continue }
            if !Self.same(mine, Self.reading(q, in: peer, at: playhead - peer.start), component) { return true }
        }
        return false
    }

    enum Reading: Equatable { case scalar(Double), vector(Vec2), color(EffectColor), none }

    static func reading(_ p: EffectProperty, in c: Clip, at l: Time) -> Reading {
        let a = c.animation
        switch p {
        case .position: return .vector(a.position.value(atLocal: l))
        case .scale: return .vector(a.scale.value(atLocal: l))
        case .anchor: return .vector(a.anchor.value(atLocal: l))
        case .rotation: return .scalar(a.rotation.value(atLocal: l))
        case .tiltX: return .scalar(a.tiltX.value(atLocal: l))
        case .tiltY: return .scalar(a.tiltY.value(atLocal: l))
        case .opacity: return .scalar(a.opacity.value(atLocal: l))
        case .volume: return .scalar(a.volume.value(atLocal: l))
        case .shutterAngle: return .scalar(a.shutterAngle.value(atLocal: l))
        case .antiFlicker: return .scalar(a.antiFlicker.value(atLocal: l))
        case .mask: return maskParam(p, in: c).map { .scalar($0.value(atLocal: l)) } ?? .none
        case .maskPath: return .none
        case .anim(_, let param):
            if param == .position { return animVector(p, in: c).map { .vector($0.value(atLocal: l)) } ?? .none }
            return animScalar(p, in: c).map { .scalar($0.value(atLocal: l)) } ?? .none
        case .fx:
            switch p.kind {
            case .color: return colorParam(p, in: c).map { .color($0.value(atLocal: l)) } ?? .none
            case .vector: return pointParam(p, in: c).map { .vector($0.value(atLocal: l)) } ?? .none
            default:
                if let v = param(p, in: c) { return .scalar(v.value(atLocal: l)) }
                // A Crop not added yet, or a Softness an old Crop does not store: the default, like the rows show.
                guard case .fx(let id, let kind, let key) = p, kind == ClipEffect.cropKind,
                      isPendingCrop(p, in: c) || c.effects.contains(where: { $0.id == id }) else { return .none }
                return .scalar(EffectCatalog.param(kind, key)?.defaultValue ?? 0)
            }
        }
    }

    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(1, abs(a), abs(b)) }

    private static func same(_ a: Reading, _ b: Reading, _ component: EffectComponent) -> Bool {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return close(x, y)
        case let (.vector(u), .vector(v)):
            switch component {
            case .x: return close(u.x, v.x)
            case .y: return close(u.y, v.y)
            case .all: return close(u.x, v.x) && close(u.y, v.y)
            }
        default: return a == b
        }
    }
}
