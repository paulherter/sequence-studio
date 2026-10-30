import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The start screen translated from the Mac `StartWindowView` (design "Start Screen B", `StartScreenTokens`): a top bar with
/// the search field, the rail (New project, Open…, the Browse tabs, Support card, "Open last project on launch", links),
/// one pane (Home, Recent, Templates, Learn) and a status bar. It covers the window under the menu bar while no project is
/// open (the Mac shows it as its own window and hides the editor). Same models: `RecentProjects.listing`, `StartLabels`,
/// `StartProjectInfo`, `ProjectTemplate.builtIn`, `TemplateFolder`, the Home row limit of `StartTemplatesModel`, the same keys
/// (`sq.start.tab`, `sq.start.sort`, `sq.reopenLastOnLaunch`).
/// Card pictures: the frame at the project's poster time of its poster media (`StartProjectInfo.posterPath`/`posterSeconds`,
/// the Mac `StartPosterLoader`), through the host's `ShellHost.startPoster` (Windows: the FFmpeg thumbnail atlas).
/// shortcut: no Appearance popover; template rename/delete only by right click (no hover … button).
@MainActor
public final class ShellStartScreen {
    public enum Tab: String, CaseIterable, Sendable {
        case home = "Home", recent = "Recent", templates = "Templates", learn = "Learn"
        var icon: SQIcon {
            switch self { case .home: .home; case .recent: .clock; case .templates: .group; case .learn: .book }
        }
    }
    public enum Sort: String, CaseIterable, Sendable { case opened = "Last opened", name = "Name", size = "Frame size" }

    /// What a press lands on.
    public enum Hit: Hashable, Sendable {
        case newProject, openOther, tab(Tab), reopenLast, appearance, feedback, support(SupportEntry), search, clearSearch, sort
        /// The grid / list toggle of Recent (`true` = list).
        case layout(Bool)
        case card(String), cardMore(String), continueOpen, quickSize(String), allFormats, template(String), lesson(Int)
    }

    /// One drawn part of the pane, in window points (scrolled).
    enum Element {
        case heading(String, CGRect, tile: Bool)
        case caption(String, CGRect)
        case tile(CGRect)
        case card(RecentProjects.Entry, CGRect)
        /// The list layout of Recent (`ListHeader`, `ProjectListRow`).
        case listHeader(CGRect)
        case listRow(RecentProjects.Entry, CGRect)
        case continueBox(RecentProjects.Entry, CGRect)
        case quick(ProjectTemplate?, CGRect)
        case templateCard(ProjectTemplate, CGRect)
        case lesson(Int, CGRect)
        case button(String, Hit, CGRect, primary: Bool)
    }

    // Start screen tokens (`StartScreenTokens`: Theme.Metrics.start*, Theme.Radius.start*, Theme.Typography.start*).
    enum M {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 20, s6: CGFloat = 24
        static let rail: CGFloat = 252, status: CGFloat = 28, gap: CGFloat = 8, top: CGFloat = 44, paneHeader: CGFloat = 56
        /// Room the Mac window buttons take at the left of the start window's top bar (`Theme.Metrics.startLights`).
        static let lights: CGFloat = 78
        static let control: CGFloat = 28, controlSmall: CGFloat = 24, row: CGFloat = 28, search: CGFloat = 260
        static let cardMin: CGFloat = 168, learnMin: CGFloat = 260, learnCard: CGFloat = 64, quickTile: CGFloat = 52
        static let thumb: CGFloat = 150, templateThumb: CGFloat = 120, thumbInset: CGFloat = 4, continueThumb: CGFloat = 190
        static let badge: CGFloat = 20, kvLabel: CGFloat = 64
        static let rCtl: CGFloat = 8, rInner: CGFloat = 6, rCard: CGFloat = 12
        static let fMini: CGFloat = 10, fCap: CGFloat = 11, fLab: CGFloat = 12, fBody: CGFloat = 13, fHead: CGFloat = 15, fTitle: CGFloat = 20
        /// Support card: title row, three lines of the tagline, padding.
        static let supportCard: CGFloat = 96
        /// Name and caption under a card picture.
        static let cardText: CGFloat = s2 + 16 + 2 + 14 + s3
    }

    /// Keys that reach the shell while the start screen is up (`ShellMenuBar.allowed` for a shown chooser).
    static let allowedCommands: Set<EditorCommand> = [.newProject, .openProject, .preferences, .keyboardShortcuts]

