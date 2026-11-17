// Swift: TextEditState.swift
//! One line of typed text without an input method (the SQ text fields of the portable UI): caret, selection, typing,
//! deletion and the caret keys. The host sends `InputKey`s; Enter and Esc are answered with `Commit` / `Cancel` so
//! the owning control decides what they do (ScrubField commits its value, a name field renames).
//! Input methods (CJK, dead keys): the host gets winit `Ime` events, draws the composition inline from the caret
//! (`Requests::draw_composition`) and hands the finished text over as `cx.typed_text`.
//! Swift `Character` (a grapheme cluster) is a Rust `char` here; the notes list the difference.

use crate::input::{InputKey, InputModifiers};
use crate::ui_cx::UiCx;
use std::ops::Range;

/// What a key did to the editor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The text changed.
    Edited,
    /// Only caret or selection moved.
    Moved,
    /// Enter.
    Commit,
    /// Escape.
    Cancel,
    /// Not a key of the editor.
    Ignored,
}

/// One step of the field's own undo (the Mac field editor's Cmd-Z): the text and selection before an edit.
#[derive(Clone, Debug, PartialEq)]
struct Snapshot {
    text: Vec<char>,
    caret: usize,
    anchor: usize,
}

#[derive(PartialEq)]
enum CharClass {
    Word,
    Space,
    Other,
}

fn char_class(c: char) -> CharClass {
    if c.is_alphabetic() || c.is_numeric() || c == '_' {
        return CharClass::Word;
    }
    if c.is_whitespace() { CharClass::Space } else { CharClass::Other }
}

/// The open text editor of a field.
#[derive(Clone, Debug, PartialEq)]
pub struct TextEditState {
    text: Vec<char>,
    /// Caret position (0...count) and the other end of the selection (== caret when nothing is selected).
    caret: usize,
    anchor: usize,
    undo_stack: Vec<Snapshot>,
    redo_stack: Vec<Snapshot>,
    /// The last edit was typing into an empty selection: the next typed character joins its undo step.
    typing_run: bool,
}

impl TextEditState {
    /// Starts editing `text` with everything selected (the Mac field selects all when it opens).
    pub fn new(text: &str) -> TextEditState {
        TextEditState::with_select_all(text, true)
    }

    /// Starts editing `text`; `select_all` false puts the caret at the end.
    pub fn with_select_all(text: &str, select_all: bool) -> TextEditState {
        let text: Vec<char> = text.chars().collect();
        let caret = text.len();
        TextEditState {
            text,
            caret,
            anchor: if select_all { 0 } else { caret },
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            typing_run: false,
        }
    }

    /// The characters.
    pub fn text(&self) -> &[char] {
        &self.text
    }
    /// The caret position.
    pub fn caret(&self) -> usize {
        self.caret
    }
    /// The other end of the selection.
    pub fn anchor(&self) -> usize {
        self.anchor
    }
    /// The text as a string.
    pub fn string(&self) -> String {
        self.text.iter().collect()
    }
    /// The selected range (empty at the caret when nothing is selected).
    pub fn selection(&self) -> Range<usize> {
        self.caret.min(self.anchor)..self.caret.max(self.anchor)
    }
    /// Whether anything is selected.
    pub fn has_selection(&self) -> bool {
        self.caret != self.anchor
    }

    /// Selects everything.
    pub fn select_all(&mut self) {
        self.anchor = 0;
        self.caret = self.text.len();
    }

    /// Replaces the selection with `s` (typing, paste).
    pub fn insert(&mut self, s: &str) {
        let typing = !self.has_selection() && s.chars().count() == 1 && s != " ";
        self.record_undo(typing);
        let r = self.selection();
        let chars: Vec<char> = s.chars().filter(|c| *c != '\n' && *c != '\r').collect();
        let n = chars.len();
        let start = r.start;
        self.text.splice(r, chars);
        self.caret = start + n;
        self.anchor = self.caret;
    }

    fn record_undo(&mut self, joins_typing: bool) {
        if !(joins_typing && self.typing_run) {
            self.undo_stack.push(self.snapshot());
        }
        self.typing_run = joins_typing;
        self.redo_stack = Vec::new();
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot { text: self.text.clone(), caret: self.caret, anchor: self.anchor }
    }

