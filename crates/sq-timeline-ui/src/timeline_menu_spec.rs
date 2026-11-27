// Swift: TimelineMenuSpec.swift
//! Pure spec of the timeline context menu (portable: the Windows panel builds the same rows) in Premiere's order, plus
//! the SQ menu row builder.

use sq_core_audio::caption_handover::TimelineCaptionsExt;
use sq_core_edit::timeline_beat_markers::BEAT_MARKER_NAME;
use sq_core_edit::timeline_comping::TimelineCompingExt;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_title_block::TitleBlockExt;
use sq_core_effects::adjustment_clip::ClipAdjustmentExt;
use sq_core_effects::speed_ramp_preset::SpeedRampPreset;
use sq_core_graphics::graphics_make_graphic::TimelineMakeGraphicExt;
use sq_core_model::{Clip, LabelColor, Timeline, TrackKind};
use sq_core_project::sequence_format_presets::TimelinePrimaryClipExt;
use sq_core_time::{Id, Time};
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::sqmenu_model::{SQMenuIcon, SQMenuItem, SQMenuShortcut};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

/// What a context-menu item asks the host to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TimelineMenuAction {
    Cut,
    Copy,
    Paste,
    PasteInsert,
    PasteAttributes,
    Delete,
    RippleDelete,
    Unlink,
    Link,
    Nest,
    Group,
    Ungroup,
    Rename,
    /// Bundle / Unbundle (selection groups) and Edit Original (open the source file in its default app).
    Bundle,
    Unbundle,
    EditOriginal,
    /// Reveal in Project: selects the clip's media in the Project panel.
    RevealInProject,
    /// Unnest: replaces a nested sequence clip by its content.
    Unnest,
    /// Add Clip Marker: a flag on the selected clip at the pointer (the host knows where).
    AddClipMarker,
    /// Enable / Disable Clip.
    Enable,
    /// Use Take for In to Out: this clip's take plays in the In..Out range, the other takes there are off.
    UseTake,
    SetToFrameSize,
    SetToFillFrame,
    EditCaption,
    SplitCaption,
    MergeCaptions,
    /// Clip > Speed/Duration.
    Speed,
    /// Clip > Reverse Clip.
    Reverse,
    /// Clip > Audio Options > Audio Gain, and the short-form pause remover.
    AudioGain,
    RemoveSilences,
    /// Short-form helpers: filler-word remover and zoom alternation over the shots.
    RemoveFillerWords,
    PunchInCuts,
    /// Clip > Beat Edits > Fit Music to Length… (one audio clip).
    FitMusicToLength,
    /// Show Clip Keyframes > Time Remapping (the speed band on the clip).
    TimeRemapping,
    /// Opens the label color submenu (its choices go to `make_sq_items`' `label_handler`).
    Label,
    /// Saves the one selected video clip's Motion/Opacity and effects as a Library preset.
    SaveAsPreset,
    SaveTitleBlock,
    /// Text or shape clip -> graphics clip with one layer.
    MakeGraphic,
    /// New Color Matte… at the playhead (the dialog is the host's).
    NewColorMatte,
    /// New Adjustment Layer at the playhead, 5 s, on the track above the top clip there.
    NewAdjustmentLayer,
    /// Save the selected title layers as a template, and the zones toggle (check mark).
    SaveTemplate,
    ToggleZones,
    /// Clip > Speed Ramp Presets (same command as the Clip menu entry).
    SpeedRamp(SpeedRampPreset, bool),
    /// Adjustment Layers: the layer follows the end of the sequence (check mark when on).
    ExtendToSequenceEnd,
    /// Empty track space: "Place Sequences as Clips" toggle (check mark when on).
    TogglePlaceSequencesAsClips,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TimelineMenuItem {
    pub action: TimelineMenuAction,
    pub title: String,
    pub is_enabled: bool,
    /// A separator line goes above this item.
    pub separator_before: bool,
    pub key: String,
    /// Modifiers of `key`.
    pub key_modifiers: KeyModifiers,
    /// Shows a check mark (toggle items).
    pub is_checked: bool,
    /// Title of the submenu this item lives in (`None` = top level). Items of one submenu are listed together.
    pub submenu: Option<String>,
}

