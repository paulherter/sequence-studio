// Swift: Draw/CaptionStyleTabDraw.swift
//! The Look tab of the Captions panel on the shared toolkit. The scope switch (All Captions / Selected), the caption
//! track (two or more tracks), the Looks gallery, the Captions section (Animation, Word Highlight), the shared text
//! block (font, format, Fill, Outline, Background, Shadow; its Look row = the caption looks), Position, the look
//! buttons, the Style Kit section (Look to Kit, Animation from Text Clip, the brand tokens) and the hint. Every edit
//! goes through `EditorSession`, one undo step per gesture; every call that edits takes the session (the Swift class
//! held it). Coordinates: points, y down, (0, 0) = the tab's top-left.
//
// The open state of the sections is remembered in the injected settings store (`set_defaults`), like `TextBlockDraw`.
// shortcut: saved caption looks go through `CaptionLookHost` (synchronous); the Swift class awaited the Look library
// on the main actor. The host bridges its async store.
// known limit: the text block's screen color sampler and its text box requests are dropped (the Look tab has no text box
// and the host sets no sampler).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::open_state::{read_open, write_open};
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{
    CaptionHorizontal, CaptionPosition, CaptionVertical, EffectColor, KaraokeStyle, MotionDefaults, StyleKit,
};
use sq_core_time::{Id, IdSource, Time};
use sq_draw::inspector::inspector_controls::{CheckState, InspectorDraw, InspectorTokens};
use sq_draw::inspector::scrub_field_control::{ClickCounter, Event as ScrubEvent, ScrubFieldControl};
use sq_draw::stone::Touch;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_editor_session::{CaptionStyleEdit, CaptionStyleField, CaptionStyleMark, CaptionStyleScope, EditorSession};
use sq_text::caption_karaoke::CaptionKaraoke;
use sq_text::caption_pill::CaptionPill;
use sq_text::caption_presets::CaptionLook;
use sq_text::caption_style_looks::CaptionStyleLook;
use sq_text::text_style::{RGBAColor, TextStyle};
use sq_transcribe::caption_preset::CaptionPreset;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::color::look_gallery_draw::LookGalleryDraw;
use crate::ec::inspector_text_formats::AnimationPresetName;
use crate::text::block_draw::Control as BlockControl;
use crate::text::block_draw::{AskNameFn, BlockRequest, LookSource, Part, TextBlockDraw};
use crate::text::inspector_model::{TextInspectorEvent, TextInspectorModel};
use crate::text::style_library::TextStyleLibrary;

/// Largest caption offset, a fraction of the frame (`CaptionPosition` clamps to it).
const MAX_OFFSET: f64 = 0.5;

/// Caption offset as the Offset fields show it: percent of the canvas, Y up like Position (stored fraction, Y down).
pub enum CaptionOffsetDisplay {}

impl CaptionOffsetDisplay {
    pub fn shown(stored: f64, is_y: bool) -> f64 {
        // + 0: never "-0"
        ((if is_y { -stored } else { stored }) * 1000.0).round() / 10.0 + 0.0
    }

    pub fn stored(shown: f64, is_y: bool) -> f64 {
        (if is_y { -shown } else { shown }) / 100.0 + 0.0
    }
}

/// The Style Kit's motion defaults as the Look tab edits them.
pub enum CaptionKitMotion {}

impl CaptionKitMotion {
    /// What a Style Kit without motion defaults starts new motion effects with (the field's reset value).
    pub const DEFAULT_SECONDS: f64 = 0.5;

    /// The motion duration in seconds as a kit time: whole milliseconds, 0.001...600 s. `None` for NaN / infinity / <= 0.
    pub fn time(seconds: f64) -> Option<Time> {
        if !seconds.is_finite() || seconds <= 0.0 {
            return None;
        }
        // The value is in 1...600_000 here, so the cast cannot saturate.
        Some(Time::new((seconds.min(600.0) * 1000.0).round() as i64, 1000))
    }
}

/// The sections of the tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    /// The style gallery (a start), then every look control: font, fill, outline, background, shadow, highlight.
    Look,
    /// Position of the caption block.
    Layout,
    /// The caption animation, apart from the look.
    Motion,
    Kit,
}

impl Section {
    pub const ALL: [Section; 4] = [Section::Look, Section::Layout, Section::Motion, Section::Kit];

    pub fn raw_value(self) -> &'static str {
        match self {
            Section::Look => "captions.style.look",
            Section::Layout => "captions.style.layout",
            Section::Motion => "captions.style.motion",
            Section::Kit => "captions.look.kit",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Section::Look => "Look",
            Section::Layout => "Layout",
            Section::Motion => "Motion",
            Section::Kit => "Style Kit",
        }
    }

    fn default_open(self) -> bool {
        self != Section::Kit
    }
}

/// What can be hovered, pressed or focused.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    Scope(usize),
    Track,
    Header(Section),
    Animation,
    Karaoke,
    KaraokeWell,
    KaraokeKeep,
    Vertical(usize),
    Horizontal(usize),
    Offset {
        is_y: bool,
    },
    ResetPosition,
    SaveLook,
    UpdateLook,
    /// A saved style of the MINE group, and its star (the default for Create Captions).
    Mine(usize),
    MineStar(usize),
    /// A named built-in style of the BUILT IN group.
    BuiltIn(usize),
    ResetLook,
    KitLook,
    TextAnim,
    BrandFont(String),
    BrandColor(String),
    MotionDuration,
    MotionCurve,
}

/// What a row of an open menu (or a finished name prompt) does once the host runs `run_commands`.
#[derive(Clone, Debug, PartialEq)]
enum StyleCommand {
    FocusTrack(Id),
    Animation(String),
    EditLook(String),
    BrandFont(String, String),
    MotionCurve(i64),
    SaveLookClicked,
    SaveLookNamed(Option<String>),
}

/// Whose color the open picker edits.
#[derive(Clone, Debug, PartialEq)]
enum ColorTarget {
    Block(BlockControl),
    Karaoke,
    Brand(String),
}

/// The saved caption looks (Swift `CaptionLookLibrary.shared`): the host bridges its Look store.
pub trait CaptionLookHost {
    /// How many looks are saved (names the next one).
    fn looks_count(&self) -> usize;
    /// The id of the default look, if one is saved.
    fn default_look_id(&self) -> Option<String>;
    /// Saves a new look as the default for Create Captions; its id, or `None` when it could not be saved.
    fn save(&mut self, name: &str, look: &CaptionLook, segmentation: &CaptionPreset) -> Option<String>;
    /// Replaces the look of a saved look; false when it could not be updated.
    fn update(&mut self, id: &str, look: &CaptionLook) -> bool;
    /// The saved styles for the MINE group: id, name, whether it is the default (the star).
    fn saved(&self) -> Vec<(String, String, bool)>;
    /// The look a saved style holds.
    fn look_of(&self, id: &str) -> Option<CaptionLook>;
    /// How the saved style `id` stands against the current look ("Edited", the star); `None` when it is gone.
    fn mark(&self, id: &str, current: &CaptionLook) -> Option<CaptionStyleMark>;
    /// Moves the star to `id` (`None` clears it); false when the style is unknown.
    fn set_default(&mut self, id: Option<&str>) -> bool;
}

type Notify<T> = Option<Box<dyn FnMut(T)>>;
/// Opens a menu: the rows and the anchor (tab points).
pub type MenuFn = Box<dyn FnMut(Vec<SQMenuItem>, CGRect)>;
/// Opens the SQ color picker for the current color at the anchor (tab points); the host answers with `color_picked`.
pub type PickColorFn = Box<dyn FnMut(EffectColor, CGRect)>;

enum Item {
    Control(Control, CGRect),
    Label(String, CGRect, bool),
    Header(Section, CGRect, bool),
    Strong(String, CGRect),
    Gallery(f64),
    Block(f64),
    Hint(CGRect),
    /// The amber "Edited" marker.
    Edited(CGRect),
    /// The line under the style grid.
    Note(CGRect),
}

enum Hit {
    Control(Control),
    Block(CGPoint),
    Gallery(CGPoint),
}

#[derive(Clone, Debug, PartialEq)]
enum Press {
    Control(Control),
    Block,
    Gallery,
}

pub struct CaptionStyleTabDraw {
    pub theme: DrawTheme,
    size: CGSize,
    pub on_status: Notify<String>,
    /// Popups: the shell's menu at the anchor. The rows queue commands: the host calls `run_commands` once it closes.
    pub on_menu: Option<MenuFn>,
    /// A swatch: the host opens the SQ color picker; answer each change with `color_picked(Some(..))` and the close
    /// with `color_picked(None)`.
    pub on_pick_color: Option<PickColorFn>,
    /// Asks for a name (Save Current as Look...); `None` = the suggested name is taken. Call `run_commands` after the
    /// answer.
    pub ask_name: Option<AskNameFn>,
    /// The caption preset a saved look keeps (the Mac `CaptionsPanelModel.selectedPreset`).
    pub segmentation: Box<dyn Fn() -> CaptionPreset>,
    /// The saved looks; without it the look buttons do nothing.
    pub look_host: Option<Box<dyn CaptionLookHost>>,
    scope: CaptionStyleScope,

    /// The same model and rows as the Text panel; its edits become caption style fields (`CaptionStyleEdit::fields`).
    pub inspector_model: TextInspectorModel,
    pub block: TextBlockDraw,
    pub gallery: LookGalleryDraw,
    /// The saved styles shown as MINE tiles (id, name, star), the one the user picked or saved last, and how it stands.
    mine: Vec<(String, String, bool)>,
    /// The named built-in styles of the BUILT IN group (id, name, style), shown above the animated gallery.
    built_ins: Vec<(String, String, TextStyle)>,
    picked_look: Option<String>,
    mark: Option<CaptionStyleMark>,

    had_selection: bool,
    has_captions: bool,
    has_selection: bool,
    state_shown: bool,
    tracks: Vec<(Id, String)>,
    track_index: Option<usize>,
    track_enabled: bool,
    reset_look_enabled: bool,
    look_ids: Vec<String>,
    look_selected_id: Option<String>,
    animation_ids: Vec<String>,
    animation_selected_id: Option<String>,
    position: CaptionPosition,
    reset_position_enabled: bool,
    karaoke: Option<KaraokeStyle>,
    /// The highlight color the well shows (kept while the picker is open, applied when it closes).
    karaoke_color: RGBAColor,
    karaoke_keep: bool,
    text_anim_enabled: bool,
    hint: String,
    kit: StyleKit,

    /// The style the inspector last showed or sent (as `CaptionStyleEdit::display_style`): the baseline of the next diff.
    shown_style: Option<TextStyle>,
    /// An inspector edit gesture is open (scrub, color drag): a reload from the session would fight it.
    inspector_gesture_open: bool,
    /// The next inspector change starts a new undo step (first change after `BeginEditing`).
    inspector_gesture_fresh: bool,
    /// The next offset change starts a new undo step.
    offset_gesture_fresh: bool,
    motion_started: bool,
    /// Consecutive changes of one control within a second are one undo step (a color drag, stepper clicks).
    last_edit: Option<(Control, f64)>,
    /// The brand color well whose picker is open: it holds its undo step however slow the changes come.
    picker_well: Option<Control>,
    color_target: Option<ColorTarget>,

    fields: HashMap<Control, ScrubFieldControl>,
    focused: Option<Control>,
    open: HashMap<Section, bool>,
    defaults: Option<Box<dyn UiDefaults>>,
    scroll_y: f64,
    hover: Option<Control>,
    pressed: Option<Control>,
    press: Option<Press>,
    counter: ClickCounter,
    /// Seconds of the host's clock at the last event or frame.
    now: f64,
    /// Text widths measured with the canvas the panel drew last (segments, buttons); no atlas: 7 points per letter.
    widths: HashMap<String, f64>,
    hint_lines: usize,
    sink: Rc<RefCell<Vec<StyleCommand>>>,
}

