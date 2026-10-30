import Foundation
import SQCore
import SQUIKit
import SQText

/// Graphics clip space <-> sequence space (offsets from the canvas center, y down) through the clip's Motion at the
/// playhead. The graphic's content is the whole canvas, so its content center is the canvas center.
public struct GraphicsCanvasMapping: Sendable, Equatable {
    public var transform: ClipTransform
    public init(transform: ClipTransform) { self.transform = transform }

    private var rad: Double { transform.rotation * .pi / 180 }

    public func sequenceOffset(fromCanvas q: Vec2) -> Vec2 {
        let d = q - transform.anchor
        let x = d.x * transform.scale.x, y = d.y * transform.scale.y
        return transform.position + Vec2(x * cos(rad) - y * sin(rad), x * sin(rad) + y * cos(rad))
    }

    public func canvasPoint(fromSequence p: Vec2) -> Vec2 {
        let d = p - transform.position
        let x = d.x * cos(rad) + d.y * sin(rad), y = -d.x * sin(rad) + d.y * cos(rad)
        let sx = abs(transform.scale.x) > 1e-9 ? transform.scale.x : 1e-9
        let sy = abs(transform.scale.y) > 1e-9 ? transform.scale.y : 1e-9
        return Vec2(x / sx, y / sy) + transform.anchor
    }

    /// A sequence-space drag delta as a canvas delta.
    public func canvasDelta(fromSequence d: Vec2) -> Vec2 { canvasPoint(fromSequence: d + transform.position) - canvasPoint(fromSequence: transform.position) }
}

/// The Graphics panel's and the Program monitor's view of the selected graphics clip: which layers are selected, and
/// every layer edit as one undo step (property drags merge per layer and property).

@MainActor
public final class GraphicsEditor {
    public let session: EditorSession
    public private(set) var selectedLayers: Set<UUID> = [] { didSet { if selectedLayers != oldValue { publishSelection() } } }
    /// Layer selection or layer content changed outside a project change (panel and overlay refresh).
    public var onSelectionChange: (() -> Void)?
    private var shownClip: Clip.ID?
    /// Draw tool: a drag on the Program monitor adds a freeform stroke layer (switched off after each stroke).
    public var isDrawing = false { didSet { if isDrawing != oldValue { onSelectionChange?() } } }
    private var gesture = 0

    public init(session: EditorSession) {
        self.session = session
        #if canImport(CoreText)
        TextGenerator.installFollowMeasure()   // G11: same text boxes for Follow in the monitor as in this overlay
        #endif
    }

    isolated deinit { session.graphicLayerSelection = nil }

    /// Tells the session which layers of which clip are selected (a Look needs the clip too: a copy of the clip keeps the layer ids).
    private func publishSelection() {
        let next = selectedLayers.isEmpty ? nil : session.singleSelectedClip.map { GraphicLayerSelection(clip: $0.id, layers: selectedLayers) }
        if session.graphicLayerSelection != next { session.graphicLayerSelection = next }
    }

    // MARK: State

    /// The selected clip when it is a graphics clip.
    public var clip: Clip? { session.singleSelectedClip.flatMap { $0.isGraphics ? $0 : nil } }
    public var document: GraphicsDocument? { clip?.graphics }

    /// Playhead in the clip's local time (keys are written here), clamped to the clip.
    public var localTime: Time {
        guard let c = clip else { return .zero }
        let t = session.playhead - c.start
        return t < .zero ? .zero : (t > c.duration ? c.duration : t)
    }

    public var canvas: Vec2 {
        guard let f = session.activeTimeline?.format else { return Vec2(1920, 1080) }
        return Vec2(Double(f.width), Double(f.height))
    }

    /// The single selected layer (properties are shown for it).
    public var selectedLayer: GraphicsLayer? {
        guard selectedLayers.count == 1, let id = selectedLayers.first else { return nil }
        return document?.layer(id)
    }

    /// The graphic's Motion at the playhead (clip space <-> sequence space).
    public var mapping: GraphicsCanvasMapping? {
        guard let c = clip else { return nil }
        let shown = session.displayedClip(c)
        return GraphicsCanvasMapping(transform: shown.renderTransform(at: session.playhead, frame: canvas))
    }

    /// Text bounds for hit tests, handles and align: the SQText raster's box at scale 1 (layer Motion not applied), on the
    /// item's text time (range-local for an item with a range), the clock render draws it with.
    public var textMeasure: GraphicsTextMeasure {
        Self.textMeasure(clipDuration: clip?.duration ?? Time(5, 1), format: session.activeTimeline?.format)
    }

    static func textMeasure(clipDuration dur: Time, format: SequenceFormat?) -> GraphicsTextMeasure {
        return { ref, t in
            guard let format else { return nil }
            #if canImport(CoreText)
            return TextGenerator.graphicsRect(ref: ref, localTime: t.local, clipDuration: t.duration ?? dur, canvas: format)
            #else
            // shortcut: Follow at evaluation time still sees no text box off the Mac (installFollowMeasure is Core Text);
            // the editor and monitor hits measure with the portable layout. Upgrade by installing a portable Follow measure.
            return TextGenerator.portableGraphicsRect(ref: ref, localTime: t.local, clipDuration: t.duration ?? dur, canvas: format)
            #endif
        }
    }

