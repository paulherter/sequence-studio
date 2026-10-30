import Foundation

// W9.7 Stabilizer (pure maths). Picture analysis (SQAnalysis, Vision) measures how each frame's content moved against the
// previous one (`CameraMotion`). Here those motions become the camera path (`CameraPose` per frame: where a point of the
// first frame sits in frame k), the path is smoothed (Smooth) or replaced by one fixed pose (Locked), and each frame gets
// the correction that moves its content from the real path onto the wanted one, scaled up just enough that the picture
// still covers its own frame (auto scale; Smooth keeps that crop under `maxCrop` by giving up correction where needed).
// The corrections are written as keys of a `stabilize` effect, a transform stage (EffectTransformStage.swift): the
// compositor applies it to the clip's own frame before Motion. Kind and keys are ordinary effect data; ProjectFile v36 gates the kind.
//
// Units: px of the upright source picture, offset from the picture center, y down; degrees clockwise on screen (the
// rotation convention of `StageTransform`).

/// A similarity pose: p -> e^logScale R(rotation) p + translation.
public struct CameraPose: Sendable, Hashable, Codable {
    public var translation: Vec2
    /// Degrees, clockwise on screen.
    public var rotation: Double
    public var logScale: Double
    public init(translation: Vec2 = .zero, rotation: Double = 0, logScale: Double = 0) {
        self.translation = translation; self.rotation = rotation; self.logScale = logScale
    }
    public static let identity = CameraPose()

    var scale: Double { exp(logScale) }
    var linear: Affine2 { Affine2.rotScale(rotation, scale, scale) }
    public func apply(_ p: Vec2) -> Vec2 { linear.linear(p) + translation }
    /// self after `o`: p -> self(o(p)). Rotations add (no wrapping), so a path stays continuous.
    func after(_ o: CameraPose) -> CameraPose {
        CameraPose(translation: apply(o.translation), rotation: rotation + o.rotation, logScale: logScale + o.logScale)
    }
    var inverse: CameraPose {
        let inv = CameraPose(rotation: -rotation, logScale: -logScale)
        return CameraPose(translation: inv.apply(translation) * -1, rotation: -rotation, logScale: -logScale)
    }
    static func lerp(_ a: CameraPose, _ b: CameraPose, _ f: Double) -> CameraPose {
        CameraPose(translation: Vec2.lerp(a.translation, b.translation, f), rotation: a.rotation + (b.rotation - a.rotation) * f,
                   logScale: a.logScale + (b.logScale - a.logScale) * f)
    }
}

/// How the content moved from one analyzed frame to the next: p_k = scale R(rotation) p_{k-1} + (dx, dy).
public struct CameraMotion: Sendable, Hashable, Codable {
    public var dx: Double, dy: Double
    /// Degrees, clockwise on screen.
    public var rotation: Double
    public var scale: Double
    public init(dx: Double = 0, dy: Double = 0, rotation: Double = 0, scale: Double = 1) {
        self.dx = dx; self.dy = dy; self.rotation = rotation; self.scale = scale
    }
    public static let identity = CameraMotion()

    /// The motion that takes content at pose `a` to pose `b` (b after a^-1).
    public init(from a: CameraPose, to b: CameraPose) {
        let m = b.after(a.inverse)
        self.init(dx: m.translation.x, dy: m.translation.y, rotation: m.rotation, scale: m.scale)
    }

    public var pose: CameraPose {
        CameraPose(translation: Vec2(dx, dy), rotation: rotation.isFinite ? rotation : 0,
                   logScale: scale.isFinite && scale > 0 ? log(scale) : 0)
    }
}

/// The result of analyzing one source range (cached per media file and range by SQAnalysis).
public struct StabilizationAnalysis: Sendable, Hashable, Codable {
    /// Bumped when the analysis changes so cached results are measured again.
    /// 3: per-frame confidence, independent check motions, cut detection beyond "no match" (W9.7 2a/2b).
    /// 4: cuts only where the two registrations do not agree (W9.7 2c).
    /// 5: camera motion and check in picture pixels on both axes for non-square pixels (anamorphic).
    /// 6: motions from tracked features at 720 px, every frame (stabilizer rebuild); confidence from the inlier ratio.
    /// 7: per-pair planar homography by RANSAC reduced to the camera similarity (similarity fit kept as the fallback).
    /// 8: the residual perspective of each pair's homography (`perspective`) is kept next to the camera similarity.
    public static let currentVersion = 8
    public var version: Int
    /// Upright source picture size (the clip's own frame), px.
    public var pictureWidth: Int, pictureHeight: Int
    /// Source time of every analyzed frame, ascending.
    public var frameTimes: [Time]
    /// `motions[i]`: frame i-1 to frame i (`motions[0]` is the identity).
    public var motions: [CameraMotion]
    /// Frame indices where the picture could not be matched to the previous frame (a scene cut, a black frame): the camera
    /// path restarts there, so smoothing never runs across it (`motions[i]` of a cut is ignored). Ascending, > 0.
    public var cuts: [Int]
    /// How far `motions[i]` can be trusted, 0...1 (texture, agreement with the independent check). Empty = all trusted.
    /// Below `Stabilizer.minConfidence` the plan replaces the motion by its trusted neighbors (no correction of noise).
    public var confidence: [Double]
    /// `checks[i]`: frame i-1 to frame i measured by a second, independent registration (photometric, SQAnalysis), nil
    /// where it could not measure. The plan's guard compares the shake before and after the correction with these and
    /// leaves a segment uncorrected when the correction would make it shakier. Empty = no guard.
    public var checks: [CameraMotion?]
    /// `rolling[i]`: shift and scan-axis slope of frame i-1 to frame i for the rolling shutter option (RollingShutter.swift),
    /// nil where it could not be measured. Empty = an analysis from before the option (it is measured again when needed).
    public var rolling: [RollingShutterSample?]
    /// How the sensor's rows lie in the upright picture, as the quarter turns the stored picture was rotated by:
    /// 0 rows read top to bottom, 1 right to left, 2 bottom to top, 3 left to right.
    public var rollingScan: Int
    public var rollingScansAlongX: Bool { rollingScan % 2 != 0 }
    /// Seconds between two frames of the source as the analyzer received them (60 fps: 1/60), 0 = not known. The
    /// analyzer skips frames closer than 24 ms, so `frameTimes` can be coarser; a sensor cannot read longer than this.
    public var sourceFrameInterval: Double
    /// `perspective[i]`: what the homography of frame i-1 to frame i holds beyond `motions[i]` (the similarity), in picture
    /// px (Stabilizer+Perspective). Empty = no pair had any (similarity fits only).
    public var perspective: [PerspectiveResidual]

