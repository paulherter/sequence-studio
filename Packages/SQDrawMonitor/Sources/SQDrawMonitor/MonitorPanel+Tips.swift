import Foundation
import SQCore
import SQUIKit

/// The tips of the monitor header popups: the Mac `MonitorPanelView` `setTooltip` texts (sequence / source popup, safe
/// zone, zoom, quality, "...").
extension MonitorPanel {
    /// The tip of a header control (`MonitorPanelView` setup).
    public func headerTip(_ ctl: HeaderControl) -> String {
        switch ctl {
        case .content: SQL10n.string(model.mode == .source ? "Source Clips" : "Open Sequences")
        case .zone: SQL10n.string("Platform Safe Zone")
        case .zoom: SQL10n.string("Zoom: Fit, or 10 to 800 %")
        case .quality: SQL10n.string("Playback Quality")
        case .options: SQL10n.string("More")
        }
    }

    /// The tip of the header control at `p` (panel points), nil off the controls.
    public func headerTip(at p: CGPoint) -> String? {
        headerControls.first { $0.1.contains(p) }.map { headerTip($0.0) }
    }
}
