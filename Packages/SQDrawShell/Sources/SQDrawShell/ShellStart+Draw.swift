import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// Drawing of the start screen: the Mac `StartWindowView` parts (StartButton, RailRow, ProjectCard, PosterWell, Badge,
/// QuickSizeTile, TemplateCard, LearnCard) on the Canvas with the start tokens.
extension ShellStartScreen {
    /// The start screen's color names (`StartWindow.SC`) on the draw theme.
    struct Colors {
        let t: DrawTheme
        var canvas: DrawColor { t.canvas }
        var frame: DrawColor { t.titlebar }
        var panel: DrawColor { t.panel }
        var well: DrawColor { t.content }
        var raised: DrawColor { t.overlay }
        var soft: DrawColor { t.inkFill(0.06) }
        var softHover: DrawColor { t.inkFill(0.09) }
        var poster: DrawColor { t.fill }
        /// `Theme.Colors.field`.
        var field: DrawColor { DrawColor.black.alpha(t.palette.isDark ? 0.28 : 0.05) }
        var warning: DrawColor { DrawColor(Float(t.palette.warning.r) / 255, Float(t.palette.warning.g) / 255, Float(t.palette.warning.b) / 255, 1) }
        var support: DrawColor { DrawColor(hex: 0xEA4AAA) }
        var badge: DrawColor { DrawColor.black.alpha(0.72) }
        var badgeText: DrawColor { DrawColor.white.alpha(0.92) }
        /// `Theme.Colors.clipVideo` (FrameGlyph).
        var clipVideo: DrawColor { t.clip(.videoDefault) }
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let k = Colors(t: t)
        c.fill(frame, k.canvas)
        drawTopBar(&c, t, k)
        drawRail(&c, t, k)
        drawPane(&c, t, k)
        drawStatus(&c, t, k)
    }

    private func drawTopBar(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors) {
        if barFrame == nil {
            c.fill(topBar, k.frame)
            c.draw("Sequence Studio", in: CGRect(x: topBar.minX + titleInset, y: topBar.minY, width: 200, height: topBar.height),
                   fontSize: M.fCap, t.label2)
        }
        let f = searchRect
        c.fill(roundedRect: f, radius: M.rCtl, t.field)
        c.draw(icon: .search, at: CGPoint(x: f.minX + M.s2, y: f.midY - 6), size: 12, t.label3)
        let textRect = CGRect(x: f.minX + M.s2 + 18, y: f.minY, width: f.width - 18 - M.s2 - 26, height: f.height)
        search.draw(&c, in: textRect, theme: t, focused: search.isEditing)
        if query.isEmpty, !search.isEditing {
            c.draw("Search projects", in: textRect, fontSize: M.fLab, t.label3)
            c.draw(ShellPlatformText.commandKey("f"), in: f.insetBy(dx: M.s3, dy: 0), fontSize: M.fCap, t.label3, align: .right)
        } else if !query.isEmpty {
            c.draw(icon: .closeCircleFilled, at: searchClearRect.origin, size: 16, t.label3)
        }
        if search.isEditing { c.stroke(roundedRect: f.insetBy(dx: -1, dy: -1), radius: M.rCtl + 1, width: 2, t.accent) }
    }

    private func drawStatus(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors) {
        let r = statusBar
        c.fill(r, k.frame)
        let n = recents.count
        let left = "Projects folder: " + ShellPlatformText.abbreviatingHome(StorageLocations.load().projectsRoot.path) + "     " + (n == 1 ? "1 project" : "\(n) projects")
        let open = host.map { $0.session.isEmptyUntitled ? "No project open" : $0.session.displayName } ?? ""
        c.draw(left, in: r.insetBy(dx: M.s4, dy: 0), fontSize: M.fCap, t.label3)
        c.draw(open + "     Sequence Studio " + AppVersion.display, in: r.insetBy(dx: M.s4, dy: 0), fontSize: M.fCap, t.label3, align: .right)
    }

    // MARK: Rail

