import AppKit
import SQCore

/// Remove Silences preview: every range that would be cut is shaded red across all lanes, with a solid edge at both
/// ends, so the cuts can be judged against the waveforms before anything changes.
extension TimelineView {
    func drawSilencePreview(clip: CGRect) {
        guard !silencePreview.isEmpty else { return }
        let fill = Theme.TimelineSkin.silenceFill, edge = Theme.TimelineSkin.silenceEdge
        for r in silencePreview {
            let x0 = geometry.x(for: r.start), x1 = geometry.x(for: r.end)
            if x1 < clip.minX { continue }
            if x0 > clip.maxX { break }
            let band = CGRect(x: x0, y: clip.minY, width: max(x1 - x0, 1), height: clip.height)
            fill.setFill(); band.fill()
            edge.setFill()
            CGRect(x: x0, y: clip.minY, width: 1, height: clip.height).fill()
            CGRect(x: max(x1 - 1, x0), y: clip.minY, width: 1, height: clip.height).fill()
        }
    }
}
