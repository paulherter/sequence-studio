import Foundation
import SQAnalysis
import SQCore

/// What an Auto Reframe run did.
public struct ReframeOutcome: Sendable, Hashable {
    public var reframed: Int
    /// Clips in which no face, person or salient object was found (left alone).
    public var noSubject: Int
    /// Clips whose frames could not be read (offline, unreadable).
    public var failed: Int
    /// Clips whose picture already fills the frame exactly (same shape): nothing to reframe, left alone.
    public var alreadyFramed: Int
    /// Clips whose read hung (a decoder or Vision call that never answered, `BlockingLane.Stalled`): given up, left alone.
    public var stalled: Int
    public init(reframed: Int, noSubject: Int, failed: Int, alreadyFramed: Int = 0, stalled: Int = 0) {
        self.reframed = reframed; self.noSubject = noSubject; self.failed = failed; self.alreadyFramed = alreadyFramed
        self.stalled = stalled
    }
}

/// Auto Reframe (W4.2, W7.1): analyzes the selected clips' pictures and writes an Auto Reframe effect (Position keys plus a
/// cover Scale, as a transform stage on top of Motion) that keeps the subject in the active sequence's frame. The user's
/// Motion values and keys are left alone; the stage's keys are editable in Effect Controls; one undo step.
/// With a format variant active (W5.1) the frame is the variant's and the values go into that variant's effect overrides.
extension EditorSession {
    /// Clips Auto Reframe works on: the command clips (selection, else under the playhead) that show media video with a
    /// known picture size, on unlocked tracks. Generators, nested sequences, stills and held frames are skipped.
    public var reframeTargets: [Clip] {
        guard let t = activeTimeline else { return [] }
        let locked = Set(t.tracks.filter(\.isLocked).flatMap(\.clips).map(\.id))
        return commandClips(kind: .video).filter {
            !$0.isGenerator && $0.sequence == nil && !$0.isStill && $0.holdFrame == nil && !locked.contains($0.id)
                && project.pictureSize(of: $0) != nil
        }
    }

    /// Crop-window geometry of `clip` in the active sequence, in the active variant's frame when one is shown (its
    /// current static anchor, as that variant shows it, is kept).
    public func reframeGeometry(for clip: Clip, options: ReframeOptions = ReframeOptions()) -> ReframeGeometry? {
        guard let t = activeTimeline, let size = project.pictureSize(of: clip) else { return nil }
        let v = activeVariantID, frame = t.format(for: v)
        return ReframeGeometry(pictureWidth: size.width, pictureHeight: size.height,
                               frameWidth: frame.width, frameHeight: frame.height,
                               anchor: t.resolvedClip(clip, variant: v).transform(at: clip.start).anchor, zoom: options.zoom)
    }

