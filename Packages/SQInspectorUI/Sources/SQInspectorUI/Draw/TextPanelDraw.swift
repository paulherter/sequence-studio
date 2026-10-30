import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit
import SQEditorSession
import SQLibrary
import SQText
import SQTranscribe
import SQUIKit

/// The Captions panel on the shared toolkit: `TextPanelView` translated. The v9 `.capbar` (a 38 pt bar, the tab switch
/// at the leading inset) over the shown tab: List (`CaptionsTabDraw`), Look (`CaptionStyleTabDraw`) and Templates
/// (`TextTemplatesTabDraw`), and Transcribe (`TranscriptTabDraw`) once the host gives it a transcription service
/// (`useTranscription`; SQTranscribe has none on Windows yet, so there the panel keeps three tabs).
/// Coordinates: points, y down, (0, 0) = the panel's top-left.
@MainActor public final class TextPanelDraw {
    public enum Tab: Int, CaseIterable, Sendable { case transcript, captions, style, templates
        public var title: String {
            switch self { case .transcript: "Transcribe"; case .captions: "List"; case .style: "Look"; case .templates: "Templates" }
        }
    }

    public var theme = DrawTheme() { didSet { captions.theme = theme; style.theme = theme; templates.theme = theme; transcript.theme = theme } }
    public var size = CGSize(width: 320, height: 480) { didSet { layoutPages() } }
    public let captions: CaptionsTabDraw
    public let style: CaptionStyleTabDraw
    public let templates: TextTemplatesTabDraw
    public let transcript = TranscriptTabDraw()
    /// The tabs the switch shows, in order (Transcribe only with a transcription service).
    public private(set) var tabs: [Tab] = [.captions, .style, .templates]
    private var service: (@MainActor () -> any TranscriptionService)?
    private var models: [UUID: CaptionsPanelModel] = [:]
    private var modelTimeline: UUID?
    public private(set) var tab: Tab = .captions
    /// The Templates tab was opened: the host reloads the Library's templates (the Mac host observes the Library).
    public var onShowTemplates: (@MainActor () -> Void)?

    private var hoverTab: Tab?
    private var pressedTab: Tab?
    /// The page took the press (drags and the release go to it).
    private var pagePressed = false

    /// Popups and row menus of every tab, anchors in panel points (the tab bar included).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// The Look tab's swatches, anchor in panel points; `change(nil)` = the picker closed. Without it swatches do nothing.
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// Status lines of every tab (template placed, look saved, captions exported).
    public var onStatus: (@MainActor (String) -> Void)? { didSet { captions.onStatus = onStatus; style.onStatus = onStatus } }

    private let session: EditorSession
    /// The Library's items the Templates tab shows (saved templates are placed from them).
    private(set) var libraryPresets: [PresetItem] = []
    private var loadingLibrary = false

    public init(session: EditorSession) {
        self.session = session
        captions = CaptionsTabDraw(session: session)
        style = CaptionStyleTabDraw(session: session)
        templates = TextTemplatesTabDraw()
        layoutPages()
        captions.onMenu = { [weak self] items, anchor in self?.onMenu?(items, anchor.offsetBy(dx: 0, dy: Self.barHeight)) }
        style.onMenu = { [weak self] items, anchor in self?.onMenu?(items, anchor.offsetBy(dx: 0, dy: Self.barHeight)) }
        style.onPickColor = { [weak self] current, anchor, change in
            guard let pick = self?.onPickColor else { return change(nil) }
            pick(current, anchor.offsetBy(dx: 0, dy: Self.barHeight), change)
        }
        templates.allTiles = TextTemplateTile.tiles(presets: [], builtIns: TextTemplateCatalog.all)
        templates.onPick = { [weak self] tile in
            guard let self else { return }
            if let s = TextTemplatePlacement.place(tile, presets: libraryPresets, session: self.session) { onStatus?(s) }
        }
    }

