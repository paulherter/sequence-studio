//! The Style tab of the Captions panel: the edit fields, their pure rules and the session glue.

use std::collections::BTreeSet;

use sq_core_time::Id;

use sq_core_effects::style_kit::{CAPTION_ANIMATION_REF, CAPTION_STYLE_REF, StyleValueExt};
use sq_core_model::{
    CaptionItem, CaptionPosition, CaptionShadow, CaptionStyleSpec, CaptionStyleTweaks, EffectColor, Project, StyleKit,
    StylePill, StyleValue,
};
use sq_text::caption_pill::CaptionPill;
use sq_text::caption_presets::{CaptionLook, CaptionLookRegistry, CaptionPresetLibrary};
use sq_text::style_kit_text::{StyleKitTextExt, TokenField};
use sq_text::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextShadow, TextStroke, TextStyle,
};

use super::common::default_caption_position;
use crate::EditorSession;
use sq_core_audio::TimelineCaptionEditsExt as TimelineCaptionEdits;

/// Upper end of a caption text size (the model clamps to 1...1000).
const MAX_CAPTION_SIZE: f64 = 1000.0;
/// Upper end of the pill corner radius (the model clamps to 0...10000).
const MAX_PILL_CORNER_RADIUS: f64 = 10_000.0;

/// One edit made in the Style tab of the Captions panel.
#[derive(Clone, Debug, PartialEq)]
pub enum CaptionStyleField {
    /// Built-in caption style the captions start from ("default", "outline", "pill", ...).
    Look(String),
    /// Built-in caption animation id.
    Animation(String),
    Font(String),
    Size(f64),
    TextColor(RGBAColor),
    /// Outline color; `None` turns the outline off.
    Outline(Option<RGBAColor>),
    /// Pill (box behind the words) color; `None` turns the pill off.
    Pill(Option<RGBAColor>),
    /// Pill size in em. Turns the pill on.
    PillSize(f64),
    /// Pill corner radius in points; `None` = fully round ends. Turns the pill on.
    PillCorners(Option<f64>),
    AllCaps(bool),
    Weight(FontWeight),
    Italic(bool),
    Alignment(TextAlignment),
    Tracking(f64),
    LineSpacing(f64),
    /// Outline width in points; the outline must be on.
    StrokeWidth(f64),
    StrokePosition(StrokePosition),
    /// Pill padding in em (horizontal, vertical). Turns the pill on.
    PillPadding {
        horizontal_em: f64,
        vertical_em: f64,
    },
    /// Shadow; `None` turns it off.
    Shadow(Option<TextShadow>),
}

/// What the Style tab edits: every caption (the project's kit caption style) or the selected captions (a look of their own).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CaptionStyleScope {
    All,
    Selected,
}

impl CaptionStyleScope {
    /// The Swift raw value, used in undo keys.
    pub fn raw_value(self) -> &'static str {
        match self {
            CaptionStyleScope::All => "all",
            CaptionStyleScope::Selected => "selected",
        }
    }
}

/// What the Style tab shows for a scope.
// Swift: EditorSession+CaptionStyleTab.swift:41
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionStyleState {
    /// The style as drawn (tokens resolved).
    // Swift: EditorSession+CaptionStyleTab.swift:44
    pub style: TextStyle,
    /// The built-in look it starts from; `None` for a saved or own look.
    // Swift: EditorSession+CaptionStyleTab.swift:46
    pub base_id: Option<String>,
    /// The caption animation id; `None` when it is not a built-in animation.
    // Swift: EditorSession+CaptionStyleTab.swift:48
    pub animation_id: Option<String>,
    /// Pill size in em (what the Size slider shows).
    // Swift: EditorSession+CaptionStyleTab.swift:50
    pub pill_size: f64,
    /// Pill corner radius in points; `None` = fully round.
    // Swift: EditorSession+CaptionStyleTab.swift:52
    pub pill_corners: Option<f64>,
}

/// The pure rules behind the Style tab.
pub enum CaptionStyleEdit {}

/// Kit looks the Style tab made for selected captions carry this id prefix.
const OWN_LOOK_PREFIX: &str = "own-";
/// Upper end of the Size slider (em).
const MAX_PILL_SIZE: f64 = 1.2;
/// A corner radius at least this large draws fully round ends (the renderer clamps to half the pill height).
const ROUND_CORNERS: f64 = 10_000.0;

/// Vertical / horizontal padding of the pill: one Size control keeps the built-in proportion.
fn pill_aspect() -> f64 {
    CaptionPill::VERTICAL_EM / CaptionPill::HORIZONTAL_EM
}

fn raw_string<T: serde::Serialize>(v: &T) -> Option<String> {
    serde_json::to_value(v).ok()?.as_str().map(str::to_string)
}

