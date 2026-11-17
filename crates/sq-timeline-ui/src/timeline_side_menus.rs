// Swift: TimelineSideMenus.swift
//! SQ rows for the small timeline context menus (volume key, speed key, transition) and the edit mode menu.
//! Pure builders (portable, the Windows timeline uses them too): the app passes closures, tests check titles, enabled and
//! checked state, order.

use crate::timeline_menu_spec::RulerRangeEntry;
use sq_core_model::fades_curve::FadeCurve;
use sq_core_model::{AudioTag, TimelineEditMode, Track, TrackKind};
use sq_editor_session::TrackToggle;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuShortcut};
use std::rc::Rc;

fn action(title: &str, f: Rc<dyn Fn()>) -> SQMenuItem {
    let mut i = SQMenuItem::new(title);
    i.action = Some(f);
    i
}

/// The handlers of the track header menu (`TimelineSideMenus.trackHeader` labels); the optional ones are left out of the
/// menu when `None`.
pub struct TrackHeaderMenu {
    pub add_video: Rc<dyn Fn()>,
    pub add_audio: Rc<dyn Fn()>,
    pub delete: Rc<dyn Fn()>,
    pub rename: Rc<dyn Fn()>,
    pub move_up: Option<Rc<dyn Fn()>>,
    pub move_down: Option<Rc<dyn Fn()>>,
    pub mix: Rc<dyn Fn()>,
    pub toggle_ducking: Rc<dyn Fn()>,
    pub sequence_volume: Option<Rc<dyn Fn()>>,
    pub select_all: Option<Rc<dyn Fn()>>,
    pub toggle: Option<Rc<dyn Fn(TrackToggle)>>,
}

/// Builders of the small context menus.
pub struct TimelineSideMenus;

impl TimelineSideMenus {
    /// Right-click on a volume key.
    pub fn volume_key(delete: Rc<dyn Fn()>) -> Vec<SQMenuItem> {
        vec![action("Delete Keyframe", delete)]
    }

    /// Fade handle menu: the curve shapes with a check on the current one. No fade yet: the rows are disabled.
    pub fn fade_curve(current: Option<FadeCurve>, set: Rc<dyn Fn(FadeCurve)>) -> Vec<SQMenuItem> {
        FadeCurve::ALL
            .iter()
            .map(|c| {
                let c = *c;
                let set = Rc::clone(&set);
                let mut i = action(c.title(), Rc::new(move || set(c)));
                i.is_enabled = current.is_some();
                i.is_checked = current == Some(c);
                i
            })
            .collect()
    }

    /// Right-click on the speed band away from a key: "Add Speed Point" at the click.
    pub fn speed_point(add: Rc<dyn Fn()>) -> Vec<SQMenuItem> {
        vec![action("Add Speed Point", add)]
    }

    /// Right-click on a speed key.
    pub fn speed_key(delete_title: &str, is_ramp: bool, curve: Rc<dyn Fn()>, delete: Rc<dyn Fn()>) -> Vec<SQMenuItem> {
        let mut rows = Vec::new();
        if is_ramp {
            rows.push(action("Speed Transition Curve…", curve));
            rows.push(SQMenuItem::separator());
        }
        rows.push(action(delete_title, delete));
        rows
    }

    /// Marker commands at the pointer, then Mark In / Out and Remove In and Out (keys shown), Delete Marker last.
    pub fn ruler(
        has_marker_at_pointer: bool,
        entries: &[RulerRangeEntry],
        add_marker_shortcut: &str,
        add_marker: Rc<dyn Fn()>,
        edit_marker: Rc<dyn Fn()>,
        range: Rc<dyn Fn(EditorCommand)>,
        delete_marker: Rc<dyn Fn()>,
    ) -> Vec<SQMenuItem> {
        let mut first = action("Add Marker", add_marker);
        first.shortcut = add_marker_shortcut.to_string();
        let mut rows = vec![first];
        if has_marker_at_pointer {
            rows.push(action("Edit Marker…", edit_marker));
        }
        rows.push(SQMenuItem::separator());
        for e in entries {
            let cmd = e.command;
            let range = Rc::clone(&range);
            let mut row = action(&e.title, Rc::new(move || range(cmd)));
            row.shortcut = SQMenuShortcut::glyphs(&e.key, e.key_modifiers);
            row.is_enabled = e.is_enabled;
            rows.push(row);
        }
        if has_marker_at_pointer {
            rows.push(SQMenuItem::separator());
            rows.push(action("Delete Marker", delete_marker));
        }
        rows
    }

