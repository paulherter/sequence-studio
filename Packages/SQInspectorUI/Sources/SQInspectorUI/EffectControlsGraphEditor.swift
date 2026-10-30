import Foundation
import SQCore
import SQUIKit

/// Graph Editor mode of Effect Controls (After Effects style, speed graph only): the whole keyframe area becomes one
/// speed graph. The property rows selected on the left (or every animated property with the "show all" filter) are drawn
/// in that one plot on one shared speed axis (display units per second, 0 at the bottom), one color per property; the
/// row's value fields carry the same color. Keys of several properties are selected together, moved together in time,
/// and their speed handles are edited together. The key selection is the panel's normal selection, so the key menu and
/// the Smooth / Smooth in / Smooth out commands act on it.
extension EffectControlsModel {
    /// Properties drawn in the graph, in panel order. Colors have no speed and are left out.
    public var graphEditorProperties: [EffectProperty] {
        guard let c = clip else { return [] }
        let keyed = Set(selection.map(\.property))
        return panelProperties.filter { p in
            guard p.kind != .color else { return false }
            if graphShowAll { return !(track(p, in: c)?.keyIDs.isEmpty ?? true) }
            return graphProperties.contains(p) || keyed.contains(p.id)
        }
    }

    /// Samples per segment for the widest drawn segment: one sample per 2 pt, 4...64 (a long segment on screen gets
    /// the full 64, a short or zoomed-out one far fewer).
    public static func adaptiveSamples(segmentSeconds: Double, pointsPerSecond: Double) -> Int {
        let n = segmentSeconds * pointsPerSecond / 2
        return n.isFinite ? min(max(Int(n), 4), 64) : 48
    }

    /// Sample count for the current properties and zoom (widest key-to-key span among the drawn properties).
    public func graphSampleCount(pointsPerSecond: Double) -> Int {
        guard let c = clip else { return 4 }
        var widest = 0.0
        for p in graphEditorProperties {
            let ts = (track(p, in: c)?.glyphs ?? []).map { Double($0.time.value) / Double($0.time.timescale) }
            for (a, b) in zip(ts, ts.dropFirst()) { widest = max(widest, b - a) }
        }
        return Self.adaptiveSamples(segmentSeconds: widest, pointsPerSecond: pointsPerSecond)
    }

    /// The drawn curves with their color slot and display units. A row without keys is a flat line at 0.
    public func graphEditorCurves(samples: Int = 48) -> [GraphEditorCurve] {
        guard let c = clip else { return [] }
        let props = graphEditorProperties
        let slots = GraphEditorPalette.slots(for: props)
        return zip(props, slots).map { p, slot in
            let t = track(p, in: c)
            let curve = (t?.keyIDs.isEmpty ?? true) ? .still : (t?.speedOverlay(samples: samples, hue: isHueProperty(p)) ?? .still)
            return GraphEditorCurve(property: p.id, title: p.title, curve: curve, colorIndex: slot,
                                    scale: Self.speedScale(p, picture: displayPicture), unit: Self.speedUnit(p, picture: displayPicture))
        }
    }

    /// True for a hue parameter (degrees round the color circle): its segments take the short way between keys.
    func isHueProperty(_ p: EffectProperty) -> Bool {
        guard case .fx(let id, let kind, let key) = p, clip?.effects.contains(where: { $0.id == id }) == true else { return false }
        return EffectCatalog.param(kind, key)?.isHue == true
    }

    /// Color slot of a property while it is drawn in the graph (tints its value fields), else nil.
    public func graphColorSlot(_ p: EffectProperty) -> Int? {
        let props = graphEditorProperties
        guard let i = props.firstIndex(of: p) else { return nil }
        return GraphEditorPalette.slots(for: props)[i]
    }

    /// Native units -> display units for speeds (linear display mappings; volume stays in gain).
    static func speedScale(_ p: EffectProperty, picture: Vec2? = nil) -> Double {
        if p == .volume { return 1 }
        let s = p.display(1, picture: picture) - p.display(0, picture: picture)
        return s.isFinite && s != 0 ? abs(s) : 1
    }
    static func speedUnit(_ p: EffectProperty, picture: Vec2? = nil) -> String {
        switch p {
        case .position, .anchor: return "px"
        case .volume: return "gain"
        default: return p.displayUnit(picture: picture)
        }
    }

    /// Click-away (empty space in Controls, or focus left the panel): no row, effect header or key stays selected.
    /// `keepMask`: a click elsewhere (the Program monitor, where masks are drawn and edited) keeps a selected mask.
    public func clearRowSelection(keepMask: Bool = false) {
        graphProperties = []
        if case .mask? = selectedSection, keepMask {} else { selectedSection = nil }
        clearSelection()
    }

    /// Click on a property row's label: that row and its keys are the one selection; `extend` (Shift / Cmd) adds or
    /// removes the row (and its keys) instead. An effect header selection never stays alongside a row selection.
    public func selectPropertyRow(_ p: EffectProperty, extend: Bool) {
        selectedSection = nil
        let ids = Set(track(p)?.keyIDs ?? [])
        if extend {
            let removing = graphProperties.contains(p)
            setSelection(for: p, ids: removing ? [] : ids)
        } else {
            clearSelection()
            setSelection(for: p, ids: ids)
        }
        selectGraphProperty(p, extend: extend)
    }

