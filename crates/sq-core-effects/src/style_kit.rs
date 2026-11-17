// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleKit.swift (logic; the saved types live in sq-core-model `style_kit.rs`)
//! Project-level brand tokens (fonts, colors, the caption pill, the caption style, motion defaults). Values that may follow
//! the brand are `StyleValue`s: a literal or the name of a token. Resolution happens where the value is used (captions
//! resolve through the caption library every frame, text clips are re-resolved when the kit changes), so changing a token
//! changes every caption and text that refers to it. The text crate owns the text side.

use crate::effects_editing::ClipEffectsEditingExt;
use serde::{Deserialize, Serialize};
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{
    AnimatedProperty, Clip, ClipEffect, EffectColor, GeneratorRef, GraphicsContent, MotionDefaults, Project, StyleKit,
    StyleValue,
};
use sq_core_time::{Id, IdSource};
use std::fs;
use std::path::Path;

/// Caption look payload version of the caption look (`ProjectFile+V72`): a Look with a newer payload makes a `.sqstyle`
/// file version 2.
pub const CAPTION_LOOK_PAYLOAD_VERSION: i64 = 1;

/// Swift `StyleValue.resolve` / `tokenName`.
pub trait StyleValueExt<V> {
    /// The literal, or the token's value from `lookup`; `None` for a token the kit does not define.
    fn resolve(&self, lookup: impl Fn(&str) -> Option<V>) -> Option<V>;
    /// The token's name, if it is a token.
    fn token_name(&self) -> Option<&str>;
}

impl<V: Clone> StyleValueExt<V> for StyleValue<V> {
    fn resolve(&self, lookup: impl Fn(&str) -> Option<V>) -> Option<V> {
        match self {
            StyleValue::Literal(v) => Some(v.clone()),
            StyleValue::Token(name) => lookup(name),
        }
    }

    fn token_name(&self) -> Option<&str> {
        match self {
            StyleValue::Token(n) => Some(n),
            StyleValue::Literal(_) => None,
        }
    }
}

/// What `StyleKitExt::merging` did. Token names are prefixed with their kind ("font:brand", "color:accent").
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StyleKitMergeReport {
    /// Tokens added.
    pub added_tokens: Vec<String>,
    /// Tokens the importer already had with a different value: the importer's value stays.
    pub kept_tokens: Vec<String>,
    /// Ids of the looks added (renamed ids for looks whose id was taken by a different look).
    pub added_looks: Vec<String>,
}

impl StyleKitMergeReport {
    /// Nothing was added.
    pub fn is_empty(&self) -> bool {
        self.added_tokens.is_empty() && self.added_looks.is_empty()
    }
}

/// Caption style ref of the kit caption style (resolved by the text crate).
pub const CAPTION_STYLE_REF: &str = "kit-caption";
/// Caption animation ref of the kit caption style.
pub const CAPTION_ANIMATION_REF: &str = "kit-caption";

/// Swift `StyleKit` methods.
pub trait StyleKitExt {
    /// The font token.
    fn font(&self, name: &str) -> Option<&str>;
    /// The color token.
    fn color(&self, name: &str) -> Option<EffectColor>;
    /// Imports `other` into this kit without touching the importer's brand: tokens, pill, caption style and motion defaults
    /// are only added where this kit has none; looks are added, a look whose id is taken by a different look gets a new id
    /// ("pop-2", name "Pop 2"). An imported look that refers to a token the importer already defines draws in the
    /// importer's value (that is the point: the look follows the importer's brand).
    fn merging(&self, other: &StyleKit) -> (StyleKit, StyleKitMergeReport);
}

impl StyleKitExt for StyleKit {
    fn font(&self, name: &str) -> Option<&str> {
        self.fonts.get(name).map(String::as_str)
    }

    fn color(&self, name: &str) -> Option<EffectColor> {
        self.colors.get(name).copied()
    }

