//! Title blocks and title templates, the project style kit, caption Look gallery and template styles on the session.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use sq_core_audio::TimelineCaptionsExt;
use sq_core_edit::timeline_clipboard::TimelineClipboardExt;
use sq_core_edit::timeline_title_block::TitleBlockExt;
use sq_core_edit::timeline_title_tracks::TimelineTitleTracksExt;
use sq_core_edit::title_template::{ProjectTitleTemplateExt, TitleTemplateExt};
use sq_core_effects::style_kit::{
    CAPTION_ANIMATION_REF, CAPTION_STYLE_REF, StyleKitExt, StyleKitFile, StyleKitMergeReport,
};
use sq_core_model::{
    Clip, EditError, GeneratorRef, GraphicsContent, SlotValue, StyleKit, TemplateEditError, TemplateSlot,
    TemplateSlotKind, Timeline, TitleTemplateError, TrackKind,
};
use sq_core_time::{Id, Time, TimeRange};
use sq_library::title_block::TitleBlock;
use sq_text::caption_style_looks::{CaptionStyleLook, CaptionStyleLooks};
use sq_text::look::{Look, StyleKitLookExt};
use sq_text::style_kit_pauls::StyleKitPaulsExt;
use sq_text::style_kit_text::{ProjectTextExt, StyleKitTextExt};
use sq_text::template_text_style::TemplateTextStyle;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;

use crate::EditorSession;
use crate::es04_effects::LookTarget;
use sq_core_audio::TimelineCaptionEditsExt as TimelineCaptionEdits;

pub use sq_core_model::TitleTemplate;

impl EditorSession {
    /// Replaces the project's kit; every token-bound text clip is re-resolved in the same undo step.
    // Swift: EditorSession+StyleKit.swift:9
    pub fn set_style_kit(&mut self, kit: Option<StyleKit>, name: &str) {
        if kit == self.project().style_kit {
            return;
        }
        // `perform` re-resolves the token-bound text clips (see `perform_steps`).
        self.perform(name, None, |p| p.style_kit = kit);
    }

    /// Imports a `.sqstyle`: adds its tokens and looks without overwriting the project's own brand tokens.
    // Swift: EditorSession+StyleKit.swift:15
    pub fn import_style_kit(&mut self, url: &Path) -> Result<StyleKitMergeReport, String> {
        let other = StyleKitFile::read(url).map_err(|e| e.to_string())?;
        let (merged, report) = self.project().style_kit.clone().unwrap_or_default().merging(&other);
        self.set_style_kit(Some(merged), "Import Style Kit");
        Ok(report)
    }

    /// Imports the bundled maintainer's Kit like a `.sqstyle`: the project's own tokens stay.
    // Swift: EditorSession+StyleKit.swift:24
    pub fn import_pauls_kit(&mut self) -> StyleKitMergeReport {
        let (merged, report) = self.project().style_kit.clone().unwrap_or_default().merging(&StyleKit::pauls());
        self.set_style_kit(Some(merged), "Imported Kit");
        report
    }

    /// Writes the project's kit (the starter kit when the project has none) as a `.sqstyle`.
    // Swift: EditorSession+StyleKit.swift:32
    pub fn export_style_kit(&self, url: &Path) -> Result<(), String> {
        let legacy = self.project().uses_legacy_built_in_font();
        let kit = self.project().style_kit.clone().unwrap_or_else(|| StyleKit::starter_with(legacy));
        StyleKitFile::write(&kit, url).map_err(|e| e.to_string())
    }

    /// Every caption of the active sequence uses the kit caption style (one undo step). False without a kit caption style.
    // Swift: EditorSession+StyleKit.swift:37
    pub fn use_kit_caption_style(&mut self) -> bool {
        if self.project().style_kit.as_ref().is_none_or(|k| k.caption.is_none()) {
            return false;
        }
        self.set_caption_style(CAPTION_STYLE_REF, Some(CAPTION_ANIMATION_REF))
    }

    /// Saves the caption look on screen into the project's kit under `name`. Returns the kit look id; `None` without captions.
    // Swift: EditorSession+StyleKit.swift:46
    pub fn save_caption_look_to_kit(&mut self, name: &str) -> Option<String> {
        let look = self.current_caption_look()?;
        let clean = name.trim();
        if clean.is_empty() {
            return None;
        }
        let mut kit = self.project().style_kit.clone().unwrap_or_default();
        let existing = kit.looks.iter().find(|(_, v)| v.name == clean).map(|(k, _)| k.clone());
        let id = existing.unwrap_or_else(|| unique_kit_look_id(clean, &kit));
        kit.add_look(&look, &id, clean).ok()?;
        self.set_style_kit(Some(kit), "Save Look to Style Kit");
        Some(id)
    }

