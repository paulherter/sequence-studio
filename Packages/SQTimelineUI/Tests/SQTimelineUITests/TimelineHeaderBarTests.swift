import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)

@MainActor
struct TimelineHeaderBarTests {
    private func makeView(height: CGFloat = 300) -> TimelineView {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        return TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: height))
    }

    private func makeBar(_ v: TimelineView) -> TimelineHeaderBar {
        let bar = TimelineHeaderBar(frame: NSRect(x: 0, y: 0, width: 900, height: TimelineHeaderBar.height))
        bar.bind(to: v)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    @Test func noToolColumnLeft() {
        #expect(TimelineGeometry.toolColumnWidth == 0)
        #expect(TimelineGeometry.contentOriginX == TimelineGeometry.headerWidth)
        let v = makeView()
        #expect(v.subviews.compactMap { $0 as? NSButton }.isEmpty)
    }

    private func makeStrip(_ v: TimelineView) -> ToolStripView {
        let strip = ToolStripView(frame: NSRect(x: 0, y: 0, width: 30, height: 200))
        strip.bind(to: v)
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    @Test func stripHasTheSixDesignToolsWithSelectionActive() {
        let strip = makeStrip(makeView())
        #expect(strip.toolButtons.map(\.tool) == [.selection, .razor, .slip, .hand, .type, .mask])
        #expect(strip.toolButtons.filter { $0.button.state == .on }.map(\.tool) == [.selection])
        #expect(strip.toolButtons.allSatisfy { $0.button.style == .tool })
    }

    /// Every tool the app has is reachable from the bar: six buttons, the rest in its right-click menu.
    @Test func barMenuListsEveryToolAndTheDockPlaces() {
        let strip = makeStrip(makeView())
        let titles = strip.allToolItems().map(\.title)
        for t in ["Select", "Blade", "Slip", "Hand", "Create", "Mask", "Select Forward", "Ripple", "Roll", "Slide", "Rate Stretch", "Zoom",
                  "Dock Left", "Dock Right", "Dock Above the Timeline", "Float", "Hide Tool Bar"] {
            #expect(titles.contains(t), "missing \(t)")
        }
        #expect(ToolStripView.describedTip("Blade (C)", tool: .razor) == "Blade (C) · Cuts a clip where you click.")
    }

    @Test func clickingRazorButtonSwitchesToolAndHighlight() throws {
        let v = makeView()
        let strip = makeStrip(v)
        var reported: TimelineTool?
        v.onToolChange = { reported = $0 }
        let i = try #require(strip.toolButtons.firstIndex { $0.tool == .razor })
        strip.toolButtons[i].button.performClick(nil)
        #expect(v.toolState.tool == .razor && reported == .razor)
        #expect(strip.toolButtons.filter { $0.button.state == .on }.map(\.tool) == [.razor])
    }

    @Test func keyboardToolChangeMovesTheHighlight() {
        let v = makeView()
        let strip = makeStrip(v)
        v.toolState.tool = .razor                           // what the C key does
        #expect(strip.toolButtons.filter { $0.button.state == .on }.map(\.tool) == [.razor])
    }

    @Test func headerBarShowsTheDesignControls() {
        let bar = makeBar(makeView())
        bar.frame = CGRect(x: 0, y: 0, width: 900, height: TimelineHeaderBar.height)
        bar.layoutSubtreeIfNeeded()
        let shown = bar.subviews.filter { !$0.isHidden }
        #expect(shown.compactMap { $0 as? NSTextField }.count == 1)                    // the playhead timecode
        #expect(shown.compactMap { $0 as? TimelineToolSlotButton }.count == 4)         // snap, link, marker, Fit
        #expect(!bar.modeControl.isHidden)                                             // Normal | Fast Cut: always there
        bar.editMode = .magnetic
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.modeControl.isHidden && bar.modeControl.mode == .magnetic)
    }

    @Test func fitPopupCarriesZoomAndTrackHeight() {
        let bar = makeBar(makeView())
        let titles = bar.fitItems().map(\.title)
        for t in ["Fit Sequence", "Zoom In", "Zoom Out", "Taller Tracks", "Shorter Tracks", "Fit All Tracks to Height", "Place Sequences as Clips"] {
            #expect(titles.contains(t), "missing \(t)")
        }
    }

    @Test func markerButtonReports() {
        let bar = makeBar(makeView())
        var n = 0
        bar.onAddMarker = { n += 1 }
        bar.markerButton.performClick(nil)
        #expect(n == 1)
    }

    @Test func snapAndLinkToggleShowOnOffState() {
        let v = makeView()
        let bar = makeBar(v)
        var reported: (Bool, Bool)?
        v.onToggleChange = { reported = ($0, $1) }
        #expect(bar.snapButton.state == .on && bar.linkButton.state == .on)
        bar.snapButton.performClick(nil)
        #expect(!v.toolState.snapping && v.toolState.linkedSelection)
        #expect(bar.snapButton.state == .off && bar.linkButton.state == .on)
        #expect(reported?.0 == false && reported?.1 == true)
        bar.linkButton.performClick(nil)
        #expect(!v.toolState.linkedSelection && bar.linkButton.state == .off)
        v.toolState.snapping = true                         // the S key
        #expect(bar.snapButton.state == .on)
    }

    @Test func layoutFitsAndKeepsTabsSpace() {
        for width in [900.0, 700.0, 600.0, 540.0] {
            let f = TimelineHeaderBar.frames(width: width)
            let all = [f.editMode, f.timecode, f.snap, f.link, f.marker, f.fit]
            #expect(all.allSatisfy { $0.minX >= f.tabs.maxX && $0.maxX <= width })
            let sorted = all.sorted { $0.minX < $1.minX }
            for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.maxX <= b.minX) }
            #expect(f.tabs.width > 100)
            #expect(all.allSatisfy { $0.height <= TimelineHeaderBar.height })
        }
        #expect(TimelineHeaderBar.frames(width: 100).tabs.width >= 0)       // never negative
    }

    @Test func designOrderAndSize() {
        let f = TimelineHeaderBar.frames(width: 1200)
        // tabs | Normal / Fast Cut | timecode | snap link marker | Fit
        #expect(f.editMode.maxX < f.timecode.minX && f.timecode.maxX + 8 == f.snap.minX)
        #expect(f.snap.maxX + 4 == f.link.minX && f.link.maxX + 4 == f.marker.minX && f.marker.maxX + 4 == f.fit.minX)
        #expect(f.fit.maxX == CGFloat(1196))
        #expect(f.separators.isEmpty && f.heightFit == .zero && f.zoomIn == .zero && f.zoomOut == .zero && f.placeClips == .zero)
        #expect(TimelineHeaderBar.height == 30)
        #expect(f.snap.width == 24 && f.snap.height == 24 && f.fit.height == 24)
    }

    @Test func buttonStylesFollowTheBoard() {
        let bar = makeBar(makeView())
        #expect(bar.snapButton.style == .toggle && bar.linkButton.style == .toggle)
        #expect(bar.snapButton.contentTintColor == Theme.Colors.accent)
        bar.snapButton.performClick(nil)
        #expect(bar.snapButton.contentTintColor == Theme.Colors.label2)
    }

    @Test func pointerDownIsReported() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        let v = makeView()
        window.contentView?.addSubview(v)
        var downs = 0
        v.onPointerDown = { downs += 1 }
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: v.convert(CGPoint(x: 400, y: 60), to: nil), modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        v.mouseDown(with: e)
        #expect(downs == 1)
    }

    @Test func tracksFillThePanel() {
        let v = makeView(height: 220)
        let rows = v.geometry.rows(for: v.timeline)
        #expect(abs(rows.last!.maxY - (220 - ZoomScrollBar.height)) < 0.5)     // the zoom bar is below the track area
    }
}

