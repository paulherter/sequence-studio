import Foundation
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQUIKit

/// The status bar's texts (the Mac `StatusBarView` setters), one value per frame.
public struct StatusBarContent: Equatable, Sendable {
    /// "1920 × 1080 · 25 fps" (+ " VFR").
    public var format = ""
    /// The save state with its dot; nil hides both.
    public var save: SaveStatus?
    /// Flash messages and job lines (label2).
    public var message = ""
    /// "Playback: Full · GPU"; "" hides it.
    public var playback = ""
    /// "Sequence Studio 0.9 Alpha".
    public var version = "Sequence Studio " + AppVersion.display
    /// The Color page's grade text; "" hides it.
    public var grade = ""
    /// The warning chip while Linked Selection is off.
    public var linkedSelectionOff = false
    /// The background relink offer's chip ("Found 4 offline files · Reconnect"); "" hides it.
    public var relinkOffer = ""
    /// The export queue's ring (0...1); nil hides it.
    public var exportProgress: Double?
    public init() {}

    /// The Mac `setSequence` text.
    public static func format(width: Int, height: Int, fps: Double, variableFrameRate: Bool) -> String {
        let rate = fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
        return "\(width) × \(height) · \(rate) fps" + (variableFrameRate ? " VFR" : "")
    }

    /// The Mac `setPlaybackQuality` text.
    public static func playback(_ q: MonitorQuality) -> String { "Playback: \(q.title) · GPU" }
}

/// The status bar, drawn: the Mac `StatusBarView.layout` (format, dot + save state and the message from the left;
/// version, playback, grade and the Linked Selection chip from the right; a narrow window drops the version first,
/// then the playback and grade texts), the export ring at the right end and the relink offer chip left of the warnings.
/// The Mac outside-media chip is off since the Library's health line shows that count (`MediaPlacement.projectChanged`).
/// shortcut: the ring opens no queue window (the shared UI has none yet); add the click when it does.
public enum StatusBarDraw {
    public static let linkedSelectionOff = "Linked Selection off"
    /// ShellMetrics.statusPad / statusDot and Theme.Spacing.iconToLabel (SQUIKit's AppKit Theme is Mac-only).
    static let pad = CGFloat(DrawTheme.Spacing.lg), dot: CGFloat = 6, iconToLabel: CGFloat = 6
    static let fontSize = CGFloat(DrawTheme.TypeSize.body)

    public struct Frames: Equatable {
        public var format, dot, save, message, version, playback, grade, link, relink, ring: CGRect?
    }
    /// `Theme.Metrics.statusLine` + 6: the ring's side.
    static let ringSide: CGFloat = 20
    static let chipSize = CGFloat(DrawTheme.TypeSize.caption)

