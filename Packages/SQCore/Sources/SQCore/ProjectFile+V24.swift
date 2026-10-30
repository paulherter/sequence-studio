import Foundation

extension ProjectFile {
    /// v24 (W1.5, typed effect parameters): `ClipEffect.colors` / `ClipEffect.points` (optional on decode). Drop Shadow's
    /// three 0...255 channels (`shadowRed/Green/Blue`) become one color parameter `shadowColor`
    /// (`ClipEffect.upgradingLegacyShadowColor`); Shadow Only keeps its stored 0/1 value (now shown as a checkbox, still on
    /// from 0.5), so nothing to change there. A project that does not decode is passed on unchanged (the final decode
    /// then reports it). Older builds drop the color on save and render a black shadow.
    static func migrateV23toV24(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              var project = try? decoder().decode(Project.self, from: raw) else { return obj }
        guard project.migrateLegacyShadowColor() else { return obj }
        guard let data = try? encoder().encode(project),
              let migrated = try? JSONSerialization.jsonObject(with: data) else { return obj }
        o["project"] = migrated
        return o
    }
}

extension Project {
    /// Runs `ClipEffect.upgradingLegacyShadowColor` on every effect of every clip. True when anything changed.
    @discardableResult
    mutating func migrateLegacyShadowColor() -> Bool {
        var changed = false
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                for c in timelines[ti].tracks[tr].clips where c.effects.contains(where: \.hasLegacyShadowColor) {
                    var n = c
                    n.effects = c.effects.map { $0.upgradingLegacyShadowColor() }
                    timelines[ti].tracks[tr].replace(n)
                    changed = true
                }
            }
        }
        return changed
    }
}

extension ClipEffect {
    var hasLegacyShadowColor: Bool {
        kind == Self.dropShadowKind
            && [Self.shadowRedKey, Self.shadowGreenKey, Self.shadowBlueKey].contains { parameters[$0] != nil }
    }

    /// A v23 Drop Shadow with its three 0...255 channel parameters folded into the color parameter `shadowColor`
    /// (channel / 255, alpha 1; the evaluation clamps to 0...1 like the old one clamped to 0...255); anything else is
    /// returned unchanged. Public so other stored effects (presets, clipboards) can upgrade the same way.
    ///
    /// Static channels give a static color. With keys, the color gets a key at every time any channel had one, with
    /// each channel's value there. Between two such times the color takes the one shape every changing channel shares
    /// (hold, linear, or the same ease handles), which reproduces the old result at every instant. Where the changing
    /// channels differ (say red hold and green linear, or different handles, or an eased channel cut by another
    /// channel's key), that stretch is sampled every 1/30 s (at most 300 samples) into linear keys: exact at those
    /// samples, linear in between.
    public func upgradingLegacyShadowColor() -> ClipEffect {
        guard hasLegacyShadowColor else { return self }
        let keys = [Self.shadowRedKey, Self.shadowGreenKey, Self.shadowBlueKey]
        let channels = keys.map { parameters[$0] ?? AnimatedProperty(0) }
        func colour(at t: Time?) -> EffectColor {
            let v = channels.map { p -> Double in (t.map { p.value(atLocal: $0) } ?? p.value) / 255 }
            return EffectColor(red: v[0], green: v[1], blue: v[2])
        }
        var out = self
        for k in keys { out.parameters[k] = nil }
        var prop = AnimatedProperty(colour(at: nil))
        let times = Set(channels.flatMap { $0.track.keys.map(\.time) }).sorted()
        if !times.isEmpty {
            // The static fallback mirrors the curve's start so removing all keys later shows the same color.
            prop.value = colour(at: times[0])
            var built = times.map { Keyframe(time: $0, value: colour(at: $0)) }
            var samples: [Keyframe<EffectColor>] = []
            for i in built.indices.dropLast() {
                let a = built[i].time, b = built[i + 1].time
                let shapes = channels.map { LegacySegmentShape($0, from: a, to: b) }
                let changing = Set(shapes.filter { $0 != .constant })
                switch changing.count == 1 ? changing.first! : (changing.isEmpty ? .constant : nil) {
                case .hold?:
                    built[i].interpolation = .hold
                case .eased(let o, let inH)?:
                    built[i].outHandle = o; built[i + 1].inHandle = inH
                    built[i].interpolation = o == .linear && inH == .linear ? .linear : .bezier
                case .constant?:
                    break
                case .unrepresentable?, nil:
                    let d = b - a
                    let n = Int64(min(max((KeyframeMath.seconds(d) * 30).rounded(.up), 1), 300))
                    for j in 1..<n { let t = a + Time.scaled(d, by: j, over: n); samples.append(Keyframe(time: t, value: colour(at: t))) }
                }
            }
            for k in built + samples { prop.track.insert(k) }
        }
        out.colors[Self.shadowColorKey] = prop
        return out
    }
}

/// How one legacy channel moves between two consecutive merged key times `a` and `b` (no channel has a key between).
enum LegacySegmentShape: Hashable {
    case constant, hold, eased(EaseHandle, EaseHandle), unrepresentable

    init(_ p: AnimatedProperty<Double>, from a: Time, to b: Time) {
        let keys = p.track.keys
        guard let ka = keys.last(where: { $0.time <= a }), let kb = keys.first(where: { $0.time >= b }) else {
            self = .constant; return      // before the first or after the last key: flat
        }
        if ka.value == kb.value { self = .constant; return }
        if ka.interpolation == .hold { self = kb.time == b ? .hold : .constant; return }
        if ka.time == a && kb.time == b { self = .eased(ka.outHandle, kb.inHandle); return }
        // Part of a longer segment: only a straight one stays straight when cut.
        self = ka.outHandle == .linear && kb.inHandle == .linear ? .eased(.linear, .linear) : .unrepresentable
    }
}
