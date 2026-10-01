import Foundation
import Observation
import SSCore

// MARK: - Sections and properties

public enum EffectSection: String, CaseIterable, Sendable, Hashable {
    case motion, opacity, roundedCorners, volume

    public var title: String {
        switch self {
        case .motion: "Motion"
        case .opacity: "Opacity"
        case .roundedCorners: "Rounded Corners"
        case .volume: "Volume"
        }
    }

    /// Kind of the applied effect behind this section; nil for the built-in clip properties (always present).
    public var effectKind: String? {
        self == .roundedCorners ? ClipEffect.roundedCornersKind : nil
    }

    /// Animatable properties.
    public var properties: [EffectProperty] {
        switch self {
        case .motion: [.position, .scale, .rotation, .anchor]
        case .opacity: [.opacity]
        case .roundedCorners: [.cornerRadius]
        case .volume: [.volume]
        }
    }
}

public enum EffectProperty: String, CaseIterable, Sendable, Hashable {
    case position, scale, rotation, anchor, opacity, volume, cornerRadius

    public enum Kind: Sendable { case vector, uniform, scalar }

    public var kind: Kind {
        switch self {
        case .position, .anchor: .vector
        case .scale: .uniform
        case .rotation, .opacity, .volume, .cornerRadius: .scalar
        }
    }

    public var id: PropertyID { PropertyID(rawValue) }

    public var title: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .anchor: "Anchor Point"
        case .opacity: "Opacity"
        case .volume: "Volume"
        case .cornerRadius: "Radius"
        }
    }

    public var section: EffectSection {
        switch self {
        case .position, .scale, .rotation, .anchor: .motion
        case .opacity: .opacity
        case .volume: .volume
        case .cornerRadius: .roundedCorners
        }
    }

    // MARK: Display units (what the ScrubField shows)

    /// Volume is stored as linear gain and shown in dB; this is the dB shown for silence.
    public static let silenceDB = -60.0

    public func display(_ native: Double) -> Double {
        switch self {
        case .scale, .opacity: native * 100
        case .volume: native <= 0.001 ? Self.silenceDB : max(20 * log10(native), Self.silenceDB)
        default: native
        }
    }

    public func native(fromDisplay d: Double) -> Double {
        switch self {
        case .scale, .opacity: d / 100
        case .volume: d <= Self.silenceDB ? 0 : pow(10, d / 20)
        default: d
        }
    }

    public var displayUnit: String {
        switch self {
        case .scale, .opacity: "%"
        case .rotation: "\u{00B0}"
        case .cornerRadius: "px"
        case .volume: "dB"
        default: ""
        }
    }
    public var displayDecimals: Int {
        switch self {
        case .scale, .opacity, .position, .anchor: 1
        case .rotation: 1
        case .volume: 1
        case .cornerRadius: 0
        }
    }
    public var displayStep: Double {
        switch self {
        case .volume: 0.1
        case .position, .anchor, .cornerRadius: 1
        case .scale, .opacity: 0.5
        case .rotation: 0.5
        }
    }
    public var displayRange: ClosedRange<Double> {
        switch self {
        case .opacity: 0...100
        case .scale: 0...10_000
        case .cornerRadius: 0...10_000
        case .volume: Self.silenceDB...15
        default: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        }
    }
}

public enum EffectComponent: Sendable, Hashable { case x, y, all }

public enum StopwatchOutcome: Sendable, Equatable {
    case added, removed
    /// Turning the stopwatch off deletes all keys: the caller asks first, then repeats with `confirmRemoval: true`.
    case needsConfirmation
    /// Playhead outside the clip, or no clip.
    case unavailable
}

// MARK: - Model

/// State and edit logic of the Effect Controls panel for one clip. Every change produces a new `Clip`
/// value and goes out through `onEdit(clip, actionName, coalescing)`; the owner applies it (undo snapshot).
///
/// Coalescing: inside a gesture (`beginGesture` ... `endGesture`, e.g. one scrub drag or one lane drag)
/// the first edit has `coalescing == false` and all following ones `true`, so one gesture is one undo step.
/// Inside a gesture every edit is computed from the clip as it was at `beginGesture`, so steps never drift.
@MainActor @Observable
public final class EffectControlsModel {
    public private(set) var clip: Clip?
    /// Timeline time.
    public var playhead: Time = .zero
    public var frameDuration = Time(1, 30)
    public private(set) var selection: Set<SummaryMember> = []
    public var expanded: Set<EffectProperty> = []
    public var collapsedSections: Set<EffectSection> = []
    /// Section header last clicked: Delete removes its effect (when removable) if no keys are selected.
    public var selectedSection: EffectSection?
    public var graphMode: GraphMode = .speed
    public var easingLibrary = EasingLibrary()

