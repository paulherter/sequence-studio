import Foundation
import Observation
import SQAnalysis
import SQCore
import SQUIKit

// MARK: - Sections and properties

// `EffectSection` itself lives in SQEditorSession (the timeline key lane names it).
extension EffectSection {
    /// Animatable properties.
    public var properties: [EffectProperty] {
        switch self {
        // Opacity sits inside Motion, under Anchor Point; FB-G: Motion's own Shutter Angle closes the group (Transform's place).
        case .motion: [.position, .scale, .rotation, .tiltX, .tiltY, .anchor, .opacity, .shutterAngle, .antiFlicker]
        case .opacity: [.opacity]
        case .volume: [.volume]
        case .speed: []
        case .effect(let id, let kind):
            // P4: an X/Y pair (Transform Position / Anchor) is one row, carried by its X member.
            // Multiband band solo / bypass and "Link band controls" live in the custom setup popup only (no rows, no keys).
            (EffectCatalog.spec(for: kind).map { spec in spec.params.filter { spec.pair(containing: $0.key)?.y != $0.key } } ?? [])
                .filter { kind != ClipEffect.audioMultibandKind || !ClipEffect.mbSetupOnlyKeys.contains($0.key) }
                .map { .fx(id, kind: kind, key: $0.key) }
        case .mask(let id): MaskParam.allCases.map { .mask(id, $0) }
        case .animation(let side): AnimationParam.allCases.map { .anim(side, $0) }
        }
    }
}

public enum EffectProperty: Hashable, Sendable {
    case position, scale, rotation, anchor, opacity, volume
    /// FB-G: Motion's own Shutter Angle (`ClipAnimation.shutterAngle`, degrees, 0 = no motion blur).
    case shutterAngle
    /// v92: Motion's Anti-flicker Filter (`ClipAnimation.antiFlicker`, 0...1).
    case antiFlicker
    /// Perspective tilt of the layer (`ClipAnimation.tiltX` / `tiltY`, degrees, +-89).
    case tiltX, tiltY
    /// A parameter of an applied effect instance.
    case fx(ClipEffect.ID, kind: String, key: String)
    /// W6.7: a keyframable number of a path mask.
    case mask(ClipMask.ID, MaskParam)
    /// The Path of a path mask: keys only (drawn on the mask's controls row), no value field and no value graph.
    case maskPath(ClipMask.ID)
    /// One row of a Custom Intro / Outro (text clip): offset from rest in pixels, scale factor, degrees, opacity.
    case anim(AnimationSide, AnimationParam)

    public static let builtIns: [EffectProperty] = [.position, .scale, .rotation, .anchor, .opacity, .volume, .shutterAngle, .antiFlicker, .tiltX, .tiltY]

    public enum Kind: Sendable { case vector, uniform, scalar, color }

    public var rawValue: String {
        switch self {
        case .position: "position"
        case .scale: "scale"
        case .rotation: "rotation"
        case .anchor: "anchor"
        case .opacity: "opacity"
        case .volume: "volume"
        case .shutterAngle: "shutterAngle"
        case .antiFlicker: "antiFlicker"
        case .tiltX: "tiltX"
        case .tiltY: "tiltY"
        case .fx(let id, let kind, let key): "fx:\(id.uuidString):\(kind):\(key)"
        case .mask(let id, let m): "mask:\(id.uuidString):\(m.rawValue)"
        case .maskPath(let id): "maskpath:\(id.uuidString)"
        case .anim(let side, let param): "anim:\(side.rawValue):\(param.rawValue)"
        }
    }

    /// The Custom animation row behind this property; nil for every other property.
    public var animParam: AnimationParam? {
        if case .anim(_, let param) = self { return param }
        return nil
    }

    public init?(rawValue: String) {
        if let b = Self.builtIns.first(where: { $0.rawValue == rawValue }) { self = b; return }
        let parts = rawValue.split(separator: ":", maxSplits: 3).map(String.init)
        if parts.count == 2, parts[0] == "maskpath", let id = UUID(uuidString: parts[1]) { self = .maskPath(id); return }
        if parts.count == 3, parts[0] == "mask", let id = UUID(uuidString: parts[1]), let m = MaskParam(rawValue: parts[2]) {
            self = .mask(id, m); return
        }
        if parts.count == 3, parts[0] == "anim", let side = AnimationSide(rawValue: parts[1]), let m = AnimationParam(rawValue: parts[2]) {
            self = .anim(side, m); return
        }
        guard parts.count == 4, parts[0] == "fx", let id = UUID(uuidString: parts[1]) else { return nil }
        self = .fx(id, kind: parts[2], key: parts[3])
    }

    public var kind: Kind {
        switch self {
        case .position, .anchor: .vector
        case .scale: .uniform
        case .rotation, .tiltX, .tiltY, .opacity, .volume, .shutterAngle, .antiFlicker, .mask, .maskPath: .scalar
        case .anim(_, let param): param == .position ? .vector : .scalar
        case .fx:
            switch paramKind {
            case .point?: .vector
            case .color?: .color
            default: .scalar
            }
        }
    }

    public var id: PropertyID { PropertyID(rawValue) }

    /// A row of an Animation (In/Out) section (its keys live in the text payload, not in the clip's tracks).
    public var isAnimationRow: Bool { if case .anim = self { true } else { false } }

    /// What the catalog says about an effect parameter.
    var fxSpec: EffectParamSpec? {
        if case .fx(_, let kind, let key) = self { return EffectCatalog.param(kind, key) }
        return nil
    }

    /// P4: the X/Y pair this property is the row of (it is the pair's X member); nil for every other property.
    public var pair: EffectParamPair? {
        guard case .fx(_, let kind, let key) = self, let pr = EffectCatalog.spec(for: kind)?.pair(containing: key),
              pr.x == key else { return nil }
        return pr
    }

    /// Value kind of an effect parameter (slider, checkbox, choice, color, point); nil for the fixed properties.
    /// A pair row is a point (two fields, like Motion's Position) whose default is the members' defaults.
    public var paramKind: EffectParamKind? {
        if let pr = pair, case .fx(_, let kind, _) = self {
            return .point(Vec2(EffectCatalog.param(kind, pr.x)?.defaultValue ?? 0, EffectCatalog.param(kind, pr.y)?.defaultValue ?? 0))
        }
        return fxSpec?.kind
    }

    /// Has a value graph under its row (sliders and positions; not colors, checkboxes or choices).
    public var hasGraph: Bool {
        if case .maskPath = self { return false }      // a shape per key: no value to plot
        return switch paramKind {
        case .color?, .checkbox?, .choice?: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .anchor: "Anchor"
        case .opacity: "Opacity"
        case .volume: "Volume"
        case .shutterAngle: "Shutter Angle"
        case .antiFlicker: "Anti-flicker Filter"
        case .tiltX: "Tilt X"
        case .tiltY: "Tilt Y"
        case .fx(_, _, let key): pair?.title ?? fxSpec?.title ?? key
        case .mask(_, let m): m.title
        case .maskPath: "Mask Path"
        case .anim(_, let param): param.title
        }
    }

    public var section: EffectSection {
        switch self {
        case .position, .scale, .rotation, .tiltX, .tiltY, .anchor, .shutterAngle, .antiFlicker: .motion
        case .opacity: .opacity
        case .volume: .volume
        case .fx(let id, let kind, _): .effect(id, kind: kind)
        case .mask(let id, _), .maskPath(let id): .mask(id)
        case .anim(let side, _): .animation(side)
        }
    }

    // MARK: Display units (what the ScrubField shows)

    /// Volume is stored as linear gain and shown in dB; this is the dB shown for silence.
    public static let silenceDB = -60.0

    /// Resolve / Final Cut convention (docs/research/VALUE-DISPLAY-RESOLVE-FCP.md): Position and Anchor show 0,0 at
    /// the center with Y up, Rotation is counterclockwise positive. Storage stays center-based, y down, clockwise
    /// positive; this sign is the only difference between the shown number and the stored one.
    public func displaySign(component: EffectComponent = .all) -> Double {
        switch self {
        case .position, .anchor, .anim(_, .position): component == .y ? -1 : 1
        case .rotation, .anim(_, .rotation): -1
        case .fx(_, let kind, let key):
            switch key {
            case ClipEffect.stageRotationKey: -1
            case ClipEffect.stagePositionYKey, ClipEffect.stageAnchorYKey: -1
            case ClipEffect.stagePositionXKey, ClipEffect.stageAnchorXKey: component == .y ? -1 : 1
            case ClipEffect.groupRotationKey where kind == ClipEffect.groupTransformKind: -1
            case ClipEffect.groupPositionKey, ClipEffect.groupAnchorKey:
                kind == ClipEffect.groupTransformKind && component == .y ? -1 : 1
            default: 1
            }
        default: 1
        }
    }

    /// Shown = stored x this for an effect row. Crop (stored percent of the picture) is shown in px of the clip's own
    /// picture once `picture` (upright size in px) is known; without it the percent stays.
    func fxDisplayScale(picture: Vec2?) -> Double {
        guard let spec = fxSpec else { return 1 }
        if let axis = spec.pictureAxis, let pic = picture {
            let size = axis == .width ? pic.x : pic.y
            if size > 0 { return size / 100 }
        }
        return spec.displayScale
    }

    /// True for rows whose shown scale depends on the clip's picture size (Crop).
    var pictureDependent: Bool { fxSpec?.pictureAxis != nil }

    /// True when `fxDisplayScale` maps percent to px of the picture (the row's unit is then "px").
    func showsPictureUnits(picture: Vec2?) -> Bool {
        guard let axis = fxSpec?.pictureAxis, let pic = picture else { return false }
        return (axis == .width ? pic.x : pic.y) > 0
    }

    public func display(_ native: Double, component: EffectComponent = .all, picture: Vec2? = nil) -> Double {
        let v: Double
        switch self {
        case .scale, .opacity, .anim(_, .scale), .anim(_, .opacity): v = native * 100
        case .volume: return native <= 0.001 ? Self.silenceDB : max(20 * log10(native), Self.silenceDB)
        case .fx: v = native * fxDisplayScale(picture: picture)
        default: v = native
        }
        return v * displaySign(component: component) + 0      // + 0: never "-0"
    }

    /// `v` (native units) limited to the row's range; Position / Anchor and unranged rows are unlimited.
    public func clampedNative(_ v: Double, picture: Vec2? = nil) -> Double {
        let r = displayRange(picture: picture)
        guard r.lowerBound > -1e12 || r.upperBound < 1e12 else { return v }
        let a = native(fromDisplay: r.lowerBound, picture: picture), b = native(fromDisplay: r.upperBound, picture: picture)
        return min(max(v, min(a, b)), max(a, b))
    }

    public func native(fromDisplay d: Double, component: EffectComponent = .all, picture: Vec2? = nil) -> Double {
        let d = d * displaySign(component: component)
        switch self {
        case .scale, .opacity, .anim(_, .scale), .anim(_, .opacity): return d / 100
        case .volume: return d <= Self.silenceDB ? 0 : pow(10, d / 20)
        case .fx: return d / fxDisplayScale(picture: picture)
        default: return d
        }
    }

