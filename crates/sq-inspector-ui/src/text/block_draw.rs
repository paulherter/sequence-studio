// Swift: Draw/TextBlockDraw.swift
//! The text clip's block of Controls on the shared toolkit: `TextBlockView` (context `.clip`) translated. Three parts,
//! each with its own coordinates (points, y down, (0, 0) = the part's top-left), placed by the host like the Mac
//! skeleton: `Text` (box, font, size, style toggles, alignment, spacing, Look and the Appearance rows with their detail
//! rows) leads Controls, `Arrange` (align to frame) closes Transform, `Animation` (Intro / Outro) follows Transform.
//! The model is `TextInspectorModel`; the Swift class held it, here every call that reads or edits takes it.
//
// The open state of the sections and layers is remembered in the injected settings store (`set_defaults`).

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use crate::open_state::{read_open, write_open};
use sq_core_graphics::custom_animation::AnimationSide;
use sq_core_model::EffectColor;
use sq_core_model::anchored_animation::{
    SegmentShape, TextAnimatorEffect, TextAnimatorOrder, TextAnimatorUnit, TextSlideDirection,
};
use sq_draw::inspector::inspector_controls::CheckState;
use sq_draw::inspector::inspector_controls::{Direction, InspectorDraw, InspectorTokens};
use sq_draw::inspector::scrub_field_control::ClickCounter;
use sq_draw::inspector::scrub_field_control::{Event as ScrubEvent, ScrubFieldControl};
use sq_draw::inspector::text_edit_state::{Outcome, TextEditState};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_text::caption_style_looks::LookGroup;
use sq_text::font_resolver::Axis;
use sq_text::text_align_to_frame::FrameAlignment;
use sq_text::text_style::{
    FontWeight, RGBAColor, StrokePosition, TextAlignment, TextDirection, TextFootageFill, TextListKind,
    TextVerticalAlignment,
};
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqcolor_value::SQColorValue;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::color::look_gallery_draw::LookGalleryDraw;
use crate::ec::animation::AnimationChoices;
use crate::text::animator_choices::{Control as AnimatorControl, TextAnimatorChoices};
use crate::text::inspector_model::{AnimatorSide, TextInspectorModel, TokenField};

/// The three places the host puts the block.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    Text,
    /// The Captions Style rows of the kit: Font, Fill, Outline, Background and Shadow as switch rows, then the dense
    /// text block folded under "More Text Options".
    KitLook,
    Arrange,
    Animation,
}

/// Adds one row: label, icon, level, tip, controls, height.
type AddRow<'a> =
    dyn FnMut(Option<String>, Option<SQIcon>, usize, Option<String>, Vec<(Control, CGRect)>, Option<f64>) + 'a;

/// What the Look popup lists and does (`TextBlockView.LookSource`).
pub struct LookSource {
    pub titles: Vec<String>,
    pub ids: Vec<String>,
    pub selected: Option<String>,
    pub pick: Box<dyn FnMut(&str)>,
    pub add: Option<Box<dyn FnMut()>>,
}

/// The applied look as the Look rows show it (`TextBlockView.LookStatus`).
#[derive(Clone, Debug, PartialEq)]
pub struct LookStatus {
    pub name: String,
    pub edited: bool,
    pub can_update: bool,
}

/// The Appearance rows, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Layer {
    Fill,
    Gradient,
    Outline,
    Background,
    Shadow,
    Second,
    AutoFit,
    List,
}

impl Layer {
    pub const ALL: [Layer; 8] = [
        Layer::Fill,
        Layer::Gradient,
        Layer::Outline,
        Layer::Background,
        Layer::Shadow,
        Layer::Second,
        Layer::AutoFit,
        Layer::List,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Layer::Fill => "Fill",
            Layer::Gradient => "Gradient",
            Layer::Outline => "Outline",
            Layer::Background => "Background",
            Layer::Shadow => "Shadow",
            Layer::Second => "Second Line",
            Layer::AutoFit => "Shrink to Box",
            Layer::List => "List",
        }
    }

    /// The Swift raw value (the defaults key suffix).
    pub fn raw(self) -> &'static str {
        match self {
            Layer::Fill => "fill",
            Layer::Gradient => "gradient",
            Layer::Outline => "outline",
            Layer::Background => "background",
            Layer::Shadow => "shadow",
            Layer::Second => "second",
            Layer::AutoFit => "autofit",
            Layer::List => "list",
        }
    }

    pub fn has_well(self) -> bool {
        !matches!(self, Layer::Second | Layer::AutoFit | Layer::List)
    }

    pub fn has_detail(self) -> bool {
        self != Layer::AutoFit
    }
}

/// A numeric field of the block.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Field {
    Size,
    Tracking,
    Leading,
    FillValue,
    OutlineValue,
    BackgroundValue,
    ShadowValue,
    FillOpacity,
    StrokeWidth,
    BoxOpacity,
    PadX,
    PadY,
    Radius,
    ShadowOpacity,
    ShadowAngle,
    ShadowDistance,
    ShadowSize,
    ShadowBlur,
    GradientAngle,
    SecondSize,
    InLength,
    OutLength,
    /// A numeric field of a text animator side (stagger, length, distance, blur, loops).
    Animator(AnimatorSide, AnimatorControl),
    /// A variation axis of the style's font, by its tag.
    Axis(String),
}

impl Field {
    const ANIMATOR_FIELDS: [AnimatorControl; 5] = [
        AnimatorControl::Stagger,
        AnimatorControl::Length,
        AnimatorControl::Distance,
        AnimatorControl::Blur,
        AnimatorControl::Loops,
    ];

    /// Every field but the font axes (those exist only for the style's own font).
    pub fn all() -> Vec<Field> {
        let mut v = vec![
            Field::Size,
            Field::Tracking,
            Field::Leading,
            Field::FillValue,
            Field::OutlineValue,
            Field::BackgroundValue,
            Field::ShadowValue,
            Field::FillOpacity,
            Field::StrokeWidth,
            Field::BoxOpacity,
            Field::PadX,
            Field::PadY,
            Field::Radius,
            Field::ShadowOpacity,
            Field::ShadowAngle,
            Field::ShadowDistance,
            Field::ShadowSize,
            Field::ShadowBlur,
            Field::GradientAngle,
            Field::SecondSize,
            Field::InLength,
            Field::OutLength,
        ];
        for side in [AnimatorSide::In, AnimatorSide::Out] {
            v.extend(Self::ANIMATOR_FIELDS.iter().map(|&k| Field::Animator(side, k)));
        }
        v
    }
}

/// A row of toggle buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Group {
    Style,
    Align,
    Vertical,
    Direction,
    Frame,
    FillMode,
    StrokePosition,
    SecondItalic,
}

/// What can be hovered, pressed or focused.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    TextHeader,
    AnimationHeader,
    TextBox,
    Font,
    Weight,
    Look,
    /// A named style tile of the Style row (an index into [`TextBlockDraw::style_tiles`]).
    StyleTile(usize),
    LookAdd,
    LookUpdate,
    LookSaveNew,
    Button(Group, usize),
    Check(Layer),
    /// Inline unit or caption text of a kit row ("px", "corner", "Off"); never hit.
    Unit(&'static str),
    Well(Layer),
    Chevron(Layer),
    /// The eyedropper after a row's value (fill, outline, background, shadow).
    Eyedropper(Layer),
    GradientEnd,
    SecondWell,
    SecondFont,
    SecondWeight,
    ListKind,
    Intro,
    Outro,
    /// A popup of a text animator side (effect, unit, easing, direction, order).
    Animator(AnimatorSide, AnimatorControl),
    Field(Field),
    /// A kit token popup ("Literal" releases the field from the token).
    Token(TokenField),
    /// The Look gallery (the last Animation row).
    Gallery,
    /// A field-leading slider: the field, then the track.
    Slider(Field),
}

/// One laid-out row.
#[derive(Clone, Debug)]
pub struct Row {
    pub label: Option<String>,
    pub icon: Option<SQIcon>,
    pub level: usize,
    pub y: f64,
    pub height: f64,
    pub controls: Vec<(Control, CGRect)>,
    pub tip: Option<String>,
}

/// What a numeric field allows and resets to.
#[derive(Clone, Debug, PartialEq)]
pub struct Spec {
    pub range: (f64, f64),
    pub def: Option<f64>,
    pub step: f64,
    pub decimals: i64,
    pub unit: &'static str,
}

/// Icon (or title) and tooltip of one button of a group.
pub struct ButtonSpec {
    pub icon: Option<SQIcon>,
    pub title: Option<&'static str>,
    pub tip: &'static str,
}

pub struct TextBlockDraw {
    pub theme: DrawTheme,
    pub width: f64,
    /// A part's height changed (a section or detail row opened, the box grew): the host re-lays out; it reads
    /// `take_height_changed`.
    height_changed: bool,
    /// The clip's text shown in the box.
    pub text: String,
    box_text: String,
    /// The text box row (the Captions Look tab hides it).
    pub shows_text_box: bool,
    /// The animated Look gallery as the last Animation row.
    shows_look_gallery: bool,
    pub look_gallery: LookGalleryDraw,
    /// `None`: the model's text looks.
    pub look_source: Option<Box<dyn Fn() -> LookSource>>,
    pub look_status: Option<Box<dyn Fn() -> Option<LookStatus>>>,
    /// The host can sample a screen color: the eyedropper buttons show.
    pub can_sample_screen_color: bool,
    defaults: Option<Box<dyn UiDefaults>>,
    text_open: bool,
    /// The block sits under the kit's Look rows: its dense part is "More Text Options", closed by default, with its own
    /// remembered state.
    pub kit_key: bool,
    /// The Check controls draw as switches (set by `draw` for the kit part).
    switch_checks: bool,
    animation_open: bool,
    open_layers: BTreeSet<Layer>,
    last_fill_alpha: f64,
    axis_cache: RefCell<Option<(String, Vec<Axis>)>>,
    fields: HashMap<Field, ScrubFieldControl>,
    focused: Option<Field>,
    menu_sink: Rc<RefCell<Vec<BlockCommand>>>,
    hover: Option<Control>,
    pressed: Option<Control>,
    press_part: Part,
    slider_drag: Option<Field>,
    field_press: Option<Field>,
    counter: ClickCounter,
    editor: Option<TextEditState>,
    typed: bool,
    color_open: bool,
    requests: Vec<BlockRequest>,
    /// Asks for a name (Save as New Look, Rename, Save Animation): title, initial, then `done` (`None` = canceled).
    /// Without it the suggested name is taken.
    pub ask_name: Option<AskNameFn>,
    /// Something did not happen: the host shows it in its status line.
    pub on_notice: Option<Box<dyn FnMut(String)>>,
    /// Replaces the Update button's action.
    pub on_update_look: Option<Box<dyn FnMut()>>,
    /// Replaces the Save as New action.
    pub on_save_look_as_new: Option<Box<dyn FnMut()>>,
    /// The host's Look context menu; `None` = the model's text looks.
    pub look_context: Option<Box<dyn Fn() -> Vec<SQMenuItem>>>,
}

/// What the block asks of its host (the Swift class held closures; the host drains `take_requests`).
#[derive(Clone, Debug, PartialEq)]
pub enum BlockRequest {
    /// A popup opened: the SQ menu at `anchor` (coordinates of `part`). The rows queue commands: the host calls
    /// `run_menu_commands` once the menu closes.
    Menu { items: Vec<SQMenuItem>, anchor: CGRect, part: Part },
    /// A swatch was clicked: open the color picker, answer each change with `color_changed` and its close with
    /// `color_changed(.., None)`.
    PickColor { control: Control, current: EffectColor, anchor: CGRect, part: Part },
    /// An eyedropper: sample a screen color and answer with `color_sampled` (`None` = canceled).
    SampleColor(Layer),
    /// A typing gesture in the text box starts (first change after focus).
    TextBegin,
    /// The box text changed.
    TextChange(String),
    /// The typing gesture ended (focus left).
    TextEnd,
}

/// Asks the host for a name; `done` gets it, or `None` when canceled.
pub type AskNameFn = Box<dyn FnMut(&str, &str, Box<dyn FnOnce(Option<String>)>)>;

/// A name the block asked for that the host shows as a dialog; `done` gets the typed name, `None` when canceled.
pub struct NameAsk {
    pub title: String,
    pub initial: String,
    pub done: Box<dyn FnOnce(Option<String>)>,
}

/// The names asked for until the host shows them: [`NameAsks::ask`] is what `ask_name` gets, the host drains
/// [`NameAsks::take`] into dialogs. A block without one saves under the suggested name unseen.
#[derive(Clone, Default)]
pub struct NameAsks(Rc<RefCell<Vec<NameAsk>>>);

impl NameAsks {
    pub fn ask(&self) -> AskNameFn {
        let queue = Rc::clone(&self.0);
        Box::new(move |title, initial, done| {
            queue.borrow_mut().push(NameAsk { title: title.to_string(), initial: initial.to_string(), done });
        })
    }

    pub fn take(&self) -> Vec<NameAsk> {
        std::mem::take(&mut *self.0.borrow_mut())
    }
}

/// What a menu row does once the host closes the menu (the rows hold no model): the host calls `run_menu_commands`.
#[derive(Clone, Debug, PartialEq)]
pub enum BlockCommand {
    Font(String),
    Weight(FontWeight),
    PickStyle(String),
    PickSourceLook(String),
    SecondFont(String),
    SecondWeight(FontWeight),
    List(TextListKind),
    Animation(String, AnimationSide),
    Effect(Option<TextAnimatorEffect>, AnimatorSide),
    Unit(TextAnimatorUnit, AnimatorSide),
    Easing(SegmentShape, AnimatorSide),
    Direction(TextSlideDirection, AnimatorSide),
    Order(TextAnimatorOrder, AnimatorSide),
    Token(TokenField, Option<String>),
    SaveLookAsNew,
    SaveStyleNamed(String),
    UpdateLook,
    UpdateStyle(String),
    AskRename(String, String),
    RenameStyle(String, String),
    DeleteStyle(String),
    SaveAnimationNamed(AnimationSide, String),
}

impl Default for TextBlockDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl TextBlockDraw {
    pub const ICON_BUTTON: f64 = 28.0;
    pub const SEGMENT_WIDTH: f64 = 60.0;
    pub const WEIGHT_WIDTH: f64 = 78.0;
    pub const LENGTH_WIDTH: f64 = 76.0;
    /// Text box line height.
    pub const LINE_HEIGHT: f64 = type_size::BODY as f64 + 5.0;

