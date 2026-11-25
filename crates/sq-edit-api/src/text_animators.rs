//! Text animators of a text layer from JSON: the same `TextAnimator` the Text panel's animator rows edit, through the same
//! shared rules (`TextAnimator::starting` / `set_effect` / `set_unit`, `AnimationSet::set_text_animator`). A layer has at
//! most one animator per side: `in` (plays at the start of the clip) and `out` (at its end), so `side` names it.

use serde_json::{Map, Value, json};
use sq_core_model::anchored_animation::{
    AnimationSet, SegmentShape, TextAnimator, TextAnimatorEffect, TextCursor, TextAnimatorOrder, TextSlideDirection,
};
use sq_core_model::{GraphicsContent, GraphicsLayer};
use sq_core_time::Time;
use sq_text::text_generator::TextGenerator;

/// The fields of an animator request (besides the op's own `clip` / `layer`).
pub const ANIMATOR_KEYS: [&str; 13] = [
    "side", "effect", "unit", "order", "easing", "duration", "stagger", "direction", "distance", "blur", "loops", "overshoot", "cursor",
];

const MAX_MS: f64 = 60_000.0;
const MAX_PX: f64 = 2000.0;

/// `in` or `out` (default `in`).
pub fn parse_side(v: Option<&Value>) -> Result<bool, String> {
    match v.map(|s| s.as_str()) {
        None => Ok(true),
        Some(Some("in")) => Ok(true),
        Some(Some("out")) => Ok(false),
        _ => Err("side: \"in\" (plays at the clip start) or \"out\" (at its end)".into()),
    }
}

fn name<T: serde::de::DeserializeOwned>(key: &str, v: &Value, known: &str) -> Result<T, String> {
    serde_json::from_value(v.clone()).map_err(|_| format!("{key}: unknown {v}; known: {known}"))
}

fn number(key: &str, v: &Value, max: f64) -> Result<f64, String> {
    let n = v.as_f64().filter(|n| n.is_finite() && (0.0..=max).contains(n));
    n.ok_or_else(|| format!("{key}: a number 0...{max}"))
}

/// Checks the shape of a request body without touching a model (run when the request is decoded).
pub fn check_spec(v: &Value, need_effect: bool) -> Result<(), String> {
    let Value::Object(m) = v else { return Err("an animator is an object {effect, unit?, ...}".into()) };
    crate::edit_operation::check_strict_keys(m, &ANIMATOR_KEYS, "text animator")?;
    if need_effect && !m.contains_key("effect") {
        return Err("a new animator needs \"effect\" (see GET /v1/textAnimators)".into());
    }
    parse_side(m.get("side"))?;
    // Without an "effect" the real animator decides (in `apply`); the probe only checks the shape.
    let mut probe = TextAnimator::starting(if m.contains_key("effect") { TextAnimatorEffect::Fade } else { TextAnimatorEffect::Typewriter });
    patch(&mut probe, m)
}

/// Applies the fields of `m` to `a`: effect and unit first (they carry the panel's follow-up rules), then the rest.
fn patch(a: &mut TextAnimator, m: &Map<String, Value>) -> Result<(), String> {
    if let Some(v) = m.get("effect") {
        a.set_effect(name("effect", v, "fade, pop, slide, typewriter, blur, wave, pulse")?);
    }
    if let Some(v) = m.get("unit") {
        a.set_unit(name("unit", v, "character, word, line")?);
    }
    if let Some(v) = m.get("order") {
        a.order = name::<TextAnimatorOrder>("order", v, "forward, reverse, center")?;
    }
    if let Some(v) = m.get("easing") {
        let e: SegmentShape = name("easing", v, "linear, easeIn, easeOut, easeInOut, overshoot")?;
        if e == SegmentShape::Hold {
            return Err("easing: known: linear, easeIn, easeOut, easeInOut, overshoot".into());
        }
        a.easing = e;
    }
    if let Some(v) = m.get("duration") {
        a.duration = ms("duration", v)?;
    }
    if let Some(v) = m.get("stagger") {
        a.stagger = ms("stagger", v)?;
    }
    if let Some(v) = m.get("direction") {
        a.direction = name::<TextSlideDirection>("direction", v, "up, down, left, right")?;
    }
    if let Some(v) = m.get("distance") {
        a.distance = number("distance", v, MAX_PX)?;
    }
    if let Some(v) = m.get("blur") {
        a.blur_radius = number("blur", v, MAX_PX)?;
    }
    if let Some(v) = m.get("loops") {
        let n = v.as_i64().filter(|n| (1..=50).contains(n)).ok_or("loops: a whole number 1...50")?;
        a.loops = n;
    }
    if let Some(v) = m.get("overshoot") {
        a.overshoot = match v {
            Value::Null => None,
            _ => Some(v.as_f64().filter(|n| (1.0..=3.0).contains(n)).ok_or("overshoot: a number 1...3 (1.08 = pop peaks at 108 %), null = the easing's own peak")?),
        };
    }
    if let Some(v) = m.get("cursor") {
        a.cursor = cursor(v, a)?;
    }
    Ok(())
}

