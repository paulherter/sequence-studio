import AppKit
import Foundation
import SSCore

/// Pinch, scroll and keys that zoom or pan the keyframe area. Every view of the area (lanes, ruler, graph) uses it,
/// and all of them end in `EffectControlsModel.zoom / panViewport`, so they stay in one mapping.
enum KeyframeZoomInput {
    enum Scroll: Equatable {
        case zoom(factor: Double)
        case pan(points: CGFloat)
        case none
    }

    /// Pinch: magnification 0.1 = 10 % bigger.
    static func magnifyFactor(_ magnification: CGFloat) -> Double { max(1 + Double(magnification), 0.05) }

    /// Horizontal scrolling pans; Option (or Command) + vertical scrolling zooms; plain vertical scrolling is left to the
    /// enclosing scroll view (the rows).
    static func classify(deltaX: CGFloat, deltaY: CGFloat, zoomModifier: Bool) -> Scroll {
        if zoomModifier, deltaY != 0 { return .zoom(factor: exp(Double(deltaY) * 0.02)) }
        if abs(deltaX) > abs(deltaY), deltaX != 0 { return .pan(points: deltaX) }
        return .none
    }

    @MainActor
    static func scroll(_ e: NSEvent) -> Scroll {
        classify(deltaX: e.scrollingDeltaX, deltaY: e.scrollingDeltaY,
                 zoomModifier: !e.modifierFlags.isDisjoint(with: [.option, .command]))
    }

    /// Keys: + / = zoom in, - zoom out, \ fit. Returns true when handled.
    @MainActor
    static func key(_ e: NSEvent, model: EffectControlsModel) -> Bool {
        guard e.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        switch e.charactersIgnoringModifiers {
        case "=", "+": model.zoomIn(); return true
        case "-": model.zoomOut(); return true
        case "\\": model.zoomToFit(); return true
        default: return false
        }
    }
}