    public init(version: Int = StabilizationAnalysis.currentVersion, pictureWidth: Int, pictureHeight: Int,
                frameTimes: [Time], motions: [CameraMotion], cuts: [Int] = [], confidence: [Double] = [],
                checks: [CameraMotion?] = [], rolling: [RollingShutterSample?] = [], rollingScan: Int = 0,
                sourceFrameInterval: Double = 0, perspective: [PerspectiveResidual] = []) {
        self.perspective = perspective
        self.version = version; self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight
        self.frameTimes = frameTimes; self.motions = motions; self.cuts = cuts
        self.confidence = confidence; self.checks = checks
        self.rolling = rolling; self.rollingScan = ((rollingScan % 4) + 4) % 4
        self.sourceFrameInterval = sourceFrameInterval.isFinite && sourceFrameInterval > 0 ? sourceFrameInterval : 0
    }

    /// Confidence of `motions[i]` (1 when not measured): the stored one, raised to how well the independent check agrees
    /// with the motion (`checkAgreement`). Two independent registrations that agree are not noise, whatever the inlier
    /// ratio says: a selfie's large face takes half the tracked points as outliers (feature confidence below
    /// `Stabilizer.minConfidence` on scattered frames), and dropping those frames' motion left half the shake in.
    public func confidence(at i: Int) -> Double {
        let stored = storedConfidence(at: i)
        return stored >= 1 ? stored : max(stored, checkAgreement(at: i))
    }

    /// The feature confidence of `motions[i]` as measured (1 when not measured), without the check's vote. For what the
    /// check does not see: it registers a similarity, so it vouches for `motions[i]`, never for `perspective[i]`.
    public func storedConfidence(at i: Int) -> Double { i >= 0 && i < confidence.count ? confidence[i] : 1 }

    /// 0...1: how well `checks[i]` agrees with `motions[i]` (0 without a check). RMS difference of the two at the four
    /// half-way-to-the-corner points, px per 512 px of the long side: 1 within `Stabilizer.fullAgreement`, 0 from
    /// `Stabilizer.fullDisagreement`.
    public func checkAgreement(at i: Int) -> Double {
        guard i >= 0, i < checks.count, i < motions.count, let c = checks[i] else { return 0 }
        let w = Double(pictureWidth), h = Double(pictureHeight)
        guard w > 0, h > 0 else { return 0 }
        let a = motions[i].pose, b = c.pose
        var s = 0.0
        for q in [Vec2(-w / 4, -h / 4), Vec2(w / 4, -h / 4), Vec2(w / 4, h / 4), Vec2(-w / 4, h / 4)] {
            let d = a.apply(q) - b.apply(q)
            s += d.x * d.x + d.y * d.y
        }
        let d = (s / 4).squareRoot() * 512 / max(w, h)
        guard d.isFinite else { return 0 }
        return min(max((Stabilizer.fullDisagreement - d) / (Stabilizer.fullDisagreement - Stabilizer.fullAgreement), 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case version, pictureWidth, pictureHeight, frameTimes, motions, cuts, confidence, checks, rolling, rollingScan
        case sourceFrameInterval, perspective
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version), pictureWidth: try c.decode(Int.self, forKey: .pictureWidth),
                  pictureHeight: try c.decode(Int.self, forKey: .pictureHeight), frameTimes: try c.decode([Time].self, forKey: .frameTimes),
                  motions: try c.decode([CameraMotion].self, forKey: .motions),
                  cuts: try c.decodeIfPresent([Int].self, forKey: .cuts) ?? [],
                  confidence: try c.decodeIfPresent([Double].self, forKey: .confidence) ?? [],
                  checks: try c.decodeIfPresent([CameraMotion?].self, forKey: .checks) ?? [],
                  rolling: try c.decodeIfPresent([RollingShutterSample?].self, forKey: .rolling) ?? [],
                  rollingScan: try c.decodeIfPresent(Int.self, forKey: .rollingScan) ?? 0,
                  sourceFrameInterval: try c.decodeIfPresent(Double.self, forKey: .sourceFrameInterval) ?? 0,
                  perspective: try c.decodeIfPresent([PerspectiveResidual].self, forKey: .perspective) ?? [])
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(pictureWidth, forKey: .pictureWidth)
        try c.encode(pictureHeight, forKey: .pictureHeight); try c.encode(frameTimes, forKey: .frameTimes)
        try c.encode(motions, forKey: .motions)
        if !cuts.isEmpty { try c.encode(cuts, forKey: .cuts) }
        if !confidence.isEmpty { try c.encode(confidence, forKey: .confidence) }
        if !checks.isEmpty { try c.encode(checks, forKey: .checks) }
        if !rolling.isEmpty { try c.encode(rolling, forKey: .rolling) }
        if rollingScan != 0 { try c.encode(rollingScan, forKey: .rollingScan) }
        if sourceFrameInterval > 0 { try c.encode(sourceFrameInterval, forKey: .sourceFrameInterval) }
        if !perspective.isEmpty { try c.encode(perspective, forKey: .perspective) }
    }

    /// The analyzed frame nearest to source time `t` (ties to the later one); 0 when there are none.
    public func index(nearest t: Time) -> Int {
        guard !frameTimes.isEmpty else { return 0 }
        var lo = 0, hi = frameTimes.count       // first index with frameTimes[i] >= t
        while lo < hi {
            let mid = (lo + hi) / 2
            if frameTimes[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return 0 }
        if lo == frameTimes.count { return frameTimes.count - 1 }
        let before = t - frameTimes[lo - 1], after = frameTimes[lo] - t
        return after <= before ? lo : lo - 1
    }

    var seconds: Double {
        guard let a = frameTimes.first, let b = frameTimes.last else { return 0 }
        let d = b - a
        return Double(d.value) / Double(d.timescale)
    }
}

public enum StabilizerMode: Int, Sendable, Hashable, CaseIterable {
    /// Keeps the camera's intended movement, removes the shake.
    case smooth = 0
    /// Holds the first framing still, as on a tripod.
    case locked = 1
    /// Holds the framing when the shot is a still one (shake only, no intended movement), else keeps the movement.
    case auto = 2
}

/// What fills the border the Crop Limit leaves uncovered (stored as the index of the Edge Fill choice; never reorder).
public enum StabilizerEdgeFill: Int, Sendable, Hashable, CaseIterable {
    /// The planned zoom hides the border (up to the Crop Limit): the clip transform, as before the option existed.
    case zoom = 0
    /// The picture is mirrored back over its own edge.
    case mirror = 1
    /// The mirrored picture, blurred wide where it reaches past the edge.
    case blur = 2

