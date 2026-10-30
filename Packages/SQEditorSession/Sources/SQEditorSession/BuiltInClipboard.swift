import SQCore

/// A built-in effect of a clip (Transform, Blend, Volume) copied as a whole: the group and the clip it came from, so the
/// values and keyframes can be put onto other clips. Speed is not copied (it changes the clip length).
public struct BuiltInClipboard: Sendable, Equatable {
    public var group: PasteAttributeGroup
    public var clip: Clip

    public init(group: PasteAttributeGroup, clip: Clip) {
        self.group = group
        self.clip = clip
    }

    /// The group a built-in section stands for; nil for Speed, applied effects, masks and animations.
    public static func group(for section: EffectSection) -> PasteAttributeGroup? {
        switch section {
        case .motion: .motion
        case .opacity: .opacity
        case .volume: .volume
        default: nil
        }
    }
}

extension EditorSession {
    /// Copies the built-in effect `section` of `clip` (Effect Controls Cmd+C on its header). False for sections that
    /// cannot be copied as a whole.
    @discardableResult
    public func copyBuiltIn(_ section: EffectSection, of clip: Clip) -> Bool {
        guard let g = BuiltInClipboard.group(for: section), g.kind == clip.kind else { return false }
        builtInClipboard = BuiltInClipboard(group: g, clip: clip)
        effectClipboard = nil
        return true
    }

    /// Selected clips that can take the copied built-in effect.
    func builtInTargets(_ b: BuiltInClipboard) -> [Clip.ID] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && $0.kind == b.group.kind }.map(\.id)
    }

    /// Cmd+V / Paste Attributes with a built-in effect copied: its values and keyframes replace the same group on every
    /// selected clip of the same kind (one undo step).
    func pasteBuiltIn(_ b: BuiltInClipboard, groups: Set<PasteAttributeGroup>, scaleTimes: Bool) -> Bool {
        guard groups.contains(b.group) else { return false }
        let ids = builtInTargets(b)
        guard !ids.isEmpty else { return false }
        return attempt("Paste \(b.group.title)") { t in
            var n = 0
            for id in ids {
                guard let c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                let out = c.pastingAttributes(from: b.clip, groups: [b.group], scaleTimes: scaleTimes)
                guard out != c else { continue }
                try t.replaceClip(out)
                n += 1
            }
            if n == 0 { throw EditError.emptyClip }
        }
    }
}
