import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// A menu the header bar asks the host to open (built with `TimelineHeaderStrip.items`).
public enum TimelineHeaderMenu: Equatable, Sendable {
    /// The Fit popup: zoom, track height, Place Sequences as Clips.
    case fit
    /// Normal | Fast Cut.
    case editMode
}

public enum TimelineHeaderAction: Equatable, Sendable {
    /// Run through the host's command path (the same as the key): Snapping, Linked Selection, Add Marker, Fast Cut verbs.
    case command(EditorCommand)
    case selectTab(Timeline.ID)
    case closeTab(Timeline.ID)
    case moveTab(Timeline.ID, to: Int)
    /// Open `menu` with its top-left at `at` (window points).
    case menu(TimelineHeaderMenu, at: CGPoint)
}

/// What the header bar shows; the host builds it from the session and the panel once per frame (`make`).
public struct TimelineHeaderState: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var root: Timeline.ID
        /// "Main" or "Main > Inner".
        public var title: String
        public var active: Bool
        public init(root: Timeline.ID, title: String, active: Bool) { self.root = root; self.title = title; self.active = active }
    }
    public var tabs: [Tab] = []
    public var editMode: TimelineEditMode = .normal
    public var timecode = ""
    public var snapping = true
    public var linkedSelection = true
    /// Fast Cut verbs that can run on the selection (`EditorSession.fastCutCommandEnabled`), in `FastCutVerb.all` order.
    public var verbsEnabled: [Bool] = []
    public init() {}

    /// The Mac `EditorPanels.syncSequenceTabs` / `syncEditMode` / `syncFastCutStrip` and the header's timecode.
    @MainActor public static func make(session s: EditorSession, panel: TimelinePanel) -> TimelineHeaderState {
        var st = TimelineHeaderState()
        let tabs = s.sequenceTabs
        st.tabs = tabs.tabs.enumerated().map { i, tab in
            Tab(root: tab.root, title: tab.path.map { s.project.timeline($0)?.name ?? "?" }.joined(separator: " > "),
                active: i == tabs.activeIndex)
        }
        let t = s.activeTimeline
        st.editMode = t?.editMode ?? .normal
        if let t {
            // Formats the playhead like the Mac header (drop-frame only where the rate has it, the sequence's start).
            var f = TimecodeFormat(frameDuration: t.frameDuration)
            f.startFrame = t.timecodeStart.frameIndex(frameDuration: t.frameDuration)
            f.framesOnly = t.timecodeDisplay == .frames
            st.timecode = f.string(for: s.playhead, frameDuration: t.frameDuration)
        }
        st.snapping = panel.toolState.snapping
        st.linkedSelection = panel.toolState.linkedSelection
        if st.editMode == .magnetic { st.verbsEnabled = FastCutVerb.all.map { s.fastCutCommandEnabled($0.command) } }
        return st
    }
}

/// The header bar above the timeline and the Fast Cut strip under it, translated from the Mac `TimelineHeaderBar`,
/// `SequenceTabsView`, `TimelineModeChip` and `FastCutStrip` (geometry: `TimelineHeaderLayout`, shared with the Mac).
/// Hover tips: the Mac `Tooltip.text` strings through `HostHover` (TimelineTips.swift).
public struct TimelineHeaderStrip {
    public var theme: DrawTheme
    /// Text widths for the layout (tab pills, the capsule, the verbs); nil = an estimate (tests).
    public var atlas: GlyphAtlas?
    /// False hides the bar (the Color page shows its own header).
    public var visible = true

    public private(set) var state = TimelineHeaderState()
    public private(set) var scale: Float = 1
    /// Bar and Fast Cut strip in window points (strip .zero in Normal).
    public private(set) var bar = CGRect.zero
    public private(set) var strip = CGRect.zero
    public private(set) var frames = TimelineHeaderLayout.Frames(tabs: .zero, timecode: .zero, snap: .zero, link: .zero,
                                                                 marker: .zero, fit: .zero, editMode: .zero)
    public private(set) var tabRects: [(tab: CGRect, close: CGRect)] = []
    public private(set) var verbRects: [CGRect] = []
    public private(set) var badgeRect = CGRect.zero
    public private(set) var hovered: Control?

