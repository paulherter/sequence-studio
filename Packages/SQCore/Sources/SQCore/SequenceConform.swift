import Foundation

/// How a picture clip is conformed when its sequence changes frame size (Sequence > Change Format…).
public enum ConformMode: String, Sendable, Codable, CaseIterable {
    /// The whole old frame stays visible inside the new one (bars on one axis).
    case fit
    /// The old frame covers the new one, cropping one axis; the center stays the center.
    case fill

    public var title: String {
        switch self {
        case .fit: "Fit (show everything, bars)"
        case .fill: "Fill (crop to the new frame)"
        }
    }
}

/// Multi-format phase 1: retarget a sequence to a new frame size and conform every clip (design note (a) option 1 in
/// docs/ROADMAP.md). Positions are offsets from the canvas center in sequence pixels (see `ClipTransform`), so a
/// uniform factor on position and scale maps the old frame onto the new one and keeps the subject center.
/// Pure maths, no AVFoundation; the destructive edit is one `Project` mutation (undo = snapshot).
public enum SequenceConform {
    public struct AspectPreset: Sendable, Hashable {
        public let name: String
        public let width: Int
        public let height: Int
    }

    /// The shapes Change Format offers, at 1080 class sizes.
    public static let aspectPresets: [AspectPreset] = [
        AspectPreset(name: "9:16", width: 1080, height: 1920),
        AspectPreset(name: "16:9", width: 1920, height: 1080),
        AspectPreset(name: "4:5", width: 1080, height: 1350),
        AspectPreset(name: "1:1", width: 1080, height: 1080),
        AspectPreset(name: "4:3", width: 1440, height: 1080),
    ]

    /// Title safe inset per side, as a fraction of the frame (Premiere's default title safe area: 80 % of the frame).
    public static let titleSafeInset = 0.1

    /// A text clip's block (the text, or the box of area text) at Scale 100 %, in sequence pixels.
    public struct TextBlock: Sendable, Hashable {
        public var width: Double
        public var height: Double
        /// Ink center minus block center (shadow or stroke make the raster lopsided; see `TextAlignToFrame`). The layer
        /// scales about the raster (ink) center, so the block center moves by `inkOffset * (1 - scale)`.
        public var inkOffset: Vec2
        public init(width: Double, height: Double, inkOffset: Vec2 = .zero) {
            self.width = width; self.height = height; self.inkOffset = inkOffset
        }
    }

    /// Measures a text clip's block; nil = unknown. SQCore cannot lay out text, so the caller (SQText) measures it.
    public typealias TextSize = (Clip) -> TextBlock?

    /// Uniform factor that maps the old frame into the new one: fit = whole old frame visible, fill = new frame covered.
    public static func frameFactor(from old: SequenceFormat, to new: SequenceFormat, mode: ConformMode) -> Double {
        guard old.displayWidth > 0, old.height > 0, new.displayWidth > 0, new.height > 0 else { return 1 }
        let sx = Double(new.displayWidth) / Double(old.displayWidth), sy = Double(new.height) / Double(old.height)
        return mode == .fit ? min(sx, sy) : max(sx, sy)
    }

    /// Half width and half height of the title safe area, in sequence pixels from the center.
    public static func safeHalfExtent(of f: SequenceFormat) -> Vec2 {
        Vec2(Double(f.displayWidth) * (0.5 - titleSafeInset), Double(f.height) * (0.5 - titleSafeInset))
    }