    private func drawRail(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors) {
        for (r, h) in railSpots() {
            switch h {
            case .newProject: button(&c, t, k, "New project", icon: .plus, hint: ShellPlatformText.commandKey("n"), r, primary: true, hover: hover == h)
            case .openOther: button(&c, t, k, "Open…", icon: .folder, hint: ShellPlatformText.commandKey("o"), r, primary: false, hover: hover == h)
            case .tab(let tb):
                if tb == .home {
                    c.draw("Browse", in: CGRect(x: r.minX + M.s3, y: r.minY - 16 - M.s1, width: r.width, height: 16), fontSize: M.fCap, t.label3,
                           face: c.semibold)
                }
                // `RailRow`: pressed fill on the open tab, soft on hover; 12 pt icon centered in 16, 12 pt title (medium when open).
                let on = tab == tb, ink = on || hover == h ? t.label : t.label2
                if on || hover == h { c.fill(roundedRect: r, radius: M.rCtl, on ? t.fillHover : k.soft) }
                c.draw(icon: tb.icon, at: CGPoint(x: r.minX + M.s3 + 2, y: r.midY - M.fLab / 2), size: M.fLab, ink)
                c.draw(tb.rawValue, in: CGRect(x: r.minX + M.s3 + M.s4 + M.s2, y: r.minY, width: r.width - 60, height: r.height),
                       fontSize: M.fLab, ink, face: on ? c.medium : 0)
                if tb == .recent, !recents.isEmpty {
                    c.draw("\(recents.count)", in: r.insetBy(dx: M.s3, dy: 0), fontSize: M.fCap, t.label3, align: .right)
                }
            case .reopenLast:
                let b = CGRect(x: r.minX, y: r.midY - 7, width: 14, height: 14)
                InspectorDraw.checkbox(&c, reopenLast ? .on : .off, box: b, hovering: hover == h, pressed: false, enabled: true, t)
                c.draw("Open last project on launch", in: CGRect(x: b.maxX + M.s2, y: r.minY, width: r.width - 22, height: r.height),
                       fontSize: M.fLab, t.label2)
            case .appearance, .feedback, .support:
                // `LinkButton`: 28 square, 8 radius, 13 pt icon.
                if hover == h { c.fill(roundedRect: r, radius: M.rCtl, k.soft) }
                let icon: SQIcon = h == .appearance ? .contrast : h == .feedback ? .mail
                    : h == .support(.github) ? .code : h == .support(.discord) ? .discord : .heart
                c.draw(icon: icon, at: CGPoint(x: r.midX - M.fBody / 2, y: r.midY - M.fBody / 2), size: M.fBody,
                       h == .support(.support) ? k.support : t.label2)
            default: break
            }
        }
        // Support card (`supportCard`).
        let s = supportCardRect
        c.fill(roundedRect: s, radius: M.rCard, k.soft)
        c.draw(icon: .heart, at: CGPoint(x: s.minX + M.s3, y: s.minY + M.s3 + 2), size: M.fLab, k.support)
        c.draw(SupportEntry.support.menuTitle, in: CGRect(x: s.minX + M.s3 + M.fLab + M.s2, y: s.minY + M.s3, width: s.width - 40, height: 16),
               fontSize: M.fLab, t.label, face: c.semibold)
        _ = c.drawWrapped(SupportLinks.tagline, in: CGRect(x: s.minX + M.s3, y: s.minY + M.s3 + 16 + M.s2, width: s.width - 2 * M.s3, height: 60),
                          fontSize: M.fLab, lineHeight: 16, t.label2)
    }

    /// `StartButton`: 28 high, 8 radius, 12 pt medium; primary = accent fill (6 % brighter on hover), raised = overlay with the
    /// soft fill over it on hover; 12 pt icon leading, 8 gap, the key hint (11 pt medium) at the right.
    func button(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors, _ title: String, icon: SQIcon? = nil, hint: String? = nil,
                _ r: CGRect, primary: Bool, hover: Bool) {
        c.fill(roundedRect: r, radius: M.rCtl, primary ? (hover ? t.accentFill.lifted(0.06) : t.accentFill) : k.raised)
        if !primary, hover { c.fill(roundedRect: r, radius: M.rCtl, k.soft) }
        let ink = primary ? DrawColor.white : t.label
        var x = r.minX + M.s3
        if let icon {
            c.draw(icon: icon, at: CGPoint(x: x, y: r.midY - M.fLab / 2), size: M.fLab, ink)
            x += M.fLab + M.s2
        }
        if icon == nil && hint == nil {
            c.draw(title, in: r, fontSize: M.fLab, ink, align: .center, face: c.medium)
        } else {
            c.draw(title, in: CGRect(x: x, y: r.minY, width: r.maxX - x, height: r.height), fontSize: M.fLab, ink, face: c.medium)
        }
        if let hint {
            c.draw(hint, in: r.insetBy(dx: M.s3, dy: 0), fontSize: M.fCap, primary ? DrawColor.white.alpha(0.78) : t.label3, align: .right,
                   face: c.medium)
        }
    }

