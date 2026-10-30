import Foundation

// Pro grade (Color Graph effect, kind `colorGraph`, v78). The Simple grade is the clip's Color effects (fixed sections);
// the Pro grade is one Color Graph effect: an In LUT (the conversion, same rules as Simple's Input LUT), Steps in serial
// order, then an Out LUT. Simple and Pro are exclusive: `ColorGraph.isActive` says which one renders, the other one stays
// in the effect list dimmed with all its values. Static values (not keyframable in phase 1, like curves and Color Range).
// Steps work on the display-referred signal after the conversion.

/// Three channel values (red, green, blue). Stored as `[r, g, b]`.
public struct ColorTriple: Sendable, Hashable, Codable {
    public var r: Float, g: Float, b: Float
    public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    public init(all v: Float) { self.init(v, v, v) }

    public init(from d: Decoder) throws {
        var c = try d.unkeyedContainer()
        self.init(try c.decode(Float.self), try c.decode(Float.self), try c.decode(Float.self))
    }
    public func encode(to e: Encoder) throws {
        var c = e.unkeyedContainer()
        try c.encode(r); try c.encode(g); try c.encode(b)
    }
}

/// Lift / Gamma / Gain / Offset, then Contrast around Pivot and Saturation. Per channel:
/// `t = v + lift * (1 - v)`, `t = t * gain + offset`, `t = t^gamma` (t > 0), `t = (t - pivot) * contrast + pivot`,
/// then saturation around Rec.709 luma. With lift 0 and contrast 1 this is the ASC CDL (slope = gain, power = gamma).
public struct StepPrimaries: Sendable, Hashable, Codable {
    public var lift = ColorTriple(all: 0)       // -1...1
    public var gamma = ColorTriple(all: 1)      // exponent 0.1...4 (CDL power)
    public var gain = ColorTriple(all: 1)       // 0...4 (CDL slope)
    public var offset = ColorTriple(all: 0)     // -1...1
    public var contrast: Float = 1              // 0...2
    public var pivot: Float = 0.435             // 0...1, display-referred
    public var saturation: Float = 1            // 0...4
    public init() {}

    public var isNeutral: Bool { self == StepPrimaries() }

    /// The slider ranges (the Step inspector and imported decisions keep to them).
    public static let liftRange: ClosedRange<Float> = -1...1
    public static let gammaRange: ClosedRange<Float> = 0.1...4
    public static let gainRange: ClosedRange<Float> = 0...4
    public static let offsetRange: ClosedRange<Float> = -1...1
    public static let contrastRange: ClosedRange<Float> = 0...2
    public static let pivotRange: ClosedRange<Float> = 0...1
    public static let saturationRange: ClosedRange<Float> = 0...4

    /// Reference maths (the renderer's CPU path and GPU kernel follow it).
    public func apply(_ c: (Float, Float, Float)) -> (Float, Float, Float) {
        func ch(_ v: Float, _ l: Float, _ ga: Float, _ gn: Float, _ o: Float) -> Float {
            var t = v + l * (1 - v)
            t = t * gn + o
            if t > 0, ga != 1 { t = pow(t, ga) }
            return (t - pivot) * contrast + pivot
        }
        let r = ch(c.0, lift.r, gamma.r, gain.r, offset.r)
        let g = ch(c.1, lift.g, gamma.g, gain.g, offset.g)
        let b = ch(c.2, lift.b, gamma.b, gain.b, offset.b)
        if saturation == 1 { return (r, g, b) }
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (y + saturation * (r - y), y + saturation * (g - y), y + saturation * (b - y))
    }

    private enum CodingKeys: String, CodingKey { case lift, gamma, gain, offset, contrast, pivot, saturation }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = StepPrimaries()
        lift = try c.decodeIfPresent(ColorTriple.self, forKey: .lift) ?? def.lift
        gamma = try c.decodeIfPresent(ColorTriple.self, forKey: .gamma) ?? def.gamma
        gain = try c.decodeIfPresent(ColorTriple.self, forKey: .gain) ?? def.gain
        offset = try c.decodeIfPresent(ColorTriple.self, forKey: .offset) ?? def.offset
        contrast = try c.decodeIfPresent(Float.self, forKey: .contrast) ?? def.contrast
        pivot = try c.decodeIfPresent(Float.self, forKey: .pivot) ?? def.pivot
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation) ?? def.saturation
    }
}

