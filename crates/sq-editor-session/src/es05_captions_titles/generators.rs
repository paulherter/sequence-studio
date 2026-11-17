//! Clips made without media: text, tone, shapes, Lottie animations and graphics, plus the Add Title builder.

use std::collections::BTreeSet;
use std::path::Path;

use sq_core_audio::tone_generator::{ToneClipExt, ToneSpec};
use sq_core_edit::generators::GeneratorsExt;
use sq_core_graphics::format_variants_view::{ProjectVariantsExt, TimelineVariantsExt, VariantError};
use sq_core_graphics::graphics_editing::ProjectGraphicsExt;
use sq_core_graphics::graphics_make_graphic::ProjectMakeGraphicExt;
use sq_core_graphics::graphics_move_out::{GraphicsLayerDestination, ProjectMoveOutExt};
use sq_core_graphics::lottie_generator::{LottieImportError, LottieInfo, LottieLimits, ProjectLottieExt};
use sq_core_graphics::shape_generator::ProjectShapeExt;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{
    AnimatedProperty, Clip, ClipEffect, EditError, GraphicsLayer, SequenceFormat, ShapeKind, Track, TrackKind,
    TransitionKind,
};
use sq_core_time::keyframes_model::Vec2;
use sq_core_time::{Id, Time, TimeRange};
use sq_library::library_folder_store::SettingsStore;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::text_generator::TextGenerator;
use sq_text::text_presets::{TextPresetApply, TextPresetCatalog};
use sq_text::text_style::FontWeight;
use sq_text::text_template::TextTemplate;

use super::common::generator_track;
use super::graphic_presets::{CTAEndCard, GraphicPresetCatalog};
use crate::{EditorSession, GraphicLayerSelection, LookRef, LookScope, LookStore};
use sq_core_audio::TimelineCaptionEditsExt as TimelineCaptionEdits;

/// Where moved graphics layers landed (Swift's `(clip:, layers:)` tuple).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MovedLayers {
    pub clip: Id,
    pub layers: Vec<Id>,
}

