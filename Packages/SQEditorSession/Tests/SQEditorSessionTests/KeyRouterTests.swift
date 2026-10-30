import Foundation
import Testing
import SQCore
@testable import SQEditorSession
@testable import SQUIKit

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    var time: Double { lock.withLock { t } }
    func advance(_ d: Double) { lock.withLock { t += d } }
}

private func down(_ k: Character, _ m: KeyModifiers = []) -> KeyEvent { KeyEvent(.char(k), m) }
private func up(_ k: Character) -> KeyEvent { KeyEvent(.char(k), [], phase: .up) }

private func rates(_ a: [RouterAction]) -> [ShuttleAction] {
    a.compactMap { if case .shuttle(let s) = $0 { s } else { nil } }
}

@Suite struct CommandMapTests {
    let map = CommandMap.premiereDefault

    @Test func noDuplicateBindingsWithinScope() {
        #expect(map.duplicates.isEmpty)
    }

    @Test func uxSection3Present() {
        func g(_ k: Key, _ m: KeyModifiers = [], focus: PanelID? = .timeline) -> EditorCommand? {
            map.command(for: KeyBinding(k, m), focus: focus)
        }
        let c: (Character) -> Key = { .char($0) }
        #expect(g(c("v")) == .tool(.selection)); #expect(g(c("a")) == .tool(.trackForward))
        #expect(g(c("a"), .shift) == .tool(.trackBackward))
        #expect(g(c("b")) == .tool(.ripple)); #expect(g(c("n")) == .tool(.rolling))
        #expect(g(c("y")) == .tool(.slip)); #expect(g(c("u")) == .tool(.slide))
        #expect(g(c("c")) == .tool(.razor)); #expect(g(c("h")) == .tool(.hand))
        #expect(g(c("z")) == .tool(.zoom)); #expect(g(c("t")) == .tool(.type))
        #expect(g(.space) == .playPause)
        #expect(g(c("j")) == .shuttleReverse); #expect(g(c("k")) == .shuttleStop); #expect(g(c("l")) == .shuttleForward)
        #expect(g(.left) == .stepBackward); #expect(g(.right) == .stepForward)
        #expect(g(.left, .shift) == .stepBackward5); #expect(g(.right, .shift) == .stepForward5)
        #expect(g(.up) == .previousEditPoint); #expect(g(.down) == .nextEditPoint)
        #expect(g(.home) == .goToStart); #expect(g(.end) == .goToEnd)
        #expect(g(c("i")) == .markIn); #expect(g(c("o")) == .markOut)
        #expect(g(c("i"), .shift) == .goToIn); #expect(g(c("o"), .shift) == .goToOut)
        #expect(g(c("x"), .option) == .clearInOut); #expect(g(c("x")) == .markClip)
        #expect(g(c(";")) == .lift); #expect(g(c("'")) == .extract)
        #expect(g(c(",")) == .insert); #expect(g(c(".")) == .overwrite)
        #expect(g(c("f")) == .matchFrame); #expect(g(c("r"), .shift) == .reverseMatchFrame)
        #expect(g(c("k"), .command) == .addEdit); #expect(g(c("k"), [.command, .shift]) == .addEditAllTracks)
        #expect(g(c("q")) == .rippleTrimPrevious); #expect(g(c("w")) == .rippleTrimNext)
        #expect(g(c("e")) == .extendEdit)
        #expect(g(.delete) == .delete); #expect(g(.delete, .shift) == .rippleDelete)
        #expect(g(c("s")) == .toggleSnapping)
        #expect(g(c("l"), .command) == .link)
        #expect(g(c("m")) == .addMarker)
        #expect(g(c("c"), .command) == .copy); #expect(g(c("x"), .command) == .cut); #expect(g(c("v"), .command) == .paste)
        #expect(g(c("v"), [.command, .option]) == .pasteAttributes)
        #expect(g(c("z"), .command) == .undo); #expect(g(c("z"), [.command, .shift]) == .redo)
        #expect(g(c("\\")) == .zoomFit); #expect(g(c("=")) == .zoomIn); #expect(g(c("-")) == .zoomOut)
        #expect(g(c("i"), .command) == .importMedia); #expect(g(c("n"), .command) == .newSequence)
        #expect(g(c("s"), .command) == .save); #expect(g(c("m"), .command) == .export)
        #expect(g(c("`")) == .maximizePanel)
        let panels: [PanelID] = [.project, .sourceMonitor, .timeline, .programMonitor, .effectControls, .audioMeter, .effects]
        for (i, p) in panels.enumerated() {
            #expect(g(c(Character(String(i + 1))), .shift) == .focusPanel(p))
        }
        // keyframe proposal
        #expect(g(.function(9)) == .easyEase); #expect(g(.function(9), .shift) == .easeIn)
        #expect(g(.function(9), [.command, .shift]) == .easeOut)
        // Opt+Left/Right trim by one frame (Premiere); Cmd+Opt+H stays free for Hide Others.
        #expect(g(.left, .option) == .trimBackward); #expect(g(.right, .option) == .trimForward)
        #expect(g(c("h"), [.command, .option]) == nil)
    }

