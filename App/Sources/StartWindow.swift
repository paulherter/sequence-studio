import AppKit
import SQCore
import SQEditorSession
import SQEditorUI
import SQUIKit
import SwiftUI

// Start screen measurements (design "Start Screen B", StartScreenTokens): spacing scale, radii, type sizes.
private let gapXS = Theme.Metrics.startS1, gapS = Theme.Metrics.startS2, gapM = Theme.Metrics.startS3
private let gapL = Theme.Metrics.startS4, gapXL = Theme.Metrics.startS5, gapXXL = Theme.Metrics.startS6
private let hairGap = Theme.Spacing.xxs, ringOutset = Theme.Spacing.xxs / 2
private let rCtl = Theme.Radius.startControl, rInner = Theme.Radius.startInner, rCard = Theme.Radius.startCard
private let hCtl = Theme.Metrics.startControl, hSmall = Theme.Metrics.startControlSmall

/// Start screen type: tabular digits, design sizes.
private func sf(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font { Font(Theme.Typography.start(size, weight)) }
private let fCap = Theme.Typography.startCaption, fLab = Theme.Typography.startLabel, fBody = Theme.Typography.startBody
private let fTitle = Theme.Typography.startTitle

/// Start screen colors (design B names → Theme). Translucent fills sit on the panel, which gives the design's opaque
/// `raisedSoft` (panel + 6 % ink) and `raisedSoftHover` (+ 8 %).
private enum SC {
    static let canvas = Quiet.color(Theme.Colors.canvas)
    static let frame = Quiet.color(Theme.Colors.titlebar)
    static let panel = Quiet.color(Theme.Colors.panel)
    static let well = Quiet.color(Theme.Colors.content)
    static let raised = Quiet.color(Theme.Colors.overlay)
    static let soft = Quiet.color(Theme.Colors.fill2)
    static let softHover = Quiet.color(Theme.State.rowHover)
    static let pressed = Quiet.color(Theme.Colors.fillHover)
    static let field = Quiet.color(Theme.Colors.field)
    static let poster = Quiet.color(Theme.Colors.fill)
    static let accent = Quiet.color(Theme.Colors.accent)
    static let accentFill = Quiet.color(Theme.Colors.accentFill)
    static let focusRing = Quiet.color(Theme.Colors.focusRing)
    static let warning = Quiet.color(Theme.Colors.warning)
    static let support = Quiet.color(Theme.Colors.support)
    static let badge = Color.black.opacity(Theme.Metrics.startBadgeAlpha)
    static let badgeText = Color.white.opacity(0.92)
}

/// Start screen (design "Start Screen B"): top bar with search, a left rail (New project, Open, Import, Browse tabs,
/// Support, options and links) and one pane on the right (Home, Recent, Templates, Learn), on the canvas, plus a status bar.
/// New project opens the New Project sheet; a size tile or a template card creates the project in one click.
struct StartWindowView: View {
    enum Tab: String, CaseIterable { case home = "Home", recent = "Recent", templates = "Templates", learn = "Learn"
        var symbol: SQIcon {
            switch self {
            case .home: .home
            case .recent: .clock
            case .templates: .group
            case .learn: .book
            }
        }
    }

    enum Sort: String, CaseIterable { case opened = "Last opened", name = "Name", size = "Frame size" }

    /// Date wording of the cards (shared with the portable start screen: SQEditorSession `StartLabels`).
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        StartLabels.day(date, now: now, calendar: calendar)
    }
    static func groupLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        StartLabels.group(date, now: now, calendar: calendar)
    }
    static func relativeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        StartLabels.relative(date, now: now, calendar: calendar)
    }

    var templates: [ProjectTemplate]
    var recents: [RecentProjects.Entry]
    /// Paths of recents whose file is gone: grayed, with "Locate…".
    var missing: Set<String> = []
    /// Frame size, rate and length per recent path (filled in the background; cards show what is known).
    var infos: [String: StartProjectInfo] = [:]
    /// First-frame stills per recent path (loaded in the background; a card without one shows the neutral poster fill).
    var posters: [String: CGImage] = [:]
    var onNewProject: () -> Void = {}
    var onImportPremiere: () -> Void = {}
    var onCreate: (ProjectTemplate) -> Void
    var onOpen: (URL) -> Void
    var onOpenOther: () -> Void
    var onDeleteTemplate: (ProjectTemplate) -> Void
    var onRenameTemplate: (ProjectTemplate) -> Void = { _ in }
    var onLocateRecent: (URL) -> Void = { _ in }
    var onRemoveRecent: (URL) -> Void
    var onClearRecents: () -> Void
    /// "Save Current as Template": nil when no project is open (the button is hidden).
    var onSaveTemplate: (() -> Void)? = nil
    var reopenLast: Bool = false
    var onSetReopenLast: (Bool) -> Void = { _ in }
    /// Support links in the rail. Discord is nil (hidden) until its URL exists.
    var supportEntries: [SupportEntry] = SupportEntry.visible(discord: nil)
    var onSupportEntry: (SupportEntry) -> Void = { _ in }
    /// The feedback icon in the link row (Help > Send Feedback).
    var onFeedback: () -> Void = {}
    /// Learn > Keyboard map.
    var onKeyboardMap: () -> Void = {}
    /// The appearance link: shows the Appearance popover at this rect (start window content coordinates, top-left origin).
    var onAppearance: ((CGRect) -> Void)? = nil
    /// Row chosen with Up/Down (nil = the newest, which "Continue" opens).
    var selectedPath: String? = nil

    /// Stored, so the open tab survives the rebuild an Appearance change causes.
    @AppStorage("sq.start.tab") private var tabRaw = Tab.recent.rawValue
    @State private var query = ""
    @State private var appearanceAnchor: CGRect = .zero
    /// Bumped by ⌘F; the search field takes focus when it changes.
    @State private var searchFocusTick = 0
    @AppStorage("sq.start.listLayout") private var listLayout = false
    @AppStorage("sq.start.sort") private var sortRaw = Sort.opened.rawValue

    private var tab: Tab {
        get { Tab(rawValue: tabRaw) ?? .recent }
        nonmutating set { tabRaw = newValue.rawValue }
    }
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .opened }
    private var builtIn: [ProjectTemplate] { templates.filter { ProjectTemplate.builtIn.map(\.id).contains($0.id) } }
    private var user: [ProjectTemplate] { templates.filter { !ProjectTemplate.builtIn.map(\.id).contains($0.id) } }
    private var current: RecentProjects.Entry? { recents.first(where: { !missing.contains($0.path) }) }
    private var highlightedPath: String? { selectedPath ?? current?.path }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var shown: [RecentProjects.Entry] {
        let order: RecentProjects.Order = sort == .name ? .name : sort == .size ? .size : .opened
        return RecentProjects.listing(recents, query: query, order: order) { path in infos[path].map { $0.width * $0.height } }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: Theme.Metrics.startGap) {
                rail.frame(width: Theme.Metrics.startRail).frame(maxHeight: .infinity)
                pane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: rCard).fill(SC.panel))
                    .clipShape(RoundedRectangle(cornerRadius: rCard))
            }
            .padding(Theme.Metrics.startGap)
            .background(SC.canvas)
            statusBar
        }
        .background(SC.canvas)
        .frame(minWidth: Theme.Metrics.startWindowMinSize.width, minHeight: Theme.Metrics.startWindowMinSize.height)
        .ignoresSafeArea()
        .preferredColorScheme(ThemeAppearance.shared.settings.mode == .light ? .light : .dark)
        .onChange(of: query) { _, q in if !q.trimmingCharacters(in: .whitespaces).isEmpty { tab = .recent } }
        .background { shortcutCatcher }
    }

    /// ⌘F focuses the search field (the menus own ⌘N and ⌘O).
    private var shortcutCatcher: some View {
        Button("") { searchFocusTick += 1 }.keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Top bar and status bar

    private var topBar: some View {
        HStack(spacing: gapM) {
            Text("Sequence Studio").font(sf(fCap)).foregroundStyle(Quiet.label2)
            Spacer(minLength: gapM)
            searchField
        }
        .padding(.leading, Theme.Metrics.startLights).padding(.trailing, gapM)
        .frame(height: Theme.Metrics.startTop)
        .background(SC.frame)
    }

    private var searchField: some View {
        StartSearchField(text: $query, focusTick: searchFocusTick)
            .frame(width: Theme.Metrics.startSearch, height: hCtl)
            .overlay(alignment: .trailing) {
                if query.isEmpty {
                    Text("⌘F").font(sf(fCap, .medium)).foregroundStyle(Quiet.label3)
                        .padding(.trailing, gapM).allowsHitTesting(false)
                }
            }
    }

    private var statusBar: some View {
        HStack(spacing: gapL) {
            Text("Projects folder: \((StorageLocations.load().projectsRoot.path as NSString).abbreviatingWithTildeInPath)")
            Text(recents.count == 1 ? "1 project" : "\(recents.count) projects")
            Spacer(minLength: 0)
            Text("No project open")
            Text("Sequence Studio \(Self.versionLabel)")
        }
        .font(sf(fCap)).foregroundStyle(Quiet.label3).lineLimit(1)
        .padding(.horizontal, gapL)
        .frame(height: Theme.Metrics.startStatus)
        .background(SC.frame)
    }

    static var versionLabel: String { AppVersion.display }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: hairGap) {
            VStack(spacing: gapS) {
                StartButton(title: "New project", symbol: .plus, hint: "⌘N", style: .primary, action: onNewProject)
                StartButton(title: "Open…", symbol: .folder, hint: "⌘O", style: .raised, action: onOpenOther)
            }
            .padding(.bottom, gapL)
            Text("Browse").font(sf(fCap, .semibold)).foregroundStyle(Quiet.label3)
                .padding(.horizontal, gapM).padding(.bottom, gapXS)
            ForEach(Tab.allCases, id: \.self) { t in
                RailRow(title: t.rawValue, symbol: t.symbol, count: t == .recent && !recents.isEmpty ? recents.count : nil,
                        current: tab == t) { tab = t }
            }
            Spacer(minLength: gapM)
            supportCard
            options
        }
        .padding(.top, gapM).padding(.horizontal, gapS).padding(.bottom, gapS)
    }

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: gapS) {
            HStack(spacing: gapS) {
                SQIcon.heart.swiftUIImage(size: fLab).foregroundStyle(SC.support)
                Text(SupportEntry.support.menuTitle).font(sf(fLab, .bold)).foregroundStyle(Quiet.label)
            }
            Text(SupportLinks.tagline).font(sf(fLab)).foregroundStyle(Quiet.label2)
                .lineSpacing(fLab * 0.45 - (fLab * 0.2)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(gapM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: rCard).fill(SC.soft))
        .background(alignment: .topTrailing) {   // M2: Pip peeks over the card edge once there are projects; later background = drawn behind, so the card hides his lower part
            if !recents.isEmpty {
                SQMascotPlaceView(.startProjects).padding(.trailing, gapL)
                    .offset(y: -((SQMascotPlace.startProjects.makeView()?.intrinsicContentSize.height ?? 0) - SQMascotPlace.peekTuck))
            }
        }
        .padding(.bottom, gapM)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: gapXS) {
            HStack(spacing: gapS) {
                SQCheckboxView(isOn: Binding(get: { reopenLast }, set: onSetReopenLast))
                    .frame(width: Theme.Metrics.checkbox, height: Theme.Metrics.checkbox)
                Text("Open last project on launch").font(sf(fLab)).foregroundStyle(Quiet.label2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: hSmall)
            .sqHelp("Skips this screen and reopens what you worked on last. Also in Preferences.")
            HStack(spacing: hairGap) {
                LinkButton(symbol: .contrast, tip: "Appearance", tint: Quiet.label2) {
                    onAppearance?(appearanceAnchor)
                }
                .background(GeometryReader { g in
                    Color.clear.onAppear { appearanceAnchor = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in appearanceAnchor = f }
                })
                LinkButton(symbol: .mail, tip: "Send feedback or report a bug", tint: Quiet.label2, action: onFeedback)
                ForEach(supportEntries.filter { $0 != .support }, id: \.self) { e in
                    LinkButton(symbol: e == .github ? .code : .discord,
                               tip: e.menuTitle, tint: Quiet.label2) { onSupportEntry(e) }
                }
                LinkButton(symbol: .heart, tip: "Support Sequence Studio to keep it free.", tint: SC.support) { onSupportEntry(.support) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, gapXS)
    }

    // MARK: Pane

    @ViewBuilder private var pane: some View {
        switch tab {
        case .home: home
        case .recent: recent
        case .templates: templatesPane
        case .learn: learn
        }
    }

    private func header(_ title: String, count: Int? = nil, @ViewBuilder tools: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: gapS) {
            Text(title).font(sf(fTitle, .semibold)).foregroundStyle(Quiet.label)
            if let count { Text("\(count)").font(sf(fLab)).foregroundStyle(Quiet.label3) }
            Spacer(minLength: 0)
            tools()
        }
        .padding(.leading, gapXXL).padding(.trailing, gapL).padding(.vertical, gapS)
        .frame(minHeight: Theme.Metrics.startPaneHeader)
        .padding(.bottom, gapS)
    }

    private func scroll<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { body() }
                .padding(.horizontal, gapXXL).padding(.bottom, gapXXL)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func groupLabel(_ text: String, first: Bool = false, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Text(text).font(sf(fLab, .semibold)).foregroundStyle(Quiet.label2)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.top, first ? .zero : gapXL).padding(.bottom, gapM)
    }

    private static let cardColumns = [GridItem(.adaptive(minimum: Theme.Metrics.startCardMin, maximum: .infinity), spacing: Theme.Metrics.startS4, alignment: .top)]
    private static let learnColumns = [GridItem(.adaptive(minimum: Theme.Metrics.startLearnMin), spacing: Theme.Metrics.startS3, alignment: .top)]

    // MARK: Recent

    private var recent: some View {
        VStack(spacing: 0) {
            header("Recent", count: recents.isEmpty ? nil : shown.count) {
                if !recents.isEmpty {
                    IconSegments(symbols: [.grid, .list], tips: ["Grid", "List"],
                                 selection: Binding(get: { listLayout ? 1 : 0 }, set: { listLayout = $0 == 1 }))
                    SortButton(title: sort.rawValue) { sortMenu }
                }
            }
            if recents.isEmpty {
                emptyState("No projects yet",
                           "Start with a frame size, or drop a video here and the project takes that clip's size and frame rate.",
                           secondary: ("Open…", onOpenOther), mascot: .startEmpty)
            } else if shown.isEmpty {
                emptyState("No projects match “\(trimmedQuery)”", "Search looks at project names.", primary: ("Clear search", { query = "" }))
            } else if listLayout {
                scroll { recentList }
            } else {
                scroll { recentGrid }
            }
        }
    }

    private var sortMenu: [SQMenuItem] {
        Sort.allCases.map { s in SQMenuItem(title: s.rawValue, isChecked: s == sort) { sortRaw = s.rawValue } }
    }

    @ViewBuilder private var recentGrid: some View {
        if sort == .opened {
            let groups = ["Today", "This week", "Earlier"].map { g in (g, shown.filter { Self.groupLabel($0.opened) == g }) }
                .filter { !$0.1.isEmpty }
            ForEach(Array(groups.enumerated()), id: \.element.0) { i, g in
                groupLabel(g.0, first: i == 0)
                cards(g.1)
            }
        } else {
            cards(shown)
        }
    }

    private func cards(_ items: [RecentProjects.Entry]) -> some View {
        LazyVGrid(columns: Self.cardColumns, alignment: .leading, spacing: gapL) {
            ForEach(items) { e in
                ProjectCard(entry: e, info: infos[e.path], poster: posters[e.path], gone: missing.contains(e.path), selected: e.path == highlightedPath,
                            open: { open(e) }, menu: { recentMenu(e) })
            }
        }
    }

    private var recentList: some View {
        VStack(spacing: 0) {
            ListHeader()
            ForEach(shown) { e in
                ProjectListRow(entry: e, info: infos[e.path], poster: posters[e.path], gone: missing.contains(e.path), selected: e.path == highlightedPath,
                               open: { open(e) }, menu: { recentMenu(e) })
            }
        }
    }

    private func open(_ e: RecentProjects.Entry) {
        if missing.contains(e.path) { onLocateRecent(e.url) } else { onOpen(e.url) }
    }

    private func recentMenu(_ e: RecentProjects.Entry) -> [SQMenuItem] {
        let gone = missing.contains(e.path)
        return [gone ? SQMenuItem(title: "Locate…") { onLocateRecent(e.url) }
                     : SQMenuItem(title: "Open") { onOpen(e.url) },
                SQMenuItem(title: "Reveal in Finder", isEnabled: !gone) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) },
                .separator,
                SQMenuItem(title: "Remove from Recents") { onRemoveRecent(e.url) },
                SQMenuItem(title: "Remove All from Recents") { onClearRecents() }]
    }

    private func emptyState(_ title: String, _ text: String, primary: (String, () -> Void)? = nil,
                            secondary: (String, () -> Void)? = nil, mascot: SQMascotPlace? = nil) -> some View {
        VStack(spacing: gapM) {
            if let mascot { SQMascotPlaceView(mascot) }
            Text(title).font(sf(Theme.Typography.startHeading, .semibold)).foregroundStyle(Quiet.label)
            Text(text).font(sf(fLab)).foregroundStyle(Quiet.label3).multilineTextAlignment(.center)
                .frame(maxWidth: Theme.Metrics.startSearch + emptyTextExtra)
            HStack(spacing: gapS) {
                if let primary {
                    StartButton(title: primary.0, style: .raised, fixed: true, action: primary.1)
                } else {
                    StartButton(title: "New project", symbol: .plus, style: .primary, fixed: true, action: onNewProject)
                }
                if let secondary { StartButton(title: secondary.0, style: .raised, fixed: true, action: secondary.1) }
            }
            .padding(.top, gapXS)
        }
        .padding(gapXXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Home

    private var home: some View {
        VStack(spacing: 0) {
            header("Home")
            scroll {
                VStack(alignment: .leading, spacing: gapL) {
                    continueTile
                    sizesTile
                    if !yourRow.shown.isEmpty { yourTemplatesTile }
                }
            }
        }
    }

    private var continueTile: some View {
        tile {
            Text("Continue").font(sf(Theme.Typography.startHeading, .semibold)).foregroundStyle(Quiet.label)
            if let last = current {
                HStack(alignment: .top, spacing: gapL) {
                    PosterWell(info: infos[last.path], gone: false, height: Theme.Metrics.startContinueThumb)
                        .frame(width: Theme.Metrics.startContinueThumb * 16 / 9)
                    VStack(alignment: .leading, spacing: gapS) {
                        Text(last.name).font(sf(Theme.Typography.startHeading, .semibold)).foregroundStyle(Quiet.label).lineLimit(1)
                        kv("Frame", infos[last.path].map { "\($0.size) · \($0.aspect)" } ?? "–")
                        kv("Rate", infos[last.path]?.rate ?? "–")
                        kv("Length", infos[last.path]?.length ?? "–")
                        kv("Edited", Self.relativeLabel(last.opened))
                        Spacer(minLength: gapS)
                        StartButton(title: "Open", hint: "⏎", style: .primary, fixed: true) { onOpen(last.url) }
                    }
                    .frame(maxHeight: Theme.Metrics.startContinueThumb, alignment: .topLeading)
                }
            } else {
                Text("Projects you open appear here.").font(sf(fLab)).foregroundStyle(Quiet.label3)
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: gapS) {
            Text(k).font(sf(fLab)).foregroundStyle(Quiet.label3).frame(width: Theme.Metrics.startAppearanceLabel - gapL, alignment: .leading)
            Text(v).font(sf(fLab)).foregroundStyle(Quiet.label).lineLimit(1)
        }
    }

    private var sizesTile: some View {
        tile {
            Text("Start from a size").font(sf(Theme.Typography.startHeading, .semibold)).foregroundStyle(Quiet.label)
            Text("Creates the project in Movies/Sequence Studio and opens it.").font(sf(fLab)).foregroundStyle(Quiet.label3)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: gapS), GridItem(.flexible(), spacing: gapS)], alignment: .leading, spacing: gapS) {
                ForEach(builtIn) { t in QuickSizeTile(template: t) { onCreate(t) } }
                QuickSizeTile(template: nil, action: onNewProject)
            }
        }
    }

    private var yourRow: (shown: [ProjectTemplate], total: Int) { StartTemplatesModel.yourTemplates(from: templates) }

    /// Home row "Your templates": click a card, type a name, Return (the copy goes to the projects folder).
    private var yourTemplatesTile: some View {
        tile {
            HStack {
                Text("Your templates").font(sf(Theme.Typography.startHeading, .semibold)).foregroundStyle(Quiet.label)
                Spacer()
                if yourRow.total > yourRow.shown.count {
                    StartButton(title: "All templates", style: .raised, fixed: true) { tab = .templates }
                }
            }
            Text("Click one, name the video, press Return.").font(sf(fLab)).foregroundStyle(Quiet.label3)
            templateGrid(yourRow.shown)
        }
    }

    private func tile<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: gapM) { c() }
            .padding(gapL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: rCard).fill(SC.soft))
    }

    // MARK: Templates

    private var templatesPane: some View {
        VStack(spacing: 0) {
            header("Templates")
            scroll {
                groupLabel("Built in", first: true)
                templateGrid(builtIn)
                groupLabel("Yours") {
                    if let save = onSaveTemplate { StartButton(title: "Save Current as Template…", style: .raised, fixed: true, action: save) }
                }
                if user.isEmpty {
                    Text("Open a project and save its sequence as a template. It shows up here.").font(sf(fLab)).foregroundStyle(Quiet.label3)
                } else {
                    templateGrid(user)
                }
            }
        }
    }

    private func templateGrid(_ list: [ProjectTemplate]) -> some View {
        LazyVGrid(columns: Self.cardColumns, alignment: .leading, spacing: gapL) {
            ForEach(list) { t in
                TemplateCard(template: t, isBuiltIn: ProjectTemplate.builtIn.contains { $0.id == t.id }, create: { onCreate(t) },
                             menu: { templateMenu(t) })
            }
        }
    }

    private func templateMenu(_ t: ProjectTemplate) -> [SQMenuItem] {
        guard !ProjectTemplate.builtIn.contains(where: { $0.id == t.id }) else { return [SQMenuItem(title: "Create Project") { onCreate(t) }] }
        return [SQMenuItem(title: "Create Project") { onCreate(t) }, .separator,
                SQMenuItem(title: "Rename…") { onRenameTemplate(t) }, SQMenuItem(title: "Delete Template") { onDeleteTemplate(t) }]
    }

    // MARK: Learn

    private struct Lesson: Identifiable {
        var title: String, text: String, symbol: SQIcon
        var id: String { title }
    }

    /// Short tips in the app's own words. Only the keyboard map has a page behind it; the rest is read in the card.
    private static let lessons = [
        Lesson(title: "Keyboard map", text: "Every tool and its key.", symbol: .keyboard),
        Lesson(title: "Start from a template", text: "A size tile or a saved template makes the project in one click.", symbol: .openInSource),
        Lesson(title: "Keep your setup", text: "Save Current as Template keeps format, tracks and Looks for the next video.", symbol: .download),
        Lesson(title: "Fast Cut", text: "Choose it in New project for the magnetic timeline.", symbol: .zap),
        Lesson(title: "Outside files", text: "New project decides whether files from elsewhere are copied, moved or linked.", symbol: .folder),
        Lesson(title: "Drag an effect onto a clip", text: "Effects and transitions land where you drop them.", symbol: .sparkles),
        Lesson(title: "Continue", text: "The newest project is one click away in Home and Recent.", symbol: .playCircle),
    ]

    private var learn: some View {
        VStack(spacing: 0) {
            header("Learn")
            scroll {
                LazyVGrid(columns: Self.learnColumns, alignment: .leading, spacing: gapM) {
                    ForEach(Self.lessons) { l in
                        LearnCard(title: l.title, text: l.text, symbol: l.symbol,
                                  action: l.title == "Keyboard map" ? onKeyboardMap : nil)
                    }
                }
            }
        }
    }
}

