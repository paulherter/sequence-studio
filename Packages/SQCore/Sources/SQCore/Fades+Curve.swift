import Foundation

/// Shape of an audio fade (right-click menu on a fade handle). The shape lives in the ease handles of the fade's two
/// marked keys (the first key's out handle, the second key's in handle), so no model field and no file version is needed:
/// a fade without handles is `linear`.
public enum FadeCurve: String, Sendable, Hashable, CaseIterable, Codable {
    /// Constant slope.
    case linear
    /// Slow start, fast middle, slow end.
    case sCurve
    /// Equal-power shape: the level moves like the square root of the progress (the fade is louder in the middle than
    /// the linear one by up to 3 dB).
    case plus3dB
    /// The opposite: the level moves like the square of the progress (quieter in the middle, up to 3 dB below linear).
    case minus3dB

    public var title: String {
        switch self {
        case .linear: "Linear"
        case .sCurve: "S-Curve"
        case .plus3dB: "+3 dB"
        case .minus3dB: "-3 dB"
        }
    }

    /// Handles (out of the first key, in of the second key) that shape a fade IN (level rising) or a fade OUT.
    /// A fade out is the time mirror of the fade in: the progress is `1 - f(1 - t)`, which swaps and keeps the handles.
    func handles(fadeIn: Bool) -> (out: EaseHandle, in: EaseHandle) {
        let h: (out: EaseHandle, in: EaseHandle)
        switch self {
        case .linear: return (.linear, .linear)
        case .sCurve: return (EaseHandle(dx: 1.0 / 3, dy: 0), EaseHandle(dx: 1.0 / 3, dy: 0))
        // y = sqrt(x) as a cubic bezier: P1 = (0, 1/3), P2 = (1/3, 2/3).
        case .plus3dB: h = (EaseHandle(dx: 0, dy: 1.0 / 3), EaseHandle(dx: 2.0 / 3, dy: 1.0 / 3))
        // y = x * x: P1 = (1/3, 0), P2 = (2/3, 1/3).
        case .minus3dB: h = (EaseHandle(dx: 1.0 / 3, dy: 0), EaseHandle(dx: 1.0 / 3, dy: 2.0 / 3))
        }
        return fadeIn ? h : (out: h.in, in: h.out)
    }
}

extension FadeKeys {
    /// Curve of the head (`head`) or tail fade; `.linear` for a fade without handles or with a hand-made curve, nil
    /// when there is no such fade.
    public static func curve(of p: AnimatedProperty<Double>, marks: FadeMarks, head: Bool) -> FadeCurve? {
        let ids = head ? marks.head : marks.tail
        guard ids.count == 2, let a = p.track.key(id: ids[0]), let b = p.track.key(id: ids[1]) else { return nil }
        for c in FadeCurve.allCases {
            let h = c.handles(fadeIn: head)
            if close(a.outHandle, h.out), close(b.inHandle, h.in) { return c }
        }
        return .linear
    }

    /// The property with the head or tail fade shaped as `curve`; unchanged when there is no such fade.
    public static func setting(curve: FadeCurve, on prop: AnimatedProperty<Double>, marks: FadeMarks, head: Bool) -> AnimatedProperty<Double> {
        let ids = head ? marks.head : marks.tail
        guard ids.count == 2, let ai = prop.track.keys.firstIndex(where: { $0.id == ids[0] }),
              let bi = prop.track.keys.firstIndex(where: { $0.id == ids[1] }) else { return prop }
        var p = prop
        let h = curve.handles(fadeIn: head)
        p.track.keys[ai].outHandle = h.out
        p.track.keys[ai].interpolation = curve == .linear ? .linear : .bezier
        p.track.keys[bi].inHandle = h.in
        return p
    }

    private static func close(_ a: EaseHandle, _ b: EaseHandle) -> Bool { abs(a.dx - b.dx) < 1e-6 && abs(a.dy - b.dy) < 1e-6 }
}

extension Clip {
    /// Shape of the audio fade in / out; nil without that fade.
    public var audioFadeInCurve: FadeCurve? { FadeKeys.curve(of: animation.volume, marks: audioFades, head: true) }
    public var audioFadeOutCurve: FadeCurve? { FadeKeys.curve(of: animation.volume, marks: audioFades, head: false) }

    public mutating func setAudioFadeCurve(_ curve: FadeCurve, head: Bool) {
        animation.volume = FadeKeys.setting(curve: curve, on: animation.volume, marks: audioFades, head: head)
    }
}

/// User setting: the shape a new audio fade gets when its handle is dragged (`sq.audio.defaultFadeCurve`, a `FadeCurve`
/// raw value; missing or unknown = linear). Preferences > Audio > Fade Shape writes it; every timeline host reads it.
public enum DefaultFadeCurve {
    public static let defaultsKey = "sq.audio.defaultFadeCurve"
    public static func current(_ defaults: UserDefaults = .standard) -> FadeCurve {
        defaults.string(forKey: defaultsKey).flatMap(FadeCurve.init(rawValue:)) ?? .linear
    }
    public static func set(_ curve: FadeCurve, defaults: UserDefaults = .standard) { defaults.set(curve.rawValue, forKey: defaultsKey) }
}
