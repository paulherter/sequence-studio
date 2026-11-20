// Swift: Draw/ClipSectionsDraw.swift, ClipSectionLogic.swift
//! The clip's content section of Controls: which section a clip gets (`ClipSectionMode::resolve`), and the hosted bodies
//! that exist in Rust today: Audio (`TrackAudioDraw` per track), Shape (kind buttons), Color Matte (swatch and hex) and the
//! Graphic row (layer summary and "Edit in Graphics"). Coordinates: points, y down, (0, 0) = the section's top-left.
//!
//! The Swift class held the `EditorSession`; here the draw never touches it. `sync` takes the clip and the tracks, and every
//! edit the user makes is queued as a [`SectionAction`] the host runs against the session (one undo step per gesture, as
//! the action says). Menus and the color picker are requests the host answers (`run_menu_commands`, `matte_picked`).
//! Template hosts `TemplateSlotsDraw` (its edits are [`SectionAction::Template`]). The Text block and the Graphic item rows
//! need the host's text model and Graphics editor, so the host owns and draws them: it tells the section their height
//! (`set_text_height`, `set_item_rows_height`) and places them with `items_top`. The Graphic layer picker is a popup row
//! ([`SectionAction::LayerMenu`], answered with `layer_picked`). Not hosted: the caption list (Controls never lists captions, so `Captions` is unused here).

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use sq_core_color::{ColorMatteClipExt, ColorMatteColor};
use sq_core_graphics::graphics_layer_projection::GraphicsItemPickerExt;
use sq_core_model::StyleKit;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::{AudioTag, Clip, EffectColor, GeneratorRef, ShapeKind, TrackKind};
use sq_core_time::Id;
use sq_core_time::Vec2;
use sq_draw::inspector::inspector_controls::Direction;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputKey, InputModifiers, InspectorDraw, TextAlign, UiCx};
use sq_text::text_align_to_frame::FrameAlignment;
use sq_text::text_generator::TextGenerator;
use sq_text::text_template::TextTemplate;
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;

use crate::audio_masks::draw_support::MenuRequest;
use crate::audio_masks::track_audio_draw::TrackAudioDraw;
use crate::audio_masks::track_audio_inspector_model::TrackAudioEvent;
use crate::graphics::template_slots_draw::{TemplateEvent, TemplateSlotsDraw};
use crate::text::animator_choices::TextAnimatorChoices;
use crate::text::block_draw::{BlockRequest, LookSource, LookStatus, Part, TextBlockDraw};
use crate::text::inspector_model::{TextInspectorEvent, TextInspectorModel};

/// Which content section Controls shows for the selection. Text, Shape, Color Matte, Template and Graphic lead the column
/// (before Transform); Audio closes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipSectionMode {
    None,
    Text,
    Audio,
    Shape,
    Matte,
    Template,
    Graphic,
    Captions,
}

impl ClipSectionMode {
    /// Whether the section leads the column (content before Transform) or closes it.
    pub fn leads(self) -> bool {
        matches!(self, Self::Text | Self::Shape | Self::Matte | Self::Template | Self::Graphic)
    }

    /// The kind the Controls header names ("Text · 00:00:05:14"); `None` = the clip's track kind.
    pub fn kind_name(self) -> Option<&'static str> {
        self.leads().then(|| self.title())
    }

    pub fn resolve(clip: Option<&Clip>) -> ClipSectionMode {
        let Some(c) = clip else { return Self::None };
        if c.template_slots.is_some() && c.sequence.is_some() {
            return Self::Template;
        }
        let kind = c.generator.as_ref().map(|g| g.kind.as_str());
        if kind == Some(TextGenerator::KIND) {
            Self::Text
        } else if kind == Some(GeneratorRef::SHAPE) {
            Self::Shape
        } else if c.is_color_matte() {
            Self::Matte
        } else if c.is_graphics() {
            Self::Graphic
        } else if c.kind == TrackKind::Audio {
            Self::Audio
        } else {
            Self::None
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::None => "",
            Self::Text => "Text",
            Self::Audio => "Audio",
            Self::Shape => "Shape",
            Self::Matte => "Color Matte",
            Self::Template => "Template",
            Self::Graphic => "Graphic",
            Self::Captions => "All Captions",
        }
    }

    /// "3 layers" for the Graphic section and the Graphics panel header.
    pub fn layer_summary(clip: &Clip) -> String {
        match clip.graphics().map_or(0, |g| g.layers.len()) {
            1 => "1 layer".to_string(),
            n => format!("{n} layers"),
        }
    }
}

/// What the host must do for the section.
#[derive(Clone, Debug, PartialEq)]
pub enum SectionAction {
    /// `session.set_shape_kind`.
    SetShapeKind { clip: Id, kind: ShapeKind },
    /// `session.set_color_matte`; `continues` joins the open picker gesture's undo step.
    SetColorMatte { clip: Id, color: ColorMatteColor, continues: bool },
    /// The swatch was clicked: open the color picker at `anchor`, report to [`ClipSectionsDraw::matte_picked`].
    PickMatteColor { current: EffectColor, anchor: CGRect },
    /// "Edit in Graphics": bring the Graphics panel to the front.
    EditGraphics,
    /// The Layer popup was clicked: show a menu at `anchor` with "Whole graphic" first, then one row per entry (`checked`
    /// marks the shown item), and answer a choice with [`ClipSectionsDraw::layer_picked`].
    LayerMenu { entries: Vec<(Id, String)>, picked: Option<Id>, anchor: CGRect },
    /// Controls shows another item of the graphic (`None` = the whole graphic): the host sets the session's
    /// `GraphicLayerSelection` to that one layer (or clears it) and refreshes the item rows.
    GraphicItem { clip: Id, layer: Option<Id> },
    /// A track's audio preset changed (`None` = cleared); the host forwards it to the engine.
    /// The track's audio tweaks changed (`None`: back to the role's preset); `continues` = the same drag as the call before.
    AudioPreset { track: Id, preset: Option<Box<sq_audiofx::presets::TrackAudioPreset>>, continues: bool },
    /// The role popup changed a track's role: `session.set_track_audio_role` (the session keeps a chain the user edited or picked).
    AudioRole { track: Id, role: Option<AudioTag> },
    /// The Loudness dropdown changed a track's target: `session.set_track_loudness_target` (`None`: the role's default).
    AudioLoudness { track: Id, lufs: Option<f64> },
    /// A template slot, the zones switch or the Middle choice changed on the template clip.
    Template { clip: Id, event: TemplateEvent },
    /// A color slot was clicked: open the color picker at `anchor`, report to [`ClipSectionsDraw::template_color_picked`].
    PickTemplateColor { current: EffectColor, anchor: CGRect },
    /// The text clip's template or animations changed (`updateTextClip`, or `updateTextClips` when several text clips are
    /// selected, which also needs `from`, `old_animations` and `forcing`). `continues` joins the open gesture's undo step.
    UpdateText {
        clip: Id,
        from: Box<TextTemplate>,
        to: Box<TextTemplate>,
        animations: Box<AnimationSet>,
        old_animations: Option<Box<AnimationSet>>,
        forcing: BTreeSet<String>,
        continues: bool,
    },
    /// `onAlignToFrame`: the host moves the clip so its text block meets the frame.
    AlignToFrame(FrameAlignment),
    /// The user's text styles changed: the host persists them.
    StylesChanged(Box<crate::text::style_library::TextStyleLibrary>),
    /// The Look popup or its menu did something to the shown text (`ClipSectionsDraw.wireLooks`).
    Look(LookAction),
    /// The section's height changed: the panel lays out again.
    HeightChanged,
}

/// What the Look popup of the Controls text block asks the host to do (`session.applyLook` and friends); Update,
/// Rename and Delete act on the Look the text carries.
#[derive(Clone, Debug, PartialEq)]
pub enum LookAction {
    /// Give the text the Look with this token.
    Apply(String),
    Update,
    SaveAsNew(String),
    Rename(String),
    Delete,
}

/// The Looks the Controls text block lists, as the host last read them (`ClipSectionsDraw.lookEntries`, `carriedLook`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ControlLooks {
    /// (token, name) of every Look, in list order.
    pub entries: Vec<(String, String)>,
    /// The token of the Look the text carries.
    pub selected: Option<String>,
    /// That Look's name, whether the text differs from it, and whether it can be updated (not built in).
    pub carried: Option<LookStatus>,
}