    // MARK: Pane

    private func drawPane(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors) {
        c.fill(roundedRect: paneRect, radius: M.rCard, k.panel)
        let h = paneHeader
        var titleRect = CGRect(x: h.minX + M.s6, y: h.minY, width: h.width - 2 * M.s6, height: h.height)
        let titleWidth = c.draw(tab.rawValue, in: titleRect, fontSize: M.fTitle, t.label, face: c.semibold)
        if tab == .recent, !recents.isEmpty {
            titleRect.origin.x += titleWidth + M.s2
            c.draw("\(shown.count)", in: titleRect, fontSize: M.fLab, t.label3)
            let s = sortRect
            c.fill(roundedRect: s, radius: M.rCtl, hover == .sort ? k.softHover : k.soft)
            c.draw(sort.rawValue, in: s.insetBy(dx: M.s3, dy: 0), fontSize: M.fLab, t.label)
            c.draw(icon: .chevronDown, at: CGPoint(x: s.maxX - M.s2 - M.fCap, y: s.midY - M.fCap / 2), size: M.fCap, t.label3)
            // `IconSegments`: field background, the chosen segment raised.
            let seg = layoutToggleRect
            c.fill(roundedRect: seg, radius: M.rCtl, k.field)
            for list in [false, true] {
                let r = layoutSegment(list), on = listLayout == list
                if on { c.fill(roundedRect: r, radius: M.rInner, k.raised) }
                c.draw(icon: list ? .list : .grid, at: CGPoint(x: r.midX - M.fLab / 2, y: r.midY - M.fLab / 2), size: M.fLab,
                       on ? t.label : t.label3)
            }
        }
        if let e = emptyState() {
            let mid = CGPoint(x: contentRect.midX, y: contentRect.midY)
            c.draw(e.title, in: CGRect(x: contentRect.minX, y: mid.y - 40, width: contentRect.width, height: 20), fontSize: M.fHead, t.label,
                   align: .center, face: c.semibold)
            c.draw(e.text, in: CGRect(x: contentRect.minX + M.s6, y: mid.y - 12, width: contentRect.width - 2 * M.s6, height: 16),
                   fontSize: M.fLab, t.label3, align: .center)
            for b in e.buttons { drawElement(&c, t, k, b) }
            return
        }
        c.saveGState()
        c.clip(to: contentRect)
        for e in scrolledElements() { drawElement(&c, t, k, e) }
        c.restoreGState()
        scrollBody.drawScroller(&c, viewport: contentRect, content: paneLayout().height, theme: t)
    }

