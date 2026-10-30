import Foundation

// Transitions (project file v17).
//
// A transition belongs to a track and is anchored to clip IDs, not to times:
// - a cut transition names the outgoing and the incoming clip that touch at the cut,
// - a single-sided transition names one clip (`incoming` only = fade in at the head, `outgoing` only = fade out at the tail).
// What is stored is the user's intent (kind, requested duration, alignment). What actually plays is *resolved* from the
// current clips (`Track.resolvedTransitions`): the cut must still exist, and the duration is clamped to the handles (source
// media beyond the cut, through speed and reverse). So every edit keeps transitions consistent without touching the edit
// code: a transition whose cut is gone resolves to nothing (and `pruneTransitions` drops it), a slip that shrinks a handle
// re-clamps it, and undoing the slip restores the requested length. Without handles the edge frame is held
// (`heldBefore` / `heldAfter` on `ResolvedTransition`), so a transition still plays; the duration is clamped only when
// even that is not allowed.

public enum TransitionKind: String, Sendable, Codable, CaseIterable {
    // Video
    case crossDissolve, dipToBlack, dipToWhite
    /// A cross dissolve of a few frames (the maintainer's 2-5 frame dissolves).
    case quickFade
    /// Motion transitions (v25), rendered by the compositor's transition node (`TransitionRender`).
    case push, slide, whip, zoomIn, zoomOut, zoomPop, softWipe
    /// RGB split + horizontal slice displacement (a hard cut at the middle, deterministic from progress).
    case glitch
    /// Iris: the incoming picture opens as a growing ellipse (soft edge). Light Leak: a warm procedural gradient sweeps
    /// over a dissolve, composited with screen blend. Both are pure functions of the progress (`TransitionRender.Iris/LightLeak`).
    case iris, lightLeak
    /// Round 4 set (DECISIONS 2026-10-05): Blur Dissolve (both pictures blur as they mix), Dip to Color (a color of your
    /// choice, `Transition.color`), Flash (a short sharp white peak over a hard cut), Spin (both pictures rotate), Cross Zoom
    /// (dissolve under a radial smear), Static (channel-change noise), Light Noise (dissolve with drifting glow), Strobe Cut
    /// (A and B alternate hard, ending on B). Whip, Zoom In / Out and Through White already exist and are not repeated.
    case blurDissolve, dipToColour, flash, spin, crossZoom, staticNoise, lightNoise, strobeCut
    /// Parity set (DECISIONS 2026-10-13): Additive Dissolve (both pictures add, a bright overlap), and the shape reveals of
    /// Premiere's Iris / Wipe and Resolve's Shape / Wipe bins on one mask path (`TransitionRender.ShapeWipe`).
    case additiveDissolve, clockWipe, boxIris, diamondIris, crossIris, barnDoors, venetianBlinds
    /// Second wipe set (same mask path): Radial (around the top-left corner), Wedge (fan from 12 o'clock to both sides),
    /// Pinwheel (four blades), Checker (cells alternate direction), Zig-Zag Blocks (snake of blocks), Inset (from the top-left
    /// corner), Random Blocks (cells in a fixed shuffled order).
    case radialWipe, wedgeWipe, pinwheel, checkerWipe, zigZagBlocks, insetWipe, randomBlocks
    /// Slice (strips slide in from alternate sides, one mask path) and Mosaic Dissolve (a dissolve under growing, then
    /// shrinking blocks).
    case sliceWipe, mosaicDissolve
    /// Third set: Flip 3D (a card turns about its center line, one shader path), Spring (B slides in and settles with a small
    /// overshoot), Fall (A drops out, tilting), Burn (A burns away with a glowing edge), Flare (a dissolve under a sweeping
    /// flare), Warp (both pictures ripple through a dissolve), Shake (a camera-shake cut with a color split).
    case flip3D, spring, fall, burn, flare, warp, shake
    /// N6b (v38): a Library clip (`Transition.stinger`, alpha) over a hard cut at the edit point. No handles needed.
    case stinger
    /// FB-G (v40): element transitions. One clip edge only (head = In, tail = Out); they animate that clip on its own
    /// transform stage like the Move / Zoom / Pop motion effects did (ElementTransitions.swift), no second picture.
    case move, zoom, pop
    // Audio
    case constantPower, constantGain, exponentialFade

    public var trackKind: TrackKind {
        switch self {
        case .constantPower, .constantGain, .exponentialFade: .audio
        default: .video
        }
    }

    public var name: String {
        switch self {
        case .crossDissolve: "Dissolve"
        case .dipToBlack: "Through Black"
        case .dipToWhite: "Through White"
        case .quickFade: "Quick Fade"
        case .push: "Push"
        case .slide: "Slide"
        case .whip: "Whip"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomPop: "Zoom Pop"
        case .softWipe: "Soft Wipe"
        case .glitch: "Glitch"
        case .iris: "Iris"
        case .lightLeak: "Light Leak"
        case .blurDissolve: "Blur Dissolve"
        case .dipToColour: "Through Color"
        case .flash: "Flash"
        case .spin: "Spin"
        case .crossZoom: "Cross Zoom"
        case .staticNoise: "Static"
        case .lightNoise: "Light Noise"
        case .strobeCut: "Strobe Cut"
        case .additiveDissolve: "Additive Dissolve"
        case .clockWipe: "Clock Wipe"
        case .boxIris: "Box Iris"
        case .diamondIris: "Diamond Iris"
        case .crossIris: "Cross Iris"
        case .barnDoors: "Barn Doors"
        case .venetianBlinds: "Blinds"
        case .radialWipe: "Radial Wipe"
        case .wedgeWipe: "Wedge Wipe"
        case .pinwheel: "Pinwheel"
        case .checkerWipe: "Checker Wipe"
        case .zigZagBlocks: "Zig-Zag Blocks"
        case .insetWipe: "Inset"
        case .randomBlocks: "Random Blocks"
        case .sliceWipe: "Slice"
        case .mosaicDissolve: "Mosaic Dissolve"
        case .flip3D: "Flip 3D"
        case .spring: "Spring"
        case .fall: "Fall"
        case .burn: "Burn"
        case .flare: "Flare"
        case .warp: "Warp"
        case .shake: "Shake"
        case .stinger: "Stinger"
        case .move: "Move"
        case .zoom: "Zoom"
        case .pop: "Pop"
        case .constantPower: "Smooth Crossfade"
        case .constantGain: "Steady Crossfade"
        case .exponentialFade: "Exponential Fade"
        }
    }

    public static func kinds(for track: TrackKind) -> [TransitionKind] { allCases.filter { $0.trackKind == track } }
    /// Premiere's defaults: Cross Dissolve for video, Constant Power for audio.
    public static func defaultKind(for track: TrackKind) -> TransitionKind { track == .video ? .crossDissolve : .constantPower }

    /// Moves, scales or masks the pictures (compositor transition node) instead of mixing opacities.
    public var isMotion: Bool {
        switch self {
        case .push, .slide, .whip, .zoomIn, .zoomOut, .zoomPop, .softWipe, .glitch, .iris, .lightLeak,
             .blurDissolve, .spin, .crossZoom, .staticNoise, .lightNoise, .strobeCut, .additiveDissolve, .clockWipe, .boxIris,
             .diamondIris, .crossIris, .barnDoors, .venetianBlinds,
             .radialWipe, .wedgeWipe, .pinwheel, .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe, .mosaicDissolve,
             .flip3D, .spring, .fall, .burn, .flare, .warp, .shake: true
        default: false
        }
    }
    /// Dissolves to a flat color and back through the solid dip layer (`TransitionMix.video`).
    public var isDip: Bool { self == .dipToBlack || self == .dipToWhite || self == .dipToColour || self == .flash }
    /// The dip color is the user's (`Transition.color`).
    public var usesColor: Bool { self == .dipToColour }
    public var usesDirection: Bool { [.push, .slide, .whip, .softWipe, .lightLeak, .spin, .barnDoors, .flip3D, .spring, .fall, .burn, .flare].contains(self) }
    /// Shape reveals (`TransitionRender.ShapeWipe`): a distance field with a soft edge, no movement.
    public var isShapeReveal: Bool { [.clockWipe, .boxIris, .diamondIris, .crossIris, .barnDoors, .venetianBlinds, .radialWipe, .wedgeWipe, .pinwheel,
                                         .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe].contains(self) }
    /// Push, Slide and Soft Wipe have one straight moving edge a border can follow.
    public var usesBorder: Bool { self == .push || self == .slide || self == .softWipe }
    public static let maxBorderWidth = 0.1
    public var usesSoftness: Bool { self == .softWipe || self == .iris || self == .lightLeak || isShapeReveal }
    public var usesMotionBlur: Bool {
        isMotion && !(isShapeReveal || [.softWipe, .glitch, .iris, .lightLeak, .blurDissolve, .staticNoise, .lightNoise, .strobeCut,
                                        .additiveDissolve, .mosaicDissolve, .flip3D, .burn, .flare, .warp, .shake].contains(self)) || isElement
    }
    /// Element transitions have their own Curve parameter instead; Zoom In / Out's speed curve is part of their look.
    public var usesEasing: Bool { trackKind == .video && self != .stinger && !isElement && self != .zoomIn && self != .zoomOut }
    /// Plays a third picture (`Transition.stinger`) over a hard cut instead of mixing A and B.
    public var isStinger: Bool { self == .stinger }

    /// Dissolves and dips stay linear (Premiere; the maintainer's opacity keys are all linear); slides and the pop decelerate into place
    /// like his "Move From" presets (Premiere's "Ease In": slow arrival); every other motion eases in and out.
    public var defaultEasing: EasingCurve {
        switch self {
        case .slide, .zoomPop: .easeIn
        case .push, .whip, .zoomIn, .zoomOut, .softWipe, .iris, .lightLeak, .blurDissolve, .spin, .crossZoom: .easeInOut
        case .clockWipe, .boxIris, .diamondIris, .crossIris, .barnDoors, .venetianBlinds, .radialWipe, .wedgeWipe, .pinwheel,
             .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe, .mosaicDissolve: .easeInOut
        default: .linear
        }
    }

