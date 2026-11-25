//! `addMask`: a rectangle or ellipse mask on a clip, through the same `add_shape_mask_path` the Mask tool uses.

use serde_json::{Map, Value, json};
use sq_core_masks::{ClipMasksExt, MaskInputsExt};
use sq_core_model::{Clip, MaskPath, MaskShapeKind};
use sq_core_time::{IdSource, Vec2};

/// Keys of `addMask` besides `op` and `clip`.
pub const KEYS: [&str; 6] = ["shape", "center", "size", "feather", "invert", "name"];

/// Largest feather (px of the clip's own frame).
const MAX_FEATHER: f64 = 4000.0;

fn pair(v: &Value, what: &str) -> Result<Vec2, String> {
    let bad = || format!("addMask: {what} is {{x,y}} or [x,y] as fractions of the frame (0...1)");
    let num = |x: &Value| x.as_f64().filter(|n| n.is_finite()).ok_or_else(bad);
    match v {
        Value::Array(a) if a.len() == 2 => Ok(Vec2::new(num(&a[0])?, num(&a[1])?)),
        Value::Object(o) => Ok(Vec2::new(num(o.get("x").ok_or_else(bad)?)?, num(o.get("y").ok_or_else(bad)?)?)),
        _ => Err(bad()),
    }
}

/// Checks the fields (run when the request is decoded).
pub fn check_spec(m: &Map<String, Value>) -> Result<(), String> {
    parse(m).map(|_| ())
}

/// The decoded request.
pub struct Spec {
    kind: MaskShapeKind,
    path: MaskPath,
    feather: Option<f64>,
    invert: bool,
    name: Option<String>,
}

fn parse(m: &Map<String, Value>) -> Result<Spec, String> {
    crate::edit_operation::check_strict_keys(m, &KEYS, "addMask")?;
    let kind = match m.get("shape").and_then(Value::as_str) {
        Some("ellipse") => MaskShapeKind::Ellipse,
        Some("rectangle") => MaskShapeKind::Rectangle,
        _ => return Err("addMask: shape is \"ellipse\" or \"rectangle\"".into()),
    };
    let center = m.get("center").map_or(Ok(Vec2::new(0.5, 0.5)), |v| pair(v, "center"))?;
    let size = m.get("size").map_or(Ok(Vec2::new(0.5, 0.5)), |v| pair(v, "size"))?;
    if !(0.0..=1.0).contains(&center.x) || !(0.0..=1.0).contains(&center.y) {
        return Err("addMask: center is inside the frame (0...1)".into());
    }
    if size.x <= 0.0 || size.y <= 0.0 || size.x > 4.0 || size.y > 4.0 {
        return Err("addMask: size is above 0 and at most 4 (fractions of the frame)".into());
    }
    let feather = match m.get("feather") {
        None => None,
        Some(v) => Some(v.as_f64().filter(|f| (0.0..=MAX_FEATHER).contains(f)).ok_or("addMask: feather is 0...4000 px")?),
    };
    let invert = match m.get("invert") {
        None => false,
        Some(v) => v.as_bool().ok_or("addMask: invert is true or false")?,
    };
    let name = match m.get("name") {
        None => None,
        Some(v) => Some(v.as_str().ok_or("addMask: name is a string")?.to_string()),
    };
    let (half, c) = (Vec2::new(size.x / 2.0, size.y / 2.0), center);
    let path = if kind == MaskShapeKind::Ellipse {
        MaskPath::ellipse(c, half)
    } else {
        MaskPath::rectangle(Vec2::new(c.x - half.x, c.y - half.y), Vec2::new(c.x + half.x, c.y + half.y))
    };
    Ok(Spec { kind, path, feather, invert, name })
}

/// Adds the mask to the clip.
pub fn apply(c: &mut Clip, fields: &Map<String, Value>, ids: &mut dyn IdSource) -> Result<(), String> {
    let spec = parse(fields)?;
    let id = c.add_shape_mask_path(spec.kind, spec.path, ids);
    let mut masks = c.masks().to_vec();
    if let Some(m) = masks.iter_mut().find(|m| m.id == id) {
        if let Some(f) = spec.feather {
            m.feather.value = f;
        }
        m.inverted = spec.invert;
        if let Some(n) = spec.name {
            m.name = n;
        }
    }
    c.set_masks(masks);
    Ok(())
}

/// The masks of a clip for the read-back.
pub fn read_back(c: &Clip) -> Vec<Value> {
    c.masks()
        .iter()
        .map(|m| {
            let (mut lo, mut hi) = (Vec2::new(f64::MAX, f64::MAX), Vec2::new(f64::MIN, f64::MIN));
            for v in &m.path.value.polygon() {
                lo = Vec2::new(lo.x.min(v.x), lo.y.min(v.y));
                hi = Vec2::new(hi.x.max(v.x), hi.y.max(v.y));
            }
            json!({"id": m.id, "name": m.name, "shape": m.kind, "invert": m.inverted, "feather": m.feather.value,
                "center": {"x": (lo.x + hi.x) / 2.0, "y": (lo.y + hi.y) / 2.0}, "size": {"x": hi.x - lo.x, "y": hi.y - lo.y}})
        })
        .collect()
}
