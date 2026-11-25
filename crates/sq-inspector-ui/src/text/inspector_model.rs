// Swift: TextInspectorModel.swift
//! State and edit logic of the text properties inspector. Every edit goes through `edit`, which brackets it in
//! begin/end for undo coalescing unless the caller already opened a session (`begin_editing` ... `end_editing`, e.g. for
//! a color-well drag).

use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use sq_core_effects::keystone::Keystone;
use sq_core_graphics::custom_animation::{
    AnimationSetCustomExt, AnimationSide, KeyframeTemplateCustomExt, KeystoneAnimationExt,
};
use sq_core_model::StyleKit;
use sq_core_model::anchored_animation::{
    AnimationAnchor, AnimationSet, KeyframeTemplate, SegmentShape, TextAnimator, TextAnimatorEffect, TextAnimatorOrder,
    TextAnimatorUnit, TextSlideDirection,
};
use sq_core_time::{Id, IdSource, Time, Vec2};
use sq_text::bundled_fonts;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::caption_style_looks::{CaptionStyleLook, CaptionStyleLooks};
use sq_text::font_resolver::{Axis, FontResolver};
use sq_text::style_kit_text::TokenField as StyleTokenField;
use sq_text::text_align_to_frame::FrameAlignment;
use sq_text::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextDirection, TextFootageFill,
    TextGradient, TextLineStyle, TextListKind, TextShadow, TextStroke, TextStyle, TextVerticalAlignment,
};

use crate::ec::animation::{AnimationChoices, AnimationKeystoneSource};
use crate::text::style_library::TextStyleLibrary;

/// What the model reports to its host, in Swift's call order (the `onX` closures of the Swift class).
#[derive(Clone, Debug, PartialEq)]
pub enum TextInspectorEvent {
    /// `onBeginEditing`.
    BeginEditing,
    /// `onChange`: the new style and animations, and the template paths ("style.italic") the host must copy to every
    /// selected clip even where the shown clip did not change (`pendingForcedPaths`; empty outside a style edit).
    Change(Box<TextStyle>, Box<AnimationSet>, BTreeSet<String>),
    /// `onEndEditing`.
    EndEditing,
    /// `onPresetsChanged`: the host persists the library.
    PresetsChanged(Box<CaptionPresetLibrary>),
    /// `onStylesChanged`: the host persists the user's text styles.
    StylesChanged(Box<TextStyleLibrary>),
    /// `onAlignToFrame`: the host moves the clip so its text block meets the frame.
    AlignToFrame(FrameAlignment),
}

/// Which side of the animator rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnimatorSide {
    In,
    Out,
}

/// The style fields that can follow a kit token.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TokenField {
    Font,
    Color,
    StrokeColor,
    BackgroundColor,
}

impl TokenField {
    pub const ALL: [TokenField; 4] =
        [TokenField::Font, TokenField::Color, TokenField::StrokeColor, TokenField::BackgroundColor];

    fn style_field(self) -> StyleTokenField {
        match self {
            TokenField::Font => StyleTokenField::Font,
            TokenField::Color => StyleTokenField::Color,
            TokenField::StrokeColor => StyleTokenField::StrokeColor,
            TokenField::BackgroundColor => StyleTokenField::BackgroundColor,
        }
    }

    /// The field exists in `s` (stroke and background color only with a stroke / background).
    pub fn is_available(self, s: &TextStyle) -> bool {
        match self {
            TokenField::Font | TokenField::Color => true,
            TokenField::StrokeColor => s.stroke.is_some(),
            TokenField::BackgroundColor => s.background.is_some(),
        }
    }
}

fn token_slot(t: &mut sq_text::style_kit_text::TextStyleTokens, f: TokenField) -> &mut Option<String> {
    match f {
        TokenField::Font => &mut t.font,
        TokenField::Color => &mut t.color,
        TokenField::StrokeColor => &mut t.stroke_color,
        TokenField::BackgroundColor => &mut t.background_color,
    }
}

fn with_alpha(c: RGBAColor, a: f64) -> RGBAColor {
    RGBAColor::new(c.red, c.green, c.blue, a)
}

/// Defaults the text inspector restores when a box background or shadow is switched on again, and the font families it
/// offers.
pub enum TextBoxDefaults {}

impl TextBoxDefaults {
    pub fn background_color() -> RGBAColor {
        with_alpha(RGBAColor::BLACK, 0.75)
    }

    pub fn background_padding() -> BoxPadding {
        BoxPadding::new(16.0, 8.0)
    }

    pub const BACKGROUND_RADIUS: f64 = 8.0;

    pub fn shadow_color() -> RGBAColor {
        with_alpha(RGBAColor::BLACK, 0.6)
    }

    /// The bundled families and the installed ones, each once, sorted case-insensitively (Swift `FontFamilyList`: the
    /// font manager's list, which includes the bundled fonts there).
    pub fn installed_families() -> Vec<String> {
        let mut all = bundled_fonts::picker_names();
        all.extend(sq_text::system_fonts::families());
        all.sort_by_cached_key(|n| n.to_lowercase());
        all.dedup_by(|a, b| a.to_lowercase() == b.to_lowercase());
        all
    }
}

/// State and edit logic of the text properties inspector.
pub struct TextInspectorModel {
    style: TextStyle,
    animations: AnimationSet,
    library: CaptionPresetLibrary,
    styles: TextStyleLibrary,
    applied_style_id: Option<String>,
    fixed_library: Option<CaptionPresetLibrary>,
    saved_styles: BTreeMap<String, TextStyle>,
    font_families: Vec<String>,
    session_depth: i64,
    family_provider: Box<dyn Fn() -> Vec<String>>,
    last_stroke: TextStroke,
    last_gradient: Option<TextGradient>,
    last_background: TextBackground,
    last_second_line: Option<TextLineStyle>,
    last_shadow: TextShadow,
    events: Vec<TextInspectorEvent>,
    ids: Box<dyn IdSource>,
    picked: BTreeMap<u8, String>,
    version: u64,
    /// Multi-select: dotted paths of the template fields ("style.size", "style.shadow", "text") that differ between the
    /// selected text clips; the panel shows those fields empty. Set by the host, empty for one clip.
    pub mixed_paths: BTreeSet<String>,
    /// Picture size of the sequence: a saved animation stores Position as a fraction of it.
    pub frame_size: Vec2,
    /// The Library's keystones of this window: where the Intro / Outro popups read saved animations. Set by the host.
    pub keystones: Option<Rc<dyn AnimationKeystoneSource>>,
    /// What the model edits now (the host sets the clip or layer id).
    pub target: Option<Id>,
    /// The project's style kit (the host sets it on every load); `None` = no kit and the bind controls are off.
    pub kit: Option<StyleKit>,
    /// Length of the clip the animations play on; set by the host. Bounds Intro + Outro (zones never overlap).
    pub clip_duration: Option<Time>,
}