    /// Frames in the bar's coordinates (points); `width` measures a text at the bar's font, `chipWidth` at the chip's
    /// caption size (nil: `width`).
    public static func layout(_ s: StatusBarContent, in bar: CGRect, width: (String) -> CGFloat,
                              chipWidth: ((String) -> CGFloat)? = nil) -> Frames {
        var f = Frames()
        let gap = pad
        func text(_ x: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: x, y: bar.minY, width: ceil(w), height: bar.height) }
        var left = bar.minX + pad
        if !s.format.isEmpty {
            let w = width(s.format)
            f.format = text(left, w)
            left += ceil(w) + gap
        }
        if let save = s.save {
            f.dot = CGRect(x: left, y: (bar.midY - dot / 2).rounded(), width: dot, height: dot)
            let w = width(save.text)
            f.save = text(left + dot + iconToLabel, w)
            left = f.save!.maxX + gap
        }
        var right = bar.maxX - pad
        if s.exportProgress != nil {
            f.ring = CGRect(x: right - ringSide + 3, y: (bar.midY - ringSide / 2).rounded(), width: ringSide, height: ringSide)
            right = f.ring!.minX - gap + 3
        }
        for (key, s, least) in [(\Frames.version, s.version, left + 320), (\Frames.playback, s.playback, left + 160)] where !s.isEmpty {
            let w = ceil(width(s))
            guard right - w >= least else { continue }
            f[keyPath: key] = text(right - w, w)
            right -= w + gap
        }
        if !s.grade.isEmpty {
            let w = ceil(width(s.grade))
            if right - w >= left + 160 {
                f.grade = text(right - w, w)
                right -= w + gap
            }
        }
        if s.linkedSelectionOff {
            let w = ceil(width(linkedSelectionOff))
            if right - w >= left {
                f.link = text(right - w, w)
                right -= w + gap
            }
        }
        if !s.relinkOffer.isEmpty {
            let w = ceil(chipWidth.map { $0(s.relinkOffer) } ?? width(s.relinkOffer))
            if right - w >= left {
                f.relink = text(right - w, w)
                right -= w + gap
            }
        }
        if !s.message.isEmpty, right > left { f.message = CGRect(x: left, y: bar.minY, width: right - left, height: bar.height) }
        return f
    }

    public static func draw(_ c: inout Canvas, _ s: StatusBarContent, in bar: CGRect, theme t: DrawTheme) {
        c.fill(bar, t.titlebar)
        c.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1), t.separator)
        let fs = fontSize
        let f = layout(s, in: bar, width: { [c] in c.size(of: $0, fontSize: fs).width },
                       chipWidth: { [c] in c.size(of: $0, fontSize: chipSize).width })
        let w = t.palette.warning, warning = DrawColor(Float(w.r) / 255, Float(w.g) / 255, Float(w.b) / 255, Float(w.a))
        if let r = f.format { c.draw(s.format, in: r, fontSize: fs, t.label3) }
        if let r = f.dot, let save = s.save {
            let green = save.kind == .saved || save.kind == .empty
            c.fill(ellipseIn: r, green ? DrawColor(hex: 0x30D158) : warning)   // Theme.Colors.green
        }
        if let r = f.save, let save = s.save { c.draw(SQL10n.localized(save.text), in: r, fontSize: fs, t.label3) }
        if let r = f.message { c.draw(SQL10n.localized(s.message), in: r, fontSize: fs, t.label2) }
        if let r = f.version { c.draw(s.version, in: r, fontSize: fs, t.label3) }
        if let r = f.playback { c.draw(s.playback, in: r, fontSize: fs, t.label3) }
        if let r = f.grade { c.draw(s.grade, in: r, fontSize: fs, t.label3) }
        if let r = f.link { c.draw(SQL10n.string(linkedSelectionOff), in: r, fontSize: fs, warning) }
        if let r = f.relink { c.draw(s.relinkOffer, in: r, fontSize: chipSize, warning) }
        if let r = f.ring, let p = s.exportProgress { drawRing(&c, in: r, progress: p, theme: t) }
    }

    /// The Mac `ProgressRingView`: a 2 pt track in the hover fill, the accent arc clockwise from 12 o'clock.
    static func drawRing(_ c: inout Canvas, in r: CGRect, progress: Double, theme t: DrawTheme) {
        let o = r.insetBy(dx: 4, dy: 4)
        c.stroke(ellipseIn: o, width: 2, t.fillHover)
        let p = min(max(progress, 0), 1)
        guard p > 0 else { return }
        let steps = max(Int(48 * p), 2), rad = o.width / 2
        let pts = (0...steps).map { i -> CGPoint in
            let a = -Double.pi / 2 + 2 * Double.pi * p * Double(i) / Double(steps)
            return CGPoint(x: o.midX + rad * CGFloat(cos(a)), y: o.midY + rad * CGFloat(sin(a)))
        }
        c.strokePolyline(pts, width: 2, t.accent)
    }

    /// The clickable part under `p` (bar points): the relink chip or the ring.
    public enum Part: Equatable { case relink, ring }
    public static func part(at p: CGPoint, _ s: StatusBarContent, in bar: CGRect, measure: TextMeasure) -> Part? {
        let f = layout(s, in: bar, width: { measure.width($0, size: fontSize) }, chipWidth: { measure.width($0, size: chipSize) })
        if f.relink?.contains(p) == true { return .relink }
        if f.ring?.contains(p) == true { return .ring }
        return nil
    }
}

/// The title row's own parts after the menu titles (the Mac `TopBarView`): the project name, "Edited 2 min ago" in a
/// slot as wide as its widest text (so the page switch after it stays put), and at the right end the Workspace popup
/// and the accent Export button. The Edit | Color switch is `ColorPageHost.layoutSwitch(after: switchAfter)`.
@MainActor
public final class TitleRowHost {
    public enum Part: Hashable { case name, edited, workspace, export }
    public private(set) var frames: [Part: CGRect] = [:]
    /// Where the page switch goes (points): after the edit-time slot.
    public private(set) var switchAfter: CGFloat = 0
    public var projectName = ""
    /// When the project last changed or was saved; nil hides the edit time.
    public var edited: Date?
    public var workspaceName = ""
    /// The start screen is up: the bar is the app's name only (the Mac chooser window has no project name, workspace or
    /// Export), so the row lays out nothing.
    public var isChooser = false
    /// The Workspace popup's items (Window > Workspaces).
    public var workspaceItems: (@MainActor () -> [SQMenuItem])?
    public var onExport: (@MainActor () -> Void)?
    public var menus: MenuController?
    var hovered: Part?
    var pressed: Part?
    static let nameMax: CGFloat = 360, nameMin: CGFloat = 80
    /// ShellMetrics.topGap / topControl / topTrailing (SQUIKit's AppKit Theme is Mac-only).
    static let gap = CGFloat(DrawTheme.Spacing.md), control: CGFloat = 28, trailing = CGFloat(DrawTheme.Spacing.md)
    static let sm = CGFloat(DrawTheme.Spacing.sm), md = CGFloat(DrawTheme.Spacing.md)
    static let fontSize = CGFloat(DrawTheme.TypeSize.title), editedSize = CGFloat(DrawTheme.TypeSize.body)
    static let editedSamples = ["Edited just now", "Edited 59 min ago", "Edited 23 h ago", "Edited 99 d ago"]

    public init() {}

