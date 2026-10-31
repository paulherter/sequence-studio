import Foundation

/// Pure helpers of the Library preview transport.
public enum LibraryPreviewMath {
    /// Seek target for a skip button: clamped to 0...duration (an unknown duration only clamps at 0).
    public static func skipTarget(position: Double, delta: Double, duration: Double) -> Double {
        let t = position + delta
        guard t.isFinite else { return 0 }
        return duration > 0 ? min(max(t, 0), duration) : max(t, 0)
    }

    /// "m:ss", or "h:mm:ss" from one hour; negative, NaN and infinity read 0:00.
    public static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The preview a library kind gets.
    public enum Mode: Sendable, Equatable { case audio, video, image }

    public static func mode(for kind: LibraryItemKind) -> Mode? {
        switch kind {
        case .audio: .audio
        case .video: .video
        case .image, .overlay: .image
        case .lut, .font, .other: nil
        }
    }

    // MARK: Viewer size (the divider between list and preview)

    public static let minViewerHeight: Double = 60
    public static let maxViewerHeight: Double = 480
    /// Height the list keeps at least, and what the bar needs besides the viewer (padding, transport).
    public static let listReserve: Double = 160
    public static let chromeHeight: Double = 70

    /// The viewer height to show: the stored one (or `fallback`), within min/max and, when the panel height is known
    /// (> 0), leaving `listReserve` for the list.
    public static func viewerHeight(stored: Double?, fallback: Double, panelHeight: Double) -> Double {
        var h = stored.flatMap { $0.isFinite ? $0 : nil } ?? fallback
        var top = maxViewerHeight
        if panelHeight > 0 { top = min(top, panelHeight - listReserve - chromeHeight) }
        h = min(h, top)
        return max(h, minViewerHeight)
    }

    /// Dragging the divider up (negative y change in a flipped view) makes the viewer taller.
    public static func resizedHeight(start: Double, dragDeltaY: Double) -> Double { start - dragDeltaY }

    // MARK: Sidebar width (the divider between the folder tree and the items)

    public static let defaultSidebarWidth: Double = 136
    public static let minSidebarWidth: Double = 96
    public static let maxSidebarWidth: Double = 320
    /// Width the item area keeps at least.
    public static let contentReserve: Double = 160

    /// The sidebar width to show: the stored one (or the default) within min/max, leaving `contentReserve` for the items.
    /// A panel narrower than min + reserve keeps the minimum.
    public static func sidebarWidth(stored: Double?, panelWidth: Double) -> Double {
        let w = stored.flatMap { $0.isFinite ? $0 : nil } ?? defaultSidebarWidth
        var top = maxSidebarWidth
        if panelWidth > 0 { top = min(top, panelWidth - contentReserve) }
        return max(min(w, top), minSidebarWidth)
    }
}
