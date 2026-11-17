// Swift: Draw/GraphicsPanelDraw.swift
//! The Graphics panel on the shared toolkit: header (clip name, layer count, Save as Template...), the layer list with its
//! footer and a drag handle under it, then the property rows of the selection, scrolled: Intro and Outro + Template Fields
//! with no layer selected; Arrange, Transform, Follow, Shape + Appearance (or the shared text block for a text layer) and the
//! layer's effects otherwise. Every value goes through `GraphicsEditor`, one undo step per gesture. The rows rebuild when
//! the structure key changes and read their values on every draw. Coordinates: points, y down, (0, 0) = the panel's
//! top-left.
//!
//! The Swift panel owned the editor and called its callbacks; here the editor and the session live in [`PanelHost`] (the
//! context of both forms) and everything the host must do (menus, the color picker, Save as Template...) is a
//! [`PanelRequest`] it drains with `take_requests`.
//
// The list height, the Link Scale switch and the folded sections are remembered in the defaults store (`LIST_HEIGHT_KEY`,
// `SCALE_LINKED_KEY`). The text model's frame size is `AnimationChoices.frameSize(displayFormat)` (the active variant).

use std::cell::RefCell;
use std::rc::Rc;

use crate::text::style_library::TextStyleLibrary;
use sq_core_effects::effect_preset::EffectPreset;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::{
    BlendMode, ClipEffect, EffectCatalog, EffectColor, EffectParamKind, FollowTarget, GraphicsContent, GraphicsEdges,
    GraphicsLayer, ShapeKind, ZoneMiddle,
};
use sq_core_time::{Id, SequentialIds, Time};
use sq_draw::inspector::inspector_controls::{CheckState, InspectorDraw};
use sq_draw::inspector::scrub_field_control::ClickCounter;
use sq_draw::theme::{spacing, type_size};
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_editor_session::EditorSession;
use sq_text::text_style::TextStyle;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::clip_sections::ClipSectionMode;
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
use crate::graphics::editor::{EffectDrop, GraphicsEditor, shape_title};
use crate::graphics::editor_props::Property;
use crate::graphics::form_draw::{GraphicsFormDraw, IconItem, Kind, TextButton};
use crate::graphics::layer_list_draw::GraphicsLayerListDraw;
use crate::graphics::panel_logic::{self, GraphicsEmptyState};
use crate::graphics::template_fields;
use crate::text::block_draw::{BlockRequest, Control, NameAsk, NameAsks, Part as TextPart, TextBlockDraw};
use crate::text::inspector_model::{TextInspectorEvent, TextInspectorModel};

/// Something the panel's rows queued while the host context was borrowed; `run_commands` applies it.
enum Command {
    AddEffect(String),
    ApplyPreset(String, Box<EffectPreset>),
    SaveEffectPreset(Box<EffectPreset>),
}

/// Defaults key of the Link Scale switch (default on).
pub const SCALE_LINKED_KEY: &str = "sq.graphics.scaleLinked";
/// Defaults key of the layer list height.
pub const LIST_HEIGHT_KEY: &str = "sq.graphics.listHeight";

type PresetSource = Rc<dyn Fn() -> Vec<(String, EffectPreset)>>;

/// The context of the panel's forms: the editor and the session it edits.
pub struct PanelHost {
    pub editor: GraphicsEditor,
    /// The host's session while a call runs inside [`GraphicsPanelDraw::with_session`]; a stand-in otherwise.
    pub session: EditorSession,
    /// Align to the frame (each layer on its own) or to the selection; kept for the session.
    pub align_to_frame: bool,
    pub scale_linked: bool,
    /// The stored settings (`sq.graphics.scaleLinked`, `sq.graphics.listHeight`); none = not remembered.
    pub defaults: Option<Box<dyn UiDefaults>>,
    /// A row changed the structure (a shape kind, Align To): the panel rebuilds on the next sync.
    dirty: bool,
    menu: Option<(Vec<SQMenuItem>, CGRect)>,
    commands: Rc<RefCell<Vec<Command>>>,
    presets: Option<PresetSource>,
}

impl PanelHost {
    pub fn new(editor: GraphicsEditor, session: EditorSession) -> PanelHost {
        PanelHost {
            editor,
            session,
            align_to_frame: false,
            scale_linked: true,
            defaults: None,
            dirty: false,
            menu: None,
            commands: Rc::new(RefCell::new(Vec::new())),
            presets: None,
        }
    }

    fn read<R>(&self, f: impl FnOnce(&GraphicsEditor, &EditorSession) -> R) -> R {
        f(&self.editor, &self.session)
    }

    fn write<R>(&mut self, f: impl FnOnce(&mut GraphicsEditor, &mut EditorSession) -> R) -> R {
        let s = &mut self.session;
        f(&mut self.editor, s)
    }

    fn value(&self, p: &Property, axis: usize, k: f64) -> Option<f64> {
        self.read(|e, s| e.value(s, p, axis)).map(|v| v * k + 0.0) // + 0: no "-0"
    }

    fn keyed(&self, p: &Property) -> bool {
        self.read(|e, s| e.is_keyed(s, p))
    }

    fn begin_gesture(&mut self) {
        self.write(|e, s| e.begin_gesture(s));
    }
}

/// What the host does for the panel.
pub enum PanelRequest {
    /// An SQ menu at `anchor` in panel coordinates. The rows queue commands: call `run_commands` once the menu closes.
    Menu { items: Vec<SQMenuItem>, anchor: CGRect },
    /// The SQ color picker; answer each change with `color_changed(target, Some(..))` and the end with `None`.
    PickColor { current: EffectColor, anchor: CGRect, target: ColorTarget },
    /// An eyedropper for the text block (`TextBlockDraw::color_sampled`).
    SampleColor(crate::text::block_draw::Layer),
    /// A double-click on a text layer's row: its text opens for typing on the Program monitor.
    EditText(Id),
    /// "Make Graphic" in the empty state.
    MakeGraphic,
    /// "Save as Template..." in the header.
    SaveTemplate,
    /// "Save Effects as Preset..." in the Effects section.
    SaveEffectPreset(EffectPreset),
    /// Something did not happen (a Custom animation that could not be saved): the host shows it in its status line.
    Notice(String),
    /// Save as New Look, Rename Look, Save Animation: the host shows a name dialog and answers through `done`.
    AskName(NameAsk),
    /// A Look was saved, renamed or deleted in the text block: the host writes the library to its Look store (the one
    /// store the Inspector and the Captions Style tab use), or the change is gone after the next start.
    StylesChanged(Box<TextStyleLibrary>),
}

/// Whose color the picker edits.
#[derive(Clone, Debug, PartialEq)]
pub enum ColorTarget {
    Form(usize),
    Tail(usize),
    Text(Control),
}

/// A pointer region of the panel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    SaveTemplate,
    EmptyAction,
    List,
    Handle,
    Form,
    Text(TextPart),
    Tail,
}

/// The shared text block and its model for a text layer.
struct TextHost {
    block: TextBlockDraw,
    model: TextInspectorModel,
}

pub struct GraphicsPanelDraw {
    pub host: PanelHost,
    pub theme: DrawTheme,
    /// The host samples the Program picture for the text block's eyedropper buttons (Swift `canSampleScreenColor`).
    pub can_sample_screen_color: bool,
    size: CGSize,
    list: GraphicsLayerListDraw,
    form: GraphicsFormDraw<PanelHost>,
    /// The Effects sections under the text block (a text layer's rows are form, text block, tail).
    tail: GraphicsFormDraw<PanelHost>,
    text: Option<TextHost>,
    /// Builds the model the text block edits (font list, saved styles and id source are the host's).
    text_model: Option<Box<dyn Fn() -> TextInspectorModel>>,
    /// The Library's saved animations for the Intro / Outro popups; the text model reads and saves through it.
    animation_keystones: Option<Rc<dyn crate::ec::animation::AnimationKeystoneSource>>,
    /// Notices of the text block (`TextBlockDraw::on_notice`), turned into `PanelRequest::Notice` by `pump_text`.
    notices: Rc<RefCell<Vec<String>>>,
    /// Names the text block asked for, turned into `PanelRequest::AskName` by `pump_text`.
    name_asks: NameAsks,
    text_gesture_open: bool,
    structure_key: Option<String>,
    form_scroll: f64,
    list_height: Option<f64>,
    /// One-line message at the bottom (a refused effect drop) and when it goes away.
    status: Option<(String, f64)>,
    /// The list took the last click (selected rows draw the focused tint).
    list_focused: bool,
    hover: Option<Region>,
    pressed: Option<Region>,
    handle_start: Option<(f64, f64)>,
    counter: ClickCounter,
    empty_hint_bottom: Option<f64>,
    requests: Vec<PanelRequest>,
    now: f64,
}

impl GraphicsPanelDraw {
    pub const HEADER_HEIGHT: f64 = 32.0;
    pub const MIN_LIST_HEIGHT: f64 = GraphicsLayerListDraw::ROW_HEIGHT * 3.0
        + GraphicsLayerListDraw::HEADER_HEIGHT
        + GraphicsLayerListDraw::FOOTER_HEIGHT;
    pub const DEFAULT_LIST_HEIGHT: f64 = GraphicsLayerListDraw::ROW_HEIGHT * 6.0
        + GraphicsLayerListDraw::HEADER_HEIGHT
        + GraphicsLayerListDraw::FOOTER_HEIGHT;
    const HANDLE_GRAB: f64 = 6.0;

    /// `stand_in` is a scratch session the panel holds between calls: the hosts only lend their session
    /// (`HostCx::session` is a `&mut`), so every call that reads or edits it runs inside [`Self::with_session`].
    pub fn new(editor: GraphicsEditor, stand_in: EditorSession) -> GraphicsPanelDraw {
        let mut p = GraphicsPanelDraw {
            can_sample_screen_color: false,
            host: PanelHost::new(editor, stand_in),
            theme: DrawTheme::default(),
            size: CGSize { width: 320.0, height: 480.0 },
            list: GraphicsLayerListDraw::default(),
            form: GraphicsFormDraw::default(),
            tail: GraphicsFormDraw::default(),
            text: None,
            text_model: None,
            animation_keystones: None,
            notices: Rc::default(),
            name_asks: NameAsks::default(),
            text_gesture_open: false,
            structure_key: None,
            form_scroll: 0.0,
            list_height: None,
            status: None,
            list_focused: false,
            hover: None,
            pressed: None,
            handle_start: None,
            counter: ClickCounter::new(),
            empty_hint_bottom: None,
            requests: Vec::new(),
            now: 0.0,
        };
        for f in [&mut p.form, &mut p.tail] {
            f.begin_gesture = Some(Rc::new(|h: &mut PanelHost| h.begin_gesture()));
        }
        p
    }

    /// The Library's effect presets a layer can take.
    /// Runs `f` with the host's `session` as the panel's session (`sync`, `draw`, input, `run_commands`, ..).
    pub fn with_session<R>(&mut self, session: &mut EditorSession, f: impl FnOnce(&mut GraphicsPanelDraw) -> R) -> R {
        std::mem::swap(&mut self.host.session, session);
        let r = f(self);
        std::mem::swap(&mut self.host.session, session);
        r
    }

