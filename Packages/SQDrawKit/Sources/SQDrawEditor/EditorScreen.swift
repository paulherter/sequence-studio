import Foundation
import SQCore
import SQDrawKit

/// The whole editor window: top bar, Program monitor card, timeline card, status bar (design B: cards 2 pt apart on the
/// divider color). Keys: Space play/pause, J/K/L shuttle, Left/Right step, Home/End, I/O marks (Shift: go to), M marker,
/// V/C tools, Delete (Shift: ripple),
/// Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y, +/- zoom, `\` zoom to fit.
public struct EditorScreen {
    public var theme: DrawTheme
    public var timelineView = TimelineView()
    public private(set) var topBar = DrawRect.zero
    public private(set) var statusBar = DrawRect.zero
    public private(set) var monitor = DrawRect.zero
    /// The Effect Controls card left of the Program monitor (the Mac Editing layout); the host draws the panel into it.
    public private(set) var inspector = DrawRect.zero
    /// The Project panel left of the timeline (pixels); 0 width while `projectWidth` is 0 (points, set by the host).
    public private(set) var project = DrawRect.zero
    public var projectWidth: Float = 0
    /// Draws the plain top and status bars; false when the host draws its own (the Mac shared UI's title row and
    /// `StatusBarDraw`). The bars keep their rects either way.
    public var drawsBars = true
    /// Cards placed by the host (pixels; the Windows panel dock) instead of the fixed layout; nil = the fixed layout.
    public struct Slots: Sendable, Equatable {
        public var monitor, inspector, project, timeline: DrawRect
        public init(monitor: DrawRect, inspector: DrawRect, project: DrawRect, timeline: DrawRect) {
            self.monitor = monitor; self.inspector = inspector; self.project = project; self.timeline = timeline
        }
    }
    public var slots: Slots?
    /// The picture rect inside the monitor (sequence aspect, fitted).
    public private(set) var picture = DrawRect.zero
    /// The Program monitor footer (scrub strip with marks and markers, timecode, transport, In/Out duration), the Mac
    /// MonitorPanelView footer translated to the canvas; laid out in points.
    public private(set) var footer = MonitorFooter()
    /// The In/Out being dragged on the strip (drawn instead of the stored marks until the drop).
    private var markPreview: (markIn: Time?, markOut: Time?)?
    private var shuttle = Shuttle()
    private var fitted = false
    public private(set) var size: (w: Float, h: Float) = (0, 0)

    public init(theme: DrawTheme = DrawTheme()) { self.theme = theme }

    public mutating func layout(width: Float, height: Float, _ s: EditorSnapshot) {
        size = (width, height)
        var r = DrawRect(x: 0, y: 0, w: width, h: height)
        topBar = r.sliceTop(theme.px(DrawTheme.Metrics.topBar))
        statusBar = r.sliceBottom(theme.px(DrawTheme.Metrics.statusBar))
        let gap = theme.px(DrawTheme.Metrics.paneDivider)
        if let slots {
            monitor = slots.monitor; inspector = slots.inspector; project = slots.project; r = slots.timeline
        } else {
            r = DrawRect(x: r.x + gap, y: r.y + gap, w: r.w - 2 * gap, h: r.h - 2 * gap)
            monitor = r.sliceTop((r.h * 0.56).rounded())
            _ = r.sliceTop(gap)
            // Up to 600 pt: past 512 pt (352 rows + 160 lanes, EffectControlsSplit) the keyframe lanes show beside the rows.
            inspector = monitor.sliceLeft(min(max((monitor.w * 0.34).rounded(), theme.px(300)), theme.px(600)))
            _ = monitor.sliceLeft(gap)
            if projectWidth > 0 {
                project = r.sliceLeft(min(theme.px(projectWidth), (r.w * 0.4).rounded()))
                _ = r.sliceLeft(gap)
            } else { project = .zero }
        }
        timelineView.layout(r, timeline: s.timeline, theme: theme)
        if !fitted, timelineView.tracksArea.w > 0 {
            timelineView.zoomToFit(frames: max(1, s.duration.frameIndex(frameDuration: s.frameDuration)))
            fitted = true
        }
        var m = monitor
        _ = m.sliceTop(theme.px(DrawTheme.Metrics.monitorHeader))
        let footerRect = m.sliceBottom(theme.px(DrawTheme.Metrics.monitorFooter))
        let f = s.timeline.format
        let aspect = Float(max(1, f.width)) / Float(max(1, f.height))
        var pw = m.w, ph = (pw / aspect).rounded()
        if ph > m.h { ph = m.h; pw = (ph * aspect).rounded() }
        picture = DrawRect(x: (m.midX - pw / 2).rounded(), y: (m.midY - ph / 2).rounded(), w: pw, h: ph)
        // The footer works in points (the canvas scales): its strip spans the card inside the 12 pt padding.
        let k = CGFloat(max(theme.scale, 0.01))
        footer.layout(CGRect(x: CGFloat(footerRect.x) / k, y: CGFloat(footerRect.y) / k, width: CGFloat(footerRect.w) / k,
                             height: CGFloat(footerRect.h) / k), footerState(s), durationWidth: 0)
    }