    /// Analyzes every target clip with the detector `detector(media)` returns (nil = skip as failed), then applies all
    /// plans as one undo step. `progress` gets 0...1 over the whole run. Throws `CancellationError` when the task is
    /// canceled; nothing is applied then.
    public func autoReframe(options: ReframeOptions = ReframeOptions(),
                            progress: (@Sendable (Double) -> Void)? = nil,
                            detector: (MediaRef) -> (any SubjectDetecting)?) async throws -> ReframeOutcome {
        guard let timeline = activeTimeline else { return ReframeOutcome(reframed: 0, noSubject: 0, failed: 0) }
        let variant = activeVariantID                  // captured: switching the monitor meanwhile does not redirect the keys
        var outcome = ReframeOutcome(reframed: 0, noSubject: 0, failed: 0)
        let jobs = reframeTargets.compactMap { c -> (Clip, ReframeGeometry, [ReframeSample], MediaRef)? in
            guard let g = reframeGeometry(for: c, options: options), let m = project.media(c.media) else { return nil }
            if g.isAlreadyFramed { outcome.alreadyFramed += 1; return nil }
            return (c, g, ReframeSampling.samples(for: c, frameDuration: timeline.frameDuration, interval: options.sampleInterval), m)
        }
        var plans: [Clip.ID: ReframePlan] = [:]
        let n = Double(max(jobs.count, 1))
        for (i, (clip, geometry, samples, media)) in jobs.enumerated() {
            guard let d = detector(media) else { outcome.failed += 1; continue }
            let base = Double(i)
            do {
                let found = try await ReframeAnalyzer.detect(samples: samples, using: d) { p in progress?((base + p) / n) }
                if let plan = ReframePlanner.plan(detections: found, geometry: geometry, options: options) {
                    plans[clip.id] = plan
                } else {
                    outcome.noSubject += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch is BlockingLane.Stalled {
                outcome.stalled += 1
            } catch {
                outcome.failed += 1
            }
        }
        try Task.checkCancellation()
        let snapshot = Dictionary(uniqueKeysWithValues: jobs.map { ($0.0.id, $0.0) })
        let r = applyReframe(plans, in: timeline.id, expecting: snapshot, format: timeline.format(for: variant), variant: variant)
        outcome.reframed = r.applied
        outcome.failed += r.stale
        return outcome
    }

    /// The plan of `old` still fits `live`: same timing, time mapping and anchor (keys are clip-local, framing uses
    /// the anchor; in a variant also the variant's anchor override). Anything else means the clip was edited while it
    /// was analyzed.
    static func reframeStillFits(_ live: Clip, _ old: Clip, variant: FormatVariant.ID? = nil) -> Bool {
        live.start == old.start && live.duration == old.duration && live.source == old.source && live.speed == old.speed
            && live.reversed == old.reversed && live.speedKeys == old.speedKeys && live.holdFrame == old.holdFrame
            && live.animation.anchor == old.animation.anchor
            && variant.map { live.variantOverrides[$0]?.anchor == old.variantOverrides[$0]?.anchor } ?? true
    }

    /// Writes the plans (Position, uniform Scale) into the clips' Auto Reframe stage as one undo step "Auto Reframe". Clips
    /// that are gone or now sit on a locked track are skipped. False when nothing was written. Default timeline: the active
    /// one. The Motion fx toggle is left as it is (the stage renders either way).
    @discardableResult
    public func applyReframe(_ plans: [Clip.ID: ReframePlan], in timeline: Timeline.ID? = nil) -> Bool {
        applyReframe(plans, in: timeline, expecting: nil, format: nil, variant: nil).applied > 0
    }

    /// `expecting`: the clips as they were when the analysis started; a clip that differs now (see `reframeStillFits`),
    /// or every clip when the sequence format is no longer `format`, is skipped and counted as stale (so are clips that
    /// are gone or now on a locked track). `variant`: the keys go into that variant's override (Position, Scale) and
    /// `format` is compared with the variant's canvas; a variant that is gone makes every clip stale.
    func applyReframe(_ plans: [Clip.ID: ReframePlan], in timeline: Timeline.ID?, expecting: [Clip.ID: Clip]?,
                      format: SequenceFormat?, variant: FormatVariant.ID?) -> (applied: Int, stale: Int) {
        guard !plans.isEmpty, let tid = timeline ?? activeTimelineID else { return (0, 0) }
        if let variant, project.timeline(tid)?.variant(variant) == nil { return (0, plans.count) }
        if let format, project.timeline(tid)?.format(for: variant) != format { return (0, plans.count) }
        var applied = 0
        do {
            try perform("Auto Reframe") { p in
                applied = 0
                try p.edit(tid) { t in
                    for tr in t.tracks where !tr.isLocked {
                        for c in tr.clips {
                            guard let plan = plans[c.id] else { continue }
                            if let old = expecting?[c.id], !Self.reframeStillFits(c, old, variant: variant) { continue }
                            var n = c
                            // W7.1: the framing is an Auto Reframe effect stage on top of Motion; the user's Motion values
                            // and keys stay. A second run replaces the clip's stage (keeps its id, so variant overrides of
                            // it keep pointing at it).
                            let existing = n.effects.firstIndex { $0.kind == ClipEffect.reframeKind }
                            let id = existing.map { n.effects[$0].id } ?? UUID()
                            let shown = variant.map { t.resolvedClip(c, variant: $0) } ?? c
                            let stage = EffectTransformStage.reframeEffect(scale: plan.scale, position: plan.position,
                                                                           base: shown.transform(at: shown.start), id: id)
                            if let variant {
                                // The variant's own framing (effect-parameter overrides); the base clip and the other
                                // variants keep theirs. A new stage on the base starts at identity.
                                if existing == nil { var e = stage; e.parameters = ClipEffect.defaultParameters(for: e.kind); n.effects.append(e) }
                                var o = n.variantOverrides[variant] ?? VariantOverride()
                                o.effectParameters[id] = stage.parameters
                                n.variantOverrides[variant] = o
                            } else if let i = existing {
                                n.effects[i] = stage
                            } else {
                                n.effects.append(stage)
                            }
                            if n != c { try t.replaceClip(n) }
                            applied += 1
                        }
                    }
                }
            }
        } catch { setError(Self.message(for: error)); return (0, 0) }
        // Clips deleted or moved to a locked track meanwhile count as stale too.
        return (applied, plans.count - applied)
    }
}
