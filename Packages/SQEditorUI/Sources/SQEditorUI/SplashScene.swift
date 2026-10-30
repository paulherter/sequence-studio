import CoreGraphics
import SQUIKit
import AppKit

enum SplashMouth: Equatable { case smile, grin, flat, o }

/// One sampled Pip pose of the splash scene (x in window points, y offset in points, up is negative like the mock).
struct SplashPose: Equatable {
    var x: CGFloat, y: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, r: CGFloat = 0
    var ex: CGFloat = 0, ey: CGFloat = 0
    var happy = false
    var mouth = SplashMouth.smile
}

/// The final splash scene F1 of pip-startbild (`SC.sb3`): a mini timeline card, Pip as the playhead driving right in
/// stages, clips growing behind him. Pure functions of the scene time `tau` (design seconds, 0...3.8); the window maps
/// real startup progress to `tau`, so the keyframes are time-scaled to whatever the start takes.
enum SplashScene {
    struct Clip { let start: CGFloat, end: CGFloat, row: Int, color: (top: NSColor, bottom: NSColor) }

    static let cardX: CGFloat = 52, cardTop: CGFloat = 300, cardWidth: CGFloat = 320, cardHeight: CGFloat = 134
    static let cardRadius: CGFloat = 9, clipRadius: CGFloat = 5
    static let rulerHeight: CGFloat = 22
    static let rowTops: [CGFloat] = [330, 358, 386]
    static let clipHeight: CGFloat = 22
    /// Pip's tip rests on the ruler line.
    static let tipY: CGFloat = cardTop + rulerHeight
    /// Pip artwork width (the mock's `P`); height follows the artwork ratio.
    static let pipWidth: CGFloat = 114

    static func X(_ v: CGFloat) -> CGFloat { 52 + (v - 36) * 1.194 }

    static let clips: [Clip] = {
        typealias C = (top: NSColor, bottom: NSColor)
        let o = Theme.Splash.clipOrange, p = Theme.Splash.clipPink, r = Theme.Splash.clipRose
        let v = Theme.Splash.clipViolet, d = Theme.Splash.clipDeep, red = Theme.Splash.clipRed
        let rows: [[(CGFloat, CGFloat, C)]] = [
            [(44, 120, o), (124, 210, p), (214, 296, r)],
            [(44, 92, v), (96, 172, o), (176, 252, v), (256, 296, p)],
            [(60, 150, d), (154, 230, red), (234, 296, v)]]
        return rows.enumerated().flatMap { ri, row in row.map { Clip(start: X($0.0), end: X($0.1), row: ri, color: $0.2) } }
    }()

    static let stations: [CGFloat] = [82, 118, 106, 196, 276].map(X)
    /// Scene time at which Pip reaches the last station (end of the driving part).
    static let driveEnd: Double = 2.8
    static let endTime: Double = 3.8

    enum Ease { case out, `in`, io, hold }
    private struct Key { var t: Double; var p: SplashPose; var ease: Ease }

    static func ease(_ e: Ease, _ u: Double) -> Double {
        switch e {
        case .out: let v = u - 1; return 1 + 2.1 * v * v * v + 1.1 * v * v
        case .in: return u * (2 - u)
        case .io, .hold: return u * u * u * (u * (u * 6 - 15) + 10)
        }
    }

    private static let keys: [Key] = {
        let k: CGFloat = 1.9, s = stations
        var cur = SplashPose(x: s[0])
        var out: [Key] = []
        func add(_ t: Double, _ ease: Ease = .io, _ edit: (inout SplashPose) -> Void) { edit(&cur); out.append(Key(t: t, p: cur, ease: ease)) }
        // Driving part: x only (travelX), no lean, nod or hop that could read as a bump; the gaze settles calmly.
        add(0) { $0.x = s[0]; $0.ex = 12; $0.ey = 20; $0.mouth = .smile }
        add(driveEnd) { $0.x = s[4]; $0.ex = 0; $0.ey = 0 }
        add(2.92, .hold) { $0.sx = 1.16; $0.sy = 0.8 }
        add(3.0, .out) { $0.y = -22 * k; $0.sx = 0.92; $0.sy = 1.14; $0.happy = true; $0.mouth = .grin }
        add(3.2, .out) { $0.y = -24 * k; $0.sx = 1; $0.sy = 1 }
        add(3.4, .hold) { $0.y = 0; $0.sx = 1.18; $0.sy = 0.78 }
        add(3.55, .out) { $0.sx = 0.97; $0.sy = 1.05; $0.happy = false; $0.mouth = .smile }
        add(3.8) { $0.sx = 1; $0.sy = 1 }
        return out
    }()

    static func pose(at t: Double) -> SplashPose {
        guard let first = keys.first, let last = keys.last else { return SplashPose(x: stations[0]) }
        if t <= first.t { return first.p }
        if t >= last.t { return last.p }
        var i = 0
        while keys[i + 1].t <= t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let e = CGFloat(ease(b.ease, (t - a.t) / (b.t - a.t)))
        var r = a.p
        func mix(_ f: KeyPath<SplashPose, CGFloat>) -> CGFloat { a.p[keyPath: f] + (b.p[keyPath: f] - a.p[keyPath: f]) * e }
        r.x = travelX(at: t); r.y = mix(\.y); r.sx = mix(\.sx); r.sy = mix(\.sy); r.r = mix(\.r); r.ex = mix(\.ex); r.ey = mix(\.ey)
        return r
    }

    /// Pip's x: one monotone travel from the first to the last station. The time-based ease already shapes `t`, so the
    /// map is linear (a second ease would stall him).
    static func travelX(at t: Double) -> CGFloat {
        let u = CGFloat(min(1, max(0, t / driveEnd)))
        return stations[0] + (stations[4] - stations[0]) * u
    }

    /// Furthest x Pip has reached up to `t` (the clips grow behind it and never shrink).
    static func furthestX(at t: Double) -> CGFloat { travelX(at: t) }

    /// Clip width at `t`: grows with Pip, plus 8 pt, up to the full clip.
    static func clipWidth(_ c: Clip, at t: Double) -> CGFloat {
        max(0, min(c.end - c.start, furthestX(at: t) + 8 - c.start))
    }

    /// Scene time: the (time-based) travel progress drives the driving part, the Ready moment plays the joy jump in real
    /// time.
    static func tau(progress: Double, ready: Bool, readyElapsed: Double) -> Double {
        ready ? driveEnd + readyElapsed : driveEnd * min(1, max(0, progress))
    }
}
