import Foundation

// Explicit wiring of the Steps graph (v80). The Step kinds (serial, parallel, layer) describe the topology the renderer
// understands: columns. The Steps canvas edits wires, which can say more (a Step with no input, one output feeding two
// Steps, a Step in a branch). `ColorGraph.links` holds such custom wiring; it is nil while the wiring is exactly what the
// kinds say. Every wire edit is compiled back into kinds when it can be (so the picture follows the wiring); when it
// cannot, the wires are kept as drawn and `isWiringApplied` is false (the renderer still follows the Step order).
// Key wires (`keyLinks`) are stored the same way; the renderer applies them (`keyDonors`): a Step's key limits the Step it
// feeds, the keys into a mixer box combine by the head's `keyMix` and limit the whole stack.

/// Where a wire starts or ends: the graph's source or sink, a Step (image or key dot, the link says which), or the mixer box
/// of a stack (named by the stack's first Step).
public enum GraphPort: Hashable, Sendable, Codable {
    case source, sink, step(UUID), mixer(UUID)

    public var stepID: UUID? { if case .step(let i) = self { return i } else { return nil } }
    public var isMixer: Bool { if case .mixer = self { return true } else { return false } }

    private var text: String {
        switch self {
        case .source: "source"
        case .sink: "sink"
        case .step(let i): "step:" + i.uuidString
        case .mixer(let i): "mixer:" + i.uuidString
        }
    }
    public init(from d: Decoder) throws {
        let s = try d.singleValueContainer().decode(String.self)
        if s == "source" { self = .source; return }
        if s == "sink" { self = .sink; return }
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad port \(s)"))
        }
        switch parts[0] {
        case "step": self = .step(id)
        case "mixer": self = .mixer(id)
        default: throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad port \(s)"))
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        try c.encode(text)
    }
}

/// A wire: the output of `from` into the input of `to` (an image wire), or the key output of a Step into the key input of a
/// Step or mixer (a key wire).
public struct GraphLink: Hashable, Sendable, Codable {
    public var from: GraphPort
    public var to: GraphPort
    public init(_ from: GraphPort, _ to: GraphPort) { self.from = from; self.to = to }
}

/// Why a wire cannot be made.
public enum LinkRefusal: Sendable, Equatable {
    /// The start is not an output (the graph's sink).
    case notAnOutput
    /// The end is not an input (the graph's source).
    case notAnInput
    case sameBox
    case unknownBox
    /// The wire would loop back into its own start.
    case cycle
    /// The wire is already there.
    case duplicate
    /// A key wire needs a Step's key output and a Step's or mixer's key input.
    case notAKeyEnd
}

extension ColorGraph {
    /// The head Steps of the stacks that have a mixer box.
    public var mixerHeads: [UUID] { columns.compactMap { $0.count > 1 ? $0[0].id : nil } }

    /// The wires the Step kinds say: one column after the other, a stack ending in its mixer.
    public static func derivedLinks(columns: [[UUID]]) -> [GraphLink] {
        var out: [GraphLink] = []
        var src = GraphPort.source
        for col in columns where !col.isEmpty {
            if col.count > 1 {
                for id in col { out.append(GraphLink(src, .step(id))); out.append(GraphLink(.step(id), .mixer(col[0]))) }
                src = .mixer(col[0])
            } else {
                out.append(GraphLink(src, .step(col[0])))
                src = .step(col[0])
            }
        }
        out.append(GraphLink(src, .sink))
        return out
    }

    /// Every image wire: the stored custom wiring, else the wires of the Step kinds.
    public var imageLinks: [GraphLink] { links ?? Self.derivedLinks(columns: columns.map { $0.map(\.id) }) }

    /// The wiring is not what the Step kinds say; the picture follows the Step order, not these wires.
    public var hasCustomWiring: Bool { links != nil }

    /// False while custom wiring exists that the renderer does not apply (key wires are applied).
    public var isWiringApplied: Bool { links == nil }

    /// The enabled Steps whose key output feeds the key input of `port`, in wire order.
    public func keyDonors(_ port: GraphPort) -> [ColorStep] {
        // A plain loop: Swift 6.3.3 on Windows crashed in the release optimizer (SILCombine) on the
        // filter/compactMap(flatMap(step))/filter(\.enabled) chain that stood here.
        var donors: [ColorStep] = []
        for link in keyLinks where link.to == port {
            guard let id = link.from.stepID, let donor = step(id), donor.enabled else { continue }
            donors.append(donor)
        }
        return donors
    }

    /// A key wire touches this Step (its key output or input).
    public func usesKeyLink(_ id: UUID) -> Bool {
        keyLinks.contains { $0.from == .step(id) || $0.to == .step(id) }
    }

    func exists(_ p: GraphPort) -> Bool {
        switch p {
        case .source, .sink: true
        case .step(let i): step(i) != nil
        case .mixer(let h): mixerHeads.contains(h)
        }
    }

    // MARK: Checking a wire