    public var title: String {
        switch self { case .zoom: "Zoom"; case .mirror: "Mirror Edge"; case .blur: "Blur Edge" }
    }
}

public struct StabilizerOptions: Sendable, Hashable {
    /// Which engine (StabilizeEffect.swift). The plan below is the Standard one; a Gyroflow Stabilizer is never planned here.
    public var method: StabilizerMethod = .standard
    public var mode: StabilizerMode = .smooth
    /// Smooth: how long a wobble is still removed (Gaussian sigma), seconds.
    public var smoothness: Double = 0.5
    /// How much of the correction is applied, 0...1 (1 = all; the correction pose is blended with no correction).
    public var strength: Double = 1
    /// Smooth: most of each picture side the auto scale may cut away (0.08 = scale at most 1 / 0.92).
    public var maxCrop: Double = 0.08
    /// What fills the border the crop limit leaves open. Mirror and Blur lower the plan's zoom (`Stabilizer.edgeFillTolerance`), so it is part of the plan.
    public var edgeFill: StabilizerEdgeFill = .zoom
    /// Locked: the same cap; a shot that would need more shows its edges on the frames that do.
    public var maxLockedCrop: Double = 0.3
    /// The guard keeps a segment's correction only below this checked shake ratio (after / before). Not stored on the
    /// effect; `.infinity` turns the guard off (diagnostics).
    public var guardLimit: Double = Stabilizer.guardRatio
    /// Straighten the lean a rolling sensor adds while the camera moves (RollingShutter.swift), and how much of the
    /// measured shear is taken out, % (100 = the measured readout time).
    public var rollingShutter = false
    public var rollingShutterStrength: Double = 100
    public init() {}

    /// The settings stored on a Stabilizer effect (defaults for missing values).
    public init(effect e: ClipEffect) {
        self.init()
        method = e.stabilizeMethod
        if let m = e.parameters[ClipEffect.stabilizeModeKey]?.value { mode = StabilizerMode(rawValue: Int(m.rounded())) ?? .smooth }
        if let s = e.parameters[ClipEffect.stabilizeSmoothnessKey]?.value, s.isFinite, s > 0 { smoothness = s }
        if let t = e.parameters[ClipEffect.stabilizeStrengthKey]?.value, t.isFinite { strength = min(max(t, 0), 100) / 100 }
        if let c = e.parameters[ClipEffect.stabilizeMaxCropKey]?.value, c.isFinite { maxCrop = min(max(c, 0), 50) / 100 }
        edgeFill = e.stabilizeEdgeFill
        if let r = e.parameters[ClipEffect.rollingShutterKey]?.value { rollingShutter = r >= 0.5 }
        if let s = e.parameters[ClipEffect.rollingShutterStrengthKey]?.value, s.isFinite { rollingShutterStrength = min(max(s, 0), 200) }
    }

    /// True when a clip planned with `other` needs no new plan for these options: they differ at most in what the
    /// renderer applies by itself (Rolling Shutter Strength scales the stored shear, `rollingShutterFilter`).
    public func samePlan(as other: StabilizerOptions) -> Bool {
        var a = self, b = other
        a.rollingShutterStrength = 100; b.rollingShutterStrength = 100
        return a == b
    }
}

/// Which parts of the measured camera motion a segment's correction follows.
public enum StabilizationModel: String, Sendable, Hashable {
    /// Move, turn and zoom.
    case similarity
    /// Move and turn (the measured zoom is left out).
    case rigid
    /// Move only.
    case translation

    func reduce(_ m: CameraMotion) -> CameraMotion {
        switch self {
        case .similarity: m
        case .rigid: CameraMotion(dx: m.dx, dy: m.dy, rotation: m.rotation)
        case .translation: CameraMotion(dx: m.dx, dy: m.dy)
        }
    }
}

public struct StabilizationPlan: Sendable, Hashable {
    /// Stage per analyzed frame (auto scale included), anchor at the picture center.
    public var corrections: [StageTransform]
    /// The auto scale (>= 1).
    public var zoom: Double
    /// Every frame covers its picture at `zoom` (false only for Locked shots that move too far).
    public var fullyCovered: Bool
    /// Frames left without correction (only the shared zoom) because their segment was mostly untrusted or the guard
    /// measured more shake after the correction than before. All frames = the shot is not stabilized (warn).
    public var uncorrectedFrames: Int
    /// Per segment: checked shake after / before the correction (the guard's measure; -1 = too few checks). Diagnostics.
    public var checkedShakeRatios: [Double] = []
    /// Per segment: which parts of the measured motion were corrected (chosen with the checks). Diagnostics.
    public var models: [StabilizationModel] = []
    /// Per analyzed frame: the residual perspective correction (smoothed, Strength applied), warped in the Stabilizer's one
    /// warp pass. Empty = none (zero perspective: the render is exactly as without this field).
    public var perspective: [PerspectiveResidual] = []
    /// Per analyzed frame: share of the output pixels whose source falls outside the picture at `zoom` (0 = covered).
    /// Perspective residuals are not counted (shortcut: similarity only, upgrade if edges show on perspective-heavy clips).
    public var uncovered: [Double] = []
    /// Share of each picture side cut away by the auto scale.
    public var crop: Double { 1 - 1 / zoom }
    public init(corrections: [StageTransform], zoom: Double, fullyCovered: Bool, uncorrectedFrames: Int = 0) {
        self.corrections = corrections; self.zoom = zoom; self.fullyCovered = fullyCovered
        self.uncorrectedFrames = uncorrectedFrames
    }
}

public enum Stabilizer {
    /// Absolute poses: path[k] = motions[k] after ... after motions[0].
    public static func path(_ motions: [CameraMotion]) -> [CameraPose] {
        var out: [CameraPose] = []
        out.reserveCapacity(motions.count)
        var p = CameraPose.identity
        for m in motions {
            p = m.pose.after(p)
            out.append(p)
        }
        return out
    }

