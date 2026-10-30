import Foundation
import SQEditorSession
import SQUIKit

/// Window frame of a floating panel (screen coordinates, points). Plain numbers so the state stays Codable and testable.
public struct FloatingPanelFrame: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Which panels float in their own window, per workspace, and where. Persisted next to `workspaces.json` as
/// `floating-panels.json` (not in the project file, not in the layout tree: the panel keeps its dock position, so
/// docking it back restores the exact place). Keyed by workspace (`key(page:editName:)`).
public struct FloatingPanelState: Codable, Equatable, Sendable {
    private var layouts: [String: [String: FloatingPanelFrame]] = [:]

    public init() {}

    /// The workspace a floating set belongs to: the Edit layout by name, the Color layout by its paired Edit name.
    public static func key(page: WorkspaceStore.Page, editName: String) -> String { "\(page.rawValue):\(editName)" }

    public func panels(for key: String) -> Set<PanelID> {
        Set((layouts[key] ?? [:]).keys.compactMap(PanelID.init(rawValue:)))
    }

    public func frame(of panel: PanelID, key: String) -> FloatingPanelFrame? { layouts[key]?[panel.rawValue] }

    /// Pops `panel` out. Only dockable panels float (the Color page's Sources and Steps tabs stay in their layout).
    public mutating func float(_ panel: PanelID, key: String, frame: FloatingPanelFrame) {
        guard PanelID.dockable.contains(panel) else { return }
        layouts[key, default: [:]][panel.rawValue] = frame
    }

    public mutating func dock(_ panel: PanelID, key: String) {
        layouts[key]?[panel.rawValue] = nil
        if layouts[key]?.isEmpty == true { layouts[key] = nil }
    }

    /// Remembers a moved or resized window; ignored when the panel is not floating.
    public mutating func setFrame(_ frame: FloatingPanelFrame, of panel: PanelID, key: String) {
        guard layouts[key]?[panel.rawValue] != nil else { return }
        layouts[key]?[panel.rawValue] = frame
    }

    // MARK: Geometry

    /// Keeps the window on a connected display: a frame whose title bar is not reachable on any screen (second display
    /// unplugged) moves onto the first screen, and a frame larger than its screen shrinks to fit. y grows upward.
    public static func clamp(_ f: CGRect, screens: [CGRect], titleBar: CGFloat = 28) -> CGRect {
        guard let first = screens.first else { return f }
        let bar = CGRect(x: f.minX, y: f.maxY - titleBar, width: f.width, height: titleBar)
        let reachable = screens.first { s in
            let i = s.intersection(bar)
            return !i.isNull && i.width >= min(80, f.width) && i.height >= titleBar / 2
        }
        let screen = reachable ?? first
        var r = f
        r.size.width = min(r.width, screen.width)
        r.size.height = min(r.height, screen.height)
        if reachable == nil { r.origin = CGPoint(x: first.midX - r.width / 2, y: first.midY - r.height / 2) }
        r.origin.x = min(max(r.minX, screen.minX), screen.maxX - r.width)
        r.origin.y = min(max(r.minY, screen.minY), screen.maxY - r.height)
        return r
    }

    /// First frame of a panel that was just popped out: its dock size (at least the panel minimum), offset from the
    /// dock position so it does not sit exactly on top of it.
    public static func defaultFrame(for panel: PanelID, current: CGRect, offset: Double = 40) -> FloatingPanelFrame {
        let m = panel.minSize
        let w = max(current.width, m.width + 40), h = max(current.height, m.height + 60)
        return FloatingPanelFrame(x: current.minX + offset, y: current.maxY - h - offset, width: w, height: h)
    }

    /// A tab released this far outside the main window (screen coordinates) pops out instead of docking.
    public static func isTornOff(_ point: CGPoint, window: CGRect, margin: CGFloat = 16) -> Bool {
        !window.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    /// Frame (including the title bar) of a panel torn off a tab at `point`: the title bar sits under the pointer.
    public static func tearOffFrame(for panel: PanelID, at point: CGPoint, titleBar: Double = 28) -> FloatingPanelFrame {
        let m = panel.minSize
        let w = max(m.width + 80, 480), h = max(m.height + 80, 320) + titleBar
        return FloatingPanelFrame(x: point.x - w / 2, y: point.y + titleBar / 2 - h, width: w, height: h)
    }

    // MARK: Persistence

    public static var defaultURL: URL { WorkspaceStore.defaultURL.deletingLastPathComponent().appendingPathComponent("floating-panels.json") }

    /// Missing or unreadable file gives the empty state.
    public static func load(from url: URL = FloatingPanelState.defaultURL) -> FloatingPanelState {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(FloatingPanelState.self, from: d) else { return FloatingPanelState() }
        return s
    }

    public func save(to url: URL = FloatingPanelState.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    private enum CodingKeys: String, CodingKey { case layouts }

    /// Unknown and non-dockable panel ids are dropped.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent([String: [String: FloatingPanelFrame]].self, forKey: .layouts) ?? [:]
        let dockable = Set(PanelID.dockable.map(\.rawValue))
        for (k, v) in raw {
            let kept = v.filter { dockable.contains($0.key) }
            if !kept.isEmpty { layouts[k] = kept }
        }
    }
}
