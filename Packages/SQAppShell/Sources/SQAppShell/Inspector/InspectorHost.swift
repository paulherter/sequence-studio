import Foundation
import SQAppShell
import SQAudioFX
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQTimelineUI
import SQUIKit

/// Effect Controls of the shared UI (Windows app and Mac `SQ_SHARED_UI`): the shared-toolkit panel (SQInspectorUI
/// `EffectControlsDrawView`: rows, ruler, keyframe lanes) on the screen's inspector card, wired to the session exactly as
/// the Mac AppKit host wires it (App/Sources/EditorPanels.swift `wireEffectControls`), plus the popovers every panel
/// shares: the SQ color picker, the curve popover, the Multiband setup and the eyedropper (`AppScreenSampler`).
/// Coordinates: `frame` in points, events arrive in pixels.
@MainActor
public final class InspectorHost {
    public let model = EffectControlsModel()
    public let panel: EffectControlsDrawView
    /// The timeline's key lane source (`TimelinePanel.keyLanes` holds it weakly).
    public private(set) lazy var keyLanes = InspectorKeyLanes(model: model)
    private lazy var sections = ClipSectionsDraw(session: session)
    /// Per-track audio FX presets set in the track's audio controls (the Mac `clipSections.audioPresets`): the export
    /// mix and its stems use them, so they sound as playback.
    public var audioPresets: [Track.ID: TrackAudioPreset] { sections.audioPresets }
    /// Controls while a transition is selected (the Mac `EffectControlsContainerView` lays the transition view over the
    /// effects the same way).
    private lazy var transitions = TransitionControlsDraw(actions: TransitionControlsActions(session: session))
    private var showsTransition: Bool { transitions.shown != nil }
    /// A transition is selected: its controls cover the effects (nothing to drop an effect on).
    public var showsTransitionControls: Bool { showsTransition }
    private let session: EditorSession
    /// The card in points (window coordinates).
    public private(set) var frame: CGRect = .zero
    /// A press started in the panel: its drags and release go here too.
    public private(set) var isDragging = false
    /// The last press was in the panel: keys go here first.
    public private(set) var hasFocus = false
    private var dirty = true
    /// The open color picker popover (window points) and where its changes go.
    private var picker: ColorPickerControl?
    private var pickerFrame: CGRect = .zero
    private var pickerChange: (@MainActor (EffectColor?) -> Void)?
    private var pickerDragging = false
    /// An eyedropper is armed (the picker's or a text block row's): the next click anywhere samples the screen under
    /// the pointer and answers here (nil = canceled).
    private var sampleDone: (@MainActor (SQColorValue?) -> Void)?
    private var sampling: Bool { sampleDone != nil }
    /// The eyedropper is armed: the window shows the crosshair (`AppPointer`).
    public var isSampling: Bool { sampling }
    /// The loupe beside the pointer while the eyedropper samples (the Mac MagnifierView): screen pixels and the pointer.
    private var loupe: (grid: ColorLoupe, pointer: CGPoint)?
    /// The open curve popover (speed transition, motion Custom curve) and its frame (window points).
    private var ease: EasingPopoverDraw?
    private var easeFrame: CGRect = .zero
    private var savedCurves: [EasingCurve] = []
    /// The open Multiband Compressor setup (the Mac floating window): stays open while the user plays or edits elsewhere,
    /// takes keys after a press inside it. Frame in window points.
    private var multiband: MultibandEditorDraw?
    private var multibandFrame: CGRect = .zero
    private var multibandActive = false
    private var multibandDragging = false
    private weak var shell: ShellHost?
    private weak var menus: MenuController?
    private let sampler: any AppScreenSampler
    /// Shows the Graphics panel (the app's dock).
    public var onShowGraphics: (() -> Void)?
    /// The window's Library keystones (the Keystones card's model): the Intro / Outro popups offer them, Custom saves to
    /// them (the Mac `clipSections.keystones`).
    public weak var keystones: KeystonesPanelModel? { didSet { sections.keystones = keystones } }
    /// Save as Preset… of the selected transition: the app asks for the name and saves it to the Library.
    public var onSaveTransitionPreset: (() -> Void)?

