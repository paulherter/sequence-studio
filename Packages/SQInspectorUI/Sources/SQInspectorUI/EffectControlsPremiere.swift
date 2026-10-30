import Foundation
import SQCore

/// Premiere handling on top of `EffectControlsModel`: key copy / paste, interpolation menu choices, snapping while
/// dragging keys, effect copy / paste, twirl-down memory per clip kind, Uniform Scale.

/// Which sections and rows of one clip are open. Session only: nothing is saved with the project or the app.
struct TwirlState: Equatable {
    var collapsed: Set<EffectSection>
    var expanded: Set<EffectProperty>
}

extension EffectControlsModel {
    // MARK: Twirl-down state per clip (session only)

    func saveTwirl() {
        guard let id = twirlClip else { return }
        twirlMemory[id] = TwirlState(collapsed: collapsedSections, expanded: expanded)
    }

    /// The state a clip starts with: its first section (Transform for video, Volume for audio) open, everything else closed.
    func defaultTwirl() -> TwirlState {
        TwirlState(collapsed: Set(visibleSections.dropFirst()), expanded: [])
    }

    /// Another clip is shown: it gets its own remembered state, or the default when it has none (a split-off half or a
    /// duplicate is a new clip and starts with the default, not with the state of the clip it came from).
    func adoptTwirl(for clipID: Clip.ID) {
        guard twirlClip != clipID else { return }
        twirlClip = clipID
        let st = twirlMemory[clipID] ?? defaultTwirl()
        collapsedSections = st.collapsed
        expanded = st.expanded
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
        var changed = 0
        withVector(&c, .scale) { prop in
            changed = prop.track.keys.filter { abs($0.value.x - $0.value.y) > 1e-9 }.count
            if changed == 0 && abs(prop.value.x - prop.value.y) > 1e-9 { changed = 1 }
            prop.value = Vec2(prop.value.x, prop.value.x)
            for k in prop.track.keys { prop.track.update(k.id) { $0.value = Vec2($0.value.x, $0.value.x) } }
        }
        commit(c, "Uniform Scale")
        if changed > 0 { onNotice?(SQL10n.plural(changed, one: "Height set to Width on %@ keyframe.", other: "Height set to Width on %@ keyframes.")) }
    }

    // MARK: Interpolation (right-click menu)

    public func applyInterpolation(_ choice: KeyInterpolationChoice) {
        if choice == .holdAhead, !selectionTakesHoldAhead { return }
        // Hold and Hold Ahead write the key's kind (a curve cannot say Hold Ahead), so they never go through a curve.
        let byChoice = choice.holdKind != nil || choice.smoothsSpatialPath || (choice.pairEase != nil && hasSelectedPair)
        guard byChoice, let c = workingClip, !selection.isEmpty else {
            applyEasing(choice.curve, side: choice.side); return
        }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        s.apply(choice, to: selection)
        forgetHeldKinds()
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Easing")
    }

    /// Spatial Interpolation (right-click menu): the path through the selected Position-like keys. Temporal easing
    /// stays as it is.
    public enum SpatialChoice: CaseIterable, Sendable { case linear, autoBezier, continuousBezier
        public var title: String {
            switch self { case .linear: "Linear"; case .autoBezier: "Auto Bezier"; case .continuousBezier: "Continuous Bezier" }
        }
    }

    public var hasSelectedVectorKey: Bool {
        guard let c = clip else { return false }
        return KeyframeSummary(tracks: Self.tracks(of: c)).hasVectorKey(selection)
    }

