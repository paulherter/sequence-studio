import AppKit
import SQEditorUI
import SQCore
import SQEditorSession

/// File > New Project and the start window's New project button (design "Start Screen B", New project sheet): an SQ dialog
/// in the modal shell (`SQModalScrimView`: 50 % scrim, centered card, shared shadow) over the frontmost window. Header (title, note, close), a form with a 104 pt label column
/// (Name, Template, Frame size, Width x Height, Frame rate, Audio, Timeline, Outside files, Location) and a footer band with
/// a live summary (aspect preview, size and rate, aspect and audio and timeline) plus Cancel and Create.
/// Esc cancels, Return creates.
@MainActor
final class NewProjectSheet: NSObject {
    struct Answer {
        var name: String
        var template: ProjectTemplate
        var mode: OutsideMediaMode
        var location: URL
        var editMode: TimelineEditMode
    }

    /// Frame size presets, grouped (menu captions). `key` is the aspect shown as the popup's key.
    struct SizePreset { let group: String; let name: String; let width: Int; let height: Int; let key: String }
    static let sizePresets: [SizePreset] = [
        SizePreset(group: "Social", name: "Vertical video", width: 1080, height: 1920, key: "9:16"),
        SizePreset(group: "Social", name: "Portrait post", width: 1080, height: 1350, key: "4:5"),
        SizePreset(group: "Social", name: "Square", width: 1080, height: 1080, key: "1:1"),
        SizePreset(group: "Social", name: "Portrait 3:4", width: 1080, height: 1440, key: "3:4"),
        SizePreset(group: "Wide", name: "HD 1080p", width: 1920, height: 1080, key: "16:9"),
        SizePreset(group: "Wide", name: "4K UHD", width: 3840, height: 2160, key: "16:9"),
        SizePreset(group: "Wide", name: "HD 720p", width: 1280, height: 720, key: "16:9"),
        SizePreset(group: "Cinema", name: "Ultrawide 21:9", width: 2560, height: 1080, key: "21:9"),
        SizePreset(group: "Cinema", name: "Scope 2.39:1", width: 4096, height: 1716, key: "2.39:1"),
        SizePreset(group: "Cinema", name: "DCI 4K", width: 4096, height: 2160, key: "1.90:1"),
    ]
    /// Frame rates (same order as `SequenceFormatPresets.frameRates`) with their use.
    static let rateNotes = ["Film NTSC", "Film", "PAL", "NTSC", "Social", "", "", ""]
    /// Sample rates offered; a template with another rate adds its own entry. Channels are always Stereo until a setting backs Mono.
    static let baseAudioRates = [48_000, 44_100, 96_000]
    static let outsideChoices: [(OutsideMediaMode, String)] = StartTemplatesModel.outsideChoices.map { ($0.mode, $0.title) }

    /// "48 kHz", "44.1 kHz".
    static func audioTitle(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }

    /// "9:16", "16:9", "2.39:1" for a pixel size.
    static func aspectText(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        let rw = width / a, rh = height / a
        if rw <= 32, rh <= 32 { return "\(rw):\(rh)" }
        return String(format: "%.2f:1", Double(width) / Double(height))
    }

    /// The format the choices describe: the template's, with the typed size, the chosen rate and sample rate.
    /// A size outside 1...maxDimension keeps the template's size.
    static func resolve(base: SequenceFormat, width: Int, height: Int, rateIndex: Int, sampleRate: Int?) -> SequenceFormat {
        NewProjectInput.resolve(base: base, width: width, height: height, rateIndex: rateIndex, sampleRate: sampleRate)
    }

    // MARK: State

    private let templates: [ProjectTemplate]
    private var templateIndex = 0
    private var rateIndex = 4
    private var audioIndex = 0
    private var audioRates = NewProjectSheet.baseAudioRates
    private var outsideIndex = 0
    private var fastCut = AppSettings.load().newSequenceEditMode == .magnetic
    private var location: URL
    private var result: Answer?

    // MARK: Views