    private func drawElement(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors, _ e: Element) {
        switch e {
        case .heading(let s, let r, let tile):
            c.draw(s, in: r, fontSize: tile ? M.fHead : M.fLab, tile ? t.label : t.label2, face: c.semibold)
        case .caption(let s, let r):
            c.draw(s, in: r, fontSize: M.fLab, t.label3)
        case .tile(let r):
            c.fill(roundedRect: r, radius: M.rCard, k.soft)
        case .card(let entry, let r):
            drawCard(&c, t, k, entry, r)
        case .listHeader(let r):
            let col = listColumns(r)
            func head(_ s: String, _ x: CGFloat, _ w: CGFloat) {
                c.draw(s, in: CGRect(x: x, y: r.minY, width: w, height: r.height), fontSize: M.fCap, t.label3, face: c.semibold)
            }
            head("Name", col.name.minX, col.name.width)
            head("Frame size", col.size, 110); head("Aspect", col.aspect, 64); head("Frame rate", col.rate, 92)
            head("Length", col.length, 64); head("Edited", col.edited, 96)
        case .listRow(let entry, let r):
            drawListRow(&c, t, k, entry, r)
        case .continueBox(let entry, let r):
            let pic = CGRect(x: r.minX, y: r.minY, width: M.continueThumb * 16 / 9, height: r.height)
            posterWell(&c, t, k, info: infos[entry.path], path: entry.path, gone: false, pic)
            let x = pic.maxX + M.s4
            c.draw(entry.name, in: CGRect(x: x, y: r.minY, width: r.maxX - x, height: 20), fontSize: M.fHead, t.label)
            let info = infos[entry.path]
            let rows = [("Frame", info.map { "\($0.size) · \($0.aspect)" } ?? "–"), ("Rate", info?.rate ?? "–"),
                        ("Length", info?.length ?? "–"), ("Edited", StartLabels.relative(entry.opened))]
            for (i, kv) in rows.enumerated() {
                let y = r.minY + 20 + M.s2 + CGFloat(i) * (16 + M.s2)
                c.draw(kv.0, in: CGRect(x: x, y: y, width: M.kvLabel, height: 16), fontSize: M.fLab, t.label3)
                c.draw(kv.1, in: CGRect(x: x + M.kvLabel, y: y, width: r.maxX - x - M.kvLabel, height: 16), fontSize: M.fLab, t.label)
            }
            button(&c, t, k, "Open", hint: "⏎", openRect(r), primary: true, hover: hover == .continueOpen)
        case .quick(let tmpl, let r):
            let h: Hit = tmpl.map { .quickSize($0.id) } ?? .allFormats
            c.fill(roundedRect: r, radius: M.rCtl, k.raised)
            if hover == h { c.fill(roundedRect: r, radius: M.rCtl, k.soft) }
            let x = r.minX + M.s3 + M.controlSmall + M.s3
            if let tmpl {
                frameGlyph(&c, k, width: tmpl.format.width, height: tmpl.format.height,
                           box: CGRect(x: r.minX + M.s3, y: r.midY - M.controlSmall / 2, width: M.controlSmall, height: M.controlSmall))
                c.draw(tmpl.name, in: CGRect(x: x, y: r.midY - 17, width: r.maxX - x - M.s2, height: 17), fontSize: M.fLab, t.label)
                c.draw("\(tmpl.format.width) × \(tmpl.format.height)", in: CGRect(x: x, y: r.midY, width: r.maxX - x, height: 15),
                       fontSize: M.fCap, t.label3)
            } else {
                c.draw(icon: .ellipsis, at: CGPoint(x: r.minX + M.s3 + 5, y: r.midY - 7), size: 14, t.label2)
                c.draw("All formats…", in: CGRect(x: x, y: r.minY, width: r.maxX - x, height: r.height), fontSize: M.fLab, t.label)
            }
        case .templateCard(let tmpl, let r):
            let h = Hit.template(tmpl.id)
            c.fill(roundedRect: r, radius: M.rCard, hover == h ? k.softHover : k.soft)
            let f = tmpl.format
            let well = CGRect(x: r.minX + M.thumbInset, y: r.minY + M.thumbInset, width: r.width - 2 * M.thumbInset, height: M.templateThumb)
            posterWell(&c, t, k, info: StartProjectInfo(width: f.width, height: f.height, fps: 0, seconds: 0), path: nil, gone: false, well)
            cardText(&c, t, tmpl.name, "\(f.width) × \(f.height)", sub: t.label3, below: well, r)
        case .lesson(let i, let r):
            let l = Self.lessons[i]
            let h = Hit.lesson(i)
            c.fill(roundedRect: r, radius: M.rCard, hover == h ? k.softHover : k.soft)
            c.draw(icon: l.icon, at: CGPoint(x: r.minX + M.s4 + 4, y: r.midY - 8), size: 16, t.label2)
            let x = r.minX + M.s4 + M.s6 + M.s3
            c.draw(l.title, in: CGRect(x: x, y: r.midY - 18, width: r.maxX - x - M.s4, height: 18), fontSize: M.fBody, t.label)
            c.draw(l.text, in: CGRect(x: x, y: r.midY + 1, width: r.maxX - x - M.s4, height: 15), fontSize: M.fCap, t.label3)
        case .button(let s, let h, let r, let primary):
            button(&c, t, k, s, r, primary: primary, hover: hover == h)
        }
    }

