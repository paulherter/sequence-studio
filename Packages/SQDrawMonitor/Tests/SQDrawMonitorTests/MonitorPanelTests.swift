import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQGPUKernels
import SQUIKit
@testable import SQDrawMonitor

@MainActor
@Suite struct MonitorPanelTests {
    func panel(_ mode: MonitorMode = .program) -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: mode)
        m.duration = Time(250, 25)
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        return p
    }

    func draw(_ p: MonitorPanel) {
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
    }

    @Test func fitPictureSitsInsideTheTwelvePointMargin() {
        let p = panel()
        #expect(p.slot.minX == 12)
        #expect(abs(p.canvasRect.width / p.canvasRect.height - 16.0 / 9.0) < 0.01)
        #expect(p.slot.contains(p.canvasRect.insetBy(dx: 1, dy: 1)))
    }

    @Test func offlineCardCentersOnTheSlotWhileAFileIsOffline() {
        let p = panel()
        #expect(p.offlineCardRect(titleWidth: 80, detailWidth: 160) == nil)
        p.model.offlineFileName = "A001.mov"
        #expect(p.model.offlineCardDetail == "A001.mov was moved or renamed")
        let r = p.offlineCardRect(titleWidth: 80, detailWidth: 160)
        #expect(r?.width == 192)
        #expect(r?.height == 44)
        #expect(abs((r?.midX ?? 0) - p.slot.midX) <= 0.5)
        #expect(abs((r?.midY ?? 0) - p.slot.midY) <= 0.5)
        let wide = p.offlineCardRect(titleWidth: 80, detailWidth: 5000)
        #expect(wide?.width == p.slot.width - 32)
        // No black frame under the card (the Mac monitor's gray backdrop shows).
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        let frame = c.px(p.canvasRect)
        #expect(!c.list.quads.contains { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 && $0.x == frame.x && $0.w == frame.w })
    }

    @Test func zoomPopupValueReachesThePicture() {
        let p = panel()
        p.model.setZoom(.percent(100))
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        #expect(p.viewerZoom == .percent(100))
        #expect(p.canvasRect.width == 1920)
        #expect(p.slot.minX == 0)
    }

    @Test func ctrlWheelZoomsAboutThePointerAndShowsTheValue() {
        let p = panel()
        let mid = p.slot
        // AppKit sign: the wheel away from the user (positive deltaY) zooms in, as ProgramSurfaceView.
        _ = p.handle(.scroll(x: Float(mid.midX), y: Float(mid.midY), dx: 0, dy: 40, modifiers: .command))
        guard case .view(let s, _, _) = p.viewerZoom else { Issue.record("no view zoom"); return }
        #expect(s > Double(p.mapping.fitScale) * 0.99)
        #expect(p.model.zoom == .custom(Int((s * 100).rounded())))
    }

    @Test func pinchZoomsAndTrackpadPointsPanOneToOneAsTheMacSurface() {
        let p = panel()
        let mid = p.slot
        let h = HostGesture()
        HostGesture.$current.withValue(h) {
            let at = (x: Float(mid.midX), y: Float(mid.midY))
            let fit = Double(p.mapping.scale)
            _ = h.with(ScrollGesture(kind: .magnify(0.5), precise: true, phase: .changed)) {
                p.handle(.scroll(x: at.x, y: at.y, dx: 0, dy: 0, modifiers: []))
            }
            #expect(abs(Double(p.mapping.scale) / fit - 1.5) < 1e-6)
            // Trackpad: 10 pt of fingers move the picture 10 pt (the host's 20 px at 2x do not count).
            let c0 = p.canvasRect.minX
            _ = h.with(ScrollGesture(deltaX: 10, precise: true, phase: .changed)) {
                p.handle(.scroll(x: at.x, y: at.y, dx: 20, dy: 0, modifiers: []))
            }
            #expect(abs(p.canvasRect.minX - c0 - 10) < 0.5)
            // Mouse wheel: a line moves 8 pt.
            let c1 = p.canvasRect.minX
            _ = h.with(ScrollGesture(deltaX: 1)) { p.handle(.scroll(x: at.x, y: at.y, dx: 0, dy: 0, modifiers: [])) }
            #expect(abs(p.canvasRect.minX - c1 - 8) < 0.5)
        }
    }

    @Test func tabsReplaceTheTitleAndAClickSwitches() {
        let p = panel()
        p.tabs = ["Program", "Source"]
        var picked: [Int] = []
        p.onSelectTab = { picked.append($0) }
        draw(p)
        #expect(p.tabRects.count == 2)
        let source = p.tabRects[1], program = p.tabRects[0]
        _ = p.handle(.mouseDown(x: Float(program.midX), y: Float(program.midY), modifiers: []))
        #expect(picked.isEmpty)                                   // the shown tab: nothing to switch
        #expect(p.handle(.mouseDown(x: Float(source.maxX), y: Float(source.midY), modifiers: [])))
        #expect(picked == [1])
    }

    /// The header tabs lay out like the dock's tab strip (10 pt padding, 2 pt apart, first tab `sm - 2` in), and the header line
    /// is no longer the full-width marker.
    @Test func tabsFollowTheDockStripLayout() {
        let p = panel()
        p.tabs = ["Program", "Source"]
        draw(p)
        #expect(p.tabRects.count == 2)
        #expect(p.tabRects[0].minX == p.headerRect.minX + CGFloat(DrawTheme.Spacing.sm) - 2)
        #expect(p.tabRects[1].minX == p.tabRects[0].maxX + 2)
        #expect(p.tabRects[0].width >= 20)
    }

    @Test func emptyProgramOffersNewSequenceAndTheClickCallsIt() {
        let p = panel()
        p.model.hasSequence = false
        var calls = 0
        p.model.onNewSequence = { calls += 1 }
        draw(p)
        let r = p.newSequenceRect
        #expect(r.width > 0)
        _ = p.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(r.midX), y: Float(r.midY)))
        #expect(calls == 1)
        p.model.hasSequence = true
        draw(p)
        #expect(p.newSequenceRect == .zero)
    }

    @Test func emptyProgramStacksPipHintAndButtonAndOnlyWithAHost() {
        let p = panel()
        p.model.hasSequence = false
        p.model.onNewSequence = {}
        draw(p)
        #expect(p.emptyMascotRect == .zero)                       // no mascot closure: the text stack as before
        var drawn: [CGRect] = []
        p.emptyMascot = { _, r in drawn.append(r) }
        draw(p)
        let pip = p.emptyMascotRect
        #expect(drawn == [pip])
        #expect(pip.width == MonitorPanel.emptyMascotSide && pip.height == MonitorPanel.emptyMascotSide)
        #expect(abs(pip.midX - p.slot.midX) <= 0.5)
        #expect(pip.maxY + 14 <= p.newSequenceRect.minY)          // Pip above the hint, the button below it
        #expect(p.slot.contains(pip) && p.slot.contains(p.newSequenceRect))
        p.model.hasSequence = true
        p.model.timelineIsEmpty = true
        draw(p)
        #expect(p.emptyMascotRect.width > 0)                      // an empty timeline keeps Pip and the hint (no button)
        p.model.timelineIsEmpty = false
        draw(p)
        #expect(p.emptyMascotRect == .zero)
    }

    @Test func sourceEmptyStateHasNoPip() {
        let p = panel(.source)
        p.emptyMascot = { _, _ in Issue.record("Source draws no Pip") }
        draw(p)
        #expect(p.emptyMascotRect == .zero)
    }

    @Test func headerLineIsAccentOnlyWhileFocusedAndSitsAtTheHeaderBottom() {
        let p = panel()
        let r = MonitorPanel.activeLineRect(header: p.headerRect)
        #expect(r.maxY == p.headerRect.maxY && r.height == 2)
        #expect(r.minX == p.headerRect.minX + CGFloat(DrawTheme.Spacing.sm))
        func lineColors() -> [DrawColor] {
            var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
            p.draw(&c)
            return [p.theme.accent, p.theme.label3].filter { col in
                c.list.quads.contains { $0.w == c.px(r).w && $0.h == c.px(r).h && $0.r == col.r && $0.g == col.g && $0.b == col.b }
            }
        }
        p.isFocused = true
        #expect(lineColors().contains(p.theme.accent))
        p.isFocused = false
        #expect(!lineColors().contains(p.theme.accent))
    }

    @Test func dropHighlightPaintsTheCardAndTheHalfZone() {
        let p = panel()
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        let plain = c.list.quads.count
        p.dropHighlight = true
        var c2 = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c2)
        #expect(c2.list.quads.count > plain)
    }

    @Test func wheelAtFitDoesNotPan() {
        let p = panel()
        _ = p.handle(.scroll(x: 400, y: 200, dx: 0, dy: 40, modifiers: []))
        #expect(p.viewerZoom == .fit)
    }

    @Test func headerOffersZoomQualityAndTheMonitorMenu() {
        let p = panel()
        draw(p)
        let ctls = p.headerControls.map(\.0)
        #expect(ctls.contains(.options))
        #expect(ctls.contains(.zoom))
        #expect(ctls.contains(.quality))
        #expect(p.headerItems(.zoom).map(\.title).contains("Fit"))
        #expect(p.headerItems(.options).contains { $0.title == "Safe Margins" })
    }

    @Test func contentPopupSitsRightBesideZoomNotAfterTheTabs() throws {
        let p = panel()
        p.model.hasSequence = true
        p.model.sequenceName = "Main"
        draw(p)
        let content = try #require(p.headerControls.first(where: { $0.0 == .content })?.1)
        let zoom = try #require(p.headerControls.first(where: { $0.0 == .zoom })?.1)
        #expect(content.maxX <= zoom.minX)
        #expect(zoom.minX - content.maxX < 8)
    }

    @Test func zoneControlShowsOnlyWhileAZoneIsOn() {
        let p = panel()
        p.model.setSafeZone(.off)
        draw(p)
        #expect(!p.headerControls.contains { $0.0 == .zone })
        p.model.setSafeZone(.tiktok)
        draw(p)
        #expect(p.headerControls.contains { $0.0 == .zone })
        p.model.setSafeZone(.off)
    }

    @Test func clickOnAPopupOpensItsRowsBelowIt() {
        let p = panel()
        draw(p)
        var opened: ([SQMenuItem], CGRect)?
        p.onMenu = { items, anchor, _ in opened = (items, anchor) }
        let zoom = p.headerControls.first { $0.0 == .zoom }!.1
        _ = p.handle(.mouseDown(x: Float(zoom.midX), y: Float(zoom.midY), modifiers: []))
        #expect(opened?.1 == zoom)
        #expect(opened?.0.first?.title == "Fit")
    }

    @Test func rightClickOnTheScrubStripOpensTheMarkMenu() {
        let p = panel()
        var titles: [String] = []
        p.onMenu = { items, _, _ in titles = items.map(\.title) }
        let s = p.footer.scrubRect
        _ = p.handle(.mouseDown(x: Float(s.midX), y: Float(s.midY), modifiers: .secondary))
        #expect(titles.contains("Remove In"))
        #expect(titles.contains("Go to Out"))
    }

    @Test func transportButtonRunsTheModelAction() {
        let p = panel()
        var got: [MonitorAction] = []
        p.model.onAction = { got.append($0) }
        let play = p.footer.buttons.first { $0.0 == .playPause }!.1
        _ = p.handle(.mouseDown(x: Float(play.midX), y: Float(play.midY), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(play.midX), y: Float(play.midY)))
        #expect(got == [.playPause])
    }

    @Test func rulerDragPullsOutAGuideAndDroppingItBackRemovesIt() {
        let p = panel()
        p.model.showsRulers = true
        let r = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(r.midX), y: Float(r.minY + 5), modifiers: []))
        _ = p.handle(.mouseDragged(x: Float(r.midX), y: Float(r.midY)))
        _ = p.handle(.mouseUp(x: Float(r.midX), y: Float(r.midY)))
        #expect(p.model.guides.horizontal.count == 1)
        let y = r.minY + CGFloat(p.model.guides.horizontal[0]) * r.height
        _ = p.handle(.mouseDown(x: Float(r.midX), y: Float(y), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(r.midX), y: Float(r.minY + 1)))
        #expect(p.model.guides.isEmpty)
        p.model.showsRulers = false
    }

    @Test func dashedEdgeAndBandDrawWithoutEvenOddFill() {
        var c = Canvas(width: 100, height: 100, atlas: nil, scale: 1)
        let before = c.list.quads.count
        MonitorPanel.fillBand(&c, outer: CGRect(x: 0, y: 0, width: 100, height: 100),
                              inner: CGRect(x: 10, y: 10, width: 80, height: 80), .white)
        #expect(c.list.quads.count - before == 4)
    }

    /// Go to Timecode (the Mac `focusTimecodeField` + `commitTimecode`): typed keys go to the field, Return seeks, a
    /// rejected text keeps the time and gives the hint.
    @Test func goToTimecodeOpensTheFooterFieldAndReturnSeeks() {
        let p = panel()
        var seeks: [Time] = [], hints: [String] = []
        p.model.onSeek = { seeks.append($0) }
        p.onHint = { hints.append($0) }
        p.focusTimecodeField()
        #expect(p.isEditingTimecode)
        draw(p)
        for ch in "+10" { #expect(p.handle(.keyDown(.character(ch), modifiers: []))) }
        #expect(p.handle(.keyDown(.enter, modifiers: [])))
        #expect(seeks == [Time(10, 25)])
        #expect(!p.isEditingTimecode)
        p.focusTimecodeField()
        for ch in "soon" { _ = p.handle(.keyDown(.character(ch), modifiers: [])) }
        _ = p.handle(.keyDown(.enter, modifiers: []))
        #expect(seeks.count == 1)
        #expect(hints == [MonitorPanelModel.timecodeHint(for: "soon")])
        p.focusTimecodeField()
        p.endTimecodeEdit()
        #expect(!p.isEditingTimecode)
    }
}