    /// Gaussian smoothing with odd reflection at the ends: the first and last values stay, a straight line stays straight.
    public static func gaussianSmooth(_ xs: [Double], sigma: Double) -> [Double] {
        let n = xs.count
        guard n > 2, sigma.isFinite, sigma > 0 else { return xs }
        let r = min(Int((3 * sigma).rounded(.up)), n - 1)
        guard r > 0 else { return xs }
        let w = (0...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = w[0] + 2 * w[1...].reduce(0, +)
        func at(_ i: Int) -> Double {
            if i < 0 { return 2 * xs[0] - xs[min(-i, n - 1)] }
            if i >= n { return 2 * xs[n - 1] - xs[max(2 * (n - 1) - i, 0)] }
            return xs[i]
        }
        return (0..<n).map { i in
            var s = w[0] * xs[i]
            for k in 1...r { s += w[k] * (at(i - k) + at(i + k)) }
            return s / total
        }
    }

    static func smooth(_ poses: [CameraPose], sigma: Double) -> [CameraPose] {
        let tx = gaussianSmooth(poses.map(\.translation.x), sigma: sigma)
        let ty = gaussianSmooth(poses.map(\.translation.y), sigma: sigma)
        let r = gaussianSmooth(poses.map(\.rotation), sigma: sigma)
        let s = gaussianSmooth(poses.map(\.logScale), sigma: sigma)
        return poses.indices.map { CameraPose(translation: Vec2(tx[$0], ty[$0]), rotation: r[$0], logScale: s[$0]) }
    }

    /// RMS of the second differences: frame-to-frame shake of a point's track (a steady pan scores 0).
    public static func jitter(_ pts: [Vec2]) -> Double {
        guard pts.count > 2 else { return 0 }
        var s = 0.0
        for i in 1..<(pts.count - 1) {
            let d = pts[i + 1] - pts[i] * 2 + pts[i - 1]
            s += d.x * d.x + d.y * d.y
        }
        return (s / Double(pts.count - 2)).squareRoot()
    }

    /// Smallest zoom z (1...cap) at which `z` after correction `c` still covers the picture (half sizes hw, hh) at every
    /// output corner; nil when even `cap` does not.
    static func requiredZoom(_ c: CameraPose, hw: Double, hh: Double, cap: Double) -> Double? {
        let inv = c.inverse
        func covers(_ z: Double) -> Bool {
            for q in [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)] {
                let s = inv.apply(q * (1 / z))
                if abs(s.x) > hw * (1 + 1e-12) || abs(s.y) > hh * (1 + 1e-12) { return false }
            }
            return true
        }
        if covers(1) { return 1 }
        guard covers(cap) else { return nil }
        var lo = 1.0, hi = cap
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if covers(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// Most of a frame Mirror / Blur Edge may have to invent (share of output pixels); the zoom is lowered to this.
    public static let edgeFillTolerance = 0.01

    /// Share of the output (half sizes hw, hh) whose source lies outside the picture when correction `c` is followed by
    /// `zoom`: the picture's quad `zoom * c(corner)` is clipped to the output rectangle (Sutherland-Hodgman).
    static func uncoveredFraction(_ c: CameraPose, zoom: Double, hw: Double, hh: Double) -> Double {
        var poly = [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)].map { c.apply($0) * zoom }
        // Each clip edge: keep points with sign * coordinate <= bound.
        for (axisX, sign, bound) in [(true, 1.0, hw), (true, -1.0, hw), (false, 1.0, hh), (false, -1.0, hh)] {
            func d(_ p: Vec2) -> Double { sign * (axisX ? p.x : p.y) - bound }
            var out: [Vec2] = []
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                let da = d(a), db = d(b)
                if da <= 0 { out.append(a) }
                if (da < 0 && db > 0) || (da > 0 && db < 0) { out.append(Vec2.lerp(a, b, da / (da - db))) }
            }
            poly = out
            if poly.isEmpty { return 1 }
        }
        var area = 0.0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            area += a.x * b.y - b.x * a.y
        }
        return min(max(1 - abs(area) / 2 / (4 * hw * hh), 0), 1)
    }

    /// The plan for `analysis`; nil with fewer than two frames or no picture size.
    public static func plan(_ analysis: StabilizationAnalysis, options: StabilizerOptions) -> StabilizationPlan? {
        let n = min(analysis.motions.count, analysis.frameTimes.count)
        guard n >= 2, analysis.pictureWidth > 0, analysis.pictureHeight > 0 else { return nil }
        // Scene cuts split the shot: each segment is its own camera path (starting at the identity pose) and is smoothed or
        // locked on its own, so nothing is averaged across a cut.
        let bounds = [0] + Set(analysis.cuts.filter { $0 > 0 && $0 < n }).sorted() + [n]
        let segments = (0..<(bounds.count - 1)).map { bounds[$0]..<bounds[$0 + 1] }
        // Low-confidence motions are replaced by their trusted neighbors (`trustedMotions`): the path there follows the
        // surrounding camera movement instead of registration noise, so the correction neither removes nor adds shake.
        // A segment that is mostly untrusted (a blank wall, or a moving subject the check cannot see past) keeps the
        // measured motions as they are and is corrected only when the guard measures it gets steadier.
        let measured = trustedMotions(analysis, segments: segments)
        let doubtful = segments.map { r in
            Double(r.dropFirst().filter { analysis.confidence(at: $0) >= minConfidence }.count)
                < minConfidentShare * Double(max(r.count - 1, 1))
        }
        var skip = Array(repeating: false, count: segments.count)
        let hw = Double(analysis.pictureWidth) / 2, hh = Double(analysis.pictureHeight) / 2
        let mode: StabilizerMode = options.mode == .auto ? (isStill(measured, segments: segments, hw: hw, hh: hh) ? .locked : .smooth) : options.mode
        let strength = min(max(options.strength, 0), 1)
        let limit = 1 / (1 - min(max(mode == .locked ? options.maxLockedCrop : options.maxCrop, 0), 0.9))
        // The keys only follow the exact correction within the tolerances (`effect`), which can move the picture edge up to
        // `slack` px inwards at a corner; the zoom gets that much extra, kept inside the crop limit.
        let diagonal = (hw * hw + hh * hh).squareRoot()
        let slack = positionTolerance * 2.squareRoot() + diagonal * (scaleTolerance + limit * rotationTolerance * .pi / 180)
        let margin = 1 + slack / min(hw, hh)
        let cap = limit / margin
        let seconds = analysis.seconds
        let fps = seconds > 0 ? Double(n - 1) / seconds : 30
        let sigma = max(options.smoothness, 0) * fps
        // Bilateral motion width: path differences beyond ~15% of the long half-side count as an intended move.
        let motionSigma = max(hw, hh) * 0.15
        /// Corrections (no zoom) for one segment's motions `ms` (`ms[0]` ignored).
        func corrections(_ ms: [CameraMotion]) -> [CameraPose] {
            var ms = ms
            ms[0] = .identity
            let real = path(ms), m = ms.count
            func correction(_ wanted: CameraPose, _ k: Int) -> CameraPose { wanted.after(real[k].inverse) }
            switch mode {
            case .locked, .auto:
                // Camera Lock: one pose for the segment (middle of the translation range = smallest largest correction, mean
                // turn/scale). A frame that cannot hold it within the crop limit falls back to the smoothed path, and where
                // even that does not fit, to the real path: the lock gives way locally instead of leaving the picture short.
                let xs = real.map(\.translation.x), ys = real.map(\.translation.y)
                let mid = CameraPose(translation: Vec2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2),
                                     rotation: real.map(\.rotation).reduce(0, +) / Double(m),
                                     logScale: real.map(\.logScale).reduce(0, +) / Double(m))
                // Crop-aware: the pose is then searched for the smallest zoom the whole segment needs to hold it.
                let fixed = lockPose(real: real, start: mid, step: hw * 0.05) { p, k in
                    requiredZoom(correction(p, k), hw: hw, hh: hh, cap: cap)
                }
                let soft = bilateralSmooth(real, sigma: sigma, motionSigma: motionSigma, reach: diagonal)
                func fits(_ p: CameraPose, _ k: Int) -> Bool { requiredZoom(correction(p, k), hw: hw, hh: hh, cap: cap) != nil }
                func giveWay(_ from: CameraPose, to: CameraPose, _ k: Int) -> CameraPose {
                    if fits(from, k) { return from }
                    var lo = 0.0, hi = 1.0
                    for _ in 0..<30 {
                        let mid = (lo + hi) / 2
                        if fits(CameraPose.lerp(from, to, mid), k) { hi = mid } else { lo = mid }
                    }
                    return CameraPose.lerp(from, to, hi)
                }
                return real.indices.map { k in
                    let w = fits(fixed, k) ? fixed : giveWay(fixed, to: fits(soft[k], k) ? soft[k] : real[k], k)
                    return correction(CameraPose.lerp(real[k], fits(w, k) ? w : real[k], strength), k)
                }
            case .smooth:
                let quad = adaptiveQuadraticPath(real: real, sigma: sigma) { p, k in
                    requiredZoom(correction(p, k), hw: hw, hh: hh, cap: cap) != nil
                }
                // L1 crop path: the straightest path in the crop tube of the least zoom that is no more jittery than `quad`.
                let w = l1CropPath(real: real, base: quad, hw: hw, hh: hh) { p, k in
                    requiredZoom(correction(p, k), hw: hw, hh: hh, cap: cap)
                }
                return real.indices.map { correction(CameraPose.lerp(real[$0], w[$0], strength), $0) }
            }
        }