    public func applySpatialInterpolation(_ choice: SpatialChoice) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard s.hasVectorKey(selection) else { return }
        if choice == .linear { s.straightenSpatial(selection) } else { s.smoothSpatial(selection) }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Spatial Interpolation")
    }

    /// Two adjacent keys of one property are selected: Ease In / Out / In & Out then set both sides of the segment.
    public var hasSelectedPair: Bool {
        guard let c = clip else { return false }
        return KeyframeSummary(tracks: Self.tracks(of: c)).hasAdjacentPair(selection)
    }

    /// Eases the selected pair(s) (out of the first key, in of the second) as one undo step.
    public func applyPairEase(_ ease: PairEase) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard s.applyPairEase(ease, to: selection) > 0 else { return }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Ease Keyframe Pair")
    }

    // MARK: Unified easing (curve popover)

    /// Segments touched by the key selection across all properties (computed from the clip as it was when a gesture
    /// began, so a drag keeps acting on the same segments).
    public var easeSelection: EaseSelection {
        guard let c = workingClip else { return EaseSelection(summary: KeyframeSummary(tracks: [:]), members: []) }
        return EaseSelection(summary: KeyframeSummary(tracks: Self.tracks(of: c)), members: selection, stepped: Self.steppedProperties(in: c))
    }

    /// Checkbox / choice parameters: hold-only, never eased.
    static func steppedProperties(in c: Clip) -> Set<PropertyID> {
        Set(allProperties(in: c).filter { $0.paramKind?.isStepped == true }.map(\.id))
    }

    /// Common curve of the selected segments, or the distinct curves when they differ.
    public var easeReading: EaseReading {
        guard let c = clip else { return .empty }
        let s = KeyframeSummary(tracks: Self.tracks(of: c))
        return EaseSelection(summary: s, members: selection, stepped: Self.steppedProperties(in: c)).reading(in: s)
    }

    /// Writes one curve to every selected segment: one undo step (inside a gesture, the whole drag is one step).
    public func applyEaseShape(_ shape: EaseShape) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard EaseSelection(summary: s, members: selection, stepped: Self.steppedProperties(in: c)).apply(shape, to: &s) > 0 else { return }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Easing")
    }

    /// Spring presets bake plain linear keys into every selected segment (the file format has no spring): one undo step.
    public func applySpring(_ spring: SpringEasing) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard EaseSelection(summary: s, members: selection, stepped: Self.steppedProperties(in: c)).bake(spring, in: &s) > 0 else { return }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Apply Spring")
    }

    /// "Custom Curve...": makes the selected keys Bezier (if none is yet), opens the graph under each property of the
    /// selection (twirl) in the value graph, where the selected keys show their handles.
    public func revealCustomCurve() {
        guard let c = workingClip, !selection.isEmpty else { return }
        let tracks = Self.tracks(of: c)
        let anyBezier = selection.contains { m in tracks[m.property]?.interpolation(of: m.keyID) == .bezier }
        if !anyBezier { applyEasing(KeyInterpolationChoice.bezier.curve, side: .both) }
        let ids = Set(selection.map(\.property))
        let props = Self.allProperties(in: c).filter { ids.contains($0.id) }
        expanded.formUnion(props)
        graphMode = .speed          // the opened row is the speed graph only
        for p in props { graphModeByProperty[p] = .speed }
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
        // Mask Paths take keys too (they have no row of their own: their keys sit on the mask's controls row).
        let paths = visibleSections.compactMap { s -> PropertyID? in
            guard case .mask(let id) = s, clip?.mask(id)?.source == .path else { return nil }
            return EffectProperty.maskPath(id).id
        }
        let valid = Set(panelProperties.map(\.id)).union(paths)
        if cb.propertyIDs.count == 1, let f = focusedProperty, valid.contains(f.id),
           let r = cb.retargeted(to: f.id, isVector: f.kind == .vector || f.kind == .uniform, isColor: f.kind == .color,
                                 isPath: f.maskPathID != nil) { return r }
        let usable = cb.propertyIDs.filter { valid.contains($0) }
        return usable.count == cb.propertyIDs.count ? cb : nil
    }

    /// Cmd+V: the earliest copied key lands at the playhead; keys at the same time are replaced; keys past the clip end
    /// are dropped. Works across clips and, for one copied property, onto any property of the same value type.
    @discardableResult
    public func pasteKeys() -> Bool {
        guard let c = clip else { return false }
        guard playheadInClip else {
            onNotice?("Move the playhead onto the clip to paste keyframes.")
            return false
        }
        guard let cb = pasteTargets() else { return false }
        var tracks = Self.tracks(of: c)
        guard cb.paste(into: &tracks, at: localPlayhead, within: .zero ... duration) else { return false }
        var out = c
        // A pair row takes the keys member by member: only the member that mirrored a copied hold leads one again.
        let pairs = Self.allProperties(in: c).filter { $0.pair != nil && cb.propertyIDs.contains($0.id) }
        var plain = tracks
        for p in pairs { plain[p.id] = nil }
        write(plain, into: &out)
        let at = localPlayhead, range = Time.zero ... duration
        for p in pairs { Self.withPair(&out, p) { x, y in cb.pastePair(p.id, x: &x, y: &y, at: at, within: range) } }
        if !pairs.isEmpty { tracks = Self.tracks(of: out) }
        // The pasted keys become the selection, so a follow-up drag or interpolation change acts on them.
        let before = Self.tracks(of: c)
        var picked = Set<SummaryMember>()
        for (p, t) in tracks where cb.propertyIDs.contains(p) {
            let old = Set(before[p]?.keyIDs ?? [])
            for id in t.keyIDs where !old.contains(id) { picked.insert(SummaryMember(property: p, keyID: id)) }
        }
        guard !picked.isEmpty else {
            onNotice?("The copied keyframes fall after the end of the clip. Move the playhead earlier.")
            return false
        }
        commit(out, "Paste Keyframes")
        select(Array(picked), extend: false)
        if picked.count < cb.keyCount { onNotice?(SQL10n.plural(cb.keyCount - picked.count, one: "%@ keyframe past the end of the clip was not pasted.", other: "%@ keyframes past the end of the clip were not pasted.")) }
        return out != c
    }

    // MARK: Snapping while dragging keys (Shift)

    /// `delta` moved so the dragged keys stick to the playhead, the clip ends and keys that do not move, within
    /// `thresholdSeconds`. Computed from the clip as it was when the gesture began.
    public func snappedMoveDelta(_ delta: Time, thresholdSeconds: Double) -> Time {
        guard let c = workingClip else { return delta }
        let all = Self.tracks(of: c)
        var moving: [Time] = [], fixed: [Time] = [.zero, c.duration]
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

    /// Keyframes were copied last and are still on the clipboard: Cmd+V stays in Effect Controls even when they do not fit.
    public var hasKeyClipboard: Bool { lastCopyWasKeys && keyClipboard != nil }

    public var canCopyFocused: Bool { !selection.isEmpty || selectedSection.map(canCopyEffect) == true }
    public var canPasteFocused: Bool { lastCopyWasKeys ? canPasteKeys : canPasteEffect }

    /// Cmd+V: what was copied last, keys at the playhead or the effect onto this clip.
    @discardableResult
    public func pasteFocused() -> Bool { lastCopyWasKeys ? pasteKeys() : pasteEffect() }

    /// Cmd+X: copy, then delete what was copied.
    public var canCutFocused: Bool {
        !selection.isEmpty || selectedSection.map(canRemoveEffect) == true
    }

    public func cutFocused() {
        guard canCutFocused, copyFocused() else { return }
        deleteSelectionOrEffect()
    }

    // MARK: Copy / paste effects

    private var canPasteBuiltInCopy: Bool {
        if let h = canPasteBuiltIn { return h() }
        guard let b = builtInCopy, let g = BuiltInClipboard.group(for: b.section), let c = clip else { return false }
        return g.kind == c.kind
    }

    /// Cmd+V after copying Transform / Blend / Volume: values and keyframes replace the same group on the selected clips
    /// (the session), or on the shown clip when no session is wired.
    private func pasteBuiltInCopy() -> Bool {
        guard let b = builtInCopy, let g = BuiltInClipboard.group(for: b.section) else { return false }
        if let h = onPasteBuiltIn { return h() }
        guard let c = clip, g.kind == c.kind else { return false }
        let out = c.pastingAttributes(from: b.clip, groups: [g])
        guard out != c else { return false }
        commit(out, "Paste \(b.section.title)")
        return true
    }

    public func copyEffect(_ s: EffectSection) -> Bool {
        if BuiltInClipboard.group(for: s) != nil {
            guard canCopyEffect(s), let c = clip else { return false }
            builtInCopy = (s, c)
            effectClipboard = nil
            onBuiltInCopied?(s, c)
            return true
        }
        guard let id = s.effectID, let e = clip?.effects.first(where: { $0.id == id }) else { return false }
        effectClipboard = e
        builtInCopy = nil
        onEffectCopied?(e)
        return true
    }

    public var canPasteEffect: Bool {
        if builtInCopy != nil { return canPasteBuiltInCopy }
        guard let e = effectClipboard, let c = clip else { return false }
        if e.isAudio && showsAudioPartner { return true }      // lands on the linked audio clip (AUDIO-FX)
        return c.canAcceptPastedEffect(e)
    }

    /// Adds the copied effect to the clip as a new instance behind the existing ones (Premiere adds, it does not replace).
    /// A generator-owned effect replaces the clip's own instance instead (a shape has exactly one Shape effect).
    /// A Color effect goes behind the clip's Color effects (color stays first; see `Clip.insertPastedEffect`).
    @discardableResult
    public func pasteEffect() -> Bool {
        if builtInCopy != nil { return pasteBuiltInCopy() }
        guard canPasteEffect, var c = clip, var e = effectClipboard else { return false }
        if EffectCatalog.isGeneratorOwned(e.kind) {
            e.id = UUID()
            if let i = c.effects.firstIndex(where: { $0.kind == e.kind }) { c.effects[i] = e } else { c.effects.insert(e, at: 0) }
        } else if e.isAudio && showsAudioPartner {
            e.id = UUID(); c.effects.append(e)                 // the partner's audio effects are last; `commit` routes it
        } else {
            guard c.insertPastedEffect(e) else { return false }
        }
        commit(c, "Paste Effect")
        return true
    }
}

/// Which handler gets Cut / Copy / Paste: Effect Controls only when the first responder is inside it, or when it is the
/// focused panel and has something to do. Otherwise the normal (timeline) command runs.
public enum EffectControlsEditRouting {
    public static func effectControlsHandles(responderInside: Bool, panelFocused: Bool, canAct: Bool) -> Bool {
        responderInside || (panelFocused && canAct)
    }
}
