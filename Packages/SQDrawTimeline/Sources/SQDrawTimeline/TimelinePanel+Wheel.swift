import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// Trackpad and wheel state, the stored properties of `TimelineView.scrollWheel / magnify` (SQTimelineUI).
struct TimelineWheelState {
    var scrollZoom = ScrollZoomState()
    var axisLock = ScrollAxisLock()
    var pinchGuard = PinchScrollGuard()
    var elasticX = ElasticAxis()
    var elasticY = ElasticAxis()
    /// A running spring back of a rubber-band overscroll (`TimelineView.springBack`), started at `start` (panel clock).
    var springBack: (fromX: Double, toX: Double, fromY: Double, toY: Double, start: Double)?
    /// Fingers (or their momentum tail) are on a rubber-band scroll: the view may sit past its ends.
    var elasticTracking = false
    /// Sub-pixel parts of the scroll deltas not applied yet (carried into the next event).
    var carryX = ScrollCarry()
    var carryY = ScrollCarry()

    /// `clampScroll` leaves an overscroll alone while it is pulled or springs back.
    var allowsOverscroll: Bool { elasticTracking || springBack != nil }
}

/// `TimelineView.scrollWheel / magnify / smartMagnify`, translated: the same SQTimelineUI rules (`ScrollZoomState`,
/// `ScrollAxisLock`, `PinchScrollGuard`, `ScrollTuning`, `ElasticAxis`) fed with the AppKit deltas of `ScrollGesture`.
extension TimelinePanel {
    var feel: TimelineFeel { TimelineFeel.forMagnetic(timeline.editMode == .magnetic) }

    /// A rubber band springs back: the host keeps drawing frames until it settles.
    public var isSpringingBack: Bool { wheel.springBack != nil }

