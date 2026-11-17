// Swift: ProjectTemplate.swift (`addVariant` is inlined with its size check: the edit crate has no variant list verbs
// yet; `TemplateFolder` takes an `IdSource` where Swift mints UUIDs)
//! A starting point for a new project: sequence format, track counts and format variants, plus (user templates) the
//! media-free clips of the sequence it was saved from: title lines, emoji, adjustment layers and their element
//! transitions, so a new video starts with the title in place and only the text is replaced. Lives in its own
//! `.sqtemplate` file (never inside the project file). Built-ins cover the start window's 9:16 / 16:9 / Variants cards.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use sq_core_model::{
    ConformMode, DeliveryPlatform, DeliveryTarget, FormatVariant, Project, SequenceDefaults, SequenceFormat, StyleKit,
    Timeline, Track,
};
use sq_core_time::{Id, IdSource, Time};

use crate::sequence_format_presets::{SequenceFormatPresets, delivery_target};

/// A format variant a template adds to new sequences.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct VariantSpec {
    pub name: String,
    pub width: i64,
    pub height: i64,
}

/// Why a template is refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invalid {
    EmptyName,
    BadSize,
}

impl std::fmt::Display for Invalid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Invalid::EmptyName => "The template needs a name.",
            Invalid::BadSize => "The video size is not valid.",
        })
    }
}

/// A starting point for a new project.
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectTemplate {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub format: SequenceFormat,
    pub video_tracks: i64,
    pub audio_tracks: i64,
    pub variants: Vec<VariantSpec>,
    pub delivery_target: Option<DeliveryTarget>,
    /// The template sequence with only its generator clips (text, shapes, adjustment layers) and the transitions between
    /// them; no media, captions, markers or In/Out. `None` = an empty sequence of `video_tracks` + `audio_tracks`.
    pub content: Option<Timeline>,
    /// The Style Kit (caption look, fonts, colors) the template was saved with; a new project starts with it.
    pub style_kit: Option<StyleKit>,
}

impl ProjectTemplate {
    /// Most tracks of one kind a template creates.
    pub const MAX_TRACKS: i64 = 16;

    /// On-disk format. 2 (G11): the content has a graphics layer that follows another; it is then written under
    /// `contentV2`, so a build without Follow drops it (as any content it cannot read) instead of drawing the followers
    /// where they were authored. 3: the content has Fast Cut attachments between its graphics (v67 field); a build without
    /// Fast Cut drops the content instead of losing them silently. 4: an item of a Graphic has a range
    /// (`GraphicsLayer.range`, v74 field); a build without item ranges drops the content instead of drawing every item for
    /// the whole clip. Templates without any of these write no version and stay byte-identical.
    pub const FORMAT_VERSION: i64 = 4;

    /// A template with no content, style kit or variants.
    pub fn new(id: &str, name: &str, summary: &str, format: SequenceFormat) -> ProjectTemplate {
        ProjectTemplate {
            id: id.to_string(),
            name: name.to_string(),
            summary: summary.to_string(),
            format,
            video_tracks: SequenceDefaults::VIDEO_TRACK_COUNT as i64,
            audio_tracks: SequenceDefaults::AUDIO_TRACK_COUNT as i64,
            variants: Vec::new(),
            delivery_target: None,
            content: None,
            style_kit: None,
        }
    }

    /// True when new projects start with clips (titles, emoji, adjustment layers).
    pub fn has_content(&self) -> bool {
        self.content.as_ref().is_some_and(|c| c.tracks.iter().any(|t| !t.clips().is_empty()))
    }

    /// The format version this template is written with.
    pub fn written_format_version(&self) -> i64 {
        let Some(c) = &self.content else { return 1 };
        if contains_item_ranges(c) {
            4
        } else if c.has_attachments() {
            3
        } else if contains_follow(c) {
            2
        } else {
            1
        }
    }

    /// An id for a template saved by the user: `user-` plus a fresh id.
    pub fn user_id(ids: &mut dyn IdSource) -> String {
        format!("user-{}", ids.next_id())
    }