impl TimelineMenuItem {
    /// An item without a key.
    pub fn new(action: TimelineMenuAction, title: &str, enabled: bool) -> Self {
        Self::keyed(action, title, enabled, false, "", KeyModifiers::COMMAND)
    }

    pub fn keyed(
        action: TimelineMenuAction,
        title: &str,
        enabled: bool,
        separator_before: bool,
        key: &str,
        key_modifiers: KeyModifiers,
    ) -> Self {
        TimelineMenuItem {
            action,
            title: title.to_string(),
            is_enabled: enabled,
            separator_before,
            key: key.to_string(),
            key_modifiers,
            is_checked: false,
            submenu: None,
        }
    }

    /// The item's key as the menu shows it, taken from the key map (never hard-coded, so a rebinding cannot go stale).
    pub fn with_command(
        action: TimelineMenuAction,
        title: &str,
        enabled: bool,
        separator_before: bool,
        command: &EditorCommand,
        map: &CommandMap,
    ) -> Self {
        let eq = map.shown_binding_here(command).and_then(|b| Self::portable_key_equivalent(&b));
        let (key, mods) = eq.unwrap_or((String::new(), KeyModifiers::EMPTY));
        Self::keyed(action, title, enabled, separator_before, &key, mods)
    }

    /// Menu key text and modifiers of a binding; `None` for keys a menu cannot show as an equivalent.
    pub fn portable_key_equivalent(b: &KeyBinding) -> Option<(String, KeyModifiers)> {
        match b.key {
            Key::Char(c) => Some((c.to_string(), b.modifiers)),
            Key::Delete => Some(("\u{8}".to_string(), b.modifiers)),
            Key::Space => Some((" ".to_string(), b.modifiers)),
            _ => None,
        }
    }

    pub fn separator_before(mut self, on: bool) -> Self {
        self.separator_before = on;
        self
    }

    pub fn checked(mut self, on: bool) -> Self {
        self.is_checked = on;
        self
    }
}

/// Pure spec of the timeline context menu.
pub struct TimelineContextMenu;

impl TimelineContextMenu {
    /// Items for the current selection. `clipboard_has_clips` enables Paste; `groups` (the project's group sequences)
    /// enables Ungroup.
    pub fn items(
        timeline: &Timeline,
        selection: &BTreeSet<Id>,
        clipboard_has_clips: bool,
        groups: &BTreeSet<Id>,
        map: &CommandMap,
    ) -> Vec<TimelineMenuItem> {
        Self::items_with_captions(timeline, selection, &BTreeSet::new(), clipboard_has_clips, groups, map)
    }