    /// Why the image wire `from` -> `to` is refused; nil = fine.
    public func refusal(from: GraphPort, to: GraphPort) -> LinkRefusal? {
        if from == .sink { return .notAnOutput }
        if to == .source { return .notAnInput }
        guard exists(from), exists(to) else { return .unknownBox }
        if from == to { return .sameBox }
        if imageLinks.contains(GraphLink(from, to)) { return .duplicate }
        if reaches(to, from) { return .cycle }
        return nil
    }

    /// Why the key wire from the key output of Step `from` into the key input of `to` is refused; nil = fine.
    public func keyRefusal(from: UUID, to: GraphPort) -> LinkRefusal? {
        guard step(from) != nil else { return .unknownBox }
        switch to {
        case .step, .mixer: break
        case .source, .sink: return .notAKeyEnd
        }
        guard exists(to) else { return .unknownBox }
        if to == .step(from) { return .sameBox }
        if keyLinks.contains(GraphLink(.step(from), to)) { return .duplicate }
        if reaches(to, .step(from)) { return .cycle }
        return nil
    }

    /// `b` can be reached from `a` along image and key wires.
    private func reaches(_ a: GraphPort, _ b: GraphPort) -> Bool {
        let all = imageLinks + keyLinks
        var seen: Set<GraphPort> = [a]
        var todo = [a]
        while let p = todo.popLast() {
            if p == b { return true }
            for l in all where l.from == p && !seen.contains(l.to) { seen.insert(l.to); todo.append(l.to) }
        }
        return false
    }

    // MARK: Editing wires

    /// Wires the output of `from` into the input of `to`. A Step's or the sink's input holds one wire (a new one replaces
    /// it); a mixer takes any number; an output feeds any number. Returns why it was refused, nil when done.
    @discardableResult
    public mutating func connect(_ from: GraphPort, to: GraphPort) -> LinkRefusal? {
        if let r = refusal(from: from, to: to) { return r }
        var l = imageLinks
        if !to.isMixer { l.removeAll { $0.to == to } }
        l.append(GraphLink(from, to))
        setImageLinks(l)
        return nil
    }

    /// Takes one wire away. A Step left without an input or output stays where it is.
    public mutating func disconnect(_ link: GraphLink) {
        var l = imageLinks
        guard l.contains(link) else { return }
        l.removeAll { $0 == link }
        setImageLinks(l)
    }

    /// Wires the key output of Step `from` into the key input of a Step or mixer. A Step's key input holds one wire.
    @discardableResult
    public mutating func connectKey(from: UUID, to: GraphPort) -> LinkRefusal? {
        if let r = keyRefusal(from: from, to: to) { return r }
        if !to.isMixer { keyLinks.removeAll { $0.to == to } }
        keyLinks.append(GraphLink(.step(from), to))
        return nil
    }

    public mutating func disconnectKey(_ link: GraphLink) { keyLinks.removeAll { $0 == link } }

    /// Moves Step `id` onto the image wire `link`: it leaves its place (the wires around it close up) and sits between the
    /// ends of the wire. False when the wire does not exist or belongs to the Step.
    @discardableResult
    public mutating func insert(_ id: UUID, onto link: GraphLink) -> Bool {
        guard step(id) != nil, imageLinks.contains(link), link.from != .step(id), link.to != .step(id) else { return false }
        var l = detach(id, in: imageLinks)
        guard l.contains(link) else { return false }
        l.removeAll { $0 == link }
        if !link.to.isMixer { l.removeAll { $0.to == link.to } }
        l.append(GraphLink(link.from, .step(id)))
        l.append(GraphLink(.step(id), link.to))
        setImageLinks(l)
        return true
    }

    /// Lifts the Step out of the chain: the wires around it close up and the Step stays unwired (custom wiring; the
    /// renderer still runs it in its order, which the page says). False for a graph with one Step.
    @discardableResult
    public mutating func extract(_ id: UUID) -> Bool {
        guard steps.count > 1, step(id) != nil else { return false }
        setImageLinks(detach(id, in: imageLinks))
        return true
    }

    /// Takes the Step out of its place in the kinds (it becomes a serial Step) and closes the wires around it; the Step is
    /// then wired to nothing. Mixer boxes follow their stack's head.
    mutating func detach(_ id: UUID, in links: [GraphLink]) -> [GraphLink] {
        var l = links
        let n = GraphPort.step(id)
        let ins = l.filter { $0.to == n }.map(\.from)
        let outs = l.filter { $0.from == n }.map(\.to)
        l.removeAll { $0.from == n || $0.to == n }
        if let s = ins.first { for o in outs where !o.isMixer { l.removeAll { $0.to == o }; l.append(GraphLink(s, o)) } }
        if let i = steps.firstIndex(where: { $0.id == id }) {
            if steps[i].kind == .serial, i + 1 < steps.count, steps[i + 1].kind != .serial {
                let new = steps[i + 1].id
                l = l.map { GraphLink($0.from == .mixer(id) ? .mixer(new) : $0.from, $0.to == .mixer(id) ? .mixer(new) : $0.to) }
                steps[i + 1].kind = .serial
                steps[i + 1].mixerPosition = steps[i].mixerPosition
            }
            steps[i].kind = .serial
            steps[i].mixerPosition = nil
        }
        return pruned(l)
    }

