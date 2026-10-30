import AppKit
import SQCore
import SQUIKit

/// Fast Cut skimmer: drawing and reporting (the rules are `Skimmer`).
extension TimelineView {
    /// Pointer in view coordinates (window's by default, replaceable in tests); nil off the view.
    private func currentPointer() -> CGPoint? {
        let raw: CGPoint?
        if let pointerProvider { raw = pointerProvider() }
        else if let window { raw = convert(window.mouseLocationOutsideOfEventStream, from: nil) }
        else { raw = nil }
        return raw.flatMap { bounds.contains($0) ? $0 : nil }
    }

    /// Re-evaluates the skimmer at the pointer's current position (scroll, zoom, tool or transport changed without a move).
    public func updateSkimmerFromPointer() {
        guard timeline.isFastCut || skimmerTime != nil else { return }
        updateSkimmer(pointer: currentPointer())
    }

    /// Moves, shows or hides the skimmer for a pointer (nil: it left the view). Only a change of frame costs anything:
    /// two thin strips are redrawn over the cached content and the host is told once.
    func updateSkimmer(pointer: CGPoint?) {
        guard timeline.isFastCut || skimmerTime != nil else { return }
        let context = Skimmer.Context(isFastCut: timeline.isFastCut, isDragging: isDragging,
                                      isPlaying: isPlaybackRunning?() ?? false, isRazor: toolState.timelineTool == .razor)
        let t = Skimmer.time(pointer: pointer, context: context, viewHeight: bounds.height,
                             zoomBarHeight: ZoomScrollBar.height, geometry: geometry)
        let timeChanged = t != skimmerTime
        // The x of a line that stays on its frame changes with scroll / zoom: compare the line, not only the time.
        let x = t.map { geometry.x(for: $0).rounded() }
        guard timeChanged || (x != nil && x != skimmerX) else { return }
        invalidateSkimmerStrip()
        skimmerTime = t
        if let x { skimmerX = x; invalidateSkimmerStrip() }
        if timeChanged { onSkim?(t) }
    }

    /// Hides the line without telling the host (the caller seeks, which ends the skim).
    func clearSkimmer() {
        guard skimmerTime != nil else { return }
        invalidateSkimmerStrip()
        skimmerTime = nil
    }

    private func invalidateSkimmerStrip() {
        displayOverlay(Skimmer.lineRect(x: skimmerX, viewHeight: bounds.height, zoomBarHeight: ZoomScrollBar.height)
            .insetBy(dx: -2, dy: 0))
    }

    func drawSkimmerLine(clip: CGRect) {
        guard skimmerTime != nil else { return }
        let r = Skimmer.lineRect(x: skimmerX, viewHeight: bounds.height, zoomBarHeight: ZoomScrollBar.height)
        guard r.intersects(clip) else { return }
        Theme.Colors.skimmer.setFill()
        r.intersection(clip).fill()
    }
}