    /// Like `items`, with a caption selection (a caption counts as something Delete can remove).
    pub fn items_with_captions(
        timeline: &Timeline,
        selection: &BTreeSet<Id>,
        caption_selection: &BTreeSet<Id>,
        clipboard_has_clips: bool,
        groups: &BTreeSet<Id>,
        map: &CommandMap,
    ) -> Vec<TimelineMenuItem> {
        use TimelineMenuAction as A;
        let clips: Vec<&Clip> =
            timeline.tracks.iter().flat_map(|t| t.clips()).filter(|c| selection.contains(&c.id)).collect();
        let has_clips = !clips.is_empty();
        let only_adjustments = has_clips && clips.iter().all(|c| c.is_adjustment());
        let has_groups = clips.iter().any(|c| c.sequence.is_some_and(|s| groups.contains(&s)));
        let has_nested = clips.iter().any(|c| c.angle.is_none() && c.sequence.is_some_and(|s| !groups.contains(&s)));
        let has_any = has_clips || !caption_selection.is_empty();
        let links: BTreeSet<Id> = clips.iter().filter_map(|c| c.link).collect();
        // Linking needs two or more clips that are not already one group.
        let can_link =
            clips.len() >= 2 && !(links.len() == 1 && clips.iter().all(|c| c.link == links.first().copied()));
        let cmd = |a: A, t: &str, e: bool, c: EditorCommand| TimelineMenuItem::with_command(a, t, e, false, &c, map);
        let link_item = if links.is_empty() {
            cmd(A::Link, "Link", can_link, EditorCommand::Link)
        } else {
            cmd(A::Unlink, "Unlink", true, EditorCommand::Link)
        };
        // Generators (text) have no picture size to fit.
        let has_pictures = clips.iter().any(|c| !c.is_generator() && c.kind == TrackKind::Video);
        let has_audio = clips.iter().any(|c| c.kind == TrackKind::Audio);
        let has_caption_words = timeline.caption_tracks.iter().any(|t| t.is_visible && !t.items().is_empty());
        let can_retime = clips.iter().any(|c| Timeline::can_retime(c));
        let has_video_media = clips.iter().any(|c| Timeline::can_retime(c) && c.kind == TrackKind::Video);
        // A bundle needs two units: a linked pair counts once, and a bundle already holding the whole selection is one.
        let units: BTreeSet<Id> = clips.iter().map(|c| c.bundle.or(c.link).unwrap_or(c.id)).collect();
        let can_bundle = units.len() >= 2;
        let has_original = clips.iter().any(|c| !c.is_generator() && c.sequence.is_none());
        let single = clips.len() == 1;
        let use_take = single && timeline.in_out.is_some_and(|r| timeline.can_comp_take(clips[0].id, r));
        let media_free = timeline.is_media_free(selection);
        let mut out = vec![
            cmd(A::Cut, "Cut", has_clips, EditorCommand::Cut),
            cmd(A::Copy, "Copy", has_clips, EditorCommand::Copy),
            cmd(A::Paste, "Paste", clipboard_has_clips, EditorCommand::Paste),
            cmd(A::PasteInsert, "Paste Insert", clipboard_has_clips, EditorCommand::PasteInsert),
            cmd(A::PasteAttributes, "Paste Settings", clipboard_has_clips && has_clips, EditorCommand::PasteAttributes),
            link_item.separator_before(true),
            cmd(
                A::Enable,
                if clips.iter().any(|c| !c.is_enabled) { "Enable" } else { "Disable" },
                has_clips,
                EditorCommand::EnableClip,
            ),
            TimelineMenuItem::new(A::UseTake, "Use Take for In to Out", use_take),
            cmd(A::Group, "Group", has_clips, EditorCommand::Group).separator_before(true),
            cmd(A::Ungroup, "Ungroup", has_groups, EditorCommand::Ungroup),
            cmd(A::Bundle, "Bundle", can_bundle, EditorCommand::Bundle),
            cmd(A::Unbundle, "Unbundle", clips.iter().any(|c| c.bundle.is_some()), EditorCommand::Unbundle),
            cmd(A::Nest, "Combine…", has_clips, EditorCommand::Combine),
            cmd(A::Unnest, "Unnest", has_nested, EditorCommand::Unnest),
            cmd(A::ExtendToSequenceEnd, "Extend to Sequence End", only_adjustments, EditorCommand::ExtendToSequenceEnd)
                .checked(only_adjustments && clips.iter().all(|c| c.extends_to_end_store == Some(true))),
            cmd(A::Speed, "Speed…", can_retime, EditorCommand::SpeedDuration),
            cmd(A::Reverse, "Reverse Clip", can_retime, EditorCommand::ReverseClip),
            cmd(A::AudioGain, "Audio Gain…", has_audio, EditorCommand::AudioGain),
            TimelineMenuItem::new(A::RemoveSilences, "Remove Silences…", has_audio),
            // Same rules as the commands: filler words need a visible caption track with words, punch-in two or more shots.
            TimelineMenuItem::new(A::RemoveFillerWords, "Remove Filler Words", has_audio && has_caption_words),
            TimelineMenuItem::new(
                A::FitMusicToLength,
                "Fit Music to Length…",
                single
                    && has_audio
                    && !clips[0].is_generator()
                    && clips[0].speed.is_normal()
                    && clips[0].speed_keys.is_none()
                    && !clips[0].reversed,
            ),
            TimelineMenuItem::new(A::PunchInCuts, "Punch In Cuts…", Self::punch_in_shots(timeline, selection) >= 2),
            cmd(A::TimeRemapping, "Show Speed Ramp", has_video_media, EditorCommand::ToggleTimeRemapping),
        ];
        // The ten presets are the Clip menu's `speedRampPreset` commands; the host runs the same command.
        let has_beats = timeline.markers.iter().any(|m| m.name == BEAT_MARKER_NAME);
        out.extend(Self::speed_ramp_items(has_beats, has_video_media));
        out.extend([
            cmd(A::SetToFrameSize, "Fit to Frame", has_pictures, EditorCommand::SetToFrameSize).separator_before(true),
            cmd(A::SetToFillFrame, "Fill Frame", has_pictures, EditorCommand::SetToFillFrame),
            TimelineMenuItem::new(A::Label, "Label", has_clips).separator_before(true),
            TimelineMenuItem::new(A::Rename, "Rename…", single),
            TimelineMenuItem::new(A::AddClipMarker, "Add Clip Marker", single && clips[0].hold_frame.is_none()),
            cmd(A::EditOriginal, "Edit Original", has_original, EditorCommand::EditOriginal),
            TimelineMenuItem::new(A::RevealInProject, "Reveal in Project", has_original),
            TimelineMenuItem::new(
                A::MakeGraphic,
                "Make Graphic",
                single && timeline.make_graphic_blocker(clips[0]).is_none(),
            )
            .separator_before(true),
            TimelineMenuItem::new(
                A::SaveAsPreset,
                "Save as Preset…",
                timeline.primary_clip(selection).is_some_and(|c| c.kind == TrackKind::Video),
            ),
            TimelineMenuItem::new(A::SaveTitleBlock, "Save to Library…", media_free),
            cmd(A::SaveTemplate, "Save as Template…", media_free, EditorCommand::SaveAsTemplate),
            cmd(
                A::ToggleZones,
                "Keep Intro and Outro When Trimmed",
                media_free || clips.iter().any(|c| c.zones.is_some()),
                EditorCommand::ToggleAnimationZones,
            )
            .checked(!clips.is_empty() && clips.iter().all(|c| c.zones.is_some())),
            TimelineMenuItem::new(A::NewColorMatte, "New Color Matte…", true).separator_before(true),
            cmd(A::Delete, "Delete", has_any, EditorCommand::Delete).separator_before(true),
        ]);
        // Fast Cut: Delete already closes the gap, a second item would do the same.
        if !timeline.is_fast_cut() {
            out.push(cmd(A::RippleDelete, "Ripple Delete", has_clips, EditorCommand::RippleDelete));
        }
        out
    }

