import Foundation
import SQAnalysis
import SQCore

/// What a Stabilize run did.
public struct StabilizeOutcome: Sendable, Hashable {
    public var stabilized: Int
    /// Clips whose frames could not be read (offline, unreadable) or that were edited while they were analyzed.
    public var failed: Int
    /// Locked ("No Motion") clips that move too far to hold: some frames show the picture's edge.
    public var uncovered: Int
    /// The largest auto-scale crop written (share of each picture side), 0 when nothing was written.
    public var maxCrop: Double
    /// Clips left as shot because the measurement could not be trusted (too little detail) or would have added shake.
    public var leftAsShot: Int
    /// Clips steadied only in parts (some shots / stretches left as shot for the same reason).
    public var partly: Int
    /// Clips whose Stabilizer uses Gyroflow: not analyzed by the picture analysis (their engine runs elsewhere).
    public var gyroflow: Int
    public init(stabilized: Int, failed: Int, uncovered: Int = 0, maxCrop: Double = 0, leftAsShot: Int = 0, partly: Int = 0,
                gyroflow: Int = 0) {
        self.stabilized = stabilized; self.failed = failed; self.uncovered = uncovered; self.maxCrop = maxCrop
        self.leftAsShot = leftAsShot; self.partly = partly; self.gyroflow = gyroflow
    }
}

/// Stabilize (W9.7): measures the camera shake of the selected clips (Vision, `StabilizationAnalyzing`), smooths it in
/// SQCore (`Stabilizer`) and writes a Stabilizer effect: a transform stage with Position / Rotation / Scale keys (per-frame path,
/// decimated within a tolerance), applied to the clip's own picture before Motion (and before Transform / Auto Reframe). The user's Motion stays;
/// one undo step. A second run replaces the clip's Stabilizer (same id) and uses the settings stored on it (Result,
/// Smoothness, Crop Limit), so changing them in Effect Controls and running Stabilize again re-plans.
extension EditorSession {
    /// Same clips Auto Reframe works on: media video with a known picture size on unlocked tracks.
    public var stabilizeTargets: [Clip] { reframeTargets }

    /// Reads a cached analysis for a media file and source range (picture size as given); nil = not cached. Runs off the
    /// main actor; the app passes `StabilizationCache`.
    public typealias StabilizationLookup = @Sendable (MediaRef, TimeRange, _ width: Int, _ height: Int) async -> StabilizationAnalysis?

    /// Clips of the active sequence (unlocked tracks, media video) that carry a Stabilizer whose analysis does not cover
    /// what they show now (trimmed longer): the new frames would hold the last correction until Stabilize runs again.
    public func staleStabilizerClips() -> [Clip.ID] {
        guard let t = activeTimeline else { return [] }
        let fd = t.frameDuration
        return t.tracks.filter { !$0.isLocked }.flatMap(\.clips).compactMap { c in
            guard let e = c.effect(ofKind: ClipEffect.stabilizeKind), e.enabled, e.stabilizeMethod == .standard,
                  !c.isGenerator, c.sequence == nil,
                  let range = Self.stabilizeSourceRange(of: c, frameDuration: fd),
                  e.stabilizeNeedsAnalysis(of: range, frameDuration: fd) else { return nil }
            return c.id
        }
    }