    // MARK: Transcribe (TextPanelView.ensure)

    /// Adds the Transcribe tab (shown first, as on the Mac) over `service`; one `CaptionsPanelModel` per sequence.
    public func useTranscription(_ service: @escaping @MainActor () -> any TranscriptionService) {
        self.service = service
        tabs = Tab.allCases
        tab = .transcript
        transcript.playhead = { [weak self] in self?.session.playhead ?? .zero }
        transcript.onMarkHits = { [weak self] times, name in
            guard let self else { return }
            var added = 0
            session.attempt("Mark Search Hits") { added = $0.addSearchHitMarkers(at: times, name: name) }
            onStatus?(added == 0 ? SQL10n.string("Every match already has a marker.") : SQL10n.plural(added, one: "Marked %@ match.", other: "Marked %@ matches."))
        }
        transcript.onMenu = { [weak self] items, anchor in self?.onMenu?(items, anchor.offsetBy(dx: 0, dy: Self.barHeight)) }
        syncTranscript()
    }

    /// The model of `id`'s sequence, made on first use.
    public func transcriptModel(for id: UUID) -> CaptionsPanelModel? { models[id] }

    /// Media files of the audible clips (a relinked file keeps its media id: the path is read fresh on every sync).
    private func sequenceSource(_ tl: Timeline) -> CaptionsPanelModel.SequenceSource {
        var urls: [UUID: URL] = [:]
        var maps: [UUID: AudioChannelMap] = [:]
        var counts: [UUID: Int] = [:]
        for c in TimelineTranscription.audibleClips(in: tl) {
            guard let ref = session.project.media(c.media) else { continue }
            urls[c.media] = URL(fileURLWithPath: ref.path)
            if let map = ref.info?.audio?.channelMap { maps[c.media] = map; counts[c.media] = ref.info?.audio?.channels }
        }
        return .init(timeline: tl, urls: urls, channelMaps: maps, expectedChannels: counts)
    }

    private func syncTranscript() {
        guard let service else { return }
        let ids = Set(session.project.timelines.map(\.id))
        for id in models.keys where !ids.contains(id) { models[id] = nil }
        guard let tl = session.activeTimeline else { transcript.model = nil; modelTimeline = nil; return }
        let model: CaptionsPanelModel
        if let m = models[tl.id] {
            model = m
            m.setSequenceSource(sequenceSource(tl))
        } else {
            model = CaptionsPanelModel(service: service())
            let projectID = session.project.id
            let language = AppSettings.captionLanguage(forProject: projectID)
            if !model.languages.contains(language) { model.languages.insert(language, at: 0) }
            model.language = language
            model.autoDetectLanguage = AppSettings.load().captionAutoLanguage
            // Picking another language in the panel is the per-project override.
            model.onLanguageChanged = { l in AppSettings.setCaptionLanguage(l, forProject: projectID) }
            // Words are in sequence time already.
            model.onSeek = { [weak self] t in self?.session.seek(to: t) }
            model.onCreateCaptions = { [weak self] captions in self?.addCaptions(captions) }
            model.setSequenceSource(sequenceSource(tl))
            models[tl.id] = model
            Task { await model.loadSupportedLanguages() }
        }
        model.frameDuration = tl.frameDuration
        if transcript.model !== model { transcript.model = model }
        modelTimeline = tl.id
    }

    private func addCaptions(_ captions: [Caption]) {
        let fd = session.activeTimeline?.frameDuration
        let items = captions.map { c in
            CaptionItem(lines: c.lines, range: c.range, styleRef: c.styleRef, animationRef: c.animationRef,
                        words: c.words.map { CaptionWord(text: $0.text, range: TimeRange(start: $0.range.start - c.range.start,
                                                                                        end: $0.range.end - c.range.start),
                                                         confidence: $0.confidence) })
        }
        let snapped = fd.map { CaptionMapping.snapped(items, to: $0) } ?? items
        guard !snapped.isEmpty else { onStatus?(SQL10n.string("There are no captions to create.")); return }
        if session.addCaptions(snapped) { onStatus?(SQL10n.format("Created %@ captions.", String(snapped.count))) }
    }

