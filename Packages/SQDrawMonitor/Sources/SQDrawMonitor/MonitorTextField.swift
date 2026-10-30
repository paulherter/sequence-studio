import Foundation
import SQCore
import SQDrawKit
import SQEditorSession

/// The Program monitor's on-canvas text field (the Mac ProgramSurfaceView text editor, `beginTextEditing`): typed
/// text goes to the layer at once (the composite draws it), the field draws the layer's frame, the selection and the
/// caret over it. Return breaks the line, Esc or a click outside ends the edit, Ctrl+B / Ctrl+I toggle bold / italic.
/// The host maps the text style to plain values (SQDrawMonitor does not see SQText) and gives the caret positions of the
/// drawn glyphs (`caretSource`, the portable raster's caret map); without it the UI font's advances stand in.
/// shortcut: the stand-in carets are the UI font's advances scaled to the layer and do not wrap area text; hosts with a
/// text layout set `caretSource`.
@MainActor
public final class MonitorTextField {
    public enum StyleToggle: Sendable, Equatable { case bold, italic }

    public private(set) var edit: TextEditState?
    /// The layer the field sits on (its drawn transform), the sequence size and the style values the caret needs.
    public private(set) var target: OverlayTarget?
    public var sequenceSize = CGSize(width: 1920, height: 1080)
    /// Font size in sequence px, horizontal alignment (0 left, 0.5 center, 1 right), area text (a box: lines start at
    /// its top) and the extra line spacing in px.
    public var fontSize: Double = 100
    public var alignment: CGFloat = 0.5
    public var isBox = false
    public var lineSpacing: Double = 0

    /// The caret map of a text as the picture draws it: layer px from the frame's top-left (the layer's unscaled size).
    public var caretSource: ((String) -> Carets?)?

    public var onEdited: ((String) -> Void)?
    public var onEnded: ((String) -> Void)?
    public var onStyleToggle: ((StyleToggle) -> Void)?

    /// The stand-in carets of the last draw (the canvas measures the UI font only while drawing); a press reads them.
    private var drawnCarets: Carets?

    public init() {}

    public var isEditing: Bool { edit != nil }
    public var text: String { edit?.string ?? "" }

    /// Opens the field on `target` with `text`; `selectAll` for a new layer (typing replaces "Text"). `caretAt` (sequence
    /// px from the canvas center, the click that opened it) puts the caret at the nearest character, else it goes to the end.
    public func begin(text: String, target: OverlayTarget, selectAll: Bool, caretAt: Vec2? = nil) {
        var e = TextEditState(text, selectAll: selectAll)
        self.target = target
        drawnCarets = nil
        if !selectAll, let p = caretAt {
            // The frame in sequence px (one view point per px), so the click maps before anything is drawn.
            let r = CGRect(origin: .zero, size: sequenceSize)
            let view = CGPoint(x: r.midX + CGFloat(p.x), y: r.midY + CGFloat(p.y))
            if let f = frame(quad(canvasRect: r)) {
                e.place(carets(f, text: text).index(at: local(view, f)))
            }
        }
        edit = e
    }

    /// The layer moved or resized (style edits, playhead): the field follows.
    public func retarget(_ t: OverlayTarget) { if isEditing { target = t } }

    /// Ends the edit once (Esc, a click outside, the host closing it) and reports the final text.
    public func end() {
        guard let e = edit else { return }
        edit = nil
        target = nil
        drawnCarets = nil
        onEnded?(e.string)
    }

