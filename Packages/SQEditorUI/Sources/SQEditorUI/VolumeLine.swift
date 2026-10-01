import AppKit
import SQCore

/// The volume rubber band on an audio clip (Premiere): a line over the waveform at the clip's Volume level.
/// Drag it up or down to change the level, Cmd-click to add a key, drag a key to move it. Pure geometry and gesture
/// maths; `TimelineView` draws it and routes the mouse.
public enum VolumeLine {
    /// Rows shorter than this show no band (too little room to grab it).
    public static let minRowHeight: CGFloat = 40
    /// Level at the top and bottom of the waveform area. Below the bottom is silence.
    public static let dbTop = AudioGain.maxVolumeDB
    public static let dbBottom = -40.0
    static let lineGrab: CGFloat = 4
    static let keyGrab: CGFloat = 6

    public static func isAvailable(rowHeight: CGFloat) -> Bool { rowHeight >= minRowHeight }

    /// The area the line moves in: the waveform area of the clip rectangle.
    public static func lane(in clipRect: CGRect) -> CGRect { ClipDrawing.waveformRect(in: clipRect) }

    public static func y(forDB db: Double, in lane: CGRect) -> CGFloat {
        if db <= AudioGain.silenceDB { return lane.maxY }
        let f = (min(max(db, dbBottom), dbTop) - dbBottom) / (dbTop - dbBottom)
        return lane.maxY - lane.height * CGFloat(f)
    }

    public static func db(forY y: CGFloat, in lane: CGRect) -> Double {
        guard lane.height > 0 else { return 0 }
        if y >= lane.maxY { return AudioGain.silenceDB }
        let f = Double((lane.maxY - y) / lane.height)
        return min(dbBottom + f * (dbTop - dbBottom), dbTop)
    }

    /// Within this many points of a clip's left or right edge the trim handle beats a key (without Cmd).
    public static let edgeTrimZone: CGFloat = 6

    public static func edgeWins(at p: CGPoint, clipRect: CGRect) -> Bool {
        p.x - clipRect.minX < edgeTrimZone || clipRect.maxX - p.x < edgeTrimZone
    }

    public enum Hit: Equatable, Sendable {
        case key(UUID)
        /// On the line (not on a key) at this clip-local time.
        case line(atLocal: Time)
    }

    static func levelDB(_ clip: Clip, atLocal t: Time) -> Double { AudioGain.db(fromLinear: clip.animation.volume.value(atLocal: t)) }

    public static func hit(clip: Clip, clipRect: CGRect, at p: CGPoint, geometry: TimelineGeometry) -> Hit? {
        guard clipRect.insetBy(dx: -keyGrab, dy: 0).contains(CGPoint(x: p.x, y: clipRect.midY)) else { return nil }
        let lane = lane(in: clipRect)
        guard lane.height >= 4 else { return nil }
        for k in clip.animation.volume.track.keys {
            let kx = geometry.x(for: clip.start + k.time)
            let ky = y(forDB: AudioGain.db(fromLinear: k.value), in: lane)
            if hypot(p.x - kx, p.y - ky) <= keyGrab { return .key(k.id) }
        }
        guard clipRect.contains(CGPoint(x: p.x, y: clipRect.midY)) else { return nil }
        let local = min(max(geometry.time(atX: p.x) - clip.start, .zero), clip.duration)
        let ly = y(forDB: levelDB(clip, atLocal: local), in: lane)
        return abs(p.y - ly) <= lineGrab ? .line(atLocal: local) : nil
    }

    /// Polyline of the line inside `visible`, `step` points apart (keys are always included).
    public static func points(clip: Clip, clipRect: CGRect, visible: CGRect, step: CGFloat = 3) -> [CGPoint] {
        let lane = lane(in: clipRect)
        let x0 = max(clipRect.minX, visible.minX), x1 = min(clipRect.maxX, visible.maxX)
        guard x1 > x0, lane.height > 0 else { return [] }
        if clip.animation.volume.track.isEmpty {   // constant level: one segment (the common case, and cheap)
            let y = y(forDB: AudioGain.db(fromLinear: clip.animation.volume.value), in: lane)
            return [CGPoint(x: x0, y: y), CGPoint(x: x1, y: y)]
        }
        let secPerPoint = Double(clip.duration.value) / Double(clip.duration.timescale) / Double(max(clipRect.width, 1))
        func at(_ x: CGFloat) -> CGPoint {
            let sec = Double(x - clipRect.minX) * secPerPoint
            let t = Time(Int64((sec * 1_000_000).rounded()), 1_000_000)
            return CGPoint(x: x, y: y(forDB: levelDB(clip, atLocal: t), in: lane))
        }
        var xs: [CGFloat] = Array(stride(from: x0, to: x1, by: max(step, 1))) + [x1]
        xs += clip.animation.volume.track.keys.map { CGFloat(geometry(x: $0.time, clip: clip, rect: clipRect)) }.filter { $0 > x0 && $0 < x1 }
        return xs.sorted().map(at)
    }

    private static func geometry(x t: Time, clip: Clip, rect: CGRect) -> Double {
        let d = Double(clip.duration.value) / Double(clip.duration.timescale)
        let s = Double(t.value) / Double(t.timescale)
        return Double(rect.minX) + (d > 0 ? s / d : 0) * Double(rect.width)
    }

