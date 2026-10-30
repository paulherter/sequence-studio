import Foundation
import SQCore

/// The curve chips of an opened keyframe row (own names, no Premiere names). Hold Ahead sits directly under Hold; as
/// a shape it is a Hold (`chip(for:)` reads Hold), the model tells the two apart by the key's kind (`speedChip(for:)`).
public enum SpeedCurveChip: Int, CaseIterable, Sendable {
    case steady, smooth, smoothIn, smoothOut, hold, holdAhead

    /// The kind Hold and Hold Ahead write on the left key of a segment (nil for the curves).
    public var holdKind: Interpolation? {
        switch self {
        case .hold: .hold
        case .holdAhead: .holdAhead
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .steady: EaseName.steady
        case .smooth: EaseName.smooth
        case .smoothIn: EaseName.smoothIn
        case .smoothOut: EaseName.smoothOut
        case .hold: EaseName.hold
        case .holdAhead: EaseName.holdAhead
        }
    }

    public var shape: EaseShape {
        switch self {
        case .steady: .linear
        case .smooth: EasingCurve.easeInOut.shape
        case .smoothIn: EasingCurve.easeIn.shape
        case .smoothOut: EasingCurve.easeOut.shape
        case .hold, .holdAhead: .hold
        }
    }

    /// The chip a shape reads as: by the speeds at its two keys, whatever the reach is (a Smooth segment stays Smooth
    /// while its handles are dragged). Nil for a shape none of the chips makes.
    public static func chip(for shape: EaseShape) -> SpeedCurveChip? {
        let s = shape.effective
        if s.interpolation.isHold { return .hold }
        return allCases.first { c in
            c.holdKind == nil && abs(c.shape.speedOut - s.speedOut) < 0.02 && abs(c.shape.speedIn - s.speedIn) < 0.02
        }
    }
}

/// Speed and Reach of the selected segments, as the opened row's fields show them.
public struct SpeedGraphValues: Equatable, Sendable {
    /// Multiples of the steady speed (Steady = 1.0, Smooth = 0.0).
    public var speedOut: Double
    public var speedIn: Double
    /// Handle length as a share of the segment (0...1).
    public var reachOut: Double
    public var reachIn: Double
    public init(_ s: EaseShape) { speedOut = s.speedOut; speedIn = s.speedIn; reachOut = s.reachOut; reachIn = s.reachIn }
}

/// UI state and edits of the opened keyframe row (inline speed graph, variant A). The maths lives in SQCore (`SpeedHill`).
extension EffectControlsModel {
    /// Opens or closes the row's inline graph. Opening selects the row's keys when none of them is selected, so the
    /// chips and fields have something to act on.
    public func toggleOpen(_ p: EffectProperty) {
        if expanded.contains(p) { expanded.remove(p); return }
        expanded.insert(p)
        if selectedKeyIDs(p).isEmpty { setSelection(for: p, ids: Set(track(p)?.keyIDs ?? [])) }
    }

    /// Rows drawn in the graph opened under `p`: `p` itself, then every other selected row that is animated (several rows
    /// selected and eased together draw one hill each), in list order.
    public func speedGraphRows(for p: EffectProperty) -> [EffectProperty] {
        guard let c = clip else { return [p] }
        let others = Self.allProperties(in: c).filter { $0 != p && graphProperties.contains($0) && $0.hasGraph && isAnimated($0) }
        return graphProperties.contains(p) ? [p] + others : [p]
    }

    /// The segments of a row's track with their effective shapes, clip-local times.
    public func speedSegments(_ p: EffectProperty) -> [EaseTrackSegment] { track(p)?.easeSegments ?? [] }

    /// The selected segments that belong to the rows of the graph opened under `p`.
    func speedSelection(for p: EffectProperty) -> [(segment: EaseSegment, shape: EaseShape)] {
        guard let c = clip else { return [] }
        let ids = Set(speedGraphRows(for: p).map(\.id))
        let s = KeyframeSummary(tracks: Self.tracks(of: c))
        return EaseSelection(summary: s, members: selection, stepped: Self.steppedProperties(in: c)).shapes(in: s)
            .filter { ids.contains($0.segment.property) }
    }

    /// The chip that is on: the one every selected segment of the opened row reads as. A held segment is Hold or
    /// Hold Ahead by the kind of its left key.
    public func speedChip(for p: EffectProperty) -> SpeedCurveChip? {
        guard let c = clip else { return nil }
        let s = KeyframeSummary(tracks: Self.tracks(of: c))
        let chips = Set(speedSelection(for: p).map { sel -> SpeedCurveChip? in
            let chip = SpeedCurveChip.chip(for: sel.shape)
            let left = SummaryMember(property: sel.segment.property, keyID: sel.segment.from)
            return chip == .hold && s.interpolation(of: left) == .holdAhead ? .holdAhead : chip
        })
        return chips.count == 1 ? chips.first ?? nil : nil
    }

    /// Speed and Reach shown in the fields: those of the first selected segment (nil without a selected segment).
    public func speedValues(for p: EffectProperty) -> SpeedGraphValues? {
        speedSelection(for: p).first.map { SpeedGraphValues($0.shape) }
    }

