import Foundation

/// Fit with Blurred Fill and Card (explicit, per clip, never automatic): the picture sits whole inside the frame and a
/// blurred, enlarged, darkened copy of it fills the bars. Built only from things the model already has (a second clip on a
/// new video track below, Gaussian Blur, Opacity, Rounded Corners, Drop Shadow), so no file format change: the pair is
/// recognized by the shared link and the copy's name suffix, and removed again by `removeBlurredFill`.
public enum BlurredFillStyle: Sendable, Hashable {
    /// Whole picture, blurred copy behind it.
    case fit
    /// Picture at 85 %, rounded corners and a drop shadow over the blurred copy (for screenshots and cards).
    case card

    var suffix: String { self == .fit ? BlurredFill.fitSuffix : BlurredFill.cardSuffix }
}

public struct BlurredFillOptions: Sendable, Hashable {
    /// Blurriness of the background's Gaussian Blur (Premiere units; 115 = sigma ~40 px of its own frame).
    public var blur: Double
    /// 0...1: how much the background is darkened (its Opacity becomes 1 - dim over black).
    public var dim: Double
    public init(blur: Double = 115, dim: Double = 0.35) { self.blur = blur; self.dim = dim }
}

public enum BlurredFillError: Error, Equatable {
    /// The picture already has the sequence's aspect (Fit only): there is nothing to fill.
    case aspectMatches
    /// A generator or media without size information.
    case unknownSize
}

public enum BlurredFill {
    public static let fitSuffix = " (Blur Fill)"
    public static let cardSuffix = " (Card)"
    /// Card: picture size relative to the frame fit, corner radius, shadow.
    public static let cardScale = 0.85
    public static let cardRadius = 32.0
    /// The background is enlarged past the cover size so the blur's soft edge falls outside the frame.
    static let bleed = 1.12