    /// The Templates tab on the Library (`EditorPanels.wireTextTemplatesTab`): the built-ins at once, the user's saved
    /// templates once `store` answers, re-read each time the tab opens (the Mac host observes the Library instead).
    /// shortcut: a pick does not count as a Library use (the use counter lives in the Mac `LibraryPanelModel`); record
    /// it when the Library panel runs on the shared toolkit.
    public func useLibrary(_ store: PresetStore) {
        let reload: @MainActor () -> Void = { [weak self] in
            guard let self, !loadingLibrary else { return }
            loadingLibrary = true
            Task { @MainActor [weak self] in
                let list = await store.presets(kind: nil)
                self?.setLibrary(list)
            }
        }
        onShowTemplates = reload
        reload()
    }

    /// The Library's items arrived: the tiles show the user's own templates first, then the built-ins.
    func setLibrary(_ presets: [PresetItem]) {
        loadingLibrary = false
        libraryPresets = presets
        templates.allTiles = TextTemplateTile.tiles(presets: presets, builtIns: TextTemplateCatalog.all)
    }

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 8, the SQSegmented height 22,
    // 10 pt label insets and 1 pt track padding; upgrade when SQUIKit's tokens move into a portable file.
    public static let barHeight: CGFloat = 38
    static let pad: CGFloat = 8
    static let segmentHeight: CGFloat = 22
    static let segmentInset: CGFloat = 10
    /// SQSegmented.trackPadding: the track edge to the first segment.
    static let trackPadding: CGFloat = 1

    var body: CGRect { CGRect(x: 0, y: Self.barHeight, width: size.width, height: max(size.height - Self.barHeight, 0)) }

    private func layoutPages() {
        captions.size = body.size; style.size = body.size; templates.size = body.size; transcript.size = body.size
    }

    public func select(_ t: Tab) {
        guard t != tab else { return }
        tab = t
        if t == .style { style.refresh() }
        if t == .templates { onShowTemplates?() }
    }

    /// The tab switch's segments; `widths` from the canvas the panel drew last (no atlas: 8 points per letter).
    private var segmentWidths: [Tab: CGFloat] = Dictionary(uniqueKeysWithValues: Tab.allCases.map { ($0, CGFloat($0.title.count) * 8 + 2 * TextPanelDraw.segmentInset) })

    func frame(_ t: Tab) -> CGRect {
        var x = Self.pad + Self.trackPadding
        for k in tabs where k.rawValue < t.rawValue { x += segmentWidths[k] ?? 0 }
        let y = ((Self.barHeight - Self.segmentHeight) / 2).rounded()
        return CGRect(x: x, y: y, width: segmentWidths[t] ?? 0, height: Self.segmentHeight)
    }