    pub const WEIGHTS: [(&'static str, FontWeight); 8] = [
        ("Thin", FontWeight::Thin),
        ("Light", FontWeight::Light),
        ("Regular", FontWeight::Regular),
        ("Medium", FontWeight::Medium),
        ("Semibold", FontWeight::Semibold),
        ("Bold", FontWeight::Bold),
        ("Heavy", FontWeight::Heavy),
        ("Black", FontWeight::Black),
    ];

    pub const ALIGN_SYMBOLS: [(FrameAlignment, SQIcon, &'static str); 6] = [
        (FrameAlignment::Left, SQIcon::AlignLeft, "Align Left"),
        (FrameAlignment::CenterHorizontally, SQIcon::AlignCenterH, "Align Center Horizontally"),
        (FrameAlignment::Right, SQIcon::AlignRight, "Align Right"),
        (FrameAlignment::Top, SQIcon::AlignTop, "Align Top"),
        (FrameAlignment::CenterVertically, SQIcon::AlignCenterV, "Align Center Vertically"),
        (FrameAlignment::Bottom, SQIcon::AlignBottom, "Align Bottom"),
    ];

    pub fn new() -> TextBlockDraw {
        TextBlockDraw {
            theme: DrawTheme::default(),
            width: 320.0,
            height_changed: false,
            text: String::new(),
            box_text: String::new(),
            shows_text_box: true,
            shows_look_gallery: false,
            look_gallery: LookGalleryDraw::new(
                sq_text::caption_presets::CaptionPresetLibrary::built_in(),
                vec![LookGroup::Entrance, LookGroup::Motion, LookGroup::Exit],
            ),
            look_source: None,
            look_status: None,
            can_sample_screen_color: false,
            defaults: None,
            text_open: true,
            switch_checks: false,
            kit_key: false,
            animation_open: false,
            open_layers: BTreeSet::new(),
            last_fill_alpha: 1.0,
            axis_cache: RefCell::new(None),
            fields: HashMap::new(),
            focused: None,
            menu_sink: Rc::new(RefCell::new(Vec::new())),
            hover: None,
            pressed: None,
            press_part: Part::Text,
            slider_drag: None,
            field_press: None,
            counter: ClickCounter::new(),
            editor: None,
            typed: false,
            color_open: false,
            requests: Vec::new(),
            ask_name: None,
            on_notice: None,
            on_update_look: None,
            on_save_look_as_new: None,
            look_context: None,
        }
    }

    /// Sets the clip's text; the box keeps what is typed while a text edit is open (none here yet).
    pub fn set_text(&mut self, text: &str) {
        self.text = text.to_string();
        self.box_text = text.to_string();
    }

    pub fn set_shows_look_gallery(&mut self, on: bool) {
        if self.shows_look_gallery != on {
            self.shows_look_gallery = on;
            self.height_changed = true;
        }
    }

    /// True once after a part's height changed.
    pub fn take_height_changed(&mut self) -> bool {
        std::mem::take(&mut self.height_changed)
    }

    pub fn text_open(&self) -> bool {
        self.text_open
    }

    pub fn animation_open(&self) -> bool {
        self.animation_open
    }

    pub fn open_layers(&self) -> &BTreeSet<Layer> {
        &self.open_layers
    }

    pub fn focused(&self) -> Option<&Field> {
        self.focused.as_ref()
    }

    /// The defaults key of a Layer's open state.
    pub fn layer_key(l: Layer) -> String {
        format!("sq.textBlock.open.{}", l.raw())
    }

    /// The defaults key of the Text and Animation sections.
    pub fn section_key(k: &str) -> String {
        format!("sq.inspector.open.{k}")
    }

    /// Remembers the open state in `defaults` and takes the stored state now (Text open, Animation closed and every layer
    /// closed until stored).
    pub fn set_defaults(&mut self, defaults: Box<dyn UiDefaults>) {
        self.text_open = read_open(defaults.as_ref(), &Self::section_key(self.text_key())).unwrap_or(!self.kit_key);
        self.animation_open = read_open(defaults.as_ref(), &Self::section_key("textblock.animation")).unwrap_or(false);
        self.open_layers = Layer::ALL
            .iter()
            .copied()
            .filter(|l| read_open(defaults.as_ref(), &Self::layer_key(*l)) == Some(true))
            .collect();
        self.defaults = Some(defaults);
        self.height_changed = true;
    }

    fn remember(&mut self, key: &str, open: bool) {
        if let Some(d) = self.defaults.as_mut() {
            write_open(d.as_mut(), key, open);
        }
    }

    pub fn set_layer_open(&mut self, l: Layer, open: bool) {
        if open {
            self.open_layers.insert(l);
        } else {
            self.open_layers.remove(&l);
        }
        self.remember(&Self::layer_key(l), open);
        self.height_changed = true;
    }

    fn text_key(&self) -> &'static str {
        if self.kit_key { "textblock.text.more" } else { "textblock.text" }
    }

    pub fn set_text_open(&mut self, open: bool) {
        self.text_open = open;
        self.remember(&Self::section_key(self.text_key()), open);
        self.height_changed = true;
    }

    pub fn set_animation_open(&mut self, open: bool) {
        self.animation_open = open;
        self.remember(&Self::section_key("textblock.animation"), open);
        self.height_changed = true;
    }

    // MARK: Buttons

    /// Icon (or title) and tooltip of each button of a group.
    pub fn buttons(g: Group) -> Vec<ButtonSpec> {
        let icon = |i: SQIcon, tip| ButtonSpec { icon: Some(i), title: None, tip };
        let title = |t, tip| ButtonSpec { icon: None, title: Some(t), tip };
        match g {
            Group::Style => vec![
                icon(SQIcon::TextBold, "Bold"),
                icon(SQIcon::TextItalic, "Italic"),
                icon(SQIcon::TextCaseUpper, "All Caps"),
                icon(SQIcon::TextUnderline, "Underline"),
                icon(SQIcon::TextStrikethrough, "Strikethrough"),
                icon(SQIcon::TextOverline, "Overline"),
            ],
            Group::Align => vec![
                icon(SQIcon::TextAlignLeft, "Align Text Left"),
                icon(SQIcon::TextAlignCenter, "Center Text"),
                icon(SQIcon::TextAlignRight, "Align Text Right"),
            ],
            Group::Vertical => vec![
                icon(SQIcon::TextTop, "Align Text to Top"),
                icon(SQIcon::TextMiddle, "Center Text Vertically"),
                icon(SQIcon::TextBottom, "Align Text to Bottom"),
            ],
            Group::Direction => {
                vec![icon(SQIcon::TextLTR, "Left to Right"), icon(SQIcon::TextRTL, "Right to Left")]
            }
            Group::Frame => Self::ALIGN_SYMBOLS.iter().map(|s| icon(s.1, s.2)).collect(),
            Group::FillMode => {
                vec![title("Color", "Fill Mode"), title("Footage", "Fill Mode"), title("Invert", "Fill Mode")]
            }
            Group::StrokePosition => {
                vec![title("Out", "Outline Position"), title("Mid", "Outline Position")]
            }
            Group::SecondItalic => vec![title("I", "Italic")],
        }
    }

    // MARK: Layout

    const ROW: f64 = ControlsGrid::ROW_HEIGHT;
    /// The kit's switch (width, height).
    const KIT_SWITCH: (f64, f64) = (34.0, 20.0);

    fn value_end(&self) -> f64 {
        (self.width - ControlsGrid::TRAILING).max(ControlsGrid::VALUE_X)
    }

    fn reset_x(&self) -> f64 {
        self.value_end() - ControlsGrid::RESET_WIDTH
    }

    fn boxed(x: f64, w: f64, h: f64) -> CGRect {
        CGRect::new(x, ((Self::ROW - h) / 2.0).round(), w.max(0.0), h)
    }

    fn cell(x: f64, w: f64) -> CGRect {
        Self::boxed(x, w, ControlsGrid::CONTROL_HEIGHT)
    }

    fn group(g: Group, x: f64, w: f64) -> Vec<(Control, CGRect)> {
        (0..Self::buttons(g).len()).map(|i| (Control::Button(g, i), Self::cell(x + i as f64 * w, w))).collect()
    }

    /// The text box: 2 to 6 lines.
    pub fn box_height(&self) -> f64 {
        let lines = self.box_text.split('\n').count();
        lines.clamp(2, 6) as f64 * Self::LINE_HEIGHT + 8.0
    }

    /// A tile is at least this wide and grows with the panel to the frame's 80 pt (`.tile` in panels.html).
    const STYLE_TILE_W: f64 = 64.0;
    const STYLE_TILE_MAX_W: f64 = 80.0;
    const STYLE_TILE_H: f64 = 46.0;
    const STYLE_TILE_GAP: f64 = 6.0;
    /// The built-in styles the Style row shows as tiles (the frame's Title, Lower Third, ...), in this order. A host with
    /// its own Look list (the Captions tab) has its tiles elsewhere.
    const STYLE_TILE_IDS: [&'static str; 4] = ["title", "lower-third", "outline", "pill"];

    /// (id, name, style) of the Style row's tiles.
    pub fn style_tiles(&self, model: &TextInspectorModel) -> Vec<(String, String, sq_text::text_style::TextStyle)> {
        if self.look_source.is_some() {
            return Vec::new();
        }
        Self::STYLE_TILE_IDS.iter().filter_map(|id| model.styles().entry(id)).map(|e| (e.id, e.name, e.style)).collect()
    }

    pub fn look_edited(&self, model: &TextInspectorModel) -> bool {
        self.current_look_status(model).is_some_and(|s| s.edited)
    }

    /// The style font's variation axes, looked up once per font name (rows are laid out every frame).
    pub fn font_axes(&self, model: &TextInspectorModel) -> Vec<Axis> {
        let name = &model.style().font_name;
        if let Some((font, axes)) = self.axis_cache.borrow().as_ref()
            && font == name
        {
            return axes.clone();
        }
        let axes = model.font_axes();
        *self.axis_cache.borrow_mut() = Some((name.clone(), axes.clone()));
        axes
    }

    fn axis(&self, model: &TextInspectorModel, tag: &str) -> Option<Axis> {
        self.font_axes(model).into_iter().find(|a| a.tag == tag)
    }

    pub fn rows(&self, model: &TextInspectorModel, part: Part) -> Vec<Row> {
        let mut out: Vec<Row> = Vec::new();
        let mut y = 0.0;
        let mut add = |label: Option<String>,
                       icon: Option<SQIcon>,
                       level: usize,
                       tip: Option<String>,
                       controls: Vec<(Control, CGRect)>,
                       height: Option<f64>| {
            let h = height.unwrap_or(Self::ROW);
            out.push(Row { label, icon, level, y, height: h, controls, tip });
            y += h;
        };
        let s = |t: &str| Some(t.to_string());
        let (x0, ve, fw) = (ControlsGrid::VALUE_X, self.value_end(), ControlsGrid::VALUE_WIDTH);
        let full = Self::cell(x0, ve - x0);
        let slider = |f: Field| vec![(Control::Slider(f), full)];
        match part {
            Part::Text | Part::KitLook => {
                if part == Part::KitLook {
                    self.kit_rows(model, &mut add);
                }
                add(
                    None,
                    None,
                    0,
                    None,
                    vec![(Control::TextHeader, CGRect::new(0.0, 0.0, self.width, Self::ROW))],
                    None,
                );
                if self.text_open {
                    let bh = self.box_height();
                    if self.shows_text_box {
                        let r = CGRect::new(ControlsGrid::LABEL_X, 4.0, (ve - ControlsGrid::LABEL_X).max(0.0), bh);
                        add(None, None, 0, None, vec![(Control::TextBox, r)], Some(bh + 8.0));
                    }
                    let tiles = self.style_tiles(model);
                    if !tiles.is_empty() {
                        let gap = Self::STYLE_TILE_GAP;
                        let fit = (((ve - x0 + gap) / (Self::STYLE_TILE_W + gap)) as usize).clamp(1, tiles.len());
                        // The tiles share the room the row has (hit areas follow the panel width), up to the frame's size.
                        let tw =
                            (((ve - x0 + gap) / fit as f64) - gap).clamp(Self::STYLE_TILE_W, Self::STYLE_TILE_MAX_W);
                        let controls = (0..fit)
                            .map(|i| {
                                (
                                    Control::StyleTile(i),
                                    CGRect::new(x0 + i as f64 * (tw + gap), 3.0, tw, Self::STYLE_TILE_H),
                                )
                            })
                            .collect();
                        add(s("Style"), None, 0, None, controls, Some(Self::STYLE_TILE_H + 6.0));
                    }
                    let pw = Self::WEIGHT_WIDTH;
                    add(
                        s("Font"),
                        None,
                        0,
                        None,
                        vec![
                            (Control::Font, Self::cell(x0, ve - pw - ControlsGrid::GAP - x0)),
                            (Control::Weight, Self::cell(ve - pw, pw)),
                        ],
                        None,
                    );
                    add(s("Size"), None, 0, None, slider(Field::Size), None);
                    let ib = Self::ICON_BUTTON;
                    add(None, None, 0, None, Self::group(Group::Style, ControlsGrid::LABEL_X, ib), None);
                    add(None, None, 0, None, Self::group(Group::Align, ControlsGrid::LABEL_X, ib), None);
                    let mut vertical = Self::group(Group::Vertical, ControlsGrid::LABEL_X, ib);
                    vertical.extend(Self::group(
                        Group::Direction,
                        ControlsGrid::LABEL_X + 3.0 * ib + 2.0 * ControlsGrid::GAP,
                        ib,
                    ));
                    add(None, None, 0, None, vertical, None);
                    let lead = x0 + fw + ControlsGrid::GAP;
                    add(
                        None,
                        Some(SQIcon::MoveHorizontal),
                        0,
                        s("Letter Spacing (px)"),
                        vec![
                            (Control::Field(Field::Tracking), Self::cell(x0, fw)),
                            (Control::Field(Field::Leading), Self::cell(lead + 14.0 + ControlsGrid::GAP, fw)),
                        ],
                        None,
                    );
                    // The font's variation axes: one number per axis, none for a static font.
                    for a in self.font_axes(model) {
                        let tip = Some(format!("{} ({})", a.name, a.tag));
                        add(
                            Some(a.name.clone()),
                            None,
                            0,
                            tip,
                            vec![(Control::Field(Field::Axis(a.tag)), Self::cell(x0, fw))],
                            None,
                        );
                    }
                    let token_row = |add: &mut AddRow, f: TokenField, level: usize| {
                        if model.token_names(f).is_empty() {
                            return;
                        }
                        let name = if f == TokenField::Font { "Font" } else { "Color" };
                        add(
                            Some(SQL10n::format("%@ Token", &[&SQL10n::string(name)])),
                            None,
                            level,
                            Some(SQL10n::format("Follow %@ Token", &[&SQL10n::string(name)])),
                            vec![(Control::Token(f), Self::cell(x0, ve - x0))],
                            None,
                        );
                    };
                    token_row(&mut add, TokenField::Font, 0);
                    add(
                        s("Look"),
                        None,
                        0,
                        None,
                        vec![
                            (Control::Look, Self::cell(x0, self.reset_x() - ControlsGrid::GAP - x0)),
                            (Control::LookAdd, Self::cell(self.reset_x(), ControlsGrid::RESET_WIDTH)),
                        ],
                        None,
                    );
                    if self.look_edited(model) {
                        add(
                            None,
                            None,
                            0,
                            None,
                            vec![
                                (Control::LookUpdate, Self::cell(x0, 64.0)),
                                (Control::LookSaveNew, Self::cell(x0 + 64.0 + ControlsGrid::GAP, 96.0)),
                            ],
                            None,
                        );
                    }
                    for l in Layer::ALL {
                        let mut c = vec![(
                            Control::Check(l),
                            Self::boxed(ControlsGrid::TOGGLE_X, ControlsGrid::TOGGLE_WIDTH, 14.0),
                        )];
                        if l.has_well() {
                            c.push((Control::Well(l), Self::boxed(ControlsGrid::value_column(0), fw, 18.0)));
                        }
                        let value = match l {
                            Layer::Fill => Some(Field::FillValue),
                            Layer::Outline => Some(Field::OutlineValue),
                            Layer::Background => Some(Field::BackgroundValue),
                            Layer::Shadow => Some(Field::ShadowValue),
                            _ => None,
                        };
                        if let Some(f) = value {
                            c.push((Control::Field(f), Self::cell(ControlsGrid::value_column(1), fw)));
                        }
                        if Self::EYEDROPPER_LAYERS.contains(&l) && self.can_sample_screen_color {
                            c.push((
                                Control::Eyedropper(l),
                                Self::cell(ControlsGrid::value_column(2), ControlsGrid::RESET_WIDTH),
                            ));
                        }
                        if l.has_detail() {
                            c.push((Control::Chevron(l), Self::cell(self.reset_x(), ControlsGrid::RESET_WIDTH)));
                        }
                        add(s(&SQL10n::string(l.title())), None, 0, None, c, None);
                        if !l.has_detail() || !self.open_layers.contains(&l) {
                            continue;
                        }
                        let seg = Self::SEGMENT_WIDTH;
                        match l {
                            Layer::Fill => {
                                add(s("Opacity"), None, 1, None, slider(Field::FillOpacity), None);
                                add(s("Mode"), None, 1, None, Self::group(Group::FillMode, x0, seg), None);
                                token_row(&mut add, TokenField::Color, 1);
                            }
                            Layer::Gradient => {
                                add(
                                    s("End Color"),
                                    None,
                                    1,
                                    None,
                                    vec![(Control::GradientEnd, Self::boxed(x0, fw, 18.0))],
                                    None,
                                );
                                add(s("Angle"), None, 1, None, slider(Field::GradientAngle), None);
                            }
                            Layer::Outline => {
                                add(
                                    None,
                                    Some(SQIcon::Minimize),
                                    1,
                                    s("Outline Width"),
                                    slider(Field::StrokeWidth),
                                    None,
                                );
                                add(s("Position"), None, 1, None, Self::group(Group::StrokePosition, x0, seg), None);
                                token_row(&mut add, TokenField::StrokeColor, 1);
                            }
                            Layer::Background => {
                                add(s("Opacity"), None, 1, None, slider(Field::BoxOpacity), None);
                                add(s("Padding X"), None, 1, None, slider(Field::PadX), None);
                                add(s("Padding Y"), None, 1, None, slider(Field::PadY), None);
                                add(s("Radius"), None, 1, None, slider(Field::Radius), None);
                                token_row(&mut add, TokenField::BackgroundColor, 1);
                            }
                            Layer::Shadow => {
                                add(
                                    None,
                                    Some(SQIcon::Droplet),
                                    1,
                                    s("Shadow Opacity"),
                                    slider(Field::ShadowOpacity),
                                    None,
                                );
                                add(
                                    None,
                                    Some(SQIcon::ShadowAngle),
                                    1,
                                    s("Shadow Angle"),
                                    slider(Field::ShadowAngle),
                                    None,
                                );
                                add(
                                    None,
                                    Some(SQIcon::Move),
                                    1,
                                    s("Shadow Distance"),
                                    slider(Field::ShadowDistance),
                                    None,
                                );
                                add(None, Some(SQIcon::Maximize), 1, s("Shadow Size"), slider(Field::ShadowSize), None);
                                add(
                                    None,
                                    Some(SQIcon::CircleDotted),
                                    1,
                                    s("Shadow Blur"),
                                    slider(Field::ShadowBlur),
                                    None,
                                );
                            }
                            Layer::Second => {
                                let pw = Self::WEIGHT_WIDTH;
                                add(
                                    s("Font"),
                                    None,
                                    1,
                                    None,
                                    vec![
                                        (Control::SecondFont, Self::cell(x0, ve - pw - ControlsGrid::GAP - x0)),
                                        (Control::SecondWeight, Self::cell(ve - pw, pw)),
                                    ],
                                    None,
                                );
                                add(s("Size"), None, 1, None, slider(Field::SecondSize), None);
                                let mut c = vec![(Control::SecondWell, Self::boxed(x0, fw, 18.0))];
                                c.extend(Self::group(
                                    Group::SecondItalic,
                                    x0 + fw + ControlsGrid::GAP,
                                    Self::ICON_BUTTON,
                                ));
                                add(s("Color"), None, 1, None, c, None);
                            }
                            Layer::List => {
                                add(s("Style"), None, 1, None, vec![(Control::ListKind, Self::cell(x0, 96.0))], None);
                            }
                            Layer::AutoFit => {}
                        }
                    }
                }
            }
            Part::Arrange => add(s("Arrange"), None, 0, None, Self::group(Group::Frame, x0, Self::ICON_BUTTON), None),
            Part::Animation => {
                add(
                    None,
                    None,
                    0,
                    None,
                    vec![(Control::AnimationHeader, CGRect::new(0.0, 0.0, self.width, Self::ROW))],
                    None,
                );
                if self.animation_open {
                    let lw = Self::LENGTH_WIDTH;
                    let pw = ve - lw - ControlsGrid::GAP - x0;
                    add(
                        s("Intro"),
                        None,
                        0,
                        None,
                        vec![
                            (Control::Intro, Self::cell(x0, pw)),
                            (Control::Field(Field::InLength), Self::cell(ve - lw, lw)),
                        ],
                        None,
                    );
                    add(
                        s("Outro"),
                        None,
                        0,
                        None,
                        vec![
                            (Control::Outro, Self::cell(x0, pw)),
                            (Control::Field(Field::OutLength), Self::cell(ve - lw, lw)),
                        ],
                        None,
                    );
                    // The text animators: two half-width popups per row, then the value fields.
                    let half = ((ve - x0 - ControlsGrid::GAP) / 2.0).floor();
                    for (side, title) in [(AnimatorSide::In, "In"), (AnimatorSide::Out, "Out")] {
                        add(
                            Some(SQL10n::format("%@ by", &[&SQL10n::string(title)])),
                            None,
                            0,
                            None,
                            vec![
                                (Control::Animator(side, AnimatorControl::Effect), Self::cell(x0, half)),
                                (Control::Animator(side, AnimatorControl::Unit), Self::cell(ve - half, half)),
                            ],
                            None,
                        );
                        add(
                            None,
                            None,
                            0,
                            None,
                            vec![
                                (Control::Animator(side, AnimatorControl::Easing), Self::cell(x0, half)),
                                (Control::Animator(side, AnimatorControl::Direction), Self::cell(ve - half, half)),
                            ],
                            None,
                        );
                        add(
                            s("Order"),
                            None,
                            0,
                            None,
                            vec![(Control::Animator(side, AnimatorControl::Order), Self::cell(x0, half))],
                            None,
                        );
                        for (k, label) in [
                            (AnimatorControl::Stagger, "Stagger"),
                            (AnimatorControl::Length, "Length"),
                            (AnimatorControl::Distance, "Distance"),
                            (AnimatorControl::Blur, "Blur"),
                            (AnimatorControl::Loops, "Loops"),
                        ] {
                            add(
                                s(label),
                                None,
                                0,
                                None,
                                vec![(Control::Field(Field::Animator(side, k)), Self::cell(x0, fw))],
                                None,
                            );
                        }
                    }
                    if self.shows_look_gallery {
                        let gh = self.look_gallery.height_for_width(self.width);
                        add(
                            None,
                            None,
                            0,
                            None,
                            vec![(Control::Gallery, CGRect::new(0.0, 0.0, self.width, gh))],
                            Some(gh),
                        );
                    }
                }
            }
        }
        out
    }

    /// Layers with an eyedropper after the value.
    const EYEDROPPER_LAYERS: [Layer; 4] = [Layer::Fill, Layer::Outline, Layer::Background, Layer::Shadow];

    /// The kit's Look rows (`Panel / Captions / Style`): Font + weight + size, then Fill, Outline, Background and
    /// Shadow, each a switch, a color chip and its numbers.
    fn kit_rows(&self, model: &TextInspectorModel, add: &mut AddRow) {
        let s = |t: &str| Some(t.to_string());
        let (x0, ve, fw, g) = (ControlsGrid::VALUE_X, self.value_end(), ControlsGrid::VALUE_WIDTH, ControlsGrid::GAP);
        let pw = Self::WEIGHT_WIDTH;
        add(
            s("Font"),
            None,
            0,
            None,
            vec![
                (Control::Font, Self::cell(x0, (ve - pw - fw - 2.0 * g - x0).max(60.0))),
                (Control::Weight, Self::cell((ve - pw - fw - g).max(x0 + 60.0 + g), pw)),
                (Control::Field(Field::Size), Self::cell((ve - fw).max(x0 + 60.0 + pw + 2.0 * g), fw)),
            ],
            None,
        );
        let sw = Self::KIT_SWITCH;
        let chip = x0 + sw.0 + g;
        let unit = |x: f64, text: &'static str| {
            let w = (text.chars().count() as f64 * 7.0).max(14.0);
            ((Control::Unit(text), Self::cell(x, w)), x + w + g)
        };
        for l in [Layer::Fill, Layer::Outline, Layer::Background, Layer::Shadow] {
            let mut c = vec![(Control::Check(l), Self::boxed(x0, sw.0, sw.1))];
            let on = self.is_on(model, l);
            let mut x = chip;
            if l == Layer::Shadow && !on {
                c.push(unit(x, "Off").0);
            } else {
                c.push((Control::Well(l), Self::boxed(x, fw, 18.0)));
                x += fw + g;
                let mut numbers: Vec<(Field, &'static str)> = Vec::new();
                match l {
                    Layer::Outline => numbers.push((Field::StrokeWidth, "px")),
                    Layer::Background => {
                        numbers.push((Field::PadX, "px"));
                        numbers.push((Field::Radius, "corner px"));
                    }
                    Layer::Shadow => numbers.push((Field::ShadowBlur, "blur px")),
                    _ => {}
                }
                for (f, label) in numbers {
                    c.push((Control::Field(f), Self::cell(x, fw)));
                    x += fw + g;
                    let (u, nx) = unit(x, label);
                    c.push(u);
                    x = nx;
                }
            }
            add(s(&SQL10n::string(l.title())), None, 0, None, c, None);
        }
    }

    pub fn height(&self, model: &TextInspectorModel, part: Part) -> f64 {
        self.rows(model, part).last().map_or(0.0, |r| r.y + r.height)
    }

    pub fn frame(&self, model: &TextInspectorModel, c: &Control, part: Part) -> Option<CGRect> {
        self.rows(model, part).into_iter().find_map(|r| {
            r.controls.iter().find(|(k, _)| k == c).map(|(_, f)| CGRect::new(f.x, f.y + r.y, f.width, f.height))
        })
    }

    /// Slider parts: the value field first, the track after it.
    pub fn slider_parts(r: CGRect) -> (CGRect, CGRect) {
        let fw = ControlsGrid::VALUE_WIDTH.min(r.width);
        let field = CGRect::new(r.x, r.y, fw, r.height);
        let tx = field.x + field.width + ControlsGrid::GAP;
        (field, CGRect::new(tx, r.y, (r.x + r.width - tx).max(0.0), r.height))
    }

    // MARK: Values

    pub fn spec(&self, model: &TextInspectorModel, f: &Field) -> Spec {
        let spec = |lo: f64, hi: f64, def: Option<f64>, step: f64, decimals: i64, unit: &'static str| Spec {
            range: (lo, hi),
            def,
            step,
            decimals,
            unit,
        };
        match f {
            Field::Animator(side, k) => {
                let ms = TextInspectorModel::MAX_ANIMATOR_MILLISECONDS as f64;
                let px = TextInspectorModel::MAX_ANIMATOR_PIXELS;
                match k {
                    AnimatorControl::Stagger => {
                        spec(0.0, ms, Some(self.animator_stagger_default(model, *side) as f64), 5.0, 0, "ms")
                    }
                    AnimatorControl::Length => {
                        spec(0.0, ms, Some(TextAnimatorChoices::DEFAULT_DURATION_MILLISECONDS as f64), 5.0, 0, "ms")
                    }
                    AnimatorControl::Distance => {
                        spec(0.0, px, Some(TextInspectorModel::DEFAULT_ANIMATOR_DISTANCE), 1.0, 0, "px")
                    }
                    AnimatorControl::Blur => {
                        spec(0.0, px, Some(TextInspectorModel::DEFAULT_ANIMATOR_BLUR), 1.0, 0, "px")
                    }
                    _ => spec(1.0, 50.0, Some(1.0), 1.0, 0, "x"),
                }
            }
            Field::Axis(tag) => {
                let Some(a) = self.axis(model, tag) else { return spec(0.0, 1.0, None, 1.0, 0, "") };
                let span = a.maximum - a.minimum;
                let step = if span > 200.0 {
                    1.0
                } else if span > 20.0 {
                    0.5
                } else {
                    0.1
                };
                spec(
                    a.minimum,
                    a.minimum.max(a.maximum),
                    Some(a.default_value),
                    step,
                    if step < 1.0 { 1 } else { 0 },
                    "",
                )
            }
            Field::InLength | Field::OutLength => {
                let side = if *f == Field::InLength { AnimationSide::Intro } else { AnimationSide::Outro };
                let lo = TextInspectorModel::MINIMUM_ZONE_MILLISECONDS as f64;
                let hi = model.zone_milliseconds(side).unwrap_or(0).max(model.maximum_zone_milliseconds(side)) as f64;
                spec(lo, lo.max(hi), None, 10.0, 0, "ms")
            }
            Field::Size | Field::SecondSize => spec(1.0, 400.0, Some(48.0), 1.0, 1, "px"),
            Field::Tracking => spec(-100.0, 500.0, Some(0.0), 0.5, 1, ""),
            Field::Leading => spec(-200.0, 500.0, Some(0.0), 1.0, 1, ""),
            Field::FillValue | Field::FillOpacity | Field::BackgroundValue | Field::BoxOpacity => {
                spec(0.0, 100.0, Some(100.0), 1.0, 1, "%")
            }
            Field::ShadowValue | Field::ShadowOpacity => spec(0.0, 100.0, Some(60.0), 1.0, 1, "%"),
            Field::OutlineValue | Field::StrokeWidth | Field::ShadowSize => spec(0.0, 100.0, Some(0.0), 0.5, 1, "px"),
            Field::PadX | Field::PadY => spec(0.0, 400.0, Some(0.0), 1.0, 1, "px"),
            Field::Radius => spec(0.0, 200.0, Some(0.0), 1.0, 1, "px"),
            Field::ShadowAngle => spec(-360.0, 360.0, Some(135.0), 1.0, 1, "°"),
            Field::ShadowDistance => spec(0.0, 400.0, Some(0.0), 0.5, 1, "px"),
            Field::ShadowBlur => spec(0.0, 200.0, Some(0.0), 0.5, 1, "px"),
            Field::GradientAngle => spec(0.0, 360.0, Some(90.0), 1.0, 1, "°"),
        }
    }

    /// The Stagger reset follows the animator's unit.
    fn animator_stagger_default(&self, model: &TextInspectorModel, side: AnimatorSide) -> i64 {
        let Some(a) = model.animator(side) else { return TextAnimatorChoices::DEFAULT_STAGGER_MILLISECONDS };
        TextInspectorModel::animator_milliseconds(TextInspectorModel::default_stagger(a.unit))
    }

    pub fn value(&self, model: &TextInspectorModel, f: &Field) -> f64 {
        let s = model.style();
        let alpha = |a: f64| (a * 100.0).round();
        match f {
            Field::Size => s.size,
            Field::Tracking => s.tracking,
            Field::Leading => s.line_spacing,
            Field::FillValue | Field::FillOpacity => alpha(s.color.alpha),
            Field::OutlineValue | Field::StrokeWidth => s.stroke.as_ref().map_or(0.0, |t| t.width),
            Field::BackgroundValue | Field::BoxOpacity => s.background.as_ref().map_or(100.0, |b| alpha(b.color.alpha)),
            Field::PadX => s.background.as_ref().map_or(0.0, |b| b.padding.horizontal),
            Field::PadY => s.background.as_ref().map_or(0.0, |b| b.padding.vertical),
            Field::Radius => s.background.as_ref().map_or(0.0, |b| b.corner_radius),
            Field::ShadowValue | Field::ShadowOpacity => s.shadow.as_ref().map_or(60.0, |h| alpha(h.color.alpha)),
            Field::ShadowAngle => s.shadow.as_ref().map_or(135.0, |h| h.angle().round()),
            Field::ShadowDistance => s.shadow.as_ref().map_or(0.0, |h| h.distance()),
            Field::ShadowBlur => s.shadow.as_ref().map_or(0.0, |h| h.blur),
            Field::ShadowSize => s.shadow.as_ref().map_or(0.0, |h| h.spread),
            Field::GradientAngle => s.gradient.as_ref().map_or(90.0, |g| g.angle),
            Field::SecondSize => s.second_line.as_ref().map_or(s.size * 2.0 / 3.0, |l| l.size),
            Field::InLength => model.zone_milliseconds(AnimationSide::Intro).unwrap_or(0) as f64,
            Field::OutLength => model.zone_milliseconds(AnimationSide::Outro).unwrap_or(0) as f64,
            Field::Axis(tag) => self.axis(model, tag).map_or(0.0, |a| model.axis_value(&a)),
            Field::Animator(side, k) => {
                let Some(a) = model.animator(*side) else {
                    return if *k == AnimatorControl::Loops { 1.0 } else { 0.0 };
                };
                match k {
                    AnimatorControl::Stagger => TextInspectorModel::animator_milliseconds(a.stagger) as f64,
                    AnimatorControl::Length => TextInspectorModel::animator_milliseconds(a.duration) as f64,
                    AnimatorControl::Distance => a.distance,
                    AnimatorControl::Blur => a.blur_radius,
                    _ => a.loops as f64,
                }
            }
        }
    }

    pub fn is_enabled(&self, model: &TextInspectorModel, f: &Field) -> bool {
        let s = model.style();
        match f {
            Field::Size | Field::Tracking | Field::Leading | Field::FillValue | Field::FillOpacity => true,
            Field::OutlineValue | Field::StrokeWidth => s.stroke.is_some(),
            Field::BackgroundValue | Field::BoxOpacity | Field::PadX | Field::PadY | Field::Radius => {
                s.background.is_some()
            }
            Field::ShadowValue
            | Field::ShadowOpacity
            | Field::ShadowAngle
            | Field::ShadowDistance
            | Field::ShadowBlur
            | Field::ShadowSize => s.shadow.is_some(),
            Field::GradientAngle => s.gradient.is_some(),
            Field::SecondSize => s.second_line.is_some(),
            Field::InLength => model.zone_milliseconds(AnimationSide::Intro).is_some(),
            Field::OutLength => model.zone_milliseconds(AnimationSide::Outro).is_some(),
            Field::Animator(side, k) => TextAnimatorChoices::is_enabled(*k, model.animator(*side)),
            Field::Axis(tag) => self.axis(model, tag).is_some(),
        }
    }

    /// Multi-select: a value that differs between the selected text clips shows no number.
    pub fn is_mixed(&self, model: &TextInspectorModel, f: &Field) -> bool {
        let m = |p: &str| model.is_mixed(p);
        match f {
            Field::Size => m("size"),
            Field::Tracking => m("tracking"),
            Field::Leading => m("lineSpacing"),
            Field::FillValue | Field::FillOpacity => m("color.alpha"),
            Field::OutlineValue | Field::StrokeWidth => m("stroke.width"),
            Field::BackgroundValue | Field::BoxOpacity => m("background.color.alpha"),
            Field::PadX => m("background.padding.horizontal"),
            Field::PadY => m("background.padding.vertical"),
            Field::Radius => m("background.cornerRadius"),
            Field::ShadowValue | Field::ShadowOpacity => m("shadow.color.alpha"),
            Field::ShadowAngle | Field::ShadowDistance => m("shadow.offsetX") || m("shadow.offsetY"),
            Field::ShadowBlur => m("shadow.blur"),
            Field::ShadowSize => m("shadow.spread"),
            Field::SecondSize => m("secondLine.size"),
            Field::Axis(_) => m("fontAxes"),
            Field::GradientAngle | Field::InLength | Field::OutLength | Field::Animator(..) => false,
        }
    }

    pub fn set(&self, model: &mut TextInspectorModel, f: &Field, v: f64) {
        let s = model.style().clone();
        match f {
            Field::Size => model.set_size(v),
            Field::Tracking => model.set_tracking(v),
            Field::Leading => model.set_line_spacing(v),
            Field::FillValue | Field::FillOpacity => model.set_fill_alpha(v / 100.0),
            Field::OutlineValue | Field::StrokeWidth => model.set_stroke_width(v),
            Field::BackgroundValue | Field::BoxOpacity => model.set_background_opacity(v / 100.0),
            Field::PadX => model.set_background_padding(v, s.background.as_ref().map_or(0.0, |b| b.padding.vertical)),
            Field::PadY => model.set_background_padding(s.background.as_ref().map_or(0.0, |b| b.padding.horizontal), v),
            Field::Radius => model.set_background_radius(v),
            Field::ShadowValue | Field::ShadowOpacity => model.set_shadow_opacity(v / 100.0),
            Field::ShadowAngle => model.set_shadow_angle(v, s.shadow.as_ref().map_or(0.0, |h| h.distance())),
            Field::ShadowDistance => model.set_shadow_angle(s.shadow.as_ref().map_or(135.0, |h| h.angle()), v),
            Field::ShadowBlur => model.set_shadow_blur(v),
            Field::ShadowSize => model.set_shadow_spread(v),
            Field::GradientAngle => model.set_gradient_angle(v),
            Field::SecondSize => model.set_second_line_size(v),
            Field::InLength => model.set_zone_length(TextInspectorModel::milliseconds(v), AnimationSide::Intro),
            Field::OutLength => model.set_zone_length(TextInspectorModel::milliseconds(v), AnimationSide::Outro),
            Field::Axis(tag) => {
                if let Some(a) = self.axis(model, tag) {
                    model.set_font_axis(&a, v);
                }
            }
            Field::Animator(side, k) => match k {
                AnimatorControl::Stagger => model.set_animator_stagger(TextInspectorModel::milliseconds(v), *side),
                AnimatorControl::Length => model.set_animator_duration(TextInspectorModel::milliseconds(v), *side),
                AnimatorControl::Distance => model.set_animator_distance(v, *side),
                AnimatorControl::Blur => model.set_animator_blur_radius(v, *side),
                _ => model.set_animator_loops(v.round() as i64, *side),
            },
        }
    }

    /// The scrub field of `f`, configured from the model (a drag or typing keeps its own value).
    pub fn field(&mut self, model: &TextInspectorModel, f: &Field) -> &mut ScrubFieldControl {
        let sp = self.spec(model, f);
        let (enabled, mixed, value) = (self.is_enabled(model, f), self.is_mixed(model, f), self.value(model, f));
        let fd = self.fields.entry(f.clone()).or_insert_with(|| ScrubFieldControl::new(value));
        fd.range = sp.range.0..=sp.range.1;
        fd.step = sp.step;
        fd.unit = sp.unit.to_string();
        fd.default_value = sp.def;
        fd.decimals = sp.decimals;
        fd.is_enabled = enabled;
        fd.is_mixed = mixed;
        if !fd.is_dragging() && fd.editor().is_none() {
            fd.value = value;
        }
        fd
    }

    /// Turns a field's events into model edits, one undo step per gesture.
    pub fn apply(&self, model: &mut TextInspectorModel, events: Vec<ScrubEvent>, f: &Field) {
        for e in events {
            match e {
                ScrubEvent::Begin => model.begin_editing(),
                ScrubEvent::Live(v) | ScrubEvent::Change(v) => self.set(model, f, v),
                ScrubEvent::End(v) | ScrubEvent::Cancel(v) => {
                    self.set(model, f, v);
                    model.end_editing();
                }
            }
        }
    }

    // MARK: Buttons

    /// Selected and mixed state of a button (`TextBlockView.refresh`).
    pub fn button_state(&self, model: &TextInspectorModel, g: Group, i: usize) -> (bool, bool) {
        let s = model.style();
        match g {
            Group::Style => {
                const PATHS: [&str; 6] = ["weight", "italic", "allCaps", "underline", "strikethrough", "overline"];
                let on = [s.weight >= FontWeight::Bold, s.italic, s.all_caps, s.underline, s.strikethrough, s.overline];
                let mixed = model.is_mixed(PATHS[i]);
                (on[i] && !mixed, mixed)
            }
            Group::Align => {
                if model.is_mixed("alignment") {
                    return (false, true);
                }
                let cur = [TextAlignment::Left, TextAlignment::Center, TextAlignment::Right]
                    .iter()
                    .position(|a| *a == s.alignment)
                    .unwrap_or(1);
                (cur == i, false)
            }
            Group::Vertical => {
                if model.is_mixed("verticalAlignment") {
                    return (false, true);
                }
                let cur = [TextVerticalAlignment::Top, TextVerticalAlignment::Middle, TextVerticalAlignment::Bottom]
                    .iter()
                    .position(|a| *a == s.vertical_alignment)
                    .unwrap_or(0);
                (cur == i, false)
            }
            Group::Direction => {
                if model.is_mixed("direction") {
                    return (false, true);
                }
                let want = if i == 0 { TextDirection::LeftToRight } else { TextDirection::RightToLeft };
                (s.direction == Some(want), false)
            }
            Group::Frame => (false, false),
            Group::FillMode => {
                if model.is_mixed("footageFill") {
                    return (false, true);
                }
                let cur = match s.footage_fill {
                    Some(TextFootageFill::Stencil) => 1,
                    Some(TextFootageFill::Inverted) => 2,
                    None => 0,
                };
                (cur == i, false)
            }
            Group::StrokePosition => {
                if model.is_mixed("stroke.position") {
                    return (false, true);
                }
                let centre = s.stroke.as_ref().is_some_and(|t| t.position == StrokePosition::Centre);
                (usize::from(centre) == i, false)
            }
            Group::SecondItalic => {
                if model.is_mixed("secondLine.italic") {
                    return (false, true);
                }
                (s.second_line.as_ref().is_some_and(|l| l.italic), false)
            }
        }
    }

    pub fn button_enabled(&self, model: &TextInspectorModel, g: Group) -> bool {
        match g {
            Group::StrokePosition => model.style().stroke.is_some(),
            Group::SecondItalic => model.style().second_line.is_some(),
            _ => true,
        }
    }

    pub fn press(&self, model: &mut TextInspectorModel, g: Group, i: usize) {
        let s = model.style().clone();
        match g {
            Group::Style => {
                let on = !self.button_state(model, g, i).0;
                match i {
                    0 => model.set_weight(if on { s.weight.max(FontWeight::Bold) } else { FontWeight::Regular }),
                    1 => model.set_italic(on),
                    2 => model.set_all_caps(on),
                    3 => model.set_underline(on),
                    4 => model.set_strikethrough(on),
                    _ => model.set_overline(on),
                }
            }
            Group::Align => {
                model.set_alignment([TextAlignment::Left, TextAlignment::Center, TextAlignment::Right][i.min(2)])
            }
            Group::Vertical => model.set_vertical_alignment(
                [TextVerticalAlignment::Top, TextVerticalAlignment::Middle, TextVerticalAlignment::Bottom][i.min(2)],
            ),
            Group::Direction => {
                // Pressing the picked one again returns to automatic.
                let picked = if i == 0 { TextDirection::LeftToRight } else { TextDirection::RightToLeft };
                let again = !model.is_mixed("direction") && s.direction == Some(picked);
                model.set_direction(if again { None } else { Some(picked) });
            }
            Group::Frame => {
                if let Some(a) = Self::ALIGN_SYMBOLS.get(i) {
                    model.align_to_frame(a.0);
                }
            }
            Group::FillMode => model
                .set_footage_fill([None, Some(TextFootageFill::Stencil), Some(TextFootageFill::Inverted)][i.min(2)]),
            Group::StrokePosition => {
                model.set_stroke_position(if i == 1 { StrokePosition::Centre } else { StrokePosition::Outside })
            }
            Group::SecondItalic => model.set_second_line_italic(!s.second_line.as_ref().is_some_and(|l| l.italic)),
        }
    }

    // MARK: Appearance rows

    pub fn check_state(&self, model: &TextInspectorModel, l: Layer) -> CheckState {
        let group = match l {
            Layer::Fill => None,
            Layer::Gradient => Some("gradient"),
            Layer::Outline => Some("stroke"),
            Layer::Background => Some("background"),
            Layer::Shadow => Some("shadow"),
            Layer::Second => Some("secondLine"),
            Layer::AutoFit => Some("autoFit"),
            Layer::List => Some("list"),
        };
        if group.is_some_and(|g| model.is_mixed_presence(g)) {
            return CheckState::Mixed;
        }
        if self.is_on(model, l) { CheckState::On } else { CheckState::Off }
    }

    pub fn is_on(&self, model: &TextInspectorModel, l: Layer) -> bool {
        let s = model.style();
        match l {
            Layer::Fill => s.color.alpha > 0.0,
            Layer::Gradient => s.gradient.is_some(),
            Layer::Outline => s.stroke.is_some(),
            Layer::Background => s.background.is_some(),
            Layer::Shadow => s.shadow.is_some(),
            Layer::Second => s.second_line.is_some(),
            Layer::AutoFit => s.auto_fit == Some(true),
            Layer::List => s.list.is_some(),
        }
    }

    pub fn toggle(&mut self, model: &mut TextInspectorModel, l: Layer) {
        let on = self.check_state(model, l) != CheckState::On;
        match l {
            Layer::Fill => {
                if model.style().color.alpha > 0.0 {
                    self.last_fill_alpha = model.style().color.alpha;
                }
                model.set_fill_alpha(if on { self.last_fill_alpha.max(0.01) } else { 0.0 });
            }
            Layer::Gradient => model.set_gradient_enabled(on),
            Layer::Outline => model.set_stroke_enabled(on),
            Layer::Background => model.set_background_enabled(on),
            Layer::Shadow => model.set_shadow_enabled(on),
            Layer::Second => model.set_second_line_enabled(on),
            Layer::AutoFit => model.set_auto_fit(on),
            Layer::List => model.set_list(if on { Some(TextListKind::Bullet) } else { None }),
        }
    }

    /// The swatch color of a row (`None` = the layer is off: the well shows the field color).
    pub fn well_color(&self, model: &TextInspectorModel, c: &Control) -> Option<RGBAColor> {
        let s = model.style();
        match c {
            Control::Well(Layer::Fill) => Some(s.color),
            Control::Well(Layer::Gradient) => s.gradient.as_ref().map(|g| g.start),
            Control::Well(Layer::Outline) => s.stroke.as_ref().map(|t| t.color),
            Control::Well(Layer::Background) => s.background.as_ref().map(|b| b.color),
            Control::Well(Layer::Shadow) => s.shadow.as_ref().map(|h| h.color),
            Control::GradientEnd => s.gradient.as_ref().map(|g| g.end),
            Control::SecondWell => s.second_line.as_ref().map(|l| l.color),
            _ => None,
        }
    }

    pub fn set_well(&self, model: &mut TextInspectorModel, c: &Control, v: RGBAColor) {
        match c {
            Control::Well(Layer::Fill) => model.set_color(v),
            Control::Well(Layer::Gradient) => model.set_gradient_start(v),
            Control::Well(Layer::Outline) => model.set_stroke_color(v),
            Control::Well(Layer::Background) => model.set_background_color(v),
            Control::Well(Layer::Shadow) => model.set_shadow_color(v),
            Control::GradientEnd => model.set_gradient_end(v),
            Control::SecondWell => model.set_second_line_color(v),
            _ => {}
        }
    }

    // MARK: Looks

    /// The applied look as the Look rows show it.
    pub fn current_look_status(&self, model: &TextInspectorModel) -> Option<LookStatus> {
        if let Some(f) = &self.look_status {
            return f();
        }
        if self.look_source.is_some() {
            return None;
        }
        let e = model.styles().entry(model.applied_style_id()?)?;
        Some(LookStatus { name: e.name, edited: model.is_style_modified(), can_update: !e.is_built_in })
    }

    // MARK: Drawing

    pub fn hover(&self) -> Option<&Control> {
        self.hover.as_ref()
    }

    pub fn draw(&mut self, model: &TextInspectorModel, c: &mut Canvas, part: Part, cx: &mut UiCx, now: f64) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        let h = self.height(model, part);
        c.fill(CGRect::new(0.0, 0.0, self.width, h), t.panel());
        self.switch_checks = part == Part::KitLook;
        for r in self.rows(model, part) {
            let label_x = ControlsGrid::LABEL_X + r.level as f64 * ControlsGrid::LEVEL_INDENT;
            if let Some(l) = &r.label {
                let rect =
                    CGRect::new(label_x, r.y, (ControlsGrid::VALUE_X - label_x - ControlsGrid::GAP).max(0.0), r.height);
                c.draw_text_in(&SQL10n::string(l), rect, fs, t.label2(), TextAlign::Left, 0.0, 0);
            }
            if let Some(i) = r.icon {
                c.draw_icon(i, CGPoint::new(label_x, r.y + ((r.height - 12.0) / 2.0).round()), 12.0, t.label2(), None);
            }
            for (k, f0) in &r.controls {
                let f = CGRect::new(f0.x, f0.y + r.y, f0.width, f0.height);
                self.draw_control(model, c, k, f, cx, now);
            }
            match r.controls.first().map(|x| &x.0) {
                Some(Control::Check(Layer::Second)) => {
                    let x = ControlsGrid::value_column(0);
                    let rect = CGRect::new(x, r.y, (self.reset_x() - ControlsGrid::GAP - x).max(0.0), r.height);
                    c.draw_text_in(&self.second_summary(model), rect, fs, t.label3(), TextAlign::Left, 0.0, 0);
                }
                Some(Control::Field(Field::Tracking)) => {
                    let x = ControlsGrid::VALUE_X + ControlsGrid::VALUE_WIDTH + ControlsGrid::GAP;
                    c.draw_icon(
                        SQIcon::MoveVertical,
                        CGPoint::new(x, r.y + ((r.height - 12.0) / 2.0).round()),
                        12.0,
                        t.label2(),
                        None,
                    );
                }
                _ => {}
            }
        }
    }

