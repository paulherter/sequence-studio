// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Look.swift
//! A Look: a named, saved appearance, and the Look library.

use crate::caption_pill::CaptionPill;
use crate::caption_presets::{CaptionLook, CaptionLookError};
use crate::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextShadow, TextStroke, TextStyle,
};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_model::anchored_animation::KeyframeTemplate;
use sq_core_model::{KaraokeStyle, StyleKit, StyleKitLook, trim_spaces};
use sq_core_time::IdSource;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::LazyLock;

/// The animation as the Look compares it: "no animation" reads the same whether stored as nil or as the empty template.
fn normalized(a: Option<&KeyframeTemplate>) -> Option<&KeyframeTemplate> {
    a.filter(|t| **t != KeyframeTemplate::none())
}

/// A Look: a named, saved appearance. One type for captions, text clips and graphic text items.
/// It never stores text content. `style` is always there; the rest is optional and only applied where it means something:
/// `animation` (nil = applying the Look leaves the item's animation alone), `karaoke` (the word highlight of caption
/// tracks) and `caption_segmentation` (how Create Captions splits lines; opaque JSON of the transcribe preset, which this
/// module does not know).
#[derive(Clone, Debug, PartialEq)]
pub struct Look {
    /// Identity.
    pub id: String,
    /// Shown name.
    pub name: String,
    /// The text style.
    pub style: TextStyle,
    /// The animation.
    pub animation: Option<KeyframeTemplate>,
    /// The word highlight of caption tracks.
    pub karaoke: Option<KaraokeStyle>,
    /// How Create Captions splits lines.
    pub caption_segmentation: Option<Vec<u8>>,
    /// Shipped with the app: read-only, never persisted.
    pub is_built_in: bool,
    /// Optional group of the Look strip's filter ("Bold", "Clean"). Lives in the Look store file only (an optional key old
    /// builds ignore); the project's kit payload does not carry it, so a project Look has none.
    pub category: Option<String>,
}

/// What the Look looks like, without its id and name. Two Looks with equal values are the same Look twice.
#[derive(Clone, Debug, PartialEq)]
pub struct LookValues {
    /// The text style.
    pub style: TextStyle,
    /// The animation.
    pub animation: Option<KeyframeTemplate>,
    /// The word highlight.
    pub karaoke: Option<KaraokeStyle>,
    /// How Create Captions splits lines.
    pub caption_segmentation: Option<Vec<u8>>,
}

impl LookValues {
    /// Values with a style only.
    pub fn new(style: TextStyle) -> LookValues {
        LookValues { style, animation: None, karaoke: None, caption_segmentation: None }
    }
}

/// Why a Look could not be stored or read.
#[derive(Clone, Debug, PartialEq)]
pub enum LookError {
    /// Written by a newer build.
    NewerVersion,
    /// The JSON does not encode or decode.
    Malformed,
}

impl std::fmt::Display for LookError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LookError::NewerVersion => write!(f, "newer version"),
            LookError::Malformed => write!(f, "malformed Look"),
        }
    }
}

impl std::error::Error for LookError {}

impl From<CaptionLookError> for LookError {
    fn from(e: CaptionLookError) -> LookError {
        match e {
            CaptionLookError::NewerVersion => LookError::NewerVersion,
            CaptionLookError::Malformed => LookError::Malformed,
        }
    }
}

