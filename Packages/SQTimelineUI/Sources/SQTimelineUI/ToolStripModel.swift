#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// Where the tool strip is docked. `floating` = a rounded panel over the timeline.
public enum ToolStripEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom, floating
    /// Left and right are columns; top, bottom and the floating bar are rows (v9 `.tbar.floating`: a row).
    public var isVertical: Bool { self == .left || self == .right }
}

/// Window > Tools: visibility, dock edge and float origin (UserDefaults `sq.tools.*`).
public enum ToolStripPrefs {
    public static let visibleKey = "sq.tools.visible"
    public static let edgeKey = "sq.tools.edge"
    public static let floatXKey = "sq.tools.floatX"
    public static let floatYKey = "sq.tools.floatY"
    public static let didChange = Notification.Name("sq.tools.didChange")

    public static var visible: Bool {
        get { UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: visibleKey); NotificationCenter.default.post(name: didChange, object: nil) }
    }
    public static var edge: ToolStripEdge {
        get { ToolStripEdge(rawValue: UserDefaults.standard.string(forKey: edgeKey) ?? "") ?? .left }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: edgeKey); NotificationCenter.default.post(name: didChange, object: nil) }
    }
    public static var floatOrigin: CGPoint {
        get {
            let d = UserDefaults.standard
            return CGPoint(x: d.object(forKey: floatXKey) as? Double ?? 40, y: d.object(forKey: floatYKey) as? Double ?? 40)
        }
        set {
            UserDefaults.standard.set(Double(newValue.x), forKey: floatXKey)
            UserDefaults.standard.set(Double(newValue.y), forKey: floatYKey)
        }
    }
}

/// Pure geometry of the tool bar dock (tested). Design v9 `.tbar`: 38 wide beside the lanes with an 18 pt grip on top and
/// 28 pt tools; docked above (or below) the lanes it is a 36 pt row; floating it is a 36 pt row with 4 pt padding.
public enum ToolStripLayout {
    public static let thickness: CGFloat = 38
    /// Height of the bar as a row (docked top / bottom, floating).
    public static let rowThickness: CGFloat = 36
    public static let toolSize: CGFloat = 28
    /// Vertical bar: 18 pt grip + 2 pt margin. Row: a 24 pt wide grip.
    public static let gripLength: CGFloat = 20
    public static let rowGripLength: CGFloat = 24
    public static let toolGap: CGFloat = 2
    public static let endPadding: CGFloat = 8
    public static let floatPadding: CGFloat = 4
    /// A drag ending this close to the left / right edge docks there (v9: 64), this close to the top / bottom (v9: 48).
    public static let snapDistanceX: CGFloat = 64
    public static let snapDistanceY: CGFloat = 48

    public static func thickness(_ edge: ToolStripEdge) -> CGFloat { edge.isVertical ? thickness : rowThickness }

    /// Length of the bar along its main axis for `count` tools.
    public static func length(toolCount: Int, edge: ToolStripEdge = .left) -> CGFloat {
        let tools = CGFloat(toolCount) * toolSize + CGFloat(max(toolCount - 1, 0)) * toolGap
        switch edge {
        case .left, .right: return gripLength + tools + endPadding
        case .top, .bottom: return endPadding + rowGripLength + tools + endPadding
        case .floating: return floatPadding + rowGripLength + tools + floatPadding
        }
    }

    /// Edge a drag released at `p` (in the dock's coordinates) docks to; `floating` when far from every edge.
    public static func edge(for p: CGPoint, in bounds: CGRect) -> ToolStripEdge {
        if p.x - bounds.minX < snapDistanceX { return .left }
        if bounds.maxX - p.x < snapDistanceX { return .right }
        if p.y - bounds.minY < snapDistanceY { return .top }
        if bounds.maxY - p.y < snapDistanceY { return .bottom }
        return .floating
    }