/// A click in the Look popup or its menu that waits for [`ClipSectionsDraw::pump_text`].
#[derive(Clone)]
enum LookClick {
    Do(LookAction),
    /// "+" or "Save as New Look...": asks for a name first.
    AskSave,
    /// "Rename...": asks for a name first.
    AskRename,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Hit {
    Header,
    Kind(usize),
    Well,
    Audio,
    Template,
    LayerPicker,
    EditGraphics,
    None,
}

const KIND_BUTTON: f64 = 32.0;
const EDIT_BUTTON_WIDTH: f64 = 120.0;
const PICKER_WIDTH: f64 = 160.0;
const SHAPES: [ShapeKind; 4] = [ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line, ShapeKind::Arrow];

pub struct ClipSectionsDraw {
    pub theme: DrawTheme,
    width: f64,
    mode: ClipSectionMode,
    collapsed: BTreeSet<&'static str>,
    audio: HashMap<Id, TrackAudioDraw>,
    audio_track: Option<Id>,
    shape_clip: Option<Id>,
    shape_kind: ShapeKind,
    matte_clip: Option<Id>,
    matte_color: ColorMatteColor,
    matte_gesture_open: bool,
    graphic_clip: Option<Id>,
    layer_summary: String,
    /// The items of the shown graphic, front-most first (`GraphicsItemPickerExt::item_picker_entries`).
    graphic_picker: Vec<(Id, String)>,
    /// The item Controls shows (`None` = the whole graphic).
    picked_item: Option<Id>,
    template: TemplateSlotsDraw,
    template_clip: Option<Id>,
    text_height: f64,
    text_clip: Option<Id>,
    text_template: Option<TextTemplate>,
    text_animations: Option<AnimationSet>,
    text_gesture_open: bool,
    item_rows_height: f64,
    /// "Edit in Graphics" is dimmed without a Graphics panel to go to.
    pub can_edit_graphics: bool,
    hover: Hit,
    pressed: Hit,
    actions: Vec<SectionAction>,
    /// Open change brackets of the audio block and whether one of them already reported a change (a drag is one undo step).
    audio_gesture_depth: u32,
    audio_changed_in_gesture: bool,
    /// The Look list the block's popup shows and what its clicks queued (see [`ClipSectionsDraw::wire_looks`]).
    looks: Rc<RefCell<ControlLooks>>,
    look_clicks: Rc<RefCell<Vec<LookClick>>>,
}

impl Default for ClipSectionsDraw {
    fn default() -> ClipSectionsDraw {
        ClipSectionsDraw::new()
    }
}

impl ClipSectionsDraw {
    const NOTE: &'static str = "These settings belong to the whole track, so every clip on it follows. They are saved with the project and apply in playback and export.";

    pub fn new() -> ClipSectionsDraw {
        ClipSectionsDraw {
            theme: DrawTheme::default(),
            width: 320.0,
            mode: ClipSectionMode::None,
            collapsed: BTreeSet::new(),
            audio: HashMap::new(),
            audio_track: None,
            shape_clip: None,
            shape_kind: ShapeKind::Rectangle,
            matte_clip: None,
            matte_color: ColorMatteColor { r: 0, g: 0, b: 0 },
            matte_gesture_open: false,
            graphic_clip: None,
            layer_summary: String::new(),
            graphic_picker: Vec::new(),
            picked_item: None,
            template: TemplateSlotsDraw::new(),
            template_clip: None,
            text_height: 0.0,
            text_clip: None,
            text_template: None,
            text_animations: None,
            text_gesture_open: false,
            item_rows_height: 0.0,
            can_edit_graphics: false,
            hover: Hit::None,
            pressed: Hit::None,
            actions: Vec::new(),
            audio_gesture_depth: 0,
            audio_changed_in_gesture: false,
            looks: Rc::default(),
            look_clicks: Rc::default(),
        }
    }

    /// Makes the block's Look row the session's Looks: the popup lists [`ControlLooks`], and its clicks and the
    /// right-click menu become [`SectionAction::Look`] on the next `pump_text` (names are asked through `block.ask_name`).
    pub fn wire_looks(&self, block: &mut TextBlockDraw) {
        let push = |clicks: &Rc<RefCell<Vec<LookClick>>>, c: LookClick| clicks.borrow_mut().push(c);
        let (looks, clicks) = (Rc::clone(&self.looks), Rc::clone(&self.look_clicks));
        block.look_source = Some(Box::new({
            let (looks, clicks) = (Rc::clone(&looks), Rc::clone(&clicks));
            move || {
                let l = looks.borrow();
                let (pick, add) = (Rc::clone(&clicks), Rc::clone(&clicks));
                LookSource {
                    titles: l.entries.iter().map(|(_, name)| name.clone()).collect(),
                    ids: l.entries.iter().map(|(id, _)| id.clone()).collect(),
                    selected: l.selected.clone(),
                    pick: Box::new(move |id| push(&pick, LookClick::Do(LookAction::Apply(id.to_string())))),
                    add: Some(Box::new(move || push(&add, LookClick::AskSave))),
                }
            }
        }));
        block.look_status = Some(Box::new({
            let looks = Rc::clone(&looks);
            move || looks.borrow().carried.clone()
        }));
        block.on_update_look = Some(Box::new({
            let clicks = Rc::clone(&clicks);
            move || push(&clicks, LookClick::Do(LookAction::Update))
        }));
        block.on_save_look_as_new = Some(Box::new({
            let clicks = Rc::clone(&clicks);
            move || push(&clicks, LookClick::AskSave)
        }));
        block.look_context = Some(Box::new(move || {
            let item = |c: LookClick| -> Rc<dyn Fn()> {
                let clicks = Rc::clone(&clicks);
                Rc::new(move || push(&clicks, c.clone()))
            };
            let editable = looks.borrow().carried.as_ref().filter(|s| s.can_update).map(|s| s.name.clone());
            TextAnimatorChoices::look_menu_items(
                editable.as_deref(),
                item(LookClick::Do(LookAction::Update)),
                item(LookClick::AskSave),
                item(LookClick::AskRename),
                item(LookClick::Do(LookAction::Delete)),
            )
        }));
    }

    /// The Looks to list and the one the shown text carries (the host reads them from the session after every change).
    pub fn set_looks(&mut self, looks: ControlLooks) {
        *self.looks.borrow_mut() = looks;
    }

    /// Turns what the Look popup queued into actions; a click that needs a name asks `block.ask_name` first, and the
    /// answer arrives as a later click (a canceled or empty name does nothing; without a prompt the suggestion is used).
    fn pump_looks(&mut self, block: &mut TextBlockDraw) {
        loop {
            let clicks: Vec<LookClick> = self.look_clicks.borrow_mut().drain(..).collect();
            if clicks.is_empty() {
                break;
            }
            for click in clicks {
                let carried = self.looks.borrow().carried.as_ref().map(|s| s.name.clone());
                match click {
                    LookClick::Do(a) => self.actions.push(SectionAction::Look(a)),
                    LookClick::AskSave => {
                        let initial = carried.map_or_else(|| "My Look".to_string(), |n| format!("{n} 2"));
                        self.ask_look_name(block, "Save as New Look", &initial, LookAction::SaveAsNew);
                    }
                    LookClick::AskRename => {
                        if let Some(n) = carried {
                            self.ask_look_name(block, "Rename Look", &n, LookAction::Rename);
                        }
                    }
                }
            }
        }
    }

    fn ask_look_name(&self, block: &mut TextBlockDraw, title: &str, initial: &str, make: fn(String) -> LookAction) {
        let clicks = Rc::clone(&self.look_clicks);
        let Some(ask) = block.ask_name.as_mut() else {
            clicks.borrow_mut().push(LookClick::Do(make(initial.to_string())));
            return;
        };
        ask(
            title,
            initial,
            Box::new(move |typed| {
                if let Some(n) = typed.map(|t| t.trim().to_string()).filter(|n| !n.is_empty()) {
                    clicks.borrow_mut().push(LookClick::Do(make(n)));
                }
            }),
        );
    }

    pub fn mode(&self) -> ClipSectionMode {
        self.mode
    }

    pub fn width(&self) -> f64 {
        self.width
    }

    pub fn set_width(&mut self, w: f64) {
        self.width = w;
        for a in self.audio.values_mut() {
            a.width = w;
        }
        self.template.width = w;
    }

    /// The installed font families for a font slot's popup.
    pub fn set_font_families(&mut self, families: Vec<String>) {
        self.template.font_families = families;
    }

    /// The height of the Text block the host draws (`TextBlockDraw` part Text); the section has no header in Text mode.
    pub fn set_text_height(&mut self, h: f64) {
        if self.text_height != h {
            self.text_height = h;
            if self.mode == ClipSectionMode::Text {
                self.actions.push(SectionAction::HeightChanged);
            }
        }
    }

