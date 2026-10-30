import Foundation

/// Geometry of the light platform UI mock the Program monitor can draw over the dimmed zone (right action column, account
/// name and caption lines, progress bar). Pure fractions of the frame (origin top-left), derived from the clear (safe)
/// rectangle, so it scales with any frame and matches whatever the zone popup chose. Preview only: never exported.
public enum PlatformUIMock {
    public enum Kind: Sendable, Hashable { case avatar, like, comment, share, save, accountName, captionLine, progressBar }

    public struct Element: Sendable, Hashable {
        public var kind: Kind
        /// Frame fractions. The round buttons are square in pixels at `frameAspect`.
        public var rect: NormRect
        public var isRoundButton: Bool { [.avatar, .like, .comment, .share, .save].contains(kind) }
    }

    /// The elements for a clear rectangle `zone` in a frame of `frameAspect` (width / height). Empty when the zone leaves
    /// no room outside it (a full-frame zone).
    public static func elements(zone z: NormRect, frameAspect: Double) -> [Element] {
        let aspect = max(frameAspect, 0.01)
        let rightBand = 1 - (z.x + z.width), bottomBand = 1 - (z.y + z.height)
        var out: [Element] = []
        if rightBand > 0.01 {
            let dh = min(min(rightBand * 0.62, 0.11) * aspect, (z.y + z.height) / 7.6), dw = dh / aspect   // the stack always fits above the zone's bottom
            let cx = (z.x + z.width) + rightBand / 2
            let step = dh * 1.55
            let kinds: [Kind] = [.save, .share, .comment, .like, .avatar]   // bottom to top
            var cy = z.y + z.height - dh * 0.7
            for k in kinds {
                out.append(Element(kind: k, rect: NormRect(x: cx - dw / 2, y: cy - dh / 2, width: dw, height: dh)))
                cy -= step
            }
        }
        if bottomBand > 0.02 {
            let top = z.y + z.height
            let w = z.width
            out.append(Element(kind: .accountName, rect: NormRect(x: z.x, y: top + bottomBand * 0.12, width: min(0.30, w * 0.45), height: bottomBand * 0.07)))
            out.append(Element(kind: .captionLine, rect: NormRect(x: z.x, y: top + bottomBand * 0.28, width: w * 0.85, height: bottomBand * 0.06)))
            out.append(Element(kind: .captionLine, rect: NormRect(x: z.x, y: top + bottomBand * 0.40, width: w * 0.60, height: bottomBand * 0.06)))
            out.append(Element(kind: .progressBar, rect: NormRect(x: 0, y: 1 - 0.004, width: 1, height: 0.004)))
        }
        return out
    }
}

extension SafeZoneChoice {
    /// The platforms that have a UI mock (the vertical creator apps); YouTube long-form and off have none.
    public var hasUIMock: Bool { self == .tiktok || self == .reels || self == .shorts }

    /// The mock elements for this choice in a frame of `frameAspect`; empty when there is none.
    public func uiMock(frameAspect: Double) -> [PlatformUIMock.Element] {
        guard hasUIMock, let z = normRect(frameAspect: frameAspect) else { return [] }
        return PlatformUIMock.elements(zone: z, frameAspect: frameAspect)
    }
}