impl CaptionStyleTabDraw {
    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.lg 16 below the stack, the
    // SQSegmented small height 22 and 12 pt label insets, the 38 x 20 swatch; upgrade when SQUIKit's tokens move into a
    // portable file.
    pub const SEGMENT_HEIGHT: f64 = 22.0;
    pub const SEGMENT_INSET: f64 = 12.0;
    pub const ICON_SEGMENT: f64 = 28.0;
    pub const SWATCH: CGSize = CGSize { width: 38.0, height: 20.0 };
    pub const BOTTOM_PAD: f64 = 16.0;
    pub const BRAND_LABEL_WIDTH: f64 = 96.0;
    pub const MOTION_FIELD_WIDTH: f64 = 64.0;
    pub const HINT_LINE: f64 = 15.0;
    pub const VERTICAL_TITLES: [&'static str; 3] = ["Top", "Middle", "Bottom"];
    pub const HORIZONTAL_ICONS: [(SQIcon, &'static str); 3] =
        [(SQIcon::TextAlignLeft, "Left"), (SQIcon::TextAlignCenter, "Center"), (SQIcon::TextAlignRight, "Right")];
    const VERTICALS: [CaptionVertical; 3] = [CaptionVertical::Top, CaptionVertical::Middle, CaptionVertical::Bottom];
    const HORIZONTALS: [CaptionHorizontal; 3] =
        [CaptionHorizontal::Left, CaptionHorizontal::Center, CaptionHorizontal::Right];

    /// Attaches the Library's keystones to the tab's text model: saved animations show in the Intro / Outro popups of the
    /// caption style and Save Custom stores one (the same source as the Graphics panel).
    pub fn set_animation_keystones(&mut self, source: Rc<dyn crate::ec::animation::AnimationKeystoneSource>) {
        self.inspector_model.keystones = Some(source);
    }

    /// `font_families`: the installed families (the brand font menu and the block's font menu).
    pub fn new(font_families: Box<dyn Fn() -> Vec<String>>, ids: Box<dyn IdSource>) -> CaptionStyleTabDraw {
        let inspector_model = TextInspectorModel::new(
            TextStyle::default(),
            AnimationSet::new(None, None),
            None,
            font_families,
            TextStyleLibrary::default(),
            ids,
        );
        let mut block = TextBlockDraw::new();
        block.shows_text_box = false;
        let mut fields = HashMap::new();
        for is_y in [false, true] {
            let mut f = ScrubFieldControl::new(0.0);
            f.range = -100.0 * MAX_OFFSET..=100.0 * MAX_OFFSET;
            f.step = 0.5;
            f.decimals = 1;
            f.unit = "%".to_string();
            f.default_value = Some(0.0);
            fields.insert(Control::Offset { is_y }, f);
        }
        let mut m = ScrubFieldControl::new(CaptionKitMotion::DEFAULT_SECONDS);
        m.range = 0.05..=600.0;
        m.step = 0.05;
        m.decimals = 2;
        m.unit = "s".to_string();
        m.default_value = Some(CaptionKitMotion::DEFAULT_SECONDS);
        fields.insert(Control::MotionDuration, m);
        let open = Section::ALL.iter().map(|s| (*s, s.default_open())).collect();
        let mut d = CaptionStyleTabDraw {
            theme: DrawTheme::default(),
            size: CGSize { width: 320.0, height: 480.0 },
            on_status: None,
            on_menu: None,
            on_pick_color: None,
            ask_name: None,
            segmentation: Box::new(CaptionPreset::standard),
            look_host: None,
            scope: CaptionStyleScope::All,
            inspector_model,
            block,
            gallery: LookGalleryDraw::built_in(),
            mine: Vec::new(),
            built_ins: TextStyleLibrary::built_ins().into_iter().map(|e| (e.id, e.name, e.style)).collect(),
            picked_look: None,
            mark: None,
            had_selection: false,
            has_captions: false,
            has_selection: false,
            state_shown: false,
            tracks: Vec::new(),
            track_index: None,
            track_enabled: true,
            reset_look_enabled: false,
            look_ids: Vec::new(),
            look_selected_id: None,
            animation_ids: Vec::new(),
            animation_selected_id: None,
            position: default_position(),
            reset_position_enabled: false,
            karaoke: None,
            karaoke_color: RGBAColor::new(1.0, 0.86, 0.1, 1.0),
            karaoke_keep: false,
            text_anim_enabled: false,
            hint: String::new(),
            kit: StyleKit::default(),
            shown_style: None,
            inspector_gesture_open: false,
            inspector_gesture_fresh: true,
            offset_gesture_fresh: true,
            motion_started: false,
            last_edit: None,
            picker_well: None,
            color_target: None,
            fields,
            focused: None,
            open,
            defaults: None,
            scroll_y: 0.0,
            hover: None,
            pressed: None,
            press: None,
            counter: ClickCounter::new(),
            now: 0.0,
            widths: HashMap::new(),
            hint_lines: 2,
            sink: Rc::new(RefCell::new(Vec::new())),
        };
        d.block.width = d.size.width;
        d.block.kit_key = true;
        d.block.set_text_open(false);
        d.gallery.width = d.size.width;
        d
    }

    pub fn size(&self) -> CGSize {
        self.size
    }

    pub fn set_size(&mut self, size: CGSize) {
        self.size = size;
        self.block.width = size.width;
        self.gallery.width = size.width;
        self.clamp_scroll();
    }

    /// Applies `theme` to the block as well.
    pub fn set_theme(&mut self, theme: DrawTheme) {
        self.theme = theme;
        self.block.theme = theme;
    }

    pub fn scope(&self) -> CaptionStyleScope {
        self.scope
    }

    pub fn scroll_y(&self) -> f64 {
        self.scroll_y
    }

    /// Remembers the section state in `defaults` and takes the stored state now.
    pub fn set_defaults(&mut self, defaults: Box<dyn UiDefaults>) {
        for s in Section::ALL {
            if let Some(open) = read_open(defaults.as_ref(), &TextBlockDraw::section_key(s.raw_value())) {
                self.open.insert(s, open);
            }
        }
        self.defaults = Some(defaults);
    }

    pub fn is_open(&self, s: Section) -> bool {
        self.open.get(&s).copied().unwrap_or_else(|| s.default_open())
    }

    pub fn focused(&self) -> Option<&Control> {
        self.focused.as_ref()
    }

    /// The Karaoke style the tab shows.
    pub fn karaoke(&self) -> Option<&KaraokeStyle> {
        self.karaoke.as_ref()
    }

    /// True once there is a caption style to show (a caption track exists).
    pub fn state_shown(&self) -> bool {
        self.state_shown
    }

    // MARK: Session to UI

    pub fn refresh(&mut self, s: &EditorSession) {
        self.has_captions = !s.caption_items().is_empty();
        self.has_selection = !s.caption_selection().is_empty();
        // Selecting a caption (list or timeline) edits that caption; clearing the selection goes back to the track look.
        if self.has_selection != self.had_selection {
            self.scope = if self.has_selection { CaptionStyleScope::Selected } else { CaptionStyleScope::All };
            self.had_selection = self.has_selection;
        }
        if self.scope == CaptionStyleScope::Selected && !self.has_selection {
            self.scope = CaptionStyleScope::All;
        }
        let all = s.active_timeline().map(|t| t.caption_tracks.clone()).unwrap_or_default();
        self.tracks = all
            .iter()
            .map(|t| (t.id, if t.name.is_empty() { "Captions".to_string() } else { t.name.clone() }))
            .collect();
        self.track_index = s.current_caption_track().and_then(|cur| all.iter().position(|t| t.id == cur.id));
        self.track_enabled = s.caption_selection().is_empty();
        self.reset_look_enabled = s.selected_captions_have_overrides();
        self.gallery.current_id = s.current_caption_style_look().map(|l| l.id);
        self.mine = self.look_host.as_ref().map(|h| h.saved()).unwrap_or_default();
        let current = s.current_caption_look();
        let built_in = |id: &String| self.built_ins.iter().any(|b| Self::built_in_key(&b.0) == *id);
        if self.picked_look.as_ref().is_some_and(|id| !built_in(id) && !self.mine.iter().any(|m| &m.0 == id)) {
            self.picked_look = None;
        }
        self.mark = match (&self.picked_look, &current, &self.look_host) {
            (Some(id), Some(look), Some(h)) => h.mark(id, look),
            _ => None,
        };

        let state = s.caption_style_state(self.scope);
        self.look_ids = CaptionStyleEdit::built_in_style_ids();
        self.look_selected_id = state.as_ref().and_then(|st| st.base_id.clone());
        self.animation_ids = CaptionStyleEdit::built_in_animation_ids();
        self.animation_selected_id = state.as_ref().and_then(|st| st.animation_id.clone());
        if let Some(st) = state.as_ref() {
            let shown = CaptionStyleEdit::display_style(&st.style);
            self.shown_style = Some(shown.clone());
            // Not while the user drags a field: the session value is rounded and would pull the control away.
            if !self.inspector_gesture_open && *self.inspector_model.style() != shown {
                self.inspector_model.load(shown.clone(), AnimationSet::new(None, None));
            }
            // A box switched on in a caption is the caption pill (round ends, built-in padding), not a text clip's box.
            self.inspector_model.seed_layer_defaults(Some(CaptionPill::background(&shown, None)), None, None);
            self.drain_model_events(None);
        }
        self.state_shown = state.is_some();
        self.set_look_source();

        let selected_ids = s.caption_selection();
        let own = self.scope == CaptionStyleScope::Selected && self.has_selection;
        self.position = if own {
            s.caption_items()
                .iter()
                .find(|c| selected_ids.contains(&c.id))
                .map(|c| s.effective_caption_position(c))
                .unwrap_or_else(|| s.caption_position())
        } else {
            s.caption_position()
        };
        self.reset_position_enabled =
            s.caption_items().iter().any(|c| c.position.is_some() && (!own || selected_ids.contains(&c.id)));
        for is_y in [false, true] {
            let k = Control::Offset { is_y };
            let (shown, enabled) = (
                CaptionOffsetDisplay::shown(if is_y { self.position.offset_y } else { self.position.offset_x }, is_y),
                self.state_shown,
            );
            if let Some(f) = self.fields.get_mut(&k)
                && !f.is_dragging()
                && !f.is_editing()
            {
                f.value = shown;
                f.is_enabled = enabled;
            }
        }

        self.karaoke = s.caption_karaoke();
        if let Some(k) = &self.karaoke {
            self.karaoke_color = CaptionKaraoke::color(k);
            self.karaoke_keep = k.keep_spoken;
        }
        self.text_anim_enabled = self.has_captions && s.animation_from_selected_text_clip().is_some();
        self.hint = if !self.has_captions {
            "Create captions first (Captions tab), then style them here.".to_string()
        } else if self.scope == CaptionStyleScope::All {
            let name = s.current_caption_track().map_or_else(|| SQL10n::string("the track"), |t| t.name.clone());
            SQL10n::format(
                "Changes every caption on %@, except that it releases captions with their own look.",
                &[&name],
            )
        } else {
            "Changes only the selected captions. Reset to Track Look hands them back.".to_string()
        };
        self.kit = s.project().style_kit.clone().unwrap_or_default();
        if let Some(f) = self.fields.get_mut(&Control::MotionDuration)
            && !f.is_dragging()
            && !f.is_editing()
        {
            f.value = self.kit.motion.as_ref().map_or(CaptionKitMotion::DEFAULT_SECONDS, |m| {
                m.duration.value() as f64 / m.duration.timescale() as f64
            });
        }
        self.clamp_scroll();
    }

    /// The block's Look row = the caption looks; the closures only queue commands.
    fn set_look_source(&mut self) {
        let (ids, selected) = (self.look_ids.clone(), self.look_selected_id.clone());
        let titles: Vec<String> = ids.iter().map(|i| AnimationPresetName::title(i)).collect();
        let sink = Rc::clone(&self.sink);
        self.block.look_source = Some(Box::new(move || {
            let (pick_sink, add_sink) = (Rc::clone(&sink), Rc::clone(&sink));
            LookSource {
                titles: titles.clone(),
                ids: ids.clone(),
                selected: selected.clone(),
                pick: Box::new(move |id| pick_sink.borrow_mut().push(StyleCommand::EditLook(id.to_string()))),
                add: Some(Box::new(move || add_sink.borrow_mut().push(StyleCommand::SaveLookClicked))),
            }
        }));
    }

    // MARK: Layout

    fn rh() -> f64 {
        ControlsGrid::ROW_HEIGHT
    }

    fn value_end(&self) -> f64 {
        (self.size.width - ControlsGrid::TRAILING).max(ControlsGrid::VALUE_X)
    }

    fn text_width(&self, s: &str) -> f64 {
        self.widths.get(s).copied().unwrap_or_else(|| s.chars().count() as f64 * 7.0)
    }

    const TILE_W: f64 = 84.0;
    const TILE_H: f64 = 60.0;
    const TILE_GAP: f64 = 8.0;

    fn tile_columns(width: f64) -> usize {
        (((width - 16.0 + Self::TILE_GAP) / (Self::TILE_W + Self::TILE_GAP)).floor() as usize).max(1)
    }

    /// The tiles share the row evenly (six across in a 615 pt panel, like the kit).
    fn tile_width(width: f64) -> f64 {
        let n = Self::tile_columns(width) as f64;
        ((width - 16.0 - Self::TILE_GAP * (n - 1.0)) / n).clamp(Self::TILE_W, 120.0)
    }

    /// The Update button: names the picked saved style once one is picked (`Update "Name"`).
    fn update_title(&self) -> String {
        match &self.mark {
            Some(m) => SQL10n::format("Update \u{201C}%@\u{201D}", &[&m.name]),
            None => SQL10n::string("Update Style"),
        }
    }

    fn button_width(&self, s: &str) -> f64 {
        self.widths.get(&format!("button:{s}")).copied().unwrap_or_else(|| s.chars().count() as f64 * 7.0 + 20.0)
    }

    fn layout(&self) -> (Vec<Item>, f64) {
        let mut out: Vec<Item> = Vec::new();
        let mut y = 0.0;
        let rh = Self::rh();
        let x0 = ControlsGrid::VALUE_X;
        let value_end = self.value_end();
        let boxed = |x: f64, w: f64, h: f64, y: f64| CGRect::new(x, y + ((rh - h) / 2.0).round(), w.max(0.0), h);
        let ch = ControlsGrid::CONTROL_HEIGHT;
        let label = |out: &mut Vec<Item>, s: &str, y: f64| {
            out.push(Item::Label(
                s.to_string(),
                CGRect::new(ControlsGrid::LABEL_X, y, (x0 - ControlsGrid::LABEL_X - ControlsGrid::GAP).max(0.0), rh),
                false,
            ));
        };
        let header = |out: &mut Vec<Item>, s: Section, top_line: bool, y: &mut f64| -> bool {
            out.push(Item::Header(s, CGRect::new(0.0, *y, self.size.width, rh), top_line));
            *y += rh;
            self.is_open(s)
        };

        // The kit's top row: the scope switch on the left, "Edited" / Update / Save as New on the right (they wrap to a
        // row of their own when the panel is too narrow for both).
        let scope_titles = ["All Captions", "Selected"];
        let sw: Vec<f64> =
            scope_titles.iter().map(|t| self.text_width(&SQL10n::string(t)) + 2.0 * Self::SEGMENT_INSET).collect();
        let mut sx = ControlsGrid::TOGGLE_X;
        for (i, w) in sw.iter().enumerate() {
            out.push(Item::Control(Control::Scope(i), CGRect::new(sx, y, *w, Self::SEGMENT_HEIGHT)));
            sx += w;
        }
        let mut looks = vec![
            (Control::SaveLook, "Save as New Style\u{2026}".to_string()),
            (Control::UpdateLook, self.update_title()),
        ];
        if self.scope == CaptionStyleScope::Selected {
            looks.push((Control::ResetLook, "Reset to Track Look".to_string()));
        }
        let edited = self.mark.as_ref().is_some_and(|m| m.edited);
        let edited_w = if edited { self.text_width("\u{25CF} Edited") + ControlsGrid::GAP } else { 0.0 };
        let widths: Vec<f64> = looks.iter().map(|(_, t)| self.button_width(&SQL10n::string(t))).collect();
        let strip = edited_w + widths.iter().sum::<f64>() + ControlsGrid::GAP * (looks.len() as f64 - 1.0);
        let right = self.size.width - ControlsGrid::TRAILING;
        let fits = sx + ControlsGrid::GAP + strip <= right;
        let mut bx = if fits { right - strip } else { ControlsGrid::TOGGLE_X };
        if !fits {
            y += Self::SEGMENT_HEIGHT + 6.0;
        }
        let row_y = if fits { y + (Self::SEGMENT_HEIGHT - rh) / 2.0 } else { y };
        if edited {
            let w = edited_w - ControlsGrid::GAP;
            out.push(Item::Edited(CGRect::new(bx, row_y, w, rh)));
            bx += edited_w;
        }
        for ((k, _), w) in looks.into_iter().zip(widths) {
            out.push(Item::Control(k, boxed(bx, w, ch, row_y)));
            bx += w + ControlsGrid::GAP;
        }
        y += if fits { Self::SEGMENT_HEIGHT + 6.0 } else { rh };

        if self.tracks.len() >= 2 {
            label(&mut out, "Track", y);
            out.push(Item::Control(Control::Track, boxed(x0, value_end - x0, ch, y)));
            y += rh;
        }
        // One grid of styles: MINE first, then BUILT IN, each tile naming its source (kit: 6 wide).
        let pad = 8.0;
        let cols = Self::tile_columns(self.size.width);
        let tile_w = Self::tile_width(self.size.width);
        let total = self.mine.len() + self.built_ins.len();
        for i in 0..total {
            let (col, row) = ((i % cols) as f64, (i / cols) as f64);
            let tile = CGRect::new(
                pad + col * (tile_w + Self::TILE_GAP),
                y + row * (Self::TILE_H + Self::TILE_GAP),
                tile_w,
                Self::TILE_H,
            );
            if i < self.mine.len() {
                // The star first: a hit finds the first item that contains the point.
                let star = CGRect::new(tile.max_x() - 20.0, tile.min_y() + 2.0, 18.0, 18.0);
                out.push(Item::Control(Control::MineStar(i), star));
                out.push(Item::Control(Control::Mine(i), tile));
            } else {
                out.push(Item::Control(Control::BuiltIn(i - self.mine.len()), tile));
            }
        }
        y += total.div_ceil(cols) as f64 * (Self::TILE_H + Self::TILE_GAP);
        let note_h = Self::HINT_LINE * 2.0;
        out.push(Item::Note(CGRect::new(
            ControlsGrid::TOGGLE_X,
            y,
            (self.size.width - ControlsGrid::TOGGLE_X - ControlsGrid::TRAILING).max(0.0),
            note_h,
        )));
        y += note_h;

        let look_top = header(&mut out, Section::Look, false, &mut y);
        if look_top {
            // The block holds Font..Shadow and, folded, the dense text options; Highlight words follows it.
            if self.state_shown {
                out.push(Item::Block(y));
                y += self.block.height(&self.inspector_model, Part::KitLook);
            }
            label(&mut out, "Highlight Words", y);
            out.push(Item::Control(Control::Karaoke, boxed(x0, 34.0, 20.0, y)));
            let wx = x0 + 34.0 + ControlsGrid::GAP;
            out.push(Item::Control(Control::KaraokeWell, boxed(wx, Self::SWATCH.width, Self::SWATCH.height, y)));
            let kx = wx + Self::SWATCH.width + ControlsGrid::GAP;
            let keep = self.text_width(&SQL10n::string("Keep spoken"));
            out.push(Item::Control(Control::KaraokeKeep, boxed(kx, 14.0 + 4.0 + keep, 14.0, y)));
            y += rh;
        }
        if header(&mut out, Section::Layout, true, &mut y) {
            label(&mut out, "Position", y);
            let vw: Vec<f64> = Self::VERTICAL_TITLES
                .iter()
                .map(|t| self.text_width(&SQL10n::string(t)) + 2.0 * Self::SEGMENT_INSET)
                .collect();
            let mut vx = x0;
            for (i, w) in vw.iter().enumerate() {
                out.push(Item::Control(Control::Vertical(i), boxed(vx, *w, Self::SEGMENT_HEIGHT, y)));
                vx += w;
            }
            y += rh;
            label(&mut out, "Align", y);
            for i in 0..Self::HORIZONTAL_ICONS.len() {
                out.push(Item::Control(
                    Control::Horizontal(i),
                    boxed(x0 + i as f64 * Self::ICON_SEGMENT, Self::ICON_SEGMENT, Self::SEGMENT_HEIGHT, y),
                ));
            }
            y += rh;
            label(&mut out, "Offset", y);
            let mut ox = x0;
            for (is_y, name) in [(false, "X"), (true, "Y")] {
                let lw = self.text_width(name);
                out.push(Item::Label(name.to_string(), CGRect::new(ox, y, lw, rh), true));
                ox += lw + ControlsGrid::GAP;
                out.push(Item::Control(Control::Offset { is_y }, boxed(ox, ControlsGrid::VALUE_WIDTH, ch, y)));
                ox += ControlsGrid::VALUE_WIDTH + ControlsGrid::GAP;
            }
            y += rh;
            let w = self.button_width(&SQL10n::string("Reset to Kit Position"));
            out.push(Item::Control(Control::ResetPosition, boxed(x0, w, ch, y)));
            y += rh;
        }
        if header(&mut out, Section::Motion, true, &mut y) {
            label(&mut out, "Animation", y);
            out.push(Item::Control(Control::Animation, boxed(x0, value_end - x0, ch, y)));
            y += rh;
            // The animated styles are the picker for the Animation row.
            out.push(Item::Gallery(y));
            y += self.gallery.height_for_width(self.size.width);
        }
        if header(&mut out, Section::Kit, true, &mut y) {
            for (k, title) in [(Control::KitLook, "Look to Kit"), (Control::TextAnim, "Animation from Text Clip")] {
                let w = self.button_width(&SQL10n::string(title));
                out.push(Item::Control(k, boxed(ControlsGrid::TOGGLE_X, w, ch, y)));
                y += rh;
            }
            out.push(Item::Strong(
                "Brand (Style Kit)".to_string(),
                CGRect::new(ControlsGrid::TOGGLE_X, y, (value_end - ControlsGrid::TOGGLE_X).max(0.0), rh),
            ));
            y += rh;
            // The brand grid: a trailing label column of 96, then the control (`rebuildBrand`).
            let lx = ControlsGrid::TOGGLE_X;
            let cx = lx + Self::BRAND_LABEL_WIDTH + ControlsGrid::GAP;
            let brand_label = |out: &mut Vec<Item>, s: String, y: f64| {
                out.push(Item::Label(s, CGRect::new(lx, y, Self::BRAND_LABEL_WIDTH, rh), true));
            };
            let pop_w = (value_end - cx).clamp(60.0, 160.0);
            for name in self.kit.fonts.keys() {
                let title = SQL10n::string(&AnimationPresetName::title(name));
                brand_label(&mut out, SQL10n::format("%@ Font", &[&title]), y);
                out.push(Item::Control(Control::BrandFont(name.to_string()), boxed(cx, pop_w, ch, y)));
                y += rh;
            }
            for name in self.kit.colors.keys() {
                let title = SQL10n::string(&AnimationPresetName::title(name));
                brand_label(&mut out, SQL10n::format("%@ Color", &[&title]), y);
                out.push(Item::Control(
                    Control::BrandColor(name.to_string()),
                    boxed(cx, Self::SWATCH.width, Self::SWATCH.height, y),
                ));
                y += rh;
            }
            brand_label(&mut out, "Motion".to_string(), y);
            out.push(Item::Control(Control::MotionDuration, boxed(cx, Self::MOTION_FIELD_WIDTH, ch, y)));
            let curve_x = cx + Self::MOTION_FIELD_WIDTH + ControlsGrid::GAP;
            out.push(Item::Control(
                Control::MotionCurve,
                boxed(curve_x, (value_end - curve_x).clamp(60.0, 140.0), ch, y),
            ));
            y += rh;
        }
        let hh = self.hint_lines as f64 * Self::HINT_LINE;
        out.push(Item::Hint(CGRect::new(
            ControlsGrid::TOGGLE_X,
            y,
            (self.size.width - ControlsGrid::TOGGLE_X - ControlsGrid::TRAILING).max(0.0),
            hh,
        )));
        y += hh + Self::BOTTOM_PAD;
        (out, y)
    }

    /// Where the text block starts in content points (0 while it is hidden).
    fn block_y(&self) -> f64 {
        self.layout().0.iter().find_map(|i| if let Item::Block(y) = i { Some(*y) } else { None }).unwrap_or(0.0)
    }

    fn max_scroll(&self) -> f64 {
        (self.layout().1 - self.size.height).max(0.0)
    }

    fn clamp_scroll(&mut self) {
        self.scroll_y = self.scroll_y.clamp(0.0, self.max_scroll());
    }

    /// Content point of a tab point.
    fn content(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y + self.scroll_y)
    }

    /// The frame of `k` in tab points (scroll applied); `None` while it is not shown.
    pub fn frame(&self, k: &Control) -> Option<CGRect> {
        for item in self.layout().0 {
            match item {
                Item::Control(c, r) if c == *k => return Some(offset_y(r, -self.scroll_y)),
                Item::Header(s, r, _) if *k == Control::Header(s) => return Some(offset_y(r, -self.scroll_y)),
                _ => {}
            }
        }
        None
    }

    fn hit(&self, p: CGPoint) -> Option<Hit> {
        let q = self.content(p);
        for item in self.layout().0 {
            match item {
                Item::Control(k, r) => {
                    if CGRect::new(r.min_x(), r.min_y() - 2.0, r.width, r.height + 4.0).contains(q) {
                        return Some(Hit::Control(k));
                    }
                }
                Item::Header(s, r, _) => {
                    if r.contains(q) {
                        return Some(Hit::Control(Control::Header(s)));
                    }
                }
                Item::Block(y) if q.y >= y && q.y < y + self.block.height(&self.inspector_model, Part::KitLook) => {
                    return Some(Hit::Block(CGPoint::new(q.x, q.y - y)));
                }
                Item::Gallery(y) if q.y >= y && q.y < y + self.gallery.height_for_width(self.size.width) => {
                    return Some(Hit::Gallery(CGPoint::new(q.x, q.y - y)));
                }
                _ => {}
            }
        }
        None
    }

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        if let Some(Hit::Control(k)) = self.hit(p) { Some(k) } else { None }
    }

    // MARK: Enabled state

    fn is_enabled(&self, k: &Control) -> bool {
        match k {
            Control::Scope(i) => *i == 0 || self.has_selection,
            Control::Track => self.track_enabled,
            Control::Animation | Control::Vertical(_) | Control::Horizontal(_) | Control::Offset { .. } => {
                self.state_shown
            }
            Control::ResetPosition => self.reset_position_enabled,
            Control::Karaoke => self.has_captions,
            Control::KaraokeWell | Control::KaraokeKeep => self.karaoke.is_some(),
            Control::SaveLook | Control::UpdateLook | Control::KitLook => self.has_captions,
            Control::ResetLook => self.reset_look_enabled,
            Control::TextAnim => self.text_anim_enabled,
            _ => true,
        }
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, ui: &mut UiCx) {
        self.now = ui.now;
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        if c.atlas().is_some() {
            self.measure(c);
        }
        let (items, _) = self.layout();
        c.save_gstate();
        c.clip_to(CGRect::new(0.0, 0.0, self.size.width, self.size.height));
        c.translate_by(0.0, -self.scroll_y);
        for item in items {
            match item {
                Item::Control(k, r) => self.draw_control(c, &k, r, ui),
                Item::Label(s, r, right) => {
                    let align = if right { TextAlign::Right } else { TextAlign::Left };
                    c.draw_text_in(&SQL10n::string(&s), r, fs, t.label2(), align, 0.0, 0);
                }
                Item::Strong(s, r) => {
                    c.draw_text_in(&SQL10n::string(&s), r, fs, t.label(), TextAlign::Left, 0.0, 0);
                }
                Item::Header(s, r, top) => self.draw_header(c, s, r, top),
                Item::Gallery(y) => {
                    c.save_gstate();
                    c.translate_by(0.0, y);
                    self.gallery.draw(c, &t, ui.now);
                    c.restore_gstate();
                }
                Item::Block(y) => {
                    c.save_gstate();
                    c.translate_by(0.0, y);
                    self.block.draw(&self.inspector_model, c, Part::KitLook, ui, ui.now);
                    c.restore_gstate();
                }
                Item::Edited(r) => {
                    let text = SQL10n::string("\u{25CF} Edited");
                    c.draw_text_in(&text, r, f64::from(type_size::CAPTION), t.yellow(), TextAlign::Left, 0.0, 0);
                }
                Item::Note(r) => {
                    let text = SQL10n::string(
                        "Pick a style as a start, then change anything below. Everything is saved with the style.",
                    );
                    c.draw_wrapped(&text, r, fs, Self::HINT_LINE, t.label3());
                }
                Item::Hint(r) => {
                    let text = SQL10n::string(&self.hint);
                    if c.atlas().is_some() {
                        self.hint_lines = c.wrap(&text, r.width, fs).len().max(1);
                    }
                    c.draw_wrapped(&text, r, fs, Self::HINT_LINE, t.label3());
                }
            }
        }
        c.restore_gstate();
    }

    fn measure(&mut self, c: &Canvas) {
        let fs = f64::from(type_size::BODY);
        for s in ["All Captions", "Selected", "Keep spoken", "X", "Y"].into_iter().chain(Self::VERTICAL_TITLES) {
            let l = SQL10n::string(s);
            self.widths.insert(l.clone(), c.size_of(&l, fs, 0).width.ceil());
        }
        let update = self.update_title();
        let l = SQL10n::string("\u{25CF} Edited");
        self.widths.insert(l.clone(), c.size_of(&l, f64::from(type_size::CAPTION), 0).width.ceil());
        let w = InspectorDraw::button_width(c, &update);
        self.widths.insert(format!("button:{update}"), w);
        for s in [
            "Reset to Kit Position",
            "Save as New Style\u{2026}",
            "Update Style",
            "Reset to Track Look",
            "Look to Kit",
            "Animation from Text Clip",
        ] {
            let l = SQL10n::string(s);
            let w = InspectorDraw::button_width(c, &l);
            self.widths.insert(format!("button:{l}"), w);
        }
    }

    fn draw_header(&self, c: &mut Canvas, s: Section, f: CGRect, top_line: bool) {
        // The shared inspector group header (r8 `.grp`), not a copy.
        let hovered = self.hover == Some(Control::Header(s));
        crate::ec_draw::group_header(c, f, self.size.width, s.title(), self.is_open(s), hovered, "", top_line, &self.theme);
    }

    fn draw_segment(
        &self,
        c: &mut Canvas,
        r: CGRect,
        title: Option<&str>,
        icon: Option<SQIcon>,
        on: bool,
        k: &Control,
    ) {
        let t = self.theme;
        let first = matches!(k, Control::Scope(0) | Control::Vertical(0) | Control::Horizontal(0));
        let (enabled, rad) = (self.is_enabled(k), f64::from(radius::SMALL));
        if first {
            c.fill_rounded(r, rad, t.fill());
        } else {
            c.fill(r, t.fill());
        }
        let hovered = self.hover.as_ref() == Some(k) && enabled;
        if on || hovered {
            c.fill_rounded(r.inset_by(1.0, 1.0), rad, if on { t.fill_pressed() } else { t.fill_hover() });
        }
        let base = if on { t.label() } else { t.label2() };
        let ink = if enabled { base } else { base.with_alpha(base.a * InspectorTokens::DISABLED_ALPHA) };
        if let Some(icon) = icon {
            c.draw_icon(icon, CGPoint::new((r.mid_x() - 5.5).round(), (r.mid_y() - 5.5).round()), 11.0, ink, None);
        }
        if let Some(title) = title {
            c.draw_text_in(&SQL10n::string(title), r, f64::from(type_size::BODY), ink, TextAlign::Center, 0.0, 0);
        }
    }

    fn draw_control(&mut self, c: &mut Canvas, k: &Control, r: CGRect, ui: &mut UiCx) {
        let (t, fs, en) = (self.theme, f64::from(type_size::BODY), self.is_enabled(k));
        let hovering = self.hover.as_ref() == Some(k);
        let pressed = self.pressed.as_ref() == Some(k);
        let dim = if en { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        match k {
            Control::Scope(i) => {
                let on = (self.scope == CaptionStyleScope::Selected) == (*i == 1);
                self.draw_segment(c, r, Some(if *i == 0 { "All Captions" } else { "Selected" }), None, on, k);
            }
            Control::Vertical(i) => {
                let on = Self::VERTICALS.iter().position(|v| *v == self.position.vertical) == Some(*i);
                self.draw_segment(c, r, Some(Self::VERTICAL_TITLES[*i]), None, on, k);
            }
            Control::Horizontal(i) => {
                let on = Self::HORIZONTALS.iter().position(|h| *h == self.position.horizontal) == Some(*i);
                self.draw_segment(c, r, None, Some(Self::HORIZONTAL_ICONS[*i].0), on, k);
            }
            Control::Track => {
                let title = self.track_index.and_then(|i| self.tracks.get(i)).map(|t| t.1.clone()).unwrap_or_default();
                InspectorDraw::popup(c, &title, r, hovering, false, en, true, ControlsGrid::CONTROL_HEIGHT, None, &t);
            }
            Control::Animation => {
                let title = self
                    .animation_selected_id
                    .as_deref()
                    .map_or_else(|| SQL10n::string("Saved Animation"), AnimationPresetName::title);
                InspectorDraw::popup(c, &title, r, hovering, false, en, true, ControlsGrid::CONTROL_HEIGHT, None, &t);
            }
            Control::Karaoke => {
                let touch = Touch { hovering, pressed, disabled: !en, ..Touch::default() };
                c.stone_switch(r, self.karaoke.is_some(), touch, &t);
            }
            Control::KaraokeKeep => {
                let s = if self.karaoke_keep && self.karaoke.is_some() { CheckState::On } else { CheckState::Off };
                InspectorDraw::checkbox(
                    c,
                    s,
                    CGRect::new(r.min_x(), r.min_y(), 14.0, 14.0),
                    hovering,
                    pressed,
                    en,
                    false,
                    &t,
                );
                c.draw_text_in(
                    &SQL10n::string("Keep spoken"),
                    CGRect::new(r.min_x() + 18.0, r.min_y() - 4.0, (r.width - 18.0).max(0.0), 22.0),
                    fs,
                    t.label().with_alpha(t.label().a * dim),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            Control::KaraokeWell => {
                let col = self.karaoke_color;
                let ink = Color::new(col.red as f32, col.green as f32, col.blue as f32, dim);
                InspectorDraw::color_well(c, ink, r, hovering && en, &t);
            }
            Control::Offset { .. } | Control::MotionDuration => {
                let focused = self.focused.as_ref() == Some(k);
                if let Some(f) = self.fields.get_mut(k) {
                    f.hovering = hovering;
                    f.draw(c, r, &t, focused, ui);
                }
            }
            Control::ResetPosition
            | Control::SaveLook
            | Control::UpdateLook
            | Control::ResetLook
            | Control::KitLook
            | Control::TextAnim => {
                InspectorDraw::button(
                    c,
                    &if *k == Control::UpdateLook {
                        self.update_title()
                    } else {
                        SQL10n::string(Self::button_title(k))
                    },
                    r,
                    hovering,
                    pressed,
                    en,
                    false,
                    ControlsGrid::CONTROL_HEIGHT,
                    &t,
                );
            }
            Control::BrandFont(name) => {
                let title = self.kit.fonts.get(name).cloned().unwrap_or_default();
                InspectorDraw::popup(
                    c,
                    &title,
                    r,
                    hovering,
                    false,
                    true,
                    true,
                    ControlsGrid::CONTROL_HEIGHT,
                    None,
                    &t,
                );
            }
            Control::BrandColor(name) => {
                let col = self.kit.colors.get(name).copied().unwrap_or(effect_color(1.0, 1.0, 1.0, 1.0));
                let ink = Color::new(col.red as f32, col.green as f32, col.blue as f32, col.alpha.max(0.15) as f32);
                InspectorDraw::color_well(c, ink, r, hovering, &t);
            }
            Control::MotionCurve => {
                let i = self.kit.motion.as_ref().map_or(MotionCurve::PremiereDefault.raw_value(), |m| m.curve);
                let titles = MotionCurve::titles();
                let title = usize::try_from(i).ok().and_then(|i| titles.get(i)).cloned().unwrap_or_default();
                InspectorDraw::popup(
                    c,
                    &title,
                    r,
                    hovering,
                    false,
                    true,
                    true,
                    ControlsGrid::CONTROL_HEIGHT,
                    None,
                    &t,
                );
            }
            Control::Mine(i) => {
                let Some((id, name, _)) = self.mine.get(*i) else { return };
                let picked = self.picked_look.as_deref() == Some(id.as_str());
                c.fill_rounded(r, f64::from(radius::SMALL), if hovering { t.fill_hover() } else { t.fill() });
                if picked {
                    c.stroke_rounded(r, f64::from(radius::SMALL), 2.0, t.accent());
                }
                let sample = CGRect::new(r.min_x(), r.min_y() + 2.0, r.width, r.height - 28.0);
                let aa = "A\u{0061}"; // a font sample, not a UI string
                c.draw_text_in(aa, sample, 14.0, t.label(), TextAlign::Center, 0.0, 0);
                self.draw_tile_names(c, r, name, "MINE", &t);
            }
            Control::BuiltIn(i) => {
                let Some((id, name, style)) = self.built_ins.get(*i) else { return };
                let picked = self.picked_look.as_deref() == Some(Self::built_in_key(id).as_str());
                c.fill_rounded(r, f64::from(radius::SMALL), if hovering { t.fill_hover() } else { t.fill() });
                if picked {
                    c.stroke_rounded(r, f64::from(radius::SMALL), 2.0, t.accent());
                }
                let sample = CGRect::new(r.min_x(), r.min_y() + 2.0, r.width, r.height - 28.0);
                crate::text::style_sample::draw_style_sample(c, style, sample);
                self.draw_tile_names(c, r, name, "BUILT IN", &t);
            }
            Control::MineStar(i) => {
                let Some((_, _, star)) = self.mine.get(*i) else { return };
                let (icon, ink) = if *star {
                    (SQIcon::StarFilled, t.yellow())
                } else if hovering {
                    (SQIcon::Star, t.label2())
                } else {
                    (SQIcon::Star, t.label3())
                };
                c.draw_icon(icon, CGPoint::new(r.mid_x() - 5.0, r.mid_y() - 5.0), 10.0, ink, None);
            }
            Control::Header(_) => {}
        }
    }

    /// The style name and, under it, where the style comes from.
    fn draw_tile_names(&self, c: &mut Canvas, r: CGRect, name: &str, source: &str, t: &DrawTheme) {
        let caption = f64::from(type_size::CAPTION);
        let label = CGRect::new(r.min_x() + 4.0, r.max_y() - 26.0, r.width - 8.0, 14.0);
        c.draw_text_in(&SQL10n::string(name), label, caption, t.label2(), TextAlign::Center, 0.0, 0);
        let src = CGRect::new(r.min_x() + 4.0, r.max_y() - 14.0, r.width - 8.0, 12.0);
        c.draw_text_in(&SQL10n::string(source), src, 9.0, t.label3(), TextAlign::Center, 0.0, 0);
    }

    fn button_title(k: &Control) -> &'static str {
        match k {
            Control::ResetPosition => "Reset to Kit Position",
            Control::SaveLook => "Save as New Style\u{2026}",
            Control::UpdateLook => "Update Style",
            Control::Mine(_) | Control::MineStar(_) | Control::BuiltIn(_) => "",
            Control::ResetLook => "Reset to Track Look",
            Control::KitLook => "Look to Kit",
            Control::TextAnim => "Animation from Text Clip",
            _ => "",
        }
    }

    // MARK: Pointer

    pub fn mouse_moved(&mut self, p: Option<CGPoint>, ui: &mut UiCx) {
        if self.press.is_some() {
            return;
        }
        self.now = ui.now;
        let (mut block_p, mut gallery_p) = (None, None);
        self.hover = None;
        if let Some(h) = p.and_then(|p| self.hit(p)) {
            match h {
                Hit::Control(k) => self.hover = Some(k),
                Hit::Block(q) => block_p = Some(q),
                Hit::Gallery(q) => gallery_p = Some(q),
            }
        }
        self.block.mouse_moved(&self.inspector_model, block_p, Part::KitLook, ui.now);
        self.gallery.mouse_moved(gallery_p, ui.now);
    }

    pub fn mouse_down(
        &mut self,
        s: &mut EditorSession,
        ui: &mut UiCx,
        p: CGPoint,
        m: InputModifiers,
        click_count: Option<i64>,
    ) {
        self.now = ui.now;
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, ui.now));
        let h = self.hit(p);
        if let Some(f) = self.focused.clone()
            && !matches!(&h, Some(Hit::Control(k)) if *k == f)
        {
            self.resign_field(s, ui, &f);
        }
        if !matches!(h, Some(Hit::Block(_))) {
            self.block.resign_focus(&mut self.inspector_model, ui);
            self.pump_block(s);
        }
        let Some(h) = h.filter(|_| !m.contains(InputModifiers::SECONDARY)) else {
            self.press = None;
            return;
        };
        match h {
            Hit::Block(q) => {
                self.press = Some(Press::Block);
                self.block.mouse_down(&mut self.inspector_model, q, Part::KitLook, Some(n), None, ui);
                self.pump_block(s);
            }
            Hit::Gallery(q) => {
                self.press = Some(Press::Gallery);
                self.gallery.mouse_down(q);
            }
            Hit::Control(k) => {
                if !self.is_enabled(&k) {
                    self.press = None;
                    return;
                }
                self.press = Some(Press::Control(k.clone()));
                self.pressed = Some(k.clone());
                match k {
                    Control::Offset { .. } | Control::MotionDuration => {
                        let Some(f) = self.fields.get_mut(&k) else { return };
                        let ev = f.mouse_down(p.x as f32, n);
                        self.focused = Some(k.clone());
                        self.apply(s, ev, &k);
                    }
                    Control::Track | Control::Animation | Control::BrandFont(_) | Control::MotionCurve => {
                        self.pressed = None;
                        self.open_menu(s, &k);
                    }
                    _ => {}
                }
            }
        }
    }

    pub fn mouse_dragged(&mut self, s: &mut EditorSession, ui: &mut UiCx, p: CGPoint, modifiers: InputModifiers) {
        self.now = ui.now;
        match self.press.clone() {
            Some(Press::Block) => {
                let q = self.content(p);
                let q = CGPoint::new(q.x, q.y - self.block_y());
                self.block.mouse_dragged(&mut self.inspector_model, q, modifiers, None, ui);
                self.pump_block(s);
            }
            Some(Press::Control(k)) if matches!(k, Control::Offset { .. } | Control::MotionDuration) => {
                let Some(f) = self.fields.get_mut(&k) else { return };
                let ev = f.mouse_dragged(p.x as f32, InputModifiers::NONE, 1.0, ui);
                self.apply(s, ev, &k);
            }
            _ => {}
        }
    }

    pub fn mouse_up(&mut self, s: &mut EditorSession, ui: &mut UiCx, p: CGPoint) {
        self.now = ui.now;
        let press = self.press.take();
        self.finish_press(s, ui, p, press);
        self.pressed = None;
        self.press = None;
        self.mouse_moved(Some(p), ui);
    }

    fn finish_press(&mut self, s: &mut EditorSession, ui: &mut UiCx, p: CGPoint, press: Option<Press>) {
        match press {
            Some(Press::Block) => {
                let q = self.content(p);
                let q = CGPoint::new(q.x, q.y - self.block_y());
                self.block.mouse_up(&mut self.inspector_model, q, Part::KitLook, ui);
                self.pump_block(s);
            }
            Some(Press::Gallery) => {
                if let Some(Hit::Gallery(q)) = self.hit(p) {
                    self.gallery.mouse_up(q);
                } else {
                    self.gallery.mouse_up(CGPoint::new(-1.0, -1.0));
                }
                for look in std::mem::take(&mut self.gallery.picked) {
                    self.pick_style_look(s, &look);
                }
            }
            Some(Press::Control(k)) => {
                if matches!(k, Control::Offset { .. } | Control::MotionDuration) {
                    if let Some(f) = self.fields.get_mut(&k) {
                        let ev = f.mouse_up(ui);
                        self.apply(s, ev, &k);
                    }
                    return;
                }
                if self.control_at(p).as_ref() == Some(&k) {
                    self.click(s, ui, &k);
                }
            }
            None => {}
        }
    }

    fn click(&mut self, s: &mut EditorSession, _ui: &mut UiCx, k: &Control) {
        match k {
            Control::Scope(i) => {
                self.scope = if *i == 1 { CaptionStyleScope::Selected } else { CaptionStyleScope::All };
                self.last_edit = None;
                self.refresh(s);
            }
            Control::Header(sec) => {
                let now = !self.is_open(*sec);
                self.open.insert(*sec, now);
                if let Some(d) = self.defaults.as_mut() {
                    write_open(d.as_mut(), &TextBlockDraw::section_key(sec.raw_value()), now);
                }
                self.clamp_scroll();
            }
            Control::Karaoke => {
                if self.karaoke.is_none() {
                    self.karaoke_keep = false;
                }
                self.set_karaoke(s, self.karaoke.is_none());
            }
            Control::KaraokeKeep => {
                self.karaoke_keep = !self.karaoke_keep;
                self.set_karaoke(s, true);
            }
            Control::KaraokeWell => self.pick_karaoke_color(),
            Control::Vertical(_) | Control::Horizontal(_) => self.position_changed(s, k),
            Control::ResetPosition => {
                self.last_edit = None;
                let ids = if self.scope == CaptionStyleScope::Selected && !s.caption_selection().is_empty() {
                    s.caption_selection().clone()
                } else {
                    s.all_caption_ids()
                };
                s.reset_caption_positions(&ids);
                self.refresh(s);
            }
            Control::SaveLook => self.save_look_clicked(s),
            Control::UpdateLook => self.update_look_clicked(s),
            Control::Mine(i) => self.pick_mine(s, *i),
            Control::BuiltIn(i) => self.pick_built_in(s, *i),
            Control::MineStar(i) => self.toggle_star(s, *i),
            Control::ResetLook => {
                self.last_edit = None;
                if !s.reset_selected_captions_to_track_look()
                    && let Some(e) = s.last_error().map(str::to_string)
                {
                    self.status(e);
                }
                self.refresh(s);
            }
            Control::KitLook => {
                let n = s.project().style_kit.as_ref().map_or(0, |k| k.looks.len()) + 1;
                if s.save_caption_look_to_kit(&format!("Look {n}")).is_some() {
                    self.status(SQL10n::format("Look saved in the Style Kit as \"Look %@\".", &[&n.to_string()]));
                } else {
                    self.status(SQL10n::string("The look could not be saved in the Style Kit."));
                }
                self.refresh(s);
            }
            Control::TextAnim => self.text_anim_clicked(s),
            Control::BrandColor(name) => self.pick_brand_color(name),
            _ => {}
        }
    }

    fn status(&mut self, text: String) {
        if let Some(f) = self.on_status.as_mut() {
            f(text);
        }
    }

    // MARK: Menus

    fn queue(&self, title: &str, checked: bool, cmd: StyleCommand) -> SQMenuItem {
        let sink = Rc::clone(&self.sink);
        let mut i = SQMenuItem::new(title);
        i.title = title.to_string();
        i.is_checked = checked;
        i.action = Some(Rc::new(move || sink.borrow_mut().push(cmd.clone())));
        i
    }

    fn open_menu(&mut self, _s: &EditorSession, k: &Control) {
        let Some(anchor) = self.frame(k) else { return };
        let mut items: Vec<SQMenuItem> = Vec::new();
        match k {
            Control::Track => {
                for (i, (id, name)) in self.tracks.iter().enumerate() {
                    items.push(self.queue(name, Some(i) == self.track_index, StyleCommand::FocusTrack(*id)));
                }
            }
            Control::Animation => {
                for id in &self.animation_ids {
                    let checked = self.animation_selected_id.as_deref() == Some(id.as_str());
                    items.push(self.queue(
                        &AnimationPresetName::title(id),
                        checked,
                        StyleCommand::Animation(id.clone()),
                    ));
                }
                if self.animation_selected_id.as_ref().is_none_or(|id| !self.animation_ids.contains(id)) {
                    let mut saved = SQMenuItem::new(&SQL10n::string("Saved Animation"));
                    saved.is_enabled = false;
                    saved.is_checked = true;
                    items.push(saved);
                }
            }
            Control::BrandFont(name) => {
                let current = self.kit.fonts.get(name).cloned();
                let mut families = self.inspector_model.font_families().to_vec();
                if let Some(c) = &current
                    && !families.contains(c)
                {
                    families.insert(0, c.clone());
                }
                for f in families {
                    let checked = current.as_deref() == Some(f.as_str());
                    items.push(self.queue(&f, checked, StyleCommand::BrandFont(name.clone(), f.clone())));
                }
            }
            Control::MotionCurve => {
                let cur = self.kit.motion.as_ref().map_or(MotionCurve::PremiereDefault.raw_value(), |m| m.curve);
                for (i, title) in MotionCurve::titles().iter().enumerate() {
                    let i = i as i64;
                    items.push(self.queue(title, i == cur, StyleCommand::MotionCurve(i)));
                }
            }
            _ => return,
        }
        if !items.is_empty()
            && let Some(f) = self.on_menu.as_mut()
        {
            f(items, anchor);
        }
    }

    /// Runs what the closed menu or the answered name prompt queued, then what the block queued.
    pub fn run_commands(&mut self, s: &mut EditorSession) {
        loop {
            let commands: Vec<_> = self.sink.borrow_mut().drain(..).collect();
            let block_ran = !commands.is_empty();
            for cmd in commands {
                match cmd {
                    StyleCommand::FocusTrack(id) => {
                        s.focus_caption_track(Some(id));
                        self.last_edit = None;
                        self.refresh(s);
                    }
                    StyleCommand::Animation(id) => self.edit(s, CaptionStyleField::Animation(id), Control::Animation),
                    StyleCommand::EditLook(id) => {
                        self.edit(s, CaptionStyleField::Look(id), Control::Header(Section::Look));
                    }
                    StyleCommand::BrandFont(name, font) => {
                        s.edit_style_kit("Brand Font", false, |k| {
                            k.fonts.insert(name, font);
                        });
                        self.refresh(s);
                    }
                    StyleCommand::MotionCurve(i) => {
                        s.edit_style_kit("Motion Curve", false, |k| {
                            let duration = k.motion.as_ref().map_or(Time::new(1, 2), |m| m.duration);
                            k.motion = Some(MotionDefaults { duration, curve: i });
                        });
                        self.refresh(s);
                    }
                    StyleCommand::SaveLookClicked => self.save_look_clicked(s),
                    StyleCommand::SaveLookNamed(name) => {
                        if let Some(name) = name.map(|n| n.trim().to_string()).filter(|n| !n.is_empty()) {
                            self.save_look(s, &name);
                        }
                    }
                }
            }
            self.block.run_menu_commands(&mut self.inspector_model);
            self.drain_model_events(Some(s));
            if !block_ran && self.sink.borrow().is_empty() {
                break;
            }
        }
    }

    // MARK: Edits

    /// True when `k` changed again within a second: the change joins the previous undo step.
    fn continuing(&mut self, k: &Control) -> bool {
        let now = self.now;
        let last = self.last_edit.replace((k.clone(), now));
        let Some((last_k, at)) = last else { return false };
        if last_k != *k {
            return false;
        }
        if self.picker_well.as_ref() == Some(k) {
            return true; // an open picker holds the step, however slow
        }
        now - at < 1.0
    }

    fn edit(&mut self, s: &mut EditorSession, f: CaptionStyleField, k: Control) {
        let joins = self.continuing(&k);
        if !s.edit_caption_style(f, self.scope, joins)
            && let Some(e) = s.last_error().map(str::to_string)
        {
            self.status(e);
        }
        self.refresh(s);
    }

    fn pick_style_look(&mut self, s: &mut EditorSession, look: &CaptionStyleLook) {
        self.last_edit = None;
        // A tile is only the look; the animation stays and is set in Motion.
        if s.apply_caption_style_look_only(look, None) {
            self.status(SQL10n::format("Caption look: %@.", &[&SQL10n::string(&look.title)]));
        } else {
            let e = s
                .last_error()
                .map_or_else(|| SQL10n::string("Create captions first, then pick a look."), str::to_string);
            self.status(e);
        }
        self.refresh(s);
    }

    /// Answers what the model said since the last call; `None` for the session while the tab refreshes (no edit can
    /// come from a load).
    fn drain_model_events(&mut self, s: Option<&mut EditorSession>) {
        let mut s = s;
        for ev in self.inspector_model.take_events() {
            match ev {
                TextInspectorEvent::BeginEditing => {
                    self.inspector_gesture_open = true;
                    self.inspector_gesture_fresh = true;
                }
                TextInspectorEvent::Change(style, _, _) => {
                    if let Some(s) = s.as_deref_mut() {
                        self.inspector_changed(s, &style);
                    }
                }
                TextInspectorEvent::EndEditing => self.inspector_gesture_open = false,
                _ => {}
            }
        }
    }

    /// An edit in the shared text block: the difference to what was shown becomes caption fields, one undo step per
    /// gesture.
    fn inspector_changed(&mut self, s: &mut EditorSession, new: &TextStyle) {
        let new = CaptionStyleEdit::display_style(new);
        let old = self.shown_style.clone().unwrap_or_else(|| new.clone());
        let fields = CaptionStyleEdit::fields(&old, &new);
        let joins = !self.inspector_gesture_fresh;
        self.inspector_gesture_fresh = false;
        if fields.is_empty() {
            return;
        }
        self.shown_style = Some(new);
        self.last_edit = None;
        if !s.edit_caption_style_fields(fields, self.scope, joins)
            && let Some(e) = s.last_error().map(str::to_string)
        {
            self.status(e);
        }
    }

    /// Forwards what the block asked for (menus, color pickers) and applies the model events it made.
    fn pump_block(&mut self, s: &mut EditorSession) {
        for r in self.block.take_requests() {
            let dy = self.block_y() - self.scroll_y;
            match r {
                BlockRequest::Menu { items, anchor, .. } => {
                    if let Some(f) = self.on_menu.as_mut() {
                        f(items, offset_y(anchor, dy));
                    }
                }
                BlockRequest::PickColor { control, current, anchor, .. } => {
                    if let Some(f) = self.on_pick_color.as_mut() {
                        self.color_target = Some(ColorTarget::Block(control));
                        f(current, offset_y(anchor, dy));
                    }
                }
                _ => {}
            }
        }
        self.drain_model_events(Some(s));
    }

    /// Any position control: the whole position is read back from the controls.
    fn position_changed(&mut self, s: &mut EditorSession, k: &Control) {
        let (mut v, mut h) = (self.position.vertical, self.position.horizontal);
        if let Control::Vertical(i) = k {
            v = Self::VERTICALS[(*i).min(2)];
        }
        if let Control::Horizontal(i) = k {
            h = Self::HORIZONTALS[(*i).min(2)];
        }
        let stored = |d: &Self, is_y: bool| {
            CaptionOffsetDisplay::stored(d.fields.get(&Control::Offset { is_y }).map_or(0.0, |f| f.value), is_y)
        };
        let p =
            CaptionPosition { vertical: v, horizontal: h, offset_x: stored(self, false), offset_y: stored(self, true) };
        // One scrub / typed commit / arrow burst of an offset field is one undo step; a segment is its own.
        let is_offset = matches!(k, Control::Offset { .. });
        let joins = is_offset && !self.offset_gesture_fresh;
        if is_offset {
            self.offset_gesture_fresh = false;
        } else {
            self.last_edit = None;
        }
        if self.scope == CaptionStyleScope::Selected && !s.caption_selection().is_empty() {
            let ids = s.caption_selection().clone();
            s.set_caption_item_position(&ids, p, joins); // their own position
        } else {
            s.set_caption_position(p, joins);
        }
        self.refresh(s);
    }

    fn set_karaoke(&mut self, s: &mut EditorSession, on: bool) {
        if !on {
            s.set_caption_karaoke(None);
            self.refresh(s);
            return;
        }
        let c = self.karaoke_color;
        s.set_caption_karaoke(Some(KaraokeStyle {
            red: c.red,
            green: c.green,
            blue: c.blue,
            keep_spoken: self.karaoke_keep,
        }));
        self.refresh(s);
    }

    /// One undo step per picker session: the well follows the picks, the highlight is set when the picker closes.
    fn pick_karaoke_color(&mut self) {
        let Some(anchor) = self.frame(&Control::KaraokeWell) else { return };
        let c = self.karaoke_color;
        if let Some(f) = self.on_pick_color.as_mut() {
            self.color_target = Some(ColorTarget::Karaoke);
            f(effect_color(c.red, c.green, c.blue, 1.0), anchor);
        }
    }

    fn pick_brand_color(&mut self, name: &str) {
        let Some(anchor) = self.frame(&Control::BrandColor(name.to_string())) else { return };
        self.picker_well = Some(Control::BrandColor(name.to_string()));
        self.last_edit = None; // a new picker session starts a new undo step
        let cur = self.kit.colors.get(name).copied().unwrap_or(effect_color(1.0, 1.0, 1.0, 1.0));
        if let Some(f) = self.on_pick_color.as_mut() {
            self.color_target = Some(ColorTarget::Brand(name.to_string()));
            f(cur, anchor);
        }
    }

    /// The host's answer to `on_pick_color`: each change, then `None` when the picker closed.
    pub fn color_picked(&mut self, s: &mut EditorSession, color: Option<EffectColor>) {
        let Some(target) = self.color_target.clone() else { return };
        if color.is_none() {
            self.color_target = None;
        }
        match target {
            ColorTarget::Block(control) => {
                self.block.color_changed(&mut self.inspector_model, &control, color);
                self.pump_block(s);
            }
            ColorTarget::Karaoke => match color {
                None => {
                    if self.karaoke.is_some() {
                        self.set_karaoke(s, true);
                    }
                }
                Some(c) => self.karaoke_color = RGBAColor::new(c.red, c.green, c.blue, 1.0),
            },
            ColorTarget::Brand(name) => match color {
                None => self.picker_well = None,
                Some(c) => {
                    let k = Control::BrandColor(name.clone());
                    let c = CaptionStyleEdit::effect(&RGBAColor::new(c.red, c.green, c.blue, c.alpha));
                    let joins = self.continuing(&k);
                    s.edit_style_kit("Brand Color", joins, |kit| {
                        kit.colors.insert(name, c);
                    });
                    self.refresh(s);
                }
            },
        }
    }

    fn set_motion_duration(&mut self, s: &mut EditorSession, v: f64, joins: bool) {
        let Some(t) = CaptionKitMotion::time(v) else { return };
        s.edit_style_kit("Change Motion Duration", joins, |k| {
            let curve = k.motion.as_ref().map_or(MotionCurve::PremiereDefault.raw_value(), |m| m.curve);
            k.motion = Some(MotionDefaults { duration: t, curve });
        });
    }

    /// The scrub field's events: offsets re-read the whole position, the motion duration goes to the kit.
    fn apply(&mut self, s: &mut EditorSession, events: Vec<ScrubEvent>, k: &Control) {
        let is_motion = *k == Control::MotionDuration;
        for e in events {
            match e {
                ScrubEvent::Begin => {
                    if is_motion {
                        self.motion_started = false;
                    } else {
                        self.offset_gesture_fresh = true;
                    }
                }
                ScrubEvent::Live(v) | ScrubEvent::Change(v) => {
                    self.set_field(k, v);
                    if is_motion {
                        let started = self.motion_started;
                        self.set_motion_duration(s, v, started);
                        self.motion_started = true;
                    } else {
                        self.position_changed(s, k);
                    }
                }
                ScrubEvent::End(v) | ScrubEvent::Cancel(v) => {
                    let changed = self.fields.get(k).map(|f| f.value) != Some(v);
                    self.set_field(k, v);
                    if is_motion {
                        let started = self.motion_started;
                        if !started || changed {
                            self.set_motion_duration(s, v, started);
                        }
                        self.motion_started = false;
                        self.refresh(s);
                    } else if changed || self.offset_gesture_fresh {
                        self.position_changed(s, k);
                    }
                }
            }
        }
    }

    fn set_field(&mut self, k: &Control, v: f64) {
        if let Some(f) = self.fields.get_mut(k) {
            f.value = v;
        }
    }

    /// Commits the focused number field and the text box (a menu chord, a press in another panel).
    pub fn end_text_edits(&mut self, s: &mut EditorSession, ui: &mut UiCx) {
        if let Some(f) = self.focused.clone() {
            self.resign_field(s, ui, &f);
        }
        self.block.resign_focus(&mut self.inspector_model, ui);
        self.pump_block(s);
    }

    fn resign_field(&mut self, s: &mut EditorSession, ui: &mut UiCx, k: &Control) {
        self.focused = None;
        let Some(f) = self.fields.get_mut(k) else { return };
        let ev = f.resign_focus(ui);
        self.apply(s, ev, k);
    }

    // MARK: Looks

    /// A MINE tile: its look goes to every caption and the tile counts as the picked style.
    fn pick_mine(&mut self, s: &mut EditorSession, i: usize) {
        let Some(id) = self.mine.get(i).map(|m| m.0.clone()) else { return };
        let Some(look) = self.look_host.as_ref().and_then(|h| h.look_of(&id)) else { return };
        self.last_edit = None;
        s.push_caption_look(&look, &id, None);
        self.picked_look = Some(id);
        self.refresh(s);
    }

    /// The registry key of a built-in style used as a caption look.
    fn built_in_key(id: &str) -> String {
        format!("built-in-{id}")
    }

    /// A tile of the BUILT IN group: the style goes on every caption, like a saved one.
    fn pick_built_in(&mut self, s: &mut EditorSession, i: usize) {
        let Some((id, _, style)) = self.built_ins.get(i).cloned() else { return };
        let look = CaptionLook::new(style, sq_core_model::anchored_animation::KeyframeTemplate::none());
        let key = Self::built_in_key(&id);
        self.last_edit = None;
        s.push_caption_look(&look, &key, None);
        self.picked_look = Some(key);
        self.refresh(s);
    }

    /// The star of a MINE tile: makes it the default for Create Captions, or clears it when it already is.
    fn toggle_star(&mut self, s: &mut EditorSession, i: usize) {
        let Some((id, _, is_default)) = self.mine.get(i).cloned() else { return };
        let target = (!is_default).then_some(id);
        if !self.look_host.as_mut().is_some_and(|h| h.set_default(target.as_deref())) {
            self.status(SQL10n::string("The default style could not be changed."));
        }
        self.refresh(s);
    }

    fn lookup_count(&self) -> usize {
        self.look_host.as_ref().map_or(0, |h| h.looks_count())
    }

    /// The current look becomes a saved look and the default for Create Captions.
    fn save_look_clicked(&mut self, s: &mut EditorSession) {
        if s.current_caption_look().is_none() {
            return;
        }
        let initial = SQL10n::format("Caption Look %@", &[&(self.lookup_count() + 1).to_string()]);
        let Some(ask) = self.ask_name.as_mut() else {
            self.save_look(s, &initial);
            return;
        };
        let sink = Rc::clone(&self.sink);
        ask(
            &SQL10n::string("Save as New Look"),
            &initial,
            Box::new(move |name| sink.borrow_mut().push(StyleCommand::SaveLookNamed(name))),
        );
    }

    fn save_look(&mut self, s: &mut EditorSession, name: &str) {
        let Some(look) = s.current_caption_look() else { return };
        let seg = (self.segmentation)();
        let id = self.look_host.as_mut().and_then(|h| h.save(name, &look, &seg));
        match id {
            Some(id) => {
                s.push_caption_look(&look, &id, None);
                self.picked_look = Some(id);
                self.status(SQL10n::string("Look saved as the default for Create Captions."));
            }
            None => self.status(SQL10n::string("The look could not be saved.")),
        }
        self.refresh(s);
    }

    /// Edit one caption (or all), then push: its look goes to every caption and into the default look.
    fn update_look_clicked(&mut self, s: &mut EditorSession) {
        let Some(look) = s.current_caption_look() else { return };
        let picked = self.picked_look.clone();
        let Some(id) = picked.or_else(|| self.look_host.as_ref().and_then(|h| h.default_look_id())) else {
            let name = SQL10n::format("Caption Look %@", &[&(self.lookup_count() + 1).to_string()]);
            self.save_look(s, &name);
            return;
        };
        if self.look_host.as_mut().is_some_and(|h| h.update(&id, &look)) {
            s.push_caption_look(&look, &id, None);
            self.status(SQL10n::string("Look updated on every caption."));
        } else {
            self.status(SQL10n::string("The look could not be updated."));
        }
        self.refresh(s);
    }

    fn text_anim_clicked(&mut self, s: &mut EditorSession) {
        let (Some(a), Some(mut look)) = (s.animation_from_selected_text_clip(), s.current_caption_look()) else {
            return;
        };
        look.animation = a;
        let seg = (self.segmentation)();
        let n = self.lookup_count() + 1;
        let id = match self.look_host.as_ref().and_then(|h| h.default_look_id()) {
            Some(id) => self.look_host.as_mut().is_some_and(|h| h.update(&id, &look)).then_some(id),
            None => self.look_host.as_mut().and_then(|h| h.save(&format!("Caption Look {n}"), &look, &seg)),
        };
        match id {
            Some(id) => {
                s.push_caption_look(&look, &id, None);
                self.status(SQL10n::string("Animation taken from the text clip and saved in the default look."));
            }
            None => self.status(SQL10n::string("The look could not be saved.")),
        }
        self.refresh(s);
    }

    // MARK: Wheel, keys, frame tick, help

    pub fn scroll(&mut self, _p: CGPoint, dy: f64) -> bool {
        let max = self.max_scroll();
        if max <= 0.0 {
            return false;
        }
        self.scroll_y = (self.scroll_y - dy).clamp(0.0, max);
        true
    }

    /// The text block's focused field first, then the focused number field (typing, arrows, Return / Esc).
    pub fn key(&mut self, s: &mut EditorSession, ui: &mut UiCx, k: InputKey, m: InputModifiers) -> bool {
        self.now = ui.now;
        if self.block.key(&mut self.inspector_model, k, m, ui) {
            self.pump_block(s);
            return true;
        }
        let Some(f) = self.focused.clone() else { return false };
        if k == InputKey::Character('\t') {
            self.resign_field(s, ui, &f);
            return true;
        }
        let Some(fd) = self.fields.get_mut(&f) else { return false };
        let (ev, used) = fd.key_used(k, m, ui.now, ui);
        let ended = !fd.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
        self.apply(s, ev, &f);
        if ended {
            self.focused = None;
        }
        used
    }

    /// Per frame: ends arrow bursts; true while the gallery previews a look (the host keeps redrawing).
    pub fn tick(&mut self, s: &mut EditorSession, now: f64) -> bool {
        self.now = now;
        self.block.tick(&mut self.inspector_model, now);
        self.drain_model_events(Some(s));
        let keys: Vec<Control> = self.fields.keys().cloned().collect();
        for k in keys {
            let Some(f) = self.fields.get_mut(&k) else { continue };
            let ev = f.tick(now);
            if !ev.is_empty() {
                self.apply(s, ev, &k);
            }
        }
        self.gallery.tick()
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        let tip: Option<String> = match self.hit(p)? {
            Hit::Block(q) => return self.block.help(&self.inspector_model, q, Part::KitLook),
            Hit::Gallery(q) => return self.gallery.help(q),
            Hit::Control(k) => match k {
                Control::Scope(i) => Some(if i == 0 { "All Captions" } else { "Selected Captions" }.to_string()),
                Control::Track => Some("Caption Track".to_string()),
                Control::Header(s) => {
                    Some(format!("{} {}", if self.is_open(s) { "Collapse" } else { "Expand" }, s.title()))
                }
                Control::Animation => Some("Caption Animation".to_string()),
                Control::Karaoke => Some("Word Highlight".to_string()),
                Control::KaraokeWell => Some("Highlight Color".to_string()),
                Control::KaraokeKeep => Some("Keep Spoken Words Lit".to_string()),
                Control::Vertical(_) => Some("Caption Position".to_string()),
                Control::Horizontal(i) => Some(Self::HORIZONTAL_ICONS[i.min(2)].1.to_string()),
                Control::Offset { is_y } => Some(if is_y { "Offset Y" } else { "Offset X" }.to_string()),
                Control::ResetPosition => Some("Reset to Kit Position".to_string()),
                Control::SaveLook => Some("Save Look".to_string()),
                Control::UpdateLook => Some(self.update_title()),
                Control::Mine(i) => self.mine.get(i).map(|m| format!("Use \"{}\" on every caption", m.1)),
                Control::MineStar(_) => Some("Default for Create Captions".to_string()),
                Control::BuiltIn(i) => self.built_ins.get(i).map(|m| format!("Use \"{}\" on every caption", m.1)),
                Control::ResetLook => Some("Reset to Track Look".to_string()),
                Control::KitLook => Some("Look to Kit".to_string()),
                Control::TextAnim => Some("Animation from Text Clip".to_string()),
                Control::BrandFont(n) => {
                    return Some(SQL10n::format("%@ Font", &[&SQL10n::string(&AnimationPresetName::title(&n))]));
                }
                Control::BrandColor(n) => {
                    return Some(SQL10n::format("%@ Color", &[&SQL10n::string(&AnimationPresetName::title(&n))]));
                }
                Control::MotionDuration => Some("Motion Duration".to_string()),
                Control::MotionCurve => Some("Motion Curve".to_string()),
            },
        };
        tip.map(|t| SQL10n::string(&t))
    }

    /// Typing in the text block or a number field (the host keeps IME on while it is open).
    pub fn is_editing_text(&self) -> bool {
        self.block.is_typing() || self.focused.as_ref().and_then(|f| self.fields.get(f)).is_some_and(|f| f.is_editing())
    }
}

fn default_position() -> CaptionPosition {
    CaptionPosition {
        vertical: CaptionVertical::Bottom,
        horizontal: CaptionHorizontal::Center,
        offset_x: 0.0,
        offset_y: 0.0,
    }
}

fn effect_color(red: f64, green: f64, blue: f64, alpha: f64) -> EffectColor {
    EffectColor { red, green, blue, alpha }
}

fn offset_y(r: CGRect, dy: f64) -> CGRect {
    CGRect::new(r.min_x(), r.min_y() + dy, r.width, r.height)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn y_is_shown_up() {
        assert_eq!(CaptionOffsetDisplay::shown(0.1, true), -10.0); // stored down, shown up
        assert_eq!(CaptionOffsetDisplay::shown(-0.25, true), 25.0);
        assert_eq!(CaptionOffsetDisplay::shown(0.1, false), 10.0);
    }

    #[test]
    fn round_trip_and_no_negative_zero() {
        let mut v = -0.5;
        while v <= 0.5 {
            assert_eq!(CaptionOffsetDisplay::stored(CaptionOffsetDisplay::shown(v, true), true), v);
            assert_eq!(CaptionOffsetDisplay::stored(CaptionOffsetDisplay::shown(v, false), false), v);
            v += 0.125;
        }
        assert!(CaptionOffsetDisplay::shown(0.0, true).is_sign_positive());
        assert!(CaptionOffsetDisplay::stored(0.0, true).is_sign_positive());
    }

    #[test]
    fn motion_time_is_whole_milliseconds_and_clamped() {
        assert_eq!(CaptionKitMotion::time(0.5), Some(Time::new(1, 2)));
        assert_eq!(CaptionKitMotion::time(1000.0), Some(Time::new(600, 1)));
        assert_eq!(CaptionKitMotion::time(0.0), None);
        assert_eq!(CaptionKitMotion::time(f64::NAN), None);
    }

    fn session_with_caption() -> EditorSession {
        use sq_core_model::{Project, SequenceFormat, Timeline, Track, TrackKind};
        use sq_core_time::SequentialIds;
        use sq_editor_session::SessionDeps;
        let mut ids = SequentialIds::default();
        let tracks = vec![Track::new(ids.next_id(), TrackKind::Video), Track::new(ids.next_id(), TrackKind::Audio)];
        let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 30)), tracks);
        let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
        let dir = std::env::temp_dir().join(format!("sq-inspector-ui-style-tab-{}", std::process::id()));
        let mut deps = SessionDeps::headless(dir);
        deps.ids = Box::new(SequentialIds::default());
        let mut s = EditorSession::new(project, deps);
        assert!(s.add_caption_at_playhead().is_some());
        s
    }

    fn tab() -> CaptionStyleTabDraw {
        CaptionStyleTabDraw::new(Box::new(Vec::new), Box::new(sq_core_time::SequentialIds::default()))
    }

    struct Stub;
    impl crate::ec::animation::AnimationKeystoneSource for Stub {
        fn offered_animations(
            &self,
            _: sq_core_graphics::custom_animation::AnimationSide,
        ) -> Vec<sq_core_effects::keystone::Keystone> {
            Vec::new()
        }
        fn can_save(&self) -> bool {
            true
        }
        fn save(&self, _: sq_core_effects::keystone::Keystone) -> bool {
            true
        }
    }

    /// The style tab's text model reads the same Library keystones as the Graphics panel's.
    #[test]
    fn the_style_tab_takes_the_animation_keystones() {
        let mut t = tab();
        assert!(t.inspector_model.keystones.is_none());
        t.set_animation_keystones(Rc::new(Stub));
        assert!(t.inspector_model.keystones.as_ref().is_some_and(|k| k.can_save()));
    }

    #[test]
    fn refresh_shows_the_style_once_a_caption_exists() {
        let s = session_with_caption();
        let mut d = tab();
        assert!(!d.state_shown());
        d.refresh(&s);
        assert!(d.state_shown());
        // A new caption is selected, so the tab edits that caption.
        assert_eq!(d.scope(), CaptionStyleScope::Selected);
        assert!(d.frame(&Control::Vertical(0)).is_some());
    }

    #[test]
    fn a_vertical_segment_moves_the_selected_caption() {
        let mut s = session_with_caption();
        let mut d = tab();
        d.refresh(&s);
        let r = d.frame(&Control::Vertical(0)).expect("segment shown");
        let (mut cx, p) = (UiCx::new(), CGPoint::new(r.mid_x(), r.mid_y()));
        d.mouse_down(&mut s, &mut cx, p, InputModifiers::NONE, Some(1));
        d.mouse_up(&mut s, &mut cx, p);
        let own = s.caption_items()[0].position.map(|p| p.vertical);
        assert_eq!(own, Some(CaptionVertical::Top));
    }

    #[test]
    fn a_header_click_folds_its_section() {
        let mut s = session_with_caption();
        let mut d = tab();
        d.refresh(&s);
        assert!(d.is_open(Section::Layout));
        let r = d.frame(&Control::Header(Section::Layout)).expect("header shown");
        let (mut cx, p) = (UiCx::new(), CGPoint::new(r.mid_x(), r.mid_y()));
        d.mouse_down(&mut s, &mut cx, p, InputModifiers::NONE, Some(1));
        d.mouse_up(&mut s, &mut cx, p);
        assert!(!d.is_open(Section::Layout));
        assert!(d.frame(&Control::Vertical(0)).is_none());
    }

    #[test]
    fn a_folded_section_comes_back_from_the_settings_store() {
        let mut s = session_with_caption();
        let store = crate::open_state::SharedDefaults::default();
        let mut d = tab();
        d.set_defaults(Box::new(store.clone()));
        d.refresh(&s);
        let r = d.frame(&Control::Header(Section::Layout)).expect("header shown");
        let (mut cx, p) = (UiCx::new(), CGPoint::new(r.mid_x(), r.mid_y()));
        d.mouse_down(&mut s, &mut cx, p, InputModifiers::NONE, Some(1));
        d.mouse_up(&mut s, &mut cx, p);
        let mut again = tab();
        assert!(again.is_open(Section::Layout));
        again.set_defaults(Box::new(store));
        assert!(!again.is_open(Section::Layout));
    }

    /// Saved styles in memory: what the host's Look store and settings answer.
    type FakeStore = (Vec<(String, String, CaptionLook)>, Option<String>);
    struct FakeLooks(Rc<RefCell<FakeStore>>);
    impl CaptionLookHost for FakeLooks {
        fn looks_count(&self) -> usize {
            self.0.borrow().0.len()
        }
        fn default_look_id(&self) -> Option<String> {
            self.0.borrow().1.clone()
        }
        fn save(&mut self, _: &str, _: &CaptionLook, _: &CaptionPreset) -> Option<String> {
            None
        }
        fn update(&mut self, id: &str, look: &CaptionLook) -> bool {
            let mut b = self.0.borrow_mut();
            b.0.iter_mut().find(|l| l.0 == id).map(|l| l.2 = look.clone()).is_some()
        }
        fn saved(&self) -> Vec<(String, String, bool)> {
            let b = self.0.borrow();
            b.0.iter().map(|l| (l.0.clone(), l.1.clone(), b.1.as_deref() == Some(l.0.as_str()))).collect()
        }
        fn look_of(&self, id: &str) -> Option<CaptionLook> {
            self.0.borrow().0.iter().find(|l| l.0 == id).map(|l| l.2.clone())
        }
        fn mark(&self, id: &str, current: &CaptionLook) -> Option<CaptionStyleMark> {
            let b = self.0.borrow();
            let l = b.0.iter().find(|l| l.0 == id)?;
            Some(CaptionStyleMark {
                id: Id::fixed(1),
                name: l.1.clone(),
                edited: l.2 != *current,
                is_default: b.1.as_deref() == Some(id),
            })
        }
        fn set_default(&mut self, id: Option<&str>) -> bool {
            self.0.borrow_mut().1 = id.map(str::to_string);
            true
        }
    }

    fn click_control(d: &mut CaptionStyleTabDraw, s: &mut EditorSession, k: &Control) {
        let r = d.frame(k).expect("control shown");
        let (mut cx, p) = (UiCx::new(), CGPoint::new(r.mid_x(), r.mid_y()));
        d.mouse_down(s, &mut cx, p, InputModifiers::NONE, Some(1));
        d.mouse_up(s, &mut cx, p);
    }

    #[test]
    fn a_picked_style_shows_edited_after_a_change_and_update_names_it() {
        let mut s = session_with_caption();
        let mut d = tab();
        let store = Rc::new(RefCell::new((
            vec![("a".to_string(), "My Shorts".to_string(), CaptionLook::default_look())],
            None,
        )));
        d.look_host = Some(Box::new(FakeLooks(Rc::clone(&store))));
        d.refresh(&s);
        assert_eq!(d.update_title(), "Update Style");
        assert!(d.frame(&Control::Mine(0)).is_some());
        click_control(&mut d, &mut s, &Control::Mine(0));
        assert_eq!(d.mark.as_ref().map(|m| (m.name.as_str(), m.edited)), Some(("My Shorts", false)));
        assert!(!d.layout().0.iter().any(|i| matches!(i, Item::Edited(_))));
        // The user changes the size under the style: the look differs from the picked style.
        assert!(s.edit_caption_style(CaptionStyleField::Size(91.0), CaptionStyleScope::All, false));
        d.refresh(&s);
        assert_eq!(d.mark.as_ref().map(|m| m.edited), Some(true));
        assert_eq!(d.update_title(), "Update \u{201C}My Shorts\u{201D}");
        assert!(d.layout().0.iter().any(|i| matches!(i, Item::Edited(_))));
        // Update writes the current look into the style: no longer edited.
        click_control(&mut d, &mut s, &Control::UpdateLook);
        assert_eq!(d.mark.as_ref().map(|m| m.edited), Some(false));
        assert!(!d.layout().0.iter().any(|i| matches!(i, Item::Edited(_))));
    }

    #[test]
    fn the_star_marks_one_default_and_a_second_click_clears_it() {
        let mut s = session_with_caption();
        let mut d = tab();
        let look = CaptionLook::default_look();
        let rows = vec![("a".to_string(), "A".to_string(), look.clone()), ("b".to_string(), "B".to_string(), look)];
        let store = Rc::new(RefCell::new((rows, None)));
        d.look_host = Some(Box::new(FakeLooks(Rc::clone(&store))));
        d.refresh(&s);
        assert!(d.mine.iter().all(|m| !m.2));
        click_control(&mut d, &mut s, &Control::MineStar(1));
        assert_eq!(d.mine.iter().map(|m| m.2).collect::<Vec<_>>(), [false, true]);
        assert_eq!(store.borrow().1.as_deref(), Some("b"));
        click_control(&mut d, &mut s, &Control::MineStar(0));
        assert_eq!(d.mine.iter().map(|m| m.2).collect::<Vec<_>>(), [true, false]);
        click_control(&mut d, &mut s, &Control::MineStar(0));
        assert_eq!(store.borrow().1, None);
        // A tile and its star are two targets: the star does not pick the style.
        assert!(d.picked_look.is_none());
    }

    #[test]
    fn the_style_grid_is_six_wide_in_a_wide_panel_and_the_scope_row_carries_the_buttons() {
        let s = session_with_caption();
        let mut d = tab();
        d.refresh(&s);
        d.set_size(CGSize::new(900.0, 900.0));
        assert_eq!(CaptionStyleTabDraw::tile_columns(615.0), 6);
        let items = d.layout().0;
        let top = |k: &Control| {
            items.iter().find_map(|i| if let Item::Control(c, r) = i { (c == k).then_some(*r) } else { None })
        };
        let (scope, save) = (top(&Control::Scope(0)).expect("scope"), top(&Control::SaveLook).expect("save"));
        assert!((scope.min_y() - save.min_y()).abs() < 12.0, "one row: {scope:?} {save:?}");
        assert!(save.min_x() > scope.max_x());
    }

    #[test]
    fn built_in_group_lists_named_styles_and_a_click_puts_one_on_the_captions() {
        let mut s = session_with_caption();
        let mut d = tab();
        d.refresh(&s);
        let names: Vec<&str> = d.built_ins.iter().map(|b| b.1.as_str()).collect();
        assert!(names.contains(&"Bold Box") && names.contains(&"Pill") && names.contains(&"Lower Third"), "{names:?}");
        let i = d.built_ins.iter().position(|b| b.1 == "Bold Box").expect("Bold Box");
        let want = d.built_ins[i].2.clone();
        // the style grid sits above the Look section; the animated gallery moved down into Motion
        let items = d.layout().0;
        let tile = items.iter().position(|it| matches!(it, Item::Control(Control::BuiltIn(0), _))).expect("tile");
        let look = items.iter().position(|it| matches!(it, Item::Header(Section::Look, ..))).expect("look header");
        let gallery = items.iter().position(|it| matches!(it, Item::Gallery(_))).expect("gallery");
        assert!(tile < look && look < gallery);
        click_control(&mut d, &mut s, &Control::BuiltIn(i));
        assert_eq!(d.picked_look.as_deref(), Some("built-in-bold-box"));
        d.refresh(&s);
        assert_eq!(d.picked_look.as_deref(), Some("built-in-bold-box"), "a refresh keeps the pick");
        let now = s.current_caption_look().expect("look").style;
        assert_eq!(now.background, want.background);
    }
}
