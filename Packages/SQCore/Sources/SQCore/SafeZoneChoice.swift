#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The platform whose UI zone the Program monitor overlays. Independent of the sequence; remembered by the app
/// (`sq.monitor.safeZone`). Creator platforms only.
public enum SafeZoneChoice: String, Sendable, Hashable, CaseIterable {
    case off, tiktok, reels, shorts, youtube

    public var title: String {
        switch self {
        case .off: "Off"
        case .tiktok: "TikTok"
        case .reels: "Reels"
        case .shorts: "Shorts"
        case .youtube: "YouTube"
        }
    }

    /// Short label of the monitor popup ("Zone off" is shown as "Zone").
    public var badgeTitle: String { self == .off ? "Zone" : title }

    /// The zone a sequence's delivery platform implies (off when it has none).
    public init(platform: DeliveryPlatform) {
        switch platform.safeZonePlatform {
        case .tiktok?: self = .tiktok
        case .reels?: self = .reels
        case .shorts?: self = .shorts
        case nil: self = .off
        }
    }

    /// Unknown or missing stored values mean off.
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .off }

    /// YouTube long-form: approximate title bar (top) and player controls (bottom) of the 16:9 player, full frame at any aspect.
    static let youtubeZone = SafeZone(top: 0.08, bottom: 0.12, left: 0.05, right: 0.05)

    /// The clear (safe) rectangle as frame fractions, origin top-left; nil when off.
    public func normRect(frameAspect: Double) -> NormRect? {
        switch self {
        case .off: nil
        case .tiktok: SafeZone.rect(for: .tiktok, frameAspect: frameAspect)
        case .reels: SafeZone.rect(for: .reels, frameAspect: frameAspect)
        case .shorts: SafeZone.rect(for: .shorts, frameAspect: frameAspect)
        case .youtube: Self.youtubeZone.rect
        }
    }

    /// The clear rectangle in offset space (sequence px from the canvas center, y down), as snapping and drawing use it.
    public func offsetRect(canvasWidth w: Double, canvasHeight h: Double) -> CGRect? {
        guard let n = normRect(frameAspect: w / max(h, 1)) else { return nil }
        return CGRect(x: (n.x - 0.5) * w, y: (n.y - 0.5) * h, width: n.width * w, height: n.height * h)
    }
}
