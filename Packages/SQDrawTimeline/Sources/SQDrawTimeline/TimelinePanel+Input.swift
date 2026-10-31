import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI

/// Events, translated from `TimelineView.mouseDown / mouseDragged / mouseUp / scrollWheel` and the autoscroll timer:
/// the same order of hit checks and the same SQTimelineUI calls; callbacks become `TimelineAction`s.
extension TimelinePanel {
    /// Seconds and points within which a second press counts as a double-click (the host reports no click count).
    static let doubleClickTime: Double = 0.5
    static let doubleClickDistance: CGFloat = 4

    /// Panel points of a host event position (device pixels in the window).
    public func point(x: Float, y: Float) -> CGPoint {
        CGPoint(x: CGFloat((x - frame.x) / scale), y: CGFloat((y - frame.y) / scale))
    }

    /// Handles one host event; mouse downs and wheel events outside the frame are ignored, drags and the release of a
    /// press that began here are taken wherever the pointer is.
    public mutating func handle(_ e: InputEvent) -> [TimelineAction] {
        // Wheel, zoom bar, hand and zoom keys while playing: the user's view beats the playback follow (the Mac
        // viewport-change hook).
        let view = (geometry.scrollX, geometry.pointsPerSecond)
        defer {
            let moved = view != (geometry.scrollX, geometry.pointsPerSecond)
            if moved { zoomAnimation = nil }                         // a scroll or drag of the view ends a running ease (Mac `setScroll`)
            if isPlaying, moved { follow.userScrolled(whilePlaying: true) }
            publishHover(e)
        }
        switch e {
        case .mouseDown(let x, let y, let mods):
            guard frame.contains(x, y) else { return [] }
            return mouseDown(point(x: x, y: y), modifiers: mods)
        case .mouseDragged(let x, let y):
            guard gesture != nil else { return [] }
            return mouseDragged(point(x: x, y: y))
        case .mouseUp(let x, let y):
            guard gesture != nil else { return [] }
            return mouseUp(point(x: x, y: y))
        case .mouseMoved(let x, let y):
            return mouseMoved(frame.contains(x, y) ? point(x: x, y: y) : nil)
        case .scroll(let x, let y, let dx, let dy, let mods):
            guard frame.contains(x, y) else { return [] }
            scrollWheel(at: point(x: x, y: y), gesture: ScrollGesture.current(pixelsX: dx, pixelsY: dy), modifiers: mods)
            return []
        case .keyDown(let k, let mods):
            return key(k, modifiers: mods) ?? []
        }
    }

    static func gestureModifiers(_ m: InputModifiers) -> GestureModifiers {
        var g: GestureModifiers = []
        if m.contains(.shift) { g.insert(.shift) }
        if m.contains(.command) { g.insert(.command) }
        if m.contains(.option) { g.insert(.option) }
        return g
    }

    /// 1, 2, 3... for presses close in time and place (NSEvent.clickCount).
    mutating func clickCount(at p: CGPoint) -> Int {
        let now = clock()
        var n = 1
        if let l = lastClick, now - l.time <= Self.doubleClickTime,
           abs(p.x - l.point.x) <= Self.doubleClickDistance, abs(p.y - l.point.y) <= Self.doubleClickDistance { n = l.count + 1 }
        lastClick = (now, p, n)
        return n
    }

    // MARK: Mouse down

    mutating func mouseDown(_ p: CGPoint, modifiers mods: InputModifiers) -> [TimelineAction] {
        // The right button (`rightMouseDown`): the host builds the menu (`TimelineMenus`), which selects first.
        // An open word field: a press inside keeps editing, any other press takes the text first (the field loses focus).
        if !mods.contains(.secondary), let inside = wordFieldPress(p) { return inside }
        let typed = finishWordField(commit: true)
        if mods.contains(.secondary) { cancelGesture(); return typed + [.contextMenu(at: p)] }
        downModifiers = mods
        pressCursor = cursor(atPoint: p, modifiers: mods)
        if toolState.keepAttached { keepAttachedUsed = true }
        // A press ends the skim (the Mac `clearSkimmer`; the host's skim returns the monitor to the playhead).
        let skimAt = skimmerTime
        let skimEnd: [TimelineAction] = skimAt == nil ? [] : [.skim(nil)]
        skimmerTime = nil
        return typed + skimEnd + pressed(p, modifiers: mods, skimmedTime: skimAt)
    }

