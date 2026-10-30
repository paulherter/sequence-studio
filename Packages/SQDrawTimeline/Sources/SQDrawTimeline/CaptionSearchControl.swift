import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// Find and replace on the caption track, the Mac `CaptionSearchPopup` translated onto the canvas: find field with the
/// match count and previous / next / close, replace field with Replace and Replace All, Match Case. Stays open while
/// the timeline is used (closes on Esc or the close button). All logic is `CaptionSearchModel`; the panel turns the
/// answers into timeline actions (`TimelinePanel+CaptionSearch`). Coordinates are window points.
/// shortcut: a click inside an open field selects all instead of placing the caret (the panel has no atlas at event
/// time); upgrade when the field gets the host's text measure.
public struct CaptionSearchControl {
    /// What the panel does after an event.
    public enum Answer: Equatable {
        /// Return, Next, Previous or Replace went to this match: select it, seek, scroll to it.
        case show(CaptionTextMatch)
        /// Typing found this match: select it only.
        case highlight(CaptionTextMatch)
        /// A replace produced this timeline (one undo step with this name).
        case replace(Timeline, String)
        case close
    }

    enum Part: Equatable { case find, replace, previous, next, close, replaceOne, replaceAll, matchCase }

    public static let width: CGFloat = 356
    static let pad = CGFloat(DrawTheme.Spacing.md), gap = CGFloat(DrawTheme.Spacing.sm), line: CGFloat = 22, icon: CGFloat = 22
    static let countWidth: CGFloat = 64
    public static var height: CGFloat { pad + line + gap + line + gap + line + pad }

    public private(set) var model: CaptionSearchModel
    /// Top left of the card (window points).
    public var origin: CGPoint = .zero
    var findField = TextFieldControl()
    var replaceField = TextFieldControl()
    /// "N replaced", shown in place of the match count until the next action in the popup.
    var notice: String?
    /// False until the current match was gone to: the first Return or Next goes to it, later ones step on.
    var visited = false
    var hovered: Part?
    var pressed: Part?

    public init(model: CaptionSearchModel = CaptionSearchModel()) {
        self.model = model
        findField.alignment = .left; replaceField.alignment = .left
        findField.fontSize = CGFloat(DrawTheme.TypeSize.body); replaceField.fontSize = findField.fontSize
        findField.placeholder = "Find in captions"; replaceField.placeholder = "Replace with"
    }

    public var frame: CGRect { CGRect(x: origin.x, y: origin.y, width: Self.width, height: Self.height) }
    public var countText: String { notice ?? model.countLabel }
    public var isEditing: Bool { findField.isEditing || replaceField.isEditing }

    // MARK: Layout (the Mac `build`)

    func rect(_ p: Part) -> CGRect {
        let o = origin, w = Self.width, pad = Self.pad, h = Self.line
        let y1 = o.y + pad, y2 = y1 + h + Self.gap, y3 = y2 + h + Self.gap
        let iconStep = Self.icon + CGFloat(DrawTheme.Spacing.xs)
        let right = o.x + w - pad - 3 * iconStep - (Self.gap - CGFloat(DrawTheme.Spacing.xs))
        let allW: CGFloat = 84, oneW: CGFloat = 68
        switch p {
        case .close: return CGRect(x: o.x + w - pad - Self.icon, y: y1, width: Self.icon, height: h)
        case .next: return CGRect(x: o.x + w - pad - iconStep - Self.icon, y: y1, width: Self.icon, height: h)
        case .previous: return CGRect(x: o.x + w - pad - 2 * iconStep - Self.icon, y: y1, width: Self.icon, height: h)
        case .find: return CGRect(x: o.x + pad, y: y1, width: right - Self.countWidth - Self.gap - o.x - pad, height: h)
        case .replaceAll: return CGRect(x: o.x + w - pad - allW, y: y2, width: allW, height: h)
        case .replaceOne: return CGRect(x: o.x + w - pad - allW - Self.gap - oneW, y: y2, width: oneW, height: h)
        case .replace: return CGRect(x: o.x + pad, y: y2, width: w - 2 * pad - allW - oneW - 2 * Self.gap, height: h)
        case .matchCase: return CGRect(x: o.x + pad, y: y3, width: 160, height: h)
        }
    }

    var countFrame: CGRect {
        let f = rect(.find)
        return CGRect(x: f.maxX + Self.gap, y: f.minY, width: Self.countWidth, height: Self.line)
    }

    func part(at p: CGPoint) -> Part? {
        [Part.find, .replace, .previous, .next, .close, .replaceOne, .replaceAll, .matchCase].first { rect($0).contains(p) }
    }

    func enabled(_ p: Part) -> Bool {
        let has = !model.matches.isEmpty
        switch p {
        case .previous, .next: return has
        case .replaceOne: return model.canReplace
        case .replaceAll: return has && model.find != model.replacement
        default: return true
        }
    }

    // MARK: Opening

    /// Shows the card (or, already shown, puts the caret back into the find field with its text selected).
    public mutating func focusFind(in timeline: Timeline, from playhead: Time) {
        _ = replaceField.commit()
        _ = findField.commit()
        findField.mouseDown()
        _ = refresh(in: timeline, from: playhead, highlight: false)
    }

    /// The timeline changed under the popup (an edit, undo): search again, keep the place. A "N replaced" notice stays.
    public mutating func resync(_ timeline: Timeline, playhead: Time) {
        model.refresh(in: timeline, from: playhead)
    }

    var findText: String { findField.editor?.string ?? findField.text }
    private var replaceText: String { replaceField.editor?.string ?? replaceField.text }