    /// A key while editing; true when the field took it (every key does, so shortcuts do not run under the caret).
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard var e = edit else { return false }
        if modifiers.contains(.command), case .character(let c) = k {
            switch c.lowercased() {
            case "b": onStyleToggle?(.bold); return true
            case "i": onStyleToggle?(.italic); return true
            default: break
            }
        }
        if k == .escape { end(); return true }
        let outcome = e.handleLines(k, modifiers: modifiers)
        edit = e
        if outcome == .edited { onEdited?(e.string) }
        return true
    }

    // MARK: Geometry

    /// The layer's corners in view points (top-left, top-right, bottom-right, bottom-left) inside `canvasRect`.
    public func quad(canvasRect r: CGRect) -> [CGPoint] {
        guard let t = target else { return [] }
        let aspect = t.size.height > 0 ? Double(t.size.width / t.size.height) : 16.0 / 9
        return TransformOverlayGeometry(sequenceSize: sequenceSize, viewRect: r, mediaAspect: aspect,
                                        transform: t.displayTransform, mediaPixelSize: t.size).quad
    }

    /// Caret placement in the layer's frame (x right, y down from its top-left corner): the lines' tops and heights and
    /// one caret per character boundary of the text (`count + 1`; caret `i` sits before character `i`).
    public struct Carets: Sendable, Equatable {
        public struct Line: Sendable, Equatable {
            public var top: CGFloat, height: CGFloat
            public init(top: CGFloat, height: CGFloat) { self.top = top; self.height = height }
        }
        public struct Caret: Sendable, Equatable {
            public var line: Int, x: CGFloat
            public init(line: Int, x: CGFloat) { self.line = line; self.x = x }
        }
        public var lines: [Line]
        public var carets: [Caret]
        public init(lines: [Line], carets: [Caret]) { self.lines = lines; self.carets = carets }

        /// Layer px to view points (`sx` across, `sy` down).
        func scaled(_ sx: CGFloat, _ sy: CGFloat) -> Carets {
            Carets(lines: lines.map { Line(top: $0.top * sy, height: $0.height * sy) },
                   carets: carets.map { Caret(line: $0.line, x: $0.x * sx) })
        }

        /// The caret nearest to `p`: the line under it (clamped to the first / last), then the nearest caret on that line.
        public func index(at p: CGPoint) -> Int {
            guard !lines.isEmpty, !carets.isEmpty else { return 0 }
            let row = lines.lastIndex { $0.top <= p.y } ?? 0
            let onRow = carets.indices.filter { carets[$0].line == row }
            return onRow.min { abs(carets[$0].x - p.x) < abs(carets[$1].x - p.x) } ?? (p.y < lines[0].top ? 0 : carets.count - 1)
        }
    }

    /// The stand-in carets from the UI font: lines in a frame `size` view points large; `measure` gives the width of a
    /// string at the canvas's UI font; `viewPerPixel` converts sequence px to view points.
    public func layout(size: CGSize, viewPerPixel: CGFloat, measure: (String) -> CGFloat) -> Carets {
        Self.standIn(text, size: size, viewPerPixel: viewPerPixel, fontSize: fontSize, lineSpacing: lineSpacing,
                     alignment: alignment, isBox: isBox, measure: measure)
    }

    static func standIn(_ text: String, size: CGSize, viewPerPixel: CGFloat, fontSize: Double, lineSpacing: Double,
                        alignment: CGFloat, isBox: Bool, measure: (String) -> CGFloat) -> Carets {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fontView = CGFloat(fontSize) * viewPerPixel
        let lh = max(1, fontView * 1.2 + CGFloat(lineSpacing) * viewPerPixel)
        let ref = max(measure("M"), 0.001)
        let k = fontView * 0.8 / ref                             // the UI font's em scaled to the layer's
        let top = isBox ? 0 : (size.height - lh * CGFloat(lines.count)) / 2
        var outLines: [Carets.Line] = [], carets: [Carets.Caret] = []
        for (i, line) in lines.enumerated() {
            var xs: [CGFloat] = [0]
            var prefix = ""
            for ch in line { prefix.append(ch); xs.append(measure(prefix) * k) }
            let left = (size.width - (xs.last ?? 0)) * alignment
            outLines.append(.init(top: top + lh * CGFloat(i), height: lh))
            carets += xs.map { .init(line: i, x: $0 + left) }    // the last one stands for the line break
        }
        return Carets(lines: outLines, carets: carets)
    }

    /// The carets in view points for the frame `f`: the host's caret map, else the stand-in. `measure` is the UI font
    /// while drawing (`drawing`: kept for the next press), else an even advance of 0.6 em per character.
    private func carets(_ f: Frame, text: String, drawing: Bool = false,
                        measure: (String) -> CGFloat = { CGFloat($0.count) * 7.2 }) -> Carets {
        guard let t = target, t.size.width > 0, t.size.height > 0 else { return Carets(lines: [], carets: []) }
        let sx = f.size.width / t.size.width, sy = f.size.height / t.size.height
        if let c = caretSource?(text), c.carets.count == text.count + 1 { return c.scaled(sx, sy) }
        if !drawing, let d = drawnCarets, d.carets.count == text.count + 1 { return d }
        let c = Self.standIn(text, size: f.size, viewPerPixel: sx, fontSize: fontSize, lineSpacing: lineSpacing,
                             alignment: alignment, isBox: isBox, measure: measure)
        if drawing { drawnCarets = c }
        return c
    }

    // MARK: Drawing and pointer

    private struct Frame { let o: CGPoint, ux: CGPoint, uy: CGPoint, size: CGSize }

    private func frame(_ q: [CGPoint]) -> Frame? {
        guard q.count == 4 else { return nil }
        let w = hypot(q[1].x - q[0].x, q[1].y - q[0].y), h = hypot(q[3].x - q[0].x, q[3].y - q[0].y)
        guard w > 0.5, h > 0.5 else { return nil }
        return Frame(o: q[0], ux: CGPoint(x: (q[1].x - q[0].x) / w, y: (q[1].y - q[0].y) / w),
                     uy: CGPoint(x: (q[3].x - q[0].x) / h, y: (q[3].y - q[0].y) / h), size: CGSize(width: w, height: h))
    }

    /// A view point in the frame's own axes.
    private func local(_ p: CGPoint, _ f: Frame) -> CGPoint {
        let d = CGPoint(x: p.x - f.o.x, y: p.y - f.o.y)
        return CGPoint(x: d.x * f.ux.x + d.y * f.ux.y, y: d.x * f.uy.x + d.y * f.uy.y)
    }

    public func draw(_ c: inout Canvas, canvasRect r: CGRect, theme t: DrawTheme) {
        guard let e = edit, let f = frame(quad(canvasRect: r)) else { return }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: f.o.x + f.ux.x * x + f.uy.x * y, y: f.o.y + f.ux.y * x + f.uy.y * y)
        }
        c.stroke(polygon: [pt(0, 0), pt(f.size.width, 0), pt(f.size.width, f.size.height), pt(0, f.size.height)],
                 width: 1, t.accent)
        let m = carets(f, text: e.string, drawing: true) { c.size(of: $0, fontSize: 12).width }
        guard m.carets.count == e.text.count + 1 else { return }
        let sel = e.selection
        if !sel.isEmpty {
            for (li, line) in m.lines.enumerated() {
                let xs = (sel.lowerBound...sel.upperBound).filter { m.carets[$0].line == li }.map { m.carets[$0].x }
                guard xs.count >= 2, let x0 = xs.min(), let x1 = xs.max(), x1 > x0 else { continue }
                let y0 = line.top, y1 = line.top + line.height
                c.fill(polygon: [pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1)], t.accent.alpha(0.3))
            }
        }
        let caret = m.carets[min(e.caret, m.carets.count - 1)]
        if m.lines.indices.contains(caret.line) {
            let line = m.lines[caret.line]
            c.strokeLine(from: pt(caret.x, line.top), to: pt(caret.x, line.top + line.height), width: 2, t.accent)
            HostRequests.current.caret = c.px(CGRect(origin: pt(caret.x, line.top), size: .zero).union(CGRect(origin: pt(caret.x, line.top + line.height), size: .zero)))
        }
    }

    /// A press while editing: inside the frame it places the caret (Shift extends) and returns true; outside it ends the
    /// edit and returns false so the press goes on (the Type tool's next click).
    public func mouseDown(_ p: CGPoint, modifiers: InputModifiers, canvasRect r: CGRect) -> Bool {
        guard var e = edit, let f = frame(quad(canvasRect: r)) else { return false }
        let l = local(p, f)
        guard l.x >= -4, l.y >= -4, l.x <= f.size.width + 4, l.y <= f.size.height + 4 else {
            end(); return false
        }
        e.place(carets(f, text: e.string).index(at: l), extend: modifiers.contains(.shift))
        edit = e
        return true
    }
}