/// Width the empty-state sentence may take beyond the search field width (keeps it to two lines).
private let emptyTextExtra = Theme.Metrics.startS7 * 4

// MARK: - Parts

/// Start screen button (`.btn`): 28 high, 8 radius, 12 pt medium; leading icon, the key hint pushed to the right.
private struct StartButton: View {
    enum Style { case primary, raised, ghost }
    var title: String
    var symbol: SQIcon? = nil
    var hint: String? = nil
    var style: Style
    /// Sized to its content (empty states, tiles) instead of the rail width.
    var fixed = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: gapS) {
                if let symbol { symbol.swiftUIImage(size: fLab) }
                Text(title).font(sf(fLab, .medium)).lineLimit(1)
                if !fixed { Spacer(minLength: 0) }
                if let hint {
                    Text(hint).font(sf(fCap, .medium))
                        .foregroundStyle(style == .primary ? AnyShapeStyle(Color.white.opacity(0.78)) : AnyShapeStyle(Quiet.label3))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, gapM)
            .frame(maxWidth: fixed ? nil : .infinity, minHeight: hCtl, maxHeight: hCtl)
            .background(RoundedRectangle(cornerRadius: rCtl).fill(background))
            .overlay { if hovering, style != .primary { RoundedRectangle(cornerRadius: rCtl).fill(SC.soft) } }
            .brightness(hovering && style == .primary ? 0.06 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: fixed, vertical: true)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: .white
        case .raised: Quiet.label
        case .ghost: hovering ? Quiet.label : Quiet.label2
        }
    }

    private var background: Color {
        switch style {
        case .primary: SC.accentFill
        case .raised: SC.raised
        case .ghost: .clear
        }
    }
}

