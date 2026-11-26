// Swift: CommandMap.swift
//! The key map: which binding runs which command in which scope, and the default sets.

use crate::editor_command::{CommandScope, EditorCommand, EditorTool};
use crate::key_binding::{Key, KeyBinding, KeyModifiers as M};
use crate::key_binding_text::WindowsKeyRoute;
use crate::keymap_store::{Keymap, KeymapOverride};
use crate::layout_keys;
use crate::panel_id::PanelID;
use sq_core_model::TrackKind;
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

/// One binding: where it applies, the key and the command it runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Entry {
    pub scope: CommandScope,
    pub binding: KeyBinding,
    pub command: EditorCommand,
}

/// A key map: the entries in order and a lookup table over them.
#[derive(Clone, Debug)]
pub struct CommandMap {
    /// Every entry, in order.
    pub entries: Vec<Entry>,
    table: HashMap<CommandScope, HashMap<KeyBinding, EditorCommand>>,
}

impl CommandMap {
    /// A map over `entries`; when a (scope, binding) pair appears twice the first one wins.
    pub fn new(entries: Vec<Entry>) -> CommandMap {
        let mut table: HashMap<CommandScope, HashMap<KeyBinding, EditorCommand>> = HashMap::new();
        for e in &entries {
            table.entry(e.scope).or_default().entry(e.binding).or_insert(e.command);
        }
        CommandMap { entries, table }
    }

    /// Entries whose (scope, binding) is bound more than once. Must be empty.
    pub fn duplicates(&self) -> Vec<Entry> {
        let mut seen: HashMap<CommandScope, HashSet<KeyBinding>> = HashMap::new();
        let mut out = Vec::new();
        for e in &self.entries {
            if !seen.entry(e.scope).or_default().insert(e.binding) {
                out.push(*e);
            }
        }
        out
    }

    /// Focus-specific scope wins over `Global`.
    pub fn command_for(&self, binding: &KeyBinding, focus: Option<PanelID>) -> Option<EditorCommand> {
        let table = &self.table;
        if let Some(c) = CommandScope::scope_for(focus).and_then(|s| table.get(&s)).and_then(|t| t.get(binding)) {
            return Some(*c);
        }
        table.get(&CommandScope::Global).and_then(|t| t.get(binding)).copied()
    }

    /// First binding of a command (menus show it as key equivalent). Global scope preferred.
    pub fn binding_for(&self, command: &EditorCommand) -> Option<KeyBinding> {
        self.entries
            .iter()
            .find(|e| e.command == *command && e.scope == CommandScope::Global)
            .or_else(|| self.entries.iter().find(|e| e.command == *command))
            .map(|e| e.binding)
    }

    /// The key a menu row, tooltip or list shows for `command` on `platform`: the first binding of the command (Global scope
    /// first) that a key press there really runs as this command. The Mac presses every binding as written. Windows and
    /// Linux have one Ctrl for the Mac's Command and Control, so a Control binding whose Ctrl twin is bound runs the twin
    /// (or, in another panel, a second command): that chord stays reachable from the menus and Quick Apply only ("Menu
    /// only" in the manual) and shows no key. They also type on the layout in use: a binding no key of it reaches shows
    /// no key either (`layout_keys`).
    pub fn shown_binding_for(&self, command: &EditorCommand, platform: sq_os::Platform) -> Option<KeyBinding> {
        self.shown_binding_on(command, platform, sq_os::keyboard::active().as_deref())
    }

    /// [`CommandMap::shown_binding_for`] on a given keyboard layout (`None`: the US keyboard).
    pub fn shown_binding_on(
        &self,
        command: &EditorCommand,
        platform: sq_os::Platform,
        layout: Option<&sq_os::keyboard::ActiveKeyboard>,
    ) -> Option<KeyBinding> {
        let own = |global: bool| {
            self.entries.iter().filter(move |e| e.command == *command && (e.scope == CommandScope::Global) == global)
        };
        own(true).chain(own(false)).find(|e| self.is_pressable_with(e, platform, layout)).map(|e| e.binding)
    }

    /// Whether the key press of `e` on `platform` runs `e.command` (see [`CommandMap::shown_binding_for`]).
    pub fn is_pressable_on(&self, e: &Entry, platform: sq_os::Platform) -> bool {
        self.is_pressable_with(e, platform, sq_os::keyboard::active().as_deref())
    }

    /// [`CommandMap::is_pressable_on`] on a given keyboard layout (`None`: the US keyboard).
    pub fn is_pressable_with(
        &self,
        e: &Entry,
        platform: sq_os::Platform,
        layout: Option<&sq_os::keyboard::ActiveKeyboard>,
    ) -> bool {
        platform.key_text_style() == sq_os::KeyTextStyle::Symbols || (self.pc_press_runs(e) && self.types_on(e, layout))
    }

    /// [`CommandMap::shown_binding_for`] on the system the app runs on.
    pub fn shown_binding_here(&self, command: &EditorCommand) -> Option<KeyBinding> {
        self.shown_binding_for(command, sq_os::Platform::current())
    }

    /// Whether some key of `layout` makes the character of `e`'s binding (a key that is no character needs none).
    fn types_on(&self, e: &Entry, layout: Option<&sq_os::keyboard::ActiveKeyboard>) -> bool {
        let Key::Char(c) = e.binding.key else { return true };
        let m = e.binding.modifiers;
        let (ctrl, alt) = (m.contains(M::COMMAND) || m.contains(M::CONTROL), m.contains(M::OPTION));
        let binds = |c: char, shift: bool| self.binds_press(Key::Char(layout_keys::map_char(c)), ctrl, alt, shift);
        layout_keys::typing(layout, c, m.contains(M::SHIFT), &binds).is_some()
    }

    /// Whether any scope binds `key` for a press with these modifiers (the Windows and Linux route: `ctrl` reaches Command
    /// and Control bindings).
    pub fn binds_press(&self, key: Key, ctrl: bool, alt: bool, shift: bool) -> bool {
        WindowsKeyRoute::candidates(key, ctrl, alt, shift)
            .iter()
            .any(|b| self.table.values().any(|t| t.contains_key(b)))
    }

    /// Whether any scope of the running map binds `key` for a press with these modifiers (see [`CommandMap::binds_press`]).
    pub fn current_binds_press(key: Key, ctrl: bool, alt: bool, shift: bool) -> bool {
        Self::with_current(|m| m.binds_press(key, ctrl, alt, shift))
    }

    /// Whether the Ctrl chord of `e` runs `e.command` in every panel where the entry applies (the Windows and Linux route).
    fn pc_press_runs(&self, e: &Entry) -> bool {
        let m = e.binding.modifiers;
        let ctrl = m.contains(M::COMMAND) || m.contains(M::CONTROL);
        e.scope.foci().into_iter().all(|focus| {
            WindowsKeyRoute::command(e.binding.key, ctrl, m.contains(M::OPTION), m.contains(M::SHIFT), focus, self)
                == Some(e.command)
        })
    }

    /// The map the running app uses (preset + the user's `sq.keymap` diff). The app sets it at launch and after every
    /// edit so tooltips and hints that default to it never show a stale key. Tests keep the Premiere default.
    pub fn current() -> CommandMap {
        match CURRENT.lock() {
            Ok(guard) => guard.clone().unwrap_or_else(Self::premiere_default),
            Err(_) => Self::premiere_default(),
        }
    }