    pub fn set_effect_presets(&mut self, source: impl Fn() -> Vec<(String, EffectPreset)> + 'static) {
        self.host.presets = Some(Rc::new(source));
    }

    /// How the text block's model is made for a text layer; without it a model that starts on the built-in Looks and
    /// whose Looks nobody saves.
    pub fn set_text_model(&mut self, make: impl Fn() -> TextInspectorModel + 'static) {
        self.text_model = Some(Box::new(make));
    }

    /// Attaches the Library's keystones: saved animations show in the Intro / Outro popups and Save Custom stores one.
    pub fn set_animation_keystones(&mut self, source: Rc<dyn crate::ec::animation::AnimationKeystoneSource>) {
        self.animation_keystones = Some(source);
    }

    pub fn set_size(&mut self, size: CGSize) {
        self.size = size;
    }

    pub fn set_theme(&mut self, theme: DrawTheme) {
        self.theme = theme;
        self.list.theme = theme;
        self.form.theme = theme;
        self.tail.theme = theme;
        if let Some(t) = &mut self.text {
            t.block.theme = theme;
        }
    }

    pub fn status(&self) -> Option<&str> {
        self.status.as_ref().map(|s| s.0.as_str())
    }

    /// The layer list (rows and their frames; the root-level tests click them).
    pub fn list(&self) -> &GraphicsLayerListDraw {
        &self.list
    }

    pub fn structure_key(&self) -> Option<&str> {
        self.structure_key.as_deref()
    }

    pub fn form_scroll(&self) -> f64 {
        self.form_scroll
    }

    pub fn hover(&self) -> Option<Region> {
        self.hover
    }

    /// What the panel asked the host to do since the last call.
    pub fn take_requests(&mut self) -> Vec<PanelRequest> {
        std::mem::take(&mut self.requests)
    }

    // MARK: Session

    /// Call on every session change (project, selection, playhead): drops gone layers from the selection, reloads the list
    /// and rebuilds the rows when their structure changed. Drawing calls it too.
    pub fn sync(&mut self, cx: &mut UiCx) {
        self.now = cx.now;
        self.host.write(|e, s| e.sync(s));
        let (ed, s) = (&self.host.editor, &self.host.session);
        self.list.reload(ed, s);
        let key = Self::structure(ed, s);
        if self.host.dirty || self.structure_key.as_deref() != Some(&key) {
            self.host.dirty = false;
            self.structure_key = Some(key);
            self.rebuild(cx);
        }
        self.load_text();
    }

    pub fn select_all(&mut self, cx: &mut UiCx) {
        self.host.write(|e, s| e.select_all_layers(s));
        self.sync(cx);
    }

    /// Edit > Delete with the panel focused: removes the selected layers (Swift `editor.deleteSelected()`).
    pub fn delete_selected_layers(&mut self, cx: &mut UiCx) {
        self.host.write(|e, s| e.delete_selected(s));
        self.sync(cx);
    }

    /// The key whose change rebuilds the rows (Swift `GraphicsPanelLogic.structure`).
    pub fn structure(e: &GraphicsEditor, s: &EditorSession) -> String {
        let Some(c) = e.clip(s).filter(|c| c.graphics().is_some()) else {
            let state = GraphicsEmptyState::resolve(s.single_selected_clip());
            return format!("none#{}", state.map(|x| format!("{x:?}")).unwrap_or_default());
        };
        let mut k = c.id.to_string();
        let mut sel: Vec<String> = e.selected_layers(s).iter().map(|i| i.to_string()).collect();
        sel.sort();
        k += &format!("#{}", sel.join(","));
        k += &format!("#{}", e.target_layers(s).iter().map(|l| panel_logic::kind_tag(l)).collect::<Vec<_>>().join(","));
        if let Some(l) = e.selected_layer(s) {
            k += &format!(
                "#{}",
                l.effects.iter().map(|x| format!("{}{}", x.id, x.enabled)).collect::<Vec<_>>().join(",")
            );
        }
        if e.selected_layers(s).is_empty() {
            k += if c.zones.is_none() { "#zonesOff" } else { "#zonesOn" };
        }
        if let Some(l) = e.selected_layer(s) {
            let target = l.follow.as_ref().map_or("-".to_string(), |f| format!("{:?}", f.target));
            let names: Vec<String> = e.follow_candidates(s).iter().map(|c| c.name.clone()).collect();
            k += &format!("#follow:{target}:{}", names.join(","));
        }
        if e.is_drawing() {
            k += "#draw";
        }
        k
    }

    // MARK: Layout

    fn has_clip(&self) -> bool {
        self.host.read(|e, s| e.clip(s).is_some_and(|c| c.graphics().is_some()))
    }

    /// Remembers the list height, the Link Scale switch and the folded sections in `defaults` and takes the stored values now.
    pub fn set_defaults(&mut self, defaults: Box<dyn UiDefaults>) {
        let shared = crate::open_state::SharedUiDefaults::new(defaults);
        self.form.set_defaults(Box::new(shared.clone()));
        let defaults: Box<dyn UiDefaults> = Box::new(shared);
        self.host.scale_linked = defaults.integer(SCALE_LINKED_KEY).is_none_or(|v| v != 0);
        self.list_height = defaults.string(LIST_HEIGHT_KEY).and_then(|t| t.parse::<f64>().ok()).filter(|h| *h > 0.0);
        self.host.defaults = Some(defaults);
    }

    fn clamped_list_height(&self, h: f64) -> f64 {
        let max_h =
            (self.size.height - Self::HEADER_HEIGHT - ControlsGrid::ROW_HEIGHT * 4.0).max(Self::MIN_LIST_HEIGHT);
        h.max(Self::MIN_LIST_HEIGHT).min(max_h)
    }

    pub fn list_height(&self) -> f64 {
        self.clamped_list_height(self.list_height.unwrap_or(Self::DEFAULT_LIST_HEIGHT))
    }

    fn list_frame(&self) -> CGRect {
        CGRect { x: 0.0, y: Self::HEADER_HEIGHT, width: self.size.width, height: self.list_height() }
    }

    fn handle_frame(&self) -> CGRect {
        let l = self.list_frame();
        CGRect { x: 0.0, y: l.max_y() - Self::HANDLE_GRAB / 2.0, width: self.size.width, height: Self::HANDLE_GRAB }
    }

    fn body_frame(&self) -> CGRect {
        if !self.has_clip() {
            return CGRect { x: 0.0, y: 0.0, width: self.size.width, height: self.size.height };
        }
        let y = self.list_frame().max_y() + 1.0;
        CGRect { x: 0.0, y, width: self.size.width, height: (self.size.height - y).max(0.0) }
    }

    fn text_parts(&self) -> Vec<TextPart> {
        if self.text.is_some() { vec![TextPart::Text, TextPart::Arrange, TextPart::Animation] } else { Vec::new() }
    }

    /// Top of each body block in panel coordinates: form, text parts, tail, end.
    fn blocks(&self) -> (f64, Vec<(TextPart, f64)>, f64, f64) {
        let mut y = self.body_frame().y + f64::from(spacing::SM) - self.form_scroll;
        let f = y;
        y += self.form.height();
        let mut parts = Vec::new();
        for p in self.text_parts() {
            parts.push((p, y));
            y += self.text.as_ref().map_or(0.0, |t| t.block.height(&t.model, p));
        }
        let t = y;
        y += self.tail.height();
        (f, parts, t, y + f64::from(spacing::MD))
    }

    fn text_origin(&self, part: TextPart) -> f64 {
        self.blocks().1.iter().find(|x| x.0 == part).map_or(0.0, |x| x.1)
    }

    fn content_height(&self) -> f64 {
        self.blocks().3 + self.form_scroll - self.body_frame().y
    }

    fn max_form_scroll(&self) -> f64 {
        (self.content_height() - self.body_frame().height).max(0.0)
    }

    // MARK: Build

    fn rebuild(&mut self, cx: &mut UiCx) {
        self.form.reset(cx, &mut self.host);
        self.tail.reset(cx, &mut self.host);
        self.form.width = self.size.width;
        self.tail.width = self.size.width;
        if let Some(mut t) = self.text.take() {
            t.block.resign_focus(&mut t.model, cx);
        }
        self.form_scroll = 0.0;
        let (clip, layers, n, selected) = self.host.read(|e, s| {
            (
                e.clip(s).filter(|c| c.graphics().is_some()).cloned(),
                e.target_layers(s).into_iter().cloned().collect::<Vec<_>>(),
                e.selected_layers(s).len(),
                e.selected_layer(s).cloned(),
            )
        });
        let Some(clip) = clip else { return };
        if n == 0 {
            self.build_intro_outro(&clip);
            return;
        }
        self.build_arrange(n);
        self.build_transform();
        if n == 1 {
            self.build_follow();
        }
        if layers.iter().all(|l| !l.is_text()) {
            self.build_shape(&layers);
            self.build_appearance(&layers);
        } else if selected.as_ref().is_some_and(GraphicsLayer::is_text) {
            self.build_text();
        }
        if let Some(l) = selected {
            self.build_effects(&l);
        }
    }

    fn build_intro_outro(&mut self, clip: &sq_core_model::Clip) {
        let id = clip.id;
        let zones_off = |h: &PanelHost| h.read(|e, s| e.clip(s).is_none_or(|c| c.zones.is_none()));
        self.form.begin("Intro and Outro", "introOutro", None, None, None);
        self.form.add(
            Kind::Check {
                title: "Keep intro and outro when trimmed".to_string(),
                state: Rc::new(move |h: &PanelHost| if zones_off(h) { CheckState::Off } else { CheckState::On }),
                toggle: Rc::new(move |h: &mut PanelHost| {
                    let on = zones_off(h);
                    h.session.set_zones_enabled(on, id);
                    h.dirty = true;
                }),
            },
            None,
        );
        if clip.zones.is_some() {
            self.form.add(
                Kind::Segments {
                    title: "Middle".to_string(),
                    labels: vec!["Hold".to_string(), "Stretch".to_string()],
                    selected: Rc::new(|h: &PanelHost| {
                        usize::from(
                            h.read(|e, s| e.clip(s).and_then(|c| c.zones.as_ref().map(|z| z.middle)))
                                == Some(ZoneMiddle::Stretch),
                        )
                    }),
                    enabled: Rc::new(|_, _| true),
                    choose: Rc::new(move |h: &mut PanelHost, i| {
                        h.begin_gesture();
                        let m = if i == 1 { ZoneMiddle::Stretch } else { ZoneMiddle::Hold };
                        h.session.set_zone_middle(m, id);
                    }),
                },
                None,
            );
            let secs = |t: Time| t.value() as f64 / t.timescale() as f64;
            let zone = move |h: &PanelHost, outro: bool| {
                h.read(|e, s| {
                    e.clip(s)
                        .and_then(|c| c.zones.as_ref().map(|z| secs(if outro { z.outro_length } else { z.intro_end })))
                })
            };
            for (title, outro) in [("In", false), ("Out", true)] {
                self.form.numbers(
                    title,
                    "s",
                    None,
                    2,
                    None,
                    None,
                    vec![(
                        Rc::new(move |h: &PanelHost| zone(h, outro)),
                        Rc::new(move |h: &mut PanelHost, v| {
                            let (i, o) = if outro { (None, Some(v)) } else { (Some(v), None) };
                            h.write(|e, s| e.set_zone_lengths(s, i, o));
                        }),
                    )],
                    None,
                    None,
                    &self.host,
                );
            }
        }
        // The fields "Save as Template..." makes from this graphic (read-only here).
        let fields = template_fields::fields(clip);
        if fields.is_empty() {
            return;
        }
        self.form.begin("Template Fields", "templateFields", None, None, None);
        for t in fields {
            self.form.add(Kind::Label { title: t.title, value: t.value }, None);
        }
    }

