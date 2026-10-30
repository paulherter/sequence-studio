import Foundation
import SQCore
import SQUIKit

/// What Controls shows while a transition is selected (the Mac `syncTransitions` inputs of `TransitionControlsView.update`):
/// a clip-edge transition or a transition layer clip, with its resolved length and the menus' choices.
public struct TransitionControlsShown: Equatable {
    public var transition: Transition
    /// nil: the transition's cut is gone.
    public var resolved: ResolvedTransition?
    public var frameDuration: Time
    /// The clips a Stinger can play (id, name), offered in its Clip menu.
    public var stingerMedia: [StingerChoice] = []
    /// The kind has a user default (FB-W): shown under the name, and Reset goes back to it.
    public var hasUserDefault = false
    /// A transition layer clip (DECISIONS 2026-10-05): a Type menu instead of the preset and default buttons.
    public var isLayer = false

    public struct StingerChoice: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public init(transition: Transition, resolved: ResolvedTransition?, frameDuration: Time, stingerMedia: [StingerChoice] = [],
                hasUserDefault: Bool = false, isLayer: Bool = false) {
        self.transition = transition; self.resolved = resolved; self.frameDuration = frameDuration
        self.stingerMedia = stingerMedia; self.hasUserDefault = hasUserDefault; self.isLayer = isLayer
    }
}

/// The rules of the transition controls, shared by the Mac `TransitionControlsView` and the draw-list
/// `TransitionControlsDraw`: which rows a kind shows, the slider units, the alignment choices, the held-frame note.
public enum TransitionControlsLogic {
    /// The rows under the name, in the Mac stack order.
    public enum Row: Hashable, Sendable {
        case kind, duration, alignment, element(String), stingerClip, stingerCut, color, easing, direction, softness,
             border, borderColor, motionBlur
    }

    /// Curves offered for a transition (hold would turn it into a cut at the end).
    public static let easings: [EasingCurve] = EasingCurve.transitionPresets
    /// Pop-up item after the presets: opens the curve editor on a hand-drawn curve.
    public static let customEasingTitle = EaseName.customMenu
    /// Index of the Custom item in the easing pop-up.
    public static var customEasingIndex: Int { easings.count }

    /// Pop-up index of a curve: its preset, else Custom.
    public static func easingIndex(of c: EasingCurve) -> Int {
        guard let p = c.matchingTransitionPreset, let i = easings.firstIndex(of: p) else { return customEasingIndex }
        return i
    }

    /// Motion blur slider: percent of a 360 degree shutter (100 % = one frame).
    public static func blurPercent(_ shutter: Double) -> Double { (shutter * 100).rounded() }
    public static func shutter(percent: Double) -> Double { max(0, percent) / 100 }
    /// Softness slider: percent of the frame.
    public static func softnessPercent(_ s: Double) -> Double { (s * 100).rounded() }
    /// An element transition blurs through its clip's shutter, which stops at one frame (360 degrees).
    public static func blurRange(_ k: TransitionKind) -> ClosedRange<Double> { 0...(k.isElement ? 100 : 200) }
    public static let softnessRange: ClosedRange<Double> = 0...50
    public static let borderRange: ClosedRange<Double> = 0...10
    public static let stingerCutRange: ClosedRange<Double> = 0...100

    /// Duration field value: the transition's length in whole frames.
    public static func durationFrames(_ t: Time, frameDuration fd: Time) -> Double { Double(t.frameIndex(frameDuration: fd)) }
    /// A field value back to a time: whole frames, at least one.
    public static func duration(frames: Double, frameDuration fd: Time) -> Time { fd * max(1, Int64(frames.rounded())) }

    /// The length shown: the resolved one (clamped to the media), else the stored one.
    public static func shownDuration(_ s: TransitionControlsShown) -> Time { s.resolved?.duration ?? s.transition.duration }

    public static func subtitle(_ s: TransitionControlsShown) -> String {
        if s.isLayer { return "Transition Layer · everything below" }
        return (s.transition.kind.trackKind == .video ? "Video Transition" : "Audio Transition") + (s.hasUserDefault ? " · Your Default" : "")
    }

    public static func resetTip(hasUserDefault: Bool) -> String { hasUserDefault ? "Reset to Your Default" : "Reset to Default" }

    /// Alignment choices: two-sided transitions (and layers) pick center / start / end; Custom only while it is set.
    public static func alignmentOptions(_ s: TransitionControlsShown) -> [TransitionAlignment] {
        var options: [TransitionAlignment] = isTwoSided(s) ? [.center, .startAtCut, .endAtCut] : []
        if s.transition.alignment == .custom { options.append(.custom) }
        return options
    }
    public static func isTwoSided(_ s: TransitionControlsShown) -> Bool { s.isLayer || !s.transition.isSingleSided }

