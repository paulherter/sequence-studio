import Foundation
import SQCore

/// The Graphics panel's rules both panels share (the Mac `GraphicsPanelView` and the draw-list `GraphicsPanelDraw`):
/// when the property rows rebuild, which layers count as lines. Portable (Windows too).
@MainActor public enum GraphicsPanelLogic {
    /// What decides the property rows: clip, selection, the selected layer's effects, draw mode.
    public static func structure(_ e: GraphicsEditor) -> String {
        guard let c = e.clip, c.graphics != nil else {
            return "none#" + (GraphicsEmptyState.resolve(e.session.singleSelectedClip).map { "\($0)" } ?? "")
        }
        var s = c.id.uuidString
        s += "#" + e.selectedLayers.map(\.uuidString).sorted().joined(separator: ",")
        s += "#" + e.targetLayers.map(kindTag).joined(separator: ",")
        if let l = e.selectedLayer { s += "#" + l.effects.map { "\($0.id)\($0.enabled)" }.joined(separator: ",") }
        if e.selectedLayers.isEmpty { s += c.zones == nil ? "#zonesOff" : "#zonesOn" }
        // Follow rows: present only while following; the popup lists the layers by name.
        if let l = e.selectedLayer {
            s += "#follow:" + (l.follow.map { "\($0.target)" } ?? "-") + ":" + e.followCandidates.map(\.name).joined(separator: ",")
        }
        s += e.isDrawing ? "#draw" : ""
        return s
    }

    /// Kind tag for the structure key (a kind change rebuilds the Shape rows).
    public nonisolated static func kindTag(_ l: GraphicsLayer) -> String {
        switch l.content {
        case .shape(let k): k.rawValue
        case .path(_, let closed): closed ? "closedPath" : "path"
        case .text: "text"
        }
    }

    /// The selected items Controls > Graphic edits (Corners, Fill, Outline): two or more shape and path items, none of
    /// them text. One picked item shows as its own clip, so its Shape section carries these values already.
    public nonisolated static func itemRowLayers(_ layers: [GraphicsLayer]) -> [GraphicsLayer] {
        guard layers.count > 1, layers.allSatisfy({ !$0.isText }) else { return [] }
        return layers
    }

    /// Corners only when every row item is a rectangle.
    public nonisolated static func allRectangles(_ layers: [GraphicsLayer]) -> Bool {
        layers.allSatisfy { if case .shape(.rectangle) = $0.content { true } else { false } }
    }

    /// Lines, arrows and open paths have a length and no fill.
    public nonisolated static func isLineLike(_ l: GraphicsLayer) -> Bool {
        switch l.content {
        case .shape(let k): k == .line || k == .arrow
        case .path(_, let closed): !closed
        case .text: false
        }
    }
}
