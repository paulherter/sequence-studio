import Foundation
import SQCore

extension EditorSession {
    /// Clips Audio Gain works on: the selected audio clips, plus the linked audio of selected video clips
    /// (Premiere applies the gain to the audio of a selected linked clip).
    public var audioGainTargets: [Clip] {
        guard let tl = activeTimeline else { return [] }
        let all = tl.tracks.flatMap(\.clips)
        let chosen = all.filter { selection.contains($0.id) }
        let links = Set(chosen.compactMap(\.link))
        var out: [Clip] = []
        for c in all where c.kind == .audio && !c.isGenerator {
            if selection.contains(c.id) || (c.link.map(links.contains) ?? false) { out.append(c) }
        }
        return out
    }

    /// Sets the Audio Gain (dB) of the given clips as one undo step.
    @discardableResult
    public func setAudioGain(_ gains: [Clip.ID: Double]) -> Bool {
        guard !gains.isEmpty else { return false }
        return attempt("Audio Gain") { t in
            for (id, db) in gains {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                c.audioGainDB = min(max(db, AudioGain.minGainDB), AudioGain.maxGainDB)
                try t.replaceClip(c)
            }
        }
    }
}