    fn build_arrange(&mut self, n: usize) {
        use sq_core_graphics::graphics_editing::{GraphicsAlign, GraphicsAxis};
        self.form.begin("Arrange", "arrange", None, None, None);
        let to_frame = n < 2 || self.host.align_to_frame;
        let aligns = [
            (SQIcon::AlignLeft, "Align Left", GraphicsAlign::Left),
            (SQIcon::AlignCenterH, "Align Centers Horizontally", GraphicsAlign::CenterX),
            (SQIcon::AlignRight, "Align Right", GraphicsAlign::Right),
            (SQIcon::AlignTop, "Align Top", GraphicsAlign::Top),
            (SQIcon::AlignCenterV, "Align Centers Vertically", GraphicsAlign::CenterY),
            (SQIcon::AlignBottom, "Align Bottom", GraphicsAlign::Bottom),
        ];
        let mut items: Vec<IconItem<PanelHost>> = aligns
            .into_iter()
            .map(|(icon, title, a)| {
                IconItem::new(icon, title, Rc::new(move |h: &mut PanelHost| h.write(|e, s| e.align(s, a, to_frame))))
            })
            .collect();
        let three = n >= 3;
        for (icon, title, axis) in [
            (SQIcon::DistributeH, "Distribute Horizontally", GraphicsAxis::Horizontal),
            (SQIcon::DistributeV, "Distribute Vertically", GraphicsAxis::Vertical),
        ] {
            let mut it =
                IconItem::new(icon, title, Rc::new(move |h: &mut PanelHost| h.write(|e, s| e.distribute(s, axis))));
            it.enabled = Rc::new(move |_| three);
            items.push(it);
        }
        self.form.add(Kind::Icons { title: None, items }, None);
        self.form.add(
            Kind::Segments {
                title: "Align To".to_string(),
                labels: vec!["Frame".to_string(), "Selection".to_string()],
                selected: Rc::new(move |_| usize::from(!to_frame)),
                enabled: Rc::new(move |_, i| i == 0 || n >= 2),
                choose: Rc::new(|h: &mut PanelHost, i| {
                    h.align_to_frame = i == 0;
                    h.dirty = true;
                }),
            },
            None,
        );
    }