    /// The explicit marker of a pair, with no file format change: the identities of the copy and of Card's two effects are
    /// derived from the picture clip's id (a fixed byte-wise addition), so they survive renames, trims, moves and an
    /// unlinked pair. A user clip or effect can never have such an id by accident. A pasted or duplicated picture gets a new
    /// id and therefore starts without a pair. Trade-off: the copy is deliberately NOT linked to the picture (a link would
    /// make deleting the copy delete the picture and its audio), so moving the picture does not move the copy; applying
    /// the look again re-places the copy under the picture.
    enum Role: UInt8 { case copy = 0x5B, round = 0x2D, shadow = 0x71 }
    static func derivedID(_ id: UUID, _ role: Role) -> UUID {
        var b = withUnsafeBytes(of: id.uuid) { Array($0) }
        // Addition, not XOR: derived(derived(x)) must differ from x.
        for i in b.indices { b[i] = b[i] &+ role.rawValue &+ UInt8(truncatingIfNeeded: i &* 29) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// True when the picture's aspect equals the frame's within 1 %.
    public static func matchesAspect(picture: (width: Int, height: Int), frame: SequenceFormat) -> Bool {
        guard picture.width > 0, picture.height > 0, frame.width > 0, frame.height > 0 else { return true }
        let a = Double(picture.width) / Double(picture.height), b = Double(frame.width) / Double(frame.height)
        return abs(a - b) / b < 0.01
    }
}

extension Timeline {
    /// The pair `id` belongs to: `id` may be the picture or its blurred copy. `background` is nil when the copy was deleted
    /// on its own while Card's effects are still on the picture.
    public func blurredFillPair(of id: Clip.ID) -> (picture: Clip, background: Clip?, style: BlurredFillStyle)? {
        let all = tracks.flatMap(\.clips)
        guard let x = all.first(where: { $0.id == id }) else { return nil }
        let pic = all.first(where: { $0.kind == .video && BlurredFill.derivedID($0.id, .copy) == id }) ?? x
        let bg = all.first { $0.id == BlurredFill.derivedID(pic.id, .copy) }
        let isCard = pic.effects.contains { $0.id == BlurredFill.derivedID(pic.id, .round) }
        if isCard { return (pic, bg, .card) }
        return bg.map { (pic, $0, .fit) }
    }

    /// The picture clip a command should act on: the clip itself, or the picture when `id` is the blurred copy.
    public func blurredFillPicture(of id: Clip.ID) -> Clip.ID {
        blurredFillPair(of: id)?.picture.id ?? id
    }

    /// Fit with Blurred Fill / Card on a video clip whose picture is `picture` px (upright). `id` may also be the blurred
    /// copy of an earlier application (the picture is used). A new video track is inserted directly below the picture's
    /// track and receives the blurred copy (same media, range, speed and color effects, not linked, see `BlurredFill.Role`).
    /// The picture gets the frame-fit scale (Card: 85 % of it). Applying again replaces the previous look. Throws
    /// `.trackLocked`, `.clipNotFound`, `.wrongTrackKind` (audio), and `BlurredFillError.aspectMatches` (Fit only); nothing
    /// changes then.
    public mutating func applyBlurredFill(_ clip: Clip.ID, picture: (width: Int, height: Int), style: BlurredFillStyle,
                                         options: BlurredFillOptions = BlurredFillOptions()) throws {
        guard picture.width > 0, picture.height > 0 else { throw BlurredFillError.unknownSize }
        var work = self
        let id = work.blurredFillPicture(of: clip)
        if work.blurredFillPair(of: id) != nil { try work.removeBlurredFill(id) }
        guard let m = work.find(id) else { throw EditError.clipNotFound }
        guard m.clip.kind == .video, !m.clip.isGenerator else { throw EditError.wrongTrackKind }
        guard !work.tracks[m.track].isLocked else { throw EditError.trackLocked }
        if style == .fit, BlurredFill.matchesAspect(picture: picture, frame: format) { throw BlurredFillError.aspectMatches }

        let fit = format.fitScale(width: picture.width, height: picture.height)
        let cover = max(Double(format.displayWidth) / Double(picture.width), Double(format.height) / Double(picture.height))

        var pic = m.clip
        let s = style == .card ? fit * BlurredFill.cardScale : fit
        pic.animation.scale = AnimatedProperty(Vec2(s, s))
        if style == .card {
            var round = ClipEffect.roundedCorners(radius: BlurredFill.cardRadius)
            round.id = BlurredFill.derivedID(pic.id, .round)
            pic.effects.append(round)
            if var shadow = ClipEffect.make(kind: ClipEffect.dropShadowKind) {
                shadow.id = BlurredFill.derivedID(pic.id, .shadow)
                shadow.parameters[ClipEffect.shadowOpacityKey] = AnimatedProperty(60)
                shadow.parameters[ClipEffect.shadowDirectionKey] = AnimatedProperty(180)
                shadow.parameters[ClipEffect.shadowDistanceKey] = AnimatedProperty(24)
                shadow.parameters[ClipEffect.shadowSoftnessKey] = AnimatedProperty(48)
                pic.effects.append(shadow)
            }
        }

        var bg = m.clip
        bg.id = BlurredFill.derivedID(pic.id, .copy)
        bg.link = nil
        bg.name = m.clip.name + style.suffix
        bg.animation = ClipAnimation()
        bg.masks = []                 // the blurred backdrop fills the frame: no masks, no baked presets of the picture
        bg.bakedEffects = []
        let bs = cover * BlurredFill.bleed
        bg.animation.scale = AnimatedProperty(Vec2(bs, bs))
        bg.animation.opacity = AnimatedProperty(min(max(1 - options.dim, 0), 1))
        bg.effects = m.clip.effects.filter(\.isColor).map { $0.copy() }
        if var blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind) {
            blur.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(max(options.blur, 0))
            bg.effects.append(blur)
        }
        bg.blendMode = .normal
        bg.audioFades = FadeMarks()
        bg.duckKeyIDs = []

        work.tracks[m.track].replace(pic)
        var below = Track(kind: .video, name: "")
        try below.overwrite(bg)
        work.tracks.insert(below, at: m.track)
        self = work
    }

    /// Takes the look away: deletes the blurred copy (and its track when that is now empty), drops exactly the Rounded
    /// Corners and Drop Shadow effects Card added (the user's own stay) and undoes Card's 85 % scale (Fit keeps its
    /// frame-fit scale). `id` may be either clip of the pair. No-op (no throw) when `id` is not part of a pair.
    public mutating func removeBlurredFill(_ id: Clip.ID) throws {
        guard let pair = blurredFillPair(of: id) else { return }
        var work = self
        if let bgClip = pair.background {
            guard let bi = work.tracks.firstIndex(where: { $0.clip(bgClip.id) != nil }) else { throw EditError.clipNotFound }
            guard !work.tracks[bi].isLocked else { throw EditError.trackLocked }
            work.tracks[bi].remove(bgClip.id)
            if work.tracks[bi].clips.isEmpty, work.tracks[bi].transitions.isEmpty {
                let gone = work.tracks.remove(at: bi).id
                work.clearPictureMasks(readingTrack: gone)
            }
        }
        var pic = pair.picture
        if pair.style == .card {
            let ours: Set<UUID> = [BlurredFill.derivedID(pic.id, .round), BlurredFill.derivedID(pic.id, .shadow)]
            pic.effects.removeAll { ours.contains($0.id) }
            if !pic.animation.scale.isAnimated {
                let v = pic.animation.scale.value
                pic.animation.scale = AnimatedProperty(Vec2(v.x / BlurredFill.cardScale, v.y / BlurredFill.cardScale))
            }
        }
        guard let pi = work.tracks.firstIndex(where: { $0.clip(pic.id) != nil }) else { throw EditError.clipNotFound }
        guard !work.tracks[pi].isLocked else { throw EditError.trackLocked }
        work.tracks[pi].replace(pic)
        self = work
    }
}