    /// Runs `f` on the running map without copying it (labels ask on every frame).
    pub fn with_current<R>(f: impl FnOnce(&CommandMap) -> R) -> R {
        match CURRENT.lock() {
            Ok(guard) => match guard.as_ref() {
                Some(map) => f(map),
                None => f(&Self::premiere_default()),
            },
            Err(_) => f(&Self::premiere_default()),
        }
    }

    /// Makes `map` the running map.
    pub fn set_current(map: CommandMap) {
        if let Ok(mut guard) = CURRENT.lock() {
            *guard = Some(map);
        }
    }

    /// Sequence Studio's own default set (docs/KEYMAP.md): the Premiere set with the changes the maintainer's workflow asks for.
    /// Written as a diff over Premiere so the two sets cannot drift apart.
    pub fn sq_default() -> CommandMap {
        Self::sq_default_for(sq_os::Platform::current())
    }

    /// [`CommandMap::sq_default`] as `platform` binds it (only the Quick Apply key differs between Mac and the rest).
    pub fn sq_default_for(platform: sq_os::Platform) -> CommandMap {
        static MAC: OnceLock<CommandMap> = OnceLock::new();
        static OTHER: OnceLock<CommandMap> = OnceLock::new();
        let cell = if platform.command_is_cmd_key() { &MAC } else { &OTHER };
        cell.get_or_init(|| {
            let t = |k: M| KeyBinding::new(Key::Char('t'), k);
            let timeline = CommandScope::Timeline;
            let program = CommandScope::Program;
            let trim_mode = EditorCommand::ToggleTrimMode;
            Keymap::apply(
                &[
                    // Q / E ripple-trim the previous / next edit to the playhead (Premiere: Q / W). Extend Edit moves from E to W.
                    KeymapOverride::new(
                        timeline,
                        &KeyBinding::new(Key::Char('e'), M::EMPTY),
                        Some(&EditorCommand::RippleTrimNext),
                    ),
                    KeymapOverride::new(
                        timeline,
                        &KeyBinding::new(Key::Char('w'), M::EMPTY),
                        Some(&EditorCommand::ExtendEdit),
                    ),
                    // Shift+T stays Keyword at Playhead (our key since N5); Trim mode moves to Ctrl+Shift+T.
                    KeymapOverride::new(timeline, &t(M::SHIFT), None),
                    KeymapOverride::new(program, &t(M::SHIFT), None),
                    KeymapOverride::new(CommandScope::Global, &t(M::SHIFT), Some(&EditorCommand::KeywordAtPlayhead)),
                    KeymapOverride::new(timeline, &t(M::CONTROL | M::SHIFT), Some(&trim_mode)),
                    KeymapOverride::new(program, &t(M::CONTROL | M::SHIFT), Some(&trim_mode)),
                ],
                &Self::premiere_default_for(platform),
            )
        })
        .clone()
    }

    /// The Premiere defaults (docs/UX.md section 3).
    pub fn premiere_default() -> CommandMap {
        Self::premiere_default_for(sq_os::Platform::current())
    }

    /// [`CommandMap::premiere_default`] as `platform` binds it.
    pub fn premiere_default_for(platform: sq_os::Platform) -> CommandMap {
        static MAC: OnceLock<CommandMap> = OnceLock::new();
        static OTHER: OnceLock<CommandMap> = OnceLock::new();
        let cell = if platform.command_is_cmd_key() { &MAC } else { &OTHER };
        cell.get_or_init(|| build_premiere_default(platform)).clone()
    }
}

/// The running map; `None` until the app sets one (then the Premiere default).
static CURRENT: Mutex<Option<CommandMap>> = Mutex::new(None);

/// The modifier of the Quick Apply key. Option+Space on the Mac; Alt+Space belongs to the window system menu on Windows and to
/// KRunner on KDE, so Windows and Linux use Ctrl+Space (Ctrl is `COMMAND` there; Ctrl+Space bound nothing in the map).
pub fn quick_apply_modifier(platform: sq_os::Platform) -> M {
    if platform.command_is_cmd_key() { M::OPTION } else { M::COMMAND }
}

/// The digit key `n` (1...9).
fn digit(n: i64) -> Key {
    Key::Char(char::from_digit(n as u32, 10).unwrap_or('0'))
}

