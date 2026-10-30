#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import SQText

/// Smart guides of the Program monitor (Photoshop / After Effects): while a layer is moved, its edges and center
/// snap to the canvas center and edges and to the edges and centers of the other layers. Everything is in offset
/// space (sequence px from the canvas center, y down).
public enum SnapGuides {
    public struct Targets: Sendable, Equatable {
        public var xs: [Double]
        public var ys: [Double]
        public init(xs: [Double], ys: [Double]) { self.xs = xs; self.ys = ys }
    }

    public struct Result: Sendable, Equatable {
        /// Correction to add to the moved layer's position.
        public var dx: Double, dy: Double
        /// x positions of vertical guide lines / y positions of horizontal ones to draw.
        public var verticalLines: [Double]
        public var horizontalLines: [Double]
        public static let none = Result(dx: 0, dy: 0, verticalLines: [], horizontalLines: [])

        /// Shift axis lock: no correction (and no guide) on a locked axis.
        public func locking(x: Bool, y: Bool) -> Result {
            Result(dx: x ? 0 : dx, dy: y ? 0 : dy, verticalLines: x ? [] : verticalLines, horizontalLines: y ? [] : horizontalLines)
        }
    }

    /// Canvas lines, the edges of the given safe areas, plus min / mid / max of every other layer's bounds.
    public static func targets(canvas: CGSize, others: [CGRect], safeAreas: [SafeArea] = [], zone: CGRect? = nil) -> Targets {
        var xs = [-Double(canvas.width) / 2, 0, Double(canvas.width) / 2]
        var ys = [-Double(canvas.height) / 2, 0, Double(canvas.height) / 2]
        for a in safeAreas {
            let r = a.rect(in: canvas)
            xs += [Double(r.minX), Double(r.maxX)]
            ys += [Double(r.minY), Double(r.maxY)]
        }
        if let z = zone {   // platform UI zone (offset space): content snaps onto its edges
            xs += [Double(z.minX), Double(z.maxX)]
            ys += [Double(z.minY), Double(z.maxY)]
        }
        for r in others where !r.isEmpty {
            xs += [Double(r.minX), Double(r.midX), Double(r.maxX)]
            ys += [Double(r.minY), Double(r.midY), Double(r.maxY)]
        }
        return Targets(xs: xs, ys: ys)
    }

    /// Bounds of the other layers to snap to. A graphics clip's overlay box is its canvas-sized group: at identity it only
    /// repeats the canvas lines, and once moved or scaled its edges are empty space, so it never becomes a snap target.
    public static func otherBounds(_ others: [OverlayTarget]) -> [CGRect] {
        others.filter { !$0.isGraphics }.map { LayerBounds.rect(size: $0.size, transform: $0.displayTransform) }
    }

    /// Snaps the bounds `box` of the moving layer. The nearest (feature, target) pair within `threshold` wins per axis.
    public static func snap(box: CGRect, targets: Targets, threshold: Double) -> Result {
        let (dx, vx) = axis(features: [Double(box.minX), Double(box.midX), Double(box.maxX)], targets: targets.xs, threshold: threshold)
        let (dy, hy) = axis(features: [Double(box.minY), Double(box.midY), Double(box.maxY)], targets: targets.ys, threshold: threshold)
        return Result(dx: dx, dy: dy, verticalLines: vx, horizontalLines: hy)
    }

    /// Snaps a single point (point-parameter handles).
    public static func snap(point: Vec2, targets: Targets, threshold: Double) -> Result {
        snap(box: CGRect(x: point.x, y: point.y, width: 0, height: 0), targets: targets, threshold: threshold)
    }

    private static func axis(features: [Double], targets: [Double], threshold: Double) -> (Double, [Double]) {
        var best: Double?
        for f in features {
            for t in targets {
                let d = t - f
                if abs(d) <= threshold, abs(d) < abs(best ?? .infinity) { best = d }
            }
        }
        guard let d = best else { return (0, []) }
        // Every target that one of the shifted features now sits on gets a guide line.
        var lines: [Double] = []
        for t in targets where features.contains(where: { abs($0 + d - t) < 1e-6 }) && !lines.contains(where: { abs($0 - t) < 1e-6 }) {
            lines.append(t)
        }
        return (d, lines.sorted())
    }
}