    /// "Edited just now", "Edited 2 min ago", "Edited 3 h ago", "Edited 4 d ago" (the Mac `TopBarView.relative`).
    public static func editedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, now.timeIntervalSince(date))
        let rel = s < 60 ? "just now" : s < 3600 ? "\(Int(s / 60)) min ago" : s < 86_400 ? "\(Int(s / 3600)) h ago" : "\(Int(s / 86_400)) d ago"
        return "Edited " + rel
    }

    /// Lays the parts out in the `barHeight` tall bar of `width` points that starts at `top` (Windows: the second row,
    /// below the menu row), from `x` (the end of the menu titles); the switch keeps `switchWidth` free. A narrow bar
    /// shortens the name and then drops the Workspace popup (Window > Workspaces still lists them); Export never shrinks.
    public func layout(after x: CGFloat, width: CGFloat, barHeight: CGFloat, top: CGFloat = 0, switchWidth: CGFloat? = nil,
                       measure: TextMeasure) {
        let switchWidth = switchWidth ?? 2 * ColorPageHost.switchSegment
        frames = [:]
        switchAfter = x
        guard !isChooser else { return }
        let gap = Self.gap, ch = min(Self.control, barHeight - 4)
        let y = top + ((barHeight - ch) / 2).rounded()
        let exportW = ceil(measure.width(SQL10n.string("Export"), size: Self.editedSize, face: measure.medium)) + 2 * Self.md
        let export = CGRect(x: width - Self.trailing - exportW, y: y, width: exportW, height: ch)
        frames[.export] = export
        var minX = export.minX
        let left = x + gap
        if !workspaceName.isEmpty {
            let w = ceil(measure.width(workspaceName, size: Self.editedSize)) + 2 * Self.sm + 12
            let r = CGRect(x: export.minX - Self.sm - w, y: y, width: w, height: ch)
            if r.minX - gap >= left + switchWidth + ColorPageHost.switchLead {
                frames[.workspace] = r
                minX = r.minX
            }
        }
        let slot = Self.editedSamples.map { ceil(measure.width($0, size: Self.editedSize)) }.max() ?? 0
        let subGap = Self.sm
        let room = max(minX - gap - switchWidth - ColorPageHost.switchLead - left, 0)
        let full = min(ceil(measure.width(projectName, size: Self.fontSize, face: measure.semibold)), Self.nameMax)
        // A narrow bar gives up the edit-time slot before the name gets shorter than `nameMin`.
        let keepsSlot = room - subGap - slot >= min(full, Self.nameMin)
        let nameW = keepsSlot ? min(full, room - subGap - slot) : min(full, room)
        frames[.name] = CGRect(x: left, y: top, width: nameW, height: barHeight)
        let text = Self.editedText(edited)
        if keepsSlot, !text.isEmpty, measure.width(text, size: Self.editedSize) <= slot {
            frames[.edited] = CGRect(x: left + nameW + subGap, y: top, width: slot, height: barHeight)
        }
        switchAfter = keepsSlot ? left + nameW + subGap + slot : left + nameW
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        if let r = frames[.name], r.width > 0 { c.draw(projectName, in: r, fontSize: Self.fontSize, t.label, face: c.semibold) }
        if let r = frames[.edited] { c.draw(Self.editedText(edited), in: r, fontSize: Self.editedSize, t.label3) }
        if let r = frames[.workspace] {
            if pressed == .workspace || hovered == .workspace {
                c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), pressed == .workspace ? t.fillPressed : t.fillHover)
            }
            let text = CGRect(x: r.minX + Self.sm, y: r.minY, width: r.width - 2 * Self.sm - 12, height: r.height)
            c.draw(workspaceName, in: text, fontSize: Self.editedSize, t.label2)
            c.draw(icon: .chevronDown, at: CGPoint(x: r.maxX - Self.sm - 10, y: (r.midY - 5).rounded()), size: 10, t.label3)
        }
        if let r = frames[.export] {
            var fill = t.accentFill
            if pressed == .export { fill = fill.lifted(-0.1) } else if hovered == .export { fill = fill.lifted(0.06) }
            c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), fill)
            c.draw(SQL10n.string("Export"), in: r, fontSize: Self.editedSize, .white, align: .center, face: c.medium)
        }
    }

    /// Clicks on Export and the Workspace popup, hover for both. Events in pixels.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func part(_ x: Float, _ y: Float) -> Part? {
            let q = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            return [Part.export, .workspace].first { frames[$0]?.contains(q) == true }
        }
        switch e {
        case .mouseMoved(let x, let y):
            hovered = part(x, y)
            return false
        case .mouseDown(let x, let y, _):
            guard let p = part(x, y) else { return false }
            pressed = p
            if p == .workspace, let r = frames[.workspace], let items = workspaceItems?() {
                pressed = nil
                menus?.popUp(items: items, below: r)
            }
            return true
        case .mouseUp(let x, let y):
            guard let p = pressed else { return false }
            pressed = nil
            if p == .export, part(x, y) == .export { onExport?() }
            return true
        default:
            return false
        }
    }
}