    fn build_transform(&mut self) {
        self.form.begin("Transform", "transform", None, None, None);
        type Field = (crate::graphics::form_draw::Getter<PanelHost>, crate::graphics::form_draw::Setter<PanelHost>);
        let field = |p: Property, axis: usize, k: f64| -> Field {
            let q = p.clone();
            (
                Rc::new(move |h: &PanelHost| h.value(&p, axis, k)),
                Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_value(s, &q, axis, v / k))),
            )
        };
        let keyed =
            |p: Property| -> crate::graphics::form_draw::Flag<PanelHost> { Rc::new(move |h: &PanelHost| h.keyed(&p)) };
        let host = &self.host;
        let f = &mut self.form;
        f.numbers(
            "Position",
            "", // as in the Controls panel: four digits and a unit do not fit the shared field width
            Some(keyed(Property::Position)),
            1,
            None,
            None,
            vec![field(Property::Position, 0, 1.0), field(Property::Position, 1, -1.0)], // Y up, 0,0 = centered
            None,
            None,
            host,
        );
        f.numbers(
            "Anchor",
            "",
            Some(keyed(Property::Anchor)),
            1,
            Some(&[0.0, 0.0]),
            None,
            vec![field(Property::Anchor, 0, 1.0), field(Property::Anchor, 1, -1.0)],
            None,
            None,
            host,
        );
        let scale = |axis: usize| -> Field {
            (
                Rc::new(move |h: &PanelHost| h.value(&Property::Scale, axis, 100.0)),
                Rc::new(move |h: &mut PanelHost, v| {
                    if h.scale_linked {
                        h.write(|e, s| e.set_scale_linked(s, axis, v / 100.0));
                    } else {
                        h.write(|e, s| e.set_value(s, &Property::Scale, axis, v / 100.0));
                    }
                }),
            )
        };
        let mut link = IconItem::new(
            SQIcon::Link,
            "Link Scale",
            Rc::new(|h: &mut PanelHost| {
                h.scale_linked = !h.scale_linked;
                let on = i64::from(h.scale_linked);
                if let Some(d) = h.defaults.as_mut() {
                    d.set_integer(SCALE_LINKED_KEY, on);
                }
            }),
        );
        link.selected = Rc::new(|h: &PanelHost| h.scale_linked);
        link.off_icon = Some(SQIcon::Unlink);
        f.numbers(
            "Scale",
            "%",
            Some(keyed(Property::Scale)),
            1,
            Some(&[100.0, 100.0]),
            None,
            vec![scale(0), scale(1)],
            Some(link),
            None,
            host,
        );
        f.numbers(
            "Rotation",
            "\u{b0}",
            Some(keyed(Property::Rotation)),
            1,
            Some(&[0.0]),
            None,
            vec![field(Property::Rotation, 0, -1.0)], // counterclockwise positive
            None,
            None,
            host,
        );
        f.numbers(
            "Opacity",
            "%",
            Some(keyed(Property::Opacity)),
            1,
            Some(&[100.0]),
            None,
            vec![field(Property::Opacity, 0, 100.0)],
            None,
            None,
            host,
        );
        let modes = BlendMode::ALL.to_vec();
        let (m1, m2) = (modes.clone(), modes.clone());
        f.add(
            Kind::Popup {
                title: "Blend".to_string(),
                titles: modes.iter().map(|m| m.title().to_string()).collect(),
                selected: Rc::new(move |h: &PanelHost| {
                    h.read(|e, s| e.blend_mode(s)).and_then(|b| m1.iter().position(|x| *x == b))
                }),
                enabled: Rc::new(|_| true),
                choose: Rc::new(move |h: &mut PanelHost, i| {
                    if let Some(m) = m2.get(i) {
                        h.write(|e, s| e.set_blend_mode(s, *m));
                    }
                }),
            },
            None,
        );
    }

    fn build_follow(&mut self) {
        self.form.begin("Follow", "follow", None, None, None);
        let (targets, titles, locked, has_follow) = self.host.read(|e, s| {
            let mut t: Vec<Option<FollowTarget>> = vec![None, Some(FollowTarget::Frame)];
            t.extend(e.follow_candidates(s).iter().map(|c| Some(FollowTarget::Layer(c.id))));
            let titles: Vec<String> = t.iter().map(|x| e.follow_title(s, *x)).collect();
            (t, titles, e.selected_layer(s).is_none_or(|l| l.is_locked), e.follow(s).is_some())
        });
        let current = targets.clone();
        self.form.add(
            Kind::Popup {
                title: "Follows".to_string(),
                titles,
                selected: Rc::new(move |h: &PanelHost| {
                    let now = h.read(|e, s| e.follow(s).map(|f| f.target));
                    Some(current.iter().position(|t| *t == now).unwrap_or(0))
                }),
                enabled: Rc::new(move |_| !locked),
                choose: Rc::new(move |h: &mut PanelHost, i| {
                    if let Some(t) = targets.get(i) {
                        h.write(|e, s| e.set_follow_target(s, *t));
                    }
                }),
            },
            None,
        );
        if !has_follow {
            return;
        }
        let edges = [
            (SQIcon::ArrowLeftToLine, "Left Edge", GraphicsEdges::LEFT),
            (SQIcon::ArrowUpFromLine, "Top Edge", GraphicsEdges::TOP),
            (SQIcon::ArrowRightToLine, "Right Edge", GraphicsEdges::RIGHT),
            (SQIcon::ArrowDownToLine, "Bottom Edge", GraphicsEdges::BOTTOM),
        ];
        let items = edges
            .into_iter()
            .map(|(icon, title, edge)| {
                let mut it = IconItem::new(
                    icon,
                    title,
                    Rc::new(move |h: &mut PanelHost| {
                        h.begin_gesture();
                        h.write(|e, s| e.toggle_follow_edge(s, edge));
                    }),
                );
                it.enabled = Rc::new(move |_| !locked);
                it.selected =
                    Rc::new(move |h: &PanelHost| h.read(|e, s| e.follow(s).is_some_and(|f| f.edges.0 & edge.0 != 0)));
                it
            })
            .collect();
        self.form.add(Kind::Icons { title: Some("Edges".to_string()), items }, None);
        let d = GraphicsEditor::DEFAULT_FOLLOW_PADDING;
        let pad = |edge: GraphicsEdges, pick: fn(&sq_core_model::GraphicsEdgePadding) -> f64| {
            use sq_core_graphics::graphics_follow::GraphicsFollowExt;
            (
                Rc::new(move |h: &PanelHost| h.read(|e, s| e.follow(s).map(|f| pick(&f.resolved_padding()))))
                    as crate::graphics::form_draw::Getter<PanelHost>,
                Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_follow_padding(s, v, edge)))
                    as crate::graphics::form_draw::Setter<PanelHost>,
            )
        };
        let (l, r, t, b) = (
            pad(GraphicsEdges::LEFT, |p| p.left),
            pad(GraphicsEdges::RIGHT, |p| p.right),
            pad(GraphicsEdges::TOP, |p| p.top),
            pad(GraphicsEdges::BOTTOM, |p| p.bottom),
        );
        self.form.numbers("Padding L / R", "px", None, 1, Some(&[d, d]), None, vec![l, r], None, None, &self.host);
        self.form.numbers("Padding T / B", "px", None, 1, Some(&[d, d]), None, vec![t, b], None, None, &self.host);
    }

    fn build_shape(&mut self, layers: &[GraphicsLayer]) {
        self.form.begin("Shape", "shape", None, None, None);
        let is_line = layers.iter().all(panel_logic::is_line_like);
        let is_rect = panel_logic::all_rectangles(layers);
        if layers.iter().all(|l| matches!(l.content, GraphicsContent::Shape { .. })) {
            let kinds = vec![ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line, ShapeKind::Arrow];
            let (k1, k2) = (kinds.clone(), kinds.clone());
            self.form.add(
                Kind::Popup {
                    title: "Kind".to_string(),
                    titles: kinds.iter().map(|k| shape_title(*k).to_string()).collect(),
                    selected: Rc::new(move |h: &PanelHost| {
                        h.read(|e, s| e.shape_kind(s)).and_then(|k| k1.iter().position(|x| *x == k))
                    }),
                    enabled: Rc::new(|_| true),
                    choose: Rc::new(move |h: &mut PanelHost, i| {
                        if let Some(k) = k2.get(i) {
                            h.write(|e, s| e.set_shape_kind(s, *k));
                            h.dirty = true;
                        }
                    }),
                },
                None,
            );
        }
        let mut shape_row = |title: &str, key: &'static str| {
            let p = Property::shape(key);
            let def = EffectCatalog::param(ClipEffect::SHAPE_EFFECT_KIND, key).map(|x| x.default_value);
            let q = p.clone();
            self.form.numbers(
                title,
                "px",
                Some(Rc::new(move |h: &PanelHost| h.keyed(&q))),
                0,
                def.as_ref().map(std::slice::from_ref),
                None,
                vec![(
                    Rc::new(move |h: &PanelHost| h.value(&p, 0, 1.0)),
                    Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_shape_value(s, key, v.max(0.0)))),
                )],
                None,
                None,
                &self.host,
            );
        };
        if is_line {
            shape_row("Length", ClipEffect::SHAPE_WIDTH_KEY);
        } else {
            shape_row("Width", ClipEffect::SHAPE_WIDTH_KEY);
            shape_row("Height", ClipEffect::SHAPE_HEIGHT_KEY);
        }
        if is_rect {
            shape_row("Corners", ClipEffect::SHAPE_CORNER_RADIUS_KEY);
        }
    }

    /// Fill, Outline, Shadow: check, color, main value inline; details under the chevron.
    fn build_appearance(&mut self, layers: &[GraphicsLayer]) {
        use crate::graphics::form_draw::{Getter, Setter};
        self.form.begin("Appearance", "appearance", None, None, None);
        let kind = ClipEffect::SHAPE_EFFECT_KIND;
        let shadow = ClipEffect::DROP_SHADOW_KIND;
        let color_of = move |kind: &'static str,
                             key: &'static str|
              -> (
            crate::graphics::form_draw::ColorGetter<PanelHost>,
            crate::graphics::form_draw::ColorSetter<PanelHost>,
        ) {
            (
                Rc::new(move |h: &PanelHost| h.read(|e, s| e.color(s, kind, key))),
                Rc::new(move |h: &mut PanelHost, c| h.write(|e, s| e.set_color(s, kind, key, c))),
            )
        };
        let shape_on = |key: &'static str| -> (
            crate::graphics::form_draw::TriGetter<PanelHost>,
            crate::graphics::form_draw::BoolSetter<PanelHost>,
        ) {
            (
                Rc::new(move |h: &PanelHost| h.read(|e, s| e.shape_value(s, key)).map(|v| v >= 0.5)),
                Rc::new(move |h: &mut PanelHost, on| {
                    h.write(|e, s| e.set_shape_value(s, key, if on { 1.0 } else { 0.0 }))
                }),
            )
        };
        if !layers.iter().all(panel_logic::is_line_like) {
            let key = ClipEffect::SHAPE_FILL_COLOR_KEY;
            let (on, set_on) = shape_on(ClipEffect::SHAPE_FILL_KEY);
            let (color, set_color) = color_of(kind, key);
            self.form.appearance(
                Kind::Appearance {
                    title: "Fill".to_string(),
                    key: "fill".to_string(),
                    on,
                    set_on,
                    color,
                    set_color,
                    has_detail: false,
                },
                Rc::new(move |h: &PanelHost| h.read(|e, s| e.color_alpha(s, kind, key)).map(|a| a * 100.0)),
                Rc::new(move |h: &mut PanelHost, v| {
                    h.write(|e, s| e.set_color_alpha(s, kind, key, v.clamp(0.0, 100.0) / 100.0))
                }),
                "%",
                100.0,
                &self.host,
            );
        }
        let width_p = Property::shape(ClipEffect::SHAPE_STROKE_WIDTH_KEY);
        let stroke_key = ClipEffect::SHAPE_STROKE_COLOR_KEY;
        let (on, set_on) = shape_on(ClipEffect::SHAPE_STROKE_KEY);
        let (color, set_color) = color_of(kind, stroke_key);
        let (w1, w2, w3, w4) = (width_p.clone(), width_p.clone(), width_p.clone(), width_p);
        self.form.appearance(
            Kind::Appearance {
                title: "Outline".to_string(),
                key: "outline".to_string(),
                on,
                set_on,
                color,
                set_color,
                has_detail: true,
            },
            Rc::new(move |h: &PanelHost| h.value(&w1, 0, 1.0)),
            Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_value(s, &w2, 0, v.max(0.0)))),
            "px",
            8.0,
            &self.host,
        );
        let (get, set): (Getter<PanelHost>, Setter<PanelHost>) = (
            Rc::new(move |h: &PanelHost| h.value(&w3, 0, 1.0)),
            Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_value(s, &w4, 0, v.max(0.0)))),
        );
        let w5 = Property::shape(ClipEffect::SHAPE_STROKE_WIDTH_KEY);
        self.form.numbers(
            "Width",
            "px",
            Some(Rc::new(move |h: &PanelHost| h.keyed(&w5))),
            1,
            Some(&[8.0]),
            None,
            vec![(get, set)],
            None,
            Some("outline"),
            &self.host,
        );
        let fx = move |key: &str| Property::Effect { kind: shadow.to_string(), key: key.to_string(), id: None };
        let has_shadow = layers.iter().all(|l| l.effects.iter().any(|e| e.kind == shadow));
        let (color, set_color) = color_of(shadow, ClipEffect::SHADOW_COLOR_KEY);
        let (o1, o2) = (fx(ClipEffect::SHADOW_OPACITY_KEY), fx(ClipEffect::SHADOW_OPACITY_KEY));
        self.form.appearance(
            Kind::Appearance {
                title: "Shadow".to_string(),
                key: "shadow".to_string(),
                on: Rc::new(|h: &PanelHost| h.read(|e, s| e.shadow_state(s))),
                set_on: Rc::new(|h: &mut PanelHost, on| {
                    h.write(|e, s| e.set_shadow(s, on));
                    h.dirty = true;
                }),
                color,
                set_color,
                has_detail: has_shadow,
            },
            Rc::new(move |h: &PanelHost| h.value(&o1, 0, 1.0)),
            Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_value(s, &o2, 0, v.clamp(0.0, 100.0)))),
            "%",
            50.0,
            &self.host,
        );
        if !has_shadow {
            return;
        }
        for (title, key, unit) in [
            ("Opacity", ClipEffect::SHADOW_OPACITY_KEY, "%"),
            ("Angle", ClipEffect::SHADOW_DIRECTION_KEY, "\u{b0}"),
            ("Distance", ClipEffect::SHADOW_DISTANCE_KEY, "px"),
            ("Blur", ClipEffect::SHADOW_SOFTNESS_KEY, "px"),
        ] {
            let (p1, p2, p3) = (fx(key), fx(key), fx(key));
            let spec = EffectCatalog::param(shadow, key);
            let range = spec.as_ref().map(|s| (*s.range.start(), *s.range.end()));
            let def = spec.as_ref().map(|s| s.default_value);
            self.form.numbers(
                title,
                unit,
                Some(Rc::new(move |h: &PanelHost| h.keyed(&p1))),
                0,
                def.as_ref().map(std::slice::from_ref),
                None,
                vec![(
                    Rc::new(move |h: &PanelHost| h.value(&p2, 0, 1.0)),
                    Rc::new(move |h: &mut PanelHost, v| {
                        let v = range.map_or(v, |(lo, hi)| v.clamp(lo, hi));
                        h.write(|e, s| e.set_value(s, &p3, 0, v));
                    }),
                )],
                None,
                Some("shadow"),
                &self.host,
            );
        }
    }

    /// The shared text block drives the layer's text template: the box edits `text`, every other control `style`.
    fn build_text(&mut self) {
        let mut model = match &self.text_model {
            Some(make) => make(),
            None => TextInspectorModel::new(
                TextStyle::default(),
                AnimationSet::new(None, None),
                None,
                Box::new(crate::text::inspector_model::TextBoxDefaults::installed_families),
                TextStyleLibrary::default(),
                Box::new(SequentialIds::default()),
            ),
        };
        model.keystones.clone_from(&self.animation_keystones);
        let mut block = TextBlockDraw::new();
        block.theme = self.theme;
        block.width = self.size.width;
        block.can_sample_screen_color = self.can_sample_screen_color;
        let notices = Rc::clone(&self.notices);
        block.on_notice = Some(Box::new(move |t| notices.borrow_mut().push(t)));
        block.ask_name = Some(self.name_asks.ask());
        model.frame_size = self.text_frame_size();
        self.text = Some(TextHost { block, model });
        self.load_text();
    }

    /// The frame the text model measures in: the displayed format (the active variant), like Swift.
    fn text_frame_size(&self) -> sq_core_time::Vec2 {
        self.host.read(|_, s| crate::ec::animation::AnimationChoices::frame_size(s.display_format().as_ref()))
    }

    /// Loads the template back into the text block unless a gesture is open.
    fn load_text(&mut self) {
        let frame = self.text_frame_size();
        let Some(t) = &mut self.text else { return };
        t.model.frame_size = frame;
        let (tpl, anims, id) =
            self.host.read(|e, s| (e.text_template(s), e.text_animations(s), e.selected_layer(s).map(|l| l.id)));
        let Some(tpl) = tpl else { return };
        t.model.target = id;
        let anims = anims.unwrap_or_else(|| sq_core_model::anchored_animation::AnimationSet::new(None, None));
        if !self.text_gesture_open && (*t.model.style() != tpl.style || *t.model.animations() != anims) {
            t.model.load(tpl.style.clone(), anims);
        }
        if t.block.text != tpl.text {
            t.block.set_text(&tpl.text);
        }
    }

    /// One section per effect on the layer (enable eye, remove button), then Add Effect... and Presets....
    fn build_effects(&mut self, layer: &GraphicsLayer) {
        let appearance_shadow = if layer.is_text() {
            None
        } else {
            layer.effects.iter().find(|e| e.kind == ClipEffect::DROP_SHADOW_KIND).map(|e| e.id)
        };
        for fx in &layer.effects {
            if EffectCatalog::is_generator_owned(&fx.kind) || Some(fx.id) == appearance_shadow {
                continue;
            }
            let Some(spec) = EffectCatalog::spec_for(&fx.kind) else { continue };
            self.build_effect(fx.id, &fx.kind, &spec);
        }
        let f = &mut self.tail;
        f.begin("Effects", "fxAdd", None, None, None);
        f.add(
            Kind::Buttons(vec![
                TextButton {
                    title: "Add Effect\u{2026}".to_string(),
                    action: Rc::new(|h: &mut PanelHost, anchor| {
                        let items: Vec<SQMenuItem> = GraphicsEditor::offered_effects()
                            .into_iter()
                            .map(|spec| {
                                let (q, kind) = (Rc::clone(&h.commands), spec.kind.clone());
                                let mut it = SQMenuItem::new(&spec.title);
                                it.action =
                                    Some(Rc::new(move || q.borrow_mut().push(Command::AddEffect(kind.clone()))));
                                it
                            })
                            .collect();
                        if !items.is_empty() {
                            h.menu = Some((items, anchor));
                        }
                    }),
                },
                TextButton {
                    title: "Presets\u{2026}".to_string(),
                    action: Rc::new(|h: &mut PanelHost, anchor| {
                        let mut items: Vec<SQMenuItem> = h
                            .presets
                            .as_ref()
                            .map(|p| p())
                            .unwrap_or_default()
                            .into_iter()
                            .map(|(name, preset)| {
                                let (q, n) = (Rc::clone(&h.commands), name.clone());
                                let mut it = SQMenuItem::new(&name);
                                it.action = Some(Rc::new(move || {
                                    q.borrow_mut().push(Command::ApplyPreset(n.clone(), Box::new(preset.clone())));
                                }));
                                it
                            })
                            .collect();
                        if !items.is_empty() {
                            items.push(SQMenuItem::separator());
                        }
                        let current = h.read(|e, s| e.layer_effect_preset(s));
                        let mut save = SQMenuItem::new("Save Effects as Preset\u{2026}");
                        save.is_enabled = current.is_some();
                        if let Some(p) = current {
                            let q = Rc::clone(&h.commands);
                            save.action = Some(Rc::new(move || {
                                q.borrow_mut().push(Command::SaveEffectPreset(Box::new(p.clone())))
                            }));
                        }
                        items.push(save);
                        h.menu = Some((items, anchor));
                    }),
                },
            ]),
            None,
        );
    }

    fn build_effect(&mut self, id: Id, kind: &str, spec: &sq_core_model::EffectSpec) {
        let fx_get = move |h: &PanelHost| -> Option<ClipEffect> {
            h.read(|e, s| e.selected_layer(s).and_then(|l| l.effects.iter().find(|x| x.id == id).cloned()))
        };
        let local = |h: &PanelHost| h.read(|e, s| e.local_time(s));
        let f = &mut self.tail;
        f.begin(
            &spec.title,
            &format!("fx.{kind}"),
            Some(Rc::new(move |h: &PanelHost| fx_get(h).is_none_or(|x| x.enabled))),
            Some(Rc::new(move |h: &mut PanelHost, on| {
                h.write(|e, s| e.set_effect_enabled(s, id, on));
                h.dirty = true;
            })),
            Some(Rc::new(move |h: &mut PanelHost| {
                h.write(|e, s| e.remove_effect(s, id));
                h.dirty = true;
            })),
        );
        for p in &spec.params {
            let key = p.key.clone();
            match &p.kind {
                EffectParamKind::Slider => {
                    let prop = EffectProperty::Fx { id, kind: kind.to_string(), key: key.clone() };
                    let pk = Property::Effect { kind: kind.to_string(), key: key.clone(), id: Some(id) };
                    let (default, range) = (p.default_value, p.range.clone());
                    let (k1, k2, pr1, pr2, pr3) = (key.clone(), key.clone(), prop.clone(), prop.clone(), prop.clone());
                    let reset = pr3.display(default, EffectComponent::All, None);
                    f.numbers(
                        &p.title,
                        &p.unit,
                        Some(Rc::new(move |h: &PanelHost| h.keyed(&pk))),
                        p.decimals,
                        Some(&[reset]),
                        None,
                        vec![(
                            Rc::new(move |h: &PanelHost| {
                                let v = fx_get(h).map_or(default, |x| {
                                    x.parameters.get(&k1).map_or(default, |q| q.value_at_local(local(h)))
                                });
                                Some(pr1.display(v, EffectComponent::All, None))
                            }),
                            Rc::new(move |h: &mut PanelHost, v| {
                                let native = pr2
                                    .native_from_display(v, EffectComponent::All, None)
                                    .clamp(*range.start(), *range.end());
                                h.write(|e, s| e.set_effect_value(s, id, &k2, native));
                            }),
                        )],
                        None,
                        None,
                        &self.host,
                    );
                }
                EffectParamKind::Checkbox => {
                    let (k1, k2) = (key.clone(), key.clone());
                    let on = move |h: &PanelHost, k: &str| {
                        fx_get(h).and_then(|x| x.parameters.get(k).map(|q| q.value_at_local(local(h)))).unwrap_or(0.0)
                            >= 0.5
                    };
                    f.add(
                        Kind::Check {
                            title: p.title.clone(),
                            state: Rc::new(
                                move |h: &PanelHost| if on(h, &k1) { CheckState::On } else { CheckState::Off },
                            ),
                            toggle: Rc::new(move |h: &mut PanelHost| {
                                let was = on(h, &k2);
                                h.write(|e, s| e.set_effect_value(s, id, &k2, if was { 0.0 } else { 1.0 }));
                            }),
                        },
                        None,
                    );
                }
                EffectParamKind::Choice(titles) => {
                    let (k1, k2) = (key.clone(), key.clone());
                    f.add(
                        Kind::Popup {
                            title: p.title.clone(),
                            titles: titles.clone(),
                            selected: Rc::new(move |h: &PanelHost| {
                                let v = fx_get(h)
                                    .and_then(|x| x.parameters.get(&k1).map(|q| q.value_at_local(local(h))))
                                    .unwrap_or(0.0);
                                Some(v.round().max(0.0) as usize)
                            }),
                            enabled: Rc::new(|_| true),
                            choose: Rc::new(move |h: &mut PanelHost, i| {
                                h.write(|e, s| e.set_effect_value(s, id, &k2, i as f64))
                            }),
                        },
                        None,
                    );
                }
                EffectParamKind::Color(def) => {
                    let (k1, k2, def) = (key.clone(), key.clone(), *def);
                    f.add(
                        Kind::Color {
                            title: p.title.clone(),
                            get: Rc::new(move |h: &PanelHost| {
                                Some(
                                    fx_get(h)
                                        .and_then(|x| x.colors.get(&k1).map(|q| q.value_at_local(local(h))))
                                        .unwrap_or(def),
                                )
                            }),
                            set: Rc::new(move |h: &mut PanelHost, c| h.write(|e, s| e.set_effect_color(s, id, &k2, c))),
                        },
                        None,
                    );
                }
                EffectParamKind::Point(def) => {
                    let pk = Property::EffectPoint { kind: kind.to_string(), key: key.clone(), id: Some(id) };
                    let prop = EffectProperty::Fx { id, kind: kind.to_string(), key: key.clone() };
                    let sign = |c| prop.display_sign(c);
                    let (sx, sy) = (sign(EffectComponent::X), sign(EffectComponent::Y));
                    let pk2 = pk.clone();
                    let axis = |i: usize, k: f64, k1: String| {
                        let (pk, def) = (pk2.clone(), *def);
                        (
                            Rc::new(move |h: &PanelHost| {
                                let v = fx_get(h)
                                    .and_then(|x| x.points.get(&k1).map(|q| q.value_at_local(local(h))))
                                    .unwrap_or(def);
                                Some((if i == 0 { v.x } else { v.y }) * k + 0.0)
                            }) as crate::graphics::form_draw::Getter<PanelHost>,
                            Rc::new(move |h: &mut PanelHost, v| h.write(|e, s| e.set_value(s, &pk, i, v * k)))
                                as crate::graphics::form_draw::Setter<PanelHost>,
                        )
                    };
                    f.numbers(
                        &p.title,
                        "px",
                        Some(Rc::new(move |h: &PanelHost| h.keyed(&pk))),
                        1,
                        Some(&[def.x * sx + 0.0, def.y * sy + 0.0]),
                        None,
                        vec![axis(0, sx, key.clone()), axis(1, sy, key.clone())],
                        None,
                        None,
                        &self.host,
                    );
                }
            }
        }
    }

    /// Applies what menus and rows queued (an effect to add, a preset to apply); the host calls it once a menu closes.
    pub fn run_commands(&mut self, cx: &mut UiCx) {
        // The text block's popups (Look, Font, Weight, In by, Out by ...) queue their pick in the block; `pump_text` runs it
        // and turns the model's edit into an editor edit. Without this the pick stayed queued and nothing changed.
        self.pump_text();
        let cmds: Vec<Command> = std::mem::take(&mut *self.host.commands.borrow_mut());
        for c in cmds {
            match c {
                Command::AddEffect(kind) => {
                    let r = self.host.write(|e, s| e.add_effects(s, &[kind], None));
                    self.show_drop(r, cx);
                }
                Command::ApplyPreset(name, p) => {
                    let r = self.host.write(|e, s| e.apply_effect_preset(s, &p, &name, None));
                    self.show_drop(r, cx);
                }
                Command::SaveEffectPreset(p) => self.requests.push(PanelRequest::SaveEffectPreset(*p)),
            }
        }
        {
            let s = &mut self.host.session;
            self.list.flush(&mut self.host.editor, s);
        }
        self.sync(cx);
    }

    /// An added effect needs no message (its section appears); a refusal shows for three seconds.
    fn show_drop(&mut self, r: EffectDrop, cx: &mut UiCx) {
        self.sync(cx);
        if let EffectDrop::Refused(why) = r {
            self.show_status(&why);
        }
    }

    fn show_status(&mut self, text: &str) {
        self.status = Some((SQL10n::string(text), self.now + 3.0));
    }

    /// Effects dropped on the panel at `p` (`None`: not over a point): on a layer row they go to that layer, elsewhere to the
    /// one selected layer. True when the panel took the drop (a Graphic is open and the drag carried effects).
    pub fn drop_effects(&mut self, kinds: &[String], p: Option<CGPoint>, cx: &mut UiCx) -> bool {
        if !self.has_clip() || kinds.is_empty() {
            return false;
        }
        if let Some(p) = p.filter(|p| self.region(*p) == Some(Region::List)) {
            let q = self.local(p, Region::List);
            let r = {
                let s = &mut self.host.session;
                self.list.drop_effects(kinds, q, &mut self.host.editor, s)
            };
            if let Some(r) = r {
                self.show_drop(r, cx);
                return true;
            }
        }
        if self.host.read(|e, s| e.selected_layers(s).len()) != 1 {
            self.show_drop(EffectDrop::Refused("Select one layer to add an effect.".to_string()), cx);
            return true;
        }
        let r = self.host.write(|e, s| e.add_effects(s, kinds, None));
        self.show_drop(r, cx);
        true
    }

    /// An Effects drag is over the panel at `p` (`None`: it left): the layer row under it takes the accent tint.
    pub fn effect_drag_over(&mut self, p: Option<CGPoint>) {
        let on_list = p.filter(|p| self.has_clip() && self.region(*p) == Some(Region::List));
        let q = on_list.map(|p| self.local(p, Region::List));
        self.list.effect_drag_over(q);
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, cx: &mut UiCx) {
        self.sync(cx);
        let t = self.theme;
        let fs = f64::from(type_size::BODY);
        c.fill(CGRect { x: 0.0, y: 0.0, width: self.size.width, height: self.size.height }, t.panel());
        let clip = self.host.read(|e, s| e.clip(s).filter(|c| c.graphics().is_some()).cloned());
        let Some(clip) = clip else {
            self.draw_empty(c);
            return;
        };
        c.fill(CGRect { x: 0.0, y: 0.0, width: self.size.width, height: Self::HEADER_HEIGHT }, t.titlebar());
        let save = self.save_template_frame();
        InspectorDraw::button(
            c,
            &SQL10n::string("Save as Template\u{2026}"),
            save,
            self.hover == Some(Region::SaveTemplate),
            self.pressed == Some(Region::SaveTemplate),
            true,
            false,
            ControlsGrid::CONTROL_HEIGHT,
            &t,
        );
        let sm = f64::from(spacing::SM);
        let summary = SQL10n::string(&ClipSectionMode::layer_summary(&clip));
        let sw = c.size_of(&summary, fs, 0).width;
        let name_frame =
            CGRect { x: sm, y: 0.0, width: (save.x - sm * 2.0 - sw - sm).max(0.0), height: Self::HEADER_HEIGHT };
        c.draw_text_in(&clip.name, name_frame, fs, t.label(), TextAlign::Left, 0.0, c.semibold());
        let summary_frame = CGRect { x: save.x - sm - sw, y: 0.0, width: sw, height: Self::HEADER_HEIGHT };
        c.draw_text_in(&summary, summary_frame, fs, t.label3(), TextAlign::Left, 0.0, 0);
        c.fill(CGRect { x: 0.0, y: Self::HEADER_HEIGHT - 1.0, width: self.size.width, height: 1.0 }, t.separator());
        // List.
        let lf = self.list_frame();
        self.list.size = CGSize { width: lf.width, height: lf.height };
        c.save_gstate();
        c.translate_by(0.0, lf.y);
        self.list.draw(c, &self.host.editor, &self.host.session, self.list_focused, cx);
        c.restore_gstate();
        let handle_hot = self.hover == Some(Region::Handle) || self.pressed == Some(Region::Handle);
        c.fill(
            CGRect { x: 0.0, y: lf.max_y(), width: self.size.width, height: 1.0 },
            if handle_hot { t.accent() } else { t.separator() },
        );
        // Body.
        let body = self.body_frame();
        let (form_y, text_y, tail_y, _) = self.blocks();
        c.save_gstate();
        c.clip_to(body);
        self.form.width = self.size.width;
        self.tail.width = self.size.width;
        c.save_gstate();
        c.translate_by(0.0, form_y);
        self.form.draw(c, &self.host, cx);
        c.restore_gstate();
        if let Some(tx) = &mut self.text {
            tx.block.width = self.size.width;
            for (p, y) in text_y {
                c.save_gstate();
                c.translate_by(0.0, y);
                tx.block.draw(&tx.model, c, p, cx, cx.now);
                c.restore_gstate();
            }
        }
        c.save_gstate();
        c.translate_by(0.0, tail_y);
        self.tail.draw(c, &self.host, cx);
        c.restore_gstate();
        c.restore_gstate();
        self.draw_status(c);
    }

    fn save_template_frame(&self) -> CGRect {
        let (w, h) = (132.0, ControlsGrid::CONTROL_HEIGHT);
        CGRect {
            x: self.size.width - f64::from(spacing::SM) - w,
            y: ((Self::HEADER_HEIGHT - h) / 2.0).round(),
            width: w,
            height: h,
        }
    }

    fn empty_state(&self) -> GraphicsEmptyState {
        let s = &self.host.session;
        GraphicsEmptyState::resolve(s.single_selected_clip()).unwrap_or(GraphicsEmptyState::NoGraphic)
    }

    fn make_graphic_blocker(&self) -> Option<&'static str> {
        use sq_core_graphics::graphics_make_graphic::ProjectMakeGraphicExt;
        if self.empty_state() != GraphicsEmptyState::EditedInControls {
            return None;
        }
        let s = &self.host.session;
        s.single_selected_clip().and_then(|c| s.project().make_graphic_blocker(c.id))
    }

    fn empty_button_frame(&self) -> CGRect {
        let (w, h) = (150.0, ControlsGrid::CONTROL_HEIGHT);
        // 12 pt under the hint text as the last draw measured it.
        let y = self.empty_hint_bottom.map_or(self.size.height / 2.0 + 24.0, |b| b + 12.0);
        CGRect { x: ((self.size.width - w) / 2.0).round(), y: y.round(), width: w, height: h }
    }

    fn draw_empty(&mut self, c: &mut Canvas) {
        let (t, state, blocker) = (self.theme, self.empty_state(), self.make_graphic_blocker());
        let hint = blocker.map_or_else(|| SQL10n::string(state.hint()), str::to_string);
        let all = CGRect { x: 0.0, y: 0.0, width: self.size.width, height: self.size.height };
        self.empty_hint_bottom =
            Some(c.draw_empty_state_art(&SQL10n::string(state.title()), &hint, all, 34.0, true, &t));
        let title = if state == GraphicsEmptyState::EditedInControls { "Make Graphic" } else { "New Graphics Clip" };
        InspectorDraw::button(
            c,
            &SQL10n::string(title),
            self.empty_button_frame(),
            self.hover == Some(Region::EmptyAction),
            self.pressed == Some(Region::EmptyAction),
            state != GraphicsEmptyState::EditedInControls || blocker.is_none(),
            false,
            ControlsGrid::CONTROL_HEIGHT,
            &t,
        );
        self.draw_status(c);
    }

    fn draw_status(&self, c: &mut Canvas) {
        let Some((text, until)) = &self.status else { return };
        if self.now >= *until {
            return;
        }
        let h = ControlsGrid::ROW_HEIGHT;
        let r = CGRect { x: 0.0, y: (self.size.height - h).max(0.0), width: self.size.width, height: h };
        c.fill(r, self.theme.panel());
        c.draw_text_in(text, r, f64::from(type_size::BODY), self.theme.label2(), TextAlign::Center, 0.0, 0);
    }

    // MARK: Pointer

    pub fn region(&self, p: CGPoint) -> Option<Region> {
        if !self.has_clip() {
            return self.empty_button_frame().contains(p).then_some(Region::EmptyAction);
        }
        if self.save_template_frame().contains(p) {
            return Some(Region::SaveTemplate);
        }
        if p.y < Self::HEADER_HEIGHT {
            return None;
        }
        if self.handle_frame().contains(p) {
            return Some(Region::Handle);
        }
        if self.list_frame().contains(p) {
            return Some(Region::List);
        }
        if !self.body_frame().contains(p) {
            return None;
        }
        let (form_y, text_y, tail_y, _) = self.blocks();
        if p.y < form_y + self.form.height() {
            return Some(Region::Form);
        }
        for (part, y) in text_y {
            let h = self.text.as_ref().map_or(0.0, |t| t.block.height(&t.model, part));
            if p.y >= y && p.y < y + h {
                return Some(Region::Text(part));
            }
        }
        (p.y >= tail_y && p.y < tail_y + self.tail.height()).then_some(Region::Tail)
    }

    fn local(&self, p: CGPoint, r: Region) -> CGPoint {
        let dy = match r {
            Region::List => self.list_frame().y,
            Region::Form => self.blocks().0,
            Region::Tail => self.blocks().2,
            Region::Text(part) => self.text_origin(part),
            _ => 0.0,
        };
        CGPoint { x: p.x, y: p.y - dy }
    }

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.pressed.is_some() {
            return;
        }
        self.hover = p.and_then(|p| self.region(p));
        let at = |r: Region, s: &Self| if s.hover == Some(r) { p.map(|p| s.local(p, r)) } else { None };
        let (l, f, t) = (at(Region::List, self), at(Region::Form, self), at(Region::Tail, self));
        self.list.mouse_moved(l);
        self.form.mouse_moved(f);
        self.tail.mouse_moved(t);
        for part in self.text_parts() {
            let q = at(Region::Text(part), self);
            if let Some(tx) = &mut self.text {
                tx.block.mouse_moved(&tx.model, q, part, self.now);
            }
        }
    }

    /// Commits every open field outside region `keep`: the form, the tail, the text box and a layer rename.
    fn end_edits_outside(&mut self, keep: Option<Region>, cx: &mut UiCx) {
        if keep != Some(Region::Form) {
            self.form.resign_focus(&mut self.host, cx);
        }
        if keep != Some(Region::Tail) {
            self.tail.resign_focus(&mut self.host, cx);
        }
        if !matches!(keep, Some(Region::Text(_)))
            && let Some(t) = &mut self.text
        {
            t.block.resign_focus(&mut t.model, cx);
        }
        if keep != Some(Region::List) {
            let s = &mut self.host.session;
            self.list.commit_rename(&mut self.host.editor, s);
        }
    }

    /// Commits whatever is open (a menu chord, a press in another panel).
    pub fn end_text_edits(&mut self, cx: &mut UiCx) {
        self.end_edits_outside(None, cx);
        self.pump(cx);
    }

    pub fn mouse_down(&mut self, p: CGPoint, modifiers: InputModifiers, click_count: Option<i64>, cx: &mut UiCx) {
        self.now = cx.now;
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let r = self.region(p);
        self.pressed = r;
        self.list_focused = r == Some(Region::List);
        self.end_edits_outside(r, cx);
        let Some(r) = r else { return };
        let q = self.local(p, r);
        match r {
            Region::List => {
                let s = &mut self.host.session;
                self.list.mouse_down(q, modifiers, Some(n), &mut self.host.editor, s, cx);
            }
            Region::Handle => self.handle_start = Some((p.y, self.list_height())),
            Region::Form => self.form.mouse_down(q, Some(n), &mut self.host, cx),
            Region::Tail => self.tail.mouse_down(q, Some(n), &mut self.host, cx),
            Region::Text(part) => {
                if modifiers.contains(InputModifiers::SECONDARY) {
                    self.pressed = None;
                    if let Some(tx) = &self.text {
                        let items = tx.block.look_context_items(&tx.model);
                        let anchor = CGRect { x: p.x, y: p.y, width: 1.0, height: 1.0 };
                        if !items.is_empty() {
                            self.requests.push(PanelRequest::Menu { items, anchor });
                        }
                    }
                    return;
                }
                if let Some(tx) = &mut self.text {
                    tx.block.mouse_down(&mut tx.model, q, part, Some(n), None, cx);
                }
            }
            _ => {}
        }
        self.pump(cx);
    }

    /// Whether the layer drag in progress will copy (Alt was held on the last move).
    pub fn is_copying_layer(&self) -> bool {
        self.list.is_copying()
    }

    pub fn mouse_dragged(&mut self, p: CGPoint, modifiers: InputModifiers, cx: &mut UiCx) {
        let Some(r) = self.pressed else { return };
        let q = self.local(p, r);
        match r {
            Region::List => {
                let s = &self.host.session;
                self.list.mouse_dragged(q, modifiers, &self.host.editor, s);
            }
            Region::Handle => {
                if let Some((y, h)) = self.handle_start {
                    let height = self.clamped_list_height(h + p.y - y);
                    self.list_height = Some(height);
                    if let Some(d) = self.host.defaults.as_mut() {
                        d.set_string(LIST_HEIGHT_KEY, &height.to_string());
                    }
                }
            }
            Region::Form => self.form.mouse_dragged(q, modifiers, 1.0, &mut self.host, cx),
            Region::Tail => self.tail.mouse_dragged(q, modifiers, 1.0, &mut self.host, cx),
            Region::Text(_) => {
                if let Some(tx) = &mut self.text {
                    tx.block.mouse_dragged(&mut tx.model, q, modifiers, None, cx);
                }
            }
            _ => {}
        }
        self.pump(cx);
    }

    pub fn mouse_up(&mut self, p: CGPoint, modifiers: InputModifiers, cx: &mut UiCx) {
        let r = self.pressed.take();
        self.handle_start = None;
        if let Some(r) = r {
            let q = self.local(p, r);
            match r {
                Region::List => {
                    let s = &mut self.host.session;
                    self.list.mouse_up(q, modifiers, &mut self.host.editor, s);
                }
                Region::Form => self.form.mouse_up(q, &mut self.host, cx),
                Region::Tail => self.tail.mouse_up(q, &mut self.host, cx),
                Region::Text(part) => {
                    if let Some(tx) = &mut self.text {
                        tx.block.mouse_up(&mut tx.model, q, part, cx);
                    }
                }
                Region::SaveTemplate => {
                    if self.region(p) == Some(r) {
                        self.requests.push(PanelRequest::SaveTemplate);
                    }
                }
                Region::EmptyAction => {
                    if self.region(p) == Some(r) {
                        if self.empty_state() == GraphicsEmptyState::EditedInControls {
                            if self.make_graphic_blocker().is_none() {
                                self.requests.push(PanelRequest::MakeGraphic);
                            }
                        } else {
                            self.host.write(|e, s| e.new_graphics_clip(s));
                        }
                    }
                }
                Region::Handle => {}
            }
        }
        self.pump(cx);
        self.mouse_moved(Some(p));
    }

    /// Wheel: scrolls the list or the property rows (a hovered number field takes it first).
    pub fn scroll(&mut self, p: CGPoint, dy: f64, precise: bool, modifiers: InputModifiers, cx: &mut UiCx) {
        let Some(r) = self.region(p) else { return };
        let q = self.local(p, r);
        match r {
            Region::List => self.list.scroll(dy),
            Region::Form if self.form.scroll(q, dy, precise, modifiers, &mut self.host, cx) => {}
            Region::Tail if self.tail.scroll(q, dy, precise, modifiers, &mut self.host, cx) => {}
            Region::Form | Region::Tail | Region::Text(_) => {
                self.form_scroll = (self.form_scroll - dy).clamp(0.0, self.max_form_scroll());
            }
            _ => {}
        }
        self.pump(cx);
    }

    /// Keys: an open rename, text or field edit first; then Delete removes the selected layers, Return renames the selected
    /// layer (a text layer: its text in the text box), Command-A selects every layer.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> bool {
        let handled = self.key_inner(k, modifiers, cx);
        self.pump(cx);
        handled
    }

    fn key_inner(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> bool {
        {
            let s = &mut self.host.session;
            if self.list.key(k, modifiers, &mut self.host.editor, s, cx) {
                return true;
            }
        }
        if let Some(tx) = &mut self.text
            && tx.block.key(&mut tx.model, k, modifiers, cx)
        {
            return true;
        }
        if self.form.key(k, modifiers, &mut self.host, cx) || self.tail.key(k, modifiers, &mut self.host, cx) {
            return true;
        }
        if !self.has_clip() {
            return false;
        }
        let plain = !modifiers.contains(InputModifiers::COMMAND) && !modifiers.contains(InputModifiers::OPTION);
        match k {
            InputKey::Delete | InputKey::Backspace => {
                if !plain || self.host.read(|e, s| e.selected_layers(s).is_empty()) {
                    return false;
                }
                self.host.write(|e, s| e.delete_selected(s));
                true
            }
            InputKey::Enter if plain && !modifiers.contains(InputModifiers::SHIFT) => {
                // A text layer puts the caret in its text box, any other single layer or group renames its row.
                if self.host.read(|e, s| e.selected_layers(s).len()) != 1 {
                    return false;
                }
                let is_text = self.host.read(|e, s| e.selected_layer(s).is_some_and(GraphicsLayer::is_text));
                if is_text && let Some(tx) = &mut self.text {
                    return tx.block.focus_text_box(&mut tx.model, cx);
                }
                self.list.begin_rename_selected(&self.host.editor, &self.host.session)
            }
            InputKey::Character('a') if modifiers.contains(InputModifiers::COMMAND) => {
                self.host.write(|e, s| e.select_all_layers(s));
                true
            }
            _ => false,
        }
    }

    pub fn tick(&mut self, cx: &mut UiCx) {
        self.now = cx.now;
        self.form.tick(&mut self.host, cx.now);
        self.tail.tick(&mut self.host, cx.now);
        if let Some(tx) = &mut self.text {
            tx.block.tick(&mut tx.model, cx.now);
        }
        self.pump(cx);
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        let r = self.region(p)?;
        let q = self.local(p, r);
        match r {
            Region::List => self.list.help(q),
            Region::Form => self.form.help(q),
            Region::Tail => self.tail.help(q),
            Region::Text(part) => self.text.as_ref().and_then(|t| t.block.help(&t.model, q, part)),
            Region::Handle => Some(SQL10n::string("Drag to resize the layer list")),
            _ => None,
        }
    }

    /// A color the picker chose (`None`: the session ended).
    pub fn color_changed(&mut self, target: ColorTarget, color: Option<EffectColor>, cx: &mut UiCx) {
        match target {
            ColorTarget::Form(row) => self.form.change_color(row, color, &mut self.host),
            ColorTarget::Tail(row) => self.tail.change_color(row, color, &mut self.host),
            ColorTarget::Text(control) => {
                if let Some(tx) = &mut self.text {
                    tx.block.color_changed(&mut tx.model, &control, color);
                }
            }
        }
        self.pump(cx);
    }

    /// The text eyedropper answered (`None`: canceled).
    pub fn color_sampled(
        &mut self,
        layer: crate::text::block_draw::Layer,
        picked: Option<sq_uikit::sqcolor_value::SQColorValue>,
        cx: &mut UiCx,
    ) {
        if let Some(tx) = &mut self.text {
            tx.block.color_sampled(&mut tx.model, layer, picked);
        }
        self.pump(cx);
    }

    /// After every input: popups chosen, queued commands, the text block's edits, the forms' menus and color requests, the
    /// list's menu and selection change; then the rows follow the structure.
    fn pump(&mut self, cx: &mut UiCx) {
        self.form.flush(&mut self.host);
        self.tail.flush(&mut self.host);
        self.pump_text();
        let offsets = (self.blocks().0, self.blocks().2);
        if let Some(m) = self.form.take_menu() {
            self.requests.push(PanelRequest::Menu { items: m.items, anchor: shift(m.anchor, offsets.0) });
        }
        if let Some(m) = self.tail.take_menu() {
            self.requests.push(PanelRequest::Menu { items: m.items, anchor: shift(m.anchor, offsets.1) });
        }
        if let Some((items, anchor)) = self.host.menu.take() {
            self.requests.push(PanelRequest::Menu { items, anchor: shift(anchor, offsets.1) });
        }
        if let Some(r) = self.form.take_color_request() {
            self.requests.push(PanelRequest::PickColor {
                current: r.current,
                anchor: shift(r.anchor, offsets.0),
                target: ColorTarget::Form(r.row),
            });
        }
        if let Some(r) = self.tail.take_color_request() {
            self.requests.push(PanelRequest::PickColor {
                current: r.current,
                anchor: shift(r.anchor, offsets.1),
                target: ColorTarget::Tail(r.row),
            });
        }
        if let Some(m) = self.list.take_menu() {
            self.requests.push(PanelRequest::Menu { items: m.items, anchor: shift(m.anchor, Self::HEADER_HEIGHT) });
        }
        self.requests.extend(self.list.take_edit_text().map(PanelRequest::EditText));
        self.list.take_changed();
        if self.form.take_height_changed() | self.tail.take_height_changed() {
            self.form_scroll = self.form_scroll.min(self.max_form_scroll());
        }
        self.sync(cx);
    }

    /// The text model's style and animation edits and the block's typing become editor edits (Swift `wireText`).
    fn pump_text(&mut self) {
        let notices: Vec<String> = self.notices.borrow_mut().drain(..).collect();
        self.requests.extend(notices.into_iter().map(PanelRequest::Notice));
        self.requests.extend(self.name_asks.take().into_iter().map(PanelRequest::AskName));
        let Some(tx) = &mut self.text else { return };
        tx.block.run_menu_commands(&mut tx.model);
        let events = tx.model.take_events();
        let reqs = tx.block.take_requests();
        let part_of = |p: TextPart, s: &Self| s.text_origin(p);
        for e in events {
            match e {
                TextInspectorEvent::BeginEditing => {
                    self.text_gesture_open = true;
                    self.host.begin_gesture();
                }
                TextInspectorEvent::EndEditing => self.text_gesture_open = false,
                TextInspectorEvent::Change(style, anims, _) => {
                    let (style, anims) = (*style, *anims);
                    let changed = self.host.read(|e, s| e.text_animations(s)) != Some(anims.clone());
                    self.host.write(|e, s| {
                        if changed {
                            e.update_text(s, "Text Animation", Some(&anims), |t| t.style = style);
                        } else {
                            e.update_text(s, "Text Style", None, |t| t.style = style);
                        }
                    });
                }
                TextInspectorEvent::StylesChanged(library) => self.requests.push(PanelRequest::StylesChanged(library)),
                TextInspectorEvent::AlignToFrame(_) | TextInspectorEvent::PresetsChanged(_) => {}
            }
        }
        for r in reqs {
            match r {
                BlockRequest::TextBegin => self.host.begin_gesture(),
                BlockRequest::TextEnd => {}
                BlockRequest::TextChange(s) => {
                    self.host.write(|e, ss| e.update_text(ss, "Edit Text", None, |t| t.text = s));
                }
                BlockRequest::Menu { items, anchor, part } => {
                    let dy = part_of(part, self);
                    self.requests.push(PanelRequest::Menu { items, anchor: shift(anchor, dy) });
                }
                BlockRequest::PickColor { control, current, anchor, part } => {
                    let dy = part_of(part, self);
                    self.requests.push(PanelRequest::PickColor {
                        current,
                        anchor: shift(anchor, dy),
                        target: ColorTarget::Text(control),
                    });
                }
                BlockRequest::SampleColor(l) => self.requests.push(PanelRequest::SampleColor(l)),
            }
        }
    }
}

