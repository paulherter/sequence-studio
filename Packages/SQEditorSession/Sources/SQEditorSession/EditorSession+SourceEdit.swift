import Foundation
import SQCore

extension EditorSession {
    /// Source Monitor Insert (`,`) / Overwrite (`.`): the source's In..Out (whole media when unmarked) lands at the
    /// sequence In point, else at the playhead, on the patched tracks (`sourcePatch`, `Timeline.sourcePatchTargets`; track
    /// targeting does not decide this). Place on Top picks its own video track but honors a disconnected video patch.
    /// Afterwards the playhead sits at the end of the new clip (Premiere). One undo step. Returns false when nothing was placed.
    @discardableResult
    public func sourceEdit(media id: MediaRef.ID, marks: SourceMarks? = nil, streams: SourceStreams = .both,
                           mode: ThreePointMode, placeOnTop: Bool = false, backtimed: Bool = false,
                           fitToFill: Bool = false, fourPointFit: FourPointFit = .trimSourceEnd) -> Bool {
        guard let t = activeTimeline, let ref = project.media(id) else { return false }
        if backtimed, !(placeOnTop && t.isFastCut) { setError("Attach Backtimed needs a Fast Cut sequence."); return false }
        if backtimed, t.mainTrackEnd <= .zero { setError("Attach Backtimed needs a clip on the main track."); return false }
        let still = ref.info?.isStill == true
        guard let total = still ? Time(5, 1) : (ref.info?.duration ?? ref.duration) else { return false }
        let m = marks ?? project.sourceMarks(for: id)
        guard let source = still ? TimeRange(start: .zero, duration: total) : Timeline.sourceEditRange(marks: m, total: total) else {
            setError("Nothing to edit: the In and Out points leave no range."); return false
        }
        let adopts = !t.formatLocked && t.tracks.allSatisfy { $0.clips.isEmpty }
        let hasVideo = ref.info?.video != nil || ref.info == nil
        let hasAudio = ref.info?.audio != nil
        var endTime = Time.zero
        var noTarget = false
        let patch = sourcePatch
        var fourPoint = false
        var needsSequenceRange = false
        let done = attempt(backtimed ? "Attach Backtimed" : fitToFill ? "Fit to Fill" : mode == .insert ? "Insert" : "Overwrite") { tl in
            if adopts, let v = ref.info?.video {
                tl.format = SequenceFormat(width: v.displayWidth, height: v.displayHeight,
                                           frameDuration: still ? tl.format.frameDuration : v.nominalFrameDuration,
                                           audioSampleRate: tl.format.audioSampleRate).sanitized(fallback: tl.format)
            }
            // Place on Top ignores the patched track: video only, picked below once the length is known.
            var targets: [Track.ID] = []
            if !placeOnTop {
                guard let found = tl.sourcePatchTargets(patch, hasVideo: hasVideo, hasAudio: hasAudio, streams: streams) else {
                    noTarget = true; throw EditError.clipNotFound
                }
                targets = found
            } else if !hasVideo || !streams.includesVideo {
                throw EditError.clipNotFound
            } else if !patch.video.isConnected {
                noTarget = true; throw EditError.clipNotFound
            }
            let fit = ref.info?.video.map { tl.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
            // Attach Backtimed: the sequence In/Out play no part. The length is the source In..Out (or the whole clip), whole
            // frames; the clip ends at the playhead, its head is cut when there is no room before the sequence start.
            if backtimed {
                guard let plan = Timeline.sourceEditPlan(sourceMarks: m, total: total, sequenceIn: nil, sequenceOut: nil,
                                                         playhead: self.playhead, frameDuration: tl.frameDuration, isStill: still)
                else { throw EditError.emptyClip }
                // Never on the main track: the clip ends at the playhead, at most at the main track's end.
                let end = min(self.playhead.snapped(to: tl.frameDuration), tl.mainTrackEnd), d = plan.source.duration
                guard end > .zero else { throw EditError.emptyClip }
                switch tl.placeOnTopTarget(in: TimeRange(start: max(end - d, .zero), duration: min(d, end))) {
                case .existing(let id): targets = [id]
                case .newTrack: targets = [tl.addTrack(kind: .video)]
                }
                try tl.threePointEdit(source: plan.source, media: id, name: ref.name, mediaDuration: still ? nil : total,
                                      isStill: still, initialScale: fit, targets: targets, at: end, mode: mode, backtimed: true)
                endTime = end
                return
            }
            // Split In points (Mark Audio In / Mark Video In): picture and sound start apart, end together, linked.
            if !still, !placeOnTop, !fitToFill, streams == .both, hasVideo, hasAudio, !tl.isFastCut,
               let split = m.splitIns(total: total),
               let vt = tl.sourcePatchTargets(patch, hasVideo: true, hasAudio: false, streams: .videoOnly),
               let audioTargets = tl.sourcePatchTargets(patch, hasVideo: false, hasAudio: true, streams: .audioOnly),
               let plan = Timeline.sourceEditPlan(sourceMarks: SourceMarks(markIn: split.video, markOut: split.out), total: total,
                                                  sequenceIn: tl.explicitMarks.markIn, sequenceOut: tl.explicitMarks.markOut,
                                                  playhead: self.playhead, frameDuration: tl.frameDuration, isStill: false) {
                let shift = plan.source.start - split.video
                try tl.splitSourceEdit(media: id, name: ref.name, videoIn: plan.source.start, audioIn: max(split.audio + shift, .zero),
                                       out: plan.source.end, mediaDuration: total, initialScale: fit,
                                       videoTracks: vt, audioTracks: audioTargets, at: plan.at, mode: mode)
                endTime = plan.at + plan.source.duration
                return
            }
            // Three-point rule (Adobe): sequence In and Out give the length, otherwise the source does; an Out alone is back-timed
            // and cuts the source head when there is no room before it. Four marks: sequence range and source In.
            let sm = tl.explicitMarks
            // Fit to Fill: the whole source In..Out (or clip) retimed into the sequence In..Out.
            if fitToFill, !still {
                guard let f = Timeline.fitToFillPlan(sourceMarks: m, total: total, sequenceIn: sm.markIn, sequenceOut: sm.markOut,
                                                     frameDuration: tl.frameDuration) else {
                    needsSequenceRange = true; throw EditError.emptyClip
                }
                if placeOnTop {
                    switch tl.placeOnTopTarget(in: TimeRange(start: f.at, duration: f.length)) {
                    case .existing(let id): targets = [id]
                    case .newTrack: targets = [tl.addTrack(kind: .video)]
                    }
                }
                try tl.threePointEdit(source: f.source, media: id, name: ref.name, mediaDuration: total, isStill: false,
                                      initialScale: fit, targets: targets, at: f.at, mode: mode, speed: f.speed)
                endTime = f.at + f.length
                return
            }
            let used = fourPointFit.apply(source: m, sequenceIn: sm.markIn, sequenceOut: sm.markOut)
            guard let plan = Timeline.sourceEditPlan(sourceMarks: used.source, total: total, sequenceIn: used.sequenceIn,
                                                     sequenceOut: used.sequenceOut, playhead: self.playhead,
                                                     frameDuration: tl.frameDuration, isStill: still)
            else { throw EditError.emptyClip }
            fourPoint = plan.usedFourPointDefault
            let placed = plan.source, at = plan.at, d = plan.source.duration
            if placeOnTop {
                switch tl.placeOnTopTarget(in: TimeRange(start: at, duration: d)) {
                case .existing(let id): targets = [id]
                case .newTrack: targets = [tl.addTrack(kind: .video)]
                }
            }
            try tl.threePointEdit(source: placed, media: id, name: ref.name, mediaDuration: still ? nil : total,
                                  isStill: still, initialScale: fit, targets: targets, at: at, mode: mode)
            endTime = at + d
        }
        if needsSequenceRange { setError("Fit to Fill needs a sequence In and Out; set both, then try again.") }
        if noTarget { setError("Nothing is patched: click the source chips left of the track headers to connect them.") }
        if done { seekSequence(to: endTime) }
        if done, fourPoint { setError("Four marks set: used the sequence In/Out and the source In (Fit to Fill in the Source menu retimes the source into the range instead).") }
        return done
    }
}

extension EditorSession {
    /// Play In to Out (Option+K): plays the sequence In..Out range (the whole sequence without marks), stops at Out, or
    /// loops. With `preroll` / `postroll` (Shift+Space, Premiere "Play In to Out with Preroll/Postroll") it starts that
    /// long before In and ends that long after Out, clamped to the sequence.
    public func playInToOut(preroll: Time = .zero, postroll: Time = .zero) {
        guard let t = activeTimeline else { return }
        var range = t.inOut.flatMap { $0.isEmpty ? nil : $0 }
        if let r = range, preroll > .zero || postroll > .zero {
            range = PlaybackBounds.extended(r, preroll: preroll, postroll: postroll, duration: t.duration) ?? r
        }
        start(range: range, from: range?.start ?? .zero, returnTo: nil)
    }

