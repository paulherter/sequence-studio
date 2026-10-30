import Foundation

// The layer list on the Color Pro page: the Steps as rows, topmost row = last Step. It only reads and writes fields that
// exist since v79 / v80 (`kind`, `mix`, `layerMix`), so it needs no ProjectFile version of its own.

/// How a row of the layer list joins the rows below it.
public enum StepBlend: Sendable, Hashable {
    /// A Serial Step: it works on the result below.
    case series
    /// A Parallel Step: the result is averaged with the Steps of its column.
    case parallel
    /// A Layer Step composited with this mode.
    case layer(LayerMixMode)

    /// Menu order: the two plain ways first, then every layer mode.
    public static let all: [StepBlend] = [.series, .parallel] + LayerMixMode.allCases.map { .layer($0) }
}

extension ColorGraph {
    /// The Steps in list order: the topmost layer (the last Step) first.
    public var listSteps: [ColorStep] { steps.reversed() }

    /// The list edits Steps through their kinds, which is only possible while no custom wiring says otherwise.
    public var allowsListEdit: Bool { links == nil }

    public func blend(of id: UUID) -> StepBlend? {
        guard let s = step(id) else { return nil }
        switch s.kind {
        case .serial: return .series
        case .parallel: return .parallel
        case .layer: return .layer(s.layerMix)
        }
    }

    /// Sets how a Step joins the rows below. false (nothing changed) for the base row (the first Step is always serial),
    /// an unknown id and a graph with custom wiring.
    @discardableResult
    public mutating func setBlend(_ id: UUID, _ blend: StepBlend) -> Bool {
        guard allowsListEdit, let i = steps.firstIndex(where: { $0.id == id }), i > 0 else { return false }
        let kind: StepKind, mode: LayerMixMode
        switch blend {
        case .series: kind = .serial; mode = .normal
        case .parallel: kind = .parallel; mode = .normal
        case .layer(let m): kind = .layer; mode = m
        }
        setKind(id, kind)
        update(id) { $0.layerMix = mode }
        return true
    }

    /// Moves a Step to list row `row` (0 = top, clamped).
    public mutating func moveStep(_ id: UUID, toListRow row: Int) {
        moveStep(id, to: steps.count - 1 - min(max(row, 0), steps.count - 1))
    }
}
