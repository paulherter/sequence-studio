// Swift: EffectsCatalog.swift
//! What the Effects panel lists, shared by every panel that shows effect rows.

use crate::effects::effect_folder_model::EffectFolderOutline;
use sq_core_effects::effect_stack_preset::{EffectStackPreset, EffectStackPresets, StackBin};
use sq_core_effects::transition::ALL_TRANSITION_KINDS;
use sq_core_model::hidden_catalog;
use sq_core_model::{ClipEffect, TrackKind, TransitionKind};
use sq_core_time::Id;
use sq_editor_session::{EffectDragPayload, QuickApplyCatalog, QuickApplyItem};
use sq_library::preset_store::{PresetItem, PresetKind};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqicon::SQIcon;
use std::collections::BTreeSet;

/// One row of the Effects panel list (and of the Text panel's template list): every panel that shows effect rows shows
/// the same rows.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EffectsRow {
    /// Unique per row.
    pub id: String,
    /// Shown title.
    pub title: String,
    /// Hover tip text.
    pub subtitle: String,
    /// Leading icon.
    pub symbol: SQIcon,
    /// A category heading: not selectable, not draggable.
    pub is_header: bool,
    /// Effects panel outline: indentation level.
    pub depth: i64,
    /// Folder rows (click toggles them).
    pub is_folder: bool,
    /// The folder is open.
    pub is_expanded: bool,
    /// The effect id the row stands for (`id` is unique per row; the same effect can sit in several folders).
    pub payload: Option<String>,
    /// Section rows of the Effects panel: number of entries inside (hits while searching), shown at the right.
    pub count: Option<i64>,
    /// A user folder row, or an item inside one.
    pub user_folder: Option<Id>,
}

impl EffectsRow {
    /// A plain row.
    pub fn new(id: &str, title: &str, symbol: SQIcon, is_header: bool) -> EffectsRow {
        EffectsRow {
            id: id.to_string(),
            title: title.to_string(),
            subtitle: String::new(),
            symbol,
            is_header,
            depth: 0,
            is_folder: false,
            is_expanded: false,
            payload: None,
            count: None,
            user_folder: None,
        }
    }

    /// The id the row stands for.
    pub fn item_id(&self) -> &str {
        self.payload.as_deref().unwrap_or(&self.id)
    }
}

/// One thing the Effects panel offers: an effect kind, a transition, a built-in or saved preset, a text Look.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EffectsEntry {
    /// The effect kind, transition id or preset row id.
    pub id: String,
    /// Shown title.
    pub title: String,
    /// The folder the entry sits in.
    pub category: String,
    /// Leading icon.
    pub symbol: SQIcon,
}

impl EffectsEntry {
    /// An entry.
    pub fn new(id: &str, title: &str, category: &str, symbol: SQIcon) -> EffectsEntry {
        EffectsEntry { id: id.to_string(), title: title.to_string(), category: category.to_string(), symbol }
    }

    /// Search hit: the query is inside the title, the category (or its shown name) or one of the effect's other names
    /// (`EffectSearchTerms`: "stabilize", "steady", "camera shake" all find the Stabilizer).
    pub fn matches(&self, q: &str) -> bool {
        q.is_empty()
            || self.title.to_lowercase().contains(q)
            || self.category.to_lowercase().contains(q)
            || EffectFolderOutline::display_name(&self.category).to_lowercase().contains(q)
            || EffectFolderOutline::kit_group(&self.category).to_lowercase().contains(q)
            || crate::effects::effect_search_terms::EffectSearchTerms::terms(&self.id).iter().any(|t| t.contains(q))
    }
}

/// What the Effects panel lists, shared by every panel that shows effect rows.
pub enum EffectsCatalog {}

fn e(id: &str, title: &str, category: &str, symbol: SQIcon) -> EffectsEntry {
    EffectsEntry::new(id, title, category, symbol)
}

impl EffectsCatalog {
    /// Everything that can be applied today: video effects, audio effects (AUDIO-FX), then transitions.
    /// Hidden effects (`HiddenCatalog`: duplicates of another effect) are not listed; stored ones still work.
    pub fn catalog() -> Vec<EffectsEntry> {
        Self::offered(hidden_catalog::is_active())
    }

