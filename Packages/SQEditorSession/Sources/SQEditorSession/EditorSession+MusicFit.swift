import Foundation
import SQAnalysis
import SQCore

/// Clip > Fit Music to Length: cuts or loops the selected music clip at bar boundaries (`SQAnalysis.MusicFit`) so it ends
/// at the target length. The chosen version becomes split + trim pieces with a smooth crossfade at every join, one undo step.
extension EditorSession {
    /// "Version 1: 30.0 s, exact, cut 2 bars" for a row of the Fit Music dialog (AppKit sheet and shared dialog).
    public static func musicFitRowTitle(_ v: MusicFit.Version, index: Int) -> String {
        func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
        let err = seconds(v.lengthError)
        let fit = abs(err) < 0.05 ? "exact" : String(format: "%@%.1f s", err > 0 ? "+" : "-", abs(err))
        let bars = v.jumpBars == 1 ? "1 bar" : "\(v.jumpBars) bars"
        return String(format: "Version %d: %.1f s, %@, %@ %@", index + 1, seconds(v.length), fit, v.removesAudio ? "cut" : "loop", bars)
    }

    /// The one selected audio clip Fit Music works on: media audio at normal speed (retimed clips are refused).
    public var musicFitClip: Clip? {
        let c = selectedAudioClips
        guard c.count == 1, let clip = c.first, clip.speed.isNormal, clip.speedKeys == nil, !clip.reversed,
              clip.sequence == nil else { return nil }
        return clip
    }

    public var canFitMusic: Bool { musicFitClip != nil }

    /// Wanted clip length: the In/Out range when one is marked, else from the clip start to the sequence end.
    /// shortcut: the clip keeps its start; a range In that differs from it is not applied, upgrade with a "move to In" option.
    public func musicFitTarget(for clip: Clip) -> Time? {
        guard let t = activeTimeline else { return nil }
        if let r = t.inOut, r.duration > .zero { return r.duration }
        let end = t.tracks.map(\.end).max() ?? .zero
        let len = end - clip.start
        return len > .zero ? len : nil
    }

    /// Up to three versions for the selected clip. `grid` is in media time; it is cut to the part the clip plays.
    public func musicFitVersions(grid: BeatGrid, target: Time? = nil) -> [MusicFit.Version] {
        guard let clip = musicFitClip, let want = target ?? musicFitTarget(for: clip) else { return [] }
        let window = clip.source
        let idx = grid.beats.indices.filter { window.contains(grid.beats[$0]) }
        guard idx.count >= 2 else { return [] }
        let beats = idx.map { grid.beats[$0] - window.start }
        let down = grid.downbeatBeatIndices.compactMap { idx.firstIndex(of: $0) }
        guard down.count >= 2 else { return [] }
        let local = BeatGrid(beats: beats, downbeatBeatIndices: down, beatsPerBar: grid.beatsPerBar, bpm: grid.bpm)
        return MusicFit.propose(grid: local, duration: window.duration, target: want)
    }

    /// Replaces the clip by the version's pieces (the first keeps the clip ID) and puts a crossfade on every join.
    /// Refused (error message, no undo step) when the longer result would run into the next clip on the track.
    @discardableResult
    public func applyMusicFit(_ version: MusicFit.Version, to clipID: Clip.ID? = nil) -> Bool {
        guard let clip = clipID.flatMap({ id in activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id } }) ?? musicFitClip,
              !version.segments.isEmpty else { return false }
        let base = clip.source.start
        // A join at the very start leaves an empty first segment: it is not a piece.
        let segments = version.segments.filter { $0.source.duration > .zero }
        guard !segments.isEmpty else { return false }
        return attempt("Fit Music to Length") { t in
            guard let ti = t.tracks.firstIndex(where: { $0.clips.contains { $0.id == clip.id } }) else { throw EditError.clipNotFound }
            let newEnd = clip.start + version.length
            if t.tracks[ti].clips.contains(where: { $0.id != clip.id && $0.start < newEnd && $0.timeline.end > clip.start }) {
                throw EditError.collision
            }
            var pieces: [Clip] = []
            for (i, seg) in segments.enumerated() {
                var p = clip
                if i > 0 { p.id = UUID(); p.link = nil }
                p.source = TimeRange(start: base + seg.source.start, end: base + seg.source.end)
                p.start = clip.start + seg.outputStart
                if i > 0 { p.audioFades = FadeMarks(); p.duckKeyIDs = [] }
                pieces.append(p)
            }
            let lastID = pieces[pieces.count - 1].id
            for k in t.tracks[ti].transitions.indices where t.tracks[ti].transitions[k].outgoing == clip.id {
                t.tracks[ti].transitions[k].outgoing = lastID
            }
            t.tracks[ti].remove(clip.id)
            for p in pieces { try t.tracks[ti].overwrite(p) }
            for (a, b) in zip(pieces, pieces.dropFirst()) {
                // A join without handles keeps the plain cut: the audio is the same either way.
                _ = try? t.addTransition(kind: .constantPower, track: t.tracks[ti].id, outgoing: a.id, incoming: b.id,
                                         duration: version.crossfade)
            }
        }
    }
}
