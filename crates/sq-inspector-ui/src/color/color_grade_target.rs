// Swift: Color/ColorGradeTarget.swift
//! What the Color panel, the eyedropper and Auto work on, and which clip the panel grades.

use super::color_clip_row::ColorClipRow;
use sq_core_color::{ClipGradeExt, ClipGradeLinksExt, ProjectGradeLinksExt};
use sq_core_edit::color_grade_targets::{ClipGradeTargetsExt, ProjectGradeTargetsExt, TimelineGradeTargetsExt};
use sq_core_effects::adjustment_clip::ClipAdjustmentExt;
use sq_core_model::{Clip, Project, Timeline, TrackKind};
use sq_core_project::sequence_format_presets::TimelinePrimaryClipExt;
use sq_core_time::{Id, Time};
use std::collections::{BTreeMap, BTreeSet};

/// What the Color panel, the eyedropper and Auto work on.
#[derive(Clone, Debug, PartialEq)]
pub enum ColorTargetResolution {
    Clip(Id),
    /// The whole sequence; `layer` is nil until the first edit creates the Timeline grade layer.
    Sequence {
        timeline: Id,
        layer: Option<Id>,
    },
    /// Nothing gradable: one sentence saying why (shown instead of an empty panel).
    Message(String),
}

/// Which clip the Color panel grades (pure, tested in ColorTargetBarTests / ColorClipsPanelTests).
///
/// Sync rule between the Clips panel and the timeline (DECISIONS 2026-10-03 "Color page + timeline header"):
/// - Picking a source row selects one of its cuts in the timeline (the host moves the playhead onto it when it is
///   elsewhere, so the monitor and scopes show what is graded). Picking "Whole sequence" selects the Timeline grade layer
///   (or nothing before it exists).
/// - Selecting one picture clip in the timeline targets it (also out of "Whole sequence"); selecting the Timeline grade
///   layer targets the whole sequence. An empty timeline selection keeps the target, so clicking into empty timeline
///   space never drops what is being graded.
/// - Audio, several clips, text/graphics or a nested sequence selected in the timeline give a one-line explanation
///   instead of the panel (not while "Whole sequence" is targeted); picking in the list ends that.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct ColorTargetState {
    /// "Whole sequence" is targeted (the Timeline grade).
    whole_sequence: bool,
    /// The clip the Clips panel points at.
    pick: Option<Id>,
    /// Why the timeline selection cannot be graded (nil = it can, or nothing is selected).
    notice: Option<String>,
}

impl ColorTargetState {
    pub const AUDIO_NOTICE: &'static str =
        "Audio clips have no picture. Select a video clip in the timeline, or a source in Clips.";
    pub const NESTED_NOTICE: &'static str =
        "A nested sequence is graded inside: open it and grade its clips, or use an adjustment layer above it.";
    pub const GENERATOR_NOTICE: &'static str =
        "Text and graphics take no grade. Their colors are set in Effect Controls.";
    pub const NOTHING_NOTICE: &'static str = "Select a clip in the timeline to grade it.";
    pub const EMPTY_NOTICE: &'static str = "This sequence has no video clips yet.";
    pub const NO_SEQUENCE_NOTICE: &'static str = "Open a sequence to grade it.";

    pub fn new(pick: Option<Id>) -> ColorTargetState {
        ColorTargetState { whole_sequence: false, pick, notice: None }
    }

    pub fn whole_sequence(&self) -> bool {
        self.whole_sequence
    }

    pub fn pick(&self) -> Option<Id> {
        self.pick
    }

    pub fn notice(&self) -> Option<&str> {
        self.notice.as_deref()
    }

    pub fn multi_notice(n: usize) -> String {
        format!(
            "{n} clips selected. Pick one source in Clips to grade it; Paste Grade (\u{2318}V) applies the copied grade to all of them."
        )
    }