    /// Captures the sequence's format, track counts, variants, delivery target and its media-free clips (`content`).
    pub fn capturing(t: &Timeline, name: &str, style_kit: Option<StyleKit>, id: &str) -> ProjectTemplate {
        let content = graphics_only(t);
        let n: usize = content.as_ref().map_or(0, |c| c.tracks.iter().map(|tr| tr.clips().len()).sum());
        let count = |kind| i64::try_from(t.tracks.iter().filter(|tr| tr.kind == kind).count()).unwrap_or(i64::MAX);
        let mut template = ProjectTemplate::new(
            id,
            name,
            &format!(
                "{} × {}{}",
                t.format.width,
                t.format.height,
                if n > 0 { format!(", {n} graphics") } else { String::new() }
            ),
            t.format.clone(),
        );
        template.video_tracks = count(sq_core_model::TrackKind::Video);
        template.audio_tracks = count(sq_core_model::TrackKind::Audio);
        template.variants =
            t.variants.iter().map(|v| VariantSpec { name: v.name.clone(), width: v.width, height: v.height }).collect();
        template.delivery_target = t.delivery_target.clone();
        template.content = content;
        template.style_kit = style_kit;
        template
    }

    /// First unused name: "Reel", "Reel 2", "Reel 3"... (case-insensitive, trimmed).
    pub fn free_name(base: &str, taken: &[String]) -> String {
        let base = base.trim();
        let used: BTreeSet<String> = taken.iter().map(|t| t.to_lowercase()).collect();
        let mut name = base.to_string();
        let mut n = 1;
        while used.contains(&name.to_lowercase()) {
            n += 1;
            name = format!("{base} {n}");
        }
        name
    }

    /// A template needs a name and positive, sane sizes (format and variants).
    pub fn validate(&self) -> Result<(), Invalid> {
        if self.name.trim().is_empty() {
            return Err(Invalid::EmptyName);
        }
        let range = 1..=SequenceFormatPresets::MAX_DIMENSION;
        let sizes = std::iter::once((self.format.width, self.format.height))
            .chain(self.variants.iter().map(|v| (v.width, v.height)));
        if sizes.into_iter().all(|(w, h)| range.contains(&w) && range.contains(&h)) {
            Ok(())
        } else {
            Err(Invalid::BadSize)
        }
    }

    /// A ready project: one locked sequence (so imported footage never changes the format), 4V + 4A by default.
    pub fn make_project(&self, name: &str, ids: &mut dyn IdSource) -> Project {
        let project_id = ids.next_id();
        if let Some(content) = &self.content {
            let mut tl = content.clone();
            tl.id = ids.next_id();
            tl.name = "Sequence 01".to_string();
            tl.format = self.format.clone();
            tl.format_locked = true;
            tl.delivery_target = self.delivery_target.clone();
            let mut p = Project::new(project_id, name, vec![], vec![tl]);
            p.style_kit = self.style_kit.clone();
            return p;
        }
        let clamp = |n: i64| usize::try_from(n.clamp(0, Self::MAX_TRACKS)).unwrap_or(0);
        let tracks = Timeline::default_tracks(clamp(self.video_tracks), clamp(self.audio_tracks), ids);
        let mut tl = Timeline::new(ids.next_id(), "Sequence 01", self.format.clone(), tracks);
        tl.format_locked = true;
        tl.delivery_target = self.delivery_target.clone();
        for v in &self.variants {
            let valid = 1..=SequenceFormatPresets::MAX_DIMENSION;
            if valid.contains(&v.width) && valid.contains(&v.height) {
                tl.variants.push(FormatVariant {
                    id: ids.next_id(),
                    name: v.name.clone(),
                    width: v.width,
                    height: v.height,
                    conform: ConformMode::Fill,
                });
            }
        }
        let mut p = Project::new(project_id, name, vec![], vec![tl]);
        p.style_kit = self.style_kit.clone();
        p
    }

    /// A new sequence for an existing project (File > New Sequence from Template): same layout as `make_project`'s
    /// sequence, but the format stays unlocked like any other sequence.
    pub fn make_sequence(&self, name: &str, ids: &mut dyn IdSource) -> Timeline {
        let mut tl = self.make_project(name, ids).timelines.remove(0);
        tl.name = name.to_string();
        tl.format_locked = false;
        tl
    }

