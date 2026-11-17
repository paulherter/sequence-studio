// Swift: TimelineHeaderModel.swift
//! The Fast Cut strip verbs and the timeline header bar's geometry (design v9 `.ph`), shared by the Mac header bar and the
//! drawn bar.

use sq_uikit::editor_command::EditorCommand;
use sq_uikit::keyframe_graph_geometry::Rect;
use sq_uikit::sqicon::SQIcon;

/// One verb of the Fast Cut strip: the command it runs (same path as its key), its title, icon and help.
#[derive(Clone, Debug, PartialEq)]
pub struct FastCutVerb {
    /// The command.
    pub command: EditorCommand,
    /// Shown title.
    pub title: &'static str,
    /// Icon.
    pub icon: SQIcon,
    /// Help text.
    pub help: &'static str,
}

impl FastCutVerb {
    /// Left to right; the order follows an edit: add, open a gap, move off and on the main track, group.
    pub fn all() -> Vec<FastCutVerb> {
        vec![
            FastCutVerb {
                command: EditorCommand::AppendToMainTrack,
                title: "Append",
                icon: SQIcon::ArrowRightToLine,
                help: "Adds the Source clip to the end of the main track",
            },
            FastCutVerb {
                command: EditorCommand::InsertSpacer,
                title: "Spacer",
                icon: SQIcon::SquareDashed,
                help: "Inserts an empty spacer at the playhead",
            },
            FastCutVerb {
                command: EditorCommand::LiftOffMainTrack,
                title: "Lift off",
                icon: SQIcon::ArrowUpFromLine,
                help: "Moves the selected main-track clips above the main track",
            },
            FastCutVerb {
                command: EditorCommand::PutOnMainTrack,
                title: "Put on",
                icon: SQIcon::ArrowDownToLine,
                help: "Moves the selected attached clips onto the main track",
            },
            FastCutVerb {
                command: EditorCommand::CreateStoryline,
                title: "Storyline",
                icon: SQIcon::Stack,
                help: "Groups the selected attached clips into one storyline",
            },
        ]
    }
}

/// The frames of the header bar's parts.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeaderFrames {
    /// Tabs (flexible).
    pub tabs: Rect,
    /// Playhead timecode.
    pub timecode: Rect,
    /// Snapping toggle.
    pub snap: Rect,
    /// Linked selection toggle.
    pub link: Rect,
    /// Add marker button.
    pub marker: Rect,
    /// Fit popup.
    pub fit: Rect,
    /// Normal | Fast Cut capsule, left of Fit (zero when not shown).
    pub edit_mode: Rect,
    /// The "..." menu at the right edge (22 x 22).
    pub more: Rect,
}

/// The timeline header bar's geometry (design v9 `.ph`): tabs (flexible) | edit mode capsule | timecode | Snapping,
/// Linked selection, Add marker, Fit, from the right.
pub struct TimelineHeaderLayout;

impl TimelineHeaderLayout {
    /// v9 `.ph`: 30 high, 4 pt padding left and right, 4 pt between the controls.
    pub const HEIGHT: f64 = 30.0;
    /// v9 `.ibtn.sm`: 24 x 24, radius 4.
    pub const BUTTON_WIDTH: f64 = 24.0;
    /// Height of a toggle.
    pub const TOGGLE_HEIGHT: f64 = 24.0;
    /// Space between controls.
    pub const SPACING: f64 = 4.0;
    /// Left padding.
    pub const LEFT_PADDING: f64 = 4.0;
    /// Right padding.
    pub const RIGHT_PADDING: f64 = 4.0;
    /// v9 timecode: 8 pt before the first button.
    pub const GROUP_GAP: f64 = 8.0;
    /// v9 flat popup "Fit": 10 pt, label, 8 pt, 12 pt chevron, 8 pt.
    pub const FIT_WIDTH: f64 = 56.0;
    /// The popup's width for a label `label_width` wide: never less than [`Self::FIT_WIDTH`], so a longer translation
    /// ("Einpassen") grows the button instead of being cut to its first letters.
    pub fn fit_width(label_width: f64) -> f64 {
        (10.0 + label_width.ceil() + 8.0 + 12.0 + 8.0).max(Self::FIT_WIDTH)
    }
    /// Playhead timecode ("00:00:15:12", 11 pt) left of the buttons.
    pub const TIMECODE_WIDTH: f64 = 72.0;
    /// The edit mode capsule's height (`Theme.Metrics.capsule`).
    pub const CAPSULE_HEIGHT: f64 = 22.0;
    /// The "..." button of the header (spec 9: panel headers end in a 22 x 22 menu).
    pub const MORE_SIZE: f64 = 22.0;

