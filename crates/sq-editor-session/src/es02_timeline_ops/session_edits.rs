//! Split edits (J / L cut) and Whoosh, Bundle / Subclip / Join Cuts, Comping, Sync, Trim, and the multi-select edits of
//! Effect Controls and the Text section.

use std::collections::BTreeSet;

use sq_core_edit::multi_clip_edit::CodableMerge;
use sq_core_edit::sync_audio_plan::SyncAudioPlan;
use sq_core_edit::timeline_cut_keys::JLCut;
use sq_core_edit::timeline_split_edit::SplitEditSide;
use sq_core_edit::timeline_trim_mode::{TrimPoint, TrimSide};
use sq_core_graphics::format_variants_view::VariantError;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::{AudioTag, Clip, EditError, Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_text::text_generator::TextGenerator;
use sq_text::text_template::TextTemplate;

use super::prelude::*;
use crate::AudioRoleDefaults;
use crate::EdgeRef;
use crate::EditorSession;

/// Clip > Bundle menu state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BundleMenuState {
    pub can_bundle: bool,
    pub can_unbundle: bool,
}

fn variant_error(e: VariantError) -> EditError {
    match e {
        VariantError::Edit(e) => e,
        VariantError::VariantNotFound => EditError::ClipNotFound,
    }
}

fn side_name(side: SplitEditSide) -> &'static str {
    if side == SplitEditSide::Audio { "audio" } else { "video" }
}

impl EditorSession {
    // MARK: Split edit

