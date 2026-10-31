import Foundation
import Testing
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

/// Every binding of the Premiere key map, pressed the way the Mac shared window sends it (`MacKeys` key code and flag
/// bits, then `ShellKeys.command`), must run the command the AppKit key route runs for the same chord.
@Suite("Mac shortcut route")
struct MacShortcutRouteTests {
    static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20

    /// The key code of the US cap for `key` (non-keypad first).
    static func code(for key: Key) -> UInt16? {
        let keypad: Set<UInt16> = [69, 78, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        let all = (0..<128).map(UInt16.init)
        return (all.filter { !keypad.contains($0) } + all.filter { keypad.contains($0) }).first { c in
            guard let k = MacKeys.key(code: c) else { return false }
            return ShellKeys.key(k) == key
        }
    }

    static func flags(_ m: KeyModifiers) -> UInt {
        (m.contains(.shift) ? shift : 0) | (m.contains(.control) ? control : 0)
            | (m.contains(.option) ? option : 0) | (m.contains(.command) ? command : 0)
    }

    static func panel(for scope: CommandScope) -> PanelID? {
        switch scope {
        case .global: nil
        case .timeline: .timeline
        case .program: .programMonitor
        case .source: .sourceMonitor
        case .project: .project
        case .effectControls: .effectControls
        }
    }

    /// What the window sends for one press and the command the shell resolves from it.
    static func route(_ b: KeyBinding, focus: PanelID?, map: CommandMap) -> EditorCommand? {
        guard let code = code(for: b.key) else { return nil }
        let fl = flags(b.modifiers)
        let events = MacKeys.events(key: MacKeys.key(code: code), modifiers: MacKeys.keyModifiers(flags: fl), committed: "", composing: false)
        guard case .keyDown(let k, let m)? = events.first else { return nil }
        return ShellKeys.command(k, m, focus: focus, map: map, mac: true)
    }

    @Test func everyBindingOfTheMapRunsItsCommandFromTheMacWindow() {
        let map = CommandMap.premiereDefault
        var wrong: [String] = []
        for e in map.entries {
            let focus = Self.panel(for: e.scope)
            let got = Self.route(e.binding, focus: focus, map: map)
            if got != e.command { wrong.append("\(e.scope) \(e.binding) wants \(e.command), got \(String(describing: got))") }
        }
        #expect(wrong.isEmpty, Comment(rawValue: "\(wrong.count) bindings do not reach their command:\n" + wrong.joined(separator: "\n")))
    }

    @Test func aChordWithoutABindingRunsNothingOnTheMac() {
        // Command+E has no binding; its Control twin (Append to Main Track) must not answer for it (a Windows rule).
        let map = CommandMap.premiereDefault
        var leaks: [String] = []
        for e in map.entries where e.binding.modifiers.contains(.control) && !e.binding.modifiers.contains(.command) {
            var cmd = e.binding.modifiers
            cmd.remove(.control); cmd.insert(.command)
            let twin = KeyBinding(e.binding.key, cmd)
            let focus = Self.panel(for: e.scope)
            if map.command(for: twin, focus: focus) != nil { continue }
            if let got = Self.route(twin, focus: focus, map: map) { leaks.append("\(twin) answers \(got)") }
        }
        #expect(leaks.isEmpty, Comment(rawValue: leaks.joined(separator: "\n")))
    }
}
