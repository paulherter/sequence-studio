import Foundation

/// The Program monitor's text state table (tool + what is under the pointer + editing state -> cursor, frame, action).
/// Pure so it can be tested; `ProgramSurfaceView` and the host only apply the result. The table is in DESIGN.md.
public enum MonitorTextInteraction {
    public enum Hit: Sendable, Equatable { case empty, textLayer, handle }
    public enum Event: Sendable, Equatable { case hover, click, doubleClick, escape }
    public enum Cursor: Sendable, Equatable { case arrow, move, iBeam, openHand, overlay, crosshair }
    public enum Action: Sendable, Equatable {
        case createText
        /// A graphics clip is selected: add a text layer inside it at the pointer / edit the layer under the pointer.
        case createLayerText
        case editLayerText(caretAtClick: Bool)
        /// Select the text layer under the pointer and open the in-monitor editor.
        case editText(caretAtClick: Bool)
        case endEditing
    }

    /// A just-created text must keep typing focus: while the protection window is open, a focus loss that no mouse click
    /// and no other text field caused (a panel refresh after the new clip is selected) hands focus back to the field
    /// instead of ending the edit. After the window, or on a click or another text field, the edit ends as usual.
    public static func reclaimsFocus(protectedUntil: TimeInterval?, now: TimeInterval, causedByMouseDown: Bool,
                                     newResponderIsText: Bool) -> Bool {
        guard let until = protectedUntil, now < until else { return false }
        return !causedByMouseDown && !newResponderIsText
    }

    public static func cursor(tool: ProgramSurfaceView.Tool, hit: Hit, editing: Bool) -> Cursor {
        switch tool {
        case .hand: return .openHand
        case .type: return .iBeam
        case .create: return .crosshair
        case .select, .mask:
            switch hit {
            case .handle: return .overlay      // the overlay picks the resize / rotate cursor
            case .textLayer: return .move
            case .empty: return .arrow
            }
        }
    }

    /// Frame + handles around the selected text layer. Always while editing; otherwise with Select or Type.
    public static func frameVisible(tool: ProgramSurfaceView.Tool, hasTextTarget: Bool, editing: Bool) -> Bool {
        guard hasTextTarget else { return false }
        return editing || tool != .hand
    }

    /// Only an idle Select tool drags / scales the frame; with Type or while editing it is a picture of the box.
    public static func frameIsInteractive(tool: ProgramSurfaceView.Tool, editing: Bool) -> Bool {
        tool.usesOverlay && !editing
    }

    /// `inGraphic`: a graphics clip is selected and the playhead is inside it; `hit` is then about its layers.
    public static func actions(tool: ProgramSurfaceView.Tool, hit: Hit, editing: Bool, event: Event, inGraphic: Bool = false) -> [Action] {
        let end: [Action] = editing ? [.endEditing] : []
        if inGraphic {
            switch (tool, event) {
            case (_, .hover), (.hand, _): return []
            case (_, .escape): return end
            case (.type, .click), (.type, .doubleClick):
                return hit == .textLayer ? end + [.editLayerText(caretAtClick: true)] : end + [.createLayerText]
            case (.select, .click), (.mask, _), (.create, _): return end
            case (.select, .doubleClick):
                return hit == .textLayer && !editing ? [.editLayerText(caretAtClick: false)] : end
            }
        }
        switch (tool, event) {
        case (_, .hover), (.hand, _): return []
        case (_, .escape): return end
        case (.type, .click), (.type, .doubleClick):
            return hit == .textLayer ? end + [.editText(caretAtClick: true)] : end + [.createText]
        case (.select, .click), (.mask, _), (.create, _): return end
        case (.select, .doubleClick):
            return hit == .textLayer && !editing ? [.editText(caretAtClick: false)] : end
        }
    }
}