    @Test func focusPrecedence() {
        // Delete: timeline -> delete, project -> project items, program/none -> unbound.
        let del = KeyBinding(.delete)
        #expect(map.command(for: del, focus: .timeline) == .delete)
        #expect(map.command(for: del, focus: .project) == .deleteProjectItems)
        #expect(map.command(for: del, focus: .programMonitor) == nil)
        #expect(map.command(for: del, focus: nil) == nil)
        // Global commands work from every focus; timeline-only ones do not leak.
        #expect(map.command(for: KeyBinding(.space), focus: .project) == .playPause)
        #expect(map.command(for: KeyBinding(.up), focus: .sourceMonitor) == nil)
        #expect(map.command(for: KeyBinding(.up), focus: .programMonitor) == .previousEditPoint)
        // A specific scope overrides global.
        let m = CommandMap(entries: [
            .init(scope: .global, binding: KeyBinding(.space), command: .playPause),
            .init(scope: .source, binding: KeyBinding(.space), command: .markClip),
        ])
        #expect(m.command(for: KeyBinding(.space), focus: .sourceMonitor) == .markClip)
        #expect(m.command(for: KeyBinding(.space), focus: .timeline) == .playPause)
    }

    @Test func menusResolve() {
        for menu in EditorMenus.all {
            let cmds = menu.commands
            #expect(!cmds.isEmpty)
            #expect(Set(cmds).count == cmds.count, "duplicate in \(menu.title)")
            for c in cmds {
                #expect(!c.title.isEmpty)
                #expect(map.binding(for: c) != nil || EditorMenus.menuOnly.contains(c), "no key for \(c)")
            }
        }
        #expect(EditorMenus.all.map(\.title) == ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window"])
    }
}

@Suite struct KeyRouterTests {
    let clock = TestClock()
    func router(_ focus: PanelID? = .timeline) -> KeyRouter {
        let c = clock
        return KeyRouter(focus: focus, clock: { c.time })
    }

    @Test func llLShuttle() {
        var r = router()
        var last: PlaybackRate = .zero
        var seen: [PlaybackRate] = []
        for _ in 0..<3 {
            for a in rates(r.handle(down("l"))) { if case .setRate(let x) = a { last = x; seen.append(x) } }
            _ = r.handle(up("l"))
        }
        #expect(seen == [PlaybackRate(1), PlaybackRate(2), PlaybackRate(4)])
        #expect(last == PlaybackRate(4))
    }

    @Test func jAfterLSlowsDownOneStepThenReverses() {
        var r = router()
        _ = r.handle(down("l")); _ = r.handle(up("l"))
        _ = r.handle(down("l")); _ = r.handle(up("l"))
        #expect(rates(r.handle(down("j"))) == [.setRate(PlaybackRate(1))])      // 2x -> 1x
        _ = r.handle(up("j"))
        #expect(rates(r.handle(down("j"))) == [.setRate(PlaybackRate(-1))])     // at 1x the opposite key reverses
    }