    fn restore(&mut self, s: Snapshot) {
        self.text = s.text;
        self.caret = s.caret;
        self.anchor = s.anchor;
        self.typing_run = false;
    }

    /// Whether Cmd-Z has a step.
    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }
    /// Whether Shift-Cmd-Z has a step.
    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    /// Cmd-Z in the open field: the text goes back one edit (a run of typed letters is one step).
    pub fn undo(&mut self) -> bool {
        let Some(s) = self.undo_stack.pop() else { return false };
        self.redo_stack.push(self.snapshot());
        self.restore(s);
        true
    }

    /// Shift-Cmd-Z.
    pub fn redo(&mut self) -> bool {
        let Some(s) = self.redo_stack.pop() else { return false };
        self.undo_stack.push(self.snapshot());
        self.restore(s);
        true
    }

    /// The selected text (Cmd-C, Cmd-X), `None` when nothing is selected.
    pub fn selected_text(&self) -> Option<String> {
        self.has_selection().then(|| self.text[self.selection()].iter().collect())
    }

    // Words (double-click, Option-arrows)

    /// Selects the run of like characters around `i` (a double click: the word, or the spaces / punctuation under it).
    pub fn select_word(&mut self, i: usize) {
        if self.text.is_empty() {
            return;
        }
        let at = (if i == self.text.len() { i - 1 } else { i }).min(self.text.len() - 1);
        let k = char_class(self.text[at]);
        let (mut lo, mut hi) = (at, at + 1);
        while lo > 0 && char_class(self.text[lo - 1]) == k {
            lo -= 1;
        }
        while hi < self.text.len() && char_class(self.text[hi]) == k {
            hi += 1;
        }
        self.anchor = lo;
        self.caret = hi;
    }

    /// Option-Left: the start of the word before `i`.
    fn word_start(&self, i: usize) -> usize {
        let mut j = i;
        while j > 0 && char_class(self.text[j - 1]) != CharClass::Word {
            j -= 1;
        }
        while j > 0 && char_class(self.text[j - 1]) == CharClass::Word {
            j -= 1;
        }
        j
    }

    /// Option-Right: the end of the word after `i`.
    fn word_end(&self, i: usize) -> usize {
        let mut j = i;
        while j < self.text.len() && char_class(self.text[j]) != CharClass::Word {
            j += 1;
        }
        while j < self.text.len() && char_class(self.text[j]) == CharClass::Word {
            j += 1;
        }
        j
    }

    /// Places the caret at character index `i` (a click in the field); `extend` keeps the anchor (shift-click).
    pub fn place(&mut self, i: usize, extend: bool) {
        self.typing_run = false;
        self.caret = i.min(self.text.len());
        if !extend {
            self.anchor = self.caret;
        }
    }

    /// One key. The keyboard layout's text for the press (`cx.typed_text`) wins over the key position.
    pub fn handle(&mut self, key: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> Outcome {
        let shift = modifiers.contains(InputModifiers::SHIFT);
        // The system layout's text for this press wins over the key position (Y is not Z, Shift gives capitals, AltGr @).
        if let Some(typed) = cx.typed_text.clone().filter(|t| !t.is_empty())
            && matches!(key, InputKey::Character(_) | InputKey::Space | InputKey::Plus | InputKey::Minus)
        {
            self.insert(&typed);
            return Outcome::Edited;
        }
        match key {
            InputKey::Enter => Outcome::Commit,
            InputKey::Escape => Outcome::Cancel,
            InputKey::Character(c) => {
                if modifiers.contains(InputModifiers::CONTROL) {
                    return Outcome::Ignored; // Mac Control chords are shortcuts, not text
                }
                if modifiers.contains(InputModifiers::COMMAND) {
                    return self.command(c, shift, cx);
                }
                self.insert(&c.to_string());
                Outcome::Edited
            }
            InputKey::Space => {
                self.insert(" ");
                Outcome::Edited
            }
            InputKey::Plus => {
                self.insert("+");
                Outcome::Edited
            }
            InputKey::Minus => {
                self.insert("-");
                Outcome::Edited
            }
            InputKey::Backspace => {
                if self.has_selection() {
                    self.insert("");
                    return Outcome::Edited;
                }
                if self.caret == 0 {
                    return Outcome::Ignored;
                }
                let from = if modifiers.contains(InputModifiers::COMMAND) {
                    0
                } else if modifiers.contains(InputModifiers::OPTION) {
                    self.word_start(self.caret)
                } else {
                    self.caret - 1
                };
                self.record_undo(false);
                self.text.drain(from..self.caret);
                self.caret = from;
                self.anchor = self.caret;
                Outcome::Edited
            }
            InputKey::Delete => {
                if self.has_selection() {
                    self.insert("");
                    return Outcome::Edited;
                }
                if self.caret >= self.text.len() {
                    return Outcome::Ignored;
                }
                self.record_undo(false);
                let to = if modifiers.contains(InputModifiers::COMMAND) {
                    self.text.len()
                } else if modifiers.contains(InputModifiers::OPTION) {
                    self.word_end(self.caret)
                } else {
                    self.caret + 1
                };
                self.text.drain(self.caret..to);
                Outcome::Edited
            }
            InputKey::Left => {
                if self.has_selection() && !shift {
                    self.caret = self.selection().start;
                    self.anchor = self.caret;
                    return Outcome::Moved;
                }
                let to = if modifiers.contains(InputModifiers::COMMAND) {
                    0
                } else if modifiers.contains(InputModifiers::OPTION) {
                    self.word_start(self.caret)
                } else {
                    self.caret.saturating_sub(1)
                };
                self.move_to(to, shift);
                Outcome::Moved
            }
            InputKey::Right => {
                if self.has_selection() && !shift {
                    self.caret = self.selection().end;
                    self.anchor = self.caret;
                    return Outcome::Moved;
                }
                let to = if modifiers.contains(InputModifiers::COMMAND) {
                    self.text.len()
                } else if modifiers.contains(InputModifiers::OPTION) {
                    self.word_end(self.caret)
                } else {
                    self.caret + 1
                };
                self.move_to(to, shift);
                Outcome::Moved
            }
            InputKey::Home | InputKey::Up => {
                self.move_to(0, shift);
                Outcome::Moved
            }
            InputKey::End | InputKey::Down => {
                self.move_to(self.text.len(), shift);
                Outcome::Moved
            }
            InputKey::PageUp | InputKey::PageDown | InputKey::Function(_) => Outcome::Ignored,
        }
    }

    /// Cmd-A / C / X / V / Z (Shift-Z redoes): the field editor's own, so a shortcut typed into an open field never reaches
    /// the timeline's copy or undo.
    fn command(&mut self, c: char, shift: bool, cx: &mut UiCx) -> Outcome {
        let lower: String = c.to_lowercase().collect();
        match lower.as_str() {
            "a" => {
                self.select_all();
                Outcome::Moved
            }
            "c" => {
                if let Some(t) = self.selected_text() {
                    cx.clipboard.write(&t);
                }
                Outcome::Moved
            }
            "x" => {
                let Some(t) = self.selected_text() else { return Outcome::Moved };
                cx.clipboard.write(&t);
                self.insert("");
                Outcome::Edited
            }
            "v" => {
                let Some(t) = cx.clipboard.read().filter(|t| !t.is_empty()) else { return Outcome::Moved };
                self.insert(&t);
                self.typing_run = false;
                Outcome::Edited
            }
            "z" => {
                let done = if shift { self.redo() } else { self.undo() };
                if done { Outcome::Edited } else { Outcome::Moved }
            }
            _ => Outcome::Ignored,
        }
    }

    fn move_to(&mut self, i: usize, extend: bool) {
        self.typing_run = false;
        self.caret = i.min(self.text.len());
        if !extend {
            self.anchor = self.caret;
        }
    }

    // Multi-line (the text clip's box)

    /// Start index of every line; a "\n" ends a line.
    pub fn line_starts(&self) -> Vec<usize> {
        let mut s = vec![0];
        for (i, ch) in self.text.iter().enumerate() {
            if *ch == '\n' {
                s.push(i + 1);
            }
        }
        s
    }

    /// Line and column of character index `i`.
    pub fn position(&self, i: usize) -> (usize, usize) {
        let starts = self.line_starts();
        let line = starts.iter().rposition(|s| *s <= i).unwrap_or(0);
        (line, i - starts[line])
    }

    /// Index of `column` in `line`, clamped to the line (its end is before its "\n").
    pub fn index(&self, line: i64, column: i64) -> usize {
        let starts = self.line_starts();
        let l = line.clamp(0, starts.len() as i64 - 1) as usize;
        let end = if l + 1 < starts.len() { starts[l + 1] - 1 } else { self.text.len() };
        let at = starts[l] as i64 + column.max(0);
        (at.min(end as i64)) as usize
    }

    /// Keys of a multi-line box: Return breaks the line, Up / Down keep the column, Home / End go to the line's ends
    /// (with Command to the text's ends); the rest as `handle`.
    pub fn handle_lines(&mut self, key: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> Outcome {
        let shift = modifiers.contains(InputModifiers::SHIFT);
        let command = modifiers.contains(InputModifiers::COMMAND);
        const FAR: i64 = i64::MAX / 2;
        match key {
            InputKey::Enter => {
                let r = self.selection();
                self.record_undo(false);
                let start = r.start;
                self.text.splice(r, ['\n']);
                self.caret = start + 1;
                self.anchor = self.caret;
                Outcome::Edited
            }
            InputKey::Up | InputKey::Down => {
                let p = self.position(self.caret);
                let target = p.0 as i64 + if key == InputKey::Up { -1 } else { 1 };
                if target < 0 {
                    self.move_to(0, shift);
                } else if target >= self.line_starts().len() as i64 {
                    self.move_to(self.text.len(), shift);
                } else {
                    let to = self.index(target, p.1 as i64);
                    self.move_to(to, shift);
                }
                Outcome::Moved
            }
            InputKey::Home | InputKey::End => {
                if command {
                    self.move_to(if key == InputKey::Home { 0 } else { self.text.len() }, shift);
                    return Outcome::Moved;
                }
                let line = self.position(self.caret).0;
                let to = self.index(line as i64, if key == InputKey::Home { 0 } else { FAR });
                self.move_to(to, shift);
                Outcome::Moved
            }
            InputKey::Left | InputKey::Right if command => {
                let line = self.position(self.caret).0;
                let to = self.index(line as i64, if key == InputKey::Left { 0 } else { FAR });
                self.move_to(to, shift);
                Outcome::Moved
            }
            _ => self.handle(key, modifiers, cx),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(s: &str, cx: &mut UiCx) -> TextEditState {
        let mut e = TextEditState::with_select_all("", false);
        for c in s.chars() {
            e.handle(if c == ' ' { InputKey::Space } else { InputKey::Character(c) }, InputModifiers::NONE, cx);
        }
        e
    }

    fn sel(e: &TextEditState) -> String {
        e.text()[e.selection()].iter().collect()
    }

    #[test]
    fn typing_replaces_the_initial_selection() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::new("12.5");
        assert_eq!(e.selection(), 0..4);
        e.handle(InputKey::Character('4'), InputModifiers::NONE, &mut cx);
        e.handle(InputKey::Character('0'), InputModifiers::NONE, &mut cx);
        assert_eq!(e.string(), "40");
        e.handle(InputKey::Left, InputModifiers::NONE, &mut cx);
        e.handle(InputKey::Backspace, InputModifiers::NONE, &mut cx);
        assert!(e.string() == "0" && e.caret() == 0);
        e.handle(InputKey::End, InputModifiers::NONE, &mut cx);
        e.handle(InputKey::Left, InputModifiers::SHIFT, &mut cx);
        assert_eq!(e.selection(), 0..1);
        e.handle(InputKey::Delete, InputModifiers::NONE, &mut cx);
        assert_eq!(e.string(), "");
        assert_eq!(e.handle(InputKey::Enter, InputModifiers::NONE, &mut cx), Outcome::Commit);
        assert_eq!(e.handle(InputKey::Escape, InputModifiers::NONE, &mut cx), Outcome::Cancel);
    }

    #[test]
    fn command_a_and_command_backspace() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("abc", false);
        e.handle(InputKey::Character('a'), InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.selection(), 0..3);
        e.place(2, false);
        e.handle(InputKey::Backspace, InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.string(), "c");
    }

    #[test]
    fn return_breaks_the_line_and_replaces_the_selection() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("ab", false);
        e.place(1, false);
        assert_eq!(e.handle_lines(InputKey::Enter, InputModifiers::NONE, &mut cx), Outcome::Edited);
        assert!(e.string() == "a\nb" && e.caret() == 2);
        e.select_all();
        e.handle_lines(InputKey::Enter, InputModifiers::NONE, &mut cx);
        assert!(e.string() == "\n" && e.caret() == 1);
    }

    #[test]
    fn up_and_down_keep_the_column_and_clamp_to_short_lines() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("hello\nab\nworld", false);
        e.place(4, false);
        e.handle_lines(InputKey::Down, InputModifiers::NONE, &mut cx);
        assert_eq!(e.position(e.caret()), (1, 2));
        e.handle_lines(InputKey::Down, InputModifiers::NONE, &mut cx);
        assert_eq!(e.position(e.caret()), (2, 2));
        e.handle_lines(InputKey::Down, InputModifiers::NONE, &mut cx);
        assert_eq!(e.caret(), e.text().len());
        e.place(1, false);
        e.handle_lines(InputKey::Up, InputModifiers::NONE, &mut cx);
        assert_eq!(e.caret(), 0);
        e.handle_lines(InputKey::Down, InputModifiers::SHIFT, &mut cx);
        assert_eq!(e.selection(), 0..6);
    }

    #[test]
    fn home_and_end_stay_on_the_line_command_goes_to_the_ends() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("one\ntwo", false);
        e.place(5, false);
        e.handle_lines(InputKey::Home, InputModifiers::NONE, &mut cx);
        assert_eq!(e.caret(), 4);
        e.handle_lines(InputKey::End, InputModifiers::NONE, &mut cx);
        assert_eq!(e.caret(), 7);
        e.place(1, false);
        e.handle_lines(InputKey::End, InputModifiers::NONE, &mut cx);
        assert_eq!(e.caret(), 3);
        e.handle_lines(InputKey::Home, InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.caret(), 0);
        e.handle_lines(InputKey::Right, InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.caret(), 3);
    }

    #[test]
    fn typing_still_goes_through_the_single_line_keys() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("a\nb", false);
        assert_eq!(e.handle_lines(InputKey::Character('c'), InputModifiers::NONE, &mut cx), Outcome::Edited);
        assert_eq!(e.string(), "a\nbc");
        for _ in 0..3 {
            e.handle_lines(InputKey::Backspace, InputModifiers::NONE, &mut cx);
        }
        assert_eq!(e.string(), "a");
    }

    #[test]
    fn double_click_selects_the_word_under_the_pointer() {
        let mut e = TextEditState::with_select_all("hello big-world", false);
        e.select_word(7);
        assert_eq!(sel(&e), "big");
        e.select_word(5);
        assert_eq!(sel(&e), " ");
        e.select_word(15);
        assert_eq!(sel(&e), "world");
    }

    #[test]
    fn option_arrows_jump_words_and_option_backspace_deletes_one() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("one two  three", false);
        e.handle(InputKey::Left, InputModifiers::OPTION, &mut cx);
        assert_eq!(e.caret(), 9);
        e.handle(InputKey::Left, InputModifiers::OPTION, &mut cx);
        assert_eq!(e.caret(), 4);
        e.handle(InputKey::Right, InputModifiers::OPTION, &mut cx);
        assert_eq!(e.caret(), 7);
        e.handle(InputKey::Backspace, InputModifiers::OPTION, &mut cx);
        assert!(e.string() == "one   three" && e.caret() == 4);
        e.handle(InputKey::Delete, InputModifiers::OPTION, &mut cx);
        assert_eq!(e.string(), "one ");
    }

    #[test]
    fn shift_option_left_extends_the_selection_by_a_word() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("one two", false);
        e.handle(InputKey::Left, InputModifiers::OPTION | InputModifiers::SHIFT, &mut cx);
        assert_eq!(sel(&e), "two");
    }

    #[test]
    fn copy_cut_and_paste_use_the_clipboard() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("hello world", false);
        e.select_word(1);
        assert_eq!(e.handle(InputKey::Character('c'), InputModifiers::COMMAND, &mut cx), Outcome::Moved);
        assert_eq!(cx.clipboard.read().as_deref(), Some("hello"));
        assert_eq!(e.handle(InputKey::Character('x'), InputModifiers::COMMAND, &mut cx), Outcome::Edited);
        assert_eq!(e.string(), " world");
        e.place(e.text().len(), false);
        assert_eq!(e.handle(InputKey::Character('v'), InputModifiers::COMMAND, &mut cx), Outcome::Edited);
        assert_eq!(e.string(), " worldhello");
    }

    #[test]
    fn paste_replaces_the_selection_and_system_clipboard_wins() {
        use std::cell::RefCell;
        use std::rc::Rc;
        let mut cx = UiCx::new();
        let written = Rc::new(RefCell::new(Vec::<String>::new()));
        let sink = Rc::clone(&written);
        cx.clipboard.write_system = Some(Box::new(move |s| sink.borrow_mut().push(s.to_string())));
        cx.clipboard.read_system = Some(Box::new(|| Some("SYS".to_string())));
        let mut e = TextEditState::new("abc");
        e.handle(InputKey::Character('v'), InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.string(), "SYS");
        e.select_all();
        e.handle(InputKey::Character('c'), InputModifiers::COMMAND, &mut cx);
        assert_eq!(*written.borrow(), vec!["SYS".to_string()]);
    }

    #[test]
    fn command_z_undoes_typing_runs_and_shift_command_z_redoes() {
        let mut cx = UiCx::new();
        let mut e = typed("abc", &mut cx);
        e.handle(InputKey::Backspace, InputModifiers::NONE, &mut cx);
        assert_eq!(e.string(), "ab");
        assert_eq!(e.handle(InputKey::Character('z'), InputModifiers::COMMAND, &mut cx), Outcome::Edited);
        assert_eq!(e.string(), "abc");
        e.handle(InputKey::Character('z'), InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.string(), "");
        assert_eq!(e.handle(InputKey::Character('z'), InputModifiers::COMMAND, &mut cx), Outcome::Moved);
        e.handle(InputKey::Character('z'), InputModifiers::COMMAND | InputModifiers::SHIFT, &mut cx);
        assert_eq!(e.string(), "abc");
    }

    #[test]
    fn undo_restores_a_cut_selection() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::with_select_all("keep this", false);
        e.select_word(6);
        e.handle(InputKey::Character('x'), InputModifiers::COMMAND, &mut cx);
        assert_eq!(e.string(), "keep ");
        e.handle(InputKey::Character('z'), InputModifiers::COMMAND, &mut cx);
        assert!(e.string() == "keep this" && sel(&e) == "this");
    }

    #[test]
    fn the_layout_text_wins_over_the_key_position() {
        let mut cx = UiCx::new();
        cx.typed_text = Some("z".to_string());
        let mut e = TextEditState::with_select_all("", false);
        assert_eq!(e.handle(InputKey::Character('y'), InputModifiers::NONE, &mut cx), Outcome::Edited);
        assert_eq!(e.string(), "z");
    }

    #[test]
    fn a_committed_input_method_text_is_typed_whole() {
        // The host delivers an `Ime::Commit` as a key of no binding with the text in `typed_text`.
        let mut cx = UiCx::new();
        cx.typed_text = Some("日本語".to_string());
        let mut e = TextEditState::with_select_all("ab", false);
        assert_eq!(e.handle(InputKey::Character('\0'), InputModifiers::NONE, &mut cx), Outcome::Edited);
        assert_eq!(e.string(), "ab日本語");
        assert_eq!(e.caret(), 5);
    }
}