const CURSOR_KEYS: [&str; 4] = ["char", "blink", "color", "holdAfter"];

/// `{char?, blink?, color?, holdAfter?}` on a typewriter; `null` removes the cursor. A given object starts from the
/// animator's current cursor (or the defaults), so a partial update keeps the other fields.
fn cursor(v: &Value, a: &TextAnimator) -> Result<Option<TextCursor>, String> {
    let Value::Object(m) = v else {
        return if v.is_null() { Ok(None) } else { Err("cursor: an object {char?, blink?, color?, holdAfter?} or null".into()) };
    };
    if a.effect != TextAnimatorEffect::Typewriter {
        return Err("cursor: only the typewriter effect has a cursor".into());
    }
    crate::edit_operation::check_strict_keys(m, &CURSOR_KEYS, "cursor")?;
    let mut c = a.cursor.clone().unwrap_or_else(TextCursor::standard);
    if let Some(g) = m.get("char") {
        let g = g.as_str().filter(|g| sq_core_time::text::graphemes(g).count() == 1);
        c.glyph = g.ok_or("cursor.char: one character, e.g. \"|\" or \"_\"")?.to_string();
    }
    if let Some(b) = m.get("blink") {
        c.blink = ms("cursor.blink", b)?.max(Time::new(1, 100));
    }
    if let Some(h) = m.get("holdAfter") {
        c.hold_after = ms("cursor.holdAfter", h)?;
    }
    if let Some(col) = m.get("color") {
        let hex = col.as_str().map(str::to_ascii_lowercase);
        c.color = match hex {
            Some(h) if h.len() == 7 && h.starts_with('#') && h[1..].chars().all(|c| c.is_ascii_hexdigit()) => Some(h),
            _ if col.is_null() => None,
            _ => return Err("cursor.color: \"#rrggbb\" (null = the text color)".into()),
        };
    }
    Ok(Some(c))
}

fn ms(key: &str, v: &Value) -> Result<Time, String> {
    Ok(Time::new(number(key, v, MAX_MS)?.round() as i64, 1000))
}

fn with_animations(
    layer: &mut GraphicsLayer,
    f: impl FnOnce(&mut AnimationSet) -> Result<(), String>,
) -> Result<(), String> {
    let GraphicsContent::Text { generator } = &layer.content else { return Err("the layer is not a text layer".into()) };
    let (template, animations) = TextGenerator::decode(generator).map_err(|e| format!("text layer: {e}"))?;
    let mut set = animations.unwrap_or_else(|| AnimationSet::new(None, None));
    f(&mut set)?;
    let animations = (set.animation_in.is_some() || set.animation_out.is_some()).then_some(set);
    let generator = TextGenerator::make_ref(&template, animations.as_ref()).map_err(|e| e.to_string())?;
    layer.content = GraphicsContent::Text { generator };
    Ok(())
}

/// Adds the animator of a side (`fresh`: refuses when the side has one) or changes the fields given.
pub fn apply(layer: &mut GraphicsLayer, spec: &Value, fresh: bool) -> Result<(), String> {
    check_spec(spec, fresh)?;
    let Value::Object(m) = spec else { return Ok(()) };
    let intro = parse_side(m.get("side"))?;
    let side = if intro { "in" } else { "out" };
    with_animations(layer, |set| {
        let cur = set.text_animator(intro).cloned();
        let mut a = match (cur, fresh) {
            (Some(_), true) => return Err(format!("the layer already has an {side} animator; use setTextAnimator")),
            (None, false) => return Err(format!("the layer has no {side} animator; use addTextAnimator")),
            (Some(a), false) => a,
            (None, true) => {
                let effect = m.get("effect").map(|v| name("effect", v, "fade, pop, slide, typewriter, blur, wave, pulse"));
                TextAnimator::starting(effect.ok_or("a new animator needs \"effect\"")??)
            }
        };
        patch(&mut a, m)?;
        set.set_text_animator(intro, Some(a));
        Ok(())
    })
}

