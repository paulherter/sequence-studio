// Swift: TimelineSessionBridge.swift
//! Applies the panel's actions through the `EditorSession` API, the way App/EditorPanels wires the Mac `TimelineView`
//! callbacks. Editors of other panels go to the [`TimelineHost`]; one it does not have comes back as a status line.

use crate::action::TimelineAction;
use crate::host::{TimelineEditorRequest, TimelineHost};
use crate::panel::TimelinePanel;
use sq_core_effects::transition_layer::ClipTransitionLayer as _;
use sq_core_graphics::graphics_editing::GraphicsDocumentEditingExt as _;
use sq_core_model::ClipEdge;
use sq_core_model::ThreePointMode;
use sq_core_model::{Clip, Timeline};
use sq_core_time::Time;
use sq_editor_session::{EditorSession, PlaceOptions, TrackToggle, TransitionTimingChange};
use sq_timeline_ui::KeystoneBar;
use std::collections::BTreeSet;

/// Runs `a`; returns a status line for the host (a refusal, a hint, or a dialog that is not there yet). `panel` is the
/// timeline panel the Swift `host.editPanel` reaches: the keystone bar and the item selection follow the edit.
pub fn apply(
    a: TimelineAction,
    s: &mut EditorSession,
    host: &mut TimelineHost,
    mut panel: Option<&mut TimelinePanel>,
) -> Option<String> {
    match a {
        TimelineAction::Commit(c) => s.commit(&c),
        TimelineAction::CloseGap(g) => s.close_gap(&g),
        TimelineAction::Select { clips, captions } => s.select(clips, captions),
        TimelineAction::Seek(t) => s.seek(t),
        TimelineAction::BeginScrub => s.begin_scrub(),
        TimelineAction::Scrub(t) => s.scrub(t),
        TimelineAction::EndScrub => s.end_scrub(),
        TimelineAction::ToggleTrack { track, toggle, shift, option } => {
            // The target chip: Shift / Option change several targets at once (`toggleTarget`); every other button
            // toggles one track, Shift all of its kind.
            if toggle == TrackToggle::Target {
                s.toggle_target(track, shift, option);
            } else {
                s.toggle_tracks(track, toggle, shift);
            }
        }
        TimelineAction::AddTrack(kind) => s.add_track(kind),
        TimelineAction::TransitionLayerCut { clip, to, continues } => {
            s.stop_playback();
            s.move_transition_layer_cut(clip, to, continues);
        }
        TimelineAction::TransitionLayerResize { clip, edge, to, symmetric, continues } => {
            // The step is measured against the end as it is now (the model clamps; nothing accumulates).
            let fd = s.active_timeline()?.format.frame_duration;
            let r = s
                .active_timeline()?
                .tracks
                .iter()
                .flat_map(|t| t.clips().iter())
                .find(|c| c.id == clip)?
                .resolved_transition_layer(fd)?;
            let delta = to - if edge == ClipEdge::Head { r.span.start } else { r.span.end() };
            if delta != Time::ZERO {
                s.stop_playback();
                s.resize_transition_layer(clip, edge, delta, symmetric, continues);
            }
        }
        TimelineAction::SourcePatchClick { kind, solo } => {
            if solo {
                s.solo_source_patch(kind);
            } else {
                s.toggle_source_patch(kind);
            }
        }
        TimelineAction::SourcePatchMove { kind, to, both } => {
            if both {
                s.patch_source_both(kind, to);
            } else {
                s.patch_source(kind, to);
            }
        }
        TimelineAction::MoveMarker(id, t) => s.move_marker(id, t),
        TimelineAction::SetMarkerDuration(id, d) => s.set_marker_duration(id, d),
        TimelineAction::MoveInOut(r, part) => s.move_in_out(r, Some(part)),
        TimelineAction::SelectTransition { id, keep_clips } => s.select_transition(id, keep_clips),
        TimelineAction::ChangeTransition { id, change, continues } => {
            s.stop_playback();
            s.set_transition(
                id,
                &TransitionTimingChange {
                    duration: Some(change.duration),
                    alignment: Some(change.alignment),
                    custom_before: (change.alignment == sq_core_model::TransitionAlignment::Custom)
                        .then_some(change.custom_before),
                    kind: None,
                },
                continues,
            );
        }
        TimelineAction::OpenNestedSequence(id) => s.enter_nested_sequence(id),
        // The editors belong to other panels: the host opens them (a status line when it has none yet).
        TimelineAction::EditTransition(id) => return host.request(&TimelineEditorRequest::EditTransitionDuration(id)),
        TimelineAction::OpenTrimMode { point, pointer_before } => {
            return host.request(&TimelineEditorRequest::TrimMode { point, pointer_before });
        }
        // The Mac selects the clip (and stops playback) before it opens the monitor's text editing or the Graphics panel.
        TimelineAction::EditTextClip(id) => {
            s.stop_playback();
            s.select(BTreeSet::from([id]), BTreeSet::new());
            return host.request(&TimelineEditorRequest::TextClip(id));
        }
        TimelineAction::EditToneClip(id) => {
            s.select(BTreeSet::from([id]), BTreeSet::new());
            return host.request(&TimelineEditorRequest::ToneClip(id));
        }
        TimelineAction::OpenGraphicLayers(id) => {
            s.stop_playback();
            s.select(BTreeSet::from([id]), BTreeSet::new());
            return host.request(&TimelineEditorRequest::GraphicLayers(id));
        }
        TimelineAction::OpenInSource(media) => return host.request(&TimelineEditorRequest::Source { media }),
        TimelineAction::EditMarker(id) => return host.request(&TimelineEditorRequest::Marker(id)),
        TimelineAction::EditClipMarker { clip, marker } => {
            return host.request(&TimelineEditorRequest::ClipMarker { clip, marker });
        }
        TimelineAction::MoveClipMarker { clip, marker, to } => s.move_clip_marker(marker, clip, to),
        TimelineAction::ReplaceClip { clip, base, undo_name, continues } => {
            s.replace_clip_rebased(&base, &clip, &undo_name, continues);
        }
        TimelineAction::EndGesture => s.end_gesture(),
        TimelineAction::LineKeyClick { key, extend } => {
            let Some(r) = key else {
                s.select_line_keys(&BTreeSet::new());
                return None;
            };
            let next: BTreeSet<_> = if extend {
                // Shift-click toggles the key in the picked set (symmetric difference).
                let mut keys = s.selected_line_keys().clone();
                if !keys.remove(&r) {
                    keys.insert(r);
                }
                keys
            } else {
                BTreeSet::from([r])
            };
            s.select_line_keys(&next);
        }
        TimelineAction::SpeedEdit { clip, keys, phase, keeping_keys } => {
            s.apply_speed_edit(&sq_editor_session::SpeedEdit { clip, keys, phase, keeping_keys });
        }
        TimelineAction::CancelSpeedEdit { clip, restoring } => s.cancel_speed_edit(clip, *restoring),
        TimelineAction::KeyLaneClick { clip, time, extend } => {
            return host.request(&TimelineEditorRequest::KeyLaneKey { clip, time, extend });
        }
        TimelineAction::ToggleCaptionTrackVisibility(id) => {
            let visible = s.active_timeline()?.caption_tracks.iter().find(|t| t.id == id)?.is_visible;
            let _ = s.perform_timeline(if visible { "Hide Caption Track" } else { "Show Caption Track" }, None, |t| {
                if let Some(i) = t.caption_tracks.iter().position(|c| c.id == id) {
                    t.caption_tracks[i].is_visible = !t.caption_tracks[i].is_visible;
                }
                Ok(())
            });
        }
        TimelineAction::EditCaption(id, word) => {
            if let Some(word) = word
                && host.open.as_mut().is_some_and(|open| open(&TimelineEditorRequest::CaptionWord(word)))
            {
                return None;
            }
            return host.request(&TimelineEditorRequest::CaptionText(id));
        }
        TimelineAction::Skim(t) => s.skim(t),
        TimelineAction::SlipTwoUp(two, tl) => {
            if let Some(hook) = &mut host.slip_two_up {
                hook(two.as_ref(), &tl);
            }
        }
        TimelineAction::DropMedia { ids, time, track, new_track, insert, streams } => {
            let options = PlaceOptions {
                at: Some(time),
                video_track: track,
                mode: if insert { ThreePointMode::Insert } else { ThreePointMode::Overwrite },
                streams,
                new_track,
                ..PlaceOptions::default()
            };
            // Swift `placeMediaAsking`: an empty, never configured sequence of another format asks first (a flow).
            if s.format_mismatch(&ids).is_some() {
                host.flows.push(sq_draw_shell::ShellFlow::PlaceMedia { ids, options });
            } else {
                s.place_media(&ids, &options);
            }
        }
        TimelineAction::DropKeystone { keystone, clip, span } => {
            let Some(landed) = s.apply_keystone(&keystone, clip, Some(span)) else {
                return Some(s.last_error().map_or_else(
                    || format!("\u{201C}{}\u{201D} could not be applied.", keystone.name),
                    str::to_string,
                ));
            };
            if let Some(p) = panel.as_mut() {
                let now = s.active_timeline().and_then(|t| clip_of(t, clip)).cloned();
                p.set_keystone_bar(Some(KeystoneBar { clip, span: landed, name: keystone.name.clone() }), now);
            }
        }
        TimelineAction::RestretchKeystone { clip, from, to, name } => {
            let ok = s.restretch_keystone(clip, &from, &to);
            if let Some(p) = panel.as_mut() {
                let now = s.active_timeline().and_then(|t| clip_of(t, clip)).cloned();
                p.set_keystone_bar(Some(KeystoneBar { clip, span: if ok { to } else { from }, name }), now);
            }
            if !ok {
                return s.last_error().map(str::to_string);
            }
        }
        TimelineAction::SelectItems { clip, items } => {
            if s.single_selected_clip().map(|c| c.id) != Some(clip) {
                s.select(BTreeSet::from([clip]), BTreeSet::new());
            }
            if let Some(hook) = &mut host.item_selection {
                hook(clip, &items);
            }
        }
        TimelineAction::MakeGraphic(id) => {
            s.select(BTreeSet::from([id]), BTreeSet::new());
            s.make_graphic();
        }
        TimelineAction::ReorderItems { clip, ids, to_index } => {
            let set: BTreeSet<_> = ids.into_iter().collect();
            let index = i64::try_from(to_index).unwrap_or(0);
            s.edit_graphics(clip, "Reorder Layer", None, |d| d.move_to_index(&set, index));
        }
        TimelineAction::MoveItemsOut { clip, ids, to, copy } => {
            let Some(landed) = s.move_graphics_layers(&ids, clip, to, copy) else {
                return s.last_error().map(str::to_string);
            };
            s.select(BTreeSet::from([landed.clip]), BTreeSet::new());
            if let Some(p) = panel.as_mut() {
                p.set_item_selection(Some(landed.clip), landed.layers.iter().copied().collect());
            }
            if let Some(hook) = &mut host.item_selection {
                hook(landed.clip, &landed.layers.iter().copied().collect());
            }
        }
        TimelineAction::SetAttachPoint { clip, time } => {
            return s.set_attach_point_at(clip, time).then(|| "Attach point set.".to_string());
        }
        TimelineAction::ContextMenu(_) => return None, // the host builds the menu (it needs the panel)
        TimelineAction::Command(c) => host.run(c),
        TimelineAction::Status(m) => return Some(m),
    }
    None
}

/// The clip with `id` anywhere in the sequence.
fn clip_of(t: &Timeline, id: sq_core_time::Id) -> Option<&Clip> {
    t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == id)
}
