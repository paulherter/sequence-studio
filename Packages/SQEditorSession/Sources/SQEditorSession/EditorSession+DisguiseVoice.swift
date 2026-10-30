import Foundation
import SQUIKit
import SQCore
import SQTranscribe

/// Captions for a disguised range: only the transcript words that sound inside it, never anything outside.
public enum DisguiseVoiceCaptions {
    /// `transcript` holds sequence-time words. Words reaching into `range` are clamped to it, segmented with `preset`,
    /// and the captions are put on frames. `range` must lie on frames; every item ends up inside it.
    public static func items(transcript: Transcript, preset: CaptionPreset, range: TimeRange, frameDuration fd: Time) -> [CaptionItem] {
        let words = transcript.words.compactMap { w -> TranscriptWord? in
            guard let hit = w.range.intersection(range), !hit.isEmpty else { return nil }
            var out = w
            out.range = hit
            return out
        }
        guard !words.isEmpty else { return [] }
        let part = Transcript(language: transcript.language, words: words)
        let captions = CaptionSegmenter.applyTiming(CaptionSegmenter.segment(part, preset: preset), preset: preset)
        // Timing rules (minimum duration, closed gaps) may push a caption past the range: cut it back.
        let items = captions.compactMap { c -> CaptionItem? in
            guard let r = c.range.intersection(range), !r.isEmpty else { return nil }
            return CaptionItem(lines: c.lines, range: r, styleRef: c.styleRef, animationRef: c.animationRef,
                               words: c.words.map { CaptionWord(text: $0.text, range: relative($0.range, in: r), confidence: $0.confidence) })
        }
        return CaptionMapping.snapped(items, to: fd).compactMap { it -> CaptionItem? in
            guard it.range.start < range.end else { return nil }
            guard it.range.end > range.end else { return it }
            var out = it
            out.range = TimeRange(start: it.range.start, end: range.end)
            let whole = TimeRange(start: .zero, end: out.range.duration)
            out.words = it.words.map { CaptionWord(text: $0.text, range: relative($0.range, in: whole), confidence: $0.confidence) }
            return out
        }
    }

    /// `r` clamped to `outer`, counted from `outer.start`.
    private static func relative(_ r: TimeRange, in outer: TimeRange) -> TimeRange {
        let a = min(max(r.start, outer.start), outer.end)
        let b = min(max(r.end, a), outer.end)
        return TimeRange(start: a - outer.start, end: b - outer.start)
    }
}

extension EditorSession {
    public struct DisguiseVoiceOutcome: Equatable, Sendable {
        /// The disguised range in sequence time.
        public var range: TimeRange
        /// Clip parts that carry the effect now.
        public var clips: Int
        /// Captions created for the range (0 without a transcript, or when no word sounds inside it).
        public var captions: Int
        /// The caption track is locked: the voice was disguised, captions were left alone.
        public var captionTrackLocked = false

        /// The status line: what was disguised (clip parts, range as timecodes), what happened to the captions, and the
        /// one honest sentence about what the effect is. `hasTranscript` = a current transcript was at hand.
        @MainActor public func statusText(frameDuration fd: Time, hasTranscript: Bool) -> String {
            let span = "\(MarkersPanelModel.timecode(range.start, frameDuration: fd)) to \(MarkersPanelModel.timecode(range.end, frameDuration: fd))"
            let what = SQL10n.format(clips == 1 ? "Disguise Voice on %@ clip, %@." : "Disguise Voice on %@ clips, %@.", String(clips), span)
            let text: String
            if captionTrackLocked {
                text = SQL10n.string("No captions: the caption track is locked.")
            } else if captions > 0 {
                text = SQL10n.plural(captions, one: "%@ caption created.", other: "%@ captions created.")
            } else if !hasTranscript {
                text = SQL10n.string("Captions need a current transcript: transcribe in the Text panel, then run Disguise Voice again.")
            } else {
                text = SQL10n.string("The transcript has no words in this range, so no captions were created.")
            }
            return [what, text, SQL10n.string(AudioDisguiseValues.hint)].joined(separator: " ")
        }
    }

    /// What Disguise Voice acts on: In to Out when it reaches every selected audio clip (an In/Out left over from other
    /// work must not decide), else the span of the selected audio clips. Widened to whole frames (start down, end up), so
    /// no part of a frame keeps the original voice. nil when no audio clip is selected.
    public var disguiseVoiceRange: TimeRange? {
        guard let t = activeTimeline else { return nil }
        let clips = selectedAudioClips
        guard let first = clips.first else { return nil }
        let fd = t.frameDuration
        func onFrames(_ r: TimeRange) -> TimeRange? {
            let out = TimeRange(start: r.start.flooredToFrame(fd), end: r.end.ceiled(to: fd))
            return out.isEmpty ? nil : out
        }
        if let io = t.inOut, clips.allSatisfy({ $0.timeline.overlaps(io) }), let r = onFrames(io) { return r }
        let span = clips.reduce(first.timeline) { TimeRange(start: min($0.start, $1.timeline.start), end: max($0.end, $1.timeline.end)) }
        return onFrames(span)
    }

    /// Disguise Voice: the selected audio clips are cut at the range's edges, the parts inside get the Disguise Voice
    /// effect, and captions are made for exactly that range from `transcript` (sequence-time words), all in one undo step.
    /// Without a transcript only the effect is applied; this never starts a transcription. Existing captions that
    /// overlap a new one are replaced, the others stay. A locked caption track never stops the disguise: the captions are
    /// skipped and the outcome says so. nil when nothing changed (`lastError` says why if it was refused).
    @discardableResult
    public func disguiseVoice(transcript: Transcript?, preset: CaptionPreset? = nil, voice: Int = 0) -> DisguiseVoiceOutcome? {
        guard let t = activeTimeline, let range = disguiseVoiceRange else { return nil }
        let ids = Set(selectedAudioClips.map(\.id))
        // `replaceCaptions` without a track writes to the first one.
        let target = currentCaptionTrack?.id
        let locked = (target.flatMap { t.captionTrack($0) } ?? t.captionTracks.first)?.isLocked == true
        let items = locked ? [] : transcript.map {
            DisguiseVoiceCaptions.items(transcript: $0, preset: preset ?? .standard, range: range, frameDuration: t.frameDuration)
        } ?? []
        var parts = 0
        let done = attempt("Disguise Voice") { t in
            parts = try t.disguiseVoice(range: range, clips: ids, voice: voice).count
            guard !items.isEmpty else { return }
            let existing = target.flatMap { t.captionTrack($0) }?.items ?? []
            let kept = existing.filter { e in !items.contains { $0.range.overlaps(e.range) } }
            _ = try t.replaceCaptions(kept + items, track: target)
        }
        return done ? DisguiseVoiceOutcome(range: range, clips: parts, captions: items.count, captionTrackLocked: locked) : nil
    }
}

extension EditorCommand {
    /// The second line under a menu item, for commands whose name alone would promise too much.
    public var menuHelp: String? {
        switch self {
        case .disguiseVoice: AudioDisguiseValues.hint
        default: nil
        }
    }
}
