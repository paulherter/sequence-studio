import Foundation
import SSCore

/// Premiere handling on top of `EffectControlsModel`: key copy / paste, interpolation menu choices, snapping while
/// dragging keys, effect copy / paste, twirl-down memory per clip kind, Uniform Scale.

struct TwirlState: Codable, Equatable {
    var collapsed: [String]
    var expanded: [String]
}

extension EffectControlsModel {
    // MARK: Twirl-down state per clip kind

    private static func twirlDefaultsKey(_ kind: String) -> String { "effectControls.twirl.\(kind)" }

    func saveTwirl() {
        guard let k = twirlKind else { return }
        let st = TwirlState(collapsed: collapsedSections.map(\.rawValue).sorted(), expanded: expanded.map(\.rawValue).sorted())
        twirlMemory[k] = st
        if let d = twirlDefaults, let data = try? JSONEncoder().encode(st) { d.set(data, forKey: Self.twirlDefaultsKey(k)) }
    }

    /// A clip of another kind is shown: its own remembered twirl state replaces the current one.
    func adoptTwirl(for kind: TrackKind) {
        let k = kind.rawValue
        guard twirlKind != k else { return }
        let first = twirlKind == nil
        twirlKind = k
        var st = twirlMemory[k]
        if st == nil, let d = twirlDefaults, let data = d.data(forKey: Self.twirlDefaultsKey(k)) {
            st = try? JSONDecoder().decode(TwirlState.self, from: data)
        }
        if let st {
            collapsedSections = Set(st.collapsed.compactMap(EffectSection.init(rawValue:)))
            expanded = Set(st.expanded.compactMap(EffectProperty.init(rawValue:)))
        } else if !first {
            collapsedSections = []; expanded = []
        }
        saveTwirl()
    }

    // MARK: Uniform Scale

    static func isUniformScale(_ c: Clip, at t: Time) -> Bool {
        let s = c.animation.scale
        if abs(s.value.x - s.value.y) > 1e-9 { return false }
        return s.track.keys.allSatisfy { abs($0.value.x - $0.value.y) < 1e-9 }
    }

    /// Checked: Width and Height are one value again (an unequal pair takes Width for both).
    public func setUniformScale(_ on: Bool) {
        guard on != uniformScale else { return }
        uniformScale = on
        guard on, var c = clip, !Self.isUniformScale(c, at: .zero) else { return }
        withVector(&c, .scale) { prop in
            prop.value = Vec2(prop.value.x, prop.value.x)
            for k in prop.track.keys { prop.track.update(k.id) { $0.value = Vec2($0.value.x, $0.value.x) } }
        }
        commit(c, "Uniform Scale")
    }

    // MARK: Interpolation (right-click menu)

    public func applyInterpolation(_ choice: KeyInterpolationChoice) {
        applyEasing(choice.curve, side: choice.side)
    }

    // MARK: Copy / paste keys

    public var canCopyKeys: Bool { !selection.isEmpty }
    public var canPasteKeys: Bool { keyClipboard != nil && playheadInClip && pasteTargets() != nil }

    @discardableResult
    public func copyKeys() -> Bool {
        guard let c = clip, !selection.isEmpty else { return false }
        var sel: [PropertyID: Set<UUID>] = [:]
        for m in selection { sel[m.property, default: []].insert(m.keyID) }
        guard let cb = KeyframeClipboard.copy(from: Self.tracks(of: c), selection: sel) else { return false }
        keyClipboard = cb
        return true
    }

    /// Clipboard as it would land on this clip: same properties, or one property retargeted to the focused row.
    private func pasteTargets() -> KeyframeClipboard? {
        guard let cb = keyClipboard, clip != nil else { return nil }
        let valid = Set(visibleSections.flatMap(\.properties).map(\.id))
        if cb.propertyIDs.count == 1, let f = focusedProperty, valid.contains(f.id),
           let r = cb.retargeted(to: f.id, isVector: f.kind != .scalar) { return r }
        let usable = cb.propertyIDs.filter { valid.contains($0) }
        return usable.count == cb.propertyIDs.count ? cb : nil
    }

