import AppKit

/// Where Pip appears in the app (design `pip-in-der-app`, places M1...M15). One constant switches a place: remove it
/// from `enabled`. Only places that are out of the way of editing are listed; M4, M13 and M18 are deliberately not built.
public enum SQMascotPlace: String, CaseIterable, Sendable {
    case startEmpty        // M1  start window, no project yet
    case startProjects     // M2  start window with projects, peeks over the support card
    case projectEmpty      // M3  Project panel, no media
    case programEmpty      // M5  Program monitor, no sequence
    case searchEmpty       // M6  search finds nothing
    case exportRunning     // M7
    case exportDone        // M8
    case exportFailed      // M9
    case captionsRunning   // M10
    case mediaOffline      // M14
    case importDone        // M15

    /// The places that are switched on. Edit this set to turn a place off.
    public static let enabled: Set<SQMascotPlace> = Set(allCases)

    public var isEnabled: Bool { Self.enabled.contains(self) }

    public var animation: SQMascotAnim {
        switch self {
        case .startEmpty: return .wink
        case .startProjects: return .peek
        case .projectEmpty, .programEmpty: return .sleep
        case .searchEmpty: return .search
        case .exportRunning: return .work
        case .exportDone: return .cheer
        case .exportFailed: return .oops
        case .captionsRunning: return .think
        case .mediaOffline: return .sad
        case .importDone: return .proud
        }
    }

    /// Edge length of the artwork in points.
    public var side: CGFloat {
        switch self {
        case .startEmpty: return 120
        case .startProjects: return 52
        case .projectEmpty: return 36
        case .programEmpty: return 72
        case .searchEmpty: return 52
        case .exportRunning: return 38
        case .exportDone: return 84
        case .exportFailed: return 34
        case .captionsRunning: return 48
        case .mediaOffline: return 26
        case .importDone: return 44
        }
    }

    /// Rest between repeats in seconds where the design sets one (nil: the animation's own).
    public var restPause: ClosedRange<Double>? {
        switch self {
        case .startEmpty: return 5...9
        case .startProjects: return 4...7
        case .searchEmpty: return 8...14
        default: return nil
        }
    }

    /// How far the bottom of a peeking Pip reaches behind the card edge, in points. 0: his cut edge is flush with the card's
    /// top edge (feedback 2026-10-30: 2 pt looked too low, "inside").
    public static let peekTuck: CGFloat = 0

    /// Top y of a peeking Pip of `height` whose card's top edge is at `cardTop` (y grows downward): his bottom ends
    /// `peekTuck` points below the edge, hidden by the card.
    public static func peekTop(cardTop: CGFloat, height: CGFloat) -> CGFloat { cardTop - height + peekTuck }

    /// A new view for this place, or nil when the place is switched off.
    @MainActor public func makeView(side override: CGFloat? = nil) -> SQMascotView? {
        guard isEnabled else { return nil }
        let v = SQMascotView(.animation(animation), side: override ?? side)
        v.restPause = restPause
        v.place = self
        return v
    }
}
