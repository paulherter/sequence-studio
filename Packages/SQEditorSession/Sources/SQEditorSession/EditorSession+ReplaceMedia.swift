import SQCore

extension EditorSession {
    /// Replace edit (Option-drop of a Project item onto a clip): the clip keeps position, length, effects and keys and plays
    /// the dropped media. The new media starts at its In mark (or its start); with `matchSourceTime` (Shift+Option) the frame
    /// the Source monitor shows lines up with the sequence playhead instead. One undo step; false = refused (reported).
    @discardableResult
    public func replaceMedia(of clipID: Clip.ID, with mediaID: MediaRef.ID, matchSourceTime: Time? = nil) -> Bool {
        guard let ref = project.media(mediaID) else { setError("That item is not in the project."); return false }
        let still = ref.info?.isStill == true
        guard let total = ref.info?.duration ?? ref.duration else { setError("That item has no known length yet."); return false }
        let media = ReplacementMedia(id: ref.id, name: ref.name, duration: total, hasVideo: ref.info?.video != nil || ref.info == nil,
                                     hasAudio: ref.info?.audio != nil, isStill: still)
        let alignment: ReplaceAlignment
        if let t = matchSourceTime { alignment = .matchFrame(mediaTime: t, timelineTime: playhead) }
        else { alignment = .clipStart(sourceIn: Timeline.sourceEditRange(marks: project.sourceMarks(for: ref.id), total: total)?.start ?? .zero) }
        return attempt("Replace Clip") { tl in try tl.replaceMedia(of: clipID, with: media, alignment: alignment) }
    }

    /// Replace edit with several selected items: Premiere uses the first one; we also say so in the status line instead of
    /// dropping the rest silently. Empty = refused.
    @discardableResult
    public func replaceMedia(of clipID: Clip.ID, withFirstOf ids: [MediaRef.ID], matchSourceTime: Time? = nil) -> Bool {
        guard let first = ids.first else { return false }
        guard replaceMedia(of: clipID, with: first, matchSourceTime: matchSourceTime) else { return false }
        if ids.count > 1 { setError("Replaced with the first of \(ids.count) items.") }
        return true
    }

    /// Replace edit with a sequence (Option-drop of a sequence): the clip plays it as a nested clip from its start, keeping
    /// position, length and effects. One undo step; false = refused (reported).
    @discardableResult
    public func replaceWithSequence(of clipID: Clip.ID, with sequence: Timeline.ID) -> Bool {
        guard let host = activeTimelineID else { return false }
        do {
            try perform("Replace Clip") { try $0.replaceWithSequence(of: clipID, with: sequence, in: host) }
            return true
        } catch {
            setError(error as? EditError == .insufficientMedia ? "That sequence is shorter than the clip it replaces."
                     : error as? EditError == .emptyClip ? "That sequence is empty." : Self.message(for: error))
            return false
        }
    }

    /// True when a four-mark Source edit needs the Fit Clip choice: both Source marks, both sequence marks, and the two
    /// ranges differ in length (equal lengths fit exactly whatever is ignored).
    public func fourPointNeedsChoice(media id: MediaRef.ID, marks: SourceMarks? = nil) -> Bool {
        guard let t = activeTimeline, let src = (marks ?? project.sourceMarks(for: id)).range else { return false }
        let sm = t.explicitMarks
        guard let i = sm.markIn, let o = sm.markOut, o > i else { return false }
        return (o - i) != src.duration
    }
}
