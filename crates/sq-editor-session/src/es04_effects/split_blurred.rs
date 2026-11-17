//! Adjustment layers, blurred fill, keystones and split screen.

use std::collections::BTreeSet;

use sq_core_effects::adjustment_clip::ProjectAdjustmentExt;
use sq_core_effects::blurred_fill::{
    BlurredFill, BlurredFillError, BlurredFillOptions, BlurredFillStyle, TimelineBlurredFillExt,
};
use sq_core_effects::keystone::{Keystone, KeystoneProperty, KeystoneSpan, TimelineKeystoneExt};
use sq_core_graphics::split_layout::{ProjectSplitLayoutExt, SplitAnimation, SplitLayoutPreset};
use sq_core_model::{EditError, TrackKind};
use sq_core_time::keyframes_model::Vec2;
use sq_core_time::{Id, Time, TimeRange};

use crate::es05_captions_titles::generator_track;

use sq_uikit::editor_command::EditorCommand;

use crate::EditorSession;

/// Why a split screen preset cannot be applied to the current clips.
// Swift: EditorSession+SplitScreen.swift:10
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitScreenProblem {
    TooFewClips { required: i64 },
    SameTrack,
}

impl EditorSession {
    /// Places an Adjustment Layer at `time` (default: playhead) on `track`, else on the topmost free video track.
    // Swift: EditorSession+Adjustment.swift:8
    pub fn add_adjustment_layer(&mut self, time: Option<Time>, track: Option<Id>, duration: Time) -> Option<Id> {
        let (Some(t), Some(tl)) = (self.active_timeline(), self.active_timeline_id) else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let fd = t.frame_duration();
        let start = time.unwrap_or(self.playhead).snapped(fd);
        let duration = duration.snapped(fd).max(fd);
        let Some(chosen) = generator_track(t, TimeRange::new(start, duration), track, true) else {
            self.set_error("There is no video track for the adjustment layer.");
            return None;
        };
        let mut made = None;
        let lease = self.lend_ids();
        let ids = &mut lease.source();
        let result = self.try_perform("Add Adjustment Layer", None, |p| {
            made = Some(p.add_adjustment_clip(tl, start, chosen, duration, &mut *ids)?);
            Ok::<(), EditError>(())
        });
        self.return_ids(lease);
        if let Err(e) = result {
            self.set_error(e.to_string());
            return None;
        }
        if let Some(id) = made {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        made
    }

    /// Fit with Blurred Fill / Card on the selected video clips. Returns whether anything changed.
    // Swift: EditorSession+BlurredFill.swift:9
    pub fn apply_blurred_fill(&mut self, style: BlurredFillStyle, options: &BlurredFillOptions) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let mut jobs: Vec<(Id, (i64, i64))> = Vec::new();
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        for c in self.command_clips(Some(TrackKind::Video)) {
            // The blurred copy stands for its picture.
            let pid = t.blurred_fill_picture(c.id);
            if !seen.insert(pid) {
                continue;
            }
            let Some(pic) = t.tracks.iter().find_map(|tr| tr.clip(pid)) else { continue };
            let Some(size) = self.project().picture_size(pic) else { continue };
            let applied = t.blurred_fill_pair(pid).is_some();
            if style == BlurredFillStyle::Fit && !applied && BlurredFill::matches_aspect(size, &t.format) {
                continue;
            }
            jobs.push((pid, size));
        }
        if jobs.is_empty() {
            return false;
        }
        let name =
            if style == BlurredFillStyle::Fit { "Fit with Blurred Fill" } else { "Card with Blurred Background" };
        let mut refusal: Option<String> = None;
        let options = *options;
        let ok = self.attempt_keyed_ids(name, None, |tl, ids| {
            for (id, size) in &jobs {
                tl.apply_blurred_fill(*id, *size, style, options, ids).map_err(|e| match e {
                    BlurredFillError::Edit(e) => e,
                    other => {
                        refusal = Some(other.to_string());
                        EditError::EmptyClip
                    }
                })?;
            }
            Ok(())
        });
        if let Some(m) = refusal {
            self.set_error(m);
        }
        ok
    }
    // Swift: EditorSession+BlurredFill.swift:31
    pub fn remove_blurred_fill(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        let ids: Vec<Id> = self
            .command_clips(Some(TrackKind::Video))
            .iter()
            .filter(|c| t.blurred_fill_pair(c.id).is_some())
            .map(|c| t.blurred_fill_picture(c.id))
            .filter(|id| seen.insert(*id))
            .collect();
        if ids.is_empty() {
            return false;
        }
        self.attempt_keyed_ids("Remove Blurred Fill", None, |tl, _| {
            ids.iter().try_for_each(|id| tl.remove_blurred_fill(*id))
        })
    }
    // Swift: EditorSession+BlurredFill.swift:44
    pub fn blurred_fill_enabled(&self, command: &EditorCommand) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let clips = self.command_clips(Some(TrackKind::Video));
        if *command == EditorCommand::RemoveBlurredFill {
            clips.iter().any(|c| t.blurred_fill_pair(c.id).is_some())
        } else if *command == EditorCommand::FitBlurredFill {
            // The jobs `apply_blurred_fill` would make: a clip that already has the frame's shape has nothing to fit.
            clips.iter().any(|c| {
                let pid = t.blurred_fill_picture(c.id);
                let Some(size) =
                    t.tracks.iter().find_map(|tr| tr.clip(pid)).and_then(|pic| self.project().picture_size(pic))
                else {
                    return false;
                };
                t.blurred_fill_pair(pid).is_some() || !BlurredFill::matches_aspect(size, &t.format)
            })
        } else {
            clips.iter().any(|c| self.project().picture_size(c).is_some())
        }
    }

    /// Applies `keystone` to `clip` at `span` (nil span = around the playhead); where it landed.
    // Swift: EditorSession+Keystones.swift:9
    pub fn apply_keystone(
        &mut self,
        keystone: &Keystone,
        clip: Id,
        span: Option<KeystoneSpan>,
    ) -> Option<KeystoneSpan> {
        let Some(c) = self.clip_in_active(clip) else {
            self.set_error(EditError::ClipNotFound.to_string());
            return None;
        };
        let place = span.unwrap_or_else(|| keystone.placement(self.playhead - c.start, c.duration()));
        let mut landed = None;
        let ok = self.attempt_keyed_ids(&format!("Apply Motion \u{201c}{}\u{201d}", keystone.name), None, |t, ids| {
            landed = Some(t.apply_keystone(keystone, clip, place.start, place.duration, ids)?);
            Ok(())
        });
        if ok { landed } else { None }
    }
    // Swift: EditorSession+Keystones.swift:23
    pub fn restretch_keystone(&mut self, clip: Id, span: &KeystoneSpan, new: &KeystoneSpan) -> bool {
        if new == span {
            return false;
        }
        self.attempt_keyed_ids("Change Motion Length", None, |t, _| t.restretch_keystone(clip, span, new))
    }
    // Swift: EditorSession+Keystones.swift:31
    pub fn keystone_from_selected_clip(
        &mut self,
        properties: Option<&BTreeSet<KeystoneProperty>>,
        name: &str,
    ) -> Option<Keystone> {
        let tl = self.active_timeline()?;
        let (w, h) = (tl.format.display_width() as f64, tl.format.height as f64);
        let c = self.single_selected_clip().cloned().filter(|c| c.kind == TrackKind::Video)?;
        let props = properties.cloned().unwrap_or_else(|| {
            [KeystoneProperty::Position, KeystoneProperty::Scale, KeystoneProperty::Rotation, KeystoneProperty::Opacity]
                .into_iter()
                .collect()
        });
        Keystone::capture(&c, &props, Vec2::new(w, h), name, self.ids.as_mut())
    }

    /// Length of the slide in and out of the animated split screen variants.
    // Swift: EditorSession+SplitScreen.swift:7
    pub const DEFAULT_SPLIT_ANIMATION_DURATION: Time = Time::new(1, 2);

    // Swift: EditorSession+SplitScreen.swift:13
    pub fn split_screen_problem(&self, preset: SplitLayoutPreset) -> Option<SplitScreenProblem> {
        let required = preset.cell_count() as i64;
        let Some(t) = self.active_timeline() else { return Some(SplitScreenProblem::TooFewClips { required }) };
        let ids: BTreeSet<Id> = self.command_clips(Some(TrackKind::Video)).iter().map(|c| c.id).collect();
        let tracks: Vec<usize> = t
            .tracks
            .iter()
            .enumerate()
            .flat_map(|(i, tr)| tr.clips().iter().filter(|c| ids.contains(&c.id)).map(move |_| i))
            .collect();
        let distinct: BTreeSet<usize> = tracks.iter().copied().collect();
        if distinct.len() != tracks.len() {
            return Some(SplitScreenProblem::SameTrack);
        }
        if tracks.len() as i64 >= required { None } else { Some(SplitScreenProblem::TooFewClips { required }) }
    }
    // Swift: EditorSession+SplitScreen.swift:22
    pub fn split_screen_extra_clips(&self, preset: SplitLayoutPreset) -> i64 {
        (self.command_clips(Some(TrackKind::Video)).len() as i64 - preset.cell_count() as i64).max(0)
    }
    // Swift: EditorSession+SplitScreen.swift:29
    pub fn apply_split_screen(&mut self, preset: SplitLayoutPreset, animated: bool, gap: f64) -> bool {
        let Some(tid) = self.active_timeline_id else { return false };
        let ids: BTreeSet<Id> = self.command_clips(Some(TrackKind::Video)).iter().map(|c| c.id).collect();
        if self.split_screen_problem(preset).is_some() {
            return false;
        }
        let animation = animated
            .then(|| SplitAnimation { duration: Self::DEFAULT_SPLIT_ANIMATION_DURATION, ..SplitAnimation::default() });
        let lease = self.lend_ids();
        let ids_src = &mut lease.source();
        let mut moved = 0;
        let result = self.try_perform("Split Screen", None, |p| {
            moved = p.apply_split_layout(preset, &ids, tid, gap, animation.as_ref(), &mut *ids_src)?;
            if moved == 0 {
                Err(sq_core_graphics::split_layout::SplitLayoutError::Edit(EditError::EmptyClip))
            } else {
                Ok(())
            }
        });
        self.return_ids(lease);
        match result {
            Ok(()) => true,
            Err(sq_core_graphics::split_layout::SplitLayoutError::Edit(EditError::EmptyClip)) if moved == 0 => false,
            Err(e) => {
                self.set_error(e.to_string());
                false
            }
        }
    }
}
