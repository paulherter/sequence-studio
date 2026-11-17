// Swift: ShellExportRows.swift (ExportItem, ExportRow, ExportSection, ExportSheetRows)
//! The settings column of the Export sheet, line for line with the Mac `ExportSheetRows`: sections (Video, Audio, Captions,
//! Range, Output, Advanced) of rows, each row a label and controls. The Swift rows carry closures over the model; here every
//! control carries an [`Act`] and [`apply`] runs it against the model, so the rows can be checked without a window.

use sq_core_time::Time;
use sq_editor_session::{CutDownKey, ExportDialogModel, ExportSeconds};
use sq_export::core::audio_delivery::{AudioDeliveryTarget, AudioSeverity};
use sq_export::core::encoder_support::{EncoderSupport, Missing};
use sq_export::core::error::ExportDecodeError;
use sq_export::core::frame_output::{FrameOutput, FrameStillFormat};
use sq_export::core::hdr::{HdrDelivery, HdrToSdr, HdrTransfer};
use sq_export::core::preflight::ExportPreflight;
use sq_export::core::preset::QualityStep;
use sq_export::core::settings::{
    AudioCodec, AudioFileFormat, BitrateKind, CaptionMode, CoverImageFormat, EncoderSpeed, VideoCodec, VideoProfile,
};
use sq_uikit::localization::SQL10n;

/// `ExportItem.Tone`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Tone {
    Label,
    // `ExportItem.Tone.label2` exists on the Mac; no row uses it yet.
    #[allow(dead_code)]
    Label2,
    Label3,
    Warning,
    Green,
    Red,
}

/// `ExportItem.Width`: `Fill` shares the room left, `Fit` takes the control's own width, `Fixed` a set width.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Width {
    Fill,
    Fit,
    Fixed(f64),
}

/// The number field of a scrub item.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct ScrubSpec {
    pub value: f64,
    pub min: f64,
    pub max: f64,
    pub step: f64,
    pub decimals: i64,
    pub default: Option<f64>,
}

/// `ExportItem.Kind`.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Kind {
    Popup {
        titles: Vec<String>,
        selected: usize,
        disabled: Vec<usize>,
    },
    Check {
        title: String,
        on: bool,
    },
    /// The kit's 34 x 20 switch (no title: the row label says what it is).
    Switch {
        on: bool,
    },
    Scrub(ScrubSpec),
    /// The unit after a number field (`SQUnitLabel`).
    Unit(String),
    Text {
        text: String,
        tone: Tone,
        caption: bool,
    },
    Segmented {
        labels: Vec<String>,
        selected: usize,
        disabled: Vec<usize>,
        segment_width: f64,
        /// Outlined pills with a gap instead of one joined track (the redesign's chips).
        chips: bool,
    },
    Button(String),
    /// A square quiet button with an icon (the size swap).
    IconButton(sq_uikit::sqicon::SQIcon),
    /// One toggle chip (a stem role).
    Chip {
        title: String,
        on: bool,
    },
    /// The File Name capsule with the extension after the text.
    Field {
        suffix: String,
    },
    /// The Folder capsule (read only).
    Path(String),
}

/// What a control changes (the Swift closure of the item).
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Act {
    None,
    Codec(Vec<VideoCodec>),
    Profile(Vec<VideoProfile>),
    Size(Vec<(i64, i64)>),
    /// The shape chips: 9:16, 16:9, 1:1, 4:5.
    Shape,
    /// Width and height trade places.
    Swap,
    Width,
    Height,
    FrameRate(Vec<f64>),
    ImageFormat(Vec<FrameStillFormat>),
    RateControl,
    ConstantQuality,
    Hardware,
    Speed,
    QualityStep,
    BitrateKind(Vec<BitrateKind>),
    Bitrate,
    HasMax,
    MaxBitrate,
    IncludeAudio,
    AudioCodec,
    SampleRate,
    AudioBitrate,
    BitDepth(Vec<i64>),
    Normalize,
    AudioLoudness,
    LoudnessTarget,
    DeliveryTarget,
    AudioCheck,
    StemCheck(String),
    StemsRun,
    CutCheck(CutDownKey),
    CutsRun,
    Captions,
    CoverOn,
    CoverFormat,
    RangeMode,
    CustomStart,
    CustomEnd,
    OneFilePerClip,
    FileName,
    ChooseFolder,
    CopyChapters(String),
    Channels,
    TruePeak,
    Keyframe,
    BFrames,
    Alpha,
    Damaged,
    HdrToSdr,
    HdrExposure,
    HdrGamut,
    ColorSpace,
    PeakNits,
}

/// One control of a settings row.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Item {
    pub kind: Kind,
    pub width: Width,
    pub enabled: bool,
    pub act: Act,
    /// The number field commits rebuild the rows (the Mac `rebuild:` of `scrub`).
    pub rebuild: bool,
}

/// One row: label at 25, controls from 128.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Row {
    pub title: String,
    pub items: Vec<Item>,
    pub dimmed: bool,
    /// The row height; the card default without it.
    pub height: Option<f64>,
    /// Offset of the controls from the row top; centered without it (rows whose controls start at the top).
    pub top: Option<f64>,
    /// A grey line under the label (English key, localized when drawn).
    pub hint: String,
}

/// One folding section of the column.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Section {
    pub title: &'static str,
    pub key: &'static str,
    pub default_open: bool,
    pub rows: Vec<Row>,
    /// Folded under "More settings" (the essentials card has an empty title and no header).
    pub detail: bool,
}

/// A value an item delivers.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Val {
    Index(usize),
    Bool(bool),
    Number(f64),
    Press,
    Text(String),
}

/// What an applied value asks of the sheet.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Outcome {
    /// The rows may differ now (the Mac `reload()`).
    pub rebuild: bool,
    /// The Size popup's "Custom" entry was chosen or left.
    pub custom_size: Option<bool>,
    /// Work only the flow can do: `folder`, `stems_run`, `cuts_run`, `audio_check`.
    pub event: Option<&'static str>,
    /// Text for the clipboard.
    pub copy: Option<String>,
}

pub(crate) const NUMBER_FIELD_WIDTH: f64 = 84.0;
pub(crate) const SIZES: [(i64, i64); 7] =
    [(1080, 1920), (1920, 1080), (1080, 1080), (1080, 1350), (1280, 720), (3840, 2160), (2160, 3840)];
pub(crate) const ALL_CODECS: [(&str, VideoCodec); 7] = [
    ("H.264", VideoCodec::H264),
    ("HEVC", VideoCodec::Hevc),
    ("ProRes 422 Proxy", VideoCodec::ProRes422Proxy),
    ("ProRes 422 LT", VideoCodec::ProRes422LT),
    ("ProRes 422", VideoCodec::ProRes422),
    ("ProRes 422 HQ", VideoCodec::ProRes422HQ),
    ("ProRes 4444", VideoCodec::ProRes4444),
];
const CAPTION_MODES: [CaptionMode; 5] =
    [CaptionMode::None, CaptionMode::BurnIn, CaptionMode::SidecarSrt, CaptionMode::SidecarVtt, CaptionMode::SidecarItt];