    /// Call on every session change: a different clip clears the layer selection; deleted layers drop out of it.
    public func sync() {
        let id = clip?.id
        let ids = Set(document?.layers.map(\.id) ?? [])
        let kept = id == shownClip ? selectedLayers.intersection(ids) : []
        if id != shownClip { isDrawing = false }
        shownClip = id
        if kept != selectedLayers { selectedLayers = kept; onSelectionChange?() }
    }

    public func select(_ ids: Set<UUID>) {
        let ids = ids.intersection(Set(document?.layers.map(\.id) ?? []))
        guard ids != selectedLayers else { return }
        selectedLayers = ids
        onSelectionChange?()
    }

    public func selectAllLayers() { select(Set(document?.layers.map(\.id) ?? [])) }

    /// Starts a new drag: its edits merge into one undo step, separate from the previous drag.
    public func beginGesture() { gesture += 1; session.stopPlayback() }
    /// Closes the open gesture: the next edit never merges into it.
    public func endGesture() { gesture += 1 }

    // MARK: Edits

    /// Intro / outro zone lengths in seconds (the in and out animation of the whole clip). One undo step per drag.
    public func setZoneLengths(intro: Double?, outro: Double?) {
        guard let c = clip else { return }
        let z = c.zones
        func t(_ s: Double) -> Time { Time(Int64((s * 600).rounded()), 600) }
        let i = intro.map(t) ?? z?.introEnd ?? .zero, o = outro.map(t) ?? z?.outroLength ?? .zero
        try? session.perform("Set Intro and Outro", coalescing: "zoneLengths:\(c.id):\(gesture)") {   // locked track: no change
            try $0.setAnimationZoneLengths(intro: i, outro: o, clip: c.id)
        }
    }

    /// One undo step on the selected graphics clip. `merge`: edits with the same key merge (drags, steppers).
    @discardableResult
    public func edit(_ name: String, merge: String? = nil, _ body: (inout GraphicsDocument) -> Void) -> Bool {
        guard let c = clip else { return false }
        return session.editGraphics(c.id, name: SQL10n.undoName(name), coalescing: merge.map { "gfx:\(c.id):\($0):\(gesture)" }, body)
    }

    /// New Graphics Clip: an empty graphic at the playhead, selected.
    @discardableResult
    public func newGraphicsClip() -> Clip.ID? {
        let id = session.addGraphicsClip()
        sync()
        return id
    }

    public func addShape(_ kind: ShapeKind) {
        let c = canvas
        add(GraphicsLayer.shape(kind, canvasWidth: Int(c.x), canvasHeight: Int(c.y)), name: "Add \(kind.title)")
    }

    public func addText(_ string: String = "Text") {
        let template = TextTemplate(name: "Text", text: string, style: CaptionPresetLibrary.builtIn.style(for: "title"))
        guard let ref = try? TextGenerator.makeRef(template: template, animations: nil) else { return }
        add(GraphicsLayer.text(ref, name: string), name: "Add Text")
    }

    /// A free drawing stroke (canvas points, offsets from the canvas center), smoothed and reduced to the points that
    /// carry its shape (`tolerance` in canvas px).
    public func addPath(_ points: [Vec2], closed: Bool = false, color: EffectColor = .white, strokeWidth: Double = 8,
                        tolerance: Double = GraphicsEditor.strokeTolerance) {
        isDrawing = false
        guard let layer = Self.strokeLayer(points, closed: closed, color: color, strokeWidth: strokeWidth, tolerance: tolerance) else { return }
        add(layer, name: "Draw")
    }

    /// Smoothing tolerance of a stroke when the caller has no view scale (canvas px).
    public static let strokeTolerance = 2.0

    /// The layer of a drawn stroke; nil for fewer than two points.
    public static func strokeLayer(_ points: [Vec2], closed: Bool = false, color: EffectColor = .white, strokeWidth: Double = 8,
                                   tolerance: Double = GraphicsEditor.strokeTolerance) -> GraphicsLayer? {
        let pts = PathSmoothing.smooth(points, tolerance: tolerance)
        guard pts.count >= 2 else { return nil }
        return GraphicsLayer.path(canvasPoints: pts, closed: closed, color: color, strokeWidth: strokeWidth)
    }

    /// Adds `layer` above the selected ones as one undo step `name` and selects it.
    public func add(_ layer: GraphicsLayer, name: String) {
        let above = selectedLayers.compactMap { document?.index(of: $0) }.max().flatMap { document?.layers[$0].id }
        var newID: UUID?
        guard edit(name, { newID = $0.add(layer, above: above) }), let newID else { return }
        selectedLayers = [newID]
        onSelectionChange?()
    }

    public func deleteSelected() {
        let ids = selectedLayers
        guard !ids.isEmpty, edit("Delete Layers", { $0.remove(ids) }) else { return }
        select([])
    }

    public func duplicateSelected() {
        guard let doc = document, !selectedLayers.isEmpty else { return }
        let ordered = doc.layers.map(\.id).filter(selectedLayers.contains)
        var copies: [UUID] = []
        guard edit("Duplicate Layers", { copies = $0.duplicate(ordered) }) else { return }
        selectedLayers = Set(copies)
        onSelectionChange?()
    }

    public func groupSelected() {
        let ids = selectedLayers
        guard ids.count >= 2 else { return }
        edit("Group Layers") { _ = $0.group(ids, name: "Group") }
    }

    public func ungroupSelected() {
        guard let doc = document else { return }
        let groups = Set(selectedLayers.compactMap { doc.layer($0)?.group })
        guard !groups.isEmpty else { return }
        edit("Ungroup Layers") { d in for g in groups { d.ungroup(g) } }
    }