    /// The highlighted drop zone of a docking edge while the grip is dragged (nil for floating).
    public static func zone(_ edge: ToolStripEdge, in bounds: CGRect) -> CGRect? {
        switch edge {
        case .left: CGRect(x: bounds.minX, y: bounds.minY, width: snapDistanceX, height: bounds.height)
        case .right: CGRect(x: bounds.maxX - snapDistanceX, y: bounds.minY, width: snapDistanceX, height: bounds.height)
        case .top: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: snapDistanceY)
        case .bottom: CGRect(x: bounds.minX, y: bounds.maxY - snapDistanceY, width: bounds.width, height: snapDistanceY)
        case .floating: nil
        }
    }

    /// Bar frame and the content frame left over (flipped coordinates).
    public static func frames(edge: ToolStripEdge, bounds: CGRect, toolCount: Int, floatOrigin: CGPoint,
                              visible: Bool = true) -> (strip: CGRect, content: CGRect) {
        guard visible else { return (.zero, bounds) }
        let row = rowThickness
        switch edge {
        case .left:
            return (CGRect(x: bounds.minX, y: bounds.minY, width: thickness, height: bounds.height),
                    CGRect(x: bounds.minX + thickness, y: bounds.minY, width: max(bounds.width - thickness, 0), height: bounds.height))
        case .right:
            return (CGRect(x: bounds.maxX - thickness, y: bounds.minY, width: thickness, height: bounds.height),
                    CGRect(x: bounds.minX, y: bounds.minY, width: max(bounds.width - thickness, 0), height: bounds.height))
        case .top:
            return (CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: row),
                    CGRect(x: bounds.minX, y: bounds.minY + row, width: bounds.width, height: max(bounds.height - row, 0)))
        case .bottom:
            return (CGRect(x: bounds.minX, y: bounds.maxY - row, width: bounds.width, height: row),
                    CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(bounds.height - row, 0)))
        case .floating:
            let w = length(toolCount: toolCount, edge: .floating), h = row
            let x = min(max(floatOrigin.x, bounds.minX), max(bounds.maxX - w, bounds.minX))
            let y = min(max(floatOrigin.y, bounds.minY), max(bounds.maxY - h, bounds.minY))
            return (CGRect(x: x, y: y, width: w, height: h), bounds)
        }
    }

    /// Rect of tool `i` and the grip inside a bar of `edge`, in the bar's own flipped coordinates.
    public static func slots(edge: ToolStripEdge, toolCount: Int, size: CGSize) -> (grip: CGRect, tools: [CGRect]) {
        var tools = [CGRect]()
        if edge.isVertical {
            let x = ((size.width - toolSize) / 2).rounded()
            for i in 0..<toolCount { tools.append(CGRect(x: x, y: gripLength + CGFloat(i) * (toolSize + toolGap), width: toolSize, height: toolSize)) }
            return (CGRect(x: 0, y: 0, width: size.width, height: gripLength - 2), tools)
        }
        let lead = edge == .floating ? floatPadding : endPadding
        let y = ((size.height - toolSize) / 2).rounded()
        let x0 = lead + rowGripLength
        for i in 0..<toolCount { tools.append(CGRect(x: x0 + CGFloat(i) * (toolSize + toolGap), y: y, width: toolSize, height: toolSize)) }
        return (CGRect(x: lead, y: y, width: rowGripLength, height: toolSize), tools)
    }
}

/// The tool bar's tools and menus, shared by the Mac `ToolStripView` and the draw-list strip (SQDrawTimeline `ToolStrip`).
/// `commit` receives the new tool state; the caller hands it to the timeline (and reports the tool change).
public enum ToolStripTools {
    /// Design v9 `TOOLS`, in order.
    public static let order: [TimelineTool] = [.selection, .razor, .slip, .hand, .type, .mask]
    public static let symbols: [TimelineTool: (symbol: SQIcon, title: String)] = [
        .selection: (.toolSelect, "Select"),
        .razor: (.toolBlade, "Blade"),
        .slip: (.toolSlip, "Slip"),
        .hand: (.toolHand, "Hand"),
        .type: (.text, "Create"),
        .mask: (.toolMask, "Mask"),
    ]
    /// Design v9 `TOOLS`: what each tool does (second part of the tooltip).
    public static let help: [TimelineTool: String] = [
        .selection: "Select, move and trim clips.",
        .razor: "Cuts a clip where you click.",
        .slip: "Moves the content inside a clip. Hold for keyframe behavior.",
        .hand: "Scrolls the timeline.",
        .type: "Adds an item to a Graphic clip. Hold for the shape.",
        .mask: "Masks the selected clip. Hold for the mask type.",
    ]
    /// Tools without a button (v9: "A, B, N, U, R and Z are keyboard only"): listed in the bar's right-click menu.
    public static let keyboardTools: [(tool: TimelineTool, title: String)] = [
        (.trackSelectForward, "Select Forward"), (.rippleEdit, "Ripple"), (.rollEdit, "Roll"), (.slide, "Slide"),
        (.rateStretch, "Rate Stretch"), (.zoom, "Zoom"), (.position, "Position"),
    ]
    public static let gripTip = "All tools · Click for every tool with its key. Drag to dock left, right or above the timeline, or let go anywhere to float. Double-click puts it back on the left."

