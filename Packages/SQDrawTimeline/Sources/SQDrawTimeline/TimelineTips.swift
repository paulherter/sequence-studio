import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// The hover tips of the drawn timeline bars, the Mac strings (`TimelineHeaderBar.refreshTips`, `FastCutStrip`,
/// `ToolStripView`). The bars offer them to `HostHover` on every move they handle.
enum TimelineTips {
    /// "Snapping (S)": the title with the command's key from the key map; the bare title when it has none.
    static func text(_ title: String, _ command: EditorCommand, map: CommandMap = .current) -> String {
        #if canImport(AppKit)
        Tooltip.text(title, command: command, map: map)
        #else
        // Tooltip (SQUIKit) is AppKit-only; the same "Name (Key)" text from the portable key names.
        map.binding(for: command).map { "\(title) (\(KeyBindingText.text($0)))" } ?? title
        #endif
    }

    static func header(_ c: TimelineHeaderStrip.Control, state: TimelineHeaderState, map: CommandMap = .current) -> String? {
        switch c {
        case .tab(let i): return state.tabs.indices.contains(i) ? state.tabs[i].title : nil
        case .tabClose: return "Close Sequence"
        case .editMode:
            return state.editMode == .magnetic
                ? text("Fast Cut", .toggleMagnetic, map: map)
                    + " · The main track closes gaps by itself; clips above and below stay attached. Click to change the mode."
                : "Normal · Classic tracks, every edit stays where you put it. Click to change the mode."
        case .snap: return text("Snapping", .toggleSnapping, map: map) + " · Clips snap to edits, markers and the playhead."
        case .link: return text("Linked selection", .toggleLinkedSelection, map: map) + " · Video and its audio select together."
        case .marker: return text("Add marker", .addMarker, map: map)
        case .fit: return text("Zoom", .zoomFit, map: map) + " · Fit the whole sequence."
        case .verb(let i):
            guard FastCutVerb.all.indices.contains(i) else { return nil }
            let v = FastCutVerb.all[i]
            return text(v.title, v.command, map: map) + " · " + v.help
        }
    }

    /// The Mac `ToolStripView.sync` tips: "Name (Key) · what it does", the Create, Mask and Slip slots with their mode.
    static func tool(_ t: TimelineTool, state s: ToolState, map: CommandMap = .current) -> String {
        let head: String
        switch t {
        case .type: head = text("Create: \(s.createMode.title)", .tool(s.createMode.editorTool), map: map)
        case .mask: head = text("Mask: \(s.maskMode.title)", .tool(.mask), map: map)
        case .slip: head = text(s.slipKeyframesStay ? "Slip (Keyframes Stay)" : "Slip", .tool(.slip), map: map)
        default:
            let title = ToolStripTools.symbols[t]?.title ?? ""
            head = ToolStripTools.editorTool(t).map { text(title, .tool($0), map: map) } ?? title
        }
        return ToolStripTools.help[t].map { "\(head) · \($0)" } ?? head
    }
}

extension TimelineHeaderStrip {
    /// The tip of the control at window point `p`.
    func tip(at p: CGPoint) -> String? { control(at: p).flatMap { TimelineTips.header($0, state: state) } }
}

extension ToolStrip {
    /// The tip of the slot (or the grip) at window point `p`.
    func tip(at p: CGPoint, state: ToolState) -> String? {
        let s = slots
        if s.grip.contains(p) { return ToolStripTools.gripTip }
        guard let i = s.tools.firstIndex(where: { $0.contains(p) }), ToolStripTools.order.indices.contains(i) else { return nil }
        return TimelineTips.tool(ToolStripTools.order[i], state: state)
    }
}