fn kit_spec(
    base_style: &str,
    animation: Option<String>,
    font: Option<StyleValue<String>>,
    uses_pill: bool,
) -> CaptionStyleSpec {
    CaptionStyleSpec {
        base_style: base_style.to_string(),
        animation,
        font,
        size: None,
        text_color: None,
        stroke_color: None,
        uses_pill,
        all_caps: None,
        hides_background: None,
        tweaks: None,
    }
}

fn literal_pill(color: EffectColor) -> StylePill {
    StylePill {
        color: StyleValue::Literal(color),
        horizontal_em: CaptionPill::HORIZONTAL_EM,
        vertical_em: CaptionPill::VERTICAL_EM,
        corner_radius: None,
    }
}

impl CaptionStyleEdit {
    /// Style ids of the built-in looks (no saved looks, no kit styles).
    // Swift: EditorSession+CaptionStyleTab.swift:58
    pub fn built_in_style_ids() -> Vec<String> {
        CaptionPresetLibrary::built_in()
            .style_ids()
            .into_iter()
            .filter(|i| !i.starts_with("look-") && i != CAPTION_STYLE_REF)
            .collect()
    }

    // Swift: EditorSession+CaptionStyleTab.swift:61
    pub fn built_in_animation_ids() -> Vec<String> {
        CaptionPresetLibrary::built_in()
            .animation_ids()
            .into_iter()
            .filter(|i| !i.starts_with("look-") && i != CAPTION_ANIMATION_REF)
            .collect()
    }

    // Swift: EditorSession+CaptionStyleTab.swift:65
    pub fn effect(c: &RGBAColor) -> EffectColor {
        EffectColor { red: c.red, green: c.green, blue: c.blue, alpha: c.alpha }
    }

    /// The pill (size, corners) as the Style tab shows it for a drawn style.
    fn pill_metrics(style: &TextStyle) -> (f64, Option<f64>) {
        match style.background {
            Some(bg) if style.size > 0.0 => (
                bg.padding.horizontal / style.size,
                if bg.corner_radius >= ROUND_CORNERS { None } else { Some(bg.corner_radius) },
            ),
            _ => (CaptionPill::HORIZONTAL_EM, None),
        }
    }

    /// Turns the kit pill on without changing the look: the pill takes the look's own box color when it has one.
    fn ensure_pill(spec: &mut CaptionStyleSpec, k: &mut StyleKit, base: &TextStyle) {
        spec.uses_pill = true;
        spec.hides_background = None;
        if k.pill.is_none() {
            let color = base.background.map_or(CaptionPill::COLOR, |b| b.color);
            k.pill = Some(literal_pill(Self::effect(&color)));
        }
    }

    /// The style as the Style tab's inspector shows it: invisible layers (clear outline, clear box or shadow) count as
    /// off, kit token bindings and the second paragraph are not part of a caption look.
    // Swift: EditorSession+CaptionStyleTab.swift:93
    pub fn display_style(style: &TextStyle) -> TextStyle {
        let mut s = style.clone();
        if s.stroke.is_some_and(|st| st.color.alpha <= 0.0 || st.width <= 0.0) {
            s.stroke = None;
        }
        if s.background.is_some_and(|bg| bg.color.alpha <= 0.0) {
            s.background = None;
        }
        if s.shadow.is_some_and(|sh| sh.color.alpha <= 0.0) {
            s.shadow = None;
        }
        s.second_line = None;
        s.tokens = None;
        s
    }

