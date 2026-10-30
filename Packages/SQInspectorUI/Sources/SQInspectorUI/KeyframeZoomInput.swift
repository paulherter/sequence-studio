#if os(macOS)
import AppKit
#endif
import Foundation
import SQCore
import SQDrawKit

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

    /// The shared toolkit's wheel at the keyframe area: the host gesture's AppKit deltas (a wheel line, not its list
    /// pixels, as the Mac views read `scrollingDelta`), a pinch zooms by `magnifyFactor`. `dx`/`dy` (points) only
    /// count without a host gesture.
    static func classify(dx: CGFloat, dy: CGFloat, modifiers: InputModifiers) -> Scroll {
        guard let g = ScrollGesture.published else {
            return classify(deltaX: dx, deltaY: dy, zoomModifier: !modifiers.isDisjoint(with: [.option, .command]))
        }
        switch g.kind {
        case .magnify(let m): return .zoom(factor: magnifyFactor(CGFloat(m)))
        case .smartMagnify: return .none
        case .scroll:
            return classify(deltaX: CGFloat(g.deltaX), deltaY: CGFloat(g.deltaY),
                            zoomModifier: !modifiers.isDisjoint(with: [.option, .command]))
        }
    }

    /// Keys of the shared toolkit: + / = zoom in, - zoom out, \ fit (the Mac `key(_:model:)`). True when handled.
    @MainActor
    static func key(_ k: InputKey, modifiers: InputModifiers, model: EffectControlsModel) -> Bool {
        guard !modifiers.contains(.command) else { return false }      // Ctrl on Windows arrives as .command
        switch k {
        case .character("="), .character("+"), .plus: model.zoomIn(); return true
        case .character("-"), .minus: model.zoomOut(); return true
        case .character("\\"): model.zoomToFit(); return true
        default: return false
        }
    }

    #if os(macOS)
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
    #endif
}