    /// Takes the fields into the model and searches. `highlight`: the search text changed, so the match is marked.
    mutating func refresh(in timeline: Timeline, from playhead: Time, highlight: Bool) -> [Answer] {
        model.find = findText
        model.replacement = replaceText
        model.refresh(in: timeline, from: playhead)
        guard highlight else { return [] }
        notice = nil
        visited = false
        return model.currentMatch.map { [.highlight($0)] } ?? []
    }

    // MARK: Actions

    mutating func step(forward: Bool) -> [Answer] {
        notice = nil
        if visited || !forward { model.step(forward: forward) }
        visited = true
        return model.currentMatch.map { [.show($0)] } ?? []
    }

    mutating func replaceOne(in timeline: Timeline) -> [Answer] {
        notice = nil
        model.replacement = replaceText
        guard let out = model.replacingCurrent(in: timeline) else { return [] }
        visited = true
        return [.replace(out, "Replace in Caption")] + (model.currentMatch.map { [.show($0)] } ?? [])
    }

    mutating func replaceAll(in timeline: Timeline) -> [Answer] {
        model.replacement = replaceText
        guard let r = model.replacingAll(in: timeline) else { notice = nil; return [] }
        notice = r.count == 1 ? "1 replaced" : "\(r.count) replaced"
        return [.replace(r.timeline, "Replace All in Captions")]
    }

    // MARK: Events

    /// A press. nil when it landed outside the card (the card stays open, its fields commit).
    public mutating func mouseDown(_ p: CGPoint, timeline: Timeline, playhead: Time) -> [Answer]? {
        guard frame.contains(p) else {
            _ = findField.commit(); _ = replaceField.commit()
            return nil
        }
        guard let part = part(at: p), enabled(part) else { return [] }
        pressed = part
        switch part {
        case .find:
            _ = replaceField.commit()
            if !findField.isEditing { findField.mouseDown() }
        case .replace:
            _ = findField.commit()
            if !replaceField.isEditing { replaceField.mouseDown() }
        default: break
        }
        return []
    }

    public mutating func mouseUp(_ p: CGPoint, timeline: Timeline, playhead: Time) -> [Answer] {
        defer { pressed = nil }
        guard let part = pressed, rect(part).contains(p), enabled(part) else { return [] }
        switch part {
        case .previous: return step(forward: false)
        case .next: return step(forward: true)
        case .close: return [.close]
        case .replaceOne: return replaceOne(in: timeline)
        case .replaceAll: return replaceAll(in: timeline)
        case .matchCase:
            model.caseSensitive.toggle()
            return refresh(in: timeline, from: playhead, highlight: true)
        case .find, .replace: return []
        }
    }

    public mutating func mouseMoved(_ p: CGPoint) { hovered = frame.contains(p) ? part(at: p) : nil }

    /// A key. nil when neither field is open (the timeline takes it).
    public mutating func key(_ k: InputKey, modifiers m: InputModifiers, timeline: Timeline, playhead: Time) -> [Answer]? {
        let inFind = findField.isEditing
        guard inFind || replaceField.isEditing else { return nil }
        switch k {
        case .escape: return [.close]
        case .enter: return inFind ? step(forward: !m.contains(.shift)) : replaceOne(in: timeline)
        case InputKey.tab:
            // `nextKeyView`: the two fields hand the focus to each other.
            if inFind { _ = findField.commit(); replaceField.mouseDown() } else { _ = replaceField.commit(); findField.mouseDown() }
            return []
        default:
            let before = (findText, replaceText)
            if inFind { _ = findField.key(k, modifiers: m) } else { _ = replaceField.key(k, modifiers: m) }
            guard (findText, replaceText) != before else { return [] }
            return refresh(in: timeline, from: playhead, highlight: inFind)
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let bounds = frame, radius = SQMenuLayout.cornerRadius
        c.shadow(roundedRect: bounds, radius: radius, blur: 10, dy: 4, DrawColor(0, 0, 0, 0.25))
        let bg = bounds.insetBy(dx: 0.25, dy: 0.25)
        c.fill(roundedRect: bg, radius: radius, t.overlay)
        c.stroke(roundedRect: bg, radius: radius, width: 0.5, t.inkFill(0.14))
        findField.draw(&c, in: rect(.find), theme: t, focused: false)
        c.draw(countText, in: countFrame, fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3, align: .right)
        for (part, icon) in [(Part.previous, SQIcon.chevronUp), (.next, .chevronDown), (.close, .close)] {
            let r = rect(part), on = enabled(part)
            if on, hovered == part || pressed == part {
                c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), pressed == part ? t.fillPressed : t.fillHover)
            }
            let color = on ? t.label2 : t.label2.alpha(t.label2.a * InspectorTokens.disabledAlpha)
            c.draw(icon: icon, at: CGPoint(x: r.midX - 7, y: r.midY - 7), size: 14, color)
        }
        replaceField.draw(&c, in: rect(.replace), theme: t, focused: false)
        for (part, title) in [(Part.replaceOne, "Replace"), (.replaceAll, "Replace All")] {
            InspectorDraw.button(&c, title: SQL10n.string(title), in: rect(part), hovering: hovered == part, pressed: pressed == part,
                                 enabled: enabled(part), t)
        }
        let mc = rect(.matchCase)
        let box = CGRect(x: mc.minX, y: mc.midY - 7, width: 14, height: 14)
        InspectorDraw.checkbox(&c, model.caseSensitive ? .on : .off, box: box, hovering: hovered == .matchCase,
                               pressed: pressed == .matchCase, enabled: true, t)
        c.draw(SQL10n.string("Match Case"), in: CGRect(x: box.maxX + 6, y: mc.minY, width: mc.width - 20, height: mc.height),
               fontSize: CGFloat(DrawTheme.TypeSize.body), t.label)
    }
}