    /// Loads the text clip into the host's model and block (Swift `loadText`). Call after `sync` while the mode is Text.
    /// `kit` and `frame_size` are the project's Style Kit and the sequence picture size; `mixed` the template paths that
    /// differ between several selected text clips (empty for one). Reports the block's height through `set_text_height`.
    pub fn load_text(
        &mut self,
        clip: &Clip,
        model: &mut TextInspectorModel,
        block: &mut TextBlockDraw,
        kit: Option<StyleKit>,
        frame_size: Vec2,
        mixed: BTreeSet<String>,
    ) {
        let decoded = clip.generator.as_ref().and_then(|g| TextGenerator::decode(g).ok());
        let Some((t, anims)) = decoded else {
            // Undecodable: never edit the previous clip.
            self.text_clip = None;
            self.text_template = None;
            self.text_animations = None;
            model.target = None;
            block.set_text("");
            self.set_text_height(block.height(model, Part::Text));
            return;
        };
        let changed_clip = self.text_clip != Some(clip.id);
        self.text_clip = Some(clip.id);
        model.target = Some(clip.id);
        model.kit = kit;
        model.frame_size = frame_size;
        model.clip_duration = Some(clip.duration());
        let set = anims.clone().unwrap_or_else(|| AnimationSet::new(None, None));
        if changed_clip || self.text_template.as_ref() != Some(&t) {
            self.text_template = Some(t.clone());
            model.load(t.style.clone(), set);
        } else {
            // Only the animations moved: an open edit session stays open.
            model.adopt(set);
        }
        self.text_animations = anims;
        if model.mixed_paths != mixed {
            model.mixed_paths = mixed;
        }
        let shown = if model.mixed_paths.contains("text") { "" } else { t.text.as_str() };
        if block.text != shown {
            block.set_text(shown);
        }
        self.set_text_height(block.height(model, Part::Text));
    }

    /// Forwards what the text model and block did since the last call (Swift `wireText`, `textTyped`, `sendText`): style
    /// and animation edits and typing become [`SectionAction::UpdateText`]. Takes the block's text requests out of
    /// `requests` (the rest, menus and pickers, stay for the host) and keeps the block's height up to date.
    pub fn pump_text(
        &mut self,
        model: &mut TextInspectorModel,
        block: &mut TextBlockDraw,
        requests: &mut Vec<BlockRequest>,
    ) {
        self.pump_looks(block);
        for e in model.take_events() {
            match e {
                TextInspectorEvent::BeginEditing | TextInspectorEvent::EndEditing => self.text_gesture_open = false,
                TextInspectorEvent::Change(style, anims, forcing) => {
                    let (Some(id), Some(old)) = (self.text_clip, self.text_template.clone()) else { continue };
                    let mut t = old.clone();
                    t.style = *style;
                    self.text_template = Some(t.clone());
                    self.send_text(id, old, t, *anims, forcing);
                }
                TextInspectorEvent::AlignToFrame(a) => self.actions.push(SectionAction::AlignToFrame(a)),
                TextInspectorEvent::StylesChanged(l) => self.actions.push(SectionAction::StylesChanged(l)),
                TextInspectorEvent::PresetsChanged(_) => {}
            }
        }
        let mut rest = Vec::new();
        for r in requests.drain(..) {
            match r {
                BlockRequest::TextBegin | BlockRequest::TextEnd => self.text_gesture_open = false,
                BlockRequest::TextChange(s) => {
                    let (Some(id), Some(old)) = (self.text_clip, self.text_template.clone()) else { continue };
                    if old.text == s && !model.mixed_paths.contains("text") {
                        continue;
                    }
                    let mut t = old.clone();
                    t.text = s;
                    self.text_template = Some(t.clone());
                    self.send_text(id, old, t, model.animations().clone(), BTreeSet::new());
                }
                other => rest.push(other),
            }
        }
        *requests = rest;
        if self.mode == ClipSectionMode::Text {
            self.set_text_height(block.height(model, Part::Text));
        }
    }

    fn send_text(
        &mut self,
        clip: Id,
        from: TextTemplate,
        to: TextTemplate,
        anims: AnimationSet,
        forcing: BTreeSet<String>,
    ) {
        self.actions.push(SectionAction::UpdateText {
            clip,
            from: Box::new(from),
            to: Box::new(to),
            animations: Box::new(anims.clone()),
            old_animations: self.text_animations.take().map(Box::new),
            forcing,
            continues: self.text_gesture_open,
        });
        self.text_animations = Some(anims);
        self.text_gesture_open = true;
    }

    /// The height of the Graphic item rows the host draws (`GraphicItemRowsDraw`) below the layer row.
    pub fn set_item_rows_height(&mut self, h: f64) {
        if self.item_rows_height != h {
            self.item_rows_height = h;
            if self.mode == ClipSectionMode::Graphic {
                self.actions.push(SectionAction::HeightChanged);
            }
        }
    }

    /// Where the host's Graphic item rows start, in section coordinates.
    pub fn items_top(&self) -> f64 {
        self.header_height() + self.graphic_rows() * ControlsGrid::ROW_HEIGHT
    }

    /// The Layer row only exists while the graphic has items.
    fn graphic_rows(&self) -> f64 {
        if self.graphic_picker.is_empty() { 1.0 } else { 2.0 }
    }

    /// Follows the session's shared item selection (its one store): Controls shows the one selected item, else the whole
    /// graphic. The host calls it every frame after `sync`, so a pick on the monitor or in the Graphics panel shows here.
    /// Not stored anywhere else: the Layer menu only reports its choice, the host writes it to the session.
    pub fn set_layer_selection(&mut self, selection: Option<&sq_editor_session::GraphicLayerSelection>) {
        // The picker list is the document's item set, so `shown_item`'s rule is "one selected id that is listed".
        self.picked_item = selection.filter(|s| Some(s.clip) == self.graphic_clip).and_then(|s| {
            let one = s.layers.iter().next().copied().filter(|_| s.layers.len() == 1)?;
            self.graphic_picker.iter().any(|e| e.0 == one).then_some(one)
        });
    }

    /// The item Controls shows (`None` = the whole graphic).
    pub fn picked_item(&self) -> Option<Id> {
        self.picked_item
    }

    /// The Layer menu's choice (`None` = Whole graphic).
    pub fn layer_picked(&mut self, layer: Option<Id>) {
        let Some(clip) = self.graphic_clip else { return };
        self.actions.push(SectionAction::GraphicItem { clip, layer });
    }

    pub fn shape_kind(&self) -> ShapeKind {
        self.shape_kind
    }

    pub fn matte_color(&self) -> ColorMatteColor {
        self.matte_color
    }

    /// Switches the shown audio block between its Track and Effects tabs (the shot poses; the user clicks the switch).
    pub fn set_audio_tab(&mut self, tab: crate::audio_masks::audio_effects_tab::Tab) {
        if let Some(a) = self.audio_block_mut() {
            a.set_tab(tab);
        }
    }

    /// The track whose audio block is shown.
    pub fn audio_track_id(&self) -> Option<Id> {
        self.audio_track
    }

    /// Feeds the shown audio block's gain-reduction meter and returns the band it shows (None = no block).
    pub fn set_audio_gain_reduction(&mut self, f: impl FnOnce(usize) -> f64) -> Option<usize> {
        let a = self.audio_block_mut()?;
        let band = a.selected_band();
        a.set_gain_reduction_db(f(band));
        Some(band)
    }

    /// Learn Noise: when the shown block was asked to listen, runs `capture` (mono samples, rate) and gives them to it;
    /// the request is cleared even when there is nothing to hear.
    pub fn serve_learn_noise(&mut self, capture: impl FnOnce() -> Option<(Vec<f32>, f64)>) {
        let Some(a) = self.audio_block_mut() else { return };
        if !a.learn_noise_requested {
            return;
        }
        match capture() {
            Some((samples, rate)) => {
                a.learn_noise(&samples, rate);
            }
            None => a.learn_noise_requested = false,
        }
    }

    /// Feeds the shown audio block's Noise Gate Open / Closed (None = gate off or no reading).
    pub fn set_audio_gate_open(&mut self, open: Option<bool>) {
        if let Some(a) = self.audio_block_mut() {
            a.set_gate_open(open);
        }
    }

    /// The audio block of the shown clip's track.
    pub fn audio_block(&self) -> Option<&TrackAudioDraw> {
        self.audio_track.and_then(|t| self.audio.get(&t))
    }

    pub fn audio_block_mut(&mut self) -> Option<&mut TrackAudioDraw> {
        self.audio_track.and_then(|t| self.audio.get_mut(&t))
    }

    /// What the user did since the last call, in order.
    pub fn take_actions(&mut self) -> Vec<SectionAction> {
        std::mem::take(&mut self.actions)
    }

