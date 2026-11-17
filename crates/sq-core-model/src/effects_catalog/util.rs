// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectsCatalog.swift (spec builders)

use crate::{EffectParamSpec, EffectSpec};

/// A slider row: key, title, unit, default, range ends, step, decimals.
#[allow(clippy::too_many_arguments)]
pub(super) fn p(
    key: &str,
    title: &str,
    unit: &str,
    default: f64,
    lo: f64,
    hi: f64,
    step: f64,
    decimals: i64,
) -> EffectParamSpec {
    EffectParamSpec::new(key, title, unit, default, lo..=hi, step, decimals)
}

/// An effect without linked pairs.
pub(super) fn spec(kind: &str, title: &str, params: Vec<EffectParamSpec>) -> EffectSpec {
    EffectSpec { kind: kind.to_string(), title: title.to_string(), params, pairs: Vec::new() }
}
