import Foundation
import SQCore

/// The one ease list for the Graphics panel's key right-click (docs/VOCABULARY.md Easing): the same names and order as every
/// other menu, then "Custom…" which opens the curve popover. Pure list; the editor stores the pick like a clip key's ease.
public enum GraphicsKeyEase {
    /// Steady, Smooth, Smooth In, Smooth Out, Hold, Fast Start, Fast End, Gentle, Smooth In 100%, Smooth Out 100%, Soft Landing.
    public static let menuCurves: [EasingCurve] = [
        .linear, .easeInOut, .easeIn, .easeOut, .hold, .fastStart, .fastEnd, .premiereDefault, .easeOut100, .easeIn100, .softLanding,
    ]
    public static var menuTitles: [String] { menuCurves.map(\.displayName) + [EaseName.customMenu] }
}
