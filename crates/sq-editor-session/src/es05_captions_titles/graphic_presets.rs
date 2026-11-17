//! Built-in graphics made of shape and text layers only: the CTA end card, stickers, lower thirds and callouts.

use std::sync::{Arc, LazyLock};

use sq_core_model::{AnimatedProperty, ClipAnimation, ClipEffect, EffectColor, GraphicsLayer, ShapeKind};
use sq_core_time::keyframes_model::{Keyframe, KeyframeValue, Vec2};
use sq_core_time::{IdSource, Time};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::{FontWeight, RGBAColor, TextAlignment, TextShadow, TextStyle};
use sq_text::text_template::TextTemplate;

/// An error while building a text layer.
pub type BuildError = String;

// MARK: building blocks shared by the CTA card and the catalog

fn secs(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

/// Seconds as a time with millisecond precision.
fn sec(s: f64) -> Time {
    Time::new((s * 1000.0).round() as i64, 1000)
}

/// Pixel unit: 1 at 1080 px on the short side.
fn unit(w: i64, h: i64) -> f64 {
    w.min(h) as f64 / 1080.0
}

fn keys<V: KeyframeValue + Clone>(ids: &mut dyn IdSource, pairs: &[(f64, V)], default: V) -> AnimatedProperty<V> {
    let mut p = AnimatedProperty::new(default);
    for (t, x) in pairs {
        p.track.insert(Keyframe::new(ids.next_id(), sec(*t), x.clone()));
    }
    p
}

struct ShapeSpec {
    width: f64,
    height: f64,
    fill: Option<EffectColor>,
    stroke: Option<EffectColor>,
    stroke_width: f64,
    radius: f64,
}

fn shape(ids: &mut dyn IdSource, kind: ShapeKind, name: &str, w: i64, h: i64, spec: ShapeSpec) -> GraphicsLayer {
    let mut l = GraphicsLayer::shape(ids, kind, w, h);
    l.name = name.to_string();
    l.set_shape_size(spec.width, spec.height);
    if let Some(e) = l.effects.first_mut() {
        e.parameters.insert(ClipEffect::SHAPE_CORNER_RADIUS_KEY.to_string(), AnimatedProperty::new(spec.radius));
        e.parameters.insert(
            ClipEffect::SHAPE_FILL_KEY.to_string(),
            AnimatedProperty::new(if spec.fill.is_none() { 0.0 } else { 1.0 }),
        );
        if let Some(f) = spec.fill {
            e.colors.insert(ClipEffect::SHAPE_FILL_COLOR_KEY.to_string(), AnimatedProperty::new(f));
        }
        e.parameters.insert(
            ClipEffect::SHAPE_STROKE_KEY.to_string(),
            AnimatedProperty::new(if spec.stroke.is_none() { 0.0 } else { 1.0 }),
        );
        if let Some(c) = spec.stroke {
            e.colors.insert(ClipEffect::SHAPE_STROKE_COLOR_KEY.to_string(), AnimatedProperty::new(c));
            e.parameters
                .insert(ClipEffect::SHAPE_STROKE_WIDTH_KEY.to_string(), AnimatedProperty::new(spec.stroke_width));
        }
    }
    l
}

fn text(ids: &mut dyn IdSource, name: &str, string: &str, style: TextStyle) -> Result<GraphicsLayer, BuildError> {
    let r = TextGenerator::make_ref(&TextTemplate::new(name, string, style), None).map_err(|e| e.to_string())?;
    Ok(GraphicsLayer::text(ids.next_id(), r, name))
}

/// Text style of the catalog: centered white, optional shadow, tracking and capitals.
#[derive(Clone, Copy)]
struct Style {
    size: f64,
    weight: FontWeight,
    color: RGBAColor,
    shadow: bool,
    tracking: f64,
    caps: bool,
}

fn style(size: f64, weight: FontWeight) -> Style {
    Style { size, weight, color: RGBAColor::WHITE, shadow: false, tracking: 0.0, caps: false }
}

impl Style {
    fn color(mut self, c: RGBAColor) -> Style {
        self.color = c;
        self
    }
    fn shadow(mut self, on: bool) -> Style {
        self.shadow = on;
        self
    }
    fn tracking(mut self, t: f64) -> Style {
        self.tracking = t;
        self
    }
    fn caps(mut self, on: bool) -> Style {
        self.caps = on;
        self
    }
    fn build(self) -> TextStyle {
        let mut s = TextStyle::new(TextStyle::default_font_name(), self.size, self.weight, self.color);
        s.shadow = self.shadow.then(|| TextShadow::from_angle(RGBAColor::new(0.0, 0.0, 0.0, 0.55), 135.0, 3.0, 8.0));
        s.alignment = TextAlignment::Center;
        s.tracking = self.tracking;
        s.all_caps = self.caps;
        s
    }
}

const INK: RGBAColor = RGBAColor { red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0 };

fn yellow() -> EffectColor {
    EffectColor { red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0 }
}
fn red() -> EffectColor {
    EffectColor { red: 1.0, green: 0.19, blue: 0.19, alpha: 1.0 }
}
fn white() -> EffectColor {
    EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 }
}
fn ink() -> EffectColor {
    EffectColor { red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0 }
}
fn blue() -> EffectColor {
    EffectColor { red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0 }
}
fn color(red: f64, green: f64, blue: f64, alpha: f64) -> EffectColor {
    EffectColor { red, green, blue, alpha }
}

