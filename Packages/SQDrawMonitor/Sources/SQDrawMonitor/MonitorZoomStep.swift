import Foundation
import SQDrawKit

extension MonitorZoom {
    /// Next zoom for the Zoom In / Zoom Out keys while a monitor has focus: through the popup presets, Fit at the low end.
    /// From Fit, In goes to 100 % and Out stays at Fit. A pinch value (`custom`) steps to the next preset beyond it.
    public func stepped(zoomIn: Bool) -> MonitorZoom {
        let steps = MonitorZoom.presets.compactMap { z -> Int? in if case .percent(let p) = z { p } else { nil } }.sorted()
        let current: Int
        switch self {
        case .fit: return zoomIn ? .percent(100) : .fit
        case .percent(let p), .custom(let p): current = p
        }
        if zoomIn {
            if let next = steps.first(where: { $0 > current }) { return .percent(next) }
            return .percent(steps.last ?? current)
        }
        if let prev = steps.last(where: { $0 < current }) { return .percent(prev) }
        return .fit
    }
}