    /// Shots Punch In Cuts would work on (`EditorSession.punchInCutsClips`): two or more selected video clips, else the
    /// enabled clips of the targeted (or first) video track.
    pub fn punch_in_shots(timeline: &Timeline, selection: &BTreeSet<Id>) -> usize {
        let videos: Vec<_> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
        let selected =
            videos.iter().flat_map(|t| t.clips()).filter(|c| selection.contains(&c.id) && !c.is_generator()).count();
        if selected >= 2 {
            return selected;
        }
        let Some(track) = videos.iter().find(|t| t.is_targeted).or(videos.first()) else { return 0 };
        track.clips().iter().filter(|c| c.is_enabled && !c.is_generator()).count()
    }

    /// "Speed Ramp Presets" submenu: the five shapes, then the on-Beat variants (need beat markers on the sequence).
    pub fn speed_ramp_items(has_beats: bool, has_video_media: bool) -> Vec<TimelineMenuItem> {
        let sub = "Speed Ramp Presets";
        let mut out = Vec::new();
        for on_beat in [false, true] {
            for (i, p) in SpeedRampPreset::ALL.iter().enumerate() {
                let title = EditorCommand::SpeedRampPreset(*p, on_beat).title();
                let mut it = TimelineMenuItem::keyed(
                    TimelineMenuAction::SpeedRamp(*p, on_beat),
                    &title,
                    has_video_media && (!on_beat || has_beats),
                    on_beat && i == 0,
                    "",
                    KeyModifiers::COMMAND,
                );
                it.submenu = Some(sub.to_string());
                out.push(it);
            }
        }
        out
    }