/// Estimated width of one line (the renderer lays out the real one); only used to place left-aligned text.
fn est_width(s: &str, size: f64, factor: f64) -> f64 {
    s.chars().count() as f64 * size * factor
}

/// Pop in (overshoot), optional bob and wobble while it stays, pop out at the end.
fn pop(ids: &mut dyn IdSource, p: Vec2, d: Time, bob: f64, wobble: f64) -> ClipAnimation {
    let end = secs(d);
    let one = Vec2::new(1.0, 1.0);
    let mut a = ClipAnimation { position: AnimatedProperty::new(p), ..Default::default() };
    a.scale = keys(
        ids,
        &[
            (0.0, Vec2::new(0.0, 0.0)),
            (0.18, Vec2::new(1.15, 1.15)),
            (0.32, one),
            (end - 0.25, one),
            (end, Vec2::new(0.0, 0.0)),
        ],
        one,
    );
    if bob != 0.0 {
        let mut pairs: Vec<(f64, Vec2)> = vec![(0.0, p)];
        let (mut t, mut up) = (0.32, true);
        while t < end - 0.25 {
            pairs.push((t, Vec2::new(p.x, p.y + if up { -bob } else { 0.0 })));
            up = !up;
            t += 0.5;
        }
        pairs.push((end - 0.25, p));
        a.position = keys(ids, &pairs, p);
    }
    if wobble != 0.0 {
        let mut pairs: Vec<(f64, f64)> = vec![(0.0, 0.0)];
        let (mut t, mut sign) = (0.32, 1.0);
        while t < end - 0.25 {
            pairs.push((t, wobble * sign));
            sign = -sign;
            t += 0.45;
        }
        pairs.push((end - 0.25, 0.0));
        a.rotation = keys(ids, &pairs, 0.0);
    }
    a
}

/// Slide in from the left with a fade, hold, fade out.
fn slide(ids: &mut dyn IdSource, p: Vec2, dx: f64, delay: f64, d: Time) -> ClipAnimation {
    let end = secs(d);
    let from = Vec2::new(p.x + dx, p.y);
    ClipAnimation {
        position: keys(ids, &[(0.0, from), (delay, from), (delay + 0.4, p), (end, p)], p),
        opacity: keys(ids, &[(0.0, 0.0), (delay, 0.0), (delay + 0.3, 1.0), (end - 0.35, 1.0), (end, 0.0)], 1.0),
        ..Default::default()
    }
}

/// In: grows (or wipes) from `from` while fading up and moving in by `offset`; out: the same backwards; `pulse` makes it
/// breathe while it stays. Starts at opacity 0, so the first frame is never a hard cut.
fn reveal(ids: &mut dyn IdSource, p: Vec2, d: Time, from: Vec2, offset: Vec2, pulse: f64, delay: f64) -> ClipAnimation {
    let end = secs(d);
    let (in_end, out_start) = (delay + 0.3, end - 0.3);
    let opacity = keys(ids, &[(0.0, 0.0), (delay, 0.0), (delay + 0.22, 1.0), (out_start, 1.0), (end, 0.0)], 1.0);
    let mut a = ClipAnimation { opacity, ..Default::default() };
    let one = Vec2::new(1.0, 1.0);
    let mut scale: Vec<(f64, Vec2)> = vec![(0.0, from), (delay, from), (in_end, one)];
    if pulse != 0.0 {
        let (mut t, mut up) = (in_end + 0.5, true);
        while t < out_start - 0.2 {
            scale.push((t, if up { Vec2::new(1.0 + pulse, 1.0 + pulse) } else { one }));
            up = !up;
            t += 0.5;
        }
    }
    scale.extend([(out_start, one), (end, from)]);
    a.scale = keys(ids, &scale, one);
    let away = Vec2::new(p.x + offset.x, p.y + offset.y);
    a.position = keys(ids, &[(0.0, away), (delay, away), (in_end, p), (out_start, p), (end, away)], p);
    a
}

// MARK: CTA end card

/// H1: the built-in follow / share end card of short videos: a pill, a bell icon and a label that pop in, get pressed
/// (the pill dips to 90 % and back) and switch to the second state ("FOLGEN" -> "GEFOLGT", red -> gray). Built from
/// existing generator types only, so no alpha video is needed and every part stays editable in the Graphics panel.
// Swift: CTAEndCard.swift:9
pub enum CTAEndCard {}

impl CTAEndCard {
    // Swift: CTAEndCard.swift:10
    pub const ID: &'static str = "cta-end-card";
    // Swift: CTAEndCard.swift:11
    pub const NAME: &'static str = "CTA End Card";
    // Swift: CTAEndCard.swift:12
    pub const LABEL: &'static str = "FOLGEN";
    pub const DONE_LABEL: &'static str = "GEFOLGT";
    pub const ICON: &'static str = "\u{1F514}";
    /// Length of the clip a new card gets.
    // Swift: CTAEndCard.swift:14
    pub const DURATION: Time = Time::new(4, 1);
    // Swift: CTAEndCard.swift:17
    pub const POP_UP: Time = Time::new(1, 4);
    pub const POP_SETTLE: Time = Time::new(7, 20);
    const PRESS_START: Time = Time::new(8, 5);
    const PRESS_DOWN: Time = Time::new(17, 10);
    const PRESS_UP: Time = Time::new(37, 20);
    const SWAP_START: Time = Time::new(33, 20);
    const SWAP_END: Time = Time::new(9, 5);
    const PRESS_SCALE: f64 = 0.9;
    const POP_OVERSHOOT: f64 = 1.1;

