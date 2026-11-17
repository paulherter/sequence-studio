//! Command routing (which stage owns a command, what the edit verbs do per focused panel) and the key router.

use std::collections::BTreeMap;

use sq_core_edit::playback::{PlaybackRate, Shuttle, ShuttleAction, ShuttleKey};
use sq_uikit::command_map::CommandMap;
use sq_uikit::command_support::CommandSupport;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::focus_routing::{EditVerb, FocusedEditTarget};
use sq_uikit::key_binding::{Key, KeyEvent, KeyPhase};
use sq_uikit::panel_id::PanelID;

use super::CommandRouting;

/// The stage of the app's command execution that performs the command.
// Swift: CommandRouting.swift:12
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handler {
    Core,
    TimelineOp,
    Shell,
    EffectsLook,
}

/// Where a command goes. `focus_dependent` = the result depends on the focused panel (edit verbs, panel overrides,
/// zoom, delete); everything else is global and ignores focus.
// Swift: CommandRouting.swift:17
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route {
    // Swift: CommandRouting.swift:18
    pub handler: Handler,
    // Swift: CommandRouting.swift:19
    pub focus_dependent: bool,
}

/// What an edit verb does for a focus target.
// Swift: CommandRouting.swift:45
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditAction {
    /// The timeline's own path continues (also Effect Controls' Delete, which has its own order of targets).
    FallThrough,
    /// The panel has no such command: the key does nothing and the item is disabled. Never the timeline's clips.
    Swallow,
    EffectControls,
    DeleteProjectItems,
    PasteMedia,
    DeleteGraphicsLayers,
    SelectAllGraphicsLayers,
    DeleteCaptions,
}

/// Menu enablement of an edit verb.
// Swift: CommandRouting.swift:56
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditEnabled {
    /// The timeline's own rules decide.
    TimelineRules,
    Always,
    Never,
    CanPasteMedia,
    GraphicsHasSelection,
    GraphicsHasLayers,
}

/// An edit verb's action and enablement for a focus target.
// Swift: CommandRouting.swift:65
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EditRoute {
    // Swift: CommandRouting.swift:66
    pub action: EditAction,
    // Swift: CommandRouting.swift:67
    pub enabled: EditEnabled,
}

impl EditRoute {
    // Swift: CommandRouting.swift:68
    pub fn new(action: EditAction, enabled: EditEnabled) -> EditRoute {
        EditRoute { action, enabled }
    }
}

/// A command a focused panel takes before the generic path.
// Swift: CommandRouting.swift:96
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FocusOverride {
    /// Space plays the previewed Library item.
    LibraryPreviewPlay,
    /// Cmd-C / Cmd-V copy and paste the whole grade.
    CopyGrade,
    PasteGrade,
}

/// Which view the zoom commands zoom.
// Swift: CommandRouting.swift:128
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ZoomTarget {
    ProgramMonitor,
    SourceMonitor,
    EffectControls,
    Timeline,
}

/// Which monitor Export Frame takes.
// Swift: CommandRouting.swift:137
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExportFrameTarget {
    SourceMonitor,
    Program,
}

/// Where Find goes.
// Swift: CommandRouting.swift:140
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FindTarget {
    /// Caption find and replace if the timeline has captions to search, else the Project panel.
    CaptionsThenProject,
    Project,
}