    /// Menu of caption segments (right-click on a caption): edit the text, split at the playhead, merge, delete.
    pub fn caption_items(
        timeline: &Timeline,
        caption_selection: &BTreeSet<Id>,
        playhead: Time,
        map: &CommandMap,
    ) -> Vec<TimelineMenuItem> {
        use TimelineMenuAction as A;
        let under_playhead = timeline
            .captions_at(playhead)
            .iter()
            .any(|a| caption_selection.is_empty() || caption_selection.contains(&a.item.id));
        // Merging needs two or more captions of the same track.
        let tracks_of_selection: BTreeSet<Id> = timeline
            .caption_tracks
            .iter()
            .filter(|t| t.items().iter().any(|i| caption_selection.contains(&i.id)))
            .map(|t| t.id)
            .collect();
        vec![
            TimelineMenuItem::new(A::EditCaption, "Edit in Text", caption_selection.len() == 1),
            TimelineMenuItem::new(A::SplitCaption, "Split Caption at Playhead", under_playhead).separator_before(true),
            TimelineMenuItem::new(
                A::MergeCaptions,
                "Merge Captions",
                caption_selection.len() >= 2 && tracks_of_selection.len() == 1,
            ),
            TimelineMenuItem::with_command(
                A::Delete,
                "Delete",
                !caption_selection.is_empty(),
                true,
                &EditorCommand::Delete,
                map,
            ),
        ]
    }

    /// Right-click on a gap between clips: Paste first, Ripple Delete (closes the gap) last.
    pub fn gap_items(clipboard_has_clips: bool, map: &CommandMap) -> Vec<TimelineMenuItem> {
        use TimelineMenuAction as A;
        vec![
            TimelineMenuItem::with_command(A::Paste, "Paste", clipboard_has_clips, false, &EditorCommand::Paste, map),
            TimelineMenuItem::with_command(
                A::PasteInsert,
                "Paste Insert",
                clipboard_has_clips,
                false,
                &EditorCommand::PasteInsert,
                map,
            ),
            TimelineMenuItem::with_command(
                A::RippleDelete,
                "Ripple Delete",
                true,
                true,
                &EditorCommand::RippleDelete,
                map,
            ),
        ]
    }

    /// Right-click on empty track space.
    pub fn empty_items(
        clipboard_has_clips: bool,
        place_sequences_as_clips: bool,
        map: &CommandMap,
    ) -> Vec<TimelineMenuItem> {
        use TimelineMenuAction as A;
        vec![
            TimelineMenuItem::with_command(A::Paste, "Paste", clipboard_has_clips, false, &EditorCommand::Paste, map),
            TimelineMenuItem::with_command(
                A::PasteInsert,
                "Paste Insert",
                clipboard_has_clips,
                false,
                &EditorCommand::PasteInsert,
                map,
            ),
            TimelineMenuItem::new(A::NewAdjustmentLayer, "New Adjustment Layer", true).separator_before(true),
            TimelineMenuItem::keyed(
                A::TogglePlaceSequencesAsClips,
                "Place Sequences as Clips",
                true,
                true,
                "",
                KeyModifiers::COMMAND,
            )
            .checked(place_sequences_as_clips),
        ]
    }