fn side_key(s: AnimationSide) -> u8 {
    if s == AnimationSide::Intro { 0 } else { 1 }
}

impl TextInspectorModel {
    /// Shortest zone the length fields accept.
    pub const MINIMUM_ZONE_MILLISECONDS: i64 = 50;
    /// Longest stagger / length the fields accept (= `TextAnimator::MAX_TIME`).
    pub const MAX_ANIMATOR_MILLISECONDS: i64 = 60_000;
    pub const DEFAULT_ANIMATOR_DISTANCE: f64 = 40.0;
    pub const DEFAULT_ANIMATOR_BLUR: f64 = 12.0;
    pub const MAX_ANIMATOR_PIXELS: f64 = 2000.0;

    /// `library`: `None` = the live caption library, re-read on every `load`.
    pub fn new(
        style: TextStyle,
        animations: AnimationSet,
        library: Option<CaptionPresetLibrary>,
        font_families: Box<dyn Fn() -> Vec<String>>,
        styles: TextStyleLibrary,
        ids: Box<dyn IdSource>,
    ) -> TextInspectorModel {
        let mut m = TextInspectorModel {
            library: library.clone().unwrap_or_else(CaptionPresetLibrary::built_in),
            fixed_library: library,
            style: style.clone(),
            animations,
            styles,
            applied_style_id: None,
            saved_styles: BTreeMap::new(),
            font_families: Vec::new(),
            session_depth: 0,
            family_provider: font_families,
            last_stroke: TextStroke::new(RGBAColor::BLACK, 4.0, StrokePosition::Outside),
            last_gradient: None,
            last_background: TextBackground::new(
                TextBoxDefaults::background_color(),
                TextBoxDefaults::background_padding(),
                TextBoxDefaults::BACKGROUND_RADIUS,
            ),
            last_second_line: None,
            last_shadow: TextShadow::new(TextBoxDefaults::shadow_color(), 0.0, 2.0, 6.0),
            events: Vec::new(),
            ids,
            picked: BTreeMap::new(),
            version: 0,
            mixed_paths: BTreeSet::new(),
            frame_size: Vec2::new(1080.0, 1920.0),
            keystones: None,
            target: None,
            kit: None,
            clip_duration: None,
        };
        m.remember(&style);
        m.refresh_families();
        m
    }

    /// Bumped by every change of what the panel shows.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The events since the last call, in order.
    pub fn take_events(&mut self) -> Vec<TextInspectorEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn style(&self) -> &TextStyle {
        &self.style
    }

    pub fn animations(&self) -> &AnimationSet {
        &self.animations
    }

    pub fn library(&self) -> &CaptionPresetLibrary {
        &self.library
    }

    /// Text styles (look only): the built-in set plus the user's saved ones.
    pub fn styles(&self) -> &TextStyleLibrary {
        &self.styles
    }

    /// The style last applied or saved from this inspector; with `style` it tells whether the clip was edited away from it.
    pub fn applied_style_id(&self) -> Option<&str> {
        self.applied_style_id.as_deref()
    }

    /// Installed font families (plus the current font name when it is not one of them).
    pub fn font_families(&self) -> &[String] {
        &self.font_families
    }

    /// True when the style field at `path` ("size", "shadow.blur") differs between the selected clips.
    pub fn is_mixed(&self, path: &str) -> bool {
        self.mixed_paths.contains(&format!("style.{path}"))
    }

    /// The color at `path` ("color", "shadow.color") differs in red, green or blue (opacity has its own field), or its
    /// layer is on in some clips and off in others: the well shows the mixed state.
    pub fn is_mixed_color(&self, path: &str) -> bool {
        if ["red", "green", "blue"].iter().any(|c| self.is_mixed(&format!("{path}.{c}"))) || self.is_mixed(path) {
            return true;
        }
        // "stroke.color": the stroke layer itself switched differently.
        let Some(dot) = path.rfind('.') else { return false };
        self.is_mixed_presence(&path[..dot])
    }

    /// A layer group ("stroke", "background", "shadow", "secondLine") is on in some clips and off in others.
    pub fn is_mixed_presence(&self, group: &str) -> bool {
        self.mixed_paths.contains(&format!("style.{group}"))
    }

    pub fn load(&mut self, style: TextStyle, animations: AnimationSet) {
        if self.session_depth > 0 {
            // An open edit session belongs to the previous values.
            self.session_depth = 0;
            self.events.push(TextInspectorEvent::EndEditing);
        }
        self.style = style.clone();
        self.animations = animations;
        self.applied_style_id = self.styles.match_style(&style);
        self.remember(&style);
        self.refresh_families();
        self.refresh_library();
        self.version += 1;
    }

    /// Re-reads the caption library (the kit or saved looks may have changed since the last load).
    pub fn refresh_library(&mut self) {
        let base = self.fixed_library.clone().unwrap_or_else(CaptionPresetLibrary::built_in);
        if self.saved_styles.is_empty() {
            if base.styles != self.library.styles || base.animations != self.library.animations {
                self.library = base;
                self.version += 1;
            }
            return;
        }
        let mut styles = base.styles.clone();
        for (k, v) in &self.saved_styles {
            styles.insert(k.clone(), v.clone());
        }
        self.library = CaptionPresetLibrary::new(
            styles,
            base.animations.clone(),
            &base.default_style_id,
            &base.default_animation_id,
        );
        self.version += 1;
    }