    /// Shutter of the motion blur in frames (0.5 = 180 degrees). A whip is mostly blur.
    public var defaultMotionBlur: Double {
        switch self {
        case .whip: 1.5
        // Zoom In / Out: a full frame of shutter, the radial smear carries the "whoosh" at the fade.
        case .zoomIn, .zoomOut, .crossZoom, .spin: 1
        case .push, .slide, .zoomPop, .spring, .fall: 0.5
        default: 0
        }
    }
    /// Soft Wipe edge: half width of the soft band, fraction of the frame.
    public static let defaultSoftness = 0.1
    public static let defaultDirection = TransitionDirection.left

    /// Length a new transition of this kind gets (DECISIONS 2026-10-06 "Transition feel defaults": long enough for the
    /// factory curve to settle; the fast part of a move is still as short as before). nil = the Preferences default
    /// (dissolves, dips, wipe, audio). A stored transition keeps its own length.
    public func presetDuration(frameDuration fd: Time) -> Time? {
        let fps = Double(fd.timescale) / Double(fd.value)
        func seconds(_ s: Double) -> Time { fd * max(1, Int64((s * fps).rounded())) }
        switch self {
        case .quickFade: return fd * 3
        case .push: return seconds(0.8)
        case .slide: return seconds(1.0)
        case .whip: return seconds(0.5)
        case .zoomIn, .zoomOut: return seconds(0.7)
        case .zoomPop: return seconds(0.8)
        case .glitch: return seconds(0.3)
        case .iris: return seconds(0.8)
        case .lightLeak: return seconds(1.0)
        case .flash: return seconds(0.5)
        case .spin, .crossZoom: return seconds(0.8)
        case .staticNoise, .strobeCut: return seconds(0.4)
        case .lightNoise: return seconds(1.0)
        case .flip3D, .spring, .fall, .flare: return seconds(0.8)
        case .burn: return seconds(1.0)
        case .warp: return seconds(0.7)
        case .shake: return seconds(0.5)
        case .move, .zoom: return seconds(0.8)
        case .pop: return seconds(0.6)
        default: return nil
        }
    }
}

/// Where a motion transition moves the picture (push, slide) or sweeps its edge (wipe).
public enum TransitionDirection: String, Sendable, Codable, CaseIterable {
    case left, right, up, down

    public var name: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }

    /// Unit motion vector in frame fractions, y down.
    public var vector: Vec2 {
        switch self {
        case .left: Vec2(-1, 0)
        case .right: Vec2(1, 0)
        case .up: Vec2(0, -1)
        case .down: Vec2(0, 1)
        }
    }
}

public enum TransitionAlignment: String, Sendable, Codable, CaseIterable {
    case center, startAtCut, endAtCut
    /// Dragged to a custom position over the cut (`Transition.customBefore` frames lie before the cut).
    case custom

    public var name: String {
        switch self {
        case .center: "Center at Cut"
        case .startAtCut: "Start at Cut"
        case .endAtCut: "End at Cut"
        case .custom: "Custom Start"
        }
    }
}

public struct Transition: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: TransitionKind
    /// Requested duration, whole frames of the sequence. The resolved duration may be shorter (handles).
    public var duration: Time
    public var alignment: TransitionAlignment
    /// Used by `.custom`: the part of the transition before the cut, whole frames.
    public var customBefore: Time
    /// Clip before the cut; nil = fade in at the head of `incoming`.
    public var outgoing: Clip.ID?
    /// Clip after the cut; nil = fade out at the tail of `outgoing`.
    public var incoming: Clip.ID?
    /// Style (v25; optional in the file, nil = the kind's default). Progress curve over the span.
    public var easing: EasingCurve?
    public var direction: TransitionDirection?
    /// v89: travels the other way (`renderDirection`); nil = not reversed, so a file without one stays byte-identical.
    public var reversed: Bool?
    /// Soft Wipe edge, 0...0.5 of the frame.
    public var softness: Double?
    /// Motion blur shutter in frames, 0...4.
    public var motionBlur: Double?
    /// N6b (v38): the clip a `.stinger` transition plays over the cut; nil = none picked (a plain cut).
    public var stinger: TransitionStinger?
    /// FB-G (v40): parameters of an element transition (Move / Zoom / Pop), motion-effect keys; nil or a missing key = the
    /// default (`TransitionKind.elementParams`). Zoom In / Out: "amount" (percent); without it they play their older look.
    public var params: [String: Double]?
    /// Through Color: the dip color as display-encoded RGB bytes; nil = `TransitionMix.defaultDipColor`.
    public var color: [UInt8]?
    /// Border along the moving edge of a Push / Slide / Soft Wipe: width as a fraction of the frame (0...0.1), nil = none (a
    /// file without one stays byte-identical). `borderColor`: display-encoded RGB bytes, nil = white.
    public var borderWidth: Double?
    public var borderColor: [UInt8]?

    public var effectiveEasing: EasingCurve { easing ?? kind.defaultEasing }
    public var effectiveDirection: TransitionDirection { direction ?? TransitionKind.defaultDirection }
    public var effectiveSoftness: Double { softness ?? TransitionKind.defaultSoftness }
    public var effectiveMotionBlur: Double { motionBlur ?? kind.defaultMotionBlur }

    public init(id: UUID = UUID(), kind: TransitionKind, duration: Time, alignment: TransitionAlignment = .center,
                customBefore: Time = .zero, outgoing: Clip.ID?, incoming: Clip.ID?) {
        self.id = id; self.kind = kind; self.duration = duration; self.alignment = alignment
        self.customBefore = customBefore; self.outgoing = outgoing; self.incoming = incoming
    }

    public var isSingleSided: Bool { outgoing == nil || incoming == nil }
}

/// N6b: the Library clip of a Stinger transition. It plays from its first frame over the cut; at `cutFraction` of its
/// length the picture underneath switches from the outgoing to the incoming clip (that instant is the edit point).
public struct TransitionStinger: Sendable, Hashable, Codable {
    public var media: UUID
    /// 0...1 of the stinger's length where the picture switches (typically where the stinger fully covers the frame).
    public var cutFraction: Double {
        didSet { cutFraction = Self.clamp(cutFraction) }
    }
    /// Scale of the stinger picture (1 = one source pixel per sequence pixel); nil = 1. `Project.setStinger` writes the
    /// fit value, so a 4K stinger fills an HD sequence.
    public var scale: Double?

    public init(media: UUID, cutFraction: Double = 0.5, scale: Double? = nil) {
        self.media = media; self.cutFraction = Self.clamp(cutFraction); self.scale = scale
    }

    private enum CodingKeys: String, CodingKey { case media, cutFraction, scale }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        media = try c.decode(UUID.self, forKey: .media)
        cutFraction = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .cutFraction) ?? 0.5)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
    }

    static func clamp(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), 1) : 0.5 }

    /// The stinger as a clip on the timeline for one resolved span (its id is the transition's: a layer, not a track clip).
    func clip(id: Transition.ID, span: TimeRange, sourceStart: Time) -> Clip {
        var c = Clip(id: id, name: "Stinger", media: media, kind: .video,
                     source: TimeRange(start: sourceStart, duration: span.duration), start: span.start)
        if let s = scale { c.animation.scale = AnimatedProperty(Vec2(s, s)) }
        return c
    }
}

/// What a transition currently is on the timeline.
public struct ResolvedTransition: Sendable, Hashable, Identifiable {
    public var id: Transition.ID
    public var kind: TransitionKind
    public var alignment: TransitionAlignment
    public var outgoing: Clip.ID?, incoming: Clip.ID?
    /// The cut, or for a single-sided transition the clip edge it sits on.
    public var cut: Time
    public var span: TimeRange
    /// Parts of the span before and after `cut`; `before + after == span.duration`.
    public var before: Time, after: Time
    public var requestedDuration: Time
    public var frameDuration: Time
    /// Effective style (the kind's defaults filled in).
    public var easing: EasingCurve = .linear
    public var direction: TransitionDirection = .left
    public var softness: Double = TransitionKind.defaultSoftness
    public var motionBlur: Double = 0
    /// `.stinger`: the clip played over the cut, and its media time at `span.start` (above zero when a short clip next to
    /// the cut trimmed the stinger's head, so its cut frame still lands on the edit).
    public var stinger: TransitionStinger?
    public var stingerStart: Time = .zero
    /// Through Color: the color the picture dips to (display-encoded bytes); nil = the kind's own (black / white).
    public var color: [UInt8]?
    /// Zoom In / Out with a stored Amount (scale, 1.1 = 110 %): the settling zoom. nil = the older look.
    public var zoomAmount: Double?
    /// Border along the moving edge (`Transition.borderWidth`); nil = none.
    public var borderWidth: Double?
    public var borderColor: [UInt8]?

    public var duration: Time { span.duration }
    public var frames: Int { Int(span.duration.frameIndex(frameDuration: frameDuration)) }
    /// The handles ran short and `duration` is less than requested ("insufficient media").
    /// Also true while frames are held (below): the red tick of the timeline says "not the full picture on one side".
    public var isClamped: Bool { span.duration < requestedDuration || heldFrames > 0 }
    /// Video cut with no media beyond it (Premiere's repeated frames, Q-TRN1 / parity fix 8): frames of the span before the
    /// cut where the incoming clip shows its first frame, held. Derived when resolving, never stored.
    public var heldBefore: Int64 = 0
    /// Frames of the span after the cut where the outgoing clip shows its last frame, held.
    public var heldAfter: Int64 = 0
    /// All held frames of the span (either side).
    public var heldFrames: Int64 { heldBefore + heldAfter }
    public var isHeld: Bool { heldFrames > 0 }
    public var isSingleSided: Bool { outgoing == nil || incoming == nil }

    /// Frame index inside the span (0 ..< frames) for timeline time `t`; nil outside.
    public func frameIndex(at t: Time) -> Int? {
        guard span.contains(t) else { return nil }
        return min(max(Int((t - span.start).frameIndex(frameDuration: frameDuration)), 0), frames - 1)
    }
}

/// The pure mixing functions of transitions (shared by playback and export).
public struct TransitionMix: Sendable, Equatable {
    public var outgoing: Double, incoming: Double, dip: Double