    /// The caption fields that turn `old` into `new` (both as `display_style` shows them): what an edit in the shared
    /// Text inspector means for a caption look. Layers that come on carry all their values, so the result does not
    /// depend on what the look had hidden. The order is the order to apply them (a layer on before its details).
    // Swift: EditorSession+CaptionStyleTab.swift:105
    pub fn fields(old: &TextStyle, new: &TextStyle) -> Vec<CaptionStyleField> {
        use CaptionStyleField as F;
        let mut f = Vec::new();
        if new.font_name != old.font_name {
            f.push(F::Font(new.font_name.clone()));
        }
        if new.size != old.size {
            f.push(F::Size(new.size));
        }
        if new.color != old.color {
            f.push(F::TextColor(new.color));
        }
        if new.weight != old.weight {
            f.push(F::Weight(new.weight));
        }
        if new.italic != old.italic {
            f.push(F::Italic(new.italic));
        }
        if new.all_caps != old.all_caps {
            f.push(F::AllCaps(new.all_caps));
        }
        if new.alignment != old.alignment {
            f.push(F::Alignment(new.alignment));
        }
        if new.tracking != old.tracking {
            f.push(F::Tracking(new.tracking));
        }
        if new.line_spacing != old.line_spacing {
            f.push(F::LineSpacing(new.line_spacing));
        }
        match (old.stroke, new.stroke) {
            (o, None) => {
                if o.is_some() {
                    f.push(F::Outline(None));
                }
            }
            (Some(o), Some(n)) => {
                if n.color != o.color {
                    f.push(F::Outline(Some(n.color)));
                }
                if n.width != o.width {
                    f.push(F::StrokeWidth(n.width));
                }
                if n.position != o.position {
                    f.push(F::StrokePosition(n.position));
                }
            }
            (None, Some(n)) => {
                f.extend([F::Outline(Some(n.color)), F::StrokeWidth(n.width), F::StrokePosition(n.position)]);
            }
        }
        let padding = |n: &TextBackground| F::PillPadding {
            horizontal_em: n.padding.horizontal / new.size,
            vertical_em: n.padding.vertical / new.size,
        };
        let corners = |n: &TextBackground| {
            F::PillCorners(if n.corner_radius >= ROUND_CORNERS { None } else { Some(n.corner_radius) })
        };
        match (old.background, new.background) {
            (o, None) => {
                if o.is_some() {
                    f.push(F::Pill(None));
                }
            }
            (Some(o), Some(n)) => {
                if n.color != o.color {
                    f.push(F::Pill(Some(n.color)));
                }
                if n.padding != o.padding {
                    f.push(padding(&n));
                }
                if n.corner_radius != o.corner_radius {
                    f.push(corners(&n));
                }
            }
            (None, Some(n)) => f.extend([F::Pill(Some(n.color)), padding(&n), corners(&n)]),
        }
        if new.shadow != old.shadow {
            f.push(F::Shadow(new.shadow));
        }
        f
    }

    // Swift: EditorSession+CaptionStyleTab.swift:138
    pub fn apply_fields_to_kit(fields: &[CaptionStyleField], kit: &StyleKit) -> StyleKit {
        let start = kit_spec("default", None, None, false);
        fields.iter().fold(kit.clone(), |k, f| Self::apply_to_kit(f, &k, &start))
    }

    // Swift: EditorSession+CaptionStyleTab.swift:142
    pub fn apply_fields_to_style(
        fields: &[CaptionStyleField],
        style: &TextStyle,
        library: &CaptionPresetLibrary,
    ) -> TextStyle {
        fields.iter().fold(style.clone(), |s, f| Self::apply_to_style(f, &s, library))
    }

    fn tweak(spec: &mut CaptionStyleSpec, body: impl FnOnce(&mut CaptionStyleTweaks)) {
        let mut t = spec.tweaks.take().unwrap_or_default();
        body(&mut t);
        spec.tweaks = if t == CaptionStyleTweaks::default() { None } else { Some(t) };
    }