    /// The same list for an explicit switch (tests; `catalog` uses the app-level default).
    pub fn offered(hiding: bool) -> Vec<EffectsEntry> {
        let mut all = Self::look_entries();
        all.extend(Self::video_entries());
        all.extend(Self::audio_entries());
        all.extend(Self::transition_entries());
        all.into_iter().filter(|x| !hidden_catalog::is_hidden_effect_kind(&x.id, hiding)).collect()
    }

    /// AUDIO-FX: the "Audio Effects" folder, in Premiere's sub-folders. Ids are the `audio.` effect kinds.
    pub fn audio_entries() -> Vec<EffectsEntry> {
        let mut out = Self::stack_preset_entries(&[StackBin::Voice]);
        out.extend([
            e(ClipEffect::AUDIO_COMPRESSOR_KIND, "Compressor", "Level", SQIcon::FoldVertical),
            e(ClipEffect::AUDIO_DE_ESSER_KIND, "De-Esser", "Level", SQIcon::Voice),
            e(ClipEffect::AUDIO_GAIN_KIND, "Gain", "Level", SQIcon::Volume),
            e(ClipEffect::AUDIO_LIMITER_KIND, "Limiter", "Level", SQIcon::WaveformLines),
            e(ClipEffect::AUDIO_EQ_KIND, "EQ (3 band)", "Tone", SQIcon::SlidersVertical),
            e(ClipEffect::AUDIO_PARAMETRIC_EQ_KIND, "EQ", "Tone", SQIcon::SlidersVertical),
            e(ClipEffect::AUDIO_GRAPHIC_EQ_KIND, "Graphic EQ", "Tone", SQIcon::SlidersVertical),
            e(ClipEffect::AUDIO_MULTIBAND_KIND, "Multiband Compressor", "Level", SQIcon::ChartBars),
            e(ClipEffect::AUDIO_ENHANCE_SPEECH_KIND, "Enhance Speech", "Cleanup", SQIcon::ToolMask),
            e(ClipEffect::AUDIO_NOISE_REDUCTION_KIND, "Noise Reduction", "Cleanup", SQIcon::Activity),
            e(ClipEffect::AUDIO_NOISE_GATE_KIND, "Noise Gate", "Cleanup", SQIcon::WaveformLines),
            e(ClipEffect::AUDIO_DE_HUM_KIND, "De-Hum", "Cleanup", SQIcon::ZapOff),
            e(ClipEffect::AUDIO_DE_REVERB_KIND, "De-Reverb", "Cleanup", SQIcon::WaveformLines),
            e(ClipEffect::AUDIO_LOW_CUT_KIND, "Low Cut", "Cleanup", SQIcon::ArrowUpRight),
            e(ClipEffect::AUDIO_NOTCH_KIND, "Notch", "Cleanup", SQIcon::ShapeLine),
            e(ClipEffect::AUDIO_HIGH_CUT_KIND, "High Cut", "Cleanup", SQIcon::ArrowDownRight),
            e(ClipEffect::AUDIO_DIALOGUE_LEVELER_KIND, "Dialogue Leveler", "Level", SQIcon::Microphone),
            e(ClipEffect::AUDIO_DELAY_KIND, "Delay", "Space", SQIcon::Loop),
            e(ClipEffect::AUDIO_REVERB_KIND, "Reverb", "Space", SQIcon::Landmark),
            e(ClipEffect::AUDIO_STEREO_WIDTH_KIND, "Stereo Width", "Space", SQIcon::MoveHorizontal),
            e(ClipEffect::AUDIO_CHORUS_KIND, "Chorus", "Space", SQIcon::Activity),
            e(ClipEffect::AUDIO_PITCH_SHIFT_KIND, "Pitch Shift", "Tone", SQIcon::Waveform),
            e(ClipEffect::AUDIO_DISGUISE_VOICE_KIND, "Disguise Voice", "Tone", SQIcon::Drama),
        ]);
        out
    }

