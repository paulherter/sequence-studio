import Foundation
import SQCore

/// What the thumbnails of a video clip on the timeline show: the first frame in a column at the head (the default),
/// the first and the last frame, or a strip of frames along the whole clip.
public enum ThumbnailMode: String, CaseIterable, Sendable {
    case head, headAndTail, continuous

    public var title: String {
        switch self {
        case .head: "Head"
        case .headAndTail: "Head and Tail"
        case .continuous: "Continuous"
        }
    }
}

/// The choice is a user preference of the app (UserDefaults `sq.timeline.thumbnailMode`), not part of a project.
public enum ThumbnailPrefs {
    public static let modeKey = "sq.timeline.thumbnailMode"
    public static let didChange = Notification.Name("sq.timeline.thumbnailMode.didChange")

    public static var mode: ThumbnailMode {
        get { ThumbnailMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .head }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// One picture of a clip's thumbnails, in clip-local points.
public struct ThumbnailTile: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable {
        /// The clip's first frame.
        case head
        /// The clip's last frame.
        case tail
        /// The frame at this share (0...1) of the clip's length.
        case fraction(Double)
    }
    /// Distance of the tile's left edge from the clip's left edge.
    public var offset: CGFloat
    public var width: CGFloat
    public var anchor: Anchor
    /// Drawn under the name strip instead of beside it (the strip modes keep the name readable).
    public var belowNameStrip: Bool
}

public enum ThumbnailLayout {
    /// Most tiles a clip gets in one draw (a safety cap far above what a screen shows).
    static let maxTiles = 400

    /// The tiles of a clip `clipWidth` points wide.
    /// - Parameters:
    ///   - column: the head column's width (`ClipDrawing.thumbnailColumn` result, 0 = the clip shows no thumbnails).
    ///   - visible: the part of the clip on screen in clip-local points; tiles outside it are not made.
    public static func tiles(mode: ThumbnailMode, clipWidth: CGFloat, column: CGFloat, visible: ClosedRange<CGFloat>) -> [ThumbnailTile] {
        guard column > 0, clipWidth > 0 else { return [] }
        switch mode {
        case .head:
            return [ThumbnailTile(offset: 0, width: column, anchor: .head, belowNameStrip: false)]
        case .headAndTail:
            let head = ThumbnailTile(offset: 0, width: column, anchor: .head, belowNameStrip: false)
            // A clip too short for two columns and a name keeps only the head.
            guard clipWidth >= column * 2 + 24 else { return [head] }
            return [head, ThumbnailTile(offset: clipWidth - column, width: column, anchor: .tail, belowNameStrip: false)]
        case .continuous:
            let w = column * 2
            let first = max(0, Int((max(visible.lowerBound, 0) / w).rounded(.down)))
            let last = Int((min(visible.upperBound, clipWidth) / w).rounded(.down))
            guard last >= first else { return [] }
            var out: [ThumbnailTile] = []
            for i in first...min(last, first + maxTiles) {
                let x = CGFloat(i) * w
                guard x < clipWidth else { break }
                let tile = min(w, clipWidth - x)
                // The first tile shows the first frame, the last one the last frame; the rest the frame under their center.
                let anchor: ThumbnailTile.Anchor = i == 0 ? .head
                    : (x + w >= clipWidth ? .tail : .fraction(Double((x + tile / 2) / clipWidth)))
                out.append(ThumbnailTile(offset: x, width: tile, anchor: anchor, belowNameStrip: true))
            }
            return out
        }
    }

    /// Media time a tile asks for. Interior frames snap to a quarter second so zooming reuses cached pictures; the first
    /// and last frame are exact.
    public static func mediaTime(of anchor: ThumbnailTile.Anchor, clip c: Clip, frameDuration fd: Time) -> Time {
        let lastFrame = max(c.timeline.start, c.timeline.end - fd)
        switch anchor {
        case .head:
            return c.sourceTime(at: c.timeline.start, frameDuration: fd)
        case .tail:
            return c.sourceTime(at: lastFrame, frameDuration: fd)
        case .fraction(let f):
            let local = Time.scaled(c.timeline.duration, by: Int64((min(max(f, 0), 1) * 1000).rounded()), over: 1000)
            let at = min(max((c.timeline.start + local).snapped(to: fd), c.timeline.start), lastFrame)
            return c.sourceTime(at: at, frameDuration: fd).snapped(to: Time(1, 4))
        }
    }
}
