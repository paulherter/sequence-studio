import Foundation
import SQCore
import SQText

/// Title templates in the editor (TEMPLATE-ECOSYSTEM T3, DECISIONS 2026-10-06): Save as Template from the selected video
/// layers, placing a saved template as one nested clip, editing its slots, and the clip's animation zones. The model
/// lives in SQCore (`TitleTemplate`, `AnimationZones`); this file is the session glue plus what SQCore cannot know: the
/// in/out animation lengths of text layers (SQText payload).
extension EditorSession {
    /// True when the selection holds at least one video-track clip (text, shape, graphic or footage).
    public var canSaveSelectionAsTemplate: Bool {
        guard let t = activeTimeline else { return false }
        return t.tracks.contains { $0.kind == .video && $0.clips.contains { selection.contains($0.id) } }
    }

    /// Selected video-track clips that can carry animation zones.
    public var selectedZoneClips: [Clip] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.filter { $0.kind == .video }.flatMap { $0.clips.filter { selection.contains($0.id) } }
    }

    /// True when the playhead lies inside a selected video clip (a monitor frame then shows the title).
    public var playheadIsInsideSelectedVideo: Bool {
        selectedZoneClips.contains { $0.timeline.start <= playhead && playhead < $0.timeline.end }
    }

    /// The selection as a template named `name`; nil with a fresh `lastError` when nothing usable is selected. The
    /// first text layer also gets Color, Font and Size slots (the text slots are made by `TitleTemplate.capture`).
    public func titleTemplateFromSelection(name: String) -> TitleTemplate? {
        guard let tlID = activeTimelineID, let t = activeTimeline, canSaveSelectionAsTemplate else {
            setError("Select the title layers first."); return nil
        }
        let videoIDs = t.tracks.filter { $0.kind == .video }.flatMap { $0.clips.filter { selection.contains($0.id) }.map(\.id) }
        let picked = t.tracks.flatMap(\.clips).filter { videoIDs.contains($0.id) }
        let shift = picked.map(\.start).min() ?? .zero
        do {
            var template = try TitleTemplate.capture(clips: videoIDs, in: tlID, of: project, name: name,
                                                     extraKeyTimes: Self.textAnimationKeyTimes(of: picked, shift: shift))
            if let first = template.slots.first(where: { $0.kind == .text }) {
                let layer = first.layer, gl = first.graphicsLayer
                template.slots += [
                    TemplateSlot(name: "Color", kind: .color, layer: layer, graphicsLayer: gl, path: "template.style.color",
                                 value: Self.styleValue(of: template, layer: layer, graphicsLayer: gl) { s in .color(red: s.color.red, green: s.color.green, blue: s.color.blue, alpha: s.color.alpha) }
                                    ?? .color(red: 1, green: 1, blue: 1, alpha: 1)),
                    TemplateSlot(name: "Font", kind: .font, layer: layer, graphicsLayer: gl, path: "template.style.fontName",
                                 value: Self.styleValue(of: template, layer: layer, graphicsLayer: gl) { .font($0.fontName) } ?? .font(TextStyle.defaultFontName)),
                    TemplateSlot(name: "Size", kind: .number, layer: layer, graphicsLayer: gl, path: "template.style.size",
                                 value: Self.styleValue(of: template, layer: layer, graphicsLayer: gl) { .number($0.size) } ?? .number(48)),
                ]
            }
            return template
        } catch {
            setError(Self.message(for: error)); return nil
        }
    }

    private static func styleValue(of template: TitleTemplate, layer: Clip.ID, graphicsLayer: UUID? = nil,
                                    _ make: (TextStyle) -> SlotValue) -> SlotValue? {
        guard let clip = template.content.tracks.lazy.flatMap(\.clips).first(where: { $0.id == layer }) else { return nil }
        var ref = clip.generator
        if let graphicsLayer {
            guard case let .text(r)? = clip.graphics?.layer(graphicsLayer)?.content else { return nil }
            ref = r
        }
        guard let ref, let (t, _) = try? TextGenerator.decode(ref) else { return nil }
        return make(t.style)
    }

    /// End of every text layer's in animation and start of its out animation, in the time of a template that starts at
    /// `shift` (zones need keys where SQCore sees none: the text animation lives in the payload).
    static func textAnimationKeyTimes(of clips: [Clip], shift: Time) -> [Time] {
        var times: [Time] = []
        for c in clips {
            var refs: [GeneratorRef] = []
            if let g = c.generator, g.kind == GeneratorRef.text { refs.append(g) }
            for l in c.graphics?.layers ?? [] { if case let .text(r) = l.content { refs.append(r) } }
            let base = c.start - shift
            for g in refs {
                guard let (_, set) = try? TextGenerator.decode(g), let set else { continue }
                if let i = set.animationIn, i.duration > .zero { times.append(base + i.duration) }
                if let o = set.outStart(clipDuration: c.duration) { times.append(base + o) }
            }
        }
        return times
    }

    /// Places `template` at `time` (default the playhead) on a free video track above whatever plays there, as one undo
    /// step, and selects the new clip. nil with `lastError` when refused.
    @discardableResult
    public func insertTitleTemplate(_ template: TitleTemplate, at time: Time? = nil) -> Clip.ID? {
        guard let tlID = activeTimelineID, let t = activeTimeline else { setError("Open a sequence first."); return nil }
        let fd = t.frameDuration
        let start = (time ?? playhead).snapped(to: fd)
        let range = TimeRange(start: start, duration: max(template.duration.snapped(to: fd), fd))
        var placed: Clip.ID?
        do {
            try perform("Insert Title Template") { p in
                var track: Track.ID?
                try p.edit(tlID) { track = $0.stackedTitleTracks(count: 1, over: range).first }
                guard let track else { throw EditError.clipNotFound }
                placed = try p.applyTitleTemplate(template, in: tlID, track: track, at: start)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let placed { select(clips: [placed]) }
        return placed
    }

    /// Changes one slot of an applied template clip. `continuesGesture` merges a drag or typing into one undo step.
    public func setTemplateSlot(_ slot: TemplateSlot.ID, to value: SlotValue, clip id: Clip.ID, continuesGesture: Bool) {
        if !continuesGesture { gestureCounter += 1 }
        do {
            try perform("Edit Template", coalescing: "templateSlot:\(id):\(slot):\(gestureCounter)") {
                try $0.setTemplateSlot(slot, to: value, clip: id)
            }
        } catch { setError(Self.message(for: error)) }
    }

    /// Turns a clip's animation zones on (auto-detected) or off. Returns whether it was applied (`lastError` says why not).
    /// An applied template clip is detected from its inner sequence and keeps its design length.
    @discardableResult
    public func setZonesEnabled(_ on: Bool, clip id: Clip.ID) -> Bool {
        guard let clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return false }
        do {
            try perform(on ? "Turn Zones On" : "Turn Zones Off") { p in
                guard on else { try p.setAnimationZones(nil, clip: id); return }
                if clip.templateSlots != nil, let seq = clip.sequence.flatMap({ p.timeline($0) }) {
                    let extra = Self.textAnimationKeyTimes(of: seq.tracks.filter { $0.kind == .video }.flatMap(\.clips), shift: .zero)
                    var z = TitleTemplate.detectZones(in: seq, extraKeyTimes: extra)
                    if let old = clip.zones { z.middle = old.middle }
                    try p.setAnimationZones(z, clip: id)
                } else {
                    try p.autoDetectAnimationZones(clip: id)
                }
            }
            return true
        } catch TitleTemplateError.noKeyframes {
            setError("This clip has no keyframes, so there is no intro or outro to keep.")
            return false
        } catch { setError(Self.message(for: error)); return false }
    }

    /// What the middle of a clip with zones does when the clip gets longer or shorter.
    public func setZoneMiddle(_ middle: AnimationZones.Middle, clip id: Clip.ID) {
        guard var z = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.zones else { return }
        z.middle = middle
        do { try perform("Set Zone Middle") { try $0.setAnimationZones(z, clip: id) } } catch { setError(Self.message(for: error)) }
    }
}
