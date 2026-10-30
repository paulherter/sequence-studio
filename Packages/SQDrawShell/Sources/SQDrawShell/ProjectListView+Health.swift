import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit

/// The Project panel's health line at the bottom (the Mac `ProjectHealthBar`): "312 in folder · 4 outside · 1 missing"
/// with a Fix… button; shown only while something needs attention. "outside" opens the Fix menu, "missing" filters the
/// list to Offline Media; Fix offers Collect (the host's `onCollect`), Reconnect (File > Reconnect Media…) and Show missing.
extension ProjectListView {
    static let healthHeight: CGFloat = 24
    static let healthGreen = DrawColor(hex: 0x30D158)

    public enum HealthPart: Equatable, Sendable { case inFolder, outside, missing, fix }

    var health: ProjectHealth { model?.health ?? ProjectHealth() }

    /// The line's rect (window points); nil while the project is healthy.
    var healthRect: CGRect? {
        guard model != nil, !health.isHealthy else { return nil }
        return CGRect(x: frame.minX, y: frame.maxY - Self.healthHeight, width: frame.width, height: Self.healthHeight)
    }

    static func healthTexts(_ h: ProjectHealth) -> [(HealthPart, String)] {
        var out: [(HealthPart, String)] = [(.inFolder, SQL10n.format("%@ in folder", String(h.inFolder)))]
        if h.outside > 0 { out.append((.outside, SQL10n.format("%@ outside", String(h.outside)))) }
        if h.missing > 0 { out.append((.missing, SQL10n.format("%@ missing", String(h.missing)))) }
        return out
    }

    /// The segments (dot + count) from the left and the Fix… button at the right, `Theme.Spacing.md` apart.
    func healthLayout(_ measure: TextMeasure) -> [(part: HealthPart, rect: CGRect)] {
        guard let r = healthRect else { return [] }
        let fs = CGFloat(DrawTheme.TypeSize.caption), g = CGFloat(DrawTheme.Spacing.sm)
        let fixW = ceil(measure.width(SQL10n.string("Fix…"), size: CGFloat(DrawTheme.TypeSize.body))) + 2 * CGFloat(DrawTheme.Spacing.md)
        let fix = CGRect(x: r.maxX - g - fixW, y: r.minY + 2, width: fixW, height: r.height - CGFloat(DrawTheme.Spacing.xs))
        var out: [(HealthPart, CGRect)] = []
        var x = r.minX + g
        for (part, text) in Self.healthTexts(health) {
            let w = ceil(measure.width("●", size: fs) + CGFloat(DrawTheme.Spacing.xs) + measure.width(text, size: fs))
            guard x + w <= fix.minX - g else { break }
            out.append((part, CGRect(x: x, y: r.minY, width: w, height: r.height)))
            x += w + CGFloat(DrawTheme.Spacing.md)
        }
        out.append((.fix, fix))
        return out
    }

    /// The Fix menu's rows for `h` (the Mac `ProjectHealthBar.menuItems`); Collect only when the host can collect.
    static func healthMenuItems(for h: ProjectHealth, canCollect: Bool, run: @escaping @MainActor (HealthPart) -> Void,
                                collect: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        if h.outside > 0, canCollect {
            rows.append(SQMenuItem(title: SQL10n.plural(h.outside, one: "Collect %@ file into project", other: "Collect %@ files into project"),
                                   action: { collect() }))
        }
        if h.missing > 0 {
            rows.append(SQMenuItem(title: SQL10n.plural(h.missing, one: "Reconnect %@ missing file…", other: "Reconnect %@ missing files…"),
                                   action: { run(.fix) }))
            rows.append(SQMenuItem(title: SQL10n.string("Show missing files"), action: { run(.missing) }))
        }
        return rows
    }

    func drawHealth(_ c: inout Canvas, theme t: DrawTheme) {
        guard let r = healthRect else { return }
        c.fill(r, t.panel)
        c.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1), t.separator)
        let fs = CGFloat(DrawTheme.TypeSize.caption)
        let w = t.palette.warning, warning = DrawColor(Float(w.r) / 255, Float(w.g) / 255, Float(w.b) / 255, Float(w.a))
        let texts = Dictionary(Self.healthTexts(health), uniquingKeysWith: { a, _ in a })
        for (part, rect) in healthLayout(TextMeasure(atlas: c.atlas, scale: c.scale)) {
            if part == .fix {
                InspectorDraw.button(&c, title: SQL10n.string("Fix…"), in: rect, hovering: healthHover == .fix, pressed: false, enabled: true, t)
                continue
            }
            let dot = part == .inFolder ? Self.healthGreen : part == .outside ? warning : Self.offlineRed
            let d: CGFloat = 6
            c.fill(ellipseIn: CGRect(x: rect.minX, y: rect.midY - d / 2, width: d, height: d), dot)
            let tx = rect.minX + d + CGFloat(DrawTheme.Spacing.xs)
            c.draw(texts[part] ?? "", in: CGRect(x: tx, y: rect.minY, width: max(rect.maxX - tx, 0), height: rect.height),
                   fontSize: fs, healthHover == part && part != .inFolder ? t.label : t.label2)
        }
    }

    /// The part under `p` (window points).
    func healthPart(at p: CGPoint) -> HealthPart? {
        guard healthRect?.contains(p) == true else { return nil }
        return healthLayout(host?.measure ?? TextMeasure(atlas: nil, scale: 1)).first { $0.rect.contains(p) }?.part
    }

    /// A click on the health line; true when it was on the line.
    func healthClick(at p: CGPoint) -> Bool {
        guard healthRect?.contains(p) == true else { return false }
        switch healthPart(at: p) {
        case .missing?: model?.mediaFilter = .offline
        case .outside?, .fix?:
            let fix = healthLayout(host?.measure ?? TextMeasure(atlas: nil, scale: 1)).first { $0.part == .fix }?.rect ?? .zero
            let items = Self.healthMenuItems(for: health, canCollect: onCollect != nil, run: { [weak self] part in
                guard let self else { return }
                if part == .missing { model?.mediaFilter = .offline } else { host?.spawn { [weak self] in await self?.host?.reconnectFromFoundFile() } }
            }, collect: { [weak self] in self?.onCollect?() })
            if !items.isEmpty { host?.menuBar.controller.present(items: items, at: CGPoint(x: fix.minX, y: fix.maxY), anchor: fix) }
        case .inFolder?, nil: break
        }
        return true
    }
}