    /// Weight of the incoming picture on frame `frameIndex` of `frames`: strictly inside 0...1, so a one-frame transition
    /// shows the 50 % blend and the first frame is already slightly mixed (like a dissolve laid over the cut).
    public static func videoWeight(frameIndex: Int, frames: Int) -> Double { Double(frameIndex + 1) / Double(frames + 1) }

    /// Two-sided video mix at incoming weight `w`. Cross dissolve: `(1-w)*A + w*B`. Dips: A fades to the dip color over the
    /// first half, B fades in from it over the second; at `w = 0.5` the picture is the dip color only.
    public static func video(_ kind: TransitionKind, weight w: Double) -> TransitionMix {
        switch kind {
        case .dipToBlack, .dipToWhite, .dipToColour:
            let o = max(0, 1 - 2 * w), i = max(0, 2 * w - 1)
            return TransitionMix(outgoing: o, incoming: i, dip: 1 - o - i)
        case .flash:
            // Hard cut at the middle; the color comes in fast and leaves fast (a peak, not a ramp).
            let k = pow(max(0, 1 - abs(2 * w - 1)), flashExponent)
            return TransitionMix(outgoing: w < 0.5 ? 1 - k : 0, incoming: w < 0.5 ? 0 : 1 - k, dip: k)
        default:
            return TransitionMix(outgoing: 1 - w, incoming: w, dip: 0)
        }
    }

    /// Dip color as display-encoded RGB bytes.
    public static func dipColor(_ kind: TransitionKind, custom: [UInt8]? = nil) -> [UInt8] {
        switch kind {
        case .dipToWhite, .flash: [255, 255, 255]
        case .dipToColour: sanitised(custom) ?? defaultDipColour
        default: [0, 0, 0]
        }
    }
    /// Through Color without a pick: a warm red, so the kind is visibly not Through Black.
    public static let defaultDipColour: [UInt8] = [230, 60, 50]
    /// Flash: the color peak is `(1 - |2w - 1|)^exponent` (a dip is exponent 1).
    static let flashExponent = 2.5
    static func sanitised(_ c: [UInt8]?) -> [UInt8]? { c.flatMap { $0.count == 3 ? $0 : nil } }

    /// Audio gains at progress 0...1 through the transition. Constant Power: equal-power (cos/sin), the summed power of
    /// uncorrelated material stays constant. Constant Gain: linear, the summed amplitude of identical material stays constant.
    public static func audioGains(_ kind: TransitionKind, progress p: Double) -> (outgoing: Double, incoming: Double) {
        let p = min(max(p, 0), 1)
        if kind == .constantGain { return (1 - p, p) }
        if kind == .exponentialFade { return ((1 - p) * (1 - p), p * p) }
        return (cos(p * .pi / 2), sin(p * .pi / 2))
    }
}

extension EasingCurve {
    /// Eased progress for normalized time `t` (clamped to 0...1). Hold stays at 0 until the very end.
    public func progress(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch interpolation {
        case .linear: return t
        case .hold: return t < 1 ? 0 : 1
        case .holdAhead: return t > 0 ? 1 : 0
        case .bezier:
            if t == 0 || t == 1 { return t }
            return KeyframeMath.bezierProgress(t, out: outHandle, in: inHandle)
        }
    }
}

/// How one side of a motion transition is drawn at one instant. Offsets and blur are fractions of the frame (x of the
/// width, y of the height, y down), so the result does not depend on the canvas size; scale is about the frame center.
public struct TransitionSide: Sendable, Hashable {
    public var offset: Vec2 = .zero
    public var scale = 1.0
    public var opacity = 1.0
    /// Directional motion blur: the full smear vector (centered on the picture's position).
    public var blur: Vec2 = .zero
    /// Radial (zoom) blur: relative scale spread of the smear, centered.
    public var zoomBlur = 0.0
    /// Rotation about the frame center in radians (clockwise on screen), applied in pixels so the picture stays undistorted.
    public var rotation = 0.0
    /// Outside the picture it repeats mirrored instead of being transparent (a side scaled below 100 % still fills the frame).
    public var mirrorEdges = false

    public init(offset: Vec2 = .zero, scale: Double = 1, opacity: Double = 1, blur: Vec2 = .zero, zoomBlur: Double = 0,
                rotation: Double = 0, mirrorEdges: Bool = false) {
        self.offset = offset; self.scale = scale; self.opacity = opacity; self.blur = blur; self.zoomBlur = zoomBlur
        self.rotation = rotation; self.mirrorEdges = mirrorEdges
    }
    public static let identity = TransitionSide()
}

/// One frame of a motion transition: both sides (each composited alone into a transparent frame first) and how they combine.
/// Pure values, shared by playback and export; the compositor's `transitionMix` kernel draws it.
public struct TransitionRender: Sendable, Hashable {
    public enum Compose: UInt32, Sendable, Hashable {
        /// Premultiplied sum: the two pictures tile the frame (push). Edges are bilinear, so the seam always sums to full cover.
        case sum = 0
        case incomingOver = 1
        case outgoingOver = 2
        /// Soft-edged mask between the two.
        case wipe = 3
        /// RGB split + slice displacement on one picture, hard cut at `Glitch.mix` 0.5.
        case glitch = 4
        /// Ellipse mask (`Iris`): B inside the growing ellipse, `wipe.front` = its radius, `wipe.softness` the edge.
        case iris = 5
        /// Dissolve plus a screen-blended gradient (`LightLeak`): `wipe.front` = eased progress, direction = travel.
        case lightLeak = 6
        /// Dissolve of two pictures each smeared by a disc blur (`wipe.front` = incoming weight, `wipe.softness` = blur radius,
        /// frame height fractions): `BlurDissolve`.
        case blurDissolve = 7
        /// Channel-change noise (`Glitch` fields: mix = incoming weight, intensity, seed): hard cut at mix 0.5.
        case staticNoise = 8
        /// Dissolve plus a drifting screen-blended glow noise (`wipe.front` = eased progress).
        case lightNoise = 9
        /// Reveal of B by a distance field (`ShapeWipe`): `wipe.direction.x` = shape id, `front` / `softness` as an iris.
        case shape = 10
        /// Dissolve under blocks that grow to the middle and shrink again (`wipe.front` = eased progress).
        case mosaic = 11
        /// Flip 3D (`Flip3D`): one card turning about the center line, `wipe.front` = eased progress, direction = axis and sense.
        case flip3D = 12
        /// Burn / Flare / Warp / Shake: `wipe.front` = eased progress (direction leans Burn and moves Flare).
        case burn = 13, flare = 14, warp = 15, shake = 16
    }
    public struct Wipe: Sendable, Hashable {
        /// Direction the edge travels (unit vector, y down).
        public var direction: Vec2
        /// Edge position along `direction`, 0 = the side it starts from, 1 = the far side; B shows behind it.
        public var front: Double
        /// Half width of the soft band, frame fractions.
        public var softness: Double
        public init(direction: Vec2 = .zero, front: Double = 0, softness: Double = 0) {
            self.direction = direction; self.front = front; self.softness = softness
        }
    }

    /// Glitch state: purely a function of the frame, so playback and export agree. The shader mirrors `sliceShift` bit for bit.
    public struct Glitch: Sendable, Hashable {
        /// Incoming weight 0...1; the picture switches from A to B at 0.5.
        public var mix: Double
        /// 0...1, a bell over the span (peaks at the cut).
        public var intensity: Double
        /// Per-frame hash seed.
        public var seed: UInt32
        public init(mix: Double = 0, intensity: Double = 0, seed: UInt32 = 0) { self.mix = mix; self.intensity = intensity; self.seed = seed }

        /// Horizontal bands (full frame height split in this many slices).
        public static let bands = 24
        /// Largest slice displacement and RGB channel offset, frame fractions of the width.
        public static let maxShift = 0.12, maxSplit = 0.025

        static func hash(_ band: UInt32, _ seed: UInt32) -> UInt32 {
            var h = band &* 0x9E3779B1 ^ seed &* 0x85EBCA6B
            h ^= h >> 15; h = h &* 0x2C1B3C6D; h ^= h >> 12; h = h &* 0x297A2D39; h ^= h >> 15
            return h
        }
        /// Horizontal displacement of one band (frame fractions, signed); 0 for most bands at low intensity.
        public static func sliceShift(band: Int, seed: UInt32, intensity: Double) -> Double {
            let h = hash(UInt32(band), seed)
            let gate = Double(h & 0xFF) / 255
            guard gate < 0.45 * intensity else { return 0 }
            return (Double((h >> 8) & 0xFFFF) / 65535 * 2 - 1) * maxShift * intensity
        }
        public static func rgbSplit(intensity: Double) -> Double { maxSplit * min(max(intensity, 0), 1) }
    }

    /// Iris mask. The shader (`transitionMix`, compose 5) mirrors this.
    public enum Iris {
        /// 0 at the center, 1 at the corners; the iso-lines are ellipses with the frame's aspect.
        public static func radius(u: Double, v: Double) -> Double {
            let x = (u - 0.5) * 2, y = (v - 0.5) * 2
            return (x * x + y * y).squareRoot() / 2.0.squareRoot()
        }
        /// How much of the incoming picture shows (1 inside the ellipse, 0 outside, smooth over +-softness).
        public static func mask(u: Double, v: Double, front: Double, softness: Double) -> Double {
            1 - smoothstep(front - softness, front + softness, radius(u: u, v: v))
        }
    }

    /// Shape reveals: every shape is a distance field `d(u, v)` over the frame (0...1, y down); B shows where `d` is below the
    /// front. The shader (`transitionMix`, compose 10) mirrors this, the shape id travels in `wipe.direction.x`.
    /// Spring and Fall move curves (frame fractions of travel).
    public enum SpringFall {
        /// 0 -> 1 with a small overshoot (about 9 % near 45 %) that settles exactly on 1.
        public static func spring(_ t: Double) -> Double {
            let t = min(max(t, 0), 1)
            return 1 - (1 - t) * exp(-4 * t) * cos(2.2 * .pi * t)
        }
        /// Gravity: distance grows with the square of the time, A is gone (past the edge) at the end.
        public static func fall(_ t: Double) -> Double { let t = min(max(t, 0), 1); return 1.1 * t * t }
        /// Tilt of the falling picture at the end of the fall, radians.
        public static let tilt = 0.25
    }

