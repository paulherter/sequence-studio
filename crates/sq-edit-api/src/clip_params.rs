//! Every inspector parameter of a clip (or of one layer of a graphics clip) as one list, and the verbs on it. The values
//! live in the model's own `ClipAnimation` / `ClipEffect` / `EffectCatalog` (the Effect Controls read the same), so this
//! file holds no second parameter list: it only names them with a path and converts values to and from JSON.
//!
//! Paths: `motion.position|scale|rotation|anchor|tiltX|tiltY|shutterAngle|antiFlicker`, `opacity`, `audio.volumeDb`,
//! `audio.gainDb`, `effect.<effectId>.<key>`; on a layer of a graphics clip the same with a `layer.<layerId>.` prefix.
//! Units are the model's: scale 1 = 100 %, opacity 0...1, rotation in degrees, position in sequence px from the center,
//! effect values as stored (the catalog range).

use serde_json::{Map, Value, json};
use sq_core_model::{
    AnimatedProperty, Clip, ClipAnimation, ClipEffect, EffectCatalog, EffectColor, EffectParamKind, EffectParamSpec,
    GraphicsContent, GraphicsLayer, TrackKind, TrackPan,
};
use sq_core_time::{Id, IdSource, Interpolation, Keyframe, KeyframeValue, Time, Vec2};

/// The animation fields a clip or layer has.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Anim {
    Position,
    Scale,
    Rotation,
    Anchor,
    TiltX,
    TiltY,
    Opacity,
    Volume,
    Shutter,
    AntiFlicker,
}

const ANIMS: [(&str, Anim); 10] = [
    ("motion.position", Anim::Position),
    ("motion.scale", Anim::Scale),
    ("motion.rotation", Anim::Rotation),
    ("motion.anchor", Anim::Anchor),
    ("motion.tiltX", Anim::TiltX),
    ("motion.tiltY", Anim::TiltY),
    ("motion.shutterAngle", Anim::Shutter),
    ("motion.antiFlicker", Anim::AntiFlicker),
    ("opacity", Anim::Opacity),
    ("audio.volumeDb", Anim::Volume),
];

/// What a path points at.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Addr {
    Anim(Anim),
    GainDb,
    Effect(Id, String),
}

/// A path split into its optional layer and the address.
pub(crate) fn parse_path(path: &str) -> Result<(Option<Id>, Addr), String> {
    let (layer, rest) = match path.strip_prefix("layer.") {
        Some(r) => {
            let (id, rest) = r.split_once('.').ok_or_else(|| format!("bad param path '{path}'"))?;
            (Some(Id::parse(id).ok_or_else(|| format!("bad layer id in '{path}'"))?), rest)
        }
        None => (None, path),
    };
    if let Some((_, a)) = ANIMS.iter().find(|(p, _)| *p == rest) {
        return Ok((layer, Addr::Anim(*a)));
    }
    if rest == "audio.gainDb" {
        return Ok((layer, Addr::GainDb));
    }
    if let Some(r) = rest.strip_prefix("effect.")
        && let Some((id, key)) = r.split_once('.')
        && let Some(id) = Id::parse(id)
        && !key.is_empty()
    {
        return Ok((layer, Addr::Effect(id, key.to_string())));
    }
    Err(format!(
        "unknown param path '{path}'; see GET /v1/clip/<id>/params (motion.*, opacity, audio.volumeDb, audio.gainDb, effect.<id>.<key>, layer.<id>.<...>)"
    ))
}

#[derive(Clone, Copy, PartialEq)]
enum Ty {
    Number,
    Bool,
    Choice,
    Vec2,
    Color,
    Text,
}

impl Ty {
    fn name(self) -> &'static str {
        match self {
            Ty::Number => "number",
            Ty::Bool => "bool",
            Ty::Choice => "choice",
            Ty::Vec2 => "vec2",
            Ty::Color => "color",
            Ty::Text => "text",
        }
    }
}

struct Meta {
    title: String,
    unit: String,
    ty: Ty,
    min: Option<f64>,
    max: Option<f64>,
    default: Value,
    choices: Vec<String>,
    /// Stored linear, shown and set in dB.
    db: bool,
}

fn vec2_json(v: Vec2) -> Value {
    json!({"x": v.x, "y": v.y})
}

fn color_json(c: EffectColor) -> Value {
    json!([c.red, c.green, c.blue, c.alpha])
}

