import Foundation

// Temporal effects: Video Denoise and Deflicker read the clip's neighboring decoded source frames; Motion Blur smears the
// clip's own motion (Motion, transform stages, keys) over a shutter window. Kinds and keys are stored strings: never rename.
//
// Frame history seam (one rule for playback, scrub and export): a layer whose `ClipEffects.temporal` is set asks for the source
// frames `TemporalWindow.neighbors` names (sample indices either side of the shown frame, inside the clip's source range,
// nearest first). Playback takes them from its byte-capped frame cache (misses are decoded like any other; while playing the
// filter is `degraded(.fast)`, a settled frame waits for the exact window), export keeps them in a `FrameHistory` bounded to
// the window. The renderer works with whatever subset arrived (`TemporalFilter.clamped(before:after:)`).

extension ClipEffect {
    public static let videoDenoiseKind = "videoDenoise"
    public static let deflickerKind = "deflicker"
    public static let motionBlurKind = "motionBlurFX"

    public static let framesEachSideKey = "framesEachSide"
    public static let qualityKey = "quality"
    public static let motionSearchKey = "motionSearch"
    public static let lumaStrengthKey = "lumaStrength", colorStrengthKey = "colorStrength"
    public static let motionLimitKey = "motionLimit"
    public static let detailSizeKey = "detailSize"
    public static let spatialLumaKey = "spatialLuma", spatialColorKey = "spatialColor"
    public static let keepOriginalKey = "keepOriginal"
    public static let analysisKey = "analysis", strengthKey = "strength"
    public static let blurDirectionModeKey = "blurSide", smoothnessKey = "smoothness"
    /// C4 Trails (v64): earlier source frames laid over the shown one, each weaker than the one before.
    public static let trailsKind = "trails"
    public static let trailCountKey = "trailCount", trailSpacingKey = "trailSpacing", trailDecayKey = "trailDecay"
    public static let trailBlendKey = "trailBlend"
}

/// How exact the temporal work must be. Export and a settled (paused) frame are `.exact`; playing and scrubbing are `.fast`.
public enum TemporalQuality: Sendable, Hashable { case exact, fast }

/// Evaluated Video Denoise + Deflicker of one layer at one instant (sibling of `FilmLook` inside `ClipEffects`). The renderer
/// runs it on the decoded source frame before the color pipeline and every other effect.
public struct TemporalFilter: Sendable, Hashable {
    /// Video Denoise: temporal average of the neighboring frames (motion-rejected), then a spatial edge-keeping smooth.
    public struct Denoise: Sendable, Hashable {
        /// Source frames used on each side of the shown one, 0...5.
        public var framesEachSide: Int
        /// false = Fast (single-pixel difference), true = Best (patch difference, motion search).
        public var best: Bool
        /// Motion search radius step: 0 = small (none), 1 = medium, 2 = large. Only with `best`.
        public var motionSearch: Int
        /// Temporal strength 0...1 for luma and color (higher = more averaging across differences).
        public var luma: Double, color: Double
        /// 0...1: differences above the limit count as motion and are left alone (higher = more tolerant).
        public var motionLimit: Double
        /// Spatial pass size: 0 = off, 1 small, 2 medium, 3 large.
        public var detailSize: Int
        /// Spatial strength 0...1 for luma and color.
        public var spatialLuma: Double, spatialColor: Double
        /// 0...1 share of the original frame mixed back in (keeps texture).
        public var keepOriginal: Double
        public init(framesEachSide: Int, best: Bool = false, motionSearch: Int = 1, luma: Double = 0.4, color: Double = 0.5,
                    motionLimit: Double = 0.5, detailSize: Int = 0, spatialLuma: Double = 0, spatialColor: Double = 0,
                    keepOriginal: Double = 0) {
            self.framesEachSide = framesEachSide; self.best = best; self.motionSearch = motionSearch
            self.luma = luma; self.color = color; self.motionLimit = motionLimit; self.detailSize = detailSize
            self.spatialLuma = spatialLuma; self.spatialColor = spatialColor; self.keepOriginal = keepOriginal
        }
        /// The temporal part does something.
        public var isTemporal: Bool { framesEachSide > 0 && (luma > 0 || color > 0) }
        /// The spatial part does something.
        public var isSpatial: Bool { detailSize > 0 && (spatialLuma > 0 || spatialColor > 0) }
    }
    /// Deflicker: each frame's brightness is scaled to the average brightness of the window around it.
    public struct Deflicker: Sendable, Hashable {
        /// Frames averaged on each side of the shown one, 1...10.
        public var framesEachSide: Int
        /// false = Fast (one gain for the whole frame), true = Best (a gain per region, regions that change too much
        /// between frames, i.e. motion, are not corrected).
        public var local: Bool
        /// 0...1 how much of the correction is applied.
        public var strength: Double
        public init(framesEachSide: Int, local: Bool = false, strength: Double = 1) {
            self.framesEachSide = framesEachSide; self.local = local; self.strength = strength
        }
    }

