#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SQUIKit

/// Clipping indication on a timeline waveform: the part of a column between -1 dBFS and full scale is drawn yellow
/// ("near"); a column that reaches 0 dBFS or goes over it (the waveform shows the level after Volume and Audio Gain)
/// is drawn red over the same band. Pure geometry on the columns the waveform is drawn from.
public enum WaveformClipping {
    /// -1 dBFS as linear amplitude: from here on a peak counts as near clipping.
    static let nearThreshold: Float = 0.891_25
    /// Columns this close to full scale count as reaching 0 dBFS (columns are clamped to 1).
    static let overThreshold: Float = 0.999

    public enum Level: Equatable { case clear, near, over }

    public static func level(of c: WaveformColumn) -> Level {
        let peak = max(abs(c.lo), abs(c.hi))
        if c.clipped || peak >= overThreshold { return .over }
        return peak >= nearThreshold ? .near : .clear
    }

    /// Bands to fill, in the coordinates of `rect` (same as `WaveformPath.bars`): `near` and `over` as rectangles.
    public static func bandRects(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> (near: [CGRect], over: [CGRect]) {
        var near: [CGRect] = [], over: [CGRect] = []
        let t = CGFloat(nearThreshold)
        for (lane, laneRect) in WaveformPath.laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            // y of the -1 dBFS line: from the bottom up (rectified) or either side of the center (bipolar).
            let cut: (CGFloat, CGFloat) = style.shape == .rectified
                ? (laneRect.maxY - t * laneRect.height, laneRect.maxY)
                : (laneRect.midY - t * laneRect.height / 2, laneRect.midY + t * laneRect.height / 2)
            for (i, c) in columns[lane].enumerated() {
                let level = level(of: c)
                guard level != .clear else { continue }
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { continue }
                let (top, bottom) = WaveformPath.yRange(c, laneRect, style)
                var add = [CGRect(x: x, y: top, width: 1, height: max(cut.0 - top, 1))]
                if style.shape == .bipolar {
                    let y = min(cut.1, bottom - 1)
                    add.append(CGRect(x: x, y: y, width: 1, height: max(bottom - y, 1)))
                }
                if level == .over { over += add } else { near += add }
            }
        }
        return (near, over)
    }

    #if canImport(AppKit)
    /// `bandRects` as paths.
    static func bands(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> (near: CGPath, over: CGPath) {
        let r = bandRects(columns: columns, rect: rect, style: style, firstColumn: firstColumn)
        let near = CGMutablePath(), over = CGMutablePath()
        r.near.forEach { near.addRect($0) }
        r.over.forEach { over.addRect($0) }
        return (near, over)
    }

    static var nearColor: CGColor { Theme.Colors.yellow.cgColor }
    static var overColor: CGColor { Theme.Colors.red.cgColor }
    #endif
}