/// One Browse row of the rail (`.rl`): 28 high, 8 radius, 13 pt; hover fill, the open tab pressed fill and medium weight.
private struct RailRow: View {
    var title: String
    var symbol: SQIcon
    var count: Int?
    var current: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Metrics.startIconGap) {
                symbol.swiftUIImage(size: fLab).frame(width: gapL)
                Text(title).font(sf(fLab, current ? .medium : .regular))
                Spacer(minLength: 0)
                if let count { Text("\(count)").font(sf(fCap)).foregroundStyle(Quiet.label3) }
            }
            .foregroundStyle(current || hovering ? Quiet.label : Quiet.label2)
            .padding(.horizontal, gapM)
            .frame(maxWidth: .infinity, minHeight: hCtl, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: rCtl).fill(current ? SC.pressed : hovering ? SC.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Icon-only link button (`.ibtn`): 28 square, 8 radius, SQ tooltip.
private struct LinkButton: View {
    var symbol: SQIcon
    var tip: String
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            symbol.swiftUIImage(size: fBody).foregroundStyle(tint)
                .frame(width: hCtl, height: hCtl)
                .background(RoundedRectangle(cornerRadius: rCtl).fill(hovering ? SC.soft : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .sqHelp(tip)
    }
}

/// Segmented icon toggle (`.seg.ic`): field background, 2 px padding; 24 x 28 segments, the chosen one raised.
private struct IconSegments: View {
    var symbols: [SQIcon]
    var tips: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: hairGap) {
            ForEach(symbols.indices, id: \.self) { i in
                Button { selection = i } label: {
                    symbols[i].swiftUIImage(size: fLab)
                        .foregroundStyle(selection == i ? Quiet.label : Quiet.label3)
                        .frame(width: hCtl, height: hSmall)
                        .background(RoundedRectangle(cornerRadius: rInner).fill(selection == i ? SC.raised : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sqHelp(tips[i])
            }
        }
        .padding(hairGap)
        .background(RoundedRectangle(cornerRadius: rCtl).fill(SC.field))
    }
}

/// Pop button (`.pop`): title and chevron, opens an SQ menu under it.
private struct SortButton: View {
    var title: String
    var items: () -> [SQMenuItem]
    @State private var hovering = false

    var body: some View {
        Button {
            SQMenuController.shared.present(items: items(), at: NSEvent.mouseLocation)
        } label: {
            HStack(spacing: gapS) {
                Text(title).font(sf(fLab)).foregroundStyle(Quiet.label)
                SQIcon.chevronDown.swiftUIImage(size: fCap).foregroundStyle(Quiet.label3)
            }
            .padding(.leading, gapM).padding(.trailing, gapS)
            .frame(height: hCtl)
            .background(RoundedRectangle(cornerRadius: rCtl).fill(hovering ? SC.softHover : SC.soft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .sqHelp("Sort projects")
    }
}

/// Picture well of a card: a neutral frame in the project's aspect (no poster frames rendered yet), aspect and length badges.
private struct PosterWell: View {
    var info: StartProjectInfo?
    var poster: CGImage? = nil
    var gone: Bool
    var height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rCtl).fill(SC.well)
            GeometryReader { g in
                let box = CGSize(width: g.size.width - gapM * 2, height: g.size.height - gapM * 2)
                let ar = info.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16 / 9
                let w = min(box.width, box.height * ar), h = w / ar
                Group {
                    if let poster {
                        Image(decorative: poster, scale: 1).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(SC.poster)
                            .overlay { if !gone, info?.mediaMissing != true {
                                SQIcon.film.swiftUIImage(size: fBody).foregroundStyle(Quiet.label3)
                            } }
                    }
                }
                .frame(width: max(w, 0), height: max(h, 0))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            if gone {
                VStack(spacing: gapXS) {
                    SQIcon.warning.swiftUIImage(size: fBody)
                    Text("File missing").font(sf(fCap, .medium))
                }
                .foregroundStyle(SC.warning)
            } else if info?.mediaMissing == true {
                VStack(spacing: gapXS) {
                    SQIcon.unlink.swiftUIImage(size: fBody)
                    Text("Locate media…").font(sf(fCap, .medium))
                }
                .foregroundStyle(SC.warning)
            }
        }
        .frame(height: height)
        .saturation(gone ? 0 : 1)
        .overlay(alignment: .bottomLeading) {
            if let info, !gone { Badge { AspectGlyph(width: info.width, height: info.height); Text(info.aspect) }.padding(gapS) }
        }
        .overlay(alignment: .bottomTrailing) {
            if let info, !gone, info.seconds > 0 { Badge { Text(info.length) }.padding(gapS) }
        }
    }
}

/// Pill on a picture (`.badge`): 20 high, 0.72 black, 11 pt medium.
private struct Badge<C: View>: View {
    @ViewBuilder var content: () -> C
    var body: some View {
        HStack(spacing: gapXS) { content() }
            .font(sf(fCap, .medium)).foregroundStyle(SC.badgeText)
            .padding(.horizontal, gapS)
            .frame(minHeight: Theme.Metrics.startBadge)
            .background(Capsule().fill(SC.badge))
    }
}

/// Small outlined box in the frame's aspect, inside a badge.
private struct AspectGlyph: View {
    var width: Int
    var height: Int
    var body: some View {
        let ar = CGFloat(width) / CGFloat(max(height, 1)), box = fCap - hairGap
        let w = ar >= 1 ? box : box * ar, h = ar >= 1 ? box / ar : box
        RoundedRectangle(cornerRadius: hairGap / 2).stroke(SC.badgeText, lineWidth: Theme.Overlay.edgeWidth * 3)
            .frame(width: w, height: h).frame(width: box, height: box)
    }
}

/// Recent project card (`.card`): picture well, name and "1080 × 1920 · 2 h ago"; hover lifts, "…" opens the menu.
private struct ProjectCard: View {
    var entry: RecentProjects.Entry
    var info: StartProjectInfo?
    var poster: CGImage? = nil
    var gone: Bool
    var selected: Bool
    var open: () -> Void
    var menu: () -> [SQMenuItem]
    @State private var hovering = false

    private var subtitle: String {
        if gone { return "File not found. Click to locate it." }
        let when = StartWindowView.relativeLabel(entry.opened)
        return info.map { "\($0.size) · \(when)" } ?? when
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                PosterWell(info: info, poster: poster, gone: gone, height: Theme.Metrics.startThumb).padding(Theme.Metrics.startThumbInset)
                HStack(alignment: .top, spacing: gapXS) {
                    VStack(alignment: .leading, spacing: hairGap) {
                        Text(entry.name).font(sf(fBody, .semibold)).foregroundStyle(gone ? Quiet.label2 : Quiet.label).lineLimit(1)
                        Text(subtitle).font(sf(fCap)).foregroundStyle(gone ? SC.warning : Quiet.label3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        SQMenuController.shared.present(items: menu(), at: NSEvent.mouseLocation)
                    } label: {
                        SQIcon.ellipsis.swiftUIImage(size: fLab).foregroundStyle(Quiet.label2)
                            .frame(width: hSmall, height: hSmall).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .sqHelp("More")
                }
                .padding(.top, gapS).padding(.leading, gapM).padding(.trailing, gapXS).padding(.bottom, gapM)
            }
            .background(RoundedRectangle(cornerRadius: rCard).fill(hovering ? SC.softHover : SC.soft))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: rCard).stroke(SC.accent, lineWidth: hairGap) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .sqHelp(gone ? "File not found. Click to locate it." : (entry.path as NSString).abbreviatingWithTildeInPath)
        .sqContextMenu(menu)
    }
}

/// Columns of the list layout (`.lrow`): picture, name, frame size, aspect, rate, length, edited, more.
private enum ListCol {
    static let thumb = Theme.Metrics.startListThumb.width
    static let size: CGFloat = 110, aspect: CGFloat = 64, rate: CGFloat = 92, length: CGFloat = 64, edited: CGFloat = 96
    static let more = hCtl
}

private struct ListHeader: View {
    var body: some View {
        HStack(spacing: gapM) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, ListCol.thumb + gapM)
            Text("Frame size").frame(width: ListCol.size, alignment: .leading)
            Text("Aspect").frame(width: ListCol.aspect, alignment: .leading)
            Text("Frame rate").frame(width: ListCol.rate, alignment: .leading)
            Text("Length").frame(width: ListCol.length, alignment: .leading)
            Text("Edited").frame(width: ListCol.edited, alignment: .leading)
            Color.clear.frame(width: ListCol.more)
        }
        .font(sf(fCap, .semibold)).foregroundStyle(Quiet.label3).lineLimit(1)
        .padding(.horizontal, gapS)
        .frame(height: hCtl)
    }
}

private struct ProjectListRow: View {
    var entry: RecentProjects.Entry
    var info: StartProjectInfo?
    var poster: CGImage? = nil
    var gone: Bool
    var selected: Bool
    var open: () -> Void
    var menu: () -> [SQMenuItem]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: gapM) {
            PosterThumb(info: info, poster: poster, gone: gone)
            Text(entry.name).font(sf(fLab, .medium)).foregroundStyle(gone ? Quiet.label2 : Quiet.label)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if gone {
                Text("File not found").foregroundStyle(SC.warning).frame(width: ListCol.size + ListCol.aspect + gapM, alignment: .leading)
                StartButton(title: "Locate…", style: .raised, fixed: true, action: open)
                    .frame(width: ListCol.rate + ListCol.length + gapM, alignment: .leading)
            } else {
                Text(info?.size ?? "–").frame(width: ListCol.size, alignment: .leading)
                Text(info?.aspect ?? "–").frame(width: ListCol.aspect, alignment: .leading)
                Text(info?.rate ?? "–").frame(width: ListCol.rate, alignment: .leading)
                Text(info?.length ?? "–").frame(width: ListCol.length, alignment: .leading)
            }
            Text(StartWindowView.relativeLabel(entry.opened)).frame(width: ListCol.edited, alignment: .leading)
            Button {
                SQMenuController.shared.present(items: menu(), at: NSEvent.mouseLocation)
            } label: {
                SQIcon.ellipsis.swiftUIImage(size: fBody).foregroundStyle(Quiet.label2).frame(width: ListCol.more, height: hCtl).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(hovering ? 1 : 0)
        }
        .font(sf(fLab)).foregroundStyle(Quiet.label2).lineLimit(1)
        .padding(.horizontal, gapS)
        .frame(height: Theme.Metrics.startListRow)
        .background(RoundedRectangle(cornerRadius: rCtl).fill(selected ? SC.pressed : hovering ? SC.soft : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1, perform: open)
        .sqHelp(gone ? "File not found. Click to locate it." : (entry.path as NSString).abbreviatingWithTildeInPath)
        .sqContextMenu(menu)
    }
}

/// 40 x 32 picture of a list row.
private struct PosterThumb: View {
    var info: StartProjectInfo?
    var poster: CGImage? = nil
    var gone: Bool
    var body: some View {
        let size = Theme.Metrics.startListThumb
        ZStack {
            RoundedRectangle(cornerRadius: rInner).fill(SC.well)
            if gone {
                SQIcon.warning.swiftUIImage(size: fCap).foregroundStyle(SC.warning)
            } else {
                let ar = info.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16 / 9
                let box = CGSize(width: size.width - gapS, height: size.height - gapS)
                let w = min(box.width, box.height * ar)
                Group {
                    if let poster { Image(decorative: poster, scale: 1).resizable().scaledToFill() } else { Rectangle().fill(SC.poster) }
                }
                .frame(width: w, height: w / ar).clipShape(RoundedRectangle(cornerRadius: hairGap))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Home quick tile (52 high, raised): frame glyph, template name and size. nil template = "All formats…".
private struct QuickSizeTile: View {
    var template: ProjectTemplate?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: gapM) {
                if let t = template {
                    FrameGlyph(width: t.format.width, height: t.format.height, box: hSmall)
                    VStack(alignment: .leading, spacing: hairGap) {
                        Text(t.name).font(sf(fLab, .medium)).foregroundStyle(Quiet.label).lineLimit(1)
                        Text("\(t.format.width) × \(t.format.height)").font(sf(fCap)).foregroundStyle(Quiet.label3)
                    }
                } else {
                    SQIcon.ellipsis.swiftUIImage(size: fBody).foregroundStyle(Quiet.label2).frame(width: hSmall)
                    Text("All formats…").font(sf(fLab, .medium)).foregroundStyle(Quiet.label)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, gapM)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.startQuickTile, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: rCtl).fill(SC.raised))
            .overlay { if hovering { RoundedRectangle(cornerRadius: rCtl).fill(SC.soft) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .sqHelp(template?.summary ?? "Every frame size and rate")
    }
}

/// Template card: 120 high picture with the frame, name and size.
private struct TemplateCard: View {
    var template: ProjectTemplate
    var isBuiltIn: Bool
    var create: () -> Void
    var menu: () -> [SQMenuItem]
    @State private var hovering = false

    var body: some View {
        let f = template.format
        Button(action: create) {
            VStack(alignment: .leading, spacing: 0) {
                PosterWell(info: StartProjectInfo(width: f.width, height: f.height, fps: 0, seconds: 0), gone: false,
                           height: Theme.Metrics.startTemplateThumb)
                    .padding(Theme.Metrics.startThumbInset)
                VStack(alignment: .leading, spacing: hairGap) {
                    Text(template.name).font(sf(fBody, .semibold)).foregroundStyle(Quiet.label).lineLimit(1)
                    Text("\(f.width) × \(f.height)").font(sf(fCap)).foregroundStyle(Quiet.label3).lineLimit(1)
                }
                .padding(.top, gapS).padding(.horizontal, gapM).padding(.bottom, gapM)
            }
            .background(RoundedRectangle(cornerRadius: rCard).fill(hovering ? SC.softHover : SC.soft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .sqHelp(template.summary)
        .sqContextMenu(menu)
    }
}

/// Learn card (`.lcard`): 64 high, icon, title and one line. Tips without a page are plain text, not buttons.
private struct LearnCard: View {
    var title: String
    var text: String
    var symbol: SQIcon
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: gapM) {
                symbol.swiftUIImage(size: Theme.Typography.startHeading).foregroundStyle(Quiet.label2).frame(width: gapXXL)
                VStack(alignment: .leading, spacing: hairGap) {
                    Text(title).font(sf(fBody, .semibold)).foregroundStyle(Quiet.label).lineLimit(1)
                    Text(text).font(sf(fCap)).foregroundStyle(Quiet.label3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, gapL)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.startLearnCard, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: rCard).fill(hovering && action != nil ? SC.softHover : SC.soft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(action != nil)
        .onHover { hovering = $0 }
    }
}

/// A rectangle with the frame's aspect, fitted in a `box` square, in the video clip color.
private struct FrameGlyph: View {
    var width: Int
    var height: Int
    var box: CGFloat

    var body: some View {
        let ar = CGFloat(width) / CGFloat(max(height, 1))
        let w = ar >= 1 ? box : box * ar, h = ar >= 1 ? box / max(ar, 0.01) : box
        RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Quiet.color(Theme.Colors.clipVideo))
            .frame(width: w, height: h)
            .frame(width: box, height: box)
    }
}

// MARK: - Appearance popover

/// The Appearance popover (design B v7): Dark | Light, Background -6…6, Contrast 0…100 in steps of 5, the lowest text
/// contrast and Reset. Lives in an SQPopover window, so the live rebuild of the start view never cuts a slider drag.
struct AppearancePopoverView: View {
    var onClose: () -> Void
    @State private var appearance = ThemeAppearance.shared

    var body: some View {
        let s = appearance.settings, rev = appearance.revision
        VStack(alignment: .leading, spacing: gapM) {
            HStack {
                Text("Appearance").font(sf(fBody, .semibold)).foregroundStyle(Quiet.label)
                Spacer(minLength: gapS)
                Button(action: onClose) {
                    SQIcon.close.swiftUIImage(size: fLab).foregroundStyle(Quiet.label2)
                        .frame(width: hSmall, height: hSmall).contentShape(Rectangle())
                }.buttonStyle(.plain).sqHelp("Close")
            }
            .id(rev)
            SQSegmentedView(labels: ["Dark", "Light"], segmentWidth: (Theme.Metrics.startAppearanceWidth - gapM * 2) / 2,
                            selection: Binding(get: { s.mode == .dark ? 0 : 1 },
                                               set: { i in appearance.update { $0.mode = i == 0 ? .dark : .light } }))
                .frame(height: hCtl)
            row("Background", value: s.background > 0 ? "+\(s.background)" : "\(s.background)", rev: rev) {
                SQSliderView(value: Double(s.background), range: AppearanceSettings.backgroundRange, step: 1, standard: 0) { v in
                    appearance.update { $0.background = Int(v) }
                }
            }
            row("Contrast", value: "\(s.contrast)", rev: rev) {
                SQSliderView(value: Double(s.contrast), range: AppearanceSettings.contrastRange, step: 5, standard: 50) { v in
                    appearance.update { $0.contrast = Int(v) }
                }
            }
            HStack(spacing: gapS) {
                let low = appearance.palette.lowestTextContrast
                Text(String(format: "Lowest text contrast %.1f:1", low)).foregroundStyle(low < 4.5 ? SC.warning : Quiet.label3)
                Spacer(minLength: 0)
                StartButton(title: "Reset", style: .raised, fixed: true) { appearance.reset() }
            }
            .font(sf(fCap))
            .padding(.top, gapXS)
            .id(rev)
        }
        .frame(width: Theme.Metrics.startAppearanceWidth - gapM * 2)
    }

    private func row(_ label: String, value: String, rev: Int, @ViewBuilder slider: () -> some View) -> some View {
        HStack(spacing: gapS) {
            Text(label).font(sf(fLab)).foregroundStyle(Quiet.label2)
                .frame(width: Theme.Metrics.startAppearanceLabel, alignment: .leading).id(rev)
            slider().frame(maxWidth: .infinity)
            Text(value).font(sf(fLab)).foregroundStyle(Quiet.label)
                .frame(width: Theme.Metrics.startAppearanceValue, alignment: .trailing).id(rev)
        }
        .frame(minHeight: hCtl)
    }
}

/// SQSlider in SwiftUI, snapped to `step`; double-click returns to `standard`.
private struct SQSliderView: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Int>
    var step: Double
    var standard: Double
    var onChange: (Double) -> Void

    func makeNSView(context: Context) -> SQSlider {
        let s = SQSlider(frame: .zero)
        s.minValue = Double(range.lowerBound); s.maxValue = Double(range.upperBound)
        s.defaultValue = standard
        s.isContinuous = true
        s.doubleValue = value
        let coordinator = context.coordinator
        s.onChange = { v in coordinator.send(v) }
        return s
    }
    func updateNSView(_ s: SQSlider, context: Context) {
        context.coordinator.parent = self
        if abs(s.doubleValue - value) >= step / 2 { s.doubleValue = value }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: SQSliderView
        private var last: Double?
        init(_ p: SQSliderView) { parent = p }
        func send(_ raw: Double) {
            let v = (raw / parent.step).rounded() * parent.step
            guard v != last else { return }
            last = v
            parent.onChange(v)
        }
        @objc func changed(_ s: SQSlider) { send(s.doubleValue) }
    }
}

/// The Start window's search: the shared `SQSearchField` (capsule, focus line, SQ cancel) instead of a SwiftUI TextField.
private struct StartSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusTick: Int

    func makeNSView(context: Context) -> SQSearchField {
        let f = SQSearchField()
        f.setQuietPlaceholder("Search projects")
        f.sendsSearchStringImmediately = true
        f.delegate = context.coordinator
        f.target = context.coordinator
        f.action = #selector(Coordinator.changed(_:))
        f.setAccessibilityLabel("Search projects")
        context.coordinator.lastTick = focusTick
        return f
    }

    func updateNSView(_ f: SQSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.lastTick != focusTick {
            context.coordinator.lastTick = focusTick
            f.window?.makeFirstResponder(f)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: StartSearchField
        var lastTick = 0
        init(_ p: StartSearchField) { parent = p }
        @objc func changed(_ sender: NSSearchField) { parent.text = sender.stringValue }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
    }
}