    // Swift: CTAEndCard.swift:21
    pub fn red() -> EffectColor {
        red()
    }

    /// Scale of the whole card at clip-local `t` (what every layer follows about the card's center).
    // Swift: CTAEndCard.swift:26
    pub fn card_scale_at_local(t: Time) -> f64 {
        let keys = [
            (Time::ZERO, 0.0),
            (Self::POP_UP, Self::POP_OVERSHOOT),
            (Self::POP_SETTLE, 1.0),
            (Self::PRESS_START, 1.0),
            (Self::PRESS_DOWN, Self::PRESS_SCALE),
            (Self::PRESS_UP, 1.0),
        ];
        if t <= keys[0].0 {
            return keys[0].1;
        }
        for i in 1..keys.len() {
            if t <= keys[i].0 {
                let (a, b) = (keys[i - 1], keys[i]);
                let f = secs(t - a.0) / secs(b.0 - a.0);
                return a.1 + (b.1 - a.1) * f;
            }
        }
        1.0
    }

    /// The layers, bottom first, for a `canvas_width` x `canvas_height` graphic.
    // Swift: CTAEndCard.swift:40
    pub fn layers(
        canvas_width: i64,
        canvas_height: i64,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<GraphicsLayer>, BuildError> {
        let (w, h) = (canvas_width as f64, canvas_height as f64);
        let pill_w = (w * 0.62).min(h * 0.4);
        let pill_h = pill_w * 0.235;
        let centre = Vec2::new(0.0, h * 0.18);
        let icon_x = -pill_w / 2.0 + pill_h * 0.85;
        let text_x = pill_h * 0.35;
        let grey = color(0.23, 0.23, 0.25, 1.0);

        let mut grey_fade = AnimatedProperty::new(0.0);
        let mut label_out = AnimatedProperty::new(1.0);
        let mut done_in = AnimatedProperty::new(0.0);
        for (prop, a, b) in [(&mut grey_fade, 0.0, 1.0), (&mut label_out, 1.0, 0.0), (&mut done_in, 0.0, 1.0)] {
            prop.track.insert(Keyframe::new(ids.next_id(), Self::SWAP_START, a));
            prop.track.insert(Keyframe::new(ids.next_id(), Self::SWAP_END, b));
        }

        let pill = |ids: &mut dyn IdSource, name: &str, c: EffectColor, opacity: AnimatedProperty<f64>| {
            let mut l = shape(
                ids,
                ShapeKind::Rectangle,
                name,
                canvas_width,
                canvas_height,
                ShapeSpec {
                    width: pill_w,
                    height: pill_h,
                    fill: Some(c),
                    stroke: None,
                    stroke_width: 0.0,
                    radius: pill_h / 2.0,
                },
            );
            l.animation = Self::motion(ids, centre, centre, opacity);
            l
        };
        let label =
            |ids: &mut dyn IdSource, name: &str, string: &str, size: f64, dx: f64, opacity: AnimatedProperty<f64>| {
                let mut st = style(size, FontWeight::Heavy).build();
                st.all_caps = true;
                let mut l = text(ids, name, string, st)?;
                l.animation = Self::motion(ids, Vec2::new(centre.x + dx, centre.y), centre, opacity);
                Ok::<GraphicsLayer, BuildError>(l)
            };

        let mut result =
            vec![pill(ids, "Pill", red(), AnimatedProperty::new(1.0)), pill(ids, "Pill Done", grey, grey_fade)];
        result.push(label(ids, "Icon", Self::ICON, pill_h * 0.5, icon_x - centre.x, AnimatedProperty::new(1.0))?);
        result.push(label(ids, "Label", Self::LABEL, pill_h * 0.36, text_x, label_out)?);
        result.push(label(ids, "Label Done", Self::DONE_LABEL, pill_h * 0.36, text_x, done_in)?);
        Ok(result)
    }

    /// Pop-in and press as Scale keys; the position keys move with the scale (about the card center `c`) so the layers
    /// keep their places inside the card.
    fn motion(ids: &mut dyn IdSource, p: Vec2, c: Vec2, opacity: AnimatedProperty<f64>) -> ClipAnimation {
        let mut s = AnimatedProperty::new(Vec2::new(1.0, 1.0));
        let mut pos = AnimatedProperty::new(p);
        for t in [Time::ZERO, Self::POP_UP, Self::POP_SETTLE, Self::PRESS_START, Self::PRESS_DOWN, Self::PRESS_UP] {
            let k = Self::card_scale_at_local(t);
            s.track.insert(Keyframe::new(ids.next_id(), t, Vec2::new(k, k)));
            pos.track.insert(Keyframe::new(ids.next_id(), t, Vec2::new(c.x + (p.x - c.x) * k, c.y + (p.y - c.y) * k)));
        }
        ClipAnimation { scale: s, position: pos, opacity, ..Default::default() }
    }
}

// MARK: catalog

/// The groups of the built-in graphics.
// Swift: GraphicPresets.swift:7
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphicPresetCategory {
    Sticker,
    LowerThird,
    Callout,
}

impl GraphicPresetCategory {
    /// Every category in the Swift `CaseIterable` order.
    pub const ALL: [GraphicPresetCategory; 3] =
        [GraphicPresetCategory::Sticker, GraphicPresetCategory::LowerThird, GraphicPresetCategory::Callout];

