//! Multi-select editing: the value all selected clips share, matching effects across clips, field-by-field style carry.
// Swift: MultiClipEdit.swift

use std::collections::BTreeSet;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde::ser::Error as _;
use serde_json::{Map, Value};
use sq_core_model::Clip;
use sq_core_time::Id;

/// Multi-select editing (Effect Controls / Text with several clips selected, Premiere): every field shows the value all
/// selected clips share, or nothing when they differ; an edit sets that one value on all of them.
pub struct MultiValue;

impl MultiValue {
    /// The value every element shares; None when they differ or there is none.
    pub fn common<V: PartialEq>(values: impl IntoIterator<Item = V>) -> Option<V> {
        let mut it = values.into_iter();
        let first = it.next()?;
        for v in it {
            if v != first {
                return None;
            }
        }
        Some(first)
    }
}

/// Swift `Clip.matchingEffectID(for:in:)`.
pub trait MatchingEffectExt {
    /// The effect on this clip that corresponds to `id` on `source`: the same kind at the same occurrence (the second
    /// Blur matches the second Blur). None when this clip has fewer effects of that kind.
    fn matching_effect_id(&self, id: Id, source: &Clip) -> Option<Id>;
}

impl MatchingEffectExt for Clip {
    fn matching_effect_id(&self, id: Id, source: &Clip) -> Option<Id> {
        let e = source.effects.iter().find(|e| e.id == id)?;
        let n = source.effects.iter().take_while(|x| x.id != id).filter(|x| x.kind == e.kind).count();
        self.effects.iter().filter(|x| x.kind == e.kind).nth(n).map(|x| x.id)
    }
}

/// Carries one edit of a Codable value (a text style) to other values field by field, through its JSON form: only the
/// fields the edit changed are written, everything else keeps the other value's own setting. Objects merge per key,
/// arrays and scalars are replaced whole; a group switched on or off (an optional present / absent) is switched the same.
pub struct CodableMerge;

impl CodableMerge {
    /// `peer` with every field that differs between `old` and `new` set to `new`'s.
    /// `forcing`: dotted paths ("style.size", "style.shadow") copied from `new` even when the edit left them unchanged — a
    /// mixed field set to the shown item's own value. A whole group is copied or removed; a field inside a group the peer
    /// does not have is skipped.
    pub fn carry<T: Serialize + DeserializeOwned>(
        old: &T,
        new: &T,
        peer: &T,
        forcing: &BTreeSet<String>,
    ) -> Result<T, serde_json::Error> {
        let (o, n) = (object(old)?, object(new)?);
        if json_eq(&Value::Object(o.clone()), &Value::Object(n.clone())) && forcing.is_empty() {
            return serde_json::from_value(object_value(peer)?);
        }
        let mut merged = merge(&o, &n, &object(peer)?);
        for path in forcing {
            let keys: Vec<&str> = path.split('.').collect();
            force(&keys, &n, &mut merged);
        }
        serde_json::from_value(Value::Object(merged))
    }

    /// Dotted paths of the fields that are not the same in all `values`: a leaf ("shadow.blur") or, when a group is on in
    /// some and off in others, the group ("shadow").
    pub fn differing_paths<T: Serialize>(values: &[T]) -> Result<BTreeSet<String>, serde_json::Error> {
        let mut out = BTreeSet::new();
        if values.len() > 1 {
            let objects = values.iter().map(object).collect::<Result<Vec<_>, _>>()?;
            collect(&objects.iter().collect::<Vec<_>>(), "", &mut out);
        }
        Ok(out)
    }
}

fn object<T: Serialize>(v: &T) -> Result<Map<String, Value>, serde_json::Error> {
    match serde_json::to_value(v)? {
        Value::Object(d) => Ok(d),
        _ => Err(serde_json::Error::custom("value does not encode as an object")),
    }
}

fn object_value<T: Serialize>(v: &T) -> Result<Value, serde_json::Error> {
    object(v).map(Value::Object)
}

/// Foundation's equality of JSON values: numbers compare by value whatever their text form.
fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| json_eq(p, q)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| json_eq(v, w)))
        }
        _ => a == b,
    }
}

fn same(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => json_eq(x, y),
        _ => false,
    }
}