/// Picks the pixels a Step changes by hue, saturation and luma (the same ranges and soft edge as Color Range).
public struct ColorQualifier: Sendable, Hashable, Codable {
    public var hueCenter: Float = 25        // 0..<360
    public var hueWidth: Float = 50         // 0...360
    public var satMin: Float = 10           // 0...100
    public var satMax: Float = 100
    public var lumMin: Float = 0            // 0...100
    public var lumMax: Float = 100
    public var softness: Float = 20         // 0...100
    public var invert = false
    public init() {}

    /// The same ranges as a Color Range with no correction (the renderer shares its mask).
    public var asColorRange: HSLSecondary {
        var h = HSLSecondary()
        h.hueCenter = hueCenter; h.hueWidth = hueWidth; h.satMin = satMin; h.satMax = satMax
        h.lumMin = lumMin; h.lumMax = lumMax; h.softness = softness; h.invert = invert
        return h.clamped()
    }

    private enum CodingKeys: String, CodingKey { case hueCenter, hueWidth, satMin, satMax, lumMin, lumMax, softness, invert }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = ColorQualifier()
        func f(_ k: CodingKeys, _ v: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? v }
        hueCenter = try f(.hueCenter, def.hueCenter); hueWidth = try f(.hueWidth, def.hueWidth)
        satMin = try f(.satMin, def.satMin); satMax = try f(.satMax, def.satMax)
        lumMin = try f(.lumMin, def.lumMin); lumMax = try f(.lumMax, def.lumMax)
        softness = try f(.softness, def.softness)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// A shape that limits a Step to part of the frame. Positions are in frame units (0...1, y down); width and height are
/// fractions of the frame width / height; softness is the soft edge as a fraction of the shape's size (0...1).
/// Linear: everything on one side of the line through the center (at `rotation`) is in; `width` is the soft band.
public struct StepWindow: Sendable, Hashable, Codable {
    public enum Shape: String, Sendable, Hashable, Codable, CaseIterable { case ellipse, rectangle, linear }
    public var shape: Shape = .ellipse
    public var centerX: Float = 0.5
    public var centerY: Float = 0.5
    public var width: Float = 0.5
    public var height: Float = 0.5
    public var rotation: Float = 0          // degrees, clockwise
    public var softness: Float = 0.2
    public var invert = false
    public init(shape: Shape = .ellipse) { self.shape = shape }