    /// Menus the audio block asked for (block coordinates moved into the section's), then `run_menu_commands`.
    pub fn take_menus(&mut self) -> Vec<MenuRequest> {
        let dy = self.header_height();
        let shift = |m: MenuRequest| MenuRequest {
            anchor: CGRect::new(m.anchor.min_x(), m.anchor.min_y() + dy, m.anchor.width, m.anchor.height),
            ..m
        };
        let mut out: Vec<MenuRequest> = match self.audio_block_mut() {
            Some(a) => std::mem::take(&mut a.menus).into_iter().map(shift).collect(),
            None => Vec::new(),
        };
        if let Some(m) = self.template.take_menu() {
            out.push(shift(MenuRequest { items: m.items, anchor: m.anchor }));
        }
        out
    }

    /// A menu row was chosen.
    pub fn run_menu_commands(&mut self) {
        if let Some(a) = self.audio_block_mut() {
            a.run_menu_commands();
        }
        self.template.flush();
        self.pump_audio();
        self.pump_template();
    }

    fn header_height(&self) -> f64 {
        if self.mode == ClipSectionMode::Text { 0.0 } else { ControlsGrid::HEADER_HEIGHT }
    }

    fn collapsible(&self) -> bool {
        self.mode != ClipSectionMode::Text
    }

    pub fn is_collapsed(&self) -> bool {
        self.collapsible() && self.collapsed.contains(self.mode.title())
    }

    // MARK: Session to UI

    /// The selection or the project changed. `tracks` lists every track of the active timeline with its audio role;
    /// `new_audio` makes the block for a track the first time its clip is shown.
    pub fn sync(
        &mut self,
        clip: Option<&Clip>,
        tracks: &[(Id, Option<AudioTag>)],
        clip_track: Option<Id>,
        new_audio: &mut dyn FnMut(Id, Option<AudioTag>) -> TrackAudioDraw,
    ) {
        self.audio.retain(|id, _| tracks.iter().any(|t| t.0 == *id));
        if self.audio_track.is_some_and(|id| !self.audio.contains_key(&id) && !tracks.iter().any(|t| t.0 == id)) {
            self.audio_track = None;
        }
        for (id, role) in tracks {
            if let Some(a) = self.audio.get_mut(id)
                && a.model.role() != *role
            {
                a.model.sync_role(*role);
            }
        }
        let new = ClipSectionMode::resolve(clip);
        let mut changed = new != self.mode;
        match (new, clip) {
            (ClipSectionMode::Shape, Some(c)) => {
                self.shape_clip = Some(c.id);
                if let Some(k) = c.generator.as_ref().and_then(GeneratorRef::shape_kind) {
                    self.shape_kind = k;
                }
            }
            (ClipSectionMode::Matte, Some(c)) => {
                self.matte_clip = Some(c.id);
                if let Some(m) = c.matte_color() {
                    self.matte_color = m;
                }
            }
            (ClipSectionMode::Audio, Some(_)) => {
                let before = self.audio_track;
                self.audio_track = clip_track;
                if let Some(t) = clip_track
                    && !self.audio.contains_key(&t)
                {
                    let role = tracks.iter().find(|x| x.0 == t).and_then(|x| x.1);
                    let mut block = new_audio(t, role);
                    block.note = SQL10n::string(Self::NOTE);
                    block.theme = self.theme;
                    block.width = self.width;
                    self.audio.insert(t, block);
                }
                changed = changed || before != self.audio_track;
            }
            (ClipSectionMode::Template, Some(c)) => {
                self.template_clip = Some(c.id);
                self.template.theme = self.theme;
                self.template.width = self.width;
                let slots = c.template_slots.as_deref().unwrap_or(&[]);
                changed = self.template.show(slots, c.zones.clone()) || changed;
            }
            (ClipSectionMode::Graphic, Some(c)) => {
                self.graphic_clip = Some(c.id);
                self.layer_summary = ClipSectionMode::layer_summary(c);
                let before = self.graphic_picker.is_empty();
                self.graphic_picker = c.graphics().map(|g| g.item_picker_entries()).unwrap_or_default();
                changed = changed || before != self.graphic_picker.is_empty();
            }
            _ => {}
        }
        self.mode = new;
        if changed {
            self.actions.push(SectionAction::HeightChanged);
        }
    }

    /// The project's Loudness targets per audio track follow into the blocks (undo, redo, another view): no callbacks.
    pub fn sync_loudness(&mut self, targets: &[(Id, Option<f64>)]) {
        for (id, lufs) in targets {
            if let Some(a) = self.audio.get_mut(id) {
                a.model.sync_loudness_target(*lufs);
            }
        }
    }

    /// The project's stored audio tweaks per audio track follow into the blocks (undo, redo, another view): no callbacks.
    pub fn sync_presets(&mut self, stored: &[(Id, Option<sq_audiofx::presets::TrackAudioPreset>)]) {
        for (id, preset) in stored {
            if let Some(a) = self.audio.get_mut(id) {
                a.model.sync_preset(preset.as_ref());
            }
        }
    }

    /// Forwards what the audio model did: preset changes and role picks (Swift `onChange`, `onRoleChange`).
    fn pump_audio(&mut self) {
        let Some(track) = self.audio_track else { return };
        let Some(a) = self.audio.get_mut(&track) else { return };
        for ev in a.model.take_events() {
            match ev {
                TrackAudioEvent::Change(p) => {
                    let continues = self.audio_changed_in_gesture;
                    self.audio_changed_in_gesture = self.audio_gesture_depth > 0;
                    self.actions.push(SectionAction::AudioPreset { track, preset: Some(p), continues });
                }
                // The session keeps edited tweaks and drops untouched ones with the role, in one undo step.
                TrackAudioEvent::RoleChange(role) => self.actions.push(SectionAction::AudioRole { track, role }),
                TrackAudioEvent::LoudnessChange(lufs) => {
                    self.actions.push(SectionAction::AudioLoudness { track, lufs })
                }
                TrackAudioEvent::BeginChange => self.audio_gesture_depth += 1,
                TrackAudioEvent::EndChange => {
                    self.audio_gesture_depth = self.audio_gesture_depth.saturating_sub(1);
                    if self.audio_gesture_depth == 0 {
                        self.audio_changed_in_gesture = false;
                    }
                }
            }
        }
    }

    /// Forwards what the template block did: slot edits, the zones switch and the picker request.
    fn pump_template(&mut self) {
        let Some(clip) = self.template_clip else { return };
        for event in self.template.take_events() {
            self.actions.push(SectionAction::Template { clip, event });
        }
        if let Some(r) = self.template.take_color_request() {
            let a = r.anchor;
            let anchor = CGRect::new(a.min_x(), a.min_y() + self.header_height(), a.width, a.height);
            self.actions.push(SectionAction::PickTemplateColor { current: r.current, anchor });
        }
    }

    /// The picker reports a color for the template's color slot (`None` = it closed).
    pub fn template_color_picked(&mut self, color: Option<EffectColor>) {
        self.template.color_picked(color);
        self.pump_template();
    }

    // MARK: Layout

    fn body_height(&self) -> f64 {
        match self.mode {
            ClipSectionMode::Audio => self.audio_block().map_or(0.0, TrackAudioDraw::height),
            ClipSectionMode::Shape => 2.0 * ControlsGrid::ROW_HEIGHT,
            ClipSectionMode::Matte => ControlsGrid::ROW_HEIGHT,
            ClipSectionMode::Graphic => self.graphic_rows() * ControlsGrid::ROW_HEIGHT + self.item_rows_height,
            ClipSectionMode::Text => self.text_height,
            ClipSectionMode::Template => self.template.height(),
            ClipSectionMode::None | ClipSectionMode::Captions => 0.0,
        }
    }

    /// Height for the current width; 0 when no section applies.
    pub fn height(&self) -> f64 {
        match self.mode {
            ClipSectionMode::None | ClipSectionMode::Captions => 0.0,
            _ if self.is_collapsed() => self.header_height(),
            _ => self.header_height() + self.body_height(),
        }
    }

    fn kind_frame(&self, i: usize) -> CGRect {
        CGRect::new(
            ControlsGrid::VALUE_X + i as f64 * KIND_BUTTON,
            self.header_height() + ((ControlsGrid::ROW_HEIGHT - 22.0) / 2.0).round(),
            KIND_BUTTON,
            22.0,
        )
    }

    fn well_frame(&self) -> CGRect {
        CGRect::new(
            ControlsGrid::VALUE_X,
            self.header_height() + ((ControlsGrid::ROW_HEIGHT - 18.0) / 2.0).round(),
            44.0,
            18.0,
        )
    }

    fn picker_frame(&self) -> Option<CGRect> {
        if self.graphic_picker.is_empty() {
            return None;
        }
        let inset = ((ControlsGrid::ROW_HEIGHT - ControlsGrid::CONTROL_HEIGHT) / 2.0).round();
        Some(CGRect::new(
            ControlsGrid::VALUE_X,
            self.header_height() + inset,
            PICKER_WIDTH,
            ControlsGrid::CONTROL_HEIGHT,
        ))
    }