    /// Slots with a hold / right-click menu of variants (the corner mark).
    public static func hasVariants(_ t: TimelineTool) -> Bool { t == .slip || t == .mask || t == .type }

    /// The icon a slot shows for the current state: Create and Mask show their mode.
    public static func icon(_ t: TimelineTool, state: ToolState) -> SQIcon {
        switch t {
        case .type: SQIcon(rawValue: state.createMode.symbol) ?? .text
        case .mask: SQIcon(rawValue: state.maskMode.symbol) ?? .toolMask
        default: symbols[t]?.symbol ?? .unknown
        }
    }

    /// The key-map tool a slot stands for (every slot has one).
    public static func editorTool(_ t: TimelineTool) -> EditorTool? {
        switch t {
        case .selection: .selection
        case .trackSelectForward: .trackForward
        case .rippleEdit: .ripple
        case .rollEdit: .rolling
        case .slip: .slip
        case .slide: .slide
        case .razor: .razor
        case .hand: .hand
        case .rateStretch: .rateStretch
        case .zoom: .zoom
        case .type: .type          // the Create slot: its mode's own key-map tool is `CreateToolMode.editorTool`
        case .mask: .mask
        case .position: .position
        }
    }

    /// The hold / right-click menu of a slot with variants; empty for the others.
    public static func variantItems(_ t: TimelineTool, state: ToolState, commit: @escaping @MainActor (ToolState) -> Void) -> [SQMenuItem] {
        switch t {
        case .slip:
            // Plain slip (keyframes follow the content) or keyframes stay on the timeline.
            return [SQMenuItem.header("Slip")] + [("Keyframes follow content", false), ("Keyframes stay on the timeline", true)].map { title, stay in
                SQMenuItem(title: title, isChecked: stay == state.slipKeyframesStay) {
                    var s = state; s.tool = .slip; s.slipKeyframesStay = stay; commit(s)
                }
            }
        case .mask:
            return [SQMenuItem.header("Mask")] + MaskToolMode.allCases.map { mode in
                SQMenuItem(title: mode.title, isChecked: mode == state.maskMode) {
                    var s = state; s.tool = .mask; s.maskMode = mode; commit(s)
                }
            }
        case .type:
            return [SQMenuItem.header("Create")] + CreateToolMode.allCases.map { mode in
                SQMenuItem(title: mode.title, isChecked: mode == state.createMode) {
                    var s = state; s.tool = .type; s.createMode = mode; commit(s)
                }
            }
        default:
            return []
        }
    }

    /// Right-click on the bar (not on a tool) or a click on the grip: every tool with its key, the keyboard-only ones
    /// included, and where the bar docks.
    public static func allToolItems(state: ToolState, edge: ToolStripEdge, map: CommandMap = .current,
                                    commit: @escaping @MainActor (ToolState) -> Void) -> [SQMenuItem] {
        func key(_ t: TimelineTool) -> String {
            editorTool(t).flatMap { map.binding(for: .tool($0)) }.map { KeyboardListing.text(for: $0) } ?? ""
        }
        func item(_ t: TimelineTool, _ title: String) -> SQMenuItem {
            SQMenuItem(title: title, shortcut: key(t), isChecked: state.tool == t) { var s = state; s.tool = t; commit(s) }
        }
        var items = [SQMenuItem.header("Tools")]
        items += order.map { item($0, symbols[$0]?.title ?? "") }
        items.append(.separator)
        items += keyboardTools.map { item($0.tool, $0.title) }
        items.append(.separator)
        items.append(.header("Tool Bar"))
        let docks: [(String, ToolStripEdge)] = [("Dock Left", .left), ("Dock Right", .right), ("Dock Above the Timeline", .top),
                                                 ("Dock Below the Timeline", .bottom), ("Float", .floating)]
        items += docks.map { title, e in SQMenuItem(title: title, isChecked: edge == e) { ToolStripPrefs.edge = e } }
        items.append(SQMenuItem(title: "Hide Tool Bar") { ToolStripPrefs.visible = false })
        return items
    }
}
