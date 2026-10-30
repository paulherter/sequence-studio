import Foundation

// Split-screen layouts: N clips on stacked video tracks get Scale, Position and a Crop effect so that each fills one
// cell of the frame. Everything is written as ordinary Motion values, Crop parameters and keyframes, so the result is
// editable in Effect Controls afterwards. Pure model code, no file-format change (Crop is an existing effect).

/// A rectangle of the sequence frame in pixels, origin top-left, y down.
public struct SplitCell: Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum SplitLayoutPreset: String, Sendable, Hashable, CaseIterable {
    /// 50/50 with a vertical divider: first clip left, second right.
    case sideBySide
    /// 50/50 with a horizontal divider: first clip top, second bottom.
    case stacked
    /// 60/40 with a vertical divider: first clip left (60 %).
    case sixtyForty
    /// Three equal rows, first clip on top.
    case threeStacked
    /// First clip fills the frame, second sits in the bottom-right corner (30 % width).
    case pictureInPicture
    /// Like Picture in Picture, but a square slot with fully rounded corners (a circle).
    case pictureInPictureCircle

    /// Clips a preset needs (extra selected clips are left alone).
    public var cellCount: Int { self == .threeStacked ? 3 : 2 }

    public var title: String {
        switch self {
        case .sideBySide: "Side by Side 50/50"
        case .stacked: "Top and Bottom 50/50"
        case .sixtyForty: "Side by Side 60/40"
        case .threeStacked: "Three Stacked"
        case .pictureInPicture: "Picture in Picture"
        case .pictureInPictureCircle: "Picture in Picture (Circle)"
        }
    }
}

public enum SplitLayoutError: Error, Equatable {
    case tooFewClips(required: Int)
    /// Two selected clips share a track: a split screen needs one clip per track.
    case sameTrack
}

/// Where a clip lands in its cell: cover fit (the picture fills the cell, the excess is cropped, aspect kept).
public struct SplitPlacement: Sendable, Hashable {
    public var scale: Double
    /// Offset of the cell center from the frame center, px (the Motion Position convention).
    public var position: Vec2
    /// Fractions 0...1 of the clip's own frame.
    public var crop: CropInsets
}

public enum SplitLayout {
    static let pipWidthFraction = 0.3, pipMarginFraction = 0.04

    /// Cells of `preset`, in clip order (lowest track first). `gap` px of divider is cut out of the touching edges
    /// (the background shows through); ignored for Picture in Picture.
    public static func cells(_ preset: SplitLayoutPreset, canvasWidth w: Double, canvasHeight h: Double,
                             gap: Double = 0) -> [SplitCell] {
        let g = max(gap, 0) / 2
        switch preset {
        case .sideBySide: return columns([0.5, 0.5], w, h, g)
        case .sixtyForty: return columns([0.6, 0.4], w, h, g)
        case .stacked: return rows([0.5, 0.5], w, h, g)
        case .threeStacked: return rows([1.0 / 3, 1.0 / 3, 1.0 / 3], w, h, g)
        case .pictureInPicture:
            let pw = w * pipWidthFraction, ph = h * pipWidthFraction, m = w * pipMarginFraction
            return [SplitCell(x: 0, y: 0, width: w, height: h),
                    SplitCell(x: w - m - pw, y: h - m * h / w - ph, width: pw, height: ph)]
        case .pictureInPictureCircle:
            let side = w * pipWidthFraction, m = w * pipMarginFraction
            return [SplitCell(x: 0, y: 0, width: w, height: h),
                    SplitCell(x: w - m - side, y: h - m - side, width: side, height: side)]
        }
    }

    public static func cells(_ preset: SplitLayoutPreset, canvasWidth w: Int, canvasHeight h: Int, gap: Double = 0) -> [SplitCell] {
        cells(preset, canvasWidth: Double(w), canvasHeight: Double(h), gap: gap)
    }