    public func reorder(_ how: GraphicsReorder) {
        let ids = selectedLayers
        guard !ids.isEmpty else { return }
        edit("Arrange Layers") { $0.reorder(ids, how) }
    }

    public func move(_ ids: [UUID], toIndex i: Int) {
        edit("Arrange Layers") { $0.move(ids, toIndex: i) }
    }

    /// Layer list drag: one undo step "Arrange Layers"; the moved layers stay selected.
    public func apply(_ drop: LayerDrop) {
        guard edit("Arrange Layers", { $0.move(drop.ids, toIndex: drop.toIndex, group: drop.group) }) else { return }
        select(Set(drop.ids))
    }

    /// Layer list Option-drag: copies of the dragged layers land at the drop, the originals stay; the copies are selected.
    public func applyCopy(_ drop: LayerDrop) {
        var copies: [UUID] = []
        guard edit("Duplicate Layers", { copies = $0.copy(drop.ids, toIndex: drop.toIndex, group: drop.group) }),
              !copies.isEmpty else { return }
        select(Set(copies))
    }

    public func renameGroup(_ id: UUID, _ name: String) {
        guard let old = document?.group(id)?.name, old != name.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        edit("Rename Group") { $0.renameGroup(id, name) }
    }

    /// Eye of a group row: every member shown or hidden, one undo step.
    public func setVisible(_ ids: Set<UUID>, _ on: Bool) {
        edit(on ? "Show Layers" : "Hide Layers") { d in for id in ids { d.update(id) { $0.isVisible = on } } }
    }

    /// Lock of a group row: every member locked or unlocked, one undo step.
    public func setLocked(_ ids: Set<UUID>, _ on: Bool) {
        edit(on ? "Lock Layers" : "Unlock Layers") { d in for id in ids { d.update(id) { $0.isLocked = on } } }
    }

    /// Isolate: every layer except the selected ones hidden (`hideOthers`) or locked (`lockOthers`), one undo step.
    public func isolateSelection(lock: Bool) {
        let keep = selectedLayers
        guard !keep.isEmpty, let all = document?.layers.map(\.id) else { return }
        let others = all.filter { !keep.contains($0) }
        guard !others.isEmpty else { return }
        edit(lock ? "Lock Others" : "Hide Others") { d in
            for id in others { d.update(id) { if lock { $0.isLocked = true } else { $0.isVisible = false } } }
        }
    }

    /// Every layer shown and unlocked, one undo step.
    public func showAllLayers() {
        guard let all = document?.layers.map(\.id), !all.isEmpty else { return }
        edit("Show All Layers") { d in for id in all { d.update(id) { $0.isVisible = true; $0.isLocked = false } } }
    }

    /// The members of group `g`.
    public func members(of g: UUID) -> Set<UUID> { Set(document?.layers.filter { $0.group == g }.map(\.id) ?? []) }

    /// Align: to the frame (each layer on its own) or, for 2+ layers, to the selection's joint bounds.
    public func align(_ edge: GraphicsAlign, toFrame: Bool = false) {
        let ids = selectedLayers, t = localTime, c = canvas, m = textMeasure
        guard !ids.isEmpty else { return }
        // Measured as drawn (Follow resolved); axes and sizes Follow sets stay its own (G11).
        edit("Align Layers") {
            $0.editingResolved(atLocal: t, canvas: c, text: m) { $0.align(ids, edge, canvas: c, atLocal: t, text: m, toFrame: toFrame) }
        }
    }

    public func distribute(_ axis: GraphicsAxis) {
        let ids = selectedLayers, t = localTime, c = canvas, m = textMeasure
        guard ids.count >= 3 else { return }
        edit("Distribute Layers") {
            $0.editingResolved(atLocal: t, canvas: c, text: m) { $0.distribute(ids, axis, atLocal: t, text: m) }
        }
    }

    public func setVisible(_ id: UUID, _ on: Bool) { edit(on ? "Show Layer" : "Hide Layer") { $0.update(id) { $0.isVisible = on } } }
    public func setLocked(_ id: UUID, _ on: Bool) { edit(on ? "Lock Layer" : "Unlock Layer") { $0.update(id) { $0.isLocked = on } } }
    /// Color label of the layers (nil = none), one undo step; unchanged = no step.
    public func setLabel(_ ids: some Sequence<UUID>, _ label: LabelColor?) {
        let list = Array(ids)
        guard let d = document, list.contains(where: { d.layer($0)?.label != label }) else { return }
        edit(label == nil ? "Clear Layer Label" : "Label Layers") { d in for id in list { d.update(id) { $0.label = label } } }
    }
    public func rename(_ id: UUID, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, document?.layer(id)?.name != n else { return }
        edit("Rename Layer") { $0.update(id) { $0.name = n } }
    }

    /// Monitor drag: moves the selected layers (and their groups) by a canvas delta; one undo step per drag.
    public func translateSelected(by d: Vec2) {
        let ids = selectedLayers
        guard !ids.isEmpty, d != .zero else { return }
        // A pinned layer's dragged axis is unpinned where it is drawn (G11).
        let t = localTime, c = canvas, m = textMeasure
        edit("Move Layers", merge: "move") { $0.moveEditingResolved(ids, by: d, atLocal: t, canvas: c, text: m) }
    }