/// Removes the animator of a side.
pub fn remove(layer: &mut GraphicsLayer, side: Option<&Value>) -> Result<(), String> {
    let intro = parse_side(side)?;
    with_animations(layer, |set| {
        if set.text_animator(intro).is_none() {
            return Err(format!("the layer has no {} animator", if intro { "in" } else { "out" }));
        }
        set.set_text_animator(intro, None);
        Ok(())
    })
}

/// One animator as the API reads it (times in milliseconds, like the request).
pub fn animator_json(a: &TextAnimator) -> Value {
    let ms = |t: Time| t.value() as f64 * 1000.0 / t.timescale() as f64;
    json!({"effect": a.effect, "unit": a.unit, "order": a.order, "easing": a.easing, "duration": ms(a.duration),
        "stagger": ms(a.stagger), "direction": a.direction, "distance": a.distance, "blur": a.blur_radius, "loops": a.loops,
        "overshoot": a.overshoot, "cursor": a.cursor.as_ref().map(|c| json!({"char": c.glyph, "blink": ms(c.blink),
            "color": c.color, "holdAfter": ms(c.hold_after)}))})
}

/// The animators of a text layer: `{in?: {...}, out?: {...}}`; `None` for a layer that is not text.
pub fn layer_animators(layer: &GraphicsLayer) -> Option<Map<String, Value>> {
    let GraphicsContent::Text { generator } = &layer.content else { return None };
    let (_, set) = TextGenerator::decode(generator).ok()?;
    let mut out = Map::new();
    if let Some(set) = set {
        for (key, intro) in [("in", true), ("out", false)] {
            if let Some(a) = set.text_animator(intro) {
                out.insert(key.into(), animator_json(a));
            }
        }
    }
    Some(out)
}

/// `GET /v1/textAnimators`: what the animator ops accept.
pub fn catalog_json() -> Value {
    json!({
        "sides": ["in", "out"],
        "effects": ["fade", "pop", "slide", "typewriter", "blur", "wave", "pulse"],
        "loopEffects": ["wave", "pulse"],
        "units": ["character", "word", "line"],
        "orders": ["forward", "reverse", "center"],
        "easings": ["linear", "easeIn", "easeOut", "easeInOut", "overshoot"],
        "directions": ["up", "down", "left", "right"],
        "fields": {"duration": "ms 0...60000 (one unit's animation)", "stagger": "ms 0...60000 (delay between units)",
            "distance": "px 0...2000 (slide)", "blur": "px 0...2000 (blur start)", "loops": "1...50 (wave, pulse)",
            "cursor": "typewriter only: {char: \"|\", blink: 530 (ms per half), color: \"#rrggbb\" (default: the text color), holdAfter: 600 (ms it stays after the last character)}; null removes it",
            "overshoot": "1...3 (pop peak scale, 1.08 = 108 %); null/absent = the easing's own peak (about 1.098)"},
        "defaults": {"unit": "word", "duration": 300, "stagger": 80, "order": "forward", "easing": "easeOut (pop: overshoot)",
            "direction": "up", "distance": 40, "blur": 12, "loops": 1},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cursor_is_checked_and_read_back() {
        let ok = |v: Value| check_spec(&v, true);
        assert!(ok(json!({"effect": "typewriter", "unit": "character", "cursor": {"char": "_", "blink": 400, "color": "#FF8800", "holdAfter": 900}})).is_ok());
        assert!(ok(json!({"effect": "typewriter", "cursor": {}})).is_ok());
        assert!(ok(json!({"effect": "typewriter", "cursor": null})).is_ok());
        for bad in [
            json!({"effect": "fade", "cursor": {}}),
            json!({"effect": "typewriter", "cursor": {"char": "ab"}}),
            json!({"effect": "typewriter", "cursor": {"color": "red"}}),
            json!({"effect": "typewriter", "cursor": {"blink": -1}}),
            json!({"effect": "typewriter", "cursor": {"speed": 1}}),
            json!({"effect": "typewriter", "cursor": 3}),
        ] {
            assert!(ok(bad.clone()).is_err(), "{bad}");
        }
        let mut a = TextAnimator::starting(TextAnimatorEffect::Typewriter);
        let Value::Object(m) = json!({"cursor": {"color": "#FF8800"}}) else { return };
        patch(&mut a, &m).unwrap_or_else(|e| panic!("{e}"));
        let j = animator_json(&a);
        assert_eq!(j["cursor"], json!({"char": "|", "blink": 530.0, "color": "#ff8800", "holdAfter": 600.0}));
        let Value::Object(m) = json!({"cursor": null}) else { return };
        patch(&mut a, &m).unwrap_or_else(|e| panic!("{e}"));
        assert!(animator_json(&a)["cursor"].is_null());
    }
}
