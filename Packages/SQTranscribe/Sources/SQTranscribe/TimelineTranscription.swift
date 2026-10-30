import Foundation
import SQCore
import SQMedia

/// Transcript of a whole sequence (Premiere: Transcribe Sequence). Every audible audio clip is looked up by its media file;
/// each file is transcribed once (cached per call), and the words that fall inside a clip's used source range are mapped
/// to sequence time through the clip's position and speed. Words of all clips end up in one list sorted by time.
public enum TimelineTranscription {
    /// Audio clips that are heard: audio tracks that are not muted (and, when any track is soloed, only soloed ones),
    /// enabled clips with media. Generators, stills, nested sequences and reversed or frame-held clips are left out
    /// (no usable word order).
    public static func audibleClips(in timeline: Timeline) -> [Clip] {
        let audio = timeline.tracks.filter { $0.kind == .audio }
        let anySolo = audio.contains { $0.isSolo }
        return audio.filter { !$0.isMuted && (!anySolo || $0.isSolo) }
            .flatMap(\.clips)
            .filter { $0.isEnabled && !$0.isGenerator && !$0.isNested && !$0.isStill && !$0.reversed && $0.holdFrame == nil && $0.speedKeys == nil }
            .sorted { $0.start < $1.start }
    }

    /// What a transcript depends on: position, source range, speed and media of every audible clip, plus the frame duration.
    /// A different layout means the stored sequence-time words no longer match the timeline.
    public struct Layout: Sendable, Hashable {
        struct Entry: Sendable, Hashable { var id: UUID; var media: UUID; var start: Time; var source: TimeRange; var speed: ClipSpeed }
        var entries: [Entry]
        var frameDuration: Time
    }

    public static func layout(of timeline: Timeline) -> Layout {
        Layout(entries: audibleClips(in: timeline).map { Layout.Entry(id: $0.id, media: $0.media, start: $0.start, source: $0.source, speed: $0.speed) },
               frameDuration: timeline.frameDuration)
    }

    /// Words of the clip's media (source time) that the clip plays, moved to sequence time. A word belongs to the clip when
    /// its midpoint lies inside the used source range; its ends are clamped to the clip.
    public static func mapWords(_ words: [TranscriptWord], from clip: Clip, frameDuration: Time) -> [TranscriptWord] {
        guard !clip.reversed, clip.holdFrame == nil else { return [] }
        let src = clip.source
        let span = clip.timeline
        return words.compactMap { word in
            let mid = Time((word.range.start + word.range.end).value, (word.range.start + word.range.end).timescale * 2)
            guard mid >= src.start, mid < src.end else { return nil }
            let a = min(max(clip.timelineTime(forSource: max(word.range.start, src.start), frameDuration: frameDuration), span.start), span.end)
            let b = min(max(clip.timelineTime(forSource: min(word.range.end, src.end), frameDuration: frameDuration), a), span.end)
            var out = word
            out.range = TimeRange(start: a, end: b)
            return out
        }
    }

    /// Transcribes every audible clip's media once and merges the mapped words into one transcript in sequence time.
    /// `urls` resolves media IDs to files; clips whose media has no URL are skipped. Throws `noAudio` when nothing is audible.
    /// `channelMaps` (F7.10): media whose clips play chosen channels are transcribed from those channels (rendered to a
    /// temporary file), so a clip mapped to the lavalier channel is heard from that channel.
    public static func transcribe(timeline: Timeline, urls: [UUID: URL], channelMaps: [UUID: AudioChannelMap] = [:],
                                  expectedChannels: [UUID: Int] = [:], service: any TranscriptionService, locale: Locale,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let clips = audibleClips(in: timeline).filter { urls[$0.media] != nil }
        guard !clips.isEmpty else { throw TranscriptionError.noAudio }
        var order: [UUID] = []
        for c in clips where !order.contains(c.media) { order.append(c.media) }
        var perMedia: [UUID: [TranscriptWord]] = [:]
        for (i, media) in order.enumerated() {
            try Task.checkCancellation()
            guard let url = urls[media] else { continue }
            let base = Double(i), count = Double(order.count)
            let t = try await transcribeOne(url: url, map: channelMaps[media], expectedChannels: expectedChannels[media], service: service, locale: locale) { p in progress((base + p) / count) }
            perMedia[media] = t.words
        }
        var words: [TranscriptWord] = []
        // Clips that play the same recording at overlapping times (A1 + A2, overlapped clips) would give every word twice:
        // a word is dropped when an earlier clip of the same media already produced a word overlapping it in time.
        var kept: [UUID: [TimeRange]] = [:]
        for clip in clips {
            let earlier = kept[clip.media] ?? []
            let mine = mapWords(perMedia[clip.media] ?? [], from: clip, frameDuration: timeline.frameDuration)
                .filter { w in !earlier.contains { $0.start < w.range.end && w.range.start < $0.end } }
            words += mine
            kept[clip.media] = earlier + mine.map(\.range)
        }
        words.sort { $0.range.start < $1.range.start }
        progress(1)
        return Transcript(language: locale.identifier(.bcp47), words: words)
    }

    /// One media file: from the file itself, or from the channels `map` names (rendered to a temporary file that is
    /// removed afterwards).
    private static func transcribeOne(url: URL, map: AudioChannelMap?, expectedChannels: Int?, service: any TranscriptionService, locale: Locale,
                                      progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        guard let map else { return try await service.transcribe(url: url, locale: locale, progress: progress) }
        #if canImport(AVFoundation)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sq-transcribe-map-\(UUID().uuidString).caf")
        do { try await AudioSources.writeFile(from: url, channelMap: map, to: temp, expectedChannels: expectedChannels) } catch {
            try? FileManager.default.removeItem(at: temp)
            // Only a file with no audio to render is "no audio"; a disk or decoder error stays what it is.
            if case MediaError.unreadable = error { throw TranscriptionError.noAudio }
            throw error
        }
        do {
            let result = try await service.transcribe(url: temp, locale: locale, progress: progress)
            try? FileManager.default.removeItem(at: temp)
            return result
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        #else
        // shortcut: no channel-map rendering off the Mac (AudioSources.writeFile is AVFoundation), upgrade when
        // SQMediaFFmpeg renders channel maps.
        _ = (map, expectedChannels)
        throw TranscriptionError.unavailable
        #endif
    }
}