    /// Trails (C4): `count` earlier source frames, `spacing` frames apart, laid over the shown one; echo k (1 = nearest)
    /// has weight (1 - decay)^k. Runs after Denoise / Deflicker on the same decoded frames, before the color pipeline.
    public struct Trails: Sendable, Hashable {
        /// How an echo meets the picture: Add (sums, brightens), Screen (brightens softly), Lighten (the brighter one wins).
        public enum Blend: Int, Sendable, Hashable, CaseIterable { case add = 0, screen = 1, lighten = 2 }
        public static let countRange = 2...8, spacingRange = 1...3
        /// The furthest frame back a trail reads (8 echoes x 3 frames): bounds the history export keeps.
        public static let maxReach = countRange.upperBound * spacingRange.upperBound
        public var count: Int
        public var spacing: Int
        /// 0...1: share each echo loses against the one before it.
        public var decay: Double
        public var blend: Blend
        /// The clip plays its source backwards here (reverse, or a reversed speed segment): the frames already seen lie
        /// ahead in source order, so the echoes are read from there. Set by `Clip.effects(at:)`.
        public var backward = false
        /// Clamps every value to its range.
        public init(count: Int, spacing: Int, decay: Double, blend: Blend) {
            self.count = min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound)
            self.spacing = min(max(spacing, Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
            self.decay = decay.isNaN ? 0 : min(max(decay, 0), 1)
            self.blend = blend
        }
        /// Frames back of each echo, nearest first.
        public var offsets: [Int] { (1...count).map { $0 * spacing } }
        /// Weight of each echo, nearest first.
        public var weights: [Double] {
            var w = 1.0
            return (1...count).map { _ in w *= 1 - decay; return w }
        }
        /// Furthest frame back.
        public var reach: Int { count * spacing }
    }

    public var denoise: Denoise?
    public var deflicker: Deflicker?
    public var trails: Trails?
    public init(denoise: Denoise? = nil, deflicker: Deflicker? = nil, trails: Trails? = nil) {
        self.denoise = denoise; self.deflicker = deflicker; self.trails = trails
    }

    /// Nothing to do.
    public var isIdentity: Bool { denoise == nil && deflicker == nil && trails == nil }

    /// Source frames Denoise / Deflicker need on each side of the shown one.
    public var radius: Int {
        max(denoise.map { $0.isTemporal ? $0.framesEachSide : 0 } ?? 0, deflicker?.framesEachSide ?? 0)
    }
    /// Source frames needed before the shown one (Trails look back, or ahead when `backward`).
    public var reachBack: Int { max(radius, trails.map { $0.backward ? 0 : $0.reach } ?? 0) }
    /// Source frames needed after the shown one.
    public var reachAhead: Int { max(radius, trails.map { $0.backward ? $0.reach : 0 } ?? 0) }

