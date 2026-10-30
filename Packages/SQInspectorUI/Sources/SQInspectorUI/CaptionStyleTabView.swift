import SQUIKit
import AppKit
import SQCore
import SQText
import SQTranscribe

/// Style tab of the Captions panel (FB-M point 6, W8.3): design every caption at once (the project's kit caption style)
/// or only the selected ones (a look of their own), the word highlight, saved looks, and the project's brand tokens
/// (fonts, colors, pill, motion defaults) edited in place.
@MainActor
public final class CaptionStyleTabView: NSView {
    public weak var session: EditorSession? { didSet { refresh() } }
    /// Model of the active sequence: its caption preset is the segmentation a saved look keeps.
    public var model: CaptionsPanelModel?
    public var onStatus: ((String) -> Void)?
    public private(set) var scope: CaptionStyleScope = .all

    let scopeControl = SQSegmented(labels: ["All Captions", "Selected"], segmentWidth: 0)
    /// Which caption track "All Captions" edits (shown with two or more tracks).
    let trackPopUp = SQPopup(frame: .zero, pullsDown: false)
    private var trackRow: TextBlockRow!
    /// Hands the selected captions back to their track look (clears the sparse per-caption overrides).
    let resetLookButton = SQButton(title: "Reset to Track Look", target: nil, action: nil)
    private var hadSelection = false
    /// Holds the caption looks (titles, ids, selection) behind the text block's Look row; not shown itself.
    let lookPopUp = SQPopup(frame: .zero, pullsDown: false)
    private var lookSelectedID: String?
    let animationPopUp = SQPopup(frame: .zero, pullsDown: false)
    /// The look gallery (`CaptionStyleLooks`): style, motion and word highlight of the current caption track in one click.
    let gallery = CaptionStyleLookGalleryView()
    /// The same model and sections as the Text panel (font, format, Fill, Outline, Background, Shadow); its edits are
    /// translated into caption style fields (`CaptionStyleEdit.fields`) and go through `EditorSession.editCaptionStyle`.
    let inspectorModel = TextInspectorModel()
    private lazy var inspector = TextInspectorView(model: inspectorModel, forCaptions: true)
    /// The style the inspector last showed or sent (as `CaptionStyleEdit.displayStyle`): the baseline of the next diff.
    private var shownStyle: TextStyle?
    /// An inspector edit gesture is open (scrub, color drag): a reload from the session would fight it.
    private var inspectorGestureOpen = false
    /// The next inspector change starts a new undo step (first change after `onBeginEditing`).
    private var inspectorGestureFresh = true
    /// FB-Y: where every caption sits (the project's kit).
    let verticalControl = SQSegmented(labels: ["Top", "Middle", "Bottom"], segmentWidth: 0)
    let horizontalControl = SQSegmented(labels: ["", "", ""], segmentWidth: 28)
    let offsetXField = ScrubField()
    let offsetYField = ScrubField()
    /// The next offset change starts a new undo step (first change after a scrub / typed commit begins).
    private var offsetGestureFresh = true
    let resetPositionButton = SQButton(title: "Reset to Kit Position", target: nil, action: nil)
    let karaokeCheck = SQCheckbox(title: "Word Highlight", target: nil, action: nil)
    let karaokeWell = SQColorWell()
    let karaokeKeep = SQCheckbox(title: "Keep spoken", target: nil, action: nil)
    private let saveLookButton = SQButton(title: "Save Current as Look…", target: nil, action: nil)
    private let updateLookButton = SQButton(title: "Update Look", target: nil, action: nil)
    private let kitLookButton = SQButton(title: "Look to Kit", target: nil, action: nil)
    private let textAnimButton = SQButton(title: "Animation from Text Clip", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let brandGrid = NSGridView()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var brandSignature: [String] = []
    /// Consecutive changes of one control within a second are one undo step (a color well drag, stepper clicks).
    private var lastEdit: (control: ObjectIdentifier, at: ContinuousClock.Instant)?

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        build()
        refresh()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    /// Space above and below a control in a grid row.
    private static let rowPad = (ControlsGrid.rowHeight - ControlsGrid.controlHeight) / 2
    /// Row insets on the Controls grid: the leading edge is the toggle column (where section headers start), the trailing
    /// edge the grid's trailing inset; `vertical` above and below.
    private static func insets(_ vertical: CGFloat) -> NSEdgeInsets { insets(vertical, vertical) }
    private static func insets(_ top: CGFloat, _ bottom: CGFloat) -> NSEdgeInsets {
        NSEdgeInsets(top: top, left: ControlsGrid.toggleX, bottom: bottom, right: ControlsGrid.trailing)
    }

    private func small(_ c: NSControl) { c.controlSize = .small; c.font = Theme.Typography.body }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.Typography.body; l.textColor = Theme.Colors.label2; l.alignment = .right
        return l
    }

    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.Typography.bodyStrong; l.textColor = Theme.Colors.label
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal; r.spacing = Theme.Spacing.sm; r.alignment = .centerY
        return r
    }

    private func build() {
        scopeControl.selectedSegment = 0
        scopeControl.target = self; scopeControl.action = #selector(scopeChanged)
        scopeControl.setToolTip("All Captions", forSegment: 0)
        scopeControl.setToolTip("Selected Captions", forSegment: 1)
        for p in [lookPopUp, animationPopUp] { small(p); p.target = self }
        lookPopUp.action = #selector(lookChanged); lookPopUp.sqToolTip = "Look"
        animationPopUp.action = #selector(animationChanged); animationPopUp.sqToolTip = "Caption Animation"
        karaokeWell.target = self
        karaokeWell.widthAnchor.constraint(equalToConstant: Theme.Row.swatch.width).isActive = true
        karaokeWell.heightAnchor.constraint(equalToConstant: Theme.Row.swatch.height).isActive = true
        karaokeWell.action = #selector(karaokeWellChanged); karaokeWell.sqToolTip = "Highlight Color"
        karaokeWell.onClose = { [weak self] in self?.karaokeChanged() }      // one undo step per picker session
        karaokeWell.color = Theme.TextDefaults.karaokeHighlight
        inspectorModel.onBeginEditing = { [weak self] in self?.inspectorGestureOpen = true; self?.inspectorGestureFresh = true }
        inspectorModel.onEndEditing = { [weak self] in self?.inspectorGestureOpen = false }
        inspectorModel.onChange = { [weak self] style, _ in self?.inspectorChanged(style) }
        inspector.onHeightChange = { [weak self] in self?.needsLayout = true }
        verticalControl.target = self; verticalControl.action = #selector(positionChanged(_:))
        verticalControl.sqToolTip = "Caption Position"
        horizontalControl.images = [nil, nil, nil]
        for (i, (sym, tip)) in [(SQIcon.textAlignLeft, "Left"), (.textAlignCenter, "Center"), (.textAlignRight, "Right")].enumerated() {
            horizontalControl.images[i] = Theme.symbol(sym, size: 11, label: tip)
            horizontalControl.setToolTip(tip, forSegment: i)
        }
        horizontalControl.target = self; horizontalControl.action = #selector(positionChanged(_:))
        resetPositionButton.target = self; resetPositionButton.action = #selector(resetPositionClicked)
        resetPositionButton.sqToolTip = "Reset to Kit Position"
        for (f, tip) in [(offsetXField, "Offset X"), (offsetYField, "Offset Y")] {
            f.range = -100 * CaptionPosition.maxOffset...100 * CaptionPosition.maxOffset
            f.step = 0.5; f.decimals = 1; f.unit = "%"; f.defaultValue = 0; f.sqToolTip = tip
            f.setAccessibilityLabel(tip)
            f.widthAnchor.constraint(equalToConstant: ControlsGrid.valueWidth).isActive = true
            f.onBegin = { [weak self] in self?.offsetGestureFresh = true }
            f.onChange = { [weak self] _ in self?.positionChanged(f) }
        }
        for (b, sel) in [(karaokeCheck, #selector(karaokeChanged)), (karaokeKeep, #selector(karaokeChanged))] {
            small(b); b.target = self; b.action = sel
        }
        karaokeCheck.sqToolTip = "Word Highlight"
        karaokeKeep.sqToolTip = "Keep Spoken Words Lit"
        for (b, sel, tip) in [(saveLookButton, #selector(saveLookClicked), "Save Look"),
                              (updateLookButton, #selector(updateLookClicked), "Update Look"),
                              (kitLookButton, #selector(kitLookClicked), "Look to Kit"),
                              (textAnimButton, #selector(textAnimClicked), "Animation from Text Clip")] {
            b.target = self; b.action = sel; b.sqToolTip = tip
        }
        hint.font = Theme.Typography.body; hint.textColor = Theme.Colors.label3

        // Board "Captions · Look": scope switch, Captions section (Animation, Word Highlight), the shared text block
        // (Text + Appearance, its Look row = the caption looks), Position, the two look buttons, then (not on the
        // board, kept) the Style Kit actions in a closed section.
        func labelled(_ title: String, _ views: [NSView], height: CGFloat = ControlsGrid.rowHeight) -> TextBlockRow {
            TextBlockRow(label: title, labelWidth: TextBlockRow.labelWidth, controls: views, height: height)
        }
        animationPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Inspector.popupWidth).isActive = true
        karaokeCheck.title = ""
        brandGrid.rowSpacing = ControlsGrid.gap; brandGrid.columnSpacing = ControlsGrid.gap

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets.bottom = Theme.Spacing.lg
        let scopeRow = NSView()
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeRow.addSubview(scopeControl)
        NSLayoutConstraint.activate([
            scopeControl.centerXAnchor.constraint(equalTo: scopeRow.centerXAnchor),
            scopeControl.topAnchor.constraint(equalTo: scopeRow.topAnchor),
            scopeControl.bottomAnchor.constraint(equalTo: scopeRow.bottomAnchor, constant: -6),
        ])
        small(trackPopUp); trackPopUp.target = self; trackPopUp.action = #selector(trackChanged); trackPopUp.sqToolTip = "Caption Track"
        trackPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Inspector.popupWidth).isActive = true
        trackRow = labelled("Track", [trackPopUp])
        resetLookButton.target = self; resetLookButton.action = #selector(resetLookClicked)
        resetLookButton.sqToolTip = "Reset to Track Look"
        let looksSection = InspectorSection(title: "Looks", key: "captions.look.gallery", defaultOpen: false)
        looksSection.header.showsTopLine = false
        gallery.onPick = { [weak self] look in self?.pickStyleLook(look) }
        looksSection.addRow(gallery)
        let captionsSection = InspectorSection(title: "Captions", key: "captions.look.captions")
        captionsSection.addRow(labelled("Animation", [animationPopUp]))
        captionsSection.addRow(labelled("Word Highlight", [karaokeCheck, karaokeWell, karaokeKeep]))
        let positionSection = InspectorSection(title: "Position", key: "captions.look.position")
        positionSection.addRow(labelled("Vertical", [verticalControl]))
        positionSection.addRow(labelled("Align", [horizontalControl]))
        positionSection.addRow(labelled("Offset", [label("X"), offsetXField, label("Y"), offsetYField]))
        positionSection.addRow(labelled("", [resetPositionButton]))
        let looksRow = NSStackView(views: [saveLookButton, updateLookButton, resetLookButton])
        looksRow.orientation = .horizontal; looksRow.spacing = ControlsGrid.gap
        looksRow.edgeInsets = Self.insets(Self.rowPad)
        let kitSection = InspectorSection(title: "Style Kit", key: "captions.look.kit", defaultOpen: false)
        for v in [kitLookButton, textAnimButton, header("Brand (Style Kit)"), brandGrid] as [NSView] {
            let host = NSStackView(views: [v]); host.edgeInsets = Self.insets(Self.rowPad)
            kitSection.addRow(host)
        }
        let hintHost = NSStackView(views: [hint]); hintHost.edgeInsets = Self.insets(0)
        for v in [scopeRow, trackRow, looksSection, captionsSection, inspector, positionSection, looksRow, kitSection, hintHost] as [NSView] {
            stack.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        inspector.lookSource = { [weak self] in
            guard let self else { return .init(titles: [], ids: [], selected: nil, pick: { _ in }, add: nil) }
            let ids = lookPopUp.itemArray.compactMap { $0.representedObject as? String }
            return .init(titles: ids.map { TextInspectorView.title(for: $0) }, ids: ids, selected: lookSelectedID,
                         pick: { [weak self] id in self?.pickLook(id) }, add: { [weak self] in self?.saveLookClicked() })
        }
        let doc = FlippedDocumentView()
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        doc.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    // MARK: Session to UI

    public func refresh() {
        guard let s = session else { return }
        let hasCaptions = !s.captionItems.isEmpty
        let hasSelection = !s.captionSelection.isEmpty
        // Selecting a caption (list or timeline) edits that caption; clearing the selection goes back to the track look.
        if hasSelection != hadSelection { scope = hasSelection ? .selected : .all; hadSelection = hasSelection }
        if scope == .selected && !hasSelection { scope = .all }
        refreshTrackPicker(s)
        scopeControl.selectedSegment = scope == .all ? 0 : 1
        scopeControl.setEnabled(hasSelection, forSegment: 1)
        let state = s.captionStyleState(scope: scope)

        fill(lookPopUp, ids: CaptionStyleEdit.builtInStyleIDs, selected: state?.baseID, other: "Saved Look")
        fill(animationPopUp, ids: CaptionStyleEdit.builtInAnimationIDs, selected: state?.animationID, other: "Saved Animation")
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
        let enabled = state != nil
        lookPopUp.isEnabled = enabled
        lookSelectedID = state?.baseID
        inspector.refreshLook()
        inspector.isHidden = !enabled
        animationPopUp.isEnabled = enabled
        animationPopUp.sqToolTip = "Caption Animation"

        let selectedIDs = s.captionSelection
        let own = scope == .selected && hasSelection
        let pos = own ? (s.captionItems.first { selectedIDs.contains($0.id) }.map(s.effectiveCaptionPosition) ?? s.captionPosition) : s.captionPosition
        resetPositionButton.isEnabled = s.captionItems.contains { $0.position != nil && (!own || selectedIDs.contains($0.id)) }
        verticalControl.selectedSegment = CaptionPosition.Vertical.allCases.firstIndex(of: pos.vertical) ?? 2
        horizontalControl.selectedSegment = CaptionPosition.Horizontal.allCases.firstIndex(of: pos.horizontal) ?? 1
        for (f, v) in [(offsetXField, pos.offsetX), (offsetYField, pos.offsetY)] where !f.isDragging && !f.isEditing {
            f.value = CaptionOffsetDisplay.shown(v, isY: f === offsetYField)
        }
        for c in [verticalControl, horizontalControl, offsetXField, offsetYField] as [NSControl] {
            c.isEnabled = state != nil
        }

        let k = s.captionKaraoke
        karaokeCheck.state = k == nil ? .off : .on
        karaokeCheck.isEnabled = hasCaptions
        karaokeWell.isEnabled = k != nil; karaokeKeep.isEnabled = k != nil
        if let k {
            karaokeWell.color = Theme.ColorBridge.srgb(k.red, k.green, k.blue)
            karaokeKeep.state = k.keepSpoken ? .on : .off
        }
        saveLookButton.isEnabled = hasCaptions; updateLookButton.isEnabled = hasCaptions; kitLookButton.isEnabled = hasCaptions
        textAnimButton.isEnabled = hasCaptions && s.animationFromSelectedTextClip() != nil
        hint.stringValue = !hasCaptions ? "Create captions first (Captions tab), then style them here."
            : scope == .all ? "Changes every caption on \(s.currentCaptionTrack?.name ?? "the track"), except that it releases captions with their own look."
            : "Changes only the selected captions. Reset to Track Look hands them back."
        refreshBrand(s.project.styleKit)
    }

    private func refreshTrackPicker(_ s: EditorSession) {
        let tracks = s.activeTimeline?.captionTracks ?? []
        trackRow.isHidden = tracks.count < 2
        trackPopUp.removeAllItems()
        for t in tracks {
            trackPopUp.addItem(withTitle: t.name.isEmpty ? "Captions" : t.name)
            trackPopUp.lastItem?.representedObject = t.id
        }
        if let cur = s.currentCaptionTrack, let i = tracks.firstIndex(where: { $0.id == cur.id }) { trackPopUp.selectItem(at: i) }
        // With a caption selected its own track is the one that counts.
        trackPopUp.isEnabled = s.captionSelection.isEmpty
        resetLookButton.isEnabled = s.selectedCaptionsHaveOverrides
        gallery.currentID = s.currentCaptionStyleLook?.id
        resetLookButton.isHidden = scope != .selected
    }

    private func pickStyleLook(_ look: CaptionStyleLook) {
        guard let s = session else { return }
        lastEdit = nil
        if s.applyCaptionStyleLook(look) { onStatus?(SQL10n.format("Caption look: %@.", SQL10n.string(look.title))) }
        else { onStatus?(s.lastError ?? "Create captions first, then pick a look.") }
        refresh()
    }

    @objc private func trackChanged() {
        guard let id = trackPopUp.selectedItem?.representedObject as? UUID else { return }
        session?.focusCaptionTrack(id)
        lastEdit = nil
    }

    @objc private func resetLookClicked() {
        guard let s = session else { return }
        lastEdit = nil
        if !s.resetSelectedCaptionsToTrackLook(), let e = s.lastError { onStatus?(e) }
        refresh()
    }

    private func fill(_ p: NSPopUpButton, ids: [String], selected: String?, other: String) {
        p.removeAllItems()
        for id in ids {
            p.addItem(withTitle: TextInspectorView.title(for: id))
            p.lastItem?.representedObject = id
        }
        if let selected, let i = ids.firstIndex(of: selected) { p.selectItem(at: i) } else {
            p.addItem(withTitle: other); p.lastItem?.isEnabled = false
            p.selectItem(at: p.numberOfItems - 1)
        }
    }

    // MARK: Brand tokens

    private func refreshBrand(_ kit: StyleKit?) {
        let k = kit ?? StyleKit()
        let sig = k.fonts.keys.sorted().map { "f:\($0)" } + k.colors.keys.sorted().map { "c:\($0)" }
            + [k.pill == nil ? "" : "pill", k.motion == nil ? "" : "motion"]
        if sig != brandSignature {
            brandSignature = sig
            rebuildBrand(k)
        }
        // Values only (the rows stay, so a color well being dragged keeps its target).
        for case let p as NSPopUpButton in brandControls where p.identifier?.rawValue.hasPrefix("font:") == true {
            let name = String(p.identifier!.rawValue.dropFirst(5))
            if let v = k.fonts[name] {
                if p.item(withTitle: v) == nil { p.insertItem(withTitle: v, at: 0) }
                p.selectItem(withTitle: v)
            }
        }
        for case let w as SQColorWell in brandControls where w.identifier?.rawValue.hasPrefix("color:") == true {
            if let c = k.colors[String(w.identifier!.rawValue.dropFirst(6))] { w.color = Self.ns(RGBAColor(c)) }
        }
        for case let f as ScrubField in brandControls where f.identifier?.rawValue == "motionD" && !f.isDragging && !f.isEditing {
            f.value = k.motion.map { Double($0.duration.value) / Double($0.duration.timescale) } ?? Self.defaultMotionSeconds
        }
        for case let p as NSPopUpButton in brandControls where p.identifier?.rawValue == "motionC" {
            p.selectItem(at: k.motion?.curve ?? MotionCurve.premiereDefault.rawValue)
        }
    }

    private var brandControls: [NSView] = []

    private func rebuildBrand(_ k: StyleKit) {
        while brandGrid.numberOfRows > 0 { brandGrid.removeRow(at: 0) }
        brandControls = []
        let families = FontFamilyList.current
        for name in k.fonts.keys.sorted() {
            let p = SQPopup(frame: .zero, pullsDown: false)
            small(p); p.addItems(withTitles: families)
            p.identifier = .init("font:\(name)"); p.target = self; p.action = #selector(brandFontChanged(_:))
            p.sqToolTip = SQL10n.format("%@ Font", SQL10n.string(TextInspectorView.title(for: name)))
            brandGrid.addRow(with: [label(TextInspectorView.title(for: name) + " Font"), p]); brandControls.append(p)
        }
        for name in k.colors.keys.sorted() {
            let w = SQColorWell()
            w.widthAnchor.constraint(equalToConstant: Theme.Row.swatch.width).isActive = true
            w.heightAnchor.constraint(equalToConstant: Theme.Row.swatch.height).isActive = true
            w.identifier = .init("color:\(name)"); w.target = self; w.action = #selector(brandColorChanged(_:))
            w.sqToolTip = SQL10n.format("%@ Color", SQL10n.string(TextInspectorView.title(for: name)))
            w.onOpen = { [weak self, weak w] in
                guard let self, let w else { return }
                pickerWell = ObjectIdentifier(w); lastEdit = nil       // a new picker session starts a new undo step
            }
            w.onClose = { [weak self] in self?.pickerWell = nil }
            brandGrid.addRow(with: [label(TextInspectorView.title(for: name) + " Color"), w]); brandControls.append(w)
        }
        func number(_ id: String, _ tip: String) -> ScrubField {
            let f = ScrubField()
            f.identifier = .init(id); f.sqToolTip = tip; f.setAccessibilityLabel(tip)
            f.range = 0.05...600; f.step = 0.05; f.decimals = 2; f.unit = "s"; f.defaultValue = Self.defaultMotionSeconds
            let started = FreshFlag()
            f.onBegin = { started.on = false }
            f.onChange = { [weak self] v in self?.setMotionDuration(v, continuing: started.on); started.on = true }
            f.onEnd = { [weak self] v in if !started.on { self?.setMotionDuration(v, continuing: false) } }
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            brandControls.append(f)
            return f
        }
        let curve = SQPopup(frame: .zero, pullsDown: false)
        small(curve); curve.addItems(withTitles: MotionCurve.titles)
        curve.identifier = .init("motionC"); curve.target = self; curve.action = #selector(brandCurveChanged(_:))
        curve.sqToolTip = "Motion Curve"
        brandControls.append(curve)
        brandGrid.addRow(with: [label("Motion"), row([number("motionD", "Motion Duration"), curve])])
        if brandGrid.numberOfColumns > 0 {
            brandGrid.column(at: 0).xPlacement = .trailing
            brandGrid.column(at: 0).width = 96
        }
    }

    // MARK: Actions

    /// True when `sender` changed again within a second: the change joins the previous undo step.
    private var pickerWell: ObjectIdentifier?
    private func continuing(_ sender: AnyObject) -> Bool {
        let now = ContinuousClock.now
        defer { lastEdit = (ObjectIdentifier(sender), now) }
        guard let last = lastEdit, last.control == ObjectIdentifier(sender) else { return false }
        if pickerWell == ObjectIdentifier(sender) { return true }          // an open picker holds the step, however slow
        return now - last.at < .seconds(1)
    }

    private func edit(_ f: CaptionStyleField, _ sender: AnyObject) {
        guard let s = session else { return }
        if !s.editCaptionStyle(f, scope: scope, continuesGesture: continuing(sender)), let e = s.lastError { onStatus?(e) }
    }

    @objc private func scopeChanged() {
        scope = scopeControl.selectedSegment == 1 ? .selected : .all
        lastEdit = nil
        refresh()
    }

    private func pickLook(_ id: String) {
        if let i = lookPopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) { lookPopUp.selectItem(at: i) }
        lookChanged()
    }

    @objc private func lookChanged() {
        if let id = lookPopUp.selectedItem?.representedObject as? String { edit(.look(id), lookPopUp) }
    }

    @objc private func animationChanged() {
        if let id = animationPopUp.selectedItem?.representedObject as? String { edit(.animation(id), animationPopUp) }
    }

    /// An edit in the shared Text inspector: the difference to what was shown becomes caption fields, one undo step per
    /// gesture (a scrub or color drag keeps `inspectorGestureOpen`; later changes of it join the first step).
    private func inspectorChanged(_ new: TextStyle) {
        guard let s = session else { return }
        let new = CaptionStyleEdit.displayStyle(new)
        let old = shownStyle ?? new
        let fields = CaptionStyleEdit.fields(from: old, to: new)
        let joins = !inspectorGestureFresh
        inspectorGestureFresh = false
        guard !fields.isEmpty else { return }
        shownStyle = new
        lastEdit = nil
        if !s.editCaptionStyle(fields, scope: scope, continuesGesture: joins), let e = s.lastError { onStatus?(e) }
    }

    /// Any position control: the whole position is read back from the controls (stepper and field stay in step).
    @objc private func positionChanged(_ sender: NSControl) {
        guard let s = session else { return }
        func stored(_ f: ScrubField) -> Double { CaptionOffsetDisplay.stored(f.value, isY: f === offsetYField) }
        let verticals = CaptionPosition.Vertical.allCases, horizontals = CaptionPosition.Horizontal.allCases
        let v = verticals[min(verticals.count - 1, max(0, verticalControl.selectedSegment))]
        let h = horizontals[min(horizontals.count - 1, max(0, horizontalControl.selectedSegment))]
        let p = CaptionPosition(vertical: v, horizontal: h, offsetX: stored(offsetXField), offsetY: stored(offsetYField))
        // One scrub / typed commit / arrow burst of an offset field is one undo step; a segment is its own.
        let isOffset = sender === offsetXField || sender === offsetYField
        let joins = isOffset && !offsetGestureFresh
        if isOffset { offsetGestureFresh = false } else { lastEdit = nil }
        if scope == .selected, !s.captionSelection.isEmpty {
            s.setCaptionItemPosition(s.captionSelection, p, continuesGesture: joins)   // their own position, not the kit's
        } else {
            s.setCaptionPosition(p, continuesGesture: joins)
        }
        refresh()
    }

    /// Hands the selected captions (scope Selected) or every caption back to the project's caption position.
    @objc private func resetPositionClicked() {
        guard let s = session else { return }
        lastEdit = nil
        s.resetCaptionPositions(scope == .selected && !s.captionSelection.isEmpty ? s.captionSelection : s.allCaptionIDs)
        refresh()
    }

    @objc private func karaokeWellChanged() { if !karaokeWell.isActive { karaokeChanged() } }

    @objc private func karaokeChanged() {
        guard let s = session else { return }
        if karaokeCheck.state == .off { s.setCaptionKaraoke(nil); return }
        let c = karaokeWell.color.usingColorSpace(.sRGB) ?? karaokeWell.color
        s.setCaptionKaraoke(KaraokeStyle(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent,
                                         keepSpoken: karaokeKeep.state == .on))
    }

    @objc private func brandFontChanged(_ p: NSPopUpButton) {
        guard let id = p.identifier?.rawValue, let v = p.titleOfSelectedItem else { return }
        session?.editStyleKit(name: "Brand Font") { $0.fonts[String(id.dropFirst(5))] = v }
    }

    @objc private func brandColorChanged(_ w: SQColorWell) {
        guard let id = w.identifier?.rawValue else { return }
        let c = CaptionStyleEdit.effect(Self.rgba(w.color))
        session?.editStyleKit(name: "Brand Color", continuesGesture: continuing(w)) { $0.colors[String(id.dropFirst(6))] = c }
    }

    /// What a Style Kit without motion defaults starts new motion effects with (`CaptionKitMotion`, shared with the draw tab).
    static var defaultMotionSeconds: Double { CaptionKitMotion.defaultSeconds }

    static func motionTime(seconds v: Double) -> Time? { CaptionKitMotion.time(seconds: v) }

    /// A scrub / typed value of the motion duration; one gesture is one undo step.
    private func setMotionDuration(_ v: Double, continuing joins: Bool) {
        guard let t = Self.motionTime(seconds: v) else { return }
        session?.editStyleKit(name: "Change Motion Duration", continuesGesture: joins) { k in
            let curve = k.motion?.curve ?? MotionCurve.premiereDefault.rawValue
            k.motion = MotionDefaults(duration: t, curve: curve)
        }
    }

    @objc private func brandCurveChanged(_ p: NSPopUpButton) {
        session?.editStyleKit(name: "Motion Curve") { k in
            k.motion = MotionDefaults(duration: k.motion?.duration ?? Time(1, 2), curve: p.indexOfSelectedItem)
        }
    }

    // MARK: Looks (moved from the Captions tab)

    /// The current look becomes a saved look and the default for Create Captions.
    @objc private func saveLookClicked() {
        guard session?.currentCaptionLook() != nil else { return }
        // The same name prompt as Save as New Look in Controls and Graphics.
        guard let name = inspector.askLookName("Save as New Look", "Caption Look \(CaptionLookLibrary.shared.looks.count + 1)") else { return }
        saveLook(named: name)
    }

    private func saveLook(named name: String) {
        guard let s = session, let look = s.currentCaptionLook() else { return }
        let seg = model?.selectedPreset ?? .standard
        Task { @MainActor [weak self] in
            do {
                let id = try await CaptionLookLibrary.shared.save(name: name, look: look, segmentation: seg, makeDefault: true)
                s.pushCaptionLook(look, id: id.uuidString)
                self?.onStatus?("Look saved as the default for Create Captions.")
            } catch { self?.onStatus?("The look could not be saved.") }
        }
    }

    /// The look on screen goes into the project's Style Kit (named after the number of kit looks).
    @objc private func kitLookClicked() {
        guard let s = session else { return }
        let n = (s.project.styleKit?.looks.count ?? 0) + 1
        if s.saveCaptionLookToKit(name: "Look \(n)") != nil { onStatus?(SQL10n.format("Look saved in the Style Kit as \"Look %@\".", String(n))) }
        else { onStatus?("The look could not be saved in the Style Kit.") }
    }

    /// Edit one caption (or all), then push: its look goes to every caption and into the default look.
    @objc private func updateLookClicked() {
        guard let s = session, let look = s.currentCaptionLook() else { return }
        guard let stored = CaptionLookLibrary.shared.defaultLook else {
            saveLook(named: "Caption Look \(CaptionLookLibrary.shared.looks.count + 1)")
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await CaptionLookLibrary.shared.update(stored.id, look: look, segmentation: nil)
                s.pushCaptionLook(look, id: stored.id.uuidString)
                self?.onStatus?("Look updated on every caption.")
            } catch { self?.onStatus?("The look could not be updated.") }
        }
    }

    @objc private func textAnimClicked() {
        guard let s = session, let a = s.animationFromSelectedTextClip(), var look = s.currentCaptionLook() else { return }
        look.animation = a
        let seg = model?.selectedPreset ?? .standard
        let n = CaptionLookLibrary.shared.looks.count + 1
        Task { @MainActor [weak self] in
            do {
                let id: UUID
                if let stored = CaptionLookLibrary.shared.defaultLook {
                    try await CaptionLookLibrary.shared.update(stored.id, look: look, segmentation: nil)
                    id = stored.id
                } else {
                    id = try await CaptionLookLibrary.shared.save(name: "Caption Look \(n)", look: look, segmentation: seg, makeDefault: true)
                }
                s.pushCaptionLook(look, id: id.uuidString)
                self?.onStatus?("Animation taken from the text clip and saved in the default look.")
            } catch { self?.onStatus?("The look could not be saved.") }
        }
    }

    // MARK: Color

    static func ns(_ c: RGBAColor) -> NSColor { Theme.ColorBridge.ns(c) }

    static func rgba(_ c: NSColor) -> RGBAColor {
        Theme.ColorBridge.rgba(c)
    }
}

private final class FreshFlag { var on = false }

/// Document view of the Style tab's scroll view: top-down like the rest of the panel.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