    /// Monitor corner handle drag (one undo step per drag).
    public func resize(_ id: UUID, corner: GraphicsCorner, to p: Vec2, keepAspect: Bool) {
        let t = localTime, c = canvas, m = textMeasure
        // Text: the handles change the font size, not Scale (non-text layers keep scaling).
        if let doc = document, let out = Self.resizingText(doc, id: id, corner: corner, to: p, atLocal: t, text: m) {
            edit("Resize Text", merge: "resize") { $0 = out }
            return
        }
        edit("Resize Layer", merge: "resize") {
            $0.editingResolved(atLocal: t, canvas: c, text: m) {
                $0.resize(id, corner: corner, to: p, atLocal: t, keepAspect: keepAspect, text: m)
            }
        }
    }

    // MARK: Layer properties (every selected layer, at the playhead)

    /// A keyable layer property: Motion, or a scalar parameter of the layer's first effect of `kind` (Shape look, Shadow).
    public enum Property: Hashable, Sendable {
        case position, anchor, scale, rotation, opacity
        /// A scalar effect parameter; `id` binds to one effect instance (nil = the layer's first effect of `kind`).
        case effect(kind: String, key: String, id: UUID? = nil)
        /// A point parameter (X, Y) of an effect of `kind` (stored in `ClipEffect.points`).
        case effectPoint(kind: String, key: String, id: UUID? = nil)

        /// Merge key for gestures.
        var id: String {
            switch self {
            case .position: "position"
            case .anchor: "anchor"
            case .scale: "scale"
            case .rotation: "rotation"
            case .opacity: "opacity"
            case .effect(let kind, let key, let fid): "\(kind).\(key).\(fid?.uuidString ?? "")"
            case .effectPoint(let kind, let key, let fid): "\(kind).\(key).point.\(fid?.uuidString ?? "")"
            }
        }

        /// Name used in tooltips and undo names ("Add Opacity Keyframe").
        public var title: String {
            switch self {
            case .effect(let kind, let key, _), .effectPoint(let kind, let key, _): EffectCatalog.param(kind, key)?.title ?? key
            default: id.prefix(1).uppercased() + id.dropFirst()
            }
        }

        public static func shape(_ key: String) -> Property { .effect(kind: ClipEffect.shapeEffectKind, key: key) }
    }

    /// The selected layers, bottom first.
    public var targetLayers: [GraphicsLayer] { document?.layers.filter { selectedLayers.contains($0.id) } ?? [] }
    /// The front-most selected layer: its key state is what the stopwatch shows.
    public var primaryLayer: GraphicsLayer? { targetLayers.last }

    /// The value shown for `p` (component `axis` of a Vec2): nil when the selected layers differ (mixed) or none has it.
    public func value(_ p: Property, axis: Int = 0) -> Double? {
        let t = localTime
        let vs = targetLayers.compactMap { Self.component($0, p, axis, t) }
        guard let first = vs.first, vs.count == targetLayers.count else { return nil }
        return vs.allSatisfy { abs($0 - first) < 1e-9 } ? first : nil
    }

    /// Sets component `axis` of `p` on every selected layer (the other component stays per layer); keys where animated.
    public func setValue(_ p: Property, axis: Int = 0, _ v: Double) {
        writeAll(p) { l, t in Self.write(&l, p, axis: axis, v, t) }
    }

    /// Linked scale: component `axis` becomes `v` on every selected layer, the other follows in that layer's own ratio.
    public func setScaleLinked(axis: Int, _ v: Double) {
        writeAll(.scale) { l, t in
            let old = l.animation.scale.value(atLocal: t)
            let o = axis == 0 ? old.x : old.y, other = axis == 0 ? old.y : old.x
            let k = abs(o) > 1e-9 ? v / o : 1
            let n = abs(o) > 1e-9 ? other * k : v
            l.animation.scale.set(axis == 0 ? Vec2(v, n) : Vec2(n, v), atLocal: t)
        }
    }

    /// The blend mode shown (nil when the selected layers differ).
    public var blendMode: BlendMode? {
        let ms = Set(targetLayers.map(\.blendMode))
        return ms.count == 1 ? ms.first : nil
    }

    /// The target layers in a merge key: edits on another selection never fold into the same undo step.
    static func mergeIDs(_ ids: [UUID]) -> String { ids.map(\.uuidString).sorted().joined(separator: ",") }

    private func writeAll(_ p: Property, _ body: @escaping (inout GraphicsLayer, Time) -> Void) {
        let ids = targetLayers.map(\.id)
        guard !ids.isEmpty else { return }
        let t = localTime
        edit(p.title, merge: "props:\(p.id):\(Self.mergeIDs(ids))") { d in for id in ids { d.update(id) { body(&$0, t) } } }
    }

    /// The effect a property addresses: by id when it carries one (a second effect of the same kind has its own tracks),
    /// else the layer's first effect of that kind (Shape look, Shadow).
    private static func fxIndex(_ l: GraphicsLayer, _ kind: String, _ id: UUID?) -> Int? {
        if let id { return l.effects.firstIndex { $0.id == id } }
        return l.effects.firstIndex { $0.kind == kind }
    }
    private static func fx(_ l: GraphicsLayer, _ kind: String, _ id: UUID?) -> ClipEffect? { fxIndex(l, kind, id).map { l.effects[$0] } }

