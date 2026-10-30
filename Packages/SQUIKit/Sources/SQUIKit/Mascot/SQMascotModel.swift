import Foundation

// SQMascot (Pip): pose model, easings and key-pose animations. Pure value math, no drawing, no clock. The data is
// `Resources/Mascot/pip-anim.json` (design source of truth, copied unchanged); the rules follow its `ease` notes.

/// Numeric pose channels. The raw JSON key is the case name.
public enum SQMascotKey: Int, CaseIterable, Sendable {
    case tx, ty, sx, sy, rot, fx, fy, ex, ey, esp, bl, bly, bldx, hd, hL, mgx, mgy, mgs, mgo, bs, dpx, dpy, dps
    case d1, d2, d3, z1, z2, z3, z1y, z2y, z3y, sp, h1, h2, hide
    case bcy, btilt, bbow, bhl, bsw, bdx, baL, baR

    var jsonKey: String { String(describing: self) }
    /// Brow shape channels: taken from the side that has brows when only one side does.
    static let brow: [SQMascotKey] = [.bcy, .btilt, .bbow, .bhl, .bsw, .bdx]
}

/// An eye or mouth shape: kind plus its numeric parameters (JSON order, kind removed).
public struct SQMascotShape: Equatable, Sendable {
    public var kind: String
    public var a: [Double]
    public init(_ kind: String, _ a: [Double]) { self.kind = kind; self.a = a }
}

/// One full pose. `kEyeL`/`kEyeR`/`kMouth` are runtime squeeze factors for a shape swap in progress, `blink` the idle
/// blink openness (1 open); they are not part of the data.
public struct SQMascotPose: Equatable, Sendable {
    public var n: [Double]
    public var eL: SQMascotShape
    public var eR: SQMascotShape
    public var m: SQMascotShape
    public var kEyeL = 1.0, kEyeR = 1.0, kMouth = 1.0, blink = 1.0

    public subscript(_ k: SQMascotKey) -> Double {
        get { n[k.rawValue] }
        set { n[k.rawValue] = newValue }
    }

    /// Mixes `a` toward `b` by `u` (may overshoot). Shapes of the same kind blend; different kinds swap in the middle
    /// while squeezed shut (as the design player does).
    public static func mix(_ a: SQMascotPose, _ b: SQMascotPose, _ u: Double) -> SQMascotPose {
        var o = a
        for i in 0..<a.n.count { o.n[i] = a.n[i] + (b.n[i] - a.n[i]) * u }
        let aBrow = a[.baL] + a[.baR], bBrow = b[.baL] + b[.baR]
        if aBrow == 0 { for k in SQMascotKey.brow { o[k] = b[k] } }
        else if bBrow == 0 { for k in SQMascotKey.brow { o[k] = a[k] } }
        (o.eL, o.kEyeL) = shape(a.eL, b.eL, u)
        (o.eR, o.kEyeR) = shape(a.eR, b.eR, u)
        (o.m, o.kMouth) = shape(a.m, b.m, u)
        o[.hide] = min(max(u, 0), 1) < 1 ? a[.hide] : b[.hide]
        o.blink = 1
        return o
    }

    private static func shape(_ a: SQMascotShape, _ b: SQMascotShape, _ u: Double) -> (SQMascotShape, Double) {
        if a.kind == b.kind, a.a.count == b.a.count {
            return (SQMascotShape(a.kind, zip(a.a, b.a).map { $0 + ($1 - $0) * u }), 1)
        }
        let c = min(max(u, 0), 1)
        return (c < 0.5 ? a : b, abs(1 - 2 * c))
    }
}

/// Easings by the JSON `ease` names.
public enum SQMascotEase: String, Sendable {
    case lin, io, `in`, out, back, pop, spring

    public func value(_ t: Double) -> Double {
        switch self {
        case .lin: return t
        case .io: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .in: return t * t
        case .out: return 1 - (1 - t) * (1 - t)
        case .back: let v = t - 1; return 1 + 2.3 * v * v * v + 1.3 * v * v
        case .pop: let v = t - 1; return 1 + 3.4 * v * v * v + 2.4 * v * v
        case .spring:
            if t >= 1 { return 1 }
            return 1 - exp(-6 * t) * (cos(7 * t) + 0.86 * sin(7 * t)) * (1 - t * t * t * t)
        }
    }
}

/// Move to `to` in `duration` ms with `ease`, then hold `hold` ms.
public struct SQMascotStep: Sendable {
    public var to: SQMascotPose
    public var duration: Double
    public var ease: SQMascotEase
    public var hold: Double
}

/// Named animations. The raw value is the key in `pip-anim.json`.
public enum SQMascotAnim: String, CaseIterable, Sendable {
    case wink, peek
    case sleep = "schlaf"
    case search = "suche"
    case work = "arbeit"
    case cheer = "jubel"
    case oops = "ups"
    case think = "denkt"
    case proud = "stolz"
    case sad = "still-traurig"
    /// Reactions (parts, played on demand): M3 wake and hop away, R2 one eye opens and falls shut again.
    case dragWake = "m3wach"
    case dragAway = "m3weg"
    case hoverOpen = "m5blinzel"
    case hoverClose = "m5wieder"
}

