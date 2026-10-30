import Foundation

/// Every VoiceOver string of the custom AppKit views (timeline, monitors, meters) in one place, built by pure functions
/// so they are unit-tested and a later localization picks them up from here. Callers pass timecodes already formatted.
public enum SQAccessibilityText {
    // MARK: Timeline

    public static var timelineLabel: String { SQL10n.string("Timeline") }
    public static var timelineHelp: String { SQL10n.string("Tracks and clips of the sequence") }

    /// "Video track V1, 3 clips, locked".
    public static func track(kind: String, label: String, clipCount: Int, locked: Bool = false, muted: Bool = false,
                             hidden: Bool = false) -> String {
        var parts = [SQL10n.format("%@ track %@", SQL10n.string(kind), label),
                     SQL10n.plural(clipCount, one: "%@ clip", other: "%@ clips")]
        if locked { parts.append(SQL10n.string("locked")) }
        if muted { parts.append(SQL10n.string("muted")) }
        if hidden { parts.append(SQL10n.string("hidden")) }
        return parts.joined(separator: ", ")
    }

    /// "Interview, from 00:00:01:00, length 00:00:04:00".
    public static func clip(name: String, start: String, length: String, offline: Bool = false) -> String {
        let n = name.isEmpty ? SQL10n.string("Untitled clip") : name
        return SQL10n.format("%@, from %@, length %@", n, start, length) + (offline ? SQL10n.string(", media offline") : "")
    }

    public static func timelinePlayhead(_ timecode: String) -> String { SQL10n.format("Playhead at %@", timecode) }

    // MARK: Monitors

    public static var timecodeLabel: String { SQL10n.string("Timecode") }
    public static func playState(isPlaying: Bool) -> String { SQL10n.string(isPlaying ? "Playing" : "Paused") }
    public static var monitorLabel: String { SQL10n.string("Monitor") }
    /// "Playing, at 00:00:05:12".
    public static func monitorValue(isPlaying: Bool, timecode: String) -> String {
        SQL10n.format("%@, at %@", playState(isPlaying: isPlaying), timecode)
    }

    // MARK: Meters

    public static var meterLabel: String { SQL10n.string("Audio meter") }
    /// One channel: "Left, minus 12.3 dB", "Left, silent", "Left, clipped" (the clip latch wins). `dB` nil = silent.
    public static func meterChannel(name: String, dB: Float?, clipped: Bool) -> String {
        if clipped { return SQL10n.format("%@, clipped", name) }
        guard let dB else { return SQL10n.format("%@, silent", name) }
        let v = (Double(dB) * 10).rounded() / 10
        let spoken = v < 0 ? SQL10n.format("minus %@", String(format: "%.1f", -v)) : String(format: "%.1f", v)
        return SQL10n.format("%@, %@ dB", name, spoken)
    }
    /// All channels joined: "Left, minus 12.3 dB. Right, silent".
    public static func meterValue(_ channels: [String]) -> String { channels.joined(separator: ". ") }
    /// "L" / "R" / "M" to the spoken channel name.
    public static func channelName(_ short: String) -> String {
        switch short {
        case "L": return SQL10n.string("Left")
        case "R": return SQL10n.string("Right")
        case "M": return SQL10n.string("Mono")
        default: return short
        }
    }

    /// Every key this file looks up (the German catalog must translate them).
    static let keys = ["Timeline", "Tracks and clips of the sequence", "%@ track %@", "%@ clip", "%@ clips", "locked", "muted",
                       "hidden", "Untitled clip", "%@, from %@, length %@", ", media offline", "Playhead at %@", "Timecode",
                       "Playing", "Paused", "Monitor", "%@, at %@", "Audio meter", "%@, clipped", "%@, silent", "minus %@",
                       "%@, %@ dB", "Left", "Right", "Mono", "Video"]
}