    /// Builds the SQ menu rows (own design, no native menu). `handler` runs with the chosen action; the label submenu
    /// reports through `label_handler`. Submenu items are grouped under one parent row in order of first appearance.
    pub fn make_sq_items(
        items: &[TimelineMenuItem],
        label_handler: Option<Rc<dyn Fn(Option<LabelColor>)>>,
        current_label: Option<LabelColor>,
        handler: Rc<dyn Fn(TimelineMenuAction)>,
    ) -> Vec<SQMenuItem> {
        let mut out: Vec<SQMenuItem> = Vec::new();
        let mut host_index: BTreeMap<String, usize> = BTreeMap::new();
        let leaf = |it: &TimelineMenuItem| {
            let mut row = SQMenuItem::new(&it.title);
            row.shortcut = SQMenuShortcut::glyphs(&it.key, it.key_modifiers);
            row.is_enabled = it.is_enabled;
            row.is_checked = it.is_checked;
            let h = Rc::clone(&handler);
            let a = it.action;
            row.action = Some(Rc::new(move || h(a)));
            row
        };
        for it in items {
            if let Some(sub) = &it.submenu {
                let i = match host_index.get(sub) {
                    Some(&h) => h,
                    None => {
                        let mut parent = SQMenuItem::new(sub);
                        parent.submenu = Some(Vec::new());
                        out.push(parent);
                        host_index.insert(sub.clone(), out.len() - 1);
                        out.len() - 1
                    }
                };
                if let Some(rows) = out[i].submenu.as_mut() {
                    if it.separator_before {
                        rows.push(SQMenuItem::separator());
                    }
                    rows.push(leaf(it));
                }
                continue;
            }
            if it.separator_before && !out.is_empty() {
                out.push(SQMenuItem::separator());
            }
            if it.action == TimelineMenuAction::Label {
                let mut rows = Vec::new();
                let choices: Vec<Option<LabelColor>> =
                    std::iter::once(None).chain(LabelColor::ALL.iter().copied().map(Some)).collect();
                for (n, c) in choices.into_iter().enumerate() {
                    let mut row = SQMenuItem::new(c.map_or("Default", |c| c.display_name()));
                    row.is_checked = c.is_some() && c == current_label;
                    let lh = label_handler.clone();
                    row.action = Some(Rc::new(move || {
                        if let Some(lh) = &lh {
                            lh(c);
                        }
                    }));
                    if let Some(c) = c {
                        row.icon = SQMenuIcon::Swatch(c.rgb());
                    }
                    rows.push(row);
                    if n == 0 {
                        rows.push(SQMenuItem::separator());
                    }
                }
                let mut parent = SQMenuItem::new(&it.title);
                parent.is_enabled = it.is_enabled && label_handler.is_some();
                parent.submenu = Some(rows);
                out.push(parent);
                continue;
            }
            out.push(leaf(it));
        }
        out
    }
}

/// "Combine…" sheet: one name field, default "Combined NN", OK / Cancel (the sheet itself is per platform).
pub struct NestSheet;

impl NestSheet {
    /// First free "Combined NN" among `existing` names.
    pub fn default_name(existing: &[String]) -> String {
        let names: BTreeSet<&str> = existing.iter().map(String::as_str).collect();
        let mut n = 1;
        while names.contains(format!("Combined {n:02}").as_str()) {
            n += 1;
        }
        format!("Combined {n:02}")
    }

    /// Trimmed name, or the default for a blank field.
    pub fn resolved_name(input: &str, existing: &[String]) -> String {
        let t = input.trim_matches(crate::timeline_interaction::is_ws);
        if t.is_empty() { Self::default_name(existing) } else { t.to_string() }
    }
}

/// "Save as Preset…" sheet: name plus where the keys land on other clips.
pub struct PresetSaveSheet;

impl PresetSaveSheet {
    /// Trimmed name, or `fallback` for a blank field.
    pub fn resolved_name(input: &str, fallback: &str) -> String {
        let t = input.trim_matches(crate::timeline_interaction::is_ws);
        if t.is_empty() { fallback.to_string() } else { t.to_string() }
    }
}

/// One entry of the ruler's right-click menu for the In/Out range (Mark In, Mark Out, Remove In and Out, keys shown).
/// Keys come from the key map, so a rebinding shows at once.
#[derive(Clone, Debug, PartialEq)]
pub struct RulerRangeEntry {
    pub title: String,
    pub command: EditorCommand,
    pub is_enabled: bool,
    pub key: String,
    pub key_modifiers: KeyModifiers,
    pub separator_before: bool,
}