    /// The video effects, by folder.
    pub fn video_entries() -> Vec<EffectsEntry> {
        vec![
            e(ClipEffect::GAUSSIAN_BLUR_KIND, "Blur", "Blur & Sharpen", SQIcon::CircleDotted),
            e(ClipEffect::DIRECTIONAL_BLUR_KIND, "Directional Blur", "Blur & Sharpen", SQIcon::Wind),
            e(ClipEffect::SHARPEN_KIND, "Sharpen", "Blur & Sharpen", SQIcon::Triangle),
            e(ClipEffect::UNSHARP_MASK_KIND, "Unsharp Mask", "Blur & Sharpen", SQIcon::Triangle),
            e(ClipEffect::RADIAL_BLUR_KIND, "Radial Blur", "Blur & Sharpen", SQIcon::SunRays),
            e(ClipEffect::MOTION_BLUR_KIND, "Motion Blur", "Blur & Sharpen", SQIcon::CircleDashed),
            e(ClipEffect::INVERT_KIND, "Invert", "Color & Basics", SQIcon::Contrast),
            e(ClipEffect::COLOR_KIND, "Color", "Color & Basics", SQIcon::Palette),
            e(ClipEffect::BRIGHTNESS_CONTRAST_KIND, "Brightness & Contrast", "Color & Basics", SQIcon::SunDim),
            e(ClipEffect::TINT_KIND, "Duotone", "Color & Basics", SQIcon::Droplet),
            e(ClipEffect::LENS_DISTORTION_KIND, "Lens Distortion", "Distort", SQIcon::Aperture),
            e(ClipEffect::MIRROR_KIND, "Mirror", "Distort", SQIcon::FlipHorizontal),
            e(ClipEffect::SPHERIZE_KIND, "Spherize", "Distort", SQIcon::CircleDot),
            e(ClipEffect::TWIRL_KIND, "Twirl", "Distort", SQIcon::Tornado),
            e(ClipEffect::WAVE_WARP_KIND, "Wave Warp", "Distort", SQIcon::Waves),
            e(ClipEffect::BLACK_AND_WHITE_KIND, "Black & White", "Color & Basics", SQIcon::Contrast),
            e(ClipEffect::ALPHA_ADJUST_KIND, "Transparency", "Cutout", SQIcon::Checkerboard),
            e(ClipEffect::ULTRA_KEY_KIND, "Color Key", "Cutout", SQIcon::User),
            e(ClipEffect::LUMA_KEY_KIND, "Luma Key", "Cutout", SQIcon::Contrast),
            e(ClipEffect::TRACK_MASK_KIND, "Track Mask", "Cutout", SQIcon::Stack),
            e(ClipEffect::GRAIN_KIND, "Film Grain", "Film & Retro", SQIcon::Grain),
            e(ClipEffect::NOISE_KIND, "Noise", "Film & Retro", SQIcon::Grain),
            e(ClipEffect::DROP_SHADOW_KIND, "Drop Shadow", "Stylize", SQIcon::Ungroup),
            e(ClipEffect::LONG_SHADOW_KIND, "Long Shadow", "Stylize", SQIcon::Stack),
            e(ClipEffect::OUTLINE_KIND, "Outline", "Stylize", SQIcon::SquareDashed),
            e(ClipEffect::GLOW_KIND, "Glow", "Stylize", SQIcon::SunRays),
            e(ClipEffect::GRADIENT_KIND, "Gradient", "Stylize", SQIcon::PanelBottom),
            e(ClipEffect::LIGHT_LEAK_KIND, "Light Leak", "Stylize", SQIcon::SunMedium),
            e(ClipEffect::MOSAIC_KIND, "Mosaic", "Stylize", SQIcon::Grid3),
            e(ClipEffect::HALFTONE_KIND, "Halftone", "Stylize", SQIcon::Grain),
            e(ClipEffect::TILE_KIND, "Tile", "Distort", SQIcon::Grid),
            e(ClipEffect::KALEIDOSCOPE_KIND, "Kaleidoscope", "Distort", SQIcon::Hexagon),
            e(ClipEffect::CORNER_PIN_KIND, "Corner Warp", "Distort", SQIcon::Hexagon),
            e(ClipEffect::GLITCH_KIND, "Glitch Displace", "Distort", SQIcon::Columns3),
            e(ClipEffect::EDGE_FEATHER_KIND, "Edge Feather", "Stylize", SQIcon::SquareDashed),
            e(ClipEffect::POSTERIZE_KIND, "Posterize", "Stylize", SQIcon::Stack),
            e(ClipEffect::RGB_SPLIT_KIND, "RGB Split", "Stylize", SQIcon::Hexagon),
            e(ClipEffect::STROBE_KIND, "Strobe Light", "Stylize", SQIcon::Zap),
            e(ClipEffect::VIGNETTE_KIND, "Vignette", "Stylize", SQIcon::CircleDashed),
            e(ClipEffect::CROP_KIND, "Crop", "Transform", SQIcon::Crop),
            e(ClipEffect::HORIZONTAL_FLIP_KIND, "Horizontal Flip", "Transform", SQIcon::MoveHorizontal),
            e(ClipEffect::ROUNDED_CORNERS_KIND, "Rounded Corners", "Transform", SQIcon::RoundedSquare),
            e(ClipEffect::STABILIZE_KIND, "Stabilize", "Stabilize", SQIcon::Scan),
            e(ClipEffect::TRANSFORM_KIND, "Transform", "Transform", SQIcon::Move),
            e(ClipEffect::VERTICAL_FLIP_KIND, "Vertical Flip", "Transform", SQIcon::MoveVertical),
            // W7.4 / N3 parametric motion effects. FB-G: Move / Zoom / Pop / Fade are transitions now (Video Transitions).
            e(ClipEffect::SHAKE_KIND, "Shake", "Motion", SQIcon::Vibrate),
            e(ClipEffect::BOUNCE_KIND, "Bounce", "Motion", SQIcon::MoveVertical),
            e(ClipEffect::PULSE_KIND, "Pulse", "Motion", SQIcon::Radio),
            e(ClipEffect::WIGGLE_KIND, "Wiggle", "Motion", SQIcon::Waves),
            // Temporal clean-up (reads neighboring source frames).
            e(ClipEffect::VIDEO_DENOISE_KIND, "Video Denoise", "Repair", SQIcon::ToolMask),
            e(ClipEffect::DEFLICKER_KIND, "Deflicker", "Repair", SQIcon::Lightbulb),
            // Time and burn-in: a stepped frame rate, and a camcorder date/time drawn by the text renderer.
            e(ClipEffect::POSTERIZE_TIME_KIND, "Posterize Time", "Time", SQIcon::Timer),
            e(ClipEffect::TRAILS_KIND, "Trails", "Time", SQIcon::Generator),
            e(ClipEffect::DATE_STAMP_KIND, "Date Stamp", "Stylize", SQIcon::CalendarClock),
        ]
    }

