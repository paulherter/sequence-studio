import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// The About and Acknowledgments bodies (`AboutDialog.makeBody` / `makeAcknowledgmentsBody` in SQEditorUI, AppController+About)
/// on the canvas: in the `SQModal.Size.sList` card, the app icon (88), the name in the display size, the version line, the
/// tagline, the link buttons (Support tinted), the license, the supporters (when any) and the credits; the second page lists
/// what the app builds on. The words are `AboutContent`, shared with the AppKit dialog.
@MainActor
public final class ShellAboutContent: ShellDialogContent {
    public enum Page: Sendable { case about, acknowledgments }

    enum M {
        static let cardWidth: CGFloat = 480          // Theme.Modal.widthSList
        static let icon: CGFloat = 88
        static let md: CGFloat = 12                  // Theme.Spacing.md
        static let sm: CGFloat = 8                   // Theme.Spacing.sm
        static let display: CGFloat = 18, title: CGFloat = 13, body: CGFloat = 11, caption: CGFloat = 10
        static let taglineWidth: CGFloat = 360
        static let supportersWidth: CGFloat = 300
        static let supportersMaxHeight: CGFloat = 96
        static let buttonHeight: CGFloat = 22        // Theme.Metrics.quietButton
        static let buttonPadding: CGFloat = 11       // SQButton.horizontalPadding
        static let buttonRadius: CGFloat = 8
        static let sidePad: CGFloat = 20
        static let support = DrawColor(hex: 0xEA4AAA) // Theme.Colors.support
    }

    public let page: Page
    let supporters: [String]
    let links: [AboutContent.Link]
    let open: (URL) -> Void
    public var openPopup: ((_ items: [SQMenuItem], _ below: CGRect) -> Void)?

    /// One drawn piece of the body, in window points after `layout`.
    enum Part {
        case icon(CGRect)
        case text(String, CGRect, size: CGFloat, Tone, medium: Bool, center: Bool)
        case button(String, CGRect, URL, support: Bool)
    }
    enum Tone { case label, label2, label3 }
    private(set) var parts: [Part] = []
    private var hovered: Int?, pressed: Int?

    public init(page: Page, supporters: [String] = [], discord: URL? = SupportLinks.discord, open: @escaping (URL) -> Void) {
        self.page = page; self.supporters = supporters
        links = AboutContent.links(discord: discord); self.open = open
    }

    static func url(_ l: AboutContent.Link) -> URL {
        switch l {
        case .github: SupportLinks.github
        case .support: SupportLinks.url
        case .discord: SupportLinks.discord ?? SupportLinks.url
        }
    }

    private var measure = TextMeasure(atlas: nil, scale: 1)

    public func height(width: CGFloat) -> CGFloat {
        build(CGRect(x: 0, y: 0, width: width, height: 0), measure: measure).height
    }

    public func layout(_ frame: CGRect, measure m: TextMeasure) {
        measure = m
        parts = build(frame, measure: m).parts
    }

    private func lineHeight(_ size: CGFloat, _ m: TextMeasure) -> CGFloat { m.lineHeight(size) }