    // MARK: Sessions

    pub fn begin_editing(&mut self) {
        if self.session_depth == 0 {
            self.events.push(TextInspectorEvent::BeginEditing);
        }
        self.session_depth += 1;
    }

    pub fn end_editing(&mut self) {
        if self.session_depth <= 0 {
            return;
        }
        self.session_depth -= 1;
        if self.session_depth == 0 {
            self.events.push(TextInspectorEvent::EndEditing);
        }
    }

    /// `fields`: the style fields the edit sets ("italic", "shadow"); those that are mixed are forced to all clips.
    fn edit(&mut self, fields: &[&str], body: impl FnOnce(&mut TextStyle)) {
        let mut s = self.style.clone();
        body(&mut s);
        let forced: BTreeSet<String> = fields
            .iter()
            .map(|f| format!("style.{f}"))
            .filter(|f| self.mixed_paths.iter().any(|p| p == f || p.starts_with(&format!("{f}."))))
            .collect();
        if s == self.style && forced.is_empty() {
            return;
        }
        self.begin_editing();
        self.style = s.clone();
        self.remember(&s);
        self.events.push(TextInspectorEvent::Change(
            Box::new(self.style.clone()),
            Box::new(self.animations.clone()),
            forced,
        ));
        self.end_editing();
        self.version += 1;
    }

    fn edit_animations(&mut self, body: impl FnOnce(&mut AnimationSet)) {
        let mut a = self.animations.clone();
        body(&mut a);
        if a == self.animations {
            return;
        }
        self.begin_editing();
        self.animations = a;
        self.events.push(TextInspectorEvent::Change(
            Box::new(self.style.clone()),
            Box::new(self.animations.clone()),
            BTreeSet::new(),
        ));
        self.end_editing();
        self.version += 1;
    }

    /// What a layer starts with when switched on while the style has none (a host with its own defaults, e.g. the caption
    /// pill). Fires no events; a layer the style already has keeps its own values.
    pub fn seed_layer_defaults(
        &mut self,
        background: Option<TextBackground>,
        stroke: Option<TextStroke>,
        shadow: Option<TextShadow>,
    ) {
        if self.style.background.is_none()
            && let Some(b) = background
        {
            self.last_background = b;
        }
        if self.style.stroke.is_none()
            && let Some(s) = stroke
        {
            self.last_stroke = s;
        }
        if self.style.shadow.is_none()
            && let Some(s) = shadow
        {
            self.last_shadow = s;
        }
    }

    fn remember(&mut self, s: &TextStyle) {
        if let Some(v) = s.stroke {
            self.last_stroke = v;
        }
        if let Some(v) = s.background {
            self.last_background = v;
        }
        if let Some(g) = s.gradient {
            self.last_gradient = Some(g);
        }
        if let Some(v) = s.shadow {
            self.last_shadow = v;
        }
        if let Some(v) = &s.second_line {
            self.last_second_line = Some(v.clone());
        }
    }

    fn refresh_families(&mut self) {
        let mut f = (self.family_provider)();
        if !self.style.font_name.is_empty() && !f.contains(&self.style.font_name) {
            f.insert(0, self.style.font_name.clone());
        }
        if let Some(n) = self.style.second_line.as_ref().map(|l| l.font_name.clone())
            && !n.is_empty()
            && !f.contains(&n)
        {
            f.insert(0, n);
        }
        self.font_families = f;
    }

    // MARK: Basic

    pub fn set_font_family(&mut self, name: &str) {
        self.edit(&["fontName"], |s| {
            s.font_name = name.to_string();
            s.unbind(StyleTokenField::Font);
        });
        self.refresh_families();
    }

    pub fn set_weight(&mut self, w: FontWeight) {
        self.edit(&["weight"], |s| s.weight = w);
    }

    pub fn set_size(&mut self, v: f64) {
        self.edit(&["size"], |s| s.size = v.max(1.0));
    }

    pub fn set_color(&mut self, c: RGBAColor) {
        self.edit(&["color.red", "color.green", "color.blue"], |s| {
            s.color = c;
            s.unbind(StyleTokenField::Color);
        });
    }

    /// Fill opacity (0 = fill off); the fill color stays.
    pub fn set_fill_alpha(&mut self, a: f64) {
        self.edit(&["color.alpha"], |s| {
            s.color = with_alpha(s.color, a);
            s.unbind(StyleTokenField::Color);
        });
    }

    pub fn set_alignment(&mut self, a: TextAlignment) {
        self.edit(&["alignment"], |s| s.alignment = a);
    }

    pub fn set_line_spacing(&mut self, v: f64) {
        self.edit(&["lineSpacing"], |s| s.line_spacing = v);
    }

    pub fn set_tracking(&mut self, v: f64) {
        self.edit(&["tracking"], |s| s.tracking = v);
    }

    pub fn set_italic(&mut self, on: bool) {
        self.edit(&["italic"], |s| s.italic = on);
    }

    pub fn set_vertical_alignment(&mut self, a: TextVerticalAlignment) {
        self.edit(&["verticalAlignment"], |s| s.vertical_alignment = a);
    }

    pub fn set_all_caps(&mut self, on: bool) {
        self.edit(&["allCaps"], |s| s.all_caps = on);
    }

    /// Line styles (`TextDecorations`): a bar under, through or over every line, in the fill color.
    pub fn set_underline(&mut self, on: bool) {
        self.edit(&["underline"], |s| s.underline = on);
    }

    pub fn set_strikethrough(&mut self, on: bool) {
        self.edit(&["strikethrough"], |s| s.strikethrough = on);
    }

    pub fn set_overline(&mut self, on: bool) {
        self.edit(&["overline"], |s| s.overline = on);
    }

    /// Paragraph direction: `None` is automatic (the first strong character decides).
    pub fn set_direction(&mut self, d: Option<TextDirection>) {
        self.edit(&["direction"], |s| s.direction = d);
    }

