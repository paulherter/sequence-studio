import AppKit
import SQUIKit

extension ClipDrawing {
    /// A background analysis of the clip (Stabilizer): a thin progress strip along the clip's bottom edge, no popup. The strip
    /// shows the share done; the picture and the timeline stay usable while it runs.
    @MainActor static func drawAnalysisProgress(rect: CGRect, progress: Double) {
        guard rect.width >= 12 else { return }
        let h: CGFloat = 3
        let track = CGRect(x: rect.minX + 1, y: rect.maxY - h - 1, width: rect.width - 2, height: h)
        Theme.Colors.accent.withAlphaComponent(0.3).setFill()
        track.fill()
        Theme.Colors.accent.setFill()
        CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(max(progress, 0), 1)), height: h).fill()
    }
}