    /// "16:9" when the size has one of the preset shapes, else "W×H".
    public static func aspectLabel(width: Int, height: Int) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = max(gcd(width, height), 1)
        let label = "\(width / g):\(height / g)"
        return aspectPresets.contains { $0.name == label } ? label : "\(width)×\(height)"
    }

    /// A picture clip (media, nested sequence) after its frame was scaled by `k`: Scale and Position, values and keys
    /// (with spatial tangents), are multiplied by `k`. Anchor (layer pixels), rotation and effects stay.
    public static func conformPicture(_ c: Clip, factor k: Double) -> Clip {
        var n = c
        n.animation.position = scaled(c.animation.position, k, k)
        n.animation.scale = scaled(c.animation.scale, k, k)
        return conformGroupStages(n, k, k)
    }

    /// Group Transform effects (an ungrouped Group's Motion, canvas px) on a new frame: Position and Anchor move with the
    /// canvas by (sx, sy); Scale and Rotation stay, since the clip's own Motion already carries the frame scale.
    static func conformGroupStages(_ c: Clip, _ sx: Double, _ sy: Double) -> Clip {
        guard c.effects.contains(where: { $0.kind == ClipEffect.groupTransformKind }) else { return c }
        var n = c
        n.effects = c.effects.map { conformGroupStage($0, sx, sy) }
        return n
    }

    /// One effect on a new frame: a Group Transform's Position and Anchor scale by (sx, sy); anything else is returned as is.
    static func conformGroupStage(_ e: ClipEffect, _ sx: Double, _ sy: Double) -> ClipEffect {
        guard e.kind == ClipEffect.groupTransformKind else { return e }
        var n = e
        for key in [ClipEffect.groupPositionKey, ClipEffect.groupAnchorKey] {
            if let p = e.points[key] { n.points[key] = scaled(p, sx, sy) }
        }
        return n
    }

    /// A text clip on a new frame: Scale is kept (text never grows with a fill), Position moves per axis with the
    /// frame (a lower third stays a lower third). With a known block size the text shrinks to fit the title safe area
    /// and an unanimated position is clamped so the block sits inside it. Animated positions are only scaled (a slide
    /// in from off screen must keep its outside key). Rotation is ignored for the bounds.
    public static func conformText(_ c: Clip, from old: SequenceFormat, to new: SequenceFormat,
                                   blockSize: TextBlock?) -> Clip {
        guard old.displayWidth > 0, old.height > 0 else { return c }
        var n = c
        let sx = Double(new.displayWidth) / Double(old.displayWidth), sy = Double(new.height) / Double(old.height)
        n.animation.position = scaled(c.animation.position, sx, sy)
        n = conformGroupStages(n, sx, sy)
        guard let block = blockSize, block.width > 0, block.height > 0 else { return n }
        let safe = safeHalfExtent(of: new)
        let sc = maxAbsScale(n.animation.scale)
        let bw = block.width * sc.x / 2, bh = block.height * sc.y / 2
        var shrink = 1.0
        if bw > 0 { shrink = min(shrink, safe.x / bw) }
        if bh > 0 { shrink = min(shrink, safe.y / bh) }
        if shrink < 1 { n.animation.scale = scaled(n.animation.scale, shrink, shrink) }
        // TODO: animated position/scale/anchor are not clamped (a slide in must keep its off-screen key); only the static
        // values are used for the block center offset below.
        if !n.animation.position.isAnimated {
            // Screen block center = position + ink * (1 - scale) - anchor * scale (layer scaled about the raster center,
            // anchor lands on the position; see the compositor and `TextAlignToFrame`).
            let s = n.animation.scale.value, a = n.animation.anchor.value
            let off = Vec2(block.inkOffset.x * (1 - s.x) - a.x * s.x, block.inkOffset.y * (1 - s.y) - a.y * s.y)
            let rx = max(0, safe.x - bw * shrink), ry = max(0, safe.y - bh * shrink)
            var p = n.animation.position.value
            p.x = min(max(p.x + off.x, -rx), rx) - off.x
            p.y = min(max(p.y + off.y, -ry), ry) - off.y
            n.animation.position.value = p
        }
        return n
    }

    /// `t` with the new frame size and every video clip conformed. Audio clips, solids and other generators stay.
    /// Frame rate and sample rate come from `format` too (callers usually keep them).
    public static func conformed(_ t: Timeline, to format: SequenceFormat, mode: ConformMode,
                                 overrides: [Clip.ID: ConformMode] = [:], textSize: TextSize = { _ in nil }) -> Timeline {
        var out = t
        let old = t.format
        out.format = format
        // A platform target belongs to an orientation (vertical vs horizontal loudness group); square counts as vertical.
        if (old.displayWidth > old.height) != (format.displayWidth > format.height) { out.deliveryTarget = nil }
        for tr in out.tracks.indices where out.tracks[tr].kind == .video {
            for c in out.tracks[tr].clips {
                let n: Clip
                if let g = c.generator {
                    guard g.kind == GeneratorRef.text else { continue }
                    n = conformText(c, from: old, to: format, blockSize: textSize(c))
                } else {
                    n = conformPicture(c, factor: frameFactor(from: old, to: format, mode: overrides[c.id] ?? mode))
                }
                if n != c { out.tracks[tr].replace(n) }
            }
        }
        return out
    }

    /// Multiplies values, keys and spatial tangents by (sx, sy).
    static func scaled(_ p: AnimatedProperty<Vec2>, _ sx: Double, _ sy: Double) -> AnimatedProperty<Vec2> {
        var q = p
        func m(_ v: Vec2) -> Vec2 { Vec2(v.x * sx, v.y * sy) }
        q.value = m(p.value)
        q.track.keys = p.track.keys.map {
            var k = $0
            k.value = m(k.value); k.inTangent = m(k.inTangent); k.outTangent = m(k.outTangent)
            return k
        }
        return q
    }

    /// Largest scale magnitude per axis the property reaches (its keys when animated, else its value).
    static func maxAbsScale(_ p: AnimatedProperty<Vec2>) -> Vec2 {
        let vs = p.isAnimated ? p.track.keys.map(\.value) : [p.value]
        return Vec2(vs.map { abs($0.x) }.max() ?? 1, vs.map { abs($0.y) }.max() ?? 1)
    }
}