    /// Flip 3D geometry: the card at screen point (`x`, `y`) in -1...1 (y down) turned by `angle` about the vertical center
    /// line, camera 3 half-heights away. Returns the card point (-1...1) that lands there, nil where the card is not.
    /// The shader (`compose == 12`) repeats this.
    public enum Flip3D {
        public static let camera = 3.0
        public static func cardPoint(x X: Double, y Y: Double, angle: Double) -> (x: Double, y: Double)? {
            let d = camera, den = d * cos(angle) + X * sin(angle)
            guard den > 0.05 else { return nil }
            let x = X * d / den, y = Y * (d - x * sin(angle)) / d
            return abs(x) <= 1 && abs(y) <= 1 ? (x, y) : nil
        }
    }

    public enum ShapeWipe {
        public enum Shape: Int, Sendable, Hashable {
            case clock = 0, box, diamond, cross, doorsAcross, doorsDown, blinds
            case radial, wedge, pinwheel, checker, zigZag, inset, random, slice
        }
        /// Number of slats of Blinds.
        public static let blindCount = 8
        /// Cells of Checker (columns x rows), Zig-Zag Blocks (columns, rows) and Random Blocks.
        public static let checkerCells = (columns: 8, rows: 6)
        public static let zigZagCells = (columns: 8, rows: 8)
        public static let randomCells = (columns: 12, rows: 8)
        /// Strips of Slice.
        public static let sliceCount = 10
        /// Order of a Random Blocks cell, 0..<1. Integer hash; the shader (`shapeHash`) repeats it bit for bit.
        public static func cellOrder(_ cx: Int, _ cy: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: cx) &* 73856093 ^ UInt32(truncatingIfNeeded: cy) &* 19349663
            h = (h ^ (h >> 13)) &* 1274126177
            h ^= h >> 16
            return Double(h & 0xFFFF) / 65536
        }

