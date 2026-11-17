//! Looks on the selection: the list, the target, apply/update/save/rename/delete and the monitor hover preview.

use sq_core_model::anchored_animation::{AnimationAnchor, AnimationSet, KeyframeTemplate};
use sq_core_model::{Clip, GeneratorRef, GraphicsContent, KaraokeStyle, StyleKit};
use sq_core_time::Id;
use sq_playback::engine::LookPreview;
use sq_text::caption_presets::CaptionLook;
use sq_text::look::{Look, LookLibrary, LookState, LookValues, StyleKitLookExt};
use sq_text::style_kit_text::StyleKitTextExt;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;
use sq_text::text_template::TextTemplate;

use super::look_store::{LookStore, StoreError};
use crate::{CaptionStyleEdit, EditorSession, TimelineCaptionEdits};

/// Where a Look lives.
// Swift: EditorSession+Looks.swift:6
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LookScope {
    BuiltIn,
    User,
    Project,
}

/// A Look and where it lives.
// Swift: EditorSession+Looks.swift:9
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct LookRef {
    // Swift: EditorSession+Looks.swift:10
    pub scope: LookScope,
    // Swift: EditorSession+Looks.swift:11
    pub id: String,
}

impl LookScope {
    /// The stored name of the scope (`scope:id` of the last used Look).
    pub fn raw_value(self) -> &'static str {
        match self {
            LookScope::BuiltIn => "builtIn",
            LookScope::User => "user",
            LookScope::Project => "project",
        }
    }

    /// The scope stored under `raw`.
    pub fn from_raw(raw: &str) -> Option<LookScope> {
        [LookScope::BuiltIn, LookScope::User, LookScope::Project].into_iter().find(|s| s.raw_value() == raw)
    }
}

impl LookRef {
    // Swift: EditorSession+Looks.swift:12
    pub fn new(scope: LookScope, id: &str) -> LookRef {
        LookRef { scope, id: id.to_string() }
    }
    /// The id a text clip or caption track remembers (project Looks carry the Style Kit prefix).
    // Swift: EditorSession+Looks.swift:16
    pub fn token(&self) -> String {
        if self.scope == LookScope::Project { StyleKit::look_id(&self.id) } else { self.id.clone() }
    }
}

/// One row of the Looks list.
// Swift: EditorSession+Looks.swift:19
#[derive(Clone, Debug, PartialEq)]
pub struct LookEntry {
    // Swift: EditorSession+Looks.swift:20
    pub ref_: LookRef,
    // Swift: EditorSession+Looks.swift:21
    pub look: Look,
}

impl LookEntry {
    // Swift: EditorSession+Looks.swift:22
    pub fn id(&self) -> String {
        self.ref_.token()
    }
}

/// What a Look is applied to.
// Swift: EditorSession+Looks.swift:25
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LookTarget {
    TextClip(Id),
    GraphicText(Id, Id),
    Captions,
}

/// Prefix of the Looks a caption track keeps for itself (`CaptionStyleEdit.ownLookPrefix`).
const OWN_LOOK_PREFIX: &str = "own-";
/// Prefix of the project Look copies of built-in Looks (`EditorSession.builtInLookPrefix`).
pub(crate) const BUILT_IN_LOOK_PREFIX: &str = "builtin-";

/// Kit Looks the list does not show: a caption track's own and the copies of built-in ones.
fn is_hidden_kit_look(id: &str) -> bool {
    id.starts_with(OWN_LOOK_PREFIX) || id.starts_with(BUILT_IN_LOOK_PREFIX)
}

impl EditorSession {
    /// Settings key of the Look a text last received (`scope:id`); Add Title starts from it.
    // Swift: EditorSession+Title.swift:43
    pub const LAST_TEXT_LOOK_KEY: &'static str = "sq.lastTextLook";