    private enum CodingKeys: String, CodingKey { case shape, centerX, centerY, width, height, rotation, softness, invert }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = StepWindow()
        func f(_ k: CodingKeys, _ v: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? v }
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .ellipse
        centerX = try f(.centerX, def.centerX); centerY = try f(.centerY, def.centerY)
        width = try f(.width, def.width); height = try f(.height, def.height)
        rotation = try f(.rotation, def.rotation); softness = try f(.softness, def.softness)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// A point on the Steps canvas (canvas units, 1 unit = 1 pt at zoom 100%).
public struct StepPosition: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// How a Step joins the Steps before it. A Serial Step starts a new column and works on the column before; a Parallel
/// Step works on the same input as its column's Serial Step and the results are averaged; a Layer Step also works on
/// that input and goes over the averaged result, limited by its key (qualifier / window); without a key it replaces.
public enum StepKind: String, Sendable, Hashable, Codable, CaseIterable { case serial, parallel, layer }

/// How the key wires that arrive at one mixer box combine into one matte (v80). Applied in link order: the first wire sets
/// the matte, each next one is combined with it.
public enum KeyMixMode: String, Sendable, Hashable, Codable, CaseIterable { case add, multiply, subtract, max }

/// Layer mix: how a Layer Step's result composites over what is below it (the average of the column and the Layer Steps before);
/// the Step's key (and Mix) controls the strength. Normal replaces.
public enum LayerMixMode: String, Sendable, Hashable, Codable, CaseIterable { case normal, add, subtract, multiply, screen, lighten, darken }

/// One Step of the Pro grade: primaries, curves, a LUT, limited by an optional qualifier and window.
public struct ColorStep: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var label: String
    public var enabled = true
    public var primaries = StepPrimaries()
    public var curves = RGBCurves()
    public var hueCurves = HueCurves()
    /// A look LUT inside the Step (display signal in and out); nil = none.
    public var lut: LUTRef?
    public var lutIntensity: Float = 100    // 0...100
    /// nil = every pixel.
    public var qualifier: ColorQualifier?
    /// nil = the whole frame.
    public var window: StepWindow?
    /// How the Step joins the Steps before it; the first Step of a graph is always serial.
    public var kind: StepKind = .serial
    /// How much of the Step's result shows: 0...100, a blend of its output with its input.
    public var mix: Float = 100
    /// Where the Step sits on the Steps canvas (top-left corner, canvas units); nil = the automatic layout places it.
    public var position: StepPosition?
    /// Where the mixer box behind this Step's stack sits (only the serial head of a Parallel / Layer stack has one); nil = automatic.
    public var mixerPosition: StepPosition?
    /// v80: how a Layer Step composites over the result below it; ignored for other kinds.
    public var layerMix: LayerMixMode = .normal
    /// v80: the Step's key output is read inverted ("outside": everything the window / qualifier does not select).
    public var keyOutside = false
    /// v80: how the key wires into the mixer box behind this Step's stack combine (only the stack's head); the matte then
    /// limits the whole stack's result.
    public var keyMix: KeyMixMode = .multiply

    public init(id: UUID = UUID(), label: String) { self.id = id; self.label = label }

    /// The Step changes nothing (a qualifier or window alone never changes the picture).
    public var isNeutral: Bool {
        primaries.isNeutral && curves.isNeutral && hueCurves.isNeutral && (lut == nil || lutIntensity <= 0)
    }

    /// The Step's values back to their defaults; id, label and the switch stay.
    public mutating func reset() { self = ColorStep(id: id, label: label).with { $0.enabled = enabled; $0.kind = kind; $0.position = position; $0.mixerPosition = mixerPosition; $0.keyMix = keyMix } }

    private func with(_ f: (inout ColorStep) -> Void) -> ColorStep { var s = self; f(&s); return s }

    private enum CodingKeys: String, CodingKey {
        case id, label, enabled, primaries, curves, hueCurves, lut, lutIntensity, qualifier, window, kind, mix, position, mixerPosition
        case layerMix, keyOutside, keyMix
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Step"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        primaries = try c.decodeIfPresent(StepPrimaries.self, forKey: .primaries) ?? StepPrimaries()
        curves = try c.decodeIfPresent(RGBCurves.self, forKey: .curves) ?? RGBCurves()
        hueCurves = try c.decodeIfPresent(HueCurves.self, forKey: .hueCurves) ?? HueCurves()
        lut = try c.decodeIfPresent(LUTRef.self, forKey: .lut)
        lutIntensity = try c.decodeIfPresent(Float.self, forKey: .lutIntensity) ?? 100
        qualifier = try c.decodeIfPresent(ColorQualifier.self, forKey: .qualifier)
        window = try c.decodeIfPresent(StepWindow.self, forKey: .window)
        kind = try c.decodeIfPresent(StepKind.self, forKey: .kind) ?? .serial
        mix = try c.decodeIfPresent(Float.self, forKey: .mix) ?? 100
        position = try c.decodeIfPresent(StepPosition.self, forKey: .position)
        mixerPosition = try c.decodeIfPresent(StepPosition.self, forKey: .mixerPosition)
        layerMix = try c.decodeIfPresent(LayerMixMode.self, forKey: .layerMix) ?? .normal
        keyOutside = try c.decodeIfPresent(Bool.self, forKey: .keyOutside) ?? false
        keyMix = try c.decodeIfPresent(KeyMixMode.self, forKey: .keyMix) ?? .multiply
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        if !enabled { try c.encode(enabled, forKey: .enabled) }
        if !primaries.isNeutral { try c.encode(primaries, forKey: .primaries) }
        if !curves.isNeutral { try c.encode(curves, forKey: .curves) }
        if !hueCurves.isNeutral { try c.encode(hueCurves, forKey: .hueCurves) }
        try c.encodeIfPresent(lut, forKey: .lut)
        if lutIntensity != 100 { try c.encode(lutIntensity, forKey: .lutIntensity) }
        try c.encodeIfPresent(qualifier, forKey: .qualifier)
        try c.encodeIfPresent(window, forKey: .window)
        if kind != .serial { try c.encode(kind, forKey: .kind) }
        if mix != 100 { try c.encode(mix, forKey: .mix) }
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(mixerPosition, forKey: .mixerPosition)
        if layerMix != .normal { try c.encode(layerMix, forKey: .layerMix) }
        if keyOutside { try c.encode(keyOutside, forKey: .keyOutside) }
        if keyMix != .multiply { try c.encode(keyMix, forKey: .keyMix) }
    }