    /// Vertical 9:16 for TikTok, Reels and Shorts.
    pub fn vertical() -> ProjectTemplate {
        let mut t = ProjectTemplate::new(
            "builtin-vertical-9x16",
            "Vertical 9:16",
            "1080 × 1920, 30 fps. TikTok, Reels, Shorts.",
            sized(1080, 1920),
        );
        t.delivery_target = Some(delivery_target(DeliveryPlatform::Tiktok));
        t
    }

    /// Horizontal 16:9 for YouTube.
    pub fn horizontal() -> ProjectTemplate {
        let mut t = ProjectTemplate::new(
            "builtin-horizontal-16x9",
            "Horizontal 16:9",
            "1920 × 1080, 30 fps. YouTube.",
            sized(1920, 1080),
        );
        t.delivery_target = Some(delivery_target(DeliveryPlatform::Youtube));
        t
    }

    /// A 9:16 master with 16:9 and 1:1 variants.
    pub fn variants_template() -> ProjectTemplate {
        let mut t = ProjectTemplate::new(
            "builtin-variants",
            "Variants",
            "9:16 master with 16:9 and 1:1 variants.",
            sized(1080, 1920),
        );
        t.variants = vec![
            VariantSpec { name: "16:9".to_string(), width: 1920, height: 1080 },
            VariantSpec { name: "1:1".to_string(), width: 1080, height: 1080 },
        ];
        t.delivery_target = Some(delivery_target(DeliveryPlatform::Tiktok));
        t
    }

    /// The three built-in templates.
    pub fn built_in() -> Vec<ProjectTemplate> {
        vec![Self::vertical(), Self::horizontal(), Self::variants_template()]
    }
}

fn sized(width: i64, height: i64) -> SequenceFormat {
    let mut f = SequenceFormat::new(Time::new(1, 30));
    f.width = width;
    f.height = height;
    f
}

/// Some item of a Graphic in this sequence has a range: templates gate their format on it too (a build without item
/// ranges would draw every item for the whole clip).
fn contains_item_ranges(t: &Timeline) -> bool {
    t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.graphics_store.as_ref().is_some_and(|g| g.has_item_ranges())))
}

/// Any graphics layer of this sequence's clips follows something (G11): templates gate their format on it too.
fn contains_follow(t: &Timeline) -> bool {
    t.tracks.iter().any(|tr| {
        tr.clips()
            .iter()
            .any(|c| c.graphics_store.as_ref().is_some_and(|g| g.layers.iter().any(|l| l.follow.is_some())))
    })
}

/// `t` with only its generator clips (and the transitions that touch nothing else); `None` when none is left. Track
/// layout, names, locks and audio roles stay; media, nested sequences, captions, markers and In/Out go.
fn graphics_only(t: &Timeline) -> Option<Timeline> {
    let mut out = t.clone();
    out.markers = Vec::new();
    out.in_out = None;
    out.in_out_kind = None;
    out.caption_tracks = Vec::new();
    out.group = None;
    // A new sequence's edit mode comes from the preference, not from the template; attachments to clips that are not
    // kept (media) go, those between kept graphics stay (and gate the format, see `written_format_version`).
    out.set_edit_mode_stored(sq_core_model::TimelineEditMode::Normal);
    out.tracks = t
        .tracks
        .iter()
        .map(|tr| {
            let kept: Vec<_> = tr.clips().iter().filter(|c| c.generator.is_some()).cloned().collect();
            let ids: BTreeSet<Id> = kept.iter().map(|c| c.id).collect();
            let transitions = tr
                .transitions
                .iter()
                .filter(|x| [x.incoming, x.outgoing].into_iter().flatten().all(|i| ids.contains(&i)))
                .cloned()
                .collect();
            let mut n = Track::new(tr.id, tr.kind);
            n.set_clips(kept);
            n.is_locked = tr.is_locked;
            n.sync_lock = tr.sync_lock;
            n.name = tr.name.clone();
            n.is_visible = tr.is_visible;
            n.is_muted = tr.is_muted;
            n.is_solo = tr.is_solo;
            n.is_targeted = tr.is_targeted;
            n.height = tr.height;
            n.transitions = transitions;
            n.volume_db = tr.volume_db;
            n.pan = tr.pan;
            n.audio_role = tr.audio_role;
            n
        })
        .collect();
    out.drop_attachments_to_missing_hosts();
    if out.tracks.iter().any(|tr| !tr.clips().is_empty()) { Some(out) } else { None }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TemplateOut<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    format_version: Option<i64>,
    id: &'a str,
    name: &'a str,
    summary: &'a str,
    format: &'a SequenceFormat,
    video_tracks: i64,
    audio_tracks: i64,
    variants: &'a [VariantSpec],
    #[serde(skip_serializing_if = "Option::is_none")]
    delivery_target: &'a Option<DeliveryTarget>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<&'a Timeline>,
    #[serde(rename = "contentV2", skip_serializing_if = "Option::is_none")]
    content_v2: Option<&'a Timeline>,
    #[serde(skip_serializing_if = "Option::is_none")]
    style_kit: &'a Option<StyleKit>,
}

