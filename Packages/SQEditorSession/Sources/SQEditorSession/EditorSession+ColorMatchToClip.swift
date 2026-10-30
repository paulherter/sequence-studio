import Foundation
import SQUIKit
import SQCore

/// Clip > Video Options > Match Color to Clip: the one-shot Color Match. The session picks target and reference
/// (`Timeline.colorMatchPair`), hands the host a solo view of each clip to render and sample, and writes the result
/// (Exposure + Color Wheels on the target's first Color effect) as one undo step.
public enum ColorMatchToClipPlan: Sendable, Equatable {
    case ready(ColorMatchPair)
    case blocked(String)
}

public enum ColorMatchToClipOutcome: Sendable, Equatable {
    case applied
    /// The target already looks like the reference: nothing written.
    case alreadyMatches
    /// A frame gave too few usable samples (black, offline).
    case unreadable
}

extension EditorSession {
    public static let colorMatchNoTarget = "Select a video clip to match its color."
    public static let colorMatchNoReference =
        "Nothing to match to: put a clip on another track under the playhead, or a clip before this one on its track."

    /// The clip the command grades: of the selected video clips (else the clips under the playhead) the one under the
    /// playhead on the highest track, else the last one.
    var colorMatchTarget: Clip? {
        let locked = Set(activeTimeline?.tracks.filter(\.isLocked).flatMap(\.clips).map(\.id) ?? [])
        let all = commandClips(kind: .video).filter { $0.isColorMatchPicture && $0.acceptsColor && !locked.contains($0.id) }
        return all.last { $0.timeline.contains(playhead) } ?? all.last
    }

    /// Menu enabling: there is a clip to grade (the command reports any other problem).
    public var hasColorMatchTarget: Bool { colorMatchTarget != nil }

    /// What the command would do now, or why it cannot.
    public func colorMatchToClipPlan() -> ColorMatchToClipPlan {
        guard let t = activeTimeline, let target = colorMatchTarget else { return .blocked(Self.colorMatchNoTarget) }
        let source = colorSource(of: target)
        if source != .rec709 {
            return .blocked(SQL10n.format("Match works on Rec. 709 footage. This clip is interpreted as %@; grade it by hand.", source.displayName))
        }
        if let e = target.colorGradeEffects.first?.colorEffect(atLocal: nil, id: 1), e.isEnabled(.vignette), !e.isNeutral(.vignette) {
            return .blocked("Match would measure the Vignette too. Reset or switch off Vignette first.")
        }
        guard let pair = t.colorMatchPair(target: target.id, playhead: playhead) else { return .blocked(Self.colorMatchNoReference) }
        return .ready(pair)
    }

    /// The sequence as the engine shows it with only clip `id` visible: its raw picture plus its grade, fitted into the frame
    /// (`Timeline.soloingVideoClip`, the Color page's solo).
    public func colorMatchSoloTimeline(_ id: Clip.ID) -> Timeline? {
        guard let tid = activeTimelineID, let (t, _) = project.variantView(of: tid, variant: activeVariantID),
              let c = t.tracks.lazy.compactMap({ $0.clips.first { $0.id == id } }).first else { return nil }
        return t.soloingVideoClip(id, picture: project.pictureSize(of: c))
    }

    /// Shows the solo view of `id` at sequence time `at` in the Program engine (for one frame capture).
    public func showColorMatchSolo(_ id: Clip.ID, at: Time) -> Bool {
        guard let tid = activeTimelineID, let (_, nested) = project.variantView(of: tid, variant: activeVariantID),
              let solo = colorMatchSoloTimeline(id) else { return false }
        engine.setTimeline(solo, sequences: nested)
        engine.seek(to: at)
        return true
    }

    /// Puts the sequence back into the engine at the playhead after `showColorMatchSolo`.
    public func endColorMatchSolo() {
        pushTimeline(force: true)
        engine.seek(to: colorSourceView?.position ?? playhead)
    }

    /// Solves and writes the match from the two sampled frames (display-encoded RGB). One undo step "Match Color to Clip".
    @discardableResult
    public func applyColorMatchToClip(_ pair: ColorMatchPair, reference: [SIMD3<Float>], target: [SIMD3<Float>])
        -> ColorMatchToClipOutcome {
        guard let tl = activeTimeline,
              let clip = tl.tracks.lazy.compactMap({ $0.clips.first { $0.id == pair.target } }).first,
              let refStats = ColorMatchStats.measure(ColorMatchSolver.pictureSamples(reference)) else { return .unreadable }
        let samples = ColorMatchSolver.pictureSamples(target)
        guard samples.count >= 16 else { return .unreadable }
        let local = min(max(pair.targetTime - clip.start, .zero), max(clip.duration - tl.frameDuration, .zero))
        let effect = clip.colorGradeEffects.first?.colorEffect(atLocal: local, id: 1) ?? ClipColor.defaultEffects[0]
        guard let result = ColorMatchSolver.solveClip(display: samples, effect: effect, reference: refStats) else {
            return .alreadyMatches
        }
        let refName = tl.tracks.lazy.compactMap({ $0.clips.first { $0.id == pair.reference } }).first?.name ?? "Clip"
        let tc = TimecodeFormat(frameDuration: tl.frameDuration).string(for: pair.referenceTime, frameDuration: tl.frameDuration)
        let ref = ColorMatchReference(clip: pair.reference, time: pair.referenceTime, label: "\(refName) \(tc)", stats: refStats)
        let ok = attempt("Match Color to Clip") { t in
            var c = clip
            guard c.applyColorMatch(result, reference: ref, atLocal: local) else { throw EditError.emptyClip }
            try t.replaceClip(c)
        }
        return ok ? .applied : .alreadyMatches
    }
}