    /// Film and tape looks: ready-made stacks (the presets) first, then the single effects they are built from.
    pub fn look_entries() -> Vec<EffectsEntry> {
        let mut out = Self::stack_preset_entries(&[StackBin::Looks]);
        out.extend([
            e(ClipEffect::GATE_WEAVE_KIND, "Gate Weave", "Film & Retro", SQIcon::MoveHorizontal),
            e(ClipEffect::AGED_FILM_KIND, "Aged Film", "Film & Retro", SQIcon::Film),
            e(ClipEffect::SCANLINES_KIND, "Scanlines", "Film & Retro", SQIcon::Menu),
            e(ClipEffect::CHROMA_BLEED_KIND, "Chroma Bleed", "Film & Retro", SQIcon::Droplet),
            e(ClipEffect::TRACKING_NOISE_KIND, "Tracking Noise", "Film & Retro", SQIcon::Activity),
        ]);
        out
    }

    /// Every transition, under the video or audio transitions folder.
    pub fn transition_entries() -> Vec<EffectsEntry> {
        ALL_TRANSITION_KINDS
            .iter()
            .map(|&k| {
                e(
                    &EffectDragPayload::transition_id(k),
                    sq_core_effects::transition::TransitionKindExt::name(k),
                    if k.track_kind() == TrackKind::Video { "Video Transitions" } else { "Audio Transitions" },
                    Self::transition_symbol(k),
                )
            })
            .collect()
    }

