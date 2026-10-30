import Foundation

/// A reference to something that lives in a bin: a nested bin, a media item or a sequence (timeline).
public enum BinItem: Sendable, Hashable, Codable {
    case bin(Bin)
    case media(MediaRef.ID)
    case sequence(Timeline.ID)

    /// Identity without payload, used to address items in move operations.
    public var ref: BinItemRef {
        switch self {
        case .bin(let b): .bin(b.id)
        case .media(let id): .media(id)
        case .sequence(let id): .sequence(id)
        }
    }
}

public enum BinItemRef: Sendable, Hashable, Codable {
    case bin(Bin.ID)
    case media(MediaRef.ID)
    case sequence(Timeline.ID)
}

/// A folder in the Project panel. Children keep their stored order (user order); sorting is an explicit operation.
public struct Bin: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var children: [BinItem]

    public init(id: UUID = UUID(), name: String, children: [BinItem] = []) {
        self.id = id; self.name = name; self.children = children
    }

    // MARK: Queries

    /// The bin with `id` anywhere in this subtree (including self).
    public func bin(_ id: Bin.ID) -> Bin? {
        if self.id == id { return self }
        for case .bin(let b) in children { if let f = b.bin(id) { return f } }
        return nil
    }

    /// All items in this subtree, depth first (not including self).
    public var allRefs: [BinItemRef] {
        children.flatMap { item -> [BinItemRef] in
            if case .bin(let b) = item { return [item.ref] + b.allRefs }
            return [item.ref]
        }
    }

    public func contains(_ ref: BinItemRef) -> Bool { allRefs.contains(ref) }

    /// ID of the bin directly containing `ref`, or nil if it is not in this subtree.
    public func parent(of ref: BinItemRef) -> Bin.ID? {
        if children.contains(where: { $0.ref == ref }) { return id }
        for case .bin(let b) in children { if let p = b.parent(of: ref) { return p } }
        return nil
    }

    /// Media IDs in this subtree, depth first.
    public var mediaIDs: [MediaRef.ID] {
        allRefs.compactMap { if case .media(let id) = $0 { id } else { nil } }
    }

    // MARK: Internal tree surgery

    @discardableResult
    mutating func modify(_ target: Bin.ID, _ body: (inout Bin) -> Void) -> Bool {
        if id == target { body(&self); return true }
        for i in children.indices {
            if case .bin(var b) = children[i], b.modify(target, body) { children[i] = .bin(b); return true }
        }
        return false
    }

    /// Removes the first occurrence of `ref` in this subtree and returns it.
    mutating func extract(_ ref: BinItemRef) -> BinItem? {
        if let i = children.firstIndex(where: { $0.ref == ref }) { return children.remove(at: i) }
        for i in children.indices {
            if case .bin(var b) = children[i], let item = b.extract(ref) { children[i] = .bin(b); return item }
        }
        return nil
    }

    /// Drops media and sequence references that fail `keep`, everywhere in the subtree.
    mutating func prune(_ keep: (BinItemRef) -> Bool) {
        children = children.compactMap { item in
            switch item {
            case .bin(var b): b.prune(keep); return .bin(b)
            default: return keep(item.ref) ? item : nil
            }
        }
    }
}

// MARK: - Project operations

public enum BinSortKey: Sendable, Equatable { case name, kind }

extension Project {
    /// Bins first, then sequences, then media.
    private static func kindRank(_ r: BinItemRef) -> Int {
        switch r { case .bin: 0; case .sequence: 1; case .media: 2 }
    }

    public func bin(_ id: Bin.ID) -> Bin? { rootBin.bin(id) }

    public func displayName(of ref: BinItemRef) -> String {
        switch ref {
        case .bin(let id): rootBin.bin(id)?.name ?? ""
        case .media(let id): media(id)?.name ?? ""
        case .sequence(let id): timelines.first { $0.id == id }?.name ?? ""
        }
    }