    // Swift: GraphicPresets.swift:10
    pub fn title(self) -> &'static str {
        match self {
            GraphicPresetCategory::Sticker => "Stickers",
            GraphicPresetCategory::LowerThird => "Lower Thirds",
            GraphicPresetCategory::Callout => "Callouts",
        }
    }

    /// Singular name used in an entry's Library title ("Arrow Sticker").
    // Swift: GraphicPresets.swift:14
    pub fn label(self) -> &'static str {
        match self {
            GraphicPresetCategory::Sticker => "Sticker",
            GraphicPresetCategory::LowerThird => "Lower Third",
            GraphicPresetCategory::Callout => "Callout",
        }
    }
}

/// Builds the layers of a graphic for a canvas size (ids come from the caller's source).
pub type GraphicBuild =
    Arc<dyn Fn(i64, i64, &mut dyn IdSource) -> Result<Vec<GraphicsLayer>, BuildError> + Send + Sync>;

/// A plain builder of a catalog entry.
type BuildFn = fn(i64, i64, &mut dyn IdSource) -> Result<Vec<GraphicsLayer>, BuildError>;

/// One built-in graphic.
#[derive(Clone)]
pub struct GraphicPresetEntry {
    // Swift: GraphicPresets.swift:21
    pub id: String,
    // Swift: GraphicPresets.swift:22
    pub name: String,
    // Swift: GraphicPresets.swift:23
    pub category: GraphicPresetCategory,
    /// Length of the clip a new graphic gets.
    // Swift: GraphicPresets.swift:25
    pub duration: Time,
    // Swift: GraphicPresets.swift:26
    pub build: GraphicBuild,
}

impl GraphicPresetEntry {
    /// The layers, bottom first, for a `canvas_width` x `canvas_height` graphic.
    // Swift: GraphicPresets.swift:29
    pub fn layers(
        &self,
        canvas_width: i64,
        canvas_height: i64,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<GraphicsLayer>, BuildError> {
        (self.build)(canvas_width, canvas_height, ids)
    }
}

/// The catalog of built-in stickers, lower thirds and callouts.
pub enum GraphicPresetCatalog {}

impl GraphicPresetCatalog {
    // Swift: GraphicPresets.swift:31
    pub fn entry(id: &str) -> Option<GraphicPresetEntry> {
        catalog().iter().find(|e| e.id == id).cloned()
    }

    /// Entries whose name contains every word of `query` (case-insensitive); an empty query returns all.
    // Swift: GraphicPresets.swift:35
    pub fn matching(query: &str) -> Vec<GraphicPresetEntry> {
        let q = query.to_lowercase();
        let tokens: Vec<&str> = q.split_whitespace().collect();
        catalog().iter().filter(|e| tokens.iter().all(|t| e.name.to_lowercase().contains(t))).cloned().collect()
    }

    // Swift: GraphicPresets.swift:39
    pub const STICKER_DURATION: Time = Time::new(3, 1);
    pub const LOWER_THIRD_DURATION: Time = Time::new(5, 1);
    pub const CALLOUT_DURATION: Time = Time::new(4, 1);

    // Swift: GraphicPresets.swift:41
    pub fn all() -> Vec<GraphicPresetEntry> {
        catalog().clone()
    }
}

fn catalog() -> &'static Vec<GraphicPresetEntry> {
    static ALL: LazyLock<Vec<GraphicPresetEntry>> = LazyLock::new(|| {
        let mut all = stickers();
        all.extend(lower_thirds());
        all.extend(callouts());
        all
    });
    &ALL
}

fn entry(
    id: &str,
    name: &str,
    category: GraphicPresetCategory,
    duration: Time,
    build: impl Fn(i64, i64, &mut dyn IdSource) -> Result<Vec<GraphicsLayer>, BuildError> + Send + Sync + 'static,
) -> GraphicPresetEntry {
    GraphicPresetEntry { id: id.to_string(), name: name.to_string(), category, duration, build: Arc::new(build) }
}

fn rect(width: f64, height: f64, fill: Option<EffectColor>, radius: f64) -> ShapeSpec {
    ShapeSpec { width, height, fill, stroke: None, stroke_width: 0.0, radius }
}

fn outlined(
    width: f64,
    height: f64,
    fill: Option<EffectColor>,
    stroke: EffectColor,
    stroke_width: f64,
    radius: f64,
) -> ShapeSpec {
    ShapeSpec { width, height, fill, stroke: Some(stroke), stroke_width, radius }
}

// MARK: stickers

fn emoji(id: &str, name: &'static str, glyph: &'static str) -> GraphicPresetEntry {
    entry(id, name, GraphicPresetCategory::Sticker, GraphicPresetCatalog::STICKER_DURATION, move |w, h, ids| {
        let u = unit(w, h);
        let mut l = text(ids, name, glyph, style(260.0 * u, FontWeight::Regular).build())?;
        l.animation = pop(ids, Vec2::new(0.0, 0.0), GraphicPresetCatalog::STICKER_DURATION, 0.0, 9.0);
        Ok(vec![l])
    })
}

