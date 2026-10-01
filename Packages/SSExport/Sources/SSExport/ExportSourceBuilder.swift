import Foundation
import SSAudioFX
import SSCore
import SSMedia
import SSPlayback
import SSTranscribe

/// Builds the real export sources of one sequence: decoded video through the compositor (text, nested sequences,
/// corner radius), the mixed audio (clip/track volume, per-track FX presets, nested sequences) and the sidecar cues.
/// Loudness normalisation runs in `ExportWriter` (the audio source is rewindable).
public enum ExportSourceBuilder {
    public enum BuildError: Error, Sendable, Equatable { case emptyRange }

    /// Frames of `range` at `frameDuration` (rounded up: the last, partial frame is still written).
    public static func frameCount(range: TimeRange, frameDuration: Time) -> Int {
        let n = Int128(range.duration.value) * Int128(frameDuration.timescale)
        let d = Int128(range.duration.timescale) * Int128(frameDuration.value)
        guard d > 0, n > 0 else { return 0 }
        return Int(n / d + (n % d > 0 ? 1 : 0))
    }

    public static func range(for settings: ExportSettings, in timeline: Timeline) -> TimeRange {
        switch settings.range {
        case .entireSequence: TimeRange(start: .zero, duration: timeline.duration)
        case .inOut(let r): r
        }
    }

    /// The caption burn-in of a "Burn in captions" export: every visible caption track of the sequence, drawn with its
    /// caption style at the bottom safe area. Nil when burn-in is off or there are no captions.
    public static func burnIn(for timeline: Timeline, settings: ExportSettings) -> CaptionBurnIn? {
        guard settings.captions == .burnIn else { return nil }
        let items = timeline.captionTracks.filter(\.isVisible).flatMap(\.items)
            .filter { !$0.range.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !items.isEmpty else { return nil }
        let captions = items.map {
            Caption(lines: $0.lines, range: $0.range, styleRef: $0.styleRef, animationRef: $0.animationRef)
        }
        return CaptionBurnIn(captions: captions, library: .builtIn)
    }

    /// - Parameters:
    ///   - sequences: all timelines of the project by id (nested clips resolve through them).
    ///   - presets: per-audio-track FX presets (tracks without one are dry).
    public static func make(timeline: Timeline, sequences: [Timeline.ID: Timeline], settings: ExportSettings,
                            resolver: any MediaResolver, presets: [Track.ID: TrackAudioPreset] = [:],
                            pixelFormat: ExportPixelFormat = .bgra8) throws -> ExportSources {
        let range = range(for: settings, in: timeline)
        let frames = frameCount(range: range, frameDuration: settings.video.frameDuration)
        guard frames > 0 else { throw BuildError.emptyRange }
        let provider = DecoderFrameProvider(resolver: resolver)
        let video = try TimelineFrameSource(timeline: timeline, sequences: sequences, provider: provider,
                                            width: settings.video.width, height: settings.video.height,
                                            frameDuration: settings.video.frameDuration, frameCount: frames,
                                            startTime: range.start, pixelFormat: pixelFormat,
                                            captions: burnIn(for: timeline, settings: settings),
                                            colorResolver: resolver.colorResolver)
        let hasAudio = settings.audio.enabled && timeline.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty }
        let audio: (any AudioSource)? = hasAudio
            ? TimelineAudioSource(timeline: timeline, sequences: sequences, range: range, presets: presets, resolver: resolver)
            : nil
        let cues = timeline.captionTracks.filter(\.isVisible).flatMap(\.items).map { SRTCue(lines: $0.lines, range: $0.range) }
        return ExportSources(video: video, audio: audio, captions: cues)
    }
}