    @ObservationIgnored public var onEdit: ((Clip, String, Bool) -> Void)?
    /// Jump the playhead (timeline time), e.g. for the prev/next key buttons.
    @ObservationIgnored public var onSeek: ((Time) -> Void)?
    @ObservationIgnored public var onLibraryChange: ((EasingLibrary) -> Void)?

    @ObservationIgnored private var gestureBase: Clip?
    @ObservationIgnored private var gestureEmitted = false

    public init() {}

    // MARK: Clip

    /// Sets the clip shown. Never calls `onEdit`. A different clip resets selection; the same clip prunes
    /// selected keys that no longer exist.
    public func setClip(_ c: Clip?) {
        if c?.id != clip?.id { selection = []; selectedSection = nil; gestureBase = nil; gestureEmitted = false }
        clip = c
        if let sec = selectedSection, !visibleSections.contains(sec) || sec.effectKind == nil { selectedSection = nil }
        pruneSelection()
    }

    /// Follows the session: the selected clip (or the video clip of a selected linked pair), nothing for no or a mixed
    /// selection. Called for every session change; cheap when nothing relevant changed.
    public func sync(with session: EditorSession, change: EditorSession.Change) {
        if change.contains(.project) || change.contains(.media) {
            let fd = session.activeTimeline?.frameDuration ?? frameDuration
            if fd != frameDuration { frameDuration = fd }
        }
        if change.contains(.selection) || change.contains(.project) { setClip(session.singleSelectedClip) }
        if change.contains(.playhead) || change.contains(.project), playhead != session.playhead { playhead = session.playhead }
    }

    public var visibleSections: [EffectSection] {
        guard let clip else { return [] }
        if clip.kind == .audio { return [.volume] }
        var out: [EffectSection] = [.motion, .opacity]
        if clip.roundedCorners != nil { out.append(.roundedCorners) }
        return out
    }

    public var duration: Time { clip?.source.duration ?? .zero }
    public var localPlayhead: Time { playhead - (clip?.start ?? .zero) }
    public var playheadInClip: Bool { clip != nil && localPlayhead >= .zero && localPlayhead <= duration }

    // MARK: Reading

    public func isAnimated(_ p: EffectProperty) -> Bool { track(p, in: clip).map { !$0.keyIDs.isEmpty } ?? false }

    public func keyState(_ p: EffectProperty) -> ScrubKeyframeState {
        guard isAnimated(p) else { return .none }
        return keyTime(p, at: localPlayhead) ? .onKey : .between
    }

    public func scalarValue(_ p: EffectProperty) -> Double {
        guard let a = clip?.animation else { return 0 }
        let l = localPlayhead
        if p == .cornerRadius { return Self.radius(of: clip)?.value(atLocal: l) ?? 0 }
        switch p {
        case .rotation: return a.rotation.value(atLocal: l)
        case .opacity: return a.opacity.value(atLocal: l)
        case .volume: return a.volume.value(atLocal: l)
        case .cornerRadius: return 0
        case .scale: return a.scale.value(atLocal: l).x
        case .position: return a.position.value(atLocal: l).x
        case .anchor: return a.anchor.value(atLocal: l).x
        }
    }

    public func vectorValue(_ p: EffectProperty) -> Vec2 {
        guard let a = clip?.animation else { return .zero }
        let l = localPlayhead
        switch p {
        case .position: return a.position.value(atLocal: l)
        case .scale: return a.scale.value(atLocal: l)
        case .anchor: return a.anchor.value(atLocal: l)
        default: return Vec2(scalarValue(p), 0)
        }
    }

    public func track(_ p: EffectProperty) -> PropertyTrack? { track(p, in: clip) }

