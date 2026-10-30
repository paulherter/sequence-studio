import Foundation
import SQExport
import SQUIKit
import SQDrawKit

/// The export queue popover (the Mac `ExportQueueView`): one 48 pt row per job with its name, a progress bar while it
/// runs or the state text, Cancel on a waiting or running job and the file's folder on a finished one, "Clear Finished"
/// in the footer. It opens above the status bar's ring, refreshes while open and closes on a click outside or Escape.
/// Running, finished and failed rows carry Pip (`ShellMascot`), the progress bar uses the icon gradient, and a section
/// above the list shows the background jobs (proxies, transcription) with their own Cancel.
@MainActor
public final class ExportQueuePopover {
    public struct Job: Equatable {
        public var id: UUID
        public var name: String
        public var state: ExportJobState
        public var progress: Double
        public init(id: UUID, name: String, state: ExportJobState, progress: Double) {
            self.id = id; self.name = name; self.state = state; self.progress = progress
        }
        var isFinished: Bool {
            switch state { case .waiting, .running: return false; default: return true }
        }
    }

    /// A background job above the list (the Mac `BackgroundJob`): title, optional progress and Cancel.
    public struct Background: Equatable {
        public var id: String
        public var title: String
        public var progress: Double?
        public init(id: String, title: String, progress: Double?) { self.id = id; self.title = title; self.progress = progress }
    }

    public static let width: CGFloat = 340
    public static let backgroundRowHeight: CGFloat = 36
    static let pipSide: CGFloat = 28
    public static let rowHeight: CGFloat = 48
    public static let footerHeight: CGFloat = 36
    public static let maxListHeight: CGFloat = 320
    static let pad: CGFloat = 12
    static let button: CGFloat = 20

    /// Jobs as the queue reports them (finished ones the user cleared are not listed).
    public private(set) var jobs: [Job] = []
    public private(set) var frame: CGRect = .zero
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    public private(set) var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    public private(set) var background: [Background] = []
    public var onCancelBackground: ((String) -> Void)?
    private var cleared: Set<UUID> = []
    private var anchor: CGPoint
    private var hoverRow: Int?
    /// Runs Pip in each row (blink, breath); the 250 ms queue refresh redraws it.
    private let stage = ShellMascotStage()
    private var hoverClear = false
    public var revealTitle = "Show in Explorer"
    public var canReveal = true
    public var onCancel: ((UUID) -> Void)?
    public var onReveal: ((URL) -> Void)?
    public var onClose: (() -> Void)?

    public init(anchor: CGPoint) { self.anchor = anchor }

    public func update(_ all: [Job], background bg: [Background]? = nil) {
        if let bg { background = bg }
        jobs = all.filter { !cleared.contains($0.id) }
        scroll = min(scroll, maxScroll)
    }

    /// Hides the finished jobs (the queue itself keeps them).
    public func clearFinished() {
        cleared.formUnion(jobs.filter(\.isFinished).map(\.id))
        jobs.removeAll(where: \.isFinished)
        scroll = min(scroll, maxScroll)
    }

