// Swift: SQAppShell/Monitors/MonitorHost.swift `programMenuItems`
//! The Program monitor's right-click menu: marks, the marker, the Add Mask and Show submenus, Show in Source/Timeline,
//! Export Frame, Loop Playback, Zoom and the range commands. Rows queue events; the app root runs them (commands on the shell, mask rows on the Effect
//! Controls model).

use crate::monitor_panel_model::{MenuCommand, MonitorEvent, MonitorPanelModel, ProgramMenuAction};
use sq_core_model::MaskShapeKind;
use sq_core_time::Id;
use sq_draw::monitor::monitor_modes::MonitorAction;
use sq_os::Platform;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand as C;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::sqmenu_model::SQMenuItem;

/// What the menu needs to know about the shown sequence and clip.
#[derive(Clone, Debug, Default)]
pub struct ProgramMenuState {
    /// The sequence has an In/Out range.
    pub has_in_out: bool,
    /// The shown clip is a video clip (mask rows are enabled).
    pub mask_clip: bool,
    /// The clip already has masks (Delete Masks).
    pub has_masks: bool,
    /// A clip of a source is under the playhead (Reverse Match Frame).
    pub has_source: bool,
    /// Add Subject Mask can run.
    pub subject_mask_enabled: bool,
    /// Picture mask track choices without "No track": (track, title, checked).
    pub picture_tracks: Vec<(Option<Id>, String, bool)>,
    /// Subject Mask Edges choices: (title, help, checked), in the order `ProgramMenuAction::SetSubjectMaskEdges` indexes.
    pub subject_edges: Vec<(String, String, bool)>,
}

impl MonitorPanelModel {
    /// The rows, built row for row like Swift's `programMenuItems`.
    pub fn program_context_menu(&self, st: &ProgramMenuState) -> Vec<SQMenuItem> {
        let map = CommandMap::current();
        let cmd = |c: C, enabled: bool| {
            let mut i = SQMenuItem::new(&c.title());
            i.shortcut =
                map.shown_binding_here(&c).map(|b| KeyBindingText::text(&b, Platform::current())).unwrap_or_default();
            i.is_enabled = enabled;
            i.action = Some(self.event_action(MonitorEvent::ProgramMenu(ProgramMenuAction::Command(c))));
            i
        };
        let mask = |title: &str, enabled: bool, a: ProgramMenuAction| {
            let mut i = SQMenuItem::new(title);
            i.is_enabled = enabled;
            i.action = Some(self.event_action(MonitorEvent::ProgramMenu(a)));
            i
        };
        let io = st.has_in_out;
        let mut picture = SQMenuItem::new("Add Picture Mask");
        picture.is_enabled = !st.picture_tracks.is_empty();
        picture.submenu = Some(
            st.picture_tracks
                .iter()
                .map(|(track, title, checked)| {
                    let mut i = mask(title, true, ProgramMenuAction::AddPictureMask(*track));
                    i.is_checked = *checked;
                    i
                })
                .collect(),
        );
        let mut edges = SQMenuItem::new("Subject Mask Edges");
        edges.submenu = Some(
            st.subject_edges
                .iter()
                .enumerate()
                .map(|(n, (title, help, checked))| {
                    let mut i = mask(title, true, ProgramMenuAction::SetSubjectMaskEdges(n));
                    i.is_checked = *checked;
                    i.help = Some(help.clone());
                    i
                })
                .collect(),
        );
        let mut zoom = SQMenuItem::new("Zoom");
        zoom.submenu = Some(self.zoom_menu());
        let parent = |title: &str, rows: Vec<SQMenuItem>| {
            let mut i = SQMenuItem::new(title);
            i.submenu = Some(rows);
            i
        };
        // Regrouped (redesign R5a): marks and the marker first, masks and display switches in submenus, then the frame
        // commands, playback, and the two range commands last.
        let add_mask = parent(
            "Add Mask",
            vec![
                mask("Add Rectangle Mask", st.mask_clip, ProgramMenuAction::AddMask(MaskShapeKind::Rectangle)),
                mask("Add Ellipse Mask", st.mask_clip, ProgramMenuAction::AddMask(MaskShapeKind::Ellipse)),
                picture,
                mask("Add Color Range Mask", st.mask_clip, ProgramMenuAction::AddColorRangeMask),
                cmd(C::AddSubjectMask, st.subject_mask_enabled),
                SQMenuItem::separator(),
                mask("Delete Masks", st.mask_clip && st.has_masks, ProgramMenuAction::DeleteMasks),
            ],
        );
        let show = parent(
            "Show",
            vec![
                self.command_row(
                    "Safe Margins",
                    self.safe_margins(),
                    MenuCommand::Perform(MonitorAction::ToggleSafeMargins),
                ),
                self.command_row(
                    "Mask Tint",
                    self.shows_mask_tint(),
                    MenuCommand::SetShowsMaskTint(!self.shows_mask_tint()),
                ),
                edges,
            ],
        );
        vec![
            cmd(C::MarkIn, true),
            cmd(C::MarkOut, true),
            cmd(C::GoToIn, io),
            cmd(C::GoToOut, io),
            cmd(C::ClearInOut, io),
            SQMenuItem::separator(),
            cmd(C::AddMarker, true),
            SQMenuItem::separator(),
            add_mask,
            show,
            SQMenuItem::separator(),
            cmd(C::MatchFrame, true),
            cmd(C::ReverseMatchFrame, st.has_source),
            cmd(C::ExportFrame, true),
            SQMenuItem::separator(),
            cmd(C::ToggleLoop, true),
            zoom,
            SQMenuItem::separator(),
            cmd(C::Lift, io),
            cmd(C::Extract, io),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every row title, submenus included.
    fn titles(items: &[SQMenuItem]) -> Vec<String> {
        items
            .iter()
            .flat_map(|i| [vec![i.title.clone()], titles(i.submenu.as_deref().unwrap_or(&[]))].concat())
            .collect()
    }

    fn find<'a>(items: &'a [SQMenuItem], title: &str) -> Option<&'a SQMenuItem> {
        items
            .iter()
            .find_map(|i| (i.title == title).then_some(i).or_else(|| find(i.submenu.as_deref().unwrap_or(&[]), title)))
    }

