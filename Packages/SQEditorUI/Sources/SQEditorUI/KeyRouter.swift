import Foundation
import SQCore

public enum RouterAction: Sendable, Equatable {
    case command(EditorCommand, focus: PanelID?)
    case shuttle(ShuttleAction)
}

/// Pure key routing: key events + focused panel -> actions. No AppKit.
/// The UI must not call it while a text field is first responder.
/// It owns the J/K/L down/up state machine (SQCore `Shuttle`). The hold timing for "K held + L/J held > 0.25 s"
/// uses the injected clock: every event first runs `tick()`; the UI also calls `tick()` from a timer
/// scheduled at `nextDeadline` so slow mode starts without another key event.
public struct KeyRouter: Sendable {
    public static let holdThreshold: TimeInterval = 0.25

    public var map: CommandMap
    public var focus: PanelID?
    public private(set) var shuttle = Shuttle()

    private let now: @Sendable () -> TimeInterval
    private var shuttleDown: [Key: ShuttleKey] = [:]     // physical key -> role, so key-up ignores modifiers
    private var pendingHold: [ShuttleKey: TimeInterval] = [:]

    public init(map: CommandMap = .premiereDefault, focus: PanelID? = nil, clock: @escaping @Sendable () -> TimeInterval) {
        self.map = map; self.focus = focus; self.now = clock
    }

    /// Time at which `tick()` will have work to do, if any.
    public var nextDeadline: TimeInterval? { pendingHold.values.min().map { $0 + Self.holdThreshold } }

    public mutating func tick() -> [RouterAction] {
        let t = now()
        var out: [RouterAction] = []
        for (key, start) in pendingHold.sorted(by: { $0.value < $1.value }) where t - start >= Self.holdThreshold {
            pendingHold[key] = nil
            append(shuttle.holdElapsed(key), to: &out)
        }
        return out
    }

    /// True when the host must swallow this event (return nil from the key monitor) so it never reaches the responder
    /// chain, where an unhandled key down plays the error beep. Covers key downs with a binding even when `handle`
    /// yields no action (auto-repeat of a non-repeatable command), and the key ups of shuttle keys.
    public func consumes(_ event: KeyEvent) -> Bool {
        switch event.phase {
        case .down: return map.command(for: event.binding, focus: focus) != nil
        case .up: return shuttleDown[event.key] != nil
        }
    }

    /// Playback was stopped from outside the keyboard (a click, the transport button): the next L/J starts at 1x.
    public mutating func transportStopped() { shuttle.stopped() }

    /// The playing speed was changed by something other than J/K/L (Shift+L / Shift+J): the next J/L continues from it.
    public mutating func rateChanged(to rate: PlaybackRate) { shuttle.adopt(rate) }

    public mutating func handle(_ event: KeyEvent) -> [RouterAction] {
        var out = tick()
        switch event.phase {
        case .up:
            if let role = shuttleDown.removeValue(forKey: event.key) {
                pendingHold[role] = nil
                append(shuttle.release(role), to: &out)
            }
        case .down:
            guard let cmd = map.command(for: event.binding, focus: focus) else { return out }
            if event.isRepeat && !cmd.isRepeatable { return out }
            switch cmd {
            case .shuttleReverse: press(.j, event.key, &out)
            case .shuttleStop: press(.k, event.key, &out)
            case .shuttleForward: press(.l, event.key, &out)
            default: out.append(.command(cmd, focus: focus))
            }
        }
        return out
    }

    private mutating func press(_ role: ShuttleKey, _ key: Key, _ out: inout [RouterAction]) {
        // Auto-repeat of a held shuttle key is not a new press.
        guard shuttleDown[key] == nil else { return }
        let kHeld = shuttleDown.values.contains(.k)
        shuttleDown[key] = role
        append(shuttle.press(role), to: &out)
        if role != .k && kHeld { pendingHold[role] = now() }
    }

    private func append(_ a: ShuttleAction, to out: inout [RouterAction]) {
        if case .none = a { return }
        out.append(.shuttle(a))
    }
}