    /// Radius parameter of the applied Rounded Corners effect; nil when the effect is not applied.
    static func radius(of c: Clip?) -> AnimatedProperty<Double>? {
        c?.roundedCorners?.parameters[ClipEffect.radiusKey]
    }

    private func track(_ p: EffectProperty, in c: Clip?) -> PropertyTrack? {
        guard let a = c?.animation else { return nil }
        switch p {
        case .position: return .vector(a.position.track)
        case .scale: return .vector(a.scale.track)
        case .anchor: return .vector(a.anchor.track)
        case .rotation: return .scalar(a.rotation.track)
        case .opacity: return .scalar(a.opacity.track)
        case .volume: return .scalar(a.volume.track)
        case .cornerRadius: return Self.radius(of: c).map { .scalar($0.track) }
        }
    }

    private func keyTime(_ p: EffectProperty, at local: Time) -> Bool {
        track(p)?.times.contains { $0.time == local } ?? false
    }

    /// Key times in timeline time.
    public func keys(_ p: EffectProperty) -> [(id: UUID, time: Time)] {
        let start = clip?.start ?? .zero
        return (track(p)?.times ?? []).map { ($0.id, $0.time + start) }
    }

    // MARK: Gestures

    public func beginGesture() {
        gestureBase = clip
        gestureEmitted = false
    }

    public func endGesture() {
        gestureBase = nil
        gestureEmitted = false
    }

    private var inGesture: Bool { gestureBase != nil }

    /// Stores `new`, and emits it unless nothing changed.
    private func commit(_ new: Clip, _ name: String) {
        guard new != clip else { return }
        clip = new
        pruneSelection()
        let coalescing = inGesture && gestureEmitted
        if inGesture { gestureEmitted = true }
        onEdit?(new, name, coalescing)
    }

    private var workingClip: Clip? { gestureBase ?? clip }

    // MARK: Stopwatch and key buttons