impl CommandRouting {
    /// Commands that are listed in a menu but have no handler yet. Must stay empty.
    // Swift: CommandRouting.swift:24
    pub fn not_wired() -> &'static [EditorCommand] {
        &[]
    }

    // Swift: CommandRouting.swift:25
    pub fn route(c: &EditorCommand) -> Option<Route> {
        let handler = if CommandSupport::is_shell_command(c) {
            Handler::Shell
        } else if CommandSupport::is_timeline_op(c) {
            Handler::TimelineOp
        } else if CommandSupport::is_effects_look_op(c) {
            Handler::EffectsLook
        } else if CommandSupport::is_core(c) {
            Handler::Core
        } else {
            return None;
        };
        Some(Route { handler, focus_dependent: Self::is_focus_dependent(c) })
    }

    fn is_focus_dependent(c: &EditorCommand) -> bool {
        use EditorCommand::*;
        if EditVerb::from_command(c).is_some() || c.keyframe_nudge_frames().is_some() {
            return true;
        }
        matches!(
            c,
            PlayPause
                | ZoomIn
                | ZoomOut
                | ZoomFit
                | ExportFrame
                | Find
                | PlayInToOutRoll
                | PlayAround
                | MaximizeActivePanel
                | SelectNextPanel
                | SelectPreviousPanel
                | MaximizePanel
                | DeleteProjectItems
                | NextKeyframe
                | PreviousKeyframe
                | AddKeyframe
                | Insert
                | Overwrite
        )
    }

    /// What an edit verb does for the focused panel.
    // Swift: CommandRouting.swift:70
    pub fn edit_route(target: FocusedEditTarget, verb: EditVerb) -> EditRoute {
        use EditAction::*;
        use EditEnabled::*;
        const SWALLOWED: EditRoute = EditRoute { action: Swallow, enabled: Never };
        let route = |action, enabled| EditRoute { action, enabled };
        match (target, verb) {
            (FocusedEditTarget::Timeline, _) => route(FallThrough, TimelineRules),
            (FocusedEditTarget::EffectControls, EditVerb::SelectAll) => SWALLOWED, // keyframe select-all: not built yet
            (FocusedEditTarget::EffectControls, _) => route(EffectControls, TimelineRules),
            (FocusedEditTarget::Project, EditVerb::Delete) => route(DeleteProjectItems, Always),
            (FocusedEditTarget::Project, EditVerb::Paste) => route(PasteMedia, CanPasteMedia),
            (FocusedEditTarget::Graphics, EditVerb::Delete) => route(DeleteGraphicsLayers, GraphicsHasSelection),
            (FocusedEditTarget::Graphics, EditVerb::SelectAll) => route(SelectAllGraphicsLayers, GraphicsHasLayers),
            (FocusedEditTarget::Captions, EditVerb::Delete) => route(DeleteCaptions, Always),
            _ => SWALLOWED,
        }
    }

    /// A command a focused panel takes before the generic path; `None` = no override.
    // Swift: CommandRouting.swift:105
    pub fn focus_override(c: &EditorCommand, focus: Option<PanelID>) -> Option<FocusOverride> {
        use EditorCommand::*;
        match (focus, c) {
            (Some(PanelID::Library), PlayPause) => Some(FocusOverride::LibraryPreviewPlay),
            (Some(PanelID::ColorInspector | PanelID::ColorClips | PanelID::Steps), Copy) => {
                Some(FocusOverride::CopyGrade)
            }
            (Some(PanelID::ColorInspector | PanelID::ColorClips | PanelID::Steps), Paste) => {
                Some(FocusOverride::PasteGrade)
            }
            _ => None,
        }
    }

    // shortcut: the member lists still live in sq-uikit's CommandSupport (menus and key tests read them there);
    // upgrade by moving the lists here once those crates depend on sq-editor-session.
    // Swift: CommandRouting.swift:118
    pub fn is_core(c: &EditorCommand) -> bool {
        CommandSupport::is_core(c)
    }
    // Swift: CommandRouting.swift:119
    pub fn is_timeline_op(c: &EditorCommand) -> bool {
        CommandSupport::is_timeline_op(c)
    }
    // Swift: CommandRouting.swift:120
    pub fn is_shell_command(c: &EditorCommand) -> bool {
        CommandSupport::is_shell_command(c)
    }
    // Swift: CommandRouting.swift:121
    pub fn is_effects_look_op(c: &EditorCommand) -> bool {
        CommandSupport::is_effects_look_op(c)
    }
    // Swift: CommandRouting.swift:122
    pub fn is_supported(c: &EditorCommand) -> bool {
        CommandSupport::is_supported(c)
    }

    /// A focused monitor zooms its picture; Effect Controls and the timeline keep their own zoom.
    // Swift: CommandRouting.swift:129
    pub fn zoom_target(focus: Option<PanelID>, effect_controls_focused: bool) -> ZoomTarget {
        match focus {
            Some(PanelID::ProgramMonitor) => ZoomTarget::ProgramMonitor,
            Some(PanelID::SourceMonitor) => ZoomTarget::SourceMonitor,
            _ if effect_controls_focused => ZoomTarget::EffectControls,
            _ => ZoomTarget::Timeline,
        }
    }

    // Swift: CommandRouting.swift:138
    pub fn export_frame_target(focus: Option<PanelID>) -> ExportFrameTarget {
        if focus == Some(PanelID::SourceMonitor) {
            ExportFrameTarget::SourceMonitor
        } else {
            ExportFrameTarget::Program
        }
    }

    // Swift: CommandRouting.swift:144
    pub fn find_target(focus: Option<PanelID>) -> FindTarget {
        if focus == Some(PanelID::Timeline) { FindTarget::CaptionsThenProject } else { FindTarget::Project }
    }

    /// The Source monitor gets the first look at every command while it has focus.
    // Swift: CommandRouting.swift:147
    pub fn source_monitor_offered(focus: Option<PanelID>) -> bool {
        focus == Some(PanelID::SourceMonitor)
    }
}

