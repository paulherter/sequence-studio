//! The clip look commands that need nothing but the session (video fades, frame holds, Dynamic Zoom, blurred fill, split
//! screen, punch-in, subject mask).

use sq_core_effects::blurred_fill::{BlurredFillOptions, BlurredFillStyle};
use sq_core_effects::dynamic_zoom::ZoomEase;
use sq_core_model::{ClipEdge, TrackKind};
use sq_uikit::editor_command::EditorCommand;

use super::split_blurred::SplitScreenProblem;
use crate::EditorSession;

/// Menu enabling and execution of the look commands, shared by every shell.
pub enum EditorLookCommands {}

impl EditorLookCommands {
    // Swift: EditorLookCommands.swift:11
    pub fn handles(c: &EditorCommand) -> bool {
        matches!(
            c,
            EditorCommand::VideoFadeIn
                | EditorCommand::VideoFadeOut
                | EditorCommand::AddFrameHold
                | EditorCommand::InsertFrameHold
                | EditorCommand::DynamicZoomIn
                | EditorCommand::DynamicZoomOut
                | EditorCommand::SplitScreen(..)
                | EditorCommand::FitBlurredFill
                | EditorCommand::FitCard
                | EditorCommand::RemoveBlurredFill
                | EditorCommand::TogglePunchIn
                | EditorCommand::AddSubjectMask
        )
    }
    /// Menu enabling; `None` when `c` is not one of these.
    // Swift: EditorLookCommands.swift:20
    pub fn enabled(c: &EditorCommand, session: &EditorSession) -> Option<bool> {
        match c {
            EditorCommand::VideoFadeIn | EditorCommand::VideoFadeOut => {
                Some(!session.command_clips_for_menu(Some(TrackKind::Video)).is_empty())
            }
            EditorCommand::AddFrameHold | EditorCommand::InsertFrameHold => Some(
                session
                    .command_clips_for_menu(Some(TrackKind::Video))
                    .iter()
                    .any(|c| c.timeline().contains(session.playhead())),
            ),
            EditorCommand::SplitScreen(preset, _) => Some(session.split_screen_problem(*preset).is_none()),
            EditorCommand::FitBlurredFill | EditorCommand::FitCard | EditorCommand::RemoveBlurredFill => {
                Some(session.blurred_fill_enabled(c))
            }
            EditorCommand::TogglePunchIn => Some(session.punch_in_enabled()),
            EditorCommand::DynamicZoomIn | EditorCommand::DynamicZoomOut => Some(!session.reframe_targets().is_empty()),
            EditorCommand::AddSubjectMask => Some(session.add_subject_mask_enabled()),
            _ => None,
        }
    }
    /// The line that says why a look command (or Cut / Snap to Beats) cannot run now, for each such command that is
    /// disabled: the menu shows it under the row, so a greyed row is never silent.
    pub fn disabled_reasons(session: &EditorSession) -> Vec<(EditorCommand, String)> {
        use sq_core_graphics::split_layout::SplitLayoutPreset;
        let mut out = Vec::new();
        for c in [EditorCommand::CutToBeats, EditorCommand::SnapToBeats] {
            if let Some(why) = session.beat_edit_problem() {
                out.push((c, why.to_string()));
            }
        }
        for c in [EditorCommand::FitBlurredFill, EditorCommand::FitCard, EditorCommand::RemoveBlurredFill] {
            if Self::enabled(&c, session) == Some(false) {
                out.push((c, Self::blurred_fill_refusal(&c).to_string()));
            }
        }
        for preset in SplitLayoutPreset::ALL {
            if let Some(problem) = session.split_screen_problem(preset) {
                let why = Self::split_screen_refusal(preset, problem);
                out.extend([false, true].map(|animated| (EditorCommand::SplitScreen(preset, animated), why.clone())));
            }
        }
        out
    }

