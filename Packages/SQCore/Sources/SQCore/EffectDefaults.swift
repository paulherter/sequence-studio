import Foundation

/// FB-W: the user's own starting values for effects and transitions ("Use as Default" in Effect Controls). Lives in the
/// user library (never in a project), so every project and every new instance picks it up.
///
/// - Effects: one default per effect kind. Key times are clip-local, i.e. relative to the clip's first frame, and land
///   at the same offsets on the clip a new instance is added to. Color and generator-owned kinds have none.
/// - Transitions: one default per kind (kind, length, easing, direction, softness, motion blur, element parameters),
///   used at every place a transition of that kind is added: cuts, clip starts and clip ends. The place decides the
///   alignment.
/// - Order: a preset wins over a default (it is applied on top); a Style Kit's motion settings apply after the default.
public struct EffectDefaults: Sendable, Hashable, Codable {
    public static let payloadVersion = 1

    public enum PayloadError: Error, Equatable, Sendable {
        case newerVersion(found: Int, supported: Int)
    }

    /// By effect kind. Ids inside are meaningless (every use gets fresh ones).
    public var effects: [String: ClipEffect]
    /// By `TransitionKind.rawValue`.
    public var transitions: [String: TransitionPreset]

    public init(effects: [String: ClipEffect] = [:], transitions: [String: TransitionPreset] = [:]) {
        self.effects = effects; self.transitions = transitions
    }

    public var isEmpty: Bool { effects.isEmpty && transitions.isEmpty }

    // MARK: Effects

    /// Known effect kinds except Color (a grade belongs to its footage) and generator-owned looks.
    public static func canHaveDefault(kind: String) -> Bool {
        guard let e = ClipEffect.make(kind: kind) else { return false }
        return !e.isColor && !EffectCatalog.isGeneratorOwned(kind)
    }

    public func hasDefault(effect kind: String) -> Bool { effects[kind] != nil }

    public func effect(_ kind: String) -> ClipEffect? { effects[kind] }

    /// Makes `effect`'s values the default of its kind. `keepKeyframes` false: every parameter is frozen at clip-local
    /// `t` (the value shown at the playhead). False for a kind that cannot have a default.
    @discardableResult
    public mutating func setDefault(from effect: ClipEffect, keepKeyframes: Bool, at t: Time) -> Bool {
        guard Self.canHaveDefault(kind: effect.kind) else { return false }
        var e = keepKeyframes ? effect : effect.frozen(atLocal: t)
        e.id = UUID(); e.enabled = true
        effects[effect.kind] = e
        return true
    }

    public mutating func removeDefault(effect kind: String) { effects[kind] = nil }

    /// A new instance of `kind`: the user default (fresh ids for the effect and every key) laid over the factory values,
    /// so parameters added to the catalog since start at factory and ones it dropped are ignored. Factory when there is
    /// no default; nil for an unknown kind.
    public func makeEffect(kind: String) -> ClipEffect? {
        guard var out = ClipEffect.make(kind: kind) else { return nil }
        guard let saved = effects[kind], Self.canHaveDefault(kind: kind) else { return out }
        for key in out.parameters.keys { if let p = saved.parameters[key] { out.parameters[key] = p.withFreshKeyIDs() } }
        for key in out.colors.keys { if let p = saved.colors[key] { out.colors[key] = p.withFreshKeyIDs() } }
        for key in out.points.keys { if let p = saved.points[key] { out.points[key] = p.withFreshKeyIDs() } }
        return out
    }

    // MARK: Transitions

    public func hasDefault(transition kind: TransitionKind) -> Bool { transitions[kind.rawValue] != nil }

    public func transition(_ kind: TransitionKind) -> TransitionPreset? { transitions[kind.rawValue] }

    /// Makes `transition`'s look (and requested length) the default of its kind.
    public mutating func setDefault(from transition: Transition) {
        transitions[transition.kind.rawValue] = TransitionPreset.capture(from: transition)
    }

    public mutating func removeDefault(transition kind: TransitionKind) { transitions[kind.rawValue] = nil }

    // MARK: Payload

    public func payload() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else { throw PayloadError.newerVersion(found: version, supported: Self.payloadVersion) }
        self = try JSONDecoder().decode(EffectDefaults.self, from: payload)
        effects = effects.mapValues { $0.upgradingLegacyShadowColor() }
        for (k, var p) in transitions where p.alignment == .custom { p.alignment = .center; transitions[k] = p }
    }
}

extension AnimatedProperty {
    /// Same value and keys, every key with a new id.
    public func withFreshKeyIDs() -> AnimatedProperty {
        var c = self
        c.track = KeyframeTrack(keys: track.keys.map { var k = $0; k.id = UUID(); return k })
        return c
    }

    /// Same value and the same keys (time, value, easing) whatever their ids.
    public func sameCurve(as other: AnimatedProperty) -> Bool {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func plain(_ p: AnimatedProperty) -> [Keyframe<V>] { p.track.keys.map { var k = $0; k.id = zero; return k } }
        return value == other.value && plain(self) == plain(other)
    }
}

extension Clip {
    /// "Reset" of an applied effect: its values go back to the user default of its kind (keys included), else to the
    /// factory values. Stays where it is with its id, and is switched on again. False for an unknown id.
    @discardableResult
    public mutating func resetEffect(_ id: ClipEffect.ID, defaults: EffectDefaults?) -> Bool {
        guard let i = effects.firstIndex(where: { $0.id == id }),
              let fresh = (defaults ?? EffectDefaults()).makeEffect(kind: effects[i].kind) else { return false }
        effects[i].parameters = fresh.parameters
        effects[i].colors = fresh.colors
        effects[i].points = fresh.points
        effects[i].enabled = true
        return true
    }
}

extension Timeline {
    /// A transition default's look on the new transition `id`: easing, direction, softness, motion blur and element
    /// parameters. Kind, length and alignment are left alone (the caller placed it).
    public mutating func applyTransitionDefault(_ d: TransitionPreset, to id: Transition.ID) throws {
        try setTransition(id, easing: d.easing, direction: d.direction, softness: d.softness, motionBlur: d.motionBlur,
                          reversed: d.reversed ?? false)
        try replaceTransitionBorder(id, width: d.borderWidth, color: d.borderColor)
        if d.kind.hasParams, let tr = transition(id)?.1, tr.kind == d.kind {
            try setTransition(id, params: (d.params ?? [:]).filter { d.kind.elementParam($0.key) != nil }, replacing: true)
        }
    }

    /// "Reset" of a transition: its length and look go back to `userDefault` (same kind), else to the factory look
    /// (no own style) at `factoryDuration`. Kind and alignment stay.
    public mutating func resetTransition(_ id: Transition.ID, to userDefault: TransitionPreset?, factoryDuration: Time) throws {
        guard let (tid, tr) = transition(id), let ti = tracks.firstIndex(where: { $0.id == tid }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        let d = userDefault?.kind == tr.kind ? userDefault : nil
        if let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) {
            var n = tracks[ti].transitions[ni]
            n.easing = nil; n.direction = nil; n.softness = nil; n.motionBlur = nil; n.params = nil; n.reversed = nil
            n.borderWidth = nil; n.borderColor = nil
            tracks[ti].transitions[ni] = n
        }
        try setTransition(id, duration: d?.duration ?? factoryDuration)
        if let d { try applyTransitionDefault(d, to: id) } else { try applyFactoryLook(id) }
    }
}
