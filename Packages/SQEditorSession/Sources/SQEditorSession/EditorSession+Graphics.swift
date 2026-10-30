import Foundation
import SQCore

/// GFX graphics clips (design layer): one clip, many layers. Layer edits go through `GraphicsEditor`.
extension EditorSession {
    /// Places an empty graphics clip at `time` (default: playhead) on `track`, else on the topmost unlocked video track
    /// that is free there. One undo step; selects the new clip. Returns its ID; a refusal goes to `lastError`.
    /// `neverOverwrite` (Create tools): when no unlocked video track is free over the range, a new video track goes on
    /// top in the same undo step instead of overwriting what is there.
    @discardableResult
    public func addGraphicsClip(at time: Time? = nil, track: Track.ID? = nil, duration: Time = Time(5, 1),
                                layers: [GraphicsLayer] = [], neverOverwrite: Bool = false) -> Clip.ID? {
        guard let t = activeTimeline, let tl = activeTimelineID else { setError("Open a sequence first."); return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        let duration = max(duration.snapped(to: t.frameDuration), t.frameDuration)
        let freeTrack = Self.generatorTrack(in: t, for: TimeRange(start: start, duration: duration), preferred: track,
                                            allowOverwrite: !neverOverwrite)
        let newTrack = freeTrack == nil && neverOverwrite && track == nil ? Track(kind: .video) : nil
        guard let chosen = freeTrack ?? newTrack?.id else {
            setError("There is no video track for the graphic."); return nil
        }
        var newID: Clip.ID?
        do {
            try perform("Add Graphic") { p in
                if let newTrack { try p.edit(tl) { $0.tracks.append(newTrack) } }
                newID = try p.addGraphicsClip(in: tl, at: start, track: chosen, duration: duration, layers: layers)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }

    /// Edits the layers of graphics clip `id` as one undo step (`coalescing`: consecutive edits with the same key merge).
    /// Returns whether it was applied; a refusal (locked track) goes to `lastError`.
    @discardableResult
    public func editGraphics(_ id: Clip.ID, name: String, coalescing key: String? = nil,
                             _ body: (inout GraphicsDocument) -> Void) -> Bool {
        let before = history.current
        do { try perform(name, coalescing: key) { try $0.editGraphics(clipID: id, body) } }
        catch { setError(Self.message(for: error)); return false }
        return history.current != before
    }

    /// Make Graphic: turns the selected text or shape clip into a graphics clip (one undo step). The clip stays selected.
    @discardableResult
    public func makeGraphic() -> Bool {
        guard selection.count == 1, let id = selection.first, project.canConvertToGraphics(clipID: id) else { return false }
        do { try perform("Make Graphic") { _ = try $0.convertToGraphics(clipID: id) } }
        catch { setError(Self.message(for: error)); return false }
        return true
    }

    /// CREATOR 7: places a built-in sticker or lower third (`GraphicPresetCatalog`) as a Graphics clip, one undo step.
    @discardableResult
    public func addGraphicPreset(_ id: String, at time: Time? = nil, track: Track.ID? = nil) -> Clip.ID? {
        guard let entry = GraphicPresetCatalog.entry(id: id) else { setError("That graphic is not available."); return nil }
        guard let t = activeTimeline else { setError("Open a sequence first."); return nil }
        do {
            let layers = try entry.layers(canvasWidth: t.format.displayWidth, canvasHeight: t.format.height)
            return addGraphicsClip(at: time, track: track, duration: entry.duration, layers: layers)
        } catch { setError(Self.message(for: error)); return nil }
    }

    /// H1: places the built-in CTA end card (pill, bell, "FOLGEN" -> "GEFOLGT" with a press animation) as a Graphics clip.
    @discardableResult
    public func addCTAEndCard(at time: Time? = nil, track: Track.ID? = nil) -> Clip.ID? {
        guard let t = activeTimeline else { setError("Open a sequence first."); return nil }
        do {
            let layers = try CTAEndCard.layers(canvasWidth: t.format.displayWidth, canvasHeight: t.format.height)
            return addGraphicsClip(at: time, track: track, duration: CTAEndCard.duration, layers: layers)
        } catch { setError(Self.message(for: error)); return nil }
    }
}
