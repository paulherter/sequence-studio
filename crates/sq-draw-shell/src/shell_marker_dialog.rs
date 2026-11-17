// Swift: ShellMarkerDialog.swift
//! The Mac marker sheet (`EditorPanels.editMarker`) as a shell form: Name, Color, Duration (sequence markers), Comment;
//! OK, Cancel and a leading Delete Marker. Shared by the Mac shared UI and Windows (timeline request `.marker` /
//! `.clipMarker`, Add and Edit Marker, Edit Marker).

use crate::shell_dialog::{DialogForm, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::ShellHost;
use sq_core_model::{Marker, MarkerColor, Timeline};
use sq_core_time::{Id, Time};
use sq_draw::DrawTheme;
use sq_editor_session::{EditorSession, MarkersPanelModel};
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// `MarkerColor.allCases`.
const COLORS: [MarkerColor; 8] = [
    MarkerColor::Green,
    MarkerColor::Red,
    MarkerColor::Purple,
    MarkerColor::Orange,
    MarkerColor::Yellow,
    MarkerColor::White,
    MarkerColor::Blue,
    MarkerColor::Cyan,
];

/// `rawValue.capitalized` of a marker color ("Green"), spelled out so a renamed variant cannot change the label.
fn color_title(c: MarkerColor) -> String {
    match c {
        MarkerColor::Green => "Green",
        MarkerColor::Red => "Red",
        MarkerColor::Purple => "Purple",
        MarkerColor::Orange => "Orange",
        MarkerColor::Yellow => "Yellow",
        MarkerColor::White => "White",
        MarkerColor::Blue => "Blue",
        MarkerColor::Cyan => "Cyan",
    }
    .to_string()
}

impl ShellHost {
    /// Opens the dialog for a sequence marker (`clip == None`) or a clip marker and applies the answer. False when the
    /// marker is gone.
    pub async fn edit_marker<R: ShellRoot + ?Sized>(h: UiRef<R>, id: Id, clip: Option<Id>) -> bool {
        let Some(Some(d)) = h.with(|r| Self::marker_dialog(id, clip, r.shell_parts().session)) else { return false };
        let Some(answer) = Self::ask(&h, d).await else { return true };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            Self::apply_marker_dialog(&*form, answer, id, clip, p.session);
        });
        true
    }

    pub fn find_marker(id: Id, clip: Option<Id>, t: &Timeline) -> Option<Marker> {
        if let Some(clip) = clip {
            return t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips().iter())
                .find(|c| c.id == clip)?
                .markers
                .as_ref()?
                .iter()
                .find(|m| m.id == id)
                .cloned();
        }
        t.markers.iter().find(|m| m.id == id).cloned()
    }

    /// The marker sheet's rows: Name, Color, Duration (sequence markers only), Comment.
    pub fn marker_form(m: &Marker, is_clip: bool, frame_duration: Time) -> ShellForm {
        let titles: Vec<String> = COLORS.iter().map(|c| color_title(*c)).collect();
        let mut rows = vec![
            Row::field("name", "Name", &m.name),
            // the kit's row of 8 dots; the names stay for the screen reader
            Row::segmented(
                "color",
                "Color",
                &titles.iter().map(String::as_str).collect::<Vec<_>>(),
                COLORS.iter().position(|c| *c == m.color).unwrap_or(0) as i64,
                0.0,
            ),
        ];
        if !is_clip {
            rows.push(Row::field("duration", "Duration", &MarkersPanelModel::timecode(m.duration, frame_duration)));
        }
        rows.push(Row::field("comment", "Comment", &m.comment));
        let mut form = ShellForm::new(rows);
        form.dot_rows.insert("color".to_string(), COLORS.iter().map(|c| DrawTheme::marker(*c).rgb_hex()).collect());
        form
    }

    pub(crate) fn marker_dialog(id: Id, clip: Option<Id>, session: &EditorSession) -> Option<ShellDialog> {
        let t = session.active_timeline()?;
        let m = Self::find_marker(id, clip, t)?;
        let mut d = ShellDialog::new(if clip.is_none() { "Marker" } else { "Clip Marker" }, "");
        d.form = Some(Box::new(Self::marker_form(&m, clip.is_some(), t.frame_duration())));
        d.add_button("OK", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.add_button("Delete Marker", SQDialogRole::Destructive, true);
        // art.html 18: red text, no fill
        d.ghost_buttons.insert(2);
        Some(d)
    }

    /// OK writes name, color, comment (and duration for sequence markers) as one undo step; Delete Marker removes it.
    pub fn apply_marker_dialog(
        f: &dyn DialogForm,
        r: SQDialogResponse,
        id: Id,
        clip: Option<Id>,
        session: &mut EditorSession,
    ) {
        let Some(t) = session.active_timeline() else { return };
        let Some(m) = Self::find_marker(id, clip, t) else { return };
        let frame_duration = t.frame_duration();
        if r == SQDialogResponse::THIRD {
            match clip {
                Some(clip) => session.delete_clip_marker(id, clip),
                None => session.delete_marker(id),
            }
            return;
        }
        if r != SQDialogResponse::FIRST {
            return;
        }
        let name = f.text("name").unwrap_or_else(|| m.name.clone());
        let comment = f.text("comment").unwrap_or_else(|| m.comment.clone());
        let color = f
            .index("color")
            .and_then(|i| usize::try_from(i).ok())
            .and_then(|i| COLORS.get(i).copied())
            .unwrap_or(m.color);
        match clip {
            Some(clip) => session.edit_clip_marker(id, clip, &name, color, &comment),
            None => {
                let dur = f
                    .text("duration")
                    .and_then(|s| MarkersPanelModel::parse_timecode(&s, frame_duration))
                    .unwrap_or(m.duration);
                session.edit_marker_with_duration(id, &name, color, &comment, dur);
            }
        }
    }
}