    /// The variation axes of the style's font (empty for a static font), in the font's axis order.
    pub fn font_axes(&self) -> Vec<Axis> {
        FontResolver::axes_for_font_name(&self.style.font_name)
    }

    /// The value an axis shows: the style's override, else the font's default.
    pub fn axis_value(&self, axis: &Axis) -> f64 {
        let v = self.style.font_axes.as_ref().and_then(|a| a.get(&axis.tag)).copied().unwrap_or(axis.default_value);
        v.max(axis.minimum).min(axis.maximum)
    }

    /// Sets one axis; a value equal to the font's default removes the override (and the dictionary when it is empty), so
    /// an untouched style stays `font_axes == None`.
    pub fn set_font_axis(&mut self, axis: &Axis, value: f64) {
        self.edit(&["fontAxes"], |s| {
            let mut a = s.font_axes.take().unwrap_or_default();
            let v = value.max(axis.minimum).min(axis.maximum);
            if v == axis.default_value {
                a.remove(&axis.tag);
            } else {
                a.insert(axis.tag.clone(), v);
            }
            s.font_axes = if a.is_empty() { None } else { Some(a) };
        });
    }

    pub fn reset_font_axes(&mut self) {
        self.edit(&["fontAxes"], |s| s.font_axes = None);
    }

    /// The six align buttons: the host moves the clip so its text block meets the frame (it owns the clip's transform).
    pub fn align_to_frame(&mut self, a: FrameAlignment) {
        self.events.push(TextInspectorEvent::AlignToFrame(a));
    }

    // MARK: Footage fill

    /// `None` = the Fill color fills the glyphs; `Stencil` shows the picture below through them; `Inverted` inverts it.
    pub fn set_footage_fill(&mut self, f: Option<TextFootageFill>) {
        self.edit(&["footageFill"], |s| s.footage_fill = f);
    }

    // MARK: Stroke

    pub fn stroke_enabled(&self) -> bool {
        self.style.stroke.is_some()
    }

    pub fn set_stroke_enabled(&mut self, on: bool) {
        let last = self.last_stroke;
        self.edit(&["stroke"], |s| s.stroke = on.then_some(last));
    }

    pub fn set_stroke_color(&mut self, c: RGBAColor) {
        self.edit(&["stroke.color.red", "stroke.color.green", "stroke.color.blue"], |s| {
            if let Some(st) = s.stroke.as_mut() {
                st.color = c;
            }
            s.unbind(StyleTokenField::StrokeColor);
        });
    }

    pub fn set_stroke_width(&mut self, w: f64) {
        self.edit(&["stroke.width"], |s| {
            if let Some(st) = s.stroke.as_mut() {
                st.width = w.max(0.0);
            }
        });
    }

    pub fn set_stroke_position(&mut self, p: StrokePosition) {
        self.edit(&["stroke.position"], |s| {
            if let Some(st) = s.stroke.as_mut() {
                st.position = p;
            }
        });
    }

    // MARK: Second line style (small top line over a big bottom line)

    /// Every paragraph after the first is drawn in the second-line look (font, weight, size, color, italic).
    pub fn second_line_enabled(&self) -> bool {
        self.style.second_line.is_some()
    }

    /// On: the last second-line look of this inspector, else the clip look at twice the size and bold.
    pub fn set_second_line_enabled(&mut self, on: bool) {
        let last = self.last_second_line.clone();
        self.edit(&["secondLine"], |s| {
            if !on {
                s.second_line = None;
                return;
            }
            if s.second_line.is_some() {
                return;
            }
            if let Some(last) = last {
                s.second_line = Some(last);
                return;
            }
            let mut l = TextLineStyle::from_style(s);
            l.size = s.size * 2.0;
            l.weight = s.weight.max(FontWeight::Bold);
            s.second_line = Some(l);
        });
    }

    pub fn set_second_line_font(&mut self, name: &str) {
        self.edit(&["secondLine.fontName"], |s| {
            if let Some(l) = s.second_line.as_mut() {
                l.font_name = name.to_string();
            }
        });
        self.refresh_families();
    }

    pub fn set_second_line_weight(&mut self, w: FontWeight) {
        self.edit(&["secondLine.weight"], |s| {
            if let Some(l) = s.second_line.as_mut() {
                l.weight = w;
            }
        });
    }

    pub fn set_second_line_size(&mut self, v: f64) {
        self.edit(&["secondLine.size"], |s| {
            if let Some(l) = s.second_line.as_mut() {
                l.size = v.max(1.0);
            }
        });
    }

    pub fn set_second_line_color(&mut self, c: RGBAColor) {
        self.edit(&["secondLine.color.red", "secondLine.color.green", "secondLine.color.blue"], |s| {
            if let Some(l) = s.second_line.as_mut() {
                l.color = c;
            }
        });
    }

    pub fn set_second_line_italic(&mut self, on: bool) {
        self.edit(&["secondLine.italic"], |s| {
            if let Some(l) = s.second_line.as_mut() {
                l.italic = on;
            }
        });
    }

    // MARK: Layout: shrink to box, lists, gradient fill

    pub fn auto_fit_enabled(&self) -> bool {
        self.style.auto_fit == Some(true)
    }

    /// On: in an area text box the glyphs shrink until the block fits (never grow). Off: the size stays as set.
    pub fn set_auto_fit(&mut self, on: bool) {
        self.edit(&["autoFit"], |s| s.auto_fit = on.then_some(true));
    }

    pub fn list_kind(&self) -> Option<TextListKind> {
        self.style.list
    }

    pub fn set_list(&mut self, kind: Option<TextListKind>) {
        self.edit(&["list"], |s| s.list = kind);
    }

    /// On: the last gradient of this inspector, else the fill color to its inverse, top to bottom.
    pub fn set_gradient_enabled(&mut self, on: bool) {
        let last = self.last_gradient;
        self.edit(&["gradient"], |s| {
            if !on {
                s.gradient = None;
                return;
            }
            if s.gradient.is_some() {
                return;
            }
            if let Some(g) = last {
                s.gradient = Some(g);
                return;
            }
            let c = s.color;
            let inverse = RGBAColor::new(1.0 - c.red, 1.0 - c.green, 1.0 - c.blue, c.alpha);
            s.gradient = Some(TextGradient { start: c, end: inverse, angle: 90.0 });
        });
    }