impl From<serde_json::Error> for LookError {
    fn from(_: serde_json::Error) -> LookError {
        LookError::Malformed
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LookWire<'a> {
    id: &'a str,
    name: &'a str,
    style: &'a TextStyle,
    #[serde(skip_serializing_if = "Option::is_none")]
    animation: &'a Option<KeyframeTemplate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    karaoke: &'a Option<KaraokeStyle>,
    #[serde(with = "sq_core_time::base64::option", skip_serializing_if = "Option::is_none")]
    caption_segmentation: &'a Option<Vec<u8>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: &'a Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookRead {
    id: String,
    name: String,
    style: TextStyle,
    #[serde(default)]
    animation: Option<KeyframeTemplate>,
    #[serde(default)]
    karaoke: Option<KaraokeStyle>,
    #[serde(default, with = "sq_core_time::base64::option")]
    caption_segmentation: Option<Vec<u8>>,
    #[serde(default)]
    category: Option<String>,
}

impl Serialize for Look {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        LookWire {
            id: &self.id,
            name: &self.name,
            style: &self.style,
            animation: &self.animation,
            karaoke: &self.karaoke,
            caption_segmentation: &self.caption_segmentation,
            category: &self.category,
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for Look {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Look, D::Error> {
        let r = LookRead::deserialize(d)?;
        Ok(Look {
            id: r.id,
            name: r.name,
            style: r.style,
            animation: r.animation,
            karaoke: r.karaoke,
            caption_segmentation: r.caption_segmentation,
            is_built_in: false,
            category: r.category,
        })
    }
}

/// How a project's kit stores a Look.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Payload {
    style: TextStyle,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    animation: Option<KeyframeTemplate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    karaoke: Option<KaraokeStyle>,
    #[serde(default, with = "sq_core_time::base64::option", skip_serializing_if = "Option::is_none")]
    caption_segmentation: Option<Vec<u8>>,
}

impl Look {
    /// 1 = the caption look (style + animation), read by every build. 2 = everything a Look can hold.
    pub const PAYLOAD_VERSION: i64 = 2;

    /// A Look with a style only.
    pub fn new(id: &str, name: &str, style: TextStyle) -> Look {
        Look {
            id: id.to_string(),
            name: name.to_string(),
            style,
            animation: None,
            karaoke: None,
            caption_segmentation: None,
            is_built_in: false,
            category: None,
        }
    }

    /// A Look from a caption look (style + animation).
    pub fn from_caption_look(id: &str, name: &str, caption_look: CaptionLook) -> Look {
        let mut l = Look::new(id, name, caption_look.style);
        l.animation = Some(caption_look.animation);
        l
    }

    /// The values (animation: "no animation" reads as nil).
    pub fn values(&self) -> LookValues {
        LookValues {
            style: self.style.clone(),
            animation: normalized(self.animation.as_ref()).cloned(),
            karaoke: self.karaoke.clone(),
            caption_segmentation: self.caption_segmentation.clone(),
        }
    }

    /// The Look as captions render it (no animation = the empty template).
    pub fn caption_look(&self) -> CaptionLook {
        CaptionLook {
            style: self.style.clone(),
            animation: self.animation.clone().unwrap_or_else(KeyframeTemplate::none),
        }
    }

    /// True when an item this Look was applied to no longer shows it: its style differs, or the Look carries an
    /// animation and the item's animation differs. A Look without an animation never looks at the item's animation.
    pub fn differs(&self, style: &TextStyle, animation: Option<&KeyframeTemplate>) -> bool {
        if *style != self.style {
            return true;
        }
        let Some(mine) = self.animation.as_ref() else { return false };
        normalized(Some(mine)) != normalized(animation)
    }

    /// The stored form and its version: a Look that is exactly a caption look (style + animation) is written as
    /// version 1, byte-compatible with older builds; anything else as version 2.
    pub fn payload(&self) -> Result<(Vec<u8>, i64), LookError> {
        if let (Some(animation), None, None) = (&self.animation, &self.karaoke, &self.caption_segmentation) {
            let look = CaptionLook { style: self.style.clone(), animation: animation.clone() };
            return Ok((look.payload()?, CaptionLook::PAYLOAD_VERSION));
        }
        let p = Payload {
            style: self.style.clone(),
            animation: self.animation.clone(),
            karaoke: self.karaoke.clone(),
            caption_segmentation: self.caption_segmentation.clone(),
        };
        // `Value` objects keep their keys sorted.
        Ok((serde_json::to_vec(&sq_core_time::json_sorted::to_value(p)?)?, Self::PAYLOAD_VERSION))
    }

    /// Reads a stored Look.
    pub fn from_payload(id: &str, name: &str, payload: &[u8], version: i64) -> Result<Look, LookError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(LookError::NewerVersion);
        }
        if version <= CaptionLook::PAYLOAD_VERSION {
            return Ok(Look::from_caption_look(id, name, CaptionLook::from_payload(payload, version)?));
        }
        let p: Payload = serde_json::from_slice(payload)?;
        let mut l = Look::new(id, name, p.style);
        l.animation = p.animation;
        l.karaoke = p.karaoke;
        l.caption_segmentation = p.caption_segmentation;
        Ok(l)
    }
}

/// How an item relates to the Look that was applied to it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum LookState {
    /// No Look applied (or the Look no longer exists).
    None,
    /// The item shows the Look exactly.
    Applied(String),
    /// The item was changed after the Look was applied ("edited": Update Look / Save as New Look).
    Edited(String),
}

impl LookState {
    /// The applied Look's id.
    pub fn look_id(&self) -> Option<&str> {
        match self {
            LookState::None => None,
            LookState::Applied(id) | LookState::Edited(id) => Some(id),
        }
    }

    /// Whether the item was edited after the Look was applied.
    pub fn is_edited(&self) -> bool {
        matches!(self, LookState::Edited(_))
    }
}

