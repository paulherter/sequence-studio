import AppKit
import Observation
import SQCore
import SQLibrary

// MARK: - Saved easing presets (PresetStore `.easing`)

/// The user's saved easing curves, kept in the shared preset store (kind `.easing`). Payload: `EasingCurve.presetPayload()`.
@MainActor @Observable
public final class EasingPresetLibrary {
    public private(set) var saved: [EasingCurve] = []
    @ObservationIgnored private let store: PresetStore?
    @ObservationIgnored private var loaded = false

    public init(store: PresetStore?) { self.store = store }

    /// Same store instance as the Library panel (`LibraryServices.presetStore`), so neither overwrites the other's saves.
    public static let shared = EasingPresetLibrary(store: LibraryStores.presetStore)

    public func reload() async {
        guard let store else { return }
        saved = await EasingPresets.load(store)
        loaded = true
    }

    func loadIfNeeded() { if !loaded { loaded = true; Task { await reload() } } }

    /// Adds a preset (name trimmed; empty becomes "Custom Curve").
    public func save(_ shape: EaseShape, name: String) async throws {
        let curve = try await EasingPresets.save(shape, name: name, in: store)
        if store != nil { await reload() } else { saved.append(curve) }
    }
}

extension EasingCurveChips {
    @MainActor static func curves(library: EasingPresetLibrary, session: [EasingCurve], hold: Bool = true) -> [EasingCurve] {
        curves(saved: library.saved, session: session, hold: hold)
    }
}

/// Opens the curve popover for any source: keyframe segments, a transition, a speed transition of the Time Remapping
/// band, a motion effect's Custom curve, a keystone. One editor for all of them: the speed curve (`EaseSpeedEditorView`).
@MainActor
public enum EasingCurvePopover {
    public static func make(source: any EaseCurveSource, library: EasingPresetLibrary = .shared) -> SQPopover {
        let p = SQPopover(controller: EasingCurvePopoverController(source: source, library: library))
        p.mode = .transient
        return p
    }
}

// MARK: - Popover content

/// ~260x200 pt: the curve, preset chips under it, and a name field with Save.
final class EasingCurvePopoverController: NSViewController {
    static let size = NSSize(width: 260, height: 200)

    let model: any EaseCurveSource
    let library: EasingPresetLibrary
    let editor = EaseSpeedEditorView()
    private let chipScroll = NSScrollView()
    private let chipStack = NSStackView()
    private let nameField = NSTextField()
    private let saveButton = SQButton(title: "Save", target: nil, action: nil)
    private var chipItems: [EasingChipItem] = []
    private var isOpen = false
    /// One observation chain at a time: reopening the popover must not start a second one.
    private var observing = false

    init(source: any EaseCurveSource, library: EasingPresetLibrary) {
        self.model = source; self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    convenience init(model: EffectControlsModel, library: EasingPresetLibrary) { self.init(source: model, library: library) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = EasingPopoverRootView(frame: NSRect(origin: .zero, size: Self.size))
        let w = Self.size.width, pad: CGFloat = 8
        editor.frame = NSRect(x: 0, y: 0, width: w, height: 126)
        editor.onBegin = { [weak self] in self?.model.beginGesture() }
        editor.onChange = { [weak self] s in self?.model.applyEaseShape(s) }
        editor.onEnd = { [weak self] in self?.model.endGesture() }
        root.addSubview(editor)

        chipStack.orientation = .horizontal
        chipStack.spacing = 4
        chipStack.edgeInsets = NSEdgeInsets(top: 0, left: pad, bottom: 0, right: pad)
        chipScroll.documentView = chipStack
        chipScroll.hasHorizontalScroller = false
        chipScroll.drawsBackground = false
        chipScroll.frame = NSRect(x: 0, y: 132, width: w, height: 26)
        root.addSubview(chipScroll)

        nameField.placeholderString = "Preset name"
        nameField.font = Theme.Typography.body
        nameField.controlSize = .small
        nameField.frame = NSRect(x: pad, y: 167, width: w - 2 * pad - 64, height: Theme.Row.controlLarge)
        root.addSubview(nameField)
        saveButton.target = self; saveButton.action = #selector(save(_:))
        saveButton.frame = NSRect(x: w - pad - 60, y: 167, width: 60, height: Theme.Row.controlLarge)
        saveButton.sqToolTip = Tooltip.text("Save Curve", shortcut: nil)
        root.addSubview(saveButton)
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isOpen = true
        library.loadIfNeeded()
        refresh()
        observe()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isOpen = false
    }

    /// Starts the chain unless one is pending. A chain that fires while closed ends there (the next open restarts it).
    func observe() {
        guard isOpen, !observing else { return }
        observing = true
        withObservationTracking {
            model.observeEaseInputs(); _ = library.saved
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observing = false
                guard isOpen else { return }
                refresh()
                observe()
            }
        }
    }

