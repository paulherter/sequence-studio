import Foundation

// The Auto Reframe options sheet: two plain choices that map onto `ReframeOptions`.

/// How closely the camera path of an Auto Reframe follows the subject over time (sheet row "Motion").
public enum ReframeSmoothness: String, Sendable, Hashable, CaseIterable {
    /// Follows quickly; small moves show.
    case quick
    /// The default.
    case steady
    /// Calm, slow camera; can lag behind fast subjects.
    case smooth

    public var title: String { self == .quick ? "Quick" : self == .steady ? "Steady" : "Smooth" }
}

/// How tight the framing sits on the subject (sheet row "Framing").
public enum ReframeTightness: String, Sendable, Hashable, CaseIterable {
    /// Just fills the frame (the default).
    case fill
    case closer
    case tight

    public var title: String { self == .fill ? "Fill Frame" : self == .closer ? "Closer" : "Tight" }
}

extension ReframeOptions {
    /// The options of a sheet choice; Steady and Fill Frame are the unchanged defaults.
    public init(smoothness: ReframeSmoothness, tightness: ReframeTightness) {
        self.init()
        switch smoothness {
        case .quick: smoothingWindow = 0.4; deadZone = 0.03
        case .steady: break
        case .smooth: smoothingWindow = 2.5; deadZone = 0.08
        }
        switch tightness {
        case .fill: zoom = 1
        case .closer: zoom = 1.2
        case .tight: zoom = 1.4
        }
    }
}
