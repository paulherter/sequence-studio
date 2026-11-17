// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Labels.swift (type; names, defaults and the Project queries: task M-4)

use crate::{BinItemRef, Clip, MediaRef, Project, TrackKind};
use serde::{Deserialize, Serialize};
use sq_core_time::Id;
use std::collections::{BTreeMap, BTreeSet};

/// Label color of a clip, media item or sequence; the raw values are the stored identifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LabelColor {
    /// `violet`.
    Violet,
    /// `iris`.
    Iris,
    /// `caribbean`.
    Caribbean,
    /// `lavender`.
    Lavender,
    /// `cerulean`.
    Cerulean,
    /// `forest`.
    Forest,
    /// `rose`.
    Rose,
    /// `mango`.
    Mango,
    /// `purple`.
    Purple,
    /// `blue`.
    Blue,
    /// `teal`.
    Teal,
    /// `magenta`.
    Magenta,
    /// `tan`.
    Tan,
    /// `green`.
    Green,
    /// `brown`.
    Brown,
    /// `yellow`.
    Yellow,
}

impl LabelColor {
    /// Every label in the order the pickers list them (Swift `allCases`).
    pub const ALL: [LabelColor; 16] = [
        LabelColor::Violet,
        LabelColor::Iris,
        LabelColor::Caribbean,
        LabelColor::Lavender,
        LabelColor::Cerulean,
        LabelColor::Forest,
        LabelColor::Rose,
        LabelColor::Mango,
        LabelColor::Purple,
        LabelColor::Blue,
        LabelColor::Teal,
        LabelColor::Magenta,
        LabelColor::Tan,
        LabelColor::Green,
        LabelColor::Brown,
        LabelColor::Yellow,
    ];

    /// Label when a video item has none.
    pub const VIDEO_DEFAULT: LabelColor = LabelColor::Blue;
    /// Label when an audio item has none.
    pub const AUDIO_DEFAULT: LabelColor = LabelColor::Green;
    /// Label when a still image has none.
    pub const IMAGE_DEFAULT: LabelColor = LabelColor::Violet;
    /// Label when a sequence has none.
    pub const SEQUENCE_DEFAULT: LabelColor = LabelColor::Forest;
    /// Label when a nested sequence has none.
    pub const NESTED_DEFAULT: LabelColor = LabelColor::Cerulean;
    /// Label of a text clip.
    pub const TEXT_DEFAULT: LabelColor = LabelColor::Purple;
    /// Label of a generator or adjustment clip.
    pub const GENERATOR_DEFAULT: LabelColor = LabelColor::Tan;
    /// Label of a caption.
    pub const CAPTION_DEFAULT: LabelColor = LabelColor::Mango;
    /// Label of a bin.
    pub const BIN_DEFAULT: LabelColor = LabelColor::Rose;

    /// Display names of the design (docs/design-source/menus.txt); the raw values stay the stored identifiers.
    pub fn display_name(self) -> &'static str {
        match self {
            LabelColor::Violet => "Violet",
            LabelColor::Iris => "Indigo",
            LabelColor::Caribbean => "Aqua",
            LabelColor::Lavender => "Lilac",
            LabelColor::Cerulean => "Sky",
            LabelColor::Forest => "Dark Green",
            LabelColor::Rose => "Pink",
            LabelColor::Mango => "Orange",
            LabelColor::Purple => "Purple",
            LabelColor::Blue => "Blue",
            LabelColor::Teal => "Teal",
            LabelColor::Magenta => "Magenta",
            LabelColor::Tan => "Sand",
            LabelColor::Green => "Green",
            LabelColor::Brown => "Brown",
            LabelColor::Yellow => "Yellow",
        }
    }

    /// sRGB as 0xRRGGBB. The type defaults equal the clip colors of the design board (sq.css `.clip`).
    pub fn rgb(self) -> u32 {
        match self {
            LabelColor::Violet => 0x9A50C8,
            LabelColor::Iris => 0x5F6FD0,
            LabelColor::Caribbean => 0x2A8E8A,
            LabelColor::Lavender => 0x9A8FC8,
            LabelColor::Cerulean => 0x4F78A3,
            LabelColor::Forest => 0x3F7A4A,
            LabelColor::Rose => 0xBC4F78,
            LabelColor::Mango => 0xA8741C,
            LabelColor::Purple => 0x7350C0,
            LabelColor::Blue => 0x3474B5,
            LabelColor::Teal => 0x2F8F9D,
            LabelColor::Magenta => 0x9C3F79,
            LabelColor::Tan => 0x55555A,
            LabelColor::Green => 0x1E8449,
            LabelColor::Brown => 0x7A5237,
            LabelColor::Yellow => 0xB8A02E,
        }
    }
}

