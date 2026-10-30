import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI
@testable import SQUIKit

private let fd = Time(1, 24)

/// WP-E (INTERACTION-AUDIT): menu order and keys, tooltips, undo names, empty state, zoom bar cursors.
@Suite struct TimelineInteractionAuditTests {
    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero)
    }
    private func timeline(_ clips: [Clip] = []) -> Timeline {
        Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: clips)])
    }

    @Test func clipMenuEndsWithTheDestructiveGroup() {
        let c = clip()
        let items = TimelineContextMenu.items(timeline: timeline([c]), selection: [c.id], clipboardHasClips: true)
        let actions = items.map(\.action)
        #expect(Array(actions.suffix(2)) == [.delete, .rippleDelete])
        #expect(actions.prefix(5) == [.cut, .copy, .paste, .pasteInsert, .pasteAttributes])
        // Clear starts the last group, nothing destructive sits in the middle.
        #expect(items[items.count - 2].separatorBefore)
        #expect(!actions.dropLast(2).contains(.delete) && !actions.dropLast(2).contains(.rippleDelete))
    }

    @Test func fastCutMenuListsOnlyTheDeleteThatHappens() {
        let c = clip()
        var t = timeline([c])
        t.editMode = .magnetic
        let items = TimelineContextMenu.items(timeline: t, selection: [c.id], clipboardHasClips: false)
        #expect(items.map(\.action).contains(.delete) && !items.map(\.action).contains(.rippleDelete))
    }

    @Test func gapMenuPutsRippleDeleteAfterPaste() {
        let items = TimelineContextMenu.gapItems(clipboardHasClips: true)
        #expect(items.map(\.action) == [.paste, .pasteInsert, .rippleDelete])
        #expect(items.last?.separatorBefore == true)
    }

    @Test func menuKeysComeFromTheKeyMap() {
        let map = CommandMap.premiereDefault
        let c = clip()
        let def = TimelineContextMenu.items(timeline: timeline([c]), selection: [c.id], clipboardHasClips: true, map: map)
        #expect(def.first { $0.action == .cut }?.key == "x")
        #expect(def.first { $0.action == .rippleDelete }?.modifiers == [.shift])
        // Rebinding Cut changes the shown key; an unbound command shows none.
        let rebound = CommandMap(entries: map.entries.filter { $0.command != .cut }
            + [.init(scope: .global, binding: KeyBinding(.char("q"), [.command, .option]), command: .cut)])
        let re = TimelineContextMenu.items(timeline: timeline([c]), selection: [c.id], clipboardHasClips: true, map: rebound)
        #expect(re.first { $0.action == .cut }?.key == "q")
        #expect(re.first { $0.action == .cut }?.modifiers == [.command, .option])
        #expect(def.first { $0.action == .nest }?.key == "")
    }

    @MainActor @Test func toolTipsCarryTheMappedKey() {
        let map = CommandMap.premiereDefault
        #expect(ToolStripView.toolTip(.selection, title: "Select", map: map) == "Select (V)")
        #expect(ToolStripView.toolTip(.razor, title: "Blade", map: map) == "Blade (C)")
        #expect(Tooltip.text("Snap", command: .toggleSnapping, map: map) == "Snap (S)")
    }

    @Test func trackToggleNamesAreStateSpecific() {
        let all: [TrackToggle] = [.target, .visible, .mute, .solo, .lock, .syncLock]
        for t in all {
            let on = TrackToggleNames.name(t, turningOn: true), off = TrackToggleNames.name(t, turningOn: false)
            #expect(on != off)
            #expect(!on.hasPrefix("Toggle") && !off.hasPrefix("Toggle"))
        }
        #expect(TrackToggleNames.name(.mute, turningOn: true) == "Mute Track")
        #expect(TrackToggleNames.name(.mute, turningOn: false) == "Unmute Track")
    }

    @Test func emptyStateShowsOnlyForAnEmptyTimelineWithoutADrop() {
        #expect(TimelineEmptyState.isVisible(timeline: timeline(), dropActive: false))
        #expect(!TimelineEmptyState.isVisible(timeline: timeline(), dropActive: true))
        #expect(!TimelineEmptyState.isVisible(timeline: timeline([clip()]), dropActive: false))
        #expect(TimelineEmptyState.hint(map: .premiereDefault).contains(","))
    }

    @MainActor @Test func zoomBarCursorsFollowThePart() {
        #expect(ZoomScrollBar.cursor(for: .lower, dragging: false) == .resizeLeftRight)
        #expect(ZoomScrollBar.cursor(for: .upper, dragging: true) == .resizeLeftRight)
        #expect(ZoomScrollBar.cursor(for: .body, dragging: false) == .openHand)
        #expect(ZoomScrollBar.cursor(for: .body, dragging: true) == .closedHand)
    }
}