    @discardableResult
    public func toggleStopwatch(_ p: EffectProperty, confirmRemoval: Bool = false) -> StopwatchOutcome {
        guard var c = clip else { return .unavailable }
        let local = localPlayhead
        if isAnimated(p) {
            guard confirmRemoval else { return .needsConfirmation }
            withVector(&c, p) { $0.value = $0.value(atLocal: local); $0.track = KeyframeTrack() }
            withScalar(&c, p) { $0.value = $0.value(atLocal: local); $0.track = KeyframeTrack() }
            selection = selection.filter { $0.property != p.id }
            commit(c, "Remove Keyframes")
            return .removed
        }
        guard playheadInClip else { return .unavailable }
        withVector(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value)) }
        withScalar(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value)) }
        commit(c, "Add Keyframe")
        return .added
    }

    /// Add / remove button: key at the playhead on, or off again. On a static property it is the stopwatch.
    @discardableResult
    public func toggleKeyAtPlayhead(_ p: EffectProperty) -> StopwatchOutcome {
        guard var c = clip else { return .unavailable }
        guard isAnimated(p) else { return toggleStopwatch(p) }
        let local = localPlayhead
        if keyTime(p, at: local) {
            withVector(&c, p) { Self.removeKey(&$0, at: local) }
            withScalar(&c, p) { Self.removeKey(&$0, at: local) }
            commit(c, "Remove Keyframe")
            return .removed
        }
        guard playheadInClip else { return .unavailable }
        withVector(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
        withScalar(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
        commit(c, "Add Keyframe")
        return .added
    }

    /// Removes the key; when it was the last one the static value takes over so nothing jumps.
    private static func removeKey<V: KeyframeValue>(_ prop: inout AnimatedProperty<V>, at local: Time) {
        let shown = prop.value(atLocal: local)
        if let k = prop.track.keys.first(where: { $0.time == local }) { prop.track.remove(k.id) }
        if prop.track.isEmpty { prop.value = shown }
    }

    public func previousKeyTime(_ p: EffectProperty) -> Time? {
        let l = localPlayhead
        guard let t = track(p)?.times.map(\.time).filter({ $0 < l }).max() else { return nil }
        return t + (clip?.start ?? .zero)
    }

    public func nextKeyTime(_ p: EffectProperty) -> Time? {
        let l = localPlayhead
        guard let t = track(p)?.times.map(\.time).filter({ $0 > l }).min() else { return nil }
        return t + (clip?.start ?? .zero)
    }

    public func goToPreviousKey(_ p: EffectProperty) { if let t = previousKeyTime(p) { onSeek?(t) } }
    public func goToNextKey(_ p: EffectProperty) { if let t = nextKeyTime(p) { onSeek?(t) } }

    // MARK: Editing values

    /// The property should show `v` (native units) at the playhead.
    /// Static: sets the value. Animated with selected keys of this property: relative edit of all of them
    /// (PHASE4 rule 7). Animated otherwise: adds or replaces the key at the playhead.
    @discardableResult
    public func setValue(_ p: EffectProperty, component: EffectComponent = .all, to v: Double) -> Bool {
        guard var c = workingClip else { return false }
        let local = localPlayhead
        let inRange = playheadInClip
        let selected = Set(selection.filter { $0.property == p.id }.map(\.keyID))
        var ok = false
        withScalar(&c, p) { prop in
            ok = Self.apply(&prop, new: v, local: local, inRange: inRange, selected: selected)
        }
        withVector(&c, p) { prop in
            let cur = prop.value(atLocal: local)
            let new: Vec2
            switch (p.kind, component) {
            case (.uniform, _), (_, .all): new = Vec2(v, v)
            case (_, .x): new = Vec2(v, cur.y)
            case (_, .y): new = Vec2(cur.x, v)
            }
            ok = Self.apply(&prop, new: new, local: local, inRange: inRange, selected: selected)
        }
        guard ok else { return false }
        commit(c, "Change \(p.title)")
        return true
    }

    /// Direct manipulation in the Program monitor: writes the parts of `t` that differ from `start` (the transform when
    /// the gesture began) into Position, Scale, Rotation and Anchor at the playhead, like typing the values. Static
    /// properties are set, animated ones get or update the key at the playhead. Inside a gesture every call starts
    /// from the clip as it was when the gesture began, so repeated calls never accumulate; one undo step per gesture.
    @discardableResult
    public func setTransform(_ t: ClipTransform, from start: ClipTransform) -> Bool {
        guard var c = workingClip else { return false }
        let local = localPlayhead, inRange = playheadInClip
        var ok = true
        if t.position != start.position {
            withVector(&c, .position) { ok = Self.apply(&$0, new: t.position, local: local, inRange: inRange, selected: []) && ok }
        }
        if t.scale != start.scale {
            withVector(&c, .scale) { ok = Self.apply(&$0, new: t.scale, local: local, inRange: inRange, selected: []) && ok }
        }
        if t.rotation != start.rotation {
            withScalar(&c, .rotation) { ok = Self.apply(&$0, new: t.rotation, local: local, inRange: inRange, selected: []) && ok }
        }
        if t.anchor != start.anchor {
            withVector(&c, .anchor) { ok = Self.apply(&$0, new: t.anchor, local: local, inRange: inRange, selected: []) && ok }
        }
        guard ok else { return false }
        commit(c, "Transform")
        return true
    }

    /// Motion-path edit in the Program monitor: a Position key's value and/or its tangents. Gesture edits merge.
    public func editPositionKey(_ id: UUID, position: Vec2?, tangents: (in: Vec2, out: Vec2)?) {
        guard var c = workingClip else { return }
        withVector(&c, .position) { p in
            p.track.update(id) { k in
                if let position { k.value = position }
                if let tangents { k.inTangent = tangents.in; k.outTangent = tangents.out }
            }
        }
        commit(c, "Move Keyframe")
    }

    private static func apply<V: KeyframeValue>(_ prop: inout AnimatedProperty<V>, new: V, local: Time,
                                                inRange: Bool, selected: Set<UUID>) -> Bool {
        guard prop.isAnimated else { prop.value = new; return true }
        if !selected.isDisjoint(with: prop.track.keys.map(\.id)) {
            return prop.track.setValue(new, at: local, selected: selected)
        }
        if let k = prop.track.keys.first(where: { $0.time == local }) {
            prop.track.set(k.id, value: new)
            return true
        }
        guard inRange else { return false }
        prop.track.insert(Keyframe(time: local, value: new))
        return true
    }

    // MARK: Selection

    private func pruneSelection() {
        guard let c = clip else { selection = []; return }
        let tracks = Self.tracks(of: c)
        var alive = Set<SummaryMember>()
        for p in EffectProperty.allCases {
            let ids = Set(tracks[p.id]?.keyIDs ?? [])
            alive.formUnion(selection.filter { $0.property == p.id && ids.contains($0.keyID) })
        }
        if alive != selection { selection = alive }
    }

    public func select(_ members: [SummaryMember], extend: Bool) {
        let set = Set(members)
        selection = extend ? selection.symmetricDifference(set) : set
    }

    public func clearSelection() { if !selection.isEmpty { selection = [] } }

    /// Replaces this property's selected keys (graph view selection feedback).
    public func setSelection(for p: EffectProperty, ids: Set<UUID>) {
        var s = selection.filter { $0.property != p.id }
        for id in ids { s.insert(SummaryMember(property: p.id, keyID: id)) }
        selection = s
    }

    public func selectedKeyIDs(_ p: EffectProperty) -> Set<UUID> {
        Set(selection.filter { $0.property == p.id }.map(\.keyID))
    }

    public func summaryKeys(_ section: EffectSection) -> [SummaryKey] {
        guard let c = clip else { return [] }
        return KeyframeSummary(tracks: Self.tracks(of: c))
            .groups(of: Set(section.properties.map(\.id)))
    }

    public func isSelected(_ key: SummaryKey) -> Bool { key.members.isSubset(of: selection) }

    public func selectSummary(_ key: SummaryKey, extend: Bool) {
        if extend {
            if isSelected(key) { selection.subtract(key.members) } else { selection.formUnion(key.members) }
        } else {
            selection = key.members
        }
    }

    public func selectKey(_ p: EffectProperty, id: UUID, extend: Bool) {
        select([SummaryMember(property: p.id, keyID: id)], extend: extend)
    }

    /// Marquee: all keys of `properties` whose clip-local time lies in `range`.
    public func selectKeys(in range: ClosedRange<Time>, properties: Set<EffectProperty>, extend: Bool) {
        var hit = Set<SummaryMember>()
        for p in properties {
            for k in track(p)?.times ?? [] where range.contains(k.time) {
                hit.insert(SummaryMember(property: p.id, keyID: k.id))
            }
        }
        selection = extend ? selection.union(hit) : hit
    }

    // MARK: Key edits on the selection

    static func tracks(of c: Clip) -> [PropertyID: PropertyTrack] {
        let a = c.animation
        var out: [PropertyID: PropertyTrack] = [:]
        func put(_ p: EffectProperty, _ t: PropertyTrack) { if !t.keyIDs.isEmpty { out[p.id] = t } }
        put(.position, .vector(a.position.track)); put(.scale, .vector(a.scale.track))
        put(.anchor, .vector(a.anchor.track)); put(.rotation, .scalar(a.rotation.track))
        put(.opacity, .scalar(a.opacity.track)); put(.volume, .scalar(a.volume.track))
        if let r = radius(of: c) { put(.cornerRadius, .scalar(r.track)) }
        return out
    }

    private func write(_ tracks: [PropertyID: PropertyTrack], into c: inout Clip) {
        for p in EffectProperty.allCases {
            let t = tracks[p.id]
            switch p {
            case .position: if case .vector(let v)? = t { c.animation.position.track = v }
            case .scale: if case .vector(let v)? = t { c.animation.scale.track = v }
            case .anchor: if case .vector(let v)? = t { c.animation.anchor.track = v }
            case .rotation: if case .scalar(let s)? = t { c.animation.rotation.track = s }
            case .opacity: if case .scalar(let s)? = t { c.animation.opacity.track = s }
            case .volume: if case .scalar(let s)? = t { c.animation.volume.track = s }
            case .cornerRadius: if case .scalar(let s)? = t { Self.withRadius(&c) { $0.track = s } }
            }
        }
    }

    /// Moves the selected keys (all properties) in time by `delta`, from the gesture base. Clamped to the clip
    /// range and against unselected neighbours; landing on an unselected key replaces it. Returns the delta applied.
    @discardableResult
    public func moveSelection(by delta: Time) -> Time {
        guard let c = workingClip else { return .zero }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        let members = selection.filter { s.tracks[$0.property]?.keyIDs.contains($0.keyID) ?? false }
        guard !members.isEmpty else { return .zero }
        let times = members.flatMap { m in (s.tracks[m.property]?.times ?? []).filter { $0.id == m.keyID }.map(\.time) }
        let lo = times.min() ?? .zero, hi = times.max() ?? .zero
        let clamped = min(max(delta, .zero - lo), c.source.duration - hi)
        let applied = s.move(members, by: clamped)
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Move Keyframes")
        return applied
    }

    public func applyEasing(_ curve: EasingCurve, side: EaseSide = .both) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        s.apply(curve, to: selection, side: side)
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Easing")
    }

    public func toggleHold() {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        s.toggleHold(selection)
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Toggle Hold Keyframes")
    }

    /// Removes the selected keys. A property left without keys keeps the value it shows at the playhead.
    public func deleteSelection() {
        guard var c = clip, !selection.isEmpty else { return }
        let local = localPlayhead
        for p in EffectProperty.allCases {
            let ids = selectedKeyIDs(p)
            guard !ids.isEmpty else { continue }
            withVector(&c, p) { Self.remove(ids, from: &$0, local: local) }
            withScalar(&c, p) { Self.remove(ids, from: &$0, local: local) }
        }
        selection = []
        commit(c, "Delete Keyframes")
    }

    private static func remove<V: KeyframeValue>(_ ids: Set<UUID>, from prop: inout AnimatedProperty<V>, local: Time) {
        let shown = prop.value(atLocal: local)
        for id in ids { prop.track.remove(id) }
        if prop.track.isEmpty { prop.value = shown }
    }

    // MARK: Reset, enable, remove (Premiere: circular arrow, fx toggle, Delete)

    /// Value a property returns to on reset (no keyframes).
    public func defaultValue(_ p: EffectProperty) -> AnimatedProperty<Double>? {
        switch p {
        case .rotation: ClipAnimation().rotation
        case .opacity: ClipAnimation().opacity
        case .volume: ClipAnimation().volume
        case .cornerRadius: ClipEffect.defaultParameters(for: ClipEffect.roundedCornersKind)[ClipEffect.radiusKey]
        default: nil
        }
    }

    /// True when the property has no keys and sits at its default (the reset button is dimmed then).
    public func isDefault(_ p: EffectProperty) -> Bool {
        guard let c = clip else { return true }
        let d = ClipAnimation()
        switch p {
        case .position: return c.animation.position == d.position
        case .scale: return c.animation.scale == d.scale
        case .anchor: return c.animation.anchor == d.anchor
        default:
            guard let cur = Self.scalar(p, in: c), let def = defaultValue(p) else { return true }
            return cur.value == def.value && !cur.isAnimated
        }
    }

    private static func scalar(_ p: EffectProperty, in c: Clip) -> AnimatedProperty<Double>? {
        switch p {
        case .rotation: c.animation.rotation
        case .opacity: c.animation.opacity
        case .volume: c.animation.volume
        case .cornerRadius: radius(of: c)
        default: nil
        }
    }

    private func resetInPlace(_ c: inout Clip, _ p: EffectProperty) {
        let d = ClipAnimation()
        switch p {
        case .position: c.animation.position = d.position
        case .scale: c.animation.scale = d.scale
        case .anchor: c.animation.anchor = d.anchor
        default:
            guard let def = defaultValue(p) else { return }
            withScalar(&c, p) { $0 = def }
        }
    }

    /// Reset one property to its default and drop its keys: one undo step.
    public func reset(_ p: EffectProperty) {
        guard var c = clip else { return }
        resetInPlace(&c, p)
        selection = selection.filter { $0.property != p.id }
        commit(c, "Reset \(p.title)")
    }

    /// Reset every property of a section (and re-enable its effect): one undo step.
    public func resetSection(_ s: EffectSection) {
        guard var c = clip else { return }
        for p in s.properties { resetInPlace(&c, p) }
        if let k = s.effectKind, var e = c.effect(ofKind: k), !e.enabled {
            e.enabled = true
            c.roundedCorners = e
        }
        let ids = Set(s.properties.map(\.id))
        selection = selection.filter { !ids.contains($0.property) }
        commit(c, "Reset \(s.title)")
    }

    public func isEffectEnabled(_ s: EffectSection) -> Bool {
        guard let k = s.effectKind else { return true }
        return clip?.effect(ofKind: k)?.enabled ?? false
    }

    /// fx toggle of an applied effect.
    public func setEffectEnabled(_ s: EffectSection, _ on: Bool) {
        guard let k = s.effectKind, var c = clip, var e = c.effect(ofKind: k), e.enabled != on else { return }
        e.enabled = on
        c.roundedCorners = e
        commit(c, on ? "Enable \(s.title)" : "Disable \(s.title)")
    }

    public func canRemoveEffect(_ s: EffectSection) -> Bool {
        guard let k = s.effectKind else { return false }
        return clip?.effect(ofKind: k) != nil
    }

    /// Removes the applied effect with all its values and keys: one undo step.
    @discardableResult
    public func removeEffect(_ s: EffectSection) -> Bool {
        guard canRemoveEffect(s), var c = clip else { return false }
        c.roundedCorners = nil
        let ids = Set(s.properties.map(\.id))
        selection = selection.filter { !ids.contains($0.property) }
        if selectedSection == s { selectedSection = nil }
        expanded.subtract(s.properties)
        commit(c, "Remove \(s.title)")
        return true
    }

    /// Delete key: selected keys first, else the selected effect section.
    public func deleteSelectionOrEffect() {
        if !selection.isEmpty { deleteSelection() }
        else if let s = selectedSection { removeEffect(s) }
    }

    // MARK: Easing library

    public func saveCurveFromSelection(name: String) {
        guard let c = clip else { return }
        for p in EffectProperty.allCases {
            guard let id = selectedKeyIDs(p).first else { continue }
            switch track(p, in: c) {
            case .scalar(let t)?: if let k = t.key(id: id) { easingLibrary.saveCurve(from: k, name: name) }
            case .vector(let t)?: if let k = t.key(id: id) { easingLibrary.saveCurve(from: k, name: name) }
            case nil: break
            }
            onLibraryChange?(easingLibrary)
            return
        }
    }

    // MARK: Graph

    /// Scalar track shown in the graph: the property itself, or one component of a vector property.
    public func graphTrack(_ p: EffectProperty, component: EffectComponent) -> KeyframeTrack<Double> {
        switch track(p) {
        case .scalar(let t)?: return t
        case .vector(let t)?: return GraphProjection.project(t, component: component == .y ? .y : .x)
        case nil: return KeyframeTrack()
        }
    }

    /// Takes the complete track edited in the graph (one gesture = one undo step) and merges it back.
    public func applyGraphEdit(_ p: EffectProperty, component: EffectComponent, track edited: KeyframeTrack<Double>) {
        guard var c = clip else { return }
        let uniform = p.kind == .uniform
        let comp: GraphProjection.Component = component == .y ? .y : .x
        withScalar(&c, p) { $0.track = edited }
        withVector(&c, p) { $0.track = GraphProjection.merge(base: $0.track, edited: edited, component: comp, uniform: uniform) }
        commit(c, "Edit \(p.title) Keyframes")
    }

    // MARK: Property access by kind

    private func withScalar(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<Double>) -> Void) {
        switch p {
        case .rotation: body(&c.animation.rotation)
        case .opacity: body(&c.animation.opacity)
        case .volume: body(&c.animation.volume)
        case .cornerRadius: Self.withRadius(&c, body)
        default: break
        }
    }

    static func withRadius(_ c: inout Clip, _ body: (inout AnimatedProperty<Double>) -> Void) {
        guard var e = c.roundedCorners, var r = e.parameters[ClipEffect.radiusKey] else { return }
        body(&r)
        e.parameters[ClipEffect.radiusKey] = r
        c.roundedCorners = e
    }

    private func withVector(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<Vec2>) -> Void) {
        switch p {
        case .position: body(&c.animation.position)
        case .scale: body(&c.animation.scale)
        case .anchor: body(&c.animation.anchor)
        default: break
        }
    }
}

