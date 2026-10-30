#if os(Windows)
import Foundation

/// The few `Theme` tokens the portable timeline logic reads (SQUIKit's `Theme` is AppKit and stays Mac-only). Values are
/// the Mac's at UI scale 1; the draw-list toolkit scales points to pixels itself.
/// shortcut: copies of `Theme.Metrics` / `Theme.Motion` / `Theme.PlayheadSkin` values, until SQUIKit's tokens move into a portable file.
public enum Theme {
    public enum Metrics {
        public static let trackV1: CGFloat = 40
        public static let trackA1: CGFloat = 32
        public static let trackOther: CGFloat = 20
        public static let trackHeader: CGFloat = 156
        public static let toolColumn: CGFloat = 0
    }
    public enum PlayheadSkin {
        public static let lineWidth: CGFloat = 2
        public static func lineFrame(centerX x: CGFloat, y: CGFloat = 0, height: CGFloat) -> CGRect {
            CGRect(x: x.rounded() - lineWidth / 2, y: y, width: lineWidth, height: height)
        }
    }
    public enum Motion {
        public static let fast: Double = 0.12
        public enum Curve: Sendable, Equatable {
            case easeOut
            public func value(_ t: Double) -> Double {
                let c = min(max(t, 0), 1)
                return 1 - pow(1 - c, 3)
            }
        }
    }
}
#endif