/// What a media item is, for icons and default labels. Derived from probe info and the file extension.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MediaKind {
    /// Video only.
    Video,
    /// Audio only.
    Audio,
    /// Video with sound.
    VideoAudio,
    /// A still image.
    Image,
    /// Not probed.
    Unknown,
}

const IMAGE_EXTENSIONS: [&str; 13] =
    ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp", "psd", "exr", "dng"];

/// The extension of the last path component, as `NSString.pathExtension` (none for ".png" or "name.").
pub(crate) fn path_extension(path: &str) -> &str {
    let name = path.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    match name.rfind('.') {
        Some(i) if i > 0 => &name[i + 1..],
        _ => "",
    }
}

impl MediaRef {
    /// What the item is, from its file extension and probe info.
    pub fn kind(&self) -> MediaKind {
        if IMAGE_EXTENSIONS.contains(&path_extension(&self.path).to_lowercase().as_str()) {
            return MediaKind::Image;
        }
        let Some(info) = &self.info else { return MediaKind::Unknown };
        match (info.video.is_some(), info.audio.is_some()) {
            (true, true) => MediaKind::VideoAudio,
            (true, false) => MediaKind::Video,
            (false, true) => MediaKind::Audio,
            _ => MediaKind::Unknown,
        }
    }

    /// Colors the item wears in the Project panel, the same colors its clips get on the timeline (`LabelResolver`):
    /// the label if set (picture and sound clips share it), else the type defaults. Video with audio has two (picture, sound).
    pub fn clip_labels(&self) -> Vec<LabelColor> {
        if let Some(label) = self.label {
            return vec![label];
        }
        match self.kind() {
            MediaKind::Audio => vec![LabelColor::AUDIO_DEFAULT],
            MediaKind::Image => vec![LabelColor::IMAGE_DEFAULT],
            MediaKind::VideoAudio => vec![LabelColor::VIDEO_DEFAULT, LabelColor::AUDIO_DEFAULT],
            _ => vec![LabelColor::VIDEO_DEFAULT],
        }
    }

    /// Label when `label` is `None`.
    pub fn default_label(&self) -> LabelColor {
        match self.kind() {
            MediaKind::Audio => LabelColor::AUDIO_DEFAULT,
            MediaKind::Image => LabelColor::IMAGE_DEFAULT,
            _ => LabelColor::VIDEO_DEFAULT,
        }
    }

    /// The label, or the default of the item's type.
    pub fn effective_label(&self) -> LabelColor {
        self.label.unwrap_or_else(|| self.default_label())
    }
}

/// Generator kind of a text clip (`GeneratorRef.text`).
pub(crate) const TEXT_GENERATOR: &str = "text";

/// Value snapshot of everything needed to color clips; the timeline view holds one (no Project dependency).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LabelResolver {
    media_labels: BTreeMap<Id, LabelColor>,
    image_media: BTreeSet<Id>,
    sequence_labels: BTreeMap<Id, LabelColor>,
}

impl LabelResolver {
    /// Color a clip draws in: its own label, else the label of its sequence / media, else the default for its type.
    pub fn label(&self, clip: &Clip) -> LabelColor {
        if let Some(l) = clip.label {
            return l;
        }
        if let Some(g) = &clip.generator {
            return if g.kind == TEXT_GENERATOR { LabelColor::TEXT_DEFAULT } else { LabelColor::GENERATOR_DEFAULT };
        }
        if let Some(s) = clip.sequence {
            return self.sequence_labels.get(&s).copied().unwrap_or(LabelColor::NESTED_DEFAULT);
        }
        if let Some(l) = self.media_labels.get(&clip.media) {
            return *l;
        }
        if self.image_media.contains(&clip.media) {
            return LabelColor::IMAGE_DEFAULT;
        }
        if clip.kind == TrackKind::Audio { LabelColor::AUDIO_DEFAULT } else { LabelColor::VIDEO_DEFAULT }
    }
}