// MARK: - Vec2 <-> scalar graph projection

public enum GraphProjection {
    public enum Component: Sendable { case x, y }

    public static func project(_ t: KeyframeTrack<Vec2>, component: Component) -> KeyframeTrack<Double> {
        KeyframeTrack(keys: t.keys.map { k in
            Keyframe(id: k.id, time: k.time, value: component == .x ? k.value.x : k.value.y,
                     interpolation: k.interpolation, inHandle: k.inHandle, outHandle: k.outHandle)
        })
    }

    /// Existing keys (by id) take time, component value and easing from `edited` and keep everything else;
    /// keys missing from `edited` are dropped; new keys take the other component from the base curve.
    public static func merge(base: KeyframeTrack<Vec2>, edited: KeyframeTrack<Double>,
                             component: Component, uniform: Bool) -> KeyframeTrack<Vec2> {
        func set(_ v: Vec2, _ d: Double) -> Vec2 {
            uniform ? Vec2(d, d) : (component == .x ? Vec2(d, v.y) : Vec2(v.x, d))
        }
        return KeyframeTrack(keys: edited.keys.map { e in
            var k = base.key(id: e.id) ?? Keyframe(id: e.id, time: e.time,
                                                   value: base.value(at: e.time) ?? .zero)
            k.time = e.time
            k.value = set(k.value, e.value)
            k.interpolation = e.interpolation
            k.inHandle = e.inHandle; k.outHandle = e.outHandle
            return k
        })
    }
}