impl Serialize for ProjectTemplate {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let v = self.written_format_version();
        TemplateOut {
            format_version: (v > 1).then_some(v),
            id: &self.id,
            name: &self.name,
            summary: &self.summary,
            format: &self.format,
            video_tracks: self.video_tracks,
            audio_tracks: self.audio_tracks,
            variants: &self.variants,
            delivery_target: &self.delivery_target,
            content: if v > 1 { None } else { self.content.as_ref() },
            content_v2: if v > 1 { self.content.as_ref() } else { None },
            style_kit: &self.style_kit,
        }
        .serialize(s)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TemplateIn {
    id: String,
    name: String,
    #[serde(default)]
    summary: Option<String>,
    format: SequenceFormat,
    #[serde(default)]
    video_tracks: Option<i64>,
    #[serde(default)]
    audio_tracks: Option<i64>,
    #[serde(default)]
    variants: Option<Vec<VariantSpec>>,
    #[serde(default)]
    delivery_target: Option<DeliveryTarget>,
    #[serde(default)]
    format_version: Option<Value>,
    #[serde(default)]
    content: Option<Value>,
    #[serde(default, rename = "contentV2")]
    content_v2: Option<Value>,
    #[serde(default)]
    style_kit: Option<Value>,
}

impl<'de> Deserialize<'de> for ProjectTemplate {
    /// Content a build cannot read (a newer build saved it) is dropped; the template itself still loads.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<ProjectTemplate, D::Error> {
        let w = TemplateIn::deserialize(d)?;
        let v = w.format_version.as_ref().and_then(Value::as_i64).unwrap_or(1);
        let content = if v > ProjectTemplate::FORMAT_VERSION {
            None
        } else {
            let raw = if v > 1 { w.content_v2 } else { w.content };
            raw.and_then(|c| serde_json::from_value::<Timeline>(c).ok())
        };
        Ok(ProjectTemplate {
            id: w.id,
            name: w.name,
            summary: w.summary.unwrap_or_default(),
            format: w.format,
            video_tracks: w.video_tracks.unwrap_or(SequenceDefaults::VIDEO_TRACK_COUNT as i64),
            audio_tracks: w.audio_tracks.unwrap_or(SequenceDefaults::AUDIO_TRACK_COUNT as i64),
            variants: w.variants.unwrap_or_default(),
            delivery_target: w.delivery_target,
            content,
            style_kit: w.style_kit.and_then(|s| serde_json::from_value::<StyleKit>(s).ok()),
        })
    }
}

/// Why a template could not be saved, renamed or deleted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TemplateError {
    Invalid(Invalid),
    /// A file system call or the encoding failed.
    Io(String),
}

impl From<Invalid> for TemplateError {
    fn from(i: Invalid) -> TemplateError {
        TemplateError::Invalid(i)
    }
}

/// A folder of `.sqtemplate` files (JSON, one template each). Unreadable files are skipped.
pub struct TemplateFolder {
    pub path: PathBuf,
}