    private func tab(at p: CGPoint) -> Tab? {
        guard p.y < Self.barHeight else { return nil }
        return tabs.first { frame($0).contains(p) }
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - Self.barHeight) }

    // MARK: Session to UI

    /// A project or selection change (`TextPanelView.sync`).
    public func sync() {
        captions.sync()
        syncTranscript()
        if tab == .style { style.refresh() }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        if c.atlas != nil {
            for k in Tab.allCases { segmentWidths[k] = c.size(of: SQL10n.string(k.title), fontSize: fs).width.rounded(.up) + 2 * Self.segmentInset }
        }
        let all = tabs.map(frame)
        if let first = all.first, let last = all.last {
            // SQSegmented: the track is `fill2` with 6 pt corners, the segments sit 1 pt inside it.
            c.fill(roundedRect: first.union(last).insetBy(dx: -Self.trackPadding, dy: 0), radius: CGFloat(DrawTheme.Radius.control),
                   t.inkFill(0.06))
        }
        for k in tabs {
            let f = frame(k), on = k == tab
            if on || hoverTab == k || pressedTab == k {
                c.fill(roundedRect: f.insetBy(dx: 0, dy: Self.trackPadding), radius: CGFloat(DrawTheme.Radius.small),
                       on ? t.fillPressed : t.fillHover)
            }
            c.draw(SQL10n.string(k.title), in: f, fontSize: fs, on ? DrawColor.white : t.label, align: .center)
        }
        c.saveGState()
        c.clip(to: body)
        c.translateBy(x: 0, y: Self.barHeight)
        switch tab {
        case .transcript: transcript.draw(&c)
        case .captions: captions.draw(&c)
        case .style: style.draw(&c)
        case .templates: templates.draw(&c)
        }
        c.restoreGState()
    }

    // MARK: Pointer and keys

    public func mouseMoved(to p: CGPoint?) {
        hoverTab = p.flatMap(tab(at:))
        let q = p.flatMap { $0.y >= Self.barHeight ? local($0) : nil }
        switch tab {
        case .transcript: transcript.mouseMoved(to: q)
        case .captions: captions.mouseMoved(to: q)
        case .style: style.mouseMoved(to: q)
        case .templates: templates.mouseMoved(to: q)
        }
    }

    public func mouseDown(at p: CGPoint, modifiers m: InputModifiers = [], clickCount: Int? = nil) {
        if p.y < Self.barHeight {
            pressedTab = tab(at: p)
            pagePressed = false
            return
        }
        pagePressed = true
        let q = local(p)
        switch tab {
        case .transcript: transcript.mouseDown(at: q, modifiers: m, clickCount: clickCount)
        case .captions: captions.mouseDown(at: q, modifiers: m, clickCount: clickCount)
        case .style: style.mouseDown(at: q, modifiers: m, clickCount: clickCount)
        case .templates: templates.mouseDown(at: q)
        }
    }

    public func mouseDragged(to p: CGPoint) {
        guard pagePressed else { return }
        let q = local(p)
        switch tab {
        case .transcript: transcript.mouseDragged(to: q)
        case .captions: captions.mouseDragged(to: q)
        case .style: style.mouseDragged(to: q)
        case .templates: break
        }
    }

    public func mouseUp(at p: CGPoint) {
        if let t = pressedTab {
            pressedTab = nil
            if tab(at: p) == t { select(t) }
            return
        }
        guard pagePressed else { return }
        pagePressed = false
        let q = local(p)
        switch tab {
        case .transcript: transcript.mouseUp(at: q)
        case .captions: captions.mouseUp(at: q)
        case .style: style.mouseUp(at: q)
        case .templates: templates.mouseUp(at: q)
        }
    }

    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        guard p.y >= Self.barHeight else { return false }
        let q = local(p)
        switch tab {
        case .transcript: return transcript.scroll(at: q, dy: dy)
        case .captions: return captions.scroll(at: q, dy: dy)
        case .style: return style.scroll(at: q, dy: dy)
        case .templates: return templates.scroll(at: q, dy: dy)
        }
    }

    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        switch tab {
        case .transcript: transcript.key(k, modifiers: m)
        case .captions: captions.key(k, modifiers: m)
        case .style: style.key(k, modifiers: m)
        case .templates: templates.key(k, modifiers: m)
        }
    }

    public func tick() -> Bool { tab == .style ? style.tick() : false }

    public func help(at p: CGPoint) -> String? {
        guard p.y >= Self.barHeight else { return nil }
        let q = local(p)
        switch tab {
        case .transcript: return transcript.help(at: q)
        case .captions: return captions.help(at: q)
        case .style: return style.help(at: q)
        case .templates: return templates.help(at: q)
        }
    }

    /// Delete in the panel deletes the selected captions while the List tab shows (`TextPanelView.deleteSelectedCaptions`).
    public var showsCaptionList: Bool { tab == .captions }
}