    /// Right-click on a track header: the switches, Select All, Add / Delete / Move / Rename, mix and live ducking.
    pub fn track_header(track: &Track, h: TrackHeaderMenu) -> Vec<SQMenuItem> {
        // Every switch of the header, also the ones it only shows in their non-default state (audio lock, sync lock).
        let mut switches: Vec<SQMenuItem> = Vec::new();
        if let Some(toggle) = &h.toggle {
            let mut checked = |title: &str, on: bool, t: TrackToggle| {
                let toggle = Rc::clone(toggle);
                let mut row = action(title, Rc::new(move || toggle(t)));
                row.is_checked = on;
                switches.push(row);
            };
            checked("Target Track", track.is_targeted, TrackToggle::Target);
            if track.kind == TrackKind::Video {
                checked("Show Track", track.is_visible, TrackToggle::Visible);
            } else {
                checked("Mute", track.is_muted, TrackToggle::Mute);
                checked("Solo", track.is_solo, TrackToggle::Solo);
            }
            checked("Lock Track", track.is_locked, TrackToggle::Lock);
            checked("Sync Lock", track.sync_lock, TrackToggle::SyncLock);
            switches.push(SQMenuItem::separator());
        }
        let mut rows = switches;
        if let Some(select_all) = h.select_all {
            let mut row = action("Select All Clips on Track", select_all);
            row.is_enabled = !track.clips().is_empty() && !track.is_locked;
            rows.push(row);
            rows.push(SQMenuItem::separator());
        }
        rows.push(action("Add Video Track", h.add_video));
        rows.push(action("Add Audio Track", h.add_audio));
        let mut delete = action("Delete Track", h.delete);
        delete.is_enabled = !track.is_locked;
        rows.push(delete);
        rows.push(SQMenuItem::separator());
        let moves = h.move_up.is_some() || h.move_down.is_some();
        if let Some(up) = h.move_up {
            rows.push(action("Move Track Up", up));
        }
        if let Some(down) = h.move_down {
            rows.push(action("Move Track Down", down));
        }
        if moves {
            rows.push(SQMenuItem::separator());
        }
        rows.push(action("Rename…", h.rename));
        if track.kind == TrackKind::Audio {
            rows.push(action("Volume and Pan…", h.mix));
            // The level of the whole sequence (after every track), next to the track's own fader.
            if let Some(v) = h.sequence_volume {
                rows.push(action("Sequence Volume…", v));
            }
            // Per-track opt-out of live ducking. Only Music (ducked) and Dialogue (ducks) tracks take part.
            let title = match track.audio_role {
                Some(AudioTag::Music) => "Duck Under Dialogue",
                Some(AudioTag::Dialogue) => "Duck the Music",
                _ => "Live Ducking (Dialogue or Music tracks)",
            };
            let takes_part = matches!(track.audio_role, Some(AudioTag::Music | AudioTag::Dialogue));
            let mut row = action(title, h.toggle_ducking);
            row.is_enabled = takes_part;
            row.is_checked = takes_part && !track.is_excluded_from_live_ducking();
            rows.push(row);
        }
        rows
    }

    /// Right-click on a transition.
    pub fn transition(
        set_duration: Rc<dyn Fn()>,
        save_as_preset: Rc<dyn Fn()>,
        delete: Rc<dyn Fn()>,
    ) -> Vec<SQMenuItem> {
        vec![
            action("Set Transition Duration…", set_duration),
            action("Save as Preset…", save_as_preset),
            SQMenuItem::separator(),
            action("Delete", delete),
        ]
    }
}

/// Rows of the edit mode menu and the chip's texts. The chip shows the short label ("Fast"), menus and tooltips use the
/// full name ("Fast Cut"). Shared by the Mac chip and the drawn header bar.
pub struct TimelineModeMenu;