impl TemplateFolder {
    pub const FILE_EXTENSION: &'static str = "sqtemplate";

    pub fn new(path: &Path) -> TemplateFolder {
        TemplateFolder { path: path.to_path_buf() }
    }

    fn file(&self, t: &ProjectTemplate) -> PathBuf {
        let safe: String =
            t.id.chars().map(|c| if c.is_alphabetic() || c.is_numeric() || c == '-' { c } else { '_' }).collect();
        self.path.join(format!("{safe}.{}", Self::FILE_EXTENSION))
    }

    /// Validates and writes the template (pretty printed, keys sorted).
    pub fn save(&self, t: &ProjectTemplate) -> Result<(), TemplateError> {
        t.validate()?;
        let io = |e: std::io::Error| TemplateError::Io(e.to_string());
        std::fs::create_dir_all(&self.path).map_err(io)?;
        let value = sq_core_time::json_sorted::to_value(t).map_err(|e| TemplateError::Io(e.to_string()))?;
        let data = serde_json::to_vec_pretty(&value).map_err(|e| TemplateError::Io(e.to_string()))?;
        let file = self.file(t);
        let tmp = file.with_extension("tmp");
        std::fs::write(&tmp, data).map_err(io)?;
        std::fs::rename(&tmp, &file).map_err(io)
    }

    /// Renames in place (same id, same file). Fails with `EmptyName` for a blank name.
    pub fn rename(&self, t: &ProjectTemplate, name: &str) -> Result<ProjectTemplate, TemplateError> {
        let mut n = t.clone();
        n.name = name.trim().to_string();
        self.save(&n)?;
        Ok(n)
    }

    /// Removes the template's file.
    pub fn delete(&self, t: &ProjectTemplate) -> Result<(), TemplateError> {
        std::fs::remove_file(self.file(t)).map_err(|e| TemplateError::Io(e.to_string()))
    }

    /// Sorted by name. Invalid templates are skipped; an id that collides with a built-in or an earlier template is
    /// replaced by a fresh `user-` id.
    // Names sort by lowercase text, not by ICU `localizedCaseInsensitiveCompare` (the portable core has no locale tables).
    pub fn load(&self, ids: &mut dyn IdSource) -> Vec<ProjectTemplate> {
        let mut files: Vec<PathBuf> = std::fs::read_dir(&self.path)
            .map(|rd| {
                rd.filter_map(Result::ok)
                    .map(|e| e.path())
                    .filter(|p| p.extension().and_then(|e| e.to_str()) == Some(Self::FILE_EXTENSION))
                    .collect()
            })
            .unwrap_or_default();
        files.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
        let mut seen: BTreeSet<String> = ProjectTemplate::built_in().into_iter().map(|t| t.id).collect();
        let mut out: Vec<ProjectTemplate> = Vec::new();
        for f in files {
            let Some(mut t) = std::fs::read(&f).ok().and_then(|d| serde_json::from_slice::<ProjectTemplate>(&d).ok())
            else {
                continue;
            };
            if t.validate().is_err() {
                continue;
            }
            if !seen.insert(t.id.clone()) {
                t.id = ProjectTemplate::user_id(ids);
                seen.insert(t.id.clone());
            }
            out.push(t);
        }
        out.sort_by_key(|t| t.name.to_lowercase());
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, GeneratorRef, Marker, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn temp(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("{tag}-{}", std::process::id()))
    }

    fn counts(tl: &Timeline) -> (usize, usize) {
        let n = |k| tl.tracks.iter().filter(|t| t.kind == k).count();
        (n(TrackKind::Video), n(TrackKind::Audio))
    }

    #[test]
    fn vertical_template_is_one_step_to_a_916_project() {
        let t =
            ProjectTemplate::built_in().into_iter().find(|t| t.id == ProjectTemplate::vertical().id).expect("vertical");
        let p = t.make_project("Reel", &mut SequentialIds::default());
        let tl = &p.timelines[0];
        assert_eq!(p.name, "Reel");
        assert!(tl.format.width == 1080 && tl.format.height == 1920 && tl.format_locked);
        assert_eq!(counts(tl), (4, 4));
        assert_eq!(tl.delivery_target.as_ref().map(|d| d.platform), Some(DeliveryPlatform::Tiktok));
    }