    /// Applies the gallery `look` to the caption track `track` (default: the track the Look tab edits): style,
    /// animation and word highlight in one undo step. False without a caption track.
    // Swift: EditorSession+StyleLooks.swift:12
    pub fn apply_caption_style_look(&mut self, look: &CaptionStyleLook, track: Option<Id>) -> bool {
        self.apply_caption_look(look, track, false)
    }

    /// The Style tab's tile pick: only the look (style and word highlight). The track keeps the animation it has;
    /// the animation is its own row (Motion).
    pub fn apply_caption_style_look_only(&mut self, look: &CaptionStyleLook, track: Option<Id>) -> bool {
        self.apply_caption_look(look, track, true)
    }

    fn apply_caption_look(&mut self, look: &CaptionStyleLook, track: Option<Id>, keep_animation: bool) -> bool {
        let Some(tl) = self.active_timeline() else { return false };
        let Some(target) = track.and_then(|t| tl.caption_track(t)).or_else(|| self.current_caption_track()) else {
            return false;
        };
        let animation = if keep_animation { target.animation_ref.clone() } else { look.animation_ref.clone() };
        let (id, items): (Id, BTreeSet<Id>) = (target.id, target.items().iter().map(|i| i.id).collect());
        self.attempt_keyed_ids("Caption Look", None, |t, _| {
            t.set_caption_style(&look.style_ref, Some(&animation), id, false)?;
            t.set_track_karaoke(look.karaoke.clone(), id)?;
            t.set_caption_item_style(&items, None)?;
            if keep_animation { Ok(()) } else { t.set_caption_item_animation(&items, None) }
        })
    }

    /// The gallery look the current caption track shows now (`None`: none, or edited since).
    // Swift: EditorSession+StyleLooks.swift:26
    pub fn current_caption_style_look(&self) -> Option<CaptionStyleLook> {
        let t = self.current_caption_track()?;
        CaptionStyleLooks::matching(&t.style_ref, &t.animation_ref, t.karaoke.as_ref()).cloned()
    }

    /// True when the selection is one text item or captions are the target (the template-style pick applies there).
    // Swift: EditorSession+TemplateStyle.swift:11
    pub fn can_apply_template_style(&self) -> bool {
        self.look_target().is_some()
    }

    /// Gives the first text layer of a Library title template to the selected text, or to a caption track.
    // Swift: EditorSession+TemplateStyle.swift:19
    pub fn apply_template_style(&mut self, template: &TitleTemplate, caption_track: Option<Id>) -> bool {
        let Some(target) = self.look_target() else { return false };
        let Some(style) = TemplateTextStyle::from_tracks(&template.content.tracks) else { return false };
        if target == LookTarget::Captions {
            return self.apply_caption_template_style(&style, template, caption_track);
        }
        let Some((text, anims)) = self.text_content(target) else { return false };
        let (given, animations) = style.giving(&text, anims.as_ref());
        self.write_text(target, &given, animations.as_ref())
    }

    /// The template becomes a project Look named like it (re-applying updates that Look); the track follows it, so new
    /// captions on the track inherit style, shadow and animation.
    /// A caption plays one animation, so of the template's in and out only the in animation (else the out) is kept
    /// (Swift does the same, `EditorSession+TemplateStyle.swift:34`).
    // Swift: EditorSession+TemplateStyle.swift:35
    fn apply_caption_template_style(
        &mut self,
        style: &TemplateTextStyle,
        template: &TitleTemplate,
        track: Option<Id>,
    ) -> bool {
        let id = format!("template-{}", template.name);
        let animation =
            style.animations.as_ref().and_then(|a| a.animation_in.clone().or_else(|| a.animation_out.clone()));
        let look = Look { animation, ..Look::new(&id, &template.name, style.style.clone()) };
        let mut kit = self.project().style_kit.clone().unwrap_or_default();
        if kit.set_look(&look).is_err() {
            return false;
        }
        let token = StyleKit::look_id(&id);
        self.give_caption_tracks(&look, &token, &token, Some(kit), track)
    }

