//! A static accent on words of a text layer (`setTextAccent`): the text model's karaoke highlight range (`TextHighlight`) held
//! still, so the layer renders the accent words in another fill color exactly like a lit karaoke word.

use crate::clip_params::parse_rgba;
use serde_json::{Map, Value, json};
use sq_core_model::{GraphicsContent, GraphicsLayer};
use sq_text::caption_karaoke::TextHighlight;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::RGBAColor;

/// Keys of `setTextAccent` besides `op`, `clip` and `layer`.
pub const KEYS: [&str; 4] = ["from", "to", "color", "clear"];

/// Words of a text: whitespace separated, in reading order (the count `TextHighlight.words` indexes).
pub fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

/// Checks the shape of the fields without touching a model.
pub fn check_spec(m: &Map<String, Value>) -> Result<(), String> {
    crate::edit_operation::check_strict_keys(m, &KEYS, "setTextAccent")?;
    if m.get("clear").is_some_and(|c| c.as_bool() == Some(true)) {
        return if m.len() == 1 { Ok(()) } else { Err("setTextAccent: clear takes no other field".into()) };
    }
    if m.contains_key("clear") {
        return Err("setTextAccent: clear is true (or leave it out and give from, to?, color)".into());
    }
    let idx = |k: &str| match m.get(k) {
        None => Ok(None),
        Some(v) => v.as_u64().map(Some).ok_or_else(|| format!("setTextAccent: {k} is a word index (0, 1, 2 ...)")),
    };
    let from = idx("from")?.ok_or("setTextAccent: from (first accent word index) is required")?;
    if let Some(to) = idx("to")?
        && to <= from
    {
        return Err("setTextAccent: to is the index after the last accent word, so it must be above from".into());
    }
    parse_rgba(m.get("color").ok_or("setTextAccent: color (#rrggbb) is required")?).map(|_| ())
}

/// Applies the accent (or clears it) on a text layer.
pub fn apply(layer: &mut GraphicsLayer, m: &Map<String, Value>) -> Result<(), String> {
    check_spec(m)?;
    let GraphicsContent::Text { generator } = &layer.content else {
        return Err("the layer is not a text layer".into());
    };
    let (mut template, animations) = TextGenerator::decode(generator).map_err(|e| format!("text layer: {e}"))?;
    if m.contains_key("clear") {
        template.highlight = None;
    } else {
        let from = m.get("from").and_then(Value::as_u64).unwrap_or(0) as usize;
        let to = m.get("to").and_then(Value::as_u64).map_or(from + 1, |t| t as usize);
        let words = word_count(&template.text);
        if to > words {
            return Err(format!(
                "setTextAccent: the text has {words} words (indexes 0...{}); to is at most {words}",
                words.saturating_sub(1)
            ));
        }
        let [r, g, b, a] = parse_rgba(m.get("color").unwrap_or(&Value::Null))?;
        template.highlight = Some(TextHighlight::new(from..to, RGBAColor::new(r, g, b, a)));
    }
    let generator = TextGenerator::make_ref(&template, animations.as_ref()).map_err(|e| e.to_string())?;
    layer.content = GraphicsContent::Text { generator };
    Ok(())
}

/// The accent of a text layer for the read-back: `{from, to, color}` or `None`.
pub fn read_back(layer: &GraphicsLayer) -> Option<Value> {
    let GraphicsContent::Text { generator } = &layer.content else { return None };
    let (template, _) = TextGenerator::decode(generator).ok()?;
    let h = template.highlight?;
    if h.words.is_empty() {
        return None;
    }
    let c = h.color;
    Some(
        json!({"from": h.words.start, "to": h.words.end, "color": {"red": c.red, "green": c.green, "blue": c.blue, "alpha": c.alpha}}),
    )
}