fn force(keys: &[&str], new: &Map<String, Value>, out: &mut Map<String, Value>) {
    let Some(&key) = keys.first() else { return };
    if keys.len() == 1 {
        match new.get(key) {
            Some(v) => out.insert(key.to_string(), v.clone()),
            None => out.remove(key),
        };
        return;
    }
    let (Some(Value::Object(n)), Some(Value::Object(o))) = (new.get(key), out.get_mut(key)) else { return };
    force(&keys[1..], n, o);
}

fn merge(old: &Map<String, Value>, new: &Map<String, Value>, peer: &Map<String, Value>) -> Map<String, Value> {
    let mut out = peer.clone();
    let keys: BTreeSet<&String> = old.keys().chain(new.keys()).collect();
    for key in keys {
        let (o, n) = (old.get(key), new.get(key));
        if same(o, n) {
            continue;
        }
        if let (Some(Value::Object(od)), Some(Value::Object(nd))) = (o, n) {
            // A field inside a group: merge into the peer's group, or take the whole group when the peer has none.
            let merged = match peer.get(key) {
                Some(Value::Object(p)) => merge(od, nd, p),
                _ => nd.clone(),
            };
            out.insert(key.clone(), Value::Object(merged));
        } else {
            match n {
                Some(v) => out.insert(key.clone(), v.clone()),
                None => out.remove(key),
            };
        }
    }
    out
}