    /// Makes sure the edits of the row opened under `p` have a target: with no selected segment there, all its keys.
    private func ensureSpeedSelection(for p: EffectProperty) {
        if speedSelection(for: p).isEmpty { setSelection(for: p, ids: Set(track(p)?.keyIDs ?? [])) }
    }

    /// A curve chip: one shape on every selected segment of the opened row (and of the rows eased with it).
    /// Hold and Hold Ahead set the kind of the segment's left key, so one turns into the other.
    public func applySpeedChip(_ chip: SpeedCurveChip, for p: EffectProperty) {
        if chip == .holdAhead, p.isAnimationRow || !selectionTakesHoldAhead { return }
        ensureSpeedSelection(for: p)
        guard let kind = chip.holdKind else {
            transformSpeed(for: p, "Set Keyframe Easing") { _, _ in chip.shape }
            forgetHeldKinds()
            return
        }
        guard let c = workingClip else { return }
        let ids = Set(speedGraphRows(for: p).map(\.id))
        let members = selection.filter { ids.contains($0.property) }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard EaseSelection(summary: s, members: members, stepped: Self.steppedProperties(in: c)).setHoldKind(kind, in: &s) > 0 else { return }
        forgetHeldKinds()
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Easing")
    }

    /// Rewrites every selected segment of the rows drawn under `p` from its own shape: one undo step (inside a gesture
    /// the whole drag is one step). Selected keys of other rows are left alone.
    private func transformSpeed(for p: EffectProperty, _ name: String, _ change: (EaseSegment, EaseShape) -> EaseShape) {
        guard let c = workingClip else { return }
        let ids = Set(speedGraphRows(for: p).map(\.id))
        let members = selection.filter { ids.contains($0.property) }
        guard !members.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard EaseSelection(summary: s, members: members, stepped: Self.steppedProperties(in: c)).transform(in: &s, change) > 0 else { return }
        var out = c
        write(s.tracks, into: &out)
        commit(out, name)
    }

    /// Handle length (share of the segment) on `side` of every selected segment. The key speeds stay what they are.
    public func setReach(_ reach: Double, side: EaseSide, for p: EffectProperty) {
        ensureSpeedSelection(for: p)
        transformSpeed(for: p, "Set Keyframe Reach") { _, shape in shape.settingReach(reach, side: side) }
    }

    /// Reach and key speed of the handle on `side` together (one drag step), the speed clamped so the handle's value part
    /// stays inside `valueRange`.
    public func setHandle(reach: Double, speed: Double, side: EaseSide, for p: EffectProperty, valueRange: ClosedRange<Double>? = -2...3) {
        ensureSpeedSelection(for: p)
        transformSpeed(for: p, "Set Keyframe Reach") { _, shape in
            shape.settingReach(reach, side: side).settingSpeed(speed, side: side, valueRange: valueRange)
        }
    }

    /// Speed at the key on `side` of every selected segment (multiple of the steady speed). The reach stays what it is.
    public func setKeySpeed(_ speed: Double, side: EaseSide, for p: EffectProperty) {
        ensureSpeedSelection(for: p)
        transformSpeed(for: p, "Set Keyframe Speed") { _, shape in shape.settingSpeed(speed, side: side) }
    }

    /// A handle of the graph is grabbed: its segment becomes the selection unless it already is part of it.
    public func selectSpeedSegment(_ p: EffectProperty, from: UUID, to: UUID) {
        let has = easeSelection.segments.contains { $0.property == p.id && $0.from == from && $0.to == to && $0.side == .both }
        if !has { setSelection(for: p, ids: [from, to]) }
    }

    /// Summary value at the right of a section row (design source `.fx .sum`), nil when the section has none.
    /// `collapsed` is the open state the header row was built for; the row passes it so its value changes in the
    /// same pass that adds or removes the body rows (never a model change ahead of the rebuild). Default: the live state.
    public func sectionSummary(_ s: EffectSection, collapsed: Bool? = nil) -> String? {
        guard let c = clip else { return nil }
        let isCollapsed = collapsed ?? collapsedSections.contains(s)
        if case .effect(let id, let kind) = s, kind == ClipEffect.colorKind, let fx = c.effects.first(where: { $0.id == id }) {
            return Self.lookSummary(fx)
        }
        // v9 `.ksv`: "100 % · Forward".
        if s == .speed {
            return isCollapsed ? String(format: "%g %% \u{00B7} ", (speedPercent * 100).rounded() / 100) + (isReversed ? "Reverse" : "Forward") : nil
        }
        // Collapsed: the first number of the section, so the closed row still says what it does.
        guard isCollapsed, let p = s.properties.first(where: { ($0.kind == .scalar || $0.kind == .uniform) && $0.paramKind?.isStepped != true }) else { return nil }
        let pic = displayPicture
        let v = p.display(scalarValue(p), picture: pic)
        let text = String(format: "%.\(max(p.displayDecimals(picture: pic), 0))f", v)
        let unit = p.displayUnit(picture: pic)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    private static func lookSummary(_ fx: ClipEffect) -> String? {
        switch fx.grade?.look {
        case .file(let path)?:
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return name.isEmpty ? nil : "Look \(name)"
        case .embedded?: return "Look Camera"
        default: return nil
        }
    }
}