    private mutating func pressed(_ p: CGPoint, modifiers mods: InputModifiers, skimmedTime: Time? = nil) -> [TimelineAction] {
        let clicks = clickCount(at: p)
        let shift = mods.contains(.shift), command = mods.contains(.command), option = mods.contains(.option)
        let tool = toolState.timelineTool
        if zoomBarDown(p, clicks: clicks) { return [] }
        if interaction.isIdle, let zone = TrackSizing.zone(at: p, rows: rows, viewWidth: size.width) {
            if zone == .split, clicks == 2 {                    // double-click: back to the middle
                geometry.splitFraction = TrackSizing.defaultSplitFraction
                clampScroll()
                persistHeights()
                return []
            }
            gesture = .resize(zone: zone, startY: p.y, rows: rows, startFraction: geometry.splitFraction)
            return []
        }
        if patchDown(p) { return [] }                          // the patch chip comes first in its header (Mac)
        // The header buttons are subviews on the Mac: they take the press before the timeline sees it.
        if let (id, toggle) = headerHit(p) {
            gesture = .header(id, toggle)
            return [.toggleTrack(id, toggle, shift: shift, option: option)]
        }
        if let lane = itemLaneDown(p, modifiers: mods) { return lane }
        if case .header(let id) = geometry.hitTest(p, in: timeline) {
            gesture = .header(id, .target)
            if clicks == 2 { applyHeights(TrackSizing.toggled(rows: rows, track: id, wholeKind: shift)); persistHeights() }   // header double-click
            return []
        }
        if keystoneDown(p) { return [] }
        var out: [TimelineAction] = []
        if let speed = speedDown(p, modifiers: mods) { return speed }
        if let key = keyLaneDown(p, shift: shift) { return key }
        if attachDown(p, modifiers: mods) { lastDrag = p; return [] }      // Fast Cut: drag the attach thread
        if let band = bandDown(p, command: command, shift: shift) { return band }
        // A press anywhere else drops the picked line keys (the Mac view's `onLineKeyClick(nil)`).
        if !selectedLineKeys.isEmpty { selectedLineKeys = []; out.append(.lineKeyClick(nil, extend: false)) }
        if let t = weakStretchJump(at: p) { playhead = t; return out + [.seek(t)] }
        if let id = attachPointClick(at: p, modifiers: mods) { return out + [.setAttachPoint(clip: id, time: geometry.time(atX: p.x))] }
        if let id = captionEyeHit(p) { return out + [.toggleCaptionTrackVisibility(id)] }
        if tool == .selection, let layer = transitionLayerDown(p, clicks: clicks) { return out + layer }
        if tool == .selection, let hit = TransitionLayout.hitTest(p, in: timeline, geometry: geometry) {
            let keep = shift || command
            selectedTransition = hit.id
            out.append(.selectTransition(hit.id, keepClips: keep))
            if clicks == 2 { return out + [.editTransition(hit.id)] }
            if let track = timeline.track(hit.track),
               let r = track.resolvedTransitions(frameDuration: timeline.format.frameDuration).first(where: { $0.id == hit.id }) {
                gesture = .transition(hit: hit, original: r, startX: p.x, began: false, lastFrames: 0)
            }
            return out
        }
        let hit = geometry.hitTest(p, in: timeline)
        // Two quick Razor or Zoom clicks are two cuts / zooms; every other tool opens the item on double-click.
        let opens = clicks == 2 && tool != .razor && tool != .zoom
        if opens, case .caption(let id, _) = hit {
            // The word under the pointer becomes a field; a caption without words keeps the Text panel.
            return beginWordEditing(at: p, caption: id) ?? [.editCaption(id, word: nil)]
        }
        if clicks == 2, tool == .selection, case .clip(let id, let zone) = hit, zone != .body,
           let tr = timeline.tracks.first(where: { $0.clips.contains { $0.id == id } }),
           let c = tr.clips.first(where: { $0.id == id }), !tr.isLocked, c.sequence == nil, c.generator == nil,
           geometry.x(for: c.timeline.end) - geometry.x(for: c.start) >= 3 * TimelineGeometry.maxTrimHandleWidth,
           let point = timeline.trimPoint(at: zone == .head ? c.start : c.timeline.end, on: tr.id) {
            return [.openTrimMode(point, pointerBefore: zone == .tail)]
        }
        if opens, case .clip(let id, _) = hit, let clip = timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) {
            if let seq = clip.sequence { return [.openNestedSequence(seq)] }
            if clip.tone != nil { return [.editToneClip(id)] }
            if clip.isGraphics { return [.openGraphicLayers(id)] }
            if clip.generator != nil { return [.editTextClip(id)] }
            return [.openInSource(clip.media)]
        }
        if hit == .ruler {
            // Above the track headers the ruler shows nothing: markers and In/Out scrolled under there cannot be grabbed.
            let onContent = p.x >= TimelineGeometry.contentOriginX
            if clicks == 2, let m = markerID(at: p) { return [.editMarker(m)] }
            if let h = markerEndHandleID(at: p), let m = timeline.markers.first(where: { $0.id == h }) {
                gesture = .markerDuration(id: h, start: m.time, original: m.duration, moved: false)
                return []
            }
            if let m = markerID(at: p), let time = timeline.markers.first(where: { $0.id == m })?.time {
                gesture = .marker(id: m, downX: p.x, moved: false, original: time)
                return []
            }
            if onContent, let io = timeline.inOut, !io.isEmpty, let part = InOutDrag.part(atX: p.x, range: io, geometry: geometry) {
                gesture = .inOut(part: part, downX: p.x, downTime: geometry.time(atX: p.x), moved: false, original: io)
                return []
            }
            // The ruler is the playhead's handle: the press itself begins the scrub.
            gesture = .scrub
            lastDrag = p
            let t = scrubTime(at: p, shift: shift)
            playhead = t
            return [.beginScrub, .scrub(t)]
        }
        if tool != .zoom, tool != .hand, let h = ClipMarkerFlags.hit(at: p, in: timeline, geometry: geometry) {
            if clicks == 2 { return [.editClipMarker(clip: h.clip, marker: h.marker)] }
            gesture = .clipMarker(hit: h, downX: p.x, moved: false)    // a drag moves the flag; a plain click does nothing
            return []
        }
        if tool == .zoom, p.x >= TimelineGeometry.contentOriginX, p.y >= TimelineGeometry.rulerHeight {
            gesture = .zoom(start: p, current: p, zoomOut: option)
            return []
        }
        if selectedTransition != nil, !shift, !command {
            selectedTransition = nil
            out.append(.selectTransition(nil, keepClips: false))
        }
        // Fast Cut: a plain press over the tracks also puts the playhead where the skimmer was (the Mac `mouseDown`).
        if let t = skimmedTime, clicks == 1, mods.intersection([.shift, .command, .option]).isEmpty {
            playhead = t
            out.append(.seek(t))
        }
        feedInteraction()
        interaction.mouseDown(p, modifiers: Self.gestureModifiers(mods))
        gesture = .clips
        lastDrag = p
        return out + refreshFromInteraction()
    }

    // MARK: Drag

    mutating func mouseDragged(_ p: CGPoint) -> [TimelineAction] {
        guard let g = gesture else { return [] }
        let shift = dragModifiers.contains(.shift)
        switch g {
        case .transition(let hit, let original, let startX, let began, let lastFrames):
            let frames = (geometry.time(atX: p.x) - geometry.time(atX: startX)).frameIndex(frameDuration: geometry.frameDuration)
            if frames == lastFrames && began { return [] }
            if !began && abs(p.x - startX) < TimelineInteraction.dragThreshold { return [] }
            let change = TransitionLayout.drag(original, zone: hit.zone, frames: frames, oneSide: shift)
            gesture = .transition(hit: hit, original: original, startX: startX, began: true, lastFrames: frames)
            return [.changeTransition(hit.id, change, continues: began)]
        case .resize(let zone, let startY, let startRows, let startFraction):
            let dy = p.y - startY
            switch zone {
            case .split:
                // Only the split moves: the heights as drawn are frozen so stretched rows do not re-fit under the pointer.
                let frozen = TrackSizing.frozen(startRows)
                if geometry.heightOverrides != frozen { applyHeights(frozen) }
                geometry.splitFraction = TrackSizing.splitFraction(startFraction: startFraction, dy: dy,
                                                                   available: geometry.splitAvailable(for: timeline))
                clampScroll()
            case .trackEdge(let id):
                let start = startRows.first { $0.track == id }?.height ?? 0
                applyHeights(TrackSizing.resized(rows: startRows, track: id, to: start + dy, wholeKind: shift))
            }
            return []
        case .zoom(let start, _, let out):
            gesture = .zoom(start: start, current: p, zoomOut: out)
            return []
        case .inOut(let part, let downX, let downTime, let moved, let original):
            if !moved, abs(p.x - downX) < TimelineInteraction.dragThreshold { return [] }
            gesture = .inOut(part: part, downX: downX, downTime: downTime, moved: true, original: original)
            lastDrag = p
            dragInOut(to: p)
            return []
        case .markerDuration(let id, let start, let original, _):
            gesture = .markerDuration(id: id, start: start, original: original, moved: true)
            let r = MarkerRange.duration(forEndTime: geometry.unsnappedTime(atX: p.x), start: start, timeline: timeline,
                                         markerID: id, snapping: snapping, geometry: geometry, playhead: playhead, beatLevel: beatLevel)
            _ = timeline.setMarkerDuration(id, to: r)
            return []
        case .marker(let id, let downX, let moved, let original):
            if !moved, abs(p.x - downX) < TimelineInteraction.dragThreshold { return [] }
            gesture = .marker(id: id, downX: downX, moved: true, original: original)
            lastDrag = p
            dragMarker(to: p)
            return []
        case .scrub:
            lastDrag = p
            let t = scrubTime(at: p, shift: shift)
            playhead = t
            return [.scrub(t)]
        case .transitionLayer(let d):
            return transitionLayerDragged(d, at: p)
        case .patch(let kind, let down, let dragging):
            patchDragged(kind, down: down, dragging: dragging, at: p)
            return []
        case .header:
            return []
        case .zoomBar(let s):
            zoomBarDragged(p, s)
            return []
        case .clipMarker(let h, let downX, let moved):
            if !moved, abs(p.x - downX) < TimelineInteraction.dragThreshold { return [] }
            gesture = .clipMarker(hit: h, downX: downX, moved: true)
            lastDrag = p
            let r = clipMarkerTarget(h, at: p)
            timeline.moveClipMarker(h.marker, on: h.clip, to: r.time)
            scrubSnapTime = r.hit?.time
            return []
        case .band(let d):
            return bandDragged(d, to: p)
        case .speed:
            return speedDragged(to: p)
        case .attach:
            attachDragged(to: p)
            lastDrag = p
            return []
        case .keystone(let d):
            keystoneDragged(d, to: p)
            return []
        case .itemLane:
            return itemLaneDragged(to: p)
        case .clips:
            interaction.geometry = geometry
            interaction.mouseDragged(p, modifiers: Self.gestureModifiers(dragModifiers))
            lastDrag = p
            return refreshFromInteraction()
        }
    }

    // MARK: Release

    mutating func mouseUp(_ p: CGPoint) -> [TimelineAction] {
        guard let g = gesture else { return [] }
        defer { gesture = nil; lastDrag = nil; lastAutoscroll = nil; interaction.snapInverted = false }
        switch g {
        case .resize:
            persistHeights()
            return []
        case .transitionLayer:
            return []
        case .transition, .header:
            return []
        case .patch(let kind, _, let dragging):
            return patchUp(kind, dragging: dragging, at: p)
        case .attach:
            return attachUp(at: p)
        case .keystone(let d):
            return keystoneUp(d, at: p)
        case .itemLane:
            return itemLaneUp(at: p)
        case .zoomBar:
            zoomBarUp()
            return []
        case .band(let d):
            return bandUp(d, at: p)
        case .speed:
            return speedUp(at: p)
        case .clipMarker(let h, _, let moved):
            scrubSnapTime = nil
            guard moved else { return [] }
            let r = clipMarkerTarget(h, at: p)
            timeline.moveClipMarker(h.marker, on: h.clip, to: h.time)    // back to the original, the session commits
            return r.time != h.time ? [.moveClipMarker(clip: h.clip, marker: h.marker, to: r.time)] : []
        case .zoom(let start, _, let out):
            finishZoomDrag(start: start, end: p, zoomOut: out)
            return []
        case .inOut(let part, _, let downTime, let moved, let original):
            guard moved else { return rulerClick(at: geometry.time(atX: p.x)) }
            let r = InOutDrag.target(part: part, original: original, downTime: downTime, time: geometry.time(atX: p.x),
                                     frameDuration: geometry.frameDuration)
            if r != original { return [.moveInOut(r, part: part.markedPart)] }
            timeline.setMarkedRange(original)
            return []
        case .markerDuration(let id, _, let original, let moved):
            let now = timeline.markers.first { $0.id == id }?.duration ?? original
            _ = timeline.setMarkerDuration(id, to: original)          // back to the original, the session commits
            return moved && now != original ? [.setMarkerDuration(id, to: now)] : []
        case .marker(let id, _, let moved, let original):
            scrubSnapTime = nil
            guard moved else { return rulerClick(at: geometry.time(atX: p.x)) }
            let r = MarkerDrag.target(time: geometry.unsnappedTime(atX: p.x), dragging: id, in: timeline, playhead: playhead,
                                      snapping: snapping, geometry: geometry, beatLevel: beatLevel)
            if r.time != original { return [.moveMarker(id, to: r.time)] }
            timeline.moveMarker(id, to: original)
            return []
        case .scrub:
            scrubSnapTime = nil
            return [.endScrub]
        case .clips:
            interaction.geometry = geometry
            let commit = interaction.mouseUp(p, modifiers: Self.gestureModifiers(dragModifiers))
            var out = refreshFromInteraction()
            if let m = interaction.releasedRejection { out.append(.status(m)) }
            if let commit { out.append(.commit(commit)) }
            return out
        }
    }

    /// Esc during a drag: the gesture is dropped and the committed timeline shows again.
    public mutating func cancelGesture() {
        guard gesture != nil else { return }
        interaction.cancel()
        slipTwoUpShown = false
        gesture = nil
        lastDrag = nil
        scrubSnapTime = nil
        timeline = committed
    }

    // MARK: Hover, wheel, keys

    mutating func mouseMoved(_ p: CGPoint?) -> [TimelineAction] {
        hoverPoint = p
        zoomBar.hover(p, in: zoomBarRect, handles: zoomBarHandles)
        if let p { hoverTrack = rows.first { p.y >= $0.y && p.y < $0.maxY && p.y >= TimelineGeometry.rulerHeight }?.track }
        else { hoverTrack = nil }
        return updateSkimmer(pointer: p)
    }

    /// Timeline keys: the tool letters (`TimelineTool(key:)`), zoom (`=` `-` `\`), Esc and Delete. nil = not a
    /// timeline key, the host handles it (transport, undo...).
    public mutating func key(_ k: InputKey, modifiers mods: InputModifiers) -> [TimelineAction]? {
        defer { publishKeyHover() }
        if toolState.keepAttached, k != .character("`") { keepAttachedUsed = true }     // a key edit during the ` hold
        if wordField != nil { return wordFieldKey(k, modifiers: mods) }
        if case .character(let ch) = k, let lane = itemLaneKey(ch, modifiers: mods) { return lane }
        switch k {
        case .enter where mods.isEmpty:
            return editSelectedWord()                        // Return: the selected word becomes a field
        case .escape:
            guard gesture != nil else {
                // No drag: Esc goes back to the Selection tool first (the Mac key monitor), then clears a gap or edge selection (the Mac `keyDown`); else it is the host's.
                if toolState.tool != .selection { toolHold.clear(); toolState.select(.selection); return [] }
                guard interaction.clearGapAndEdgeSelection() else { return nil }
                return refreshFromInteraction()
            }
            let hideTwoUp = slipTwoUpShown
            let lane = cancelItemLaneDrag() + cancelBandDrag() + cancelSpeedDrag()
            cancelGesture()
            return hideTwoUp ? [.slipTwoUp(nil, timeline)] : lane
        case .plus where mods.isEmpty: zoomIn(); return []
        case .minus where mods.isEmpty: zoomOut(); return []
        case .delete, .backspace:
            if HostKeyRepeat.shared.isRepeat { return [] }     // a held Delete deletes once (the Mac `isRepeatable` filter)
            if mods.isEmpty, let word = deleteSelectedWord() { return word }     // a selected word goes alone
            guard mods.subtracting(.shift).isEmpty, interaction.hasDeleteTarget, gesture == nil else { return nil }
            // The Mac order (`AppController.execute(.delete)`): a selected transition goes first, then a gap (ripple close).
            if selectedTransition != nil { return nil }
            if selection.isEmpty, captionSelection.isEmpty, let gap = interaction.gapSelection { return [.closeGap(gap)] }
            // Delete / Backspace lift (clear), Shift ripples (the Mac key map's clear / ripple delete).
            guard let c = interaction.deleteSelection(ripple: mods.contains(.shift)) else { return [] }
            var out = refreshFromInteraction()
            out.append(.commit(c))
            return out
        case .character("s") where mods.isEmpty && gesture != nil:
            return setSnapInverted(true)                     // Hold-S: snapping flips until the key comes up
        case .character("`") where mods.isEmpty && timeline.isFastCut:
            if !toolState.keepAttached { keepAttachedUsed = gesture != nil }
            return holdKeepAttached(true)                    // Fast Cut: attached clips stay on their frame while held
        case .character(let ch) where mods.isEmpty:
            if ch == "\\" { zoomToFit(); return [] }
            if ch == "=" { zoomIn(); return [] }
            guard gesture == nil, let tool = TimelineTool(key: ch) else { return nil }
            if !HostKeyRepeat.shared.isRepeat, let now = ToolStripTools.editorTool(toolState.tool), let next = ToolStripTools.editorTool(tool) {
                toolHold.press(.char(Character(ch.lowercased())), tool: next, previous: now, at: clock())
            }
            toolState.tool = tool
            return []
        default:
            return nil
        }
    }

    // MARK: Autoscroll (`autoscrollTick`)

    /// A drag sits near the left or right edge: the host must draw every frame so the autoscroll keeps its pace even when
    /// the pointer rests (the Mac runs a 60 Hz timer for it).
    public var isAutoscrolling: Bool {
        guard let l = lastDrag, gesture != nil, toolState.timelineTool != .hand, toolState.timelineTool != .zoom else { return false }
        return TimelineAutoscroll.velocity(pointerX: l.x, viewLeft: TimelineGeometry.contentOriginX, viewRight: size.width) != 0
    }

    /// Call once per frame: a drag near the left or right edge scrolls and replays the drag at the new scroll.
    public mutating func tick() -> [TimelineAction] {
        stepSpringBack()
        stepZoomAnimation()
        guard let l = lastDrag, gesture != nil, toolState.timelineTool != .hand, toolState.timelineTool != .zoom else {
            lastAutoscroll = nil
            return []
        }
        let now = clock()
        let dt = min(now - (lastAutoscroll ?? now), 0.1)
        lastAutoscroll = now
        let v = TimelineAutoscroll.velocity(pointerX: l.x, viewLeft: TimelineGeometry.contentOriginX, viewRight: size.width)
        guard v != 0, dt > 0 else { return [] }
        let before = geometry.scrollX
        geometry.scrollX += v * CGFloat(dt)
        clampScroll()
        guard geometry.scrollX != before else { return [] }
        return replayDrag()
    }

    mutating func replayDrag() -> [TimelineAction] {
        guard let p = lastDrag, let g = gesture else { return [] }
        switch g {
        case .marker(_, _, true, _): dragMarker(to: p); return []
        case .clipMarker(let h, _, true):
            let r = clipMarkerTarget(h, at: p)
            timeline.moveClipMarker(h.marker, on: h.clip, to: r.time)
            scrubSnapTime = r.hit?.time
            return []
        case .itemLane: return itemLaneDragged(to: p)
        case .inOut(_, _, _, true, _): dragInOut(to: p); return []
        case .scrub:
            let t = scrubTime(at: p, shift: dragModifiers.contains(.shift))
            playhead = t
            return [.scrub(t)]
        case .clips:
            guard !interaction.isIdle else { return [] }
            interaction.geometry = geometry
            interaction.mouseDragged(p, modifiers: Self.gestureModifiers(dragModifiers))
            return refreshFromInteraction()
        default: return []
        }
    }

    // MARK: Helpers (translated as they are)

    var snapping: Bool { toolState.snapping != interaction.snapInverted }

    mutating func feedInteraction() {
        interaction.geometry = geometry
        interaction.playhead = playhead
        interaction.markers = timeline.markerSnapTimes(beatLevel: beatLevel) + timeline.clipMarkerTimes()
    }

    /// Shows the gesture's preview and reports selection changes and hints (`refreshFromInteraction`).
    mutating func refreshFromInteraction() -> [TimelineAction] {
        var out: [TimelineAction] = []
        // Slip: the monitor shows the clip's new first and last frame while dragging (the Mac `onSlipTwoUp`).
        if let two = interaction.slipTwoUp {
            slipTwoUpShown = true
            out.append(.slipTwoUp(two, interaction.preview))
        } else if slipTwoUpShown {
            slipTwoUpShown = false
            out.append(.slipTwoUp(nil, interaction.preview))
        }
        if interaction.moveHint != lastHint {
            lastHint = interaction.moveHint
            if let h = lastHint { out.append(.status(h)) }
        }
        if interaction.geometry.scrollX != geometry.scrollX || interaction.geometry.scrollY != geometry.scrollY {
            geometry.scrollX = interaction.geometry.scrollX
            geometry.scrollY = interaction.geometry.scrollY
            clampScroll()
        }
        if interaction.preview != timeline { timeline = interaction.preview }
        if interaction.selection != selection || interaction.captionSelection != captionSelection {
            selection = interaction.selection
            captionSelection = interaction.captionSelection
            out.append(.select(clips: selection, captions: captionSelection))
        }
        return out
    }

    mutating func applyHeights(_ h: [Track.ID: CGFloat]) {
        if geometry.fitAllTracks { geometry.fitAllTracks = false }
        geometry.heightOverrides = h
        clampScroll()
    }

    /// `scrubTime`: Shift (or Hold-S) sticks the playhead to edits, markers and 0 and shows the snap line.
    mutating func scrubTime(at p: CGPoint, shift: Bool) -> Time {
        guard shift || interaction.snapInverted else { scrubSnapTime = nil; return geometry.time(atX: p.x) }
        let r = PlayheadSnap.resolve(geometry.unsnappedTime(atX: p.x), timeline: timeline, geometry: geometry, beatLevel: beatLevel)
        scrubSnapTime = r.hit?.time
        return r.time
    }

    func rulerClick(at t: Time) -> [TimelineAction] { [.beginScrub, .seek(t), .endScrub] }

    mutating func dragInOut(to p: CGPoint) {
        guard case .inOut(let part, _, let downTime, _, let original)? = gesture else { return }
        timeline.setMarkedRange(InOutDrag.target(part: part, original: original, downTime: downTime, time: geometry.time(atX: p.x),
                                                 frameDuration: geometry.frameDuration))
    }

    mutating func dragMarker(to p: CGPoint) {
        guard case .marker(let id, _, _, _)? = gesture else { return }
        let r = MarkerDrag.target(time: geometry.unsnappedTime(atX: p.x), dragging: id, in: timeline, playhead: playhead,
                                  snapping: snapping, geometry: geometry, beatLevel: beatLevel)
        timeline.moveMarker(id, to: r.time)
        scrubSnapTime = r.hit?.time
    }

    /// `dragClipMarker`: where the flag under the pointer lands.
    func clipMarkerTarget(_ h: ClipMarkerFlags.Hit, at p: CGPoint) -> (time: Time, hit: SnapPoint?) {
        ClipMarkerFlags.target(time: geometry.unsnappedTime(atX: p.x), dragging: h, in: timeline, playhead: playhead,
                               snapping: snapping, geometry: geometry)
    }

    /// `markerID(at:)`: the nearest marker flag within 6 pt in the ruler's grab band.
    func markerID(at p: CGPoint) -> Marker.ID? {
        guard p.x >= TimelineGeometry.contentOriginX,
              MarkerRange.grabBand(rulerHeight: TimelineGeometry.rulerHeight).contains(p.y) else { return nil }
        return timeline.markers.map { ($0.id, abs(geometry.x(for: $0.time) - p.x)) }
            .filter { $0.1 <= 6 }.min { $0.1 < $1.1 }?.0
    }

    func markerEndHandleID(at p: CGPoint) -> Marker.ID? {
        guard p.x >= TimelineGeometry.contentOriginX,
              MarkerRange.grabBand(rulerHeight: TimelineGeometry.rulerHeight).contains(p.y) else { return nil }
        return MarkerRange.endHandle(atX: p.x, markers: timeline.markers, geometry: geometry)
    }

    /// `finishZoomDrag`: a click zooms one step in (Option: out) around the pointer, a box zooms to fit it.
    mutating func finishZoomDrag(start: CGPoint, end: CGPoint, zoomOut: Bool) {
        let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
        let r: (scale: Double, scrollX: Double)
        if max(dx, dy) < TimelineInteraction.dragThreshold {
            let t = zoomTarget
            let c = TimelineZoom.zoomClick(scale: t.scale, scrollX: t.scrollX,
                                           anchorX: Double(start.x - TimelineGeometry.contentOriginX), zoomOut: zoomOut, range: zoomLimits)
            startZoomAnimation(toScale: c.scale, toScroll: c.scrollX, mode: .anchored(x: Double(start.x - TimelineGeometry.contentOriginX)))
            return
        } else {
            func seconds(_ x: CGFloat) -> Double {
                let t = geometry.unsnappedTime(atX: x)
                return Double(t.value) / Double(t.timescale)
            }
            r = TimelineZoom.zoomMarquee(startSeconds: seconds(start.x), endSeconds: seconds(end.x),
                                         viewport: Double(contentViewportWidth), range: zoomLimits)
        }
        zoomAnimation = nil
        geometry.pointsPerSecond = r.scale
        geometry.scrollX = CGFloat(r.scrollX)
        clampScroll()
    }
}