    static let tabKey = "sq.start.tab"
    static let sortKey = "sq.start.sort"
    static let listLayoutKey = "sq.start.listLayout"
    /// `AppController.reopenLastKey`.
    public static let reopenLastKey = "sq.reopenLastOnLaunch"

    /// `StartWindowView.lessons`: only the keyboard map has a page behind it.
    static let lessons: [(title: String, text: String, icon: SQIcon)] = [
        ("Keyboard map", "Every tool and its key.", .keyboard),
        ("Start from a template", "A size tile or a saved template makes the project in one click.", .openInSource),
        ("Keep your setup", "Save Current as Template keeps format, tracks and Looks for the next video.", .download),
        ("Fast Cut", "Choose it in New project for the magnetic timeline.", .zap),
        ("Outside files", "New project decides whether files from elsewhere are copied, moved or linked.", .folder),
        ("Drag an effect onto a clip", "Effects and transitions land where you drop them.", .sparkles),
        ("Continue", "The newest project is one click away in Home and Recent.", .playCircle),
    ]

    public weak var host: ShellHost?
    public let defaults: UserDefaults
    /// The area under the menu bar, window points.
    public var frame: CGRect = .zero
    /// The window bar the search field moves into (the Mac start window keeps its title and search in the title bar);
    /// nil: the screen's own top row holds the title and the search (Windows, whose bar ends in the caption buttons).
    public var barFrame: CGRect?
    /// Where the top bar's "Sequence Studio" starts: after the window buttons in the Mac start window (`startLights`).
    public var titleInset: CGFloat = M.s3
    public var tab: Tab { didSet { defaults.set(tab.rawValue, forKey: Self.tabKey); scroll = 0 } }
    public var sort: Sort { didSet { defaults.set(sort.rawValue, forKey: Self.sortKey) } }
    /// Recent as a list (`sq.start.listLayout`, the Mac key).
    public var listLayout: Bool { didSet { defaults.set(listLayout, forKey: Self.listLayoutKey); scroll = 0 } }
    /// Paths of recents whose file is gone: grayed, "Locate…".
    public var missing: Set<String> = []
    /// Frame size, rate and length per recent path (read in the background).
    public var infos: [String: StartProjectInfo] = [:]
    /// The user's templates (`TemplateFolder.standard`); the built-ins come first.
    public var userTemplates: [ProjectTemplate] = []
    /// The picture of the card of `path`: the poster media's frame at the poster time; nil while it is not decoded, when
    /// the project or its media is gone, or the project has no picture media.
    public func cardPoster(path: String) -> ProjectPoster? {
        guard !missing.contains(path), let info = infos[path], !info.mediaMissing, let media = info.posterPath else { return nil }
        return host?.startPoster?(media, info.posterSeconds)
    }
    /// Row chosen with Up/Down (nil = the newest, which Return opens).
    public internal(set) var selectedPath: String?
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    public internal(set) var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    public internal(set) var hover: Hit?
    var search = TextFieldControl()

    public init(host: ShellHost, defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
        tab = Tab(rawValue: defaults.string(forKey: Self.tabKey) ?? "") ?? .recent
        sort = Sort(rawValue: defaults.string(forKey: Self.sortKey) ?? "") ?? .opened
        listLayout = defaults.bool(forKey: Self.listLayoutKey)
        search.alignment = .left
        search.fontSize = M.fLab
    }

    // MARK: Model

    var recents: [RecentProjects.Entry] { host?.recents.entries ?? [] }
    public var query: String { search.editor?.string ?? search.text }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// `StartWindowView.shown`.
    public var shown: [RecentProjects.Entry] {
        let order: RecentProjects.Order = sort == .name ? .name : sort == .size ? .size : .opened
        return RecentProjects.listing(recents, query: query, order: order) { [infos] in infos[$0].map { $0.width * $0.height } }
    }
    var current: RecentProjects.Entry? { recents.first { !missing.contains($0.path) } }
    var highlightedPath: String? { selectedPath ?? current?.path }
    var builtIn: [ProjectTemplate] { ProjectTemplate.builtIn }
    public var reopenLast: Bool { defaults.bool(forKey: Self.reopenLastKey) }

    public func setQuery(_ s: String) {
        search.cancel()
        search.text = s
        queryChanged()
    }

    func queryChanged() {
        if !trimmedQuery.isEmpty, tab != .recent { tab = .recent }
        scroll = 0
    }

    // MARK: Layout