    /// Play to Out: from the playhead to Out (the sequence end when only In is set); nothing when the playhead is already past it.
    @discardableResult
    public func playToOut() -> Bool {
        guard let t = activeTimeline, let io = t.exportRange, playhead < io.end else { return false }
        start(range: TimeRange(start: playhead, end: io.end), from: playhead, returnTo: nil)
        return true
    }

    /// Shift+K, Play Around: from `preroll` before the playhead to `postroll` after it; at the end the playhead goes back
    /// to where it was.
    public func playAround(preroll: Time, postroll: Time) {
        guard let t = activeTimeline else { return }
        let here = playhead
        guard let range = PlaybackBounds.playAround(at: here, preroll: preroll, postroll: postroll, duration: t.duration) else { return }
        start(range: range, from: range.start, returnTo: here)
    }

    private func start(range: TimeRange?, from t: Time, returnTo: Time?) {
        if isPlaying { stopPlayback() }
        seek(to: t)
        apply(shuttle: .setRate(.forward))
        bounds.range = range           // after apply: starting playback clears the range
        bounds.returnTo = range == nil ? nil : returnTo
    }

    public func toggleLoop() { bounds.loop.toggle() }
}

extension EditorSession {
    /// Option+I: the sequence In goes away (Out stays). Both cleared: no range at all.
    public func clearIn() {
        guard activeTimeline?.explicitMarks.markIn != nil else { return }
        attempt("Clear In") { $0.clearIn() }
    }