    private let panel: SheetPanel
    private let card = SheetCard()
    private let nameField = SQTextField(string: "Untitled Project")
    private let templatePopup = SQMenuPopup()
    private let templateHint = NewProjectSheet.hint("")
    private let sizePopup = SQMenuPopup()
    private let sizeKey = KeyLabel()
    private let widthField = SQDialog.makeNumberField(range: 1...Double(SequenceFormatPresets.maxDimension), step: 1, width: 84)
    private let heightField = SQDialog.makeNumberField(range: 1...Double(SequenceFormatPresets.maxDimension), step: 1, width: 84)
    private let aspectHint = NewProjectSheet.hint("")
    private let ratePopup = SQMenuPopup()
    private let audioPopup = SQMenuPopup()
    private let modeSegmented = SQSegmented(labels: ["Normal", "Fast Cut"], segmentWidth: 84)
    private let outsidePopup = SQMenuPopup()
    private let pathLabel = NSTextField(labelWithString: "")
    private let preview = PreviewBox()
    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")

    private static func hint(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.Typography.start(Theme.Typography.startCaption)
        l.textColor = Theme.Colors.label3
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// The folder chosen last time (`sq.newProject.location`); the Movies default while it is unset or gone.
    static let locationKey = "sq.newProject.location"
    static func rememberedLocation() -> URL {
        var isDir: ObjCBool = false
        if let path = UserDefaults.standard.string(forKey: locationKey),
           FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return StorageLocations.load().projectsRoot
    }

    private init(templates: [ProjectTemplate], preferred: ProjectTemplate?, frame: NSRect) {
        self.templates = templates
        location = Self.rememberedLocation()
        panel = SheetPanel(contentRect: frame)
        super.init()
        if let preferred, let i = templates.firstIndex(where: { $0.id == preferred.id }) { templateIndex = i }
        build(frame: frame)
        applyTemplate()
        panel.onCancel = { [weak self] in self?.finish(nil) }
        panel.onCreate = { [weak self] in self?.create() }
    }

    private var baseFormat: SequenceFormat {
        templates.indices.contains(templateIndex) ? templates[templateIndex].format : SequenceFormat(frameDuration: Time(1, 30))
    }

    private var chosen: SequenceFormat {
        Self.resolve(base: baseFormat, width: Int(widthField.value.rounded()), height: Int(heightField.value.rounded()),
                     rateIndex: rateIndex, sampleRate: audioRates[audioIndex])
    }

    // MARK: Layout (design: sheet 600, radius 14, head 56, form 104 + 16 + control, foot 68)

    private static let sheetWidth: CGFloat = 600
    private static let headHeight: CGFloat = 56
    private static let footHeight: CGFloat = 68
    private static let rowH: CGFloat = 28
    private static let popWidth: CGFloat = 260

    private func build(frame: NSRect) {
        let s3 = Theme.Metrics.startS3, s4 = Theme.Metrics.startS4, s5 = Theme.Metrics.startS5, s6 = Theme.Metrics.startS6
        let font = Theme.Typography.start(Theme.Typography.startLabel)

        // Header.
        let title = NSTextField(labelWithString: "New project")
        title.font = Theme.Typography.start(Theme.Typography.startHeading, .semibold)
        title.textColor = Theme.Colors.label
        let note = Self.hint("Settings can change later in Sequence Settings.")
        note.font = font
        let close = SQButton(symbol: .close, label: "Close", target: self, action: #selector(cancelPressed))
        close.toolTip = "Close (Esc)"

        // Form rows, top to bottom. `labelX` right edge of the label column, `x` start of the controls.
        let labelX = s6, labelW: CGFloat = 104
        let x = labelX + labelW + s4
        let controlW = Self.sheetWidth - x - s6
        let rowGap = s3
        var y = Self.headHeight + s5
        var formViews: [NSView] = []
        func label(_ text: String, rowY: CGFloat) {
            guard !text.isEmpty else { return }
            let l = NSTextField(labelWithString: text)
            l.font = font; l.textColor = Theme.Colors.label2; l.alignment = .right
            l.frame = NSRect(x: labelX, y: rowY + (Self.rowH - 16) / 2, width: labelW, height: 16)
            formViews.append(l)
        }
        func place(_ v: NSView, x px: CGFloat, w: CGFloat, rowY: CGFloat, h: CGFloat? = nil) {
            v.translatesAutoresizingMaskIntoConstraints = true
            let height = h ?? Self.rowH
            v.frame = NSRect(x: px, y: rowY + (Self.rowH - height) / 2, width: w, height: height)
            formViews.append(v)
        }
        func hintAfter(_ l: NSTextField, from px: CGFloat, rowY: CGFloat) {
            l.frame = NSRect(x: px, y: rowY + (Self.rowH - 14) / 2, width: Self.sheetWidth - s6 - px, height: 14)
            formViews.append(l)
        }
        func next(_ extra: CGFloat = 0) { y += Self.rowH + rowGap + extra }
        func popup(_ p: SQMenuPopup) {
            p.boxHeight = Self.rowH; p.sizesToTitle = false
            p.font = font
        }

        // Name
        label("Name", rowY: y)
        nameField.font = font
        place(nameField, x: x, w: controlW, rowY: y, h: Theme.Row.control)
        next()
        // Template
        label("Template", rowY: y)
        popup(templatePopup)
        templatePopup.itemsProvider = { [weak self] in self?.templateItems() ?? [] }
        place(templatePopup, x: x, w: Self.popWidth, rowY: y)
        hintAfter(templateHint, from: x + Self.popWidth + Theme.Metrics.startS2, rowY: y)
        next(Theme.Metrics.startS1)
        // Frame size
        label("Frame size", rowY: y)
        popup(sizePopup)
        sizePopup.itemsProvider = { [weak self] in self?.sizeItems() ?? [] }
        place(sizePopup, x: x, w: Self.popWidth, rowY: y)
        sizeKey.frame = NSRect(x: x + Self.popWidth - 28 - 56, y: y, width: 56, height: Self.rowH)
        sizeKey.font = Theme.Typography.start(Theme.Typography.startCaption)
        formViews.append(sizeKey)
        next()
        // Width x height
        for f in [widthField, heightField] {
            f.leadingText = true
            f.onChange = { [weak self] _ in self?.fieldsChanged() }
            f.onEnd = { [weak self] _ in self?.fieldsChanged() }
        }
        place(widthField, x: x, w: 84, rowY: y, h: Theme.Row.control)
        let swap = SQButton(symbol: .swap, label: "Swap width and height", target: self, action: #selector(swapSize))
        swap.toolTip = "Swap width and height"
        place(swap, x: x + 84 + Theme.Metrics.startS2, w: Self.rowH, rowY: y)
        place(heightField, x: x + 84 + Theme.Metrics.startS2 * 2 + Self.rowH, w: 84, rowY: y, h: Theme.Row.control)
        hintAfter(aspectHint, from: x + 84 * 2 + Self.rowH + Theme.Metrics.startS2 * 3, rowY: y)
        next()
        // Frame rate
        label("Frame rate", rowY: y)
        popup(ratePopup)
        ratePopup.itemsProvider = { [weak self] in self?.rateItems() ?? [] }
        place(ratePopup, x: x, w: Self.popWidth, rowY: y)
        next()
        // Audio
        label("Audio", rowY: y)
        popup(audioPopup)
        audioPopup.itemsProvider = { [weak self] in self?.audioItems() ?? [] }
        place(audioPopup, x: x, w: Self.popWidth, rowY: y)
        next()
        // Timeline
        label("Timeline", rowY: y)
        modeSegmented.target = self; modeSegmented.action = #selector(modeChanged)
        modeSegmented.translatesAutoresizingMaskIntoConstraints = true
        let segW = modeSegmented.intrinsicContentSize.width
        place(modeSegmented, x: x, w: segW, rowY: y, h: min(modeSegmented.intrinsicContentSize.height, Self.rowH))
        let tlHint = Self.hint("Default from Preferences › Playback")
        hintAfter(tlHint, from: x + segW + Theme.Metrics.startS2, rowY: y)
        next()
        // Outside files
        label("Outside files", rowY: y)
        popup(outsidePopup)
        outsidePopup.itemsProvider = { [weak self] in self?.outsideItems() ?? [] }
        place(outsidePopup, x: x, w: Self.popWidth, rowY: y)
        next(Theme.Metrics.startS1)
        // Location
        label("Location", rowY: y)
        let chooseW: CGFloat = 92
        let chip = PathChip(label: pathLabel)
        place(chip, x: x, w: controlW - chooseW - Theme.Metrics.startS2, rowY: y)
        let choose = SQButton(title: "Choose…", target: self, action: #selector(chooseLocation), style: .standard)
        choose.boxHeight = Self.rowH
        place(choose, x: x + controlW - chooseW, w: chooseW, rowY: y)
        y += Self.rowH + s5

        // Footer band.
        let footY = y
        let sheetH = footY + Self.footHeight
        let foot = FrameBand(frame: NSRect(x: 0, y: footY, width: Self.sheetWidth, height: Self.footHeight))
        preview.frame = NSRect(x: s5, y: (Self.footHeight - 44) / 2, width: 44, height: 44)
        line1.font = Theme.Typography.start(Theme.Typography.startLabel, .semibold)
        line1.textColor = Theme.Colors.label; line1.lineBreakMode = .byTruncatingTail
        line2.font = Theme.Typography.start(Theme.Typography.startCaption)
        line2.textColor = Theme.Colors.label3; line2.lineBreakMode = .byTruncatingTail
        let cancel = SQButton(title: "Cancel", target: self, action: #selector(cancelPressed), style: .standard)
        let createB = SQButton(title: "Create  ⏎", target: self, action: #selector(createPressed), style: .accent)
        for b in [cancel, createB] { b.boxHeight = Self.rowH }
        let createW: CGFloat = 104, cancelW: CGFloat = 76
        createB.frame = NSRect(x: Self.sheetWidth - s5 - createW, y: (Self.footHeight - Self.rowH) / 2, width: createW, height: Self.rowH)
        cancel.frame = NSRect(x: createB.frame.minX - Theme.Metrics.startS2 - cancelW, y: createB.frame.minY, width: cancelW, height: Self.rowH)
        let textX = preview.frame.maxX + s3
        let textW = cancel.frame.minX - s4 - textX
        line1.frame = NSRect(x: textX, y: Self.footHeight / 2 - 16, width: textW, height: 16)
        line2.frame = NSRect(x: textX, y: Self.footHeight / 2 + 1, width: textW, height: 14)
        for v in [preview, line1, line2, cancel, createB] { foot.addSubview(v) }

        // Header placement.
        title.frame = NSRect(x: s5, y: 10, width: 400, height: 20)
        note.frame = NSRect(x: s5, y: 31, width: 460, height: 16)
        close.frame = NSRect(x: Self.sheetWidth - s3 - Self.rowH, y: (Self.headHeight - Self.rowH) / 2, width: Self.rowH, height: Self.rowH)

        card.frame = NSRect(x: 0, y: 0, width: Self.sheetWidth, height: sheetH)
        ([title, note, close] + formViews + [foot]).forEach(card.content.addSubview)
        card.content.frame = card.bounds
        // The shared modal shell: 50 % scrim over the host window, the card centered with the shared drop shadow.
        let root = SQModalScrimView(card: card)
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.layer?.cornerRadius = Theme.Radius.startCard
        panel.contentView = root
    }

    // MARK: Menus

    private func templateItems() -> [SQMenuItem] {
        func rows(_ list: [(Int, ProjectTemplate)]) -> [SQMenuItem] {
            list.map { i, t in
                SQMenuItem(title: t.name, isChecked: i == templateIndex) { [weak self] in
                    self?.templateIndex = i; self?.applyTemplate()
                }
            }
        }
        let builtInIDs = Set(ProjectTemplate.builtIn.map(\.id))
        let all = Array(templates.enumerated()).map { ($0.offset, $0.element) }
        let built = all.filter { builtInIDs.contains($0.1.id) }, yours = all.filter { !builtInIDs.contains($0.1.id) }
        var items: [SQMenuItem] = []
        if !built.isEmpty { items.append(.header("Built in")); items += rows(built) }
        if !yours.isEmpty { items.append(.header("Yours")); items += rows(yours) }
        return items
    }

    private func sizeItems() -> [SQMenuItem] {
        var items: [SQMenuItem] = []
        var group = ""
        for p in Self.sizePresets {
            if p.group != group { items.append(.header(p.group)); group = p.group }
            let on = Int(widthField.value.rounded()) == p.width && Int(heightField.value.rounded()) == p.height
            items.append(SQMenuItem(title: p.name, shortcut: "\(p.width) × \(p.height)", isChecked: on) { [weak self] in
                self?.widthField.value = Double(p.width); self?.heightField.value = Double(p.height)
                self?.fieldsChanged()
            })
        }
        items.append(.separator)
        let custom = currentPreset == nil
        items.append(SQMenuItem(title: "Custom size", isChecked: custom) { [weak self] in self?.widthField.window?.makeFirstResponder(self?.widthField) })
        return items
    }

    private func rateItems() -> [SQMenuItem] {
        SequenceFormatPresets.frameRates.enumerated().map { i, r in
            SQMenuItem(title: r.label + " fps", shortcut: Self.rateNotes[i], isChecked: i == rateIndex) { [weak self] in
                self?.rateIndex = i; self?.refresh()
            }
        }
    }

    private func audioItems() -> [SQMenuItem] {
        audioRates.enumerated().map { i, rate in
            SQMenuItem(title: "\(Self.audioTitle(rate)) · Stereo", isChecked: i == audioIndex) { [weak self] in
                self?.audioIndex = i; self?.refresh()
            }
        }
    }

    private func outsideItems() -> [SQMenuItem] {
        Self.outsideChoices.enumerated().map { i, c in
            SQMenuItem(title: c.1, isChecked: i == outsideIndex) { [weak self] in self?.outsideIndex = i; self?.refresh() }
        }
    }

    // MARK: Behavior

    private var currentPreset: SizePreset? {
        let w = Int(widthField.value.rounded()), h = Int(heightField.value.rounded())
        return Self.sizePresets.first { $0.width == w && $0.height == h }
    }

    /// A template was picked: its size, rate and sample rate fill the controls.
    private func applyTemplate() {
        let f = baseFormat
        widthField.value = Double(f.width); widthField.defaultValue = Double(f.width)
        heightField.value = Double(f.height); heightField.defaultValue = Double(f.height)
        if let i = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == f.frameDuration }) { rateIndex = i }
        if !audioRates.contains(f.audioSampleRate) { audioRates.append(f.audioSampleRate) }
        if let i = audioRates.firstIndex(of: f.audioSampleRate) { audioIndex = i }
        refresh()
    }

    private func fieldsChanged() { refresh() }

    @objc private func swapSize() {
        let w = widthField.value
        widthField.value = heightField.value; heightField.value = w
        refresh()
    }

    @objc private func modeChanged() { fastCut = modeSegmented.selectedSegment == 1; refresh() }

    @objc private func chooseLocation() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Choose"
        p.message = "Choose where the project folder is created"
        p.directoryURL = location
        if p.runModal() == .OK, let url = p.url {
            location = url
            UserDefaults.standard.set(url.path, forKey: Self.locationKey)
            refresh()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Titles of every control and the summary follow the state.
    private func refresh() {
        let f = chosen
        let rate = SequenceFormatPresets.frameRates[rateIndex].label
        templatePopup.title = templates.indices.contains(templateIndex) ? templates[templateIndex].name : ""
        templateHint.stringValue = templates.indices.contains(templateIndex) ? templates[templateIndex].summary : ""
        let preset = currentPreset
        sizePopup.title = preset?.name ?? "Custom size"
        sizeKey.stringValue = preset?.key ?? Self.aspectText(width: f.width, height: f.height)
        let aspect = Self.aspectText(width: f.width, height: f.height)
        aspectHint.stringValue = "\(aspect) · px"
        ratePopup.title = rate + " fps"
        let rateHz = audioRates[audioIndex]
        audioPopup.title = "\(Self.audioTitle(rateHz)) · Stereo"
        modeSegmented.selectedSegment = fastCut ? 1 : 0
        outsidePopup.title = Self.outsideChoices[outsideIndex].1
        pathLabel.stringValue = Self.tildePath(location)
        line1.stringValue = "\(f.width) × \(f.height) · \(rate) fps"
        line2.stringValue = "\(aspect) · \(Self.audioTitle(rateHz)) Stereo · \(fastCut ? "Fast Cut" : "Normal") timeline"
        preview.aspect = f.height > 0 ? CGFloat(f.width) / CGFloat(f.height) : 1
    }

    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: Finish

    @objc private func cancelPressed() { finish(nil) }
    @objc private func createPressed() { create() }

    private func create() {
        panel.makeFirstResponder(nil)       // commits a field being typed in
        guard templates.indices.contains(templateIndex) else { finish(nil); return }
        var template = templates[templateIndex]
        template.format = chosen
        finish(Answer(name: NewProjectInput.name(typed: nameField.stringValue), template: template,
                      mode: Self.outsideChoices[outsideIndex].0, location: location,
                      editMode: fastCut ? .magnetic : .normal))
    }

    private func finish(_ answer: Answer?) {
        guard NSApp.modalWindow === panel else { return }
        result = answer
        NSApp.stopModal()
    }

    /// nil when canceled. `preferred` pre-selects a template. Centered over the key window (start window or editor).
    static func run(templates: [ProjectTemplate], preferred: ProjectTemplate? = nil, over explicitHost: NSWindow? = nil) -> Answer? {
        guard !templates.isEmpty else { return nil }
        let host = explicitHost ?? [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 }.first { !($0 is NSPanel) }
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        let frame = host?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 720)
        let sheet = NewProjectSheet(templates: templates, preferred: preferred, frame: frame)
        host?.addChildWindow(sheet.panel, ordered: .above)
        sheet.panel.makeKeyAndOrderFront(nil)
        sheet.panel.makeFirstResponder(sheet.nameField)
        sheet.nameField.selectText(nil)
        NSApp.runModal(for: sheet.panel)
        host?.removeChildWindow(sheet.panel)
        sheet.panel.orderOut(nil)
        host?.makeKeyAndOrderFront(nil)
        return sheet.result
    }
}

// MARK: - Views

/// Borderless window over the host window: key-capable, Esc and Return routed to the sheet.
@MainActor
private final class SheetPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCreate: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        appearance = Theme.windowAppearance
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Editing a field: Return commits it, Esc drops the edit; the sheet stays open.
            if SQModal.isEditingText(firstResponder) {
                if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".") {
                    _ = SQModal.abortEditing(in: self); return
                }
                if event.keyCode == 36 || event.keyCode == 76 {
                    super.sendEvent(event)
                    SQModal.endEditingAfterCommit(in: self)
                    return
                }
            }
            if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".") {
                onCancel?(); return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.isARepeat { return }
                // A focused button or popup takes Return itself (activates that control).
                if firstResponder is SQButton || firstResponder is SQMenuPopup || firstResponder is SQSegmented {
                    super.sendEvent(event); return
                }
                onCreate?(); return
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The sheet's card: panel fill with radius 14 (the drop shadow comes from `SQModalScrimView`).
private final class SheetCard: NSView {
    let content = FlippedView()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.Colors.panel.cgColor
        content.layer?.cornerRadius = SQDialogMetrics.radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = Theme.Overlay.edgeWidth
        content.layer?.borderColor = Theme.Colors.overlayEdge.cgColor
        addSubview(content)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); content.frame = bounds }
    override var mouseDownCanMoveWindow: Bool { false }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The footer band: `titlebar` (frame) color.
private final class FrameBand: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.titlebar.cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The aspect key drawn inside the frame size box, left of the chevron; clicks fall through to the box.
private final class KeyLabel: NSView {
    var stringValue = "" { didSet { needsDisplay = true } }
    var font = Theme.Typography.start(Theme.Typography.startCaption)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle(); style.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Colors.label3, .paragraphStyle: style]
        let h = (stringValue as NSString).size(withAttributes: attrs).height
        (stringValue as NSString).draw(in: NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h), withAttributes: attrs)
    }
}