    public enum Control: Equatable, Sendable {
        case tab(Int), tabClose(Int), editMode, snap, link, marker, fit, verb(Int)
    }
    enum Press: Equatable { case control(Control), tab(Int, index: Int) }
    private(set) var press: Press?

    static let tabHeight: CGFloat = 24
    static let tabFont: CGFloat = 12
    static let tabMaxWidth: CGFloat = 240
    static let closeSize: CGFloat = 12
    static let glyph: CGFloat = 16
    static let bodyFont: CGFloat = 11
    static let verbHeight: CGFloat = 22

    public init(theme: DrawTheme = DrawTheme()) { self.theme = theme }

    public var isDragging: Bool { press != nil }

    func textWidth(_ s: String, _ size: CGFloat, face: Int = 0) -> CGFloat {
        guard let atlas else { return CGFloat(s.count) * size * 0.55 }
        return CGFloat(atlas.width(of: s, pixelSize: Float(size) * scale, face: face) / scale)
    }

    // MARK: Layout

    /// Lays the bar (and in Fast Cut the strip) out at the top of `rect` (device pixels); returns what is left below.
    public mutating func layout(_ rect: DrawRect, scale s: Float, state st: TimelineHeaderState) -> DrawRect {
        scale = s
        state = st
        guard visible else { bar = .zero; strip = .zero; return rect }
        let k = CGFloat(s)
        let area = CGRect(x: CGFloat(rect.x) / k, y: CGFloat(rect.y) / k, width: CGFloat(rect.w) / k, height: CGFloat(rect.h) / k)
        let h = TimelineHeaderLayout.height
        bar = CGRect(x: area.minX, y: area.minY, width: area.width, height: min(h, area.height))
        let fast = st.editMode == .magnetic
        strip = fast ? CGRect(x: area.minX, y: bar.maxY, width: area.width, height: min(h, max(area.height - bar.height, 0))) : .zero
        let modeWidth = TimelineModeMenu.chipWidth { textWidth($0, Self.bodyFont) }
        var f = TimelineHeaderLayout.frames(width: bar.width, height: bar.height, modeWidth: modeWidth)
        func shift(_ r: CGRect) -> CGRect { r == .zero ? r : r.offsetBy(dx: bar.minX, dy: bar.minY) }
        f = TimelineHeaderLayout.Frames(tabs: shift(f.tabs), timecode: shift(f.timecode), snap: shift(f.snap), link: shift(f.link),
                                        marker: shift(f.marker), fit: shift(f.fit), editMode: shift(f.editMode))
        frames = f
        layoutTabs()
        layoutStrip()
        let used = (Float(strip == .zero ? bar.maxY : strip.maxY) * s).rounded()
        return DrawRect(x: rect.x, y: used, w: rect.w, h: max(rect.y + rect.h - used, 0))
    }

    /// `SequenceTabsView.layoutTabs`: pills 24 high, text + 20 (+ the close mark with more than one tab), at most 240.
    private mutating func layoutTabs() {
        tabRects = []
        var x = frames.tabs.minX
        let y = (frames.tabs.minY + (frames.tabs.height - Self.tabHeight) / 2).rounded()
        let extra = state.tabs.count > 1 ? Self.closeSize + 4 : 0
        for t in state.tabs {
            let w = min(ceil(textWidth(t.title, Self.tabFont, face: atlas?.mediumFace ?? 0)) + 20 + extra, Self.tabMaxWidth)
            let r = CGRect(x: x, y: y, width: w, height: Self.tabHeight)
            tabRects.append((r, CGRect(x: r.maxX - 8 - Self.closeSize, y: r.minY + (r.height - Self.closeSize) / 2,
                                       width: Self.closeSize, height: Self.closeSize)))
            x = r.maxX
        }
    }