fn stickers() -> Vec<GraphicPresetEntry> {
    let d = GraphicPresetCatalog::STICKER_DURATION;
    let sticker = |id: &str, name: &str, build: BuildFn| entry(id, name, GraphicPresetCategory::Sticker, d, build);
    vec![
        sticker("sticker-arrow", "Arrow", |w, h, ids| {
            let u = unit(w, h);
            let mut l = shape(
                ids,
                ShapeKind::Arrow,
                "Arrow",
                w,
                h,
                outlined(300.0 * u, 190.0 * u, Some(yellow()), ink(), 8.0 * u, 0.0),
            );
            l.animation = pop(ids, Vec2::new(0.0, 0.0), GraphicPresetCatalog::STICKER_DURATION, 28.0 * u, 0.0);
            Ok(vec![l])
        }),
        sticker("sticker-circle", "Circle", |w, h, ids| {
            let u = unit(w, h);
            let mut l = shape(
                ids,
                ShapeKind::Ellipse,
                "Circle",
                w,
                h,
                outlined(380.0 * u, 380.0 * u, None, red(), 16.0 * u, 0.0),
            );
            l.animation = pop(ids, Vec2::new(0.0, 0.0), GraphicPresetCatalog::STICKER_DURATION, 0.0, 0.0);
            let mut s = l.animation.scale.clone();
            // slow pulse while it stays
            s.track.insert(Keyframe::new(ids.next_id(), sec(1.1), Vec2::new(1.06, 1.06)));
            s.track.insert(Keyframe::new(ids.next_id(), sec(1.9), Vec2::new(1.0, 1.0)));
            l.animation.scale = s;
            Ok(vec![l])
        }),
        emoji("sticker-pop-fire", "Pop Fire", "\u{1F525}"),
        emoji("sticker-pop-heart", "Pop Heart", "\u{2764}\u{FE0F}"),
        emoji("sticker-pop-laugh", "Pop Laugh", "\u{1F602}"),
        sticker("sticker-swipe-up", "Swipe Up", |w, h, ids| {
            let u = unit(w, h);
            let d = GraphicPresetCatalog::STICKER_DURATION;
            let (pill_w, pill_h) = (520.0 * u, 120.0 * u);
            let centre = Vec2::new(0.0, h as f64 * 0.30);
            let mut pill =
                shape(ids, ShapeKind::Rectangle, "Pill", w, h, rect(pill_w, pill_h, Some(white()), pill_h / 2.0));
            pill.animation = pop(ids, centre, d, 0.0, 0.0);
            let mut label =
                text(ids, "Label", "SWIPE UP", style(52.0 * u, FontWeight::Heavy).color(INK).tracking(3.0).build())?;
            label.animation = pop(ids, Vec2::new(centre.x + 36.0 * u, centre.y), d, 0.0, 0.0);
            let mut arrow = text(
                ids,
                "Arrow",
                "\u{2191}",
                style(70.0 * u, FontWeight::Heavy).color(RGBAColor::new(1.0, 0.19, 0.19, 1.0)).build(),
            )?;
            arrow.animation = pop(ids, Vec2::new(centre.x - pill_w / 2.0 + 70.0 * u, centre.y), d, 16.0 * u, 0.0);
            Ok(vec![pill, label, arrow])
        }),
        sticker("sticker-link-in-bio", "Link in Bio", |w, h, ids| {
            let u = unit(w, h);
            let d = GraphicPresetCatalog::STICKER_DURATION;
            let (pill_w, pill_h) = (560.0 * u, 120.0 * u);
            let centre = Vec2::new(0.0, h as f64 * 0.30);
            let mut pill =
                shape(ids, ShapeKind::Rectangle, "Pill", w, h, rect(pill_w, pill_h, Some(blue()), pill_h / 2.0));
            pill.animation = pop(ids, centre, d, 0.0, 0.0);
            let mut icon = text(ids, "Icon", "\u{1F517}", style(64.0 * u, FontWeight::Regular).build())?;
            icon.animation = pop(ids, Vec2::new(centre.x - pill_w / 2.0 + 72.0 * u, centre.y), d, 0.0, 10.0);
            let mut label =
                text(ids, "Label", "LINK IN BIO", style(50.0 * u, FontWeight::Heavy).tracking(3.0).build())?;
            label.animation = pop(ids, Vec2::new(centre.x + 34.0 * u, centre.y), d, 0.0, 0.0);
            Ok(vec![pill, icon, label])
        }),
    ]
}

// MARK: lower thirds

/// Geometry shared by the lower thirds: left edge, name row and role row (canvas px from the center, y down).
#[derive(Clone, Copy)]
struct Frame {
    left: f64,
    name_y: f64,
    role_y: f64,
    u: f64,
}

impl Frame {
    fn new(w: i64, h: i64) -> Frame {
        let u = unit(w, h);
        let (wf, hf) = (w as f64, h as f64);
        let left = -wf * 0.5 + (wf * 0.07).max(60.0 * u);
        let name_y = hf * 0.5 - (hf * 0.2).max(250.0 * u);
        Frame { left, name_y, role_y: name_y + 62.0 * u, u }
    }
}