fn l(s: &str) -> String {
    SQL10n::string(s)
}

/// `ExportSheetRows.fpsText`.
pub(crate) fn fps_text(fps: f64) -> String {
    format!("{} fps", if fps == fps.round() { format!("{}", fps as i64) } else { format!("{fps}") })
}

/// The inputs of the rows besides the model.
pub(crate) struct Rows<'a> {
    pub model: &'a ExportDialogModel,
    /// The codecs the encoder writes.
    pub codecs: &'a [VideoCodec],
    /// The Size popup's "Custom" entry was chosen.
    pub custom_size: bool,
    /// The home folder, for `~` in the folder capsule.
    pub home: Option<String>,
    /// A copy action is wired (chapters).
    pub can_copy: bool,
    /// A folder chooser is wired.
    pub can_choose_folder: bool,
    /// This computer's encoder for the selected output and what it cannot do (`None` before the probe ran).
    pub support: Option<EncoderSupport>,
}

/// The sheet's line for an option the computer's encoder cannot do.
const NOT_HERE: &str = "Not available on this computer.";

impl Rows<'_> {
    /// Whether the encoder of this computer cannot honor `option` (false before the probe answered).
    fn lacks(&self, option: Missing) -> bool {
        self.support.as_ref().is_some_and(|x| !x.can(option))
    }
}

fn item(kind: Kind, width: Width, act: Act) -> Item {
    Item { kind, width, enabled: true, act, rebuild: true }
}

fn row(title: &str, items: Vec<Item>) -> Row {
    Row { title: title.to_string(), items, dimmed: false, height: None, top: None, hint: String::new() }
}

impl Row {
    fn tall(mut self, height: f64, top: f64) -> Self {
        (self.height, self.top) = (Some(height), Some(top));
        self
    }

    fn high(mut self, height: f64) -> Self {
        self.height = Some(height);
        self
    }

    fn hint(mut self, hint: &str) -> Self {
        self.hint = hint.to_string();
        self
    }
}

fn text(s: &str, tone: Tone, width: Width, caption: bool) -> Item {
    item(Kind::Text { text: l(s), tone, caption }, width, Act::None)
}

fn popup(titles: &[String], selected: usize, enabled: bool, rebuild: bool, act: Act) -> Item {
    let mut i = item(
        Kind::Popup { titles: titles.iter().map(|t| l(t)).collect(), selected, disabled: Vec::new() },
        Width::Fill,
        act,
    );
    (i.enabled, i.rebuild) = (enabled, rebuild);
    i
}

fn popup_s(titles: &[&str], selected: usize, enabled: bool, rebuild: bool, act: Act) -> Item {
    popup(&titles.iter().map(|s| (*s).to_string()).collect::<Vec<_>>(), selected, enabled, rebuild, act)
}

fn check(title: &str, on: bool, enabled: bool, width: Width, rebuild: bool, act: Act) -> Item {
    let mut i = item(Kind::Check { title: l(title), on }, width, act);
    (i.enabled, i.rebuild) = (enabled, rebuild);
    i
}

fn switch(on: bool, enabled: bool, rebuild: bool, act: Act) -> Item {
    let mut i = item(Kind::Switch { on }, Width::Fixed(34.0), act);
    (i.enabled, i.rebuild) = (enabled, rebuild);
    i
}

/// Greys out entries of a popup (they stay listed, as the sheet's other "not available" choices do).
fn with_disabled(mut i: Item, entries: Vec<usize>) -> Item {
    if let Kind::Popup { disabled, .. } = &mut i.kind {
        *disabled = entries;
    }
    i
}

fn button(title: &str, enabled: bool, act: Act) -> Item {
    let mut i = item(Kind::Button(l(title)), Width::Fit, act);
    i.enabled = enabled;
    i
}

#[allow(clippy::too_many_arguments)]
fn scrub(
    value: f64,
    (min, max): (f64, f64),
    step: f64,
    unit: &str,
    decimals: i64,
    default: Option<f64>,
    enabled: bool,
    rebuild: bool,
    act: Act,
) -> Vec<Item> {
    let spec = ScrubSpec { value, min, max, step, decimals, default };
    let width = if unit.is_empty() { Width::Fill } else { Width::Fixed(NUMBER_FIELD_WIDTH) };
    let mut field = item(Kind::Scrub(spec), width, act);
    (field.enabled, field.rebuild) = (enabled, rebuild);
    if unit.is_empty() { vec![field] } else { vec![field, item(Kind::Unit(unit.to_string()), Width::Fit, Act::None)] }
}

fn segmented(labels: &[&str], selected: usize, disabled: Vec<usize>, segment_width: f64, act: Act) -> Item {
    item(
        Kind::Segmented {
            labels: labels.iter().map(|s| l(s)).collect(),
            selected,
            disabled,
            segment_width,
            chips: false,
        },
        Width::Fit,
        act,
    )
}

fn chips(labels: &[&str], selected: usize, disabled: Vec<usize>, segment_width: f64, act: Act) -> Item {
    let mut i = segmented(labels, selected, disabled, segment_width, act);
    if let Kind::Segmented { chips, .. } = &mut i.kind {
        *chips = true;
    }
    i
}

/// The shapes of the chips under Size.
pub(crate) const SHAPES: [(i64, i64); 4] = [(1080, 1920), (1920, 1080), (1080, 1080), (1080, 1350)];
const SHAPE_NAMES: [&str; 4] = ["9:16", "16:9", "1:1", "4:5"];

/// The shape (index into [`SHAPES`]) whose ratio the size has, if any.
pub(crate) fn shape_of(w: i64, h: i64) -> Option<usize> {
    SHAPES.iter().position(|s| s.0 * h == s.1 * w)
}

