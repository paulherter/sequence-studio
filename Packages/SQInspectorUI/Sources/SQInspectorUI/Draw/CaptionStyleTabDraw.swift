import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit
import SQEditorSession
import SQText
import SQTranscribe
import SQUIKit

/// Caption offset as the Offset fields show it: percent of the canvas, Y up like Position (stored fraction, Y down).
enum CaptionOffsetDisplay {
    static func shown(_ stored: Double, isY: Bool) -> Double {
        ((isY ? -stored : stored) * 1000).rounded() / 10 + 0      // + 0: never "-0"
    }
    static func stored(_ shown: Double, isY: Bool) -> Double { (isY ? -shown : shown) / 100 + 0 }
}

/// The Style Kit's motion defaults as the Look tab edits them (shared by the Mac view and the draw panel).
enum CaptionKitMotion {
    /// What a Style Kit without motion defaults starts new motion effects with (the field's reset value).
    static let defaultSeconds = 0.5

    /// The motion duration in seconds as a kit time: whole milliseconds, 0.001...600 s. Nil for NaN / infinity / <= 0.
    static func time(seconds v: Double) -> Time? {
        guard v.isFinite, v > 0 else { return nil }
        return Time(Int64((min(v, 600) * 1000).rounded()), 1000)
    }
}

