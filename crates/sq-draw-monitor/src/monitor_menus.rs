// Swift: MonitorMenus.swift
//! SQ rows of the monitor menus (options "...", viewer right-click pieces, source and format popups). Built directly, no
//! native menu. Actions are `Rc<dyn Fn>` the caller supplies; the model's own menus push commands (see
//! `monitor_panel_model::MenuQueue`).

use crate::monitor_panel_model::{FormatItem, SequenceItem, SourceItem};
use crate::safe_zone_choice::SafeZoneChoice;
use crate::shortcut_tips::MonitorActionTips;
use sq_core_effects::sequence_conform::{AspectPreset, SequenceConform};
use sq_core_time::Id;
use sq_draw::monitor::monitor_modes::{MonitorAction, MonitorMode, MonitorZoom};
use sq_editor_session::es01_session_core::MonitorQuality;
use sq_os::Platform;
use sq_uikit::command_map::CommandMap;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind};
use std::rc::Rc;

/// What the "..." menu shows.
pub struct OptionMenuState<'a> {
    /// Program or Source.
    pub mode: MonitorMode,
    /// The actions this monitor offers.
    pub available: &'a [MonitorAction],
    /// Loop Playback is on.
    pub is_looping: bool,
    /// Safe Margins is on.
    pub safe_margins: bool,
    /// The zoom shown.
    pub zoom: MonitorZoom,
    /// The playback quality choice.
    pub quality: MonitorQuality,
    /// The level Auto resolved to.
    pub auto_level: Option<MonitorQuality>,
}

/// What the "..." menu's rows do.
pub struct OptionMenuActions<'a> {
    /// Row title of an action.
    pub title: &'a dyn Fn(MonitorAction) -> String,
    /// Key column of an action row.
    pub shortcut: &'a dyn Fn(MonitorAction) -> String,
    /// An action row.
    pub perform: Rc<dyn Fn(MonitorAction)>,
    /// A zoom row.
    pub set_zoom: Rc<dyn Fn(MonitorZoom)>,
    /// A quality row.
    pub set_quality: Rc<dyn Fn(MonitorQuality)>,
}

/// SQ rows of the monitor menus.
pub enum MonitorMenus {}

fn row(title: &str, is_checked: bool, action: Rc<dyn Fn()>) -> SQMenuItem {
    let mut i = SQMenuItem::new(title);
    i.is_checked = is_checked;
    i.action = Some(action);
    i
}

fn submenu(title: &str, items: Vec<SQMenuItem>) -> SQMenuItem {
    let mut i = SQMenuItem::new(title);
    i.submenu = Some(items);
    i
}

impl MonitorMenus {
    /// Zoom presets with the current one checked (Program and Source viewer menus, options menu).
    pub fn zoom_items(current: MonitorZoom, set: Rc<dyn Fn(MonitorZoom)>) -> Vec<SQMenuItem> {
        MonitorZoom::presets()
            .into_iter()
            .map(|z| {
                let set = Rc::clone(&set);
                row(&z.title(), z == current, Rc::new(move || set(z)))
            })
            .collect()
    }

    /// The playback quality rows.
    pub fn quality_items(
        current: MonitorQuality,
        auto_level: Option<MonitorQuality>,
        set: Rc<dyn Fn(MonitorQuality)>,
    ) -> Vec<SQMenuItem> {
        MonitorQuality::menu_cases()
            .into_iter()
            .map(|q| {
                let set = Rc::clone(&set);
                row(&Self::auto_title(q, auto_level), q == current, Rc::new(move || set(q)))
            })
            .collect()
    }

    /// Menu title of a quality row: Auto names the level it currently resolved to ("Auto (1/2)").
    pub fn auto_title(q: MonitorQuality, level: Option<MonitorQuality>) -> String {
        match level {
            Some(level) if q == MonitorQuality::Auto => format!("Auto ({})", level.title()),
            _ => q.title().to_string(),
        }
    }

    /// Key column of an action row: the mapped key of its command (never hard-coded), "" when unbound.
    pub fn shortcut_of(a: MonitorAction, map: &CommandMap) -> String {
        a.command()
            .and_then(|c| map.shown_binding_here(&c))
            .map(|b| KeyBindingText::text(&b, Platform::current()))
            .unwrap_or_default()
    }