struct TrackHeaderSlotTests {
    @Test @MainActor func slotsFollowTheDesign() {
        let w = Theme.Metrics.trackHeader
        #expect(w == 156)
        let v = TrackHeaderView.slots(width: w, height: 40, kind: .video)
        #expect(v.eye == CGRect(x: w - 4 - 24, y: 8, width: 24, height: 24) && v.lock == CGRect(x: w - 4 - 52, y: 8, width: 24, height: 24))
        #expect(v.sync == .zero && v.nameRight == v.lock.minX - 4)
        let a = TrackHeaderView.slots(width: w, height: 32, kind: .audio)
        #expect(a.solo!.maxX == w - 4 && a.mute!.maxX + 4 == a.solo!.minX && a.lock == .zero && a.nameRight == a.mute!.minX - 4)
        // A locked audio track and a switched-off sync lock show their button left of M / S.
        let locked = TrackHeaderView.slots(width: w, height: 32, kind: .audio, showsSync: true, showsLock: true)
        #expect(locked.lock.maxX + 4 == locked.mute!.minX && locked.sync.maxX + 4 == locked.lock.minX)
        // Low rows keep their buttons, smaller.
        let low = TrackHeaderView.slots(width: w, height: 20, kind: .video)
        #expect(low.eye!.height == 16 && low.eye!.minY == 2)
    }