    /// All captions: edits the kit caption style (`kit.caption`, or `start` when the kit has none). A field bound to a
    /// token edits that token in place, so the brand (and every text bound to it) follows; an unbound field gets a literal.
    // Swift: EditorSession+CaptionStyleTab.swift:155
    pub fn apply_to_kit(f: &CaptionStyleField, kit: &StyleKit, start: &CaptionStyleSpec) -> StyleKit {
        use CaptionStyleField as F;
        let mut k = kit.clone();
        let mut spec = k.caption.clone().unwrap_or_else(|| start.clone());
        let base = CaptionPresetLibrary::built_in().style(Some(spec.base_style.as_str()));
        let finite = |v: f64, other: f64| if v.is_finite() { v } else { other };
        match f {
            F::Look(id) => {
                // A new look starts clean from that look; the font binding (the brand) and the animation stay.
                // The pill look draws the kit pill, so its Size and Corners edit what is on screen.
                let uses_pill = id == CaptionPill::STYLE_ID;
                spec = kit_spec(id, spec.animation.clone(), spec.font.clone(), uses_pill);
                if uses_pill && k.pill.is_none() {
                    k.pill = Some(literal_pill(Self::effect(&CaptionPill::COLOR)));
                }
            }
            F::Animation(id) => spec.animation = Some(id.clone()),
            F::Font(name) => match spec.font.as_ref().and_then(|v| v.token_name()).map(str::to_string) {
                Some(n) => {
                    k.fonts.insert(n, name.clone());
                }
                None => spec.font = Some(StyleValue::Literal(name.clone())),
            },
            F::Size(v) => spec.size = if v.is_finite() { Some(v.clamp(1.0, MAX_CAPTION_SIZE)) } else { None },
            F::TextColor(c) => match spec.text_color.as_ref().and_then(|v| v.token_name()).map(str::to_string) {
                Some(n) => {
                    k.colors.insert(n, Self::effect(c));
                }
                None => spec.text_color = Some(StyleValue::Literal(Self::effect(c))),
            },
            F::Outline(Some(c)) => match spec.stroke_color.as_ref().and_then(|v| v.token_name()).map(str::to_string) {
                Some(n) => {
                    k.colors.insert(n, Self::effect(c));
                }
                None => spec.stroke_color = Some(StyleValue::Literal(Self::effect(c))),
            },
            F::Outline(None) => {
                // The spec cannot remove the base look's outline: a clear one draws nothing.
                spec.stroke_color = if base.stroke.is_none() {
                    None
                } else {
                    Some(StyleValue::Literal(EffectColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0 }))
                };
            }
            F::Pill(Some(c)) => {
                spec.uses_pill = true;
                spec.hides_background = None;
                match k.pill.as_ref().map(|p| p.color.token_name().map(str::to_string)) {
                    Some(Some(n)) => {
                        k.colors.insert(n, Self::effect(c));
                    }
                    Some(None) => {
                        if let Some(p) = k.pill.as_mut() {
                            p.color = StyleValue::Literal(Self::effect(c));
                        }
                    }
                    None => k.pill = Some(literal_pill(Self::effect(c))),
                }
            }
            F::Pill(None) => {
                spec.uses_pill = false;
                // A look with a box of its own (pill, bold box, YouTube) keeps its type and drops only the box.
                spec.hides_background = if base.background.is_some() { Some(true) } else { None };
            }
            F::PillSize(v) => {
                Self::ensure_pill(&mut spec, &mut k, &base);
                let em = if v.is_finite() { v.clamp(0.0, MAX_PILL_SIZE) } else { CaptionPill::HORIZONTAL_EM };
                if let Some(p) = k.pill.as_mut() {
                    p.horizontal_em = em;
                    p.vertical_em = em * pill_aspect();
                }
            }
            F::PillCorners(r) => {
                Self::ensure_pill(&mut spec, &mut k, &base);
                if let Some(p) = k.pill.as_mut() {
                    p.corner_radius = r.map(|r| if r.is_finite() { r.clamp(0.0, MAX_PILL_CORNER_RADIUS) } else { 0.0 });
                }
            }
            F::AllCaps(b) => spec.all_caps = Some(*b),
            F::Weight(w) => Self::tweak(&mut spec, |t| t.weight = Some(w.raw_value())),
            F::Italic(b) => Self::tweak(&mut spec, |t| t.italic = Some(*b)),
            F::Alignment(a) => Self::tweak(&mut spec, |t| t.alignment = raw_string(a)),
            F::Tracking(v) => Self::tweak(&mut spec, |t| t.tracking = Some(finite(*v, 0.0))),
            F::LineSpacing(v) => Self::tweak(&mut spec, |t| t.line_spacing = Some(finite(*v, 0.0))),
            F::StrokeWidth(v) => Self::tweak(&mut spec, |t| t.stroke_width = Some(finite(v.max(0.0), 0.0))),
            F::StrokePosition(p) => Self::tweak(&mut spec, |t| t.stroke_position = raw_string(p)),
            F::PillPadding { horizontal_em, vertical_em } => {
                Self::ensure_pill(&mut spec, &mut k, &base);
                if let Some(p) = k.pill.as_mut() {
                    p.horizontal_em = if horizontal_em.is_finite() {
                        horizontal_em.clamp(0.0, MAX_PILL_SIZE)
                    } else {
                        CaptionPill::HORIZONTAL_EM
                    };
                    p.vertical_em = if vertical_em.is_finite() {
                        vertical_em.clamp(0.0, MAX_PILL_SIZE)
                    } else {
                        CaptionPill::VERTICAL_EM
                    };
                }
            }
            F::Shadow(Some(sh)) => Self::tweak(&mut spec, |t| {
                t.shadow = Some(CaptionShadow {
                    color: Self::effect(&sh.color),
                    offset_x: sh.offset_x,
                    offset_y: sh.offset_y,
                    blur: sh.blur,
                    resting_angle: sh.resting_angle,
                });
                t.hides_shadow = None;
            }),
            F::Shadow(None) => Self::tweak(&mut spec, |t| {
                t.shadow = None;
                t.hides_shadow = if base.shadow.is_some() { Some(true) } else { None };
            }),
        }
        k.caption = Some(spec);
        k
    }

    /// Selected captions: edits the style they are drawn with. A manual choice ends that field's token binding.
    // Swift: EditorSession+CaptionStyleTab.swift:228
    pub fn apply_to_style(f: &CaptionStyleField, style: &TextStyle, library: &CaptionPresetLibrary) -> TextStyle {
        use CaptionStyleField as F;
        let mut s = style.clone();
        let finite = |v: f64| if v.is_finite() { v } else { 0.0 };
        match f {
            F::Look(id) => s = library.style(Some(id.as_str())),
            F::Animation(_) => {}
            F::Font(name) => {
                s.font_name = name.clone();
                s.unbind(TokenField::Font);
            }
            F::Size(v) => {
                if v.is_finite() {
                    s.size = v.clamp(1.0, MAX_CAPTION_SIZE);
                }
            }
            F::TextColor(c) => {
                s.color = *c;
                s.unbind(TokenField::Color);
            }
            F::Outline(Some(c)) => {
                let width =
                    s.stroke.map(|st| st.width).filter(|w| *w > 0.0).unwrap_or_else(|| (s.size * 0.1).round().max(2.0));
                s.stroke = Some(TextStroke::new(*c, width, s.stroke.map_or(StrokePosition::Outside, |st| st.position)));
                s.unbind(TokenField::StrokeColor);
            }
            F::Outline(None) => {
                s.stroke = None;
                s.unbind(TokenField::StrokeColor);
            }
            F::Pill(Some(c)) => {
                let padding = s.background.map_or(
                    BoxPadding::new(
                        (s.size * CaptionPill::HORIZONTAL_EM).round(),
                        (s.size * CaptionPill::VERTICAL_EM).round(),
                    ),
                    |b| b.padding,
                );
                let corners = s.background.map_or(ROUND_CORNERS, |b| b.corner_radius);
                s.background = Some(TextBackground::new(*c, padding, corners));
                s.unbind(TokenField::BackgroundColor);
            }
            F::Pill(None) => {
                s.background = None;
                s.unbind(TokenField::BackgroundColor);
            }
            F::PillSize(v) => {
                let mut bg = s.background.unwrap_or_else(|| CaptionPill::background(&s, None));
                let em = if v.is_finite() { v.clamp(0.0, MAX_PILL_SIZE) } else { CaptionPill::HORIZONTAL_EM };
                bg.padding = BoxPadding::new((s.size * em).round(), (s.size * em * pill_aspect()).round());
                s.background = Some(bg);
            }
            F::PillCorners(r) => {
                let mut bg = s.background.unwrap_or_else(|| CaptionPill::background(&s, None));
                bg.corner_radius = r.map_or(ROUND_CORNERS, |r| if r.is_finite() { r.max(0.0) } else { 0.0 });
                s.background = Some(bg);
            }
            F::AllCaps(b) => s.all_caps = *b,
            F::Weight(w) => s.weight = *w,
            F::Italic(b) => s.italic = *b,
            F::Alignment(a) => s.alignment = *a,
            F::Tracking(v) => s.tracking = finite(*v),
            F::LineSpacing(v) => s.line_spacing = finite(*v),
            F::StrokeWidth(v) => {
                if let Some(st) = s.stroke.as_mut() {
                    st.width = if v.is_finite() { v.max(0.0) } else { 0.0 };
                }
            }
            F::StrokePosition(p) => {
                if let Some(st) = s.stroke.as_mut() {
                    st.position = *p;
                }
            }
            F::PillPadding { horizontal_em, vertical_em } => {
                let mut bg = s.background.unwrap_or_else(|| CaptionPill::background(&s, None));
                let size = s.size;
                let pad = |em: f64, fallback: f64| {
                    ((if em.is_finite() { em.clamp(0.0, MAX_PILL_SIZE) } else { fallback }) * size).round()
                };
                bg.padding = BoxPadding::new(
                    pad(*horizontal_em, CaptionPill::HORIZONTAL_EM),
                    pad(*vertical_em, CaptionPill::VERTICAL_EM),
                );
                s.background = Some(bg);
            }
            F::Shadow(sh) => s.shadow = *sh,
        }
        s
    }

    /// True when the track is drawn in a style the kit caption spec cannot hold (an applied Look, a saved or own look):
    /// an "all captions" edit then changes that style in place and keeps every other field.
    fn shows_own_look(track: &sq_core_model::CaptionTrack) -> bool {
        let r = track.style_ref.as_str();
        !r.is_empty() && r != CAPTION_STYLE_REF && !Self::built_in_style_ids().iter().any(|b| b == r)
    }

    /// Every style and animation ref a caption track or caption of the project carries.
    pub(crate) fn caption_refs(p: &Project) -> BTreeSet<String> {
        let mut refs = BTreeSet::new();
        for track in p.timelines.iter().flat_map(|t| t.caption_tracks.iter()) {
            refs.insert(track.style_ref.clone());
            refs.insert(track.animation_ref.clone());
            for item in track.items() {
                refs.insert(item.style_ref.clone());
                refs.insert(item.animation_ref.clone());
            }
        }
        refs
    }

    /// A kit look is in use while either of its two refs is in `refs` (a caption can take only the animation of a look).
    pub(crate) fn is_kit_look_used(id: &str, refs: &BTreeSet<String>) -> bool {
        let token = <StyleKit as StyleKitTextExt>::look_id(id);
        refs.contains(&CaptionLook::style_id(&token)) || refs.contains(&CaptionLook::animation_id(&token))
    }

    /// Drops the kit looks with this id prefix that no caption carries any more (neither style nor animation).
    pub(crate) fn prune_kit_looks(p: &mut Project, prefix: &str) {
        let refs = Self::caption_refs(p);
        let Some(kit) = p.style_kit.as_mut() else { return };
        kit.looks.retain(|id, _| !id.starts_with(prefix) || Self::is_kit_look_used(id, &refs));
    }

    /// Drops the "own-" kit looks no caption uses any more.
    pub(crate) fn prune_own_looks(p: &mut Project) {
        Self::prune_kit_looks(p, OWN_LOOK_PREFIX);
    }
}