fn collect(objects: &[&Map<String, Value>], prefix: &str, out: &mut BTreeSet<String>) {
    let keys: BTreeSet<&String> = objects.iter().flat_map(|o| o.keys()).collect();
    for key in keys {
        let path = if prefix.is_empty() { key.clone() } else { format!("{prefix}.{key}") };
        let vals: Vec<Option<&Value>> = objects.iter().map(|o| o.get(key)).collect();
        if vals.iter().all(Option::is_none) {
            continue;
        }
        if vals.iter().any(Option::is_none) {
            out.insert(path);
            continue;
        }
        let dicts: Vec<&Map<String, Value>> = vals.iter().filter_map(|v| v.and_then(Value::as_object)).collect();
        if dicts.len() == vals.len() {
            collect(&dicts, &path, out);
            continue;
        }
        if vals[1..].iter().any(|v| !same(*v, vals[0])) {
            out.insert(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use sq_core_model::{ClipEffect, TrackKind};
    use sq_core_time::{Time, TimeRange};

    #[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
    struct Shadow {
        blur: f64,
        opacity: f64,
    }
    #[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
    struct Style {
        size: f64,
        font: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        shadow: Option<Shadow>,
        #[serde(default)]
        tags: Vec<String>,
    }

    fn style(size: f64, font: &str, shadow: Option<(f64, f64)>) -> Style {
        Style {
            size,
            font: font.to_string(),
            shadow: shadow.map(|(blur, opacity)| Shadow { blur, opacity }),
            tags: vec![],
        }
    }
    fn shadow(blur: f64, opacity: f64) -> Option<Shadow> {
        Some(Shadow { blur, opacity })
    }
    fn carry(old: &Style, new: &Style, peer: &Style) -> Style {
        CodableMerge::carry(old, new, peer, &BTreeSet::new()).unwrap()
    }
    fn forced(old: &Style, new: &Style, peer: &Style, paths: &[&str]) -> Style {
        CodableMerge::carry(old, new, peer, &paths.iter().map(|p| p.to_string()).collect()).unwrap()
    }

    #[test]
    fn common_value_is_the_shared_one_or_none() {
        assert_eq!(MultiValue::common([2.0, 2.0, 2.0]), Some(2.0));
        assert_eq!(MultiValue::common([2.0, 3.0]), None);
        assert_eq!(MultiValue::common(Vec::<f64>::new()), None);
        assert_eq!(MultiValue::common(["a"]), Some("a"));
    }

    fn clip(ids: &mut sq_core_time::SequentialIds, kinds: &[&str]) -> Clip {
        use sq_core_time::IdSource;
        let mut c = Clip::new(
            ids.next_id(),
            "c",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::ZERO,
        );
        c.effects = kinds.iter().map(|k| ClipEffect::new(ids.next_id(), k)).collect();
        c
    }

    #[test]
    fn effects_match_by_kind_and_occurrence() {
        let mut ids = sq_core_time::SequentialIds::default();
        let a = clip(&mut ids, &["blur", "crop", "blur"]);
        let b = clip(&mut ids, &["crop", "blur", "tint", "blur"]);
        assert_eq!(b.matching_effect_id(a.effects[0].id, &a), Some(b.effects[1].id));
        assert_eq!(b.matching_effect_id(a.effects[2].id, &a), Some(b.effects[3].id));
        assert_eq!(b.matching_effect_id(a.effects[1].id, &a), Some(b.effects[0].id));
        let c = clip(&mut ids, &["blur"]);
        assert_eq!(c.matching_effect_id(a.effects[2].id, &a), None);
        assert_eq!(c.matching_effect_id(Id::from_u128(7777), &a), None);
    }

    #[test]
    fn carry_changes_only_the_edited_field() {
        let old = style(40.0, "A", Some((2.0, 0.5)));
        let mut new = old.clone();
        new.size = 60.0;
        assert_eq!(carry(&old, &new, &style(20.0, "B", None)), style(60.0, "B", None));
    }

    #[test]
    fn carry_nested_field_keeps_peer_siblings() {
        let old = style(40.0, "A", Some((2.0, 0.5)));
        let mut new = old.clone();
        new.shadow = shadow(9.0, 0.5);
        assert_eq!(carry(&old, &new, &style(20.0, "B", Some((1.0, 0.9)))).shadow, shadow(9.0, 0.9));
        // A peer without the group takes the whole group.
        assert_eq!(carry(&old, &new, &style(20.0, "B", None)).shadow, shadow(9.0, 0.5));
    }

    #[test]
    fn carry_switching_a_group_off_and_on() {
        let on = style(40.0, "A", Some((2.0, 0.5)));
        let mut off = on.clone();
        off.shadow = None;
        assert_eq!(carry(&on, &off, &style(20.0, "B", Some((7.0, 0.1)))).shadow, None);
        assert_eq!(carry(&off, &on, &style(20.0, "B", None)).shadow, shadow(2.0, 0.5));
    }

    #[test]
    fn carry_replaces_arrays_whole() {
        let mut old = style(1.0, "A", None);
        old.tags = vec!["x".into()];
        let mut new = old.clone();
        new.tags = vec!["x".into(), "y".into()];
        let mut peer = style(2.0, "B", None);
        peer.tags = vec!["z".into()];
        assert_eq!(carry(&old, &new, &peer).tags, ["x", "y"]);
    }

    #[test]
    fn no_change_leaves_peer_alone() {
        let s = style(1.0, "A", None);
        let peer = style(2.0, "B", Some((1.0, 1.0)));
        assert_eq!(carry(&s, &s, &peer), peer);
    }

    #[test]
    fn differing_paths_list_leaves_and_presence() {
        let a = style(40.0, "A", Some((2.0, 0.5)));
        let b = style(40.0, "B", Some((3.0, 0.5)));
        let c = style(40.0, "A", None);
        let set = |xs: &[&str]| xs.iter().map(|x| x.to_string()).collect::<BTreeSet<_>>();
        assert_eq!(CodableMerge::differing_paths(&[a.clone(), b]).unwrap(), set(&["font", "shadow.blur"]));
        assert_eq!(CodableMerge::differing_paths(&[a.clone(), c]).unwrap(), set(&["shadow"]));
        assert!(CodableMerge::differing_paths(&[a.clone(), a.clone()]).unwrap().is_empty());
        assert!(CodableMerge::differing_paths(&[a]).unwrap().is_empty());
    }

    #[test]
    fn forced_field_is_copied_even_when_unchanged() {
        let s = style(40.0, "A", None);
        assert_eq!(forced(&s, &s, &style(20.0, "B", None), &["size"]), style(40.0, "B", None));
    }

    #[test]
    fn forced_group_is_copied_whole_or_removed() {
        let on = style(1.0, "A", Some((2.0, 0.5)));
        assert_eq!(forced(&on, &on, &style(2.0, "B", None), &["shadow"]).shadow, shadow(2.0, 0.5));
        let mut off = on.clone();
        off.shadow = None;
        assert_eq!(forced(&off, &off, &style(2.0, "B", Some((7.0, 1.0))), &["shadow"]).shadow, None);
    }

    #[test]
    fn forced_nested_field_keeps_peer_siblings() {
        let s = style(1.0, "A", Some((2.0, 0.5)));
        let peer = style(2.0, "B", Some((9.0, 0.1)));
        assert_eq!(forced(&s, &s, &peer, &["shadow.blur"]).shadow, shadow(2.0, 0.1));
        let bare = style(2.0, "B", None);
        assert_eq!(forced(&s, &s, &bare, &["shadow.blur"]), bare);
    }
}
