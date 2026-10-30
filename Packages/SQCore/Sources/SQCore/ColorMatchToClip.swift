import Foundation

// Clip > Video Options > Match Color to Clip: the one-shot form of FB-B3 Color Match. The reference is picked from the
// timeline (no Set Reference step), both clips are measured on their own (solo picture: raw file + grade), and the same
// Color Wheels solver writes the target's first Color effect. Pure model side; the host renders and samples the frames.

/// Which clip a target is matched to, and the sequence times of the two frames that are measured.
public struct ColorMatchPair: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// The clip under the playhead on another video track (nearest track; below wins a tie).
        case stacked
        /// The clip before the target on its own track.
        case previous
    }
    public var target: Clip.ID
    public var targetTime: Time
    public var reference: Clip.ID
    public var referenceTime: Time
    public var source: Source
}

extension Clip {
    /// A picture of its own that Match can measure: an enabled video clip from a file (no generator, no nested sequence).
    public var isColorMatchPicture: Bool { kind == .video && isEnabled && !isGenerator && !isNested }

    /// The frame Match measures: the playhead's when it is on the clip, else the clip's middle frame.
    func colorMatchSampleTime(playhead: Time, frameDuration: Time) -> Time {
        if timeline.contains(playhead) { return playhead.flooredToFrame(frameDuration) }
        return (start + Time.scaled(duration, by: 1, over: 2)).flooredToFrame(frameDuration)
    }
}

extension Timeline {
    /// The reference for matching video clip `target`: the clip under `playhead` on the nearest other visible video track,
    /// else the previous clip on the target's own track. nil when the target cannot be matched or nothing qualifies.
    public func colorMatchPair(target: Clip.ID, playhead: Time) -> ColorMatchPair? {
        guard let ti = tracks.firstIndex(where: { $0.kind == .video && $0.clips.contains { $0.id == target } }),
              let clip = tracks[ti].clips.first(where: { $0.id == target }), clip.isColorMatchPicture else { return nil }
        let targetTime = clip.colorMatchSampleTime(playhead: playhead, frameDuration: frameDuration)
        let stacked = tracks.indices
            .filter { $0 != ti && tracks[$0].kind == .video && tracks[$0].isVisible }
            .sorted { (abs($0 - ti), $0) < (abs($1 - ti), $1) }
            .lazy.compactMap { i in self.tracks[i].clips.first { $0.isColorMatchPicture && $0.timeline.contains(playhead) } }
            .first
        if let r = stacked {
            return ColorMatchPair(target: target, targetTime: targetTime, reference: r.id,
                                  referenceTime: playhead.flooredToFrame(frameDuration), source: .stacked)
        }
        guard let prev = tracks[ti].clips.last(where: { $0.timeline.end <= clip.start && $0.isColorMatchPicture }) else {
            return nil
        }
        return ColorMatchPair(target: target, targetTime: targetTime, reference: prev.id,
                              referenceTime: prev.colorMatchSampleTime(playhead: prev.start - frameDuration,
                                                                       frameDuration: frameDuration),
                              source: .previous)
    }
}

extension ColorMatchSolver {
    /// Display samples without letterbox / pillarbox black (every channel below 1/255): a solo picture fitted into a
    /// frame of another shape would otherwise count its bars as shadows.
    public static func pictureSamples(_ display: [SIMD3<Float>]) -> [SIMD3<Float>] {
        display.filter { max($0.x, $0.y, $0.z) >= 1 / 255 }
    }

    /// The wheels already in the measured picture (neutral when the Wheels section is switched off).
    public static func wheelsInPicture(_ e: ColorEffect) -> ColorWheels {
        e.isEnabled(.wheels) ? e.wheels : ColorWheels()
    }

    /// Mean display luma of the picture the stats describe (the band masks sum to 1 per pixel, so the weighted band means
    /// add up to the frame mean).
    static func meanLuma(_ s: ColorMatchStats) -> Float {
        (ColorMatchStats.luma * s.shadows).sum() * s.weights.x + (ColorMatchStats.luma * s.midtones).sum() * s.weights.y
            + (ColorMatchStats.luma * s.highlights).sum() * s.weights.z
    }

    /// The Exposure stage runs only where the gray-axis Basic model (`AutoToneSolver.tone`) describes the picture before
    /// the wheels: Basic on, no Input LUT, Look and Curves off or neutral.
    static func exposureStageApplies(_ e: ColorEffect) -> Bool {
        e.isEnabled(.basicCorrection) && e.inputLUTIsNeutral
            && [ColorSectionKind.creative, .curves].allSatisfy { !e.isEnabled($0) || e.isNeutral($0) }
    }

