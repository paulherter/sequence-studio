import Foundation
import SSCore

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
            let at = tl.sourceEditPosition(playhead: self.playhead).snapped(to: tl.frameDuration)
            guard let targets = tl.sourceEditTargets(hasVideo: hasVideo, hasAudio: hasAudio, streams: streams) else {
                noTarget = true; throw EditError.clipNotFound
            }
            let fit = ref.info?.video.map { tl.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
            try tl.threePointEdit(source: source, media: id, name: ref.name, mediaDuration: still ? nil : total,
                                  isStill: still, initialScale: fit, targets: targets, at: at, mode: mode)
            endTime = at + source.duration
        }
        if noTarget { setError("Target a track first (the V1 / A1 buttons in the track headers).") }
        if done { seek(to: endTime) }
        return done
    }
}