fn to_db(linear: f64) -> f64 {
    if linear <= 0.0 { TrackPan::MIN_VOLUME_DB } else { (20.0 * linear.log10()).max(TrackPan::MIN_VOLUME_DB) }
}

fn anim_meta(a: Anim) -> Meta {
    let m = |title: &str, unit: &str, ty, min, max, default: Value| Meta {
        title: title.into(),
        unit: unit.into(),
        ty,
        min,
        max,
        default,
        choices: Vec::new(),
        db: false,
    };
    match a {
        Anim::Position => m("Position", "px", Ty::Vec2, None, None, vec2_json(Vec2::ZERO)),
        Anim::Scale => m("Scale", "x (1 = 100%)", Ty::Vec2, Some(0.0), None, vec2_json(Vec2::new(1.0, 1.0))),
        Anim::Rotation => m("Rotation", "deg", Ty::Number, None, None, json!(0.0)),
        Anim::Anchor => m("Anchor Point", "px", Ty::Vec2, None, None, vec2_json(Vec2::ZERO)),
        Anim::TiltX => m("Tilt X", "deg", Ty::Number, None, None, json!(0.0)),
        Anim::TiltY => m("Tilt Y", "deg", Ty::Number, None, None, json!(0.0)),
        Anim::Opacity => m("Opacity", "0...1", Ty::Number, Some(0.0), Some(1.0), json!(1.0)),
        Anim::Shutter => m("Shutter Angle", "deg", Ty::Number, Some(0.0), Some(360.0), json!(0.0)),
        Anim::AntiFlicker => m("Anti-flicker", "", Ty::Number, Some(0.0), None, json!(0.0)),
        Anim::Volume => Meta {
            db: true,
            ..m("Volume", "dB", Ty::Number, Some(TrackPan::MIN_VOLUME_DB), Some(TrackPan::MAX_VOLUME_DB), json!(0.0))
        },
    }
}

fn effect_meta(s: &EffectParamSpec) -> Meta {
    let (ty, choices, default) = match &s.kind {
        EffectParamKind::Slider => (Ty::Number, Vec::new(), json!(s.default_value)),
        EffectParamKind::Checkbox => (Ty::Bool, Vec::new(), json!(s.default_value >= 0.5)),
        EffectParamKind::Choice(t) => (Ty::Choice, t.clone(), json!(s.default_value)),
        EffectParamKind::Color(c) => (Ty::Color, Vec::new(), color_json(*c)),
        EffectParamKind::Point(v) => (Ty::Vec2, Vec::new(), vec2_json(*v)),
    };
    let scalar = ty == Ty::Number || ty == Ty::Choice;
    Meta {
        title: s.title.clone(),
        unit: s.unit.clone(),
        ty,
        min: scalar.then(|| *s.range.start()),
        max: scalar.then(|| *s.range.end()),
        default,
        choices,
        db: false,
    }
}

