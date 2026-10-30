// Spike scene: ruler with time labels, three tracks with a few clips, playhead. Integer pixels and frames only.
public enum TimelineStrip {
    public static let gutter = 80          // track header width
    public static let rulerHeight = 28
    public static let pixelsPerSecond = 40
    public static let fps = 30
    public static let durationFrames = 30 * 24

    struct Clip { var track: Int; var start: Int; var length: Int; var color: DrawColor; var name: String }  // seconds
    static let clips: [Clip] = [
        Clip(track: 0, start: 1, length: 6, color: DrawColor(0.20, 0.45, 0.80), name: "Intro"),
        Clip(track: 0, start: 8, length: 9, color: DrawColor(0.28, 0.62, 0.45), name: "Interview"),
        Clip(track: 0, start: 18, length: 5, color: DrawColor(0.78, 0.50, 0.22), name: "B-roll"),
        Clip(track: 1, start: 0, length: 12, color: DrawColor(0.55, 0.35, 0.75), name: "Dialog"),
        Clip(track: 1, start: 13, length: 10, color: DrawColor(0.55, 0.35, 0.75), name: "Dialog 2"),
        Clip(track: 2, start: 2, length: 20, color: DrawColor(0.75, 0.30, 0.45), name: "Music"),
    ]
    static let trackNames = ["V1", "A1", "A2"]

    public static func x(forFrame f: Int) -> Int { gutter + f * pixelsPerSecond / fps }
    public static func frame(forX x: Int) -> Int { max(0, min(durationFrames, (x - gutter) * fps / pixelsPerSecond)) }

    public static func timecode(frame f: Int) -> String {
        let s = f / fps
        return "\(s / 60 < 10 ? "0" : "")\(s / 60):\(s % 60 < 10 ? "0" : "")\(s % 60):\(f % fps < 10 ? "0" : "")\(f % fps)"
    }

    public static func draw(width: Int, height: Int, playheadFrame: Int) -> DrawList {
        var l = DrawList()
        let text = DrawColor(0.85, 0.86, 0.88), dim = DrawColor(0.55, 0.57, 0.60)
        l.rect(0, 0, width, height, DrawColor(0.10, 0.10, 0.11))
        // Ruler
        l.rect(0, 0, width, rulerHeight, DrawColor(0.15, 0.15, 0.17))
        l.rect(0, rulerHeight - 1, width, 1, DrawColor(0.28, 0.28, 0.31))
        for half in 0...(durationFrames / (fps / 2)) {
            let px = gutter + half * pixelsPerSecond / 2
            guard px < width else { break }
            let major = half % 2 == 0
            l.rect(px, rulerHeight - (major ? 10 : 5), 1, major ? 10 : 5, dim)
            if major && (half / 2) % 2 == 0 { l.text(px + 3, 6, timecodeShort(half / 2), scale: 1, text) }
        }
        // Tracks
        let trackH = 56, gap = 6
        for t in 0..<3 {
            let y = rulerHeight + 8 + t * (trackH + gap)
            l.rect(0, y, gutter - 2, trackH, DrawColor(0.17, 0.17, 0.19))
            l.text(10, y + trackH / 2 - 7, trackNames[t], scale: 2, text)
            l.rect(gutter, y, width - gutter, trackH, DrawColor(0.13, 0.13, 0.14))
        }
        for c in clips {
            let y = rulerHeight + 8 + c.track * (trackH + gap)
            let cx = gutter + c.start * pixelsPerSecond, cw = c.length * pixelsPerSecond - 2
            guard cx < width else { continue }
            let w = min(cw, width - cx)
            l.rect(cx, y + 2, w, trackH - 4, c.color)
            l.rect(cx, y + 2, w, 1, DrawColor(1, 1, 1, 0.35))                 // top highlight
            l.rect(cx, y + trackH - 3, w, 1, DrawColor(0, 0, 0, 0.35))        // bottom shade
            l.text(cx + 6, y + 8, c.name, scale: 2, DrawColor(1, 1, 1, 0.92))
        }
        // Playhead
        let px = x(forFrame: playheadFrame)
        let red = DrawColor(0.95, 0.30, 0.25)
        l.rect(px - 1, 0, 2, height, red)
        l.rect(px - 6, 0, 13, 11, red)
        l.rect(px - 4, 11, 9, 2, red)
        l.rect(px - 2, 13, 5, 2, red)
        let tc = timecode(frame: playheadFrame)
        l.rect(px + 8, rulerHeight + 2, tc.count * 12 + 8, 18, DrawColor(0, 0, 0, 0.65))
        l.text(px + 12, rulerHeight + 5, tc, scale: 2, DrawColor(1, 1, 1))
        return l
    }

    static func timecodeShort(_ s: Int) -> String { "\(s / 60 < 10 ? "0" : "")\(s / 60):\(s % 60 < 10 ? "0" : "")\(s % 60)" }
}