    pub fn set_gradient_start(&mut self, c: RGBAColor) {
        self.edit(&["gradient.start.red", "gradient.start.green", "gradient.start.blue"], |s| {
            if let Some(g) = s.gradient.as_mut() {
                g.start = c;
            }
        });
    }

    pub fn set_gradient_end(&mut self, c: RGBAColor) {
        self.edit(&["gradient.end.red", "gradient.end.green", "gradient.end.blue"], |s| {
            if let Some(g) = s.gradient.as_mut() {
                g.end = c;
            }
        });
    }

    pub fn set_gradient_angle(&mut self, degrees: f64) {
        self.edit(&["gradient.angle"], |s| {
            if let Some(g) = s.gradient.as_mut() {
                g.angle = degrees;
            }
        });
    }

    // MARK: Background box

    pub fn set_background_enabled(&mut self, on: bool) {
        let last = self.last_background;
        self.edit(&["background"], |s| s.background = on.then_some(last));
    }

    pub fn set_background_color(&mut self, c: RGBAColor) {
        self.edit(&["background.color.red", "background.color.green", "background.color.blue"], |s| {
            if let Some(b) = s.background.as_mut() {
                b.color = c;
            }
            s.unbind(StyleTokenField::BackgroundColor);
        });
    }

    pub fn set_background_padding(&mut self, horizontal: f64, vertical: f64) {
        self.edit(&["background.padding"], |s| {
            if let Some(b) = s.background.as_mut() {
                b.padding = BoxPadding::new(horizontal, vertical);
            }
        });
    }

    pub fn set_background_radius(&mut self, r: f64) {
        self.edit(&["background.cornerRadius"], |s| {
            if let Some(b) = s.background.as_mut() {
                b.corner_radius = r.max(0.0);
            }
        });
    }

    // MARK: Shadow

    pub fn set_shadow_enabled(&mut self, on: bool) {
        let last = self.last_shadow;
        self.edit(&["shadow"], |s| s.shadow = on.then_some(last));
    }

    pub fn set_shadow_color(&mut self, c: RGBAColor) {
        self.edit(&["shadow.color.red", "shadow.color.green", "shadow.color.blue"], |s| {
            if let Some(sh) = s.shadow.as_mut() {
                sh.color = c;
            }
        });
    }

    pub fn set_shadow_offset(&mut self, x: f64, y: f64) {
        self.edit(&["shadow.offsetX", "shadow.offsetY"], |s| {
            if let Some(sh) = s.shadow.as_mut() {
                sh.offset_x = x;
                sh.offset_y = y;
            }
        });
    }

    pub fn set_shadow_blur(&mut self, b: f64) {
        self.edit(&["shadow.blur"], |s| {
            if let Some(sh) = s.shadow.as_mut() {
                sh.blur = b.max(0.0);
            }
        });
    }

    /// Light angle in degrees and distance in pixels (the stored offset follows).
    pub fn set_shadow_angle(&mut self, degrees: f64, distance: f64) {
        self.edit(&["shadow.offsetX", "shadow.offsetY"], |s| {
            let Some(sh) = s.shadow else { return };
            let mut n = TextShadow::from_angle(sh.color, degrees, distance.max(0.0), sh.blur);
            n.spread = sh.spread;
            s.shadow = Some(n);
        });
    }

    /// The shadow "Size": the glyph shape grows by this many px before the blur.
    pub fn set_shadow_spread(&mut self, v: f64) {
        self.edit(&["shadow.spread"], |s| {
            if let Some(sh) = s.shadow.as_mut() {
                sh.set_spread(v.max(0.0));
            }
        });
    }

    pub fn set_shadow_opacity(&mut self, o: f64) {
        self.edit(&["shadow.color.alpha"], |s| {
            if let Some(sh) = s.shadow.as_mut() {
                sh.color = with_alpha(sh.color, o);
            }
        });
    }

    pub fn set_background_opacity(&mut self, o: f64) {
        self.edit(&["background.color.alpha"], |s| {
            let Some(b) = s.background.as_mut() else { return };
            b.color = with_alpha(b.color, o);
            s.unbind(StyleTokenField::BackgroundColor);
        });
    }

    // MARK: Kit tokens

    /// Token names of the kit that fit `field` (font tokens for the font, color tokens otherwise), sorted.
    pub fn token_names(&self, field: TokenField) -> Vec<String> {
        let Some(kit) = &self.kit else { return Vec::new() };
        if field == TokenField::Font {
            kit.fonts.keys().cloned().collect()
        } else {
            kit.colors.keys().cloned().collect()
        }
    }

    /// The token `field` follows, `None` = a literal.
    pub fn bound_token(&self, field: TokenField) -> Option<String> {
        let mut t = self.style.tokens.clone()?;
        token_slot(&mut t, field).clone()
    }

    /// Binds `field` to the kit token `name` (the style takes the token's current value at once and follows later kit
    /// changes) or, with `None`, releases it (the current value stays as a literal). One edit step; unknown tokens are ignored.
    pub fn bind_token(&mut self, field: TokenField, name: Option<&str>) {
        if !field.is_available(&self.style) {
            return;
        }
        if let Some(name) = name {
            if !self.token_names(field).iter().any(|n| n == name) {
                return;
            }
            let kit = self.kit.clone();
            self.edit(&[], |s| {
                let mut t = s.tokens.clone().unwrap_or_default();
                *token_slot(&mut t, field) = Some(name.to_string());
                s.tokens = Some(t);
                *s = s.resolved(kit.as_ref());
            });
        } else {
            self.edit(&[], |s| s.unbind(field.style_field()));
        }
    }

    // MARK: Caption style presets

    pub fn preset_ids(&self) -> Vec<String> {
        self.library.style_ids()
    }

