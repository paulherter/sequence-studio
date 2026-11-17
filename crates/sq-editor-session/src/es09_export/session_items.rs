//! The Export dialog's sequence list from the session (Swift `ExportDialogModel+Session.swift`).

use std::collections::BTreeSet;

use sq_core_audio::audio_effects::ProjectAudioEffectsExt;
use sq_core_edit::cover_frame::CoverFrame;
use sq_core_edit::cut_check::{CaptionBounds, CutCheck, CutFindingKind};
use sq_core_edit::source_edit_placement::SourceEditPlacementExt;
use sq_core_edit::sync_offsets::SyncOffsetsExt;
use sq_core_model::{Project, Timeline, TrackKind};
use sq_core_time::Id;
use sq_export::core::delivery::{SourceTraits, safe_zone_platform};
use sq_export::core::hdr::HdrTransfer;

use super::model::{ExportDialogModel, SelectedClipRange, SequenceItem};
use crate::EditorSession;

impl ExportDialogModel {
    /// Every pickable sequence with its In/Out, format, platform, variants, cover marker, voice and sync warnings, the
    /// active sequence's selected clips and the delivery-chip traits. `caption_bounds` is the caption box the delivery
    /// chips measure against the platform's safe zone (`EditorSession.captionBox` in Swift); `None` counts no captions.
    // Swift: Export/ExportDialogModel+Session.swift:11
    pub fn sequence_items(session: &EditorSession, caption_bounds: Option<&CaptionBounds>) -> Vec<SequenceItem> {
        let project = session.project();
        let under_voice = project.sequences_nested_under_disguise_voice();
        let selected = session.selection();
        let active = session.active_timeline_id();
        project
            .pickable_timelines()
            .map(|t| {
                let mut item = SequenceItem::new(t.id, &t.name, t.duration());
                item.in_out = t.export_range();
                item.format = Some(t.format.clone());
                item.delivery_target = t.delivery_target.clone();
                item.variants = t.variants.clone();
                item.cover_time = CoverFrame::time(&t.markers);
                item.nested_under_disguise_voice = under_voice.contains(&t.id);
                item.unsynced_audio_clips = Self::unsynced_audio_count(t);
                if Some(t.id) == active {
                    item.selected_clips = Self::selected_ranges(t, selected);
                }
                item.markers = t.markers.clone();
                item.source_traits = Self::source_traits(t, project, caption_bounds);
                item.hdr_target = Self::hdr_target(t);
                item
            })
            .collect()
    }

    /// The HDR transfer the picture clips target (`ClipColor.targetSpace`), for the dialog's HDR delivery suggestion.
    // Swift: Export/ExportDialogModel+Session.swift:27
    pub fn hdr_target(timeline: &Timeline) -> Option<HdrTransfer> {
        HdrTransfer::suggested(
            timeline
                .tracks
                .iter()
                .flat_map(|tr| tr.clips().iter())
                .filter(|c| c.kind != TrackKind::Audio)
                .map(|c| c.footage_color.target_space),
        )
    }

    /// Audio clips that play out of sync with their linked picture (the audio check warns about them).
    // Swift: Export/ExportDialogModel+Session.swift:32
    pub fn unsynced_audio_count(timeline: &Timeline) -> i64 {
        let offsets = timeline.sync_offsets();
        if offsets.is_empty() {
            return 0;
        }
        timeline
            .tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| c.kind == TrackKind::Audio && offsets.contains_key(&c.id))
            .count() as i64
    }

    /// Whether the picture clips of the timeline use variable frame rate or interlaced media, and how many captions
    /// reach into the delivery platform's UI zone.
    // Swift: Export/ExportDialogModel+Session.swift:40
    pub fn source_traits(
        timeline: &Timeline,
        project: &Project,
        caption_bounds: Option<&CaptionBounds>,
    ) -> SourceTraits {
        let mut t = SourceTraits::default();
        let used: BTreeSet<Id> = timeline
            .tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| c.kind != TrackKind::Audio)
            .map(|c| c.media)
            .collect();
        for id in used {
            let Some(v) = project.media(id).and_then(|m| m.info.as_ref()).and_then(|i| i.video.as_ref()) else {
                continue;
            };
            if v.is_variable_frame_rate {
                t.has_variable_frame_rate = true;
            }
            if v.is_interlaced() {
                t.has_interlaced = true;
            }
        }
        if let Some(zone) = timeline.delivery_target.as_ref().and_then(|d| safe_zone_platform(d.platform)) {
            let f = &timeline.format;
            let aspect = if f.height > 0 { f.display_width() as f64 / f.height as f64 } else { 9.0 / 16.0 };
            t.captions_in_zone = CutCheck::analyze(timeline, Some(zone), aspect, caption_bounds)
                .iter()
                .filter(|x| x.kind == CutFindingKind::CaptionOutsideSafeZone)
                .count();
        }
        t
    }

    /// Video-side clips of the timeline selection (a linked audio clip would repeat its picture's span), as spans.
    // Swift: Export/ExportDialogModel+Session.swift:58
    pub fn selected_ranges(timeline: &Timeline, selection: &BTreeSet<Id>) -> Vec<SelectedClipRange> {
        if selection.is_empty() {
            return Vec::new();
        }
        let picked: Vec<_> =
            timeline.tracks.iter().flat_map(|tr| tr.clips().iter()).filter(|c| selection.contains(&c.id)).collect();
        let has_video = picked.iter().any(|c| c.kind != TrackKind::Audio);
        picked
            .into_iter()
            .filter(|c| !has_video || c.kind != TrackKind::Audio)
            .map(|c| SelectedClipRange::new(&c.name, c.timeline()))
            .collect()
    }
}