    /// Re-plans a clip's Stabilizer from the cached analysis with the settings now stored on it (Result, Smoothness, Crop
    /// Limit), so changing them in Effect Controls takes effect at once without a new analysis. One undo step with the
    /// settings edit that caused it. False when nothing was written (no Stabilizer, analysis not cached, clip edited meanwhile).
    @discardableResult
    public func replanStabilizer(clip id: Clip.ID, lookup: StabilizationLookup) async -> Bool {
        guard let timeline = activeTimeline, let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == id }),
              let old = clip.effect(ofKind: ClipEffect.stabilizeKind), old.stabilizeMethod == .standard,
              let media = project.media(clip.media), let size = project.pictureSize(of: clip),
              let range = Self.stabilizeSourceRange(of: clip, frameDuration: timeline.frameDuration) else { return false }
        let fd = timeline.frameDuration
        let options = StabilizerOptions(effect: old)
        guard let analysis = await lookup(media, range, size.width, size.height), !Task.isCancelled else { return false }
        // Rolling Shutter switched on over an analysis from before the option: it has no row motion, analyze again
        // (job center, cancelable); the result then carries it and plans the correction.
        if options.rollingShutter, analysis.rolling.isEmpty, analysis.frameTimes.count > 1 {
            rollingShutterRequests[timeline.id, default: []].insert(id)
            onStabilizerNeedsAnalysis?(timeline.id, [id])
            return false
        }
        let built = await Task.detached(priority: .userInitiated) {
            Self.buildStabilizer(analysis: analysis, options: options, clip: clip, frameDuration: fd, id: old.id)
        }.value
        guard let (effect, _) = built, !Task.isCancelled else { return false }
        return !applyStabilizer([id: effect], in: timeline.id, expecting: [id: clip], coalescing: "clip:\(id):\(gestureCounter)").isEmpty
    }

    /// Re-plans several clips from their cached analyses with the settings now stored on them (the same as
    /// `replanStabilizer` for each), written as one undo step with the settings edit that caused it. Returns the clips written.
    @discardableResult
    public func replanStabilizers(clips ids: [Clip.ID], lookup: StabilizationLookup) async -> Set<Clip.ID> {
        guard let timeline = activeTimeline else { return [] }
        let fd = timeline.frameDuration
        var effects: [Clip.ID: ClipEffect] = [:]
        var snapshot: [Clip.ID: Clip] = [:]
        var needAnalysis: Set<Clip.ID> = []
        for id in ids {
            guard let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == id }),
                  let old = clip.effect(ofKind: ClipEffect.stabilizeKind), old.stabilizeMethod == .standard,
                  let media = project.media(clip.media), let size = project.pictureSize(of: clip),
                  let range = Self.stabilizeSourceRange(of: clip, frameDuration: fd) else { continue }
            let options = StabilizerOptions(effect: old)
            guard let analysis = await lookup(media, range, size.width, size.height), !Task.isCancelled else { continue }
            if options.rollingShutter, analysis.rolling.isEmpty, analysis.frameTimes.count > 1 { needAnalysis.insert(id); continue }
            let built = await Task.detached(priority: .userInitiated) {
                Self.buildStabilizer(analysis: analysis, options: options, clip: clip, frameDuration: fd, id: old.id)
            }.value
            guard let (effect, _) = built, !Task.isCancelled else { continue }
            effects[id] = effect; snapshot[id] = clip
        }
        if !needAnalysis.isEmpty {
            rollingShutterRequests[timeline.id, default: []].formUnion(needAnalysis)
            onStabilizerNeedsAnalysis?(timeline.id, needAnalysis)
        }
        guard !effects.isEmpty, !Task.isCancelled else { return [] }
        return applyStabilizer(effects, in: timeline.id, expecting: snapshot, coalescing: "clips:\(gestureCounter)")
    }

    /// Clips whose Stabilizer asked for an analysis while another one ran (Rolling Shutter switched on, an Analyze
    /// row): they wait here, per sequence, and run when it ends, so the option is never left on without its correction.
    /// The queue does not depend on which sequence is open.
    public func queueStabilizerAnalysis(_ ids: Set<Clip.ID>, in timeline: Timeline.ID? = nil) {
        guard let tid = timeline ?? activeTimelineID else { return }
        queuedStabilizerAnalysis[tid, default: []].formUnion(ids)
    }

    /// Hands out the queued clips of one sequence (default: the open one) and forgets them: those that still want the
    /// analysis (an unlocked track, an enabled Standard Stabilizer). Deleted clips and removed effects drop out.
    public func takeQueuedStabilizerAnalysis(in timeline: Timeline.ID? = nil) -> Set<Clip.ID> {
        guard let tid = timeline ?? activeTimelineID, let queued = queuedStabilizerAnalysis.removeValue(forKey: tid) else { return [] }
        return wantingStabilizerAnalysis(queued, in: tid)
    }

    /// The next sequence with queued clips that still want the analysis; the other sequences stay queued.
    public func takeNextQueuedStabilizerAnalysis() -> (timeline: Timeline.ID, clips: Set<Clip.ID>)? {
        for tid in Array(queuedStabilizerAnalysis.keys) {
            guard let queued = queuedStabilizerAnalysis.removeValue(forKey: tid) else { continue }
            let wanted = wantingStabilizerAnalysis(queued, in: tid)
            if !wanted.isEmpty { return (tid, wanted) }
        }
        return nil
    }

    private func wantingStabilizerAnalysis(_ queued: Set<Clip.ID>, in tid: Timeline.ID) -> Set<Clip.ID> {
        guard !queued.isEmpty, let t = project.timeline(tid) else { rollingShutterRequests[tid] = nil; return [] }
        let wanted = Set(t.tracks.filter { !$0.isLocked }.flatMap(\.clips).filter { c in
            guard queued.contains(c.id), let e = c.effect(ofKind: ClipEffect.stabilizeKind) else { return false }
            return e.enabled && e.stabilizeMethod == .standard
        }.map(\.id))
        // A clip that leaves the queue without running no longer waits for a correction.
        rollingShutterRequests[tid]?.subtract(queued.subtracting(wanted))
        return wanted
    }

    /// Forgets the queue (the running analysis was canceled: nothing follows by itself) and switches Rolling Shutter
    /// back off for the clips that waited for it.
    public func dropQueuedStabilizerAnalysis() {
        queuedStabilizerAnalysis = [:]
        withdrawRollingShutterRequests()
    }

    /// A canceled (or failed) analysis leaves Rolling Shutter on without its correction, and the next Smoothness edit
    /// would start the analysis again: Cancel switches the option back off for the clips that asked for it (`clips`
    /// nil = all of them, in every sequence), one undo step. The cached analysis stays, so settings re-plan at once.
    public func withdrawRollingShutterRequests(clips: Set<Clip.ID>? = nil) {
        let requests = rollingShutterRequests.mapValues { ids in clips.map { ids.intersection($0) } ?? ids }
            .filter { !$0.value.isEmpty && project.timeline($0.key) != nil }
        if let clips {
            for tid in rollingShutterRequests.keys { rollingShutterRequests[tid]?.subtract(clips) }
        } else { rollingShutterRequests = [:] }
        guard !requests.isEmpty else { return }
        do {
            try perform("Rolling Shutter") { p in
                for (tid, ids) in requests {
                    try p.edit(tid) { t in
                        for tr in t.tracks where !tr.isLocked {
                            for c in tr.clips where ids.contains(c.id) {
                                var n = c
                                guard let i = n.effects.firstIndex(where: { $0.kind == ClipEffect.stabilizeKind }),
                                      n.effects[i].parameters[ClipEffect.rollingShutterKey]?.value ?? 0 >= 0.5 else { continue }
                                n.effects[i].parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(0)
                                try t.replaceClip(n)
                            }
                        }
                    }
                }
            }
        } catch { setError(Self.message(for: error)) }
    }

    /// Re-plans after a short pause (a slider drag changes the settings many times); a newer call replaces the pending one.
    public func scheduleStabilizerReplan(clip id: Clip.ID, lookup: @escaping StabilizationLookup) {
        stabilizerReplanTask?.cancel()
        stabilizerReplanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await replanStabilizer(clip: id, lookup: lookup)
        }
    }

    /// Several clips at once: one pause, one write, one undo step.
    public func scheduleStabilizerReplan(clips ids: [Clip.ID], lookup: @escaping StabilizationLookup) {
        stabilizerReplanTask?.cancel()
        stabilizerReplanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await replanStabilizers(clips: ids, lookup: lookup)
        }
    }

    /// The source range a clip shows (through speed, reverse and time remapping), one sequence frame longer than the last
    /// source time shown so its frame is read.
    static func stabilizeSourceRange(of clip: Clip, frameDuration fd: Time) -> TimeRange? {
        let frames = clip.duration.frameIndex(frameDuration: fd)
        guard frames > 0 else { return nil }
        var lo = clip.sourceTime(at: clip.start, frameDuration: fd), hi = lo
        for i in 1..<max(frames, 1) {
            let s = clip.sourceTime(at: clip.start + fd * i, frameDuration: fd)
            if s < lo { lo = s }
            if hi < s { hi = s }
        }
        if lo.isNegative { lo = .zero }
        return TimeRange(start: lo, end: max(hi, lo) + fd)
    }

    /// Analyzes every target clip with the analyzer `analyzer(media)` returns (nil = skip as failed), then writes all
    /// Stabilizer effects as one undo step "Stabilize". `options`: nil = each clip's stored settings (defaults for a
    /// clip without a Stabilizer). `progress` gets 0...1 over the whole run. Throws `CancellationError` when the task is
    /// canceled; nothing is written then.
    public func stabilize(options: StabilizerOptions? = nil, only: Set<Clip.ID>? = nil, in timelineID: Timeline.ID? = nil,
                          progress: (@Sendable (Double) -> Void)? = nil,
                          analyzer: (MediaRef) -> (any StabilizationAnalyzing)?) async throws -> StabilizeOutcome {
        // A target sequence that is gone ends the run; only "no sequence given" means the open one.
        let found: Timeline? = timelineID.map { project.timeline($0) } ?? activeTimeline
        guard let timeline = found else { return StabilizeOutcome(stabilized: 0, failed: 0) }
        let fd = timeline.frameDuration
        let targets = only.map { ids in
            let locked = Set(timeline.tracks.filter(\.isLocked).flatMap(\.clips).map(\.id))
            return timeline.tracks.flatMap(\.clips).filter { ids.contains($0.id) && !locked.contains($0.id) && !$0.isGenerator
                && $0.sequence == nil && !$0.isStill && $0.holdFrame == nil }
        } ?? stabilizeTargets
        // A Gyroflow Stabilizer is never re-planned from the picture analysis (explicit Standard options still switch it back).
        let gyro = Set(targets.filter { options == nil && $0.effect(ofKind: ClipEffect.stabilizeKind)?.stabilizeMethod == .gyroflow }.map(\.id))
        let jobs = targets.filter { !gyro.contains($0.id) }.compactMap { c -> (Clip, TimeRange, MediaRef, (width: Int, height: Int))? in
            guard let m = project.media(c.media), let size = project.pictureSize(of: c),
                  let range = Self.stabilizeSourceRange(of: c, frameDuration: fd) else { return nil }
            return (c, range, m, size)
        }
        var outcome = StabilizeOutcome(stabilized: 0, failed: 0, gyroflow: gyro.count)
        var effects: [Clip.ID: (ClipEffect, StabilizationPlan)] = [:]
        let n = Double(max(jobs.count, 1))
        for (i, (clip, range, media, size)) in jobs.enumerated() {
            guard let a = analyzer(media) else { outcome.failed += 1; continue }
            let base = Double(i)
            let o = options ?? clip.effect(ofKind: ClipEffect.stabilizeKind).map(StabilizerOptions.init(effect:)) ?? StabilizerOptions()
            do {
                let analysis = try await a.analyze(sourceRange: range, pictureWidth: size.width, pictureHeight: size.height,
                                                   rolling: o.rollingShutter) { p in
                    progress?((base + p) / n)
                }
                let id = clip.effect(ofKind: ClipEffect.stabilizeKind)?.id ?? UUID()
                // Smoothing, crop solve and key building are O(frames x radius): off the main actor, back only to apply.
                let built = await Task.detached(priority: .userInitiated) {
                    Self.buildStabilizer(analysis: analysis, options: o, clip: clip, frameDuration: fd, id: id)
                }.value
                guard let built else { outcome.failed += 1; continue }
                effects[clip.id] = built
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome.failed += 1
            }
        }
        try Task.checkCancellation()
        let snapshot = Dictionary(uniqueKeysWithValues: jobs.map { ($0.0.id, $0.0) })
        let written = applyStabilizer(effects.mapValues(\.0), in: timeline.id, expecting: snapshot)
        outcome.stabilized = written.count
        // Written clips have their correction. A clip that asked for Rolling Shutter but failed or was skipped keeps the
        // option on without it: switch it back off (one undo step) so the next edit does not analyze again.
        let asked = (rollingShutterRequests[timeline.id] ?? []).intersection(targets.map(\.id))
        rollingShutterRequests[timeline.id]?.subtract(asked)
        let unwritten = asked.subtracting(written)
        if !unwritten.isEmpty {
            rollingShutterRequests[timeline.id, default: []].formUnion(unwritten)
            withdrawRollingShutterRequests(clips: unwritten)
        }
        outcome.failed += effects.count - written.count
        for id in written {
            guard let plan = effects[id]?.1 else { continue }
            outcome.maxCrop = max(outcome.maxCrop, plan.crop)
            if !plan.fullyCovered { outcome.uncovered += 1 }
            if plan.uncorrectedFrames >= plan.corrections.count { outcome.leftAsShot += 1 }
            else if plan.uncorrectedFrames > 0 { outcome.partly += 1 }
        }
        return outcome
    }

    /// Stabilize dropped from the Effects panel (or Effect Controls): adds a fresh Stabilizer where a clip has none (one
    /// undo step "Add Stabilizer"). It does NOT start an analysis: the clip waits idle until the user presses Start (they may
    /// choose Gyroflow instead, and a default analysis would be wasted). True when a target can carry one.
    public func addStabilizer(to ids: Set<Clip.ID>) -> Bool {
        guard let t = activeTimeline else { return false }
        let locked = Set(t.tracks.filter(\.isLocked).flatMap(\.clips).map(\.id))
        let targets = t.tracks.flatMap(\.clips).filter { ids.contains($0.id) && $0.canStabilize && !locked.contains($0.id) }
        guard !targets.isEmpty else { return false }
        let defaults = effectDefaults
        if targets.contains(where: { $0.stabilizerID == nil }) {
            guard attempt("Add Stabilizer", { tl in
                for c in targets where c.stabilizerID == nil {
                    guard var n = tl.tracks.lazy.flatMap(\.clips).first(where: { $0.id == c.id }),
                          n.addEffect(kind: ClipEffect.stabilizeKind, defaults: defaults) != nil else { continue }
                    try tl.replaceClip(n)
                }
            }) else { return false }
        }
        return true
    }

    /// True when a running analysis has nothing left to write: a clip that carried a Stabilizer when it started lost it, or
    /// is gone (effect removed, clip deleted), in any sequence. `clips` are the run's clips, `watching` those that carried one.
    public func stabilizeRunIsObsolete(clips: Set<Clip.ID>, watching: Set<Clip.ID>) -> Bool {
        guard !watching.isEmpty else { return false }
        let live = Set(project.timelines.flatMap(\.tracks).flatMap(\.clips).filter { $0.stabilizerID != nil }.map(\.id))
        return watching.isDisjoint(with: live)
    }

    /// Plans the correction and builds the Stabilizer effect (decimated keys). Pure and nonisolated, so a run does it off
    /// the main actor. nil when the analysis is too short to plan.
    nonisolated static func buildStabilizer(analysis: StabilizationAnalysis, options: StabilizerOptions, clip: Clip,
                                            frameDuration fd: Time, id: UUID) -> (ClipEffect, StabilizationPlan)? {
        guard let plan = Stabilizer.plan(analysis, options: options) else { return nil }
        return (Stabilizer.effect(plan: plan, analysis: analysis, clip: clip, frameDuration: fd, options: options, id: id), plan)
    }

    /// Writes the Stabilizer effects as one undo step "Stabilize": replaces a clip's Stabilizer, else inserts it before the
    /// clip's first other transform stage. Clips that are gone, on a locked track, or no longer match `expecting` (see
    /// `reframeStillFits`: keys are per clip frame), or whose Stabilizer changed since the snapshot are skipped. A replaced
