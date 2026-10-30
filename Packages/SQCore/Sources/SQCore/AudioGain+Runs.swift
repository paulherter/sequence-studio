import Foundation

extension AudioGain {
    /// Longest pause (between two clips of one track) that still counts as one spoken run for Match Loudness.
    public static let runGap = Time(1, 2)

    /// Match Loudness runs: for each audio clip of `selected`, the run it belongs to, meaning the clips of its track that
    /// follow each other (pause at most `maxGap`) with the same role. Cut dialogue is then measured as one piece, so the
    /// pieces get one gain and stay even. A run may contain clips that are not selected (they are measured, not changed).
    /// Runs come back ordered by start; a clip lands in exactly one run. Generator clips and video clips are ignored.
    public static func loudnessRuns(of selected: Set<Clip.ID>, in t: Timeline, maxGap: Time = runGap) -> [[Clip]] {
        var out: [[Clip]] = []
        for tr in t.tracks where tr.kind == .audio {
            let clips = tr.clips.filter { !$0.isGenerator }.sorted { $0.start < $1.start }
            var run: [Clip] = []
            func flush() {
                if run.contains(where: { selected.contains($0.id) }) { out.append(run) }
                run = []
            }
            for c in clips {
                if let last = run.last {
                    let joined = c.start - last.timeline.end <= maxGap && t.role(of: c) == t.role(of: last)
                    if !joined { flush() }
                }
                run.append(c)
            }
            flush()
        }
        return out.sorted { $0[0].start < $1[0].start }
    }
}