    var chipItemsForTests: [EasingChipItem] { chipItems }

    /// Number of live observation chains (0 or 1), for tests.
    var observationChains: Int { observing ? 1 : 0 }

    func refresh() {
        let reading = model.easeReading
        editor.reading = reading
        editor.emptyHint = model.emptyEaseHint
        editor.valueRange = model.handleValueRange
        var items = EasingCurveChips.curves(library: library, session: model.sessionEasingCurves, hold: model.allowsHold).map(EasingChipItem.curve)
        if model.canBakeSpring { items += EasingLibrary.springPresets.map(EasingChipItem.spring) }
        let common: EaseShape? = if case .common(let s) = reading { s } else { nil }
        if items != chipItems { rebuildChips(items) }
        for case let (b as SQButton, item) in zip(chipStack.arrangedSubviews, chipItems) {
            b.isEnabled = reading != .empty
            if case .curve(let c) = item { b.state = common.map { c.shape.isApproximatelyEqual(to: $0) } == true ? .on : .off }
            else { b.state = .off }
        }
        saveButton.isEnabled = common != nil
    }

    private func rebuildChips(_ items: [EasingChipItem]) {
        chipItems = items
        for v in chipStack.arrangedSubviews { chipStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let b = SQButton(title: "", target: self, action: #selector(applyChip(_:)))
            b.image = EasingThumbnail.image(for: item)
            b.imagePosition = .imageOnly
            b.setButtonType(.pushOnPushOff)
            b.contentTintColor = Theme.Colors.label
            b.sqToolTip = { if case .spring = item { return item.name + " (bakes keys)" } else { return item.name } }()
            b.setAccessibilityLabel(item.name)
            b.tag = i
            b.widthAnchor.constraint(equalToConstant: EasingThumbnail.size.width + 6).isActive = true
            chipStack.addArrangedSubview(b)
        }
        chipStack.layoutSubtreeIfNeeded()
        let fit = chipStack.fittingSize
        chipStack.frame = NSRect(x: 0, y: 0, width: max(fit.width, Self.size.width), height: 26)
    }

    @objc private func applyChip(_ sender: SQButton) {
        guard chipItems.indices.contains(sender.tag) else { return }
        apply(chipItems[sender.tag])
    }

    func apply(_ item: EasingChipItem) {
        switch item {
        case .curve(let c): model.applyEaseShape(c.shape)
        case .spring(let s): model.applySpring(s.spring)
        }
        refresh()
    }

    @objc private func save(_ sender: Any?) {
        guard case .common(let shape) = model.easeReading else { return }
        let name = nameField.stringValue
        nameField.stringValue = ""
        let lib = library
        Task { @MainActor in try? await lib.save(shape, name: name) }
    }
}

private final class EasingPopoverRootView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Ruler button

/// Curve icon at the top of Effect Controls, next to the keyframe ruler: opens the easing popover for the selected keys.
public final class EasingCurveButton: NSButton {
    public let model: EffectControlsModel
    public var library: EasingPresetLibrary = .shared
    private var popover: SQPopover?

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: Theme.Row.control))
        let img = Theme.symbol(.curve, size: 13, label: "Keyframe Easing")
        if let img { image = img; imagePosition = .imageOnly } else { title = "Ease" }
        isBordered = false
        contentTintColor = Theme.Colors.label2
        sqToolTip = "Keyframe Easing"
        setAccessibilityLabel("Keyframe Easing")
        target = self; action = #selector(toggle(_:))
        update()
        observe()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func observe() {
        withObservationTracking {
            _ = model.clip; _ = model.selection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
    }

    /// Enabled only with something to ease. An open popover stays open and shows its empty state instead.
    private func update() { isEnabled = !model.easeSelection.isEmpty }

    @objc private func toggle(_ sender: Any?) {
        if let p = popover, p.isShown { p.close(); return }
        let p = popover ?? makePopover()
        popover = p
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func makePopover() -> SQPopover { EasingCurvePopover.make(source: model, library: library) }
}