impl RulerRangeEntry {
    pub fn entries(has_in_out: bool, map: &CommandMap) -> Vec<RulerRangeEntry> {
        let entry = |title: &str, c: EditorCommand, enabled: bool| {
            let eq = map.shown_binding_here(&c).and_then(|b| TimelineMenuItem::portable_key_equivalent(&b));
            let (key, key_modifiers) = eq.unwrap_or((String::new(), KeyModifiers::EMPTY));
            RulerRangeEntry {
                title: title.to_string(),
                command: c,
                is_enabled: enabled,
                key,
                key_modifiers,
                separator_before: false,
            }
        };
        vec![
            entry("Mark In", EditorCommand::MarkIn, true),
            entry("Mark Out", EditorCommand::MarkOut, true),
            entry("Remove In and Out", EditorCommand::ClearInOut, has_in_out),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{FD, mk, mkv, timeline, track};
    use sq_core_time::TimeRange;

    #[test]
    fn combine_shows_option_g_from_the_key_map() {
        let map = CommandMap::premiere_default();
        let item = TimelineMenuItem::with_command(
            TimelineMenuAction::Nest,
            "Combine…",
            true,
            false,
            &EditorCommand::Combine,
            &map,
        );
        assert_eq!(item.key, "g");
        assert_eq!(item.key_modifiers, KeyModifiers::OPTION);
    }

    fn item(items: &[TimelineMenuItem], a: TimelineMenuAction) -> Option<&TimelineMenuItem> {
        items.iter().find(|i| i.action == a)
    }

    fn items_for(tl: &Timeline, sel: &[Id]) -> Vec<TimelineMenuItem> {
        let sel: BTreeSet<Id> = sel.iter().copied().collect();
        TimelineContextMenu::items(tl, &sel, false, &BTreeSet::new(), &CommandMap::current())
    }

    #[test]
    fn speed_is_enabled_for_media_clips_only_with_a_selection() {
        let c = mkv(0, 10);
        let tl = timeline(vec![track(TrackKind::Video, vec![c.clone()])]);
        assert!(item(&items_for(&tl, &[c.id]), TimelineMenuAction::Speed).is_some_and(|i| i.is_enabled));
        assert!(item(&items_for(&tl, &[]), TimelineMenuAction::Speed).is_some_and(|i| !i.is_enabled));
    }

    #[test]
    fn add_clip_marker_needs_one_clip_and_unnest_a_nested_one() {
        let c = mkv(0, 10);
        let tl = timeline(vec![track(TrackKind::Video, vec![c.clone()])]);
        let on = items_for(&tl, &[c.id]);
        assert!(item(&on, TimelineMenuAction::AddClipMarker).is_some_and(|i| i.is_enabled));
        assert!(item(&on, TimelineMenuAction::RevealInProject).is_some_and(|i| i.is_enabled));
        let none = items_for(&tl, &[]);
        assert!(item(&none, TimelineMenuAction::AddClipMarker).is_some_and(|i| !i.is_enabled));
        assert!(item(&none, TimelineMenuAction::Unnest).is_some_and(|i| !i.is_enabled));
    }

    fn take_timeline(takes: usize, in_out: Option<TimeRange>) -> (Timeline, Id) {
        let tracks: Vec<_> =
            (0..takes).map(|_| track(TrackKind::Audio, vec![mk(0, 240, TrackKind::Audio, None)])).collect();
        let first = tracks[0].clips()[0].id;
        let mut tl = timeline(tracks);
        tl.in_out = in_out;
        (tl, first)
    }

    #[test]
    fn use_take_needs_a_range_and_another_take() {
        let range = Some(TimeRange::new(FD * 48, FD * 72));
        let (tl, c) = take_timeline(2, range);
        assert!(item(&items_for(&tl, &[c]), TimelineMenuAction::UseTake).is_some_and(|i| i.is_enabled));
        let (tl, c) = take_timeline(2, None);
        assert!(item(&items_for(&tl, &[c]), TimelineMenuAction::UseTake).is_some_and(|i| !i.is_enabled));
        let (tl, c) = take_timeline(1, range);
        assert!(item(&items_for(&tl, &[c]), TimelineMenuAction::UseTake).is_some_and(|i| !i.is_enabled));
    }

    #[test]
    fn keys_come_from_the_key_map() {
        let c = mkv(0, 10);
        let tl = timeline(vec![track(TrackKind::Video, vec![c.clone()])]);
        let items = items_for(&tl, &[c.id]);
        let copy = item(&items, TimelineMenuAction::Copy);
        assert_eq!(copy.map(|i| (i.key.as_str(), i.key_modifiers)), Some(("c", KeyModifiers::COMMAND)));
    }

    #[test]
    fn speed_ramp_rows_form_one_submenu_with_beat_variants_needing_beats() {
        let rows = TimelineContextMenu::speed_ramp_items(false, true);
        assert_eq!(rows.len(), 10);
        assert!(rows.iter().all(|r| r.submenu.as_deref() == Some("Speed Ramp Presets")));
        assert!(rows[..5].iter().all(|r| r.is_enabled));
        assert!(rows[5..].iter().all(|r| !r.is_enabled));
        assert!(rows[5].separator_before && !rows[6].separator_before);
    }

    #[test]
    fn make_sq_items_groups_submenu_rows_under_one_parent_in_order() {
        let items = TimelineContextMenu::speed_ramp_items(true, true);
        let mut all = vec![TimelineMenuItem::new(TimelineMenuAction::Cut, "Cut", true)];
        all.extend(items);
        all.push(TimelineMenuItem::new(TimelineMenuAction::Delete, "Delete", true).separator_before(true));
        let rows = TimelineContextMenu::make_sq_items(&all, None, None, Rc::new(|_| {}));
        let titles: Vec<_> = rows.iter().map(|r| r.title.clone()).collect();
        assert_eq!(titles.len(), 4);
        assert_eq!(titles[1], "Speed Ramp Presets");
        assert_eq!(rows[1].submenu.as_ref().map(Vec::len), Some(11));
    }

    #[test]
    fn label_submenu_has_default_a_separator_and_every_color() {
        let items = vec![TimelineMenuItem::new(TimelineMenuAction::Label, "Label", true)];
        let rows = TimelineContextMenu::make_sq_items(
            &items,
            Some(Rc::new(|_| {})),
            Some(LabelColor::ALL[2]),
            Rc::new(|_| {}),
        );
        let sub = rows[0].submenu.as_ref().map_or(0, Vec::len);
        assert_eq!(sub, 1 + 1 + LabelColor::ALL.len());
        assert!(rows[0].is_enabled);
        let off = TimelineContextMenu::make_sq_items(&items, None, None, Rc::new(|_| {}));
        assert!(!off[0].is_enabled);
    }

    #[test]
    fn gap_and_empty_menus_list_their_rows() {
        let map = CommandMap::current();
        let gap = TimelineContextMenu::gap_items(true, &map);
        assert_eq!(
            gap.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(),
            ["Paste", "Paste Insert", "Ripple Delete"]
        );
        let empty = TimelineContextMenu::empty_items(false, true, &map);
        assert_eq!(
            empty.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(),
            ["Paste", "Paste Insert", "New Adjustment Layer", "Place Sequences as Clips"]
        );
        assert!(empty[3].is_checked && empty[3].separator_before && !empty[0].is_enabled && empty[2].is_enabled);
    }

    #[test]
    fn nest_sheet_names_are_unique_and_blank_input_falls_back() {
        let existing = vec!["Combined 01".to_string(), "Combined 02".to_string()];
        assert_eq!(NestSheet::default_name(&existing), "Combined 03");
        assert_eq!(NestSheet::resolved_name("  \n ", &existing), "Combined 03");
        assert_eq!(NestSheet::resolved_name(" Mine ", &existing), "Mine");
        assert_eq!(PresetSaveSheet::resolved_name("  ", "Preset"), "Preset");
    }

    #[test]
    fn caption_menu_merge_needs_two_captions_of_one_track() {
        let tl = timeline(vec![]);
        let none = BTreeSet::new();
        let rows = TimelineContextMenu::caption_items(&tl, &none, Time::new(0, 1), &CommandMap::current());
        assert_eq!(rows.len(), 4);
        assert!(!rows[3].is_enabled && rows[3].separator_before);
        assert!(!rows[2].is_enabled);
    }
}