    /// True when the selection can be saved as a title block: only generator clips, at least one.
    // Swift: EditorSession+TitleBlock.swift:9
    pub fn can_save_selection_as_title_block(&self) -> bool {
        self.active_timeline().is_some_and(|t| t.is_media_free(&self.selection))
    }

    /// The selection as a title block; `None` with a fresh `last_error` when something selected has media.
    // Swift: EditorSession+TitleBlock.swift:15
    pub fn title_block_from_selection(&mut self) -> Option<TitleBlock> {
        let Some(t) = self.active_timeline() else {
            self.set_error("Select the title clips first.");
            return None;
        };
        if self.selection.is_empty() {
            self.set_error("Select the title clips first.");
            return None;
        }
        let block = if t.is_media_free(&self.selection) {
            t.clipboard(&self.selection).and_then(TitleBlock::new)
        } else {
            None
        };
        if block.is_none() {
            self.set_error("A title block holds only text, shape and adjustment clips. Deselect clips with media.");
        }
        block
    }

    /// Places `block` at `time` (default the playhead) on free tracks above whatever plays there, as one undo step.
    // Swift: EditorSession+TitleBlock.swift:26
    pub fn insert_title_block(&mut self, block: &TitleBlock, at: Option<Time>) -> Vec<Id> {
        let (Some(tl), Some(fd)) = (self.active_timeline_id, self.active_timeline().map(Timeline::frame_duration))
        else {
            self.set_error("Open a sequence first.");
            return Vec::new();
        };
        let start = at.unwrap_or(self.playhead).snapped(fd);
        let mut ids: Vec<Id> = Vec::new();
        let r = self.perform_ids("Insert Title Block", None, |p, src| {
            p.edit(tl, |t| {
                ids = t.place_block(&block.block, start, src)?;
                Ok(())
            })
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return Vec::new();
        }
        let texts: Vec<Id> = ids
            .iter()
            .zip(&block.block.entries)
            .filter(|(_, e)| e.clip.generator.as_ref().is_some_and(|g| g.kind == TextGenerator::KIND))
            .map(|(i, _)| *i)
            .collect();
        if let Some(first) = texts.first().or(ids.first()) {
            self.select(BTreeSet::from([*first]), BTreeSet::new());
        }
        ids
    }

    /// True when the selection holds at least one video-track clip (text, shape, graphic or footage).
    // Swift: EditorSession+TitleTemplate.swift:11
    pub fn can_save_selection_as_template(&self) -> bool {
        self.active_timeline().is_some_and(|t| {
            t.tracks
                .iter()
                .any(|tr| tr.kind == TrackKind::Video && tr.clips().iter().any(|c| self.selection.contains(&c.id)))
        })
    }

    /// Selected video-track clips that can carry animation zones.
    // Swift: EditorSession+TitleTemplate.swift:17
    pub fn selected_zone_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks
            .iter()
            .filter(|tr| tr.kind == TrackKind::Video)
            .flat_map(|tr| tr.clips().iter().filter(|c| self.selection.contains(&c.id)).cloned())
            .collect()
    }

    /// True when the playhead lies inside a selected video clip.
    // Swift: EditorSession+TitleTemplate.swift:23
    pub fn playhead_is_inside_selected_video(&self) -> bool {
        let playhead = self.playhead;
        self.selected_zone_clips().iter().any(|c| c.start <= playhead && playhead < c.timeline().end())
    }