    /// Built-in, user and project Looks in that order.
    // Swift: EditorSession+Looks.swift:46
    pub fn looks(&self, store: &LookStore) -> Vec<LookEntry> {
        let project = self.project().style_kit.as_ref().map(|k| k.project_looks()).unwrap_or_default();
        let entry = |scope, look: Look| LookEntry { ref_: LookRef::new(scope, &look.id), look };
        LookLibrary::built_ins()
            .iter()
            .cloned()
            .map(|l| entry(LookScope::BuiltIn, l))
            .chain(store.library().user().iter().cloned().map(|l| entry(LookScope::User, l)))
            .chain(project.into_iter().filter(|l| !is_hidden_kit_look(&l.id)).map(|l| entry(LookScope::Project, l)))
            .collect()
    }
    // Swift: EditorSession+Looks.swift:52
    pub fn look(&self, r: &LookRef, store: &LookStore) -> Option<Look> {
        match r.scope {
            LookScope::BuiltIn => LookLibrary::built_ins().iter().find(|l| l.id == r.id).cloned(),
            LookScope::User => store.library().look(&r.id).filter(|l| !l.is_built_in),
            LookScope::Project => self.project().style_kit.as_ref().and_then(|k| k.look(&r.id)),
        }
    }
    // Swift: EditorSession+Looks.swift:60
    pub fn look_target(&self) -> Option<LookTarget> {
        if let [id] = self.selection.iter().copied().collect::<Vec<_>>().as_slice() {
            if let Some(sel) = self.graphic_layer_selection().filter(|s| s.clip == *id && s.layers.len() == 1)
                && let Some(layer) = sel.layers.iter().next().copied()
                && self.text_content(LookTarget::GraphicText(*id, layer)).is_some()
            {
                return Some(LookTarget::GraphicText(*id, layer));
            }
            if self.text_content(LookTarget::TextClip(*id)).is_some() {
                return Some(LookTarget::TextClip(*id));
            }
        }
        self.active_timeline().filter(|t| !t.caption_tracks.is_empty()).map(|_| LookTarget::Captions)
    }
    /// Whether the target's style still equals the Look it was given.
    // Swift: EditorSession+Looks.swift:72
    pub fn look_state(&self, store: &LookStore) -> LookState {
        let Some(cur) = self.current_look_values(store, None) else { return LookState::None };
        let Some(r) = cur.applied else { return LookState::None };
        let Some(look) = self.look(&r, store) else { return LookState::None };
        if !cur.carried || look.differs(&cur.style, cur.animation.as_ref()) {
            LookState::Edited(r.token())
        } else {
            LookState::Applied(r.token())
        }
    }
    /// The Look the target was given, if it still exists.
    // Swift: EditorSession+Looks.swift:79
    pub fn applied_look(&self, store: &LookStore) -> Option<LookRef> {
        self.current_look_values(store, None)?.applied
    }
    /// Gives the target the Look: one undo step. A Look without an animation leaves the target's animation as it is.
    /// The app remembers a successful text Look with `remember_text_look` (Swift did it here through UserDefaults).
    // Swift: EditorSession+Looks.swift:82
    pub fn apply_look(&mut self, r: &LookRef, store: &LookStore, caption_track: Option<Id>) -> bool {
        let (Some(target), Some(look)) = (self.look_target(), self.look(r, store)) else { return false };
        match target {
            LookTarget::TextClip(_) | LookTarget::GraphicText(..) => {
                let Some((template, anims)) = self.text_content(target) else { return false };
                let (template, anims) = Self::giving_look(&look, &r.token(), &template, anims.as_ref());
                self.write_text(target, &template, anims.as_ref())
            }
            LookTarget::Captions => {
                let mut kit = self.project().style_kit.clone();
                let mut token = r.token();
                if r.scope == LookScope::BuiltIn {
                    let mut copy = look.clone();
                    copy.id = format!("{BUILT_IN_LOOK_PREFIX}{}", look.id);
                    let mut k = kit.unwrap_or_default();
                    if k.set_look(&copy).is_err() {
                        return false;
                    }
                    token = StyleKit::look_id(&copy.id);
                    kit = Some(k);
                }
                self.give_caption_tracks(&look, &token, &r.token(), kit, caption_track)
            }
        }
    }