    var topBar: CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: barFrame == nil ? M.top : 0) }
    var statusBar: CGRect { CGRect(x: frame.minX, y: frame.maxY - M.status, width: frame.width, height: M.status) }
    var body: CGRect {
        CGRect(x: frame.minX, y: topBar.maxY, width: frame.width, height: max(statusBar.minY - topBar.maxY, 0)).insetBy(dx: M.gap, dy: M.gap)
    }
    var railRect: CGRect { CGRect(x: body.minX, y: body.minY, width: M.rail, height: body.height) }
    var paneRect: CGRect { CGRect(x: railRect.maxX + M.gap, y: body.minY, width: max(body.maxX - railRect.maxX - M.gap, 0), height: body.height) }
    var paneHeader: CGRect { CGRect(x: paneRect.minX, y: paneRect.minY, width: paneRect.width, height: M.paneHeader) }
    /// The scrolling part of the pane.
    var contentRect: CGRect {
        CGRect(x: paneRect.minX, y: paneHeader.maxY + M.s2, width: paneRect.width, height: max(paneRect.maxY - paneHeader.maxY - M.s2, 0))
    }
    var searchRect: CGRect {
        let bar = barFrame ?? topBar
        return CGRect(x: bar.maxX - M.s3 - M.search, y: (bar.midY - M.control / 2).rounded(), width: M.search, height: M.control)
    }
    var searchClearRect: CGRect { CGRect(x: searchRect.maxX - 22, y: searchRect.midY - 8, width: 16, height: 16) }

    /// The rail's buttons, tab rows and option rows.
    func railSpots() -> [(CGRect, Hit)] {
        let r = railRect.insetBy(dx: M.s2, dy: 0)
        var y = railRect.minY + M.s3
        var out: [(CGRect, Hit)] = []
        out.append((CGRect(x: r.minX, y: y, width: r.width, height: M.control), .newProject)); y += M.control + M.s2
        out.append((CGRect(x: r.minX, y: y, width: r.width, height: M.control), .openOther)); y += M.control + M.s4 + 16 + M.s1
        for t in Tab.allCases { out.append((CGRect(x: r.minX, y: y, width: r.width, height: M.row), .tab(t))); y += M.row + 2 }
        // `options`: the checkbox row (24 high), 4 gap, the link buttons (28 square, 2 apart), 4 in from the rail's inset.
        let links = railRect.maxY - M.s2 - M.control
        out.append((CGRect(x: r.minX + M.s1, y: links - M.s1 - M.controlSmall, width: r.width - M.s2, height: M.controlSmall), .reopenLast))
        var x = r.minX + M.s1
        for h in [Hit.appearance, .feedback] + SupportEntry.visible(discord: SupportLinks.discord).reversed().map({ Hit.support($0) }) {
            out.append((CGRect(x: x, y: links, width: M.control, height: M.control), h)); x += M.control + 2
        }
        return out
    }

    var supportCardRect: CGRect {
        let r = railRect.insetBy(dx: M.s2, dy: 0)
        let optionsTop = railRect.maxY - M.s2 - M.control - M.controlSmall - M.s1
        return CGRect(x: r.minX, y: optionsTop - M.s3 - M.supportCard, width: r.width, height: M.supportCard)
    }

    /// The card Pip peeks over (`SQMascotPlace.startProjects`, the Mac `supportCard` background) once there are projects;
    /// nil without projects. The host draws him: his bottom tucks `SQMascotPlace.peekTuck` behind the card's top edge, 16 in
    /// from its right edge.
    public var mascotCard: CGRect? { recents.isEmpty ? nil : supportCardRect }

    /// The empty Recent pane's Pip (`SQMascotPlace.startEmpty`, above the title): the point his bottom center sits on.
    public var emptyMascotBase: CGPoint? {
        guard tab == .recent, recents.isEmpty else { return nil }
        return CGPoint(x: contentRect.midX, y: contentRect.midY - 40 - M.s3)
    }

    /// `SortButton`: 12 + title + 8 + 11 pt chevron + 8, 28 high, 16 from the pane edge.
    var sortRect: CGRect {
        let w = ceil((host?.measure ?? TextMeasure(atlas: nil, scale: 1)).width(sort.rawValue, size: M.fLab)) + M.s3 + M.s2 + M.fCap + M.s2
        return CGRect(x: paneHeader.maxX - M.s4 - w, y: paneHeader.midY - M.control / 2, width: w, height: M.control)
    }

    /// `IconSegments`: two 28 x 24 segments in a 2 pt frame, 8 left of the sort button.
    var layoutToggleRect: CGRect {
        let w = 2 * M.control + 3 * M.s1 / 2 + M.s1 / 2
        return CGRect(x: sortRect.minX - M.s2 - w, y: paneHeader.midY - M.control / 2, width: w, height: M.control)
    }
    func layoutSegment(_ list: Bool) -> CGRect {
        let t = layoutToggleRect
        return CGRect(x: t.minX + 2 + (list ? M.control + 2 : 0), y: t.minY + 2, width: M.control, height: M.controlSmall)
    }

    /// `ListCol`: the right-hand columns of a list row (name takes the rest), `gapM` 12 apart, 8 inside the row.
    struct ListColumns {
        var name: CGRect, size: CGFloat, aspect: CGFloat, rate: CGFloat, length: CGFloat, edited: CGFloat, more: CGRect
    }
    static let listThumbSize = CGSize(width: 40, height: 32)
    static let listRowHeight: CGFloat = 44
    func listColumns(_ r: CGRect) -> ListColumns {
        let pad = M.s2, gap = M.s3
        var x = r.maxX - pad
        let more = CGRect(x: x - M.control, y: r.minY, width: M.control, height: r.height); x = more.minX - gap
        let edited = x - 96; x = edited - gap
        let length = x - 64; x = length - gap
        let rate = x - 92; x = rate - gap
        let aspect = x - 64; x = aspect - gap
        let size = x - 110; x = size - gap
        let nameX = r.minX + pad + Self.listThumbSize.width + gap
        return ListColumns(name: CGRect(x: nameX, y: r.minY, width: max(x - nameX, 0), height: r.height), size: size, aspect: aspect,
                           rate: rate, length: length, edited: edited, more: more)
    }

    /// Columns of an adaptive grid (`GridItem(.adaptive(minimum:))`): as many as fit, spread over the width.
    static func columns(width: CGFloat, min: CGFloat, spacing: CGFloat) -> (count: Int, width: CGFloat) {
        let n = Swift.max(1, Int((width + spacing) / (min + spacing)))
        return (n, (width - CGFloat(n - 1) * spacing) / CGFloat(n))
    }

    /// The pane's parts at scroll 0 and the content height.
    func paneLayout() -> (elements: [Element], height: CGFloat) {
        let x0 = contentRect.minX + M.s6, w = Swift.max(contentRect.width - 2 * M.s6, 0)
        var y = contentRect.minY
        var out: [Element] = []
        func grid<T>(_ items: [T], min: CGFloat, height: CGFloat, spacing: CGFloat, _ make: (T, CGRect) -> Element) {
            guard !items.isEmpty else { return }
            let (n, cw) = Self.columns(width: w, min: min, spacing: spacing)
            for (i, it) in items.enumerated() {
                out.append(make(it, CGRect(x: x0 + CGFloat(i % n) * (cw + spacing), y: y + CGFloat(i / n) * (height + spacing),
                                           width: cw, height: height)))
            }
            let rows = (items.count + n - 1) / n
            y += CGFloat(rows) * height + CGFloat(rows - 1) * spacing
        }
        func group(_ text: String, first: Bool) {
            y += first ? 0 : M.s5
            out.append(.heading(text, CGRect(x: x0, y: y, width: w, height: 16), tile: false))
            y += 16 + M.s3
        }
        let cardHeight = 2 * M.thumbInset + M.thumb + M.cardText
        let templateHeight = 2 * M.thumbInset + M.templateThumb + M.cardText
        switch tab {
        case .recent:
            let list = shown
            if recents.isEmpty || list.isEmpty { return ([], 0) }
            if listLayout {
                out.append(.listHeader(CGRect(x: x0, y: y, width: w, height: M.control)))
                y += M.control
                for e in list {
                    out.append(.listRow(e, CGRect(x: x0, y: y, width: w, height: Self.listRowHeight)))
                    y += Self.listRowHeight
                }
            } else if sort == .opened {
                let groups = StartLabels.groups.map { g in (g, list.filter { StartLabels.group($0.opened) == g }) }.filter { !$0.1.isEmpty }
                for (i, g) in groups.enumerated() {
                    group(g.0, first: i == 0)
                    grid(g.1, min: M.cardMin, height: cardHeight, spacing: M.s4) { .card($0, $1) }
                }
            } else {
                grid(list, min: M.cardMin, height: cardHeight, spacing: M.s4) { .card($0, $1) }
            }
        case .home:
            func tile(_ content: () -> Void) {
                let top = y
                let at = out.count
                y += M.s4
                content()
                y += M.s4
                out.insert(.tile(CGRect(x: x0, y: top, width: w, height: y - top)), at: at)
                y += M.s4
            }
            let inner = x0 + M.s4, iw = w - 2 * M.s4
            tile {
                out.append(.heading("Continue", CGRect(x: inner, y: y, width: iw, height: 20), tile: true)); y += 20 + M.s3
                if let last = current {
                    out.append(.continueBox(last, CGRect(x: inner, y: y, width: iw, height: M.continueThumb))); y += M.continueThumb
                } else {
                    out.append(.caption("Projects you open appear here.", CGRect(x: inner, y: y, width: iw, height: 16))); y += 16
                }
            }
            tile {
                out.append(.heading("Start from a size", CGRect(x: inner, y: y, width: iw, height: 20), tile: true)); y += 20 + M.s3
                out.append(.caption("Creates the project in the projects folder and opens it.", CGRect(x: inner, y: y, width: iw, height: 16)))
                y += 16 + M.s3
                let items: [ProjectTemplate?] = builtIn.map { Optional($0) } + [nil]
                let cw = (iw - M.s2) / 2
                for (i, t) in items.enumerated() {
                    out.append(.quick(t, CGRect(x: inner + CGFloat(i % 2) * (cw + M.s2), y: y + CGFloat(i / 2) * (M.quickTile + M.s2),
                                                width: cw, height: M.quickTile)))
                }
                let rows = (items.count + 1) / 2
                y += CGFloat(rows) * M.quickTile + CGFloat(rows - 1) * M.s2
            }
            // `StartTemplatesModel.yourTemplates` (SQEditorUI): the first four of the user's own.
            let yours = (shown: Array(userTemplates.prefix(4)), total: userTemplates.count)
            if !yours.shown.isEmpty {
                tile {
                    out.append(.heading("Your templates", CGRect(x: inner, y: y, width: iw, height: 20), tile: true)); y += 20 + M.s3
                    out.append(.caption("Click one, name the video, press Return.", CGRect(x: inner, y: y, width: iw, height: 16)))
                    y += 16 + M.s3
                    let (n, cw) = Self.columns(width: iw, min: M.cardMin, spacing: M.s4)
                    for (i, t) in yours.shown.enumerated() {
                        out.append(.templateCard(t, CGRect(x: inner + CGFloat(i % n) * (cw + M.s4), y: y + CGFloat(i / n) * (templateHeight + M.s4),
                                                           width: cw, height: templateHeight)))
                    }
                    let rows = (yours.shown.count + n - 1) / n
                    y += CGFloat(rows) * templateHeight + CGFloat(rows - 1) * M.s4
                }
            }
            y -= M.s4
        case .templates:
            group("Built in", first: true)
            grid(builtIn, min: M.cardMin, height: templateHeight, spacing: M.s4) { .templateCard($0, $1) }
            group("Yours", first: false)
            if userTemplates.isEmpty {
                out.append(.caption("Open a project and save its sequence as a template. It shows up here.", CGRect(x: x0, y: y, width: w, height: 16)))
                y += 16
            } else {
                grid(userTemplates, min: M.cardMin, height: templateHeight, spacing: M.s4) { .templateCard($0, $1) }
            }
        case .learn:
            grid(Array(Self.lessons.indices), min: M.learnMin, height: M.learnCard, spacing: M.s3) { .lesson($0, $1) }
        }
        return (out, y - contentRect.minY + M.s6)
    }

    /// The empty Recent pane (`emptyState`): title, text and its buttons, centered in the content.
    func emptyState() -> (title: String, text: String, buttons: [Element])? {
        guard tab == .recent, recents.isEmpty || shown.isEmpty else { return nil }
        let title = recents.isEmpty ? "No projects yet" : SQL10n.format("No projects match “%@”", trimmedQuery)
        let text = recents.isEmpty ? "Start with a frame size, or drop a video here and the project takes that clip's size and frame rate."
            : "Search looks at project names."
        let mid = CGPoint(x: contentRect.midX, y: contentRect.midY)
        let bw: CGFloat = 120
        let buttons: [Element] = recents.isEmpty
            ? [.button("New project", .newProject, CGRect(x: mid.x - bw - M.s1, y: mid.y + 24, width: bw, height: M.control), primary: true),
               .button("Open…", .openOther, CGRect(x: mid.x + M.s1, y: mid.y + 24, width: bw, height: M.control), primary: false)]
            : [.button("Clear search", .clearSearch, CGRect(x: mid.x - bw / 2, y: mid.y + 24, width: bw, height: M.control), primary: false)]
        return (title, text, buttons)
    }

    /// The pane's parts moved by the scroll.
    func scrolledElements() -> [Element] {
        if let e = emptyState() { return e.buttons }
        return paneLayout().elements.map { $0.offset(-scroll) }
    }

    /// The press target at `p` (window points).
    public func hit(at p: CGPoint) -> Hit? {
        guard frame.contains(p) || searchRect.contains(p) else { return nil }
        if searchRect.contains(p) { return !query.isEmpty && searchClearRect.contains(p) ? .clearSearch : .search }
        if railRect.contains(p) {
            return railSpots().first { $0.0.contains(p) }?.1
        }
        if tab == .recent, !recents.isEmpty {
            if sortRect.contains(p) { return .sort }
            if layoutToggleRect.contains(p) { return .layout(layoutSegment(true).contains(p) || (p.x > layoutSegment(false).maxX)) }
        }
        guard contentRect.contains(p) else { return nil }
        for e in scrolledElements() {
            switch e {
            case .card(let entry, let r) where r.contains(p):
                return moreRect(r).contains(p) ? .cardMore(entry.path) : .card(entry.path)
            case .listRow(let entry, let r) where r.contains(p):
                return listColumns(r).more.contains(p) ? .cardMore(entry.path) : .card(entry.path)
            case .continueBox(_, let r) where openRect(r).contains(p): return .continueOpen
            case .quick(let t, let r) where r.contains(p): return t.map { .quickSize($0.id) } ?? .allFormats
            case .templateCard(let t, let r) where r.contains(p): return .template(t.id)
            case .lesson(let i, let r) where r.contains(p): return Self.lessons[i].title == "Keyboard map" ? .lesson(i) : nil
            case .button(_, let h, let r, _) where r.contains(p): return h
            default: continue
            }
        }
        return nil
    }

    func moreRect(_ card: CGRect) -> CGRect {
        CGRect(x: card.maxX - M.s1 - M.controlSmall, y: card.maxY - M.cardText + M.s2 - 2, width: M.controlSmall, height: M.controlSmall)
    }

    func openRect(_ box: CGRect) -> CGRect {
        let textX = box.minX + M.continueThumb * 16 / 9 + M.s4
        return CGRect(x: textX, y: box.maxY - M.control, width: 96, height: M.control)
    }

    // MARK: Events

    /// Every event while the start screen is up (it is modal over the editor). `scale` turns pixels into points.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(Swift.max(scale, 0.01))
        if emptyState() == nil, scrollBody.scrollerEvent(e, scale: scale, viewport: contentRect, content: paneLayout().height) { return true }
        switch e {
        case .mouseDown(let x, let y, let m):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            let h = hit(at: p)
            if h != .search, search.isEditing { _ = search.commit() }
            guard let h else { return frame.contains(p) }
            if m.contains(.secondary) {
                if case .card(let path) = h { host?.menuBar.controller.present(items: recentMenu(path), at: p) }
                if case .template(let id) = h, let t = userTemplates.first(where: { $0.id == id }) {
                    host?.menuBar.controller.present(items: templateMenu(t), at: p)
                }
                return true
            }
            press(h, at: p)
            return true
        case .mouseMoved(let x, let y):
            hover = hit(at: CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
            return true
        case .scroll(let x, let y, _, let dy, _):
            guard contentRect.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) else { return true }
            let maxScroll = Swift.max(paneLayout().height - contentRect.height, 0)
            scrollBody.wheel(dy: dy, scale: k, maxOffset: maxScroll, extent: contentRect.height)
            return true
        case .keyDown(let key, let m):
            return keyDown(key, m)
        default:
            return true
        }
    }

    func keyDown(_ key: InputKey, _ m: InputModifiers) -> Bool {
        if search.isEditing {
            if key == .escape {
                if query.isEmpty { search.cancel() } else { setQuery(""); search.mouseDown() }
                return true
            }
            if key == .down || key == .up || key == .enter { _ = search.commit() } else {
                _ = search.key(key, modifiers: m)
                queryChanged()
                return true
            }
        }
        switch key {
        case .character("f") where m == .command, .character("F") where m == .command:
            search.mouseDown()
            return true
        case .escape:
            if let host, StartOverlayPolicy.escapeCloses(hasRealProject: !host.session.isEmptyUntitled) { host.hideStart() }
            return true
        case .up, .down:
            let list = shown.filter { !missing.contains($0.path) }
            guard !list.isEmpty else { return true }
            let i = list.firstIndex { $0.path == highlightedPath } ?? 0
            let next = Swift.min(Swift.max(i + (key == .down ? 1 : -1), 0), list.count - 1)
            selectedPath = list[next].path
            return true
        case .enter:
            if let path = highlightedPath { open(path) }
            return true
        default:
            return false
        }
    }

    func press(_ h: Hit, at p: CGPoint) {
        guard let host else { return }
        switch h {
        case .newProject: _ = host.execute(.newProject)
        case .openOther: _ = host.execute(.openProject)
        case .tab(let t): tab = t
        case .reopenLast: defaults.set(!reopenLast, forKey: Self.reopenLastKey)
        // shortcut: Appearance opens Preferences (its Appearance row) instead of the Mac popover; upgrade with a drawn popover.
        case .appearance: _ = host.execute(.preferences)
        case .feedback: host.perform(.sendFeedback)
        case .support(let s): host.perform(.support(s))
        case .search: search.mouseDown()
        case .clearSearch: setQuery("")
        case .sort:
            let items = Sort.allCases.map { s in SQMenuItem(title: s.rawValue, isChecked: s == sort) { [weak self] in self?.sort = s } }
            host.menuBar.controller.present(items: items, at: CGPoint(x: sortRect.minX, y: sortRect.maxY), pointer: p)
        case .layout(let list): listLayout = list
        case .card(let path): open(path)
        case .cardMore(let path): host.menuBar.controller.present(items: recentMenu(path), at: p)
        case .continueOpen: if let c = current { open(c.path) }
        case .quickSize(let id): if let t = builtIn.first(where: { $0.id == id }) { host.spawn { await host.quickCreate(t) } }
        case .allFormats: _ = host.execute(.newProject)
        case .template(let id):
            if let t = (builtIn + userTemplates).first(where: { $0.id == id }) { host.spawn { await host.quickCreate(t) } }
        case .lesson: _ = host.execute(.keyboardShortcuts)
        }
    }

    /// A card's click: open, or locate a project file that is gone.
    func open(_ path: String) {
        guard let host else { return }
        let url = URL(fileURLWithPath: path)
        if missing.contains(path) { host.spawn { await host.locateRecent(url) } } else { host.spawn { await host.openProject(at: url) } }
    }

    /// `StartWindowView.recentMenu`.
    func recentMenu(_ path: String) -> [SQMenuItem] {
        let gone = missing.contains(path), url = URL(fileURLWithPath: path)
        #if os(Windows)
        let reveal = "Show in Explorer"
        #else
        let reveal = "Reveal in Finder"
        #endif
        return [gone ? SQMenuItem(title: "Locate…") { [weak self] in self?.open(path) }
                     : SQMenuItem(title: "Open") { [weak self] in self?.open(path) },
                SQMenuItem(title: reveal, isEnabled: !gone) { [weak self] in self?.host?.revealFile?(url) },
                .separator,
                SQMenuItem(title: "Remove from Recents") { [weak self] in self?.host?.removeRecent(path: path) },
                SQMenuItem(title: "Remove All from Recents") { [weak self] in self?.host?.perform(.clearRecents) }]
    }

    /// `StartWindowView.templateMenu` for a saved template (a right click on its card; built-ins have no menu).
    func templateMenu(_ t: ProjectTemplate) -> [SQMenuItem] {
        [SQMenuItem(title: "Create Project") { [weak self] in self?.host?.spawn { await self?.host?.quickCreate(t) } },
         .separator,
         SQMenuItem(title: "Rename…") { [weak self] in self?.host?.spawn { await self?.host?.renameTemplate(t) } },
         SQMenuItem(title: "Delete Template") { [weak self] in self?.host?.deleteTemplate(t) }]
    }

    /// Reads the recents' files off the main thread (`pruneRecentsInBackground`): which are gone, frame size and length.
    public func reload() {
        let paths = recents.map(\.path)
        userTemplates = (host?.templateFolder ?? .standard).load()
        Task { [weak self] in
            let (gone, infos) = await Task.detached(priority: .utility) { () -> (Set<String>, [String: StartProjectInfo]) in
                let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
                return (gone, StartProjectInfo.read(paths.filter { !gone.contains($0) }))
            }.value
            self?.missing = gone
            self?.infos = infos
        }
    }
}