/// What a key event asks the host to do.
// Swift: KeyRouter.swift:4
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RouterAction {
    Command(EditorCommand, Option<PanelID>),
    Shuttle(ShuttleAction),
}

/// Pure key routing: key events + focused panel -> actions. The UI must not call it while a text field is first
/// responder. It owns the J/K/L down/up state machine; the hold timing for "K held + L/J held > 0.25 s" uses the
/// injected clock: every event first runs `tick()`; the UI also calls `tick()` from a timer scheduled at
/// `next_deadline` so slow mode starts without another key event.
// Swift: KeyRouter.swift:13
pub struct KeyRouter {
    // Swift: KeyRouter.swift:16
    pub map: CommandMap,
    // Swift: KeyRouter.swift:18
    pub focus: Option<PanelID>,
    shuttle: Shuttle,
    now: Box<dyn Fn() -> f64>,
    /// Physical key -> role, so key-up ignores modifiers.
    shuttle_down: BTreeMap<KeyOrder, ShuttleKey>,
    pending_hold: BTreeMap<ShuttleKey, f64>,
}

/// `Key` has no order; the router needs a map over physical keys, so it wraps the key in a debug-ordered handle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct KeyOrder(Key);

impl Ord for KeyOrder {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        format!("{:?}", self.0).cmp(&format!("{:?}", other.0))
    }
}

impl PartialOrd for KeyOrder {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl KeyRouter {
    // Swift: KeyRouter.swift:15
    pub const HOLD_THRESHOLD: f64 = 0.25;

    /// Swift defaults: the Premiere key map and no focus.
    // Swift: KeyRouter.swift:24
    pub fn new(map: CommandMap, focus: Option<PanelID>, clock: Box<dyn Fn() -> f64>) -> KeyRouter {
        KeyRouter {
            map,
            focus,
            shuttle: Shuttle::new(),
            now: clock,
            shuttle_down: BTreeMap::new(),
            pending_hold: BTreeMap::new(),
        }
    }

    /// The J/K/L state machine.
    // Swift: KeyRouter.swift:19
    pub fn shuttle(&self) -> &Shuttle {
        &self.shuttle
    }

    /// Time at which `tick()` will have work to do, if any.
    // Swift: KeyRouter.swift:30
    pub fn next_deadline(&self) -> Option<f64> {
        self.pending_hold.values().copied().reduce(f64::min).map(|t| t + Self::HOLD_THRESHOLD)
    }

    // Swift: KeyRouter.swift:31
    pub fn tick(&mut self) -> Vec<RouterAction> {
        let t = (self.now)();
        let mut out = Vec::new();
        let mut due: Vec<(ShuttleKey, f64)> =
            self.pending_hold.iter().filter(|(_, s)| t - **s >= Self::HOLD_THRESHOLD).map(|(k, s)| (*k, *s)).collect();
        due.sort_by(|a, b| a.1.total_cmp(&b.1));
        for (key, _) in due {
            self.pending_hold.remove(&key);
            let a = self.shuttle.hold_elapsed(key);
            Self::append(a, &mut out);
        }
        out
    }

    /// True when the host must swallow this event so it never reaches the responder chain, where an unhandled key
    /// down plays the error beep. Covers key downs with a binding even when `handle` yields no action, and the key
    /// ups of shuttle keys.
    // Swift: KeyRouter.swift:45
    pub fn consumes(&self, event: &KeyEvent) -> bool {
        match event.phase {
            KeyPhase::Down => self.map.command_for(&event.binding(), self.focus).is_some(),
            KeyPhase::Up => self.shuttle_down.contains_key(&KeyOrder(event.key)),
        }
    }

    /// Playback was stopped from outside the keyboard: the next L/J starts at 1x.
    // Swift: KeyRouter.swift:53
    pub fn transport_stopped(&mut self) {
        self.shuttle.stopped();
    }

    /// The playing speed was changed by something other than J/K/L: the next J/L continues from it.
    // Swift: KeyRouter.swift:56
    pub fn rate_changed(&mut self, rate: PlaybackRate) {
        self.shuttle.adopt(rate);
    }

