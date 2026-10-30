import Foundation
import SQAnalysis
import SQCore
import SQMedia

/// Markers on Beat from the spectral tracker (`SQAnalysis.BeatDetector`, decoded sample audio): it knows downbeats. The markers are the ordinary "Beat" markers, so Cut to Beats, Snap to Beats and
/// Hit on Beat speed ramps (`EditorSession+SpeedPresets`) work on them unchanged.
extension AudioShortform {
    /// Timeline times of the grid's beats (or only its downbeats) that `clip` actually plays: a beat is a source time, it is
    /// mapped through the clip's speed, reverse and ramps, and dropped when the clip's source range does not hold it.
    public static func beatTimes(of clip: Clip, grid: BeatGrid, downbeatsOnly: Bool = false) -> [Time] {
        let source = downbeatsOnly ? grid.downbeats : grid.beats
        return source.filter { clip.source.contains($0) }
            .map { clip.timelineTime(forSource: $0) }
            .filter { clip.timeline.contains($0) }
            .sorted()
    }
}

extension EditorSession {
    /// Clips Markers on Beat analyzes: the selected audio clips, else the Music clips (`musicDuckTargets`).
    public var beatAnalysisTargets: [Clip] {
        guard let t = activeTimeline else { return [] }
        let chosen = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && $0.kind == .audio }
        return chosen.isEmpty ? musicDuckTargets : chosen
    }

    /// Decodes the file and runs the beat tracker, off the main actor. nil: no audio, too short or no pulse.
    public nonisolated static func analyzeBeats(url: URL) async -> BeatGrid? {
        #if os(macOS)
        guard let samples = try? await MonoAudioDecoder.decode(url: url) else { return nil }
        return await Task.detached(priority: .utility) {
            BeatDetector.analyze(samples: samples, sampleRate: MonoAudioDecoder.analysisSampleRate)
        }.value
        #else
        return nil   // shortcut: decoding and the beat tracker are Mac-only; upgrade with the FFmpeg audio source.
        #endif
    }

    /// Analyzes every `beatAnalysisTargets` clip (one decode per media file). `url` gives a clip's media file.
    public func beatGrids(url: (Clip) -> URL?) async -> [Clip.ID: BeatGrid] {
        let clips = beatAnalysisTargets
        var byMedia: [UUID: BeatGrid?] = [:]
        var out: [Clip.ID: BeatGrid] = [:]
        for c in clips {
            if byMedia[c.media] == nil {
                guard let u = url(c) else { byMedia[c.media] = .some(nil); continue }
                byMedia[c.media] = .some(await Self.analyzeBeats(url: u))
            }
            if let g = byMedia[c.media] ?? nil { out[c.id] = g }
        }
        return out
    }

    /// Markers on Beat, one undo step: replaces the beat markers inside each analyzed clip's range. Returns the number of
    /// markers (0 with no clip in `grids`, and then no undo step).
    @discardableResult
    public func addMarkersOnBeat(grids: [Clip.ID: BeatGrid], downbeatsOnly: Bool = false) -> Int {
        let found: [(TimeRange, [Time])] = beatAnalysisTargets.compactMap { c in
            grids[c.id].map { (c.timeline, AudioShortform.beatTimes(of: c, grid: $0, downbeatsOnly: downbeatsOnly)) }
        }
        guard !found.isEmpty else { return 0 }
        var total = 0
        _ = attempt(downbeatsOnly ? "Markers on Downbeats" : "Markers on Beat") { t in
            total = 0
            for (range, times) in found { total += t.replaceBeatMarkers(in: range, with: times) }
        }
        return total
    }
}