/// Stabilizer keeps its `enabled` flag. Returns the clips written.
    @discardableResult
    func applyStabilizer(_ effects: [Clip.ID: ClipEffect], in timeline: Timeline.ID? = nil,
                         expecting: [Clip.ID: Clip]? = nil, coalescing: String? = nil) -> Set<Clip.ID> {
        guard !effects.isEmpty, let tid = timeline ?? activeTimelineID else { return [] }
        var written: Set<Clip.ID> = []
        do {
            try perform("Stabilize", coalescing: coalescing) { p in
                written = []
                try p.edit(tid) { t in
                    for tr in t.tracks where !tr.isLocked {
                        for c in tr.clips {
                            guard let e = effects[c.id] else { continue }
                            if let old = expecting?[c.id] {
                                guard Self.reframeStillFits(c, old) else { continue }
                                // The Stabilizer was changed (settings, removed, added) while it was analyzed: the plan
                                // used the old settings, so leave the user's edit alone.
                                guard c.effect(ofKind: ClipEffect.stabilizeKind) == old.effect(ofKind: ClipEffect.stabilizeKind) else { continue }
                            }
                            var n = c
                            if let i = n.effects.firstIndex(where: { $0.kind == ClipEffect.stabilizeKind }) {
                                var e = e
                                e.enabled = n.effects[i].enabled    // a re-run never switches a disabled Stabilizer back on
                                // A keyframed Rolling Shutter Strength keeps its keys (the plan only knows its value).
                                if let strength = n.effects[i].parameters[ClipEffect.rollingShutterStrengthKey], strength.isAnimated {
                                    e.parameters[ClipEffect.rollingShutterStrengthKey] = strength
                                }
                                n.effects[i] = e
                            } else {
                                n.effects.insert(e, at: Stabilizer.insertionIndex(in: n.effects))
                            }
                            if n != c { try t.replaceClip(n) }
                            written.insert(c.id)
                        }
                    }
                }
            }
        } catch { setError(Self.message(for: error)); return [] }
        return written
    }
}