    /// The shared shell resolves the command itself (Ctrl/Alt mapping) and still gets the Mac repeat filter and J/K/L rules.
    @Test func resolvedCommandKeepsRepeatFilterAndShuttleHold() {
        var r = router()
        #expect(rates(r.handle(command: .shuttleForward, key: .char("l"), isRepeat: false)) == [.setRate(PlaybackRate(1))])
        #expect(r.handle(command: .shuttleForward, key: .char("l"), isRepeat: true).isEmpty)       // held L is one press
        #expect(r.handle(command: .playPause, key: .space, isRepeat: true).isEmpty)                // not repeatable
        #expect(r.handle(command: .stepForward, key: .right, isRepeat: true) == [.command(.stepForward, focus: .timeline)])
        _ = r.handle(up("l"))
        _ = r.handle(command: .shuttleStop, key: .char("k"), isRepeat: false)
        #expect(rates(r.handle(command: .shuttleForward, key: .char("l"), isRepeat: false)) == [.step(1)])   // K held: L steps a frame
    }

    /// L held when the window lost focus: its key up never arrives. The next L press after `releaseAllKeys` must play.
    @Test func releaseAllKeysForgetsLostKeyUps() {
        var r = router()
        _ = r.handle(down("l"))
        _ = r.handle(down("k"))
        #expect(rates(r.releaseAllKeys()) == [])
        #expect(!r.consumes(up("l")))                                         // nothing is held any more
        #expect(rates(r.handle(down("l"))) == [.setRate(PlaybackRate(1))])     // plays, not a K+L frame step
    }

    @Test func releaseAllKeysEndsSlowModeAndPendingHold() {
        var r = router()
        _ = r.handle(down("k"))
        _ = r.handle(down("l"))
        clock.advance(0.3)
        #expect(rates(r.tick()) == [.setRate(PlaybackRate(1, 4))])
        #expect(rates(r.releaseAllKeys()) == [.setRate(.zero)])
        #expect(r.nextDeadline == nil)
    }

    @Test func kStops() {
        var r = router()
        _ = r.handle(down("l"))
        #expect(rates(r.handle(down("k"))) == [.setRate(.zero)])
    }

    @Test func kPlusLTapIsOneFrame() {
        var r = router()
        _ = r.handle(down("k"))
        #expect(rates(r.handle(down("l"))) == [.step(1)])
        clock.advance(0.1)
        #expect(r.tick().isEmpty)
        #expect(r.handle(up("l")).isEmpty)
        clock.advance(1)
        #expect(r.tick().isEmpty)
        #expect(rates(r.handle(down("j"))) == [.step(-1)])
    }

    @Test func kPlusLHoldIsQuarterSpeed() {
        var r = router()
        _ = r.handle(down("k"))
        _ = r.handle(down("l"))
        #expect(r.nextDeadline == 0.25)
        clock.advance(0.25)
        #expect(rates(r.tick()) == [.setRate(PlaybackRate(1, 4))])
        #expect(r.nextDeadline == nil)
        #expect(rates(r.handle(up("l"))) == [.setRate(.zero)])
    }

    @Test func holdJIsMinusQuarter() {
        var r = router()
        _ = r.handle(down("k")); _ = r.handle(down("j"))
        clock.advance(0.3)
        #expect(rates(r.handle(up("j"))) == [.setRate(PlaybackRate(-1, 4)), .setRate(.zero)])
    }

    @Test func autoRepeatIgnoredForShuttleAndNonRepeatable() {
        var r = router()
        _ = r.handle(down("l"))
        #expect(r.handle(KeyEvent(.char("l"), [], isRepeat: true)).isEmpty)
        #expect(r.handle(KeyEvent(.char("i"), [], isRepeat: true)).isEmpty)
        #expect(r.handle(KeyEvent(.right, [], isRepeat: true)) == [.command(.stepForward, focus: .timeline)])
    }

    @Test func commandsCarryFocus() {
        var r = router(.sourceMonitor)
        #expect(r.handle(down("i")) == [.command(.markIn, focus: .sourceMonitor)])
        #expect(r.handle(KeyEvent(.up)).isEmpty)
        r.focus = .timeline
        #expect(r.handle(KeyEvent(.up)) == [.command(.previousEditPoint, focus: .timeline)])
        #expect(r.handle(down("k", .command)) == [.command(.addEdit, focus: .timeline)])
        #expect(r.shuttle.rate == .zero)
    }

    @Test func keyUpIgnoresModifierChange() {
        var r = router()
        _ = r.handle(down("l"))
        // Key-up arrives with Shift already pressed: still releases the held role without stray output.
        #expect(r.handle(KeyEvent(.char("l"), .shift, phase: .up)).isEmpty)
        #expect(rates(r.handle(down("l"))) == [.setRate(PlaybackRate(2))])
    }
}
