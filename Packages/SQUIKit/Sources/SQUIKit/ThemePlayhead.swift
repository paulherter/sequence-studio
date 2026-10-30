import AppKit

// Playhead "K1" (DECISIONS 2026-10-13): the app icon's head shape without the face, porcelain gradient, 12 pt wide head,
// 2 pt line. One drawing helper for every ruler, lane and curve view; no view draws its own head.

extension Theme {
    public enum PlayheadSkin {
        /// Thickness of every playhead line.
        public static let lineWidth: CGFloat = 2
        /// The head: even width so it sits centered on the 2 pt line (half-pixel safe), height from the icon's aspect.
        public static let headSize = CGSize(width: 12, height: 12)
        public static let headOutlineWidth: CGFloat = 1

        /// Icon head outline in its SVG space (`pip-head.svg`, viewBox 122 152 780 776), converted once; no SVG at runtime.
        nonisolated(unsafe) private static let source: CGPath = {   // immutable after init
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 250.96, y: 152.12))
            p.addLine(to: CGPoint(x: 773.04, y: 152.12))
            p.addCurve(to: CGPoint(x: 902, y: 281.08), control1: CGPoint(x: 855.62, y: 152.12), control2: CGPoint(x: 902, y: 198.5))
            p.addLine(to: CGPoint(x: 902, y: 620.12))
            p.addCurve(to: CGPoint(x: 824, y: 738.68), control1: CGPoint(x: 902, y: 669.94), control2: CGPoint(x: 865.18, y: 707.58))
            p.addLine(to: CGPoint(x: 609.55, y: 900.92))
            p.addCurve(to: CGPoint(x: 414.45, y: 900.92), control1: CGPoint(x: 561.4, y: 937.32), control2: CGPoint(x: 462.6, y: 937.32))
            p.addLine(to: CGPoint(x: 200, y: 738.68))
            p.addCurve(to: CGPoint(x: 122, y: 620.12), control1: CGPoint(x: 158.82, y: 707.58), control2: CGPoint(x: 122, y: 669.94))
            p.addLine(to: CGPoint(x: 122, y: 281.08))
            p.addCurve(to: CGPoint(x: 250.96, y: 152.12), control1: CGPoint(x: 122, y: 198.5), control2: CGPoint(x: 168.38, y: 152.12))
            p.closeSubpath()
            return p
        }()

        /// Head outline with its center line at `centerX` and its top at `top` (y grows downward, flipped views).
        public static func headPath(centerX c: CGFloat, top: CGFloat = 0) -> CGPath {
            var t = CGAffineTransform(translationX: c - headSize.width / 2, y: top)
            t = t.scaledBy(x: headSize.width / 780, y: headSize.height / 776)
            t = t.translatedBy(x: -122, y: -152)
            return source.copy(using: &t) ?? source
        }

        /// Frame of the line centered on `x` (rounded to a whole point), `height` tall from `y`.
        public static func lineFrame(centerX x: CGFloat, y: CGFloat = 0, height: CGFloat) -> NSRect {
            NSRect(x: x.rounded() - lineWidth / 2, y: y, width: lineWidth, height: height)
        }

        /// Draws the head into the current (flipped) graphics context.
        @MainActor public static func drawHead(centerX c: CGFloat, top: CGFloat = 0) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let path = headPath(centerX: c, top: top)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: [headTop.cgColor, headBottom.cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: c, y: top), end: CGPoint(x: c, y: top + headSize.height), options: [])
            }
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(headOutline.cgColor)
            ctx.setLineWidth(headOutlineWidth)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