const NAME_TEXT: &str = "Your Name";
const ROLE_TEXT: &str = "Role or Place";

struct NameAndRole {
    x: f64,
    name_size: f64,
    role_size: f64,
    name_color: RGBAColor,
    role_color: RGBAColor,
    shadow: bool,
    name_caps: bool,
    delay: f64,
}

/// Name and role text layers, left-aligned at `x` (centers estimated from the text length).
fn name_and_role(ids: &mut dyn IdSource, f: Frame, o: NameAndRole) -> Result<Vec<GraphicsLayer>, BuildError> {
    let d = GraphicPresetCatalog::LOWER_THIRD_DURATION;
    let mut n = text(
        ids,
        "Name",
        NAME_TEXT,
        style(o.name_size, FontWeight::Heavy).color(o.name_color).shadow(o.shadow).caps(o.name_caps).build(),
    )?;
    n.animation = slide(
        ids,
        Vec2::new(o.x + est_width(NAME_TEXT, o.name_size, 0.58) / 2.0, f.name_y),
        -90.0 * f.u,
        o.delay + 0.08,
        d,
    );
    let mut r = text(
        ids,
        "Role",
        ROLE_TEXT,
        style(o.role_size, FontWeight::Medium).color(o.role_color).shadow(o.shadow).build(),
    )?;
    r.animation = slide(
        ids,
        Vec2::new(o.x + est_width(ROLE_TEXT, o.role_size, 0.52) / 2.0, f.role_y),
        -90.0 * f.u,
        o.delay + 0.16,
        d,
    );
    Ok(vec![n, r])
}

fn nr(x: f64, name_size: f64, role_size: f64) -> NameAndRole {
    NameAndRole {
        x,
        name_size,
        role_size,
        name_color: RGBAColor::WHITE,
        role_color: RGBAColor::WHITE,
        shadow: true,
        name_caps: false,
        delay: 0.0,
    }
}