        // Per segment: the full similarity correction, and (when the checks can judge it) the same without the measured
        // zoom, and without zoom and turn. Vision's zoom / turn of a small, nearly still frame is mostly noise (60 fps
        // iPhone footage: per-frame shake below 1 px), and correcting noise adds shake; the check, independent of that
        // noise, picks the model that leaves the least shake.
        var raw: [CameraPose] = []
        raw.reserveCapacity(n)
        var models: [StabilizationModel] = []
        var ratios: [Double] = []
        for (i, seg) in segments.enumerated() {
            var ms = doubtful[i] ? Array(analysis.motions[seg]) : Array(measured[seg])
            var best = (model: StabilizationModel.similarity, raw: corrections(ms), ratio: nil as Double?)
            best.ratio = checkedShakeRatio(best.raw, analysis.checks, seg, hw: hw, hh: hh)
            // Untrusted frames in a trusted segment: their own motion is dropped for the neighbors' mean, so their part
            // of the shake stays in. The motions as measured are tried too and kept when the checks see clearly less
            // shake (registration noise corrected into the picture makes the checked ratio worse, not better).
            if !doubtful[i], let fallback = best.ratio, fallback > 0, Array(analysis.motions[seg]) != ms {
                let asMeasured = Array(analysis.motions[seg])
                let c = corrections(asMeasured)
                if let r = checkedShakeRatio(c, analysis.checks, seg, hw: hw, hh: hh), r < fallback * simplerModelGain {
                    ms = asMeasured
                    best = (.similarity, c, r)
                }
            }
            if let full = best.ratio, full > 0 {
                for model in [StabilizationModel.rigid, .translation] {
                    let c = corrections(ms.map(model.reduce))
                    if let r = checkedShakeRatio(c, analysis.checks, seg, hw: hw, hh: hh), r < best.ratio! * simplerModelGain {
                        best = (model, c, r)
                    }
                }
            }
            raw += best.raw
            models.append(best.model)
            let r = best.ratio
            ratios.append(r ?? -1)
            if doubtful[i] {
                if !(r.map { $0 < min(options.guardLimit, 1) } ?? false) { skip[i] = true }
            } else if let r, !(r < options.guardLimit) {
                skip[i] = true
            }
        }
        var uncorrected = 0
        for (i, seg) in segments.enumerated() where skip[i] {
            for k in seg { raw[k] = .identity }
            uncorrected += seg.count
        }
        var zoom = 1.0, covered = true
        for c in raw {
            if let z = requiredZoom(c, hw: hw, hh: hh, cap: cap) { zoom = max(zoom, z) } else { zoom = cap; covered = false }
        }
        // Mirror / Blur Edge fill what the zoom would hide: the zoom drops to the least at which no frame leaves more than
        // `edgeFillTolerance` of its pixels open (never below 1, never above the covering zoom).
        if options.edgeFill != .zoom, zoom > 1 {
            func worst(_ z: Double) -> Double { raw.map { uncoveredFraction($0, zoom: z, hw: hw, hh: hh) }.max() ?? 0 }
            if worst(1) > edgeFillTolerance {
                var lo = 1.0, hi = zoom
                for _ in 0..<40 {
                    let mid = (lo + hi) / 2
                    if worst(mid) <= edgeFillTolerance { hi = mid } else { lo = mid }
                }
                zoom = hi
            } else {
                zoom = 1
            }
        }
        if zoom > 1 { zoom *= margin }   // zoom 1 = no correction anywhere: nothing for the keys to miss
        let corrections = raw.map { c -> StageTransform in
            let z = CameraPose(logScale: log(zoom)).after(c)
            let identity = abs(z.translation.x) < 1e-9 && abs(z.translation.y) < 1e-9 && abs(z.rotation) < 1e-9 && abs(z.logScale) < 1e-12
            return identity ? .identity : StageTransform(position: z.translation, scale: z.scale, rotation: z.rotation)
        }
        var plan = StabilizationPlan(corrections: corrections, zoom: zoom, fullyCovered: covered, uncorrectedFrames: uncorrected)
        plan.uncovered = raw.map { uncoveredFraction($0, zoom: zoom, hw: hw, hh: hh) }
        plan.checkedShakeRatios = ratios
        plan.models = models
        plan.perspective = perspectiveCorrections(analysis, n: n, segments: segments, skip: skip, locked: mode == .locked,
                                                  sigma: sigma, strength: strength)
        return plan
    }

    /// True when every segment's camera stays within a small part of the picture around its middle pose: a still shot with
    /// shake only, which Auto holds like a tripod. A pan, a walk or a drift moves the path beyond it.
    static func isStill(_ motions: [CameraMotion], segments: [Range<Int>], hw: Double, hh: Double) -> Bool {
        let reach = (hw * hw + hh * hh).squareRoot()
        for seg in segments where seg.count > 1 {
            var ms = Array(motions[seg]); ms[0] = .identity
            let real = path(ms)
            let xs = real.map(\.translation.x), ys = real.map(\.translation.y)
            let mid = CameraPose(translation: Vec2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2),
                                 rotation: real.map(\.rotation).reduce(0, +) / Double(real.count),
                                 logScale: real.map(\.logScale).reduce(0, +) / Double(real.count))
            if real.contains(where: { pathDistance($0, mid, reach: reach * 0.5) > stillLimit * min(hw, hh) }) { return false }
        }
        return true
    }
    /// Auto holds a shot whose path stays within this share of the half picture around its middle.
    static let stillLimit = 0.12

    /// A simpler model replaces the fuller one only when its checked shake ratio is below this share of the fuller one's
    /// (near ties keep the full correction: the check's own noise pulls ratios together).
    public static let simplerModelGain = 0.9

    /// Motions below this confidence are not used as measured (`trustedMotions`).
    public static let minConfidence = 0.5
    /// Motion and check agree within this (px per 512 px of the long side): full confidence; from `fullDisagreement`
    /// none, so trusted (`minConfidence`) up to 1 px per 512. Half the scale SQAnalysis rates Vision against the check
    /// with (1...3, PhotometricRegistration): here the agreement overrides a low feature confidence, so it must be close.
    public static let fullAgreement = 0.5, fullDisagreement = 1.5
    /// A segment with fewer trusted motions than this share is corrected only when the guard measures less shake after
    /// (ratio below 1, and below `guardLimit`); without a verdict it is left uncorrected.
    public static let minConfidentShare = 0.5
    /// The guard keeps a correction only when the checked shake after is below this share of before. Above 1 because the
    /// check's own noise pulls every ratio towards 1 (a ratio near 1 means "cannot tell"); measured 2026-10-04
    /// (EngineBench stabilize): segments that improve 0.28-1.14, the iPhone shots that got shakier 1.6-2.3.
    public static let guardRatio = 1.25
    /// Fewer checked pairs in a segment than this: no verdict, the correction stays.
    public static let guardMinPairs = 10

    /// Trusted motions averaged on each side of an untrusted stretch (the camera's steady movement there, without shake).
    static let fallbackNeighbours = 10

    /// The measured motions with every low-confidence one replaced by the camera's steady movement around it: the mean
    /// of up to `fallbackNeighbors` trusted motions before and after the stretch, blended across it (one side only at a
    /// segment end; identity when the segment has none). Single neighbors would carry their own shake into the stretch
    /// as a fake pan.
    static func trustedMotions(_ a: StabilizationAnalysis, segments: [Range<Int>]) -> [CameraMotion] {
        var out = Array(a.motions.prefix(segments.last?.upperBound ?? 0))
        guard !a.confidence.isEmpty else { return out }
        func mean(_ ks: ArraySlice<Int>) -> CameraMotion? {
            guard !ks.isEmpty else { return nil }
            var m = CameraMotion(dx: 0, dy: 0, rotation: 0, scale: 0)
            for k in ks { let x = a.motions[k]; m.dx += x.dx; m.dy += x.dy; m.rotation += x.rotation; m.scale += log(x.scale) }
            let c = Double(ks.count)
            return CameraMotion(dx: m.dx / c, dy: m.dy / c, rotation: m.rotation / c, scale: exp(m.scale / c))
        }
        for seg in segments {
            let trusted = seg.dropFirst().filter { a.confidence(at: $0) >= minConfidence && a.motions[$0].scale > 0 }
            guard trusted.count < seg.count - 1 else { continue }
            var k = seg.lowerBound + 1
            while k < seg.upperBound {
                guard a.confidence(at: k) < minConfidence else { k += 1; continue }
                var end = k
                while end < seg.upperBound && a.confidence(at: end) < minConfidence { end += 1 }   // stretch k..<end
                let split = trusted.firstIndex { $0 > k } ?? trusted.count
                let left = mean(trusted[max(0, split - fallbackNeighbours)..<split])
                let right = mean(trusted[split..<min(trusted.count, split + fallbackNeighbours)])
                for j in k..<end {
                    switch (left, right) {
                    case let (l?, r?):
                        let t = Double(j - k + 1) / Double(end - k + 1)
                        out[j] = CameraMotion(dx: l.dx + (r.dx - l.dx) * t, dy: l.dy + (r.dy - l.dy) * t,
                                              rotation: l.rotation + (r.rotation - l.rotation) * t,
                                              scale: exp(log(l.scale) + (log(r.scale) - log(l.scale)) * t))
                    case let (l?, nil): out[j] = l
                    case let (nil, r?): out[j] = r
                    case (nil, nil): out[j] = .identity
                    }
                }
                k = end
            }
        }
        return out
    }

    /// Variance of the frame-to-frame motion of four points (half way to the corners), summed: the residual shake measure.
    static func shake(_ ms: [CameraPose], hw: Double, hh: Double) -> Double {
        guard ms.count > 1 else { return 0 }
        var total = 0.0
        for q in [Vec2(-hw / 2, -hh / 2), Vec2(hw / 2, -hh / 2), Vec2(hw / 2, hh / 2), Vec2(-hw / 2, hh / 2)] {
            let d = ms.map { $0.apply(q) - q }
            var mean = Vec2.zero
            for v in d { mean = mean + v }
            mean = mean * (1 / Double(d.count))
            var s = 0.0
            for v in d { let e = v - mean; s += e.x * e.x + e.y * e.y }
            total += s / Double(d.count - 1)
        }
        return total
    }

    /// The guard's measure for one segment: shake after the segment's corrections `raw` (no zoom; `raw[0]` is frame
    /// `seg.lowerBound`) / before, as the checks see it; nil when there are too few checks to tell.
    static func checkedShakeRatio(_ raw: [CameraPose], _ checks: [CameraMotion?], _ seg: Range<Int>, hw: Double, hh: Double) -> Double? {
        var before: [CameraPose] = [], after: [CameraPose] = []
        let o = seg.lowerBound
        for k in seg.dropFirst() where k < checks.count {
            guard let t = checks[k] else { continue }
            let tp = t.pose
            before.append(tp)
            // What the viewer sees from frame k-1 to k: C_k after T_k after C_{k-1}^-1.
            after.append(raw[k - o].after(tp).after(raw[k - 1 - o].inverse))
        }
        guard before.count >= guardMinPairs else { return nil }
        let b = shake(before, hw: hw, hh: hh), a = shake(after, hw: hw, hh: hh)
        return b > 0 ? a / b : (a > 0 ? .infinity : 1)
    }

    /// A Stabilizer effect for `clip`: Position / Rotation / Scale keys at clip frames (the correction of the analyzed source
    /// frame nearest to the source time shown there, through speed, reverse and time remapping; decimated within the
    /// tolerances below), plus the settings. Pure and nonisolated: callers run it off the main actor.
    public static func effect(plan: StabilizationPlan, analysis: StabilizationAnalysis, clip: Clip, frameDuration fd: Time,
                              options: StabilizerOptions, id: UUID = UUID()) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.stabilizeKind)!
        e.id = id
        e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(Double(StabilizerMethod.standard.rawValue))
        e.parameters[ClipEffect.stabilizeModeKey] = AnimatedProperty(Double(options.mode.rawValue))
        e.parameters[ClipEffect.stabilizeSmoothnessKey] = AnimatedProperty(options.smoothness)
        e.parameters[ClipEffect.stabilizeStrengthKey] = AnimatedProperty(options.strength * 100)
        e.parameters[ClipEffect.stabilizeMaxCropKey] = AnimatedProperty(options.maxCrop * 100)
        if options.edgeFill != .zoom { e.parameters[ClipEffect.stabilizeEdgeFillKey] = AnimatedProperty(Double(options.edgeFill.rawValue)) }
        if let a = analysis.frameTimes.first, let b = analysis.frameTimes.last {
            e.parameters[ClipEffect.stabilizeFromKey] = AnimatedProperty(Double(a.value) / Double(a.timescale))
            e.parameters[ClipEffect.stabilizeToKey] = AnimatedProperty(Double(b.value) / Double(b.timescale))
        }
        e.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(options.rollingShutter ? 1 : 0)
        e.parameters[ClipEffect.rollingShutterStrengthKey] = AnimatedProperty(options.rollingShutterStrength)
        let frames = Int(clip.duration.frameIndex(frameDuration: fd))
        if options.rollingShutter, frames > 0, !analysis.rolling.isEmpty {
            let shears = RollingShutter.shears(analysis, readout: RollingShutter.estimate(analysis).readout)
            var sx = [Double](), sy = [Double]()
            sx.reserveCapacity(frames); sy.reserveCapacity(frames)
            for i in 0..<frames {
                let s = RollingShutter.shear(shears, analysis, at: clip.sourceTime(at: clip.start + fd * Int64(i), frameDuration: fd))
                sx.append(s.x); sy.append(s.y)
            }
            let extent = Double(max(analysis.rollingScansAlongX ? analysis.pictureWidth : analysis.pictureHeight, 1))
            // Half a pixel across the whole extent: a quarter pixel at the first and last row.
            e.parameters[ClipEffect.rollingShearXKey] = decimatedProperty(sx, frameDuration: fd, tolerance: 0.5 / extent)
            e.parameters[ClipEffect.rollingShearYKey] = decimatedProperty(sy, frameDuration: fd, tolerance: 0.5 / extent)
            if analysis.rollingScansAlongX { e.parameters[ClipEffect.rollingScanAxisKey] = AnimatedProperty(1) }
        }
        if frames > 0, !plan.perspective.isEmpty {
            // Eight keys (the residual homography), written only when a frame needs a correction: none = no warp pass.
            let tol = perspectiveTolerances(pictureWidth: analysis.pictureWidth, pictureHeight: analysis.pictureHeight)
            var cols = [[Double]](repeating: [], count: 8)
            for i in 0..<frames {
                let v = perspectiveCorrection(plan, analysis, at: clip.sourceTime(at: clip.start + fd * Int64(i), frameDuration: fd)).values
                for c in 0..<8 { cols[c].append(v[c]) }
            }
            if cols.contains(where: { $0.contains { abs($0) > perspectiveFloor } }) {
                for c in 0..<8 { e.parameters[ClipEffect.stabilizePerspectiveKeys[c]] = decimatedProperty(cols[c], frameDuration: fd, tolerance: tol[c]) }
            }
        }
        guard frames > 0, !plan.corrections.isEmpty else { return e }
        // The full per-frame correction, then only the keys linear interpolation needs to stay within the tolerances
        // (a key per frame would make a 10-minute clip tens of MB in the file and in every undo step).
        var px = [Double](), py = [Double](), rot = [Double](), sc = [Double]()
        px.reserveCapacity(frames); py.reserveCapacity(frames); rot.reserveCapacity(frames); sc.reserveCapacity(frames)
        for i in 0..<frames {
            let src = clip.sourceTime(at: clip.start + fd * Int64(i), frameDuration: fd)
            let c = correction(plan, analysis, at: src)
            px.append(c.position.x); py.append(c.position.y); rot.append(c.rotation); sc.append(c.scale * 100)
        }
        func prop(_ v: [Double], _ tolerance: Double) -> AnimatedProperty<Double> {
            decimatedProperty(v, frameDuration: fd, tolerance: tolerance)
        }
        e.parameters[ClipEffect.stagePositionXKey] = prop(px, positionTolerance)
        e.parameters[ClipEffect.stagePositionYKey] = prop(py, positionTolerance)
        e.parameters[ClipEffect.stageRotationKey] = prop(rot, rotationTolerance)
        e.parameters[ClipEffect.stageScaleKey] = prop(sc, scaleTolerance * 100)
        return e
    }

    /// The correction at source time `t`: the analyzed frame's own, linear between two analyzed frames (high frame rates
    /// are analyzed at about 30 fps, `StabilizationAnalysis` frame step), held before the first / after the last and
    /// across a cut (the earlier shot's).
    public static func correction(_ plan: StabilizationPlan, _ analysis: StabilizationAnalysis, at t: Time) -> StageTransform {
        let cs = plan.corrections, ts = analysis.frameTimes
        let n = min(cs.count, ts.count)
        guard n > 0 else { return .identity }
        var lo = 0, hi = n          // first index with ts[i] > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return cs[0] }
        let i = lo - 1
        if i == n - 1 || ts[i] == t || analysis.cuts.contains(i + 1) { return cs[i] }
        let span = ts[i + 1] - ts[i], into = t - ts[i]
        let f = Double(into.value) / Double(into.timescale) / (Double(span.value) / Double(span.timescale))
        guard f.isFinite, f > 0 else { return cs[i] }
        let a = cs[i], b = cs[i + 1]
        return StageTransform(position: Vec2.lerp(a.position, b.position, f), scale: exp(log(a.scale) + (log(b.scale) - log(a.scale)) * f),
                              rotation: a.rotation + (b.rotation - a.rotation) * f)
    }

    /// One value per frame (`fd` apart from 0) as linear keys within `tolerance` of every value; a constant (no keys)
    /// when every value is within `tolerance` of the first.
    public static func decimatedProperty(_ v: [Double], frameDuration fd: Time, tolerance: Double) -> AnimatedProperty<Double> {
        guard let first = v.first else { return AnimatedProperty(0) }
        // Constant only when the constant itself is within tolerance everywhere (RDP's two end keys alone can still
        // hide up to twice the tolerance between them).
        guard v.contains(where: { abs($0 - first) > tolerance }) else { return AnimatedProperty(first) }
        let kept = decimate(times: v.indices.map(Double.init), values: v, tolerance: tolerance)
        return AnimatedProperty(first, track: KeyframeTrack(keys: kept.map { Keyframe(time: fd * Int64($0), value: v[$0]) }))
    }

    /// Largest error of the stored keys against the full per-frame correction: source px, degrees, scale (1 = 100 %).
    public static let positionTolerance = 0.1, rotationTolerance = 0.01, scaleTolerance = 0.0005

    /// Ramer-Douglas-Peucker on one value track: indices to keep (always the first and the last) so that linear
    /// interpolation between kept samples stays within `tolerance` of every dropped one.
    public static func decimate(times: [Double], values: [Double], tolerance: Double) -> [Int] {
        let n = min(times.count, values.count)
        guard n > 2 else { return Array(0..<n) }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true; keep[n - 1] = true
        var stack = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let span = times[b] - times[a], va = values[a], dv = values[b] - values[a]
            var worst = -1.0, at = -1
            for k in (a + 1)..<b {
                let f = span > 0 ? (times[k] - times[a]) / span : 0
                let d = abs(va + dv * f - values[k])
                if d > worst { worst = d; at = k }
            }
            if worst > tolerance {
                keep[at] = true
                stack.append((a, at)); stack.append((at, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// Where a Stabilizer effect goes in `effects`: before the first transform stage (it corrects the source picture, so
    /// Transform / Auto Reframe / motion presets act on the steadied picture), else at the end.
    public static func insertionIndex(in effects: [ClipEffect]) -> Int {
        effects.firstIndex { $0.isTransformStage && $0.kind != ClipEffect.stabilizeKind } ?? effects.count
    }
}

extension ClipEffect {
    public static let stabilizeKind = "stabilize"
    // Stored parameter keys (never rename). The stage keys (position, rotation, scale) are the shared transform-stage keys.
    public static let stabilizeStrengthKey = "stabilizeStrength"
    public static let stabilizeEdgeFillKey = "edgeFill"
    public static let stabilizeModeKey = "stabilizeMode",stabilizeSmoothnessKey = "smoothness", stabilizeMaxCropKey = "maxCrop"
    /// The source range (seconds) the analysis measured, to notice a clip trimmed beyond it.
    public static let stabilizeFromKey = "analysedFrom", stabilizeToKey = "analysedTo"

    /// What fills the border a Standard Stabilizer's Crop Limit leaves open (Zoom when missing or out of range).
    public var stabilizeEdgeFill: StabilizerEdgeFill {
        guard kind == Self.stabilizeKind, let v = parameters[Self.stabilizeEdgeFillKey]?.value, v.isFinite else { return .zoom }
        return StabilizerEdgeFill(rawValue: Int(v.rounded())) ?? .zoom
    }

    /// The Stabilizer's correction is a picture warp with a filled border instead of a clip transform.
    var stabilizeFillsEdges: Bool { enabled && stabilizeMethod == .standard && stabilizeEdgeFill != .zoom }

    /// The source range a Stabilizer's analysis covered; nil for a Stabilizer written before it was recorded.
    public var stabilizeAnalysedRange: (from: Double, to: Double)? {
        guard kind == Self.stabilizeKind, let a = parameters[Self.stabilizeFromKey]?.value,
              let b = parameters[Self.stabilizeToKey]?.value else { return nil }
        return (a, b)
    }

    /// The Stabilizer's analysis no longer covers `needed` (source range the clip shows now): trimmed longer, so the new
    /// frames would hold the last correction. `frameDuration` is the tolerance.
    public func stabilizeNeedsAnalysis(of needed: TimeRange, frameDuration fd: Time) -> Bool {
        guard let r = stabilizeAnalysedRange else { return false }
        let tol = 2 * Double(fd.value) / Double(fd.timescale)   // the range ends one frame past the last frame shown
        let lo = Double(needed.start.value) / Double(needed.start.timescale)
        let hi = Double(needed.end.value) / Double(needed.end.timescale)
        return lo < r.from - tol || hi > r.to + tol
    }
}

extension EffectTransformStage {
    /// The Stabilizer effect (Effects panel > Video > Transform, or Clip > Video Options > Stabilize). Method first; Effect
    /// Controls shows only the rows of the chosen method (`StabilizerMethod.visibleKeys`).
    public static let stabilizeSpec = EffectSpec(kind: ClipEffect.stabilizeKind, title: "Stabilizer", params: [
        .choice(ClipEffect.stabilizeMethodKey, "Method", StabilizerMethod.allCases.map(\.title)),
        // Standard
        .choice(ClipEffect.stabilizeModeKey, "Result", ["Smooth Motion", "No Motion", "Auto"]),
        EffectParamSpec(key: ClipEffect.stabilizeStrengthKey, title: "Strength", unit: "%", defaultValue: 100,
                        range: 0...100, step: 1, decimals: 0),
        EffectParamSpec(key: ClipEffect.stabilizeSmoothnessKey, title: "Smoothness", unit: "s", defaultValue: 0.5,
                        range: 0.05...10, step: 0.05, decimals: 2),
        EffectParamSpec(key: ClipEffect.stabilizeMaxCropKey, title: "Crop Limit", unit: "%", defaultValue: 8,
                        range: 0...50, step: 1, decimals: 0),
        .choice(ClipEffect.stabilizeEdgeFillKey, "Edge Fill", StabilizerEdgeFill.allCases.map(\.title)),
        .checkbox(ClipEffect.rollingShutterKey, "Rolling Shutter"),
        EffectParamSpec(key: ClipEffect.rollingShutterStrengthKey, title: "Rolling Shutter Strength", unit: "%", defaultValue: 100,
                        range: 0...200, step: 1, decimals: 0),
        // Gyroflow (GyroflowOptions)
        EffectParamSpec(key: ClipEffect.gyroSmoothnessKey, title: "Smoothness", unit: "%", defaultValue: 50,
                        range: 1...100, step: 1, decimals: 0),
        EffectParamSpec(key: ClipEffect.gyroZoomLimitKey, title: "Zoom Limit", unit: "%", defaultValue: 130,
                        range: 100...300, step: 1, decimals: 0),
        EffectParamSpec(key: ClipEffect.gyroFieldOfViewKey, title: "Field of View", unit: "%", defaultValue: 100,
                        range: 10...300, step: 1, decimals: 0),
        EffectParamSpec(key: ClipEffect.gyroLensCorrectionKey, title: "Lens Correction", unit: "%", defaultValue: 100,
                        range: 0...100, step: 1, decimals: 0),
        .checkbox(ClipEffect.gyroRollingShutterKey, "Rolling Shutter", on: true),
        EffectParamSpec(key: ClipEffect.gyroHorizonLockKey, title: "Horizon Lock", unit: "%", defaultValue: 0,
                        range: 0...100, step: 1, decimals: 0),
        EffectParamSpec(key: ClipEffect.gyroSyncOffsetKey, title: "Sync Offset", unit: "ms", defaultValue: 0,
                        range: -5000...5000, step: 1, decimals: 1),
    ])
    // The Position / Rotation / Scale keys the analysis writes are not listed: they are dense generated data (the stage reads
    // them by key, `stageTransform`), and changing Result / Smoothness / Crop Limit re-plans them from the cached analysis.
}