    /// Click on an effect header: only that effect is selected, no row or key.
    public func selectEffectHeader(_ s: EffectSection) {
        graphProperties = []
        clearSelection()
        selectedSection = s
    }

    /// Turns the Graph Editor on or off (Controls row menu, View > Graph Editor, the toggle) and reports the new state.
    public func toggleGraphEditor() { graphEditor.toggle(); onGraphEditorChanged?(graphEditor) }

    /// Row menu entry: the Graph Editor on or off for the whole panel.
    func graphEditorMenuItem() -> SQMenuItem {
        SQMenuItem(title: graphEditor ? "Hide Graph Editor" : "Show Graph Editor", isEnabled: clip != nil) { [weak self] in self?.toggleGraphEditor() }
    }

    /// Click on a row name: plain click shows only that property; `extend` (Shift / Cmd) adds or removes it.
    public func selectGraphProperty(_ p: EffectProperty, extend: Bool) {
        if extend {
            if graphProperties.contains(p) { graphProperties.remove(p) } else { graphProperties.insert(p) }
        } else {
            graphProperties = [p]
        }
    }

    /// Moves the selected keys (all properties) by `seconds` from the gesture base, frame-rounded. With snapping on and a
    /// tolerance given, the move lands exactly on the playhead or another key when one is that close. Call
    /// `beginGesture` first and `endGraphKeyMove` on mouse-up.
    public func moveGraphSelection(bySeconds seconds: Double, snapTolerance: Double? = nil) {
        var seconds = seconds
        if graphSnap, let tol = snapTolerance, let c = workingClip ?? clip {
            var moving: [Double] = [], targets: [Double] = []
            for (pid, t) in Self.tracks(of: c) {
                for k in t.times {
                    let s = Self.secs(k.time)
                    if selection.contains(SummaryMember(property: pid, keyID: k.id)) { moving.append(s) } else { targets.append(s) }
                }
            }
            targets.append(Self.secs(localPlayhead))
            targets += [0, Self.secs(c.duration)]       // clip start and end
            seconds = GraphEditorSnap.delta(seconds, moving: moving, targets: targets, tolerance: tol)
        }
        let fd = frameDuration
        let fdSecs = Double(fd.value) / Double(max(fd.timescale, 1))
        let frames = (seconds / fdSecs).rounded()
        guard frames.isFinite, abs(frames) < 1e12 else { return }
        moveSelection(by: Time.frames(Int64(frames), frameDuration: fd))
    }

    static func secs(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }

    /// Ends a graph key drag as one undo step. Unlike the lanes, the moved keys stay selected (After Effects): the
    /// next step is usually easing them.
    public func endGraphKeyMove() {
        let keep = selection
        endKeyMove()
        if selection != keep { select(Array(keep), extend: false) }
    }

    /// Gives every selected key `handle` on `side` (same influence, same speed relative to its segment), from the
    /// gesture base. Inside a gesture the whole drag is one undo step.
    public func setGraphHandle(_ handle: EaseHandle, side: KeySide) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        guard s.setHandle(handle, side: side, on: selection) > 0 else { return }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Speed")
    }

    /// Bottom toolbar ease buttons: Smooth, Smooth in, Smooth out, Steady, Hold (same as the key menu).
    public func applyGraphEase(_ choice: KeyInterpolationChoice) {
        guard !selection.isEmpty else { return }
        applyInterpolation(choice)
    }

    /// Fit: the time range of the selected keys (or of every drawn key) fills the plot, with a small margin. The speed
    /// axis always fits itself.
    public func fitGraph(selectionOnly: Bool) {
        var times: [Double] = []
        for c in graphEditorCurves() {
            times += c.curve.keys.filter { !selectionOnly || selection.contains(SummaryMember(property: c.property, keyID: $0.id)) }
                .map(\.seconds)
        }
        guard let lo = times.min(), let hi = times.max() else { return }
        let span = max(hi - lo, minViewportSpan)
        let pad = span * 0.08
        setViewport(KeyframeViewport(start: lo - pad, span: span + 2 * pad))
    }

    /// The toolbar's Fit button: the selected keys when there are any, else every drawn key.
    public func fitGraph() { fitGraph(selectionOnly: !selection.isEmpty) }
}

/// Snapping of a time move: the smallest correction that puts any moving key onto any target, if within `tolerance`.
public enum GraphEditorSnap {
    public static func delta(_ d: Double, moving: [Double], targets: [Double], tolerance: Double) -> Double {
        var best: Double?
        for m in moving {
            for t in targets {
                let corr = t - (m + d)
                if abs(corr) <= tolerance, abs(corr) < abs(best ?? .infinity) { best = corr }
            }
        }
        return d + (best ?? 0)
    }
}

/// Graph Editor on/off, remembered per panel (UserDefaults; the view loads and saves it, the model never reads it).
public enum EffectControlsGraphEditorPref {
    static let key = "sq.effectControls.graphEditor"
    public static func load() -> Bool { UserDefaults.standard.bool(forKey: key) }
    public static func save(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}