fn lower_thirds() -> Vec<GraphicPresetEntry> {
    let d = GraphicPresetCatalog::LOWER_THIRD_DURATION;
    let lower = |id: &str, name: &str, build: BuildFn| entry(id, name, GraphicPresetCategory::LowerThird, d, build);
    vec![
        lower("lower-third-bar", "Bar", |w, h, ids| {
            let f = Frame::new(w, h);
            let mut bar = shape(
                ids,
                ShapeKind::Rectangle,
                "Accent",
                w,
                h,
                rect(10.0 * f.u, 112.0 * f.u, Some(yellow()), 5.0 * f.u),
            );
            bar.animation = slide(
                ids,
                Vec2::new(f.left, (f.name_y + f.role_y) / 2.0),
                -40.0 * f.u,
                0.0,
                GraphicPresetCatalog::LOWER_THIRD_DURATION,
            );
            let mut out = vec![bar];
            out.extend(name_and_role(ids, f, nr(f.left + 28.0 * f.u, 58.0 * f.u, 34.0 * f.u))?);
            Ok(out)
        }),
        lower("lower-third-box", "Box", |w, h, ids| {
            let f = Frame::new(w, h);
            let d = GraphicPresetCatalog::LOWER_THIRD_DURATION;
            let bw = est_width(NAME_TEXT, 58.0 * f.u, 0.58).max(est_width(ROLE_TEXT, 34.0 * f.u, 0.52)) + 80.0 * f.u;
            let bh = 140.0 * f.u;
            let mid = (f.name_y + f.role_y) / 2.0;
            let mut b = shape(
                ids,
                ShapeKind::Rectangle,
                "Box",
                w,
                h,
                rect(bw, bh, Some(color(0.07, 0.07, 0.09, 0.88)), 10.0 * f.u),
            );
            b.animation = slide(ids, Vec2::new(f.left + bw / 2.0, mid), -90.0 * f.u, 0.0, d);
            let mut line = shape(ids, ShapeKind::Rectangle, "Accent", w, h, rect(bw, 6.0 * f.u, Some(blue()), 0.0));
            line.animation = slide(ids, Vec2::new(f.left + bw / 2.0, mid + bh / 2.0 - 3.0 * f.u), -90.0 * f.u, 0.1, d);
            let mut out = vec![b, line];
            out.extend(name_and_role(
                ids,
                f,
                NameAndRole { shadow: false, delay: 0.1, ..nr(f.left + 40.0 * f.u, 58.0 * f.u, 34.0 * f.u) },
            )?);
            Ok(out)
        }),
        lower("lower-third-underline", "Underline", |w, h, ids| {
            let f = Frame::new(w, h);
            let d = GraphicPresetCatalog::LOWER_THIRD_DURATION;
            let lw = est_width(NAME_TEXT, 62.0 * f.u, 0.58).max(est_width(ROLE_TEXT, 34.0 * f.u, 0.52)) + 20.0 * f.u;
            let mut line =
                shape(ids, ShapeKind::Rectangle, "Accent", w, h, rect(lw, 6.0 * f.u, Some(red()), 3.0 * f.u));
            let y = f.name_y + 38.0 * f.u;
            line.animation = slide(ids, Vec2::new(f.left + lw / 2.0, y), -60.0 * f.u, 0.0, d);
            let mut s = AnimatedProperty::new(Vec2::new(1.0, 1.0));
            s.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(0.0, 1.0)));
            s.track.insert(Keyframe::new(ids.next_id(), sec(0.5), Vec2::new(1.0, 1.0)));
            line.animation.scale = s;
            let f2 = Frame { role_y: y + 44.0 * f.u, ..f };
            let mut out = vec![line];
            out.extend(name_and_role(ids, f2, nr(f.left + 6.0 * f.u, 62.0 * f.u, 34.0 * f.u))?);
            Ok(out)
        }),
        lower("lower-third-pill", "Pill", |w, h, ids| {
            let f = Frame::new(w, h);
            let d = GraphicPresetCatalog::LOWER_THIRD_DURATION;
            let pw = est_width(NAME_TEXT, 52.0 * f.u, 0.58) + 90.0 * f.u;
            let ph = 92.0 * f.u;
            let mut pill = shape(ids, ShapeKind::Rectangle, "Pill", w, h, rect(pw, ph, Some(white()), ph / 2.0));
            pill.animation = slide(ids, Vec2::new(f.left + pw / 2.0, f.name_y), -90.0 * f.u, 0.0, d);
            let mut n = text(ids, "Name", NAME_TEXT, style(52.0 * f.u, FontWeight::Heavy).color(INK).build())?;
            n.animation = slide(ids, Vec2::new(f.left + pw / 2.0, f.name_y), -90.0 * f.u, 0.08, d);
            let mut r = text(ids, "Role", ROLE_TEXT, style(34.0 * f.u, FontWeight::Semibold).shadow(true).build())?;
            r.animation = slide(
                ids,
                Vec2::new(f.left + 20.0 * f.u + est_width(ROLE_TEXT, 34.0 * f.u, 0.52) / 2.0, f.name_y + 76.0 * f.u),
                -90.0 * f.u,
                0.16,
                d,
            );
            Ok(vec![pill, n, r])
        }),
        lower("lower-third-slab", "Slab", |w, h, ids| {
            let f = Frame::new(w, h);
            let d = GraphicPresetCatalog::LOWER_THIRD_DURATION;
            let nw = est_width(NAME_TEXT, 56.0 * f.u, 0.58) + 70.0 * f.u;
            let rw = est_width(ROLE_TEXT, 32.0 * f.u, 0.52) + 70.0 * f.u;
            let mut top = shape(ids, ShapeKind::Rectangle, "Name Slab", w, h, rect(nw, 84.0 * f.u, Some(blue()), 0.0));
            top.animation = slide(ids, Vec2::new(f.left + nw / 2.0, f.name_y), -90.0 * f.u, 0.0, d);
            let mut bottom = shape(
                ids,
                ShapeKind::Rectangle,
                "Role Slab",
                w,
                h,
                rect(rw, 54.0 * f.u, Some(color(0.07, 0.07, 0.09, 0.9)), 0.0),
            );
            bottom.animation = slide(ids, Vec2::new(f.left + rw / 2.0, f.name_y + 69.0 * f.u), -90.0 * f.u, 0.1, d);
            let f2 = Frame { role_y: f.name_y + 69.0 * f.u, ..f };
            let mut out = vec![top, bottom];
            out.extend(name_and_role(
                ids,
                f2,
                NameAndRole { shadow: false, delay: 0.1, ..nr(f.left + 35.0 * f.u, 56.0 * f.u, 32.0 * f.u) },
            )?);
            Ok(out)
        }),
        lower("lower-third-minimal", "Minimal", |w, h, ids| {
            let f = Frame::new(w, h);
            let end = secs(GraphicPresetCatalog::LOWER_THIRD_DURATION);
            let mut layers =
                name_and_role(ids, f, NameAndRole { name_caps: true, ..nr(f.left, 54.0 * f.u, 32.0 * f.u) })?;
            // Rise and fade instead of a slide.
            for l in &mut layers {
                let p = l.animation.position.value_at_local(sec(1.0));
                l.animation = ClipAnimation {
                    position: keys(ids, &[(0.0, Vec2::new(p.x, p.y + 24.0 * f.u)), (0.45, p), (end, p)], p),
                    opacity: keys(ids, &[(0.0, 0.0), (0.4, 1.0), (end - 0.35, 1.0), (end, 0.0)], 1.0),
                    ..Default::default()
                };
            }
            Ok(layers)
        }),
    ]
}

// MARK: callouts (tutorial overlays: point at, box in, ring, mark, number)

