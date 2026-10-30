import Foundation

// Lane drag-out (Graphic layer system): layers leave their Graphic and land in another Graphic or on a new Graphic on
// another track. Layer ranges and keys are clip-local, so they travel through absolute timeline time: `extractLayers`
// hands them out in absolute time, `insertLayers` puts them back into the local time of the receiving clip.

/// A layer on its way between two Graphics: `span` is the part of the timeline it shows in, and its keys are absolute too.
public struct ExtractedLayer: Sendable, Equatable {
    public var layer: GraphicsLayer
    public var span: TimeRange
}

extension GraphicsDocument {
    /// Removes the layers `ids` (bottom first in the result) and returns them in absolute time. A layer leaves its group
    /// and unpins a Follow whose target does not travel with it; layers that followed a removed one are unpinned.
    public mutating func extractLayers(_ ids: some Sequence<UUID>, clipStart: Time, clipDuration: Time) -> [ExtractedLayer] {
        let set = Set(ids)
        let out = extractedCopies(set, clipStart: clipStart, clipDuration: clipDuration)
        remove(set)
        return out
    }

    /// The same as `extractLayers`, the layers stay (copy).
    public func extractedCopies(_ ids: some Sequence<UUID>, clipStart: Time, clipDuration: Time) -> [ExtractedLayer] {
        let set = Set(ids)
        return layers.filter { set.contains($0.id) }.map { l in
            var m = l
            let local = shownRange(of: l, clipDuration: clipDuration)
            m.group = nil
            m.range = nil
            if case .layer(let t)? = m.follow?.target, !set.contains(t) { m.follow = nil }
            m.shiftKeys(by: clipStart)
            return ExtractedLayer(layer: m, span: TimeRange(start: clipStart + local.start, duration: local.duration))
        }
    }

    /// Puts `items` into the clip at `clipStart` lasting `clipDuration`, above the layer at `index` (nil = on top), and
    /// returns their IDs. A layer keeps its picture and keys on the same timeline times; a range that fills the clip
    /// is stored as nil. `fresh` gives every layer new IDs (copy); Follow links among the set follow the copies.
    @discardableResult
    public mutating func insertLayers(_ items: [ExtractedLayer], clipStart: Time, clipDuration: Time, at index: Int? = nil,
                                      fresh: Bool = false) -> [UUID] {
        var map: [UUID: UUID] = [:]
        var placed: [GraphicsLayer] = []
        for it in items {
            var l = it.layer
            if fresh {
                let old = l.id
                l.id = UUID(); l.name += " copy"
                l.animation.position = l.animation.position.withFreshKeyIDs()
                l.animation.scale = l.animation.scale.withFreshKeyIDs()
                l.animation.rotation = l.animation.rotation.withFreshKeyIDs()
                l.animation.opacity = l.animation.opacity.withFreshKeyIDs()
                l.animation.anchor = l.animation.anchor.withFreshKeyIDs()
                l.effects = l.effects.map { var e = $0; e.id = UUID(); return e }
                map[old] = l.id
            }
            l.shiftKeys(by: Time.zero - clipStart)
            let r = GraphicsDocument.clamped(TimeRange(start: it.span.start - clipStart, duration: it.span.duration), to: clipDuration)
            l.range = r.start <= .zero && r.end >= clipDuration ? nil : r
            placed.append(l)
        }
        for i in placed.indices {
            if case .layer(let t)? = placed[i].follow?.target, let n = map[t] { placed[i].follow?.target = .layer(id: n) }
        }
        let at = min(max(index ?? layers.count, 0), layers.count)
        layers.insert(contentsOf: placed, at: at)
        return placed.map(\.id)
    }
}

extension GraphicsLayer {
    /// Moves every key time (Motion, Opacity, effects) by `d`.
    mutating func shiftKeys(by d: Time) {
        guard d != .zero else { return }
        animation = animation.remapped { $0 + d }
        for j in effects.indices { effects[j] = effects[j].remapped { $0 + d } }
    }
}