    private static func component(_ l: GraphicsLayer, _ p: Property, _ axis: Int, _ t: Time) -> Double? {
        let a = l.animation
        func c(_ v: Vec2) -> Double { axis == 0 ? v.x : v.y }
        switch p {
        case .position: return c(a.position.value(atLocal: t))
        case .anchor: return c(a.anchor.value(atLocal: t))
        case .scale: return c(a.scale.value(atLocal: t))
        case .rotation: return a.rotation.value(atLocal: t)
        case .opacity: return a.opacity.value(atLocal: t)
        case .effect(let kind, let key, let fid): return Self.fx(l, kind, fid)?.scalar(key, atLocal: t)
        case .effectPoint(let kind, let key, let fid):
            guard let v = Self.fx(l, kind, fid)?.points[key]?.value(atLocal: t) else { return nil }
            return c(v)
        }
    }

    private static func write(_ l: inout GraphicsLayer, _ p: Property, axis: Int, _ v: Double, _ t: Time) {
        func vec(_ a: inout AnimatedProperty<Vec2>) {
            var x = a.value(atLocal: t)
            if axis == 0 { x.x = v } else { x.y = v }
            // A layer's typed Position is the base of its animation: the keys move with it (`movedBase`).
            if case .position = p { a = a.movedBase(to: x, atLocal: t) } else { a.set(x, atLocal: t) }
        }
        switch p {
        case .position: vec(&l.animation.position)
        case .anchor: vec(&l.animation.anchor)
        case .scale: vec(&l.animation.scale)
        case .rotation: l.animation.rotation.set(v, atLocal: t)
        case .opacity: l.animation.opacity.set(min(max(v, 0), 1), atLocal: t)
        case .effect(let kind, let key, let fid):
            guard let i = Self.fxIndex(l, kind, fid) else { return }
            var prop = l.effects[i].parameters[key] ?? AnimatedProperty(l.effects[i].scalar(key, atLocal: t))
            prop.set(v, atLocal: t)
            l.effects[i].parameters[key] = prop
        case .effectPoint(let kind, let key, let fid):
            guard let i = Self.fxIndex(l, kind, fid) else { return }
            var prop = l.effects[i].points[key] ?? AnimatedProperty(.zero)
            vec(&prop)
            l.effects[i].points[key] = prop
        }
    }

    // MARK: Keys (state of the front-most selected layer; buttons act on every selected layer)

    private enum KeyOp { case start, stop, add, remove, ease(EasingCurve) }

    private static func keyInfo(_ l: GraphicsLayer, _ p: Property) -> (animated: Bool, times: [Time], shapes: [EaseShape]) {
        func info<V>(_ a: AnimatedProperty<V>) -> (Bool, [Time], [EaseShape]) {
            (a.isAnimated, a.track.keys.map(\.time),
             a.track.keys.map { EaseShape(interpolation: $0.interpolation, out: $0.outHandle, in: $0.inHandle) })
        }
        let a = l.animation
        switch p {
        case .position: return info(a.position)
        case .anchor: return info(a.anchor)
        case .scale: return info(a.scale)
        case .rotation: return info(a.rotation)
        case .opacity: return info(a.opacity)
        case .effect(let kind, let key, let fid):
            guard let prop = Self.fx(l, kind, fid)?.parameters[key] else { return (false, [], []) }
            return info(prop)
        case .effectPoint(let kind, let key, let fid):
            guard let prop = Self.fx(l, kind, fid)?.points[key] else { return (false, [], []) }
            return info(prop)
        }
    }

    private static func apply(_ op: KeyOp, _ p: Property, to l: inout GraphicsLayer, at t: Time) {
        func run<V>(_ a: inout AnimatedProperty<V>) {
            switch op {
            case .start: if !a.isAnimated { a.toggleKeyframing(atLocal: t) }
            case .stop: if a.isAnimated { a.toggleKeyframing(atLocal: t) }
            case .add:
                if !a.isAnimated { a.toggleKeyframing(atLocal: t) }
                else if !a.track.keys.contains(where: { $0.time == t }) { a.track.insert(Keyframe(time: t, value: a.value(atLocal: t))) }
            case .remove:
                if let k = a.track.keys.first(where: { $0.time == t }), a.track.keys.count > 1 { a.track.remove(k.id) }
            case .ease(let curve):
                // Only the key at the playhead (stored like clip keys); between keys nothing is overwritten.
                for k in a.track.keys where k.time == t { a.track.update(k.id) { curve.apply(to: &$0) } }
            }
        }
        switch p {
        case .position: run(&l.animation.position)
        case .anchor: run(&l.animation.anchor)
        case .scale: run(&l.animation.scale)
        case .rotation: run(&l.animation.rotation)
        case .opacity: run(&l.animation.opacity)
        case .effect(let kind, let key, let fid):
            guard let i = Self.fxIndex(l, kind, fid) else { return }
            var prop = l.effects[i].parameters[key] ?? AnimatedProperty(l.effects[i].scalar(key, atLocal: t))
            run(&prop)
            l.effects[i].parameters[key] = prop
        case .effectPoint(let kind, let key, let fid):
            guard let i = Self.fxIndex(l, kind, fid) else { return }
            var prop = l.effects[i].points[key] ?? AnimatedProperty(.zero)
            run(&prop)
            l.effects[i].points[key] = prop
        }
    }

    private func applyAll(_ op: KeyOp, _ p: Property, name: String, merge: String? = nil) {
        let ids = targetLayers.filter { !$0.isLocked }.map(\.id), t = localTime
        guard !ids.isEmpty else { return }
        edit(name, merge: merge) { d in for id in ids { d.update(id) { Self.apply(op, p, to: &$0, at: t) } } }
    }

    /// Ease of the key at the playhead of `p`, as the curve editor reads it; nil when the playhead is not on a key.
    public func keyEaseShape(_ p: Property) -> EaseShape? {
        guard let l = primaryLayer else { return nil }
        let info = Self.keyInfo(l, p)
        return info.times.firstIndex(of: localTime).map { info.shapes[$0] }
    }

