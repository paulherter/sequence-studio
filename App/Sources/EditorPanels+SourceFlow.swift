import AppKit
import SQCore
import SQEditorUI

/// Source / Project flow wiring: hover marks, poster frames, multi-clip open, grip drags on the Program strip, and the
/// preferences that reach the panels. Kept out of `EditorPanels.swift` so merges stay small.
extension EditorPanels {
    func wireSourceFlow() {
        startCachePolling()
        projectView.onNotice = { [weak self] m in self?.onStatus?(m) }
        projectModel.onSourceMarks = { [weak self] id, marks in self?.session.setSourceMarks(marks, for: id) }
        projectView.sourcePosition = { [weak self] in
            guard let self, let id = source.mediaID else { return nil }
            return (id, source.currentTime)
        }
        // Double-click: with several clips selected they all load (the first shows, the rest join the Source list);
        // on a hover-scrubbed icon the clip opens at the hovered frame.
        projectView.onOpenMedia = { [weak self] id in self?.openInSource(id, at: nil) }
        projectView.onOpenMediaAt = { [weak self] id, t in self?.openInSource(id, at: t) }
        // Dragging an In / Out grip on the Program strip: one undo step on release.
        monitorModel.onMarkEdit = { [weak self] end, t in
            guard let self else { return }
            let fd = session.activeTimeline?.frameDuration ?? monitorModel.frameDuration
            switch end {
            case .markIn: session.setInPoint(at: t)
            case .markOut: session.setOutPoint(at: t - fd)       // the strip reports the stored end, one frame past Out
            case .playhead: break
            }
        }
    }

    /// Twice a second: the ruler's cache strip follows the frame cache, and with `SQ_HUD=1` the Program monitor shows the
    /// scrub latency (dev aid; Paul judges the feel, this reports milliseconds).
    func startCachePolling() {
        let showHUD = ProcessInfo.processInfo.environment["SQ_HUD"] == "1"
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only ask the cache when it (or the sequence) changed since the last look.
                let key = [self.session.engine.cacheGeneration, self.session.activeTimeline?.duration.hashValue ?? 0,
                           self.session.undoName?.hashValue ?? 0]
                if key != self.lastCacheKey {
                    self.lastCacheKey = key
                    self.timelineView.setCachedRanges(self.session.engine.cachedSpans)
                }
                if showHUD { self.monitorModel.latencyText = self.session.engine.scrubLatencyText }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func openInSource(_ id: MediaRef.ID, at time: Time?) {
        let selected = projectView.selectedMediaIDs
        let ok: Bool
        if time == nil, selected.count > 1, selected.contains(id) {
            ok = source.open(all: [id] + selected.filter { $0 != id })
        } else {
            ok = source.open(id, at: time)
        }
        if ok { onShowSource?() }
    }

    /// Preferences that live inside the panels (playback roll, Hover Scrub).
    func applySettings(_ s: AppSettings) {
        source.preroll = s.preroll
        source.postroll = s.postroll
        projectView.hoverScrubEnabled = s.hoverScrub
    }
}