    /// `ProjectCard`: picture well, name, "1080 × 1920 · 2 h ago", "…" on hover, ring on the highlighted one.
    private func drawCard(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors, _ e: RecentProjects.Entry, _ r: CGRect) {
        let gone = missing.contains(e.path), hovering = hover == .card(e.path) || hover == .cardMore(e.path)
        c.fill(roundedRect: r, radius: M.rCard, hovering ? k.softHover : k.soft)
        if e.path == highlightedPath { c.stroke(roundedRect: r, radius: M.rCard, width: 2, t.accent) }
        let well = CGRect(x: r.minX + M.thumbInset, y: r.minY + M.thumbInset, width: r.width - 2 * M.thumbInset, height: M.thumb)
        posterWell(&c, t, k, info: infos[e.path], path: e.path, gone: gone, well)
        let when = StartLabels.relative(e.opened)
        let sub = gone ? "File not found. Click to locate it." : infos[e.path].map { "\($0.size) · \(when)" } ?? when
        cardText(&c, t, e.name, sub, sub: gone ? k.warning : t.label3, nameColor: gone ? t.label2 : t.label, below: well, r)
        if hovering {
            let m = moreRect(r)
            if hover == .cardMore(e.path) { c.fill(roundedRect: m, radius: M.rInner, t.fillHover) }
            c.draw(icon: .ellipsis, at: CGPoint(x: m.midX - 6, y: m.midY - 6), size: 12, t.label2)
        }
    }

    /// `ProjectListRow`: 40 x 32 picture, name (medium), size, aspect, rate, length, edited, "…" on hover.
    private func drawListRow(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors, _ e: RecentProjects.Entry, _ r: CGRect) {
        let gone = missing.contains(e.path), hovering = hover == .card(e.path) || hover == .cardMore(e.path)
        if e.path == highlightedPath { c.fill(roundedRect: r, radius: M.rCtl, t.fillPressed) }
        else if hovering { c.fill(roundedRect: r, radius: M.rCtl, k.soft) }
        let info = infos[e.path]
        let col = listColumns(r)
        let thumb = CGRect(x: r.minX + M.s2, y: r.midY - Self.listThumbSize.height / 2, width: Self.listThumbSize.width, height: Self.listThumbSize.height)
        c.fill(roundedRect: thumb, radius: M.rInner, k.well)
        if gone {
            c.draw(icon: .warning, at: CGPoint(x: thumb.midX - 5.5, y: thumb.midY - 5.5), size: M.fCap, k.warning)
        } else {
            let box = thumb.insetBy(dx: M.s2 / 2, dy: M.s2 / 2)
            let ar = info.map { CGFloat($0.width) / CGFloat(Swift.max($0.height, 1)) } ?? 16 / 9
            let w = Swift.min(box.width, box.height * ar)
            let pic = CGRect(x: box.midX - w / 2, y: box.midY - w / ar / 2, width: w, height: w / ar)
            if let p = cardPoster(path: e.path) { c.draw(imageSlot: p.slot, in: pic, source: p.cropped(toFill: pic)) }
            else { c.fill(roundedRect: pic, radius: M.s1 / 2, k.poster) }
        }
        func text(_ s: String, _ x: CGFloat, _ w: CGFloat, _ color: DrawColor) {
            c.draw(s, in: CGRect(x: x, y: r.minY, width: w, height: r.height), fontSize: M.fLab, color)
        }
        c.draw(e.name, in: col.name, fontSize: M.fLab, gone ? t.label2 : t.label, face: c.medium)
        if gone {
            text("File not found", col.size, 110 + 64 + M.s3, k.warning)
            let b = CGRect(x: col.rate, y: r.midY - M.control / 2, width: 76, height: M.control)
            button(&c, t, k, "Locate…", b, primary: false, hover: false)
        } else {
            text(info?.size ?? "–", col.size, 110, t.label2); text(info?.aspect ?? "–", col.aspect, 64, t.label2)
            text(info?.rate ?? "–", col.rate, 92, t.label2); text(info?.length ?? "–", col.length, 64, t.label2)
        }
        text(StartLabels.relative(e.opened), col.edited, 96, t.label2)
        if hovering {
            c.draw(icon: .ellipsis, at: CGPoint(x: col.more.midX - M.fBody / 2, y: col.more.midY - M.fBody / 2), size: M.fBody, t.label2)
        }
    }