fn build_premiere_default(platform: sq_os::Platform) -> CommandMap {
    let mut e: Vec<Entry> = Vec::new();
    let mut add = |scope: CommandScope, key: Key, modifiers: M, command: EditorCommand| {
        e.push(Entry { scope, binding: KeyBinding::new(key, modifiers), command });
    };
    let g = CommandScope::Global;
    let t = CommandScope::Timeline;

    // Transport
    add(g, Key::Char('j'), M::EMPTY, EditorCommand::ShuttleReverse);
    add(g, Key::Char('k'), M::EMPTY, EditorCommand::ShuttleStop);
    add(g, Key::Char('l'), M::EMPTY, EditorCommand::ShuttleForward);
    add(g, Key::Space, M::EMPTY, EditorCommand::PlayPause);
    add(g, Key::Char('j'), M::SHIFT, EditorCommand::ShuttleSlowReverse);
    add(g, Key::Char('l'), M::SHIFT, EditorCommand::ShuttleSlowForward);
    add(g, Key::Left, M::EMPTY, EditorCommand::StepBackward);
    add(g, Key::Right, M::EMPTY, EditorCommand::StepForward);
    add(g, Key::Left, M::SHIFT, EditorCommand::StepBackward5);
    add(g, Key::Right, M::SHIFT, EditorCommand::StepForward5);
    add(g, Key::Home, M::EMPTY, EditorCommand::GoToStart);
    add(g, Key::End, M::EMPTY, EditorCommand::GoToEnd);
    // Marking
    add(g, Key::Char('i'), M::EMPTY, EditorCommand::MarkIn);
    add(g, Key::Char('o'), M::EMPTY, EditorCommand::MarkOut);
    add(g, Key::Char('i'), M::SHIFT, EditorCommand::GoToIn);
    add(g, Key::Char('o'), M::SHIFT, EditorCommand::GoToOut);
    add(g, Key::Char('x'), M::EMPTY, EditorCommand::MarkClip);
    add(g, Key::Char('x'), M::OPTION, EditorCommand::ClearInOut);
    add(g, Key::Char('i'), M::OPTION, EditorCommand::ClearIn);
    add(g, Key::Char('o'), M::OPTION, EditorCommand::ClearOut);
    add(g, Key::Space, M::CONTROL, EditorCommand::PlayToOut); // Premiere: Play from Playhead to Out
    add(g, Key::Space, M::CONTROL | M::SHIFT, EditorCommand::PlayFromStart); // Play from Start; Ctrl+Space (to Out) and Shift+Space (with rolls) stay
    add(g, Key::Space, M::SHIFT, EditorCommand::PlayInToOutRoll);
    add(g, Key::Char('k'), M::SHIFT, EditorCommand::PlayAround);
    add(g, Key::Char('l'), M::CONTROL, EditorCommand::ToggleLoop);
    add(g, Key::Char('e'), M::SHIFT, EditorCommand::ExportFrame);
    add(g, Key::Char('/'), M::COMMAND, EditorCommand::NewBin); // File > Bin (Premiere); Cmd+B in the Project panel below
    add(g, Key::Char('e'), M::COMMAND | M::SHIFT, EditorCommand::EnableClip); // Premiere: Clip > Enable. (Export Frame is Shift+E only.)
    add(g, Key::Char('/'), M::COMMAND | M::SHIFT, EditorCommand::Duplicate);
    add(g, Key::Char('g'), M::COMMAND, EditorCommand::Group);
    add(g, Key::Char('g'), M::COMMAND | M::SHIFT, EditorCommand::Ungroup); // Premiere: Clip > Group / Ungroup
    // Premiere's selection Group under our name (Cmd+G stays the layer Group); Make Subclip and Edit Original keep Premiere's keys.
    add(g, Key::Char('g'), M::COMMAND | M::OPTION, EditorCommand::Bundle);
    add(g, Key::Char('g'), M::COMMAND | M::OPTION | M::SHIFT, EditorCommand::Unbundle);
    add(g, Key::Char('g'), M::OPTION, EditorCommand::Combine); // Final Cut's compound clip key; Alt+G on Windows and Linux
    add(g, Key::Char('u'), M::COMMAND, EditorCommand::MakeSubclip);
    add(g, Key::Char('e'), M::COMMAND, EditorCommand::EditOriginal);
    add(g, Key::Char('t'), M::COMMAND | M::OPTION, EditorCommand::SaveAsTemplate); // Save the selected title layers as a template
    add(g, Key::Char(';'), M::EMPTY, EditorCommand::Lift);
    add(g, Key::Char('\''), M::EMPTY, EditorCommand::Extract);
    add(g, Key::Char(','), M::EMPTY, EditorCommand::Insert);
    add(g, Key::Char('.'), M::EMPTY, EditorCommand::Overwrite);
    add(g, Key::Char('m'), M::EMPTY, EditorCommand::AddMarker);
    add(g, Key::Char('m'), M::OPTION, EditorCommand::ClearMarker);
    add(g, Key::Char('m'), M::CONTROL | M::OPTION, EditorCommand::ClearAllMarkers); // Premiere: Clear Selected / All Markers (Cmd+Opt+M stays Quick Export)
    add(g, Key::Char('p'), M::SHIFT, EditorCommand::TogglePunchIn); // W8.2: static punch-in on/off for the selected clips
    // N5 Keyword at Playhead (transcript word under the playhead -> big text clip) has no key here: Premiere's Shift+T is
    // Trim mode. The SQ set keeps Shift+T for the keyword (see `sqDefault`).
    add(g, Key::Char('t'), M::COMMAND, EditorCommand::AddTitle); // Premiere's legacy New Title key: two lines + emoji, animated in
    add(g, Key::Char('c'), M::COMMAND | M::OPTION, EditorCommand::AutoCaptions); // transcribe the sequence + create captions in one go
    // Keyframe easing for the selected keyframes in Effect Controls (After Effects keys; Premiere has none). Needs fn on most Macs.
    add(g, Key::Function(9), M::EMPTY, EditorCommand::EasyEase);
    add(g, Key::Function(9), M::SHIFT, EditorCommand::EaseIn);
    add(g, Key::Function(9), M::COMMAND | M::SHIFT, EditorCommand::EaseOut);
    add(g, Key::Char('s'), M::SHIFT, EditorCommand::ToggleAudioScrubbing);
    add(g, Key::Char('d'), M::COMMAND, EditorCommand::ApplyVideoTransition);
    add(g, Key::Char('d'), M::COMMAND | M::SHIFT, EditorCommand::ApplyAudioTransition);
    add(g, Key::Char('d'), M::SHIFT, EditorCommand::ApplyDefaultTransitions);
    add(g, Key::Char('m'), M::SHIFT, EditorCommand::NextMarker);
    add(g, Key::Char('m'), M::COMMAND | M::SHIFT, EditorCommand::PreviousMarker);
    add(g, Key::Char('m'), M::OPTION | M::SHIFT, EditorCommand::NextWeakTracking); // tracked Magic mask: next weak stretch (confidence strip)
    add(g, Key::Char('/'), M::EMPTY, EditorCommand::MarkSelection);
    // F7.16 Angles clip: 1-9 switch the angle while the Timeline or the Program monitor has focus (other panels keep
    // the digits for typing and type-select).
    for n in 1..=9 {
        for scope in [t, CommandScope::Program] {
            add(scope, digit(n), M::EMPTY, EditorCommand::SwitchAngle(n));
        }
    }
    // Tools
    add(g, Key::Char('v'), M::EMPTY, EditorCommand::Tool(EditorTool::Selection));
    add(g, Key::Char('a'), M::EMPTY, EditorCommand::Tool(EditorTool::TrackForward));
    add(g, Key::Char('a'), M::SHIFT, EditorCommand::Tool(EditorTool::TrackBackward));
    add(g, Key::Char('b'), M::EMPTY, EditorCommand::Tool(EditorTool::Ripple));
    add(g, Key::Char('n'), M::EMPTY, EditorCommand::Tool(EditorTool::Rolling));
    add(g, Key::Char('y'), M::EMPTY, EditorCommand::Tool(EditorTool::Slip));
    add(g, Key::Char('u'), M::EMPTY, EditorCommand::Tool(EditorTool::Slide));
    add(g, Key::Char('c'), M::EMPTY, EditorCommand::Tool(EditorTool::Razor));
    add(g, Key::Char('h'), M::EMPTY, EditorCommand::Tool(EditorTool::Hand));
    add(g, Key::Char('z'), M::EMPTY, EditorCommand::Tool(EditorTool::Zoom));
    add(g, Key::Char('t'), M::EMPTY, EditorCommand::Tool(EditorTool::Type));
    add(g, Key::Char('r'), M::EMPTY, EditorCommand::Tool(EditorTool::RateStretch));
    // Create tool modes. R, O, L and P alone are Stretch, Mark Out, Shuttle and Mask: the shapes take Option+Shift.
    add(g, Key::Char('r'), M::OPTION | M::SHIFT, EditorCommand::Tool(EditorTool::Rectangle));
    add(g, Key::Char('e'), M::OPTION | M::SHIFT, EditorCommand::Tool(EditorTool::Ellipse));
    add(g, Key::Char('l'), M::OPTION | M::SHIFT, EditorCommand::Tool(EditorTool::Line));
    add(g, Key::Char('d'), M::OPTION | M::SHIFT, EditorCommand::Tool(EditorTool::Draw));
    add(g, Key::Char('p'), M::EMPTY, EditorCommand::Tool(EditorTool::Mask)); // O is Mark Out; P = Premiere's Pen key, our pen lives in the Mask tool
    // Clipboard / history / file
    add(g, Key::Char('c'), M::COMMAND, EditorCommand::Copy);
    add(g, Key::Char('x'), M::COMMAND, EditorCommand::Cut);
    add(g, Key::Char('v'), M::COMMAND, EditorCommand::Paste);
    add(g, Key::Char('v'), M::COMMAND | M::OPTION, EditorCommand::PasteAttributes);
    add(g, Key::Char('v'), M::COMMAND | M::SHIFT, EditorCommand::PasteInsert);
    add(g, Key::Char('z'), M::COMMAND, EditorCommand::Undo);
    add(g, Key::Char('z'), M::COMMAND | M::SHIFT, EditorCommand::Redo);
    add(g, Key::Char('i'), M::COMMAND, EditorCommand::ImportMedia);
    add(g, Key::Char('n'), M::COMMAND, EditorCommand::NewSequence);
    add(g, Key::Char('s'), M::COMMAND, EditorCommand::Save);
    add(g, Key::Char('m'), M::COMMAND, EditorCommand::Export);
    add(g, Key::Char('m'), M::COMMAND | M::OPTION, EditorCommand::QuickExport);
    add(g, Key::Char('s'), M::COMMAND | M::SHIFT, EditorCommand::SaveAs);
    add(g, Key::Char('s'), M::COMMAND | M::OPTION, EditorCommand::SaveCopy);
    add(g, Key::Char('o'), M::COMMAND, EditorCommand::OpenProject);
    add(g, Key::Char('n'), M::COMMAND | M::OPTION, EditorCommand::NewProject);
    add(g, Key::Char('w'), M::COMMAND | M::SHIFT, EditorCommand::CloseProject);
    // UI scale (View > Larger / Smaller / Actual Size): Cmd+= / - / 0 are track height and audio targets in the timeline
    add(g, Key::Char('='), M::COMMAND | M::OPTION, EditorCommand::UiScaleLarger);
    add(g, Key::Char('-'), M::COMMAND | M::OPTION, EditorCommand::UiScaleSmaller);
    add(g, Key::Char('0'), M::COMMAND | M::OPTION, EditorCommand::UiScaleReset);
    add(g, Key::Char('k'), M::COMMAND | M::OPTION, EditorCommand::KeyboardShortcuts);
    add(g, Key::Char(','), M::COMMAND, EditorCommand::Preferences);
    // Panels (Premiere set; 6 maps to the Audio Meter, our only audio-side panel, never to Library; 8 Text/Captions,
    // 9 Graphics: Premiere's Media Browser and Audio Clip Mixer have no panel here, so those keys carry our own panels)
    let panels = [
        PanelID::Project,
        PanelID::SourceMonitor,
        PanelID::Timeline,
        PanelID::ProgramMonitor,
        PanelID::EffectControls,
        PanelID::AudioMeter,
        PanelID::Effects,
        PanelID::Text,
        PanelID::Graphics,
    ];
    for (i, p) in panels.into_iter().enumerate() {
        add(g, digit(i as i64 + 1), M::SHIFT, EditorCommand::FocusPanel(p));
    }
    add(g, Key::Char('0'), M::SHIFT, EditorCommand::FocusPanel(PanelID::ColorInspector)); // SH-18: Color follows the number row
    // Shift+, nudges 10 frames left: selected keyframes when Effect Controls has focus, clips otherwise (Shift+. is Place on Top).
    add(g, Key::Char(','), M::SHIFT, EditorCommand::NudgeLeft10);
    add(g, Key::Char('`'), M::EMPTY, EditorCommand::MaximizePanel);
    add(g, Key::Char('`'), M::SHIFT, EditorCommand::MaximizeActivePanel);
    add(g, Key::Char('0'), M::OPTION | M::SHIFT, EditorCommand::ResetLayout);
    // Premiere: Ctrl+Shift+. and ,; Ctrl+Shift+. is Paste Attached backtimed here, so the pair sits on Ctrl+Option
    add(g, Key::Char('.'), M::CONTROL | M::OPTION, EditorCommand::SelectNextPanel);
    add(g, Key::Char(','), M::CONTROL | M::OPTION, EditorCommand::SelectPreviousPanel);
    add(g, Key::Space, quick_apply_modifier(platform), EditorCommand::QuickApply);
    // Timeline
    add(t, Key::Up, M::EMPTY, EditorCommand::PreviousEditPoint);
    add(t, Key::Down, M::EMPTY, EditorCommand::NextEditPoint);
    add(t, Key::Char('k'), M::COMMAND, EditorCommand::AddEdit);
    add(t, Key::Char('k'), M::COMMAND | M::SHIFT, EditorCommand::AddEditAllTracks);
    add(t, Key::Char('k'), M::CONTROL, EditorCommand::JumpCutAlternate); // W8.1, next to Add Edit (Ctrl+Option+K is Add Keyframe)
    add(t, Key::Char('a'), M::CONTROL | M::SHIFT, EditorCommand::SplitEditAudio);
    add(t, Key::Char('v'), M::CONTROL | M::SHIFT, EditorCommand::SplitEditVideo); // J / L cut
    // Fast cutting (Q-CUT1/2): none of these keys is used in the Premiere set.
    add(g, Key::Char('x'), M::SHIFT, EditorCommand::CutOut);
    add(g, Key::Char('.'), M::SHIFT, EditorCommand::PlaceOnTop); // Q-BRL1: b-roll in one key (Resolve F12, which is a media key on a Mac)
    add(t, Key::Char('j'), M::OPTION, EditorCommand::JCut);
    add(t, Key::Char('l'), M::OPTION, EditorCommand::LCut);
    add(t, Key::Delete, M::CONTROL, EditorCommand::CloseGapAtPlayhead);
    add(t, Key::Char('q'), M::EMPTY, EditorCommand::RippleTrimPrevious);
    add(t, Key::Char('w'), M::EMPTY, EditorCommand::RippleTrimNext);
    add(t, Key::Char('e'), M::EMPTY, EditorCommand::ExtendEdit);
    add(t, Key::Char('q'), M::SHIFT, EditorCommand::RollTrimPrevious);
    add(t, Key::Char('w'), M::SHIFT, EditorCommand::RollTrimNext);
    add(t, Key::Char('q'), M::OPTION, EditorCommand::TrimPrevious);
    add(t, Key::Char('w'), M::OPTION, EditorCommand::TrimNext);
    // Nudge the audio / video half of the nearest cut one frame (J / L cut fine tuning). Opt+Left/Right is Trim 1 frame,
    // so these take Ctrl+Opt (audio) and Ctrl+Opt+Shift (video); Ctrl+Opt+Left/Right was free in both sets.
    add(t, Key::Left, M::CONTROL | M::OPTION, EditorCommand::NudgeAudioEditLeft);
    add(t, Key::Right, M::CONTROL | M::OPTION, EditorCommand::NudgeAudioEditRight);
    add(t, Key::Left, M::CONTROL | M::OPTION | M::SHIFT, EditorCommand::NudgeVideoEditLeft);
    add(t, Key::Right, M::CONTROL | M::OPTION | M::SHIFT, EditorCommand::NudgeVideoEditRight);
    add(t, Key::Char('t'), M::CONTROL, EditorCommand::ToggleTrimType);
    add(CommandScope::Program, Key::Char('t'), M::CONTROL, EditorCommand::ToggleTrimType); // Trim mode keeps the keys on the Program monitor too
    add(CommandScope::Program, Key::Char('t'), M::SHIFT, EditorCommand::ToggleTrimMode); // Premiere: Trim Edit
    add(t, Key::Char('t'), M::SHIFT, EditorCommand::ToggleTrimMode); // Premiere: Trim Edit (the SQ set moves it to Ctrl+Shift+T)
    add(t, Key::Up, M::OPTION, EditorCommand::MoveSelectionUp);
    add(t, Key::Down, M::OPTION, EditorCommand::MoveSelectionDown);
    // Premiere parity (2026-10): select the next / previous clip on the track, jump to the selected clip's ends, slide by key.
    add(t, Key::Down, M::COMMAND, EditorCommand::SelectNextClip);
    add(t, Key::Up, M::COMMAND, EditorCommand::SelectPreviousClip);
    add(t, Key::Home, M::SHIFT, EditorCommand::GoToSelectedClipStart);
    add(t, Key::End, M::SHIFT, EditorCommand::GoToSelectedClipEnd);
    add(t, Key::Char(','), M::OPTION, EditorCommand::SlideLeft);
    add(t, Key::Char('.'), M::OPTION, EditorCommand::SlideRight);
    add(t, Key::Char(','), M::OPTION | M::SHIFT, EditorCommand::SlideLeft5);
    add(t, Key::Char('.'), M::OPTION | M::SHIFT, EditorCommand::SlideRight5);
    add(t, Key::Left, M::COMMAND | M::OPTION, EditorCommand::SlipLeft);
    add(t, Key::Right, M::COMMAND | M::OPTION, EditorCommand::SlipRight);
    add(t, Key::Left, M::COMMAND | M::OPTION | M::SHIFT, EditorCommand::SlipLeft5);
    add(t, Key::Right, M::COMMAND | M::OPTION | M::SHIFT, EditorCommand::SlipRight5);
    add(t, Key::Delete, M::EMPTY, EditorCommand::Delete);
    add(t, Key::Delete, M::SHIFT, EditorCommand::RippleDelete);
    add(t, Key::Char('s'), M::EMPTY, EditorCommand::ToggleSnapping);
    add(t, Key::Char('g'), M::SHIFT, EditorCommand::ToggleMagnetic); // Fast Cut on/off (was Glue): Shift+G was free in both sets
    add(t, Key::Char('e'), M::CONTROL, EditorCommand::AppendToMainTrack);
    add(t, Key::Char('w'), M::CONTROL, EditorCommand::InsertSpacer); // Fast Cut verbs
    add(g, Key::Char('v'), M::OPTION, EditorCommand::PasteAttached);
    add(g, Key::Char('.'), M::CONTROL | M::SHIFT, EditorCommand::AttachBacktimed); // Fast Cut: Paste Attached, Place on Top backtimed
    add(t, Key::Up, M::COMMAND | M::OPTION, EditorCommand::LiftOffMainTrack);
    add(t, Key::Down, M::COMMAND | M::OPTION, EditorCommand::PutOnMainTrack);
    // Fast Cut storylines: Cmd+G is Group, so Create Storyline takes Ctrl+G; Position tool Shift+V (P is Mask).
    add(t, Key::Char('g'), M::CONTROL, EditorCommand::CreateStoryline);
    add(t, Key::Delete, M::CONTROL | M::SHIFT, EditorCommand::StorylineRippleDelete);
    add(t, Key::Left, M::CONTROL | M::COMMAND, EditorCommand::MoveClipLeft);
    add(t, Key::Right, M::CONTROL | M::COMMAND, EditorCommand::MoveClipRight);
    add(t, Key::Delete, M::COMMAND | M::OPTION, EditorCommand::DeleteSelectionOnly);
    add(g, Key::Char('v'), M::SHIFT, EditorCommand::Tool(EditorTool::Position));
    add(t, Key::Char('a'), M::COMMAND, EditorCommand::SelectAll);
    add(t, Key::Char('a'), M::COMMAND | M::SHIFT, EditorCommand::DeselectAll);
    add(t, Key::Char('d'), M::EMPTY, EditorCommand::SelectClipAtPlayhead);
    add(t, Key::Up, M::SHIFT, EditorCommand::PreviousEditPointAnyTrack);
    add(t, Key::Down, M::SHIFT, EditorCommand::NextEditPointAnyTrack);
    // Nudge the selected clips (Cmd+arrows) or trim the selected edit (Opt+Shift+arrows; Opt+arrows is one frame, see AppController).
    add(t, Key::Left, M::COMMAND, EditorCommand::NudgeLeft);
    add(t, Key::Right, M::COMMAND, EditorCommand::NudgeRight);
    add(t, Key::Left, M::COMMAND | M::SHIFT, EditorCommand::NudgeLeft10);
    add(t, Key::Right, M::COMMAND | M::SHIFT, EditorCommand::NudgeRight10);
    add(t, Key::Left, M::OPTION | M::SHIFT, EditorCommand::TrimBackward5);
    add(t, Key::Right, M::OPTION | M::SHIFT, EditorCommand::TrimForward5);
    add(t, Key::Char('l'), M::COMMAND, EditorCommand::Link);
    add(t, Key::Char('m'), M::CONTROL | M::SHIFT, EditorCommand::MuteTracks);
    add(t, Key::Char('s'), M::CONTROL | M::OPTION, EditorCommand::Solo);
    add(t, Key::Char('d'), M::CONTROL | M::SHIFT, EditorCommand::DetachAudio);
    add(t, Key::Char('l'), M::CONTROL | M::OPTION, EditorCommand::MatchLoudness);
    add(t, Key::Char('d'), M::CONTROL | M::OPTION, EditorCommand::AutoDuck); // were unbound
    add(t, Key::Char('g'), M::EMPTY, EditorCommand::AudioGain);
    add(t, Key::Char('['), M::EMPTY, EditorCommand::AudioGainDown);
    add(t, Key::Char(']'), M::EMPTY, EditorCommand::AudioGainUp);
    add(t, Key::Char('['), M::SHIFT, EditorCommand::AudioGainDown6);
    add(t, Key::Char(']'), M::SHIFT, EditorCommand::AudioGainUp6);
    add(t, Key::Char('r'), M::COMMAND, EditorCommand::SpeedDuration);
    add(t, Key::Char('r'), M::CONTROL | M::OPTION, EditorCommand::ReverseClip); // FCP and Resolve ship no key for it; free in both sets
    add(t, Key::Char('f'), M::EMPTY, EditorCommand::MatchFrame);
    add(t, Key::Char('r'), M::SHIFT, EditorCommand::ReverseMatchFrame);
    add(t, Key::Char('='), M::EMPTY, EditorCommand::ZoomIn);
    add(t, Key::Char('-'), M::EMPTY, EditorCommand::ZoomOut);
    add(t, Key::Char('\\'), M::EMPTY, EditorCommand::ZoomFit);
    // Track heights: modifier combinations only, so plain +/-/\ stay timeline zoom.
    add(t, Key::Char('='), M::COMMAND, EditorCommand::VideoTracksTaller);
    add(t, Key::Char('-'), M::COMMAND, EditorCommand::VideoTracksShorter);
    add(t, Key::Char('='), M::OPTION, EditorCommand::AudioTracksTaller);
    add(t, Key::Char('-'), M::OPTION, EditorCommand::AudioTracksShorter);
    add(t, Key::Char('='), M::CONTROL, EditorCommand::AllTracksTaller);
    add(t, Key::Char('-'), M::CONTROL, EditorCommand::AllTracksShorter);
    add(t, Key::Char('\\'), M::CONTROL, EditorCommand::ToggleFitTracks);
    add(t, Key::Char('='), M::SHIFT, EditorCommand::ExpandAllTracks);
    add(t, Key::Char('-'), M::SHIFT, EditorCommand::MinimizeAllTracks);
    // Trim Backward/Forward 1 frame (Premiere: Opt+Left/Right), Ripple Delete is Shift+Delete only.
    add(t, Key::Left, M::OPTION, EditorCommand::TrimBackward);
    add(t, Key::Right, M::OPTION, EditorCommand::TrimForward);
    // Play In to Out (Option+K on the Mac; bound per panel bound per panel).
    for scope in [CommandScope::Program, CommandScope::Source, CommandScope::Project, CommandScope::Timeline] {
        add(scope, Key::Char('k'), M::OPTION, EditorCommand::PlayInToOut);
    }
    // Go to Timecode (FCP: Ctrl+P) and Toggle Video / Audio Targets (Cmd+9 / Cmd+0): free in both sets.
    add(g, Key::Char('p'), M::CONTROL, EditorCommand::GoToTimecode);
    add(t, Key::Char('9'), M::COMMAND, EditorCommand::ToggleVideoTargets);
    add(t, Key::Char('0'), M::COMMAND, EditorCommand::ToggleAudioTargets);
    // Add Keyframe (Ctrl+Option+K): the property last used in Controls. Option+K stays Play In to Out (a menu key shows on one item only).
    for scope in [CommandScope::Timeline, CommandScope::EffectControls] {
        add(scope, Key::Char('k'), M::CONTROL | M::OPTION, EditorCommand::AddKeyframe);
    }
    // Keyframe jumps, Linked Selection and Add Track (audit A8): Ctrl+[ / Ctrl+] step between keyframes of the selected
    // clips; Ctrl+Shift+L toggles Linked Selection; Ctrl+Option+V / A add a video / audio track. All free in both sets.
    add(g, Key::Char('['), M::CONTROL, EditorCommand::PreviousKeyframe);
    add(g, Key::Char(']'), M::CONTROL, EditorCommand::NextKeyframe);
    add(t, Key::Char('l'), M::CONTROL | M::SHIFT, EditorCommand::ToggleLinkedSelection);
    // Select Layer Above / Below in the open Graphic (Option+] / Option+[; the Final Cut set keeps its trim keys there).
    for scope in [CommandScope::Timeline, CommandScope::Program] {
        add(scope, Key::Char(']'), M::OPTION, EditorCommand::SelectLayerAbove);
        add(scope, Key::Char('['), M::OPTION, EditorCommand::SelectLayerBelow);
    }
    // Track targeting and lock by key, fades, frame hold, Join Cuts, Paste to Targeted Track (all free in both sets).
    for n in 1..=9 {
        let c = digit(n);
        add(t, c, M::CONTROL, EditorCommand::ToggleTrackTarget(TrackKind::Video, n));
        add(t, c, M::CONTROL | M::OPTION, EditorCommand::ToggleTrackTarget(TrackKind::Audio, n));
    }
    add(t, Key::Char('k'), M::CONTROL | M::SHIFT, EditorCommand::ToggleLockOfTargets);
    add(t, Key::Char('['), M::CONTROL | M::OPTION, EditorCommand::VideoFadeIn);
    add(t, Key::Char(']'), M::CONTROL | M::OPTION, EditorCommand::VideoFadeOut);
    add(t, Key::Char('h'), M::CONTROL | M::SHIFT, EditorCommand::AddFrameHold);
    add(t, Key::Char('j'), M::CONTROL | M::OPTION, EditorCommand::JoinCuts);
    add(t, Key::Char('v'), M::COMMAND | M::OPTION | M::SHIFT, EditorCommand::PasteToTargets);
    add(t, Key::Char('v'), M::CONTROL | M::OPTION, EditorCommand::AddVideoTrack);
    add(t, Key::Char('a'), M::CONTROL | M::OPTION, EditorCommand::AddAudioTrack);
    add(t, Key::Delete, M::CONTROL | M::OPTION, EditorCommand::DeleteTrack);
    // Replace With Clip (from Source / from Project) and J / L Cut by Offset: three-modifier keys, free in both sets.
    add(t, Key::Char('r'), M::CONTROL | M::OPTION | M::SHIFT, EditorCommand::ReplaceClipFromSource);
    add(t, Key::Char('p'), M::CONTROL | M::OPTION | M::SHIFT, EditorCommand::ReplaceClipFromProject);
    add(t, Key::Char('j'), M::CONTROL | M::OPTION | M::SHIFT, EditorCommand::JCutByOffset);
    add(t, Key::Char('l'), M::CONTROL | M::OPTION | M::SHIFT, EditorCommand::LCutByOffset);
    // Program monitor
    add(CommandScope::Program, Key::Up, M::EMPTY, EditorCommand::PreviousEditPoint);
    add(CommandScope::Program, Key::Down, M::EMPTY, EditorCommand::NextEditPoint);
    add(CommandScope::Program, Key::Char('f'), M::EMPTY, EditorCommand::MatchFrame);
    add(CommandScope::Program, Key::Char('r'), M::SHIFT, EditorCommand::ReverseMatchFrame);
    // Project panel
    add(CommandScope::Project, Key::Delete, M::EMPTY, EditorCommand::DeleteProjectItems);
    add(CommandScope::Project, Key::Char('b'), M::COMMAND, EditorCommand::NewBin);
    add(CommandScope::Project, Key::Char('p'), M::COMMAND, EditorCommand::SetPosterFrame);
    add(CommandScope::Project, Key::Char('p'), M::OPTION, EditorCommand::ClearPosterFrame);
    add(CommandScope::Project, Key::PageUp, M::COMMAND, EditorCommand::ProjectListView);
    add(CommandScope::Project, Key::PageDown, M::COMMAND, EditorCommand::ProjectIconView);
    // Premiere uses Shift+[ / Shift+], which the Timeline already has for Audio Gain 6 dB (menu keys must be unique), so Cmd+[ / Cmd+] here.
    add(CommandScope::Project, Key::Char('['), M::COMMAND, EditorCommand::ProjectThumbnailSmaller);
    add(CommandScope::Project, Key::Char(']'), M::COMMAND, EditorCommand::ProjectThumbnailLarger);
    add(CommandScope::Project, Key::Char('h'), M::SHIFT, EditorCommand::ToggleHoverScrub);
    add(CommandScope::Project, Key::Char('f'), M::COMMAND, EditorCommand::Find);
    CommandMap::new(e)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command_support::CommandSupport;
    use crate::menu_keys::MenuKeys;
    use crate::menu_spec::EditorMenus;

    fn maps() -> Vec<(&'static str, CommandMap)> {
        vec![("premiere", CommandMap::premiere_default()), ("sq", CommandMap::sq_default())]
    }

    #[test]
    fn option_g_runs_combine_in_both_key_sets() {
        for (name, m) in maps() {
            assert_eq!(m.command_for(&ch('g', M::OPTION), None), Some(EditorCommand::Combine), "{name}");
            assert_eq!(m.binding_for(&EditorCommand::Combine), Some(ch('g', M::OPTION)), "{name}");
        }
    }

    fn ch(c: char, m: M) -> KeyBinding {
        KeyBinding::new(Key::Char(c), m)
    }

    #[test]
    fn digits_switch_angles_only_in_timeline_and_program() {
        let map = CommandMap::premiere_default();
        for n in 1..=9 {
            let b = ch(char::from_digit(n as u32, 10).unwrap_or('0'), M::EMPTY);
            assert_eq!(map.command_for(&b, Some(PanelID::Timeline)), Some(EditorCommand::SwitchAngle(n)));
            assert_eq!(map.command_for(&b, Some(PanelID::ProgramMonitor)), Some(EditorCommand::SwitchAngle(n)));
            assert_ne!(map.command_for(&b, Some(PanelID::Effects)), Some(EditorCommand::SwitchAngle(n)));
            assert_ne!(map.command_for(&b, None), Some(EditorCommand::SwitchAngle(n)));
        }
        assert!(map.duplicates().is_empty());
    }

    #[test]
    fn close_project_is_a_shell_command_in_the_file_menu_with_command_shift_w() {
        assert!(EditorMenus::file().commands().contains(&EditorCommand::CloseProject));
        assert!(CommandSupport::is_shell_command(&EditorCommand::CloseProject));
        let map = CommandMap::premiere_default();
        assert_eq!(map.binding_for(&EditorCommand::CloseProject).map(|b| b.modifiers), Some(M::COMMAND | M::SHIFT));
        assert!(map.duplicates().is_empty());
        assert!(EditorMenus::clip().commands().contains(&EditorCommand::SetPosterFrame));
        assert!(map.binding_for(&EditorCommand::SetPosterFrame).is_some());
    }

    #[test]
    fn premiere_set_uses_shift_t_for_trim_mode() {
        let shift_t = ch('t', M::SHIFT);
        let m = CommandMap::premiere_default();
        assert!(m.duplicates().is_empty());
        assert_eq!(m.command_for(&shift_t, Some(PanelID::Timeline)), Some(EditorCommand::ToggleTrimMode));
        assert_eq!(m.command_for(&shift_t, Some(PanelID::ProgramMonitor)), Some(EditorCommand::ToggleTrimMode));
        assert!(!m.entries.iter().any(|e| e.command == EditorCommand::KeywordAtPlayhead && e.binding == shift_t));
    }

    #[test]
    fn sq_set_keeps_keyword_on_shift_t_and_trim_mode_on_ctrl_shift_t() {
        let shift_t = ch('t', M::SHIFT);
        let ctrl_shift_t = ch('t', M::CONTROL | M::SHIFT);
        let m = CommandMap::sq_default();
        assert!(m.duplicates().is_empty());
        assert_eq!(m.command_for(&shift_t, Some(PanelID::Timeline)), Some(EditorCommand::KeywordAtPlayhead));
        assert_eq!(m.command_for(&ctrl_shift_t, Some(PanelID::Timeline)), Some(EditorCommand::ToggleTrimMode));
        assert_eq!(m.command_for(&ctrl_shift_t, Some(PanelID::ProgramMonitor)), Some(EditorCommand::ToggleTrimMode));
    }

    /// The set the app starts with (`KeymapConfig::default`, Sequence Studio) matches the design kit's shortcuts.json rows:
    /// Ripple Trim Next Edit E, Extend Selected Edit W (Timeline), Trim Mode Ctrl+Shift+T, Keyword at Playhead Shift+T.
    #[test]
    fn starting_keymap_matches_the_kit_rows() {
        use crate::keymap_store::{KeymapConfig, KeymapPreset};
        let config = KeymapConfig::default();
        assert_eq!(config.preset, KeymapPreset::Sq);
        let m = config.map();
        let timeline = Some(PanelID::Timeline);
        assert_eq!(m.command_for(&ch('e', M::EMPTY), timeline), Some(EditorCommand::RippleTrimNext));
        assert_eq!(m.command_for(&ch('w', M::EMPTY), timeline), Some(EditorCommand::ExtendEdit));
        assert_eq!(m.command_for(&ch('t', M::SHIFT), timeline), Some(EditorCommand::KeywordAtPlayhead));
        assert_eq!(m.command_for(&ch('t', M::CONTROL | M::SHIFT), timeline), Some(EditorCommand::ToggleTrimMode));
    }

    /// A key a system cannot press as the command is never shown for it (every shown key must work).
    #[test]
    fn a_chord_the_pc_cannot_press_shows_no_key_but_the_mac_shows_it() {
        use sq_os::Platform;
        let pc = CommandMap::sq_default_for(Platform::Windows);
        let mac = CommandMap::sq_default_for(Platform::Mac);
        // Ctrl+Space is Quick Apply on a PC: Play to Out (Control+Space on the Mac) is menu only there.
        assert!(pc.shown_binding_for(&EditorCommand::PlayToOut, Platform::Windows).is_none());
        assert!(mac.shown_binding_for(&EditorCommand::PlayToOut, Platform::Mac).is_some());
        // Ctrl+[ is Smaller Thumbnails in the Project panel and Go to Previous Keyframe elsewhere: the Control binding runs
        // the Project command there, so only the command that owns the chord in its own panel shows it.
        assert!(pc.shown_binding_for(&EditorCommand::ProjectThumbnailSmaller, Platform::Linux).is_some());
        assert!(pc.shown_binding_for(&EditorCommand::PreviousKeyframe, Platform::Linux).is_none());
        // A plain Command chord is shown everywhere.
        assert_eq!(
            pc.shown_binding_for(&EditorCommand::Save, Platform::Windows),
            Some(KeyBinding::new(Key::Char('s'), M::COMMAND))
        );
    }

    #[test]
    fn no_duplicate_bindings_in_a_scope() {
        assert!(CommandMap::premiere_default().duplicates().is_empty());
    }

    /// A key bound twice for different commands in scopes that can be active together (global + one panel scope) is a
    /// collision unless the panel scope deliberately overrides the global one. None of the defaults does.
    #[test]
    fn panel_scopes_never_shadow_global_keys() {
        for (name, map) in maps() {
            let global: HashMap<KeyBinding, EditorCommand> = map
                .entries
                .iter()
                .filter(|e| e.scope == CommandScope::Global)
                .map(|e| (e.binding, e.command))
                .collect();
            for e in map.entries.iter().filter(|e| e.scope != CommandScope::Global) {
                if let Some(g) = global.get(&e.binding) {
                    assert_eq!(*g, e.command, "{name} {:?} {:?} shadows global {g:?}", e.scope, e.binding);
                }
            }
        }
    }

    /// Every key is reachable: the platform adapter produces a plain key (`=`, not `+`) plus modifiers.
    #[test]
    fn keys_are_key_caps_not_shifted_characters() {
        let shifted =
            ['+', '_', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '{', '}', '|', ':', '"', '<', '>', '?'];
        for e in CommandMap::premiere_default().entries {
            if let Key::Char(c) = e.binding.key {
                assert!(!shifted.contains(&c), "{:?} uses shifted character {c}", e.command);
            }
        }
    }

    #[test]
    fn every_menu_command_has_a_key_or_is_menu_only() {
        let map = CommandMap::premiere_default();
        for c in EditorMenus::all().iter().flat_map(|m| m.commands()) {
            assert!(map.binding_for(&c).is_some() || EditorMenus::menu_only().contains(&c), "{c:?}");
        }
    }

    #[test]
    fn file_and_app_shortcuts_match_premiere() {
        use EditorCommand as C;
        let map = CommandMap::premiere_default();
        let expected = [
            (ch('n', M::COMMAND), C::NewSequence),
            (ch('n', M::COMMAND | M::OPTION), C::NewProject),
            (ch('o', M::COMMAND), C::OpenProject),
            (ch('s', M::COMMAND), C::Save),
            (ch('s', M::COMMAND | M::SHIFT), C::SaveAs),
            (ch('s', M::COMMAND | M::OPTION), C::SaveCopy),
            (ch('i', M::COMMAND), C::ImportMedia),
            (ch('m', M::COMMAND), C::Export),
            (ch('k', M::COMMAND | M::OPTION), C::KeyboardShortcuts),
            (ch(',', M::COMMAND), C::Preferences),
            (ch('z', M::COMMAND), C::Undo),
            (ch('z', M::COMMAND | M::SHIFT), C::Redo),
            (ch('x', M::COMMAND), C::Cut),
            (ch('c', M::COMMAND), C::Copy),
            (ch('v', M::COMMAND), C::Paste),
            (ch('v', M::COMMAND | M::OPTION), C::PasteAttributes),
        ];
        for (binding, command) in expected {
            assert_eq!(map.command_for(&binding, None), Some(command), "{command:?}");
        }
    }

    #[test]
    fn focus_panels_follow_premiere_mapping() {
        let map = CommandMap::premiere_default();
        let shift = |c: char| ch(c, M::SHIFT);
        let focus = |c: char| map.command_for(&shift(c), None);
        assert_eq!(focus('1'), Some(EditorCommand::FocusPanel(PanelID::Project)));
        assert_eq!(focus('2'), Some(EditorCommand::FocusPanel(PanelID::SourceMonitor)));
        assert_eq!(focus('3'), Some(EditorCommand::FocusPanel(PanelID::Timeline)));
        assert_eq!(focus('4'), Some(EditorCommand::FocusPanel(PanelID::ProgramMonitor)));
        assert_eq!(focus('5'), Some(EditorCommand::FocusPanel(PanelID::EffectControls)));
        assert_eq!(focus('7'), Some(EditorCommand::FocusPanel(PanelID::Effects)));
        assert_eq!(focus('8'), Some(EditorCommand::FocusPanel(PanelID::Text)));
        assert_eq!(focus('9'), Some(EditorCommand::FocusPanel(PanelID::Graphics)));
        assert_eq!(focus('0'), Some(EditorCommand::FocusPanel(PanelID::ColorInspector)));
        assert_eq!(focus(','), Some(EditorCommand::NudgeLeft10), "Shift+, nudges 10 frames left");
        assert_eq!(map.command_for(&ch('`', M::EMPTY), None), Some(EditorCommand::MaximizePanel));
    }

    #[test]
    fn menu_order_and_placement() {
        let titles: Vec<&str> = EditorMenus::all().iter().map(|m| m.title.as_str()).collect();
        assert_eq!(titles, ["File", "Edit", "Clip", "Sequence", "Markers", "View", "Window"]);
        let markers = EditorMenus::markers().commands();
        assert!(markers.contains(&EditorCommand::MarkIn) && markers.contains(&EditorCommand::AddMarker));
        assert!(EditorMenus::sequence().commands().contains(&EditorCommand::ToggleSnapping));
        assert_eq!(EditorMenus::sequence().commands().first(), Some(&EditorCommand::SequenceSettings));
        assert!(EditorMenus::file().commands().contains(&EditorCommand::Revert));
        assert!(EditorMenus::file().commands().contains(&EditorCommand::ProjectNotes));
        assert_eq!(CommandMap::premiere_default().binding_for(&EditorCommand::ProjectNotes), None);
        assert!(CommandSupport::is_shell_command(&EditorCommand::ProjectNotes));
        // Each command sits in exactly one menu.
        let all: Vec<EditorCommand> = EditorMenus::all().iter().flat_map(|m| m.commands()).collect();
        let unique: HashSet<&EditorCommand> = all.iter().collect();
        assert_eq!(unique.len(), all.len());
    }

    /// A default key must never flash "not available yet": every command the default maps bind is wired.
    #[test]
    fn every_default_key_command_is_supported() {
        for (name, map) in maps() {
            for e in map.entries {
                assert!(CommandSupport::is_supported(&e.command), "{name} {:?} is bound but not supported", e.command);
            }
        }
    }

    /// Menu items carry one key each; two items may not show the same key.
    #[test]
    fn menu_keys_are_unique() {
        for (name, map) in maps() {
            let mut seen: HashMap<KeyBinding, EditorCommand> = HashMap::new();
            for c in menu_commands() {
                let Some(k) = map.binding_for(&c) else { continue };
                if let Some(other) = seen.get(&k).filter(|o| **o != c) {
                    panic!("{name} {k:?} is shown by {other:?} and {c:?}");
                }
                seen.insert(k, c);
            }
        }
    }

    /// A Command key owned by a menu item fires that item before the router sees it. A scoped binding of the same key
    /// for another command would be dead.
    #[test]
    fn menu_owned_keys_do_not_hide_scoped_bindings() {
        for (name, map) in maps() {
            let mut owner: HashMap<KeyBinding, EditorCommand> = HashMap::new();
            for c in menu_commands() {
                if let Some(k) = map.binding_for(&c) {
                    owner.insert(k, c);
                }
            }
            for e in map.entries.iter().filter(|e| e.binding.modifiers.contains(M::COMMAND)) {
                if let Some(o) = owner.get(&e.binding).filter(|o| **o != e.command) {
                    panic!(
                        "{name} {:?} {:?} is bound to {:?} but the menu item {o:?} fires first",
                        e.scope, e.binding, e.command
                    );
                }
            }
        }
    }

    fn menu_commands() -> Vec<EditorCommand> {
        let mut v: Vec<EditorCommand> =
            EditorMenus::all().iter().flat_map(|m| m.commands()).filter(CommandSupport::is_supported).collect();
        v.extend(MenuKeys::APP_MENU_COMMANDS);
        v.extend(EditorMenus::window_panels().iter().map(|p| EditorCommand::FocusPanel(*p)));
        v
    }

    /// Transport, marking and edit keys work the same in the monitors and the timeline.
    #[test]
    fn monitors_own_transport_keys() {
        use EditorCommand as C;
        for (name, map) in maps() {
            for focus in [PanelID::ProgramMonitor, PanelID::SourceMonitor, PanelID::Timeline] {
                let cmd = |k: Key| map.command_for(&KeyBinding::new(k, M::EMPTY), Some(focus));
                assert_eq!(cmd(Key::Space), Some(C::PlayPause), "{name} {focus:?}");
                assert_eq!(cmd(Key::Char('j')), Some(C::ShuttleReverse));
                assert_eq!(cmd(Key::Char('k')), Some(C::ShuttleStop));
                assert_eq!(cmd(Key::Char('l')), Some(C::ShuttleForward));
                assert_eq!(cmd(Key::Left), Some(C::StepBackward));
                assert_eq!(cmd(Key::Right), Some(C::StepForward));
                assert_eq!(cmd(Key::Char('i')), Some(C::MarkIn));
                assert_eq!(cmd(Key::Char('o')), Some(C::MarkOut));
                assert_eq!(cmd(Key::Char('x')), Some(C::MarkClip));
                assert_eq!(cmd(Key::Char(',')), Some(C::Insert));
                assert_eq!(cmd(Key::Char('.')), Some(C::Overwrite));
            }
        }
    }

    #[test]
    fn current_defaults_to_premiere_until_set() {
        assert_eq!(CommandMap::current().entries.len(), CommandMap::premiere_default().entries.len());
    }
}
