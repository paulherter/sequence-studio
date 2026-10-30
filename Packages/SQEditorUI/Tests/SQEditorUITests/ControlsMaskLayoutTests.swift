import AppKit
import Foundation
import SQCore
import SQText
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// The mask rows and the caption Style tab on the Controls grid, measured between control bounds at 324 / 364 / 520 pt:
/// equal leading edges, the grid's one gap between neighbors, tail on the trailing edge, lane rows with the row's y and
/// height. Builds on the rig of `ControlsSkeletonLayoutTests`.
@MainActor @Suite struct ControlsMaskLayoutTests {
    let rig = ControlsSkeletonLayoutTests()

    func maskPanel(width w: CGFloat, picture: Bool = false) throws -> EffectControlsView {
        let (s, _) = try rig.footage(.video)
        return rig.panel(s, width: w) { m in
            if let id = m.addMask(.rectangle) { m.toggleMaskPathKeyAtPlayhead(id) }      // keyed: its navigation shows
            if picture { _ = m.addPictureMask(track: nil) }
        }
    }

    func maskRows(_ v: EffectControlsView) -> [ControlsSkeletonLayoutTests.Probed] {
        rig.probes(v).filter { $0.view is MaskControlsRow || $0.view is MaskTrackRow || $0.view is MaskUseRow || $0.view is PictureMaskRow }
    }

    /// The key navigation of the Path row and the four-button navigation of a parameter row are the same width, and
    /// every button edge of both is a whole point.
    @Test func navigationHasOneWidthAndWholePointSlots() throws {
        for w in ControlsSkeletonLayoutTests.widths {
            let v = try maskPanel(width: w)
            let row = try #require(maskRows(v).first { $0.view is MaskControlsRow })
            let tail = try #require(row.probe.tail, "keyed mask path shows its navigation at \(w)")
            let param = ControlsKeyNavigation(propertyName: "P", onPrevious: {}, onToggleKey: {}, onNext: {}, onOpen: {})
            param.frame = ControlsGrid(width: w).navigationFrame(height: ControlsGrid.rowHeight)
            param.layoutSubtreeIfNeeded()
            #expect(tail.width == param.frame.width && tail.minX == param.frame.minX && tail.maxX == ControlsGrid(width: w).resetX - ControlsGrid.gap)
            #expect(tail.width.truncatingRemainder(dividingBy: 3) == 0 && tail.width.truncatingRemainder(dividingBy: 4) == 0)
            for b in param.subviews { #expect(b.frame.minX == b.frame.minX.rounded() && b.frame.width == b.frame.width.rounded()) }
        }
    }

    @Test func pathMaskRowsSitOnTheGrid() throws {
        for w in ControlsSkeletonLayoutTests.widths {
            let v = try maskPanel(width: w)
            rig.check(v, width: w, "mask")           // every row: grid edges, row height, lanes (y and height) as the row
            let rows = maskRows(v)
            #expect(rows.contains { $0.view is MaskControlsRow } && rows.contains { $0.view is MaskTrackRow } && rows.contains { $0.view is MaskUseRow },
                    "mask rows missing at \(w): \(rows.map { type(of: $0.view) })")
            let g = ControlsGrid(width: w)
            for r in rows {
                #expect(r.frame.height == ControlsGrid.rowHeight)
                switch r.view {
                case is MaskControlsRow:
                    // Inverted in the label column, Mode in value column 0, key navigation fills the tail column.
                    #expect(r.probe.label?.minX == ControlsGrid.labelX && r.probe.label?.width == ControlsGrid.labelWidth)
                    #expect(r.probe.controls.first?.minX == ControlsGrid.valueX)
                    // Full width, but never into the key navigation (2 pt short at the narrowest column since the
                    // rows sit one step right of the section title).
                    #expect(r.probe.controls.first?.maxX == min(ControlsGrid.valueX + Theme.Inspector.popupWidth, g.valueMaxX))
                    #expect(r.probe.tail?.width == ControlsGrid.navigationWidth && r.probe.tail?.minX == g.navigationX && r.probe.tail?.maxX == g.resetX - ControlsGrid.gap)
                    #expect(r.probe.toggle?.midX == ControlsGrid.toggleMidX)
                case is MaskTrackRow:
                    #expect(r.probe.label?.minX == ControlsGrid.labelX)
                    #expect(r.probe.controls.count == 3)
                    #expect(r.probe.controls[0].minX == ControlsGrid.valueX && r.probe.controls[0].width == ControlsGrid.controlHeight)
                    #expect(r.probe.tail?.minX == g.resetX && r.probe.tail?.maxX == g.tailMaxX)
                case is MaskUseRow:
                    #expect(r.probe.toggle?.midX == ControlsGrid.toggleMidX)
                    #expect(r.probe.label?.minX == ControlsGrid.labelX)
                    #expect(r.probe.controls.first?.minX == ControlsGrid.valueX && r.probe.controls.first!.maxX <= g.tailMaxX)
                default: break
                }
            }
        }
    }

