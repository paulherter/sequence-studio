//! The clip right-click menu, regrouped (redesign R5a): the common rows stay on the first level, the rare ones sit in the
//! Speed, Audio, Frame, Color, Arrange and Save submenus. Same rows and actions as the flat list, only moved; a row the plan
//! does not name stays on the first level, in its old order, above the plan. Only "New Color Matte…" is dropped (see below).

use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind};

/// One planned entry: a row (the first title that exists wins), a submenu, or a separator.
enum Plan {
    Row(&'static [&'static str]),
    Sub(&'static str, Vec<Plan>),
    Sep,
}

use Plan::{Row, Sep, Sub};

fn plan(audio_only: bool, has_grades: bool) -> Vec<Plan> {
    let mut p = vec![
        Row(&["Cut"]),
        Row(&["Copy"]),
        Row(&["Paste"]),
        Sub("Paste Special", vec![Row(&["Paste Insert"]), Row(&["Paste Settings"])]),
        Sep,
        Row(&["Disable", "Enable"]),
        Row(&["Unlink", "Link"]),
        Sep,
        Sub(
            "Speed",
            vec![
                Row(&["Speed…"]),
                Row(&["Reverse Clip"]),
                Sep,
                Row(&["Show Speed Ramp"]),
                Row(&["Speed Ramp Presets"]),
            ],
        ),
        Sub(
            "Audio",
            vec![
                Row(&["Audio Gain…"]),
                Row(&["Remove Silences…"]),
                Row(&["Remove Filler Words"]),
                Row(&["Fit Music to Length…"]),
            ],
        ),
    ];
    if !audio_only {
        p.push(Sub("Frame", vec![Row(&["Fit to Frame"]), Row(&["Fill Frame"]), Row(&["Punch In Cuts…"])]));
    }
    if has_grades {
        p.push(Sub(
            "Color",
            vec![
                Row(&["Grade From Previous Clip"]),
                Row(&["Grade From Clip Before Previous"]),
                Row(&["Grade All From This Camera"]),
            ],
        ));
    }
    p.extend([
        Sub(
            "Arrange",
            vec![
                Row(&["Group"]),
                Row(&["Ungroup"]),
                Row(&["Bundle"]),
                Row(&["Unbundle"]),
                Sep,
                Row(&["Combine…"]),
                Row(&["Unnest"]),
                Row(&["Extend to Sequence End"]),
                Row(&["Use Take for In to Out"]),
                Row(&["Keep Intro and Outro When Trimmed"]),
            ],
        ),
        Row(&["Label"]),
        Sep,
        Row(&["Rename…"]),
        Row(&["Add Clip Marker"]),
        Row(&["Reveal in Project"]),
        Row(&["Edit Original"]),
        Sub(
            "Save",
            vec![
                Row(&["Save as Preset…"]),
                Row(&["Save to Library…"]),
                Row(&["Save as Template…"]),
                Sep,
                Row(&["Make Graphic"]),
            ],
        ),
        Sep,
        Row(&["Delete"]),
        Row(&["Ripple Delete"]),
    ]);
    p
}

fn take(pool: &mut Vec<SQMenuItem>, titles: &[&str]) -> Option<SQMenuItem> {
    let at = pool.iter().position(|i| i.kind != SQMenuItemKind::Separator && titles.contains(&i.title.as_str()))?;
    Some(pool.remove(at))
}

fn build(pool: &mut Vec<SQMenuItem>, plan: &[Plan]) -> Vec<SQMenuItem> {
    let mut out: Vec<SQMenuItem> = Vec::new();
    for entry in plan {
        match entry {
            Row(titles) => out.extend(take(pool, titles)),
            Sep => out.push(SQMenuItem::separator()),
            Sub(title, inner) => {
                let rows = tidy(build(pool, inner));
                if rows.is_empty() {
                    continue;
                }
                let mut parent = SQMenuItem::new(title);
                parent.is_enabled = rows.iter().any(|r| r.is_enabled);
                parent.submenu = Some(rows);
                out.push(parent);
            }
        }
    }
    out
}

/// Drops leading, trailing and doubled separators.
fn tidy(items: Vec<SQMenuItem>) -> Vec<SQMenuItem> {
    let mut out: Vec<SQMenuItem> = Vec::new();
    for i in items {
        if i.kind == SQMenuItemKind::Separator && out.last().is_none_or(|l| l.kind == SQMenuItemKind::Separator) {
            continue;
        }
        out.push(i);
    }
    while out.last().is_some_and(|l| l.kind == SQMenuItemKind::Separator) {
        out.pop();
    }
    out
}

