import Foundation
import SQAudioFX
import SQCore
import SQExport
import SQMedia

/// Pure helpers for the audio short-form tools (testable without a session).
public enum AudioShortform {
    /// Where dialogue is heard on `clip`: its timeline range minus the pauses.
    public static func activeRanges(of clip: TimeRange, silences: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        var cursor = clip.start
        for s in silences.sorted(by: { $0.start < $1.start }) {
            let a = max(s.start, clip.start), b = min(s.end, clip.end)
            guard b > a else { continue }
            if a > cursor { out.append(TimeRange(start: cursor, duration: a - cursor)) }
            cursor = max(cursor, b)
        }
        if clip.end > cursor { out.append(TimeRange(start: cursor, duration: clip.end - cursor)) }
        return out
    }

    /// Sorted, with overlapping or touching ranges joined.
    public static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) where !r.isEmpty {
            if let last = out.last, r.start <= last.end { out[out.count - 1] = TimeRange(start: last.start, duration: max(last.end, r.end) - last.start) }
            else { out.append(r) }
        }
        return out
    }

    /// Pauses of `clip` in timeline time, as heard: the source level goes through the clip's time mapping (reverse, speed,
    /// ramps), Audio Gain, the volume line and the track fader before it is compared with the threshold. `sourcePeak` is the
    /// linear peak of the media in a source range.
    public static func silences(of clip: Clip, trackVolumeDB: Double = 0, thresholdDB: Double, minimumLength: Time,
                                sourcePeak: (TimeRange) -> Float) -> [TimeRange] {
        let (levels, window) = ClipLevels.audible(of: clip, trackVolumeDB: trackVolumeDB, sourcePeak: sourcePeak)
        return SilenceDetector.silences(levels: levels, window: window, thresholdDB: thresholdDB, minimumLength: minimumLength)
            .map { TimeRange(start: clip.start + $0.start, duration: $0.duration) }
    }

    /// Same, reading the peaks from a decoded waveform.
    public static func silences(of clip: Clip, in data: WaveformData, trackVolumeDB: Double = 0, thresholdDB: Double,
                                minimumLength: Time) -> [TimeRange] {
        silences(of: clip, trackVolumeDB: trackVolumeDB, thresholdDB: thresholdDB, minimumLength: minimumLength) { r in
            data.peaks(in: r, buckets: 1).reduce(Float(0)) { m, ch in
                guard let p = ch.first else { return m }
                return max(m, abs(p.min), abs(p.max))
            }
        }
    }

    /// Pauses of several overlapping or touching clips together: a range is silent only where EVERY clip covering it is
    /// silent (the others are still heard there). Where clips do not overlap this is the plain union of their pauses.
    /// Gaps between clips are not pauses.
    public static func combinedSilences(_ clips: [(range: TimeRange, silences: [TimeRange])]) -> [TimeRange] {
        let coverage = merged(clips.map(\.range))
        let active = merged(clips.flatMap { activeRanges(of: $0.range, silences: $0.silences) })
        return subtract(active, from: coverage)
    }

    /// `ranges` (sorted, disjoint) minus `cut` (sorted, disjoint).
    static func subtract(_ cut: [TimeRange], from ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges {
            var cursor = r.start
            for c in cut where c.end > r.start && c.start < r.end {
                if c.start > cursor { out.append(TimeRange(start: cursor, duration: c.start - cursor)) }
                cursor = max(cursor, c.end)
            }
            if r.end > cursor { out.append(TimeRange(start: cursor, duration: r.end - cursor)) }
        }
        return out
    }
}

extension AudioShortform {
    /// Audio tracks that are heard: not muted, and only the solo ones when any audio track is solo.
    public static func audibleTracks(_ t: Timeline) -> [Track] {
        let audio = t.tracks.filter { $0.kind == .audio && !$0.isMuted }
        return audio.contains { $0.isSolo } ? audio.filter(\.isSolo) : audio
    }
}

