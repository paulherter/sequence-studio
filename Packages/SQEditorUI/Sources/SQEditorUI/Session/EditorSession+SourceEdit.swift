import Foundation
import SQCore

extension EditorSession {
    /// Source Monitor Insert (`,`) / Overwrite (`.`): the source's In..Out (whole media when unmarked) lands at the
    /// sequence In point, else at the playhead, on the targeted tracks (`Timeline.sourceEditTargets`). Afterwards the
    /// playhead sits at the end of the new clip (Premiere). One undo step. Returns false when nothing was placed.
    @discardableResult
    public func sourceEdit(media id: MediaRef.ID, marks: SourceMarks? = nil, streams: SourceStreams = .both,
                           mode: ThreePointMode) -> Bool {
        guard let t = activeTimeline, let ref = project.media(id) else { return false }
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
        let done = attempt(mode == .insert ? "Insert" : "Overwrite") { tl in
            if adopts, let v = ref.info?.video {
                tl.format = SequenceFormat(width: v.displayWidth, height: v.displayHeight,
                                           frameDuration: still ? tl.format.frameDuration : v.nominalFrameDuration,
                                           audioSampleRate: tl.format.audioSampleRate)
            }
            guard let targets = tl.sourceEditTargets(hasVideo: hasVideo, hasAudio: hasAudio, streams: streams) else {
                noTarget = true; throw EditError.clipNotFound
            }
            let fit = ref.info?.video.map { tl.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
            // Whole sequence frames (a 24 fps clip in a 30 fps sequence, 60 in 25): round the length, stay inside the media.
            let fd = tl.frameDuration
            var d = source.duration.snapped(to: fd)
            if d <= .zero { d = fd }
            if !still, source.start + d > total { d = d - fd }
            guard d > .zero else { throw EditError.emptyClip }
            let placed = TimeRange(start: source.start, duration: d)
            // Three-point rule: sequence In, else a sequence Out back-timed from the end, else the playhead.
            let at = tl.sourceEditPlacement(sourceDuration: d, playhead: self.playhead).snapped(to: tl.frameDuration)
            try tl.threePointEdit(source: placed, media: id, name: ref.name, mediaDuration: still ? nil : total,
                                  isStill: still, initialScale: fit, targets: targets, at: at, mode: mode)
            endTime = at + d
        }
        if noTarget { setError("Target a track first (the V1 / A1 buttons in the track headers).") }
        if done { seek(to: endTime) }
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
    /// Option+I: the sequence In goes back to the start (Out stays). Both cleared: no range at all.
    public func clearIn() {
        guard let io = activeTimeline?.inOut else { return }
        let end = io.end
        attempt("Clear In") { $0.inOut = end >= $0.duration ? nil : TimeRange(start: .zero, end: end) }
    }

    /// Option+O: the sequence Out goes back to the end of the sequence (In stays).
    public func clearOut() {
        guard let io = activeTimeline?.inOut else { return }
        let start = io.start
        attempt("Clear Out") { $0.inOut = start <= .zero ? nil : TimeRange(start: start, end: max($0.duration, start + $0.frameDuration)) }
    }
}

extension EditorSession {
    /// New Sequence From Clip: a sequence in the clip's own format holding the clip; it becomes the active one.
    @discardableResult
    public func newSequence(fromMedia id: MediaRef.ID) -> Timeline.ID? {
        guard let t = project.sequence(fromMedia: id) else { setError("That clip cannot become a sequence yet."); return nil }
        perform("New Sequence From Clip") { p in
            p.timelines.append(t)
            p.normalizeBins()
        }
        setActiveTimeline(t.id)
        return t.id
    }

    /// Replace Footage / Link Media: `ref` (probed from the new file) takes over the item `id`. One undo step.
    public func replaceFootage(_ id: MediaRef.ID, with ref: MediaRef) {
        perform("Replace Footage") { _ = $0.replaceMedia(id, with: ref) }
    }
}