    /// The file needs v79: a Step that is not serial or not at Mix 100.
    /// The file needs v80: a Layer mix other than Normal, an inverted key, or a non-default key mix.
    var usesV80Fields: Bool { layerMix != .normal || keyOutside || keyMix != .multiply }
    var usesV79Fields: Bool { kind != .serial || mix != 100 || position != nil || mixerPosition != nil }
}

/// The Pro grade: In LUT -> Steps in order -> Out LUT.
public struct ColorGraph: Sendable, Hashable, Codable {
    /// Serial order = processing order; never empty.
    public var steps: [ColorStep] {
        didSet {
            if steps.isEmpty { steps = [ColorStep(label: "Step 1")] }
            else if steps[0].kind != .serial { steps[0].kind = .serial }
        }
    }
    /// The conversion, same rules as Simple's Input LUT (`.automatic` = the camera LUT of S-Log3 media, else built in).
    public var inputLUT: LUTRef?
    /// A last look LUT after every Step; nil = none.
    public var outputLUT: LUTRef?
    public var outputLUTIntensity: Float = 100
    /// Simple | Pro: true = this graph is the clip's grade and the Color effects stay dimmed.
    public var isActive = false
    /// v80: custom image wiring (`ColorGraph+Wiring.swift`); nil = the wires the Step kinds say.
    public internal(set) var links: [GraphLink]?
    /// v80: key wires (key output of a Step into the key input of a Step or mixer). The renderer applies them (`ColorPipeline.graphOps`).
    public internal(set) var keyLinks: [GraphLink] = []

    public init(steps: [ColorStep] = [], inputLUT: LUTRef? = .automatic, outputLUT: LUTRef? = nil) {
        self.steps = steps.isEmpty ? [ColorStep(label: "Step 1")] : steps
        self.inputLUT = inputLUT; self.outputLUT = outputLUT
    }

    /// Every Step (and the Out LUT) changes nothing; the In LUT is the conversion and does not count.
    public var isNeutral: Bool {
        steps.allSatisfy { !$0.enabled || $0.isNeutral } && (outputLUT == nil || outputLUTIntensity <= 0)
    }

    public func step(_ id: UUID) -> ColorStep? { steps.first { $0.id == id } }