/// The Look library: the built-in Looks (read-only) plus saved ones in creation order. A value; `LookStore` (app) and
/// `StyleKit.looks` (project) persist it.
#[derive(Clone, Debug, PartialEq)]
pub struct LookLibrary {
    user: Vec<Look>,
    /// Ids of Looks that were merged into an equal one (old id -> kept id), so what referred to the old id still resolves.
    aliases: BTreeMap<String, String>,
}

impl Default for LookLibrary {
    fn default() -> Self {
        LookLibrary::new(Vec::new(), BTreeMap::new())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LibraryWire<'a> {
    format_version: i64,
    looks: &'a [Look],
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    aliases: &'a BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LibraryRead {
    #[serde(default)]
    format_version: Option<i64>,
    #[serde(default)]
    looks: Option<Vec<Look>>,
    #[serde(default)]
    aliases: Option<BTreeMap<String, String>>,
}

impl Serialize for LookLibrary {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        LibraryWire { format_version: Self::FORMAT_VERSION, looks: &self.user, aliases: &self.aliases }.serialize(s)
    }
}

impl<'de> Deserialize<'de> for LookLibrary {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<LookLibrary, D::Error> {
        let r = LibraryRead::deserialize(d)?;
        if r.format_version.unwrap_or(1) > Self::FORMAT_VERSION {
            return Err(serde::de::Error::custom("newer version"));
        }
        Ok(LookLibrary::new(r.looks.unwrap_or_default(), r.aliases.unwrap_or_default()))
    }
}

impl LookLibrary {
    /// Version of the stored library.
    pub const FORMAT_VERSION: i64 = 1;

    /// A library of saved Looks; a Look whose id is taken is dropped, an alias needs its kept Look.
    pub fn new(user: Vec<Look>, aliases: BTreeMap<String, String>) -> LookLibrary {
        let mut lib = LookLibrary { user: Vec::new(), aliases: BTreeMap::new() };
        for mut l in user {
            if lib.look(&l.id).is_none() {
                l.is_built_in = false;
                lib.user.push(l);
            }
        }
        for (old, kept) in aliases {
            if lib.look(&old).is_none() && lib.user.iter().any(|l| l.id == kept) {
                lib.aliases.insert(old, kept);
            }
        }
        lib
    }

    /// The saved Looks.
    pub fn user(&self) -> &[Look] {
        &self.user
    }

    /// The merged-away ids and the Looks that replaced them.
    pub fn aliases(&self) -> &BTreeMap<String, String> {
        &self.aliases
    }

    /// Built-in Looks first, then the saved ones.
    pub fn looks(&self) -> Vec<Look> {
        Self::built_ins().iter().chain(self.user.iter()).cloned().collect()
    }

    /// The Look under `id`; an id that was merged away resolves to the Look that replaced it.
    pub fn look(&self, id: &str) -> Option<Look> {
        if let Some(b) = Self::built_ins().iter().find(|l| l.id == id) {
            return Some(b.clone());
        }
        let key = self.aliases.get(id).map_or(id, String::as_str);
        self.user.iter().find(|l| l.id == key).cloned()
    }

    /// The id of the first Look whose style equals `style` exactly (saved Looks first, so a saved copy wins).
    pub fn match_style(&self, style: &TextStyle) -> Option<String> {
        self.user.iter().chain(Self::built_ins().iter()).find(|l| l.style == *style).map(|l| l.id.clone())
    }

    /// Whether an item with `style` (and `animation`) still shows the Look applied to it.
    pub fn state(
        &self,
        style: &TextStyle,
        animation: Option<&KeyframeTemplate>,
        applied_look_id: Option<&str>,
    ) -> LookState {
        let Some(l) = applied_look_id.and_then(|id| self.look(id)) else { return LookState::None };
        if l.differs(style, animation) { LookState::Edited(l.id) } else { LookState::Applied(l.id) }
    }

    /// "Save as New Look": saves the values under a trimmed `name`; nil for an empty name or a taken `id`.
    pub fn add(&mut self, name: &str, values: LookValues, id: Option<&str>, ids: &mut dyn IdSource) -> Option<String> {
        let n = trim_spaces(name, true);
        if n.is_empty() {
            return None;
        }
        if let Some(id) = id
            && self.look(id).is_some()
        {
            return None;
        }
        let new_id = match id {
            Some(id) => id.to_string(),
            None => self.fresh_id(ids),
        };
        let mut l = Look::new(&new_id, n, values.style);
        l.animation = values.animation;
        l.karaoke = values.karaoke;
        l.caption_segmentation = values.caption_segmentation;
        self.user.push(l);
        Some(new_id)
    }

