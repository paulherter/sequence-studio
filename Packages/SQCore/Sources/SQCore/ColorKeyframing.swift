import Foundation

// Keyframe control of the Color panel (INTERACTION-AUDIT §2): one slider, or one wheel group whose parameters (hue,
// amount, luma) animate together. `effect` is the inspector id of the Color effect (1-based, list order); `keys` are
// its parameter keys (`ClipEffect.color…Key`). Times are clip-local.

// Color wheel keys move the puck across the disc: hue and amount are stored as two tracks, but in a segment where
// both are keyed at the same two times with the same easing, the puck goes in a straight line from one key's position
// to the next (crossing near the center for opposite hues) instead of swinging round the hue circle. A hold on either
// track holds the puck. Anywhere else each track keeps its own evaluation (hue the short way, amount as keyed), so a
// wheel with only its hue animated never passes through the neutral center. Nothing new is stored; render, playback
// and export all read `colorEffect(atLocal:id:)`. Allocation-free: it runs per frame.

extension ClipEffect {
    /// Hue (degrees) and amount of wheel `pk` at clip-local `t` when the puck moves on the disc there; nil = evaluate
    /// each track on its own (not both keyed, keys at different times, different easing, or `t` on a key).
    func puckValue(_ pk: ColorPuckField, atLocal t: Time) -> (hue: Double, amount: Double)? {
        guard let h = parameters[pk.hueKey], let a = parameters[pk.amountKey],
              let i = h.track.segmentIndex(at: t), let j = a.track.segmentIndex(at: t) else { return nil }
        let h0 = h.track.keys[i], h1 = h.track.keys[i + 1], a0 = a.track.keys[j], a1 = a.track.keys[j + 1]
        guard h0.time == a0.time, h1.time == a1.time, t != h0.time else { return nil }
        if h0.interpolation.isHold || a0.interpolation.isHold {   // a Hold Ahead shows the next key already
            let ahead = h0.interpolation == .holdAhead || a0.interpolation == .holdAhead
            return ahead ? (h1.value, a1.value) : (h0.value, a0.value)
        }
        guard h0.outHandle == a0.outHandle, h1.inHandle == a1.inHandle else { return nil }
        var k0 = h0, k1 = h1
        k0.value = 0; k1.value = 1
        let f = KeyframeTrack<Double>.segmentValue(k0, k1, KeyframeMath.ratio(t - h0.time, h1.time - h0.time))
        let r0 = h0.value * .pi / 180, r1 = h1.value * .pi / 180
        let x = Double.lerp(cos(r0) * a0.value, cos(r1) * a1.value, f)
        let y = Double.lerp(sin(r0) * a0.value, sin(r1) * a1.value, f)
        let amount = (x * x + y * y).squareRoot()
        guard amount > 1e-9 else { return (h.hueValue(atLocal: t), 0) }
        return (HueMath.wrap(atan2(y, x) * 180 / .pi), amount)
    }

    /// After an edit at `t` (`before` = this effect before it): a wheel whose hue or amount got a new or changed key at
    /// `t` while its partner is animated without a key there gets the partner keyed at the value it showed, so the
    /// puck does not jump and the segment stays on the disc.
    mutating func keyWheelPartners(atLocal t: Time, before: ClipEffect) {
        for pk in ColorGradeFields.pucks {
            guard parameters[pk.hueKey]?.isAnimated == true, parameters[pk.amountKey]?.isAnimated == true else { continue }
            for (edited, partner) in [(pk.hueKey, pk.amountKey), (pk.amountKey, pk.hueKey)] {
                let now = parameters[edited]?.track.keys.first { $0.time == t }
                let was = before.parameters[edited]?.track.keys.first { $0.time == t }
                guard let now, was?.value != now.value,
                      parameters[partner]?.track.keys.contains(where: { $0.time == t }) == false,
                      let v = before.colorShownValue(partner, atLocal: t) else { continue }
                parameters[partner]?.track.insert(Keyframe(time: t, value: v))
            }
        }
    }