    @Test func pictureMaskRowSitsOnTheGrid() throws {
        for w in ControlsSkeletonLayoutTests.widths {
            let v = try maskPanel(width: w, picture: true)
            rig.check(v, width: w, "picture mask")
            let pic = try #require(maskRows(v).first { $0.view is PictureMaskRow })
            let g = ControlsGrid(width: w)
            #expect(pic.probe.label?.minX == ControlsGrid.labelX)
            #expect(pic.probe.controls.count == 2 && pic.probe.controls[0].minX == ControlsGrid.valueX)
            #expect(pic.probe.controls[1].width == Theme.Inspector.channelWidth)
            #expect(pic.probe.tail?.maxX == g.tailMaxX)
            #expect(pic.probe.tail!.minX - pic.probe.controls[1].maxX == ControlsGrid.gap)
        }
    }

    /// The Subject mask row has the edges of the path mask's first line: Inverted in the label column, Mode in value
    /// column 0 (same left edge and width as `MaskControlsRow`), delete in the tail column, one gap between outlines.
    @Test func subjectMaskRowSitsOnTheGrid() throws {
        for w in ControlsSkeletonLayoutTests.widths {
            let (s, _) = try rig.footage(.video)
            #expect(s.addSubjectMask())
            let v = rig.panel(s, width: w) { m in
                if let id = m.addMask(.rectangle) { m.toggleMaskPathKeyAtPlayhead(id) }
                for id in m.subjectMaskIDs { m.collapsedSections.remove(.mask(id)) }     // sections start collapsed
            }
            rig.check(v, width: w, "subject mask")
            let all = rig.probes(v)
            let subject = try #require(all.first { $0.view is SubjectMaskRow }, "subject row missing at \(w): \(all.map { type(of: $0.view) }) \(v.model.subjectMaskIDs)")
            let path = try #require(all.first { $0.view is MaskControlsRow })
            let track = try #require(all.first { $0.view is MaskTrackRow })
            let g = ControlsGrid(width: w), p = subject.probe
            #expect(subject.frame.height == ControlsGrid.rowHeight && subject.frame.width == w)
            #expect(p.label?.minX == ControlsGrid.labelX && p.label?.minX == path.probe.label?.minX && p.label?.width == path.probe.label?.width)
            #expect(p.controls.count == 1 && p.controls[0].minX == ControlsGrid.valueX && p.controls[0].minX == path.probe.controls[0].minX)
            #expect(p.controls[0].width == Theme.Inspector.popupWidth)
            #expect(path.probe.controls[0].width == min(Theme.Inspector.popupWidth, g.valueMaxX - ControlsGrid.valueX))
            #expect(p.tail?.minX == g.resetX && p.tail?.maxX == g.tailMaxX && p.tail?.minX == track.probe.tail?.minX && p.tail?.maxX == track.probe.tail?.maxX)
            #expect(p.tail!.minX - p.controls[0].maxX >= ControlsGrid.gap)
            for c in p.controls + [p.label!, p.tail!] { #expect(abs(c.midY - subject.frame.height / 2) <= 0.5 && c.height <= ControlsGrid.controlHeight) }
        }
    }

    /// The subject row has no name of its own: the section header right above it carries the mask's name ("Subject"), a
    /// shape mask's header carries its own, so the two kinds differ by a visible title and never by their rows alone.
    @Test func subjectAndShapeMaskRowsAreToldApartByTheirHeader() throws {
        for w in ControlsSkeletonLayoutTests.widths {
            let (s, _) = try rig.footage(.video)
            #expect(s.addSubjectMask())
            let v = rig.panel(s, width: w) { m in
                _ = m.addMask(.rectangle)
                for id in m.subjectMaskIDs { m.collapsedSections.remove(.mask(id)) }
            }
            let all = rig.probes(v)
            let si = try #require(all.firstIndex { $0.view is SubjectMaskRow })
            let pi = try #require(all.firstIndex { $0.view is MaskControlsRow })
            let subjectHeader = try #require(all[..<si].last { $0.isHeader }, "no header above the subject row at \(w)")
            let pathHeader = try #require(all[..<pi].last { $0.isHeader }, "no header above the path row at \(w)")
            #expect(subjectHeader.title == "Subject")
            #expect(!pathHeader.title.isEmpty && pathHeader.title != subjectHeader.title)
        }
    }

    // MARK: Caption Style tab

    func captionTab(width w: CGFloat) -> CaptionStyleTabView {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        s.replaceCaptions([CaptionItem(lines: ["a"], range: TimeRange(start: Time(0, 1), end: Time(1, 1)), styleRef: "default")])
        let view = CaptionStyleTabView()
        view.session = s
        view.frame = NSRect(x: 0, y: 0, width: w, height: 1400)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func captionRows(_ v: NSView) -> [(frame: NSRect, probe: ControlsRowProbe)] {
        var out: [(frame: NSRect, probe: ControlsRowProbe)] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let p = view as? any ControlsRowProbing, view.bounds.width > 0, view.bounds.height > 0 { out.append((v.convert(view.bounds, from: view), p.rowProbe)) }
            view.subviews.forEach(walk)
        }
        walk(v)
        return out
    }

    @Test func captionStyleTabRowsSitOnTheGrid() {
        for w in ControlsSkeletonLayoutTests.widths {
            let v = captionTab(width: w)
            let rows = captionRows(v)
            #expect(rows.count >= 6, "caption rows at \(w): \(rows.count)")
            for (f, p) in rows {
                let name = "caption \(w) y\(f.minY)"
                #expect(f.height == ControlsGrid.rowHeight || f.height == ControlsGrid.headerHeight, "\(name): row height \(f.height)")
                if f.height == ControlsGrid.headerHeight { continue }       // a section header: its own pitch
                #expect(f.minX == 0 && f.width == w, "\(name): \(f)")
                if let l = p.label { #expect(l.minX == ControlsGrid.labelX, "\(name): label \(l)") }
                if let c = p.controls.first { #expect(c.minX == ControlsGrid.valueX, "\(name): first control \(c)") }
                for (a, b) in zip(p.controls, p.controls.dropFirst()) {
                    #expect(b.minX - a.maxX == ControlsGrid.gap, "\(name): gap \(b.minX - a.maxX)")
                }
                if let last = p.controls.last { #expect(last.maxX <= w - ControlsGrid.trailing, "\(name): \(last) past the trailing inset") }
                for c in p.controls { #expect(abs(c.midY - f.height / 2) <= 0.5 && c.height <= ControlsGrid.controlHeight, "\(name): \(c)") }
            }
        }
    }
}