extension ShellStartScreen.Element {
    func offset(_ dy: CGFloat) -> Self {
        func o(_ r: CGRect) -> CGRect { r.offsetBy(dx: 0, dy: dy) }
        switch self {
        case .heading(let s, let r, let t): return .heading(s, o(r), tile: t)
        case .caption(let s, let r): return .caption(s, o(r))
        case .tile(let r): return .tile(o(r))
        case .card(let e, let r): return .card(e, o(r))
        case .listHeader(let r): return .listHeader(o(r))
        case .listRow(let e, let r): return .listRow(e, o(r))
        case .continueBox(let e, let r): return .continueBox(e, o(r))
        case .quick(let t, let r): return .quick(t, o(r))
        case .templateCard(let t, let r): return .templateCard(t, o(r))
        case .lesson(let i, let r): return .lesson(i, o(r))
        case .button(let s, let h, let r, let p): return .button(s, h, o(r), primary: p)
        }
    }
}

extension ShellHost {
    public var isStartShown: Bool { startScreen != nil }

    /// Window > Start Window, and the launch without a project.
    public func showStart(defaults: UserDefaults = .standard) {
        menuBar.controller.dismiss()
        let s = startScreen ?? ShellStartScreen(host: self, defaults: defaults)
        startScreen = s
        startDefaults = defaults
        startShownFor = session.project.id
        startShownEmpty = session.isEmptyUntitled
        startLayout()
        s.reload()
    }

