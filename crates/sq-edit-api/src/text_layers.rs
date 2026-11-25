//! Text layers of a graphics clip from JSON: the same `GraphicsLayer::text` + `TextGenerator` payload the Graphics panel and
//! the Premiere import make, so a layer made here renders and animates like any other.

use crate::clip_params::{Addr, Anim, Host, parse_rgba};
use serde_json::{Map, Value, json};
use sq_core_model::{GraphicsContent, GraphicsLayer};
use sq_core_time::{IdSource, Time};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;
use sq_text::text_template::TextTemplate;

/// The fields of one text layer.
pub const LAYER_KEYS: [&str; 16] = [
    "name", "text", "font", "size", "color", "weight", "align", "position", "scale", "rotation", "opacity", "italic",
    "tracking", "lineSpacing", "allCaps", "style",
];

/// Layers one `addGraphic` may carry.
pub const MAX_LAYERS: usize = 50;

/// Checks the shape of a layer description without touching a model (run when the request is decoded).
pub fn check_spec(v: &Value) -> Result<(), String> {
    let Value::Object(m) = v else { return Err("a layer is an object {text, font?, size?, color?, ...}".into()) };
    crate::edit_operation::check_strict_keys(m, &LAYER_KEYS, "text layer")
}

fn weight(v: &Value) -> Result<i64, String> {
    if let Some(n) = v.as_i64() {
        return Ok(n);
    }
    let names = [
        ("thin", 100),
        ("light", 300),
        ("regular", 400),
        ("medium", 500),
        ("semibold", 600),
        ("bold", 700),
        ("heavy", 800),
        ("black", 900),
    ];
    let s = v.as_str().ok_or("weight: a number (100...900) or a name")?;
    names
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(s))
        .map(|(_, w)| *w)
        .ok_or_else(|| format!("weight: unknown '{s}'; known: thin, light, regular, medium, semibold, bold, heavy, black"))
}

/// Applies `spec` to `layer`. A new layer (`fresh`) must say its text. Position, scale, rotation and opacity are the layer's
/// static Motion values (use setKeyframe on `layer.<id>.motion.position` etc. to animate).
pub fn apply(layer: &mut GraphicsLayer, spec: &Value, fresh: bool, duration: Time) -> Result<(), String> {
    check_spec(spec)?;
    let Value::Object(m) = spec else { return Ok(()) };
    let (mut template, animations) = match &layer.content {
        GraphicsContent::Text { generator } if !fresh => {
            TextGenerator::decode(generator).map_err(|e| format!("text layer: {e}"))?
        }
        _ => {
            let text = m.get("text").and_then(Value::as_str).ok_or("a new text layer needs \"text\"")?;
            (TextTemplate::new("Text", text, TextStyle::default()), None)
        }
    };
    if let Some(t) = m.get("text") {
        template.text = t.as_str().ok_or("text must be a string")?.to_string();
    }
    let mut style = serde_json::to_value(&template.style).map_err(|e| e.to_string())?;
    let Value::Object(sm) = &mut style else { return Err("style is not an object".into()) };
    let mut put = |k: &str, v: Value| {
        sm.insert(k.into(), v);
    };
    if let Some(v) = m.get("font") {
        put("fontName", v.clone());
    }
    if let Some(v) = m.get("size") {
        put("size", v.clone());
    }
    if let Some(v) = m.get("color") {
        let [red, green, blue, alpha] = parse_rgba(v)?;
        put("color", json!({"red": red, "green": green, "blue": blue, "alpha": alpha}));
    }
    if let Some(v) = m.get("weight") {
        put("weight", json!(weight(v)?));
    }
    if let Some(v) = m.get("align") {
        put("alignment", v.clone());
    }
    for (from, to) in [("italic", "italic"), ("tracking", "tracking"), ("lineSpacing", "lineSpacing"), ("allCaps", "allCaps")]
    {
        if let Some(v) = m.get(from) {
            put(to, v.clone());
        }
    }
    if let Some(Value::Object(raw)) = m.get("style") {
        for (k, v) in raw {
            put(k, v.clone());
        }
    } else if m.contains_key("style") {
        return Err("style must be an object of TextStyle fields (see GET /v1/clip/<id>/params)".into());
    }
    template.style = serde_json::from_value(style).map_err(|e| format!("text style: {e}"))?;
    let generator = TextGenerator::make_ref(&template, animations.as_ref()).map_err(|e| e.to_string())?;
    layer.content = GraphicsContent::Text { generator };
    if let Some(n) = m.get("name") {
        layer.name = n.as_str().ok_or("name must be a string")?.to_string();
    }
    let mut host = Host::of_layer(layer, duration);
    for (key, anim) in [("position", Anim::Position), ("scale", Anim::Scale), ("rotation", Anim::Rotation), ("opacity", Anim::Opacity)]
    {
        if let Some(v) = m.get(key) {
            host.set(&Addr::Anim(anim), v)?;
        }
    }
    Ok(())
}

/// A new text layer; `fallback_name` names it when the spec does not.
pub fn new_layer(spec: &Value, fallback_name: &str, ids: &mut dyn IdSource, duration: Time) -> Result<GraphicsLayer, String> {
    check_spec(spec)?;
    let blank = TextGenerator::make_ref(&TextTemplate::new("Text", "", TextStyle::default()), None).map_err(|e| e.to_string())?;
    let mut l = GraphicsLayer::text(ids.next_id(), blank, fallback_name);
    apply(&mut l, spec, true, duration)?;
    Ok(l)
}

/// The fields of a `setTextLayer` / `addTextLayer` request body (everything but the op's own keys).
pub fn spec_from(map: &Map<String, Value>, own: &[&str]) -> Value {
    Value::Object(map.iter().filter(|(k, _)| !own.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect())
}