    /// The "..." menu: toggles, Zoom, Playback Quality, then the overflow actions that are available.
    pub fn option_items(st: &OptionMenuState, a: &OptionMenuActions) -> Vec<SQMenuItem> {
        let make = |t: &str, act: MonitorAction, on: Option<bool>| {
            let perform = Rc::clone(&a.perform);
            let mut i = row(t, on.unwrap_or(false), Rc::new(move || perform(act)));
            i.shortcut = (a.shortcut)(act);
            i
        };
        let mut rows = vec![
            make("Loop Playback", MonitorAction::Loop, Some(st.is_looping)),
            make("Play In to Out", MonitorAction::PlayInToOut, None),
        ];
        if st.mode == MonitorMode::Program {
            rows.push(make("Safe Margins", MonitorAction::ToggleSafeMargins, Some(st.safe_margins)));
        }
        rows.push(SQMenuItem::separator());
        rows.push(submenu("Zoom", Self::zoom_items(st.zoom, Rc::clone(&a.set_zoom))));
        rows.push(submenu(
            "Playback Quality",
            Self::quality_items(st.quality, st.auto_level, Rc::clone(&a.set_quality)),
        ));
        rows.push(SQMenuItem::separator());
        for act in MonitorAction::overflow_menu(st.mode) {
            if st.available.contains(&act) {
                rows.push(make(&(a.title)(act), act, None));
            }
        }
        let extras: Vec<MonitorAction> =
            MonitorAction::source_menu_extras(st.mode).into_iter().filter(|x| st.available.contains(x)).collect();
        if !extras.is_empty() {
            rows.push(SQMenuItem::separator());
            for act in extras {
                let t = act.menu_title().map(str::to_string).unwrap_or_else(|| (a.title)(act));
                rows.push(make(&t, act, None));
            }
        }
        rows
    }

    /// The "..." menu in its final shape: the base rows, then one submenu per non-empty group (Overlays, Playback,
    /// Compare), then `tail` rows. A group of one row is shown as that row, not as a submenu of one.
    pub fn grouped(
        base: Vec<SQMenuItem>,
        overlays: Vec<SQMenuItem>,
        playback: Vec<SQMenuItem>,
        compare: Vec<SQMenuItem>,
        tail: Vec<SQMenuItem>,
    ) -> Vec<SQMenuItem> {
        let mut rows = base;
        let mut groups: Vec<SQMenuItem> = Vec::new();
        for (title, mut items) in [("Overlays", overlays), ("Playback", playback), ("Compare", compare)] {
            if items.is_empty() {
                continue;
            }
            if items.len() == 1 {
                groups.push(items.remove(0));
            } else {
                groups.push(submenu(title, items));
            }
        }
        let needs_separator = |rows: &Vec<SQMenuItem>| rows.last().is_some_and(|r| r.kind != SQMenuItemKind::Separator);
        if !groups.is_empty() {
            if needs_separator(&rows) {
                rows.push(SQMenuItem::separator());
            }
            rows.extend(groups);
        }
        if !tail.is_empty() {
            if needs_separator(&rows) {
                rows.push(SQMenuItem::separator());
            }
            rows.extend(tail);
        }
        rows
    }

    /// Source clip popup: the clips opened before (checked = current), then Close / Close All.
    pub fn source_items(
        items: &[SourceItem],
        current: Option<Id>,
        pick: Rc<dyn Fn(Id)>,
        close: Rc<dyn Fn()>,
        close_all: Rc<dyn Fn()>,
    ) -> Vec<SQMenuItem> {
        if items.is_empty() {
            return Vec::new();
        }
        let mut rows: Vec<SQMenuItem> = items
            .iter()
            .map(|it| {
                let pick = Rc::clone(&pick);
                let id = it.id;
                row(&it.name, Some(it.id) == current, Rc::new(move || pick(id)))
            })
            .collect();
        rows.push(SQMenuItem::separator());
        rows.push(row("Close", false, close));
        rows.push(row("Close All", false, close_all));
        rows
    }

    /// Title of the source popup ("No clip" when empty).
    pub fn source_title(items: &[SourceItem], current: Option<Id>) -> String {
        let Some(first) = items.first() else { return "No clip".to_string() };
        items.iter().find(|i| Some(i.id) == current).map_or_else(|| first.name.clone(), |i| i.name.clone())
    }

    /// Program title popup: the open sequences (checked = the shown one). Frame formats are not listed here (see
    /// `format_items`).
    pub fn sequence_items(items: &[SequenceItem], current: Option<Id>, pick: Rc<dyn Fn(Id)>) -> Vec<SQMenuItem> {
        items
            .iter()
            .map(|it| {
                let pick = Rc::clone(&pick);
                let id = it.id;
                row(&it.name, Some(it.id) == current, Rc::new(move || pick(id)))
            })
            .collect()
    }

    /// Title of the Program popup: the shown sequence's name ("Sequence" without one).
    pub fn sequence_title(items: &[SequenceItem], current: Option<Id>, fallback: &str) -> String {
        if let Some(n) = items.iter().find(|i| Some(i.id) == current).map(|i| i.name.as_str()).filter(|n| !n.is_empty())
        {
            return n.to_string();
        }
        if fallback.is_empty() { "Sequence".to_string() } else { fallback.to_string() }
    }

    /// Program title: the sequence name, plus " · name" of the variant shown (none for the sequence's own format).
    pub fn program_title(
        items: &[SequenceItem],
        current: Option<Id>,
        fallback: &str,
        formats: &[FormatItem],
        format: Option<Id>,
    ) -> String {
        let base = Self::sequence_title(items, current, fallback);
        let Some(f) = format else { return base };
        let Some(v) = formats.iter().find(|v| v.id == f) else { return base };
        format!("{} · {}", base, v.name)
    }