public enum SQMascotKind: String, Sendable { case loop, rest, once, part }

public struct SQMascotAnimation: Sendable {
    public var kind: SQMascotKind
    /// Tight art: viewBox 125 268 774 774, no hand, magnifier, badge or floating marks (also used for <= 24 pt).
    public var tight: Bool
    public var viewBox: CGRect
    /// Art-space y below which nothing is drawn (peek behind a card edge).
    public var clipBottom: Double?
    /// Strength of idle breathing and sway (0 asleep).
    public var breath: Double
    /// Seconds of rest between repeats (`rest` kind only).
    public var pause: ClosedRange<Double>?
    public var rest: SQMascotPose
    public var still: SQMascotPose
    public var from: SQMascotPose?
    public var steps: [SQMascotStep]
    public var totalMilliseconds: Double { steps.reduce(0) { $0 + $1.duration + $1.hold } }
}

public struct SQMascotIdleConfig: Equatable, Sendable {
    public var breathHeight = 0.012, breathWidth = 0.006, breathPeriod = 3800.0
    public var swayDegrees = 0.9, swayPeriod = 7600.0
    public var blinkEvery = 2600.0...6400.0
    public var blinkClose = 110.0, blinkShut = 50.0, blinkOpen = 150.0, blinkGap = 130.0
    /// Every n-th blink is a double blink.
    public var doubleEvery = 5
    /// Breathing and sway fade in over this long after an animation.
    public var fadeIn = 900.0
    /// Walk back to the rest pose before idling.
    public var settle = 420.0
}

/// M3: eyes, face and tilt follow a point (the file being dragged). Per step of `rx` points sideways (at most 3 steps)
/// and `ry` points up or down (at most 1 step) the channels in `x` and `y` move by their value; `lag` is the low-pass
/// time constant in ms.
public struct SQMascotLook: Sendable {
    public var base: SQMascotPose
    public var x: [SQMascotKey: Double]
    public var y: [SQMascotKey: Double]
    public var rx = 55.0, ry = 42.0, lag = 130.0
    public static let maxX = 3.0, maxY = 1.0

    /// Steps (sideways, vertical) for an offset of the point from Pip's center, in points.
    public func target(dx: Double, dy: Double) -> (x: Double, y: Double) {
        (min(max(dx / rx, -Self.maxX), Self.maxX), min(max(dy / ry, -Self.maxY), Self.maxY))
    }

    /// The pose at `gx` sideways and `gy` vertical steps.
    public func pose(gx: Double, gy: Double) -> SQMascotPose {
        var p = base
        for (k, v) in x { p[k] += v * gx }
        for (k, v) in y { p[k] += v * gy }
        return p
    }
}

/// The low-pass state of a follow in progress.
public struct SQMascotFollower: Sendable {
    public let look: SQMascotLook
    public private(set) var gx = 0.0, gy = 0.0
    public init(look: SQMascotLook) { self.look = look }

    /// Moves toward the target for the offset (`dx`, `dy` in points from the center) by `dt` ms; returns the pose.
    public mutating func advance(_ dt: Double, dx: Double, dy: Double) -> SQMascotPose {
        let t = look.target(dx: dx, dy: dy)
        let k = 1 - exp(-dt / look.lag)
        gx += (t.x - gx) * k
        gy += (t.y - gy) * k
        return look.pose(gx: gx, gy: gy)
    }
}

public struct SQMascotLibrary: Sendable {
    public let idle: SQMascotIdleConfig
    public let look: SQMascotLook
    public let defaultPose: SQMascotPose
    /// The `look` base pose (amazed face).
    public let amazed: SQMascotPose
    private let anims: [String: SQMascotAnimation]

    public func animation(_ a: SQMascotAnim) -> SQMascotAnimation { anims[a.rawValue]! }

    public static let shared: SQMascotLibrary = {
        guard let url = Bundle.module.url(forResource: "pip-anim", withExtension: "json", subdirectory: "Mascot"),
              let data = try? Data(contentsOf: url), let lib = try? SQMascotLibrary(json: data)
        else { preconditionFailure("pip-anim.json missing from SQUIKit resources") }
        return lib
    }()

    public struct ParseError: Error { public var detail: String }