    /// The empty state (title, hint) the Color panel shows for a resolution message (INTERACTION-AUDIT §10): what is
    /// missing as the title, the message itself as the hint.
    pub fn empty_state(message: &str) -> (String, String) {
        let m = message.to_string();
        match message {
            Self::NO_SEQUENCE_NOTICE => ("No sequence open".to_string(), m),
            Self::EMPTY_NOTICE => {
                ("No video clips".to_string(), "Add clips to the sequence to grade them.".to_string())
            }
            Self::NOTHING_NOTICE => ("No clip selected".to_string(), m),
            Self::AUDIO_NOTICE => ("Audio has no picture".to_string(), m),
            Self::NESTED_NOTICE => ("Nested sequence".to_string(), m),
            Self::GENERATOR_NOTICE => ("Text or graphic selected".to_string(), m),
            _ => (
                (if message.contains("clips selected") { "Several clips selected" } else { "No clip selected" })
                    .to_string(),
                m,
            ),
        }
    }

    /// The timeline selection changed.
    pub fn selection_changed(&mut self, selection: &BTreeSet<Id>, timeline: Option<&Timeline>) {
        let Some(timeline) = timeline.filter(|_| !selection.is_empty()) else {
            self.notice = None;
            return;
        };
        let Some(c) = timeline.primary_clip(selection) else {
            if self.whole_sequence {
                return;
            }
            let pictures = timeline
                .tracks
                .iter()
                .flat_map(|t| t.clips())
                .filter(|c| selection.contains(&c.id) && c.kind == TrackKind::Video)
                .count();
            self.notice =
                Some(if pictures == 0 { Self::AUDIO_NOTICE.to_string() } else { Self::multi_notice(pictures) });
            return;
        };
        if c.is_sequence_grade() {
            self.whole_sequence = true;
            self.notice = None;
            return;
        }
        if c.accepts_color() {
            self.pick = Some(c.id);
            self.whole_sequence = false;
            self.notice = None;
            return;
        }
        if self.whole_sequence {
            return;
        }
        self.notice = Some(
            if c.kind == TrackKind::Audio {
                Self::AUDIO_NOTICE
            } else if c.is_nested() {
                Self::NESTED_NOTICE
            } else {
                Self::GENERATOR_NOTICE
            }
            .to_string(),
        );
    }

    /// A clip (a source row's cut) was picked in the Clips panel (the host also selects it in the timeline).
    pub fn list_picked(&mut self, id: Id) {
        self.pick = Some(id);
        self.notice = None;
        self.whole_sequence = false;
    }

    /// "Whole sequence" was picked in the Clips panel.
    pub fn whole_sequence_picked(&mut self) {
        self.whole_sequence = true;
        self.notice = None;
    }

    pub fn resolve(&self, timeline: Option<&Timeline>) -> ColorTargetResolution {
        let Some(timeline) = timeline else {
            return ColorTargetResolution::Message(Self::NO_SEQUENCE_NOTICE.to_string());
        };
        let layer = || timeline.sequence_grade_clip().map(|c| c.id);
        if self.whole_sequence {
            return ColorTargetResolution::Sequence { timeline: timeline.id, layer: layer() };
        }
        if let Some(n) = &self.notice {
            return ColorTargetResolution::Message(n.clone());
        }
        if let Some(pick) = self.pick
            && let Some(c) = timeline.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == pick)
            && c.accepts_color()
            && !c.is_sequence_grade()
        {
            return ColorTargetResolution::Clip(pick);
        }
        // Nothing picked or selected: the Whole Sequence is the visible default target (the chip says so; the layer is
        // created on the first change, DECISIONS 2026-10-13 App audit).
        if ColorSourceListItem::items(Some(timeline), None).is_empty() {
            return ColorTargetResolution::Message(Self::EMPTY_NOTICE.to_string());
        }
        ColorTargetResolution::Sequence { timeline: timeline.id, layer: layer() }
    }

    /// "On screen: X" when the Program monitor does not show `target` at `playhead` (nil = it does). The picture on screen
    /// is the topmost visible clip there; adjustment layers and the Timeline grade show no picture of their own.
    pub fn on_screen_hint(
        target: &ColorTargetResolution,
        timeline: Option<&Timeline>,
        playhead: Time,
    ) -> Option<String> {
        let timeline = timeline?;
        let ColorTargetResolution::Clip(id) = target else { return None };
        let clip = timeline.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == *id)?;
        if clip.timeline().contains(playhead) {
            return None;
        }
        for track in timeline.tracks.iter().rev() {
            if track.kind == TrackKind::Video
                && track.is_visible
                && let Some(c) =
                    track.clips().iter().find(|c| c.timeline().contains(playhead) && c.is_enabled && !c.is_adjustment())
            {
                return Some(format!("On screen: {}", c.name));
            }
        }
        Some("On screen: no clip".to_string())
    }
}

