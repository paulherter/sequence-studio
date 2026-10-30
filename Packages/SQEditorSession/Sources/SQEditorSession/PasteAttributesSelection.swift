import SQCore

/// What the Paste Attributes dialog lets the user pick: a group of attributes of the copied clip. Anything not picked
/// stays untouched on the target (e.g. only Motion keeps the target's Opacity). Pure logic, no AppKit.
public enum PasteAttributeGroup: String, CaseIterable, Sendable, Hashable {
    case motion, opacity, effects, color, volume

    public var title: String {
        switch self {
        case .motion: "Transform"
        case .opacity: "Opacity"
        case .effects: "Effects"
        case .color: "Color"
        case .volume: "Volume"
        }
    }

    public var kind: TrackKind { self == .volume ? .audio : .video }

    public static func groups(for kind: TrackKind) -> [PasteAttributeGroup] { allCases.filter { $0.kind == kind } }

    /// Groups of `source` that are worth offering (the copied clip actually has something there).
    public static func available(in source: Clip) -> [PasteAttributeGroup] {
        groups(for: source.kind)
    }

    /// Copies this group's fields from `source` onto `target` (same kind assumed). Effects follow the same rule as a full
    /// paste: same-count kinds are replaced one by one, otherwise the copies are added behind.
    public func copy(from source: Clip, into target: inout Clip, pasted: Clip) {
        switch self {
        case .motion:
            target.replaceMotion(with: pasted)   // carries the pending v10 Scale state (H6)
        case .opacity:
            target.opacityEnabled = pasted.opacityEnabled
            target.animation.opacity = pasted.animation.opacity
            target.masks = pasted.masks
            target.blendMode = pasted.blendMode
        case .effects:
            // Source without its Color effects, pasted by the core rules; the target's own grade is put back afterwards,
            // so Effects and Color stay independent.
            var src = source
            src.effects.removeAll { $0.isColor || $0.isColorGraph }
            var p = target.pastingAttributes(from: src)
            p.replaceColorGrade(with: target.colorGradeEffects)
            p.colorGraph = target.colorGraph
            target.effects = p.effects
        case .color:
            guard target.acceptsColor else { break }
            target.footageColor = source.footageColor
            target.replaceColorGrade(with: source.colorGradeEffects)
            target.applyCopiedGraph(source.colorGraph)
        case .volume:
            target.animation.volume = pasted.animation.volume
            target.audioGainDB = pasted.audioGainDB
        }
    }
}

extension Clip {
    /// Paste Attributes limited to `groups`. Same kind only; other attributes stay as they are.
    /// `scaleTimes` (Premiere's "Scale Attribute Times"): the copied key times are stretched by target / source length first.
    public func pastingAttributes(from source: Clip, groups: Set<PasteAttributeGroup>, scaleTimes: Bool = false) -> Clip {
        guard source.kind == kind else { return self }
        let source = scaleTimes ? source.keyTimesScaled(toDuration: duration) : source
        let full = pastingAttributes(from: source)
        var out = self
        for g in groups where g.kind == kind { g.copy(from: source, into: &out, pasted: full) }
        return out
    }
}

extension Timeline {
    /// Paste Attributes onto `ids`, only `groups`. Returns how many clips changed (throws when none did).
    @discardableResult
    /// `sourceLane` / `pictureLanes` (from the clipboard): Picture masks keep their lane offset when their track is not here.
    public mutating func pasteAttributes(from source: Clip, to ids: [Clip.ID], groups: Set<PasteAttributeGroup>, scaleTimes: Bool = false,
                                         sourceLane: Int? = nil, pictureLanes: [Track.ID: Int] = [:]) throws -> Int {
        var work = self
        var changed = 0
        for id in ids where id != source.id {
            guard let c = work.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), c.kind == source.kind else { continue }
            let out = work.remappingPictureTracks(of: c.pastingAttributes(from: source, groups: groups, scaleTimes: scaleTimes),
                                                  sourceLane: sourceLane, pictureLanes: pictureLanes)
            guard out != c else { continue }
            try work.replaceClip(out)
            changed += 1
        }
        guard changed > 0 else { throw EditError.emptyClip }
        self = work
        return changed
    }
}