    /// Display samples (as they leave Basic with `from`) as they would leave it with `to`: each pixel's luma goes back
    /// through `from` and forward through `to`; its color is scaled with it (ratios kept, so hue and saturation stay).
    static func exposed(_ px: [SIMD3<Float>], from: BasicCorrection, to: BasicCorrection) -> [SIMD3<Float>] {
        guard from != to else { return px }
        return px.map { c in
            let y = (ColorMatchStats.luma * c).sum()
            let y2 = AutoToneSolver.tone(AutoToneSolver.untone(y, from), to)
            return y > 1e-4 ? c * (y2 / y) : c + SIMD3(repeating: y2 - y)
        }
    }

    /// One-shot match: Exposure first (bisection so the frame's mean luma equals the reference's; ±5 stops, rounded to
    /// 0.01 like the slider), then the Color Wheels solve (`solve`) on the picture as the new Exposure would show it.
    /// `display`: the clip's frame as shown with effect `e` (its first Color effect). nil when nothing would change.
    public static func solveClip(display: [SIMD3<Float>], effect e: ColorEffect, reference: ColorMatchStats) -> ColorMatchResult? {
        let finite = display.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard finite.count >= 16 else { return nil }
        let step = max(1, finite.count / maxSamples)
        var px = Swift.stride(from: 0, to: finite.count, by: step).map { finite[$0] }
        let shownWheels = wheelsInPicture(e)
        if !shownWheels.isNeutral {
            let prep = ColorWheelsModel.Prepared(shownWheels)
            px = px.map { ColorWheelsModel.unapply($0, prep) }
        }
        var exposure: Float? = nil
        if exposureStageApplies(e) {
            let target = meanLuma(reference)
            let base = px.map { AutoToneSolver.untone((ColorMatchStats.luma * $0).sum(), e.basic) }
            func mean(_ ev: Float) -> Float {
                var b = e.basic; b.exposure = ev
                return base.reduce(0) { $0 + min(max(AutoToneSolver.tone($1, b), 0), 1) } / Float(base.count)
            }
            var lo: Float = -5, hi: Float = 5
            for _ in 0..<40 { let m = (lo + hi) / 2; if mean(m) < target { lo = m } else { hi = m } }
            let ev = (((lo + hi) / 2) * 100).rounded() / 100
            if ev != e.basic.exposure {
                var b = e.basic; b.exposure = ev
                px = exposed(px, from: e.basic, to: b)
                exposure = ev
            }
        }
        let wheels = solve(display: px, current: ColorWheels(), reference: reference) ?? ColorWheels()
        let result = ColorMatchResult(exposure: exposure, wheels: wheels)
        let unchanged = exposure == nil && rounded(wheels) == rounded(shownWheels) && e.isEnabled(.wheels)
        return unchanged ? nil : result
    }
}

/// What Match writes: a new Exposure (nil = keep) and the Color Wheels with Wheels Saturation.
public struct ColorMatchResult: Sendable, Equatable {
    public var exposure: Float?
    public var wheels: ColorWheels
    public init(exposure: Float?, wheels: ColorWheels) { self.exposure = exposure; self.wheels = wheels }
}

extension Clip {
    /// Writes a Match result: the first Color effect (created when the clip has none) gets the wheels with its Wheels
    /// section on and the new Exposure, keyed at clip-local `t` where those are keyframed, and remembers `reference` (so
    /// the Match row in Effect Controls shows it and can match again). False on clips that take no color.
    public mutating func applyColorMatch(_ result: ColorMatchResult, reference: ColorMatchReference, atLocal t: Time?) -> Bool {
        guard acceptsColor else { return false }
        if colorEffectIndices.isEmpty { effects.insert(ClipEffect.colorGrade(ClipColor.defaultEffects[0]), at: 0) }
        guard let i = colorEffectIndices.first else { return false }
        var e = effects[i].colorEffect(atLocal: t, id: 1)
        e.wheels = result.wheels
        e.setEnabled(.wheels, true)
        if let ev = result.exposure { e.basic.exposure = ev }
        effects[i].setColorEffect(e, atLocal: t)
        var d = effects[i].colorData
        d.match = reference
        effects[i].grade = d
        return true
    }
}