// MARK: - Layout (pure)

public struct EffectRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case section(EffectSection)
        case property(EffectProperty)
        case placeholder(EffectSection)
        case graph(EffectProperty)
    }
    public var kind: Kind
    public var y: CGFloat
    public var height: CGFloat
}

public enum EffectControlsLayout {
    public static let graphComponentHeight: CGFloat = 120

    /// Vector properties show one graph per component (X, Y).
    public static func graphHeight(_ p: EffectProperty) -> CGFloat {
        p.kind == .vector ? graphComponentHeight * 2 : graphComponentHeight
    }

    public static func rows(sections: [EffectSection], collapsed: Set<EffectSection>,
                            expanded: Set<EffectProperty>) -> [EffectRow] {
        let h = Theme.Metrics.effectControlsRow
        var out: [EffectRow] = []
        var y: CGFloat = 0
        func add(_ k: EffectRow.Kind, _ height: CGFloat) { out.append(EffectRow(kind: k, y: y, height: height)); y += height }
        for s in sections {
            add(.section(s), h)
            guard !collapsed.contains(s) else { continue }
            if s.properties.isEmpty { add(.placeholder(s), h) }
            for p in s.properties {
                add(.property(p), h)
                if expanded.contains(p) { add(.graph(p), graphHeight(p)) }
            }
        }
        return out
    }