    public var displayUnit: String { displayUnit(picture: nil) }
    public func displayUnit(picture: Vec2?) -> String {
        switch self {
        case .scale, .opacity, .anim(_, .scale), .anim(_, .opacity): "%"
        case .rotation, .tiltX, .tiltY, .shutterAngle, .anim(_, .rotation): "\u{00B0}"
        case .volume: "dB"
        case .fx: showsPictureUnits(picture: picture) ? "px" : (fxSpec?.unit ?? "")
        case .mask(_, let m): m.unit
        default: ""
        }
    }
    public var displayDecimals: Int { displayDecimals(picture: nil) }
    public func displayDecimals(picture: Vec2?) -> Int {
        switch self {
        case .scale, .opacity, .position, .anchor: 1
        case .rotation, .tiltX, .tiltY: 1
        case .shutterAngle: 0
        case .antiFlicker: 2
        case .volume: 1
        case .fx: showsPictureUnits(picture: picture) ? 0 : (fxSpec?.decimals ?? 1)
        case .mask, .maskPath, .anim: 1
        }
    }
    public var displayStep: Double { displayStep(picture: nil) }
    public func displayStep(picture: Vec2?) -> Double {
        switch self {
        case .volume: 0.1
        case .position, .anchor: 1
        case .scale, .opacity: 0.5
        case .rotation, .tiltX, .tiltY: 0.5
        case .shutterAngle: 1
        case .antiFlicker: 0.05
        case .fx: showsPictureUnits(picture: picture) ? 1 : (fxSpec?.step ?? 1) * (fxSpec?.displayScale ?? 1)
        case .mask, .maskPath: 1
        case .anim(_, let param): param == .position ? 1 : 0.5
        }
    }
    private static func scaled(_ r: ClosedRange<Double>?, by k: Double) -> ClosedRange<Double> {
        guard let r else { return -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude }
        return r.lowerBound * k...r.upperBound * k
    }
    public var displayRange: ClosedRange<Double> { displayRange(picture: nil) }
    public func displayRange(picture: Vec2?) -> ClosedRange<Double> {
        switch self {
        case .opacity, .anim(_, .opacity): 0...100
        case .shutterAngle: 0...360
        case .antiFlicker: 0...1
        case .tiltX, .tiltY: -PerspectiveTilt.maxDegrees...PerspectiveTilt.maxDegrees
        case .scale, .anim(_, .scale): 0...10_000
        case .volume: Self.silenceDB...15
        case .mask(_, let m): m.range
        case .fx: Self.scaled(fxSpec?.range, by: fxDisplayScale(picture: picture))
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
    public private(set) var clip: Clip? { didSet { if clip != oldValue { clipRevision &+= 1; closeCurvesWithoutKeys(old: oldValue) } } }

    /// An opened curve row with fewer than two keys left has no curve to show: it closes itself (its arrow is gone too).
    private func closeCurvesWithoutKeys(old: Clip?) {
        guard let old, let c = clip, old.id == c.id, !expanded.isEmpty else { return }
        let gone = expanded.filter { p in
            let n = track(p, in: c)?.keyIDs.count ?? 0
            return n < 2 && n < (track(p, in: old)?.keyIDs.count ?? 0)
        }
        if !gone.isEmpty { expanded.subtract(gone) }
    }
    /// Counts changes of `clip`: display caches (lanes, graph) rebuild when it moves, never on playhead ticks.
    @ObservationIgnored public private(set) var clipRevision = 0
    /// Timeline time.
    public var playhead: Time = .zero { didSet { if playhead != oldValue { endColorGesture() } } }
    public var frameDuration = Time(1, 30)
    /// Tracked frames of Magic masks (keys on the mask's row). Tests inject one over a memory store.
    @ObservationIgnored public var magicFrames: MagicTrackedFrames = .shared
    public internal(set) var selection: Set<SummaryMember> = [] { didSet { if selection != oldValue { endColorGesture() } } }
    public var expanded: Set<EffectProperty> = [] { didSet { if expanded != oldValue { saveTwirl() } } }
    public var collapsedSections: Set<EffectSection> = [] { didSet { if collapsedSections != oldValue { saveTwirl() } } }
    /// Open groups of Color effects ("<effect id>/<switch key>"; Basic Correction, Creative, Curves ...).
    public var openColorGroups: Set<String> = []
    /// Color effects already shown once: a new one starts collapsed (it is often added by the Color page, not by hand).
    @ObservationIgnored private var seenColorEffects: Set<ClipEffect.ID> = []
    /// Scale row: one linked value (chain button on) or Width and Height. Follows the clip when it changes.
    public var uniformScale = true
    /// Property whose row or keys were last used: where a pasted single-property key set lands.
    public var focusedProperty: EffectProperty?
    @ObservationIgnored var keyClipboard: KeyframeClipboard?
    @ObservationIgnored var effectClipboard: ClipEffect?
    /// Called when an effect is copied, so the session keeps it for Cmd-V on timeline clips while this panel is closed.
    @ObservationIgnored public var onEffectCopied: ((ClipEffect) -> Void)?
    @ObservationIgnored var lastCopyWasKeys = true
    /// A built-in effect (Transform, Blend, Volume) copied as a whole: the section and the clip it came from. The app
    /// keeps it in the session so Paste reaches every selected clip (`onBuiltInCopied`, `canPasteBuiltIn`, `onPasteBuiltIn`).
    @ObservationIgnored var builtInCopy: (section: EffectSection, clip: Clip)?
    @ObservationIgnored public var onBuiltInCopied: ((EffectSection, Clip) -> Void)?
    @ObservationIgnored public var canPasteBuiltIn: (() -> Bool)?
    @ObservationIgnored public var onPasteBuiltIn: (() -> Bool)?
    /// Short messages for the status line (e.g. keys that did not fit).
    @ObservationIgnored public var onNotice: ((String) -> Void)?
    /// Track Backward (false) / Forward (true) on a mask row; the app runs the tracker (`trackMask`) and cancels a running one.
    @ObservationIgnored public var onTrackMask: ((ClipMask.ID, Bool) -> Void)?
    /// A Magic mask's track controls: a command, or nil for Stop.
    @ObservationIgnored public var onTrackMagic: ((ClipMask.ID, MagicTrackControl.Command?) -> Void)?
    /// The timeline the shown clip is in (Picture mask track choices, C6); the app sets it, nil in tests that do not need it.
    @ObservationIgnored public var timeline: (() -> Timeline?)?
    /// What Track Forward / Backward follows (the Track choice on the mask row; session only, not in the project).
    public var maskTrackMode: MaskTrackMode = .default
    /// Twirl-down state per clip (session only); `twirlClip` is the clip whose state is on screen.
    @ObservationIgnored var twirlClip: Clip.ID?
    @ObservationIgnored var twirlMemory: [Clip.ID: TwirlState] = [:]
    /// Section header last clicked: Delete removes its effect (when removable) if no keys are selected.
    public var selectedSection: EffectSection?
    public var graphMode: GraphMode = .speed      // Speed Graph first (the maintainer); Value Graph stays one click away
    /// Rows that chose their own graph mode; every other row follows `graphMode`.
    public var graphModeByProperty: [EffectProperty: GraphMode] = [:]
    /// Graph Editor mode: the keyframe area shows one overlaid speed graph instead of the lanes (EffectControlsGraphEditor).
    public var graphEditor = false
    /// Called after every on / off change of the Graph Editor (the view persists it).
    @ObservationIgnored public var onGraphEditorChanged: ((Bool) -> Void)?
    /// Property rows selected for the Graph Editor (click a row name; Shift / Cmd adds or removes).
    public var graphProperties: Set<EffectProperty> = []
    /// Graph Editor filter: every animated property instead of the selected rows.
    public var graphShowAll = false
    /// Graph Editor: key moves snap to the playhead and to other keys.
    public var graphSnap = true
    public var easingLibrary = EasingLibrary()
    /// FB-W: the user's effect defaults ("Reset" goes back to these; the app keeps them in sync with the library).
    public var effectDefaults = EffectDefaults()
    /// "Use as Default" / "Reset Default to Factory" changed the defaults: the app stores them.
    @ObservationIgnored public var onEffectDefaultsChange: ((EffectDefaults) -> Void)?

    @ObservationIgnored public var onEdit: ((Clip, String, Bool) -> Void)?
    /// Multi-select: the shown clip and its peers changed together, ONE undo step (coalescing like `onEdit`).
    @ObservationIgnored public var onEditMany: (([Clip], String, Bool) -> Void)?
    /// Multi-select: the other selected clips (as displayed); an edit of `clip` goes to them too. Empty = one clip.
    public private(set) var peers: [Clip] = []
    @ObservationIgnored var peerGestureBase: [Clip]?
    /// Jump the playhead (timeline time), e.g. for the prev/next key buttons.
    @ObservationIgnored public var onSeek: ((Time) -> Void)?
    @ObservationIgnored public var onLibraryChange: ((EasingLibrary) -> Void)?
    /// Playhead scrubbing in the keyframe ruler: a press stops playback, a drag scrubs like the timeline ruler.
    @ObservationIgnored public var onPointerDown: (() -> Void)?
    @ObservationIgnored public var onScrubBegan: (() -> Void)?
    @ObservationIgnored public var onScrub: ((Time) -> Void)?
    @ObservationIgnored public var onScrubEnded: (() -> Void)?
    @ObservationIgnored private var scrubBegan = false

    /// Visible part of the clip in the keyframe area (nil = whole clip). Use `viewport`.
    private var zoomState: KeyframeViewport?

    @ObservationIgnored private var gestureBase: Clip?
    @ObservationIgnored private var gestureEmitted = false
    /// Which hold (Hold or Hold Ahead) a key was when Toggle Hold last took it out of hold, so toggling it on again
    /// brings that one back. Session memory of this panel only: nothing is stored in the project, and any other ease
    /// put on the key forgets it.
    @ObservationIgnored var heldKinds: [UUID: Interpolation] = [:]
    /// `clipRevision` right after the last Toggle Hold: `heldKinds` is only valid while the clip has not moved since.
    @ObservationIgnored private var heldKindsRevision = -1
    /// Undo name of the gesture's last emitted edit; an Esc cancel reuses it (never "Cancel").
    @ObservationIgnored private var gestureName: String?
    /// Key drag: steps change the shown clip only (a scratch copy); the session gets one edit on mouse-up (`endKeyMove`).
    @ObservationIgnored private var deferEmit = false
    @ObservationIgnored private var deferredEditName: String?
    /// Color parameter being dragged in the color panel: its edits share one undo step until anything else happens.
    @ObservationIgnored private var colorGesture: EffectProperty?
    @ObservationIgnored private var committingColor = false

    /// Linked audio clip of a video clip. Its Volume is shown (and edited) in the Audio group under the video effects: the
    /// shown `clip` carries the partner's volume in `animation.volume`; `commit` routes it back to the partner.
    @ObservationIgnored private var audioPartner: Clip?
    /// The video clip's own volume line (restored before an edit is handed to `onEdit`).
    @ObservationIgnored private var ownVolume: AnimatedProperty<Double>?
    /// Partner start minus video start: the partner's keys are shown shifted by it (and shifted back on commit).
    @ObservationIgnored private var partnerOffset: Time = .zero
    /// Graphics clip whose item (layer) Controls shows: `clip` is that item's projection (`Clip.graphicsItemProjection`),
    /// edits go back into the item (`applyingItemProjection`). nil for a plain clip or the whole graphic.
    @ObservationIgnored private(set) var itemHost: (host: Clip, layer: UUID)?
    /// Edit of the linked audio clip (Volume shown under a video clip).
    @ObservationIgnored public var onAudioEdit: ((Clip, String, Bool) -> Void)?
    /// FB-B3: Set Reference / Match of a Color effect was pressed; the host samples the Program frame.
    @ObservationIgnored public var onColorMatch: ((ClipEffect.ID, ColorMatchRequest) -> Void)?
    /// Adjust of the Color Graph row was pressed: the host shows the Color page (the graph is its Pro page).
    @ObservationIgnored public var onOpenColorPro: (() -> Void)?
    /// Stabilizer (EffectControlsModel+Stabilize.swift): the running analysis (set by the host), Analyze / Cancel pressed,
    /// and why Gyroflow cannot run on a clip (nil = it can).
    public var stabilizeRun: StabilizeRunState?
    @ObservationIgnored public var onStabilizeAnalyze: ((Clip.ID) -> Void)?
    @ObservationIgnored public var onStabilizeCancel: (() -> Void)?
    /// Cancel on a Gyroflow Stabilizer's Analyze row: the host stops the engine's analysis of this clip and options.
    @ObservationIgnored public var onGyroflowCancel: ((Clip, GyroflowOptions) -> Void)?
    @ObservationIgnored public var gyroflowBlockOf: ((Clip) -> String?)?
    /// The clip shows source frames its Stabilizer's analysis does not cover (trimmed longer): the row says so.
    @ObservationIgnored public var stabilizeStaleOf: ((Clip) -> Bool)?
    /// The Gyroflow engine's analysis of a clip with these options (progress / ready / failed for the Analyze row).
    @ObservationIgnored public var gyroflowStateOf: ((Clip, GyroflowOptions) -> GyroAnalysisState)?
    /// Bumped by the host when a Gyroflow analysis moved on: the Analyze row reads `gyroflowStateOf` again.
    public var gyroflowRevision = 0
    /// The source color space a clip renders with (override, media detection, project input); nil = the clip's override or Rec. 709.
    @ObservationIgnored public var colorSourceOf: ((Clip) -> ColorSpaceID)?
    /// A video clip is shown together with its linked audio clip (Volume and audio effects belong to that one).
    var showsAudioPartner: Bool { audioPartner != nil }

    public init() {}

    // MARK: Clip

    private func collapseNewColorEffects(in c: Clip) {
        for e in c.effects where e.isColor && seenColorEffects.insert(e.id).inserted {
            collapsedSections.insert(.effect(e.id, kind: e.kind))
            for k in ColorEffectGroups.openByDefault { openColorGroups.insert(Self.colorGroupID(e.id, k)) }
        }
    }

    nonisolated public static func colorGroupID(_ effect: ClipEffect.ID, _ key: String) -> String { "\(effect.uuidString)/\(key)" }

    public func toggleColorGroup(_ effect: ClipEffect.ID, _ key: String) {
        let g = Self.colorGroupID(effect, key)
        if openColorGroups.contains(g) { openColorGroups.remove(g) } else { openColorGroups.insert(g) }
    }

    nonisolated static let multibandParametersKey = "all-parameters"

    /// "All Parameters" of a Multiband Compressor: closed until the user opens it.
    public func isMultibandParametersOpen(_ effect: ClipEffect.ID) -> Bool {
        openColorGroups.contains(Self.colorGroupID(effect, Self.multibandParametersKey))
    }

    public func toggleMultibandParameters(_ effect: ClipEffect.ID) { toggleColorGroup(effect, Self.multibandParametersKey) }

    /// Name of the clip that carries the effect (the shown clip, or its linked audio clip), nil when it is gone.
    public func multibandClipName(_ effect: ClipEffect.ID) -> String? {
        if let c = clip, c.effects.contains(where: { $0.id == effect }) { return c.name }
        if let p = audioPartner, p.effects.contains(where: { $0.id == effect }) { return p.name }
        return nil
    }

    /// The curves of a Color effect (neutral when it has none).
    public func colorCurves(_ effect: ClipEffect.ID) -> RGBCurves {
        clip?.effects.first { $0.id == effect }?.colorData.curves ?? RGBCurves()
    }

    /// Writes the curves of a Color effect (a drag is one undo step through begin/endGesture).
    public func setColorCurves(_ effect: ClipEffect.ID, _ curves: RGBCurves) {
        guard var c = workingClip, let i = c.effects.firstIndex(where: { $0.id == effect }), c.effects[i].isColor else { return }
        var g = c.effects[i].colorData
        guard g.curves != curves else { return }
        g.curves = curves
        c.effects[i].grade = g
        commit(c, "Edit Curves")
    }

    /// Sets the clip shown. Never calls `onEdit`. A different clip resets selection; the same clip prunes
    /// selected keys that no longer exist.
    public func setClip(_ shown: Clip?, audioPartner partner: Clip? = nil, peers newPeers: [Clip] = [],
                        item: (host: Clip, layer: UUID)? = nil) {
        var c = shown
        let itemChanged = item?.layer != itemHost?.layer
        itemHost = shown == nil ? nil : item
        let newPeers = shown == nil ? [] : newPeers
        Self.sizeRowsMemo(forSelection: newPeers.count + 1)
        if newPeers.isEmpty, let v = shown, v.kind != .audio, let partner, partner.kind == .audio {
            ownVolume = v.animation.volume; audioPartner = partner
            // Keys are clip-local: an L/J-cut partner starts elsewhere, so its keys move into the video clip's time base.
            let d = partner.start - v.start
            partnerOffset = d
            c?.animation.volume = d == .zero ? partner.animation.volume : partner.animation.volume.shifted(by: d)
            // AUDIO-FX: shown in the Audio group, edits go to the partner
            c?.effects += partner.effects.filter(\.isAudio).map { d == .zero ? $0 : $0.shifted(by: d) }
        } else { ownVolume = nil; audioPartner = nil; partnerOffset = .zero }
        if c != clip { endColorGesture() }      // undo or an outside edit: the color gesture's base is stale
        if c?.id != clip?.id || newPeers.map(\.id) != peers.map(\.id) { peerGestureBase = nil }
        if newPeers != peers { peers = newPeers }
        if c?.id != clip?.id || itemChanged { selection = []; selectedSection = nil; gestureBase = nil; closeEmittedGesture(); zoomState = nil
            deferEmit = false; deferredEditName = nil; revertPendingFrameSteps()
            if scrubBegan { scrubBegan = false; onScrubEnded?() }      // a lost mouse-up must not leave the scrub open
        }
        if let c {
            // Follows the clip: a new clip derives it, any later change (undo, redo, external edit) can only switch it off.
            if c.id != clip?.id { uniformScale = Self.isUniformScale(c, at: .zero) }
            else if !Self.isUniformScale(c, at: .zero) { uniformScale = false }
        }
        clip = c
        if let c { adoptTwirl(for: c.id) }
        if let c { collapseNewColorEffects(in: c) }
        if let sec = selectedSection, !visibleSections.contains(sec) || !Self.keepsSelection(sec) { selectedSection = nil }
        pruneSelection()
    }

    /// Follows the session: the selected clip (or the video clip of a selected linked pair), nothing for no or a mixed
    /// selection. Called for every session change; cheap when nothing relevant changed.
    public func sync(with session: EditorSession, change: EditorSession.Change) {
        speedSession = session
        if change.contains(.project) || change.contains(.media) {
            let fd = session.activeTimeline?.frameDuration ?? frameDuration
            if fd != frameDuration { frameDuration = fd }
        }
        if change.contains(.selection) || change.contains(.project) {
            guard !deferEmit else { return syncPlayhead(with: session, change: change) }     // mid key drag: the scratch copy stays
            if syncMulti(with: session) { return syncPlayhead(with: session, change: change) }
            let shown = session.displayedSelectedClip
            if let shown, let sel = session.graphicLayerSelection, sel.clip == shown.id, shown.isGraphics,
               let layer = shown.graphics?.shownItem(selection: sel.layers),
               let projected = shown.graphicsItemProjection(layer) {
                setClip(projected, item: (shown, layer))
                return syncPlayhead(with: session, change: change)
            }
            let partner = shown.flatMap { c in c.link.flatMap { l in
                c.kind == .audio ? nil : session.activeTimeline?.tracks.flatMap(\.clips).first { $0.link == l && $0.kind == .audio } } }
            setClip(shown, audioPartner: partner)
        }   // as the active variant shows it (W5.1)
        syncPlayhead(with: session, change: change)
    }

    private func syncPlayhead(with session: EditorSession, change: EditorSession.Change) {
        if change.contains(.playhead) || change.contains(.project), playhead != session.playhead { playhead = session.playhead }
    }

    /// The session that applies the Speed section's edits (set by `sync`).
    weak var speedSession: EditorSession?

    /// Upright size in px of the picture the shown clip displays (active format variant); nil for generators and media
    /// without probe info. Crop is shown in px of it.
    public var displayPicture: Vec2? {
        guard let session = speedSession, let c = clip,
              let s = session.project.pictureSize(of: c, variant: session.activeVariantID) else { return nil }
        return Vec2(Double(s.width), Double(s.height))
    }

    public var visibleSections: [EffectSection] {
        guard let clip else { return [] }
        // Applied effects sit below the fixed ones, in list order (= evaluation order).
        // The first Crop is edited by Transform's Crop rows: no section of its own.
        let transformCrop = Self.transformCropID(in: clip)
        // A Color Graph shows only while Pro is the clip's grade; the Color panel's Simple | Pro switch owns the rest.
        let applied = clip.effects.filter {
            EffectCatalog.spec(for: $0.kind) != nil && $0.id != transformCrop && (!$0.isColorGraph || $0.colorGraph?.isActive == true)
        }
        let audioFX: [EffectSection] = applied.filter(\.isAudio).map { .effect($0.id, kind: $0.kind) }
        if clip.kind == .audio { return [.volume] + (isMulti ? audioFX.filter { $0.effectID.map(sharedByAnyPeer) ?? false } : audioFX) }
        var out: [EffectSection] = [.motion]       // Opacity is a row of Motion, not a section of its own
        if isMulti {
            out += sharedCustomSides().map { .animation($0) }
            return out + applied.filter { !$0.isAudio && sharedByAnyPeer($0.id) }.map { .effect($0.id, kind: $0.kind) }
        }
        out += customAnimationSections(of: clip)   // a Custom Intro / Outro: its rows follow the Animation section
        if speedSession != nil, Timeline.canRetime(clip) { out.append(.speed) }
        out += clip.masks.map { .mask($0.id) }   // every mask (path, Magic, Subject, Picture) follows Motion/Opacity
        out += applied.filter { !$0.isAudio }.map { .effect($0.id, kind: $0.kind) }
        if audioPartner != nil { out += [.volume] + audioFX }   // Audio group: the linked audio clip's Volume and effects
        return out
    }

    public var duration: Time { clip?.duration ?? .zero }
    var durationSeconds: Double { Double(duration.value) / Double(max(duration.timescale, 1)) }

    // MARK: Zoom (keyframe area)

    /// Smallest visible span: a few frames.
    public var minViewportSpan: Double { 4 * Double(frameDuration.value) / Double(max(frameDuration.timescale, 1)) }

    /// What the lanes, ruler, clip bar, graph and zoom bar show (clip-local seconds).
    public var viewport: KeyframeViewport {
        let d = durationSeconds
        return zoomState?.clamped(duration: d, minSpan: minViewportSpan) ?? .full(duration: d)
    }
    public var isZoomed: Bool { !viewport.isFull(duration: durationSeconds) }

    public func setViewport(_ v: KeyframeViewport) {
        let c = v.clamped(duration: durationSeconds, minSpan: minViewportSpan)
        zoomState = c.isFull(duration: durationSeconds) ? nil : c
    }

    /// `factor` > 1 zooms in. The anchor (clip-local seconds) stays where it is on screen; default: the playhead when
    /// visible, else the window center.
    public func zoom(by factor: Double, around anchor: Double? = nil) {
        let v = viewport
        let ph = Double(localPlayhead.value) / Double(max(localPlayhead.timescale, 1))
        let a = anchor ?? (v.range.contains(ph) ? ph : v.start + v.span / 2)
        setViewport(v.zoomed(by: factor, around: a, duration: durationSeconds, minSpan: minViewportSpan))
    }
    public func zoomIn() { zoom(by: 1.6) }
    public func zoomOut() { zoom(by: 1 / 1.6) }
    public func zoomToFit() { zoomState = nil }
    public func panViewport(bySeconds s: Double) {
        setViewport(viewport.panned(by: s, duration: durationSeconds, minSpan: minViewportSpan))
    }
    func revealPlayhead(_ t: Time) {
        guard zoomState != nil, let c = clip else { return }
        let local = t - c.start
        setViewport(viewport.revealing(Double(local.value) / Double(local.timescale), duration: durationSeconds, minSpan: minViewportSpan))
    }

    /// Geometry of a lane-like view of the given width (same mapping everywhere).
    public func laneGeometry(width: CGFloat) -> KeyframeLaneGeometry {
        KeyframeLaneGeometry(width: width, duration: duration, viewport: zoomState == nil ? nil : viewport)
    }

    // MARK: Playhead scrubbing (ruler)

    /// Clip-local times the playhead sticks to while Shift is held: every key of every property, plus the clip ends.
    public func snapTargets() -> [Time] {
        guard let c = clip else { return [] }
        var out: [Time] = [.zero, c.duration]
        for t in Self.tracks(of: c).values { out += t.times.map(\.time) }
        return out
    }

    /// Timeline time for a ruler position (clip-local, frame-snapped). With `snap` the time sticks to keyframes
    /// within `thresholdSeconds`.
    public func scrubTarget(local: Time, snap: Bool, thresholdSeconds: Double) -> Time {
        let l = snap ? KeyframeSnap.snapped(local, candidates: snapTargets(), thresholdSeconds: thresholdSeconds) : local
        return (clip?.start ?? .zero) + l
    }

    public func scrubDown(to t: Time) {
        scrubBegan = false
        onPointerDown?()
        onSeek?(t)
    }
    public func scrubDrag(to t: Time) {
        if !scrubBegan { scrubBegan = true; onScrubBegan?() }
        if let onScrub { onScrub(t) } else { onSeek?(t) }
    }
    public func scrubUp() {
        if scrubBegan { onScrubEnded?() }
        scrubBegan = false
    }
    public var localPlayhead: Time { playhead - (clip?.start ?? .zero) }
    public var playheadInClip: Bool { clip != nil && localPlayhead >= .zero && localPlayhead <= duration }

    // MARK: Reading

    public func isAnimated(_ p: EffectProperty) -> Bool { track(p, in: clip).map { !$0.keyIDs.isEmpty } ?? false }

    public func keyState(_ p: EffectProperty) -> ScrubKeyframeState {
        guard isAnimated(p) else { return .none }
        return keyTime(p, at: localPlayhead) ? .onKey : .between
    }

    /// What the property's `KeyframeControls` show (ring, prev / diamond / next and their enabled states).
    public func keyframeControlState(_ p: EffectProperty) -> KeyframeControlState {
        KeyframeControlState.resolve(animated: isAnimated(p), onKey: keyState(p) == .onKey,
                                     hasPrevious: previousKeyTime(p) != nil, hasNext: nextKeyTime(p) != nil,
                                     playheadInRange: playheadInClip)
    }

    public func scalarValue(_ p: EffectProperty) -> Double {
        guard let a = clip?.animation else { return 0 }
        let l = localPlayhead
        switch p {
        case .rotation: return a.rotation.value(atLocal: l)
        case .tiltX: return a.tiltX.value(atLocal: l)
        case .tiltY: return a.tiltY.value(atLocal: l)
        case .opacity: return a.opacity.value(atLocal: l)
        case .volume: return a.volume.value(atLocal: l)
        case .shutterAngle: return a.shutterAngle.value(atLocal: l)
        case .antiFlicker: return a.antiFlicker.value(atLocal: l)
        case .fx(let id, _, let key): return clip?.effects.first { $0.id == id }?.shownValue(key, atLocal: l) ?? 0
        case .mask: return Self.maskParam(p, in: clip)?.value(atLocal: l) ?? 0
        case .maskPath: return 0
        case .anim(_, .position): return Self.animVector(p, in: clip)?.value(atLocal: l).x ?? 0
        case .anim: return Self.animScalar(p, in: clip)?.value(atLocal: l) ?? 0
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
        case .fx where p.pair != nil:
            guard let (x, y) = Self.pairMembers(p, in: clip) else { return .zero }
            return Vec2(x.value(atLocal: l), y.value(atLocal: l))
        case .fx where p.kind == .vector: return Self.pointParam(p, in: clip)?.value(atLocal: l) ?? .zero
        case .anim(_, .position): return Self.animVector(p, in: clip)?.value(atLocal: l) ?? .zero
        default: return Vec2(scalarValue(p), 0)
        }
    }

    /// Color of a color parameter at the playhead (black for anything else).
    public func colorValue(_ p: EffectProperty) -> EffectColor {
        Self.colorParam(p, in: clip)?.value(atLocal: localPlayhead) ?? .black
    }

    public func track(_ p: EffectProperty) -> PropertyTrack? { track(p, in: clip) }

    /// The animated value of a slider / checkbox / choice parameter; nil when that effect instance is not on the clip.
    static func param(_ p: EffectProperty, in c: Clip?) -> AnimatedProperty<Double>? {
        guard case .fx(let id, _, let key) = p else { return nil }
        return c?.effects.first { $0.id == id }?.parameters[key]
    }

    /// The animated number of a mask (Feather, Opacity, Expansion); nil when the mask is gone.
    static func maskParam(_ p: EffectProperty, in c: Clip?) -> AnimatedProperty<Double>? {
        guard case .mask(let id, let m) = p, let mask = c?.mask(id) else { return nil }
        return m.value(of: mask)
    }

    static func withMask(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<Double>) -> Void) {
        guard case .mask(let id, let m) = p else { return }
        c.updateMask(id) { mask in
            var v = m.value(of: mask)
            body(&v)
            m.set(v, in: &mask)
        }
    }

    /// The animated value of a color parameter.
    static func colorParam(_ p: EffectProperty, in c: Clip?) -> AnimatedProperty<EffectColor>? {
        guard case .fx(let id, _, let key) = p else { return nil }
        return c?.effects.first { $0.id == id }?.colors[key]
    }

    /// The animated value of a point parameter.
    static func pointParam(_ p: EffectProperty, in c: Clip?) -> AnimatedProperty<Vec2>? {
        guard case .fx(let id, _, let key) = p else { return nil }
        if p.pair != nil { return pairMembers(p, in: c).map { KeyframesPair.editable($0.x, $0.y) } }
        return c?.effects.first { $0.id == id }?.points[key]
    }

    /// The two scalar members of a pair row (P4), as stored.
    static func pairMembers(_ p: EffectProperty, in c: Clip?) -> (x: AnimatedProperty<Double>, y: AnimatedProperty<Double>)? {
        guard case .fx(let id, let kind, _) = p, let pr = p.pair, let e = c?.effects.first(where: { $0.id == id }) else { return nil }
        let x = member(e, kind, pr.x)
        return (x, pr.linkable && e.parameters[pr.y] == nil ? x : member(e, kind, pr.y))
    }

    /// P5: effects whose linkable pair (Scale) is unlinked; a change rebuilds the rows (one field or two).
    public var unlinkedPairEffects: [ClipEffect.ID] {
        clip?.effects.filter { e in
            EffectCatalog.spec(for: e.kind)?.pairs.contains { $0.linkable && e.parameters[$0.y] != nil } == true
        }.map(\.id) ?? []
    }

    /// P5: a linkable pair row (Transform Scale) is linked while its Y member is not stored (Height follows Scale).
    public func isLinked(_ p: EffectProperty) -> Bool {
        guard case .fx(let id, _, _) = p, let pr = p.pair, pr.linkable,
              let e = clip?.effects.first(where: { $0.id == id }) else { return false }
        return e.parameters[pr.y] == nil
    }

    /// Link toggle of a linkable pair row. Off: Height gets Scale's keys (same picture). On: Height is dropped and follows
    /// Scale again (a differing Height is lost, with a notice).
    public func setLinked(_ p: EffectProperty, _ on: Bool) {
        guard case .fx(let id, _, _) = p, let pr = p.pair, pr.linkable, on != isLinked(p),
              var c = workingClip, let i = c.effects.firstIndex(where: { $0.id == id }) else { return }
        if on {
            let x = Self.member(c.effects[i], c.effects[i].kind, pr.x), y = c.effects[i].parameters[pr.y]
            let differs = y.map { $0.isAnimated || abs($0.value - x.value) > 1e-9 } ?? false
            c.effects[i].parameters[pr.y] = nil
            commit(c, "Link \(p.title)")
            if differs { onNotice?("Height set to Width.") }
        } else {
            c.effects[i].parameters[pr.y] = Self.member(c.effects[i], c.effects[i].kind, pr.x).withFreshKeyIDs()
            commit(c, "Unlink \(p.title)")
        }
    }

    /// A pair member as stored, or its catalog default when the effect does not store it (yet).
    static func member(_ e: ClipEffect, _ kind: String, _ key: String) -> AnimatedProperty<Double> {
        e.parameters[key] ?? AnimatedProperty(EffectCatalog.param(kind, key)?.defaultValue ?? 0)
    }

    /// Keys of an effect parameter, typed by its kind.
    static func fxTrack(_ p: EffectProperty, in c: Clip?) -> PropertyTrack? {
        switch p.kind {
        case .color: colorParam(p, in: c).map { .color($0.track) }
        case .vector: pointParam(p, in: c).map { .vector($0.track) }
        default: param(p, in: c).map { .scalar($0.track) }
        }
    }

    /// Every property that exists on `c` right now: the fixed ones and the parameters of its applied effects.
    static func allProperties(in c: Clip) -> [EffectProperty] {
        EffectProperty.builtIns + c.effects.filter { EffectCatalog.spec(for: $0.kind) != nil }
            .flatMap { e in EffectSection.effect(e.id, kind: e.kind).properties }
            + c.masks.flatMap { EffectSection.mask($0.id).properties }
            + c.masks.filter { $0.source == .path }.map { .maskPath($0.id) }
            + customSides(of: c).flatMap { EffectSection.animation($0).properties }   // a preset side has no rows to edit
    }

    func track(_ p: EffectProperty, in c: Clip?) -> PropertyTrack? {
        guard let a = c?.animation else { return nil }
        switch p {
        case .position: return .vector(a.position.track)
        case .scale: return .vector(a.scale.track)
        case .anchor: return .vector(a.anchor.track)
        case .rotation: return .scalar(a.rotation.track)
        case .tiltX: return .scalar(a.tiltX.track)
        case .tiltY: return .scalar(a.tiltY.track)
        case .opacity: return .scalar(a.opacity.track)
        case .volume: return .scalar(a.volume.track)
        case .shutterAngle: return .scalar(a.shutterAngle.track)
        case .antiFlicker: return .scalar(a.antiFlicker.track)
        case .fx: return Self.fxTrack(p, in: c)
        case .mask: return Self.maskParam(p, in: c).map { .scalar($0.track) }
        case .maskPath(let id): return c?.mask(id).map { .path($0.path.track) }
        case .anim(_, .position): return Self.animVector(p, in: c).map { .vector($0.track) }
        case .anim: return Self.animScalar(p, in: c).map { .scalar($0.track) }
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
        endColorGesture()
        closeEmittedGesture()
        gestureBase = clip
        peerGestureBase = isMulti ? peers : nil
        gestureName = nil
    }

    /// A gesture that reached the session is ended there before its state is dropped (the shown clip changes, the next
    /// gesture begins without a mouse-up of the last): every gesture that emitted ends exactly once, never zero times.
    private func closeEmittedGesture() {
        guard gestureEmitted else { return }
        gestureEmitted = false
        onGestureEnded?()
    }

    /// A gesture that reached the session ended (mouse up, Escape, the color well closed): the host ends the session's
    /// gesture too (`EditorSession.endGesture`), so the step is final and the next edit starts one of its own.
    @ObservationIgnored public var onGestureEnded: (() -> Void)?

    public func endGesture() {
        let emitted = gestureEmitted
        gestureBase = nil
        peerGestureBase = nil
        gestureEmitted = false
        if emitted { onGestureEnded?() }
    }

    var inGesture: Bool { gestureBase != nil }

    /// Escape during a gesture: puts the clip back as it was when the gesture began, coalesced into the gesture's
    /// undo step under the gesture's own name. History drops a step that ends where it began, so nothing is left to undo.
    public func cancelGesture() {
        if let base = gestureBase, base != clip || (peerGestureBase.map { $0 != peers } ?? false) {
            commit(base, gestureName ?? "Edit Effects", peers: peerGestureBase)
        }
        if deferEmit { deferEmit = false; deferredEditName = nil; revertPendingFrameSteps() }
        endGesture()
    }

    /// Stores `new`, and emits it unless nothing changed.
    /// `newPeers` (multi-select): the peers as the same edit leaves them; they go to the session with `new` in one step.
    func commit(_ new: Clip, _ englishName: String, peers newPeers: [Clip]? = nil) {
        let name = SQL10n.undoName(englishName)
        let peersChanged = newPeers.map { $0 != peers } ?? false
        guard new != clip || peersChanged else { return }
        if !committingColor { endColorGesture() }
        let old = clip
        clip = new
        if let newPeers, peersChanged { peers = newPeers }
        pruneSelection()
        if deferEmit { deferredEditName = name; return }     // key drag: the lanes show it, the session hears once
        let coalescing = inGesture && gestureEmitted
        if inGesture { gestureEmitted = true; gestureName = name }
        if newPeers != nil, isMulti {
            if let onEditMany { onEditMany([new] + peers, name, coalescing) } else { ([new] + peers).forEach { onEdit?($0, name, coalescing) } }
            return
        }
        emit(new, old: old, name, coalescing: coalescing)
    }

    /// Sends a stored clip to the session (the clip, and the audio partner's share of it).
    private func emit(_ new: Clip, old: Clip?, _ name: String, coalescing: Bool) {
        if let h = itemHost {
            let merged = h.host.applyingItemProjection(new, layer: h.layer)
            if merged == h.host {      // a locked item takes no edit: show it as it was
                if let back = h.host.graphicsItemProjection(h.layer) { clip = back }
                return
            }
            itemHost = (merged, h.layer)
            onEdit?(merged, name, coalescing)
            return
        }
        guard let partner = audioPartner, let own = ownVolume, let old else { onEdit?(new, name, coalescing); return }
        // Video clip with an audio partner: Volume and audio effects belong to the partner, everything else to the video clip.
        let newFX = new.effects.filter(\.isAudio), oldFX = old.effects.filter(\.isAudio)
        if new.animation.volume != old.animation.volume || newFX != oldFX {
            let back = Time.zero - partnerOffset
            var p = partner
            p.animation.volume = back == .zero ? new.animation.volume : new.animation.volume.shifted(by: back)
            p.effects = p.effects.filter { !$0.isAudio } + newFX.map { back == .zero ? $0 : $0.shifted(by: back) }
            audioPartner = p
            onAudioEdit?(p, name, coalescing)
        }
        var video = new; video.animation.volume = own; video.effects.removeAll(where: \.isAudio)
        var before = old; before.animation.volume = own; before.effects.removeAll(where: \.isAudio)
        if video != before { onEdit?(video, name, coalescing) }
    }

    /// Clip an edit starts from (the gesture's base inside a gesture). Any edit other than the color panel's own
    /// closes an open color gesture first, so it never computes from the color gesture's stale base.
    var workingClip: Clip? {
        endColorGesture()
        return gestureBase ?? clip
    }

    // MARK: Color panel gesture

    /// Continuous color from the color panel: consecutive calls for the same property are one undo step. The gesture
    /// ends on `endColorGesture()` (well deactivated, panel closed) or as soon as anything else edits, begins a gesture,
    /// moves the playhead, changes the selection or the clip.
    @discardableResult
    public func setColorContinuously(_ p: EffectProperty, to color: EffectColor) -> Bool {
        if colorGesture != p {
            endColorGesture()
            closeEmittedGesture()
            gestureBase = clip
            peerGestureBase = isMulti ? peers : nil
            colorGesture = p
        }
        committingColor = true
        defer { committingColor = false }
        return applyColor(p, color, from: gestureBase ?? clip)
    }

    /// Ends an open color gesture (no-op otherwise; never ends another gesture).
    public func endColorGesture() {
        guard colorGesture != nil else { return }
        colorGesture = nil
        endGesture()
    }

    // MARK: Stopwatch and key buttons

    @discardableResult
    public func toggleStopwatch(_ p: EffectProperty, confirmRemoval: Bool = false) -> StopwatchOutcome {
        if case .maskPath(let id) = p { return toggleMaskPathStopwatch(id, confirmRemoval: confirmRemoval) }
        guard var c = clip else { return .unavailable }
        let local = keyLocal
        if isAnimated(p) {
            guard confirmRemoval else { return .needsConfirmation }
            clearKeys(&c, p, at: local)
            selection = selection.filter { $0.property != p.id }
            // Multi-select: every selected clip loses its keys of the property, frozen at its own playhead.
            commit(c, "Remove Keyframes", peers: editedPeers(p) { c, q, l, _ in clearKeys(&c, q, at: Self.clamped(l, in: c)) })
            return .removed
        }
        guard playheadInClip || isMulti else { return .unavailable }
        withVector(&c, p) { $0.track.insertKey(Keyframe(time: local, value: $0.value(atLocal: local)), smoothSpatial: p == .position) }
        withScalar(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
        withColor(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
        // Multi-select: every selected clip gets a key at its own playhead (its nearest end when the playhead is outside it).
        commit(c, "Add Keyframe", peers: editedPeers(p) { c, q, l, _ in insertKeyHere(&c, q, at: Self.clamped(l, in: c)) })
        return .added
    }

    /// Add / remove button: key at the playhead on, or off again. On a static property it is the stopwatch.
    /// Multi-select: the same on every selected clip, at its own playhead, in one undo step.
    @discardableResult
    public func toggleKeyAtPlayhead(_ p: EffectProperty) -> StopwatchOutcome {
        if case .maskPath(let id) = p { return toggleMaskPathKey(id) }
        guard var c = clip else { return .unavailable }
        guard isAnimated(p) else { return toggleStopwatch(p) }
        let local = keyLocal
        if keyTime(p, at: local) {
            removeKeyHere(&c, p, at: local)
            commit(c, "Remove Keyframe", peers: editedPeers(p) { c, q, l, _ in removeKeyHere(&c, q, at: Self.clamped(l, in: c)) })
            return .removed
        }
        guard playheadInClip || isMulti else { return .unavailable }
        withVector(&c, p) { $0.track.insertKey(Keyframe(time: local, value: $0.value(atLocal: local)), smoothSpatial: p == .position) }
        let shown: Double? = local == localPlayhead ? scalarValue(p) : nil   // hues the short way, Color wheels on the disc
        let before = c
        withScalar(&c, p) { $0.track.insert(Keyframe(time: local, value: shown ?? $0.value(atLocal: local))) }
        Self.followShown(&c, p, before: before, local: local)
        withColor(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
        commit(c, "Add Keyframe", peers: editedPeers(p) { c, q, l, _ in insertKeyHere(&c, q, at: Self.clamped(l, in: c)) })
        return .added
    }

    /// Add Keyframe command: puts a key at the playhead, never removes one. `.unavailable` when a key is already
    /// there (or the property is a mask path), so the caller can say so instead of toggling it off.
    @discardableResult
    public func addKeyAtPlayhead(_ p: EffectProperty) -> StopwatchOutcome {
        if case .maskPath = p { return .unavailable }
        if isAnimated(p), keyTime(p, at: keyLocal) { return .unavailable }
        return toggleKeyAtPlayhead(p)
    }

    /// Where the key buttons key the shown clip: the playhead, or with several clips selected the playhead clamped into it.
    private var keyLocal: Time {
        guard isMulti, let c = clip else { return localPlayhead }
        return Self.clamped(localPlayhead, in: c)
    }

    nonisolated static func clamped(_ l: Time, in c: Clip) -> Time { min(max(l, .zero), c.duration) }

    /// Drops every key of `p`, the value frozen as shown at `local`.
    private func clearKeys(_ c: inout Clip, _ p: EffectProperty, at local: Time) {
        withVector(&c, p) { $0.value = $0.value(atLocal: local); $0.track = KeyframeTrack() }
        let before = c
        withScalar(&c, p) { $0.value = $0.value(atLocal: local); $0.track = KeyframeTrack() }
        withColor(&c, p) { $0.value = $0.value(atLocal: local); $0.track = KeyframeTrack() }
        Self.followShown(&c, p, before: before, local: local)
    }

    /// A key of `p` at `local` holding the value shown there.
    private func insertKeyHere(_ c: inout Clip, _ p: EffectProperty, at local: Time) {
        withVector(&c, p) { $0.track.insertKey(Keyframe(time: local, value: $0.value(atLocal: local)), smoothSpatial: p == .position) }
        let before = c
        withScalar(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
        Self.followShown(&c, p, before: before, local: local)
        withColor(&c, p) { $0.track.insert(Keyframe(time: local, value: $0.value(atLocal: local))) }
    }

    /// Removes the key of `p` at `local` (nothing when there is none).
    private func removeKeyHere(_ c: inout Clip, _ p: EffectProperty, at local: Time) {
        withVector(&c, p) { Self.removeKey(&$0, at: local) }
        let before = c
        withScalar(&c, p) { Self.removeKey(&$0, at: local) }
        Self.followShown(&c, p, before: before, local: local)
        withColor(&c, p) { Self.removeKey(&$0, at: local) }
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

    public func goToPreviousKey(_ p: EffectProperty) { if let t = previousKeyTime(p) { revealPlayhead(t); onSeek?(t) } }
    public func goToNextKey(_ p: EffectProperty) { if let t = nextKeyTime(p) { revealPlayhead(t); onSeek?(t) } }

    // MARK: Editing values

    /// The property should show `v` (native units) at the playhead.
    /// Static: sets the value. Animated with selected keys of this property: relative edit of all of them
    /// (PHASE4 rule 7). Animated otherwise: adds or replaces the key at the playhead.
    @discardableResult
    public func setValue(_ p: EffectProperty, component: EffectComponent = .all, to v: Double) -> Bool {
        guard var c = workingClip else { return false }
        let local = localPlayhead
        let inRange = playheadInClip
        // Checkbox / popup values are absolute: a relative edit of several selected keys would leave the 0...1 / index range.
        let selected = p.paramKind?.isStepped == true ? [] : selectedKeysAtPlayhead(p)
        guard applyValue(&c, p, component: component, v, local: local, inRange: inRange, selected: selected) else { return false }
        let others = editedPeers(p) { c, q, l, r in _ = applyValue(&c, q, component: component, v, local: l, inRange: r, selected: []) }
        commit(c, "Change \(p.title)", peers: others)
        return true
    }

    /// Several parameters in ONE commit (one undo step), e.g. loading a preset.
    func setValues(_ pairs: [(EffectProperty, Double)], name: String) {
        guard var c = workingClip else { return }
        let local = localPlayhead, inRange = playheadInClip
        var any = false
        for (p, v) in pairs where applyValue(&c, p, component: .all, v, local: local, inRange: inRange, selected: []) { any = true }
        if any { commit(c, name) }
    }

    private func applyValue(_ c: inout Clip, _ p: EffectProperty, component: EffectComponent, _ value: Double, local: Time,
                            inRange: Bool, selected: Set<UUID>) -> Bool {
        guard value.isFinite else { return false }
        let v = p.clampedNative(value, picture: displayPicture)      // every entry point (field, graph, preset, relative key edit) stays inside the range
        var ok = false
        let before = c
        withScalar(&c, p, local: local) { prop in
            ok = Self.apply(&prop, new: v, local: local, inRange: inRange, selected: selected)
        }
        Self.followShown(&c, p, before: before, local: local)
        withVector(&c, p, local: local) { prop in
            let cur = prop.value(atLocal: local)
            let new: Vec2
            switch (p.kind, component) {
            case (.uniform, .x) where !uniformScale: new = Vec2(v, cur.y)
            case (.uniform, .y) where !uniformScale: new = Vec2(cur.x, v)
            case (.uniform, _), (_, .all): new = Vec2(v, v)
            case (_, .x): new = Vec2(v, cur.y)
            case (_, .y): new = Vec2(cur.x, v)
            }
            ok = Self.apply(&prop, new: new, local: local, inRange: inRange, selected: selected, smoothSpatial: p == .position)
        }
        return ok
    }

    /// A color parameter should show `color` at the playhead (same rules as `setValue`: static value, selected keys,
    /// or the key at the playhead).
    @discardableResult
    public func setColor(_ p: EffectProperty, to color: EffectColor) -> Bool {
        applyColor(p, color, from: workingClip)
    }

    /// Colors are absolute: selected keys all take `color` (a relative shift would push channels out of 0...1).
    private func applyColor(_ p: EffectProperty, _ color: EffectColor, from base: Clip?) -> Bool {
        guard var c = base, p.kind == .color else { return false }
        let local = localPlayhead, inRange = playheadInClip, selected = selectedKeysAtPlayhead(p)
        var ok = false
        withColor(&c, p) { prop in
            let ids = prop.track.keys.map(\.id).filter { selected.contains($0) }
            if prop.isAnimated && !ids.isEmpty {
                for id in ids { prop.track.set(id, value: color) }
                ok = true
            } else {
                ok = Self.apply(&prop, new: color, local: local, inRange: inRange, selected: [])
            }
        }
        guard ok else { return false }
        let others = editedPeers(p) { c, q, l, r in withColor(&c, q) { _ = Self.apply(&$0, new: color, local: l, inRange: r, selected: []) } }
        commit(c, "Change \(p.title)", peers: others)
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
            if t.anchor != start.anchor, c.animation.position.isAnimated {
                // Anchor drag: Position only compensates so the picture stays put. With animated Position every key
                // gets the same compensation (a key at the playhead alone would bend the motion path).
                let d = t.position - start.position
                withVector(&c, .position) { p in for id in p.track.keys.map(\.id) { p.track.update(id) { $0.value = $0.value + d } } }
            } else if Self.movesWholeMotion(c) {
                withVector(&c, .position) { $0 = $0.movedBase(to: t.position, atLocal: local) }
            } else {
                withVector(&c, .position) { ok = Self.apply(&$0, new: t.position, local: local, inRange: inRange, selected: [], smoothSpatial: true) && ok }
            }
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
        commit(c, "Change Transform")
        return true
    }

    /// Text and graphic clips: a typed or dragged Position is the base of the whole animation, so every key moves with
    /// it (the fly-in keeps its shape) instead of getting a key at the playhead. Pictures keep key-at-playhead.
    static func movesWholeMotion(_ c: Clip) -> Bool {
        c.animation.position.isAnimated && (c.generator?.kind == GeneratorRef.text || c.isGraphics)
    }

    /// A vector property (position, anchor, point parameter) should show `v` at the playhead: both components in one pass
    /// and one commit (two `setValue` calls in a gesture would each start from the gesture base and lose the first).
    @discardableResult
    public func setVector(_ p: EffectProperty, to v: Vec2) -> Bool {
        guard p.kind == .vector, var c = workingClip else { return false }
        let local = localPlayhead, inRange = playheadInClip
        let selected = selectedKeysAtPlayhead(p)
        var ok = false
        if p == .position, selected.isEmpty, Self.movesWholeMotion(c) {
            withVector(&c, p) { $0 = $0.movedBase(to: v, atLocal: local) }
            ok = true
        } else {
            withVector(&c, p) { ok = Self.apply(&$0, new: v, local: local, inRange: inRange, selected: selected, smoothSpatial: p == .position) }
        }
        guard ok else { return false }
        let others = editedPeers(p) { c, q, l, r in
            withVector(&c, q) { _ = Self.apply(&$0, new: v, local: l, inRange: r, selected: [], smoothSpatial: q == .position) }
        }
        commit(c, "Change \(p.title)", peers: others)
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

    /// Selected keys of `p` that an edit at the playhead applies to: only when the playhead sits on one of them
    /// (then all selected keys shift together). A key selected elsewhere never captures the edit: the value at the
    /// playhead always wins and creates a key there (Premiere).
    private func selectedKeysAtPlayhead(_ p: EffectProperty) -> Set<UUID> {
        let selected = selectedKeyIDs(p)
        guard !selected.isEmpty, let t = track(p) else { return [] }
        let l = localPlayhead
        return t.times.contains { $0.time == l && selected.contains($0.id) } ? selected : []
    }

    static func apply<V: KeyframeValue>(_ prop: inout AnimatedProperty<V>, new: V, local: Time,
                                                inRange: Bool, selected: Set<UUID>,
                                                smoothSpatial: Bool = false) -> Bool {
        guard prop.isAnimated else { prop.value = new; return true }
        if !selected.isDisjoint(with: prop.track.keys.map(\.id)) {
            return prop.track.setValue(new, at: local, selected: selected)
        }
        if let k = prop.track.keys.first(where: { $0.time == local }) {
            prop.track.set(k.id, value: new)
            return true
        }
        guard inRange else { return false }
        prop.track.insertKey(Keyframe(time: local, value: new), smoothSpatial: smoothSpatial)
        return true
    }

    // MARK: Selection

    private func pruneSelection() {
        guard let c = clip else { selection = []; return }
        let tracks = Self.tracks(of: c)
        var alive = Set<SummaryMember>()
        for p in Self.allProperties(in: c) {
            let ids = Set(tracks[p.id]?.keyIDs ?? [])
            alive.formUnion(selection.filter { $0.property == p.id && ids.contains($0.keyID) })
        }
        alive.formUnion(liveMagicMembers(selection))
        if alive != selection { selection = alive }
    }

    public func select(_ members: [SummaryMember], extend: Bool) {
        let set = Set(members)
        selection = extend ? selection.symmetricDifference(set) : set
    }

    /// Keys, section selection and expansion that belonged to deleted masks must not linger (they would target nothing).
    func forgetRemovedMasks(_ ids: [ClipMask.ID]) {
        for id in ids {
            let props = EffectSection.mask(id).properties
            let pids = Set(EffectSection.mask(id).keyProperties.map(\.id))
            selection = selection.filter { !pids.contains($0.property) }
            expanded.subtract(props)
            if selectedSection == .mask(id) { selectedSection = nil }
        }
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
        return Self.mergingMagic(KeyframeSummary(tracks: Self.tracks(of: c)).groups(of: Set(section.keyProperties.map(\.id))),
                                 magicSummaryKeys(section))
    }

    /// Summary keys of one closed group of a Color effect (the group's switch and numbers), empty while the group is open.
    public func colorGroupSummaryKeys(_ effect: ClipEffect.ID, _ groupKey: String) -> [SummaryKey] {
        guard let c = clip, !openColorGroups.contains(Self.colorGroupID(effect, groupKey)) else { return [] }
        let params = EffectCatalog.spec(for: ClipEffect.colorKind)?.params ?? []
        let ids = Set(params.filter { ColorEffectGroups.groupKey(of: $0.key) == groupKey }
            .map { EffectProperty.fx(effect, kind: ClipEffect.colorKind, key: $0.key).id })
        return KeyframeSummary(tracks: Self.tracks(of: c)).groups(of: ids)
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
        focusedProperty = p
        select([SummaryMember(property: p.id, keyID: id)], extend: extend)
    }

    /// Marquee: all keys of `properties` whose clip-local time lies in `range`.
    public func selectKeys(in range: ClosedRange<Time>, properties: Set<EffectProperty>, extend: Bool) {
        let hit = keys(in: range, properties: properties)
        selection = extend ? selection.union(hit) : hit
    }

    /// All keys of `properties` whose clip-local time lies in `range`.
    public func keys(in range: ClosedRange<Time>, properties: Set<EffectProperty>) -> Set<SummaryMember> {
        var hit = Set<SummaryMember>()
        for p in properties {
            for k in laneKeys(p) where range.contains(k.time) {
                hit.insert(SummaryMember(property: p.id, keyID: k.id))
            }
        }
        return hit
    }

    // MARK: Key edits on the selection

    static func tracks(of c: Clip) -> [PropertyID: PropertyTrack] {
        let a = c.animation
        var out: [PropertyID: PropertyTrack] = [:]
        func put(_ p: EffectProperty, _ t: PropertyTrack) { if !t.keyIDs.isEmpty { out[p.id] = t } }
        put(.position, .vector(a.position.track)); put(.scale, .vector(a.scale.track))
        put(.anchor, .vector(a.anchor.track)); put(.rotation, .scalar(a.rotation.track))
        put(.tiltX, .scalar(a.tiltX.track)); put(.tiltY, .scalar(a.tiltY.track))
        put(.opacity, .scalar(a.opacity.track)); put(.volume, .scalar(a.volume.track))
        put(.shutterAngle, .scalar(a.shutterAngle.track))
        put(.antiFlicker, .scalar(a.antiFlicker.track))
        for p in allProperties(in: c) {
            if case .fx = p, let t = fxTrack(p, in: c) { put(p, t) }
            if case .mask = p, let m = maskParam(p, in: c) { put(p, .scalar(m.track)) }
            if case .maskPath(let id) = p, let m = c.mask(id) { put(p, .path(m.path.track)) }
            if case .anim(_, let param) = p {
                if param == .position { if let v = animVector(p, in: c) { put(p, .vector(v.track)) } }
                else if let v = animScalar(p, in: c) { put(p, .scalar(v.track)) }
            }
        }
        return out
    }

    func write(_ tracks: [PropertyID: PropertyTrack], into c: inout Clip) {
        for p in Self.allProperties(in: c) {
            let t = tracks[p.id]
            switch p {
            case .position: if case .vector(let v)? = t { c.animation.position.track = v }
            case .scale: if case .vector(let v)? = t { c.animation.scale.track = v }
            case .anchor: if case .vector(let v)? = t { c.animation.anchor.track = v }
            case .rotation: if case .scalar(let s)? = t { c.animation.rotation.track = s }
            case .tiltX: if case .scalar(let s)? = t { c.animation.tiltX.track = s }
            case .tiltY: if case .scalar(let s)? = t { c.animation.tiltY.track = s }
            case .opacity: if case .scalar(let s)? = t { c.animation.opacity.track = s }
            case .volume: if case .scalar(let s)? = t { c.animation.volume.track = s }
            case .shutterAngle: if case .scalar(let s)? = t { c.animation.shutterAngle.track = s }
            case .antiFlicker: if case .scalar(let s)? = t { c.animation.antiFlicker.track = s }
            case .fx:
                switch t {
                case .scalar(let s)?: Self.withFX(&c, p) { $0.track = s }
                case .vector(let v)?: Self.withFXPoint(&c, p) { $0.track = v }
                case .color(let k)?: Self.withFXColor(&c, p) { $0.track = k }
                case .path?, nil: break
                }
            case .mask: if case .scalar(let s)? = t { Self.withMask(&c, p) { $0.track = s } }
            case .maskPath(let id): if case .path(let k)? = t { c.updateMask(id) { $0.path.track = k } }
            case .anim:
                switch t {
                // Only a row that changed is stored: every other key of the side keeps its id.
                case .scalar(let s)?: if Self.animScalar(p, in: c)?.track != s { withScalar(&c, p) { $0.track = s } }
                case .vector(let v)?: if Self.animVector(p, in: c)?.track != v { withVector(&c, p) { $0.track = v } }
                case .color?, .path?, nil: break
                }
            }
        }
    }

    /// Moves the selected keys (all properties) in time by `delta`, from the gesture base. Not held inside the clip. Keys pass unselected neighbors; landing exactly on one snaps a frame further (nothing is replaced).
    /// Steps only change the shown clip, `endKeyMove` sends the one edit. Returns the delta applied.
    @discardableResult
    public func moveSelection(by delta: Time, duplicate: Bool = false) -> Time {
        guard let c = workingClip else { return .zero }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        let members = selection.filter { s.tracks[$0.property]?.keyIDs.contains($0.keyID) ?? false }
        guard !members.isEmpty else { return .zero }
        let times = members.flatMap { m in (s.tracks[m.property]?.times ?? []).filter { $0.id == m.keyID }.map(\.time) }
        // Keys may leave the clip on either side (Premiere): they stay in the clip's data, are not drawn, and a Select All
        // still takes them. Only a day either way is the stop, so a runaway drag cannot overflow the time.
        let limits = Time(-86_400, 1) ... Time(86_400, 1)
        let clamped = min(max(delta, limits.lowerBound), limits.upperBound)
        let applied = duplicate ? s.moveDuplicating(members, by: clamped, frame: frameDuration, limits: limits)
                                : s.move(members, by: clamped, frame: frameDuration, limits: limits)
        var out = c
        write(s.tracks, into: &out)
        if inGesture { deferEmit = true }
        commit(out, duplicate ? "Duplicate Keyframes" : "Move Keyframes")
        return applied
    }

    /// Ends a key drag: one undo step, and the moved keys stay selected (Premiere). A value change at the playhead
    /// still only edits selected keys when the playhead sits on one of them (`selectedKeysAtPlayhead`).
    public func endKeyMove() {
        let base = gestureBase, name = deferredEditName
        deferEmit = false; deferredEditName = nil
        let depth = speedSession?.undoStepDepth ?? 0
        if let name, let c = clip, c != base {      // the one edit of the drag: one undo step
            emit(c, old: base, name, coalescing: false)
            gestureEmitted = true
        }
        registerPendingFrameSteps(since: depth)
        endGesture()
    }

    public func applyEasing(_ curve: EasingCurve, side: EaseSide = .both) {
        guard let c = workingClip, !selection.isEmpty else { return }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        s.apply(curve, to: selection, side: side)
        forgetHeldKinds()
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Easing")
    }

    /// The selected keys got an ease by name: Toggle Hold has nothing to bring back for them.
    func forgetHeldKinds() { for m in selection { heldKinds[m.keyID] = nil } }

    /// Hold Ahead can be stored on every selected key. Animation (In/Out) tracks live inside text payloads, templates
    /// and Caption Looks and store it as a Hold (`AnimationTrack`), so with one of their keys selected it is not offered.
    public var selectionTakesHoldAhead: Bool {
        !selection.contains { EffectProperty(rawValue: $0.property.rawValue)?.isAnimationRow == true }
    }

    /// All selected keys hold: they leave it; otherwise all become a hold, each the kind (Hold or Hold Ahead) it was
    /// when this toggle last took it out (a key it never took out becomes a Hold). The memory only holds while the
    /// clip is the one the last toggle left: undo, a dragged handle or any other edit in between clears it.
    public func toggleHold() {
        guard let c = workingClip, !selection.isEmpty else { return }
        if heldKindsRevision != clipRevision { heldKinds = [:] }
        defer { heldKindsRevision = clipRevision }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        for m in selection {
            if let kind = s.interpolation(of: m), kind.isHold { heldKinds[m.keyID] = kind }
        }
        s.toggleHold(selection, restoring: heldKinds)
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Toggle Hold Keyframes")
    }

    /// Removes the selected keys. A property left without keys keeps the value it shows at the playhead.
    public func deleteSelection() {
        guard var c = clip, !selection.isEmpty else { return }
        let local = localPlayhead
        let before = c
        for p in Self.allProperties(in: c) {
            let ids = selectedKeyIDs(p)
            guard !ids.isEmpty else { continue }
            withVector(&c, p) { Self.remove(ids, from: &$0, local: local) }
            withScalar(&c, p) { Self.remove(ids, from: &$0, local: local) }
            withColor(&c, p) { Self.remove(ids, from: &$0, local: local) }
            if case .maskPath(let id) = p { c.updateMask(id) { Self.remove(ids, from: &$0.path, local: local) } }
            Self.followShown(&c, p, before: before, local: local)
        }
        let depth = speedSession?.undoStepDepth ?? 0
        let gone = removeSelectedMagicFrames(&c).filter { !$0.isEmpty }
        selection = []
        commit(c, "Delete Keyframes")
        // The deleted mattes are no project state: their own undo step, so one Undo brings the frames back.
        if !gone.isEmpty, let session = speedSession {
            let frames = magicFrames
            let undo: () -> Void = { gone.forEach { frames.restore($0) } }
            // Redo takes out the frames that were deleted, by identity: not one tracked again at that time since.
            let redo: () -> Void = { gone.forEach { frames.remove(matching: $0) } }
            if deferEmit {
                // Mid key drag the clip edit is not emitted yet: the frames join the drag's one undo step (`endKeyMove`).
                pendingFrameSteps.append((undo, redo))
            } else {
                session.registerSideStep("Delete Keyframes", since: depth, undo: undo, redo: redo)
            }
        }
    }

    /// Frame deletes made during a key drag, waiting for the drag's one undo step.
    @ObservationIgnored private var pendingFrameSteps: [(undo: () -> Void, redo: () -> Void)] = []

    /// The drag's step is in the session (`depth` taken before it): the pending frame deletes belong to it, so it stays ONE
    /// undo step. Without a step of its own they become the named step of the delete, as outside a drag.
    private func registerPendingFrameSteps(since depth: Int) {
        guard !pendingFrameSteps.isEmpty, let session = speedSession else { return }
        let steps = pendingFrameSteps
        pendingFrameSteps = []
        session.registerSideStep("Delete Keyframes", since: depth,
                                 undo: { for s in steps.reversed() { s.undo() } }, redo: { for s in steps { s.redo() } })
    }

    /// The drag ended without its edit reaching the session (canceled, clip replaced): the deleted frames come back, as
    /// the clip did.
    private func revertPendingFrameSteps() {
        let steps = pendingFrameSteps
        pendingFrameSteps = []
        for s in steps.reversed() { s.undo() }
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
        case .tiltX: ClipAnimation().tiltX
        case .tiltY: ClipAnimation().tiltY
        case .opacity: ClipAnimation().opacity
        case .volume: ClipAnimation().volume
        case .shutterAngle: ClipAnimation().shutterAngle
        case .antiFlicker: ClipAnimation().antiFlicker
        case .fx(_, let kind, let key): effectDefaults.effect(kind)?.parameters[key] ?? ClipEffect.defaultParameters(for: kind)[key]
        case .mask(_, let m): AnimatedProperty(m.defaultValue)
        case .anim(_, let param) where param != .position: AnimatedProperty(param.rest)
        default: nil
        }
    }

    /// Default of a color parameter (nil for anything else).
    public func defaultColor(_ p: EffectProperty) -> EffectColor? {
        if case .fx(_, let kind, let key) = p, let u = effectDefaults.effect(kind)?.colors[key] { return u.value }
        if case .color(let d)? = p.paramKind { return d }
        return nil
    }

    /// Default of a point parameter (nil for anything else).
    public func defaultPoint(_ p: EffectProperty) -> Vec2? {
        if let pr = p.pair, case .fx(let id, let kind, _) = p,
           let x = defaultValue(.fx(id, kind: kind, key: pr.x)), let y = defaultValue(.fx(id, kind: kind, key: pr.y)) {
            return Vec2(x.value, y.value)
        }
        if case .fx(_, let kind, let key) = p, let u = effectDefaults.effect(kind)?.points[key] { return u.value }
        if case .point(let d)? = p.paramKind { return d }
        return nil
    }

    /// True when the property has no keys and sits at its default (the reset button is dimmed then).
    public func isDefault(_ p: EffectProperty) -> Bool {
        guard let c = clip else { return true }
        let d = ClipAnimation()
        switch p {
        case .position: return c.animation.position == d.position
        case .scale: return c.animation.scale == d.scale
        case .anchor: return c.animation.anchor == d.anchor
        case .anim(_, .position): return !(Self.animVector(p, in: c)?.isAnimated ?? false)
        case .fx(_, let kind, let key) where p.kind == .color:
            guard let cur = Self.colorParam(p, in: c) else { return true }
            if let u = effectDefaults.effect(kind)?.colors[key], u.isAnimated { return cur.sameCurve(as: u) }
            return cur.value == defaultColor(p) && !cur.isAnimated
        case .fx(let id, let kind, _) where p.pair != nil:
            // Member by member (the X member's EffectProperty *is* the pair row, so read storage directly).
            guard let pr = p.pair, let e = c.effects.first(where: { $0.id == id }) else { return true }
            return [pr.x, pr.y].allSatisfy { key in
                let cur = Self.member(e, kind, key)
                guard let def = defaultValue(.fx(id, kind: kind, key: key)) else { return true }
                return def.isAnimated ? cur.sameCurve(as: def) : cur.value == def.value && !cur.isAnimated
            }
        case .fx(_, let kind, let key) where p.kind == .vector:
            guard let cur = Self.pointParam(p, in: c) else { return true }
            if let u = effectDefaults.effect(kind)?.points[key], u.isAnimated { return cur.sameCurve(as: u) }
            return cur.value == defaultPoint(p) && !cur.isAnimated
        default:
            guard let cur = Self.scalar(p, in: c), let def = defaultValue(p) else { return true }
            if def.isAnimated { return cur.sameCurve(as: def) }
            return cur.value == def.value && !cur.isAnimated
        }
    }

    private static func scalar(_ p: EffectProperty, in c: Clip) -> AnimatedProperty<Double>? {
        switch p {
        case .rotation: c.animation.rotation
        case .tiltX: c.animation.tiltX
        case .tiltY: c.animation.tiltY
        case .opacity: c.animation.opacity
        case .volume: c.animation.volume
        case .shutterAngle: c.animation.shutterAngle
        case .antiFlicker: c.animation.antiFlicker
        case .fx: param(p, in: c)
        case .mask: maskParam(p, in: c)
        case .anim: animScalar(p, in: c)
        default: nil
        }
    }

    private func resetInPlace(_ c: inout Clip, _ p: EffectProperty) {
        let d = ClipAnimation()
        switch p {
        case .position: c.animation.position = d.position
        case .scale: c.animation.scale = d.scale
        case .anchor: c.animation.anchor = d.anchor
        case .anim(_, .position): withVector(&c, p) { $0 = AnimatedProperty(.zero) }
        case .fx(_, let kind, let key) where p.kind == .color:
            if let u = effectDefaults.effect(kind)?.colors[key] { withColor(&c, p) { $0 = u.withFreshKeyIDs() } }
            else if let def = defaultColor(p) { withColor(&c, p) { $0 = AnimatedProperty(def) } }
        case .fx(let id, let kind, _) where p.pair != nil:
            guard let pr = p.pair, let i = c.effects.firstIndex(where: { $0.id == id }) else { return }
            for key in [pr.x, pr.y] {
                if let def = defaultValue(.fx(id, kind: kind, key: key)) { c.effects[i].parameters[key] = def.withFreshKeyIDs() }
            }
            if pr.linkable { c.effects[i].parameters[pr.y] = nil }       // P5: a reset Scale is linked again
        case .fx(_, let kind, let key) where p.kind == .vector:
            if let u = effectDefaults.effect(kind)?.points[key] { withVector(&c, p) { $0 = u.withFreshKeyIDs() } }
            else if let def = defaultPoint(p) { withVector(&c, p) { $0 = AnimatedProperty(def) } }
        default:
            guard let def = defaultValue(p) else { return }
            withScalar(&c, p) { $0 = def.withFreshKeyIDs() }
        }
    }

    /// Reset arrow: the property goes back to its default and its keys are removed, one undo step (animated or not).
    /// "Reset at Playhead" (`resetAtPlayhead`) is the separate context-menu item. Always true.
    @discardableResult
    public func reset(_ p: EffectProperty) -> Bool {
        resetAll(p)
        return true
    }

    /// Default value in place of the value at the playhead (key created or replaced).
    @discardableResult
    public func resetAtPlayhead(_ p: EffectProperty) -> Bool {
        guard var c = workingClip, playheadInClip, resetValue(&c, p, local: localPlayhead, inRange: true) else { return false }
        // Multi-select: every other clip at its own playhead (a static one just gets the default).
        commit(c, "Reset \(p.title)", peers: editedPeers(p) { c, q, l, r in _ = resetValue(&c, q, local: l, inRange: r) })
        return true
    }

    /// The default in place of `p`'s value at `local` (static: the value; animated: the key there, added when `inRange`).
    private func resetValue(_ c: inout Clip, _ p: EffectProperty, local: Time, inRange: Bool) -> Bool {
        let d = ClipAnimation()
        var ok = false
        withVector(&c, p) { prop in
            let def: Vec2 = defaultPoint(p) ?? (p == .position ? d.position.value : p == .scale ? d.scale.value : d.anchor.value)
            ok = Self.apply(&prop, new: def, local: local, inRange: inRange, selected: [])
        }
        withScalar(&c, p) { prop in
            guard let def = defaultValue(p)?.value else { return }
            ok = Self.apply(&prop, new: def, local: local, inRange: inRange, selected: [])
        }
        withColor(&c, p) { prop in
            guard let def = defaultColor(p) else { return }
            ok = Self.apply(&prop, new: def, local: local, inRange: inRange, selected: [])
        }
        return ok
    }

    /// Reset one property to its default and drop its keys: one undo step.
    public func resetAll(_ p: EffectProperty) {
        guard var c = clip else { return }
        resetInPlace(&c, p)
        selection = selection.filter { $0.property != p.id }
        commit(c, "Reset \(p.title)", peers: editedPeers(p) { c, q, _, _ in resetInPlace(&c, q) })
    }

    /// The variant property a Motion row writes to (both tilt rows are `.tilt`); nil for rows a variant does not override.
    static func variantProperty(of p: EffectProperty) -> VariantProperty? {
        switch p {
        case .position: .position
        case .scale: .scale
        case .rotation: .rotation
        case .anchor: .anchor
        case .tiltX, .tiltY: .tilt
        default: nil
        }
    }

    /// "Reset to Automatic" is offered: a variant is active and its override of the shown clip has this property.
    public func canResetToAutomatic(_ p: EffectProperty) -> Bool {
        guard let vp = Self.variantProperty(of: p), let session = speedSession, let c = clip else { return false }
        return session.hasVariantOverride(vp, clip: c.id)
    }

    /// Drops the variant's own value of the row's property (tilt: both axes); the clip follows the automatic conform again.
    public func resetToAutomatic(_ p: EffectProperty) {
        guard let vp = Self.variantProperty(of: p), let session = speedSession, let c = clip else { return }
        session.resetVariantOverride(vp, clip: c.id)
    }

    /// Reset button state: an animated property can reset at the playhead while its value there is not the default.
    public func canResetAtPlayhead(_ p: EffectProperty) -> Bool {
        guard isAnimated(p), playheadInClip else { return false }
        let d = ClipAnimation()
        switch p {
        case .position: return vectorValue(p) != d.position.value
        case .scale: return vectorValue(p) != d.scale.value
        case .anchor: return vectorValue(p) != d.anchor.value
        case .fx where p.kind == .color: return defaultColor(p).map { colorValue(p) != $0 } ?? false
        case .fx where p.kind == .vector: return defaultPoint(p).map { vectorValue(p) != $0 } ?? false
        default: return defaultValue(p).map { scalarValue(p) != $0.value } ?? false
        }
    }

    /// Reset every property of a section (and re-enable its effect): one undo step.
    public func resetSection(_ s: EffectSection) {
        guard var c = clip else { return }
        if s == .speed { resetSpeed(); return }
        let props = properties(of: s)
        resetSection(s, props, in: &c)
        let ids = Set(props.map(\.id))
        selection = selection.filter { !ids.contains($0.property) }
        // Multi-select: the same section of every clip that has it (its properties mapped to that clip).
        let others = isMulti ? (peerGestureBase ?? peers).map { peer -> Clip in
            var o = peer
            if let t = mappedSection(s, to: peer) { resetSection(t, props.compactMap { mapped($0, to: peer) }, in: &o) }
            return o
        } : nil
        commit(c, "Reset \(s.title)", peers: others)
    }

    /// Resets `s` of `c` (its rows `props`) and switches it on again.
    private func resetSection(_ s: EffectSection, _ props: [EffectProperty], in c: inout Clip) {
        // FB-W: an effect that can have a user default goes back to it as a whole (keys included), else to factory.
        if case .effect(let id, let kind) = s, EffectDefaults.canHaveDefault(kind: kind) {
            c.resetEffect(id, defaults: effectDefaults)
        } else {
            for p in props { resetInPlace(&c, p) }      // Transform resets its Crop rows too
        }
        switch s {
        case .motion: c.motionEnabled = true; c.opacityEnabled = true; c.blendMode = .normal
        case .opacity: c.opacityEnabled = true; c.blendMode = .normal
        case .volume, .speed, .animation: break
        case .effect(let id, _):
            if let i = c.effects.firstIndex(where: { $0.id == id }) { c.effects[i].enabled = true }
        case .mask(let id): c.updateMask(id) { $0.enabled = true }
        }
    }

    // MARK: User defaults (FB-W)

    private func appliedEffect(_ s: EffectSection) -> ClipEffect? {
        guard case .effect(let id, _) = s else { return nil }
        return clip?.effects.first { $0.id == id }
    }

    /// "Use as Default" is offered for applied effects other than Color and generator-owned looks.
    public func canUseAsDefault(_ s: EffectSection) -> Bool {
        appliedEffect(s).map { EffectDefaults.canHaveDefault(kind: $0.kind) } ?? false
    }

    /// The effect's kind has a user default (marker in the header; "Reset" goes back to it).
    public func hasUserDefault(_ s: EffectSection) -> Bool {
        guard case .effect(_, let kind) = s else { return false }
        return effectDefaults.hasDefault(effect: kind)
    }

    /// The effect has keyframes (the menu then also offers a default without them).
    public func effectIsAnimated(_ s: EffectSection) -> Bool { !(appliedEffect(s)?.keyTimes.isEmpty ?? true) }

    /// This effect's values become the default of its kind. `keepKeyframes`: keys stay, relative to the clip's first
    /// frame; otherwise the values shown at the playhead are kept (no keys).
    @discardableResult
    public func useAsDefault(_ s: EffectSection, keepKeyframes: Bool = true) -> Bool {
        guard let e = appliedEffect(s), let c = clip else { return false }
        let at = min(max(localPlayhead, .zero), c.duration)
        var d = effectDefaults
        guard d.setDefault(from: e, keepKeyframes: keepKeyframes, at: at) else { return false }
        setEffectDefaults(d)
        return true
    }

    /// Deletes the user default of the section's kind: new instances and "Reset" use the built-in values again.
    public func resetDefaultToFactory(_ s: EffectSection) {
        guard case .effect(_, let kind) = s else { return }
        var d = effectDefaults
        d.removeDefault(effect: kind)
        setEffectDefaults(d)
    }

    private func setEffectDefaults(_ d: EffectDefaults) {
        guard d != effectDefaults else { return }
        effectDefaults = d
        onEffectDefaultsChange?(d)
    }

    public func isEffectEnabled(_ s: EffectSection) -> Bool {
        switch s {
        case .motion: return (clip?.motionEnabled ?? true) && (clip?.opacityEnabled ?? true)
        case .opacity: return clip?.opacityEnabled ?? true
        case .volume, .speed, .animation: return true
        case .effect(let id, _): return clip?.effects.first { $0.id == id }?.enabled ?? false
        case .mask(let id): return clip?.mask(id)?.enabled ?? false
        }
    }

    /// Blend Mode and mask rows follow the visible Transform fx switch, never the hidden Blend section's own flag (AUDIT D13):
    /// the switch sets both flags, so a row can no longer look dead while the visible switch is on.
    public var isBlendGroupEnabled: Bool { isEffectEnabled(.motion) }

    /// fx toggle of an applied effect.
    /// Multi-select: every clip that has the section gets the same state (a mixed switch included), one undo step.
    public func setEffectEnabled(_ s: EffectSection, _ on: Bool) {
        guard var c = clip, isEffectEnabled(s) != on || isEffectEnabledMixed(s) else { return }
        guard Self.setEnabled(s, on, in: &c) else { return }
        let others = isMulti ? (peerGestureBase ?? peers).map { peer -> Clip in
            var o = peer
            if let t = mappedSection(s, to: peer) { _ = Self.setEnabled(t, on, in: &o) }
            return o
        } : nil
        commit(c, on ? "Enable \(s.title)" : "Disable \(s.title)", peers: others)
    }

    private static func setEnabled(_ s: EffectSection, _ on: Bool, in c: inout Clip) -> Bool {
        switch s {
        case .motion: c.motionEnabled = on; c.opacityEnabled = on
        case .opacity: c.opacityEnabled = on
        case .volume, .speed, .animation: return false
        case .effect(let id, _):
            guard let i = c.effects.firstIndex(where: { $0.id == id }) else { return false }
            c.effects[i].enabled = on
        case .mask(let id): c.updateMask(id) { $0.enabled = on }
        }
        return true
    }

    /// A generator-owned effect (a shape's look) belongs to its clip: it can be reset, copied and pasted onto the same
    /// generator kind, never removed, cut or duplicated.
    public func canRemoveEffect(_ s: EffectSection) -> Bool {
        guard let id = s.effectID, let e = clip?.effects.first(where: { $0.id == id }) else { return false }
        return !EffectCatalog.isGeneratorOwned(e.kind)
    }

    public func canCopyEffect(_ s: EffectSection) -> Bool {
        if let g = BuiltInClipboard.group(for: s) { return clip.map { $0.kind == g.kind } ?? false }
        guard let id = s.effectID else { return false }
        return clip?.effects.contains { $0.id == id } ?? false
    }

    // MARK: Convert to Keyframes / Re-open as Effect (W7.5): timeline edits, done by the session through these hooks.

    @ObservationIgnored public var onConvertToKeyframes: ((Clip.ID, ClipEffect.ID) -> Void)?
    @ObservationIgnored public var onReopenAsEffect: ((Clip.ID) -> Void)?
    /// Consulted for enabling (the session knows variants and the active timeline); nil falls back to the clip alone.
    @ObservationIgnored public var canConvert: ((Clip.ID, ClipEffect.ID) -> Bool)?

    public func canConvertToKeyframes(_ s: EffectSection) -> Bool {
        guard let c = clip, let id = s.effectID else { return false }
        return canConvert?(c.id, id) ?? c.canConvertToKeyframes(effect: id)
    }

    public func convertToKeyframes(_ s: EffectSection) {
        guard let c = clip, let id = s.effectID else { return }
        onConvertToKeyframes?(c.id, id)
    }

    /// The newest baked record can be re-opened; it is offered on the Motion section.
    public var canReopenAsEffect: Bool {
        guard let c = clip, let r = c.bakedEffects.last else { return false }
        return c.canReopenAsEffect(r.id)
    }

    public var reopenTitle: String {
        guard let r = clip?.bakedEffects.last else { return "Re-open as Effect" }
        return "Re-open as Effect (\(EffectCatalog.title(for: r.recipeID)))"
    }

    public func reopenAsEffect() { if let c = clip { onReopenAsEffect?(c.id) } }

    /// Removes the applied effect with all its values and keys: one undo step.
    @discardableResult
    public func removeEffect(_ s: EffectSection) -> Bool {
        guard canRemoveEffect(s), var c = clip, let id = s.effectID else { return false }
        c.removeEffect(id)
        let ids = Set(s.properties.map(\.id))
        selection = selection.filter { !ids.contains($0.property) }
        if selectedSection == s { selectedSection = nil }
        expanded.subtract(s.properties)
        commit(c, "Remove \(s.title)")
        return true
    }

    /// Delete key: selected keys first, else the selected effect section or mask.
    public func deleteSelectionOrEffect() {
        if !selection.isEmpty { deleteSelection() }
        else if case .mask(let id)? = selectedSection { removeMask(id) }
        else if let s = selectedSection { removeEffect(s) }
    }

    /// Sections whose header selection survives a clip update: effects and masks.
    static func keepsSelection(_ s: EffectSection) -> Bool {
        if case .mask = s { return true }
        if BuiltInClipboard.group(for: s) != nil { return true }
        return s.effectKind != nil
    }

    /// Whether Delete / Backspace removes section `s` (a removable effect, or a mask of the clip).
    public func canDeleteSection(_ s: EffectSection) -> Bool {
        if case .mask(let id) = s { return clip?.mask(id) != nil }
        return canRemoveEffect(s)
    }

    /// Whether the section header shows as selected (effects and masks; Motion and the fixed sections never do).
    public func isSectionSelected(_ s: EffectSection) -> Bool {
        guard selectedSection == s else { return false }
        if case .mask = s { return true }
        if BuiltInClipboard.group(for: s) != nil { return true }
        return s.effectKind != nil
    }

    // MARK: Easing library

    public func saveCurveFromSelection(name: String) {
        guard let c = clip else { return }
        for p in Self.allProperties(in: c) {
            guard let id = selectedKeyIDs(p).first else { continue }
            switch track(p, in: c) {
            case .scalar(let t)?: if let k = t.key(id: id) { easingLibrary.saveCurve(from: k, name: name) }
            case .vector(let t)?: if let k = t.key(id: id) { easingLibrary.saveCurve(from: k, name: name) }
            case .color(let t)?: if let k = t.key(id: id) { easingLibrary.saveCurve(from: k, name: name) }
            case .path(let t)?: if let k = t.key(id: id) { easingLibrary.saveCurve(from: k, name: name) }
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
        case .scalar(let t)?: return Self.mirrored(t, by: p.displaySign())
        case .vector(let t)?:
            return Self.mirrored(GraphProjection.project(t, component: component == .y ? .y : .x), by: p.displaySign(component: component))
        case .color?, .path?, nil: return KeyframeTrack()   // colors and mask paths have no value graph
        }
    }

    /// The graph draws the displayed direction (up = larger shown number): a flipped row shows its mirrored values.
    /// Ease handles are fractions of the segment, so negating the values mirrors the curve exactly.
    static func mirrored(_ t: KeyframeTrack<Double>, by sign: Double) -> KeyframeTrack<Double> {
        guard sign < 0 else { return t }
        var m = t
        for k in t.keys { m.update(k.id) { $0.value = -$0.value } }
        return m
    }

    /// Takes the complete track edited in the graph (one gesture = one undo step) and merges it back.
    public func applyGraphEdit(_ p: EffectProperty, component: EffectComponent, track edited: KeyframeTrack<Double>) {
        guard var c = clip else { return }
        let edited = Self.mirrored(edited, by: p.displaySign(component: component))      // back to stored direction
        let uniform = p.kind == .uniform && uniformScale
        let comp: GraphProjection.Component = component == .y ? .y : .x
        withScalar(&c, p) { $0.track = edited }
        withVector(&c, p) { $0.track = GraphProjection.merge(base: $0.track, edited: edited, component: comp, uniform: uniform) }
        commit(c, "Edit \(p.title) Keyframes")
    }

    // MARK: Property access by kind

    func withScalar(_ c: inout Clip, _ p: EffectProperty, local: Time? = nil, _ body: (inout AnimatedProperty<Double>) -> Void) {
        switch p {
        case .rotation: body(&c.animation.rotation)
        case .tiltX: body(&c.animation.tiltX)
        case .tiltY: body(&c.animation.tiltY)
        case .opacity: body(&c.animation.opacity)
        case .volume: body(&c.animation.volume)
        case .shutterAngle: body(&c.animation.shutterAngle)
        case .antiFlicker: body(&c.animation.antiFlicker)
        case .fx where p.pair != nil: break          // a pair row is a vector (withVector writes both members)
        case .fx: Self.withFX(&c, p, body)
        case .mask: Self.withMask(&c, p, body)
        case .anim: Self.withAnimScalar(&c, p, local: local ?? localPlayhead, body)
        default: break
        }
    }

    /// After a per-row key edit at `local`: a value left static keeps what the picture showed (hue the short way,
    /// wheel on the disc) and an animated Color wheel partner is keyed so the puck does not jump (SQCore).
    static func followShown(_ c: inout Clip, _ p: EffectProperty, before: Clip, local: Time) {
        guard case .fx(let id, _, let key) = p else { return }
        c.followShownValues(effect: id, key: key, atLocal: local, before: before)
    }

    /// Mutates one effect parameter in place (nothing happens when the instance or parameter is gone).
    static func withFX(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<Double>) -> Void) {
        if isPendingCrop(p, in: c) { withPendingCrop(&c, p, body); return }      // Transform's Crop rows add the Crop
        // A Crop saved before Softness existed does not store it: it starts from the default.
        guard case .fx(let id, let kind, let key) = p, let i = c.effects.firstIndex(where: { $0.id == id }),
              var v = c.effects[i].parameters[key]
                ?? (kind == ClipEffect.cropKind ? EffectCatalog.param(kind, key).map { AnimatedProperty($0.defaultValue) } : nil)
        else { return }
        let before = Set(v.track.keys.map(\.id))
        body(&v)
        // Checkbox / popup values jump: keys they get are hold, never interpolated.
        if p.paramKind?.isStepped == true {
            for k in v.track.keys where !before.contains(k.id) { v.track.update(k.id) { $0.interpolation = .hold } }
        }
        c.effects[i].parameters[key] = v
    }

    /// Mutates one point parameter of an effect instance.
    static func withFXPoint(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<Vec2>) -> Void) {
        if p.pair != nil {
            // P4: both scalar members as one Vec2, written back aligned (storage stays two tracks, no file change).
            withPair(&c, p) { x, y in KeyframesPair.edit(&x, &y, body) }
            return
        }
        guard case .fx(let id, _, let key) = p, let i = c.effects.firstIndex(where: { $0.id == id }),
              var v = c.effects[i].points[key] else { return }
        body(&v)
        c.effects[i].points[key] = v
    }

    /// Mutates the two scalar members of a pair row (P4) and stores them. Linked (P5): Height is not stored; it follows
    /// X, edited as a pair of equals.
    static func withPair(_ c: inout Clip, _ p: EffectProperty,
                         _ body: (inout AnimatedProperty<Double>, inout AnimatedProperty<Double>) -> Void) {
        guard case .fx(let id, let kind, _) = p, let pr = p.pair,
              let i = c.effects.firstIndex(where: { $0.id == id }) else { return }
        var x = member(c.effects[i], kind, pr.x), y = member(c.effects[i], kind, pr.y)
        let linked = pr.linkable && c.effects[i].parameters[pr.y] == nil
        if linked { y = x.withFreshKeyIDs() }
        body(&x, &y)
        c.effects[i].parameters[pr.x] = x
        if !linked { c.effects[i].parameters[pr.y] = y }
    }

    /// Mutates one color parameter of an effect instance.
    static func withFXColor(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<EffectColor>) -> Void) {
        guard case .fx(let id, _, let key) = p, let i = c.effects.firstIndex(where: { $0.id == id }),
              var v = c.effects[i].colors[key] else { return }
        body(&v)
        c.effects[i].colors[key] = v
    }

    func withVector(_ c: inout Clip, _ p: EffectProperty, local: Time? = nil, _ body: (inout AnimatedProperty<Vec2>) -> Void) {
        switch p {
        case .position: body(&c.animation.position)
        case .scale: body(&c.animation.scale)
        case .anchor: body(&c.animation.anchor)
        case .fx: Self.withFXPoint(&c, p, body)
        case .anim: Self.withAnimVector(&c, p, local: local ?? localPlayhead, body)
        default: break
        }
    }

    func withColor(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<EffectColor>) -> Void) {
        if case .fx = p { Self.withFXColor(&c, p, body) }
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

public enum SpeedControl: Equatable, Sendable { case speed, reverse, keepPitch, timeInterpolation }

public struct EffectRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case section(EffectSection)
        case property(EffectProperty)
        case placeholder(EffectSection)
        case graph(EffectProperty)
        /// The three rows of the Speed section: Speed value, Reverse, Keep Pitch.
        case speedControl(SpeedControl)
        /// Blend Mode pop-up under the Opacity row (only when the view asks for it).
        case blendMode
        /// "Video" / "Audio" group header above the sections of that side (only when the view asks for it).
        case group(EffectGroup)
        /// W6.7: Invert, Mode, Path stopwatch and delete of the path mask whose section is above.
        case maskControls(ClipMask.ID)
        /// Second mask line: Track Backward / Forward, the Track choice and delete (own line so the mask rows fit the 300 pt panel minimum).
        case maskTrack(ClipMask.ID)
        /// C6: "Picture of [track] [Shape | Brightness]" and delete, instead of `maskTrack` for a Picture mask.
        case pictureMask(ClipMask.ID)
        /// v87 Color range mask: "Color" (picked color, Inverted, delete) and its Tolerance / Softness lines.
        case colorRangeMask(ClipMask.ID)
        case colorRangeAmount(ClipMask.ID, soft: Bool)
        /// How the mask is used: Cuts picture (Opacity) and the effects it is the input of.
        case maskUse(ClipMask.ID)
        /// W9.8: one subject mask of the clip under Opacity (name, Inverted, Mode, delete).
        case subjectMask(ClipMask.ID)
        /// A group of a Color effect (Basic Correction, Creative, Curves ...): twirl, title and the group's switch.
        case colorGroup(ClipEffect.ID, key: String)
        /// The RGB curve editor under the Curves group.
        case curves(ClipEffect.ID)
        /// Multiband Compressor: button row that opens the custom setup popup.
        case multiband(ClipEffect.ID)
        /// "All Parameters" disclosure of a Multiband Compressor; its parameter rows follow only while it is open.
        case multibandParams(ClipEffect.ID)
        /// Parametric EQ: "Curve" disclosure, and the inline curve editor while it is open.
        case eqCurveHeader(ClipEffect.ID)
        case eqCurve(ClipEffect.ID)
        /// FB-B3: Set Reference / Match under the Color Wheels group.
        case colorMatch(ClipEffect.ID)
        /// The Pro grade: its Step count and the Adjust button that opens the Color page.
        case colorGraph(ClipEffect.ID)
        /// Start / end of a range grade (COLOR-GRADE-LINKS), under its section header.
        case gradeRange(ClipEffect.ID)
        /// Fade-in / fade-out lengths of a range grade (soft edges), under its Range row.
        case gradeFade(ClipEffect.ID)
        /// Stabilizer: Analyze / Cancel, progress and status, under its Method row.
        case stabilizeAnalyze(ClipEffect.ID)
        /// Track Mask: the track pop-up, above its Mode row.
        case trackMaskTrack(ClipEffect.ID)
    }
    public var kind: Kind
    public var y: CGFloat
    public var height: CGFloat
}

public enum EffectGroup: Sendable, Hashable {
    case video, audio
    public var title: String { self == .video ? "Video" : "Audio" }
}

/// The on/off switch of a section header: a power symbol (the Premiere-style `fx` button is gone).
public enum EffectControlsSwitch {
    public static func symbol(on: Bool) -> SQIcon { on ? .powerOn : .powerOff }
}

public enum EffectControlsLayout {
    /// The opened keyframe row (design source `.epane` / `.eg`): one inline graph per row, vectors included.
    public static let graphComponentHeight: CGFloat = ControlsMetrics.graph
    public static let curvesRowHeight: CGFloat = 200
    static func colorGroupID(_ effect: ClipEffect.ID, _ key: String) -> String { EffectControlsModel.colorGroupID(effect, key) }

    public static func graphHeight(_ p: EffectProperty) -> CGFloat { graphComponentHeight }

    private static func isChoice(_ p: EffectProperty) -> Bool { if case .choice? = p.paramKind { return true } else { return false } }

    /// Row heights from the one grid (`ControlsGrid`): every section header `headerHeight`, every parameter row
    /// `rowHeight`, and `sectionGap` between two sections.
    public static func rows(sections: [EffectSection], collapsed: Set<EffectSection>,
                            expanded: Set<EffectProperty>,
                            blendModeRow: Bool = false, groupHeaders: Bool = false,
                            openColorGroups: Set<String> = [],
                            subjectMasks: [ClipMask.ID] = [],
                            pictureMasks: Set<ClipMask.ID> = [],
                            colorRangeMasks: Set<ClipMask.ID> = [],
                            gradeRanges: [ClipEffect.ID] = [],
                            stabilizers: [ClipEffect.ID: StabilizerMethod] = [:],
                            transformCrop: [EffectProperty] = []) -> [EffectRow] {
        let h = ControlsMetrics.parameter, tall = ControlsMetrics.tallParameter
        var out: [EffectRow] = []
        var y: CGFloat = 0
        func add(_ k: EffectRow.Kind, _ height: CGFloat) { out.append(EffectRow(kind: k, y: y, height: height)); y += height }
        var lastGroup: EffectGroup?
        for s in sections {
            if groupHeaders, group(of: s) != lastGroup { add(.group(group(of: s)), ControlsMetrics.group); lastGroup = group(of: s) }
            if !out.isEmpty { y += ControlsMetrics.sectionGap }
            add(.section(s), ControlsMetrics.section)
            guard !collapsed.contains(s) else { continue }
            if s == .speed { for k in [SpeedControl.speed, .reverse, .keepPitch, .timeInterpolation] { add(.speedControl(k), h) }; continue }
            if case .effect(let id, let kind) = s, kind == ClipEffect.colorGraphKind { add(.colorGraph(id), h); continue }
            if s.properties.isEmpty { add(.placeholder(s), h) }
            if case .effect(let id, let kind) = s, kind == ClipEffect.audioMultibandKind {
                add(.multiband(id), ControlsMetrics.multibandRow)
                add(.multibandParams(id), ControlsMetrics.section)
                if !openColorGroups.contains(colorGroupID(id, EffectControlsModel.multibandParametersKey)) { continue }
            }
            if case .effect(let id, let kind) = s, kind == ClipEffect.audioParametricEQKind {
                add(.eqCurveHeader(id), ControlsMetrics.section)
                if openColorGroups.contains(colorGroupID(id, EffectControlsModel.eqCurveKey)) { add(.eqCurve(id), EffectControlsModel.eqCurveHeight) }
            }
            if case .effect(let id, _) = s, gradeRanges.contains(id) { add(.gradeRange(id), h); add(.gradeFade(id), h) }
            // A Subject mask: its own line (name, Inverted, Mode, delete) first, then Feather / Opacity / Expansion, then its use.
            if case .mask(let id) = s, subjectMasks.contains(id) { add(.subjectMask(id), tall) }
            defer {
                if case .mask(let id) = s {
                    if subjectMasks.contains(id) { add(.maskUse(id), tall) }
                    else if colorRangeMasks.contains(id) {
                        add(.colorRangeMask(id), tall); add(.colorRangeAmount(id, soft: false), h)
                        add(.colorRangeAmount(id, soft: true), h); add(.maskUse(id), tall)
                    }
                    else if pictureMasks.contains(id) { add(.pictureMask(id), tall); add(.maskControls(id), tall); add(.maskUse(id), tall) }
                    else { add(.maskControls(id), tall); add(.maskTrack(id), h); add(.maskUse(id), tall) }
                }
            }
            // Transform ends with its Crop rows (`EffectControlsModel.transformCropProperties`).
            for p in s.properties + (s == .motion ? transformCrop : []) {
                // A Picture mask has no Feather / Expansion in v1.
                if case .mask(let id, let m) = p, (pictureMasks.contains(id) || colorRangeMasks.contains(id)), m == .feather || m == .expansion { continue }
                // A Stabilizer shows Method, its Analyze row, then only the chosen method's rows.
                if case .fx(let id, let kind, let key) = p, kind == ClipEffect.stabilizeKind {
                    let method = stabilizers[id] ?? .standard
                    guard method.visibleKeys.contains(key) else { continue }
                    add(.property(p), isChoice(p) ? tall : h)
                    if key == ClipEffect.stabilizeMethodKey { add(.stabilizeAnalyze(id), tall) }
                    else if expanded.contains(p) && p.hasGraph { add(.graph(p), graphHeight(p)) }
                    continue
                }
                // A Track Mask picks its track on a row of its own, above Mode.
                if case .fx(let id, let kind, let key) = p, kind == ClipEffect.trackMaskKind, key == ClipEffect.trackMaskModeKey {
                    add(.trackMaskTrack(id), tall)
                }
                // A Color effect is grouped like the Color page: each group header carries its switch, closed groups hide their rows.
                if case .fx(let id, let kind, let key) = p, kind == ClipEffect.colorKind {
                    if ColorEffectGroups.isGroupToggle(key) {
                        add(.colorGroup(id, key: key), h)
                        if key == ClipEffect.colorCurvesOnKey, openColorGroups.contains(colorGroupID(id, key)) { add(.curves(id), curvesRowHeight) }
                        if key == ClipEffect.colorWheelsOnKey, openColorGroups.contains(colorGroupID(id, key)) { add(.colorMatch(id), h) }
                        continue
                    }
                    if let g = ColorEffectGroups.groupKey(of: key), !openColorGroups.contains(colorGroupID(id, g)) { continue }
                }
                add(.property(p), isChoice(p) ? tall : h)
                if expanded.contains(p) && p.hasGraph { add(.graph(p), graphHeight(p)) }
                if p == .opacity && blendModeRow { add(.blendMode, tall) }
            }
        }
        return out
    }

    /// Video effects (Motion, Opacity, applied effects) sit above the Audio ones (Volume, audio effects).
    public static func group(of s: EffectSection) -> EffectGroup {
        if s == .volume { return .audio }
        if let k = s.effectKind, ClipEffect.isAudioKind(k) { return .audio }
        return .video
    }

    public static func totalHeight(_ rows: [EffectRow]) -> CGFloat { rows.last.map { $0.y + $0.height } ?? 0 }

    public static func row(at y: CGFloat, in rows: [EffectRow]) -> EffectRow? {
        rows.first { y >= $0.y && y < $0.y + $0.height }
    }
}

// MARK: - Lane geometry (pure)

/// Maps clip-local time to x in the keyframe lane and back. Without a viewport the whole clip is visible.
public struct KeyframeLaneGeometry: Sendable, Equatable {
    public var width: CGFloat
    public var duration: Time
    public var inset: CGFloat
    public var viewport: KeyframeViewport?

    public init(width: CGFloat, duration: Time, inset: CGFloat = 10, viewport: KeyframeViewport? = nil) {
        self.width = width; self.duration = duration; self.inset = inset; self.viewport = viewport
    }

    private var usable: CGFloat { max(width - 2 * inset, 1) }
    private var durationSeconds: Double { Double(duration.value) / Double(duration.timescale) }
    public var viewStart: Double { viewport?.start ?? 0 }
    public var viewSpan: Double { viewport.map { max($0.span, 1e-9) } ?? durationSeconds }
    public var pointsPerSecond: Double { viewSpan > 0 ? Double(usable) / viewSpan : 0 }

    public func x(seconds s: Double) -> CGFloat {
        guard viewSpan > 0 else { return inset }
        return inset + CGFloat((s - viewStart) / viewSpan) * usable
    }

    public func x(for local: Time) -> CGFloat { x(seconds: Double(local.value) / Double(local.timescale)) }

    /// Clip-local seconds at `x`, not clamped.
    public func seconds(atX x: CGFloat) -> Double {
        viewStart + Double((x - inset) / usable) * viewSpan
    }

    /// Nearest frame at `x`, clamped to 0...duration.
    public func time(at x: CGFloat, frameDuration: Time) -> Time {
        guard durationSeconds > 0 else { return .zero }
        let s = seconds(atX: x)
        let fd = Double(frameDuration.value) / Double(frameDuration.timescale)
        let t = Time.frames(Int64((s / fd).rounded()), frameDuration: frameDuration)
        return min(max(t, .zero), duration)
    }

    /// Nearest frame at `x`, not clamped: a key drag may go past either clip edge.
    public func unclampedTime(at x: CGFloat, frameDuration: Time) -> Time {
        guard durationSeconds > 0 else { return .zero }
        let fd = Double(frameDuration.value) / Double(frameDuration.timescale)
        return Time.frames(Int64((seconds(atX: x) / fd).rounded()), frameDuration: frameDuration)
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


/// W6.7: the keyframable numbers of a path mask shown in Effect Controls.
public enum MaskParam: String, Sendable, Hashable, CaseIterable {
    case feather, opacity, expansion

    public var title: String {
        switch self { case .feather: "Mask Feather"; case .opacity: "Mask Opacity"; case .expansion: "Mask Expansion" }
    }
    public var unit: String { self == .opacity ? "%" : "px" }
    public var range: ClosedRange<Double> {
        switch self {
        case .feather: 0...1000
        case .opacity: 0...100
        case .expansion: -1000...1000
        }
    }
    public var defaultValue: Double {
        switch self { case .feather: ClipMask.defaultFeather; case .opacity: 100; case .expansion: 0 }
    }
    func value(of m: ClipMask) -> AnimatedProperty<Double> {
        switch self { case .feather: m.feather; case .opacity: m.opacity; case .expansion: m.expansion }
    }
    func set(_ v: AnimatedProperty<Double>, in m: inout ClipMask) {
        switch self { case .feather: m.feather = v; case .opacity: m.opacity = v; case .expansion: m.expansion = v }
    }
}