    #[test]
    fn horizontal_template_is_169() {
        let tl = ProjectTemplate::horizontal().make_project("x", &mut SequentialIds::default()).timelines.remove(0);
        assert!(tl.format.width == 1920 && tl.format.height == 1080);
    }

    #[test]
    fn variants_template_adds_variants() {
        let tl =
            ProjectTemplate::variants_template().make_project("x", &mut SequentialIds::default()).timelines.remove(0);
        assert_eq!(tl.format.height, 1920);
        assert_eq!(tl.variants.iter().map(|v| (v.width, v.height)).collect::<Vec<_>>(), [(1920, 1080), (1080, 1080)]);
    }

    #[test]
    fn built_in_ids_are_unique() {
        let ids: BTreeSet<String> = ProjectTemplate::built_in().into_iter().map(|t| t.id).collect();
        assert_eq!(ids.len(), ProjectTemplate::built_in().len());
    }

    #[test]
    fn template_from_timeline_round_trips() {
        let mut ids = SequentialIds::default();
        let mut format = SequenceFormat::new(Time::new(1, 25));
        format.width = 1080;
        format.height = 1350;
        let mut tl = Timeline::new(Id::from_u128(900), "S", format, Timeline::default_tracks(2, 4, &mut ids));
        tl.variants.push(FormatVariant {
            id: Id::from_u128(901),
            name: "Wide".into(),
            width: 1920,
            height: 1080,
            conform: ConformMode::Fill,
        });
        let t = ProjectTemplate::capturing(&tl, "Mine", None, "user-x");
        let back: ProjectTemplate = serde_json::from_slice(&serde_json::to_vec(&t).expect("encode")).expect("decode");
        assert_eq!(back, t);
        let made = back.make_project("P", &mut ids).timelines.remove(0);
        assert!(made.format.height == 1350 && made.format.frame_duration == Time::new(1, 25));
        assert_eq!(counts(&made).1, 4);
        assert_eq!(made.variants.len(), 1);
    }

    #[test]
    fn track_counts_are_clamped() {
        let mut t = ProjectTemplate::vertical();
        t.video_tracks = 99;
        t.audio_tracks = -3;
        let tl = t.make_project("x", &mut SequentialIds::default()).timelines.remove(0);
        assert_eq!(counts(&tl), (ProjectTemplate::MAX_TRACKS as usize, 0));
    }

