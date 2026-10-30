import Foundation
import SQDrawKit
import SQTimelineUI

/// The header column's Mix row (AppKit `TimelineView.drawMixHeader`): "Mix" with "0.0 dB" on the right, right after
/// the last track row. Like the AppKit row it has no model behind it yet (the master gain reads 0.0 dB).
extension TimelinePanel {
    static let mixRowHeight: CGFloat = 22
    static let mixLevelText = "0.0 dB"

    /// The row in panel points, nil while it would leave the track area (under the ruler or into the zoom bar).
    func mixRowRect() -> CGRect? {
        let top = rows.last.map(\.bottom) ?? (TimelineGeometry.rulerHeight + geometry.captionHeight(for: timeline))
        let r = CGRect(x: TimelineGeometry.toolColumnWidth, y: top, width: TimelineGeometry.headerWidth, height: Self.mixRowHeight)
        guard r.minY >= TimelineGeometry.rulerHeight, r.maxY <= trackAreaHeight else { return nil }
        return r
    }

    /// Design v9 `.th` without a chip: panel fill, 1 pt row line, separator, name, level in caption size.
    func drawMixRow(_ cv: inout Canvas) {
        guard let r = mixRowRect() else { return }
        cv.fill(r, theme.panel)
        cv.fill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), theme.trackRowLine)
        cv.fill(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), theme.separator)
        let chip = Self.chipRect(height: r.height).offsetBy(dx: r.minX + patchColumnOffset, dy: r.minY)
        let level = CGRect(x: r.minX, y: r.minY, width: r.width - 1, height: r.height)
        let levelW = cv.draw(Self.mixLevelText, in: level, fontSize: DrawTheme.TypeSize.caption.cg, theme.label3, align: .right,
                             inset: DrawTheme.Spacing.sm.cg)
        let nameX = chip.maxX + Self.buttonGap
        let nameW = r.maxX - DrawTheme.Spacing.sm.cg - levelW - Self.buttonGap - nameX
        guard nameW > 12 else { return }
        cv.draw("Mix", at: CGPoint(x: nameX, y: (r.minY + (r.height - 14) / 2).rounded()), fontSize: DrawTheme.TypeSize.body.cg,
                theme.label2, maxWidth: nameW)
    }
}