        public static func distance(_ s: Shape, u: Double, v: Double) -> Double {
            let x = (u - 0.5) * 2, y = (v - 0.5) * 2
            switch s {
            case .clock:
                // Clockwise from 12 o'clock.
                let a = atan2(x, -y) / (2 * .pi)
                return a < 0 ? a + 1 : a
            case .box: return max(abs(x), abs(y))
            case .diamond: return (abs(x) + abs(y)) / 2
            case .cross: return min(abs(x), abs(y))
            case .doorsAcross: return abs(x)
            case .doorsDown: return abs(y)
            case .blinds:
                let t = v * Double(blindCount)
                return t - t.rounded(.down)
            case .radial:
                return atan2(u, v) / (.pi / 2)
            case .wedge:
                return atan2(abs(x), -y) / .pi
            case .pinwheel:
                let a = atan2(x, -y) / (2 * .pi), c = (a < 0 ? a + 1 : a) * 4
                return c - c.rounded(.down)
            case .checker:
                let c = Double(checkerCells.columns), r = Double(checkerCells.rows)
                let f = u * c - (u * c).rounded(.down)
                return (Int((u * c).rounded(.down)) + Int((v * r).rounded(.down))) % 2 == 0 ? f : 1 - f
            case .zigZag:
                let c = Double(zigZagCells.columns), r = Double(zigZagCells.rows)
                let row = min((v * r).rounded(.down), r - 1)
                let col = min((u * c).rounded(.down), c - 1)
                let along = (col + 0.5) / c
                return (row + (Int(row) % 2 == 0 ? along : 1 - along)) / r
            case .slice:
                let t = v * Double(sliceCount), row = t.rounded(.down)
                return Int(row) % 2 == 0 ? u : 1 - u
            case .inset:
                return max(u, v)
            case .random:
                let c = Double(randomCells.columns), r = Double(randomCells.rows)
                return cellOrder(Int(min((u * c).rounded(.down), c - 1)), Int(min((v * r).rounded(.down), r - 1)))
            }
        }
        /// How much of B shows (1 where `distance` is below the front, smooth over +-softness).
        public static func mask(_ s: Shape, u: Double, v: Double, front: Double, softness: Double) -> Double {
            1 - smoothstep(front - softness, front + softness, distance(s, u: u, v: v))
        }
    }

    /// Light Leak: the gradient color at a point and the dissolve behind it. The shader (compose 6) mirrors this.
    public enum LightLeak {
        /// Incoming weight of the underlying dissolve (B takes over while the leak peaks).
        public static func mixWeight(progress p: Double) -> Double { smoothstep(0.35, 0.65, p) }
        /// Strength of the leak over the span, 0 at both ends and 1 in the middle.
        public static func bell(progress p: Double) -> Double { max(0, sin(min(max(p, 0), 1) * .pi)) }
        /// Leak color (linear, added with screen blend) at `u, v` (0...1, y down). A soft band traveling along `direction`;
        /// `softness` widens it.
        public static func leak(u: Double, v: Double, progress p: Double, direction d: Vec2, softness: Double) -> (r: Double, g: Double, b: Double) {
            let x = (u - 0.5) * d.x + (v - 0.5) * d.y + 0.5            // along the travel
            let y = -(u - 0.5) * d.y + (v - 0.5) * d.x + 0.5           // across it
            let centre = -0.3 + 1.6 * p, width = 0.15 + 1.5 * softness
            let k = (x - centre) / width
            let f = exp(-k * k)
            let b = bell(progress: p)
            let t = min(max(y, 0), 1)
            let warm = (r: 1.0, g: 0.55 - 0.35 * t, b: 0.15 + 0.3 * t)  // orange at one edge, pink at the other
            let a = f * b * 1.2, core = f * f * f * b
            return (min(1, warm.r * a + 0.4 * core), min(1, warm.g * a + 0.3 * core), min(1, warm.b * a + 0.2 * core))
        }
        /// Screen blend of `leak` over a premultiplied picture (the leak counts as much as the picture's alpha).
        public static func screen(base c: (Double, Double, Double), alpha a: Double,
                                  leak l: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
            (c.0 + l.r * a * (1 - c.0), c.1 + l.g * a * (1 - c.1), c.2 + l.b * a * (1 - c.2))
        }
    }

    /// Blur Dissolve: the blur radius peaks (as a bell) in the middle of the span.
    public enum BlurDissolve {
        /// Largest radius, fraction of the frame height.
        public static let maxRadius = 0.02
        public static func radius(progress p: Double) -> Double { maxRadius * max(0, sin(min(max(p, 0), 1) * .pi)) }
    }
    /// Spin: the largest rotation of either picture, radians (90 degrees).
    public static let spinAngle = Double.pi / 2
    /// Scale at which a picture rotated by `angle` still covers a frame up to 16:9 (a wider frame shows a sliver of the other side).
    public static func coverScale(rotation angle: Double) -> Double { cos(abs(angle)) + sin(abs(angle)) * 16.0 / 9.0 }
    /// Cross Zoom: A grows to 1 + this, B settles from 1 + this; the radial smear is `crossZoomBlur * bell * motionBlur`.
    public static let crossZoomAmount = 0.4, crossZoomBlur = 0.35, spinBlur = 0.12
    /// Strobe Cut: A and B alternate over this many equal parts (even = A, odd = B), so it ends on B.
    public static let strobeParts = 6

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    public var outgoing: TransitionSide
    public var incoming: TransitionSide
    public var compose: Compose
    public var wipe: Wipe
    public var glitch = Glitch()
    /// Border drawn over the moving edge (`wipe.direction` / `wipe.front` locate it); nil = none.
    public var border: Border?

    /// A colored band centered on the transition's moving edge. The shader (`transitionCompose`, after the mix) mirrors
    /// `coverage`; the color is working-space linear.
    public struct Border: Sendable, Hashable {
        /// Full width, frame fraction along the travel direction.
        public var width: Double
        public var r: Double, g: Double, b: Double
        /// nil unless `width` > 0. `color`: display-encoded RGB bytes (nil = white), linearized with the BT.709 inverse OETF.
        public init?(width: Double?, color: [UInt8]?) {
            guard let w = width, w.isFinite, w > 0 else { return nil }
            self.width = min(w, TransitionKind.maxBorderWidth)
            func lin(_ v: UInt8) -> Double {
                let x = Double(v) / 255
                return x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1 / 0.45)
            }
            let c = color?.count == 3 ? color! : [255, 255, 255]
            r = lin(c[0]); g = lin(c[1]); b = lin(c[2])
        }
        /// How much of the band covers a point at `x` (0...1 along the travel direction) when the edge is at `front`;
        /// `aa` = half a pixel along the direction, so the band edge is smooth;
        /// the band fades while `front` is within half a width of the frame edge.
        public static func coverage(x: Double, front: Double, width: Double, aa: Double) -> Double {
            let d = abs(x - front), h = width / 2
            let a = max(aa, 1e-6)
            // The band fades in over its own half width as the edge enters or leaves the frame: no solid strip on the
            // first and last frame.
            let enter = TransitionRender.smoothstep(0, h, front) * TransitionRender.smoothstep(0, h, 1 - front)
            return (1 - TransitionRender.smoothstep(h - a, h + a, d)) * enter
        }
    }

    public init(outgoing: TransitionSide = .identity, incoming: TransitionSide = .identity, compose: Compose = .sum, wipe: Wipe = Wipe()) {
        self.outgoing = outgoing; self.incoming = incoming; self.compose = compose; self.wipe = wipe
    }

    /// Zoom Pop's 110 % -> 100 % with a fading 4 % radial smear (the maintainer's "VideoStart OUT": scale 110 -> 100 plus blur
    /// 40 -> 0 over the first ~0.2 s).
    static let popScale = 0.1, popBlur = 0.04
    /// Zoom In / Out (DECISIONS 2026-10-04, the maintainer's real spec): both layers scale between 100 % and this (110-120 % discussed).
    public static let zoomAmount = 1.1
    /// Zoom In / Out: A's opacity fade over B at the transition point, in frames (fixed, independent of the span).
    public static let zoomFadeFrames = 3.0
    /// Zoom In / Out speed curve exponent: A follows u^k (fastest at its end), B 1 - (1 - u)^k (fastest at its start).
    static let zoomCurve = 3.0

    /// Zoom In / Out (DECISIONS 2026-10-04): B sits under A; A fades out over `zoomFadeFrames` centered on the middle of the
    /// span (a short real crossfade). A plays its move from the span start to the end of that fade, B from the start of the
    /// fade to the span end, both 100 -> amount % (Zoom Out: amount -> 100 %), A accelerating into its end and B starting at
    /// full speed and settling: one continuous move with its peak speed at the fade. Scale stays >= 100 %, no empty edges.
    /// Single-sided ones play their side's move over the whole span and fade in (head) / out (tail) over the same frames.
    /// The radial blur is each layer's relative scale change during the shutter. Positions are in frames (`frameIndex + 1`
    /// of `frames + 1`, as `TransitionMix.videoWeight`), so the fade stays exact.
    ///
    /// `settles` (DECISIONS 2026-10-06, a transition with a stored Amount): the move ends at rest on both span edges, so nothing
    /// jumps there. Zoom In: A 100 % -> amount, B 100 / amount % -> 100 % (same direction, B a little past 100 % and back).
    /// Zoom Out: A 100 % -> 100 / amount %, B amount -> 100 %. The side below 100 % repeats mirrored at its edges (under the
    /// smear), so the frame stays full.
    static func zoomLayers(zoomIn: Bool, amount: Double, motionBlur: Double, frameIndex i: Int, frames n: Int,
                           hasOutgoing: Bool, hasIncoming: Bool, settles: Bool = false) -> TransitionRender {
        let total = Double(n + 1), pos = Double(i + 1)
        let fade = max(1, min(zoomFadeFrames, total / 2))
        let mid = total / 2
        let aEnd = hasIncoming ? mid + fade / 2 : total
        let bStart = hasOutgoing ? mid - fade / 2 : 0
        let k = zoomCurve, delta = max(amount, 1) - 1
        func scale(_ p: Double) -> Double { zoomIn ? 1 + delta * p : 1 + delta * (1 - p) }
        let big = max(amount, 1), small = 1 / big
        func aScale(_ x: Double) -> Double {
            let p = pow(min(max(x / aEnd, 0), 1), k)
            return settles ? 1 + ((zoomIn ? big : small) - 1) * p : scale(p)
        }
        func bScale(_ x: Double) -> Double {
            let u = min(max((x - bStart) / (total - bStart), 0), 1)
            guard settles else { return scale(1 - pow(1 - u, k)) }
            // Zoom In lands from below and may swing past 100 % (never shows an edge); Zoom Out lands from above without.
            let from = zoomIn ? small : big
            return from + (1 - from) * (zoomIn ? zoomSettle(u) : 1 - pow(1 - u, 4))
        }
        let h = max(0, motionBlur) / 2
        func blur(_ f: (Double) -> Double) -> Double { abs(f(pos + h) - f(pos - h)) / f(pos) }
        var aOpacity = 0.0, bOpacity = 0.0
        if hasOutgoing { aOpacity = min(1, max(0, (aEnd - pos) / fade)) }
        if hasIncoming { bOpacity = hasOutgoing ? (pos > bStart ? 1 : 0) : min(1, pos / fade) }
        var r = TransitionRender()
        r.outgoing = TransitionSide(scale: aScale(pos), opacity: aOpacity, zoomBlur: blur(aScale), mirrorEdges: settles && !zoomIn)
        r.incoming = TransitionSide(scale: bScale(pos), opacity: bOpacity, zoomBlur: blur(bScale), mirrorEdges: settles && zoomIn)
        r.compose = .outgoingOver
        return r
    }

    /// B's progress in a settling Zoom In: starts at full speed, passes its rest by 6 % of the way at half time and comes
    /// back with no speed left: 1 - (1 - u)^3 (1 - 3u).
    static func zoomSettle(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        return 1 - pow(1 - u, 3) * (1 - 3 * u)
    }

    /// The state on frame `frameIndex` of `frames`. Progress is `TransitionMix.videoWeight` through `easing`. Motion blur is
    /// physical: the distance travelled during `motionBlur` frames of shutter at the current (eased) speed.
    /// `hasIncoming` false (a tail transition: an outgoing clip, nothing after it): kinds that only animate the incoming
    /// picture (Slide, Zoom Pop) play mirrored on the outgoing one, so it slides / pops out instead of hard-cutting.
    public static func evaluate(kind: TransitionKind, direction: TransitionDirection, softness: Double, motionBlur: Double,
                                easing: EasingCurve, frameIndex i: Int, frames n: Int, hasIncoming: Bool = true,
                                hasOutgoing: Bool = true, zoomAmount amount: Double = zoomAmount,
                                zoomSettles: Bool = false, border: Border? = nil) -> TransitionRender {
        let raw = TransitionMix.videoWeight(frameIndex: i, frames: n)
        let dt = 1 / Double(n + 1)
        let e = easing.progress(raw)
        // A curve may run outside 0...1 (overshoot): the moves follow it, the opacities of Spin / Cross Zoom do not.
        let w = min(max(e, 0), 1)
        // Progress covered by one frame of shutter around this instant.
        let de = (easing.progress(raw + dt / 2) - easing.progress(raw - dt / 2)) * max(0, motionBlur)
        let v = direction.vector
        func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        var r = TransitionRender()
        switch kind {
        case .push, .whip:
            let blur = Vec2(v.x * de, v.y * de)
            r.outgoing = TransitionSide(offset: Vec2(v.x * e, v.y * e), blur: blur)
            r.incoming = TransitionSide(offset: Vec2(v.x * (e - 1), v.y * (e - 1)), blur: blur)
            r.compose = .sum
            if kind == .push, let border { r.border = border; r.wipe = Wipe(direction: v, front: e) }
        case .slide where !hasIncoming:
            // The slide-in played backwards in time but still traveling along `direction`: A leaves, accelerating.
            let eo = 1 - easing.progress(1 - raw)
            r.outgoing = TransitionSide(offset: Vec2(v.x * eo, v.y * eo), blur: Vec2(v.x * de, v.y * de))
            r.compose = .sum
            if let border { r.border = border; r.wipe = Wipe(direction: v, front: eo) }
        case .slide:
            r.incoming = TransitionSide(offset: Vec2(v.x * (e - 1), v.y * (e - 1)), blur: Vec2(v.x * de, v.y * de))
            r.compose = .incomingOver
            if let border { r.border = border; r.wipe = Wipe(direction: v, front: e) }
        case .zoomIn, .zoomOut:
            return zoomLayers(zoomIn: kind == .zoomIn, amount: amount, motionBlur: motionBlur, frameIndex: i, frames: n,
                              hasOutgoing: hasOutgoing, hasIncoming: hasIncoming, settles: zoomSettles)
        case .zoomPop where !hasIncoming:
            // The pop-in reversed in time: A grows towards 110 %, the smear builds and it fades out at the end.
            let back = 1 - raw
            let sa = 1 + popScale * (1 - easing.progress(back))
            let pop = popBlur * max(0, 1 - back / 0.3)
            r.outgoing = TransitionSide(scale: sa, opacity: min(1, back / 0.15), zoomBlur: pop + popScale * de / sa)
            r.compose = .outgoingOver
        case .zoomPop:
            let sb = 1 + popScale * (1 - e)
            let pop = popBlur * max(0, 1 - raw / 0.3)
            r.incoming = TransitionSide(scale: sb, opacity: min(1, raw / 0.15), zoomBlur: pop + popScale * de / sb)
            r.compose = .incomingOver
        case .softWipe:
            let s = min(max(softness, 0), 0.5)
            r.wipe = Wipe(direction: v, front: e * (1 + 2 * s) - s, softness: s)
            r.compose = .wipe
            r.border = border
        case .iris:
            let s = min(max(softness, 0), 0.5)
            r.wipe = Wipe(direction: v, front: e * (1 + 2 * s) - s, softness: s)
            r.compose = .iris
        case .lightLeak:
            r.wipe = Wipe(direction: v, front: e, softness: min(max(softness, 0), 0.5))
            r.compose = .lightLeak
        case .blurDissolve:
            r.wipe = Wipe(direction: v, front: e, softness: BlurDissolve.radius(progress: raw))
            r.compose = .blurDissolve
        case .spin:
            let sign = v.x + v.y > 0 ? 1.0 : -1.0
            let ta = sign * spinAngle * e, tb = sign * spinAngle * (e - 1)
            let bell = sin(raw * .pi) * spinBlur * max(0, motionBlur)
            r.outgoing = TransitionSide(scale: coverScale(rotation: ta), opacity: 1 - w, zoomBlur: bell, rotation: ta)
            r.incoming = TransitionSide(scale: coverScale(rotation: tb), opacity: w, zoomBlur: bell, rotation: tb)
            r.compose = .sum
        case .crossZoom:
            let blur = sin(raw * .pi) * crossZoomBlur * max(0, motionBlur)
            r.outgoing = TransitionSide(scale: 1 + crossZoomAmount * e, opacity: 1 - w, zoomBlur: blur)
            r.incoming = TransitionSide(scale: 1 + crossZoomAmount * (1 - e), opacity: w, zoomBlur: blur)
            r.compose = .sum
        case .strobeCut:
            let part = min(strobeParts - 1, Int(raw * Double(strobeParts)))
            let showB = part % 2 == 1
            r.outgoing = TransitionSide(opacity: showB ? 0 : 1)
            r.incoming = TransitionSide(opacity: showB ? 1 : 0)
            r.compose = .sum
        case .staticNoise:
            r.glitch = Glitch(mix: raw, intensity: min(1, 0.2 + 0.8 * sin(raw * .pi)),
                              seed: UInt32(truncatingIfNeeded: i) &* 2654435761 &+ 777)
            r.compose = .staticNoise
        case .lightNoise:
            r.wipe = Wipe(direction: v, front: e, softness: 0)
            r.compose = .lightNoise
        case .mosaicDissolve:
            r.wipe = Wipe(direction: v, front: e, softness: 0)
            r.compose = .mosaic
        case .flip3D, .burn, .flare, .warp, .shake:
            r.wipe = Wipe(direction: v, front: w, softness: 0)
            switch kind {
            case .flip3D: r.compose = .flip3D
            case .burn: r.compose = .burn
            case .flare: r.compose = .flare
            case .warp: r.compose = .warp
            default: r.compose = .shake
            }
        case .spring where !hasIncoming:
            // Nothing to settle: A just slides out along the direction.
            r.outgoing = TransitionSide(offset: Vec2(v.x * e, v.y * e), blur: Vec2(v.x * de, v.y * de))
            r.compose = .sum
        case .spring:
            // B slides in along `direction` and settles with a small overshoot; A stays under it.
            let s = SpringFall.spring(e)
            let ds = (SpringFall.spring(easing.progress(raw + dt / 2)) - SpringFall.spring(easing.progress(raw - dt / 2))) * max(0, motionBlur)
            r.incoming = TransitionSide(offset: Vec2(v.x * (s - 1), v.y * (s - 1)), blur: Vec2(v.x * ds, v.y * ds))
            r.compose = .incomingOver
        case .fall:
            // A drops out along `direction`, accelerating and tilting; B waits under it.
            let f = SpringFall.fall(e)
            let df = (SpringFall.fall(easing.progress(raw + dt / 2)) - SpringFall.fall(easing.progress(raw - dt / 2))) * max(0, motionBlur)
            let sign = v.x + v.y > 0 ? 1.0 : -1.0
            r.outgoing = TransitionSide(offset: Vec2(v.x * f, v.y * f), blur: Vec2(v.x * df, v.y * df), rotation: sign * SpringFall.tilt * f)
            r.compose = .outgoingOver
        case .additiveDissolve:
            // Both pictures at full strength over the middle, so the sum brightens (clipped by the display).
            r.outgoing = TransitionSide(opacity: min(1, 2 * (1 - w)))
            r.incoming = TransitionSide(opacity: min(1, 2 * w))
            r.compose = .sum
        case .clockWipe, .boxIris, .diamondIris, .crossIris, .barnDoors, .venetianBlinds, .radialWipe, .wedgeWipe, .pinwheel,
             .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe:
            let s = min(max(softness, 0), 0.5)
            let shape: ShapeWipe.Shape
            switch kind {
            case .clockWipe: shape = .clock
            case .boxIris: shape = .box
            case .diamondIris: shape = .diamond
            case .crossIris: shape = .cross
            case .barnDoors: shape = direction == .left || direction == .right ? .doorsAcross : .doorsDown
            case .radialWipe: shape = .radial
            case .wedgeWipe: shape = .wedge
            case .pinwheel: shape = .pinwheel
            case .checkerWipe: shape = .checker
            case .zigZagBlocks: shape = .zigZag
            case .insetWipe: shape = .inset
            case .randomBlocks: shape = .random
            case .sliceWipe: shape = .slice
            default: shape = .blinds
            }
            r.wipe = Wipe(direction: Vec2(Double(shape.rawValue), 0), front: e * (1 + 2 * s) - s, softness: s)
            r.compose = .shape
        case .glitch:
            let raw = TransitionMix.videoWeight(frameIndex: i, frames: n)
            r.glitch = Glitch(mix: raw, intensity: sin(raw * .pi), seed: UInt32(truncatingIfNeeded: i) &* 2654435761 &+ 12345)
            r.compose = .glitch
        default:
            break
        }
        return r
    }
}