impl Project {
    /// The label colors of this project's media and sequences, for coloring clips.
    pub fn label_resolver(&self) -> LabelResolver {
        let mut r = LabelResolver::default();
        for m in &self.media {
            if let Some(l) = m.label {
                r.media_labels.insert(m.id, l);
            }
            if m.kind() == MediaKind::Image {
                r.image_media.insert(m.id);
            }
        }
        for t in &self.timelines {
            if let Some(l) = t.label {
                r.sequence_labels.insert(t.id, l);
            }
        }
        r
    }

    /// Sequences that are used as a nested clip in some sequence.
    pub fn nested_sequence_ids(&self) -> BTreeSet<Id> {
        self.timelines.iter().flat_map(|t| &t.tracks).flat_map(|tr| tr.clips()).filter_map(|c| c.sequence).collect()
    }

    /// Label shown for a bin item. Bins have no label (fixed default).
    pub fn label_of(&self, item: BinItemRef) -> LabelColor {
        match item {
            BinItemRef::Bin(_) => LabelColor::BIN_DEFAULT,
            BinItemRef::Media(id) => self.media(id).map_or(LabelColor::VIDEO_DEFAULT, MediaRef::effective_label),
            BinItemRef::Sequence(id) => match self.timeline(id) {
                None => LabelColor::SEQUENCE_DEFAULT,
                Some(t) => t.label.unwrap_or(if self.nested_sequence_ids().contains(&id) {
                    LabelColor::NESTED_DEFAULT
                } else {
                    LabelColor::SEQUENCE_DEFAULT
                }),
            },
        }
    }

    /// Colors a Project panel item wears (see `MediaRef::clip_labels`); sequences and bins have one.
    pub fn clip_labels_of(&self, item: BinItemRef) -> Vec<LabelColor> {
        if let BinItemRef::Media(id) = item
            && let Some(m) = self.media(id)
        {
            return m.clip_labels();
        }
        vec![self.label_of(item)]
    }

    /// Sets (or with `None` resets) the label of media items and sequences in `refs`; bins are ignored.
    /// Returns whether anything changed.
    pub fn set_label(&mut self, label: Option<LabelColor>, refs: &[BinItemRef]) -> bool {
        let mut changed = false;
        for r in refs {
            match *r {
                BinItemRef::Bin(_) => {}
                BinItemRef::Media(id) => {
                    if let Some(m) = self.media.iter_mut().find(|m| m.id == id).filter(|m| m.label != label) {
                        m.label = label;
                        changed = true;
                    }
                }
                BinItemRef::Sequence(id) => {
                    if let Some(t) = self.timelines.iter_mut().find(|t| t.id == id).filter(|t| t.label != label) {
                        t.label = label;
                        changed = true;
                    }
                }
            }
        }
        changed
    }