    private func cardText(_ c: inout Canvas, _ t: DrawTheme, _ name: String, _ subtitle: String, sub: DrawColor,
                          nameColor: DrawColor? = nil, below well: CGRect, _ r: CGRect) {
        let x = r.minX + M.s3, w = r.width - M.s3 - M.s1 - M.controlSmall
        c.draw(name, in: CGRect(x: x, y: well.maxY + M.thumbInset + M.s2, width: w, height: 16), fontSize: M.fBody, nameColor ?? t.label)
        c.draw(subtitle, in: CGRect(x: x, y: well.maxY + M.thumbInset + M.s2 + 18, width: w, height: 14), fontSize: M.fCap, sub)
    }

    /// `PosterWell`: the frame in its aspect on the well, badges for aspect and length, the missing-file states.
    private func posterWell(_ c: inout Canvas, _ t: DrawTheme, _ k: Colors, info: StartProjectInfo?, path: String?, gone: Bool, _ r: CGRect) {
        c.fill(roundedRect: r, radius: M.rCtl, k.well)
        let box = r.insetBy(dx: M.s3, dy: M.s3)
        let ar = info.map { CGFloat($0.width) / CGFloat(Swift.max($0.height, 1)) } ?? 16 / 9
        let w = Swift.min(box.width, box.height * ar), h = w / ar
        let pic = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: Swift.max(w, 0), height: Swift.max(h, 0))
        if !gone, let path, let p = cardPoster(path: path) {
            c.draw(imageSlot: p.slot, in: pic, source: p.cropped(toFill: pic))
        } else {
            c.fill(roundedRect: pic, radius: CGFloat(DrawTheme.Radius.small), k.poster)
            if !gone, info?.mediaMissing != true { c.draw(icon: .film, at: CGPoint(x: pic.midX - 6.5, y: pic.midY - 6.5), size: M.fBody, t.label3) }
        }
        if gone || info?.mediaMissing == true {
            c.draw(icon: gone ? .warning : .unlink, at: CGPoint(x: r.midX - 6.5, y: r.midY - 14), size: M.fBody, k.warning)
            c.draw(gone ? "File missing" : "Locate media…", in: CGRect(x: r.minX, y: r.midY + 2, width: r.width, height: 14),
                   fontSize: M.fCap, k.warning, align: .center)
        }
        guard let info, !gone, path != nil else { return }
        // Badges (`Badge`): aspect at the bottom left with its glyph, length at the bottom right.
        let aspectW = c.size(of: info.aspect, fontSize: M.fCap).width + 2 * M.s2 + 10 + M.s1
        let a = CGRect(x: r.minX + M.s2, y: r.maxY - M.s2 - M.badge, width: aspectW, height: M.badge)
        c.fill(roundedRect: a, radius: M.badge / 2, k.badge)
        let g = CGRect(x: a.minX + M.s2, y: a.midY - 5, width: 10, height: 10)
        let gw = ar >= 1 ? g.width : g.width * ar, gh = ar >= 1 ? g.height / ar : g.height
        c.stroke(roundedRect: CGRect(x: g.midX - gw / 2, y: g.midY - gh / 2, width: gw, height: gh), radius: 1, width: 1, k.badgeText)
        c.draw(info.aspect, in: CGRect(x: g.maxX + M.s1, y: a.minY, width: a.maxX - g.maxX, height: a.height), fontSize: M.fCap, k.badgeText)
        if info.seconds > 0 {
            let lw = c.size(of: info.length, fontSize: M.fCap).width + 2 * M.s2
            let l = CGRect(x: r.maxX - M.s2 - lw, y: a.minY, width: lw, height: M.badge)
            c.fill(roundedRect: l, radius: M.badge / 2, k.badge)
            c.draw(info.length, in: l, fontSize: M.fCap, k.badgeText, align: .center)
        }
    }

    /// `FrameGlyph`: a rectangle in the frame's aspect, fitted in `box`, in the video clip color.
    private func frameGlyph(_ c: inout Canvas, _ k: Colors, width: Int, height: Int, box: CGRect) {
        let ar = CGFloat(width) / CGFloat(Swift.max(height, 1))
        let w = ar >= 1 ? box.width : box.width * ar, h = ar >= 1 ? box.height / Swift.max(ar, 0.01) : box.height
        c.fill(roundedRect: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h), radius: CGFloat(DrawTheme.Radius.small), k.clipVideo)
    }
}