/// Where dragged layers land.
public enum GraphicsLayerDestination: Sendable, Equatable {
    /// Another Graphic, above the layer at `index` of its list (nil = on top).
    case graphic(Clip.ID, index: Int?)
    /// A new Graphic on a video track, covering the time the layers show in.
    case newGraphic(track: Track.ID)
}

extension Project {
    /// Moves (or, with `copy`, copies) layers of Graphic `source` to another Graphic or to a new Graphic on another track,
    /// as one mutation (one undo step "Move Layer Out"). The edit is all or nothing. A moved-out Graphic that is left
    /// without layers is removed. Throws `.clipNotFound` (unknown clip or layers), `.trackLocked`, `.wrongTrackKind`
    /// and `.collision` (the target Graphic does not overlap a layer in time, the new Graphic would cover another clip,
    /// or the destination is the source). Returns the receiving Graphic and the IDs of the layers there.
    @discardableResult
    public mutating func moveGraphicsLayers(_ ids: [UUID], from source: Clip.ID, to dest: GraphicsLayerDestination,
                                            copy: Bool = false) throws -> (clip: Clip.ID, layers: [UUID]) {
        var work = self
        guard let ti = work.timelines.firstIndex(where: { $0.tracks.contains { $0.clips.contains { $0.id == source } } }),
              let si = work.timelines[ti].tracks.firstIndex(where: { $0.clips.contains { $0.id == source } }),
              let src = work.timelines[ti].tracks[si].clips.first(where: { $0.id == source }), src.isGraphics,
              var doc = src.graphics, !ids.isEmpty, ids.allSatisfy({ doc.layer($0) != nil }) else { throw EditError.clipNotFound }
        if work.timelines[ti].tracks[si].isLocked { throw EditError.trackLocked }
        let start = src.timeline.start, length = src.timeline.duration
        let items = copy ? doc.extractedCopies(ids, clipStart: start, clipDuration: length)
                         : doc.extractLayers(ids, clipStart: start, clipDuration: length)
        let landed: (clip: Clip.ID, layers: [UUID])
        switch dest {
        case .graphic(let target, let index):
            guard target != source else { throw EditError.collision }
            guard let c = work.graphicsClip(target) else { throw EditError.clipNotFound }
            guard items.allSatisfy({ $0.span.overlaps(c.timeline) }) else { throw EditError.collision }
            let placed = try work.editGraphics(clipID: target) {
                $0.insertLayers(items, clipStart: c.timeline.start, clipDuration: c.timeline.duration, at: index, fresh: copy)
            }
            landed = (target, placed)
        case .newGraphic(let trackID):
            guard let tr = work.timelines[ti].tracks.firstIndex(where: { $0.id == trackID }) else { throw EditError.clipNotFound }
            guard work.timelines[ti].tracks[tr].kind == .video else { throw EditError.wrongTrackKind }
            if work.timelines[ti].tracks[tr].isLocked { throw EditError.trackLocked }
            let from = items.map(\.span.start).min() ?? start, to = items.map(\.span.end).max() ?? start
            let span = TimeRange(start: from, end: max(to, from + work.timelines[ti].frameDuration))
            // shortcut: no overwrite here; a drop onto occupied time is refused so the receiving track never eats a clip
            // (the source Graphic included), upgrade when a drop should be allowed to overwrite.
            guard !work.timelines[ti].tracks[tr].clips.contains(where: { $0.timeline.overlaps(span) }) else { throw EditError.collision }
            let id = try work.addGraphicsClip(in: work.timelines[ti].id, at: span.start, track: trackID, duration: span.duration)
            let placed = try work.editGraphics(clipID: id) {
                $0.insertLayers(items, clipStart: span.start, clipDuration: span.duration, fresh: copy)
            }
            landed = (id, placed)
        }
        if !copy {
            if doc.layers.isEmpty { work.timelines[ti].tracks[si].remove(source) }
            else {
                var edited = src
                edited.graphics = doc
                work.timelines[ti].tracks[si].replace(edited)
            }
        }
        self = work
        return landed
    }
}