    fn blurred_fill_refusal(c: &EditorCommand) -> &'static str {
        match c {
            EditorCommand::FitBlurredFill => "Select a video clip whose shape differs from the sequence frame.",
            EditorCommand::FitCard => "Select a video clip to put on a card.",
            _ => "Select a clip that has a blurred fill.",
        }
    }

    fn split_screen_refusal(
        preset: sq_core_graphics::split_layout::SplitLayoutPreset,
        p: SplitScreenProblem,
    ) -> String {
        match p {
            SplitScreenProblem::SameTrack => "Select clips on different tracks".to_string(),
            SplitScreenProblem::TooFewClips { .. } => {
                format!("Select {} video clips on stacked tracks for a split screen.", preset.cell_count())
            }
        }
    }

    /// Runs the command. `Some("")` = done quietly, a line = status text, `None` = not one of these commands.
    // Swift: EditorLookCommands.swift:34
    pub fn run(c: &EditorCommand, session: &mut EditorSession) -> Option<String> {
        let quiet = |ok: bool, refusal: &str| Some(if ok { String::new() } else { refusal.to_string() });
        match c {
            EditorCommand::VideoFadeIn => quiet(
                session.fade_video(ClipEdge::Head, EditorSession::DEFAULT_FADE_DURATION),
                "Select a video clip to fade in.",
            ),
            EditorCommand::VideoFadeOut => quiet(
                session.fade_video(ClipEdge::Tail, EditorSession::DEFAULT_FADE_DURATION),
                "Select a video clip to fade out.",
            ),
            EditorCommand::AddFrameHold => {
                quiet(session.add_frame_hold(), "Put the playhead on a video clip to hold its frame.")
            }
            EditorCommand::InsertFrameHold => quiet(
                session.insert_frame_hold(EditorSession::DEFAULT_FRAME_HOLD_DURATION),
                "Put the playhead on a video clip to insert a frame hold.",
            ),
            EditorCommand::FitBlurredFill => quiet(
                session.apply_blurred_fill(BlurredFillStyle::Fit, &BlurredFillOptions::default()),
                Self::blurred_fill_refusal(c),
            ),
            EditorCommand::FitCard => quiet(
                session.apply_blurred_fill(BlurredFillStyle::Card, &BlurredFillOptions::default()),
                Self::blurred_fill_refusal(c),
            ),
            EditorCommand::RemoveBlurredFill => quiet(session.remove_blurred_fill(), Self::blurred_fill_refusal(c)),
            EditorCommand::DynamicZoomIn | EditorCommand::DynamicZoomOut => {
                let zoom_in = *c == EditorCommand::DynamicZoomIn;
                Some(
                    if session.apply_dynamic_zoom(zoom_in, EditorSession::DYNAMIC_ZOOM_AMOUNT, ZoomEase::EaseInOut) {
                        "Dynamic Zoom: Scale and Position keys are in Effect Controls (Dynamic Zoom)."
                    } else {
                        "Select a video clip to zoom."
                    }
                    .to_string(),
                )
            }
            EditorCommand::TogglePunchIn => quiet(session.toggle_punch_in(), "Select a video clip to punch in."),
            EditorCommand::AddSubjectMask => {
                quiet(session.add_subject_mask(), "Select a video clip without a subject mask.")
            }
            EditorCommand::SplitScreen(preset, animated) => match session.split_screen_problem(*preset) {
                Some(problem) => Some(Self::split_screen_refusal(*preset, problem)),
                None => {
                    let extra = session.split_screen_extra_clips(*preset);
                    if !session.apply_split_screen(*preset, *animated, 0.0) || extra == 0 {
                        return Some(String::new());
                    }
                    let (plural, verb) = if extra == 1 { ("clip", "was") } else { ("clips", "were") };
                    Some(format!(
                        "{} uses {} clips (lowest tracks); {extra} more selected {plural} {verb} left unchanged.",
                        preset.title(),
                        preset.cell_count()
                    ))
                }
            },
            _ => None,
        }
    }
}