/// Title / action safe margins (Premiere: action 90 %, title 80 % of the frame), centered on the canvas.
public enum SafeArea: Sendable, CaseIterable {
    case action, title
    public var fraction: Double { self == .action ? 0.9 : 0.8 }
    /// In offset space (centered on the origin).
    public func rect(in canvas: CGSize) -> CGRect {
        let w = Double(canvas.width) * fraction, h = Double(canvas.height) * fraction
        return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    }
}

/// Bounding box of a layer in offset space, for snapping.
public enum LayerBounds {
    /// `size` = the layer at scale 1 (native px); model as in `TransformOverlayGeometry`:
    /// `offset = position + R(rotation) * S(scale) * (local - anchor)`.
    public static func rect(size: CGSize, transform t: ClipTransform) -> CGRect {
        let hw = Double(size.width) / 2, hh = Double(size.height) / 2
        let a = t.rotation * .pi / 180
        let (c, s) = (cos(a), sin(a))
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for (lx, ly) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)] {
            let dx = (lx - t.anchor.x) * t.scale.x, dy = (ly - t.anchor.y) * t.scale.y
            let x = t.position.x + dx * c - dy * s, y = t.position.y + dx * s + dy * c
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// What the Program monitor's transform overlay manipulates: one picture, text or graphics clip at the playhead.
/// `displayTransform` is what the overlay draws; edits come back through `baseTransform(fromDisplay:)`.
public struct OverlayTarget: Sendable, Equatable {
    public var clip: Clip.ID
    /// The layer at scale 1 in sequence px: native picture size (Premiere semantics, 100 % = source pixels) or the
    /// text raster.
    public var size: CGSize
    public var isText: Bool
    /// Transform as stored in the clip (evaluated at the playhead).
    public var baseTransform: ClipTransform
    /// Text: its raster center relative to the canvas center (the clip's Position is added on top); zero for pictures.
    public var shift: Vec2
    public var positionTrack: KeyframeTrack<Vec2>
    /// Text in/out animation factors at the playhead, folded into the drawn transform like the renderer does.
    public var animScale = 1.0
    public var animRotation = 0.0
    /// A graphics clip: `size` is its canvas-sized group, not visible content.
    public var isGraphics = false
    /// The clip's Group Transform effects at the playhead (an ungrouped Group's Motion, canvas px), in list order. They act after
    /// everything else, so the overlay draws through them and edits come back through their inverse.
    public var groupStages: [ClipTransform] = []

    public init(clip: Clip.ID, size: CGSize, isText: Bool, baseTransform: ClipTransform, shift: Vec2,
                positionTrack: KeyframeTrack<Vec2>, animScale: Double = 1.0, animRotation: Double = 0.0,
                isGraphics: Bool = false, groupStages: [ClipTransform] = []) {
        self.clip = clip; self.size = size; self.isText = isText; self.baseTransform = baseTransform; self.shift = shift
        self.positionTrack = positionTrack; self.animScale = animScale; self.animRotation = animRotation
        self.isGraphics = isGraphics; self.groupStages = groupStages
    }

    public var displayTransform: ClipTransform {
        var t = baseTransform
        t.position = t.position + shift
        t.scale = Vec2(t.scale.x * animScale, t.scale.y * animScale)
        t.rotation += animRotation
        for g in groupStages { t = g.composed(after: t) }
        return t
    }

    /// Stored transform for a transform edited in the overlay (inverse of `displayTransform`).
    public func baseTransform(fromDisplay t: ClipTransform) -> ClipTransform {
        var b = t.removingGroupStages(groupStages)
        b.position = b.position - shift
        let k = abs(animScale) > 1e-9 ? animScale : 1
        b.scale = Vec2(b.scale.x / k, b.scale.y / k)
        b.rotation = b.rotation - animRotation
        return b
    }

    /// nil when the clip is not a picture/text clip or is not under `time`. A picture clip of unknown size is treated
    /// as filling the sequence (legacy aspect-fit). `variant`: the format variant `timeline` shows (a nested clip whose
    /// inner sequence has it is that inner variant's size).
    public static func make(clip: Clip, project: Project, timeline: Timeline, at time: Time,
                            variant: FormatVariant.ID? = nil) -> OverlayTarget? {
        guard clip.kind != .audio, clip.timeline.contains(time) else { return nil }
        let base = clip.transform(at: time)
        let canvas = CGSize(width: timeline.format.displayWidth, height: timeline.format.height)
        if clip.isGraphics {
            // A graphics clip composites its layers inside a canvas-sized group that carries the clip's Motion: the overlay
            // manipulates that group (layer handles are the Graphics overlay's job).
            var target = OverlayTarget(clip: clip.id, size: canvas, isText: false, baseTransform: base, shift: .zero,
                                       positionTrack: clip.animation.position.track)
            target.groupStages = clip.groupStageTransforms(at: time)
            if !target.groupStages.isEmpty { target.positionTrack = KeyframeTrack<Vec2>() }
            target.isGraphics = true
            return target
        }
        if let ref = clip.generator {
            guard ref.kind == GeneratorRef.text, let (template, _) = try? TextGenerator.decode(ref) else { return nil }
            #if os(macOS)
            guard let f = try? TextGenerator.frame(ref: ref, localTime: time - clip.start, clipDuration: clip.source.duration,
                                                   canvas: timeline.format, scale: 1) else {
                // Empty text renders nothing: a small box at the position so the caret has somewhere to sit.
                return OverlayTarget(clip: clip.id, size: CGSize(width: 24, height: template.style.size * 1.2), isText: true,
                                     baseTransform: base, shift: .zero, positionTrack: KeyframeTrack<Vec2>())
            }
            let shift = Vec2(f.x + f.width / 2 - Double(timeline.format.displayWidth) / 2 + f.offsetX,
                             f.y + f.height / 2 - Double(timeline.format.height) / 2 + f.offsetY)
            var target = OverlayTarget(clip: clip.id, size: CGSize(width: f.width, height: f.height), isText: true,
                                       baseTransform: base, shift: shift, positionTrack: KeyframeTrack<Vec2>())
            target.animScale = f.scale; target.animRotation = f.rotation
            target.groupStages = clip.groupStageTransforms(at: time)
            return target   // no motion path for text (keys are not shifted)
            #else
            // The portable layout gives the box the portable raster draws (TextGenerator.portableFrame), without drawing it.
            guard let f = try? TextGenerator.portableBox(ref: ref, localTime: time - clip.start, clipDuration: clip.source.duration,
                                                         canvas: timeline.format) else {
                return OverlayTarget(clip: clip.id, size: CGSize(width: 24, height: template.style.size * 1.2), isText: true,
                                     baseTransform: base, shift: .zero, positionTrack: KeyframeTrack<Vec2>())
            }
            let shift = Vec2(f.x + f.width / 2 - Double(timeline.format.displayWidth) / 2 + f.offsetX,
                             f.y + f.height / 2 - Double(timeline.format.height) / 2 + f.offsetY)
            var target = OverlayTarget(clip: clip.id, size: CGSize(width: f.width, height: f.height), isText: true,
                                       baseTransform: base, shift: shift, positionTrack: KeyframeTrack<Vec2>())
            target.animScale = f.scale; target.animRotation = f.rotation
            target.groupStages = clip.groupStageTransforms(at: time)
            return target
            #endif
        }
        let size = project.pictureSize(of: clip, variant: variant).map { CGSize(width: $0.width, height: $0.height) } ?? canvas
        var target = OverlayTarget(clip: clip.id, size: size, isText: false, baseTransform: base, shift: .zero,
                                   positionTrack: clip.animation.position.track)
        target.groupStages = clip.groupStageTransforms(at: time)
        // The motion path is in Motion's space: with a group stage on top it would not sit on the picture.
        if !target.groupStages.isEmpty { target.positionTrack = KeyframeTrack<Vec2>() }
        return target
    }
}
