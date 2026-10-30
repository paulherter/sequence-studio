import Foundation
import SQCore
import SQDrawKit

/// Remove Silences preview (the Mac TimelineView+SilencePreview): every range the open dialog would cut is shaded red
/// across all lanes, with a solid edge at both ends, so the cuts can be judged against the waveforms before anything changes.
extension TimelinePanel {
    /// `Theme.TimelineSkin.silenceFill` / `silenceEdge`.
    static let silenceFillAlpha: Float = 0.28
    static let silenceEdgeAlpha: Float = 0.9

    func drawSilencePreview(_ cv: inout Canvas, clip: CGRect) {
        guard !silencePreview.isEmpty else { return }
        let red = skin.red
        let fill = red.alpha(Self.silenceFillAlpha), edge = red.alpha(Self.silenceEdgeAlpha)
        for r in silencePreview {
            let x0 = geometry.x(for: r.start), x1 = geometry.x(for: r.end)
            if x1 < clip.minX { continue }
            if x0 > clip.maxX { break }
            cv.fill(CGRect(x: x0, y: clip.minY, width: max(x1 - x0, 1), height: clip.height), fill)
            cv.fill(CGRect(x: x0, y: clip.minY, width: 1, height: clip.height), edge)
            cv.fill(CGRect(x: max(x1 - 1, x0), y: clip.minY, width: 1, height: clip.height), edge)
        }
    }
}
