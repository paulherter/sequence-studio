// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRPreset.swift. Premiere effect presets (.prfpset, "Effect Presets and Custom Items"): the same object table as a
//! project (docs/PRPROJ-IMPORT.md "Effect presets"). Tree "1" -> RootBin -> BinTreeItem folders (TreeItemBase/Name,
//! Items/Item) -> leaf TreeItem (TreeItemBase/Data) -> FilterPresetItem (FilterPresets/FilterPreset) -> FilterPreset (Type,
//! anchor points, Component) -> VideoFilterComponent / AudioFilterComponent, read like a clip's components.

use crate::prcontainer::{NodeExt, ObjectTable, PRTicks, all_named};
use crate::prdocument::{PRComponent, PRDocument, PRItem, PRParamValue, PRReader, PRSequence, PRSource};
use crate::primport_report::{PRImportReport, Status};
use crate::prmapper::{ClipContext, Mapping};
use sq_core_audio::audio_effects as ae;
use sq_core_effects::effect_preset::{Anchor, EffectPreset};
use sq_core_model::{AnimatedProperty, BlendMode, Clip, ClipAnimation, ClipEffect, ClipSpeed, TrackKind};
use sq_core_time::{IdSource, KeyframeTrack, KeyframeValue, Time, TimeRange, Vec2};
use sq_prproj_reader::inflate::{MAX_PROJECT_SIZE, gzip_inflate};
use sq_prproj_reader::{ImportError, Node};
use std::collections::{BTreeMap, BTreeSet};

/// One effect of a preset with its timing frame.
#[derive(Debug, Clone)]
pub struct PRPresetFilter {
    /// Premiere's preset type: 0 Scale (keys stretch with the clip), 1 Anchor to In Point, 2 Anchor to Out Point.
    pub kind: i64,
    /// The saved clip's source range (ticks); key times are absolute in that range.
    pub anchor_in: i64,
    pub anchor_out: i64,
    pub speed: f64,
    /// Audio only: 0 mono, 1 stereo, 2 5.1. Premiere saves one instance per channel type.
    pub channel_type: Option<i64>,
    pub component: PRComponent,
    /// Object id of the FilterPreset (dedupes shortcut copies of a folder).
    pub object_id: String,
}

impl PRPresetFilter {
    /// How key times follow the clip the preset lands on.
    pub fn anchor(&self) -> Anchor {
        match self.kind {
            1 => Anchor::Start,
            2 => Anchor::End,
            _ => Anchor::Stretch,
        }
    }

    /// Length of the clip the preset was saved from.
    pub fn reference_duration(&self) -> Time {
        PRTicks::time((self.anchor_out - self.anchor_in).max(0))
    }
}

/// A preset leaf of the tree.
#[derive(Debug, Clone)]
pub struct PRPreset {
    /// Folders below the root bin, outermost first.
    pub folders: Vec<String>,
    pub name: String,
    pub filters: Vec<PRPresetFilter>,
    /// Other folders listing the same preset (a folder added again as a shortcut, or copied into another folder).
    pub alias_folders: Vec<Vec<String>>,
}

impl PRPreset {
    /// "Folder / Folder / Name".
    pub fn path(&self) -> String {
        self.folders.iter().chain(std::iter::once(&self.name)).cloned().collect::<Vec<_>>().join(" / ")
    }