    /// The window lost key focus: key ups of keys held now go elsewhere. Forgets them and returns what stopping a
    /// slow-mode hold does.
    // Swift: KeyRouter.swift:60
    pub fn release_all_keys(&mut self) -> Vec<RouterAction> {
        self.shuttle_down.clear();
        self.pending_hold.clear();
        let mut out = Vec::new();
        let a = self.shuttle.all_keys_released();
        Self::append(a, &mut out);
        out
    }

    // Swift: KeyRouter.swift:67
    pub fn handle(&mut self, event: &KeyEvent) -> Vec<RouterAction> {
        let mut out = self.tick();
        match event.phase {
            KeyPhase::Up => {
                if let Some(role) = self.shuttle_down.remove(&KeyOrder(event.key)) {
                    self.pending_hold.remove(&role);
                    let a = self.shuttle.release(role);
                    Self::append(a, &mut out);
                }
            }
            KeyPhase::Down => {
                let Some(cmd) = self.map.command_for(&event.binding(), self.focus) else { return out };
                out.extend(self.handle_command(cmd, event.key, event.is_repeat));
            }
        }
        out
    }

    /// A key down whose command the host already resolved: the same rules as `handle` (repeat filter, J/K/L press
    /// and hold). Returns what `handle(down)` would after its `tick()`.
    // Swift: KeyRouter.swift:85
    pub fn handle_command(&mut self, cmd: EditorCommand, key: Key, is_repeat: bool) -> Vec<RouterAction> {
        let mut out = Vec::new();
        if is_repeat && !cmd.is_repeatable() {
            return out;
        }
        match cmd {
            EditorCommand::ShuttleReverse => self.press(ShuttleKey::J, key, &mut out),
            EditorCommand::ShuttleStop => self.press(ShuttleKey::K, key, &mut out),
            EditorCommand::ShuttleForward => self.press(ShuttleKey::L, key, &mut out),
            _ => out.push(RouterAction::Command(cmd, self.focus)),
        }
        out
    }

    fn press(&mut self, role: ShuttleKey, key: Key, out: &mut Vec<RouterAction>) {
        // Auto-repeat of a held shuttle key never gets here (`handle_command` drops repeats of commands that are not
        // repeatable). A down that is no repeat is a new press even when this key's up was never seen (a lost key-up
        // must not swallow every later press of the key: L, L stayed at 1x on Windows).
        let k_held = self.shuttle_down.values().any(|r| *r == ShuttleKey::K);
        self.shuttle_down.insert(KeyOrder(key), role);
        let a = self.shuttle.press(role);
        Self::append(a, out);
        if role != ShuttleKey::K && k_held {
            self.pending_hold.insert(role, (self.now)());
        }
    }