    fn draw_header(&self, c: &mut Canvas, f: CGRect, title: &str, open: bool, summary: &str, top_line: bool) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        if top_line {
            c.fill(CGRect::new(0.0, f.min_y(), self.width, 1.0), t.separator());
        }
        let dir = if open { Direction::Down } else { Direction::Right };
        InspectorDraw::chevron(
            c,
            CGRect::new(ControlsGrid::HEADER_TOGGLE_X, f.min_y(), 12.0, f.height),
            dir,
            t.label3(),
            8.0,
        );
        c.draw_text_in(
            &SQL10n::string(title),
            CGRect::new(ControlsGrid::HEADER_LABEL_X, f.min_y(), 120.0, f.height),
            fs,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        let sx = ControlsGrid::HEADER_LABEL_X + 90.0;
        let sw = (self.width - ControlsGrid::TRAILING - sx).max(0.0);
        c.draw_text_in(summary, CGRect::new(sx, f.min_y(), sw, f.height), fs, t.label3(), TextAlign::Right, 0.0, 0);
        c.fill(CGRect::new(0.0, f.max_y() - 1.0, self.width, 1.0), t.track_row_line());
    }

    fn draw_control(
        &mut self,
        model: &TextInspectorModel,
        c: &mut Canvas,
        k: &Control,
        f: CGRect,
        cx: &mut UiCx,
        now: f64,
    ) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        let hovering = self.hover.as_ref() == Some(k);
        let pressed = self.pressed.as_ref() == Some(k);
        let icon_at = |c: &mut Canvas, i: SQIcon, ink: Color| {
            c.draw_icon(i, CGPoint::new((f.mid_x() - 6.0).round(), (f.mid_y() - 6.0).round()), 12.0, ink, None);
        };
        match k {
            Control::TextHeader => {
                self.draw_header(
                    c,
                    f,
                    if self.switch_checks { "More Text Options" } else { "Text" },
                    self.text_open,
                    &self.text_summary(model),
                    false,
                );
            }
            Control::AnimationHeader => {
                self.draw_header(c, f, "Animation", self.animation_open, &self.animation_summary(model), true);
            }
            Control::TextBox => self.draw_box(c, f, cx),
            Control::Gallery => {
                self.look_gallery.width = self.width;
                self.look_gallery.current_id = model.current_look_id();
                c.save_gstate();
                c.translate_by(f.min_x(), f.min_y());
                self.look_gallery.draw(c, &t, now);
                c.restore_gstate();
            }
            Control::Font
            | Control::Weight
            | Control::Look
            | Control::SecondFont
            | Control::SecondWeight
            | Control::ListKind
            | Control::Intro
            | Control::Outro
            | Control::Animator(..)
            | Control::Token(_) => {
                let title = SQL10n::string(&self.popup_title(model, k));
                crate::ec_draw::popup(c, &title, f, hovering, false, self.popup_enabled(model, k), &t);
            }
            Control::StyleTile(i) => {
                let Some((id, name, style)) = self.style_tiles(model).into_iter().nth(*i) else { return };
                let on = model.selected_style_id().as_deref() == Some(id.as_str());
                c.fill_rounded(
                    f,
                    f64::from(radius::SMALL),
                    if hovering || pressed { t.fill_hover() } else { t.fill() },
                );
                if on {
                    c.stroke_rounded(f, f64::from(radius::SMALL), 2.0, t.accent());
                }
                super::style_sample::draw_style_sample(
                    c,
                    &style,
                    CGRect::new(f.x, f.y + 2.0, f.width, f.height - 16.0),
                );
                let label = CGRect::new(f.x + 2.0, f.max_y() - 15.0, f.width - 4.0, 14.0);
                let ink = if on { t.label() } else { t.label2() };
                c.draw_text_in(
                    &SQL10n::string(&name),
                    label,
                    f64::from(type_size::CAPTION),
                    ink,
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
            Control::LookAdd => {
                c.stone_button(f, ButtonKind::Quiet, Touch { hovering, pressed, ..Touch::default() }, &t);
                icon_at(c, SQIcon::Plus, t.label2());
            }
            Control::LookUpdate => {
                let can = self.current_look_status(model).is_some_and(|s| s.can_update);
                crate::ec_draw::button(c, &SQL10n::string("Update"), f, hovering, pressed, can, &t);
            }
            Control::LookSaveNew => {
                crate::ec_draw::button(c, &SQL10n::string("Save as New"), f, hovering, pressed, true, &t);
                let state = self.current_look_status(model).map_or(String::new(), |s| {
                    if s.edited { format!("{} \u{b7} {}", s.name, SQL10n::string("edited")) } else { s.name }
                });
                let x = f.max_x() + ControlsGrid::GAP;
                let rect = CGRect::new(x, f.min_y(), (self.value_end() - x).max(0.0), f.height);
                c.draw_text_in(&state, rect, fs, t.accent(), TextAlign::Left, 0.0, 0);
            }
            Control::Button(g, i) => {
                let (on, mixed) = self.button_state(model, *g, *i);
                let enabled = self.button_enabled(model, *g);
                let spec = Self::buttons(*g).swap_remove(*i);
                let body = CGRect::new(f.x + 1.0, f.y, (f.width - 2.0).max(0.0), f.height);
                let touch = Touch { hovering, pressed, disabled: !enabled, focused: false };
                c.stone_chip(body, on, false, touch, &t);
                let base = if on { t.label() } else { t.label2() };
                let ink = if enabled { base } else { base.with_alpha(base.a * InspectorTokens::DISABLED_ALPHA) };
                if let Some(icon) = spec.icon {
                    icon_at(c, icon, ink);
                } else if let Some(title) = spec.title {
                    c.draw_text_in(&SQL10n::string(title), f, fs, ink, TextAlign::Center, 0.0, 0);
                }
                // Multi-select: a differing switch shows a dash under its glyph.
                if mixed {
                    c.fill(CGRect::new(f.mid_x() - 4.0, f.max_y() - 3.0, 8.0, 1.0), t.label3());
                }
            }
            Control::Unit(text) => {
                c.draw_text_in(&SQL10n::string(text), f, fs, t.label3(), TextAlign::Left, 0.0, 0);
            }
            Control::Check(l) if self.switch_checks => {
                let touch = Touch { hovering, pressed, ..Touch::default() };
                c.stone_switch(f, self.is_on(model, *l), touch, &t);
            }
            Control::Check(l) => {
                let boxed = CGRect::new(f.min_x(), f.min_y(), 14.0, 14.0);
                InspectorDraw::checkbox(c, self.check_state(model, *l), boxed, hovering, pressed, true, false, &t);
            }
            Control::Well(_) | Control::GradientEnd | Control::SecondWell => match self.well_color(model, k) {
                Some(col) => {
                    let ink = Color::new(col.red as f32, col.green as f32, col.blue as f32, col.alpha.max(0.15) as f32);
                    InspectorDraw::color_well(c, ink, f, hovering, &t);
                }
                None => InspectorDraw::color_well(c, t.field(), f, false, &t),
            },
            Control::Eyedropper(l) => {
                let on = self.is_on(model, *l);
                if on {
                    c.stone_button(f, ButtonKind::Quiet, Touch { hovering, pressed, ..Touch::default() }, &t);
                }
                let base = t.label2();
                icon_at(
                    c,
                    SQIcon::Eyedropper,
                    if on { base } else { base.with_alpha(base.a * InspectorTokens::DISABLED_ALPHA) },
                );
            }
            Control::Chevron(l) => {
                let dir = if self.open_layers.contains(l) { Direction::Down } else { Direction::Right };
                InspectorDraw::chevron(c, f, dir, if hovering { t.label() } else { t.label3() }, 8.0);
            }
            Control::Field(fl) => {
                let focused = self.focused.as_ref() == Some(fl);
                let fd = self.field(model, fl);
                fd.hovering = hovering;
                fd.draw(c, f, &t, focused, cx);
            }
            Control::Slider(fl) => {
                let (field, track) = Self::slider_parts(f);
                let sp = self.spec(model, fl);
                let (value, enabled) = (self.value(model, fl), self.is_enabled(model, fl));
                let focused = self.focused.as_ref() == Some(fl);
                let fd = self.field(model, fl);
                fd.hovering = hovering;
                fd.draw(c, field, &t, focused, cx);
                let frac = (value - sp.range.0) / (sp.range.1 - sp.range.0).max(1e-9);
                InspectorDraw::slider(c, frac, 0.0, track, enabled, &t);
            }
        }
    }

    /// The text box: the field capsule grown to its lines; while typing, the open editor (line by line, caret and
    /// selection on their lines).
    fn draw_box(&self, c: &mut Canvas, f: CGRect, cx: &mut UiCx) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        let r = f64::from(sq_uikit::redesign_tokens::radius::CONTROL);
        let touch = Touch { hovering: self.hover == Some(Control::TextBox), ..Touch::default() };
        c.stone_field(f, r, self.editor.is_some(), touch, &t);
        let inner = CGRect::new(f.x + 8.0, f.y + 4.0, (f.width - 16.0).max(0.0), (f.height - 8.0).max(0.0));
        if let Some(e) = &self.editor {
            InspectorDraw::edit_lines(c, e, inner, Self::LINE_HEIGHT, fs, t.label(), &t, cx);
            return;
        }
        c.save_gstate();
        c.clip_to(inner);
        for (i, line) in self.box_text.split('\n').enumerate() {
            let rect = CGRect::new(inner.x, inner.y + i as f64 * Self::LINE_HEIGHT, inner.width, Self::LINE_HEIGHT);
            c.draw_text_in(line, rect, fs, t.label(), TextAlign::Left, 0.0, 0);
        }
        c.restore_gstate();
    }