    /// The preset whose style equals the current style, if any ("default" only when nothing else matches).
    pub fn selected_preset_id(&self) -> Option<String> {
        let ids = self.library.style_ids();
        ids.iter()
            .find(|id| **id != self.library.default_style_id && self.library.style(Some(id)) == self.style)
            .or_else(|| ids.iter().find(|id| self.library.style(Some(id)) == self.style))
            .cloned()
    }

    /// Applies a gallery look to the title: its style, and its animation in the slot of its anchor (the other slot stays).
    /// One edit gesture (one undo step); everything stays editable afterwards.
    pub fn apply_look(&mut self, look: &CaptionStyleLook) {
        if !self.library.has_style(&look.style_ref) || !self.library.has_animation(&look.animation_ref) {
            return;
        }
        let s = self.library.style(Some(&look.style_ref));
        let a = look.animation_set(&self.library, &self.animations);
        if s == self.style && a == self.animations {
            return;
        }
        self.begin_editing();
        self.style = s.clone();
        self.animations = a;
        self.remember(&s);
        self.events.push(TextInspectorEvent::Change(
            Box::new(self.style.clone()),
            Box::new(self.animations.clone()),
            BTreeSet::new(),
        ));
        self.end_editing();
        self.version += 1;
    }

    /// The gallery look the title shows now: same style and animation slot (`None` once edited).
    pub fn current_look_id(&self) -> Option<String> {
        CaptionStyleLooks::all()
            .iter()
            .find(|look| {
                if self.library.style(Some(&look.style_ref)) != self.style {
                    return false;
                }
                let t = self.library.animation(Some(&look.animation_ref));
                if t == KeyframeTemplate::none() {
                    return false;
                }
                if t.anchor == AnimationAnchor::Start {
                    self.animations.animation_in.as_ref() == Some(&t)
                } else {
                    self.animations.animation_out.as_ref() == Some(&t)
                }
            })
            .map(|look| look.id.clone())
    }

    pub fn apply_preset(&mut self, id: &str) {
        if !self.library.has_style(id) {
            return;
        }
        let s = self.library.style(Some(id));
        self.edit(&[], |st| *st = s);
    }

    /// Saves the current style under a slug of `name` (made unique). `None` for an empty name.
    pub fn save_current_as_preset(&mut self, name: &str) -> Option<String> {
        let slug = Self::slug(name);
        if slug.is_empty() {
            return None;
        }
        let mut id = slug.clone();
        let mut n = 2;
        while self.library.has_style(&id) {
            id = format!("{slug}-{n}");
            n += 1;
        }
        let mut styles = self.library.styles.clone();
        styles.insert(id.clone(), self.style.clone());
        self.saved_styles.insert(id.clone(), self.style.clone());
        self.library = CaptionPresetLibrary::new(
            styles,
            self.library.animations.clone(),
            &self.library.default_style_id,
            &self.library.default_animation_id,
        );
        self.events.push(TextInspectorEvent::PresetsChanged(Box::new(self.library.clone())));
        self.version += 1;
        Some(id)
    }

    pub(crate) fn slug(name: &str) -> String {
        let mapped: String = name.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
        mapped.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-")
    }

    // MARK: Text styles (look only, no animation)

    /// The style whose look equals the current one exactly, if any.
    pub fn selected_style_id(&self) -> Option<String> {
        self.styles.match_style(&self.style)
    }

    /// The clip was edited away from the style it started from.
    pub fn is_style_modified(&self) -> bool {
        let Some(id) = &self.applied_style_id else { return false };
        let Some(e) = self.styles.entry(id) else { return false };
        e.style != self.style
    }

    /// Applies the look of `id` to the clip: one undo step. Animations stay as they are.
    pub fn apply_style(&mut self, id: &str) {
        let Some(e) = self.styles.entry(id) else { return };
        self.edit(&[], |s| *s = e.style);
        self.applied_style_id = Some(id.to_string());
    }

    /// Saves the current look under `name`; the new style counts as the applied one. `None` for an empty name.
    pub fn save_current_as_style(&mut self, name: &str) -> Option<String> {
        let mut next = self.styles.clone();
        let id = next.add(name, self.style.clone(), self.ids.as_mut())?;
        self.commit_styles(next);
        self.applied_style_id = Some(id.clone());
        Some(id)
    }

    /// Overwrites a user style with the current look ("Update style").
    pub fn update_style_from_current(&mut self, id: &str) {
        let mut next = self.styles.clone();
        if !next.update(id, self.style.clone()) {
            return;
        }
        self.commit_styles(next);
    }

    pub fn rename_style(&mut self, id: &str, name: &str) {
        let mut next = self.styles.clone();
        if !next.rename(id, name) {
            return;
        }
        self.commit_styles(next);
    }

    pub fn delete_style(&mut self, id: &str) {
        let mut next = self.styles.clone();
        if !next.delete(id) {
            return;
        }
        if self.applied_style_id.as_deref() == Some(id) {
            self.applied_style_id = None;
        }
        self.commit_styles(next);
    }

    /// The Look store changed (here or elsewhere): show its Looks.
    pub fn reload_styles(&mut self, library: TextStyleLibrary) {
        if self.styles != library || self.styles.base() != library.base() {
            self.styles = library;
            self.version += 1;
        }
    }

    fn commit_styles(&mut self, next: TextStyleLibrary) {
        self.styles = next.clone();
        self.events.push(TextInspectorEvent::StylesChanged(Box::new(next)));
        self.version += 1;
    }

    // MARK: Animations (anchored: in = start, out = end)

    fn store(&self) -> Option<&dyn AnimationKeystoneSource> {
        self.keystones.as_deref()
    }

    /// Off first, the neutral presets, the rest, then the saved ones (`AnimationChoices`).
    pub fn in_animation_ids(&self) -> Vec<String> {
        AnimationChoices::preset_ids(AnimationSide::Intro, &self.library, self.store())
    }

    pub fn out_animation_ids(&self) -> Vec<String> {
        AnimationChoices::preset_ids(AnimationSide::Outro, &self.library, self.store())
    }

