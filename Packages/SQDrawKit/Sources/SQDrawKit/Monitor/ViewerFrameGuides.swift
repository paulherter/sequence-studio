import Foundation

/// Aspect frame of the Program monitor: the largest centered rectangle of a ratio inside the picture (9:16 inside a
/// 16:9 picture, 16:9 inside a vertical one). Session-only, drawn over the picture, never exported.
public enum AspectFrame: String, Sendable, CaseIterable, Equatable {
    case off, vertical9x16, portrait4x5, square1x1, wide16x9

    public var title: String {
        switch self {
        case .off: "Off"
        case .vertical9x16: "9:16"
        case .portrait4x5: "4:5"
        case .square1x1: "1:1"
        case .wide16x9: "16:9"
        }
    }

    /// Width / height; nil for `.off`.
    public var ratio: Double? {
        switch self {
        case .off: nil
        case .vertical9x16: 9.0 / 16.0
        case .portrait4x5: 4.0 / 5.0
        case .square1x1: 1
        case .wide16x9: 16.0 / 9.0
        }
    }

    /// The frame inside `picture` (same coordinate space), centered; nil when off or the picture is empty.
    public func rect(in picture: CGRect) -> CGRect? {
        guard let ratio, picture.width > 0, picture.height > 0 else { return nil }
        var w = picture.width, h = picture.width / ratio
        if h > picture.height { h = picture.height; w = h * ratio }
        return CGRect(x: picture.midX - w / 2, y: picture.midY - h / 2, width: w, height: h)
    }
}

/// Size of the two safe-margin rectangles as percent of the picture (action outer, title inner). Session-only.
public struct SafeMarginSizes: Sendable, Equatable {
    public static let actionPresets = [95, 93, 90, 85]
    public static let titlePresets = [90, 85, 80, 70]
    public static let `default` = SafeMarginSizes(action: 90, title: 80)

    public private(set) var action: Int
    public private(set) var title: Int

    public init(action: Int, title: Int) {
        let a = min(max(action, 50), 100)
        self.action = a
        self.title = min(max(title, 50), a)     // title safe never exceeds action safe
    }

    public func settingAction(_ v: Int) -> SafeMarginSizes { SafeMarginSizes(action: v, title: title) }
    public func settingTitle(_ v: Int) -> SafeMarginSizes { SafeMarginSizes(action: action, title: v) }
    /// Fractions in draw order (outer first).
    public var fractions: [Double] { [Double(action) / 100, Double(title) / 100] }
}