/// Location chip: folder icon and the path on a `fill` rounded box.
private final class PathChip: FlippedView {
    init(label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.fill.cgColor
        layer?.cornerRadius = Theme.Radius.startControl
        let icon = NSImageView(image: SQIcon.folder.image(size: 16))
        icon.contentTintColor = Theme.Colors.label2
        icon.frame = NSRect(x: Theme.Metrics.startS3, y: 6, width: 16, height: 16)
        label.font = Theme.Typography.start(Theme.Typography.startLabel)
        label.textColor = Theme.Colors.label2
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon); addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private let label: NSTextField
    override func layout() {
        super.layout()
        let x = Theme.Metrics.startS3 + 16 + Theme.Metrics.startS2
        label.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: max(bounds.width - x - Theme.Metrics.startS3, 0), height: 16)
        subviews.first { $0 is NSImageView }?.frame = NSRect(x: Theme.Metrics.startS3, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
}

/// 44 pt `content` box with the chosen aspect drawn as a clip-colored rectangle.
private final class PreviewBox: NSView {
    var aspect: CGFloat = 9.0 / 16 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.content.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.startControl, yRadius: Theme.Radius.startControl).fill()
        let side: CGFloat = 28
        let a = max(aspect, 0.05)
        let w = a >= 1 ? side : side * a, h = a >= 1 ? side / a : side
        let r = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: max(h, 2))
        Theme.Colors.clipVideo.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
    }
}