    private static func columns(_ f: [Double], _ w: Double, _ h: Double, _ g: Double) -> [SplitCell] {
        var x = 0.0
        return f.indices.map { i in
            let cw = (i == f.count - 1) ? w - x : w * f[i]
            defer { x += cw }
            let l = i > 0 ? g : 0, r = i < f.count - 1 ? g : 0
            return SplitCell(x: x + l, y: 0, width: cw - l - r, height: h)
        }
    }

    private static func rows(_ f: [Double], _ w: Double, _ h: Double, _ g: Double) -> [SplitCell] {
        var y = 0.0
        return f.indices.map { i in
            let ch = (i == f.count - 1) ? h - y : h * f[i]
            defer { y += ch }
            let t = i > 0 ? g : 0, b = i < f.count - 1 ? g : 0
            return SplitCell(x: 0, y: y + t, width: w, height: ch - t - b)
        }
    }

    /// Cover fit of a `picture` (upright pixels) into `cell`.
    public static func placement(of cell: SplitCell, picture: (width: Int, height: Int),
                                 canvasWidth w: Double, canvasHeight h: Double) -> SplitPlacement {
        let pw = Double(max(picture.width, 1)), ph = Double(max(picture.height, 1))
        let s = max(cell.width / pw, cell.height / ph)
        let shownW = pw * s, shownH = ph * s
        let cx = (1 - min(cell.width / shownW, 1)) / 2, cy = (1 - min(cell.height / shownH, 1)) / 2
        return SplitPlacement(scale: s,
                              position: Vec2(cell.x + cell.width / 2 - w / 2, cell.y + cell.height / 2 - h / 2),
                              crop: CropInsets(left: cx, top: cy, right: cx, bottom: cy))
    }

    public static func placement(of cell: SplitCell, picture: (width: Int, height: Int),
                                 canvasWidth w: Int, canvasHeight h: Int) -> SplitPlacement {
        placement(of: cell, picture: picture, canvasWidth: Double(w), canvasHeight: Double(h))
    }
}

// MARK: - In / out animation

public enum SplitAnimationStyle: String, Sendable, Hashable, CaseIterable {
    /// The cell slides in from outside the frame (Position keys).
    case slide
    /// The cell is revealed from one edge (Crop keys).
    case wipe
    /// The cell grows from nothing (Scale keys).
    case scale
}

/// Side a cell comes from (slide, wipe). Cells alternate: the second one comes from the opposite side, and so on.
public enum SplitDirection: String, Sendable, Hashable, CaseIterable {
    case left, right, top, bottom
    var opposite: SplitDirection {
        switch self { case .left: .right; case .right: .left; case .top: .bottom; case .bottom: .top }
    }
}

public enum SplitEase: String, Sendable, Hashable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut

    /// Handles of the in segment (leaving the first key, arriving at the second).
    var handles: (out: EaseHandle, in: EaseHandle) {
        switch self {
        case .linear: (.linear, .linear)
        case .easeIn: (EaseHandle(dx: 0.42, dy: 0), EaseHandle(dx: 0, dy: 0))
        case .easeOut: (EaseHandle(dx: 0, dy: 0), EaseHandle(dx: 0.42, dy: 0))
        case .easeInOut: (EaseHandle(dx: 0.42, dy: 0), EaseHandle(dx: 0.42, dy: 0))
        }
    }
}

public struct SplitAnimation: Sendable, Hashable {
    public var style: SplitAnimationStyle
    public var direction: SplitDirection
    public var ease: SplitEase
    /// Length of the in and of the out, clamped to half the clip.
    public var duration: Time
    public var animateIn: Bool
    public var animateOut: Bool
    /// Second, fourth... cell comes from the opposite side.
    public var alternate: Bool

    public init(style: SplitAnimationStyle = .slide, direction: SplitDirection = .left, ease: SplitEase = .easeInOut,
                duration: Time = Time(1, 2), animateIn: Bool = true, animateOut: Bool = true, alternate: Bool = true) {
        self.style = style; self.direction = direction; self.ease = ease; self.duration = duration
        self.animateIn = animateIn; self.animateOut = animateOut; self.alternate = alternate
    }
}