    /// The rows a transition shows, in order.
    public static func rows(_ s: TransitionControlsShown) -> [Row] {
        let k = s.transition.kind
        var out: [Row] = []
        if s.isLayer { out.append(.kind) }
        out += [.duration, .alignment]
        out += k.elementParams.map { .element($0.key) }
        if k.isStinger { out.append(.stingerClip) }
        if k.isStinger, s.transition.stinger != nil { out.append(.stingerCut) }
        if k.usesColor { out.append(.color) }
        if k.usesEasing { out.append(.easing) }
        if k.usesDirection { out.append(.direction) }
        if k.usesSoftness { out.append(.softness) }
        // Edge transitions only: a transition layer has no stored border.
        if !s.isLayer, k.usesBorder { out += [.border, .borderColor] }
        if k.usesMotionBlur { out.append(.motionBlur) }
        return out
    }

    /// The row titles (the Mac 70 pt right-aligned labels).
    public static func title(_ r: Row, kind: TransitionKind) -> String {
        switch r {
        case .kind: "Type"
        case .duration: "Duration"
        case .alignment: "Alignment"
        case .element(let key): kind.elementParams.first { $0.key == key }?.title ?? key
        case .stingerClip: "Clip"
        case .stingerCut: "Cut Point"
        case .color: "Color"
        case .easing: "Easing"
        case .direction: "Direction"
        case .softness: "Softness"
        case .border: "Border"
        case .borderColor: "Border Color"
        case .motionBlur: "Motion Blur"
        }
    }

    /// The Stinger Clip menu: None, the candidates, and "Missing Clip" for a picked clip that is gone; the index shown.
    public static func stingerItems(_ s: TransitionControlsShown) -> (titles: [String], ids: [UUID?], selected: Int) {
        var titles = ["None"], ids: [UUID?] = [nil]
        for m in s.stingerMedia { titles.append(m.name); ids.append(m.id) }
        guard let id = s.transition.stinger?.media else { return (titles, ids, 0) }
        if !s.stingerMedia.contains(where: { $0.id == id }) { titles.append("Missing Clip"); ids.append(id) }
        return (titles, ids, ids.firstIndex(of: id) ?? 0)
    }

    /// Dip color shown (display-encoded RGB bytes).
    public static func color(_ s: TransitionControlsShown) -> [UInt8] { TransitionMix.dipColor(s.transition.kind, custom: s.transition.color) }
    public static func borderColor(_ s: TransitionControlsShown) -> [UInt8] {
        s.transition.borderColor?.count == 3 ? s.transition.borderColor! : [255, 255, 255]
    }

    /// The note under the rows while the transition is shortened or holds frames; nil when it plays in full.
    public static func note(_ s: TransitionControlsShown) -> String? {
        guard let r = s.resolved, r.isClamped else { return nil }
        if r.heldBefore > 0 && r.heldAfter > 0 {
            return "Held frames: neither clip has media beyond the cut, so both edge frames repeat (striped)."
        }
        if r.isHeld { return "Held frame: a clip has no media beyond the cut on one side, so its edge frame repeats (striped)." }
        if s.transition.kind.isStinger { return "Shortened: a clip next to the cut is shorter than the stinger's part on its side." }
        return "Shortened: the clips do not have enough media beyond the cut for the full length."
    }

    /// Rows of the right-click menu (FB-W); empty for stingers.
    public static func contextItems(kind: TransitionKind, hasUserDefault: Bool, reset: @escaping @MainActor () -> Void,
                                    useAsDefault: @escaping @MainActor () -> Void,
                                    resetDefaultToFactory: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        guard !kind.isStinger else { return [] }
        return [
            SQMenuItem(title: hasUserDefault ? "Reset to Your Default" : "Reset") { reset() },
            .separator,
            SQMenuItem(title: SQL10n.format("Use as Default for %@", SQL10n.string(kind.name))) { useAsDefault() },
            SQMenuItem(title: "Reset Default to Factory", isEnabled: hasUserDefault) { resetDefaultToFactory() },
        ]
    }
}

/// The transition controls' session side, translated from the Mac shell wiring (App/Sources/EditorPanels+Transitions.swift):
/// which transition is shown (a clip-edge transition, else the one selected transition layer clip) and every edit, sent
/// to the layer or to the edge transition. Both platforms' hosts call it.
@MainActor
public final class TransitionControlsActions {
    public let session: EditorSession
    /// Status line text (Use as Default, Reset Default to Factory).
    public var onStatus: ((String) -> Void)?

    public init(session: EditorSession) { self.session = session }

    /// The one selected clip when it is a transition layer (and no clip-edge transition is selected).
    public var selectedLayer: Clip.ID? {
        guard session.selectedTransition == nil, session.selection.count == 1, let id = session.selection.first,
              session.transitionLayerInfo(id) != nil else { return nil }
        return id
    }

    /// What Controls shows now; nil: no transition selected (Controls shows the clip).
    public func shown() -> TransitionControlsShown? {
        guard let fd = session.activeTimeline?.frameDuration else { return nil }
        if let id = selectedLayer, let info = session.transitionLayerInfo(id) {
            return TransitionControlsShown(transition: info.transition, resolved: info.resolved, frameDuration: fd, isLayer: true)
        }
        guard let id = session.selectedTransition, let info = session.transitionInfo(id) else { return nil }
        let stingers = info.transition.kind.isStinger
            ? session.stingerCandidates.map { TransitionControlsShown.StingerChoice(id: $0.id, name: $0.name) } : []
        return TransitionControlsShown(transition: info.transition, resolved: info.resolved, frameDuration: fd, stingerMedia: stingers,
                                       hasUserDefault: session.hasTransitionDefault(info.transition.kind))
    }

