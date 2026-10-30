import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit

/// What a press on the trim bar asks for.
public enum TrimBarAction: Equatable, Sendable {
    case side(TrimSide)
    case step(Int)
    case done
}

/// Trim mode's controls on the shared toolkit, translated from the Mac `TrimMonitorView` control row (52 pt): the side
/// switch Before / After / Both on the left, -5 -1 +1 +5 centered, the result note and Done on the right. The host
/// shows it while `TrimModeModel.isActive` and passes the actions to the model.
public struct TrimBar: Sendable {
    public var theme: DrawTheme
    public private(set) var side: TrimSide = .roll
    public private(set) var sides: Set<TrimSide> = []
    public private(set) var note = ""
    /// The bar in window points.
    public private(set) var frame = CGRect.zero
    public private(set) var scale: Float = 1
    private var hovered: Part?
    private var pressed: Part?

    public static let height: CGFloat = 52
    static let segmentWidth: CGFloat = 58
    static let stepWidth: CGFloat = 40
    /// `TrimModeModel.steps` (main-actor bound there, the bar lays out anywhere).
    static let steps = [-5, -1, 1, 5]
    static let sideOrder: [(TrimSide, String)] = [(.outgoing, "Before"), (.incoming, "After"), (.roll, "Both")]

    enum Part: Hashable { case side(TrimSide), step(Int), done }

    public init(theme: DrawTheme = DrawTheme()) { self.theme = theme }

    /// Reads the side, the sides the edit has and the note from the model.
    @MainActor public mutating func update(from m: TrimModeModel) {
        side = m.side
        sides = Set(TrimSide.allCases.filter { m.point?.supports($0) == true })
        note = m.note
    }

    /// The bar fills `rect` (window points).
    public mutating func layout(in rect: CGRect, scale s: Float) {
        frame = rect
        scale = s
    }

    func rects() -> [(Part, CGRect)] {
        let gap = CGFloat(DrawTheme.Spacing.sm), xs = CGFloat(DrawTheme.Spacing.xs)
        let h = CGFloat(DrawTheme.Metrics.panelHeader) - 6, y = frame.minY + ((frame.height - h) / 2).rounded()
        var out: [(Part, CGRect)] = []
        for (i, s) in Self.sideOrder.enumerated() {
            out.append((.side(s.0), CGRect(x: frame.minX + gap + CGFloat(i) * Self.segmentWidth, y: y, width: Self.segmentWidth, height: h)))
        }
        let steps = Self.steps
        let rowW = CGFloat(steps.count) * Self.stepWidth + CGFloat(steps.count - 1) * xs
        var x = (frame.midX - rowW / 2).rounded()
        for n in steps {
            out.append((.step(n), CGRect(x: x, y: y, width: Self.stepWidth, height: h)))
            x += Self.stepWidth + xs
        }
        out.append((.done, CGRect(x: frame.maxX - gap - Self.doneWidth, y: y, width: Self.doneWidth, height: h)))
        return out
    }

    static let doneWidth: CGFloat = 56

    var noteRect: CGRect {
        let steps = CGFloat(Self.steps.count)
        let rowW = steps * Self.stepWidth + (steps - 1) * CGFloat(DrawTheme.Spacing.xs)
        let x = frame.midX + rowW / 2 + CGFloat(DrawTheme.Spacing.sm)
        let right = frame.maxX - CGFloat(DrawTheme.Spacing.sm) * 2 - Self.doneWidth
        return CGRect(x: x, y: frame.minY, width: max(right - x, 0), height: frame.height)
    }

    func part(at p: CGPoint) -> Part? {
        rects().first { $0.1.contains(p) }?.0
    }

    func isEnabled(_ part: Part) -> Bool {
        if case .side(let s) = part { return sides.contains(s) }
        return true
    }

    public func contains(x: Float, y: Float) -> Bool {
        frame.contains(CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)))
    }

    /// Presses on the bar; nil = not the bar's (pointer moves always go on).
    public mutating func handle(_ e: InputEvent) -> [TrimBarAction]? {
        let k = CGFloat(max(scale, 0.01))
        switch e {
        case .mouseDown(let x, let y, _):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            guard frame.contains(p) else { return nil }
            pressed = part(at: p).flatMap { isEnabled($0) ? $0 : nil }
            return []
        case .mouseDragged(let x, let y):
            guard pressed != nil else { return nil }
            hovered = part(at: CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
            return []
        case .mouseUp(let x, let y):
            guard let was = pressed else { return nil }
            pressed = nil
            guard part(at: CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) == was else { return [] }
            switch was {
            case .side(let s): return [.side(s)]
            case .step(let n): return [.step(n)]
            case .done: return [.done]
            }
        case .mouseMoved(let x, let y):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            hovered = frame.contains(p) ? part(at: p) : nil
            return nil
        default:
            return nil
        }
    }

    public func draw(_ c: inout Canvas) {
        guard frame.width > 0 else { return }
        c.fill(frame, theme.panel)
        c.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1), theme.separator)
        for (part, r) in rects() {
            let title: String
            var accent = false
            switch part {
            case .side(let s):
                title = Self.sideOrder.first { $0.0 == s }?.1 ?? ""
                accent = s == side
            case .step(let n): title = n > 0 ? "+\(n)" : "\(n)"
            case .done: title = "Done"
            }
            InspectorDraw.button(&c, title: SQL10n.string(title), in: r, hovering: hovered == part, pressed: pressed == part,
                                 enabled: isEnabled(part), accent: accent, theme)
        }
        if !note.isEmpty {
            c.draw(SQL10n.string(note), in: noteRect, fontSize: CGFloat(DrawTheme.TypeSize.body), theme.label2)
        }
    }
}

extension TrimBar {
    /// The edit and the trimmed side as the timeline's edge selection (the Mac `syncTrimMode`): the outgoing tail, the
    /// incoming head, or both for a roll; a side trim ripples. nil when the edit lacks that side.
    public static func edges(for p: TrimPoint, side: TrimSide) -> EdgeSelection? {
        var edges: [EdgeRef] = []
        switch side {
        case .outgoing: if let o = p.outgoing { edges = [EdgeRef(clip: o, edge: .tail)] }
        case .incoming: if let i = p.incoming { edges = [EdgeRef(clip: i, edge: .head)] }
        case .roll: if let o = p.outgoing, let i = p.incoming { edges = [EdgeRef(clip: o, edge: .tail), EdgeRef(clip: i, edge: .head)] }
        }
        return edges.isEmpty ? nil : EdgeSelection(edges: edges, ripple: side != .roll)
    }
}

extension TimelinePanel {
    /// Shows `e` as the selected edges (Trim mode keeps its edit selected this way).
    public mutating func selectEdges(_ e: EdgeSelection?) { interaction.setEdgeSelection(e) }
}
