import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The tile under the pointer while hover scrubbing: which media, the frame time, where the scrub line sits.
struct HoverScrubState: Equatable {
    var item: Int
    var media: MediaRef.ID
    var time: Time
    var x: CGFloat
}

/// Hover Scrub in the icon grid (the Mac `ProjectIconView.mouseMoved`): over a video tile's thumbnail the pointer's
/// x picks the frame (`HoverScrub.time`), the tile shows it with a 1.5 pt accent line. Plus the item tips.
extension ProjectListView {
    /// The Mac `scrubLine` width.
    static let scrubLineWidth: CGFloat = 1.5

    /// View > Hover Scrub: switches it and keeps the choice in the user's settings.
    public func setHoverScrub(_ on: Bool) {
        hoverScrubOn = on
        if !on { scrub = nil }
        var s = AppSettings.load(from: defaults)
        s.hoverScrub = on
        s.save(to: defaults)
    }

    /// While Hover Scrub is off, holding Shift scrubs (the Mac `ProjectIconView`, Premiere); the keys come from
    /// `liveModifiers`.
    func scrubState(at p: CGPoint) -> HoverScrubState? {
        let shift = liveModifiers?().contains(.shift) ?? false
        guard hoverScrubOn || shift, !isDragging, viewMode == .icons, let model, let i = tile(at: p), thumbRect(i).contains(p) else { return nil }
        let items = gridItems()
        guard items.indices.contains(i), case .media(let id) = items[i], let ref = model.project.media(id),
              ref.kind != .audio, ref.kind != .image, !model.isOffline(id),
              let total = ref.info?.duration ?? ref.duration, total > .zero else { return nil }
        let r = thumbRect(i)
        let t = HoverScrub.time(fraction: Double((p.x - r.minX) / r.width), duration: total,
                                frameDuration: ref.info?.video?.nominalFrameDuration ?? Time(1, 30))
        return HoverScrubState(item: i, media: id, time: t, x: p.x)
    }

    /// The clip and frame under the pointer in the icon view (Set Poster Frame uses it).
    public var hoveredFrame: (media: MediaRef.ID, time: Time)? { scrub.map { ($0.media, $0.time) } }

    /// The poster a grid tile draws: the scrubbed frame while the pointer is over it (the poster until it loads).
    func tilePoster(_ i: Int, media m: MediaRef.ID) -> ProjectPoster? {
        if let s = scrub, s.item == i, s.media == m, let p = posterAt?(m, s.time) { return p }
        return poster?(m)
    }

    func drawScrubLine(_ c: inout Canvas, theme: DrawTheme, item i: Int) {
        guard let s = scrub, s.item == i else { return }
        let r = thumbRect(i)
        c.fill(CGRect(x: min(max(s.x, r.minX), r.maxX - Self.scrubLineWidth), y: r.minY, width: Self.scrubLineWidth, height: r.height),
               theme.accent)
    }

    /// The tip over a media row or tile: its file path (offline items say so).
    func itemTip(at p: CGPoint) -> String? {
        guard !isDragging, let model, let i = item(at: p) else { return nil }
        let items = items()
        guard items.indices.contains(i), case .media(let id) = items[i], let ref = model.project.media(id) else { return nil }
        return model.isOffline(id) ? SQL10n.format("Offline: %@", ref.path) : ref.path
    }
}
