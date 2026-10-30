import Foundation

public enum MonitorMode: Sendable, Hashable { case program, source }

public enum MonitorZoom: Sendable, Hashable {
    case fit
    case percent(Int)
    /// Reached by pinch or scroll zoom (not a popup preset).
    case custom(Int)
    public static let presets: [MonitorZoom] = [.fit, .percent(10), .percent(25), .percent(50), .percent(75),
                                                .percent(100), .percent(150), .percent(200), .percent(400), .percent(800)]
    public var title: String {
        switch self { case .fit: "Fit"; case .percent(let p), .custom(let p): "\(p) %" }
    }
}

public enum MonitorAction: Sendable, Hashable, CaseIterable {
    case markIn, markOut, goToIn, goToOut, stepBack, stepForward, playPause, addMarker, insert, overwrite
    case lift, extract, exportFrame, loop, playInToOut, toggleSafeMargins
    /// Scrub bar right-click: take the marks away (the main menu's Remove In / Out / In and Out).
    case clearIn, clearOut, clearInOut
    /// Source monitor menu only (no key of their own yet): Replace the selected clip with the Source clip at the playhead frame,
    /// and Fit to Fill (the marked source range retimed into the sequence In..Out).
    case replace, fitToFill

    /// Footer transport, left to right: Mark In at the far left, Mark Out at the far right, Play exactly in the middle
    /// (two buttons on each side of it, so the row centers Play itself).
    public static func buttonBar(for mode: MonitorMode) -> [MonitorAction] {
        [.markIn, .stepBack, .playPause, .stepForward, .markOut]
    }

    /// Everything else lives in the header wrench menu (with Loop, Play In to Out and Safe Margins). Mark In / Out stay on I / O and the Mark menu. Insert / Overwrite belong to the Source monitor, Lift / Extract to the Program monitor.
    /// Extra Source rows below the overflow rows of the "..." menu (not buttons, no EditorCommand yet).
    public static func sourceMenuExtras(for mode: MonitorMode) -> [MonitorAction] { mode == .source ? [.replace, .fitToFill] : [] }

    /// Menu title of an action that has no footer button.
    public var menuTitle: String? {
        switch self {
        case .replace: "Replace Clip from Source"
        case .fitToFill: "Fit to Fill"
        default: nil
        }
    }

    public static func overflowMenu(for mode: MonitorMode) -> [MonitorAction] {
        let edit: [MonitorAction] = mode == .source ? [.insert, .overwrite] : [.lift, .extract]
        return [.addMarker, .goToIn, .goToOut] + edit + [.exportFrame]
    }
}