    /// The icon of a transition.
    pub fn transition_symbol(k: TransitionKind) -> SQIcon {
        use TransitionKind as K;
        match k {
            K::QuickFade => SQIcon::Zap,
            K::Push => SQIcon::PushRight,
            K::Slide => SQIcon::SlideOut,
            K::Whip => SQIcon::Wind,
            K::ZoomIn => SQIcon::ZoomIn,
            K::ZoomOut => SQIcon::ZoomOut,
            K::ZoomPop => SQIcon::ZoomSparkle,
            K::SoftWipe => SQIcon::Columns2,
            K::Glitch => SQIcon::Activity,
            K::Iris => SQIcon::CircleDashed,
            K::LightLeak => SQIcon::SunRays,
            K::BlurDissolve => SQIcon::Droplet,
            K::DipToColour => SQIcon::Contrast,
            K::Flash => SQIcon::Zap,
            K::Spin => SQIcon::Refresh,
            K::CrossZoom => SQIcon::Maximize,
            K::StaticNoise => SQIcon::Tv,
            K::LightNoise => SQIcon::Sparkles,
            K::StrobeCut => SQIcon::Lightbulb,
            K::AdditiveDissolve => SQIcon::SunMedium,
            K::ClockWipe => SQIcon::Clock,
            K::BoxIris => SQIcon::SquareDashed,
            K::DiamondIris => SQIcon::Diamond,
            K::CrossIris => SQIcon::Plus,
            K::BarnDoors => SQIcon::Columns3,
            K::VenetianBlinds => SQIcon::List,
            K::RadialWipe => SQIcon::CircleDashed,
            K::WedgeWipe => SQIcon::SunRays,
            K::Pinwheel => SQIcon::RotateCW,
            K::CheckerWipe => SQIcon::Checkerboard,
            K::ZigZagBlocks => SQIcon::Grid3,
            K::InsetWipe => SQIcon::SquareDashed,
            K::RandomBlocks => SQIcon::Grid,
            K::SliceWipe => SQIcon::List,
            K::MosaicDissolve => SQIcon::Grid3,
            K::Flip3D => SQIcon::RotateCW,
            K::Spring => SQIcon::SlideOut,
            K::Fall => SQIcon::ArrowRight,
            K::Burn => SQIcon::SunMedium,
            K::Flare => SQIcon::SunRays,
            K::Warp => SQIcon::Droplet,
            K::Shake => SQIcon::Zap,
            K::Stinger => SQIcon::Sequence,
            K::Move => SQIcon::ArrowRight,
            K::Zoom => SQIcon::ZoomIn,
            K::Pop => SQIcon::Sparkles,
            _ => {
                if k.track_kind() == TrackKind::Video {
                    SQIcon::Group
                } else {
                    SQIcon::Activity
                }
            }
        }
    }

    /// Flat rows for a search text: entries whose title or category contain it (case-insensitive), under their category
    /// heading. The panel itself shows the folder outline (`EffectFolderOutline`); this flat form stays for callers and tests.
    pub fn rows(query: &str, entries: &[EffectsEntry]) -> Vec<EffectsRow> {
        let q = query.trim_matches([' ', '\t']).to_lowercase();
        let hits: Vec<&EffectsEntry> = entries.iter().filter(|x| x.matches(&q)).collect();
        let mut out = Vec::new();
        let mut seen: Vec<&str> = Vec::new();
        for h in &hits {
            if !seen.contains(&h.category.as_str()) {
                seen.push(&h.category);
            }
        }
        for c in seen {
            out.push(EffectsRow::new(
                &format!("category-{c}"),
                &EffectFolderOutline::display_name(c),
                SQIcon::Folder,
                true,
            ));
            out.extend(
                hits.iter().filter(|h| h.category == c).map(|h| EffectsRow::new(&h.id, &h.title, h.symbol, false)),
            );
        }
        out
    }

