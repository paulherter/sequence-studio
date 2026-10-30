import SQAnalysis
import Foundation
import SQAudioFX
import SQCore
import SQMedia
import SQPlayback
import SQText
import SQTranscribe

/// Builds the real export sources of one sequence: decoded video through the compositor (text, nested sequences,
/// corner radius), the mixed audio (clip/track volume, per-track FX presets, nested sequences) and the sidecar cues.
/// Loudness normalization runs in `ExportWriter` (the audio source is rewindable).
public enum ExportSourceBuilder {
    public enum BuildError: Error, Sendable, Equatable { case emptyRange }

    /// Frames of `range` at `frameDuration` (rounded up: the last, partial frame is still written).
    public static func frameCount(range: TimeRange, frameDuration: Time) -> Int {
        ExportFrameCount.of(range: range, frameDuration: frameDuration)
    }

    public static func range(for settings: ExportSettings, in timeline: Timeline) -> TimeRange {
        switch settings.range {
        case .entireSequence: TimeRange(start: .zero, duration: timeline.duration)
        case .inOut(let r): r
        }
    }

    /// The caption burn-in of a "Burn in captions" export: every visible caption track of the sequence, drawn with its
    /// caption style at the bottom safe area. Nil when burn-in is off or there are no captions.
    public static func burnIn(for timeline: Timeline, settings: ExportSettings,
                              library: CaptionPresetLibrary = .builtIn) -> CaptionBurnIn? {
        guard settings.captions == .burnIn else { return nil }
        // One layer per visible caption track, in track order: overlapping tracks all burn in, as the monitor draws them.
        let layers: [[Caption]] = timeline.captionTracks.filter(\.isVisible).map { track in
            track.items
                .filter { !$0.range.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { Caption(lines: $0.lines, range: $0.range, styleRef: $0.styleRef, animationRef: $0.animationRef,
                               words: $0.words, karaoke: track.karaoke, position: $0.position) }
        }
        guard layers.contains(where: { !$0.isEmpty }) else { return nil }
        let burn = CaptionBurnIn(layers: layers, library: library, frameDuration: timeline.format.frameDuration)
        burn.pixelAspect = settings.video.pixelAspect
        return burn
    }

    /// - Parameters:
    ///   - sequences: all timelines of the project by id (nested clips resolve through them).
    ///   - presets: per-audio-track FX presets (tracks without one are dry).
    ///   - captionLibrary: the project's caption styles (`CaptionLookRegistry.library(for: project.styleKit)`); the default is
    ///     the process-wide library of the project being edited.
    ///   - liveDucking: the project's own live ducking setting (`Project.liveDucking`; nil = Preferences), as playback uses.
    ///   - dialogueSilences: pauses inside dialogue clips (`TimelineWaveforms.silences`), as playback uses.
    ///   - useProxies: the global "use proxies for export" switch: ready proxies with the original's frame times are decoded
    ///     instead of the originals (drafts; smart-render copy segments still read the original).
    ///   - renderCache: preview render cache segments the export may read instead of compositing them (the same files
    ///     playback reads); used only when `RenderCacheSegmentWriter.mayReuse` says the settings match the cache.
    ///   - decodeQoS: QoS of the decode queues (the background render cache passes utility).
    ///   - pixelFormat: nil = the codec's own (`ExportSettings.sourcePixelFormat`: 10-bit for HEVC Main 10 and ProRes).
    public static func make(timeline: Timeline, sequences: [Timeline.ID: Timeline], settings: ExportSettings,
                            resolver: any MediaResolver, presets: [Track.ID: TrackAudioPreset] = [:],
                            liveDucking: ProjectLiveDucking? = nil,
                            dialogueSilences: (any DialogueSilenceProvider)? = nil,
                            pixelFormat: ExportPixelFormat? = nil,
                            captionLibrary: CaptionPresetLibrary = .builtIn,
                            useProxies: Bool = false, renderCache: [RenderCacheSpan] = [],
                            decodeQoS: DispatchQoS = .userInitiated) throws -> ExportSources {
        var timeline = timeline
        timeline.renderCacheSpans = RenderCacheSegmentWriter.mayReuse(settings, timeline: timeline) ? renderCache : []
        let range = range(for: settings, in: timeline)
        let frames = frameCount(range: range, frameDuration: settings.video.frameDuration)
        guard frames > 0 else { throw BuildError.emptyRange }
        // One budget for every decoder of this export (all parallel segments): sessions and frames stay bounded.
        // Halved on 8 GB Macs (`WorkLimits.exportDecoderSessions` / `exportFrameBytes`; the defaults from 16 GB up).
        let limits = WorkLimits.current
        let budget = DecoderBudget(maxDecoders: limits.exportDecoderSessions, maxBytes: limits.exportFrameBytes,
                                   maxSoftwareDecoders: limits.softwareDecoderSessions)
        let provider = DecoderFrameProvider(resolver: resolver, budget: budget, useProxies: useProxies, qos: decodeQoS)
        let video = try TimelineFrameSource(timeline: timeline, sequences: sequences, provider: provider,
                                            width: settings.video.width, height: settings.video.height,
                                            frameDuration: settings.video.frameDuration, frameCount: frames,
                                            startTime: range.start, pixelFormat: pixelFormat ?? settings.sourcePixelFormat,
                                            captions: burnIn(for: timeline, settings: settings, library: captionLibrary),
                                            colorResolver: resolver.colorResolver, gyroWarper: resolver.gyroWarper,
                                            continueOnDamagedFrames: settings.continueOnDamagedFrames,
                                            makeProvider: { DecoderFrameProvider(resolver: resolver, budget: budget, useProxies: useProxies, qos: decodeQoS) },
                                            subjectMattes: ExportSubjectMattes(deinterlace: {
                                                // As `DecoderFrameProvider` asks for its decoders.
                                                resolver.colorResolver?.info(of: $0)?.video?.deinterlaceFieldOrder
                                            }) { resolver.fileURL(for: $0) },
                                            hdrToSDR: settings.hdrToSDR, hdrOutput: ExportWriter.hdrTags(settings)?.transfer)
        let hasAudio = settings.audio.enabled && timeline.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty }
        // The last, partial frame is written whole: the audio covers that whole frame too (silence past the sequence end),
        // so both tracks end together instead of the video running up to a frame past the audio.
        let audioRange = TimeRange(start: range.start, duration: settings.video.frameDuration * Int64(frames))
        let audio: (any AudioSource)? = hasAudio
            ? TimelineAudioSource(timeline: timeline, sequences: sequences, range: audioRange, presets: presets,
                                  liveDucking: liveDucking, dialogueSilences: dialogueSilences, resolver: resolver)
            : nil
        let cues = timeline.captionTracks.filter(\.isVisible).flatMap(\.items).map { SRTCue(lines: $0.lines, range: $0.range) }
        return ExportSources(video: video, audio: audio, captions: cues)
    }
}