    /// Option+O: the sequence Out goes away (In stays, the range then runs to the end of the sequence).
    public func clearOut() {
        guard activeTimeline?.explicitMarks.markOut != nil else { return }
        attempt("Clear Out") { $0.clearOut() }
    }
}

extension EditorSession {
    /// New Sequence From Clip: a sequence in the clip's own format holding the clip; it becomes the active one.
    @discardableResult
    public func newSequence(fromMedia id: MediaRef.ID) -> Timeline.ID? {
        guard var t = project.sequence(fromMedia: id) else { setError("That clip cannot become a sequence yet."); return nil }
        t.setEditMode(newSequenceEditMode)
        perform("New Sequence From Clip") { p in
            p.timelines.append(t)
            p.normalizeBins()
        }
        setActiveTimeline(t.id)
        return t.id
    }

    /// Replace Footage / Link Media: `ref` (probed from the new file) takes over the item `id`. One undo step.
    public func replaceFootage(_ id: MediaRef.ID, with ref: MediaRef) {
        requestedMedia.remove(id)       // so `syncMedia` opens the new file now, not on the first decode
        perform("Replace Media") { _ = $0.replaceMedia(id, with: ref) }
    }
}

extension EditorSession {
    /// Dragging the In / Out grip on the Program monitor strip: sets that mark at the frame `t` (Out: the frame is the
    /// last one inside). One undo step per drag.
    public func setInPoint(at t: Time) {
        guard activeTimeline != nil else { return }
        attempt("Mark In") { $0.markIn(at: max(.zero, t)) }
    }

    public func setOutPoint(at t: Time) {
        guard activeTimeline != nil else { return }
        attempt("Mark Out") { $0.markOut(at: max(.zero, t)) }
    }

    /// Drop of a drag on the In/Out band (ruler or Program strip): one undo step. With `part` (Program strip) a newly
    /// dragged range sets both marks and an edge or body drag keeps an In-only or Out-only mark; without it (ruler) the
    /// part is read from the range.
    public func moveInOut(to r: TimeRange, part: MarkedRangeDragPart? = nil) {
        guard activeTimeline != nil else { return }
        attempt("Move In and Out") { t in
            if let part { t.dragMarkedRange(to: r, part: part) } else { t.dragMarkedRange(to: r) }
        }
    }
}