    /// FB-T3: the built-in motion and keying presets (Whip In, Bounce In, Green Screen ...), listed first in the Presets
    /// folder. Ids `preset.builtin.<id>`.
    pub fn built_in_preset_entries() -> Vec<EffectsEntry> {
        Self::stack_preset_entries(&[StackBin::Motion, StackBin::Keying])
    }

    /// The one listing path of the built-in stack presets (`EffectStackPresets.offered`, hidden ones left out): row id,
    /// name, and the folder and icon of the preset's bin.
    pub fn stack_preset_entries(bins: &[StackBin]) -> Vec<EffectsEntry> {
        let bins: BTreeSet<StackBin> = bins.iter().copied().collect();
        EffectStackPresets::offered_in(&bins)
            .iter()
            .map(|p: &EffectStackPreset| e(&p.row_id(), &p.name, p.bin.panel_category(), p.bin.panel_symbol()))
            .collect()
    }

    /// The Library's saved presets as Effects panel entries (keystones stay in their own panel). Mirrors the Mac
    /// wiring in EditorPanels so both panels list the same "Presets" folder.
    pub fn preset_entries(presets: &[PresetItem]) -> Vec<EffectsEntry> {
        presets
            .iter()
            .filter(|p| p.kind != PresetKind::Keystone)
            .map(|p| e(&format!("preset.{}", p.id), &p.name, EffectFolderOutline::PRESETS_FOLDER, SQIcon::ToolMask))
            .collect()
    }
}

/// The Effects panel folder and icon of a bin of built-in stack presets.
pub trait StackBinPanelExt {
    /// The Effects panel folder a bin's presets are listed in (unchanged by consolidation step 8: film looks in Looks,
    /// everything else in Presets; Voice's Presets folder sits in the audio folder because its id is an audio id).
    fn panel_category(self) -> &'static str;
    /// The icon of the bin's presets.
    fn panel_symbol(self) -> SQIcon;
}

impl StackBinPanelExt for StackBin {
    fn panel_category(self) -> &'static str {
        if self == StackBin::Looks { "Looks" } else { "Presets" }
    }

    fn panel_symbol(self) -> SQIcon {
        match self {
            StackBin::Motion | StackBin::Keying => SQIcon::Sparkles,
            StackBin::Looks => SQIcon::Sequence,
            StackBin::Voice => SQIcon::Microphone,
        }
    }
}

/// The palette rows of the Effects panel's own lists.
pub trait QuickApplyCatalogExt {
    /// The palette rows of the Effects panel's own lists (effects, transitions, built-in presets) plus `presets`;
    /// `commands` are the supported menu commands in menu order.
    fn items_for(presets: &[PresetItem], commands: &[EditorCommand]) -> Vec<QuickApplyItem>;
}