    /// The curve popover's source for Easing > Custom.
    public func easeSource() -> TransitionEaseSource? {
        if let id = selectedLayer { return TransitionEaseSource(session: session, target: .layer(id)) }
        if let id = session.selectedTransition { return TransitionEaseSource(session: session, target: .edge(id)) }
        return nil
    }

    public func setKind(_ k: TransitionKind) {
        guard let id = selectedLayer else { return }
        session.setTransitionLayerKind(id, k)
    }

    public func setDuration(_ d: Time) {
        if let id = selectedLayer { session.setTransitionLayerDuration(id, d); return }
        guard let id = session.selectedTransition else { return }
        session.setTransition(id, duration: d)
    }

    /// A custom alignment keeps its offset; the named ones are fully described by the alignment itself.
    public func setAlignment(_ a: TransitionAlignment) {
        if let id = selectedLayer { session.setTransitionLayerAlignment(id, a); return }
        guard let id = session.selectedTransition else { return }
        session.setTransition(id, alignment: a)
    }

    public func setEasing(_ c: EasingCurve) {
        if let id = selectedLayer { session.setTransitionLayerStyle(id, "Easing", continuesGesture: false) { $0.easing = c }; return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, easing: c)
    }

    public func setDirection(_ d: TransitionDirection) {
        if let id = selectedLayer { session.setTransitionLayerStyle(id, "Direction", continuesGesture: false) { $0.direction = d }; return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, direction: d)
    }

    public func setReversed(_ on: Bool) {
        if let id = selectedLayer { session.setTransitionLayerStyle(id, "Reverse", continuesGesture: false) { $0.reversed = on ? true : nil }; return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, reversed: on)
    }

    public func setSoftness(_ s: Double, continuesGesture: Bool) {
        if let id = selectedLayer { session.setTransitionLayerStyle(id, "Softness", continuesGesture: continuesGesture) { $0.softness = s }; return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, softness: s, continuesGesture: continuesGesture)
    }

    public func setMotionBlur(_ b: Double, continuesGesture: Bool) {
        if let id = selectedLayer { session.setTransitionLayerStyle(id, "Motion Blur", continuesGesture: continuesGesture) { $0.motionBlur = b }; return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, motionBlur: b, continuesGesture: continuesGesture)
    }

    public func setColor(_ rgb: [UInt8], continuesGesture: Bool) {
        if let id = selectedLayer { session.setTransitionLayerStyle(id, "Color", continuesGesture: continuesGesture) { $0.color = rgb }; return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, color: rgb, continuesGesture: continuesGesture)
    }

    public func setBorderWidth(_ w: Double, continuesGesture: Bool) {
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, borderWidth: w, continuesGesture: continuesGesture)
    }

    public func setBorderColor(_ rgb: [UInt8], continuesGesture: Bool) {
        guard let id = session.selectedTransition else { return }
        session.setTransitionStyle(id, borderColor: rgb, continuesGesture: continuesGesture)
    }

    public func setStingerMedia(_ m: UUID?) {
        guard let id = session.selectedTransition else { return }
        session.setTransitionStinger(id, media: m)
    }

    public func setStingerCut(_ c: Double, continuesGesture: Bool) {
        guard let id = session.selectedTransition, let media = session.transitionInfo(id)?.transition.stinger?.media else { return }
        session.setTransitionStinger(id, media: media, cutFraction: c, continuesGesture: continuesGesture)
    }

    /// A typed or picked element parameter (FB-G).
    public func setElementParam(_ key: String, _ value: Double) {
        if let id = selectedLayer { session.setTransitionLayerParam(id, key, value); return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionParams(id, [key: value])
    }

    /// A dragged element parameter: every change as it moves; `continuesGesture` false for the first.
    public func setElementParamLive(_ key: String, _ value: Double, continuesGesture: Bool) {
        if let id = selectedLayer { _ = session.setTransitionLayerParam(id, key, value, continuesGesture: continuesGesture); return }
        guard let id = session.selectedTransition else { return }
        session.setTransitionParams(id, [key: value], continuesGesture: continuesGesture)
    }

    /// FB-W: the shown transition becomes the default of its kind.
    public func useAsDefault() {
        guard let id = session.selectedTransition, let kind = session.transitionInfo(id)?.transition.kind else { return }
        if session.useTransitionAsDefault(id) { onStatus?(SQL10n.format("New %@ transitions now start with this look.", SQL10n.string(kind.name))) }
    }

    public func reset() {
        guard let id = session.selectedTransition else { return }
        session.resetTransition(id)
    }

    public func resetDefaultToFactory() {
        guard let id = session.selectedTransition, let kind = session.transitionInfo(id)?.transition.kind else { return }
        session.resetTransitionDefaultToFactory(kind)
        onStatus?(SQL10n.format("%@ is back to its built-in default.", SQL10n.string(kind.name)))
    }
}