    /// Drops wires of boxes that are gone; a vanished mixer (its stack shrank to one Step) closes up.
    func pruned(_ links: [GraphLink]) -> [GraphLink] {
        func alive(_ p: GraphPort) -> Bool { p.stepID.map { step($0) != nil } ?? true }
        var l = links.filter { alive($0.from) && alive($0.to) }
        let heads = Set(mixerHeads)
        var gone: [GraphPort] = []
        for p in l.flatMap({ [$0.from, $0.to] }) {
            if case .mixer(let h) = p, !heads.contains(h), !gone.contains(p) { gone.append(p) }
        }
        for m in gone {
            let ins = l.filter { $0.to == m }.map(\.from)
            let outs = l.filter { $0.from == m }.map(\.to)
            l.removeAll { $0.from == m || $0.to == m }
            if ins.count == 1 {
                for o in outs { if !o.isMixer { l.removeAll { $0.to == o } }; l.append(GraphLink(ins[0], o)) }
            }
        }
        return l
    }

    /// Stores the wires: compiled back into Step kinds when they say a column graph, kept as custom wiring otherwise.
    mutating func setImageLinks(_ links: [GraphLink]) {
        let l = pruned(links)
        if let c = compile(l) {
            applyCompiled(c)
            self.links = nil
        } else {
            self.links = l == Self.derivedLinks(columns: columns.map { $0.map(\.id) }) ? nil : l
        }
    }

    /// Cleans wires of boxes that no longer exist (after a Step was removed or the kinds changed).
    mutating func sanitizeWiring() {
        if let l = links { setImageLinks(l) }
        let snapshot = self
        keyLinks.removeAll { l in
            guard let from = l.from.stepID, snapshot.step(from) != nil else { return true }
            return !snapshot.exists(l.to)
        }
    }

    struct Compiled { var order: [UUID]; var kinds: [UUID: StepKind]; var mixers: [(old: UUID, head: UUID)] }

    /// The Step order and kinds for wires that say a column graph: the source feeds one Step, or several Steps that all end
    /// in one mixer; and so on to the sink, every wire used once. nil for anything else.
    func compile(_ l: [GraphLink]) -> Compiled? {
        func into(_ p: GraphPort) -> [GraphLink] { l.filter { $0.to == p } }
        var cur = GraphPort.source
        var order: [UUID] = []
        var kinds: [UUID: StepKind] = [:]
        var mixers: [(old: UUID, head: UUID)] = []
        var used = 0
        while true {
            let outs = l.filter { $0.from == cur }
            if outs.count == 1, outs[0].to == .sink {
                used += 1
                guard into(.sink).count == 1 else { return nil }
                break
            }
            let targets = outs.map(\.to)
            if targets.count == 1, case .step(let s) = targets[0] {
                guard step(s) != nil, !order.contains(s), into(.step(s)).count == 1,
                      !l.contains(where: { $0.from == .step(s) && $0.to.isMixer }) else { return nil }
                order.append(s); kinds[s] = .serial; used += 1; cur = .step(s)
            } else if targets.count >= 2 {
                let ids = targets.compactMap(\.stepID)
                guard ids.count == targets.count, Set(ids).count == ids.count,
                      ids.allSatisfy({ step($0) != nil && !order.contains($0) }) else { return nil }
                var mixer: GraphPort?
                for id in ids {
                    let o = l.filter { $0.from == .step(id) }
                    guard into(.step(id)).count == 1, o.count == 1, o[0].to.isMixer, mixer == nil || mixer == o[0].to else { return nil }
                    mixer = o[0].to
                }
                guard case .mixer(let m)? = mixer, into(.mixer(m)).count == ids.count else { return nil }
                let members = into(.mixer(m)).compactMap(\.from.stepID)
                guard Set(members) == Set(ids) else { return nil }
                for (i, id) in members.enumerated() {
                    let old = step(id)?.kind ?? .serial
                    kinds[id] = i == 0 ? .serial : (old == .layer ? .layer : .parallel)
                }
                order += members
                mixers.append((m, members[0]))
                used += 2 * ids.count
                cur = .mixer(m)
            } else { return nil }
        }
        guard used == l.count, order.count == steps.count else { return nil }
        return Compiled(order: order, kinds: kinds, mixers: mixers)
    }

    private mutating func applyCompiled(_ c: Compiled) {
        let oldPos = Dictionary(uniqueKeysWithValues: steps.compactMap { s in s.mixerPosition.map { (s.id, $0) } })
        var byID = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        var out: [ColorStep] = []
        for id in c.order {
            if var s = byID.removeValue(forKey: id) { s.kind = c.kinds[id] ?? .serial; s.mixerPosition = nil; out.append(s) }
        }
        steps = out
        for m in c.mixers { if let p = oldPos[m.old] ?? oldPos[m.head] { setMixerPosition(m.head, p) } }
    }
}