    // MARK: Pointer

    /// What the block asks of its host since the last call.
    pub fn take_requests(&mut self) -> Vec<BlockRequest> {
        std::mem::take(&mut self.requests)
    }

    pub fn is_typing(&self) -> bool {
        self.editor.is_some()
    }

    /// True while the Look gallery previews a hovered look: the host keeps redrawing at display rate.
    pub fn is_animating(&self) -> bool {
        self.shows_look_gallery && self.animation_open && self.look_gallery.tick()
    }

    /// The caret index under `p` (part coordinates) in the open box.
    fn box_caret(
        &self,
        model: &TextInspectorModel,
        e: &TextEditState,
        p: CGPoint,
        part: Part,
        measure: Option<&Canvas>,
    ) -> Option<usize> {
        let f = self.frame(model, &Control::TextBox, part)?;
        let inner = CGRect::new(f.x + 8.0, f.y + 4.0, (f.width - 16.0).max(0.0), (f.height - 8.0).max(0.0));
        Some(InspectorDraw::caret_index_at(measure?, e, p, inner, Self::LINE_HEIGHT, f64::from(type_size::BODY)))
    }

    pub fn control_at(&self, model: &TextInspectorModel, p: CGPoint, part: Part) -> Option<Control> {
        for r in self.rows(model, part) {
            if p.y < r.y || p.y >= r.y + r.height {
                continue;
            }
            for (k, f) in r.controls.iter().filter(|(k, _)| !matches!(k, Control::Unit(_))) {
                let hit = CGRect::new(f.x, f.y + r.y, f.width, f.height);
                let wide = if *k == Control::TextBox { hit } else { CGRect::new(hit.x, r.y, hit.width, r.height) };
                if wide.contains(p) {
                    return Some(k.clone());
                }
            }
            // The Appearance title opens and closes its detail rows like the chevron.
            if let Some((Control::Check(l), _)) = r.controls.first()
                && l.has_detail()
                && p.x >= ControlsGrid::LABEL_X
                && p.x < ControlsGrid::VALUE_X
            {
                return Some(Control::Chevron(*l));
            }
        }
        None
    }