    /// Moves only the audio or only the video edit point of the cut nearest to the playhead (on that side's tracks) to
    /// the playhead: a roll, so nothing later shifts and the sequence length stays. One undo step. Returns whether
    /// anything moved.
    // Swift: EditorSession+SplitEdit.swift:9
    pub fn split_edit_to_playhead(&mut self, side: SplitEditSide) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let at = self.playhead;
        let Some(cut) = t.nearest_cut(at, side, None) else {
            self.set_error(format!("No cut on {} tracks to split.", side_name(side)));
            return false;
        };
        if cut == at {
            return false;
        }
        let name = if side == SplitEditSide::Audio { "Split Edit Audio" } else { "Split Edit Video" };
        self.attempt(name, None, |t| t.split_edit(cut, side, at, None).map(|_| ()))
    }

    // Swift: EditorSession+SplitEdit.swift:20
    pub fn split_edit_enabled(&self) -> bool {
        self.active_timeline().is_some()
    }

    /// Keyboard nudge of one half of the cut nearest to the playhead (on that side's tracks) by `frames` (negative =
    /// earlier): the audio edit of a J / L cut moves while the picture stays, or the other way round. A roll like
    /// `split_edit_to_playhead`, one undo step, the playhead stays so repeated presses keep working on the same cut.
    /// The move is clamped by media handles; nothing moves (false, with a message) when there is no room.
    // Swift: EditorSession+SplitEdit.swift:27
    pub fn nudge_split_edit(&mut self, side: SplitEditSide, frames: i64) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if frames == 0 {
            return false;
        }
        let name = side_name(side);
        let Some(cut) = t.nearest_cut(self.playhead, side, None) else {
            self.set_error(format!("No cut on {name} tracks to nudge."));
            return false;
        };
        let fd = t.frame_duration();
        let target = cut + Time::new(frames * fd.value(), fd.timescale());
        let moved = t.clone().split_edit(cut, side, target, None).ok().filter(|m| *m != Time::ZERO);
        if moved.is_none() {
            self.set_error(format!("No room to move the {name} edit."));
            return false;
        }
        let undo = if side == SplitEditSide::Audio { "Nudge Audio Edit" } else { "Nudge Video Edit" };
        self.attempt(undo, None, |t| t.split_edit(cut, side, target, None).map(|_| ()))
    }

    /// J / L cut by a fixed offset instead of to the playhead: the audio edit of the cut nearest to the playhead moves
    /// `explicit` earlier (`JCut`, audio leads the picture) or later (`LCut`, audio trails), rounded to whole frames (at
    /// least one). The picture edit and the playhead stay, so repeated presses keep growing the same split. Without an
    /// explicit offset the role of the audio clip after the cut picks it (`defaults`).
    // Swift: EditorSession+SplitEdit.swift:48
    pub fn offset_split_edit(&mut self, kind: JLCut, explicit: Option<Time>, defaults: &AudioRoleDefaults) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let fd = t.frame_duration();
        let offset = explicit.unwrap_or_else(|| {
            let tag = t.nearest_cut(self.playhead, SplitEditSide::Audio, None).and_then(|c| {
                t.tracks
                    .iter()
                    .filter(|tr| tr.kind == TrackKind::Audio)
                    .find_map(|tr| tr.clips().iter().find(|x| x.start == c).and_then(|x| tr.role_of(x)))
            });
            defaults.split_offset(tag, fd)
        });
        let exact = offset.value() as f64 * fd.timescale() as f64 / (offset.timescale() as f64 * fd.value() as f64);
        let frames = (exact.round() as i64).max(1);
        self.nudge_split_edit(SplitEditSide::Audio, if kind == JLCut::JCut { -frames } else { frames })
    }

    /// "Whoosh at Selected Cuts": a copy of the audio `media` centered on each cut in `cuts`, on free audio tracks (a
    /// new one when none is free), tagged SFX. One undo step. Returns whether anything was placed.
    // Swift: EditorSession+SplitEdit.swift:66
    pub fn add_whoosh(&mut self, media: Id, cuts: &[Time]) -> bool {
        let Some(r) = self.project().media(media) else { return false };
        let Some(total) = r.info.as_ref().map(|i| i.duration).or(r.duration).filter(|t| *t > Time::ZERO) else {
            return false;
        };
        if cuts.is_empty() {
            self.set_error("Select a cut (an edge, or clips next to each other) first.");
            return false;
        }
        let name = r.name.clone();
        self.with_ids(|s, ids| {
            let mut proto =
                Clip::new(ids.next_id(), &name, media, TrackKind::Audio, TimeRange::new(Time::ZERO, total), Time::ZERO);
            proto.media_duration = Some(total);
            proto.audio_tag = Some(AudioTag::Sfx);
            s.attempt("Whoosh at Cuts", None, |t| t.place_centred(&proto, cuts, ids).map(|_| ()))
        })
    }

    /// The cuts the selection points at: the times of the given selected edges that are cuts, else the cuts around the
    /// selected clips.
    // Swift: EditorSession+SplitEdit.swift:77
    pub fn selected_cuts(&self, edges: &[EdgeRef]) -> Vec<Time> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        if edges.is_empty() {
            return t.cuts_of_clips(&self.selection);
        }
        let set: BTreeSet<Time> = edges.iter().filter_map(|e| t.cut_time_of_clip(e.clip, e.edge)).collect();
        set.into_iter().collect()
    }

    // MARK: Bundle

    /// Clip > Bundle is enabled with two or more units selected (a linked group or an existing bundle counts once);
    /// Unbundle with any bundled clip.
    // Swift: EditorSession+Bundle.swift:10
    pub fn bundle_menu_state(&self) -> BundleMenuState {
        let clips: Vec<Clip> = self.selected_clips_vec();
        let units: BTreeSet<Id> = clips.iter().map(|c| c.bundle.or(c.link).unwrap_or(c.id)).collect();
        BundleMenuState { can_bundle: units.len() >= 2, can_unbundle: clips.iter().any(|c| c.bundle.is_some()) }
    }

    pub(crate) fn selected_clips_vec(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| self.selection.contains(&c.id)).cloned().collect()
    }

    /// Opt+Cmd+G: bundles the selected clips (and their linked partners); the whole bundle becomes the selection.
    // Swift: EditorSession+Bundle.swift:18
    pub fn bundle_selection(&mut self) -> bool {
        if !self.bundle_menu_state().can_bundle {
            return false;
        }
        let ids = self.selection.clone();
        let mut made = None;
        let ok = self.with_ids(|s, src| {
            s.attempt("Bundle", None, |t| {
                made = Some(t.bundle(&ids, src)?);
                Ok(())
            })
        });
        let (true, Some(b), Some(t)) = (ok, made, self.active_timeline()) else { return false };
        let members: BTreeSet<Id> =
            t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| c.bundle == Some(b)).map(|c| c.id).collect();
        self.select(members, BTreeSet::new());
        true
    }

    /// Opt+Shift+Cmd+G: breaks up every bundle a selected clip belongs to. The clips stay selected.
    // Swift: EditorSession+Bundle.swift:29
    pub fn unbundle_selection(&mut self) -> bool {
        if !self.bundle_menu_state().can_unbundle {
            return false;
        }
        let ids = self.selection.clone();
        self.attempt("Unbundle", None, |t| t.unbundle(&ids).map(|_| ()))
    }

    /// Clip > Make Subclip: the In/Out range of `media` (an open end runs to the media's edge) becomes a new Project item
    /// filed after it. Needs an In or an Out. Returns the new item, `None` (with `last_error` set) when refused.
    // Swift: EditorSession+Bundle.swift:40
    pub fn make_subclip(&mut self, media: Id, name: Option<&str>) -> Option<Id> {
        let r = self.project().media(media)?;
        let marks = self.project().source_marks_for(media);
        if marks.is_empty() {
            self.set_error("Set an In or Out point in the Source monitor first.");
            return None;
        }
        let total = r.duration.or(marks.mark_out).unwrap_or(Time::ZERO);
        let Some(range) = Timeline::source_edit_range(&marks, total) else {
            self.set_error("The In to Out range is empty.");
            return None;
        };
        let mut made = None;
        let r = self.with_ids(|s, ids| {
            s.try_perform("Make Subclip", None, |p| {
                made = Some(p.make_subclip(media, range, name, ids)?);
                Ok(())
            })
        });
        match r {
            Ok(()) => made,
            Err(e) => {
                self.set_error(Self::message_for(&e));
                None
            }
        }
    }

    /// Media of the selected clips that have a file, each once, in track order (Reveal in Project).
    // Swift: EditorSession+Bundle.swift:60
    pub fn media_of_selection(&self) -> Vec<Id> {
        let mut seen = BTreeSet::new();
        self.selected_clips_vec()
            .iter()
            .filter(|c| !c.is_generator() && !c.is_nested())
            .filter(|c| self.project().media(c.media).is_some() && seen.insert(c.media))
            .map(|c| c.media)
            .collect()
    }

    /// Files of the selected timeline clips that have media (text, generators and nested sequences have none), each
    /// once, in track order. The app opens them in their default app (Clip > Edit Original).
    // Swift: EditorSession+Bundle.swift:69
    pub fn original_files_of_selection(&self) -> Vec<String> {
        let mut seen = BTreeSet::new();
        self.selected_clips_vec()
            .iter()
            .filter(|c| !c.is_generator() && !c.is_nested())
            .filter_map(|c| self.project().media(c.media))
            .filter(|m| seen.insert(m.path.clone()))
            .map(|m| m.path.clone())
            .collect()
    }

    /// Sequence > Join Cuts: merges the through edits (blade leftovers) at the selected clips, or on the whole timeline
    /// when nothing is selected, in one undo step. Returns how many cuts went; 0 changes nothing and adds no undo step.
    // Swift: EditorSession+Bundle.swift:86
    pub fn join_cuts_in_selection(&mut self) -> usize {
        let Some(t) = self.active_timeline() else { return 0 };
        let scope = (!self.selection.is_empty()).then(|| self.selection.clone());
        if t.through_edits(scope.as_ref()).is_empty() {
            return 0;
        }
        let mut n = 0;
        // Fast Cut: clips attached to a joined right half re-attach to the joined clip (`magnetic_join`).
        let ok = self.with_ids(|s, ids| {
            s.attempt("Join Cuts", None, |t| {
                n = t.magnetic_join(scope.as_ref(), ids)?;
                Ok(())
            })
        });
        if ok { n } else { 0 }
    }

    // MARK: Comping

    /// Use Take for In to Out: the selected clip's take plays inside the In..Out range, the other takes of the stack are
    /// off there (one undo step, track switches untouched). False when nothing was done (no single clip, no range, no
    /// other take there).
    // Swift: EditorSession+Comping.swift:9
    pub fn use_selected_take_for_range(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let (1, Some(&id)) = (self.selection.len(), self.selection.iter().next()) else { return false };
        let Some(range) = t.in_out.filter(|r| !r.is_empty()) else { return false };
        if !t.can_comp_take(id, range) {
            return false;
        }
        self.with_ids(|s, ids| s.attempt("Use Take", None, |t| t.comp_take(id, range, ids).map(|_| ())))
    }

    // MARK: Sync

    // Swift: EditorSession+Sync.swift:6
    pub fn move_into_sync(&mut self, id: Id) {
        self.with_ids(|s, ids| {
            s.attempt("Move into Sync", None, |t| {
                let offsets = t.sync_offsets();
                t.move_into_sync(id, &offsets, ids)
            })
        });
    }

    // Swift: EditorSession+Sync.swift:7
    pub fn slip_into_sync(&mut self, id: Id) {
        self.attempt("Slip into Sync", None, |t| {
            let offsets = t.sync_offsets();
            t.slip_into_sync(id, &offsets)
        });
    }

    /// Reference and targets of Sync Audio to Reference for the current selection (`None`: fewer than two usable clips).
    // Swift: EditorSession+Sync.swift:17
    pub fn sync_audio_plan(&self) -> Option<SyncAudioPlan> {
        self.active_timeline()?.sync_audio_plan(&self.selection)
    }

    /// Warning for clips that were placed by whole-second capture dates (no shared sound, no timecode); `None` when
    /// none were.
    // Swift: EditorSession+Sync.swift:28
    pub fn capture_date_warning(count: usize) -> Option<String> {
        if count == 0 {
            return None;
        }
        let which = if count == 1 { "1 clip was".to_string() } else { format!("{count} clips were") };
        Some(format!(
            "{which} placed by capture date only, which is accurate to about a second. Check the sync by ear."
        ))
    }

    /// Moves the clip (with its linked partners) so its recording lines up with the reference clip's and, with
    /// `retime`, corrects the drift by a constant speed: one undo step. False with `last_error` set when refused.
    // Swift: EditorSession+Sync.swift:33
    pub fn sync_audio(
        &mut self,
        id: Id,
        reference: Id,
        fit: &sq_core_audio::audio_drift_fit::AudioDriftFit,
        retime: bool,
    ) -> bool {
        use sq_core_audio::audio_drift_fit::AudioSyncMethod;
        let name = match fit.method {
            AudioSyncMethod::Sound => "Sync Audio",
            AudioSyncMethod::Timecode => "Sync by Timecode",
            AudioSyncMethod::CaptureDate => "Sync by Capture Date",
        };
        self.attempt(name, None, |t| t.sync_audio(id, reference, fit, retime))
    }

    // MARK: Trim

    /// Moves the edit `frames` later (negative = earlier) on `side`: one undo step per call. Returns how far the edit
    /// moved (zero when media handles, a neighbor or the sequence start blocked it; nothing is recorded then), `None`
    /// when the edit was refused (locked track, missing clip: `last_error` says why).
    // Swift: EditorSession+Trim.swift:12
    pub fn trim_edit(&mut self, p: &TrimPoint, side: TrimSide, frames: i64) -> Option<Time> {
        let mut probe = self.active_timeline()?.clone();
        if frames == 0 {
            return None;
        }
        let delta = probe.frame_duration() * frames;
        let moved = match self.with_ids(|_, ids| probe.trim_edit(p, side, delta, ids)) {
            Ok(m) => m,
            Err(e) => {
                self.set_error(Self::message_for(&e));
                return None;
            }
        };
        if moved == Time::ZERO {
            return Some(Time::ZERO);
        }
        let name = if side == TrimSide::Roll { "Move Edit" } else { "Ripple Trim" };
        let ok = self.with_ids(|s, ids| s.attempt(name, None, |tl| tl.trim_edit(p, side, delta, ids).map(|_| ())));
        ok.then_some(moved)
    }

    /// The sequence and nested sequences the engine was last given (the two-up monitor's own engines show the same).
    // Swift: EditorSession+Trim.swift:7
    pub fn pushed_snapshot(&self) -> Option<&crate::PushedTimeline> {
        self.pushed.as_ref()
    }

    // MARK: Multi-select (Effect Controls, Text section)

    /// The selected text clips (as displayed) when several clips are selected and all of them are text; else empty.
    // Swift: EditorSession+MultiEdit.swift:9
    pub fn selected_text_clips(&self) -> Vec<Clip> {
        let clips = self.selected_edit_clips();
        let all_text = clips.iter().all(|c| c.generator.as_ref().is_some_and(|g| g.kind == TextGenerator::KIND));
        if clips.len() > 1 && all_text { clips } else { Vec::new() }
    }

    /// Dotted paths of the text fields ("text", "style.size", "style.shadow") that differ between the selected text
    /// clips: the Text section shows those fields empty.
    // Swift: EditorSession+MultiEdit.swift:16
    pub fn text_mixed_paths(&self) -> BTreeSet<String> {
        let templates: Vec<TextTemplate> = self
            .selected_text_clips()
            .iter()
            .filter_map(|c| c.generator.as_ref().and_then(|g| TextGenerator::decode(g).ok()).map(|d| d.0))
            .collect();
        CodableMerge::differing_paths(&templates).unwrap_or_default()
    }

    /// Text section edit with several text clips selected: `primary` goes from `old` to `new`, every other selected text
    /// clip gets only the fields that changed (its other fields keep their own values). ONE undo step; edits of one
    /// gesture merge. `forcing`: template paths ("style.italic") copied even when unchanged on `primary` (a mixed field
    /// set to the shown clip's own value).
    // Swift: EditorSession+MultiEdit.swift:25
    #[allow(clippy::too_many_arguments)]
    pub fn update_text_clips(
        &mut self,
        primary: Id,
        old: &TextTemplate,
        new: &TextTemplate,
        animations: Option<&AnimationSet>,
        old_animations: Option<&AnimationSet>,
        continues_gesture: bool,
        forcing: &BTreeSet<String>,
    ) {
        let clips = self.selected_text_clips();
        if !clips.iter().any(|c| c.id == primary) {
            self.update_text_clip(primary, new, animations, continues_gesture);
            return;
        }
        let none = AnimationSet::new(None, None);
        let mut edits: Vec<Clip> = Vec::new();
        let built: Result<(), String> = (|| {
            for c in &clips {
                let Some(mut g) = c.generator.clone() else { continue };
                let r = if c.id == primary {
                    TextGenerator::make_ref(new, animations).map_err(|e| e.to_string())?
                } else {
                    let (t, a) = TextGenerator::decode(&g).map_err(|e| e.to_string())?;
                    let carried = CodableMerge::carry(old, new, &t, forcing).map_err(|e| e.to_string())?;
                    let anims = if animations == old_animations {
                        a
                    } else {
                        Some(
                            CodableMerge::carry(
                                old_animations.unwrap_or(&none),
                                animations.unwrap_or(&none),
                                a.as_ref().unwrap_or(&none),
                                &BTreeSet::new(),
                            )
                            .map_err(|e| e.to_string())?,
                        )
                    };
                    TextGenerator::make_ref(&carried, anims.as_ref()).map_err(|e| e.to_string())?
                };
                g.payload = r.payload;
                g.payload_version = r.payload_version;
                let mut e = c.clone();
                e.generator = Some(g);
                edits.push(e);
            }
            Ok(())
        })();
        if let Err(m) = built {
            self.set_error(m);
            return;
        }
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let v = self.active_variant_id();
        let key = format!("texts:{}", self.gesture_counter);
        self.attempt("Edit Text", Some(&key), |t| {
            for e in &edits {
                // In a format variant the text is edited as that variant shows it, else it is the shared base text.
                match v {
                    Some(_) => t.apply_displayed_edit(e, v, true).map_err(variant_error)?,
                    None => t.replace_clip(e.clone())?,
                }
            }
            Ok(())
        });
    }

    /// The clips an Effect Controls / Text edit goes to, as the active variant shows them: one per selected clip, a
    /// linked A/V pair counted once by its video clip; ordered by start, then track. Empty when a selected clip is not
    /// in the active sequence.
    // Swift: EditorSession+MultiEdit.swift:69
    pub fn selected_edit_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline().filter(|_| !self.selection.is_empty()) else { return Vec::new() };
        let mut picked: Vec<(Clip, usize)> = Vec::new();
        for (i, tr) in t.tracks.iter().enumerate() {
            picked.extend(tr.clips().iter().filter(|c| self.selection.contains(&c.id)).map(|c| (c.clone(), i)));
        }
        if picked.len() != self.selection.len() {
            return Vec::new();
        }
        // A linked group shows its picture clip (the audio of a selected pair edits through it, like one clip).
        let linked_picture: BTreeSet<Id> =
            picked.iter().filter(|p| p.0.kind != TrackKind::Audio).filter_map(|p| p.0.link).collect();
        let mut seen_links: BTreeSet<Id> = BTreeSet::new();
        let mut out: Vec<(Clip, usize)> = Vec::new();
        for p in picked {
            if let Some(l) = p.0.link {
                if p.0.kind == TrackKind::Audio && linked_picture.contains(&l) {
                    continue;
                }
                if !seen_links.insert(l) {
                    continue;
                }
            }
            out.push(p);
        }
        out.sort_by_key(|p| (p.0.start, p.1));
        out.into_iter().map(|p| self.displayed_clip(&p.0)).collect()
    }

    /// Effect Controls edit of several clips as displayed: ONE undo step. Edits of one gesture merge.
    // Swift: EditorSession+MultiEdit.swift:89
    pub fn replace_displayed_clips(&mut self, clips: Vec<Clip>, name: &str, continues_gesture: bool) {
        if clips.len() <= 1 {
            if let Some(c) = clips.into_iter().next() {
                self.replace_displayed_clip(c, name, continues_gesture);
            }
            return;
        }
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let v = self.active_variant_id();
        let conforms: Vec<bool> = match v {
            Some(v) => clips.iter().map(|c| self.project().conforms_picture(c, Some(v))).collect(),
            None => Vec::new(),
        };
        let key = format!("clips:{}", self.gesture_counter);
        self.attempt(name, Some(&key), |t| {
            for (i, c) in clips.iter().enumerate() {
                match v {
                    Some(_) => t.apply_displayed_edit(c, v, conforms[i]).map_err(variant_error)?,
                    None => t.replace_clip(c.clone())?,
                }
            }
            Ok(())
        });
    }

    /// `replace_displayed_clips` of edits computed from `bases` (the displayed clips the panel held, matched by id): each
    /// clip is merged onto the clip the session displays now. A clip without a base is written as it is.
    pub fn replace_displayed_clips_rebased(
        &mut self,
        bases: &[Clip],
        clips: Vec<Clip>,
        name: &str,
        continues_gesture: bool,
    ) {
        let rebased = clips
            .into_iter()
            .map(|c| {
                let base = bases.iter().find(|b| b.id == c.id);
                match (base, self.clip_in_active(c.id)) {
                    (Some(base), Some(stored)) => Clip::rebased(base, &c, &self.displayed_clip(&stored)),
                    _ => c,
                }
            })
            .collect();
        self.replace_displayed_clips(rebased, name, continues_gesture);
    }
}
