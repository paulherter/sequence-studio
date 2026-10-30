import Foundation

public enum PanelID: String, Sendable, Codable, Hashable, CaseIterable {
    case effectControls, text
    case programMonitor, sourceMonitor
    case library, effects, project
    case timeline
    /// Level meter right of the timeline (Premiere's audio meters).
    case audioMeter
    /// Color page panels (also available from the Window menu on the Edit page).
    case colorInspector, scopes
    /// The Sources panel of the Color page (the id predates the rename): source tiles, grade state, copy/paste. A dock
    /// tab of the Color layouts only.
    case colorClips
    /// The Steps graph (Pro grade) of the Color page. A dock tab of the Color layouts only.
    case steps
    /// G1: keyframe building blocks (Window > Keystones).
    case keystones
    /// Layer list and properties of the selected graphics clip (design layer).
    case graphics
    /// The marker list: every sequence and clip marker, filter, click to go there (Window > Marker List).
    case markerList

    /// Smallest size the panel is laid out at (width, height in points), below the tab strip.
    /// Layouts never squeeze a panel under this; the window minimum is derived from it.
    public var minSize: (width: Double, height: Double) {
        switch self {
        case .timeline: (320, 150)
        case .audioMeter: (56, 100)
        case .programMonitor, .sourceMonitor: (380, 200)
        case .effectControls: (300, 120)
        case .text: (240, 140)
        case .library: (200, 120)
        case .effects: (180, 100)
        case .project: (200, 100)
        case .colorInspector: (260, 160)
        case .colorClips: (140, 100)
        case .steps: (240, 120)
        case .scopes: (200, 120)
        case .keystones: (180, 100)
        case .graphics: (240, 160)
        case .markerList: (200, 120)
        }
    }

    /// The panels a layout tree can hold (everything but the Color page's Sources and Steps).
    public static let dockable: [PanelID] = allCases.filter { $0 != .colorClips && $0 != .steps }

    /// Height of a tab strip above every group (DESIGN: panel header).
    #if canImport(AppKit)
    public static let headerHeight = Double(ShellMetrics.panelHeader)
    #else
    // shortcut: the unscaled DESIGN height off the Mac (UIScale is AppKit), upgrade with the shared toolkit's UI scale.
    public static let headerHeight = 30.0
    #endif
}
