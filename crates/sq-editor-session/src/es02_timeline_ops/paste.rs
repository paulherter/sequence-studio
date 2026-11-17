//! Paste: attribute groups, built-in effect clipboard, media paste routing and the drag payload types.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use sq_core_model::{Clip, EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Timestamp};
use sq_uikit::focus_routing::FocusedEditTarget;

use super::prelude::*;
use crate::EditorSession;
use crate::EffectSection;

/// The attribute groups Paste Attributes offers: anything not picked stays untouched on the target.
// Swift: PasteAttributesSelection.swift:5
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum PasteAttributeGroup {
    Motion,
    Opacity,
    Effects,
    Color,
    Volume,
}

impl PasteAttributeGroup {
    /// Every group, in Swift's declaration order.
    pub const ALL: [PasteAttributeGroup; 5] = [Self::Motion, Self::Opacity, Self::Effects, Self::Color, Self::Volume];

    /// Swift's `String` raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            PasteAttributeGroup::Motion => "motion",
            PasteAttributeGroup::Opacity => "opacity",
            PasteAttributeGroup::Effects => "effects",
            PasteAttributeGroup::Color => "color",
            PasteAttributeGroup::Volume => "volume",
        }
    }

    /// The name the dialog and the undo step show.
    // Swift: PasteAttributesSelection.swift:7
    pub fn title(self) -> &'static str {
        match self {
            PasteAttributeGroup::Motion => "Transform",
            PasteAttributeGroup::Opacity => "Opacity",
            PasteAttributeGroup::Effects => "Effects",
            PasteAttributeGroup::Color => "Color",
            PasteAttributeGroup::Volume => "Volume",
        }
    }

    // Swift: PasteAttributesSelection.swift:17
    pub fn kind(self) -> TrackKind {
        if self == PasteAttributeGroup::Volume { TrackKind::Audio } else { TrackKind::Video }
    }

    // Swift: PasteAttributesSelection.swift:19
    pub fn groups(kind: TrackKind) -> Vec<PasteAttributeGroup> {
        Self::ALL.into_iter().filter(|g| g.kind() == kind).collect()
    }

    /// Groups of `source` that are worth offering (the copied clip actually has something there).
    // Swift: PasteAttributesSelection.swift:23
    pub fn available(source: &Clip) -> Vec<PasteAttributeGroup> {
        Self::groups(source.kind)
    }

    /// Copies this group's fields from `source` onto `target` (same kind assumed). Effects follow the same rule as a
    /// full paste: same-count kinds are replaced one by one, otherwise the copies are added behind.
    // Swift: PasteAttributesSelection.swift:29
    pub fn copy(self, source: &Clip, target: &mut Clip, pasted: &Clip, ids: &mut dyn IdSource) {
        match self {
            PasteAttributeGroup::Motion => target.replace_motion(pasted),
            PasteAttributeGroup::Opacity => {
                target.opacity_enabled = pasted.opacity_enabled;
                target.animation.opacity = pasted.animation.opacity.clone();
                target.set_masks(pasted.masks().to_vec());
                target.blend_mode = pasted.blend_mode;
            }
            PasteAttributeGroup::Effects => {
                // Source without its Color effects, pasted by the core rules; the target's own grade is put back
                // afterwards, so Effects and Color stay independent.
                let mut src = source.clone();
                src.effects.retain(|e| !(e.is_color() || e.kind == COLOR_GRAPH_KIND));
                let mut p = target.pasting_attributes(&src, ids);
                let grade = target.color_grade_effects();
                p.replace_color_grade(&grade, ids);
                p.apply_copied_graph(target.color_graph(), ids);
                target.effects = p.effects;
            }
            PasteAttributeGroup::Color => {
                if target.accepts_color() {
                    target.footage_color = source.footage_color.clone();
                    target.replace_color_grade(&source.color_grade_effects(), ids);
                    target.apply_copied_graph(source.color_graph(), ids);
                }
            }
            PasteAttributeGroup::Volume => {
                target.animation.volume = pasted.animation.volume.clone();
                target.audio_gain_db = pasted.audio_gain_db;
            }
        }
    }
}

/// Paste Attributes limited to `groups`. Same kind only; other attributes stay as they are. `scale_times` (Premiere's
/// "Scale Attribute Times"): the copied key times are stretched by target / source length first.
// Swift: PasteAttributesSelection.swift:62
pub fn pasting_attributes_in_groups(
    target: &Clip,
    source: &Clip,
    groups: &BTreeSet<PasteAttributeGroup>,
    scale_times: bool,
    ids: &mut dyn IdSource,
) -> Clip {
    if source.kind != target.kind {
        return target.clone();
    }
    let source = if scale_times { source.key_times_scaled(target.duration()) } else { source.clone() };
    let full = target.pasting_attributes(&source, ids);
    let mut out = target.clone();
    for g in groups.iter().filter(|g| g.kind() == target.kind) {
        g.copy(&source, &mut out, &full, ids);
    }
    out
}

