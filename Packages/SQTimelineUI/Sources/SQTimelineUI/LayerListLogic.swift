import SQUIKit
import Foundation
import SQCore

/// One row of the Graphics layer list (front first): a group header or a layer.
public struct LayerListRow: Equatable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable { case group(UUID), layer(UUID) }
    public var kind: Kind
    public var name: String
    /// SF Symbol of the layer kind (groups: none, they draw the disclosure chevron).
    public var symbol: SQIcon?
    /// Group of a layer row (indented under its header); a group row's own id.
    public var group: UUID?
    /// Group rows: every member visible / locked. Layer rows: the layer's flags.
    public var isVisible: Bool
    public var isLocked: Bool
    /// Group rows: open (members shown).
    public var isOpen: Bool
    /// Color label: a layer's own; a group row's when every member has the same one.
    public var label: LabelColor?

    public var layerID: UUID? { if case .layer(let id) = kind { id } else { nil } }
    public var groupID: UUID? { if case .group(let id) = kind { id } else { nil } }
    public var isIndented: Bool { layerID != nil && group != nil }
}

/// What a drag in the layer list carries: selected layers, or one group (its header was dragged).
public enum LayerDrag: Equatable, Sendable {
    case layers([UUID])
    case group(UUID)
}

/// Where a drop goes, as `GraphicsDocument.move(_:toIndex:group:)` arguments.
public struct LayerDrop: Equatable, Sendable {
    public var ids: [UUID]
    /// Index in the layer list without the moving layers (0 = bottom).
    public var toIndex: Int
    /// The group the moved layers end up in (nil = none).
    public var group: UUID?
}

/// Pure layer list logic of the Graphics panel: rows from the document, drop targets and shift-range selection.
public enum LayerListLogic {
    /// Rows front first. A group header stands where its front-most member is; its members follow, indented, unless the
    /// group is collapsed.
    public static func rows(_ d: GraphicsDocument, collapsed: Set<UUID> = []) -> [LayerListRow] {
        var out: [LayerListRow] = []
        var seen = Set<UUID>()
        for l in d.layers.reversed() {
            if let g = l.group, let group = d.group(g) {
                if !seen.contains(g) {
                    seen.insert(g)
                    let members = d.layers.filter { $0.group == g }
                    out.append(LayerListRow(kind: .group(g), name: group.name, symbol: nil, group: g,
                                            isVisible: members.allSatisfy(\.isVisible), isLocked: members.allSatisfy(\.isLocked),
                                            isOpen: !collapsed.contains(g),
                                            label: Set(members.map(\.label)).count == 1 ? members[0].label : nil))
                }
                if collapsed.contains(g) { continue }
                out.append(row(l, group: g))
            } else {
                out.append(row(l, group: nil))
            }
        }
        return out
    }

    private static func row(_ l: GraphicsLayer, group: UUID?) -> LayerListRow {
        LayerListRow(kind: .layer(l.id), name: l.name, symbol: symbol(l), group: group,
                     isVisible: l.isVisible, isLocked: l.isLocked, isOpen: false, label: l.label)
    }

    /// Clip-local times of every key of the layer (Motion, Opacity and every effect parameter), sorted, without duplicates.
    public static func keyTimes(_ l: GraphicsLayer) -> [Time] {
        let a = l.animation
        var t: [Time] = a.position.track.keys.map(\.time) + a.anchor.track.keys.map(\.time)
            + a.scale.track.keys.map(\.time) + a.rotation.track.keys.map(\.time) + a.opacity.track.keys.map(\.time)
        for e in l.effects { t += e.keyTimes }
        return Array(Set(t)).sorted()
    }

    /// A ranged item is outside its range at the clip-local playhead: its row is dimmed (it draws nothing there).
    /// Never with the playhead outside the clip (`local` nil), and never for an item that shows over the whole clip.
    public static func isOutsideRange(_ l: GraphicsLayer, local: Time?) -> Bool {
        guard let t = local, l.range != nil else { return false }
        return !l.isShown(atLocal: t)
    }

    public static func symbol(_ l: GraphicsLayer) -> SQIcon {
        switch l.content {
        case .shape(.rectangle): .shapeRectangle
        case .shape(.ellipse): .shapeEllipse
        case .shape(.line): .shapeLine
        case .shape(.arrow): .arrowUpRight
        case .path: .draw
        case .text: .text
        }
    }