fn callouts() -> Vec<GraphicPresetEntry> {
    let d = GraphicPresetCatalog::CALLOUT_DURATION;
    let callout = |id: &str, name: &str, build: BuildFn| entry(id, name, GraphicPresetCategory::Callout, d, build);
    vec![
        callout("callout-pointer", "Pointer", |w, h, ids| {
            let u = unit(w, h);
            let d = GraphicPresetCatalog::CALLOUT_DURATION;
            let mut l = shape(
                ids,
                ShapeKind::Arrow,
                "Pointer",
                w,
                h,
                outlined(260.0 * u, 150.0 * u, Some(yellow()), ink(), 8.0 * u, 0.0),
            );
            let p = Vec2::new(0.0, 0.0);
            let mut a = reveal(ids, p, d, Vec2::new(0.8, 0.8), Vec2::new(-160.0 * u, 0.0), 0.0, 0.0);
            // Nudges toward the target while it stays.
            let end = secs(d);
            let away = Vec2::new(p.x - 160.0 * u, p.y);
            let mut pairs: Vec<(f64, Vec2)> = vec![(0.0, away), (0.3, p)];
            let (mut t, mut fwd) = (0.8, true);
            while t < end - 0.4 {
                pairs.push((t, Vec2::new(p.x + if fwd { 30.0 * u } else { 0.0 }, p.y)));
                fwd = !fwd;
                t += 0.45;
            }
            pairs.extend([(end - 0.3, p), (end, away)]);
            a.position = keys(ids, &pairs, p);
            l.animation = a;
            Ok(vec![l])
        }),
        callout("callout-focus-ring", "Focus Ring", |w, h, ids| {
            let u = unit(w, h);
            let mut l = shape(
                ids,
                ShapeKind::Ellipse,
                "Ring",
                w,
                h,
                outlined(420.0 * u, 420.0 * u, None, red(), 14.0 * u, 0.0),
            );
            l.animation = reveal(
                ids,
                Vec2::new(0.0, 0.0),
                GraphicPresetCatalog::CALLOUT_DURATION,
                Vec2::new(1.7, 1.7),
                Vec2::new(0.0, 0.0),
                0.07,
                0.0,
            );
            Ok(vec![l])
        }),
        callout("callout-highlight-box", "Highlight Box", |w, h, ids| {
            let u = unit(w, h);
            let mut l = shape(
                ids,
                ShapeKind::Rectangle,
                "Box",
                w,
                h,
                outlined(640.0 * u, 220.0 * u, Some(color(1.0, 0.84, 0.04, 0.28)), yellow(), 8.0 * u, 18.0 * u),
            );
            // wipes open from the middle
            l.animation = reveal(
                ids,
                Vec2::new(0.0, 0.0),
                GraphicPresetCatalog::CALLOUT_DURATION,
                Vec2::new(0.0, 1.0),
                Vec2::new(0.0, 0.0),
                0.0,
                0.0,
            );
            Ok(vec![l])
        }),
        callout("callout-marker-line", "Marker Line", |w, h, ids| {
            let u = unit(w, h);
            let d = GraphicPresetCatalog::CALLOUT_DURATION;
            let p = Vec2::new(0.0, 0.0);
            let mut bar = shape(
                ids,
                ShapeKind::Rectangle,
                "Marker",
                w,
                h,
                rect(620.0 * u, 70.0 * u, Some(color(1.0, 0.84, 0.04, 0.85)), 12.0 * u),
            );
            bar.animation = reveal(ids, p, d, Vec2::new(0.0, 1.0), Vec2::new(0.0, 0.0), 0.0, 0.0);
            let mut label =
                text(ids, "Label", "KEY POINT", style(44.0 * u, FontWeight::Heavy).color(INK).tracking(2.0).build())?;
            label.animation = reveal(ids, p, d, Vec2::new(0.9, 0.9), Vec2::new(0.0, 0.0), 0.0, 0.15);
            Ok(vec![bar, label])
        }),
        callout("callout-label", "Label Tag", |w, h, ids| {
            let u = unit(w, h);
            let d = GraphicPresetCatalog::CALLOUT_DURATION;
            let p = Vec2::new(0.0, -(h as f64) * 0.12);
            let off = Vec2::new(0.0, 40.0 * u);
            let mut tag =
                shape(ids, ShapeKind::Rectangle, "Tag", w, h, rect(560.0 * u, 110.0 * u, Some(white()), 16.0 * u));
            tag.animation = reveal(ids, p, d, Vec2::new(0.6, 0.6), off, 0.0, 0.0);
            let mut label = text(ids, "Label", "Look here", style(54.0 * u, FontWeight::Heavy).color(INK).build())?;
            label.animation = reveal(ids, p, d, Vec2::new(0.6, 0.6), off, 0.0, 0.1);
            let tip = Vec2::new(0.0, p.y + 80.0 * u);
            let mut pointer = shape(ids, ShapeKind::Arrow, "Tip", w, h, rect(70.0 * u, 50.0 * u, Some(white()), 0.0));
            pointer.animation = reveal(ids, tip, d, Vec2::new(0.6, 0.6), off, 0.0, 0.05);
            pointer.animation.rotation = AnimatedProperty::new(90.0);
            Ok(vec![tag, pointer, label])
        }),
        callout("callout-step-badge", "Step Badge", |w, h, ids| {
            let u = unit(w, h);
            let d = GraphicPresetCatalog::CALLOUT_DURATION;
            let mut disc = shape(
                ids,
                ShapeKind::Ellipse,
                "Badge",
                w,
                h,
                outlined(190.0 * u, 190.0 * u, Some(blue()), white(), 10.0 * u, 0.0),
            );
            disc.animation = pop(ids, Vec2::new(0.0, 0.0), d, 0.0, 0.0);
            let mut n = text(ids, "Number", "1", style(120.0 * u, FontWeight::Black).build())?;
            n.animation = pop(ids, Vec2::new(0.0, 0.0), d, 0.0, 0.0);
            Ok(vec![disc, n])
        }),
    ]
}