/// "12" or "12.5".
fn format_mbps(v: f64) -> String {
    if (v - v.round()).abs() < 0.05 { format!("{}", v.round() as i64) } else { format!("{v:.1}") }
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// "9:16", or "1.43:1" when the reduced ratio is not small.
pub(crate) fn aspect_text(w: i64, h: i64) -> String {
    let g = gcd(w.max(1), h.max(1));
    let (a, b) = (w / g, h / g);
    if a <= 32 && b <= 32 { format!("{a}:{b}") } else { format!("{:.2}:1", w as f64 / h.max(1) as f64) }
}

/// The Range segments in the design's order; the model's modes are 0 Entire, 1 In to Out, 2 Custom, 3 Selected.
pub(crate) const RANGE_SEGMENTS: [&str; 4] = ["Entire", "In to Out", "Selected", "Custom"];

/// The segment that shows a model range mode.
pub(crate) fn range_segment(mode: i64) -> usize {
    match mode {
        2 => 3,
        3 => 2,
        m => usize::try_from(m).unwrap_or(0),
    }
}

/// The model range mode a segment sets (the swap is its own inverse).
pub(crate) fn range_mode_of_segment(segment: usize) -> i64 {
    range_segment(segment as i64) as i64
}

impl Rows<'_> {
    /// The sections with rows, in the Mac order; empty ones are left out.
    pub(crate) fn sections(&self) -> Vec<Section> {
        let s = self.model.settings();
        let audio_only = s.audio_only.is_some();
        let (mut essentials, video_details) = if audio_only { (Vec::new(), Vec::new()) } else { self.video_rows() };
        if s.frame_output.is_none() && !audio_only {
            essentials.push(self.audio_switch_row());
        }
        essentials.extend(self.caption_rows());
        essentials.extend(self.range_rows());
        essentials.extend(self.output_rows());
        if s.frame_output.is_none() && !audio_only {
            essentials.extend(self.cover_rows());
        }
        let audio_details = if s.frame_output.is_some() { Vec::new() } else { self.audio_rows() };
        let all = [
            Section { title: "", key: "export.essentials", default_open: true, rows: essentials, detail: false },
            Section {
                title: "Video details",
                key: "export.video",
                default_open: true,
                rows: video_details,
                detail: true,
            },
            Section {
                title: "Audio details",
                key: "export.audio",
                default_open: true,
                rows: audio_details,
                detail: true,
            },
            Section {
                title: "Advanced",
                key: "export.advanced",
                default_open: true,
                rows: self.advanced_rows(),
                detail: true,
            },
        ];
        all.into_iter().filter(|s| !s.rows.is_empty()).collect()
    }

    // MARK: Output

    fn abbreviated(&self, path: &str) -> String {
        let platform = sq_os::Platform::current();
        match &self.home {
            Some(h) => sq_os::paths::tilde(platform, path, h),
            None => sq_os::paths::display_form(platform, path),
        }
    }

    pub(crate) fn output_rows(&self) -> Vec<Row> {
        let m = self.model;
        let ext = if m.file_extension().is_empty() { String::new() } else { format!(".{}", m.file_extension()) };
        let folder = m
            .output_directory()
            .map_or_else(|| l("Choose a folder\u{2026}"), |d| self.abbreviated(&d.to_string_lossy()));
        let mut rows = vec![row(
            "Save to",
            vec![
                item(Kind::Field { suffix: ext }, Width::Fill, Act::FileName),
                item(Kind::Path(folder), Width::Fill, Act::None),
                button("Change\u{2026}", self.can_choose_folder, Act::ChooseFolder),
            ],
        )];
        rows.extend(self.chapter_rows());
        rows
    }

    fn chapter_rows(&self) -> Vec<Row> {
        let Some(c) = self.model.chapters() else { return Vec::new() };
        let hint = if c.warnings.is_empty() { l("Paste into the video description") } else { l(&c.warnings[0]) };
        let tone = if c.warnings.is_empty() { Tone::Label3 } else { Tone::Warning };
        let mut rows = vec![row(
            "Chapters",
            vec![
                button("Copy Chapters", self.can_copy, Act::CopyChapters(c.text.clone())),
                text(&hint, tone, Width::Fill, false),
            ],
        )];
        for w in c.warnings.iter().skip(1) {
            rows.push(row("Warning", vec![text(w, Tone::Warning, Width::Fill, false)]));
        }
        rows
    }

    // MARK: Video

    /// The video rows: the essentials (Size, Quality, Format, Frame Rate) and the details folded under More settings.
    fn video_rows(&self) -> (Vec<Row>, Vec<Row>) {
        let m = self.model;
        let (s, d) = (m.settings(), m.preset_settings());
        let mastering = s.video.codec.is_mastering();
        if let Some(output) = s.frame_output {
            return (self.frame_output_rows(output), Vec::new());
        }
        let mut ess = self.size_essential_rows();
        let mut rows = Vec::new();
        let mut list: Vec<(&str, VideoCodec)> =
            ALL_CODECS.iter().filter(|c| self.codecs.contains(&c.1)).copied().collect();
        if !list.iter().any(|c| c.1 == s.video.codec)
            && let Some(own) = ALL_CODECS.iter().find(|c| c.1 == s.video.codec)
        {
            list.push(*own);
        }
        let titles: Vec<&str> = list.iter().map(|c| c.0).collect();
        let at = list.iter().position(|c| c.1 == s.video.codec).unwrap_or(0);
        // No encoder for the chosen format on this computer: it stays shown, greyed out, and the export refuses.
        let no_encoder = self.lacks(Missing::Encoder);
        let picker = popup_s(&titles, at, true, true, Act::Codec(list.iter().map(|c| c.1).collect()));
        let format = row("Format", vec![with_disabled(picker, if no_encoder { vec![at] } else { Vec::new() })])
            .hint(if no_encoder { NOT_HERE } else { "" });
        let profiles: Vec<(&str, VideoProfile)> = match s.video.codec {
            VideoCodec::H264 => vec![
                ("Automatic", VideoProfile::Automatic),
                ("Baseline", VideoProfile::Baseline),
                ("Main", VideoProfile::Main),
                ("High", VideoProfile::High),
            ],
            VideoCodec::Hevc => vec![
                ("Automatic", VideoProfile::Automatic),
                ("Main", VideoProfile::Main),
                ("Main 10", VideoProfile::Main10),
            ],
            _ => vec![("Automatic", VideoProfile::Automatic)],
        };
        let titles: Vec<&str> = profiles.iter().map(|p| p.0).collect();
        let at = profiles.iter().position(|p| p.1 == s.video.profile).unwrap_or(0);
        let main10_lost = s.video.profile == VideoProfile::Main10 && self.lacks(Missing::TenBit);
        // H.264 Baseline / Main / High that the encoder of this computer cannot set (MPEG-4 Part 2 as the last resort).
        let profile_lost = s.video.codec == VideoCodec::H264
            && s.video.profile != VideoProfile::Automatic
            && self.lacks(Missing::Profile);
        let lost_entries: Vec<usize> = profiles
            .iter()
            .enumerate()
            .filter(|(_, p)| main10_lost && p.1 == VideoProfile::Main10)
            .map(|p| p.0)
            .collect();
        rows.push(
            row(
                "Profile",
                vec![with_disabled(
                    popup_s(
                        &titles,
                        at,
                        !s.video.codec.is_pro_res(),
                        true,
                        Act::Profile(profiles.iter().map(|p| p.1).collect()),
                    ),
                    lost_entries,
                )],
            )
            .hint(if main10_lost {
                "Main 10 is not available on this computer: the export will not run."
            } else if profile_lost {
                "The profile is not available on this computer: the encoder writes its own."
            } else {
                ""
            }),
        );
        rows.extend(self.size_rows());
        if !mastering && s.video.constant_quality().is_none() {
            ess.extend(self.quality_rows());
        }
        ess.push(format);
        ess.push(self.frame_rate_row());
        if !mastering {
            let q = s.video.constant_quality();
            let mut items = vec![popup_s(
                &["Target bitrate", "Constant quality"],
                usize::from(q.is_some()),
                true,
                true,
                Act::RateControl,
            )];
            if let Some(q) = q {
                items.extend(scrub(
                    (q * 100.0).round(),
                    (5.0, 100.0),
                    1.0,
                    "%",
                    0,
                    Some(60.0),
                    true,
                    false,
                    Act::ConstantQuality,
                ));
            }
            rows.push(row("Rate Control", items));
        }
        let hardware = row(
            "",
            vec![check("Use hardware encoding", s.video.hardware_encoding, true, Width::Fit, false, Act::Hardware)],
        );
        if s.video.constant_quality().is_some() {
            rows.push(hardware);
            rows.extend(self.encoder_speed_rows(mastering));
            rows.extend(self.color_space_rows());
            return (ess, rows);
        }
        let kinds = BitrateKind::available(s.video.codec);
        let default_mbps = d.video.bitrate.average_bits_per_second() as f64 / 1_000_000.0;
        let target = scrub(
            m.bitrate_mbps(),
            (0.5, 400.0),
            0.5,
            "Mbit/s",
            1,
            Some(default_mbps),
            !mastering,
            false,
            Act::Bitrate,
        );
        let cbr_lost = s.video.uses_constant_bitrate() && self.lacks(Missing::ConstantBitrate);
        let cbr_hint =
            if cbr_lost { "Constant bitrate is not available on this computer: the file is VBR." } else { "" };
        if kinds.is_empty() {
            rows.push(row("Bitrate", target).hint(cbr_hint));
        } else {
            let titles: Vec<&str> = kinds.iter().map(|k| k.title()).collect();
            let at = kinds.iter().position(|k| *k == m.bitrate_kind()).unwrap_or(0);
            let mut mode = popup_s(&titles, at, true, true, Act::BitrateKind(kinds.clone()));
            mode.width = Width::Fixed(96.0);
            let mut items = vec![mode];
            items.extend(target);
            rows.push(row("Bitrate", items).hint(cbr_hint));
        }
        if mastering || m.bitrate_kind().shows_maximum() {
            let max_default =
                d.video.bitrate.max_bits_per_second().unwrap_or(d.video.bitrate.average_bits_per_second() * 3 / 2)
                    as f64
                    / 1_000_000.0;
            let mut items =
                vec![check("Limit", m.has_max_bitrate(), !mastering, Width::Fixed(96.0), true, Act::HasMax)];
            items.extend(scrub(
                m.max_bitrate_mbps(),
                (0.5, 600.0),
                0.5,
                "Mbit/s",
                1,
                Some(max_default),
                !mastering && m.has_max_bitrate(),
                false,
                Act::MaxBitrate,
            ));
            rows.push(row("Max Bitrate", items));
        }
        rows.push(hardware);
        rows.extend(self.encoder_speed_rows(mastering));
        rows.extend(self.color_space_rows());
        (ess, rows)
    }

    fn frame_rate_row(&self) -> Row {
        let m = self.model;
        let mut rates = ExportDialogModel::FRAME_RATES.to_vec();
        if !rates.contains(&m.fps()) {
            rates.push(m.fps());
        }
        let titles: Vec<String> = rates.iter().map(|r| fps_text(*r)).collect();
        let at = rates.iter().position(|r| *r == m.fps()).unwrap_or(0);
        row("Frame Rate", vec![popup(&titles, at, true, true, Act::FrameRate(rates))])
    }

    fn frame_output_rows(&self, output: FrameOutput) -> Vec<Row> {
        let mut rows = Vec::new();
        if let FrameOutput::Sequence(format) = output {
            let formats = FrameStillFormat::available();
            let titles: Vec<&str> = formats.iter().map(|f| f.display_name()).collect();
            let at = formats.iter().position(|f| *f == format).unwrap_or(0);
            rows.push(row("Image Format", vec![popup_s(&titles, at, true, true, Act::ImageFormat(formats))]));
        } else {
            rows.push(row(
                "Format",
                vec![text("Animated GIF, loops, 256 colors per frame", Tone::Label, Width::Fixed(300.0), false)],
            ));
        }
        rows.extend(self.size_essential_rows());
        rows.push(self.frame_rate_row());
        rows
    }

    fn encoder_speed_rows(&self, mastering: bool) -> Vec<Row> {
        let current = self.model.encoder_speed();
        let titles: Vec<&str> = EncoderSpeed::ALL.iter().map(|s| s.display_name()).collect();
        let at = EncoderSpeed::ALL.iter().position(|s| *s == current).unwrap_or(0);
        let mut rows = vec![row("Encoder Speed", vec![popup_s(&titles, at, !mastering, true, Act::Speed)])];
        if !mastering && let Some(hint) = ExportDialogModel::encoder_speed_hint(current, physical_memory()) {
            rows.push(row("", vec![text(&hint, Tone::Label3, Width::Fixed(260.0), true)]));
        }
        rows
    }

    fn size_rows(&self) -> Vec<Row> {
        let m = self.model;
        let s = m.settings();
        let mut sizes = SIZES.to_vec();
        if let Some(f) = m.sequences().iter().find(|i| i.id == m.selected_id()).and_then(|i| i.format.as_ref())
            && f.is_valid()
        {
            let own = (f.width & !1, f.height & !1);
            if !sizes.contains(&own) {
                sizes.insert(0, own);
            }
        }
        let cur = (s.video.width, s.video.height);
        let matched = sizes.iter().position(|x| *x == cur);
        let is_custom = self.custom_size || matched.is_none();
        let mut names: Vec<String> = sizes.iter().map(|x| format!("{} \u{00D7} {}", x.0, x.1)).collect();
        names.push("Custom".to_string());
        let at = if is_custom { names.len() - 1 } else { matched.unwrap_or(0) };
        let rows = vec![row("Size Preset", vec![popup(&names, at, true, true, Act::Size(sizes))])];
        rows
    }

    /// Size as typed width x height with the swap and the ratio, and the shape chips under it.
    fn size_essential_rows(&self) -> Vec<Row> {
        let m = self.model;
        let s = m.settings();
        let (w, h) = (s.video.width, s.video.height);
        let d = m.preset_settings();
        let field = |v: i64, dv: i64, act: Act| {
            let mut f = scrub(v as f64, (2.0, 8192.0), 2.0, "", 0, Some(dv as f64), true, true, act).remove(0);
            f.width = Width::Fixed(64.0);
            f
        };
        let swap = Item {
            kind: Kind::IconButton(sq_uikit::sqicon::SQIcon::Swap),
            width: Width::Fixed(28.0),
            enabled: true,
            act: Act::Swap,
            rebuild: true,
        };
        let items = vec![
            field(w, d.video.width, Act::Width),
            text("\u{00D7}", Tone::Label3, Width::Fit, false),
            field(h, d.video.height, Act::Height),
            swap,
            text(
                &aspect_text(w, h),
                Tone::Label2,
                Width::Fixed(if aspect_text(w, h).len() > 5 { 64.0 } else { 44.0 }),
                false,
            ),
        ];
        let at = shape_of(w, h).unwrap_or(SHAPES.len());
        vec![
            row("Size", items).tall(39.0, 8.0).hint("Type a size or pick a shape. The picture is scaled to fit."),
            row("", vec![chips(&SHAPE_NAMES, at, Vec::new(), 52.0, Act::Shape)]).tall(29.0, 1.0),
        ]
    }

    /// Quality in words: three steps on the existing quality setting, the Mbit/s small beside them.
    fn quality_rows(&self) -> Vec<Row> {
        let m = self.model;
        // A preset's own bitrate rarely sits on a step: the nearest one is lit, so the segment never opens empty.
        let at = m
            .quality_step()
            .and_then(|c| QualityStep::ALL.iter().position(|x| *x == c))
            .unwrap_or(QualityStep::ALL.len());
        let mbps = format!("{} Mbit/s", format_mbps(m.bitrate_mbps()));
        vec![
            row("Quality", vec![segmented(&["Smaller", "Standard", "Best"], at, Vec::new(), 76.0, Act::QualityStep)])
                .tall(38.0, 8.0),
            row("", vec![text(&mbps, Tone::Label3, Width::Fit, false)]).high(21.0),
        ]
    }

    fn audio_switch_row(&self) -> Row {
        let loudness = self.model.settings().audio.loudness;
        let on = self.model.settings().audio.enabled;
        // The kit's loudness popup in front of the switch: the Normalize setting as one choice (Off, a delivery target, or
        // the custom value the Normalize row below holds).
        let mut titles = vec!["No loudness match".to_string()];
        titles.extend(AudioDeliveryTarget::ALL.iter().map(|t| t.display_name().to_string()));
        let at = match (loudness, self.model.delivery_target_index()) {
            (None, _) => 0,
            (Some(_), Some(i)) => i + 1,
            (Some(ln), None) => {
                titles.push(format!("Custom ({} LUFS)", ln.target_lufs.round()));
                titles.len() - 1
            }
        };
        let mut target = popup(&titles, at, on, true, Act::AudioLoudness);
        target.width = Width::Fixed(210.0);
        // The hint names what the picked option does; the switch state wins because "off" means no sound at all.
        let hint = match (on, loudness.is_some()) {
            (false, _) => "Audio is off: the file exports without sound.",
            (true, false) => "The loudness stays as it is in the sequence.",
            (true, true) => "Loudness is matched for the platform.",
        };
        row("Audio", vec![target, switch(on, true, true, Act::IncludeAudio)]).high(64.0).hint(hint)
    }

    // MARK: Audio

    fn audio_rows(&self) -> Vec<Row> {
        let m = self.model;
        let s = m.settings();
        let on = s.audio.enabled;
        let mut rows = Vec::new();
        if s.audio_only.is_none() {
            rows.push(row(
                "Codec",
                vec![popup_s(
                    &["AAC", "PCM"],
                    usize::from(s.audio.codec != AudioCodec::Aac),
                    on,
                    true,
                    Act::AudioCodec,
                )],
            ));
        }
        let rates = [44_100, 48_000, 96_000];
        rows.push(row(
            "Sample Rate",
            vec![popup_s(
                &["44.1 kHz", "48 kHz", "96 kHz"],
                rates.iter().position(|r| *r == s.audio.sample_rate).unwrap_or(1),
                on,
                false,
                Act::SampleRate,
            )],
        ));
        if s.effective_audio().codec == AudioCodec::Aac {
            let rates = [128_000, 192_000, 256_000, 320_000];
            rows.push(row(
                "Bitrate",
                vec![popup_s(
                    &["128 kbit/s", "192 kbit/s", "256 kbit/s", "320 kbit/s"],
                    rates.iter().position(|r| *r == s.audio.bitrate).unwrap_or(1),
                    on,
                    false,
                    Act::AudioBitrate,
                )],
            ));
        } else {
            let depths: Vec<i64> =
                if s.audio_only == Some(AudioFileFormat::Flac) { vec![16, 24] } else { vec![16, 24, 32] };
            let titles: Vec<String> = depths.iter().map(|d| format!("{d}-bit")).collect();
            let at = depths.iter().position(|d| *d == s.audio.pcm_bit_depth).unwrap_or(1);
            rows.push(row("Bit Depth", vec![popup(&titles, at, on, false, Act::BitDepth(depths))]));
        }
        let mut norm = vec![check("", s.audio.loudness.is_some(), on, Width::Fit, true, Act::Normalize)];
        if let Some(ln) = s.audio.loudness {
            norm.extend(scrub(
                ln.target_lufs,
                (-40.0, -5.0),
                1.0,
                "LUFS",
                1,
                m.preset_settings().audio.loudness.map(|x| x.target_lufs),
                on,
                false,
                Act::LoudnessTarget,
            ));
            let mut titles = vec!["Custom".to_string()];
            titles.extend(AudioDeliveryTarget::ALL.iter().map(|t| t.display_name().to_string()));
            let at = m.delivery_target_index().map_or(0, |i| i + 1);
            norm.push(popup(&titles, at, on, true, Act::DeliveryTarget));
        }
        rows.push(row("Normalize", norm));
        if !m.loudness_range_available() {
            rows.push(row(
                "Loudness Range",
                vec![text("Needs a program of 60 s or more", Tone::Label3, Width::Fill, false)],
            ));
        }
        rows.extend(self.audio_check_rows(on));
        rows.extend(self.stem_rows());
        rows.extend(self.cut_down_rows());
        rows
    }

    fn cut_down_rows(&self) -> Vec<Row> {
        let m = self.model;
        let plans = m.cut_down_plans();
        if plans.is_empty() {
            return Vec::new();
        }
        let secs = |t: Time| t.export_seconds().round() as i64;
        let mut rows: Vec<Row> = plans
            .iter()
            .map(|plan| {
                row(
                    &format!("{} s", plan.target_seconds),
                    plan.ranges
                        .iter()
                        .enumerate()
                        .map(|(i, r)| {
                            let k = CutDownKey::new(plan.target_seconds, i);
                            let title = format!("{}\u{2013}{} s", secs(r.start), secs(r.end()));
                            check(&title, m.is_cut_down_checked(k), true, Width::Fit, true, Act::CutCheck(k))
                        })
                        .collect(),
                )
            })
            .collect();
        let hint = if m.output_directory().is_none() { "Choose a folder first" } else { "One file per checked range" };
        rows.push(row(
            "Cut-downs",
            vec![
                button(
                    "Export Cut-downs",
                    m.checked_cut_down_count() > 0 && m.output_directory().is_some(),
                    Act::CutsRun,
                ),
                text(hint, Tone::Label3, Width::Fill, false),
            ],
        ));
        rows
    }

    fn stem_rows(&self) -> Vec<Row> {
        let m = self.model;
        if !m.can_export_stems() {
            return Vec::new();
        }
        let size = format!("{:.1} MB", m.stem_estimated_bytes() as f64 / 1_000_000.0);
        let mut hint = if m.output_directory().is_none() {
            l("Choose a folder first")
        } else {
            SQL10n::format("About %@ in %@ files", &[&size, &m.active_stems().len().to_string()])
        };
        if let Some(s) = m.stem_status() {
            hint = l(s);
        }
        // The kit's one Stems row: the role chips, then Export Stems; the size or "Choose a folder first" under it.
        let busy = m.is_exporting_stems();
        let mut items: Vec<Item> = m
            .stem_plan()
            .iter()
            .map(|stem| {
                item(
                    Kind::Chip { title: l(&stem.title), on: m.is_stem_checked(&stem.id) },
                    Width::Fit,
                    Act::StemCheck(stem.id.clone()),
                )
            })
            .collect();
        items.push(button(
            if busy { "Exporting\u{2026}" } else { "Export Stems" },
            !busy && m.output_directory().is_some() && !m.active_stems().is_empty(),
            Act::StemsRun,
        ));
        vec![row("Stems", items).hint(&hint)]
    }

    fn audio_check_rows(&self, enabled: bool) -> Vec<Row> {
        let m = self.model;
        let mut hint = l("Loudness, true peak, clipping, gaps, dual mono, sync");
        if let Some(e) = m.audio_check_error() {
            hint = l(e);
        }
        let title = if m.is_checking_audio() {
            "Checking\u{2026}"
        } else if m.has_audio_check() {
            "Check Again"
        } else {
            "Check Audio"
        };
        let mut rows = vec![row(
            "Audio Check",
            vec![
                button(title, enabled && !m.is_checking_audio(), Act::AudioCheck),
                text(&hint, Tone::Label3, Width::Fill, false),
            ],
        )];
        for f in m.audio_findings() {
            let (tone, mark) = match f.severity {
                AudioSeverity::Pass => (Tone::Green, "Pass"),
                AudioSeverity::Warning => (Tone::Warning, "Warning"),
                AudioSeverity::Fail => (Tone::Red, "Fail"),
            };
            rows.push(row(mark, vec![text(&f.message, tone, Width::Fill, false)]));
        }
        rows
    }

    // MARK: Captions and range

    fn caption_rows(&self) -> Vec<Row> {
        let m = self.model;
        let at = CAPTION_MODES.iter().position(|c| *c == m.captions()).unwrap_or(0);
        let disabled = if m.settings().audio_only.is_some() { vec![1] } else { Vec::new() };
        vec![
            row(
                "Captions",
                vec![chips(
                    &["None", "Burn in", "SRT file", "VTT file", "iTT file"],
                    at,
                    disabled,
                    74.0,
                    Act::Captions,
                )],
            )
            .high(36.0),
        ]
    }

    fn cover_rows(&self) -> Vec<Row> {
        let m = self.model;
        let on = switch(m.cover_image().is_some(), true, true, Act::CoverOn);
        let hint = "Also save a still as the thumbnail.";
        let Some(f) = m.cover_image() else { return vec![row("Cover image", vec![on]).high(48.0).hint(hint)] };
        let formats = [CoverImageFormat::Png, CoverImageFormat::Jpg];
        let format = segmented(
            &["PNG", "JPG"],
            formats.iter().position(|x| *x == f).unwrap_or(0),
            Vec::new(),
            44.0,
            Act::CoverFormat,
        );
        vec![
            row("Cover image", vec![format, on]).high(48.0).hint(hint),
            row("Cover Frame", vec![text(&m.cover_frame_text(), Tone::Label3, Width::Fixed(300.0), false)]),
        ]
    }

    pub(crate) fn range_rows(&self) -> Vec<Row> {
        let m = self.model;
        let fd = m.settings().video.frame_duration;
        let mut disabled = Vec::new();
        if !m.can_use_in_out() {
            disabled.push(1);
        }
        if !m.can_use_selection() {
            disabled.push(2);
        }
        let mut rows = vec![row(
            "Range",
            vec![segmented(&RANGE_SEGMENTS, range_segment(m.range_mode()), disabled, 70.0, Act::RangeMode)],
        )];
        let total = m.sequences().iter().find(|i| i.id == m.selected_id()).map_or(0.0, |i| i.duration.export_seconds());
        if m.range_mode() == 2 {
            let r = m.range_seconds();
            rows.push(row(
                "Start",
                scrub(r.start, (0.0, total.max(0.1)), 0.5, "s", 2, Some(0.0), true, true, Act::CustomStart),
            ));
            rows.push(row(
                "End",
                scrub(r.end, (0.0, total.max(0.1)), 0.5, "s", 2, Some(total), true, true, Act::CustomEnd),
            ));
        }
        if m.range_mode() == 3 && m.selected_clip_count() > 1 {
            rows.push(row(
                "Files",
                vec![check("One file per clip", m.one_file_per_clip(), true, Width::Fit, true, Act::OneFilePerClip)],
            ));
        }
        // The marks exist: show the range the export covers for the picked mode (Entire reads 0 to the sequence end),
        // not the raw marks, which can be a stray one-frame In/Out the Entire export ignores.
        if m.sequences().iter().any(|i| i.id == m.selected_id() && i.in_out.is_some()) {
            let r = m.effective_range();
            rows.push(row(
                "In / Out",
                vec![text(
                    &format!(
                        "{} \u{2013} {}",
                        ExportDecodeError::timecode(r.start, fd),
                        ExportDecodeError::timecode(r.end(), fd)
                    ),
                    Tone::Label,
                    Width::Fixed(260.0),
                    false,
                )],
            ));
        }
        rows
    }

    // MARK: Advanced

    fn advanced_rows(&self) -> Vec<Row> {
        let m = self.model;
        let (s, d) = (m.settings(), m.preset_settings());
        let mastering = s.video.codec.is_mastering();
        if s.frame_output.is_some() {
            return Vec::new();
        }
        let audio_on = s.audio_only.is_some() || s.audio.enabled;
        let channels = row(
            "Channels",
            vec![popup_s(&["Mono", "Stereo"], usize::from(s.audio.channels != 1), audio_on, false, Act::Channels)],
        );
        let peak = s.audio.loudness.map(|ln| {
            row(
                "True Peak Max",
                scrub(
                    ln.true_peak_ceiling_db,
                    (-9.0, 0.0),
                    0.5,
                    "dBTP",
                    1,
                    d.audio.loudness.map(|x| x.true_peak_ceiling_db),
                    audio_on,
                    false,
                    Act::TruePeak,
                ),
            )
        });
        let mut rows = Vec::new();
        if s.audio_only.is_some() {
            rows.push(channels);
            rows.extend(peak);
            return rows;
        }
        rows.push(row(
            "Keyframe Every",
            scrub(
                s.video.keyframe_interval as f64,
                (1.0, 600.0),
                1.0,
                "frames",
                0,
                Some(d.video.keyframe_interval as f64),
                !mastering,
                false,
                Act::Keyframe,
            ),
        ));
        // A computer whose encoder writes no B-frames shows the box off and unavailable instead of a lit box that does nothing.
        let b_lost = self.lacks(Missing::BFrames);
        rows.push(
            row(
                "B-Frames",
                vec![check(
                    "Allow frame reordering",
                    s.video.allows_frame_reordering && !b_lost,
                    !mastering && !b_lost,
                    Width::Fit,
                    false,
                    Act::BFrames,
                )],
            )
            .hint(if b_lost && s.video.allows_frame_reordering { NOT_HERE } else { "" }),
        );
        rows.push(row(
            "Alpha",
            vec![check(
                "Keep transparency (ProRes 4444)",
                s.video.preserves_alpha,
                s.video.codec == VideoCodec::ProRes4444,
                Width::Fit,
                true,
                Act::Alpha,
            )],
        ));
        rows.push(row(
            "Bit Depth",
            vec![item(
                Kind::Text { text: format!("{}-bit", s.video.bit_depth()), tone: Tone::Label, caption: false },
                Width::Fixed(120.0),
                Act::None,
            )],
        ));
        rows.push(channels);
        rows.extend(peak);
        rows.push(row(
            "Damaged Frames",
            vec![check(
                "Continue on damaged frames",
                m.continue_on_damaged_frames(),
                true,
                Width::Fit,
                false,
                Act::Damaged,
            )],
        ));
        rows.push(row(
            "HDR to SDR",
            vec![check(
                "Adjust the conversion of HDR clips",
                s.hdr_to_sdr.is_some(),
                true,
                Width::Fit,
                true,
                Act::HdrToSdr,
            )],
        ));
        if let Some(h) = s.hdr_to_sdr {
            rows.push(row(
                "HDR Exposure",
                scrub(h.exposure_stops, (-4.0, 4.0), 0.1, "stops", 1, Some(0.0), true, true, Act::HdrExposure),
            ));
            rows.push(row(
                "HDR Gamut",
                vec![check(
                    "Compress colors outside Rec.709",
                    h.compresses_gamut,
                    true,
                    Width::Fit,
                    false,
                    Act::HdrGamut,
                )],
            ));
        }
        rows
    }

    fn color_space_rows(&self) -> Vec<Row> {
        let s = self.model.settings();
        if s.video.codec != VideoCodec::Hevc {
            return vec![row(
                "Color Space",
                vec![text("Rec. 709 (tagged 1-1-1)", Tone::Label, Width::Fixed(200.0), false)],
            )];
        }
        let mut titles = vec!["Rec. 709 (SDR)".to_string()];
        titles.extend(HdrTransfer::ALL.iter().map(|t| format!("Rec. 2020 {}", t.title())));
        let sel =
            s.hdr_delivery.and_then(|h| HdrTransfer::ALL.iter().position(|t| *t == h.transfer)).map_or(0, |i| i + 1);
        let mut rows = vec![row("Color Space", vec![popup(&titles, sel, true, true, Act::ColorSpace)])];
        if let Some(h) = s.hdr_delivery {
            rows.push(row(
                "Peak Brightness",
                scrub(h.peak_nits, (100.0, 10_000.0), 50.0, "nits", 0, Some(1000.0), true, true, Act::PeakNits),
            ));
        }
        rows
    }
}