/// A mutable view of one slot, by value type.
enum Slot<'a> {
    Num(&'a mut AnimatedProperty<f64>),
    Vec(&'a mut AnimatedProperty<Vec2>),
    Col(&'a mut AnimatedProperty<EffectColor>),
}

/// The animation and effects of a clip or of one graphics layer.
pub(crate) struct Host<'a> {
    pub anim: &'a mut ClipAnimation,
    pub effects: &'a mut Vec<ClipEffect>,
    pub gain: Option<&'a mut f64>,
    pub audio: bool,
    /// Clip length: keys sit inside it (clip-local time).
    pub duration: Time,
}

impl<'a> Host<'a> {
    pub fn of_clip(c: &'a mut Clip) -> Host<'a> {
        let (audio, duration) = (c.kind == TrackKind::Audio, c.duration());
        Host { anim: &mut c.animation, effects: &mut c.effects, gain: Some(&mut c.audio_gain_db), audio, duration }
    }

    pub fn of_layer(l: &'a mut GraphicsLayer, duration: Time) -> Host<'a> {
        Host { anim: &mut l.animation, effects: &mut l.effects, gain: None, audio: false, duration }
    }

    fn slot(&mut self, addr: &Addr) -> Result<(Slot<'_>, Meta), String> {
        match addr {
            Addr::GainDb => Err("audio.gainDb has no keyframes".into()),
            Addr::Anim(a) => {
                if (*a == Anim::Volume) != self.audio {
                    let path = ANIMS.iter().find(|(_, x)| x == a).map_or("?", |(p, _)| *p);
                    return Err(format!("'{path}' is not a parameter of this clip; see GET /v1/clip/<id>/params"));
                }
                let meta = anim_meta(*a);
                let m = &mut *self.anim;
                Ok((
                    match *a {
                        Anim::Position => Slot::Vec(&mut m.position),
                        Anim::Scale => Slot::Vec(&mut m.scale),
                        Anim::Anchor => Slot::Vec(&mut m.anchor),
                        Anim::Rotation => Slot::Num(&mut m.rotation),
                        Anim::Opacity => Slot::Num(&mut m.opacity),
                        Anim::Volume => Slot::Num(&mut m.volume),
                        Anim::Shutter => Slot::Num(&mut m.shutter_angle),
                        Anim::AntiFlicker => Slot::Num(&mut m.anti_flicker),
                        Anim::TiltX => Slot::Num(&mut m.tilt_x),
                        Anim::TiltY => Slot::Num(&mut m.tilt_y),
                    },
                    meta,
                ))
            }
            Addr::Effect(id, key) => {
                let e = self.effects.iter_mut().find(|e| e.id == *id).ok_or_else(|| format!("no effect {id} on this clip"))?;
                let spec = EffectCatalog::param(&e.kind, key)
                    .ok_or_else(|| format!("effect '{}' has no parameter '{key}'", e.kind))?;
                let meta = effect_meta(&spec);
                let slot = match &spec.kind {
                    EffectParamKind::Color(c) => {
                        Slot::Col(e.colors.entry(key.clone()).or_insert_with(|| AnimatedProperty::new(*c)))
                    }
                    EffectParamKind::Point(v) => {
                        Slot::Vec(e.points.entry(key.clone()).or_insert_with(|| AnimatedProperty::new(*v)))
                    }
                    _ => {
                        // The linked Y of a pair is stored only while unlinked: do not create it behind the user's back.
                        let linked_y = EffectCatalog::spec_for(&e.kind)
                            .is_some_and(|s| s.pairs.iter().any(|p| p.linkable && p.y == *key));
                        if linked_y && !e.parameters.contains_key(key) {
                            return Err(format!("'{key}' follows its linked pair; set the X parameter instead"));
                        }
                        Slot::Num(e.parameters.entry(key.clone()).or_insert_with(|| AnimatedProperty::new(spec.default_value)))
                    }
                };
                Ok((slot, meta))
            }
        }
    }

    /// Sets the static value; refused while the property has keys (the keys win, a silent no-op would mislead).
    pub fn set(&mut self, addr: &Addr, value: &Value) -> Result<(), String> {
        if *addr == Addr::GainDb {
            if !self.audio {
                return Err("audio.gainDb is a parameter of audio clips".into());
            }
            let g = parse_number(value)?;
            if !(-60.0..=60.0).contains(&g) {
                return Err("audio.gainDb must be within -60...60".into());
            }
            return self.gain.as_deref_mut().map(|x| *x = g).ok_or_else(|| "audio.gainDb exists on clips only".to_string());
        }
        let (slot, meta) = self.slot(addr)?;
        let animated = match &slot {
            Slot::Num(p) => p.is_animated(),
            Slot::Vec(p) => p.is_animated(),
            Slot::Col(p) => p.is_animated(),
        };
        if animated {
            return Err("the parameter has keyframes: use setKeyframe / removeKeyframe".into());
        }
        match slot {
            Slot::Num(p) => p.value = number_in(value, &meta)?,
            Slot::Vec(p) => p.value = parse_vec2(value)?,
            Slot::Col(p) => p.value = parse_color(value)?,
        }
        Ok(())
    }

    /// Adds (or replaces the key at the same time) a key at clip-local `at`.
    pub fn set_key(
        &mut self,
        addr: &Addr,
        at: Time,
        value: &Value,
        interpolation: Option<Interpolation>,
        ids: &mut dyn IdSource,
    ) -> Result<(), String> {
        if at < Time::ZERO || at > self.duration {
            return Err("at must lie inside the clip (clip-local time, 0 = clip start)".into());
        }
        let (slot, meta) = self.slot(addr)?;
        match slot {
            Slot::Num(p) => put_key(p, at, number_in(value, &meta)?, interpolation, ids),
            Slot::Vec(p) => put_key(p, at, parse_vec2(value)?, interpolation, ids),
            Slot::Col(p) => put_key(p, at, parse_color(value)?, interpolation, ids),
        }
        Ok(())
    }

    /// Removes the key at clip-local `at`.
    pub fn remove_key(&mut self, addr: &Addr, at: Time) -> Result<(), String> {
        let (slot, _) = self.slot(addr)?;
        let removed = match slot {
            Slot::Num(p) => drop_key(p, at),
            Slot::Vec(p) => drop_key(p, at),
            Slot::Col(p) => drop_key(p, at),
        };
        if removed { Ok(()) } else { Err("no keyframe at that time".into()) }
    }

    /// Every parameter as JSON (`prefix` = `layer.<id>.` or empty). Works on a copy: listing never creates a parameter.
    pub fn list(&mut self, prefix: &str, extra: Option<(&str, Id)>) -> Vec<Value> {
        let mut out = Vec::new();
        let mut put = |path: String, group: &str, meta: &Meta, slot: &Slot<'_>, e: Option<Id>| {
            let (value, animated, keys) = describe(slot, meta);
            let mut m = Map::new();
            m.insert("path".into(), json!(path));
            m.insert("group".into(), json!(group));
            m.insert("title".into(), json!(meta.title));
            m.insert("type".into(), json!(meta.ty.name()));
            if !meta.unit.is_empty() {
                m.insert("unit".into(), json!(meta.unit));
            }
            if let Some(v) = meta.min {
                m.insert("min".into(), json!(v));
            }
            if let Some(v) = meta.max {
                m.insert("max".into(), json!(v));
            }
            m.insert("default".into(), meta.default.clone());
            if !meta.choices.is_empty() {
                m.insert("choices".into(), json!(meta.choices));
            }
            m.insert("value".into(), value);
            m.insert("animated".into(), json!(animated));
            if animated {
                m.insert("keyframes".into(), Value::Array(keys));
            }
            if let Some(e) = e {
                m.insert("effect".into(), json!(e));
            }
            if let Some((k, id)) = extra {
                m.insert(k.into(), json!(id));
            }
            out.push(Value::Object(m));
        };
        let wanted: Vec<(&str, Anim)> =
            ANIMS.iter().copied().filter(|(_, a)| (*a == Anim::Volume) == self.audio).collect();
        for (p, a) in wanted {
            let kind = if self.audio { "Audio" } else if a == Anim::Opacity { "Opacity" } else { "Motion" };
            if let Ok((slot, meta)) = self.slot(&Addr::Anim(a)) {
                put(format!("{prefix}{p}"), kind, &meta, &slot, None);
            }
        }
        if self.audio && let Some(g) = self.gain.as_deref() {
            let meta = Meta {
                title: "Audio Gain".into(),
                unit: "dB".into(),
                ty: Ty::Number,
                min: Some(-60.0),
                max: Some(60.0),
                default: json!(0.0),
                choices: Vec::new(),
                db: false,
            };
            let mut p = AnimatedProperty::new(*g);
            put(format!("{prefix}audio.gainDb"), "Audio", &meta, &Slot::Num(&mut p), None);
        }
        let list: Vec<(Id, String)> = self.effects.iter().map(|e| (e.id, e.kind.clone())).collect();
        for (id, kind) in list {
            let Some(spec) = EffectCatalog::spec_for(&kind) else { continue };
            for p in &spec.params {
                let addr = Addr::Effect(id, p.key.clone());
                if let Ok((slot, meta)) = self.slot(&addr) {
                    put(format!("{prefix}effect.{id}.{}", p.key), &spec.title, &meta, &slot, Some(id));
                }
            }
        }
        out
    }
}

fn put_key<V: KeyframeValue>(
    p: &mut AnimatedProperty<V>,
    at: Time,
    v: V,
    interpolation: Option<Interpolation>,
    ids: &mut dyn IdSource,
) {
    let id = p.track.keys.iter().find(|k| k.time == at).map_or_else(|| ids.next_id(), |k| k.id);
    let mut k = Keyframe::new(id, at, v);
    if let Some(i) = interpolation {
        k.interpolation = i;
    }
    p.track.insert(k);
}

fn drop_key<V: KeyframeValue>(p: &mut AnimatedProperty<V>, at: Time) -> bool {
    let Some(id) = p.track.keys.iter().find(|k| k.time == at).map(|k| k.id) else { return false };
    p.track.remove(id);
    true
}

fn interp_name(i: Interpolation) -> &'static str {
    match i {
        Interpolation::Linear => "linear",
        Interpolation::Hold => "hold",
        Interpolation::Bezier => "bezier",
        Interpolation::HoldAhead => "holdAhead",
    }
}

/// `linear`, `hold` or `bezier`.
pub(crate) fn parse_interpolation(s: &str) -> Result<Interpolation, String> {
    match s {
        "linear" => Ok(Interpolation::Linear),
        "hold" => Ok(Interpolation::Hold),
        "bezier" => Ok(Interpolation::Bezier),
        other => Err(format!("interpolation: unknown '{other}'; known: linear, hold, bezier")),
    }
}

fn describe(slot: &Slot<'_>, meta: &Meta) -> (Value, bool, Vec<Value>) {
    let num = |v: f64| -> Value {
        match meta.ty {
            Ty::Bool => json!(v >= 0.5),
            _ if meta.db => json!(to_db(v)),
            _ => json!(v),
        }
    };
    fn keys<V: Clone>(p: &AnimatedProperty<V>, f: &dyn Fn(&V) -> Value) -> Vec<Value> {
        p.track
            .keys
            .iter()
            .map(|k| json!({"at": k.time, "value": f(&k.value), "interpolation": interp_name(k.interpolation)}))
            .collect()
    }
    match slot {
        Slot::Num(p) => (num(p.value), !p.track.is_empty(), keys(p, &|v| num(*v))),
        Slot::Vec(p) => (vec2_json(p.value), !p.track.is_empty(), keys(p, &|v| vec2_json(*v))),
        Slot::Col(p) => (color_json(p.value), !p.track.is_empty(), keys(p, &|v| color_json(*v))),
    }
}

fn parse_number(v: &Value) -> Result<f64, String> {
    match v {
        Value::Number(n) => n.as_f64().filter(|x| x.is_finite()).ok_or_else(|| "value is not a finite number".into()),
        Value::Bool(b) => Ok(f64::from(u8::from(*b))),
        other => Err(format!("expected a number, got {other}")),
    }
}

/// A scalar in the property's units, range-checked; dB is converted to the stored linear gain, a choice may be named.
fn number_in(v: &Value, meta: &Meta) -> Result<f64, String> {
    let x = match (meta.ty, v) {
        (Ty::Choice, Value::String(s)) => meta
            .choices
            .iter()
            .position(|c| c.eq_ignore_ascii_case(s))
            .map(|i| i as f64)
            .ok_or_else(|| format!("unknown choice '{s}'; known: {}", meta.choices.join(", ")))?,
        _ => parse_number(v)?,
    };
    if meta.min.is_some_and(|m| x < m) || meta.max.is_some_and(|m| x > m) {
        let (lo, hi) = (meta.min.map_or("-inf".to_string(), |m| m.to_string()), meta.max.map_or("inf".to_string(), |m| m.to_string()));
        return Err(format!("{} must be within {lo}...{hi}, got {x}", meta.title));
    }
    Ok(if meta.db { TrackPan::linear(x) } else { x })
}

fn parse_vec2(v: &Value) -> Result<Vec2, String> {
    match v {
        Value::Number(_) => {
            let x = parse_number(v)?;
            Ok(Vec2::new(x, x))
        }
        Value::Array(a) if a.len() == 2 => Ok(Vec2::new(parse_number(&a[0])?, parse_number(&a[1])?)),
        Value::Object(m) => {
            let get = |k: &str| m.get(k).ok_or_else(|| format!("missing '{k}' in the point")).and_then(parse_number);
            Ok(Vec2::new(get("x")?, get("y")?))
        }
        other => Err(format!("expected {{\"x\":..,\"y\":..}}, [x, y] or one number, got {other}")),
    }
}

/// `[r,g,b(,a)]` 0...1, `{"r","g","b","a"?}` or `"#rrggbb(aa)"`.
pub(crate) fn parse_rgba(v: &Value) -> Result<[f64; 4], String> {
    let chan = |x: f64| if (0.0..=1.0).contains(&x) { Ok(x) } else { Err("color channels are 0...1".to_string()) };
    match v {
        Value::String(s) => {
            let h = s.strip_prefix('#').ok_or("colors are #rrggbb, #rrggbbaa or [r,g,b,a] in 0...1")?;
            if (h.len() != 6 && h.len() != 8) || !h.is_ascii() {
                return Err("colors are #rrggbb or #rrggbbaa".into());
            }
            let b = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).map(|x| f64::from(x) / 255.0).map_err(|e| e.to_string());
            Ok([b(0)?, b(2)?, b(4)?, if h.len() == 8 { b(6)? } else { 1.0 }])
        }
        Value::Array(a) if a.len() == 3 || a.len() == 4 => {
            let g = |i: usize| a.get(i).map_or(Ok(1.0), |x| parse_number(x).and_then(chan));
            Ok([chan(parse_number(&a[0])?)?, chan(parse_number(&a[1])?)?, chan(parse_number(&a[2])?)?, g(3)?])
        }
        Value::Object(m) => {
            let get = |long: &str, short: &str, d: Option<f64>| match m.get(long).or_else(|| m.get(short)) {
                Some(x) => parse_number(x).and_then(chan),
                None => d.ok_or_else(|| format!("missing '{short}'")),
            };
            Ok([get("red", "r", None)?, get("green", "g", None)?, get("blue", "b", None)?, get("alpha", "a", Some(1.0))?])
        }
        other => Err(format!("expected a color, got {other}")),
    }
}