    static func phase(_ p: ScrollPhase) -> ScrollZoomState.Phase {
        switch p {
        case .none: .none
        case .mayBegin: .mayBegin
        case .began: .began
        case .changed: .changed
        case .stationary: .stationary
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }

    /// One wheel, trackpad scroll, pinch or two-finger double tap at `p` (panel points).
    mutating func scrollWheel(at p: CGPoint, gesture g: ScrollGesture, modifiers mods: InputModifiers) {
        switch g.kind {
        case .magnify(let m): magnify(at: p, magnification: m, phase: g.phase); return
        case .smartMagnify:
            if feel.doubleTapFits { zoomToFit() }        // Fast Cut (Final Cut); the Normal view has no double tap
            return
        case .scroll: break
        }
        let tune = self.feel
        let phase = Self.phase(g.phase), momentum = Self.phase(g.momentumPhase)
        let dx = g.deltaX, dy = g.deltaY
        // Command / Option zooms about the pointer; a momentum tail keeps the decision of its gesture.
        let held = mods.contains(.command) || mods.contains(.option)
        if wheel.scrollZoom.isZoom(phase: phase, momentumPhase: momentum, modifierHeld: held) {
            let d = abs(dy) >= abs(dx) ? dy : dx
            setZoom(pointsPerSecond: geometry.pointsPerSecond * TimelineZoom.scrollFactor(delta: d, precise: g.precise), anchorX: p.x)
            return
        }
        var d = (dx: dx, dy: dy)
        if g.precise {
            if wheel.axisLock.rule != tune.axisRule { wheel.axisLock = ScrollAxisLock(rule: tune.axisRule) }
            d = wheel.axisLock.filter(phase: phase, momentumPhase: momentum, dx: d.dx, dy: d.dy)
        }
        if wheel.pinchGuard.suppressesVertical(now: clock()) { d.dy = 0 }
        let horizontalOnly = mods.contains(.shift) || maxScrollY() == 0
        let a = ScrollTuning.scrollAmounts(dx: d.dx, dy: d.dy, precise: g.precise, horizontalOnly: horizontalOnly, feel: tune)
        if tune.rubberBand && g.precise {
            elasticScroll(dx: -a.x, dy: -a.y, phase: phase, momentumPhase: momentum)
            return
        }
        if wheel.springBack != nil || wheel.elasticTracking { endSpringBack() }
        guard a.x != 0 || a.y != 0 else { return }
        geometry.scrollX -= CGFloat(wheel.carryX.whole(a.x, scale: Double(scale)))
        geometry.scrollY -= CGFloat(wheel.carryY.whole(a.y, scale: Double(scale)))
        clampScroll()
    }

    /// Pinch: zoom about the pointer; its vertical residue does not scroll (`PinchScrollGuard`).
    mutating func magnify(at p: CGPoint, magnification m: Double, phase: ScrollPhase) {
        wheel.pinchGuard.magnify(phase: Self.phase(phase), now: clock())
        setZoom(pointsPerSecond: geometry.pointsPerSecond * TimelineZoom.pinchFactor(magnification: m), anchorX: p.x)
    }

    // MARK: Rubber band (feel.rubberBand)

    /// `TimelineView.elasticScroll`: `dx`/`dy` are scroll-offset deltas. Vertical bounces only when the tracks overflow.
    private mutating func elasticScroll(dx: Double, dy: Double, phase: ScrollZoomState.Phase, momentumPhase: ScrollZoomState.Phase) {
        if momentumPhase == .none, phase == .began || phase == .mayBegin { endSpringBack(settle: false) }
        if wheel.springBack != nil { return }                       // the momentum tail of a released overscroll
        switch momentumPhase == .none ? phase : momentumPhase {
        case .mayBegin, .began, .changed, .stationary: wheel.elasticTracking = true
        case .none, .ended, .cancelled: wheel.elasticTracking = false
        }
        let x = wheel.elasticX.step(position: Double(geometry.scrollX), delta: dx, range: 0...Double(maxScrollX()),
                                    dimension: Double(contentViewportWidth), phase: phase, momentumPhase: momentumPhase)
        var y = (position: Double(geometry.scrollY), springBack: false)
        let maxY = Double(maxScrollY())
        if maxY > 0 {
            y = wheel.elasticY.step(position: Double(geometry.scrollY), delta: dy, range: 0...maxY,
                                    dimension: Double(trackAreaHeight), phase: phase, momentumPhase: momentumPhase)
        }
        geometry.scrollX = CGFloat(x.position)
        geometry.scrollY = CGFloat(y.position)
        if x.springBack || y.springBack { startSpringBack() }
        clampScroll()
    }

    /// Eases an overscrolled view back to its ends over `RubberBand.springDuration` (driven by `tick`).
    private mutating func startSpringBack() {
        let sx = Double(geometry.scrollX), sy = Double(geometry.scrollY)
        let tx = RubberBand.edge(of: sx, range: 0...Double(maxScrollX())) ?? sx
        let ty = RubberBand.edge(of: sy, range: 0...Double(maxScrollY())) ?? sy
        endSpringBack(settle: false)
        guard tx != sx || ty != sy else { return }
        wheel.springBack = (sx, tx, sy, ty, clock())
    }

    /// One frame of a running spring back (`TimelineView.springBackTick`).
    mutating func stepSpringBack() {
        guard let s = wheel.springBack else { return }
        let p = (clock() - s.start) / RubberBand.springDuration
        if p >= 1 { endSpringBack(); return }
        geometry.scrollX = CGFloat(RubberBand.springBack(from: s.fromX, to: s.toX, progress: p))
        geometry.scrollY = CGFloat(RubberBand.springBack(from: s.fromY, to: s.toY, progress: p))
        interaction.geometry = geometry
    }

    /// Stops a running spring back; `settle` puts the view inside its range (the spring's end state).
    mutating func endSpringBack(settle: Bool = true) {
        wheel.springBack = nil
        wheel.elasticTracking = false
        if settle { clampScroll() }
    }
}