impl QuickApplyCatalogExt for QuickApplyCatalog {
    fn items_for(presets: &[PresetItem], commands: &[EditorCommand]) -> Vec<QuickApplyItem> {
        let effects: Vec<(String, String)> = EffectsCatalog::catalog().into_iter().map(|x| (x.id, x.title)).collect();
        let built_in: Vec<(String, String)> =
            EffectsCatalog::built_in_preset_entries().into_iter().map(|x| (x.id, x.title)).collect();
        QuickApplyCatalog::items(&effects, &built_in, presets, commands)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effects::effect_folder_model::EffectFolderStore;
    use sq_core_time::{SequentialIds, Timestamp};
    use std::collections::BTreeSet;

    fn dissolve_id() -> String {
        EffectsCatalog::transition_entries()
            .into_iter()
            .find(|x| x.title.to_lowercase().contains("dissolve"))
            .map(|x| x.id)
            .unwrap_or_default()
    }

    #[test]
    fn catalog_lists_effects_audio_and_transitions() {
        let ids: BTreeSet<String> = EffectsCatalog::offered(false).into_iter().map(|x| x.id).collect();
        assert!(ids.contains(ClipEffect::GAUSSIAN_BLUR_KIND));
        assert!(ids.contains(ClipEffect::AUDIO_COMPRESSOR_KIND));
        assert!(ids.contains(&dissolve_id()));
    }

    #[test]
    fn style_and_time_effects_sit_in_the_swift_bins() {
        let cat = EffectsCatalog::catalog();
        let bin = |kind: &str| cat.iter().find(|x| x.id == kind).map(|x| x.category.clone());
        assert_eq!(bin(ClipEffect::OUTLINE_KIND).as_deref(), Some("Stylize"));
        assert_eq!(bin(ClipEffect::LONG_SHADOW_KIND).as_deref(), Some("Stylize"));
        assert_eq!(bin(ClipEffect::TRAILS_KIND).as_deref(), Some("Time"));
        assert_eq!(bin(ClipEffect::MOTION_BLUR_KIND).as_deref(), Some("Blur & Sharpen"));
    }

    #[test]
    fn search_finds_other_names() {
        let rows = EffectsCatalog::rows("steady", &EffectsCatalog::catalog());
        assert!(rows.iter().any(|r| r.id == ClipEffect::STABILIZE_KIND));
        assert!(rows.first().is_some_and(|r| r.is_header));
    }

    #[test]
    fn preset_entries_skip_keystones_and_use_preset_ids() {
        let mut ids = SequentialIds::default();
        let now = Timestamp::from_reference_seconds(0.0);
        let id = sq_core_time::IdSource::next_id(&mut ids);
        let effect = PresetItem::new(id, PresetKind::Effect, "Warm", now, Vec::new(), 1);
        let keystone =
            PresetItem::new(sq_core_time::IdSource::next_id(&mut ids), PresetKind::Keystone, "K", now, Vec::new(), 1);
        let entries = EffectsCatalog::preset_entries(&[effect, keystone]);
        assert_eq!(entries.iter().map(|x| x.id.clone()).collect::<Vec<_>>(), vec![format!("preset.{id}")]);
        assert_eq!(entries[0].category, EffectFolderOutline::PRESETS_FOLDER);
    }

    #[test]
    fn folder_outline_opens_search_hits() {
        let rows = EffectFolderOutline::rows(
            &EffectsCatalog::catalog(),
            &EffectFolderStore::new(),
            &BTreeSet::new(),
            "blur",
            &BTreeSet::new(),
        );
        assert!(rows.iter().any(|r| r.payload.as_deref() == Some(ClipEffect::GAUSSIAN_BLUR_KIND)));
    }

    #[test]
    fn folders_are_merged_and_searchable_by_premiere_names() {
        let cat = EffectsCatalog::catalog();
        let bin = |kind: &str| cat.iter().find(|x| x.id == kind).map(|x| x.category.clone());
        assert_eq!(bin(ClipEffect::SHARPEN_KIND).as_deref(), Some("Blur & Sharpen"));
        for k in [ClipEffect::GATE_WEAVE_KIND, ClipEffect::SCANLINES_KIND, ClipEffect::GRAIN_KIND] {
            assert_eq!(bin(k).as_deref(), Some("Film & Retro"), "{k}");
        }
        assert_eq!(bin(ClipEffect::STABILIZE_KIND).as_deref(), Some("Stabilize"));
        let rows = EffectsCatalog::rows("gaussian blur", &cat);
        assert!(rows.iter().any(|r| r.id == ClipEffect::GAUSSIAN_BLUR_KIND));
        // No empty "Text" folder, and every folder row shows its count.
        let rows = EffectFolderOutline::rows(&cat, &EffectFolderStore::new(), &BTreeSet::new(), "", &BTreeSet::new());
        assert!(rows.iter().all(|r| r.title != "Text"));
        assert!(rows.iter().filter(|r| r.is_folder).all(|r| r.count.is_some()));
        let rows = EffectFolderOutline::rows(&cat, &EffectFolderStore::new(), &BTreeSet::new(), "", &BTreeSet::new());
        let groups: Vec<_> = rows.iter().filter(|r| r.is_folder).collect();
        assert!(groups.iter().any(|r| r.title == "Film & Retro"));
        assert!(groups.iter().all(|r| r.count.is_some_and(|c| c > 0)));
    }

    #[test]
    fn effect_groups_are_flat_like_the_kit() {
        let cat = EffectsCatalog::catalog();
        let rows = EffectFolderOutline::rows(&cat, &EffectFolderStore::new(), &BTreeSet::new(), "", &BTreeSet::new());
        // Closed: every group is a top-level head, no "Video" folder, nothing nested.
        assert!(rows.iter().all(|r| r.is_folder && r.depth == 0));
        assert!(rows.iter().all(|r| r.title != "Video"));
        let titles: Vec<&str> = rows.iter().map(|r| r.title.as_str()).collect();
        assert!(titles.contains(&"Stabilize") && titles.contains(&"Transitions") && titles.contains(&"Audio"));
        // Open: the audio effects sit directly under "Audio" (no category folders between).
        let open = BTreeSet::from([EffectFolderOutline::builtin_id(EffectFolderOutline::AUDIO_EFFECTS_FOLDER, None)]);
        let rows = EffectFolderOutline::rows(&cat, &EffectFolderStore::new(), &open, "", &BTreeSet::new());
        let audio = rows.iter().position(|r| r.title == "Audio").expect("audio group");
        let n = rows[audio].count.expect("count");
        assert!(rows[audio + 1..audio + 1 + n as usize].iter().all(|r| !r.is_folder && r.depth == 1));
        // The video category heads still carry their folder ids (drag, saved open state).
        let stab = rows.iter().find(|r| r.title == "Stabilize").expect("stabilize");
        assert!(stab.id.ends_with("/Stabilize") && stab.depth == 0);
    }

    #[test]
    fn video_groups_follow_the_kit_order_and_keep_every_effect() {
        let cat = EffectsCatalog::catalog();
        let rows = EffectFolderOutline::rows(&cat, &EffectFolderStore::new(), &BTreeSet::new(), "", &BTreeSet::new());
        let titles: Vec<&str> = rows.iter().map(|r| r.title.as_str()).collect();
        let pos = |t: &str| titles.iter().position(|x| *x == t).unwrap_or_else(|| panic!("no group {t}: {titles:?}"));
        let kit = ["Color & Basics", "Blur & Sharpen", "Distort", "Stylize", "Film & Retro", "Stabilize", "Time"];
        assert!(kit.windows(2).all(|w| pos(w[0]) < pos(w[1])), "{titles:?}");
        assert!(pos("Time") < pos("Transitions") && pos("Transitions") < pos("Audio"), "{titles:?}");
        for old in ["Cutout", "Transform", "Motion", "Repair", "Adjust"] {
            assert!(!titles.contains(&old), "{old} is folded into a kit group");
        }
        // Counts per group add up to every video effect (nothing was dropped by the regroup).
        let video: usize = kit.iter().map(|g| rows[pos(g)].count.unwrap_or(0) as usize).sum();
        let expected =
            cat.iter().filter(|x| EffectFolderOutline::location(x).0 == EffectFolderOutline::EFFECTS_FOLDER).count();
        assert_eq!(video, expected);
        // Old names still find their effects.
        let hits = |q: &str| cat.iter().filter(|x| x.matches(q)).map(|x| x.id.clone()).collect::<Vec<_>>();
        assert!(hits("cutout").contains(&ClipEffect::LUMA_KEY_KIND.to_string()));
        assert!(hits("motion").contains(&ClipEffect::SHAKE_KIND.to_string()));
        assert!(hits("gaussian blur").contains(&ClipEffect::GAUSSIAN_BLUR_KIND.to_string()));
        // The saved-preset bin reads as the kit's pack.
        assert_eq!(EffectFolderOutline::display_name(EffectFolderOutline::PRESETS_FOLDER), "Sequence Studio pack");
    }
}
