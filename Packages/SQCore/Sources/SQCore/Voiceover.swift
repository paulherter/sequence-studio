import Foundation

/// Voiceover from typed text: pure helpers for the script, the file name and the rate. The speech itself is rendered by the
/// app layer (on-device synthesizer, never in SQCore); `Timeline.placeVoiceover` puts the result on the timeline.
public enum Voiceover {
    /// Longest script accepted by the dialog.
    public static let maxCharacters = 5000
    /// Speaking rate on a 0...1 scale (0.5 = the normal speed of the system voice).
    public static let minRate = 0.0, maxRate = 1.0, defaultRate = 0.5

    public static func clampedRate(_ r: Double) -> Double { min(max(r, minRate), maxRate) }

    /// Trimmed text with runs of spaces and tabs folded to one space and more than one blank line folded to one.
    public static func cleaned(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var blank = 0
        for raw in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            if line.isEmpty { blank += 1; if blank == 1, !lines.isEmpty { lines.append("") } } else { blank = 0; lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }

    /// The rate shown as a speed factor: 0 -> 0.5x, 0.5 (normal) -> 1x, 1 -> 2x (two linear halves).
    public static func speedFactor(rate: Double) -> Double {
        let r = clampedRate(rate)
        return r <= 0.5 ? 0.5 + r : 1 + (r - 0.5) * 2
    }
    /// Inverse of `speedFactor(rate:)`; a factor outside 0.5...2 is clamped.
    public static func rate(forSpeedFactor f: Double) -> Double {
        let x = min(max(f, 0.5), 2)
        return x <= 1 ? x - 0.5 : 0.5 + (x - 1) / 2
    }

    /// Rough spoken length in seconds for the dialog's hint: about 150 words a minute at the normal rate, and the rate
    /// slider stretches that between 0.5x and 2x.
    public static func estimatedSeconds(of text: String, rate: Double) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return 0 }
        let factor = speedFactor(rate: rate)
        return Double(words) / 150 * 60 / factor
    }

    /// "Voiceover - first six words.caf", made unique against `existing` with a counter. Characters unsafe in a file name are dropped.
    public static func fileName(for text: String, existing: Set<String>) -> String {
        let words = cleaned(text).split(whereSeparator: { $0.isWhitespace })
            .map { w in String(w.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" || $0 == "_" }) }
            .filter { !$0.isEmpty }.prefix(6)
        let base = words.isEmpty ? "Voiceover" : "Voiceover - " + words.joined(separator: " ")
        var name = base + ".caf", n = 2
        while existing.contains(name) { name = "\(base) \(n).caf"; n += 1 }
        return name
    }

    /// The clip name for a file made by `fileName`.
    public static func clipName(fromFile file: String) -> String { NSString(string: file).deletingPathExtension }
}

public struct VoiceoverPlacement: Sendable, Equatable {
    public var clip: Clip.ID
    public var track: Track.ID
    /// True when no existing audio track was free and a new one was added.
    public var createdTrack: Bool
}

extension Timeline {
    /// Puts a voiceover clip (`media`, `duration` long) at `t` rounded up to a frame, on the first audio track that is free
    /// there: a Dialogue track first, then an empty untagged one, else a new track at the bottom. Locked tracks and tracks
    /// with another role are never used, nothing is overwritten. The track gets the Dialogue role (its voiced preset is
    /// the shared voice chain). Throws `.emptyClip` for a zero length.
    @discardableResult
    public mutating func placeVoiceover(media: UUID, name: String, duration: Time, at t: Time) throws -> VoiceoverPlacement {
        guard duration > .zero else { throw EditError.emptyClip }
        let start = max(t.ceiled(to: frameDuration), .zero)
        let range = TimeRange(start: start, duration: duration)
        func free(_ tr: Track) -> Bool { tr.kind == .audio && !tr.isLocked && !tr.clips.contains { $0.timeline.overlaps(range) } }
        var index = tracks.firstIndex { free($0) && $0.audioRole == .dialogue }
            ?? tracks.firstIndex { free($0) && $0.audioRole == nil && $0.clips.isEmpty }
        var created = false
        if index == nil {
            _ = addTrack(kind: .audio)
            index = tracks.count - 1
            created = true
        }
        let i = index!
        let clip = Clip(name: name, media: media, kind: .audio, source: TimeRange(start: .zero, duration: duration), start: start,
                        mediaDuration: duration)
        var work = tracks[i]
        try work.overwrite(clip)
        work.audioRole = .dialogue
        tracks[i] = work
        return VoiceoverPlacement(clip: clip.id, track: work.id, createdTrack: created)
    }
}
