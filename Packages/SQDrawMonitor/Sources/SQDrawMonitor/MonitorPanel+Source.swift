import Foundation
import SQCore
import SQDrawKit
import SQMedia

/// The Program | Source tab strip of the monitor card and the Source monitor's waveform view for audio-only media
/// (SourceWaveformView translated): the whole file's peaks, the In-Out range behind them and the playhead; a press scrubs.
extension MonitorPanel {
    /// Tab labels in the header instead of the title (the Mac tab group of Program and Source); the host draws one panel
    /// per tab on the same card and switches on `onSelectTab`.
    static let tabGap = CGFloat(DrawTheme.Spacing.md)
    static let waveInset: CGFloat = 8
    static let waveVerticalInset: CGFloat = 24

    /// Draws the title or the tabs at `x`; returns the width taken. Fills `tabRects`.
    func drawTitleOrTabs(_ c: inout Canvas, x: CGFloat, fontSize: CGFloat) -> CGFloat {
        let t = theme
        tabRects = []
        guard !tabs.isEmpty else {
            return c.draw(title, in: CGRect(x: x, y: headerRect.minY, width: headerRect.width / 2, height: headerRect.height),
                          fontSize: fontSize, t.label)
        }
        var cursor = x
        for (i, label) in tabs.enumerated() {
            let w = c.size(of: label, fontSize: fontSize).width.rounded(.up)
            let r = CGRect(x: cursor, y: headerRect.minY, width: w, height: headerRect.height)
            tabRects.append(r)
            c.draw(label, in: r, fontSize: fontSize, i == selectedTab ? t.label : t.label3)
            cursor += w + Self.tabGap
        }
        return cursor - Self.tabGap - x
    }

    /// The tab under `p` (window points), if any.
    public func tab(at p: CGPoint) -> Int? {
        tabRects.firstIndex { $0.insetBy(dx: -Self.tabGap / 2, dy: 0).contains(p) }
    }

    /// Audio-only media in the Source monitor: the waveform replaces the picture.
    public var showsWaveform: Bool { model.mode == .source && model.viewerMode == .waveform && emptyText == nil }

    var waveMath: MonitorScrubMath {
        MonitorScrubMath(duration: model.duration, frameDuration: model.frameDuration, width: waveContentWidth, inset: Self.waveInset)
    }

    func drawWaveform(_ c: inout Canvas) {
        let t = theme
        let wave = CGRect(x: slot.minX + Self.waveInset, y: slot.minY + Self.waveVerticalInset,
                          width: max(waveContentWidth - 2 * Self.waveInset, 1), height: max(slot.height - 2 * Self.waveVerticalInset, 1))
        let m = waveMath, total = model.duration
        if model.markIn != nil || model.markOut != nil, total > .zero {
            let a = m.x(for: model.markIn ?? .zero), b = m.x(for: model.markOut ?? total)
            if b > a {
                c.fill(CGRect(x: slot.minX + a, y: wave.minY - 8, width: b - a, height: wave.height + 16),
                       t.accent.alpha(t.palette.isDark ? 0.22 : 0.16))
            }
        }
        if let data = model.sourceWaveform, total > .zero {
            let buckets = max(1, Int(wave.width.rounded()))
            let channels = data.peaks(in: TimeRange(start: .zero, end: total), buckets: buckets)
            let n = max(channels.count, 1)
            let laneH = wave.height / CGFloat(n)
            let ink = DrawColor.white.alpha(0.62), clip = Self.color(t.palette.red)
            for (ci, peaks) in channels.enumerated() {
                let mid = wave.minY + laneH * (CGFloat(ci) + 0.5), half = laneH / 2 - 1
                for (i, p) in peaks.enumerated() {
                    let hi = CGFloat(min(max(p.max, -1), 1)), lo = CGFloat(min(max(p.min, -1), 1))
                    let top = mid - hi * half, h = max((hi - lo) * half, 1)
                    c.fill(CGRect(x: wave.minX + CGFloat(i), y: top, width: 1, height: h),
                           p.max >= 1 || p.min <= -1 ? clip : ink)
                }
            }
        } else if total > .zero {
            c.draw("Building waveform\u{2026}", in: CGRect(x: slot.minX, y: slot.midY - 9, width: slot.width, height: 18),
                   fontSize: 13, t.label3, align: .center)
        }
        guard total > .zero else { return }
        c.fill(CGRect(x: slot.minX + m.x(for: model.currentTime) - 0.5, y: slot.minY, width: 1, height: slot.height), t.playhead)
    }

    /// A press or drag on the waveform scrubs (the first call of a gesture begins the scrub).
    func scrubWaveform(began: Bool, at p: CGPoint) {
        guard model.duration > .zero else { return }
        if began { model.onScrubBegan?() }
        let t = waveMath.time(atX: p.x - slot.minX)
        if let s = model.onScrub { s(t) } else { model.onSeek?(t) }
    }
}