    /// The content (timing + every param), independent of object ids.
    fn signature(&self) -> String {
        self.filters
            .iter()
            .map(|f| {
                format!(
                    "{}|{}|{}|{}|{:?}",
                    f.kind,
                    f.anchor_out - f.anchor_in,
                    f.channel_type.unwrap_or(-1),
                    f.component.match_name,
                    f.component.params
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// Reads .prfpset files.
pub struct PRPresetReader;

struct Walk<'a> {
    t: &'a ObjectTable,
    out: Vec<PRPreset>,
    seen_filters: BTreeMap<Vec<String>, usize>,
    visited: BTreeSet<String>,
}

impl Walk<'_> {
    fn walk(&mut self, n: &Node, folders: &[String]) {
        if let Some(id) = n.object_id()
            && !self.visited.insert(id.to_string())
        {
            return;
        }
        let name = n.text_at("TreeItemBase/Name").unwrap_or("").to_string();
        if n.child("Items").is_some() {
            let mut below = folders.to_vec();
            below.push(name);
            for item in n.children_at("Items/Item") {
                if let Some(c) = self.t.deref(Some(item)) {
                    self.walk(c, &below);
                }
            }
            return;
        }
        let Some(data) = self.t.deref(n.child("TreeItemBase/Data")).filter(|d| d.name == "FilterPresetItem") else {
            return;
        };
        let refs: Vec<String> = data
            .children_at("FilterPresets/FilterPreset")
            .into_iter()
            .filter_map(|r| r.reference().map(str::to_string))
            .collect();
        if refs.is_empty() {
            return;
        }
        let below: Vec<String> = folders.iter().skip(1).cloned().collect();
        if let Some(&i) = self.seen_filters.get(&refs) {
            self.out[i].alias_folders.push(below);
            return;
        }
        self.seen_filters.insert(refs.clone(), self.out.len());
        let filters =
            refs.iter().filter_map(|r| self.t.get(r).and_then(|f| PRPresetReader::filter(f, self.t))).collect();
        self.out.push(PRPreset { folders: below, name, filters, alias_folders: Vec::new() });
    }
}

impl PRPresetReader {
    /// Every preset leaf in tree order. A preset whose filters are already listed (a shortcut copy of a folder) is not
    /// repeated: its folder joins the first one's `alias_folders`.
    pub fn read(data: &[u8]) -> Result<Vec<PRPreset>, ImportError> {
        let t = ObjectTable::new(&gzip_inflate(data, MAX_PROJECT_SIZE)?)?;
        let tree = t.get("1").or_else(|| all_named(&t, "Tree").into_iter().next());
        let Some(root) = tree.and_then(|tree| t.deref(tree.child("RootBin"))) else {
            return Err(ImportError::NotPremiereProject);
        };
        let mut w = Walk { t: &t, out: Vec::new(), seen_filters: BTreeMap::new(), visited: BTreeSet::new() };
        w.walk(root, &[]);
        Ok(w.out)
    }

    fn filter(f: &Node, t: &ObjectTable) -> Option<PRPresetFilter> {
        let c = t.deref(f.child("Component"))?;
        let comp = PRReader::component(c, t)?;
        let channel = if c.name == "AudioFilterComponent" {
            c.text_at("AudioComponent/ChannelType").and_then(|s| s.parse().ok())
        } else {
            None
        };
        Some(PRPresetFilter {
            kind: f.text_at("Type").and_then(|s| s.parse().ok()).unwrap_or(0),
            anchor_in: f.int_at("AnchorInPoint").unwrap_or(0),
            anchor_out: f.int_at("AnchorOutPoint").unwrap_or(0),
            speed: PRParamValue::double(f.text_at("Speed")).unwrap_or(1.0),
            channel_type: channel,
            component: comp,
            object_id: f.object_id().unwrap_or("").to_string(),
        })
    }
}

/// A Premiere preset as an SQ effect preset.
#[derive(Debug, Clone)]
pub struct PRMappedPreset {
    /// Library name: the preset's own name, with its folder added when another imported preset has the same name.
    pub name: String,
    pub path: String,
    pub preset: EffectPreset,
    /// What was approximated or dropped for this preset (empty = 1:1).
    pub notes: Vec<String>,
}

/// A preset that was not imported, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skipped {
    pub path: String,
    pub reason: String,
}

/// The result of mapping a preset file.
#[derive(Debug, Clone)]
pub struct PRPresetImport {
    pub presets: Vec<PRMappedPreset>,
    pub skipped: Vec<Skipped>,
    pub report: PRImportReport,
}

/// Maps Premiere presets to SQ effect presets.
pub struct PRPresetMapper;

/// Dropped parts that leave the rest of a preset usable (imported with a note).
const PARTIAL_DROPS: [&str; 2] = ["Volume in a preset", "Blend mode in a preset"];

impl PRPresetMapper {
    /// Folders never imported (none: the maintainer wants his Zoom Transition presets, 2026-10-25).
    pub fn ignored_folders() -> BTreeSet<String> {
        BTreeSet::new()
    }

    /// `frame`: the picture size positions and anchors are converted against (Premiere stores them normalized).
    pub fn map(
        presets: &[PRPreset],
        frame: (i64, i64),
        ignored: &BTreeSet<String>,
        ids: &mut dyn IdSource,
    ) -> PRPresetImport {
        let mut out: Vec<PRMappedPreset> = Vec::new();
        let mut skipped = Vec::new();
        let mut report = PRImportReport::default();
        let mut signatures = BTreeSet::new();
        for p in presets {
            if std::iter::once(&p.folders).chain(&p.alias_folders).any(|f| f.iter().any(|x| ignored.contains(x))) {
                skipped.push(Skipped { path: p.path(), reason: "ignored folder".into() });
                continue;
            }
            // Same name, same content (a preset saved twice): import once.
            if !signatures.insert(format!("{}\n{}", p.name, p.signature())) {
                continue;
            }
            let (preset, r) = Self::map_one(p, frame, ids);
            for e in r.entries() {
                for _ in 0..e.count {
                    report.note(&e.feature, e.status, &e.note);
                }
            }
            // An effect SQ cannot do would leave a different look or sound than the preset promises: not imported.
            let missing: Vec<String> = r
                .entries()
                .iter()
                .filter(|e| e.status == Status::Dropped && !PARTIAL_DROPS.contains(&e.feature.as_str()))
                .map(|e| if e.note.is_empty() { e.feature.clone() } else { format!("{} ({})", e.feature, e.note) })
                .collect();
            let Some(preset) = preset.filter(|p| !p.is_empty() && missing.is_empty()) else {
                let reason = if missing.is_empty() {
                    "nothing to import".to_string()
                } else {
                    format!("no SQ equivalent: {}", missing.join(", "))
                };
                skipped.push(Skipped { path: p.path(), reason });
                continue;
            };
            let notes = r
                .entries()
                .iter()
                .filter(|e| e.status != Status::Mapped)
                .map(|e| {
                    format!("{}: {}", e.status.label(), e.feature)
                        + &if e.note.is_empty() { String::new() } else { format!(" ({})", e.note) }
                })
                .collect();
            out.push(PRMappedPreset { name: p.name.clone(), path: p.path(), preset, notes });
        }
        // Same name, other content: add the folder.
        let mut counts: BTreeMap<String, usize> = BTreeMap::new();
        for m in &out {
            *counts.entry(m.name.clone()).or_default() += 1;
        }
        for m in &mut out {
            if counts.get(&m.name).copied().unwrap_or(0) > 1
                && let Some(folder) = presets.iter().find(|p| p.path() == m.path).and_then(|p| p.folders.last())
            {
                m.name = format!("{} ({folder})", m.name);
            }
        }
        PRPresetImport { presets: out, skipped, report }
    }

    /// One preset; `None` when it has no filters.
    fn map_one(p: &PRPreset, size: (i64, i64), ids: &mut dyn IdSource) -> (Option<EffectPreset>, PRImportReport) {
        // Audio: Premiere keeps a mono, stereo and 5.1 instance of every effect; the stereo one is the one edited.
        let channels: BTreeSet<i64> = p.filters.iter().filter_map(|f| f.channel_type).collect();
        let channel = if channels.contains(&1) { Some(1) } else { channels.first().copied() };
        let filters: Vec<&PRPresetFilter> =
            p.filters.iter().filter(|f| f.channel_type.is_none() || f.channel_type == channel).collect();
        let Some(&first) = filters.first() else { return (None, PRImportReport::default()) };
        let seq = PRSequence {
            id: "preset".into(),
            name: "Preset".into(),
            width: size.0,
            height: size.1,
            frame_duration: Time::new(1, 30),
            video_tracks: Vec::new(),
            audio_tracks: Vec::new(),
            markers: Vec::new(),
        };
        let doc = PRDocument { sequences: Vec::new() };
        let mut m = Mapping::new(&doc, &BTreeMap::new(), ids);
        let frame = Vec2::new(size.0 as f64, size.1 as f64);
        let mut preset = EffectPreset::new(first.anchor(), first.reference_duration());
        let defaults = ClipAnimation::default();
        for f in filters.iter().copied() {
            if f.speed != 1.0 {
                m.report.note("Preset clip speed", Status::Approximated, "keys read at 100 %");
            }
            // Key times into the first filter's frame (all of the maintainer's presets share one frame; mixed ones are
            // approximated).
            let (anchor, r, r0) = (f.anchor(), f.reference_duration(), first.reference_duration());
            let retime: Box<dyn Fn(Time) -> Time> = if anchor == first.anchor() {
                match anchor {
                    Anchor::Start => Box::new(|t| t),
                    Anchor::End => Box::new(move |t| t - r + r0),
                    Anchor::Stretch => Box::new(move |t| EffectPreset::map_time(t, Anchor::Stretch, r, r0)),
                }
            } else {
                m.report.note("Preset with mixed anchors", Status::Approximated, "keys placed as on the saved clip");
                Box::new(move |t| EffectPreset::map_time(t, anchor, r, r0))
            };
            let ctx = ClipContext { in_point: f.anchor_in, speed: ClipSpeed::NORMAL, sequence: &seq };
            let c = &f.component;
            let item = PRItem {
                name: p.name.clone(),
                start: 0,
                end: f.anchor_out - f.anchor_in,
                in_point: f.anchor_in,
                out_point: f.anchor_out,
                speed: 1.0,
                source: PRSource::Unknown,
                components: vec![c.clone()],
                is_adjustment_layer: false,
                is_audio: c.is_audio,
                clip_gain: 1.0,
                markers: Vec::new(),
            };
            if c.is_audio {
                let (id, media) = (m.ids.next_id(), m.ids.next_id());
                let mut clip = Clip::new(
                    id,
                    &p.name,
                    media,
                    TrackKind::Audio,
                    TimeRange::new(Time::ZERO, f.reference_duration()),
                    Time::ZERO,
                );
                m.audio(&item, &ctx, &mut clip);
                if clip.animation.volume.is_animated() || clip.animation.volume.value != 1.0 {
                    m.report.note("Volume in a preset", Status::Dropped, "SQ presets carry no clip volume");
                }
                preset.effects.extend(clip.effects.iter().map(|e| retimed_effect(e, &*retime)));
                continue;
            }
            if c.match_name == "AE.ADBE Motion" || c.match_name == "AE.ADBE Opacity" {
                // Only what the preset changes (keyed or not at its default), as a preset saved in SQ.
                let a = m.motion(&item, &ctx, frame, Vec2::ZERO, 1.0);
                if c.match_name == "AE.ADBE Motion" {
                    preset.position = take(&a.position, &defaults.position, &*retime).or(preset.position);
                    preset.scale = take(&a.scale, &defaults.scale, &*retime).or(preset.scale);
                    preset.rotation = take(&a.rotation, &defaults.rotation, &*retime).or(preset.rotation);
                    preset.anchor_point = take(&a.anchor, &defaults.anchor, &*retime).or(preset.anchor_point);
                    if preset.position.is_some() || preset.anchor_point.is_some() {
                        m.report.note(
                            "Motion position / anchor in a preset",
                            Status::Approximated,
                            &format!("pixels of a {}x{} frame", size.0, size.1),
                        );
                    }
                } else {
                    preset.opacity = take(&a.opacity, &defaults.opacity, &*retime).or(preset.opacity);
                    if m.blend_mode(&item) != BlendMode::Normal {
                        m.report.note("Blend mode in a preset", Status::Dropped, "SQ presets carry no blend mode");
                    }
                }
            }
            let fx = m.effects(&item, &ctx, frame, Vec2::ZERO);
            if c.match_name == "AE.ADBE Geometry2"
                && PRParamValue::point(c.param(1).and_then(|p| p.static_value.as_deref()))
                    .unwrap_or(Vec2::new(0.5, 0.5))
                    != Vec2::new(0.5, 0.5)
            {
                m.report.note(
                    "Transform anchor in a preset",
                    Status::Approximated,
                    &format!("pixels of a {}x{} frame", size.0, size.1),
                );
            }
            preset.effects.extend(fx.iter().map(|e| retimed_effect(e, &*retime)));
        }
        preset.effects = voice_chain_ordered(std::mem::take(&mut preset.effects));
        (Some(preset), std::mem::take(&mut m.report))
    }
}

/// `v` retimed when it is keyed or differs from the default `d`.
fn take<V: KeyframeValue>(
    v: &AnimatedProperty<V>,
    d: &AnimatedProperty<V>,
    f: &dyn Fn(sq_core_time::Time) -> sq_core_time::Time,
) -> Option<AnimatedProperty<V>> {
    (v.is_animated() || v.value != d.value).then(|| retimed(v, f))
}

/// A .prfpset stores the effects grouped per effect type in no meaningful order (the maintainer's NTG preset is stored
/// Multiband, Noise Reduction, EQ; Premiere applies it as EQ, Compressor, Noise Reduction; the file has no index field). The
/// voice chain effects are put in Premiere's applied order, other effects keep their slots.
fn voice_chain_ordered(effects: Vec<ClipEffect>) -> Vec<ClipEffect> {
    let order = [ae::AUDIO_PARAMETRIC_EQ_KIND, ae::AUDIO_MULTIBAND_KIND, ae::AUDIO_NOISE_REDUCTION_KIND];
    let position = |kind: &str| order.iter().position(|k| *k == kind);
    let slots: Vec<usize> = (0..effects.len()).filter(|&i| position(&effects[i].kind).is_some()).collect();
    let mut sorted: Vec<(usize, &ClipEffect)> = slots.iter().map(|&i| &effects[i]).enumerate().collect();
    sorted.sort_by_key(|(offset, e)| (position(&e.kind), *offset));
    let ordered: Vec<ClipEffect> = sorted.into_iter().map(|(_, e)| e.clone()).collect();
    let mut out = effects;
    for (slot, e) in slots.into_iter().zip(ordered) {
        out[slot] = e;
    }
    out
}

fn retimed<V: KeyframeValue>(p: &AnimatedProperty<V>, f: &dyn Fn(Time) -> Time) -> AnimatedProperty<V> {
    let mut c = p.clone();
    c.track = KeyframeTrack::with_keys(
        p.track
            .keys
            .iter()
            .map(|k| {
                let mut k = k.clone();
                k.time = f(k.time);
                k
            })
            .collect(),
    );
    c
}

fn retimed_effect(e: &ClipEffect, f: &dyn Fn(Time) -> Time) -> ClipEffect {
    let mut e = e.clone();
    e.parameters = e.parameters.iter().map(|(k, v)| (k.clone(), retimed(v, f))).collect();
    e.colors = e.colors.iter().map(|(k, v)| (k.clone(), retimed(v, f))).collect();
    e.points = e.points.iter().map(|(k, v)| (k.clone(), retimed(v, f))).collect();
    e
}