    /// The selection as a template named `name`; `None` with a fresh `last_error` when nothing usable is selected.
    // Swift: EditorSession+TitleTemplate.swift:29
    pub fn title_template_from_selection(&mut self, name: &str) -> Option<TitleTemplate> {
        let (Some(tl_id), true) = (self.active_timeline_id, self.can_save_selection_as_template()) else {
            self.set_error("Select the title layers first.");
            return None;
        };
        let t = self.active_timeline()?;
        let video_ids: Vec<Id> = t
            .tracks
            .iter()
            .filter(|tr| tr.kind == TrackKind::Video)
            .flat_map(|tr| tr.clips().iter().filter(|c| self.selection.contains(&c.id)).map(|c| c.id))
            .collect();
        let picked: Vec<Clip> =
            t.tracks.iter().flat_map(|tr| tr.clips().iter()).filter(|c| video_ids.contains(&c.id)).cloned().collect();
        let shift = picked.iter().map(|c| c.start).min().unwrap_or(Time::ZERO);
        let extra = Self::text_animation_key_times(&picked, shift);
        let captured =
            self.with_ids(|s, ids| TitleTemplate::capture(&video_ids, tl_id, s.project(), name, &extra, ids));
        let mut template = match captured {
            Ok(t) => t,
            Err(e) => {
                self.set_error(Self::message_for(&e));
                return None;
            }
        };
        if let Some(first) = template.slots.iter().find(|s| s.kind == TemplateSlotKind::Text) {
            let (layer, gl) = (first.layer, first.graphics_layer);
            let slot = |ids: &mut dyn sq_core_time::IdSource, name: &str, kind, path: &str, value| TemplateSlot {
                id: ids.next_id(),
                name: name.to_string(),
                kind,
                layer,
                graphics_layer: gl,
                path: path.to_string(),
                value,
            };
            let color = Self::style_value(&template, layer, gl, |s| SlotValue::Color {
                red: s.color.red,
                green: s.color.green,
                blue: s.color.blue,
                alpha: s.color.alpha,
            })
            .unwrap_or(SlotValue::Color { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 });
            let font = Self::style_value(&template, layer, gl, |s| SlotValue::Font(s.font_name.clone()))
                .unwrap_or_else(|| SlotValue::Font(TextStyle::default_font_name().to_string()));
            let size = Self::style_value(&template, layer, gl, |s| SlotValue::Number(s.size))
                .unwrap_or(SlotValue::Number(48.0));
            let extra_slots = self.with_ids(|_, ids| {
                vec![
                    slot(ids, "Color", TemplateSlotKind::Color, "template.style.color", color),
                    slot(ids, "Font", TemplateSlotKind::Font, "template.style.fontName", font),
                    slot(ids, "Size", TemplateSlotKind::Number, "template.style.size", size),
                ]
            });
            template.slots.extend(extra_slots);
        }
        Some(template)
    }