    var hasFinished: Bool { jobs.contains(where: \.isFinished) }
    private var contentHeight: CGFloat { CGFloat(jobs.count) * Self.rowHeight }
    private var backgroundHeight: CGFloat { background.isEmpty ? 0 : CGFloat(background.count) * Self.backgroundRowHeight + 9 }
    private var listHeight: CGFloat { jobs.isEmpty ? 80 : min(max(contentHeight, 100), Self.maxListHeight) }
    private func backgroundRect(_ i: Int) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + 4 + CGFloat(i) * Self.backgroundRowHeight, width: frame.width, height: Self.backgroundRowHeight)
    }
    private var maxScroll: CGFloat { max(0, contentHeight - listHeight) }
    private var listRect: CGRect { CGRect(x: frame.minX, y: frame.minY + backgroundHeight, width: frame.width, height: listHeight) }
    private var footerRect: CGRect { CGRect(x: frame.minX, y: frame.minY + backgroundHeight + listHeight, width: frame.width, height: Self.footerHeight) }
    private var clearRect: CGRect {
        let f = footerRect
        return CGRect(x: f.maxX - Self.pad - 96, y: f.minY + 5, width: 96, height: f.height - 10)
    }

    /// Places the popover above its anchor (the ring in the status bar), right edges aligned, inside `window`.
    public func layout(in window: CGRect) {
        let h = backgroundHeight + listHeight + (jobs.isEmpty ? 0 : Self.footerHeight)
        var x = anchor.x - Self.width + 24
        x = min(max(x, window.minX + 8), window.maxX - Self.width - 8)
        var y = anchor.y - 14 - h
        y = max(y, window.minY + 8)
        frame = CGRect(x: x, y: y, width: Self.width, height: h)
    }

    private func rowRect(_ i: Int) -> CGRect {
        CGRect(x: frame.minX, y: listRect.minY + CGFloat(i) * Self.rowHeight - scroll, width: frame.width, height: Self.rowHeight)
    }

    private func actionRect(_ i: Int) -> CGRect {
        let r = rowRect(i)
        return CGRect(x: r.maxX - Self.pad - Self.button, y: r.midY - Self.button / 2, width: Self.button, height: Self.button)
    }

    private func action(_ j: Job) -> (icon: SQIcon, tip: String)? {
        switch j.state {
        case .waiting, .running: return (.closeCircleFilled, "Stop")
        case .done: return canReveal ? (.findFolder, revealTitle) : nil
        default: return nil
        }
    }

    static func stateText(_ s: ExportJobState) -> String {
        switch s {
        case .waiting: return "Waiting"
        case .running: return "Exporting"
        case .done: return "Done"
        case .failed(let why): return SQL10n.format("Failed: %@", why)
        case .cancelled: return "Canceled"
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        guard frame.width > 0 else { return }
        let radius = CGFloat(DrawTheme.Radius.control)
        c.shadow(roundedRect: frame, radius: radius, blur: 16, dy: 6, DrawColor(0, 0, 0, 0.35), opaqueAbove: true)
        c.fill(roundedRect: frame, radius: radius, t.overlay)
        c.stroke(roundedRect: frame, radius: radius, width: 1, t.separator)
        drawBackground(&c, theme: t)
        c.saveGState()
        c.clip(to: listRect)
        if jobs.isEmpty {
            c.draw(SQL10n.string(background.isEmpty ? "No tasks running" : "No exports"), in: listRect, fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
        }
        for (i, j) in jobs.enumerated() {
            let r = rowRect(i)
            guard r.maxY >= listRect.minY, r.minY <= listRect.maxY else { continue }
            if hoverRow == i { c.fill(roundedRect: r.insetBy(dx: 4, dy: 2), radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            let act = action(j)
            let pip = Self.pipAnimation(j.state)
            let textX = r.minX + Self.pad + Self.pipSide + 8
            let textW = Self.width - Self.pad * 2 - Self.pipSide - 8 - (act != nil ? Self.button + 8 : 0)
            let iconRect = CGRect(x: r.minX + Self.pad, y: r.midY - Self.pipSide / 2, width: Self.pipSide, height: Self.pipSide)
            if let pip {
                stage.draw(pip, slot: i, in: iconRect, into: &c)
            } else {
                let glyph: SQIcon = { if case .cancelled = j.state { return .stopCircle }; return .clock }()
                c.draw(icon: glyph, at: CGPoint(x: iconRect.midX - 7, y: iconRect.midY - 7), size: 14, t.label2)
            }
            c.draw(j.name, at: CGPoint(x: textX, y: r.minY + 7), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label, maxWidth: textW)
            if case .running = j.state {
                Self.drawBar(&c, CGRect(x: textX, y: r.minY + 29, width: textW, height: 4), value: j.progress, theme: t)
            } else {
                var line = SQL10n.string(Self.stateText(j.state))
                if case .failed = j.state { line = Self.stateText(j.state) }
                c.draw(line, at: CGPoint(x: textX, y: r.minY + 26), fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label2, maxWidth: textW)
            }
            if let act {
                let a = actionRect(i)
                c.draw(icon: act.icon, at: CGPoint(x: a.minX + 2, y: a.minY + 2), size: Self.button - 4, t.label2)
            }
        }
        c.restoreGState()
        scrollBody.drawScroller(&c, viewport: listRect, content: contentHeight, theme: t)
        if !jobs.isEmpty {
            let f = footerRect
            c.fill(CGRect(x: f.minX, y: f.minY, width: f.width, height: 1), t.separator)
            let on = hasFinished
            if hoverClear, on { c.fill(roundedRect: clearRect, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            c.draw(SQL10n.string("Clear Finished"), in: clearRect, fontSize: CGFloat(DrawTheme.TypeSize.body), on ? t.label : t.label3, align: .center)
        }
    }

    /// Pip's pose for a state (`SQMascotPlace` exportRunning/Done/Failed); waiting and canceled use an icon.
    static func pipAnimation(_ s: ExportJobState) -> SQMascotAnim? {
        switch s {
        case .running: return .work
        case .done: return .cheer
        case .failed: return .oops
        default: return nil
        }
    }

    /// The app icon gradient (`Theme.IconGradient`) as vertical strips, on the fill track.
    static func drawBar(_ c: inout Canvas, _ bar: CGRect, value: Double, theme t: DrawTheme) {
        c.fill(roundedRect: bar, radius: 2, t.fill)
        let w = max(bar.width * CGFloat(min(max(value, 0), 1)), 4)
        guard value > 0 else { return }
        let stops = [DrawColor(hex: 0x350670), DrawColor(hex: 0x8727C7), DrawColor(hex: 0xEF3A87), DrawColor(hex: 0xFE9E46)]
        let n = max(1, Int((w / 2).rounded(.up)))
        c.saveGState()
        c.clip(to: CGRect(x: bar.minX, y: bar.minY, width: w, height: bar.height))
        for i in 0..<n {
            let x0 = bar.minX + w * CGFloat(i) / CGFloat(n)
            let u = Float(bar.width > 0 ? (x0 - bar.minX + 1) / bar.width : 0) * Float(stops.count - 1)
            let k = min(Int(u), stops.count - 2), f = min(max(u - Float(k), 0), 1)
            let a = stops[k], b = stops[k + 1]
            let col = DrawColor(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
            c.fill(CGRect(x: x0, y: bar.minY, width: w / CGFloat(n) + 0.5, height: bar.height), col)
        }
        c.restoreGState()
    }

    private func bgCancelRect(_ i: Int) -> CGRect {
        let r = backgroundRect(i)
        return CGRect(x: r.maxX - Self.pad - Self.button, y: r.midY - Self.button / 2, width: Self.button, height: Self.button)
    }

    private func drawBackground(_ c: inout Canvas, theme t: DrawTheme) {
        guard !background.isEmpty else { return }
        for (i, b) in background.enumerated() {
            let r = backgroundRect(i)
            let textW = Self.width - Self.pad * 2 - 14 - 8 - Self.button - 8
            c.draw(icon: .settings, at: CGPoint(x: r.minX + Self.pad, y: r.midY - 7), size: 14, t.label2)
            let x = r.minX + Self.pad + 22
            c.draw(b.title, at: CGPoint(x: x, y: r.minY + 4), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label, maxWidth: textW)
            if let p = b.progress, p > 0 {
                Self.drawBar(&c, CGRect(x: x, y: r.minY + 25, width: textW, height: 4), value: p, theme: t)
            } else {
                c.draw(SQL10n.string("Waiting"), at: CGPoint(x: x, y: r.minY + 20), fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label2, maxWidth: textW)
            }
            let a = bgCancelRect(i)
            c.draw(icon: .closeCircleFilled, at: CGPoint(x: a.minX + 2, y: a.minY + 2), size: Self.button - 4, t.label2)
        }
        c.fill(CGRect(x: frame.minX, y: frame.minY + backgroundHeight - 1, width: frame.width, height: 1), t.separator)
    }

    // MARK: Events (window points; `scale` converts the event's pixels)

    /// True when the popover took the event (it is modal: every press outside closes it).
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        if scrollBody.scrollerEvent(e, scale: scale, viewport: listRect, content: contentHeight) { return true }
        let k = CGFloat(max(scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        switch e {
        case .mouseMoved(let x, let y):
            let p = pt(x, y)
            hoverRow = frame.contains(p) && listRect.contains(p) ? row(at: p) : nil
            hoverClear = !jobs.isEmpty && clearRect.contains(p)
            if let i = hoverRow, let a = action(jobs[i]), actionRect(i).contains(p) { HostHover.current.offerTip(SQL10n.string(a.tip)) }
            return true
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            guard frame.contains(p) else { onClose?(); return true }
            for (i, b) in background.enumerated() where bgCancelRect(i).insetBy(dx: -4, dy: -4).contains(p) {
                onCancelBackground?(b.id)
                return true
            }
            if !jobs.isEmpty, clearRect.contains(p), hasFinished { clearFinished(); return true }
            if listRect.contains(p), let i = row(at: p), actionRect(i).insetBy(dx: -4, dy: -4).contains(p) {
                let j = jobs[i]
                switch j.state {
                case .waiting, .running: onCancel?(j.id)
                case .done(let url): onReveal?(url)
                default: break
                }
            }
            return true
        case .mouseDragged, .mouseUp:
            return true
        case .scroll(let x, let y, _, let dy, _):
            guard frame.contains(pt(x, y)) else { return true }
            scrollBody.wheel(dy: dy, scale: k, maxOffset: maxScroll, extent: listRect.height)
            return true
        case .keyDown(let key, _):
            if key == .escape { onClose?() }
            return true
        }
    }

    private func row(at p: CGPoint) -> Int? {
        let i = Int(((p.y - listRect.minY + scroll) / Self.rowHeight).rounded(.down))
        return jobs.indices.contains(i) ? i : nil
    }
}