@MainActor
@Suite struct MeterPanelTests {
    func panel() -> MeterPanel {
        let p = MeterPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 120, h: 300), scale: 1)
        return p
    }

    @Test func meterAndLoudnessColumnsSitCenteredWhenTheyFit() {
        let p = panel()
        #expect(p.meterRect.width == AudioMeter.width)
        #expect(p.loudnessRect.width == LoudnessMeter.columnsWidth)
        #expect(abs((p.meterRect.minX - 0) - (120 - p.loudnessRect.maxX)) <= 1)
        p.layout(DrawRect(x: 0, y: 0, w: 60, h: 300), scale: 1)
        #expect(p.loudnessRect == .zero)
    }

    @Test func newBuffersMoveTheBarsAndStaleFeedSilencesThem() {
        let p = panel()
        var seq = 0
        p.reading = { (ObjectIdentifier(MeterPanel.self), seq, [0.5, 0.5]) }
        p.loudnessReading = { LoudnessReading(momentaryLUFS: -20, shortTermLUFS: -21, integratedLUFS: -22, truePeakDB: -3) }
        seq = 1; p.poll(now: 10)
        #expect(!p.meter.isSettled)
        #expect(p.loudness.reading.momentaryLUFS == -20)
        p.poll(now: 10.5)                                 // same buffer number: playback stopped
        #expect(p.loudness.reading.momentaryLUFS == nil)
        #expect(p.loudness.reading.integratedLUFS == -22)
    }

    @Test func meterFollowsTheBallisticsSettingAtEachBuffer() {
        let d = UserDefaults(suiteName: "sq.test.meterstyle.\(UUID().uuidString)")!
        d.set(MeterStyle.fast.rawValue, forKey: MeterStyle.defaultsKey)
        let p = MeterPanel(monitorDefaults: d)
        p.layout(DrawRect(x: 0, y: 0, w: 120, h: 300), scale: 1)
        p.reading = { (ObjectIdentifier(MeterPanel.self), 1, [0.5, 0.5]) }
        p.poll(now: 10)
        #expect(p.meter.style == .fast)
    }

    @Test func clickOnLoudnessResetsAndRightClickOpensTheMenu() {
        let p = panel()
        var reset = 0, titles: [String] = []
        p.onResetLoudness = { reset += 1 }
        p.onMenu = { items, _ in titles = items.map(\.title) }
        let l = p.loudnessRect
        _ = p.handle(.mouseDown(x: Float(l.midX), y: Float(l.midY), modifiers: []))
        #expect(reset == 1)
        _ = p.handle(.mouseDown(x: Float(l.midX), y: Float(l.midY), modifiers: .secondary))
        #expect(titles.last == "Reset Peak and Loudness" && titles.contains("Dim Monitor"))
    }
}