extension EditorSession {
    /// Selected audio clips (video clips are ignored, also when linked): what the `[` / `]` keys and the tags act on.
    public var selectedAudioClips: [Clip] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && $0.kind == .audio && !$0.isGenerator }
    }

    /// `[` / `]`: Audio Gain of the selected audio clips changes by `db`, one undo step. Never goes below the gain floor.
    @discardableResult
    public func nudgeAudioGain(byDB db: Double) -> Bool {
        let clips = selectedAudioClips
        guard !clips.isEmpty else { return false }
        var gains: [Clip.ID: Double] = [:]
        for c in clips { if let g = AudioGain.apply(.adjust(db), to: c.audioGainDB, peak: nil) { gains[c.id] = g } }
        return setAudioGain(gains)
    }

    /// Tags the selected audio clips; choosing the tag they all have already removes it.
    @discardableResult
    public func toggleAudioTag(_ tag: AudioTag) -> Bool {
        let clips = selectedAudioClips
        guard !clips.isEmpty else { return false }
        let remove = clips.allSatisfy { $0.audioTag == tag }
        let ids = Set(clips.map(\.id))
        return attempt(remove ? "Remove Tag" : "Tag as \(tag.title)") { t in
            for id in ids {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                c.audioTag = remove ? nil : tag
                try t.replaceClip(c)
            }
        }
    }

    /// Music clips Auto Duck works on: the selected ones tagged Music, else every Music clip of the sequence.
    public var musicDuckTargets: [Clip] {
        guard let t = activeTimeline else { return [] }
        let music = t.tracks.flatMap(\.clips).filter { $0.kind == .audio && $0.audioTag == .music }
        let chosen = music.filter { selection.contains($0.id) }
        return chosen.isEmpty ? music : chosen
    }

    /// Dialogue activity on the timeline: every audible Dialogue clip minus its pauses (`silences` gives them per clip).
    /// Disabled clips and muted tracks are silent and do not duck; with a solo audio track only the solo tracks count.
    public func dialogueRanges(silences: (Clip) -> [TimeRange]) -> [TimeRange] {
        guard let t = activeTimeline else { return [] }
        var all: [TimeRange] = []
        for track in AudioShortform.audibleTracks(t) {
            for c in track.clips where c.audioTag == .dialogue && c.isEnabled { all += AudioShortform.activeRanges(of: c.timeline, silences: silences(c)) }
        }
        return AudioShortform.merged(all)
    }

    /// Auto Duck Music: one undo step. Returns the number of keys written (0 = no dialogue or no music clip).
    @discardableResult
    public func autoDuckMusic(silences: (Clip) -> [TimeRange], amountDB: Double = Ducking.defaultAmountDB,
                              fade: Time = Ducking.defaultFade) -> Int {
        let targets = musicDuckTargets.map(\.id)
        let dialogue = dialogueRanges(silences: silences)
        guard !targets.isEmpty else { return 0 }
        var total = 0
        _ = attempt("Auto Duck Music") { t in
            total = 0
            for id in targets {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                total += c.applyDucking(dialogue: dialogue, amountDB: amountDB, fade: fade)
                try t.replaceClip(c)
            }
        }
        return total
    }

    // MARK: Match loudness

    /// Integrated loudness of the clip's audio as heard from its source (no gain, no volume line), nil for silence.
    public func measureLoudness(of clip: Clip) async -> Double? {
        guard let format = activeTimeline?.format else { return nil }
        var c = clip
        c.start = .zero; c.link = nil; c.audioGainDB = 0
        c.animation.volume = AnimatedProperty(1.0)
        c.audioTag = nil; c.duckKeyIDs = []
        let tl = Timeline(name: "", format: format, tracks: [Track(kind: .audio, clips: [c])])
        let source = TimelineAudioSource(timeline: tl, range: c.timeline, resolver: media)
        guard let m = try? await LoudnessNormalizer.measure(source), m.integratedLUFS.isFinite else { return nil }
        return m.integratedLUFS
    }

    /// Match Loudness on the selected audio clips: Audio Gain is set so each reaches its tag's target (Dialogue -14 LUFS,
    /// Music and SFX 6 dB lower). Returns the number of clips changed; silent clips stay as they are.
    @discardableResult
    public func matchLoudness() async -> Int {
        let clips = selectedAudioClips
        var gains: [Clip.ID: Double] = [:]
        for c in clips {
            let lufs = await measureLoudness(of: c)
            if let g = AudioGain.matchLoudness(measuredLUFS: lufs, targetLUFS: AudioGain.targetLUFS(for: c)) { gains[c.id] = g }
        }
        return setAudioGain(gains) ? gains.count : 0
    }

    // MARK: Remove silences

    /// Frame-aligned cuts for the clips' pauses (timeline time). Only audible clips count (enabled, on an unmuted track,
    /// solo respected); where selected clips overlap, a range is a pause only if all of them are silent there.
    public func silenceCuts(for clips: [Clip], silences: (Clip) -> [TimeRange], padding: Time) -> [TimeRange] {
        guard let t = activeTimeline else { return [] }
        let heard = Set(AudioShortform.audibleTracks(t).flatMap(\.clips).filter(\.isEnabled).map(\.id))
        let parts = clips.filter { heard.contains($0.id) }.map { (range: $0.timeline, silences: silences($0)) }
        return SilenceRemoval.cuts(silences: AudioShortform.combinedSilences(parts), padding: padding, frameDuration: t.frameDuration)
    }

    /// Ripple-deletes the cuts on the tracks of `clips` and of their linked partners: one undo step, all or nothing.
    @discardableResult
    public func removeSilences(cuts: [TimeRange], from clips: [Clip]) -> Bool {
        guard !cuts.isEmpty, let t = activeTimeline else { return false }
        let links = Set(clips.compactMap(\.link))
        var tracks: [Track.ID] = []
        for tr in t.tracks where tr.clips.contains(where: { c in clips.contains { $0.id == c.id } || (c.link.map(links.contains) ?? false) }) {
            tracks.append(tr.id)
        }
        return attempt("Remove Silences") { _ = try $0.removeCuts(cuts, tracks: tracks) }
    }
}

extension EditorSession {
    /// Track fader (dB, clamped to the fader range) and pan (-1...1) of an audio track, one undo step. Playback, scrubbing and
    /// export read the same fields.
    @discardableResult
    public func setTrackMix(_ id: Track.ID, volumeDB: Double, pan: Double) -> Bool {
        attempt("Track Volume and Pan") { t in
            guard let i = t.tracks.firstIndex(where: { $0.id == id }), t.tracks[i].kind == .audio else { return }
            t.tracks[i].volumeDB = min(max(volumeDB, TrackPan.minVolumeDB), TrackPan.maxVolumeDB)
            t.tracks[i].pan = min(max(pan, -1), 1)
        }
    }
}