    /// The footer's marks state from the snapshot (MonitorPanelModel's fields the host sets for the Program monitor).
    public func footerState(_ s: EditorSnapshot) -> MonitorFooterState {
        var f = MonitorFooterState(mode: .program, frameDuration: s.frameDuration)
        f.currentTime = s.playhead
        f.duration = s.duration
        f.markIn = markPreview.map(\.markIn) ?? s.timeline.inOut?.start
        f.markOut = markPreview.map(\.markOut) ?? s.timeline.inOut?.end
        f.markerTimes = s.timeline.markers.map(\.time)
        f.isPlaying = s.isPlaying
        return f
    }

    /// Footer rects in pixels (scripted input and tests).
    public func footerPixels(_ r: CGRect) -> DrawRect {
        let k = Float(theme.scale)
        return DrawRect(x: Float(r.minX) * k, y: Float(r.minY) * k, w: Float(r.width) * k, h: Float(r.height) * k)
    }
    public var scrubBar: DrawRect { footerPixels(footer.scrubRect) }
    public func button(_ a: MonitorAction) -> DrawRect { footerPixels(footer.buttons.first { $0.0 == a }?.1 ?? .zero) }
    public var playButton: DrawRect { button(.playPause) }

    // MARK: Drawing

    /// Draws the window; the picture quad is emitted when `hasPicture` (the host binds the decoded frame).
    /// `underlay` draws after the window background and before the cards (the dock's cards and tab strips).
    public func draw(_ s: EditorSnapshot, atlas: GlyphAtlas, hasPicture: Bool, underlay: ((inout DrawList) -> Void)? = nil) -> DrawList {
        var list = DrawList(width: size.w, height: size.h)
        let body = theme.px(DrawTheme.TypeSize.body), cap = theme.px(DrawTheme.TypeSize.caption)
        let pad = theme.px(DrawTheme.Spacing.md)
        list.fill(DrawRect(x: 0, y: topBar.maxY, w: size.w, h: statusBar.y - topBar.maxY), theme.divider)
        // Top bar.
        if drawsBars {
            list.fill(topBar, theme.titlebar)
            list.text("Sequence Studio", in: topBar, pixelSize: body, color: theme.label2, atlas: atlas, inset: pad)
            list.text(s.projectName, in: topBar, pixelSize: body, color: theme.label, atlas: atlas, align: .center)
        }
        underlay?(&list)
        list.fill(inspector, theme.panel, radius: theme.px(DrawTheme.Radius.panel))
        // Monitor card.
        list.fill(monitor, theme.panel, radius: theme.px(DrawTheme.Radius.panel))
        var head = monitor
        let header = head.sliceTop(theme.px(DrawTheme.Metrics.monitorHeader))
        list.text("Program", in: header, pixelSize: body, color: theme.label, atlas: atlas, inset: pad)
        list.text(s.timeline.name, in: header, pixelSize: body, color: theme.label3, atlas: atlas, align: .right, inset: pad)
        list.fill(DrawRect(x: monitor.x, y: picture.y, w: monitor.w, h: picture.h), theme.content)
        list.fill(picture, .black)
        if hasPicture { list.video(picture) }
        drawFooter(&list, s, atlas: atlas)
        // Timeline card.
        timelineView.draw(&list, s, theme: theme, atlas: atlas)
        // Status bar.
        guard drawsBars else { return list }
        list.fill(statusBar, theme.titlebar)
        list.text(s.status, in: statusBar, pixelSize: cap, color: theme.label3, atlas: atlas, inset: pad)
        let f = s.timeline.format
        let fps = Double(f.frameDuration.timescale) / Double(max(1, f.frameDuration.value))
        let format = "\(f.width)×\(f.height) · \(fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)) fps"
        list.text(format, in: statusBar, pixelSize: cap, color: theme.label3, atlas: atlas, align: .right, inset: pad)
        if !s.grade.isEmpty, let r = Self.gradeFrame(statusBar: statusBar, pad: pad,
                                                     statusWidth: atlas.width(of: s.status, pixelSize: cap),
                                                     formatWidth: atlas.width(of: format, pixelSize: cap),
                                                     gradeWidth: atlas.width(of: s.grade, pixelSize: cap)) {
            list.text(s.grade, in: r, pixelSize: cap, color: theme.label3, atlas: atlas)
        }
        return list
    }