fn shift(r: CGRect, dy: f64) -> CGRect {
    CGRect { x: r.x, y: r.y + dy, width: r.width, height: r.height }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics::editor_tests::with_three_shapes;
    use crate::text::animator_choices::Control as AnimatorControl;
    use crate::text::inspector_model::AnimatorSide;
    use std::collections::BTreeSet;

    fn panel() -> (GraphicsPanelDraw, UiCx) {
        let (s, e) = with_three_shapes();
        let mut p = GraphicsPanelDraw::new(e, s);
        let mut cx = UiCx::new();
        p.sync(&mut cx);
        (p, cx)
    }

    fn titles(f: &GraphicsFormDraw<PanelHost>) -> Vec<String> {
        f.rows()
            .iter()
            .filter_map(|r| match &*r.kind {
                Kind::Section { title, .. } => Some(title.clone()),
                _ => None,
            })
            .collect()
    }

    /// A pick in a popup of the text block (In by, Look, Font ...) queues in the block; `run_commands`, which the host calls
    /// once a menu row ran, must apply it. It stayed queued: the popup closed and the row kept its value.
    #[test]
    fn a_text_block_popup_pick_applies_when_the_host_runs_the_commands() {
        let (mut p, mut cx) = panel();
        p.host.write(|e, s| e.add_text(s, "Hello"));
        p.sync(&mut cx);
        let intro = |p: &GraphicsPanelDraw| p.host.read(|e, s| e.text_animations(s)).and_then(|a| a.animation_in);
        assert!(intro(&p).is_none(), "no intro before the pick");
        let items = {
            let tx = p.text.as_ref().expect("a text layer shows the text block");
            tx.block
                .menu_for(&tx.model, &Control::Animator(AnimatorSide::In, AnimatorControl::Effect))
                .expect("the In by popup")
        };
        let row = items.iter().find(|i| i.title == "Typewriter").expect("a Typewriter row");
        (row.action.as_ref().expect("the row runs something"))();
        p.run_commands(&mut cx);
        assert!(intro(&p).is_some(), "Typewriter is the layer's intro");
    }

    /// Graphics > Look "+" > Save as New Look: the model keeps the new Look in memory only, so the panel must hand the
    /// library to the host (the Look store). It was dropped here, so the Look was gone after a restart.
    #[test]
    fn saving_a_look_in_the_text_block_asks_the_host_to_store_the_looks() {
        let (mut p, mut cx) = panel();
        p.host.write(|e, s| e.add_text(s, "Hello"));
        p.sync(&mut cx);
        let save = {
            let tx = p.text.as_ref().expect("a text layer shows the text block");
            let items = tx.block.look_context_items(&tx.model);
            items.into_iter().find(|i| i.title.starts_with("Save as New Look")).expect("the Save as New Look row")
        };
        (save.action.as_ref().expect("the row runs something"))();
        p.run_commands(&mut cx); // runs the row: the block asks for a name
        p.run_commands(&mut cx); // the next pump hands the ask on
        let ask = p
            .take_requests()
            .into_iter()
            .find_map(|r| if let PanelRequest::AskName(a) = r { Some(a) } else { None })
            .expect("the block asks for a name");
        (ask.done)(Some("MyLook2".to_string()));
        p.run_commands(&mut cx);
        let library = p
            .take_requests()
            .into_iter()
            .find_map(|r| if let PanelRequest::StylesChanged(l) = r { Some(l) } else { None })
            .expect("the saved Look goes to the host");
        let names: Vec<String> = library.user().into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["MyLook2"]);
    }

    #[test]
    fn the_text_frame_is_the_displayed_variant_not_the_canvas() {
        let (mut p, _) = panel();
        let canvas = p.host.read(|e, s| e.canvas(s));
        assert_eq!(p.text_frame_size(), canvas);
        p.host.write(|_, s| {
            let id = s.add_variant("Vertical", 1080, 1920, sq_core_model::ConformMode::Fit);
            s.set_active_variant(id);
        });
        assert_eq!(p.text_frame_size(), sq_core_time::Vec2::new(1080.0, 1920.0));
    }

    #[test]
    fn one_selected_shape_builds_the_sections_and_the_effects_tail() {
        let (p, _) = panel();
        assert_eq!(titles(&p.form), ["Arrange", "Transform", "Follow", "Shape", "Appearance"]);
        assert_eq!(titles(&p.tail), ["Effects"]);
        assert!(p.has_clip() && p.form.height() > 0.0);
    }

    #[test]
    fn no_selection_shows_intro_and_outro_and_a_selection_change_rebuilds() {
        let (mut p, mut cx) = panel();
        let key = p.structure_key().map(str::to_string);
        p.host.write(|e, s| e.select(s, BTreeSet::new()));
        p.sync(&mut cx);
        assert_eq!(titles(&p.form), ["Intro and Outro"]);
        assert_ne!(p.structure_key().map(str::to_string), key);
        p.select_all(&mut cx);
        // Several layers: no Follow section (it needs exactly one).
        assert_eq!(titles(&p.form), ["Arrange", "Transform", "Shape", "Appearance"]);
    }

    #[test]
    fn a_lent_session_is_edited_and_handed_back() {
        let (lent, e) = with_three_shapes();
        let (stand_in, _) = with_three_shapes();
        let mut lent = lent;
        let mut p = GraphicsPanelDraw::new(e, stand_in);
        let mut cx = UiCx::new();
        p.with_session(&mut lent, |p| {
            p.sync(&mut cx);
            p.host.begin_gesture();
            p.host.write(|e, s| e.set_blend_mode(s, BlendMode::ALL[3]));
        });
        assert_eq!(p.with_session(&mut lent, |p| p.host.read(|e, s| e.blend_mode(s))), Some(BlendMode::ALL[3]));
    }

    #[test]
    fn a_popup_row_writes_through_the_editor_and_reads_back() {
        let (mut p, mut cx) = panel();
        let kind = p.form.rows().iter().find_map(|r| match &*r.kind {
            Kind::Popup { title, .. } if title == "Blend" => Some(Rc::clone(&r.kind)),
            _ => None,
        });
        let Some(kind) = kind else { panic!("blend row") };
        let Kind::Popup { titles, selected, choose, .. } = &*kind else { panic!("popup") };
        assert_eq!(titles.len(), BlendMode::ALL.len());
        choose(&mut p.host, 3);
        assert_eq!(selected(&p.host), Some(3));
        p.sync(&mut cx);
        assert_eq!(p.host.read(|e, s| e.blend_mode(s)), Some(BlendMode::ALL[3]));
    }

    #[test]
    fn the_regions_follow_the_layout_and_the_list_handle_resizes() {
        let (mut p, mut cx) = panel();
        let lf = p.list_frame();
        assert_eq!(p.region(CGPoint { x: 10.0, y: 5.0 }), None);
        assert_eq!(p.region(CGPoint { x: 10.0, y: lf.y + 10.0 }), Some(Region::List));
        assert_eq!(p.region(CGPoint { x: 10.0, y: lf.max_y() }), Some(Region::Handle));
        assert_eq!(p.region(CGPoint { x: 10.0, y: lf.max_y() + 20.0 }), Some(Region::Form));
        let before = p.list_height();
        let grab = CGPoint { x: 10.0, y: lf.max_y() };
        p.mouse_down(grab, InputModifiers::default(), Some(1), &mut cx);
        p.mouse_dragged(CGPoint { x: 10.0, y: grab.y + 40.0 }, InputModifiers::default(), &mut cx);
        p.mouse_up(CGPoint { x: 10.0, y: grab.y + 40.0 }, InputModifiers::default(), &mut cx);
        assert!(p.list_height() > before);
        let grab = CGPoint { x: 10.0, y: p.list_frame().max_y() };
        p.mouse_down(grab, InputModifiers::default(), Some(1), &mut cx);
        p.mouse_dragged(CGPoint { x: 10.0, y: -1000.0 }, InputModifiers::default(), &mut cx);
        assert_eq!(p.list_height(), GraphicsPanelDraw::MIN_LIST_HEIGHT);
    }

    #[test]
    fn an_effect_drop_needs_one_layer_and_a_refusal_shows_for_three_seconds() {
        let (mut p, mut cx) = panel();
        p.select_all(&mut cx);
        assert!(p.drop_effects(&["gaussianBlur".to_string()], None, &mut cx));
        assert_eq!(p.status(), Some("Select one layer to add an effect."));
        cx.now = 10.0;
        p.now = 10.0;
        p.host.write(|e, s| {
            let first = e.document(s).and_then(|d| d.layers.first()).map(|l| l.id);
            e.select(s, first.into_iter().collect());
        });
        assert!(p.drop_effects(&["gaussianBlur".to_string()], None, &mut cx));
        let fx = p.host.read(|e, s| e.selected_layer(s).map_or(0, |l| l.effects.len()));
        assert!(fx >= 1);
        assert!(titles(&p.tail).len() >= 2, "the new effect has its own section");
    }

    #[test]
    fn follow_and_the_add_effect_list_come_from_the_editor() {
        let (mut p, mut cx) = panel();
        let target = p.host.read(|e, s| e.follow_candidates(s).first().map(|l| l.id)).expect("a candidate");
        p.host.write(|e, s| e.set_follow_target(s, Some(FollowTarget::Layer(target))));
        p.sync(&mut cx);
        assert!(p.host.read(|e, s| e.follow(s).is_some()));
        assert!(p.form.rows().iter().any(|r| matches!(&*r.kind, Kind::Icons { title: Some(t), .. } if t == "Edges")));
        let offered = GraphicsEditor::offered_effects();
        assert!(
            !offered.is_empty() && offered.windows(2).all(|w| w[0].title.to_lowercase() <= w[1].title.to_lowercase())
        );
        p.host.write(|e, s| e.set_follow_target(s, None));
        assert!(p.host.read(|e, s| e.follow(s).is_none()));
    }

    #[test]
    fn a_layer_preset_round_trips_with_fresh_ids() {
        let (mut p, mut cx) = panel();
        assert!(p.host.read(|e, s| e.layer_effect_preset(s)).is_none());
        p.host.write(|e, s| e.add_effects(s, &["gaussianBlur".to_string()], None));
        let preset = p.host.read(|e, s| e.layer_effect_preset(s)).expect("preset");
        let r = p.host.write(|e, s| e.apply_effect_preset(s, &preset, "Soft", None));
        assert_eq!(r, EffectDrop::Added);
        p.sync(&mut cx);
        let ids: Vec<Id> = p.host.read(|e, s| {
            e.selected_layer(s)
                .map(|l| l.effects.iter().filter(|x| x.kind == "gaussianBlur").map(|x| x.id).collect())
                .unwrap_or_default()
        });
        assert_eq!(ids.len(), 2);
        assert_ne!(ids[0], ids[1]);
    }

    #[test]
    fn the_empty_state_names_the_selection() {
        let s = crate::graphics::editor_tests::session();
        let p = GraphicsPanelDraw::new(crate::graphics::editor_tests::editor(), s);
        assert!(!p.has_clip());
        assert_eq!(p.empty_state(), GraphicsEmptyState::NoGraphic);
        assert_eq!(
            p.region({
                let f = p.empty_button_frame();
                CGPoint { x: f.x + f.width / 2.0, y: f.y + f.height / 2.0 }
            }),
            Some(Region::EmptyAction)
        );
    }
}