    /// Makes the bin tree consistent with `media` and `timelines`: unknown references are dropped,
    /// duplicates removed (first wins), items not in any bin are appended to the root bin.
    public mutating func normalizeBins() {
        let mediaIDs = Set(media.map(\.id)), seqIDs = Set(timelines.map(\.id))
        rootBin.prune { r in
            switch r {
            case .media(let id): mediaIDs.contains(id)
            case .sequence(let id): seqIDs.contains(id)
            case .bin: true
            }
        }
        var seen = Set<BinItemRef>()
        func dedupe(_ b: inout Bin) {
            b.children = b.children.compactMap { item in
                guard seen.insert(item.ref).inserted else { return nil }
                if case .bin(var sub) = item { dedupe(&sub); return .bin(sub) }
                return item
            }
        }
        dedupe(&rootBin)
        let filed = Set(rootBin.allRefs)
        for m in media where !filed.contains(.media(m.id)) { rootBin.children.append(.media(m.id)) }
        // The inside of an applied title template is not a sequence of its own (TitleTemplate.swift): not filed.
        let insides = titleTemplateInsides
        for t in timelines where t.group == nil && !filed.contains(.sequence(t.id)) && !insides.contains(t.id) {
            rootBin.children.append(.sequence(t.id))
        }
    }

    /// Creates an empty bin inside `parent` (default: root) and returns its ID; nil if `parent` does not exist.
    @discardableResult
    public mutating func newBin(name: String = "Folder", in parent: Bin.ID? = nil) -> Bin.ID? {
        let new = Bin(name: name)
        let ok = rootBin.modify(parent ?? rootBin.id) { $0.children.append(.bin(new)) }
        return ok ? new.id : nil
    }

    /// Renames a bin; false for an unknown bin or an empty name.
    @discardableResult
    public mutating func renameBin(_ id: Bin.ID, to name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return rootBin.modify(id) { $0.name = name }
    }

    /// Moves `items` into bin `dest`, preserving their given order. `index` is the insertion position among
    /// `dest`'s children after the moved items were removed (nil = append). Refused (returns false, nothing
    /// changes) if `dest` is unknown, an item is unknown or the root bin, or a bin would land in itself or a descendant.
    @discardableResult
    public mutating func move(_ items: [BinItemRef], to dest: Bin.ID, at index: Int? = nil) -> Bool {
        guard rootBin.bin(dest) != nil else { return false }
        var unique: [BinItemRef] = []
        for r in items where !unique.contains(r) { unique.append(r) }
        for r in unique {
            guard rootBin.contains(r) else { return false }
            if case .bin(let id) = r, let moving = rootBin.bin(id), moving.bin(dest) != nil { return false }
        }
        var copy = rootBin
        var extracted: [BinItem] = []
        for r in unique { if let item = copy.extract(r) { extracted.append(item) } }
        copy.modify(dest) { d in
            let i = min(max(index ?? d.children.count, 0), d.children.count)
            d.children.insert(contentsOf: extracted, at: i)
        }
        rootBin = copy
        return true
    }

    /// Deletes a bin; its children move into the parent at the bin's position. The root bin cannot be deleted.
    @discardableResult
    public mutating func deleteBin(_ id: Bin.ID) -> Bool {
        guard id != rootBin.id, let parentID = rootBin.parent(of: .bin(id)) else { return false }
        return rootBin.modify(parentID) { p in
            guard let i = p.children.firstIndex(where: { $0.ref == .bin(id) }),
                  case .bin(let doomed) = p.children[i] else { return }
            p.children.replaceSubrange(i...i, with: doomed.children)
        }
    }

    /// Sorts the direct children of a bin. Stable: equal keys keep their current relative order.
    @discardableResult
    public mutating func sortBin(_ id: Bin.ID, by key: BinSortKey, ascending: Bool = true) -> Bool {
        guard let current = rootBin.bin(id)?.children else { return false }
        let names = current.map { displayName(of: $0.ref) }
        let ranks = current.map { Self.kindRank($0.ref) }
        let order = current.indices.sorted { l, r in
            let cmp: ComparisonResult
            switch key {
            case .name: cmp = names[l].localizedStandardCompare(names[r])
            case .kind: cmp = ranks[l] == ranks[r] ? .orderedSame : (ranks[l] < ranks[r] ? .orderedAscending : .orderedDescending)
            }
            if cmp == .orderedSame { return l < r }     // stability
            return (cmp == .orderedAscending) == ascending
        }
        return rootBin.modify(id) { $0.children = order.map { current[$0] } }
    }
}