/// Paste Attributes onto `to`, only `groups`. Returns how many clips changed (`EmptyClip` when none did).
/// `source_lane` / `picture_lanes` (from the clipboard): Picture masks keep their lane offset when their track is not here.
// Swift: PasteAttributesSelection.swift:76
#[allow(clippy::too_many_arguments)] // the Swift signature, one parameter per option
pub fn paste_attributes(
    t: &mut Timeline,
    source: &Clip,
    to: &[Id],
    groups: &BTreeSet<PasteAttributeGroup>,
    scale_times: bool,
    source_lane: Option<usize>,
    picture_lanes: &std::collections::BTreeMap<Id, usize>,
    ids: &mut dyn IdSource,
) -> Result<usize, EditError> {
    let mut work = t.clone();
    let mut changed = 0;
    for &id in to.iter().filter(|&&id| id != source.id) {
        let Some(c) = work.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id).cloned() else { continue };
        if c.kind != source.kind {
            continue;
        }
        let pasted = pasting_attributes_in_groups(&c, source, groups, scale_times, ids);
        let out = work.remapping_picture_tracks(&pasted, source_lane, picture_lanes);
        if out == c {
            continue;
        }
        work.replace_clip(out)?;
        changed += 1;
    }
    if changed == 0 {
        return Err(EditError::EmptyClip);
    }
    *t = work;
    Ok(changed)
}

/// A built-in effect of a clip (Transform, Blend, Volume) copied as a whole: the group and the clip it came from, so the
/// values and keyframes can be put onto other clips. Speed is not copied (it changes the clip length).
// Swift: BuiltInClipboard.swift:5
#[derive(Clone, Debug, PartialEq)]
pub struct BuiltInClipboard {
    // Swift: BuiltInClipboard.swift:6
    pub group: PasteAttributeGroup,
    // Swift: BuiltInClipboard.swift:7
    pub clip: Clip,
}

impl BuiltInClipboard {
    // Swift: BuiltInClipboard.swift:8
    pub fn new(group: PasteAttributeGroup, clip: Clip) -> BuiltInClipboard {
        BuiltInClipboard { group, clip }
    }

    /// The group a built-in section stands for; `None` for Speed, applied effects, masks and animations.
    // Swift: BuiltInClipboard.swift:15
    pub fn group_for(section: EffectSection) -> Option<PasteAttributeGroup> {
        match section {
            EffectSection::Motion => Some(PasteAttributeGroup::Motion),
            EffectSection::Opacity => Some(PasteAttributeGroup::Opacity),
            EffectSection::Volume => Some(PasteAttributeGroup::Volume),
            _ => None,
        }
    }
}

impl EditorSession {
    /// Copies the built-in effect `section` of `clip` (Effect Controls Cmd+C on its header). False for sections that
    /// cannot be copied as a whole.
    // Swift: BuiltInClipboard.swift:28
    pub fn copy_built_in(&mut self, section: EffectSection, clip: &Clip) -> bool {
        let Some(g) = BuiltInClipboard::group_for(section).filter(|g| g.kind() == clip.kind) else { return false };
        self.built_in_clipboard = Some(BuiltInClipboard::new(g, clip.clone()));
        self.effect_clipboard = None;
        true
    }

    /// Selected clips that can take the copied built-in effect.
    #[allow(dead_code)] // called by ES4 (`can_paste_attributes`)
    pub(crate) fn built_in_targets(&self, b: &BuiltInClipboard) -> Vec<Id> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && c.kind == b.group.kind())
            .map(|c| c.id)
            .collect()
    }

    /// Cmd+V / Paste Attributes with a built-in effect copied: its values and keyframes replace the same group on every
    /// selected clip of the same kind (one undo step).
    #[allow(dead_code)] // called by ES4 (`paste_attributes`)
    pub(crate) fn paste_built_in(
        &mut self,
        b: &BuiltInClipboard,
        groups: &BTreeSet<PasteAttributeGroup>,
        scale_times: bool,
    ) -> bool {
        if !groups.contains(&b.group) {
            return false;
        }
        let targets = self.built_in_targets(b);
        if targets.is_empty() {
            return false;
        }
        let only = BTreeSet::from([b.group]);
        let name = format!("Paste {}", b.group.title());
        self.with_ids(|s, ids| {
            s.attempt(&name, None, |t| {
                let mut n = 0;
                for id in targets {
                    let Some(c) = t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id).cloned() else {
                        continue;
                    };
                    let out = pasting_attributes_in_groups(&c, &b.clip, &only, scale_times, ids);
                    if out == c {
                        continue;
                    }
                    t.replace_clip(out)?;
                    n += 1;
                }
                if n == 0 { Err(EditError::EmptyClip) } else { Ok(()) }
            })
        })
    }
}

/// Cmd+V with files or an image on the system pasteboard (a Finder copy, a screenshot, an image copied in a browser).
/// Our own clip clipboard lives in the session, not on the pasteboard, so it keeps priority simply by being non-empty.
// Swift: PasteMediaRouting.swift:5
pub enum PasteMedia {}

