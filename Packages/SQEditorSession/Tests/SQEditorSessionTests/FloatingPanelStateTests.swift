import Foundation
import Testing
import SQUIKit
@testable import SQEditorSession

@Suite struct FloatingPanelStateTests {
    let edit = FloatingPanelState.key(page: .edit, editName: "Editing – PC")
    let color = FloatingPanelState.key(page: .color, editName: "Editing – PC")
    let frame = FloatingPanelFrame(x: 100, y: 200, width: 500, height: 300)

    @Test func keysSeparateWorkspacesAndPages() {
        #expect(edit != color)
        #expect(edit != FloatingPanelState.key(page: .edit, editName: "Editing – MacBook"))
    }

    @Test func floatAndDockPerWorkspace() {
        var s = FloatingPanelState()
        s.float(.scopes, key: edit, frame: frame)
        #expect(s.panels(for: edit) == [.scopes])
        #expect(s.panels(for: color).isEmpty)
        #expect(s.frame(of: .scopes, key: edit) == frame)
        s.dock(.scopes, key: edit)
        #expect(s.panels(for: edit).isEmpty)
        #expect(s.frame(of: .scopes, key: edit) == nil)
    }

    @Test func setFrameOnlyForFloatingPanels() {
        var s = FloatingPanelState()
        s.setFrame(frame, of: .library, key: edit)
        #expect(s.panels(for: edit).isEmpty)
        s.float(.library, key: edit, frame: frame)
        let moved = FloatingPanelFrame(x: 1, y: 2, width: 300, height: 200)
        s.setFrame(moved, of: .library, key: edit)
        #expect(s.frame(of: .library, key: edit) == moved)
    }

    @Test func nonDockablePanelsDoNotFloat() {
        var s = FloatingPanelState()
        s.float(.steps, key: edit, frame: frame)
        #expect(s.panels(for: edit).isEmpty)
    }

    @Test func roundTripAndUnknownPanelsDropped() throws {
        var s = FloatingPanelState()
        s.float(.graphics, key: edit, frame: frame)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(FloatingPanelState.self, from: data) == s)
        let raw = #"{"layouts":{"k":{"graphics":{"x":1,"y":2,"width":3,"height":4},"gone":{"x":1,"y":2,"width":3,"height":4},"colorClips":{"x":1,"y":2,"width":3,"height":4}}}}"#
        let d = try JSONDecoder().decode(FloatingPanelState.self, from: Data(raw.utf8))
        #expect(d.panels(for: "k") == [.graphics])      // unknown ids and non-dockable panels are dropped
    }

    @Test func saveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-floating-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = FloatingPanelState()
        s.float(.scopes, key: edit, frame: frame)
        try s.save(to: url)
        #expect(FloatingPanelState.load(from: url) == s)
        #expect(FloatingPanelState.load(from: url.appendingPathExtension("missing")) == FloatingPanelState())
    }

    @Test func clampKeepsTitleBarReachable() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let inside = CGRect(x: 100, y: 100, width: 500, height: 300)
        #expect(FloatingPanelState.clamp(inside, screens: screens) == inside)
        // Saved on a second display that is gone: moved onto the first one, size kept.
        let gone = CGRect(x: 3000, y: 100, width: 500, height: 300)
        let c = FloatingPanelState.clamp(gone, screens: screens)
        #expect(c.size == gone.size)
        #expect(screens[0].contains(c))
        // Present second display keeps the frame.
        let two = screens + [CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let onSecond = CGRect(x: 2000, y: 100, width: 500, height: 300)
        #expect(FloatingPanelState.clamp(onSecond, screens: two) == onSecond)
        // Larger than the display: shrunk to fit.
        let big = FloatingPanelState.clamp(CGRect(x: 0, y: 0, width: 5000, height: 4000), screens: screens)
        #expect(screens[0].contains(big))
    }

    @Test func defaultFrameFitsPanelMinimum() {
        let f = FloatingPanelState.defaultFrame(for: .timeline, current: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(f.width >= PanelID.timeline.minSize.width)
        #expect(f.height >= PanelID.timeline.minSize.height)
    }

    @Test func tabReleasedOutsideWindowTearsOff() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(!FloatingPanelState.isTornOff(CGPoint(x: 500, y: 300), window: win))
        #expect(!FloatingPanelState.isTornOff(CGPoint(x: 1005, y: 300), window: win))   // inside the margin: still a dock drop
        #expect(FloatingPanelState.isTornOff(CGPoint(x: 1100, y: 300), window: win))
        #expect(FloatingPanelState.isTornOff(CGPoint(x: -200, y: -50), window: win))
    }

    @Test func tearOffFrameHangsUnderPointerAndFitsMinimum() {
        let f = FloatingPanelState.tearOffFrame(for: .timeline, at: CGPoint(x: 2000, y: 500), titleBar: 28)
        #expect(f.width >= PanelID.timeline.minSize.width)
        #expect(f.height >= PanelID.timeline.minSize.height + 28)
        // The title bar (top edge) sits under the pointer, horizontally centered.
        #expect(abs(f.rect.midX - 2000) < 0.5)
        #expect(f.rect.maxY - 14 == 500)
    }
}