    /// Renames a saved Look; false for an empty name or an unknown id.
    pub fn rename(&mut self, id: &str, name: &str) -> bool {
        let n = trim_spaces(name, true);
        let Some(i) = self.index(id).filter(|_| !n.is_empty()) else { return false };
        self.user[i].name = n.to_string();
        true
    }

    /// "Update Look": changes the values of a saved Look in place (its id and name stay).
    pub fn update(&mut self, id: &str, change: impl FnOnce(&mut Look)) -> bool {
        let Some(i) = self.index(id) else { return false };
        let mut l = self.user[i].clone();
        change(&mut l);
        l.id = self.user[i].id.clone();
        l.name = self.user[i].name.clone();
        l.is_built_in = false;
        self.user[i] = l;
        true
    }

    /// `update` that replaces the style.
    pub fn update_style(&mut self, id: &str, style: TextStyle) -> bool {
        self.update(id, |l| l.style = style)
    }

    /// Deletes a saved Look. An id that was merged into another Look only stops resolving: the Look it pointed at stays.
    pub fn delete(&mut self, id: &str) -> bool {
        if self.aliases.contains_key(id) && !self.user.iter().any(|l| l.id == id) {
            self.aliases.remove(id);
            return true;
        }
        let Some(i) = self.index(id) else { return false };
        let gone = self.user.remove(i).id;
        self.aliases.retain(|_, v| *v != gone);
        true
    }

    /// An editable copy ("Name Copy", "Name Copy 2", ...) of any Look, built-in or not.
    pub fn duplicate(&mut self, id: &str, ids: &mut dyn IdSource) -> Option<String> {
        let src = self.look(id)?;
        let base = strip_copy_suffix(&src.name);
        let names: BTreeSet<String> = self.looks().into_iter().map(|l| l.name).collect();
        let mut name = format!("{base} Copy");
        let mut n = 2;
        while names.contains(&name) {
            name = format!("{base} Copy {n}");
            n += 1;
        }
        let values = LookValues {
            style: src.style,
            animation: src.animation,
            karaoke: src.karaoke,
            caption_segmentation: src.caption_segmentation,
        };
        self.add(&name, values, None, ids)
    }

    /// Moves the saved Looks into the order of `ids` (unknown ids are ignored, Looks not named keep their place at the end).
    pub fn reorder(&mut self, ids: &[String]) {
        let mut rank: BTreeMap<&str, usize> = BTreeMap::new();
        for (i, id) in ids.iter().enumerate() {
            rank.entry(id).or_insert(i);
        }
        let mut indexed: Vec<(usize, Look)> = std::mem::take(&mut self.user).into_iter().enumerate().collect();
        indexed.sort_by_key(|(offset, l)| (rank.get(l.id.as_str()).copied().unwrap_or(usize::MAX), *offset));
        self.user = indexed.into_iter().map(|(_, l)| l).collect();
    }

    /// Takes Looks from another store in (the migration of the old separate stores, an import). Returns where each
    /// incoming id ended up.
    /// - A Look whose values equal a saved one is not added: its id becomes an alias of the saved Look.
    /// - A different Look under a taken name gets a number ("Name 2").
    /// - A different Look under a taken id gets a new id.
    pub fn merge(&mut self, incoming: Vec<Look>, ids: &mut dyn IdSource) -> BTreeMap<String, String> {
        let mut map = BTreeMap::new();
        for mut l in incoming {
            l.is_built_in = false;
            if let Some(same) = self.user.iter().find(|u| u.values() == l.values()).cloned() {
                if same.id != l.id && self.look(&l.id).is_none() {
                    self.aliases.insert(l.id.clone(), same.id.clone());
                }
                map.insert(l.id.clone(), same.id);
                continue;
            }
            let old = l.id.clone();
            if self.look(&l.id).is_some() {
                l.id = self.fresh_id(ids);
            }
            let names: BTreeSet<String> = self.looks().into_iter().map(|x| x.name).collect();
            let blank = trim_spaces(&l.name, true).is_empty();
            if names.contains(&l.name) || blank {
                let base = if blank { "Look".to_string() } else { l.name.clone() };
                let mut n = 2;
                while names.contains(&format!("{base} {n}")) {
                    n += 1;
                }
                l.name = if names.contains(&base) { format!("{base} {n}") } else { base };
            }
            map.insert(old, l.id.clone());
            self.user.push(l);
        }
        map
    }