fn parse_color(v: &Value) -> Result<EffectColor, String> {
    let [red, green, blue, alpha] = parse_rgba(v)?;
    Ok(EffectColor { red, green, blue, alpha })
}

/// The whole read model of a clip: parameters, effects, layers.
pub fn clip_params_json(clip: &Clip) -> Value {
    let mut c = clip.clone();
    let mut params = Host::of_clip(&mut c).list("", None);
    let effects: Vec<Value> = clip
        .effects
        .iter()
        .map(|e| json!({"id": e.id, "kind": e.kind, "title": EffectCatalog::title_for(&e.kind), "enabled": e.enabled}))
        .collect();
    let mut layers = Vec::new();
    if let Some(doc) = c.graphics_store.clone() {
        let duration = c.duration();
        for mut l in doc.layers {
            let id = l.id;
            let mut entry = Map::new();
            entry.insert("id".into(), json!(id));
            entry.insert("name".into(), json!(l.name));
            if let GraphicsContent::Text { generator } = &l.content {
                entry.insert("type".into(), json!("text"));
                if let Ok((tpl, _)) = sq_text::text_generator::TextGenerator::decode(generator) {
                    entry.insert("text".into(), json!(tpl.text));
                    entry.insert("style".into(), serde_json::to_value(&tpl.style).unwrap_or(Value::Null));
                }
            } else {
                entry.insert("type".into(), json!("shape"));
            }
            layers.push(Value::Object(entry));
            let name = l.name.clone();
            let is_text = l.is_text();
            let text = match &l.content {
                GraphicsContent::Text { generator } => sq_text::text_generator::TextGenerator::decode(generator).ok(),
                _ => None,
            };
            let mut host = Host::of_layer(&mut l, duration);
            params.extend(host.list(&format!("layer.{id}."), Some(("layer", id))));
            if is_text && let Some((tpl, _)) = text {
                let mut text_param = |path: String, title: &str, ty: Ty, value: Value| {
                    params.push(json!({"path": format!("layer.{id}.{path}"), "group": name, "title": title, "type": ty.name(),
                        "value": value, "animated": false, "layer": id}));
                };
                text_param("text".into(), "Text", Ty::Text, json!(tpl.text));
                text_param("style".into(), "Text style", Ty::Text, serde_json::to_value(&tpl.style).unwrap_or(Value::Null));
            }
        }
    }
    json!({"clip": clip.id, "name": clip.name, "params": params, "effects": effects, "layers": layers})
}