    /// Format popup: the sequence's own format (`None` id), its variants, then Add Format (aspect presets) and Remove Format.
    pub fn format_items(
        base: &str,
        items: &[FormatItem],
        current: Option<Id>,
        pick: Rc<dyn Fn(Option<Id>)>,
        add: Rc<dyn Fn(AspectPreset)>,
        remove: Rc<dyn Fn(Id)>,
    ) -> Vec<SQMenuItem> {
        let own = Rc::clone(&pick);
        let mut rows =
            vec![row(if base.is_empty() { "Sequence" } else { base }, current.is_none(), Rc::new(move || own(None)))];
        for it in items {
            let pick = Rc::clone(&pick);
            let id = it.id;
            rows.push(row(&it.name, Some(it.id) == current, Rc::new(move || pick(Some(id)))));
        }
        rows.push(SQMenuItem::separator());
        let presets: Vec<SQMenuItem> = SequenceConform::ASPECT_PRESETS
            .iter()
            .map(|p| {
                let add = Rc::clone(&add);
                let p = *p;
                row(&format!("{} · {} × {}", p.name, p.width, p.height), false, Rc::new(move || add(p)))
            })
            .collect();
        rows.push(submenu("Add Format", presets));
        let mut remove_row = row(
            "Remove Format",
            false,
            Rc::new(move || {
                if let Some(c) = current {
                    remove(c);
                }
            }),
        );
        remove_row.is_enabled = current.is_some();
        rows.push(remove_row);
        rows
    }

    /// Platform UI zone popup of the Program monitor (checked = current).
    pub fn safe_zone_items(current: SafeZoneChoice, set: Rc<dyn Fn(SafeZoneChoice)>) -> Vec<SQMenuItem> {
        SafeZoneChoice::ALL
            .into_iter()
            .map(|c| {
                let set = Rc::clone(&set);
                row(c.title(), c == current, Rc::new(move || set(c)))
            })
            .collect()
    }

    /// "Show platform UI" row under the zone choices: the mock of the app's buttons and caption (TikTok, Reels, Shorts only).
    pub fn platform_mock_items(is_on: bool, available: bool, set: Rc<dyn Fn(bool)>) -> Vec<SQMenuItem> {
        let mut r = row("Show platform UI", is_on && available, Rc::new(move || set(!is_on)));
        r.is_enabled = available;
        vec![SQMenuItem::separator(), r]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn auto_names_the_level_it_resolved_to() {
        assert_eq!(MonitorMenus::auto_title(MonitorQuality::Auto, Some(MonitorQuality::Half)), "Auto (1/2)");
        assert_eq!(MonitorMenus::auto_title(MonitorQuality::Full, Some(MonitorQuality::Half)), "Full");
        assert_eq!(MonitorMenus::auto_title(MonitorQuality::Auto, None), "Auto");
    }

    #[test]
    fn grouped_collapses_single_row_groups_and_separates() {
        let one = vec![SQMenuItem::new("Resolution Badge")];
        let two = vec![SQMenuItem::new("A"), SQMenuItem::new("B")];
        let rows = MonitorMenus::grouped(
            vec![SQMenuItem::new("Base")],
            one,
            Vec::new(),
            two,
            vec![SQMenuItem::new("Full Screen")],
        );
        let titles: Vec<&str> = rows.iter().map(|r| r.title.as_str()).collect();
        assert_eq!(titles, ["Base", "", "Resolution Badge", "Compare", "", "Full Screen"]);
    }

    #[test]
    fn program_title_and_popup_name_the_variant() {
        let seq = Id::from_u128(1);
        let v = Id::from_u128(2);
        let items = [SequenceItem { id: seq, name: "Main".into() }];
        let fmts = [FormatItem { id: v, name: "Vertical".into() }];
        assert_eq!(MonitorMenus::program_title(&items, Some(seq), "", &fmts, None), "Main");
        assert_eq!(MonitorMenus::program_title(&items, Some(seq), "", &fmts, Some(v)), "Main · Vertical");
        let rows =
            MonitorMenus::format_items("16:9", &fmts, Some(v), Rc::new(|_| {}), Rc::new(|_| {}), Rc::new(|_| {}));
        assert_eq!(rows[0].title, "16:9");
        assert_eq!(rows[1].title, "Vertical");
    }

    #[test]
    fn source_popup_lists_clips_then_close_rows() {
        let a = Id::from_u128(1);
        let items = [SourceItem { id: a, name: "Clip".into() }];
        assert_eq!(MonitorMenus::source_title(&[], None), "No clip");
        assert_eq!(MonitorMenus::source_title(&items, None), "Clip");
        let picked = Rc::new(RefCell::new(Vec::new()));
        let p = Rc::clone(&picked);
        let rows = MonitorMenus::source_items(
            &items,
            Some(a),
            Rc::new(move |id| p.borrow_mut().push(id)),
            Rc::new(|| {}),
            Rc::new(|| {}),
        );
        assert_eq!(rows.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(), ["Clip", "", "Close", "Close All"]);
        if let Some(act) = &rows[0].action {
            act();
        }
        assert_eq!(*picked.borrow(), [a]);
    }
}