extension Clip {
    /// Writes one cell: static Scale/Position, a Crop effect (reused when present, added when needed), all earlier keys of
    /// those properties removed. Optional in/out keys on top.
    mutating func applySplitPlacement(_ p: SplitPlacement, cellIndex: Int, cell: SplitCell,
                                      canvasWidth w: Double, canvasHeight h: Double,
                                      splitAnimation: SplitAnimation?, frameDuration: Time) {
        let l = p.crop.left * 100, t = p.crop.top * 100, r = p.crop.right * 100, b = p.crop.bottom * 100
        // Cover fit and crop assume an upright picture around its center.
        rotationAndAnchorReset()
        var scale = AnimatedProperty(Vec2(p.scale, p.scale))
        var position = AnimatedProperty(p.position)
        var crops: [String: AnimatedProperty<Double>] = [
            ClipEffect.cropLeftKey: AnimatedProperty(l), ClipEffect.cropTopKey: AnimatedProperty(t),
            ClipEffect.cropRightKey: AnimatedProperty(r), ClipEffect.cropBottomKey: AnimatedProperty(b),
        ]

        let len = duration
        // Whole frames, rounded down, at most half the clip: in and out never overlap and keys stay ordered.
        let d = splitAnimation.map { Self.frames(floor: $0.duration, of: frameDuration, atMost: len) } ?? .zero
        if let a = splitAnimation, d > .zero, a.animateIn || a.animateOut {
            let dir = (a.alternate && cellIndex % 2 == 1) ? a.direction.opposite : a.direction
            func apply<V: KeyframeValue>(_ prop: inout AnimatedProperty<V>, hidden: V) {
                prop.track.keys = SplitKeys.keys(final: prop.value, hidden: hidden, length: len, duration: d, ease: a.ease,
                                                 animateIn: a.animateIn, animateOut: a.animateOut)
            }
            switch a.style {
            case .slide:
                var hidden = p.position
                switch dir {
                case .left: hidden.x = -w / 2 - cell.width / 2
                case .right: hidden.x = w / 2 + cell.width / 2
                case .top: hidden.y = -h / 2 - cell.height / 2
                case .bottom: hidden.y = h / 2 + cell.height / 2
                }
                apply(&position, hidden: hidden)
            case .scale:
                apply(&scale, hidden: Vec2(0, 0))
            case .wipe:
                let (key, hidden): (String, Double) = switch dir {
                case .left: (ClipEffect.cropRightKey, max(100 - l, r))
                case .right: (ClipEffect.cropLeftKey, max(100 - r, l))
                case .top: (ClipEffect.cropBottomKey, max(100 - t, b))
                case .bottom: (ClipEffect.cropTopKey, max(100 - b, t))
                }
                if var prop = crops[key] {
                    apply(&prop, hidden: hidden)
                    crops[key] = prop
                }
            }
        }

        self.animation.scale = scale
        self.animation.position = position
        let hasCrop = crops.values.contains { $0.value != 0 || $0.isAnimated }
        if let i = effects.firstIndex(where: { $0.kind == ClipEffect.cropKind }) {
            effects[i].parameters.merge(crops) { _, new in new }
        } else if hasCrop, let id = addEffect(kind: ClipEffect.cropKind), let i = effects.firstIndex(where: { $0.id == id }) {
            effects[i].parameters.merge(crops) { _, new in new }
        }
    }

    /// Rounded Corners at half the cell side; the radius is layer-local, so it is divided by the clip's scale.
    mutating func setCircleCorners(diameter: Double, scale: Double) {
        let r = diameter / 2 / max(scale, 1e-9)
        if let i = effects.firstIndex(where: { $0.kind == ClipEffect.roundedCornersKind }) {
            effects[i].parameters[ClipEffect.radiusKey] = AnimatedProperty(r)
        } else {
            effects.append(ClipEffect.roundedCorners(radius: r))
        }
    }

    private mutating func rotationAndAnchorReset() {
        animation.rotation = AnimatedProperty(0.0)
        animation.anchor = AnimatedProperty(Vec2.zero)
    }