    /// `FastCutStrip.layout`: the badge 8 pt in, 12 pt to the first verb, 4 pt between verbs (icon + title buttons).
    private mutating func layoutStrip() {
        verbRects = []
        guard strip != .zero else { badgeRect = .zero; return }
        let bw = ceil(textWidth("Fast Cut", Self.bodyFont))
        badgeRect = CGRect(x: strip.minX + 8, y: strip.minY, width: bw, height: strip.height)
        var x = badgeRect.maxX + 12
        let y = (strip.minY + (strip.height - Self.verbHeight) / 2).rounded()
        for v in FastCutVerb.all {
            let w = ceil(10 + 14 + 4 + textWidth(v.title, Self.bodyFont) + 10)
            verbRects.append(CGRect(x: x, y: y, width: w, height: Self.verbHeight))
            x += w + 4
        }
    }

    public func contains(x: Float, y: Float) -> Bool {
        let p = CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale))
        return visible && (bar.contains(p) || strip.contains(p))
    }

    func control(at p: CGPoint) -> Control? {
        for (i, r) in tabRects.enumerated() where r.tab.contains(p) && r.tab.minX < frames.tabs.maxX {
            if state.tabs.count > 1, hovered == .tab(i) || hovered == .tabClose(i), r.close.insetBy(dx: -3, dy: -3).contains(p) {
                return .tabClose(i)
            }
            return .tab(i)
        }
        if frames.editMode.contains(p) { return .editMode }
        if frames.snap.contains(p) { return .snap }
        if frames.link.contains(p) { return .link }
        if frames.marker.contains(p) { return .marker }
        if frames.fit.contains(p) { return .fit }
        if let i = verbRects.firstIndex(where: { $0.contains(p) }) { return .verb(i) }
        return nil
    }

    // MARK: Drawing

    public func draw(_ cv: inout Canvas) {
        guard visible, bar.width > 0 else { return }
        cv.fill(bar, theme.panel)
        cv.fill(CGRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1), theme.separator)
        drawTabs(&cv)
        drawMode(&cv)
        // Timecode: 11 pt, label3, right-aligned.
        cv.draw(state.timecode, in: frames.timecode, fontSize: Self.bodyFont, theme.label3, align: .right)
        drawToggle(&cv, .snap, icon: .snap, on: state.snapping)
        drawToggle(&cv, .link, icon: .link, on: state.linkedSelection)
        drawToggle(&cv, .marker, icon: .marker, on: nil)
        // v9 flat popup: no fill until hovered, 11 pt label 10 pt in, 12 pt chevron 8 pt from the right.
        let fit = frames.fit
        if hovered == .fit || press == .control(.fit) { cv.fill(roundedRect: fit, radius: CGFloat(DrawTheme.Radius.small), theme.fillHover) }
        cv.draw("Fit", in: fit, fontSize: Self.bodyFont, theme.label, inset: 10)
        cv.draw(icon: .chevronDown, at: CGPoint(x: fit.maxX - 8 - 12, y: fit.midY - 6), size: 12, theme.label3)
        drawStrip(&cv)
    }

    /// Snap / Linked Selection on = accent glyph, off = dim glyph; hover fill only (`TimelineToolSlotButton.toggle`).
    private func drawToggle(_ cv: inout Canvas, _ c: Control, icon: SQIcon, on: Bool?) {
        let r: CGRect
        switch c { case .snap: r = frames.snap; case .link: r = frames.link; default: r = frames.marker }
        if hovered == c || press == .control(c) { cv.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), theme.fillHover) }
        let g = Self.glyph
        cv.draw(icon: icon, at: CGPoint(x: r.midX - g / 2, y: r.midY - g / 2), size: g, on == true ? theme.accent : theme.label2)
    }

    /// `SequenceTabsView.draw`: the active tab in label color over a 2 pt accent line (10 pt in), others label3 (label2
    /// on hover); the close mark on the hovered tab when there is more than one.
    private func drawTabs(_ cv: inout Canvas) {
        cv.saveGState()
        cv.clip(to: frames.tabs)
        let many = state.tabs.count > 1
        for (i, t) in state.tabs.enumerated() {
            let r = tabRects[i].tab
            let hover = hovered == .tab(i) || hovered == .tabClose(i)
            if t.active {
                cv.fill(roundedRect: CGRect(x: r.minX + 10, y: bar.maxY - 3, width: max(r.width - 20, 0), height: 2), radius: 1, theme.accent)
            }
            let reserve: CGFloat = many ? Self.closeSize + 4 : 0
            cv.draw(t.title, in: CGRect(x: r.minX + 10, y: r.minY, width: max(r.width - 20 - reserve, 0), height: r.height),
                    fontSize: Self.tabFont, t.active ? theme.label : (hover ? theme.label2 : theme.label3), face: cv.medium)
            if many, hover {
                cv.draw(icon: .close, at: tabRects[i].close.origin, size: Self.closeSize, hovered == .tabClose(i) ? theme.label : theme.label3)
            }
        }
        cv.restoreGState()
    }

    /// `TimelineModeChip.draw`: a capsule, accent tint for Fast Cut, quiet fill (hover lighter) for Normal.
    private func drawMode(_ cv: inout Canvas) {
        let r = frames.editMode
        guard r != .zero else { return }
        let fast = state.editMode == .magnetic
        let tint = fast ? theme.accent : theme.label2
        let skin = TimelineSkin(theme: theme)
        cv.fill(roundedRect: r, radius: r.height / 2, fast ? skin.accentTint : (hovered == .editMode ? theme.fillHover : theme.fill))
        let s = TimelineModeMenu.iconSize
        cv.draw(icon: TimelineModeMenu.icon(state.editMode), at: CGPoint(x: r.minX + TimelineModeMenu.leftPadding, y: r.midY - s / 2),
                size: s, tint)
        let lx = r.minX + TimelineModeMenu.leftPadding + s + TimelineModeMenu.iconToLabel
        cv.draw(TimelineModeMenu.chipLabel(state.editMode), in: CGRect(x: lx, y: r.minY, width: r.maxX - lx, height: r.height),
                fontSize: Self.bodyFont, tint)
    }

    /// `FastCutStrip`: the "Fast Cut" badge in accent, then one quiet button per verb (dim when it cannot run).
    private func drawStrip(_ cv: inout Canvas) {
        guard strip != .zero else { return }
        cv.fill(strip, theme.panel)
        cv.fill(CGRect(x: strip.minX, y: strip.maxY - 1, width: strip.width, height: 1), theme.separator)
        cv.draw("Fast Cut", in: badgeRect, fontSize: Self.bodyFont, theme.accent)
        for (i, v) in FastCutVerb.all.enumerated() where i < verbRects.count {
            let r = verbRects[i]
            let on = i < state.verbsEnabled.count && state.verbsEnabled[i]
            let pressed = press == .control(.verb(i))
            cv.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control),
                    on && pressed ? theme.fillPressed : (on && hovered == .verb(i) ? theme.fillHover : theme.fill))
            let tint = on ? theme.label : theme.label3
            cv.draw(icon: v.icon, at: CGPoint(x: r.minX + 10, y: r.midY - 7), size: 14, tint)
            cv.draw(v.title, in: CGRect(x: r.minX + 28, y: r.minY, width: r.width - 28, height: r.height), fontSize: Self.bodyFont, tint)
        }
    }

    // MARK: Input

    /// Handles one host event (device pixels); nil = not the bar's (the host passes it on).
    public mutating func handle(_ e: InputEvent) -> [TimelineHeaderAction]? {
        let k = CGFloat(scale)
        switch e {
        case .mouseDown(let x, let y, _):
            guard contains(x: x, y: y) else { return nil }
            return mouseDown(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        case .mouseDragged(let x, let y):
            guard press != nil else { return nil }
            return mouseDragged(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        case .mouseUp(let x, let y):
            guard press != nil else { return nil }
            return mouseUp(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        case .mouseMoved(let x, let y):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            hovered = contains(x: x, y: y) ? control(at: p) : nil
            // The close mark shows on hover: a second look finds it under the pointer.
            if case .tab(let i)? = hovered, state.tabs.count > 1, tabRects[i].close.insetBy(dx: -3, dy: -3).contains(p) { hovered = .tabClose(i) }
            guard contains(x: x, y: y) else { return nil }
            HostHover.current.offerTip(hovered.flatMap { TimelineTips.header($0, state: state) })
            return []
        case .scroll(let x, let y, _, _, _):
            return contains(x: x, y: y) ? [] : nil
        case .keyDown:
            return nil
        }
    }

    private mutating func mouseDown(_ p: CGPoint) -> [TimelineHeaderAction] {
        guard let c = control(at: p) else { return [] }
        switch c {
        case .tab(let i):
            // A tab selects at the press (the Mac `mouseDown`), then a drag reorders it.
            press = .tab(i, index: i)
            return [.selectTab(state.tabs[i].root)]
        case .editMode:
            // The capsule opens its menu at the press, under it.
            return [.menu(.editMode, at: CGPoint(x: frames.editMode.minX, y: frames.editMode.maxY))]
        case .fit:
            return [.menu(.fit, at: CGPoint(x: frames.fit.minX, y: frames.fit.maxY))]
        default:
            press = .control(c)
            return []
        }
    }

    private mutating func mouseDragged(_ p: CGPoint) -> [TimelineHeaderAction] {
        guard case .tab(let i, let index)? = press else { return [] }
        // Drag to reorder: the tab follows the pointer over its neighbors' centers.
        let target = tabRects.firstIndex { p.x < $0.tab.midX } ?? max(tabRects.count - 1, 0)
        guard target != index else { return [] }
        press = .tab(i, index: target)
        return [.moveTab(state.tabs[i].root, to: target)]
    }

    private mutating func mouseUp(_ p: CGPoint) -> [TimelineHeaderAction] {
        defer { press = nil }
        guard case .control(let c)? = press, control(at: p) == c else { return [] }
        switch c {
        case .tabClose(let i): return state.tabs.count > 1 ? [.closeTab(state.tabs[i].root)] : []
        case .snap: return [.command(.toggleSnapping)]
        case .link: return [.command(.toggleLinkedSelection)]
        case .marker: return [.command(.addMarker)]
        case .verb(let i):
            guard i < state.verbsEnabled.count, state.verbsEnabled[i] else { return [] }
            return [.command(FastCutVerb.all[i].command)]
        default: return []
        }
    }

    // MARK: Menus

    /// The rows of `menu`. The Fit popup: Fit first, then what the bar shows no buttons for (the Mac `fitItems`);
    /// rows run commands through `run`. The capsule: Normal | Fast Cut, the pick goes to `pickMode`.
    @MainActor
    public func items(_ menu: TimelineHeaderMenu, toolState: ToolState, fitsTracks: Bool, map: CommandMap = .current,
                      run: @escaping @MainActor (EditorCommand) -> Void,
                      togglePlaceClips: @escaping @MainActor () -> Void,
                      pickMode: @escaping @MainActor (TimelineEditMode) -> Void) -> [SQMenuItem] {
        switch menu {
        case .editMode:
            let current = state.editMode
            return TimelineModeMenu.items(current: current) { if $0 != current { pickMode($0) } }
        case .fit:
            func key(_ c: EditorCommand) -> String { map.binding(for: c).map { KeyboardListing.text(for: $0) } ?? "" }
            return [
                .header("Zoom"),
                SQMenuItem(title: "Fit Sequence", shortcut: key(.zoomFit)) { run(.zoomFit) },
                SQMenuItem(title: "Zoom In", shortcut: key(.zoomIn)) { run(.zoomIn) },
                SQMenuItem(title: "Zoom Out", shortcut: key(.zoomOut)) { run(.zoomOut) },
                .separator,
                .header("Track Height"),
                SQMenuItem(title: "Taller Tracks", shortcut: key(.allTracksTaller)) { run(.allTracksTaller) },
                SQMenuItem(title: "Shorter Tracks", shortcut: key(.allTracksShorter)) { run(.allTracksShorter) },
                SQMenuItem(title: "Fit All Tracks to Height", shortcut: key(.toggleFitTracks), isChecked: fitsTracks) { run(.toggleFitTracks) },
                .separator,
                SQMenuItem(title: "Place Sequences as Clips", isChecked: toolState.placeSequencesAsClips,
                           help: "A sequence dropped or inserted lands as its own clips, not one combined clip") { togglePlaceClips() },
            ]
        }
    }
}
