// SPDX-License-Identifier: GPL-3.0-or-later
//! Unknown keys at every level of a project file. A newer build may write keys this build has no field for; `diff` finds
//! them by comparing the file's JSON with what the typed model writes back for it, and `apply` puts them into the JSON of
//! a save by object identity (an element's `id`, else its position in an array of the same length). New model structs are
//! covered without a per-struct map; the maps that exist (`UnknownKeys`) stay and win where both hold a key.
//!
//! The tree is a sparse JSON value: `{"+": {key: raw value}, "/": {key or array identity: subtree}}`.

use serde_json::{Map, Value};

const ADD: &str = "+";
const INTO: &str = "/";

/// Identity of array element `i` of `len`: its `id`, else its position with the array length (a changed length means the
/// positions no longer match, so nothing is attached by position then).
fn identity(element: &Value, i: usize, len: usize) -> String {
    match element.get("id").and_then(Value::as_str) {
        Some(id) => format!("#id:{id}"),
        None => format!("#{i}/{len}"),
    }
}

/// What `file` has that `written` (the model's own encoding of the same project) lacks; `None` when nothing.
pub(crate) fn diff(file: &Value, written: &Value) -> Option<Value> {
    let mut add = Map::new();
    let mut into = Map::new();
    match (file, written) {
        (Value::Object(f), Value::Object(w)) => {
            for (k, v) in f {
                match w.get(k) {
                    None => {
                        add.insert(k.clone(), v.clone());
                    }
                    Some(wv) => {
                        if let Some(sub) = diff(v, wv) {
                            into.insert(k.clone(), sub);
                        }
                    }
                }
            }
        }
        (Value::Array(f), Value::Array(w)) => {
            for (i, v) in f.iter().enumerate() {
                let key = identity(v, i, f.len());
                let counterpart = match v.get("id").and_then(Value::as_str) {
                    Some(id) => w.iter().find(|x| x.get("id").and_then(Value::as_str) == Some(id)),
                    None if f.len() == w.len() => w.get(i),
                    None => None,
                };
                if let Some(sub) = counterpart.and_then(|c| diff(v, c)) {
                    into.insert(key, sub);
                }
            }
        }
        _ => {}
    }
    if add.is_empty() && into.is_empty() {
        return None;
    }
    let mut node = Map::new();
    if !add.is_empty() {
        node.insert(ADD.into(), Value::Object(add));
    }
    if !into.is_empty() {
        node.insert(INTO.into(), Value::Object(into));
    }
    Some(Value::Object(node))
}

/// Puts the extras into `out` (a key `out` already has is never replaced).
pub(crate) fn apply(out: &mut Value, extras: &Value) {
    if let (Value::Object(o), Some(Value::Object(add))) = (&mut *out, extras.get(ADD)) {
        for (k, v) in add {
            o.entry(k.clone()).or_insert_with(|| v.clone());
        }
    }
    let Some(Value::Object(into)) = extras.get(INTO) else { return };
    match out {
        Value::Object(o) => {
            for (k, sub) in into {
                if let Some(child) = o.get_mut(k) {
                    apply(child, sub);
                }
            }
        }
        Value::Array(a) => {
            let len = a.len();
            for (i, element) in a.iter_mut().enumerate() {
                if let Some(sub) = into.get(&identity(element, i, len)) {
                    apply(element, sub);
                }
            }
        }
        _ => {}
    }
}