    /// The name of that ease from the one vocabulary (`EasingCurve.displayName` of the matching built-in), "Custom" otherwise.
    public func keyEaseName(_ p: Property) -> String? {
        guard let s = keyEaseShape(p) else { return nil }
        return EasingCurve.builtIns.first { $0.shape.isApproximatelyEqual(to: s) }?.displayName ?? EaseName.custom
    }

    /// Right-click ease of a layer key: the key at the playhead (no-op when the playhead is between keys, so hand-set
    /// eases are never overwritten). Stored like clip keys (interpolation + handles). One undo step; `merge` joins a drag.
    public func setKeyEase(_ p: Property, _ curve: EasingCurve, merge: Bool = false) {
        guard isKeyAtPlayhead(p) else { return }
        applyAll(.ease(curve), p, name: "Set \(p.title) Ease", merge: merge ? "ease:\(p.id)" : nil)
    }

    /// Moves the playhead to a clip-local time.
    public func seekLocal(_ t: Time) {
        guard let c = clip else { return }
        session.seek(to: c.start + t)
    }

    public func isKeyed(_ p: Property) -> Bool { primaryLayer.map { Self.keyInfo($0, p).animated } ?? false }

    /// Keys of every selected layer (navigation and the key button look at all of them).
    private func keyTimes(_ p: Property) -> [Time] {
        Array(Set(targetLayers.flatMap { Self.keyInfo($0, p).times })).sorted()
    }

    /// The playhead lies inside the selected graphics clip (a key can only be added there).
    public var playheadInClip: Bool {
        guard let c = clip else { return false }
        return session.playhead >= c.start && session.playhead < c.start + c.duration
    }

    /// What the shared keyframe control shows for `p` (gray ring off, accent ring plus navigation when animated).
    public func keyframeState(_ p: Property) -> KeyframeControlState {
        .resolve(animated: isKeyed(p), onKey: isKeyAtPlayhead(p), hasPrevious: previousKeyTime(p) != nil,
                 hasNext: nextKeyTime(p) != nil, playheadInRange: playheadInClip)
    }

    public func keyCount(_ p: Property) -> Int { keyTimes(p).count }
    public func isKeyAtPlayhead(_ p: Property) -> Bool { keyTimes(p).contains(localTime) }
    /// Nearest key before / after the playhead in clip-local time (nil when none).
    public func previousKeyTime(_ p: Property) -> Time? { keyTimes(p).filter { $0 < localTime }.max() }
    public func nextKeyTime(_ p: Property) -> Time? { keyTimes(p).filter { $0 > localTime }.min() }

    /// Previous / next key button: moves the playhead (timeline time).
    public func goToKey(_ p: Property, forward: Bool) {
        guard let c = clip, let t = forward ? nextKeyTime(p) : previousKeyTime(p) else { return }
        session.seek(to: c.start + t)
    }

    /// Key button: adds a key with the current value at the playhead on every selected layer, or removes the keys there.
    /// Needs an animated property (the stopwatch turns animation on).
    public func toggleKeyAtPlayhead(_ p: Property) {
        guard isKeyed(p) else { return }
        let adding = !isKeyAtPlayhead(p)
        applyAll(adding ? .add : .remove, p, name: adding ? "Add \(p.title) Keyframe" : "Remove \(p.title) Keyframe")
    }

    /// Stopwatch: animation on (a key at the playhead) or off for every selected layer.
    public func toggleKeyframing(_ p: Property) {
        let on = isKeyed(p)
        applyAll(on ? .stop : .start, p, name: on ? "Stop Animating \(p.title)" : "Animate \(p.title)")
    }

    public func setPosition(_ v: Vec2) { setValue(.position, axis: 0, v.x); setValue(.position, axis: 1, v.y) }
    /// Uniform scale on every selected layer.
    public func setScale(_ v: Double) { writeAll(.scale) { l, t in l.animation.scale.set(Vec2(v, v), atLocal: t) } }
    public func setRotation(_ v: Double) { setValue(.rotation, v) }
    public func setOpacity(_ v: Double) { setValue(.opacity, v) }
    public func setBlendMode(_ m: BlendMode) {
        let ids = targetLayers.map(\.id)
        guard !ids.isEmpty else { return }
        edit("Blend Mode", merge: "props:blend:\(Self.mergeIDs(ids))") { d in for id in ids { d.update(id) { $0.blendMode = m } } }
    }

    /// Shape effect value (Width, Height, Corner Radius, Outline Width, Fill/Outline on-off) at the playhead; nil = mixed.
    public func shapeValue(_ key: String) -> Double? { value(.shape(key)) }