    @Test @MainActor func nameNeverRepeatsTheChip() {
        #expect(TrackHeaderView.displayName(name: "V6", label: "V6", kind: .video) == "Video 6")
        #expect(TrackHeaderView.displayName(name: "a2", label: "A2", kind: .audio) == "Audio 2")
        #expect(TrackHeaderView.displayName(name: "", label: "V1", kind: .video) == "Video 1")
        #expect(TrackHeaderView.displayName(name: "Voice", label: "A1", kind: .audio) == "Voice")
    }

    @Test @MainActor func menuCarriesEverySwitchOfTheHeader() {
        var got = [TrackToggle]()
        let items = TimelineSideMenus.trackHeader(track: Track(kind: .audio), addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {},
                                                  toggleDucking: {}, toggle: { got.append($0) })
        for t in ["Target Track", "Mute", "Solo", "Lock Track", "Sync Lock"] {
            let item = items.first { $0.title == t }
            #expect(item != nil, "missing \(t)")
            item?.action?()
        }
        #expect(got == [.target, .mute, .solo, .lock, .syncLock])
    }

    @Test @MainActor func hoverDoesNotMoveAnyButton() {
        let track = Track(kind: .audio)
        let h = TrackHeaderView(track: track, label: "A1")
        h.frame = CGRect(x: 0, y: 0, width: Theme.Metrics.trackHeader, height: 26)
        h.layoutSubtreeIfNeeded()
        let before = h.subviews.map(\.frame)
        h.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        h.layoutSubtreeIfNeeded()
        #expect(h.subviews.map(\.frame) == before)
    }

    /// At 24 pt rows (and the smallest ones) every shown button and the target chip lie inside the row, overlap nothing, and the
    /// name never reaches under a button. Clicks through the real frames reach the right toggle.
    @Test @MainActor func buttonsFitAndDoNotOverlapAtLowRows() {
        for kind in [TrackKind.audio, .video] {
            for height in [CGFloat(16), 20, 24, 26, 32] {
                var t = Track(kind: kind); t.syncLock = false; t.isLocked = true
                let h = TrackHeaderView(track: t, label: kind == .audio ? "A1" : "V1")
                h.frame = CGRect(x: 0, y: 0, width: Theme.Metrics.trackHeader, height: height)
                h.layoutSubtreeIfNeeded()
                let shown = h.subviews.filter { !$0.isHidden }.map(\.frame).sorted { $0.minX < $1.minX }
                for (i, f) in shown.enumerated() {
                    #expect(h.bounds.contains(f), "\(kind) \(height) button \(i) outside the row")
                    if i > 0 { #expect(f.minX >= shown[i - 1].maxX, "\(kind) \(height) overlap") }
                }
            }
        }
    }

    /// A switched-off sync lock on an unhovered audio row sits next to the lock, never beside an empty slot.
    @Test @MainActor func syncLockOffLeavesNoHoleInAudioRow() {
        var t = Track(kind: .audio); t.syncLock = false
        let h = TrackHeaderView(track: t, label: "A1")
        h.frame = CGRect(x: 0, y: 0, width: Theme.Metrics.trackHeader, height: 24)
        h.layoutSubtreeIfNeeded()
        let visible = h.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.frame.minX > 45 }.sorted { $0.frame.minX < $1.frame.minX }   // not the target chip
        #expect(visible.count == 4)
        for (a, b) in zip(visible, visible.dropFirst()) { #expect(b.frame.minX - a.frame.maxX == TrackHeaderView.buttonGap) }
    }

    /// Lock and Sync Lock are one click away on every row: hidden on a plain audio row, shown while the pointer is over it.
    @Test @MainActor func hoverRevealsLockAndSyncLockOnEveryRow() {
        for kind in [TrackKind.audio, .video] {
            let h = TrackHeaderView(track: Track(kind: kind), label: kind == .audio ? "A1" : "V1")
            h.frame = CGRect(x: 0, y: 0, width: Theme.Metrics.trackHeader, height: 32)
            var got = [TrackToggle]()
            h.onToggle = { _, t in got.append(t) }
            h.layoutSubtreeIfNeeded()
            func button(_ label: String) -> NSButton? {
                h.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasPrefix(label) == true }
            }
            let lock = button("Lock"), sync = button("Sync lock")
            #expect(lock != nil && sync != nil)
            #expect(lock?.isHidden == (kind == .audio) && sync?.isHidden == true)
            h.rowHovered = true
            h.layoutSubtreeIfNeeded()
            #expect(lock?.isHidden == false && sync?.isHidden == false)
            #expect(sync!.frame.maxX < lock!.frame.minX && lock!.frame.width == 24)
            lock?.performClick(nil); sync?.performClick(nil)
            #expect(got == [.lock, .syncLock])
            h.rowHovered = false
            #expect(lock?.isHidden == (kind == .audio) && sync?.isHidden == true)
        }
    }
}