    fn merging(&self, other: &StyleKit) -> (StyleKit, StyleKitMergeReport) {
        let mut k = self.clone();
        let mut r = StyleKitMergeReport::default();
        for (name, v) in &other.fonts {
            match k.fonts.get(name) {
                Some(mine) => {
                    if mine != v {
                        r.kept_tokens.push(format!("font:{name}"));
                    }
                }
                None => {
                    k.fonts.insert(name.clone(), v.clone());
                    r.added_tokens.push(format!("font:{name}"));
                }
            }
        }
        for (name, v) in &other.colors {
            match k.colors.get(name) {
                Some(mine) => {
                    if mine != v {
                        r.kept_tokens.push(format!("color:{name}"));
                    }
                }
                None => {
                    k.colors.insert(name.clone(), *v);
                    r.added_tokens.push(format!("color:{name}"));
                }
            }
        }
        if let (None, Some(p)) = (&k.pill, &other.pill) {
            k.pill = Some(p.clone());
            r.added_tokens.push("pill".into());
        }
        if let (None, Some(c)) = (&k.caption, &other.caption) {
            k.caption = Some(c.clone());
            r.added_tokens.push("caption".into());
        }
        if let (None, Some(m)) = (&k.motion, &other.motion) {
            k.motion = Some(m.clone());
            r.added_tokens.push("motion".into());
        }
        if let (None, Some(p)) = (&k.caption_position, &other.caption_position) {
            k.caption_position = Some(*p);
            r.added_tokens.push("captionPosition".into());
        }
        // `looks` is a sorted map, so the order matches Swift's sorted-by-key walk.
        for (id, look) in &other.looks {
            let Some(mine) = k.looks.get(id) else {
                k.looks.insert(id.clone(), look.clone());
                r.added_looks.push(id.clone());
                continue;
            };
            if mine == look || k.looks.values().any(|l| l == look) {
                continue;
            }
            let mut n = 2;
            while k.looks.contains_key(&format!("{id}-{n}")) {
                n += 1;
            }
            let mut renamed = look.clone();
            renamed.name = format!("{} {n}", look.name);
            k.looks.insert(format!("{id}-{n}"), renamed);
            r.added_looks.push(format!("{id}-{n}"));
        }
        (k, r)
    }
}

/// Swift `MotionDefaults.apply(to:)`.
pub trait MotionDefaultsExt {
    /// Writes the defaults into a motion effect with Mode/Duration/Curve (loop animators have none and stay as they are).
    fn apply_to(&self, e: &mut ClipEffect);
}

impl MotionDefaultsExt for MotionDefaults {
    fn apply_to(&self, e: &mut ClipEffect) {
        if !e.is_motion_preset() || !e.parameters.contains_key(ClipEffect::MOTION_DURATION_KEY) {
            return;
        }
        let seconds = self.duration.value() as f64 / self.duration.timescale() as f64;
        e.parameters.insert(ClipEffect::MOTION_DURATION_KEY.to_string(), AnimatedProperty::new(seconds.max(0.01)));
        if MotionCurve::from_raw(self.curve).is_some() {
            e.parameters.insert(ClipEffect::MOTION_CURVE_KEY.to_string(), AnimatedProperty::new(self.curve as f64));
        }
    }
}

/// `addEffect(kind:motionDefaults:defaults:)` of Swift's `extension Clip`.
pub trait ClipStyleKitExt {
    /// `add_effect` (the user default), then the kit's motion defaults on a new motion effect.
    fn add_effect_with_motion_defaults(
        &mut self,
        kind: &str,
        motion_defaults: Option<&MotionDefaults>,
        defaults: Option<&EffectDefaults>,
        ids: &mut dyn IdSource,
    ) -> Option<Id>;
}

impl ClipStyleKitExt for Clip {
    fn add_effect_with_motion_defaults(
        &mut self,
        kind: &str,
        motion_defaults: Option<&MotionDefaults>,
        defaults: Option<&EffectDefaults>,
        ids: &mut dyn IdSource,
    ) -> Option<Id> {
        let id = self.add_effect(kind, defaults, ids)?;
        if let (Some(m), Some(e)) = (motion_defaults, self.effects.iter_mut().find(|e| e.id == id)) {
            m.apply_to(e);
        }
        Some(id)
    }
}