    /// Color `key` of the first `kind` effect of every selected layer at the playhead; nil when they differ.
    public func color(kind: String, key: String) -> EffectColor? {
        let t = localTime
        let cs = targetLayers.compactMap { l -> EffectColor? in
            guard let e = l.effects.first(where: { $0.kind == kind }) else { return nil }
            return e.colors[key]?.value(atLocal: t) ?? (EffectCatalog.param(e.kind, key).flatMap {
                if case .color(let c) = $0.kind { c } else { nil }
            })
        }
        guard let first = cs.first, cs.count == targetLayers.count, cs.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Sets color `key` of the first `kind` effect on every selected layer (one step per picker session).
    public func setColor(kind: String, key: String, _ c: EffectColor) {
        let ids = targetLayers.map(\.id), t = localTime
        guard !ids.isEmpty else { return }
        edit(EffectCatalog.param(kind, key)?.title ?? "Color", merge: "props:color:\(kind).\(key):\(Self.mergeIDs(ids))") { d in
            for id in ids { d.update(id) { l in
                guard let i = l.effects.firstIndex(where: { $0.kind == kind }) else { return }
                var prop = l.effects[i].colors[key] ?? AnimatedProperty(c)
                prop.set(c, atLocal: t)
                l.effects[i].colors[key] = prop
            } }
        }
    }

    private static func layerColor(_ l: GraphicsLayer, kind: String, key: String, at t: Time) -> EffectColor? {
        guard let e = l.effects.first(where: { $0.kind == kind }) else { return nil }
        return e.colors[key]?.value(atLocal: t) ?? (EffectCatalog.param(e.kind, key).flatMap {
            if case .color(let c) = $0.kind { c } else { nil }
        })
    }

    /// Opacity (0...1) of color `key` on every selected layer at the playhead; nil when it differs. The colors may differ.
    public func colorAlpha(kind: String, key: String) -> Double? {
        let t = localTime
        let alphas = targetLayers.compactMap { Self.layerColor($0, kind: kind, key: key, at: t)?.alpha }
        guard let first = alphas.first, alphas.count == targetLayers.count, alphas.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Sets the opacity of color `key` on every selected layer; each layer keeps its own color.
    public func setColorAlpha(kind: String, key: String, _ alpha: Double) {
        let ids = targetLayers.map(\.id), t = localTime
        guard !ids.isEmpty else { return }
        let a = min(max(alpha, 0), 1)
        edit("Opacity", merge: "props:alpha:\(kind).\(key):\(Self.mergeIDs(ids))") { d in
            for id in ids { d.update(id) { l in
                guard let i = l.effects.firstIndex(where: { $0.kind == kind }),
                      var c = Self.layerColor(l, kind: kind, key: key, at: t) else { return }
                c.alpha = a
                var prop = l.effects[i].colors[key] ?? AnimatedProperty(c)
                prop.set(c, atLocal: t)
                l.effects[i].colors[key] = prop
            } }
        }
    }

    public func shapeColor(_ key: String) -> EffectColor? { color(kind: ClipEffect.shapeEffectKind, key: key) }
    public func setShapeValue(_ key: String, _ v: Double) { setValue(.shape(key), v) }
    public func setShapeColor(_ key: String, _ c: EffectColor) { setColor(kind: ClipEffect.shapeEffectKind, key: key, c) }

    // MARK: Shape kind and Shadow (Appearance)

    /// Kind of the selected shape layers; nil when they differ or one is not a shape.
    public var shapeKind: ShapeKind? {
        let ks = targetLayers.map { l -> ShapeKind? in if case .shape(let k) = l.content { k } else { nil } }
        guard let first = ks.first ?? nil, ks.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Changes every selected shape layer to `k` (size and look stay); a line gets its outline switched on.
    public func setShapeKind(_ k: ShapeKind) {
        let ids = targetLayers.filter { if case .shape = $0.content { true } else { false } }.map(\.id), t = localTime
        guard !ids.isEmpty else { return }
        edit("Shape Kind") { d in for id in ids { d.update(id) { l in
            l.content = .shape(kind: k)
            guard k == .line, let i = l.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }),
                  l.effects[i].scalar(ClipEffect.shapeStrokeKey, atLocal: t) < 0.5 else { return }
            var on = l.effects[i].parameters[ClipEffect.shapeStrokeKey] ?? AnimatedProperty(1)
            on.set(1, atLocal: t)
            l.effects[i].parameters[ClipEffect.shapeStrokeKey] = on
        } } }
    }

    /// Shadow row: the row shows each layer's first drop shadow (further ones stay in Effects). true when that shadow
    /// exists and is on in every selected layer, false when in none, nil when mixed.
    public var shadowState: Bool? {
        let on = targetLayers.map { $0.effects.first { $0.kind == ClipEffect.dropShadowKind }?.enabled ?? false }
        guard let first = on.first, on.allSatisfy({ $0 == first }) else { return on.isEmpty ? false : nil }
        return first
    }

    /// Shadow on: the first drop shadow is switched on, a layer without one gets one (catalog defaults). Off: the first
    /// drop shadow is switched off and keeps its settings and keys. Further drop shadows are never touched.
    public func setShadow(_ on: Bool) {
        let ids = targetLayers.map(\.id)
        guard !ids.isEmpty else { return }
        edit(on ? "Shadow On" : "Shadow Off") { d in for id in ids { d.update(id) { l in
            if let i = l.effects.firstIndex(where: { $0.kind == ClipEffect.dropShadowKind }) { l.effects[i].enabled = on }
            else if on, let e = ClipEffect.make(kind: ClipEffect.dropShadowKind) { l.effects.append(e) }
        } } }
    }

    // MARK: Text

    public var textTemplate: TextTemplate? {
        guard let l = selectedLayer, case .text(let ref) = l.content else { return nil }
        return try? TextGenerator.decode(ref).0
    }

    /// In / Out animation of the selected text layer (nil for other layers; an empty set when none is stored).
    public var textAnimations: AnimationSet? {
        guard let l = selectedLayer, case .text(let ref) = l.content, let d = try? TextGenerator.decode(ref) else { return nil }
        return d.1 ?? AnimationSet(in: nil, out: nil)
    }

    /// Stores new In / Out animations on the selected text layer; the style and text stay as they are. One undo step.
    public func updateTextAnimations(_ name: String, _ animations: AnimationSet) {
        updateText(name, animations: animations) { _ in }
    }

    /// Text string, size or color of the selected text layer (the layer name follows a string that was its name).
    public func updateText(_ name: String, animations: AnimationSet? = nil, _ body: (inout TextTemplate) -> Void) {
        guard let l = selectedLayer, case .text(let ref) = l.content, let decoded = try? TextGenerator.decode(ref) else { return }
        var template = decoded.0
        let anims = animations ?? decoded.1
        let oldText = template.text
        body(&template)
        guard let new = try? TextGenerator.makeRef(template: template, animations: anims) else { return }
        let rename = l.name == oldText || l.name == "Text"
        let text = template.text
        edit(name, merge: "\(l.id):text:\(name)") { $0.update(l.id) { l in
            l.content = .text(ref: new)
            if rename, !text.isEmpty { l.name = String(text.prefix(40)) }
        } }
    }

    // MARK: Layer effects

    /// Effects a layer can take (video effects; generator-owned and color grading stay out).
    public static var layerEffectSpecs: [EffectSpec] {
        EffectCatalog.all.filter { !EffectCatalog.isGeneratorOwned($0.kind) }
    }

    /// What the Add Effect menu lists: the visible catalog (hidden kinds already excluded) minus anything a layer refuses.
    public static var offeredEffects: [EffectSpec] {
        layerEffectSpecs.filter { refusalForEffect($0.kind) == nil }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Why `kind` cannot go onto a graphics layer (nil = it can). One rule for the drop from the Effects panel and the API.
    public static func refusalForEffect(_ kind: String) -> String? {
        if EffectDragPayload.transitionKind(forID: kind) != nil { return "Transitions go on the timeline, not on a layer." }
        if EffectCatalog.isGeneratorOwned(kind) { return "That look is built into the layer." }
        guard let e = ClipEffect.make(kind: kind), EffectCatalog.spec(for: kind) != nil else { return "That is not a layer effect." }
        if e.isAudio { return "Audio effects do not apply to graphics." }
        return nil
    }

    public enum EffectDrop: Equatable, Sendable { case added, refused(String) }

    /// Appends effect `kind` to `layer` (default: the selected layer); one undo step. Refusals add nothing.
    @discardableResult
    public func addEffect(_ kind: String, to layer: UUID? = nil) -> EffectDrop { addEffects([kind], to: layer) }

    /// Appends several effects (a dragged folder) as one undo step. Refused kinds are skipped; the result is the first
    /// refusal when there was one (the panel shows it), else `.added`.
    @discardableResult
    public func addEffects(_ kinds: [String], to layer: UUID? = nil) -> EffectDrop {
        guard let id = layer ?? selectedLayer?.id, let target = document?.layer(id) else { return .refused("Select a layer first.") }
        if target.isLocked { return .refused("The layer is locked.") }
        var new: [ClipEffect] = [], refusal: String?
        for kind in kinds {
            if let why = Self.refusalForEffect(kind) { refusal = refusal ?? why; continue }
            guard let e = ClipEffect.make(kind: kind) else { refusal = refusal ?? "That is not a layer effect."; continue }
            new.append(e)
        }
        if !new.isEmpty { edit("Add Effect") { $0.update(id) { $0.effects += new } } }
        return refusal.map { .refused($0) } ?? .added
    }

    public func removeEffect(_ effect: UUID) {
        guard let id = selectedLayer?.id else { return }
        edit("Remove Effect") { $0.update(id) { $0.effects.removeAll { $0.id == effect && !EffectCatalog.isGeneratorOwned($0.kind) } } }
    }

    public func setEffectEnabled(_ effect: UUID, _ on: Bool) {
        guard let id = selectedLayer?.id else { return }
        edit(on ? "Enable Effect" : "Disable Effect") { $0.update(id) { l in
            if let i = l.effects.firstIndex(where: { $0.id == effect }) { l.effects[i].enabled = on }
        } }
    }

    public func setEffectValue(_ effect: UUID, key: String, _ v: Double) {
        guard let l = selectedLayer, let kind = l.effects.first(where: { $0.id == effect })?.kind else { return }
        setEffect("Effect", key: key, of: kind, id: effect) { e, t in
            var prop = e.parameters[key] ?? AnimatedProperty(v)
            prop.set(v, atLocal: t)
            e.parameters[key] = prop
        }
    }

    public func setEffectColor(_ effect: UUID, key: String, _ c: EffectColor) {
        guard let l = selectedLayer, let kind = l.effects.first(where: { $0.id == effect })?.kind else { return }
        setEffect("Effect Color", key: key, of: kind, id: effect) { e, t in
            var prop = e.colors[key] ?? AnimatedProperty(c)
            prop.set(c, atLocal: t)
            e.colors[key] = prop
        }
    }

    private func setEffect(_ name: String, key: String, of kind: String, id effect: UUID? = nil,
                           _ body: @escaping (inout ClipEffect, Time) -> Void) {
        guard let id = selectedLayer?.id else { return }
        let t = localTime
        edit(name, merge: "\(id):\(effect?.uuidString ?? kind):\(key)") { $0.update(id) { l in
            guard let i = l.effects.firstIndex(where: { fx in effect.map { fx.id == $0 } ?? (fx.kind == kind) }) else { return }
            body(&l.effects[i], t)
        } }
    }
}