    // Swift: EditorSession+TitleTemplate.swift:55
    fn style_value(
        template: &TitleTemplate,
        layer: Id,
        graphics_layer: Option<Id>,
        make: impl Fn(&TextStyle) -> SlotValue,
    ) -> Option<SlotValue> {
        let clip = template.content.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == layer)?;
        let mut r: Option<&GeneratorRef> = clip.generator.as_ref();
        if let Some(gl) = graphics_layer {
            let GraphicsContent::Text { generator } = &clip.graphics()?.layer(gl)?.content else { return None };
            r = Some(generator);
        }
        let (t, _) = TextGenerator::decode(r?).ok()?;
        Some(make(&t.style))
    }

    /// End of every text layer's in animation and start of its out animation, in the time of a template that starts at
    /// `shift` (zones need keys where the core sees none: the text animation lives in the payload).
    // Swift: EditorSession+TitleTemplate.swift:68
    pub(crate) fn text_animation_key_times(clips: &[Clip], shift: Time) -> Vec<Time> {
        let mut times: Vec<Time> = Vec::new();
        for c in clips {
            let mut refs: Vec<&GeneratorRef> = Vec::new();
            if let Some(g) = c.generator.as_ref().filter(|g| g.kind == TextGenerator::KIND) {
                refs.push(g);
            }
            for l in c.graphics().map(|d| d.layers.as_slice()).unwrap_or_default() {
                if let GraphicsContent::Text { generator } = &l.content {
                    refs.push(generator);
                }
            }
            let base = c.start - shift;
            for g in refs {
                let Ok((_, Some(set))) = TextGenerator::decode(g) else { continue };
                if let Some(i) = set.animation_in.as_ref().filter(|i| i.duration > Time::ZERO) {
                    times.push(base + i.duration);
                }
                if let Some(o) = set.out_start(c.timeline().duration) {
                    times.push(base + o);
                }
            }
        }
        times
    }

    /// The message of a template edit error (an `EditError` has its own text).
    pub(crate) fn message_for_template(error: &TemplateEditError) -> String {
        match error {
            TemplateEditError::Edit(e) => Self::message_for(e),
            TemplateEditError::Template(e) => e.to_string(),
        }
    }

    /// Places `template` at `time` as one undo step: on `track` when given (video, unlocked; `apply_title_template` refuses
    /// others), else on a free video track above whatever plays there.
    // Swift: EditorSession+TitleTemplate.swift:89
    pub fn insert_title_template(
        &mut self,
        template: &TitleTemplate,
        at: Option<Time>,
        track: Option<Id>,
    ) -> Option<Id> {
        let (Some(tl), Some(fd)) = (self.active_timeline_id, self.active_timeline().map(Timeline::frame_duration))
        else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let start = at.unwrap_or(self.playhead).snapped(fd);
        let range = TimeRange::new(start, template.duration().snapped(fd).max(fd));
        let mut placed: Option<Id> = None;
        let result = self.with_ids(|s, ids| {
            s.try_perform("Insert Title Template", None, |p| {
                let mut target: Option<Id> = track;
                if target.is_none() {
                    p.edit(tl, |t| {
                        target = t.stacked_title_tracks(1, range, ids).first().copied();
                        Ok(())
                    })?;
                }
                let target = target.ok_or(EditError::ClipNotFound)?;
                placed = Some(p.apply_title_template(template, tl, target, start, None, &BTreeMap::new(), ids)?);
                Ok::<(), TemplateEditError>(())
            })
        });
        if let Err(e) = result {
            self.set_error(Self::message_for_template(&e));
            return None;
        }
        if let Some(p) = placed {
            self.select(BTreeSet::from([p]), BTreeSet::new());
        }
        placed
    }

    /// Changes one slot of an applied template clip. `continues_gesture` merges a drag or typing into one undo step.
    // Swift: EditorSession+TitleTemplate.swift:109
    pub fn set_template_slot(&mut self, slot: Id, value: SlotValue, clip: Id, continues_gesture: bool) {
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let key = format!("templateSlot:{clip}:{slot}:{}", self.gesture_counter);
        let result = self.with_ids(|s, ids| {
            s.try_perform("Edit Template", Some(&key), |p| p.set_template_slot(slot, value, clip, ids))
        });
        if let Err(e) = result {
            self.set_error(Self::message_for_template(&e));
        }
    }

    /// Turns a clip's animation zones on (auto-detected) or off. Returns whether it was applied.
    // Swift: EditorSession+TitleTemplate.swift:120
    pub fn set_zones_enabled(&mut self, on: bool, clip: Id) -> bool {
        let Some(found) = self.es5_clip(clip).cloned() else { return false };
        let name = if on { "Turn Zones On" } else { "Turn Zones Off" };
        let result = self.with_ids(|s, ids| {
            let _ = ids;
            s.try_perform(name, None, |p| {
                if !on {
                    p.set_animation_zones(None, clip)?;
                    return Ok::<(), TemplateEditError>(());
                }
                if found.template_slots.is_some()
                    && let Some(seq) = found.sequence.and_then(|q| p.timeline(q))
                {
                    let videos: Vec<Clip> = seq
                        .tracks
                        .iter()
                        .filter(|t| t.kind == TrackKind::Video)
                        .flat_map(|t| t.clips().iter().cloned())
                        .collect();
                    let extra = Self::text_animation_key_times(&videos, Time::ZERO);
                    let mut z = TitleTemplate::detect_zones(seq, &extra);
                    if let Some(old) = &found.zones {
                        z.middle = old.middle;
                    }
                    p.set_animation_zones(Some(z), clip)?;
                } else {
                    p.auto_detect_animation_zones(clip)?;
                }
                Ok(())
            })
        });
        match result {
            Ok(()) => true,
            Err(TemplateEditError::Template(TitleTemplateError::NoKeyframes)) => {
                self.set_error("This clip has no keyframes, so there is no intro or outro to keep.");
                false
            }
            Err(e) => {
                self.set_error(Self::message_for_template(&e));
                false
            }
        }
    }

    /// What the middle of a clip with zones does when the clip gets longer or shorter.
    // Swift: EditorSession+TitleTemplate.swift:143
    pub fn set_zone_middle(&mut self, middle: sq_core_model::ZoneMiddle, clip: Id) {
        let Some(mut z) = self.es5_clip(clip).and_then(|c| c.zones.clone()) else { return };
        z.middle = middle;
        if let Err(e) = self.perform_ids("Set Zone Middle", None, |p, _| p.set_animation_zones(Some(z), clip)) {
            self.set_error(EditorSession::message_for(&e));
        }
    }
}

/// A kit look id from a name: lowercase letters and digits joined by "-", numbered when taken.
fn unique_kit_look_id(name: &str, kit: &StyleKit) -> String {
    let slug: String = name.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
    let slug = slug.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    let base = if slug.is_empty() { "look".to_string() } else { slug };
    let (mut id, mut n) = (base.clone(), 2);
    while kit.looks.contains_key(&id) {
        id = format!("{base}-{n}");
        n += 1;
    }
    id
}