    /// Key positions (view points) for drawing.
    public static func keyPoints(clip: Clip, clipRect: CGRect) -> [CGPoint] {
        let lane = lane(in: clipRect)
        return clip.animation.volume.track.keys.map {
            CGPoint(x: geometry(x: $0.time, clip: clip, rect: clipRect),
                    y: y(forDB: AudioGain.db(fromLinear: $0.value), in: lane))
        }
    }
}

/// Fade handles: the two small squares near the top corners of an audio clip (Premiere's fade handles). Dragging one
/// sets the head or tail fade as keys on the volume line (`FadeKeys`).
public enum FadeHandle: Sendable, Hashable { case head, tail }

extension VolumeLine {
    public static let handleSize: CGFloat = 8
    /// Gap between a handle's centre and the clip edge when there is no fade (keeps the handle inside the clip).
    static let handleInset: CGFloat = 6

    /// Centres of the head and tail handles (view points). They sit on the top edge of the waveform lane and move
    /// inward with the fade length.
    public static func fadeHandlePoints(clip: Clip, clipRect: CGRect) -> (head: CGPoint, tail: CGPoint) {
        let lane = lane(in: clipRect)
        let d = Double(clip.duration.value) / Double(clip.duration.timescale)
        func width(_ t: Time) -> CGFloat { d > 0 ? CGFloat(Double(t.value) / Double(t.timescale) / d) * clipRect.width : 0 }
        let y = lane.minY + handleSize / 2 + 1
        return (CGPoint(x: clipRect.minX + handleInset + width(clip.audioFadeIn), y: y),
                CGPoint(x: clipRect.maxX - handleInset - width(clip.audioFadeOut), y: y))
    }

    /// The handle under `p`, if any. Tail wins when the two overlap on a very short clip.
    public static func fadeHandle(clip: Clip, clipRect: CGRect, at p: CGPoint, hidden: Set<FadeHandle> = []) -> FadeHandle? {
        guard clipRect.width >= 4 * handleSize else { return nil }
        let pts = fadeHandlePoints(clip: clip, clipRect: clipRect)
        let r = handleSize / 2 + 2
        func hits(_ c: CGPoint) -> Bool { abs(p.x - c.x) <= r && abs(p.y - c.y) <= r }
        if !hidden.contains(.tail), hits(pts.tail) { return .tail }
        if !hidden.contains(.head), hits(pts.head) { return .head }
        return nil
    }

    /// The clip with its fade set from a drag: `dx` points moved since the press (handle at `startLength` then).
    public static func clip(_ clip: Clip, dragging h: FadeHandle, from startLength: Time, dx: CGFloat, clipRect: CGRect,
                            frameDuration: Time) -> Clip {
        var c = clip
        let d = Double(clip.duration.value) / Double(clip.duration.timescale)
        guard clipRect.width > 0, d > 0 else { return c }
        let sec = Double(dx) / Double(clipRect.width) * d * (h == .head ? 1 : -1)
        // Milliseconds are enough: the fade snaps down to whole frames anyway.
        let len = startLength + Time(Int64((sec * 1000).rounded()), 1000)
        switch h {
        case .head: c.setAudioFadeIn(max(len, .zero), frameDuration: frameDuration)
        case .tail: c.setAudioFadeOut(max(len, .zero), frameDuration: frameDuration)
        }
        return c
    }
}

/// One drag on the volume line. Always recomputes from the clip it started with, so the result depends only on
/// where the pointer is now (dragging back to the start restores the original).
public struct VolumeLineGesture {
    public let original: Clip
    private let hit: VolumeLine.Hit
    private let start: CGPoint
    private let clipRect: CGRect
    private let geometry: TimelineGeometry
    private let startClip: Clip
    private var keyID: UUID?

    /// `addKey`: Cmd-click on the line first adds a key there, then the drag moves that key.
    public init(clip: Clip, hit: VolumeLine.Hit, start: CGPoint, clipRect: CGRect, geometry: TimelineGeometry, addKey: Bool) {
        original = clip; self.hit = hit; self.start = start; self.clipRect = clipRect; self.geometry = geometry
        var c = clip
        switch hit {
        case .key(let id): keyID = id
        case .line(let t):
            if addKey { keyID = c.addVolumeKey(atLocal: t.snapped(to: geometry.frameDuration)) }
        }
        startClip = c
    }

    public mutating func update(to p: CGPoint) -> Clip {
        if hypot(p.x - start.x, p.y - start.y) < 1 { return startClip }   // no real movement: nothing to commit
        var c = startClip
        let lane = VolumeLine.lane(in: clipRect)
        if let id = keyID {
            let t = geometry.time(atX: p.x) - c.start
            c.moveVolumeKey(id, toLocal: t, gainDB: VolumeLine.db(forY: p.y, in: lane))
        } else if case .line(let t) = hit {
            let delta = VolumeLine.db(forY: p.y, in: lane) - VolumeLine.db(forY: start.y, in: lane)
            c.shiftVolumeLine(atLocal: t, byDB: delta)
        }
        return c
    }
}