    /// Fast mode (playback, scrub): denoise at most 1 frame each side, Fast quality, no motion search; deflicker at most 2
    /// frames each side, whole-frame gain. The spatial pass and the strengths stay (they cost little and keep the look).
    /// Trails stay as they are: they are the look, and cost one texture read per echo.
    public static let fastDenoiseFrames = 1, fastDeflickerFrames = 2

    public func degraded(_ q: TemporalQuality) -> TemporalFilter {
        guard q == .fast else { return self }
        var f = self
        if var d = f.denoise {
            d.framesEachSide = min(d.framesEachSide, Self.fastDenoiseFrames)
            d.best = false; d.motionSearch = 0
            f.denoise = d
        }
        if var d = f.deflicker {
            d.framesEachSide = min(d.framesEachSide, Self.fastDeflickerFrames)
            d.local = false
            f.deflicker = d
        }
        return f
    }
}

/// Which source frames a temporal filter reads around the shown one.
public enum TemporalWindow {
    /// Sample indices on each side of `center`, nearest first, at most `radius` each, limited to `lower...upper` (the clip's
    /// first and last source frame, so a neighbor never comes from material cut away, which may be another shot).
    public static func neighbours(center: Int, radius: Int, lower: Int, upper: Int) -> (before: [Int], after: [Int]) {
        neighbours(center: center, before: radius, after: radius, lower: lower, upper: upper)
    }

    /// As above with separate reaches (`TemporalFilter.reachBack` / `reachAhead`).
    public static func neighbours(center: Int, before b: Int, after a: Int, lower: Int, upper: Int) -> (before: [Int], after: [Int]) {
        guard center >= lower, center <= upper else { return ([], []) }
        let before = b > 0 ? (1...b).map { center - $0 }.filter { $0 >= lower } : []
        let after = a > 0 ? (1...a).map { center + $0 }.filter { $0 <= upper } : []
        return (before, after)
    }

    /// All indices of the window, oldest first (what a history must hold for `center`).
    public static func span(center: Int, radius: Int, lower: Int, upper: Int) -> ClosedRange<Int> {
        span(center: center, before: radius, after: radius, lower: lower, upper: upper)
    }

    public static func span(center: Int, before b: Int, after a: Int, lower: Int, upper: Int) -> ClosedRange<Int> {
        let n = neighbours(center: center, before: b, after: a, lower: lower, upper: upper)
        return (n.before.last ?? center)...(n.after.last ?? center)
    }
}

/// Bounded store of decoded frames for temporal effects (export). Keyed by media and sample index; `keep(_:)` drops
/// everything outside the windows still needed, so it never holds more than the sum of the windows (at most 2 x 10 + 1
/// frames per window).
public struct FrameHistory<Frame> {
    public struct Key: Hashable, Sendable { public var media: UUID; public var index: Int
        public init(media: UUID, index: Int) { self.media = media; self.index = index } }
    private var frames: [Key: Frame] = [:]
    public init() {}
    public var count: Int { frames.count }
    public subscript(media: UUID, index: Int) -> Frame? {
        get { frames[Key(media: media, index: index)] }
        set { frames[Key(media: media, index: index)] = newValue }
    }
    /// Keeps only frames inside one of `windows` (per media); everything else is released.
    public mutating func keep(_ windows: [UUID: [ClosedRange<Int>]]) {
        frames = frames.filter { k, _ in windows[k.media]?.contains { $0.contains(k.index) } ?? false }
    }
}

extension FrameHistory: Sendable where Frame: Sendable {}

/// Motion Blur effect settings (the shutter window of the clip's own motion).
public struct MotionBlurShutter: Sendable, Hashable {
    public enum Side: Int, Sendable, Hashable, CaseIterable { case both = 0, fromPrevious = 1, towardNext = 2 }
    /// Shutter angle in degrees, 0...360 (Amount 100 = 360).
    public var angle: Double
    public var side: Side
    /// Sample count factor: 0 coarse (half), 1 medium, 2 fine (double).
    public var smoothness: Int
    public init(angle: Double, side: Side = .both, smoothness: Int = 1) { self.angle = angle; self.side = side; self.smoothness = smoothness }