    /// Inserts a neutral Step behind `id` (nil or unknown = at the end); returns its id.
    @discardableResult
    public mutating func addStep(after id: UUID?, kind: StepKind = .serial) -> UUID {
        let n = (steps.compactMap { $0.label.hasPrefix("Step ") ? Int($0.label.dropFirst(5)) : nil }.max() ?? 0) + 1
        var s = ColorStep(label: "Step \(n)")
        s.kind = links == nil ? kind : .serial      // custom wiring: a new Step is wired in series
        if var l = links {
            // Behind the box that ends `id`'s column (the mixer of a stack's last Step), on every wire that left it.
            let col = columns.first { c in c.contains { $0.id == id } }
            let anchor: GraphPort = id.map { i in
                if let col, col.count > 1, col.last?.id == i { return .mixer(col[0].id) }
                return .step(i)
            } ?? (l.first { $0.to == .sink }?.from ?? .source)
            let at = (col.flatMap { c in steps.firstIndex { $0.id == c.last?.id } }).map { $0 + 1 } ?? steps.count
            steps.insert(s, at: at)
            let outs = l.filter { $0.from == anchor }.map(\.to)
            l.removeAll { $0.from == anchor }
            l.append(GraphLink(anchor, .step(s.id)))
            for o in outs { l.append(GraphLink(.step(s.id), o)) }
            setImageLinks(l)
            return s.id
        }
        if let id, let i = steps.firstIndex(where: { $0.id == id }) { steps.insert(s, at: i + 1) } else { steps.append(s) }
        return s.id
    }

    /// Removes a Step; the last one is reset instead (a graph always has one).
    public mutating func removeStep(_ id: UUID) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        if steps.count == 1 { steps[0].reset(); return }
        // Custom wiring closes up around the Step (its input goes to what it fed).
        let healed = links.map { detach(id, in: $0) }
        let wasSerial = steps[i].kind == .serial
        steps.remove(at: i)
        // A removed head hands its column to the first follower instead of joining the column before.
        if wasSerial, i < steps.count, steps[i].kind != .serial { steps[i].kind = .serial }
        if let healed { setImageLinks(healed) }
        sanitizeWiring()
    }

    /// The Steps as columns: a serial Step with the Parallel and Layer Steps behind it.
    public var columns: [[ColorStep]] {
        var out: [[ColorStep]] = []
        for s in steps {
            if s.kind == .serial || out.isEmpty { out.append([s]) } else { out[out.count - 1].append(s) }
        }
        return out
    }

    /// The number of columns (Serial Steps).
    public var serialCount: Int { steps.reduce(0) { $0 + ($1.kind == .serial ? 1 : 0) } }

    /// Changes how a Step joins the others; the first Step stays serial.
    public mutating func setKind(_ id: UUID, _ kind: StepKind) {
        links = nil     // the kinds are the wiring again
        update(id) { $0.kind = kind }
        sanitizeWiring()
    }