impl EditorSession {
    /// What the Style tab shows: the first caption track (all) or the first selected caption (selected).
    // Swift: EditorSession+CaptionStyleTab.swift:324
    pub fn caption_style_state(&self, scope: CaptionStyleScope) -> Option<CaptionStyleState> {
        self.active_timeline()?;
        let track = self.current_caption_track()?;
        let lib = CaptionLookRegistry::shared().library_for_project(self.project());
        let built_in = CaptionStyleEdit::built_in_style_ids();
        let anims = CaptionStyleEdit::built_in_animation_ids();
        let (style_ref, animation_ref) = match scope {
            CaptionStyleScope::All => (
                if track.style_ref.is_empty() {
                    track.items().first().map(|i| i.style_ref.clone()).unwrap_or_default()
                } else {
                    track.style_ref.clone()
                },
                if track.animation_ref.is_empty() {
                    track.items().first().map(|i| i.animation_ref.clone()).unwrap_or_default()
                } else {
                    track.animation_ref.clone()
                },
            ),
            CaptionStyleScope::Selected => {
                let c = self.caption_items().into_iter().find(|c| self.caption_selection.contains(&c.id))?;
                (c.style_ref, c.animation_ref)
            }
        };
        let kit = self.project().style_kit.as_ref();
        let spec = kit.and_then(|k| k.caption.as_ref());
        let base = if style_ref == CAPTION_STYLE_REF {
            spec.map(|s| s.base_style.clone())
        } else {
            built_in.contains(&style_ref).then(|| style_ref.clone())
        };
        let anim = if animation_ref == CAPTION_ANIMATION_REF {
            Some(spec.and_then(|s| s.animation.clone()).unwrap_or_else(|| CaptionLook::POP_ANIMATION_ID.to_string()))
        } else {
            anims.contains(&animation_ref).then(|| animation_ref.clone())
        };
        let style = lib.style(Some(style_ref.as_str()).filter(|r| !r.is_empty()));
        let (pill_size, pill_corners) = match (style_ref == CAPTION_STYLE_REF, spec, kit.and_then(|k| k.pill.as_ref()))
        {
            (true, Some(sp), Some(p)) if sp.uses_pill => (p.horizontal_em, p.corner_radius), // exact, not from rounded padding
            _ => CaptionStyleEdit::pill_metrics(&style),
        };
        Some(CaptionStyleState { style, base_id: base, animation_id: anim, pill_size, pill_corners })
    }

