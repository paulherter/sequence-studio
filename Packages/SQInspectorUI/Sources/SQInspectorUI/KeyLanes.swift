import Foundation
import SQCore

/// Key lane on a timeline clip: a thin strip along the bottom of the clip body with one diamond per key time of the
/// effect section selected in Effect Controls (all of its properties merged, one glyph per time). Shown on selected
/// clips only, so the timeline stays quiet otherwise. Pure geometry, portable: the Mac `TimelineView` draws it
/// (`drawKeyLane`, KeyLanes+Timeline.swift), the shared-toolkit timeline through `KeyLanes.layout` (a host
/// `TimelineKeyLaneSource`). Positions come from an `x(for:)` closure so this file needs no timeline module.
@MainActor
public enum KeyLanes {
    /// Rows shorter than this show no lane.
    public static let minRowHeight: CGFloat = 40
    public static let laneHeight: CGFloat = 10
    public static let glyphSize: CGFloat = 7

    /// Where a Magic mask section's tracked frames come from (nil = not shown). The app's reads the shared matte store.
    public static var magicFrames: MagicTrackedFrames? = .shared

    /// One drawn lane: the strip and the glyphs inside the visible span, each with its timeline time.
    public struct Layout: Equatable, Sendable {
        public var lane: CGRect
        public var glyphs: [Glyph]
        public struct Glyph: Equatable, Sendable {
            public var center: CGPoint
            public var time: Time
            public var selected: Bool
        }
    }

    /// Timeline times of the keys of `section` on `clip`, sorted, one per distinct time. A mask section includes its Path
    /// keys, a Magic mask section its tracked frames.
    public static func keyTimes(clip: Clip, section: EffectSection, frameDuration: Time = .zero) -> [Time] {
        let groups = KeyframeSummary(tracks: EffectControlsModel.tracks(of: clip)).groups(of: Set(section.keyProperties.map(\.id)))
        var local = groups.map(\.time)
        if case .mask(let id) = section, let frames = magicFrames, let m = clip.mask(id),
           let key = EffectControlsModel.magicCacheKey(m, in: clip) {
            let tracked = frames.keys(clip: clip, mask: m, key: key, frameDuration: frameDuration)
            local = Array(Set(local + tracked.map(\.time))).sorted()
        }
        return local.map { clip.start + $0 }
    }

    /// Cheap checks before any key work: a lane is possible for this clip, section, selection and row height.
    public static func isApplicable(clip: Clip, section: EffectSection?, selected: Bool, rowHeight: CGFloat) -> Bool {
        if !selected || rowHeight < minRowHeight { return false }
        guard let section else { return false }
        switch section {
        case .volume: return clip.kind == .audio
        case .speed: return false
        case .motion, .opacity: return clip.kind == .video
        case .effect, .mask, .animation: return true
        }
    }

    public static func isVisible(clip: Clip, section: EffectSection?, selected: Bool, rowHeight: CGFloat) -> Bool {
        guard isApplicable(clip: clip, section: section, selected: selected, rowHeight: rowHeight), let section else { return false }
        return !keyTimes(clip: clip, section: section).isEmpty
    }

    /// The strip inside the clip's full rectangle: bottom of the body.
    public static func lane(in clipRect: CGRect) -> CGRect {
        let body = clipRect.insetBy(dx: 0, dy: 1)
        return CGRect(x: body.minX, y: body.maxY - laneHeight - 1, width: body.width, height: laneHeight)
    }

    /// Glyph centers (view space) for `times`, skipping those outside `visible` horizontally.
    public static func glyphCenters(times: [Time], clipRect: CGRect, visible: CGRect, x: (Time) -> CGFloat) -> [CGPoint] {
        let lane = lane(in: clipRect)
        return times
            .map { CGPoint(x: x($0), y: lane.midY) }
            .filter { $0.x >= visible.minX - glyphSize && $0.x <= visible.maxX + glyphSize }
    }

    /// Timeline time of the key glyph under `p` (nil = none): inside the lane strip, within half a glyph plus 2 pt of its center.
    public static func hitTest(clip: Clip, section: EffectSection, clipRect: CGRect, at p: CGPoint, frameDuration: Time,
                               x: (Time) -> CGFloat) -> Time? {
        let lane = lane(in: clipRect)
        guard p.y >= lane.minY - 2, p.y <= lane.maxY + 2 else { return nil }
        let reach = glyphSize / 2 + 2
        let times = keyTimes(clip: clip, section: section, frameDuration: frameDuration)
        return times.filter { abs(x($0) - p.x) <= reach }
            .min { abs(x($0) - p.x) < abs(x($1) - p.x) }
    }

    /// Everything one clip's lane draws (the Mac `drawKeyLane` steps): nil when the clip shows no lane (not applicable,
    /// off screen, no keys). `picked` are the lane times Effect Controls has selected (`keyLaneSelectedTimes`);
    /// `rowHeight` defaults to the clip rectangle's height.
    public static func layout(clip: Clip, section: EffectSection?, clipRect: CGRect, visible: CGRect, selected: Bool,
                              rowHeight: CGFloat? = nil, picked: Set<Time>, frameDuration: Time,
                              x: (Time) -> CGFloat) -> Layout? {
        guard let section, clipRect.maxX >= visible.minX, clipRect.minX <= visible.maxX,
              isApplicable(clip: clip, section: section, selected: selected, rowHeight: rowHeight ?? clipRect.height)
        else { return nil }
        let times = keyTimes(clip: clip, section: section, frameDuration: frameDuration)
        guard !times.isEmpty else { return nil }
        let strip = lane(in: clipRect)
        let glyphs = times.compactMap { t -> Layout.Glyph? in
            guard let c = glyphCenters(times: [t], clipRect: clipRect, visible: visible, x: x).first else { return nil }
            return Layout.Glyph(center: c, time: t, selected: picked.contains(t))
        }
        return Layout(lane: strip, glyphs: glyphs)
    }
}