    /// Renames a Step; blank names are ignored.
    public mutating func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        update(id) { $0.label = n }
    }

    /// Moves a Step to `index` (clamped); a one-Step graph and unknown ids change nothing.
    public mutating func moveStep(_ id: UUID, to index: Int) {
        guard steps.count > 1, let i = steps.firstIndex(where: { $0.id == id }) else { return }
        links = nil
        defer { sanitizeWiring() }
        let s = steps.remove(at: i)
        // A serial head that leaves hands its column to the first follower.
        if s.kind == .serial, i < steps.count, steps[i].kind != .serial { steps[i].kind = .serial }
        steps.insert(s, at: min(max(index, 0), steps.count))
    }

    /// Puts the Step in its own column at `gap` (0 = before the first column, `columns.count` = after the last), counted
    /// without the Step itself. It becomes a serial Step; a column it led goes on with its first follower.
    public mutating func moveToGap(_ id: UUID, gap: Int) {
        guard steps.count > 1, let i = steps.firstIndex(where: { $0.id == id }) else { return }
        links = nil
        defer { sanitizeWiring() }
        var s = steps.remove(at: i)
        if s.kind == .serial, i < steps.count, steps[i].kind != .serial { steps[i].kind = .serial }
        s.kind = .serial
        let cols = columns
        let g = min(max(gap, 0), cols.count)
        steps.insert(s, at: cols.prefix(g).reduce(0) { $0 + $1.count })
    }

    public mutating func setPosition(_ id: UUID, _ p: StepPosition?) { update(id) { $0.position = p } }

    /// Stores where the mixer box of the stack led by `head` sits.
    public mutating func setMixerPosition(_ head: UUID, _ p: StepPosition?) { update(head) { $0.mixerPosition = p } }

    /// The ids of the Steps in the stack led by `head` (head first); just the head when it has no Parallel / Layer Steps.
    public func stack(of head: UUID) -> [UUID] {
        columns.first { $0.first?.id == head }?.map(\.id) ?? []
    }

    /// Deletes the mixer box of the stack led by `head`: its Parallel and Layer Steps become serial Steps in a row, in
    /// their order. False when the Step leads no stack.
    @discardableResult
    public mutating func dissolveMixer(_ head: UUID) -> Bool {
        let ids = stack(of: head)
        guard ids.count > 1 else { return false }
        links = nil
        defer { sanitizeWiring() }
        for id in ids.dropFirst() { update(id) { $0.kind = .serial } }
        update(head) { $0.mixerPosition = nil }
        return true
    }

    /// Wire "output of `source` into the input of `id`": `id` becomes a serial Step right behind the column of `source`
    /// (nil = the graph's input, the front). `source` must end a column: a lone Step or the head of a stack (its mixer).
    /// False (nothing changes) when the wire cannot be expressed: `source` is one branch of a stack, or loops back.
    @discardableResult
    public mutating func follow(_ id: UUID, after source: UUID?) -> Bool {
        guard steps.count > 1, step(id) != nil else { return false }
        links = nil
        defer { sanitizeWiring() }
        var gap = 0
        if let source {
            guard source != id, let col = columns.firstIndex(where: { $0.contains { $0.id == source } }) else { return false }
            let members = columns[col]
            // Only a column's end (its lone Step, or its mixer, named by the head) can feed a Step.
            guard members.count == 1 || members[0].id == source else { return false }
            guard !members.contains(where: { $0.id == id }) else { return false }
            let rest = columns.map { $0.filter { $0.id != id } }.filter { !$0.isEmpty }
            guard let at = rest.firstIndex(where: { $0.contains { $0.id == source } }) else { return false }
            gap = at + 1
        }
        moveToGap(id, gap: gap)
        return true
    }

    /// Wire "output of `id` into the mixer of the stack led by `head`": `id` joins that stack as a Parallel (or Layer) Step
    /// at its end. False when `id` already belongs to the stack or leads it.
    @discardableResult
    public mutating func join(_ id: UUID, stackOf head: UUID, kind: StepKind = .parallel) -> Bool {
        let members = stack(of: head)
        guard members.count > 1, !members.contains(id), let i = steps.firstIndex(where: { $0.id == id }) else { return false }
        links = nil
        defer { sanitizeWiring() }
        var s = steps.remove(at: i)
        if s.kind == .serial, i < steps.count, steps[i].kind != .serial { steps[i].kind = .serial }
        s.kind = kind == .layer ? .layer : .parallel
        let after = members.last!
        guard let at = steps.firstIndex(where: { $0.id == after }) else { steps.append(s); return false }
        steps.insert(s, at: at + 1)
        return true
    }

    /// Forgets every stored position: the automatic layout places all Steps again.
    public mutating func tidyUp() { for i in steps.indices { steps[i].position = nil; steps[i].mixerPosition = nil } }

    public mutating func setEnabled(_ id: UUID, _ on: Bool) { update(id) { $0.enabled = on } }

    /// Edits one Step in place (its id stays).
    public mutating func update(_ id: UUID, _ edit: (inout ColorStep) -> Void) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let keep = steps[i].id
        edit(&steps[i])
        steps[i].id = keep
    }

    /// The graph as rendered with its effect switched off: only the conversion stays.
    public var conversionOnly: ColorGraph {
        var g = ColorGraph(inputLUT: inputLUT)
        g.isActive = isActive
        return g
    }

    private enum CodingKeys: String, CodingKey { case steps, inputLUT, outputLUT, outputLUTIntensity, isActive = "active", links, keyLinks }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let s = try c.decodeIfPresent([ColorStep].self, forKey: .steps) ?? []
        self.init(steps: s, inputLUT: try c.decodeIfPresent(LUTRef.self, forKey: .inputLUT),
                  outputLUT: try c.decodeIfPresent(LUTRef.self, forKey: .outputLUT))
        outputLUTIntensity = try c.decodeIfPresent(Float.self, forKey: .outputLUTIntensity) ?? 100
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        links = try c.decodeIfPresent([GraphLink].self, forKey: .links)
        keyLinks = try c.decodeIfPresent([GraphLink].self, forKey: .keyLinks) ?? []
        sanitizeWiring()
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        try c.encodeIfPresent(inputLUT, forKey: .inputLUT)
        try c.encodeIfPresent(outputLUT, forKey: .outputLUT)
        if outputLUTIntensity != 100 { try c.encode(outputLUTIntensity, forKey: .outputLUTIntensity) }
        if isActive { try c.encode(isActive, forKey: .isActive) }
        try c.encodeIfPresent(links, forKey: .links)
        if !keyLinks.isEmpty { try c.encode(keyLinks, forKey: .keyLinks) }
    }

    /// The file needs v80: custom wiring or a key wire.
    var usesV80Fields: Bool { links != nil || !keyLinks.isEmpty || steps.contains { $0.usesV80Fields } }
}

