#if os(macOS)
import AppKit
#endif
import Foundation
import SQCore
import SQDrawKit

/// Keyboard commands of the Graph Editor: F fits every drawn key, Shift-F the selection, Cmd-A selects every drawn key,
/// F9 / Shift-F9 / Cmd-Shift-F9 apply Smooth / Smooth in / Smooth out to the selected keys (one undo step each).
public enum GraphEditorShortcut: Equatable, Sendable {
    case fitAll, fitSelection, selectAll
    case ease(KeyInterpolationChoice)

    /// The same keys on the shared toolkit (Ctrl on Windows arrives as `.command`).
    public static func resolve(_ k: InputKey, modifiers: InputModifiers) -> GraphEditorShortcut? {
        let f = modifiers.intersection([.command, .shift, .option])
        if k == .function(9) {
            switch f {
            case []: return .ease(.easyEase)
            case [.shift]: return .ease(.easeIn)
            case [.command, .shift]: return .ease(.easeOut)
            default: return nil
            }
        }
        guard case .character(let ch) = k else { return nil }
        switch (ch.lowercased(), f) {
        case ("f", []): return .fitAll
        case ("f", [.shift]): return .fitSelection
        case ("a", [.command]): return .selectAll
        default: return nil
        }
    }

    #if os(macOS)
    /// `characters` are the characters ignoring modifiers.
    public static func resolve(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> GraphEditorShortcut? {
        let f = flags.intersection([.command, .shift, .option, .control])
        if keyCode == 101 {                                     // F9
            switch f {
            case []: return .ease(.easyEase)
            case [.shift]: return .ease(.easeIn)
            case [.command, .shift]: return .ease(.easeOut)
            default: return nil
            }
        }
        switch (characters?.lowercased(), f) {
        case ("f", []): return .fitAll
        case ("f", [.shift]): return .fitSelection
        case ("a", [.command]): return .selectAll
        default: return nil
        }
    }
    #endif
}

extension EffectControlsModel {
    /// Selects every key of every drawn curve.
    public func selectAllGraphKeys() {
        var all: [SummaryMember] = []
        for c in graphEditorCurves() { all += c.curve.keys.map { SummaryMember(property: c.property, keyID: $0.id) } }
        select(all, extend: false)
    }

    public func perform(_ shortcut: GraphEditorShortcut) {
        switch shortcut {
        case .fitAll: fitGraph(selectionOnly: false)
        case .fitSelection: fitGraph(selectionOnly: true)
        case .selectAll: selectAllGraphKeys()
        case .ease(let c): applyGraphEase(c)
        }
    }
}