/// One row of the Clips panel: a source file of the active sequence (all its cuts share one grade while Linked), or an
/// adjustment layer (a row of its own: it has no source).
#[derive(Clone, Debug, PartialEq)]
pub struct ColorSourceListItem {
    /// The source file (an adjustment layer's own id).
    pub media: Id,
    /// The file name from the project's media, else the first cut's clip name.
    pub name: String,
    /// The cuts of this source in timeline order (start, then the upper track first).
    pub clips: Vec<Id>,
    /// Any cut carries a grade.
    pub graded: bool,
    pub is_adjustment: bool,
    /// The grade state of its cuts (`ColorClipRow::grade_text`), "Mixed grades" when they differ.
    pub grade_text: String,
}

impl ColorSourceListItem {
    /// The sources of `timeline`'s picture clips that take color, in order of their first cut. The Timeline grade layer
    /// is not listed (it is the "Whole sequence" row).
    pub fn items(timeline: Option<&Timeline>, project: Option<&Project>) -> Vec<ColorSourceListItem> {
        let Some(timeline) = timeline else { return Vec::new() };
        let mut cuts: Vec<(Time, i64, &Clip)> = Vec::new();
        for (k, tr) in timeline.tracks.iter().enumerate() {
            if tr.kind != TrackKind::Video {
                continue;
            }
            for c in tr.clips() {
                if c.accepts_color() && !c.is_sequence_grade() {
                    cuts.push((c.start, -(k as i64), c));
                }
            }
        }
        cuts.sort_by(|a, b| if a.0 != b.0 { a.0.cmp(&b.0) } else { a.1.cmp(&b.1) });
        let mut out: Vec<ColorSourceListItem> = Vec::new();
        let mut index: BTreeMap<Id, usize> = BTreeMap::new();
        for (_, _, c) in cuts {
            if let Some(&i) = index.get(&c.media) {
                out[i].clips.push(c.id);
                if !c.color_grade_effects().is_empty() {
                    out[i].graded = true;
                }
                if Self::grade_text_of(c) != out[i].grade_text {
                    out[i].grade_text = "Mixed grades".to_string();
                }
                continue;
            }
            index.insert(c.media, out.len());
            let file = if c.is_adjustment() {
                None
            } else {
                project.and_then(|p| p.media.iter().find(|m| m.id == c.media)).map(|m| m.name.clone())
            };
            out.push(ColorSourceListItem {
                media: c.media,
                name: file.unwrap_or_else(|| c.name.clone()),
                clips: vec![c.id],
                graded: !c.color_grade_effects().is_empty(),
                is_adjustment: c.is_adjustment(),
                grade_text: Self::grade_text_of(c),
            });
        }
        out
    }

    pub(crate) fn grade_text_of(c: &Clip) -> String {
        ColorClipRow::grade_text(!c.color_grade_effects().is_empty(), c.color_graph().as_ref()).to_string()
    }