    /// The preset a side plays; `None` = Custom, or a saved animation that is no longer in the Library (`is_custom` tells
    /// them apart). The text animator is not part of it (an animator-only side is "none").
    pub fn selected_in_id(&self) -> Option<String> {
        self.preset_id(AnimationSide::Intro)
    }

    pub fn selected_out_id(&self) -> Option<String> {
        self.preset_id(AnimationSide::Outro)
    }

    /// Saved animations (Library keystones) per side; read so the popups follow the Library.
    pub fn saved_animations(&self) -> Vec<sq_core_effects::keystone::Keystone> {
        let mut v = AnimationChoices::saved(AnimationSide::Intro, self.store());
        v.extend(AnimationChoices::saved(AnimationSide::Outro, self.store()));
        v
    }

    fn preset_id(&self, side: AnimationSide) -> Option<String> {
        AnimationChoices::preset_id(
            self.animations.template(side),
            side,
            &self.library,
            self.frame_size,
            self.store(),
            self.picked.get(&side_key(side)).map(String::as_str),
        )
    }

    /// The side is keyed by hand: Controls shows its Position, Scale, Rotation and Opacity rows.
    pub fn is_custom(&self, side: AnimationSide) -> bool {
        AnimationChoices::is_custom(self.animations.template(side))
    }

    /// What the side's popup shows: a preset's name, "Custom", or "Saved" for a saved animation the Library lost.
    pub fn animation_title(&self, side: AnimationSide) -> String {
        if self.is_custom(side) {
            return AnimationChoices::title(AnimationChoices::CUSTOM_ID, side, self.store());
        }
        self.preset_id(side).map_or_else(
            || AnimationChoices::UNKNOWN_TITLE.to_string(),
            |id| AnimationChoices::title(&id, side, self.store()),
        )
    }

    /// The shown name of a popup entry (`AnimationChoices.title` with the model's keystone store).
    pub fn animation_choice_title(&self, id: &str, side: AnimationSide) -> String {
        AnimationChoices::title(id, side, self.store())
    }

    /// Takes the item's animations when only they changed (a Custom side keyed in Controls, undo): unlike `load` an
    /// open edit session of the block stays open.
    pub fn adopt(&mut self, next: AnimationSet) {
        if next != self.animations {
            self.animations = next;
            self.version += 1;
        }
    }

    // MARK: Zone lengths (Intro / Outro): the first N and the last M seconds of the clip

    /// Length of a side's zone in milliseconds; `None` for a side that is Off, only an animator or a loop (no zone).
    pub fn zone_milliseconds(&self, side: AnimationSide) -> Option<i64> {
        let t = self.animations.template(side)?;
        if t.tracks.is_empty() || t.loops || t.duration <= Time::ZERO {
            return None;
        }
        Some(Self::animator_milliseconds(t.duration))
    }

    /// Longest this side may be: the clip minus the other zone (never below the minimum).
    pub fn maximum_zone_milliseconds(&self, side: AnimationSide) -> i64 {
        let cap = Self::MAX_ANIMATOR_MILLISECONDS;
        let Some(clip) = self.clip_duration.filter(|c| *c > Time::ZERO) else { return cap };
        let other_side = if side == AnimationSide::Intro { AnimationSide::Outro } else { AnimationSide::Intro };
        let other = self.zone_milliseconds(other_side).unwrap_or(0);
        let room = Self::animator_milliseconds(clip) - other;
        Self::MINIMUM_ZONE_MILLISECONDS.max(cap.min(room))
    }

    /// Sets a side's zone length: its keys are scaled to it (an authoring change; playback never scales). The clip's
    /// other zone and the clip length bound it.
    pub fn set_zone_length(&mut self, ms: i64, side: AnimationSide) {
        if self.zone_milliseconds(side).is_none() {
            return;
        }
        let clamped = ms.max(Self::MINIMUM_ZONE_MILLISECONDS).min(self.maximum_zone_milliseconds(side));
        let d = Self::animator_time(clamped);
        self.edit_animations(|set| {
            if side == AnimationSide::Intro
                && let Some(t) = &set.animation_in
            {
                set.animation_in = Some(t.retimed(d));
            }
            if side == AnimationSide::Outro
                && let Some(t) = &set.animation_out
            {
                set.animation_out = Some(t.retimed(d));
            }
        });
    }

    pub fn set_in_animation(&mut self, id: &str) {
        self.set_animation(id, AnimationSide::Intro);
    }

    pub fn set_out_animation(&mut self, id: &str) {
        self.set_animation(id, AnimationSide::Outro);
    }

    /// A preset, a saved animation, or `AnimationChoices::CUSTOM_ID` (see `make_custom`).
    pub fn set_animation(&mut self, id: &str, side: AnimationSide) {
        if id == AnimationChoices::CUSTOM_ID {
            self.make_custom(side);
            return;
        }
        // Picking what the side already shows changes nothing (its template is the same animation).
        if id.starts_with(AnimationChoices::SAVED_PREFIX) && self.preset_id(side).as_deref() == Some(id) {
            self.picked.insert(side_key(side), id.to_string());
            return;
        }
        let Some(t) = AnimationChoices::template(id, side, &self.library, self.frame_size, self.store()) else {
            return;
        };
        self.picked.insert(side_key(side), id.to_string());
        self.set_template(t, side);
    }

    /// Turns the side into a Custom animation: what it plays now with keys of its own, or a plain fade when it was Off.
    pub fn make_custom(&mut self, side: AnimationSide) {
        if self.is_custom(side) {
            return;
        }
        let now = self.animations.template(side).filter(|t| !t.tracks.is_empty()).cloned();
        let t = match now {
            Some(n) => n.with_fresh_key_ids(self.ids.as_mut()),
            None => KeyframeTemplate::custom_start(side, self.ids.as_mut()),
        };
        self.set_template(t, side);
    }

    /// True when a Custom side can be saved here: the host attached a Library that takes keystones.
    pub fn can_save_animations(&self) -> bool {
        self.store().is_some_and(|s| s.can_save())
    }

