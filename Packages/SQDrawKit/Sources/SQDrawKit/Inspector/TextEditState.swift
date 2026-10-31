import Foundation

/// One line of typed text without an input method (the SQ text fields of the portable UI): caret, selection, typing,
/// deletion and the caret keys. The host sends `InputKey`s; Enter and Esc are answered with `.commit` / `.cancel` so
/// the owning control decides what they do (ScrubField commits its value, a name field renames).
/// shortcut: no IME composition (dead keys and CJK input arrive as finished characters from the host); upgrade when a
/// Windows TSF / Mac NSTextInputClient bridge feeds marked text.
public struct TextEditState: Sendable, Equatable {
    public private(set) var text: [Character]
    /// Caret position (0...count) and the other end of the selection (== caret when nothing is selected).
    public private(set) var caret: Int
    public private(set) var anchor: Int

    public enum Outcome: Sendable, Equatable { case edited, moved, commit, cancel, ignored }

    /// One step of the field's own undo (the Mac field editor's Cmd-Z): the text and selection before an edit.
    struct Snapshot: Sendable, Equatable { var text: [Character]; var caret: Int; var anchor: Int }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// The last edit was typing into an empty selection: the next typed character joins its undo step.
    private var typingRun = false

    /// Starts editing `text` with everything selected (the Mac field selects all when it opens).
    public init(_ text: String, selectAll: Bool = true) {
        self.text = Array(text)
        caret = self.text.count
        anchor = selectAll ? 0 : caret
    }

    public var string: String { String(text) }
    public var selection: Range<Int> { min(caret, anchor)..<max(caret, anchor) }
    public var hasSelection: Bool { caret != anchor }

    public mutating func selectAll() { anchor = 0; caret = text.count }

    /// Replaces the selection with `s` (typing, paste).
    public mutating func insert(_ s: String) {
        let typing = !hasSelection && s.count == 1 && s != " "
        recordUndo(joinsTyping: typing)
        let r = selection
        let chars = Array(s.filter { $0 != "\n" && $0 != "\r" })
        text.replaceSubrange(r, with: chars)
        caret = r.lowerBound + chars.count
        anchor = caret
    }