/// The physical memory the encoder-speed hint compares with (the Mac `ProcessInfo.physicalMemory`). Unknown memory
/// shows no hint (a large machine).
fn physical_memory() -> u64 {
    ExportPreflight::physical_memory().unwrap_or(u64::MAX)
}

/// Runs the control's change against the model (the Swift item closure).
pub(crate) fn apply(model: &mut ExportDialogModel, act: &Act, v: &Val) -> Outcome {
    let mut out = Outcome { rebuild: true, ..Outcome::default() };
    let index = if let Val::Index(i) = v { Some(*i) } else { None };
    let on = if let Val::Bool(b) = v { Some(*b) } else { None };
    let num = if let Val::Number(n) = v { Some(*n) } else { None };
    match act {
        Act::None => out.rebuild = false,
        Act::Codec(list) => {
            if let Some(c) = index.and_then(|i| list.get(i)) {
                model.set_codec(*c);
                if *c == VideoCodec::H264 && model.settings().video.profile == VideoProfile::Main10 {
                    model.edit(|s| s.video.profile = VideoProfile::Automatic);
                }
            }
        }
        Act::Profile(list) => {
            if let Some(p) = index.and_then(|i| list.get(i)) {
                model.edit(|s| s.video.profile = *p);
            }
        }
        Act::Size(sizes) => {
            if let Some(i) = index {
                if i == sizes.len() {
                    out.custom_size = Some(true);
                } else {
                    out.custom_size = Some(false);
                    model.set_width(sizes[i].0);
                    model.set_height(sizes[i].1);
                }
            }
        }
        Act::Shape => {
            if let Some(sh) = index.and_then(|i| SHAPES.get(i)) {
                out.custom_size = Some(false);
                model.set_width(sh.0);
                model.set_height(sh.1);
            }
        }
        Act::Swap => {
            let (w, h) = (model.width(), model.height());
            model.set_width(h);
            model.set_height(w);
        }
        Act::Width => {
            if let Some(n) = num {
                model.set_width(n as i64 & !1);
            }
        }
        Act::Height => {
            if let Some(n) = num {
                model.set_height(n as i64 & !1);
            }
        }
        Act::FrameRate(rates) => {
            if let Some(r) = index.and_then(|i| rates.get(i)) {
                model.set_fps(*r);
            }
        }
        Act::ImageFormat(formats) => {
            if let Some(f) = index.and_then(|i| formats.get(i)) {
                model.edit(|s| s.frame_output = Some(FrameOutput::Sequence(*f)));
            }
        }
        Act::RateControl => {
            if let Some(i) = index {
                model.edit(|s| s.video.set_constant_quality(if i == 0 { None } else { Some(0.6) }));
            }
        }
        Act::ConstantQuality => {
            if let Some(n) = num {
                model.edit(|s| s.video.set_constant_quality(Some(n / 100.0)));
            }
        }
        Act::Hardware => {
            if let Some(b) = on {
                model.edit(|s| s.video.hardware_encoding = b);
            }
        }
        Act::Speed => {
            if let Some(sp) = index.and_then(|i| EncoderSpeed::ALL.get(i)) {
                model.set_encoder_speed(*sp);
            }
        }
        Act::QualityStep => {
            if let Some(step) = index.and_then(|i| QualityStep::ALL.get(i)) {
                model.set_quality_step(*step);
            }
        }
        Act::BitrateKind(kinds) => {
            if let Some(k) = index.and_then(|i| kinds.get(i)) {
                model.set_bitrate_kind(*k);
            }
        }
        Act::Bitrate => {
            if let Some(n) = num {
                model.set_bitrate_mbps(n);
            }
        }
        Act::HasMax => {
            if let Some(b) = on {
                model.set_has_max_bitrate(b);
            }
        }
        Act::MaxBitrate => {
            if let Some(n) = num {
                model.set_max_bitrate_mbps(n);
            }
        }
        Act::IncludeAudio => {
            if let Some(b) = on {
                model.edit(|s| s.audio.enabled = b);
            }
        }
        Act::AudioCodec => {
            if let Some(i) = index {
                model.edit(|s| s.audio.codec = if i == 0 { AudioCodec::Aac } else { AudioCodec::Pcm });
            }
        }
        Act::SampleRate => {
            if let Some(r) = index.and_then(|i| [44_100, 48_000, 96_000].get(i)) {
                model.edit(|s| s.audio.sample_rate = *r);
            }
        }
        Act::AudioBitrate => {
            if let Some(r) = index.and_then(|i| [128_000, 192_000, 256_000, 320_000].get(i)) {
                model.edit(|s| s.audio.bitrate = *r);
            }
        }
        Act::BitDepth(depths) => {
            if let Some(d) = index.and_then(|i| depths.get(i)) {
                model.edit(|s| s.audio.pcm_bit_depth = *d);
            }
        }
        Act::Normalize => {
            if let Some(b) = on {
                model.set_normalize_loudness(b);
            }
        }
        Act::AudioLoudness => {
            if let Some(i) = index {
                if i == 0 {
                    model.set_normalize_loudness(false);
                } else if let Some(t) = AudioDeliveryTarget::ALL.get(i - 1) {
                    model.edit(|s| s.audio.loudness = Some(t.normalization()));
                }
            }
        }
        Act::LoudnessTarget => {
            if let Some(n) = num {
                model.edit(|s| {
                    if let Some(ln) = s.audio.loudness.as_mut() {
                        ln.target_lufs = n.round();
                    }
                });
            }
        }
        Act::DeliveryTarget => {
            if let Some(t) = index.filter(|i| *i > 0).and_then(|i| AudioDeliveryTarget::ALL.get(i - 1)) {
                model.edit(|s| s.audio.loudness = Some(t.normalization()));
            }
        }
        Act::AudioCheck => out.event = Some("audio_check"),
        Act::StemCheck(id) => {
            if let Some(b) = on {
                model.set_stem_checked(id, b);
            }
        }
        Act::StemsRun => out.event = Some("stems_run"),
        Act::CutCheck(k) => {
            if let Some(b) = on {
                model.set_cut_down_checked(*k, b);
            }
        }
        Act::CutsRun => out.event = Some("cuts_run"),
        Act::Captions => {
            if let Some(c) = index.and_then(|i| CAPTION_MODES.get(i)) {
                model.set_captions(*c);
            }
        }
        Act::CoverOn => {
            if let Some(b) = on {
                model.set_cover_image(if b { Some(CoverImageFormat::Png) } else { None });
            }
        }
        Act::CoverFormat => {
            if let Some(i) = index {
                model.set_cover_image(Some([CoverImageFormat::Png, CoverImageFormat::Jpg][i.min(1)]));
            }
        }
        Act::RangeMode => {
            if let Some(i) = index {
                model.set_range_mode(range_mode_of_segment(i));
            }
        }
        Act::CustomStart => {
            if let Some(n) = num {
                model.set_custom_range(Some(n), None);
            }
        }
        Act::CustomEnd => {
            if let Some(n) = num {
                model.set_custom_range(None, Some(n));
            }
        }
        Act::OneFilePerClip => {
            if let Some(b) = on {
                model.set_one_file_per_clip(b);
            }
        }
        Act::FileName => {
            if let Val::Text(s) = v {
                model.set_file_name(s);
            }
        }
        Act::ChooseFolder => out.event = Some("folder"),
        Act::CopyChapters(t) => {
            out.rebuild = false;
            out.copy = Some(t.clone());
        }
        Act::Channels => {
            if let Some(i) = index {
                model.edit(|s| s.audio.channels = if i == 0 { 1 } else { 2 });
            }
        }
        Act::TruePeak => {
            if let Some(n) = num {
                model.edit(|s| {
                    if let Some(ln) = s.audio.loudness.as_mut() {
                        ln.true_peak_ceiling_db = n;
                    }
                });
            }
        }
        Act::Keyframe => {
            if let Some(n) = num {
                model.edit(|s| s.video.keyframe_interval = n as i64);
            }
        }
        Act::BFrames => {
            if let Some(b) = on {
                model.edit(|s| s.video.allows_frame_reordering = b);
            }
        }
        Act::Alpha => {
            if let Some(b) = on {
                model.edit(|s| s.video.preserves_alpha = b);
            }
        }
        Act::Damaged => {
            if let Some(b) = on {
                model.set_continue_on_damaged_frames(b);
            }
        }
        Act::HdrToSdr => {
            if let Some(b) = on {
                model.edit(|s| s.hdr_to_sdr = b.then(HdrToSdr::default));
            }
        }
        Act::HdrExposure => {
            if let Some(n) = num {
                model.edit(|s| {
                    if let Some(h) = s.hdr_to_sdr {
                        s.hdr_to_sdr = Some(HdrToSdr::new(n, h.compresses_gamut));
                    }
                });
            }
        }
        Act::HdrGamut => {
            if let Some(b) = on {
                model.edit(|s| {
                    if let Some(h) = s.hdr_to_sdr {
                        s.hdr_to_sdr = Some(HdrToSdr::new(h.exposure_stops, b));
                    }
                });
            }
        }
        Act::ColorSpace => {
            if let Some(i) = index {
                let peak = model.settings().hdr_delivery.map_or(1000.0, |h| h.peak_nits);
                model.edit(|s| {
                    s.hdr_delivery = i
                        .checked_sub(1)
                        .and_then(|k| HdrTransfer::ALL.get(k))
                        .map(|t| HdrDelivery::new(*t, peak, 400.0, 0.005));
                });
            }
        }
        Act::PeakNits => {
            if let Some(n) = num {
                model.edit(|s| {
                    if let Some(h) = s.hdr_delivery {
                        s.hdr_delivery = Some(HdrDelivery::new(h.transfer, n, h.frame_average_nits, h.min_nits));
                    }
                });
            }
        }
    }
    out
}