/// Swift `extension Project` in StyleKit.swift.
pub trait ProjectStyleKitExt {
    /// Value rewrite of generator payloads in every sequence (timing and track locks untouched: the brand follows
    /// everywhere). `f` returns the new ref, or `None` to keep the clip. Returns how many clips changed.
    fn rewrite_generators(&mut self, f: &dyn Fn(&GeneratorRef) -> Option<GeneratorRef>) -> usize;
}

impl ProjectStyleKitExt for Project {
    fn rewrite_generators(&mut self, f: &dyn Fn(&GeneratorRef) -> Option<GeneratorRef>) -> usize {
        let mut changed = 0;
        for tl in self.timelines.iter_mut() {
            for tr in tl.tracks.iter_mut() {
                tr.map_clips_keeping_timing(|c| {
                    let mut out = c.clone();
                    let mut touched = false;
                    if let Some(new) = c.generator.as_ref().and_then(f).filter(|n| Some(n) != c.generator.as_ref()) {
                        out.generator = Some(new);
                        touched = true;
                    }
                    // Variant generator overrides (a text clip's own box per format) follow the kit too.
                    if let Some(v) = out.variant_store.as_mut() {
                        for o in v.items.values_mut() {
                            if let Some(new) =
                                o.generator.as_ref().and_then(f).filter(|n| Some(n) != o.generator.as_ref())
                            {
                                o.generator = Some(new);
                                touched = true;
                            }
                        }
                    }
                    // Text layers of a graphics clip follow the kit too.
                    if let Some(doc) = out.graphics_store.as_mut() {
                        for layer in doc.layers.iter_mut() {
                            if let GraphicsContent::Text { generator } = &mut layer.content
                                && let Some(new) = f(generator).filter(|n| n != generator)
                            {
                                *generator = new;
                                touched = true;
                            }
                        }
                    }
                    if touched {
                        changed += 1;
                    }
                    out
                });
            }
        }
        changed
    }
}

/// `.sqstyle`: a style kit on its own (JSON `{formatVersion, kit}`), for moving a brand between projects.
pub struct StyleKitFile;

/// Why a `.sqstyle` file could not be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StyleKitFileError {
    /// Not a style kit file.
    Corrupt,
    /// Larger than `StyleKitFile::MAX_FILE_SIZE`.
    TooLarge,
    /// Written by a newer build.
    NewerVersion {
        /// The file's version.
        found: i64,
        /// The newest version this build reads.
        supported: i64,
    },
}

impl std::fmt::Display for StyleKitFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StyleKitFileError::Corrupt => f.write_str("not a style kit file"),
            StyleKitFileError::TooLarge => f.write_str("the style kit file is too large"),
            StyleKitFileError::NewerVersion { found, supported } => {
                write!(f, "file version {found} is newer than the supported {supported}")
            }
        }
    }
}

impl std::error::Error for StyleKitFileError {}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    format_version: i64,
    kit: StyleKit,
}

impl StyleKitFile {
    /// File extension.
    pub const FILE_EXTENSION: &'static str = "sqstyle";
    /// The newest version this build reads. 2 = a Look payload newer than the caption look is inside: a build that only
    /// knows version 1 would drop such a Look silently, so it has to refuse the file.
    pub const FORMAT_VERSION: i64 = 2;
    /// A kit is a few KB; anything larger is not read (hostile or wrong file).
    pub const MAX_FILE_SIZE: usize = 5 * 1024 * 1024;

    /// The lowest version that holds `kit`: files without a newer Look payload stay version 1, readable by every build.
    pub fn written_version(kit: &StyleKit) -> i64 {
        if kit.looks.values().any(|l| l.payload_version > CAPTION_LOOK_PAYLOAD_VERSION) { 2 } else { 1 }
    }

