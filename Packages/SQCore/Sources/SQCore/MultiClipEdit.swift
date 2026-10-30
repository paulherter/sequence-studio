import Foundation

/// Multi-select editing (Effect Controls / Text with several clips selected, Premiere): every field shows the value all
/// selected clips share, or nothing when they differ; an edit sets that one value on all of them.
public enum MultiValue {
    /// The value every element shares; nil when they differ or there is none.
    public static func common<V: Equatable>(_ values: some Sequence<V>) -> V? {
        var it = values.makeIterator()
        guard let first = it.next() else { return nil }
        while let v = it.next() { if v != first { return nil } }
        return first
    }
}

extension Clip {
    /// The effect on this clip that corresponds to `id` on `source`: the same kind at the same occurrence (the second
    /// Blur matches the second Blur). nil when this clip has fewer effects of that kind.
    public func matchingEffectID(for id: ClipEffect.ID, in source: Clip) -> ClipEffect.ID? {
        guard let e = source.effects.first(where: { $0.id == id }) else { return nil }
        let n = source.effects.prefix { $0.id != id }.filter { $0.kind == e.kind }.count
        let same = effects.filter { $0.kind == e.kind }
        return n < same.count ? same[n].id : nil
    }
}

/// Carries one edit of a Codable value (a text style) to other values field by field, through its JSON form: only the
/// fields the edit changed are written, everything else keeps the other value's own setting. Objects merge per key,
/// arrays and scalars are replaced whole; a group switched on or off (an optional present / absent) is switched the same.
public enum CodableMerge {
    /// `peer` with every field that differs between `old` and `new` set to `new`'s.
    /// `forcing`: dotted paths ("style.size", "style.shadow") copied from `new` even when the edit left them unchanged — a
    /// mixed field set to the shown item's own value. A whole group is copied or removed; a field inside a group the peer
    /// does not have is skipped.
    public static func carry<T: Codable>(from old: T, to new: T, into peer: T, forcing: Set<String> = []) throws -> T {
        let o = try object(old), n = try object(new)
        guard !NSDictionary(dictionary: o).isEqual(to: n) || !forcing.isEmpty else { return peer }
        var merged = merge(old: o, new: n, into: try object(peer))
        for path in forcing.sorted() { force(path.split(separator: ".").map(String.init), from: n, into: &merged) }
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func force(_ keys: [String], from new: [String: Any], into out: inout [String: Any]) {
        guard let key = keys.first else { return }
        if keys.count == 1 { out[key] = new[key]; return }
        guard let n = new[key] as? [String: Any], var o = out[key] as? [String: Any] else { return }
        force(Array(keys.dropFirst()), from: n, into: &o)
        out[key] = o
    }

    /// Dotted paths of the fields that are not the same in all `values`: a leaf ("shadow.blur") or, when a group is on in
    /// some and off in others, the group ("shadow").
    public static func differingPaths<T: Encodable>(_ values: [T]) throws -> Set<String> {
        guard values.count > 1 else { return [] }
        var out: Set<String> = []
        collect(try values.map(object), prefix: "", into: &out)
        return out
    }

    private static func object<T: Encodable>(_ v: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(v)
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return d
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): NSDictionary(dictionary: ["v": x]).isEqual(to: ["v": y])
        default: false
        }
    }

    private static func merge(old: [String: Any], new: [String: Any], into peer: [String: Any]) -> [String: Any] {
        var out = peer
        for key in Set(old.keys).union(new.keys) {
            let o = old[key], n = new[key]
            if same(o, n) { continue }
            if let od = o as? [String: Any], let nd = n as? [String: Any] {
                // A field inside a group: merge into the peer's group, or take the whole group when the peer has none.
                out[key] = (peer[key] as? [String: Any]).map { merge(old: od, new: nd, into: $0) } ?? nd
            } else {
                out[key] = n
            }
        }
        return out
    }

    private static func collect(_ objects: [[String: Any]], prefix: String, into out: inout Set<String>) {
        let keys = objects.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        for key in keys {
            let path = prefix.isEmpty ? key : prefix + "." + key
            let vals = objects.map { $0[key] }
            if vals.allSatisfy({ $0 == nil }) { continue }
            if vals.contains(where: { $0 == nil }) { out.insert(path); continue }
            let dicts = vals.compactMap { $0 as? [String: Any] }
            if dicts.count == vals.count { collect(dicts, prefix: path, into: &out); continue }
            if vals.dropFirst().contains(where: { !same($0, vals[0]) }) { out.insert(path) }
        }
    }
}