    public func hideStart() { startScreen = nil }

    /// Launch: reopen the last project when the user asked for it (`reopenLastOnLaunch`), otherwise the start screen.
    public func presentStartAtLaunch(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: ShellStartScreen.reopenLastKey), let last = recents.entries.first,
           FileManager.default.fileExists(atPath: last.path) {
            spawn { await self.openProject(at: last.url) }
        } else {
            showStart(defaults: defaults)
        }
    }

    func startLayout() {
        if let own = startWindowSize {
            startScreen?.frame = CGRect(origin: .zero, size: own)
            startScreen?.barFrame = nil
            startScreen?.titleInset = ShellStartScreen.M.lights
            return
        }
        startScreen?.frame = CGRect(x: 0, y: menuBar.height, width: size.width, height: Swift.max(size.height - menuBar.height, 0))
        startScreen?.barFrame = startSearchInBar ? CGRect(x: 0, y: 0, width: size.width, height: menuBar.height) : nil
    }

    /// The start screen follows the project: it goes once a project is opened or created, and comes back after Close
    /// Project (the Mac `closeStartWindow` / `showStartWindow` calls in the file flows).
    public func syncStart() {
        let id = session.project.id, empty = session.isEmptyUntitled
        defer { startProjectID = id }
        if startScreen != nil {
            if !empty, id != startShownFor || startShownEmpty { hideStart() }
        } else if let last = startProjectID, last != id, empty {
            showStart(defaults: startDefaults)
        }
    }

    public func removeRecent(path: String) {
        recents.remove(path: path)
        saveRecents?(recents)
    }

    /// "Locate…" on a missing recent: choose the project file's new place; the entry moves there and the project opens.
    public func locateRecent(_ url: URL) async {
        guard let new = await files?.chooseProject() else { return }
        recents.relocate(path: url.standardizedFileURL.path, to: new)
        saveRecents?(recents)
        startScreen?.missing.remove(url.standardizedFileURL.path)
        await openProject(at: new)
    }

    /// `AppController.quickCreate`: a size tile or a template card makes "Untitled" (a free name) in the projects folder;
    /// a user template asks for the video's name first.
    public func quickCreate(_ template: ProjectTemplate) async {
        guard await confirmDiscardChanges() else { return }
        let parent = StorageLocations.load().projectsRoot
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        func free(_ base: String) -> String {
            MediaManagement.freeFolderName(base) { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
        }
        var name = free("Untitled")
        if template.id.hasPrefix("user-") {
            let d = ShellDialog("Name this video", informative: SQL10n.format("From “%@”. Its folder is created in the projects folder.", template.name))
            d.form = ShellForm([.field(id: "name", label: "Name", value: name)])
            d.addButton("Create")
            d.addButton("Cancel", role: .cancel)
            guard await ask(d) == .first else { return }
            let typed = (d.form?.text("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            name = free(typed.isEmpty ? name : typed)
        }
        await createProject(ShellNewProjectAnswer(name: name, template: template, mode: nil, location: parent, editMode: nil))
    }
}