impl EditorSession {
    /// Places a text layer at `time` (default: playhead) on `track`, else on the topmost unlocked video track that is
    /// free there. Selects the new clip. Returns its ID; a refusal is reported through `last_error`.
    // Swift: EditorSession+Generators.swift:9
    pub fn add_text_clip(
        &mut self,
        template: &TextTemplate,
        at: Option<Time>,
        track: Option<Id>,
        duration: Time,
        position: Option<Vec2>,
        never_overwrite: bool,
    ) -> Option<Id> {
        let t = self.active_timeline()?;
        let fd = t.frame_duration();
        let start = at.unwrap_or(self.playhead).snapped(fd);
        // 5 s is not a whole number of frames at 29.97: the clip ends on a frame like everything else on the timeline.
        let duration = duration.snapped(fd).max(fd);
        let range = TimeRange::new(start, duration);
        let (tl, new_track, chosen) =
            self.es5_generator_target(range, track, never_overwrite, "There is no video track for the text.")?;
        let generator = match TextGenerator::make_ref(template, None) {
            Ok(g) => g,
            Err(e) => {
                self.set_error(e.to_string());
                return None;
            }
        };
        let mut new_id = None;
        let name = template.name.clone();
        let r = self.perform_ids("Add Text", None, |p, ids| {
            if let Some(nt) = new_track {
                p.edit(tl, |t| {
                    t.tracks.push(nt);
                    Ok(())
                })?;
            }
            let id = p.add_generator_clip(
                generator,
                Some(&name),
                GeneratorPlacement { timeline: tl, track: chosen, start, duration },
                ids,
            )?;
            new_id = Some(id);
            if let Some(position) = position {
                p.edit(tl, |t| {
                    for tr in &mut t.tracks {
                        if let Some(mut c) = tr.clip(id).cloned() {
                            c.animation.position = AnimatedProperty::new(position);
                            tr.replace(c);
                        }
                    }
                    Ok(())
                })?;
            }
            Ok(())
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return None;
        }
        if let Some(id) = new_id {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        new_id
    }

    /// Places a tone (1 kHz, -12 dB) at the playhead on the targeted audio track that is free there, else the last
    /// unlocked audio track. Selects the clip.
    // Swift: EditorSession+Generators.swift:47
    pub fn add_tone_clip(&mut self, spec: &ToneSpec, duration: Time) -> Option<Id> {
        let t = self.active_timeline()?;
        let tl = self.active_timeline_id?;
        let fd = t.frame_duration();
        let start = self.playhead.snapped(fd);
        let duration = duration.snapped(fd).max(fd);
        let range = TimeRange::new(start, duration);
        let audio: Vec<&Track> = t.tracks.iter().filter(|t| t.kind == TrackKind::Audio && !t.is_locked).collect();
        let clear = |tr: &&Track| !tr.clips().iter().any(|c| c.timeline().overlaps(&range));
        // Never over other sound: when no audio track is free over the range, a new one is added (same undo step).
        let free = audio
            .iter()
            .find(|tr| tr.is_targeted && clear(tr))
            .or_else(|| audio.iter().find(|tr| clear(tr)))
            .map(|tr| tr.id);
        let fresh = if free.is_none() { Some(Track::new(self.ids.next_id(), TrackKind::Audio)) } else { None };
        let chosen = free.or(fresh.as_ref().map(|t| t.id))?;
        let mut new_id = None;
        let r = self.perform_ids("Add Tone", None, |p, ids| {
            if let Some(f) = fresh {
                p.edit(tl, |t| {
                    t.tracks.push(f);
                    Ok(())
                })?;
            }
            // Swift `Project.addToneClip`: its checks are written out here (same rules, same result).
            p.edit(tl, |t| {
                let tr = t.tracks.iter().position(|x| x.id == chosen).ok_or(EditError::ClipNotFound)?;
                if t.tracks[tr].kind != TrackKind::Audio {
                    return Err(EditError::WrongTrackKind);
                }
                if t.tracks[tr].is_locked {
                    return Err(EditError::TrackLocked);
                }
                if duration <= Time::ZERO || start < Time::ZERO {
                    return Err(EditError::EmptyClip);
                }
                let id = ids.next_id();
                t.tracks[tr].overwrite(Clip::make_tone(id, spec, start, duration, "Tone"), ids)?;
                new_id = Some(id);
                Ok(())
            })
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return None;
        }
        if let Some(id) = new_id {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        new_id
    }

    /// Removes a text clip that was left empty. With `depth` (the undo depth before the clip was added) the add and any
    /// edits are withdrawn without a trace; without it the clip is lifted (gap) as one undo step.
    // Swift: EditorSession+Generators.swift:86
    pub fn discard_text_clip(&mut self, id: Id, rewinding_to: Option<usize>) -> bool {
        if let Some(depth) = rewinding_to
            && self.history.undo_depth() > depth
        {
            self.rewind_undo(depth);
            if self.selection.contains(&id) {
                let mut rest = self.selection.clone();
                rest.remove(&id);
                self.select(rest, BTreeSet::new());
            }
            return true;
        }
        let ok = self
            .attempt_keyed_ids("Delete Empty Text", None, |t, ids| crate::TimelineEdit::Lift(vec![id]).apply(t, ids));
        if ok && self.selection.contains(&id) {
            let mut rest = self.selection.clone();
            rest.remove(&id);
            self.select(rest, BTreeSet::new());
        }
        ok
    }

    /// Undo depth now, to be passed to `discard_text_clip` later.
    // Swift: EditorSession+Generators.swift:99
    pub fn undo_depth(&self) -> usize {
        self.history.undo_depth()
    }

    /// Text or style edit of a generator clip. Edits of one gesture (`continues_gesture`) merge into one step.
    // Swift: EditorSession+Generators.swift:102
    pub fn update_text_clip(
        &mut self,
        id: Id,
        template: &TextTemplate,
        animations: Option<&AnimationSet>,
        continues_gesture: bool,
    ) {
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let generator = match TextGenerator::make_ref(template, animations) {
            Ok(g) => g,
            Err(e) => {
                self.set_error(e.to_string());
                return;
            }
        };
        let key = format!("text:{id}:{}", self.gesture_counter);
        // In a format variant the text is edited as that variant shows it: an overridden generator keeps the edit in the
        // override, else it is the shared base text.
        let variant = self.active_variant_id();
        let displayed = match (variant, self.active_timeline()) {
            (Some(v), Some(tl)) => self
                .es5_clip(id)
                .map(|c| self.project().displayed_clip(c, tl, Some(v)))
                .filter(|d| d.generator.is_some())
                .map(|d| (v, d)),
            _ => None,
        };
        let r = if let Some((v, mut edited)) = displayed {
            if let Some(g) = edited.generator.as_mut() {
                g.payload = generator.payload.clone();
                g.payload_version = generator.payload_version;
            }
            self.perform_timeline_ids("Edit Text", Some(&key), |t, _| {
                t.apply_displayed_edit(&edited, Some(v), true).map_err(|e| match e {
                    VariantError::Edit(e) => e,
                    VariantError::VariantNotFound => EditError::ClipNotFound,
                })
            })
        } else {
            self.perform_ids("Edit Text", Some(&key), |p, _| {
                p.update_generator(id, generator.payload.clone(), Some(generator.payload_version))
            })
        };
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
        }
    }

    /// Replaces the captions of the first caption track (created when missing) as one undo step.
    // Swift: EditorSession+Generators.swift:126
    pub fn replace_captions(&mut self, items: Vec<sq_core_model::CaptionItem>) -> bool {
        self.attempt_keyed_ids("Create Captions", None, |t, ids| t.replace_captions(items, None, ids).map(|_| ()))
    }

    /// Applies Rounded Corners to the selected picture clips that do not have it yet.
    // Swift: EditorSession+Generators.swift:132
    pub fn add_rounded_corners(&mut self, radius: f64) -> bool {
        let ids = self.selection.clone();
        self.add_rounded_corners_to(&ids, radius)
    }

    /// Same for the given clips (an effect dropped on one clip): one undo step.
    // Swift: EditorSession+Generators.swift:138
    pub fn add_rounded_corners_to(&mut self, ids: &std::collections::BTreeSet<Id>, radius: f64) -> bool {
        if ids.is_empty() {
            return false;
        }
        self.attempt_keyed_ids("Add Rounded Corners", None, |t, ids_src| {
            let mut changed = false;
            for id in ids {
                let Some(tr) = t.tracks.iter_mut().find(|tr| tr.clip(*id).is_some()) else { continue };
                let Some(mut c) = tr.clip(*id).cloned() else { continue };
                if c.kind == TrackKind::Audio || c.rounded_corners_effect().is_some() {
                    continue;
                }
                c.set_rounded_corners_effect(Some(ClipEffect::rounded_corners(ids_src.next_id(), radius)));
                tr.replace(c);
                changed = true;
            }
            if changed { Ok(()) } else { Err(EditError::EmptyClip) }
        })
    }

    /// Places an empty graphics clip at `time` (default: playhead) on `track`, else on the topmost unlocked video track
    /// that is free there. One undo step; selects the new clip.
    // Swift: EditorSession+Graphics.swift:10
    pub fn add_graphics_clip(
        &mut self,
        at: Option<Time>,
        track: Option<Id>,
        duration: Time,
        layers: Vec<GraphicsLayer>,
        never_overwrite: bool,
    ) -> Option<Id> {
        let Some(t) = self.active_timeline() else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let fd = t.frame_duration();
        let start = at.unwrap_or(self.playhead).snapped(fd);
        let duration = duration.snapped(fd).max(fd);
        let (tl, new_track, chosen) = self.es5_generator_target(
            TimeRange::new(start, duration),
            track,
            never_overwrite,
            "There is no video track for the graphic.",
        )?;
        let mut new_id = None;
        let r = self.perform_ids("Add Graphic", None, |p, ids| {
            if let Some(nt) = new_track {
                p.edit(tl, |t| {
                    t.tracks.push(nt);
                    Ok(())
                })?;
            }
            new_id = Some(p.add_graphics_clip(
                GeneratorPlacement { timeline: tl, track: chosen, start, duration },
                layers,
                ids,
            )?);
            Ok(())
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return None;
        }
        if let Some(id) = new_id {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        new_id
    }

    /// Edits the layers of graphics clip `id` as one undo step (`key`: consecutive edits with the same key merge).
    /// Returns whether it was applied; a refusal (locked track) goes to `last_error`.
    // Swift: EditorSession+Graphics.swift:35
    pub fn edit_graphics(
        &mut self,
        id: Id,
        name: &str,
        key: Option<&str>,
        body: impl FnOnce(&mut sq_core_model::GraphicsDocument),
    ) -> bool {
        let before = self.history.current().clone();
        let mut body = Some(body);
        let r = self.perform_ids(name, key, |p, _| {
            p.edit_graphics(id, |d| {
                if let Some(b) = body.take() {
                    b(d);
                }
                Ok(())
            })
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return false;
        }
        *self.history.current() != before
    }

    /// Make Graphic: turns the selected text or shape clip into a graphics clip (one undo step).
    // Swift: EditorSession+Graphics.swift:45
    pub fn make_graphic(&mut self) -> bool {
        let (1, Some(id)) = (self.selection.len(), self.selection.iter().next().copied()) else { return false };
        if !self.project().can_convert_to_graphics(id) {
            return false;
        }
        match self.perform_ids("Make Graphic", None, |p, ids| p.convert_to_graphics(id, ids).map(|_| ())) {
            Ok(()) => true,
            Err(e) => {
                self.set_error(EditorSession::message_for(&e));
                false
            }
        }
    }

    /// Places a built-in sticker or lower third as a Graphics clip, one undo step.
    // Swift: EditorSession+Graphics.swift:54
    pub fn add_graphic_preset(&mut self, id: &str, at: Option<Time>, track: Option<Id>) -> Option<Id> {
        let Some(entry) = GraphicPresetCatalog::entry(id) else {
            self.set_error("That graphic is not available.");
            return None;
        };
        let Some(t) = self.active_timeline() else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let (w, h) = (t.format.display_width(), t.format.height);
        match entry.layers(w, h, self.ids.as_mut()) {
            Ok(layers) => self.add_graphics_clip(at, track, entry.duration, layers, false),
            Err(e) => {
                self.set_error(e);
                None
            }
        }
    }

    /// H1: places the built-in CTA end card as a Graphics clip.
    // Swift: EditorSession+Graphics.swift:65
    pub fn add_cta_end_card(&mut self, at: Option<Time>, track: Option<Id>) -> Option<Id> {
        let Some(t) = self.active_timeline() else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let (w, h) = (t.format.display_width(), t.format.height);
        match CTAEndCard::layers(w, h, self.ids.as_mut()) {
            Ok(layers) => self.add_graphics_clip(at, track, CTAEndCard::DURATION, layers, false),
            Err(e) => {
                self.set_error(e);
                None
            }
        }
    }

    /// Lane drag-out: moves (or copies) layers of Graphic `source` to another Graphic or a new one, one undo step.
    /// Returns the receiving Graphic and the layers' IDs there; a refusal goes to `last_error`.
    // Swift: EditorSession+GraphicsMoveOut.swift:7
    pub fn move_graphics_layers(
        &mut self,
        ids: &[Id],
        source: Id,
        dest: GraphicsLayerDestination,
        copy: bool,
    ) -> Option<MovedLayers> {
        let mut landed = None;
        let name = if copy { "Copy Layer Out" } else { "Move Layer Out" };
        let r = self.perform_ids(name, None, |p, new_ids| {
            let (clip, layers) = p.move_graphics_layers(ids, source, dest, copy, new_ids)?;
            landed = Some(MovedLayers { clip, layers });
            Ok(())
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return None;
        }
        landed
    }

    /// Places the Lottie animation `json` (file name `name`) at `time` on `track`, with the animation's own length.
    // Swift: EditorSession+Lottie.swift:9
    pub fn add_lottie_clip(&mut self, json: &[u8], name: &str, at: Option<Time>, track: Option<Id>) -> Option<Id> {
        let Some(t) = self.active_timeline() else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let tl = self.active_timeline_id?;
        let Some(info) = LottieInfo::parse(json) else {
            self.set_error(LottieImportError::Invalid.to_string());
            return None;
        };
        let fd = t.frame_duration();
        let start = at.unwrap_or(self.playhead).snapped(fd);
        let duration = info.duration().ceiled(fd);
        let Some(chosen) = generator_track(t, TimeRange::new(start, duration), track, true) else {
            self.set_error("There is no video track for the animation.");
            return None;
        };
        let mut new_id = None;
        let r = self.perform_ids("Add Lottie Animation", None, |p, ids| {
            let placement = GeneratorPlacement { timeline: tl, track: chosen, start, duration };
            new_id = Some(p.add_lottie_clip(json.to_vec(), name, placement, true, ids).map_err(|e| match e {
                LottieImportError::Edit(e) => e,
                LottieImportError::Invalid => EditError::EmptyClip,
            })?);
            Ok(())
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return None;
        }
        if let Some(id) = new_id {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        new_id
    }

    /// Reads a Lottie file and places it. Over-size or unreadable files go to `last_error`.
    // Swift: EditorSession+Lottie.swift:29
    pub fn add_lottie_clip_file(&mut self, url: &Path, at: Option<Time>, track: Option<Id>) -> Option<Id> {
        let data = std::fs::metadata(url)
            .ok()
            .filter(|m| m.len() as usize <= LottieLimits::MAX_BYTES)
            .and_then(|_| std::fs::read(url).ok());
        let Some(data) = data else {
            self.set_error(LottieImportError::Invalid.to_string());
            return None;
        };
        let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        self.add_lottie_clip(&data, &name, at, track)
    }

    /// Places a shape at `time` on `track`, sized to the sequence. One undo step; selects the new clip.
    // Swift: EditorSession+Shapes.swift:9
    pub fn add_shape_clip(
        &mut self,
        kind: ShapeKind,
        at: Option<Time>,
        track: Option<Id>,
        duration: Time,
    ) -> Option<Id> {
        let Some(t) = self.active_timeline() else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let tl = self.active_timeline_id?;
        let fd = t.frame_duration();
        let start = at.unwrap_or(self.playhead).snapped(fd);
        let duration = duration.snapped(fd).max(fd);
        let Some(chosen) = generator_track(t, TimeRange::new(start, duration), track, true) else {
            self.set_error("There is no video track for the shape.");
            return None;
        };
        let mut new_id = None;
        let r = self.perform_ids(&format!("Add {}", kind.title()), None, |p, ids| {
            new_id = Some(p.add_shape_clip(
                kind,
                GeneratorPlacement { timeline: tl, track: chosen, start, duration },
                ids,
            )?);
            Ok(())
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return None;
        }
        if let Some(id) = new_id {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        new_id
    }

    /// Switches a shape clip's outline (size, colors and keys stay). One undo step.
    // Swift: EditorSession+Shapes.swift:29
    pub fn set_shape_kind(&mut self, kind: ShapeKind, id: Id) {
        let same = self.es5_clip(id).and_then(|c| c.generator.as_ref()).is_some_and(|g| g.shape_kind() == Some(kind));
        if self.es5_clip(id).is_none() || same {
            return;
        }
        if let Err(e) = self.perform_ids("Change Shape", None, |p, _| p.set_shape_kind(id, kind)) {
            self.set_error(EditorSession::message_for(&e));
        }
    }

    /// Applies a `textlook.` (style only) or `textanim.` (motion only) preset to the text layers among `ids`.
    /// Returns false when none of them is a text layer or the id is unknown.
    // Swift: EditorSession+TextPresets.swift:9
    pub fn add_text_preset(&mut self, id: &str, to: &std::collections::BTreeSet<Id>) -> bool {
        let look = TextPresetCatalog::look(id);
        let motion = TextPresetCatalog::motion(id);
        if (look.is_none() && motion.is_none()) || to.is_empty() {
            return false;
        }
        let title = match (&look, &motion) {
            (Some(l), _) => format!("Text Look: {}", l.name),
            (None, Some(m)) => format!("Text Animation: {}", m.name),
            (None, None) => String::new(),
        };
        self.attempt_keyed_ids(&title, None, |t, _| {
            let mut changed = false;
            for cid in to {
                let Some(tr) = t.tracks.iter_mut().find(|tr| tr.clip(*cid).is_some()) else { continue };
                let Some(mut c) = tr.clip(*cid).cloned() else { continue };
                let Some(mut g) = c.generator.clone().filter(|g| g.kind == TextGenerator::KIND) else { continue };
                if let Some(l) = &look {
                    g = TextPresetApply::apply_look_to_ref(l, &g).map_err(|_| EditError::EmptyClip)?;
                } else if let Some(m) = &motion {
                    g = TextPresetApply::apply_motion_to_ref(m, &g).map_err(|_| EditError::EmptyClip)?;
                }
                c.generator = Some(g);
                tr.replace(c);
                changed = true;
            }
            if changed { Ok(()) } else { Err(EditError::WrongTrackKind) }
        })
    }

    /// The Look a text was last given (`None` when none yet, or it was deleted since).
    // Swift: EditorSession+Title.swift:47
    pub fn last_used_text_look(&self, defaults: &dyn SettingsStore, store: &LookStore) -> Option<LookRef> {
        let raw = String::from_utf8(defaults.data(Self::LAST_TEXT_LOOK_KEY)?).ok()?;
        let (scope, id) = raw.split_once(':')?;
        let r = LookRef::new(LookScope::from_raw(scope)?, id);
        self.look(&r, store).map(|_| r)
    }

    /// Sequence > Add Title: ONE Graphic clip at the playhead with the title's text layers, styled and animated by the
    /// last-used Look. One undo step. Returns the clip's ID in a vector; empty when refused.
    // Swift: EditorSession+Title.swift:62
    pub fn add_title(
        &mut self,
        at: Option<Time>,
        duration: Time,
        look_defaults: &dyn SettingsStore,
        store: &LookStore,
    ) -> Vec<Id> {
        let Some(t) = self.active_timeline() else {
            self.set_error("Open a sequence first.");
            return Vec::new();
        };
        let look = self.last_used_text_look(look_defaults, store).and_then(|r| self.look(&r, store).map(|l| (r, l)));
        let mut layers = Vec::new();
        for part in TitleBuilder::parts(&t.format) {
            let mut template = part.template.clone();
            let mut anims = None;
            if let Some((r, l)) = &look {
                let (given, a) = Self::giving_look(l, &r.token(), &template, None);
                anims = a;
                template = given;
            }
            let generator = match TextGenerator::make_ref(&template, anims.as_ref()) {
                Ok(g) => g,
                Err(e) => {
                    self.set_error(e.to_string());
                    return Vec::new();
                }
            };
            let mut layer = GraphicsLayer::text(self.ids.next_id(), generator, &template.text);
            layer.animation.position = AnimatedProperty::new(part.position);
            layers.push(layer);
        }
        let first = layers.first().map(|l| l.id);
        let Some(id) = self.add_graphics_clip(at, None, duration, layers, true) else { return Vec::new() };
        if let Some(first) = first {
            self.set_graphic_layer_selection(Some(GraphicLayerSelection { clip: id, layers: BTreeSet::from([first]) }));
        }
        vec![id]
    }
}

/// One text clip of the video title.
// Swift: EditorSession+Title.swift:12
#[derive(Clone, Debug, PartialEq)]
pub struct TitlePart {
    // Swift: EditorSession+Title.swift:13
    pub template: TextTemplate,
    // Swift: EditorSession+Title.swift:14
    pub position: Vec2,
    // Swift: EditorSession+Title.swift:15
    pub transition: TransitionKind,
    /// Move direction in degrees (270 = in from the left, 90 = from the right); `None` for Pop.
    // Swift: EditorSession+Title.swift:17
    pub direction: Option<f64>,
}

/// The video title: two lines, each its own text clip animated on its own.
// shortcut: the default title has no emoji layer (the Swift one had a fire emoji) because the portable text path cannot draw
// Noto Color Emoji (CBDT bitmaps) on Linux; upgrade when CBDT/COLRv1 color glyphs render, then add the third part back.
pub enum TitleBuilder {}

impl TitleBuilder {
    // Swift: EditorSession+Title.swift:9
    pub const PLACEHOLDER_TEXTS: [&'static str; 2] = ["Line One", "Line Two"];
    // Swift: EditorSession+Title.swift:10
    pub const DEFAULT_DURATION: Time = Time::new(3, 1);

    /// Lines in the upper third, line 2 under line 1. Sizes follow the frame's short side.
    // Swift: EditorSession+Title.swift:21
    pub fn parts(format: &SequenceFormat) -> Vec<TitlePart> {
        let short = format.display_width().min(format.height) as f64;
        let h = format.height as f64;
        let mut style = CaptionPresetLibrary::built_in().style(Some("title"));
        style.size = (short * 0.08).round();
        style.weight = FontWeight::Heavy;
        let y1 = (-h * 0.22).round();
        let t = Self::PLACEHOLDER_TEXTS;
        let second_y = y1 + (style.size * 1.25).round();
        vec![
            TitlePart {
                template: TextTemplate::new("Title Line 1", t[0], style.clone()),
                position: Vec2::new(0.0, y1),
                transition: TransitionKind::Move,
                direction: Some(270.0),
            },
            TitlePart {
                template: TextTemplate::new("Title Line 2", t[1], style),
                position: Vec2::new(0.0, second_y),
                transition: TransitionKind::Move,
                direction: Some(90.0),
            },
        ]
    }
}