    /// The file's bytes: pretty printed, keys sorted.
    pub fn encode(kit: &StyleKit) -> Result<Vec<u8>, serde_json::Error> {
        let env = Envelope { format_version: Self::written_version(kit), kit: kit.clone() };
        // A `Value` keeps its object keys sorted (`preserve_order` is on in the app build: use `sq_core_time::json_sorted`).
        serde_json::to_vec_pretty(&sq_core_time::json_sorted::to_value(env)?)
    }

    /// Reads a file's bytes.
    pub fn decode(data: &[u8]) -> Result<StyleKit, StyleKitFileError> {
        let obj: serde_json::Value = serde_json::from_slice(data).map_err(|_| StyleKitFileError::Corrupt)?;
        let version = obj.get("formatVersion").and_then(serde_json::Value::as_i64).ok_or(StyleKitFileError::Corrupt)?;
        if version > Self::FORMAT_VERSION {
            return Err(StyleKitFileError::NewerVersion { found: version, supported: Self::FORMAT_VERSION });
        }
        let env: Envelope = serde_json::from_value(obj).map_err(|_| StyleKitFileError::Corrupt)?;
        Ok(env.kit)
    }

    /// Writes `kit` to `path`, atomically (a temporary file next to it, then a rename).
    pub fn write(kit: &StyleKit, path: &Path) -> std::io::Result<()> {
        let data = Self::encode(kit).map_err(std::io::Error::other)?;
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = std::path::PathBuf::from(tmp);
        fs::write(&tmp, data)?;
        fs::rename(&tmp, path)
    }

    /// Reads a kit from `path`.
    pub fn read(path: &Path) -> Result<StyleKit, StyleKitFileError> {
        let size = fs::metadata(path).map_err(|_| StyleKitFileError::Corrupt)?.len();
        if size > Self::MAX_FILE_SIZE as u64 {
            return Err(StyleKitFileError::TooLarge);
        }
        let data = fs::read(path).map_err(|_| StyleKitFileError::Corrupt)?;
        if data.len() > Self::MAX_FILE_SIZE {
            return Err(StyleKitFileError::TooLarge);
        }
        Self::decode(&data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sq_core_model::{StyleKitLook, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    const RED: EffectColor = EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    const BLUE: EffectColor = EffectColor { red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0 };

    fn brand() -> StyleKit {
        let mut k = StyleKit::default();
        k.fonts.insert("brand".into(), "Avenir-Black".into());
        k.colors.insert("text".into(), EffectColor::WHITE);
        k.colors.insert("accent".into(), RED);
        k.pill = serde_json::from_value(json!({"color": {"token": "accent"}})).ok();
        k.caption = serde_json::from_value(json!({"baseStyle": "pill", "font": {"token": "brand"}, "size": 70.0,
            "textColor": {"token": "text"}, "usesPill": true}))
        .ok();
        k.motion = Some(MotionDefaults { duration: Time::new(3, 10), curve: 6 });
        k
    }

    fn look(name: &str, payload: &[u8], version: i64) -> StyleKitLook {
        StyleKitLook { name: name.into(), payload: payload.to_vec(), payload_version: version }
    }

    #[test]
    fn style_value_resolves_literals_and_tokens() {
        let k = brand();
        let color = |n: &str| k.color(n);
        assert_eq!(StyleValue::Literal(BLUE).resolve(color), Some(BLUE));
        assert_eq!(StyleValue::<EffectColor>::Token("accent".into()).resolve(color), Some(RED));
        assert_eq!(StyleValue::<EffectColor>::Token("missing".into()).resolve(color), None);
        assert_eq!(
            StyleValue::<String>::Token("brand".into()).resolve(|n| k.font(n).map(str::to_string)).as_deref(),
            Some("Avenir-Black")
        );
        assert_eq!(StyleValue::<String>::Token("brand".into()).token_name(), Some("brand"));
        assert_eq!(StyleValue::Literal(1).token_name(), None);
    }

    #[test]
    fn motion_defaults_set_duration_and_curve_of_new_motion_effects_and_leave_others_alone() {
        let mut ids = SequentialIds::default();
        let mut c = Clip::new(
            ids.next_id(),
            "c",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(5, 1)),
            Time::ZERO,
        );
        let motion = brand().motion;
        let id = c.add_effect_with_motion_defaults(ClipEffect::POP_KIND, motion.as_ref(), None, &mut ids).unwrap();
        let e = c.effects.iter().find(|e| e.id == id).unwrap();
        assert_eq!(e.parameters.get(ClipEffect::MOTION_DURATION_KEY).map(|p| p.value), Some(0.3));
        assert_eq!(e.parameters.get(ClipEffect::MOTION_CURVE_KEY).map(|p| p.value), Some(6.0));

        let mut plain = ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap();
        plain.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), AnimatedProperty::new(20.0)); // the applied start value
        let id =
            c.add_effect_with_motion_defaults(ClipEffect::GAUSSIAN_BLUR_KIND, motion.as_ref(), None, &mut ids).unwrap();
        assert_eq!(c.effects.iter().find(|e| e.id == id).map(|e| &e.parameters), Some(&plain.parameters));
    }