// MARK: - The effect and the clip

/// Which grade of a clip renders.
public enum ActiveGrade: String, Sendable, Hashable, CaseIterable { case simple, pro }

extension ClipEffect {
    public static let colorGraphKind = "colorGraph"
    public var isColorGraph: Bool { kind == Self.colorGraphKind }

    /// A new Color Graph effect holding `graph`.
    public static func colorGraph(_ graph: ColorGraph) -> ClipEffect {
        var e = ClipEffect(kind: colorGraphKind)
        e.colorGraph = graph
        return e
    }

    /// The catalog entry: no sliders, the graph is edited in the Color panel (Adjust).
    static let colorGraphSpec = EffectSpec(kind: colorGraphKind, title: "Color Graph", params: [])
}

extension Clip {
    /// Index of the clip's Color Graph effect (the first one; a clip holds at most one).
    public var colorGraphIndex: Int? { effects.firstIndex(where: \.isColorGraph) }

    /// The Pro grade, nil when the clip has none. Setting nil removes the effect; setting a graph on a clip without
    /// one adds the effect behind the Color effects.
    public var colorGraph: ColorGraph? {
        get { colorGraphIndex.flatMap { effects[$0].colorGraph ?? ColorGraph() } }
        set {
            switch (colorGraphIndex, newValue) {
            case (let i?, let g?): effects[i].colorGraph = g
            case (let i?, nil): effects.remove(at: i)
            case (nil, let g?):
                guard acceptsColor else { return }
                let at = (colorEffectIndices.last.map { $0 + 1 }) ?? 0
                effects.insert(.colorGraph(g), at: at)
            case (nil, nil): break
            }
        }
    }

    /// Paste of a copied grade: the copied graph replaces the clip's (Pro active when it was), so the clip looks like
    /// the copy. A Simple copy (no graph) turns an existing graph off and keeps its values.
    public mutating func applyCopiedGraph(_ g: ColorGraph?) {
        if let g { colorGraph = g; return }
        guard var cur = colorGraph, cur.isActive else { return }
        cur.isActive = false
        colorGraph = cur
    }

    /// Simple | Pro.
    public var activeGrade: ActiveGrade { colorGraph?.isActive == true ? .pro : .simple }

    /// Makes one grade the clip's grade; the other keeps its values. Pro on a clip without a graph adds one.
    public mutating func setActiveGrade(_ m: ActiveGrade) {
        var g = colorGraph ?? (m == .pro ? ColorGraph() : nil)
        g?.isActive = m == .pro
        if g != nil { colorGraph = g }
    }

    /// The graph `renderColor` uses: nil while Simple is active; with the effect switched off, the conversion only.
    var renderGraph: ColorGraph? {
        guard let i = colorGraphIndex, let g = effects[i].colorGraph, g.isActive else { return nil }
        return effects[i].enabled ? g : g.conversionOnly
    }
}
