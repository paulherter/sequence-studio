import Foundation

/// "Punch In Cuts": alternating or cycling zoom levels over consecutive shots, written as the same marked Punch In stage
/// as Shift+P (one punch system: toggle and remove work alike), so no file format change.
public struct PunchInCutsOptions: Sendable, Hashable {
    public enum Pattern: String, Sendable, Hashable, CaseIterable { case alternate, cyclic }
    public enum Ease: String, Sendable, Hashable, CaseIterable {
        /// Hard cut to the level (static scale).
        case hold
        case linear, easeInOut, fastStart
        public var title: String {
            switch self { case .hold: EaseName.hold; case .linear: EaseName.steady; case .easeInOut: EaseName.smooth; case .fastStart: EaseName.fastStart }
        }
    }
    /// Percent choices offered by the sheet.
    public static let scaleChoices: [Double] = [100, 110, 115, 126.5]

    /// Selected levels in percent.
    public var scales: [Double]
    public var ease: Ease
    public var pattern: Pattern
    /// Length of the eased ramp from the previous shot's level (ignored for `.hold`).
    public var rampFrames: Int

    public init(scales: [Double], ease: Ease = .hold, pattern: Pattern = .alternate, rampFrames: Int = 6) {
        self.scales = scales; self.ease = ease; self.pattern = pattern; self.rampFrames = rampFrames
    }

    /// Zoom factors in play order: alternate = 100% and the smallest selected level above it; cyclic = the selected levels ascending.
    var levels: [Double] {
        let sorted = Array(Set(scales.filter { $0 > 0 })).sorted()
        switch pattern {
        case .alternate:
            guard let top = sorted.first(where: { $0 > 100 }) else { return [] }
            return [1, top / 100]
        case .cyclic:
            return sorted.count < 2 ? [] : sorted.map { $0 / 100 }
        }
    }
}

extension Timeline {
    /// Applies the zoom pattern to the video clips `ids`, ordered by start (one atomic edit). Each zoomed clip gets
    /// the Punch In stage (marker `PunchIn.markerKey`, Transform stage, multiplies onto Motion); an existing one is updated, never
    /// stacked. `.hold` is a static scale; an eased `ease` ramps from the previous shot's level over `rampFrames` at the clip's
    /// head. Motion keys are left alone (old projects that used them keep rendering). Returns the clips changed.
    /// Throws `.clipNotFound`, `.wrongTrackKind` (non-video or generator) and `.trackLocked`; nothing changes then.
    @discardableResult
    public mutating func punchInCuts(_ ids: [Clip.ID], _ options: PunchInCutsOptions) throws -> Int {
        var work = self
        var found: [(track: Int, clip: Clip)] = []
        for id in ids {
            guard let m = work.find(id) else { throw EditError.clipNotFound }
            guard m.clip.kind == .video, !m.clip.isGenerator else { throw EditError.wrongTrackKind }
            guard !work.tracks[m.track].isLocked else { throw EditError.trackLocked }
            found.append((m.track, m.clip))
        }
        let levels = options.levels
        guard !levels.isEmpty, !found.isEmpty else { return 0 }
        found.sort { $0.clip.start < $1.clip.start }
        var changed = 0
        for (i, f) in found.enumerated() {
            var c = f.clip
            let factor = levels[i % levels.count]
            let prev = i == 0 ? factor : levels[(i - 1) % levels.count]
            let hold = options.ease == .hold || prev == factor || options.rampFrames <= 0
            var prop: AnimatedProperty<Double>
            if hold {
                guard factor != 1 else {
                    // A 100% shot carries no stage: an earlier run's Punch In stage comes off, nothing else is touched.
                    let before = c.effects.count
                    c.effects.removeAll { PunchIn.isPunchIn($0, of: c.id) }
                    if c.effects.count != before { work.tracks[f.track].replace(c); changed += 1 }
                    continue
                }
                // Zoomed by the old Punch In Cuts (static Motion scale already at this level): do not stack 1.15 x 1.15.
                let motion = c.animation.scale
                if !motion.isAnimated, abs(motion.value.x - factor) < 1e-9, abs(motion.value.y - factor) < 1e-9 { continue }
                prop = AnimatedProperty(100 * factor)
            } else {
                let ramp = min(frameDuration * Int64(options.rampFrames), c.duration)
                var a = Keyframe(time: .zero, value: 100 * prev)
                var b = Keyframe(time: ramp, value: 100 * factor)
                switch options.ease {
                case .hold, .linear: break
                case .easeInOut: EasingCurve.easeInOut.apply(to: &a); EasingCurve.easeInOut.apply(to: &b)
                case .fastStart: EasingCurve.fastStart.apply(to: &a); EasingCurve.fastStart.apply(to: &b)
                }
                prop = AnimatedProperty(100 * factor)
                prop.track.insert(a); prop.track.insert(b)
            }
            if let idx = c.effects.firstIndex(where: { PunchIn.isPunchIn($0, of: c.id) }) {
                c.effects[idx].parameters[ClipEffect.stageScaleKey] = prop
            } else if let e = PunchIn.makeStage(for: c.id, scale: prop) {
                c.effects.append(e)
            } else { continue }
            work.tracks[f.track].replace(c)
            changed += 1
        }
        self = work
        return changed
    }
}