    /// Sub-frame samples: the shutter's own count scaled by the smoothness, 2...32.
    public var sampleCount: Int {
        let n = EffectTransformStage.sampleCount(shutterAngle: angle)
        guard n > 0 else { return 0 }
        switch smoothness {
        case 0: return max(2, (n + 1) / 2)
        case 2: return min(32, n * 2)
        default: return n
        }
    }

    /// The shutter of an enabled Motion Blur effect at clip-local `t` (nil = none or amount 0); the last one wins.
    static func of(_ effects: [ClipEffect], atLocal t: Time) -> MotionBlurShutter? {
        guard let e = effects.last(where: { $0.enabled && $0.kind == ClipEffect.motionBlurKind }) else { return nil }
        let amount = e.scalar(ClipEffect.amountKey, atLocal: t)
        guard amount > 0 else { return nil }
        return MotionBlurShutter(angle: min(amount, 100) * 3.6,
                                 side: Side(rawValue: e.choice(ClipEffect.blurDirectionModeKey, atLocal: t)) ?? .both,
                                 smoothness: e.choice(ClipEffect.smoothnessKey, atLocal: t))
    }
}

extension MotionBlurSamples {
    /// At most `maxCount` samples, spread evenly over the same window (first and last kept). Playback uses this while playing;
    /// paused frames and export keep every sample.
    public func thinned(to maxCount: Int) -> MotionBlurSamples {
        let n = transforms.count
        guard maxCount >= 2, n > maxCount else { return self }
        var out: [ClipTransform] = []
        out.reserveCapacity(maxCount)
        for k in 0..<maxCount { out.append(transforms[(k * (n - 1) + (maxCount - 1) / 2) / (maxCount - 1)]) }
        out[0] = transforms[0]; out[maxCount - 1] = transforms[n - 1]
        return MotionBlurSamples(format: format, transforms: out)
    }
    /// Samples kept while playing (`thinned(to:)`).
    public static let playbackMaxSamples = 8
}

extension EffectCatalog {
    /// Video Denoise, Deflicker, Motion Blur. Defaults chosen (the design notes "Temporal effects").
    static let temporal: [EffectSpec] = {
        func p(_ key: String, _ title: String, _ unit: String, _ def: Double, _ range: ClosedRange<Double>,
               step: Double = 1, decimals: Int = 0) -> EffectParamSpec {
            EffectParamSpec(key: key, title: title, unit: unit, defaultValue: def, range: range, step: step, decimals: decimals)
        }
        return [
            EffectSpec(kind: ClipEffect.videoDenoiseKind, title: "Video Denoise", params: [
                p(ClipEffect.framesEachSideKey, "Frames Each Side", "", 2, 0...5),
                .choice(ClipEffect.qualityKey, "Quality", ["Fast", "Best"]),
                .choice(ClipEffect.motionSearchKey, "Motion Search", ["Small", "Medium", "Large"], default: 1),
                p(ClipEffect.lumaStrengthKey, "Luma Strength", "%", 40, 0...100),
                p(ClipEffect.colorStrengthKey, "Color Strength", "%", 50, 0...100),
                p(ClipEffect.motionLimitKey, "Motion Limit", "%", 50, 0...100),
                .choice(ClipEffect.detailSizeKey, "Spatial Size", ["Off", "Small", "Medium", "Large"], default: 1),
                p(ClipEffect.spatialLumaKey, "Spatial Luma", "%", 0, 0...100),
                p(ClipEffect.spatialColorKey, "Spatial Color", "%", 20, 0...100),
                p(ClipEffect.keepOriginalKey, "Keep Original", "%", 0, 0...100),
            ]),
            EffectSpec(kind: ClipEffect.deflickerKind, title: "Deflicker", params: [
                p(ClipEffect.framesEachSideKey, "Frames Each Side", "", 3, 1...10),
                .choice(ClipEffect.analysisKey, "Motion Analysis", ["Fast", "Best"]),
                p(ClipEffect.strengthKey, "Strength", "%", 100, 0...100),
            ]),
            EffectSpec(kind: ClipEffect.motionBlurKind, title: "Motion Blur", params: [
                p(ClipEffect.amountKey, "Amount", "", 50, 0...100),
                .choice(ClipEffect.blurDirectionModeKey, "Direction", ["Both Sides", "From Previous", "Toward Next"]),
                .choice(ClipEffect.smoothnessKey, "Smoothness", ["Coarse", "Medium", "Fine"], default: 1),
            ]),
            // C4 Trails: Echoes earlier frames, Spacing frames apart; each one Decay % weaker than the one before.
            EffectSpec(kind: ClipEffect.trailsKind, title: "Trails", params: [
                p(ClipEffect.trailCountKey, "Echoes", "", 4, 2...8),
                p(ClipEffect.trailSpacingKey, "Spacing", "frames", 2, 1...3),
                p(ClipEffect.trailDecayKey, "Decay", "%", 40, 0...100),
                .choice(ClipEffect.trailBlendKey, "Blend", ["Add", "Screen", "Lighten"], default: 1),
            ]),
        ]
    }()
}

extension ClipEffect {
    /// This effect's part of the temporal filter at clip-local `t` (Video Denoise / Deflicker), nil when it does nothing.
    func applyTemporal(to f: inout TemporalFilter, atLocal t: Time) {
        func v(_ key: String) -> Double { scalar(key, atLocal: t) }
        switch kind {
        case Self.videoDenoiseKind:
            let d = TemporalFilter.Denoise(
                framesEachSide: Int(v(Self.framesEachSideKey).rounded()), best: choice(Self.qualityKey, atLocal: t) == 1,
                motionSearch: choice(Self.motionSearchKey, atLocal: t),
                luma: v(Self.lumaStrengthKey) / 100, color: v(Self.colorStrengthKey) / 100, motionLimit: v(Self.motionLimitKey) / 100,
                detailSize: choice(Self.detailSizeKey, atLocal: t),
                spatialLuma: v(Self.spatialLumaKey) / 100, spatialColor: v(Self.spatialColorKey) / 100,
                keepOriginal: v(Self.keepOriginalKey) / 100)
            f.denoise = (d.isTemporal || d.isSpatial) && d.keepOriginal < 1 ? d : nil
        case Self.deflickerKind:
            let s = v(Self.strengthKey) / 100
            f.deflicker = s > 0 ? .init(framesEachSide: Int(v(Self.framesEachSideKey).rounded()),
                                        local: choice(Self.analysisKey, atLocal: t) == 1, strength: s) : nil
        case Self.trailsKind:
            let blend = min(max(Int(v(Self.trailBlendKey).rounded()), 0), TemporalFilter.Trails.Blend.allCases.count - 1)
            let tr = TemporalFilter.Trails(count: Int(v(Self.trailCountKey).rounded()), spacing: Int(v(Self.trailSpacingKey).rounded()),
                                           decay: v(Self.trailDecayKey) / 100, blend: TemporalFilter.Trails.Blend(rawValue: blend) ?? .screen)
            f.trails = tr.decay < 1 ? tr : nil
        default: break
        }
    }

    /// Video Denoise, Deflicker, Trails or Motion Blur (handled outside the segment chain).
    var isTemporalKind: Bool {
        kind == Self.videoDenoiseKind || kind == Self.deflickerKind || kind == Self.trailsKind || kind == Self.motionBlurKind
    }
}