/// The Effects panel catalog: video and audio effects with their parameters.
pub fn effects_catalog_json() -> Value {
    let hiding = sq_core_model::hidden_catalog::is_active();
    let one = |s: &sq_core_model::EffectSpec, scope: &str| {
        let params: Vec<Value> = s
            .params
            .iter()
            .map(|p| {
                let m = effect_meta(p);
                let mut o = Map::new();
                o.insert("key".into(), json!(p.key));
                o.insert("title".into(), json!(m.title));
                o.insert("type".into(), json!(m.ty.name()));
                if !m.unit.is_empty() {
                    o.insert("unit".into(), json!(m.unit));
                }
                if let Some(v) = m.min {
                    o.insert("min".into(), json!(v));
                }
                if let Some(v) = m.max {
                    o.insert("max".into(), json!(v));
                }
                o.insert("default".into(), m.default);
                if !m.choices.is_empty() {
                    o.insert("choices".into(), json!(m.choices));
                }
                Value::Object(o)
            })
            .collect();
        json!({"kind": s.kind, "title": s.title, "scope": scope, "params": params})
    };
    let mut out: Vec<Value> = EffectCatalog::offered_video(hiding).iter().map(|s| one(s, "video")).collect();
    out.extend(EffectCatalog::offered_audio(hiding).iter().map(|s| one(s, "audio")));
    json!({"effects": out})
}