    fn edit_frame(&self) -> CGRect {
        let inset = ((ControlsGrid::ROW_HEIGHT - ControlsGrid::CONTROL_HEIGHT) / 2.0).round();
        CGRect::new(
            ControlsGrid::VALUE_X,
            self.header_height() + (self.graphic_rows() - 1.0) * ControlsGrid::ROW_HEIGHT + inset,
            EDIT_BUTTON_WIDTH,
            ControlsGrid::CONTROL_HEIGHT,
        )
    }

    pub fn hex_string(c: ColorMatteColor) -> String {
        format!("#{:02X}{:02X}{:02X}", c.r, c.g, c.b)
    }

    fn symbol(k: ShapeKind) -> SQIcon {
        match k {
            ShapeKind::Rectangle => SQIcon::ShapeRectangle,
            ShapeKind::Ellipse => SQIcon::ShapeEllipse,
            ShapeKind::Line => SQIcon::ShapeLine,
            ShapeKind::Arrow => SQIcon::ArrowRight,
        }
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, cx: &mut UiCx) {
        let h = self.height();
        if h <= 0.0 {
            return;
        }
        let t = self.theme;
        let fs = f64::from(type_size::BODY);
        c.save_gstate();
        c.clip_to(CGRect::new(0.0, 0.0, self.width, h));
        c.fill(CGRect::new(0.0, 0.0, self.width, h), t.panel());
        let hh = self.header_height();
        if hh == 0.0 {
            self.draw_body(c, cx, &t);
            c.restore_gstate();
            return;
        }
        // No line on top: the rows above end with their own bottom line, a second one would double it (redesign #17).
        let dir = if self.is_collapsed() { Direction::Right } else { Direction::Down };
        InspectorDraw::chevron(c, CGRect::new(ControlsGrid::HEADER_TOGGLE_X, 0.0, 12.0, hh), dir, t.label3(), 8.0);
        let title_w = (self.width - ControlsGrid::HEADER_LABEL_X).max(0.0);
        c.draw_text_in(
            &SQL10n::string(self.mode.title()),
            CGRect::new(ControlsGrid::HEADER_LABEL_X, 0.0, title_w, hh),
            fs,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        c.fill(CGRect::new(0.0, hh - 1.0, self.width, 1.0), t.separator());
        if !self.is_collapsed() {
            self.draw_body(c, cx, &t);
        }
        c.restore_gstate();
    }

    fn label(&self, c: &mut Canvas, s: &str, y: f64) {
        let w = ControlsGrid::VALUE_X - ControlsGrid::LABEL_X - ControlsGrid::GAP;
        let r = CGRect::new(ControlsGrid::LABEL_X, y, w, ControlsGrid::ROW_HEIGHT);
        let fs = f64::from(type_size::BODY);
        crate::ec_draw::effect_controls_draw_panel::EffectControlsDrawPanel::draw_label_lines(
            c,
            &SQL10n::string(s),
            r,
            ControlsGrid::ROW_HEIGHT,
            fs,
            self.theme.label2(),
        );
    }

    fn draw_body(&mut self, c: &mut Canvas, cx: &mut UiCx, t: &DrawTheme) {
        let y = self.header_height();
        let fs = f64::from(type_size::BODY);
        match self.mode {
            ClipSectionMode::Template => {
                self.template.theme = *t;
                c.save_gstate();
                c.translate_by(0.0, y);
                self.template.draw(c, cx);
                c.restore_gstate();
            }
            ClipSectionMode::Audio => {
                if let Some(b) = self.audio_track.and_then(|id| self.audio.get(&id)) {
                    c.save_gstate();
                    c.translate_by(0.0, y);
                    b.draw(c, cx);
                    c.restore_gstate();
                }
            }
            ClipSectionMode::Shape => {
                self.label(c, "Shape", y);
                for (i, k) in SHAPES.iter().enumerate() {
                    let f = self.kind_frame(i);
                    let on = *k == self.shape_kind;
                    if on || self.hover == Hit::Kind(i) {
                        let fill = if on { t.fill_pressed() } else { t.fill_hover() };
                        c.fill_rounded(f.inset_by(1.0, 0.0), f64::from(radius::SMALL), fill);
                    }
                    let col = if on { t.label() } else { t.label2() };
                    c.draw_icon(Self::symbol(*k), CGPoint::new(f.mid_x() - 6.0, f.mid_y() - 6.0), 12.0, col, None);
                }
                let w = (self.width - ControlsGrid::VALUE_X - ControlsGrid::TRAILING).max(0.0);
                let r = CGRect::new(ControlsGrid::VALUE_X, y + ControlsGrid::ROW_HEIGHT, w, ControlsGrid::ROW_HEIGHT);
                c.draw_text_in(
                    &SQL10n::string("Size and colors: Shape effect below"),
                    r,
                    fs,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            ClipSectionMode::Matte => {
                self.label(c, "Color", y);
                let m = self.matte_color;
                let col = Color::rgb(f32::from(m.r) / 255.0, f32::from(m.g) / 255.0, f32::from(m.b) / 255.0);
                let well = self.well_frame();
                InspectorDraw::color_well(c, col, well, self.hover == Hit::Well, t);
                let r = CGRect::new(well.max_x() + ControlsGrid::GAP, y, 80.0, ControlsGrid::ROW_HEIGHT);
                c.draw_text_in(&Self::hex_string(m), r, fs, t.label2(), TextAlign::Left, 0.0, 0);
            }
            ClipSectionMode::Graphic => {
                if let Some(f) = self.picker_frame() {
                    self.label(c, "Layer", f.min_y() - ((ControlsGrid::ROW_HEIGHT - f.height) / 2.0).round());
                    let title = self
                        .picked_item
                        .and_then(|id| self.graphic_picker.iter().find(|e| e.0 == id))
                        .map_or_else(|| SQL10n::string("Whole graphic"), |e| e.1.clone());
                    let hovering = self.hover == Hit::LayerPicker;
                    InspectorDraw::popup(c, &title, f, hovering, false, true, true, f.height, None, t);
                }
                let f = self.edit_frame();
                let dy = ((ControlsGrid::ROW_HEIGHT - f.height) / 2.0).round();
                self.label(c, &self.layer_summary.clone(), f.min_y() - dy);
                let hovering = self.hover == Hit::EditGraphics;
                let pressed = self.pressed == Hit::EditGraphics;
                let title = SQL10n::string("Edit in Graphics");
                InspectorDraw::button(c, &title, f, hovering, pressed, self.can_edit_graphics, false, f.height, t);
            }
            ClipSectionMode::None | ClipSectionMode::Text | ClipSectionMode::Captions => {}
        }
    }

    // MARK: Pointer and keys

    fn hit(&self, p: CGPoint) -> Hit {
        let h = self.height();
        if h <= 0.0 || p.y < 0.0 || p.y >= h {
            return Hit::None;
        }
        if p.y < self.header_height() {
            return Hit::Header;
        }
        if self.is_collapsed() {
            return Hit::None;
        }
        match self.mode {
            ClipSectionMode::Audio => Hit::Audio,
            ClipSectionMode::Template => Hit::Template,
            ClipSectionMode::Shape => {
                (0..SHAPES.len()).find(|i| self.kind_frame(*i).contains(p)).map_or(Hit::None, Hit::Kind)
            }
            ClipSectionMode::Matte if self.well_frame().contains(p) => Hit::Well,
            ClipSectionMode::Graphic if self.picker_frame().is_some_and(|f| f.contains(p)) => Hit::LayerPicker,
            ClipSectionMode::Graphic if self.edit_frame().contains(p) => Hit::EditGraphics,
            _ => Hit::None,
        }
    }

    fn in_audio(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y - self.header_height())
    }

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover = p.map_or(Hit::None, |p| self.hit(p));
        let local = (self.hover == Hit::Audio).then(|| p.map(|p| self.in_audio(p))).flatten();
        if let Some(a) = self.audio_block_mut() {
            a.mouse_moved(local);
        }
        self.template.mouse_moved((self.hover == Hit::Template).then(|| p.map(|p| self.in_audio(p))).flatten());
    }

    pub fn mouse_down(&mut self, cx: &mut UiCx, p: CGPoint, click_count: i64) {
        self.pressed = self.hit(p);
        if self.pressed == Hit::LayerPicker {
            self.pressed = Hit::None;
            if let (Some(f), true) = (self.picker_frame(), self.graphic_clip.is_some()) {
                let (entries, picked) = (self.graphic_picker.clone(), self.picked_item);
                self.actions.push(SectionAction::LayerMenu { entries, picked, anchor: f });
            }
            return;
        }
        let local = self.in_audio(p);
        let on_audio = self.pressed == Hit::Audio;
        if let Some(a) = self.audio_block_mut() {
            if on_audio {
                a.mouse_down(local, Some(click_count), cx);
            } else {
                a.resign_focus(cx);
            }
        }
        self.pump_audio();
        if self.pressed == Hit::Template {
            self.template.mouse_down(local, Some(click_count), cx);
        } else {
            self.template.resign_focus(cx);
        }
        self.pump_template();
    }

    /// The keyboard left the panel: the track audio fields and the template fields commit and close.
    pub fn resign_focus(&mut self, cx: &mut UiCx) {
        if let Some(a) = self.audio_block_mut() {
            a.resign_focus(cx);
        }
        self.pump_audio();
        self.template.resign_focus(cx);
        self.pump_template();
    }

    pub fn mouse_dragged(&mut self, cx: &mut UiCx, p: CGPoint, modifiers: InputModifiers) {
        if self.pressed == Hit::Template {
            let local = self.in_audio(p);
            self.template.mouse_dragged(local, modifiers, self.theme.scale, cx);
            self.pump_template();
        }
        if self.pressed == Hit::Audio {
            let local = self.in_audio(p);
            if let Some(a) = self.audio_block_mut() {
                a.mouse_dragged(local, modifiers, cx);
            }
            self.pump_audio();
        }
    }

    pub fn mouse_up(&mut self, cx: &mut UiCx, p: CGPoint) {
        let was = std::mem::replace(&mut self.pressed, Hit::None);
        if was == Hit::Template {
            self.template.mouse_up(self.in_audio(p), cx);
            self.pump_template();
            return;
        }
        if was == Hit::Audio {
            let local = self.in_audio(p);
            if let Some(a) = self.audio_block_mut() {
                a.mouse_up(local, cx);
            }
            self.pump_audio();
            return;
        }
        if was == Hit::None || self.hit(p) != was {
            return;
        }
        match was {
            Hit::Header => self.toggle_collapsed(),
            Hit::Kind(i) => {
                let k = SHAPES[i];
                if let Some(id) = self.shape_clip
                    && k != self.shape_kind
                {
                    self.shape_kind = k;
                    self.actions.push(SectionAction::SetShapeKind { clip: id, kind: k });
                }
            }
            Hit::Well => self.pick_matte(),
            Hit::EditGraphics if self.can_edit_graphics => self.actions.push(SectionAction::EditGraphics),
            _ => {}
        }
    }

    fn toggle_collapsed(&mut self) {
        if self.mode == ClipSectionMode::None || !self.collapsible() {
            return;
        }
        let title = self.mode.title();
        if !self.collapsed.remove(title) {
            self.collapsed.insert(title);
        }
        self.actions.push(SectionAction::HeightChanged);
    }

    fn pick_matte(&mut self) {
        let m = self.matte_color;
        self.matte_gesture_open = false;
        let current = EffectColor {
            red: f64::from(m.r) / 255.0,
            green: f64::from(m.g) / 255.0,
            blue: f64::from(m.b) / 255.0,
            alpha: 1.0,
        };
        self.actions.push(SectionAction::PickMatteColor { current, anchor: self.well_frame() });
    }

    /// The picker reports a color (`None` = it closed): one picker session is one undo step.
    pub fn matte_picked(&mut self, color: Option<EffectColor>) {
        let Some(id) = self.matte_clip else { return };
        let Some(color) = color else {
            self.matte_gesture_open = false;
            return;
        };
        let byte = |x: f64| (x.clamp(0.0, 1.0) * 255.0).round() as u8;
        let c = ColorMatteColor { r: byte(color.red), g: byte(color.green), b: byte(color.blue) };
        self.matte_color = c;
        self.actions.push(SectionAction::SetColorMatte { clip: id, color: c, continues: self.matte_gesture_open });
        self.matte_gesture_open = true;
    }

    pub fn key(&mut self, cx: &mut UiCx, k: InputKey, modifiers: InputModifiers) -> bool {
        if self.mode == ClipSectionMode::Template {
            let used = self.template.key(k, modifiers, cx);
            self.pump_template();
            return used;
        }
        if self.mode != ClipSectionMode::Audio {
            return false;
        }
        let used = self.audio_block_mut().is_some_and(|a| a.key(k, modifiers, cx));
        self.pump_audio();
        used
    }

    pub fn tick(&mut self, now: f64) {
        if self.mode == ClipSectionMode::Template {
            self.template.tick(now);
            self.pump_template();
        }
        if self.mode == ClipSectionMode::Audio
            && let Some(a) = self.audio_block_mut()
        {
            a.tick(now);
        }
        self.pump_audio();
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.hit(p) {
            Hit::Header => {
                let fmt = if self.is_collapsed() { "Expand %@" } else { "Collapse %@" };
                Some(SQL10n::format(fmt, &[&SQL10n::string(self.mode.title())]))
            }
            Hit::Kind(i) => Some(SQL10n::string(match SHAPES[i] {
                ShapeKind::Rectangle => "Rectangle",
                ShapeKind::Ellipse => "Ellipse",
                ShapeKind::Line => "Line",
                ShapeKind::Arrow => "Arrow",
            })),
            Hit::Well => Some(SQL10n::string("Color Matte color")),
            Hit::LayerPicker => Some(SQL10n::string(
                "Pick a layer of this graphic to edit its Motion, Opacity and effects with keyframes",
            )),
            Hit::EditGraphics => Some(SQL10n::string("Edit in Graphics")),
            Hit::Audio => self.audio_block().and_then(|a| a.help(self.in_audio(p))),
            Hit::Template => self.template.help(self.in_audio(p)),
            Hit::None => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_masks::track_audio_inspector_model::TrackAudioInspectorModel;
    use sq_audiofx::presets::PresetLibrary;
    use sq_core_color::ColorMatteGeneratorExt;
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn clip(kind: TrackKind) -> Clip {
        Clip::new(
            Id::from_u128(10),
            "C",
            Id::from_u128(11),
            kind,
            TimeRange::new(Time::ZERO, Time::new(5, 1)),
            Time::ZERO,
        )
    }

    fn audio_for(_t: Id, role: Option<AudioTag>) -> TrackAudioDraw {
        let m = TrackAudioInspectorModel::new(PresetLibrary::default(), None, role, Box::new(SequentialIds::default()));
        TrackAudioDraw::new(m)
    }

    fn shown(s: &mut ClipSectionsDraw, c: &Clip, track: Id) {
        s.sync(Some(c), &[(track, None)], Some(track), &mut audio_for);
    }

    fn click(s: &mut ClipSectionsDraw, p: CGPoint) {
        let mut cx = UiCx::new();
        s.mouse_down(&mut cx, p, 1);
        s.mouse_up(&mut cx, p);
    }

    #[test]
    fn a_closing_section_adds_no_line_on_top_of_the_rows_line() {
        let mut s = ClipSectionsDraw::new();
        let mut c = clip(TrackKind::Video);
        c.generator = Some(GeneratorRef::shape(ShapeKind::Rectangle));
        shown(&mut s, &c, Id::from_u128(1));
        let a = clip(TrackKind::Audio);
        shown(&mut s, &a, Id::from_u128(1));
        assert_eq!(s.mode(), ClipSectionMode::Audio);
        let mut canvas = Canvas::with_size(400.0, 600.0, None, 1.0);
        s.draw(&mut canvas, &mut UiCx::new());
        let t = DrawTheme::default();
        // Redesign #17: the rows above end with their own line; no 1 pt line may sit in the first points of the section.
        let top_lines =
            canvas.list.quads().iter().filter(|q| q.rect.h <= 1.01 && q.rect.y < 1.0 && q.color == t.separator());
        assert_eq!(top_lines.count(), 0);
    }

    #[test]
    fn modes_follow_the_clip() {
        assert_eq!(ClipSectionMode::resolve(None), ClipSectionMode::None);
        assert_eq!(ClipSectionMode::resolve(Some(&clip(TrackKind::Video))), ClipSectionMode::None);
        assert_eq!(ClipSectionMode::resolve(Some(&clip(TrackKind::Audio))), ClipSectionMode::Audio);
        let mut c = clip(TrackKind::Video);
        c.generator = Some(GeneratorRef::shape(ShapeKind::Ellipse));
        assert_eq!(ClipSectionMode::resolve(Some(&c)), ClipSectionMode::Shape);
        c.generator = Some(GeneratorRef::color_matte(ColorMatteColor { r: 1, g: 2, b: 3 }));
        assert_eq!(ClipSectionMode::resolve(Some(&c)), ClipSectionMode::Matte);
        assert!(ClipSectionMode::Shape.leads() && !ClipSectionMode::Audio.leads());
        assert_eq!(ClipSectionMode::Matte.kind_name(), Some("Color Matte"));
        assert_eq!(ClipSectionMode::Audio.kind_name(), None);
    }

    #[test]
    fn shape_buttons_queue_one_edit_and_header_collapses() {
        let mut s = ClipSectionsDraw::new();
        let mut c = clip(TrackKind::Video);
        c.generator = Some(GeneratorRef::shape(ShapeKind::Rectangle));
        shown(&mut s, &c, Id::from_u128(1));
        assert_eq!(s.take_actions(), vec![SectionAction::HeightChanged]);
        let full = 3.0 * ControlsGrid::ROW_HEIGHT;
        assert_eq!(s.height(), full);
        let f = s.kind_frame(2);
        click(&mut s, CGPoint::new(f.mid_x(), f.mid_y()));
        assert_eq!(s.take_actions(), vec![SectionAction::SetShapeKind { clip: c.id, kind: ShapeKind::Line }]);
        click(&mut s, CGPoint::new(f.mid_x(), f.mid_y()));
        assert!(s.take_actions().is_empty());
        click(&mut s, CGPoint::new(20.0, 5.0));
        assert_eq!(s.take_actions(), vec![SectionAction::HeightChanged]);
        assert!(s.is_collapsed());
        assert_eq!(s.height(), ControlsGrid::HEADER_HEIGHT);
        assert_eq!(s.help(CGPoint::new(20.0, 5.0)).as_deref(), Some("Expand Shape"));
    }

    #[test]
    fn matte_picker_session_is_one_undo_step() {
        let mut s = ClipSectionsDraw::new();
        let mut c = clip(TrackKind::Video);
        c.generator = Some(GeneratorRef::color_matte(ColorMatteColor { r: 255, g: 0, b: 128 }));
        shown(&mut s, &c, Id::from_u128(1));
        s.take_actions();
        assert_eq!(s.matte_color(), ColorMatteColor { r: 255, g: 0, b: 128 });
        assert_eq!(ClipSectionsDraw::hex_string(s.matte_color()), "#FF0080");
        let w = s.well_frame();
        click(&mut s, CGPoint::new(w.mid_x(), w.mid_y()));
        let acts = s.take_actions();
        assert!(matches!(acts.as_slice(), [SectionAction::PickMatteColor { anchor, .. }] if *anchor == w));
        let col = |r| EffectColor { red: r, green: 0.0, blue: 0.0, alpha: 1.0 };
        s.matte_picked(Some(col(1.0)));
        s.matte_picked(Some(col(0.5)));
        s.matte_picked(None);
        let want = |r, continues| SectionAction::SetColorMatte {
            clip: c.id,
            color: ColorMatteColor { r, g: 0, b: 0 },
            continues,
        };
        assert_eq!(s.take_actions(), vec![want(255, false), want(128, true)]);
    }

    #[test]
    fn graphic_row_dims_without_a_panel_and_audio_hosts_the_track_block() {
        let mut s = ClipSectionsDraw::new();
        let c = clip(TrackKind::Audio);
        let track = Id::from_u128(7);
        shown(&mut s, &c, track);
        assert_eq!(s.mode(), ClipSectionMode::Audio);
        assert!(s.audio_block().is_some());
        let body = s.audio_block().map_or(0.0, TrackAudioDraw::height);
        assert!(body > 0.0 && s.height() == ControlsGrid::HEADER_HEIGHT + body);
        // A role change on the project side reaches the block (and edits nothing).
        s.take_actions();
        s.sync(Some(&c), &[(track, Some(AudioTag::Dialogue))], Some(track), &mut audio_for);
        assert_eq!(s.audio_block().and_then(|a| a.model.role()), Some(AudioTag::Dialogue));
        assert!(!s.take_actions().iter().any(|a| matches!(a, SectionAction::AudioPreset { .. })), "undo must not edit");
        // The track left the timeline: its block goes.
        s.sync(None, &[], None, &mut audio_for);
        assert!(s.audio_block().is_none());
        assert_eq!(s.height(), 0.0);

        let mut g = clip(TrackKind::Video);
        g.generator = None;
        let mut s = ClipSectionsDraw::new();
        s.mode = ClipSectionMode::Graphic;
        let e = s.edit_frame();
        click(&mut s, CGPoint::new(e.mid_x(), e.mid_y()));
        assert!(s.take_actions().is_empty());
        s.can_edit_graphics = true;
        let e = s.edit_frame();
        click(&mut s, CGPoint::new(e.mid_x(), e.mid_y()));
        assert_eq!(s.take_actions(), vec![SectionAction::EditGraphics]);
    }

    #[test]
    fn a_loudness_pick_becomes_an_action_and_a_project_side_change_follows_without_one() {
        let mut s = ClipSectionsDraw::new();
        let c = clip(TrackKind::Audio);
        let track = Id::from_u128(7);
        shown(&mut s, &c, track);
        s.take_actions();
        if let Some(a) = s.audio.get_mut(&track) {
            a.model.set_loudness_target(Some(-23.0));
        }
        s.pump_audio();
        assert!(s.take_actions().contains(&SectionAction::AudioLoudness { track, lufs: Some(-23.0) }));
        s.sync_loudness(&[(track, Some(-16.0))]);
        assert_eq!(s.audio_block().and_then(|a| a.model.loudness_target()), Some(-16.0));
        s.pump_audio();
        assert!(s.take_actions().is_empty(), "a followed change makes no action");
    }

    fn template_clip(zones: bool) -> Clip {
        use sq_core_model::{AnimationZones, SlotValue, TemplateSlot, TemplateSlotKind, ZoneMiddle};
        let mut c = clip(TrackKind::Video);
        c.sequence = Some(Id::from_u128(50));
        c.template_slots = Some(vec![TemplateSlot {
            id: Id::from_u128(60),
            name: "Title".to_string(),
            kind: TemplateSlotKind::Text,
            layer: Id::from_u128(61),
            graphics_layer: None,
            path: "text".to_string(),
            value: SlotValue::Text("Hi".to_string()),
        }]);
        c.zones = zones.then(|| AnimationZones::new(Time::ZERO, Time::ZERO, ZoneMiddle::Hold, None));
        c
    }

    #[test]
    fn a_template_clip_hosts_its_slots_and_zones() {
        use crate::graphics::template_slots_draw::{Control, TemplateEvent};
        let mut s = ClipSectionsDraw::new();
        s.sync(Some(&template_clip(false)), &[], None, &mut audio_for);
        assert_eq!(s.mode(), ClipSectionMode::Template);
        // Header, one slot row, the "Keep intro and outro" row.
        assert_eq!(s.height(), ControlsGrid::HEADER_HEIGHT + 2.0 * ControlsGrid::ROW_HEIGHT);
        s.take_actions();
        // Turning the zones on queues the event for the clip.
        let f = s.template.frame(Control::Zones);
        click(&mut s, CGPoint::new(f.min_x() + 4.0, f.mid_y() + ControlsGrid::HEADER_HEIGHT));
        assert_eq!(
            s.take_actions(),
            vec![SectionAction::Template { clip: Id::from_u128(10), event: TemplateEvent::Zones(true) }]
        );
        // The zones appeared: the Middle row grows the section.
        s.sync(Some(&template_clip(true)), &[], None, &mut audio_for);
        assert_eq!(s.height(), ControlsGrid::HEADER_HEIGHT + 3.0 * ControlsGrid::ROW_HEIGHT);
        assert!(s.take_actions().contains(&SectionAction::HeightChanged));
    }

    #[test]
    fn text_and_graphic_bodies_take_the_hosts_heights() {
        let mut s = ClipSectionsDraw::new();
        s.mode = ClipSectionMode::Text;
        s.set_text_height(120.0);
        assert_eq!((s.height(), s.take_actions()), (120.0, vec![SectionAction::HeightChanged]));
        s.mode = ClipSectionMode::Graphic;
        s.set_item_rows_height(48.0);
        assert_eq!(s.height(), ControlsGrid::HEADER_HEIGHT + ControlsGrid::ROW_HEIGHT + 48.0);
        assert_eq!(s.items_top(), ControlsGrid::HEADER_HEIGHT + ControlsGrid::ROW_HEIGHT);
    }

    #[test]
    fn the_layer_picker_adds_a_row_opens_its_menu_and_reports_the_choice() {
        let mut s = ClipSectionsDraw::new();
        s.mode = ClipSectionMode::Graphic;
        s.graphic_clip = Some(Id::from_u128(70));
        assert_eq!(s.items_top(), ControlsGrid::HEADER_HEIGHT + ControlsGrid::ROW_HEIGHT);
        let (a, b) = (Id::from_u128(71), Id::from_u128(72));
        s.graphic_picker = vec![(b, "Top".to_string()), (a, "Bottom".to_string())];
        assert_eq!(s.items_top(), ControlsGrid::HEADER_HEIGHT + 2.0 * ControlsGrid::ROW_HEIGHT);
        // The Edit button moves down to the second row.
        assert!(s.edit_frame().min_y() > ControlsGrid::HEADER_HEIGHT + ControlsGrid::ROW_HEIGHT);
        let f = s.picker_frame().expect("picker row");
        let mut cx = UiCx::new();
        s.mouse_down(&mut cx, CGPoint::new(f.mid_x(), f.mid_y()), 1);
        assert_eq!(
            s.take_actions(),
            vec![SectionAction::LayerMenu {
                entries: vec![(b, "Top".to_string()), (a, "Bottom".to_string())],
                picked: None,
                anchor: f,
            }]
        );
        s.layer_picked(Some(a));
        assert_eq!(s.picked_item(), None, "only the session's selection decides what is shown");
        assert_eq!(s.take_actions(), vec![SectionAction::GraphicItem { clip: Id::from_u128(70), layer: Some(a) }]);
        // The shared selection decides what is shown: one listed item, else the whole graphic.
        let sel = |ids: &[Id]| {
            sq_editor_session::GraphicLayerSelection::new(Id::from_u128(70), ids.iter().copied().collect())
        };
        s.set_layer_selection(Some(&sel(&[b])));
        assert_eq!(s.picked_item(), Some(b));
        s.set_layer_selection(Some(&sel(&[a, b])));
        assert_eq!(s.picked_item(), None);
        s.set_layer_selection(Some(&sel(&[Id::from_u128(99)])));
        assert_eq!(s.picked_item(), None);
    }

    fn text_clip(text: &str) -> Clip {
        use sq_text::text_style::TextStyle;
        let mut c = clip(TrackKind::Video);
        let t = TextTemplate::new("T", text, TextStyle::default());
        c.generator = Some(TextGenerator::make_ref(&t, None).unwrap());
        c
    }

    fn text_host() -> (TextInspectorModel, TextBlockDraw) {
        use crate::text::style_library::TextStyleLibrary;
        use sq_text::caption_presets::CaptionPresetLibrary;
        use sq_text::text_style::TextStyle;
        let m = TextInspectorModel::new(
            TextStyle::default(),
            AnimationSet::new(None, None),
            Some(CaptionPresetLibrary::built_in()),
            Box::new(|| vec!["Helvetica".to_string()]),
            TextStyleLibrary::default(),
            Box::new(SequentialIds::default()),
        );
        (m, TextBlockDraw::new())
    }

    #[test]
    fn loading_a_text_clip_fills_model_block_and_height() {
        let (mut m, mut b) = text_host();
        let mut s = ClipSectionsDraw::new();
        let c = text_clip("Hello");
        shown(&mut s, &c, Id::from_u128(11));
        assert_eq!(s.mode(), ClipSectionMode::Text);
        s.load_text(&c, &mut m, &mut b, None, Vec2::new(1920.0, 1080.0), BTreeSet::new());
        assert_eq!((b.text.as_str(), m.target, m.frame_size), ("Hello", Some(c.id), Vec2::new(1920.0, 1080.0)));
        assert_eq!(m.clip_duration, Some(Time::new(5, 1)));
        assert!(s.height() > 0.0);
        assert_eq!(s.height(), b.height(&m, Part::Text));
        // A clip without a decodable text is never edited.
        let mut bad = clip(TrackKind::Video);
        bad.generator = Some(GeneratorRef::shape(ShapeKind::Ellipse));
        s.load_text(&bad, &mut m, &mut b, None, Vec2::new(1.0, 1.0), BTreeSet::new());
        assert_eq!((m.target, b.text.as_str()), (None, ""));
    }

    #[test]
    fn typing_and_style_edits_become_update_actions_in_one_gesture() {
        let (mut m, mut b) = text_host();
        let mut s = ClipSectionsDraw::new();
        let c = text_clip("Hello");
        shown(&mut s, &c, Id::from_u128(11));
        s.load_text(&c, &mut m, &mut b, None, Vec2::new(1920.0, 1080.0), BTreeSet::new());
        s.take_actions();
        let mut reqs = vec![
            BlockRequest::TextBegin,
            BlockRequest::TextChange("Hello!".into()),
            BlockRequest::SampleColor(crate::text::block_draw::Layer::Fill),
            BlockRequest::TextChange("Hello!!".into()),
        ];
        s.pump_text(&mut m, &mut b, &mut reqs);
        assert_eq!(reqs, vec![BlockRequest::SampleColor(crate::text::block_draw::Layer::Fill)]);
        let acts = s.take_actions();
        let flags: Vec<(String, bool)> = acts
            .iter()
            .filter_map(|a| match a {
                SectionAction::UpdateText { to, continues, .. } => Some((to.text.clone(), *continues)),
                _ => None,
            })
            .collect();
        assert_eq!(flags, vec![("Hello!".to_string(), false), ("Hello!!".to_string(), true)]);
        // A style edit joins the update stream with the typed text kept.
        m.set_size(77.0);
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        let acts = s.take_actions();
        let Some(SectionAction::UpdateText { to, from, .. }) = acts.last() else { panic!("no update") };
        assert_eq!((to.style.size, to.text.as_str(), from.text.as_str()), (77.0, "Hello!!", "Hello!!"));
        // Unchanged text sends nothing.
        s.pump_text(&mut m, &mut b, &mut vec![BlockRequest::TextChange("Hello!!".into())]);
        assert!(s.take_actions().is_empty());
    }

    #[test]
    fn the_look_popup_asks_for_a_name_saves_it_and_a_cancel_does_nothing() {
        use crate::text::block_draw::NameAsks;
        let (mut m, mut b) = text_host();
        let mut s = ClipSectionsDraw::new();
        s.wire_looks(&mut b);
        let asks = NameAsks::default();
        b.ask_name = Some(asks.ask());
        let neon = ControlLooks { entries: vec![("a".into(), "Neon".into())], selected: None, carried: None };
        s.set_looks(neon);
        let mut source = b.look_source.as_ref().expect("look source")();
        assert_eq!(source.titles, ["Neon"]);
        (source.pick)("a");
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        assert_eq!(s.take_actions(), vec![SectionAction::Look(LookAction::Apply("a".into()))]);
        // The + asks first; nothing is saved until the name comes back.
        let mut add = source.add.expect("the + button");
        add();
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        assert!(s.take_actions().is_empty());
        let mut asked = asks.take();
        assert_eq!(asked.len(), 1);
        let ask = asked.remove(0);
        assert_eq!((ask.title.as_str(), ask.initial.as_str()), ("Save as New Look", "My Look"));
        (ask.done)(Some("  Mine ".into()));
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        assert_eq!(s.take_actions(), vec![SectionAction::Look(LookAction::SaveAsNew("Mine".into()))]);
        // Cancel, and an empty name, do nothing.
        for answer in [None, Some("   ".to_string())] {
            add();
            s.pump_text(&mut m, &mut b, &mut Vec::new());
            (asks.take().remove(0).done)(answer);
            s.pump_text(&mut m, &mut b, &mut Vec::new());
            assert!(s.take_actions().is_empty());
        }
    }

    #[test]
    fn the_look_menu_renames_the_carried_look_and_a_built_in_only_saves() {
        use crate::text::block_draw::NameAsks;
        let (mut m, mut b) = text_host();
        let mut s = ClipSectionsDraw::new();
        s.wire_looks(&mut b);
        let asks = NameAsks::default();
        b.ask_name = Some(asks.ask());
        let carried = |can_update| Some(LookStatus { name: "Neon".into(), edited: false, can_update });
        s.set_looks(ControlLooks { entries: Vec::new(), selected: None, carried: carried(false) });
        assert_eq!(b.look_context_items(&m).len(), 1, "a built-in Look only offers Save as New");
        s.set_looks(ControlLooks { entries: Vec::new(), selected: None, carried: carried(true) });
        let items = b.look_context_items(&m);
        assert_eq!(items.len(), 4);
        // Rename... asks with the current name.
        (items[2].action.as_ref().expect("rename"))();
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        let ask = asks.take().remove(0);
        assert_eq!((ask.title.as_str(), ask.initial.as_str()), ("Rename Look", "Neon"));
        (ask.done)(Some("Glow".into()));
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        assert_eq!(s.take_actions(), vec![SectionAction::Look(LookAction::Rename("Glow".into()))]);
        (items[3].action.as_ref().expect("delete"))();
        s.pump_text(&mut m, &mut b, &mut Vec::new());
        assert_eq!(s.take_actions(), vec![SectionAction::Look(LookAction::Delete)]);
    }
}