    /// Writes the Look's style, animation and karaoke onto one caption track (`track`) or all of them (`None`); the
    /// captions of those tracks follow the track again. One undo step. `kit` is the project kit `style_token` lives in.
    // Swift: EditorSession+Looks.swift:110
    pub(crate) fn give_caption_tracks(
        &mut self,
        look: &Look,
        style_token: &str,
        remembered_token: &str,
        kit: Option<StyleKit>,
        track: Option<Id>,
    ) -> bool {
        let (Some(t), Some(tl)) = (self.active_timeline(), self.active_timeline_id) else { return false };
        let style_ref = CaptionLook::style_id(style_token);
        let animation_ref = look.animation.as_ref().map(|_| CaptionLook::animation_id(style_token));
        let tracks: Vec<Id> = t.caption_tracks.iter().map(|c| c.id).filter(|c| track.is_none_or(|k| k == *c)).collect();
        if tracks.is_empty() {
            return false;
        }
        let all: std::collections::BTreeSet<Id> = t
            .caption_tracks
            .iter()
            .filter(|c| tracks.contains(&c.id))
            .flat_map(|c| c.items().iter().map(|i| i.id))
            .collect();
        let karaoke = look.karaoke.clone();
        let result = self.try_perform("Apply Look", None, |p| {
            if kit != p.style_kit {
                p.style_kit = kit;
            }
            p.edit(tl, |t| {
                for id in &tracks {
                    t.set_caption_style(&style_ref, animation_ref.as_deref(), *id, false)?;
                    sq_core_audio::caption_handover::TimelineCaptionsExt::set_caption_look(
                        t,
                        Some(remembered_token.to_string()),
                        *id,
                    )?;
                    if let Some(k) = &karaoke {
                        t.set_track_karaoke(Some(k.clone()), *id)?;
                    }
                }
                t.set_caption_item_style(&all, None)
            })?;
            CaptionStyleEdit::prune_own_looks(p);
            CaptionStyleEdit::prune_kit_looks(p, BUILT_IN_LOOK_PREFIX);
            Ok(())
        });
        match result {
            Ok(()) => true,
            Err(e) => {
                self.set_error(Self::message_for(&e));
                false
            }
        }
    }

    /// Overwrites the Look with the target's current style ("Update Look"); the target then counts as carrying it.
    /// The animation is taken too when the Look has one or the target is the captions. Built-in Looks cannot change.
    // Swift: EditorSession+Looks.swift:139
    pub fn update_look(&mut self, r: &LookRef, store: &LookStore) -> Result<bool, StoreError> {
        let Some(target) = self.look_target() else { return Ok(false) };
        let Some(mut look) = self.look(r, store) else { return Ok(false) };
        let Some(cur) = self.current_look_values(store, Some(&look)) else { return Ok(false) };
        let depth = self.history.undo_depth();
        let takes_animation = look.animation.is_some() || target == LookTarget::Captions;
        look.style = cur.style.clone();
        if takes_animation {
            look.animation = cur.animation.clone();
        }
        match r.scope {
            LookScope::BuiltIn => return Ok(false),
            LookScope::User => {
                let (style, animation) = (look.style.clone(), look.animation.clone());
                let changed = store.edit(|lib| {
                    lib.update(&r.id, |l| {
                        l.style = style;
                        l.animation = animation;
                    })
                })?;
                if !changed {
                    return Ok(false);
                }
            }
            LookScope::Project => {
                let mut kit = self.project().style_kit.clone().unwrap_or_default();
                if kit.set_look(&look).is_err() {
                    return Ok(false);
                }
                self.set_style_kit(Some(kit), "Update Look");
            }
        }
        if cur.applied.as_ref() != Some(r) || !cur.carried {
            self.apply_look(r, store, None);
        }
        if self.history.undo_depth() > depth + 1 {
            self.fold_undo(depth, "Update Look");
        }
        Ok(true)
    }