@MainActor
@Suite struct ScopesPanelTests {
    @Test func tallCardStacksWaveformOverVectorscope() {
        let p = ScopesPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        #expect(p.slots.count == 2)
        #expect(p.slots[0].box.height == ScopeBoxLayout.firstBox)
        #expect(p.kinds == [.waveform, .vectorscope])
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 260), scale: 1)
        #expect(p.slots.count == 1)
    }

    @Test func aFrameBinsIntoScopePicturesAtThePlotSize() async throws {
        let p = ScopesPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        let w = 64, h = 36
        let bytes = [UInt8](repeating: 126, count: w * h) + [UInt8](repeating: 128, count: w * h / 2)
        p.update(nv12: bytes, width: w, height: h, fullRange: false, generation: 1)
        for _ in 0..<200 where p.images[0] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        await p.settle()
        let plot = ScopeBoxLayout.plot(.waveform, in: p.slots[0].box.size)
        #expect(p.images[0]?.width == Int(plot.width))
        let v = try #require(p.images[1])
        #expect(v.pixels[3] == 0)                       // corner outside the vectorscope ring is transparent
    }

    @Test func gpuCountsSkipTheCPUBinningOncePerGeneration() async throws {
        @MainActor final class Source: ScopeCountsSource {
            var reads = 0, strides: [Int] = []
            var counts: ScopeCounts?
            func scopeCounts(pixelStride: Int) -> ScopeCounts? { reads += 1; strides.append(pixelStride); return counts }
        }
        let p = ScopesPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        let src = Source()
        #expect(!p.measure(from: src, generation: 1))      // nothing on the GPU: the host falls back to the readback
        let w = 64, h = 36
        let nv12 = [UInt8](repeating: 126, count: w * h) + [UInt8](repeating: 128, count: w * h / 2)
        src.counts = ScopeBinning.compute(nv12: nv12, width: w, height: h, fullRange: false, layout: ScopeLayout(), pixelStride: 1)
        #expect(p.measure(from: src, generation: 2))
        await p.settle()
        #expect(p.images[0] != nil && p.images[1] != nil)  // no detached binning of the frame
        let shown = p.imageGeneration
        #expect(p.measure(from: src, generation: 2))
        #expect(src.reads == 2 && p.imageGeneration == shown)
        #expect(src.strides == [p.pixelStride, p.pixelStride])
    }

    @Test func popupOffersEveryScopeAndSwitches() {
        let p = ScopesPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        var items: [SQMenuItem] = []
        p.onMenu = { i, _ in items = i }
        let r = p.slots[0].popup
        _ = p.handle(.mouseDown(x: Float(r.minX + 4), y: Float(r.midY), modifiers: []))
        #expect(items.map(\.title) == ScopeKind.allCases.map(ScopeBoxLayout.title))
        items[1].action?()
        #expect(p.kinds[0] == .parade)
    }
}