    public static func totalHeight(_ rows: [EffectRow]) -> CGFloat { rows.last.map { $0.y + $0.height } ?? 0 }

    public static func row(at y: CGFloat, in rows: [EffectRow]) -> EffectRow? {
        rows.first { y >= $0.y && y < $0.y + $0.height }
    }
}

// MARK: - Lane geometry (pure)

/// Maps clip-local time to x in the keyframe lane and back.
public struct KeyframeLaneGeometry: Sendable, Equatable {
    public var width: CGFloat
    public var duration: Time
    public var inset: CGFloat

    public init(width: CGFloat, duration: Time, inset: CGFloat = 10) {
        self.width = width; self.duration = duration; self.inset = inset
    }

    private var usable: CGFloat { max(width - 2 * inset, 1) }
    private var durationSeconds: Double { Double(duration.value) / Double(duration.timescale) }

    public func x(for local: Time) -> CGFloat {
        guard durationSeconds > 0 else { return inset }
        let s = Double(local.value) / Double(local.timescale)
        return inset + CGFloat(s / durationSeconds) * usable
    }

    /// Nearest frame at `x`, clamped to 0...duration.
    public func time(at x: CGFloat, frameDuration: Time) -> Time {
        guard durationSeconds > 0 else { return .zero }
        let s = Double((x - inset) / usable) * durationSeconds
        let fd = Double(frameDuration.value) / Double(frameDuration.timescale)
        let t = Time.frames(Int64((s / fd).rounded()), frameDuration: frameDuration)
        return min(max(t, .zero), duration)
    }

    public func nearestIndex(toX x: CGFloat, in times: [Time], radius: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, t) in times.enumerated() {
            let d = abs(self.x(for: t) - x)
            if d <= radius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}