    public init(session: EditorSession, menus: MenuController, shell: ShellHost, sampler: any AppScreenSampler) {
        self.session = session
        self.sampler = sampler
        self.shell = shell
        self.menus = menus
        panel = EffectControlsDrawView(model: model)
        // Edits, gestures, scrubs and the model's sync on every session change (shared with hosts without this panel).
        EffectControlsBinding.connect(model, to: session)
        InspectorHooks.connect(model: model, session: session, shell: shell) { [weak self] in self?.dirty = true }
        // Popups and right-click menus: the shell's one menu system, anchored in window points.
        panel.onMenu = { [weak self, weak menus] items, anchor in
            guard let self, let menus else { return }
            let r = anchor.offsetBy(dx: frame.minX, dy: frame.minY)
            menus.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r)
        }
        // Color wells: the shared SQ color picker as a popover under the well.
        panel.rowsPanel.onPickColor = { [weak self] color, anchor, change in
            self?.openPicker(color, anchor: anchor.offsetBy(dx: self?.frame.minX ?? 0, dy: self?.frame.minY ?? 0), change)
        }
        // The curve popover (speed transition at the playhead, a motion effect's Curve): presets from the shared store.
        panel.rowsPanel.onEaseCurve = { [weak self] source, anchor in
            guard let self else { return }
            openEase(source, anchor: anchor.offsetBy(dx: frame.minX, dy: frame.minY))
        }
        // "Edit Custom Setup" of a Multiband Compressor: the setup panel above the window.
        panel.rowsPanel.onMultibandEditor = { [weak self] effect in self?.openMultiband(effect) }
        // Key-tool dialogs and the R29 question: the shell's SQ dialog with a form, answered asynchronously.
        panel.onPrompt = { [weak shell] prompt, done in
            guard let shell else { return done(nil) }
            Task { @MainActor in done(await Self.ask(prompt, shell)) }
        }
        panel.rowsPanel.confirmRemoveKeyframes = { [weak shell] title, remove in
            guard let shell else { return }
            Task { @MainActor in if await Self.ask(.removeKeyframes(title), shell) != nil { remove() } }
        }
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            guard let self else { return }
            sections.sync(change)
            if change.contains(.selection) || change.contains(.project) { transitions.show(transitions.actions.shown()) }
            if multiband?.sync() == false { closeMultiband() }
            dirty = true
        }
        // The clip's content section (Audio, Shape, Color Matte): placed by the panel like the Mac skeleton.
        panel.rowsPanel.clipSections = sections
        // A text clip's Arrange buttons move it in the frame (one Transform undo step); notices go to the status line.
        sections.onAlignToFrame = { [weak self] a in
            guard let self else { return }
            model.alignText(a, session: self.session)
        }
        sections.onNotice = { [weak shell] m in shell?.onStatus?(m) }
        // The Graphic section's item picker: Controls shows the picked item (or the whole graphic) again.
        // Edit in Graphics: the app brings the Graphics panel to the front.
        sections.onEditGraphics = { [weak self] in self?.onShowGraphics?() }
        sections.onGraphicItemChange = { [weak self] in
            guard let self else { return }
            model.sync(with: session, change: [.selection])
            dirty = true
        }
        // Save as New Look, Rename Look, Save Animation: the shell's name field dialog.
        sections.askName = { [weak shell] title, initial, done in
            guard let shell else { return done(initial) }
            Task { @MainActor in done(await Self.ask(.name(title, initial: initial), shell)?.first) }
        }
        // Saved title templates in the Look popup ("<name> (Template)"): the text takes their style and animation.
        sections.useTemplates(from: LibraryStores.presetStore)
        wireTransitions()
        // The drawn eyedroppers outside the picker (text block Appearance rows in Controls, Text and Graphics panels).
        ScreenColorSampler.begin = { [weak self] done in self?.beginSampling(done) }
        // Animate > Add Keyframe and its key: the focused Effect Controls property (the Mac AppController+TimelineOps).
        // The facts the Controls rules read (Toggle Graph Editor, Ease, Hold): the Mac `effectModel.clip` / `selection`.
        shell.factProviders.append { [model, panel] f in
            f.effectControlsClip = model.clip != nil
            f.effectSelectionEmpty = model.selection.isEmpty
            f.effectCanCopy = model.canCopyFocused
            f.effectCanCut = model.canCutFocused
            f.effectCanPaste = model.canPasteFocused
            f.effectCanDelete = !model.selection.isEmpty || model.selectedSection.map(model.canDeleteSection) == true
            if panel.rowsPanel.focusedField != nil { f.textEditing = true }
        }
        let next = shell.onCommand
        shell.onCommand = { [weak self, weak shell] c in
            // Delete with Effect Controls focused removes the selected keys, effect or mask, never the timeline clip.
            if c == .delete || c == .rippleDelete, let self, shell?.focus == .effectControls,
               !model.selection.isEmpty || model.selectedSection.map(model.canDeleteSection) == true {
                model.deleteSelectionOrEffect()
                return true
            }
            guard let self else { return next?(c) == true }
            switch c {
            case .addKeyframe: shell?.onStatus?(addKeyframeAtPlayhead() ?? "")
            case .toggleGraphEditor:
                // Clip > Graph Editor: Effect Controls shows and flips its graph (the Mac `execute`).
                shell?.dock.show(.effectControls)
                model.toggleGraphEditor()
            case .easyEase, .easeIn, .easeOut:
                let curve: EasingCurve = c == .easyEase ? .easeInOut : c == .easeIn ? .easeIn : .easeOut
                let side: EaseSide = c == .easyEase ? .both : c == .easeIn ? .in : .out
                if !model.selection.isEmpty { model.applyEasing(curve, side: side) }
                else if !session.easeSpeedPointAtPlayhead(curve, side: side) {      // no keys selected: the speed point at the playhead
                    shell?.onStatus?(SQL10n.string("Select keyframes in Effect Controls, or put the playhead on a speed point."))
                }
            case .toggleHoldInterpolation:
                if model.selection.isEmpty { shell?.onStatus?(SQL10n.string("Select keyframes in Effect Controls first.")) } else { model.toggleHold() }
            default: return next?(c) == true
            }
            return true
        }
    }

    /// Adds a key at the playhead to the focused property. Nil when it worked, else the status line.
    public func addKeyframeAtPlayhead() -> String? {
        guard let p = model.focusedProperty else { return "Select a property in Effect Controls first." }
        if model.addKeyAtPlayhead(p) == .unavailable { return "There is already a keyframe here, or the playhead is outside the clip." }
        return nil
    }

    /// The transition controls on the shell's menu, color picker, curve popover and status line.
    private func wireTransitions() {
        transitions.onMenu = { [weak self, weak menus] items, anchor in
            guard let self, let menus else { return }
            let r = anchor.offsetBy(dx: frame.minX, dy: frame.minY)
            menus.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r)
        }
        transitions.onPickColor = { [weak self] color, anchor, change in
            self?.openPicker(color, anchor: anchor.offsetBy(dx: self?.frame.minX ?? 0, dy: self?.frame.minY ?? 0), change)
        }
        transitions.onEaseCurve = { [weak self] source, anchor in
            guard let self else { return }
            openEase(source, anchor: anchor.offsetBy(dx: frame.minX, dy: frame.minY))
        }
        transitions.onSavePreset = { [weak self] in self?.onSaveTransitionPreset?() }
        transitions.actions.onStatus = { [weak shell] m in shell?.onStatus?(m) }
        transitions.show(transitions.actions.shown())
    }

    /// `KeyToolsDialogs.run` on the shell: one field row per prompt field; the typed texts in order, nil when canceled.
    public static func ask(_ p: KeyToolPrompt, _ shell: ShellHost) async -> [String]? {
        let d = ShellDialog(p.title, informative: p.informative)
        if !p.fields.isEmpty {
            d.form = ShellForm(p.fields.enumerated().map { .field(id: "f\($0.offset)", label: $0.element.label, value: $0.element.text) })
        }
        d.addButton(p.confirm, role: .default)
        d.addButton("Cancel", role: .cancel)
        guard await shell.ask(d) == .first else { return nil }
        return p.fields.indices.map { d.form?.text("f\($0)") ?? "" }
    }

    // MARK: Color picker popover

    /// The color picker popover for another panel (Graphics); `anchor` in window points.
    public func pickColor(_ color: EffectColor, anchor: CGRect, _ change: @escaping @MainActor (EffectColor?) -> Void) {
        openPicker(color, anchor: anchor, change)
    }

    /// The app's one Graphics editor: Controls > Graphic edits its selected items (the Mac `clipSections.graphicsEditor`).
    public func useGraphicsEditor(_ e: GraphicsEditor) { sections.graphicsEditor = e }

    /// The Graphics panel picked other layers: Controls shows them.
    public func graphicsSelectionChanged() {
        model.sync(with: session, change: [.selection])
        sections.graphicItemsChanged()
        dirty = true
    }

    private func openPicker(_ color: EffectColor, anchor: CGRect, _ change: @escaping @MainActor (EffectColor?) -> Void) {
        closePicker()
        let v = SQColorValue(r: color.red, g: color.green, b: color.blue, a: color.alpha)
        let p = ColorPickerControl(value: v, showsEyedropper: true, recents: SQColorRecents.load())
        picker = p
        pickerChange = change
        let visible = CGRect(origin: .zero, size: shell?.size ?? CGSize(width: 1280, height: 800))
        pickerFrame = p.frame(anchor: anchor, in: visible)
    }

    /// The curve popover for any ease source; `anchor` in window points (the timeline opens it for speed and keystone curves).
    public func openEase(_ source: any EaseCurveSource, anchor: CGRect) {
        closePicker()
        let e = EasingPopoverDraw(source: source)
        e.saved = savedCurves
        e.onSave = { [weak self] shape, name in
            Task { @MainActor in
                guard let curve = try? await EasingPresets.save(shape, name: name, in: LibraryStores.presetStore) else { return }
                self?.savedCurves.append(curve)
                self?.ease?.saved = self?.savedCurves ?? []
                self?.dirty = true
            }
        }
        ease = e
        let visible = CGRect(origin: .zero, size: shell?.size ?? CGSize(width: 1280, height: 800))
        easeFrame = e.frame(anchor: anchor, in: visible)
        Task { @MainActor [weak self] in
            let list = await EasingPresets.load(LibraryStores.presetStore)
            self?.savedCurves = list
            self?.ease?.saved = list
            self?.dirty = true
        }
    }

    // MARK: Multiband setup

    private func openMultiband(_ effect: ClipEffect.ID) {
        if multiband?.effect == effect { multibandActive = true; return }
        closeMultiband()
        let m = MultibandEditorDraw(effect: effect, model: model)
        m.onMenu = { [weak self] items, anchor in
            guard let self, let menus else { return }
            let r = anchor.offsetBy(dx: multibandFrame.minX, dy: multibandFrame.minY)
            menus.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r)
        }
        m.onClose = { [weak self] in self?.closeMultiband() }
        let visible = CGRect(origin: .zero, size: shell?.size ?? CGSize(width: 1280, height: 800))
        multibandFrame = CGRect(x: ((visible.width - m.size.width) / 2).rounded(), y: max(((visible.height - m.size.height) / 2).rounded(), 6),
                                width: m.size.width, height: m.size.height)
        multiband = m
        multibandActive = true
        m.startMeters()
        dirty = true
    }

    private func closeMultiband() {
        guard let m = multiband else { return }
        m.resignFocus()
        m.stopMeters()
        multiband = nil
        multibandActive = false
        multibandDragging = false
        dirty = true
    }

    /// Routes one event to the Multiband panel: presses, drags and the wheel inside it, keys after a press inside it.
    /// Everything outside goes on to the panels (the setup stays open while the user plays or scrubs).
    private func handleMultiband(_ m: MultibandEditorDraw, _ e: InputEvent, scale: Float) -> Bool {
        func local(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: CGFloat(x / scale) - multibandFrame.minX, y: CGFloat(y / scale) - multibandFrame.minY)
        }
        func inside(_ q: CGPoint) -> Bool { CGRect(origin: .zero, size: multibandFrame.size).contains(q) }
        switch e {
        case .mouseDown(let x, let y, _):
            let q = local(x, y)
            guard inside(q) else { multibandActive = false; m.resignFocus(); return false }
            multibandActive = true; multibandDragging = true
            m.mouseDown(at: q)
        case .mouseDragged(let x, let y):
            guard multibandDragging else { return false }
            m.mouseDragged(to: local(x, y))
        case .mouseUp(let x, let y):
            guard multibandDragging else { return false }
            multibandDragging = false
            m.mouseUp(at: local(x, y))
        case .mouseMoved(let x, let y):
            let q = local(x, y)
            m.mouseMoved(to: inside(q) ? q : nil)
            return inside(q)
        case .scroll(let x, let y, _, let dy, let mods):
            let q = local(x, y)
            guard inside(q) else { return false }
            _ = m.scroll(at: q, dy: CGFloat(dy / scale), precise: true, modifiers: mods)
        case .keyDown(let k, let mods):
            guard multibandActive else { return false }
            guard m.key(k, modifiers: mods) else { return false }
        }
        dirty = true
        return true
    }

    private func closePicker() {
        ease = nil
        endSampling(nil)
        guard var p = picker else { return }
        if p.commitRecent() { SQColorRecents.remember(p.value) }
        picker = nil
        pickerDragging = false
        let change = pickerChange
        pickerChange = nil
        change?(nil)
        dirty = true
    }

    private func pickerChanged(_ p: ColorPickerControl) {
        let c = p.value.rgb
        pickerChange?(EffectColor(red: c.r, green: c.g, blue: c.b, alpha: p.value.a))
        dirty = true
    }

    /// Draws the open picker above every panel (call after the panels, before the shell's menus).
    public func drawPopover(_ c: inout Canvas, theme: DrawTheme) {
        if let m = multiband {
            m.theme = theme
            c.saveGState()
            c.translateBy(x: multibandFrame.minX, y: multibandFrame.minY)
            m.draw(&c)
            c.restoreGState()
        }
        if let e = ease {
            c.saveGState()
            c.translateBy(x: easeFrame.minX, y: easeFrame.minY)
            e.draw(&c, theme: theme)
            c.restoreGState()
        }
        if let p = picker {
            c.saveGState()
            c.translateBy(x: pickerFrame.minX, y: pickerFrame.minY)
            p.draw(&c, theme: theme)
            c.restoreGState()
        }
        if sampling, let l = loupe {
            let k = CGFloat(max(c.scale, 0.01))
            l.grid.draw(&c, pointer: l.pointer, in: CGRect(x: 0, y: 0, width: CGFloat(c.list.width) / k, height: CGFloat(c.list.height) / k),
                        theme: theme)
        }
    }

    /// Routes one event (pixels) to the open picker: everything while it is open; a press outside closes it (and is
    /// taken, like a transient popover), Esc closes it.
    public func handlePopover(_ e: InputEvent, scale: Float) -> Bool {
        if sampling { return sample(e, scale: scale) }
        if let ease { return handleEase(ease, e, scale: scale) }
        guard var p = picker else {
            if let m = multiband { return handleMultiband(m, e, scale: scale) }
            return false
        }
        func local(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: CGFloat(x / scale) - pickerFrame.minX, y: CGFloat(y / scale) - pickerFrame.minY)
        }
        var out = ColorPickerControl.Outcome.none
        switch e {
        case .mouseDown(let x, let y, _):
            let q = local(x, y)
            guard CGRect(origin: .zero, size: pickerFrame.size).contains(q) else { closePicker(); return true }
            out = p.mouseDown(at: q)
            pickerDragging = true
        case .mouseDragged(let x, let y):
            guard pickerDragging else { return true }
            out = p.mouseDragged(to: local(x, y))
        case .mouseUp:
            p.mouseUp()
            pickerDragging = false
        case .mouseMoved(let x, let y):
            p.mouseMoved(to: local(x, y))
            picker = p
            return false
        case .scroll: return true
        case .keyDown(let k, let m):
            let r = p.key(k, modifiers: m)
            if !r.taken, k == .escape || k == .enter { closePicker(); return true }
            out = r.outcome
        }
        picker = p
        if out == .changed { pickerChanged(p) }
        if out == .eyedropper {
            beginSampling { [weak self] c in
                guard let self, let c, var p = picker else { return }
                if p.pick(c) == .changed { picker = p; pickerChanged(p) } else { picker = p }
            }
        }
        return true
    }

    /// Arms the eyedropper: the crosshair and loupe follow the pointer until a press samples or Esc cancels.
    public func beginSampling(_ done: @escaping @MainActor (SQColorValue?) -> Void) {
        endSampling(nil)
        if let own = sampler.ownEyedropper { own(done); return }
        sampleDone = done
        shell?.onStatus?(SQL10n.string("Click anywhere to pick a color. Esc cancels."))
    }

    private func endSampling(_ color: SQColorValue?) {
        guard let done = sampleDone else { return }
        sampleDone = nil
        loupe = nil
        done(color)
    }

    /// The armed eyedropper: a press anywhere takes the screen color under the pointer, Esc disarms; everything else
    /// is held back so the click does not also hit a panel.
    private func sample(_ e: InputEvent, scale: Float) -> Bool {
        switch e {
        case .mouseDown:
            endSampling(sampler.colorUnderPointer())
            dirty = true
        case .keyDown(let k, _): if k == .escape { endSampling(nil) }
        case .mouseMoved(let x, let y):
            let k = max(scale, 0.01)
            loupe = sampler.loupeUnderPointer().map { ($0, CGPoint(x: CGFloat(x / k), y: CGFloat(y / k))) }
            return false
        default: break
        }
        return true
    }

    private func handleEase(_ pop: EasingPopoverDraw, _ e: InputEvent, scale: Float) -> Bool {
        func local(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: CGFloat(x / scale) - easeFrame.minX, y: CGFloat(y / scale) - easeFrame.minY)
        }
        dirty = true
        switch e {
        case .mouseDown(let x, let y, _):
            let q = local(x, y)
            guard CGRect(origin: .zero, size: easeFrame.size).contains(q) else { closePicker(); return true }
            pickerDragging = true
            pop.mouseDown(at: q)
        case .mouseDragged(let x, let y): if pickerDragging { pop.mouseDragged(to: local(x, y)) }
        case .mouseUp(let x, let y): if pickerDragging { pop.mouseUp(at: local(x, y)) }; pickerDragging = false
        case .mouseMoved(let x, let y): pop.mouseMoved(to: local(x, y)); return false
        case .scroll(let x, let y, let dx, let dy, _): _ = pop.scroll(at: local(x, y), dx: CGFloat(dx / scale), dy: CGFloat(dy / scale))
        case .keyDown(let k, let m): if !pop.key(k, modifiers: m), k == .escape { closePicker() }
        }
        return true
    }

    /// Places the panel on the card (`card` in pixels).
    public func layout(_ card: DrawRect, scale: Float) {
        frame = CGRect(x: CGFloat(card.x / scale), y: CGFloat(card.y / scale), width: CGFloat(card.w / scale),
                       height: CGFloat(card.h / scale))
        panel.size = frame.size
        transitions.size = frame.size
        if dirty { panel.relayout(); dirty = false }
        panel.tick()
        transitions.tick()
        _ = multiband?.tick()
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        guard frame.width > 0, frame.height > 0 else { return }
        panel.theme = theme
        transitions.theme = theme
        c.saveGState()
        c.clip(to: frame)
        c.translateBy(x: frame.minX, y: frame.minY)
        if showsTransition { transitions.draw(&c) } else { panel.draw(&c) }
        c.restoreGState()
    }

    public func contains(x: Float, y: Float, scale: Float) -> Bool {
        frame.contains(CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)))
    }

    /// Routes one event in pixels; true when the panel took it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        switch e {
        case .mouseDown(let x, let y, _):
            hasFocus = contains(x: x, y: y, scale: scale)
            guard hasFocus else { return false }
            isDragging = true
        case .mouseUp: guard isDragging else { return false }; isDragging = false
        case .mouseDragged: guard isDragging else { return false }
        case .scroll(let x, let y, _, _, _): guard contains(x: x, y: y, scale: scale) else { return false }
        case .mouseMoved(let x, let y): guard isDragging || contains(x: x, y: y, scale: scale) else { return false }
        case .keyDown: guard hasFocus else { return false }
        }
        let took = showsTransition ? transitions.handle(e, scale: scale, origin: frame.origin)
            : panel.handle(e, scale: scale, origin: frame.origin)
        dirty = true
        if case .keyDown = e { return took }
        if case .mouseMoved = e { return false }      // hover also reaches the screen (cursor, other panels' hover end)
        return true
    }
}