/// Regroups the flat clip menu `rows`. Rows of the plan that are missing are skipped; separators in `rows` are dropped (the
/// plan has its own).
///
/// With `combine_first` (two or more clips selected) "Combine…" becomes the first row, followed by its own separator, and
/// leaves the Arrange submenu: the row is moved, never shown twice.
pub fn regroup_clip_menu(rows: Vec<SQMenuItem>, combine_first: bool) -> Vec<SQMenuItem> {
    let enabled = |t: &str| rows.iter().any(|r| r.title == t && r.is_enabled);
    let audio_only = enabled("Audio Gain…") && !enabled("Fit to Frame");
    let has_grades = rows.iter().any(|r| r.title == "Grade From Previous Clip");
    // "New Color Matte…" leaves the clip menu (it is not about a clip); it stays in Sequence > New > Layer and in the
    // Project panel's options menu.
    let mut pool: Vec<SQMenuItem> =
        rows.into_iter().filter(|r| r.kind != SQMenuItemKind::Separator && r.title != "New Color Matte…").collect();
    let combine = if combine_first { take(&mut pool, &["Combine…"]) } else { None };
    let planned = build(&mut pool, &plan(audio_only, has_grades));
    // Rows the plan does not name (sync, angle and edit-point rows, "New Color Matte…") keep their place above the plan.
    let mut out = pool;
    if !out.is_empty() {
        out.push(SQMenuItem::separator());
    }
    out.extend(planned);
    let mut out = tidy(out);
    if let Some(c) = combine {
        out.insert(0, SQMenuItem::separator());
        out.insert(0, c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(titles: &[&str]) -> Vec<SQMenuItem> {
        titles.iter().map(|t| SQMenuItem::new(t)).collect()
    }

    fn names(items: &[SQMenuItem]) -> Vec<&str> {
        items.iter().map(|i| i.title.as_str()).collect()
    }

    #[test]
    fn the_first_level_keeps_the_common_rows_and_moves_the_rest_into_submenus() {
        let rows = flat(&[
            "Cut",
            "Copy",
            "Paste",
            "Paste Insert",
            "Paste Settings",
            "Unlink",
            "Disable",
            "Group",
            "Speed…",
            "Show Speed Ramp",
            "Fit to Frame",
            "Label",
            "Rename…",
            "Edit Original",
            "Save as Preset…",
            "Delete",
            "Ripple Delete",
        ]);
        let out = regroup_clip_menu(rows, false);
        let top: Vec<&str> =
            out.iter().filter(|i| i.kind != SQMenuItemKind::Separator).map(|i| i.title.as_str()).collect();
        assert_eq!(
            top,
            [
                "Cut",
                "Copy",
                "Paste",
                "Paste Special",
                "Disable",
                "Unlink",
                "Speed",
                "Frame",
                "Arrange",
                "Label",
                "Rename…",
                "Edit Original",
                "Save",
                "Delete",
                "Ripple Delete"
            ]
        );
        let paste = out.iter().find(|i| i.title == "Paste Special").and_then(|i| i.submenu.as_ref()).unwrap();
        assert_eq!(names(paste), ["Paste Insert", "Paste Settings"]);
    }

    #[test]
    fn combine_is_the_first_row_with_two_clips_and_only_there() {
        let rows = || flat(&["Match Angle", "Cut", "Group", "Combine…", "Unnest", "Delete"]);
        let out = regroup_clip_menu(rows(), true);
        assert_eq!(out[0].title, "Combine…");
        assert_eq!(out[1].kind, SQMenuItemKind::Separator);
        assert_eq!(out[2].title, "Match Angle");
        fn count(items: &[SQMenuItem]) -> usize {
            items.iter().map(|i| usize::from(i.title == "Combine…") + i.submenu.as_deref().map_or(0, count)).sum()
        }
        assert_eq!(count(&out), 1, "moved, not duplicated");
        // One clip: Combine… stays in Arrange.
        let one = regroup_clip_menu(rows(), false);
        assert_ne!(one[0].title, "Combine…");
        assert_eq!(count(&one), 1);
    }

    #[test]
    fn no_row_is_lost_and_unnamed_rows_stay_on_top() {
        let rows = flat(&[
            "Match Angle",
            "Cut",
            "Sync Clips",
            "Delete",
            "Speed Ramp Presets",
            "Reverse Clip",
            "New Color Matte…",
        ]);
        let out = regroup_clip_menu(rows, false);
        fn count(items: &[SQMenuItem]) -> usize {
            items
                .iter()
                .filter(|i| i.kind != SQMenuItemKind::Separator)
                .map(|i| if let Some(s) = &i.submenu { count(s) } else { 1 })
                .sum()
        }
        assert_eq!(count(&out), 6, "every row but New Color Matte survives");
        assert_eq!(out[0].title, "Match Angle");
        assert_eq!(out[1].title, "Sync Clips");
    }

    #[test]
    fn an_audio_only_selection_has_no_frame_submenu_and_grades_gain_a_color_submenu() {
        let mut audio = flat(&["Audio Gain…", "Fit to Frame", "Fill Frame"]);
        audio[1].is_enabled = false;
        audio[2].is_enabled = false;
        let out = regroup_clip_menu(audio, false);
        assert!(out.iter().all(|i| i.title != "Frame"));
        let out = regroup_clip_menu(flat(&["Grade From Previous Clip", "Grade All From This Camera"]), false);
        let color = out.iter().find(|i| i.title == "Color").and_then(|i| i.submenu.as_ref()).unwrap();
        assert_eq!(names(color), ["Grade From Previous Clip", "Grade All From This Camera"]);
    }
}