    /// `p` (animation part coordinates) in the gallery's coordinates.
    fn gallery_point(&self, model: &TextInspectorModel, p: CGPoint) -> Option<CGPoint> {
        self.frame(model, &Control::Gallery, Part::Animation).map(|f| CGPoint::new(p.x - f.x, p.y - f.y))
    }

    pub fn mouse_moved(&mut self, model: &TextInspectorModel, p: Option<CGPoint>, part: Part, now: f64) {
        if self.slider_drag.is_some() || self.field_press.is_some() {
            return;
        }
        self.hover = p.and_then(|q| self.control_at(model, q, part));
        if part == Part::Animation {
            let gp =
                if self.hover == Some(Control::Gallery) { p.and_then(|q| self.gallery_point(model, q)) } else { None };
            self.look_gallery.mouse_moved(gp, now);
        }
    }

    pub fn mouse_down(
        &mut self,
        model: &mut TextInspectorModel,
        p: CGPoint,
        part: Part,
        click_count: Option<i64>,
        measure: Option<&Canvas>,
        cx: &mut UiCx,
    ) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let k = self.control_at(model, p, part);
        if let Some(fl) = self.focused.clone()
            && k != Some(Control::Field(fl.clone()))
            && k != Some(Control::Slider(fl))
        {
            self.resign_focus(model, cx);
        }
        if k != Some(Control::TextBox) {
            self.end_typing();
        }
        let Some(k) = k else { return };
        self.pressed = Some(k.clone());
        self.press_part = part;
        match &k {
            Control::Gallery => {
                if let Some(q) = self.gallery_point(model, p) {
                    self.look_gallery.mouse_down(q);
                }
            }
            Control::TextBox => {
                if self.editor.is_none() {
                    self.editor = Some(TextEditState::with_select_all(&self.box_text, false));
                    self.typed = false;
                }
                // A click places the caret, a triple click selects everything.
                if let Some(mut e) = self.editor.take() {
                    if let Some(i) = self.box_caret(model, &e, p, part, measure) {
                        if n >= 3 {
                            e.select_all();
                        } else if n == 2 {
                            e.place(i, false);
                            e.select_word(i);
                        } else {
                            e.place(i, false);
                        }
                    }
                    self.editor = Some(e);
                }
            }
            Control::Field(fl) => {
                if !self.is_enabled(model, fl) {
                    return;
                }
                let ev = self.field(model, fl).mouse_down(p.x as f32, n);
                self.apply(model, ev, fl);
                self.field_press = Some(fl.clone());
                self.focused = Some(fl.clone());
            }
            Control::Slider(fl) => {
                let Some(f) = self.frame(model, &k, part) else { return };
                if !self.is_enabled(model, fl) {
                    return;
                }
                let (field, track) = Self::slider_parts(f);
                if p.x < field.max_x() {
                    let ev = self.field(model, fl).mouse_down(p.x as f32, n);
                    self.apply(model, ev, fl);
                    self.field_press = Some(fl.clone());
                    self.focused = Some(fl.clone());
                } else {
                    self.slider_drag = Some(fl.clone());
                    model.begin_editing();
                    self.set_from_slider(model, fl, p.x, track);
                }
            }
            _ => {
                if let Some(items) = self.menu_for(model, &k)
                    && let Some(anchor) = self.frame(model, &k, part)
                {
                    self.pressed = None;
                    if !items.is_empty() {
                        self.requests.push(BlockRequest::Menu { items, anchor, part });
                    }
                }
            }
        }
    }

    pub fn mouse_dragged(
        &mut self,
        model: &mut TextInspectorModel,
        p: CGPoint,
        modifiers: InputModifiers,
        measure: Option<&Canvas>,
        cx: &mut UiCx,
    ) {
        let part = self.press_part;
        if self.pressed == Some(Control::TextBox)
            && let Some(mut e) = self.editor.take()
        {
            if let Some(i) = self.box_caret(model, &e, p, part, measure) {
                e.place(i, true); // drag-select in the box
            }
            self.editor = Some(e);
            return;
        }
        if let Some(fl) = self.slider_drag.clone() {
            if let Some(f) = self.frame(model, &Control::Slider(fl.clone()), part) {
                self.set_from_slider(model, &fl, p.x, Self::slider_parts(f).1);
            }
        } else if let Some(fl) = self.field_press.clone() {
            let scale = self.theme.scale;
            let ev = self.field(model, &fl).mouse_dragged(p.x as f32, modifiers, scale, cx);
            self.apply(model, ev, &fl);
        }
    }

    pub fn mouse_up(&mut self, model: &mut TextInspectorModel, p: CGPoint, part: Part, cx: &mut UiCx) {
        self.mouse_released(model, p, part, cx);
        self.pressed = None;
        self.mouse_moved(model, Some(p), part, cx.now);
    }

    fn mouse_released(&mut self, model: &mut TextInspectorModel, p: CGPoint, part: Part, cx: &mut UiCx) {
        if self.slider_drag.take().is_some() {
            model.end_editing();
            return;
        }
        if let Some(fl) = self.field_press.take() {
            let ev = self.field(model, &fl).mouse_up(cx);
            self.apply(model, ev, &fl);
            return;
        }
        if self.pressed == Some(Control::Gallery) && part == Part::Animation {
            let q = self.gallery_point(model, p).unwrap_or(CGPoint::new(-1.0, -1.0));
            self.look_gallery.mouse_up(q);
            return;
        }
        let Some(k) = self.pressed.clone() else { return };
        if part != self.press_part || self.control_at(model, p, part).as_ref() != Some(&k) {
            return;
        }
        match &k {
            Control::TextHeader => {
                self.set_text_open(!self.text_open);
            }
            Control::AnimationHeader => {
                self.set_animation_open(!self.animation_open);
            }
            Control::Button(g, i) => {
                if self.button_enabled(model, *g) {
                    self.press(model, *g, *i);
                }
            }
            Control::Check(l) => self.toggle(model, *l),
            Control::Chevron(l) => self.set_layer_open(*l, !self.open_layers.contains(l)),
            Control::StyleTile(i) => {
                if let Some((id, ..)) = self.style_tiles(model).into_iter().nth(*i) {
                    self.run_command(model, BlockCommand::PickStyle(id));
                    self.height_changed = true;
                }
            }
            Control::LookAdd | Control::LookSaveNew => {
                self.save_look_as_new(model);
                self.height_changed = true;
            }
            Control::LookUpdate => {
                if self.current_look_status(model).is_some_and(|s| s.can_update) {
                    self.update_look(model);
                }
                self.height_changed = true;
            }
            Control::Well(_) | Control::GradientEnd | Control::SecondWell => self.pick_color(model, &k, part),
            Control::Eyedropper(l) if self.is_on(model, *l) => self.requests.push(BlockRequest::SampleColor(*l)),
            _ => {}
        }
    }

    fn set_from_slider(&self, model: &mut TextInspectorModel, fl: &Field, x: f64, track: CGRect) {
        let sp = self.spec(model, fl);
        let raw = sp.range.0 + InspectorDraw::slider_fraction(x, track) * (sp.range.1 - sp.range.0);
        self.set(model, fl, (raw / sp.step).round() * sp.step);
    }

    /// The SQ color picker through the host: one picker session is one undo step; the layer keeps its own opacity.
    fn pick_color(&mut self, model: &mut TextInspectorModel, k: &Control, part: Part) {
        let (Some(cur), Some(anchor)) = (self.well_color(model, k), self.frame(model, k, part)) else { return };
        if self.color_open {
            model.end_editing();
            self.color_open = false;
        }
        self.requests.push(BlockRequest::PickColor {
            control: k.clone(),
            current: EffectColor { red: cur.red, green: cur.green, blue: cur.blue, alpha: cur.alpha },
            anchor,
            part,
        });
    }

    /// The picker of `control` changed (`Some`) or closed (`None`).
    pub fn color_changed(&mut self, model: &mut TextInspectorModel, control: &Control, color: Option<EffectColor>) {
        let Some(color) = color else {
            if self.color_open {
                self.color_open = false;
                model.end_editing();
            }
            return;
        };
        if !self.color_open {
            self.color_open = true;
            model.begin_editing();
        }
        let alpha = self.well_color(model, control).map_or(1.0, |c| c.alpha);
        self.set_well(model, control, RGBAColor::new(color.red, color.green, color.blue, alpha));
    }

    /// An eyedropper answered: the picked color is one undo step and the layer keeps its opacity.
    pub fn color_sampled(&mut self, model: &mut TextInspectorModel, l: Layer, picked: Option<SQColorValue>) {
        let Some(picked) = picked else { return };
        let well = Control::Well(l);
        let alpha = self.well_color(model, &well).map_or(1.0, |c| c.alpha);
        let (r, g, b) = picked.rgb();
        model.begin_editing();
        self.set_well(model, &well, RGBAColor::new(r, g, b, alpha));
        model.end_editing();
    }

    // MARK: Keys

    /// Keys for the text box or the focused value field; false when neither has them.
    pub fn key(
        &mut self,
        model: &mut TextInspectorModel,
        k: InputKey,
        modifiers: InputModifiers,
        cx: &mut UiCx,
    ) -> bool {
        if let Some(mut e) = self.editor.take() {
            // Return breaks the line (the box is multi-line); the box ends with Esc, Tab or a click elsewhere.
            if k == InputKey::Escape || k == InputKey::Character('\t') {
                self.editor = Some(e);
                self.end_typing();
                return true;
            }
            let outcome = e.handle_lines(k, modifiers, cx);
            let text = e.string();
            self.editor = Some(e);
            if outcome != Outcome::Edited {
                return true;
            }
            if !self.typed {
                self.typed = true;
                self.requests.push(BlockRequest::TextBegin);
            }
            self.box_text = text.clone();
            self.requests.push(BlockRequest::TextChange(text));
            self.height_changed = true;
            return true;
        }
        let Some(fl) = self.focused.clone() else { return false };
        if k == InputKey::Character('\t') {
            let ev = self.field(model, &fl).resign_focus(cx);
            self.apply(model, ev, &fl);
            self.move_focus(model, &fl, modifiers.contains(InputModifiers::SHIFT));
            return true;
        }
        let fd = self.field(model, &fl);
        let (ev, used) = fd.key_used(k, modifiers, cx.now, cx);
        let ended = !fd.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
        self.apply(model, ev, &fl);
        if ended {
            self.focused = None;
        }
        used
    }

    /// Tab order: the enabled value fields shown, top to bottom.
    fn move_focus(&mut self, model: &TextInspectorModel, fl: &Field, backward: bool) {
        let mut order: Vec<Field> = Vec::new();
        for part in [Part::Text, Part::Arrange, Part::Animation] {
            for r in self.rows(model, part) {
                for (k, _) in r.controls {
                    if let Control::Field(x) | Control::Slider(x) = k
                        && self.is_enabled(model, &x)
                    {
                        order.push(x);
                    }
                }
            }
        }
        let Some(i) = order.iter().position(|x| x == fl) else {
            self.focused = None;
            return;
        };
        let next = (i + if backward { order.len() - 1 } else { 1 }) % order.len();
        self.focused = Some(order[next].clone());
    }

    fn end_typing(&mut self) {
        if self.editor.take().is_none() {
            return;
        }
        if self.typed {
            self.requests.push(BlockRequest::TextEnd);
        }
        self.typed = false;
        self.box_text = self.text.clone();
    }

    /// Puts the caret at the end of the text box; false when the box is hidden.
    pub fn focus_text_box(&mut self, model: &mut TextInspectorModel, cx: &mut UiCx) -> bool {
        if !self.shows_text_box {
            return false;
        }
        if self.focused.is_some() {
            self.resign_focus(model, cx);
        }
        if self.editor.is_none() {
            let mut e = TextEditState::with_select_all(&self.box_text, false);
            e.place(e.text().len(), false);
            self.editor = Some(e);
            self.typed = false;
        }
        true
    }

    pub fn resign_focus(&mut self, model: &mut TextInspectorModel, cx: &mut UiCx) {
        self.end_typing();
        let Some(fl) = self.focused.take() else { return };
        let ev = self.field(model, &fl).resign_focus(cx);
        self.apply(model, ev, &fl);
    }

    /// Per frame: ends arrow / wheel step bursts (one undo step each).
    pub fn tick(&mut self, model: &mut TextInspectorModel, now: f64) {
        let keys: Vec<Field> = self.fields.keys().cloned().collect();
        for fl in keys {
            let Some(fd) = self.fields.get_mut(&fl) else { continue };
            let ev = fd.tick(now);
            self.apply(model, ev, &fl);
        }
    }

    pub fn help(&self, model: &TextInspectorModel, p: CGPoint, part: Part) -> Option<String> {
        let row_tip =
            || self.rows(model, part).into_iter().find(|r| p.y >= r.y && p.y < r.y + r.height).and_then(|r| r.tip);
        let Some(k) = self.control_at(model, p, part) else { return row_tip().map(|t| SQL10n::string(&t)) };
        let layer_tip = |l: Layer, suffix: &str| format!("{}{suffix}", l.title());
        let tip: Option<String> = match &k {
            Control::TextHeader => Some(if self.text_open { "Collapse Text" } else { "Expand Text" }.to_string()),
            Control::AnimationHeader => {
                Some(if self.animation_open { "Collapse Animation" } else { "Expand Animation" }.to_string())
            }
            Control::Font => Some("Font".into()),
            Control::Weight => Some("Weight".into()),
            Control::Look => Some("Look".into()),
            Control::StyleTile(_) => Some("Apply this style to the text".into()),
            Control::LookAdd => Some("Save Current as Look".into()),
            Control::LookUpdate => Some("Update the Look".into()),
            Control::LookSaveNew => Some("Save as New Look".into()),
            Control::Button(g, i) => Self::buttons(*g).get(*i).map(|b| b.tip.to_string()),
            Control::Check(l) => Some(l.title().to_string()),
            Control::Chevron(l) => {
                Some(if self.open_layers.contains(l) { "Hide Details" } else { "Show Details" }.into())
            }
            Control::Well(Layer::Gradient) => Some("Gradient Start Color".into()),
            Control::Well(l) => Some(layer_tip(*l, " Color")),
            Control::Field(Field::Animator(_, AnimatorControl::Loops)) => Some("Loop Count".into()),
            Control::Field(Field::Animator(_, AnimatorControl::Distance)) => Some("Slide Distance".into()),
            Control::Field(Field::Animator(_, AnimatorControl::Blur)) => Some("Start Blur".into()),
            Control::Field(Field::Animator(_, AnimatorControl::Stagger)) => Some("Stagger".into()),
            Control::Field(Field::Animator(_, AnimatorControl::Length)) => Some("Unit Length".into()),
            Control::Eyedropper(l) => Some(format!("Pick {} Color", l.title())),
            Control::GradientEnd => Some("Gradient End Color".into()),
            Control::SecondWell => Some("Second Line Color".into()),
            Control::SecondFont => Some("Second Line Font".into()),
            Control::SecondWeight => Some("Second Line Weight".into()),
            Control::ListKind => Some("List Style".into()),
            Control::Intro => Some("Intro".into()),
            Control::Outro => Some("Outro".into()),
            Control::Field(Field::Tracking) => Some("Letter Spacing (px)".into()),
            Control::Field(Field::Leading) => Some("Line Spacing (px)".into()),
            Control::Field(Field::InLength) => Some("Intro Length".into()),
            Control::Field(Field::OutLength) => Some("Outro Length".into()),
            Control::Slider(Field::Size) => Some("Size".into()),
            Control::Token(f) => {
                let name = if *f == TokenField::Font { "Font" } else { "Color" };
                return Some(SQL10n::format("Follow %@ Token", &[&SQL10n::string(name)]));
            }
            Control::Gallery => {
                return self.gallery_point(model, p).and_then(|q| self.look_gallery.help(q));
            }
            _ => row_tip(),
        };
        tip.map(|t| SQL10n::string(&t))
    }

    // MARK: Looks and menus

    /// The Look popup's title.
    pub fn look_title(&self, model: &TextInspectorModel) -> String {
        if let Some(f) = &self.look_source {
            let src = f();
            return src
                .selected
                .as_ref()
                .and_then(|id| src.ids.iter().position(|i| i == id))
                .and_then(|i| src.titles.get(i).cloned())
                .unwrap_or_else(|| SQL10n::string("Custom"));
        }
        model
            .selected_style_id()
            .and_then(|id| model.styles().entry(&id).map(|e| e.name))
            .unwrap_or_else(|| SQL10n::string("Custom"))
    }

    fn item(&self, title: &str, checked: bool, cmd: BlockCommand) -> SQMenuItem {
        let sink = Rc::clone(&self.menu_sink);
        let mut i = SQMenuItem::new(title);
        i.title = title.to_string();
        i.is_checked = checked;
        i.action = Some(Rc::new(move || sink.borrow_mut().push(cmd.clone())));
        i
    }

    pub fn look_menu(&self, model: &TextInspectorModel) -> Vec<SQMenuItem> {
        if let Some(f) = &self.look_source {
            let src = f();
            return src
                .titles
                .iter()
                .zip(&src.ids)
                .map(|(t, id)| {
                    self.item(t, src.selected.as_ref() == Some(id), BlockCommand::PickSourceLook(id.clone()))
                })
                .collect();
        }
        let sel = model.selected_style_id();
        model
            .styles()
            .entries()
            .into_iter()
            .map(|e| self.item(&e.name, sel.as_deref() == Some(&e.id), BlockCommand::PickStyle(e.id.clone())))
            .collect()
    }

    fn font_menu(
        &self,
        model: &TextInspectorModel,
        current: Option<&str>,
        cmd: fn(String) -> BlockCommand,
    ) -> Vec<SQMenuItem> {
        model.font_families().iter().map(|f| self.item(f, current == Some(f), cmd(f.clone()))).collect()
    }

    fn weight_menu(&self, current: Option<FontWeight>, cmd: fn(FontWeight) -> BlockCommand) -> Vec<SQMenuItem> {
        Self::WEIGHTS.iter().map(|(t, w)| self.item(t, current == Some(*w), cmd(*w))).collect()
    }

    /// Off, the presets, the saved animations, Custom; a Custom side can also be saved.
    fn animation_menu(&self, model: &TextInspectorModel, side: AnimationSide) -> Vec<SQMenuItem> {
        let custom = model.is_custom(side);
        let mut ids = if side == AnimationSide::Intro { model.in_animation_ids() } else { model.out_animation_ids() };
        ids.push(AnimationChoices::CUSTOM_ID.to_string());
        if custom && model.can_save_animations() {
            ids.push(AnimationChoices::SAVE_ID.to_string());
        }
        let shown = if custom {
            Some(AnimationChoices::CUSTOM_ID.to_string())
        } else if side == AnimationSide::Intro {
            model.selected_in_id()
        } else {
            model.selected_out_id()
        };
        ids.into_iter()
            .map(|id| {
                let title = model.animation_choice_title(&id, side);
                self.item(&title, shown.as_deref() == Some(&id), BlockCommand::Animation(id, side))
            })
            .collect()
    }

    /// The popup of a control; `None` while it takes no input.
    pub fn menu_for(&self, model: &TextInspectorModel, c: &Control) -> Option<Vec<SQMenuItem>> {
        let s = model.style();
        match c {
            Control::Font => {
                let cur = (!model.is_mixed("fontName")).then(|| s.font_name.clone());
                Some(self.font_menu(model, cur.as_deref(), BlockCommand::Font))
            }
            Control::Weight => {
                Some(self.weight_menu((!model.is_mixed("weight")).then_some(s.weight), BlockCommand::Weight))
            }
            Control::Look => Some(self.look_menu(model)),
            Control::SecondFont => {
                let l = s.second_line.as_ref()?;
                Some(self.font_menu(model, Some(&l.font_name), BlockCommand::SecondFont))
            }
            Control::SecondWeight => {
                let l = s.second_line.as_ref()?;
                Some(self.weight_menu(Some(l.weight), BlockCommand::SecondWeight))
            }
            Control::ListKind => {
                s.list?;
                Some(
                    [("Bullets", TextListKind::Bullet), ("Numbers", TextListKind::Numbered)]
                        .into_iter()
                        .map(|(t, k)| self.item(t, s.list == Some(k), BlockCommand::List(k)))
                        .collect(),
                )
            }
            Control::Intro => Some(self.animation_menu(model, AnimationSide::Intro)),
            Control::Outro => Some(self.animation_menu(model, AnimationSide::Outro)),
            Control::Animator(side, k) => self.animator_menu(model, *side, *k),
            Control::Token(f) => {
                if !f.is_available(s) {
                    return None;
                }
                let bound = model.bound_token(*f);
                let mut v = vec![self.item("Literal", bound.is_none(), BlockCommand::Token(*f, None))];
                v.extend(
                    model
                        .token_names(*f)
                        .into_iter()
                        .map(|n| self.item(&n.clone(), bound.as_deref() == Some(&n), BlockCommand::Token(*f, Some(n)))),
                );
                Some(v)
            }
            _ => None,
        }
    }

    /// One popup of a text animator side; `None` while it takes no input.
    fn animator_menu(
        &self,
        model: &TextInspectorModel,
        side: AnimatorSide,
        k: AnimatorControl,
    ) -> Option<Vec<SQMenuItem>> {
        let a = model.animator(side);
        if !TextAnimatorChoices::is_enabled(k, a) {
            return None;
        }
        // "None" shows its check while there is no animator.
        Some(match k {
            AnimatorControl::Effect => TextAnimatorChoices::effects()
                .into_iter()
                .map(|(t, v)| self.item(t, v == a.map(|a| a.effect), BlockCommand::Effect(v, side)))
                .collect(),
            AnimatorControl::Unit => TextAnimatorChoices::units()
                .into_iter()
                .map(|(t, v)| self.item(t, Some(v) == a.map(|a| a.unit), BlockCommand::Unit(v, side)))
                .collect(),
            AnimatorControl::Easing => TextAnimatorChoices::easings()
                .into_iter()
                .map(|(t, v)| self.item(t, Some(v) == a.map(|a| a.easing), BlockCommand::Easing(v, side)))
                .collect(),
            AnimatorControl::Direction => TextAnimatorChoices::directions()
                .into_iter()
                .map(|(t, v)| self.item(t, Some(v) == a.map(|a| a.direction), BlockCommand::Direction(v, side)))
                .collect(),
            AnimatorControl::Order => TextAnimatorChoices::orders()
                .into_iter()
                .map(|(t, v)| self.item(t, Some(v) == a.map(|a| a.order), BlockCommand::Order(v, side)))
                .collect(),
            _ => return None,
        })
    }

    pub fn animator_title(&self, model: &TextInspectorModel, side: AnimatorSide, k: AnimatorControl) -> String {
        let a = model.animator(side);
        fn title<T: PartialEq + Copy>(list: &[(&'static str, T)], cur: Option<T>) -> String {
            list.iter().find(|(_, v)| Some(*v) == cur).or(list.first()).map_or(String::new(), |(t, _)| (*t).to_string())
        }
        match k {
            AnimatorControl::Effect => TextAnimatorChoices::effects()
                .iter()
                .find(|(_, v)| *v == a.map(|a| a.effect))
                .map_or("None", |(t, _)| t)
                .to_string(),
            AnimatorControl::Unit => title(&TextAnimatorChoices::units(), a.map(|a| a.unit)),
            AnimatorControl::Easing => title(&TextAnimatorChoices::easings(), a.map(|a| a.easing)),
            AnimatorControl::Direction => title(&TextAnimatorChoices::directions(), a.map(|a| a.direction)),
            AnimatorControl::Order => title(&TextAnimatorChoices::orders(), a.map(|a| a.order)),
            _ => String::new(),
        }
    }

    pub fn popup_title(&self, model: &TextInspectorModel, c: &Control) -> String {
        let s = model.style();
        let weight_name = |w: FontWeight| Self::WEIGHTS.iter().find(|x| x.1 == w).map_or("", |x| x.0).to_string();
        match c {
            Control::Font => {
                if model.is_mixed("fontName") {
                    String::new()
                } else {
                    s.font_name.clone()
                }
            }
            Control::Weight => {
                if model.is_mixed("weight") {
                    String::new()
                } else {
                    weight_name(s.weight)
                }
            }
            Control::Look => self.look_title(model),
            Control::SecondFont => {
                if model.is_mixed("secondLine.fontName") {
                    String::new()
                } else {
                    s.second_line.as_ref().map_or_else(|| s.font_name.clone(), |l| l.font_name.clone())
                }
            }
            Control::SecondWeight => {
                if model.is_mixed("secondLine.weight") {
                    String::new()
                } else {
                    weight_name(s.second_line.as_ref().map_or(FontWeight::Regular, |l| l.weight))
                }
            }
            Control::ListKind => {
                (if s.list == Some(TextListKind::Numbered) { "Numbers" } else { "Bullets" }).to_string()
            }
            Control::Intro => model.animation_title(AnimationSide::Intro),
            Control::Outro => model.animation_title(AnimationSide::Outro),
            Control::Animator(side, k) => self.animator_title(model, *side, *k),
            Control::Token(f) => model
                .bound_token(*f)
                .filter(|n| model.token_names(*f).contains(n))
                .unwrap_or_else(|| "Literal".to_string()),
            _ => String::new(),
        }
    }

    pub fn popup_enabled(&self, model: &TextInspectorModel, c: &Control) -> bool {
        match c {
            Control::SecondFont | Control::SecondWeight => model.style().second_line.is_some(),
            Control::ListKind => model.style().list.is_some(),
            Control::Animator(side, k) => TextAnimatorChoices::is_enabled(*k, model.animator(*side)),
            Control::Token(f) => f.is_available(model.style()),
            _ => true,
        }
    }

    /// One line under the Second Line title.
    pub fn second_summary(&self, model: &TextInspectorModel) -> String {
        let s = model.style();
        let weight = |w: FontWeight| Self::WEIGHTS.iter().find(|x| x.1 == w).map_or("", |x| x.0);
        match &s.second_line {
            Some(l) => format!("{} \u{b7} {} \u{b7} {:.1} px", l.font_name, weight(l.weight), l.size),
            None => format!("{} \u{b7} Regular \u{b7} {:.1} px", s.font_name, s.size * 2.0 / 3.0),
        }
    }

    pub fn text_summary(&self, model: &TextInspectorModel) -> String {
        if model.is_mixed("fontName") {
            return String::new();
        }
        format!("{} \u{b7} {}", model.style().font_name, model.style().size.round() as i64)
    }

    pub fn animation_summary(&self, model: &TextInspectorModel) -> String {
        format!(
            "{}: {} \u{b7} {}: {}",
            SQL10n::string("Intro"),
            model.animation_title(AnimationSide::Intro),
            SQL10n::string("Outro"),
            model.animation_title(AnimationSide::Outro)
        )
    }

    /// Asks the host for a name; the command made from it is queued, not at all when canceled or empty.
    fn name(&mut self, title: &str, initial: &str, make: impl FnOnce(String) -> BlockCommand + 'static) {
        let sink = Rc::clone(&self.menu_sink);
        let Some(ask) = self.ask_name.as_mut() else {
            sink.borrow_mut().push(make(initial.to_string()));
            return;
        };
        ask(
            title,
            initial,
            Box::new(move |typed| {
                if let Some(n) = typed.map(|t| t.trim().to_string()).filter(|n| !n.is_empty()) {
                    sink.borrow_mut().push(make(n));
                }
            }),
        );
    }

    fn save_look_as_new(&mut self, model: &TextInspectorModel) {
        if let Some(f) = self.on_save_look_as_new.as_mut() {
            f();
            return;
        }
        if let Some(src) = &self.look_source {
            let mut s = src();
            if let Some(add) = s.add.as_mut() {
                add();
            }
            return;
        }
        let base = model.applied_style_id().and_then(|id| model.styles().entry(id)).map(|e| e.name);
        let initial = base.map_or_else(|| "My Look".to_string(), |b| format!("{b} 2"));
        self.name("Save as New Look", &initial, BlockCommand::SaveStyleNamed);
    }

    /// Right-click on the Look popup: the host's menu, else the model's text looks.
    pub fn look_context_items(&self, model: &TextInspectorModel) -> Vec<SQMenuItem> {
        if let Some(f) = &self.look_context {
            return f();
        }
        let cmd = |c: BlockCommand| {
            let sink = Rc::clone(&self.menu_sink);
            let a: Rc<dyn Fn()> = Rc::new(move || sink.borrow_mut().push(c.clone()));
            a
        };
        let save_new = cmd(BlockCommand::SaveLookAsNew);
        let editable = if self.look_source.is_none() {
            model.applied_style_id().and_then(|id| model.styles().entry(id)).filter(|e| !e.is_built_in)
        } else {
            None
        };
        match editable {
            None => TextAnimatorChoices::look_menu_items(
                None,
                cmd(BlockCommand::UpdateLook),
                save_new,
                cmd(BlockCommand::UpdateLook),
                cmd(BlockCommand::UpdateLook),
            ),
            Some(e) => TextAnimatorChoices::look_menu_items(
                Some(&e.name),
                cmd(BlockCommand::UpdateStyle(e.id.clone())),
                save_new,
                cmd(BlockCommand::AskRename(e.id.clone(), e.name.clone())),
                cmd(BlockCommand::DeleteStyle(e.id)),
            ),
        }
    }

    /// The Update button.
    pub fn update_look(&mut self, model: &mut TextInspectorModel) {
        if let Some(f) = self.on_update_look.as_mut() {
            f();
        } else if let Some(id) = model.applied_style_id().map(str::to_string) {
            model.update_style_from_current(&id);
        }
    }

    /// Runs what the closed menu's rows queued (and what a name prompt queued after them).
    pub fn run_menu_commands(&mut self, model: &mut TextInspectorModel) {
        loop {
            let commands: Vec<_> = self.menu_sink.borrow_mut().drain(..).collect();
            if commands.is_empty() {
                break;
            }
            for c in commands {
                self.run_command(model, c);
            }
        }
    }

    fn run_command(&mut self, model: &mut TextInspectorModel, c: BlockCommand) {
        match c {
            BlockCommand::Font(f) => model.set_font_family(&f),
            BlockCommand::Weight(w) => model.set_weight(w),
            BlockCommand::PickStyle(id) => model.apply_style(&id),
            BlockCommand::PickSourceLook(id) => {
                if let Some(f) = &self.look_source {
                    (f().pick)(&id);
                }
            }
            BlockCommand::SecondFont(f) => model.set_second_line_font(&f),
            BlockCommand::SecondWeight(w) => model.set_second_line_weight(w),
            BlockCommand::List(k) => model.set_list(Some(k)),
            BlockCommand::Animation(id, side) => self.pick_animation(model, &id, side),
            BlockCommand::Effect(e, side) => model.set_animator_effect(e, side),
            BlockCommand::Unit(u, side) => model.set_animator_unit(u, side),
            BlockCommand::Easing(e, side) => model.set_animator_easing(e, side),
            BlockCommand::Direction(d, side) => model.set_animator_direction(d, side),
            BlockCommand::Order(o, side) => model.set_animator_order(o, side),
            BlockCommand::Token(f, n) => model.bind_token(f, n.as_deref()),
            BlockCommand::SaveLookAsNew => self.save_look_as_new(model),
            BlockCommand::SaveStyleNamed(n) => {
                model.save_current_as_style(&n);
                self.height_changed = true;
            }
            BlockCommand::UpdateLook => self.update_look(model),
            BlockCommand::UpdateStyle(id) => {
                model.update_style_from_current(&id);
                self.height_changed = true;
            }
            BlockCommand::AskRename(id, name) => {
                self.name("Rename Look", &name, move |n| BlockCommand::RenameStyle(id, n))
            }
            BlockCommand::RenameStyle(id, n) => {
                model.rename_style(&id, &n);
                self.height_changed = true;
            }
            BlockCommand::DeleteStyle(id) => {
                model.delete_style(&id);
                self.height_changed = true;
            }
            BlockCommand::SaveAnimationNamed(side, n) => {
                if !model.save_custom_animation(side, &n) {
                    self.notice(SQL10n::format(
                        "The %@ animation could not be saved: it has no keyframes, or the Library is not available.",
                        &[&SQL10n::string(side.title())],
                    ));
                }
                self.height_changed = true;
            }
        }
    }

    fn notice(&mut self, text: String) {
        if let Some(f) = self.on_notice.as_mut() {
            f(text);
        }
    }

    fn pick_animation(&mut self, model: &mut TextInspectorModel, id: &str, side: AnimationSide) {
        if id != AnimationChoices::SAVE_ID {
            model.set_animation(id, side);
            return;
        }
        let t = SQL10n::string(side.title());
        self.name(&SQL10n::format("Save %@ Animation", &[&t]), &SQL10n::format("My %@", &[&t]), move |n| {
            BlockCommand::SaveAnimationNamed(side, n)
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::anchored_animation::AnimationSet;
    use sq_core_time::SequentialIds;
    use sq_draw::{Canvas, UiCx};
    use sq_text::caption_presets::CaptionPresetLibrary;
    use sq_text::text_style::TextStyle;

    use crate::text::style_library::TextStyleLibrary;

    fn model() -> TextInspectorModel {
        TextInspectorModel::new(
            TextStyle::default(),
            AnimationSet::new(None, None),
            Some(CaptionPresetLibrary::built_in()),
            Box::new(Vec::new),
            TextStyleLibrary::default(),
            Box::new(SequentialIds::default()),
        )
    }

    #[test]
    fn closed_text_section_is_only_its_header() {
        let mut b = TextBlockDraw::new();
        let m = model();
        b.set_text_open(false);
        let rows = b.rows(&m, Part::Text);
        assert_eq!(rows.len(), 1);
        assert_eq!(b.height(&m, Part::Text), TextBlockDraw::ROW);
    }

    #[test]
    fn text_box_row_follows_the_flag_and_grows_with_lines() {
        let mut b = TextBlockDraw::new();
        let m = model();
        let with_box = b.height(&m, Part::Text);
        b.shows_text_box = false;
        let without = b.height(&m, Part::Text);
        assert_eq!(with_box - without, 2.0 * TextBlockDraw::LINE_HEIGHT + 16.0);
        b.shows_text_box = true;
        b.set_text("a\nb\nc\nd");
        assert_eq!(b.box_height(), 4.0 * TextBlockDraw::LINE_HEIGHT + 8.0);
    }

    #[test]
    fn layer_detail_rows_appear_when_opened() {
        let mut b = TextBlockDraw::new();
        let m = model();
        let closed = b.rows(&m, Part::Text).len();
        b.set_layer_open(Layer::Background, true);
        assert!(b.take_height_changed());
        assert_eq!(b.rows(&m, Part::Text).len(), closed + 4);
        assert!(b.frame(&m, &Control::Slider(Field::Radius), Part::Text).is_some());
    }

    #[test]
    fn fields_report_values_and_enabled_state() {
        let b = TextBlockDraw::new();
        let mut m = model();
        assert!(!b.is_enabled(&m, &Field::PadX));
        assert_eq!(b.value(&m, &Field::ShadowOpacity), 60.0);
        m.set_background_enabled(true);
        assert!(b.is_enabled(&m, &Field::PadX));
        b.set(&mut m, &Field::PadX, 12.0);
        assert_eq!(b.value(&m, &Field::PadX), 12.0);
    }

    #[test]
    fn style_buttons_edit_the_model() {
        let b = TextBlockDraw::new();
        let mut m = model();
        assert!(!b.button_state(&m, Group::Style, 0).0);
        b.press(&mut m, Group::Style, 0);
        assert!(b.button_state(&m, Group::Style, 0).0);
        b.press(&mut m, Group::Style, 0);
        assert_eq!(m.style().weight, FontWeight::Regular);
        b.press(&mut m, Group::Align, 2);
        assert_eq!(m.style().alignment, TextAlignment::Right);
        b.press(&mut m, Group::Direction, 0);
        b.press(&mut m, Group::Direction, 0);
        assert_eq!(m.style().direction, None);
    }

    #[test]
    fn fill_toggle_remembers_the_alpha() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        m.set_fill_alpha(0.5);
        b.toggle(&mut m, Layer::Fill);
        assert_eq!(m.style().color.alpha, 0.0);
        b.toggle(&mut m, Layer::Fill);
        assert_eq!(m.style().color.alpha, 0.5);
    }

    #[test]
    fn well_color_follows_the_layer() {
        let b = TextBlockDraw::new();
        let mut m = model();
        assert_eq!(b.well_color(&m, &Control::Well(Layer::Outline)), None);
        let c = RGBAColor::new(1.0, 0.0, 0.0, 1.0);
        m.set_stroke_enabled(true);
        b.set_well(&mut m, &Control::Well(Layer::Outline), c);
        assert_eq!(b.well_color(&m, &Control::Well(Layer::Outline)), Some(c));
    }

    fn run(b: &mut TextBlockDraw, m: &mut TextInspectorModel, items: &[SQMenuItem], title: &str) {
        let item = items.iter().find(|i| i.title == title).expect("menu row");
        (item.action.as_ref().expect("action"))();
        b.run_menu_commands(m);
    }

    #[test]
    fn weight_menu_sets_the_weight_and_checks_the_current() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        let items = b.menu_for(&m, &Control::Weight).expect("menu");
        assert!(items.iter().find(|i| i.title == "Regular").expect("row").is_checked);
        run(&mut b, &mut m, &items, "Bold");
        assert_eq!(m.style().weight, FontWeight::Bold);
        assert_eq!(b.popup_title(&m, &Control::Weight), "Bold");
    }

    #[test]
    fn second_line_popups_are_closed_while_the_layer_is_off() {
        let b = TextBlockDraw::new();
        let mut m = model();
        assert!(b.menu_for(&m, &Control::SecondFont).is_none());
        assert!(!b.popup_enabled(&m, &Control::SecondWeight));
        m.set_second_line_enabled(true);
        assert!(b.menu_for(&m, &Control::SecondWeight).is_some());
    }

    #[test]
    fn effect_menu_creates_an_animator() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        let side = AnimatorSide::In;
        assert_eq!(b.animator_title(&m, side, AnimatorControl::Effect), "None");
        let items = b.menu_for(&m, &Control::Animator(side, AnimatorControl::Effect)).expect("menu");
        run(&mut b, &mut m, &items, "Fade");
        assert_eq!(b.animator_title(&m, side, AnimatorControl::Effect), "Fade");
        assert!(b.menu_for(&m, &Control::Animator(side, AnimatorControl::Unit)).is_some());
    }

    #[test]
    fn save_look_as_new_without_a_prompt_takes_the_suggested_name() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        let before = m.styles().entries().len();
        b.menu_sink.borrow_mut().push(BlockCommand::SaveLookAsNew);
        b.run_menu_commands(&mut m);
        assert_eq!(m.styles().entries().len(), before + 1);
        assert!(b.take_height_changed());
    }

    #[test]
    fn save_look_as_new_asks_the_host_for_a_name_and_saves_what_comes_back() {
        let asks = NameAsks::default();
        let mut b = TextBlockDraw::new();
        b.ask_name = Some(asks.ask());
        let mut m = model();
        let before = m.styles().entries().len();
        b.menu_sink.borrow_mut().push(BlockCommand::SaveLookAsNew);
        b.run_menu_commands(&mut m);
        let mut asked = asks.take();
        assert_eq!(asked.len(), 1, "the + asks, it does not stay silent");
        assert_eq!((asked[0].title.as_str(), asked[0].initial.as_str()), ("Save as New Look", "My Look"));
        assert_eq!(m.styles().entries().len(), before, "nothing is saved before the answer");
        (asked.remove(0).done)(Some("  Mine  ".into()));
        b.run_menu_commands(&mut m);
        assert_eq!(m.styles().entries().len(), before + 1);
        assert_eq!(m.applied_style_id().and_then(|id| m.styles().entry(id)).map(|e| e.name), Some("Mine".to_string()));
    }

    #[test]
    fn canceled_name_prompt_saves_nothing() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        b.ask_name = Some(Box::new(|_, _, done| done(None)));
        let before = m.styles().entries().len();
        b.menu_sink.borrow_mut().push(BlockCommand::SaveLookAsNew);
        b.run_menu_commands(&mut m);
        assert_eq!(m.styles().entries().len(), before);
    }

    #[test]
    fn drawing_every_part_without_an_atlas_does_not_panic() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        b.set_text("Hello\nworld");
        b.set_animation_open(true);
        b.set_shows_look_gallery(true);
        m.set_background_enabled(true);
        for l in Layer::ALL {
            b.set_layer_open(l, true);
        }
        let mut c = Canvas::with_size(320.0, 2000.0, None, 1.0);
        for part in [Part::Text, Part::Arrange, Part::Animation] {
            b.draw(&m, &mut c, part, &mut UiCx::new(), 0.0);
        }
    }

    #[test]
    fn header_summaries_name_the_font_and_the_animations() {
        let b = TextBlockDraw::new();
        let m = model();
        assert_eq!(b.text_summary(&m), format!("{} \u{b7} {}", m.style().font_name, m.style().size.round() as i64));
        assert!(b.animation_summary(&m).contains("Intro"));
        assert!(b.second_summary(&m).ends_with(" px"));
    }

    fn center(r: CGRect) -> CGPoint {
        CGPoint::new(r.mid_x(), r.mid_y())
    }

    fn click(b: &mut TextBlockDraw, m: &mut TextInspectorModel, k: &Control, part: Part) {
        let p = center(b.frame(m, k, part).expect("frame"));
        let mut cx = UiCx::new();
        b.mouse_down(m, p, part, Some(1), None, &mut cx);
        b.mouse_up(m, p, part, &mut cx);
    }

    #[test]
    fn style_tiles_follow_the_panel_width_up_to_the_frames_size() {
        let width_of = |w: f64| {
            let mut b = TextBlockDraw::new();
            b.width = w;
            let m = model();
            let row =
                b.rows(&m, Part::Text).into_iter().find(|r| r.label.as_deref() == Some("Style")).expect("Style row");
            let f: Vec<CGRect> = row.controls.iter().map(|c| c.1).collect();
            (f.len(), f[0].width, f.last().map_or(0.0, CGRect::max_x))
        };
        let (n_narrow, w_narrow, _) = width_of(300.0);
        let (n_wide, w_wide, right) = width_of(400.0);
        let (_, w_huge, _) = width_of(900.0);
        assert!(w_narrow >= TextBlockDraw::STYLE_TILE_W && w_wide >= w_narrow && n_wide >= n_narrow);
        assert_eq!(w_huge, TextBlockDraw::STYLE_TILE_MAX_W);
        assert!(right <= 400.0, "the tiles stay inside the panel");
    }

    #[test]
    fn the_style_row_shows_named_tiles_and_a_click_applies_the_style() {
        let mut b = TextBlockDraw::new();
        b.width = 400.0;
        let mut m = model();
        let names: Vec<String> = b.style_tiles(&m).into_iter().map(|t| t.1).collect();
        assert_eq!(names, ["Title", "Lower Third", "Outline", "Pill"]);
        let row = b.rows(&m, Part::Text).into_iter().find(|r| r.label.as_deref() == Some("Style")).expect("Style row");
        assert!(row.controls.iter().all(|(k, _)| matches!(k, Control::StyleTile(_))) && !row.controls.is_empty());
        let before = m.style().clone();
        click(&mut b, &mut m, &Control::StyleTile(1), Part::Text);
        assert_ne!(*m.style(), before);
        assert_eq!(m.selected_style_id().as_deref(), Some("lower-third"));
    }

    #[test]
    fn clicking_a_style_button_edits_the_model() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        click(&mut b, &mut m, &Control::Button(Group::Style, 1), Part::Text);
        assert!(m.style().italic);
    }

    #[test]
    fn clicking_the_title_of_a_layer_opens_its_details() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        let row = b.rows(&m, Part::Text).into_iter().find(|r| r.label.as_deref() == Some("Shadow")).expect("row");
        let p = CGPoint::new(ControlsGrid::LABEL_X + 4.0, row.y + row.height / 2.0);
        let mut cx = UiCx::new();
        b.mouse_down(&mut m, p, Part::Text, Some(1), None, &mut cx);
        b.mouse_up(&mut m, p, Part::Text, &mut cx);
        assert!(b.open_layers().contains(&Layer::Shadow));
        assert!(b.take_height_changed());
    }

    #[test]
    fn clicking_a_popup_requests_its_menu() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        click(&mut b, &mut m, &Control::Weight, Part::Text);
        let reqs = b.take_requests();
        assert!(matches!(reqs.as_slice(), [BlockRequest::Menu { part: Part::Text, .. }]));
    }

    #[test]
    fn dragging_a_slider_is_one_undo_step() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        let f = b.frame(&m, &Control::Slider(Field::Size), Part::Text).expect("frame");
        let (_, track) = TextBlockDraw::slider_parts(f);
        let mut cx = UiCx::new();
        b.mouse_down(&mut m, CGPoint::new(track.min_x() + 10.0, track.mid_y()), Part::Text, Some(1), None, &mut cx);
        b.mouse_dragged(&mut m, CGPoint::new(track.max_x(), track.mid_y()), InputModifiers::NONE, None, &mut cx);
        b.mouse_up(&mut m, CGPoint::new(track.max_x(), track.mid_y()), Part::Text, &mut cx);
        assert_eq!(m.style().size, 400.0);
    }

    #[test]
    fn color_picker_session_keeps_the_layer_opacity() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        m.set_fill_alpha(0.5);
        let well = Control::Well(Layer::Fill);
        click(&mut b, &mut m, &well, Part::Text);
        assert!(matches!(b.take_requests().as_slice(), [BlockRequest::PickColor { .. }]));
        b.color_changed(&mut m, &well, Some(EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 }));
        b.color_changed(&mut m, &well, None);
        assert_eq!(m.style().color.red, 1.0);
        assert_eq!(m.style().color.alpha, 0.5);
    }

    #[test]
    fn tab_moves_the_focus_between_enabled_fields() {
        let mut b = TextBlockDraw::new();
        let mut m = model();
        let f = b.frame(&m, &Control::Field(Field::Tracking), Part::Text).expect("frame");
        let mut cx = UiCx::new();
        b.mouse_down(&mut m, center(f), Part::Text, Some(1), None, &mut cx);
        b.mouse_up(&mut m, center(f), Part::Text, &mut cx);
        assert_eq!(b.focused(), Some(&Field::Tracking));
        assert!(b.key(&mut m, InputKey::Character('\t'), InputModifiers::NONE, &mut cx));
        assert_eq!(b.focused(), Some(&Field::Leading));
    }

    #[test]
    fn help_names_the_control_under_the_pointer() {
        let b = TextBlockDraw::new();
        let m = model();
        let f = b.frame(&m, &Control::Button(Group::Style, 0), Part::Text).expect("frame");
        assert_eq!(b.help(&m, center(f), Part::Text).as_deref(), Some("Bold"));
    }

    #[test]
    fn open_sections_and_layers_come_back_from_the_settings_store() {
        let store = crate::open_state::SharedDefaults::default();
        let mut a = TextBlockDraw::new();
        a.set_defaults(Box::new(store.clone()));
        a.set_text_open(false);
        a.set_animation_open(true);
        a.set_layer_open(Layer::Shadow, true);
        let mut b = TextBlockDraw::new();
        assert!(b.text_open() && !b.animation_open());
        b.set_defaults(Box::new(store));
        assert!(!b.text_open() && b.animation_open());
        assert!(b.open_layers.contains(&Layer::Shadow) && !b.open_layers.contains(&Layer::Fill));
    }
    #[test]
    fn the_text_box_is_a_stone_field_not_a_hand_drawn_capsule() {
        let b = TextBlockDraw::new();
        let f = CGRect::new(10.0, 10.0, 200.0, 60.0);
        let mut c = Canvas::with_size(320.0, 100.0, None, 1.0);
        b.draw_box(&mut c, f, &mut UiCx::new());
        let at = |radius: f32| {
            c.list.quads().iter().any(|q| {
                q.stroke == 0.0
                    && (q.rect.x, q.rect.y, q.rect.w, q.rect.h) == (10.0, 10.0, 200.0, 60.0)
                    && q.radius == radius
            })
        };
        assert!(at(4.0), "a field well of radius control");
        assert!(!at(6.0), "no old capsule radius");
    }
}