    /// The grade text's place (pixels): right before the format text, one `pad` apart (MainWindow `StatusBar.layout`);
    /// nil when it would run into the status text on the left (a narrow window drops it, as the Mac does).
    static func gradeFrame(statusBar r: DrawRect, pad: Float, statusWidth: Float, formatWidth: Float, gradeWidth: Float) -> DrawRect? {
        let right = r.maxX - pad - formatWidth - pad
        let x = (right - gradeWidth).rounded(.down)
        let left = r.x + pad + (statusWidth > 0 ? statusWidth + pad : 0)
        guard gradeWidth > 0, x >= left else { return nil }
        return DrawRect(x: x, y: r.y, w: ceil(gradeWidth) + 1, h: r.h)
    }

    private func drawFooter(_ list: inout DrawList, _ s: EditorSnapshot, atlas: GlyphAtlas) {
        var c = Canvas(list: list, atlas: atlas, scale: theme.scale)
        let st = footerState(s)
        // The duration's width is measured with the glyphs: lay the right side out again for drawing (no hit targets
        // there on the Program monitor).
        var f = footer
        f.layout(footer.frame, st, durationWidth: c.size(of: st.footerDurationText, fontSize: 12).width)
        f.draw(&c, st, theme: theme)
        list = c.list
    }

    // MARK: Input