    /// One Style tab edit as one undo step (`continues_gesture`: merges with the previous edit, e.g. a color well drag).
    /// All captions: the kit caption style changes and every caption of the sequence uses it (own styles are released).
    /// Selected: those captions get a kit look of their own ("Own Style n"), updated in place while only they use it.
    // Swift: EditorSession+CaptionStyleTab.swift:353
    pub fn edit_caption_style(
        &mut self,
        f: CaptionStyleField,
        scope: CaptionStyleScope,
        continues_gesture: bool,
    ) -> bool {
        self.edit_caption_style_fields(vec![f], scope, continues_gesture)
    }

    /// Several fields as one undo step (one edit of the shared Text inspector can change a layer and its details).
    // Swift: EditorSession+CaptionStyleTab.swift:359
    pub fn edit_caption_style_fields(
        &mut self,
        fields: Vec<CaptionStyleField>,
        scope: CaptionStyleScope,
        continues_gesture: bool,
    ) -> bool {
        if fields.is_empty() {
            return true;
        }
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let key = format!("captionStyle:{}:{}", scope.raw_value(), self.gesture_counter);
        let (Some(tl_id), Some(track)) = (self.active_timeline_id, self.current_caption_track().cloned()) else {
            return false;
        };
        let Some(tracks) = self.active_timeline().map(|t| t.caption_tracks.clone()) else { return false };
        let lib = CaptionLookRegistry::shared().library_for_project(self.project());
        match scope {
            CaptionStyleScope::All
                if tracks.first().map(|t| t.id) != Some(track.id) || CaptionStyleEdit::shows_own_look(&track) =>
            {
                self.edit_track_look(&fields, &track, tl_id, &key)
            }
            CaptionStyleScope::All => {
                let mut kit = self.project().style_kit.clone().unwrap_or_default();
                if track.style_ref != CAPTION_STYLE_REF || kit.caption.is_none() {
                    // Start from what is on screen, not from a kit style the captions do not use.
                    let built_in = CaptionStyleEdit::built_in_style_ids();
                    let anims = CaptionStyleEdit::built_in_animation_ids();
                    // A custom animation (from a text clip or a saved look) stays: the kit spec carries its registry id.
                    let aref = track.animation_ref.clone();
                    let custom = aref != CAPTION_ANIMATION_REF && !anims.contains(&aref) && lib.has_animation(&aref);
                    let base = if built_in.contains(&track.style_ref) { track.style_ref.as_str() } else { "default" };
                    kit.caption = Some(kit_spec(base, (anims.contains(&aref) || custom).then_some(aref), None, false));
                }
                let kit = CaptionStyleEdit::apply_fields_to_kit(&fields, &kit);
                // The first track carries the project's kit style; other tracks that still use it follow, tracks with a
                // look of their own (see `edit_track_look`) keep it.
                let track_ids: Vec<Id> = tracks
                    .iter()
                    .filter(|t| t.id == track.id || t.style_ref == CAPTION_STYLE_REF || t.style_ref.is_empty())
                    .map(|t| t.id)
                    .collect();
                let all: BTreeSet<Id> = tracks
                    .iter()
                    .filter(|t| track_ids.contains(&t.id))
                    .flat_map(|t| t.items().iter().map(|i| i.id))
                    .collect();
                self.commit_caption_style(&key, |p| {
                    p.style_kit = Some(kit);
                    p.edit(tl_id, |t| {
                        for id in &track_ids {
                            t.set_caption_style(CAPTION_STYLE_REF, Some(CAPTION_ANIMATION_REF), *id, true)?;
                        }
                        t.set_caption_item_style(&all, None)
                    })?;
                    CaptionStyleEdit::prune_own_looks(p);
                    Ok(())
                })
            }
            CaptionStyleScope::Selected => {
                let ids = self.caption_selection.clone();
                let items: Vec<CaptionItem> =
                    self.caption_items().into_iter().filter(|c| ids.contains(&c.id)).collect();
                let Some(first) = items.first().cloned() else { return false };
                // The animation is the caption's own `animation_ref`, drawn by the same path as the global one.
                let own_animation = fields.iter().rev().find_map(|f| match f {
                    CaptionStyleField::Animation(a) => Some(a.clone()),
                    _ => None,
                });
                if let Some(a) = &own_animation
                    && fields.iter().all(|f| matches!(f, CaptionStyleField::Animation(_)))
                {
                    return self.commit_caption_style(&key, |p| {
                        p.edit(tl_id, |t| t.set_caption_item_animation(&ids, Some(a)))
                    });
                }
                let look = CaptionLook::new(
                    CaptionStyleEdit::apply_fields_to_style(&fields, &lib.style(Some(first.style_ref.as_str())), &lib),
                    lib.animation(Some(first.animation_ref.as_str())),
                );
                let mut kit = self.project().style_kit.clone().unwrap_or_default();
                let look_prefix = CaptionLook::style_id(&<StyleKit as StyleKitTextExt>::look_id(""));
                let mut look_id: Option<String> = None;
                // The selection already has a look of its own that nothing else uses: update it in place.
                let styles: BTreeSet<&str> = items.iter().map(|i| i.style_ref.as_str()).collect();
                if styles.len() == 1 && first.style_ref.starts_with(&format!("{look_prefix}{OWN_LOOK_PREFIX}")) {
                    let users: BTreeSet<Id> = self
                        .project()
                        .timelines
                        .iter()
                        .flat_map(|t| t.caption_tracks.iter().flat_map(|c| c.items().iter()))
                        .filter(|i| i.style_ref == first.style_ref)
                        .map(|i| i.id)
                        .collect();
                    if users == ids {
                        look_id = Some(first.style_ref[look_prefix.len()..].to_string());
                    }
                }
                let (id, name) = match look_id.and_then(|l| kit.looks.get(&l).map(|e| (l.clone(), e.name.clone()))) {
                    Some(found) => found,
                    None => {
                        let mut n = 1;
                        while kit.looks.contains_key(&format!("{OWN_LOOK_PREFIX}{n}")) {
                            n += 1;
                        }
                        (format!("{OWN_LOOK_PREFIX}{n}"), format!("Own Style {n}"))
                    }
                };
                if kit.add_look(&look, &id, &name).is_err() {
                    return false;
                }
                let style_ref = CaptionLook::style_id(&<StyleKit as StyleKitTextExt>::look_id(&id));
                self.commit_caption_style(&key, |p| {
                    p.style_kit = Some(kit);
                    p.edit(tl_id, |t| {
                        t.set_caption_item_style(&ids, Some(&style_ref))?;
                        if let Some(a) = &own_animation {
                            t.set_caption_item_animation(&ids, Some(a))?;
                        }
                        Ok(())
                    })?;
                    CaptionStyleEdit::prune_own_looks(p);
                    Ok(())
                })
            }
        }
    }