    #[test]
    fn import_adds_missing_tokens_and_keeps_existing_ones() {
        let mut mine = StyleKit::default();
        mine.fonts.insert("brand".into(), "Futura-Bold".into());
        mine.colors.insert("accent".into(), BLUE);
        let (merged, report) = mine.merging(&brand());
        assert_eq!(merged.fonts.get("brand").map(String::as_str), Some("Futura-Bold"));
        assert_eq!(merged.colors.get("accent"), Some(&BLUE));
        assert_eq!(merged.colors.get("text"), Some(&EffectColor::WHITE));
        assert!(merged.pill == brand().pill && merged.caption == brand().caption && merged.motion == brand().motion);
        let mut kept = report.kept_tokens.clone();
        kept.sort();
        assert_eq!(kept, ["color:accent", "font:brand"]);
        assert!(report.added_tokens.contains(&"color:text".to_string()));
    }

    #[test]
    fn import_keeps_the_importers_pill_caption_and_motion_and_adds_caption_position_only_where_none() {
        let mine = StyleKit {
            pill: serde_json::from_value(
                json!({"color": {"literal": {"red": 0.0, "green": 0.0, "blue": 1.0, "alpha": 1.0}}}),
            )
            .ok(),
            caption: serde_json::from_value(json!({"baseStyle": "default"})).ok(),
            motion: Some(MotionDefaults { duration: Time::new(1, 2), curve: 0 }),
            ..StyleKit::default()
        };
        let merged = mine.merging(&brand()).0;
        assert!(merged.pill == mine.pill && merged.caption == mine.caption && merged.motion == mine.motion);

        let pos = serde_json::from_value(json!({"vertical": "middle", "offsetY": 0.207})).ok();
        let theirs = StyleKit { caption_position: pos, ..StyleKit::default() };
        let (added, report) = StyleKit::default().merging(&theirs);
        assert_eq!(added.caption_position, pos);
        assert!(report.added_tokens.contains(&"captionPosition".to_string()));
        let top = serde_json::from_value(json!({"vertical": "top"})).ok();
        let mine = StyleKit { caption_position: top, ..StyleKit::default() };
        assert_eq!(mine.merging(&theirs).0.caption_position, top);
    }

    #[test]
    fn import_adds_looks_renames_a_conflicting_one_and_reimport_changes_nothing() {
        let mut mine = StyleKit::default();
        mine.looks.insert("pop".into(), look("Pop", b"mine", 1));
        let mut theirs = StyleKit::default();
        theirs.looks.insert("pop".into(), look("Pop", b"theirs", 1));
        theirs.looks.insert("box".into(), look("Box", b"box", 1));
        let (merged, report) = mine.merging(&theirs);
        assert_eq!(merged.looks.get("pop"), mine.looks.get("pop"));
        assert_eq!(merged.looks.get("box"), theirs.looks.get("box"));
        assert_eq!(
            merged.looks.get("pop-2").map(|l| (l.payload.as_slice(), l.name.as_str())),
            Some((&b"theirs"[..], "Pop 2"))
        );
        let mut added = report.added_looks.clone();
        added.sort();
        assert_eq!(added, ["box", "pop-2"]);

        let k = brand();
        let (again, report) = k.merging(&k);
        assert!(again == k && report.is_empty());
    }

