import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The parts of the Mac key route (`AppController.handle(_ event:)`) that are about key state, not about one command:
/// auto-repeat, J/K/L down and up, Esc. The shared shell and the Windows app run the same code.
extension ShellHost {
    /// A mapped key press: repeats of commands that are not `isRepeatable` are swallowed (a held Space or Delete runs once),
    /// shuttle keys go through the down/up state machine, everything else is `execute`.
    func keyCommand(_ c: EditorCommand, key k: InputKey) -> Bool {
        let repeating = HostKeyRepeat.shared.isRepeat
        if repeating, !c.isRepeatable, !Self.shuttleCommands.contains(c) { return true }
        guard Self.shuttleCommands.contains(c), enabled(c), let key = ShellKeys.key(k) else { return execute(c) }
        // The host's panels first (the Source monitor shuttles itself when it has the focus).
        if !repeating, onCommand?(c) == true { return true }
        if repeating, focus == .sourceMonitor { return true }
        if !session.isPlaying { shuttleRouter.transportStopped() }
        runShuttle(shuttleRouter.handle(command: c, key: key, isRepeat: repeating))
        return true
    }

    static let shuttleCommands: Set<EditorCommand> = [.shuttleReverse, .shuttleStop, .shuttleForward]

    /// The key came up (the host calls this from its key-up message): ends a J/K/L hold.
    public func keyUp(_ k: InputKey) {
        guard let key = ShellKeys.key(k) else { return }
        let up = KeyEvent(key, [], phase: .up)
        guard shuttleRouter.consumes(up) else { return }
        runShuttle(shuttleRouter.handle(up))
    }

    /// The window lost the keyboard: held J/K/L key-ups go elsewhere (the Mac `releaseHeldKeys`).
    public func releaseHeldKeys() { runShuttle(shuttleRouter.releaseAllKeys()) }

    func runShuttle(_ actions: [RouterAction]) {
        for a in actions { if case .shuttle(let s) = a { session.apply(shuttle: s) } }
        if !session.isPlaying { shuttleRouter.transportStopped() }
        shuttleDeadline?.cancel()
        shuttleDeadline = nil
        guard let due = shuttleRouter.nextDeadline else { return }
        let delay = max(due - ProcessInfo.processInfo.systemUptime, 0) + 0.01
        shuttleDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.shuttleDeadline = nil
            self.runShuttle(self.shuttleRouter.tick())
        }
    }

    /// Shuttle rows run from a menu or Quick Apply (no key to hold): a press and release at once. Shift+J / Shift+L nudge
    /// the playing speed one step and the next J / L continues from it.
    func runShuttleCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .shuttleReverse, .shuttleStop, .shuttleForward:
            let key: Key = c == .shuttleReverse ? .char("j") : c == .shuttleStop ? .char("k") : .char("l")
            if !session.isPlaying { shuttleRouter.transportStopped() }
            runShuttle(shuttleRouter.handle(command: c, key: key, isRepeat: false))
            runShuttle(shuttleRouter.handle(KeyEvent(key, [], phase: .up)))
        case .shuttleSlowReverse, .shuttleSlowForward:
            let rate = session.engine.rate.nudged(forward: c == .shuttleSlowForward)
            session.apply(shuttle: .setRate(rate))
            shuttleRouter.rateChanged(to: rate)
        default: return false
        }
        return true
    }

    /// Esc after the panels passed on it (a dialog, menu, text field, drag or the timeline's gap selection took theirs): the
    /// selection is cleared, clips and captions, as the Mac key monitor does. The tool reset is the timeline panel's.
    func escapeKey() -> Bool {
        // Esc closes Trim mode first (TL-08), before the tool and the selection.
        if trim.isActive { trim.exit(); return true }
        // A floating panel with the focus docks (the Mac `FloatingPanelWindow.cancelOperation`: Esc nothing else took).
        if let p = dock.focused, dock.floating.isFloating(p) { dock.floating.dockBack(p); return true }
        guard !session.selection.isEmpty || !session.captionSelection.isEmpty else { return false }
        return execute(.deselectAll)
    }
}
