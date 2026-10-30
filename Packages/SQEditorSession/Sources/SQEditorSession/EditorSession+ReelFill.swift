import SQCore

extension EditorSession {
    /// Slots of the active sequence's reel (base video track clips in time order).
    public var reelSlotCount: Int { activeTimeline?.reelSlots.count ?? 0 }

    /// Reel to fillable template (PALMIER-PRS #576): the active sequence is the template. Its base-track clips are slots;
    /// `mediaIDs` pour into them in order, each from its first frame, keeping the slot's position, length, effects,
    /// keys and transitions. With `intoCopy` the template stays untouched and a new sequence "<name> Fill" holds the
    /// result and becomes active. One undo step. Nil = refused (reported); otherwise what was filled.
    @discardableResult
    public func fillReel(with mediaIDs: [MediaRef.ID], intoCopy: Bool = true) -> ReelFillReport? {
        guard let src = activeTimeline else { return nil }
        guard !src.reelSlots.isEmpty else { setError("This sequence has no clips to use as slots."); return nil }
        var media: [ReplacementMedia] = []
        for id in mediaIDs {
            guard let ref = project.media(id) else { setError("An item has no known length yet."); return nil }
            let isStill = ref.info?.isStill == true
            // A still has no length of its own: it takes the slot's.
            guard let total = isStill ? (ref.info?.duration ?? ref.duration ?? .zero) : (ref.info?.duration ?? ref.duration) else {
                setError("An item has no known length yet."); return nil
            }
            media.append(ReplacementMedia(id: ref.id, name: ref.name, duration: total,
                                          hasVideo: ref.info?.video != nil || ref.info == nil, hasAudio: ref.info?.audio != nil,
                                          isStill: isStill))
        }
        var work = src
        if intoCopy {
            work = src.copyWithFreshIDs(name: ProjectTemplate.freeName("\(src.name) Fill", taken: project.timelines.map(\.name)))
        }
        let report = work.fillReel(slots: work.reelSlots, with: media)
        guard !report.filled.isEmpty else { setError("No slot could take that media."); return nil }
        let result = work
        if intoCopy {
            perform("Fill Reel") { p in
                p.timelines.append(result)
                p.normalizeBins()
            }
            setActiveTimeline(result.id)
        } else {
            guard attempt("Fill Reel", { tl in tl = result }) else { return nil }
        }
        return report
    }
}