/// Where a paste goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PasteRoute {
    /// Existing behavior: the timeline's clip / effect paste (or nothing in the Project panel).
    OwnClipboard,
    ImportFiles,
    ImportImage,
    Nothing,
}

/// What the pasteboard holds that can become media.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PasteContent {
    // Swift: PasteMediaRouting.swift:26
    pub file_urls: Vec<PathBuf>,
    // Swift: PasteMediaRouting.swift:27
    pub image_data: Option<Vec<u8>>,
}

impl PasteContent {
    // Swift: PasteMediaRouting.swift:29
    pub fn new(file_urls: Vec<PathBuf>, image_data: Option<Vec<u8>>) -> PasteContent {
        PasteContent { file_urls, image_data }
    }

    // Swift: PasteMediaRouting.swift:28
    pub fn has_media(&self) -> bool {
        !self.file_urls.is_empty() || self.image_data.is_some()
    }
}

// Swift: PasteMedia.swift:6
// `PasteMedia.read(from: NSPasteboard)` is the Mac pasteboard reader and stays in the app shell: it fills a
// `PasteContent` from the system pasteboard.
impl PasteMedia {
    /// Pure routing. Media paste only applies with the Project panel or the timeline focused, and only when we hold
    /// no clip data of our own.
    // Swift: PasteMediaRouting.swift:17
    pub fn route(target: FocusedEditTarget, has_own_clip_data: bool, has_files: bool, has_image: bool) -> PasteRoute {
        if target != FocusedEditTarget::Timeline && target != FocusedEditTarget::Project {
            return PasteRoute::Nothing;
        }
        if has_own_clip_data {
            PasteRoute::OwnClipboard
        } else if has_files {
            PasteRoute::ImportFiles
        } else if has_image {
            PasteRoute::ImportImage
        } else {
            PasteRoute::Nothing
        }
    }

    /// `Pasted Image 2026-10-07 14.03.22.png` (numbered when that name is taken).
    // Swift: PasteMediaRouting.swift:33
    pub fn image_file_name(date: Timestamp, existing: impl Fn(&str) -> bool) -> String {
        Self::image_file_name_in(sq_core_time::local_time::local_civil(date), existing)
    }

    /// `image_file_name` for an already converted civil time.
    pub fn image_file_name_in(c: sq_core_time::local_time::Civil, existing: impl Fn(&str) -> bool) -> String {
        let base = format!(
            "Pasted Image {:04}-{:02}-{:02} {:02}.{:02}.{:02}",
            c.year, c.month, c.day, c.hour, c.minute, c.second
        );
        let mut name = format!("{base}.png");
        let mut n = 2;
        while existing(&name) {
            name = format!("{base} {n}.png");
            n += 1;
        }
        name
    }

    /// Writes PNG data into `folder` (created if needed) and returns the file.
    // Swift: PasteMediaRouting.swift:44
    pub fn write_image(png: &[u8], folder: &Path, date: Timestamp) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(folder)?;
        let name = Self::image_file_name(date, |n| folder.join(n).exists());
        let url = folder.join(name);
        std::fs::write(&url, png)?;
        Ok(url)
    }
}

/// Drag payload types shared by the panels, the timeline and the monitor.
pub enum PasteboardTypes {}

impl PasteboardTypes {
    /// An effect dragged from the Effects panel: the effect id.
    // Swift: PasteboardTypes.swift:7
    pub const SEQUENCE_EFFECT_ID: &'static str = "com.sequencestudio.effect-id";
    /// A user folder row of the Effects panel being dragged to a new place in the list: the folder's UUID string.
    // Swift: PasteboardTypes.swift:9
    pub const SEQUENCE_EFFECT_FOLDER: &'static str = "com.sequencestudio.effect-folder";
    /// A text template dragged from the Library: the `TextTemplateCatalog` entry id as a string.
    // Swift: PasteboardTypes.swift:11
    pub const SEQUENCE_TEXT_TEMPLATE: &'static str = "com.sequencestudio.text-template";
    /// The item IDs dragged out of the Project panel (`ProjectPanelModel.pasteboardTypeName`).
    // Swift: PasteboardTypes.swift:13
    pub const SEQUENCE_MEDIA_IDS: &'static str = "com.sequencestudio.media-ids";
}

#[cfg(test)]
mod pasted_image_name_tests {
    use super::*;
    use sq_core_time::local_time::Civil;

    #[test]
    fn the_name_carries_the_given_civil_time_and_numbers_clashes() {
        let c = Civil { year: 2026, month: 10, day: 7, hour: 14, minute: 3, second: 22 };
        assert_eq!(PasteMedia::image_file_name_in(c, |_| false), "Pasted Image 2026-10-07 14.03.22.png");
        let taken = |n: &str| n == "Pasted Image 2026-10-07 14.03.22.png";
        assert_eq!(PasteMedia::image_file_name_in(c, taken), "Pasted Image 2026-10-07 14.03.22 2.png");
    }
}