    /// The layers a drag moves.
    public static func ids(_ drag: LayerDrag, in d: GraphicsDocument) -> [UUID] {
        switch drag {
        case .layers(let ids): let s = Set(ids); return d.layers.map(\.id).filter(s.contains)
        case .group(let g): return d.layers.filter { $0.group == g }.map(\.id)
        }
    }

    /// Drop of `drag` into the gap before `rows[gap]` (`rows.count` = after the last row), or onto the group row `onto`
    /// (layers join that group at its top). A layer dropped between two members of a group joins it, anywhere else it
    /// leaves its group; a dragged group never lands inside another one (it goes above it). nil when nothing changes (`forCopy`: never, a copy always adds layers).
    public static func drop(_ drag: LayerDrag, rows: [LayerListRow], document d: GraphicsDocument,
                            gap: Int, onto: Int? = nil, forCopy: Bool = false) -> LayerDrop? {
        let ids = ids(drag, in: d)
        guard !ids.isEmpty else { return nil }
        let moving = Set(ids)
        let rest = d.layers.filter { !moving.contains($0.id) }
        func isDragged(_ r: LayerListRow) -> Bool {
            if let id = r.layerID { return moving.contains(id) }
            if case .group(let g) = drag, r.groupID == g { return true }
            return false
        }
        /// Index in `rest` right above the front-most member of `g`.
        func aboveGroup(_ g: UUID) -> Int { (rest.lastIndex { $0.group == g }).map { $0 + 1 } ?? rest.count }

        var toIndex: Int
        var group: UUID?
        if let onto, rows.indices.contains(onto), let g = rows[onto].groupID {
            toIndex = aboveGroup(g)          // the top of the group, right above its front-most remaining member
            group = g                        // a dragged group goes above it instead (below)
        } else {
            let g = min(max(gap, 0), rows.count)
            let below = rows[g...].first { !isDragged($0) }
            switch below {
            case nil: toIndex = 0; group = nil
            case .some(let r):
                if let gid = r.groupID {
                    toIndex = aboveGroup(gid); group = nil
                } else if let id = r.layerID, let i = rest.firstIndex(where: { $0.id == id }) {
                    toIndex = i + 1; group = r.group
                } else { return nil }
            }
        }
        if case .group(let own) = drag {
            if let inside = group, inside != own { toIndex = aboveGroup(inside) }
            group = own
        }
        var after = d
        after.move(ids, toIndex: toIndex, group: group)
        guard forCopy || after != d else { return nil }
        return LayerDrop(ids: ids, toIndex: toIndex, group: group)
    }

    /// Click selection on `rows[index]`: plain = only it, `toggle` (Cmd) = add / remove it, `range` (Shift) = every row
    /// from `anchor` to it. A group row stands for all its members.
    public static func select(rows: [LayerListRow], document d: GraphicsDocument, current: Set<UUID>, index: Int,
                              anchor: Int?, toggle: Bool, range: Bool) -> Set<UUID> {
        guard rows.indices.contains(index) else { return current }
        func members(_ r: LayerListRow) -> Set<UUID> {
            if let id = r.layerID { return [id] }
            if let g = r.groupID { return Set(d.layers.filter { $0.group == g }.map(\.id)) }
            return []
        }
        let hit = members(rows[index])
        if range, let anchor, rows.indices.contains(anchor) {
            let lo = min(anchor, index), hi = max(anchor, index)
            return rows[lo...hi].reduce(into: Set<UUID>()) { $0.formUnion(members($1)) }
        }
        if toggle { return hit.isSubset(of: current) ? current.subtracting(hit) : current.union(hit) }
        return hit
    }

    /// A row shows selected: a layer in the selection, a group whose members all are.
    public static func isSelected(_ r: LayerListRow, document d: GraphicsDocument, selection: Set<UUID>) -> Bool {
        if let id = r.layerID { return selection.contains(id) }
        guard let g = r.groupID else { return false }
        let m = d.layers.filter { $0.group == g }.map(\.id)
        return !m.isEmpty && m.allSatisfy(selection.contains)
    }
}