/// The gain curve one clip's audio follows inside a transition span (see `AudioSegment.envelopes`).
public struct TransitionEnvelope: Sendable, Hashable {
    public enum Role: Sendable, Hashable { case outgoing, incoming }
    public var kind: TransitionKind
    public var span: TimeRange
    public var role: Role

    public init(kind: TransitionKind, span: TimeRange, role: Role) { self.kind = kind; self.span = span; self.role = role }

    /// Progress through the span at `t`, 0 before it and 1 after it.
    public func progress(at t: Time) -> Double {
        if t <= span.start { return 0 }
        if t >= span.end { return 1 }
        let a = t - span.start
        return Double(a.value) * Double(span.duration.timescale) / (Double(a.timescale) * Double(span.duration.value))
    }

    public func gain(at t: Time) -> Double {
        let g = TransitionMix.audioGains(kind, progress: progress(at: t))
        return role == .outgoing ? g.outgoing : g.incoming
    }
}

/// Where a transition can be applied.
public enum TransitionPoint: Sendable, Hashable {
    case cut(outgoing: Clip.ID, incoming: Clip.ID)
    case head(Clip.ID)
    case tail(Clip.ID)
}

// MARK: Resolution

extension Track {
    private static let unbounded: Int64 = 1 << 40

    /// Largest duration in frames the handles allow for this alignment (0 = none), given the portion limits.
    private static func maxFrames(_ alignment: TransitionAlignment, customBefore cb: Int64, beforeMax b: Int64, afterMax a: Int64) -> Int64 {
        switch alignment {
        case .center: return min(2 * b + 1, 2 * a)
        case .startAtCut: return a
        case .endAtCut: return b
        case .custom: return cb <= b ? cb + a : b
        }
    }

    /// Parts before and after the cut for a duration of `d` frames.
    private static func split(_ alignment: TransitionAlignment, customBefore cb: Int64, _ d: Int64) -> (before: Int64, after: Int64) {
        let b: Int64
        switch alignment {
        case .center: b = d / 2
        case .startAtCut: b = 0
        case .endAtCut: b = d
        case .custom: b = min(cb, d)
        }
        return (b, d - b)
    }

    /// The current, playable form of every transition of this track, in timeline order.
    public func resolvedTransitions(frameDuration fd: Time) -> [ResolvedTransition] {
        var out: [ResolvedTransition] = []
        for tr in transitions {
            if let r = resolve(tr, frameDuration: fd) { out.append(r) }
        }
        return out.sorted { $0.span.start < $1.span.start }
    }

    /// Index of clip `id`, looking next to `hint` first (the evaluation loops already know where they are).
    func clipIndex(_ id: Clip.ID, near hint: Int?) -> Int? {
        if let h = hint, !clips.isEmpty {
            for i in max(0, h - 2)...min(clips.count - 1, h + 2) where i >= 0 && clips[i].id == id { return i }
        }
        return clips.firstIndex { $0.id == id }
    }