    #[test]
    fn folder_stores_and_lists_user_templates() {
        let dir = temp("tpl");
        let folder = TemplateFolder::new(&dir);
        let mut t = ProjectTemplate::vertical();
        t.id = "user-1".into();
        t.name = "Mine".into();
        assert_eq!(folder.save(&t), Ok(()));
        let _ = std::fs::write(dir.join("bad.sqtemplate"), "junk");
        let mut ids = SequentialIds::default();
        assert_eq!(folder.load(&mut ids), vec![t.clone()]); // unreadable files are skipped
        assert_eq!(folder.delete(&t), Ok(()));
        assert!(folder.load(&mut ids).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn invalid_templates_are_refused() {
        let mut t = ProjectTemplate::vertical();
        t.id = "u1".into();
        let with = |f: &dyn Fn(&mut ProjectTemplate)| {
            let mut x = t.clone();
            f(&mut x);
            x.validate()
        };
        assert_eq!(with(&|x| x.name = "  ".into()), Err(Invalid::EmptyName));
        assert_eq!(with(&|x| x.format.width = 0), Err(Invalid::BadSize));
        assert_eq!(with(&|x| x.format.height = -5), Err(Invalid::BadSize));
        assert_eq!(
            with(&|x| x.variants = vec![VariantSpec { name: "v".into(), width: 0, height: 10 }]),
            Err(Invalid::BadSize)
        );
        assert_eq!(t.validate(), Ok(()));
        let dir = temp("tplv");
        let mut bad = t;
        bad.name = String::new();
        assert_eq!(TemplateFolder::new(&dir).save(&bad), Err(TemplateError::Invalid(Invalid::EmptyName)));
    }

    #[test]
    fn load_skips_invalid_and_fixes_colliding_ids() {
        let dir = temp("tplc");
        let _ = std::fs::create_dir_all(&dir);
        let write = |name: &str, t: &ProjectTemplate| {
            let _ = std::fs::write(dir.join(format!("{name}.sqtemplate")), serde_json::to_vec(t).unwrap_or_default());
        };
        let mk = |id: &str, name: &str| {
            let mut t = ProjectTemplate::vertical();
            t.id = id.into();
            t.name = name.into();
            t
        };
        let mut bad = mk("bad", "Bad");
        bad.format.width = 0;
        write("a", &mk(&ProjectTemplate::horizontal().id, "A")); // collides with a built-in
        write("b", &mk("dup", "B"));
        write("c", &mk("dup", "C")); // collides with B
        write("bad", &bad);
        let loaded = TemplateFolder::new(&dir).load(&mut SequentialIds::default());
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(loaded.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["A", "B", "C"]);
        let all: Vec<String> =
            loaded.iter().map(|t| t.id.clone()).chain(ProjectTemplate::built_in().into_iter().map(|t| t.id)).collect();
        assert_eq!(all.iter().collect::<BTreeSet<_>>().len(), all.len());
    }

    #[test]
    fn free_name_counts_up_case_insensitively() {
        let taken = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(ProjectTemplate::free_name("Reel", &[]), "Reel");
        assert_eq!(ProjectTemplate::free_name("Reel", &taken(&["reel"])), "Reel 2");
        assert_eq!(ProjectTemplate::free_name("Reel", &taken(&["Reel", "Reel 2"])), "Reel 3");
        assert_eq!(ProjectTemplate::free_name("  Reel ", &[]), "Reel");
        let names: Vec<String> = ProjectTemplate::built_in().into_iter().map(|t| t.name).collect();
        assert_ne!(
            ProjectTemplate::free_name(&ProjectTemplate::vertical().name, &names),
            ProjectTemplate::vertical().name
        );
    }

    #[test]
    fn rename_keeps_id_and_rejects_empty() {
        let dir = temp("tplr");
        let folder = TemplateFolder::new(&dir);
        let mut t = ProjectTemplate::vertical();
        t.id = "user-r".into();
        t.name = "Old".into();
        assert_eq!(folder.save(&t), Ok(()));
        let renamed = folder.rename(&t, "  New  ").expect("renamed");
        assert!(renamed.name == "New" && renamed.id == "user-r");
        let names: Vec<String> = folder.load(&mut SequentialIds::default()).into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["New"]);
        assert_eq!(folder.rename(&renamed, "  "), Err(TemplateError::Invalid(Invalid::EmptyName)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn make_sequence_is_unlocked_and_named() {
        let tl = ProjectTemplate::variants_template().make_sequence("Reel", &mut SequentialIds::default());
        assert_eq!(tl.name, "Reel");
        assert_eq!(tl.format, ProjectTemplate::variants_template().format);
        assert_eq!(tl.variants.len(), 2);
        assert!(!tl.format_locked);
    }

    /// V1 talking head (media), V2 + V3 title lines (text generators), V4 emoji, A1 music; one marker.
    fn template_sequence() -> Timeline {
        let mut ids = SequentialIds::default();
        let mut format = SequenceFormat::new(Time::new(1, 30));
        format.width = 1080;
        format.height = 1920;
        let mut tl = Timeline::new(Id::from_u128(900), "Template", format, Timeline::default_tracks(4, 1, &mut ids));
        let clip = |n: u128, kind, generator: bool| {
            let mut c = Clip::new(
                Id::from_u128(n),
                &format!("c{n}"),
                Id::from_u128(n + 500),
                kind,
                TimeRange::new(Time::ZERO, Time::new(3, 1)),
                Time::ZERO,
            );
            if generator {
                c.generator = Some(GeneratorRef { kind: "text".into(), payload: b"one".to_vec(), payload_version: 1 });
            }
            c
        };
        let plan = [
            (0, 1, TrackKind::Video, false),
            (1, 2, TrackKind::Video, true),
            (2, 3, TrackKind::Video, true),
            (3, 4, TrackKind::Video, true),
            (4, 5, TrackKind::Audio, false),
        ];
        for (ti, n, kind, generator) in plan {
            let mut c = clip(n, kind, generator);
            if n == 5 {
                c.kind = TrackKind::Audio;
            }
            tl.tracks[ti].set_clips(vec![c]);
        }
        tl.markers.push(Marker {
            id: Id::from_u128(777),
            time: Time::new(1, 1),
            name: "m".into(),
            color: Default::default(),
            comment: String::new(),
            duration: Time::ZERO,
        });
        tl.tracks[1].name = "Title".into();
        tl
    }

    #[test]
    fn capturing_keeps_generator_clips_and_drops_media() {
        let tl = template_sequence();
        let t = ProjectTemplate::capturing(&tl, "Mine", None, "user-c");
        let content = t.content.as_ref().expect("content");
        let clips: Vec<&Clip> = content.tracks.iter().flat_map(|tr| tr.clips().iter()).collect();
        assert_eq!(clips.len(), 3);
        assert!(clips.iter().all(|c| c.generator.is_some()) && !clips.iter().any(|c| c.id == Id::from_u128(1)));
        assert_eq!(content.tracks.len(), tl.tracks.len());
        assert_eq!(content.tracks[1].name, "Title");
        assert!(content.markers.is_empty());
        assert!(t.has_content());
        assert!(t.summary.contains("3 graphics"));
    }

    #[test]
    fn empty_sequence_captures_no_content() {
        let mut ids = SequentialIds::default();
        let tl = Timeline::new(
            Id::from_u128(1),
            "S",
            SequenceFormat::new(Time::new(1, 30)),
            Timeline::default_tracks(2, 2, &mut ids),
        );
        let t = ProjectTemplate::capturing(&tl, "Plain", None, "user-p");
        assert!(t.content.is_none() && !t.has_content());
    }

    #[test]
    fn new_project_starts_with_the_title_clips() {
        let tl = template_sequence();
        let t = ProjectTemplate::capturing(&tl, "Mine", None, "user-c");
        let made = t.make_project("Video 12", &mut SequentialIds::default());
        let m = &made.timelines[0];
        assert_eq!(made.name, "Video 12");
        assert!(m.id != tl.id && m.name == "Sequence 01" && m.format_locked && m.format.height == 1920);
        assert_eq!(counts(m), (4, 1));
        assert_eq!(m.tracks.iter().map(|t| t.clips().len()).sum::<usize>(), 3);
        assert!(m.in_out.is_none());
    }

    #[test]
    fn content_round_trips_through_the_template_folder() {
        let t = ProjectTemplate::capturing(&template_sequence(), "Mine", None, "user-c");
        let dir = temp("tplk");
        let folder = TemplateFolder::new(&dir);
        assert_eq!(folder.save(&t), Ok(()));
        let loaded = folder.load(&mut SequentialIds::default());
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(loaded.first(), Some(&t));
    }

    #[test]
    fn unreadable_content_keeps_the_template() {
        // A newer build may store content this build cannot read: the template still loads, just without the clips.
        let mut json = serde_json::to_value(ProjectTemplate::vertical()).expect("encode");
        json["content"] = serde_json::json!({"garbage": true});
        let t: ProjectTemplate = serde_json::from_value(json).expect("decode");
        assert!(t.content.is_none());
        assert_eq!(t.format, ProjectTemplate::vertical().format);
    }

    #[test]
    fn a_newer_format_drops_the_content_and_older_versions_read_plain_content() {
        let t = ProjectTemplate::capturing(&template_sequence(), "Mine", None, "user-c");
        let mut json = serde_json::to_value(&t).expect("encode");
        assert!(json.get("formatVersion").is_none() && json.get("content").is_some());
        let plain: ProjectTemplate = serde_json::from_value(json.clone()).expect("decode");
        assert_eq!(plain, t);
        json["formatVersion"] = 99.into();
        let newer: ProjectTemplate = serde_json::from_value(json).expect("decode");
        assert!(newer.content.is_none());
    }
}