    /// The body stacked from `frame.minY` down (the Mac NSStackView, centered column); returns the parts and the height.
    private func build(_ frame: CGRect, measure m: TextMeasure) -> (parts: [Part], height: CGFloat) {
        var out: [Part] = []
        let x = frame.minX + M.sidePad, w = frame.width - 2 * M.sidePad
        var y = frame.minY
        func lines(_ s: String, size: CGFloat, width: CGFloat, tone: Tone, medium: Bool = false, center: Bool, left: CGFloat? = nil) {
            let lh = lineHeight(size, m)
            let lx = left ?? (x + (w - width) / 2)
            for l in m.lines(SQL10n.string(s), width: width, size: size) {
                out.append(.text(l, CGRect(x: lx, y: y, width: width, height: lh), size: size, tone, medium: medium, center: center))
                y += lh
            }
        }
        switch page {
        case .about:
            out.append(.icon(CGRect(x: x + (w - M.icon) / 2, y: y, width: M.icon, height: M.icon)))
            y += M.icon + M.md
            lines("Sequence Studio", size: M.display, width: w, tone: .label, center: true)
            y += M.sm
            lines(AppVersion.aboutLine, size: M.body, width: w, tone: .label2, center: true)
            y += M.md
            lines(AboutContent.tagline, size: M.title, width: M.taglineWidth, tone: .label2, center: true)
            y += M.md
            let widths = links.map { max(ceil(m.width(SQL10n.string($0.title), size: M.body)) + 2 * M.buttonPadding, 0) }
            var bx = x + (w - widths.reduce(0, +) - M.sm * CGFloat(max(links.count - 1, 0))) / 2
            for (l, bw) in zip(links, widths) {
                out.append(.button(l.title, CGRect(x: bx, y: y, width: bw, height: M.buttonHeight), Self.url(l), support: l == .support))
                bx += bw + M.sm
            }
            y += M.buttonHeight + M.md
            lines("License: " + AboutContent.license, size: M.body, width: w, tone: .label, center: true)
            if !supporters.isEmpty {
                y += M.md
                let left = x + (w - M.supportersWidth) / 2
                lines("Supporters", size: M.title, width: M.supportersWidth, tone: .label, medium: true, center: false, left: left)
                y += M.sm
                // shortcut: the names stop at the Mac block's max height (96) instead of scrolling; upgrade when the list
                // outgrows it.
                let top = y
                let inner = M.supportersWidth - M.md
                for l in m.lines(supporters.joined(separator: "  \u{00B7}  "), width: inner, size: M.body)
                where y + lineHeight(M.body, m) <= top + M.supportersMaxHeight {
                    out.append(.text(l, CGRect(x: left, y: y, width: inner, height: lineHeight(M.body, m)), size: M.body, .label2,
                                     medium: false, center: false))
                    y += lineHeight(M.body, m)
                }
                y += M.sm
                let title = SupportEntry.support.menuTitle
                let bw = ceil(m.width(SQL10n.string(title), size: M.body)) + 2 * M.buttonPadding
                out.append(.button(title, CGRect(x: left, y: y, width: bw, height: M.buttonHeight), SupportLinks.url, support: false))
                y += M.buttonHeight
            }
            y += M.md
            lines(AboutContent.credits, size: M.caption, width: w, tone: .label3, center: true)
        case .acknowledgments:
            for (i, a) in AboutContent.acknowledgments.enumerated() {
                if i > 0 { y += M.md }
                lines("\(a.name)  ·  \(a.version)", size: M.body, width: w, tone: .label, medium: true, center: false, left: x)
                y += 2
                lines("\(a.license). \(a.usedFor)", size: M.caption, width: w, tone: .label2, center: false, left: x)
            }
            y += M.md
            lines(AboutContent.licenseNote, size: M.caption, width: w, tone: .label3, center: false, left: x)
        }
        return (out, y - frame.minY)
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        for (i, p) in parts.enumerated() {
            switch p {
            case .icon:
                break   // the host shows the app icon over `iconFrame`
            case .text(let s, let r, let size, let tone, let medium, let center):
                let color = switch tone { case .label: t.label; case .label2: t.label2; case .label3: t.label3 }
                c.draw(s, in: r, fontSize: size, color, align: center ? .center : .left, face: medium ? c.medium : 0)
            case .button(let s, let r, _, let support):
                c.fill(roundedRect: r, radius: M.buttonRadius, pressed == i ? t.fillPressed : (hovered == i ? t.fillHover : t.fill))
                c.draw(s, in: r, fontSize: M.body, support ? M.support : t.label, align: .center)
            }
        }
    }

    /// Where the app icon goes (window points; nil on the Acknowledgments page). The host puts the icon there: the draw
    /// list's image slots are all taken (shortcut: a host-side picture; upgrade when the renderer gets a free slot).
    public var iconFrame: CGRect? {
        for p in parts { if case .icon(let r) = p { return r } }
        return nil
    }

    /// The link button index at `p`.
    func button(at p: CGPoint) -> Int? {
        parts.indices.first { if case .button(_, let r, _, _) = parts[$0] { r.contains(p) } else { false } }
    }

    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        switch e {
        case .mouseMoved(let x, let y): hovered = button(at: pt(x, y)); return false
        case .mouseDown(let x, let y, _): pressed = button(at: pt(x, y)); return pressed != nil
        case .mouseDragged(let x, let y): hovered = button(at: pt(x, y)); return pressed != nil
        case .mouseUp(let x, let y):
            defer { pressed = nil }
            guard let p = pressed else { return false }
            if button(at: pt(x, y)) == p, case .button(_, _, let url, _) = parts[p] { open(url) }
            return true
        default: return false
        }
    }
}

extension ShellHost {
    /// Sequence Studio > About (AppController+About `presentAbout`): the About card with Done and, on the left,
    /// Acknowledgments, which swaps to the Acknowledgments card with Back.
    public func showAbout() async {
        var page = ShellAboutContent.Page.about
        while true {
            let d = ShellDialog(page == .about ? "" : "Acknowledgments")
            d.width = ShellAboutContent.M.cardWidth
            d.content = ShellAboutContent(page: page, supporters: aboutSupporters?() ?? []) { [weak self] in
                self?.openURL?($0)
            }
            d.addButton("Done", role: .default)
            d.addButton(page == .about ? "Acknowledgments" : "Back", leading: true)
            guard await ask(d) == .second else { return }
            page = page == .about ? .acknowledgments : .about
        }
    }
}