    /// The value parameter `key` of this Color effect shows at clip-local `t` (wheels on the disc, hues the short way).
    func colorShownValue(_ key: String, atLocal t: Time) -> Double? {
        if let pk = ColorGradeFields.pucks.first(where: { $0.hueKey == key || $0.amountKey == key }),
           let v = puckValue(pk, atLocal: t) {
            return key == pk.hueKey ? v.hue : v.amount
        }
        guard let p = parameters[key] else { return nil }
        return ColorGradeFields.scalars.first { $0.key == key }?.isHue == true ? p.hueValue(atLocal: t) : p.value(atLocal: t)
    }
}

extension Clip {
    /// Index in `effects` of Color effect `n` (1-based).
    private func colorEffectIndex(_ n: Int) -> Int? {
        let all = colorEffectIndices
        return n >= 1 && n <= all.count ? all[n - 1] : nil
    }

    private static func defaultValue(_ key: String) -> Double {
        ColorGradeFields.scalars.first { $0.key == key }?.spec.defaultValue ?? 0
    }

    /// True when any parameter of the group has keys.
    public func isColorAnimated(effect n: Int, keys: [String]) -> Bool {
        guard let i = colorEffectIndex(n) else { return false }
        return keys.contains { effects[i].parameters[$0]?.isAnimated == true }
    }

    /// Key times of the group (union of its parameters), ascending, without duplicates.
    public func colorKeyTimes(effect n: Int, keys: [String]) -> [Time] {
        guard let i = colorEffectIndex(n) else { return [] }
        let times = keys.flatMap { effects[i].parameters[$0]?.track.keys.map(\.time) ?? [] }
        return Array(Set(times)).sorted()
    }

    /// True when a parameter of the group has a key at `t`.
    public func hasColorKey(effect n: Int, keys: [String], atLocal t: Time) -> Bool {
        colorKeyTimes(effect: n, keys: keys).contains(t)
    }

    /// Edits Color effect `n` (a clip without Color effects gets a neutral one for `n == 1`). False = nothing changed.
    private mutating func editColorEffect(_ n: Int, _ body: (inout ClipEffect) -> Bool) -> Bool {
        var out = self
        if n == 1, out.colorEffectIndices.isEmpty {
            guard out.acceptsColor else { return false }
            out.effects.insert(ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic)), at: 0)
        }
        guard let i = out.colorEffectIndex(n), body(&out.effects[i]) else { return false }
        self = out
        return true
    }

    /// Animate on: every parameter of the group gets a key at `t` holding the value shown there (refused without `t`).
    /// Animate off: every key goes and the value at `t` (or the static value without `t`) stays.
    @discardableResult
    public mutating func setColorAnimated(_ on: Bool, effect n: Int, keys: [String], atLocal t: Time?) -> Bool {
        guard on != isColorAnimated(effect: n, keys: keys) else { return false }
        if on, t == nil { return false }
        return editColorEffect(n) { fx in
            let before = fx
            for k in keys {
                var p = fx.parameters[k] ?? AnimatedProperty(Self.defaultValue(k))
                let shown = t.flatMap { before.colorShownValue(k, atLocal: $0) } ?? (t.map { p.value(atLocal: $0) } ?? p.value)
                if on, let t {
                    p.track.insert(Keyframe(time: t, value: shown))
                } else {
                    p.value = shown
                    p.track = KeyframeTrack()
                }
                fx.parameters[k] = p
            }
            return true
        }
    }

    /// The diamond: a key of the group at `t` goes (a parameter left without keys keeps the value shown at `t`), else
    /// every parameter of the group gets a key at `t` with its value there. A static group starts animating.
    @discardableResult
    public mutating func toggleColorKey(effect n: Int, keys: [String], atLocal t: Time) -> Bool {
        let removing = hasColorKey(effect: n, keys: keys, atLocal: t)
        return editColorEffect(n) { fx in
            let before = fx
            for k in keys {
                var p = fx.parameters[k] ?? AnimatedProperty(Self.defaultValue(k))
                let shown = before.colorShownValue(k, atLocal: t) ?? p.value(atLocal: t)
                if removing {
                    guard let key = p.track.keys.first(where: { $0.time == t }) else { continue }
                    p.track.remove(key.id)
                    if p.track.isEmpty { p.value = shown }
                } else {
                    p.track.insert(Keyframe(time: t, value: shown))
                }
                fx.parameters[k] = p
            }
            return true
        }
    }
}