extension Project {
    /// Sequence > Change Format…: sets the frame size (rate and sample rate from `format`) and conforms every video
    /// clip, `mode` for all clips unless `overrides` names one. The delivery target is cleared when the orientation
    /// flips. Locked tracks are conformed too (the frame changes for them as well).
    /// TODO: decide whether locked tracks should be skipped instead. Throws `.invalidFormat` or `.timelineNotFound`; nothing changes then. One mutation = one undo step.
    public mutating func changeFormat(of id: Timeline.ID, to format: SequenceFormat, mode: ConformMode,
                                      overrides: [Clip.ID: ConformMode] = [:],
                                      textSize: SequenceConform.TextSize = { _ in nil }) throws {
        guard format.isValid else { throw EditError.invalidFormat }
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { throw EditError.timelineNotFound }
        var t = SequenceConform.conformed(timelines[i], to: format, mode: mode, overrides: overrides, textSize: textSize)
        t.formatLocked = true
        timelines[i] = t
    }

    /// Sequence > Duplicate as Format…: a conformed copy of the sequence, appended to the project (the original is
    /// untouched). Tracks, clips, link groups, transitions, markers and caption tracks/items get fresh IDs (transitions follow their clips, a
    /// generator's `media` stays its own ID). Default name: "<name> <aspect>", made unique. Returns the new ID.
    @discardableResult
    public mutating func duplicateSequence(_ id: Timeline.ID, as format: SequenceFormat, mode: ConformMode,
                                           overrides: [Clip.ID: ConformMode] = [:], name: String? = nil,
                                           textSize: SequenceConform.TextSize = { _ in nil }) throws -> Timeline.ID {
        guard format.isValid else { throw EditError.invalidFormat }
        guard let src = timeline(id) else { throw EditError.timelineNotFound }
        let conformed = SequenceConform.conformed(src, to: format, mode: mode, overrides: overrides, textSize: textSize)

        var clipIDs: [Clip.ID: Clip.ID] = [:], linkIDs: [UUID: UUID] = [:]
        var copy = conformed
        copy.id = UUID()
        copy.formatLocked = true
        // Fresh variant ids, so the duplicate's variants are its own (active-variant state, export file names); a
        // variant a nested clip's inner sequence also has keeps its id, so that clip still renders the inner variant.
        let innerVariants = Set(conformed.tracks.filter { $0.kind == .video }.flatMap(\.clips).compactMap(\.sequence)
            .compactMap { timeline($0) }.flatMap(\.variants).map(\.id))
        let variantIDs = Dictionary(uniqueKeysWithValues: conformed.variants.map {
            ($0.id, innerVariants.contains($0.id) ? $0.id : UUID())
        })
        copy.variants = conformed.variants.map { var v = $0; v.id = variantIDs[$0.id]!; return v }
        var trackIDs: [Track.ID: Track.ID] = [:]
        copy.tracks = conformed.tracks.map { tr in
            let clips: [Clip] = tr.clips.map { c in
                var n = c
                n.id = UUID()
                clipIDs[c.id] = n.id
                if c.isGenerator { n.media = n.id }
                if !c.variantOverrides.isEmpty {
                    n.variantOverrides = Dictionary(uniqueKeysWithValues: c.variantOverrides.compactMap { k, o in
                        variantIDs[k].map { ($0, o) }
                    })
                }
                if let l = c.link {
                    if linkIDs[l] == nil { linkIDs[l] = UUID() }
                    n.link = linkIDs[l]
                }
                return n
            }
            let transitions: [Transition] = tr.transitions.map { x in
                var y = x
                y.id = UUID()
                y.outgoing = x.outgoing.flatMap { clipIDs[$0] }
                y.incoming = x.incoming.flatMap { clipIDs[$0] }
                return y
            }
            var n = tr                               // keeps every track setting (audioRole, volume, pan, ...)
            n.id = UUID()
            trackIDs[tr.id] = n.id
            var k = 0
            n.mapClipsKeepingTiming { _ in defer { k += 1 }; return clips[k] }
            n.transitions = transitions
            return n
        }

        copy.remapPictureMasks(trackIDs: trackIDs)
        copy.remapSourcePatch(trackIDs: trackIDs)
        copy.remapAttachments(clipIDs)
        copy.markers = conformed.markers.map { var m = $0; m.id = UUID(); return m }
        copy.captionTracks = conformed.captionTracks.map { ct in
            CaptionTrack(id: UUID(), name: ct.name, isLocked: ct.isLocked, syncLock: ct.syncLock, isVisible: ct.isVisible,
                         items: ct.items.map { var i = $0; i.id = UUID(); return i },
                         styleRef: ct.styleRef, animationRef: ct.animationRef, karaoke: ct.karaoke, lookID: ct.lookID)
        }

        let names = Set(timelines.map(\.name))
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? "\(src.name) \(SequenceConform.aspectLabel(width: format.displayWidth, height: format.height))" : trimmed
        var candidate = base, n = 2
        while names.contains(candidate) { candidate = "\(base) \(n)"; n += 1 }
        copy.name = candidate

        timelines.append(copy)
        normalizeBins()
        return copy.id
    }
}