    fn append(a: ShuttleAction, out: &mut Vec<RouterAction>) {
        if a != ShuttleAction::None {
            out.push(RouterAction::Shuttle(a));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    use sq_uikit::key_binding::KeyModifiers;

    fn router(clock: Rc<Cell<f64>>) -> KeyRouter {
        KeyRouter::new(CommandMap::premiere_default(), None, Box::new(move || clock.get()))
    }

    fn down(c: char) -> KeyEvent {
        KeyEvent::new(Key::Char(c), KeyModifiers::default())
    }

    #[test]
    fn plain_key_routes_to_its_command_with_the_focus() {
        let clock = Rc::new(Cell::new(0.0));
        let mut r = router(clock);
        r.focus = Some(PanelID::Timeline);
        let out = r.handle(&KeyEvent::new(Key::Space, KeyModifiers::default()));
        assert_eq!(out, vec![RouterAction::Command(EditorCommand::PlayPause, Some(PanelID::Timeline))]);
        assert!(r.consumes(&KeyEvent::new(Key::Space, KeyModifiers::default())));
        assert!(r.handle(&down('~')).is_empty());
    }

    #[test]
    fn repeated_l_climbs_1x_2x_4x_with_or_without_the_key_up_between() {
        let rate_of = |out: &[RouterAction]| match out {
            [RouterAction::Shuttle(ShuttleAction::SetRate(r))] => Some(*r),
            _ => None,
        };
        for with_key_up in [true, false] {
            let mut r = router(Rc::new(Cell::new(0.0)));
            let mut seen = Vec::new();
            for _ in 0..3 {
                seen.push(rate_of(&r.handle(&down('l'))));
                if with_key_up {
                    r.handle(&KeyEvent { phase: KeyPhase::Up, ..down('l') });
                }
            }
            let want = [1, 2, 4].map(|n| Some(PlaybackRate::whole(n)));
            assert_eq!(seen, want, "L, L, L (key-up between: {with_key_up})");
        }
        assert!(!EditorCommand::ShuttleForward.is_repeatable(), "a held L never reaches the press");
    }

    #[test]
    fn a_held_l_repeating_is_not_a_new_press() {
        let mut r = router(Rc::new(Cell::new(0.0)));
        assert_eq!(r.handle(&down('l')).len(), 1);
        let repeat = KeyEvent { is_repeat: true, ..down('l') };
        assert!(r.handle(&repeat).is_empty() && r.handle(&repeat).is_empty(), "auto-repeat changes nothing");
        assert_eq!(r.shuttle().rate(), PlaybackRate::FORWARD);
    }

    #[test]
    fn l_plays_and_its_key_up_is_consumed_until_released() {
        let clock = Rc::new(Cell::new(0.0));
        let mut r = router(clock);
        let out = r.handle(&down('l'));
        assert_eq!(out, vec![RouterAction::Shuttle(ShuttleAction::SetRate(PlaybackRate::whole(1)))]);
        let mut up = down('l');
        up.phase = KeyPhase::Up;
        assert!(r.consumes(&up));
        // Auto-repeat of the held key is not a new press.
        let mut rep = down('l');
        rep.is_repeat = true;
        assert!(r.handle(&rep).is_empty());
        r.handle(&up);
        assert!(!r.consumes(&up));
    }

    #[test]
    fn k_held_with_l_held_starts_slow_mode_after_the_threshold() {
        let clock = Rc::new(Cell::new(0.0));
        let mut r = router(Rc::clone(&clock));
        r.handle(&down('k'));
        let tap = r.handle(&down('l'));
        assert_eq!(tap, vec![RouterAction::Shuttle(ShuttleAction::Step(1))]);
        assert_eq!(r.next_deadline(), Some(KeyRouter::HOLD_THRESHOLD));
        clock.set(0.3);
        let slow = r.tick();
        assert_eq!(slow.len(), 1);
        assert_eq!(r.next_deadline(), None);
        assert!(r.release_all_keys().len() <= 1);
        assert!(!r.consumes(&{
            let mut u = down('l');
            u.phase = KeyPhase::Up;
            u
        }));
    }

    #[test]
    fn routes_pick_a_handler_and_edit_verbs_follow_the_focus() {
        assert!(CommandRouting::not_wired().is_empty());
        let r = CommandRouting::route(&EditorCommand::PlayPause);
        assert_eq!(r.map(|r| r.focus_dependent), Some(true));
        let paste = CommandRouting::edit_route(FocusedEditTarget::Project, EditVerb::Paste);
        assert_eq!((paste.action, paste.enabled), (EditAction::PasteMedia, EditEnabled::CanPasteMedia));
        let swallow = CommandRouting::edit_route(FocusedEditTarget::Captions, EditVerb::Copy);
        assert_eq!((swallow.action, swallow.enabled), (EditAction::Swallow, EditEnabled::Never));
        let tl = CommandRouting::edit_route(FocusedEditTarget::Timeline, EditVerb::Cut);
        assert_eq!(tl.action, EditAction::FallThrough);
    }

    #[test]
    fn overrides_and_targets() {
        assert_eq!(
            CommandRouting::focus_override(&EditorCommand::PlayPause, Some(PanelID::Library)),
            Some(FocusOverride::LibraryPreviewPlay)
        );
        assert_eq!(
            CommandRouting::focus_override(&EditorCommand::Paste, Some(PanelID::Steps)),
            Some(FocusOverride::PasteGrade)
        );
        assert_eq!(CommandRouting::focus_override(&EditorCommand::Copy, Some(PanelID::Timeline)), None);
        assert_eq!(CommandRouting::zoom_target(Some(PanelID::SourceMonitor), true), ZoomTarget::SourceMonitor);
        assert_eq!(CommandRouting::zoom_target(None, true), ZoomTarget::EffectControls);
        assert_eq!(CommandRouting::zoom_target(None, false), ZoomTarget::Timeline);
        assert_eq!(CommandRouting::export_frame_target(None), ExportFrameTarget::Program);
        assert_eq!(CommandRouting::find_target(Some(PanelID::Timeline)), FindTarget::CaptionsThenProject);
        assert!(CommandRouting::source_monitor_offered(Some(PanelID::SourceMonitor)));
    }
}
