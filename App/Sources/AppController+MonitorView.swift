import AppKit
import SQMonitorUI
import SQRender
import SQUIKit

/// View > Show Overlays and View > View Gamma: menu entries for the monitor options of the monitor's own "..." menu.
extension AppController {
    /// True when `c` was one of these and has been handled.
    func executeMonitorViewCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .toggleOverlays:
            panels.monitorModel.toggleOverlays()
        case .viewGamma(let choice):
            guard let g = ViewGamma(rawValue: choice.rawValue) else { return true }
            panels.monitorModel.setViewGamma(g)        // one presenter state: both monitors follow
            panels.source.model.setViewGamma(g)
        default: return false
        }
        return true
    }

    /// Check mark of the View Gamma items and Show Overlays (`validateTimelineOpItem`).
    func monitorViewState(_ c: EditorCommand) -> NSControl.StateValue? {
        switch c {
        case .toggleOverlays: panels.monitorModel.overlaysHidden ? .off : .on
        case .viewGamma(let choice): panels.monitorModel.viewGamma.rawValue == choice.rawValue ? .on : .off
        default: nil
        }
    }
}
