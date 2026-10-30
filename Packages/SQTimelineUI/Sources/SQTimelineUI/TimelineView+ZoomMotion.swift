import AppKit

/// Content-cache scale limit and timer for `ZoomMotion`: content bitmap at 1x while zoom steps arrive, full scale one redraw after they stop.
extension TimelineView {
    /// True while the layer is drawn at 1x.
    public var isZoomInMotion: Bool { zoomMotion.active }

    /// Pixels per point the content bitmap is limited to (nil: the display's own scale).
    var contentScaleLimit: CGFloat? { zoomMotion.active ? 1 : nil }

    func noteZoomStep(_ kind: ZoomMotion.Step) {
        guard window != nil else { return }          // nothing is on screen: no soft frame to trade for speed
        _ = zoomMotion.step(kind, now: ProcessInfo.processInfo.systemUptime)     // the step itself redraws, now at the limit
        if zoomMotion.active { armZoomMotionTimer() }
    }

    /// Leaves the motion now (gesture end, window resigned or hidden, bench): full scale and one redraw.
    public func endZoomMotion() {
        zoomMotionToken &+= 1                         // a pending timer fire does nothing
        zoomMotionTimerPending = false
        guard zoomMotion.end() else { return }
        displayViewport()                             // the cache sharpens strip by strip (`TimelineContentCache.sharpening`)
    }

    /// True while the full-scale content bitmap is still filling in after a zoom in motion.
    public var isSharpeningContent: Bool { contentCache.isSharpening }

    /// Asks for the next sharpening strip (the bench and tests call it directly; the view schedules it itself).
    public func sharpenNextStrip() {
        guard contentCache.isSharpening else { return }
        displayViewport()
    }

    /// One strip per frame: the next display comes from the main queue, after the frame that drew this one.
    func scheduleSharpenFrame() {
        guard !sharpenFramePending else { return }
        sharpenFramePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sharpenFramePending = false
                self.sharpenNextStrip()
            }
        }
    }

    /// Timer fire (or a test with a chosen time). Re-arms when steps pushed the deadline out.
    func zoomMotionTick(now: TimeInterval) {
        if zoomMotion.tick(now: now) { zoomMotionToken &+= 1; zoomMotionTimerPending = false; displayViewport() }
        else if zoomMotion.active { armZoomMotionTimer() }
    }

    /// One pending fire at a time, on the main queue (works whatever the run loop mode).
    private func armZoomMotionTimer() {
        guard !zoomMotionTimerPending, let d = zoomMotion.deadline else { return }
        zoomMotionTimerPending = true
        let token = zoomMotionToken
        let delay = max(d - ProcessInfo.processInfo.systemUptime, 0.005)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.zoomMotionToken == token else { return }
                self.zoomMotionTimerPending = false
                self.zoomMotionTick(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }
}