    /// The saved Look under `id`; an id that was merged away finds the Look that replaced it (rename, update).
    fn index(&self, id: &str) -> Option<usize> {
        let key = self.aliases.get(id).map_or(id, String::as_str);
        self.user.iter().position(|l| l.id == key)
    }

    fn fresh_id(&self, ids: &mut dyn IdSource) -> String {
        loop {
            let id = ids.next_id().to_string();
            if self.look(&id).is_none() {
                return id;
            }
        }
    }

    /// The built-in Looks.
    pub fn built_ins() -> &'static [Look] {
        static BUILT_INS: LazyLock<Vec<Look>> = LazyLock::new(build_built_ins);
        &BUILT_INS
    }
}

/// `base` without a trailing " Copy" or " Copy <number>".
fn strip_copy_suffix(base: &str) -> &str {
    let Some(at) = base.rfind(" Copy") else { return base };
    let rest = &base[at + " Copy".len()..];
    let numbered = rest.strip_prefix(' ').is_some_and(|d| !d.is_empty() && d.chars().all(|c| c.is_ascii_digit()));
    if rest.is_empty() || numbered { &base[..at] } else { base }
}

fn build_built_ins() -> Vec<Look> {
    let black = |a: f64| RGBAColor::new(0.0, 0.0, 0.0, a);
    let font = TextStyle::default_font_name();
    let base = |size: f64, weight: FontWeight| TextStyle::new(font, size, weight, RGBAColor::WHITE);
    let soft = TextShadow::from_angle(black(0.55), 135.0, 3.0, 8.0);
    let outside = |color: RGBAColor, width: f64| TextStroke::new(color, width, StrokePosition::Outside);
    let title = TextStyle {
        shadow: Some(soft),
        alignment: TextAlignment::Center,
        line_spacing: 2.0,
        ..base(72.0, FontWeight::Bold)
    };
    let classic = TextStyle {
        shadow: Some(TextShadow::new(black(0.6), 0.0, 2.0, 6.0)),
        alignment: TextAlignment::Center,
        line_spacing: 4.0,
        ..base(56.0, FontWeight::Semibold)
    };
    let boxed = TextStyle {
        background: Some(TextBackground::new(black(0.75), BoxPadding::new(20.0, 10.0), 12.0)),
        alignment: TextAlignment::Center,
        line_spacing: 4.0,
        ..base(52.0, FontWeight::Bold)
    };
    let outline = TextStyle {
        stroke: Some(outside(RGBAColor::BLACK, 6.0)),
        alignment: TextAlignment::Center,
        line_spacing: 2.0,
        ..base(60.0, FontWeight::Heavy)
    };
    let tiktok = TextStyle {
        stroke: Some(outside(RGBAColor::BLACK, 8.0)),
        shadow: Some(soft),
        alignment: TextAlignment::Center,
        line_spacing: 2.0,
        ..base(64.0, FontWeight::Black)
    };
    let pill = CaptionPill::apply(
        &TextStyle { alignment: TextAlignment::Center, line_spacing: 2.0, ..base(64.0, FontWeight::Black) },
        None,
    );
    let yellow = TextStyle {
        color: RGBAColor::new(1.0, 0.84, 0.04, 1.0),
        stroke: Some(outside(RGBAColor::BLACK, 8.0)),
        alignment: TextAlignment::Center,
        line_spacing: 2.0,
        ..base(64.0, FontWeight::Black)
    };
    let lower = TextStyle {
        background: Some(TextBackground::new(RGBAColor::new(0.04, 0.42, 1.0, 0.85), BoxPadding::new(18.0, 8.0), 4.0)),
        alignment: TextAlignment::Left,
        line_spacing: 2.0,
        ..base(44.0, FontWeight::Semibold)
    };
    let minimal = TextStyle {
        alignment: TextAlignment::Center,
        line_spacing: 2.0,
        tracking: 6.0,
        all_caps: true,
        ..base(48.0, FontWeight::Light)
    };
    let category = |id: &str| match id {
        "title" | "bold-box" | "outline" | "tiktok" | "pill" | "yellow" => Some("Bold"),
        "classic" | "lower-third" | "minimal" => Some("Clean"),
        _ => None,
    };
    [
        ("title", "Title", title),
        ("classic", "Classic", classic),
        ("bold-box", "Bold Box", boxed),
        ("outline", "Outline", outline),
        ("tiktok", "TikTok", tiktok),
        ("pill", "Pill", pill),
        ("yellow", "Yellow", yellow),
        ("lower-third", "Lower Third", lower),
        ("minimal", "Minimal", minimal),
    ]
    .into_iter()
    .map(|(id, name, style)| {
        let mut l = Look::new(id, name, style);
        l.is_built_in = true;
        l.category = category(id).map(str::to_string);
        l
    })
    .collect()
}