    /// All Captions on a track other than the first: the track gets a kit look of its own (`own-trk-<id>`), updated in
    /// place; every caption of that track follows it (own styles are released), other tracks are untouched.
    fn edit_track_look(
        &mut self,
        fields: &[CaptionStyleField],
        track: &sq_core_model::CaptionTrack,
        tl_id: Id,
        key: &str,
    ) -> bool {
        let lib = CaptionLookRegistry::shared().library_for_project(self.project());
        let own_animation = fields.iter().rev().find_map(|f| match f {
            CaptionStyleField::Animation(a) => Some(a.clone()),
            _ => None,
        });
        let style_fields: Vec<CaptionStyleField> =
            fields.iter().filter(|f| !matches!(f, CaptionStyleField::Animation(_))).cloned().collect();
        let animation_ref = own_animation.unwrap_or_else(|| track.animation_ref.clone());
        let mut kit = self.project().style_kit.clone().unwrap_or_default();
        let mut style_ref = if track.style_ref.is_empty() {
            track.items().first().map(|i| i.style_ref.clone()).unwrap_or_default()
        } else {
            track.style_ref.clone()
        };
        if !style_fields.is_empty() {
            let look = CaptionLook::new(
                CaptionStyleEdit::apply_fields_to_style(
                    &style_fields,
                    &lib.style(Some(style_ref.as_str()).filter(|r| !r.is_empty())),
                    &lib,
                ),
                lib.animation(Some(animation_ref.as_str()).filter(|r| !r.is_empty())),
            );
            let id = track_look_id(track.id);
            if kit.add_look(&look, &id, &format!("{} Look", track.name)).is_err() {
                return false;
            }
            style_ref = CaptionLook::style_id(&<StyleKit as StyleKitTextExt>::look_id(&id));
        }
        let ids: BTreeSet<Id> = track.items().iter().map(|i| i.id).collect();
        let track_id = track.id;
        self.commit_caption_style(key, |p| {
            p.style_kit = Some(kit);
            p.edit(tl_id, |t| {
                t.set_caption_style(
                    &style_ref,
                    Some(animation_ref.as_str()).filter(|a| !a.is_empty()),
                    track_id,
                    true,
                )?;
                t.set_caption_item_style(&ids, None)
            })?;
            CaptionStyleEdit::prune_own_looks(p);
            Ok(())
        })
    }