    /// All media items and sequences whose effective label equals `label` ("Select Label Group").
    pub fn items_with_label(&self, label: LabelColor) -> Vec<BinItemRef> {
        let is_item = |r: &BinItemRef| !matches!(r, BinItemRef::Bin(_));
        self.root_bin.all_refs().into_iter().filter(|r| is_item(r) && self.label_of(*r) == label).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::*;
    use serde_json::json;

    fn media_json(n: u32, name: &str, video: bool, audio: bool, label: Option<&str>) -> serde_json::Value {
        let mut info = json!({"duration": time(10, 1)});
        if video {
            info["video"] = json!({"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                "nominalFrameDuration": time(1001, 30000), "isVariableFrameRate": false});
        }
        if audio {
            info["audio"] = json!({"sampleRate": 48000, "channels": 2, "codec": "aac"});
        }
        let mut m = json!({"id": id(n), "name": name, "path": format!("/x/{name}"), "fingerprint": {"size": 1},
            "duration": time(10, 1), "info": info});
        if let Some(l) = label {
            m["label"] = json!(l);
        }
        m
    }

    fn media_ref(v: serde_json::Value) -> MediaRef {
        serde_json::from_value(v).unwrap_or_else(|e| panic!("media: {e}"))
    }

    fn clip(media: u32, kind: &str) -> Clip {
        serde_json::from_value(clip_json(900, media, kind, 0, None)).unwrap_or_else(|e| panic!("clip: {e}"))
    }

    fn nested_clip(inner: u32) -> Clip {
        serde_json::from_value(clip_json(901, inner, "video", 0, Some(inner))).unwrap_or_else(|e| panic!("clip: {e}"))
    }

    #[test]
    fn sixteen_labels_in_order() {
        let names: Vec<_> = LabelColor::ALL.iter().map(|l| l.display_name()).collect();
        assert_eq!(
            names,
            [
                "Violet",
                "Indigo",
                "Aqua",
                "Lilac",
                "Sky",
                "Dark Green",
                "Pink",
                "Orange",
                "Purple",
                "Blue",
                "Teal",
                "Magenta",
                "Sand",
                "Green",
                "Brown",
                "Yellow"
            ]
        );
    }

    #[test]
    fn media_kinds_and_defaults() {
        let kind = |v, a| media_ref(media_json(1, "a", v, a, None));
        assert_eq!(kind(true, true).kind(), MediaKind::VideoAudio);
        assert_eq!(kind(true, false).kind(), MediaKind::Video);
        assert_eq!(kind(false, true).kind(), MediaKind::Audio);
        assert_eq!(kind(false, true).default_label(), LabelColor::Green);
        assert_eq!(kind(true, true).default_label(), LabelColor::Blue);
        let img = MediaRef::new(id(2), "p.PNG", "/x/p.PNG", crate::MediaFingerprint::new(1));
        assert_eq!((img.kind(), img.effective_label()), (MediaKind::Image, LabelColor::Violet));
        assert_eq!(media_ref(media_json(3, "a", true, true, Some("rose"))).effective_label(), LabelColor::Rose);
        assert_eq!(path_extension("/x/.png"), "");
        assert_eq!(path_extension("/x.d/file"), "");
    }

    #[test]
    fn clip_inherits_media_then_type_default() {
        let p = project_json(
            vec![media_json(1, "p", true, true, None), media_json(2, "t", true, true, Some("yellow"))],
            vec![timeline_json(10, vec![])],
        );
        let r = p.label_resolver();
        assert_eq!(r.label(&clip(1, "video")), LabelColor::Blue);
        assert_eq!(r.label(&clip(1, "audio")), LabelColor::Green);
        assert_eq!(r.label(&clip(2, "video")), LabelColor::Yellow);
        assert_eq!(r.label(&clip(2, "audio")), LabelColor::Yellow);
        let mut own = clip(2, "video");
        own.label = Some(LabelColor::Teal);
        assert_eq!(r.label(&own), LabelColor::Teal);
    }

    #[test]
    fn nested_and_generator_defaults() {
        let mut p = project_json(vec![], vec![timeline_json(10, vec![])]);
        let mut nested = nested_clip(10);
        assert_eq!(p.label_resolver().label(&nested), LabelColor::Cerulean);
        assert_eq!(LabelColor::NESTED_DEFAULT.rgb(), 0x4F78A3);
        p.timelines[0].label = Some(LabelColor::Iris);
        assert_eq!(p.label_resolver().label(&nested), LabelColor::Iris);
        nested.label = Some(LabelColor::Brown);
        assert_eq!(p.label_resolver().label(&nested), LabelColor::Brown);
        let generator = |kind: &str| {
            let mut c = clip(5, "video");
            c.generator = Some(crate::GeneratorRef { kind: kind.to_string(), payload: vec![], payload_version: 1 });
            c
        };
        let r = p.label_resolver();
        assert_eq!((r.label(&generator("text")), LabelColor::TEXT_DEFAULT.rgb()), (LabelColor::Purple, 0x7350C0));
        assert_eq!((r.label(&generator("sq.other")), LabelColor::GENERATOR_DEFAULT.rgb()), (LabelColor::Tan, 0x55555A));
        assert_eq!(
            (LabelColor::VIDEO_DEFAULT.rgb(), LabelColor::AUDIO_DEFAULT.rgb(), LabelColor::CAPTION_DEFAULT.rgb()),
            (0x3474B5, 0x1E8449, 0xA8741C)
        );
    }

    #[test]
    fn sequence_label_defaults_depend_on_nesting() {
        let outer = timeline_json(1, vec![track_json(50, "video", vec![clip_json(900, 2, "video", 0, Some(2))])]);
        let p = project_json(vec![], vec![outer, timeline_json(2, vec![])]);
        assert_eq!(p.label_of(BinItemRef::Sequence(id(1))), LabelColor::Forest);
        assert_eq!(p.label_of(BinItemRef::Sequence(id(2))), LabelColor::Cerulean);
    }

    #[test]
    fn set_label_applies_to_selection_and_ignores_bins() {
        let mut p = project_json(
            vec![media_json(1, "a", true, true, None), media_json(2, "b", false, true, None)],
            vec![timeline_json(10, vec![])],
        );
        let root = p.root_bin.id;
        let first = p.set_label(
            Some(LabelColor::Rose),
            &[BinItemRef::Media(id(1)), BinItemRef::Sequence(id(10)), BinItemRef::Bin(root)],
        );
        assert!(first);
        assert_eq!(p.media(id(1)).and_then(|m| m.label), Some(LabelColor::Rose));
        assert_eq!(p.timelines[0].label, Some(LabelColor::Rose));
        assert_eq!(p.media(id(2)).and_then(|m| m.label), None);
        assert!(!p.set_label(Some(LabelColor::Rose), &[BinItemRef::Media(id(1))]));
        assert_eq!(p.items_with_label(LabelColor::Rose).len(), 2);
        assert_eq!(p.items_with_label(LabelColor::Green), vec![BinItemRef::Media(id(2))]);
        assert!(p.set_label(None, &[BinItemRef::Media(id(1))]));
        assert_eq!(p.media(id(1)).and_then(|m| m.label), None);
    }

    #[test]
    fn project_item_colors_equal_timeline_clip_colors() {
        let photo = MediaRef::new(id(5), "p.jpg", "/x/p.jpg", crate::MediaFingerprint::new(1));
        let outer = timeline_json(1, vec![track_json(50, "video", vec![clip_json(900, 2, "video", 0, Some(2))])]);
        let mut p = project_json(
            vec![
                media_json(1, "v", true, false, None),
                media_json(3, "b", true, true, None),
                media_json(4, "t", true, true, Some("yellow")),
            ],
            vec![outer, timeline_json(2, vec![])],
        );
        p.add(photo);
        let r = p.label_resolver();
        assert_eq!(p.clip_labels_of(BinItemRef::Media(id(1))), [r.label(&clip(1, "video"))]);
        assert_eq!(
            p.clip_labels_of(BinItemRef::Media(id(3))),
            [r.label(&clip(3, "video")), r.label(&clip(3, "audio"))]
        );
        assert_eq!(p.clip_labels_of(BinItemRef::Media(id(4))), [LabelColor::Yellow]);
        assert_eq!(p.clip_labels_of(BinItemRef::Media(id(5))), [r.label(&clip(5, "video"))]);
        assert_eq!(p.clip_labels_of(BinItemRef::Sequence(id(2))), [r.label(&nested_clip(2))]);
        assert_eq!(p.clip_labels_of(BinItemRef::Sequence(id(1))), [LabelColor::SEQUENCE_DEFAULT]);
        assert_eq!(p.clip_labels_of(BinItemRef::Bin(id(77))), [LabelColor::BIN_DEFAULT]);
    }

    #[test]
    fn type_defaults_are_distinct_and_legible() {
        let d = [
            LabelColor::VIDEO_DEFAULT,
            LabelColor::AUDIO_DEFAULT,
            LabelColor::IMAGE_DEFAULT,
            LabelColor::NESTED_DEFAULT,
            LabelColor::BIN_DEFAULT,
            LabelColor::TEXT_DEFAULT,
            LabelColor::SEQUENCE_DEFAULT,
        ];
        let distinct: BTreeSet<u32> = d.iter().map(|l| l.rgb()).collect();
        assert_eq!(distinct.len(), d.len());
        let lin = |c: u32| {
            let v = f64::from(c) / 255.0;
            if v <= 0.03928 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        };
        for l in d {
            let c = l.rgb();
            let lum = 0.2126 * lin((c >> 16) & 255) + 0.7152 * lin((c >> 8) & 255) + 0.0722 * lin(c & 255);
            assert!(1.05 / (lum + 0.05) >= 4.5, "white text on {l:?}");
        }
    }
}