    /// The header bar: tabs (flexible) | Normal capsule, Fit, "..." from the right. The timecode, Snapping, Linked
    /// selection and Marker sit in the cell above the track heads, which the bar places itself (`set_cell_origin`): they
    /// are empty here. The capsule is always there (decision 2026-10-10), so the mode shows and one click changes it.
    pub fn frames(width: f64, height: f64, mode_width: f64, fit_width: f64, shows_edit_mode: bool) -> HeaderFrames {
        let mut x = width - Self::RIGHT_PADDING;
        let mut place = |w: f64, h: f64| -> Rect {
            x -= w;
            let r = Rect::new(x, ((height - h) / 2.0).round(), w, h);
            x -= Self::SPACING;
            r
        };
        let more = place(Self::MORE_SIZE, Self::MORE_SIZE);
        let fit = place(fit_width.max(Self::FIT_WIDTH), Self::TOGGLE_HEIGHT);
        let edit_mode =
            if shows_edit_mode { place(mode_width, Self::CAPSULE_HEIGHT) } else { Rect::new(0.0, 0.0, 0.0, 0.0) };
        let tabs_right = (x + Self::SPACING - Self::GROUP_GAP).max(Self::LEFT_PADDING);
        let none = Rect::new(0.0, 0.0, 0.0, 0.0);
        HeaderFrames {
            tabs: Rect::new(Self::LEFT_PADDING, 0.0, tabs_right - Self::LEFT_PADDING, height),
            timecode: none,
            snap: none,
            link: none,
            marker: none,
            fit,
            edit_mode,
            more,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controls_are_placed_from_the_right_without_overlap() {
        let f = TimelineHeaderLayout::frames(800.0, 30.0, 70.0, 56.0, true);
        assert_eq!(f.more.max_x(), 796.0);
        assert!(f.fit.max_x() < f.more.min_x() && f.edit_mode.max_x() < f.fit.min_x());
        assert!(f.tabs.max_x() <= f.edit_mode.min_x());
        assert_eq!((f.more.height, f.more.min_y()), (22.0, 4.0));
        assert_eq!(f.fit.min_y(), 3.0);
        let hidden = TimelineHeaderLayout::frames(800.0, 30.0, 70.0, 56.0, false);
        assert_eq!(hidden.edit_mode, Rect::new(0.0, 0.0, 0.0, 0.0));
        assert!(hidden.tabs.max_x() > f.tabs.max_x());
    }

    #[test]
    fn a_long_fit_label_widens_the_popup_instead_of_being_cut() {
        assert_eq!(TimelineHeaderLayout::fit_width(14.0), TimelineHeaderLayout::FIT_WIDTH);
        let w = TimelineHeaderLayout::fit_width(52.0);
        assert!(w >= 10.0 + 52.0 + 8.0 + 12.0 + 8.0);
        let f = TimelineHeaderLayout::frames(800.0, 30.0, 70.0, w, true);
        assert_eq!(f.fit.width, w);
        assert!(f.edit_mode.max_x() < f.fit.min_x());
    }

    #[test]
    fn fast_cut_verbs_keep_their_order() {
        let titles: Vec<&str> = FastCutVerb::all().iter().map(|v| v.title).collect();
        assert_eq!(titles, vec!["Append", "Spacer", "Lift off", "Put on", "Storyline"]);
    }
}