    private static func frames(floor t: Time, of fd: Time, atMost len: Time) -> Time {
        func count(_ x: Time) -> Int64 {
            guard x > .zero, fd.value > 0 else { return 0 }
            let (n, o1) = x.value.multipliedReportingOverflow(by: fd.timescale)
            let (dn, o2) = x.timescale.multipliedReportingOverflow(by: fd.value)
            return (o1 || o2 || dn == 0) ? 0 : n / dn
        }
        return fd * min(count(t), count(len) / 2)
    }
}

enum SplitKeys {
    /// Hidden -> final over `duration` at the head, final -> hidden at the tail (reverse curve), keys on a shared time merged.
    static func keys<V: KeyframeValue>(final: V, hidden: V, length: Time, duration d: Time, ease: SplitEase,
                                       animateIn: Bool, animateOut: Bool) -> [Keyframe<V>] {
        let h = ease.handles
        let shape: Interpolation = ease == .linear ? .linear : .bezier
        var keys: [Keyframe<V>] = []
        if animateIn {
            keys.append(Keyframe(time: .zero, value: hidden, interpolation: shape, outHandle: h.out))
            keys.append(Keyframe(time: d, value: final, interpolation: shape, inHandle: h.in))
        } else {
            keys.append(Keyframe(time: .zero, value: final))
        }
        if animateOut {
            let from = length - d
            if var last = keys.last, last.time == from {
                last.outHandle = h.in; last.interpolation = shape
                keys[keys.count - 1] = last
            } else {
                keys.append(Keyframe(time: from, value: final, interpolation: shape, outHandle: h.in))
            }
            keys.append(Keyframe(time: length, value: hidden, interpolation: shape, inHandle: h.out))
        } else if keys.count == 1 {
            keys = []
        }
        return keys
    }
}

// MARK: - Project command

extension Project {
    /// Applies `preset` to the video clips in `ids`, ordered by track (lowest track = first cell). Clips beyond the
    /// preset's cell count are left alone; fewer clips than cells throws `.tooFewClips`. Picture size comes from the
    /// media (generators and unknown media count as frame-sized). `animation` writes in/out keys; nil = static layout.
    /// Throws `.trackLocked` / `.timelineNotFound`; nothing changes then. Returns the number of clips changed.
    @discardableResult
    public mutating func applySplitLayout(_ preset: SplitLayoutPreset, to ids: Set<Clip.ID>, in timeline: Timeline.ID,
                                          gap: Double = 0, animation: SplitAnimation? = nil) throws -> Int {
        guard let ti = timelines.firstIndex(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        var work = timelines[ti]
        var targets: [(track: Int, clip: Clip)] = []
        for tr in work.tracks.indices where work.tracks[tr].kind == .video {
            for c in work.tracks[tr].clips where ids.contains(c.id) { targets.append((tr, c)) }
        }
        guard Set(targets.map(\.track)).count == targets.count else { throw SplitLayoutError.sameTrack }
        guard targets.count >= preset.cellCount else { throw SplitLayoutError.tooFewClips(required: preset.cellCount) }
        let w = Double(work.format.displayWidth), h = Double(work.format.height)
        let cells = SplitLayout.cells(preset, canvasWidth: w, canvasHeight: h, gap: gap)
        var changed = 0
        for (i, cell) in cells.enumerated() {
            let (tr, c) = targets[i]
            if work.tracks[tr].isLocked { throw EditError.trackLocked }
            let size = pictureSize(of: c) ?? (work.format.displayWidth, work.format.height)
            let placement = SplitLayout.placement(of: cell, picture: size, canvasWidth: w, canvasHeight: h)
            var n = c
            n.applySplitPlacement(placement, cellIndex: i, cell: cell, canvasWidth: w, canvasHeight: h,
                                  splitAnimation: animation, frameDuration: work.format.frameDuration)
            if preset == .pictureInPictureCircle, i == 1 { n.setCircleCorners(diameter: cell.width, scale: placement.scale) }
            if n != c { work.tracks[tr].replace(n); changed += 1 }
        }
        if changed > 0 { timelines[ti] = work }
        return changed
    }
}