    #[test]
    fn sqstyle_round_trip_version_follows_the_look_payloads_and_a_newer_file_is_refused() {
        let mut k = brand();
        k.looks.insert("pop".into(), look("Pop", b"x", 1));
        assert_eq!(StyleKitFile::decode(&StyleKitFile::encode(&k).unwrap()), Ok(k.clone()));
        let version = |k: &StyleKit| -> Option<i64> {
            let v: serde_json::Value = serde_json::from_slice(&StyleKitFile::encode(k).ok()?).ok()?;
            v["formatVersion"].as_i64()
        };
        assert_eq!(version(&brand()), Some(1));
        assert_eq!(version(&k), Some(1));
        k.looks.insert("new".into(), look("New", b"y", 2));
        assert_eq!(version(&k), Some(2));
        assert_eq!(StyleKitFile::decode(&StyleKitFile::encode(&k).unwrap()), Ok(k));
        assert_eq!(StyleKitFile::FORMAT_VERSION, 2);

        let mut v: serde_json::Value = serde_json::from_slice(&StyleKitFile::encode(&brand()).unwrap()).unwrap();
        v["formatVersion"] = json!(StyleKitFile::FORMAT_VERSION + 1);
        let newer = serde_json::to_vec(&v).unwrap();
        assert_eq!(StyleKitFile::decode(&newer), Err(StyleKitFileError::NewerVersion { found: 3, supported: 2 }));
        assert_eq!(StyleKitFile::decode(b"nope"), Err(StyleKitFileError::Corrupt));
    }

    #[test]
    fn sqstyle_writes_and_reads_a_file_and_refuses_an_oversized_one() {
        let dir = std::env::temp_dir().join(format!("sq-style-kit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("kit.sqstyle");
        StyleKitFile::write(&brand(), &path).unwrap();
        assert_eq!(StyleKitFile::read(&path), Ok(brand()));
        assert_eq!(StyleKitFile::FILE_EXTENSION, "sqstyle");
        let big = dir.join("big.sqstyle");
        std::fs::write(&big, vec![0u8; StyleKitFile::MAX_FILE_SIZE + 1]).unwrap();
        assert_eq!(StyleKitFile::read(&big), Err(StyleKitFileError::TooLarge));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rewrite_generators_reaches_variant_overrides() {
        let mut ids = SequentialIds::default();
        let g = |p: &[u8]| GeneratorRef { kind: "text".into(), payload: p.to_vec(), payload_version: 1 };
        let mut c = Clip::new(
            ids.next_id(),
            "t",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(1, 1)),
            Time::ZERO,
        );
        c.generator = Some(g(b"a"));
        let vid = ids.next_id();
        let overrides = serde_json::from_value(
            json!({ vid.to_string(): {"generator": {"kind": "text", "payload": "dg==", "payloadVersion": 1}} }),
        )
        .unwrap();
        c.variant_store = Some(overrides);
        let mut t = sq_core_model::Track::new(ids.next_id(), TrackKind::Video);
        assert!(t.overwrite(c, &mut ids).is_ok());
        let tl = sq_core_model::Timeline::new(
            ids.next_id(),
            "s",
            sq_core_model::SequenceFormat::new(Time::new(1, 30)),
            vec![t],
        );
        let mut p = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
        let n = p.rewrite_generators(&|g| {
            Some(GeneratorRef { payload: [g.payload.clone(), b"!".to_vec()].concat(), ..g.clone() })
        });
        let out = &p.timelines[0].tracks[0].clips()[0];
        assert_eq!(n, 1);
        assert_eq!(out.generator.as_ref().map(|g| g.payload.clone()), Some(b"a!".to_vec()));
        let v = out.variant_store.as_ref().and_then(|v| v.items.get(&vid)).and_then(|o| o.generator.as_ref());
        assert_eq!(v.map(|g| g.payload.clone()), Some(b"v!".to_vec()));
    }
}
