import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQText
import SQUIKit
import SQDrawKit

/// The Graphics panel on the shared toolkit (the Mac `GraphicsPanelView`): header (clip name, layer count, Save as
/// Template…), the layer list with its footer and a drag handle under it (height kept under `sq.graphics.listHeight`),
/// then the property rows of the selection, scrolled: Intro and Outro + Template Fields with no layer selected; Arrange,
/// Transform, Follow, Shape + Appearance (or the shared text block for a text layer) and the layer's effects otherwise.
/// Every value goes through `GraphicsEditor`, one undo step per gesture. The rows rebuild when
/// `GraphicsPanelLogic.structure` changes and read their values on every draw.
/// Coordinates: points, y down, (0, 0) = the panel's top-left.
@MainActor public final class GraphicsPanelDraw {
    public let editor: GraphicsEditor
    public var theme = DrawTheme() {
        didSet { list.theme = theme; form.theme = theme; tail.theme = theme; textBlock?.theme = theme }
    }
    public var size = CGSize(width: 320, height: 480)
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime } {
        didSet { list.clock = clock; form.clock = clock; tail.clock = clock; textBlock?.clock = clock }
    }
    /// SQ menus (popups, context menus) at `anchor` in panel coordinates.
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// The SQ color picker at `anchor`; `change(nil)` ends the session.
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// "Make Graphic" in the empty state (a text or shape clip selected).
    public var onMakeGraphic: (() -> Void)?
    /// "New Graphics Clip" in the empty state; nil runs `editor.newGraphicsClip()`.
    public var onNewGraphic: (() -> Void)?
    /// "Save as Template…" in the header; nil dims it.
    public var onSaveTemplate: (() -> Void)?
    /// "Save Effects as Preset…" in the Effects section.
    public var onSaveEffectPreset: ((EffectPreset) -> Void)?
    /// The Library's effect presets a layer can take.
    public var effectPresets: (() -> [(name: String, preset: EffectPreset)])?
    /// The window's Library keystones for the text item's Intro / Outro popups.
    public weak var keystones: (any AnimationKeystoneSource)? { didSet { textModel?.keystones = keystones } }
    /// Asks for a name (Save Look as New, Rename Look) in the text block.
    public var askName: (@MainActor (_ title: String, _ initial: String, _ done: @escaping @MainActor (String?) -> Void) -> Void)?

    let list: GraphicsLayerListDraw
    let form = GraphicsFormDraw()
    /// The Effects sections under the text block (a text layer's rows are form, text block, tail).
    let tail = GraphicsFormDraw()
    private(set) var textBlock: TextBlockDraw?
    private var textModel: TextInspectorModel?
    private var textGestureOpen = false
    private(set) var structureKey: String?
    private(set) var formScroll: CGFloat = 0
    /// One-line message at the bottom (a refused effect drop) and when it goes away.
    private(set) var status: (text: String, until: Double)?
    /// The list took the last click (selected rows draw the focused tint).
    private(set) var listFocused = false

    public static let headerHeight: CGFloat = 32
    static let listHeightKey = "sq.graphics.listHeight"
    static let minListHeight = GraphicsLayerListDraw.rowHeight * 3 + GraphicsLayerListDraw.footerHeight
    static let defaultListHeight = GraphicsLayerListDraw.rowHeight * 6 + GraphicsLayerListDraw.footerHeight
    static let handleGrab: CGFloat = 6

    public init(editor: GraphicsEditor) {
        self.editor = editor
        list = GraphicsLayerListDraw(editor: editor)
        list.onSelectionChange = { [weak self] in self?.sync() }
        list.onMenu = { [weak self] items, anchor in
            guard let self else { return }
            onMenu?(items, anchor.offsetBy(dx: 0, dy: Self.headerHeight))
        }
        for f in [form, tail] {
            f.onBeginGesture = { [weak editor] in editor?.beginGesture() }
            f.onMenu = { [weak self, weak f] items, anchor in
                guard let self, let f else { return }
                onMenu?(items, anchor.offsetBy(dx: 0, dy: formOrigin(f)))
            }
            f.onPickColor = { [weak self, weak f] color, anchor, change in
                guard let self, let f else { return }
                onPickColor?(color, anchor.offsetBy(dx: 0, dy: formOrigin(f)), change)
            }
        }
        sync()
    }

    // MARK: Session

    /// Call on every session change (project, selection, playhead): drops gone layers from the selection, reloads the
    /// list and rebuilds the rows when their structure changed. Drawing calls it too.
    public func sync() {
        editor.sync()
        list.reload()
        let key = GraphicsPanelLogic.structure(editor)
        if key != structureKey { structureKey = key; rebuild() }
        loadText()
    }

    public func selectAll() { editor.selectAllLayers(); sync() }

    // MARK: Layout

    var hasClip: Bool { editor.clip?.graphics != nil }

    var listHeight: CGFloat {
        let stored = CGFloat(UserDefaults.standard.double(forKey: Self.listHeightKey))
        return clampedListHeight(stored > 0 ? stored : Self.defaultListHeight)
    }

    private func clampedListHeight(_ h: CGFloat) -> CGFloat {
        let maxH = max(size.height - Self.headerHeight - ControlsGrid.rowHeight * 4, Self.minListHeight)
        return min(max(h, Self.minListHeight), maxH)
    }

    var listFrame: CGRect { CGRect(x: 0, y: Self.headerHeight, width: size.width, height: listHeight) }
    var handleFrame: CGRect { CGRect(x: 0, y: listFrame.maxY - Self.handleGrab / 2, width: size.width, height: Self.handleGrab) }
    var bodyFrame: CGRect {
        guard hasClip else { return CGRect(origin: .zero, size: size) }
        let y = listFrame.maxY + 1
        return CGRect(x: 0, y: y, width: size.width, height: max(size.height - y, 0))
    }

    private static let bodyInset = CGFloat(DrawTheme.Spacing.sm)
    private var textParts: [TextBlockDraw.Part] { textBlock == nil ? [] : [.text, .arrange, .animation] }

    /// Top of each body block in panel coordinates (form, text parts, tail).
    func blocks() -> (form: CGFloat, text: [(TextBlockDraw.Part, CGFloat)], tail: CGFloat, end: CGFloat) {
        var y = bodyFrame.minY + Self.bodyInset - formScroll
        let f = y
        y += form.height
        var parts: [(TextBlockDraw.Part, CGFloat)] = []
        for p in textParts { parts.append((p, y)); y += textBlock?.height(p) ?? 0 }
        let t = y
        y += tail.height
        return (f, parts, t, y + CGFloat(DrawTheme.Spacing.md))
    }

    private func formOrigin(_ f: GraphicsFormDraw) -> CGFloat { f === form ? blocks().form : blocks().tail }

    var contentHeight: CGFloat { blocks().end + formScroll - bodyFrame.minY }
    var maxFormScroll: CGFloat { max(contentHeight - bodyFrame.height, 0) }

    // MARK: Build

    /// Align to: the frame (each layer on its own) or the selection (2+ layers). Kept for the session.
    var alignToFrame = false
    var scaleLinked: Bool {
        get { UserDefaults.standard.object(forKey: "sq.graphics.scaleLinked") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sq.graphics.scaleLinked") }
    }

    func rebuild() {
        form.reset(); tail.reset()
        for f in [form, tail] { f.width = size.width }
        textBlock?.resignFocus()
        textBlock = nil; textModel = nil
        formScroll = 0
        guard let clip = editor.clip, clip.graphics != nil else { return }
        let n = editor.selectedLayers.count
        guard n > 0 else { buildIntroOutro(clip); return }
        buildArrange(count: n)
        buildTransform()
        if n == 1 { buildFollow() }
        let layers = editor.targetLayers
        // Kind sections only when every selected layer has that kind; a text layer's look lives in its text block.
        if layers.allSatisfy({ !$0.isText }) {
            buildShape(layers)
            buildAppearance(layers)
        } else if let layer = editor.selectedLayer, layer.isText {
            buildText()
        }
        if let layer = editor.selectedLayer { buildEffects(layer) }
    }

    private func buildIntroOutro(_ clip: Clip) {
        let f = form, s = editor.session, id = clip.id, e = editor
        f.begin("Intro and Outro", key: "introOutro")
        f.add(.check(title: "Keep intro and outro when trimmed", state: { [weak e] in e?.clip?.zones == nil ? .off : .on },
                     toggle: { [weak self, weak e] in
                         _ = s.setZonesEnabled(e?.clip?.zones == nil, clip: id)
                         self?.sync()
                     }))
        if clip.zones != nil {
            f.add(.segments(title: "Middle", labels: ["Hold", "Stretch"],
                            selected: { [weak e] in e?.clip?.zones?.middle == .stretch ? 1 : 0 }, enabled: { _ in true },
                            choose: { [weak e] i in e?.beginGesture(); s.setZoneMiddle(i == 1 ? .stretch : .hold, clip: id) }))
            func secs(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
            f.numbers("In", unit: "s", decimals: 2, fields: [
                (get: { [weak e] in e?.clip?.zones.map { secs($0.introEnd) } }, set: { [weak e] in e?.setZoneLengths(intro: $0, outro: nil) })])
            f.numbers("Out", unit: "s", decimals: 2, fields: [
                (get: { [weak e] in e?.clip?.zones.map { secs($0.outroLength) } }, set: { [weak e] in e?.setZoneLengths(intro: nil, outro: $0) })])
        }
        // G10: the fields "Save as Template…" makes from this graphic (read-only here).
        let fields = TemplateFieldsLogic.fields(of: clip)
        guard !fields.isEmpty else { return }
        f.begin("Template Fields", key: "templateFields")
        for t in fields { f.add(.label(title: t.title, value: t.value)) }
    }

    private func buildArrange(count n: Int) {
        let f = form, e = editor
        f.begin("Arrange", key: "arrange")
        let toFrame = n < 2 || alignToFrame
        let aligns: [(SQIcon, String, GraphicsAlign)] = [
            (.alignLeft, "Align Left", .left), (.alignCenterH, "Align Centers Horizontally", .centerX),
            (.alignRight, "Align Right", .right), (.alignTop, "Align Top", .top),
            (.alignCenterV, "Align Centers Vertically", .centerY), (.alignBottom, "Align Bottom", .bottom),
        ]
        var items = aligns.map { s, t, a in
            GraphicsFormDraw.IconItem(icon: s, title: t) { [weak e] in e?.align(a, toFrame: toFrame) }
        }
        let three = n >= 3
        items.append(.init(icon: .distributeH, title: "Distribute Horizontally", enabled: { three }) { [weak e] in e?.distribute(.horizontal) })
        items.append(.init(icon: .distributeV, title: "Distribute Vertically", enabled: { three }) { [weak e] in e?.distribute(.vertical) })
        f.add(.icons(title: nil, items))
        f.add(.segments(title: "Align To", labels: ["Frame", "Selection"], selected: { toFrame ? 0 : 1 }, enabled: { $0 == 0 || n >= 2 },
                        choose: { [weak self] i in self?.alignToFrame = i == 0; self?.structureKey = nil; self?.sync() }))
    }

    private func buildTransform() {
        let f = form, e = editor
        f.begin("Transform", key: "transform")
        func get(_ p: GraphicsEditor.Property, _ axis: Int = 0, _ k: Double = 1) -> () -> Double? {
            { [weak e] in e?.value(p, axis: axis).map { $0 * k + 0 } }      // + 0: no "-0"
        }
        func set(_ p: GraphicsEditor.Property, _ axis: Int = 0, _ k: Double = 1) -> (Double) -> Void {
            { [weak e] v in e?.setValue(p, axis: axis, v / k) }
        }
        func keyed(_ p: GraphicsEditor.Property) -> () -> Bool { { [weak e] in e?.isKeyed(p) ?? false } }
        f.numbers("Position", unit: "px", keyed: keyed(.position),
                  fields: [(get(.position, 0), set(.position, 0)), (get(.position, 1, -1), set(.position, 1, -1))])   // Y up, 0,0 = centered
        f.numbers("Anchor", unit: "px", keyed: keyed(.anchor), reset: [0, 0],
                  fields: [(get(.anchor, 0), set(.anchor, 0)), (get(.anchor, 1, -1), set(.anchor, 1, -1))])
        let scaleSet: (Int) -> (Double) -> Void = { axis in { [weak self, weak e] v in
            guard let self, let e else { return }
            if scaleLinked { e.setScaleLinked(axis: axis, v / 100) } else { e.setValue(.scale, axis: axis, v / 100) }
        } }
        let link = GraphicsFormDraw.IconItem(icon: .link, title: "Link Scale", selected: { [weak self] in self?.scaleLinked ?? true }, offIcon: .unlink) {
            [weak self] in self?.scaleLinked.toggle()
        }
        f.numbers("Scale", unit: "%", keyed: keyed(.scale), reset: [100, 100],
                  fields: [(get(.scale, 0, 100), scaleSet(0)), (get(.scale, 1, 100), scaleSet(1))], link: link)
        f.numbers("Rotation", unit: "°", keyed: keyed(.rotation), reset: [0], fields: [(get(.rotation, 0, -1), set(.rotation, 0, -1))])   // counterclockwise positive
        f.numbers("Opacity", unit: "%", keyed: keyed(.opacity), reset: [100], fields: [(get(.opacity, 0, 100), set(.opacity, 0, 100))])
        let modes = BlendMode.allCases
        f.add(.popup(title: "Blend", titles: modes.map(\.title), selected: { [weak e] in e?.blendMode.flatMap { modes.firstIndex(of: $0) } },
                     enabled: { true }, choose: { [weak e] i in e?.setBlendMode(modes[i]) }))
    }

    private func buildFollow() {
        let f = form, e = editor
        f.begin("Follow", key: "follow")
        let current = e.follow
        let targets: [GraphicsFollow.Target?] = [nil, .frame] + e.followCandidates.map { .layer(id: $0.id) }
        let locked = e.selectedLayer?.isLocked ?? true
        f.add(.popup(title: "Follows", titles: targets.map { e.followTitle($0) },
                     selected: { [weak e] in targets.firstIndex { $0 == e?.follow?.target } ?? 0 }, enabled: { !locked },
                     choose: { [weak e] i in e?.setFollowTarget(targets[i]) }))
        guard current != nil else { return }
        let edges: [(SQIcon, String, GraphicsEdges)] = [
            (.arrowLeftToLine, "Left Edge", .left), (.arrowUpFromLine, "Top Edge", .top),
            (.arrowRightToLine, "Right Edge", .right), (.arrowDownToLine, "Bottom Edge", .bottom),
        ]
        f.add(.icons(title: "Edges", edges.map { icon, title, edge in
            GraphicsFormDraw.IconItem(icon: icon, title: title, enabled: { !locked },
                                      selected: { [weak e] in e?.follow?.edges.contains(edge) ?? false }) { [weak e] in
                e?.beginGesture(); e?.toggleFollowEdge(edge)
            }
        }))
        let d = GraphicsEditor.defaultFollowPadding
        func pad(_ edge: GraphicsEdges, _ path: KeyPath<GraphicsEdgePadding, Double>) -> (get: () -> Double?, set: (Double) -> Void) {
            ({ [weak e] in e?.follow?.resolvedPadding[keyPath: path] }, { [weak e] v in e?.setFollowPadding(v, for: edge) })
        }
        f.numbers("Padding L / R", unit: "px", reset: [d, d], fields: [pad(.left, \.left), pad(.right, \.right)])
        f.numbers("Padding T / B", unit: "px", reset: [d, d], fields: [pad(.top, \.top), pad(.bottom, \.bottom)])
    }

    private func buildShape(_ layers: [GraphicsLayer]) {
        let f = form, e = editor
        f.begin("Shape", key: "shape")
        let isLine = layers.allSatisfy(GraphicsPanelLogic.isLineLike)
        let isRect = layers.allSatisfy { if case .shape(.rectangle) = $0.content { true } else { false } }
        if layers.allSatisfy({ if case .shape = $0.content { true } else { false } }) {
            let kinds = ShapeKind.allCases
            f.add(.popup(title: "Kind", titles: kinds.map(\.title), selected: { [weak e] in e?.shapeKind.flatMap { kinds.firstIndex(of: $0) } },
                         enabled: { true }, choose: { [weak self, weak e] i in e?.setShapeKind(kinds[i]); self?.sync() }))
        }
        func shapeRow(_ title: String, _ key: String) {
            let p = GraphicsEditor.Property.shape(key)
            let def = EffectCatalog.param(ClipEffect.shapeEffectKind, key)?.defaultValue
            f.numbers(title, unit: "px", keyed: { [weak e] in e?.isKeyed(p) ?? false }, decimals: 0, reset: def.map { [$0] },
                      fields: [({ [weak e] in e?.value(p) }, { [weak e] v in e?.setValue(p, max(v, 0)) })])
        }
        if isLine {
            shapeRow("Length", ClipEffect.shapeWidthKey)
        } else {
            shapeRow("Width", ClipEffect.shapeWidthKey)
            shapeRow("Height", ClipEffect.shapeHeightKey)
        }
        if isRect { shapeRow("Corners", ClipEffect.shapeCornerRadiusKey) }
    }

    /// Fill, Outline, Shadow (`GraphicAppearanceBinding`'s wiring): check, color, main value inline; details under the chevron.
    private func buildAppearance(_ layers: [GraphicsLayer]) {
        let f = form, e = editor
        f.begin("Appearance", key: "appearance")
        let kind = ClipEffect.shapeEffectKind, shadow = ClipEffect.dropShadowKind
        if !layers.allSatisfy(GraphicsPanelLogic.isLineLike) {
            let key = ClipEffect.shapeFillColorKey
            f.appearance("Fill", key: "fill", on: { [weak e] in e?.shapeValue(ClipEffect.shapeFillKey).map { $0 >= 0.5 } },
                         setOn: { [weak e] in e?.setShapeValue(ClipEffect.shapeFillKey, $0 ? 1 : 0) },
                         color: { [weak e] in e?.color(kind: kind, key: key) }, setColor: { [weak e] in e?.setColor(kind: kind, key: key, $0) },
                         value: { [weak e] in e?.colorAlpha(kind: kind, key: key).map { $0 * 100 } },
                         setValue: { [weak e] in e?.setColorAlpha(kind: kind, key: key, min(max($0, 0), 100) / 100) },
                         unit: "%", reset: 100, hasDetail: false)
        }
        let widthP = GraphicsEditor.Property.shape(ClipEffect.shapeStrokeWidthKey)
        let strokeKey = ClipEffect.shapeStrokeColorKey
        f.appearance("Outline", key: "outline", on: { [weak e] in e?.shapeValue(ClipEffect.shapeStrokeKey).map { $0 >= 0.5 } },
                     setOn: { [weak e] in e?.setShapeValue(ClipEffect.shapeStrokeKey, $0 ? 1 : 0) },
                     color: { [weak e] in e?.color(kind: kind, key: strokeKey) }, setColor: { [weak e] in e?.setColor(kind: kind, key: strokeKey, $0) },
                     value: { [weak e] in e?.value(widthP) }, setValue: { [weak e] in e?.setValue(widthP, max($0, 0)) },
                     unit: "px", reset: 8, hasDetail: true)
        f.numbers("Width", unit: "px", keyed: { [weak e] in e?.isKeyed(widthP) ?? false }, reset: [8],
                  fields: [({ [weak e] in e?.value(widthP) }, { [weak e] v in e?.setValue(widthP, max(v, 0)) })], detailOf: "outline")
        func fx(_ key: String) -> GraphicsEditor.Property { .effect(kind: shadow, key: key) }
        let hasShadow = layers.allSatisfy { l in l.effects.contains { $0.kind == shadow } }
        f.appearance("Shadow", key: "shadow", on: { [weak e] in e?.shadowState },
                     setOn: { [weak self, weak e] on in e?.setShadow(on); self?.sync() },
                     color: { [weak e] in e?.color(kind: shadow, key: ClipEffect.shadowColorKey) },
                     setColor: { [weak e] in e?.setColor(kind: shadow, key: ClipEffect.shadowColorKey, $0) },
                     value: { [weak e] in e?.value(fx(ClipEffect.shadowOpacityKey)) },
                     setValue: { [weak e] v in e?.setValue(fx(ClipEffect.shadowOpacityKey), min(max(v, 0), 100)) },
                     unit: "%", reset: 50, hasDetail: hasShadow)
        guard hasShadow else { return }
        for (title, key, unit) in [("Opacity", ClipEffect.shadowOpacityKey, "%"), ("Angle", ClipEffect.shadowDirectionKey, "°"),
                                   ("Distance", ClipEffect.shadowDistanceKey, "px"), ("Blur", ClipEffect.shadowSoftnessKey, "px")] {
            let p = fx(key)
            let spec = EffectCatalog.param(shadow, key)
            f.numbers(title, unit: unit, keyed: { [weak e] in e?.isKeyed(p) ?? false }, decimals: 0, reset: spec.map { [$0.defaultValue] },
                      fields: [({ [weak e] in e?.value(p) }, { [weak e] v in
                          e?.setValue(p, spec.map { min(max(v, $0.range.lowerBound), $0.range.upperBound) } ?? v) })],
                      detailOf: "shadow")
        }
    }

    /// The shared text block drives the layer's text template: the box edits `text`, every other control `style`.
    private func buildText() {
        let e = editor
        let model = TextInspectorModel()
        model.keystones = keystones
        let block = TextBlockDraw(model: model)
        block.theme = theme; block.width = size.width; block.clock = clock
        block.askName = askName
        block.onNotice = { [weak self] m in self?.showStatus(m) }
        block.onMenu = { [weak self] items, anchor, part in
            guard let self else { return }
            onMenu?(items, anchor.offsetBy(dx: 0, dy: textOrigin(part)))
        }
        block.onPickColor = { [weak self] color, anchor, part, change in
            guard let self else { return }
            onPickColor?(color, anchor.offsetBy(dx: 0, dy: textOrigin(part)), change)
        }
        model.onBeginEditing = { [weak self, weak e] in self?.textGestureOpen = true; e?.beginGesture() }
        model.onEndEditing = { [weak self] in self?.textGestureOpen = false }
        model.onChange = { [weak e] style, anims in
            if e?.textAnimations != anims { e?.updateText("Text Animation", animations: anims) { $0.style = style } }
            else { e?.updateText("Text Style") { $0.style = style } }
        }
        block.onTextBegin = { [weak e] in e?.beginGesture() }
        block.onTextChange = { [weak e] s in e?.updateText("Edit Text") { $0.text = s } }
        textModel = model
        textBlock = block
        loadText()
    }

    private func textOrigin(_ part: TextBlockDraw.Part) -> CGFloat { blocks().text.first { $0.0 == part }?.1 ?? 0 }

    /// Loads the template back into the text block unless a gesture is open.
    private func loadText() {
        guard let model = textModel, let block = textBlock, let t = editor.textTemplate else { return }
        model.target = editor.selectedLayer?.id
        let anims = editor.textAnimations ?? AnimationSet(in: nil, out: nil)
        model.frameSize = AnimationChoices.frameSize(editor.session.displayFormat)
        if !textGestureOpen, model.style != t.style || model.animations != anims { model.load(style: t.style, animations: anims) }
        if block.text != t.text { block.text = t.text }
    }

    /// One section per effect on the layer (enable eye, remove button), then Add Effect… and Presets….
    private func buildEffects(_ layer: GraphicsLayer) {
        let f = tail, e = editor
        let appearanceShadow = layer.isText ? nil : layer.effects.first { $0.kind == ClipEffect.dropShadowKind }?.id
        for fx in layer.effects where !EffectCatalog.isGeneratorOwned(fx.kind) && fx.id != appearanceShadow {
            guard let spec = EffectCatalog.spec(for: fx.kind) else { continue }
            let getFx = { [weak e] in e?.selectedLayer?.effects.first { $0.id == fx.id } }
            f.begin(spec.title, key: "fx.\(fx.kind)", enabled: { getFx()?.enabled ?? true },
                    setEnabled: { [weak self, weak e] on in e?.setEffectEnabled(fx.id, on); self?.sync() },
                    remove: { [weak self, weak e] in e?.removeEffect(fx.id); self?.sync() })
            for p in spec.params {
                let local = { [weak e] in e?.localTime ?? .zero }
                switch p.kind {
                case .slider:
                    let prop = EffectProperty.fx(fx.id, kind: fx.kind, key: p.key)      // the display boundary: scale and sign
                    let key = GraphicsEditor.Property.effect(kind: fx.kind, key: p.key, id: fx.id)
                    f.numbers(p.title, unit: p.unit, keyed: { [weak e] in e?.isKeyed(key) ?? false }, decimals: p.decimals,
                              reset: [prop.display(p.defaultValue)], fields: [
                        ({ prop.display(getFx()?.scalar(p.key, atLocal: local()) ?? p.defaultValue) },
                         { [weak e] v in e?.setEffectValue(fx.id, key: p.key, min(max(prop.native(fromDisplay: v), p.range.lowerBound), p.range.upperBound)) }),
                    ])
                case .checkbox:
                    f.add(.check(title: p.title, state: { (getFx()?.scalar(p.key, atLocal: local()) ?? 0) >= 0.5 ? .on : .off },
                                 toggle: { [weak e] in
                                     let on = (getFx()?.scalar(p.key, atLocal: local()) ?? 0) >= 0.5
                                     e?.setEffectValue(fx.id, key: p.key, on ? 0 : 1)
                                 }))
                case .choice(let titles):
                    f.add(.popup(title: p.title, titles: titles,
                                 selected: { Int((getFx()?.scalar(p.key, atLocal: local()) ?? 0).rounded()) }, enabled: { true },
                                 choose: { [weak e] i in e?.setEffectValue(fx.id, key: p.key, Double(i)) }))
                case .color(let def):
                    f.add(.color(title: p.title, get: { getFx()?.colors[p.key]?.value(atLocal: local()) ?? def },
                                 set: { [weak e] c in e?.setEffectColor(fx.id, key: p.key, c) }))
                case .point(let def):
                    let pk = GraphicsEditor.Property.effectPoint(kind: fx.kind, key: p.key, id: fx.id)
                    let sign = { (i: Int) in EffectProperty.fx(fx.id, kind: fx.kind, key: p.key).displaySign(component: i == 0 ? .x : .y) }
                    func axis(_ i: Int) -> (get: () -> Double?, set: (Double) -> Void) {
                        let k = sign(i)
                        return ({
                            guard let v = getFx()?.points[p.key]?.value(atLocal: local()) else { return (i == 0 ? def.x : def.y) * k + 0 }
                            return (i == 0 ? v.x : v.y) * k + 0
                        }, { [weak e] v in e?.setValue(pk, axis: i, v * k) })
                    }
                    f.numbers(p.title, unit: "px", keyed: { [weak e] in e?.isKeyed(pk) ?? false },
                              reset: [def.x * sign(0) + 0, def.y * sign(1) + 0], fields: [axis(0), axis(1)])
                }
            }
        }
        f.begin("Effects", key: "fxAdd")
        f.add(.buttons([
            .init(title: "Add Effect…") { [weak self] anchor in self?.presentAddEffectMenu(anchor) },
            .init(title: "Presets…") { [weak self] anchor in self?.presentEffectPresetMenu(anchor) },
        ]))
    }

    private func presentAddEffectMenu(_ anchor: CGRect) {
        let e = editor
        let items = GraphicsEditor.offeredEffects.map { spec in
            SQMenuItem(title: spec.title) { [weak self, weak e] in
                guard let e else { return }
                self?.showDrop(e.addEffect(spec.kind))
            }
        }
        guard !items.isEmpty else { return }
        onMenu?(items, anchor.offsetBy(dx: 0, dy: blocks().tail))
    }

    private func presentEffectPresetMenu(_ anchor: CGRect) {
        let e = editor
        var items = (effectPresets?() ?? []).map { entry in
            SQMenuItem(title: entry.name) { [weak self, weak e] in
                guard let e else { return }
                self?.showDrop(e.applyEffectPreset(entry.preset, name: entry.name))
            }
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(SQMenuItem(title: "Save Effects as Preset…", isEnabled: e.layerEffectPreset() != nil && onSaveEffectPreset != nil) {
            [weak self, weak e] in if let p = e?.layerEffectPreset() { self?.onSaveEffectPreset?(p) }
        })
        onMenu?(items, anchor.offsetBy(dx: 0, dy: blocks().tail))
    }

    /// An added effect needs no message (its section appears); a refusal shows for three seconds.
    func showDrop(_ r: GraphicsEditor.EffectDrop) {
        sync()
        if case .refused(let why) = r { showStatus(why) }
    }

    func showStatus(_ text: String) { status = (SQL10n.string(text), clock() + 3) }

    /// Effects dropped from the Effects panel on the body: they go to the selected layer when exactly one is selected.
    /// True when the panel took the drop (a Graphic is open and the drag carried effects), as the Mac `performDragOperation`.
    @discardableResult
    public func dropEffects(_ kinds: [String]) -> Bool { dropEffects(kinds, at: nil) }

    /// The same at a point of the panel: on a layer row the effects go to that layer (the Mac `LayerListView.effectDrop`),
    /// elsewhere to the one selected layer.
    @discardableResult
    public func dropEffects(_ kinds: [String], at p: CGPoint?) -> Bool {
        guard hasClip, !kinds.isEmpty else { return false }
        if let p, region(at: p) == .list, let r = list.dropEffects(kinds, at: local(p, .list)) { showDrop(r); return true }
        guard editor.selectedLayers.count == 1 else { showDrop(.refused("Select one layer to add an effect.")); return true }
        showDrop(editor.addEffects(kinds))
        return true
    }

    /// An Effects drag is over the panel at `p` (nil: it left): the layer row under it takes the accent tint.
    public func effectDragOver(at p: CGPoint?) {
        guard hasClip, let p, region(at: p) == .list else { list.effectDragOver(at: nil); return }
        list.effectDragOver(at: local(p, .list))
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        sync()
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        guard let clip = editor.clip, clip.graphics != nil else { drawEmpty(&c); return }
        // Header.
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: Self.headerHeight), t.titlebar)
        let save = saveTemplateFrame
        InspectorDraw.button(&c, title: SQL10n.string("Save as Template…"), in: save, hovering: hover == .saveTemplate,
                                pressed: pressed == .saveTemplate, enabled: onSaveTemplate != nil, t)
        let sm = CGFloat(DrawTheme.Spacing.sm)
        let summary = SQL10n.string(ClipSectionMode.layerSummary(clip))
        let sw = c.size(of: summary, fontSize: fs).width
        c.draw(clip.name, in: CGRect(x: sm, y: 0, width: max(save.minX - sm * 2 - sw - sm, 0), height: Self.headerHeight), fontSize: fs, t.label, face: c.semibold)
        c.draw(summary, in: CGRect(x: save.minX - sm - sw, y: 0, width: sw, height: Self.headerHeight), fontSize: fs, t.label3)
        c.fill(CGRect(x: 0, y: Self.headerHeight - 1, width: size.width, height: 1), t.separator)
        // List.
        list.size = listFrame.size
        c.saveGState()
        c.translateBy(x: 0, y: listFrame.minY)
        list.draw(&c, focused: listFocused)
        c.restoreGState()
        c.fill(CGRect(x: 0, y: listFrame.maxY, width: size.width, height: 1), hover == .handle || pressed == .handle ? t.accent : t.separator)
        // Body.
        let body = bodyFrame, b = blocks()
        c.saveGState()
        c.clip(to: body)
        for f in [form, tail] { f.width = size.width }
        c.saveGState(); c.translateBy(x: 0, y: b.form); form.draw(&c); c.restoreGState()
        if let block = textBlock {
            block.width = size.width
            for (p, y) in b.text { c.saveGState(); c.translateBy(x: 0, y: y); block.draw(&c, part: p); c.restoreGState() }
        }
        c.saveGState(); c.translateBy(x: 0, y: b.tail); tail.draw(&c); c.restoreGState()
        c.restoreGState()
        drawStatus(&c)
    }

    var saveTemplateFrame: CGRect {
        let w: CGFloat = 132, h = ControlsGrid.controlHeight
        return CGRect(x: size.width - CGFloat(DrawTheme.Spacing.sm) - w, y: ((Self.headerHeight - h) / 2).rounded(), width: w, height: h)
    }

    var emptyState: GraphicsEmptyState { GraphicsEmptyState.resolve(editor.session.singleSelectedClip) ?? .noGraphic }

    private var makeGraphicBlocker: String? {
        guard emptyState == .editedInControls, let c = editor.session.singleSelectedClip else { return nil }
        return editor.session.project.makeGraphicBlocker(clipID: c.id)
    }

    var emptyButtonFrame: CGRect {
        let w: CGFloat = 150, h = ControlsGrid.controlHeight
        return CGRect(x: ((size.width - w) / 2).rounded(), y: (size.height / 2 + 24).rounded(), width: w, height: h)
    }

    private func drawEmpty(_ c: inout Canvas) {
        let t = theme, state = emptyState, blocker = makeGraphicBlocker
        c.drawEmptyState(title: SQL10n.string(state.title), hint: blocker ?? SQL10n.string(state.hint),
                         in: CGRect(origin: .zero, size: size), reserve: 34, theme: t)
        let title = state == .editedInControls ? "Make Graphic" : "New Graphics Clip"
        InspectorDraw.button(&c, title: SQL10n.string(title), in: emptyButtonFrame, hovering: hover == .emptyAction,
                                pressed: pressed == .emptyAction, enabled: state != .editedInControls || blocker == nil,
                                accent: state != .editedInControls, t)
        drawStatus(&c)
    }

    private func drawStatus(_ c: inout Canvas) {
        guard let s = status, clock() < s.until else { return }
        let h = ControlsGrid.rowHeight, r = CGRect(x: 0, y: max(size.height - h, 0), width: size.width, height: h)
        c.fill(r, theme.panel)
        c.draw(s.text, in: r, fontSize: CGFloat(DrawTheme.TypeSize.body), theme.label2, align: .center)
    }

    // MARK: Pointer

    enum Region: Equatable { case saveTemplate, emptyAction, list, handle, form, text(TextBlockDraw.Part), tail }
    private(set) var hover: Region?
    private(set) var pressed: Region?
    private var handleStart: (y: CGFloat, height: CGFloat)?
    private var counter = ClickCounter()

    func region(at p: CGPoint) -> Region? {
        guard hasClip else { return emptyButtonFrame.contains(p) ? .emptyAction : nil }
        if saveTemplateFrame.contains(p) { return .saveTemplate }
        if p.y < Self.headerHeight { return nil }
        if handleFrame.contains(p) { return .handle }
        if listFrame.contains(p) { return .list }
        guard bodyFrame.contains(p) else { return nil }
        let b = blocks()
        if p.y < b.form + form.height { return .form }
        for (part, y) in b.text where p.y >= y && p.y < y + (textBlock?.height(part) ?? 0) { return .text(part) }
        if p.y >= b.tail && p.y < b.tail + tail.height { return .tail }
        return nil
    }

    private func local(_ p: CGPoint, _ r: Region) -> CGPoint {
        switch r {
        case .list: CGPoint(x: p.x, y: p.y - listFrame.minY)
        case .form: CGPoint(x: p.x, y: p.y - blocks().form)
        case .tail: CGPoint(x: p.x, y: p.y - blocks().tail)
        case .text(let part): CGPoint(x: p.x, y: p.y - textOrigin(part))
        default: p
        }
    }

    public func mouseMoved(to p: CGPoint?) {
        guard pressed == nil else { return }
        hover = p.flatMap(region)
        list.mouseMoved(to: hover == .list ? p.map { local($0, .list) } : nil)
        form.mouseMoved(to: hover == .form ? p.map { local($0, .form) } : nil)
        tail.mouseMoved(to: hover == .tail ? p.map { local($0, .tail) } : nil)
        for part in textParts { textBlock?.mouseMoved(to: hover == .text(part) ? p.map { local($0, .text(part)) } : nil, part: part) }
    }

    public func mouseDown(at p: CGPoint, modifiers: InputModifiers = [], clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let r = region(at: p)
        pressed = r
        listFocused = r == .list
        if r != .form { form.resignFocus() }
        if r != .tail { tail.resignFocus() }
        if case .text = r {} else { textBlock?.resignFocus() }
        if r != .list { list.commitRename() }
        guard let r else { return }
        switch r {
        case .list: list.mouseDown(at: local(p, r), modifiers: modifiers, clickCount: n)
        case .handle: handleStart = (p.y, listHeight)
        case .form: form.mouseDown(at: local(p, r), clickCount: n)
        case .tail: tail.mouseDown(at: local(p, r), clickCount: n)
        case .text(let part):
            if modifiers.contains(.secondary) { pressed = nil; _ = textBlock?.contextMenu(at: local(p, r), part: part); return }
            textBlock?.mouseDown(at: local(p, r), part: part, clickCount: n)
        default: break
        }
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        guard let r = pressed else { return }
        switch r {
        case .list: list.mouseDragged(to: local(p, r), modifiers: modifiers)
        case .handle:
            guard let s = handleStart else { return }
            UserDefaults.standard.set(Double(clampedListHeight(s.height + p.y - s.y)), forKey: Self.listHeightKey)
        case .form: form.mouseDragged(to: local(p, r), modifiers: modifiers)
        case .tail: tail.mouseDragged(to: local(p, r), modifiers: modifiers)
        case .text(let part): textBlock?.mouseDragged(to: local(p, r), part: part, modifiers: modifiers)
        default: break
        }
    }

    public func mouseUp(at p: CGPoint, modifiers: InputModifiers = []) {
        let r = pressed
        pressed = nil
        handleStart = nil
        defer { mouseMoved(to: p) }
        guard let r else { return }
        switch r {
        case .list: list.mouseUp(at: local(p, r), modifiers: modifiers)
        case .form: form.mouseUp(at: local(p, r))
        case .tail: tail.mouseUp(at: local(p, r))
        case .text(let part): textBlock?.mouseUp(at: local(p, r), part: part)
        case .saveTemplate: if region(at: p) == r { onSaveTemplate?() }
        case .emptyAction:
            guard region(at: p) == r else { return }
            if emptyState == .editedInControls {
                if makeGraphicBlocker == nil { onMakeGraphic?() }
            } else if let make = onNewGraphic { make() } else { _ = editor.newGraphicsClip() }
            sync()
        case .handle: break
        }
    }

    /// Wheel: scrolls the list or the property rows (a hovered number field takes it first).
    public func scroll(at p: CGPoint, dy: CGFloat, precise: Bool = true, modifiers: InputModifiers = []) {
        guard let r = region(at: p) else { return }
        switch r {
        case .list: list.scroll(dy: dy)
        case .form where form.scroll(at: local(p, r), dy: dy, precise: precise, modifiers: modifiers): return
        case .tail where tail.scroll(at: local(p, r), dy: dy, precise: precise, modifiers: modifiers): return
        case .form, .tail, .text: formScroll = min(max(formScroll - dy, 0), maxFormScroll)
        default: break
        }
    }

    /// Keys: an open rename, text or field edit first; then Delete removes the selected layers, Return renames the
    /// selected layer (a text layer: its text in the text box), Command-A selects every layer.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if list.key(k, modifiers: modifiers) { return true }
        if textBlock?.key(k, modifiers: modifiers) == true { return true }
        if form.key(k, modifiers: modifiers) || tail.key(k, modifiers: modifiers) { return true }
        guard hasClip else { return false }
        let plain = modifiers.intersection([.command, .option]).isEmpty
        switch k {
        case .delete, .backspace:
            guard plain, !editor.selectedLayers.isEmpty else { return false }
            editor.deleteSelected(); sync(); return true
        case .enter where plain && !modifiers.contains(.shift):
            // A text layer puts the caret in its text box, any other single layer or group renames its row (the Mac
            // `editSelectedLayer`).
            guard editor.selectedLayers.count == 1, let layer = editor.selectedLayer else { return false }
            if case .text = layer.content, let block = textBlock { return block.focusTextBox() }
            return list.beginRenameSelected()
        case .character("a") where modifiers.contains(.command):
            selectAll(); return true
        default: return false
        }
    }

    public func tick() {
        form.tick(); tail.tick(); textBlock?.tick()
    }

    public func help(at p: CGPoint) -> String? {
        guard let r = region(at: p) else { return nil }
        switch r {
        case .list: return list.help(at: local(p, r))
        case .form: return form.help(at: local(p, r))
        case .tail: return tail.help(at: local(p, r))
        case .text(let part): return textBlock?.help(at: local(p, r), part: part)
        case .handle: return SQL10n.string("Drag to resize the layer list")
        default: return nil
        }
    }

    /// The panel needs frames while a status message or a field burst is pending.
    public var needsTick: Bool { status.map { clock() < $0.until } ?? false }
}