    /// Cmd+V: the earliest copied key lands at the playhead; keys at the same time are replaced; keys past the clip end
    /// are dropped. Works across clips and, for one copied property, onto any property of the same value type.
    @discardableResult
    public func pasteKeys() -> Bool {
        guard let c = clip, playheadInClip, let cb = pasteTargets() else { return false }
        var tracks = Self.tracks(of: c)
        guard cb.paste(into: &tracks, at: localPlayhead, within: .zero ... duration) else { return false }
        var out = c
        write(tracks, into: &out)
        // The pasted keys become the selection, so a follow-up drag or interpolation change acts on them.
        let before = Self.tracks(of: c)
        var picked = Set<SummaryMember>()
        for (p, t) in tracks where cb.propertyIDs.contains(p) {
            let old = Set(before[p]?.keyIDs ?? [])
            for id in t.keyIDs where !old.contains(id) { picked.insert(SummaryMember(property: p, keyID: id)) }
        }
        commit(out, "Paste Keyframes")
        select(Array(picked), extend: false)
        return out != c
    }

    // MARK: Snapping while dragging keys (Shift)

    /// `delta` moved so the dragged keys stick to the playhead, the clip ends and keys that do not move, within
    /// `thresholdSeconds`. Computed from the clip as it was when the gesture began.
    public func snappedMoveDelta(_ delta: Time, thresholdSeconds: Double) -> Time {
        guard let c = workingClip else { return delta }
        let all = Self.tracks(of: c)
        var moving: [Time] = [], fixed: [Time] = [.zero, c.source.duration]
        if playheadInClip { fixed.append(localPlayhead) }
        for (p, t) in all {
            for k in t.times {
                if selection.contains(SummaryMember(property: p, keyID: k.id)) { moving.append(k.time) } else { fixed.append(k.time) }
            }
        }
        var best = delta
        var bestDist = thresholdSeconds
        for m in moving {
            for f in fixed {
                let d = f - m
                let dist = abs(Double((d - delta).value) / Double(max((d - delta).timescale, 1)))
                if dist <= bestDist { bestDist = dist; best = d }
            }
        }
        return best
    }

    // MARK: Edit menu while Effect Controls has focus

    /// Cmd+C: the selected keyframes, else the selected effect. Returns false when there is nothing to copy.
    @discardableResult
    public func copyFocused() -> Bool {
        if !selection.isEmpty { return copyKeys() && markCopied(keys: true) }
        if let s = selectedSection, copyEffect(s) { return markCopied(keys: false) }
        return false
    }
    private func markCopied(keys: Bool) -> Bool { lastCopyWasKeys = keys; return true }

    public var canCopyFocused: Bool { !selection.isEmpty || selectedSection.map { clip?.effect(ofKind: $0.effectKind ?? "") != nil } == true }
    public var canPasteFocused: Bool { lastCopyWasKeys ? canPasteKeys : canPasteEffect }

    /// Cmd+V: what was copied last, keys at the playhead or the effect onto this clip.
    @discardableResult
    public func pasteFocused() -> Bool { lastCopyWasKeys ? pasteKeys() : pasteEffect() }

    /// Cmd+X: copy, then delete what was copied.
    public func cutFocused() {
        guard copyFocused() else { return }
        deleteSelectionOrEffect()
    }

    // MARK: Copy / paste effects

    public func copyEffect(_ s: EffectSection) -> Bool {
        guard let k = s.effectKind, let e = clip?.effect(ofKind: k) else { return false }
        effectClipboard = e
        return true
    }

    public var canPasteEffect: Bool {
        guard let e = effectClipboard, let c = clip else { return false }
        return c.kind == .video && e.kind == ClipEffect.roundedCornersKind
    }

    /// Adds the copied effect to the clip, or replaces the values of the one it already has.
    @discardableResult
    public func pasteEffect() -> Bool {
        guard canPasteEffect, var c = clip, let e = effectClipboard else { return false }
        var copy = e
        if let existing = c.effect(ofKind: e.kind) { copy.id = existing.id } else { copy.id = UUID() }
        c.roundedCorners = copy
        commit(c, "Paste Effect")
        return true
    }
}