    /// The cut a pick of this row grades: `picked` when it is one of them, else the first cut that is "Linked" (its grade
    /// is the source's), else the first cut.
    pub fn clip_to_grade(&self, picked: Option<Id>, project: &Project) -> Id {
        if let Some(p) = picked.filter(|p| self.clips.contains(p)) {
            return p;
        }
        self.clips.iter().copied().find(|c| project.is_grade_linked_to_source(*c)).unwrap_or(self.clips[0])
    }
}

/// The clips the timeline outlines on the Color page: the one being graded plus every clip that shares its grade (its
/// grade link, and while "Linked" every other use of its source). The Timeline grade layer outlines itself only.
pub struct ColorGradeOutline;

impl ColorGradeOutline {
    pub fn clips(target: &ColorTargetResolution, project: &Project) -> BTreeSet<Id> {
        match target {
            ColorTargetResolution::Message(_) => BTreeSet::new(),
            ColorTargetResolution::Sequence { layer, .. } => layer.iter().copied().collect(),
            ColorTargetResolution::Clip(id) => {
                let mut out = BTreeSet::from([*id]);
                out.extend(project.grade_link_members(*id));
                if project.is_grade_linked_to_source(*id) {
                    let media = project
                        .timelines
                        .iter()
                        .flat_map(|t| t.tracks.iter())
                        .flat_map(|tr| tr.clips())
                        .find(|c| c.id == *id)
                        .map(|c| c.media);
                    if let Some(media) = media {
                        for t in project.timelines.iter() {
                            for tr in t.tracks.iter() {
                                for c in tr.clips() {
                                    if c.media == media
                                        && c.is_source_gradeable()
                                        && project.is_grade_linked_to_source(c.id)
                                    {
                                        out.insert(c.id);
                                    }
                                }
                            }
                        }
                    }
                }
                out
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_timeline_asks_to_open_a_sequence() {
        let s = ColorTargetState::default();
        assert_eq!(s.resolve(None), ColorTargetResolution::Message(ColorTargetState::NO_SEQUENCE_NOTICE.to_string()));
    }

    #[test]
    fn empty_states_name_what_is_missing() {
        assert_eq!(ColorTargetState::empty_state(ColorTargetState::NO_SEQUENCE_NOTICE).0, "No sequence open");
        assert_eq!(
            ColorTargetState::empty_state(ColorTargetState::EMPTY_NOTICE).1,
            "Add clips to the sequence to grade them."
        );
        assert_eq!(ColorTargetState::empty_state(ColorTargetState::AUDIO_NOTICE).0, "Audio has no picture");
        assert_eq!(ColorTargetState::empty_state(&ColorTargetState::multi_notice(3)).0, "Several clips selected");
        assert_eq!(ColorTargetState::empty_state("other").0, "No clip selected");
    }

    #[test]
    fn picking_from_the_list_ends_a_notice_and_the_whole_sequence() {
        let mut s = ColorTargetState::default();
        s.whole_sequence_picked();
        assert!(s.whole_sequence());
        s.list_picked(Id::from_u128(7));
        assert!(!s.whole_sequence());
        assert_eq!(s.pick(), Some(Id::from_u128(7)));
        assert_eq!(s.notice(), None);
    }

    #[test]
    fn an_empty_selection_keeps_the_target_and_clears_the_notice() {
        let mut s = ColorTargetState::new(Some(Id::from_u128(1)));
        s.selection_changed(&BTreeSet::new(), None);
        assert_eq!(s.pick(), Some(Id::from_u128(1)));
        assert_eq!(s.notice(), None);
    }

    #[test]
    fn the_outline_of_a_message_is_empty_and_of_the_sequence_is_its_layer() {
        let p = Project::new(Id::from_u128(1), "p", Vec::new(), Vec::new());
        assert!(ColorGradeOutline::clips(&ColorTargetResolution::Message(String::new()), &p).is_empty());
        let l = Id::from_u128(5);
        let t = ColorTargetResolution::Sequence { timeline: Id::from_u128(1), layer: Some(l) };
        assert_eq!(ColorGradeOutline::clips(&t, &p), BTreeSet::from([l]));
    }
}