/// The Looks of a project (its style kit).
pub trait StyleKitLookExt {
    /// The kit Look under `id`, if this build can read it.
    fn look(&self, id: &str) -> Option<Look>;
    /// Every kit Look this build can read, by name (then id).
    fn project_looks(&self) -> Vec<Look>;
    /// Adds (or replaces) the Look under its id.
    fn set_look(&mut self, look: &Look) -> Result<(), LookError>;
}

impl StyleKitLookExt for StyleKit {
    fn look(&self, id: &str) -> Option<Look> {
        self.looks.get(id).and_then(|k| Look::from_payload(id, &k.name, &k.payload, k.payload_version).ok())
    }

    fn project_looks(&self) -> Vec<Look> {
        let mut out: Vec<Look> = self.looks.keys().filter_map(|k| self.look(k)).collect();
        out.sort_by(|a, b| (&a.name, &a.id).cmp(&(&b.name, &b.id)));
        out
    }

    fn set_look(&mut self, look: &Look) -> Result<(), LookError> {
        let (payload, payload_version) = look.payload()?;
        self.looks.insert(look.id.clone(), StyleKitLook { name: look.name.clone(), payload, payload_version });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_presets::CaptionLook;
    use crate::text_style::RGBAColor;
    use sq_core_model::anchored_animation::{AnimationTrack, SegmentShape};
    use sq_core_time::{SequentialIds, Time};

    fn red() -> TextStyle {
        TextStyle::new("Menlo", 50.0, FontWeight::Bold, RGBAColor::new(1.0, 0.0, 0.0, 1.0))
    }

    fn big() -> TextStyle {
        TextStyle { size: 90.0, ..red() }
    }

    fn fade() -> KeyframeTemplate {
        KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 0.0, SegmentShape::Linear), (Time::new(1, 2), 1.0, SegmentShape::Linear)],
            )],
            duration: Time::new(1, 2),
            ..KeyframeTemplate::none()
        }
    }

    fn values(style: TextStyle, animation: Option<KeyframeTemplate>) -> LookValues {
        LookValues { animation, ..LookValues::new(style) }
    }

    fn look_with(id: &str, name: &str, style: TextStyle, animation: Option<KeyframeTemplate>) -> Look {
        let mut l = Look::new(id, name, style);
        l.animation = animation;
        l
    }

    #[test]
    fn built_ins_are_read_only_and_listed_first() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let b = LookLibrary::built_ins();
        let unique: BTreeSet<&str> = b.iter().map(|x| x.id.as_str()).collect();
        assert!(b.len() == 9 && unique.len() == 9 && b.iter().all(|x| x.is_built_in));
        let id = l.add(" Mine ", LookValues::new(red()), None, &mut ids).unwrap();
        let listed: Vec<String> = l.looks().iter().map(|x| x.id.clone()).collect();
        let expected: Vec<String> = b.iter().map(|x| x.id.clone()).chain([id.clone()]).collect();
        assert_eq!(listed, expected);
        assert!(l.look(&id).is_some_and(|x| x.name == "Mine" && !x.is_built_in));
        assert!(!l.rename(&b[0].id, "X") && !l.delete(&b[0].id) && !l.update_style(&b[0].id, red()));
        assert!(l.add("  ", LookValues::new(red()), None, &mut ids).is_none());
        assert!(l.add("Taken", LookValues::new(red()), Some(&b[0].id), &mut ids).is_none());
        assert!(l.add("Taken", LookValues::new(red()), Some(&id), &mut ids).is_none());
    }

    #[test]
    fn update_keeps_id_and_name_and_the_rest_of_the_look() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let mut v = values(red(), Some(fade()));
        v.karaoke = Some(KaraokeStyle { red: 1.0, green: 0.0, blue: 0.0, keep_spoken: true });
        let id = l.add("A", v, None, &mut ids).unwrap();
        assert!(l.update_style(&id, big()));
        let got = l.look(&id).unwrap();
        assert!(got.style == big() && got.animation == Some(fade()) && got.karaoke.is_some());
        assert!(l.update(&id, |x| {
            x.id = "other".into();
            x.name = "Other".into();
            x.animation = None;
        }));
        assert!(l.look(&id).is_some_and(|x| x.name == "A" && x.animation.is_none()) && l.look("other").is_none());
        assert!(l.rename(&id, " B ") && l.look(&id).is_some_and(|x| x.name == "B"));
        assert!(l.delete(&id) && !l.delete(&id) && l.look(&id).is_none());
    }

    #[test]
    fn duplicate_copies_everything() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let id = l.add("A", values(red(), Some(fade())), None, &mut ids).unwrap();
        let copy = l.duplicate(&id, &mut ids).unwrap();
        assert!(l.look(&copy).is_some_and(|x| x.name == "A Copy"));
        assert_eq!(l.look(&copy).unwrap().values(), l.look(&id).unwrap().values());
        let again = l.duplicate(&copy, &mut ids).unwrap();
        assert!(l.look(&again).is_some_and(|x| x.name == "A Copy 2"));
    }

    #[test]
    fn identical_looks_merge_and_the_old_id_still_resolves() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let kept = l.add("Caption Look 1", values(red(), Some(fade())), None, &mut ids).unwrap();
        let map = l.merge(
            vec![look_with("user-1", "Red", red(), Some(fade())), look_with("user-2", "Big", big(), None)],
            &mut ids,
        );
        assert_eq!(l.user().len(), 2);
        assert_eq!(
            map,
            BTreeMap::from([("user-1".to_string(), kept.clone()), ("user-2".to_string(), "user-2".to_string())])
        );
        assert!(l.look("user-1").is_some_and(|x| x.id == kept && x.name == "Caption Look 1"));
        assert_eq!(l.aliases(), &BTreeMap::from([("user-1".to_string(), kept.clone())]));
        // Deleting the kept Look removes its aliases with it.
        assert!(l.delete(&kept));
        assert!(l.look("user-1").is_none() && l.aliases().is_empty());
    }

    /// An id that was merged into another Look stands for that Look: rename and update change it, delete only drops
    /// the old id (the Look may be in use under its own id).
    #[test]
    fn a_merged_id_acts_on_the_look_it_resolves_to() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let kept = l.add("Kept", values(red(), Some(fade())), None, &mut ids).unwrap();
        l.merge(vec![look_with("old", "Red", red(), Some(fade()))], &mut ids);
        assert!(l.rename("old", "New Name") && l.look(&kept).is_some_and(|x| x.name == "New Name"));
        assert!(l.update_style("old", big()) && l.look(&kept).is_some_and(|x| x.style == big()));
        assert!(l.delete("old") && l.look(&kept).is_some() && l.look("old").is_none() && l.aliases().is_empty());
        assert!(!l.delete("old") && l.user().len() == 1);
        // A blank name adds nothing.
        assert!(l.add("  ", LookValues::new(red()), None, &mut ids).is_none() && l.user().len() == 1);
    }

    #[test]
    fn no_animation_is_the_same_stored_either_way() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let a = l.add("A", values(red(), Some(KeyframeTemplate::none())), None, &mut ids).unwrap();
        l.merge(vec![look_with("t", "B", red(), None)], &mut ids);
        assert!(l.user().len() == 1 && l.look("t").is_some_and(|x| x.id == a));
        // A Look with a real animation is a different Look.
        l.merge(vec![look_with("u", "C", red(), Some(fade()))], &mut ids);
        assert_eq!(l.user().len(), 2);
    }

    #[test]
    fn name_clashes_get_a_number_and_id_clashes_a_new_id() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let first = l.add("Brand", LookValues::new(red()), Some("x"), &mut ids).unwrap();
        let map = l.merge(
            vec![
                look_with("x", "Brand", big(), None),
                look_with("y", "Brand", TextStyle::default(), None),
                look_with("z", "Title", TextStyle { size: 91.0, ..big() }, None),
                look_with("x", "Brand", red(), None),
            ],
            &mut ids,
        );
        let names: Vec<&str> = l.user().iter().map(|x| x.name.as_str()).collect();
        assert_eq!(names, ["Brand", "Brand 2", "Brand 3", "Title 2"]);
        assert!(map["y"] == "y" && map["z"] == "z");
        assert!(l.look(&first).is_some_and(|x| x.style == red()));
        assert_eq!(l.user().iter().map(|x| x.id.clone()).collect::<BTreeSet<_>>().len(), 4);
        // Merging the same Looks again changes nothing (a second migration run is harmless).
        let before = l.clone();
        l.merge(before.user().to_vec(), &mut ids);
        assert_eq!(l, before);
    }

    #[test]
    fn library_round_trips_and_refuses_a_newer_file() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let mut v = values(red(), Some(fade()));
        v.caption_segmentation = Some(b"{}".to_vec());
        l.add("A", v, None, &mut ids);
        let mut same = look_with("old", "Same", red(), Some(fade()));
        same.caption_segmentation = Some(b"{}".to_vec());
        l.merge(vec![same], &mut ids);
        let data = serde_json::to_vec(&l).unwrap();
        assert_eq!(serde_json::from_slice::<LookLibrary>(&data).unwrap(), l);
        let mut obj: serde_json::Value = serde_json::from_slice(&data).unwrap();
        obj["formatVersion"] = (LookLibrary::FORMAT_VERSION + 1).into();
        assert!(serde_json::from_value::<LookLibrary>(obj).is_err());
    }

    #[test]
    fn edited_state_compares_the_item_with_its_look() {
        let mut ids = SequentialIds::default();
        let mut l = LookLibrary::default();
        let style_only = l.add("S", LookValues::new(red()), None, &mut ids).unwrap();
        let animated = l.add("A", values(big(), Some(fade())), None, &mut ids).unwrap();
        assert_eq!(l.state(&red(), None, None), LookState::None);
        assert_eq!(l.state(&red(), None, Some("gone")), LookState::None);
        assert_eq!(l.state(&red(), None, Some(&style_only)), LookState::Applied(style_only.clone()));
        // A Look without an animation does not care which animation the item has.
        assert_eq!(l.state(&red(), Some(&fade()), Some(&style_only)), LookState::Applied(style_only.clone()));
        assert_eq!(l.state(&big(), None, Some(&style_only)), LookState::Edited(style_only.clone()));
        assert_eq!(l.state(&big(), Some(&fade()), Some(&animated)), LookState::Applied(animated.clone()));
        assert_eq!(l.state(&big(), None, Some(&animated)), LookState::Edited(animated.clone()));
        assert!(l.state(&red(), Some(&fade()), Some(&animated)).is_edited());
        // Built-in Looks work the same; an alias reports the Look it resolves to.
        let b = &LookLibrary::built_ins()[0];
        assert_eq!(l.state(&b.style, None, Some(&b.id)), LookState::Applied(b.id.clone()));
        l.merge(vec![look_with("alias", "S again", red(), None)], &mut ids);
        assert_eq!(l.state(&red(), None, Some("alias")), LookState::Applied(style_only));
    }

    #[test]
    fn kit_looks_keep_the_old_payload_where_it_fits() {
        let mut kit = StyleKit::default();
        kit.set_look(&look_with("cap", "Caption", red(), Some(fade()))).unwrap();
        kit.set_look(&look_with("plain", "Plain", big(), None)).unwrap();
        let mut full = look_with("full", "Full", red(), Some(fade()));
        full.karaoke = Some(KaraokeStyle { red: 1.0, green: 1.0, blue: 0.0, keep_spoken: false });
        full.caption_segmentation = Some(b"{}".to_vec());
        kit.set_look(&full).unwrap();
        assert_eq!(kit.looks["cap"].payload_version, 1);
        assert!(kit.looks["plain"].payload_version == 2 && kit.looks["full"].payload_version == 2);
        // Version 1 is exactly what older builds wrote and read.
        let old = CaptionLook::from_payload(&kit.looks["cap"].payload, 1).unwrap();
        assert_eq!(old, CaptionLook::new(red(), fade()));
        let ids: Vec<String> = kit.project_looks().iter().map(|x| x.id.clone()).collect();
        assert_eq!(ids, ["cap", "full", "plain"]);
        assert!(kit.look("full").and_then(|x| x.karaoke).is_some_and(|k| k.green == 1.0));
        assert!(kit.look("plain").is_some_and(|x| x.animation.is_none()));
    }

    #[test]
    fn a_kit_from_an_older_build_lists_its_looks_unchanged() {
        let mut kit = StyleKit::default();
        let payload = CaptionLook::new(red(), fade()).payload().unwrap();
        kit.looks.insert("brand".into(), StyleKitLook { name: "Brand".into(), payload, payload_version: 1 });
        let before = kit.clone();
        let looks = kit.project_looks();
        assert_eq!(looks, vec![look_with("brand", "Brand", red(), Some(fade()))]);
        kit.set_look(&looks[0]).unwrap();
        assert_eq!(kit.looks["brand"].payload_version, before.looks["brand"].payload_version);
        assert_eq!(CaptionLook::from_payload(&kit.looks["brand"].payload, 1).unwrap(), CaptionLook::new(red(), fade()));
        // A payload from a newer build is skipped, not misread.
        kit.looks.insert(
            "future".into(),
            StyleKitLook { name: "Future".into(), payload: b"{}".to_vec(), payload_version: 99 },
        );
        let ids: Vec<String> = kit.project_looks().iter().map(|x| x.id.clone()).collect();
        assert_eq!(ids, ["brand"]);
    }
}