    public mutating func handle(_ e: InputEvent, _ s: EditorSnapshot) -> [EditorIntent] {
        let k = CGFloat(max(theme.scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        switch e {
        case .keyDown(let key, let mods): return keyIntents(key, mods, s)
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            if footer.frame.contains(p) || footer.gesture.isActive { return footerIntents(footer.mouseDown(p, footerState(s)), s) }
            return timelineView.handle(e, s)
        case .mouseDragged(let x, let y):
            if footer.gesture.isActive { return footerIntents(footer.mouseDragged(pt(x, y), footerState(s)), s) }
            return timelineView.handle(e, s)
        case .mouseUp(let x, let y):
            if footer.gesture.isActive || footer.pressed != nil { return footerIntents(footer.mouseUp(pt(x, y), footerState(s)), s) }
            return timelineView.handle(e, s)
        case .mouseMoved(let x, let y):
            footer.mouseMoved(pt(x, y))
            return timelineView.handle(e, s)
        case .scroll: return timelineView.handle(e, s)
        }
    }

    /// Footer events as editor intents (MonitorPanelModel's callbacks as the Mac host wires them for the Program monitor).
    private mutating func footerIntents(_ events: [MonitorFooterEvent], _ s: EditorSnapshot) -> [EditorIntent] {
        var out: [EditorIntent] = []
        for ev in events {
            switch ev {
            case .action(let a): out += actionIntents(a)
            case .scrubBegan: out.append(.beginScrub)
            case .scrub(let t): out.append(.scrub(t))
            case .scrubEnded: out.append(.endScrub)
            case .previewMark(let h, let t):
                var st = footerState(s); st.previewMark(h, frame: t); markPreview = (st.markIn, st.markOut)
            case .previewRange(let i, let o):
                var st = footerState(s); st.previewRange(markIn: i, markOut: o); markPreview = (st.markIn, st.markOut)
            case .commitMark(let h):
                let st = footerState(s)
                markPreview = nil
                if h == .markIn, let i = st.markIn { out.append(.setMark(.markIn, i)) }
                if h == .markOut, let o = st.markOut { out.append(.setMark(.markOut, o)) }
            case .commitRange(let part):
                let st = footerState(s)
                markPreview = nil
                if let i = st.markIn, let o = st.markOut {
                    out.append(.setInOut(TimeRange(start: i, end: o), part == .newRange ? .newRange : .body))
                }
            case .commitTimecode:
                // shortcut: the legacy editor screen never opens the timecode field (SQDrawMonitor's panel does).
                break
            case .markMenu:
                // shortcut: the strip's right-click menu (Remove In / Out, Go to In / Out) needs the shell's popup
                // menu; the same commands are on the keys and the main menu. Upgrade when SQDrawShell hosts popups.
                break
            }
        }
        return out
    }

    private mutating func actionIntents(_ a: MonitorAction) -> [EditorIntent] {
        switch a {
        case .playPause: shuttle.stopped(); return [.playPause]
        case .stepBack: shuttle.stopped(); return [.step(-1)]
        case .stepForward: shuttle.stopped(); return [.step(1)]
        default: return [.monitor(a)]
        }
    }

    private mutating func keyIntents(_ k: InputKey, _ mods: InputModifiers, _ s: EditorSnapshot) -> [EditorIntent] {
        switch k {
        case .space: shuttle.stopped(); return [.playPause]
        case .left: shuttle.stopped(); return [.step(mods.contains(.shift) ? -5 : -1)]
        case .right: shuttle.stopped(); return [.step(mods.contains(.shift) ? 5 : 1)]
        case .home: return [.goToStart]
        case .end: return [.goToEnd]
        case .delete, .backspace: return s.selection.isEmpty ? [] : [.delete(ripple: mods.contains(.shift))]
        case .plus: timelineView.zoom(by: 1.25, anchorX: playheadX(s)); return []
        case .minus: timelineView.zoom(by: 0.8, anchorX: playheadX(s)); return []
        case .escape: return [.select([])]
        case .character(let c):
            let lower = Character(c.lowercased())
            if mods.contains(.command) {
                if lower == "z" { return [mods.contains(.shift) ? .redo : .undo] }
                if lower == "y" { return [.redo] }
                return []
            }
            switch lower {
            case "j": if !s.isPlaying { shuttle.stopped() }; return [.shuttle(shuttle.press(.j))]
            case "k": return [.shuttle(shuttle.press(.k))]
            case "l": if !s.isPlaying { shuttle.stopped() }; return [.shuttle(shuttle.press(.l))]
            case "i": return [.monitor(mods.contains(.shift) ? .goToIn : .markIn)]
            case "o": return [.monitor(mods.contains(.shift) ? .goToOut : .markOut)]
            case "m": return [.monitor(.addMarker)]
            case "v": timelineView.tool = .select; return []
            case "c": timelineView.tool = .razor; return []
            case "\\": timelineView.zoomToFit(frames: max(1, s.duration.frameIndex(frameDuration: s.frameDuration))); return []
            default: return []
            }
        default: return []
        }
    }

    private func playheadX(_ s: EditorSnapshot) -> Float { timelineView.x(of: s.playhead, frameDuration: s.frameDuration) }
}