    private mutating func recordUndo(joinsTyping: Bool = false) {
        if !(joinsTyping && typingRun) { undoStack.append(Snapshot(text: text, caret: caret, anchor: anchor)) }
        typingRun = joinsTyping
        redoStack = []
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Cmd-Z in the open field: the text goes back one edit (a run of typed letters is one step).
    @discardableResult
    public mutating func undo() -> Bool {
        guard let s = undoStack.popLast() else { return false }
        redoStack.append(Snapshot(text: text, caret: caret, anchor: anchor))
        text = s.text; caret = s.caret; anchor = s.anchor; typingRun = false
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let s = redoStack.popLast() else { return false }
        undoStack.append(Snapshot(text: text, caret: caret, anchor: anchor))
        text = s.text; caret = s.caret; anchor = s.anchor; typingRun = false
        return true
    }

    /// The selected text (Cmd-C, Cmd-X), nil when nothing is selected.
    public var selectedText: String? { hasSelection ? String(text[selection]) : nil }

    // MARK: Words (double-click, Option-arrows)

    private enum CharClass { case word, space, other }
    private func charClass(_ c: Character) -> CharClass {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        return c.isWhitespace ? .space : .other
    }

    /// Selects the run of like characters around `i` (a double click: the word, or the spaces / punctuation under it).
    public mutating func selectWord(at i: Int) {
        guard !text.isEmpty else { return }
        let at = max(0, min(text.count - 1, i == text.count ? i - 1 : i))
        let k = charClass(text[at])
        var lo = at, hi = at + 1
        while lo > 0, charClass(text[lo - 1]) == k { lo -= 1 }
        while hi < text.count, charClass(text[hi]) == k { hi += 1 }
        anchor = lo; caret = hi
    }

    /// Option-Left: the start of the word before `i`.
    func wordStart(before i: Int) -> Int {
        var j = i
        while j > 0, charClass(text[j - 1]) != .word { j -= 1 }
        while j > 0, charClass(text[j - 1]) == .word { j -= 1 }
        return j
    }

    /// Option-Right: the end of the word after `i`.
    func wordEnd(after i: Int) -> Int {
        var j = i
        while j < text.count, charClass(text[j]) != .word { j += 1 }
        while j < text.count, charClass(text[j]) == .word { j += 1 }
        return j
    }

    /// Places the caret at character index `i` (a click in the field); `extend` keeps the anchor (shift-click).
    public mutating func place(_ i: Int, extend: Bool = false) {
        typingRun = false
        caret = max(0, min(text.count, i))
        if !extend { anchor = caret }
    }

    @discardableResult
    public mutating func handle(_ key: InputKey, modifiers: InputModifiers = []) -> Outcome {
        let shift = modifiers.contains(.shift)
        switch key {
        case .enter: return .commit
        case .escape: return .cancel
        case .character(let c):
            if modifiers.contains(.control) { return .ignored }        // Mac Control chords are shortcuts, not text
            if modifiers.contains(.command) { return command(c, shift: shift) }
            insert(String(c)); return .edited
        case .space: insert(" "); return .edited
        case .plus: insert("+"); return .edited
        case .minus: insert("-"); return .edited
        case .backspace:
            if hasSelection { insert(""); return .edited }
            guard caret > 0 else { return .ignored }
            let from = modifiers.contains(.command) ? 0 : modifiers.contains(.option) ? wordStart(before: caret) : caret - 1
            recordUndo()
            text.removeSubrange(from..<caret); caret = from; anchor = caret
            return .edited
        case .delete:
            if hasSelection { insert(""); return .edited }
            guard caret < text.count else { return .ignored }
            recordUndo()
            let to = modifiers.contains(.command) ? text.count : modifiers.contains(.option) ? wordEnd(after: caret) : caret + 1
            text.removeSubrange(caret..<to)
            return .edited
        case .left:
            if hasSelection && !shift { caret = selection.lowerBound; anchor = caret; return .moved }
            move(to: modifiers.contains(.command) ? 0 : modifiers.contains(.option) ? wordStart(before: caret) : caret - 1, extend: shift)
            return .moved
        case .right:
            if hasSelection && !shift { caret = selection.upperBound; anchor = caret; return .moved }
            move(to: modifiers.contains(.command) ? text.count : modifiers.contains(.option) ? wordEnd(after: caret) : caret + 1, extend: shift)
            return .moved
        case .home, .up: move(to: 0, extend: shift); return .moved
        case .end, .down: move(to: text.count, extend: shift); return .moved
        case .pageUp, .pageDown, .function: return .ignored
        }
    }

    /// Cmd-A / C / X / V / Z (Shift-Z redoes): the field editor's own, so a shortcut typed into an open field never reaches
    /// the timeline's copy or undo.
    private mutating func command(_ c: Character, shift: Bool) -> Outcome {
        switch c.lowercased() {
        case "a": selectAll(); return .moved
        case "c":
            if let t = selectedText { TextClipboard.shared.write(t) }
            return .moved
        case "x":
            guard let t = selectedText else { return .moved }
            TextClipboard.shared.write(t); insert(""); return .edited
        case "v":
            guard let t = TextClipboard.shared.read(), !t.isEmpty else { return .moved }
            insert(t); typingRun = false; return .edited
        case "z": return (shift ? redo() : undo()) ? .edited : .moved
        default: return .ignored
        }
    }

    private mutating func move(to i: Int, extend: Bool) {
        typingRun = false
        caret = max(0, min(text.count, i))
        if !extend { anchor = caret }
    }

    // MARK: Multi-line (the text clip's box)

    /// Start index of every line; a "\n" ends a line.
    public var lineStarts: [Int] {
        var s = [0]
        for (i, ch) in text.enumerated() where ch == "\n" { s.append(i + 1) }
        return s
    }

    /// Line and column of character index `i`.
    public func position(of i: Int) -> (line: Int, column: Int) {
        let starts = lineStarts
        let line = (starts.lastIndex { $0 <= i }) ?? 0
        return (line, i - starts[line])
    }

    /// Index of `column` in `line`, clamped to the line (its end is before its "\n").
    public func index(line: Int, column: Int) -> Int {
        let starts = lineStarts
        let l = max(0, min(starts.count - 1, line))
        let end = l + 1 < starts.count ? starts[l + 1] - 1 : text.count
        return min(starts[l] + max(0, column), end)
    }

    /// Keys of a multi-line box: Return breaks the line, Up / Down keep the column, Home / End go to the line's ends
    /// (with Command to the text's ends); the rest as `handle`.
    @discardableResult
    public mutating func handleLines(_ key: InputKey, modifiers: InputModifiers = []) -> Outcome {
        let shift = modifiers.contains(.shift)
        switch key {
        case .enter:
            let r = selection
            recordUndo()
            text.replaceSubrange(r, with: ["\n"])
            caret = r.lowerBound + 1; anchor = caret
            return .edited
        case .up, .down:
            let p = position(of: caret)
            let target = p.line + (key == .up ? -1 : 1)
            if target < 0 { move(to: 0, extend: shift) }
            else if target >= lineStarts.count { move(to: text.count, extend: shift) }
            else { move(to: index(line: target, column: p.column), extend: shift) }
            return .moved
        case .home, .end:
            if modifiers.contains(.command) { move(to: key == .home ? 0 : text.count, extend: shift); return .moved }
            let line = position(of: caret).line
            move(to: index(line: line, column: key == .home ? 0 : Int.max / 2), extend: shift)
            return .moved
        case .left where modifiers.contains(.command), .right where modifiers.contains(.command):
            let line = position(of: caret).line
            move(to: index(line: line, column: key == .left ? 0 : Int.max / 2), extend: shift)
            return .moved
        default:
            return handle(key, modifiers: modifiers)
        }
    }
}
