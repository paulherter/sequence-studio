import Foundation

/// Ease for a pair of adjacent selected keys: sets both sides of the segment in one go
/// (out of the first key, in of the second). `in` eases the arrival, `out` the departure.
public enum PairEase: Sendable, Hashable {
    case `in`, out, inOut

    var easesOut: Bool { self != .in }
    var easesIn: Bool { self != .out }
}

extension KeyframeTrack {
    /// True if two neighboring keys are both in `ids`.
    public func hasAdjacentPair(_ ids: Set<UUID>) -> Bool {
        return zip(keys, keys.dropFirst()).contains { ids.contains($0.id) && ids.contains($1.id) }
    }

    /// Eases every segment whose two keys are both selected. Other keys are untouched. Returns segments changed.
    @discardableResult
    public mutating func applyPairEase(_ ease: PairEase, to ids: Set<UUID>) -> Int {
        let flat = EasingCurve.easeInOut.outHandle
        return editKeys { keys in
            var n = 0
            for i in keys.indices.dropLast() where ids.contains(keys[i].id) && ids.contains(keys[i + 1].id) {
                // Only the side the ease targets is written; the other side keeps whatever it had.
                if ease.easesOut {
                    keys[i].outHandle = flat
                    if keys[i].interpolation == .linear { keys[i].interpolation = .bezier }   // Hold stays Hold
                }
                if ease.easesIn { keys[i + 1].inHandle = flat }
                n += 1
            }
            return n
        }
    }

    /// Ids of selected keys that belong to an adjacent selected pair.
    public func pairedKeyIDs(_ ids: Set<UUID>) -> Set<UUID> {
        var out = Set<UUID>()
        for (a, b) in zip(keys, keys.dropFirst()) where ids.contains(a.id) && ids.contains(b.id) { out.insert(a.id); out.insert(b.id) }
        return out
    }
}

extension PropertyTrack {
    func hasAdjacentPair(_ ids: Set<UUID>) -> Bool {
        switch self {
        case .scalar(let t): t.hasAdjacentPair(ids)
        case .vector(let t): t.hasAdjacentPair(ids)
        case .color(let t): t.hasAdjacentPair(ids)
        case .path(let t): t.hasAdjacentPair(ids)
        }
    }

    func pairedKeyIDs(_ ids: Set<UUID>) -> Set<UUID> {
        switch self {
        case .scalar(let t): t.pairedKeyIDs(ids)
        case .vector(let t): t.pairedKeyIDs(ids)
        case .color(let t): t.pairedKeyIDs(ids)
        case .path(let t): t.pairedKeyIDs(ids)
        }
    }

    mutating func applyPairEase(_ ease: PairEase, to ids: Set<UUID>) -> Int {
        switch self {
        case .scalar(var t): let n = t.applyPairEase(ease, to: ids); self = .scalar(t); return n
        case .vector(var t): let n = t.applyPairEase(ease, to: ids); self = .vector(t); return n
        case .color(var t): let n = t.applyPairEase(ease, to: ids); self = .color(t); return n
        case .path(var t): let n = t.applyPairEase(ease, to: ids); self = .path(t); return n
        }
    }
}

extension KeyframeSummary {
    public func hasAdjacentPair(_ members: Set<SummaryMember>) -> Bool {
        var by: [PropertyID: Set<UUID>] = [:]
        for m in members { by[m.property, default: []].insert(m.keyID) }
        return by.contains { p, ids in tracks[p]?.hasAdjacentPair(ids) ?? false }
    }

    /// Pair ease on every property of the selection. Returns segments changed (0 = nothing adjacent selected).
    @discardableResult
    public mutating func applyPairEase(_ ease: PairEase, to members: Set<SummaryMember>) -> Int {
        var by: [PropertyID: Set<UUID>] = [:]
        for m in members { by[m.property, default: []].insert(m.keyID) }
        var n = 0
        for (p, ids) in by { n += tracks[p]?.applyPairEase(ease, to: ids) ?? 0 }
        return n
    }
}

extension KeyframeSummary {
    /// Per property: keys in an adjacent selected pair get pair semantics (for Ease In / Out / In & Out); every other
    /// selected key gets the normal one-sided `choice` curve. Other choices apply as before.
    public mutating func apply(_ choice: KeyInterpolationChoice, to members: Set<SummaryMember>) {
        var by: [PropertyID: Set<UUID>] = [:]
        for m in members { by[m.property, default: []].insert(m.keyID) }
        for (p, ids) in by {
            guard var t = tracks[p] else { continue }
            var rest = ids
            if let pair = choice.pairEase {
                let paired = t.pairedKeyIDs(ids)
                if !paired.isEmpty { _ = t.applyPairEase(pair, to: paired); rest.subtract(paired) }
            }
            if !rest.isEmpty { t.apply(choice, to: rest) }
            tracks[p] = t
        }
    }
}

extension KeyInterpolationChoice {
    /// The pair variant of the three ease entries (nil for the others).
    public var pairEase: PairEase? {
        switch self {
        case .easeIn: .in
        case .easeOut: .out
        case .easyEase: .inOut
        default: nil
        }
    }
}