    /// Saves a Custom side as a keystone under `name` (Swift `saveCustomAnimation`): the side then shows the saved
    /// animation (its loop flag kept). False when nothing is keyed, no Library is attached or it could not store it;
    /// the side stays Custom then, there is no optimistic state.
    pub fn save_custom_animation(&mut self, side: AnimationSide, name: &str) -> bool {
        if !self.is_custom(side) {
            return false;
        }
        let Some(t) = self.animations.template(side).cloned() else { return false };
        let Some(store) = self.keystones.clone() else { return false };
        let Some(k) = Keystone::from_animation(&t, side, name, self.frame_size, self.ids.as_mut()) else {
            return false;
        };
        let Some(mut saved) = k.animation_template(self.frame_size) else { return false };
        // The keystone keeps the loop flag, so the saved animation loops again where it is picked later.
        saved.loops = t.loops;
        let id = k.id;
        if !store.save(k) {
            return false;
        }
        self.picked.insert(side_key(side), format!("{}{}", AnimationChoices::SAVED_PREFIX, id));
        self.set_template(saved, side);
        true
    }

    fn set_template(&mut self, t: KeyframeTemplate, side: AnimationSide) {
        self.edit_animations(|set| {
            let animator = set.template(side).and_then(|x| x.text_animator.clone());
            let anchor = if side == AnimationSide::Intro { AnimationAnchor::Start } else { AnimationAnchor::End };
            let next = KeyframeTemplate::combined_with_animator(Some(&t), animator, anchor);
            if side == AnimationSide::Intro {
                set.animation_in = next;
            } else {
                set.animation_out = next;
            }
        });
    }

    // MARK: Text animators (per character / word / line)

    pub fn animator(&self, side: AnimatorSide) -> Option<&TextAnimator> {
        match side {
            AnimatorSide::In => self.animations.animation_in.as_ref()?.text_animator.as_ref(),
            AnimatorSide::Out => self.animations.animation_out.as_ref()?.text_animator.as_ref(),
        }
    }

    fn edit_animator(&mut self, side: AnimatorSide, body: impl FnOnce(&mut Option<TextAnimator>)) {
        self.edit_animations(|set| {
            let mut a = match side {
                AnimatorSide::In => set.animation_in.as_ref().and_then(|t| t.text_animator.clone()),
                AnimatorSide::Out => set.animation_out.as_ref().and_then(|t| t.text_animator.clone()),
            };
            body(&mut a);
            if side == AnimatorSide::In {
                set.animation_in = KeyframeTemplate::combined_with_animator(set.animation_in.as_ref(), a, AnimationAnchor::Start);
            } else {
                set.animation_out = KeyframeTemplate::combined_with_animator(set.animation_out.as_ref(), a, AnimationAnchor::End);
            }
        });
    }

    /// Default stagger by unit: letters follow each other fast, lines slowly.
    pub(crate) fn default_stagger(unit: TextAnimatorUnit) -> Time {
        TextAnimator::default_stagger(unit)
    }

    /// `None` removes the animator. A new animator starts by word, 300 ms per unit, 80 ms stagger; pop gets the overshoot.
    pub fn set_animator_effect(&mut self, effect: Option<TextAnimatorEffect>, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            let Some(effect) = effect else {
                *a = None;
                return;
            };
            let mut cur = a.take().unwrap_or_else(|| TextAnimator::starting(effect));
            cur.set_effect(effect);
            *a = Some(cur);
        });
    }

    pub fn set_animator_unit(&mut self, unit: TextAnimatorUnit, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            let Some(cur) = a.as_mut() else { return };
            if cur.unit == unit {
                return;
            }
            cur.set_unit(unit);
        });
    }

    pub fn set_animator_order(&mut self, order: TextAnimatorOrder, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.order = order;
            }
        });
    }

    pub fn set_animator_easing(&mut self, easing: SegmentShape, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.easing = easing;
            }
        });
    }

    pub fn set_animator_direction(&mut self, d: TextSlideDirection, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.direction = d;
            }
        });
    }

    /// A typed field value as whole milliseconds in 0...60 000 (non-finite input reads as 0, never traps).
    pub fn milliseconds(value: f64) -> i64 {
        if !value.is_finite() {
            return 0;
        }
        (Self::MAX_ANIMATOR_MILLISECONDS as f64).min(value.max(0.0)).round() as i64
    }

    fn animator_time(ms: i64) -> Time {
        Time::new(Self::MAX_ANIMATOR_MILLISECONDS.min(ms.max(0)), 1000)
    }

    pub fn set_animator_duration(&mut self, ms: i64, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.duration = Self::animator_time(ms);
            }
        });
    }

    /// Slide distance in sequence pixels (0...2000; non-finite reads as the default 40).
    pub fn set_animator_distance(&mut self, px: f64, side: AnimatorSide) {
        let v =
            if px.is_finite() { Self::MAX_ANIMATOR_PIXELS.min(px.max(0.0)) } else { Self::DEFAULT_ANIMATOR_DISTANCE };
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.distance = v;
            }
        });
    }

    /// Start blur of the Blur effect in sequence pixels (0...2000).
    pub fn set_animator_blur_radius(&mut self, px: f64, side: AnimatorSide) {
        let v = if px.is_finite() { Self::MAX_ANIMATOR_PIXELS.min(px.max(0.0)) } else { Self::DEFAULT_ANIMATOR_BLUR };
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.blur_radius = v;
            }
        });
    }

    /// Cycles of a loop effect (wave, pulse), 1...50.
    pub fn set_animator_loops(&mut self, n: i64, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.loops = n.clamp(1, 50);
            }
        });
    }

    pub fn set_animator_stagger(&mut self, ms: i64, side: AnimatorSide) {
        self.edit_animator(side, |a| {
            if let Some(a) = a.as_mut() {
                a.stagger = Self::animator_time(ms);
            }
        });
    }

    /// Nearest whole millisecond of `t` (display only; integer arithmetic).
    pub fn animator_milliseconds(t: Time) -> i64 {
        let n = i128::from(t.value()) * 1000;
        let d = i128::from(t.timescale());
        ((n * 2 + d) / (d * 2)) as i64
    }
}