    /// Index of the first clip that ends after `t` (binary search; clips are sorted and never overlap).
    func clipIndex(endingAfter t: Time) -> Int {
        var lo = 0, hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clips[mid].timeline.end > t { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// `budgeted`: also respect the clip's other (earlier) transition. A clip holds at most its own length of transition
    /// frames: the head transition keeps what it asks for (it comes first on the timeline), the tail one gets what is left.
    func resolve(_ tr: Transition, frameDuration fd: Time, hint: Int? = nil, budgeted: Bool = true) -> ResolvedTransition? {
        guard tr.kind.trackKind == kind else { return nil }
        func frames(_ t: Time) -> Int64 { max(0, t.frameIndex(frameDuration: fd)) }
        func cap(_ t: Time?) -> Int64 { t.map { min(frames($0), Self.unbounded) } ?? Self.unbounded }
        let want = max(1, frames(tr.duration))
        let cb = frames(tr.customBefore)

        func make(cut: Time, d: Int64, b: Int64, a: Int64, heldBefore: Int64 = 0, heldAfter: Int64 = 0) -> ResolvedTransition {
            var r = ResolvedTransition(id: tr.id, kind: tr.kind, alignment: tr.alignment, outgoing: tr.outgoing, incoming: tr.incoming,
                               cut: cut, span: TimeRange(start: cut - fd * b, duration: fd * d), before: fd * b, after: fd * a,
                               requestedDuration: fd * want, frameDuration: fd, easing: tr.effectiveEasing,
                               direction: tr.renderDirection, softness: tr.effectiveSoftness, motionBlur: tr.effectiveMotionBlur)
            r.color = tr.color
            r.zoomAmount = tr.zoomAmount
            r.borderWidth = tr.borderWidth
            r.borderColor = tr.borderColor
            r.heldBefore = heldBefore
            r.heldAfter = heldAfter
            return r
        }

        if tr.kind.isStinger {
            // The stinger never shows handle frames: A plays to the edit, B from it. Its cut frame sits on the edit; a clip
            // shorter than its part trims the stinger on that side (a head trim moves `stingerStart`).
            guard let o = tr.outgoing, let i = tr.incoming, let oi = clipIndex(o, near: hint), oi + 1 < clips.count,
                  clips[oi + 1].id == i, clips[oi].timeline.end == clips[oi + 1].start else { return nil }
            let out = clips[oi], inc = clips[oi + 1]
            let cut = min(want, Int64((Double(want) * (tr.stinger?.cutFraction ?? 0.5)).rounded()))
            let bMax = max(0, frames(out.duration) - (budgeted ? headPortion(of: o, except: tr.id, element: tr.kind.isElement, fd) : 0))
            let b = min(cut, bMax), a = min(want - cut, frames(inc.duration))
            guard b + a >= 1 else { return nil }
            var r = make(cut: inc.start, d: b + a, b: b, a: a)
            r.stinger = tr.stinger
            r.stingerStart = fd * (cut - b)
            return r
        }

        switch (tr.outgoing, tr.incoming) {
        case let (o?, i?):
            guard let oi = clipIndex(o, near: hint), oi + 1 < clips.count, clips[oi + 1].id == i,
                  clips[oi].timeline.end == clips[oi + 1].start else { return nil }
            let out = clips[oi], inc = clips[oi + 1]
            let outSpan = max(0, frames(out.duration) - (budgeted ? headPortion(of: o, except: tr.id, element: tr.kind.isElement, fd) : 0))
            // Video, no media beyond the cut on a side (Premiere repeats frames; Q-TRN1, parity fix 8): that side holds its
            // edge frame instead of refusing, on one side or both. Only the clips' own lengths bound the span then. The
            // held frames are derived here, nothing is stored; `Clip.sourceTime` clamps the read to the media edge, so
            // playback and export decode the edge frame (one decode, cached like any still-standing frame). Audio never
            // holds (no repeated samples). A small non-zero handle still shortens the transition.
            let incHead = cap(inc.headHandle), outTail = cap(out.tailRoom)
            let holdBefore = kind == .video && incHead == 0     // incoming head frozen before the cut
            let holdAfter = kind == .video && outTail == 0      // outgoing tail frozen after the cut
            let bMax = min(holdBefore ? Self.unbounded : incHead, outSpan)
            let aMax = min(holdAfter ? Self.unbounded : outTail, frames(inc.duration))
            let d = min(want, Self.maxFrames(tr.alignment, customBefore: cb, beforeMax: bMax, afterMax: aMax))
            guard d >= 1 else { return nil }
            let (b, a) = Self.split(tr.alignment, customBefore: cb, d)
            return make(cut: inc.start, d: d, b: b, a: a, heldBefore: holdBefore ? b : 0, heldAfter: holdAfter ? a : 0)
        case let (nil, i?):
            guard let ci = clipIndex(i, near: hint) else { return nil }
            let c = clips[ci]
            let d = min(want, frames(c.duration))
            guard d >= 1 else { return nil }
            return make(cut: c.start, d: d, b: 0, a: d)
        case let (o?, nil):
            guard let ci = clipIndex(o, near: hint) else { return nil }
            let c = clips[ci]
            let d = min(want, max(0, frames(c.duration) - (budgeted ? headPortion(of: o, except: tr.id, element: tr.kind.isElement, fd) : 0)))
            guard d >= 1 else { return nil }
            return make(cut: c.timeline.end, d: d, b: d, a: 0)
        case (nil, nil):
            return nil
        }
    }

    /// Frames of clip `o` taken by the transition of the same class (element or not) that sits on its head (the earlier
    /// one), before any budgeting. Element and cut transitions are separate layers and never share a clip's frames.
    private func headPortion(of o: Clip.ID, except id: Transition.ID, element: Bool, _ fd: Time) -> Int64 {
        guard let h = transitions.first(where: { $0.incoming == o && $0.id != id && $0.kind.isElement == element }),
              let r = resolve(h, frameDuration: fd, budgeted: false) else { return 0 }
        return r.after.frameIndex(frameDuration: fd)
    }

    /// Removes the other transitions of `tr`'s class (element or not) on any edge `tr` uses.
    mutating func removeTransitions(sharingEdgesWith tr: Transition) {
        transitions.removeAll { other in
            other.id != tr.id && other.kind.isElement == tr.kind.isElement
                && ((tr.outgoing != nil && other.outgoing == tr.outgoing) || (tr.incoming != nil && other.incoming == tr.incoming))
        }
    }

    /// Alignment a new transition gets (Premiere, parity fix 8): a centered video transition at a cut with media beyond the
    /// cut on one side only moves wholly onto that side (End at Cut on the incoming head, Start at Cut on the outgoing
    /// tail) when that handle holds the requested length, so no frame is held. Otherwise, and for every other request, the
    /// alignment asked for (held frames fill what is missing).
    func appliedAlignment(for tr: Transition, frameDuration fd: Time) -> TransitionAlignment {
        guard kind == .video, tr.alignment == .center, !tr.kind.isStinger, let o = tr.outgoing, let i = tr.incoming,
              let oc = clip(o), let ic = clip(i) else { return tr.alignment }
        let noTail = oc.tailRoom.map { $0.frameIndex(frameDuration: fd) <= 0 } ?? false
        let noHead = ic.headHandle.map { $0.frameIndex(frameDuration: fd) <= 0 } ?? false
        guard noTail != noHead else { return tr.alignment }
        var probe = tr
        probe.alignment = noTail ? .endAtCut : .startAtCut
        guard let r = resolve(probe, frameDuration: fd), r.span.duration >= probe.duration, !r.isHeld else { return tr.alignment }
        return probe.alignment
    }

    /// Largest whole-frame duration the handles allow for `tr` right now (0 = nothing fits).
    func maxTransitionFrames(_ tr: Transition, frameDuration fd: Time) -> Int64 {
        var probe = tr
        probe.duration = fd * Self.unbounded
        return resolve(probe, frameDuration: fd).map { Int64($0.frames) } ?? 0
    }

    /// Drops transitions whose cut or clip no longer exists (or that nothing fits into any more).
    mutating func pruneTransitions(frameDuration fd: Time) {
        guard !transitions.isEmpty else { return }
        let keep = transitions.filter { resolve($0, frameDuration: fd) != nil }
        if keep.count != transitions.count { transitions = keep }
    }

    // MARK: Evaluation helpers (video / audio)

    /// What the track shows at `t`: an optional solid dip layer (bottom) and the clips with an opacity factor.
    /// Without a transition at `t` this is just the clip under `t` at opacity 1.
    /// `motion`: a motion transition in progress; its clips are drawn at opacity 1 and tagged as the two sides of its render node
    /// (`incoming` names the clip that is the second side, so a single-sided one knows its role).
    /// `stinger`: a Stinger in progress; `items` are then the clip on screen (A before the edit, B from it) and the stinger
    /// clip on top, both at opacity 1.
    /// Element transitions (Move / Zoom / Pop) are not drawn here: every returned clip carries their motion effect instead
    /// (`clipWithElementTransitions`).
    func videoEntries(at t: Time, frameDuration fd: Time)
        -> (dip: (id: Transition.ID, color: [UInt8])?, pair: Transition.ID?,
            motion: (id: Transition.ID, render: TransitionRender, incoming: Clip.ID?)?, items: [(clip: Clip, opacity: Double)],
            stinger: Transition.ID?) {
        var r = mixEntries(at: t, frameDuration: fd)
        guard transitions.contains(where: { $0.kind.isElement }) else { return r }
        r.items = r.items.map { (clipWithElementTransitions($0.clip, at: t, frameDuration: fd), $0.opacity) }
        return r
    }

    private func mixEntries(at t: Time, frameDuration fd: Time)
        -> (dip: (id: Transition.ID, color: [UInt8])?, pair: Transition.ID?,
            motion: (id: Transition.ID, render: TransitionRender, incoming: Clip.ID?)?, items: [(clip: Clip, opacity: Double)],
            stinger: Transition.ID?) {
        let k = clipIndex(endingAfter: t)
        let base = k < clips.count && clips[k].timeline.contains(t) && clips[k].isEnabled ? clips[k] : nil
        guard !transitions.isEmpty else { return (nil, nil, nil, base.map { [($0, 1.0)] } ?? [], nil) }
        // Only transitions on the clip at `t` and its neighbors can reach `t` (a span never leaves the clips it joins).
        let near = Set(clips[max(0, k - 1)..<min(clips.count, k + 2)].map(\.id))
        for tr in transitions where !tr.kind.isElement && (tr.outgoing.map(near.contains) == true || tr.incoming.map(near.contains) == true) {
            guard let r = resolve(tr, frameDuration: fd, hint: k), let i = r.frameIndex(at: t) else { continue }
            if r.kind.isStinger {
                guard let st = r.stinger else { break }   // nothing picked yet: a plain cut
                var items: [(clip: Clip, opacity: Double)] = []
                if let side = t < r.cut ? r.outgoing : r.incoming, let c = clip(side), c.isEnabled { items.append((c, 1)) }
                items.append((st.clip(id: r.id, span: r.span, sourceStart: r.stingerStart), 1))
                return (nil, nil, nil, items, r.id)
            }
            if r.kind.isMotion {
                // A side counts only when its clip is there and enabled (a disabled A: B plays its head-only half).
                let oc = r.outgoing.flatMap { clip($0) }.flatMap { $0.isEnabled ? $0 : nil }
                let ic = r.incoming.flatMap { clip($0) }.flatMap { $0.isEnabled ? $0 : nil }
                let render = TransitionRender.evaluate(kind: r.kind, direction: r.direction, softness: r.softness,
                                                       motionBlur: r.motionBlur, easing: r.easing, frameIndex: i, frames: r.frames,
                                                       hasIncoming: ic != nil, hasOutgoing: oc != nil,
                                                       zoomAmount: r.zoomAmount ?? TransitionRender.zoomAmount,
                                                       zoomSettles: r.zoomAmount != nil,
                                                       border: r.kind.usesBorder
                                                           ? .init(width: r.borderWidth, color: r.borderColor) : nil)
                var items: [(clip: Clip, opacity: Double)] = []
                if let oc { items.append((oc, 1)) }
                if let ic { items.append((ic, 1)) }
                return (nil, nil, (r.id, render, r.incoming), items, nil)
            }
            let w = r.easing.mixWeight(TransitionMix.videoWeight(frameIndex: i, frames: r.frames))
            let dipKind = r.kind.isDip
            let dip = dipKind ? (r.id, TransitionMix.dipColor(r.kind, custom: r.color)) : nil
            switch (r.outgoing, r.incoming) {
            case let (o?, i?):
                guard let oc = clip(o), let ic = clip(i) else { continue }
                // A disabled clip next to the cut never shows: the other side fades alone.
                var items: [(clip: Clip, opacity: Double)] = []
                let m = TransitionMix.video(r.kind, weight: w)
                if oc.isEnabled { items.append((oc, dipKind ? m.outgoing : 1 - w)) }
                if ic.isEnabled { items.append((ic, dipKind ? m.incoming : w)) }
                if dipKind { return (dip, nil, nil, items, nil) }
                // Cross dissolve: premultiplied sum A*(1-w) + B*w in linear light (the compositor's `pair` node).
                return (nil, items.count == 2 ? r.id : nil, nil, items, nil)
            case let (nil, i?):
                guard let ic = clip(i) else { continue }
                return (dip, nil, nil, ic.isEnabled ? [(ic, w)] : [], nil)
            case let (o?, nil):
                guard let oc = clip(o) else { continue }
                return (dip, nil, nil, oc.isEnabled ? [(oc, 1 - w)] : [], nil)
            case (nil, nil):
                continue
            }
        }
        return (nil, nil, nil, base.map { [($0, 1.0)] } ?? [], nil)
    }

    /// Per clip: how far its audio extends into its handles and the gain envelopes of its audio transitions.
    /// Only for the transitions that touch `ids` (the clips the caller is about to read).
    func audioTransitionInfo(frameDuration fd: Time, for ids: Set<Clip.ID>)
        -> [Clip.ID: (head: Time, tail: Time, envelopes: [TransitionEnvelope])] {
        guard kind == .audio, !transitions.isEmpty else { return [:] }
        var info: [Clip.ID: (head: Time, tail: Time, envelopes: [TransitionEnvelope])] = [:]
        // Disguise Voice: a clip without the effect never sounds in its handle next to a clip that has it. That handle is the
        // source under the disguised neighbor (the same recording after a range cut), so playing it would let the original
        // voice through the fade. The clip ends at its own edge there; the disguised side still fades through its handle.
        func silentHandle(_ id: Clip.ID, next other: Clip.ID?) -> Bool {
            guard let other, clip(other)?.hasDisguiseVoice == true else { return false }
            return clip(id)?.hasDisguiseVoice != true
        }
        for tr in transitions where tr.outgoing.map(ids.contains) == true || tr.incoming.map(ids.contains) == true {
            guard let r = resolve(tr, frameDuration: fd) else { continue }
            if let o = r.outgoing {
                var e = info[o] ?? (.zero, .zero, [])
                if !silentHandle(o, next: r.incoming) { e.tail = max(e.tail, r.after) }
                e.envelopes.append(TransitionEnvelope(kind: r.kind, span: r.span, role: .outgoing))
                info[o] = e
            }
            if let i = r.incoming {
                var e = info[i] ?? (.zero, .zero, [])
                if !silentHandle(i, next: r.outgoing) { e.head = max(e.head, r.before) }
                e.envelopes.append(TransitionEnvelope(kind: r.kind, span: r.span, role: .incoming))
                info[i] = e
            }
        }
        return info
    }
}

// MARK: Timeline API

extension Timeline {
    /// One second in whole frames of the sequence (Premiere's initial default duration of both kinds).
    public static func defaultTransitionDuration(frameDuration fd: Time) -> Time {
        fd * max(1, Int64((Double(fd.timescale) / Double(fd.value)).rounded()))
    }

    public func resolvedTransitions(on track: Track.ID) -> [ResolvedTransition] {
        self.track(track)?.resolvedTransitions(frameDuration: format.frameDuration) ?? []
    }

    /// Looks a transition up by ID.
    public func transition(_ id: Transition.ID) -> (track: Track.ID, transition: Transition)? {
        for t in tracks { if let tr = t.transitions.first(where: { $0.id == id }) { return (t.id, tr) } }
        return nil
    }

    /// Largest whole-frame duration the clip handles allow for the transition now.
    public func maxTransitionFrames(_ id: Transition.ID) -> Int64 {
        guard let (tid, tr) = transition(id), let t = track(tid) else { return 0 }
        return t.maxTransitionFrames(tr, frameDuration: format.frameDuration)
    }

    /// The cut or clip edge on `track` nearest to `t`: where Apply Video/Audio Transition lands.
    public func transitionPoint(near t: Time, on track: Track.ID) -> TransitionPoint? {
        guard let tr = self.track(track) else { return nil }
        var best: (TransitionPoint, Time)?
        func consider(_ p: TransitionPoint, at time: Time) {
            let d = time >= t ? time - t : t - time
            if best == nil || d < best!.1 { best = (p, d) }
        }
        let cs = tr.clips
        for (i, c) in cs.enumerated() {
            let prevTouches = i > 0 && cs[i - 1].timeline.end == c.start
            let nextTouches = i + 1 < cs.count && cs[i + 1].start == c.timeline.end
            if prevTouches { consider(.cut(outgoing: cs[i - 1].id, incoming: c.id), at: c.start) } else { consider(.head(c.id), at: c.start) }
            if !nextTouches { consider(.tail(c.id), at: c.timeline.end) }
        }
        return best?.0
    }

    /// Whole frames, at least 1.
    private func snapped(_ d: Time) -> Time {
        let fd = format.frameDuration
        return fd * max(1, d.frameIndex(frameDuration: fd))
    }

    private func trackIndex(_ id: Track.ID) throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        return i
    }

    /// Applies a transition at a cut (`outgoing` and `incoming` touching) or to one clip edge (the other side nil). A transition
    /// already at that place is replaced. The duration is snapped to whole frames and clamped to the handles; when no frame
    /// fits, `insufficientMedia`. Returns the new transition's ID.
    @discardableResult
    public mutating func addTransition(kind: TransitionKind, track trackID: Track.ID, outgoing: Clip.ID?, incoming: Clip.ID?,
                                       duration: Time, alignment: TransitionAlignment = .center,
                                       customBefore: Time = .zero) throws -> Transition.ID {
        let ti = try trackIndex(trackID)
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        guard kind.trackKind == tracks[ti].kind else { throw EditError.wrongTrackKind }
        guard outgoing != nil || incoming != nil else { throw EditError.clipNotFound }
        if kind.isStinger, outgoing == nil || incoming == nil { throw EditError.notACut }
        // An element transition animates one clip at one edge: never across a cut (`.head` / `.tail` of a clip instead).
        if kind.isElement, outgoing != nil, incoming != nil { throw EditError.notACut }
        for id in [outgoing, incoming].compactMap({ $0 }) where tracks[ti].clip(id) == nil { throw EditError.clipNotFound }
        if let o = outgoing, let i = incoming {
            guard let oc = tracks[ti].clip(o), let ic = tracks[ti].clip(i), oc.timeline.end == ic.start else { throw EditError.notACut }
        }
        let fd = format.frameDuration
        var tr = Transition(kind: kind, duration: snapped(duration), alignment: alignment,
                            customBefore: fd * max(0, customBefore.frameIndex(frameDuration: fd)), outgoing: outgoing, incoming: incoming)
        tr.alignment = tracks[ti].appliedAlignment(for: tr, frameDuration: fd)
        let fit = tracks[ti].maxTransitionFrames(tr, frameDuration: fd)
        guard fit >= 1 else { throw EditError.insufficientMedia }
        // A stinger keeps its length (its clip's own); clips shorter than its parts trim it when it resolves.
        if !kind.isStinger { tr.duration = min(tr.duration, fd * fit) }
        // One transition per clip edge and class (Premiere): a new one replaces what already sits on the same edge(s). An
        // element transition (Move / Zoom / Pop) needs no second picture, so it sits next to a cut transition there.
        tracks[ti].removeTransitions(sharingEdgesWith: tr)
        tracks[ti].transitions.append(tr)
        return tr.id
    }

    @discardableResult
    public mutating func addTransition(point: TransitionPoint, kind: TransitionKind, track: Track.ID, duration: Time,
                                       alignment: TransitionAlignment = .center) throws -> Transition.ID {
        switch point {
        case let .cut(o, i): try addTransition(kind: kind, track: track, outgoing: o, incoming: i, duration: duration, alignment: alignment)
        case let .head(c): try addTransition(kind: kind, track: track, outgoing: nil, incoming: c, duration: duration, alignment: alignment)
        case let .tail(c): try addTransition(kind: kind, track: track, outgoing: c, incoming: nil, duration: duration, alignment: alignment)
        }
    }

    /// Changes a transition's properties. The duration is snapped to whole frames and clamped to the handles. A change of
    /// alignment keeps the duration as far as the handles allow.
    public mutating func setTransition(_ id: Transition.ID, kind: TransitionKind? = nil, duration: Time? = nil,
                                       alignment: TransitionAlignment? = nil, customBefore: Time? = nil,
                                       easing: EasingCurve? = nil, direction: TransitionDirection? = nil,
                                       softness: Double? = nil, motionBlur: Double? = nil, color: [UInt8]? = nil,
                                       reversed: Bool? = nil, borderWidth: Double? = nil,
                                       borderColor: [UInt8]? = nil) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }),
              let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        let fd = format.frameDuration
        var tr = tracks[ti].transitions[ni]
        if let kind {
            guard kind.trackKind == tracks[ti].kind else { throw EditError.wrongTrackKind }
            if kind.isStinger, tr.isSingleSided { throw EditError.notACut }
            if kind.isElement, !tr.isSingleSided { throw EditError.notACut }
            // Keys mean different things per kind (Zoom's and Pop's "from"): a new kind starts from its defaults.
            if kind != tr.kind { tr.params = nil }
            tr.kind = kind
        }
        if let color, color.count == 3 { tr.color = color }
        // Border width 0 clears it (nil = off, identical to a file that never had one).
        if let borderWidth { tr.borderWidth = borderWidth > 0 ? min(borderWidth, TransitionKind.maxBorderWidth) : nil }
        if let borderColor, borderColor.count == 3 { tr.borderColor = borderColor }
        if let easing { tr.easing = easing }
        if let direction { tr.direction = direction }
        if let reversed { tr.reversed = reversed ? true : nil }
        if let softness { tr.softness = min(max(softness, 0), 0.5) }
        if let motionBlur { tr.motionBlur = min(max(motionBlur, 0), 4) }
        // An element transition blurs through its clip's Shutter Angle, which stops at 360 degrees (one frame).
        if tr.kind.isElement, let mb = tr.motionBlur { tr.motionBlur = min(mb, 1) }
        if let alignment { tr.alignment = alignment }
        if let customBefore { tr.customBefore = fd * max(0, customBefore.frameIndex(frameDuration: fd)) }
        if let duration { tr.duration = snapped(duration) }
        let fit = tracks[ti].maxTransitionFrames(tr, frameDuration: fd)
        if fit >= 1, !tr.kind.isStinger { tr.duration = min(tr.duration, fd * fit) }
        let classChanged = tr.kind.isElement != tracks[ti].transitions[ni].kind.isElement
        tracks[ti].transitions[ni] = tr
        if classChanged { tracks[ti].removeTransitions(sharingEdgesWith: tr) }
    }

    /// N6b: picks the clip a cut transition plays as a Stinger (nil = none: a plain cut). A clip makes the transition a
    /// Stinger. The duration is left alone (`Project.setStinger` also sets it to the clip's length).
    public mutating func setStinger(_ id: Transition.ID, _ stinger: TransitionStinger?) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }),
              let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        guard tracks[ti].kind == .video else { throw EditError.wrongTrackKind }
        var tr = tracks[ti].transitions[ni]
        if stinger != nil {
            guard !tr.isSingleSided else { throw EditError.notACut }
            tr.kind = .stinger
        }
        tr.stinger = stinger
        tracks[ti].transitions[ni] = tr
    }

    public mutating func removeTransition(_ id: Transition.ID) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        tracks[ti].transitions.removeAll { $0.id == id }
    }

    /// Drops transitions whose cut is gone or whose handles hold no frame any more. `Project.edit` calls this after every edit.
    public mutating func pruneTransitions() {
        let fd = format.frameDuration
        for i in tracks.indices { tracks[i].pruneTransitions(frameDuration: fd) }
    }
}