/// The Look tab of the Captions panel on the shared toolkit: `CaptionStyleTabView` translated. The scope switch (All
/// Captions / Selected), the caption track (two or more tracks), the Looks gallery, the Captions section (Animation,
/// Word Highlight), the shared text block (font, format, Fill, Outline, Background, Shadow; its Look row = the caption
/// looks), Position, the look buttons, the Style Kit section (Look to Kit, Animation from Text Clip, the brand tokens)
/// and the hint. Every edit goes through `EditorSession` as on the Mac, one undo step per gesture.
/// Coordinates: points, y down, (0, 0) = the tab's top-left.
@MainActor public final class CaptionStyleTabDraw {
    public let session: EditorSession
    public var theme = DrawTheme() { didSet { block.theme = theme; gallery.theme = theme } }
    public var size = CGSize(width: 320, height: 480) { didSet { block.width = size.width; gallery.width = size.width; clampScroll() } }
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime } {
        didSet { block.clock = clock; gallery.clock = clock }
    }
    public var onStatus: (@MainActor (String) -> Void)?
    /// Popups: the shell's menu at `anchor` (tab points).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// A swatch: the host opens the SQ color picker; `change(nil)` = the picker closed.
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// Asks for a name (Save Current as Look…); nil = canceled. Without it the suggested name is taken.
    public var askName: (@MainActor (_ title: String, _ initial: String, _ done: @escaping @MainActor (String?) -> Void) -> Void)? {
        didSet { block.askName = askName }
    }
    /// The caption preset a saved look keeps (the Mac `CaptionsPanelModel.selectedPreset`).
    public var segmentation: @MainActor () -> CaptionPreset = { .standard }
    public private(set) var scope: CaptionStyleScope = .all

    /// The same model and rows as the Text panel; its edits become caption style fields (`CaptionStyleEdit.fields`).
    public let inspectorModel = TextInspectorModel()
    public let block: TextBlockDraw
    public let gallery = LookGalleryDraw()

    public enum Section: String, CaseIterable, Sendable {
        case looks = "captions.look.gallery", captions = "captions.look.captions", position = "captions.look.position"
        case kit = "captions.look.kit"
        var title: String { switch self { case .looks: "Looks"; case .captions: "Captions"; case .position: "Position"; case .kit: "Style Kit" } }
        var defaultOpen: Bool { self == .captions || self == .position }
    }

    public enum Control: Hashable, Sendable {
        case scope(Int), track, header(Section), animation
        case karaoke, karaokeWell, karaokeKeep
        case vertical(Int), horizontal(Int), offset(isY: Bool), resetPosition
        case saveLook, updateLook, resetLook, kitLook, textAnim
        case brandFont(String), brandColor(String), motionDuration, motionCurve
    }

    // MARK: State (CaptionStyleTabView.refresh)

    private var hadSelection = false
    private var hasCaptions = false
    private var hasSelection = false
    private(set) var stateShown = false
    private var tracks: [(id: CaptionTrack.ID, name: String)] = []
    private var trackIndex: Int?
    private var trackEnabled = true
    private var resetLookEnabled = false
    private var lookIDs: [String] = []
    private var lookSelectedID: String?
    private var animationIDs: [String] = []
    private var animationSelectedID: String?
    private var position = CaptionPosition.default
    private var resetPositionEnabled = false
    private(set) var karaoke: KaraokeStyle?
    /// The highlight color the well shows (kept while the picker is open, applied when it closes).
    private var karaokeColor = RGBAColor(red: 1, green: 0.86, blue: 0.1)
    private var karaokeKeep = false
    private var textAnimEnabled = false
    private var hint = ""
    private var kit = StyleKit()

    /// The style the inspector last showed or sent (as `CaptionStyleEdit.displayStyle`): the baseline of the next diff.
    private var shownStyle: TextStyle?
    /// An inspector edit gesture is open (scrub, color drag): a reload from the session would fight it.
    private var inspectorGestureOpen = false
    /// The next inspector change starts a new undo step (first change after `onBeginEditing`).
    private var inspectorGestureFresh = true
    /// The next offset change starts a new undo step.
    private var offsetGestureFresh = true
    private var motionStarted = false
    /// Consecutive changes of one control within a second are one undo step (a color drag, stepper clicks).
    private var lastEdit: (control: Control, at: Double)?
    /// The brand color well whose picker is open: it holds its undo step however slow the changes come.
    private var pickerWell: Control?

    private var fields: [Control: ScrubFieldControl] = [:]
    private(set) var focused: Control?
    private(set) var open: [Section: Bool] = [:]
    private(set) var scrollY: CGFloat = 0
    private var hover: Control?
    private var pressed: Control?
    private enum Press { case control(Control), block, gallery }
    private var press: Press?
    private var counter = ClickCounter()
    /// Text widths measured with the canvas the panel drew last (segments, buttons); no atlas: 7 points per letter.
    private var widths: [String: CGFloat] = [:]

    public init(session: EditorSession) {
        self.session = session
        block = TextBlockDraw(model: inspectorModel)
        block.showsTextBox = false
        let d = UserDefaults.standard
        for s in Section.allCases { open[s] = d.object(forKey: TextBlockDraw.sectionKey(s.rawValue)) as? Bool ?? s.defaultOpen }
        for isY in [false, true] {
            var f = ScrubFieldControl(value: 0)
            f.range = -100 * CaptionPosition.maxOffset...100 * CaptionPosition.maxOffset
            f.step = 0.5; f.decimals = 1; f.unit = "%"; f.defaultValue = 0
            fields[.offset(isY: isY)] = f
        }
        var m = ScrubFieldControl(value: CaptionKitMotion.defaultSeconds)
        m.range = 0.05...600; m.step = 0.05; m.decimals = 2; m.unit = "s"; m.defaultValue = CaptionKitMotion.defaultSeconds
        fields[.motionDuration] = m
        inspectorModel.onBeginEditing = { [weak self] in self?.inspectorGestureOpen = true; self?.inspectorGestureFresh = true }
        inspectorModel.onEndEditing = { [weak self] in self?.inspectorGestureOpen = false }
        inspectorModel.onChange = { [weak self] style, _ in self?.inspectorChanged(style) }
        block.lookSource = { [weak self] in
            guard let self else { return .init(titles: [], ids: [], selected: nil, pick: { _ in }, add: nil) }
            return .init(titles: lookIDs.map { AnimationPresetName.title(for: $0) }, ids: lookIDs, selected: lookSelectedID,
                         pick: { [weak self] id in self?.edit(.look(id), .header(.captions)) },
                         add: { [weak self] in self?.saveLookClicked() })
        }
        block.onMenu = { [weak self] items, anchor, _ in
            guard let self else { return }
            onMenu?(items, anchor.offsetBy(dx: 0, dy: blockY - scrollY))
        }
        block.onPickColor = { [weak self] current, anchor, _, change in
            guard let self else { return }
            onPickColor?(current, anchor.offsetBy(dx: 0, dy: blockY - scrollY), change)
        }
        block.onNotice = { [weak self] s in self?.onStatus?(s) }
        gallery.onPick = { [weak self] look in self?.pickStyleLook(look) }
        refresh()
    }

    // MARK: Session to UI

    public func refresh() {
        let s = session
        hasCaptions = !s.captionItems.isEmpty
        hasSelection = !s.captionSelection.isEmpty
        // Selecting a caption (list or timeline) edits that caption; clearing the selection goes back to the track look.
        if hasSelection != hadSelection { scope = hasSelection ? .selected : .all; hadSelection = hasSelection }
        if scope == .selected && !hasSelection { scope = .all }
        let all = s.activeTimeline?.captionTracks ?? []
        tracks = all.map { ($0.id, $0.name.isEmpty ? "Captions" : $0.name) }
        trackIndex = s.currentCaptionTrack.flatMap { cur in all.firstIndex { $0.id == cur.id } }
        trackEnabled = s.captionSelection.isEmpty
        resetLookEnabled = s.selectedCaptionsHaveOverrides
        gallery.currentID = s.currentCaptionStyleLook?.id

        let state = s.captionStyleState(scope: scope)
        lookIDs = CaptionStyleEdit.builtInStyleIDs
        lookSelectedID = state?.baseID
        animationIDs = CaptionStyleEdit.builtInAnimationIDs
        animationSelectedID = state?.animationID
        if let st = state?.style {
            let shown = CaptionStyleEdit.displayStyle(st)
            shownStyle = shown
            // Not while the user drags a field: the session value is rounded and would pull the control away.
            if !inspectorGestureOpen, inspectorModel.style != shown {
                inspectorModel.load(style: shown, animations: AnimationSet(in: nil, out: nil))
            }
            // A box switched on in a caption is the caption pill (round ends, built-in padding), not a text clip's box.
            inspectorModel.seedLayerDefaults(background: CaptionPill.background(for: shown))
        }
        stateShown = state != nil

        let selectedIDs = s.captionSelection
        let own = scope == .selected && hasSelection
        position = own ? (s.captionItems.first { selectedIDs.contains($0.id) }.map(s.effectiveCaptionPosition) ?? s.captionPosition) : s.captionPosition
        resetPositionEnabled = s.captionItems.contains { $0.position != nil && (!own || selectedIDs.contains($0.id)) }
        for isY in [false, true] {
            guard var f = fields[.offset(isY: isY)], !f.isDragging, !f.isEditing else { continue }
            f.value = CaptionOffsetDisplay.shown(isY ? position.offsetY : position.offsetX, isY: isY)
            f.isEnabled = stateShown
            fields[.offset(isY: isY)] = f
        }

        karaoke = s.captionKaraoke
        if let k = karaoke {
            karaokeColor = CaptionKaraoke.color(k)
            karaokeKeep = k.keepSpoken
        }
        textAnimEnabled = hasCaptions && s.animationFromSelectedTextClip() != nil
        hint = !hasCaptions ? "Create captions first (Captions tab), then style them here."
            : scope == .all ? SQL10n.format("Changes every caption on %@, except that it releases captions with their own look.",
                                            s.currentCaptionTrack?.name ?? SQL10n.string("the track"))
            : "Changes only the selected captions. Reset to Track Look hands them back."
        kit = s.project.styleKit ?? StyleKit()
        if var f = fields[.motionDuration], !f.isDragging, !f.isEditing {
            f.value = kit.motion.map { Double($0.duration.value) / Double($0.duration.timescale) } ?? CaptionKitMotion.defaultSeconds
            fields[.motionDuration] = f
        }
        clampScroll()
    }

    // MARK: Layout

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.lg 16 below the stack, the
    // SQSegmented small height 22 and 12 pt label insets, the 38 × 20 swatch; upgrade when SQUIKit's tokens move into a
    // portable file.
    static let segmentHeight: CGFloat = 22
    static let segmentInset: CGFloat = 12
    static let iconSegment: CGFloat = 28
    static let swatch = CGSize(width: 38, height: 20)
    static let bottomPad: CGFloat = 16
    static let brandLabelWidth: CGFloat = 96
    static let motionFieldWidth: CGFloat = 64
    static let hintLine: CGFloat = 15
    static let verticalTitles = ["Top", "Middle", "Bottom"]
    static let horizontalIcons: [(SQIcon, String)] = [(.textAlignLeft, "Left"), (.textAlignCenter, "Center"), (.textAlignRight, "Right")]

    private var rh: CGFloat { ControlsGrid.rowHeight }
    private var valueEnd: CGFloat { max(size.width - ControlsGrid.trailing, ControlsGrid.valueX) }

    private func textWidth(_ s: String) -> CGFloat { widths[s] ?? CGFloat(s.count) * 7 }
    private func buttonWidth(_ s: String) -> CGFloat { widths["button:" + s] ?? CGFloat(s.count) * 7 + 20 }

    private enum Item {
        case control(Control, CGRect)
        case label(String, CGRect, right: Bool)
        case header(Section, CGRect, topLine: Bool)
        case strong(String, CGRect)
        case gallery(CGFloat)
        case block(CGFloat)
        case hint(CGRect)
    }

    private var hintLines = 2

    private(set) var blockY: CGFloat = 0

    private func layout() -> (items: [Item], height: CGFloat) {
        var out: [Item] = []
        var y: CGFloat = 0
        let x0 = ControlsGrid.valueX, ch = ControlsGrid.controlHeight
        func box(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat = ControlsGrid.controlHeight) -> CGRect {
            CGRect(x: x, y: y + ((rh - h) / 2).rounded(), width: max(w, 0), height: h)
        }
        func label(_ s: String) { out.append(.label(s, CGRect(x: ControlsGrid.labelX, y: y, width: max(x0 - ControlsGrid.labelX - ControlsGrid.gap, 0), height: rh), right: false)) }
        func header(_ s: Section, topLine: Bool = true) -> Bool {
            out.append(.header(s, CGRect(x: 0, y: y, width: size.width, height: rh), topLine: topLine))
            y += rh
            return open[s] ?? s.defaultOpen
        }

        // Scope switch, centered, 6 below.
        let scopeTitles = ["All Captions", "Selected"]
        let sw = scopeTitles.map { textWidth(SQL10n.string($0)) + 2 * Self.segmentInset }
        var sx = ((size.width - sw.reduce(0, +)) / 2).rounded()
        for i in scopeTitles.indices {
            out.append(.control(.scope(i), CGRect(x: sx, y: y, width: sw[i], height: Self.segmentHeight)))
            sx += sw[i]
        }
        y += Self.segmentHeight + 6

        if tracks.count >= 2 {
            label("Track"); out.append(.control(.track, box(x0, valueEnd - x0))); y += rh
        }
        if header(.looks, topLine: false) {
            out.append(.gallery(y)); y += gallery.height(forWidth: size.width)
        }
        if header(.captions) {
            label("Animation"); out.append(.control(.animation, box(x0, valueEnd - x0))); y += rh
            label("Word Highlight")
            out.append(.control(.karaoke, box(x0, 14, 14)))
            let wx = x0 + 14 + ControlsGrid.gap
            out.append(.control(.karaokeWell, box(wx, Self.swatch.width, Self.swatch.height)))
            let kx = wx + Self.swatch.width + ControlsGrid.gap
            out.append(.control(.karaokeKeep, box(kx, 14 + 4 + textWidth(SQL10n.string("Keep spoken")), 14)))
            y += rh
        }
        blockY = y
        if stateShown { out.append(.block(y)); y += block.height(.text) }
        if header(.position) {
            label("Vertical")
            let vw = Self.verticalTitles.map { textWidth(SQL10n.string($0)) + 2 * Self.segmentInset }
            var vx = x0
            for i in vw.indices { out.append(.control(.vertical(i), box(vx, vw[i], Self.segmentHeight))); vx += vw[i] }
            y += rh
            label("Align")
            for i in Self.horizontalIcons.indices {
                out.append(.control(.horizontal(i), box(x0 + CGFloat(i) * Self.iconSegment, Self.iconSegment, Self.segmentHeight)))
            }
            y += rh
            label("Offset")
            var ox = x0
            for (isY, name) in [(false, "X"), (true, "Y")] {
                let lw = textWidth(name)
                out.append(.label(name, CGRect(x: ox, y: y, width: lw, height: rh), right: true))
                ox += lw + ControlsGrid.gap
                out.append(.control(.offset(isY: isY), box(ox, ControlsGrid.valueWidth)))
                ox += ControlsGrid.valueWidth + ControlsGrid.gap
            }
            y += rh
            out.append(.control(.resetPosition, box(x0, buttonWidth(SQL10n.string("Reset to Kit Position")))))
            y += rh
        }
        // Save Current as Look…, Update Look, Reset to Track Look (Selected only).
        var bx = ControlsGrid.toggleX
        let looks: [(Control, String)] = [(.saveLook, "Save Current as Look…"), (.updateLook, "Update Look")]
            + (scope == .selected ? [(.resetLook, "Reset to Track Look")] : [])
        for (k, title) in looks {
            let w = buttonWidth(SQL10n.string(title))
            out.append(.control(k, box(bx, w)))
            bx += w + ControlsGrid.gap
        }
        y += rh
        if header(.kit, topLine: true) {
            for (k, title) in [(Control.kitLook, "Look to Kit"), (.textAnim, "Animation from Text Clip")] {
                out.append(.control(k, box(ControlsGrid.toggleX, buttonWidth(SQL10n.string(title))))); y += rh
            }
            out.append(.strong("Brand (Style Kit)", CGRect(x: ControlsGrid.toggleX, y: y, width: max(valueEnd - ControlsGrid.toggleX, 0), height: rh)))
            y += rh
            // The brand grid: a trailing label column of 96, then the control (`rebuildBrand`).
            let lx = ControlsGrid.toggleX, cx = lx + Self.brandLabelWidth + ControlsGrid.gap
            func brandLabel(_ s: String) { out.append(.label(s, CGRect(x: lx, y: y, width: Self.brandLabelWidth, height: rh), right: true)) }
            let popW = min(max(valueEnd - cx, 60), 160)
            for name in kit.fonts.keys.sorted() {
                brandLabel(SQL10n.format("%@ Font", SQL10n.string(AnimationPresetName.title(for: name))))
                out.append(.control(.brandFont(name), box(cx, popW))); y += rh
            }
            for name in kit.colors.keys.sorted() {
                brandLabel(SQL10n.format("%@ Color", SQL10n.string(AnimationPresetName.title(for: name))))
                out.append(.control(.brandColor(name), box(cx, Self.swatch.width, Self.swatch.height))); y += rh
            }
            brandLabel("Motion")
            out.append(.control(.motionDuration, box(cx, Self.motionFieldWidth)))
            let curveX = cx + Self.motionFieldWidth + ControlsGrid.gap
            out.append(.control(.motionCurve, box(curveX, min(max(valueEnd - curveX, 60), 140))))
            y += rh
        }
        let hh = CGFloat(hintLines) * Self.hintLine
        out.append(.hint(CGRect(x: ControlsGrid.toggleX, y: y, width: max(size.width - ControlsGrid.toggleX - ControlsGrid.trailing, 0), height: hh)))
        y += hh + Self.bottomPad
        _ = ch
        return (out, y)
    }

    private var contentHeight: CGFloat { layout().height }
    private var maxScroll: CGFloat { max(contentHeight - size.height, 0) }
    private func clampScroll() { scrollY = min(max(scrollY, 0), maxScroll) }

    /// Content point of a tab point.
    private func content(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + scrollY) }

    /// The frame of `k` in tab points (scroll applied); nil while it is not shown.
    func frame(_ k: Control) -> CGRect? {
        for item in layout().items {
            switch item {
            case .control(let c, let r) where c == k: return r.offsetBy(dx: 0, dy: -scrollY)
            case .header(let s, let r, _) where k == .header(s): return r.offsetBy(dx: 0, dy: -scrollY)
            default: continue
            }
        }
        return nil
    }

    private enum Hit { case control(Control), block(CGPoint), gallery(CGPoint) }

    private func hit(_ p: CGPoint) -> Hit? {
        let q = content(p), laid = layout()
        for item in laid.items {
            switch item {
            case .control(let k, let r):
                if CGRect(x: r.minX, y: r.minY - 2, width: r.width, height: r.height + 4).contains(q) { return .control(k) }
            case .header(let s, let r, _): if r.contains(q) { return .control(.header(s)) }
            case .block(let y):
                if q.y >= y, q.y < y + block.height(.text) { return .block(CGPoint(x: q.x, y: q.y - y)) }
            case .gallery(let y):
                if q.y >= y, q.y < y + gallery.height(forWidth: size.width) { return .gallery(CGPoint(x: q.x, y: q.y - y)) }
            default: break
            }
        }
        return nil
    }

    func control(at p: CGPoint) -> Control? { if case .control(let k)? = hit(p) { return k }; return nil }

    // MARK: Enabled state

    private func isEnabled(_ k: Control) -> Bool {
        switch k {
        case .scope(let i): i == 0 || hasSelection
        case .track: trackEnabled
        case .animation, .vertical, .horizontal, .offset: stateShown
        case .resetPosition: resetPositionEnabled
        case .karaoke: hasCaptions
        case .karaokeWell, .karaokeKeep: karaoke != nil
        case .saveLook, .updateLook, .kitLook: hasCaptions
        case .resetLook: resetLookEnabled
        case .textAnim: textAnimEnabled
        default: true
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        if c.atlas != nil { measure(c) }
        let laid = layout()
        c.saveGState()
        c.clip(to: CGRect(origin: .zero, size: size))
        c.translateBy(x: 0, y: -scrollY)
        for item in laid.items {
            switch item {
            case .control(let k, let r): drawControl(&c, k, r)
            case .label(let s, let r, let right):
                c.draw(SQL10n.string(s), in: r, fontSize: fs, t.label2, align: right ? .right : .left)
            case .strong(let s, let r): c.draw(SQL10n.string(s), in: r, fontSize: fs, t.label)
            case .header(let s, let r, let top): drawHeader(&c, s, r, topLine: top)
            case .gallery(let y):
                c.saveGState(); c.translateBy(x: 0, y: y); gallery.draw(&c); c.restoreGState()
            case .block(let y):
                c.saveGState(); c.translateBy(x: 0, y: y); block.draw(&c, part: .text); c.restoreGState()
            case .hint(let r):
                if c.atlas != nil { hintLines = max(c.wrap(SQL10n.string(hint), width: r.width, fontSize: fs).count, 1) }
                _ = c.drawWrapped(SQL10n.string(hint), in: r, fontSize: fs, lineHeight: Self.hintLine, t.label3)
            }
        }
        c.restoreGState()
    }

    private func measure(_ c: Canvas) {
        let fs = CGFloat(DrawTheme.TypeSize.body)
        for s in ["All Captions", "Selected", "Keep spoken", "X", "Y"] + Self.verticalTitles {
            let l = SQL10n.string(s)
            widths[l] = c.size(of: l, fontSize: fs).width.rounded(.up)
        }
        for s in ["Reset to Kit Position", "Save Current as Look…", "Update Look", "Reset to Track Look", "Look to Kit", "Animation from Text Clip"] {
            let l = SQL10n.string(s)
            widths["button:" + l] = InspectorDraw.buttonWidth(c, title: l)
        }
    }

    private func drawHeader(_ c: inout Canvas, _ s: Section, _ f: CGRect, topLine: Bool) {
        let t = theme, isOpen = open[s] ?? s.defaultOpen
        if topLine { c.fill(CGRect(x: 0, y: f.minY, width: size.width, height: 1), t.separator) }
        InspectorDraw.chevron(&c, in: CGRect(x: ControlsGrid.headerToggleX, y: f.minY, width: 12, height: f.height),
                              direction: isOpen ? .down : .right, hover == .header(s) ? t.label : t.label3, size: 8)
        c.draw(SQL10n.string(s.title), in: CGRect(x: ControlsGrid.headerLabelX, y: f.minY, width: max(size.width - ControlsGrid.headerLabelX, 0),
                                                  height: f.height), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label)
        c.fill(CGRect(x: 0, y: f.maxY - 1, width: size.width, height: 1), t.trackRowLine)
    }

    private func drawSegment(_ c: inout Canvas, _ r: CGRect, title: String?, icon: SQIcon?, on: Bool, k: Control, first: Bool, last: Bool) {
        let t = theme, enabled = isEnabled(k), radius = CGFloat(DrawTheme.Radius.small)
        if first { c.fill(roundedRect: r, radius: radius, t.fill) } else { c.fill(r.insetBy(dx: 0, dy: 0), t.fill) }
        if on || (hover == k && enabled) {
            c.fill(roundedRect: r.insetBy(dx: 1, dy: 1), radius: radius, on ? t.fillPressed : t.fillHover)
        }
        let ink = (on ? t.label : t.label2).alpha(enabled ? 1 : InspectorTokens.disabledAlpha)
        if let icon { c.draw(icon: icon, at: CGPoint(x: (r.midX - 5.5).rounded(), y: (r.midY - 5.5).rounded()), size: 11, ink) }
        if let title { c.draw(SQL10n.string(title), in: r, fontSize: CGFloat(DrawTheme.TypeSize.body), ink, align: .center) }
        _ = last
    }

    private func drawControl(_ c: inout Canvas, _ k: Control, _ r: CGRect) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body), en = isEnabled(k)
        switch k {
        case .scope(let i):
            drawSegment(&c, r, title: i == 0 ? "All Captions" : "Selected", icon: nil, on: (scope == .selected) == (i == 1), k: k,
                        first: i == 0, last: i == 1)
        case .vertical(let i):
            let on = CaptionPosition.Vertical.allCases.firstIndex(of: position.vertical) == i
            drawSegment(&c, r, title: Self.verticalTitles[i], icon: nil, on: on, k: k, first: i == 0, last: i == 2)
        case .horizontal(let i):
            let on = CaptionPosition.Horizontal.allCases.firstIndex(of: position.horizontal) == i
            drawSegment(&c, r, title: nil, icon: Self.horizontalIcons[i].0, on: on, k: k, first: i == 0, last: i == 2)
        case .track:
            let title = trackIndex.map { tracks[$0].name } ?? ""
            InspectorDraw.popup(&c, title: title, in: r, hovering: hover == k, open: false, enabled: en, t)
        case .animation:
            let title = animationSelectedID.map(AnimationPresetName.title(for:)) ?? SQL10n.string("Saved Animation")
            InspectorDraw.popup(&c, title: title, in: r, hovering: hover == k, open: false, enabled: en, t)
        case .karaoke:
            InspectorDraw.checkbox(&c, karaoke == nil ? .off : .on, box: r, hovering: hover == k, pressed: pressed == k, enabled: en, t)
        case .karaokeKeep:
            InspectorDraw.checkbox(&c, karaokeKeep && karaoke != nil ? .on : .off, box: CGRect(x: r.minX, y: r.minY, width: 14, height: 14),
                                   hovering: hover == k, pressed: pressed == k, enabled: en, t)
            c.draw(SQL10n.string("Keep spoken"), in: CGRect(x: r.minX + 18, y: r.minY - 4, width: max(r.width - 18, 0), height: 22),
                   fontSize: fs, t.label.alpha(en ? 1 : InspectorTokens.disabledAlpha))
        case .karaokeWell:
            let col = karaokeColor
            InspectorDraw.colorWell(&c, DrawColor(Float(col.red), Float(col.green), Float(col.blue), en ? 1 : InspectorTokens.disabledAlpha),
                                    in: r, hovering: hover == k && en, t)
        case .offset, .motionDuration:
            guard var f = fields[k] else { return }
            f.hovering = hover == k
            f.draw(&c, in: r, theme: t, focused: focused == k)
        case .resetPosition, .saveLook, .updateLook, .resetLook, .kitLook, .textAnim:
            InspectorDraw.button(&c, title: SQL10n.string(buttonTitle(k)), in: r, hovering: hover == k, pressed: pressed == k, enabled: en, t)
        case .brandFont(let name):
            InspectorDraw.popup(&c, title: kit.fonts[name] ?? "", in: r, hovering: hover == k, open: false, enabled: true, t)
        case .brandColor(let name):
            let col = kit.colors[name] ?? EffectColor(red: 1, green: 1, blue: 1, alpha: 1)
            InspectorDraw.colorWell(&c, DrawColor(Float(col.red), Float(col.green), Float(col.blue), Float(max(col.alpha, 0.15))),
                                    in: r, hovering: hover == k, t)
        case .motionCurve:
            let i = kit.motion?.curve ?? MotionCurve.premiereDefault.rawValue
            InspectorDraw.popup(&c, title: MotionCurve.titles.indices.contains(i) ? MotionCurve.titles[i] : "", in: r,
                                hovering: hover == k, open: false, enabled: true, t)
        case .header: break
        }
    }

    private func buttonTitle(_ k: Control) -> String {
        switch k {
        case .resetPosition: "Reset to Kit Position"
        case .saveLook: "Save Current as Look…"
        case .updateLook: "Update Look"
        case .resetLook: "Reset to Track Look"
        case .kitLook: "Look to Kit"
        case .textAnim: "Animation from Text Clip"
        default: ""
        }
    }

    // MARK: Pointer

    public func mouseMoved(to p: CGPoint?) {
        guard press == nil else { return }
        var blockP: CGPoint?, galleryP: CGPoint?
        hover = nil
        if let p, let h = hit(p) {
            switch h {
            case .control(let k): hover = k
            case .block(let q): blockP = q
            case .gallery(let q): galleryP = q
            }
        }
        block.mouseMoved(to: blockP, part: .text)
        gallery.mouseMoved(to: galleryP)
    }

    public func mouseDown(at p: CGPoint, modifiers m: InputModifiers = [], clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let h = hit(p)
        if let f = focused, h.map({ if case .control(let k) = $0 { return k == f }; return false }) != true { resignField(f) }
        if case .block? = h {} else { block.resignFocus() }
        guard let h, !m.contains(.secondary) else { press = nil; return }
        switch h {
        case .block(let q): press = .block; block.mouseDown(at: q, part: .text, clickCount: n)
        case .gallery(let q): press = .gallery; gallery.mouseDown(at: q)
        case .control(let k):
            guard isEnabled(k) else { press = nil; return }
            press = .control(k); pressed = k
            switch k {
            case .offset, .motionDuration:
                guard var f = fields[k] else { return }
                let ev = f.mouseDown(x: Float(p.x), clickCount: n)
                fields[k] = f
                focused = k
                apply(ev, k)
            case .track, .animation, .brandFont, .motionCurve:
                pressed = nil
                openMenu(k)
            default: break
            }
        }
    }

    public func mouseDragged(to p: CGPoint) {
        switch press {
        case .block?:
            let q = content(p)
            block.mouseDragged(to: CGPoint(x: q.x, y: q.y - blockY), part: .text)
        case .control(let k)?:
            guard case .offset = k, var f = fields[k] else {
                if k == .motionDuration, var f = fields[k] {
                    let ev = f.mouseDragged(x: Float(p.x), modifiers: []); fields[k] = f; apply(ev, k)
                }
                return
            }
            let ev = f.mouseDragged(x: Float(p.x), modifiers: [])
            fields[k] = f
            apply(ev, k)
        default: break
        }
    }

    public func mouseUp(at p: CGPoint) {
        defer { pressed = nil; press = nil; mouseMoved(to: p) }
        switch press {
        case .block?:
            let q = content(p)
            block.mouseUp(at: CGPoint(x: q.x, y: q.y - blockY), part: .text)
        case .gallery?:
            if case .gallery(let q)? = hit(p) { gallery.mouseUp(at: q) } else { gallery.mouseUp(at: CGPoint(x: -1, y: -1)) }
        case .control(let k)?:
            if case .offset = k, var f = fields[k] { let ev = f.mouseUp(); fields[k] = f; apply(ev, k); return }
            if k == .motionDuration, var f = fields[k] { let ev = f.mouseUp(); fields[k] = f; apply(ev, k); return }
            guard control(at: p) == k else { return }
            click(k)
        case nil: break
        }
    }

    private func click(_ k: Control) {
        let s = session
        switch k {
        case .scope(let i):
            scope = i == 1 ? .selected : .all
            lastEdit = nil
            refresh()
        case .header(let sec):
            let now = !(open[sec] ?? sec.defaultOpen)
            open[sec] = now
            UserDefaults.standard.set(now, forKey: TextBlockDraw.sectionKey(sec.rawValue))
            clampScroll()
        case .karaoke:
            if karaoke == nil { karaokeKeep = false }
            setKaraoke(on: karaoke == nil)
        case .karaokeKeep:
            karaokeKeep.toggle()
            setKaraoke(on: true)
        case .karaokeWell: pickKaraokeColor()
        case .vertical, .horizontal: positionChanged(k)
        case .resetPosition:
            lastEdit = nil
            _ = s.resetCaptionPositions(scope == .selected && !s.captionSelection.isEmpty ? s.captionSelection : s.allCaptionIDs)
            refresh()
        case .saveLook: saveLookClicked()
        case .updateLook: updateLookClicked()
        case .resetLook:
            lastEdit = nil
            if !s.resetSelectedCaptionsToTrackLook(), let e = s.lastError { onStatus?(e) }
            refresh()
        case .kitLook:
            let n = (s.project.styleKit?.looks.count ?? 0) + 1
            if s.saveCaptionLookToKit(name: "Look \(n)") != nil { onStatus?(SQL10n.format("Look saved in the Style Kit as \"Look %@\".", String(n))) }
            else { onStatus?(SQL10n.string("The look could not be saved in the Style Kit.")) }
            refresh()
        case .textAnim: textAnimClicked()
        case .brandColor(let name): pickBrandColor(name)
        default: break
        }
    }

    // MARK: Menus

    private func openMenu(_ k: Control) {
        guard let anchor = frame(k) else { return }
        var items: [SQMenuItem] = []
        switch k {
        case .track:
            items = tracks.enumerated().map { i, tr in
                SQMenuItem(title: tr.name, isChecked: i == trackIndex) { [weak self] in
                    self?.session.focusCaptionTrack(tr.id); self?.lastEdit = nil; self?.refresh()
                }
            }
        case .animation:
            items = animationIDs.map { id in
                SQMenuItem(title: AnimationPresetName.title(for: id), isChecked: id == animationSelectedID) { [weak self] in
                    self?.edit(.animation(id), .animation)
                }
            }
            if animationSelectedID.map({ !animationIDs.contains($0) }) ?? true {
                items.append(SQMenuItem(title: SQL10n.string("Saved Animation"), isEnabled: false, isChecked: true))
            }
        case .brandFont(let name):
            let current = kit.fonts[name]
            var families = inspectorModel.fontFamilies
            if let current, !families.contains(current) { families.insert(current, at: 0) }
            items = families.map { f in
                SQMenuItem(title: f, isChecked: f == current) { [weak self] in
                    self?.session.editStyleKit(name: "Brand Font") { $0.fonts[name] = f }
                    self?.refresh()
                }
            }
        case .motionCurve:
            let cur = kit.motion?.curve ?? MotionCurve.premiereDefault.rawValue
            items = MotionCurve.titles.enumerated().map { i, title in
                SQMenuItem(title: title, isChecked: i == cur) { [weak self] in
                    self?.session.editStyleKit(name: "Motion Curve") { k in
                        k.motion = MotionDefaults(duration: k.motion?.duration ?? Time(1, 2), curve: i)
                    }
                    self?.refresh()
                }
            }
        default: return
        }
        if !items.isEmpty { onMenu?(items, anchor) }
    }

    // MARK: Edits

    /// True when `k` changed again within a second: the change joins the previous undo step.
    private func continuing(_ k: Control) -> Bool {
        let now = clock()
        defer { lastEdit = (k, now) }
        guard let last = lastEdit, last.control == k else { return false }
        if pickerWell == k { return true }          // an open picker holds the step, however slow
        return now - last.at < 1
    }

    private func edit(_ f: CaptionStyleField, _ k: Control) {
        if !session.editCaptionStyle(f, scope: scope, continuesGesture: continuing(k)), let e = session.lastError { onStatus?(e) }
        refresh()
    }

    private func pickStyleLook(_ look: CaptionStyleLook) {
        lastEdit = nil
        if session.applyCaptionStyleLook(look) { onStatus?(SQL10n.format("Caption look: %@.", SQL10n.string(look.title))) }
        else { onStatus?(session.lastError ?? SQL10n.string("Create captions first, then pick a look.")) }
        refresh()
    }

    /// An edit in the shared text block: the difference to what was shown becomes caption fields, one undo step per gesture.
    private func inspectorChanged(_ new: TextStyle) {
        let new = CaptionStyleEdit.displayStyle(new)
        let old = shownStyle ?? new
        let fields = CaptionStyleEdit.fields(from: old, to: new)
        let joins = !inspectorGestureFresh
        inspectorGestureFresh = false
        guard !fields.isEmpty else { return }
        shownStyle = new
        lastEdit = nil
        if !session.editCaptionStyle(fields, scope: scope, continuesGesture: joins), let e = session.lastError { onStatus?(e) }
    }

    /// Any position control: the whole position is read back from the controls.
    private func positionChanged(_ k: Control) {
        var v = position.vertical, h = position.horizontal
        if case .vertical(let i) = k { v = CaptionPosition.Vertical.allCases[min(max(i, 0), 2)] }
        if case .horizontal(let i) = k { h = CaptionPosition.Horizontal.allCases[min(max(i, 0), 2)] }
        func stored(_ isY: Bool) -> Double { CaptionOffsetDisplay.stored(fields[.offset(isY: isY)]?.value ?? 0, isY: isY) }
        let p = CaptionPosition(vertical: v, horizontal: h, offsetX: stored(false), offsetY: stored(true))
        // One scrub / typed commit / arrow burst of an offset field is one undo step; a segment is its own.
        var isOffset = false
        if case .offset = k { isOffset = true }
        let joins = isOffset && !offsetGestureFresh
        if isOffset { offsetGestureFresh = false } else { lastEdit = nil }
        if scope == .selected, !session.captionSelection.isEmpty {
            _ = session.setCaptionItemPosition(session.captionSelection, p, continuesGesture: joins)   // their own position
        } else {
            session.setCaptionPosition(p, continuesGesture: joins)
        }
        refresh()
    }

    private func setKaraoke(on: Bool) {
        guard on else { _ = session.setCaptionKaraoke(nil); refresh(); return }
        let c = karaokeColor
        _ = session.setCaptionKaraoke(KaraokeStyle(red: c.red, green: c.green, blue: c.blue, keepSpoken: karaokeKeep))
        refresh()
    }

    /// One undo step per picker session: the well follows the picks, the highlight is set when the picker closes.
    private func pickKaraokeColor() {
        guard let pick = onPickColor, let anchor = frame(.karaokeWell) else { return }
        let c = karaokeColor
        pick(EffectColor(red: c.red, green: c.green, blue: c.blue, alpha: 1), anchor) { [weak self] color in
            guard let self else { return }
            guard let color else { if karaoke != nil { setKaraoke(on: true) }; return }
            karaokeColor = RGBAColor(red: color.red, green: color.green, blue: color.blue)
        }
    }

    private func pickBrandColor(_ name: String) {
        guard let pick = onPickColor, let anchor = frame(.brandColor(name)) else { return }
        let k = Control.brandColor(name)
        pickerWell = k; lastEdit = nil       // a new picker session starts a new undo step
        let cur = kit.colors[name] ?? EffectColor(red: 1, green: 1, blue: 1, alpha: 1)
        pick(cur, anchor) { [weak self] color in
            guard let self else { return }
            guard let color else { pickerWell = nil; return }
            let c = CaptionStyleEdit.effect(RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
            session.editStyleKit(name: "Brand Color", continuesGesture: continuing(k)) { $0.colors[name] = c }
            refresh()
        }
    }

    private func setMotionDuration(_ v: Double, continuing joins: Bool) {
        guard let t = CaptionKitMotion.time(seconds: v) else { return }
        session.editStyleKit(name: "Change Motion Duration", continuesGesture: joins) { k in
            let curve = k.motion?.curve ?? MotionCurve.premiereDefault.rawValue
            k.motion = MotionDefaults(duration: t, curve: curve)
        }
    }

    /// The scrub field's events: offsets re-read the whole position, the motion duration goes to the kit.
    private func apply(_ events: [ScrubFieldControl.Event], _ k: Control) {
        for e in events {
            switch e {
            case .begin:
                if k == .motionDuration { motionStarted = false } else { offsetGestureFresh = true }
            case .live(let v), .change(let v):
                setField(k, v)
                if k == .motionDuration { setMotionDuration(v, continuing: motionStarted); motionStarted = true }
                else { positionChanged(k) }
            case .end(let v), .cancel(let v):
                let changed = fields[k]?.value != v
                setField(k, v)
                if k == .motionDuration {
                    if !motionStarted || changed { setMotionDuration(v, continuing: motionStarted) }
                    motionStarted = false
                    refresh()
                } else if changed || offsetGestureFresh {
                    positionChanged(k)
                }
            }
        }
    }

    private func setField(_ k: Control, _ v: Double) {
        guard var f = fields[k] else { return }
        f.value = v
        fields[k] = f
    }

    private func resignField(_ k: Control) {
        guard var f = fields[k] else { focused = nil; return }
        let ev = f.resignFocus()
        fields[k] = f
        focused = nil
        apply(ev, k)
    }

    // MARK: Looks

    /// The current look becomes a saved look and the default for Create Captions.
    private func saveLookClicked() {
        guard session.currentCaptionLook() != nil else { return }
        let initial = SQL10n.format("Caption Look %@", String(CaptionLookLibrary.shared.looks.count + 1))
        guard let askName else { saveLook(named: initial); return }
        askName(SQL10n.string("Save as New Look"), initial) { [weak self] name in
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self?.saveLook(named: name)
        }
    }

    private func saveLook(named name: String) {
        guard let look = session.currentCaptionLook() else { return }
        let s = session, seg = segmentation()
        Task { @MainActor [weak self] in
            do {
                let id = try await CaptionLookLibrary.shared.save(name: name, look: look, segmentation: seg, makeDefault: true)
                _ = s.pushCaptionLook(look, id: id.uuidString)
                self?.onStatus?(SQL10n.string("Look saved as the default for Create Captions."))
            } catch { self?.onStatus?(SQL10n.string("The look could not be saved.")) }
            self?.refresh()
        }
    }

    /// Edit one caption (or all), then push: its look goes to every caption and into the default look.
    private func updateLookClicked() {
        guard let look = session.currentCaptionLook() else { return }
        guard let stored = CaptionLookLibrary.shared.defaultLook else {
            saveLook(named: SQL10n.format("Caption Look %@", String(CaptionLookLibrary.shared.looks.count + 1)))
            return
        }
        let s = session
        Task { @MainActor [weak self] in
            do {
                try await CaptionLookLibrary.shared.update(stored.id, look: look, segmentation: nil)
                _ = s.pushCaptionLook(look, id: stored.id.uuidString)
                self?.onStatus?(SQL10n.string("Look updated on every caption."))
            } catch { self?.onStatus?(SQL10n.string("The look could not be updated.")) }
            self?.refresh()
        }
    }

    private func textAnimClicked() {
        guard let a = session.animationFromSelectedTextClip(), var look = session.currentCaptionLook() else { return }
        look.animation = a
        let s = session, seg = segmentation(), n = CaptionLookLibrary.shared.looks.count + 1
        Task { @MainActor [weak self] in
            do {
                let id: UUID
                if let stored = CaptionLookLibrary.shared.defaultLook {
                    try await CaptionLookLibrary.shared.update(stored.id, look: look, segmentation: nil)
                    id = stored.id
                } else {
                    id = try await CaptionLookLibrary.shared.save(name: "Caption Look \(n)", look: look, segmentation: seg, makeDefault: true)
                }
                _ = s.pushCaptionLook(look, id: id.uuidString)
                self?.onStatus?(SQL10n.string("Animation taken from the text clip and saved in the default look."))
            } catch { self?.onStatus?(SQL10n.string("The look could not be saved.")) }
            self?.refresh()
        }
    }

    // MARK: Wheel, keys, frame tick, help

    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        guard maxScroll > 0 else { return false }
        scrollY = min(max(scrollY - dy, 0), maxScroll)
        return true
    }

    /// The text block's focused field first, then the focused number field (typing, arrows, Return / Esc).
    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        if block.key(k, modifiers: m) { return true }
        guard let f = focused, var fd = fields[f] else { return false }
        if k == .tab { resignField(f); return true }
        let ev = fd.key(k, modifiers: m, now: clock())
        fields[f] = fd
        apply(ev, f)
        return true
    }

    /// Per frame: ends arrow bursts; true while the gallery previews a look (the host keeps redrawing).
    public func tick() -> Bool {
        block.tick()
        for k in Array(fields.keys) {
            guard var f = fields[k] else { continue }
            let ev = f.tick(now: clock())
            fields[k] = f
            if !ev.isEmpty { apply(ev, k) }
        }
        return gallery.tick()
    }

    public func help(at p: CGPoint) -> String? {
        guard let h = hit(p) else { return nil }
        switch h {
        case .block(let q): return block.help(at: q, part: .text)
        case .gallery(let q): return gallery.help(at: q)
        case .control(let k):
            let tip: String? = switch k {
            case .scope(let i): i == 0 ? "All Captions" : "Selected Captions"
            case .track: "Caption Track"
            case .header(let s): (open[s] ?? s.defaultOpen) ? "Collapse \(s.title)" : "Expand \(s.title)"
            case .animation: "Caption Animation"
            case .karaoke: "Word Highlight"
            case .karaokeWell: "Highlight Color"
            case .karaokeKeep: "Keep Spoken Words Lit"
            case .vertical: "Caption Position"
            case .horizontal(let i): Self.horizontalIcons[i].1
            case .offset(let isY): isY ? "Offset Y" : "Offset X"
            case .resetPosition: "Reset to Kit Position"
            case .saveLook: "Save Look"
            case .updateLook: "Update Look"
            case .resetLook: "Reset to Track Look"
            case .kitLook: "Look to Kit"
            case .textAnim: "Animation from Text Clip"
            case .brandFont(let n): SQL10n.format("%@ Font", SQL10n.string(AnimationPresetName.title(for: n)))
            case .brandColor(let n): SQL10n.format("%@ Color", SQL10n.string(AnimationPresetName.title(for: n)))
            case .motionDuration: "Motion Duration"
            case .motionCurve: "Motion Curve"
            }
            return tip.map { SQL10n.string($0) }
        }
    }

    /// Typing in the text block or a number field (the host keeps IME on while it is open).
    public var isEditingText: Bool { focused.flatMap { fields[$0]?.isEditing } ?? false }
}
