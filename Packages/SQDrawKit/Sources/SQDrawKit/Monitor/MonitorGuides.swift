import Foundation

/// User guides of the Program monitor: vertical positions are fractions of the picture width, horizontal ones of its
/// height (0...1, origin top-left). Guides belong to the monitor session, not to the project.
public struct MonitorGuides: Sendable, Equatable {
    public enum Axis: Sendable { case vertical, horizontal }
    public struct Guide: Sendable, Equatable { public var axis: Axis; public var fraction: Double }

    public private(set) var vertical: [Double] = []
    public private(set) var horizontal: [Double] = []

    public init() {}

    public var isEmpty: Bool { vertical.isEmpty && horizontal.isEmpty }
    public var all: [Guide] {
        vertical.map { Guide(axis: .vertical, fraction: $0) } + horizontal.map { Guide(axis: .horizontal, fraction: $0) }
    }

    /// Adds a guide (clamped into the picture) and returns its index within its axis.
    @discardableResult
    public mutating func add(_ axis: Axis, at fraction: Double) -> Int {
        let f = min(max(fraction, 0), 1)
        switch axis {
        case .vertical: vertical.append(f); return vertical.count - 1
        case .horizontal: horizontal.append(f); return horizontal.count - 1
        }
    }

    public mutating func move(_ axis: Axis, index: Int, to fraction: Double) {
        let f = min(max(fraction, 0), 1)
        switch axis {
        case .vertical: if vertical.indices.contains(index) { vertical[index] = f }
        case .horizontal: if horizontal.indices.contains(index) { horizontal[index] = f }
        }
    }

    public mutating func remove(_ axis: Axis, index: Int) {
        switch axis {
        case .vertical: if vertical.indices.contains(index) { vertical.remove(at: index) }
        case .horizontal: if horizontal.indices.contains(index) { horizontal.remove(at: index) }
        }
    }

    public mutating func clear() { vertical = []; horizontal = [] }

    /// The guide nearest to `fraction` on `axis` within `tolerance` (fractions), or nil.
    public func nearest(_ axis: Axis, to fraction: Double, tolerance: Double) -> Int? {
        let list = axis == .vertical ? vertical : horizontal
        var best: (Int, Double)?
        for (i, g) in list.enumerated() {
            let d = abs(g - fraction)
            if d <= tolerance, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// Snaps `fraction` to a guide on `axis` within `tolerance`; unchanged when none is near.
    public func snapped(_ axis: Axis, _ fraction: Double, tolerance: Double) -> Double {
        guard let i = nearest(axis, to: fraction, tolerance: tolerance) else { return fraction }
        return axis == .vertical ? vertical[i] : horizontal[i]
    }

    /// Ruler tick spacing (fraction of the picture) with major ticks every 10 %, minor every 5 % (always the same
    /// scale: the ruler reads in percent of the frame, independent of the sequence size).
    public static let majorStep = 0.1
    public static let minorStep = 0.05
}