impl TimelineModeMenu {
    /// Capsule metrics: icon 14.
    pub const ICON_SIZE: f64 = 14.0;
    /// 8 pt in from the left.
    pub const LEFT_PADDING: f64 = 8.0;
    /// 10 pt from the right.
    pub const RIGHT_PADDING: f64 = 10.0;
    /// 6 pt between icon and label.
    pub const ICON_TO_LABEL: f64 = 6.0;

    /// Short label of the chip.
    pub fn chip_label(mode: TimelineEditMode) -> &'static str {
        if mode == TimelineEditMode::Magnetic { "Fast" } else { "Normal" }
    }

    /// Full name of the mode.
    pub fn full_name(mode: TimelineEditMode) -> &'static str {
        if mode == TimelineEditMode::Magnetic { "Fast Cut" } else { "Normal" }
    }

    /// Icon of the mode.
    pub fn icon(mode: TimelineEditMode) -> SQIcon {
        if mode == TimelineEditMode::Magnetic { SQIcon::Zap } else { SQIcon::Stack }
    }

    /// One-line help of the mode.
    pub fn help(mode: TimelineEditMode) -> &'static str {
        if mode == TimelineEditMode::Magnetic {
            "Gaps close by themselves, attached clips follow"
        } else {
            "Classic tracks, edits stay where you put them"
        }
    }

    /// Normal first, Fast Cut second, a check on `current`; picking a row calls `pick`.
    pub fn items(current: TimelineEditMode, pick: Rc<dyn Fn(TimelineEditMode)>) -> Vec<SQMenuItem> {
        [TimelineEditMode::Normal, TimelineEditMode::Magnetic]
            .iter()
            .map(|mode| {
                let mode = *mode;
                let pick = Rc::clone(&pick);
                let mut i = action(Self::full_name(mode), Rc::new(move || pick(mode)));
                i.is_checked = mode == current;
                i.help = Some(Self::help(mode).to_string());
                i.with_leading(Self::icon(mode), None)
            })
            .collect()
    }

    /// Wide enough for the longer label, so the header does not shift when the mode changes.
    pub fn chip_width(label_width: impl Fn(&str) -> f64) -> f64 {
        let label = [TimelineEditMode::Normal, TimelineEditMode::Magnetic]
            .iter()
            .map(|m| label_width(Self::chip_label(*m)))
            .fold(0.0, f64::max);
        (Self::LEFT_PADDING + Self::ICON_SIZE + Self::ICON_TO_LABEL + label + Self::RIGHT_PADDING).ceil()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::Clip;
    use sq_core_time::Id;
    use sq_uikit::sqmenu_model::SQMenuItemKind;
    use std::cell::Cell;

    fn titles(rows: &[SQMenuItem]) -> Vec<String> {
        rows.iter()
            .map(|r| if r.kind == SQMenuItemKind::Separator { "-".to_string() } else { r.title.clone() })
            .collect()
    }

    fn noop() -> Rc<dyn Fn()> {
        Rc::new(|| {})
    }

    #[test]
    fn volume_key_runs_delete() {
        let ran = Rc::new(Cell::new(0));
        let r = Rc::clone(&ran);
        let rows = TimelineSideMenus::volume_key(Rc::new(move || r.set(r.get() + 1)));
        assert_eq!(titles(&rows), vec!["Delete Keyframe"]);
        if let Some(a) = &rows[0].action {
            a();
        }
        assert_eq!(ran.get(), 1);
    }

    #[test]
    fn speed_key_adds_curve_only_on_ramp() {
        let plain = TimelineSideMenus::speed_key("Delete Speed Keyframe", false, noop(), noop());
        assert_eq!(titles(&plain), vec!["Delete Speed Keyframe"]);
        let ramp = TimelineSideMenus::speed_key("Delete Speed Transition", true, noop(), noop());
        assert_eq!(titles(&ramp), vec!["Speed Transition Curve…", "-", "Delete Speed Transition"]);
    }

    #[test]
    fn transition_order() {
        let rows = TimelineSideMenus::transition(noop(), noop(), noop());
        assert_eq!(titles(&rows), vec!["Set Transition Duration…", "Save as Preset…", "-", "Delete"]);
    }

    #[test]
    fn fade_curve_rows_follow_the_current_fade() {
        let set = Rc::new(Cell::new(None));
        let s = Rc::clone(&set);
        let rows = TimelineSideMenus::fade_curve(Some(FadeCurve::SCurve), Rc::new(move |c| s.set(Some(c))));
        assert_eq!(rows.len(), FadeCurve::ALL.len());
        assert!(rows.iter().zip(FadeCurve::ALL).all(|(r, c)| r.is_checked == (c == FadeCurve::SCurve) && r.is_enabled));
        if let Some(a) = &rows[0].action {
            a();
        }
        assert_eq!(set.get(), Some(FadeCurve::Linear));
        assert!(TimelineSideMenus::fade_curve(None, Rc::new(|_| {})).iter().all(|r| !r.is_enabled));
    }

    #[test]
    fn mode_menu_checks_the_current_mode() {
        let rows = TimelineModeMenu::items(TimelineEditMode::Magnetic, Rc::new(|_| {}));
        assert_eq!(titles(&rows), vec!["Normal", "Fast Cut"]);
        assert!(!rows[0].is_checked && rows[1].is_checked);
        assert_eq!(TimelineModeMenu::chip_label(TimelineEditMode::Magnetic), "Fast");
        assert_eq!(TimelineModeMenu::chip_width(|s| s.len() as f64 * 6.0), (8.0_f64 + 14.0 + 6.0 + 36.0 + 10.0).ceil());
    }

    #[test]
    fn ruler_rows() {
        use sq_uikit::command_map::CommandMap;
        use std::cell::RefCell;
        let entries = RulerRangeEntry::entries(false, &CommandMap::current());
        let cmds = Rc::new(RefCell::new(Vec::<EditorCommand>::new()));
        let sink = Rc::clone(&cmds);
        let noop: Rc<dyn Fn()> = Rc::new(|| {});
        let plain = TimelineSideMenus::ruler(
            false,
            &entries,
            "M",
            Rc::clone(&noop),
            Rc::clone(&noop),
            Rc::new(move |c| sink.borrow_mut().push(c)),
            Rc::clone(&noop),
        );
        assert_eq!(titles(&plain), ["Add Marker", "-", "Mark In", "Mark Out", "Remove In and Out"]);
        assert_eq!(plain[0].shortcut, "M");
        assert!(!plain[4].is_enabled);
        if let Some(f) = &plain[2].action {
            f();
        }
        assert_eq!(*cmds.borrow(), [EditorCommand::MarkIn]);
        let on = TimelineSideMenus::ruler(
            true,
            &entries,
            "",
            Rc::clone(&noop),
            Rc::clone(&noop),
            Rc::new(|_| {}),
            Rc::clone(&noop),
        );
        assert_eq!(
            titles(&on),
            ["Add Marker", "Edit Marker…", "-", "Mark In", "Mark Out", "Remove In and Out", "-", "Delete Marker"]
        );
    }

    fn header(track: &Track, f: impl FnOnce(&mut TrackHeaderMenu)) -> Vec<SQMenuItem> {
        let mut h = TrackHeaderMenu {
            add_video: noop(),
            add_audio: noop(),
            delete: noop(),
            rename: noop(),
            move_up: None,
            move_down: None,
            mix: noop(),
            toggle_ducking: noop(),
            sequence_volume: None,
            select_all: None,
            toggle: None,
        };
        f(&mut h);
        TimelineSideMenus::track_header(track, h)
    }

    #[test]
    fn track_header_video_and_locked() {
        let mut track = Track::new(Id::from_u128(1), TrackKind::Video);
        let mut rows = header(&track, |_| {});
        assert_eq!(titles(&rows), vec!["Add Video Track", "Add Audio Track", "Delete Track", "-", "Rename…"]);
        assert!(rows[2].is_enabled);
        track.is_locked = true;
        rows = header(&track, |_| {});
        assert!(!rows[2].is_enabled);
    }

    #[test]
    fn track_header_select_all_clips_row() {
        let hit = Rc::new(Cell::new(false));
        let mut track = Track::new(Id::from_u128(1), TrackKind::Video);
        let rows = |track: &Track| {
            let hit = Rc::clone(&hit);
            header(track, move |h| h.select_all = Some(Rc::new(move || hit.set(true))))
        };
        assert!(rows(&track)[0].title == "Select All Clips on Track" && !rows(&track)[0].is_enabled); // empty track
        let one = sq_core_time::Time::new(1, 1);
        track.set_clips(vec![Clip::new(
            Id::from_u128(2),
            "c",
            Id::from_u128(3),
            TrackKind::Video,
            sq_core_time::TimeRange::new(sq_core_time::Time::ZERO, one),
            sq_core_time::Time::ZERO,
        )]);
        assert!(rows(&track)[0].is_enabled);
        if let Some(a) = &rows(&track)[0].action {
            a();
        }
        assert!(hit.get());
        track.is_locked = true;
        assert!(!rows(&track)[0].is_enabled);
    }

    #[test]
    fn track_header_audio_ducking() {
        let mut track = Track::new(Id::from_u128(1), TrackKind::Audio);
        let ducking = |t: &Track| header(t, |_| {}).pop();
        let d = ducking(&track);
        assert_eq!(d.as_ref().map(|r| r.title.as_str()), Some("Live Ducking (Dialogue or Music tracks)"));
        assert!(d.as_ref().is_some_and(|r| !r.is_enabled && !r.is_checked));
        track.audio_role = Some(AudioTag::Music);
        let d = ducking(&track);
        assert_eq!(d.as_ref().map(|r| r.title.as_str()), Some("Duck Under Dialogue"));
        assert!(d.as_ref().is_some_and(|r| r.is_enabled && r.is_checked));
        track.audio_role = Some(AudioTag::Dialogue);
        track.set_excluded_from_live_ducking(true);
        let d = ducking(&track);
        assert_eq!(d.as_ref().map(|r| r.title.as_str()), Some("Duck the Music"));
        assert!(d.as_ref().is_some_and(|r| r.is_enabled && !r.is_checked));
        let rows = header(&track, |_| {});
        assert_eq!(rows[5].title, "Volume and Pan…");
        let hit = Rc::new(Cell::new(false));
        let h2 = Rc::clone(&hit);
        let with_level = header(&track, move |h| h.sequence_volume = Some(Rc::new(move || h2.set(true))));
        assert!(
            with_level[6].title == "Sequence Volume…" && with_level.last().is_some_and(|r| r.title == "Duck the Music")
        );
        if let Some(a) = &with_level[6].action {
            a();
        }
        assert!(hit.get());
        let video = Track::new(Id::from_u128(9), TrackKind::Video);
        let rows = header(&video, |h| h.sequence_volume = Some(noop()));
        assert!(!titles(&rows).contains(&"Sequence Volume…".to_string()));
    }

    #[test]
    fn track_header_lists_move_rows_when_given() {
        let track = Track::new(Id::from_u128(1), TrackKind::Video);
        let rows = header(&track, |h| {
            h.move_up = Some(noop());
            h.move_down = Some(noop());
        });
        let t = titles(&rows);
        assert!(t.contains(&"Move Track Up".to_string()) && t.contains(&"Move Track Down".to_string()));
    }

    #[test]
    fn track_header_switches_check_and_toggle() {
        let got = Rc::new(std::cell::RefCell::new(Vec::new()));
        let g = Rc::clone(&got);
        let mut track = Track::new(Id::from_u128(1), TrackKind::Audio);
        track.is_muted = true;
        let rows = header(&track, move |h| h.toggle = Some(Rc::new(move |t| g.borrow_mut().push(t))));
        assert_eq!(
            titles(&rows)[..6],
            ["Target Track", "Mute", "Solo", "Lock Track", "Sync Lock", "-"].map(String::from)
        );
        assert!(rows[1].is_checked);
        if let Some(a) = &rows[1].action {
            a();
        }
        assert_eq!(*got.borrow(), vec![TrackToggle::Mute]);
    }
}