    /// Saves the target's current style as a new Look and gives it to the target: one undo step. `None` for an empty name.
    // Swift: EditorSession+Looks.swift:163
    pub fn save_look_as_new(
        &mut self,
        name: &str,
        scope: LookScope,
        store: &LookStore,
    ) -> Result<Option<LookRef>, StoreError> {
        let (Some(target), Some(cur)) = (self.look_target(), self.current_look_values(store, None)) else {
            return Ok(None);
        };
        let n = name.trim();
        if n.is_empty() {
            return Ok(None);
        }
        // A text clip that does not animate saves a Look without an animation (it then fits any animation).
        let animation = if target == LookTarget::Captions || cur.animation != Some(KeyframeTemplate::none()) {
            cur.animation.clone()
        } else {
            None
        };
        let depth = self.history.undo_depth();
        let values = LookValues {
            style: cur.style.clone(),
            animation,
            karaoke: cur.karaoke.clone(),
            caption_segmentation: None,
        };
        let r = match scope {
            LookScope::BuiltIn => return Ok(None),
            LookScope::User => {
                let id = self.with_ids(|_, ids| store.edit(|lib| lib.add(n, values, None, ids)))?;
                let Some(id) = id else { return Ok(None) };
                LookRef::new(LookScope::User, &id)
            }
            LookScope::Project => {
                let mut kit = self.project().style_kit.clone().unwrap_or_default();
                let id = self.ids.next_id().to_string();
                let look = Look {
                    id: id.clone(),
                    name: n.to_string(),
                    style: values.style,
                    animation: values.animation,
                    karaoke: values.karaoke,
                    caption_segmentation: None,
                    is_built_in: false,
                    category: None,
                };
                if kit.set_look(&look).is_err() {
                    return Ok(None);
                }
                self.set_style_kit(Some(kit), "Save Look");
                LookRef::new(LookScope::Project, &id)
            }
        };
        self.apply_look(&r, store, None);
        if self.history.undo_depth() > depth + 1 {
            self.fold_undo(depth, "Save Look");
        }
        Ok(Some(r))
    }
    // Swift: EditorSession+Looks.swift:188
    pub fn rename_look(&mut self, r: &LookRef, name: &str, store: &LookStore) -> Result<bool, StoreError> {
        match r.scope {
            LookScope::BuiltIn => Ok(false),
            LookScope::User => store.edit(|lib| lib.rename(&r.id, name)),
            LookScope::Project => {
                let n = name.trim();
                let Some(mut kit) = self.project().style_kit.clone().filter(|k| k.looks.contains_key(&r.id)) else {
                    return Ok(false);
                };
                if n.is_empty() {
                    return Ok(false);
                }
                if let Some(l) = kit.looks.get_mut(&r.id) {
                    l.name = n.to_string();
                }
                self.perform("Rename Look", None, |p| p.style_kit = Some(kit));
                Ok(true)
            }
        }
    }
    // Swift: EditorSession+Looks.swift:205
    pub fn delete_look(&mut self, r: &LookRef, store: &LookStore) -> Result<bool, StoreError> {
        match r.scope {
            LookScope::BuiltIn => Ok(false),
            LookScope::User => store.edit(|lib| lib.delete(&r.id)),
            LookScope::Project => {
                let Some(mut kit) = self.project().style_kit.clone().filter(|k| k.looks.contains_key(&r.id)) else {
                    return Ok(false);
                };
                if CaptionStyleEdit::is_kit_look_used(&r.id, &CaptionStyleEdit::caption_refs(self.project())) {
                    return Ok(false);
                }
                kit.looks.remove(&r.id);
                self.set_style_kit(Some(kit), "Delete Look");
                Ok(true)
            }
        }
    }
    /// Shows the Look on the selection in the Program monitor without applying it (hover over a Look tile).
    // Swift: EditorSession+LookPreview.swift:10
    pub fn preview_look(&mut self, r: Option<&LookRef>, store: &LookStore) -> bool {
        let preview = r.filter(|_| !self.is_playing()).and_then(|r| self.look_preview_of(r, store));
        let showing = preview.is_some();
        self.engine.set_look_preview(preview);
        showing
    }

    fn look_preview_of(&self, r: &LookRef, store: &LookStore) -> Option<LookPreview> {
        let target = self.look_target()?;
        let look = self.look(r, store)?;
        match target {
            LookTarget::TextClip(_) | LookTarget::GraphicText(..) => {
                let (template, anims) = self.text_content(target)?;
                let (container, layer, from) = self.stored_text_ref(target)?;
                let given = Self::giving_look(&look, &r.token(), &template, anims.as_ref());
                let to = TextGenerator::make_ref(&given.0, given.1.as_ref()).ok()?;
                Some(LookPreview::Text { container, layer, from, to })
            }
            // What the click applies: the Look's style, its animation (also `none`, which removes the captions' own) and its highlight.
            LookTarget::Captions => Some(LookPreview::Captions {
                style: Box::new(look.style.clone()),
                animation: look.animation.clone().map(Box::new),
                karaoke: look.karaoke.clone().map(Box::new),
            }),
        }
    }

