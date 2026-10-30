import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The Project panel translated from the Mac `ProjectPanelView`: the same `ProjectPanelModel` (rows, cell texts, kind
/// icons, labels, search, sort, delete/rename/new folder) as a list (folders open in place, a kind chip per row, the
/// columns of `ProjectColumnLayout` with the header's column picker) or an icon grid (posters from the host, folders
/// entered by double-click, a path row back). The header's "..." menu switches the view and shows the search row. Drawing
/// and events are new; the menus are the Mac `ProjectPanelMenus` rows the shared toolkit has.
/// shortcut: no hover scrub, smart folders, filter chips or column drag/resize; upgrade when the Windows Project panel
/// gets its own pointer-hover pass.
@MainActor
public final class ProjectListView {
    public struct Row: Equatable {
        public var ref: BinItemRef
        public var depth: Int
    }
    /// List or icon grid (the Mac `ProjectPanelView.ViewMode`, saved under the same key).
    public enum ViewMode: String, Sendable { case list, icons }

    // Mac metrics: `Theme.Row.panelList` 26, `Theme.Spacing.md` lead 12, `Theme.Spacing.treeIndent` 14, chip 16.
    public static let rowHeight: CGFloat = 26
    public static let headerHeight: CGFloat = 30
    /// `ProjectPanelView.searchRowHeight` / `crumbHeight`; the outline's column header.
    public static let searchRowHeight: CGFloat = 38
    public static let crumbHeight: CGFloat = 28
    /// `PanelListHeader.height` = `Theme.Row.panelList`.
    public static let columnHeaderHeight: CGFloat = 26
    static let nameLead: CGFloat = 12
    static let levelIndent: CGFloat = 14
    static let chip: CGFloat = 16
    static let doubleClick: Double = 0.4
    static let viewModeKey = "ProjectPanel.viewMode"
    static let searchVisibleKey = "sq.project.searchVisible"
    /// Icon grid thumbnail width, kept across launches (the Mac slider's 64...160 range).
    static let thumbSizeKey = "sq.project.thumbSize"
    static let thumbRange: ClosedRange<CGFloat> = 64...160

    public weak var host: ShellHost?
    /// The panel in window points.
    public var frame: CGRect = .zero
    /// Draws "Project" in its header row; off when a dock tab strip above already names the panel.
    public var showsTitle = true
    /// The dock whose tab strip carries the item count, New Folder and "..." (the Mac `TabStrip`); nil keeps the header row.
    public weak var stripDock: ShellDock?
    public private(set) var expanded: Set<Bin.ID> = []
    public internal(set) var selection: [BinItemRef] = []
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    public internal(set) var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    /// Keys go to the list only after a click inside it, until a click elsewhere.
    public internal(set) var hasFocus = false
    /// A double-click on a sequence opens it, on a media item it goes to the host (Source monitor where there is one).
    public var onOpenSequence: ((Timeline.ID) -> Void)?
    public var onOpenMedia: ((MediaRef.ID) -> Void)?
    /// Extract Audio (the item's sound as its own M4A item); nil on hosts without audio extraction.
    public var onExtractAudio: ((MediaRef.ID) -> Void)?
    /// Conform to Constant Frame Rate of the eligible items (a background job); nil hides the row.
    public var onConformToConstantFrameRate: (([MediaRef.ID]) -> Void)?
    /// The health line's Fix > Collect (copy outside media into the project folder); nil hides the row (ProjectListView+Health).
    public var onCollect: (@MainActor () -> Void)?
    var healthHover: HealthPart?
    /// A drag of the selected media and sequences out of the list (the Mac outline's pasteboard drag): the host shows it
    /// over the timeline. `point` in window pixels as the events give it.
    public enum DragPhase: Sendable { case moved, ended, canceled }
    public var onDrag: ((_ refs: [BinItemRef], _ phase: DragPhase, _ x: Float, _ y: Float) -> Void)?
    private var press: CGPoint?
    public private(set) var isDragging = false
    /// Where a drag inside the panel would drop the items (a folder, or between rows); nil = the host's drop (timeline).
    var moveTarget: MoveTarget?
    static let dragSlop: CGFloat = 4
    /// Clock for the double-click test.
    public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var lastClick: (ref: BinItemRef, time: Double)?

    /// Where the view mode, search row and columns are kept per user (the Mac panel's keys).
    public let defaults: UserDefaults
    public internal(set) var viewMode: ViewMode
    public internal(set) var isSearchVisible: Bool
    public internal(set) var columns: ProjectColumnLayout
    var search = TextFieldControl()
    /// The poster of a media item for the icon grid (the Mac `ProjectThumbnails.poster`); nil while it loads or for audio.
    public var poster: (@MainActor (MediaRef.ID) -> ProjectPoster?)?
    /// Icon grid thumbnail width (`ProjectIconView.thumbSize`).
    public var thumbSize: CGFloat = 96 { didSet { defaults.set(Double(thumbSize), forKey: Self.thumbSizeKey) } }
    /// The thumbnail slider is being dragged.
    var sizeSliderDragging = false
    /// View > Hover Scrub (`AppSettings.hoverScrub`): moving over a video tile shows the frame under the pointer.
    public internal(set) var hoverScrubOn: Bool
    /// The frame of a media item at a media time for hover scrubbing (the Mac `ProjectThumbnails.scrub`); nil while it loads.
    public var posterAt: (@MainActor (MediaRef.ID, Time) -> ProjectPoster?)?
    /// The tile being scrubbed (ProjectListView+HoverScrub).
    var scrub: HoverScrubState?
    /// The keys held now (the host's key state; `.mouseMoved` carries none): Shift scrubs while Hover Scrub is off.
    public var liveModifiers: (() -> InputModifiers)?

    public init(host: ShellHost, defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
        viewMode = ViewMode(rawValue: defaults.string(forKey: Self.viewModeKey) ?? "") ?? .list
        isSearchVisible = defaults.bool(forKey: Self.searchVisibleKey)
        let saved = CGFloat(defaults.double(forKey: Self.thumbSizeKey))
        if saved > 0 { thumbSize = min(max(saved, Self.thumbRange.lowerBound), Self.thumbRange.upperBound) }
        columns = ProjectColumnLayout.load(from: defaults)
        hoverScrubOn = AppSettings.load(from: defaults).hoverScrub
        search.alignment = .left
        host.projectSelection = { [weak self] in self?.selection ?? [] }
        host.factProviders.append { [weak self] f in if self?.search.isEditing == true { f.textEditing = true } }
        host.projectList = self
    }

    var model: ProjectPanelModel? { host?.projectModel }

    /// Visible rows: the root's sequences first, then folders and loose items (the Mac `rootItems`), open folders inline.
    public func rows() -> [Row] {
        guard let model else { return [] }
        var out: [Row] = []
        func add(_ items: [BinItem], _ depth: Int) {
            for i in items {
                out.append(Row(ref: i.ref, depth: depth))
                if case .bin(let b) = i, expanded.contains(b.id) { add(model.children(of: b), depth + 1) }
            }
        }
        let all = model.children(of: model.project.rootBin)
        func isSequence(_ i: BinItem) -> Bool { if case .sequence = i.ref { true } else { false } }
        add(all.filter(isSequence) + all.filter { !isSequence($0) }, 0)
        return out
    }

    /// The clickable items in display order: the list rows, or the grid's tiles.
    func items() -> [BinItemRef] { viewMode == .list ? rows().map(\.ref) : gridItems() }

    /// The scrolling content under the header, the search row and the column header or path row.
    var listRect: CGRect {
        let top = chromeHeight, bottom = healthRect?.height ?? 0
        return CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: max(frame.height - top - bottom, 0))
    }

    func rowRect(_ i: Int) -> CGRect {
        CGRect(x: frame.minX, y: listRect.minY + CGFloat(i) * Self.rowHeight - scroll, width: frame.width, height: Self.rowHeight)
    }

    public func row(at p: CGPoint) -> Int? {
        guard viewMode == .list, listRect.contains(p) else { return nil }
        let i = Int(((p.y - listRect.minY + scroll) / Self.rowHeight).rounded(.down))
        return rows().indices.contains(i) ? i : nil
    }

    /// Index into `items()` under `p`.
    func item(at p: CGPoint) -> Int? { viewMode == .list ? row(at: p) : tile(at: p) }

    var contentHeight: CGFloat { viewMode == .list ? CGFloat(rows().count) * Self.rowHeight : gridHeight }

    public func toggle(_ id: Bin.ID) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    public func select(_ refs: [BinItemRef]) { selection = refs }

    /// Find: opens the bins that hold `refs` (parents first) and selects them.
    public func reveal(_ refs: [BinItemRef], in root: Bin) {
        for ref in refs {
            var up = root.parent(of: ref)
            while let b = up, b != root.id { expanded.insert(b); up = root.parent(of: .bin(b)) }
        }
        selection = refs
    }

    // MARK: Events

    /// Clicks, wheel, Delete, Return (rename), typing into the search row. `scale` turns pixels into points.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        if scrollBody.scrollerEvent(e, scale: scale, viewport: listRect, content: contentHeight) { return true }
        switch e {
        case .mouseDown(let x, let y, let m):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            if !m.contains(.secondary), stripClick(at: p) { endSearchEditing(); press = nil; return true }
            hasFocus = frame.contains(p)
            if !hasFocus || !searchRect.contains(p) { endSearchEditing() }
            guard hasFocus else { return false }
            if healthClick(at: p) || chromeClick(at: p, modifiers: m) { press = nil; return true }
            click(at: p, modifiers: m)
            press = m.contains(.secondary) || item(at: p) == nil ? nil : p
            return true
        case .mouseDragged(let x, let y):
            if sizeSliderDragging { setThumbSize(atX: CGFloat(x) / k); return true }
            guard let start = press else { return false }
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            if !isDragging {
                guard hypot(p.x - start.x, p.y - start.y) >= Self.dragSlop, !selection.isEmpty else { return true }
                isDragging = true
                lastClick = nil
            }
            moveTarget = self.moveTarget(at: p, moving: selection)
            if moveTarget == nil, !dragRefs.isEmpty { onDrag?(dragRefs, .moved, x, y) }
            return true
        case .mouseUp(let x, let y):
            if sizeSliderDragging { sizeSliderDragging = false; return true }
            guard press != nil else { return false }
            press = nil
            if isDragging {
                isDragging = false
                defer { moveTarget = nil }
                // Dropped on a folder or between rows of the panel: the items move there (the host sees a canceled drag).
                if let t = moveTarget { dropMove(selection, on: t); if !dragRefs.isEmpty { onDrag?(dragRefs, .canceled, x, y) } }
                else if !dragRefs.isEmpty { onDrag?(dragRefs, .ended, x, y) }
            }
            return true
        case .scroll(let x, let y, _, let dy, _):
            guard frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) else { return false }
            let maxScroll = max(contentHeight - listRect.height, 0)
            scrollBody.wheel(dy: dy, scale: k, maxOffset: maxScroll, extent: listRect.height)
            return true
        case .keyDown(.escape, _) where isDragging:
            press = nil
            isDragging = false
            moveTarget = nil
            if !dragRefs.isEmpty { onDrag?(dragRefs, .canceled, 0, 0) }
            return true
        case .keyDown(let key, let m):
            if search.isEditing { searchKey(key, modifiers: m); return true }
            guard hasFocus, !selection.isEmpty else { return false }
            switch key {
            case .delete, .backspace: deleteSelection(); return true
            case .enter:
                if selection.count == 1 { rename(selection[0]) }
                return true
            default: return false
            }
        case .mouseMoved(let x, let y):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            healthHover = healthPart(at: p)
            scrub = scrubState(at: p)
            HostHover.current.offerTip(itemTip(at: p))
            return false
        default: return false
        }
    }

    /// What a drag carries: the selected media and sequences (folders do not drag onto the timeline).
    var dragRefs: [BinItemRef] { selection.filter { if case .bin = $0 { false } else { true } } }

    func click(at p: CGPoint, modifiers m: InputModifiers) {
        let list = items()
        guard let i = item(at: p) else {
            if !m.contains(.secondary) { selection = [] }
            if m.contains(.secondary) { host?.menuBar.controller.present(items: menu(), at: p) }
            return
        }
        let ref = list[i]
        if m.contains(.command) {
            if let at = selection.firstIndex(of: ref) { selection.remove(at: at) } else { selection.append(ref) }
        } else if m.contains(.shift), let anchor = selection.last, let a = list.firstIndex(of: anchor) {
            selection = Array(list[min(a, i)...max(a, i)])
        } else if !(m.contains(.secondary) && selection.contains(ref)) {
            selection = [ref]
        }
        if m.contains(.secondary) { host?.menuBar.controller.present(items: menu(), at: p); return }
        // The disclosure arrow sits before a folder's chip.
        if viewMode == .list, case .bin(let id) = ref,
           p.x < frame.minX + Self.nameLead + CGFloat(rows()[i].depth + 1) * Self.levelIndent {
            toggle(id)
            return
        }
        let t = now()
        defer { lastClick = (ref, t) }
        guard let last = lastClick, last.ref == ref, t - last.time < Self.doubleClick else { return }
        lastClick = nil
        open(ref)
    }

    public func open(_ ref: BinItemRef) {
        switch ref {
        case .bin(let id):
            if viewMode == .icons { enter(id) } else { toggle(id) }
        case .sequence(let id): onOpenSequence?(id)
        case .media(let id): onOpenMedia?(id)
        }
    }


    // MARK: Menu and actions (ProjectPanelMenus.items: the Mac `ProjectPanelView.menuItems` rows and context)

    /// The right-click menu for the current selection (empty = the empty-area menu), built as the Mac panel builds it.
    public func menu() -> [SQMenuItem] {
        guard let model, let host else { return [] }
        let targets = selection
        let media = targets.compactMap { if case .media(let id) = $0 { id } else { nil } }
        let nonBin = targets.filter { if case .bin = $0 { false } else { true } }
        let labels = Set(nonBin.map { model.label(of: $0) })
        let sounds = media.map { model.project.media($0)?.info?.audio }
        let counts = media.map { id in model.project.media(id).flatMap { r in r.info?.audio?.mappableChannels(path: r.path) } }
        let sameChannels = counts.allSatisfy { $0 == counts.first ?? nil }
        let sameMap = sounds.allSatisfy { $0?.channelMap == sounds.first??.channelMap }
        var c = ProjectPanelMenus.Context(
            media: media,
            hasBin: targets.contains { if case .bin = $0 { true } else { false } },
            hasSequence: targets.contains { if case .sequence = $0 { true } else { false } },
            targetCount: targets.count,
            allMediaOnline: !media.isEmpty && media.allSatisfy { !model.isOffline($0) },
            singleMediaOffline: media.count == 1 && model.isOffline(media[0]),
            singleMediaHasPoster: media.count == 1 && model.project.media(media[0])?.posterTime != nil,
            singleMediaHasMarks: media.count == 1 && !model.project.sourceMarks(for: media[0]).isEmpty,
            sharedLabel: labels.count == 1 ? labels.first : nil,
            firstLabel: nonBin.first.map { model.label(of: $0) },
            hasNonBinTarget: !nonBin.isEmpty,
            isIconView: viewMode == .icons,
            canGoUp: model.browseBin != model.project.rootBin.id,
            hoverScrub: hoverScrubOn,
            pixelAspect: PixelAspectChoices.state(project: model.project, media: media))
        if sameChannels, let first = sounds.first { c.audioChannels = counts.first.flatMap { $0 } ?? 0; c.audioChannelMap = sameMap ? first?.channelMap : nil }
        c.deinterlace = model.deinterlaceState(media)
        c.anyMediaUsed = media.contains { !model.project.sequenceNames(using: $0).isEmpty }
        c.canFillReel = host.session.reelSlotCount > 0
        c.canConformToCFR = onConformToConstantFrameRate != nil
            && media.contains { id in model.project.media(id).map(ConstantFrameRateConform.isEligible) ?? false }
        let map = host.map
        return ProjectPanelMenus.items(c, shortcut: { ProjectPanelMenus.shortcut($0, map: map) }) {
            [weak self] in self?.run($0, targets: targets)
        }
    }

    /// The Mac `ProjectPanelView.run`: what each menu row does with the clicked items.
    func run(_ action: ProjectPanelMenus.Action, targets: [BinItemRef]) {
        guard let model, let host else { return }
        let media = targets.compactMap { if case .media(let id) = $0 { id } else { nil } }
        let sequences = targets.compactMap { if case .sequence(let id) = $0 { id } else { nil } }
        func place(_ mode: ThreePointMode) {
            let ok = media.isEmpty && !sequences.isEmpty ? host.session.placeSequences(sequences, mode: mode)
                                                         : host.session.placeMediaAsking(media, mode: mode)
            if !ok, let e = host.session.lastError { host.flash(e) }
        }
        switch action {
        case .newFolder: newFolder()
        case .newColorMatte: host.perform(.newColorMatte)
        case .newSequence: _ = host.execute(.newSequence)
        case .importMedia: host.spawn { await host.importAnything() }
        case .find: host.spawn { await host.find() }
        case .goUp: goUp()
        case .toggleHoverScrub: setHoverScrub(!hoverScrubOn)
        case .openInSource: if let id = media.first { onOpenMedia?(id) }
        case .openInTimeline: if let id = sequences.first { onOpenSequence?(id) }
        case .insert: place(.insert)
        case .overwrite: place(.overwrite)
        case .sequenceFromClip: if let id = media.first { _ = host.session.newSequence(fromMedia: id) }
        case .createAnglesClip, .fillReel, .editOriginal:
            let c: EditorCommand = action == .fillReel ? .fillReel : action == .editOriginal ? .editOriginal : .createAnglesClip
            if !host.execute(c) { host.flash("This needs the selected media items.") }
        case .makeSubclip:
            if let id = media.first, host.session.makeSubclip(of: id) == nil, let e = host.session.lastError { host.flash(e) }
        case .rename: if targets.count == 1 { rename(targets[0]) }
        case .deletePoster: _ = model.setPoster(nil, for: targets)
        case .reveal:
            // shortcut: reveals the first file (the Mac selects them all in one Finder window); upgrade with a list reveal hook.
            if let id = media.first, let path = model.project.media(id)?.path { host.revealFile?(URL(fileURLWithPath: path)) }
        case .replaceMedia: if let id = media.first { host.spawn { await host.replaceMedia(id) } }
        case .locateMedia: if let id = media.first { host.spawn { await host.locateOffline(id) } }
        case .delete: deleteSelection()
        case .clearUsedMedia:
            let r = model.clear(targets)
            if let m = r.message { host.presentMessage(ProjectPanelModel.deleteName(for: targets), m) }
            if r.changed { selection = [] }
        case .extractAudio: if let id = media.first { onExtractAudio?(id) }
        case .conformToConstantFrameRate:
            let ids = media.filter { id in model.project.media(id).map(ConstantFrameRateConform.isEligible) ?? false }
            if !ids.isEmpty { onConformToConstantFrameRate?(ids) }
        case .setPixelAspect(let a): _ = model.setPixelAspect(a, for: targets)
        case .customPixelAspect: host.spawn { await host.customSelectionPixelAspect() }
        case .setDeinterlace(let on): _ = model.setDeinterlace(on, for: targets)
        case .setLabel(let l): _ = model.setLabel(l, for: targets)
        case .selectLabelGroup(let l): selection = model.project.items(withLabel: l)
        case .toggleColumn, .resetColumns: break       // the column header's own menu (ProjectListView+Chrome)
        case .setAudioChannels(let m): _ = model.setAudioChannels(m, for: targets)
        }
    }

    public func newFolder() {
        guard let model else { return }
        if case .bin(let id) = selection.first, selection.count == 1 { model.currentBin = id; expanded.insert(id) } else {
            model.currentBin = viewMode == .icons ? model.browseBin : model.project.rootBin.id
        }
        if let id = model.newBin() { selection = [.bin(id)] }
    }

    public func setLabel(_ l: LabelColor?) { _ = model?.setLabel(l, for: selection.filter { if case .bin = $0 { false } else { true } }) }

    public func deleteSelection() {
        guard let model, !selection.isEmpty else { return }
        let r = model.delete(selection)
        if let msg = r.message { host?.presentMessage(ProjectPanelModel.deleteName(for: selection), msg) }
        if r.changed { selection = [] }
    }

    /// Rename in a small form dialog (the Mac edits the cell in place).
    public func rename(_ ref: BinItemRef) {
        guard let host, let model else { return }
        let d = ShellDialog("Rename")
        d.form = ShellForm([.field(id: "name", label: "Name", value: model.displayName(of: ref))])
        d.addButton("Rename")
        d.addButton("Cancel", role: .cancel)
        host.spawn {
            guard await host.ask(d) == .first, let name = d.form?.text("name") else { return }
            let t = name.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { _ = model.rename(ref, to: t) }
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        guard let model else { return }
        c.fill(frame, theme.panel)
        drawChrome(&c, theme: theme, model: model)
        c.saveGState()
        c.clip(to: listRect)
        if viewMode == .icons { drawGrid(&c, theme: theme, model: model) } else { drawList(&c, theme: theme, model: model) }
        c.restoreGState()
        scrollBody.drawScroller(&c, viewport: listRect, content: contentHeight, theme: theme)
        drawMoveTarget(&c, theme: theme)
        drawHealth(&c, theme: theme)
    }

    private func drawList(_ c: inout Canvas, theme: DrawTheme, model: ProjectPanelModel) {
        let list = rows()
        let cols = columnFrames(list.map(\.ref))
        let nameEnd = cols.first { $0.column == .name }?.maxX ?? frame.maxX
        for (i, r) in list.enumerated() {
            let rr = rowRect(i)
            guard rr.maxY >= listRect.minY, rr.minY <= listRect.maxY else { continue }
            // The outline's selection is full width; gray (unemphasized) while the list has no focus.
            if selection.contains(r.ref) { c.fill(rr, hasFocus ? theme.accentFill : Self.unfocusedSelection) }
            var offline = false
            if case .media(let m) = r.ref { offline = model.isOffline(m) }
            let kind = model.itemKind(of: r.ref)
            var x = rr.minX + Self.nameLead + CGFloat(r.depth) * Self.levelIndent
            if case .bin(let id) = r.ref {
                let open = expanded.contains(id)
                let mid = CGPoint(x: x + 4, y: rr.midY)
                let pts = open ? [CGPoint(x: mid.x - 3, y: mid.y - 1.5), CGPoint(x: mid.x, y: mid.y + 1.5), CGPoint(x: mid.x + 3, y: mid.y - 1.5)]
                    : [CGPoint(x: mid.x - 1.5, y: mid.y - 3), CGPoint(x: mid.x + 1.5, y: mid.y), CGPoint(x: mid.x - 1.5, y: mid.y + 3)]
                c.strokePolyline(pts, width: 1.2, theme.label2)
                x += Self.levelIndent
            }
            // Kind chip: the label color (offline red) with the kind's glyph, as `ProjectIconBox.Chip`.
            let chipRect = CGRect(x: x, y: rr.midY - Self.chip / 2, width: Self.chip, height: Self.chip)
            let fill = offline ? Self.offlineRed : theme.clip(kind == .bin ? .binDefault : model.label(of: r.ref))
            c.fill(roundedRect: chipRect, radius: 4, fill)
            let glyph = SQIcon(rawValue: ProjectItemIcon.icon(for: kind).symbol) ?? .unknown
            c.draw(icon: glyph, at: CGPoint(x: chipRect.minX + 2, y: chipRect.minY + 2), size: Self.chip - 4, theme.onClip)
            let nameX = chipRect.maxX + 10
            let text = offline ? Self.offlineRed : theme.label
            c.draw(model.cellText(.name, r.ref), in: CGRect(x: nameX, y: rr.minY, width: max(nameEnd - nameX - 4, 0), height: rr.height),
                   fontSize: Self.listFont, text)
            for col in cols where col.column != .name {
                let cell = CGRect(x: col.minX, y: rr.minY, width: col.maxX - col.minX, height: rr.height)
                c.draw(model.cellText(col.column, r.ref), in: cell, fontSize: Self.listFont, offline ? text : theme.label2,
                       align: Self.rightAligned(col.column) ? .right : .left, inset: Self.cellInset)
            }
        }
    }

    static let offlineRed = DrawColor(hex: 0xE5484D)
    /// `unemphasizedSelectedContentBackgroundColor` over the panel, as the AppKit render draws it.
    static let unfocusedSelection = DrawColor(hex: 0x4F4F51)
}
