import Foundation
import SSCore

public enum RouterAction: Sendable, Equatable {
    case command(EditorCommand, focus: PanelID?)
    case shuttle(ShuttleAction)
}

/// Pure key routing: key events + focused panel -> actions. No AppKit.
/// The UI must not call it while a text field is first responder.
/// It owns the J/K/L down/up state machine (SSCore `Shuttle`). The hold timing for "K held + L/J held > 0.25 s"
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