    /// The generator ref the target's text is stored with, and the clip that holds it (the text clip, or the graphic clip).
    // Swift: EditorSession+Looks.swift:248
    pub(crate) fn stored_text_ref(&self, target: LookTarget) -> Option<(Id, Id, GeneratorRef)> {
        let t = self.active_timeline()?;
        let find = |id: Id| -> Option<&Clip> { t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id) };
        match target {
            LookTarget::TextClip(id) => {
                let clip = find(id)?;
                let r = self.displayed_clip(clip).generator.or_else(|| clip.generator.clone())?;
                Some((id, id, r))
            }
            LookTarget::GraphicText(clip, layer) => {
                let GraphicsContent::Text { generator } = &find(clip)?.graphics()?.layer(layer)?.content else {
                    return None;
                };
                Some((clip, layer, generator.clone()))
            }
            LookTarget::Captions => None,
        }
    }

    /// Removes any Look preview from the monitor.
    // Swift: EditorSession+LookPreview.swift:40
    pub fn clear_look_preview(&mut self) {
        self.engine.set_look_preview(None);
    }

    /// What a text gets from a Look (shared by applying it and by a preview, so both draw the same).
    // Swift: EditorSession+Looks.swift:238
    pub(crate) fn giving_look(
        look: &Look,
        token: &str,
        template: &TextTemplate,
        animations: Option<&AnimationSet>,
    ) -> (TextTemplate, Option<AnimationSet>) {
        let mut t = template.clone();
        t.style = look.style.clone();
        t.look_id = Some(token.to_string());
        let mut anims = animations.cloned();
        if let Some(a) = look.animation.clone().filter(|a| *a != KeyframeTemplate::none()) {
            let current = animations;
            anims = Some(if a.anchor == AnimationAnchor::End {
                AnimationSet::new(current.and_then(|c| c.animation_in.clone()), Some(a))
            } else {
                AnimationSet::new(Some(a), current.and_then(|c| c.animation_out.clone()))
            });
        }
        (t, anims)
    }

    /// Stores the template on the target as one undo step.
    // Swift: EditorSession+Looks.swift:216
    pub(crate) fn write_text(
        &mut self,
        target: LookTarget,
        template: &TextTemplate,
        animations: Option<&AnimationSet>,
    ) -> bool {
        match target {
            LookTarget::TextClip(id) => {
                self.update_text_clip(id, template, animations, false);
                true
            }
            LookTarget::GraphicText(clip, layer) => {
                let Ok(generator) = TextGenerator::make_ref(template, animations) else { return false };
                self.edit_graphics(clip, "Apply Look", None, |d| {
                    if let Some(l) = d.layers.iter_mut().find(|l| l.id == layer) {
                        l.content = GraphicsContent::Text { generator };
                    }
                })
            }
            LookTarget::Captions => false,
        }
    }

    /// The template and animations the target's text is stored with.
    // Swift: EditorSession+Looks.swift:262
    pub(crate) fn text_content(&self, target: LookTarget) -> Option<(TextTemplate, Option<AnimationSet>)> {
        let t = self.active_timeline()?;
        let find = |id: Id| -> Option<&Clip> { t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id) };
        match target {
            LookTarget::TextClip(id) => {
                let clip = find(id)?;
                let r = self.displayed_clip(clip).generator.or_else(|| clip.generator.clone())?;
                TextGenerator::decode(&r).ok()
            }
            LookTarget::GraphicText(clip, layer) => {
                let GraphicsContent::Text { generator } = &find(clip)?.graphics()?.layer(layer)?.content else {
                    return None;
                };
                TextGenerator::decode(generator).ok()
            }
            LookTarget::Captions => None,
        }
    }

    /// The style, animation and karaoke the target shows, and the Look it carries. `slot_of`: the Look whose animation
    /// slot is read on a text clip (default: the applied Look); a Look animated from the end sits in the out-animation.
    // Swift: EditorSession+Looks.swift:286
    fn current_look_values(&self, store: &LookStore, slot_of: Option<&Look>) -> Option<CurrentLookValues> {
        let target = self.look_target()?;
        match target {
            LookTarget::TextClip(_) | LookTarget::GraphicText(..) => {
                let (t, anims) = self.text_content(target)?;
                let applied = t.look_id.as_deref().and_then(|tok| self.look_ref(tok, store));
                let slot = slot_of.cloned().or_else(|| applied.as_ref().and_then(|a| self.look(a, store)));
                let animation = match slot.and_then(|l| l.animation).filter(|a| *a != KeyframeTemplate::none()) {
                    Some(a) if a.anchor == AnimationAnchor::End => anims.as_ref().and_then(|s| s.animation_out.clone()),
                    Some(_) => anims.as_ref().and_then(|s| s.animation_in.clone()).or(t.animation.clone()),
                    None => anims
                        .as_ref()
                        .and_then(|s| s.animation_in.clone().or_else(|| s.animation_out.clone()))
                        .or(t.animation.clone()),
                };
                Some(CurrentLookValues { style: t.style, animation, karaoke: None, applied, carried: true })
            }
            LookTarget::Captions => {
                let track = self.active_timeline()?.caption_tracks.first()?;
                let first = track.items().first();
                let style_ref = if track.style_ref.is_empty() {
                    first.map(|i| i.style_ref.clone()).unwrap_or_default()
                } else {
                    track.style_ref.clone()
                };
                let anim_ref = if track.animation_ref.is_empty() {
                    first.map(|i| i.animation_ref.clone()).unwrap_or_default()
                } else {
                    track.animation_ref.clone()
                };
                let lib = store.registry().library_for_project(self.project());
                let prefix = CaptionLook::style_id("");
                let direct = style_ref.strip_prefix(&prefix).and_then(|tok| self.look_ref(tok, store));
                let remembered = if direct.is_none() {
                    track.look_id.as_deref().and_then(|t| self.look_ref(t, store))
                } else {
                    None
                };
                Some(CurrentLookValues {
                    style: lib.style((!style_ref.is_empty()).then_some(style_ref.as_str())),
                    animation: Some(lib.animation((!anim_ref.is_empty()).then_some(anim_ref.as_str()))),
                    karaoke: track.karaoke.clone(),
                    carried: direct.is_some(),
                    applied: direct.or(remembered),
                })
            }
        }
    }

    /// The Look a stored token names; an id that was merged into another Look resolves to that one.
    // Swift: EditorSession+Looks.swift:318
    fn look_ref(&self, token: &str, store: &LookStore) -> Option<LookRef> {
        let kit_prefix = StyleKit::look_id("");
        if let Some(id) = token.strip_prefix(&kit_prefix) {
            if let Some(built_in) = id.strip_prefix(BUILT_IN_LOOK_PREFIX) {
                return LookLibrary::built_ins()
                    .iter()
                    .any(|l| l.id == built_in)
                    .then(|| LookRef::new(LookScope::BuiltIn, built_in));
            }
            return (self.project().style_kit.as_ref().is_some_and(|k| k.look(id).is_some())
                && !is_hidden_kit_look(id))
            .then(|| LookRef::new(LookScope::Project, id));
        }
        store
            .library()
            .look(token)
            .map(|l| LookRef::new(if l.is_built_in { LookScope::BuiltIn } else { LookScope::User }, &l.id))
    }

    /// Writes the Look a text was last given (`scope:id`) to `defaults` (Swift `rememberTextLook`); the app calls it
    /// after a successful `apply_look` on a text.
    // Swift: EditorSession+Title.swift:54
    pub fn remember_text_look(defaults: &mut dyn sq_library::library_folder_store::SettingsStore, r: &LookRef) {
        defaults.set_data(Self::LAST_TEXT_LOOK_KEY, format!("{}:{}", r.scope.raw_value(), r.id).into_bytes());
    }
}

/// What the Looks panel compares: the style, animation and karaoke of the target and the Look it carries.
struct CurrentLookValues {
    style: TextStyle,
    animation: Option<KeyframeTemplate>,
    karaoke: Option<KaraokeStyle>,
    applied: Option<LookRef>,
    /// The target still points at the applied Look itself. False for captions whose style was edited after the Look was
    /// applied: they draw a style of their own and only remember the Look (`CaptionTrack.look_id`).
    carried: bool,
}
