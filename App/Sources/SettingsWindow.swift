import AppKit
import CoreAudio
import SQAudioFX
import SQCore
import SQEditorSession
import SQEditorUI
import SQPlayback

/// Settings (⌘,): an L modal (`SQDialog` on the `SQModal` shell) with a 200 wide sidebar and six pages (General, Playback,
/// Editing, Audio, Media, Advanced), rows from `SQFormRow`, one footer button "Done". Every change is written to
/// UserDefaults at once (`AppSettings`). Autosave interval and audio output are read at launch. The page model and the
/// option inventory live in `SettingsPages.swift` (SQEditorUI).
@MainActor
final class SettingsWindowController: NSObject {
    unowned let controller: AppController
    private var dialog: SQDialog?
    private var root: SQDialogForm?
    private var currentPage = SettingsPage.general

    private let autosavePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let uiScalePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let outsideMediaPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let libraryCopyCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let watchFolderCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let cardImportCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let growingFilesCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let proxiesExportCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let autoLanguageCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let recoveryCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let updateCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let qualityPopUp = SQPopup(frame: .zero, pullsDown: false)
    /// Frame cache of both monitors: Auto (tag 0) or a size in GB (tag = GB).
    private let cacheSizePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let backgroundCheck = SQCheckbox(title: "", target: nil, action: nil)
    /// Preview render cache on/off and its disk cap (tag = GB; `AppSettings.renderCacheCapChoices`).
    private let renderCacheCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let renderCacheCapPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let prerollPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let postrollPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let textDurationPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let languagePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let uiLanguagePopUp = SQPopup(frame: .zero, pullsDown: false)
    /// "Restart Sequence Studio to apply the language." + Restart button, shown while the chosen language differs from the running one.
    private lazy var languageRestartLine: NSStackView = {
        let note = value(SQL10n.string("Restart Sequence Studio to apply the language."), Theme.Colors.label2)
        let button = SQButton(title: "Restart", target: self, action: #selector(restartForLanguage), style: .standard)
        let line = NSStackView(views: [note, button])
        line.orientation = .horizontal; line.alignment = .centerY; line.spacing = Theme.Spacing.sm
        line.isHidden = !SQL10n.restartPending
        return line
    }()
    private let deClickCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let liveDuckCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let liveDuckAmount = SQDialog.makeNumberField(value: 12, range: 0.5...40, step: 0.5, decimals: 1, unit: "dB", defaultValue: 12, width: nil)
    private let liveDuckPreset = SQPopup(frame: .zero, pullsDown: false)
    /// Lookahead, attack, hold, recovery and minimum pause of the live duck (`DuckTiming`, same controls as the project dialog).
    private let liveDuckTiming = DuckTimingForm(timing: DuckTiming.stored())
    /// "Normal | Fast Cut" = `AppSettings.newSequenceEditMode` (`sq.newSequenceEditMode`): segment 0 = Normal.
    private let newSequenceModeSegmented = SQSegmented(labels: ["Normal", "Fast Cut"], segmentWidth: 0)
    private let scrubbingCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let dropDotCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let cachePath = SQDialog.makeField("", width: 300)
    /// Cache size cap (tag = GB; `AppSettings.cacheCapChoices`): applies to the proxy cache at once.
    private let cacheCapPopUp = SQPopup(frame: .zero, pullsDown: false)
    /// Audio output device: item 0 = system default; the others carry the CoreAudio UID as `representedObject`.
    private let audioOutputPopUp = SQPopup(frame: .zero, pullsDown: false)
    /// `MeterStyle` (`sq.audio.meterBallistics`) and `FadeCurve` (`sq.audio.defaultFadeCurve`); item `representedObject` = raw value.
    private let meterStylePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let fadeCurvePopUp = SQPopup(frame: .zero, pullsDown: false)
    /// Crossfade kind (`AudioRoleDefaults.crossfadeKind`) and the per-role J / L offsets and audio transition lengths.
    private let crossfadePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let roleOffsetFields: [AudioTag: ScrubField] = Dictionary(uniqueKeysWithValues: AudioTag.allCases.map {
        ($0, SQDialog.makeNumberField(value: 0.25, range: 0.05...10, step: 0.05, decimals: 2, defaultValue: AudioRoleDefaults.standard.splitOffsetSeconds[$0] ?? 0.25, width: nil))
    })
    private let roleTransitionFields: [AudioTag: ScrubField] = Dictionary(uniqueKeysWithValues: AudioTag.allCases.map {
        ($0, SQDialog.makeNumberField(value: 1, range: 0.05...600, step: 0.05, decimals: 2, defaultValue: AudioRoleDefaults.standard.transitionSeconds[$0] ?? 1, width: nil))
    })
    private let cacheNote = NSTextField(wrappingLabelWithString: "")
    /// Scratch and projects roots (`StorageLocations`, keys `sq.storage.*`).
    private let scratchPath = SQDialog.makeField("", width: 300)
    private let projectsPath = SQDialog.makeField("", width: 300)
    private var scratchResetButton: SQButton?
    private var projectsResetButton: SQButton?
    private var cacheResetButton: SQButton?
    private let usedLabel = NSTextField(labelWithString: "")
    /// Frames; double-click resets to 0 (= one second).
    private let videoTransitionField = SQDialog.makeNumberField(range: 0...10_000, step: 1, defaultValue: 0, width: nil)
    private let audioTransitionField = SQDialog.makeNumberField(value: 1, range: 0.05...600, step: 0.05, decimals: 2, defaultValue: 1, width: nil)
    /// LUFS the Audio Gain sheet's "Normalize Loudness to" row starts at.
    private let apiCheck = SQCheckbox(title: "", target: nil, action: nil)
    private let apiDot = NSView()
    private let apiStatusText = NSTextField(labelWithString: "")
    private var apiCopy: SQButton?
    private var apiState = EditAPIRunState.notRunning

    private var pageViews: [SettingsPage: NSView] = [:]
    private var sidebarRows: [SettingsPage: SettingsSidebarRow] = [:]
    private let bodyHost = SettingsFlippedView()
    private let bodyScroll = NSScrollView()

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    /// Opens the modal over the main window; a second call while it shows does nothing.
    func show(page: SettingsPage? = nil, over explicitHost: NSWindow? = nil) {
        guard dialog == nil else { return }
        if let page { currentPage = page }
        let content = buildIfNeeded()
        load()
        refreshLibraryFolders()
        observeLibraryFolders()
        let d = SQDialog()
        d.messageText = SQL10n.string("Settings")
        d.accessoryView = content
        d.width = Theme.Modal.widthL
        d.cardHeight = Theme.Modal.heightL
        d.addButton(SQL10n.string("Done"), role: .default)
        dialog = d
        let finish: @MainActor (SQDialog.Response) -> Void = { [weak self] _ in self?.dialog = nil }
        if let host = explicitHost ?? NSApp.keyWindow ?? NSApp.mainWindow {
            d.beginSheetModal(for: host, completion: finish)
        } else {
            finish(d.runModal())
        }
    }

    /// Render harness (`scripts/render-panels.sh`): page `page` as the modal body (sidebar and page, no card), without showing it.
    func renderPage(_ page: SettingsPage) -> NSView? {
        let content = buildIfNeeded()
        load()
        refreshLibraryFolders()
        select(page)
        content.frame = NSRect(x: 0, y: 0, width: Theme.Modal.widthL, height: Theme.Modal.heightL - Theme.Modal.headerHeight - Theme.Modal.footerHeight)
        content.layoutSubtreeIfNeeded()
        return content
    }

    // MARK: Build

    private func buildIfNeeded() -> SQDialogForm {
        if let root { return root }
        for p in SettingsPage.allCases { pageViews[p] = SQFormRow.page(rows(for: p)) }
        controller.editAPI.onState = { [weak self] s in self?.applyAPIState(s) }

        let sidebar = NSStackView()
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = Theme.Spacing.xxs
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        for p in SettingsPage.allCases {
            let r = SettingsSidebarRow(page: p) { [weak self] in self?.select(p) }
            sidebarRows[p] = r
            sidebar.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        let side = NSView()
        side.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(sidebar)
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.Colors.separator.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.documentView = bodyHost
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        SQScrollView.apply(to: bodyScroll)
        bodyHost.translatesAutoresizingMaskIntoConstraints = false

        let split = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        for v in [side, rule, bodyScroll] { split.addSubview(v) }
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: split.topAnchor), side.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            side.widthAnchor.constraint(equalToConstant: SettingsPage.sidebarWidth),
            sidebar.topAnchor.constraint(equalTo: side.topAnchor, constant: Theme.Spacing.md),
            sidebar.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: Theme.Spacing.sm),
            sidebar.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -Theme.Spacing.sm),
            rule.leadingAnchor.constraint(equalTo: side.trailingAnchor), rule.widthAnchor.constraint(equalToConstant: 1),
            rule.topAnchor.constraint(equalTo: split.topAnchor), rule.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            bodyScroll.leadingAnchor.constraint(equalTo: rule.trailingAnchor), bodyScroll.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: split.topAnchor), bodyScroll.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            bodyHost.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
        ])
        let form = SQDialogForm(rows: [split])
        root = form
        select(currentPage)
        return form
    }

    private func select(_ page: SettingsPage) {
        currentPage = page
        for (p, r) in sidebarRows { r.isSelected = p == page }
        bodyHost.subviews.forEach { $0.removeFromSuperview() }
        guard let v = pageViews[page] else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: bodyHost.topAnchor, constant: Theme.Modal.bodyPadV),
            v.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor, constant: Theme.Modal.bodyPadH),
            v.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor, constant: -Theme.Modal.bodyPadH),
            v.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor, constant: -Theme.Modal.bodyPadV),
        ])
        bodyScroll.contentView.scroll(to: .zero)
    }

    private func rows(for page: SettingsPage) -> [NSView] {
        switch page {
        case .general: generalRows()
        case .playback: playbackRows()
        case .editing: editingRows()
        case .audio: audioRows()
        case .media: mediaRows()
        case .advanced: advancedRows()
        }
    }

    // MARK: Small builders

    private func value(_ text: String, _ color: NSColor = Theme.Dialog.titleColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.Typography.body; l.textColor = color
        return l
    }

    private var labelBoxes: [ObjectIdentifier: SQCheckbox] = [:]

    /// Checkbox with its text 8 pt to the right; a click on the text toggles the box.
    private func checkItem(_ box: SQCheckbox, _ text: String, trailing: [NSView] = []) -> NSStackView {
        let l = value(SQL10n.string(text))
        box.setAccessibilityLabel(SQL10n.string(text))
        let click = NSClickGestureRecognizer(target: self, action: #selector(labelClicked(_:)))
        l.addGestureRecognizer(click)
        labelBoxes[ObjectIdentifier(click)] = box
        let s = NSStackView(views: [box, l] + trailing)
        s.alignment = .centerY
        s.spacing = Theme.Spacing.sm
        return s
    }

    @objc private func labelClicked(_ g: NSClickGestureRecognizer) {
        guard let box = labelBoxes[ObjectIdentifier(g)], box.isEnabled else { return }
        box.state = box.state == .on ? .off : .on
        if let action = box.action { NSApp.sendAction(action, to: box.target, from: box) }
    }

    private func fixed(_ v: NSView, _ w: CGFloat) -> NSView { SQFormRow.width(v, w) }

    // MARK: Pages

    private func generalRows() -> [NSView] {
        for (i, v) in AppSettings.autosaveChoices.enumerated() {
            autosavePopUp.addItem(withTitle: v < 120 ? "Every minute" : "Every \(Int(v / 60)) minutes")
            autosavePopUp.lastItem?.tag = i
        }
        autosavePopUp.target = self; autosavePopUp.action = #selector(changed)
        recoveryCheck.target = self; recoveryCheck.action = #selector(changed)
        updateCheck.target = self; updateCheck.action = #selector(changed)
        for s in AppSettings.textDurationChoices { textDurationPopUp.addItem(withTitle: s == 1 ? "1 second" : "\(s) seconds"); textDurationPopUp.lastItem?.tag = s }
        textDurationPopUp.target = self; textDurationPopUp.action = #selector(changed)
        for id in CaptionsPanelModel.defaultLanguages {
            languagePopUp.addItem(withTitle: Locale.current.localizedString(forIdentifier: id) ?? id)
            languagePopUp.lastItem?.representedObject = id
        }
        languagePopUp.target = self; languagePopUp.action = #selector(changed)
        for v in UIScale.steps { uiScalePopUp.addItem(withTitle: "\(Int((v * 100).rounded())) %") }
        uiScalePopUp.selectItem(at: UIScale.steps.firstIndex(of: UIScale.pending) ?? 2)
        uiScalePopUp.target = self; uiScalePopUp.action = #selector(uiScaleChanged)
        uiLanguagePopUp.addItem(withTitle: SQL10n.string("System")); uiLanguagePopUp.lastItem?.representedObject = "system"
        for code in SQL10n.supported {
            // Each language in its own name, so it can be found whatever the current language is.
            let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            uiLanguagePopUp.addItem(withTitle: name.prefix(1).uppercased() + name.dropFirst())
            uiLanguagePopUp.lastItem?.representedObject = code
        }
        let stored = UserDefaults.standard.string(forKey: SQL10n.defaultsKey) ?? "system"
        if let i = uiLanguagePopUp.itemArray.firstIndex(where: { $0.representedObject as? String == stored }) { uiLanguagePopUp.selectItem(at: i) }
        uiLanguagePopUp.target = self; uiLanguagePopUp.action = #selector(uiLanguageChanged)
        return [SQFormRow.row("Interface Language", fixed(uiLanguagePopUp, 180), help: "The language of menus, panels and settings. Applies the next time Sequence Studio starts.",
                             extra: [languageRestartLine]),
                SQFormRow.row("Interface Size", fixed(uiScalePopUp, 180), help: "Scales text and controls everywhere, right away."),
                SQFormRow.row("Autosave", fixed(autosavePopUp, 180), help: "Changed projects are saved to a recovery copy; your project file is only written when you save."),
                SQFormRow.row("Recovery", checkItem(recoveryCheck, "Offer to restore after an unclean quit"), help: "Changed projects are saved to a recovery copy; this offers to restore it after an unclean quit."),
                SQFormRow.row("Updates", checkItem(updateCheck, "Check for a newer version at launch"), help: UpdateCheck.feedURL.isEmpty ? "Not set up in this build yet: nothing is contacted." : "Asks one address for the newest version number; nothing else is sent."),
                SQFormRow.caption("New items"),
                SQFormRow.row("New Text Length", fixed(textDurationPopUp, 180)),
                SQFormRow.row("Transcription", fixed(languagePopUp, 180), help: "The language spoken in your footage. A project can pick another language in the Captions panel."),
                SQFormRow.row("Auto Language", checkItem(autoLanguageCheck, "Run again in the language the text turns out to be"), help: "When a transcription clearly comes out in another language the list offers, it is transcribed once more in that language. Takes effect the next time a sequence opens.")]
    }

    @objc private func uiLanguageChanged() {
        guard let code = uiLanguagePopUp.selectedItem?.representedObject as? String else { return }
        if code == "system" { UserDefaults.standard.removeObject(forKey: SQL10n.defaultsKey) }
        else { UserDefaults.standard.set(code, forKey: SQL10n.defaultsKey) }
        languageRestartLine.isHidden = !SQL10n.restartPending
    }

    @objc private func restartForLanguage() { AppRelaunch.relaunch() }

    @objc private func uiScaleChanged() {
        let i = uiScalePopUp.indexOfSelectedItem
        guard UIScale.steps.indices.contains(i) else { return }
        UIScale.set(UIScale.steps[i])
    }

    private func playbackRows() -> [NSView] {
        let budget = controller.memoryBudget
        let autoQ = MonitorQuality(budget.autoPreviewQuality)
        qualityPopUp.addItem(withTitle: "Auto (\(autoQ.title))"); qualityPopUp.lastItem?.representedObject = Self.autoTag
        for q in MonitorQuality.allCases { qualityPopUp.addItem(withTitle: q.title); qualityPopUp.lastItem?.representedObject = q.rawValue }
        qualityPopUp.target = self; qualityPopUp.action = #selector(changed)
        for (g, title) in zip(FrameCacheChoices.values(for: budget), FrameCacheChoices.titles(for: budget)) {
            cacheSizePopUp.addItem(withTitle: title); cacheSizePopUp.lastItem?.tag = g
        }
        cacheSizePopUp.target = self; cacheSizePopUp.action = #selector(changed)
        backgroundCheck.target = self; backgroundCheck.action = #selector(changed)
        renderCacheCheck.target = self; renderCacheCheck.action = #selector(changed)
        for g in AppSettings.renderCacheCapChoices { renderCacheCapPopUp.addItem(withTitle: "\(g) GB"); renderCacheCapPopUp.lastItem?.tag = g }
        renderCacheCapPopUp.target = self; renderCacheCapPopUp.action = #selector(changed)
        let ramGB = Int((Double(budget.physicalMemory) / Double(MemoryBudget.gib)).rounded())
        for pop in [prerollPopUp, postrollPopUp] {
            for n in AppSettings.rollChoices { pop.addItem(withTitle: n == 1 ? "1 second" : "\(n) seconds") }
            pop.target = self; pop.action = #selector(changed)
        }
        scrubbingCheck.target = self; scrubbingCheck.action = #selector(changed)
        dropDotCheck.target = self; dropDotCheck.action = #selector(changed)
        audioOutputPopUp.target = self; audioOutputPopUp.action = #selector(audioOutputChanged)
        fillAudioOutputPopUp()
        return [SQFormRow.row("Preview Quality", fixed(qualityPopUp, 180), help: "The monitors' playback resolution at launch; change it any time in the monitor. Auto picks 1/2 on Macs with 8 GB or less and lowers the resolution while memory runs low. Export always uses full quality."),
                SQFormRow.row("Frame Cache", fixed(cacheSizePopUp, 180), help: SQL10n.format("Memory for decoded frames of both monitors (this Mac: %@ GB). More plays back smoother, less leaves room for other apps. Auto scales with your Mac and shrinks when memory runs low.", String(ramGB))),
                SQFormRow.row("Background Work", checkItem(backgroundCheck, "Make proxies while you edit"), help: "Heavy clips get a lighter playback copy in the background. Turn off on a slow Mac to keep it quiet; it also pauses by itself when the Mac is hot or memory runs low."),
                SQFormRow.row("Render Cache", checkItem(renderCacheCheck, "Render heavy parts while idle"), help: "Stretches with effects, speed changes, transitions or several layers are rendered to disk in the background while you do not edit or play, then play smoothly from there. Edits make a new render; old ones age out. Pauses when the Mac is hot or busy."),
                SQFormRow.row("Render Cache Size", fixed(renderCacheCapPopUp, 120), help: "Most disk the render cache may use. The least recently used renders go first."),
                SQFormRow.caption("Play around"),
                SQFormRow.row("Preroll", fixed(prerollPopUp, 120), help: "Seconds played before the marked range (Shift+Space) or the playhead (Shift+K)."),
                SQFormRow.row("Postroll", fixed(postrollPopUp, 120), help: "Seconds played after the marked range or the playhead."),
                SQFormRow.caption("Feedback"),
                SQFormRow.row("Audio Output", fixed(audioOutputPopUp, 260), help: "Where both monitors play sound. System Default follows the Mac's output; a device that is not connected falls back to it."),
                SQFormRow.row("Audio Scrubbing", checkItem(scrubbingCheck, "Play sound while dragging the playhead")),
                SQFormRow.row("Dropped Frames", checkItem(dropDotCheck, "Show a dot when frames are dropped"), help: "A small dot in the Program monitor turns amber for two seconds when playback drops a frame. Hover it for the count of the last play.")]
    }

    private func editingRows() -> [NSView] {
        newSequenceModeSegmented.target = self; newSequenceModeSegmented.action = #selector(changed)
        for f in [videoTransitionField, audioTransitionField] { f.onEnd = { [weak self] _ in self?.transitionDefaultsChanged() }; f.valueTint = Theme.Colors.label }
        return [SQFormRow.row("New Sequences Start in", newSequenceModeSegmented, help: "Normal keeps classic tracks and Delete leaves a gap (Shift+Delete closes it). Fast Cut closes gaps on the main track by itself and keeps clips above and below attached to their clip. You can switch any sequence later in the timeline header."),
                SQFormRow.caption("Default transition length"),
                SQFormRow.numberRow("Video Transition", field: videoTransitionField, unit: "frames", note: "· 0 means 1 second",
                                    help: "Default length of transitions placed with Command-D, Shift-Command-D and Shift-D. Existing transitions do not change."),
                SQFormRow.numberRow("Audio Transition", field: audioTransitionField, unit: "seconds"),
                SQFormRow.caption("Your effect and transition defaults"),
                EffectDefaultsSettingsView()]
    }

    private func audioRows() -> [NSView] {
        deClickCheck.target = self; deClickCheck.action = #selector(deClickChanged)
        liveDuckCheck.target = self; liveDuckCheck.action = #selector(liveDuckChanged)
        liveDuckAmount.onEnd = { [weak self] _ in self?.liveDuckChanged() }
        _ = fixed(liveDuckAmount, 92)
        liveDuckPreset.addItem(withTitle: "Custom")
        for p in DuckPreset.all { liveDuckPreset.addItem(withTitle: SQL10n.string(p.title)) }
        liveDuckPreset.target = self; liveDuckPreset.action = #selector(liveDuckPresetPicked)
        let duck = checkItem(liveDuckCheck, "Duck music under dialogue while mixing", trailing: [liveDuckAmount])
        liveDuckTiming.onChange = { [weak self] in DuckTiming.store($0); self?.syncDuckPresetPopup() }
        let grid = SQFormRow.unitGrid(liveDuckTiming.titledFields)
        for style in MeterStyle.allCases {
            meterStylePopUp.addItem(withTitle: SQL10n.string(style.title)); meterStylePopUp.lastItem?.representedObject = style.rawValue
        }
        for curve in FadeCurve.allCases {
            fadeCurvePopUp.addItem(withTitle: SQL10n.string(curve.title)); fadeCurvePopUp.lastItem?.representedObject = curve.rawValue
        }
        for kind in TransitionKind.kinds(for: .audio) {
            crossfadePopUp.addItem(withTitle: SQL10n.string(kind.name)); crossfadePopUp.lastItem?.representedObject = kind.rawValue
        }
        crossfadePopUp.target = self; crossfadePopUp.action = #selector(roleDefaultsChanged)
        for f in Array(roleOffsetFields.values) + Array(roleTransitionFields.values) {
            f.onEnd = { [weak self] _ in self?.roleDefaultsChanged() }; f.valueTint = Theme.Colors.label
        }
        let offsetGrid = SQFormRow.unitGrid(AudioTag.allCases.map { (title: SQL10n.string($0.title), field: roleOffsetFields[$0]!) })
        let lengthGrid = SQFormRow.unitGrid(AudioTag.allCases.map { (title: SQL10n.string($0.title), field: roleTransitionFields[$0]!) })
        meterStylePopUp.target = self; meterStylePopUp.action = #selector(meterStyleChanged)
        fadeCurvePopUp.target = self; fadeCurvePopUp.action = #selector(fadeCurveChanged)
        return [SQFormRow.row("De-Click", checkItem(deClickCheck, "Fade clip edges to prevent clicks"), help: "A 3 ms fade at the start and end of every audio clip, so hard cuts never pop. Playback and export."),
                SQFormRow.caption("Ducking"),
                SQFormRow.row("Live Ducking", duck, help: "Music-role tracks follow Dialogue-role tracks while mixing (playback and export). Off by default. A clip that also has baked Auto Duck keys ducks twice."),
                SQFormRow.row("Duck Preset", fixed(liveDuckPreset, 180),
                              help: "Soft is a shallow duck with a slow return for voice-over. Hard is a deep, quick duck for fast speech. Change the amount or any timing value and it shows Custom."),
                SQFormRow.row("Duck Timing", fixed(liveDuckTiming.preset, 180),
                              help: "Lookahead starts the duck early, Attack and Recovery are the ramps down and back up, Hold keeps the duck after speech, Minimum pause is the shortest gap that lets the music come back. Classic is the original 300 ms fade each way.", extra: [grid]),
                SQFormRow.caption("Roles"),
                SQFormRow.row("Crossfade", fixed(crossfadePopUp, 180), help: "The kind of crossfade the default audio transition places (Shift-Command-D)."),
                SQFormRow.row("J / L Offset", [], help: "Seconds the audio edit moves for a J or L cut with the offset shortcut, by the role of the clip.", extra: [offsetGrid]),
                SQFormRow.row("Crossfade Length", [], help: "Seconds a default audio transition gets on a clip with this role. Untagged clips use the Audio Transition length on the Editing page.", extra: [lengthGrid]),
                SQFormRow.caption("Metering and fades"),
                SQFormRow.row("Meter Response", fixed(meterStylePopUp, 180),
                              help: "How fast the level meters fall and how long the peak marker holds. Smooth is calm, Fast follows every peak."),
                SQFormRow.row("Fade Shape", fixed(fadeCurvePopUp, 180),
                              help: "The shape a new audio fade gets when you drag its handle. Existing fades keep theirs.")]
    }

    @objc private func roleDefaultsChanged() {
        var d = AudioRoleDefaults.load()
        for r in AudioTag.allCases {
            if let v = roleOffsetFields[r]?.value, v > 0 { d.splitOffsetSeconds[r] = (v * 100).rounded() / 100 }
            if let v = roleTransitionFields[r]?.value, v > 0 { d.transitionSeconds[r] = (v * 100).rounded() / 100 }
        }
        if let raw = crossfadePopUp.selectedItem?.representedObject as? String, let k = TransitionKind(rawValue: raw) { d.crossfadeKind = k }
        d.save()
    }

    @objc private func meterStyleChanged() {
        guard let raw = meterStylePopUp.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: MeterStyle.defaultsKey)
    }

    @objc private func fadeCurveChanged() {
        guard let raw = fadeCurvePopUp.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: DefaultFadeCurve.defaultsKey)
    }

    @objc private func liveDuckChanged() {
        liveDuckAmount.isEnabled = liveDuckCheck.state == .on
        let db = DuckPreset.clampedAmount(liveDuckAmount.value)
        liveDuckAmount.value = db
        LiveDucking.setAmount(liveDuckCheck.state == .on ? db : nil)
        syncDuckPresetPopup()
    }

    @objc private func liveDuckPresetPicked() {
        let i = liveDuckPreset.indexOfSelectedItem - 1
        guard DuckPreset.all.indices.contains(i) else { return }
        let p = DuckPreset.all[i]
        liveDuckAmount.value = p.amountDB
        liveDuckTiming.timing = p.timing
        DuckTiming.store(p.timing)
        liveDuckChanged()
    }

    private func syncDuckPresetPopup() {
        let match = DuckPreset.matching(amountDB: liveDuckAmount.value, timing: liveDuckTiming.timing)
        liveDuckPreset.selectItem(at: match.flatMap { DuckPreset.all.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    private func loadLiveDucking() {
        let current = LiveDucking.current()
        liveDuckCheck.state = current == nil ? .off : .on
        liveDuckAmount.value = current?.amountDB ?? Ducking.defaultAmountDB
        liveDuckAmount.isEnabled = current != nil
        syncDuckPresetPopup()
    }

    @objc private func deClickChanged() { AudioDeClick.isEnabled = deClickCheck.state == .on }

    private func mediaRows() -> [NSView] {
        cachePath.isEditable = false
        cachePath.setAccessibilityLabel("Cache folder")
        usedLabel.textColor = Theme.Colors.label2; usedLabel.font = Theme.Typography.body
        let clear = SQButton(title: "Delete Cache", target: self, action: #selector(clearCache), style: .standard)
        let choose = SQButton(title: "Choose…", target: self, action: #selector(chooseCacheFolder), style: .standard)
        let reset = SQButton(title: "Use Default", target: self, action: #selector(resetCacheFolder), style: .standard)
        cacheResetButton = reset
        for g in AppSettings.cacheCapChoices { cacheCapPopUp.addItem(withTitle: "\(g) GB"); cacheCapPopUp.lastItem?.tag = g }
        cacheCapPopUp.target = self; cacheCapPopUp.action = #selector(cacheCapChanged)
        cacheNote.font = Theme.Typography.body; cacheNote.textColor = Theme.Colors.label2
        cardImportCheck.target = self; cardImportCheck.action = #selector(cardImportChanged(_:))
        growingFilesCheck.target = self; growingFilesCheck.action = #selector(changed)
        proxiesExportCheck.target = self; proxiesExportCheck.action = #selector(changed)
        autoLanguageCheck.target = self; autoLanguageCheck.action = #selector(changed)
        let defaults = MediaSettings.defaults
        outsideMediaPopUp.removeAllItems()
        for m in OutsideMediaMode.allCases {
            outsideMediaPopUp.addItem(withTitle: m == .ask ? "Ask" : m.title)
            outsideMediaPopUp.lastItem?.representedObject = m.rawValue
        }
        outsideMediaPopUp.selectItem(at: OutsideMediaMode.allCases.firstIndex(of: defaults.outside) ?? 0)
        outsideMediaPopUp.target = self; outsideMediaPopUp.action = #selector(mediaPolicyChanged)
        libraryCopyCheck.target = self; libraryCopyCheck.action = #selector(mediaPolicyChanged)
        watchFolderCheck.target = self; watchFolderCheck.action = #selector(mediaPolicyChanged)
        let add = SQButton(title: "Add Folder…", target: self, action: #selector(addLibraryFolder), style: .standard)
        return [SQFormRow.row("Outside Files", fixed(outsideMediaPopUp, 180), help: "What happens to files dropped from outside the project folder. Files already inside the project folder are always used where they are. A project can override this in File > Media Management."),
                SQFormRow.row("Project Folder", checkItem(watchFolderCheck, "Add new files in the project folder to the bin"), help: "New files and folders appear in the bin, linked in place; removed files go offline."),
                SQFormRow.row("Card Import", checkItem(cardImportCheck, "Open the import window when a card is connected"), help: "You choose per import: copy the files into the Media folder next to your project, or use them directly from the card."),
                SQFormRow.row("Growing Files", checkItem(growingFilesCheck, "Refresh clips of files that are still being recorded"), help: "Looks every few seconds at project files that grow or get re-rendered and updates their length, thumbnails and waveform. It pauses during playback and export. Off: files are checked when you come back to the app."),
                SQFormRow.caption("Library"),
                SQFormRow.row("Library", checkItem(libraryCopyCheck, "Copy library items used in a sequence into the project"), help: "Sounds, music, video, images and LUTs are copied to Files/Library in the background, once per unique file."),
                SQFormRow.row("Library Folders", EffectDefaultsSettingsView.box(libraryFoldersStack), help: "Folders of sounds, music, graphics, video and LUTs. They appear in the Library panel of every project. Using an item in a sequence copies it into the project.", extra: [add]),
                SQFormRow.caption("Cache"),
                SQFormRow.row("Cache Folder", cachePath, help: "Proxies are stored in the Proxies folder inside it. A new folder applies at the next launch; proxies already made stay in the old folder (Delete Cache there is safe, they are rebuilt when needed).", extra: [choose, reset]),
                SQFormRow.row("Cache Size", fixed(cacheCapPopUp, 120), help: "Most disk the proxy cache may use. The least recently used proxies go first, never one a monitor is playing."),
                SQFormRow.row("Export", checkItem(proxiesExportCheck, "Use proxies when exporting"), help: "Renders from the ready proxies instead of the original files: much faster, lower quality. For drafts and review copies only. Clips without a ready proxy use the original, and smart-render copies stay original. Off by default."),
                SQFormRow.row("", [cacheNote]),
                SQFormRow.row("", [usedLabel, clear], help: "Clearing the cache is safe: files are rebuilt when needed.")]
            + storageRows()
    }

    // MARK: Scratch and projects folders (`StorageLocations`)

    private func storageRows() -> [NSView] {
        scratchPath.isEditable = false; scratchPath.setAccessibilityLabel("Scratch folder")
        projectsPath.isEditable = false; projectsPath.setAccessibilityLabel("Projects folder")
        let sChoose = SQButton(title: "Choose…", target: self, action: #selector(chooseScratchFolder), style: .standard)
        let sReset = SQButton(title: "Use Default", target: self, action: #selector(resetScratchFolder), style: .standard)
        let pChoose = SQButton(title: "Choose…", target: self, action: #selector(chooseProjectsFolder), style: .standard)
        let pReset = SQButton(title: "Use Default", target: self, action: #selector(resetProjectsFolder), style: .standard)
        scratchResetButton = sReset; projectsResetButton = pReset
        refreshStorageRows()
        return [SQFormRow.caption("Folders"),
                SQFormRow.row("Scratch Folder", scratchPath, help: "Temporary working files such as pasted images of an unsaved project. Defaults to the Scratch folder inside the cache folder. Applies at once.", extra: [sChoose, sReset]),
                SQFormRow.row("Projects Folder", projectsPath, help: "Where new projects are created and suggested. Defaults to ~/Movies/Sequence Studio.", extra: [pChoose, pReset])]
    }

    private func refreshStorageRows() {
        let l = StorageLocations.load()
        scratchPath.stringValue = (l.scratchRoot.path as NSString).abbreviatingWithTildeInPath
        projectsPath.stringValue = (l.projectsRoot.path as NSString).abbreviatingWithTildeInPath
        scratchResetButton?.isEnabled = l.scratchFolder != nil
        projectsResetButton?.isEnabled = l.projectsFolder != nil
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func setStorageFolder(scratch: Bool, _ url: URL?) {
        if let problem = StorageFolderChoice.setFolder(scratch: scratch, url) { cacheNote.stringValue = problem; return }
        cacheNote.stringValue = ""
        refreshStorageRows()
    }

    @objc private func chooseScratchFolder() { if let u = pickFolder() { setStorageFolder(scratch: true, u) } }
    @objc private func resetScratchFolder() { setStorageFolder(scratch: true, nil) }
    @objc private func chooseProjectsFolder() { if let u = pickFolder() { setStorageFolder(scratch: false, u) } }
    @objc private func resetProjectsFolder() { setStorageFolder(scratch: false, nil) }

    // MARK: Library folders (app-wide, `sq.library.folders`)

    private let libraryFoldersStack: NSStackView = {
        let s = NSStackView(); s.orientation = .vertical; s.alignment = .width; s.spacing = 0
        return s
    }()

    private var observingLibraryFolders = false

    /// Keeps the list in step with the Library model (a folder added in the Library panel, one going unavailable).
    private func observeLibraryFolders() {
        guard !observingLibraryFolders, let model = controller.panels?.libraryModel else { return }
        observingLibraryFolders = true
        track(model)
    }

    private func track(_ model: LibraryPanelModel) {
        withObservationTracking { _ = model.folders } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshLibraryFolders()
                self.track(model)
            }
        }
    }

    private func refreshLibraryFolders() {
        libraryFoldersStack.arrangedSubviews.forEach { libraryFoldersStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let folders = controller.panels?.libraryModel.folders ?? []
        if folders.isEmpty {
            libraryFoldersStack.addArrangedSubview(Self.listLine([value("No folders yet.", Theme.Colors.label3)]))
        }
        for (i, row) in folders.enumerated() {
            let offline = row.state == .offline
            let icon = NSImageView(image: Theme.symbol(.folder, size: 13) ?? NSImage())
            icon.contentTintColor = Theme.Colors.label3
            let name = value(row.folder.displayName, offline ? Theme.Colors.label3 : Theme.Dialog.titleColor)
            name.setContentHuggingPriority(.required, for: .horizontal)
            name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let path = value((row.folder.url.path as NSString).abbreviatingWithTildeInPath, Theme.Dialog.hintColor)
            path.lineBreakMode = .byTruncatingMiddle
            path.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            path.setContentHuggingPriority(.init(1), for: .horizontal)
            var views: [NSView] = [icon, name, path]
            if offline { views.append(value("unavailable", Theme.Colors.warning)) }
            let remove = SQButton(title: "Remove", target: self, action: #selector(removeLibraryFolder(_:)), style: .standard)
            remove.tag = i
            remove.setAccessibilityLabel("Remove \(row.folder.displayName)")
            views.append(remove)
            libraryFoldersStack.addArrangedSubview(Self.listLine(views))
        }
    }

    /// One list line: 28 high at least, 12 inside the box edge.
    private static func listLine(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.alignment = .centerY; row.spacing = Theme.Spacing.sm
        row.edgeInsets = NSEdgeInsets(top: .zero, left: Theme.Spacing.md, bottom: .zero, right: Theme.Spacing.md)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: SQFormRow.lineHeight).isActive = true
        return row
    }

    @objc private func addLibraryFolder() {
        guard let model = controller.panels?.libraryModel else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        Task { [weak self] in
            await model.addFolder(url: url, bookmark: bookmark)
            self?.refreshLibraryFolders()
        }
    }

    @objc private func removeLibraryFolder(_ sender: NSControl) {
        guard let model = controller.panels?.libraryModel, model.folders.indices.contains(sender.tag) else { return }
        let id = model.folders[sender.tag].id
        Task { [weak self] in
            await model.removeFolder(id)
            self?.refreshLibraryFolders()
        }
    }

    // MARK: Advanced (Edit API)

    private func advancedRows() -> [NSView] {
        apiCheck.target = self; apiCheck.action = #selector(apiChanged)
        apiDot.wantsLayer = true
        apiDot.layer?.cornerRadius = Theme.Radius.small
        apiDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([apiDot.widthAnchor.constraint(equalToConstant: 8), apiDot.heightAnchor.constraint(equalToConstant: 8)])
        apiStatusText.font = Theme.Typography.body
        let copy = SQButton(symbol: .copy, label: "Copy address", target: self, action: #selector(copyAPIAddress))
        apiCopy = copy
        let status = NSStackView(views: [apiDot, apiStatusText, copy])
        status.alignment = .centerY; status.spacing = Theme.Spacing.sm
        applyAPIState(controller.editAPI.state)
        return [SQFormRow.row("Edit API", checkItem(apiCheck, "Allow local tools to edit the open project"), help: "Only programs on this Mac can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md.", extra: [status])]
    }

    private func applyAPIState(_ s: EditAPIRunState) {
        apiState = s
        apiStatusText.stringValue = s.text
        let color: NSColor = switch s.tone {
        case .idle: Theme.Colors.label3
        case .ok: Theme.Colors.green
        case .warning: Theme.Colors.warning
        }
        apiStatusText.textColor = s.tone == .idle ? Theme.Colors.label3 : Theme.Colors.label2
        apiDot.layer?.backgroundColor = color.cgColor
        apiCopy?.isHidden = s.copyablePort == nil
    }

    @objc private func copyAPIAddress() {
        guard let port = apiState.copyablePort else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("127.0.0.1:\(port)", forType: .string)
    }

    @objc private func apiChanged() {
        EditAPIController.isEnabled = apiCheck.state == .on
        controller.editAPI.sync()
        applyAPIState(controller.editAPI.state)
    }

    // MARK: State

    private func load() {
        let s = controller.settings
        autosavePopUp.selectItem(at: AppSettings.autosaveChoices.firstIndex(of: s.autosaveInterval) ?? 2)
        recoveryCheck.state = s.offerRecovery ? .on : .off
        updateCheck.state = s.checkForUpdates ? .on : .off
        qualityPopUp.selectItem(at: s.previewQualityAuto ? 0 : (MonitorQuality.allCases.firstIndex(of: s.defaultQuality) ?? 0) + 1)
        cacheSizePopUp.selectItem(withTag: s.frameCacheGB)
        if cacheSizePopUp.selectedItem == nil { cacheSizePopUp.selectItem(withTag: 0) }
        backgroundCheck.state = s.backgroundWork ? .on : .off
        renderCacheCheck.state = s.renderCache ? .on : .off
        renderCacheCapPopUp.selectItem(withTag: s.renderCacheCapGB)
        if renderCacheCapPopUp.selectedItem == nil { renderCacheCapPopUp.selectItem(withTag: 10) }
        prerollPopUp.selectItem(at: AppSettings.rollChoices.firstIndex(of: s.prerollSeconds) ?? 3)
        postrollPopUp.selectItem(at: AppSettings.rollChoices.firstIndex(of: s.postrollSeconds) ?? 2)
        textDurationPopUp.selectItem(withTag: s.defaultTextSeconds)
        if textDurationPopUp.selectedItem == nil { textDurationPopUp.selectItem(withTag: 5) }
        scrubbingCheck.state = s.audioScrubbing ? .on : .off
        dropDotCheck.state = s.dropIndicator ? .on : .off
        newSequenceModeSegmented.selectedSegment = s.newSequenceEditMode == .magnetic ? 1 : 0
        deClickCheck.state = AudioDeClick.isEnabled ? .on : .off
        meterStylePopUp.selectItem(at: MeterStyle.allCases.firstIndex(of: MeterStyle.current()) ?? 1)
        fadeCurvePopUp.selectItem(at: FadeCurve.allCases.firstIndex(of: DefaultFadeCurve.current()) ?? 0)
        loadLiveDucking()
        let roles = AudioRoleDefaults.load()
        for r in AudioTag.allCases {
            roleOffsetFields[r]?.value = roles.splitOffsetSeconds[r] ?? 0.25
            roleTransitionFields[r]?.value = roles.transitionSeconds[r] ?? 1
        }
        if let i = TransitionKind.kinds(for: .audio).firstIndex(of: roles.crossfadeKind) { crossfadePopUp.selectItem(at: i) }
        selectLanguage(s.captionLanguage)
        cachePath.stringValue = (s.effectiveCacheFolder.path as NSString).abbreviatingWithTildeInPath
        cacheCapPopUp.selectItem(withTag: s.cacheCapGB)
        if cacheCapPopUp.selectedItem == nil {
            cacheCapPopUp.addItem(withTitle: "\(s.cacheCapGB) GB"); cacheCapPopUp.lastItem?.tag = s.cacheCapGB
            cacheCapPopUp.selectItem(withTag: s.cacheCapGB)
        }
        cacheResetButton?.isEnabled = s.cacheFolder != nil
        selectAudioOutput(s.audioOutputUID)
        let t = TransitionDefaults.load()
        videoTransitionField.value = Double(t.videoFrames)
        audioTransitionField.value = t.audioSeconds
        let media = MediaSettings.defaults
        outsideMediaPopUp.selectItem(at: OutsideMediaMode.allCases.firstIndex(of: media.outside) ?? 0)
        libraryCopyCheck.state = media.copyLibraryItems ? .on : .off
        watchFolderCheck.state = media.watchFolder ? .on : .off
        cardImportCheck.state = CardImportSettings.enabled ? .on : .off
        growingFilesCheck.state = s.refreshGrowingFiles ? .on : .off
        proxiesExportCheck.state = s.useProxiesForExport ? .on : .off
        autoLanguageCheck.state = s.captionAutoLanguage ? .on : .off
        refreshUsed()
        apiCheck.state = EditAPIController.isEnabled ? .on : .off
        applyAPIState(controller.editAPI.state)
    }

    private func selectLanguage(_ id: String) {
        if !languagePopUp.itemArray.contains(where: { $0.representedObject as? String == id }) {
            languagePopUp.addItem(withTitle: Locale.current.localizedString(forIdentifier: id) ?? id)
            languagePopUp.lastItem?.representedObject = id
        }
        if let i = languagePopUp.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { languagePopUp.selectItem(at: i) }
    }

    private func transitionDefaultsChanged() {
        var t = TransitionDefaults.load()
        let frames = Int(videoTransitionField.value.rounded())
        if frames >= 0, frames <= 10_000 { t.videoFrames = frames }
        let seconds = (audioTransitionField.value * 100).rounded() / 100
        if seconds.isFinite, seconds > 0, seconds <= 600 { t.audioSeconds = seconds }
        t.save()
        videoTransitionField.value = Double(t.videoFrames)
        audioTransitionField.value = t.audioSeconds
    }

    @objc private func changed() {
        var s = controller.settings
        s.autosaveInterval = AppSettings.autosaveChoices[max(autosavePopUp.indexOfSelectedItem, 0)]
        controller.session.setAutosaveInterval(s.autosaveInterval)
        s.offerRecovery = recoveryCheck.state == .on
        s.checkForUpdates = updateCheck.state == .on
        let rawQuality = qualityPopUp.selectedItem?.representedObject as? String
        s.previewQualityAuto = rawQuality == Self.autoTag
        if let raw = rawQuality, let q = MonitorQuality(rawValue: raw) { s.defaultQuality = q }
        s.frameCacheGB = max(0, cacheSizePopUp.selectedItem?.tag ?? 0)
        s.backgroundWork = backgroundCheck.state == .on
        s.renderCache = renderCacheCheck.state == .on
        if let gb = renderCacheCapPopUp.selectedItem?.tag, gb > 0 { s.renderCacheCapGB = gb }
        s.prerollSeconds = AppSettings.rollChoices[max(prerollPopUp.indexOfSelectedItem, 0)]
        s.postrollSeconds = AppSettings.rollChoices[max(postrollPopUp.indexOfSelectedItem, 0)]
        if let t = textDurationPopUp.selectedItem?.tag, t > 0 { s.defaultTextSeconds = t }
        if let id = languagePopUp.selectedItem?.representedObject as? String { s.captionLanguage = id }
        s.audioScrubbing = scrubbingCheck.state == .on
        s.dropIndicator = dropDotCheck.state == .on
        s.refreshGrowingFiles = growingFilesCheck.state == .on
        s.useProxiesForExport = proxiesExportCheck.state == .on
        s.captionAutoLanguage = autoLanguageCheck.state == .on
        s.newSequenceEditMode = newSequenceModeSegmented.selectedSegment == 1 ? .magnetic : .normal
        controller.settings = s
        controller.session.newSequenceEditMode = s.newSequenceEditMode
        s.save()
        controller.session.engine.audioScrubbing = s.audioScrubbing
        controller.applyPlaybackMemorySettings()
    }

    private static let autoTag = "auto"

    @objc private func mediaPolicyChanged() {
        let raw = outsideMediaPopUp.selectedItem?.representedObject as? String ?? ""
        MediaSettings.defaults = MediaPolicyDefaults(outside: OutsideMediaMode(rawValue: raw) ?? .ask,
                                                     copyLibraryItems: libraryCopyCheck.state == .on,
                                                     watchFolder: watchFolderCheck.state == .on)
        controller.mediaPlacement.restartWatching()
    }

    @objc private func cardImportChanged(_ sender: SQCheckbox) { CardImportSettings.enabled = sender.state == .on }

    @objc private func clearCache() {
        // Proxies go through the live cache (its index stays right); everything else in the folder is plain files.
        controller.session.autoProxy?.clearCache()
        let url = controller.settings.effectiveCacheFolder
        let proxies = controller.settings.proxyCacheDirectory.standardizedFileURL
        if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for f in items where f.standardizedFileURL != proxies { try? FileManager.default.removeItem(at: f) }
        }
        refreshUsed()
    }

    @objc private func cacheCapChanged() {
        guard let gb = cacheCapPopUp.selectedItem?.tag, gb > 0 else { return }
        controller.settings.cacheCapGB = gb
        controller.settings.save()
        controller.applyCacheCap()
        refreshUsed()
    }

    @objc private func chooseCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCacheFolder(url)
    }

    @objc private func resetCacheFolder() { setCacheFolder(nil) }

    private func setCacheFolder(_ url: URL?) {
        let before = controller.settings.cacheFolder
        cacheNote.stringValue = StorageFolderChoice.setCacheFolder(url, settings: &controller.settings)
        guard controller.settings.cacheFolder != before || url == nil else { return }
        refreshStorageRows()
        cachePath.stringValue = (controller.settings.effectiveCacheFolder.path as NSString).abbreviatingWithTildeInPath
        cacheResetButton?.isEnabled = controller.settings.cacheFolder != nil
        refreshUsed()
    }

    // MARK: Audio output

    private func fillAudioOutputPopUp() {
        audioOutputPopUp.removeAllItems()
        audioOutputPopUp.addItem(withTitle: "System Default"); audioOutputPopUp.lastItem?.representedObject = ""
        for d in AudioOutputDevices.available() {
            audioOutputPopUp.addItem(withTitle: d.name); audioOutputPopUp.lastItem?.representedObject = d.uid
        }
    }

    private func selectAudioOutput(_ uid: String?) {
        fillAudioOutputPopUp()
        guard let uid, !uid.isEmpty else { audioOutputPopUp.selectItem(at: 0); return }
        if let i = audioOutputPopUp.itemArray.firstIndex(where: { $0.representedObject as? String == uid }) {
            audioOutputPopUp.selectItem(at: i)
        } else {
            audioOutputPopUp.addItem(withTitle: "Not connected (playing on System Default)")
            audioOutputPopUp.lastItem?.representedObject = uid
            audioOutputPopUp.selectItem(at: audioOutputPopUp.numberOfItems - 1)
        }
    }

    @objc private func audioOutputChanged() {
        let uid = audioOutputPopUp.selectedItem?.representedObject as? String ?? ""
        controller.settings.audioOutputUID = uid.isEmpty ? nil : uid
        controller.settings.save()
        controller.applyAudioOutputDevice()
    }

    /// Render harness only: fixed text for the cache size (the harness home has no cache).
    nonisolated(unsafe) static var renderUsedOverride: String?

    private func refreshUsed() {
        if let fixed = Self.renderUsedOverride { usedLabel.stringValue = fixed; return }
        usedLabel.stringValue = "Calculating…"
        let url = controller.settings.effectiveCacheFolder
        let proxies = controller.settings.proxyCacheDirectory
        Task.detached(priority: .utility) {
            var bytes = Self.folderSize(url)
            if !proxies.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") { bytes += Self.folderSize(proxies) }
            let text = bytes == 0 ? "Empty" : SQByteSize.string(bytes)
            await MainActor.run { [weak self] in self?.usedLabel.stringValue = text }
        }
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Top-left origin document view of the page scroller.
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One sidebar entry: icon and title, selected fill, click selects the page.
private final class SettingsSidebarRow: NSView {
    private let onClick: () -> Void
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var isSelected = false { didSet { update() } }

    init(page: SettingsPage, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        icon.image = Theme.symbol(page.icon, size: 14)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = page.localizedTitle
        label.font = Theme.Typography.body
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Row.list + Theme.Spacing.xs),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.md),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.sm),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(page.localizedTitle)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        layer?.backgroundColor = isSelected ? Theme.Colors.fill.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? Theme.Colors.label : Theme.Colors.label2
        icon.contentTintColor = isSelected ? Theme.Colors.label : Theme.Colors.label3
        setAccessibilityValue(isSelected ? "selected" : nil)
    }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}