    #[test]
    fn the_program_menu_offers_the_manual_mask_entries_and_disables_them_off_video() {
        let m = MonitorPanelModel::new(
            sq_core_time::Time::new(1, 25),
            sq_draw::monitor::monitor_modes::MonitorMode::Program,
        );
        let on = m.program_context_menu(&ProgramMenuState { mask_clip: true, ..Default::default() });
        let t = titles(&on);
        for want in
            ["Add Rectangle Mask", "Add Ellipse Mask", "Add Picture Mask", "Add Color Range Mask", "Delete Masks"]
        {
            assert!(t.iter().any(|x| x == want), "{want} missing in {t:?}");
        }
        let enabled = |items: &[SQMenuItem], title: &str| find(items, title).unwrap().is_enabled;
        assert!(enabled(&on, "Add Rectangle Mask"));
        assert!(!enabled(&on, "Delete Masks"), "no masks yet");
        let off = m.program_context_menu(&ProgramMenuState::default());
        assert!(titles(&off).iter().any(|x| x == "Subject Mask Edges"));
        assert!(!enabled(&off, "Add Ellipse Mask"));
    }

    #[test]
    fn subject_mask_edges_lists_the_choices_with_the_stored_one_checked() {
        let m = MonitorPanelModel::new(
            sq_core_time::Time::new(1, 25),
            sq_draw::monitor::monitor_modes::MonitorMode::Program,
        );
        let st = ProgramMenuState {
            subject_edges: vec![("Quality".into(), "a".into(), false), ("Speed".into(), "b".into(), true)],
            ..Default::default()
        };
        let menu = m.program_context_menu(&st);
        let edges = find(&menu, "Subject Mask Edges").unwrap();
        let rows = edges.submenu.as_ref().unwrap();
        assert_eq!(
            rows.iter().map(|r| (r.title.as_str(), r.is_checked)).collect::<Vec<_>>(),
            [("Quality", false), ("Speed", true)]
        );
        assert_eq!(rows[1].help.as_deref(), Some("b"));
    }
}
