import Foundation
import SQCore

/// Stem export: the mix split by audio role, one audio file per stem, plus the music-and-effects mix (M&E: everything
/// except dialogue, for dubbing). Every stem is the sequence itself with the other audio tracks muted, so clip and
/// track volume, FX presets and ducking behave exactly as in the full mix.
public enum StemPlan {
    public struct Stem: Sendable, Equatable {
        public var id: String
        public var title: String
        /// Appended to the output name: `Interview_dialogue.wav`.
        public var fileSuffix: String
        public var timeline: Timeline
    }

    /// One stem per role that has audio tracks with clips (tracks without a role form "other"), then M&E when the
    /// sequence has dialogue and something else. Empty when no audio track carries a clip.
    public static func stems(for timeline: Timeline) -> [Stem] {
        let audioIdx = timeline.tracks.indices.filter { timeline.tracks[$0].kind == .audio && !timeline.tracks[$0].clips.isEmpty }
        guard !audioIdx.isEmpty else { return [] }
        func make(id: String, title: String, keep: (Track) -> Bool) -> Stem? {
            let members = audioIdx.filter { keep(timeline.tracks[$0]) }
            guard !members.isEmpty else { return nil }
            var tl = timeline
            for i in tl.tracks.indices where tl.tracks[i].kind == .audio {
                tl.tracks[i].isSolo = false
                if !members.contains(i) { tl.tracks[i].isMuted = true }
            }
            return Stem(id: id, title: title, fileSuffix: id, timeline: tl)
        }
        var out: [Stem] = []
        for role in AudioTag.allCases {
            if let s = make(id: role.rawValue, title: role.title, keep: { $0.audioRole == role }) { out.append(s) }
        }
        if let s = make(id: "other", title: "Other", keep: { $0.audioRole == nil }) { out.append(s) }
        let hasDialogue = audioIdx.contains { timeline.tracks[$0].audioRole == .dialogue }
        let hasRest = audioIdx.contains { timeline.tracks[$0].audioRole != .dialogue }
        if hasDialogue, hasRest, let me = make(id: "me", title: "Music and Effects", keep: { $0.audioRole != .dialogue }) {
            out.append(me)
        }
        return out
    }

    /// `<base>_<suffix>.<ext>` for every stem, in plan order.
    public static func fileNames(base: String, stems: [Stem], ext: String) -> [String] {
        stems.map { "\(base)_\($0.fileSuffix).\(ext)" }
    }
}