    public init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let def = root["default"] as? [String: Any],
              let rawAnims = root["anims"] as? [String: Any]
        else { throw ParseError(detail: "root") }
        let base = try Self.pose(def, over: nil)
        defaultPose = base
        var idleCfg = SQMascotIdleConfig()
        if let i = root["idle"] as? [String: Any] {
            if let b = i["breath"] as? [String: Any] {
                idleCfg.breathHeight = b["sy"] as? Double ?? idleCfg.breathHeight
                idleCfg.breathWidth = b["sx"] as? Double ?? idleCfg.breathWidth
                idleCfg.breathPeriod = b["period"] as? Double ?? idleCfg.breathPeriod
            }
            if let s = i["sway"] as? [String: Any] {
                idleCfg.swayDegrees = s["rot"] as? Double ?? idleCfg.swayDegrees
                idleCfg.swayPeriod = s["period"] as? Double ?? idleCfg.swayPeriod
            }
            if let b = i["blink"] as? [String: Any] {
                if let e = b["every"] as? [Double], e.count == 2 { idleCfg.blinkEvery = e[0]...e[1] }
                idleCfg.blinkClose = b["close"] as? Double ?? idleCfg.blinkClose
                idleCfg.blinkShut = b["shut"] as? Double ?? idleCfg.blinkShut
                idleCfg.blinkOpen = b["open"] as? Double ?? idleCfg.blinkOpen
            }
        }
        idle = idleCfg
        let lookRoot = root["look"] as? [String: Any]
        if let lookBase = lookRoot?["base"] as? [String: Any] {
            amazed = try Self.pose(lookBase, over: base)
        } else { amazed = base }
        func deltas(_ any: Any?) -> [SQMascotKey: Double] {
            var out: [SQMascotKey: Double] = [:]
            for (name, v) in any as? [String: Any] ?? [:] {
                if let k = SQMascotKey.allCases.first(where: { $0.jsonKey == name }), let d = (v as? NSNumber)?.doubleValue { out[k] = d }
            }
            return out
        }
        var lk = SQMascotLook(base: amazed, x: deltas(lookRoot?["x"]), y: deltas(lookRoot?["y"]))
        lk.rx = lookRoot?["rx"] as? Double ?? lk.rx
        lk.ry = lookRoot?["ry"] as? Double ?? lk.ry
        lk.lag = lookRoot?["lag"] as? Double ?? lk.lag
        look = lk
        var out: [String: SQMascotAnimation] = [:]
        for (name, any) in rawAnims {
            guard let a = any as? [String: Any], let kindText = a["kind"] as? String,
                  let kind = SQMascotKind(rawValue: kindText), let vb = a["vb"] as? String else { continue }
            let box = vb.split(separator: " ").compactMap { Double($0) }
            guard box.count == 4 else { throw ParseError(detail: "vb \(name)") }
            var steps: [SQMascotStep] = []
            for s in a["steps"] as? [[String: Any]] ?? [] {
                let ease = SQMascotEase(rawValue: s["e"] as? String ?? "io") ?? .io
                steps.append(SQMascotStep(to: try Self.pose(s["p"] as? [String: Any] ?? [:], over: base),
                                          duration: max(1, s["d"] as? Double ?? 0), ease: ease, hold: s["h"] as? Double ?? 0))
            }
            let rest = try Self.pose(a["rest"] as? [String: Any] ?? [:], over: base)
            var pause: ClosedRange<Double>?
            if let p = a["pause"] as? [Double], p.count == 2 { pause = p[0]...p[1] }
            var clipY: Double?
            switch a["clip"] as? String {
            case "pipfloor2": clipY = 833
            case "pipfloor": clipY = 1102
            default: break
            }
            out[name] = SQMascotAnimation(
                kind: kind, tight: a["tight"] as? Bool ?? false,
                viewBox: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]), clipBottom: clipY,
                breath: a["breath"] as? Double ?? 1, pause: pause, rest: rest,
                still: try Self.pose(a["still"] as? [String: Any] ?? a["rest"] as? [String: Any] ?? [:], over: base),
                from: try (a["from"] as? [String: Any]).map { try Self.pose($0, over: base) },
                steps: steps)
        }
        anims = out
    }

    private static func shape(_ any: Any?) -> SQMascotShape? {
        guard let arr = any as? [Any], let kind = arr.first as? String else { return nil }
        return SQMascotShape(kind, arr.dropFirst().compactMap { ($0 as? NSNumber)?.doubleValue })
    }

    /// Builds a pose from a (partial) JSON dict on top of `base` (nil: the dict is the complete default).
    private static func pose(_ d: [String: Any], over base: SQMascotPose?) throws -> SQMascotPose {
        var p: SQMascotPose
        if let base { p = base } else {
            guard let l = shape(d["eL"]), let r = shape(d["eR"]), let m = shape(d["m"]) else { throw ParseError(detail: "default shapes") }
            p = SQMascotPose(n: Array(repeating: 0, count: SQMascotKey.allCases.count), eL: l, eR: r, m: m)
        }
        for k in SQMascotKey.allCases { if let v = (d[k.jsonKey] as? NSNumber)?.doubleValue { p[k] = v } }
        if base != nil {
            if let s = shape(d["eL"]) { p.eL = s }
            if let s = shape(d["eR"]) { p.eR = s }
            if let s = shape(d["m"]) { p.m = s }
        }
        return p
    }
}