    /// Edits the project's kit (brand tokens, pill, motion) as one undo step; `continues_gesture` merges with the
    /// previous edit.
    // Swift: EditorSession+CaptionStyleTab.swift:471
    pub fn edit_style_kit(&mut self, name: &str, continues_gesture: bool, body: impl FnOnce(&mut StyleKit)) {
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let mut kit = self.project().style_kit.clone().unwrap_or_default();
        body(&mut kit);
        if Some(&kit) == self.project().style_kit.as_ref() {
            return;
        }
        let key = format!("styleKit:{}", self.gesture_counter);
        self.perform(name, Some(&key), |p| p.style_kit = Some(kit));
    }

    /// Where captions sit on the picture (all captions of the project, kept in its style kit).
    // Swift: EditorSession+CaptionStyleTab.swift:480
    pub fn caption_position(&self) -> CaptionPosition {
        self.project().style_kit.as_ref().and_then(|k| k.caption_position).unwrap_or_else(default_caption_position)
    }

    /// Moves every caption (top/middle/bottom, left/center/right, free offset) as one undo step; the default position
    /// is stored as `None`.
    // Swift: EditorSession+CaptionStyleTab.swift:484
    pub fn set_caption_position(&mut self, p: CaptionPosition, continues_gesture: bool) {
        self.edit_style_kit("Caption Position", continues_gesture, |k| {
            k.caption_position = if p == default_caption_position() { None } else { Some(p) };
        });
    }

    fn commit_caption_style(
        &mut self,
        key: &str,
        body: impl FnOnce(&mut Project) -> Result<(), sq_core_model::EditError>,
    ) -> bool {
        let before = self.history.current().clone();
        if let Err(e) = self.perform_ids("Caption Style", Some(key), |p, _| body(p)) {
            self.set_error(EditorSession::message_for(&e));
            return false;
        }
        *self.history.current() != before
    }
}

/// The kit look id of a caption track's own look.
fn track_look_id(track: Id) -> String {
    format!("{OWN_LOOK_PREFIX}trk-{}", track.to_string().chars().take(8).collect::<String>())
}
