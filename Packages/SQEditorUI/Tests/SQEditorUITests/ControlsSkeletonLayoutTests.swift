import AppKit
import Foundation
import SQCore
import SQText
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// Text concept B, Bild 5: the Controls column is one skeleton on one grid. Every row of every section reports the
/// frames of its toggle, label, controls and tail (`ControlsRowProbing`); the tests build the panel for five kinds of
/// selection at three widths and compare those frames with the grid, measured between element bounds.
@MainActor @Suite struct ControlsSkeletonLayoutTests {
    static let widths: [CGFloat] = [352, 392, 520]

    // MARK: Rig

    func session(_ tracks: [Track] = [Track(kind: .video, isTargeted: true), Track(kind: .audio, isTargeted: true)]) -> EditorSession {
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: tracks)
        return EditorSession(project: Project(name: "P", timelines: [tl]))
    }

    func footage(_ kind: TrackKind) throws -> (EditorSession, Clip.ID) {
        let clip = Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                        mediaDuration: Time(60, 1))
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        if kind == .video { try v.overwrite(clip) } else { try a.overwrite(clip) }
        let s = session([v, a])
        s.select(clips: [clip.id])
        return (s, clip.id)
    }

    /// The panel as the app builds it, laid out with the Controls column `width` wide.
    func panel(_ session: EditorSession, width: CGFloat, configure: (EffectControlsModel) -> Void = { _ in }) -> EffectControlsView {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.speedSession = session
        if let c = session.displayedSelectedClip { m.setClip(c) }
        configure(m)
        let v = EffectControlsView(model: m)
        v.persistLabelWidth = { _ in }
        v.clipSections = ClipSectionsView(session: session)
        v.frame = NSRect(x: 0, y: 0, width: width + 400, height: 900)
        v.setLabelWidth(width)
        v.rebuild(reusing: false)
        v.layoutSubtreeIfNeeded()
        return v
    }

    struct Probed { var view: NSView; var frame: NSRect; var probe: ControlsRowProbe; var isHeader: Bool; var title: String }

    /// Every shown row of the column, top to bottom, with its frame in the content's coordinates.
    func probes(_ v: EffectControlsView) -> [Probed] {
        var out: [Probed] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let p = view as? any ControlsRowProbing, view.bounds.width > 0, view.bounds.height > 0 {
                var title = ""
                if let h = view as? SectionHeaderRow { title = h.title.stringValue }
                if let h = view as? InspectorSectionHeader { title = h.title }
                let header = view is SectionHeaderRow || view is InspectorSectionHeader
                out.append(Probed(view: view, frame: v.contentView.convert(view.bounds, from: view), probe: p.rowProbe, isHeader: header, title: title))
            }
            view.subviews.forEach(walk)
        }
        walk(v.contentView)
        return out.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The grid rules for one built panel. Returns the section titles in the order shown.
    @discardableResult
    func check(_ v: EffectControlsView, width: CGFloat, _ what: String) -> [String] {
        let rows = probes(v)
        #expect(!rows.isEmpty, "\(what) \(width)")
        let tailMaxX = width - ControlsGrid.trailing
        for r in rows {
            let name = "\(what) \(width) \(type(of: r.view)) \(r.title) y\(r.frame.minY)"
            // The row spans the column.
            #expect(r.frame.minX == 0 && r.frame.width == width, "\(name): row \(r.frame)")
            // One header height, one row height (a taller row is a whole multiple of nothing: it must be declared).
            if r.isHeader {
                #expect(r.frame.height == ControlsGrid.headerHeight, "\(name): header height \(r.frame.height)")
            } else if !isTall(r.view) {
                #expect(r.frame.height == ControlsGrid.rowHeight, "\(name): row height \(r.frame.height)")
            }
            // A section header sits at the inset; its rows (and a group header inside it) one step right of it.
            let indent = r.isHeader ? CGFloat(r.probe.level) * ControlsGrid.levelIndent : ControlsGrid.rowIndent
            if let t = r.probe.toggle { #expect(t.midX == ControlsGrid.headerToggleMidX + indent, "\(name): toggle \(t)") }
            if let l = r.probe.label, l.width > 0 { #expect(l.minX == ControlsGrid.headerLabelX + indent, "\(name): label \(l)") }
            let c = r.probe.controls
            if let first = c.first, r.probe.label != nil || !isTall(r.view) {
                #expect(first.minX == (r.probe.fullWidth ? ControlsGrid.labelX : ControlsGrid.valueX), "\(name): first control \(first)")
            }
            for (a, b) in zip(c, c.dropFirst()) {
                #expect(b.minX - a.maxX == ControlsGrid.gap, "\(name): gap \(b.minX - a.maxX) between \(a) and \(b)")
            }
            if let last = c.last { #expect(last.maxX <= tailMaxX, "\(name): last control \(last) past \(tailMaxX)") }
            if let t = r.probe.tail {
                // The reset slot (or delete) ends at the trailing edge; a bare key navigation ends one gap left of that slot.
                let navigationMaxX = ControlsGrid(width: width).resetX - ControlsGrid.gap
                #expect(t.maxX == tailMaxX || t.maxX == navigationMaxX, "\(name): tail \(t)")
                if let last = c.last { #expect(t.minX - last.maxX >= ControlsGrid.gap, "\(name): tail gap \(t.minX - last.maxX)") }
            }
            // Controls and label sit on the row's center line.
            if !isTall(r.view) {
                let mid = r.frame.height / 2
                for f in c + [r.probe.label].compactMap({ $0 }) where f.height > 0 {
                    #expect(abs(f.midY - mid) <= 0.5, "\(name): \(f) off the center line \(mid)")
                    #expect(f.height <= ControlsGrid.controlHeight, "\(name): control height \(f.height)")
                }
            }
        }
        // Rows never overlap, and they follow each other without holes other than the section gap.
        for (a, b) in zip(rows, rows.dropFirst()) {
            #expect(b.frame.minY >= a.frame.maxY, "\(what) \(width): \(type(of: b.view)) \(b.title) at \(b.frame.minY) overlaps \(type(of: a.view)) ending \(a.frame.maxY)")
        }
        // The lane rows are the row views: same y, same height.
        let views = v.shownRowViews
        #expect(v.lanes.rows.count == views.count)
        for (lane, view) in zip(v.lanes.rows, views) {
            #expect(lane.y == view.frame.minY && lane.height == view.frame.height, "\(what) \(width): lane \(lane.y)/\(lane.height) vs row \(view.frame)")
        }
        // Every row reports its frames; the exceptions are named (rows that are one custom editor, and the mask rows).
        for view in views where !(view is any ControlsRowProbing) {
            let type = String(describing: type(of: view))
            #expect(Self.unprobed.contains(type), "\(what) \(width): \(type) reports no frames")
            // An opened row's curve spans the column and the lanes: it starts at the column's left edge and reaches past it.
            if view is SpeedGraphRow {
                #expect(view.frame.minX == 0 && view.frame.width > width, "\(what) \(width): \(type) \(view.frame)")
                continue
            }
            #expect(view.frame.minX == 0 && view.frame.width == width, "\(what) \(width): \(type) \(view.frame)")
        }
        return rows.filter(\.isHeader).map(\.title)
    }

    /// Row views that do not report frames: the mask rows (owned by the mask work, not on the grid's probe yet) and the
    /// curve of an opened row (one editor over column and lanes).
    static let unprobed: Set<String> = ["MaskControlsRow", "MaskTrackRow", "MaskUseRow", "SpeedGraphRow"]

    /// Rows that are taller than the grid row by design: the text box, the compressor's crossover strip.
    func isTall(_ view: NSView) -> Bool {
        guard let r = view as? TextBlockRow else { return false }
        return r.bounds.height > ControlsGrid.rowHeight
    }

    func order(_ titles: [String], _ expected: [String], _ what: String) {
        let found = expected.map { titles.firstIndex(of: $0) }
        #expect(!found.contains(nil), "\(what): \(titles) misses one of \(expected)")
        let idx = found.compactMap { $0 }
        #expect(idx == idx.sorted(), "\(what): \(titles) not in the order \(expected)")
    }

    // MARK: The five selections

    @Test func gridNumbers() {
        // Section header at the inset, rows one step (12 pt, the list panels' step) right of it.
        #expect(ControlsGrid.headerToggleMidX == 15 && ControlsGrid.headerLabelX == 28 && ControlsGrid.rowIndent == 12)
        #expect(ControlsGrid.rowIndent == Theme.Spacing.md && ControlsGrid.levelIndent == ControlsGrid.rowIndent)
        #expect(ControlsGrid.toggleMidX == 27 && ControlsGrid.labelX == 40 && ControlsGrid.valueX == 134)
        #expect(ControlsGrid.valueColumn(1) == 190 && ControlsGrid.valueColumn(2) == 246)
        #expect(ControlsGrid.gap == 6 && ControlsGrid.trailing == 12 && ControlsGrid.valueWidth == 50)
        #expect(ControlsGrid.rowHeight == 26 && ControlsGrid.headerHeight == 26 && ControlsMetrics.sectionGap == 0)
    }

    @Test func textClip() throws {
        for w in Self.widths {
            let s = session()
            _ = try #require(s.addTextClip(template: TextTemplate(name: "T", text: "Hi", style: TextStyle(fontName: "Helvetica", size: 80, color: .white))))
            let v = panel(s, width: w)
            let titles = check(v, width: w, "text")
            order(titles, ["Text", EffectSection.motion.title, "Animation"], "text \(w)")
            #expect(titles.first == "Text")
            #expect(v.clipInfoLabel.stringValue.hasPrefix("Text \u{00B7} "))
        }
    }

    /// The Animation section in its three states. Off and a preset show no rows of their own; Custom shows one section
    /// per side with Position, Scale, Rotation and Opacity, each a Controls row with its lane, one of them opened.
    @Test func textClipAnimationOffPresetAndCustom() throws {
        let template = TextTemplate(name: "T", text: "Hi", style: TextStyle(fontName: "Helvetica", size: 80, color: .white))
        let intro = EffectSection.animation(.intro).title, outro = EffectSection.animation(.outro).title
        let fade = CaptionPresetLibrary.builtIn.animation(for: "fade")
        let states: [(String, AnimationSet?, [String])] = [
            ("off", nil, []),
            ("preset", AnimationSet(in: fade, out: nil), []),
            ("custom", AnimationSet(in: .customStart(.intro), out: .customStart(.outro)), [intro, outro]),
        ]
        let opened = EffectProperty.anim(.intro, .opacity)
        for w in Self.widths {
            for (name, set, sections) in states {
                let s = session()
                let id = try #require(s.addTextClip(template: template))
                s.updateTextClip(id, template: template, animations: set, continuesGesture: false)
                let v = panel(s, width: w) { $0.collapsedSections = []; $0.expanded = [opened] }
                let titles = check(v, width: w, "animation \(name)")
                order(titles, [EffectSection.motion.title, "Animation"] + sections, "animation \(name) \(w)")
                #expect(titles.contains(intro) == !sections.isEmpty && titles.contains(outro) == !sections.isEmpty, "\(name) \(w): \(titles)")
                let rows = v.lanes.rows
                let mine = rows.filter { if case .property(let p) = $0.kind, case .anim = p { return true } else { return false } }
                #expect(mine.count == (sections.isEmpty ? 0 : 8), "\(name) \(w): \(mine.count) animation rows in \(rows.map(\.kind))")
                let graphs = rows.filter { if case .graph = $0.kind { return true } else { return false } }
                #expect(graphs.count == (sections.isEmpty ? 0 : 1), "\(name) \(w): \(graphs.count) open curves")
                guard !sections.isEmpty else { continue }
                // The opened row's curve sits directly under its row, and both are the frames of their row views.
                let i = try #require(rows.firstIndex { if case .property(let p) = $0.kind { return p == opened } else { return false } })
                #expect({ if case .graph = rows[i + 1].kind { return true } else { return false } }(), "\(name) \(w): no curve under the row")
                #expect(rows[i + 1].y == rows[i].y + rows[i].height)
                #expect(rows[i].height == ControlsGrid.rowHeight)
                #expect(v.shownRowViews[i].frame.minY == rows[i].y && v.shownRowViews[i + 1].frame.height == rows[i + 1].height)
                // Every Custom row (Scale, Opacity, Position, Rotation per side) sits on the grid, in plain numbers.
                for (lane, view) in zip(rows, v.shownRowViews) {
                    guard case .property(let p) = lane.kind, case .anim = p else { continue }
                    let what = "\(name) \(w) \(p)"
                    let probe = try #require((view as? any ControlsRowProbing)?.rowProbe, "\(what): no frames")
                    #expect(view.frame.height == 26 && lane.y == view.frame.minY && lane.height == 26, "\(what): \(view.frame)")
                    #expect(probe.label?.minX == 40, "\(what): label \(String(describing: probe.label))")
                    #expect(probe.controls.first?.minX == 134, "\(what): controls \(probe.controls)")
                    for (a, b) in zip(probe.controls, probe.controls.dropFirst()) { #expect(b.minX - a.maxX == 6, "\(what): gap") }
                    // The key navigation shows on a keyed row only (a new Custom side keys Opacity).
                    if case .anim(_, .opacity) = p { #expect(probe.tail != nil, "\(what): no key navigation") }
                    if let tail = probe.tail {
                        #expect(tail.maxX == w - 12 && [ControlsGrid.resetWidth, ControlsGrid.navigationWidth + ControlsGrid.gap + ControlsGrid.resetWidth].contains(tail.width), "\(what): tail \(tail)")
                        if let last = probe.controls.last { #expect(tail.minX - last.maxX >= 6, "\(what): tail gap") }
                    }
                }
            }
        }
    }

    @Test func shapeClip() throws {
        for w in Self.widths {
            let s = session()
            _ = try #require(s.addShapeClip(.ellipse))
            let v = panel(s, width: w)
            let titles = check(v, width: w, "shape")
            order(titles, ["Shape", EffectSection.motion.title], "shape \(w)")
            #expect(titles.first == "Shape")
            #expect(v.clipInfoLabel.stringValue.hasPrefix("Shape \u{00B7} "))
        }
    }

    @Test func graphicClip() throws {
        for w in Self.widths {
            let s = session()
            _ = try #require(s.addGraphicsClip())
            let v = panel(s, width: w)
            let titles = check(v, width: w, "graphic")
            order(titles, ["Graphic", EffectSection.motion.title], "graphic \(w)")
            #expect(titles.first == "Graphic")
        }
    }

    /// A Graphic clip with two selected shape items: their basics (Corners, Fill, Outline) are grid rows of the Graphic section.
    func graphicPanel(_ kind: ShapeKind, width w: CGFloat) throws -> (EffectControlsView, GraphicsEditor, GraphicItemRows) {
        let s = session()
        _ = try #require(s.addGraphicsClip())
        let editor = GraphicsEditor(session: s)
        editor.sync()
        // One picked item shows as its own clip (its Shape section carries the values), so the item rows are for several.
        editor.addShape(kind)
        editor.addShape(kind)
        editor.select(Set(editor.document?.layers.map(\.id) ?? []))
        #expect(editor.selectedLayers.count == 2)
        let v = panel(s, width: w)
        let sections = try #require(v.clipSections)
        sections.graphicsEditor = editor
        sections.sync([.project, .selection])
        v.rebuild(reusing: false)
        v.layoutSubtreeIfNeeded()
        return (v, editor, sections.graphicView.itemRows)
    }

    func rowLabels(_ v: EffectControlsView) -> [String] {
        probes(v).compactMap { r in
            if let t = r.view as? TextBlockRow { return t.label?.stringValue }
            if let h = r.view as? AppearanceHead { return h.label.stringValue }
            return nil
        }
    }

    @Test func graphicClipWithASelectedShapeItem() throws {
        for w in Self.widths {
            let (v, editor, rows) = try graphicPanel(.rectangle, width: w)
            let titles = check(v, width: w, "graphic item")
            order(titles, ["Graphic", EffectSection.motion.title], "graphic item \(w)")
            #expect(Array(rowLabels(v).prefix(3)) == ["Corners", "Fill", "Outline"], "\(w): \(rowLabels(v))")
            // Fill and Outline: check in the toggle column, swatch in value column 0, the value in column 1.
            for head in [rows.fill.head, rows.outline.head] {
                let p = head.rowProbe
                #expect(p.toggle != nil)
                #expect(p.controls.map(\.minX) == [ControlsGrid.valueColumn(0), ControlsGrid.valueColumn(1)])
                #expect(head.chevron.isHidden)
            }
            #expect(rows.cornersRow.rowProbe.controls.map(\.width) == [ControlsGrid.valueWidth])
            _ = editor
        }
    }

    @Test func theItemRowsFollowTheKindOfTheSelectedItem() throws {
        let w = Self.widths[0]
        let (ellipse, e1, _) = try graphicPanel(.ellipse, width: w)
        check(ellipse, width: w, "graphic ellipse")
        #expect(Array(rowLabels(ellipse).prefix(2)) == ["Fill", "Outline"])
        let (line, e2, _) = try graphicPanel(.line, width: w)
        check(line, width: w, "graphic line")
        #expect(rowLabels(line).first == "Outline")
        #expect(!rowLabels(line).contains("Fill") && !rowLabels(line).contains("Corners"))
        // No item selected: only the "Edit in Graphics" row.
        let (none, e3, rows) = try graphicPanel(.rectangle, width: w)
        e3.select([])
        rows.refresh()
        none.rebuild(reusing: false)
        none.layoutSubtreeIfNeeded()
        check(none, width: w, "graphic no item")
        #expect(rows.isHidden)
        #expect(!rowLabels(none).contains("Outline"))
        _ = (e1, e2)
    }

    /// The rows write the item's Shape effect (the same values the Graphics panel and the keyframe rows edit), one undo
    /// step per gesture.
    @Test func theItemRowsEditTheShapeEffect() throws {
        let (_, editor, rows) = try graphicPanel(.rectangle, width: Self.widths[0])
        let s = editor.session
        func shape() throws -> ClipEffect {
            let layer = try #require(editor.targetLayers.first)
            return try #require(layer.effects.first { $0.kind == ClipEffect.shapeEffectKind })
        }
        rows.corners.onBegin?()
        rows.corners.onChange?(10)
        rows.corners.onChange?(24)
        #expect(try shape().scalar(ClipEffect.shapeCornerRadiusKey, atLocal: .zero) == 24)
        rows.outline.value.onBegin?()
        rows.outline.value.onChange?(12)
        #expect(try shape().scalar(ClipEffect.shapeStrokeWidthKey, atLocal: .zero) == 12)
        rows.fill.value.onBegin?()
        rows.fill.value.onChange?(50)
        #expect(editor.shapeColor(ClipEffect.shapeFillColorKey)?.alpha == 0.5)
        rows.refresh()
        #expect(rows.corners.value == 24 && rows.outline.value.value == 12 && rows.fill.value.value == 50)
        // Three gestures, three undo steps: the first undo restores the fill only.
        s.undo()
        #expect(editor.shapeColor(ClipEffect.shapeFillColorKey)?.alpha == 1)
        #expect(try shape().scalar(ClipEffect.shapeStrokeWidthKey, atLocal: .zero) == 12)
        s.undo(); s.undo()
        #expect(try shape().scalar(ClipEffect.shapeCornerRadiusKey, atLocal: .zero) != 24)
    }

    @Test func fillOpacityKeepsTheColorOfEveryItem() throws {
        let (_, editor, rows) = try graphicPanel(.rectangle, width: Self.widths[0])
        let first = try #require(editor.selectedLayers.first)
        editor.setShapeColor(ClipEffect.shapeFillColorKey, EffectColor(red: 1, green: 0, blue: 0))
        editor.addShape(.ellipse)
        let second = try #require(editor.selectedLayers.first)
        editor.setShapeColor(ClipEffect.shapeFillColorKey, EffectColor(red: 0, green: 0, blue: 1))
        editor.select([first, second])
        rows.refresh()
        #expect(rows.fill.value.value == 100)
        rows.fill.value.onBegin?()
        rows.fill.value.onChange?(50)
        func fill(_ id: UUID) throws -> EffectColor {
            editor.select([id])
            return try #require(editor.shapeColor(ClipEffect.shapeFillColorKey))
        }
        #expect(try fill(first) == EffectColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(try fill(second) == EffectColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        editor.select([first, second])
        rows.refresh()
        #expect(rows.fill.value.value == 50)
        // One gesture, one undo step for both items.
        editor.session.undo()
        #expect(try fill(first).alpha == 1)
        #expect(try fill(second).alpha == 1)
    }

    @Test func videoClipWithEffectsMaskAndSpeed() throws {
        for w in Self.widths {
            let (s, id) = try footage(.video)
            #expect(s.addEffect(kind: ClipEffect.gaussianBlurKind, to: [id]))
            #expect(s.addEffect(kind: ClipEffect.dropShadowKind, to: [id]))
            let v = panel(s, width: w) { m in _ = m.addMask(.rectangle) }
            let titles = check(v, width: w, "video")
            // Opacity is a row of Transform; then Speed, the mask, each applied effect.
            #expect(titles == [EffectSection.motion.title, EffectSection.speed.title, "Mask (1)", "Blur", "Drop Shadow"], "video \(w): \(titles)")
            // Footage: the clip line shows the v9 meta (sequence, track, range); the kind is the icon and the tooltip.
            #expect(v.clipInfoLabel.stringValue.contains(" \u{2013} ") && v.clipIconName == .film)
            #expect(v.clipInfoLabel.sqToolTip?.hasPrefix("Video \u{00B7} ") == true)
        }
    }

    @Test func audioClip() throws {
        for w in Self.widths {
            let (s, _) = try footage(.audio)
            let v = panel(s, width: w)
            let titles = check(v, width: w, "audio")
            #expect(titles.last == "Audio", "audio \(w): \(titles)")
            #expect(titles.count >= 2)
        }
    }

    /// An audio clip without keys: the "No keyframes" hint of the lanes starts below the whole column (the Audio
    /// section is placed after the rows), never beside it.
    @Test func noKeyframesHintStartsBelowTheLastSection() throws {
        for w in Self.widths {
            let (s, _) = try footage(.audio)
            let v = panel(s, width: w)
            let sections = try #require(v.clipSections)
            #expect(sections.mode == .audio && sections.frame.height > 0)
            #expect(v.lanes.showsNoKeysHint)
            #expect(v.lanes.contentBottom == v.placement.height)
            // The lanes share the content's vertical origin, so the two frames compare directly.
            #expect(v.lanes.emptyHint.frame.minY >= sections.frame.maxY, "\(w): hint \(v.lanes.emptyHint.frame.minY), Audio ends \(sections.frame.maxY)")
            #expect(v.lanes.emptyHint.frame.minY >= (v.lanes.rows.last.map { $0.y + $0.height } ?? 0))
        }
    }

    func captionSession() throws -> (EditorSession, [CaptionItem]) {
        let s = session()
        _ = try #require(s.addCaptionTrack())
        let items = (0..<5).map { CaptionItem(lines: ["Caption \($0)"], range: TimeRange(start: Time(Int64($0), 1), duration: Time(1, 1))) }
        #expect(s.addCaptions(items))
        return (s, items)
    }

    /// All Captions is the last section of the column: one list (`CaptionReadListView`), on the grid, a click seeks.
    @Test func captionTrackShowsAllCaptions() throws {
        for w in Self.widths {
            let (s, _) = try captionSession()
            s.select(clips: [])
            let v = panel(s, width: w)
            let sections = try #require(v.clipSections)
            #expect(sections.mode == .captions)
            let titles = check(v, width: w, "captions")
            #expect(titles == ["All Captions"])
            #expect(v.clipInfoLabel.stringValue == "Captions \u{00B7} 5")

            let list = sections.captionList
            #expect(!list.isHidden)
            #expect(list.model.rows.count == 5)
            // The list spans the column under its header; time and text sit on the label and the control column.
            let header = try #require(probes(v).first { $0.isHeader })
            let frame = v.contentView.convert(list.bounds, from: list)
            #expect(frame.minX == 0 && frame.width == w, "\(w): \(frame)")
            #expect(frame.minY == header.frame.maxY)
            #expect(frame.height >= 3 * Theme.Row.list && frame.maxY <= v.placement.height)
            for i in 0..<5 {
                let c = list.columns(row: i)
                #expect(c.time.minX == ControlsGrid.labelX && c.time.maxX == ControlsGrid.labelX + Theme.Inspector.nameWidth)
                #expect(c.text.minX == ControlsGrid.valueX)
                #expect(c.text.maxX == w - ControlsGrid.trailing, "\(w) row \(i): \(c.text)")
                #expect(c.time.height == Theme.Row.list)
            }
            // Read only: a click moves the playhead, the mark follows it.
            list.click(row: 2)
            #expect(s.playhead == Time(2, 1))
            sections.sync(.playhead)
            #expect(list.currentRow == 2)
        }
    }

    /// A selected caption keeps the list; a selected clip replaces it; a sequence without captions has none.
    @Test func allCaptionsShowsForACaptionSelectionOnly() throws {
        let (s, _) = try captionSession()
        let id = try #require(s.currentCaptionTrack?.items.first?.id)
        s.select(clips: [], captions: [id])
        let v = panel(s, width: 364)
        #expect(v.clipSections?.mode == .captions)
        #expect(check(v, width: 364, "caption selected") == ["All Captions"])

        let (a, _) = try footage(.audio)
        _ = try #require(a.addCaptionTrack())
        #expect(panel(a, width: 364).clipSections?.mode == .audio)

        let empty = session()
        empty.select(clips: [])
        let none = panel(empty, width: 364)
        #expect(none.clipSections?.mode == ClipSectionMode.none)
        #expect(none.clipSections?.captionList.isHidden == true)
    }

    /// The Look list is read once and kept: a project change (every edit) does not read the Look store again; a Look
    /// action does.
    @Test func lookListIsNotRebuiltOnEveryProjectChange() throws {
        let s = session()
        _ = try #require(s.addTextClip(template: TextTemplate(name: "T", text: "Hi", style: TextStyle(fontName: "Helvetica", size: 80, color: .white))))
        let v = panel(s, width: 364)
        let sections = try #require(v.clipSections)
        #expect(sections.mode == .text)
        sections.sync(.project)
        let built = sections.lookListBuilds
        #expect(built >= 1)
        for _ in 0..<5 { sections.sync(.project); sections.sync([.project, .selection]) }
        #expect(sections.lookListBuilds == built)
        sections.looksChanged()
        #expect(sections.lookListBuilds == built + 1)
        NotificationCenter.default.post(name: LookStore.didChange, object: LookStore.shared)
        #expect(sections.lookListBuilds == built + 2)
    }

    /// One Look menu in every host: Save as New Look with the name prompt, no Duplicate.
    @Test func lookMenuIsTheSameInEveryHost() throws {
        // Model only (Graphics): the block saves into its own text looks.
        let m = TextInspectorModel(style: TextStyle(fontName: "Helvetica", size: 80, color: .white), animations: AnimationSet(in: nil, out: nil),
                                   library: .builtIn, fontFamilies: { ["Helvetica"] }, styles: TextStyleLibrary())
        let block = TextBlockView(model: m, context: .graphics)
        var asked: [String] = []
        block.askLookName = { title, _ in asked.append(title); return "Mine" }
        #expect(block.lookContextItems().map(\.title) == ["Save as New Look\u{2026}"])
        block.lookContextItems().first?.action?()
        #expect(asked == ["Save as New Look"])
        let id = try #require(m.appliedStyleID)
        #expect(m.styles.entry(id)?.name == "Mine")
        let own = block.lookContextItems().map(\.title)
        #expect(own == ["Update \u{201C}Mine\u{201D}", "Save as New Look\u{2026}", "Rename\u{2026}", "Delete"])
        #expect(!own.contains("Duplicate"))
        block.askLookName = { title, _ in asked.append(title); return nil }       // canceled: nothing is saved
        block.lookContextItems()[1].action?()
        #expect(m.styles.user.count == 1)

        // A host with its own Look list (Captions > Look): the same item, routed to the host.
        var added = 0
        block.lookSource = { .init(titles: [], ids: [], selected: nil, pick: { _ in }, add: { added += 1 }) }
        #expect(block.lookContextItems().map(\.title) == ["Save as New Look\u{2026}"])
        block.lookContextItems().first?.action?()
        #expect(added == 1)

        // Controls: the same four items for a user Look, one for none.
        #expect(TextBlockView.lookMenuItems(editable: nil, saveNew: {}).map(\.title) == ["Save as New Look\u{2026}"])
        #expect(TextBlockView.lookMenuItems(editable: "A", saveNew: {}).map(\.title) == ["Update \u{201C}A\u{201D}", "Save as New Look\u{2026}", "Rename\u{2026}", "Delete"])
    }

    /// The content slot ends at the divider at every width, and the sections of one column share one gap.
    @Test func sectionsAreOneGapApart() throws {
        let s = session()
        _ = try #require(s.addTextClip(template: TextTemplate(name: "T", text: "Hi", style: TextStyle(fontName: "Helvetica", size: 80, color: .white))))
        let v = panel(s, width: 364)
        let rows = probes(v)
        for (i, r) in rows.enumerated() where r.isHeader && i > 0 {
            let before = rows[i - 1]
            #expect(r.frame.minY - before.frame.maxY == ControlsMetrics.sectionGap, "\(r.title): \(r.frame.minY - before.frame.maxY) below \(type(of: before.view))")
        }
    }
}
