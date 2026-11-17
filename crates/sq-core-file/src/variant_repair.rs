// SPDX-License-Identifier: GPL-3.0-or-later

//! Unknown enum values never cost data: a value a newer build wrote ("pink" as a marker color) is read as the nearest known
//! value and listed in the salvage report, instead of dropping the clip or sequence that holds it.

use serde::de::DeserializeOwned;
use serde_json::Value;

/// How many values one item may have read as a near match before the repair gives up.
const MAX_REPAIRS: usize = 64;

/// The unknown value and the known ones out of a serde message ("unknown variant `pink`, expected one of `a`, `b` at line..").
fn parse_message(message: &str) -> Option<(String, Vec<String>)> {
    let rest = message.strip_prefix("unknown variant `")?;
    let (unknown, rest) = rest.split_once('`')?;
    let rest = rest.strip_prefix(", expected ")?;
    let rest = rest.strip_prefix("one of ").unwrap_or(rest);
    let list = rest.split(" at line ").next()?;
    let known: Vec<String> =
        list.split('`').enumerate().filter(|(i, _)| i % 2 == 1).map(|(_, s)| s.to_string()).collect();
    (!known.is_empty()).then(|| (unknown.to_string(), known))
}

fn edit_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.to_lowercase().chars().collect();
    let b: Vec<char> = b.to_lowercase().chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut prev = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cur = row[j + 1];
            row[j + 1] = (prev + usize::from(ca != cb)).min(row[j] + 1).min(cur + 1);
            prev = cur;
        }
    }
    row[b.len()]
}

/// The known value nearest to `unknown`; the first listed (the type's own first case) wins a tie.
pub(crate) fn nearest<'k>(unknown: &str, known: &'k [String]) -> &'k str {
    known.iter().min_by_key(|k| edit_distance(unknown, k)).map_or("", String::as_str)
}

/// Whether `v` reads as a `T`. An unknown enum value inside it is replaced in `v` by the nearest known value and noted in
/// `notes`, one line each. `false` when `v` still does not read as a `T` (the caller drops or reports that part).
pub(crate) fn reads_as<T: DeserializeOwned>(v: &mut Value, notes: &mut Vec<String>) -> bool {
    if T::deserialize(&*v).is_ok() {
        return true;
    }
    let Ok(mut text) = serde_json::to_string(v) else { return false };
    let mut found = Vec::new();
    for _ in 0..MAX_REPAIRS {
        let Err(error) = serde_json::from_str::<T>(&text) else { break };
        let Some((unknown, known)) = parse_message(&error.to_string()) else { return false };
        let replacement = nearest(&unknown, &known).to_string();
        let quoted = format!("\"{unknown}\"");
        // The error points just after the value; the nearest quoted copy at or before that spot is the one.
        let end = error.column().saturating_sub(1).saturating_add(1).min(text.len());
        let Some(at) = text.get(..end).and_then(|head| head.rfind(&quoted)) else { return false };
        text.replace_range(at..at + quoted.len(), &format!("\"{replacement}\""));
        found.push(format!("Unknown value “{unknown}” was read as “{replacement}”"));
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(fixed) if T::deserialize(&fixed).is_ok() => {
            *v = fixed;
            notes.extend(found);
            true
        }
        _ => false,
    }
}
